// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import AppKit
import CoreData
import Combine

class LocalStore {
    static let defaultProfileId = "Default"
    /// Format 10 is the Core Data store; formats 1...9 are SwiftData stores
    /// that `LocalStoreLegacyImport` converts on first open (macOS 14+ only —
    /// every pre-10 store was written by an app whose floor was macOS 14).
    static let compatibilityConfiguration = LocalStoreCompatibilityConfiguration(
        currentStoreFormatVersion: 10,
        readableStoreFormatVersions: 1...10,
        // A manifest-less store can only have been written by a SwiftData
        // build: format-10 stores are created together with their manifest.
        legacyFallbackStoreFormatVersion: 9,
        storeFilename: "LocalStore.sqlite"
    )

    private(set) var container: NSPersistentContainer?
    let account: Account
    private let userStorageURL: URL
    private var cancellable: AnyCancellable?
    /// Single background context that executes every write; the FIFO stream
    /// below serializes job submission order on top of it.
    private let writeContext: NSManagedObjectContext?

    /// Serial FIFO queue for background writes. The write context serializes
    /// write *execution*, but dispatching each write as an independent `Task`
    /// carries no guarantee of reaching the context in submission order. A
    /// "create record" write could therefore land after a follow-up "update
    /// field" write that targets it, and the update would silently no-op (its
    /// fetch finds no row). This broke pinned-split pairing: the
    /// `splitPartnerGuid` set right after the two pinned rows were created
    /// would sometimes apply before the rows existed, leaving the pair
    /// unlinked and rendering as two cells once the live SplitGroup went away
    /// (e.g. on close). Funnelling every write through this stream restores
    /// submit-order == apply-order, which every caller already assumes.
    private let writeJobContinuation: AsyncStream<() async -> Void>.Continuation?
    private(set) var compatibilityStatus: LocalStoreCompatibilityStatus = .notChecked

    @MainActor var mainContext: NSManagedObjectContext? {
        container?.viewContext
    }

    init(
        account: Account,
        storeDirectoryURL: URL? = nil,
        presentsCompatibilityAlerts: Bool = true
    ) {
        self.account = account

        let userDir = account.userDataStorage
        let storeURL = storeDirectoryURL ?? userDir.appendingPathComponent("localDB")
        userStorageURL = storeURL
        if storeDirectoryURL == nil {
            Self.migrateOldDatabaseIfNeeded(from: userDir, to: storeURL)
        }

        try? FileManager.default.createDirectory(at: userStorageURL,
                                                 withIntermediateDirectories: true)

        let compatibilityController = LocalStoreCompatibilityController(
            configuration: Self.compatibilityConfiguration
        )
        let compatibilityResult: LocalStoreCompatibilityResult
        do {
            compatibilityResult = try compatibilityController.prepareStore(at: userStorageURL)
        } catch {
            AppLogError("[LocalStore] Failed to prepare local store compatibility state: \(error)")
            compatibilityStatus = .failed(error.localizedDescription)
            container = nil
            writeContext = nil
            writeJobContinuation = nil
            return
        }

        let openPlan: LocalStoreOpenPlan
        switch compatibilityResult {
        case .ready(let plan):
            compatibilityStatus = .ready(plan)
            openPlan = plan
        case .requiresNewerApp(let issue):
            AppLogError(
                "[LocalStore] Store format \(issue.activeStoreFormatVersion) requires a newer app. Current readable range: \(issue.readableStoreFormatVersions)"
            )
            compatibilityStatus = .requiresNewerApp(issue)
            container = nil
            writeContext = nil
            writeJobContinuation = nil
            if presentsCompatibilityAlerts {
                Self.runRequiresNewerAppAlert()
            }
            return
        }

        let storeFileURL = userStorageURL.appendingPathComponent(Self.compatibilityConfiguration.storeFilename)

        // Formats 1...9 are SwiftData stores: convert once before opening.
        if openPlan.activeStoreFormatVersion < 10,
           FileManager.default.fileExists(atPath: storeFileURL.path) {
            do {
                try LocalStoreLegacyImport.convertStore(
                    at: userStorageURL,
                    storeFilename: Self.compatibilityConfiguration.storeFilename
                )
            } catch {
                AppLogError("[LocalStore] Failed to convert legacy store: \(error)")
                compatibilityStatus = .failed(error.localizedDescription)
                container = nil
                writeContext = nil
                writeJobContinuation = nil
                return
            }
        }

        do {
            let persistentContainer = try Self.makeContainer(storeFileURL: storeFileURL)
            container = persistentContainer
            let backgroundContext = persistentContainer.newBackgroundContext()
            backgroundContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
            // The write context is long-lived; without merging it would keep
            // serving rows from its first-load snapshot and miss edits saved
            // on the main context (e.g. profile display-name upserts).
            backgroundContext.automaticallyMergesChangesFromParent = true
            writeContext = backgroundContext
            // Drain queued writes one at a time, in submission order. Buffering
            // is unbounded so no write is ever dropped, and yields made before
            // this consumer starts are replayed in order.
            let (stream, continuation) = AsyncStream<() async -> Void>.makeStream()
            writeJobContinuation = continuation
            Task {
                for await job in stream {
                    await job()
                }
            }
            do {
                try compatibilityController.markStoreOpenedSuccessfully(openPlan, at: userStorageURL)
            } catch {
                AppLogError("[LocalStore] Failed to record opened local store format: \(error)")
            }
        } catch {
            AppLogError("Failed to create persistent container: \(error)")
            container = nil
            writeContext = nil
            writeJobContinuation = nil
        }
    }

    static func makeContainer(storeFileURL: URL) throws -> NSPersistentContainer {
        let container = NSPersistentContainer(name: "LocalStore", managedObjectModel: LocalStoreSchema.model)
        let description = NSPersistentStoreDescription(url: storeFileURL)
        description.type = NSSQLiteStoreType
        description.shouldAddStoreAsynchronously = false
        container.persistentStoreDescriptions = [description]
        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError {
            throw loadError
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        return container
    }

    private static func runRequiresNewerAppAlert() {
        Task { @MainActor in
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("localData.compatibilityAlert.updateRequiredTitle", value: "Update Phi to Open Local Data",
                comment: "Local store compatibility alert - title when the local database was opened by a newer app version"
            )
            alert.informativeText = NSLocalizedString("localData.compatibilityAlert.newerVersionMessage", value: "This version of Phi cannot open local browser data that was updated by a newer version. Install the latest Phi version and try again.",
                comment: "Local store compatibility alert - body when a newer app is required to read local data"
            )
            alert.alertStyle = .warning
            alert.addButton(withTitle: NSLocalizedString("localData.compatibilityAlert.dismissButton", value: "OK", comment: "Local data compatibility alert - Dismiss button"))
            alert.runModal()
        }
    }
}

// MARK: - Database Migration
extension LocalStore {
    private static func migrateOldDatabaseIfNeeded(from oldDir: URL, to newDir: URL) {
        let fileManager = FileManager.default
        let oldDBFile = oldDir.appendingPathComponent("LocalStore.sqlite")

        guard fileManager.fileExists(atPath: oldDBFile.path) else {
            AppLogDebug("No old database found, skipping migration")
            return
        }

        let newDBFile = newDir.appendingPathComponent("LocalStore.sqlite")
        if fileManager.fileExists(atPath: newDBFile.path) {
            AppLogDebug("New database already exists, skipping migration")
            return
        }

        AppLogInfo("Migrating database from \(oldDir.path) to \(newDir.path)")

        do {
            try fileManager.createDirectory(at: newDir, withIntermediateDirectories: true)

            let filesToMigrate = [
                "LocalStore.sqlite",
                "LocalStore.sqlite-shm",
                "LocalStore.sqlite-wal",
            ]

            for fileName in filesToMigrate {
                let oldFile = oldDir.appendingPathComponent(fileName)
                let newFile = newDir.appendingPathComponent(fileName)

                if fileManager.fileExists(atPath: oldFile.path) {
                    try fileManager.moveItem(at: oldFile, to: newFile)
                    AppLogDebug("Migrated: \(fileName)")
                }
            }

            AppLogInfo("Database migration completed successfully")
        } catch {
            AppLogError("Failed to migrate database: \(error)")
        }
    }
}

// MARK: - Database Utilities
extension LocalStore {
    func backupDatabase() -> URL? {
        let dbURL = userStorageURL.appendingPathComponent("LocalStore.sqlite")
        let backupURL = userStorageURL.appendingPathComponent("LocalStore_backup_\(Date().timeIntervalSince1970).sqlite")

        do {
            try FileManager.default.copyItem(at: dbURL, to: backupURL)
            AppLogInfo("[LocalStore] Database backed up to: \(backupURL.path)")
            return backupURL
        } catch {
            AppLogError("[LocalStore] Failed to backup database: \(error)")
            return nil
        }
    }
}

extension LocalStore {
    @MainActor
    func getAllPinnedTabs(
        for profileId: String,
        spaceId: String = LocalStore.defaultSpaceId
    ) -> [TabDataModel] {
        guard let context = mainContext else { return [] }
        do {
            return try pinnedTabs(
                profileId: profileId,
                spaceId: spaceId,
                scope: pinnedTabScope(in: context),
                in: context
            )
        } catch {
            AppLogError("Failed to fetch pinned tabs for profile \(profileId), Space \(spaceId): \(error)")
            return []
        }
    }

    // Read operations use the main context.
    @MainActor
    func getAllTabs() -> [TabDataModel] {
        guard let context = mainContext else { return [] }
        do {
            let request = TabDataModel.request(sortBy: [NSSortDescriptor(key: "index", ascending: true)])
            return try context.fetch(request)
        } catch {
            AppLogError("Failed to fetch tabs: \(error)")
            return []
        }
    }

    @MainActor
    func getTab(by guid: String) -> TabDataModel? {
        guard let context = mainContext else { return nil }
        do {
            let request = TabDataModel.request(NSPredicate(format: "guid == %@", guid))
            return try context.fetch(request).first
        } catch {
            AppLogError("Failed to fetch tab with guid \(guid): \(error)")
            return nil
        }
    }

    @MainActor
    func getTabs(by url: URL) -> [TabDataModel] {
        guard let context = mainContext else { return [] }
        do {
            let request = TabDataModel.request(
                NSPredicate(format: "url == %@", url as NSURL),
                sortBy: [NSSortDescriptor(key: "index", ascending: true)]
            )
            return try context.fetch(request)
        } catch {
            AppLogError("Failed to fetch tabs with url \(url): \(error)")
            return []
        }
    }

    @MainActor
    func getOpenTabs() -> [TabDataModel] {
        guard let context = mainContext else { return [] }
        do {
            let request = TabDataModel.request(
                NSPredicate(format: "isOpenned == YES"),
                sortBy: [NSSortDescriptor(key: "index", ascending: true)]
            )
            return try context.fetch(request)
        } catch {
            AppLogError("Failed to fetch open tabs: \(error)")
            return []
        }
    }

    func updateTabURL(_ guid: String, url: URL) {
        performBackgroundWrite { context in
            do {
                let request = TabDataModel.request(NSPredicate(format: "guid == %@", guid))
                if let tab = try context.fetch(request).first {
                    tab.url = url
                    tab.needUpdateMetaData = true
                    tab.updatedDate = Date()
                }
            } catch {
                AppLogError("[LocalStore] Failed to update tab URL: \(error)")
            }
        }
    }

    /// Update tab URL by guid using a URL string.
    /// - Parameters:
    ///   - guid: The guid of the tab in local database.
    ///   - urlString: New URL string to set for the tab.
    func updateTabURL(_ guid: String, urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            return
        }
        updateTabURL(guid, url: url)
    }

    func updateTabTitle(_ guid: String, title: String) {
        performBackgroundWrite { context in
            do {
                let request = TabDataModel.request(NSPredicate(format: "guid == %@", guid))
                if let tab = try context.fetch(request).first {
                    tab.title = title
                    tab.updatedDate = Date()
                }
            } catch {
                AppLogError("[LocalStore] Failed to update tab title: \(error)")
            }
        }
    }

    /// Sets the persisted split-partner guid on a pinned tab record. Pass nil
    /// to clear it (called when a split is unpinned or one half is destroyed).
    /// Writes happen on the background context, same as the other tab updates.
    func updateTabSplitPartner(_ guid: String, partnerGuid: String?) {
        performBackgroundWrite { context in
            do {
                let request = TabDataModel.request(NSPredicate(format: "guid == %@", guid))
                if let tab = try context.fetch(request).first {
                    if tab.splitPartnerGuid == partnerGuid {
                        return
                    }
                    tab.splitPartnerGuid = partnerGuid
                    tab.updatedDate = Date()
                }
            } catch {
                AppLogError("[LocalStore] Failed to update split partner: \(error)")
            }
        }
    }

    func updateLastSeen(_ guid: String, seenAt: Date = Date()) {
        performBackgroundWrite { context in
            do {
                let request = TabDataModel.request(NSPredicate(format: "guid == %@", guid))
                guard let tab = try context.fetch(request).first else {
                    return
                }
                switch tab.dataType {
                case .pinnedTab, .bookmark:
                    tab.lastSeen = seenAt
                    tab.updatedDate = seenAt
                case .tab, .bookmarkFolder:
                    return
                }
            } catch {
                AppLogError("[LocalStore] Failed to update last seen date: \(error)")
            }
        }
    }

    func updateTabFavicon(_ guid: String, favicon: Data) {
        performBackgroundWrite { context in
            do {
                let request = TabDataModel.request(NSPredicate(format: "guid == %@", guid))
                if let tab = try context.fetch(request).first {
                    if tab.favicon == favicon {
                        return
                    }
                    tab.favicon = favicon
                    tab.updatedDate = Date()
                }
            } catch {
                AppLogError("[LocalStore] Failed to update tab favicon: \(error)")
            }
        }
    }

    func deleteTab(_ tab: TabDataModel) {
        let guid = tab.guid
        performBackgroundWrite { context in
            do {
                let request = TabDataModel.request(NSPredicate(format: "guid == %@", guid))
                if let tabToDelete = try context.fetch(request).first {
                    context.delete(tabToDelete)
                }
            } catch {
                AppLogError("[LocalStore] Failed to delete tab: \(error)")
            }
        }
    }

    func deleteTab(by guid: String) {
        performBackgroundWrite { context in
            do {
                let request = TabDataModel.request(NSPredicate(format: "guid == %@", guid))
                if let tab = try context.fetch(request).first {
                    context.delete(tab)
                }
            } catch {
                AppLogError("[LocalStore] Failed to delete tab with guid \(guid): \(error)")
            }
        }
    }

    @MainActor
    private func saveMainContext() {
        guard let context = mainContext else { return }
        do {
            try context.save()
        } catch {
            AppLogError("[LocalStore] Failed to save main context: \(error)")
        }
    }

    func performBackgroundWrite(_ block: @escaping (NSManagedObjectContext) -> Void) {
        guard let writeContext else { return }
        writeJobContinuation?.yield {
            await writeContext.perform {
                block(writeContext)
                do {
                    try writeContext.save()
                } catch {
                    AppLogError("[LocalStore] save error: \(error)")
                    writeContext.rollback()
                }
            }
        }
    }

    func performBackgroundWriteAndWait(_ block: @escaping (NSManagedObjectContext) -> Void) async {
        guard let writeContext else { return }
        // Enqueue through the same FIFO stream so ordering relative to async
        // writes is preserved, then await this job's completion.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writeJobContinuation?.yield {
                await writeContext.perform {
                    block(writeContext)
                    do {
                        try writeContext.save()
                    } catch {
                        AppLogError("[LocalStore] save error: \(error)")
                        writeContext.rollback()
                    }
                }
                continuation.resume()
            }
        }
    }

    func performBackgroundWriteAndWaitThrowing<Result: Sendable>(
        _ block: @escaping (NSManagedObjectContext) throws -> Result
    ) async throws -> Result {
        guard let writeContext, let writeJobContinuation else {
            throw LocalStoreWriteError.storeUnavailable
        }
        return try await withCheckedThrowingContinuation { continuation in
            writeJobContinuation.yield {
                do {
                    let result = try await writeContext.perform {
                        do {
                            let result = try block(writeContext)
                            try writeContext.save()
                            return result
                        } catch {
                            writeContext.rollback()
                            throw error
                        }
                    }
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // Exposes the main context for UI-bound consumers.
    @MainActor
    func getMainContext() -> NSManagedObjectContext? {
        return mainContext
    }

    /// Checks whether a `NSManagedObjectContextDidSave` notification contains
    /// any inserted/updated/deleted object satisfying `predicate`.
    static func notificationContainsChanges(
        _ notification: Notification,
        matching predicate: (NSManagedObject) -> Bool
    ) -> Bool {
        guard let userInfo = notification.userInfo else { return false }
        for key in [NSInsertedObjectsKey, NSUpdatedObjectsKey, NSDeletedObjectsKey] {
            if let objects = userInfo[key] as? Set<NSManagedObject>,
               objects.contains(where: predicate) {
                return true
            }
        }
        return false
    }

    static func tabType(from object: NSManagedObject) -> Int? {
        guard object.entity.attributesByName["type"] != nil else {
            return nil
        }
        return object.value(forKey: "type") as? Int
    }

    @MainActor
    func pinnedTabsPublisher(
        for profileID: String,
        spaceId: String = LocalStore.defaultSpaceId
    ) -> AnyPublisher<[TabDataModel], Never> {
        guard mainContext != nil else {
            return Just([]).eraseToAnyPublisher()
        }

        let subject = CurrentValueSubject<[TabDataModel], Never>([])

        let fetchPinnedTabs = {
            self.getAllPinnedTabs(for: profileID, spaceId: spaceId)
        }

        // Dedup must compare value snapshots, not the fetched objects: a
        // refetch returns the same registered instances refreshed in place by
        // the saving context, so an object-based `removeDuplicates` compared
        // every object against itself and swallowed field edits — pinned
        // URL/title edits never reached the per-space subscribers.
        let initialTabs = fetchPinnedTabs()
        var lastSnapshot = initialTabs.map(PinnedTabSnapshot.init)
        subject.send(initialTabs)

        let notificationCenter = NotificationCenter.default
        let cancellable = notificationCenter
            .publisher(for: .NSManagedObjectContextDidSave)
            .filter {
                Self.notificationContainsChanges(
                    $0,
                    matching: {
                        if $0.entity.name == BrowserDataSettingsModel.entityName {
                            return true
                        }
                        return $0.entity.name == TabDataModel.entityName &&
                            Self.tabType(from: $0) == TabDataType.pinnedTab.rawValue
                    }
                )
            }
            .receive(on: DispatchQueue.main)
            .sink { _ in
                let updatedTabs = fetchPinnedTabs()
                let snapshot = updatedTabs.map(PinnedTabSnapshot.init)
                guard snapshot != lastSnapshot else { return }
                lastSnapshot = snapshot
                subject.send(updatedTabs)
            }

        return subject
            .handleEvents(receiveCancel: {
                cancellable.cancel()
            })
            .eraseToAnyPublisher()
    }
}

/// Value snapshot of a pinned-tab row used by `pinnedTabsPublisher` for
/// change detection across saves.
private struct PinnedTabSnapshot: Equatable {
    let guid: String
    let title: String
    let url: URL
    let index: Int
    let lastSeen: Date?
    let updatedDate: Date
    let splitPartnerGuid: String?
    let lineageId: String?
    let profileId: String?
    let spaceId: String?

    init(_ model: TabDataModel) {
        guid = model.guid
        title = model.title
        url = model.url
        index = model.index
        lastSeen = model.lastSeen
        updatedDate = model.updatedDate
        splitPartnerGuid = model.splitPartnerGuid
        lineageId = model.pinLineageId
        profileId = model.profileId
        spaceId = model.spaceId
    }
}

extension LocalStore {
    @MainActor
    func profile(with profileId: String, createIfNeeded: Bool = true) throws -> ProfileModel? {
        guard let context = mainContext else { return nil }
        return try profile(with: profileId, in: context, createIfNeeded: createIfNeeded)
    }

    @MainActor
    func upsertProfileDisplayNames(_ displayNamesByProfileId: [String: String]) {
        guard let context = mainContext, !displayNamesByProfileId.isEmpty else { return }

        do {
            var didChange = false
            for (profileId, rawDisplayName) in displayNamesByProfileId {
                let displayName = rawDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !profileId.isEmpty, !displayName.isEmpty,
                      let profile = try profile(with: profileId, in: context, createIfNeeded: true) else {
                    continue
                }
                if profile.displayName != displayName {
                    profile.displayName = displayName
                    didChange = true
                }
            }
            if didChange {
                try context.save()
            }
        } catch {
            AppLogError("[LocalStore] Failed to upsert profile display names: \(error)")
        }
    }

    func removePinnedTab(
        _ tab: Tab,
        profileId: String,
        spaceId: String = LocalStore.defaultSpaceId
    ) {
        guard let guid = tab.guidInLocalDB else { return }
        performBackgroundWrite { context in
            do {
                guard let activeTab = try self.activePinnedTab(
                    resolving: guid,
                    profileId: profileId,
                    spaceId: spaceId,
                    in: context
                ) else {
                    AppLogWarn("[LocalStore] Active pinned tab not found for removal: \(guid)")
                    return
                }
                context.delete(activeTab)
            } catch {
                AppLogError("[LocalStore] Failed to remove pinned tab: \(error)")
            }
        }
    }

    func deleteTab(_ localGuid: String) {
        performBackgroundWrite { context in
            do {
                let request = TabDataModel.request(NSPredicate(format: "guid == %@", localGuid))
                let results = try context.fetch(request)
                results.forEach { model in
                    context.delete(model)
                }
            } catch {
                AppLogError("[LocalStore] failed to delete tab: \(error.localizedDescription)")
            }
        }
    }

    /// Creates a pinned-tab record directly from a URL — the headless
    /// counterpart of `moveOrCreatePinnedTab`, which needs a live `Tab`.
    /// The record lands at `index` (clamped; appended when nil) in the active
    /// pinned-tab scope and reaches every covered window through
    /// `pinnedTabsPublisher`, where it shows as a closed pinned tab.
    func createPinnedTab(guid: String,
                         url: String,
                         title: String,
                         profileId: String,
                         spaceId: String = LocalStore.defaultSpaceId,
                         index: Int? = nil) {
        guard let parsedURL = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            AppLogWarn("[LocalStore] createPinnedTab: invalid URL \(url)")
            return
        }
        performBackgroundWrite { context in
            do {
                let scope = try self.pinnedTabScope(in: context)
                var pinnedTabs = try self.pinnedTabs(
                    profileId: profileId,
                    spaceId: spaceId,
                    scope: scope,
                    in: context
                )
                let now = Date()
                let model = TabDataModel(
                    insertInto: context,
                    title: title,
                    guid: guid,
                    index: 0,
                    url: parsedURL,
                    favicon: nil,
                    createdDate: now,
                    updatedDate: now
                )
                model.dataType = .pinnedTab
                model.isCreatedByChromium = false
                model.pinLineageId = guid
                try self.applyCurrentPinnedTabOwner(
                    profileId: profileId,
                    spaceId: spaceId,
                    to: model,
                    in: context
                )
                let insertIndex = min(max(index ?? pinnedTabs.count, 0), pinnedTabs.count)
                pinnedTabs.insert(model, at: insertIndex)
                for (position, tabModel) in pinnedTabs.enumerated() {
                    tabModel.index = position
                    tabModel.updatedDate = now
                }
            } catch {
                AppLogError("[LocalStore] Failed to create pinned tab: \(error)")
            }
        }
    }

    func moveOrCreatePinnedTab(_ tab: Tab,
                               after afterGuid: String?,
                               profileId: String,
                               spaceId: String = LocalStore.defaultSpaceId,
                               newGuid: String? = nil) {
        let tabGuid = tab.guidInLocalDB ?? UUID().uuidString
        let tabLineageId = tab.pinnedLineageId
        let tabTitle = tab.title
        let tabURL = tab.url
        performBackgroundWrite { context in
            do {
                let scope = try self.pinnedTabScope(in: context)
                var pinnedTabs = try self.pinnedTabs(
                    profileId: profileId,
                    spaceId: spaceId,
                    scope: scope,
                    in: context
                )
                let resolvedTabGuid = try self.activePinnedTab(
                    resolving: tabGuid,
                    profileId: profileId,
                    spaceId: spaceId,
                    in: context
                )?.guid
                let resolvedAfterGuid: String?
                if let afterGuid {
                    guard let activeAfterTab = try self.activePinnedTab(
                        resolving: afterGuid,
                        profileId: profileId,
                        spaceId: spaceId,
                        in: context
                    ) else {
                        AppLogWarn("[LocalStore] Active after tab not found: \(afterGuid)")
                        return
                    }
                    resolvedAfterGuid = activeAfterTab.guid
                } else {
                    resolvedAfterGuid = nil
                }

                var tabToMove: TabDataModel
                let now = Date()
                if let resolvedTabGuid,
                   let tabToMoveIndex = pinnedTabs.firstIndex(where: { $0.guid == resolvedTabGuid }) {
                    tabToMove = pinnedTabs.remove(at: tabToMoveIndex)
                } else {
                    guard tabLineageId == nil else {
                        AppLogWarn("[LocalStore] Active pinned tab not found for move: \(tabGuid)")
                        return
                    }
                    guard let urlStr = tabURL, let url = URL(string: urlStr) else {
                        AppLogWarn("[LocalStore] Invalid URL for new tab: \(tabURL ?? "nil")")
                        return
                    }

                    tabToMove = TabDataModel(
                        insertInto: context,
                        title: tabTitle,
                        guid: newGuid ?? UUID().uuidString,
                        index: 0,
                        url: url,
                        favicon: nil,
                        createdDate: now,
                        updatedDate: now
                    )
                    tabToMove.dataType = .pinnedTab
                    tabToMove.isCreatedByChromium = false
                    tabToMove.pinLineageId = tabLineageId ?? tabToMove.guid
                    AppLogInfo("[LocalStore] Created new pinned tab with guid: \(tabGuid)")
                }

                if tabToMove.pinLineageId == nil {
                    tabToMove.pinLineageId = tabToMove.guid
                }
                try self.applyCurrentPinnedTabOwner(
                    profileId: profileId,
                    spaceId: spaceId,
                    to: tabToMove,
                    in: context
                )

                let insertIndex: Int
                if let resolvedAfterGuid {
                    if let afterIndex = pinnedTabs.firstIndex(where: { $0.guid == resolvedAfterGuid }) {
                        insertIndex = afterIndex + 1
                    } else {
                        AppLogWarn("[LocalStore] After tab not found: \(resolvedAfterGuid)")
                        return
                    }
                } else {
                    insertIndex = 0
                }

                pinnedTabs.insert(tabToMove, at: insertIndex)

                for (index, tabModel) in pinnedTabs.enumerated() {
                    tabModel.index = index
                    tabModel.updatedDate = now
                }

            } catch {
                AppLogError("[LocalStore] Failed to move tab: \(error)")
            }
        }
    }

    func profile(with profileId: String, in context: NSManagedObjectContext, createIfNeeded: Bool) throws -> ProfileModel? {
        let request = ProfileModel.request(NSPredicate(format: "profileId == %@", profileId))
        let profiles: [ProfileModel] = try context.fetch(request)
        if let existingProfile = profiles.first {
            return existingProfile
        }
        guard createIfNeeded else {
            return nil
        }
        return ProfileModel(insertInto: context, profileId: profileId)
    }
}

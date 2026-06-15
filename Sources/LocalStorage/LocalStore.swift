// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import AppKit
import SwiftData
import Combine

@ModelActor
actor LocalStoreActor {
    func perform(_ block: (ModelContext) -> Void) {
        block(modelContext)
        do {
            try modelContext.save()
        } catch {
            AppLogError("[LocalStore] save error: \(error)")
        }
    }
}

class LocalStore {
    static let defaultProfileId = "Default"
    static let compatibilityConfiguration = LocalStoreCompatibilityConfiguration(
        currentStoreFormatVersion: 6,
        readableStoreFormatVersions: 1...6,
        storeFilename: "LocalStore.sqlite"
    )

    private(set) var container: ModelContainer?
    let account: Account
    private let userStorageURL: URL
    private var cancellable: AnyCancellable?
    private let writeActor: LocalStoreActor?

    /// Serial FIFO queue for background writes. `writeActor` serializes write
    /// *execution*, but `performBackgroundWrite` previously dispatched each
    /// write as an independent `Task`, and unstructured tasks carry no
    /// guarantee of reaching the actor in submission order. A "create record"
    /// write could therefore land after a follow-up "update field" write that
    /// targets it, and the update would silently no-op (its fetch finds no
    /// row). This broke pinned-split pairing: the `splitPartnerGuid` set right
    /// after the two pinned rows were created would sometimes apply before the
    /// rows existed, leaving the pair unlinked and rendering as two cells once
    /// the live SplitGroup went away (e.g. on close). Funnelling every write
    /// through this stream restores submit-order == apply-order, which every
    /// caller already assumes.
    private let writeJobContinuation: AsyncStream<() async -> Void>.Continuation?
    private(set) var compatibilityStatus: LocalStoreCompatibilityStatus = .notChecked

    @MainActor var mainContext: ModelContext? {
        container?.mainContext
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
            writeActor = nil
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
            writeActor = nil
            writeJobContinuation = nil
            if presentsCompatibilityAlerts {
                Self.runRequiresNewerAppAlert()
            }
            return
        }
        
        let configuration = ModelConfiguration(url: userStorageURL.appendingPathComponent("LocalStore.sqlite"))
        
        do {
            let modelContainer = try ModelContainer(
                for: TabDataModel.self,
                ProfileModel.self,
                migrationPlan: TabDataModelMigrationPlan.self,
                configurations: configuration
            )
            container = modelContainer
            let actor = LocalStoreActor(modelContainer: modelContainer)
            writeActor = actor
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
            AppLogError("Failed to create ModelContainer: \(error)")
            container = nil
            writeActor = nil
            writeJobContinuation = nil
        }
    }

    private static func runRequiresNewerAppAlert() {
        Task { @MainActor in
            let alert = NSAlert()
            alert.messageText = NSLocalizedString(
                "Update Phi to Open Local Data",
                comment: "Local store compatibility alert - title when the local database was opened by a newer app version"
            )
            alert.informativeText = NSLocalizedString(
                "This version of Phi cannot open local browser data that was updated by a newer version. Install the latest Phi version and try again.",
                comment: "Local store compatibility alert - body when a newer app is required to read local data"
            )
            alert.alertStyle = .warning
            alert.addButton(withTitle: NSLocalizedString("OK", comment: "Generic - OK button to dismiss an alert"))
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
    func getAllPinnedTabs(for profileId: String) -> [TabDataModel] {
        guard let context = mainContext else { return [] }
        do {
            let pinnedRaw = TabDataType.pinnedTab.rawValue
            let sortBy: [SortDescriptor<TabDataModel>] = [SortDescriptor(\.index)]
            let descriptor = FetchDescriptor<TabDataModel>(
                predicate: #Predicate<TabDataModel> { tab in
                    tab.type == pinnedRaw && tab.profile?.profileId == profileId
                },
                sortBy: sortBy
            )
            return try context.fetch(descriptor)
        } catch {
            AppLogError("Failed to fetch pinned tabs for profile \(profileId): \(error)")
            return []
        }
    }

    // Read operations use the main context.
    @MainActor
    func getAllTabs() -> [TabDataModel] {
        guard let context = mainContext else { return [] }
        do {
            let sortBy: [SortDescriptor<TabDataModel>] = [SortDescriptor(\.index)]
            let descriptor = FetchDescriptor<TabDataModel>(sortBy: sortBy)
            return try context.fetch(descriptor)
        } catch {
            AppLogError("Failed to fetch tabs: \(error)")
            return []
        }
    }
    
    @MainActor
    func getTab(by guid: String) -> TabDataModel? {
        guard let context = mainContext else { return nil }
        do {
            let predicate = #Predicate<TabDataModel> { $0.guid == guid }
            let descriptor = FetchDescriptor<TabDataModel>(predicate: predicate)
            return try context.fetch(descriptor).first
        } catch {
            AppLogError("Failed to fetch tab with guid \(guid): \(error)")
            return nil
        }
    }
    
    @MainActor
    func getTabs(by url: URL) -> [TabDataModel] {
        guard let context = mainContext else { return [] }
        do {
            let predicate = #Predicate<TabDataModel> { $0.url == url }
            let sortBy: [SortDescriptor<TabDataModel>] = [SortDescriptor(\.index)]
            let descriptor = FetchDescriptor<TabDataModel>(predicate: predicate, sortBy: sortBy)
            return try context.fetch(descriptor)
        } catch {
            AppLogError("Failed to fetch tabs with url \(url): \(error)")
            return []
        }
    }
    
    @MainActor
    func getOpenTabs() -> [TabDataModel] {
        guard let context = mainContext else { return [] }
        do {
            let predicate = #Predicate<TabDataModel> { $0.isOpenned == true }
            let sortBy: [SortDescriptor<TabDataModel>] = [SortDescriptor(\.index)]
            let descriptor = FetchDescriptor<TabDataModel>(predicate: predicate, sortBy: sortBy)
            return try context.fetch(descriptor)
        } catch {
            AppLogError("Failed to fetch open tabs: \(error)")
            return []
        }
    }

    func updateTabURL(_ guid: String, url: URL) {
        performBackgroundWrite { context in
            do {
                let predicate = #Predicate<TabDataModel> { $0.guid == guid }
                let descriptor = FetchDescriptor<TabDataModel>(predicate: predicate)
                if let tab = try context.fetch(descriptor).first {
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
                let predicate = #Predicate<TabDataModel> { $0.guid == guid }
                let descriptor = FetchDescriptor<TabDataModel>(predicate: predicate)
                if let tab = try context.fetch(descriptor).first {
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
    /// Writes happen on the background actor, same as the other tab updates.
    func updateTabSplitPartner(_ guid: String, partnerGuid: String?) {
        performBackgroundWrite { context in
            do {
                let predicate = #Predicate<TabDataModel> { $0.guid == guid }
                let descriptor = FetchDescriptor<TabDataModel>(predicate: predicate)
                if let tab = try context.fetch(descriptor).first {
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
                let predicate = #Predicate<TabDataModel> { $0.guid == guid }
                let descriptor = FetchDescriptor<TabDataModel>(predicate: predicate)
                guard let tab = try context.fetch(descriptor).first else {
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
                let predicate = #Predicate<TabDataModel> { $0.guid == guid }
                let descriptor = FetchDescriptor<TabDataModel>(predicate: predicate)
                if let tab = try context.fetch(descriptor).first {
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
                let predicate = #Predicate<TabDataModel> { $0.guid == guid }
                let descriptor = FetchDescriptor<TabDataModel>(predicate: predicate)
                if let tabToDelete = try context.fetch(descriptor).first {
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
                let predicate = #Predicate<TabDataModel> { $0.guid == guid }
                let descriptor = FetchDescriptor<TabDataModel>(predicate: predicate)
                if let tab = try context.fetch(descriptor).first {
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
    
    func performBackgroundWrite(_ block: @escaping (ModelContext) -> Void) {
        guard let writeActor else { return }
        writeJobContinuation?.yield {
            await writeActor.perform(block)
        }
    }

    func performBackgroundWriteAndWait(_ block: @escaping (ModelContext) -> Void) async {
        guard let writeActor else { return }
        // Enqueue through the same FIFO stream so ordering relative to async
        // writes is preserved, then await this job's completion.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writeJobContinuation?.yield {
                await writeActor.perform(block)
                continuation.resume()
            }
        }
    }
    
    // Exposes the main context for UI-bound consumers.
    @MainActor
    func getMainContext() -> ModelContext? {
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
    func pinnedTabsPublisher(for profileID: String) -> AnyPublisher<[TabDataModel], Never> {
        guard mainContext != nil else {
            return Just([]).eraseToAnyPublisher()
        }
        
        let subject = CurrentValueSubject<[TabDataModel], Never>([])
        
        let fetchPinnedTabs = {
            self.getAllPinnedTabs(for: profileID)
        }
        
        subject.send(fetchPinnedTabs())
        
        let notificationCenter = NotificationCenter.default
        let cancellable = notificationCenter
            .publisher(for: .NSManagedObjectContextDidSave)
            .filter {
                Self.notificationContainsChanges(
                    $0,
                    matching: { $0.entity.name == TabDataModel.entityName &&
                        Self.tabType(from: $0) == TabDataType.pinnedTab.rawValue }
                )
            }
            .receive(on: DispatchQueue.main)
            .sink { _ in
                let updatedTabs = fetchPinnedTabs()
                subject.send(updatedTabs)
            }
        
        return subject
            .removeDuplicates { oldTabs, newTabs in
                guard oldTabs.count == newTabs.count else { return false }
                return zip(oldTabs, newTabs).allSatisfy { old, new in
                    old.guid == new.guid && 
                    old.title == new.title && 
                    old.index == new.index &&
                    old.lastSeen == new.lastSeen &&
                    old.updatedDate == new.updatedDate
                }
            }
            .handleEvents(receiveCancel: {
                cancellable.cancel()
            })
            .eraseToAnyPublisher()
    }
}

extension LocalStore {
    @MainActor
    func profile(with profileId: String, createIfNeeded: Bool = true) throws -> ProfileModel? {
        guard let context = mainContext else { return nil }
        return try profile(with: profileId, in: context, createIfNeeded: createIfNeeded)
    }

    func removePinnedTab(_ tab: Tab) {
        guard let guid = tab.guidInLocalDB else {
            return
        }
        deleteTab(guid)
        
    }
    
    func deleteTab(_ localGuid: String) {
        performBackgroundWrite { context in
            do {
                let predicate = #Predicate<TabDataModel> { $0.guid == localGuid }
                let descriptor = FetchDescriptor<TabDataModel>(predicate: predicate)
                let results = try context.fetch(descriptor)
                results.forEach { model in
                    context.delete(model)
                }
            } catch {
                AppLogError("[LocalStore] failed to delete tab: \(error.localizedDescription)")
            }
        }
    }
    
    func moveOrCreatePinnedTab(_ tab: Tab, after afterGuid: String?, profileId: String, newGuid: String? = nil) {
        let tabGuid = tab.guidInLocalDB ?? UUID().uuidString
        let tabTitle = tab.title
        let tabURL = tab.url
        performBackgroundWrite { context in
            do {
                guard let profile = try self.profile(with: profileId, in: context, createIfNeeded: true) else {
                    AppLogError("[LocalStore] Missing profile for pinned tab write: \(profileId)")
                    return
                }
                let pinnedRaw = TabDataType.pinnedTab.rawValue
                let pinnedPredicate = #Predicate<TabDataModel> {
                    $0.type == pinnedRaw && $0.profile?.profileId == profileId
                }
                let sortBy: [SortDescriptor<TabDataModel>] = [SortDescriptor(\.index)]
                let descriptor = FetchDescriptor<TabDataModel>(
                    predicate: pinnedPredicate,
                    sortBy: sortBy
                )
                var pinnedTabs = try context.fetch(descriptor)
                
                var tabToMove: TabDataModel
                let now = Date()
                if let tabToMoveIndex = pinnedTabs.firstIndex(where: { $0.guid == tabGuid }) {
                    tabToMove = pinnedTabs.remove(at: tabToMoveIndex)
                } else {
                    guard let urlStr = tabURL, let url = URL(string: urlStr) else {
                        AppLogWarn("[LocalStore] Invalid URL for new tab: \(tabURL ?? "nil")")
                        return
                    }
                    
                    tabToMove = TabDataModel(
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
                    tabToMove.profile = profile
                    tabToMove.profileId = profileId
                    context.insert(tabToMove)
                    AppLogInfo("[LocalStore] Created new pinned tab with guid: \(tabGuid)")
                }

                tabToMove.profile = profile
                tabToMove.profileId = profileId
                
                let insertIndex: Int
                if let afterGuid = afterGuid {
                    if let afterIndex = pinnedTabs.firstIndex(where: { $0.guid == afterGuid }) {
                        insertIndex = afterIndex + 1
                    } else {
                        AppLogWarn("[LocalStore] After tab not found: \(afterGuid)")
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

    func profile(with profileId: String, in context: ModelContext, createIfNeeded: Bool) throws -> ProfileModel? {
        let descriptor = FetchDescriptor<ProfileModel>(
            predicate: #Predicate<ProfileModel> { $0.profileId == profileId }
        )
        let profiles: [ProfileModel] = try context.fetch(descriptor)
        if let existingProfile = profiles.first {
            return existingProfile
        }
        guard createIfNeeded else {
            return nil
        }
        let profile = ProfileModel(profileId: profileId)
        context.insert(profile)
        return profile
    }
}

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
            // **回滚，与 `performThrowing` 同款。** `LocalStoreActor` 是一个
            // `@ModelActor`，整个进程的后台写共用它这**一个** `modelContext`；一次失败的
            // save 把那一批改动原样留在上下文里，于是此后每一次 save 都带着同一批坏对象
            // 重试并同样失败——一条 fire-and-forget 的 UI 写就此让**全部**后台写（同步落
            // 地也在内）持续失败，直到别处某个 throwing 写碰巧 rollback 了它。
            modelContext.rollback()
        }
    }

    func performThrowing<Result: Sendable>(
        _ block: (ModelContext) throws -> Result
    ) throws -> Result {
        do {
            let result = try block(modelContext)
            try modelContext.save()
            return result
        } catch {
            modelContext.rollback()
            throw error
        }
    }
}

class LocalStore {
    static let defaultProfileId = "Default"
    static let compatibilityConfiguration = LocalStoreCompatibilityConfiguration(
        currentStoreFormatVersion: 10,
        readableStoreFormatVersions: 1...10,
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
                SpaceModel.self,
                SpaceURLRule.self,
                BrowserDataSettingsModel.self,
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
                try self.updateTabSplitPartnerBody(guid, partnerGuid: partnerGuid, in: context)
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
    
    /// 一轮图标回填的若干条**合成一次**后台写（Phi sync M3-3 §8.2 / Task 10）。
    ///
    /// 与上面那条 `updateTabFavicon(_:favicon:)` 的区别有两处，两处都是必须的：
    ///  1. **一个事务**。逐条调那一条是 N 次 `performBackgroundWrite`，一轮 20 条就是 20 次
    ///     写事务，而这些字节全是同一轮回填的产物。
    ///  2. **会抛**。那一条是 fire-and-forget 的，调用方看不出写成没成；回填队列要据此把
    ///     这一批记成成功还是失败。
    ///
    /// 与被写行完全相同的字节跳过（不写 `updatedDate`），于是一次重复回填不会在 UI 上
    /// 制造一批假的「刚刚更新」。
    func updateTabFaviconsThrowing(_ writes: [(guid: String, favicon: Data)]) async throws {
        guard !writes.isEmpty else { return }
        try await performBackgroundWriteAndWaitThrowing { context in
            for write in writes {
                let guid = write.guid
                let predicate = #Predicate<TabDataModel> { $0.guid == guid }
                let descriptor = FetchDescriptor<TabDataModel>(predicate: predicate)
                guard let tab = try context.fetch(descriptor).first else { continue }
                if tab.favicon == write.favicon { continue }
                tab.favicon = write.favicon
                tab.updatedDate = Date()
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

    func performBackgroundWriteAndWaitThrowing<Result: Sendable>(
        _ block: @escaping (ModelContext) throws -> Result
    ) async throws -> Result {
        guard let writeActor, let writeJobContinuation else {
            throw LocalStoreWriteError.storeUnavailable
        }
        return try await withCheckedThrowingContinuation { continuation in
            writeJobContinuation.yield {
                do {
                    let result = try await writeActor.performThrowing(block)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
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

    // MARK: - 整账户的变化信号（M3-3 §5.7）
    //
    // 与上面那个 `pinnedTabsPublisher` 以及 `bookmarksPublisher(profileId:spaceId:)` 是
    // 两类东西，别把它们混成一个：
    //
    // - **作用域**。那两个是按 (profile, space) 的，每个窗口订阅一份，下游是 UI；这两个是
    //   整账户的一条信号，下游是同步引擎。改那两个的语义会波及全部 UI，所以这里是**新增
    //   兄弟**，一个字节都不碰既有那两个。
    // - **载荷**。那两个交出当前值（`[TabDataModel]`）；这两个交出的是 `Void`——引擎要的是
    //   「有东西变了」，拿到之后自己按注册清单去读快照。
    // - **订阅当刻不发**。`spacesPublisher` / `bookmarksPublisher` 的上游是
    //   `CurrentValueSubject` 并在订阅当刻立刻 `send(fetch())`，因为 UI 需要一个初值。变化
    //   通知不需要，照抄那个形状就是每次挂上订阅都白推一轮。
    //
    // 去重比的是**取值快照数组**，不是 model 对象：SwiftData 在保存的上下文里**就地刷新**
    // 同一批实例，所以一次重取拿回来的是上一次那些对象，按对象比较恒等、真实的字段编辑会
    // 被整个吞掉。`spacesPublisher`（LocalStore+Space.swift）与上面的 `PinnedTabSnapshot`
    // 都为此栽过跟头并留了注释。
    //
    // 快照**有意取成同步层那份的超集**：书签不做 canonical root 过滤，pin 不做作用域过滤。
    // 超集只会多发一次信号（引擎那一轮比下来零字段变化 ⇒ 零提交），而子集会**漏**掉真实的
    // 变化——同一个过滤口径在两处各写一遍、然后慢慢走偏，正是 §4.8 点名要躲的那件事。
    // 行的次序按 `guid` 排定：两次 fetch 都没有排序保证，不排就会有一批「同一批行、不同
    // 次序」的伪变化。
    //
    // **级的次序是「类型过滤 → 2 s 防抖 → 投影一次 → 去重」，防抖在投影之前**（§5.7 第 1
    // 条）。反过来（每条 save 各投影一遍、再按值去重）只塌掉**发射**、塌不掉**工作量**：
    // 一次导入或一次多行拖拽就是每条 save 一次全表 fetch、一次 map、一次排序，全在主 actor
    // 上。去重仍然留着，因为防抖只保证「安静了 2 秒」，不保证「真的变了」——favicon 回填照样
    // 起计时器，安静期过后那唯一一次投影比下来逐字节相同，于是什么都不发。

    /// 两条信号默认的防抖窗口。与 `PhiChromiumCoordinator.phiSyncPushDebounce` 是同一个 2 秒
    /// 窗口，但**有意各存一份**：把协调器那个常量引进 `LocalStorage` 就是一条新的跨层依赖，
    /// 而这一层本来就不认识那一层。窗口挪进 publisher 之后协调器那两条订阅不再自己防抖，
    /// 否则端到端延迟会变成 4 秒。
    ///
    /// 两个 publisher 都收一个 `debounceWindow` 参数并默认到它，**只为用例**：一条用例要么
    /// 量的是「窗口本身」（那就用默认值，别人改了常量它要跟着动），要么量的是窗口之外的性质
    /// （去重、过滤、作用域进不进快照），后者没有理由为每次断言各空转两秒。生产调用一律走
    /// 默认值。
    static let changeSignalDebounce: TimeInterval = 2

    /// 整账户的书签 / 文件夹变化信号（§5.7）。订阅当刻不发。
    ///
    /// 防抖在这里，不在协调器：一连串 save 要在**任何一次投影发生之前**塌掉。
    ///
    /// **必须在主线程订阅**（`Deferred` 体内有 `dispatchPrecondition`）。基线快照在订阅当刻
    /// 现取，而它读 `mainContext`；从别的线程订阅会在 SwiftData 的主上下文上并发读，那是
    /// 一类不会当场报错、只会偶尔交出半截数据的错误。协调器与用例都在主 actor 上订阅。
    ///
    /// **favicon、`lastSeen` 与 `updatedDate` 不进快照**，所以一次 `updateTabFavicon` /
    /// `updateLastSeen` 起了防抖计时器、但安静期过后那唯一一次投影比下来逐字节相同，什么都
    /// 不发。Task 10 的图标回填队列每写回一条就触发一次推送、而每次推送的内容与账户上的完全
    /// 相同，是这条规则挡掉的那个自激。
    ///
    /// 返回的 publisher **每次订阅各有一份基线**（`Deferred`）：基线是订阅当刻那一份快照，
    /// 同一个返回值被订两次就必须各自记各自的，否则第二个订阅者永远比不出差别、一个信号都
    /// 收不到。协调器在 `stopPhiSync()` 之后会重新挂订阅，所以这不是理论情形。
    @MainActor
    func bookmarkChangesPublisher(
        debounceWindow: TimeInterval = LocalStore.changeSignalDebounce
    ) -> AnyPublisher<Void, Never> {
        guard mainContext != nil else {
            return Empty(completeImmediately: true).eraseToAnyPublisher()
        }

        return Deferred { [weak self] () -> AnyPublisher<Void, Never> in
            dispatchPrecondition(condition: .onQueue(.main))
            guard let self else {
                return Empty(completeImmediately: true).eraseToAnyPublisher()
            }
            // 订阅当刻取一次基线，但**不发射**——它是「上一次的样子」，不是一次变化。
            var lastSnapshot = self.bookmarkChangeSnapshot()

            return NotificationCenter.default
                .publisher(for: .NSManagedObjectContextDidSave)
                .filter {
                    LocalStore.notificationContainsChanges(
                        $0,
                        matching: {
                            guard $0.entity.name == TabDataModel.entityName,
                                  let type = LocalStore.tabType(from: $0) else { return false }
                            return type == TabDataType.bookmark.rawValue ||
                                type == TabDataType.bookmarkFolder.rawValue
                        }
                    )
                }
                // **先上主队列，再防抖。** 通知是保存那个上下文的线程发的（写走后台 actor），
                // 而 `debounce` 是有状态的：它自己攒着「上一个值」与一只计时器。让它在若干条
                // 后台线程上收值，就是在无锁状态上并发读写。上面那个 `filter` 不怕，它只碰两个
                // 静态纯函数。
                .receive(on: DispatchQueue.main)
                .debounce(for: .seconds(debounceWindow), scheduler: DispatchQueue.main)
                .compactMap { [weak self] _ -> Void? in
                    // 读不出来就**不发信号**，绝不当成「全没了」：下游是一次推送轮，而 §4.7
                    // 的差分对空集合的回答是给每一条游标发 tombstone。
                    guard let self else { return nil }
                    guard let snapshot = self.bookmarkChangeSnapshot() else { return nil }
                    guard snapshot != lastSnapshot else { return nil }
                    lastSnapshot = snapshot
                    return ()
                }
                .eraseToAnyPublisher()
        }
        .eraseToAnyPublisher()
    }

    /// 整账户的 pin 变化信号（§5.7）。订阅当刻不发；每次订阅各有一份基线、必须在主线程订阅，
    /// 两条理由都同上。
    ///
    /// 过滤器把 `BrowserDataSettingsModel` 算进来，与 `pinnedTabsPublisher` 今天那条同款：
    /// 作用域一翻，同一批物理行里「同步层认领哪些」整个换一遍，而那次 save 碰的不是
    /// `TabDataModel`。作用域本身也进快照，否则一次纯翻转在行上看不出任何差别。
    @MainActor
    func pinnedTabChangesPublisher(
        debounceWindow: TimeInterval = LocalStore.changeSignalDebounce
    ) -> AnyPublisher<Void, Never> {
        guard mainContext != nil else {
            return Empty(completeImmediately: true).eraseToAnyPublisher()
        }

        return Deferred { [weak self] () -> AnyPublisher<Void, Never> in
            dispatchPrecondition(condition: .onQueue(.main))
            guard let self else {
                return Empty(completeImmediately: true).eraseToAnyPublisher()
            }
            var lastSnapshot = self.pinnedTabChangeSnapshot()

            return NotificationCenter.default
                .publisher(for: .NSManagedObjectContextDidSave)
                .filter {
                    LocalStore.notificationContainsChanges(
                        $0,
                        matching: {
                            if $0.entity.name == BrowserDataSettingsModel.entityName {
                                return true
                            }
                            return $0.entity.name == TabDataModel.entityName &&
                                LocalStore.tabType(from: $0) == TabDataType.pinnedTab.rawValue
                        }
                    )
                }
                // 先上主队列再防抖，理由同书签那条。
                .receive(on: DispatchQueue.main)
                .debounce(for: .seconds(debounceWindow), scheduler: DispatchQueue.main)
                .compactMap { [weak self] _ -> Void? in
                    guard let self else { return nil }
                    guard let snapshot = self.pinnedTabChangeSnapshot() else { return nil }
                    guard snapshot != lastSnapshot else { return nil }
                    lastSnapshot = snapshot
                    return ()
                }
                .eraseToAnyPublisher()
        }
        .eraseToAnyPublisher()
    }

    /// nil = 这一刻读不出来。调用方把它当成「不知道」，不是「一条都没有」。
    @MainActor
    private func bookmarkChangeSnapshot() -> [BookmarkChangeSnapshot]? {
        guard let context = mainContext else { return nil }
        do {
            return try allBookmarkModels(in: context)
                .map(BookmarkChangeSnapshot.init)
                .sorted { $0.guid < $1.guid }
        } catch {
            // R12：只记类型与 domain/code，一个行内容的字节都不记。
            AppLogError("[phi-sync] bookmark change snapshot failed: \(PhiSyncLog.describe(error))")
            return nil
        }
    }

    /// 同上。作用域读失败也算「不知道」——把它回落成 `.profile` 会在一台 Space 作用域的
    /// 机器上伪造出一次作用域翻转。
    ///
    /// **不走 `pinSyncFetch(in:)`**：那个函数自己再读一次作用域，还要按 `(ownerKey, index,
    /// guid)` 排出一份 `active` 数组——而 owner 是每次比较现算的。这里要的是**未经作用域
    /// 过滤**的那一半，那份排序整个是白做的。所以作用域读一次，行集合走两边共用的
    /// `nonDormantPinModels(in:)`——那条判据必须只有一份，理由写在它自己身上。
    @MainActor
    private func pinnedTabChangeSnapshot() -> PinnedTabChangeSnapshot? {
        guard let context = mainContext else { return nil }
        do {
            let scope = try pinnedTabScope(in: context)
            let rows = try nonDormantPinModels(in: context)
                .map(PinnedTabRowChangeSnapshot.init)
                .sorted { $0.guid < $1.guid }
            return PinnedTabChangeSnapshot(scope: scope, rows: rows)
        } catch {
            AppLogError("[phi-sync] pin change snapshot failed: \(PhiSyncLog.describe(error))")
            return nil
        }
    }
}

/// 一条书签 / 文件夹行在**同步层眼里**的取值快照（§5.7）。字段照 `PhiLocalBookmark`
/// 取，因为「变了没有」问的就是「引擎下一轮发出去的字节会不会不同」。
///
/// **`favicon` / `lastSeen` / `updatedDate` 有意不在这里**：前两个不是用户对内容的编辑，
/// 第三个每一次写都会动（`updateLastSeen` 与 `updateTabFavicon` 都写它）。
private struct BookmarkChangeSnapshot: Equatable {
    let syncId: String?
    let guid: String
    let spaceId: String?
    let profileId: String?
    let parentGuid: String?
    let index: Int
    let type: Int
    let title: String
    let url: URL
    let secondaryUrl: URL?
    let secondaryTitle: String?
    let source: Int
    let createdDate: Date
    let contentUpdatedDate: Date?

    init(_ model: TabDataModel) {
        syncId = model.syncId
        guid = model.guid
        spaceId = model.spaceId
        profileId = model.profileId ?? model.profile?.profileId
        parentGuid = model.parent?.guid
        index = model.index
        type = model.type
        title = model.title
        url = model.url
        secondaryUrl = model.secondaryUrl
        secondaryTitle = model.secondaryTitle
        source = model.source
        createdDate = model.createdDate
        contentUpdatedDate = model.contentUpdatedDate
    }
}

/// 一条 pin 行的取值快照，字段照 `PhiLocalPin` 取。
///
/// `splitPartnerGuid` 而不是伙伴的 lineage：换算要第二张表，而伙伴行本身也在这个数组里，
/// 它改 lineage 的那一刻数组已经不同了——超集，不漏。
private struct PinnedTabRowChangeSnapshot: Equatable {
    let lineageId: String?
    let guid: String
    let spaceId: String?
    let profileId: String?
    let index: Int
    let title: String
    let url: URL
    let splitPartnerGuid: String?
    let source: Int
    let createdDate: Date
    let contentUpdatedDate: Date?
    let isDormant: Bool

    init(_ model: TabDataModel) {
        lineageId = model.pinLineageId
        guid = model.guid
        spaceId = model.spaceId
        profileId = model.profileId ?? model.profile?.profileId
        index = model.index
        title = model.title
        url = model.url
        splitPartnerGuid = model.splitPartnerGuid
        source = model.source
        createdDate = model.createdDate
        contentUpdatedDate = model.contentUpdatedDate
        isDormant = model.isPinnedTabDormant
    }
}

/// pin 侧比的是「作用域 + 行」这一对。行一个字节没动但作用域翻了，同步层认领的那一批就
/// 整个换了，所以它是快照的一部分而不是订阅之外的东西。
private struct PinnedTabChangeSnapshot: Equatable {
    let scope: PinnedTabScope
    let rows: [PinnedTabRowChangeSnapshot]
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
                try self.createPinnedTabBody(guid: guid,
                                             url: parsedURL,
                                             title: title,
                                             profileId: profileId,
                                             spaceId: spaceId,
                                             index: index,
                                             lineageId: nil,
                                             createdDate: nil,
                                             // 与今天逐字相同：`TabDataModel.source` 的
                                             // 默认值就是 0，这条路径从不设它。
                                             source: 0,
                                             in: context)
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
        // URL 的解析必须留在共享 body 的 create 分支里：提到这里会让「URL 非法但行已存在」
        // 的那一次**移动**也失败，而今天它是成功的。这里只做一次无副作用的转换。
        let tabURL = tab.url.flatMap { URL(string: $0) }
        performBackgroundWrite { context in
            do {
                try self.moveOrCreatePinnedTabBody(guid: tabGuid,
                                                   lineageId: tabLineageId,
                                                   title: tabTitle,
                                                   url: tabURL,
                                                   after: afterGuid,
                                                   profileId: profileId,
                                                   spaceId: spaceId,
                                                   newGuid: newGuid,
                                                   in: context)
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

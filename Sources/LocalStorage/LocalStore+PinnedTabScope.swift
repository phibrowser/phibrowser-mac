// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import SwiftData

enum PinnedTabScope: String, CaseIterable, Identifiable {
    case space
    case profile
    case app

    var id: String { rawValue }

    var hierarchyLevel: Int {
        switch self {
        case .space: 0
        case .profile: 1
        case .app: 2
        }
    }
}

// 写入失败的原因。**只有 `.storeUnavailable` 有文案**：它会上屏——
// `changePinnedTabScope` 失败时 `SpacesSettingsView` 把 `error.localizedDescription`
// 放进一个 `.critical` NSAlert 的 `informativeText`，而那条路径上
// `performBackgroundWriteAndWaitThrowing` 唯一的失败就是它。所以 `: LocalizedError`
// 与那条既有的 `errorDescription` 必须留着。
//
// 六个新 case **不带文案**：它们只在同步层内部流转（引擎接住之后按 §4.5 停放并记一条
// 元数据日志），从不显示给用户；给它们做本地化字符串等于往 xcstrings 里加六条永远不会
// 被渲染的 key，而每加一条都要走那条纯增量手工合并流程。
//
// 早先这里写着「一律无载荷，靠 Swift 给无载荷枚举自动合成 `Equatable`」。M3-3 的书签
// 落地需要 `spaceImporting` 带上是哪个 Space（引擎按 Space 停放），而带载荷的 case 会让
// 那条自动合成失效、连带打断既有用例里的每一次 `XCTAssertEqual`。因此**显式声明
// `: Equatable`**：行为与今天逐字相同（`String` 本身可比），只是不再依赖那条隐式规则。
enum LocalStoreWriteError: LocalizedError, Equatable {
    /// 本地库根本没打开（兼容性预检拒绝了它，或者 `ModelContainer` 建失败）。
    case storeUnavailable
    /// 按 guid 定位的那条物理行不存在（或者要求的父不存在 / 不是文件夹）。
    case rowNotFound
    /// 目标是某个 Profile / Space 的隐藏根文件夹，搬它或删它都会让书签树失去根。
    case rowIsRoot
    /// URL 归一化失败。
    case invalidURL
    /// 目标 Space 不可写：它被删了，或者中途换了 Profile。
    case targetNotWritable
    /// 一批候选行被逐条跳过之后一条都没剩下——空清单也算。调用方的 bug，不是一次成功
    /// 的空操作。
    case noCandidateSurvived
    /// 目标 guid 不在当前作用域里（pin 侧使用）。
    case rowNotInActiveScope
    /// 要删的那条文件夹底下还有这一批从没点名过的孩子（§4.5 / R-M3-3-17）。
    ///
    /// `TabDataModel.children` 带 `@Relationship(deleteRule: .cascade)`，所以一次
    /// `context.delete` 会把整棵子树无声地带走。R-M3-3-17 要求引擎先把每一个不该死的后代
    /// 删掉或提到 Space root；这条守卫把「引擎漏了一个」从**静默销毁用户数据**变成一次
    /// 整批回滚。本地独有、从没发布过的行（`syncId == nil`）正是最容易被漏掉的那一类。
    case folderNotEmpty
    /// 这条本机行已经带着**另一个**账户级身份了（§6.1 / §12.1 13d）。
    ///
    /// 覆盖写会让旧身份在本机瞬间失去对应行，而下一轮差分对「没有本机行」的回答是发一条
    /// tombstone——把对端那条实体删掉。一条行的身份只认领一次。
    case rowAlreadyMapped
    /// 这个 Space 正在被导入，本轮整批不落地（§4.9 第 3 条）。
    ///
    /// **与 `targetNotWritable` 分开**：那一个的含义是「Space 被删了或换了 Profile」，是结构
    /// 性失败；这一个是**瞬时**的，引擎该按停放处理、下一轮重试，两者混用会让 §11.2 的
    /// `parked` 计数说不清话。
    case spaceImporting(spaceId: String)

    var errorDescription: String? {
        switch self {
        case .storeUnavailable:
            return NSLocalizedString(
                "Local browser data is unavailable.",
                comment: "Pinned-tab scope migration error when the local store cannot be opened"
            )
        case .rowNotFound, .rowIsRoot, .invalidURL, .targetNotWritable,
             .noCandidateSurvived, .rowNotInActiveScope, .folderNotEmpty,
             .rowAlreadyMapped, .spaceImporting:
            // 同步层内部错误，从不上屏。
            return nil
        }
    }
}

private struct PinnedTabOwner: Hashable {
    let profileId: String?
    let spaceId: String?

    var sortKey: String {
        "\(profileId ?? "")\u{0}\(spaceId ?? "")"
    }
}

private struct PinnedTabContentSignature: Hashable {
    // Only fields that define the user-visible pinned item participate in
    // variant identity. Bookmark provenance/secondary fields are preserved on
    // the selected row but must not create indistinguishable pinned variants.
    let title: String
    let url: URL
}

private struct PinnedTabVariantSignature: Hashable {
    let content: PinnedTabContentSignature
    let splitPartnerLineageId: String?
    let splitPartnerContent: PinnedTabContentSignature?
}

private struct PinnedTabMergeCandidate {
    let source: TabDataModel
    let lineageId: String
    let signature: PinnedTabVariantSignature
    var sourceGuids: [String]
    var lastSeen: Date?
}

extension LocalStore {
    @MainActor
    func pinnedTabScope() -> PinnedTabScope {
        guard let context = mainContext else { return .profile }
        do {
            return try pinnedTabScope(in: context)
        } catch {
            AppLogError("[LocalStore] Failed to read pinned-tab scope: \(error)")
            return .profile
        }
    }

    /// Changes the store-wide pinned-tab scope and migrates all currently
    /// active collections in the same save. Moving to a narrower scope copies
    /// each parent collection to its existing children. Moving to a broader
    /// scope merges child collections, collapsing unchanged copies by lineage
    /// while preserving divergent variants as separate pinned tabs.
    func changePinnedTabScope(
        to newScope: PinnedTabScope,
        preferredProfileId: String? = nil,
        preferredSpaceId: String? = nil
    ) async throws {
        try await performBackgroundWriteAndWaitThrowing { context in
            let currentScope = try self.pinnedTabScope(in: context)
            guard currentScope != newScope else { return }

            try self.migratePinnedTabs(
                from: currentScope,
                to: newScope,
                preferredProfileId: preferredProfileId,
                preferredSpaceId: preferredSpaceId,
                in: context
            )
            let settings = try self.browserDataSettings(in: context, createIfNeeded: true)
            settings?.pinnedTabScopeRawValue = newScope.rawValue
        }
    }

    func pinnedTabScope(in context: ModelContext) throws -> PinnedTabScope {
        let settings = try browserDataSettings(in: context, createIfNeeded: false)
        return settings.flatMap { PinnedTabScope(rawValue: $0.pinnedTabScopeRawValue) } ?? .profile
    }

    func pinnedTabs(
        profileId: String,
        spaceId: String,
        scope: PinnedTabScope,
        in context: ModelContext
    ) throws -> [TabDataModel] {
        let pinnedRaw = TabDataType.pinnedTab.rawValue
        let sortBy = [SortDescriptor<TabDataModel>(\.index), SortDescriptor(\.guid)]
        let descriptor: FetchDescriptor<TabDataModel>
        switch scope {
        case .space:
            descriptor = FetchDescriptor(
                predicate: #Predicate<TabDataModel> {
                    $0.type == pinnedRaw &&
                    ($0.profileId == profileId || $0.profile?.profileId == profileId) &&
                    $0.spaceId == spaceId
                },
                sortBy: sortBy
            )
        case .profile:
            descriptor = FetchDescriptor(
                predicate: #Predicate<TabDataModel> {
                    $0.type == pinnedRaw &&
                    ($0.profileId == profileId || $0.profile?.profileId == profileId) &&
                    $0.spaceId == nil
                },
                sortBy: sortBy
            )
        case .app:
            descriptor = FetchDescriptor(
                predicate: #Predicate<TabDataModel> {
                    $0.type == pinnedRaw &&
                    $0.profileId == nil &&
                    $0.spaceId == nil
                },
                sortBy: sortBy
            )
        }
        return try context.fetch(descriptor)
    }

    func applyCurrentPinnedTabOwner(
        profileId: String,
        spaceId: String,
        to tab: TabDataModel,
        in context: ModelContext
    ) throws {
        let owner = Self.pinnedTabOwner(for: try pinnedTabScope(in: context),
                                        profileId: profileId,
                                        spaceId: spaceId)
        try applyPinnedTabOwner(owner, to: tab, in: context)
    }

    /// 一对 `(profileId, spaceId)` 在某个作用域下坐出来的归属。
    ///
    /// 抽出来只为让同步层的批次入口能算出「这一条 create 之后要重排哪个 owner」，而不必
    /// 把 `applyCurrentPinnedTabOwner` 里那个 switch 抄第二遍——两处分叉的后果是一批
    /// create 之后那个 owner 的 index 不被重排，于是同一个集合里出现重复 index。
    fileprivate static func pinnedTabOwner(for scope: PinnedTabScope,
                                           profileId: String,
                                           spaceId: String) -> PinnedTabOwner {
        switch scope {
        case .space:
            return PinnedTabOwner(profileId: profileId, spaceId: spaceId)
        case .profile:
            return PinnedTabOwner(profileId: profileId, spaceId: nil)
        case .app:
            return PinnedTabOwner(profileId: nil, spaceId: nil)
        }
    }

    /// Returns whether a pinned row belongs to the store's currently selected
    /// scope. Inactive rows are retained as migration backups, so callers that
    /// mutate by physical guid must reject them rather than reporting success
    /// after changing data that no window can currently see.
    @MainActor
    func isPinnedTabInActiveScope(_ tab: TabDataModel) -> Bool {
        guard tab.dataType == .pinnedTab, let context = mainContext else {
            return false
        }
        do {
            return pinnedTab(tab, belongsTo: try pinnedTabScope(in: context))
        } catch {
            AppLogError("[LocalStore] Failed to validate pinned-tab scope membership: \(error)")
            return false
        }
    }

    @MainActor
    func isPinnedTabInActiveScope(guid: String) -> Bool {
        guard let tab = getTab(by: guid) else { return false }
        return isPinnedTabInActiveScope(tab)
    }

    /// Resolves a physical pinned guid against the collection currently owned
    /// by the requested window. A scope migration retains its source rows as
    /// inactive backups and creates new physical rows, so a UI action queued
    /// during that handoff can still carry the old guid. Resolve that backup
    /// through lineage and the complete persisted variant instead of mutating
    /// the invisible source row or creating a duplicate in the new scope.
    func activePinnedTab(
        resolving guid: String,
        profileId: String,
        spaceId: String,
        in context: ModelContext
    ) throws -> TabDataModel? {
        let scope = try pinnedTabScope(in: context)
        let activeTabs = try pinnedTabs(
            profileId: profileId,
            spaceId: spaceId,
            scope: scope,
            in: context
        )
        if let exact = activeTabs.first(where: { $0.guid == guid }) {
            return exact
        }

        let pinnedRaw = TabDataType.pinnedTab.rawValue
        let sourceDescriptor = FetchDescriptor<TabDataModel>(
            predicate: #Predicate { $0.guid == guid && $0.type == pinnedRaw }
        )
        guard let source = try context.fetch(sourceDescriptor).first,
              !pinnedTab(source, belongsTo: scope) else {
            // A guid owned by another active Space/Profile must never be
            // redirected into this window's collection.
            return nil
        }

        let lineageId = source.pinLineageId ?? source.guid
        let lineageMatches = activeTabs.filter {
            ($0.pinLineageId ?? $0.guid) == lineageId
        }
        guard !lineageMatches.isEmpty else { return nil }

        let allPinned = try context.fetch(FetchDescriptor<TabDataModel>(
            predicate: #Predicate { $0.type == pinnedRaw }
        ))
        let rowsByGuid = Dictionary(uniqueKeysWithValues: allPinned.map { ($0.guid, $0) })
        let sourceSignature = pinnedTabVariantSignature(for: source, rowsByGuid: rowsByGuid)
        let exactVariants = lineageMatches.filter {
            pinnedTabVariantSignature(for: $0, rowsByGuid: rowsByGuid) == sourceSignature
        }
        if exactVariants.count == 1 {
            return exactVariants[0]
        }
        return lineageMatches.count == 1 ? lineageMatches[0] : nil
    }

    /// Updates a pinned record in the requested window's active owner. The
    /// owner-aware resolution keeps an edit sheet that straddles a scope
    /// migration from writing into the retained, invisible backup row.
    func updatePinnedTab(
        resolving guid: String,
        profileId: String,
        spaceId: String,
        url: URL,
        title: String?
    ) {
        performBackgroundWrite { context in
            do {
                guard let activeTab = try self.activePinnedTab(
                    resolving: guid,
                    profileId: profileId,
                    spaceId: spaceId,
                    in: context
                ) else {
                    AppLogWarn("[LocalStore] Active pinned tab not found for update: \(guid)")
                    return
                }
                activeTab.url = url
                activeTab.needUpdateMetaData = true
                if let title {
                    activeTab.title = title
                }
                activeTab.updatedDate = Date()
            } catch {
                AppLogError("[LocalStore] Failed to update pinned tab: \(error)")
            }
        }
    }

    /// Executes an Agent/API mutation only while its exact physical guid is
    /// still part of the selected scope. Unlike a window-owned UI action, an
    /// API call has no unambiguous child Space to target after a narrowing
    /// migration, so a stale guid must fail closed instead of touching backup
    /// data or guessing an owner.
    func updateActivePinnedTab(
        guid: String,
        url: URL?,
        title: String?
    ) {
        // 入口这一层的 no-op 守卫逐字保留：今天它在**排队之前**就返回，一次写都不入队、
        // 一条日志都不记。共享 body 里那条同义的守卫因此永远不会被这条路径踩到。
        guard url != nil || title != nil else { return }
        performBackgroundWrite { context in
            do {
                try self.updateActivePinnedTabBody(guid: guid, url: url, title: title, in: context)
            } catch {
                AppLogError("[LocalStore] Failed to update active pinned tab: \(error)")
            }
        }
    }

    /// Throwing sibling used ONLY by the sync layer (§4.9). 「guid 不在当前作用域」是
    /// fail-closed 的设计、不是 bug，但对同步层必须可见：fire-and-forget 入口那条静默
    /// `return` 与一次成功落地在调用方看来一模一样，于是引擎会为一次根本没发生的写入
    /// 落下 `reconciled` / `server` 基线——那条行此后既不会被差分判成删除（它还在），
    /// 也不会被快照重发（基线说它已同步）。
    func updateActivePinnedTabThrowing(
        guid: String,
        url: URL?,
        title: String?
    ) async throws {
        try await performBackgroundWriteAndWaitThrowing { context in
            try self.updateActivePinnedTabBody(guid: guid, url: url, title: title, in: context)
        }
    }

    /// Single implementation shared by both entry points.
    private func updateActivePinnedTabBody(
        guid: String,
        url: URL?,
        title: String?,
        in context: ModelContext
    ) throws {
        // 一个字段都没给是调用方的 bug，不是一次成功的空写。
        guard url != nil || title != nil else {
            throw LocalStoreWriteError.noCandidateSurvived
        }
        let pinnedRaw = TabDataType.pinnedTab.rawValue
        let descriptor = FetchDescriptor<TabDataModel>(
            predicate: #Predicate { $0.guid == guid && $0.type == pinnedRaw }
        )
        guard let tab = try context.fetch(descriptor).first else {
            throw LocalStoreWriteError.rowNotFound
        }
        guard pinnedTab(tab, belongsTo: try pinnedTabScope(in: context)) else {
            throw LocalStoreWriteError.rowNotInActiveScope
        }
        // 赋值一律无条件执行，与今天逐字相同——把「值没变」做成跳过会连 `needUpdateMetaData`
        // 一起跳过，那是 UI 行为的改变。`contentDidChange` 只决定 `contentUpdatedDate`。
        var contentDidChange = false
        if let url {
            if tab.url != url { contentDidChange = true }
            tab.url = url
            tab.needUpdateMetaData = true
        }
        if let title {
            if tab.title != title { contentDidChange = true }
            tab.title = title
        }
        let now = Date()
        // 只在内容字段真的变化时写（§4.9 第 0 条 / R-M3-3-26）：把标题改成同样文字的一次
        // 保存，不该让这一行赢下对端的编辑。两个入口都写，因为一次本机 UI 编辑与一次远端
        // 落地在「这一行的内容什么时候被改的」这件事上意义相同。
        if contentDidChange {
            tab.contentUpdatedDate = now
        }
        tab.updatedDate = now
    }

    func removeActivePinnedTab(guid: String) {
        performBackgroundWrite { context in
            do {
                try self.removeActivePinnedTabBody(guid: guid, in: context)
            } catch {
                AppLogError("[LocalStore] Failed to remove active pinned tab: \(error)")
            }
        }
    }

    /// Throwing sibling used ONLY by the sync layer (§4.9)，理由同
    /// `updateActivePinnedTabThrowing`。
    func removeActivePinnedTabThrowing(guid: String) async throws {
        try await performBackgroundWriteAndWaitThrowing { context in
            try self.removeActivePinnedTabBody(guid: guid, in: context)
        }
    }

    /// Single implementation shared by both entry points.
    private func removeActivePinnedTabBody(guid: String, in context: ModelContext) throws {
        let pinnedRaw = TabDataType.pinnedTab.rawValue
        let descriptor = FetchDescriptor<TabDataModel>(
            predicate: #Predicate { $0.guid == guid && $0.type == pinnedRaw }
        )
        guard let tab = try context.fetch(descriptor).first else {
            throw LocalStoreWriteError.rowNotFound
        }
        guard pinnedTab(tab, belongsTo: try pinnedTabScope(in: context)) else {
            throw LocalStoreWriteError.rowNotInActiveScope
        }
        context.delete(tab)
    }

    private func pinnedTabVariantSignature(
        for tab: TabDataModel,
        rowsByGuid: [String: TabDataModel]
    ) -> PinnedTabVariantSignature {
        let partner = tab.splitPartnerGuid.flatMap { rowsByGuid[$0] }
        return PinnedTabVariantSignature(
            content: contentSignature(for: tab),
            splitPartnerLineageId: partner.map { $0.pinLineageId ?? $0.guid },
            splitPartnerContent: partner.map { contentSignature(for: $0) }
        )
    }

    private func applyPinnedTabOwner(
        _ owner: PinnedTabOwner,
        to tab: TabDataModel,
        in context: ModelContext
    ) throws {
        tab.profileId = owner.profileId
        tab.spaceId = owner.spaceId
        if let profileId = owner.profileId {
            tab.profile = try profile(with: profileId, in: context, createIfNeeded: true)
        } else {
            tab.profile = nil
        }
    }

    private func browserDataSettings(
        in context: ModelContext,
        createIfNeeded: Bool
    ) throws -> BrowserDataSettingsModel? {
        let singletonId = BrowserDataSettingsModel.singletonId
        let descriptor = FetchDescriptor<BrowserDataSettingsModel>(
            predicate: #Predicate { $0.id == singletonId }
        )
        if let settings = try context.fetch(descriptor).first {
            return settings
        }
        guard createIfNeeded else { return nil }
        let settings = BrowserDataSettingsModel()
        context.insert(settings)
        return settings
    }

    private func migratePinnedTabs(
        from sourceScope: PinnedTabScope,
        to targetScope: PinnedTabScope,
        preferredProfileId: String?,
        preferredSpaceId: String?,
        in context: ModelContext
    ) throws {
        let pinnedRaw = TabDataType.pinnedTab.rawValue
        let allPinned = try context.fetch(FetchDescriptor<TabDataModel>(
            predicate: #Predicate { $0.type == pinnedRaw },
            sortBy: [SortDescriptor(\.index), SortDescriptor(\.guid)]
        ))
        let activeSourceRows = allPinned.filter { pinnedTab($0, belongsTo: sourceScope) }
        // A Profile collection with no Space cannot be represented while Space
        // scope is active. Its rows remain logically live even though their
        // physical owner still has Profile shape, so include them alongside the
        // visible Space collections when leaving Space scope. The persisted bit
        // distinguishes them from ordinary, stale Profile migration backups if
        // Spaces are created, deleted, or re-profiled before the next change.
        let dormantSourceRows = sourceScope == .space
            ? allPinned.filter {
                $0.isPinnedTabDormant && pinnedTab($0, belongsTo: .profile)
            }
            : []
        let sourceRows = activeSourceRows + dormantSourceRows
        let targetRows = allPinned.filter { pinnedTab($0, belongsTo: targetScope) }

        // Old rows for an inactive target scope are backups, not migration
        // input. Rebuild that target from the currently active scope so
        // switching back never resurrects stale edits. Deletion happens after
        // insertion because dormant Profile rows are both logical source rows
        // and physical rows in the Profile-shaped target collection.

        let targetOwners = try pinnedTabTargetOwners(
            for: targetScope,
            sourceRows: sourceRows,
            in: context
        )
        let lineageByGuid = Dictionary(
            uniqueKeysWithValues: sourceRows.map { ($0.guid, $0.pinLineageId ?? $0.guid) }
        )

        for owner in targetOwners.sorted(by: { $0.sortKey < $1.sortKey }) {
            let collections = sourceCollections(
                from: sourceRows,
                sourceScope: sourceScope,
                targetScope: targetScope,
                targetOwner: owner,
                preferredProfileId: preferredProfileId,
                preferredSpaceId: preferredSpaceId
            )
            let candidates = mergeCandidates(
                from: collections,
                lineageByGuid: lineageByGuid
            )
            try insertPinnedTabs(candidates, for: owner, in: context)
        }

        for row in targetRows {
            context.delete(row)
        }

        if sourceScope == .profile, targetScope == .space {
            let profileIdsWithSpaces = Set(
                try context.fetch(FetchDescriptor<SpaceModel>()).map(\.profileId)
            )
            for row in activeSourceRows {
                guard let profileId = row.profileId ?? row.profile?.profileId else {
                    row.isPinnedTabDormant = false
                    continue
                }
                row.isPinnedTabDormant = !profileIdsWithSpaces.contains(profileId)
            }
        } else {
            // Once a dormant collection has been represented in another active
            // scope, its retained physical rows become ordinary backups again.
            for row in dormantSourceRows where !targetRows.contains(where: { $0 === row }) {
                row.isPinnedTabDormant = false
            }
        }
    }

    private func pinnedTab(_ tab: TabDataModel, belongsTo scope: PinnedTabScope) -> Bool {
        switch scope {
        case .space:
            return tab.spaceId != nil
        case .profile:
            return (tab.profileId != nil || tab.profile != nil) && tab.spaceId == nil
        case .app:
            return tab.profileId == nil && tab.spaceId == nil
        }
    }

    private func pinnedTabTargetOwners(
        for scope: PinnedTabScope,
        sourceRows: [TabDataModel],
        in context: ModelContext
    ) throws -> Set<PinnedTabOwner> {
        switch scope {
        case .app:
            return [PinnedTabOwner(profileId: nil, spaceId: nil)]
        case .profile:
            let profiles = try context.fetch(FetchDescriptor<ProfileModel>())
            let profileIds = Set(profiles.map(\.profileId))
                .union(sourceRows.compactMap { $0.profileId ?? $0.profile?.profileId })
            return Set(profileIds.map { PinnedTabOwner(profileId: $0, spaceId: nil) })
        case .space:
            let spaces = try context.fetch(FetchDescriptor<SpaceModel>())
            return Set(spaces.map {
                PinnedTabOwner(profileId: $0.profileId, spaceId: $0.spaceId)
            })
        }
    }

    private func sourceCollections(
        from sourceRows: [TabDataModel],
        sourceScope: PinnedTabScope,
        targetScope: PinnedTabScope,
        targetOwner: PinnedTabOwner,
        preferredProfileId: String?,
        preferredSpaceId: String?
    ) -> [[TabDataModel]] {
        let relevantRows = sourceRows.filter { row in
            switch (sourceScope, targetScope) {
            case (.app, _), (_, .app):
                return true
            case (.profile, .space), (.space, .profile):
                return (row.profileId ?? row.profile?.profileId) == targetOwner.profileId
            default:
                return true
            }
        }
        let grouped = Dictionary(grouping: relevantRows) { row in
            owner(of: row, at: sourceScope)
        }
        let orderedOwners = grouped.keys.sorted { lhs, rhs in
            let lhsPreferred = isPreferred(
                lhs,
                scope: sourceScope,
                profileId: preferredProfileId,
                spaceId: preferredSpaceId
            )
            let rhsPreferred = isPreferred(
                rhs,
                scope: sourceScope,
                profileId: preferredProfileId,
                spaceId: preferredSpaceId
            )
            if lhsPreferred != rhsPreferred { return lhsPreferred }
            return lhs.sortKey < rhs.sortKey
        }
        return orderedOwners.map { owner in
            (grouped[owner] ?? []).sorted {
                if $0.index != $1.index { return $0.index < $1.index }
                return $0.guid < $1.guid
            }
        }
    }

    private func owner(of tab: TabDataModel, at scope: PinnedTabScope) -> PinnedTabOwner {
        switch scope {
        case .space:
            return PinnedTabOwner(profileId: tab.profileId ?? tab.profile?.profileId, spaceId: tab.spaceId)
        case .profile:
            return PinnedTabOwner(profileId: tab.profileId ?? tab.profile?.profileId, spaceId: nil)
        case .app:
            return PinnedTabOwner(profileId: nil, spaceId: nil)
        }
    }

    private func isPreferred(
        _ owner: PinnedTabOwner,
        scope: PinnedTabScope,
        profileId: String?,
        spaceId: String?
    ) -> Bool {
        switch scope {
        case .space:
            return owner.spaceId == spaceId
        case .profile:
            return owner.profileId == profileId
        case .app:
            return true
        }
    }

    private func mergeCandidates(
        from collections: [[TabDataModel]],
        lineageByGuid: [String: String]
    ) -> [PinnedTabMergeCandidate] {
        var candidates: [PinnedTabMergeCandidate] = []
        var candidateIndicesByLineage: [String: [Int]] = [:]

        for collection in collections {
            for source in collection {
                let lineageId = source.pinLineageId ?? source.guid
                let signature = PinnedTabVariantSignature(
                    content: contentSignature(for: source),
                    splitPartnerLineageId: source.splitPartnerGuid.flatMap { lineageByGuid[$0] },
                    splitPartnerContent: source.splitPartnerGuid
                        .flatMap { partnerGuid in
                            collections.lazy.flatMap { $0 }.first(where: { $0.guid == partnerGuid })
                        }
                        .map { contentSignature(for: $0) }
                )
                let matchingIndex = candidateIndicesByLineage[lineageId]?.first {
                    candidates[$0].signature == signature
                }
                if let matchingIndex {
                    candidates[matchingIndex].sourceGuids.append(source.guid)
                    if let lastSeen = source.lastSeen,
                       candidates[matchingIndex].lastSeen.map({ lastSeen > $0 }) ?? true {
                        candidates[matchingIndex].lastSeen = lastSeen
                    }
                    continue
                }

                let candidate = PinnedTabMergeCandidate(
                    source: source,
                    lineageId: lineageId,
                    signature: signature,
                    sourceGuids: [source.guid],
                    lastSeen: source.lastSeen
                )
                candidates.append(candidate)
                candidateIndicesByLineage[lineageId, default: []].append(candidates.count - 1)
            }
        }
        return candidates
    }

    // 合并键**只用可同步的字段**（R-M3-3-16）。
    //
    // favicon 曾经参与这个签名，而 `mergeCandidates` 只在签名相等时才合并同 lineage 的
    // 两份副本。D9 让 favicon 留在设备本地并各自回填（spec §8），所以两台机器对同一条 pin
    // 合法地持有**不同的**字节：同一次账户级作用域变更于是在 A 上合出 1 行、在 B 上合出
    // 2 行，两台机器的 pin 数量从此不同，且各自都认为自己是对的——没有任何计数器会变色。
    //
    // 去掉之后两台机器从同一批可同步字段算出同一个结果；万一仍有残差，也只会以「多落一条
    // 实体」的并集形式出现（两台都收到、都显示），而不会发散。
    private func contentSignature(for tab: TabDataModel) -> PinnedTabContentSignature {
        PinnedTabContentSignature(
            title: tab.title,
            url: tab.url
        )
    }

    private func insertPinnedTabs(
        _ candidates: [PinnedTabMergeCandidate],
        for owner: PinnedTabOwner,
        in context: ModelContext
    ) throws {
        var targetModels: [TabDataModel] = []
        var candidateIndexBySourceGuid: [String: Int] = [:]

        for (index, candidate) in candidates.enumerated() {
            let source = candidate.source
            let model = TabDataModel(
                title: source.title,
                guid: UUID().uuidString,
                index: index,
                url: source.url,
                favicon: source.favicon,
                createdDate: source.createdDate,
                updatedDate: source.updatedDate
            )
            model.dataType = .pinnedTab
            model.overrideTitle = source.overrideTitle
            model.isOpenned = false
            model.isCreatedByChromium = source.isCreatedByChromium
            model.needUpdateMetaData = source.needUpdateMetaData
            model.source = source.source
            model.secondaryUrl = source.secondaryUrl
            model.secondaryTitle = source.secondaryTitle
            model.lastSeen = candidate.lastSeen
            model.pinLineageId = candidate.lineageId
            try applyPinnedTabOwner(owner, to: model, in: context)
            context.insert(model)
            targetModels.append(model)
            for sourceGuid in candidate.sourceGuids {
                candidateIndexBySourceGuid[sourceGuid] = index
            }
        }

        for (index, candidate) in candidates.enumerated() {
            guard let partnerGuid = candidate.source.splitPartnerGuid,
                  let partnerIndex = candidateIndexBySourceGuid[partnerGuid] else {
                targetModels[index].splitPartnerGuid = nil
                continue
            }
            targetModels[index].splitPartnerGuid = targetModels[partnerIndex].guid
        }
    }
}

// MARK: - 同步层的 pin 读写口（§4.8 / §4.9）
//
// 这一段整体住在本文件里，不在 `LocalStore.swift`：`pinnedTab(_:belongsTo:)`、
// `owner(of:at:)`、`contentSignature(for:)` 这几个 helper 都是 `private`，而 Swift 的
// `private` 只对**同一个文件**里的其它 extension 可见。
extension LocalStore {
    /// 同步层每轮那**一次** pin fetch 的产物：快照与差分定义域出自同一批 models。
    ///
    /// 两者之间**没有第二个时刻**（L9）。跑两次查询的话，中间隔着至少一次 actor hop，
    /// 期间用户取消固定一条 pin，同一轮里它会既在快照里（当成活的发布）又不在定义域里
    /// （发 tombstone）。
    struct PinSyncFetch {
        /// 当前作用域内、**非休眠**的行，按 `(ownerKey, index, guid)` 有序——`allPins()`
        /// 的来源。
        let active: [TabDataModel]
        /// 同一批 fetch 里**未经作用域过滤**的非休眠行——`allPinIdentities()` 的来源
        /// （R-exec-4）。
        ///
        /// **少一层过滤、多一层过滤各有理由，两条都是有意的：**
        ///
        /// - 作用域过滤去掉了：一次作用域迁移把旧集合的物理行原地留下当备份
        ///   （`migratePinnedTabs` 只删**目标**作用域的旧行），它们大多 `isPinnedTabDormant
        ///   == false`。这些行在本机是真实存在的，只是同步层这一轮不认领它们。「同步层不
        ///   认领它」与「账户应该忘掉它」是两句不同的话——后者的回答是给每一条游标发
        ///   tombstone，一次作用域抖动就会删掉账户上整批 pin。
        /// - 休眠过滤留着了：`PhiLocalPin.isDormant` 的契约明写「休眠行不进快照，也不参与
        ///   差分」，于是「只剩休眠副本的 lineage」在差分眼里就是「本机没有这一行」并照常
        ///   产出 tombstone（spec §12.1 的 8b 第一句）。
        let nonDormant: [TabDataModel]
    }

    /// 一次 fetch（带 `\.profile` 预取）+ 一次作用域读，其余全在内存里。
    func pinSyncFetch(in context: ModelContext) throws -> PinSyncFetch {
        let pinnedRaw = TabDataType.pinnedTab.rawValue
        var descriptor = FetchDescriptor<TabDataModel>(
            predicate: #Predicate<TabDataModel> { $0.type == pinnedRaw }
        )
        // owner 推导要读 `profile?.profileId`；不预取就是每行一次 fault。
        descriptor.relationshipKeyPathsForPrefetching = [\.profile]
        let scope = try pinnedTabScope(in: context)
        let nonDormant = try context.fetch(descriptor).filter { !$0.isPinnedTabDormant }
        let active = nonDormant
            .filter { pinnedTab($0, belongsTo: scope) }
            .sorted { lhs, rhs in
                let lhsOwner = owner(of: lhs, at: scope)
                let rhsOwner = owner(of: rhs, at: scope)
                if lhsOwner.sortKey != rhsOwner.sortKey {
                    return lhsOwner.sortKey < rhsOwner.sortKey
                }
                if lhs.index != rhs.index { return lhs.index < rhs.index }
                return lhs.guid < rhs.guid
            }
        return PinSyncFetch(active: active, nonDormant: nonDormant)
    }

    /// 给同 owner 内的同 lineage 变体重铸 `pinLineageId`（§7.2 / A11）。
    ///
    /// 「变宽」方向的迁移会在同一个 owner 下留下两条共享 lineage 的活动行（内容分歧的
    /// 变体），而它们**不是**同一条实体的两个副本——它们是用户看得见的两个固定标签页。
    /// 按「一条实体、多个物理副本」处理会留下一整类永远同步不了的行：第二个副本没有自己的
    /// 身份，既到不了别的机器，也无法被别的机器删除，而每一个计数器都读健康值。
    ///
    /// 它是一次**本地写**，所以它属于那一轮的 `PinApplyBatch`、与落地同一个事务，
    /// **不在 push 段那个只读的 pre-pass 里**（W14）。
    ///
    /// 没有 fire-and-forget 兄弟：没有任何 UI 路径会改一行的 lineage。
    func relineagePinnedTabThrowing(guid: String, newLineageId: String) async throws {
        try await performBackgroundWriteAndWaitThrowing { context in
            try self.relineagePinnedTabBody(guid: guid, newLineageId: newLineageId, in: context)
        }
    }

    private func relineagePinnedTabBody(
        guid: String,
        newLineageId: String,
        in context: ModelContext
    ) throws {
        let pinnedRaw = TabDataType.pinnedTab.rawValue
        let descriptor = FetchDescriptor<TabDataModel>(
            predicate: #Predicate { $0.guid == guid && $0.type == pinnedRaw }
        )
        guard let tab = try context.fetch(descriptor).first else {
            throw LocalStoreWriteError.rowNotFound
        }
        // 分组的来源是那一轮 `pinSyncFetch(in:).active` 的结果，所以定义域一致：
        // 作用域外的备份行与休眠行都不参与重铸。
        guard !tab.isPinnedTabDormant,
              pinnedTab(tab, belongsTo: try pinnedTabScope(in: context)) else {
            throw LocalStoreWriteError.rowNotInActiveScope
        }
        guard tab.pinLineageId != newLineageId else { return }
        tab.pinLineageId = newLineageId
        // 身份不是内容：`contentUpdatedDate` 不碰（§4.9 第 0 条）。
        tab.updatedDate = Date()
    }

    /// Throwing sibling used ONLY by the sync layer (§4.9)。比 fire-and-forget 入口多两个
    /// 参数：`lineageId`（线上身份的一半，落地必须原样写回、不能重铸）与 `createdDate`
    /// （`created_at_ms` 按 `min()` 合并之后要真的落到行上）。
    ///
    /// `url` 收 `URL` 而不是 `String`，因此根本不经过入口那一步 `URL(string:)`（§4.9 第 2 条）。
    ///
    /// `source` 是 `PhiPinTabEntity` 的字段 8（`TabSource` 的 raw value），`PinKind.merge`
    /// 按「取非零一侧、都非零取较小者」合并它。缺这个参数，一条远端 pin 落地时它只能落成
    /// 默认值 0，下一轮的快照把 0 当成本机的值发回去，把对端记录的导入来源抹掉。
    ///
    /// `contentUpdatedDate` 同理（R-exec-5，与书签的 `BulkBookmarkInsert` 是同一件事）：
    /// 缺它的话一条远端 pin 落地时那一列是 nil，下一轮快照拿 `contentUpdatedDate ??
    /// createdDate` 当本机比较戳，取到的是**落地那一刻**的 `createdDate`，比对端真正的编辑
    /// 时间晚得多——刚落地的那条 pin 于是在下一次字段冲突里凭「我比较新」赢下对端的真实编辑。
    func createPinnedTabThrowing(guid: String,
                                 url: URL,
                                 title: String,
                                 profileId: String,
                                 spaceId: String = LocalStore.defaultSpaceId,
                                 index: Int? = nil,
                                 lineageId: String? = nil,
                                 createdDate: Date? = nil,
                                 source: Int = 0,
                                 contentUpdatedDate: Date? = nil) async throws {
        try await performBackgroundWriteAndWaitThrowing { context in
            try self.createPinnedTabBody(guid: guid,
                                         url: url,
                                         title: title,
                                         profileId: profileId,
                                         spaceId: spaceId,
                                         index: index,
                                         lineageId: lineageId,
                                         createdDate: createdDate,
                                         source: source,
                                         contentUpdatedDate: contentUpdatedDate,
                                         in: context)
        }
    }

    /// Single implementation shared by both entry points.
    func createPinnedTabBody(guid: String,
                             url: URL,
                             title: String,
                             profileId: String,
                             spaceId: String,
                             index: Int?,
                             lineageId: String?,
                             createdDate: Date?,
                             source: Int,
                             contentUpdatedDate: Date? = nil,
                             in context: ModelContext) throws {
        let scope = try pinnedTabScope(in: context)
        var activePins = try pinnedTabs(
            profileId: profileId,
            spaceId: spaceId,
            scope: scope,
            in: context
        )
        let now = Date()
        let model = TabDataModel(
            title: title,
            guid: guid,
            index: 0,
            url: url,
            favicon: nil,
            createdDate: createdDate ?? now,
            updatedDate: now
        )
        model.dataType = .pinnedTab
        model.isCreatedByChromium = false
        model.pinLineageId = lineageId ?? guid
        model.source = source
        // nil 就留 nil：`PhiLocalPin.contentUpdatedDate` 的契约是「nil = 从未改过内容」，
        // 拿 `now` 顶上去会把每一条本机新建的 pin 都伪装成刚被编辑过。
        model.contentUpdatedDate = contentUpdatedDate
        try applyCurrentPinnedTabOwner(
            profileId: profileId,
            spaceId: spaceId,
            to: model,
            in: context
        )
        context.insert(model)
        let insertIndex = min(max(index ?? activePins.count, 0), activePins.count)
        activePins.insert(model, at: insertIndex)
        for (position, tabModel) in activePins.enumerated() {
            tabModel.index = position
            tabModel.updatedDate = now
        }
    }

    /// Throwing sibling used ONLY by the sync layer (§4.9)。fire-and-forget 入口收的是一个
    /// 活动 `Tab`，同步层手里没有；它在入口就把需要的四个值取出来，所以这里直接收那四个值。
    ///
    /// `url` 是 `URL?` 而不是 `String?`：解析必须留在 create 分支里做，把它提到入口会让
    /// 「URL 非法但行已存在」的那一次**移动**也失败，而今天它是成功的。
    func moveOrCreatePinnedTabThrowing(guid: String,
                                       lineageId: String?,
                                       title: String,
                                       url: URL?,
                                       after afterGuid: String?,
                                       profileId: String,
                                       spaceId: String = LocalStore.defaultSpaceId,
                                       newGuid: String? = nil) async throws {
        try await performBackgroundWriteAndWaitThrowing { context in
            try self.moveOrCreatePinnedTabBody(guid: guid,
                                               lineageId: lineageId,
                                               title: title,
                                               url: url,
                                               after: afterGuid,
                                               profileId: profileId,
                                               spaceId: spaceId,
                                               newGuid: newGuid,
                                               in: context)
        }
    }

    /// Single implementation shared by both entry points.
    ///
    /// 三条今天「记一条 warning 然后 return」的守卫在这里各变成一次 `throw`：对同步层它们
    /// 与成功落地无法区分，而引擎会为一次没发生的写落下基线（§4.9 / R-M3-3-14）。
    /// fire-and-forget 包装捕获并记录，数据侧的行为因此一字不变——`performBackgroundWrite`
    /// 不回滚，抛出点之前的改动照样落盘，与今天 `return` 时留下的状态逐字相同。
    func moveOrCreatePinnedTabBody(guid tabGuid: String,
                                   lineageId tabLineageId: String?,
                                   title tabTitle: String,
                                   url tabURL: URL?,
                                   after afterGuid: String?,
                                   profileId: String,
                                   spaceId: String,
                                   newGuid: String?,
                                   in context: ModelContext) throws {
        let scope = try pinnedTabScope(in: context)
        var activePins = try pinnedTabs(
            profileId: profileId,
            spaceId: spaceId,
            scope: scope,
            in: context
        )
        let resolvedTabGuid = try activePinnedTab(
            resolving: tabGuid,
            profileId: profileId,
            spaceId: spaceId,
            in: context
        )?.guid
        let resolvedAfterGuid: String?
        if let afterGuid {
            guard let activeAfterTab = try activePinnedTab(
                resolving: afterGuid,
                profileId: profileId,
                spaceId: spaceId,
                in: context
            ) else {
                throw LocalStoreWriteError.rowNotFound
            }
            resolvedAfterGuid = activeAfterTab.guid
        } else {
            resolvedAfterGuid = nil
        }

        var tabToMove: TabDataModel
        let now = Date()
        if let resolvedTabGuid,
           let tabToMoveIndex = activePins.firstIndex(where: { $0.guid == resolvedTabGuid }) {
            tabToMove = activePins.remove(at: tabToMoveIndex)
        } else {
            // 带 lineage 却解析不到活动行 = 这个 guid 属于**另一个**活动 owner，
            // `activePinnedTab` 显式拒绝了它（§7.2）。换 owner 不是一次移动，是旧 tag 的
            // tombstone 加新 tag 的 create。
            guard tabLineageId == nil else {
                throw LocalStoreWriteError.rowNotInActiveScope
            }
            guard let url = tabURL else {
                throw LocalStoreWriteError.invalidURL
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
            tabToMove.pinLineageId = tabLineageId ?? tabToMove.guid
            context.insert(tabToMove)
            AppLogInfo("[LocalStore] Created new pinned tab with guid: \(tabGuid)")
        }

        if tabToMove.pinLineageId == nil {
            tabToMove.pinLineageId = tabToMove.guid
        }
        try applyCurrentPinnedTabOwner(
            profileId: profileId,
            spaceId: spaceId,
            to: tabToMove,
            in: context
        )

        let insertIndex: Int
        if let resolvedAfterGuid {
            guard let afterIndex = activePins.firstIndex(where: { $0.guid == resolvedAfterGuid }) else {
                throw LocalStoreWriteError.rowNotFound
            }
            insertIndex = afterIndex + 1
        } else {
            insertIndex = 0
        }

        activePins.insert(tabToMove, at: insertIndex)

        for (index, tabModel) in activePins.enumerated() {
            tabModel.index = index
            tabModel.updatedDate = now
        }
    }

    /// Throwing sibling used ONLY by the sync layer (§4.9)。落地一条 `split_partner_uuid`
    /// 非空的 pin 时，两个方向的 `splitPartnerGuid` 必须在**同一个事务**里写完（§7.4）；
    /// `reconcilePinnedSplitPartners()` 帮不上忙，它遍历的是活动窗口里的 `SplitGroup`，
    /// 而一对由同步落地的拆分 pin 没有任何活动 group。
    func updateTabSplitPartnerThrowing(_ guid: String, partnerGuid: String?) async throws {
        try await performBackgroundWriteAndWaitThrowing { context in
            try self.updateTabSplitPartnerBody(guid, partnerGuid: partnerGuid, in: context)
        }
    }

    /// Single implementation shared by both entry points.
    ///
    /// 「值已经是它了」不是失败：行的状态与请求一致，基线照写是正确的。「行不存在」才是。
    ///
    /// 定位**只**认 pin 行（M5）。原先它按 guid 匹配任何一条 `TabDataModel` 并取一个无序
    /// fetch 的 `.first`，而 `pinnedTabRow(with:)` 的注释已经说明一条普通 tab 与一条 pin 可以
    /// 共享 guid 空间。落地批次是这个 body 的新调用方，把一条普通 tab 的 `splitPartnerGuid`
    /// 改写会让它在下一轮的 pin 快照里凭空出现。**UI 行为逐字不变**：`updateTabSplitPartner`
    /// 的每一个既有调用点（`BrowserState+Split.swift:309-310, 852-853, 900-904`、
    /// `BrowserState.swift:3217, 5906-5907`）的 guid 都是从 `pinnedTabs` 里取的，本来就只会是
    /// pin 行。
    func updateTabSplitPartnerBody(_ guid: String,
                                   partnerGuid: String?,
                                   in context: ModelContext) throws {
        let pinnedRaw = TabDataType.pinnedTab.rawValue
        let predicate = #Predicate<TabDataModel> { $0.guid == guid && $0.type == pinnedRaw }
        let descriptor = FetchDescriptor<TabDataModel>(predicate: predicate)
        guard let tab = try context.fetch(descriptor).first else {
            throw LocalStoreWriteError.rowNotFound
        }
        guard tab.splitPartnerGuid != partnerGuid else { return }
        tab.splitPartnerGuid = partnerGuid
        tab.updatedDate = Date()
    }

    // MARK: - 一轮远端落地的批次入口（R-exec-2 的 pin 版）

    /// 一轮远端落地的**全部** pin 操作，一个写块、一个事务。
    ///
    /// `ops` 已由 `PinApplyBatch` 排好序（① create / relineage / move ② update ③ delete），
    /// 这里**一条都不重排**。
    ///
    /// **不能由那几个 throwing 兄弟拼出来**（R-exec-2，与书签同一条理由）：它们各自开一个
    /// `performBackgroundWriteAndWaitThrowing` 块，N 条操作就是 N 个事务，部分成功于是成立
    /// ——引擎会为一批只落了一半的操作写下基线；而把它们套进这一个块里则会在串行写流上
    /// 自锁。共享的 body 是本文件的 `private`，所以这个入口住在**本文件**，不在同步层。
    ///
    /// 块内两件事与书签那边逐条对应：
    /// 1. **导入锁在写块内部再读一次**（§4.9 第 3 条）。轮首那次读只是优化，「读完之后导入
    ///    才开始」那个边沿只有在事务里重读才挡得住。占用中就整批抛 `spaceImporting`，事务
    ///    回滚，引擎下一轮重试。
    /// 2. **末尾按被触及的每个 owner 跑一次 index 重排**。pin 是**按 owner 分组**的，不是
    ///    按父——它没有父。一批操作可能反复动同一个 owner，每条各自那次重排只保证它自己
    ///    那一刻是稠密的。
    func applyPinSyncBatchThrowing(_ ops: [PinApplyOp]) async throws {
        guard !ops.isEmpty else { return }
        try await performBackgroundWriteAndWaitThrowing { context in
            try self.applyPinSyncBatchBody(ops, in: context)
        }
    }

    /// 事务体。分出来只为可读性，没有第二个调用方。
    private func applyPinSyncBatchBody(_ ops: [PinApplyOp], in context: ModelContext) throws {
        try refuseIfImportingPins(ops, in: context)

        let scope = try pinnedTabScope(in: context)
        // 被触及的 owner，末尾统一重排一次。**记归属值，不记 model**：同一批里一条行被删
        // 之后再读它的属性是未定义的。
        var touchedOwners = Set<PinnedTabOwner>()

        for op in ops {
            switch op {
            case .create(let row):
                // 四个参数一律**显式**传（§4.9 / R-exec-5）：`lineageId` 为 nil 会让 body
                // 自己铸一个新的 lineage，于是刚从账户落地的那条 pin 拿到一个线上没有的
                // 身份，下一轮被差分判成「本机新建」再发一次，账户上多出一条重复实体；
                // `source`、`createdDate` 与 `contentUpdatedDate` 同理会把对端记录的值抹成
                // 默认值，而最后那一个抹掉之后，这条 pin 下一轮的本机比较戳回落到落地时刻。
                let profileId = row.profileId ?? Self.defaultProfileId
                let spaceId = row.spaceId ?? Self.defaultSpaceId
                try createPinnedTabBody(guid: row.guid,
                                        url: row.url,
                                        title: row.title,
                                        profileId: profileId,
                                        spaceId: spaceId,
                                        index: row.index,
                                        lineageId: row.lineageId,
                                        createdDate: row.createdDate,
                                        source: row.source,
                                        contentUpdatedDate: row.contentUpdatedDate,
                                        in: context)
                touchedOwners.insert(Self.pinnedTabOwner(for: scope,
                                                         profileId: profileId,
                                                         spaceId: spaceId))

            case .relineage(let guid, let newLineageId):
                // 身份不是位置：重铸不动 index，所以这一条不进 `touchedOwners`。
                try relineagePinnedTabBody(guid: guid,
                                           newLineageId: newLineageId,
                                           in: context)

            case .move(let guid, let index):
                guard let tab = try pinnedTabRow(with: guid, in: context) else {
                    throw LocalStoreWriteError.rowNotFound
                }
                guard pinnedTab(tab, belongsTo: scope) else {
                    throw LocalStoreWriteError.rowNotInActiveScope
                }
                // 「值已经是它了」不是失败，也不该盖 `updatedDate`。`contentUpdatedDate`
                // 一律不动：位置不是内容（§4.9 第 0 条）。
                if tab.index != index {
                    tab.index = index
                    tab.updatedDate = Date()
                }
                touchedOwners.insert(owner(of: tab, at: scope))

            case .update(let guid, let fields):
                // 外层「改不改」，内层「改成什么」。`title` 的内层 nil 是「清空」——远端真
                // 的可以有一条空标题的 pin；`url` 的内层 nil 是「不动」：一条 pin 丢不掉
                // 它的 URL。
                let title = fields.title.map { $0 ?? "" }
                let url = fields.url.flatMap { $0 }
                let changesSplitPartner = fields.splitPartnerLineageId != nil
                // 一条什么都不改的补丁是调用方的 bug，不是一次成功的空写（M4）。判据是
                // **生效之后的**三个值，不是三个外层可选：`url` 的外层 some、内层 nil 表达
                // 的是「不动」，所以只带它的一条补丁同样什么都不改。这是批次里唯一一处
                // 「不抛错」曾经不等于「真的落地了」的地方，而 §4.9 的整套保证就建立在那
                // 句等价上。
                guard title != nil || url != nil || changesSplitPartner else {
                    throw LocalStoreWriteError.noCandidateSurvived
                }
                if title != nil || url != nil {
                    // 两个字段都没给时**不调**：共享 body 把那当成调用方的 bug 并抛
                    // `noCandidateSurvived`，而这里它只是「这一条补丁只动了拆分伙伴」。
                    try updateActivePinnedTabBody(guid: guid, url: url, title: title, in: context)
                }
                if let partnerLineageId = fields.splitPartnerLineageId {
                    try applyPinSplitPartnerBody(guid: guid,
                                                 partnerLineageId: partnerLineageId,
                                                 in: context)
                }

            case .delete(let guid):
                guard let tab = try pinnedTabRow(with: guid, in: context) else {
                    throw LocalStoreWriteError.rowNotFound
                }
                // 先记归属再删：删掉之后这条 model 的属性读起来是未定义的。
                touchedOwners.insert(owner(of: tab, at: scope))
                // 对半的反向链接在**同一个事务**里断掉（M6）。UI 路径从来配不出这一幕——它
                // 删一对拆分 pin 时两条一起删——但引擎会按 §7.2 只删一条（对端取消固定了
                // 其中一半）。留着那条链接，幸存的那一行就指着一条不存在的 guid：
                // `pinnedTabVariantSignature` 拿不到伙伴、作用域迁移把它当成一条普通 pin
                // 合并，而 UI 的合并单元格会去渲染一个查不到的对半。
                try clearSplitPartnerBackReferenceBody(of: tab, in: context)
                try removeActivePinnedTabBody(guid: guid, in: context)
            }
        }

        // §4.10 的投影按 owner 运行一次。`!$0.isDeleted` 与书签那边同一条理由：带待定变更
        // 的 fetch 会不会把同一个块里刚 `context.delete` 标过的行滤掉，取决于一条本里程碑
        // 没有跑过的 SwiftData 语义，而把一条死行编进号会在那个集合里留下一个空位。
        for touched in touchedOwners.sorted(by: { $0.sortKey < $1.sortKey }) {
            let rows = try pinnedTabs(profileId: touched.profileId ?? Self.defaultProfileId,
                                      spaceId: touched.spaceId ?? Self.defaultSpaceId,
                                      scope: scope,
                                      in: context)
                .filter { !$0.isDeleted }
            Self.normalizePinnedIndexes(for: rows)
        }
    }

    /// 稠密重编号。与书签那边的 `normalizeIndexes(for:)` 逐字同义——那一个住在
    /// `LocalStore+Bookmark.swift` 的 `private extension` 里，跨文件够不着。
    ///
    /// **只在 `index` 真的不同时才写**：无条件赋值会给整个集合盖一遍 `updatedDate`，而一次
    /// 本机重排本来只该动真正换了位置的那几行。
    private static func normalizePinnedIndexes(for rows: [TabDataModel]) {
        for (position, row) in rows.enumerated() where row.index != position {
            row.index = position
            row.updatedDate = Date()
        }
    }

    /// 本批次碰到的任何一个 Space 正在被导入 ⇒ 整批不落地（§4.9 第 3 条）。
    ///
    /// 四种按 guid 定位的操作身上只有 guid，所以它们的 Space 在**事务内**按行查，而不是让
    /// 调用方从一份轮首的快照里猜——那份快照到这一刻可能已经过期。
    ///
    /// Profile / App 作用域的 pin 没有 Space，那两种作用域下这道闸恒不触发，这是对的：
    /// `ImportTargetLock` 锁的是一个 Space。
    private func refuseIfImportingPins(_ ops: [PinApplyOp], in context: ModelContext) throws {
        var spaceIds = Set<String>()
        for op in ops {
            switch op {
            case .create(let row):
                if let spaceId = row.spaceId { spaceIds.insert(spaceId) }
            case .relineage(let guid, _), .move(let guid, _),
                 .update(let guid, _), .delete(let guid):
                if let spaceId = try pinnedTabRow(with: guid, in: context)?.spaceId {
                    spaceIds.insert(spaceId)
                }
            }
        }
        for spaceId in spaceIds.sorted() where ImportTargetLock.shared.isImporting(into: spaceId) {
            // 与 `targetNotWritable` 分开：导入是**瞬时**状态，引擎该停放重试，而不是把它
            // 当成一次结构性失败。`sorted()` 只为让多个 Space 同时在导入时报出去的是同一
            // 个，不随 Set 的迭代顺序变。
            throw LocalStoreWriteError.spaceImporting(spaceId: spaceId)
        }
    }

    /// 落地一条 `split_partner_uuid`：解析得出就把**两个**方向写在同一个事务里（§7.4 / I11）。
    ///
    /// **伙伴解析不出来不是失败**（§7.4 落地规则 3）：本地链接留 nil，由引擎在游标上记
    /// `pendingPartnerLineage`，伙伴落地的那一轮再把两个方向补齐。在这里抛错是错的——整个
    /// 批次是一个事务，于是「一对拆分 pin 只到了一半」这个 §7.4 视为**常态**的情形会把同一
    /// 轮里其余每一条 pin 操作一起回滚；基线永不写下、同一批每轮重放，pin 段就此停摆。
    ///
    /// 「伙伴行存在、但坐在另一个 owner 里」按同一条处理：§7.4 说一对拆分必然同 owner，所以
    /// 那是一条畸形载荷，该由 §4.6 去拒收或停放，而不是由一次本机写失败来表达。跨 owner 匹配
    /// 更会把两个 Space 里两条同 lineage 的 pin 链成一对。
    ///
    /// `reconcilePinnedSplitPartners()` 帮不上忙：它遍历的是活动窗口里的 `SplitGroup`，而
    /// 一对由同步落地的拆分 pin 没有任何活动 group。
    private func applyPinSplitPartnerBody(guid: String,
                                          partnerLineageId: String?,
                                          in context: ModelContext) throws {
        guard let tab = try pinnedTabRow(with: guid, in: context) else {
            throw LocalStoreWriteError.rowNotFound
        }
        let scope = try pinnedTabScope(in: context)
        guard pinnedTab(tab, belongsTo: scope) else {
            throw LocalStoreWriteError.rowNotInActiveScope
        }

        var resolvedPartnerGuid: String?
        if let partnerLineageId {
            let wanted = PinKind.lineageKey(partnerLineageId)
            let siblings = try pinnedTabs(
                profileId: tab.profileId ?? tab.profile?.profileId ?? Self.defaultProfileId,
                spaceId: tab.spaceId ?? Self.defaultSpaceId,
                scope: scope,
                in: context
            )
            // **一律过 `lineageKey`**：本机那一列存的可能是 `UUID().uuidString`（大写）或
            // 一条回落成 guid 的旧值，而补丁里的 lineage 是线上归一过的小写。直接比恒为假，
            // 于是每一条拆分 pin 都永远链不上、永远停在「等伙伴」那一格。
            resolvedPartnerGuid = siblings.first {
                $0.guid != guid && PinKind.lineageKey($0.pinLineageId ?? $0.guid) == wanted
            }?.guid
        }

        // 旧伙伴的反向链接先断，否则它会一直指着一条已经改配的行。只在它**确实**回指本行
        // 时才动：另一条正常的拆分对不该被这次改配波及。
        if let previous = tab.splitPartnerGuid,
           previous != resolvedPartnerGuid,
           let previousRow = try pinnedTabRow(with: previous, in: context),
           previousRow.splitPartnerGuid == guid {
            try updateTabSplitPartnerBody(previous, partnerGuid: nil, in: context)
        }
        try updateTabSplitPartnerBody(guid, partnerGuid: resolvedPartnerGuid, in: context)
        if let resolvedPartnerGuid {
            try updateTabSplitPartnerBody(resolvedPartnerGuid, partnerGuid: guid, in: context)
        }
    }

    /// 断掉**回指**这一行的那条链接，同一个事务。`.delete` 在移除一条拆分 pin 之前调它。
    ///
    /// 只在伙伴**确实**回指本行时才写：一条单向的陈旧链接（对端已经改配给别人）不该被这次
    /// 删除顺手改掉，那会把另一对正常的拆分拆散。
    private func clearSplitPartnerBackReferenceBody(of tab: TabDataModel,
                                                    in context: ModelContext) throws {
        guard let partnerGuid = tab.splitPartnerGuid, partnerGuid != tab.guid,
              let partner = try pinnedTabRow(with: partnerGuid, in: context),
              partner.splitPartnerGuid == tab.guid else {
            return
        }
        try updateTabSplitPartnerBody(partnerGuid, partnerGuid: nil, in: context)
    }

    /// 按 guid 定位一条 **pin** 行。`bookmarkNode(with:)` 那种「匹配任何 `TabDataModel`」
    /// 在这里是错的：一条普通 tab 与一条 pin 可以共享 guid 空间，而把一条 tab 当成 pin
    /// 改写会让它在下一轮快照里凭空出现。
    private func pinnedTabRow(with guid: String,
                              in context: ModelContext) throws -> TabDataModel? {
        let pinnedRaw = TabDataType.pinnedTab.rawValue
        let descriptor = FetchDescriptor<TabDataModel>(
            predicate: #Predicate { $0.guid == guid && $0.type == pinnedRaw }
        )
        return try context.fetch(descriptor).first
    }
}

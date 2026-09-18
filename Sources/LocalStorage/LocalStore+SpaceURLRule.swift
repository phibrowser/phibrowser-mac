// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Combine
import Foundation
import SwiftData

extension LocalStore {

    /// Stable persisted target for URL rules that open matches in an
    /// ephemeral Kiosk window instead of a Space. This is a wire value shared
    /// with Chromium's `phi::kKioskRuleTargetId`; it must never change after
    /// rules using it have been stored.
    static let kioskURLRuleTargetId = "__phi_kiosk__"

    /// Value-typed view of a `SpaceURLRule` used at the LocalStore boundary.
    /// `applyURLRuleEditsThrowing(upserts:deletedIds:)` accepts these so the
    /// caller never has to hold a SwiftData `@Model` instance across context
    /// boundaries (which SwiftData forbids); the write body locates each
    /// draft's row by stable `id` and writes only the units the draft carries.
    ///
    /// 一次写入口的值类型。**每一个合并单元都是 `Optional`，`nil` 的字面含义是
    /// 「这次 upsert 没带这个单元」**（§4.3 第 4 条的判据逐字落地，R-M3-4a-72）：
    /// body 对 `nil` 单元**一个字节都不写、不盖戳、不为置位出力**，哪怕库里此刻的
    /// 值与调用方手上那份不同。带了的单元照旧与库里的行逐单元比，相等 ⇒ 零写零戳
    /// （裁定 2）。内容组的三个成员**共用一枚戳**，所以它们一起进 `ContentUnit`
    /// 而不是三个独立可选值——「只改 host」在线上仍然是一次整组写。
    ///
    /// 四个单元的 `nil` 各有字面含义：`content == nil` = 不碰 `host` / `pathPrefix` /
    /// `askBeforeRouting` 与它们那枚戳；`spaceId == nil` = 不碰目标与 `targetUpdatedDate`
    /// （哪怕 sheet 打开期间远端刚把这一行的目标改过）；`sortOrder == nil` = 不对位置
    /// 表态（既有行保留现值、新行落到桶尾）；`createdDate == nil` = 既有行不碰、新行取
    /// `Date()`。`id` 的默认实参保持 `UUID().uuidString`（R-M3-4a-13：不传就等于重铸）。
    ///
    /// 按字段记脏那条路（M5 / 8b-4）直接用合成的成员构造器逐个成员构造；扁平便利
    /// 构造器（见文件末尾的 extension）给今天那个平铺的写法。
    struct URLRuleDraft {
        /// 内容组：`host` / `pathPrefix` / `askBeforeRouting` 三个成员共用
        /// `contentUpdatedDate` 那一枚戳（R-M3-4a-48）。构造时跑一次 `normalizedRule`
        /// （§8.1 的三处调用点之一），所以落进来就是不动点。
        struct ContentUnit: Equatable {
            var host: String
            var pathPrefix: String?
            var askBeforeRouting: Bool

            init(host: String, pathPrefix: String? = nil, askBeforeRouting: Bool = false) {
                let normalized = LocalStore.normalizedRule(host: host, pathPrefix: pathPrefix)
                self.host = normalized.host
                self.pathPrefix = normalized.pathPrefix
                self.askBeforeRouting = askBeforeRouting
            }
        }

        var id: String = UUID().uuidString
        var syncId: String?
        var content: ContentUnit?
        var spaceId: String?
        var sortOrder: Int?
        var createdDate: Date?
        var contentUpdatedDate: Date?

        /// 兼容读，给 Task 11 之前的调用方（`SpaceManager` 的两条乐观推送与
        /// `URLRouterTests`）：`content == nil` 时返回单元的默认值（空 host）。
        /// Task 11 / 8b-4 直接用 `content` 这个单元。
        var host: String { content?.host ?? "" }

        /// 兼容读（见 `host`）：`content == nil` ⇒ nil。
        var pathPrefix: String? { content?.pathPrefix }

        /// 兼容读（见 `host`）：`content == nil` ⇒ `false`。
        var askBeforeRouting: Bool { content?.askBeforeRouting ?? false }
    }

    /// 默认读口：软删行（`deletedDate != nil`）只对同步可见（R-M3-4a-51），这里一律过滤。
    /// `urlRulesPublisher()` 经这一函数取值，自动跟随。
    @MainActor
    func getAllURLRules() -> [SpaceRoutingRule] {
        guard let context = mainContext else { return [] }
        do {
            let descriptor = FetchDescriptor<SpaceURLRule>(
                predicate: #Predicate { $0.deletedDate == nil },
                sortBy: [SortDescriptor(\.spaceId), SortDescriptor(\.sortOrder)]
            )
            return try context.fetch(descriptor).map { model in
                SpaceRoutingRule(id: model.id, spaceId: model.spaceId, host: model.host,
                                 pathPrefix: model.pathPrefix,
                                 askBeforeRouting: model.askBeforeRouting,
                                 sortOrder: model.sortOrder, createdDate: model.createdDate)
            }
        } catch {
            AppLogError("[LocalStore] getAllURLRules failed: \(error)")
            return []
        }
    }

    @MainActor
    func getURLRules(forSpaceId spaceId: String) -> [SpaceRoutingRule] {
        guard let context = mainContext else { return [] }
        do {
            let descriptor = FetchDescriptor<SpaceURLRule>(
                predicate: #Predicate { $0.spaceId == spaceId && $0.deletedDate == nil },
                sortBy: [SortDescriptor(\.sortOrder)]
            )
            return try context.fetch(descriptor).map { model in
                SpaceRoutingRule(id: model.id, spaceId: model.spaceId, host: model.host,
                                 pathPrefix: model.pathPrefix,
                                 askBeforeRouting: model.askBeforeRouting,
                                 sortOrder: model.sortOrder, createdDate: model.createdDate)
            }
        } catch {
            AppLogError("[LocalStore] getURLRules(forSpaceId:) failed: \(error)")
            return []
        }
    }

    // MARK: - 唯一的对外写入口（R-M3-4a-49 / §4.3 第 5 条）

    /// 一次编辑器 Save / agent 调用的全部改动，一个事务。**没有非抛出的兄弟**：
    /// `writeActor == nil` 时抛 `.storeUnavailable`，块内任一处抛 ⇒ `performThrowing`
    /// 回滚整批——「静默返回」与「成功落地」在调用方看来必须不一样（R-M3-3-14）。
    func applyURLRuleEditsThrowing(upserts: [URLRuleDraft], deletedIds: Set<String>) async throws {
        try await performBackgroundWriteAndWaitThrowing { context in
            try self.applyURLRuleEditsBody(upserts: upserts, deletedIds: deletedIds, in: context)
        }
    }

    /// 八步，全部在一个 `context` 里。
    private func applyURLRuleEditsBody(upserts: [URLRuleDraft],
                                       deletedIds: Set<String>,
                                       in context: ModelContext) throws {
        // 第 1 步：一枚 `now`；一次全表 fetch（**含软删行**，R-M3-4a-56）建两张表。索引建在
        // 整张表上、按稳定 `id`，不按目标 Space 桶分建（R-M3-4a-80）。
        let now = Date()
        var rows = try context.fetch(FetchDescriptor<SpaceURLRule>())
        var byId: [String: SpaceURLRule] = [:]
        var bySyncId: [String: SpaceURLRule] = [:]
        for row in rows {
            byId[row.id] = row
            if let syncId = row.syncId {
                bySyncId[syncId] = row
            }
        }
        var touchedBuckets: Set<String> = []
        // 第 8 步的输入：本批给了非 nil `sortOrder` 的行，与第 6 步新插的行（排序时取 `Int.max`）。
        var placements: [String: Int] = [:]
        var insertedIds: Set<String> = []
        // 第 9 步的输入：本批点名的行，与其中在第 4 / 5 步里真的写了一个单元的行。
        var upsertedIds: [String] = []
        var wroteUnit: Set<String> = []

        for draft in upserts {
            // 第 2 步：定位。`byId[draft.id]` 命中 ⇒ 就是这一行；未命中且 `draft.syncId` 命中 ⇒
            // 也是这一行，并把 `row.id` 改写成 `draft.id`（裁定 3 的 legacy 兜底：编辑器的
            // `Row.init(from:)` 会把一条非 UUID 形的历史 id 往返成一个新 UUID，身份由 `syncId` 兜住）。
            var located = byId[draft.id]
            var adoptsDraftId = false
            if located == nil, let syncId = draft.syncId, let bySync = bySyncId[syncId] {
                located = bySync
                adoptsDraftId = true
            }
            // 第 2b 步：命中的是软删行（R-M3-4a-104 / 裁定 8）。索引含软删行，所以编辑器的 draft
            // 完全可能命中一条已经被 M2 或入站 tombstone 软删掉的行。
            var mintsFreshId = false
            if let row = located, row.deletedDate != nil {
                guard draft.syncId == nil else {
                    // 同步落地那条路不该走这个入口（落地走两个 per-row 原语）：fail-closed。
                    throw LocalStoreWriteError.rowAlreadyMapped
                }
                // 编辑器 / agent 这条路：那一行一个字节不碰（它在等自己那条 tombstone 的 `.applied`
                // 或 §8.4.7 的 30 天清理），改走 insert 支并换一个新铸的 `id`——`draft.id` 还被软删行
                // 占着 `@Attribute(.unique)`，复用它当场违约。
                located = nil
                mintsFreshId = true
            }

            if let row = located {
                // 第 3 步：命中行的 `syncId` 守卫，两个形状（守卫文字照 `LocalStore+Bookmark.swift:2196-2199`）。
                // 一条行的身份只认领一次：换一个 uuid 会让旧身份在本机瞬间失去对应行，而差分对此的
                // 回答是删掉对端那条实体。
                if let draftSyncId = draft.syncId {
                    // (a) 行已带着另一个 `syncId`。
                    if let rowSyncId = row.syncId, rowSyncId != draftSyncId {
                        throw LocalStoreWriteError.rowAlreadyMapped
                    }
                    // (b) 这个 `syncId` 已属于另一条 `id` 的行。
                    if let owner = bySyncId[draftSyncId], owner !== row {
                        throw LocalStoreWriteError.rowAlreadyMapped
                    }
                    if row.syncId == nil {
                        // 认领不是编辑：只写身份，不盖戳、不置位。
                        row.syncId = draftSyncId
                        bySyncId[draftSyncId] = row
                    }
                }
                if adoptsDraftId {
                    byId[row.id] = nil
                    row.id = draft.id
                    byId[draft.id] = row
                }
                let rowId = row.id
                upsertedIds.append(rowId)

                // 第 4 步：内容组，三个成员共用一枚戳（R-M3-4a-48）。`nil` ⇒ 整段跳过。非 nil ⇒ 先归一
                // （落地不经 draft，§8.1 的第三处调用点；幂等），三个成员与行现值逐一比，有任何一个
                // 不同 ⇒ 写不同的那些 + `contentUpdatedDate = now`；三个都相同 ⇒ 一个字节都不写。
                if let unit = draft.content {
                    let normalized = LocalStore.normalizedRule(host: unit.host, pathPrefix: unit.pathPrefix)
                    var contentChanged = false
                    if row.host != normalized.host {
                        row.host = normalized.host
                        contentChanged = true
                    }
                    if row.pathPrefix != normalized.pathPrefix {
                        row.pathPrefix = normalized.pathPrefix
                        contentChanged = true
                    }
                    if row.askBeforeRouting != unit.askBeforeRouting {
                        row.askBeforeRouting = unit.askBeforeRouting
                        contentChanged = true
                    }
                    if contentChanged {
                        row.contentUpdatedDate = now
                        wroteUnit.insert(rowId)
                    }
                }

                // 第 5 步：目标。`nil` ⇒ 整段跳过——`spaceId` 与 `targetUpdatedDate` 一个字节都不碰，
                // 哪怕 sheet 打开期间远端刚把这一行的目标改过（§4.3 第 4 条）——只把行现在所在的桶放进
                // `touchedBuckets`。非 nil 且不同 ⇒ 写目标 + `targetUpdatedDate = now`，旧桶与新桶都进
                // `touchedBuckets`（只重排一个会在源桶留下空洞）。`syncId` 与内容组一个字节不动——改目标
                // 就是「这一行换一个桶」，不是新行（R-M3-4a-80）。
                if let spaceId = draft.spaceId {
                    if spaceId != row.spaceId {
                        touchedBuckets.insert(row.spaceId)
                        row.spaceId = spaceId
                        row.targetUpdatedDate = now
                        wroteUnit.insert(rowId)
                    }
                    touchedBuckets.insert(spaceId)
                } else {
                    touchedBuckets.insert(row.spaceId)
                }
                if let sortOrder = draft.sortOrder {
                    placements[rowId] = sortOrder
                }
            } else {
                // 第 6 步：insert 支（两个入口：第 2 步「两者都不命中」，与第 2b 步「`syncId == nil`
                // 命中软删行」）。一条新行没有可继承的现值，缺了任一单元就无从建行，而静默跳过会让调用方
                // 以为写成功了（R-M3-3-14）——调用方的 bug，不是一次成功的空操作。
                guard let unit = draft.content, let spaceId = draft.spaceId else {
                    throw LocalStoreWriteError.noCandidateSurvived
                }
                let normalized = LocalStore.normalizedRule(host: unit.host, pathPrefix: unit.pathPrefix)
                // `syncId` 在插入点铸（R-M3-4a-23）；`draft.syncId` 非 nil 时照抄（那是同步落地那条路）。
                let syncId = draft.syncId ?? UUID().uuidString.lowercased()
                // 插入前先过第 3 步的 (b) 守卫。
                guard bySyncId[syncId] == nil else {
                    throw LocalStoreWriteError.rowAlreadyMapped
                }
                // `id` 按入口分两种：整表都没命中的取 `draft.id`（界面上那一行不跳位，R-M3-4a-101）；
                // 撞上软删行的取一个新铸的 UUID。
                let id = mintsFreshId ? UUID().uuidString.lowercased() : draft.id
                // 裁定 5：新行不铸内容戳——无基线投影取 `contentUpdatedDate ?? createdDate`，而新行的
                // `createdDate` 就是此刻。`sortOrder` 是占位，第 8 步重编。
                let row = SpaceURLRule(
                    id: id,
                    spaceId: spaceId,
                    host: normalized.host,
                    pathPrefix: normalized.pathPrefix,
                    askBeforeRouting: unit.askBeforeRouting,
                    sortOrder: Int.max,
                    createdDate: draft.createdDate ?? Date(),
                    syncId: syncId,
                    contentUpdatedDate: draft.contentUpdatedDate,
                    targetUpdatedDate: nil,
                    deletedDate: nil,
                    pendingLocalEdit: true,
                    mergePartnerSyncId: nil
                )
                context.insert(row)
                rows.append(row)
                byId[id] = row
                bySyncId[syncId] = row
                insertedIds.insert(id)
                upsertedIds.append(id)
                if let sortOrder = draft.sortOrder {
                    placements[id] = sortOrder
                }
                touchedBuckets.insert(spaceId)
            }
        }

        // 第 7 步：`deletedIds` ⇒ 软删（R-M3-4a-41），`pendingLocalEdit` 一个字节都不碰（删除不是编辑，
        // R-M3-4a-69）；命中不到 ⇒ 跳过（不抛 `.rowNotFound`：并发落地可能刚把它硬删过）。该行的桶进
        // `touchedBuckets`（一次软删也会在桶里留洞）。
        for id in deletedIds {
            guard let row = byId[id], row.deletedDate == nil else { continue }
            row.deletedDate = now
            touchedBuckets.insert(row.spaceId)
        }

        // 第 8 步：每个触及的桶各自稠密化。取该桶此刻 `deletedDate == nil` 的全部行，分成本批给了
        // `sortOrder` 的 `placed` 与没给的 `unplaced`；`unplaced` 按（本批之前的 `sortOrder`，`id`）
        // 升序（新插的行取 `Int.max`，落到桶尾）；`placed` 按（请求下标，`id`）升序后依次插进
        // `min(请求下标, 当前长度)`；最终序列按 0…n-1 写 `sortOrder`，只写真的变了的行。这一步不盖
        // 任何戳（R-M3-4a-11），也不额外置位。
        var reorderedIds: Set<String> = []
        for bucket in touchedBuckets {
            let live = rows.filter { $0.spaceId == bucket && $0.deletedDate == nil }
            var sequence = live
                .filter { placements[$0.id] == nil }
                .sorted { lhs, rhs in
                    let l = insertedIds.contains(lhs.id) ? Int.max : lhs.sortOrder
                    let r = insertedIds.contains(rhs.id) ? Int.max : rhs.sortOrder
                    if l != r { return l < r }
                    return lhs.id < rhs.id
                }
            let placed = live
                .filter { placements[$0.id] != nil }
                .sorted { lhs, rhs in
                    let l = placements[lhs.id] ?? Int.max
                    let r = placements[rhs.id] ?? Int.max
                    if l != r { return l < r }
                    return lhs.id < rhs.id
                }
            for row in placed {
                let requested = placements[row.id] ?? sequence.count
                sequence.insert(row, at: min(max(requested, 0), sequence.count))
            }
            for (index, row) in sequence.enumerated() where row.sortOrder != index {
                row.sortOrder = index
                reorderedIds.insert(row.id)
            }
        }

        // 第 9 步：`pendingLocalEdit = true` 只对「第 4 / 5 / 8 步里至少真的写了一个单元」的那些 upsert
        // 行落写（§4.3 置位表：内容改 / 改目标 / 拖动排序都置位）。`nil` 单元不出力；「带了但值与行
        // 相同」的单元同样不出力；已经是 `true` 的行不重复写。
        for id in upsertedIds where wroteUnit.contains(id) || reorderedIds.contains(id) {
            if let row = byId[id], !row.pendingLocalEdit {
                row.pendingLocalEdit = true
            }
        }
    }

    // MARK: - 同步落地专用的两个 per-row 原语

    // 都拆成 throwing 兄弟 + `…Body(…in:)` 半边，而且 body 是 **internal（不是 private）**：
    // Task 8 的 `applyURLRuleSyncBatchBody` 要在同一个写块里组合它们，嵌套开第二个
    // `performBackgroundWriteAndWaitThrowing` 会在串行写队列上自我死锁（R-exec-2）。
    // 两者的寻址定义域一律是含软删行的那一次全表 fetch（R-M3-4a-56）——按默认读口寻址会对一条
    // 软删行插出第二条同 `syncId` 的行。两者都不碰 `pendingLocalEdit`（引擎的每一次写都不置位）。

    /// Throwing sibling used ONLY by the sync layer — see `updateBookmarkThrowing`.
    func upsertURLRuleThrowing(syncId: String,
                               spaceId: String,
                               host: String,
                               pathPrefix: String?,
                               ask: Bool,
                               sortOrder: Int,
                               createdDate: Date,
                               contentUpdatedDate: Date?,
                               targetUpdatedDate: Date?) async throws {
        try await performBackgroundWriteAndWaitThrowing { context in
            try self.upsertURLRuleBody(syncId: syncId,
                                       spaceId: spaceId,
                                       host: host,
                                       pathPrefix: pathPrefix,
                                       ask: ask,
                                       sortOrder: sortOrder,
                                       createdDate: createdDate,
                                       contentUpdatedDate: contentUpdatedDate,
                                       targetUpdatedDate: targetUpdatedDate,
                                       in: context)
        }
    }

    /// 命中 ⇒ 就地写九个字段（`host` / `pathPrefix` 先过 `normalizedRule`），**两枚戳照抄入参、
    /// 一枚 `now` 都不铸**（R-M3-4a-20，先例 `LocalStore+Bookmark.swift:2073`），命中行若带
    /// `deletedDate` ⇒ 同一次行写里把 `deletedDate` 与 `mergePartnerSyncId` 清成 nil；命中不到
    /// ⇒ 建行（R-M3-4a-42(a)，**绝不抛 `.rowNotFound`**），`id` 现铸、`syncId` 取入参。
    func upsertURLRuleBody(syncId: String,
                           spaceId: String,
                           host: String,
                           pathPrefix: String?,
                           ask: Bool,
                           sortOrder: Int,
                           createdDate: Date,
                           contentUpdatedDate: Date?,
                           targetUpdatedDate: Date?,
                           in context: ModelContext) throws {
        let normalized = LocalStore.normalizedRule(host: host, pathPrefix: pathPrefix)
        let rows = try context.fetch(FetchDescriptor<SpaceURLRule>())
        guard let row = rows.first(where: { $0.syncId == syncId }) else {
            context.insert(SpaceURLRule(
                id: UUID().uuidString,
                spaceId: spaceId,
                host: normalized.host,
                pathPrefix: normalized.pathPrefix,
                askBeforeRouting: ask,
                sortOrder: sortOrder,
                createdDate: createdDate,
                syncId: syncId,
                contentUpdatedDate: contentUpdatedDate,
                targetUpdatedDate: targetUpdatedDate,
                deletedDate: nil,
                pendingLocalEdit: false,
                mergePartnerSyncId: nil
            ))
            return
        }
        // 一条行的身份只认领一次（`LocalStore+Bookmark.swift:2196-2199` 同款守卫）。按 `syncId`
        // 寻址时它恒成立；留着是让寻址方式一旦变化，静默覆盖仍然变成一次抛错（R-M3-3-14）。
        guard row.syncId == nil || row.syncId == syncId else {
            throw LocalStoreWriteError.rowAlreadyMapped
        }
        row.syncId = syncId
        row.spaceId = spaceId
        row.host = normalized.host
        row.pathPrefix = normalized.pathPrefix
        row.askBeforeRouting = ask
        row.sortOrder = sortOrder
        row.createdDate = createdDate
        row.contentUpdatedDate = contentUpdatedDate
        row.targetUpdatedDate = targetUpdatedDate
        if row.deletedDate != nil {
            row.deletedDate = nil
            row.mergePartnerSyncId = nil
        }
    }

    /// Throwing sibling used ONLY by the sync layer — see `updateBookmarkThrowing`.
    func hardDeleteURLRuleThrowing(syncId: String) async throws {
        try await performBackgroundWriteAndWaitThrowing { context in
            try self.hardDeleteURLRuleBody(syncId: syncId, in: context)
        }
    }

    /// `context.delete(row)`（**真删**，入站 tombstone 落地是硬删）；命中不到就静默返回
    /// （入站 tombstone 落在本机已无行的身份上，走 T3 支）。
    func hardDeleteURLRuleBody(syncId: String, in context: ModelContext) throws {
        let rows = try context.fetch(FetchDescriptor<SpaceURLRule>())
        for row in rows where row.syncId == syncId {
            // 同款守卫，见 `upsertURLRuleBody`。
            guard row.syncId == nil || row.syncId == syncId else {
                throw LocalStoreWriteError.rowAlreadyMapped
            }
            context.delete(row)
        }
    }

    @MainActor
    func urlRulesPublisher() -> AnyPublisher<[SpaceRoutingRule], Never> {
        guard mainContext != nil else {
            return Just([]).eraseToAnyPublisher()
        }

        let subject = CurrentValueSubject<[SpaceRoutingRule], Never>([])
        let fetch = { self.getAllURLRules() }
        subject.send(fetch())

        let cancellable = NotificationCenter.default
            .publisher(for: .NSManagedObjectContextDidSave)
            .filter {
                Self.notificationContainsChanges(
                    $0,
                    matching: { $0.entity.name == SpaceURLRule.entityName }
                )
            }
            .receive(on: DispatchQueue.main)
            .sink { _ in subject.send(fetch()) }

        return subject
            .removeDuplicates()
            .handleEvents(receiveCancel: { cancellable.cancel() })
            .prefix(untilOutputFrom: NotificationCenter.default.publisher(
                for: Self.willCloseNotification, object: self))
            .eraseToAnyPublisher()
    }

    // MARK: - 归一化（§8.1 的那一个不动点函数）

    // `internal static` 挂在 `LocalStore` 上（§8.1 没有引入任何新命名空间）。三处调用：本地编辑
    // （`URLRuleDraft.ContentUnit.init`）、入站（`URLRuleKind` 的 plan 闭包，Task 7）、落地
    // （`applyURLRuleEditsBody` 与 `upsertURLRuleBody`）。

    /// 幂等：`normalizedRule(normalizedRule(x)) == normalizedRule(x)`，证明在 §8.1，
    /// 用例 CASE U-6。
    static func normalizedRule(host: String, pathPrefix: String?)
        -> (host: String, pathPrefix: String?) {
        (host: normalizedHost(host), pathPrefix: normalizedPathPrefix(pathPrefix))
    }

    /// host 半边（R-M3-4a-21 / §8.1）。**右端是一个字符集、一次扫描**——「先剥点再
    /// trim」或「先 trim 再剥点」的分步写法对点与空白交替的后缀都不是不动点，而循环
    /// 需要一个说不清的上界。
    static func normalizedHost(_ raw: String) -> String {
        var s = Substring(raw).drop(while: { $0.isWhitespace || $0.isNewline })
        while let last = s.last, last.isWhitespace || last.isNewline || last == "." {
            s = s.dropLast()
        }
        return String(s).lowercased()
    }

    /// path 半边（R-M3-4a-21 / §8.1）。**步骤之间不可交换**：从前的实现在解码**之前**
    /// 剥尾斜杠，而 `/` 在 `.urlPathAllowed` 里、再编码会把它放回来，于是
    /// `f("/foo%2F") == "/foo/"` 而 `f("/foo/") == "/foo"`；更糟的是 `f("/%2F") == "//"`
    /// 而 `f("//") == nil`，一条带路径前缀的规则悄悄放宽成「匹配任意路径」。
    /// **`"/"` 与 nil 是两个不同的值**：nil = 匹配任意路径，`"/"` = 只匹配根
    /// （`URLRouter.swift:80-86`、`phi_url_router.cc:64-78`）。
    ///
    /// Both the Swift `URLRouter` and the C++ `phi::PhiURLRouter` compare
    /// against the percent-encoded canonical path, so the stored prefix
    /// must end up in this shape regardless of how the user expressed it.
    static func normalizedPathPrefix(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "/" { return "/" }                                          // 0
        guard !trimmed.isEmpty else { return nil }                                // 1
        var s = trimmed.hasPrefix("/") ? trimmed : "/" + trimmed                  // 2
        s = s.removingPercentEncoding ?? s                                        // 3
        s = s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s  // 4
        while s.count > 1 && s.hasSuffix("/") { s.removeLast() }                  // 5
        return s                                                                  // 6
    }
}

extension LocalStore.URLRuleDraft {
    /// 扁平便利构造器：填好 `content` 与 `spaceId`，让 Task 11 的四处构造点与
    /// agent router 保持今天那个平铺的写法（`SpaceURLRulesEditor.swift:143-149`、
    /// `AgentSpaceRouter+Management.swift:247-252` / `:308-311` / `:350-353`）。
    /// `spaceId` 带 `nil` 默认值是给 Task 11 之前的那四处（它们不传目标，
    /// `SpaceManager.setAllRules` / `setRules` 用字典键 / `forSpaceId` 盖上去）。
    /// 按字段记脏那条路（M5 / 8b-4）直接用成员逐个构造，不经这个 init。
    init(id: String = UUID().uuidString,
         host: String,
         pathPrefix: String? = nil,
         askBeforeRouting: Bool = false,
         spaceId: String? = nil,
         sortOrder: Int? = nil,
         createdDate: Date? = nil,
         syncId: String? = nil,
         contentUpdatedDate: Date? = nil) {
        self.init(id: id,
                  syncId: syncId,
                  content: ContentUnit(host: host,
                                       pathPrefix: pathPrefix,
                                       askBeforeRouting: askBeforeRouting),
                  spaceId: spaceId,
                  sortOrder: sortOrder,
                  createdDate: createdDate,
                  contentUpdatedDate: contentUpdatedDate)
    }
}

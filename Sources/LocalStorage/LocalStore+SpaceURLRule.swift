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

    // MARK: - 同步层的第二读口与全表索引（R-M3-4a-51 / R-M3-4a-56 / R-M3-4a-80）

    /// 同步层的第二读口：整张表，**含软删行**，按 `(spaceId, sortOrder, id)` 有序。
    /// `AccountPhiURLRuleAccess` 的快照与 `liveOwners`、`urlRuleChangesPublisher` 的值快照都读它。
    /// 读失败**抛**（R-exec-3）——与 `getAllURLRules()` 那个 `return []` 的 UI 读口刻意不同：
    /// 差分对空集合的回答是给每一条游标发一条 tombstone。
    func allURLRuleModelsIncludingDeleted(in context: ModelContext) throws -> [SpaceURLRule] {
        try context.fetch(FetchDescriptor<SpaceURLRule>(
            sortBy: [SortDescriptor(\.spaceId), SortDescriptor(\.sortOrder), SortDescriptor(\.id)]
        ))
    }

    /// 整张表（**含软删行**）按 `syncId` 的索引，一个写块里**只建一次**（R-M3-4a-56 的寻址条款、
    /// R-M3-4a-80 的整表索引）。`syncId == nil` 的行不进 `bySyncId`，它们只在 `rows`——收尾稠密
    /// 重排的定义域——里。两个 per-row 原语从它寻址、往它登记，于是一批 N 条 op 是一次全表
    /// fetch，不是 N 次。
    struct URLRuleTableIndex {
        private(set) var rows: [SpaceURLRule]
        private(set) var bySyncId: [String: SpaceURLRule]

        init(rows: [SpaceURLRule]) {
            self.rows = rows
            var bySyncId: [String: SpaceURLRule] = [:]
            for row in rows {
                if let syncId = row.syncId, bySyncId[syncId] == nil {
                    bySyncId[syncId] = row
                }
            }
            self.bySyncId = bySyncId
        }

        mutating func insert(_ row: SpaceURLRule) {
            rows.append(row)
            if let syncId = row.syncId, bySyncId[syncId] == nil {
                bySyncId[syncId] = row
            }
        }

        mutating func remove(_ row: SpaceURLRule) {
            rows.removeAll { $0 === row }
            if let syncId = row.syncId, bySyncId[syncId] === row {
                bySyncId[syncId] = nil
            }
        }

        /// §8.4.2 M1 的 re-key 之后把索引跟上：旧键若指向这一行就摘掉，新键登记（`row.syncId`
        /// 已经是新值）。同一个写块里排在后面的 `.update` 按新身份寻址，靠的就是这一步。
        mutating func rekey(_ row: SpaceURLRule, from previous: String?) {
            if let previous, bySyncId[previous] === row {
                bySyncId[previous] = nil
            }
            if let syncId = row.syncId, bySyncId[syncId] == nil {
                bySyncId[syncId] = row
            }
        }
    }

    /// 一次 `FetchDescriptor<SpaceURLRule>()`（含软删行）建索引。
    func urlRuleTableIndex(in context: ModelContext) throws -> URLRuleTableIndex {
        URLRuleTableIndex(rows: try context.fetch(FetchDescriptor<SpaceURLRule>()))
    }

    // MARK: - 同步落地专用的两个 per-row 原语

    // 都拆成 throwing 兄弟 + `…Body(…index:in:)` 半边，而且 body 是 **internal（不是 private）**：
    // `applyURLRuleSyncBatchBody` 要在同一个写块里组合它们，嵌套开第二个
    // `performBackgroundWriteAndWaitThrowing` 会在串行写队列上自我死锁（R-exec-2）。
    // 两者的寻址定义域一律是含软删行的那一份 `URLRuleTableIndex`（R-M3-4a-56）——按默认读口寻址会
    // 对一条软删行插出第二条同 `syncId` 的行。两者都不碰 `pendingLocalEdit`（引擎的每一次写都不置位）。

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
            var index = try self.urlRuleTableIndex(in: context)
            try self.upsertURLRuleBody(syncId: syncId,
                                       spaceId: spaceId,
                                       host: host,
                                       pathPrefix: pathPrefix,
                                       ask: ask,
                                       sortOrder: sortOrder,
                                       createdDate: createdDate,
                                       contentUpdatedDate: contentUpdatedDate,
                                       targetUpdatedDate: targetUpdatedDate,
                                       index: &index,
                                       in: context)
        }
    }

    /// 命中 ⇒ 就地写九个字段（`host` / `pathPrefix` 先过 `normalizedRule`），**两枚戳照抄入参、
    /// 一枚 `now` 都不铸**（R-M3-4a-20，先例 `LocalStore+Bookmark.swift:2073`），命中行若带
    /// `deletedDate` ⇒ 同一次行写里把 `deletedDate` 与 `mergePartnerSyncId` 清成 nil；命中不到
    /// ⇒ 建行（R-M3-4a-42(a)，**绝不抛 `.rowNotFound`**），`id` 现铸、`syncId` 取入参。
    /// 返回命中或新建的那一行，调用方用它记桶。
    @discardableResult
    func upsertURLRuleBody(syncId: String,
                           spaceId: String,
                           host: String,
                           pathPrefix: String?,
                           ask: Bool,
                           sortOrder: Int,
                           createdDate: Date,
                           contentUpdatedDate: Date?,
                           targetUpdatedDate: Date?,
                           index: inout URLRuleTableIndex,
                           in context: ModelContext) throws -> SpaceURLRule {
        let normalized = LocalStore.normalizedRule(host: host, pathPrefix: pathPrefix)
        guard let row = index.bySyncId[syncId] else {
            let row = SpaceURLRule(
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
            )
            context.insert(row)
            index.insert(row)
            return row
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
        return row
    }

    /// Throwing sibling used ONLY by the sync layer — see `updateBookmarkThrowing`.
    func hardDeleteURLRuleThrowing(syncId: String) async throws {
        try await performBackgroundWriteAndWaitThrowing { context in
            var index = try self.urlRuleTableIndex(in: context)
            try self.hardDeleteURLRuleBody(syncId: syncId, index: &index, in: context)
        }
    }

    /// `context.delete(row)`（**真删**，入站 tombstone 落地是硬删）；命中不到就静默返回 nil
    /// （入站 tombstone 落在本机已无行的身份上，走 T3 支）。返回被删行**删之前**所在的桶。
    @discardableResult
    func hardDeleteURLRuleBody(syncId: String,
                               index: inout URLRuleTableIndex,
                               in context: ModelContext) throws -> String? {
        var bucket: String?
        // `index.rows` 是值拷贝，循环里改 `index` 不影响遍历。
        for row in index.rows where row.syncId == syncId {
            // 同款守卫，见 `upsertURLRuleBody`。
            guard row.syncId == nil || row.syncId == syncId else {
                throw LocalStoreWriteError.rowAlreadyMapped
            }
            if bucket == nil {
                bucket = row.spaceId
            }
            context.delete(row)
            index.remove(row)
        }
        return bucket
    }

    // MARK: - §8.4.2 M1 的 re-key 原语（§4.3 六个新原语的第一个）

    /// Throwing sibling used ONLY by the sync layer — see `updateBookmarkThrowing`.
    ///
    /// §8.4.2 M1 的 re-key，**按本机行 `id` 寻址**（`OwnedItemApplyStep` 既不带旧 `syncId`
    /// 也不带本机 id，而 `context.pairs` 带的正是后者）。
    /// 守卫两条：① 该行此刻的 `syncId` **等于** `syncId` ⇒ 幂等返回、零写；
    /// ② 该行 `deletedDate != nil` ⇒ 抛 `LocalStoreWriteError.rowNotFound`（软删行不认领）。
    /// 外加 R-M3-4a-80 的唯一 `rowAlreadyMapped` 形状：`syncId` 已经属于**另一条 `id`** 的
    /// 行 ⇒ 抛 `LocalStoreWriteError.rowAlreadyMapped`、**整批回滚**。
    /// **必须是 re-key 而不是「删旧建新」**：后者会让本机那一行短暂没有身份、或产生第二条
    /// 行，而 §5.7 的差分对「有游标、无本机行」的回答是发一条 tombstone。
    func rekeyURLRuleThrowing(localId: String, to syncId: String) async throws {
        try await performBackgroundWriteAndWaitThrowing { context in
            var index = try self.urlRuleTableIndex(in: context)
            try self.rekeyURLRuleBody(localId: localId, to: syncId, index: &index, in: context)
        }
    }

    /// R-exec-2 的 body 兄弟：批次入口在自己的写块里调它（各自开一次
    /// `performBackgroundWriteAndWaitThrowing` 会在同一个串行写流上自我死锁）。
    /// 寻址定义域是**整张表按 `id`**（含软删行，R-M3-4a-56 / R-M3-4a-80），撞车检查按 `syncId`
    /// 在整表上做。**只写 `syncId` 一列**：不盖戳、不置位、不碰 `mergePartnerSyncId`
    /// （RR10-8 / R-M3-4a-69）。书签那条认领守卫（`syncId == nil || syncId == 新值`）在这里
    /// **不适用**：规则的 re-key 必然改写一个非 nil 的旧值（插入点铸造），照抄会让每一次认领都抛。
    func rekeyURLRuleBody(localId: String,
                          to syncId: String,
                          index: inout URLRuleTableIndex,
                          in context: ModelContext) throws {
        guard let row = index.rows.first(where: { $0.id == localId }) else {
            throw LocalStoreWriteError.rowNotFound
        }
        guard row.deletedDate == nil else {
            throw LocalStoreWriteError.rowNotFound
        }
        // ① 相等则幂等接受（CASE M-32 (a)）：少了它 CASE M-13 的重投会抛。
        if row.syncId == syncId { return }
        // R-M3-4a-80：这个账户身份已经属于另一条 `id` 的行（`.unique` 只建在 `id` 上，两条行争
        // 同一个身份 ⇒ 本机没有活行认领其中一条 ⇒ 下一轮差分为它发一条 tombstone）。
        if let owner = index.bySyncId[syncId], owner !== row {
            throw LocalStoreWriteError.rowAlreadyMapped
        }
        let previous = row.syncId
        row.syncId = syncId
        index.rekey(row, from: previous)
    }

    // MARK: - §8.4.3 M2 的三个原语（§4.3 六个新原语的第二 ~ 四个，8b-2）

    // 三条共用（计划裁定五）：寻址定义域一律是**含软删行**的那一份 `URLRuleTableIndex`
    // （R-M3-4a-56 的寻址条款）；带 §4.3 末段那条与 `LocalStore+Bookmark.swift:2196-2199`
    // 逐字同款的 `rowAlreadyMapped` 守卫；**索引里找不到那条 `syncId` ⇒ 零写返回、DEBUG 下
    // `assertionFailure`，不抛** —— M2 的三个输入全部来自同一个事务里刚读到的那份投影，结构上
    // 必然命中；抛会把整页落地回滚掉，而 §5.5 的「落地失败 ⇒ 整批回滚、下一轮重放」会让同一页
    // 每轮重放每轮抛（与 CASE M-13 论证过的死循环同形）。三条都**一个字节不碰
    // `pendingLocalEdit`**（R-M3-4a-69 / RR5-8），也都不铸任何**戳**——`contentUpdatedDate`
    // 只在 `setURLRuleContentGroupBody` 里**照抄来源**（D33 / §8.4.1 第五条）。

    /// Throwing sibling used ONLY by the sync layer — see `updateBookmarkThrowing`.
    ///
    /// §8.4.3 第 2 步 (b) 与编辑器删除集共用。**两列一次写、一个 SwiftData 事务**（RR8-4）：
    /// `deletedDate = Date()` 与 `mergePartnerSyncId` 同时落行。编辑器那条路径传 `nil`。
    func softDeleteURLRuleThrowing(syncId: String, mergePartnerSyncId: String?) async throws {
        try await performBackgroundWriteAndWaitThrowing { context in
            var index = try self.urlRuleTableIndex(in: context)
            try self.softDeleteURLRuleBody(syncId: syncId,
                                           mergePartnerSyncId: mergePartnerSyncId,
                                           index: &index, in: context)
        }
    }

    /// 返回被软删那一行所在的桶（`nil` = 索引里没有这条身份，零写）。调用方用它记桶：一次
    /// 软删会在桶里留下一个空洞下标，而 `sortOrder` 是路由特异度的第三项、排在裁决键之前。
    /// **已经软删的行不重写 `deletedDate`**（那会把 §8.4.7 的 30 天清理时钟拨回去）。
    @discardableResult
    func softDeleteURLRuleBody(syncId: String,
                               mergePartnerSyncId: String?,
                               index: inout URLRuleTableIndex,
                               in context: ModelContext) throws -> String? {
        guard let row = index.bySyncId[syncId] else {
            assertionFailure("url rule soft delete: the merge tail addressed a row that is not there")
            return nil
        }
        guard row.syncId == nil || row.syncId == syncId else {
            throw LocalStoreWriteError.rowAlreadyMapped
        }
        // 同一次行写：抛在两句中间的实现会留下「软删了、伙伴没写」的半状态，而 §8.4.4 的
        // 伙伴查找正是靠那一列把那次编辑救回来的。
        if row.deletedDate == nil { row.deletedDate = Date() }
        if row.mergePartnerSyncId != mergePartnerSyncId {
            row.mergePartnerSyncId = mergePartnerSyncId
        }
        return row.spaceId
    }

    /// Throwing sibling used ONLY by the sync layer — see `updateBookmarkThrowing`.
    ///
    /// §8.4.3 第 1 步的提示写，**只写这一列**；传 `nil` 就是清空（两条清空规则走它）。
    /// **值相同时零写**（RR11-8，**第二道防御**——承重的那条前置在 `mergePointerPass` 里）。
    func setURLRuleMergePartnerThrowing(syncId: String, mergePartnerSyncId: String?) async throws {
        try await performBackgroundWriteAndWaitThrowing { context in
            var index = try self.urlRuleTableIndex(in: context)
            try self.setURLRuleMergePartnerBody(syncId: syncId,
                                                mergePartnerSyncId: mergePartnerSyncId,
                                                index: &index, in: context)
        }
    }

    func setURLRuleMergePartnerBody(syncId: String,
                                    mergePartnerSyncId: String?,
                                    index: inout URLRuleTableIndex,
                                    in context: ModelContext) throws {
        guard let row = index.bySyncId[syncId] else {
            assertionFailure("url rule merge partner: the merge tail addressed a row that is not there")
            return
        }
        guard row.syncId == nil || row.syncId == syncId else {
            throw LocalStoreWriteError.rowAlreadyMapped
        }
        guard row.mergePartnerSyncId != mergePartnerSyncId else { return }
        row.mergePartnerSyncId = mergePartnerSyncId
    }

    /// Throwing sibling used ONLY by the sync layer — see `updateBookmarkThrowing`.
    ///
    /// §8.4.3 第 2 步 (a) 的胜者吸收，**按内容组整组写**：三个字段连同它们共用的那一枚戳。
    /// **不碰** `sortOrder` / `targetUpdatedDate` / `deletedDate` / `pendingLocalEdit`。
    /// **不复用 `upsertURLRuleThrowing`**：它要求同时给 `sortOrder`（与本页重排打架）与
    /// `targetUpdatedDate`（收敛不该碰目标戳）。
    func setURLRuleContentGroupThrowing(syncId: String, host: String, pathPrefix: String?,
                                        ask: Bool, contentUpdatedDate: Date) async throws {
        try await performBackgroundWriteAndWaitThrowing { context in
            var index = try self.urlRuleTableIndex(in: context)
            try self.setURLRuleContentGroupBody(syncId: syncId, host: host,
                                                pathPrefix: pathPrefix, ask: ask,
                                                contentUpdatedDate: contentUpdatedDate,
                                                index: &index, in: context)
        }
    }

    func setURLRuleContentGroupBody(syncId: String, host: String, pathPrefix: String?,
                                    ask: Bool, contentUpdatedDate: Date,
                                    index: inout URLRuleTableIndex,
                                    in context: ModelContext) throws {
        guard let row = index.bySyncId[syncId] else {
            assertionFailure("url rule content group: the merge tail addressed a row that is not there")
            return
        }
        guard row.syncId == nil || row.syncId == syncId else {
            throw LocalStoreWriteError.rowAlreadyMapped
        }
        // §8.1 的第四处调用点：幂等，来源行可能是 V11 回填的、没过归一化的老行。
        let normalized = LocalStore.normalizedRule(host: host, pathPrefix: pathPrefix)
        if row.host != normalized.host { row.host = normalized.host }
        if row.pathPrefix != normalized.pathPrefix { row.pathPrefix = normalized.pathPrefix }
        if row.askBeforeRouting != ask { row.askBeforeRouting = ask }
        // 戳**照抄来源**（D33）：铸 `now` 会让一条经机器搬运的规则带着伪造的新鲜度去赢一次
        // 真实的用户编辑。
        if row.contentUpdatedDate != contentUpdatedDate {
            row.contentUpdatedDate = contentUpdatedDate
        }
    }

    // MARK: - §8.4.4 M3 的转移原语（§4.3 六个新原语的第五个，8b-3）

    /// Throwing sibling used ONLY by the sync layer — see `updateBookmarkThrowing`.
    ///
    /// §8.4.4 的 M3 编辑转移。按**三个合并单元**与 W 此刻的值比 LWW，**只写赢下的整组**；
    /// 返回真的写下去的单元数（0…2），调用方据此计 `transferred`（§13.2）。
    /// 至少写了一个单元 ⇒ 置位 `W.pendingLocalEdit`；两组都输 ⇒ **零写、不置位**（§8.4.5）。
    ///
    /// **W 那一侧的戳按单元取 `max(行戳, 有效账户戳)`**（R-M3-4a-98）：行戳会滞后于账户
    /// （新行那一列是 `nil`、`rebaselined` 只刷基线不写行），只读行会把账户上更新的那份取值
    /// 覆写掉，而本页没有到 W 的 `.update` 时 R-M3-4a-93 的相序救不了。`targetEffectiveStamps`
    /// 由落地批次从 `URLRuleApplyBatch.accountStamps` 里取 W 那一条填进来（与页内 M2 尾钩用的
    /// 是同一张表），**不开新的协议成员**；取不到 ⇒ 两枚按 `nil` 处理、`max` 退化成行戳。
    ///
    /// **原语这一层不认识 X**：R-M3-4a-102 的「来源行未变」复查在批次执行器里做完，这里只管
    /// 往 W 上写。寻址定义域是含软删行的那一份 `URLRuleTableIndex`（R-M3-4a-56）；
    /// `toSyncId` 在整表都找不到 ⇒ 返回 0、零写、**不抛**。
    @discardableResult
    func transferURLRuleEditThrowing(toSyncId: String, source: RuleProjection,
                                     targetEffectiveStamps: URLRuleEffectiveStamps) async throws
        -> Int {
        try await performBackgroundWriteAndWaitThrowing { context -> Int in
            var index = try self.urlRuleTableIndex(in: context)
            return try self.transferURLRuleEditBody(toSyncId: toSyncId, source: source,
                                                    targetEffectiveStamps: targetEffectiveStamps,
                                                    index: &index, in: context).written
        }
    }

    /// 一次转移真的写下去了什么。`movedFrom` 非 nil = 目标单元赢下、W 换了桶，**源桶与目标桶
    /// 都要进本页的重排定义域**（R-M3-4a-3）。
    struct URLRuleTransferResult: Equatable {
        var written = 0
        /// 内容组输掉 ⇒ 计一次 `superseded_by_delete`（§13.3）。
        var contentSuperseded = false
        var movedFrom: String?
    }

    /// R-exec-2 的 body 兄弟（批次入口要在同一个写块、同一份索引上调它）。判定整个交给
    /// `URLRuleKind.transferDecision(target:source:targetEffectiveStamps:)`——生产落地与假件
    /// 读**同一份**判据，两处各写一份的实现迟早在「谁赢」上分叉。
    @discardableResult
    func transferURLRuleEditBody(toSyncId: String, source: RuleProjection,
                                 targetEffectiveStamps: URLRuleEffectiveStamps,
                                 index: inout URLRuleTableIndex,
                                 in context: ModelContext) throws -> URLRuleTransferResult {
        var out = URLRuleTransferResult()
        guard let row = index.bySyncId[toSyncId] else {
            // 寻址不到 ⇒ 零写、不抛（同族守卫见 `softDeleteURLRuleBody`）。
            out.contentSuperseded = true
            return out
        }
        // 同款守卫，见 `upsertURLRuleBody`。
        guard row.syncId == nil || row.syncId == toSyncId else {
            throw LocalStoreWriteError.rowAlreadyMapped
        }
        let decision = URLRuleKind.transferDecision(target: Self.projectURLRule(row),
                                                    source: source,
                                                    targetEffectiveStamps: targetEffectiveStamps)
        out.contentSuperseded = decision.contentSuperseded
        out.written = decision.written
        if decision.writesContent {
            // §8.1 的幂等归一（来源行可能是 V11 回填的老行）；三个字段连同 source 的那一枚
            // 组戳一起写，**照抄，绝不铸 `now`**（D33 / §8.4.1 第五条）。
            let normalized = LocalStore.normalizedRule(host: source.host,
                                                       pathPrefix: source.pathPrefix)
            row.host = normalized.host
            row.pathPrefix = normalized.pathPrefix
            row.askBeforeRouting = source.askBeforeRouting
            row.contentUpdatedDate = source.contentUpdatedDate
        }
        if decision.writesTarget, let spaceId = source.targetSpaceId {
            if row.spaceId != spaceId {
                out.movedFrom = row.spaceId
                row.spaceId = spaceId
            }
            row.targetUpdatedDate = source.targetUpdatedDate
        }
        // §8.4.5：**`written > 0` 才置位**。无条件置位会给 W 留一个永不清掉的标志——它从此
        // 永久退出静止（M2 不再收敛它）、并对每一次远端删除让位。
        if out.written > 0, !row.pendingLocalEdit { row.pendingLocalEdit = true }
        return out
    }

    // MARK: - 落地批次入口（R-exec-2）

    /// 一页远端落地的**全部**操作，一个写块、一个事务（§5.5）。
    /// ops 已由 `URLRuleApplyBatch` 合并与排序，这里**按序执行、不再重排**。
    ///
    /// **必须住在这个文件里**：per-row 的 throwing 兄弟各开一次 `performBackgroundWriteAndWaitThrowing`
    /// （串行写流），在写块里调它们会自我死锁；共享的 `…Body` 半边只有这里能在同一个 `context` 里
    /// 组合。抛错 = `performThrowing` 回滚整批，一条都没落。
    ///
    /// **`ops` 为空、但带着尾钩的批次照样开一次事务**（R-M3-4a-56：一页没有任何规则落地时
    /// 同样要跑 M2，那一页单开一次同形事务）。两者都空才是真的无事可做。
    @discardableResult
    func applyURLRuleSyncBatchThrowing(_ ops: [URLRuleSyncOp],
                                       mergeTail: URLRuleMergeTail? = nil) async throws
        -> URLRuleBatchOutcome {
        guard !ops.isEmpty || mergeTail != nil else { return URLRuleBatchOutcome() }
        return try await performBackgroundWriteAndWaitThrowing { context in
            try self.applyURLRuleSyncBatchBody(ops, mergeTail: mergeTail, in: context)
        }
    }

    /// 事务体。分出来只为可读性，没有第二个调用方。块内**五件事**，顺序固定（8b-2 在 Task 8
    /// 的四件事里插了第 ③ 件）：
    /// 1. **一次**把整张表（含软删行）按 `syncId` 建索引；
    /// 2. 按序执行每个 op（`URLRuleApplyBatch.init` 已经按四相排好，这里**不再重排**）——
    ///    `.transfer`（第三相，8b-3）先做 R-M3-4a-102 的「来源行未变」复查再写伙伴行；
    ///    `.create` / `.update` / `.move` 都落到 `upsertURLRuleBody`（行不存在就建，
    ///    两个远端戳照抄载荷，命中软删行就在同一次行写里清 `deletedDate` / `mergePartnerSyncId`），
    ///    `.reorder` 只写 `sortOrder`，`.delete` 走 `hardDeleteURLRuleBody`（真删）；`pendingLocalEdit`
    ///    一个字节都不碰；
    /// 3. 记账「被触及的桶」：`.create` ⇒ 目标桶；`.move` ⇒ 写 `spaceId` **之前**读到的源桶 + 目标桶
    ///    （R-M3-4a-3）；`.reorder` ⇒ 本桶；`.delete` ⇒ 删之前读到的桶；`.update` ⇒ **不记**（它只改
    ///    内容组，次序没动；一次白写会经 §6.5 的 publisher 变成一次多余的推送轮）——只有它**进了桶**
    ///    （建了新行，R-M3-4a-42(a)；或救回了一条软删行，§5.5「行存在」一格）或（防御）目标真的变了才记；
    /// 4. **尾钩**（8b-2 / R-M3-4a-56）：把此刻的行投影（含软删行）交给
    ///    `URLRuleMergeTail.evaluate`，按序执行它交回的 M2 ops，并把它报的桶**并进**第 ③ 步
    ///    那份记账。**排在稠密重排之前**：排在之后的实现会在败者离开的桶里留下一个空洞下标。
    /// 5. 收尾：对被触及的每个桶各跑一次稠密重排——排除软删行（R-M3-4a-51）后按当前 `(sortOrder, id)`
    ///    升序写 `sortOrder = index`，只写真的变了的行。
    private func applyURLRuleSyncBatchBody(_ ops: [URLRuleSyncOp],
                                           mergeTail: URLRuleMergeTail?,
                                           in context: ModelContext) throws
        -> URLRuleBatchOutcome {
        var outcome = URLRuleBatchOutcome()
        var index = try urlRuleTableIndex(in: context)
        var touchedBuckets: Set<String> = []
        // R-M3-4a-102 / 裁定 11：**只有 (α) 那一对**要做「来源行未变」复查。判别标准写死成
        // 「这条 `.transfer` 的同身份 `.delete` 在不在同一批里」——`plan` 的 (α) 支产出这一对、
        // (β) 支只产出 `.transfer`，两者在 op 列表上结构可分。
        // (β) 的取值源是本轮那条入站 `merged`、不是本机行，拿本机行去比必然不等 ⇒ 把复查加到
        // 每一条 `.transfer` 上的实现会让 (β) 永远转移不成、终态两条规则。
        var alphaSources: Set<String> = []
        for op in ops {
            if case .delete(let syncId) = op { alphaSources.insert(syncId) }
        }

        /// 一条 op 的执行。第 ② 步与第 ④ 步（尾钩）**共用它**：M2 的三条与落地那五条在同一个
        /// 事务、同一份索引上写，两处各写一份的实现迟早在记桶上分叉。
        func execute(_ op: URLRuleSyncOp) throws {
            switch op {
            case .create(let values):
                try upsertURLRuleBody(values, index: &index, in: context)
                touchedBuckets.insert(values.spaceId)
            case .update(let values):
                // 两个判据都要在 upsert **之前**读：命中软删行时 upsert 会当场清掉 `deletedDate`。
                let existing = index.bySyncId[values.syncId]
                let sourceBucket = existing?.spaceId
                // 「进了桶」= 行不存在（建行，R-M3-4a-42(a)）或命中的是软删行（救回，§5.5「行存在」
                // 一格）：两种情况下这一行在 `siblings(inSpaceId:)` 的活行定义域里都**从没被数过**，
                // 落在载荷的下标上会撞上一条活行（R-M3-4a-3 / RR-B9），所以目标桶必须重排。救回那次
                // 写本来就改了 `deletedDate`，同一事务里重排不多出任何一次 publisher 信号。
                let entersBucket = existing == nil || existing?.deletedDate != nil
                try upsertURLRuleBody(values, index: &index, in: context)
                if entersBucket {
                    touchedBuckets.insert(values.spaceId)
                } else if let sourceBucket, sourceBucket != values.spaceId {
                    touchedBuckets.insert(sourceBucket)
                    touchedBuckets.insert(values.spaceId)
                }
            case .move(let values):
                let sourceBucket = index.bySyncId[values.syncId]?.spaceId
                try upsertURLRuleBody(values, index: &index, in: context)
                if let sourceBucket {
                    touchedBuckets.insert(sourceBucket)
                }
                touchedBuckets.insert(values.spaceId)
            case .reorder(let syncId, _, let sortOrder):
                // 没有载荷，无从建行：命中不到就跳过（那条身份这一页没有行可排）。
                guard let row = index.bySyncId[syncId] else { return }
                if row.sortOrder != sortOrder {
                    row.sortOrder = sortOrder
                }
                touchedBuckets.insert(row.spaceId)
            case .delete(let syncId):
                // R-M3-4a-102：(α) 的复查不过 ⇒ `.transfer` 与**同身份的 `.delete`** 两条
                // op 都不执行（相序保证 `.transfer` 已经先跑过、集合已经填好）。
                guard !outcome.deferredTombstones.contains(syncId) else { return }
                if let bucket = try hardDeleteURLRuleBody(syncId: syncId, index: &index, in: context) {
                    touchedBuckets.insert(bucket)
                }
            case .transfer(let fromSyncId, let toSyncId, let source, let stamps):
                if alphaSources.contains(fromSyncId),
                   !URLRuleKind.transferSourceUnchanged(
                       row: index.bySyncId[fromSyncId].map(Self.projectURLRule), source: source) {
                    // 来源行在 pre-pass 与这次事务之间被用户改过（或已不在 / 已软删）⇒
                    // W 一个字节不写、X 一个字节不写、`transferred` 不加，身份交回引擎按
                    // `plan.parkedTombstones` 停放，下一页 / 下一轮拿**新**取值重判。
                    outcome.deferredTombstones.insert(fromSyncId)
                    return
                }
                let result = try transferURLRuleEditBody(toSyncId: toSyncId, source: source,
                                                         targetEffectiveStamps: stamps,
                                                         index: &index, in: context)
                if result.written > 0 { outcome.transferred += 1 }
                if result.contentSuperseded { outcome.transferSupersededByDelete += 1 }
                // 目标单元赢下 ⇒ W 换了桶 ⇒ 源桶与目标桶都进重排定义域（R-M3-4a-3）。
                if let movedFrom = result.movedFrom {
                    touchedBuckets.insert(movedFrom)
                    if let bucket = index.bySyncId[toSyncId]?.spaceId {
                        touchedBuckets.insert(bucket)
                    }
                }
            case .rekey(let localId, let syncId, let values):
                // §8.4.2 M1：先 re-key（只写 `syncId`），带 `values` 时同一个写块里紧接着按**新**
                // 身份 upsert（`index.rekey` 已经让它命中这一行）。认领的行第一次拿到账户级 rank，
                // 桶按投影重排一次，所以目标桶记账（与 `.create` 同一条理由）。
                try rekeyURLRuleBody(localId: localId, to: syncId, index: &index, in: context)
                if let values {
                    assert(values.syncId == syncId, "url rule batch: rekey values carry another identity")
                    let sourceBucket = index.bySyncId[syncId]?.spaceId
                    try upsertURLRuleBody(values, index: &index, in: context)
                    touchedBuckets.insert(values.spaceId)
                    if let sourceBucket, sourceBucket != values.spaceId {
                        touchedBuckets.insert(sourceBucket)
                    }
                }
            // 8b-2 的三条（§8.4.3）。**只由尾钩产出**，落地那一批里不会有它们。
            case .softDelete(let syncId, let mergePartnerSyncId):
                if let bucket = try softDeleteURLRuleBody(syncId: syncId,
                                                          mergePartnerSyncId: mergePartnerSyncId,
                                                          index: &index, in: context) {
                    touchedBuckets.insert(bucket)
                }
            case .setMergePartner(let syncId, let mergePartnerSyncId):
                // **不记桶**：这一列不进路由表、不改次序（CASE M-7 的「零次行写以外的动静」）。
                try setURLRuleMergePartnerBody(syncId: syncId,
                                               mergePartnerSyncId: mergePartnerSyncId,
                                               index: &index, in: context)
            case .setContentGroup(let syncId, let host, let pathPrefix, let ask,
                                  let contentUpdatedDate):
                // 同上：内容组不改桶内次序（`sortOrder` 一个字节不碰）。
                try setURLRuleContentGroupBody(syncId: syncId, host: host, pathPrefix: pathPrefix,
                                               ask: ask, contentUpdatedDate: contentUpdatedDate,
                                               index: &index, in: context)
            }
        }

        // ② 落地 op，按序。
        for op in ops { try execute(op) }

        // ④ 尾钩：R-M3-4a-56 写死「全部落地写之后、稠密重排之前、同一个事务」。交给它的是
        //    `index.rows` 此刻那份投影（**含软删行**，寻址要它；活行过滤在 `mergePass` 里，
        //    与 `allURLRules()` 同一条判据）——零额外读，也正是 R-M3-4a-100 的剔除依据。
        if let mergeTail {
            let result = mergeTail.evaluate(index.rows.map(Self.projectURLRule))
            for op in result.ops { try execute(op) }
            touchedBuckets.formUnion(result.touchedBuckets)
            outcome.collapsed = result.collapsed
            outcome.mergeChangedRouting = result.changedRouting
        }

        // ⑤ 收尾稠密重排。
        for bucket in touchedBuckets {
            let live = index.rows
                .filter { $0.spaceId == bucket && $0.deletedDate == nil }
                .sorted { ($0.sortOrder, $0.id) < ($1.sortOrder, $1.id) }
            for (position, row) in live.enumerated() where row.sortOrder != position {
                row.sortOrder = position
            }
        }
        return outcome
    }

    /// 事务内的取值快照，**绝不是 model 对象**（同步层的 `PhiLocalURLRule` 上有完整说明）。
    /// 与 `AccountPhiURLRuleAccess.project` 逐字同形，只是那一份读的是主 context 的 fetch、
    /// 这一份读的是写块里那份**已经被本页落地写改过**的索引。
    private static func projectURLRule(_ model: SpaceURLRule) -> PhiLocalURLRule {
        PhiLocalURLRule(id: model.id,
                        syncId: model.syncId,
                        spaceId: model.spaceId,
                        host: model.host,
                        pathPrefix: model.pathPrefix,
                        askBeforeRouting: model.askBeforeRouting,
                        sortOrder: model.sortOrder,
                        createdDate: model.createdDate,
                        contentUpdatedDate: model.contentUpdatedDate,
                        targetUpdatedDate: model.targetUpdatedDate,
                        deletedDate: model.deletedDate,
                        pendingLocalEdit: model.pendingLocalEdit,
                        mergePartnerSyncId: model.mergePartnerSyncId)
    }

    /// 九个字段的载荷形式，转发到上面那个逐参数的 body。
    @discardableResult
    private func upsertURLRuleBody(_ values: URLRuleLandingValues,
                                   index: inout URLRuleTableIndex,
                                   in context: ModelContext) throws -> SpaceURLRule {
        try upsertURLRuleBody(syncId: values.syncId,
                              spaceId: values.spaceId,
                              host: values.host,
                              pathPrefix: values.pathPrefix,
                              ask: values.askBeforeRouting,
                              sortOrder: values.sortOrder,
                              createdDate: values.createdDate,
                              contentUpdatedDate: values.contentUpdatedDate,
                              targetUpdatedDate: values.targetUpdatedDate,
                              index: &index,
                              in: context)
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

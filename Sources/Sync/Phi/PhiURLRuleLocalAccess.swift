// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// 一条本机规则行的值快照。**绝不是 model 对象**：SwiftData 就地刷新同一批实例，按对象
/// 比较的去重会吞掉真实字段编辑（`LocalStore+Space.swift:431-452`、`LocalStore.swift:536-540`
/// 两处都为此栽过跟头）。与 `PhiLocalBookmark`（`PhiBookmarkLocalAccess.swift`）同款：住在
/// `Sources/Sync/Phi/`、**不依赖 `LocalStorage`**，所以同步层可以在没有 SwiftData 的测试
/// 进程里整体构造。协议 `PhiURLRuleLocalAccess` 与 `AccountPhiURLRuleAccess` 由 Task 8
/// 追加进同一个文件（M3-3 PR2 的形状：值类型先于生产实现）。
struct PhiLocalURLRule: Equatable {
    /// 本机物理行的 id（`SpaceURLRule.id`）。落地的每一个操作都按它定位。
    var id: String
    /// 账户级 uuid（小写，`SpaceURLRule.syncId`）。插入点铸造（R-M3-4a-23），所以对一条活行
    /// **实际恒非 nil**；类型仍是可选，因为 V11 之前的历史行要经 backfill 才拿到它。
    var syncId: String?
    /// 目标 Space 的本机 id；Incognito 目标是裸前缀 `SpaceManager.incognitoRuleTargetId`。
    var spaceId: String
    var host: String
    /// nil = 匹配任意路径（线上是 `""`）；`"/"` = 只匹配根。两者是**不同的值**（§8.1）。
    var pathPrefix: String?
    var askBeforeRouting: Bool
    /// 桶内稠密下标（§8.3）；线上只有 `rank`，两者由 `URLRuleKind.rankToSortOrder` 投影。
    var sortOrder: Int
    var createdDate: Date
    /// nil = 从未改过内容组，无基线投影的内容组戳退回 `createdDate`（R-M3-4a-12）。
    var contentUpdatedDate: Date?
    /// R-M3-4a-73：§8.2 的无基线分支取 `targetUpdatedDate ?? createdDate`。
    var targetUpdatedDate: Date?
    /// 软删标记（R-M3-4a-41）。`allURLRulesIncludingDeleted()` 交回软删行，调用方靠它分辨。
    var deletedDate: Date?
    /// R-M3-4a-65 的用户编辑信号。kind 适配（Task 7）**一处都不读**（读点穷举为二，都在
    /// 8b-1 / 8b-3）。
    var pendingLocalEdit: Bool
    /// R-M3-4a-71 的合并伙伴。**本机状态、不上线、不进实体、不进签名**；kind 适配不读不写。
    var mergePartnerSyncId: String?
}

// MARK: - 落地值类型（§5.5「合并后的一次写」）

/// 一次落地写要写进一条行的**全部**取值（§5.5「合并后的一次写」）。
///
/// **九个字段就是落地允许写的全部列**：`deletedDate` / `pendingLocalEdit` /
/// `mergePartnerSyncId` 刻意不在里面——落地一律不碰 `pendingLocalEdit`（清位只在发布段的
/// 两处，§8.4.5），另两列由批次入口按 §5.5「行存在」那一格自己处置。**不复用**
/// `PhiLocalURLRule`：那个类型带着本机 `id` 与三列本机状态，拿它当落地载荷会让「引擎写了
/// 一列它不该写的东西」变成一次编译得过的手滑。
struct URLRuleLandingValues: Equatable, Sendable {
    var syncId: String
    var spaceId: String
    var host: String
    var pathPrefix: String?
    var askBeforeRouting: Bool
    /// 本页的**最终稠密下标**，由 §8.3 的 `(rank ?? "", syncId ?? id)` 投影在协议**之上**
    /// 算好（R-exec-2 的书签先例：`rankToIndex` 跑在协议之上，批次入口只做收尾稠密化）。
    var sortOrder: Int
    /// 载荷的 `created_at_ms`（R-M3-4a-20）。
    var createdDate: Date
    /// 合并结果的**内容组戳**（R-M3-4a-20 / R-M3-4a-48）。**绝不是 `now`**：引擎不铸戳。
    var contentUpdatedDate: Date
    /// 合并结果的**目标戳**。同上。
    var targetUpdatedDate: Date
}

/// 落地一条远端规则所需的**单个**本机写操作。
enum URLRuleSyncOp: Equatable, Sendable {
    /// 行不存在（**含软删行的定义域里也找不到**）⇒ 按载荷建行（R-M3-4a-42(a)）。
    case create(URLRuleLandingValues)
    /// 就地改内容组 + 两个远端戳，桶不变。
    case update(URLRuleLandingValues)
    /// 改目标（rehome）：连同内容组与两个远端戳一次写完，**源桶与目标桶都进重排定义域**
    /// （R-M3-4a-3）。
    case move(URLRuleLandingValues)
    /// 纯重排：**只写 `sortOrder`、只重排本桶**，`spaceId` 与两枚戳一个字节都不写。
    case reorder(syncId: String, spaceId: String, sortOrder: Int)
    /// 入站 tombstone ⇒ **硬删**（R-M3-4a-41）。
    case delete(syncId: String)

    /// 这条 op 指向的账户级身份。
    var syncId: String {
        switch self {
        case .create(let values), .update(let values), .move(let values):
            return values.syncId
        case .reorder(let syncId, _, _), .delete(let syncId):
            return syncId
        }
    }
}

/// 一页远端落地要施加的**全部**规则操作，已按 §5.5 合并与排序。
///
/// **是操作列表，不是单个枚举**：`apply(_:)` 一次要落一整页的多条行，而 §5.5 的落地契约
/// 要求它们在**一个**事务里（部分成功不存在）。
struct URLRuleApplyBatch {
    private(set) var ops: [URLRuleSyncOp]

    /// `currentSpaceIds`：**本页那一次** `allURLRulesIncludingDeleted()` 给的
    /// `syncId -> 行现值 spaceId`。init 做两件事，缺一不可：
    ///
    /// ① **同一 `syncId` 的多条 step 合成一条**（R-M3-4a-42(b) / RR-B9）。模块会为一次
    ///    「同时改了内容与目标」的入站实体产出 `.move`（第一相）与 `.update`（第二相）
    ///    两条（`SyncableOwnedItems.swift` 的两相），而两条带的是**同一份**合并结果，
    ///    所以合并就是择一：目标真的变了留 `.move`，没变留 `.update`。分两次写会让
    ///    `.update` 在 `.move` 之后再写一次归属，行落进一个**从没被重排过**的桶。
    /// ② **`.move` 的降级**（CASE U-10b）：`currentSpaceIds[syncId] == values.spaceId`
    ///    ⇒ 目标没动，这是一次纯重排 ⇒ 降成 `.reorder`（只有 `.move`、没有 `.update`
    ///    的那一种；有 `.update` 的按 ① 留 `.update`）。把 `.move` 一律当 rehome 会白
    ///    重排一个这一页根本没被碰过的桶。
    ///
    /// 相序：① `create` / `update` / `move` / `reorder` ② `delete`；相内**稳定**（保持传入
    /// 次序，按身份首次出现的位置）。规则之间没有父子，所以相序只为让「被触及的桶」这份
    /// 记账有确定的求值点。
    init(unordered: [URLRuleSyncOp], currentSpaceIds: [String: String] = [:]) {
        // 一身份一槽，按首次出现的次序；同类 op 重复出现时后到的覆盖先到的（两条带的是同一份
        // 合并结果，择哪条都一样）。
        struct Slot {
            var create: URLRuleLandingValues?
            var update: URLRuleLandingValues?
            var move: URLRuleLandingValues?
            var reorder: (spaceId: String, sortOrder: Int)?
            var delete = false
        }
        var order: [String] = []
        var slots: [String: Slot] = [:]
        for op in unordered {
            let syncId = op.syncId
            if slots[syncId] == nil {
                slots[syncId] = Slot()
                order.append(syncId)
            }
            switch op {
            case .create(let values): slots[syncId]?.create = values
            case .update(let values): slots[syncId]?.update = values
            case .move(let values): slots[syncId]?.move = values
            case .reorder(_, let spaceId, let sortOrder): slots[syncId]?.reorder = (spaceId, sortOrder)
            case .delete: slots[syncId]?.delete = true
            }
        }

        var upgrades: [URLRuleSyncOp] = []
        var deletes: [URLRuleSyncOp] = []
        for syncId in order {
            guard let slot = slots[syncId] else { continue }
            var merged: URLRuleSyncOp?
            if let move = slot.move {
                if currentSpaceIds[syncId] == move.spaceId {
                    // 目标没动。内容要写的留 `.update`；行本页不存在的留 `.create`（两者都落到
                    // 同一个 upsert，只是记桶的规则不同）；否则就是一次纯重排。
                    if let update = slot.update {
                        merged = .update(update)
                    } else if let create = slot.create {
                        merged = .create(create)
                    } else {
                        merged = .reorder(syncId: syncId, spaceId: move.spaceId, sortOrder: move.sortOrder)
                    }
                } else {
                    // 目标真的变了（或本页快照里没有这条身份，现值未知）⇒ rehome，`.move` 自己
                    // 带着新 `spaceId` 与全部内容，`.update` 那份内容一个字节都不会丢。
                    merged = .move(move)
                }
            } else if let create = slot.create {
                merged = .create(create)
            } else if let update = slot.update {
                merged = .update(update)
            } else if let reorder = slot.reorder {
                merged = .reorder(syncId: syncId, spaceId: reorder.spaceId, sortOrder: reorder.sortOrder)
            }
            if slot.delete {
                // 同一条身份不会既有一条升级写又有一条 `.delete`。(α) 的 `.transfer` + `.delete`
                // 组合是 Task 8b-3 的，届时这条断言随之放宽。相序让 `.delete` 落在最后，所以
                // 真的撞上时终态仍是确定的（删）。
                assert(merged == nil, "url rule batch: identity \(syncId.prefix(8)) has both an upgrade and a delete")
                deletes.append(.delete(syncId: syncId))
            }
            if let merged {
                upgrades.append(merged)
            }
        }
        ops = upgrades + deletes
    }
}

// MARK: - 协议基座

/// 引擎读写本机规则行的**唯一**接缝。引擎是 `actor`，它照既有 `PhiSpaceLocalAccess`
/// （`PhiSpaceLocalAccess.swift`）的写法 hop 到 main actor 上调这些方法。
///
/// **本文件此刻交的是基座子集**（附录 C-4 是成员归属的权威表）。后续任务往协议、
/// `AccountPhiURLRuleAccess` 与 `FakeURLRuleAccess` 三处同 commit 追加：
/// Task 6 `refreshRoutingTableAfterLanding()`；Task 9 `hardDeleteURLRule(syncId:)` /
/// `purgeSoftDeletedURLRules(olderThan:)`；8b-1 `signatureIndex(resolve:)` /
/// `pendingLocalEditIdentities` / `unpublishedIdentities` / `mergePartners` /
/// `notePersistedClaims` / `noteDeletedRows`；8b-3 `partnerNotAtRest(table:rows:resolve:tombstonesThisPage:)`；
/// 8b-4 `clearPendingLocalEdit(syncId:ifProjectionEquals:)` / `clearPendingLocalEditIfUnchanged(entries:)`。
///
/// 生产实现是本文件末尾的 `AccountPhiURLRuleAccess`。
@MainActor
protocol PhiURLRuleLocalAccess: AnyObject {
    /// 全账户的**活**规则行（`deletedDate == nil`），按 `(spaceId, sortOrder, id)` 有序。
    /// **一次 fetch，每页至多一次**（R-M3-4a-62：规则的轮内投影**不是轮首冻结**的，每一页
    /// 落地段提交之后重读一次），由引擎缓存后交给 sortOrder 投影、收敛与落地复用。
    /// **软删行不在里面**（R-M3-4a-51）：它们不参与稠密重排、不参与路由。
    ///
    /// **抛错，绝不返回空数组**（R-exec-3）：差分对空集合的回答是给每一条游标发一条
    /// tombstone，也就是抹掉全账户的规则并让每台设备跟着抹。
    func allURLRules() throws -> [PhiLocalURLRule]

    /// **快照与差分专用**：活行 ∪ 软删行（R-M3-4a-51）。差分必须看见软删行才能产出
    /// tombstone（软删行退出 `locals`，§5.7），而稠密重排必须看不见它们。
    /// 与上面同一次 fetch，只是不加那道过滤。
    func allURLRulesIncludingDeleted() throws -> [PhiLocalURLRule]

    /// 某个目标 Space 桶内的**未过滤**次序（「未过滤」= 不按同步合格性过滤；**软删行仍然
    /// 排除**），供 §8.3 的稠密 sortOrder 投影使用。
    /// **不是第二次 fetch**：它读的是**本页**那一次 `allURLRules()` 的结果按 `spaceId` 在
    /// 内存里分的组。
    func siblings(inSpaceId spaceId: String) -> [PhiLocalURLRule]

    /// 与 `allURLRules()` **同源**的独立谓词，判据是 `syncId`、不是 `id`。
    func isKnownLocalURLRule(_ syncId: String) -> Bool

    /// §9.3 保留期级联在本机这一侧的唯一读口（R-M3-4a-36 / R-exec-11 的身份粒度等价物）。
    /// 收本轮命中判据 (a) 的候选身份，交回其中**本机还有活行认领**的那些。
    /// **抛 ⇒ 这条 kind 的级联整段不跑**（R-exec-3）。定义域是 `allURLRules()` 那一次
    /// **整库**读，不是快照（R-exec-4 / R-exec-8）。
    ///
    /// 协议手上没有 resolver，所以生产实现**只填 `claimed`**、`owners` 留空；Task 6 的
    /// `.urlRules` 注册项闭包拿回来的身份配 `OwnedOwnerMaps` 补 `owners`。
    func liveOwners(_ candidates: Set<String>) throws -> OwnedLiveRows

    /// 一整页远端落地，**一个**事务（§5.5）。抛错 = 一条都没落，调用方不许写基线。
    func apply(_ batch: URLRuleApplyBatch) async throws
}

// MARK: - 生产实现

/// 生产实现，与 `AccountPhiPinnedTabAccess`（`PhiPinnedTabLocalAccess.swift`）并列：
/// **init 收 `LocalStore`，不收 `Account`**——`AccountPhiBookmarkAccess(account:)` 经懒加载的
/// `account.localStorage` 去够真实用户目录，生产类在测试里根本驱动不了；收 `LocalStore` 让
/// CASE U-10 / U-10f / U-16 / U-26 全都能在一个临时目录的真 `LocalStore` 上跑。协调器在
/// `buildPhiSyncEngine` 里本来就拿得到 `account.localStorage`，生产行为一字不变。
@MainActor
final class AccountPhiURLRuleAccess: PhiURLRuleLocalAccess {
    private let store: LocalStore
    /// 本页那一次 fetch 的投影。`allURLRules()` / `allURLRulesIncludingDeleted()` 重建，
    /// `siblings(inSpaceId:)` 与 `isKnownLocalURLRule(_:)` 复用，**不再 fetch**。
    private var cachedRows: [PhiLocalURLRule] = []          // 含软删行
    private var cachedLive: [PhiLocalURLRule] = []          // 过滤软删行
    private var cachedSiblings: [String: [PhiLocalURLRule]] = [:]
    private var cachedLiveSyncIds: Set<String> = []
    /// 本页有没有一份可用的快照。区分「读到了，就是空的」与「没读到」——后者让两个非抛出
    /// 的读者答「都不在」，而那正是会让引擎把每条身份都判成死映射的静默默认值。
    private var snapshotIsLoaded = false

    init(store: LocalStore) {
        self.store = store
    }

    // MARK: - 读

    func allURLRules() throws -> [PhiLocalURLRule] {
        try rebuildCache()
        return cachedLive
    }

    func allURLRulesIncludingDeleted() throws -> [PhiLocalURLRule] {
        try rebuildCache()
        return cachedRows
    }

    func siblings(inSpaceId spaceId: String) -> [PhiLocalURLRule] {
        guard requireLoadedSnapshot() else { return [] }
        return cachedSiblings[spaceId] ?? []
    }

    func isKnownLocalURLRule(_ syncId: String) -> Bool {
        guard requireLoadedSnapshot() else { return false }
        return cachedLiveSyncIds.contains(syncId)
    }

    /// **自己做一次 fetch**，不读、也不覆盖本页缓存：保留期级联跑在轮末、每轮至多一次，而本页
    /// 缓存是 R-M3-4a-62 的落地段不变量，被它换掉就是把「每页刷新」偷偷改成「级联刷新」。
    /// 读失败**抛**（R-exec-3）。
    func liveOwners(_ candidates: Set<String>) throws -> OwnedLiveRows {
        guard let context = store.getMainContext() else {
            AppLogError("[phi-sync] url rule live-owner read failed: no main context")
            throw LocalStoreWriteError.storeUnavailable
        }
        let models: [SpaceURLRule]
        do {
            models = try store.allURLRuleModelsIncludingDeleted(in: context)
        } catch {
            // R12：只记类型与 domain/code，不记任何行内容。
            AppLogError("[phi-sync] url rule live-owner fetch failed: \(PhiSyncLog.describe(error))")
            throw error
        }
        var claimed: Set<String> = []
        for model in models where model.deletedDate == nil {
            if let syncId = model.syncId, candidates.contains(syncId) {
                claimed.insert(syncId)
            }
        }
        return OwnedLiveRows(claimed: claimed, owners: [:])
    }

    // MARK: - 写

    /// 薄转发：事务、按序执行、两桶稠密重排全在 `LocalStore.applyURLRuleSyncBatchThrowing`
    /// （`LocalStore+SpaceURLRule.swift`）里（R-exec-2）。
    ///
    /// **成功之后就地重读一遍**（R-M3-4a-62 的「每页刷新」在这里落地），不是清空了事。这次
    /// 重读抛了就原样上抛，**但那一批已经提交了**——调用方必须把它当成「落地成功、快照跟不上」，
    /// 而不是「没落地」，与 `AccountPhiBookmarkAccess.apply` 逐字同一条契约。
    func apply(_ batch: URLRuleApplyBatch) async throws {
        try await store.applyURLRuleSyncBatchThrowing(batch.ops)
        try rebuildCache()
    }

    // MARK: - 私有

    private func invalidateCache() {
        cachedRows = []
        cachedLive = []
        cachedSiblings = [:]
        cachedLiveSyncIds = []
        snapshotIsLoaded = false
    }

    /// 两个非抛出读者共用的前置判断。返回 false 时调用方交出「不在」那个值——它是**错的**，
    /// 只是签名里没有别的东西可交，所以 DEBUG 下直接炸，让误用在引擎用例里当场现形。
    private func requireLoadedSnapshot() -> Bool {
        if !snapshotIsLoaded {
            assertionFailure("read the url rule snapshot before a successful allURLRules()/apply()")
        }
        return snapshotIsLoaded
    }

    /// **失败一律抛，而且先把缓存清干净**（R-exec-3），形状照 `AccountPhiBookmarkAccess.rebuildCache()`。
    /// 一次 `FetchDescriptor<SpaceURLRule>()`（含软删行），两份定义域与两份索引一起换上。
    private func rebuildCache() throws {
        invalidateCache()
        guard let context = store.getMainContext() else {
            AppLogError("[phi-sync] url rule snapshot failed: no main context")
            throw LocalStoreWriteError.storeUnavailable
        }
        let models: [SpaceURLRule]
        do {
            models = try store.allURLRuleModelsIncludingDeleted(in: context)
        } catch {
            AppLogError("[phi-sync] url rule snapshot fetch failed: \(PhiSyncLog.describe(error))")
            throw error
        }
        // 次序 `(spaceId, sortOrder, id)` 是契约的一部分：差分按它产出提交序列，index 投影按它编号。
        let rows = models.map(Self.project).sorted {
            ($0.spaceId, $0.sortOrder, $0.id) < ($1.spaceId, $1.sortOrder, $1.id)
        }
        let live = rows.filter { $0.deletedDate == nil }
        var siblings: [String: [PhiLocalURLRule]] = [:]
        var liveSyncIds: Set<String> = []
        for row in live {
            siblings[row.spaceId, default: []].append(row)
            if let syncId = row.syncId {
                liveSyncIds.insert(syncId)
            }
        }
        cachedRows = rows
        cachedLive = live
        cachedSiblings = siblings
        cachedLiveSyncIds = liveSyncIds
        snapshotIsLoaded = true
    }

    /// 取值快照，绝不是 model 对象（见 `PhiLocalURLRule` 上的说明）。
    private static func project(_ model: SpaceURLRule) -> PhiLocalURLRule {
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
}

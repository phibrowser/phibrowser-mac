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
    /// §8.4.2 的认领：`.claim` step 的落地形式。**按本机行 `id` 寻址**（`OwnedItemApplyStep`
    /// 既不带旧 `syncId` 也不带本机 id，而 `context.pairs` 带的正是后者）。
    /// `values != nil` = 这条身份在 `context.adoptedFieldWrites` 里 ⇒ re-key 与字段合并结果
    /// **写在同一次行写里**（R-M3-4a-42(b)：一页里同一条身份只有一次落地写）。
    case rekey(localId: String, to: String, values: URLRuleLandingValues?)

    // MARK: 8b-2：§8.4.3 的 M2 三条。**只由落地段尾钩产出**（`URLRuleMergeTail`），不经
    // `URLRuleApplyBatch` 的合并与降级——它们不是「落地一条远端实体」，而是本机收敛的补写。

    /// §8.4.3 第 2 步 (b) 的败者软删。`deletedDate` 与 `mergePartnerSyncId` **同一次行写**
    /// （RR8-4）；编辑器那条删除路径传 `nil`。**`pendingLocalEdit` 一个字节不碰**。
    case softDelete(syncId: String, mergePartnerSyncId: String?)
    /// §8.4.3 第 1 步的提示写，**只写这一列**；`nil` 就是清空（两条清空规则走它）。
    case setMergePartner(syncId: String, mergePartnerSyncId: String?)
    /// §8.4.3 第 2 步 (a) 的胜者吸收，**按内容组整组写**：三个字段连同它们共用的那一枚戳。
    /// **不碰** `sortOrder` / `targetUpdatedDate` / `deletedDate` / `pendingLocalEdit`。
    case setContentGroup(syncId: String, host: String, pathPrefix: String?,
                         ask: Bool, contentUpdatedDate: Date)

    /// 这条 op 指向的账户级身份（`.rekey` 是它要写上去的**新**身份）。
    var syncId: String {
        switch self {
        case .create(let values), .update(let values), .move(let values):
            return values.syncId
        case .reorder(let syncId, _, _), .delete(let syncId):
            return syncId
        case .rekey(_, let to, _):
            return to
        case .softDelete(let syncId, _), .setMergePartner(let syncId, _):
            return syncId
        case .setContentGroup(let syncId, _, _, _, _):
            return syncId
        }
    }
}

// MARK: - 落地段尾部（R-M3-4a-56 / 计划裁定三）

/// R-M3-4a-56 的落地段尾部。**在这一页的全部落地写之后、稠密 `sortOrder` 重排之前**，
/// 在**同一个事务**里对含软删行的**当前**行投影求值一次，交回要补写的 M2 ops 与它们碰过
/// 的桶。纯计算：真的找到重复时才产出 ops（§8.4.3 开头）。
/// 那份**当前**投影同时是 **R-M3-4a-100** 的剔除依据：候选集在这里做第二次减法
/// （`pendingLocalEdit` / 已软删 / 行已不在，计划裁定六 (3)），**零额外读**。
///
/// **闭包刻意不带全局 actor**：它在写队列上被调，在 `@MainActor` 的落地闭包里直接形成会被
/// 推断成 `@MainActor` 闭包。装配点因此是一个**非隔离**的工厂函数，捕获的全是值类型。
struct URLRuleMergeTail {
    var evaluate: ([PhiLocalURLRule]) -> URLRuleMergeResult
}

/// 一次批次落地的可观测结局。**`collapsed` 只统计真的被软删的败者**（R-M3-4a-54）。
struct URLRuleBatchOutcome: Sendable, Equatable {
    var collapsed = 0
    /// §6.6 第 8 行的触发条件：M2 真的写了**软删或内容组**。**指针写不算**
    /// （`mergePartnerSyncId` 不进路由表，为它刷一次是白刷，CASE M-7 钉住零刷新）。
    var mergeChangedRouting = false
    /// **R-M3-4a-102**（8b-3 的计划裁定 11）：§8.4.4 (α) 的那一对 op（`.transfer` + 同身份的
    /// `.delete`）在事务里重读来源行、发现它与 op 带的 `source` **已经不同**（或行已不在 /
    /// 已软删）⇒ **两条 op 都不执行**，身份进这个集合。
    /// 本任务只**声明并原样回传**（M2 自己从不填它，落地 op 的执行器填）；引擎按
    /// `plan.parkedTombstones` 记账（游标 `pendingTombstone = true`、行不动），**绝不**进
    /// `outcome.landed` / `outcome.deleted`。书签与 pin 恒空集。
    var deferredTombstones: Set<String> = []
}

/// 一页远端落地要施加的**全部**规则操作，已按 §5.5 合并与排序。
///
/// **是操作列表，不是单个枚举**：`apply(_:)` 一次要落一整页的多条行，而 §5.5 的落地契约
/// 要求它们在**一个**事务里（部分成功不存在）。
struct URLRuleApplyBatch {
    private(set) var ops: [URLRuleSyncOp]
    /// R-M3-4a-56 的落地段尾钩（8b-2）。`nil` = 这一页不跑 M2（书签 / pin 的路径与 Task 8
    /// 的既有调用点都不传它）。
    private(set) var mergeTail: URLRuleMergeTail?
    /// R-M3-4a-98：`.transfer` 的目标侧戳从这里取，落地闭包在拼批次**之前**用
    /// `URLRuleKind.effectiveAccountStamps(landed:rebaselined:table:identities:)` 算好整张表。
    /// 本任务只**供给**它（消费者是 8b-3 的转移 op 执行器）。
    private(set) var accountStamps: [String: URLRuleEffectiveStamps]

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
    init(unordered: [URLRuleSyncOp], currentSpaceIds: [String: String] = [:],
         mergeTail: URLRuleMergeTail? = nil,
         accountStamps: [String: URLRuleEffectiveStamps] = [:]) {
        self.mergeTail = mergeTail
        self.accountStamps = accountStamps
        // 一身份一槽，按首次出现的次序；同类 op 重复出现时后到的覆盖先到的（两条带的是同一份
        // 合并结果，择哪条都一样）。
        struct Slot {
            var create: URLRuleLandingValues?
            var update: URLRuleLandingValues?
            var move: URLRuleLandingValues?
            var reorder: (spaceId: String, sortOrder: Int)?
            var delete = false
            /// §8.4.2 M1：这条身份要写到哪条本机行上（按 `localId` 寻址）。
            var rekey: (localId: String, values: URLRuleLandingValues?)?
        }
        var order: [String] = []
        var slots: [String: Slot] = [:]
        // ③ **一条本机行一页只认领一次**（RR3-4 / CASE M-13）：plan 那一侧按 1:1 配对，两条
        //    `.rekey` 指向同一条行在结构上不该出现；真出现时留第一条、丢后到的（后到的那条
        //    身份落地后复核不过 ⇒ 停放，下一轮按普通 create 落地），绝不让第二次 re-key 把
        //    第一个身份从那一行上挤掉——挤掉的那条身份本机再无活行认领，下一轮差分为它发
        //    一条 tombstone。
        var rekeyedLocalIds: Set<String> = []
        // 8b-2 的三条 M2 op **不进槽**：它们不是「落地一条远端实体」，没有可合并的同身份
        // 兄弟，也不参与 `.move` 的降级。按传入次序原样穿过，相序排在 `.delete` **之前**
        // （§8.4.3 的 (b) 软删要看得见一条本页稍后才被硬删的行）。
        var passthrough: [URLRuleSyncOp] = []
        for op in unordered {
            switch op {
            case .softDelete, .setMergePartner, .setContentGroup:
                passthrough.append(op)
                continue
            case .create, .update, .move, .reorder, .delete, .rekey:
                break
            }
            let syncId = op.syncId
            if case .rekey(let localId, _, _) = op {
                guard rekeyedLocalIds.insert(localId).inserted else {
                    assertionFailure("url rule batch: local row claimed twice in one page")
                    continue
                }
            }
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
            case .rekey(let localId, _, let values): slots[syncId]?.rekey = (localId, values)
            case .softDelete, .setMergePartner, .setContentGroup: continue   // 上面已经穿过
            }
        }

        var upgrades: [URLRuleSyncOp] = []
        var deletes: [URLRuleSyncOp] = []
        for syncId in order {
            guard let slot = slots[syncId] else { continue }
            var merged: URLRuleSyncOp?
            if let rekey = slot.rekey {
                // §8.4.2 M1 / R-M3-4a-42(b)：认领与字段合并结果**同一条 op**——同一身份另有的
                // `.update`（`adoptedFieldWrites` 那条）折进 `values`。签名含目标，所以一次认领
                // 不会同时是一次 rehome；`.move` / `.create` 在这里只是防御性的兜底取值。
                merged = .rekey(localId: rekey.localId, to: syncId,
                                values: rekey.values ?? slot.update ?? slot.move ?? slot.create)
            } else if let move = slot.move {
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
        ops = upgrades + passthrough + deletes
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
/// `notePersistedClaims` / `noteDeletedRows`（本文件已交）；8b-3 `partnerNotAtRest(table:rows:resolve:tombstonesThisPage:)`；
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
    ///
    /// 返回值是 8b-2 的落地段尾钩（M2）在**同一个事务**里的结局：`collapsed` 与
    /// `mergeChangedRouting`（§6.6 第 8 行的触发条件）。**`ops` 为空、只带尾钩的批次照样
    /// 落一次事务**（R-M3-4a-56：一页没有任何规则落地时同样要收敛）。
    /// `@discardableResult` 只为让 Task 8 那几条「只看 `rows` 变没变」的值级 fixture 用例
    /// 保持原样；引擎那一侧**永远**读它（`landURLRules` 把两个字段接进 `OwnedLandingOutcome`）。
    @discardableResult
    func apply(_ batch: URLRuleApplyBatch) async throws -> URLRuleBatchOutcome

    /// §6.6 / R-M3-4a-34：一页规则落地**提交之后**刷新 Chromium 那张路由表，**一页一次**。
    /// 生产实现是一句 `SpaceManager.shared.reloadURLRulesFromStore()`（重读 + 换缓存 +
    /// `pushRoutingTableToChromium()`）。放在 access 上而不是让引擎直调 `SpaceManager`，
    /// 与 `PhiSpaceLocalAccess`（`applyRemoteHidden` / `closeSpaceWindows` / `clearThemeRecords`）
    /// 落地副作用的形状逐字相同（Task 6 计划裁定一）。
    func refreshRoutingTableAfterLanding()

    /// §5.7 第一条出路：那条身份的 tombstone 已被服务端接受 ⇒ 把本机那条软删行硬删。
    /// 行已经不在（并发清扫刚删过）**不是错误**，无事可做即可。
    func hardDeleteURLRule(syncId: String) async throws
    /// §5.7 第二条出路：把 `deletedDate < cutoff` 的软删行硬删掉，返回条数。
    /// **判据是 `deletedDate`，与游标无关。**
    func purgeSoftDeletedURLRules(olderThan cutoff: Date) async throws -> Int

    // MARK: D30（8b-1）

    /// §8.4.1 的签名索引，**每页建一次**：来源是**本页那一次**
    /// `allURLRulesIncludingDeleted()` 的结果**减去软删行**（软删行不参与认领、也不是收敛的
    /// 组成员）。**「本页那一次」是硬的**（R-M3-4a-62 / RR4-3）。
    /// 一个签名可以对应多条行（正是收敛要处理的情形），所以值是数组；组内**按
    /// `(syncId ?? "", id)` 升序**排好，§8.4.2 的 1:1 配对直接取第一条。
    /// 选「一次建索引」而不是逐条查：这个协议是 `@MainActor` 的，逐条查就是每条实体一次
    /// 主 actor 跃迁；索引是那一次整库读的内存分组，**零额外 fetch**。
    func signatureIndex(resolve: OwnerResolver) -> [RuleSignature: [PhiLocalURLRule]]

    /// R-M3-4a-73 的具名输入之一：满足 **(α) 前三个合取项**（行在、`deletedDate == nil`、
    /// **有签名**）**且** `row.pendingLocalEdit == true` 的身份。填进
    /// `OwnedItemPlanContext.pendingLocalEdits`（那个成员是 **8b-3** 加的）。
    func pendingLocalEditIdentities(resolve: OwnerResolver) -> Set<String>

    /// 同上，取值式是 `server != nil && reconciled != nil && server != reconciled`
    /// （与发布段的 `pending` 集合 `PhiSyncEngine.publishOwnedKind` **同源**）。
    func unpublishedIdentities(table: PhiOwnedItemTable, resolve: OwnerResolver) -> Set<String>

    /// 身份 -> 伙伴 W 的身份，按 §8.4.4 的**三步查找次序**算好：① 读行上的
    /// `mergePartnerSyncId`，指到的行**静止**就是 W；② 取不到、或取到的行**存在但不静止**
    /// ⇒ 退到兜底支「当前签名 == `baselineSignature(X)`」的**静止活行**（多条时取 `syncId`
    /// 字典序最小的那条）；③ 都拿不出 ⇒ 不进本表。**W 必须静止**（§8.4.1 的十个合取项，
    /// 含第 10 项，R-M3-4a-86——所以本页的 tombstone 集合是入参，谓词没有别的来源可读它），
    /// **W 绝不等于 X 自己**（RR7-13）。
    /// **定义域不受 (α) 前三个合取项限制**（RR8-1）：(β) 落点上的 X 按定义是**软删态**的，
    /// 照抄 `deletedDate == nil` 会让这张表对 (β) 恒空。
    /// **读它的只有 8b-3 的 (α) / (β) 两支**；8b-1 把它实现完整并钉住判据，不接线。
    func mergePartners(table: PhiOwnedItemTable, resolve: OwnerResolver,
                       tombstonesThisPage: Set<String>) -> [String: String]

    /// R-M3-4a-62 的第一个就地更新口：认领把账户身份写进本机行之后**立刻**折回轮内投影。
    /// 参数方向是**本机行 id -> 新 `syncId`**（**与书签那一侧相反**：
    /// `BookmarkSyncRoundState.notePersistedClaims` 收的是身份 -> guid，§5.6 给规则写死的是
    /// 这个方向，spec 是约束方）。不折回去，同一页的落地段看到的还是「这一行没有（这个）身份」，
    /// 于是它可能把第二个身份配给同一条行。
    func notePersistedClaims(_ claimed: [String: String])

    /// R-M3-4a-62 的第二个口：本页**真的被删掉**的那些行立刻退出投影，形状照
    /// `BookmarkSyncRoundState.noteDeletedRows`。**让位的身份绝不进这里**（R-M3-4a-61）。
    func noteDeletedRows(_ syncIds: Set<String>)

    // **没有、也不许有 `clearAllSyncIds`**（§4.4 末段 / R-M3-4a-23）：规则的 `syncId` 在插入点
    // 铸造，自撤销时清掉它，重新加入后账户上那些旧身份没有任何设备认领 ⇒ 孤儿实体。缺席本身
    // 就是那道防线——协调器的 `clearAllSyncIds` 闭包只扩到书签。
}

// MARK: - D30 的四个只读查询（生产实现与假件共用同一份逻辑）

/// `signatureIndex` / `pendingLocalEditIdentities` / `unpublishedIdentities` / `mergePartners`
/// 的**纯函数**半边：入参是本页那一次读的**全部**行（含软删行），每个函数按自己的定义域
/// 过滤。生产实现喂 `cachedRows`、假件喂 `rows`，判据只有这一份——两处各写一份的实现迟早
/// 在「谁算静止」上分叉，而那正是 §8.4.1 要求「三处读同一个谓词」的原因。
enum URLRuleSignatureQueries {
    /// §8.4.1 的归一化函数（三处调用点之一，与 `normalizeArrivals` 同款注入）。
    static let normalize: (String, String?) -> (host: String, pathPrefix: String?) = {
        LocalStore.normalizedRule(host: $0, pathPrefix: $1)
    }

    static func signatureIndex(rows: [PhiLocalURLRule],
                               resolve: OwnerResolver) -> [RuleSignature: [PhiLocalURLRule]] {
        var out: [RuleSignature: [PhiLocalURLRule]] = [:]
        for row in rows where row.deletedDate == nil {
            guard let signature = URLRuleKind.signature(of: row, resolve: resolve,
                                                        normalize: normalize) else { continue }
            out[signature, default: []].append(row)
        }
        for key in out.keys {
            out[key]?.sort { ($0.syncId ?? "", $0.id) < ($1.syncId ?? "", $1.id) }
        }
        return out
    }

    static func pendingLocalEditIdentities(rows: [PhiLocalURLRule],
                                           resolve: OwnerResolver) -> Set<String> {
        var out: Set<String> = []
        for row in rows where row.deletedDate == nil && row.pendingLocalEdit {
            guard let syncId = row.syncId,
                  URLRuleKind.signature(of: row, resolve: resolve, normalize: normalize) != nil
            else { continue }
            out.insert(syncId)
        }
        return out
    }

    static func unpublishedIdentities(rows: [PhiLocalURLRule], table: PhiOwnedItemTable,
                                      resolve: OwnerResolver) -> Set<String> {
        var out: Set<String> = []
        for row in rows where row.deletedDate == nil {
            guard let syncId = row.syncId, let cursor = table.cursors[syncId],
                  let server = cursor.server, let reconciled = cursor.reconciled,
                  server != reconciled,
                  URLRuleKind.signature(of: row, resolve: resolve, normalize: normalize) != nil
            else { continue }
            out.insert(syncId)
        }
        return out
    }

    static func mergePartners(rows: [PhiLocalURLRule], table: PhiOwnedItemTable,
                              resolve: OwnerResolver,
                              tombstonesThisPage: Set<String>) -> [String: String] {
        func atRest(_ row: PhiLocalURLRule) -> Bool {
            URLRuleKind.isAtRest(row: row, cursor: row.syncId.flatMap { table.cursors[$0] },
                                 resolve: resolve, normalize: normalize,
                                 tombstonesThisPage: tombstonesThisPage)
        }
        // 候选 W 的定义域：静止的活行，按当前签名分组、组内按 `syncId` 升序（兜底支取最小）。
        var restingBySyncId: [String: PhiLocalURLRule] = [:]
        var restingBySignature: [RuleSignature: [PhiLocalURLRule]] = [:]
        for row in rows where row.deletedDate == nil {
            guard let syncId = row.syncId, atRest(row),
                  let signature = URLRuleKind.signature(of: row, resolve: resolve,
                                                        normalize: normalize) else { continue }
            restingBySyncId[syncId] = row
            restingBySignature[signature, default: []].append(row)
        }
        for key in restingBySignature.keys {
            restingBySignature[key]?.sort { ($0.syncId ?? "") < ($1.syncId ?? "") }
        }
        var out: [String: String] = [:]
        // X 的定义域**含软删行**（RR8-1）。
        for x in rows {
            guard let xId = x.syncId else { continue }
            // ① 行上的 `mergePartnerSyncId`：指到的行必须存在**且静止**，且不是 X 自己。
            if let pointer = x.mergePartnerSyncId, pointer != xId, restingBySyncId[pointer] != nil {
                out[xId] = pointer
                continue
            }
            // ② 兜底：当前签名 == `baselineSignature(X)` 的静止活行，取 `syncId` 最小的那条。
            guard let baseline = URLRuleKind.baselineSignature(identity: xId, table: table,
                                                               resolve: resolve, normalize: normalize),
                  let partner = restingBySignature[baseline]?.first(where: { $0.syncId != xId }),
                  let partnerId = partner.syncId else { continue }
            out[xId] = partnerId
            // ③ 两条都拿不出 ⇒ 不进本表（上面的 `guard` 就是那条出口）。
        }
        return out
    }
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
    @discardableResult
    func apply(_ batch: URLRuleApplyBatch) async throws -> URLRuleBatchOutcome {
        let outcome = try await store.applyURLRuleSyncBatchThrowing(batch.ops,
                                                                    mergeTail: batch.mergeTail)
        try rebuildCache()
        return outcome
    }

    /// 靠 `urlRulesPublisher` 自己发射是不够的：它按 SwiftData 就地刷新的同一批实例去重，一次
    /// 只改 host 的落地会被吞掉（`LocalStore+SpaceURLRule.swift` 的 `removeDuplicates`）。
    /// 一页一次、只在 `apply` 成功返回之后（引擎那一侧保证）。
    func refreshRoutingTableAfterLanding() {
        SpaceManager.shared.reloadURLRulesFromStore()
    }

    // MARK: - §5.7 软删行的两条出路

    /// 直接转 Task 5 的 `hardDeleteURLRuleThrowing(syncId:)`：找不到行是无事可做，不是错误。
    /// **不动本页缓存**：出路 1 跑在发布段末尾，本页落地早已结束，下一页 / 下一轮的
    /// `allURLRules()` 自己重建。
    func hardDeleteURLRule(syncId: String) async throws {
        try await store.hardDeleteURLRuleThrowing(syncId: syncId)
    }

    /// 用已有的两件东西组合：一次 `allURLRulesIncludingDeleted()` 筛出 `deletedDate < cutoff`
    /// 且有身份的软删行，逐条 `hardDeleteURLRuleThrowing(syncId:)`。**逐条一个事务是特性**：
    /// 中途崩掉剩下的那些下一次清理轮重算，判据没有任何一次性状态。`syncId == nil` 的软删行
    /// 按 R-M3-4a-23 不可达（插入点铸造）。判据是**行上的** `deletedDate`，与游标无关。
    ///
    /// **一行失败不中断**：剩下的照删、成功的照数，末尾按 R12 记一条（kind + 失败条数），返回
    /// 成功条数。失败的那几行没有任何一次性状态，下一次清理轮重算。只有那一次读抛出去。
    func purgeSoftDeletedURLRules(olderThan cutoff: Date) async throws -> Int {
        let expired = try allURLRulesIncludingDeleted().compactMap { row -> String? in
            guard let deletedDate = row.deletedDate, deletedDate < cutoff else { return nil }
            return row.syncId
        }
        var purged = 0
        var failed = 0
        for syncId in expired {
            do {
                try await store.hardDeleteURLRuleThrowing(syncId: syncId)
                purged += 1
            } catch {
                failed += 1
            }
        }
        if failed > 0 {
            AppLogWarn("[phi-sync] soft-deleted rule sweep: some rows could not be hard-deleted "
                       + "kind=urlrules failed=\(failed)")
        }
        return purged
    }

    // MARK: - D30（8b-1）：四个只读查询 + 两个就地更新口

    /// 全部读**本页缓存**（Task 8 的 `cachedRows` / `cachedLive`），零额外 fetch。快照没读到
    /// 时照 `requireLoadedSnapshot()` 的形状交回空值并在 DEBUG 下断言。
    func signatureIndex(resolve: OwnerResolver) -> [RuleSignature: [PhiLocalURLRule]] {
        guard requireLoadedSnapshot() else { return [:] }
        return URLRuleSignatureQueries.signatureIndex(rows: cachedLive, resolve: resolve)
    }

    func pendingLocalEditIdentities(resolve: OwnerResolver) -> Set<String> {
        guard requireLoadedSnapshot() else { return [] }
        return URLRuleSignatureQueries.pendingLocalEditIdentities(rows: cachedLive, resolve: resolve)
    }

    func unpublishedIdentities(table: PhiOwnedItemTable, resolve: OwnerResolver) -> Set<String> {
        guard requireLoadedSnapshot() else { return [] }
        return URLRuleSignatureQueries.unpublishedIdentities(rows: cachedLive, table: table,
                                                             resolve: resolve)
    }

    func mergePartners(table: PhiOwnedItemTable, resolve: OwnerResolver,
                       tombstonesThisPage: Set<String>) -> [String: String] {
        guard requireLoadedSnapshot() else { return [:] }
        return URLRuleSignatureQueries.mergePartners(rows: cachedRows, table: table, resolve: resolve,
                                                     tombstonesThisPage: tombstonesThisPage)
    }

    /// 按本机行 `id` 定位、改两份缓存里那一条的 `syncId`（键方向：**本机行 id -> 新 syncId**）。
    /// `apply(_:)` 成功返回时缓存已经重建过一次，这里通常是一次幂等的补写；它存在是为了
    /// R-M3-4a-62 的契约在类型上可见，而不依赖「apply 顺手重读过」这个实现细节。
    func notePersistedClaims(_ claimed: [String: String]) {
        guard requireLoadedSnapshot(), !claimed.isEmpty else { return }
        for index in cachedRows.indices {
            guard let syncId = claimed[cachedRows[index].id] else { continue }
            cachedRows[index].syncId = syncId
        }
        reindexLive()
    }

    /// 按 `syncId` 把本页真的被删掉的行从两份缓存里移除。**让位的身份绝不进这里**（R-M3-4a-61）。
    func noteDeletedRows(_ syncIds: Set<String>) {
        guard requireLoadedSnapshot(), !syncIds.isEmpty else { return }
        cachedRows.removeAll { row in
            guard let syncId = row.syncId else { return false }
            return syncIds.contains(syncId)
        }
        reindexLive()
    }

    // MARK: - 私有

    /// 从 `cachedRows` 重算另三份派生缓存（两个就地更新口改完 `cachedRows` 之后调）。
    private func reindexLive() {
        let live = cachedRows.filter { $0.deletedDate == nil }
        var siblings: [String: [PhiLocalURLRule]] = [:]
        var liveSyncIds: Set<String> = []
        for row in live {
            siblings[row.spaceId, default: []].append(row)
            if let syncId = row.syncId {
                liveSyncIds.insert(syncId)
            }
        }
        cachedLive = live
        cachedSiblings = siblings
        cachedLiveSyncIds = liveSyncIds
    }

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

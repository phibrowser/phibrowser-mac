// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import SwiftProtobuf

// 「归属项」（书签 / pin）的 snapshot / 差分 / plan / 认领，外加 §4.3 的位置合并。
//
// **整个文件是纯函数**，与 `SyncableSpaces.swift:19-22` 的自述逐字同款：引擎拥有全部
// 持久化，`snapshot` 一个字节都不写。这里没有 actor hop、没有 `LocalStore`、没有
// `UserDefaults`，所以它能在一个没有 SwiftData 的测试进程里整体跑起来。
//
// rank 的四个原语（`rankAlphabet` / `rankBetween` / `longestIncreasingKeptSet` /
// `assignRanks` / `isLegalRank`）**不在这里重写**：它们住在 `SyncableSpaces` 上，本文件
// 是第二个调用方（R4 单一实现）。两份实现迟早会漂，而它们决定的是账户级次序。

/// 身份翻译与归属合格性，由引擎在**轮首**算好一次传进来——纯函数模块不该自己去够
/// `PhiSpaceSyncTable` 或者映射表。
struct OwnerResolver {
    /// 本地 spaceId -> 账户级 syncUuid。
    var syncUuid: (String) -> String?
    /// syncUuid -> 本地 spaceId。
    var localSpaceId: (String) -> String?
    /// §4.2 规则 1 那三条判据的合取：在 `currentSpaces()` 里 ∧ 有 syncUuid ∧ Space 游标
    /// 既不 `hidden` 也没有 `purgedAtMs`。
    ///
    /// **只对 Space 归属有意义**：本模块只在 `localSpaceId(uuid) != nil` 时问它，所以一个
    /// profile / app 作用域的 pin 归属不会被它一刀切掉。
    var isEligibleSpace: (String) -> Bool
    /// 本地 profileId -> 账户级 profile uuid。
    var globalUuid: (String) -> String?
    /// profile uuid -> 本地 profileId。
    var localProfileId: (String) -> String?
}

/// 协议层三元组 + 载荷。`plan` 收它而不是裸载荷，因为 §5.6 L1 的「收割」要拿到服务端赋的
/// `entityId` 与 `version`，而那两个字段住在 `PhiRemoteEntity` 上、**不在**加密载荷里。
struct OwnedItemArrival<Entity> {
    var entity: Entity
    var entityId: String
    var version: Int64
}

/// `plan` 的第六个参数：一次调用要带的全部轮内上下文。散成多个实参会让签名随着每一条新
/// 规则而变。
struct OwnedItemPlanContext {
    /// `adopt` 的配对表：实体身份 -> 本机 guid。
    var pairs: [String: String] = [:]
    /// 本轮同时到达的 tombstone 身份集合（提升只在父被**证实死亡**时发生）。
    var tombstonedIdentities: Set<String> = []
    /// 本轮因一条远端文件夹 tombstone 而要消失的身份（A9 的第三个合取项）。
    var deletedSubtree: Set<String> = []
    /// 解析得到一条**活的**本地行的父身份（A9 的第二个合取项）。
    var liveLocalParents: Set<String> = []
    /// 本机当前作用域与账户作用域（书签两者都传 nil）。两者都非 nil 且**不相等**时，
    /// §7.3 的作用域不一致成立：`plan` 产出零 step、把入站实体**全部**塞进 `parked`。
    var localScope: PinnedTabScope? = nil
    var accountScope: PinnedTabScope? = nil
    var scopeMismatch: Bool {
        guard let localScope, let accountScope else { return false }
        return localScope != accountScope
    }
}

/// 一个落地步骤属于 §4.4 三相里的哪一相，由这个枚举决定——它同时是排序键：
/// `.claim` / `.create` / `.move` 是第一相，`.update` 第二相，`.delete` 第三相。
enum StepKind: Equatable {
    case claim        // 认领：把账户身份写到一条已存在的本机行上（§6.3 第 ① 步）
    case create
    case move         // 改父 / 改 Space / 改位置
    case update       // 只改内容字段
    case delete
}

struct OwnedItemApplyStep: Equatable {
    var identity: String
    var kind: StepKind
    /// **模块判定的**落地父，`""` = Space 根。
    ///
    /// nil = 「照载荷自己的父落地」——一条根级书签的 create、以及每一条 pin（pin 没有父）
    /// 都是 nil。非 nil 只发生在模块真的**决定**了一个父的时候：提升到根（`""`，§4.4
    /// 第 5 步）与挂到本轮一起落地的那个父之下。
    var newParentUuid: String?
    var newRank: String?
    /// 落地后要写进 `reconciled` 的字节（`Phi_PhiEntity` 信封的序列化形式）。
    var payload: Data?
}

/// 一条停放项。**它带着归属 uuid**：§4.4 第 4 步要求停放的同时记下「我在等哪一个归属
/// 落地」，引擎把它写进游标的 `pendingOwnerUuid`，下一轮据此判断这条停放项是否可以重试。
struct ParkedOwnedItem: Equatable {
    var payload: Data
    var pendingOwnerUuid: String?
}

struct OwnedItemPlan {
    var steps: [OwnedItemApplyStep]    // 已按 §4.4 三相排序
    var parked: [String: ParkedOwnedItem]
    var refused: Int
    var lifted: Int
    var supersededByDelete: Int
    var cancelledDeletes: Set<String>
    /// 身份 -> 本轮从协议层收割到的 `(entityId, version)`，即使那条实体被丢弃。
    var harvest: [String: (entityId: String, version: Int64)]
}

/// §4.6 的结构性拒收判据。**没有 `refusedAtMs`**：这些判据全是结构性的，对端修好就该被
/// 接受，所以每轮重判一次（Space 侧那个「记住我拒过」的优化已经变成一条无法自愈的永久
/// 排除）。
enum OwnedItemRefusal: Equatable {
    case illegalRank, cycle, isFolderMismatch, selfReference, invalidUuid, invalidURL
}

struct OwnedItemSnapshotResult<Entity> {
    /// **每一条合格的本机行都在这里**，不只是「有变化的那些」。变化检测是**调用方**的事：
    /// 引擎拿 `entities[身份]` 与游标的 `reconciled` 比序列化字节，不等才进发布切片。
    var entities: [String: Entity]
    /// 归属未映射（`syncUuid(forSpaceId:)` 返回 nil）而跳过的条数。
    var skippedUnmappedOwner: Int
    /// 归属映射得到、但 `isEligibleSpace` 判为不合格（hidden / purged）而跳过的条数。
    /// **两者都计进 `excluded_unmapped_owner` 这一个计数**：spec §11.2 对它的定义覆盖
    /// 「归属解析不出来」与「归属不合格」两种，日志行上只有一个字段。分两个成员是为了让
    /// 两条排除路径各自可断言。
    var skippedIneligibleOwner: Int
}

/// `tombstones(...)` 的返回：**不只是身份列表**。§4.7 要求产出一条差分 tombstone 的同时
/// 把那条游标推进到「待删」状态——清 `pendingApply`、置 `pendingDelete` 与
/// `deleteDecidedAtMs`、收割 `entityId` / `version`。纯函数拿的是 `table` 的**值拷贝**，
/// 改不到调用方那一份，所以它必须把要改的东西**返回出来**，由引擎写回。
struct OwnedItemTombstoneResult {
    /// 本轮要发 tombstone 的身份，已按 §5.3 的反拓扑序排好（子先于父）。
    var identities: [String]
    /// 身份 -> 该游标要被写成什么样（调用方 apply 到自己那份表上）。
    var cursorUpdates: [String: PhiOwnedItemCursor]
}

struct OwnedItemAdoptionResult {
    var pairs: [String: String]        // 实体身份 -> 本机 guid
    var adopted: Int
    var unmatchedFolders: Int
}

#if DEBUG
/// 测试专用探针：数**本模块自己**打进 `rankBetween` 的次数（CASE 4a.8）。
///
/// `SyncableSpaces.assignRanks` 内部那些调用不计——它是 `SyncableSpaces` 自己的算法，本
/// 里程碑一个字都没动它。这个探针守的是另一件事：**入站路径**（`plan`）绝不能把对端字节
/// 里的 rank 递给一个会 `precondition` 的函数。
enum RankProbe {
    nonisolated(unsafe) private(set) static var rankBetweenCalls = 0
    static func reset() { rankBetweenCalls = 0 }
    static func note() { rankBetweenCalls += 1 }
}
#endif

/// 一种「归属项」kind 的薄适配：编解码、字段 LWW 表、归属解析、盖戳。模块本身只认这个
/// 协议，不认书签也不认 pin。
///
/// **相对 spec §4.1 那份声明的增补，逐条写明理由**（都是「模块是泛型的，而这件事只有
/// 适配层知道」这一个形状）：
/// - `localEdge(of:)`：`snapshot` 要把子行的 `parent_uuid` 填成**父行的账户身份**，而候选
///   身份只活在内存里（§4.2 第 2 条），所以这张 `本地 id -> 身份` 表只能在模块里、从
///   `locals` 自己算出来；模块不认识 `PhiLocalBookmark`，由适配层把这一对拿出来。
/// - `rank(of:)`：rank 通道要读基线里的 rank 再喂给 `assignRanks`，泛型 `Entity` 上没有
///   这个字段。
/// - `locationStamp(of:)`：§4.3 的载体戳，A9 的第一个合取项也要它。spec 把它列在
///   `BookmarkKind` 上，这里把它提进协议，签名一字不改。
/// - `stamp(...)`：§4.2 第 4/5 条的盖戳规则按**字段分组**（location / rank / 内容），分组
///   本身只有适配层知道。`project` 保持「不盖戳」的纯投影。
protocol OwnedItemKind {
    /// 线上实体类型（`Phi_PhiBookmarkEntity` / `Phi_PhiPinTabEntity`）。
    associatedtype Entity: SwiftProtobuf.Message & Equatable
    /// 本机行的值快照（`PhiLocalBookmark` / `PhiLocalPin`）。
    associatedtype Local

    static var tagPrefix: String { get }        // "phi-bookmark:" / "phi-pin:"
    static var entityName: String { get }       // 服务端明文常量

    static func identity(of entity: Entity) -> String
    /// 本机行的账户身份。书签是 `syncId`（nil = 这一行还没铸过身份，本轮不发布）。
    static func identity(of local: Local, resolve: OwnerResolver, scope: PinnedTabScope?) -> String?

    static func envelope(_ entity: Entity) -> Phi_PhiEntity
    static func entity(from envelope: Phi_PhiEntity) -> Entity?

    /// 本机行 → 线上实体，**不盖时间戳也不填 rank**。归属解析不出 ⇒ nil，该行本轮整条
    /// 跳过（§4.2 第 1 条）。`parentIdentity` 是父行的账户身份，nil = 直接挂在 Space 根下。
    static func project(_ local: Local, resolve: OwnerResolver, scope: PinnedTabScope?,
                        parentIdentity: String?) -> Entity?
    /// 字段级 LWW 合并。**必须从 `remote` 起手**（保留未知字段，`Proto/README.md`）。
    static func merge(local: Entity, remote: Entity) -> Entity
    /// 内容拒收（结构非法的载荷），nil = 接受。
    static func refuses(_ entity: Entity) -> OwnedItemRefusal?
    /// 这条实体落地**之前必须已经解析出来**的归属引用。
    ///
    /// **复数**（spec §4.1）：一条实体可以有不止一个归属引用，§4.4 第 4 步要为其中任一个
    /// 记 `pendingOwnerUuid`，单个可选表达不了。书签返回的是**绑定**的那一个——子孙是
    /// `parent_uuid`，根级项是 `space_uuid`；子孙的 `space_uuid` 是诊断字段，接收端忽略
    /// （R-M3-3-18），把它也算成必须解析会让一次「移走文件夹再删掉旧 Space」把整棵子树
    /// **永久**停放在每一台新设备上。
    static func ownerUuids(of entity: Entity) -> [String]

    static func localEdge(of local: Local) -> (id: String, parentId: String?)
    static func rank(of entity: Entity) -> String
    static func locationStamp(of entity: Entity) -> Int64
    static func stamp(_ projected: Entity, baseline: Entity?, local: Local,
                      rank: String, now: Int64) -> Entity
}

/// 一条归属引用在本轮里的状态（`plan` 第 3 步）。文件作用域而不是函数内的局部类型：
/// 泛型函数里不允许嵌套类型。
private enum OwnerState {
    /// 本轮工作集里的另一条实体——一条依赖边。
    case item(String)
    /// 父被**证实死亡**：本轮的 tombstone，或游标上已经定案的 `deletedAtMs`。
    case lift
    /// 归属在模块之外解析得出（一个合格的 Space、一个映射得到的 profile、或一条活的
    /// 本地父行）。
    case external
    case unresolved
}

enum SyncableOwnedItems {

    // MARK: - rank 原语的转发

    /// 转发到 `SyncableSpaces.rankBetween`，**顺带过一次探针**。本模块的每一次 rank 生成
    /// 都走这里，于是 CASE 4a.8 能断言「入站路径一次都没碰过它」。
    static func rankBetween(_ a: String?, _ b: String?) -> String {
        #if DEBUG
        RankProbe.note()
        #endif
        return SyncableSpaces.rankBetween(a, b)
    }

    // MARK: - 出站：snapshot（§4.2）

    /// 每一条**合格**本机行的出站实体，按身份键。
    ///
    /// PURE：什么都不写。`locals` 是引擎交进来的那一份（未同步行的候选身份已经在内存里
    /// 填进了 `syncId`，§4.2 第 2 条），归属过滤**在这个函数里面做**——差分要看到被过滤掉
    /// 的那些行，所以调用方不许先把它们筛掉（§4.7）。
    static func snapshot<K: OwnedItemKind>(_ kind: K.Type, locals: [K.Local],
                                           table: PhiOwnedItemTable, resolve: OwnerResolver,
                                           scope: PinnedTabScope?, now: Int64)
        -> OwnedItemSnapshotResult<K.Entity> {
        var skippedUnmappedOwner = 0
        var skippedIneligibleOwner = 0

        // 本地 id -> 账户身份。子行的 `parent_uuid` 填的是**父行的身份**。
        var identityByLocalId: [String: String] = [:]
        for local in locals {
            guard let identity = K.identity(of: local, resolve: resolve, scope: scope) else { continue }
            identityByLocalId[K.localEdge(of: local).id] = identity
        }

        var candidates: [(identity: String, local: K.Local, entity: K.Entity, group: String)] = []
        for local in locals {
            guard let identity = K.identity(of: local, resolve: resolve, scope: scope) else { continue }
            // §4.2 第 3 条：停放中 / 待发 tombstone / 待发删除的游标一律不进快照。一个停放中
            // 的实体若被快照，每个字段会盖上 `now` 再按停放游标的 entityId/version 当 update
            // 提交，把账户上那条整体覆盖成本机的值。
            if let cursor = table.cursors[identity] {
                guard cursor.pendingApply == nil, !cursor.pendingTombstone,
                      !cursor.pendingDelete else { continue }
            }
            let parentIdentity = K.localEdge(of: local).parentId.flatMap { identityByLocalId[$0] }
            guard let entity = K.project(local, resolve: resolve, scope: scope,
                                         parentIdentity: parentIdentity) else {
                skippedUnmappedOwner += 1
                continue
            }
            let owners = K.ownerUuids(of: entity)
            // 归属映射得到、但那个 Space 已经 hidden / purged。
            if owners.contains(where: { resolve.localSpaceId($0) != nil && !resolve.isEligibleSpace($0) }) {
                skippedIneligibleOwner += 1
                continue
            }
            candidates.append((identity, local, entity, owners.joined(separator: "\u{0}")))
        }

        // 基线：变更检测与 rank 通道的共同输入。
        var baselines: [String: K.Entity] = [:]
        for candidate in candidates {
            guard let bytes = table.cursors[candidate.identity]?.reconciled,
                  let envelope = try? Phi_PhiEntity(serializedBytes: bytes),
                  let entity = K.entity(from: envelope) else { continue }
            baselines[candidate.identity] = entity
        }
        // rank 通道唯一的解码边界：基线是对端字节，只有本仓库自己产得出的 rank 才允许
        // 到达 `rankBetween`；其余降格成「没有 rank」，于是它落进 `assignRanks` 的补集
        // 并被派一个真的。
        func baselineRank(_ identity: String) -> String? {
            guard let rank = baselines[identity].map(K.rank(of:)),
                  SyncableSpaces.isLegalRank(rank) else { return nil }
            return rank
        }

        // 一个归属一组（书签是「同一个父」，pin 是同一个 owner）：rank 只在组内可比。
        var groupOrder: [String] = []
        var groups: [String: [Int]] = [:]
        for (offset, candidate) in candidates.enumerated() {
            if groups[candidate.group] == nil { groupOrder.append(candidate.group) }
            groups[candidate.group, default: []].append(offset)
        }
        var assigned: [String: String] = [:]
        for key in groupOrder {
            let members = groups[key] ?? []
            let order = members.map { (uuid: candidates[$0].identity,
                                       rank: baselineRank(candidates[$0].identity)) }
            for (identity, rank) in SyncableSpaces.assignRanks(order: order) {
                assigned[identity] = rank
            }
        }

        var entities: [String: K.Entity] = [:]
        for candidate in candidates {
            let rank = assigned[candidate.identity] ?? baselineRank(candidate.identity) ?? "V"
            entities[candidate.identity] = K.stamp(candidate.entity,
                                                   baseline: baselines[candidate.identity],
                                                   local: candidate.local, rank: rank, now: now)
        }
        return OwnedItemSnapshotResult(entities: entities,
                                       skippedUnmappedOwner: skippedUnmappedOwner,
                                       skippedIneligibleOwner: skippedIneligibleOwner)
    }

    // MARK: - 差分 tombstone（§4.7）

    /// 本地删除的**唯一**起源：`LocalStore` 没有书签 / pin 的删除钩子，publisher 发出的是
    /// 缺席，所以删除是一次快照差分。三条判据逐条对应一个会删掉账户数据的错法：
    ///
    /// - `reconciled != nil`（**不是 `entityId != nil`**）：停放会 harvest `entityId`，按它
    ///   判会给一条**仅仅是本机还没能放下去**的入站实体发 tombstone，把对端刚建的东西删掉。
    /// - `deletedAtMs == nil`：挡住「远端删除刚落地 ⇒ 本机行没了 ⇒ 又给它发一条自己的
    ///   tombstone」这个回声。
    /// - 本机确实没有这一行了。
    ///
    /// 两条排除（归属未映射 / 归属不合格）不是「本机没有这一行」：那些行**存在**，只是
    /// 不发布；把它们算成缺席会在一次映射抖动里删掉账户上一整个 Space 的书签。
    ///
    /// **`pendingApply != nil` 不是第四条判据**（A7）：对一条有基线的游标来说它的含义是
    /// 「这一行落地过，一个更新的远端版本正在等」，那是一次**删除对编辑**的冲突，本机的
    /// 删除赢——产出 tombstone 并在同一步清掉 `pendingApply`。
    static func tombstones<K: OwnedItemKind>(_ kind: K.Type, locals: [K.Local],
                                             table: PhiOwnedItemTable, resolve: OwnerResolver,
                                             scope: PinnedTabScope?,
                                             nowMs: Int64) -> OwnedItemTombstoneResult {
        var liveIdentities: Set<String> = []
        for local in locals {
            if let identity = K.identity(of: local, resolve: resolve, scope: scope) {
                liveIdentities.insert(identity)
            }
        }

        var identities: [String] = []
        var cursorUpdates: [String: PhiOwnedItemCursor] = [:]
        for (identity, cursor) in table.cursors {
            guard cursor.reconciled != nil else { continue }
            guard cursor.deletedAtMs == nil else { continue }
            guard !liveIdentities.contains(identity) else { continue }
            if let owner = cursor.ownerUuid {
                // 归属未映射。**pin 的 App 作用域 ownerKey 是字面量**，它不需要映射：
                // Task 4b 接入时由 `PinKind` 保证那条游标的 `ownerUuid` 不写字面量，或者
                // 由引擎的 resolver 把它映成自身。
                let mapped = resolve.localSpaceId(owner) != nil || resolve.localProfileId(owner) != nil
                guard mapped else { continue }
                // 归属不合格（hidden / purged）。
                guard resolve.localSpaceId(owner) == nil || resolve.isEligibleSpace(owner) else { continue }
            }
            identities.append(identity)
            // 已经在待发集合里的，游标一个字节都不改：重写 `deleteDecidedAtMs` 会把 A9 那条
            // 「入站位置比删除决定更新」的比较基准往后推，一次并发移动就再也取消不了删除。
            if cursor.pendingDelete, cursor.pendingApply == nil { continue }
            var updated = cursor
            updated.pendingApply = nil
            updated.pendingOwnerUuid = nil
            updated.pendingDelete = true
            updated.deleteDecidedAtMs = nowMs
            cursorUpdates[identity] = updated
        }

        // §5.3 的反拓扑序：子先于父。父子关系从基线里解出来——tombstone 没有载荷，这是
        // 唯一的来源。
        var parentOf: [String: String] = [:]
        for identity in identities {
            guard let bytes = table.cursors[identity]?.reconciled,
                  let envelope = try? Phi_PhiEntity(serializedBytes: bytes),
                  let entity = K.entity(from: envelope) else { continue }
            if let parent = K.ownerUuids(of: entity).first(where: { table.cursors[$0] != nil }) {
                parentOf[identity] = parent
            }
        }
        let depths = depth(of: identities, parentOf: parentOf)
        identities.sort {
            let left = depths[$0] ?? 0, right = depths[$1] ?? 0
            return left == right ? $0 < $1 : left > right
        }
        return OwnedItemTombstoneResult(identities: identities, cursorUpdates: cursorUpdates)
    }

    // MARK: - 入站：plan（§4.4）

    /// 本轮到达 + 停放集 → 一个**分三相有序**的落地计划。
    ///
    /// 书签的依赖是**同一个 data type 内的兄弟实体**，而且可以任意深，所以这里先做一次
    /// 拓扑排序：一页里乱序到达的一棵树**一轮**落完，而不是每层一轮。
    static func plan<K: OwnedItemKind>(_ kind: K.Type,
                                       arrivals: [OwnedItemArrival<K.Entity>],
                                       parked: [String: ParkedOwnedItem],
                                       table: PhiOwnedItemTable,
                                       resolve: OwnerResolver,
                                       context: OwnedItemPlanContext) -> OwnedItemPlan {
        // 收割先于一切：**无论那条实体后来被丢弃、拒收还是停放**，服务端赋的
        // `entityId` / `version` 都要留下（A6）。不收割的实现在真机上表现为一个每 60 s
        // 重来一次、删除永远落不了地的循环。
        var harvest: [String: (entityId: String, version: Int64)] = [:]
        for item in arrivals {
            let identity = K.identity(of: item.entity)
            guard !identity.isEmpty else { continue }
            let previous = harvest[identity]
            harvest[identity] = (entityId: item.entityId.isEmpty ? (previous?.entityId ?? "")
                                                                 : item.entityId,
                                 version: max(item.version, previous?.version ?? 0))
        }

        func payloadBytes(_ entity: K.Entity) -> Data? {
            try? K.envelope(entity).serializedData()
        }

        // §7.3：作用域不一致 ⇒ 零 step，入站实体**全部**停放，等作用域收敛。
        if context.scopeMismatch {
            var parkedOut = parked
            for item in arrivals {
                let identity = K.identity(of: item.entity)
                guard !identity.isEmpty, let payload = payloadBytes(item.entity) else { continue }
                parkedOut[identity] = ParkedOwnedItem(
                    payload: payload, pendingOwnerUuid: K.ownerUuids(of: item.entity).first)
            }
            return OwnedItemPlan(steps: [], parked: parkedOut, refused: 0, lifted: 0,
                                 supersededByDelete: 0, cancelledDeletes: [], harvest: harvest)
        }

        // 1. 工作集 = 停放项（按 uuid 字典序，设备无关）∪ 本轮到达，到达项覆盖同身份的
        //    停放项。解不开的停放项原样留在 `parked` 里。
        var working: [(identity: String, entity: K.Entity)] = []
        var slotOf: [String: Int] = [:]
        var parkedOut: [String: ParkedOwnedItem] = [:]
        for identity in parked.keys.sorted() {
            guard let item = parked[identity] else { continue }
            guard let envelope = try? Phi_PhiEntity(serializedBytes: item.payload),
                  let entity = K.entity(from: envelope) else {
                parkedOut[identity] = item
                continue
            }
            slotOf[identity] = working.count
            working.append((identity, entity))
        }
        for item in arrivals {
            let identity = K.identity(of: item.entity)
            guard !identity.isEmpty else { continue }
            if let slot = slotOf[identity] {
                working[slot] = (identity, item.entity)
            } else {
                slotOf[identity] = working.count
                working.append((identity, item.entity))
            }
        }

        // 2. 拒收与 tombstone 覆盖。孩子自己也带 tombstone 时**不提升**——那才是「这条也
        //    该消失」，所以它的活实体在这里就被它自己的 tombstone 盖掉。
        var refused = 0
        var survivors: [(identity: String, entity: K.Entity)] = []
        for item in working {
            if context.tombstonedIdentities.contains(item.identity) { continue }
            if K.refuses(item.entity) != nil { refused += 1; continue }
            survivors.append(item)
        }
        let survivorIdentities = Set(survivors.map(\.identity))

        // 3. 归属分类。**「父只是不在」绝不触发提升**：父缺席的原因里有好几个与删除无关
        //    且都可达（解密失败、被拒收、自己也停放着、被页预算切在后面），按「不在即提升」
        //    写，一份坏密文就能把一整棵子树在整个账户上拍平，而且再也回不去。
        func classify(_ uuid: String) -> OwnerState {
            if survivorIdentities.contains(uuid) { return .item(uuid) }
            if context.tombstonedIdentities.contains(uuid)
                || table.cursors[uuid]?.deletedAtMs != nil { return .lift }
            if context.liveLocalParents.contains(uuid) { return .external }
            if resolve.localSpaceId(uuid) != nil { return resolve.isEligibleSpace(uuid) ? .external : .unresolved }
            if resolve.localProfileId(uuid) != nil { return .external }
            return .unresolved
        }

        // 4. 拓扑排序（Kahn）。排不完的剩余节点即处在环里——对端 bug 或伪造载荷，一律
        //    refuse：停放会让它永远等一个等不到的父。
        var dependencies: [String: [String]] = [:]
        for item in survivors {
            dependencies[item.identity] = K.ownerUuids(of: item.entity).compactMap {
                if case .item(let parent) = classify($0), parent != item.identity { return parent }
                return nil
            }
        }
        var ordered: [(identity: String, entity: K.Entity)] = []
        var placed: Set<String> = []
        var remaining = survivors
        while true {
            var progressed = false
            var stillRemaining: [(identity: String, entity: K.Entity)] = []
            for item in remaining {
                let ready = (dependencies[item.identity] ?? []).allSatisfy { placed.contains($0) }
                if ready {
                    ordered.append(item)
                    placed.insert(item.identity)
                    progressed = true
                } else {
                    stillRemaining.append(item)
                }
            }
            remaining = stillRemaining
            if remaining.isEmpty || !progressed { break }
        }
        refused += remaining.count      // 环

        // 5. 按拓扑序落地。
        var steps: [OwnedItemApplyStep] = []
        var lifted = 0
        var supersededByDelete = 0
        var cancelledDeletes: Set<String> = []
        var landedIdentities: Set<String> = []

        for item in ordered {
            let identity = item.identity
            var landingParent: String?
            var wasLifted = false
            var blockedBy: String?
            for owner in K.ownerUuids(of: item.entity) {
                switch classify(owner) {
                case .item(let parent):
                    if landedIdentities.contains(parent) {
                        landingParent = parent
                    } else {
                        blockedBy = owner      // 父本身停放 / 被拒 / 在环里
                    }
                case .lift:
                    wasLifted = true
                    landingParent = ""
                case .external:
                    continue
                case .unresolved:
                    blockedBy = owner
                }
                if blockedBy != nil { break }
            }

            if let blockedBy {
                if let payload = payloadBytes(item.entity) {
                    parkedOut[identity] = ParkedOwnedItem(payload: payload,
                                                          pendingOwnerUuid: blockedBy)
                }
                continue
            }

            let cursor = table.cursors[identity]
            let baseline: K.Entity? = cursor?.reconciled.flatMap {
                guard let envelope = try? Phi_PhiEntity(serializedBytes: $0) else { return nil }
                return K.entity(from: envelope)
            }
            let merged = baseline.map { K.merge(local: $0, remote: item.entity) } ?? item.entity

            // §5.6 的 L1 支：游标带 `pendingDelete` 时到达的**存活**实体。
            if cursor?.pendingDelete == true {
                let decidedAt = cursor?.deleteDecidedAtMs ?? 0
                let newerThanDeletion = K.locationStamp(of: merged) > decidedAt
                let parentIsLive = landingParent.map {
                    $0.isEmpty || landedIdentities.contains($0) || context.liveLocalParents.contains($0)
                } ?? true
                let outsideDeletedSubtree = !context.deletedSubtree.contains(identity)
                    && !(landingParent.map { context.deletedSubtree.contains($0) } ?? false)
                // A9：把该项移到一个**活的、且不在被删子树里**的父下，且位置比删除决定更新
                // ⇒ 取消删除。其余一切入站更新都被丢弃（本机的删除赢）。
                guard newerThanDeletion, parentIsLive, outsideDeletedSubtree else {
                    supersededByDelete += 1
                    continue
                }
                cancelledDeletes.insert(identity)
            }

            if wasLifted { lifted += 1 }
            landedIdentities.insert(identity)
            let payload = payloadBytes(merged)
            let rank = K.rank(of: merged)

            if context.pairs[identity] != nil {
                // §6.3：① 把账户身份写到那条本机行上，② 再按三相把字段落下去。
                steps.append(OwnedItemApplyStep(identity: identity, kind: .claim,
                                                newParentUuid: landingParent, newRank: rank,
                                                payload: payload))
                steps.append(OwnedItemApplyStep(identity: identity, kind: .update,
                                                newParentUuid: nil, newRank: nil, payload: payload))
                continue
            }
            guard let baseline else {
                steps.append(OwnedItemApplyStep(identity: identity, kind: .create,
                                                newParentUuid: landingParent, newRank: rank,
                                                payload: payload))
                continue
            }
            let moved = wasLifted || K.ownerUuids(of: merged) != K.ownerUuids(of: baseline)
                || K.rank(of: merged) != K.rank(of: baseline)
            if moved {
                steps.append(OwnedItemApplyStep(identity: identity, kind: .move,
                                                newParentUuid: landingParent, newRank: rank,
                                                payload: payload))
            }
            if merged != baseline && !moved {
                steps.append(OwnedItemApplyStep(identity: identity, kind: .update,
                                                newParentUuid: nil, newRank: nil, payload: payload))
            }
        }

        // 6. 本轮的远端 tombstone：子先于父（§4.4 的第三相）。
        var deleteParentOf: [String: String] = [:]
        for identity in context.tombstonedIdentities {
            var entity: K.Entity?
            if let slot = slotOf[identity], slot < working.count { entity = working[slot].entity }
            if entity == nil, let bytes = table.cursors[identity]?.reconciled,
               let envelope = try? Phi_PhiEntity(serializedBytes: bytes) {
                entity = K.entity(from: envelope)
            }
            guard let entity else { continue }
            if let parent = K.ownerUuids(of: entity).first(where: {
                context.tombstonedIdentities.contains($0) || table.cursors[$0] != nil
            }) {
                deleteParentOf[identity] = parent
            }
        }
        let tombstoned = Array(context.tombstonedIdentities)
        let depths = depth(of: tombstoned, parentOf: deleteParentOf)
        for identity in tombstoned.sorted(by: {
            let left = depths[$0] ?? 0, right = depths[$1] ?? 0
            return left == right ? $0 < $1 : left > right
        }) {
            steps.append(OwnedItemApplyStep(identity: identity, kind: .delete,
                                            newParentUuid: nil, newRank: nil, payload: nil))
        }

        // 7. 三相排序，相内**稳定**（保持上面攒出来的拓扑 / 反拓扑次序）。
        let sorted = steps.enumerated().sorted { lhs, rhs in
            let lhsPhase = phase(lhs.element.kind), rhsPhase = phase(rhs.element.kind)
            return lhsPhase == rhsPhase ? lhs.offset < rhs.offset : lhsPhase < rhsPhase
        }.map(\.element)

        return OwnedItemPlan(steps: sorted, parked: parkedOut, refused: refused, lifted: lifted,
                             supersededByDelete: supersededByDelete,
                             cancelledDeletes: cancelledDeletes, harvest: harvest)
    }

    // MARK: - 认领（§6 的规则 (i)）

    /// D10 的规则 (i)，**只对书签存在**（§6.7：pin 完全不走 §6）：一条入站实体匹配到一条
    /// `syncId == nil` 的本地行 ⇒ 那一行**接过这个 uuid**，落地是一次原地更新而不是新建。
    ///
    /// **没有第二条规则。** 同步层从不因为「看起来重复」而删除或合并任何已经发布的实体
    /// （R-M3-3-28）：那一版的自动折叠会让同一个父下的每一个兄弟文件夹塌成一个（文件夹共享
    /// 同一个占位 URL），而塌掉的文件夹会把孩子甩到 Space 根上。这个函数**从不删除任何
    /// 东西，也不会让任何入站实体被丢掉**——没配上的实体照常建新行，没配上的本机行照常
    /// 自己铸身份。
    ///
    /// 匹配自上而下走：从每个有映射的 Space 的根、以及每一条**已经有身份**的本机行（跨轮
    /// 锚点，§6.3 末）出发，一层一层往下。每一层先按**完整**匹配键分组——书签是 URL，
    /// 文件夹是标题——再在组内按位配对（本地 `index` 序 × 远端 `rank` 序）。按 (Space, 路径)
    /// 分组再按位配会把一条本机的 URL X 配给一条远端的 URL Y。
    static func adopt(arrivals: [Phi_PhiBookmarkEntity], locals: [PhiLocalBookmark],
                      resolve: OwnerResolver) -> OwnedItemAdoptionResult {
        var pairs: [String: String] = [:]
        var unmatchedFolders = 0

        var localByGuid: [String: PhiLocalBookmark] = [:]
        var localGuidByIdentity: [String: String] = [:]
        for local in locals {
            localByGuid[local.guid] = local
            if let identity = local.syncId { localGuidByIdentity[identity] = local.guid }
        }
        var arrivalsByParent: [String: [Phi_PhiBookmarkEntity]] = [:]
        for entity in arrivals {
            arrivalsByParent[entity.parentUuid.stringValue, default: []].append(entity)
        }

        var queue: [(remoteParent: String, localParentGuid: String?, localSpaceId: String)] = []
        var visited: Set<String> = []
        func enqueue(_ remoteParent: String, _ localParentGuid: String?, _ localSpaceId: String) {
            let key = remoteParent + "\u{0}" + (localParentGuid ?? "") + "\u{0}" + localSpaceId
            guard visited.insert(key).inserted else { return }
            queue.append((remoteParent, localParentGuid, localSpaceId))
        }

        // 起点 ①：每一个有映射的 Space 的根。
        for entity in arrivalsByParent[""] ?? [] {
            if let spaceId = resolve.localSpaceId(entity.spaceUuid.stringValue) {
                enqueue("", nil, spaceId)
            }
        }
        // 起点 ②：一条**已经被认领过**的本机行是它孩子的锚点。规则 (i) 因此在分轮切片下
        // 继续工作，不需要任何窗口——写成「只在该 Space 首次合并时跑一次」的实现，会让
        // 第二轮到达的实体在本机建出重复行。
        for entity in arrivals {
            let parent = entity.parentUuid.stringValue
            guard !parent.isEmpty, let guid = localGuidByIdentity[parent],
                  let row = localByGuid[guid] else { continue }
            enqueue(parent, guid, row.spaceId)
        }

        var head = 0
        while head < queue.count {
            let level = queue[head]
            head += 1

            var candidates: [Phi_PhiBookmarkEntity] = []
            for entity in arrivalsByParent[level.remoteParent] ?? [] {
                // 根级那一层要按 Space 再筛一次：`parent_uuid == ""` 的实体来自账户里的
                // 每一个 Space。
                if level.remoteParent.isEmpty,
                   resolve.localSpaceId(entity.spaceUuid.stringValue) != level.localSpaceId {
                    continue
                }
                // 已经有持有者的实体不参与配对（**规则 (i) 只认 `syncId == nil` 的行**），
                // 但它是它自己那一层的锚点。
                if let guid = localGuidByIdentity[entity.bookmarkUuid] {
                    if entity.isFolder, let row = localByGuid[guid] {
                        enqueue(entity.bookmarkUuid, guid, row.spaceId)
                    }
                    continue
                }
                candidates.append(entity)
            }
            let localChildren = locals.filter {
                $0.syncId == nil && $0.spaceId == level.localSpaceId
                    && $0.parentGuid == level.localParentGuid
            }

            // 文件夹按**标题**分组，**绝不按 URL**：本地所有文件夹共享同一个占位 URL，按
            // URL 比会把一个父下的每一个兄弟文件夹判成同一个东西。
            unmatchedFolders += pairWithinGroups(
                remote: candidates.filter(\.isFolder),
                local: localChildren.filter(\.isFolder),
                remoteKey: { $0.title.stringValue },
                localKey: { $0.title }) { entity, row in
                    pairs[entity.bookmarkUuid] = row.guid
                    enqueue(entity.bookmarkUuid, row.guid, row.spaceId)
                }
            // 书签按 URL 分组。
            _ = pairWithinGroups(
                remote: candidates.filter { !$0.isFolder },
                local: localChildren.filter { !$0.isFolder },
                remoteKey: { $0.url.stringValue },
                localKey: { $0.url.absoluteString }) { entity, row in
                    pairs[entity.bookmarkUuid] = row.guid
                }
        }
        return OwnedItemAdoptionResult(pairs: pairs, adopted: pairs.count,
                                       unmatchedFolders: unmatchedFolders)
    }

    /// 一层之内的一对一配对：**先按完整键分组，再**在组内按位配（本地 `index` 序 × 远端
    /// `rank` 序）。两边都是各自视角下用户看到的顺序，于是「哪一条本地与哪一条远端相比」
    /// 是位置对应的，而不是任意的。返回没配上的**入站**条数。
    private static func pairWithinGroups(remote: [Phi_PhiBookmarkEntity],
                                         local: [PhiLocalBookmark],
                                         remoteKey: (Phi_PhiBookmarkEntity) -> String,
                                         localKey: (PhiLocalBookmark) -> String,
                                         pair: (Phi_PhiBookmarkEntity, PhiLocalBookmark) -> Void)
        -> Int {
        var remoteGroups: [String: [Phi_PhiBookmarkEntity]] = [:]
        for entity in remote { remoteGroups[remoteKey(entity), default: []].append(entity) }
        var localGroups: [String: [PhiLocalBookmark]] = [:]
        for row in local { localGroups[localKey(row), default: []].append(row) }

        var leftOver = 0
        for (key, entities) in remoteGroups {
            let orderedRemote = entities.sorted {
                let left = $0.rank.stringValue, right = $1.rank.stringValue
                return left == right ? $0.bookmarkUuid < $1.bookmarkUuid : left < right
            }
            let orderedLocal = (localGroups[key] ?? []).sorted {
                $0.index == $1.index ? $0.guid < $1.guid : $0.index < $1.index
            }
            for (offset, entity) in orderedRemote.enumerated() {
                if offset < orderedLocal.count { pair(entity, orderedLocal[offset]) }
                else { leftOver += 1 }
            }
        }
        return leftOver
    }

    // MARK: - 私有工具

    /// ① claim / create / move ② update ③ delete，与 `BookmarkApplyBatch.phase` 同义。
    private static func phase(_ kind: StepKind) -> Int {
        switch kind {
        case .claim, .create, .move: return 1
        case .update: return 2
        case .delete: return 3
        }
    }

    /// 从 `parentOf` 往上走到没有父为止。`parentOf.count` 当跳数上限：一条环在这里被截断
    /// 成一个有限深度，而不是把排序挂死。
    private static func depth(of identities: [String], parentOf: [String: String]) -> [String: Int] {
        var out: [String: Int] = [:]
        let limit = parentOf.count
        for identity in identities where out[identity] == nil {
            var hops = 0
            var cursor = parentOf[identity]
            while let parent = cursor, hops < limit {
                hops += 1
                cursor = parentOf[parent]
            }
            out[identity] = hops
        }
        return out
    }
}

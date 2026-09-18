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
    /// `adopt` 的配对表：实体身份 -> 本机行的稳定本地 id（书签是 `guid`，规则是 `PhiLocalURLRule.id`）。
    var pairs: [String: String] = [:]
    /// `adopt` 按 §6.2 算好的**字段级合并结果**（身份 -> `Phi_PhiEntity` 信封字节），即
    /// `OwnedItemAdoptionResult.merges`。`plan` 用它替换这些身份的入站实体，于是落地的是
    /// 合并结果而不是「整体采纳远端」。字节而不是实体，是为了让这个结构保持非泛型。
    var adoptedMerges: [String: Data] = [:]
    /// `OwnedItemAdoptionResult.fieldWrites`：认领之后还要写字段的那些身份。不在里面的
    /// 身份只产出一条 `.claim`——那一行的内容已经等于合并结果，再发一条空补丁没有意义。
    var adoptedFieldWrites: Set<String> = []
    /// 本轮同时到达的 tombstone 身份集合（提升只在父被**证实死亡**时发生）。
    var tombstonedIdentities: Set<String> = []
    /// 身份 -> **本机那一行此刻的出站投影**（`Phi_PhiEntity` 信封字节），由适配层按 §4.2
    /// 第 4 / 5 条盖好戳——即「这一轮的 `snapshot` 会为这条身份发布的那一份」。
    ///
    /// **§4.3 的合并是对两条实体 X、Y 对称地写的，而 X 是本机此刻那一条，不是基线。**
    /// 拿 `reconciled` 当本机那一侧，一处**还没发布**的本机编辑在线上没有任何代表：它的
    /// 字段在基线里仍是旧值旧戳，于是对端只要碰了同一条实体的**任何**一个字段，合并结果
    /// 就带着旧值回来，而 `.update` 的字段补丁是整组内容字段一起写的（`bookmarkPatch`）
    /// ——那次本机编辑被静默改写，没有 commit、没有计数，两台机器都认为自己收敛了。
    /// 基线的用途是**差分出要发布什么**（§4.2 第 4 条的盖戳判据），不是决定落地什么。
    ///
    /// 只给**有基线**的身份算（无基线那一类走 §6.2 的 `adoptedMerges`，或者本来就整条
    /// 采纳远端）：没有基线时 `stamp` 会把 `location` / `rank` 盖成 0 并把内容字段盖成
    /// `contentUpdatedDate`，那是认领那条路的规则，不是一条已经在账户上的行的规则。
    var localProjections: [String: Data] = [:]
    /// 本轮因一条远端文件夹 tombstone 而要消失的身份（A9 的第三个合取项）。
    var deletedSubtree: Set<String> = []
    /// 解析得到一条**活的**本地行的父身份（A9 的第二个合取项）。
    var liveLocalParents: Set<String> = []
    /// 本机当前作用域与账户作用域（书签两者都传 nil）。两者都非 nil 且**不相等**时，
    /// §7.3 的作用域不一致成立：`plan` 产出零 step、把入站实体**全部**塞进 `parked`。
    var localScope: PinnedTabScope? = nil
    var accountScope: PinnedTabScope? = nil
    /// 身份 -> 那一行**这一页落地之前**的合并签名（D30 / §8.4.1），由适配层的 pre-pass 填
    /// （8b-2 计划裁定二）。`plan` 手上没有本机行（`localProjections` 是投影字节，不是行），
    /// 算不出签名，所以它只在产出 `.move` / `.update` 的那一刻**照身份查一次**这张表并把命中的
    /// 那些抄进 `OwnedItemPlan.preLandingSignatures`；查不到的身份**结构性地不在表里**
    /// （不强解包、不填空值）。
    ///
    /// 类型逐字是 `[String: RuleSignature]`（8b-2 计划裁定一）：`AnyHashable` 会把第二遍指针的
    /// 分组键从编译期类型退化成运行期强转（失败即**静默**空转，正是 RR12-1 点名的那种失效），
    /// 而给 `OwnedItemKind` 加第三个关联类型会把非泛型的 `OwnedItemPlan` 也拖成泛型、牵动书签
    /// 与 pin 的每一个调用点。本文件已经在 `localScope` / `accountScope` 上具名引用了 pin 专属
    /// 的 `PinnedTabScope`，全仓又是**一个** Swift module，所以这里没有任何新的构建边。
    /// **书签与 pin 那两条路径永不填它。**
    var localSignatures: [String: RuleSignature] = [:]
    /// 轮首之后作用域**动过**（R-exec-12）：两个值在轮首取样时还一致，落地之前再读已经不是
    /// 那一对了。轮内那份本机投影因此过期，与「两者不相等」同等处理——差别只在它证明的是
    /// 「投影过期」而不是「本机与账户不一致」，而 §7.3 的处置对两者是同一个。
    var scopeMovedMidRound = false
    var scopeMismatch: Bool {
        if scopeMovedMidRound { return true }
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
    /// 新增（M3-4a / R-M3-4a-26）。非 nil = 这一步把该身份搬到另一个归属桶。
    /// 只有归属可变的 kind 会填它；书签的归属变化走 `newParentUuid` + `location`，
    /// pin 的归属在 client tag 里、根本变不了。**默认 nil**，所以书签与 pin 的每一处
    /// 构造点与每一条既有 `==` 断言逐字不变。
    var newOwnerUuid: String? = nil
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
    /// 合并结果里**本机那一侧赢了字段**的那些身份：必须重新发布（与
    /// `OwnedItemAdoptionResult.mustRepublish` 同一条规则、同一个理由，§6.2）。
    ///
    /// 普通差分对它们的回答永远是「没变化」——落地之后本机那一行与 `reconciled` 逐字相等，
    /// 于是快照算出来的字节就是基线本身。不显式排进发布队列，本机赢下的那个值**永远**到不了
    /// 账户，而两台机器都认为自己收敛了。
    var mustRepublish: Set<String> = []
    /// **本轮一条 step 都产不出、因此要连同存活实体一起停放的 tombstone 身份**（§7.3 的
    /// 作用域不一致）。调用方把它们写成游标的 `pendingTombstone`，下一轮的工作集照常带上。
    ///
    /// 它与 `parked` 是同一件事的两半：那一支把入站的**存活**实体全部塞进 `parked`，而
    /// tombstone 没有载荷可停（§2.5：它只有 tag hash），所以只能在这里报出身份。少了这半边，
    /// 一次作用域不一致轮会把本轮到达的每一条远端删除**永久**丢掉——版本已经收割、游标看上去
    /// 健康、marker 早已推过那一页，于是那条 pin 在本机永远不死，而账户上它早就没了。
    var parkedTombstones: Set<String> = []
    /// 身份 -> 要写进 `reconciled` 的新字节，**而这条身份本轮一个 step 都没有**。
    ///
    /// LWW 比的是 `(值, 戳)` 这一对，所以一条**取值没变、戳更新**的入站实体照样要被吃下：
    /// 对端把标题从 A 改成 B 再改回 A，账户上那条是 `A@300`，而本机基线还停在 `A@100`。
    /// 落地那一侧确实什么都不用做（那一行已经是 A，产一条空补丁是错的），但基线**必须**跟上
    /// ——不跟上的话，一条后到的 `B@200`（重放、第三台设备、marker 回退都产得出）会拿 200 去
    /// 比 100 而**赢下**，把账户上更新的那个 A 覆盖掉，两台机器从此不同。
    ///
    /// 这一位不破坏「apply → 基线」的次序（§4.5）：走到这里的身份按定义没有任何东西要落地，
    /// 合并结果与基线在**取值**上逐字相同，差的只是时间戳。
    var rebaselined: [String: Data] = [:]
    /// 身份 -> 那一行**这一页落地之前**的合并签名（D30 / §8.4.1 / R-M3-4a-73），
    /// **只在产出 `.move` / `.update` 的那一刻**从 `OwnedItemPlanContext.localSignatures` 抄下来。
    ///
    /// §8.4.3 第 1 步的**第二遍**指针按它分组：一条本页被 `.move` 搬走目标的规则 Z，与一条
    /// 留在旧目标上、本页什么都不落地的同签名重复 X，按**此刻**的签名已经不同组了，而那正是
    /// 唯一需要写下指针的形状（R-M3-4a-74 / 75）。三条禁令：**绝不**落地之后重读行（那时行
    /// 已经在新目标上，第二遍与第一遍逐字相同）；**绝不**用 `OwnedItemApplyStep.newOwnerUuid`
    /// （那是**新**目标）；**绝不**在轮首冻结一次（pre-pass 每页跑一次，CASE M2-b）。
    ///
    /// **书签与 pin 恒空**（它们的 plan 上下文不填 `localSignatures`）。
    var preLandingSignatures: [String: RuleSignature] = [:]
}

/// §4.6 的结构性拒收判据。**没有 `refusedAtMs`**：这些判据全是结构性的，对端修好就该被
/// 接受，所以每轮重判一次（Space 侧那个「记住我拒过」的优化已经变成一条无法自愈的永久
/// 排除）。
enum OwnedItemRefusal: Equatable {
    case illegalRank, cycle, isFolderMismatch, selfReference, invalidUuid, invalidURL
    /// §5.4：`host` 归一后为空。三处写路径与桥接层都把空 host 当成「丢弃这一行」。
    case emptyHost
    /// §5.4：`host` 归一后是 `"*"` 或 `"*."`。两个匹配器都显式判死。
    case degenerateHost
    /// §5.4：`host` 含 `/`；或含 `:` 且**不是**「以 `[` 开头、以 `]` 结尾」的 IPv6 字面量。
    case malformedHost
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
    /// §6.2 的字段级合并结果（身份 -> `Phi_PhiEntity` 信封字节）：本机内容字段带着
    /// `contentUpdatedDate ?? createdDate` 的戳与远端各自的戳按 LWW 定胜负，位置**取远端**
    /// （本机那一行没有基线，它的位置纯属本机派生）。喂给 `plan` 的 `context.adoptedMerges`。
    var merges: [String: Data] = [:]
    /// 合并结果里有本机字段赢了的那些身份 —— **必须重新发布**，走正常的快照与切片。
    /// 本机赢了却不发布，对端永远停在旧值上，而两边都认为自己收敛了。
    var mustRepublish: Set<String> = []
    /// 落地时**确实要写字段**的那些身份：合并结果的内容与那条本机行现在的内容不同。
    ///
    /// 与 `mustRepublish` 是相反的两个方向，都要有：本机赢了一个字段 ⇒ 那一行已经是对的、
    /// 账户不是（`mustRepublish`）；远端赢了一个字段 ⇒ 账户是对的、那一行要被改写（这个
    /// 集合）。只认领而不写字段，一条被远端改过名的行会永远停在本机的旧标题上，而
    /// `reconciled` 说的是新标题——下一轮的快照于是拿那个旧标题去发布，两台机器永久分歧。
    var fieldWrites: Set<String> = []
    /// 配上了、但**合并算不出来**（投影失败）而被丢掉的配对数。
    ///
    /// 丢掉而不是「退回整体采纳远端」：那条路会在一次归属解析抖动里静默吃掉用户的本机编辑。
    /// 丢掉的代价只是那一行这一轮保持未同步，下一轮重来。
    var unmergeablePairs: Int = 0
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
    ///
    /// `baseline` 是本机手上那条已落地的实体（没有就是 nil），**§4.6 的 `is_folder` 判据
    /// 要它**：一条行不会在书签与文件夹之间变形，两侧不符的那条实体要被**拒收**而不是被
    /// 合并掉。把这一条放进 `refuses` 而不是新开一个成员，是为了让 §4.6 那张表只有一个
    /// 实现点。
    static func refuses(_ entity: Entity, baseline: Entity?) -> OwnedItemRefusal?
    /// 这条实体落地**之前必须已经解析出来**的归属引用。
    ///
    /// **复数**（spec §4.1）：一条实体可以有不止一个归属引用，§4.4 第 4 步要为其中任一个
    /// 记 `pendingOwnerUuid`，单个可选表达不了。书签返回的是**绑定**的那一个——子孙是
    /// `parent_uuid`，根级项是 `space_uuid`；子孙的 `space_uuid` 是诊断字段，接收端忽略
    /// （R-M3-3-18），把它也算成必须解析会让一次「移走文件夹再删掉旧 Space」把整棵子树
    /// **永久**停放在每一台新设备上。
    static func ownerUuids(of entity: Entity) -> [String]

    /// 这条本机行**当前所在的归属**：书签是它那个 Space 的 syncUuid，pin 是推导出来的
    /// ownerKey。nil = 归属没有映射。
    ///
    /// **与 `ownerUuids(of:)` 是两件事，不能合并**：后者是「落地之前必须已经解析出来的
    /// 引用」，对一条子孙书签而言那是它的**父**；而 hidden / purged 的排除判据问的是「这一
    /// 行坐在哪个 Space 里」。用 `ownerUuids` 去判，`resolve.localSpaceId(<一个书签 uuid>)`
    /// 恒为 nil，于是一个账户已软删、本机还留着 30 天的 Space 底下**每一条非根行**都继续
    /// 发布，30 天后被 purge 级联静默删掉，而整段时间里每一个计数器都是健康值。
    ///
    /// 这同时是引擎每轮要刷进每条游标 `ownerUuid` 的那个值（A12 / §3.5），所以它只该有一个
    /// 实现点。
    static func eligibilityOwner(of local: Local, resolve: OwnerResolver,
                                 scope: PinnedTabScope?) -> String?

    static func localEdge(of local: Local) -> (id: String, parentId: String?)
    static func rank(of entity: Entity) -> String
    static func locationStamp(of entity: Entity) -> Int64
    static func stamp(_ projected: Entity, baseline: Entity?, local: Local,
                      rank: String, now: Int64) -> Entity
    /// 这条实体**内容字段**的取值字节（时间戳清零），与 `SyncableSettings.signature(of:)`
    /// 同义、同理由：判「要不要带一份字段补丁」只能看取值，看整条实体会把对端一次纯重盖戳
    /// 也算成一次内容变化，产出一条空补丁。位置与 rank **不在里面**——它们由 `.move` 承载。
    static func contentSignature(of entity: Entity) -> Data

    /// 这条实体现在**指向**哪一个归属桶（规则的 `target_space_uuid` 字段值）。
    /// nil = 这一 kind 的归属不可变、或不由单一字段承载 ⇒ `.move` 不带 `newOwnerUuid`。
    ///
    /// **不是 `ownerUuids(of:).first`**（R-M3-4a-26 / RR-B5）：那个成员的合同是「落地前必须
    /// 解析出来的归属引用」，将来任何一条 kind 想把某个归属排除在停放判据外时又会返回空；
    /// 而 `plan` 是泛型的，拿不到任何具体字段，所以通道只能是一个协议成员。
    static func targetOwnerUuid(of entity: Entity) -> String?
}

extension OwnedItemKind {
    /// 默认 nil：`BookmarkKind` 与 `PinKind` 一行不改、行为逐字不变。
    static func targetOwnerUuid(of entity: Entity) -> String? { nil }
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

    /// 转发到 `SyncableSpaces.rankBetween`，**顺带过一次探针**。
    ///
    /// 本模块**唯一**的 rank 生成路径是 `snapshot` 里那次 `assignRanks`，它把这个转发器作为
    /// 注入点传了进去，所以探针数到的就是真实次数。入站路径（`plan`）一条都不该有：
    /// `rankBetween` 在发布构建里用 `precondition` 直接 trap，而对端字节是不可信输入。
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
    ///
    /// - Precondition: `locals` 已按**同级次序**排好（书签是
    ///   `(spaceId, parentGuid, index, guid)`，`PhiBookmarkLocalAccess.allBookmarks()` 的契约）。
    ///   rank 通道把它当成「当前本机次序」直接喂给 `assignRanks`；换成任何别的次序，每一轮
    ///   都会重排一批本来不该动的 rank。
    static func snapshot<K: OwnedItemKind>(_ kind: K.Type, locals: [K.Local],
                                           table: PhiOwnedItemTable, resolve: OwnerResolver,
                                           scope: PinnedTabScope?, now: Int64)
        -> OwnedItemSnapshotResult<K.Entity> {
        var skippedUnmappedOwner = 0
        var skippedIneligibleOwner = 0

        // 第一遍：逐行判「它**自己**是不是本轮的同步合格行」（§4.2 第 1 / 3 条）。
        //
        // 归属判据读的是 `eligibilityOwner`——**这一行坐在哪个 Space 里**，不是它的绑定
        // 引用。对一条子孙书签来说绑定引用是它的父，拿那个去问 `isEligibleSpace` 永远为真，
        // 于是一个账户已软删的 Space 底下每一条非根行都会继续发布。
        var indexByLocalId: [String: Int] = [:]
        var identityOf: [String?] = []
        var selfEligible: [Bool] = []
        for (offset, local) in locals.enumerated() {
            indexByLocalId[K.localEdge(of: local).id] = offset
            guard let identity = K.identity(of: local, resolve: resolve, scope: scope) else {
                identityOf.append(nil)
                selfEligible.append(false)
                continue
            }
            identityOf.append(identity)
            guard let owner = K.eligibilityOwner(of: local, resolve: resolve, scope: scope) else {
                skippedUnmappedOwner += 1
                selfEligible.append(false)
                continue
            }
            if resolve.localSpaceId(owner) != nil, !resolve.isEligibleSpace(owner) {
                skippedIneligibleOwner += 1
                selfEligible.append(false)
                continue
            }
            // §4.2 第 3 条：停放中 / 待发 tombstone / 待发删除的游标一律不进快照。一个停放中
            // 的实体若被快照，每个字段会盖上 `now` 再按停放游标的 entityId/version 当 update
            // 提交，把账户上那条整体覆盖成本机的值。
            if let cursor = table.cursors[identity] {
                guard cursor.pendingApply == nil, !cursor.pendingTombstone,
                      !cursor.pendingDelete else {
                    selfEligible.append(false)
                    continue
                }
            }
            selfEligible.append(true)
        }

        // §4.2 第 2 条：**父行不是本轮的同步合格行 ⇒ 该行本轮跳过**（整条祖先链都要合格）。
        // 不计任何计数——它不是「归属没映射」，把它算进 `excluded_unmapped_owner` 会让那个
        // 计数混进另一种现象。一条子书签若在父的实体即将被 tombstone / 停放 / 过期时照发，
        // 账户上会留下一条指着一个不该存在的父的实体。
        func chainEligible(_ offset: Int) -> Bool {
            guard selfEligible[offset] else { return false }
            var hops = 0
            var parentId = K.localEdge(of: locals[offset]).parentId
            while let id = parentId, hops <= locals.count {
                guard let parentOffset = indexByLocalId[id], selfEligible[parentOffset] else {
                    return false
                }
                parentId = K.localEdge(of: locals[parentOffset]).parentId
                hops += 1
            }
            return true
        }

        // 本地 id -> 账户身份，**只收合格行**：子行的 `parent_uuid` 只能填一个合格父的身份。
        var identityByLocalId: [String: String] = [:]
        for (offset, local) in locals.enumerated() where selfEligible[offset] {
            identityByLocalId[K.localEdge(of: local).id] = identityOf[offset]
        }

        var candidates: [(identity: String, local: K.Local, entity: K.Entity, group: String)] = []
        // **一条身份至多一个候选**（R-exec-12 / D-B）。`locals` 是一行一条，而 pin 的身份是
        // `(lineage, owner)` **推导**出来的（§3.2 / R-M3-3-15），所以两条本机行完全可能算出
        // 同一条身份——书签那一侧靠 `syncId` 那一列，结构上产不出这个形状。
        //
        // 不去重的后果不是「多发一条」，是**永不收敛**：下面那个 rank 通道按行喂
        // `assignRanks`，于是同一个 uuid 在 `order` 里出现两次；重复的那一个按定义不在严格
        // 递增的保留集里，每一轮都被派一个新铸的 `rankBetween`，而 `assigned` 按 uuid 记账
        // ⇒ 它**盖掉**保留的那一条刚拿到的 rank。这条身份的发布字节于是每一轮都与基线不同
        // （`PhiSyncEngine` 的发布判据是裸字节比较），每一轮都提交一次，分数键一轮长一个
        // 字符——Mac B 2026-09-14 那一分钟 25 轮、922 → 934 字节的提交循环就是这个。
        //
        // 留**第一条**：`allPins()` 按 `(ownerKey, index, guid)` 有序，于是留下的正是
        // `PinKind.normalizeVariants` 折叠时留下的同一条行。正常情况下身份本来就互不相同，
        // 这一趟一条都不丢。
        var claimedIdentities: Set<String> = []
        for (offset, local) in locals.enumerated() {
            guard chainEligible(offset), let identity = identityOf[offset] else { continue }
            guard claimedIdentities.insert(identity).inserted else { continue }
            let parentIdentity = K.localEdge(of: local).parentId.flatMap { identityByLocalId[$0] }
            // 归属已经在第一遍判过，所以这一支是防御性的：投影再失败就静默跳过，绝不
            // 二次计进任何一个排除计数。
            guard let entity = K.project(local, resolve: resolve, scope: scope,
                                         parentIdentity: parentIdentity) else { continue }
            candidates.append((identity, local, entity,
                               K.ownerUuids(of: entity).joined(separator: "\u{0}")))
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
            for (identity, rank) in SyncableSpaces.assignRanks(order: order,
                                                              rankBetween: rankBetween) {
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
    ///
    /// `pendingClaims` 是第六条排除，也是「还没认领上」与「认领不上」之间那道界线
    /// （R-exec-9）：里面装的是**本轮 §6 的认领真的配上了、但那次 `syncId` 写回没能落盘**的
    /// 身份（导入锁拒了那一批）。那条本机行离认领只差一次成功的写回，而它此刻还没有
    /// `syncId`，于是第三条判据（「本机确实没有这一行了」）对它成立——不排除它，这一轮就会
    /// 把一条两边都同意它存在的账户实体删掉，下一轮本机那一行再铸一个新身份重新建一条，
    /// 对端看到的是一次删除加一次毫无关系的新建。
    ///
    /// **绝不能退化成「`pendingApply != nil` 就排除」**：一条认领**配不上**的停放游标
    /// （用户在重试窗口里改了那一行或把它删了）正是该被 tombstone 的那一类，靠 `pendingApply`
    /// 一刀切会把它永久留在账户上，而没有任何设备还能删掉它。
    ///
    /// **第七个入参 `explicitDeletions` 是规则这一 kind 的第二个 tombstone 起源**
    /// （R-M3-4a-78）。上面那套判据是**跟随端保护**：账户说某个 Space 没了、或本机映射还没
    /// 建起来，就不替别人发删除。而「用户在本机删掉一个 Space」恰好踩中两道归属门的中间
    /// 态——`SpaceModel` 行已在同一次提交里删掉 ⇒ `isEligibleSpace(owner)` 假，sync-uuid
    /// 映射却还在 ⇒ `localSpaceId(owner)` 非 nil ⇒ 合格门逐条 `continue` ⇒ 一条 tombstone
    /// 都发不出来，本机没了、账户还在，那些实体成为**任何设备都删不掉**的孤儿。
    ///
    /// 落在这个集合里的身份**只跳过两道归属门**：它的软删**就是**用户这一次删除动作本身
    /// 写下的，归属合不合格与「用户要不要删它」无关；而它已经在账户上（第一条判据）。
    /// 其余三条判据、`pendingClaims` 排除与整段游标记账**逐字照旧**。
    ///
    /// **集合的来源必须是「一次删除决定」，不是「行不见了」**（R-M3-4a-85）：保留期 purge
    /// 是跟随不是决定，它对规则行走硬删、绝不写 `deletedDate`，因此永远进不了这个集合。
    static func tombstones<K: OwnedItemKind>(_ kind: K.Type, locals: [K.Local],
                                             table: PhiOwnedItemTable, resolve: OwnerResolver,
                                             scope: PinnedTabScope?,
                                             nowMs: Int64,
                                             pendingClaims: Set<String> = [],
                                             explicitDeletions: Set<String> = []) -> OwnedItemTombstoneResult {
        // 往后长的入参一律接在 `pendingClaims` 之后、一律带默认值：Task 8b-3 的
        // `deferredDeletions: Set<String> = []` 排在 `explicitDeletions` 之后（R-M3-4a-84），
        // 书签 / pin 的调用点与既有用例一个字都不用改。
        var liveIdentities: Set<String> = []
        for local in locals {
            if let identity = K.identity(of: local, resolve: resolve, scope: scope) {
                liveIdentities.insert(identity)
            }
        }

        var identities: [String] = []
        var cursorUpdates: [String: PhiOwnedItemCursor] = [:]
        for (identity, cursor) in table.cursors {
            // Task 8b-3 的 `deferredDeletions` 进来时排在**这一行之前**（R-M3-4a-84）：
            // 它要的是「不进 identities、零 cursorUpdates」，所以必须先于三条判据。
            guard cursor.reconciled != nil else { continue }
            guard cursor.deletedAtMs == nil else { continue }
            guard !liveIdentities.contains(identity) else { continue }
            // 本轮认领已经配上、只差一次成功的写回（R-exec-9）。
            guard !pendingClaims.contains(identity) else { continue }
            // 两道**归属**门，起源 (b) 的身份从这里绕过去（R-M3-4a-78）。
            if !explicitDeletions.contains(identity) {
                // **`ownerUuid == nil` 按「归属未知」处理，不放行**：引擎每轮要为表里的每一条
                // 游标刷新这个字段（A12 / §3.5），所以 nil 说明那条前置条件没成立，而本模块
                // 检查不了。方向只能是保守的——发不出 tombstone 最多留一条本机已经没有的实体，
                // 放行则可能删掉账户上一整个 Space 的书签。
                guard let owner = cursor.ownerUuid else { continue }
                // 归属未映射。**pin 的 App 作用域 ownerKey 是字面量**，它不需要映射：
                // Task 4b 接入时由 `PinKind` 保证那条游标的 `ownerUuid` 不写字面量，或者
                // 由引擎的 resolver 把它映成自身。
                let mapped = resolve.localSpaceId(owner) != nil || resolve.localProfileId(owner) != nil
                guard mapped else { continue }
                // 归属不合格（hidden / purged）。
                guard resolve.localSpaceId(owner) == nil || resolve.isEligibleSpace(owner) else { continue }
            }
            identities.append(identity)
            var updated = cursor
            updated.pendingApply = nil
            updated.pendingOwnerUuid = nil
            updated.pendingDelete = true
            // **删除决定的时刻只写一次。** 一条已经待删、同时还停着一条入站更新的游标是
            // 可达的（`plan` 会在走到 `pendingDelete` 那一支之前先把被挡住的实体停放下来），
            // 重写这个戳会把 A9 那条「入站位置比删除决定更新」的比较基准一路往后推，于是
            // 一次并发移动永远取消不了删除。
            if !cursor.pendingDelete { updated.deleteDecidedAtMs = nowMs }
            if updated != cursor { cursorUpdates[identity] = updated }
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
        //
        // **tombstone 与存活实体一起停**（spec §12.1 第 15 条：「本轮到达的 pin 实体全部进
        // `pendingApply`，tombstone 进 `pendingTombstone`」）。它们没有载荷可以塞进 `parked`
        // ——一条 tombstone 只有 tag hash（§2.5）——所以走 `parkedTombstones` 这条身份通道。
        // 只停存活实体的写法会把本轮到达的每一条远端删除永久丢掉：marker 早已推过那一页，
        // 服务端不会再发第二次。
        if context.scopeMismatch {
            var parkedOut = parked
            for item in arrivals {
                let identity = K.identity(of: item.entity)
                guard !identity.isEmpty, let payload = payloadBytes(item.entity) else { continue }
                parkedOut[identity] = ParkedOwnedItem(
                    payload: payload, pendingOwnerUuid: K.ownerUuids(of: item.entity).first)
            }
            return OwnedItemPlan(steps: [], parked: parkedOut, refused: 0, lifted: 0,
                                 supersededByDelete: 0, cancelledDeletes: [], harvest: harvest,
                                 parkedTombstones: context.tombstonedIdentities)
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
        var refused = 0
        for item in arrivals {
            let identity = K.identity(of: item.entity)
            // §4.6 的第一条判据：uuid 为空 ⇒ 拒收。丢掉而不计数会让一个每轮都在发空 uuid 的
            // 对端在计数行上完全不可见。
            guard !identity.isEmpty else { refused += 1; continue }
            if let slot = slotOf[identity] {
                working[slot] = (identity, item.entity)
            } else {
                slotOf[identity] = working.count
                working.append((identity, item.entity))
            }
        }

        // 2. 拒收与 tombstone 覆盖。孩子自己也带 tombstone 时**不提升**——那才是「这条也
        //    该消失」，所以它的活实体在这里就被它自己的 tombstone 盖掉。
        func baselineOf(_ identity: String) -> K.Entity? {
            guard let bytes = table.cursors[identity]?.reconciled,
                  let envelope = try? Phi_PhiEntity(serializedBytes: bytes) else { return nil }
            return K.entity(from: envelope)
        }

        var survivors: [(identity: String, entity: K.Entity)] = []
        for item in working {
            if context.tombstonedIdentities.contains(item.identity) { continue }
            // 基线一并交给 `refuses`：§4.6 的 `is_folder` 判据比的就是「与本机已有的那一条
            // 不符」。合并掉这个分歧（取并 / 取一侧）是错的——它是 INVARIANT 不是 LWW。
            if K.refuses(item.entity, baseline: baselineOf(item.identity)) != nil {
                refused += 1
                continue
            }
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
        var mustRepublish: Set<String> = []
        var rebaselined: [String: Data] = [:]
        var preLandingSignatures: [String: RuleSignature] = [:]
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
            let baseline = baselineOf(identity)
            // 认领的身份走 §6.2 的**字段级**合并，结果由 `adopt` 算好、经 `context` 传进来。
            // 一条被认领的本机行没有基线，所以下面那条「与基线合并」的通路对它退化成
            // 「整体采纳远端」——而那正是 §6.2 点名禁止的东西（用户在一次二十分钟的首同步
            // 期间改的标题会静默消失，没有 commit 也没有计数）。
            let adopted: K.Entity? = context.adoptedMerges[identity].flatMap {
                guard let envelope = try? Phi_PhiEntity(serializedBytes: $0) else { return nil }
                return K.entity(from: envelope)
            }
            // **合并的本机那一侧是本机行此刻的投影**（`context.localProjections`），基线只在
            // 没有投影时兜底。理由写在 `OwnedItemPlanContext.localProjections` 上：基线里那
            // 一份是**上一次同步**的值，用它当本机那一侧会让一处还没发布的本机编辑在对端
            // 碰了同一条实体的任何字段时被改写掉。
            let localProjection: K.Entity? = context.localProjections[identity].flatMap {
                guard let envelope = try? Phi_PhiEntity(serializedBytes: $0) else { return nil }
                return K.entity(from: envelope)
            }
            let merged = adopted
                ?? localProjection.map { K.merge(local: $0, remote: item.entity) }
                ?? baseline.map { K.merge(local: $0, remote: item.entity) }
                ?? item.entity
            // 本机赢下 `location` 时落地的父要跟着合并结果走，否则那一行会被搬到**输掉的**
            // 那个父下面，而 `reconciled` 说的是另一个——下一轮的快照把它当成一次本机移动
            // 再发出去，一次本机移动因此变成两次。`nil` = 「照载荷自己的父落地」，而载荷
            // 就是合并结果。提升（`wasLifted`）是模块自己作的决定，不受这一条影响。
            if !wasLifted, landingParent != nil,
               K.ownerUuids(of: merged) != K.ownerUuids(of: item.entity) {
                landingParent = nil
            }

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
            // §6.2 的那条规则，落在普通更新路径上：合并结果与**账户手上那一份**不同 ⇒ 本机
            // 赢了点什么，这条实体要重新发布。判据比的是整条实体而不是内容签名——本机也可能
            // 赢下 `location` / `rank`，而那两样都不在签名里。认领那一支不在这里：它的
            // `mustRepublish` 由 `adopt` 自己算（本机那一侧没有基线，判据不同）。
            if adopted == nil, localProjection != nil, payload != payloadBytes(item.entity) {
                mustRepublish.insert(identity)
            }

            if context.pairs[identity] != nil {
                // §6.3：① 把账户身份写到那条本机行上，② 再按三相把字段落下去。两条 step
                // 是因为落地的 claim 操作只写 `syncId`，内容只走 update。
                steps.append(OwnedItemApplyStep(identity: identity, kind: .claim,
                                                newParentUuid: landingParent, newRank: rank,
                                                payload: payload))
                if context.adoptedFieldWrites.contains(identity) {
                    steps.append(OwnedItemApplyStep(identity: identity, kind: .update,
                                                    newParentUuid: nil, newRank: nil,
                                                    payload: payload))
                }
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
                // `newOwnerUuid` 从合并结果的归属字段填（R-M3-4a-26）：`.claim` / `.create` /
                // `.update` / `.delete` 四处一律不填，`.create` 的目标在载荷里、由落地闭包自己读。
                steps.append(OwnedItemApplyStep(identity: identity, kind: .move,
                                                newParentUuid: landingParent,
                                                newOwnerUuid: K.targetOwnerUuid(of: merged),
                                                newRank: rank, payload: payload))
                // D30 / §8.4.3 第 1 步的第二遍分组键：**产出 step 的这一刻**记下那一行落地前的
                // 签名（8b-2 计划裁定二）。算不出的身份结构性地不在表里。
                if let key = context.localSignatures[identity] {
                    preLandingSignatures[identity] = key
                }
            }
            // **移动与内容改动是两条步骤，不是二选一。** 落地的 move 操作
            // （`BookmarkApplyOp.move`）不带字段补丁，内容只走 update；一条既搬了家又被改了
            // 名的实体若只产出 move，那次改名永远到不了本机行，而下一轮的快照会拿本机的旧
            // 标题盖回账户——对端的编辑被销毁，且没有任何计数动一下。
            //
            // 判据是**内容签名**而不是整条实体：对端一次纯重盖戳不该产出一条空补丁。
            let contentChanged = K.contentSignature(of: merged)
                != K.contentSignature(of: baseline)
            if contentChanged {
                steps.append(OwnedItemApplyStep(identity: identity, kind: .update,
                                                newParentUuid: nil, newRank: nil, payload: payload))
                // 同上（8b-2 计划裁定二）：`.move` 与 `.update` 是同一条身份的两条 step，记两次
                // 是幂等的（值相同）。
                if let key = context.localSignatures[identity] {
                    preLandingSignatures[identity] = key
                }
            }
            // 一条 step 都没有、而合并结果与基线仍然不同 ⇒ 只差时间戳，基线照样要跟上
            // （见 `OwnedItemPlan.rebaselined`）。判据是「本轮没有任何东西要落地」，所以它
            // 必须排在上面两条之后。
            if !moved, !contentChanged, let payload,
               payload != table.cursors[identity]?.reconciled {
                rebaselined[identity] = payload
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
                             cancelledDeletes: cancelledDeletes, harvest: harvest,
                             mustRepublish: mustRepublish, rebaselined: rebaselined,
                             preLandingSignatures: preLandingSignatures)
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
        var merges: [String: Data] = [:]
        var mustRepublish: Set<String> = []
        var fieldWrites: Set<String> = []
        var unmergeablePairs = 0

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

        /// §6.2 的字段级合并，**不是「整体采纳远端」**。
        ///
        /// 本机那一侧是「这条行投影出来、按无基线规则盖过戳」的实体：内容字段带
        /// `contentUpdatedDate ?? createdDate`，位置与 rank 带 0。于是内容按 LWW 各自定胜负，
        /// 位置必然取远端（0 输给任何真实的戳）——正是 §6.2 那张表。
        ///
        /// 本机戳**必须是 `contentUpdatedDate`**：`updatedDate` 被 `updateLastSeen` /
        /// `updateTabFavicon` / `normalizeIndexes` 三条**非编辑**路径往前推，而「往前推」正是
        /// 让一个没人动过的本机旧值赢下对端刚做的编辑的那个方向。
        /// 算得出合并就记下来并返回 true；**算不出就返回 false，那一对不成立**。
        ///
        /// 绝不「算不出就退回整体采纳远端」：那条路会在一次归属解析抖动里静默吃掉用户在
        /// 加入期间做的编辑，而那正是 §6.2 花整节篇幅禁止的东西。不配对的代价只是那一行
        /// 这一轮保持未同步、下一轮重来，而入站实体照常建一条新行。
        func recordMerge(_ entity: Phi_PhiBookmarkEntity, _ row: PhiLocalBookmark) -> Bool {
            let parentIdentity = entity.parentUuid.stringValue
            guard var projected = BookmarkKind.project(row, resolve: resolve, scope: nil,
                                                       parentIdentity: parentIdentity.isEmpty
                                                           ? nil : parentIdentity) else {
                return false
            }
            projected = BookmarkKind.stamp(projected, baseline: nil, local: row,
                                           rank: "", now: 0)
            // 那一行还没有身份，所以投影出来的 uuid 是空串；合并之后它接过远端这一个。
            let merged = BookmarkKind.merge(local: projected, remote: entity)
            guard let bytes = try? BookmarkKind.envelope(merged).serializedData() else {
                return false
            }
            merges[entity.bookmarkUuid] = bytes
            // 合并结果与账户手上那一份不同 ⇒ 本机赢了至少一个字段 ⇒ 必须重新发布。
            if merged != entity { mustRepublish.insert(entity.bookmarkUuid) }
            // 合并结果的内容与那一行现在的内容不同 ⇒ 落地时要写字段。
            if BookmarkKind.contentSignature(of: merged)
                != BookmarkKind.contentSignature(of: projected) {
                fieldWrites.insert(entity.bookmarkUuid)
            }
            return true
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
                    guard recordMerge(entity, row) else { unmergeablePairs += 1; return }
                    pairs[entity.bookmarkUuid] = row.guid
                    enqueue(entity.bookmarkUuid, row.guid, row.spaceId)
                }
            // 书签按 URL 分组。
            _ = pairWithinGroups(
                remote: candidates.filter { !$0.isFolder },
                local: localChildren.filter { !$0.isFolder },
                remoteKey: { $0.url.stringValue },
                localKey: { $0.url.absoluteString }) { entity, row in
                    guard recordMerge(entity, row) else { unmergeablePairs += 1; return }
                    pairs[entity.bookmarkUuid] = row.guid
                }
        }
        return OwnedItemAdoptionResult(pairs: pairs, adopted: pairs.count,
                                       unmatchedFolders: unmatchedFolders,
                                       merges: merges, mustRepublish: mustRepublish,
                                       fieldWrites: fieldWrites,
                                       unmergeablePairs: unmergeablePairs)
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

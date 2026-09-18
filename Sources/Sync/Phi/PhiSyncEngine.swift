import CryptoKit
import Foundation

/// The engine's view of the domain key. `PhiDomainKeyManager` is a concrete final class with
/// no seam of its own, so the abstraction lives here — the same shape as
/// `protocol KeyEnvelopeAPI` / `extension KeyEnvelopeAPIClient: KeyEnvelopeAPI {}`.
protocol PhiDomainKeyProviding: AnyObject {
    func domainKey() async throws -> SymmetricKey
}

/// The witness is `@MainActor` (see `PhiDomainKeyManager`), which an `async` requirement
/// accepts: the engine's `await domainKeys.domainKey()` becomes a hop onto the main actor,
/// which is exactly the point — it keeps the M2 key layer main-actor-confined.
extension PhiDomainKeyManager: PhiDomainKeyProviding {}

/// Metadata-only rendering of an error for the shipped log (design §8 / ruling R12).
///
/// A bare `\(error)` is not safe here: `KeyAPIError.http(Int, String)` carries the server's
/// raw response body, and the key endpoints answer with sealed envelopes, so interpolating the
/// whole value would put payload bytes into a log file support asks users to send. The cases
/// enumerated below are all metadata by construction; everything else degrades to the error's
/// type plus its bridged domain/code rather than its description.
enum PhiSyncLog {
    static func describe(_ error: Error) -> String {
        switch error {
        case let error as KeyAPIError:
            switch error {
            case .http(let status, _): return "KeyAPIError.http(\(status))"
            case .transport(let underlying): return "KeyAPIError.transport(\(describe(underlying)))"
            case .decode: return "KeyAPIError.decode"
            case .lastActiveDevice: return "KeyAPIError.lastActiveDevice"
            }
        case let error as PhiSyncProtocolError:
            // Every case carries an HTTP status or a protocol enum, never content.
            return String(describing: error)
        case let error as CryptoKitError:
            return String(describing: error)
        case let error as ProfileKeyManagerError:
            return String(describing: error)
        default:
            let bridged = error as NSError
            return "\(type(of: error))(domain=\(bridged.domain) code=\(bridged.code))"
        }
    }
}

/// 配对向导第 2 步 Account 列的一行（R-D6-1）。**这是一次性的、只给 UI 看的东西，
/// 不是同步状态**。
struct PhiAccountSpaceSummary: Equatable, Sendable {
    let syncUuid: String
    let name: String
    let iconName: String
    let colorHex: String
    /// 账户级 profile uuid；默认 Space 为 `""`。
    let profileUuid: String
    /// 返回值里**恒为 false**：§4.3 第 6 条把账户里的默认 Space 整条丢掉了。保留这个
    /// 字段只为让那个过滤点在类型上可读，并让测试能直接断言它。
    let isDefault: Bool
    // D7 / R-D7-1：覆盖确认页比较的字段集比第 2 步的两列表多三个。第 2 步不渲染它们，
    // 确认页（§6.9）渲染由它们算出的账户侧值。一律保留**线上编码**，不在这里解释——
    // 归一化与显示是 `SpaceOverwriteDiff` 与视图的事，否则「什么算默认」要在两个地方
    // 各判一次。
    /// 线上 `theme_id`，`""` = 无主题 pin。
    let themeId: String
    /// 线上千分单位；**负数** = 无自定义透明度（本 build 发 -1，但落地那侧判的是 `< 0`）。
    let overlayOpacityLightMilli: Int64
    let overlayOpacityDarkMilli: Int64
}

enum PhiSpacePreviewError: Error, Equatable {
    /// 协调器手上没有引擎。
    case engineUnavailable
    case retired
    /// 页预算用尽，账户视图不完整。**不返回部分结果**。
    case truncated
    /// §4.5 的期限到了（`PhiSyncEngine.previewDeadlineMs`）。**期限必须在轮体里判**：
    /// 向导那一侧取消不掉这一轮（`serialized(_:)` 把它放进一个非结构化 `Task {}`），
    /// 所以只在向导里赛跑一个 `Task.sleep` 只能改变「报什么」，改变不了「什么时候
    /// 报」——分页拉取会一直跑下去，还继续占着 round 队列。
    case timedOut
    /// `PhiSyncLog.describe` 之后的元数据字符串（R12：不含任何载荷）。
    case transport(String)
}

// MARK: - 归属项（书签 / pin）的引擎接缝（M3-3 §5）
//
// 引擎对归属 kind 是**泛型**的：它按一张注册清单驱动一切，清单里有什么就跑什么。下面这
// 一组类型就是那张清单的元素与它进出的值。**没有任何一处提到书签或 pin**，除了文件末尾
// 那个把 `BookmarkKind` 绑上去的工厂。

/// 轮首算好一次的身份翻译表。
///
/// 它是 `OwnerResolver` 的**数据**版本。`OwnerResolver` 装的是闭包，而这些值要交给跑在
/// main actor 上的适配闭包，所以跨边界的那一份必须是纯值；两者的关系只有一条 `resolver`。
/// 纯函数模块因此也不必自己去够 `PhiSpaceSyncTable` 或映射表（`SyncableOwnedItems.swift` 的
/// 自述）。
struct OwnedOwnerMaps {
    var syncUuidBySpaceId: [String: String] = [:]
    var localSpaceIdBySyncUuid: [String: String] = [:]
    /// §4.2 规则 1 那三条判据的**合取**已经算好：在 `currentSpaces()` 里 ∧ 有 syncUuid ∧
    /// 该 Space 的游标既不 `hidden` 也没有 `purgedAtMs`。
    var eligibleSpaceUuids: Set<String> = []
    var globalUuidByProfileId: [String: String] = [:]
    var localProfileIdByGlobalUuid: [String: String] = [:]

    /// App 作用域的 pin 在 client tag 第三段与 `ownerUuid` 上写的字面量（§2.4 / §2.5）。
    /// 它不是一个 uuid，两张映射表里都没有它。
    static let appOwnerKey = "app"

    var resolver: OwnerResolver {
        let maps = self
        // **字面量 `"app"` 映射回它自己**（P1）。App 作用域的 pin 的归属就是这个字符串，
        // 而它不在任何一张映射表里：不映射的话 `SyncableOwnedItems` 的三处判据
        // （`plan` 的归属分类、`tombstones` 的「归属未映射」排除、`snapshot` 的合格性）
        // 都把它读成「解析不出来」——入站的 App 作用域 pin 永远停放，用户删掉的 App 作用域
        // pin 永远发不出 tombstone，在账户上不死，每台新设备加入都把它拉回来。
        //
        // **绝不在 `tombstones` 里特判这个字符串**：那条「归属解析不出来就跳过」的规则正是
        // §4.7 用来防「一次映射抖动删掉整个 Space 的书签」的，给它开例外等于在 pin 侧凿一
        // 个洞。修在解析器这一侧，规则本身一个字都不用动（CASE 4b.4b 是这条的探针）。
        //
        // 对书签是恒等变换：书签的归属是 Space uuid 或父身份，两者都产不出这三个字母。
        func selfMapped(_ uuid: String, _ table: [String: String]) -> String? {
            uuid == Self.appOwnerKey ? Self.appOwnerKey : table[uuid]
        }
        return OwnerResolver(
            syncUuid: { maps.syncUuidBySpaceId[$0] },
            // **`localSpaceId` 不映射**：映了的话 `"app"` 会被当成一个 Space 归属，于是
            // `isEligibleSpace` 那道只对 Space 有意义的闸会一刀切掉整类 App 作用域的 pin。
            localSpaceId: { maps.localSpaceIdBySyncUuid[$0] },
            isEligibleSpace: { $0 == Self.appOwnerKey || maps.eligibleSpaceUuids.contains($0) },
            globalUuid: { selfMapped($0, maps.globalUuidByProfileId) },
            localProfileId: { selfMapped($0, maps.localProfileIdByGlobalUuid) })
    }
}

/// 一轮出站快照的**类型擦除**形态：实体已经序列化成 `Phi_PhiEntity` 信封字节，所以这个
/// 结构不带 kind 的泛型参数。变更检测就是拿这些字节与游标的 `reconciled` 比（§4.2）。
struct OwnedSnapshotBytes {
    var entities: [String: Data] = [:]
    /// 身份 -> 这条本机行**当前所在的归属**（A12 / §3.5）。引擎每轮把它刷进游标的
    /// `ownerUuid`，差分的归属判据与保留期级联都只读那一个字段。
    var ownerUuids: [String: String] = [:]
    /// 本轮在内存里**铸出**候选身份的那些行：身份 -> 本机行 id。真正写进本机行是在提交被
    /// 接受之后（§6.4「铸造在提交那一刻」）。
    var minted: [String: String] = [:]
    var skippedUnmappedOwner = 0
    var skippedIneligibleOwner = 0
    /// 这份空快照是不是 §7.3 的「作用域不一致 ⇒ 发布半边整段跳过」的产物。**只有 pin 会置
    /// 它**（书签没有作用域这个概念）。它是那种轮次里唯一的诊断：一次纯 push 轮不跑 `plan`，
    /// 于是计数行上的 `scope_mismatch` 只能从这里来。
    var scopeMismatch = false
}

/// §9.3 的保留期级联问本机那两件事的答案，擦除了 kind。
///
/// **两件事必须分开交**，合成一张 `[String: String]` 是一条数据丢失路径：一条活行的归属
/// 此刻解析不出来（Space 映射抖动）时它仍然**有活行**，只是这一轮没有新归属可写；合成一张
/// 字典之后它读起来与「没有活行」一模一样，于是那条游标被删掉——而删掉一条活行的游标正是
/// A12 的 fail-safe 要防的那一件事（下一轮以 `baseVersion == 0` 的 create 盲写覆盖账户上
/// 那一条）。
struct OwnedLiveRows {
    /// 交进去的候选里，**本机还有活行认领**的那些身份。§9.3 判据 (b) 只读这一个集合。
    var claimed: Set<String> = []
    /// 上面那些身份里归属解析得出来的那些 -> 它**此刻所在的**归属，即 rehome 要写的值。
    var owners: [String: String] = [:]
}

/// `plan` 的入参，擦除了 kind：到达项是信封字节。
struct OwnedPlanInput {
    var arrivals: [(payload: Data, entityId: String, version: Int64)] = []
    var parked: [String: ParkedOwnedItem] = [:]
    var table = PhiOwnedItemTable()
    var maps = OwnedOwnerMaps()
    /// 本轮到达的 tombstone 身份 ∪ 表里还停着的 `pendingTombstone`。
    var tombstoned: Set<String> = []
    /// 本轮那一次时钟读数。适配层拿它按 §4.2 第 4 条给本机行的投影盖戳——入站合并的本机
    /// 那一侧必须是「这一轮的快照会发布的那一份」（`OwnedItemPlanContext.localProjections`），
    /// 而那份投影里**变过的字段盖 `now`**。
    var now: Int64 = 0
}

/// `plan` 的产出，外加只有适配层算得出的那几个计数。
struct OwnedPlanOutput {
    var plan = OwnedItemPlan(steps: [], parked: [:], refused: 0, lifted: 0,
                             supersededByDelete: 0, cancelledDeletes: [], harvest: [:])
    var adopted = 0
    var unmatchedFolders = 0
    var unmergeablePairs = 0
    /// 认领的合并结果里本机赢了字段的那些身份：**必须重新发布**。
    var mustRepublish: Set<String> = []
    /// §5.3 / §6.4 的**尽力而为的推迟**：本轮的 pull 里**收到过本 kind 实体**的那些归属。
    /// 这些归属下本轮新铸身份的行不进发布切片——它们在第一个没有该归属实体到达的轮次里提交。
    ///
    /// **它是优化，不是正确性规则**，而且不引入任何窗口状态：判据就是「这一轮这个归属有没有
    /// 到达过实体」，一个轮内的局部量，不落盘、不跨轮记忆（R-M3-3-22 / CASE 7.4）。
    /// 值的口径与 `OwnedSnapshotBytes.ownerUuids` 相同（书签是**这一行坐在哪个 Space**），
    /// 不是 `owners(_:)` 那个绑定引用——后者对一条子孙书签交出的是它的父。
    var deferredOwners: Set<String> = []
    var scopeMismatch = false
    /// 身份 -> 本轮**拉到的那一条远端实体**的信封字节。§4.5 的 `server = remote`，
    /// **永远不是 merge 结果**。
    var serverBytes: [String: Data] = [:]
}

struct OwnedLandingInput {
    var steps: [OwnedItemApplyStep] = []
    var table = PhiOwnedItemTable()
    var maps = OwnedOwnerMaps()
}

/// 一次落地的结果。三条出路**方向相反**，所以它们是三个集合而不是一个笼统的失败位
/// （CASE 6.10c-3）。
struct OwnedLandingOutcome {
    /// 真的落了地、并且通过了 §4.5 的落地后复核。只有这些身份可以写基线。
    var landed: Set<String> = []
    /// 归属被占（导入锁）或落地抛了别的错 ⇒ 停放，下一轮重试。
    var parked: Set<String> = []
    /// 这一批算错了（`.folderNotEmpty` / `.rowAlreadyMapped` / 物理行类型不符）⇒ 拒收，
    /// **不停放、不建游标**。
    var refused: Set<String> = []
    /// 身份 -> 落地之后要写进 `reconciled` 的字节（合并结果）。
    var reconciled: [String: Data] = [:]
    /// 被删掉的身份（远端 tombstone 落地）。
    var deleted: Set<String> = []
    /// §7.4 的半落地拆分对：身份 -> 它还在等的那条伙伴 lineage。引擎把它写进游标的
    /// `pendingPartnerLineage`，于是 §7.4 的表副本（`doctoredOwnedTable`）认得出「这一条
    /// 确实在等伙伴」并照抄基线，而不是把 `""` 发出去拆散对端那一半。
    ///
    /// **空值（`""`）是「不再等了」**：伙伴这一轮落地了，或者这条实体已经没有伙伴。引擎据此
    /// 清掉那一位。用 `nil`（不出现在字典里）表达不了这件事——不出现的含义是「本轮没这条
    /// 身份的消息」。书签没有拆分伙伴这个概念，那一侧这张字典恒空。
    var pendingPartnerLineages: [String: String] = [:]
    /// §7.2 / A11 的变体重铸本轮改了几行（`relineaged` 计数）。书签恒为 0。
    var relineaged = 0
    /// §8.2 / Task 10：本轮由落地**新建**出来、并且通过了落地后复核的那些本机行。
    ///
    /// 判据是「新建」而不是「读一次本机的 `favicon` 列」：同步载荷里根本没有 favicon 这个
    /// 字段，所以一条由落地新建的行**按构造**没有图标；认领 / 更新命中的是本机早就有的行，
    /// 它们自己的图标不该被一次回填盖掉。于是回填的投喂源不需要任何新的本机读。
    ///
    /// 书签那一侧填这个，pin 那一侧填 `createdPins`。
    var createdRows: [PhiLocalBookmark] = []
    /// §8.2 / Task 10 的 pin 半边。同一条判据（「本轮新建」⇒ 按构造没有图标）；spec §8.2
    /// 开头那句是「落地的书签**与 pin** 没有图标时」，所以两种 kind 都投喂。
    var createdPins: [PhiLocalPin] = []
}

/// 一次停放项重试的结果（§3 / R-exec-10）。
struct OwnedParkedClaimResult {
    /// 本轮 §6 的认领**配上**的身份，写回成没成都算。差分的 `pendingClaims` 豁免读它，
    /// 出站快照的「这一行本轮不铸新身份」也读它。
    var paired: Set<String> = []
    /// 真的把身份写回了本机行的那些。引擎清它们的 `pendingApply`。
    var persisted: Set<String> = []
}

/// §11.2 的一行。**一个**结构体，引擎按注册项各持一份；每条 kind 只填它有的字段，
/// 日志行也只印它有的字段。
struct OwnedRoundCounters {
    var pulled = 0
    var applied = 0
    var parked = 0
    var pushed = 0
    var tombstones = 0
    var adopted = 0
    var unmatchedFolders = 0
    var unmergeablePairs = 0
    var resurrected = 0
    var pendingPublish = 0
    var refused = 0
    var supersededByDelete = 0
    var rehomedCursors = 0
    var unreadable = 0
    var excludedUnmappedOwner = 0
    var localReadFailed = 0
    var relineaged = 0
    var scopeMismatch = false
}

/// 一条归属 kind 的注册项。引擎只认这个：它不知道有几种 kind，也不知道是哪几种。
///
/// 存在类型包装（`OwnedItemKind` 是带两个 associatedtype 的泛型协议，
/// `[any OwnedItemKind.Type]` 装不下它），实现上是一个**持闭包的 struct**：把 kind 的纯
/// 函数与它那一侧的本地访问各自绑好。触本机的闭包一律 `@MainActor`——两个访问协议都是
/// `@MainActor`，引擎照既有的 `spaceAccess` 一样 hop 过去。
///
/// **tag 索引不在这里**：注册项全是 `let`，装不下一张每轮都在长的表（随学随加，§5.1）。
/// 那张表是引擎自己的可变状态 `ownedTagIndices`。
struct OwnedKindRegistration {
    /// 日志与计数行的行名，注册清单里的唯一键，也是查 `ownedTableForTesting(_:)` /
    /// `lastOwnedRoundCountersForTesting` 的键。
    let label: String
    let tagPrefix: String
    let entityName: String
    let store: any PhiOwnedItemStateStore
    /// 该 kind 的 `…HadRecords` / `…ReplayedForEmptyTable` 两个标志在 `PhiSpaceSyncTable`
    /// 上的读写口（§3.5 的单副本裁定）。
    let flags: OwnedKindFlags
    /// 这条 kind 的计数行印不印认领那三项（`adopted` / `unmatched_folders` /
    /// `unmergeable_pairs`）。§11.2：只有书签行有，pin 完全不走 §6。
    let reportsAdoption: Bool
    /// 这条 kind 的计数行印不印 `relineaged` / `scope_mismatch`。
    let reportsScope: Bool

    // MARK: 纯函数（不隔离）

    /// 一份信封是不是本 kind 的载荷；是就交出它的身份，不是就 nil。
    let identity: (Phi_PhiEntity) -> String?
    /// 身份 -> client tag（`identity(of:)` 的逆），接收端 §2.5 校验与组批都用它。
    let clientTag: (String) -> String
    /// 一份信封字节里那条实体的归属引用（书签是父 / Space，pin 是 owner）。切片的拓扑序
    /// 与 tombstone 的反拓扑序都从它算深度。
    let owners: (Data) -> [String]
    /// §7.4 的「本机主动解除拆分」：把一批基线字节里的拆分伙伴清空，并**给清空后的那个值
    /// 盖上本轮的 `now`**（第二个参数）。第三个参数是轮首那份身份翻译表，与 `snapshot` /
    /// `tombstones` 收的是同一份——这条 kind 要拿它把基线的身份对回本机行。
    ///
    /// **成员本身是可选的**：`nil` = 这条 kind 没有拆分伙伴这个概念（书签），调用方连
    /// main actor 那一跳与整个循环都跳过。
    ///
    /// **收一批、回一批**，不是一条一条问：它触本机（要读本轮那份行快照），所以是
    /// `@MainActor`，而 `doctoredOwnedTable` 要遍历这条 kind 的**每一条**游标——逐条问就是
    /// 每条游标一次 actor 跃迁，书签账户上那是每轮几千次主线程跳转。收进来的是引擎按通用
    /// 规则筛过的候选（没有 `pendingPartnerLineage`、有基线），交回去的只有真的被改写的那几
    /// 条；不在返回值里的身份原样沿用基线。
    ///
    /// **时间戳必须在这里盖。** 盖戳函数（`PinKind.stamp`）分不出「表副本刚刚抹掉了一个真实
    /// 的伙伴」与「这条 pin 从来就没有伙伴」——两种情形到它手上都是「空投影对空基线」，于是
    /// 它按签名相等沿用基线的戳。发出去的 `("", t_基线)` 与对端手上的 `("<伙伴>", t_基线)`
    /// 戳相同，LWW 按字节序破平手，空串**输**，对端于是永远保留那条链接：用户每解除一次、
    /// 每同步一次又被拼回去，正是 §7.4 要防的那件事。
    ///
    /// **反过来，「不是解除的那些一个字节都不许动」同样是硬要求。** 一对两半都链好的拆分
    /// pin 的游标也没有 `pendingPartnerLineage`（伙伴早就落地了），清掉它的基线会让投影
    /// （带着伙伴）与基线（空）签名不同，于是那个字段每轮重盖一次 `now`、每轮重发一次，
    /// 两台设备互相看不出变化又各自重发，**每一条拆分 pin 每一轮都在发**，还吃掉 250 条的
    /// 发布预算。判据因此是「本机那一行还挂不挂着这条链接」，不是「游标有没有在等伙伴」。
    ///
    /// 判据要读本轮那份本机行快照，所以它**触本机**，与下面那一组同属 main actor。
    let clearedSplitPartners: (@MainActor ([String: Data], Int64, OwnedOwnerMaps)
        -> [String: Data])?

    // MARK: 触本机的（main actor）

    /// 轮首那一次读（`allBookmarks()` / `allPins()`）。**抛错 ⇒ R-exec-3**：本轮这条 kind
    /// 的快照、差分与发布整段不跑，游标表一个字节都不写。
    let beginRound: @MainActor () throws -> Void
    /// 本轮已经读到的那些身份，用来给 tag 索引播种（§5.1）。
    let localIdentities: @MainActor () -> Set<String>
    let snapshot: @MainActor (PhiOwnedItemTable, OwnedOwnerMaps, Int64) -> OwnedSnapshotBytes
    /// §4.7 的差分。**定义域问的是 `allSyncIds()` / `allPinRows()`**，不是快照
    /// （R-exec-4）；本轮没成功读过时它抛。
    let tombstones: @MainActor (PhiOwnedItemTable, OwnedOwnerMaps, Int64) throws
        -> OwnedItemTombstoneResult
    /// §3 的「每一轮开头都重试停放项」里归属项这一半（R-exec-10）：把还没能写回本机行的
    /// 那些身份重新认领一次，并把配上的那些立刻写回去。**每一种轮次都跑**——一次纯 push 轮
    /// （设置推送、本地变化）也会走到发布段，而发布段的铸造与差分都要先知道「这一行已经
    /// 配上了一个账户身份」。
    let retryParkedClaims: @MainActor ([String: ParkedOwnedItem], OwnedOwnerMaps) async
        -> OwnedParkedClaimResult
    let plan: @MainActor (OwnedPlanInput) -> OwnedPlanOutput
    let land: @MainActor (OwnedLandingInput) async -> OwnedLandingOutcome
    /// §6.4：提交被接受之后才把铸出来的身份写进本机行。返回真的写下去了的那些身份。
    let claimIdentities: @MainActor ([String: String]) async -> Set<String>

    /// §9.3 保留期级联在本机这一侧的唯一读口：收本轮命中判据 (a) 的那批候选身份，交回其中
    /// **本机还有活行认领**的那些（判据 (b)）以及它们此刻所在的归属（rehome 要写的值）。
    ///
    /// **为什么不复用已有的两个口。** `localIdentities` 在 pin 那一条按设计交空集合（身份的
    /// 后半段是账户级 ownerKey，那个闭包按接缝的形状拿不到本轮的解析器），拿它当判据 (b)
    /// 会把**每一条** pin 游标都判成「没有活行认领」而删掉。`snapshot` 则会为未同步行铸候选
    /// 身份，并在 pin 作用域不一致时整段交一份空快照——两件事在一次清理里都不该发生。
    ///
    /// **抛 ⇒ 这条 kind 的级联整段不跑**（R-exec-3 同一条）：一次读不出来与「本机一条行都
    /// 没有了」在值上同形，而后者的回答是删掉命中 (a) 的每一条游标。
    ///
    /// 判据 (b) 的定义域是 `allSyncIds()` / `allPinRows()`（**整库**那一次读），不是
    /// 快照（R-exec-4 / R-exec-8）：孤儿根下面的行、作用域迁移原地留下的备份行都不发布，但
    /// 它们是**活的本地行**，「同步层这一轮不认领它」与「账户应该忘掉它」是两句不同的话。
    let liveOwners: @MainActor (Set<String>, OwnedOwnerMaps) throws -> OwnedLiveRows
}

/// One round of Phi settings sync: pull (GetUpdates -> decrypt -> field-level LWW merge ->
/// apply) and push (snapshot -> encrypt -> Commit), plus the conflict retry and the
/// account-scoped cursor state both need.
///
/// An `actor`, but actor isolation alone does **not** serialize the rounds: Swift actors are
/// reentrant, so every `await` inside a round (the domain key, the network) lets the next
/// message in. The debounced local-change push, the periodic pull, the foreground pull and the
/// conflict retry all mutate the same persisted cursor and the same `UserDefaults` snapshot, so
/// the three public entry points chain onto `roundQueue` and run strictly one after another —
/// see `serialized(_:)`. `PhiDomainKeyManager` is only ever touched from in here.
///
/// Zero knowledge: settings are sealed with the account's PhiBrowser domain key
/// (`PhiEntityCodec` -> `PhiKeyCrypto` AES-GCM) before they reach the protocol client. The
/// field-level last-writer-wins timestamps live inside that ciphertext, so the server orders
/// nothing and reads nothing.
///
/// The engine is single-account and single-use: sign-out must call `shutdown()` (see
/// `PhiChromiumCoordinator.stopPhiSync()`), because dropping the reference alone leaves the
/// rounds already on `roundQueue` running against the shared `phi.sync.*` cursor that the next
/// account is about to claim.
actor PhiSyncEngine {
    // MARK: - Persisted state
    //
    // All account-scoped. The five in `stateKeys` (entity id, version, last entity, tombstone
    // rounds, `hasAdopted`) live in `UserDefaults.standard`, which is not — so account A's
    // entity version must never be replayed against account B. What enforces that is
    // `PhiChromiumCoordinator.resetPhiSyncCursorIfAccountChanged`, which compares the recorded
    // owner against the account being mounted and wipes these keys *before* the engine is
    // built. Sign-out itself only calls `shutdown()`: the cursor is left where it is and either
    // re-adopted by the same account or dropped by that owner check. (`resetSyncState()` below
    // performs the same wipe on demand, but nothing in the app calls it.)
    //
    // The progress marker and the store birthday are the exception as of M3-4a (§2.10 /
    // R-M3-4a-18): they live in the account directory's `sync/marker.json`, beside the
    // per-kind cursor tables, through `markerStore` — so a user-data import that replaces the
    // whole directory rolls the marker back together with the tables. Their two legacy keys
    // are still declared below (`legacyMarkerStateKeys`) because the one-time migration reads
    // them and the account-switch wipe clears them; the engine itself never reads or writes
    // them once a file store is injected.

    static let statePrefix = "phi.sync."
    /// Server-assigned entity id (`id_string`) for the settings entity.
    static let entityIdStateKey = statePrefix + "entityId"
    /// Version last seen for that entity; the `base_version` of the next commit.
    static let versionStateKey = statePrefix + "version"
    /// `store_birthday`, echoed back verbatim on every request once known.
    static let storeBirthdayStateKey = statePrefix + "storeBirthday"
    /// Opaque `DataTypeProgressMarker.token` for data type 2000.
    static let markerStateKey = statePrefix + "marker"
    /// Serialized `Phi_PhiSettingEntity` last known to be on the server. Also carries the keys
    /// this build does not know about, so a newer client's settings survive a round trip
    /// through this one.
    static let lastEntityStateKey = statePrefix + "lastEntity"
    /// Consecutive pulls that found the account's settings row tombstoned. Drives the heal
    /// below; persisted because a tombstone only this process happened to see twice is not
    /// evidence enough to re-create an account's settings.
    static let tombstoneRoundsStateKey = statePrefix + "tombstoneRounds"
    /// Set once this device has settings history for the account. Deliberately *not* part of
    /// the entity cursor: see `hasAdopted`.
    static let hasAdoptedStateKey = statePrefix + "hasAdopted"

    /// The cursor keys that still live in `UserDefaults`. `storeBirthdayStateKey` and
    /// `markerStateKey` left this list in M3-4a: the marker and the birthday are in the
    /// account directory's `marker.json` now, so `resetSyncState()` and the self-revocation
    /// delete that file instead of wiping keys for them.
    static let stateKeys = [entityIdStateKey, versionStateKey, lastEntityStateKey,
                            tombstoneRoundsStateKey, hasAdoptedStateKey]

    /// The two keys the marker and the birthday lived under before M3-4a. Not in `stateKeys`,
    /// but still on every *account-scope* wipe (`resetPhiSyncCursorIfAccountChanged`, the
    /// self-revocation): a machine whose one-time migration failed to write `marker.json`
    /// keeps these keys for the next launch, and an account switch in between must not let
    /// `PhiSyncMarkerMigration` carry the previous account's marker into the new account's
    /// file — the marker is an opaque per-account token, and requesting a delta with the
    /// wrong account's marker skips that account's history for good.
    static let legacyMarkerStateKeys = [storeBirthdayStateKey, markerStateKey]

    /// GetUpdates pages drained in one pull before the round gives up. 16 was enough for one
    /// settings entity; a first-time Space drain of a busy account is not. The budget still
    /// exists only to stop a pathological `changes_remaining` from spinning forever —
    /// exhausting it ends the ROUND, never the drain (§5.5 guard 1).
    private static let maxPullPages = 64

    /// A page-budget cut queues a follow-up round immediately instead of waiting out the 60 s
    /// timer; bounded so a misbehaving server cannot spin.
    private static let maxFollowUpRounds = 4

    /// Consecutive INVALID_MESSAGE rejections after which a tombstone is finalized anyway
    /// (§5.1). Same shape as `tombstoneHealAfterRounds`.
    private static let tombstoneRejectGiveUpRounds = 3

    /// R-exec-13：补键自愈连续被拒多少轮之后**不再重新武装**。与上面那条同一个数字、同一条
    /// 理由（一次瞬时失败不该定案，一条永远失败的条目不该每轮重发一遍），但放弃的动作完全
    /// 不同——见 `PhiOwnedItemCursor.rekeyRejectRounds`。
    private static let rekeyRejectGiveUpRounds = 3

    /// The server's `MaxCommitEntries` default is 500; batching well under it keeps one bad
    /// round small.
    private static let maxCommitEntriesPerBatch = 25

    /// Consecutive tombstone pulls after which the entity cursor is dropped so a later local
    /// change can re-create the row. Refusing to publish over a tombstone is right (the delete
    /// must not be undone by the device that merely noticed it), but the refusal is otherwise
    /// account-wide and permanent: the server keeps returning the tombstoned row on every
    /// replay (`internal/data/entities_read.go` FetchUpdates has no `deleted = false` filter,
    /// and `internal/chromiumsync/getupdates.go` toSyncEntity emits it with a non-empty
    /// `id_string`), so `.absent`'s self-heal never fires and every device parks its pushes
    /// forever. Requiring several rounds first keeps a fresh delete sticky; requiring an
    /// explicit local change afterwards (this only clears the cursor, it never publishes)
    /// keeps a deliberate deletion from being resurrected by a device that is merely polling.
    private static let tombstoneHealAfterRounds = 3

    private let domainKeys: any PhiDomainKeyProviding
    private let client: PhiSyncProtocolClient
    private let defaults: UserDefaults
    /// marker / birthday 的落点（M3-4a §2.10）。`init` 的 `markerStore` 为 nil 时回落成
    /// `DefaultsBackedPhiSyncMarkerStore(defaults:)`——读写两个旧键，只给测试与还没接线的
    /// 构造点用；生产的唯一构造点 `PhiChromiumCoordinator.buildPhiSyncEngine` 必传
    /// `FilePhiSyncMarkerStore`。引擎里只有这一条代码路径：两个访问器一律走它，没有 kind 分支。
    private let markerStore: any PhiSyncMarkerStore
    /// marker / birthday 的内存镜像：`load()` 只在 `init` 跑一次，之后 `storedMarker` /
    /// `storedBirthday` 的 get 读它，set 经 `persistMarkerState` 写穿、失败回滚。每次 get 读
    /// 一次文件会给一轮加上十几次磁盘读，而且一次瞬时读失败会被解读成「marker 为 nil」⇒
    /// 整类型重放。
    private var markerState: PhiSyncMarkerFile
    private let deviceKeyId: String
    private let settings: [SyncableSetting]
    private let now: () -> Int64

    /// The Space section (M3-2). Both are `nil` on a build or an account that has no Space
    /// sync at all, and every Space branch below is gated on them being present, so the M3-1
    /// settings path is byte-for-byte what it was.
    private let spaceAccess: (any PhiSpaceLocalAccess)?
    private let spaceStore: (any PhiSpaceSyncStateStore)?

    /// Mirror of the table's `spaceSectionEnabled`, kept in memory so the shut -> open EDGE is
    /// detectable inside one process too.
    private var spaceSectionEnabled = false

    /// 归属 kind 的注册清单（M3-3 §5）。空数组 = 这台机器 / 这个构建没有归属项同步，
    /// 下面每一个归属分支都在它为空时整段跳过，所以 M3-1 / M3-2 的行为逐字节不变。
    private let ownedKinds: [OwnedKindRegistration]

    /// §8.2 / Task 10：图标回填队列。nil = 这个引擎不回填（设置-only 的构建与绝大多数
    /// 用例）。
    ///
    /// **它对同步状态完全不可见**：favicon 不在快照里，回填那次写在 §5.7 的值快照去重那里
    /// 就被吃掉，所以它不碰游标、不写基线、不触发推送。引擎与它的关系只有两条——每轮末尾
    /// 投喂一次，`shutdown()` 时停。
    private let faviconBackfill: PhiFaviconBackfillQueue?

    /// 本轮新落地、要回填图标的行。**每轮清零**（`run`），轮末一次交给队列。两种 kind 各
    /// 一个篮子：队列按 kind 分开写回（两个 access 协议实例是两个写入口）。
    private var faviconCandidatesThisRound: [PhiLocalBookmark] = []
    private var faviconPinCandidatesThisRound: [PhiLocalPin] = []

    /// §5.8：配对预览的分页预算。它与拉取的 `maxPullPages` 分开，因为两种 kind 之后
    /// 一次预览要走过整个账户的书签与 pin 才能数清账户里有几个 Space。
    private let previewMaxPages: Int

    /// 上一条的默认值，**与 init 的默认实参同源**。拉取的 64 页 × 每页 500 条 = 32 000 条
    /// 实体，横跨全部 kind 并且把 tombstone 也算进去（M5 之前永不回收）；书签与 pin 落地
    /// 之后，一个普通账户就能在数清 Space 之前把它吃完，于是配对向导拿到的是一次
    /// `.truncated`。预览的预算因此单独放大到 400 页；真正封顶这次预览的是
    /// `previewDeadlineMs`，页预算只是兜底。
    static let defaultPreviewMaxPages = 400

    /// 最近一次预览的页数与实体数（§9.1）。`runPreview` **轮首清零、每一条出口都写它**，
    /// 所以它永远是最近那一次预览的计数，不会是上一次的残值。
    /// 只有这两个数字：没有它们，一次线上截断在日志里与一次网络失败无法区分，而
    /// `PhiSpacePreviewError.truncated` **不带载荷**（给它加 associated value 会同时改坏
    /// 向导与两个测试文件里既有的 `case .truncated`），所以计数走这条独立的只读接缝。
    private var lastPreviewStats: (pages: Int, entities: Int) = (0, 0)

    /// label -> (`client_tag_hash` -> 身份)。**随学随加**：每当一条带密文的实体被解密并
    /// 归位，它的身份立刻插进它那条 kind 的索引，同一次 drain 的后续页就能路由它的
    /// tombstone。每轮开头从游标表与本机身份重建，轮内只增不减。
    ///
    /// 写成注册项上的一个字段是行不通的——那个 struct 全是 `let`，而这张表每页都在长。
    private var ownedTagIndices: [String: [String: String]] = [:]

    /// label -> 这一轮该 kind 的游标表。轮首从 store 读一次、apply 段写回，发布段再读一次
    /// （CASE 6.26 的 `loseOnLoadNumber = 2` 数的就是这两次）。它同时是
    /// `ownedTableForTesting(_:)` 的数据源，所以那个只读访问器不会多打一次 `load`。
    private var ownedTables: [String: PhiOwnedItemTable] = [:]

    /// 本轮轮首读本机行抛错的那些 kind（R-exec-3）。它们的快照、差分、发布与落地整段不跑。
    private var ownedReadFailed: Set<String> = []

    /// 本轮每条注册 kind 的计数（§11.2）。
    private var ownedCounters: [String: OwnedRoundCounters] = [:]

    /// 本轮已经重试过停放项的 kind。一轮**一次**，在归属段的最前面——`pull` 与
    /// `pushOwnedItems` 都可能是第一个到达那里的。
    private var ownedParkedRetryDone: Set<String> = []

    /// 本轮已经跑过轮首的 kind。一轮至多一次 fetch（§5.7 第 2 条硬要求），而一轮里
    /// `pull` 与 `push` 都可能第一个到达轮首。
    private var ownedRoundStarted: Set<String> = []

    /// 本轮那份身份翻译表，算一次用到底（它是几次主 actor 往返）。
    private var ownedMapsThisRound: OwnedOwnerMaps?

    /// 认领的合并结果里本机赢了字段的那些身份（`OwnedItemAdoptionResult.mustRepublish`）。
    /// 本机赢了却不发布，对端永远停在旧值上，而两边都认为自己收敛了。
    private var ownedMustRepublish: [String: Set<String>] = [:]

    /// §5.3 的尽力推迟：本轮收到过该 kind 实体的那些归属（`OwnedPlanOutput.deferredOwners`）。
    ///
    /// **累加，不覆盖**：一轮里可以有不止一次 pull（`NOT_MY_BIRTHDAY` 的重来、发布前的那次
    /// 初始 pull、`.conflict` 的限定重试各带一次），而「这一轮这个归属有没有到达过实体」问的
    /// 是整轮的并集。每轮清零，**绝不落盘**——落盘的那一刻它就成了一个跨轮的窗口状态，而
    /// R-M3-3-22 明令这张表里不许有窗口。
    private var ownedDeferredOwners: [String: Set<String>] = [:]

    /// §3.6's per-round account profile refresh. `GET /keys/v1/profiles` is small, but App
    /// activation can fire `pullOnce()` far more often than the 60 s timer.
    private static let profileRefreshMinIntervalMs: Int64 = 30_000
    private var didRefreshProfilesThisRound = false
    private var lastProfileRefreshAtMs: Int64 = 0

    /// Follow-up rounds already queued after a page-budget cut, reset by the round that
    /// finally drains. Bounds `maxFollowUpRounds`.
    private var followUpRoundsUsed = 0

    /// Set around `SyncableSettings.apply` so a local-change notification raised by the engine's
    /// own write is not mistaken for a user edit. The load-bearing echo suppression is the
    /// `<key>.phiSyncTs` / `<key>.phiSyncVal` sidecars `apply` maintains; this flag only closes
    /// the window while the write is in flight.
    private var isApplyingRemote = false

    /// No invalidation channel exists yet: only a completed pull in this serialized round
    /// permits publication. Every new pull revokes that permission, including conflict pulls,
    /// so a failed retry cannot leave later entity kinds publishing against stale state.
    private var canPublishThisRound = false

    // ── B-2 的轮级状态（M3-4a Task 2b，§2.5 / §2.8）。全部在 `run(_:)` 的复位段清零。──
    //
    // `cursorSaveFailures` 是 §2.5 第 4 条那个布尔的计数形态：四个置位点全在**写口内部**
    // （`writeSpaceTable` / `writeOwnedTable` / `persistMarkerState` 的 `false` 支，以及
    // `applySpaces` create 支里 `mapSpace` 抛 `persistFailed` 的那个 catch），不在调用点。
    // 它同时是发布闸的第三个合取项（R-M3-4a-88 / 92）：本轮任何一次游标落盘失败 ⇒ 零发布。
    private var cursorSaveFailures = 0
    /// §2.8 的具名结局。`pull` 自己只写五个（`.cursorSaveFailed` / `.pullFailed` /
    /// `.unusableSettings` / `.pageBudgetExhausted` / `.notMyBirthday`），其余三个由结局行
    /// 发射前按固定优先级派生。一轮里多次 pull 时后写覆盖先写。
    private var roundOutcome: RoundOutcome = .ok
    /// 本轮取回的页数，跨同一轮内的多次 pull 累加。
    private var roundPages = 0
    /// 「**盘上**那个 marker 本轮动过」：只在 `persistStoredMarker` 成功之后按
    /// `storedMarker != markerAtEntry` 置真（计划裁定 7）。
    private var roundMarkerAdvanced = false
    /// 结局行**发射时**写下的那一份快照；轮首不清（`nil` 只表示「这个引擎还没跑完过一轮」）。
    /// 快照而不是活值：一次 `page_budget_exhausted` 会把跟进轮排进队列，而跟进轮的
    /// `run(_:)` 一进门就把四个活计数清零——测试接缝读活值会读到下一轮的残值。
    private var lastLoggedRound: LoggedRound?

    /// 结局行的四个字段，原样冻结。
    struct LoggedRound {
        let outcome: RoundOutcome
        let pages: Int
        let markerAdvanced: Bool
        let cursorSaveFailures: Int
    }

    /// Tail of the round chain. Each public entry point appends its round to this task and
    /// awaits it, so a round that suspends in `getUpdates` or `commit` still finishes before
    /// the next one starts. Only the public entry points enqueue: the internal `pull` -> `push`
    /// and conflict `push` -> `pull` -> `push` calls run inside an already-queued round and
    /// would deadlock if they queued again.
    private var roundQueue: Task<Void, Never>?

    // MARK: - Shutdown

    /// One-way "this engine is retired" flag, set by `shutdown()` on sign-out / account
    /// switch. From then on no queued round runs, a round already in flight unwinds without
    /// writing anything, and no remote settings are applied.
    ///
    /// It lives in a lock-protected box rather than in actor state so `shutdown()` can be
    /// `nonisolated` and take effect *synchronously*. The sign-out path runs on the main
    /// actor while a round may be parked inside `getUpdates` (URLSession's default timeout is
    /// 60 s) with a debounced push chained behind it; an `await engine.shutdown()` would be
    /// just another message to a reentrant actor, with no ordering against that round's
    /// resumption. With the box, the moment `PhiChromiumCoordinator.stopPhiSync()` returns the
    /// dying round can no longer touch the shared `phi.sync.*` cursor — which the next account
    /// is about to reset and claim in the same `UserDefaults`.
    private final class StopSignal: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false

        var isStopped: Bool {
            lock.lock()
            defer { lock.unlock() }
            return stopped
        }

        func stop() {
            lock.lock()
            stopped = true
            lock.unlock()
        }
    }

    private let stopSignal = StopSignal()
    private var isStopped: Bool { stopSignal.isStopped }

    /// Retires the engine for good: rounds queued behind an in-flight one never run, and the
    /// round already in flight skips every write it has left — the account-scoped cursor
    /// (`writeState`), the settings themselves and their `<key>.phiSync*` sidecars
    /// (`writeSettings` / `snapshotLocalSettings`).
    ///
    /// The exact guarantee, because `shutdown()` is genuinely concurrent with the round (it runs
    /// on the main actor at sign-out while the round runs on the actor's executor): the flag is
    /// read immediately before each of those writes, not only at the round's entry, so what a
    /// shutdown landing at the worst possible moment can still miss is one flag read rather than
    /// a whole round. Concretely, two things may still happen after `shutdown()` returns — a
    /// round that had just passed one of those checks completes that single write, and a commit
    /// already encrypted and handed to the transport still reaches the server (nothing it
    /// answers is persisted; the post-commit writes are checked again). Neither is harmful: at
    /// the instant `shutdown()` returns the account being torn down is still the mounted one, so
    /// those bytes are its own, and the sidecars are not account-scoped in the first place. What
    /// the guarantee rules out is the thing that matters — a round resuming *after* the next
    /// account has mounted and claiming its cursor or its settings.
    ///
    /// Idempotent, and deliberately not reversible — a new sign-in builds a new engine.
    nonisolated func shutdown() {
        stopSignal.stop()
        // §8.2 / Task 10：回填与引擎同生命周期。它自己的退休位也住在一个锁盒子里，所以这
        // 一跳是同步的——退出账户那条主线程路径上等不起一次 actor hop。
        faviconBackfill?.stop()
    }

    /// 结果的一次性信箱（§4.3）。`final class` 而不是 `inout`：它要跨 `Task` 边界。
    final class PreviewBox {
        var result: Result<[PhiAccountSpaceSummary], PhiSpacePreviewError>?
    }

    /// What one queued round does. An enum rather than a closure so the body stays
    /// actor-isolated and needs no `@Sendable` gymnastics.
    private enum Round {
        case pull
        case push
        case localChange
        case localSpaceChange
        /// The Space gate's shut <-> open edge. Queued like every other round rather than
        /// applied in place, so it can never land *inside* a round that is parked in
        /// `getUpdates` — see `setSpaceSyncEnabled`.
        case spaceGate(Bool)
        /// §5.3: EVERY Space intent the main-thread facade delivers is a round.
        /// Running one "in place on the engine actor" is not exclusion — the
        /// engine is a reentrant actor, and the two long Space writers
        /// (`pull`'s apply section and `pushSpaces`) each hold one table copy
        /// across a main-actor hop or a whole network round trip and blind-write
        /// it back. An intent that lands inside either window is silently
        /// overwritten, which for `recordLocalDeletion` means the tombstone is
        /// never committed and the Space is later resurrected from a peer's
        /// entity. The queue is the only thing that makes the single writer real.
        case retentionSweep
        case recordLocalDeletion(String)
        /// 一条归属 kind 的本地变化（M3-3 §5.7）。载荷是注册项的 `label`——**kind 是数据
        /// 不是代码**，所以这里是一个 case 而不是每种 kind 一个。
        ///
        /// **归属项没有 `.recordLocal…Deletion`**（R-M3-3-5）：删除起源是 §4.7 的差分而不是
        /// 钩子。M3-4 若真给书签或 pin 加一条删除钩子（例如让一次 `deleteSpaceCascade`
        /// 立刻发 tombstone 而不必等下一轮差分），那个入口**必须**是一个排进 `roundQueue`
        /// 的 Round，而不是一次普通的 actor 方法调用：一个在轮次挂起窗口里落地的意图会被
        /// 盲写覆盖，`pendingDelete` 就此永久丢失（M3-2 §5.3 的整段论证）。
        case localOwnedChange(String)
        /// 配对向导的只读账户预览（R-D6-1）。排同一条队列，所以它不可能与一轮设置
        /// 同步交错。
        case preview(PreviewBox)
    }

    init(domainKeys: any PhiDomainKeyProviding,
         client: PhiSyncProtocolClient,
         defaults: UserDefaults,
         deviceKeyId: String,
         settings: [SyncableSetting] = SyncableSettings.all,
         spaceAccess: (any PhiSpaceLocalAccess)? = nil,
         spaceStore: (any PhiSpaceSyncStateStore)? = nil,
         markerStore: (any PhiSyncMarkerStore)? = nil,
         ownedKinds: [OwnedKindRegistration] = [],
         faviconBackfill: PhiFaviconBackfillQueue? = nil,
         previewMaxPages: Int = PhiSyncEngine.defaultPreviewMaxPages,
         now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.domainKeys = domainKeys
        self.client = client
        self.defaults = defaults
        self.deviceKeyId = deviceKeyId
        self.settings = settings
        self.spaceAccess = spaceAccess
        self.spaceStore = spaceStore
        self.ownedKinds = ownedKinds
        self.faviconBackfill = faviconBackfill
        self.previewMaxPages = previewMaxPages
        self.now = now
        // nil ⇒ 回落到两个旧键（见 `markerStore` 的属性注释），不是内存 store、也不是引擎里
        // 留一条 `if markerStore == nil` 的旧分支。镜像必须在任何一轮之前就位。
        let resolvedMarkerStore: any PhiSyncMarkerStore =
            markerStore ?? DefaultsBackedPhiSyncMarkerStore(defaults: defaults)
        self.markerStore = resolvedMarkerStore
        self.markerState = resolvedMarkerStore.load()
        self.spaceSectionEnabled = spaceStore?.load().spaceSectionEnabled ?? false
    }

    // MARK: - Public surface

    /// GetUpdates -> decrypt -> merge -> apply, then publish anything the merge left the
    /// server behind on. Never throws: a failed round is logged and retried by the scheduler.
    func pullOnce() async {
        await serialized(.pull)
    }

    /// GetUpdates -> merge -> snapshot -> Commit, with one pull-and-retry on CONFLICT.
    func pushLocalSettings() async {
        await serialized(.push)
    }

    /// Entry point for the debounced `UserDefaults.didChangeNotification` observer.
    func handleLocalDefaultsChange() async {
        await serialized(.localChange)
    }

    /// The Space section's gate (§3.5): account bound AND ARK unlocked AND the join-time
    /// pairing is finished. Driven by the coordinator, NOT by `needsPairing` — §3.6's
    /// auto-create makes that predicate flip true for a moment every time the account gains a
    /// profile, and hanging the gate on it would drop the shared marker and replay the whole
    /// data type each time.
    ///
    /// Queued through `serialized(_:)`, and that is not a detail: the engine is a reentrant
    /// actor, so a gate open awaited from the coordinator while a round is parked in
    /// `getUpdates` would otherwise land in the middle of that round — after it read the Space
    /// table and before it writes anything back — and the round would carry on with a stale
    /// `spaceLive` and re-establish the very marker this edge just dropped. Running it as a
    /// round means the edge happens strictly between rounds: the replay it arms is the next
    /// round's to perform.
    ///
    /// Must therefore be called from *outside* a round (the coordinator is the only caller);
    /// calling it from inside one would wait on the queue that round is holding. A redundant
    /// call is a no-op at the edge check inside the round, but it still queues behind whatever
    /// is in flight, so the coordinator should keep driving it on real state changes only.
    func setSpaceSyncEnabled(_ enabled: Bool) async {
        guard spaceStore != nil else { return }
        await serialized(.spaceGate(enabled))
    }

    /// 配对向导第 2 步的 Account 列（R-D6-1）。
    ///
    /// **它持久化的东西是：没有。** 不写 `storedMarker`、不写 `storedBirthday`、不建
    /// 也不改任何游标、不写任何基线、不动 `unreadableTagHashes`、不动
    /// `hasDrainedFullReplay` / `drainInProgress` / `hadRecords` /
    /// `didReplayForEmptyTable`、不写映射、不 commit 任何东西。它不是 `push`，
    /// `pushSpaces` 的四道守卫一处都没碰。`run(_:)` 的这一支还**提前返回**，所以
    /// §11 的 `logSpaceRound()` 也不跑：预览不是一轮 Space，不该在计数行里留下一条
    /// 全零记录，也不该为此多两次主 actor 往返。
    ///
    /// **它也不看 `spaceSectionEnabled`。** 这是唯一一条允许在门关着时执行的 Space
    /// 形状的读，允许的理由恰恰是「它什么都不写」。
    ///
    /// 拿到的东西是一次性的、只给 UI 看的，**不是同步状态**：它从不推进共享 marker，
    /// 所以门开边沿仍然会丢一次 marker 并重放整个 data type，账户里每一条 Space 都会
    /// 在门开后再走一遍正式路径。
    func previewAccountSpaces() async -> Result<[PhiAccountSpaceSummary], PhiSpacePreviewError> {
        let box = PreviewBox()
        await serialized(.preview(box))
        return box.result ?? .failure(.retired)
    }

    /// §4.5 的期限，**判在轮体里**（`runPreview` 的分页循环），不是只判在向导里。
    ///
    /// 向导那一侧的赛跑管不住这一轮：`serialized(_:)` 把轮体放进一个**非结构化**
    /// `Task {}`，它既不继承取消，`await task.value`（非 throwing Task）也不会因为
    /// 调用方被取消而提前返回。所以没有这个预算，一次抖动的网络会让预览按
    /// 「`previewMaxPages` 页 × URLSession 每请求 60 s」跑下去，并且一直占着 round
    /// 队列，把设置同步一起拖住。向导侧仍然有自己的硬期限（见
    /// `PairingWizardViewModel.loadAccountSpaces`），两者取值相同：那一条保证**界面**
    /// 不卡，这一条保证**工作**真的停下来。
    ///
    /// **它才是真正封顶一次预览的那个数**：`defaultPreviewMaxPages` 放大到 400 页之后，
    /// 一个慢账户会先撞上期限、而不是先撞上页预算。120 s 是「大账户也数得完」与「卡住的
    /// 网络不会一直占着 round 队列」之间的取值；向导的加载页为此有一条明说要等多久的
    /// 进度文案。
    static let previewDeadlineMs: Int64 = 120_000

    /// The gate edge itself. Runs as a queued round; never call it directly.
    private func applySpaceGate(_ enabled: Bool) {
        guard enabled != spaceSectionEnabled else { return }
        spaceSectionEnabled = enabled
        mutateSpaceTable { table in
            table.spaceSectionEnabled = enabled
            // Two triggers, one action. `markerMovedWhileGateShut` covers every shut episode this
            // build observed. `!hasDrainedFullReplay` covers the one it could not observe: the
            // M3-1 -> M3-2 UPGRADE, where the device already holds a non-nil `phi.sync.marker`
            // from months of settings sync, an empty `sync.phiSpaces` (so `hadRecords == false`
            // and guard 2's second trigger is disabled too), and no flag was ever set because the
            // flag did not exist. Without this disjunct nothing ever drops that marker: the pull
            // never sees `storedMarker == nil`, so `drainInProgress` is never armed,
            // `hasDrainedFullReplay` stays false forever, `pushSpaces` returns at its own guard,
            // and the device silently never publishes a single Space.
            // Idempotent: once a drain completes, only a real shut episode re-arms it.
            if enabled, table.markerMovedWhileGateShut || !table.hasDrainedFullReplay {
                // Both kinds share ONE progress marker for data type 2000, so every Space entity
                // the settings pulls walked past while the gate was shut will never be delivered
                // again. Replay the type, and re-arm guard 1 so nothing is committed until the
                // replay finishes.
                AppLogInfo("[phi-sync] space gate opened (marker_moved=\(table.markerMovedWhileGateShut) drained=\(table.hasDrainedFullReplay)); replaying data type \(PhiSyncEntity.dataTypeID)")
                storedMarker = nil
                table.markerMovedWhileGateShut = false
                table.hasDrainedFullReplay = false
                table.drainInProgress = true
                // Deliberately untouched: reconciled / server / entityId / version / hidden /
                // deletedAtMs / purgedAtMs. The ACCOUNT did not change; clearing them would
                // re-arm the wholesale adopt and silently drop local edits that were just
                // stamped.
            }
        }
    }

    /// Entry point for the debounced `spacesPublisher()` / `.spaceThemeDidChange` observers
    /// (§5.4). Same shape as `handleLocalDefaultsChange()`.
    func handleLocalSpacesChange() async {
        await serialized(.localSpaceChange)
    }

    /// Entry point for the debounced `bookmarkChangesPublisher()` /
    /// `pinnedTabChangesPublisher()` observers (§5.7). Same shape as
    /// `handleLocalSpacesChange()`, one line down to `serialized`.
    ///
    /// `label` is a registration's `label` — the unique key of the owned-kind list — and it
    /// travels no further than the round's log line: the publish section walks the whole
    /// registration list, so one kind's local change is an ordinary push round. It is a
    /// parameter rather than two methods because **kind is data, not code** (`Round`'s own
    /// `localOwnedChange` comment).
    ///
    /// Must be called from *outside* a round, like every other driver here: it waits on the
    /// queue the round in flight is holding.
    func handleLocalOwnedChange(label: String) async {
        await serialized(.localOwnedChange(label))
    }

    /// Delivered by `PhiSpaceSyncState.shared` and executed as a QUEUED ROUND --
    /// the table has exactly one writer (§5.3: "全部 async, 全部排进同一条
    /// roundQueue").
    ///
    /// Running the read-modify-write "on the engine actor" is not enough, and
    /// the failure is the one §5.3 names: a round reads the table, the user
    /// deletes a Space during one of that round's suspensions, and the round
    /// then writes its pre-delete copy back. `pushSpaces` holds its copy across
    /// `client.commit` (a full network round trip) and `pull`'s apply section
    /// holds one across every landing's main-actor hop, so the window is wide
    /// and ordinary. The lost `pendingDelete` is permanent and silent: the uuid
    /// never enters `spaceCommitEntries`' union again, no tombstone is ever
    /// committed, and with no `deletedAtMs` on the cursor the anti-resurrection
    /// guard cannot fire either -- the next delivery of that entity re-creates
    /// the Space the user deleted.
    ///
    /// Must be called from *outside* a round, like `setSpaceSyncEnabled`.
    func recordLocalDeletion(spaceId: String) async {
        await serialized(.recordLocalDeletion(spaceId))
    }

    func runRetentionSweep() async {
        await serialized(.retentionSweep)
    }

    /// §9.2's 30-day sweep over expired soft deletes. Runs as a queued round
    /// (`case .retentionSweep`); never call it directly.
    ///
    /// Two phases, and the split is the point. `purgeExpired` trims the table
    /// and is persisted BEFORE any `await`; only then does the data cascade run.
    ///
    /// The straight version -- load the table, trim it, `await spaceAccess.purge`
    /// in a loop, write the trimmed copy back -- is a lost update: every `purge`
    /// is a main-actor hop, i.e. an actor suspension point, and the round queued
    /// behind it does its own read-modify-write of the same table. The final
    /// `writeSpaceTable` would then put back a snapshot taken before that round
    /// existed. This is exactly what §5.3's single-writer rule is for, so the
    /// sweep runs as a round AND keeps no stale copy across a suspension.
    private func applyRetentionSweep() async {
        await applySpaceRetentionSweep()
        // §3.6 的 tombstone 游标丢弃，**排在级联之前**：一条已经到期的游标不该再进级联的
        // 候选集，那只会让同一条记录被两段逻辑各判一次。
        await dropExpiredOwnedTombstones()
        // §9.3 的游标级联，**每一次清理轮都跑，与上面这趟有没有清出东西无关**。它不是
        // `applySpaceRetentionSweep` 的尾巴：那一趟的 `expired` 是「这一次**新**清理掉的
        // uuid」，而 `purgeExpired` 在 phase 1 就盖上 `purgedAtMs` 并立刻落盘、它自己的守卫
        // 又是 `purgedAtMs == nil`，所以一个 uuid **再也不会被返回第二次**。把级联挂在那份
        // 返回值上，一次「数据删成功、游标文件写失败」就永久留下一批孤儿游标——而 §11.4
        // 明说游标文件写失败**不重试**。幂等重算一遍不需要任何新状态。
        await applyOwnedRetentionCascade()
    }

    /// 上面那两段说的 Space 那一半：`purgeExpired` + 数据级联。
    private func applySpaceRetentionSweep() async {
        guard let spaceAccess, spaceStore != nil else { return }
        var table = loadSpaceTable()
        let expired = table.purgeExpired(nowMs: now())
        guard !expired.isEmpty else { return }
        // Phase 1: persist the trimmed table with no suspension in between. The
        // cursors are now permanent tombstones -- §9.1's two promises (a
        // replayed tombstone is a no-op, snapshot never resurrects the uuid)
        // rest on the cursor being there with a `deletedAtMs`, so they hold even
        // if the cascade below is interrupted.
        writeSpaceTable(table)

        // Phase 2: cascade the data. No table copy is held across these awaits.
        for uuid in expired {
            guard !isStopped else { return }
            // D6：`purgeExpired` 返回的是 syncUuid，`purge` 收的是本地 id。解析不到
            // ⇒ 无事可做（本机本来就没有这条），游标留下的 tombstone 已经在 Phase 1
            // 写好了。
            guard let local = await spaceAccess.localSpaceId(forSyncUuid: uuid) else { continue }
            do {
                try await spaceAccess.purge(spaceId: local)
                // **purge 成功之后**才删映射行；游标留下（它是永久 tombstone 记录，
                // 这一点只有在按 syncUuid 键时才自洽）。
                await spaceAccess.dropSpaceMapping(forSpaceId: local)
            } catch {
                // 级联失败 ⇒ **映射必须留着**（R12：只记 describe 出来的那一串）。
                // 无条件删掉是一条复活路径：`currentSpaces()` 直读本地行、不经
                // `hiddenSpaceIds` 过滤，那条还在盘上的行会进下一趟 `pushSpaces`，
                // 懒铸造给它铸一个**全新的** syncUuid，账户里因此多出一条谁也合不掉
                // 的 Space；而 Phase 1 已经盖上 `purgedAtMs`，清理不会再来第二次。
                // 留着映射就留住了「syncUuid → 已 tombstone 的游标」这条链，
                // `snapshot` 的 eligible 过滤照旧把它排除在外。
                AppLogWarn("[phi-sync] retention purge failed; keeping the mapping so the row cannot be republished (\(PhiSyncLog.describe(error)))")
            }
        }
    }

    /// §3.6：删除定案满 30 天的 tombstone 游标整条丢弃，两条 kind 都过一趟。
    ///
    /// 丢弃为什么安全，论证在 `PhiOwnedItemTable.dropExpiredTombstones` 上（服务端每个
    /// `entity_id` 只有一行且只下发最新版本，所以一条身份被再次投递时投到的要么仍是那条
    /// tombstone、要么是一次更新的复活，两种在没有游标时的结论都与有游标时逐字一样）。
    /// 这里只负责**什么时候**跑它：`.retentionSweep` 是唯一一种「与任何实体流动无关、纯粹
    /// 按时间收尾」的轮次，Space 侧的 30 天清理也在这一轮。
    ///
    /// **不看 `ownedReadFailed`**：判据只有游标自己的 `deletedAtMs` 与本轮的 `now`，一次
    /// 本机读失败改变不了其中任何一个。`beginOwnedRound()` 在读抛错之前就已经把游标表载进
    /// `ownedTables` 了，所以这一趟照常成立。
    private func dropExpiredOwnedTombstones() async {
        // 与归属段的其余部分同一道门（`ownedItemsPublishAllowed` / `pushOwnedItems` / 落地段
        // 的 `spaceLive`）。门关着时这一趟不可能有产出——没有任何一轮写过游标表，所以也没有
        // 到期的 tombstone 可丢——而 `beginOwnedRound()` 是一整趟主线程书签树读 + pin 读。
        // 关着门的用户因此不必为一次必然空转的清理付这个代价。判据只有游标自己的
        // `deletedAtMs` 与 `now`，都不随门开关变化：门再开时下一趟清理轮照常把它们丢掉。
        guard spaceSectionEnabled, !ownedKinds.isEmpty, spaceStore != nil else { return }
        await beginOwnedRound()
        let nowMs = now()
        for registration in ownedKinds {
            guard !isStopped else { return }
            var table = ownedTables[registration.label] ?? PhiOwnedItemTable()
            let before = table.cursors.count
            table.dropExpiredTombstones(nowMs: nowMs)
            let dropped = before - table.cursors.count
            guard dropped > 0 else { continue }
            // R12：只记 kind 与条数。
            AppLogInfo("[phi-sync] expired tombstone cursors dropped "
                       + "kind=\(registration.label) dropped=\(dropped)")
            writeOwnedTable(registration, table)
        }
    }

    /// §9.3：一个 Space 被 30 天清理掉之后，把两张归属项表里指着它的游标级联处理掉。
    ///
    /// **幂等，每次清理轮重算一遍，并且对活行 fail-safe**（E11 + A12）。两条判据**都**成立
    /// 才删一条游标：
    ///
    /// - (a) 它的 `ownerUuid` 指向的那个 Space 的 Space 游标带 `purgedAtMs`；
    /// - (b) **没有任何活的本地行认领这条身份**。
    ///
    /// 不级联的后果：那些游标成为「有基线、无本地行」的孤儿，而 §4.7 的差分把它们**全部
    /// 判成本地删除**并发出一批 tombstone——删的是账户上别人可能还需要的实体。
    ///
    /// (b) 是 A12 的 fail-safe。`ownerUuid` 在门关着、drain 未完、pin 作用域不一致这几种
    /// 情况下会落后于本地行（它的刷新在发布段的 pre-pass 里），而删掉一条**活行**的游标
    /// 等于让那条行此后被差分判成从未发布过，下一轮以 `baseVersion == 0` 的 create 盲写
    /// 覆盖账户上那一条——服务端的 `ON CONFLICT (client_tag_hash) DO UPDATE` 没有版本检查。
    /// 命中 (a) 但违反 (b) ⇒ **不删**，就地把 `ownerUuid` 按本地行改写并计一次
    /// `rehomed_cursors`，把一整类「级联键过期」从账户级覆盖降级成一条日志。
    ///
    /// 判据只读游标上那一个字段，所以它不必把几千条基线解码一遍，也不会读到一个过期的
    /// Space：`reconciled` 在「行改了 Space 而发布还排在切片后面」的窗口里是旧值，而
    /// `ownerUuid` 每一轮 snapshot 的预处理都为表里每一条**在本机有对应行**的游标刷新一次
    /// （N3 / I9 / R-exec-8）。
    private func applyOwnedRetentionCascade() async {
        // 同上那道门。门关着时候选集恒为空：判据 (a) 要求 `purgedAtMs != nil`，而 Space 那
        // 半趟清理自己就卡在 `guard let spaceAccess` 上、从来没有清掉过任何一个 Space。
        guard spaceSectionEnabled, !ownedKinds.isEmpty, spaceStore != nil else { return }
        // 轮首那一次本机读 + 游标表读。它自己按 kind 记 `ownedReadFailed`（R-exec-3），
        // 一轮至多跑一次，所以这里与别的轮次共用同一个入口而不是自己再读一遍。
        await beginOwnedRound()
        let spaceTable = loadSpaceTable()
        let maps = await ownedRoundMaps()
        for registration in ownedKinds {
            guard !isStopped else { return }
            guard !ownedReadFailed.contains(registration.label) else { continue }
            var table = ownedTables[registration.label] ?? PhiOwnedItemTable()
            // (a)。`ownerUuid == nil` 的游标不进候选：它要么是一条账户上有、本机从没有过
            // 行的实体（归属永远解析不出来），要么是刚建出来还没被发布段刷过归属的——两种
            // 都没有「指向一个被清理掉的 Space」这回事。
            let candidates = Set(table.cursors.compactMap { identity, cursor -> String? in
                guard let owner = cursor.ownerUuid,
                      spaceTable.cursors[owner]?.purgedAtMs != nil else { return nil }
                return identity
            })
            guard !candidates.isEmpty else { continue }
            let live: OwnedLiveRows
            do {
                live = try await registration.liveOwners(candidates, maps)
            } catch {
                // 读不出来 ⇒ 这条 kind 这一轮整段不跑。下一次清理轮重算，判据没有任何
                // 一次性状态。
                AppLogWarn("[phi-sync] retention cascade skipped kind=\(registration.label): "
                           + "the local rows could not be read (\(PhiSyncLog.describe(error)))")
                continue
            }
            // 两个**本地**增量，不读 `counters.rehomedCursors` 的既有值：那一项在别的轮次
            // 里由发布段写，拿它当「这一趟有没有改过东西」的判据会在一轮里既发布又清理时
            // 多写一次盘。
            var dropped = 0
            var rehomed = 0
            for identity in candidates.sorted() {
                guard live.claimed.contains(identity) else {
                    table.cursors.removeValue(forKey: identity)
                    dropped += 1
                    continue
                }
                // (b) 违反 ⇒ 不删。归属这一轮解析不出来时连改写也不做：保留上一次已知的
                // 归属，下一轮重算——把它刷成一个猜测值会让差分的 tombstone 判据读到一条
                // 本机从没成立过的归属。
                guard let current = live.owners[identity],
                      table.cursors[identity]?.ownerUuid != current else { continue }
                table.cursors[identity]?.ownerUuid = current
                rehomed += 1
            }
            var counters = ownedCounters[registration.label] ?? OwnedRoundCounters()
            counters.rehomedCursors += rehomed
            ownedCounters[registration.label] = counters
            guard dropped > 0 || rehomed > 0 else { continue }
            // R12：只记 kind 与条数。写一律走 `writeOwnedTable`（`guard !isStopped` + 两个
            // per-kind 标志的维护都在那里），绝不直接 `store.save`。
            AppLogInfo("[phi-sync] retention cascade kind=\(registration.label) "
                       + "dropped=\(dropped) rehomed=\(rehomed)")
            writeOwnedTable(registration, table)
        }
    }

    /// Drops every account-scoped cursor, `hasAdopted` included, so the next account's entity
    /// is adopted rather than merged against the previous account's timestamps. As of M3-4a
    /// that is the five `stateKeys` *and* the marker file: the marker and the birthday live in
    /// `marker.json` (§2.10), and "every account-scoped cursor" has to stay true, so the file
    /// is deleted here — deleted, not saved empty, the same contract as the self-revocation.
    ///
    /// **Test and recovery helper — the app never calls this.** The account-scope reset that
    /// actually ships runs one layer up, in
    /// `PhiChromiumCoordinator.resetPhiSyncCursorIfAccountChanged(accountId:defaults:)`: it
    /// wipes the same `stateKeys` from outside, keyed on a recorded owner account, at the one
    /// moment the wipe is safe — before the engine for the new account exists (the marker file
    /// needs no wipe there: it is inside the account directory). Doing it from in here cannot
    /// cover that case anyway: sign-out calls `shutdown()`, and the guard below then makes
    /// this a no-op, precisely because a retired engine's `UserDefaults` may already belong to
    /// the account mounted next.
    ///
    /// **Account scope only.** Nothing that happens *within* one account may call this:
    /// clearing `hasAdopted` re-arms the wholesale adopt in `apply`, and the account's own
    /// settings history is precisely what makes a field-level merge possible. The two
    /// same-account recoveries (a server row this device can no longer address, and a store
    /// birthday that no longer matches) go through `clearRemoteCursor()` and
    /// `resetForNewStoreBirthday()` instead.
    ///
    /// Deliberately synchronous and *not* queued: it runs to completion between the suspension
    /// points of any round, so it never tears a half-written cursor.
    func resetSyncState() {
        guard !isStopped else { return }
        canPublishThisRound = false
        for key in Self.stateKeys { defaults.removeObject(forKey: key) }
        // marker / birthday 住在账户目录的 `marker.json` 里（§2.10），不在 `stateKeys` 里；
        // 「Drops every account-scoped cursor」这句合同要它们也一起走。删文件而不是存一张
        // 空表（§4.4），镜像同步复位。
        markerState = PhiSyncMarkerFile()
        markerStore.deleteFile()
    }

    // MARK: - Round serialization

    /// Runs `round` after every round enqueued before it. Actor reentrancy means a round that
    /// is parked in `getUpdates` or `commit` would otherwise let the next one in and both would
    /// interleave their writes to `storedVersion` / `storedMarker` / `storedLastEntity`.
    private func serialized(_ round: Round) async {
        let previous = roundQueue
        let task = Task { [previous] in
            await previous?.value
            await self.run(round)
        }
        roundQueue = task
        await task.value
    }

    private func run(_ round: Round) async {
        // A round enqueued before sign-out but still waiting behind an in-flight one must not
        // start against the account that has since been mounted on the same defaults.
        guard !isStopped else { return }
        // §11's counters are per ROUND, not per pull: one round can contain a
        // NOT_MY_BIRTHDAY retry, the push's preflight pull and a scoped conflict
        // retry, and `pushSpaces` runs after the pull's tail has already finished.
        spaceCounters = SpaceRoundCounters()
        canPublishThisRound = false
        // 同上，同范围：归属 kind 的计数、轮首读的成功与否、以及随学随加的 tag 索引都是
        // **每轮**的，不是每次 pull 的。
        ownedCounters = [:]
        ownedReadFailed = []
        ownedTagIndices = [:]
        ownedRoundStarted = []
        ownedParkedRetryDone = []
        ownedMapsThisRound = nil
        // B-2 的四个轮级计数（§2.5 / §2.8）同范围：一轮之内的每一次 pull 累加，轮首清零。
        cursorSaveFailures = 0
        roundOutcome = .ok
        roundPages = 0
        roundMarkerAdvanced = false
        ownedTables = [:]
        ownedMustRepublish = [:]
        // §8.2 / Task 10：投喂源也是**每轮**的。上一轮没来得及交出去的行由队列自己留着，
        // 这里清的只是本轮的收集篮。
        faviconCandidatesThisRound = []
        faviconPinCandidatesThisRound = []
        ownedDeferredOwners = [:]
        // Same reason, same scope: the NOT_MY_BIRTHDAY recursion (:608), the push's initial
        // pull (:1160 / :1456) and the CONFLICT retry (:1250) are all pulls inside ONE round,
        // and none of them re-lists the account's profiles.
        didRefreshProfilesThisRound = false
        switch round {
        case .pull:
            _ = await pull(retryOnBirthday: true, thenPush: true)
        case .push:
            await push(retryOnConflict: true)
        case .localChange:
            guard !isApplyingRemote else { return }
            await push(retryOnConflict: true)
        case .localSpaceChange:
            guard !isApplyingRemote else { return }
            await push(retryOnConflict: true)
        case .spaceGate(let enabled):
            applySpaceGate(enabled)
        case .retentionSweep:
            await applyRetentionSweep()
        case .recordLocalDeletion(let localSpaceId):
            // 边界翻译（§3.4）：`SpaceManager` 交来的是**本地** id，游标按 syncUuid
            // 键。解析不到 = 从来没发布过 = 无 tombstone 可发，这与
            // `PhiSpaceSyncTable.recordLocalDeletion` 既有的 `entityId != nil` 判据
            // 是同一件事的两个说法。门面 `PhiSpaceSyncState.recordLocalDeletion(spaceId:)`
            // 的签名与语义**不变**，仍收本地 id。
            if let uuid = await spaceAccess?.syncUuid(forSpaceId: localSpaceId) {
                runSpaceIntent { table in table.recordLocalDeletion(spaceId: uuid) }
            } else {
                AppLogInfo("[phi-sync] a local Space delete has no account identity; nothing to tombstone")
            }
        case .localOwnedChange(let label):
            // 回声抑制与 `.localSpaceChange` 逐字同款。`label` 只进日志：发布段按注册清单
            // 跑完全部 kind，所以一条 kind 的本地变化就是一次普通的 push round。
            guard !isApplyingRemote else { return }
            AppLogInfo("[phi-sync] local change for owned kind=\(label)")
            await push(retryOnConflict: true)
        case .preview(let box):
            await runPreview(into: box)
            return          // 预览不是 Space 轮：不参与 §11 的计数行，也不发结局行
        }
        logRoundOutcome()
        await logSpaceRound()
        logOwnedRounds()
        await runFaviconBackfill()
    }

    /// §2.8 / §13.2 的结局行（B-2）。发射点在这里而不是 `serialized(_:)`：后者只是排队壳。
    /// **不带** `logSpaceRound` / `logOwnedRounds` 那道 `spaceSectionEnabled` 守卫——门关轮次与
    /// M3-1 纯设置引擎正是要读这一行的两种形态。
    ///
    /// 发射前按固定优先级收口（计划裁定 6）：
    /// 1. `.notMyBirthday` 已置 ⇒ 不被覆盖；
    /// 2. `cursorSaveFailures > 0` ⇒ `.cursorSaveFailed`（这条让 push 段自己的游标写失败也收口成
    ///    `cursor_save_failed`，§2.5 第 8 条）；
    /// 3. 仍是 `.ok` 且本轮有 kind 的本机读失败 ⇒ `.localReadFailed`；
    /// 4. 仍是 `.ok` 且 Space 段有 store 但门关着 ⇒ `.gated`（`spaceStore == nil` 不算 gated，
    ///    那是 M3-1 纯设置引擎的正常形态，RR-B10）。
    ///
    /// R12：只有枚举名、计数与布尔，没有实体内容。
    private func logRoundOutcome() {
        var outcome = roundOutcome
        if outcome != .notMyBirthday {
            if cursorSaveFailures > 0 {
                outcome = .cursorSaveFailed
            } else if outcome == .ok, !ownedReadFailed.isEmpty {
                outcome = .localReadFailed
            } else if outcome == .ok, spaceStore != nil, !spaceSectionEnabled {
                outcome = .gated
            }
        }
        lastLoggedRound = LoggedRound(outcome: outcome, pages: roundPages,
                                      markerAdvanced: roundMarkerAdvanced,
                                      cursorSaveFailures: cursorSaveFailures)
        AppLogInfo("[phi-sync] round outcome=\(outcome.rawValue) pages=\(roundPages) "
                   + "marker_advanced=\(roundMarkerAdvanced) cursor_save_failed=\(cursorSaveFailures)")
    }

    /// §8.2 / Task 10：每轮末尾的一趟图标回填。
    ///
    /// 放在计数落定之后，因为它**不是同步的一部分**：它不碰游标、不写基线、不触发推送，
    /// 一次失败在 §11.2 的计数行里不该留下任何痕迹。队列自己有界（每轮 20 条），所以本轮
    /// 交进去多少与本轮真的取多少是两件事——排不上的行留到下一轮，而下一轮即使一条新行都
    /// 没有也照样排空一次。
    private func runFaviconBackfill() async {
        guard let queue = faviconBackfill, !isStopped else { return }
        let rows = faviconCandidatesThisRound
        let pins = faviconPinCandidatesThisRound
        faviconCandidatesThisRound = []
        faviconPinCandidatesThisRound = []
        if !rows.isEmpty { await queue.enqueue(rows) }
        if !pins.isEmpty { await queue.enqueue(pins) }
        _ = await queue.drainOnce()
    }

    // MARK: - 配对向导的只读账户预览（§4）

    /// §4.3 的轮体。跑在引擎 actor 的同一条 round 队列上；never call it directly.
    private func runPreview(into box: PreviewBox) async {
        let startedAt = now()
        // 轮首清零。`lastPreviewStats` 是**这一次**预览的计数：不清零的话，一次在拿域密钥
        // 上就失败的预览会让只读接缝与日志继续报上一次的页数，而那两个数字唯一的用处就是
        // 分辨「这次截断了」与「这次根本没跑起来」。下面每一条出口都写它，前置失败那几条
        // 写的就是这里的 (0, 0)。
        lastPreviewStats = (0, 0)
        guard !isStopped else { box.result = .failure(.retired); return }
        let key: SymmetricKey
        do {
            key = try await domainKeys.domainKey()
        } catch {
            AppLogWarn("[phi-sync] space preview failed: domain key unavailable (\(PhiSyncLog.describe(error)))")
            box.result = .failure(.transport("domain_key"))
            return
        }
        guard !isStopped else { box.result = .failure(.retired); return }

        var summaries: [String: (entity: Phi_PhiSpaceEntity, version: Int64)] = [:]
        var pages = 0
        var entities = 0
        var refused = 0
        var unreadable = 0
        // **局部** marker：响应里的 marker 与 birthday 都不写回。首次加入时
        // `storedBirthday` 可能还是 ""（设置同步的第一轮尚未收尾），这是正常输入——
        // 服务端会回一个真的，预览照旧不写回。
        var marker: Data?
        var more = true
        do {
            // 预算是**预览自己的**那一个，不是拉取的 `maxPullPages`：后者 64 页 × 500 条
            // 要横跨全部 kind、并且把 tombstone 一起数进去，书签与 pin 落地之后它在一个
            // 普通账户上就不够用了（§5.8）。
            while more, pages < previewMaxPages {
                // §4.5 的期限，判在**发下一页之前**。这是唯一能真正停下这次预览的地方
                // （见 `previewDeadlineMs`）；判在页边界上，所以最坏还要等当前这一页的
                // `URLSession` 超时，但分页不会再往下走，round 队列也随之让开。
                guard now() - startedAt < Self.previewDeadlineMs else {
                    lastPreviewStats = (pages, entities)
                    AppLogWarn("[phi-sync] space preview: pages=\(pages) entities=\(entities) "
                               + "error=deadline")
                    box.result = .failure(.timedOut)
                    return
                }
                let response = try await client.getUpdates(marker: marker, storeBirthday: storedBirthday)
                guard !isStopped else {
                    lastPreviewStats = (pages, entities)
                    box.result = .failure(.retired)
                    return
                }
                marker = response.newMarker
                pages += 1
                more = response.changesRemaining
                for entity in response.entities {
                    entities += 1
                    // 设置实体不关它的事；tombstone 不需要（账户里已经删掉的 Space
                    // 不该出现在配对列表里）。
                    guard entity.clientTagHash != PhiSyncEntity.settingsClientTagHash,
                          !entity.deleted else { continue }
                    guard let decoded = try? PhiEntityCodec.decrypt(entity.ciphertext, key: key) else {
                        unreadable += 1     // 只计数，**不**记进 `unreadableTagHashes`
                        continue
                    }
                    guard case .space(let space)? = decoded.kind else { continue }
                    let expected = PhiSyncEntity.clientTagHash(
                        for: PhiSyncEntity.spaceClientTag(space.spaceUuid))
                    guard expected == entity.clientTagHash else { unreadable += 1; continue }
                    // 两条 agent 特征匹配的载荷绝不能出现在配对选项里；默认 Space 的
                    // 身份由 D1 固定，绝不可在配对列表里被选中。
                    guard !SyncableSpaces.refuses(space) else { refused += 1; continue }
                    guard space.spaceUuid != SyncableSpaces.defaultSpaceUuid else { continue }
                    // 一次全量重放里每个实体只出现一次；去重取 version 较大者是防御性的。
                    if let seen = summaries[space.spaceUuid], seen.version >= entity.version { continue }
                    summaries[space.spaceUuid] = (space, entity.version)
                }
            }
        } catch PhiSyncProtocolError.notMyBirthday {
            // 预览不做任何游标清理，那是正式 pull 的职责。**这不是死路**：设置同步照常
            // 按 60 s 跑，它自己的 birthday 重试会把 `storedBirthday` 修好，下一次
            // Retry 就能过。
            lastPreviewStats = (pages, entities)
            AppLogWarn("[phi-sync] space preview: pages=\(pages) entities=\(entities) "
                       + "error=not_my_birthday")
            box.result = .failure(.transport("not_my_birthday"))
            return
        } catch {
            lastPreviewStats = (pages, entities)
            AppLogWarn("[phi-sync] space preview: pages=\(pages) entities=\(entities) "
                       + "error=\(PhiSyncLog.describe(error))")
            box.result = .failure(.transport(PhiSyncLog.describe(error)))
            return
        }

        guard !more else {
            // **不返回部分结果**：Account 列缺一条，用户就可能把一个账户里已经存在的
            // Space 选成「Add as new」，铸出第二条实体——而那正是这个向导要消灭的状态。
            // 计数走 `lastPreviewStats`，**不挂在 `.truncated` 上**：那个 case 不带载荷。
            lastPreviewStats = (pages, entities)
            AppLogWarn("[phi-sync] space preview: pages=\(pages) entities=\(entities) "
                       + "error=truncated")
            box.result = .failure(.truncated)
            return
        }

        let out = summaries.values.map { item -> PhiAccountSpaceSummary in
            let entity = item.entity
            return PhiAccountSpaceSummary(
                syncUuid: entity.spaceUuid,
                name: entity.name.stringValue,
                iconName: entity.iconName.stringValue,
                colorHex: entity.colorHex.stringValue,
                profileUuid: entity.profileUuid.stringValue,
                isDefault: false,
                themeId: entity.themeID.stringValue,
                overlayOpacityLightMilli: entity.overlayOpacityLight.intValue,
                overlayOpacityDarkMilli: entity.overlayOpacityDark.intValue)
        }.sorted { $0.syncUuid < $1.syncUuid }   // 顺序确定，便于测试与两机对照
        lastPreviewStats = (pages, entities)
        // §9.1 第一条。R12：只有计数。
        AppLogInfo("[phi-sync] space preview: pages=\(pages) entities=\(entities) "
                   + "spaces=\(out.count) refused=\(refused) unreadable=\(unreadable) "
                   + "ms=\(now() - startedAt)")
        box.result = .success(out)
    }

    // MARK: - §11 round counters

    /// §11's one-line-per-round counter set. Metadata only (R12): counts and
    /// booleans, never a uuid, a name, an icon or a colour.
    ///
    /// `applied` counts entities that LANDED this round (creates, field updates,
    /// rebinds and remote soft deletes); `tombstones` counts the tombstones this
    /// device PUBLISHED, next to `pushed` and `conflicts`.
    private struct SpaceRoundCounters {
        var pulled = 0
        var applied = 0
        var refused = 0
        var pushed = 0
        var tombstones = 0
        var conflicts = 0
        var profilesCreated = 0
        /// ok | failed | skipped. `skipped` covers "already refreshed this
        /// round", "inside the 30 s interval" and "the gate is shut" -- §11 is
        /// explicit that it is NOT a failure. Filled in by Task 11's refresh hook;
        /// until that lands no refresh runs at all, so `skipped` is the true value.
        var profileRefresh = "skipped"
    }
    private var spaceCounters = SpaceRoundCounters()

    /// One info line per round, at the end of the round.
    private func logSpaceRound() async {
        guard spaceSectionEnabled, spaceStore != nil else { return }
        let table = loadSpaceTable()
        let held = table.cursors.values.filter { $0.heldProfileUuid != nil }.count
        let parked = table.cursors.values.filter { $0.pendingApply != nil }.count
        // §9.3：`mapped` 是映射表的行数（不含默认 Space 的隐式常量）；`unmapped` 是
        // 「本机同步合格、但还没有映射」的条数。**稳态应为 0**——长期非零 = 懒铸造
        // 一直失败，这是唯一能把「这台 Mac 的某个 Space 从来没上过账户」暴露出来的
        // 信号（D6 之前那个设置段落没了，这就是它的替代物：一个计数器，不是一个界面）。
        // R12：两个都是计数，不是 uuid 列表。
        // `filter` 的闭包里不能 `await`，所以映射表一次读完再在本地比。
        var mapped = 0
        var unmapped = 0
        if let spaceAccess {
            let mappings = await spaceAccess.allSpaceMappings()
            mapped = mappings.count
            unmapped = await spaceAccess.currentSpaces().filter {
                $0.spaceId != LocalStore.defaultSpaceId && mappings[$0.spaceId] == nil
            }.count
        }
        AppLogInfo("""
            [phi-sync] spaces pulled=\(spaceCounters.pulled) applied=\(spaceCounters.applied) \
            held=\(held) parked=\(parked) refused=\(spaceCounters.refused) \
            unreadable=\(table.unreadableTagHashes.count) pushed=\(spaceCounters.pushed) \
            tombstones=\(spaceCounters.tombstones) conflicts=\(spaceCounters.conflicts) \
            drained=\(table.hasDrainedFullReplay) drain_in_progress=\(table.drainInProgress) \
            profiles_created=\(spaceCounters.profilesCreated) \
            profile_refresh=\(spaceCounters.profileRefresh) \
            mapped=\(mapped) unmapped=\(unmapped)
            """)
    }

    // MARK: - Pull

    /// Why a pull could not turn the account's entity into settings. Only `.tombstone` is
    /// healable: the other two mean the server holds real content this build must not
    /// overwrite, and the refusal has to stand until a re-minted key or a newer build can read
    /// it. A tombstone carries nothing to protect, so it may eventually be re-created.
    private enum UnusableReason: String {
        case tombstone
        case foreignPayload = "payload is not settings"
        case undecryptable = "ciphertext could not be opened"
    }

    /// What one pull could make of the account's settings entity.
    private enum RemoteView {
        /// The server sent nothing under our client tag this round.
        case absent
        /// Decrypted settings this device can merge against.
        case usable(Phi_PhiSettingEntity)
        /// The entity is there but this build cannot turn it into settings (a tombstone, a
        /// ciphertext it cannot open, or a payload that is not `.setting`). Its bytes must
        /// survive: this device may not publish over them.
        case unusable(reason: UnusableReason)
    }

    /// R-M3-4a-37：逐页边界下的 marker 抑制是**轮级状态**，不是 `break`。
    ///
    /// `.resetToNil` 之后本轮**内存里的** marker 照常逐页推进（下一次请求带什么，R-M3-4a-76），
    /// 只是不再持久化任何一页，轮末把盘上的 marker 写成 nil。两个来源：guard 2 的空表重放、
    /// 设置实体 `.unusable`。
    private enum MarkerSuppression { case none, resetToNil }

    /// §2.8 的八个具名结局。每一个都对应引擎里一条**已经存在**的早退或失败路径，
    /// 本里程碑只给它们起名字，不新增路径。`rawValue` 直接进 R12 日志行。
    enum RoundOutcome: String {
        case ok
        case gated
        case pageBudgetExhausted = "page_budget_exhausted"
        case localReadFailed = "local_read_failed"
        case unusableSettings = "unusable_settings"
        case cursorSaveFailed = "cursor_save_failed"
        case pullFailed = "pull_failed"
        case notMyBirthday = "not_my_birthday"
    }

    /// 两个 debug 中止点（§12.2 Q-12）。调用点只说「哪一个」，于是 release 构建里既没有键名
    /// 字符串也不需要 `#if`（计划裁定 8）。
    private enum DebugAbortPoint { case afterApply, betweenKinds }

    #if DEBUG || PHI_SYNC_DEBUG_SWITCHES
    static let abortAfterApplyKey = "phi.sync.debug.abortAfterApply"
    static let abortBetweenKindsKey = "phi.sync.debug.abortBetweenKinds"
    #endif

    /// 一次性：读到真值先清键再 `abort()`，否则重启后的第一轮立刻再自杀。
    /// Release 构建里整个方法体为空（计划裁定 8），调用点因此不需要 `#if`。编译条件是
    /// `#if DEBUG || PHI_SYNC_DEBUG_SWITCHES`：后者只由 Task 12 的验收构建配方经
    /// `OTHER_SWIFT_FLAGS` 传入，本仓库的工程设置里没有它。
    private func abortIfRequested(_ point: DebugAbortPoint) {
        #if DEBUG || PHI_SYNC_DEBUG_SWITCHES
        let key: String
        switch point {
        case .afterApply: key = Self.abortAfterApplyKey
        case .betweenKinds: key = Self.abortBetweenKindsKey
        }
        let store = UserDefaults.standard
        guard store.bool(forKey: key) else { return }
        store.removeObject(forKey: key)
        AppLogError("[phi-sync] deliberate abort requested by \(key)")
        abort()
        #endif
    }

    /// Returns whether all pages were downloaded and processed. A page-budget stop is not
    /// success: callers must wait for a drained pull before publishing any entity kind.
    ///
    /// M3-4a B-2（spec §2.4）：**逐页边界**。每一页的次序是 路由 → 设置落地 → Space 落地 →
    /// 归属 kind 落地 → （派生标志）→ marker；marker 是全页最后一次写，只越过已经完整落地的
    /// 页。任何一次游标 / 表 / 映射 / marker 文件写失败（`cursorSaveFailures`）都让本页的 marker
    /// 不推、本轮零发布，下一轮从上一个完整落盘的页重收——重收一页是幂等的（§2.7）。
    private func pull(retryOnBirthday: Bool, thenPush: Bool) async -> Bool {
        canPublishThisRound = false
        guard !isStopped else { return false }
        let key: SymmetricKey
        do {
            key = try await domainKeys.domainKey()
        } catch {
            AppLogWarn("[phi-sync] pull skipped: domain key unavailable (\(PhiSyncLog.describe(error)))")
            return false
        }
        // Sign-out can land in any of this round's suspension points; from here the round is
        // holding the *previous* account's domain key, so everything below is off-limits.
        guard !isStopped else { return false }

        // Guard 1 (§5.5): the drain is a PROCESS, not the property of one pull. It is armed
        // only while the Space section is live — a gated-off pull hands the Space section
        // nothing, so letting it satisfy the guard would let a fresh device publish its
        // factory default Space over the account's.
        //
        // The whole Space side of this round obeys one rule: **no copy of the table spans a
        // suspension point, and every flag is persisted the moment it is observed**. The
        // shared marker is written page by page (`persistStoredMarker(marker)` is the last
        // write of every page), so a flag derived from it has to be persisted page by page
        // too — and BEFORE that page's marker (R-M3-4a-77): a flag written after the marker
        // is simply gone when the marker write succeeds and the flag write does not, with the
        // marker left standing past whatever it walked over.
        let spaceTableAtEntry = loadSpaceTable()
        let spaceLive = spaceSectionEnabled && spaceStore != nil && spaceAccess != nil
        if spaceLive, storedMarker == nil, !spaceTableAtEntry.drainInProgress {
            // Persisted immediately, not at the tail: page 1 already makes the marker
            // non-nil, so a round that dies on page 2 would otherwise leave a non-nil marker
            // on disk beside `drainInProgress == false`. This precondition (`storedMarker ==
            // nil`) could then never be met again, `hasDrainedFullReplay` would stay false
            // for the rest of the session, and that flag is what Task 9's `pushSpaces` guard
            // reads before it publishes anything.
            mutateSpaceTable { table in
                table.drainInProgress = true
                table.hasDrainedFullReplay = false
            }
        }
        // Refresh the account profile list BEFORE the paging loop on purpose:
        // the bindings this round pulls must resolve against the mapping this
        // round just refreshed, or a Space a peer published seconds ago has to
        // park for a whole round.
        if spaceLive, !didRefreshProfilesThisRound, let spaceAccess {
            let elapsed = now() - lastProfileRefreshAtMs
            if lastProfileRefreshAtMs == 0 || elapsed >= Self.profileRefreshMinIntervalMs {
                didRefreshProfilesThisRound = true
                let outcome = await spaceAccess.refreshAccountProfiles()
                // The refresh is an `await`: retirement / sign-out / an account
                // switch can land inside it (§5.4 discipline).
                guard !isStopped else { return false }
                // A FAILED refresh does not arm the interval, or "retry next
                // round" would be contradicted by the throttle itself. `.skipped`
                // does not arm it either -- nothing ran.
                if outcome != .failed, outcome != .skipped { lastProfileRefreshAtMs = now() }
                // §11's two profile fields. `skipped` is the default the counter
                // struct starts with, so the branches that never reach here
                // (gate shut, already refreshed, inside the interval) report it
                // by construction -- and §11 is explicit that it is not a failure.
                switch outcome {
                case .failed: spaceCounters.profileRefresh = "failed"
                case .skipped: spaceCounters.profileRefresh = "skipped"
                case .unchanged, .changed: spaceCounters.profileRefresh = "ok"
                }
                spaceCounters.profilesCreated = await spaceAccess.profilesCreatedInLastRefresh()
            }
        }
        // 归属 kind 的轮首：读本机行、载入该 kind 的游标表、按游标键 ∪ 本机身份建 tag 索引。
        // 次序是固定的（§4.8 的契约）：轮首 `allBookmarks()` → 落地 → 复核 → 写基线 →
        // 差分与发布。
        //
        // **这一次 load 不武装重放**（`armsReplayOnLoss: false`）。报损由发布段那一次 load
        // 观察并处理：它在那里丢 marker、把 `hasDrainedFullReplay` 置假，于是**下一轮**才是
        // 那次整类型重放，而这一轮的发布就地中止（CASE 6.26）。
        if spaceLive { await beginOwnedRound() }
        // A snapshot, used for the cursor keys it carries and never written back.
        let tagIndex = spaceLive ? await spaceTagIndex(table: spaceTableAtEntry) : [:]

        // ── 轮级状态，全部在页循环之外声明（RR-B11）──
        //
        // A pull with no marker replays the whole type, so "the entity was not in the response"
        // is only evidence of absence when we started from scratch and drained every page.
        // 读的是 guard 2 生效**之前**的 marker（计划裁定 1）：guard 2 排在下面，所以一次
        // 「空表重放 + 账户里确实没有设置实体」的轮次不会多丢一次设置游标。
        let startedFromScratch = storedMarker == nil
        // What guard 2's first trigger compares against. `storedMarker`'s setter maps an empty
        // marker to *absent*, so "the marker did not move" is spelled "unchanged", never
        // "nil": the protocol client answers with `Data()` when the server sent no marker for
        // the type, and a response's `newMarker` is non-optional.
        let markerAtEntry = storedMarker
        // Only a gated-off round records marker movement, and only once per round: the flag
        // is a boolean, so the first page that moves the marker has already said everything
        // there is to say. `spaceStore != nil` keeps a settings-only engine (M3-1) out of the
        // Space table entirely.
        let recordsGatedMarkerMoves = !spaceLive && spaceStore != nil
        var markerMoveRecorded = false
        // R-M3-4a-38：设置实体的视图是**轮级**的——一条 drain 里它至多出现一次，而 `.absent`
        // 的动作（清设置游标）问的是「整条 drain 一页都没带设置实体吗」，逐页求值会在最后一页
        // 把刚建立的游标丢掉。`sawSettingsEntity` 就是那个轮级谓词。
        var view = RemoteView.absent
        var sawSettingsEntity = false
        var markerSuppression = MarkerSuppression.none
        var maySettingsPublish = true
        // R-M3-4a-76：内存里这个 marker 永远逐页推进，它回答的是「下一次请求带什么」，与
        // 「要不要持久化」无关；抑制只作用在 `storedMarker` 上。
        var marker = storedMarker
        var pages = 0
        var more = true
        var drained = false

        // Guard 2, trigger 2 (空表重放) 是**轮级**判定，留在页循环之外（R-M3-4a-37 / 47）：它
        // 描述的是「这台机器的 Space 表整份丢了」，与页无关；判据只读 `spaceTableAtEntry`。
        // Guarded by a ONE-SHOT flag, never by `hadRecords` / `hasDrainedFullReplay`: an
        // account whose Space entities all fail to decrypt keeps `cursors` empty and
        // `hadRecords` true forever, and would drop the marker and replay on every round.
        //
        // **先清 marker、确认写成之后才烧闩**（R-M3-4a-89，计划裁定 3）：marker 在 `marker.json`、
        // 闩在 plist，两份文件不可能原子写，所以次序必须是「可重来的那一步在前」。失败一律
        // 收口成 `.cursorSaveFailed`：闩没烧、drain 标志没动、零页、零发布，下一轮 guard 2 再
        // 触发一次。「旧 marker + 已烧闩」那一格由此不可达——闩的全仓唯一复位点是
        // `resetForNewStoreBirthday()`，那一格一旦可达就是永久失效。
        if spaceLive, spaceTableAtEntry.cursors.isEmpty, spaceTableAtEntry.hadRecords,
           !spaceTableAtEntry.didReplayForEmptyTable {
            // ① 先把盘上的 marker 清成 nil。写不成 ⇒ 什么都没发生，本轮到此为止：返回值就是
            //    `canPublishThisRound`，它在函数入口已经复位成 `false` ⇒ 零页、零发布。
            guard persistStoredMarker(nil) else {
                roundOutcome = .cursorSaveFailed
                return false
            }
            // ② marker 已确认落盘，这才烧闩 + 武装 drain。写不成 ⇒ 盘上是「marker 已清、闩未烧」，
            //    R-M3-4a-83 的回滚让内存与盘一致 ⇒ 下一轮 guard 2 判据仍成立 ⇒ 再清一次 marker
            //    （幂等，`persistMarkerState` 的 `updated == markerState` 短路成零写）⇒ 收敛。
            guard mutateSpaceTable({ table in
                table.didReplayForEmptyTable = true
                table.hasDrainedFullReplay = false
                table.drainInProgress = true
            }) else {
                roundOutcome = .cursorSaveFailed
                return false
            }
            AppLogWarn("[phi-sync] space table is empty but had records; replaying data type \(PhiSyncEntity.dataTypeID) once")
            // ③ 两次写都确认之后才动内存。
            marker = nil                                    // 本轮从头拉
            markerSuppression = .resetToNil                 // 此后任何一页都不再持久化 marker
        }
        // `hadRecords` 的维护跟着 guard 2 走到页循环之前（计划裁定 2），读的是 `spaceTableAtEntry`
        // 那一刻的 `cursors`：留在每一页里的话，第 1 页落地的游标会让第 2 页当场置真，同一轮内
        // 改变 guard 2 第二个触发条件的语义。本轮新建的游标要下一轮才置 `hadRecords`，这是无害
        // 的：`hadRecords` 描述的是一张曾经有过内容、后来丢了的表。
        if spaceLive, !spaceTableAtEntry.cursors.isEmpty, !spaceTableAtEntry.hadRecords {
            mutateSpaceTable { $0.hadRecords = true }
        }

        do {
            pageLoop: while more, pages < Self.maxPullPages {
                let response = try await client.getUpdates(marker: marker, storeBirthday: storedBirthday)
                guard !isStopped else { return false }
                // 逐页落盘（§2.4 说明 1）：birthday 变了 ⇒ marker 作废，两者住同一个文件。写失败
                // 由 `persistMarkerState` 计数，本页末统一收口——本页照常落地，只是不推 marker。
                storedBirthday = response.storeBirthday
                // 先不落盘（R-M3-4a-18）：它是全页的最后一次写。
                let pageMarker = response.newMarker
                more = response.changesRemaining
                pages += 1
                roundPages += 1

                // 本页的两个收集篮。逐页落地之后它们不再跨页：一页落完就没有「收到了但还没
                // 放下去」的实体，所以中途抛错（只可能发生在 `getUpdates`）不再需要停放。
                var batch = SpacePullBatch()
                var ownedBatches: [String: OwnedPullBatch] = [:]
                var pageCarriedSettingsEntity = false
                for entity in response.entities {
                    guard entity.clientTagHash == PhiSyncEntity.settingsClientTagHash else {
                        // Not the settings entity. With two kinds live on data type 2000 the
                        // response is no longer "our row or noise": everything else is routed
                        // to the Space section, and only while the gate is open.
                        //
                        // §5.1 的真分发：按 tag hash 查索引，**绝不是「先解密再 switch」**
                        // ——tombstone 没有密文，解密必然抛错，而 marker 已经推过那一页。
                        guard spaceLive else { continue }
                        if tagIndex[entity.clientTagHash] != nil {
                            routeSpaceEntity(entity, key: key, tagIndex: tagIndex, into: &batch)
                            continue
                        }
                        // 按注册清单逐条试；索引是引擎自己的 `ownedTagIndices[label]`。
                        if let registration = ownedKinds.first(where: {
                            ownedTagIndices[$0.label]?[entity.clientTagHash] != nil
                        }) {
                            routeOwnedEntity(registration, entity, key: key,
                                             decoded: nil, into: &ownedBatches)
                            continue
                        }
                        // 都不认。**带密文的**实体还有一条路：解开之后按 `decoded.kind` 找
                        // 注册项——一条 create 先于本机建立它的索引项到达就是这个形状。
                        // tombstone、解不开的密文与仍然认不出的载荷一律交回 Space 段，于是
                        // 「未知 tag」的处置与今天逐字相同（未知 tombstone 记 info、解不开
                        // 的进隔离区、别的 kind 只忽略这一条）。
                        if !entity.deleted, !ownedKinds.isEmpty,
                           let decoded = try? PhiEntityCodec.decrypt(entity.ciphertext, key: key),
                           let registration = ownedKinds.first(where: {
                               $0.identity(decoded) != nil
                           }) {
                            routeOwnedEntity(registration, entity, key: key,
                                             decoded: decoded, into: &ownedBatches)
                            continue
                        }
                        routeSpaceEntity(entity, key: key, tagIndex: tagIndex, into: &batch)
                        continue
                    }
                    if !entity.entityId.isEmpty { storedEntityId = entity.entityId }
                    storedVersion = entity.version
                    // 设置那一条只更新**轮级** `view`，不在页内求值（R-M3-4a-38）；四个子支都算
                    // 「本页带了设置实体」。
                    sawSettingsEntity = true
                    pageCarriedSettingsEntity = true
                    guard !entity.deleted else {
                        // A tombstone from another device: nothing to apply, and nothing to
                        // publish either — re-committing this device's snapshot on top of it
                        // would silently undelete the account's settings (the server's
                        // client_tag unique index reuses the tombstoned row).
                        view = .unusable(reason: .tombstone)
                        continue
                    }
                    do {
                        let decoded = try PhiEntityCodec.decrypt(entity.ciphertext, key: key)
                        guard case .setting(let setting)? = decoded.kind else {
                            AppLogWarn("[phi-sync] remote entity carries no settings payload; ignoring")
                            view = .unusable(reason: .foreignPayload)
                            continue
                        }
                        view = .usable(setting)
                    } catch {
                        // Wrong key (a re-mint this device has not caught up with, or a peer
                        // sealing with an envelope version this build rejects) or corrupt
                        // bytes. Never apply it, and never publish over it.
                        AppLogError("[phi-sync] cannot open remote entity version=\(entity.version) ciphertext_bytes=\(entity.ciphertext.count) (\(PhiSyncLog.describe(error)))")
                        view = .unusable(reason: .undecryptable)
                    }
                }

                // ── 这一页的落地段。次序与整轮粒度时的轮末段逐字相同，只是作用域变成一页 ──
                switch view {
                case .usable(let remote) where pageCarriedSettingsEntity:
                    tombstoneRounds = 0
                    // Wholesale only until this device has settings history of its own — which
                    // is `hasAdopted`, not "do we know which row they live in": a cursor
                    // dropped by the tombstone heal or the full-replay branch must not cost
                    // this device its local timestamps. See `apply` and `hasAdopted`.
                    apply(remote, adopt: !hasAdopted)
                case .unusable(let reason) where pageCarriedSettingsEntity:
                    // The server holds bytes under our client tag that this build cannot read.
                    // Not applying them is only half the job: the trailing push must not run
                    // either, because it would commit this device's snapshot against the id
                    // and version we just harvested from that very entity and replace it for
                    // every other device — including the keys of a newer client that this
                    // build does not understand. Rewinding the marker makes the next round see
                    // the entity again, so a re-minted domain key or a newer build heals this
                    // instead of it being terminal.
                    //
                    // R-M3-4a-37：抑制是轮级状态，取代原地的 `storedMarker = nil`。drain 照常走完
                    // 剩下的页（内存 marker 继续推进，R-M3-4a-76），轮末才把盘上的 marker 写成
                    // nil——`break` 会让版本高于这一条的一切实体永久收不到。
                    markerSuppression = .resetToNil
                    // The baseline goes with the marker, and that is what makes the refusal
                    // durable rather than a one-round suppression. `push`'s guard reads "an
                    // entity id with no baseline" as "the server holds bytes this device has not
                    // read"; a device that had synced before would otherwise keep the baseline
                    // it decrypted at an older version, and the next debounced local change —
                    // or the conflict retry, which reaches the scoped publisher and never sees
                    // `maySettingsPublish` — would commit over the unreadable entity using the
                    // id and version harvested from it right here. `storedEntityId` survives
                    // (the server always sends a non-empty `id_string`:
                    // internal/chromiumsync/getupdates.go toSyncEntity, from the UUID commit.go
                    // assigns on create), so no `version = 0` create can slip past the
                    // unreadable-baseline guard either. `apply` re-establishes the baseline as
                    // soon as a pull can read the entity again.
                    storedLastEntity = nil
                    maySettingsPublish = false
                    noteUnusable(reason)
                default:
                    break                       // `.absent` 的动作是**轮级**的，见循环之后
                }

                if spaceLive {
                    flushSpaceObservations(batch)
                    flushOwnedObservations(ownedBatches)
                    // The apply path is the one Space write that cannot be expressed as a
                    // `mutateSpaceTable` delta: `applySpaces` hops to the main actor on
                    // every landing, so its table copy necessarily spans suspension
                    // points. One load / apply / write per page is safe *here* and only
                    // here — rounds are serialized (`serialized(_:)` chains them; the gate
                    // edge and BOTH main-thread Space intents are themselves rounds), and
                    // nothing else touches the table between this load and this write.
                    //
                    // It MUST sit after `flushSpaceObservations(batch)`: `applySpaces`
                    // clears `unreadableTagHashes` for every uuid it lands, and loading
                    // after the flush is what makes "the refusal lifts by itself" true
                    // instead of racing this page's own record of the same hash. (Guard 2
                    // no longer needs an ordering here: it is a round-level check that
                    // reads `spaceTableAtEntry` before the first page, §2.4 说明 6.)
                    var spaceTable = loadSpaceTable()
                    spaceCounters.pulled += batch.decoded.count + batch.tombstones.count
                    await applySpaces(batch, table: &spaceTable)
                    await applySpaceTombstones(batch, table: &spaceTable)
                    writeSpaceTable(spaceTable)

                    // §5.2 的轮次顺序：设置 → Space → 归属 kind（注册清单的次序）。放在同一页
                    // 的后段，账户里本机没有的 Space 与它下面的树因此**通常在一页内**全部落地。
                    //
                    // R-M3-4a-39：身份翻译表**每页失效一次**。这一页刚落地的 Space 写下了新映射，
                    // 归属于它的书签 / pin 在同一页里就要解析得出，否则 `classify` 用的是上一页
                    // 那一刻的表 ⇒ 停放一轮。
                    ownedMapsThisRound = nil
                    let ownedMaps = await ownedRoundMaps()
                    for registration in ownedKinds {
                        await retryParkedOwnedClaims(registration, maps: ownedMaps)
                    }
                    for (index, registration) in ownedKinds.enumerated() {
                        await applyOwnedKind(registration,
                                             batch: ownedBatches[registration.label] ?? OwnedPullBatch(),
                                             maps: ownedMaps)
                        // §12.2 Q-12：第 1 条 kind 落完、第 2 条还没跑 —— 「一页跨 kind 半落地」
                        // 的那个窗口。Release 里是空调用。
                        if index == 0 { abortIfRequested(.betweenKinds) }
                    }
                }
                // §12.2 Q-12：落地全部完成、marker 还没写。
                abortIfRequested(.afterApply)

                // ── 这一页的 marker。全页最后一次写（§2.5）──
                // 本页任何一次游标 / 表 / 映射 / marker 文件写失败 ⇒ 本页不推、本轮不发、前面各页
                // 保留（它们各自的 marker 早已落盘）。
                if cursorSaveFailures > 0 {
                    roundOutcome = .cursorSaveFailed
                    break pageLoop
                }
                // R-M3-4a-76：**内存里这个 marker 永远推进**（下一次请求带什么），与「要不要
                // 持久化」无关；抑制只作用在 storedMarker 上。
                marker = pageMarker
                if markerSuppression == .none {
                    if recordsGatedMarkerMoves, !markerMoveRecorded,
                       Self.normalizedMarker(marker) != markerAtEntry {
                        // A page that advanced the shared marker while the gate was shut.
                        // Recorded without inspecting its contents on purpose: deciding "did
                        // this page hold a Space?" needs a decrypt, and an entity this build
                        // cannot decrypt is exactly one of the things that gets missed.
                        //
                        // R-M3-4a-77：门关期间的重放标志**先落盘**，那次写确认之后才轮到
                        // `storedMarker`。反过来（marker 先落盘、标志后写）在「marker 写成、标志
                        // 写失败」下留下「marker 已推进、标志丢失」⇒ 下次开门两个析取项都不成立
                        // ⇒ 门关期间越过的页永久丢失。假阴不可逆，假阳只是一次重收。
                        guard mutateSpaceTable({ $0.markerMovedWhileGateShut = true }) else {
                            roundOutcome = .cursorSaveFailed
                            break pageLoop
                        }
                        markerMoveRecorded = true       // 只在那次写确认之后才置
                    }
                    // R-M3-4a-18：写的是 `marker.json`。
                    guard persistStoredMarker(marker) else {
                        roundOutcome = .cursorSaveFailed
                        break pageLoop
                    }
                    if storedMarker != markerAtEntry { roundMarkerAdvanced = true }
                }
            }
            drained = !more
            if !drained, pages >= Self.maxPullPages { roundOutcome = .pageBudgetExhausted }
            // 轮末的 drain 收尾。两条新前置（RR2-11）：抑制中的一轮没有把任何一页的 marker 落盘，
            // 它不能宣称 drain 完成；游标落盘失败的一轮同理。
            if spaceLive, drained, markerSuppression == .none, roundOutcome != .cursorSaveFailed {
                let stamped = mutateSpaceTable { table in
                    guard table.drainInProgress else { return }
                    table.drainInProgress = false
                    table.hasDrainedFullReplay = true
                    table.lastDrainedBirthday = storedBirthday
                }
                // 派生状态那次写失败也要被捕获（CASE B2-4b）：写口已经计数，这里只收口结局。
                if !stamped { roundOutcome = .cursorSaveFailed }
            }
        } catch PhiSyncProtocolError.notMyBirthday {
            // Nothing to flush: the store those pages came from is gone, and
            // `resetForNewStoreBirthday()` clears the Space table's server-side state and its
            // unreadable-tag record wholesale.
            roundOutcome = .notMyBirthday
            resetForNewStoreBirthday()
            guard retryOnBirthday else { return false }
            return await pull(retryOnBirthday: false, thenPush: thenPush)
        } catch {
            roundOutcome = .pullFailed
            AppLogError("[phi-sync] pull failed device=\(deviceKeyId) (\(PhiSyncLog.describe(error)))")
            // 逐页边界之后这里**尊重抑制状态、别的什么都不写**（R-M3-4a-47）：抛错只可能发生在
            // `getUpdates`，那时前面每一页都已经完整落地并推过自己的 marker，而抛错的这一页
            // 根本没到——没有什么需要停放或冲刷。marker 只越过已经完整落地的页；下面这一句留给
            // `drainInProgress` 仍然武装着、而本轮没能把 drain 走完的那些情形（计划裁定 10）：
            // 一次**从头开始**的 drain 被打断时，一个从推进过的 marker 续拉的后续轮次会到达
            // `drained == true` 并把 `hasDrainedFullReplay = true` 盖在洞上——从那一刻起
            // `applySpaceGate` 的两个析取项都再也不能重新武装重放（门没关过、drain 已「完成」），
            // 而归属 kind 的发布闸读的正是那个标志。丢掉 marker 让重放从头再来：`drainInProgress`
            // 刻意保持为真，所以中间没有任何一轮可以宣称 drain 完成，假阳的代价只是重读本机
            // 已经见过的页。
            if spaceLive, loadSpaceTable().drainInProgress {
                AppLogWarn("[phi-sync] a drain of data type \(PhiSyncEntity.dataTypeID) was interrupted; replaying it rather than resuming past the gap")
                storedMarker = nil
            }
            return false
        }

        // `.absent` 的轮级动作（R-M3-4a-38）：整条 drain 一页都没带设置实体。
        if !sawSettingsEntity, roundOutcome != .cursorSaveFailed {
            tombstoneRounds = 0
            if drained, startedFromScratch, storedEntityId != nil {
                // A full replay carried no settings entity: the row this device points at is
                // gone (a namespace change, a targeted delete, a partial restore). Keeping the
                // id would make every later commit an update the server answers with
                // INVALID_MESSAGE forever; dropping it lets the next push create instead.
                AppLogWarn("[phi-sync] full replay carried no settings entity; dropping the stale entity cursor")
                clearEntityCursor()
            }
        }
        if markerSuppression == .resetToNil {
            // 幂等：guard 2 那一支已经写过一次；`.unusable` 那一支在这里才第一次写。
            storedMarker = nil
            if roundOutcome == .ok, case .unusable = view { roundOutcome = .unusableSettings }
        }
        // The gated-off round's `markerMovedWhileGateShut` needs no write here: it was
        // persisted by the page that observed it, before that page's marker (R-M3-4a-77).

        // Publish whatever the merge left the server short of (a locally newer value, or a
        // registered key the remote entity did not carry). `push` decides by comparison, so a
        // pure remote apply commits nothing. Settings only: whether the Space section may
        // publish is its own question (§5.5 guard 1), and the two must not be able to silence
        // each other — an unreadable settings entity says nothing about the Spaces.
        // So the two halves are called separately here rather than through the `push` wrapper:
        // `maySettingsPublish == false` means "the SETTINGS row on the server is bytes this
        // build cannot read", and letting it gate the Space section too is exactly the coupling
        // §5.2 改动三 forbids. `pushSpaces` carries every Space-side guard of its own (the gate,
        // the drain, guard 3), so calling it unconditionally is safe — on a settings-only
        // engine (`spaceStore == nil`) it returns on its first line.
        //
        // 第三项是 B-2 的本地落盘闸（R-M3-4a-88 / 92）：三项各管一件互不相干的事，必须是合取
        // ——`drained` 回答「远端这一轮拿全了吗」，`!isStopped` 回答「这台机器还在这个账户上吗」，
        // `cursorSaveFailures == 0` 回答「本地这一轮落盘全成了吗」。落点必须是这一次赋值而不是
        // 下面那个 `if`：`pull` 的返回值就是这个布尔，`push(retryOnConflict:)` 与三条冲突重试
        // 都写成 `guard await pull(…) else { return }` 然后直接发布，五个发布入口查的也只是它。
        canPublishThisRound = drained && !isStopped && cursorSaveFailures == 0
        if thenPush, canPublishThisRound {
            if maySettingsPublish {
                await pushSettings(retryOnConflict: false)
            }
            await pushSpaces(retryOnConflict: false)
            // 归属 kind 的发布段排在 Space 之后（§5.2）。它自己带全部守卫（门、drain、
            // R-exec-3 的跳过），所以无条件调用是安全的；清单为空时第一行就返回。
            await pushOwnedItems(retryOnConflict: true)
        }

        if !drained, followUpRoundsUsed < Self.maxFollowUpRounds {
            // The page budget ran out with `changes_remaining` still set. Wait out the 60 s
            // timer and a first sync turns into minutes; the follow-up continues from the
            // marker this round already advanced.
            followUpRoundsUsed += 1
            Task { [weak self] in await self?.pullOnce() }
        } else if drained {
            followUpRoundsUsed = 0
        }
        return canPublishThisRound
    }

    /// What one pull collected for the Space section.
    private struct SpacePullBatch {
        var decoded: [(uuid: String, entity: Phi_PhiSpaceEntity, entityId: String, version: Int64)] = []
        var tombstones: [(uuid: String, entityId: String, version: Int64)] = []
        var unreadableHashes: [String] = []
        var unknownTombstoneHashes: [String] = []
    }

    /// Persists what this round's routing learned about entities the shared marker has
    /// already moved past. Called on the pull's tail *and* from its failure path, because the
    /// marker advance those observations describe is durable either way: a hash recorded only
    /// on the success path is lost by the throw that follows it, and nothing will ever deliver
    /// that entity again.
    private func flushSpaceObservations(_ batch: SpacePullBatch) {
        guard !batch.unreadableHashes.isEmpty else { return }
        let seenAt = now()
        mutateSpaceTable { table in
            for hash in batch.unreadableHashes { table.unreadableTagHashes[hash] = seenAt }
        }
    }

    /// `client_tag_hash -> space_uuid`, rebuilt once per pull. A tombstone carries no
    /// ciphertext and no `space_uuid`, and SHA1 is one-way, so a remote delete can only be
    /// identified by looking its hash up in a table this device builds from the uuids it
    /// already knows.
    ///
    /// D6：种子是**游标键 ∪ 映射表的值 ∪ 常量 `"default-space"`**。映射值那一项是
    /// 必须的：一个刚被向导映射、还没 commit 过的 Space 没有游标，而账户里那条实体
    /// 的 tombstone 随时可能先到。**本地 Space 列表不再进种子**——D6 之后它塞进去的
    /// 是永远不会出现在线上的本地 id，只会让索引变大且误导读者。
    private func spaceTagIndex(table: PhiSpaceSyncTable) async -> [String: String] {
        var uuids = Set(table.cursors.keys)
        uuids.insert(SyncableSpaces.defaultSpaceUuid)
        if let spaceAccess {
            for uuid in await spaceAccess.allSpaceMappings().values { uuids.insert(uuid) }
        }
        var index: [String: String] = [:]
        for uuid in uuids {
            index[PhiSyncEntity.clientTagHash(for: PhiSyncEntity.spaceClientTag(uuid))] = uuid
        }
        return index
    }

    /// §5.2 steps 2-5, in this exact order.
    private func routeSpaceEntity(_ entity: PhiRemoteEntity,
                                  key: SymmetricKey,
                                  tagIndex: [String: String],
                                  into batch: inout SpacePullBatch) {
        let shortHash = String(entity.clientTagHash.prefix(8))

        // 2. Tombstone FIRST, before any decrypt attempt. A deleted row's specifics are the
        // type's default value the server backfilled, so its ciphertext is empty and
        // decrypting it necessarily throws — routing it after the decrypt would classify every
        // remote delete as "unreadable" and, since the marker has already moved past this
        // page, lose it forever.
        guard !entity.deleted else {
            guard let uuid = tagIndex[entity.clientTagHash] else {
                // Nothing to hide: this device has neither the row nor a cursor, and the
                // server has already replaced the specifics, so no create for that row can
                // ever arrive again.
                AppLogInfo("[phi-sync] ignoring a tombstone for an unknown tag hash=\(shortHash)")
                batch.unknownTombstoneHashes.append(entity.clientTagHash)
                return
            }
            batch.tombstones.append((uuid: uuid, entityId: entity.entityId, version: entity.version))
            return
        }

        // 3. Decrypt.
        let decoded: Phi_PhiEntity
        do {
            decoded = try PhiEntityCodec.decrypt(entity.ciphertext, key: key)
        } catch {
            AppLogWarn("[phi-sync] cannot open a space entity tag=\(shortHash) ciphertext_bytes=\(entity.ciphertext.count) (\(PhiSyncLog.describe(error)))")
            batch.unreadableHashes.append(entity.clientTagHash)
            return
        }

        // 4. Unknown kind: ignore ONLY this entity. With two kinds live, a newer client's
        // third kind is normal traffic — the settings path's `.foreignPayload` reaction
        // (rewind the marker, drop the baseline, suppress the trailing push) would drag
        // settings down with it.
        guard case .space(let space)? = decoded.kind else { return }

        // 5. The payload must hash back to the tag it arrived under.
        let expected = PhiSyncEntity.clientTagHash(for: PhiSyncEntity.spaceClientTag(space.spaceUuid))
        guard expected == entity.clientTagHash else {
            AppLogError("[phi-sync] space payload does not hash back to its tag=\(shortHash)")
            batch.unreadableHashes.append(entity.clientTagHash)
            return
        }
        batch.decoded.append((uuid: space.spaceUuid, entity: space,
                              entityId: entity.entityId, version: entity.version))
    }

    // MARK: - Space apply (§6.2 A0-A3)

    /// Lands everything one pull collected. Never throws: a failed landing parks
    /// its entity and the round moves on.
    private func applySpaces(_ batch: SpacePullBatch, table: inout PhiSpaceSyncTable) async {
        guard !isStopped, let spaceAccess else { return }

        // §3.5 fallback A is transient by design. As soon as a held binding
        // resolves -- §3.6 created the profile, or a dead mapping was rebuilt --
        // re-land the baseline so the row actually moves onto that profile.
        // Without this the hold survives (no new entity for that uuid will ever
        // arrive: the shared marker has moved past it) and the Space stays bound
        // to the wrong profile forever.
        //
        // These entities go to the loop below DIRECTLY rather than through
        // `cursor.pendingApply`, and carry `fromServer: false`. A re-park is this
        // device's own baseline, NOT something the server sent, and `pendingApply`
        // holds bytes with no room for that distinction. Landing one must
        // therefore leave `server` alone: recording the local baseline as "what
        // the server holds" makes `spaceCommitEntries`' `toSend == server`
        // permanently true for every field this device still owes the account,
        // and the owed value is never published again.
        var reparked: [String: Phi_PhiSpaceEntity] = [:]
        for (uuid, cursor) in table.cursors {
            guard let held = cursor.heldProfileUuid,
                  cursor.pendingApply == nil,
                  let bytes = cursor.reconciled,
                  let entity = try? Phi_PhiSpaceEntity(serializedBytes: bytes),
                  await spaceAccess.localProfileId(forGlobalUuid: held) != nil else { continue }
            reparked[uuid] = entity
        }

        // Everything parked earlier is retried alongside this round's arrivals,
        // oldest cursor first so ordering is device-independent.
        var pending: [(uuid: String, entity: Phi_PhiSpaceEntity, entityId: String,
                       version: Int64, fromServer: Bool)] = []
        for (uuid, cursor) in table.cursors.sorted(by: { $0.key < $1.key }) {
            if let entity = reparked[uuid] {
                pending.append((uuid: uuid, entity: entity, entityId: cursor.entityId ?? "",
                                version: cursor.version, fromServer: false))
                continue
            }
            guard let bytes = cursor.pendingApply,
                  let entity = try? Phi_PhiSpaceEntity(serializedBytes: bytes) else { continue }
            pending.append((uuid: uuid, entity: entity, entityId: cursor.entityId ?? "",
                            version: cursor.version, fromServer: true))
        }
        let incoming = batch.decoded.sorted { $0.uuid < $1.uuid }
            .map { (uuid: $0.uuid, entity: $0.entity, entityId: $0.entityId,
                    version: $0.version, fromServer: true) }
        let all = pending.filter { p in !incoming.contains { $0.uuid == p.uuid } } + incoming

        // Capture actual local edits before any incoming entity changes the rows or their
        // order. Merging the old reconciled bytes alone would erase an unpublished rename,
        // rebind, or drag during the pull that now precedes every local push.
        var localProjections: [String: Phi_PhiSpaceEntity] = [:]
        if !all.isEmpty {
            let spaces = await spaceAccess.currentSpaces()
            var uuidBySpace: [String: String] = [:]
            var uuidByProfile: [String: String] = [:]
            for space in spaces {
                uuidBySpace[space.spaceId] = await spaceAccess.syncUuid(forSpaceId: space.spaceId)
                if uuidByProfile[space.profileId] == nil {
                    uuidByProfile[space.profileId] = await spaceAccess.globalUuid(forProfileId: space.profileId)
                }
            }
            var projectionTable = table
            var withHistory: Set<String> = []
            for (uuid, cursor) in table.cursors {
                guard let bytes = cursor.reconciled,
                      (try? Phi_PhiSpaceEntity(serializedBytes: bytes)) != nil else { continue }
                withHistory.insert(uuid)
                // Publication still rejects parked rows. Their local edits participate in
                // reconciliation once a baseline exists; first adoption stays wholesale.
                projectionTable.cursors[uuid]?.pendingApply = nil
            }
            localProjections = SyncableSpaces.snapshot(spaces: spaces, table: projectionTable,
                                                       globalUuid: { uuidByProfile[$0] },
                                                       syncUuid: { uuidBySpace[$0] }, now: now())
                .filter { withHistory.contains($0.key) }
        }

        var landedAny = false
        for item in all {
            guard !isStopped else { return }
            var cursor = table.cursors[item.uuid] ?? PhiSpaceCursor()
            // R12: every Space log line names the entity by its client tag hash
            // prefix, never by the `space_uuid` it was derived from.
            let tag = PhiSyncEntity.clientTagHash(for: PhiSyncEntity.spaceClientTag(item.uuid))

            // §6.5: refuse to materialize agent / incognito payloads. Refusing is
            // NOT a claim the account should not hold it, so no tombstone is ever
            // pushed back; `refusedAtMs` only stops the re-decrypt every round.
            if SyncableSpaces.refuses(item.entity) {
                cursor.refusedAtMs = now()
                cursor.pendingApply = nil
                table.cursors[item.uuid] = cursor
                spaceCounters.refused += 1
                continue
            }
            // A soft-deleted uuid is never resurrected by a replayed create.
            if cursor.deletedAtMs != nil { cursor.pendingApply = nil; table.cursors[item.uuid] = cursor; continue }
            if cursor.pendingDelete {
                // A local deletion wins over a concurrent live update. Learn the current
                // server version for its tombstone without recreating the deleted local row.
                if !item.entityId.isEmpty { cursor.entityId = item.entityId }
                cursor.version = max(cursor.version, item.version)
                cursor.pendingApply = nil
                table.cursors[item.uuid] = cursor
                table.unreadableTagHashes.removeValue(forKey: tag)
                continue
            }

            // A0: resolve the binding. From Task 11 on the mapping is refreshed
            // earlier in the SAME round (§5.2), so a Space bound to a profile the
            // peer just created lands without waiting for the next one.
            let isDefault = item.uuid == SyncableSpaces.defaultSpaceUuid
            // D6：把线上 uuid 翻成本机的行 id。解析不到 = 账户里有、本机没有，
            // 落地时新建一行并回写映射（R-D6-7）。
            var localSpaceId = await spaceAccess.localSpaceId(forSyncUuid: item.uuid)
            // 默认 Space 的身份是 resolver 里的常量分支（SpaceSyncMappingManager.swift:53-60），
            // 没有映射行可丢；对它跑自愈只会把它当成新 Space 重铸一个本地 id。
            if !isDefault, let resolved = localSpaceId, await !spaceAccess.isKnownLocalSpace(resolved) {
                // 死映射：反查命中，但本地那一行已经没了（用户删了 Space 而清理路径
                // 被打断）。就地丢掉并按「无映射」处理，下一轮当作新 Space 落地。
                // 第二个同样可达的成因：映射先行的 create 在两次写之间死掉（R-M3-4a-87，
                // 下面 create 支的新块），留下的悬空映射走同一条出口——R-87 的整条可恢复性
                // 压在这一段上，它不是一条只服务于删除路径的补丁，重构时不可顺手删掉。
                // 形状与 profile 侧的 A0 逐字对应。
                AppLogInfo("[phi-sync] dropping a dead space mapping; the entity will land as a new Space")
                await spaceAccess.dropSpaceMapping(forSpaceId: resolved)
                localSpaceId = nil
            }
            var profileId: String?
            if !isDefault {
                let remoteUuid = item.entity.profileUuid.stringValue
                profileId = await spaceAccess.localProfileId(forGlobalUuid: remoteUuid)
                if let resolved = profileId, await !spaceAccess.isKnownLocalProfile(resolved) {
                    // A DEAD MAPPING: the reverse lookup resolved, but the local
                    // Chromium profile behind it was deleted (§3.6's "唯一的例外,
                    // 也是死映射的唯一自愈路径"). The criterion has to be "is it
                    // still in `userAssignableProfiles`" -- asking
                    // `globalUuid(forProfileId:)` would read back the very mapping
                    // the reverse lookup just resolved FROM and always say yes,
                    // i.e. never fire.
                    //
                    // Drop the entry here and treat the binding as unresolved.
                    // Next round §3.6's `missing` set contains that uuid again and
                    // rebuilds the profile under its registered name; without the
                    // drop, every landing throws on a profileId that no longer
                    // exists, the entity parks forever, and `parked` sits non-zero
                    // with no self-heal path at all.
                    AppLogInfo("[phi-sync] dropping a dead profile mapping; the account profile will be rebuilt next round")
                    await spaceAccess.dropMapping(forProfileId: resolved)
                    profileId = nil
                }
                if profileId == nil {
                    if cursor.reconciled == nil {
                        // Fallback B: never a row, never a baseline, never
                        // `refusedAtMs` -- park the whole entity and retry.
                        cursor.pendingApply = try? item.entity.serializedData()
                        cursor.entityId = item.entityId.isEmpty ? cursor.entityId : item.entityId
                        cursor.version = max(cursor.version, item.version)
                        table.cursors[item.uuid] = cursor
                        continue
                    }
                    // Fallback A: already landed. Keep the local binding, record
                    // the remote value, and echo it back with the BASELINE's
                    // timestamp (see `SyncableSpaces.snapshot`) so this device
                    // neither wins the field nor pings the binding back and forth.
                    // The local profile the hold is taken against is recorded with
                    // it: a later LOCAL rebind must be publishable (§3.5).
                    cursor.heldProfileUuid = remoteUuid
                    cursor.heldForLocalProfileId =
                        await spaceAccess.currentSpaces().first { $0.spaceId == localSpaceId }?.profileId
                } else {
                    // The binding resolves: any hold is obsolete. Clearing it here
                    // is the other half of §3.5 -- a stale hold would keep winning
                    // the snapshot's held branch over the mapping-derived value.
                    cursor.heldProfileUuid = nil
                    cursor.heldForLocalProfileId = nil
                }
            }

            // A1: no baseline -> adopt wholesale. A device with no timestamp
            // history that merged field by field would stamp its factory defaults
            // `now` and push them over the account's real values.
            let existing = await spaceAccess.currentSpaces().first { $0.spaceId == localSpaceId }
            let merged: Phi_PhiSpaceEntity
            if let bytes = cursor.reconciled,
               let baseline = try? Phi_PhiSpaceEntity(serializedBytes: bytes) {
                merged = SyncableSpaces.merge(local: localProjections[item.uuid] ?? baseline, remote: item.entity)
            } else {
                merged = item.entity
            }
            if !isDefault, merged.profileUuid.stringValue != item.entity.profileUuid.stringValue {
                // Resolve the winning binding, not the remote binding examined above.
                profileId = await spaceAccess.localProfileId(forGlobalUuid: merged.profileUuid.stringValue)
                if profileId != nil {
                    cursor.heldProfileUuid = nil
                    cursor.heldForLocalProfileId = nil
                }
            }

            // R-M3-4a-87：create 支的两次写反序、映射先行。行在 SwiftData、映射在账户
            // plist，两个 store 之间没有事务（§2.6），所以这里要的不是原子性而是可恢复性：
            // 留下的唯一中间态是「映射已写、行未建」，由上面 A0 段的死映射自愈收口。
            // 本机 id 在这里预铸（形状同 SpaceManager.swift:960），`land` 一行不改——
            // 它的 create 支本来就接受显式 id（SyncableSpaces.swift:514）。
            // `!isDefault` 与 A0 的守卫同形：默认 Space 的 `localSpaceId` 永不为 nil，写出来
            // 是为了挡住 `map` 的 `defaultSpaceIsImplicit`——否则默认 Space 每轮停放。
            if localSpaceId == nil, !isDefault {
                let newId = UUID().uuidString
                do {
                    try await spaceAccess.mapSpace(newId, toSyncUuid: item.uuid)
                } catch {
                    AppLogWarn("[phi-sync] could not map a new space tag=\(String(tag.prefix(8))) (\(PhiSyncLog.describe(error)))")
                    // 第四个 `cursorSaveFailed` 置位点（计划裁定 7 / §13.2）：映射不走
                    // `writeSpaceTable` 那条链，它的落盘失败面是 Task 2a 的 `persistFailed`
                    // （抛出后 store 已回滚，盘上零映射、零行，`land` 还没被调到）。其余映射
                    // 错误是裁决，不是落盘失败，只停放不计。
                    if (error as? SpaceSyncMappingError) == .persistFailed { cursorSaveFailures += 1 }
                    if item.fromServer {
                        cursor.pendingApply = try? item.entity.serializedData()
                        table.cursors[item.uuid] = cursor
                    }
                    continue
                }
                localSpaceId = newId
            }

            // A2 + A3: land in order, await every step, and only THEN write the
            // baselines. The reverse order leaves the shadow ahead of the row and
            // the next snapshot stamps the stale value `now` for the whole account.
            let landed: String
            do {
                landed = try await SyncableSpaces.land(merged, existing: existing,
                                                       localSpaceId: localSpaceId,
                                                       profileId: profileId, access: spaceAccess)
            } catch {
                AppLogWarn("[phi-sync] space landing failed tag=\(String(tag.prefix(8))) (\(PhiSyncLog.describe(error)))")
                // A re-parked baseline is deliberately NOT written to
                // `pendingApply`: next round it would be indistinguishable from a
                // server entity and would be recorded as `server` on the retry.
                // Discarding this round's cursor edits instead leaves the hold
                // exactly as it was, so the re-park pass above picks it up again.
                if item.fromServer {
                    cursor.pendingApply = try? item.entity.serializedData()
                    table.cursors[item.uuid] = cursor
                }
                continue
            }
            guard !isStopped else { return }

            // §5.6 again, for the one write that can report success without
            // having happened: `SpaceManager.applyRemoteRebind` optional-chains
            // through `boundAccount`, so a nil account returns normally and
            // writes nothing, and `prepareProfileChange` is documented to refuse
            // silently (an import in flight, an agent Space) with "the entity is
            // retried next round" -- which is only true if this round declines to
            // write a baseline. Verify the field that has that out-of-band
            // refusal path rather than trusting the return, and park otherwise.
            if !isDefault, let profileId, let existing, existing.profileId != profileId,
               await spaceAccess.currentSpaces().first(
                   where: { $0.spaceId == landed })?.profileId != profileId {
                AppLogWarn("[phi-sync] space rebind did not take effect tag=\(String(tag.prefix(8))); parking the entity")
                if item.fromServer {   // same reason as the landing-failure park above
                    cursor.pendingApply = try? item.entity.serializedData()
                    table.cursors[item.uuid] = cursor
                }
                continue
            }

            cursor.reconciled = try? merged.serializedData()
            // `remote`, NOT `merged`: this is "what the server holds", the
            // comparison that decides whether anything still needs publishing.
            // And only for an entity that actually CAME from the server: the
            // held re-park above re-lands this device's own baseline, which says
            // nothing about the server's copy and must leave it untouched.
            if item.fromServer { cursor.server = try? item.entity.serializedData() }
            if !item.entityId.isEmpty { cursor.entityId = item.entityId }
            cursor.version = max(cursor.version, item.version)
            cursor.pendingApply = nil
            table.cursors[item.uuid] = cursor
            table.unreadableTagHashes.removeValue(forKey: tag)
            landedAny = true
            spaceCounters.applied += 1
        }

        // One account-wide reorder after every entity landed (§7).
        if landedAny {
            // D6 的翻译点在这里，不在 `plannedOrder` 里：`ranks` 由游标键构建
            // （syncUuid），而 `plannedOrder` 拿 `syncedRanks[spaceId]` 与**本地** id
            // 比。半翻译是静默失效——每次查表都是 nil，账户级重排整体变成 no-op。
            var ranks: [String: String] = [:]
            for (uuid, cursor) in table.cursors {
                guard cursor.hidden == false, cursor.deletedAtMs == nil,
                      let bytes = cursor.reconciled,
                      let entity = try? Phi_PhiSpaceEntity(serializedBytes: bytes) else { continue }
                guard let local = await spaceAccess.localSpaceId(forSyncUuid: uuid) else { continue }
                // A locally dragged sibling may have no incoming entity in this pull. Its
                // current rank must participate without advancing its unsent baseline.
                let projected = localProjections[uuid].map { SyncableSpaces.merge(local: $0, remote: entity) }
                ranks[local] = (projected ?? entity).rank.stringValue
            }
            // `allSpacesForOrdering()`, NOT `currentSpaces()`: the result goes
            // straight to `LocalStore.reorderSpaces`, which renumbers exactly the
            // ids it is given and leaves every other row's `sortOrder` untouched.
            // Handing it the §6.5-filtered view would renumber the synced Spaces
            // 0..n-1 while agent Spaces and Spaces on unmapped profiles kept stale
            // values and interleaved arbitrarily -- the opposite of §7's "keep
            // their own slots".
            let order = SyncableSpaces.plannedOrder(
                localOrder: await spaceAccess.allSpacesForOrdering(), syncedRanks: ranks)
            try? await spaceAccess.applyOrder(order)
        }
    }

    /// Remote deletes (§9.2): the pull routes them into `batch.tombstones` and
    /// this is where they are hidden locally and the cursor becomes a tombstone
    /// record.
    ///
    /// A remote delete is a first-class product event for Spaces, not the hazard
    /// the settings path treats it as: no `tombstoneRounds`, no three-round heal,
    /// no suppression of the trailing push.
    private func applySpaceTombstones(_ batch: SpacePullBatch, table: inout PhiSpaceSyncTable) async {
        guard !isStopped, let spaceAccess else { return }
        // Everything deferred by an import lock is retried alongside this round's
        // arrivals: the shared marker has already moved past those pages, so the
        // same tombstone will never be delivered again.
        var work = batch.tombstones
        for (uuid, cursor) in table.cursors.sorted(by: { $0.key < $1.key })
        where cursor.pendingTombstone && !work.contains(where: { $0.uuid == uuid }) {
            work.append((uuid: uuid, entityId: cursor.entityId ?? "", version: cursor.version))
        }

        for item in work {
            guard !isStopped else { return }
            // D1: the default Space cannot be deleted locally (`deleteSpace`
            // refuses at SpaceManager.swift:1362) and by definition cannot be
            // deleted remotely either. `item.uuid` is a syncUuid, so the constant
            // it is compared against is the syncUuid-space one (§2.4).
            guard item.uuid != SyncableSpaces.defaultSpaceUuid else {
                AppLogInfo("[phi-sync] ignoring a tombstone for the default Space")
                continue
            }
            var cursor = table.cursors[item.uuid] ?? PhiSpaceCursor()
            if let entityId = cursor.entityId, !item.entityId.isEmpty, entityId != item.entityId {
                // The server never rewrites `client_tag_hash` on an update
                // (`internal/data/entities_write.go:243-244`), so the hash is the
                // stable identity and the id is only a cross-check.
                AppLogError("[phi-sync] tombstone entity id disagrees with the cursor; trusting the tag hash")
            }
            guard cursor.deletedAtMs == nil else {
                cursor.pendingTombstone = false
                table.cursors[item.uuid] = cursor
                continue
            }

            // D6：先把线上 uuid 翻成本机的行 id。**解析不到就跳过导入锁检查与
            // hide**，直接走游标收尾——账户里那条确实被删了，这台机器只是本来就没有
            // 它，游标必须记住，否则同一条实体的 create 重放会把它复活。
            let localSpaceId = await spaceAccess.localSpaceId(forSyncUuid: item.uuid)
            if let localSpaceId {
                if await spaceAccess.isImporting(intoSpaceId: localSpaceId) {
                    // No modal: nobody is there to see it. Persist the intent instead.
                    cursor.pendingTombstone = true
                    table.cursors[item.uuid] = cursor
                    continue
                }
                do {
                    // Windows first, so a window parked on this Space retreats along
                    // the existing fallback path instead of vanishing under the user.
                    try await spaceAccess.hide(spaceId: localSpaceId)
                } catch {
                    cursor.pendingTombstone = true
                    table.cursors[item.uuid] = cursor
                    continue
                }
            }
            // R-D6-10：**这里不删映射行**。远端软删保留映射——它是那 30 天里「这一行
            // 属于账户的哪条实体」的唯一记录，也是 `snapshot` 的 eligible 过滤能把这
            // 一行排除在外的唯一依据；30 天清理成功之后才删（`applyRetentionSweep`）。
            cursor.hidden = true
            cursor.deletedAtMs = now()
            cursor.pendingTombstone = false
            // The landing is TERMINAL for this uuid, so it writes the same
            // finished state §6.2 writes for a tombstone of our own: a local
            // delete queued a moment earlier (`recordLocalDeletion`) is owed to
            // nobody now that the account already holds the tombstone.
            // `spaceCommitEntries` unions EVERY `pendingDelete` cursor into the
            // next batch, so a flag left standing here ships a redundant
            // `deleted: true` commit whose `.applied` outcome re-stamps
            // `deletedAtMs = now()` -- restarting §9.2's 30-day window from the
            // echo instead of from the delete.
            cursor.pendingDelete = false
            cursor.deleteRejectRounds = 0
            cursor.pendingApply = nil
            cursor.heldProfileUuid = nil
            cursor.heldForLocalProfileId = nil
            if !item.entityId.isEmpty { cursor.entityId = item.entityId }
            cursor.version = max(cursor.version, item.version)
            table.cursors[item.uuid] = cursor
            spaceCounters.applied += 1   // §11: a remote soft delete is a landing
            // A soft delete IS a successful interpretation of that tag.
            table.unreadableTagHashes.removeValue(forKey:
                PhiSyncEntity.clientTagHash(for: PhiSyncEntity.spaceClientTag(item.uuid)))
            // Deliberately silent: a local delete has a confirmation dialog, a
            // remote one has no alert, no toast and no hint. And no data is
            // touched -- SpaceModel, bookmarks, pin tabs, URL rules and both theme
            // maps stay on disk for the whole retention window.
            AppLogInfo("[phi-sync] space soft-deleted by a remote tombstone")
        }
    }

    /// Records a pull that could not read the account's entity, and — for a tombstone only —
    /// arms the heal once the row has been gone for `tombstoneHealAfterRounds` consecutive
    /// pulls. Arming just drops the entity cursor: this never publishes anything, so a
    /// deliberate deletion survives until some device actually changes a setting, and only then
    /// does the commit go out as a create (`baseVersion = 0`, no entity id) that the server
    /// resolves through its `ON CONFLICT (client_tag_hash) DO UPDATE` path.
    ///
    /// Logged at error level: both refusals leave settings sync dead for the whole account, and
    /// `AppLogWarn`/`AppLogError` are the only levels that reach the shipped log file (release
    /// installs the loggers at `.info`, `Logging.swift`), so this is the one support-visible
    /// trace of a state the user cannot see or fix.
    private func noteUnusable(_ reason: UnusableReason) {
        guard reason == .tombstone else {
            // Real content this build must not overwrite; nothing here may re-create it, and a
            // non-tombstone round breaks the streak.
            tombstoneRounds = 0
            AppLogError("[phi-sync] settings entity is unusable (\(reason.rawValue)); not applying it and not publishing over it")
            return
        }
        let rounds = tombstoneRounds + 1
        tombstoneRounds = rounds
        guard rounds >= Self.tombstoneHealAfterRounds else {
            AppLogWarn("[phi-sync] settings entity is a tombstone (round \(rounds)/\(Self.tombstoneHealAfterRounds)); not applying it and not publishing over it")
            return
        }
        AppLogError("[phi-sync] settings entity has been a tombstone for \(rounds) consecutive pulls; dropping the entity cursor so the next local change re-creates it")
        clearEntityCursor()
    }

    private func apply(_ remote: Phi_PhiSettingEntity, adopt: Bool) {
        // A retired engine decrypted these settings with the signed-out account's domain key;
        // writing them now would hand the account mounted next the previous account's values.
        // This entry check only saves the merge work — `shutdown()` is concurrent with this
        // round, so what actually stops the writes is the check each of them makes for itself
        // (`snapshotLocalSettings`, `writeSettings`, `writeState`).
        guard !isStopped else { return }
        // A device with no settings history has no timestamps to compare against: every key it
        // snapshots would be stamped `now` and beat the account's real edits. So the first pull
        // adopts the account's entity wholesale; later pulls merge field by field.
        let merged: Phi_PhiSettingEntity
        if adopt {
            merged = remote
        } else {
            guard let local = snapshotLocalSettings() else { return }
            merged = SyncableSettings.merge(local: local, remote: remote)
        }

        guard writeSettings(merged) else { return }

        // What the server holds, not what we now hold locally: `push` compares against this to
        // decide whether anything still needs publishing.
        storedLastEntity = remote
        // `apply` leaves a `<key>.phiSyncTs` sidecar behind for every key it wrote, so from
        // here on this device has timestamps a merge can compare — no later pull may adopt.
        hasAdopted = true
        AppLogInfo("[phi-sync] applied remote settings keys=\(merged.values.count)")
    }

    // MARK: - Push

    /// Pull first, then publish settings, Spaces, and owned items. The publishers stay
    /// independent when settings are unchanged or unreadable, but share the pull prerequisite.
    ///
    /// The two must be siblings rather than one appended to the other. Every
    /// early return in `pushSettings` is a statement about the SETTINGS entity,
    /// and one of them is the steady state: `if let last, outgoing == last` fires
    /// on almost every round, because the user changed a Space and not a setting.
    /// A Space push hanging off the end of that function would therefore never
    /// run in exactly the case it exists for (§5.2 改动三).
    private func push(retryOnConflict: Bool) async {
        guard await pull(retryOnBirthday: true, thenPush: false) else { return }
        await pushSettings(retryOnConflict: retryOnConflict)
        await pushSpaces(retryOnConflict: retryOnConflict)
        await pushOwnedItems(retryOnConflict: retryOnConflict)
    }

    /// Publishes settings after this round's shared pull prerequisite.
    private func pushSettings(retryOnConflict: Bool) async {
        guard !isStopped, canPublishThisRound else { return }

        // A round that knows the server holds bytes it could not decode must not overwrite
        // them. `storedLastEntity` is the decrypted baseline of what the server has; an entity
        // id with no baseline means the last pull saw the entity but could not read it (bad
        // key, foreign payload, tombstone — that pull drops the baseline precisely so this
        // guard fires; a tombstone that has outlasted `tombstoneHealAfterRounds` pulls drops
        // the id too, so this guard lets that one create), or the baseline was lost with the
        // process. Committing here would
        // replace the entire entity — every key, including a newer client's — with this
        // device's snapshot. Rewind the marker so the next pull re-reads the entity and can
        // re-establish the baseline.
        //
        // This returns before `SyncableSettings.snapshot` runs, so a local change made while
        // the entity is unreadable leaves no `<key>.phiSyncTs` sidecar and never sets
        // `hasAdopted`. That is deliberate, and it has a cost on the one device that has no
        // other settings history — see `hasAdopted` for the window and why stamping here would
        // lose more than it saves.
        if storedEntityId != nil, storedLastEntity == nil {
            AppLogWarn("[phi-sync] push skipped: no readable baseline for the settings entity the server holds")
            storedMarker = nil
            return
        }

        let key: SymmetricKey
        do {
            key = try await domainKeys.domainKey()
        } catch {
            AppLogWarn("[phi-sync] push skipped: domain key unavailable (\(PhiSyncLog.describe(error)))")
            return
        }
        // Nothing below suspends before `client.commit`, so this check is the last thing that
        // can keep a retired round from publishing the signed-out account's settings — the
        // token provider behind the client now mints the *new* account's bearer token. It
        // cannot be airtight (a `shutdown()` landing between here and URLSession's send is not
        // seen), which `shutdown()` documents; what it does rule out is a round that resumed
        // from the network long after sign-out going on to commit.
        guard !isStopped, canPublishThisRound else { return }

        let last = storedLastEntity
        // A snapshot is a write too — it stamps the sidecars — so it makes its own check.
        guard let local = snapshotLocalSettings() else { return }
        // Merging against the last known server entity keeps keys this build does not know
        // about (a newer client's settings) instead of deleting them on every push.
        let outgoing = SyncableSettings.merge(local: local, remote: last ?? Phi_PhiSettingEntity())
        if let last, outgoing == last { return }

        var wrapper = Phi_PhiEntity()
        wrapper.setting = outgoing

        do {
            let ciphertext = try PhiEntityCodec.encrypt(wrapper, key: key)
            // The settings entity is still exactly one entry: a one-element batch, committed
            // under `phi-settings` as before. `name` moved from the client into the entry, so
            // it is spelled out here rather than defaulted.
            let outcomes = try await client.commit(entries: [
                PhiCommitEntry(entityId: storedEntityId,
                               clientTagHash: PhiSyncEntity.settingsClientTagHash,
                               name: PhiSyncEntity.clientTag,
                               ciphertext: ciphertext,
                               deleted: false,
                               baseVersion: storedVersion ?? 0),
            ], storeBirthday: storedBirthday)
            guard !isStopped else { return }
            guard let outcome = outcomes.first else {
                throw PhiSyncProtocolError.malformedResponse
            }
            switch outcome {
            case .applied(let entityId, let version, let storeBirthday):
                if !entityId.isEmpty { storedEntityId = entityId }
                storedVersion = version
                storedBirthday = storeBirthday
                storedLastEntity = outgoing
                // Whatever the row was before, it now holds bytes this device wrote and can
                // read: any tombstone streak is over.
                tombstoneRounds = 0
                // A published snapshot is settings history too — `SyncableSettings.snapshot`
                // stamped a sidecar timestamp for every registered key on the way here, and
                // those are exactly what a later merge compares against.
                hasAdopted = true
                AppLogInfo("[phi-sync] pushed settings keys=\(outgoing.values.count) version=\(version)")
            case .conflict(let serverVersion):
                guard retryOnConflict else {
                    AppLogWarn("[phi-sync] commit still conflicting server_version=\(serverVersion.map(String.init) ?? "unknown"); abandoning this round")
                    return
                }
                guard await pull(retryOnBirthday: true, thenPush: false) else { return }
                // `pushSettings`, not `push`: this retry is the settings entity's
                // own, and the Space half of this round has not run yet.
                await pushSettings(retryOnConflict: false)
            case .invalidMessage:
                // The same rejection as the `commitRejected(.invalidMessage)` catch below, only
                // reported per entry instead of thrown for the whole batch. Both paths exist:
                // a peer that fails the round still throws.
                dropTheEntityCursorAfterInvalidMessage()
            case .rejected(let responseType):
                AppLogError("[phi-sync] commit rejected response_type=\(responseType); abandoning this round")
                return
            }
        } catch PhiSyncProtocolError.notMyBirthday {
            resetForNewStoreBirthday()
        } catch PhiSyncProtocolError.commitRejected(.invalidMessage) {
            dropTheEntityCursorAfterInvalidMessage()
        } catch {
            AppLogError("[phi-sync] push failed device=\(deviceKeyId) (\(PhiSyncLog.describe(error)))")
        }
    }

    /// INVALID_MESSAGE on the settings commit, however it was reported — as this batch entry's
    /// outcome, or as a thrown `commitRejected(.invalidMessage)` for the whole round.
    ///
    /// The server could not find the row this commit names: the update path returns
    /// INVALID_MESSAGE on pgx.ErrNoRows and on a data_type mismatch
    /// (internal/data/entities_write.go), and NOT_MY_BIRTHDAY never fires because the
    /// account row — and with it store_birthday — is untouched. An incremental
    /// GetUpdates cannot tell us either: it simply returns nothing. Without dropping the
    /// cursor the device would send the same stale id and version forever and never sync
    /// again. Drop the row identity and the marker so the next round replays the type
    /// from scratch and either re-discovers the entity or creates it through the
    /// client_tag_hash unique index.
    ///
    /// `clearRemoteCursor()`, never `resetSyncState()`: the account is unchanged, and
    /// the snapshot taken a few statements above has just stamped `now` on the key the
    /// user edited. Clearing `hasAdopted` here would make the very next pull adopt a
    /// peer's entity wholesale over that edit — and, because `apply` also writes the
    /// remote timestamp into the key's sidecar, the edit would never be re-pushed
    /// either. That is the same distinction the `.absent` full-replay branch makes.
    private func dropTheEntityCursorAfterInvalidMessage() {
        AppLogWarn("[phi-sync] commit rejected as INVALID_MESSAGE; dropping the entity cursor and the marker so the next round rediscovers the entity")
        clearRemoteCursor()
    }

    // MARK: - Space push (§5.1 / §5.5 guard 3 / §9.1)

    /// Assembles this round's Space commit batch. Returns the uuid alongside each
    /// entry so per-entry outcomes can be applied without re-deriving anything.
    private func spaceCommitEntries(
        from table: PhiSpaceSyncTable,
        outgoing: [String: Phi_PhiSpaceEntity]
    ) -> [(uuid: String, entry: PhiCommitEntry, outgoing: Phi_PhiSpaceEntity?)] {
        var result: [(uuid: String, entry: PhiCommitEntry, outgoing: Phi_PhiSpaceEntity?)] = []
        for uuid in Set(outgoing.keys).union(table.cursors.filter { $0.value.pendingDelete }.keys).sorted() {
            let cursor = table.cursors[uuid]
            let tagHash = PhiSyncEntity.clientTagHash(for: PhiSyncEntity.spaceClientTag(uuid))

            // Guard 3 (§5.5): the server holds a row under this tag that this
            // build cannot read. A create would take the server's
            // `ON CONFLICT (client_tag_hash) DO UPDATE` path, which has NO version
            // check, and overwrite it irrecoverably -- not a delete, so M1's
            // 30-day window does not apply either.
            guard table.unreadableTagHashes[tagHash] == nil else {
                AppLogWarn("[phi-sync] refusing to commit over an unreadable row tag=\(String(tagHash.prefix(8)))")
                continue
            }

            if let cursor, cursor.pendingDelete {
                // §9.1's second gate: a tombstone with no entityId / version 0 is
                // illegal server-side and can only loop.
                guard let entityId = cursor.entityId, cursor.version > 0 else { continue }
                result.append((uuid: uuid,
                               entry: PhiCommitEntry(entityId: entityId, clientTagHash: tagHash,
                                                     name: PhiSyncEntity.spaceEntityName,
                                                     ciphertext: nil, deleted: true,
                                                     baseVersion: cursor.version),
                               outgoing: nil))
                continue
            }

            guard let snapshot = outgoing[uuid] else { continue }
            // Merge against what the server holds so a newer client's reserved
            // fields 11-14 survive a round trip through this build.
            var toSend = snapshot
            if let bytes = cursor?.server,
               let server = try? Phi_PhiSpaceEntity(serializedBytes: bytes) {
                toSend = SyncableSpaces.merge(local: snapshot, remote: server)
                if toSend == server { continue }   // nothing to publish
            }
            result.append((uuid: uuid,
                           entry: PhiCommitEntry(entityId: cursor?.entityId, clientTagHash: tagHash,
                                                 name: PhiSyncEntity.spaceEntityName,
                                                 ciphertext: nil, deleted: false,
                                                 baseVersion: cursor?.version ?? 0),
                           outgoing: toSend))
        }
        return result
    }

    /// `onlyUuids == nil` publishes everything this round's snapshot produced;
    /// a non-nil set restricts the batch to those uuids, which is what the
    /// CONFLICT retry passes so one conflicting Space cannot drag the other
    /// twenty back through the wire.
    private func pushSpaces(retryOnConflict: Bool, onlyUuids: Set<String>? = nil) async {
        guard !isStopped, canPublishThisRound, spaceSectionEnabled, let spaceAccess, spaceStore != nil else { return }
        // The one Space read-modify-write that is not a `mutateSpaceTable` delta,
        // for the same reason as the apply path's: per-entry outcomes have to be
        // carried across the batch loop's suspension points. Safe here because
        // EVERY writer of this table is a round (`recordLocalDeletion` included)
        // and rounds are serialized, and because `pushSpaces` is the last Space
        // work of the round -- `applySpaces` has already written by the time
        // this loads.
        var table = loadSpaceTable()
        // Guard 1: not one commit -- tombstones included -- until a full replay
        // has finished, or a device that has not seen the account's Spaces yet can
        // overwrite `default-space` with its factory defaults.
        guard table.hasDrainedFullReplay else {
            if table.drainInProgress {
                AppLogInfo("[phi-sync] space push held: drain_in_progress")
            }
            return
        }

        let spaces = await spaceAccess.currentSpaces()
        guard !isStopped else { return }
        var uuidByProfile: [String: String] = [:]
        for space in spaces {
            if uuidByProfile[space.profileId] == nil {
                uuidByProfile[space.profileId] = await spaceAccess.globalUuid(forProfileId: space.profileId)
            }
        }
        // R-D6-7 的懒铸造。`currentSpaces()` 已经在源头排除 incognito / 两种 agent
        // 特征 / profile 未映射的 Space，所以这里铸的每一个 uuid 都属于一个该发布的
        // Space。铸造失败（`alreadyMapped` 不可能，`defaultSpaceIsImplicit` 由
        // resolver 的常量分支吸收）只会让该 Space 本轮不发布，下一轮重试——这就是
        // 「至多一轮无映射」。
        var syncUuidBySpaceId: [String: String] = [:]
        for space in spaces {
            syncUuidBySpaceId[space.spaceId] = try? await spaceAccess.ensureMapped(spaceId: space.spaceId)
        }
        guard !isStopped else { return }
        let outgoing = SyncableSpaces.snapshot(spaces: spaces, table: table,
                                               globalUuid: { uuidByProfile[$0] ?? nil },
                                               syncUuid: { syncUuidBySpaceId[$0] ?? nil },
                                               now: now())
        var work = spaceCommitEntries(from: table, outgoing: outgoing)
        if let onlyUuids { work = work.filter { onlyUuids.contains($0.uuid) } }
        // §9.1 second gate's bookkeeping half: an unpublished pendingDelete is
        // finalized here rather than sent.
        for (uuid, var cursor) in table.cursors where cursor.pendingDelete {
            guard cursor.entityId == nil || cursor.version == 0 else { continue }
            cursor.pendingDelete = false
            cursor.reconciled = nil
            cursor.server = nil
            cursor.deletedAtMs = now()
            table.cursors[uuid] = cursor
        }
        guard !work.isEmpty else { writeSpaceTable(table); return }

        var conflicted: Set<String> = []
        // R-D6-10：这一轮被账户接受的自发 tombstone。收集在
        // `applySpaceCommitOutcome` 里，删映射在批处理循环之后——那个方法是同步的，
        // 而映射写在主 actor 上。
        var tombstonedThisRound: Set<String> = []
        var encryptionFailed = false
        while !work.isEmpty {
            let slice = Array(work.prefix(Self.maxCommitEntriesPerBatch))
            work.removeFirst(slice.count)
            var entries: [PhiCommitEntry] = []
            var payloads: [(uuid: String, entry: PhiCommitEntry, outgoing: Phi_PhiSpaceEntity?)] = []
            for item in slice {
                guard let payload = item.outgoing else {
                    entries.append(item.entry); payloads.append(item); continue
                }
                var wrapper = Phi_PhiEntity()
                wrapper.space = payload
                guard let key = try? await domainKeys.domainKey(),
                      let ciphertext = try? PhiEntityCodec.encrypt(wrapper, key: key) else {
                    // `break`, not `return`: outcomes already applied for earlier
                    // slices in this round are in `table` and must still be
                    // persisted by the `writeSpaceTable` below, or an accepted
                    // commit's baselines are silently thrown away and the next
                    // round republishes what the server already has.
                    encryptionFailed = true
                    break
                }
                entries.append(PhiCommitEntry(entityId: item.entry.entityId,
                                              clientTagHash: item.entry.clientTagHash,
                                              name: item.entry.name, ciphertext: ciphertext,
                                              deleted: false, baseVersion: item.entry.baseVersion))
                payloads.append(item)
            }
            if encryptionFailed {
                AppLogError("[phi-sync] space commit aborted: the domain key or the seal failed")
                break
            }
            guard !isStopped, canPublishThisRound else { break }
            let outcomes: [PhiCommitOutcome]
            do {
                outcomes = try await client.commit(entries: entries, storeBirthday: storedBirthday)
            } catch PhiSyncProtocolError.notMyBirthday {
                resetForNewStoreBirthday()
                return   // the reset rewrote the table itself; do not write the stale copy back
            } catch {
                AppLogError("[phi-sync] space commit failed (\(PhiSyncLog.describe(error)))")
                break    // keep the outcomes earlier slices already produced
            }
            guard !isStopped else { return }
            for (item, outcome) in zip(payloads, outcomes) {
                applySpaceCommitOutcome(outcome, for: item, table: &table,
                                        conflicted: &conflicted,
                                        tombstoned: &tombstonedThisRound)
            }
        }
        // R-D6-10：这一轮被账户接受的自发 tombstone，映射行随之删除（本地行已经没
        // 了，映射留着只会让下一次反查交出一个不存在的 spaceId）。游标留下：它是永久
        // tombstone 记录。收集在 `applySpaceCommitOutcome` 里，删除在这里——那个方法
        // 是同步的，而映射写在主 actor 上。
        for uuid in tombstonedThisRound {
            guard let local = await spaceAccess.localSpaceId(forSyncUuid: uuid) else { continue }
            await spaceAccess.dropSpaceMapping(forSpaceId: local)
        }
        writeSpaceTable(table)

        // One pull, then re-send ONLY the entities that conflicted -- the retry
        // is scoped by `onlyUuids`, so a single conflicting Space never drags
        // the other twenty back through the wire (§5.1: "一次 pull 后只重发冲突的
        // 那几条; 二次冲突放弃这几条, 本轮其余已生效").
        if retryOnConflict, !conflicted.isEmpty {
            guard await pull(retryOnBirthday: true, thenPush: false) else { return }
            await pushSpaces(retryOnConflict: false, onlyUuids: conflicted)
        }
    }

    /// The five baseline write points of §6.2, in one place.
    ///
    /// `tombstoned` collects the uuids whose OWN tombstone the account accepted this
    /// round (R-D6-10). It is an out-parameter for the same reason `conflicted` is:
    /// this method is synchronous, and dropping the mapping row is a main-actor hop
    /// the caller makes after the batch loop.
    private func applySpaceCommitOutcome(
        _ outcome: PhiCommitOutcome,
        for item: (uuid: String, entry: PhiCommitEntry, outgoing: Phi_PhiSpaceEntity?),
        table: inout PhiSpaceSyncTable,
        conflicted: inout Set<String>,
        tombstoned: inout Set<String>
    ) {
        var cursor = table.cursors[item.uuid] ?? PhiSpaceCursor()
        let isTombstone = item.entry.deleted
        switch outcome {
        case .applied(let entityId, let version, let storeBirthday):
            if !entityId.isEmpty { cursor.entityId = entityId }
            cursor.version = version
            storedBirthday = storeBirthday
            if isTombstone {
                cursor.pendingDelete = false
                cursor.deleteRejectRounds = 0
                cursor.reconciled = nil
                cursor.server = nil
                cursor.deletedAtMs = now()
                cursor.hidden = true
                spaceCounters.tombstones += 1
                tombstoned.insert(item.uuid)
            } else if let outgoing = item.outgoing {
                // BOTH baselines: updating only `server` would let the next
                // snapshot decide the field still differs from `reconciled`,
                // stamp `now` again, and win the account's LWW every round.
                cursor.reconciled = try? outgoing.serializedData()
                cursor.server = cursor.reconciled
                cursor.deleteRejectRounds = 0
                spaceCounters.pushed += 1
            }
        case .conflict:
            conflicted.insert(item.uuid)
            spaceCounters.conflicts += 1
        case .invalidMessage:
            guard isTombstone else {
                // "The server has no such row": drop the server-side triple and
                // let the next round re-create through the client_tag unique
                // index. `reconciled` survives -- it is this device's timestamp
                // history, not a statement about the server.
                cursor.entityId = nil
                cursor.version = 0
                cursor.server = nil
                break
            }
            // A rejected tombstone proves nothing: the server resolves a
            // tombstone's data type with a query OUTSIDE the commit transaction,
            // so any transient failure returns the same code as "no such row".
            // Keep the intent and re-send it unchanged; give up only after three.
            cursor.deleteRejectRounds += 1
            if cursor.deleteRejectRounds >= Self.tombstoneRejectGiveUpRounds {
                AppLogError("[phi-sync] giving up on a tombstone after \(cursor.deleteRejectRounds) rejections tag=\(String(item.entry.clientTagHash.prefix(8)))")
                cursor.pendingDelete = false
                cursor.reconciled = nil
                cursor.server = nil
                cursor.deletedAtMs = now()
                cursor.hidden = true
            }
        case .rejected(let type):
            AppLogError("[phi-sync] space commit rejected response_type=\(type) tag=\(String(item.entry.clientTagHash.prefix(8)))")
        }
        table.cursors[item.uuid] = cursor
    }

    // MARK: - 归属项：轮首、分发、落地、发布（M3-3 §5）

    /// **每轮每种 kind 最多发布 250 条 = 10 批 × 25**（§5.3）。批大小沿用
    /// `maxCommitEntriesPerBatch`，远低于服务端 500 的上限；250 条就是 10 次顺序 HTTP 往返，
    /// 整个期间这一轮占着 `roundQueue`，所以上限存在的理由是让设置与 Space 每轮都能插进来。
    private static let maxOwnedCommitsPerRound = 250

    /// What one pull collected for ONE owned kind.
    private struct OwnedPullBatch {
        var arrivals: [(identity: String, payload: Data, entityId: String, version: Int64)] = []
        var tombstones: [(identity: String, entityId: String, version: Int64)] = []
        var unreadableHashes: [String] = []
        var unreadable = 0
    }

    /// 轮首那份身份翻译表，算一次用到底。
    private func ownedRoundMaps() async -> OwnedOwnerMaps {
        if let ownedMapsThisRound { return ownedMapsThisRound }
        var maps = OwnedOwnerMaps()
        guard let spaceAccess else { ownedMapsThisRound = maps; return maps }
        let table = loadSpaceTable()
        for (localId, uuid) in await spaceAccess.allSpaceMappings() {
            maps.syncUuidBySpaceId[localId] = uuid
            maps.localSpaceIdBySyncUuid[uuid] = localId
        }
        // 默认 Space 的身份由 D1 固定成一个常量，映射表里没有它（R-D6-14 ⑥：翻译只走
        // `PhiSpaceLocalAccess` 既有的那四个方法，这里是它们的值快照）。
        maps.syncUuidBySpaceId[LocalStore.defaultSpaceId] = SyncableSpaces.defaultSpaceUuid
        maps.localSpaceIdBySyncUuid[SyncableSpaces.defaultSpaceUuid] = LocalStore.defaultSpaceId
        let spaces = await spaceAccess.currentSpaces()
        for space in spaces {
            // §4.2 规则 1 的三条判据的合取：在 `currentSpaces()` 里 ∧ 有 syncUuid ∧ 游标
            // 既不 hidden 也没有 purgedAtMs。
            if let uuid = maps.syncUuidBySpaceId[space.spaceId] {
                let cursor = table.cursors[uuid]
                if cursor?.hidden != true, cursor?.purgedAtMs == nil {
                    maps.eligibleSpaceUuids.insert(uuid)
                }
            }
            if maps.globalUuidByProfileId[space.profileId] == nil,
               let uuid = await spaceAccess.globalUuid(forProfileId: space.profileId) {
                maps.globalUuidByProfileId[space.profileId] = uuid
                maps.localProfileIdByGlobalUuid[uuid] = space.profileId
            }
        }
        ownedMapsThisRound = maps
        return maps
    }

    /// 每条注册 kind 的轮首：**一次**本机读 + 一次游标表读 + 建 tag 索引。
    ///
    /// 一轮至多一次（§5.7 第 2 条硬要求）：`pull` 与 `push` 都可能第一个到达这里。
    /// 读抛错 ⇒ R-exec-3：把这条 kind 标成本轮失效，它的快照、差分、发布与落地整段不跑，
    /// 游标表一个字节都不写。**绝不把失败的读当成零行继续**——差分对空集合的回答是给账户上
    /// 每一条已发布身份各发一条 tombstone。
    private func beginOwnedRound() async {
        guard !ownedKinds.isEmpty, spaceStore != nil else { return }
        for registration in ownedKinds {
            guard !ownedRoundStarted.contains(registration.label) else { continue }
            ownedRoundStarted.insert(registration.label)
            let table = loadOwnedTable(registration, armsReplayOnLoss: false).table
            var identities: Set<String> = []
            do {
                try await registration.beginRound()
                identities = await registration.localIdentities()
            } catch {
                ownedReadFailed.insert(registration.label)
                var counters = ownedCounters[registration.label] ?? OwnedRoundCounters()
                counters.localReadFailed += 1
                ownedCounters[registration.label] = counters
                AppLogError("[phi-sync] owned-item local read failed kind=\(registration.label) "
                            + "(\(PhiSyncLog.describe(error)))")
            }
            // 种子 = 游标键 ∪ 本机身份（§5.1）。索引在轮内**只增不减**，随学随加。
            var index: [String: String] = [:]
            for identity in Set(table.cursors.keys).union(identities) where !identity.isEmpty {
                index[PhiSyncEntity.clientTagHash(for: registration.clientTag(identity))] = identity
            }
            ownedTagIndices[registration.label] = index
        }
    }

    /// 读一条 kind 的游标表，并按 R-M3-3-13 处理报损。
    ///
    /// `armsReplayOnLoss` 只在**发布段**那一次为真（CASE 6.26）：报损做的第一件事是丢
    /// marker、重新武装 `drainInProgress`、把 `hasDrainedFullReplay` 置假，而发布侧的 guard ①
    /// 读的正是 `hasDrainedFullReplay`——所以从报损那一刻起，该 kind 在重放收尾之前一条都
    /// 发不出去。不需要第二个 `publishBlocked` 标志（M2 裁定）：两步之一写不成时本轮已经
    /// `cursorSaveFailed`，发布闸（`canPublishThisRound`）在这一轮关掉了整个发布段，
    /// `publishOwnedKind` 根本走不到这里（R-M3-4a-103）。
    ///
    /// **报损支是两步确认，次序是 marker 先、闩后**（R-M3-4a-103，计划裁定 3b）：与 guard 2 同一个
    /// 缺陷的第二处现场。反过来（闩先写、marker 后写）在 marker 写失败时留下「旧 marker +
    /// 已置位的 per-kind 闩 + 已武装的 drain」：下一轮从旧 marker 增量拉、一页空页就让 drain
    /// 「完成」、闩此后直接 `return (table, true)` 再也不报损、而闩的复位判据（一次成功的 load
    /// 交回带已发布游标的表）永远不成立——那条 kind 的整类型重放**永久丢失**。
    private func loadOwnedTable(_ registration: OwnedKindRegistration,
                                armsReplayOnLoss: Bool)
        -> (table: PhiOwnedItemTable, lost: Bool) {
        let spaceTable = loadSpaceTable()
        let (table, reportedLoss) = registration.store
            .load(hadRecords: spaceTable[keyPath: registration.flags.hadRecords])
        ownedTables[registration.label] = table
        guard reportedLoss else {
            // per-kind 闸**可以重新武装**，判据是一次成功的 **load** 交回了一张带已发布游标
            // 的表——这是它与 Space 那个永久闩唯一的行为差别（A2）。
            //
            // 绝不能改成「一次成功的 save」：save 写回去的是引擎在内存里刚建出来的那张表，
            // 而一个**每次都读不出来**的文件（权限、或解析器永远拒绝的 JSON）会在「报损 →
            // 重放 → 重建游标 → save 清闸 → 再报损」之间无限循环，此后每一轮都是一次整个
            // data type 的重放——正是 Space 那个一次性闩存在的理由。
            if table.cursors.values.contains(where: { !$0.entityId.isEmpty }),
               spaceTable[keyPath: registration.flags.replayedForEmptyTable] {
                mutateSpaceTable { $0[keyPath: registration.flags.replayedForEmptyTable] = false }
            }
            return (table, false)
        }
        guard armsReplayOnLoss else { return (table, false) }
        // per-kind 的一次性闸（A2）。**绝不复用 Space 那个永久闩 `didReplayForEmptyTable`**：
        // Space 段先花掉它之后，书签或 pin 的第一次文件丢失就一次重放都得不到。
        guard !spaceTable[keyPath: registration.flags.replayedForEmptyTable] else {
            return (table, true)
        }
        // ① 先把盘上的 marker 清成 nil。写不成 ⇒ 闩不置位、三个 drain 标志一个不动，本轮收口成
        //    `.cursorSaveFailed`（发布闸 R-M3-4a-88 / 92 自动关掉这一轮的发布）。盘上与进入
        //    这一轮之前逐字节相同 ⇒ 下一轮报损检查**照样触发**。
        //    写的是**引擎属性**而不是 `pull` 的局部量：这个函数在 `pull` 之外也被调（轮首那次
        //    `armsReplayOnLoss: false`，那条路径不写任何东西）。`cursorSaveFailures` 由写口自己加。
        guard persistStoredMarker(nil) else {
            roundOutcome = .cursorSaveFailed
            return (table, false)
        }
        // ② marker 已确认落盘，这才置位 per-kind 闩 + 武装 drain。写不成 ⇒ 盘上是「marker 已清、
        //    闩未置位」，R-M3-4a-83 的回滚让内存镜像跟着退回 ⇒ 下一轮报损检查再触发一次，第 ① 步
        //    幂等（`persistMarkerState` 的 `updated == markerState` 短路成零写、不计
        //    `cursorSaveFailures`）⇒ 收敛。
        guard mutateSpaceTable({ updated in
            updated[keyPath: registration.flags.replayedForEmptyTable] = true
            updated.hasDrainedFullReplay = false
            updated.drainInProgress = true
        }) else {
            roundOutcome = .cursorSaveFailed
            return (table, false)
        }
        // 两个失败支都回 `(table, false)`：`lost == true` 的含义是「这一次真的换来了一次重放」，
        // 而那两支什么都没换来——所以这句日志也只在两步都确认之后才说。
        AppLogWarn("[phi-sync] owned-item cursor table lost kind=\(registration.label); "
                   + "replaying data type \(PhiSyncEntity.dataTypeID) once")
        return (table, true)
    }

    /// 落盘一条 kind 的游标表，顺带维护两个 per-kind 标志。
    ///
    /// `…HadRecords` 第一次写下 `entityId` 非空的游标时置真，此后不再改。
    ///
    /// **一次性重放闸的复位不在这里**，它的判据是一次成功的 `load`（见 `loadOwnedTable`）：
    /// 这里看到的表是引擎刚在内存里建出来的，用它当「文件恢复了」的证据，会让一个永远读不
    /// 出来的文件每一轮都重放整个 data type。
    ///
    /// **返回值 = 这张表已落盘**（R-M3-4a-83）。退休那条早退**不算失败**（R-M3-4a-16 的
    /// 判据是「某个 store 的 `save` 被调用过且回报了失败」）：把它写成 `return false` 会让
    /// 一个已退休的引擎在 Task 2b 落地之后再也不推 marker。
    @discardableResult
    private func writeOwnedTable(_ registration: OwnedKindRegistration,
                                 _ table: PhiOwnedItemTable) -> Bool {
        // 早退，不是失败（R-M3-4a-16）。
        guard !isStopped else { return true }
        ownedTables[registration.label] = table
        // §2.5 第 4 条的置位点之一：判据「某个 store 的 `save` 被调用过且回报了失败」属于写口。
        // （内存镜像 `ownedTables` 在 guard 之前赋值，所以一个失败轮次里镜像领先文件；B-2 让
        // 这一轮跳过发布、下一轮重新 load，所以这一步的先后不构成问题。）
        guard registration.store.save(table) else {
            cursorSaveFailures += 1
            return false
        }
        let hasPublished = table.cursors.values.contains { !$0.entityId.isEmpty }
        guard hasPublished else { return true }
        // 两个 per-kind 标志排在 `save` **之后**（§2.5 第 7 条）：`…HadRecords` 的含义是
        // 「这台机器曾经为该 kind **写下过**一条带 `entityId` 的游标」。一次没落盘的写提前
        // 置真，会让下一次真正的文件丢失被 `load(hadRecords:)` 读成「本来就是空的」而拿不到
        // 整类型重放——而那次重放是唯一能把账户的书签树重新对齐的机制。
        mutateSpaceTable { $0[keyPath: registration.flags.hadRecords] = true }
        return true
    }

    /// §5.2 步骤 2-5，次序固定为 **路由 → 解密 → 反推 tag → 比对 → 落位**。
    ///
    /// `decoded` 非 nil = 分发的兜底支已经解过一次，别再解第二遍。
    private func routeOwnedEntity(_ registration: OwnedKindRegistration,
                                  _ entity: PhiRemoteEntity,
                                  key: SymmetricKey,
                                  decoded: Phi_PhiEntity?,
                                  into batches: inout [String: OwnedPullBatch]) {
        let shortHash = String(entity.clientTagHash.prefix(8))
        var batch = batches[registration.label] ?? OwnedPullBatch()
        defer { batches[registration.label] = batch }

        // 2. tombstone FIRST，先于任何解密尝试。tombstone 没有密文，解密必然抛错；把它归进
        // 「解不开」会让每一条远端删除**永久丢失**——marker 已经推过那一页，服务端再也不会
        // 重发。分发循环里那个 `guard !entity.deleted` 是**设置分支**里的，路由路径上的这
        // 一道必须自己带（V35）。
        guard !entity.deleted else {
            guard let identity = ownedTagIndices[registration.label]?[entity.clientTagHash] else {
                AppLogInfo("[phi-sync] ignoring an owned-item tombstone for an unknown tag "
                           + "hash=\(shortHash) kind=\(registration.label)")
                return
            }
            batch.tombstones.append((identity: identity, entityId: entity.entityId,
                                     version: entity.version))
            return
        }

        // 3. 解密。
        let payload: Phi_PhiEntity
        if let decoded {
            payload = decoded
        } else {
            do {
                payload = try PhiEntityCodec.decrypt(entity.ciphertext, key: key)
            } catch {
                AppLogWarn("[phi-sync] cannot open an owned-item entity tag=\(shortHash) "
                           + "kind=\(registration.label) ciphertext_bytes=\(entity.ciphertext.count) "
                           + "(\(PhiSyncLog.describe(error)))")
                batch.unreadableHashes.append(entity.clientTagHash)
                batch.unreadable += 1
                return
            }
        }

        // 4. 不是本 kind 的载荷 ⇒ 只忽略这一条。
        guard let identity = registration.identity(payload) else { return }

        // 5. 载荷必须 hash 回它到达时用的那个 tag（§2.5）。校验只比**身份**，不比归属：
        // 一次跨 Space 的移动是合法的，把归属一起比会把每一次移动都判成伪造载荷。
        // **tombstone 不走这条校验**——它没有载荷可反推（上面已经 return 了）。
        let expected = PhiSyncEntity.clientTagHash(for: registration.clientTag(identity))
        guard expected == entity.clientTagHash else {
            AppLogError("[phi-sync] an owned-item payload does not hash back to its "
                        + "tag=\(shortHash) kind=\(registration.label)")
            batch.unreadableHashes.append(entity.clientTagHash)
            batch.unreadable += 1
            return
        }
        guard let bytes = try? payload.serializedData() else { return }
        batch.arrivals.append((identity: identity, payload: bytes,
                               entityId: entity.entityId, version: entity.version))
        // 随学随加：同一次 drain 的后续页就能路由这条身份的 tombstone。
        ownedTagIndices[registration.label, default: [:]][entity.clientTagHash] = identity
    }

    /// 与 `flushSpaceObservations` 同一条理由：marker 推进是durable的，所以这一轮学到的
    /// 「这条 tag 本机读不出来」必须跟着落盘，否则后面那次抛错会把它一起带走。
    private func flushOwnedObservations(_ batches: [String: OwnedPullBatch]) {
        let hashes = batches.values.flatMap(\.unreadableHashes)
        guard !hashes.isEmpty else { return }
        let seenAt = now()
        mutateSpaceTable { table in
            for hash in hashes { table.unreadableTagHashes[hash] = seenAt }
        }
    }

    /// （B-2 之后 `pull` 的 catch 不再调用这里：逐页落地让「收到了但还没放下去」的实体不再跨
    /// 页存在，抛错只可能发生在 `getUpdates`，那一页根本没到。剩下的唯一调用点是下面说的
    /// `applyOwnedKind` 的 `ownedReadFailed` 提前返回。下面这段是它原本的成因，留作理由。）
    ///
    /// 一次**中途抛错**的 pull 已经把它读过的那些页永久消费掉了：共享 marker 一页一页落盘
    /// （`storedMarker = marker` 就在页循环里），而路由从那些页上解出来的实体活在这一轮的
    /// 局部变量 `ownedBatches` 里，随抛错一起消失。对归属 kind 来说这不是「下一轮再拉一次」
    /// ——服务端只从推进过的 marker 之后发货，页 1 上那些 create / update / delete **再也不会
    /// 被投递**：那条书签在本机永远不出现，那次远端删除在本机永远不发生，而每一个计数器都是
    /// 健康值。
    ///
    /// 所以这里把它们写进游标自己那条**持久**的待办通道，形状与落地段那两个停放循环逐字相同：
    /// 存活实体进 `pendingApply` + `pendingOwnerUuid`（§4.4 第 4 步），远端 tombstone 进
    /// `pendingTombstone`（§5.6 T4），**两者都先收割服务端三元组**（A6——不收割的话那条游标
    /// 以 `entityId == ""` 落盘，而那一版实体永不重投，R-exec-1 的双向坏掉）。下一轮的
    /// `applyOwnedKind` 把这两处原样读回工作集（`parked` 与 `tombstoned` 的定义里已经有它们），
    /// 于是那些页的内容照常落地，只晚一轮。
    ///
    /// **为什么不像 Space 段那样丢 marker 重放整个 data type**：那条路是 Space 段唯一能走的
    /// （它没有「收到了但还没放下去」的持久位），代价是把设置与全部 kind 一起拖进一次整类型
    /// 重放，而且只在一次**从头开始**的 drain 被打断时才武装（`drainInProgress` 的前置是
    /// `storedMarker == nil`）——一次普通增量拉取中途失败根本不触发它。归属 kind 手上正好有
    /// 那条持久通道，用它既不要求对端重发，也不动 marker。
    ///
    /// **`ownedReadFailed` 不挡这一趟**：R-exec-3 关的是该 kind 的快照、差分与发布（出站
    /// 半边），而这里写的全是入站记账——本机行读不出来，一点也不会让这批已经收下的字节更
    /// 不值得留着。
    ///
    /// **第二个调用点是 `applyOwnedKind` 的 `ownedReadFailed` 提前返回**：那一支的触发条件
    /// 不同（轮首那次本机读抛了），但被消费掉的东西与后果逐字相同。R-exec-3 关的是这条 kind
    /// 的**出站**半边（快照、差分、发布）——「本机行读不出来」一点也不会让这一批已经收下的
    /// 字节更不值得留着。
    private func parkUndeliveredOwnedEntities(_ batches: [String: OwnedPullBatch],
                                              reason: String) {
        guard !isStopped, spaceStore != nil else { return }
        for registration in ownedKinds {
            guard let batch = batches[registration.label],
                  !batch.arrivals.isEmpty || !batch.tombstones.isEmpty else { continue }
            var table = ownedTables[registration.label] ?? PhiOwnedItemTable()
            for item in batch.tombstones {
                var cursor = table.cursors[item.identity] ?? PhiOwnedItemCursor()
                harvestTriple(into: &cursor, entityId: item.entityId, version: item.version)
                cursor.pendingTombstone = true
                table.cursors[item.identity] = cursor
            }
            for item in batch.arrivals {
                var cursor = table.cursors[item.identity] ?? PhiOwnedItemCursor()
                let known = cursor.version
                harvestTriple(into: &cursor, entityId: item.entityId, version: item.version)
                // §5.6 的 L2 支在这里同样成立，判据也同样是**版本**：一条比本机那条 tombstone
                // 更旧的重放版本不许被停放，否则下一轮它会把一条用户明确删掉的行建回来。
                // 收割照做（A6）——那条待发的 tombstone 还要拿这个三元组去提交。
                if cursor.deletedAtMs == nil || item.version > known {
                    cursor.pendingApply = item.payload
                    cursor.pendingOwnerUuid = registration.owners(item.payload).first
                }
                table.cursors[item.identity] = cursor
            }
            AppLogWarn("[phi-sync] parking what the shared marker already consumed kind="
                       + "\(registration.label) reason=\(reason) "
                       + "parked=\(batch.arrivals.count) tombstones=\(batch.tombstones.count)")
            writeOwnedTable(registration, table)
        }
    }

    /// 归属段的最前面：重试停放项（§3 / R-exec-10）。
    ///
    /// **每一种轮次都跑，一轮一次。** 一次纯 push 轮（`pushLocalSettings()` /
    /// `handleLocalDefaultsChange()` / `handleLocalSpacesChange()`）没有落地段，却照样走到
    /// 发布段——而发布段的两件事都要先知道「这一行本轮已经配上了一个账户身份」：出站快照
    /// 据此**不为它铸新身份**，差分据此**不把那条身份判成缺席**。少了这一趟，用户在重试
    /// 窗口里改一次设置就足以让账户上那条实体被删掉、同一条本机行再铸一个新身份重新建一条。
    ///
    /// 它**不往游标上加任何状态**（§3.5 禁止窗口状态 / 本地铸造标志 / 去重残留）：重试的
    /// 输入就是 `pendingApply`，配对每轮从本机行现算。
    private func retryParkedOwnedClaims(_ registration: OwnedKindRegistration,
                                        maps: OwnedOwnerMaps) async {
        guard !isStopped, !ownedParkedRetryDone.contains(registration.label) else { return }
        ownedParkedRetryDone.insert(registration.label)
        guard !ownedReadFailed.contains(registration.label) else { return }
        var table = ownedTables[registration.label] ?? PhiOwnedItemTable()
        var parked: [String: ParkedOwnedItem] = [:]
        for (identity, cursor) in table.cursors {
            guard let payload = cursor.pendingApply else { continue }
            parked[identity] = ParkedOwnedItem(payload: payload,
                                               pendingOwnerUuid: cursor.pendingOwnerUuid)
        }
        guard !parked.isEmpty else { return }
        let result = await registration.retryParkedClaims(parked, maps)
        guard !result.persisted.isEmpty else { return }
        var changed = false
        for identity in result.persisted {
            guard var cursor = table.cursors[identity] else { continue }
            // **只有「写回重试」那一种形状可以解除停放。** 它的停放载荷就是 `reconciled` 的
            // 一份拷贝——那条实体早就落过地了，认领写下身份之后没有任何东西剩下要落地。
            //
            // 另一种形状是一条**真正的入站实体**被导入锁挡下（§5.6 T4）：它从没落过地，
            // `reconciled` 还是 nil，而 `.claim` **只写身份、不写任何字段**
            // （`LocalStore+Bookmark.swift`：「认领不是一次编辑」）。清掉它的载荷等于把
            // `adopt` 算出来的那份字段级合并结果扔掉，而那条实体永远不会再来一次——共享
            // marker 早已推过那一页，`pendingApply` 存在的全部理由就是这个。下一轮的快照
            // 会拿本机那一行的全部字段盖掉账户上那一条，远端的位置就此丢失，正是 §6.2
            // 点名禁止的「整体采纳本机」。
            //
            // 留着载荷是安全的：停放中的游标不进快照（§4.2 第 3 条），所以在落地段把那份
            // 合并结果放下去之前，没有任何东西会被发布到它上面。
            guard cursor.reconciled == cursor.pendingApply else { continue }
            cursor.pendingApply = nil
            cursor.pendingOwnerUuid = nil
            table.cursors[identity] = cursor
            changed = true
        }
        guard changed else { return }
        writeOwnedTable(registration, table)
    }

    /// A6 的收割**唯一的写入点**：入站那一侧每一处「把服务端三元组写进游标」都走这里。
    ///
    /// 三件事绑在一起，而第三件是 F-PK-4：收到一个非空 entity id 就把 R-exec-13 的连败计数
    /// 清零，与 `applyOwnedCommitOutcome` 的 `.applied` 支逐字同款。**理由是那个计数的含义**
    /// ——「补键这条通路连着失败了几轮」——而一条被对端的更新收割回身份的游标此刻根本不需要
    /// 补键：它已经有 id 了。留着旧账的后果是延迟很久才现形的那一种：这条身份哪天再一次
    /// 丢掉 id（一次 `.invalidMessage`、一次 NOT_MY_BIRTHDAY 之后的 reset），三次机会里已经
    /// 用掉了两次，于是它一轮就放弃，而那一轮的失败与很久以前那两次毫无关系。
    ///
    /// `entityId` 为空**什么都不写**（A6 的老规矩）：服务端偶尔在一条更新里不回 id，写进去会
    /// 把这条身份降级成「从没在账户上出现过」，下一轮以 `baseVersion == 0` 盲写覆盖。
    /// 版本取 `max`，不是直接赋值——同一轮里同一条身份可以被收割不止一次（分页、停放重试）。
    private func harvestTriple(into cursor: inout PhiOwnedItemCursor,
                               entityId: String, version: Int64) {
        if !entityId.isEmpty {
            cursor.entityId = entityId
            cursor.rekeyRejectRounds = nil
        }
        cursor.version = max(cursor.version, version)
    }

    /// 一条 kind 的入站落地段。**apply → 基线，顺序即不变量**（§4.5）。
    private func applyOwnedKind(_ registration: OwnedKindRegistration,
                                batch: OwnedPullBatch, maps: OwnedOwnerMaps) async {
        guard !isStopped else { return }
        var counters = ownedCounters[registration.label] ?? OwnedRoundCounters()
        counters.pulled += batch.arrivals.count + batch.tombstones.count
        counters.unreadable += batch.unreadable
        counters.tombstones += batch.tombstones.count
        ownedCounters[registration.label] = counters
        // R-exec-3：轮首那次本机读抛了 ⇒ 这条 kind 的快照、差分与发布整段不跑。**但入站
        // 这一批不能跟着蒸发**：共享 marker 已经一页一页推过它们，服务端不会再发第二次，
        // 就地返回等于把那条 create 与那条远端删除永久丢掉（与一次中途失败的 pull 同一种
        // 损失，只是触发条件不同）。走同一条持久通路把它们停下来，下一轮读得出来时照常落地。
        guard !ownedReadFailed.contains(registration.label) else {
            parkUndeliveredOwnedEntities([registration.label: batch], reason: "local-read-failed")
            return
        }

        var table = ownedTables[registration.label] ?? PhiOwnedItemTable()
        // 工作集 = 本轮到达的 tombstone ∪ 表里全部 `pendingTombstone` 的游标（§5.6）。
        // 重投是不存在的——共享 marker 早已推过那一页。
        var tombstoned = Set(batch.tombstones.map(\.identity))
        for (identity, cursor) in table.cursors where cursor.pendingTombstone {
            tombstoned.insert(identity)
        }
        // A6：**每一条能走到游标的入站实体**都先收割服务端三元组，tombstone 也不例外。
        //
        // 三元组同时留一份在 `tombstoneTriples` 里：下面那两个停放循环会**新建**游标，而这
        // 个循环只更新已经存在的那些（T1 支不为一条认不出来的 tombstone 建游标）。新建的
        // 那一条必须带上三元组，理由与 `plan.harvest` 那一份逐字相同（见停放循环）。
        var tombstoneTriples: [String: (entityId: String, version: Int64)] = [:]
        for item in batch.tombstones {
            let previous = tombstoneTriples[item.identity]
            tombstoneTriples[item.identity] =
                (entityId: item.entityId.isEmpty ? (previous?.entityId ?? "") : item.entityId,
                 version: max(item.version, previous?.version ?? 0))
            guard var cursor = table.cursors[item.identity] else { continue }
            harvestTriple(into: &cursor, entityId: item.entityId, version: item.version)
            table.cursors[item.identity] = cursor
        }
        // §5.6 的 L2 支：游标带 `deletedAtMs` 时到达的**存活**实体，判据是**版本**。
        //
        // **这道闸必须在 `plan` 之前。** `plan` 不看这条身份自己的 `deletedAtMs`，一条重放的
        // 旧版本照样会让它产出 `.move` / `.update`，把用户明确删掉的那一行搬回来；闸放在
        // `plan` 之后就来不及了。
        //
        // 服务端对每个 `entity_id` 只保存一行、且只下发最新版本，所以一个**比那条 tombstone
        // 更新**的存活版本按定义是删除之后发生的事（R-M3-3-23 的合法复活）；版本不新于它的
        // 那一条是一次删除**之前**版本的重放——整类型重放、门开边沿的回放、设置侧 `.unusable`
        // 的 marker 回退都产得出它，而那条实体的字段戳当然比本机刚写的 tombstone 早，按时间戳
        // 判的实现会让一条用户明确删掉的行自己回来。
        var arrivals = batch.arrivals
        var resurrecting: Set<String> = []
        var replayedAfterDelete = 0
        if arrivals.contains(where: { table.cursors[$0.identity]?.deletedAtMs != nil }) {
            var kept: [(identity: String, payload: Data, entityId: String, version: Int64)] = []
            for item in arrivals {
                guard var cursor = table.cursors[item.identity],
                      cursor.deletedAtMs != nil else {
                    kept.append(item)
                    continue
                }
                // A6 在这里同样成立：收割先于判定，两支都收。判据比的是收割**之前**那个版本。
                let known = cursor.version
                harvestTriple(into: &cursor, entityId: item.entityId, version: item.version)
                table.cursors[item.identity] = cursor
                guard item.version > known else {
                    replayedAfterDelete += 1
                    continue
                }
                resurrecting.insert(item.identity)
                kept.append(item)
            }
            arrivals = kept
        }
        counters.supersededByDelete += replayedAfterDelete
        ownedCounters[registration.label] = counters
        var parked: [String: ParkedOwnedItem] = [:]
        for (identity, cursor) in table.cursors {
            guard let payload = cursor.pendingApply else { continue }
            parked[identity] = ParkedOwnedItem(payload: payload,
                                               pendingOwnerUuid: cursor.pendingOwnerUuid)
        }
        guard !arrivals.isEmpty || !tombstoned.isEmpty || !parked.isEmpty else {
            // 被 L2 丢掉的那些实体的收割**必须落盘**：共享 marker 已经推过那一页，这一条
            // 版本再也不会被投递第二次，而本机那条待发的 tombstone 还要拿它去提交。
            if replayedAfterDelete > 0 { writeOwnedTable(registration, table) }
            return
        }

        let output = await registration.plan(
            OwnedPlanInput(arrivals: arrivals.map {
                               (payload: $0.payload, entityId: $0.entityId, version: $0.version)
                           },
                           parked: parked, table: table, maps: maps, tombstoned: tombstoned,
                           now: now()))
        counters.adopted += output.adopted
        counters.unmatchedFolders += output.unmatchedFolders
        counters.unmergeablePairs += output.unmergeablePairs
        counters.refused += output.plan.refused
        counters.supersededByDelete += output.plan.supersededByDelete
        counters.scopeMismatch = counters.scopeMismatch || output.scopeMismatch
        ownedMustRepublish[registration.label] = output.mustRepublish
        // §5.3 的尽力推迟，**并集**：一轮里可以有不止一次 pull，而判据问的是整轮。
        ownedDeferredOwners[registration.label, default: []]
            .formUnion(output.deferredOwners)

        // **只更新已存在的游标**（P5）：`plan` 先收割再判 `refuses`，所以一条被拒的实体
        // 照样在 `harvest` 里留一条记录，而它的身份可能根本没有对应游标。照着 harvest 建
        // 游标，会让一个持续发畸形载荷的对端每一轮把本机的游标表撑大一圈。
        for (identity, harvested) in output.plan.harvest {
            guard var cursor = table.cursors[identity] else { continue }
            harvestTriple(into: &cursor, entityId: harvested.entityId,
                          version: harvested.version)
            table.cursors[identity] = cursor
        }

        /// A6 的收割，**写进一条这一轮才建出来的游标**。
        ///
        /// 上面那个循环按 P5 只更新已经存在的游标，于是「本轮新建游标」的三条路——落地、
        /// §4.4 的停放、导入锁的停放——各自要再收割一次，否则那条游标以
        /// `entityId == "" / version == 0` 落盘，而共享 marker 早已推过那一页、这一版实体
        /// **永不重投**。两个来源按到达的种类取：存活实体的三元组在 `plan.harvest` 里
        /// （停放的那些也收割，见 `SyncableOwnedItems.plan` 的第一段），远端 tombstone 的在
        /// `tombstoneTriples` 里。
        func harvestServerTriple(into cursor: inout PhiOwnedItemCursor, _ identity: String) {
            guard let triple = output.plan.harvest[identity] ?? tombstoneTriples[identity] else {
                return
            }
            harvestTriple(into: &cursor, entityId: triple.entityId, version: triple.version)
        }

        let outcome = await registration.land(
            OwnedLandingInput(steps: output.plan.steps, table: table, maps: maps))
        guard !isStopped else { return }
        // §7.2 / A11 的变体重铸跑在落地那一批里，所以它的条数跟着落地结果回来。
        counters.relineaged += outcome.relineaged
        // §8.2 / Task 10：本轮新建出来的行攒进收集篮，轮末一次交给回填队列。
        faviconCandidatesThisRound.append(contentsOf: outcome.createdRows)
        faviconPinCandidatesThisRound.append(contentsOf: outcome.createdPins)

        var spaceTable = loadSpaceTable()
        var spaceTableChanged = false
        for identity in outcome.landed {
            var cursor = table.cursors[identity] ?? PhiOwnedItemCursor()
            harvestServerTriple(into: &cursor, identity)
            if outcome.deleted.contains(identity) {
                // §5.6 T1–T3：清三个待办位、写 `deletedAtMs`，于是同一轮的差分不可能把这次
                // 远端删除改写成一次本机删除再发回去。
                cursor.reconciled = nil
                cursor.server = nil
                cursor.deletedAtMs = now()
                cursor.pendingDelete = false
            } else {
                if let bytes = outcome.reconciled[identity] { cursor.reconciled = bytes }
                // §4.5：`server` **永远是 remote，不是 merged**。把合并结果写进去，下一轮
                // 就会把一个服务端从没见过的字节当成服务端的现状。
                if let server = output.serverBytes[identity] { cursor.server = server }
                // §5.6 的 L2 支后半：一次合法的复活**落地之后**才清 `deletedAtMs`。不清的
                // 话，§4.2 第 3b 条每一轮都会看见「有 `deletedAtMs` + 有活行」而再复活发布
                // 一次，每轮换来一次 `.conflict` 加一次限定重发。
                if resurrecting.contains(identity), cursor.deletedAtMs != nil {
                    cursor.deletedAtMs = nil
                    counters.resurrected += 1
                }
            }
            cursor.pendingApply = nil
            cursor.pendingOwnerUuid = nil
            cursor.pendingTombstone = false
            // §7.4：这一条的拆分伙伴解析出来了没有，只有落地那一侧知道（它手上才有本机
            // 那一批行）。`""` = 不再等了，于是 `doctoredOwnedTable` 下一轮会如实把一次
            // 本机解除发出去；非空 = 还在等，快照照抄基线。
            if let waiting = outcome.pendingPartnerLineages[identity] {
                cursor.pendingPartnerLineage = waiting.isEmpty ? nil : waiting
            }
            table.cursors[identity] = cursor
            // 一次成功的落地就是对这条 tag 的一次成功解读（§4.5 末条）：不清的话，一次
            // **瞬时**解密失败会让这条实体在本机**永久**失去发布权。
            let hash = PhiSyncEntity.clientTagHash(for: registration.clientTag(identity))
            if spaceTable.unreadableTagHashes.removeValue(forKey: hash) != nil {
                spaceTableChanged = true
            }
            counters.applied += 1
        }
        // §4.4 第 4 步的停放：归属还没落地。
        //
        // **停放建出来的游标同样要带上服务端三元组**（A6）。一条身份第一次到达就被停放
        // （作用域不一致的整轮停放、归属还没落地、导入锁）时它还没有游标，而上面那个
        // harvest 循环按 P5 只更新已经存在的那些：少了这一趟收割，游标以
        // `entityId == "" / version == 0` 落盘，而共享 marker 早已推过那一页、这一版实体
        // 永不重投——下一轮停放项落了地、写下基线，游标却仍然没有身份。
        //
        // 那条游标此后是**双向坏掉**的（Mac B 2026-09-14，build 822）：R-exec-1 说
        // `entityId == ""` 的含义是「这条身份还没在账户上出现过」，于是本机的一次删除在
        // §9.1 的第二道闸上被就地收尾（一条 tombstone 都发不出去，账户上那条实体没有任何
        // 设备还能删掉），而一次本机编辑会以 `baseVersion == 0` 的 create 盲写覆盖账户上
        // 那一条。形状与 `applySpaceUpdates` 的 fallback B 逐字相同——Space 侧停放时同样
        // 写这两行。
        for (identity, item) in output.plan.parked {
            var cursor = table.cursors[identity] ?? PhiOwnedItemCursor()
            harvestServerTriple(into: &cursor, identity)
            cursor.pendingApply = item.payload
            cursor.pendingOwnerUuid = item.pendingOwnerUuid
            table.cursors[identity] = cursor
        }
        // §7.3 的另一半：作用域不一致轮里那批**没有载荷可停**的 tombstone（`plan` 一条 step
        // 都产不出，所以它们既不在 `outcome.parked` 里也不在 `plan.parked` 里）。不记下来的
        // 话，那条远端删除就此消失——三元组已经收割、游标看上去健康、marker 早已推过那一页，
        // 于是那条 pin 在本机永远不死，而账户上它早就没了（`pendingTombstone` 存在的全部
        // 理由就是这个）。
        for identity in output.plan.parkedTombstones {
            var cursor = table.cursors[identity] ?? PhiOwnedItemCursor()
            harvestServerTriple(into: &cursor, identity)
            cursor.pendingTombstone = true
            table.cursors[identity] = cursor
        }
        // 落地被导入锁挡住的那一组（§4.9 第 3 条 / §5.6 T4）。同上，这一支也**新建**游标。
        for identity in outcome.parked {
            var cursor = table.cursors[identity] ?? PhiOwnedItemCursor()
            harvestServerTriple(into: &cursor, identity)
            if let payload = output.plan.steps.first(where: { $0.identity == identity })?.payload {
                cursor.pendingApply = payload
            }
            if tombstoned.contains(identity) { cursor.pendingTombstone = true }
            table.cursors[identity] = cursor
        }
        // 拒收：**不落地、不停放、不建游标**（CASE 6.6b / 6.11b）。
        counters.refused += outcome.refused.count
        // A9 取消了本机那条待发删除。
        for identity in output.plan.cancelledDeletes {
            guard var cursor = table.cursors[identity] else { continue }
            cursor.pendingDelete = false
            cursor.deleteDecidedAtMs = 0
            table.cursors[identity] = cursor
        }
        // §7.4 的另一半（spec item 16 的后半）：伙伴那一条身份**本轮没有实体到达**，所以它
        // 不在 `landed` 里；落地却在同一个事务里替它链上了反方向，于是它游标上那一位也要
        // 跟着清。只写到达的那一侧，反方向要等下一次本地变化才被发现，中间那段时间两台机器
        // 对同一对 pin 的显示不一致。
        //
        // **四个集合一个都不能少。** `landed` 那一半由上面那个循环负责；`parked` 与 `refused`
        // 则是**落地后复核没过**或整批算错了的那些身份——这一轮对它们的本机状态没有把握，
        // 而这一位的含义恰恰是「本机那一行还挂不挂着伙伴」。清掉一条其实没落地的身份的
        // `pendingPartnerLineage`，下一轮的表副本就会把它的基线判成一次本机解除，把对端好好
        // 的拆分对拆散——正是 §7.4 要防的那件事，只是换了一条到达路径。
        for (identity, waiting) in outcome.pendingPartnerLineages
        where !outcome.landed.contains(identity) && !outcome.parked.contains(identity)
            && !outcome.refused.contains(identity) {
            guard var cursor = table.cursors[identity] else { continue }
            let updated: String? = waiting.isEmpty ? nil : waiting
            guard cursor.pendingPartnerLineage != updated else { continue }
            cursor.pendingPartnerLineage = updated
            table.cursors[identity] = cursor
        }
        // 本轮**没有任何东西要落地**、但合并结果与基线仍然不同的那些身份：只差时间戳
        // （`OwnedItemPlan.rebaselined`）。不写的话，本机基线永远停在那个更旧的戳上，而一条
        // 后到的、取值不同却更旧的实体会拿它去比并**赢下**，把账户上更新的那个值覆盖掉。
        //
        // **这不是「没落地就写基线」的例外**（§4.5）：走到这里的身份按定义没有任何东西要
        // 落地——本机那一行的取值与合并结果逐字相同，`plan` 因此一条 step 都没产出。三个
        // 排除是深度防御：这一轮被停放 / 拒收 / 落地过的身份各有自己的写回路径。
        for (identity, bytes) in output.plan.rebaselined {
            guard var cursor = table.cursors[identity], cursor.reconciled != nil,
                  cursor.pendingApply == nil, !cursor.pendingTombstone,
                  !outcome.landed.contains(identity), !outcome.parked.contains(identity),
                  !outcome.refused.contains(identity) else { continue }
            cursor.reconciled = bytes
            // §4.5：`server` 永远是**拉到的那条远端实体**，不是合并结果。
            if let server = output.serverBytes[identity] { cursor.server = server }
            table.cursors[identity] = cursor
        }
        // 本机赢下了字段、却一个 step 都没产出的那些身份（一条更旧的远端值输给了本机手上
        // 这一份，取值与基线相同所以没什么要落地）。它们不进 `landed`，上面两个循环都不会
        // 替它们刷新 `server`——不刷的话，发布段那条**持久**判据（`server != reconciled`）
        // 看不见这次分歧，而账户上那一份确实不是本机手上这一份。
        //
        // 只写 `server`：它记的是「账户手上是什么」，这一轮刚拉到，与「本机落地了什么」
        // （`reconciled`，§4.5 要求它排在落地之后）是两件事。
        for identity in output.mustRepublish where !outcome.landed.contains(identity) {
            guard var cursor = table.cursors[identity], cursor.reconciled != nil,
                  cursor.pendingApply == nil, !cursor.pendingTombstone,
                  !outcome.parked.contains(identity), !outcome.refused.contains(identity),
                  let server = output.serverBytes[identity], cursor.server != server else {
                continue
            }
            cursor.server = server
            table.cursors[identity] = cursor
        }
        if spaceTableChanged { writeSpaceTable(spaceTable) }
        ownedCounters[registration.label] = counters
        writeOwnedTable(registration, table)
    }

    /// 归属项发布的门（PR6）。
    ///
    /// **只看 `spaceSectionEnabled` 与 `hasDrainedFullReplay`。** `sync.joinPairingPending`
    /// 引擎取不到——它是 `@MainActor ProfilePairingGate` 上的静态属性，而这是一个非 MainActor
    /// 的 actor；配对进行中协调器已经在调 `setSpaceSyncEnabled(false)`，那个值经 `.spaceGate`
    /// 排队进来并存进 `spaceSectionEnabled`，所以归属项跟 Space 段走的是同一道门。
    /// 第三条 `hasDrainedFullReplay` 是 Space 侧早就有、两种新 kind 绝不能漏掉的发布闸：
    /// 漏掉它，一台刚加入、还没拉完账户树的机器会先把自己的整棵树发上去，同时把每一行都铸上
    /// `syncId`，D10 的认领条件从此永假。
    private var ownedItemsPublishAllowed: Bool {
        guard spaceSectionEnabled, spaceStore != nil, !ownedKinds.isEmpty else { return false }
        return loadSpaceTable().hasDrainedFullReplay
    }

    private func pushOwnedItems(retryOnConflict: Bool) async {
        // 判据与 `spaceLive` 同构，`spaceAccess` 那一项也在里面：没有它，身份翻译表整张是空
        // 的，发布段会拿一份「什么都解析不出来」的映射跑完一轮。
        guard !isStopped, canPublishThisRound, !ownedKinds.isEmpty, spaceSectionEnabled,
              spaceStore != nil, spaceAccess != nil else { return }
        await beginOwnedRound()
        let maps = await ownedRoundMaps()
        // 归属段的最前面，**每一种轮次都跑**。在 pull 轮里这一趟已经在落地段之前跑过了，
        // `ownedParkedRetryDone` 让它一轮只发生一次。
        for registration in ownedKinds {
            await retryParkedOwnedClaims(registration, maps: maps)
        }
        for registration in ownedKinds {
            await publishOwnedKind(registration, maps: maps, retryOnConflict: retryOnConflict)
        }
    }

    /// 一条 kind 的发布段：快照 → 差分 → 两段切片 → 组批 → 写回。
    ///
    /// `onlyIdentities` 非 nil 时把这一批限定到那几条，这正是 `.conflict` 的限定重发传进来的
    /// 东西——一条冲突的实体绝不该把同一轮其余两百多条再拖过一次线。
    private func publishOwnedKind(_ registration: OwnedKindRegistration,
                                  maps: OwnedOwnerMaps,
                                  retryOnConflict: Bool,
                                  onlyIdentities: Set<String>? = nil) async {
        guard !isStopped, canPublishThisRound else { return }
        // R-exec-3：轮首读失败 ⇒ 快照、差分、发布**全部没跑**，不是「少发了几条」。
        guard !ownedReadFailed.contains(registration.label) else { return }
        guard ownedItemsPublishAllowed else { return }
        let loaded = loadOwnedTable(registration, armsReplayOnLoss: true)
        guard !loaded.lost else { return }
        // R-M3-4a-103（Task 2b fix round 1）：报损重放的两步之一写不成时 `loadOwnedTable` 回的是
        // `(table, false)`——上面那道 guard 放行，而这里已经过了轮首的 `canPublishThisRound`。
        // 不拦的话，发布段会拿一张**空的**游标表跑快照 → 差分 → commit，并在末尾
        // `writeOwnedTable` 写出一份新文件：下一轮的 load 不再报损，per-kind 闩再也不会置位，
        // 那条 kind 的整类型重放**永久丢失**——正是两步次序要防的那一格。一次失败的重放武装
        // 既不许对着丢失的表发布，也不许重建它的文件；下一轮报损检查照样触发。
        guard cursorSaveFailures == 0 else { return }
        var table = loaded.table
        var counters = ownedCounters[registration.label] ?? OwnedRoundCounters()

        // 1. 快照。喂进去的是一份**篡改过的表副本**（§7.4 / P4）：凡是没有
        // `pendingPartnerLineage` 的游标，其基线里的拆分伙伴被清空**并盖上本轮的 `now`**，
        // 于是一次真正的本机解除拆分会如实发出去、并且赢得下那次 LWW；确实在等伙伴的那些
        // 原样保留。**发布比较仍然用真表。**
        //
        // 时钟只读一次：`now()` 在测试里可以按读推进，两次读会让表副本的戳与快照的戳不同，
        // 而这两个值必须是同一个时刻。
        let roundNow = now()
        let doctored = await doctoredOwnedTable(registration, table, maps: maps, now: roundNow)
        let snapshot = await registration.snapshot(doctored, maps, roundNow)
        counters.excludedUnmappedOwner +=
            snapshot.skippedUnmappedOwner + snapshot.skippedIneligibleOwner
        // §7.3 / §11.2：作用域不一致时发布半边整段跳过，而那个跳过在**每一种轮次**里都会
        // 发生——包括没有任何入站、因此 `plan` 根本不跑的那一种。计数只从 `plan` 那边取的话，
        // 恰恰是唯一没有别的信号的那种轮次缺了诊断。
        counters.scopeMismatch = counters.scopeMismatch || snapshot.scopeMismatch

        // 2. A12：为表里每一条游标刷新 `ownerUuid`——包括本轮因为切片而排不上队的那些。
        for (identity, owner) in snapshot.ownerUuids {
            guard var cursor = table.cursors[identity], cursor.ownerUuid != owner else { continue }
            cursor.ownerUuid = owner
            table.cursors[identity] = cursor
        }

        // 3. 差分（§4.7）。它的第三条判据问的是 `allSyncIds()` / `allPinRows()`，
        // **不是快照**（R-exec-4）：孤儿根下的行不发布，但永远不会被判成删除。
        let diff: OwnedItemTombstoneResult
        do {
            diff = try await registration.tombstones(table, maps, now())
        } catch {
            counters.localReadFailed += 1
            ownedReadFailed.insert(registration.label)
            ownedCounters[registration.label] = counters
            AppLogError("[phi-sync] owned-item diff domain unavailable kind=\(registration.label) "
                        + "(\(PhiSyncLog.describe(error)))")
            return          // 游标表一个字节都不写
        }
        for (identity, cursor) in diff.cursorUpdates { table.cursors[identity] = cursor }

        // §9.1 第二道闸的记账半边：一条发不出去的 `pendingDelete`（没有 entityId / 版本 0）
        // 就地收尾并写 `deletedAtMs`，而不是每轮重发一条服务端必判非法的条目。
        for (identity, var cursor) in table.cursors where cursor.pendingDelete {
            guard cursor.entityId.isEmpty || cursor.version == 0 else { continue }
            cursor.pendingDelete = false
            cursor.reconciled = nil
            cursor.server = nil
            cursor.deletedAtMs = now()
            table.cursors[identity] = cursor
        }

        // 4. 两段切片，方向相反（§5.3）。
        var budget = Self.maxOwnedCommitsPerRound
        let deleteCandidates = table.cursors
            .filter { $0.value.pendingDelete && $0.value.deletedAtMs == nil }
            .keys.sorted()
        let tombstoneSlice = ownedTombstoneSlice(registration, table: table,
                                                 candidates: deleteCandidates, budget: &budget)
        // R-exec-1 的自愈，**一次性**：`entityId == ""` 的含义是「这条身份还没在账户上出现
        // 过」，而 `reconciled != nil` 的含义是「账户上那一条的某一版已经在本机落过地」。
        // 两者同时成立是一条不变量破坏，build 822 及更早会写出它——停放为一条身份新建游标
        // 时不收割服务端三元组（`applyOwnedKind` 那两个停放循环，已修）。
        //
        // 表已经这样落盘的机器**自己修不好**：那一版实体永不重投，游标再也收不到 id，于是
        // 本机对这一行的删除在上面那道闸上被就地收尾（账户上那条实体没有任何设备还能删掉），
        // 而一次本机编辑会以 `baseVersion == 0` 盲写覆盖它。
        //
        // 唯一的补键通路是**把它当成一次 create 重发**：服务端的
        // `ON CONFLICT (client_tag_hash) DO UPDATE` 按 tag 认行，而这条身份的 tag 与账户上
        // 那一条逐字相同，于是这次提交打在同一行上，回来的 `.applied` 带着真正的 entity id
        // 与版本（`applyOwnedCommitOutcome`）。Space 侧对同族状态（`.invalidMessage` 之后
        // 丢掉服务端三元组）走的就是这条通路，注释见 `applySpaceCommitOutcome`。
        //
        // **第二个触发点是 `resetForNewStoreBirthday()`**（F-PK-1，不是缺陷）：NOT_MY_BIRTHDAY
        // 之后它把每一条归属游标的 `entityId` / `version` / `server` 归零而**保留
        // `reconciled`**，于是全表都进入这里的判据。这正是要的行为——新 store 上这些身份要么
        // 不存在、要么是另一行，都该经 client tag 重新认一次。次序上也安全：同一次 reset 把
        // `hasDrainedFullReplay` 置假，而 `ownedItemsPublishAllowed` 读的就是它，所以补键一条
        // 都发不出去，直到新 store 的整类型重放排干；重放里到达的那些身份在 `harvest` 里就把
        // 三元组补回去了（`applyOwnedKind`），真正走到补键的只剩**新 store 确实没有**的那些。
        //
        // 四条限制让它不会变成一条常驻的重发规则：只碰**本机还有合格行**的身份（与快照取
        // 交集）、只碰没有停放载荷也没有待发删除的游标（那两种本轮各有自己的出路）、补上
        // 之后判据不再成立、连续三轮被拒之后**不再重新武装**（R-exec-13 的放弃，见
        // `PhiOwnedItemCursor.rekeyRejectRounds`）。本机没有行的那些补不了键——没有载荷可发；
        // 它们由对端的下一次更新收割，或者随保留期过期。
        let unkeyed = Set(table.cursors.filter {
            $0.value.entityId.isEmpty && $0.value.reconciled != nil
                && $0.value.deletedAtMs == nil && $0.value.pendingApply == nil
                && !$0.value.pendingDelete
                && ($0.value.rekeyRejectRounds ?? 0) < Self.rekeyRejectGiveUpRounds
                && snapshot.entities[$0.key] != nil
        }.keys)
        if !unkeyed.isEmpty, onlyIdentities == nil {
            // R12：只报条数与 kind，不报身份。
            AppLogWarn("[phi-sync] owned-item cursors carry a baseline but no entity id "
                       + "kind=\(registration.label) count=\(unkeyed.count); "
                       + "republishing them to re-key through the client tag")
        }
        // §6.2 的「本机赢了字段就要发布出去」**必须是持久的需求，不是轮内记忆**。
        // `ownedMustRepublish` 每轮清零（`run(_:)`），而这条需求跨得过一轮的概率一点都不低：
        // 那条身份可能排不进这一轮 250 条的切片（§5.3），或者这一轮在落地与发布之间停了
        // （退休、sign-out、进程退出）。一旦丢掉就再也回不来——落地之后本机那一行与
        // `reconciled` 逐字相等，字节差分永远不会再为它说话，而账户永远停在旧值上。
        //
        // 游标上已经durable地记着同一件事：`server` 是**账户手上**那一份（§4.5：永远是拉到
        // 的远端字节，不是合并结果），`reconciled` 是**本机落地**的那一份。两者不同 ⇒ 账户
        // 还没有这条实体的当前值。
        //
        // **`server == nil` 不算**：那是「本机不知道账户手上是什么」（NOT_MY_BIRTHDAY 之后
        // 的 reset、§9.1 的收尾），由上面 `unkeyed` 那条补键通路处理——而它带着 R-exec-13 的
        // 三次放弃。把 nil 也读成「不同」会绕过那个放弃计数，让一条服务端每轮都拒的实体永远
        // 重发。
        //
        // **`pendingTombstone` 同样不算**（F-CX-4）：那条游标上停着一次**远端删除**，等的只是
        // 一次落得下去的落地。这时把它排进发布切片，提交带的 `baseVersion` 正是从那条
        // tombstone 上收割来的版本——服务端于是接受，账户上那条实体**原地复活**，而下一轮那条
        // 停放的 tombstone 一落地，本机这一行就没了：账户多一条没有任何设备认领的实体，用户
        // 在别的设备上看见一条自己刚删掉的书签又回来了。
        let pending = Set(table.cursors.filter {
            $0.value.reconciled != nil && $0.value.server != nil
                && $0.value.server != $0.value.reconciled
                && $0.value.deletedAtMs == nil && $0.value.pendingApply == nil
                && !$0.value.pendingDelete && !$0.value.pendingTombstone
        }.keys)
        // 轮内那一份留着当**优化**：它覆盖游标还来不及记下分歧的那一类（本轮由停放项落地的
        // 合并——那一轮没有到达实体，`server` 因此没有刷新过）。
        let republish = (ownedMustRepublish[registration.label] ?? []).union(unkeyed)
            .union(pending)
        // §5.3 / §6.4 的尽力而为的推迟：某个归属在**本轮的 pull 里收到过本 kind 的实体**时，
        // 该归属下**本轮新铸身份**的行不进这一轮的切片；它们在第一个没有该归属实体到达的
        // 轮次里提交。这只是把加入期「本机先铸、对端的同一条随后才到」的窗口压窄——§6 的
        // 规则 (i) 是无状态的，谁先谁后都不丢东西，最坏是多一条重复（§6.5 的残留竞态）。
        //
        // **判据只碰本轮铸出来的身份。** 一条已经有身份的行照常发布：它在账户上已经存在，
        // 推迟它只会让一次真实的本机编辑白等一轮。已经在配对表里的行本轮根本不铸身份，
        // 所以它们也不在 `minted` 里。
        //
        // **口径是 `snapshot.ownerUuids`**（这一行坐在哪个归属里），与 `plan` 交回来的那一份
        // 同源；拿 `owners(_:)` 那个绑定引用去比，一条子孙书签比的会是它的父身份。
        let deferredOwners = ownedDeferredOwners[registration.label] ?? []
        var liveCandidates: [String] = []
        for (identity, bytes) in snapshot.entities {
            guard table.cursors[identity]?.pendingDelete != true else { continue }
            // **停着一条远端 tombstone 的身份一律不发**（F-CX-4）。§4.2 第 3 条已经把
            // `pendingTombstone` 的游标挡在快照之外，但那张快照是**适配层**算的，而这道闸
            // 守的是发布这一侧的同一件事：那条游标上等着的是一次删除，任何发出去的更新都会
            // 带着收割来的版本被服务端接受，把那条实体原地复活。判据与 `pending` 那一条同源。
            guard table.cursors[identity]?.pendingTombstone != true else { continue }
            if snapshot.minted[identity] != nil,
               let owner = snapshot.ownerUuids[identity], deferredOwners.contains(owner) {
                continue
            }
            if bytes != table.cursors[identity]?.reconciled || republish.contains(identity) {
                liveCandidates.append(identity)
            }
        }
        let liveSlice = ownedLiveSlice(registration, snapshot: snapshot,
                                       candidates: liveCandidates, budget: &budget)
        // 限定重发那一趟**不再累加**：它重跑了同一轮的快照与差分，把剩余队列再数一遍会让
        // 同一批未发布的实体在这一轮的计数行上出现两次。
        if onlyIdentities == nil {
            counters.pendingPublish += (deleteCandidates.count - tombstoneSlice.count)
                + (liveCandidates.count - liveSlice.count)
        }

        // 5. 组批。`unreadableTagHashes` 命中 ⇒ 该条目就地丢弃、不发送（§5.5）：服务端的
        // `ON CONFLICT (client_tag_hash) DO UPDATE` **没有版本检查**，一次盲写就是整体覆盖。
        let spaceTableNow = loadSpaceTable()
        var work: [(identity: String, entry: PhiCommitEntry, payload: Data?)] = []
        for identity in tombstoneSlice {
            guard onlyIdentities?.contains(identity) ?? true else { continue }
            guard let cursor = table.cursors[identity],
                  !cursor.entityId.isEmpty, cursor.version > 0 else { continue }
            let hash = PhiSyncEntity.clientTagHash(for: registration.clientTag(identity))
            guard spaceTableNow.unreadableTagHashes[hash] == nil else {
                AppLogWarn("[phi-sync] refusing to commit over an unreadable row "
                           + "tag=\(String(hash.prefix(8)))")
                continue
            }
            work.append((identity,
                         PhiCommitEntry(entityId: cursor.entityId, clientTagHash: hash,
                                        name: registration.entityName, ciphertext: nil,
                                        deleted: true, baseVersion: cursor.version), nil))
        }
        for identity in liveSlice {
            guard onlyIdentities?.contains(identity) ?? true else { continue }
            guard let payload = snapshot.entities[identity] else { continue }
            let cursor = table.cursors[identity]
            let hash = PhiSyncEntity.clientTagHash(for: registration.clientTag(identity))
            guard spaceTableNow.unreadableTagHashes[hash] == nil else {
                AppLogWarn("[phi-sync] refusing to commit over an unreadable row "
                           + "tag=\(String(hash.prefix(8)))")
                continue
            }
            let entityId = (cursor?.entityId.isEmpty ?? true) ? nil : cursor?.entityId
            work.append((identity,
                         PhiCommitEntry(entityId: entityId, clientTagHash: hash,
                                        name: registration.entityName, ciphertext: nil,
                                        deleted: false, baseVersion: cursor?.version ?? 0),
                         payload))
        }
        guard !work.isEmpty else {
            ownedCounters[registration.label] = counters
            writeOwnedTable(registration, table)
            return
        }

        var conflicted: Set<String> = []
        var appliedMinted: [String: String] = [:]
        var encryptionFailed = false
        var queue = work
        while !queue.isEmpty {
            let slice = Array(queue.prefix(Self.maxCommitEntriesPerBatch))
            queue.removeFirst(slice.count)
            var entries: [PhiCommitEntry] = []
            var sent: [(identity: String, entry: PhiCommitEntry, payload: Data?)] = []
            for item in slice {
                guard let payload = item.payload else {
                    entries.append(item.entry); sent.append(item); continue
                }
                guard let envelope = try? Phi_PhiEntity(serializedBytes: payload),
                      let key = try? await domainKeys.domainKey(),
                      let ciphertext = try? PhiEntityCodec.encrypt(envelope, key: key) else {
                    // `break`，不是 `return`：这一轮前面切片已经写进 `table` 的 outcome
                    // 必须照样落盘，否则一个已被服务端接受的提交的基线被静默扔掉，那些
                    // 实体下一轮带着过期基线重新发布。
                    encryptionFailed = true
                    break
                }
                entries.append(PhiCommitEntry(entityId: item.entry.entityId,
                                              clientTagHash: item.entry.clientTagHash,
                                              name: item.entry.name, ciphertext: ciphertext,
                                              deleted: false,
                                              baseVersion: item.entry.baseVersion))
                sent.append(item)
            }
            if encryptionFailed {
                AppLogError("[phi-sync] owned-item commit aborted kind=\(registration.label): "
                            + "the domain key or the seal failed")
                break
            }
            guard !isStopped, canPublishThisRound else { break }
            let outcomes: [PhiCommitOutcome]
            do {
                outcomes = try await client.commit(entries: entries, storeBirthday: storedBirthday)
            } catch PhiSyncProtocolError.notMyBirthday {
                // reset 已经重写了每一条游标表，手上这一份是 reset **之前**的副本。
                resetForNewStoreBirthday()
                ownedCounters[registration.label] = counters
                return
            } catch {
                AppLogError("[phi-sync] owned-item commit failed kind=\(registration.label) "
                            + "(\(PhiSyncLog.describe(error)))")
                break    // 留住前面切片已经产出的 outcome
            }
            guard !isStopped else { return }
            for (item, outcome) in zip(sent, outcomes) {
                applyOwnedCommitOutcome(outcome, for: item, registration: registration,
                                        owner: snapshot.ownerUuids[item.identity],
                                        rekeying: unkeyed.contains(item.identity),
                                        table: &table, counters: &counters,
                                        conflicted: &conflicted)
                if case .applied = outcome, item.payload != nil,
                   let localId = snapshot.minted[item.identity] {
                    appliedMinted[item.identity] = localId
                }
            }
        }

        // §6.4：铸造在提交那一刻。**写不下去的那几条把游标留着，并停放那一份载荷。**
        //
        // 撤掉游标是灾难性的：服务端**已经接受**了这些实体，所以账户上那几条真实存在；游标
        // 一删，这台机器对它们再无任何记录，而本机那些行的 `syncId` 仍然是 nil——下一轮它们
        // 重铸一批新身份、再建一批新实体，第一批就此变成**没有任何设备持有游标**的幽灵，
        // §4.7 的差分永远产不出它们的 tombstone，每一个对端都把它们物化成重复书签。
        //
        // 留着游标之后，那几条身份走的是正常的收敛路径：`pendingApply` 让 §4.2 第 3 条把它们
        // 排除在快照之外（不会重复发布），停放项在下一轮由 §6 的规则 (i) 认领回那条仍然
        // 未认领的本机行；真的认领不上时（用户在重试窗口里改了那一行、或把它删了），下一轮的
        // 差分判它「本机没有这一行」并发一条 tombstone——那是**正确的清理**，不是危险。
        //
        // **那条后路只有在游标带着归属时才走得通**：`SyncableOwnedItems.tombstones` 在
        // `ownerUuid == nil` 上保守地放弃，所以这里再钉一次。
        if !appliedMinted.isEmpty {
            let persisted = await registration.claimIdentities(appliedMinted)
            for identity in appliedMinted.keys where !persisted.contains(identity) {
                guard var cursor = table.cursors[identity] else { continue }
                cursor.pendingApply = cursor.reconciled
                if cursor.ownerUuid == nil { cursor.ownerUuid = snapshot.ownerUuids[identity] }
                table.cursors[identity] = cursor
            }
        }
        ownedCounters[registration.label] = counters
        writeOwnedTable(registration, table)

        // 一次 pull 加一次**限定到那几条**的重发；二次冲突就本轮放弃这几条（§5.3）。
        if retryOnConflict, !conflicted.isEmpty {
            guard await pull(retryOnBirthday: true, thenPush: false) else { return }
            await publishOwnedKind(registration, maps: maps, retryOnConflict: false,
                                   onlyIdentities: conflicted)
        }
    }

    /// 发布段的五个基线写入点，与 `applySpaceCommitOutcome` 同一个形状。
    ///
    /// `rekeying` = 这一条是不是本轮 R-exec-13 的补键自愈**排进去**的（而不是一次普通的
    /// 内容发布）。判据放在调用方而不是这里重算：`unkeyed` 是那一轮真正武装过的集合，而
    /// 这个函数看到的游标此刻可能已经被同一批里更早的一条 outcome 改过。
    private func applyOwnedCommitOutcome(
        _ outcome: PhiCommitOutcome,
        for item: (identity: String, entry: PhiCommitEntry, payload: Data?),
        registration: OwnedKindRegistration,
        owner: String?,
        rekeying: Bool,
        table: inout PhiOwnedItemTable,
        counters: inout OwnedRoundCounters,
        conflicted: inout Set<String>
    ) {
        let existing = table.cursors[item.identity]
        var cursor = existing ?? PhiOwnedItemCursor()
        let isTombstone = item.entry.deleted
        switch outcome {
        case .applied(let entityId, let version, let storeBirthday):
            if !entityId.isEmpty { cursor.entityId = entityId }
            cursor.version = version
            storedBirthday = storeBirthday
            if isTombstone {
                // R-M3-3-7：一条游标离开「活着」这个状态时，必定带上 `deletedAtMs`——
                // §3.6 的 30 天丢弃扫描赖以工作的就是这条不变量。
                cursor.pendingDelete = false
                cursor.deleteRejectRounds = 0
                cursor.reconciled = nil
                cursor.server = nil
                cursor.deletedAtMs = now()
                counters.tombstones += 1
            } else if let payload = item.payload {
                // **两份基线都写**（R-exec-7，与 `applySpaceCommitOutcome` 逐字同款）：服务端
                // 手上那一版**现在就是我们刚发出去的这一份**。只更新 `reconciled` 会让
                // `server` 永远停在发布之前那一版——`PhiOwnedItemState.swift` 说它的用途是
                // 「压掉一次多余的发布」，而一个永远过期的 `server` 让那句话对这台机器发布过的
                // 每一条实体都不成立。
                cursor.reconciled = payload
                cursor.server = payload
                // A12：**一条本轮刚建出来的游标也要带上归属**。它是 §4.7 差分的前置条件
                // （`tombstones` 在 `ownerUuid == nil` 上保守地放弃），而发布段那次归属刷新
                // 跑在提交循环**之前**、只碰已经存在的游标。少了这一行，一条为铸出来的身份
                // 新建的游标永远 `ownerUuid == nil`：账户上那条实体此后既没有本地行认领它，
                // 也永远发不出它的 tombstone。
                if let owner { cursor.ownerUuid = owner }
                if cursor.deletedAtMs != nil {
                    cursor.deletedAtMs = nil        // §4.2 规则 3b 的复活
                    counters.resurrected += 1
                }
                cursor.deleteRejectRounds = 0
                // 一次被接受的发布就是「这条身份此刻有 id 了」（上面刚写下）：R-exec-13 的
                // 连败计数清零，与 `deleteRejectRounds` 逐字同款。补键成功走的正是这一支。
                cursor.rekeyRejectRounds = nil
                counters.pushed += 1
            }
        case .conflict(let serverVersion):
            // **不写任何基线**：当成 `.applied` 处理会记下一条服务端从未接受的基线并静默丢掉
            // 本机的编辑。
            //
            // R-exec-17：**唯独响应带回来的 `server_version` 要收下**。紧接着那一次限定重发
            // （`publishOwnedKind` 末尾的「一次 pull + 一次重发」）用的是游标里的
            // `version` 当 `base_version`，而中间那次 pull 在服务端这一行没有新版本可派时
            // 什么都不会改——于是重试原样带着**同一个**过期版本再撞一次，`.conflict` 这一支
            // 又不记任何日志，整轮悄悄地以两条 commit 收场。Mac B 2026-09-14 那次 2.5 s
            // 的提交风暴，放大器就是这个。
            //
            // **`existing != nil` 是硬条件**：游标本来不存在时写回去，等于为一个服务端从没
            // 接受过的身份长出一条空游标（P5 的同一族缺陷）。版本只准往前走（`max` 语义）：
            // 一个比本机还旧的服务端版本是坏对端，退回去只会让下一次提交更旧。
            if let serverVersion, existing != nil, serverVersion > cursor.version {
                cursor.version = serverVersion
                table.cursors[item.identity] = cursor
            }
            conflicted.insert(item.identity)
            return
        case .invalidMessage:
            // 本来就没有游标的身份不该因为一次被拒而长出一条。
            guard existing != nil else { return }
            guard isTombstone else {
                // 「服务端没有这一行」：丢掉服务端三元组，下一轮经 client_tag 的唯一索引
                // 重新建出来。`reconciled` 留着——它是这台机器的时间戳历史，不是关于服务端
                // 的断言。**下一轮真的会重发**：`publishOwnedKind` 的补键自愈把「有基线、
                // 没有 entityId」的游标无条件排进发布切片，不再依赖「快照字节恰好与基线不等」。
                cursor.entityId = ""
                cursor.version = 0
                cursor.server = nil
                // R-exec-13 的放弃（F-PK-2）。**只数补键自愈武装出来的那些**：一次普通的
                // 内容发布被拒同样落到这一支，把它算进去会让一条正常工作的身份在三次无关的
                // 瞬时拒绝之后失去补键资格。三轮之后不再重新武装，于是一条服务端**始终**判
                // 非法的条目不会变成一条每 60 s 重发一次的永动机；放弃只停这一条自愈通路，
                // 本机那一行、它的基线与它的归属一个字都不动（见 `rekeyRejectRounds`）。
                guard rekeying else { break }
                let rejected = (cursor.rekeyRejectRounds ?? 0) + 1
                cursor.rekeyRejectRounds = rejected
                if rejected == Self.rekeyRejectGiveUpRounds {
                    // **一条，只在跨过那道线的那一轮**：此后这条身份不再进切片，也就不再有
                    // 新的 outcome 落到这里，所以不需要「放弃之后不再每轮警告」的额外判断。
                    // R12：只带 kind、tag 前缀与次数。
                    AppLogWarn("[phi-sync] giving up on re-keying an owned-item cursor after "
                               + "\(rejected) rejections kind=\(registration.label) "
                               + "tag=\(String(item.entry.clientTagHash.prefix(8)))")
                }
                break
            }
            // 一条被拒的 tombstone 什么都不能证明：服务端在提交事务**之外**解析 tombstone 的
            // data type，任何瞬时失败都返回同一个码。原样重发，三轮之后才就地收尾。
            cursor.deleteRejectRounds += 1
            if cursor.deleteRejectRounds >= Self.tombstoneRejectGiveUpRounds {
                AppLogError("[phi-sync] giving up on an owned-item tombstone after "
                            + "\(cursor.deleteRejectRounds) rejections "
                            + "tag=\(String(item.entry.clientTagHash.prefix(8)))")
                cursor.pendingDelete = false
                cursor.reconciled = nil
                cursor.server = nil
                cursor.deletedAtMs = now()
            }
        case .rejected(let type):
            // 同 `.conflict`：这条 outcome 对游标什么都没说，写回一条默认值只会造一条幽灵。
            AppLogError("[phi-sync] owned-item commit rejected response_type=\(type) "
                        + "tag=\(String(item.entry.clientTagHash.prefix(8)))")
            return
        }
        table.cursors[item.identity] = cursor
    }

    /// §7.4 的「本机主动解除拆分」。**只改喂给 `snapshot` 的那一份副本**。
    ///
    /// `now` 是**本轮那一个**时刻，与喂给 `snapshot` 的是同一个值：清空后的那个值就盖它，
    /// 于是一次真正的解除以「现在」出门并赢下对端手上那条链接（见 `clearedSplitPartners`）。
    ///
    /// `maps` 与 `snapshot` 收的是同一份：注册项要拿它把基线的身份对回本机行，才分得出
    /// 「本机已经解除」与「两半都还链着」——后者**不能**被清，否则它每轮重发一次。
    ///
    /// **一条 kind 一轮一跳。** 候选的筛选（通用规则：没有 `pendingPartnerLineage`、有基线）
    /// 留在这里，整批交给注册项在 main actor 上过一遍；没有这个概念的 kind（`nil`）连这一跳
    /// 与整个循环都不走。逐条问的写法是每条游标一次 actor 跃迁，而这个循环遍历的是这条 kind
    /// 的**每一条**游标。
    private func doctoredOwnedTable(_ registration: OwnedKindRegistration,
                                    _ table: PhiOwnedItemTable,
                                    maps: OwnedOwnerMaps,
                                    now: Int64) async -> PhiOwnedItemTable {
        guard let clear = registration.clearedSplitPartners else { return table }
        var candidates: [String: Data] = [:]
        for (identity, cursor) in table.cursors {
            guard cursor.pendingPartnerLineage == nil, let bytes = cursor.reconciled else {
                continue
            }
            candidates[identity] = bytes
        }
        guard !candidates.isEmpty else { return table }
        var doctored = table
        for (identity, cleared) in await clear(candidates, now, maps) {
            doctored.cursors[identity]?.reconciled = cleared
        }
        return doctored
    }

    /// 存活段：拓扑序 + **前缀闭包**（F2）。一条子项只在它的父也在这一片里、或父不在候选集里
    /// 时才进片，片内父排在子之前——于是对端在任何切片边界上收到的都是一棵前缀闭合的树。
    private func ownedLiveSlice(_ registration: OwnedKindRegistration,
                                snapshot: OwnedSnapshotBytes,
                                candidates: [String],
                                budget: inout Int) -> [String] {
        let candidateSet = Set(candidates)
        var parentOf: [String: String] = [:]
        for identity in candidates {
            guard let bytes = snapshot.entities[identity] else { continue }
            if let parent = registration.owners(bytes).first(where: { candidateSet.contains($0) }) {
                parentOf[identity] = parent
            }
        }
        let depths = Self.ownedDepths(of: candidates, parentOf: parentOf)
        let ordered = candidates.sorted {
            let left = depths[$0] ?? 0, right = depths[$1] ?? 0
            return left == right ? $0 < $1 : left < right
        }
        var out: [String] = []
        var admitted: Set<String> = []
        for identity in ordered {
            guard out.count < budget else { break }
            if let parent = parentOf[identity], !admitted.contains(parent) { continue }
            out.append(identity)
            admitted.insert(identity)
        }
        budget -= out.count
        return out
    }

    /// tombstone 段：反拓扑（子先于父）、**子树整取**、前置条件**只认 `.applied`**。
    ///
    /// 一个文件夹的 tombstone 推迟到它全部后代的 tombstone 已经被服务端接受之后才发
    /// （R-M3-3-24）。「排在后面」不等于「已经被接受」：二次冲突会让那几条本轮放弃，而同一轮
    /// 后面的批次照发——于是文件夹的 tombstone 带着一批没落地的后代出门，接收端回到那场提升
    /// 风暴。判据绝不认 `deletedAtMs`：§5.6 有两条路径会在服务端**没有**接受的情况下写下它。
    ///
    /// **例外，且是有意的**（B8）：一条后代走完三轮被拒的放弃支之后不再会被接受，祖先不能
    /// 因此永久卡住——此时祖先照常出门，并记一条 warning。
    private func ownedTombstoneSlice(_ registration: OwnedKindRegistration,
                                     table: PhiOwnedItemTable,
                                     candidates: [String],
                                     budget: inout Int) -> [String] {
        guard !candidates.isEmpty else { return [] }
        let candidateSet = Set(candidates)
        // 父子关系只能从基线里解出来——tombstone 没有载荷。
        var parentOf: [String: String] = [:]
        for identity in candidates {
            guard let bytes = table.cursors[identity]?.reconciled else { continue }
            if let parent = registration.owners(bytes).first(where: {
                candidateSet.contains($0) || table.cursors[$0] != nil
            }) {
                parentOf[identity] = parent
            }
        }
        var childrenOf: [String: [String]] = [:]
        for (child, parent) in parentOf { childrenOf[parent, default: []].append(child) }

        // 后代还没被接受 ⇒ 祖先这一轮不出门。
        var blocked: Set<String> = []
        var gaveUp = 0
        for identity in candidates {
            var stack = childrenOf[identity] ?? []
            while let child = stack.popLast() {
                stack.append(contentsOf: childrenOf[child] ?? [])
                // 走到这里的后代必定是本轮的候选（`childrenOf` 只从候选集建），而候选已经
                // 按 `deletedAtMs == nil` 筛过——一条上一轮就被接受的后代根本不在这张图里，
                // 所以它的祖先天然不被它挡住。
                guard let cursor = table.cursors[child] else { continue }
                if cursor.deleteRejectRounds >= Self.tombstoneRejectGiveUpRounds {
                    gaveUp += 1
                    continue
                }
                blocked.insert(identity)
            }
        }
        if gaveUp > 0 {
            AppLogWarn("[phi-sync] an owned-item ancestor tombstone is going out over "
                       + "\(gaveUp) descendant tombstone(s) the account kept rejecting "
                       + "kind=\(registration.label)")
        }

        // 子树整取：按**顶层被删祖先**分组，组要么整组进片、要么一条都不发（V16）。拆开
        // 之后，对端在两轮之间看到的是「一个文件夹里的一部分没了、另一部分还在」，而它同时
        // 还会把那个仍然存在的文件夹当成活的。
        var rootOf: [String: String] = [:]
        for identity in candidates {
            var cursor = identity
            var hops = 0
            while let parent = parentOf[cursor], hops <= candidates.count {
                cursor = parent
                hops += 1
            }
            rootOf[identity] = cursor
        }
        let depths = Self.ownedDepths(of: candidates, parentOf: parentOf)
        var groups: [String: [String]] = [:]
        for identity in candidates { groups[rootOf[identity] ?? identity, default: []].append(identity) }

        var out: [String] = []
        for root in groups.keys.sorted() {
            let members = (groups[root] ?? []).filter { !blocked.contains($0) }.sorted {
                let left = depths[$0] ?? 0, right = depths[$1] ?? 0
                return left == right ? $0 < $1 : left > right        // 子先于父
            }
            guard !members.isEmpty else { continue }
            // 单独一棵子树就超过整轮预算时照发不误：否则它每一轮都发不出去，删除永远落不
            // 了地，而切片上界存在的理由是「别把一轮堵死」，不是「宁可永远不发」。
            guard out.isEmpty || out.count + members.count <= budget else { continue }
            out.append(contentsOf: members)
        }
        budget = max(0, budget - out.count)
        return out
    }

    /// 从 `parentOf` 往上走到没有父为止，`parentOf.count` 当跳数上限（环被截断成一个有限
    /// 深度，而不是把排序挂死）。
    private static func ownedDepths(of identities: [String],
                                    parentOf: [String: String]) -> [String: Int] {
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

    /// §11.2：每条注册 kind **一行**，行名就是 `label`。字段顺序即输出顺序。
    private func logOwnedRounds() {
        guard spaceSectionEnabled, spaceStore != nil else { return }
        for registration in ownedKinds {
            var counters = ownedCounters[registration.label] ?? OwnedRoundCounters()
            let table = ownedTables[registration.label] ?? PhiOwnedItemTable()
            // `parked` 是**表的状态**，不是一个轮内增量（§11.2），所以它在这里从最终的
            // 那张表上数一次，并写回计数结构——测试面读到的与日志行印出来的是同一个数。
            let parked = table.cursors.values
                .filter { $0.pendingApply != nil || $0.pendingTombstone }.count
            counters.parked = parked
            ownedCounters[registration.label] = counters
            let unreadable = counters.unreadable
            var line = "[phi-sync] \(registration.label) pulled=\(counters.pulled) "
                + "applied=\(counters.applied) parked=\(parked) pushed=\(counters.pushed) "
                + "tombstones=\(counters.tombstones) "
            if registration.reportsAdoption {
                line += "adopted=\(counters.adopted) "
                    + "unmatched_folders=\(counters.unmatchedFolders) "
                    + "unmergeable_pairs=\(counters.unmergeablePairs) "
            }
            if registration.reportsScope { line += "relineaged=\(counters.relineaged) " }
            line += "resurrected=\(counters.resurrected) "
                + "pending_publish=\(counters.pendingPublish) refused=\(counters.refused) "
                + "superseded_by_delete=\(counters.supersededByDelete) "
                + "rehomed_cursors=\(counters.rehomedCursors) unreadable=\(unreadable) "
                + "excluded_unmapped_owner=\(counters.excludedUnmappedOwner) "
                + "local_read_failed=\(counters.localReadFailed)"
            if registration.reportsScope { line += " scope_mismatch=\(counters.scopeMismatch)" }
            AppLogInfo(line)
        }
    }

    // MARK: - Guarded writes
    //
    // Everything this engine writes into the shared `UserDefaults` goes through one of the
    // three functions here or in the section below, each of which reads the retirement flag
    // immediately before its write. The guards at the rounds' entry and suspension points are
    // an optimisation on top of that (they stop useless work and useless network), not the
    // mechanism: `shutdown()` runs concurrently with the round, so a check taken at the top of
    // `apply` or `push` says nothing about the flag's value a few statements later. See
    // `shutdown()` for the exact guarantee this buys and the residue it leaves.

    /// Single write path for the settings themselves. Returns whether the write happened, so a
    /// caller can skip the cursor bookkeeping that only makes sense once the values landed.
    @discardableResult
    private func writeSettings(_ entity: Phi_PhiSettingEntity) -> Bool {
        guard !isStopped else { return false }
        isApplyingRemote = true
        SyncableSettings.apply(entity, to: defaults, settings: settings)
        isApplyingRemote = false
        return true
    }

    private func loadSpaceTable() -> PhiSpaceSyncTable {
        spaceStore?.load() ?? PhiSpaceSyncTable()
    }

    /// Single write path for `sync.phiSpaces`, with the same retirement check every other
    /// engine write takes — a round that resumes after `shutdown()` must not write the previous
    /// account's Space shadow back over a freshly cleared table (§3.3 step 2.0).
    ///
    /// **返回值 = 这张表已落盘**（R-M3-4a-83）。两条早退**不算失败**（R-M3-4a-16）：
    /// `spaceStore == nil` 是纯设置引擎（M3-1）的**正常形态**，把它读成失败会让设置同步
    /// 从 Task 2b 落地那一刻起再也不推 marker。
    ///
    /// 主线程缓存的刷新搬进成功分支：留在 `save` 外面会让主线程展示一份**没落盘**的表
    /// ——`hiddenSpaceIds` 会把一个盘上还活着的 Space 从侧栏漏斗里滤掉，重启后它又回来。
    @discardableResult
    private func writeSpaceTable(_ table: PhiSpaceSyncTable) -> Bool {
        // 两条早退，都不是失败（R-M3-4a-16）。
        guard !isStopped, let spaceStore else { return true }
        // §2.5 第 4 条的置位点之一（计划裁定 4）：派生状态的每一次写（`markerMovedWhileGateShut`、
        // 三个 drain 标志、guard 2 的闩）都经 `mutateSpaceTable` ⇒ 这里 ⇒ 自动被覆盖。
        guard spaceStore.save(table) else {
            cursorSaveFailures += 1
            return false
        }
        Task { @MainActor in PhiSpaceSyncState.shared.refreshCaches(from: table) }
        return true
    }

    /// Read-modify-write against `sync.phiSpaces`, and the only way a round is allowed to
    /// change it. Two reasons, both of which a load-once/write-once round gets wrong:
    ///
    /// 1. **Durability.** A pull persists the shared marker page by page. Anything derived
    ///    from that marker therefore has to be persisted page by page too — and before that
    ///    page's marker (R-M3-4a-77) — or an error on page 2 throws away the record of what
    ///    page 1 already walked past, while the marker itself stays advanced. Small deltas
    ///    written where they are observed, never a whole table written at the end.
    /// 2. **Freshness.** `body` sees the table as it is *now*, not as it was before the last
    ///    suspension point, so a round can only overwrite the fields it actually touches.
    ///    The gate edge runs as its own round (`setSpaceSyncEnabled`) so it cannot interleave
    ///    in the first place; this is the belt to that suspenders, and it is what keeps
    ///    Task 9's apply path from having to think about either question again.
    ///
    /// Writes only when `body` changed something, so a no-op mutation costs no plist write and
    /// no main-actor cache refresh.
    ///
    /// **回滚之后这道 `guard table != before` 仍然正确**（R-M3-4a-83 / §2.5 第 3 条）：
    /// 一次失败的写把 `AccountUserDefaults.storage` 还原成写之前那一份，于是内存等于磁盘，
    /// 下一轮的 `loadSpaceTable()` 读到的是**旧表**，同一个改动照样被判成「变了」而重写。
    /// 少了回滚，第二轮就会在这里当场早退，`save` 根本不会被调用。
    ///
    /// **返回值 = 这次改动已落盘**（R-M3-4a-77 的「确认」靠它）：guard 2 与 per-kind 报损重放的
    /// 第 ② 步、门关记账、轮末 drain 收尾都要看它。「没变化」回 `true`——R-M3-4a-83 的回滚让
    /// 「没变化」真的等于「盘上就是这样」，所以它不是失败、也不计 `cursorSaveFailures`。
    @discardableResult
    private func mutateSpaceTable(_ body: (inout PhiSpaceSyncTable) -> Void) -> Bool {
        var table = loadSpaceTable()
        let before = table
        body(&table)
        guard table != before else { return true }
        return writeSpaceTable(table)
    }

    /// `mutateSpaceTable`'s sibling for the §5.3 intents delivered by
    /// `PhiSpaceSyncState`: the same read-modify-write against `sync.phiSpaces`,
    /// except that the intent itself reports whether it changed anything, so the
    /// caller can decide to queue a push instead of the engine guessing from a
    /// `!=` comparison.
    ///
    /// `body` may not suspend, so the read-modify-write itself cannot be torn.
    /// That is NOT what makes the intent safe, though: exclusion against the
    /// rounds that hold a table copy across their own suspensions comes from the
    /// queue, and every caller of this helper is already a `Round` body
    /// (`.recordLocalDeletion`). Never call it from a public entry point.
    @discardableResult
    private func runSpaceIntent(_ body: (inout PhiSpaceSyncTable) -> Bool) -> Bool {
        // Redundant with `writeSpaceTable`'s own `guard let spaceStore`, but it
        // avoids a pointless `PhiSpaceSyncTable()` round trip on a settings-only
        // engine.
        guard spaceStore != nil else { return false }
        var table = loadSpaceTable()
        let changed = body(&table)
        if changed { writeSpaceTable(table) }
        return changed
    }

    /// `SyncableSettings.snapshot` is a write as much as a read: for every registered key whose
    /// value differs from `<key>.phiSyncVal` it stamps `<key>.phiSyncTs = now()` and refreshes
    /// the sidecar. So it takes the same check as the settings and the cursor. `nil` means the
    /// engine was retired and nothing was stamped.
    private func snapshotLocalSettings() -> Phi_PhiSettingEntity? {
        guard !isStopped else { return nil }
        return SyncableSettings.snapshot(defaults, now: now(), settings: settings)
    }

    // MARK: - Persisted state accessors

    /// Single write path for the account-scoped cursor keys, so the shutdown check cannot be
    /// forgotten at one of the five `UserDefaults` accessors below. `nil` removes the key.
    /// The marker and the birthday do not come through here: they go to `marker.json` via
    /// `persistMarkerState`, which carries the same shutdown check.
    private func writeState(_ value: Any?, forKey key: String) {
        guard !isStopped else { return }
        guard let value else { return defaults.removeObject(forKey: key) }
        defaults.set(value, forKey: key)
    }

    /// True once this device has settings history for the account: a pull applied the account's
    /// entity, or this device committed a snapshot of its own. Either way `<key>.phiSyncTs`
    /// sidecars now exist for the registered keys, which is what makes a field-level merge
    /// meaningful — so this, not the presence of a server cursor, gates the wholesale adopt in
    /// `apply`. The two used to be the same predicate, and the coupling was a silent data
    /// loss: `clearEntityCursor()` (the tombstone heal, the full-replay branch) forgets which
    /// row the settings live in, and the next readable entity was then adopted wholesale over
    /// local edits whose debounced push had not run yet.
    ///
    /// Not derived from the sidecars themselves: those sit next to the preference keys and are
    /// not account-scoped, so they outlive the cursor wipe and would stop a device from
    /// adopting the settings of an account it has just switched to. This is cleared only by an
    /// account-scope reset of `stateKeys` — in the app that is
    /// `PhiChromiumCoordinator.resetPhiSyncCursorIfAccountChanged`, run before the new
    /// account's engine is built; `resetSyncState()` does the same wipe from in here.
    ///
    /// One known window, accepted rather than closed. When a device's only sight of the entity
    /// was `.unusable`, the pull records `storedEntityId` before dropping the baseline while
    /// `hasAdopted` remains false, and `push` returns at its "an entity id with no
    /// baseline" guard *before* `SyncableSettings.snapshot` can stamp anything. A setting the
    /// user changes in that window is therefore adopted over — not merged — once the entity
    /// becomes readable, with no log line of its own.
    ///
    /// Merging there instead would cost more. `snapshot` treats a key with no `<key>.phiSyncVal`
    /// as locally changed, so on a device with no sidecar history at all it stamps *every*
    /// registered key `now`: the merge would hand this device's whole local default set the
    /// newest timestamps in the account and the trailing push would publish it over every other
    /// device. Stamping the sidecars inside the guard to "give the merge real timestamps" has
    /// the same defect — the fabricated timestamps would be `now` for every key, not just the
    /// one the user touched, because nothing here knows which key changed. So the guard leaves
    /// no trace on purpose, and the smaller loss stands.
    /// `testAnUnreadableEntityLaterAdoptsWholesaleOverAnEditMadeInThatWindow` pins the choice.
    private var hasAdopted: Bool {
        get { defaults.bool(forKey: Self.hasAdoptedStateKey) }
        set {
            let stored: Bool? = newValue ? true : nil
            writeState(stored, forKey: Self.hasAdoptedStateKey)
        }
    }

    /// Forgets which entity the account's settings live in, keeping the progress marker, the
    /// store birthday and `hasAdopted` — this says the row is gone, never that this device has
    /// no settings history. Used when the server proves that entity is gone; the next round
    /// takes the create path, which the server resolves by `client_tag_hash`.
    private func clearEntityCursor() {
        storedEntityId = nil
        storedVersion = nil
        storedLastEntity = nil
    }

    /// `clearEntityCursor()` plus the progress marker, so the next pull replays the whole type
    /// instead of asking for changes after a watermark that describes a row the server no
    /// longer has. Same-account recovery — the store birthday and `hasAdopted` stay.
    private func clearRemoteCursor() {
        clearEntityCursor()
        storedMarker = nil
    }

    /// The store this device was tracking is gone (NOT_MY_BIRTHDAY): every cursor that
    /// describes it is void, birthday included, and any tombstone streak counted against the
    /// old store means nothing.
    ///
    /// `hasAdopted` survives, because the *account* did not change — only the server's store
    /// identity did. The `<key>.phiSyncTs` sidecars this device has been keeping still describe
    /// this account's settings, so the next readable entity must be merged against them, not
    /// adopted over them. (Only an account-scope reset of `stateKeys` clears it — see
    /// `hasAdopted`.) The Space table's *server-side* triples are cleared alongside for the
    /// same reason and with the same exception: what describes the store goes, what describes
    /// this account's own history stays.
    private func resetForNewStoreBirthday() {
        canPublishThisRound = false
        clearRemoteCursor()
        storedBirthday = ""
        tombstoneRounds = 0
        guard spaceStore != nil else { return }
        // The server holds a different data set now, so every server-side triple and every
        // loss guard has to be re-armed. `reconciled` / `hidden` / `deletedAtMs` / `purgedAtMs`
        // survive: the ACCOUNT did not change, and clearing them would re-arm the wholesale
        // adopt and silently drop edits this device has just stamped.
        mutateSpaceTable { table in
            for (uuid, var cursor) in table.cursors {
                cursor.entityId = nil
                cursor.version = 0
                cursor.server = nil
                cursor.deleteRejectRounds = 0
                table.cursors[uuid] = cursor
            }
            table.hasDrainedFullReplay = false
            table.drainInProgress = false
            table.markerMovedWhileGateShut = false
            table.didReplayForEmptyTable = false
            table.lastDrainedBirthday = nil
            table.unreadableTagHashes = [:]
            table.bookmarksReplayedForEmptyTable = false
            table.pinsReplayedForEmptyTable = false
        }
        // 归属 kind 的游标表同理，逐字同一条界线：**服务端那一侧的三元组归零，本机对
        // 「我上次与账户对齐到什么」的记忆原样保留**。清表或删文件会毁掉每一份 `reconciled`
        // 基线，而 §3.5 说那正是触发账户级盲写覆盖的状态。
        for registration in ownedKinds {
            var table = ownedTables[registration.label] ?? registration.store
                .load(hadRecords: loadSpaceTable()[keyPath: registration.flags.hadRecords]).table
            for (identity, var cursor) in table.cursors {
                cursor.entityId = ""
                cursor.version = 0
                cursor.server = nil
                cursor.deleteRejectRounds = 0
                // R-exec-13：换了 store，之前那几次拒绝什么都不再证明。不清的话，一台在旧
                // store 上放弃过补键的机器**在新 store 上**也永远不会去认那几行——而 reset
                // 刚刚把全表的 `entityId` 清空，补键正是它们回到账户上的唯一通路。
                cursor.rekeyRejectRounds = nil
                table.cursors[identity] = cursor
            }
            writeOwnedTable(registration, table)
        }
    }

    private var storedEntityId: String? {
        get { defaults.string(forKey: Self.entityIdStateKey) }
        set { writeState(newValue, forKey: Self.entityIdStateKey) }
    }

    private var storedVersion: Int64? {
        get { (defaults.object(forKey: Self.versionStateKey) as? NSNumber)?.int64Value }
        set { writeState(newValue.map { NSNumber(value: $0) }, forKey: Self.versionStateKey) }
    }

    /// marker / birthday 的唯一写穿口（M3-4a §2.10）：镜像先改、再落盘，落盘失败就回滚镜像。
    ///
    /// `guard !isStopped` 是从 `writeState` 原样继承过来的，**不可省**：`stateKeys` 收缩之后
    /// 「shutdown 之后没有 state key 被写」那两条既有断言不再覆盖 marker，而一个已退休的
    /// 引擎恰好还持着**上一个账户目录**的 store（自撤销第 1 步退休引擎、第 4 步删文件，一个
    /// 还挂在 `getUpdates` 里的轮次醒来若把 marker 写回去，就把 §4.4 防的那个灾难原样造出来）。
    ///
    /// 失败回滚是 R-M3-4a-83 的同一条理由搬到 marker 上：不回滚 ⇒ 镜像领先磁盘 ⇒ 第 N+1 轮
    /// 重投同一页时 `updated != markerState` 不成立 ⇒ 连 `save` 都不调 ⇒ marker「推进」了而
    /// 盘上没有。两个 setter 仍然丢掉返回值；`cursorSaveFailed` 的第三个置位点就在这里的
    /// `false` 支（计划裁定 4）：marker 或 birthday 任一写失败都算这一轮落盘失败，页循环在页末
    /// 读 `cursorSaveFailures` 收口。要看 Bool 的调用点走 `persistStoredMarker(_:)`。
    @discardableResult
    private func persistMarkerState(_ updated: PhiSyncMarkerFile) -> Bool {
        guard !isStopped else { return true }              // §2.5 第 4 条：早退不算失败
        guard updated != markerState else { return true }  // 没变化就不调 save，同上
        let previous = markerState
        markerState = updated
        guard markerStore.save(updated) else {
            markerState = previous
            cursorSaveFailures += 1
            return false
        }
        return true
    }

    /// `storedMarker` setter 的带回传版本：页末的 marker 写、guard 2 与 per-kind 报损重放的
    /// 第 ① 步都要看它的 Bool。归一化与 setter 相同（空 marker 存成 nil）。
    @discardableResult
    private func persistStoredMarker(_ newValue: Data?) -> Bool {
        var updated = markerState
        updated.marker = Self.normalizedMarker(newValue)
        return persistMarkerState(updated)
    }

    /// An empty marker is stored as `nil`: on the wire "no marker" and "empty marker" are the
    /// same request, and `nil` is the value every full-replay predicate here compares against.
    private static func normalizedMarker(_ marker: Data?) -> Data? {
        (marker?.isEmpty ?? true) ? nil : marker
    }

    /// The empty string is "not known yet" on the wire. It lives in `marker.json` beside the
    /// marker (M3-4a): the birthday is written page by page (§2.4), and the two must roll back
    /// together on a user-data import — a birthday kept anywhere else would come back stale
    /// and loop on NOT_MY_BIRTHDAY.
    private var storedBirthday: String {
        get { markerState.storeBirthday }
        set {
            var updated = markerState
            updated.storeBirthday = newValue
            persistMarkerState(updated)
        }
    }

    /// See `normalizedMarker`: an empty marker is stored as `nil`. The setter discards the
    /// write's Bool; call sites that need it go through `persistStoredMarker(_:)`.
    private var storedMarker: Data? {
        get { markerState.marker }
        set { persistStoredMarker(newValue) }
    }

    /// Consecutive pulls that found the account's settings row tombstoned. Zero is stored as
    /// "absent" so `stateKeys` stays a clean "nothing persisted" set after a cursor wipe.
    private var tombstoneRounds: Int {
        get { defaults.integer(forKey: Self.tombstoneRoundsStateKey) }
        set {
            let stored: Int? = newValue > 0 ? newValue : nil
            writeState(stored, forKey: Self.tombstoneRoundsStateKey)
        }
    }

    private var storedLastEntity: Phi_PhiSettingEntity? {
        get {
            guard let bytes = defaults.data(forKey: Self.lastEntityStateKey) else { return nil }
            return try? Phi_PhiSettingEntity(serializedBytes: bytes)
        }
        set { writeState(newValue.flatMap { try? $0.serializedData() }, forKey: Self.lastEntityStateKey) }
    }
}

// MARK: - 书签那一条注册项
//
// **这是整个引擎里唯一知道「书签」这个词的地方。** 上面的引擎代码一条 kind 分支都没有：
// 它按注册清单驱动一切，清单里有什么就跑什么。pin 那一条由 Task 5b-2 以同样的形状追加。

/// 书签适配的轮内可变状态。
///
/// 它存在的理由与 `AccountPhiBookmarkAccess` 那份缓存一样：轮首那一次 fetch 的结果要交给
/// 快照、差分、index 投影与落地四个消费者复用（§5.7 第 2 条硬要求）。
@MainActor
final class BookmarkSyncRoundState {
    private(set) var locals: [PhiLocalBookmark] = []
    private(set) var identityToGuid: [String: String] = [:]
    private(set) var rowByGuid: [String: PhiLocalBookmark] = [:]
    /// 本轮 §6 的认领配对：实体身份 -> 本机 guid。
    ///
    /// **累加，不覆盖**：归属段最前面那一趟停放项重试与落地段的 `plan` 都会往里写，而出站
    /// 快照的「这一行本轮不铸新身份」与差分的 `pendingClaims` 豁免读的是两者的并集。
    private(set) var pairs: [String: String] = [:]

    func mergePairs(_ pairs: [String: String]) {
        for (identity, guid) in pairs { self.pairs[identity] = guid }
    }

    /// 把本轮**中途真的写回本机行**的那些身份折回轮首那份快照。
    ///
    /// 一轮至多一次 fetch 的规则不变：这里改的是内存里那份投影，不是再读一次库。不折回去，
    /// 同一轮的落地段看到的还是「这一行没有身份」，于是它可能把**第二个**身份配给同一条行
    /// ——`applyBookmarkSyncBatchThrowing` 会用 `rowAlreadyMapped` 拒掉那个 Space 的**整批**
    /// （拒收而不是停放），那些入站实体既没有游标也永远不会重投。
    func notePersistedClaims(_ pairs: [String: String]) {
        for (identity, guid) in pairs {
            guard let index = locals.firstIndex(where: { $0.guid == guid }) else { continue }
            locals[index].syncId = identity
            rowByGuid[guid]?.syncId = identity
            identityToGuid[identity] = guid
        }
    }

    /// 把本轮**真的被删掉**的那些行从轮内投影里拿掉。
    ///
    /// 与 `notePersistedClaims` 同一条纪律（改的是内存里那份投影，不是再读一次库），方向
    /// 相反。不拿掉的话，同一轮的**发布段**仍然看得见那一行：它的游标此刻是「有
    /// `deletedAtMs`、没有 `reconciled`」，而 §4.2 第 3b 条对「有 `deletedAtMs` + 有活行」的
    /// 回答是**复活并重新发布**——一次远端删除会被同一轮的发布段原地撤销掉，对端下一轮收到
    /// 的是一条它刚刚删过的书签又回来了（CASE 6b.8）。
    func noteDeletedRows(_ guids: Set<String>) {
        guard !guids.isEmpty else { return }
        for guid in guids {
            if let syncId = rowByGuid[guid]?.syncId { identityToGuid.removeValue(forKey: syncId) }
            rowByGuid.removeValue(forKey: guid)
        }
        locals.removeAll { guids.contains($0.guid) }
    }

    func reload(_ rows: [PhiLocalBookmark]) {
        locals = rows
        identityToGuid = [:]
        rowByGuid = [:]
        for row in rows {
            rowByGuid[row.guid] = row
            if let syncId = row.syncId { identityToGuid[syncId] = row.guid }
        }
        pairs = [:]
    }

    /// 一次落地之后把轮内那份本机投影换成**落地后**的行（Step 3）。
    ///
    /// 交进来的是 access 那份缓存（`apply(_:)` 收尾已经重建过它），**不是第二次 fetch**：
    /// 一轮至多一次 fetch 的规则一个字不变。
    ///
    /// **内容与位置一起换。** 只换标题与 URL 的实现会在每一次入站搬家之后把**旧位置**配上
    /// 一个新鲜的 `now` 发回去，把对端刚做的移动原地撤销——`parentGuid` / `spaceId` /
    /// `index` 三项因此都在这一次替换里。
    ///
    /// **`pairs` 不动。** 它是本轮 §6 的认领配对，出站快照的「这一行本轮不铸新身份」与差分
    /// 的 `pendingClaims` 豁免都读它；清掉它，一条刚被认领的行会在同一轮里再被铸一个身份，
    /// 而账户上从此多一条没有本地所有者的实体。`reload` 清它是因为那是**新一轮**的开始，
    /// 这里是同一轮的中途。
    func refreshLandedRows(_ rows: [PhiLocalBookmark]) {
        locals = rows
        identityToGuid = [:]
        rowByGuid = [:]
        for row in rows {
            rowByGuid[row.guid] = row
            if let syncId = row.syncId { identityToGuid[syncId] = row.guid }
        }
    }
}

/// 同级分组的键。`parentGuid == nil` = 直接挂在这个 Space 的 canonical root 下。
private struct BookmarkSiblingGroup: Hashable {
    var spaceId: String
    var parentGuid: String?
}

private extension PhiLocalBookmark {
    /// 差分只问 `identity(of local:)`（书签就是 `syncId`），所以 §4.7 的定义域可以用一组
    /// 只带身份的壳表达——它来自 `allSyncIds()`，**不是**快照（R-exec-4）。
    static func identityOnly(_ syncId: String) -> PhiLocalBookmark {
        PhiLocalBookmark(syncId: syncId, guid: syncId, spaceId: "", profileId: "",
                         parentGuid: nil, index: 0, isFolder: false, title: "",
                         url: URL(string: "https://bookmark.phi/folder")!,
                         secondaryUrl: nil, secondaryTitle: nil, source: 0,
                         createdDate: Date(timeIntervalSince1970: 0), contentUpdatedDate: nil)
    }
}

extension OwnedKindRegistration {
    /// `BookmarkKind` 那一条注册项。
    @MainActor
    static func bookmarks(access: any PhiBookmarkLocalAccess,
                          store: any PhiOwnedItemStateStore) -> OwnedKindRegistration {
        let state = BookmarkSyncRoundState()
        return OwnedKindRegistration(
            label: "bookmarks",
            tagPrefix: PhiSyncEntity.bookmarkTagPrefix,
            entityName: PhiSyncEntity.bookmarkEntityName,
            store: store,
            flags: .bookmarks,
            reportsAdoption: true,
            reportsScope: false,
            identity: { envelope in
                guard let entity = BookmarkKind.entity(from: envelope) else { return nil }
                let identity = BookmarkKind.identity(of: entity)
                return identity.isEmpty ? nil : identity
            },
            clientTag: PhiSyncEntity.bookmarkClientTag,
            owners: { bytes in
                guard let envelope = try? Phi_PhiEntity(serializedBytes: bytes),
                      let entity = BookmarkKind.entity(from: envelope) else { return [] }
                return BookmarkKind.ownerUuids(of: entity)
            },
            // 书签没有拆分伙伴这个概念，§7.4 的表副本对它是恒等变换：`nil` 让那一段连 main
            // actor 那一跳与整个循环都不走。
            clearedSplitPartners: nil,
            beginRound: { state.reload(try access.allBookmarks()) },
            // §5.1 的索引种子：游标键 ∪ **本机全部非 nil 的 `syncId`**——问的是
            // `allSyncIds()` 而不是快照，于是孤儿根下面那些行的 tombstone 也路由得到。
            // 轮首那次读失败时它落回快照里的身份（此时快照也是空的）。
            localIdentities: {
                (try? access.allSyncIds()) ?? Set(state.locals.compactMap(\.syncId))
            },
            snapshot: { table, maps, now in
                bookmarkSnapshot(table: table, maps: maps, now: now, state: state)
            },
            tombstones: { table, maps, now in
                // R-exec-4：定义域问 `allSyncIds()`，**不问快照**。两者的差集是孤儿根 /
                // 重复根下面的整棵子树——那些行在库里、`syncId` 也在，但快照按契约把它们整棵
                // 排除。用快照当判据，它们会被逐条判成「本机没有」而各发一条 tombstone，
                // 把账户上一整棵真实存在的子树删掉，而本机那些行还在原地。
                let live = try access.allSyncIds()
                // R-exec-9：本轮 §6 的认领配上了、但 `syncId` 的写回还没落盘的那些身份不进
                // 删除集。**配上了**是判据，`pendingApply` 不是：一条认领**配不上**的停放
                // 游标正是该被差分清理掉的那一类。认领成功写回的那些身份此刻已经在
                // `allSyncIds()` 里，所以整张配对表交进去与「只交没写回去的那几条」等价。
                return SyncableOwnedItems.tombstones(
                    BookmarkKind.self, locals: live.map(PhiLocalBookmark.identityOnly),
                    table: table, resolve: maps.resolver, scope: nil, nowMs: now,
                    pendingClaims: Set(state.pairs.keys))
            },
            retryParkedClaims: { parked, maps in
                await retryParkedBookmarkClaims(parked, maps: maps, access: access, state: state)
            },
            plan: { input in bookmarkPlan(input, state: state) },
            land: { input in await landBookmarks(input, access: access, state: state) },
            claimIdentities: { minted in
                await claimBookmarkIdentities(minted, access: access, state: state)
            },
            // §9.3 的级联。判据 (b) 问 `allSyncIds()`——本机**所有**带身份的行，不做根过滤
            // （R-exec-4，与差分的定义域同一条）：孤儿根下面那些行不进快照、永远不发布，
            // 但它们是活的本地行，删掉它们的游标与删掉任何一条活行的游标后果相同。
            liveOwners: { candidates, maps in
                let resolve = maps.resolver
                var out = OwnedLiveRows()
                out.claimed = try candidates.intersection(access.allSyncIds())
                // rehome 要写的值与发布段每轮刷进 `ownerUuid` 的是**同一个函数**
                // （`eligibilityOwner`：这一行坐在哪个 Space 里），所以级联改写出来的值与
                // 下一轮 pre-pass 刷出来的值不可能分叉（A12 / §3.5 的一个实现点）。
                for row in state.locals {
                    guard let identity = row.syncId, out.claimed.contains(identity),
                          let owner = BookmarkKind.eligibilityOwner(of: row, resolve: resolve,
                                                                    scope: nil)
                    else { continue }
                    out.owners[identity] = owner
                }
                return out
            })
    }
}

/// §4.2 的出站快照 + §6.4 的候选身份铸造（**只在内存里**）。
@MainActor
private func bookmarkSnapshot(table: PhiOwnedItemTable, maps: OwnedOwnerMaps, now: Int64,
                              state: BookmarkSyncRoundState) -> OwnedSnapshotBytes {
    var out = OwnedSnapshotBytes()
    let resolve = maps.resolver
    // §4.2 第 2 条：未同步行的候选身份在内存里填进 `syncId`，真正写回本机行要等提交被
    // 接受（§6.4）。铸在这里而不是在提交那一刻算，是因为同一份候选身份既要进快照的
    // `bookmark_uuid`，又要进它孩子的 `parent_uuid`。
    // **本轮已经被 §6 认领配对的行不铸新身份。** 那条行正在（或正准备）接过一个账户上
    // 已经存在的身份；再给它铸一个，账户上就会多出第二条实体，而本机只有一行能认领其中
    // 一个——另一个从此没有本地所有者。`state.locals` 是轮首那份快照，认领写回 `syncId`
    // 之后它并不会自己变新，所以这条判据必须读配对表而不是读 `syncId`。
    let claimedGuids = Set(state.pairs.values)
    var locals = state.locals
    for index in locals.indices
    where locals[index].syncId == nil && !claimedGuids.contains(locals[index].guid) {
        let identity = UUID().uuidString.lowercased()
        locals[index].syncId = identity
        out.minted[identity] = locals[index].guid
    }
    let result = SyncableOwnedItems.snapshot(BookmarkKind.self, locals: locals, table: table,
                                             resolve: resolve, scope: nil, now: now)
    out.skippedUnmappedOwner = result.skippedUnmappedOwner
    out.skippedIneligibleOwner = result.skippedIneligibleOwner
    for (identity, entity) in result.entities {
        guard let bytes = try? BookmarkKind.envelope(entity).serializedData() else { continue }
        out.entities[identity] = bytes
    }
    // A12 / §3.5：身份 -> 这一行**当前所在的归属**，引擎每轮刷进游标的 `ownerUuid`。
    for row in locals {
        guard let identity = row.syncId,
              let owner = BookmarkKind.eligibilityOwner(of: row, resolve: resolve, scope: nil)
        else { continue }
        out.ownerUuids[identity] = owner
    }
    // 铸出来却没进快照的身份（归属不合格、或祖先链不合格）不留铸造记录：那一条这一轮不会
    // 提交，下一轮重铸。留着会让一次 `.applied` 之外的路径把身份写回本机行。
    out.minted = out.minted.filter { out.entities[$0.key] != nil }
    return out
}

/// §4.4 的入站计划 + §6 的认领。
@MainActor
private func bookmarkPlan(_ input: OwnedPlanInput,
                          state: BookmarkSyncRoundState) -> OwnedPlanOutput {
    var out = OwnedPlanOutput()
    let resolve = input.maps.resolver
    var arrivals: [OwnedItemArrival<Phi_PhiBookmarkEntity>] = []
    for item in input.arrivals {
        guard let envelope = try? Phi_PhiEntity(serializedBytes: item.payload),
              let entity = BookmarkKind.entity(from: envelope) else { continue }
        arrivals.append(OwnedItemArrival(entity: entity, entityId: item.entityId,
                                         version: item.version))
        out.serverBytes[BookmarkKind.identity(of: entity)] = item.payload
        // §5.3 的尽力推迟：**只数这一轮真的到达过的实体**，停放项不算。一条停着的实体是
        // 上一轮的消息，拿它当「这个 Space 正在到货」会让一条永远落不了地的停放项把整个
        // Space 的未同步行永久压在切片外面。
        //
        // 归属取实体自己的 `space_uuid`（**不是** `parent_uuid`）：判据说的是 Space，而一条
        // 子孙实体的绑定引用是它的父。子孙的 `space_uuid` 永不重发（R-M3-3-18），所以它可能
        // 停在搬家之前的那个 Space 上——**这条推迟是优化而不是正确性规则**，一个过期的 uuid
        // 最坏只是让某个 Space 的未同步行多等一轮，不会让任何东西丢失或重复。真正守住「不丢」
        // 的是 §6 那条无状态的认领规则。
        let spaceUuid = entity.spaceUuid.stringValue
        if !spaceUuid.isEmpty { out.deferredOwners.insert(spaceUuid) }
    }
    // D10 的规则 (i)。它**从不删除任何东西**，也不会让任何入站实体被丢掉。
    //
    // **停放项也进认领**：§6.1 那条规则是无状态、连续的，而一条停放着的实体与一条刚到达的
    // 实体对它没有区别。少了这一半，一条身份已经被账户接受、但 `syncId` 还没能写回本机行的
    // 实体（写回被导入锁挡住）会在下一轮被当成一条全新的实体建出第二行来。
    var candidates = arrivals.map(\.entity)
    let arrivedIdentities = Set(candidates.map(BookmarkKind.identity(of:)))
    for identity in input.parked.keys.sorted() where !arrivedIdentities.contains(identity) {
        guard let payload = input.parked[identity]?.payload,
              let envelope = try? Phi_PhiEntity(serializedBytes: payload),
              let entity = BookmarkKind.entity(from: envelope) else { continue }
        candidates.append(entity)
    }
    let adoption = SyncableOwnedItems.adopt(arrivals: candidates,
                                            locals: state.locals, resolve: resolve)
    var context = OwnedItemPlanContext()
    context.pairs = adoption.pairs
    context.adoptedMerges = adoption.merges
    context.adoptedFieldWrites = adoption.fieldWrites
    context.tombstonedIdentities = input.tombstoned
    context.localProjections = bookmarkLocalProjections(
        for: Set(arrivals.map { BookmarkKind.identity(of: $0.entity) })
            .union(input.parked.keys),
        table: input.table, resolve: resolve, now: input.now, state: state)
    context.liveLocalParents = Set(state.locals.filter(\.isFolder).compactMap(\.syncId))
    context.deletedSubtree = bookmarkDeletedSubtree(input.tombstoned, state: state)
    out.plan = SyncableOwnedItems.plan(BookmarkKind.self, arrivals: arrivals,
                                       parked: input.parked, table: input.table,
                                       resolve: resolve, context: context)
    state.mergePairs(adoption.pairs)
    out.adopted = adoption.adopted
    out.unmatchedFolders = adoption.unmatchedFolders
    out.unmergeablePairs = adoption.unmergeablePairs
    // 两条来源、同一条规则（§6.2 的「本机赢了字段就要发布出去」）：认领那一批由 `adopt`
    // 算，已经在账户上的那些由 `plan` 算。
    out.mustRepublish = adoption.mustRepublish.union(out.plan.mustRepublish)
    return out
}

/// 身份 -> 本机那一行**此刻**的出站投影，喂给 `OwnedItemPlanContext.localProjections`。
///
/// 盖戳走的是 `snapshot` 那一条路（`BookmarkKind.stamp` + 基线），不是 `adopt` 那一条：
/// **变过的字段盖 `now`、没变的沿用基线的戳**（§4.2 第 4 条）。用 `adopt` 那条无基线规则
/// （整组内容字段一起盖 `contentUpdatedDate`）会让一条**没被本机动过**的字段也带上一个新鲜
/// 的戳，于是对端刚做的改名被一个本机从没改过的旧值赢掉——方向与它要修的缺陷正好相反。
///
/// 三处跳过，每一处都让那条身份退回「与基线合并」的老路：
/// - 本机没有这一行（纯远端新建 / 已被删）；
/// - 游标没有基线（认领那一批、以及游标文件丢失后的重放）——没有基线时 `stamp` 会把
///   `location` / `rank` 盖成 0，那是 §4.2 第 5 条给**未同步行**的规则；
/// - 父行还没有身份：那条子行的 `parent_uuid` 填不出来，投影出来的会是一条根级实体，
///   它的 `location` 值与真实位置不同，合并出来的位置于是是错的。
@MainActor
private func bookmarkLocalProjections(for identities: Set<String>,
                                      table: PhiOwnedItemTable,
                                      resolve: OwnerResolver,
                                      now: Int64,
                                      state: BookmarkSyncRoundState) -> [String: Data] {
    var out: [String: Data] = [:]
    for identity in identities {
        guard let guid = state.identityToGuid[identity], let row = state.rowByGuid[guid],
              let baselineBytes = table.cursors[identity]?.reconciled,
              let baselineEnvelope = try? Phi_PhiEntity(serializedBytes: baselineBytes),
              let baseline = BookmarkKind.entity(from: baselineEnvelope) else { continue }
        var parentIdentity: String?
        if let parentGuid = row.parentGuid {
            guard let parent = state.rowByGuid[parentGuid]?.syncId else { continue }
            parentIdentity = parent
        }
        guard let projected = BookmarkKind.project(row, resolve: resolve, scope: nil,
                                                   parentIdentity: parentIdentity) else { continue }
        // rank 取基线那一个：本轮的 rank 只有 `snapshot` 的 `assignRanks` 算得出来，而入站
        // 这一侧不该为了合并去跑一次账户级排序。于是一次**还没发布**的本机纯排序在这一轮
        // 输给对端的 rank——下一轮的快照照常把它当成一次本机变化重新发出去。
        let stamped = BookmarkKind.stamp(projected, baseline: baseline, local: row,
                                         rank: BookmarkKind.rank(of: baseline), now: now)
        guard let bytes = try? BookmarkKind.envelope(stamped).serializedData() else { continue }
        out[identity] = bytes
    }
    return out
}

/// §6.4 的身份写回，**按 Space 切开**。
///
/// 导入锁是 fail-closed 的：一批横跨两个 Space、其中一个正在导入的写回会被整批拒掉，于是另一个
/// Space 里那些**服务端已经接受**的身份也写不回本机行。返回真的写下去了的那些身份。
@MainActor
private func claimBookmarkIdentities(_ pairs: [String: String],
                                     access: any PhiBookmarkLocalAccess,
                                     state: BookmarkSyncRoundState) async -> Set<String> {
    var bySpace: [String: [BookmarkApplyOp]] = [:]
    var identitiesBySpace: [String: Set<String>] = [:]
    for (identity, guid) in pairs.sorted(by: { $0.key < $1.key }) {
        let spaceId = state.rowByGuid[guid]?.spaceId ?? ""
        bySpace[spaceId, default: []].append(.claim(guid: guid, syncId: identity))
        identitiesBySpace[spaceId, default: []].insert(identity)
    }
    var persisted: Set<String> = []
    for spaceId in bySpace.keys.sorted() {
        guard let ops = bySpace[spaceId], !ops.isEmpty else { continue }
        do {
            try await access.apply(BookmarkApplyBatch(unordered: ops))
            persisted.formUnion(identitiesBySpace[spaceId] ?? [])
        } catch {
            AppLogError("[phi-sync] bookmark identities could not be written back "
                        + "count=\(ops.count) (\(PhiSyncLog.describe(error)))")
        }
    }
    return persisted
}

/// §3 / R-exec-10 的停放项重试，书签这一半：拿停放着的那些载荷重新走一次 §6 的认领，配上的
/// 立刻写回本机行。
///
/// 它跑在**每一种轮次**的归属段最前面，所以一次纯 push 轮也能把「这一行已经配上一个账户身份」
/// 这件事告诉后面的快照与差分。配不上的原样留着停放——那条身份下一轮再试，真的一直配不上就由
/// 差分按「本机没有这一行」清理掉（R-exec-9 的另一半）。
@MainActor
private func retryParkedBookmarkClaims(_ parked: [String: ParkedOwnedItem],
                                       maps: OwnedOwnerMaps,
                                       access: any PhiBookmarkLocalAccess,
                                       state: BookmarkSyncRoundState) async
    -> OwnedParkedClaimResult {
    var out = OwnedParkedClaimResult()
    var entities: [Phi_PhiBookmarkEntity] = []
    for identity in parked.keys.sorted() {
        guard let payload = parked[identity]?.payload,
              let envelope = try? Phi_PhiEntity(serializedBytes: payload),
              let entity = BookmarkKind.entity(from: envelope) else { continue }
        entities.append(entity)
    }
    guard !entities.isEmpty else { return out }
    let adoption = SyncableOwnedItems.adopt(arrivals: entities, locals: state.locals,
                                            resolve: maps.resolver)
    guard !adoption.pairs.isEmpty else { return out }
    out.paired = Set(adoption.pairs.keys)
    state.mergePairs(adoption.pairs)
    out.persisted = await claimBookmarkIdentities(adoption.pairs, access: access, state: state)
    var persistedPairs: [String: String] = [:]
    for identity in out.persisted {
        guard let guid = adoption.pairs[identity] else { continue }
        persistedPairs[identity] = guid
    }
    state.notePersistedClaims(persistedPairs)
    return out
}

/// A9 的第三个合取项：本轮因为一条远端文件夹 tombstone 而要消失的身份。
@MainActor
private func bookmarkDeletedSubtree(_ tombstoned: Set<String>,
                                    state: BookmarkSyncRoundState) -> Set<String> {
    var childrenOf: [String: [PhiLocalBookmark]] = [:]
    for row in state.locals {
        guard let parent = row.parentGuid else { continue }
        childrenOf[parent, default: []].append(row)
    }
    var out: Set<String> = []
    var stack = tombstoned.compactMap { state.identityToGuid[$0] }
    var hops = 0
    let limit = state.locals.count * 2 + 1
    while let guid = stack.popLast(), hops < limit {
        hops += 1
        for child in childrenOf[guid] ?? [] {
            if let identity = child.syncId { out.insert(identity) }
            stack.append(child.guid)
        }
    }
    return out
}

/// §4.4 / §4.5 的落地：按 Space 切开、rank → index 投影、三相批次、落地后复核。
@MainActor
private func landBookmarks(_ input: OwnedLandingInput,
                           access: any PhiBookmarkLocalAccess,
                           state: BookmarkSyncRoundState) async -> OwnedLandingOutcome {
    var outcome = OwnedLandingOutcome()
    guard !input.steps.isEmpty else { return outcome }
    let resolve = input.maps.resolver

    struct Planned {
        var step: OwnedItemApplyStep
        var entity: Phi_PhiBookmarkEntity?
    }
    var planned: [Planned] = []
    for step in input.steps {
        let entity = step.payload.flatMap { bytes -> Phi_PhiBookmarkEntity? in
            guard let envelope = try? Phi_PhiEntity(serializedBytes: bytes) else { return nil }
            return BookmarkKind.entity(from: envelope)
        }
        planned.append(Planned(step: step, entity: entity))
    }

    // 身份 -> 本轮要用的本机 guid。
    var guidOf: [String: String] = [:]
    for item in planned {
        if let guid = state.pairs[item.step.identity] ?? state.identityToGuid[item.step.identity] {
            guidOf[item.step.identity] = guid
        }
    }

    // §6.1 / CASE 6b.13：**这里没有「配对表指着一条已被认领的行」的降级支，因为那个状态到不
    // 了这里。** 一条 `.claim` step 只在 `context.pairs[身份] != nil` 时产出，而那张配对表来自
    // `SyncableOwnedItems.adopt`——它的 `localChildren` 只收 `syncId == nil` 的行，且组内按位
    // 一对一配（两条同键的入站实体对一条本机行只配得上第一条，第二条落进 `leftOver` 并走
    // create）。`bookmarkPlan` 在返回前把那批配对并进 `state.pairs`，所以 `guidOf` 对每一条
    // `.claim` 都解析自 `state.pairs`；而 `state.rowByGuid` 由 `reload` 与
    // `notePersistedClaims` 与 `state.locals` 同步维护，`plan` 与这里之间没有任何东西改过它。
    //
    // 真 store 那道 `rowAlreadyMapped`（`LocalStore+Bookmark.swift` 的
    // `node.syncId == nil || node.syncId == syncId`，R-M3-3-14 要求的「静默结果必须变成抛错」）
    // 因此是**深度防御**，接的是另一种形状：目标行**在这一批之前**就已经带着另一个身份。
    // 同一批里的两条 `.claim` 打在同一条尚未认领的行上不走它——真 store 边走边写
    // （第二条会看见第一条刚写下的 `syncId` 而抛），而假件是拿施加任何 op 之前的 `rows` 先扫
    // 一遍整批，两条都看见 `syncId == nil`。落地这一侧因此没有一条能自愈的路，写一条降级支
    // 只会是永远跑不到的死代码；真正守住这条不变量的是上面那条配对规则，CASE 6b.13 断的也是
    // 它（那一行最后带的是第一条身份、本机多出一条新行）。

    // §4.6 的**物理行**判据（`refuses(_:baseline:)` 够不着它——那一个比的是游标基线，而这条
    // 身份本机可能根本没有基线）。落地会把一条书签行原地变成文件夹，它的 URL 随即失去意义；
    // 反方向则让一个文件夹变成书签，**它的孩子当场失去父**。
    var work: [Planned] = []
    for item in planned {
        if let entity = item.entity, let guid = guidOf[item.step.identity],
           let isFolder = access.localIsFolder(guid: guid), isFolder != entity.isFolder {
            outcome.refused.insert(item.step.identity)
            continue
        }
        work.append(item)
    }
    // 排在前面的 create 先铸 guid，后面的孩子才解析得到父。
    for item in work where item.step.kind == .create && guidOf[item.step.identity] == nil {
        guidOf[item.step.identity] = UUID().uuidString
    }
    guard !work.isEmpty else { return outcome }

    let deletedIdentities = Set(work.filter { $0.step.kind == .delete }.map(\.step.identity))
    let deletedGuids = Set(deletedIdentities.compactMap { guidOf[$0] })

    // 本轮的落地投影：从轮首那份快照起手，逐条把位置改成计划里的位置。它同时是「父在哪个
    // Space」这个问题的答案来源——一条行的父必定与它同 Space。
    var projected = state.rowByGuid
    var rankOf: [String: String] = [:]
    for (identity, cursor) in input.table.cursors {
        guard let bytes = cursor.reconciled,
              let envelope = try? Phi_PhiEntity(serializedBytes: bytes),
              let entity = BookmarkKind.entity(from: envelope) else { continue }
        rankOf[identity] = BookmarkKind.rank(of: entity)
    }

    var placed: [(item: Planned, guid: String, group: BookmarkSiblingGroup)] = []
    var touched: Set<BookmarkSiblingGroup> = []
    var parentOf: [String: String] = [:]
    var payloadOf: [String: Data] = [:]

    for item in work {
        let identity = item.step.identity
        if let payload = item.step.payload { payloadOf[identity] = payload }
        if let rank = item.step.newRank { rankOf[identity] = rank }

        // §5.6 T3：反查到身份、**本机没有行** ⇒ 什么都不删，但游标照样写 `deletedAtMs`。
        // 这一支必须排在 `guidOf` 的 guard **之前**：T3 说的正是「身份反查不到本机行」，
        // 而那恰恰是 `guidOf` 交不出 guid 的情形。漏掉它，那条游标永远停在「活着」的状态，
        // §3.6 那个按 `deletedAtMs` 扫描的 30 天丢弃永远收不走它，而同一轮的差分还会为它
        // 发一条多余的 tombstone（`tombstones` 计数因此一次事件被记两遍）。
        let resolvedGuid = guidOf[identity]
        if item.step.kind == .delete, resolvedGuid.flatMap({ projected[$0] }) == nil {
            outcome.landed.insert(identity)
            outcome.deleted.insert(identity)
            continue
        }
        guard let guid = resolvedGuid else { continue }

        if item.step.kind == .update || item.step.kind == .delete {
            guard let row = projected[guid] else { continue }
            placed.append((item, guid, BookmarkSiblingGroup(spaceId: row.spaceId,
                                                            parentGuid: row.parentGuid)))
            continue
        }

        guard let entity = item.entity else { continue }
        // `newParentUuid == nil` **不是「挂到 Space 根」**，而是「按载荷自己的 `parent_uuid`
        // 落」。它只在模块替你决定了父的时候非 nil：提升到根（值是 `""`）、或父就在同一批里。
        let parentIdentity = item.step.newParentUuid ?? entity.parentUuid.stringValue
        var group: BookmarkSiblingGroup
        if parentIdentity.isEmpty {
            guard let spaceId = resolve.localSpaceId(entity.spaceUuid.stringValue) else {
                outcome.parked.insert(identity)
                continue
            }
            group = BookmarkSiblingGroup(spaceId: spaceId, parentGuid: nil)
        } else {
            guard let parentGuid = guidOf[parentIdentity] ?? state.identityToGuid[parentIdentity],
                  let parentRow = projected[parentGuid] else {
                outcome.parked.insert(identity)
                continue
            }
            group = BookmarkSiblingGroup(spaceId: parentRow.spaceId, parentGuid: parentGuid)
            parentOf[guid] = parentGuid
        }

        if var row = projected[guid] {
            // §4.5：**先按 `syncId` 找本机行，找不到才 create**。R-M3-3-13 的重放路径、D10
            // 的认领路径与普通的更新路径全部依赖这一条——照着计划里的 `.create` 建一遍，会
            // 让本机每一条书签在一次重放之后变成两条，而两条都带身份、都不会被差分判成删除。
            row.syncId = identity
            row.spaceId = group.spaceId
            row.parentGuid = group.parentGuid
            projected[guid] = row
        } else {
            projected[guid] = PhiLocalBookmark(
                syncId: identity, guid: guid, spaceId: group.spaceId,
                profileId: state.locals.first { $0.spaceId == group.spaceId }?.profileId
                    ?? LocalStore.defaultProfileId,
                parentGuid: group.parentGuid, index: 0, isFolder: entity.isFolder,
                title: entity.title.stringValue,
                url: URL(string: entity.url.stringValue)
                    ?? URL(string: "https://bookmark.phi/folder")!,
                secondaryUrl: URL(string: entity.secondaryURL.stringValue),
                secondaryTitle: entity.secondaryTitle.stringValue.isEmpty
                    ? nil : entity.secondaryTitle.stringValue,
                source: Int(entity.source),
                createdDate: Date(timeIntervalSince1970: Double(entity.createdAtMs) / 1000),
                contentUpdatedDate: nil)
        }
        touched.insert(group)
        placed.append((item, guid, group))
    }

    // R-M3-3-17 的三步，第 2 步在空集合上必须是**零操作**（CASE 6.10c）。
    var childrenOf: [String: [String]] = [:]
    for (guid, row) in projected {
        guard let parent = row.parentGuid else { continue }
        childrenOf[parent, default: []].append(guid)
    }
    for guid in deletedGuids where projected[guid]?.isFolder == true {
        var stack = childrenOf[guid] ?? []
        var hops = 0
        while let child = stack.popLast(), hops <= projected.count {
            hops += 1
            stack.append(contentsOf: childrenOf[child] ?? [])
            guard !deletedGuids.contains(child), var row = projected[child] else { continue }
            // 其余每一个后代**先提升到该 Space 的根**；文件夹行本身排在第 3 相删掉。
            row.parentGuid = nil
            projected[child] = row
            parentOf.removeValue(forKey: child)
            touched.insert(BookmarkSiblingGroup(spaceId: row.spaceId, parentGuid: nil))
        }
    }
    for guid in deletedGuids { projected.removeValue(forKey: guid) }

    // §4.10 的 rank → index 投影，**跑在这里而不是 access 里**（R-exec-2）：它要拿整批入站
    // 实体的 rank 一起算，而 access 只看得见本机行。`.move` 发出的是**整组的完整置换**——
    // 批次入口写的是裸 index，它不会替你把兄弟们往后挪，只发被移动的那一条会让它与某个没被
    // 碰的兄弟撞上同一个 index。
    var indexOf: [String: Int] = [:]
    for group in touched {
        var members = access.siblings(ofParent: group.parentGuid, inSpaceId: group.spaceId)
            .compactMap { projected[$0.guid] }
            .filter { $0.spaceId == group.spaceId && $0.parentGuid == group.parentGuid }
        for (guid, row) in projected where row.spaceId == group.spaceId
            && row.parentGuid == group.parentGuid
            && !members.contains(where: { $0.guid == guid }) {
            members.append(row)
        }
        for (guid, index) in BookmarkKind.rankToIndex(siblings: members, ranks: rankOf) {
            indexOf[guid] = index
        }
    }

    var opsBySpace: [String: [BookmarkApplyOp]] = [:]
    var identitiesBySpace: [String: Set<String>] = [:]
    // 已经**带着最终 index 出门**的那些 guid。只有 `.create`（index 写在行里）与 `.move`
    // 算数：`.claim` 只写 `syncId`，`.update` 只写字段，两者都不带 index，所以它们必须留给
    // 下面那趟置换。漏掉这一条，一次纯改名或一次认领会把同一个父下的兄弟们重新编号，而它
    // 自己留着旧 index——两条行撞在同一个 index 上，那个文件夹的顺序此后随 fetch 而变。
    var indexed: Set<String> = []
    // §8.2 / Task 10：本轮真的**新建**出来的那些行，落地后复核通过的会跟着 outcome 交给
    // 图标回填队列。
    var createdRowsByIdentity: [String: PhiLocalBookmark] = [:]
    func emit(_ op: BookmarkApplyOp, in spaceId: String) {
        opsBySpace[spaceId, default: []].append(op)
    }

    for entry in placed {
        let identity = entry.item.step.identity
        identitiesBySpace[entry.group.spaceId, default: []].insert(identity)
        switch entry.item.step.kind {
        case .claim:
            emit(.claim(guid: entry.guid, syncId: identity), in: entry.group.spaceId)
        case .create:
            if state.identityToGuid[identity] != nil || state.pairs[identity] != nil {
                // 本机已经有这条身份的行：一次重放 / 一次认领，不是一次新建。
                emit(.move(guid: entry.guid, toParentGuid: entry.group.parentGuid,
                           inSpaceId: entry.group.spaceId, index: indexOf[entry.guid] ?? 0),
                     in: entry.group.spaceId)
                indexed.insert(entry.guid)
                if let entity = entry.item.entity {
                    emit(.update(guid: entry.guid, fields: bookmarkPatch(entity)),
                         in: entry.group.spaceId)
                }
            } else if var row = projected[entry.guid] {
                row.index = indexOf[entry.guid] ?? 0
                emit(.create(row), in: entry.group.spaceId)
                createdRowsByIdentity[identity] = row
                indexed.insert(entry.guid)
            }
        case .move:
            emit(.move(guid: entry.guid, toParentGuid: entry.group.parentGuid,
                       inSpaceId: entry.group.spaceId, index: indexOf[entry.guid] ?? 0),
                 in: entry.group.spaceId)
            indexed.insert(entry.guid)
        case .update:
            if let entity = entry.item.entity {
                emit(.update(guid: entry.guid, fields: bookmarkPatch(entity)),
                     in: entry.group.spaceId)
            }
        case .delete:
            emit(.delete(guid: entry.guid), in: entry.group.spaceId)
        }
    }
    // 组内的其余兄弟：**组内按目标 index 升序发**，于是顺序在任何一次 fetch 之后都一样。
    // 「其余」= 这一组里所有已经存在于本机、而这一轮还没有拿到最终 index 的行——被认领的
    // 那一条、被改名的那一条，以及完全没被这一轮碰过的那些，都在里面。
    for group in touched {
        let movers = projected.values
            .filter { $0.spaceId == group.spaceId && $0.parentGuid == group.parentGuid
                && !indexed.contains($0.guid) && state.rowByGuid[$0.guid] != nil }
            .sorted { (indexOf[$0.guid] ?? 0, $0.guid) < (indexOf[$1.guid] ?? 0, $1.guid) }
        for row in movers {
            emit(.move(guid: row.guid, toParentGuid: group.parentGuid,
                       inSpaceId: group.spaceId, index: indexOf[row.guid] ?? row.index),
                 in: group.spaceId)
        }
    }

    // **一次 `apply(_:)` 是一个事务，而导入锁是 fail-closed 的**：一批横跨两个 Space、其中
    // 一个正在被导入的落地会把另一个 Space 的行也一起回滚——那些行本来没有任何理由等。
    // 所以调用之前先按 Space 把批次切开，每个被触及的 Space 一次调用。跨 Space 的父子关系
    // 不受影响：一条行的父必定与它同 Space。
    //
    // `didApply` = 这一轮有没有**真的**落下去过一批。Step 3 的重取只在它为真时发生：一轮
    // 至多一次 fetch 的规则对「一行都没落」的轮次一个字不让。
    var didApply = false
    for spaceId in opsBySpace.keys.sorted() {
        let ops = opsBySpace[spaceId] ?? []
        guard !ops.isEmpty else { continue }
        let identities = identitiesBySpace[spaceId] ?? []
        do {
            try await access.apply(BookmarkApplyBatch(unordered: ops, parentOf: parentOf))
            didApply = true
        } catch LocalStoreWriteError.folderNotEmpty, LocalStoreWriteError.rowAlreadyMapped {
            // 这一批**算错了**：拒收。它们不是在等什么，停放会让同一批每轮原样重试、永远
            // 不会好，而 `pendingApply` 里堆着一批永远落不了地的实体。
            outcome.refused.formUnion(identities)
            continue
        } catch {
            // 导入锁（`.spaceImporting`）与其余一切瞬时失败：**停放**，下一轮重试。
            outcome.parked.formUnion(identities)
            continue
        }
        // §4.5：落地之后、写基线之前，按计划复核一次。复核读的是**落地后**的行——`apply`
        // 收尾会自己重建一次缓存，所以这三个读者此刻答的是新世界。没有这次复核，任何残留的
        // 静默拒绝都会被记成一次成功落地。
        for identity in identities {
            guard let guid = guidOf[identity] else { continue }
            let known = access.isKnownLocalBookmark(guid)
            if deletedIdentities.contains(identity) {
                if known { outcome.parked.insert(identity) } else {
                    outcome.landed.insert(identity)
                    outcome.deleted.insert(identity)
                }
                continue
            }
            guard known else { outcome.parked.insert(identity); continue }
            outcome.landed.insert(identity)
            // §8.2 / Task 10：这一条是本轮**新建**出来的 ⇒ 它按构造没有图标，交给回填队列。
            if let created = createdRowsByIdentity[identity] { outcome.createdRows.append(created) }
            if let payload = payloadOf[identity] { outcome.reconciled[identity] = payload }
        }
    }
    outcome.parked.subtract(outcome.landed)
    outcome.refused.subtract(outcome.landed)
    // 本轮真的被删掉的那些行立刻退出轮内投影，于是同一轮的发布段不会把它们复活（CASE 6b.8）。
    state.noteDeletedRows(Set(outcome.deleted.compactMap { guidOf[$0] }))
    // Step 3：落地过至少一批 ⇒ 出站快照之前把轮内那份本机投影换成**落地后**的行。
    //
    // 取的是 access 那份缓存（`apply` 收尾已经重建过它），**不是再 fetch 一次**。不换的
    // 后果有两层：其一，每一次入站内容变化都多一条无谓的 commit——快照拿的是落地**前**那
    // 一行，与刚写好的 `reconciled` 不同，差分判成「本机改了」；其二，那条 commit 带的是
    // **旧值**配上一个**新鲜的 `now`**，它比对端刚才那次真实编辑更晚，于是在一次并发编辑
    // 里旧值盖掉新值——一次读写时序问题就此变成一次数据回滚（CASE 7.6 / 7.7）。
    //
    // `nil` = 本轮没有一份可用的快照（`apply` 落了地但它收尾那次重读抛了）。此时**原样
    // 留着**轮内那份投影：交出一个空数组会让整轮的出站快照变空。
    if didApply, let refreshed = access.cachedBookmarks() {
        state.refreshLandedRows(refreshed)
    }
    return outcome
}

/// 一条实体的四个内容字段 → 一次字段更新。
@MainActor
private func bookmarkPatch(_ entity: Phi_PhiBookmarkEntity) -> BookmarkFieldPatch {
    BookmarkFieldPatch(
        title: .some(entity.title.stringValue),
        url: .some(URL(string: entity.url.stringValue)),
        secondaryUrl: .some(URL(string: entity.secondaryURL.stringValue)),
        secondaryTitle: .some(entity.secondaryTitle.stringValue.isEmpty
                              ? nil : entity.secondaryTitle.stringValue))
}

// MARK: - PinKind 的适配层

/// 一轮 pin 同步的轮内状态。形状照 `BookmarkSyncRoundState`，**少了认领配对那一半**
/// （§6.7：pin 完全不走 §6——身份是 `(lineage, owner)` 推导出来的，本机行上没有一列
/// 要写回，所以既没有铸造也没有配对表）。
///
/// **`@MainActor`，与 `BookmarkSyncRoundState` 同款。** 两个访问协议都是 main actor 的，注册项
/// 里每一个触本机的闭包也都是，所以这份轮内状态只在 main actor 上被读写——包括 §7.4 的表副本
/// 那一路：`clearedSplitPartners` 因此也是 `@MainActor`，由 `doctoredOwnedTable` 每轮跳一次。
///
/// 隔离**不能**为了省那一跳而摘掉。今天它只有 `reload` 一个写者，串行的轮次确实排除了竞争，
/// 但那是一条靠人读代码才成立的不变量：编译器看不见一个只经不透明闭包捕获跨越隔离域的对象，
/// 于是「摘掉 `@MainActor`」把一条编译期保证换成了没有任何东西检查的运行期保证——而 Task 6b
/// 正要往这个类里加轮中写者（A11 的重铸）。
@MainActor
final class PinSyncRoundState {
    /// 轮首那一次 `allPins()`：当前作用域内、非休眠的全部行。
    private(set) var locals: [PhiLocalPin] = []
    private(set) var rowByGuid: [String: PhiLocalPin] = [:]
    /// §7.3 的两个判据，轮首各读一次。**账户值为 nil = 账户还没发过作用域**，此时不判
    /// 不一致（`accountScope()` 的契约）。
    private(set) var localScope: PinnedTabScope = .profile
    private(set) var accountScope: PinnedTabScope?

    /// §7.3：两者都已知且不相等 ⇒ 这一轮 pin 的**发布半边整段不跑**，入站半边全部停放。
    var scopeMismatch: Bool {
        guard let accountScope else { return false }
        return localScope != accountScope
    }

    /// 轮首取样**之后**这两个值动过没有（R-exec-12）。见 `rescanScopes(localScope:accountScope:)`。
    private(set) var scopeMovedMidRound = false

    /// §7.3 的跳过判据，两支合一：轮首就不一致，**或者**轮首一致但作用域在轮中动了。
    /// 发布段的三处守卫与落地段读的都是这一个。
    var scopeBlocked: Bool { scopeMismatch || scopeMovedMidRound }

    func reload(_ rows: [PhiLocalPin], localScope: PinnedTabScope,
                accountScope: PinnedTabScope?) {
        locals = rows
        rowByGuid = [:]
        for row in rows { rowByGuid[row.guid] = row }
        self.localScope = localScope
        self.accountScope = accountScope
        // 新的一轮从「没动过」开始：轮内状态跨轮复用（注册项持有它），不清零的话一次轮中
        // 迁移会把此后**每一轮**的 pin 段都关掉。
        scopeMovedMidRound = false
    }

    /// 轮首之后再取样一次两个作用域值；任一与轮首那一对不同 ⇒ 这一轮按 §7.3 处理。
    ///
    /// **为什么必须有这一趟（R-exec-12 / D-A）。** 轮内状态是 `beginRound` 一次性冻结的：
    /// `locals` 与两个作用域都取自 `pull` **翻第一页之前**那一刻。而作用域变更是**跟着那一页
    /// 到达的**——远端设置落地把镜像键改成新值，Task 8 的跟随迁移（`applyAccountPinnedTabScope`）
    /// 在一个 detached `Task` 里重建全部物理行。于是落地段执行时，库已经是新形状，而
    /// `state.locals` 还是旧形状：入站实体的 `(lineage, ownerKey)` 配不上任何一条**旧形状**
    /// 行算出来的身份，`landPins` 于是走 create 那一支，在迁移刚建好的行旁边**再建一遍**
    /// ——Mac B 2026-09-14 那四条重复。§7.3 原本的守卫挡不住它：两个作用域都是在它们还一致
    /// 的时候取样的。
    ///
    /// **只置标志，不更新那两个值。** `localScope` 是 `PinKind.identity(of local:)` 解读
    /// `state.locals` 的参数，把它换成新值而行还是旧的，等于用另一个作用域的规则去读这一批
    /// 行——那是比过期更糟的一种错。这一轮什么都不做，下一轮的 `beginRound` 会读到一致的
    /// 「新行 + 新作用域」。
    ///
    /// **粘性**：一轮里往返变回去也照样算动过——`locals` 无论如何都已经和库脱节了。
    func rescanScopes(localScope: PinnedTabScope, accountScope: PinnedTabScope?) {
        guard localScope != self.localScope || accountScope != self.accountScope else { return }
        scopeMovedMidRound = true
    }

    /// 一次落地之后把轮内那份本机投影换成**落地后**的行（Step 3）。形状与理由都照
    /// `BookmarkSyncRoundState.refreshLandedRows`：交进来的是 access 那份缓存
    /// （`apply(_:)` 收尾已经重建过它），**不是第二次 fetch**。
    ///
    /// **两个作用域不动**：它们是 §7.3 的判据，轮首各读一次，落地一次也改不了它们。
    func refreshLandedRows(_ rows: [PhiLocalPin]) {
        locals = rows
        rowByGuid = [:]
        for row in rows { rowByGuid[row.guid] = row }
    }

    /// 本轮真的被删掉的那些行立刻从轮内投影里消失。理由与
    /// `BookmarkSyncRoundState.noteDeletedRows` 逐字相同：留着它，同一轮的发布段会按 §4.2
    /// 第 3b 条把一条刚被远端删掉的 pin 复活发回账户。
    func noteDeletedRows(_ guids: Set<String>) {
        guard !guids.isEmpty else { return }
        for guid in guids { rowByGuid.removeValue(forKey: guid) }
        locals.removeAll { guids.contains($0.guid) }
    }

    /// 把本轮**真的写下去**的那些拆分链接折回轮内投影。
    ///
    /// 与 `BookmarkSyncRoundState.notePersistedClaims` 同一条纪律：一轮至多一次 fetch，这里
    /// 改的是内存里那份投影而不是再读一次库。不折回去，同一轮的发布段读到的还是「这一行没有
    /// 伙伴」，而 §7.4 的表副本恰好把「基线里有伙伴 ∧ 本机行没有链接」判成**一次本机解除**
    /// ——于是这台机器刚刚接收下来的那条链接会在同一轮里被当成解除重新发回账户，把对端好好
    /// 的拆分对拆散，而这台机器只是接收了它。
    func noteSplitPartnerWrites(linked: [String: String], cleared: Set<String>) {
        guard !linked.isEmpty || !cleared.isEmpty else { return }
        for index in locals.indices {
            let guid = locals[index].guid
            if let partner = linked[guid] {
                locals[index].splitPartnerLineageId = partner
            } else if cleared.contains(guid) {
                locals[index].splitPartnerLineageId = nil
            } else {
                continue
            }
            rowByGuid[guid] = locals[index]
        }
    }

    /// 这条账户身份的本机行**还挂着**拆分链接没有（§7.4 的表副本判据）。
    ///
    /// 判据精确到**身份**而不是 lineage：一条 lineage 在 N 个 owner 下是 N 条行，其中一条
    /// 被解除、另一条还链着是完全合法的状态，按 lineage 判会让那次解除永远发不出去。
    ///
    /// 只扫还挂着链接的那些行——拆分 pin 在任何一个账户上都是少数。
    func stillCarriesSplitLink(_ identity: String, maps: OwnedOwnerMaps) -> Bool {
        let resolve = maps.resolver
        for row in locals where row.splitPartnerLineageId != nil {
            if PinKind.identity(of: row, resolve: resolve, scope: localScope) == identity {
                return true
            }
        }
        return false
    }
}

/// pin 身份 `<lineage>:<ownerKey>` 的两半。
///
/// **第一个冒号就是分界**：`PinKind.isNormalizedLineage` 明确拒掉带 `:` 的 lineage，正是
/// 为了让这个拼接可逆——否则 `("a:b", "c")` 与 `("a", "b:c")` 算出同一个身份。
func pinIdentityHalves(_ identity: String) -> (lineage: String, ownerKey: String) {
    guard let separator = identity.firstIndex(of: ":") else { return (identity, "") }
    return (String(identity[..<separator]),
            String(identity[identity.index(after: separator)...]))
}

/// 身份 -> client tag（§2.5）。
///
/// **经 `pinClientTag(lineageKey(…), ownerKey:)` 构造**：那个函数自己不做任何大小写归一，
/// 归一的责任全在调用方（§3.2）。少了这一步，算出的 hash 与线上那条永不相等，接收端校验
/// 会把每一条 pin 实体都判成伪造载荷。
func pinClientTag(for identity: String) -> String {
    let halves = pinIdentityHalves(identity)
    return PhiSyncEntity.pinClientTag(PinKind.lineageKey(halves.lineage),
                                      ownerKey: halves.ownerKey)
}

/// §7.4 的表副本，pin 这一批。**一轮一跳**：引擎把这条 kind 的全部候选（通用规则已经筛过）
/// 一次交进来，返回的只有真的被改写的那几条，不在返回值里的身份原样沿用基线。
@MainActor
func clearedPinSplitPartners(_ baselines: [String: Data], now: Int64, maps: OwnedOwnerMaps,
                             state: PinSyncRoundState) -> [String: Data] {
    var out: [String: Data] = [:]
    for (identity, bytes) in baselines {
        guard let cleared = clearedPinSplitPartner(bytes, now: now, maps: maps, state: state)
        else { continue }
        out[identity] = cleared
    }
    return out
}

/// §7.4：把一份基线字节里的拆分伙伴清空，交给 `doctoredOwnedTable` 当表副本用。
///
/// **取值清空、时间戳盖本轮的 `now`**。`PinKind.stamp` 的重盖判据是字段的**签名**（取值，
/// 不含时间戳），而清空之后投影值与基线值都是空串、签名相等——于是它沿用基线的戳。那条
/// `("", t_基线)` 与对端手上的 `("<伙伴>", t_基线)` 戳相同，`SyncableSettings.lwwWinner`
/// 按序列化字节破平手，而 proto3 省略空字符串字段，空串是对方的前缀、排在前面、**输掉**
/// 平手——对端于是永远保留那条链接，用户每解除一次、每同步一次又被拼回去。盖上 `now` 之后
/// 这条解除以「现在」出门，正常赢下对端那一版。
///
/// 盖戳只能在这里做：`stamp` 分不出「表副本刚抹掉一个真实的伙伴」与「这条 pin 从来没有
/// 伙伴」——两者到它手上都是空投影对空基线。
///
/// nil = 这份字节不是一条 pin、它本来就没有伙伴、或者**本机那一行还挂着这条链接**——三种
/// 情形下调用方都原样沿用基线，于是只有真正的解除会被改写。
///
/// 最后那一条是必需的，而且它才是常见的那一类：一对**两半都链好**的拆分 pin，它的游标同样
/// 没有 `pendingPartnerLineage`（伙伴早就落地了）。清掉它的基线之后，投影（带着伙伴）与基线
/// （空）签名不同 ⇒ `restamped` 每轮盖一次 `now` ⇒ 与真表比每轮都「有变化」⇒ 每轮重发。
/// 对端收到的值与它手上那条相等，`plan` 因此产不出任何 step，它的 `reconciled` 也就永不刷新,
/// 于是它下一轮同样重发——**两台设备把每一条拆分 pin 每一轮都发一遍**，还吃掉每轮 250 条的
/// 发布预算，真正的改动被挤出去。
@MainActor
func clearedPinSplitPartner(_ bytes: Data, now: Int64, maps: OwnedOwnerMaps,
                            state: PinSyncRoundState) -> Data? {
    guard let envelope = try? Phi_PhiEntity(serializedBytes: bytes),
          var entity = PinKind.entity(from: envelope),
          !entity.splitPartnerUuid.stringValue.isEmpty else { return nil }
    // 本机那一行还挂着链接 ⇒ 这不是一次解除，一个字节都不动。
    guard !state.stillCarriesSplitLink(PinKind.identity(of: entity), maps: maps) else {
        return nil
    }
    var cleared = Phi_PhiSettingValue()
    cleared.stringValue = ""
    cleared.updatedAtMs = now
    entity.splitPartnerUuid = cleared
    return try? PinKind.envelope(entity).serializedData()
}

extension OwnedKindRegistration {
    /// `PinKind` 那一条注册项。
    @MainActor
    static func pins(access: any PhiPinnedTabLocalAccess,
                     store: any PhiOwnedItemStateStore) -> OwnedKindRegistration {
        let state = PinSyncRoundState()
        return OwnedKindRegistration(
            label: "pins",
            tagPrefix: PhiSyncEntity.pinTagPrefix,
            entityName: PhiSyncEntity.pinEntityName,
            store: store,
            flags: .pins,
            // §11.2：认领那三项**只有书签行有**——pin 完全不走 §6（§6.7）。
            reportsAdoption: false,
            // 反过来 `relineaged` 与 `scope_mismatch` 只有 pin 行有。
            reportsScope: true,
            identity: { envelope in
                guard let entity = PinKind.entity(from: envelope) else { return nil }
                let identity = PinKind.identity(of: entity)
                return identity.isEmpty ? nil : identity
            },
            clientTag: pinClientTag(for:),
            owners: { bytes in
                guard let envelope = try? Phi_PhiEntity(serializedBytes: bytes),
                      let entity = PinKind.entity(from: envelope) else { return [] }
                return PinKind.ownerUuids(of: entity)
            },
            clearedSplitPartners: { baselines, now, maps in
                clearedPinSplitPartners(baselines, now: now, maps: maps, state: state)
            },
            beginRound: {
                state.reload(try access.allPins(),
                             localScope: access.currentScope(),
                             accountScope: access.accountScope())
            },
            // §5.1 的索引种子，pin 这一侧**只有游标键**。
            //
            // 本机那一半交不出来：身份的后半段是**账户级** ownerKey，要由本轮的解析器从
            // `spaceId` / `profileId` 翻出来，而这个闭包按接缝的形状拿不到那份映射表；
            // 这个闭包也拿不到 `allPinRows()` 那份行（它不抛、也不在轮内状态里），直接拿
            // 裸 lineage 拼 tag 会往索引里塞一批线上永不存在的 hash。交空集合是保守的那一
            // 侧：索引少一条种子只会让一条
            // **游标已经丢失**的身份的远端 tombstone 被当成「不认识的 hash」忽略掉，而那条
            // 路径本来就要靠 R-M3-3-13 的整类型重放兜底。
            localIdentities: { [] },
            snapshot: { table, maps, now in
                pinSnapshot(table: table, maps: maps, now: now, access: access, state: state)
            },
            tombstones: { table, maps, now in
                try pinTombstones(table: table, maps: maps, now: now,
                                  access: access, state: state)
            },
            // §6.7：pin 不走认领，所以这一趟没有任何身份可以配、也没有任何东西要写回本机
            // 行。它仍然存在并照书签那一条接线，于是引擎那个 helper 不需要为 kind 开分支
            // （R-exec-10）。
            retryParkedClaims: { _, _ in OwnedParkedClaimResult() },
            plan: { input in pinPlan(input, access: access, state: state) },
            land: { input in await landPins(input, access: access, state: state) },
            // 同上：没有铸造就没有写回，`snapshot` 交出的 `minted` 恒空。
            claimIdentities: { _ in [] },
            // §9.3 的级联。判据 (b) 的粒度是**完整身份**（`<lineage>:<ownerKey>`），不是裸
            // lineage——域的构造与 `pinTombstones` 逐字同源，同样两个来源：
            //
            // 1. 当前作用域内的行交出**完整身份**（`PinKind.identity(of local:)`）；
            // 2. `allPins()` 一条都看不见、但 `allPinRows()` 还交得出来的那些行，各自按
            //    **自己那条身份**只认领、不改写归属——作用域迁移原地留下的备份行属于这一
            //    类，本机确实还有物理行，只是这一轮的快照不认领它们（R-exec-4 / R-exec-11）。
            //    唯一的例外是**归属反查不出来**的那些行：这一轮算不出它们坐在哪，也就证不了
            //    它们不是某条游标的那一行，于是退回按 lineage 保护（A12 的 fail-safe）。
            //
            // **按裸 lineage 判是错的**（T9a-2）：一条 lineage 在 N 个 owner 下是 N 条身份，
            // 于是一条 owner 已被清理的游标会被**另一个 owner 下**的行保护住——它既不会被删
            // （看起来有活行认领），也不会被改写（它的身份配不上任何本机行），于是永远带着
            // 一个指向已清理 Space 的 `ownerUuid` 留在表里。换 owner 按 §7.2 是「旧身份
            // tombstone + 新身份 create」，旧身份那一条本来就不该由新 owner 下的行来认领。
            liveOwners: { candidates, maps in
                let resolve = maps.resolver
                let scope = state.localScope
                let fullStoreRows = try access.allPinRows()
                // 读的是 `eligibilityOwner`，**不是**身份的后半段：`identity(of local:)` 在
                // 归属解析不出来时交的是一个占位后半段，截它等于把占位值写进游标。
                var ownerByIdentity: [String: String] = [:]
                for row in state.locals {
                    guard let identity = PinKind.identity(of: row, resolve: resolve, scope: scope),
                          let owner = PinKind.eligibilityOwner(of: row, resolve: resolve,
                                                               scope: scope)
                    else { continue }
                    ownerByIdentity[identity] = owner
                }
                // 来源 2 的定义域，同 `pinTombstones` 逐字同源：轮内投影没覆盖到的那些
                // 全库行，**各自贡献自己那条身份**（R-exec-11）。
                let claimedGuids = Set(state.locals.map(\.guid))
                var outOfScopeIdentities: Set<String> = []
                // **归属反查不出来的那些行退回按 lineage 保护**（A12 的 fail-safe）。判据不是
                // `identity(of local:)` 返回 nil——它在归属解析不出来时交的是一个 NUL 打头的
                // 占位后半段，那个身份与任何一条游标都不相等，于是「配不上」会被静默地读成
                // 「不认领」。问的是 `eligibilityOwner`，它为 nil 才是「这一轮算不出这条行
                // 坐在哪」。
                //
                // 为什么这一支必须保守：判据 (b) 保护的是「本机还有活行」的游标，而一条
                // 归属未映射的行恰恰是**证不了它不是那条游标的那一行**的状态——一次 Space
                // 映射抖动就会让它名下的游标被这一趟扫掉，而那条行还在用户的机器上。删错
                // 的代价是那条行下一轮被判成从未发布过，以 `baseVersion == 0` 的 create 盲写
                // 覆盖账户上那一条；留错的代价只是一条游标多活一个保留期。
                //
                // **只在来源 2 里退回**：作用域内的行由来源 1 按身份各自表态，它们归属算不
                // 出来时本来就一个身份都不贡献（这一点与 R-exec-11 之前逐字相同）。
                var unresolvedOwnerLineages: Set<String> = []
                for row in fullStoreRows where !claimedGuids.contains(row.guid) {
                    guard let identity = PinKind.identity(of: row, resolve: resolve, scope: scope)
                    else { continue }
                    guard PinKind.eligibilityOwner(of: row, resolve: resolve, scope: scope) != nil
                    else {
                        unresolvedOwnerLineages.insert(PinKind.lineageKey(row.lineageId))
                        continue
                    }
                    outOfScopeIdentities.insert(identity)
                }
                var out = OwnedLiveRows()
                for identity in candidates {
                    if let owner = ownerByIdentity[identity] {
                        out.claimed.insert(identity)
                        out.owners[identity] = owner
                        continue
                    }
                    // 来源 2。**按完整身份匹配**：当前作用域下还有行的那些身份已经由来源 1
                    // 各自表过态，而作用域之外的备份行只认领**它自己**那一条。按裸 lineage
                    // 兜一次就把上面那条论证撤销了。归属这里不改写 ⇒ 保留上一次已知的归属
                    // （来源 1 才是唯一的 `ownerUuid` 写入方）。
                    guard outOfScopeIdentities.contains(identity)
                            || unresolvedOwnerLineages.contains(
                                pinIdentityHalves(identity).lineage)
                    else { continue }
                    out.claimed.insert(identity)
                }
                return out
            })
    }
}

/// §4.2 的出站快照。**没有铸造那一步**：pin 的身份由 `(lineage, owner)` 推导，不需要在
/// 内存里先铸一个再等提交写回（§6.4 对 pin 退化成空操作）。
@MainActor
private func pinSnapshot(table: PhiOwnedItemTable, maps: OwnedOwnerMaps, now: Int64,
                         access: any PhiPinnedTabLocalAccess,
                         state: PinSyncRoundState) -> OwnedSnapshotBytes {
    var out = OwnedSnapshotBytes()
    // R-exec-12：发布之前再取样一次两个作用域值。纯 push 轮不跑 `plan` 也不跑落地，所以
    // 这一处是那种轮次里唯一一次复查。
    state.rescanScopes(localScope: access.currentScope(), accountScope: access.accountScope())
    // §7.3：作用域不一致 ⇒ 发布半边**整段**跳过——不铸造、不快照、不发任何 commit。
    // 一份空快照就是「这一轮没有任何 pin 要发布」；入站那一半由 `plan` 全部停放。
    //
    // 跳过的同时把 §11.2 的 `scope_mismatch` 带回去：这个跳过在**每一种轮次**里都发生，
    // 而 `plan` 只在有入站的轮次里跑，光靠它那一路，一次纯 push 轮会悄无声息地不发布。
    guard !state.scopeBlocked else {
        out.scopeMismatch = true
        return out
    }
    let resolve = maps.resolver
    let scope = state.localScope
    let result = SyncableOwnedItems.snapshot(PinKind.self, locals: state.locals, table: table,
                                             resolve: resolve, scope: scope, now: now)
    out.skippedUnmappedOwner = result.skippedUnmappedOwner
    out.skippedIneligibleOwner = result.skippedIneligibleOwner
    for (identity, entity) in result.entities {
        guard let bytes = try? PinKind.envelope(entity).serializedData() else { continue }
        out.entities[identity] = bytes
    }
    // A12 / §3.5：身份 -> 这一行**当前所在的归属**，引擎每轮刷进游标的 `ownerUuid`。
    // 读的是 `eligibilityOwner`，**不是**身份的后半段（`identity(of local:)` 在归属解析
    // 不出来时交的是一个占位后半段，截它等于把占位值写进游标）。
    for row in state.locals {
        guard let identity = PinKind.identity(of: row, resolve: resolve, scope: scope),
              let owner = PinKind.eligibilityOwner(of: row, resolve: resolve, scope: scope)
        else { continue }
        out.ownerUuids[identity] = owner
    }
    return out
}

/// §4.7 的差分。
@MainActor
private func pinTombstones(table: PhiOwnedItemTable, maps: OwnedOwnerMaps, now: Int64,
                           access: any PhiPinnedTabLocalAccess,
                           state: PinSyncRoundState) throws -> OwnedItemTombstoneResult {
    // R-exec-12：同 `pinSnapshot`。**必须排在 `allPinRows()` 之前**——轮中迁移会让 access
    // 那份快照失效（`changeScope` 只清不重读），此刻去读它只会抛，而这一轮本来就什么都
    // 不该做。
    state.rescanScopes(localScope: access.currentScope(), accountScope: access.accountScope())
    // §7.3：作用域不一致的那一轮发布半边整段不跑，差分是它的一半。
    guard !state.scopeBlocked else {
        return OwnedItemTombstoneResult(identities: [], cursorUpdates: [:])
    }
    let resolve = maps.resolver
    let scope = state.localScope
    // R-exec-4：定义域问 `allPinRows()`（**全库**那一次读），**不问快照**。本轮没成功读过时
    // 它抛，于是这一条 kind 的发布段整段不跑——空集合的回答是给账户上每一条已发布身份发
    // tombstone。
    let fullStoreRows = try access.allPinRows()
    // 定义域 = 轮内那份本机投影（当前作用域内的行，已按本轮落地刷新过）+ 全库里**它没有
    // 覆盖到**的那些行，也就是作用域迁移原地留下的备份行。两段按 `guid` 去重，轮内那一份
    // 优先——它才是落地之后的样子。
    //
    // **每一条行各自贡献自己那条 `(lineage, owner)` 身份**（R-exec-11），身份由
    // `SyncableOwnedItems.tombstones` 按 `PinKind.identity(of local:)` 算，与出站快照逐字
    // 同一条推导。于是一条 profile 形状的备份行保护的是 `(L, profileUuid)` 这一条，**挡不
    // 住** `(L, spaceX)` 被判成删除——换 owner 按 §7.2 就是「旧身份 tombstone + 新身份
    // create」。旧口径在这里补的是一批**只按裸 lineage 匹配**的壳，一条 lineage 只要还剩
    // 任何一行就把它名下全部 owner 的游标一起保护住；Mac B 2026-09-14 被吞掉的那次
    // default-space 取消固定就是这么永远发不出去的。
    var domain = state.locals
    let claimedGuids = Set(state.locals.map(\.guid))
    for row in fullStoreRows where !claimedGuids.contains(row.guid) {
        domain.append(row)
    }
    // R-exec-9 的豁免集合对 pin 恒空：没有认领就没有「配上了但还没写回」这个中间态。
    return SyncableOwnedItems.tombstones(PinKind.self, locals: domain, table: table,
                                         resolve: resolve, scope: scope, nowMs: now,
                                         pendingClaims: [])
}

/// §4.4 的入站计划。**没有 §6 的认领**（§6.7：首次同步时两边的 pin 取并集）。
@MainActor
private func pinPlan(_ input: OwnedPlanInput, access: any PhiPinnedTabLocalAccess,
                     state: PinSyncRoundState) -> OwnedPlanOutput {
    var out = OwnedPlanOutput()
    // R-exec-12：入站的处置在这里定，所以复查要排在建 `context` 之前。作用域动过 ⇒ 这一轮
    // 的入站实体**全部停放**，等下一轮那份「新行 + 新作用域」的一致投影来落。
    state.rescanScopes(localScope: access.currentScope(), accountScope: access.accountScope())
    var arrivals: [OwnedItemArrival<Phi_PhiPinTabEntity>] = []
    for item in input.arrivals {
        guard let envelope = try? Phi_PhiEntity(serializedBytes: item.payload),
              let entity = PinKind.entity(from: envelope) else { continue }
        arrivals.append(OwnedItemArrival(entity: entity, entityId: item.entityId,
                                         version: item.version))
        out.serverBytes[PinKind.identity(of: entity)] = item.payload
    }
    var context = OwnedItemPlanContext()
    context.tombstonedIdentities = input.tombstoned
    context.localProjections = pinLocalProjections(
        for: Set(arrivals.map { PinKind.identity(of: $0.entity) }).union(input.parked.keys),
        table: input.table, resolve: input.maps.resolver, now: input.now, state: state)
    // §7.3 的判据交给纯函数模块：不一致 ⇒ 零 step、入站实体全部停放。**`liveLocalParents`
    // 与 `deletedSubtree` 留空**：pin 是平的，没有父，A9 的那两个合取项对它退化。
    context.localScope = state.localScope
    context.accountScope = state.accountScope
    context.scopeMovedMidRound = state.scopeMovedMidRound
    out.plan = SyncableOwnedItems.plan(PinKind.self, arrivals: arrivals, parked: input.parked,
                                       table: input.table, resolve: input.maps.resolver,
                                       context: context)
    // §11.2 的 `scope_mismatch`：这一轮 pin 段的发布半边有没有因为作用域不一致被跳过。
    out.scopeMismatch = context.scopeMismatch
    // §6.2 的那条规则对 pin 同样成立（pin 不走 §6 的**认领**，但「本机赢了字段就要发布
    // 出去」讲的是合并，不是认领）。
    out.mustRepublish = out.plan.mustRepublish
    return out
}

/// `bookmarkLocalProjections` 的 pin 半边，三点差别都来自「pin 是平的」：没有父身份要解，
/// 身份是**算出来**的（所以同一条身份可能有多条行——与 `landPins` 逐字同一条「留第一条」
/// 判据），rank 同样取基线那一个。
@MainActor
private func pinLocalProjections(for identities: Set<String>,
                                 table: PhiOwnedItemTable,
                                 resolve: OwnerResolver,
                                 now: Int64,
                                 state: PinSyncRoundState) -> [String: Data] {
    guard !identities.isEmpty else { return [:] }
    var rowOf: [String: PhiLocalPin] = [:]
    for row in state.locals {
        guard let identity = PinKind.identity(of: row, resolve: resolve, scope: state.localScope),
              identities.contains(identity), rowOf[identity] == nil else { continue }
        rowOf[identity] = row
    }
    var out: [String: Data] = [:]
    for (identity, row) in rowOf {
        guard let baselineBytes = table.cursors[identity]?.reconciled,
              let baselineEnvelope = try? Phi_PhiEntity(serializedBytes: baselineBytes),
              let baseline = PinKind.entity(from: baselineEnvelope),
              let projected = PinKind.project(row, resolve: resolve, scope: state.localScope,
                                              parentIdentity: nil) else { continue }
        let stamped = PinKind.stamp(projected, baseline: baseline, local: row,
                                    rank: PinKind.rank(of: baseline), now: now)
        guard let bytes = try? PinKind.envelope(stamped).serializedData() else { continue }
        out[identity] = bytes
    }
    return out
}

/// §4.4 / §4.5 的落地：变体重铸 + 三相批次 + 落地后复核，**一个事务**。
///
/// 与书签那边的两点差别都来自「pin 是平的、按 owner 分组」：没有父子关系要排，所以没有
/// 提升；批次不按 Space 切开，因为一条 pin 操作的归属由 store 自己从行上读（`.create`
/// 之外的四种 op 只带 guid）。
@MainActor
private func landPins(_ input: OwnedLandingInput,
                      access: any PhiPinnedTabLocalAccess,
                      state: PinSyncRoundState) async -> OwnedLandingOutcome {
    var outcome = OwnedLandingOutcome()
    let resolve = input.maps.resolver
    let scope = state.localScope

    // R-exec-12：落地之前再取样一次两个作用域值，动过就整段不跑，入站原样停放。
    //
    // **这一趟是这个 fix 的要害。** 轮内那份本机投影是迁移**之前**的形状，按它算出来的身份
    // 配不上任何一条迁移后的行——照着落下去，`landPins` 会在刚迁好的行旁边把每一条 pin 再建
    // 一遍（Mac B 2026-09-14）。A11 的重铸同样不能跑：它按 guid 定位，而迁移已经把那批物理行
    // 换掉了。停放不丢东西——marker 已经推过那一页，但载荷记在游标的 `pendingApply` 上，下一轮
    // 的 `beginRound` 会带着一致的「新行 + 新作用域」把它们当成 `.update` 落下去。
    state.rescanScopes(localScope: access.currentScope(), accountScope: access.accountScope())
    guard !state.scopeBlocked else {
        for step in input.steps { outcome.parked.insert(step.identity) }
        return outcome
    }

    // §7.2 / A11 的变体重铸：同 owner 下多条同 lineage 的活动行，先折叠掉签名相同的精确
    // 重复，再给剩下的每一条（`index` 最小的那一条除外）重铸 `pinLineageId`。它是一次
    // **本地写**，所以它在这一轮的 `PinApplyBatch` 里、与落地同一个事务（W14），**不在**
    // 发布段那个只读的 pre-pass 里。
    var ops = PinKind.normalizeVariants(locals: state.locals).ops
    // **条数在批次提交之后才记**（见下面那次 `apply` 的后面）：批次是一个事务，被拒或被
    // 停放时一行都没改，此刻就计数会让计数行报出一批没有发生过的重铸。
    //
    // 数的是 `.relineage` 那一种，**不是 `ops.count`**：A11 现在同时产出折叠用的 `.delete`，
    // 把它们算进 `relineaged` 会让 §11.2 的计数行报出一批没有发生过的重铸。
    var relineaged = 0
    var collapsedDuplicates = 0
    for op in ops {
        switch op {
        case .relineage: relineaged += 1
        case .delete: collapsedDuplicates += 1
        default: break
        }
    }
    guard !input.steps.isEmpty || !ops.isEmpty else { return outcome }

    // 身份 -> 本机行。pin 没有 `syncId` 那一列，身份是**算出来**的，所以两条行算出同一条
    // 身份是可能的（`SyncableOwnedItems.snapshot` 的去重与 A11 的折叠讲的是同一件事）。
    //
    // 留**第一条**，与那两处逐字同一个判据：`allPins()` 按 `(ownerKey, index, guid)` 有序，
    // 于是这里认的行 = 快照发布的那一行 = A11 折叠时留下的那一行。写成后者覆盖前者的话，
    // 同一轮里一条入站 `.update` 会打在 A11 正要删掉的那个副本上（补丁是第二相、删除是第三
    // 相），于是那次远端编辑连同被删的行一起消失，而幸存的那一行还是旧值。
    var rowOf: [String: PhiLocalPin] = [:]
    for row in state.locals {
        guard let identity = PinKind.identity(of: row, resolve: resolve, scope: scope) else {
            continue
        }
        if rowOf[identity] == nil { rowOf[identity] = row }
    }

    /// 账户级 ownerKey -> 本机那一侧的两个字段（§7.2 的表反过来读）。
    func localOwner(_ ownerKey: String) -> (spaceId: String?, profileId: String?)? {
        // **归属的形状必须与本机当前作用域相符，不符就是「反推不出本机形状」。**
        //
        // 三种形状与三种作用域一一对应（§7.2 的表）：App 归属只在 App 作用域下有本机形状，
        // Space 归属只在 Space 作用域下有，Profile 归属只在 Profile 作用域下有。不带这三条
        // 守卫的话，一条**账户上还没跟着改过来的旧形状实体**照样交得出一对字段，而
        // `applyPinSyncBatchBody` 会把缺掉的那一半按 `?? defaultSpaceId` 补齐、
        // `applyCurrentPinnedTabOwner` 再按**当前**作用域盖一次归属——于是一条 Profile 归属
        // 的实体在 Space 作用域下落成了**默认 Space 里**的一行，正正压在那个 Space 本来就
        // 有的同 lineage 行旁边（Mac B 2026-09-14 23:49）。引擎那一侧的投影还以为它落在
        // profile 归属上，两边从此对不上：落地后复核按 profile 归属问「本机有这条身份吗」，
        // 答案永远是「没有」，这条身份于是每一轮都重新落地一次、每一轮都再多一行。
        //
        // **停放而不是拒收**：账户作用域收敛之后对端会用新形状重发，那时它自己就好了。
        if ownerKey == OwnedOwnerMaps.appOwnerKey {
            guard scope == .app else { return nil }
            return (nil, nil)
        }
        if let spaceId = resolve.localSpaceId(ownerKey) {
            guard scope == .space else { return nil }
            // 一条 Space 作用域的行两个字段都非 nil；profile 取同 Space 的既有行，没有就
            // 落到默认 profile（与书签落地同一条兜底）。
            let profileId = state.locals.first { $0.spaceId == spaceId }?.profileId
                ?? LocalStore.defaultProfileId
            return (spaceId, profileId)
        }
        if let profileId = resolve.localProfileId(ownerKey) {
            guard scope == .profile else { return nil }
            return (nil, profileId)
        }
        return nil
    }

    struct Planned {
        var step: OwnedItemApplyStep
        var entity: Phi_PhiPinTabEntity?
        var identity: String
        var ownerKey: String
    }
    var planned: [Planned] = []
    for step in input.steps {
        // §6.7：pin 不走认领，`plan` 因此产不出 `.claim`。真出现了就跳过，不去猜它的意思。
        guard step.kind != .claim else { continue }
        let entity = step.payload.flatMap { bytes -> Phi_PhiPinTabEntity? in
            guard let envelope = try? Phi_PhiEntity(serializedBytes: bytes) else { return nil }
            return PinKind.entity(from: envelope)
        }
        planned.append(Planned(step: step, entity: entity, identity: step.identity,
                               ownerKey: pinIdentityHalves(step.identity).ownerKey))
    }

    // 本轮的落地投影：轮首那份快照 + 这一轮新建的行。它同时回答两个问题——「这条身份有没有
    // 本机行」与「这个 owner 下现在有哪些行」（rank → index 与拆分伙伴解析都要）。
    var projected: [String: PhiLocalPin] = state.rowByGuid
    var guidOf: [String: String] = [:]
    for (identity, row) in rowOf { guidOf[identity] = row.guid }
    var rankOf: [String: String] = [:]
    for (identity, cursor) in input.table.cursors {
        guard let bytes = cursor.reconciled,
              let envelope = try? Phi_PhiEntity(serializedBytes: bytes),
              let entity = PinKind.entity(from: envelope) else { continue }
        rankOf[identity] = PinKind.rank(of: entity)
    }

    var created: Set<String> = []
    var deletedIdentities: Set<String> = []
    var payloadOf: [String: Data] = [:]
    var touchedOwners: Set<String> = []
    var ownerOfGuid: [String: String] = [:]
    for (identity, row) in rowOf {
        ownerOfGuid[row.guid] = PinKind.eligibilityOwner(of: row, resolve: resolve, scope: scope)
            ?? pinIdentityHalves(identity).ownerKey
    }

    for item in planned {
        let identity = item.identity
        if let payload = item.step.payload { payloadOf[identity] = payload }
        if let rank = item.step.newRank { rankOf[identity] = rank }
        // **纯内容更新不碰这个 owner 的次序。** rank 变了的时候 `plan` 会另发一条 `.move`
        // （`moved` 的判据里就有 rank），所以只带 `.update` 的那条身份按定义没有位置变化；
        // 把它的 owner 算进「被触及」，一次改名或一次拆分链接的落地会顺手为整组兄弟发一份
        // 完整的稠密置换，同一批里于是混进一堆与这次落地无关的 `.move`。书签那一侧对同一类
        // 步骤同样不重排（`landBookmarks` 只在 create 与提升时 `touched`）。
        if item.step.kind != .update { touchedOwners.insert(item.ownerKey) }

        if item.step.kind == .delete {
            deletedIdentities.insert(identity)
            guard let guid = guidOf[identity] else { continue }
            projected.removeValue(forKey: guid)
            continue
        }
        guard let entity = item.entity else { continue }
        if guidOf[identity] == nil {
            // 归属反推不出本机形状 ⇒ 停放，等那个 Space / profile 的映射到位。
            guard let owner = localOwner(item.ownerKey) else {
                outcome.parked.insert(identity)
                continue
            }
            // §7：身份是 `(lineage, owner)` 这一对，**一条身份一行**——而落地真正写进去的
            // 是本机那一侧的 owner。这里再按**本机 owner** 问一次「这条 lineage 已经有行了
            // 吗」，问的与上面 `guidOf` 那一问**不是同一件事**：`guidOf` 走的是
            // `PinKind.identity(of local:)`，它把本机行的归属**正向**解析成账户 uuid，解析
            // 不出来（Space 映射还没到）或解析出**另一种形状**（账户上那条实体还是 Profile
            // 归属，而本机已经迁到 Space 作用域）时，它给出的身份与入站那一条永不相等，于是
            // 这一支会在一条**本来就在的行旁边**再建一遍。Mac B 2026-09-14 23:49 的第二、
            // 第三条重复行就是这么来的：迁移刚在 default Space 建好的 `c0020f0d` 行还在，
            // 一条 Profile 归属的旧实体照样落了下来，`spaceId` 走 `.create` 的默认值回落到
            // 默认 Space，正正压在它旁边。
            //
            // **停放而不是拒收**：这一类里有可以自己好起来的一种（Space 映射晚到一轮），
            // 停放让它下一轮以 `.update` 落在那条既有行上；拒收会把它永久丢掉。
            let landingLineage = PinKind.lineageKey(pinIdentityHalves(identity).lineage)
            let landingOwnerKey = owner.spaceId ?? owner.profileId ?? OwnedOwnerMaps.appOwnerKey
            let ownerAlreadyHasLineage = projected.values.contains { row in
                PinKind.lineageKey(row.lineageId) == landingLineage
                    && (row.spaceId ?? row.profileId ?? OwnedOwnerMaps.appOwnerKey)
                        == landingOwnerKey
            }
            guard !ownerAlreadyHasLineage else {
                outcome.parked.insert(identity)
                continue
            }
            let guid = UUID().uuidString
            guidOf[identity] = guid
            created.insert(identity)
            ownerOfGuid[guid] = item.ownerKey
            projected[guid] = PhiLocalPin(
                lineageId: pinIdentityHalves(identity).lineage,
                guid: guid, spaceId: owner.spaceId, profileId: owner.profileId,
                index: 0, title: entity.title.stringValue,
                url: URL(string: entity.url.stringValue)
                    ?? URL(string: "https://pin.phi/placeholder")!,
                splitPartnerLineageId: nil, source: Int(entity.source),
                createdDate: Date(timeIntervalSince1970: Double(entity.createdAtMs) / 1000),
                // R-exec-5：内容戳照实体的内容戳落，**不是 nil、也不是落地时刻**。留 nil
                // 的话下一轮的本机比较戳回落到 `createdDate` = 落地那一刻，这条刚从对端拿
                // 来的 pin 会在下一次字段冲突里凭一个假的「我更新」赢掉对端的真实编辑。
                //
                // **两个内容字段取较大的那个戳**：`PinKind.stamp` 的无基线支拿这一个值同时
                // 盖 `title` 与 `url`（§4.2 第 5 条），只取标题的话，一次「先改标题、后改
                // 网址」的对端编辑在这台机器上会以标题那个更早的时刻重新发布。
                contentUpdatedDate: Date(timeIntervalSince1970:
                                            Double(max(entity.title.updatedAtMs,
                                                       entity.url.updatedAtMs)) / 1000),
                isDormant: false)
        }
    }

    // §4.10 的 rank → index 投影，**按 owner 分组**（pin 没有父）。每个被触及的 owner 发
    // 一份**完整的稠密置换**：批次入口写的是裸 index，它不会替你把兄弟们往后挪（M7）。
    // 本机 guid -> 它这一轮的 rank：步骤里的新 rank 优先，否则基线那一条。
    var rankByGuid: [String: String] = [:]
    for (identity, guid) in guidOf {
        guard let rank = rankOf[identity] else { continue }
        rankByGuid[guid] = rank
    }
    var indexOf: [String: Int] = [:]
    for owner in touchedOwners {
        let members = projected.values
            .filter { ownerOfGuid[$0.guid] == owner }
            .sorted { lhs, rhs in
                switch (rankByGuid[lhs.guid], rankByGuid[rhs.guid]) {
                case let (left?, right?):
                    // §2.4：rank 平手**按 `pin_uuid`（= 归一后的 lineage）破，绝不按本机
                    // `guid`**。`guid` 是每台设备各铸的，两台机器于是对同一对同 rank 的 pin
                    // 排出相反的次序，各自把自己那份 rank 发回账户——它们互相覆盖、**永不
                    // 收敛**，每一轮各发一条 commit，用户看到两台机器上的 pin 顺序不停对调。
                    // `pin_uuid` 是这一对里唯一两端都认得的键。
                    return left == right
                        ? PinKind.lineageKey(lhs.lineageId) < PinKind.lineageKey(rhs.lineageId)
                        : left < right
                // **没有 rank 的排在后面**：那是一条从没发布过、这一轮也没被碰过的本机行，
                // 把它排到前面会让每一次落地都顺手重排一遍与本轮无关的行。
                case (nil, _?): return false
                case (_?, nil): return true
                case (nil, nil):
                    return lhs.index == rhs.index ? lhs.guid < rhs.guid : lhs.index < rhs.index
                }
            }
        for (position, row) in members.enumerated() { indexOf[row.guid] = position }
    }

    // 三相里的第一相：create / relineage / move。
    var indexed: Set<String> = []
    // §8.2 / Task 10：本轮真的**新建**出来的那些 pin，落地后复核通过的会跟着 outcome 交给
    // 图标回填队列。
    var createdPinsByIdentity: [String: PhiLocalPin] = [:]
    for item in planned where item.step.kind != .delete {
        guard let guid = guidOf[item.identity], !outcome.parked.contains(item.identity) else {
            continue
        }
        if created.contains(item.identity), var row = projected[guid] {
            // **一条身份最多产出一条 `.create`，哪怕它在计划里有两条 step。**
            //
            // `plan` 对一条**有基线**的身份同时产出 `.move` 与 `.update`（位置与内容是
            // 两条步骤，见那里的注释），而 `created` 与 `guidOf` 都是**按身份**记的：上面
            // 那趟循环只铸一个 guid、只 `insert` 一次。这一趟却是**按 step** 走的，不挡的话
            // 两条 step 各自把同一行 append 一遍，`applyPinSyncBatchBody` 于是拿同一个 guid
            // 调两次 `createPinnedTabBody`——库里多出一条**与前一条 guid 完全相同**的 pin 行。
            // 那不是一次可以靠 A11 收拾的变体：两行共享 guid，此后任何按 guid 定位的写
            // （`.move` / `.update` / `.delete`）都只碰得到其中一条，而侧栏那本按
            // `guidInLocalDB` 建的字典会在重复键上直接 trap（Mac B 2026-09-14 23:49 那次
            // 崩溃，`PinnedTabViewController.swift:601`）。
            guard createdPinsByIdentity[item.identity] == nil else { continue }
            row.index = indexOf[guid] ?? 0
            projected[guid] = row
            ops.append(.create(row))
            createdPinsByIdentity[item.identity] = row
            indexed.insert(guid)
        } else if item.step.kind == .create || item.step.kind == .move {
            // §4.5：**先按身份找本机行，找不到才 create**。本机已经有这条身份的行时，一条
            // 计划里的 `.create` 是一次重放而不是一次新建——照着建一遍会让本机每条 pin 在
            // 一次重放之后变成两条，而两条都算得出身份、都不会被差分判成删除。
            ops.append(.move(guid: guid, index: indexOf[guid] ?? 0))
            indexed.insert(guid)
        }
    }
    // 其余兄弟：被触及的 owner 里所有**已经存在于本机**、这一轮还没拿到最终 index 的行。
    for owner in touchedOwners {
        let movers = projected.values
            .filter { ownerOfGuid[$0.guid] == owner && !indexed.contains($0.guid)
                && state.rowByGuid[$0.guid] != nil }
            .sorted { (indexOf[$0.guid] ?? 0, $0.guid) < (indexOf[$1.guid] ?? 0, $1.guid) }
        for row in movers {
            ops.append(.move(guid: row.guid, index: indexOf[row.guid] ?? row.index))
        }
    }

    // 第二相：字段补丁。**拆分伙伴在这里预解析**（§7.4）——伙伴行在同一个 owner 下存在
    // 就把 lineage 交给 store（它在同一个事务里写两个方向），不存在就不写本地链接，并把
    // 那条 lineage 记进游标的 `pendingPartnerLineage`：没有这一半，下一次快照会判出「这个
    // 字段变了」并把 `""` 发出去，**把对端好好的拆分对拆散**，而这台机器只是接收了它。
    var reverseLinks: [PinApplyOp] = []
    var linkedPartners: [String: String] = [:]
    var clearedPartners: Set<String> = []
    for item in planned where item.step.kind != .delete {
        guard let entity = item.entity, let guid = guidOf[item.identity],
              !outcome.parked.contains(item.identity) else { continue }
        var fields = PinFieldPatch()
        if !created.contains(item.identity) {
            fields.title = .some(entity.title.stringValue)
            fields.url = .some(URL(string: entity.url.stringValue))
        }
        let partner = PinKind.lineageKey(entity.splitPartnerUuid.stringValue)
        if partner.isEmpty {
            // 对端解除了这一对：清掉本地链接，游标那一位也跟着清。**本机本来就没有链接时
            // 一个字都不写**——一条刚建出来的行没有伙伴可解，那一条补丁只会在事务里多跑
            // 一次 `applyPinSplitPartnerBody` 并盖一遍 `updatedDate`。
            if state.rowByGuid[guid]?.splitPartnerLineageId != nil {
                fields.splitPartnerLineageId = .some(nil)
                clearedPartners.insert(guid)
            }
            outcome.pendingPartnerLineages[item.identity] = ""
        } else {
            let partnerRow = projected.values.first {
                $0.guid != guid && ownerOfGuid[$0.guid] == item.ownerKey
                    && PinKind.lineageKey($0.lineageId) == partner
            }
            fields.splitPartnerLineageId = .some(partner)
            linkedPartners[guid] = partner
            // 伙伴还没有本地行 ⇒ 这一条是半落地的那一半，记下它在等谁。
            outcome.pendingPartnerLineages[item.identity] = partnerRow == nil ? partner : ""
            // §7.4 的另一半：拆分对是**双向**的，而伙伴那一半的实体这一轮没有到达——它上一轮
            // 就落了地，只是那时这一条还不在本机，于是它的游标记下了 `pendingPartnerLineage`。
            // 反方向那一步必须**在同一个事务里**补上：只写到达的这一侧，另一侧要等下一次本地
            // 变化才被发现，中间那段时间两台机器对同一对 pin 的显示不一致。
            let thisLineage = PinKind.lineageKey(pinIdentityHalves(item.identity).lineage)
            if let partnerRow {
                let partnerIdentity = PinKind.lineageKey(partnerRow.lineageId) + ":"
                    + item.ownerKey
                if input.table.cursors[partnerIdentity]?.pendingPartnerLineage == thisLineage,
                   PinKind.lineageKey(partnerRow.splitPartnerLineageId ?? "") != thisLineage {
                    reverseLinks.append(.update(
                        guid: partnerRow.guid,
                        fields: PinFieldPatch(splitPartnerLineageId: .some(thisLineage))))
                    linkedPartners[partnerRow.guid] = thisLineage
                    outcome.pendingPartnerLineages[partnerIdentity] = ""
                }
            }
        }
        guard fields.title != nil || fields.url != nil || fields.splitPartnerLineageId != nil
        else { continue }
        ops.append(.update(guid: guid, fields: fields))
    }
    // 反方向那几条也是第二相，跟在到达的那一侧后面进同一批。
    ops.append(contentsOf: reverseLinks)

    // 第三相：删除。
    for item in planned where item.step.kind == .delete {
        // §5.6 T3：反查到身份、**本机没有行** ⇒ 什么都不删，但游标照样写 `deletedAtMs`。
        guard let guid = guidOf[item.identity], state.rowByGuid[guid] != nil else {
            outcome.landed.insert(item.identity)
            outcome.deleted.insert(item.identity)
            continue
        }
        ops.append(.delete(guid: guid))
    }

    guard !ops.isEmpty else { return outcome }
    let identities = Set(planned.map(\.identity))
        .subtracting(outcome.parked)
        .subtracting(outcome.landed)
    do {
        try await access.apply(PinApplyBatch(unordered: ops))
    } catch LocalStoreWriteError.rowAlreadyMapped, LocalStoreWriteError.rowNotFound,
            LocalStoreWriteError.rowNotInActiveScope, LocalStoreWriteError.noCandidateSurvived {
        // 这一批**算错了**：拒收。它们不是在等什么，停放会让同一批每轮原样重试、永远不会好。
        outcome.refused.formUnion(identities)
        // 一条 op 都没落，伙伴那几位当然也没写成——同停放那一支，交回空的那张表。
        outcome.pendingPartnerLineages = [:]
        return outcome
    } catch {
        // 导入锁（`.spaceImporting`）与其余一切瞬时失败：**停放**，下一轮重试。
        outcome.parked.formUnion(identities)
        outcome.pendingPartnerLineages = [:]
        return outcome
    }
    // 事务提交了，重铸这才真的发生过。
    outcome.relineaged = relineaged
    // 折叠掉的精确重复没有自己的账户身份，于是差分、游标、每一个计数器都看不见它们——
    // 一条不会被任何人注意到的本机删除。留一行告警，下一次这类竞态是一次 grep 而不是
    // 「用户一小时后发现 pin 重复了」。R12：只有条数与 kind，没有任何行内容。
    if collapsedDuplicates > 0 {
        AppLogWarn("[phi-sync] pins: collapsed \(collapsedDuplicates) exact duplicate row(s) "
                   + "sharing an identity; a round landed beside rows it could not see")
    }
    // 同一个事务里写下去的拆分链接立刻折回轮内投影，于是同一轮的发布段不会把这台机器刚刚
    // **接收**下来的那条链接当成一次本机解除再发回账户（§7.4）。
    state.noteSplitPartnerWrites(linked: linkedPartners, cleared: clearedPartners)

    // §4.5：落地之后、写基线之前，按计划复核一次。复核读的是**落地后**的行——`apply` 收尾
    // 会自己重建一次缓存，所以这个读者此刻答的是新世界。
    for identity in identities {
        let halves = pinIdentityHalves(identity)
        // **问的是完整身份，不是裸 lineage**（R-M3-3-15）。`isKnownLocalPin` 收的是**本机
        // 那一侧**的 ownerKey，而身份后半段是账户级 uuid，中间必须过 `localOwner` 的反查
        // ——直接把 uuid 传下去，本机那一列永不相等，于是每一条都被判成「不在」。反查不出
        // 本机形状 ⇒ nil ⇒ 本机不可能有这条身份的行。
        let localOwnerKey = localOwner(halves.ownerKey)
            .map { $0.spaceId ?? $0.profileId ?? OwnedOwnerMaps.appOwnerKey }
        let known = access.isKnownLocalPin(halves.lineage, ownerKey: localOwnerKey)
        if deletedIdentities.contains(identity) {
            // 只按 lineage 问的旧判据在「同一条 lineage 在别的 owner 下还有行」时答「在」，
            // 于是这条删除被无限期停放——账户上那条实体永远死不掉，而本机那一行早就没了。
            // 按完整身份问之后，答「在」就真的是这个 owner 下还有行，停放才是对的。
            if known { outcome.parked.insert(identity) } else {
                outcome.landed.insert(identity)
                outcome.deleted.insert(identity)
            }
            continue
        }
        guard known else { outcome.parked.insert(identity); continue }
        outcome.landed.insert(identity)
        // §8.2 / Task 10：这一条是本轮**新建**出来的 ⇒ 它按构造没有图标，交给回填队列。
        if let created = createdPinsByIdentity[identity] { outcome.createdPins.append(created) }
        if let payload = payloadOf[identity] { outcome.reconciled[identity] = payload }
    }
    outcome.parked.subtract(outcome.landed)
    outcome.refused.subtract(outcome.landed)
    // 本轮真的被删掉的那些行立刻退出轮内投影，理由同 `landBookmarks`（CASE 6b.8）。
    state.noteDeletedRows(Set(outcome.deleted.compactMap { guidOf[$0] }))
    // Step 3，pin 这一半：走到这里意味着上面那次 `apply` 提交了，于是出站快照之前把轮内
    // 那份本机投影换成**落地后**的行。理由与 `landBookmarks` 逐字相同——不换的话，一次
    // 远端赢下的标题或一次远端重排之后，旧值会配上一个新鲜的 `now` 被发回账户。
    if let refreshed = access.cachedPins() { state.refreshLandedRows(refreshed) }
    return outcome
}

#if DEBUG
extension PhiSyncEngine {
    /// 只读测试面。**没有任何新的驱动入口**：测试照旧用 `pullOnce()` /
    /// `setSpaceSyncEnabled(_:)` / `previewAccountSpaces()` 等既有入口驱动引擎，
    /// 这里暴露的只是它们跑完之后的状态。
    ///
    /// 每一个都是 actor 隔离的，调用方必须 `await` 并**先取值再断言**（`XCTAssert*`
    /// 的参数是 autoclosure，直接把 `await` 表达式塞进去取不到值）。
    ///
    /// 游标表与计数器的访问器由 Task 6 追加进这一段（那时引擎才持有它们）。
    var spaceTableForTesting: PhiSpaceSyncTable { loadSpaceTable() }

    /// 一条注册 kind 本轮那张游标表，按 `label` 取。读的是引擎手上那一份**内存镜像**，
    /// 不是 store——否则一次断言就会多打一次 `load`，把 `MemoryOwnedItemStore` 的
    /// `loseOnLoadNumber` / `hadRecordsSeen` 这两条脚本化语义搅乱。
    func ownedTableForTesting(_ label: String) -> PhiOwnedItemTable {
        ownedTables[label] ?? PhiOwnedItemTable()
    }

    /// 最近一轮每条注册 kind 的计数行（§11.2），按 `label` 索引。
    var lastOwnedRoundCountersForTesting: [String: OwnedRoundCounters] { ownedCounters }

    /// 最近一次预览翻过几页、数过几条实体（§5.8）。轮首清零，成功 / 截断 / 超期 / 退休 /
    /// 传输失败每一条出口都写它，所以读到的绝不会是上一次预览的残值。
    ///
    /// **这是一条独立的只读接缝，不是 `.truncated` 的载荷**：给那个 case 加 associated
    /// value 会同时改坏向导里的两处 `case .truncated:` 与两个测试文件里既有的断言，而
    /// 它们要表达的东西一个字都没变。
    var lastPreviewStatsForTesting: (pages: Int, entities: Int) { lastPreviewStats }

    /// B-2 结局行的四个只读接缝（Task 2b，§2.8）。读的是 `run(_:)` 发射结局行那一刻的**快照**
    /// （`LoggedRound`），不是活的轮级计数：一次 `page_budget_exhausted` 会把跟进轮排进队列，
    /// 而跟进轮的 `run(_:)` 一进门就把活计数清零——活值在断言那一刻读到的可能已经是下一轮的。
    /// `nil` / 0 / false 只表示「这个引擎还没跑完过一轮」。只读，不是新的驱动入口。
    var lastRoundOutcomeForTesting: RoundOutcome? { lastLoggedRound?.outcome }
    /// 最近一轮取回的页数（同一轮内多次 pull 累加）。只读。
    var lastRoundPagesForTesting: Int { lastLoggedRound?.pages ?? 0 }
    /// 最近一轮**盘上**的 marker 是否动过（计划裁定 7）。只读。
    var lastRoundMarkerAdvancedForTesting: Bool { lastLoggedRound?.markerAdvanced ?? false }
    /// 最近一轮四个写口回报失败的次数。只读。
    var lastRoundCursorSaveFailedCountForTesting: Int { lastLoggedRound?.cursorSaveFailures ?? 0 }
}
#endif

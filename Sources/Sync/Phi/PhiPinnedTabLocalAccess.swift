// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// 一条本机 pin 在同步层眼里的取值快照。与 `PhiLocalBookmark` 同款：不依赖
/// `LocalStorage`。
struct PhiLocalPin: Equatable, Sendable {
    /// 本机 `pinLineageId` 的**原样字节**。**不是**身份的全部——身份是
    /// `(lineageId, owner)` 这一对（R-M3-3-15），一条 lineage 在 N 个 Space 里就是 N 条
    /// 实体。
    ///
    /// **计划裁定（P11）：这一列不保证是小写，每一处比较都要先过 `PinKind.lineageKey(_:)`。**
    /// 那一列的来源有三条：`normalizeVariants` 写进去的是 `UUID().uuidString`（**大写**）；
    /// 既有行回落到自己的 `guid`（**大写**）；线上来的才是已归一的小写。投影时**不改写**
    /// 它（保持与 SwiftData 里的字节一致，免得每次读都产生一次伪变化）——归一的责任全部
    /// 在比较入口上。
    var lineageId: String
    /// 本机物理行的 id。落地的每一个操作都按它定位。
    var guid: String
    /// 三个作用域，两个字段，按 §7.2 的表：
    /// **Space 作用域 = `spaceId` 与 `profileId` 都非 nil**（一条 Space 作用域的行既知道
    /// 自己在哪个 Space，也知道那个 Space 绑在哪个 profile 上）；Profile 作用域 =
    /// `spaceId` 为 nil、`profileId` 非 nil；App 作用域 = 两者都为 nil。
    ///
    /// 于是 owner 的判据是**先看 `spaceId` 再看 `profileId`**，不是「哪个非 nil 用哪个」。
    var spaceId: String?
    /// 见 `spaceId` 上那张表：Space 与 Profile 两个作用域下都非 nil，只有 App 作用域为 nil。
    var profileId: String?
    var index: Int
    var title: String
    var url: URL
    /// 对半的 lineage id，nil = 不是 split 的一半。**永远不是**对半的物理
    /// `splitPartnerGuid`（按设备、按副本）。
    var splitPartnerLineageId: String?
    /// `TabSource` 的 raw value。
    var source: Int
    var createdDate: Date
    /// nil = 从未改过内容，比较戳退回 `createdDate`（§6.2）。
    var contentUpdatedDate: Date?
    /// 休眠行不进快照，也不参与差分。
    var isDormant: Bool
}

/// 一次 pin 字段更新要改哪些字段、改成什么。双层可选的读法同
/// `BookmarkFieldPatch`：外层「改不改」，内层「改成什么，nil = 清空」。
struct PinFieldPatch: Equatable {
    var title: String?? = nil
    var url: URL?? = nil
    var splitPartnerLineageId: String?? = nil
}

/// 落地一条远端 pin 所需的**单个**本机写操作。
enum PinApplyOp: Equatable {
    case create(PhiLocalPin)
    /// 把一条已存在的本机行改挂到另一个 lineage 上。**不是**换 owner——换 owner 是老
    /// tag 下的 tombstone 加新 tag 下的 create，永远不是字段变更（§7.2）。
    case relineage(guid: String, newLineageId: String)
    case move(guid: String, index: Int)
    case update(guid: String, fields: PinFieldPatch)
    case delete(guid: String)
}

/// 一轮远端落地要施加的**全部** pin 操作，已排好序。理由同 `BookmarkApplyBatch`：
/// 一轮多条行要走一个事务。
struct PinApplyBatch {
    private(set) var ops: [PinApplyOp]

    /// 与书签同一个三相排序，只是没有父子关系那一层——pin 是平的：
    /// ① create / relineage / move ② update ③ delete。
    ///
    /// 每相内**稳定**（保持传入次序）。
    init(unordered: [PinApplyOp]) {
        self.ops = unordered.enumerated().sorted { lhs, rhs in
            let lhsPhase = Self.phase(lhs.element)
            let rhsPhase = Self.phase(rhs.element)
            if lhsPhase != rhsPhase { return lhsPhase < rhsPhase }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func phase(_ op: PinApplyOp) -> Int {
        switch op {
        case .create, .relineage, .move: return 1
        case .update: return 2
        case .delete: return 3
        }
    }
}

/// 引擎读写本机 pin 的**唯一**接缝。isolation 与抛出约定同 `PhiBookmarkLocalAccess`。
///
/// 生产实现是本文件末尾的 `AccountPhiPinnedTabAccess`。
@MainActor
protocol PhiPinnedTabLocalAccess: AnyObject {
    /// 本机 SwiftData 单例行上的作用域。
    func currentScope() -> PinnedTabScope

    /// **账户**作用域：读 Task 8 的镜像偏好键；从未落地过账户值时返回 nil。
    ///
    /// §7.3 的判据是这两个方法的比较，引擎不去够 `LocalStore` 也不去够 UserDefaults。
    func accountScope() -> PinnedTabScope?

    /// 当前作用域内、**非休眠**的**全部**行，按 `(ownerKey, index, guid)` 有序。
    ///
    /// **不做「每条 lineage 挑一个代表」**——挑代表会把剩下那些行悄悄排除在同步之外，
    /// 而它们从没发布过，差分也永远不会为它们产出任何东西。
    ///
    /// **读失败一律抛，绝不返回空数组**（R-exec-3，与 `allBookmarks()` 同一条）。一次读不
    /// 出来与「这个账户一条 pin 都没有」在值上是同一个 `[]`，而 §4.7 的差分对空集合的回答
    /// 是**给每一条游标发 tombstone**——一次失败的 fetch 会删掉账户上全部 pin，且此后每台
    /// 设备都跟着删。返回一份悄悄过期的旧快照是同一类 bug 的另一种写法，所以也不做。
    func allPins() throws -> [PhiLocalPin]

    /// 差分的定义域：本机**所有**非休眠 pin 行的归一 lineage，**不做作用域过滤**
    /// （R-exec-4，与 `allSyncIds()` 同一条）。
    ///
    /// §4.7 的「这条身份在本机还有没有行」用它，不用 `allPins()`：后者回答的是「同步层这
    /// 一轮认领哪些行」。一次作用域迁移把旧集合的物理行原地留下当备份，它们不在 `allPins()`
    /// 里，但**永远不会被判成删除**——「同步层不认领它」与「账户应该忘掉它」是两句不同的
    /// 话。休眠行仍然排除在外：`isDormant` 的契约明写它不参与差分。
    ///
    /// **与快照同一次 fetch**（L9）：它读的是 `allPins()` 那一次**未经作用域过滤**的行，
    /// 不是第二次查询。因此本轮没有成功读过时它**抛**，而不是自己补一次 fetch，更不是交出
    /// 一个空集合——空集合正是 R-exec-4 要防的那个形状。
    func allPinIdentities() throws -> Set<String>

    /// 本机还有没有这条 lineage。理由同 `isKnownLocalBookmark`。
    ///
    /// **收到的是线上归一过的小写 lineage**（P11）：实现必须把本机那一列也过一遍
    /// `PinKind.lineageKey(_:)` 再比。拿它直接与一个大写的列值比恒为假，后果是每一条本机
    /// pin 都被判成「本机没有这一行」，于是整批发 tombstone。
    ///
    /// **契约**：它读的是**本轮最后一次成功的 `allPins()` 或 `apply(_:)`** 留下的那份快照。
    /// 三种情况下那份快照不存在——本轮还没读过、`allPins()` 抛了、`apply` 落地成功但它末尾
    /// 那次重读抛了（那一批**已经提交**，只是快照跟不上了）。此时它返回 false 并在 DEBUG 下
    /// `assertionFailure`：非抛出的签名表达不了「我这次没读到」，而「每一条都答不在」正是
    /// 会让引擎整批发 tombstone 的那个静默默认值。
    func isKnownLocalPin(_ lineageId: String) -> Bool

    /// 一整轮远端落地，一个事务。抛错 = 一条都没落。
    func apply(_ batch: PinApplyBatch) async throws

    /// 作用域迁移。
    ///
    /// **计划裁定：带两个 `preferred` 参数，与 spec §4.8 的 `changeScope(to:)` 不同。**
    /// §7.1 明确要求落地观察者传的两个 preferred 参数与 UI 路径逐字一致
    /// （`SpacesSettingsView.swift:501-512`），因为 `sourceCollections` 按 `isPreferred`
    /// 排序、`mergeCandidates` 取第一个集合当 `candidate.source`；不带这两个参数，同一次
    /// 作用域变更在「本机操作」与「远端落地」两条路上会产出不同的 pin 集合与顺序。
    func changeScope(to scope: PinnedTabScope,
                     preferredProfileId: String?,
                     preferredSpaceId: String?) async throws
}

/// 生产实现，与 `AccountPhiBookmarkAccess`（`PhiBookmarkLocalAccess.swift`）并列：
/// `@MainActor`，读是纯查询，写一律 `async throws`。
///
/// **依赖从 `init` 注入，收的是 `LocalStore` 而不是 `Account`。** 书签那一侧收一个
/// `Account` 再经 `account.localStorage` 去够 store，而那个属性是懒加载的、指向**真实用户
/// 目录**——于是那个生产类在测试里根本没法驱动，5a 的用例因此只覆盖到假件与纯函数，生产
/// 实现那一层是空白的。协调器在 `buildPhiSyncEngine` 里本来就拿得到 `account.localStorage`，
/// 传进来即可，生产行为一字不变。（给书签 access 补同样的注入是一条 follow-up。）
///
/// **每轮一次 fetch**（§4.8 / §5.7）：`allPins()` 跑那一次读并把结果投影成值快照，顺手建好
/// 归一 lineage 的两份索引；`allPinIdentities()` 与 `isKnownLocalPin(_:)` 读的都是那一份
/// 缓存，**不再 fetch**。
@MainActor
final class AccountPhiPinnedTabAccess: PhiPinnedTabLocalAccess {
    private let store: LocalStore
    private let defaults: UserDefaults

    /// Task 8 写的镜像偏好键。键缺失或值不认识 ⇒ `accountScope()` 返回 nil，引擎按「账户
    /// 还没发过作用域」处理、不判不一致。**这里只读**，写那一侧在 `PinnedTabScopeMirror`。
    ///
    /// 引的是那边的常量，不另写一份同样的字面量：两份字符串分头改掉一份，这一侧会静默地
    /// 永远答 nil（「账户还没发过作用域」），于是 §7.3 的不一致判据整条失效，而没有任何一条
    /// 计数会变色。
    private static var accountScopeKey: String { PinnedTabScopeMirror.key }

    /// 本轮那一次 fetch 的投影结果。`allPins()` 重建，其余两个读者复用。
    private var cachedRows: [PhiLocalPin] = []
    /// 快照里那些行的归一 lineage——`isKnownLocalPin(_:)` 的判据。
    private var cachedLineageKeys: Set<String> = []
    /// 差分的定义域：那一次 fetch 里**未经作用域过滤**的非休眠行的归一 lineage
    /// （L9 / R-exec-4）。
    private var cachedIdentityKeys: Set<String> = []
    /// 本轮有没有一份可用的快照。区分「读到了，就是空的」与「没读到」——后者让
    /// `isKnownLocalPin(_:)` 答「不在」，而那正是会让引擎整批发 tombstone 的静默默认值。
    private var snapshotIsLoaded = false

    init(store: LocalStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
    }

    // MARK: - 读

    func currentScope() -> PinnedTabScope {
        store.pinnedTabScope()
    }

    /// 键缺失、或者值不是三个 `PinnedTabScope` 之一 ⇒ nil。**不回落成 `.profile`**：
    /// 那会把「账户还没发过作用域」伪装成一次真实的账户取值，于是一台本机在 Space 作用域
    /// 的机器会把这当成 §7.3 的不一致并停掉整个 pin 段。
    func accountScope() -> PinnedTabScope? {
        guard let raw = defaults.string(forKey: Self.accountScopeKey) else { return nil }
        return PinnedTabScope(rawValue: raw)
    }

    /// 一次 fetch（带 `\.profile` 预取）+ 一次作用域读，其余全在内存里。读不出来就抛
    /// （R-exec-3）。缓存在这条路径上已经被清空，所以不存在「抛了之后还有人读到一份旧值」。
    func allPins() throws -> [PhiLocalPin] {
        try rebuildCache()
        return cachedRows
    }

    /// 与快照**同一次** fetch 的产物，在作用域过滤**之前**取（R-exec-4 / L9）。
    ///
    /// 本轮没成功读过就抛，绝不返回一个空集合：空集合在 §4.7 那边的含义是「本机一条 pin
    /// 都没有了」，回答是给每一条游标发 tombstone。
    func allPinIdentities() throws -> Set<String> {
        guard snapshotIsLoaded else {
            AppLogError("[phi-sync] pin identities read before a successful snapshot")
            throw LocalStoreWriteError.storeUnavailable
        }
        return cachedIdentityKeys
    }

    /// **两边都过 `PinKind.lineageKey`**（P11）：传进来的是线上归一过的小写 lineage，而本机
    /// 那一列可能是 `UUID().uuidString`（大写）或一条回落成 guid 的旧值。直接比恒为假。
    func isKnownLocalPin(_ lineageId: String) -> Bool {
        guard requireLoadedSnapshot() else { return false }
        return cachedLineageKeys.contains(PinKind.lineageKey(lineageId))
    }

    // MARK: - 写

    /// 一整轮远端落地，**一个**事务（§4.5）。抛错 = 一条都没落，调用方不许写基线。
    ///
    /// 薄转发：事务、三相次序的执行、导入锁的块内重读与末尾的每 owner 一次重排，全在
    /// `LocalStore.applyPinSyncBatchThrowing`（`LocalStore+PinnedTabScope.swift`）里。那些活儿
    /// 够不到这一层——`updateActivePinnedTabBody` / `removeActivePinnedTabBody` /
    /// `relineagePinnedTabBody` 与 `pinnedTab(_:belongsTo:)`、`owner(of:at:)` 都是 `private`，
    /// 而挨个调 throwing 兄弟是 N 个事务，部分成功就成立了（R-exec-2）。
    func apply(_ batch: PinApplyBatch) async throws {
        try await store.applyPinSyncBatchThrowing(batch.ops)
        // 落地改了行，本轮那份快照已经过期。**就地重读一遍**，不是清空了事：§4.5 要求
        // 「落地之后、写基线之前，按计划复核一次」，而复核用的正是上面那两个读者。清空之后
        // `isKnownLocalPin` 对每一条 lineage 都答「不在」，于是引擎把每条身份都判成死映射
        // 并整批发 tombstone。
        //
        // 这次重读抛了就原样上抛，**但那一批已经提交了**——调用方必须把它当成「落地成功、
        // 快照跟不上」，而不是「没落地」。此后两个读者在下一次成功的 `allPins()` 之前一律
        // 无效（见协议上的契约）。
        try rebuildCache()
    }

    /// 作用域迁移。两个 `preferred` 参数与 UI 路径逐字一致（§7.1）：
    /// `sourceCollections` 按 `isPreferred` 排序、`mergeCandidates` 取第一个集合当
    /// `candidate.source`，不带它们的话同一次作用域变更在「本机操作」与「远端落地」两条路上
    /// 会产出不同的 pin 集合与顺序。
    func changeScope(to scope: PinnedTabScope,
                     preferredProfileId: String?,
                     preferredSpaceId: String?) async throws {
        try await store.changePinnedTabScope(to: scope,
                                             preferredProfileId: preferredProfileId,
                                             preferredSpaceId: preferredSpaceId)
        // 迁移重建了整批物理行（新 guid、新归属），本轮那份快照与它已经没有关系了。
        // **只清不重读**：§7.3 让作用域收敛的那一轮整个发布段都不跑，所以这一轮之后没有
        // 读者；重读只会多一次没人用的 fetch。
        invalidateCache()
    }

    // MARK: - 私有

    /// **清空而不是留着**：留着就等于让 `isKnownLocalPin` 继续回答一份过期的形状，而调用方
    /// 看不出区别。
    private func invalidateCache() {
        cachedRows = []
        cachedLineageKeys = []
        cachedIdentityKeys = []
        snapshotIsLoaded = false
    }

    /// 非抛出读者的前置判断。返回 false 时调用方交出「不在」那个值——它是**错的**，只是
    /// 签名里没有别的东西可交，所以 DEBUG 下直接炸，让误用当场现形，而不是变成一批
    /// tombstone。
    private func requireLoadedSnapshot() -> Bool {
        if !snapshotIsLoaded {
            assertionFailure("read the pin snapshot before a successful allPins()/apply()")
        }
        return snapshotIsLoaded
    }

    /// **失败一律抛，而且先把缓存清干净**（R-exec-3）。
    private func rebuildCache() throws {
        invalidateCache()
        guard let context = store.getMainContext() else {
            AppLogError("[phi-sync] pin snapshot failed: no main context")
            throw LocalStoreWriteError.storeUnavailable
        }
        let fetched: LocalStore.PinSyncFetch
        do {
            fetched = try store.pinSyncFetch(in: context)
        } catch {
            // R12：只记类型与 domain/code，不记任何行内容。
            AppLogError("[phi-sync] pin snapshot fetch failed: \(PhiSyncLog.describe(error))")
            throw error
        }

        // 拆分伙伴在本机是一个**物理 guid**，而线上那一半是 lineage（按设备、按副本的 guid
        // 到不了别的机器）。翻译表出自同一批 models，所以不需要第二次查询。
        var lineageByGuid: [String: String] = [:]
        for model in fetched.nonDormant {
            lineageByGuid[model.guid] = model.pinLineageId ?? model.guid
        }

        let rows = fetched.active.map { Self.project($0, lineageByGuid: lineageByGuid) }
        // 两份索引与快照一起换上，中间没有任何一刻是「行在、索引不在」。
        cachedRows = rows
        cachedLineageKeys = Set(rows.map { PinKind.lineageKey($0.lineageId) })
        cachedIdentityKeys = Set(fetched.nonDormant.map {
            PinKind.lineageKey($0.pinLineageId ?? $0.guid)
        })
        snapshotIsLoaded = true
    }

    /// 取值快照，绝不是 model 对象：SwiftData 就地刷新同一批实例，按对象比较的去重会吞掉
    /// 真实的字段编辑（§4.8）。
    ///
    /// `lineageId` **原样投影**（P11）：归一只发生在比较入口，写回那一列会让每一次读都产生
    /// 一次伪变化。
    private static func project(_ model: TabDataModel,
                                lineageByGuid: [String: String]) -> PhiLocalPin {
        PhiLocalPin(lineageId: model.pinLineageId ?? model.guid,
                    guid: model.guid,
                    spaceId: model.spaceId,
                    profileId: model.profileId ?? model.profile?.profileId,
                    index: model.index,
                    title: model.title,
                    url: model.url,
                    splitPartnerLineageId: model.splitPartnerGuid.flatMap { lineageByGuid[$0] },
                    source: model.source,
                    createdDate: model.createdDate,
                    contentUpdatedDate: model.contentUpdatedDate,
                    isDormant: model.isPinnedTabDormant)
    }
}

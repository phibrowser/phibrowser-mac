// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// 一条本机书签 / 文件夹在同步层眼里的取值快照。与 `PhiLocalSpace`
/// （`PhiSpaceLocalAccess.swift:13`）同款：住在 `Sources/Sync/Phi/`、**不依赖
/// `LocalStorage`**，所以同步层可以在没有 SwiftData 的测试进程里整体构造。
///
/// 比 spec §4.8 的 13 个字段多一个 `contentUpdatedDate`——§6.2 要求本机侧的比较戳是
/// `contentUpdatedDate ?? createdDate`，没有这一列就取不到。
struct PhiLocalBookmark: Equatable, Sendable {
    /// 账户级 uuid（小写），首次发布时铸造后写回 `TabDataModel.syncId`。nil = 这一行
    /// 还没发布过。**永远不是本机 `guid`**（大写、按设备、每次克隆重铸）。
    var syncId: String?
    /// 本机物理行的 id。落地的每一个操作都按它定位。
    var guid: String
    var spaceId: String
    var profileId: String
    /// nil = 这一行挂在 Space 的 canonical root 下。
    var parentGuid: String?
    var index: Int
    var isFolder: Bool
    var title: String
    /// 文件夹带占位 URL `https://bookmark.phi/folder`。
    var url: URL
    var secondaryUrl: URL?
    var secondaryTitle: String?
    /// `TabSource` 的 raw value（0 phi / 1 chromium / 2 safari / 3 arc）。
    var source: Int
    var createdDate: Date
    /// nil = 从未改过内容，比较戳退回 `createdDate`（§6.2）。
    var contentUpdatedDate: Date?
}

/// 一次字段更新要改哪些字段、改成什么。
///
/// **双层可选**：外层「改不改」，内层「改成什么，nil = 清空」。四个成员都有 `= nil`
/// 默认值，所以 `BookmarkFieldPatch(title: "T")` 成立。
struct BookmarkFieldPatch: Equatable {
    var title: String?? = nil
    var url: URL?? = nil
    var secondaryUrl: URL?? = nil
    var secondaryTitle: String?? = nil
}

/// 落地一条远端书签所需的**单个**本机写操作。
enum BookmarkApplyOp: Equatable {
    /// 把一个账户级 uuid 认领到一条已存在的本机行上（写 `syncId`），不改任何内容字段。
    case claim(guid: String, syncId: String)
    case create(PhiLocalBookmark)
    /// LOCATION 变更：父、所属 Space 与同级次序一起写，三者是一个整体（§4.3）。
    case move(guid: String, toParentGuid: String?, inSpaceId: String, index: Int)
    case update(guid: String, fields: BookmarkFieldPatch)
    case delete(guid: String)
}

/// 一轮远端落地要施加的**全部**书签操作，已按 §4.4 排好序。
///
/// **是操作列表，不是单个枚举**：`apply(_:)` 一次要落一整轮的多条行，裸枚举一次只能落
/// 一行，§4.5 的「一轮远端落地的多条行用一个事务」就不成立。
struct BookmarkApplyBatch {
    private(set) var ops: [BookmarkApplyOp]

    /// 按 §4.4 三相排序：① claim / create / move（父先于子）② update ③ delete（子先于父）。
    ///
    /// `parentOf` 是这一轮**排完序之后**的父子关系（子 guid → 父 guid），排序只用它算深
    /// 度，不用它推导任何操作。不在表里的 guid 深度算 0：它要么是根级，要么它的父这一轮
    /// 没被碰过，两种情况下同相内它与谁先谁后都无所谓。
    ///
    /// 排序在每一相内是**稳定**的（同深度的保持传入次序），所以调用方自己攒的次序在排序
    /// 判据说不出话的地方仍然被保留。
    init(unordered: [BookmarkApplyOp], parentOf: [String: String] = [:]) {
        let depths = Self.depths(of: unordered.map(Self.targetGuid), parentOf: parentOf)
        let ordered = unordered.enumerated().sorted { lhs, rhs in
            let lhsPhase = Self.phase(lhs.element)
            let rhsPhase = Self.phase(rhs.element)
            if lhsPhase != rhsPhase { return lhsPhase < rhsPhase }
            let lhsDepth = depths[Self.targetGuid(lhs.element)] ?? 0
            let rhsDepth = depths[Self.targetGuid(rhs.element)] ?? 0
            if lhsDepth != rhsDepth {
                // delete 相里子先于父，其余两相父先于子。
                return lhsPhase == 3 ? lhsDepth > rhsDepth : lhsDepth < rhsDepth
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
        self.ops = ordered
        assert(Self.noDeleteBeforeItsDescendants(ordered, parentOf: parentOf),
               "a delete must never precede an operation targeting one of its descendants")
    }

    /// ① claim / create / move ② update ③ delete。
    private static func phase(_ op: BookmarkApplyOp) -> Int {
        switch op {
        case .claim, .create, .move: return 1
        case .update: return 2
        case .delete: return 3
        }
    }

    /// 每个操作定位的那条本机行。
    private static func targetGuid(_ op: BookmarkApplyOp) -> String {
        switch op {
        case .claim(let guid, _): return guid
        case .create(let row): return row.guid
        case .move(let guid, _, _, _): return guid
        case .update(let guid, _): return guid
        case .delete(let guid): return guid
        }
    }

    /// 从 `parentOf` 往上走到没有父为止。`parentOf.count` 当跳数上限：一条环（不该出现，
    /// 但本机数据损坏时可能）在这里被截断成一个有限深度，而不是把落地挂死。
    private static func depths(of guids: [String],
                               parentOf: [String: String]) -> [String: Int] {
        var out: [String: Int] = [:]
        let limit = parentOf.count
        for guid in guids where out[guid] == nil {
            var depth = 0
            var cursor = parentOf[guid]
            while let parent = cursor, depth < limit {
                depth += 1
                cursor = parentOf[parent]
            }
            out[guid] = depth
        }
        return out
    }

    /// 不变量：没有任何 `delete` 排在**以它后代为目标**的操作之前。
    private static func noDeleteBeforeItsDescendants(_ ops: [BookmarkApplyOp],
                                                     parentOf: [String: String]) -> Bool {
        var deletedAt: [String: Int] = [:]
        for (index, op) in ops.enumerated() {
            if case .delete(let guid) = op { deletedAt[guid] = index }
        }
        guard !deletedAt.isEmpty else { return true }
        let limit = parentOf.count
        for (index, op) in ops.enumerated() {
            var hops = 0
            var cursor = parentOf[targetGuid(op)]
            while let ancestor = cursor, hops < limit {
                if let deleteIndex = deletedAt[ancestor], deleteIndex < index { return false }
                cursor = parentOf[ancestor]
                hops += 1
            }
        }
        return true
    }
}

/// 引擎读写本机书签的**唯一**接缝。引擎是 `actor`，它照既有 `PhiSpaceLocalAccess`
/// （`PhiSpaceLocalAccess.swift:47`）的写法 hop 到 main actor 上调这些方法。
///
/// 写方法一律 `async throws`：非抛出签名表达不了「基线只能在行真的落了之后才写」
/// （§5.6）。
///
/// **精化 `PhiFaviconWriting`**（§8.2 / Task 10）：图标回填要的那个窄写入口挂在那条协议
/// 上，于是回填队列只认「能写 favicon 的东西」，够不着快照、差分与 `apply`。favicon 刻意
/// 不做成 `BookmarkApplyOp` 的一个 case——它不在快照里，不该经过三相排序、不该与同步落地
/// 共用事务、也不该让 §5.7 的值快照去重多认一个字段。
///
/// 生产实现是本文件末尾的 `AccountPhiBookmarkAccess`。
@MainActor
protocol PhiBookmarkLocalAccess: PhiFaviconWriting {
    /// **一次** fetch 带关系预取，**每轮至多算一次**，结果交给快照 / 差分 / index 投影
    /// 三个消费者复用。
    ///
    /// 返回值按 `(spaceId, parentGuid, index, guid)` 有序（§4.8），无父的行排在同 Space 的
    /// 有父行之前。三个消费者都依赖这个次序：`siblings(ofParent:inSpaceId:)` 是它的分组，
    /// 差分按它产出提交序列，index 投影按它编号。
    ///
    /// root 行**从不是快照行**：它们的直接孩子投影出 `parentGuid == nil`；不在 canonical
    /// root 集合里的无父 `bookmarkFolder`（并发初始化留下的孤儿根）**整棵排除**。
    ///
    /// **读失败一律抛，绝不返回空数组**（R-exec-3）。一次读不出来与「这个账户一条书签都
    /// 没有」在值上是同一个 `[]`，而 §4.7 的差分对空集合的回答是**给每一条游标发
    /// tombstone**——一次失败的 fetch 会删掉账户上整棵树，且此后每台设备都跟着删。返回一份
    /// 悄悄过期的旧快照是同一类 bug 的另一种写法，所以也不做。
    func allBookmarks() throws -> [PhiLocalBookmark]

    /// 本机**所有**带账户级身份的行的 `syncId`，**不做任何根过滤**（R-exec-4）。
    ///
    /// §4.7 的差分定义域用它，不用 `allBookmarks()`：那一个回答的是「同步层认领哪些行」，
    /// 这一个回答的是「这条身份在本机还有没有行」。孤儿根下面的行继续**不发布**（它们不在
    /// 快照里），但**永远不会被判成删除**——「同步层不认领它」与「账户应该忘掉它」是两句
    /// 不同的话。
    ///
    /// **与快照同一次 fetch**（L9）：它读的是 `allBookmarks()` 那一次**未经根过滤**的行，
    /// 不是第二次查询。两次读之间隔着至少一次 actor hop，期间用户删掉一条行的话，同一轮里
    /// 它会既在快照里（当成活的发布）又不在 `locals` 里（发 tombstone）。因此本轮没有成功
    /// 读过时它**抛**，而不是自己补一次 fetch。
    func allSyncIds() throws -> Set<String>

    /// **本轮最后一次成功的 `allBookmarks()` 或 `apply(_:)` 留下的那份行快照**，
    /// **不再 fetch**（§5.7 第 2 条硬要求）。次序与 `allBookmarks()` 交出的那一份相同。
    ///
    /// 它存在的理由只有一个：一次落地改了行之后，**同一轮的出站快照必须看见落地后的那份
    /// 投影**（§4.2 与 §4.5 之间那道接缝）。落地把一条远端赢下的标题或一次远端搬家写进了
    /// 本机行，而轮内那份本机投影还停在落地**之前**——差分于是判成「本机改了」，把**旧值**
    /// 配上一个**新鲜的 `now`** 发回账户，而那个 `now` 比对端刚才那次真实编辑更晚，于是
    /// 旧值盖掉新值。一次纯粹的读写时序问题就此变成一次数据回滚。
    ///
    /// **`nil` = 本轮没有一份可用的快照**（还没读过、`allBookmarks()` 抛了、或 `apply` 落地
    /// 成功但它末尾那次重读抛了）。调用方此时**原样留着轮内那份投影**，绝不把它清空——
    /// 与另外三个非抛出读者不同，这一个的正确回答是「我这次没读到」，所以它用可选值说出来
    /// 而不是交出一个会让整轮快照变空的 `[]`。
    func cachedBookmarks() -> [PhiLocalBookmark]?

    /// **不是第二次 fetch**，是 `allBookmarks()` 那一次结果按 `(spaceId, parentGuid)`
    /// 在内存里的分组。
    ///
    /// 且**不过滤**——§4.10 的 index 投影必须喂未过滤的兄弟列表，否则被排除的兄弟留着的
    /// 旧 `index` 会与新写的撞上。
    ///
    /// **契约**：它与 `isKnownLocalBookmark(_:)` / `localIsFolder(guid:)` 三个读的都是**本轮
    /// 最后一次成功的 `allBookmarks()` 或 `apply(_:)`** 留下的那份快照。一次成功的 `apply`
    /// 会自己重读一遍，所以 §4.5 要求的「落地之后、写基线之前按计划复核一次」在同一轮里
    /// 就能做，不必再调一次 `allBookmarks()`。
    ///
    /// 三种情况下这份快照**不存在**：本轮还没读过、`allBookmarks()` 抛了、`apply` 落地成功
    /// 但它末尾那次重读抛了（那一批**已经提交**，只是快照跟不上了）。此时三个读者返回
    /// 空 / false / nil，并在 DEBUG 下 `assertionFailure`——它们**不会**自己补一次 fetch：
    /// 非抛出的签名表达不了「我这次没读到」，悄悄补一次读只会把 R-exec-3 挡掉的那个洞搬到
    /// 这里，而「每一条都答不在」正是会让引擎把整棵树当成新行重建的那个静默默认值。
    func siblings(ofParent parentGuid: String?, inSpaceId spaceId: String) -> [PhiLocalBookmark]

    /// 本机还有没有这条物理行。与 `PhiSpaceLocalAccess.isKnownLocalSpace` 同款理由：
    /// 按 `syncId` 反查读回的正是解析 FROM 的那张表，永远说有。
    func isKnownLocalBookmark(_ guid: String) -> Bool

    /// 本机那一行的物理类型。nil = 本机没有这条身份对应的行。
    /// §4.6 的物理行 `is_folder` 判据用它——`refuses(_:baseline:)` 只比**游标基线**，
    /// 够不着「身份反查到一条行、但那一行的 dataType 与载荷不符」这一类。
    func localIsFolder(guid: String) -> Bool?

    /// 这个 Space 正在导入。导入期间的行不发布（`ImportTargetLock`）。
    func isImporting(intoSpaceId spaceId: String) -> Bool

    /// 一整轮远端落地，一个事务（§4.5）。抛错 = 一条都没落，调用方不许写基线。
    func apply(_ batch: BookmarkApplyBatch) async throws

    /// 退出账户 / 重置同步状态时抹掉全部 `syncId`（§9.2）。
    func clearAllSyncIds() async throws
}

/// 生产实现，与 `AccountPhiSpaceAccess`（`PhiSpaceLocalAccess.swift:142`）并列：持
/// `Account.localStorage`，`@MainActor`，读是纯查询，写一律 `async throws`。
///
/// **每轮一次 fetch**（§4.8 / §5.7）：`allBookmarks()` 跑那一次读并把结果投影成值快照，
/// 顺手建好 `(spaceId, parentGuid)` 的分组与 `guid -> isFolder` 的索引；
/// `siblings(ofParent:inSpaceId:)`、`isKnownLocalBookmark(_:)` 与 `localIsFolder(guid:)`
/// 读的都是那一份缓存，**不再 fetch**。
@MainActor
final class AccountPhiBookmarkAccess: PhiBookmarkLocalAccess {
    private let account: Account

    /// 分组缓存的键。`parentGuid == nil` 表示「直接挂在这个 Space 的 canonical root 下」。
    private struct SiblingKey: Hashable {
        var spaceId: String
        var parentGuid: String?
    }

    /// 本轮那一次 fetch 的投影结果。`allBookmarks()` 重建，其余三个读者复用。
    private var cachedRows: [PhiLocalBookmark] = []
    private var cachedSiblings: [SiblingKey: [PhiLocalBookmark]] = [:]
    private var cachedIsFolder: [String: Bool] = [:]
    /// 差分的定义域：那一次 fetch 的**全部**行的身份，根过滤之前就取好（L9 / R-exec-4）。
    private var cachedSyncIds: Set<String> = []
    /// 本轮有没有一份可用的快照。区分「读到了，就是空的」与「没读到」——后者让三个非抛出
    /// 的读者答「都不在」，而那正是会让引擎把整棵树当成新行重建的静默默认值。
    private var snapshotIsLoaded = false

    init(account: Account) {
        self.account = account
    }

    // MARK: - 读

    /// 一次 fetch（带 `[\.parent, \.profile]` 预取）+ 一次 canonical root 解析，其余全在
    /// 内存里。
    ///
    /// **从 canonical root 往下走，绝不用「取全部行再减去 root 集合」**：`existingBookmarkRoot`
    /// 从不治愈（`LocalStore+Bookmark.swift:1389`），所以关系断掉的孤儿根不在 canonical
    /// 集合里，减法会把那一棵整个留在快照里——于是同步层认领了一棵 UI 根本看不见的树，
    /// 而 heal-on-read 随时会把它并进主根或删掉。递归天然把它排除在外（§4.8 / R-M3-3-19）。
    /// 读不出来就抛（R-exec-3）。缓存在这条路径上已经被清空，所以不存在「抛了之后还有人
    /// 读到一份旧值」。
    func allBookmarks() throws -> [PhiLocalBookmark] {
        try rebuildCache()
        return cachedRows
    }

    /// 与快照**同一次** fetch 的产物，在根递归**之前**取（R-exec-4 / L9）：差分要的是
    /// 「这条身份在本机还有没有行」，孤儿根下面那些行照样算数。
    ///
    /// 本轮没成功读过就抛，绝不返回一个空集合：空集合在 §4.7 那边的含义是「本机一条带身份
    /// 的行都没有了」，回答是给每一条游标发 tombstone。
    func allSyncIds() throws -> Set<String> {
        guard snapshotIsLoaded else {
            AppLogError("[phi-sync] bookmark identities read before a successful snapshot")
            throw LocalStoreWriteError.storeUnavailable
        }
        return cachedSyncIds
    }

    /// 那一次 fetch 的行快照本身，**不再 fetch**。`apply(_:)` 收尾已经重建过它，所以
    /// 落地之后同一轮的出站快照拿它就能看见落地后的世界。
    ///
    /// **本轮没读到就交 nil，不交 `[]`**：调用方拿它去换掉轮内那份本机投影，一个空数组会
    /// 让整轮的出站快照变空（见协议上的契约）。
    func cachedBookmarks() -> [PhiLocalBookmark]? {
        guard snapshotIsLoaded else { return nil }
        return cachedRows
    }

    /// 分组缓存的读取，**不再 fetch**、**不过滤**（§4.10 的 index 投影要未过滤的兄弟）。
    func siblings(ofParent parentGuid: String?, inSpaceId spaceId: String) -> [PhiLocalBookmark] {
        guard requireLoadedSnapshot() else { return [] }
        return cachedSiblings[SiblingKey(spaceId: spaceId, parentGuid: parentGuid)] ?? []
    }

    /// 判据是「在本轮那份快照里」，不是「库里还有没有这个 guid」。两者只在被整棵排除的
    /// 孤儿根子树上有分歧，而对同步层来说那些行按定义不存在——差分的定义域、index 投影
    /// 的兄弟列表、快照都读同一份缓存，这个谓词跟着它们才不会自相矛盾。
    func isKnownLocalBookmark(_ guid: String) -> Bool {
        guard requireLoadedSnapshot() else { return false }
        return cachedIsFolder[guid] != nil
    }

    /// 从那一次 fetch 的缓存里读物理类型，**不额外 fetch**。找不到 ⇒ nil。
    func localIsFolder(guid: String) -> Bool? {
        guard requireLoadedSnapshot() else { return nil }
        return cachedIsFolder[guid]
    }

    func isImporting(intoSpaceId spaceId: String) -> Bool {
        ImportTargetLock.shared.isImporting(into: spaceId)
    }

    // MARK: - 写

    /// 一整轮远端落地，**一个**事务（§4.5）。抛错 = 一条都没落，调用方不许写基线。
    ///
    /// 薄转发：事务、三相次序的执行、导入锁的块内重读与末尾的每父一次重排，全在
    /// `LocalStore.applyBookmarkSyncBatchThrowing`（`LocalStore+Bookmark.swift`）里。
    /// 那些活儿够不到这一层——`moveBookmarkBody` / `updateBookmarkBody` /
    /// `deleteBookmarkBody` 与 `bookmarkNode` / `children` / `normalizeIndexes` 都是
    /// `private`，而挨个调 throwing 兄弟是 N 个事务，部分成功就成立了（R-exec-2）。
    func apply(_ batch: BookmarkApplyBatch) async throws {
        try await account.localStorage.applyBookmarkSyncBatchThrowing(batch.ops)
        // 落地改了行，本轮那份快照已经过期。**就地重读一遍**，不是清空了事：§4.5 要求
        // 「落地之后、写基线之前，按计划复核一次」，而复核用的正是那三个读者。清空之后它们
        // 对每一个 guid 都答「不在」，复核于是永远不通过、基线永远不写、同一批每轮重放；
        // 更糟的是 `isKnownLocalBookmark` 全答 false 会让引擎把每条身份都判成死映射，把整棵
        // 树当成新行重建一遍。
        //
        // 这次重读抛了就原样上抛，**但那一批已经提交了**——调用方必须把它当成「落地成功、
        // 快照跟不上」，而不是「没落地」。此后三个读者在下一次成功的 `allBookmarks()` 之前
        // 一律无效（见协议上的契约）。
        try rebuildCache()
    }

    /// 回填专用的窄写入口（§8.2 / Task 10）。一轮的若干条**合成一次**后台写。
    ///
    /// **不碰任何缓存**：`favicon` 不是 `PhiLocalBookmark` 的字段，这次写改不了本轮那份
    /// 快照的任何一个取值，所以它对差分、对 §5.7 的值快照去重、对游标全都不可见——正是
    /// 「回填不触发推送」那条要求的实现方式。
    func setFavicon(_ writes: [(guid: String, data: Data)]) async throws {
        try await account.localStorage.updateTabFaviconsThrowing(
            writes.map { (guid: $0.guid, favicon: $0.data) })
    }

    /// 一次批量写（§9.2）。逐条一个事务在一棵上千条的树上是上千个事务。
    func clearAllSyncIds() async throws {
        try await account.localStorage.clearAllBookmarkSyncIdsThrowing()
        // 自撤销 / 账户重置的收尾路径：这一轮之后没有读者了，所以只清不重读。
        invalidateCache()
    }

    // MARK: - 私有

    /// **清空而不是留着**：留着就等于让 `siblings` / `localIsFolder` 继续回答一份过期的
    /// 形状，而调用方看不出区别。
    private func invalidateCache() {
        cachedRows = []
        cachedSiblings = [:]
        cachedIsFolder = [:]
        cachedSyncIds = []
        snapshotIsLoaded = false
    }

    /// 三个非抛出读者共用的前置判断。返回 false 时调用方交出「不在」那个值——它是**错的**，
    /// 只是签名里没有别的东西可交，所以 DEBUG 下直接炸，让误用在 Task 6 的用例里当场现形，
    /// 而不是变成一棵重建出来的重复树。
    private func requireLoadedSnapshot() -> Bool {
        if !snapshotIsLoaded {
            assertionFailure("read the bookmark snapshot before a successful allBookmarks()/apply()")
        }
        return snapshotIsLoaded
    }

    /// **失败一律抛，而且先把缓存清干净**（R-exec-3）。
    ///
    /// 早先这里是「记一条日志，把上一轮那份留着」。两种静默模式都得走：一份假的空快照在
    /// 差分那边的含义是「本机这些行全没了」，而差分对「没了」的回答是给每一条游标发
    /// tombstone（§4.7）——一次 fetch 失败删掉账户上整棵树；留着上一轮那份则更隐蔽，一次
    /// 成功的 `apply` 之后再读失败，调用方拿到的是**落地之前**的形状，而它以为那是刚读的。
    ///
    /// 引擎侧那一半（本轮该 kind 的 snapshot / 差分 / 发布整段跳过，计 `local_read_failed`）
    /// 是 Task 6 的事。
    private func rebuildCache() throws {
        invalidateCache()
        let store = account.localStorage
        guard let context = store.getMainContext() else {
            AppLogError("[phi-sync] bookmark snapshot failed: no main context")
            throw LocalStoreWriteError.storeUnavailable
        }
        let models: [TabDataModel]
        let roots: Set<String>
        do {
            models = try store.allBookmarkModels(in: context)
            roots = try store.canonicalRootGuids(in: context)
        } catch {
            // R12：只记类型与 domain/code，不记任何行内容。
            AppLogError("[phi-sync] bookmark snapshot fetch failed: \(PhiSyncLog.describe(error))")
            throw error
        }

        // 差分的定义域在**根递归之前**就取好：它要的是「这条身份在本机还有没有行」，孤儿根
        // 下面那些行照样算数（R-exec-4）。与快照同一次 fetch，所以两者之间没有第二个时刻
        // （L9）。
        let syncIds = Set(models.compactMap(\.syncId))

        // 一次 fetch 的结果在内存里连成父子表，于是「从 canonical root 往下走」不需要
        // 第二次查询。`\.parent` 已经预取过，`parent?.guid` 不会再 fault。
        var childrenByParent: [String: [TabDataModel]] = [:]
        for model in models {
            guard let parentGuid = model.parent?.guid else { continue }
            childrenByParent[parentGuid, default: []].append(model)
        }

        var rows: [PhiLocalBookmark] = []
        // root 行本身从不是快照行（§3.4 规则 1），它的直接孩子投影出 `parentGuid == nil`。
        // 队列里带的 `parentGuid` 就是「投影出来的父」，root 的孩子带 nil。
        var queue: [(model: TabDataModel, parentGuid: String?)] = []
        for rootGuid in roots {
            for child in childrenByParent[rootGuid] ?? [] {
                queue.append((child, nil))
            }
        }
        var cursor = 0
        while cursor < queue.count {
            let (model, parentGuid) = queue[cursor]
            cursor += 1
            let row = Self.project(model, parentGuid: parentGuid)
            rows.append(row)
            if row.isFolder {
                for child in childrenByParent[model.guid] ?? [] {
                    queue.append((child, model.guid))
                }
            }
        }

        // §4.8 的次序：`(spaceId, parentGuid, index, guid)`，无父的行排在同 Space 的有父
        // 行之前（`nil` 投影成 ""，它小于任何真 guid）。差分按它产出提交序列，index 投影
        // 按它编号，所以这个次序是契约的一部分，不是实现细节。
        rows.sort {
            ($0.spaceId, $0.parentGuid ?? "", $0.index, $0.guid)
                < ($1.spaceId, $1.parentGuid ?? "", $1.index, $1.guid)
        }
        // 三份索引与快照一起换上，中间没有任何一刻是「行在、索引不在」。
        var siblings: [SiblingKey: [PhiLocalBookmark]] = [:]
        var isFolder: [String: Bool] = [:]
        for row in rows {
            siblings[SiblingKey(spaceId: row.spaceId, parentGuid: row.parentGuid),
                     default: []].append(row)
            isFolder[row.guid] = row.isFolder
        }
        cachedRows = rows
        cachedSiblings = siblings
        cachedIsFolder = isFolder
        cachedSyncIds = syncIds
        snapshotIsLoaded = true
    }

    /// 取值快照，绝不是 model 对象：SwiftData 就地刷新同一批实例，按对象比较的去重会吞
    /// 掉真实的字段编辑（§4.8）。
    private static func project(_ model: TabDataModel, parentGuid: String?) -> PhiLocalBookmark {
        PhiLocalBookmark(syncId: model.syncId,
                         guid: model.guid,
                         spaceId: model.spaceId ?? LocalStore.defaultSpaceId,
                         profileId: model.profileId ?? LocalStore.defaultProfileId,
                         parentGuid: parentGuid,
                         index: model.index,
                         isFolder: model.dataType == .bookmarkFolder,
                         title: model.title,
                         url: model.url,
                         secondaryUrl: model.secondaryUrl,
                         secondaryTitle: model.secondaryTitle,
                         source: model.source,
                         createdDate: model.createdDate,
                         contentUpdatedDate: model.contentUpdatedDate)
    }
}

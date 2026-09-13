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
/// 生产实现是本文件末尾的 `AccountPhiBookmarkAccess`。
@MainActor
protocol PhiBookmarkLocalAccess: AnyObject {
    /// **一次** fetch 带关系预取，**每轮至多算一次**，结果交给快照 / 差分 / index 投影
    /// 三个消费者复用。
    ///
    /// 返回值按 `(spaceId, parentGuid, index, guid)` 有序（§4.8），无父的行排在同 Space 的
    /// 有父行之前。三个消费者都依赖这个次序：`siblings(ofParent:inSpaceId:)` 是它的分组，
    /// 差分按它产出提交序列，index 投影按它编号。
    ///
    /// root 行**从不是快照行**：它们的直接孩子投影出 `parentGuid == nil`；不在 canonical
    /// root 集合里的无父 `bookmarkFolder`（并发初始化留下的孤儿根）**整棵排除**。
    func allBookmarks() -> [PhiLocalBookmark]

    /// **不是第二次 fetch**，是 `allBookmarks()` 那一次结果按 `(spaceId, parentGuid)`
    /// 在内存里的分组。
    ///
    /// 且**不过滤**——§4.10 的 index 投影必须喂未过滤的兄弟列表，否则被排除的兄弟留着的
    /// 旧 `index` 会与新写的撞上。
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
    private var cachedSpaceIdByGuid: [String: String] = [:]
    /// 这一轮还没读过。三个读者在这种情况下各自触发一次构建，**之后本轮不再 fetch**：
    /// 返回一份空快照会让差分把整棵树读成「本机已经没有这些行了」，那是会删掉账户数据的
    /// 错法（§4.7）。
    private var hasCache = false

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
    func allBookmarks() -> [PhiLocalBookmark] {
        rebuildCache()
        return cachedRows
    }

    /// 分组缓存的读取，**不再 fetch**、**不过滤**（§4.10 的 index 投影要未过滤的兄弟）。
    func siblings(ofParent parentGuid: String?, inSpaceId spaceId: String) -> [PhiLocalBookmark] {
        ensureCache()
        return cachedSiblings[SiblingKey(spaceId: spaceId, parentGuid: parentGuid)] ?? []
    }

    /// 判据是「在本轮那份快照里」，不是「库里还有没有这个 guid」。两者只在被整棵排除的
    /// 孤儿根子树上有分歧，而对同步层来说那些行按定义不存在——差分的定义域、index 投影
    /// 的兄弟列表、快照都读同一份缓存，这个谓词跟着它们才不会自相矛盾。
    func isKnownLocalBookmark(_ guid: String) -> Bool {
        ensureCache()
        return cachedIsFolder[guid] != nil
    }

    /// 从那一次 fetch 的缓存里读物理类型，**不额外 fetch**。找不到 ⇒ nil。
    func localIsFolder(guid: String) -> Bool? {
        ensureCache()
        return cachedIsFolder[guid]
    }

    func isImporting(intoSpaceId spaceId: String) -> Bool {
        ImportTargetLock.shared.isImporting(into: spaceId)
    }

    // MARK: - 写

    /// 一整轮远端落地，**一个**事务（§4.5）。抛错 = 一条都没落，调用方不许写基线。
    ///
    /// 三件事在这一个块里：
    /// 1. **导入锁在写块内部再读一次**（§4.9 第 3 条）。轮首那次读只是优化——读完之后
    ///    导入才开始的那个边沿，只有在事务里重读才能挡住。占用中就整批抛，引擎下一轮
    ///    重试，等价于「该 Space 的书签本轮整体停放」。
    /// 2. **按 `batch.ops` 的次序逐条落**。那个次序是 §4.4 的三相拓扑序，
    ///    `BookmarkApplyBatch` 已经排好，这里一条都不重排。
    /// 3. **连续的 create 攒成一次批量插入**。`insertBookmarksBulkBody` 把 index 预先
    ///    算好、只在末尾对每个被触及的父跑一次 `normalizeIndexes`；逐条插会让 250 条落
    ///    进同一个文件夹变成 250 次 fetch 加 250 次全量重排。相邻的 create 在三相排序里
    ///    本来就是连着的，所以攒批不改变任何一条操作的相对次序。
    func apply(_ batch: BookmarkApplyBatch) async throws {
        let ops = batch.ops
        guard !ops.isEmpty else { return }
        let spaceIds = touchedSpaceIds(ops)
        let store = account.localStorage
        try await store.performBackgroundWriteAndWaitThrowing { context in
            for spaceId in spaceIds where ImportTargetLock.shared.isImporting(into: spaceId) {
                throw LocalStoreWriteError.targetNotWritable
            }

            var pendingCreates: [LocalStore.BulkBookmarkInsert] = []
            func flushCreates() throws {
                guard !pendingCreates.isEmpty else { return }
                try store.insertBookmarksBulkBody(pendingCreates, in: context)
                pendingCreates.removeAll(keepingCapacity: true)
            }

            for op in ops {
                switch op {
                case .create(let row):
                    pendingCreates.append(Self.bulkInsert(from: row))
                case .claim(let guid, let syncId):
                    try flushCreates()
                    try store.claimBookmarkSyncIdBody(guid: guid, syncId: syncId, in: context)
                case .move(let guid, let parentGuid, let spaceId, let index):
                    try flushCreates()
                    try store.moveBookmarkLandingBody(guid: guid,
                                                      toParentGuid: parentGuid,
                                                      inSpaceId: spaceId,
                                                      index: index,
                                                      in: context)
                case .update(let guid, let fields):
                    try flushCreates()
                    // 外层「改不改」，内层「改成什么」。`title` 的内层 nil 是「清空」——
                    // 远端真的可以有一条空标题的书签，所以 `allowsEmptyTitle` 显式传
                    // `true`（§4.9 第 1 条：默认值会变，同步层每次都自己写出来）。
                    // `url` 的内层 nil 是「不动」：一条书签丢不掉它的 URL。
                    try store.updateBookmarkLandingBody(
                        guid: guid,
                        title: fields.title.map { $0 ?? "" },
                        url: fields.url.flatMap { $0?.absoluteString },
                        secondaryUrl: fields.secondaryUrl.map { $0?.absoluteString },
                        secondaryTitle: fields.secondaryTitle,
                        allowsEmptyTitle: true,
                        in: context)
                case .delete(let guid):
                    try flushCreates()
                    try store.deleteBookmarkLandingBody(guid: guid, in: context)
                }
            }
            try flushCreates()
        }
        // 落地改了行，本轮那份快照已经过期：下一个读者重建，而不是读着旧值往下算。
        invalidateCache()
    }

    /// 一次批量写（§9.2）。逐条一个事务在一棵上千条的树上是上千个事务。
    func clearAllSyncIds() async throws {
        let store = account.localStorage
        _ = try await store.performBackgroundWriteAndWaitThrowing { context in
            try store.clearAllBookmarkSyncIdsBody(in: context)
        }
        invalidateCache()
    }

    // MARK: - 私有

    /// 本批次碰到的全部 Space。导入锁按 Space 判，而 `claim` / `update` / `delete` 三种
    /// 操作身上只有 guid，所以它们的 Space 从本轮快照里查——那份缓存正是引擎建批次时读
    /// 的同一份。
    private func touchedSpaceIds(_ ops: [BookmarkApplyOp]) -> Set<String> {
        ensureCache()
        var out = Set<String>()
        for op in ops {
            switch op {
            case .create(let row): out.insert(row.spaceId)
            case .move(_, _, let spaceId, _): out.insert(spaceId)
            case .claim(let guid, _), .update(let guid, _), .delete(let guid):
                if let spaceId = cachedSpaceIdByGuid[guid] { out.insert(spaceId) }
            }
        }
        return out
    }

    private static func bulkInsert(from row: PhiLocalBookmark) -> LocalStore.BulkBookmarkInsert {
        LocalStore.BulkBookmarkInsert(guid: row.guid,
                                      syncId: row.syncId,
                                      title: row.title,
                                      url: row.url,
                                      index: row.index,
                                      isFolder: row.isFolder,
                                      parentGuid: row.parentGuid,
                                      spaceId: row.spaceId,
                                      profileId: row.profileId,
                                      createdDate: row.createdDate,
                                      contentUpdatedDate: row.contentUpdatedDate,
                                      secondaryUrl: row.secondaryUrl,
                                      secondaryTitle: row.secondaryTitle,
                                      source: row.source)
    }

    private func ensureCache() {
        guard !hasCache else { return }
        rebuildCache()
    }

    private func invalidateCache() {
        hasCache = false
    }

    /// **失败不落成一份空快照**：读不出来的时候既不清掉上一轮那份、也不把缓存标成有效，
    /// 下一个读者重试。一份假的空快照在差分那边的含义是「本机这些行全没了」，而差分对
    /// 「没了」的反应是给每一条发 tombstone（§4.7）——一次 fetch 失败会删掉账户上整棵树。
    ///
    /// 这挡不住**进程起来后第一轮就读失败**那一种：那时没有上一轮可留，返回的仍是空数组，
    /// 而游标表是跨启动持久化的。协议签名是非抛出的（`allBookmarks() -> [PhiLocalBookmark]`），
    /// 这一层表达不了「读失败」与「真的没有书签」的区别，所以那道闸必须由引擎侧来把
    /// （Task 6）。
    private func rebuildCache() {
        let store = account.localStorage
        guard let context = store.getMainContext() else {
            AppLogError("[PhiSync] bookmark snapshot skipped: no main context")
            return
        }
        let models: [TabDataModel]
        let roots: Set<String>
        do {
            models = try store.allBookmarkModels(in: context)
            roots = try store.canonicalRootGuids(in: context)
        } catch {
            // R12：只记类型与 domain/code，不记任何行内容。
            AppLogError("[PhiSync] bookmark snapshot fetch failed: \(PhiSyncLog.describe(error))")
            return
        }

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
        var spaceIdByGuid: [String: String] = [:]
        for row in rows {
            siblings[SiblingKey(spaceId: row.spaceId, parentGuid: row.parentGuid),
                     default: []].append(row)
            isFolder[row.guid] = row.isFolder
            spaceIdByGuid[row.guid] = row.spaceId
        }
        cachedRows = rows
        cachedSiblings = siblings
        cachedIsFolder = isFolder
        cachedSpaceIdByGuid = spaceIdByGuid
        hasCache = true
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

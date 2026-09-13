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
/// 生产实现见 Task 5a；本文件只有声明。
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

    /// 这个 Space 正在导入。导入期间的行不发布（`ImportTargetLock`）。
    func isImporting(intoSpaceId spaceId: String) -> Bool

    /// 一整轮远端落地，一个事务（§4.5）。抛错 = 一条都没落，调用方不许写基线。
    func apply(_ batch: BookmarkApplyBatch) async throws

    /// 退出账户 / 重置同步状态时抹掉全部 `syncId`（§9.2）。
    func clearAllSyncIds() async throws
}

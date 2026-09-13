// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// 一条本机 pin 在同步层眼里的取值快照。与 `PhiLocalBookmark` 同款：不依赖
/// `LocalStorage`。
struct PhiLocalPin: Equatable, Sendable {
    /// 已归一（小写）的 `pinLineageId`。**不是**身份的全部——身份是
    /// `(lineageId, owner)` 这一对（R-M3-3-15），一条 lineage 在 N 个 Space 里就是 N 条
    /// 实体。
    var lineageId: String
    /// 本机物理行的 id。落地的每一个操作都按它定位。
    var guid: String
    /// Space 作用域下非 nil。
    var spaceId: String?
    /// Profile 作用域下非 nil；**App 作用域下 `spaceId` 与 `profileId` 都为 nil**。
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
/// 生产实现见 Task 5b；本文件只有声明。
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
    func allPins() -> [PhiLocalPin]

    /// 本机还有没有这条 lineage。理由同 `isKnownLocalBookmark`。
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

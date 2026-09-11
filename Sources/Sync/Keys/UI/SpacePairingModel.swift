// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// 配对向导第 2 步的纯决定核（§5.4），逐条对照 `ProfilePairingModel`：**无 SwiftUI、
/// 无文案、无单例**。
///
/// 移植过来的三条不变量：
/// 1. **每个本地 Space 至多一个决定** —— `selections` 就是按 `localSpaceId` 键的
///    字典，结构上成立；
/// 2. **一个账户 Space 至多被一行认领** —— `assignableAccountSpaces(for:)` 排除掉
///    **更靠前的行**已认领的 uuid（同选时靠前的行赢，靠后的行读回未决定）。这一条在
///    Space 侧比 Profile 侧更要紧：Profile 侧「两个本地映射到同一个 uuid」只是 bug，
///    Space 侧**用户点两下就能造出来**，所以必须在模型里结构性禁止，而
///    `SpaceSyncMappingManager.map` 的 `.syncUuidAlreadyClaimed` 是第二道闸；
/// 3. **过期的选择读回「未决定」** —— `assignment(for:)` 发现存的 `.existing(u)` 已
///    经不在可选列表里就返回 nil，于是 `allRowsDecided` 不会把一个显示为空白的行算作
///    已决定。
struct SpacePairingModel {
    struct Input: Equatable {
        /// 本机**可配对**的 Space：`PhiSpaceLocalAccess.pairableSpaces()`（§3.4 末），
        /// 只应用 incognito + 两种 agent 特征的排除，**不**应用「该 Space 的 profile
        /// 已有映射」判据。含默认 Space。
        ///
        /// 用 `currentSpaces()` 取这一列是**错的**：第 1 步的 Profile 决定要到 Finish
        /// 才应用，向导开着的时候正在被配对的那些 profile 按定义还没有映射，于是它们
        /// 下面的 Space 会被整体藏掉，左列只剩那条只读的默认行。
        let locals: [PhiLocalSpace]
        /// 预览拉回的账户 Space（**不含默认 Space** —— 它由 D1 处理，绝不可选）。
        let accountSpaces: [PhiAccountSpaceSummary]
        /// 本地 profileId -> 显示名。
        let localProfileNames: [String: String]
        /// 账户 profile uuid -> 显示名（§5.2 的三级取名在 view model 里做完）。
        let accountProfileNames: [String: String]
    }

    enum Assignment: Hashable {
        case existing(syncUuid: String)
        case addAsNew
    }

    let input: Input
    /// localSpaceId -> Assignment
    let selections: [String: Assignment]

    /// 需要用户决定的行：本机**非默认** Space。
    var rows: [PhiLocalSpace] {
        input.locals.filter { $0.spaceId != LocalStore.defaultSpaceId }
    }

    /// 默认 Space 单独渲染成一条**只读**行：没有下拉、不计入 `allRowsDecided`、不产出
    /// 决定。D1 说了它的身份是常量，这一行只是把这件事说给用户听。
    var defaultRow: PhiLocalSpace? {
        input.locals.first { $0.spaceId == LocalStore.defaultSpaceId }
    }

    func assignment(for local: PhiLocalSpace) -> Assignment? {
        guard let stored = selections[local.spaceId] else { return nil }
        if case .existing(let uuid) = stored,
           !assignableAccountSpaces(for: local).contains(where: { $0.syncUuid == uuid }) {
            return nil
        }
        return stored
    }

    /// 自己那条永远留在自己的列表里，否则 Picker 的 selected tag 缺失会渲染成空白——
    /// **除非**更靠前的一行已经认领了它：同一个 uuid 被两行选中时，`rows` 里靠前的那行
    /// 赢，靠后的那行读回「未决定」。没有这条 tiebreak，「自己那条留在自己列表里」会把
    /// 同一个账户 Space 同时救给两行，invariant 2 就只剩 `SpaceSyncMappingManager.map`
    /// 的 `.syncUuidAlreadyClaimed` 一道闸。
    ///
    /// 两点副作用，写在这里免得后来的读者「修正」掉：
    /// 1. 循环走的是 `rows`（非默认行），所以存在 `LocalStore.defaultSpaceId` 名下的
    ///    陈旧 `.existing` 不再认领任何东西——默认行是只读的、不产出决定，本就该如此；
    /// 2. tiebreak 依赖 `input.locals` 的顺序，所以重绘之间这个顺序必须稳定。
    func assignableAccountSpaces(for local: PhiLocalSpace) -> [PhiAccountSpaceSummary] {
        let own: String? = {
            if case .existing(let uuid) = selections[local.spaceId] { return uuid }
            return nil
        }()
        var claimedByOthers: Set<String> = []
        var claimedByEarlierRows: Set<String> = []
        var seenSelf = false
        for row in rows {
            if row.spaceId == local.spaceId { seenSelf = true; continue }
            guard case .existing(let uuid) = selections[row.spaceId] else { continue }
            claimedByOthers.insert(uuid)
            if !seenSelf { claimedByEarlierRows.insert(uuid) }
        }
        return input.accountSpaces.filter { summary in
            guard !claimedByEarlierRows.contains(summary.syncUuid) else { return false }
            return summary.syncUuid == own || !claimedByOthers.contains(summary.syncUuid)
        }
    }

    /// 没有被任何一行认领的账户 Space。它们会在门开后的第一次 drain 里自动落地
    /// （新本地行 + 写映射，R-D6-7）——第 2 步的说明文案要把这件事讲清楚。
    ///
    /// 判据取自 `decisions()` 而不是整本 `selections`：被读回「未决定」的行（过期的
    /// uuid、靠后的重复认领）、以及存在 `LocalStore.defaultSpaceId` 名下的陈旧选择，
    /// 都**没有**认领任何东西，否则这里会比实际少报一条。
    var unassignedAccountSpaces: [PhiAccountSpaceSummary] {
        let claimed = Set(decisions().compactMap { decision -> String? in
            if case .existing(let uuid) = decision.assignment { return uuid }
            return nil
        })
        return input.accountSpaces.filter { !claimed.contains($0.syncUuid) }
    }

    var allRowsDecided: Bool {
        rows.allSatisfy { assignment(for: $0) != nil }
    }

    /// 把**尚未决定**的行全部置 `.addAsNew`，已决定的行**不动**（它是快捷方式，不是
    /// 重置）。
    func addAllAsNew() -> [String: Assignment] {
        var out = selections
        for row in rows where assignment(for: row) == nil {
            out[row.spaceId] = .addAsNew
        }
        return out
    }

    func decisions() -> [(localSpaceId: String, assignment: Assignment)] {
        rows.compactMap { row in
            guard let assignment = assignment(for: row) else { return nil }
            return (localSpaceId: row.spaceId, assignment: assignment)
        }
    }

    /// 「所属 Profile」标签。`nil` = 解析不出来——**视图**负责把它渲染成本地化的
    /// `—`（纯逻辑层不带文案），而且它**不影响任何判据**：这一行照样可以被选中。
    func profileName(for local: PhiLocalSpace) -> String? {
        input.localProfileNames[local.profileId]
    }

    func profileName(for summary: PhiAccountSpaceSummary) -> String? {
        input.accountProfileNames[summary.profileUuid]
    }
}

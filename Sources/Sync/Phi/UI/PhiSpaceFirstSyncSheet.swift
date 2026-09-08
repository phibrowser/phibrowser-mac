// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI

/// D2 (§8): the one question a joining Mac asks before any of its own Spaces
/// reaches the account.
///
/// Presented from `.phiSpaceFirstSyncNeeded`, whose userInfo carries exactly the
/// two values this view needs (`localNames: [String]`, `accountCount: Int`); the
/// answer goes back through `PhiSyncEngine.submitFirstSyncDecision(_:)`.
///
/// **There is no cancel button on purpose.** Nothing this Mac owns is published
/// until the table records a decision, so "close it and decide later" is already
/// the state the sheet is presented in — an explicit Cancel would only offer a
/// third outcome the engine has no case for. The Space names are listed one by
/// one rather than counted: "3 个 Space 会加入账户" is not something a user can
/// check, and the default Space merge below it is irreversible.
///
/// Purely presentational: it holds no engine reference and performs no I/O.
struct PhiSpaceFirstSyncSheet: View {
    /// The Spaces that exist only on this Mac, in the engine's order.
    let localNames: [String]
    /// How many Spaces the account already holds, the default Space excluded —
    /// it is the one being merged, not another Space to choose between.
    let accountCount: Int
    let onDecide: (PhiSpaceFirstSyncDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(NSLocalizedString("把这台 Mac 的 Space 并入账户？",
                                   comment: "Space first sync - sheet title"))
                .font(.title2.bold())
                .themedForeground(.textPrimaryStrong)

            VStack(alignment: .leading, spacing: 8) {
                Text(localNamesLine)
                Text(accountCountLine)
            }
            .font(.body)
            .themedForeground(.textPrimary)
            .fixedSize(horizontal: false, vertical: true)

            Text(defaultSpaceMergeLine)
                .font(.body)
                .themedForeground(.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            option(title: NSLocalizedString("保留两边",
                                            comment: "Space first sync - keep both button"),
                   isDefault: true,
                   body: keepBothLine) { onDecide(.keepBoth) }

            option(title: NSLocalizedString("以账户为准",
                                            comment: "Space first sync - account wins button"),
                   isDefault: false,
                   body: accountWinsLine) { onDecide(.accountWins) }
        }
        .padding(32)
        .frame(width: 460, alignment: .leading)
    }

    // MARK: - Rows

    @ViewBuilder
    private func option(title: String,
                        isDefault: Bool,
                        body: AttributedString,
                        action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if isDefault {
                    Button(title, action: action).buttonStyle(.borderedProminent)
                } else {
                    Button(title, action: action).buttonStyle(.bordered)
                }
                if isDefault {
                    Text(NSLocalizedString("默认", comment: "Space first sync - default choice tag"))
                        .font(.system(size: 11))
                        .themedForeground(.textSecondary)
                }
            }
            Text(body)
                .font(.system(size: 12))
                .themedForeground(.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Copy
    //
    // Composed as `AttributedString` fragments rather than parsed from Markdown:
    // a Space name is user text and would otherwise have to be escaped against
    // `*`, `_` and `[` before it could be interpolated into a Markdown string.

    private var localNamesLine: AttributedString {
        var out = AttributedString(String(
            format: NSLocalizedString("这台 Mac 上有 %d 个 Space 还没有加入账户：",
                                      comment: "Space first sync - local-only Spaces, followed by their names"),
            localNames.count))
        for (index, name) in localNames.enumerated() {
            if index > 0 {
                out += AttributedString(NSLocalizedString(
                    "、", comment: "Space first sync - separator between Space names"))
            }
            out += bold(name)
        }
        out += AttributedString(NSLocalizedString(
            "。", comment: "Space first sync - full stop after the Space name list"))
        return out
    }

    private var accountCountLine: AttributedString {
        AttributedString(String(
            format: NSLocalizedString("你的账户里已经有 %d 个 Space。",
                                      comment: "Space first sync - how many Spaces the account holds"),
            accountCount))
    }

    private var defaultSpaceMergeLine: AttributedString {
        AttributedString(NSLocalizedString(
            "两台设备的",
            comment: "Space first sync - default Space merge warning, part 1"))
        + bold(NSLocalizedString(
            "默认 Space 会合并",
            comment: "Space first sync - default Space merge warning, emphasized part 2"))
        + AttributedString(NSLocalizedString(
            "为账户里的同一个 Space：这台 Mac 默认 Space 的名称、图标、颜色会被账户里的值覆盖，",
            comment: "Space first sync - default Space merge warning, part 3"))
        + bold(NSLocalizedString(
            "且无法撤销",
            comment: "Space first sync - default Space merge warning, emphasized part 4"))
        + AttributedString(NSLocalizedString(
            "。", comment: "Space first sync - full stop after the merge warning"))
    }

    private var keepBothLine: AttributedString {
        AttributedString(String(
            format: NSLocalizedString("这 %d 个 Space 会加入账户，出现在你的所有设备上。",
                                      comment: "Space first sync - what keeping both does"),
            localNames.count))
    }

    private var accountWinsLine: AttributedString {
        AttributedString(String(
            format: NSLocalizedString("这 %d 个 Space 不会加入账户。它们会从这台 Mac 的 Space 列表里隐藏，",
                                      comment: "Space first sync - what account-wins does, part 1"),
            localNames.count))
        + bold(NSLocalizedString(
            "数据完整保留在本机",
            comment: "Space first sync - what account-wins does, emphasized part 2"))
        + AttributedString(NSLocalizedString(
            "（书签、Pin Tab、URL 规则、主题一个都不删），之后可以在「设置 → Spaces → 未同步到账户」里重新加入或删除。",
            comment: "Space first sync - what account-wins does, part 3"))
    }

    private func bold(_ text: String) -> AttributedString {
        var piece = AttributedString(text)
        piece.inlinePresentationIntent = .stronglyEmphasized
        return piece
    }
}

#if DEBUG
#Preview("Space first sync") {
    PhiSpaceFirstSyncSheet(localNames: ["Work", "Reading", "客户"],
                           accountCount: 4) { _ in }
}
#endif

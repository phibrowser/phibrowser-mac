// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI

/// 第 2 步的两列表（§6.4）。两列的行必须**逐行对齐**，所以结构是「一行 = 左半 +
/// 右半」而不是两个独立的列。
///
/// **这个 view 不持有任何 `@State`**：第 2 步的选择活在 `PairingWizardViewModel` 上，
/// 因为页脚要读 `allRowsDecided`、Back 要保住它们、`.error` → Retry 之后要原样回到
/// 这一步（§5.2）。
struct SpacePairingStepView: View {
    @ObservedObject var viewModel: PairingWizardViewModel
    let model: SpacePairingModel

    /// 解析不出名字时上屏的那一条。纯逻辑层交出 nil，本地化在这里。
    static let unresolvedName = NSLocalizedString(
        "—", comment: "Pairing wizard - a name that can’t be resolved (an unmapped profile, or an empty Space name on the confirmation page)")

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(NSLocalizedString("Match your Spaces", comment: "Pairing wizard - step 2 title"))
                .font(.title2.bold())
                .themedForeground(.textPrimaryStrong)
            Text(NSLocalizedString(
                "Pick the account Space each Space on this Mac belongs to, or add it to your account as a new Space. Spaces in your account that aren’t on this Mac are added here automatically. Nothing on this Mac is deleted.",
                comment: "Pairing wizard - step 2 explanation"))
                .font(.body)
                .themedForeground(.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 16) {
                Text(NSLocalizedString("This Mac", comment: "Pairing wizard - local column header"))
                    .font(.headline)
                    .themedForeground(.textPrimaryStrong)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(NSLocalizedString("Account", comment: "Pairing wizard - account column header"))
                    .font(.headline)
                    .themedForeground(.textPrimaryStrong)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(spacing: 0) {
                ForEach(Array(model.rows.enumerated()), id: \.element.spaceId) { index, local in
                    if index > 0 { SettingsRowDivider() }
                    row(local)
                }
                if let defaultRow = model.defaultRow {
                    if !model.rows.isEmpty { SettingsRowDivider() }
                    defaultSpaceRow(defaultRow)
                }
            }
            .padding(.horizontal, 12)
            .settingsCardChrome()
        }
    }

    private func row(_ local: PhiLocalSpace) -> some View {
        HStack(alignment: .top, spacing: 16) {
            localCell(local)
            accountCell(local)
        }
        .padding(.vertical, 10)
    }

    private func localCell(_ local: PhiLocalSpace) -> some View {
        let profile = model.profileName(for: local) ?? Self.unresolvedName
        return HStack(spacing: 8) {
            SpaceIconView(storedValue: local.iconName, size: 16,
                          symbolWeight: .regular, tint: Color.primary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(local.name).font(.body).themedForeground(.textPrimary)
                Text(profile).font(.caption).themedForeground(.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(
            format: NSLocalizedString("Space “%1$@” on this Mac, in profile %2$@",
                                      comment: "Pairing wizard - accessibility label for a local Space row"),
            local.name, profile))
    }

    private func accountCell(_ local: PhiLocalSpace) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Picker("", selection: binding(for: local)) {
                    Text(NSLocalizedString("Choose…", comment: "Profiles settings - download location not set"))
                        .tag(SpacePairingModel.Assignment?.none)
                    ForEach(model.assignableAccountSpaces(for: local), id: \.syncUuid) { summary in
                        Label {
                            Text(String(
                                format: NSLocalizedString("%1$@ (%2$@)",
                                                          comment: "Pairing wizard - an account Space named %1$@ in profile %2$@"),
                                summary.name, model.profileName(for: summary) ?? Self.unresolvedName))
                        } icon: {
                            // 图标与左列同一个组件：第 2 步的全部意思就是「这台 Mac
                            // 的 Work 就是账户里的 Work」，图标是最快的那条视觉线索。
                            SpaceIconView(storedValue: summary.iconName, size: 14,
                                          symbolWeight: .regular, tint: Color.primary)
                        }
                        .tag(SpacePairingModel.Assignment?.some(.existing(syncUuid: summary.syncUuid)))
                    }
                    Text(NSLocalizedString("Add as new",
                                           comment: "Pairing wizard - add this Space to the account as a new one"))
                        .tag(SpacePairingModel.Assignment?.some(.addAsNew))
                }
                .labelsHidden()
                .accessibilityLabel(String(
                    format: NSLocalizedString("Account Space for “%@”",
                                              comment: "Pairing wizard - accessibility label for the assignment picker"),
                    local.name))
                if model.assignment(for: local) != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .themedForeground(.textSecondary)
                        .accessibilityHidden(true)   // 信息已经在 Picker 的值里
                }
            }
            if model.assignment(for: local) == nil {
                Text(NSLocalizedString("Not assigned yet",
                                       comment: "Pairing wizard - account column placeholder for an undecided row"))
                    .font(.caption)
                    .themedForeground(.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 默认 Space 是一条**只读**行：右列固定文本，没有下拉、不计入 `allRowsDecided`、
    /// 不产出决定。D1 说了它的身份是常量，这一行只是把这件事说给用户听。
    private func defaultSpaceRow(_ local: PhiLocalSpace) -> some View {
        HStack(alignment: .top, spacing: 16) {
            HStack(spacing: 8) {
                SpaceIconView(storedValue: local.iconName, size: 16,
                              symbolWeight: .regular, tint: Color.primary)
                    .accessibilityHidden(true)
                Text(local.name).font(.body).themedForeground(.textPrimary)
                SettingsDefaultBadge()
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(NSLocalizedString("Already in your account",
                                   comment: "Pairing wizard - default Space row, account side"))
                .font(.body)
                .themedForeground(.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(
            format: NSLocalizedString("Space “%@” is the default Space and is already in your account",
                                      comment: "Pairing wizard - accessibility label for the default Space row"),
            local.name))
    }

    /// 读经 `model.assignment(for:)`，所以一个过期的选择显示成 "Choose…" 而不是空白
    /// Picker（与 `ProfilePairingView.remoteChoiceBinding` 同款理由）。
    private func binding(for local: PhiLocalSpace) -> Binding<SpacePairingModel.Assignment?> {
        Binding(get: { model.assignment(for: local) },
                set: { viewModel.assign($0, to: local.spaceId) })
    }
}

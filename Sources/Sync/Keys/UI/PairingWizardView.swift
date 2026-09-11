// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SwiftUI

/// 配对向导的模态根视图（§6）：步骤条 / content / 固定页脚 / 状态页 / D7 的覆盖确认页
/// / self-revoke 出口。
///
/// **确认页不另开文件**：它和加载 / 出错 / 提交中一样是容器自己的一页（同一个页脚、
/// 同一个 self-revoke 出口、同一份 chrome），拆出去只会让这个 view 再持一份页脚状态。
/// 它渲染的东西全部来自 `SpaceOverwriteDiff`，逻辑一行都不在这里。
struct PairingWizardView: View {
    @StateObject private var viewModel: PairingWizardViewModel
    let controller: SyncKeyController
    let onDismiss: () -> Void

    /// 非 nil 之后这个按钮就地置灰：这个账户的最后一台活跃设备。**为窗口的一生保持
    /// 粘性**——用户在这个模态里做不了任何事来增加第二台设备（原样搬自
    /// `ProfilePairingGateView`）。
    @State private var removeBlockedNote: String?
    /// 同一个按钮的瞬时失败（离线、5xx、Keychain）。同一个槽位显示，但**不置灰**：
    /// 重试就是修复。每次尝试开始时清掉。
    @State private var removeErrorNote: String?

    init(viewModel: PairingWizardViewModel, controller: SyncKeyController,
         onDismiss: @escaping () -> Void) {
        // 宿主建 VM、这里持有它：`weak var viewModel` 在宿主上的生命周期论证因此逐字
        // 成立——VM 活在 `window` 持有的 hosting controller 里。
        self._viewModel = StateObject(wrappedValue: viewModel)
        self.controller = controller
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(spacing: 0) {
            PairingStepBar(step: viewModel.step)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            footer
        }
        .frame(minWidth: 720, minHeight: 560)
        .themedBackground(PhiPreferences.fixedWindowBackground)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .loading:
            statusPage(message: NSLocalizedString("Loading your account…",
                                                  comment: "Pairing wizard - loading page"),
                       showsProgress: true)
        case .profiles(let locals, let remotes):
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 20) {
                    Text(NSLocalizedString("Match your profiles", comment: "Profile pairing - title"))
                        .font(.title2.bold())
                        .themedForeground(.textPrimaryStrong)
                    Text(NSLocalizedString(
                        "Phi needs one account profile for every profile on this Mac before it can sync Spaces and bookmarks to the right place. The browser stays unavailable until this is done.",
                        comment: "Pairing wizard - step 1 explanation"))
                        .font(.body)
                        .themedForeground(.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    // `.gate` 上下文只渲染行列表：标题 / 正文 / 主按钮归向导 chrome。
                    ProfilePairingView(viewModel: viewModel.keyLayer,
                                       locals: locals, remotes: remotes,
                                       selections: $viewModel.profileSelections,
                                       remoteChoices: $viewModel.profileRemoteChoices,
                                       context: .gate,
                                       onSubmit: { _ in })
                }
                .padding(24)
            }
        case .spaces(let input):
            ScrollView(.vertical) {
                SpacePairingStepView(
                    viewModel: viewModel,
                    model: SpacePairingModel(input: input, selections: viewModel.spaceSelections))
                    .padding(24)
            }
        case .confirmOverwrite(let items):
            confirmationPage(items)
        case .submitting:
            statusPage(message: NSLocalizedString("Applying your choices…",
                                                  comment: "Pairing wizard - submitting page"),
                       showsProgress: true)
        case .done:
            statusPage(message: nil, showsProgress: true)
        case .error(let message, _):
            statusPage(message: message, showsProgress: false)
        }
    }

    private func statusPage(message: String?, showsProgress: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if let message {
                Text(message).font(.body).themedForeground(.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showsProgress { ProgressView() }
        }
        .padding(24)
    }

    // MARK: - D7 的覆盖确认页（§6.9）

    private func confirmationPage(_ items: [SpaceOverwriteDiff]) -> some View {
        // 空页不可达：无差异时 Finish 根本不进这个 phase（§5.5）。断言仍然写出来，
        // 因为一旦有人把差异计算改成「总是显示」，这一页会退化成一个只有两个按钮的
        // 空白窗口。
        assert(!items.isEmpty)
        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                Text(NSLocalizedString("Review what changes",
                                       comment: "Overwrite confirmation - title"))
                    .font(.title2.bold())
                    .themedForeground(.textPrimaryStrong)
                Text(NSLocalizedString(
                    "These Spaces already exist in your account. When sync starts, the account’s values replace what’s on this Mac. The Space may also move to the profile it has in your account. Your tabs, bookmarks, pinned tabs and URL rules aren’t touched. To keep this Mac’s values instead, go back and add that Space as a new one.",
                    comment: "Overwrite confirmation - explanation"))
                    .font(.body)
                    .themedForeground(.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(items) { item in section(item) }
            }
            .padding(24)
        }
    }

    private func section(_ item: SpaceOverwriteDiff) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                SpaceIconView(storedValue: item.spaceIconName, size: 16,
                              symbolWeight: .regular, tint: Color.primary)
                    .accessibilityHidden(true)
                Text(item.spaceName).font(.headline).themedForeground(.textPrimaryStrong)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 10)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(
                format: NSLocalizedString("Changes to Space “%@”",
                                          comment: "Overwrite confirmation - accessibility label for one Space's section"),
                item.spaceName))
            ForEach(Array(item.changes.enumerated()), id: \.offset) { _, change in
                SettingsRowDivider()
                changeRow(change)
            }
        }
        .padding(.horizontal, 12)
        .settingsCardChrome()
    }

    private func changeRow(_ change: SpaceOverwriteDiff.Change) -> some View {
        // 任一侧的图标落到兜底字形时，两侧都补一段 storedValue 原文——`SpaceIconView`
        // 对**空**的与**解析不出**的 storedValue 画的是同一个 `rectangle.stack`，所以
        // `Icon: [stack] → [stack]` 是可达的。
        let showsRaw = needsRawIconText(change)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            // 字段名**宽度不对齐**：它是本地化串，德语能长出一倍，硬对齐要么截断
            // 要么把值挤出屏幕。
            Text(Self.fieldLabel(change.field))
                .font(.callout)
                .themedForeground(.textSecondary)
            value(change.local, field: change.field, showsRawIconText: showsRaw)
            Text(verbatim: "→").themedForeground(.textTertiary)
            value(change.account, field: change.field, showsRawIconText: showsRaw)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        // 整行作为一个元素，否则 VoiceOver 会把那个 `→` 单独念一遍。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(
            format: NSLocalizedString("%1$@ changes from %2$@ to %3$@",
                                      comment: "Overwrite confirmation - accessibility label for one changed field"),
            Self.fieldLabel(change.field), Self.spoken(change.local), Self.spoken(change.account)))
    }

    @ViewBuilder
    private func value(_ value: SpaceOverwriteDiff.Value,
                       field: SpaceOverwriteDiff.Field,
                       showsRawIconText: Bool) -> some View {
        switch value {
        case .text(let text):
            HStack(spacing: 6) {
                if field == .color, let swatch = Self.swatch(text) {
                    // 唯一一处由 hex 解析出来的颜色（它渲染的就是那个 hex 本身，不是
                    // 主题色）；解析不出就只留文本，不画空圆点。
                    Circle().fill(swatch).frame(width: 10, height: 10)
                }
                Text(text.isEmpty ? SpacePairingStepView.unresolvedName : text)
                    .font(.body)
                    .themedForeground(.textPrimary)
            }
        case .icon(let storedValue):
            HStack(spacing: 6) {
                SpaceIconView(storedValue: storedValue, size: 16,
                              symbolWeight: .regular, tint: Color.primary)
                if showsRawIconText {
                    Text(storedValue.isEmpty ? SpacePairingStepView.unresolvedName : storedValue)
                        .font(.caption)
                        .themedForeground(.textTertiary)
                }
            }
        case .defaultValue:
            Text(Self.noCustomValue).font(.body).themedForeground(.textPrimary)
        case .percent(let milliUnits):
            Text(Self.percentText(milliUnits)).font(.body).themedForeground(.textPrimary)
        }
    }

    /// `Default` 这条 key **不复用**：SettingsSectionCard 的 `Default` 是「默认
    /// Space / Profile」的**徽章**，而 §6.4 的默认 Space 行**在同一个窗口里**正用着
    /// 它；确认页要说的却是「这一侧没有自己的值」。同一扇窗上两个词会互相冲突。
    private static let noCustomValue = NSLocalizedString(
        "No custom value",
        comment: "Overwrite confirmation - a field with no value of its own (no theme pinned, no custom opacity); the app theme's own value is used instead")

    /// 六条字段标签，**一张 switch 同时供无障碍标签使用，不写第二份**。
    ///
    /// `Name` / `Icon` / `Color` / `Theme` 四条都是目录里**既有**的 key，所以它们照抄
    /// 树上那一条 comment（§6.8 的复用规则：同一个 key 的两份 comment 会在重新生成时
    /// 被拼成多行）。
    private static func fieldLabel(_ field: SpaceOverwriteDiff.Field) -> String {
        switch field {
        case .name: return NSLocalizedString("Name", comment: "Editor - Label for the title/name input field")
        case .icon: return NSLocalizedString("Icon", comment: "Spaces settings - icon section header")
        case .color: return NSLocalizedString("Color", comment: "General settings - Theme color row title")
        case .theme: return NSLocalizedString("Theme", comment: "General settings - Theme section title")
        case .opacityLight:
            return NSLocalizedString("Light overlay opacity",
                                     comment: "Overwrite confirmation - the light-appearance overlay opacity field")
        case .opacityDark:
            return NSLocalizedString("Dark overlay opacity",
                                     comment: "Overwrite confirmation - the dark-appearance overlay opacity field")
        }
    }

    /// **必须能表达千分单位的差别**：遮罩透明度的滑杆是连续的（`isContinuous = true`、
    /// 无 tickMarks、线性映射、写入不取整），千分单位常态上不是 10 的倍数，一律
    /// `%1$d%%` 会把两个**确实会被覆盖**的值渲染成同一个词。
    private static func percentText(_ milliUnits: Int64) -> String {
        if milliUnits % 10 == 0 {
            return String(format: NSLocalizedString("%1$d%%",
                                                    comment: "Overwrite confirmation - an overlay opacity as a whole percentage"),
                          Int(milliUnits / 10))
        }
        return String(format: NSLocalizedString("%1$.1f%%",
                                                comment: "Overwrite confirmation - an overlay opacity as a percentage with one decimal"),
                      Double(milliUnits) / 10)
    }

    /// 无障碍读的字符串。图标退回 storedValue 原文——§5.7 说过图标没有显示名目录，
    /// 这是唯一能说出口的字符串。
    private static func spoken(_ value: SpaceOverwriteDiff.Value) -> String {
        switch value {
        case .text(let text): return text.isEmpty ? SpacePairingStepView.unresolvedName : text
        case .icon(let storedValue):
            return storedValue.isEmpty ? SpacePairingStepView.unresolvedName : storedValue
        case .defaultValue: return noCustomValue
        case .percent(let milliUnits): return percentText(milliUnits)
        }
    }

    private func needsRawIconText(_ change: SpaceOverwriteDiff.Change) -> Bool {
        guard case .icon(let local) = change.local, case .icon(let account) = change.account else {
            return false
        }
        return !Self.iconResolves(local) || !Self.iconResolves(account)
    }

    private static func iconResolves(_ storedValue: String) -> Bool {
        guard !storedValue.isEmpty else { return false }
        if IconPickerSelection.fromStorageValue(storedValue) != nil { return true }
        return NSImage(systemSymbolName: storedValue, accessibilityDescription: nil) != nil
    }

    /// `Color(hexString:)`（ThirdParty/DynamicColor）不是 failable，一个无效串会画出
    /// 一个说不清的颜色，所以先自己验一遍。
    private static func swatch(_ hex: String) -> Color? {
        let body = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard body.count == 6 || body.count == 8, body.allSatisfy(\.isHexDigit) else { return nil }
        return Color(hexString: hex)
    }

    // MARK: - 页脚（§6.5）

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                if case .spaces = viewModel.phase, hasUndecidedRows {
                    Button(NSLocalizedString("Add all as new",
                                             comment: "Pairing wizard - assign every undecided Space to \"Add as new\"")) {
                        viewModel.addAllAsNew()
                    }
                    .buttonStyle(.bordered)
                }
                Spacer(minLength: 0)
                actions
            }
            // App 级模态的**唯一另一个出口**：每一页都带着它，确认页也不例外。
            Button(NSLocalizedString("Remove this device from sync…",
                                     comment: "Pairing wizard - self-revoke exit")) {
                confirmAndRemoveThisDevice()
            }
            .buttonStyle(.bordered)
            .disabled(removeBlockedNote != nil)
            if let note = removeBlockedNote ?? removeErrorNote {
                Text(note).font(.callout).themedForeground(.textSecondary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private var hasUndecidedRows: Bool {
        let model = viewModel.spaceModel
        return model.rows.contains { model.assignment(for: $0) == nil }
    }

    @ViewBuilder
    private var actions: some View {
        switch viewModel.phase {
        case .profiles:
            Button(NSLocalizedString("Continue", comment: "Pairing wizard - finish step 1")) {
                viewModel.continueToSpaces()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            // 两个析取项，逐字对应 spec §6.5 钉的那一句（也就是 `ProfilePairingView`
            // 的 `.settings` 主按钮判据今天那一句在向导里的形态）：`allDecided`
            // 之外还有「加载在飞」那一半 = `phase == .loading || phase == .submitting`。
            //
            // **不读 `viewModel.keyLayer.isSubmitting`**：`keyLayer` 是另一个
            // `ObservableObject`，而这个 view 只 `@StateObject` 观察 `viewModel`——
            // 跨对象的 `@Published` 变化不会让这里重画，那个析取项在**任何** phase 里
            // 都是一个死的、还不会刷新的读。用 `phase` 的好处是它就在被观察的对象上。
            .disabled(!viewModel.profileRowsDecided
                      || viewModel.phase == .loading || viewModel.phase == .submitting)
        case .spaces:
            Button(NSLocalizedString("Back",
                                     comment: "Web content header - Accessibility description for back navigation button")) {
                viewModel.backToProfiles()
            }
            .buttonStyle(.bordered)
            Button(NSLocalizedString("Finish", comment: "Onboarding password manager - Finish button")) {
                Task { await viewModel.finish(controller: controller) }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!viewModel.spaceModel.allRowsDecided
                      || viewModel.phase == .loading || viewModel.phase == .submitting)
        case .confirmOverwrite:
            // **两个按钮的角色是反过来的，这是有意的（D7）。** 全向导只有这一页里，
            // 处在「主按钮」位置的动作是破坏性的，所以 `.defaultAction` 给 `Back`：
            // Return 落在**安全**的那一侧。`Apply` 不挂任何 key equivalent，只能点；
            // 它的键盘路径靠 full keyboard access，而声明顺序
            // `Apply → Back → Remove…` 让第一次 Tab 就落在 `Apply` 上。
            // 仍然**不挂 `.cancelAction`**：这是 App 级阻断模态，Esc 必须是死键。
            Button(NSLocalizedString("Apply",
                                     comment: "Overwrite confirmation - apply every decision and start syncing")) {
                Task { await viewModel.applyConfirmedOverwrite(controller: controller) }
            }
            .buttonStyle(.bordered)
            Button(NSLocalizedString("Back",
                                     comment: "Web content header - Accessibility description for back navigation button")) {
                viewModel.backFromConfirmation()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        case .error:
            Button(NSLocalizedString("Retry", comment: "Phi Link - Retry loading official bot")) {
                Task { await viewModel.retry(controller: controller) }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!Self.retryEnabled(for: viewModel.phase,
                                         isSubmitting: viewModel.isApplying))
        case .loading, .submitting, .done:
            EmptyView()
        }
    }

    /// 模态的 retry 按钮是否可按。**它总是可按**，除了一趟提交正在飞的时候——沿用
    /// `ProfilePairingGateView.retryEnabled` 的全部论证（一个卡住的加载必须在任何
    /// phase 里都能重启，而一次落在提交上的 retry 会变成 `phase` 的第二个写者）。
    ///
    /// `isSubmitting` 由调用方传 `viewModel.isApplying`——那是向导 VM **自己**的
    /// `@Published`，不是 `keyLayer.isSubmitting`：后者住在另一个 `ObservableObject`
    /// 上，这个 view 不观察它，读它既不会触发重画，也在 `.error` 出现的那一刻早已被
    /// `applyPairingDecisions` 的 `defer` 清掉了。
    static func retryEnabled(for phase: PairingWizardPhase, isSubmitting: Bool) -> Bool {
        !isSubmitting
    }

    /// 第二次确认，然后是「先退休再清理」的序列。客户端**不**预探账户的设备数
    /// （这个 client 上没有列表端点）：它直接问，被拒就就地置灰（原样搬自
    /// `ProfilePairingGateView.confirmAndRemoveThisDevice`）。
    private func confirmAndRemoveThisDevice() {
        guard SelfRevokeStrings.confirmRemoval() else { return }
        removeErrorNote = nil
        Task { @MainActor in
            do {
                try await controller.removeThisDeviceFromSync()
                onDismiss()
            } catch KeyAPIError.lastActiveDevice {
                removeBlockedNote = SelfRevokeStrings.lastDeviceNote
            } catch {
                // R12：错误只进日志，界面上是那条固定文案。
                AppLogWarn("[phi-sync] self-revoke failed (\(PhiSyncLog.describe(error)))")
                removeErrorNote = SelfRevokeStrings.removalUnavailable
            }
        }
    }
}

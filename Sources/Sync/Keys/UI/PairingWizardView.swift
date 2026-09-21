// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SwiftUI

/// Modal root for the pairing wizard (§6): step bar, content, fixed footer, status pages, D7 overwrite
/// confirmation and self-revoke exit.
///
/// Keep confirmation as a container page like loading/error/submitting, sharing footer, exit and chrome
/// instead of duplicating footer state. All rendered differences come from SpaceOverwriteDiff; this view owns
/// no diff logic.
struct PairingWizardView: View {
    @StateObject private var viewModel: PairingWizardViewModel
    let controller: SyncKeyController
    let onDismiss: () -> Void

    /// A nonnil note disables removal because this is the account's last active device. Keep it sticky for
    /// this window: the modal cannot add a second device. Carried from ProfilePairingGateView.
    @State private var removeBlockedNote: String?
    /// Transient removal failure (offline, 5xx, Keychain), shown in the same slot without disabling retry.
    /// Clear at each new attempt.
    @State private var removeErrorNote: String?

    init(viewModel: PairingWizardViewModel, controller: SyncKeyController,
         onDismiss: @escaping () -> Void) {
        // The host creates the VM and this StateObject retains it through the window's hosting controller,
        // supporting the host's weak viewModel lifetime.
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
                       detail: NSLocalizedString(
                           "Phi is counting the Spaces in your account. This can take up to two minutes.",
                           comment: "Pairing wizard - loading page progress detail"),
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
                    // Gate context renders rows only; wizard chrome owns title, body and primary button.
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

    /// Loading progress detail: preview may take PhiSyncEngine.previewDeadlineMs = 120 s, with neither Retry
    /// nor a close button on loading. Explain the work and expected wait so users do not force-quit pairing
    /// and restart the wait. Other status pages pass nil and keep their existing rendering.
    private func statusPage(message: String?, detail: String? = nil,
                            showsProgress: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if let message {
                Text(message).font(.body).themedForeground(.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let detail {
                Text(detail).font(.callout).themedForeground(.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showsProgress { ProgressView() }
        }
        .padding(24)
    }

    // MARK: - D7 overwrite confirmation (§6.9)

    private func confirmationPage(_ items: [SpaceOverwriteDiff]) -> some View {
        // An empty page is invalid: Finish bypasses this phase when no differences exist (§5.5). Assert to
        // prevent future always-show logic from presenting a blank two-button page.
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
        // If either icon uses the fallback glyph, show raw storedValue for both: empty and unrecognized values
        // both render rectangle.stack, so glyphs alone can hide a real difference.
        let showsRaw = needsRawIconText(change)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            // Do not force equal label widths: localized labels can grow substantially and would truncate or
            // crowd values offscreen.
            Text(Self.fieldLabel(change.field))
                .font(.callout)
                .themedForeground(.textSecondary)
            value(change.local, field: change.field, showsRawIconText: showsRaw)
            Text(verbatim: "→").themedForeground(.textTertiary)
            value(change.account, field: change.field, showsRawIconText: showsRaw)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        // Expose the whole row as one accessibility element so VoiceOver does not read the arrow separately.
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
                    // This hex-derived color previews the literal value, not a theme color. If invalid, keep
                    // text without an empty swatch.
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

    /// Do not reuse Default: SettingsSectionCard uses it as the default Space/Profile badge in this same
    /// window (§6.4). Confirmation instead means this side has no custom value; distinct keys avoid
    /// conflicting meanings.
    private static let noCustomValue = NSLocalizedString(
        "No custom value",
        comment: "Overwrite confirmation - a field with no value of its own (no theme pinned, no custom opacity); the app theme's own value is used instead")

    /// One switch supplies all six visible and accessibility field labels. Reuse existing
    /// Name/Icon/Color/Theme keys with their existing catalog comments (§6.8); different comments for the same
    /// key are concatenated during generation.
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

    /// Preserve thousandth-unit differences: the continuous opacity slider has no ticks or rounding. Integer
    /// percentages could display two genuinely different values being overwritten as equal.
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

    /// Accessibility text. Icons use raw storedValue because §5.7 provides no display-name catalog, making it
    /// the only speakable identity.
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

    /// Validate hex first: DynamicColor's Color(hexString:) is nonfailable and can render an unspecified color
    /// for invalid input.
    private static func swatch(_ hex: String) -> Color? {
        let body = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard body.count == 6 || body.count == 8, body.allSatisfy(\.isHexDigit) else { return nil }
        return Color(hexString: hex)
    }

    // MARK: - Footer (§6.5)

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
            // The app-modal's sole alternative exit appears on every page, including confirmation.
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
            // Match §6.5: disable for undecided rows or loading/submitting. Read phase on the observed wizard
            // VM, never keyLayer.isSubmitting: keyLayer is a separate ObservableObject, and its Published
            // changes do not redraw this view.
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
            // D7 deliberately reverses button roles here: Apply is destructive, so Back receives defaultAction
            // and Return. Apply has no key equivalent; full keyboard access reaches it first in declaration
            // order Apply → Back → Remove. Do not add cancelAction: Esc must not dismiss this blocking
            // app-modal.
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

    /// Retry is enabled except during submission. A stuck load must be restartable in any phase; retry during
    /// submission would create a second phase writer. Pass the wizard VM's own Published isApplying, not
    /// keyLayer.isSubmitting, which this view does not observe and whose defer already cleared it when error
    /// appears (§6.5).
    static func retryEnabled(for phase: PairingWizardPhase, isSubmitting: Bool) -> Bool {
        !isSubmitting
    }

    /// Confirm again, then retire before cleanup. Do not preflight device count: this client has no list
    /// endpoint. Request removal directly and disable on refusal, as in
    /// ProfilePairingGateView.confirmAndRemoveThisDevice.
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
                // R12: detailed errors go only to logs; UI uses fixed text.
                AppLogWarn("[phi-sync] self-revoke failed (\(PhiSyncLog.describe(error)))")
                removeErrorNote = SelfRevokeStrings.removalUnavailable
            }
        }
    }
}

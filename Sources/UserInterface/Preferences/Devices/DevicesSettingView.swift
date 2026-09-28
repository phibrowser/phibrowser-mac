import SwiftUI

/// Settings → Sync: setup and sync status, authorized devices, and recovery/removal.
struct DevicesSettingView: View {
    @ObservedObject var viewModel: DevicesSettingViewModel
    /// The runtime "remove this device from sync" entry point. Separate from
    /// `viewModel` because that object is built from an `AccountKeyManager`
    /// pair, while the removal has to run on the coordinator-owned
    /// `SyncKeyController` (see `DevicesRemoveDeviceModel`).
    @ObservedObject var removeModel: DevicesRemoveDeviceModel
    var onJoinThisDevice: () -> Void = {}
    var onResolvePairing: () -> Void = {}
    /// Polled from the shared `SyncKeyController` rather than threaded through
    /// `DevicesSettingViewModel` (which the pane's tests construct directly):
    /// checked once when the pane appears and refreshed alongside the pending
    /// join-request poll, so the banner clears once pairing resolves.
    var needsPairingCheck: () -> Bool = { false }

    @State private var needsPairing = false
    @State private var isStatusDetailsExpanded = false

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 24) {
                if viewModel.requiresReconfiguration {
                    reconfigurationCard
                }
                if needsPairing, !viewModel.requiresReconfiguration, viewModel.unlockState == .unlocked {
                    pairingCard
                }

                switch viewModel.unlockState {
                case .loading:
                    loadingCard
                case .notSignedIn:
                    signInCard
                case .failed(let m):
                    SettingsDetailCard {
                        row(m) {
                            actionButton(NSLocalizedString("sync.settings.retry", value: "Retry", comment: "Reload sync settings")) {
                                Task { await viewModel.loadAll() }
                            }
                        }
                    }
                case .needsJoin:
                    SettingsDetailCard {
                        row(NSLocalizedString("sync.devices.notSetUp", value: "This device isn’t set up for sync yet.", comment: "Devices settings - shown when this device has not joined sync")) {
                            actionButton(NSLocalizedString("sync.devices.setUp", value: "Set up sync on this device", comment: "Devices settings - button that starts sync setup on this device")) {
                                onJoinThisDevice()
                            }
                        }
                    }
                case .unlocked:
                    if !needsPairing { statusCard }
                }

                if viewModel.isUnlocked, hasDevicesContent {
                    devicesSection
                }

                if let err = viewModel.actionError {
                    errorText(err)
                }

                if removeModel.isVisible(unlockState: viewModel.unlockState) {
                    removeDeviceSection
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 36)
            .padding(.horizontal, 36)
        }
        .themedBackground(PhiPreferences.fixedWindowBackground)
        .frame(width: 680, height: 561)
        .task {
            await viewModel.loadAll()
            needsPairing = needsPairingCheck()
            // Mirrors the ViewModel's own 3s pending-approval poll cadence so the
            // banner clears promptly once another entry point resolves pairing
            // (e.g. the key-layer window). Tied to the view's task lifecycle, so
            // it stops automatically alongside `stopPolling()` below.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                needsPairing = needsPairingCheck()
            }
        }
        .onDisappear { Task { await viewModel.stopPolling() } }
    }

    // MARK: - Shared pane styling

    /// A titled group of cards; the title sits above the card, as in the
    /// General pane's sections.
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.system(size: 12))
                .themedForeground(.textSecondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A card row: a title with optional detail lines under it, and a
    /// trailing control.
    private func row<Details: View, Control: View>(
        _ title: String,
        @ViewBuilder details: () -> Details,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13))
                    .themedForeground(.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                details()
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        row(title, details: { EmptyView() }, control: control)
    }

    private func hintText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .themedForeground(.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func errorText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Color.red)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func actionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.bordered)
            .controlSize(.small)
    }

    // MARK: - Setup and status

    private var loadingCard: some View {
        SettingsDetailCard {
            HStack {
                Spacer()
                ProgressView()
                    .controlSize(.small)
                Spacer()
            }
            .padding(.vertical, 20)
        }
    }

    private var signInCard: some View {
        SettingsDetailCard {
            row(NSLocalizedString("sync.settings.signIn", value: "Sign in to sync across devices", comment: "Sync settings signed out explanation")) {
                actionButton(NSLocalizedString("sync.settings.signInAction", value: "Sign in", comment: "Sync settings sign in action")) {
                    LoginController.shared.showLoginWindow()
                }
            }
        }
    }

    private var reconfigurationCard: some View {
        SettingsDetailCard {
            row(SyncReconfigurationStrings.explanation) {
                if let error = viewModel.reconfigurationError {
                    errorText(error)
                }
            } control: {
                actionButton(SyncReconfigurationStrings.title) { onResolvePairing() }
                    .disabled(viewModel.isReconfiguring)
            }
        }
    }

    private var pairingCard: some View {
        SettingsDetailCard {
            row(NSLocalizedString("sync.setup.notPaired", value: "Not paired", comment: "Sync status before matching completes")) {
                hintText(NSLocalizedString("sync.setup.notStarted", value: "Sync has not started", comment: "All sync waits for pairing completion"))
            } control: {
                actionButton(NSLocalizedString("sync.setup.continueSetup", value: "Continue setup", comment: "Reopen sync setup with fresh account data")) {
                    onResolvePairing()
                }
            }
        }
    }

    private var statusCard: some View {
        SettingsDetailCard {
            row(statusTitle(viewModel.summary.phase)) {
                if let date = viewModel.summary.lastSuccess {
                    hintText(String(format: NSLocalizedString("sync.status.lastSuccessAt", value: "Last successful sync on this Mac: %@", comment: "Devices settings - time of the last successful sync on this Mac; %@ is the date and time"), date.formatted()))
                }
                if viewModel.summary.phase == .needsAttention {
                    hintText(NSLocalizedString("sync.status.partialFailure", value: "Some content needs attention. Check the details and your connection.", comment: "One or more sync contexts failed"))
                }
            } control: {
                EmptyView()
            }

            Divider()

            Button {
                withAnimation { isStatusDetailsExpanded.toggle() }
            } label: {
                SettingsDetailRow(NSLocalizedString("sync.status.details", value: "Details", comment: "Expand individual sync context status")) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .themedForeground(.textTertiary)
                        .rotationEffect(.degrees(isStatusDetailsExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isStatusDetailsExpanded {
                ForEach(viewModel.requiredIDs.sorted(), id: \.self) { id in
                    Divider()
                    SettingsDetailRow(viewModel.contextTitle(id)) {
                        Text(statusTitle(SyncSummaryPhase(rawValue: viewModel.contextSnapshots[id]?.phase.rawValue ?? "checking") ?? .checking))
                            .font(.system(size: 12))
                            .themedForeground(.textSecondary)
                    }
                }
            }
        }
    }

    // MARK: - Devices

    /// False while the device list is still loading with nothing to approve, so
    /// the section does not render as a title over an empty card.
    private var hasDevicesContent: Bool {
        !viewModel.pending.isEmpty || !viewModel.devices.isEmpty || viewModel.devicesLoadError != nil
    }

    private var devicesSection: some View {
        section(NSLocalizedString("sync.devices.title", value: "Devices", comment: "Devices authorized for this account")) {
            if !viewModel.pending.isEmpty {
                SettingsDetailCard { pendingSection }
            }
            if let error = viewModel.devicesLoadError {
                SettingsDetailCard {
                    row(NSLocalizedString("sync.devices.thisMacUnknown", value: "This Mac — registration could not be checked", comment: "Device list unavailable; local identity is not proof of registration")) {
                        errorText(error)
                    } control: {
                        EmptyView()
                    }
                }
            } else if !viewModel.devices.isEmpty {
                SettingsDetailCard {
                    ForEach(Array(viewModel.devices.enumerated()), id: \.element.id) { index, device in
                        if index > 0 { Divider() }
                        SettingsDetailRow(device.name, systemImage: "laptopcomputer") {
                            HStack(spacing: 8) {
                                if device.deviceKeyID == viewModel.currentDeviceID {
                                    thisMacBadge
                                }
                                Text(verbatim: Self.platformName(device.platform))
                                    .font(.system(size: 12))
                                    .themedForeground(.textSecondary)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Same pill as `SettingsDefaultBadge`, marking the row for this Mac.
    private var thisMacBadge: some View {
        Text(NSLocalizedString("sync.devices.thisMac", value: "This Mac", comment: "Current authorized device marker"))
            .font(.system(size: 10, weight: .medium))
            .themedForeground(.textSecondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.15), in: Capsule())
    }

    private func statusTitle(_ phase: SyncSummaryPhase) -> String {
        switch phase {
        case .notStarted: return NSLocalizedString("sync.setup.notStarted", value: "Sync has not started", comment: "All sync waits for pairing completion")
        case .checking: return NSLocalizedString("sync.status.checking", value: "Checking sync status…", comment: "Sync status not yet known")
        case .initialSync: return NSLocalizedString("sync.status.initial", value: "Initial sync in progress", comment: "First sync is receiving account data")
        case .syncing: return NSLocalizedString("sync.status.syncing", value: "Syncing…", comment: "Sync has pending work")
        case .upToDate: return NSLocalizedString("sync.status.upToDate", value: "Up to date", comment: "All required contexts completed sync")
        case .offline: return NSLocalizedString("sync.status.offline", value: "Offline — changes will sync when connected", comment: "Eligible data waits for connectivity")
        case .needsAttention: return NSLocalizedString("sync.status.needsAttention", value: "Needs attention", comment: "Sync has a failure requiring attention")
        }
    }

    /// The pane's only destructive action, at the bottom and in the same
    /// secondary style as every other button on the pane. The confirmation, its
    /// copy and the `last_device` note all come from `SelfRevokeStrings`, shared
    /// with the pairing gate's exit of the same name.
    private var removeDeviceSection: some View {
        section(NSLocalizedString("sync.recovery.title", value: "Recovery and removal", comment: "Recovery guidance and device removal")) {
            SettingsDetailCard {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        hintText(NSLocalizedString("sync.recovery.explanation", value: "To join on another device, approve its request here or use your saved recovery code. The code is shown only when sync is first set up.", comment: "Explain existing recovery options without offering retrieval"))
                        if let note = removeModel.note {
                            // `note` carries two different kinds of line: the standing
                            // `last_device` explanation (informational) and a transient
                            // failure the user has to notice and retry. The latter is
                            // coloured like every other error on this pane.
                            if removeModel.noteIsError {
                                errorText(note)
                            } else {
                                hintText(note)
                            }
                        }
                    }
                    Spacer(minLength: 12)
                    if removeModel.isRemoving {
                        ProgressView().controlSize(.small)
                    }
                    actionButton(NSLocalizedString("sync.devices.removeThisDevice",
                                                   value: "Remove this device from sync…",
                                                   comment: "Devices settings - button that removes this device from sync")) {
                        Task { await removeModel.requestRemoval(confirm: SelfRevokeStrings.confirmRemoval) }
                    }
                    .disabled(!removeModel.canRequestRemoval || viewModel.isReconfiguring)
                }
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var pendingSection: some View {
        if viewModel.pending.isEmpty {
            hintText(NSLocalizedString("sync.devices.noPendingRequests", value: "No devices are waiting for approval.", comment: "Devices settings - shown when no device is waiting for approval"))
                .padding(.vertical, 12)
        } else {
            ForEach(Array(viewModel.pending.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Divider() }
                row(String(format: NSLocalizedString("sync.devices.pendingRequestTitle", value: "%1$@ · %2$@", comment: "Devices settings - a device waiting to join; %1$@ is the device name, %2$@ its platform, such as macOS"), item.name, Self.platformName(item.platform))) {
                    // Deliberately not selectable (no `.textSelection`
                    // modifier): it installs an NSTextView, and the
                    // 3-second poll that refreshes `viewModel.pending` can
                    // remove this row while AppKit's mouse-tracking loop is
                    // live, orphaning the loop and hanging the main thread.
                    hintText(String(format: NSLocalizedString("sync.devices.expiresAt", value: "Expires: %@", comment: "Devices settings - when a pending join request expires; %@ is the time"), item.deadline.formatted(date: .omitted, time: .shortened)))
                    Text(String(format: NSLocalizedString("sync.devices.verifyCode", value: "Verify this code matches the other device: %@", comment: "Devices settings - asks to compare a join request's code with the other device; %@ is the code"), item.verificationCode))
                        .font(.system(size: 12, design: .monospaced))
                        .themedForeground(.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                } control: {
                    if viewModel.busyRequestIDs.contains(item.id) { ProgressView().controlSize(.small) }
                    actionButton(NSLocalizedString("sync.devices.approve", value: "Approve", comment: "Devices settings - button that approves a device waiting to join")) {
                        Task { await viewModel.approve(item) }
                    }
                    .disabled(viewModel.busyRequestIDs.contains(item.id))
                    actionButton(NSLocalizedString("sync.devices.deny", value: "Deny", comment: "Devices settings - button that denies a device waiting to join")) {
                        Task { await viewModel.deny(item) }
                    }
                    .disabled(viewModel.busyRequestIDs.contains(item.id))
                }
            }
        }
    }
}

extension DevicesSettingView {
    /// Platform identifiers arrive from the sync backend in lowercase (`macos`). They are shown
    /// as product names, which are not translated; an unknown identifier is shown unchanged.
    static func platformName(_ platform: String) -> String {
        switch platform.lowercased() {
        case "macos": return "macOS"
        case "ios": return "iOS"
        case "ipados": return "iPadOS"
        case "windows": return "Windows"
        case "linux": return "Linux"
        case "android": return "Android"
        case "chromeos": return "ChromeOS"
        default: return platform
        }
    }
}

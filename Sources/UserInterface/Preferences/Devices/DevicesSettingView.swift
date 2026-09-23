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
            VStack(alignment: .leading, spacing: 20) {
                Text(NSLocalizedString("sync.settings.title", value: "Sync", comment: "Settings pane title for cross-device synchronization"))
                    .font(.title2.bold())
                    .themedForeground(.textPrimaryStrong)

                if !viewModel.accountName.isEmpty {
                    Text(viewModel.accountName).font(.callout).themedForeground(.textSecondary)
                }
                if needsPairing, viewModel.unlockState == .unlocked {
                    pairingBanner
                }

                switch viewModel.unlockState {
                case .loading:
                    ProgressView()
                case .notSignedIn:
                    Text(NSLocalizedString("sync.settings.signIn", value: "Sign in to sync across devices", comment: "Sync settings signed out explanation"))
                    Button(NSLocalizedString("sync.settings.signInAction", value: "Sign in", comment: "Sync settings sign in action")) { LoginController.shared.showLoginWindow() }
                case .failed(let m):
                    Text(m).foregroundColor(.red)
                    Button(NSLocalizedString("sync.settings.retry", value: "Retry", comment: "Reload sync settings")) { Task { await viewModel.loadAll() } }
                case .needsJoin:
                    VStack(alignment: .leading, spacing: 12) {
                        Text(NSLocalizedString("This device isn’t set up for sync yet.", comment: "Devices - needs join"))
                            .themedForeground(.textPrimary)
                        Button(NSLocalizedString("Set up sync on this device", comment: "Devices - set up")) {
                            onJoinThisDevice()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                case .unlocked:
                    if !needsPairing { statusSection }
                }

                if viewModel.isUnlocked {
                    devicesSection
                }

                if let err = viewModel.actionError {
                    Text(err).font(.callout).foregroundColor(.red)
                }

                if removeModel.isVisible(unlockState: viewModel.unlockState) {
                    removeDeviceSection
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
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

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.headline).themedForeground(.textPrimaryStrong)
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(statusTitle(viewModel.summary.phase)).font(.headline)
            if let date = viewModel.summary.lastSuccess {
                Text(NSLocalizedString("sync.status.lastSuccess", value: "Last successful sync on this Mac", comment: "Local completion timestamp label") + ": " + date.formatted())
                    .font(.callout).themedForeground(.textSecondary)
            }
            if viewModel.summary.phase == .needsAttention {
                Text(NSLocalizedString("sync.status.partialFailure", value: "Some content needs attention. Check the details and your connection.", comment: "One or more sync contexts failed"))
                    .font(.callout)
            }
            DisclosureGroup(isExpanded: $isStatusDetailsExpanded) {
                ForEach(viewModel.requiredIDs.sorted(), id: \.self) { id in
                    HStack {
                        Text(viewModel.contextTitle(id))
                        Spacer()
                        Text(statusTitle(SyncSummaryPhase(rawValue: viewModel.contextSnapshots[id]?.phase.rawValue ?? "checking") ?? .checking))
                    }.font(.callout).padding(.vertical, 3)
                }
            } label: {
                Text(NSLocalizedString("sync.status.details", value: "Details", comment: "Expand individual sync context status"))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation { isStatusDetailsExpanded.toggle() }
                    }
            }
        }.padding(12).settingsCardChrome()
    }

    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(NSLocalizedString("sync.devices.title", value: "Devices", comment: "Devices authorized for this account"))
            if !viewModel.pending.isEmpty { pendingSection }
            if let error = viewModel.devicesLoadError {
                Text(error).font(.callout).foregroundColor(.red)
                Text(NSLocalizedString("sync.devices.thisMacUnknown", value: "This Mac — registration could not be checked", comment: "Device list unavailable; local identity is not proof of registration"))
            } else {
                ForEach(viewModel.devices) { device in
                    HStack {
                        Image(systemName: "laptopcomputer")
                        Text(device.name)
                        Text(device.platform).font(.caption).themedForeground(.textSecondary)
                        Spacer()
                        if device.deviceKeyID == viewModel.currentDeviceID {
                            Text(NSLocalizedString("sync.devices.thisMac", value: "This Mac", comment: "Current authorized device marker")).font(.caption)
                        }
                    }.padding(.vertical, 4)
                }
            }
        }.padding(12).settingsCardChrome()
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

    /// The pane's only destructive action, at the bottom and in the secondary
    /// style the pane already uses for "Deny". The confirmation, its copy and the
    /// `last_device` note all come from `SelfRevokeStrings`, shared with the
    /// pairing gate's exit of the same name.
    @ViewBuilder
    private var removeDeviceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(NSLocalizedString("sync.recovery.title", value: "Recovery and removal", comment: "Recovery guidance and device removal"))
            Text(NSLocalizedString("sync.recovery.explanation", value: "To join on another device, approve its request here or use your saved recovery code. The code is shown only when sync is first set up.", comment: "Explain existing recovery options without offering retrieval"))
                .font(.callout)
            HStack(spacing: 10) {
                Button(NSLocalizedString("Remove this device from sync…",
                                         comment: "Devices - remove this device from sync")) {
                    Task { await removeModel.requestRemoval(confirm: SelfRevokeStrings.confirmRemoval) }
                }
                .buttonStyle(.bordered)
                .disabled(!removeModel.canRequestRemoval)
                if removeModel.isRemoving {
                    ProgressView().controlSize(.small)
                }
            }
            if let note = removeModel.note {
                // `note` carries two different kinds of line: the standing
                // `last_device` explanation (informational) and a transient
                // failure the user has to notice and retry. The latter is
                // coloured like every other error on this pane.
                Text(note)
                    .font(.callout)
                    .foregroundColor(removeModel.noteIsError ? .red : .secondary)
            }
        }
    }

    @ViewBuilder
    private var pairingBanner: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(NSLocalizedString("sync.setup.notPaired", value: "Not paired", comment: "Sync status before matching completes"))
                Text(NSLocalizedString("sync.setup.notStarted", value: "Sync has not started", comment: "All sync waits for pairing completion")).font(.callout)
            }
                .font(.body.bold())
                .themedForeground(.textPrimaryStrong)
            Spacer()
            Button(NSLocalizedString("sync.setup.continueSetup", value: "Continue setup", comment: "Reopen sync setup with fresh account data")) {
                onResolvePairing()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor))
        .cornerRadius(8)
    }

    @ViewBuilder
    private var pendingSection: some View {
        if viewModel.pending.isEmpty {
            Text(NSLocalizedString("No devices are waiting for approval.", comment: "Devices - empty"))
                .themedForeground(.textPrimary)
        } else {
            ForEach(viewModel.pending) { item in
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(item.name) · \(item.platform)")
                            .font(.body.bold())
                            .themedForeground(.textPrimaryStrong)
                        // Deliberately not selectable (no `.textSelection`
                        // modifier): it installs an NSTextView, and the
                        // 3-second poll that refreshes `viewModel.pending` can
                        // remove this row while AppKit's mouse-tracking loop is
                        // live, orphaning the loop and hanging the main thread.
                        Text(NSLocalizedString("sync.devices.expires", value: "Expires", comment: "Pending device request expiry label") + ": " + item.deadline.formatted(date: .omitted, time: .shortened))
                            .font(.caption).themedForeground(.textSecondary)
                        Text(NSLocalizedString("Verify this code matches the other device: ", comment: "Devices - verify prefix") + item.verificationCode)
                            .font(.system(.callout, design: .monospaced))
                            .themedForeground(.textPrimary)
                    }
                    Spacer()
                    Button(NSLocalizedString("Approve", comment: "Devices - approve")) {
                        Task { await viewModel.approve(item) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.busyRequestIDs.contains(item.id))
                    Button(NSLocalizedString("Deny", comment: "Devices - deny")) {
                        Task { await viewModel.deny(item) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.busyRequestIDs.contains(item.id))
                    if viewModel.busyRequestIDs.contains(item.id) { ProgressView().controlSize(.small) }
                }
                .padding(12)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(8)
            }
        }
    }
}

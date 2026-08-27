import SwiftUI

/// Settings → Devices: shows this device's unlock state, a "set up sync" affordance when
/// it isn't joined, and the list of pending device-join requests to approve or deny.
struct DevicesSettingView: View {
    @ObservedObject var viewModel: DevicesSettingViewModel
    var onJoinThisDevice: () -> Void = {}
    var onResolvePairing: () -> Void = {}
    /// Polled from the shared `SyncKeyController` rather than threaded through
    /// `DevicesSettingViewModel` (which the pane's tests construct directly):
    /// checked once when the pane appears and refreshed alongside the pending
    /// join-request poll, so the banner clears once pairing resolves.
    var needsPairingCheck: () -> Bool = { false }

    @State private var needsPairing = false

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 20) {
                Text(NSLocalizedString("Devices", comment: "Devices settings - header"))
                    .font(.title2.bold())
                    .themedForeground(.textPrimaryStrong)

                if needsPairing {
                    pairingBanner
                }

                switch viewModel.unlockState {
                case .loading:
                    ProgressView()
                case .notSignedIn:
                    Text(NSLocalizedString("Sign in to manage devices.", comment: "Devices - signed out"))
                        .themedForeground(.textPrimary)
                case .failed(let m):
                    Text(m).foregroundColor(.red)
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
                    pendingSection
                }

                if let err = viewModel.actionError {
                    Text(err).font(.callout).foregroundColor(.red)
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

    @ViewBuilder
    private var pairingBanner: some View {
        HStack(spacing: 16) {
            Text(NSLocalizedString("Profiles need pairing", comment: "Devices - pairing banner title"))
                .font(.body.bold())
                .themedForeground(.textPrimaryStrong)
            Spacer()
            Button(NSLocalizedString("Resolve", comment: "Devices - pairing banner button")) {
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
                        Text(NSLocalizedString("Verify this code matches the other device: ", comment: "Devices - verify prefix") + item.verificationCode)
                            .font(.system(.callout, design: .monospaced))
                            .themedForeground(.textPrimary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Button(NSLocalizedString("Approve", comment: "Devices - approve")) {
                        Task { await viewModel.approve(item) }
                    }
                    .buttonStyle(.borderedProminent)
                    Button(NSLocalizedString("Deny", comment: "Devices - deny")) {
                        Task { await viewModel.deny(item) }
                    }
                    .buttonStyle(.bordered)
                }
                .padding(12)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(8)
            }
        }
    }
}

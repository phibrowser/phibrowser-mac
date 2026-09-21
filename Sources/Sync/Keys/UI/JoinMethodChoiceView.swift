import SwiftUI

/// Lets a new device pick how to join: enter a recovery code, or request approval
/// from an already-authorized device. Purely presentational.
struct JoinMethodChoiceView: View {
    @ObservedObject var viewModel: KeyLayerViewModel

    var body: some View {
        VStack(spacing: 24) {
            Text(NSLocalizedString("Add this device to your account", comment: "Join choice - title"))
                .font(.title2.bold())
                .themedForeground(.textPrimaryStrong)

            Text(NSLocalizedString("Choose how to set up sync on this device.", comment: "Join choice - explanation"))
                .font(.body)
                .themedForeground(.textPrimary)
                .multilineTextAlignment(.center)

            Button(NSLocalizedString("Request approval from another device", comment: "Join choice - request approval")) {
                Task { await viewModel.startJoinRequest() }
            }
            .buttonStyle(.borderedProminent)

            Button(NSLocalizedString("Enter a recovery code", comment: "Join choice - use recovery code")) {
                viewModel.showRecoveryEntry()
            }
            .buttonStyle(.bordered)
        }
        .padding(32)
        .frame(minWidth: 360)
    }
}

#if DEBUG
#Preview("Join Method Choice") { JoinMethodChoiceView(viewModel: KeyLayerViewModel.preview()) }
#endif

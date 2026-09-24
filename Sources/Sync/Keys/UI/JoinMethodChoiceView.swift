import SwiftUI

/// Lets a new device pick how to join: enter a recovery code, or request approval
/// from an already-authorized device. Purely presentational.
struct JoinMethodChoiceView: View {
    @ObservedObject var viewModel: KeyLayerViewModel

    var body: some View {
        VStack(spacing: 24) {
            Text(NSLocalizedString("sync.setup.joinMethod.title", value: "Add this device to your account", comment: "Sync setup - title of the page that asks how this device joins the account"))
                .font(.title2.bold())
                .themedForeground(.textPrimaryStrong)

            Text(NSLocalizedString("sync.setup.joinMethod.explanation", value: "Choose how to set up sync on this device.", comment: "Sync setup - explanation under the join method title"))
                .font(.body)
                .themedForeground(.textPrimary)
                .multilineTextAlignment(.center)

            Button(NSLocalizedString("sync.setup.joinMethod.requestApproval", value: "Request approval from another device", comment: "Sync setup - option that asks another signed-in device to approve this one")) {
                Task { await viewModel.startJoinRequest() }
            }
            .buttonStyle(.borderedProminent)

            Button(NSLocalizedString("sync.setup.joinMethod.useRecoveryCode", value: "Enter a recovery code", comment: "Sync setup - option that joins this device with a saved recovery code")) {
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

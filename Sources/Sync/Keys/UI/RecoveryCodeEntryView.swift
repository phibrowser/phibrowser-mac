import SwiftUI

/// Lets the user enter a recovery code to join an already-initialized account
/// on a new device. Purely presentational: all state transitions live on
/// `KeyLayerViewModel`.
struct RecoveryCodeEntryView: View {
    @ObservedObject var viewModel: KeyLayerViewModel

    private var isConfirmation: Bool { viewModel.phase == .confirmingRecoveryCode }

    var body: some View {
        VStack(spacing: 24) {
            Text(isConfirmation
                 ? NSLocalizedString("sync.recoveryCode.confirmTitle", value: "Confirm your recovery code", comment: "Sync setup - title requiring re-entry of the saved recovery code")
                 : NSLocalizedString("Enter your recovery code", comment: "Recovery code entry - title"))
                .font(.title2.bold())
                .themedForeground(.textPrimaryStrong)

            Text(isConfirmation
                 ? NSLocalizedString("sync.recoveryCode.confirmExplanation", value: "Enter the recovery code you just saved. Sync will stay off until you confirm the code and finish setup.", comment: "Sync setup - explanation of required recovery code verification")
                 : NSLocalizedString("Enter the recovery code you saved when you set up sync on another device.", comment: "Recovery code entry - explanation"))
                .font(.body)
                .themedForeground(.textPrimary)
                .multilineTextAlignment(.center)

            TextField(
                NSLocalizedString("Recovery code", comment: "Recovery code entry - text field placeholder"),
                text: $viewModel.recoveryInput
            )
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .disableAutocorrection(true)

            if let message = viewModel.inputError {
                Text(message)
                    .font(.callout)
                    .foregroundColor(.red)
            }

            Button(NSLocalizedString("Submit", comment: "Recovery code entry - submit button")) {
                Task { await viewModel.submitRecoveryCode(viewModel.recoveryInput) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.recoveryInput.isEmpty || viewModel.workingOperation)
        }
        .padding(32)
        .frame(minWidth: 360)
    }
}

#if DEBUG
#Preview("Recovery Code Entry") {
    RecoveryCodeEntryView(viewModel: KeyLayerViewModel.preview())
}
#endif

import SwiftUI

/// Lets the user enter a recovery code to join an already-initialized account
/// on a new device. Purely presentational: all state transitions live on
/// `KeyLayerViewModel`.
struct RecoveryCodeEntryView: View {
    @ObservedObject var viewModel: KeyLayerViewModel

    var body: some View {
        VStack(spacing: 24) {
            Text(NSLocalizedString("Enter your recovery code", comment: "Recovery code entry - title"))
                .font(.title2.bold())
                .themedForeground(.textPrimaryStrong)

            Text(NSLocalizedString(
                "Enter the recovery code you saved when you set up sync on another device.",
                comment: "Recovery code entry - explanation"))
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

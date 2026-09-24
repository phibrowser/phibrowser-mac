import SwiftUI

/// Lets the user enter a recovery code to join an already-initialized account
/// on a new device. Purely presentational: all state transitions live on
/// `KeyLayerViewModel`.
struct RecoveryCodeEntryView: View {
    @ObservedObject var viewModel: KeyLayerViewModel

    var body: some View {
        VStack(spacing: 24) {
            Text(NSLocalizedString("sync.recovery.entry.title", value: "Enter your recovery code", comment: "Sync setup - title of the page for entering a recovery code"))
                .font(.title2.bold())
                .themedForeground(.textPrimaryStrong)

            Text(NSLocalizedString("sync.recovery.entry.explanation",
                value: "Enter the recovery code you saved when you set up sync on another device.",
                comment: "Sync setup - explanation on the page for entering a recovery code"))
                .font(.body)
                .themedForeground(.textPrimary)
                .multilineTextAlignment(.center)

            TextField(
                NSLocalizedString("sync.recovery.entry.placeholder", value: "Recovery code", comment: "Sync setup - placeholder of the recovery code text field"),
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

            Button(NSLocalizedString("sync.recovery.entry.submit", value: "Submit", comment: "Sync setup - button that submits the entered recovery code")) {
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

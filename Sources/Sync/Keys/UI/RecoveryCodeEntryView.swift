import SwiftUI

/// Lets the user enter a recovery code to join an already-initialized account
/// on a new device. Purely presentational: all state transitions live on
/// `KeyLayerViewModel`.
struct RecoveryCodeEntryView: View {
    @ObservedObject var viewModel: KeyLayerViewModel
    @State private var code: String = ""

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
                text: $code
            )
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .disableAutocorrection(true)

            if case .error(let message) = viewModel.phase {
                Text(message)
                    .font(.callout)
                    .foregroundColor(.red)
            }

            Button(NSLocalizedString("Submit", comment: "Recovery code entry - submit button")) {
                Task { await viewModel.submitRecoveryCode(code) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(code.isEmpty || viewModel.phase == .working)
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

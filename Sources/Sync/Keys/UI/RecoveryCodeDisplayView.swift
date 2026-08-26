import SwiftUI

/// Shows the recovery code generated during bootstrap and lets the user
/// confirm they saved it before continuing. Purely presentational: all state
/// transitions live on `KeyLayerViewModel`.
struct RecoveryCodeDisplayView: View {
    @ObservedObject var viewModel: KeyLayerViewModel

    var body: some View {
        VStack(spacing: 24) {
            Text(NSLocalizedString("Save your recovery code", comment: "Recovery code display - title"))
                .font(.title2.bold())
                .themedForeground(.textPrimaryStrong)

            Text(NSLocalizedString(
                "Store this code somewhere safe. You will need it to add another device to your account.",
                comment: "Recovery code display - explanation"))
                .font(.body)
                .themedForeground(.textPrimary)
                .multilineTextAlignment(.center)

            Text(recoveryCode)
                .font(.system(.title3, design: .monospaced))
                .textSelection(.enabled)
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(8)

            if case .error(let message) = viewModel.phase {
                Text(message)
                    .font(.callout)
                    .foregroundColor(.red)
            }

            Button(NSLocalizedString("I've saved it", comment: "Recovery code display - confirm button")) {
                viewModel.confirmSaved()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .frame(minWidth: 360)
    }

    private var recoveryCode: String {
        if case .showingRecoveryCode(let code) = viewModel.phase { return code }
        return ""
    }
}

#if DEBUG
#Preview("Recovery Code Display") {
    let viewModel = KeyLayerViewModel.preview()
    return RecoveryCodeDisplayView(viewModel: viewModel)
        .task { await viewModel.startBootstrap() }
}
#endif

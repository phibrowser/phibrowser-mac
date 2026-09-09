import AppKit
import SwiftUI

/// Shows the recovery code generated during bootstrap and lets the user
/// confirm they saved it before continuing. Purely presentational: all state
/// transitions live on `KeyLayerViewModel`.
struct RecoveryCodeDisplayView: View {
    @ObservedObject var viewModel: KeyLayerViewModel

    /// Brief "Copied" feedback after the recovery code lands on the pasteboard.
    @State private var justCopied = false

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

            // Deliberately not selectable (no `.textSelection` modifier): it
            // backs this Text with an NSTextView, whose mouse-tracking loop for a drag
            // selection drains main-actor continuations. `confirmSaved()` can
            // land `.done` mid-drag, which tears this view and its window down
            // and leaves the tracking loop spinning forever on a mouse-up that
            // can never arrive — a 100% CPU hang of the whole browser's main
            // thread. The Copy button below gives the same affordance safely.
            Text(recoveryCode)
                .font(.system(.title3, design: .monospaced))
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(8)

            Button(justCopied
                   ? NSLocalizedString("Copied", comment: "Recovery code display - copy button, just copied")
                   : NSLocalizedString("Copy", comment: "Recovery code display - copy button")) {
                copyRecoveryCode()
            }
            .buttonStyle(.bordered)
            .disabled(recoveryCode.isEmpty)

            if case .error(let message) = viewModel.phase {
                Text(message)
                    .font(.callout)
                    .foregroundColor(.red)
            }

            Button(NSLocalizedString("I've saved it", comment: "Recovery code display - confirm button")) {
                Task { await viewModel.confirmSaved() }
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

    /// Puts the recovery code on the pasteboard. Never logged: the code is key
    /// material.
    private func copyRecoveryCode() {
        let code = recoveryCode
        guard !code.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(code, forType: .string)
        justCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            justCopied = false
        }
    }
}

#if DEBUG
#Preview("Recovery Code Display") {
    let viewModel = KeyLayerViewModel.preview()
    return RecoveryCodeDisplayView(viewModel: viewModel)
        .task { await viewModel.startBootstrap() }
}
#endif

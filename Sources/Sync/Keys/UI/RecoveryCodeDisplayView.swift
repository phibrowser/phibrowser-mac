import AppKit
import SwiftUI

/// Shows the recovery code generated during bootstrap and lets the user
/// acknowledge saving it before the separate verification step. Purely presentational: all state
/// transitions live on `KeyLayerViewModel`.
struct RecoveryCodeDisplayView: View {
    @ObservedObject var viewModel: KeyLayerViewModel

    /// Brief "Copied" feedback after the recovery code lands on the pasteboard.
    @State private var justCopied = false

    var body: some View {
        VStack(spacing: 24) {
            Text(NSLocalizedString("sync.recovery.save.title", value: "Save your recovery code", comment: "Sync setup - title of the page that shows a new recovery code"))
                .font(.title2.bold())
                .themedForeground(.textPrimaryStrong)

            Text(NSLocalizedString(
                "sync.recovery.save.oneTimeNotice",
                value: "This recovery code is shown only once. Save it somewhere safe. On the next screen, enter it to confirm you saved it before continuing sync setup.",
                comment: "Recovery code display - one-time visibility warning and required next-step verification"))
                .font(.body)
                .themedForeground(.textPrimary)
                .multilineTextAlignment(.center)

            // Deliberately not selectable (no `.textSelection` modifier): it
            // backs this Text with an NSTextView, whose mouse-tracking loop for a drag
            // selection drains main-actor continuations. `confirmSaved()` can
            // replace this view mid-drag, which tears its text view down
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
                   ? NSLocalizedString("sync.recovery.save.copied", value: "Copied", comment: "Sync setup - copy button title right after the recovery code was copied")
                   : NSLocalizedString("sync.recovery.save.copy", value: "Copy", comment: "Sync setup - button that copies the recovery code")) {
                copyRecoveryCode()
            }
            .buttonStyle(.bordered)
            .disabled(recoveryCode.isEmpty)

            if case .error(let message) = viewModel.phase {
                Text(message)
                    .font(.callout)
                    .foregroundColor(.red)
            }

            Button(NSLocalizedString("sync.recovery.save.confirm", value: "I've saved it", comment: "Sync setup - button confirming the user saved the recovery code")) {
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

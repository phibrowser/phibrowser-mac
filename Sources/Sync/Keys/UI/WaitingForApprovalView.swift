import SwiftUI

/// Shown on a new device while it waits for another device to approve the join.
/// Displays the verification code the user compares against the approving device.
struct WaitingForApprovalView: View {
    @ObservedObject var viewModel: KeyLayerViewModel
    let code: String
    let deadline: Date

    var body: some View {
        VStack(spacing: 24) {
            ProgressView()

            Text(NSLocalizedString("Waiting for approval", comment: "Waiting - title"))
                .font(.title2.bold())
                .themedForeground(.textPrimaryStrong)

            Text(NSLocalizedString(
                "sync.setup.approvalInstructions", value: "On an authorized device, open Settings → Sync and approve this request. Make sure this code matches:",
                comment: "Instructions for approving another device"))
                .font(.body)
                .themedForeground(.textPrimary)
                .multilineTextAlignment(.center)

            // Deliberately not selectable (no `.textSelection` modifier): it
            // installs an NSTextView whose mouse-tracking loop is orphaned when the polled
            // phase change tears this view (and its window) down mid-drag,
            // hanging the main thread. The code is compared by eye, so there is
            // nothing to copy.
            Text(code)
                .font(.system(.title, design: .monospaced))
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(8)

            HStack(spacing: 4) {
                Text(NSLocalizedString("sync.setup.expiresIn", value: "Expires in", comment: "Approval request time remaining prefix"))
                Text(deadline, style: .timer).monospacedDigit()
            }
            .font(.callout)
            .themedForeground(.textPrimary)

            if let error = viewModel.inputError {
                Text(error).font(.callout).foregroundColor(.red)
            }
            Button(NSLocalizedString("sync.setup.useRecovery", value: "Use a recovery code", comment: "Switch from approval to recovery code")) { viewModel.showRecoveryEntry() }
            Button(NSLocalizedString("Cancel", comment: "Waiting - cancel")) { viewModel.cancelJoin() }
                .buttonStyle(.bordered)
        }
        .padding(32)
        .frame(minWidth: 360)
    }
}

#if DEBUG
#Preview("Waiting For Approval") {
    WaitingForApprovalView(viewModel: KeyLayerViewModel.preview(), code: "K7QP-3M2A", deadline: Date().addingTimeInterval(900))
}
#endif

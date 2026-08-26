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
                "On a device that’s already signed in, open Settings → Devices and approve this request. Make sure this code matches:",
                comment: "Waiting - explanation"))
                .font(.body)
                .themedForeground(.textPrimary)
                .multilineTextAlignment(.center)

            Text(code)
                .font(.system(.title, design: .monospaced))
                .textSelection(.enabled)
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(8)

            Text(NSLocalizedString("This request expires at ", comment: "Waiting - expiry prefix")
                 + deadline.formatted(date: .omitted, time: .shortened))
                .font(.callout)
                .themedForeground(.textPrimary)

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

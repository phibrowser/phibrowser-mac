import SwiftUI

/// Hosts the whole key-layer flow in one view, switching sub-views on the view model's
/// phase. Calls `onFinish` once the flow completes so a hosting window can close.
struct KeyLayerView: View {
    @ObservedObject var viewModel: KeyLayerViewModel
    var onFinish: () -> Void = {}

    var body: some View {
        Group {
            switch viewModel.phase {
            case .idle, .working:
                ProgressView().padding(48)
            case .showingRecoveryCode:
                RecoveryCodeDisplayView(viewModel: viewModel)
            case .enteringRecoveryCode:
                RecoveryCodeEntryView(viewModel: viewModel)
            case .chooseJoinMethod:
                JoinMethodChoiceView(viewModel: viewModel)
            case .waitingForApproval(let code, let deadline):
                WaitingForApprovalView(viewModel: viewModel, code: code, deadline: deadline)
            case .joinDenied:
                message(NSLocalizedString("Request denied", comment: "Join denied - title"),
                        NSLocalizedString("The other device denied this request.", comment: "Join denied - body"),
                        retry: true)
            case .joinExpired:
                message(NSLocalizedString("Request expired", comment: "Join expired - title"),
                        NSLocalizedString("This request timed out. You can try again.", comment: "Join expired - body"),
                        retry: true)
            case .error(let m):
                message(NSLocalizedString("Something went wrong", comment: "Key layer error - title"), m, retry: false)
            case .done:
                Color.clear.onAppear { onFinish() }
            }
        }
        .frame(minWidth: 420, minHeight: 320)
    }

    @ViewBuilder
    private func message(_ title: String, _ body: String, retry: Bool) -> some View {
        VStack(spacing: 24) {
            Text(title).font(.title2.bold()).themedForeground(.textPrimaryStrong)
            Text(body).font(.body).themedForeground(.textPrimary).multilineTextAlignment(.center)
            if retry {
                Button(NSLocalizedString("Try another way", comment: "Key layer - retry")) {
                    viewModel.chooseJoinAgain()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
        .frame(minWidth: 360)
    }
}

#if DEBUG
#Preview("Key Layer") { KeyLayerView(viewModel: KeyLayerViewModel.preview()) }
#endif

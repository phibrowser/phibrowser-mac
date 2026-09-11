import SwiftUI

/// Hosts the whole key-layer flow in one view, switching sub-views on the view model's
/// phase. Calls `onFinish` once the flow completes so a hosting window can close.
struct KeyLayerView: View {
    @ObservedObject var viewModel: KeyLayerViewModel
    /// The shared sync key controller, needed only for the `.pairingProfiles`
    /// phase (to apply decisions and re-resolve mappings). nil when the
    /// caller has no controller to hand over — the pairing phase then falls
    /// back to an error message rather than crashing.
    var controller: SyncKeyController? = nil
    var onFinish: () -> Void = {}

    /// `ProfilePairingView` 的两个 `@State` 已上提为 `@Binding`（§5.3），Devices pane
    /// 没有向导 VM，所以这里持那个最小的壳。
    @StateObject private var pairingSelections = ProfilePairingSelectionStore()

    /// Run-loop modes the deferred `onFinish()` may be delivered in.
    ///
    /// `.eventTracking` is deliberately absent: `onFinish()` closes the hosting
    /// window, and doing that from inside an AppKit mouse-tracking loop orphans
    /// that loop (the T17 step 0 hang — the tracking loop then spins forever
    /// waiting for a mouse-up its window can no longer deliver).
    ///
    /// `.modalPanel` is deliberately present: the profile-pairing gate parks the
    /// main run loop in `NSApp.runModal(for:)` (`AppModalPairingHost.present`), and
    /// on a second-device join that session is typically already up by the time
    /// `.done` renders — `resolveMappings()` posts `.phiProfileMappingsDidResolve`,
    /// which the gate observes, before `phase = .done` is assigned. A `.default`-only
    /// block would then wait for the whole modal session, leaving an empty "Set up
    /// sync" window on screen next to the gate. `.modalPanel` is not
    /// `.eventTracking`, so admitting it does not weaken the guarantee above.
    ///
    /// `.common` is not used: it would pull `.eventTracking` back in.
    static var finishDeliveryModes: [RunLoop.Mode] { [.default, .modalPanel] }

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
            case .pairingProfiles(let locals, let remotes):
                if let controller {
                    ProfilePairingView(viewModel: viewModel, locals: locals, remotes: remotes,
                                       selections: $pairingSelections.selections,
                                       remoteChoices: $pairingSelections.remoteChoices,
                                       onSubmit: { decisions in
                        Task { await viewModel.submitPairing(decisions, controller: controller) }
                    })
                    // 与今天 `ProfilePairingView.init` 的 `@State` 种子等价：那份种子在
                    // view 第一次构造时算一次，这里在它出现时算一次，并在候选表被重载
                    // （`applyPairingDecisions` 的失败路径）之后重新播种。
                    .onAppear { pairingSelections.seed(locals: locals, remotes: remotes) }
                    .onChange(of: locals.map(\.profileId)) { _ in
                        pairingSelections.seed(locals: locals, remotes: remotes)
                    }
                } else {
                    message(NSLocalizedString("Something went wrong", comment: "Key layer error - title"),
                            NSLocalizedString("Pairing isn’t available right now.",
                                comment: "Key layer - pairing phase reached with no controller to apply it"),
                            retry: false)
                }
            case .done:
                Color.clear.onAppear {
                    // Deferred by one run-loop pass, and kept out of
                    // `.eventTracking` specifically: delivering there would close
                    // the hosting window out from under an AppKit mouse-tracking
                    // loop. Every other mode the window can plausibly be closed
                    // in is allowed — see `finishDeliveryModes`.
                    RunLoop.main.perform(inModes: Self.finishDeliveryModes) {
                        MainActor.assumeIsolated { onFinish() }
                    }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 320)
        .onDisappear { viewModel.stopPolling() }
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

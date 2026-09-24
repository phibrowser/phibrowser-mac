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

    /// ProfilePairingView's two State values were lifted to Binding (§5.3). The Devices pane has no wizard VM,
    /// so owns this minimal selection store.
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
            case .idle, .working, .readyToPair:
                ProgressView().padding(48)
            case .introduction:
                VStack(alignment: .leading, spacing: 20) {
                    Text(NSLocalizedString("sync.setup.title", value: "Set up sync", comment: "Sync setup introduction title")).font(.title2.bold())
                    Text(NSLocalizedString("sync.setup.introduction", value: "Bring your Spaces, bookmarks, pinned tabs and supported browsing data to your other devices. Save a recovery code, then choose how this Mac joins your account.", comment: "Sync setup introduction explanation"))
                    Button(NSLocalizedString("sync.setup.continue", value: "Continue", comment: "Start sync setup")) {
                        Task { await viewModel.continueSetup() }
                    }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }.padding(32)
            case .showingRecoveryCode:
                RecoveryCodeDisplayView(viewModel: viewModel)
            case .enteringRecoveryCode:
                RecoveryCodeEntryView(viewModel: viewModel)
            case .chooseJoinMethod:
                JoinMethodChoiceView(viewModel: viewModel)
            case .waitingForApproval(let code, let deadline):
                WaitingForApprovalView(viewModel: viewModel, code: code, deadline: deadline)
            case .joinDenied:
                message(NSLocalizedString("sync.setup.joinDenied.title", value: "Request denied", comment: "Sync setup - title shown when another device denied this device's join request"),
                        NSLocalizedString("sync.setup.joinDenied.message", value: "The other device denied this request.", comment: "Sync setup - message shown when another device denied this device's join request"),
                        retry: true)
            case .joinExpired:
                message(NSLocalizedString("sync.setup.joinExpired.title", value: "Request expired", comment: "Sync setup - title shown when this device's join request timed out"),
                        NSLocalizedString("sync.setup.joinExpired.message", value: "This request timed out. You can try again.", comment: "Sync setup - message shown when this device's join request timed out"),
                        retry: true)
            case .error(let m):
                message(NSLocalizedString("sync.setup.error.title", value: "Something went wrong", comment: "Sync setup - title of the error page"), m,
                        retry: true, retryRoutesFromStart: true)
            case .pairingProfiles(let locals, let remotes):
                if let controller {
                    ProfilePairingView(viewModel: viewModel, locals: locals, remotes: remotes,
                                       selections: $pairingSelections.selections,
                                       remoteChoices: $pairingSelections.remoteChoices,
                                       onSubmit: { decisions in
                        Task { await viewModel.submitPairing(decisions, controller: controller) }
                    })
                    // Equivalent to ProfilePairingView.init's initial State seed: seed on appearance, then
                    // reseed after candidate reloads following applyPairingDecisions failure.
                    .onAppear { pairingSelections.seed(locals: locals, remotes: remotes) }
                    .onChange(of: locals.map(\.profileId)) { _ in
                        pairingSelections.seed(locals: locals, remotes: remotes)
                    }
                } else {
                    message(NSLocalizedString("sync.setup.error.title", value: "Something went wrong", comment: "Sync setup - title of the error page"),
                            NSLocalizedString("sync.setup.error.pairingUnavailable",
                                value: "Pairing isn’t available right now.",
                                comment: "Sync setup - error shown when profile matching cannot start on this device right now"),
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
    private func message(_ title: String, _ body: String, retry: Bool,
                         retryRoutesFromStart: Bool = false) -> some View {
        VStack(spacing: 24) {
            Text(title).font(.title2.bold()).themedForeground(.textPrimaryStrong)
            Text(body).font(.body).themedForeground(.textPrimary).multilineTextAlignment(.center)
            // A denied or expired request can only have come from the join flow, so
            // "another way" is the join-method choice. A generic error may come from
            // first-device setup, sign-in or reconfiguration; retry re-runs routing.
            if retry, retryRoutesFromStart {
                Button(NSLocalizedString("sync.setup.tryAgain", value: "Try again",
                                         comment: "Sync setup error screen - button that retries setup from the start")) {
                    Task { await viewModel.retrySetup() }
                }
                .buttonStyle(.borderedProminent)
            } else if retry {
                Button(NSLocalizedString("sync.setup.tryAnotherWay", value: "Try another way", comment: "Sync setup - button on a denied or expired join request page that returns to the join method choice")) {
                    viewModel.chooseJoinAgain()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
        .frame(minWidth: 360)
    }
}

/// The existing pairing host owns verification and matching in the same window.
struct SyncSetupView: View {
    @ObservedObject var keyModel: KeyLayerViewModel
    let wizard: PairingWizardViewModel
    let controller: SyncKeyController
    let onDismiss: () -> Void

    var body: some View {
        Group {
            if keyModel.phase == .readyToPair {
                PairingWizardView(viewModel: wizard, controller: controller, onDismiss: onDismiss)
                    .task {
                        wizard.shouldCompleteNewAccount = keyModel.createdAccountInThisFlow
                        await wizard.start(controller: controller)
                    }
            } else {
                KeyLayerView(viewModel: keyModel, controller: controller, onFinish: onDismiss)
                    .onExitCommand {
                        guard !keyModel.workingOperation, !keyModel.phase.requiresAcknowledgement else { return }
                        onDismiss()
                    }
            }
        }
        .frame(minWidth: 720, minHeight: 560)
    }
}

#if DEBUG
#Preview("Key Layer") { KeyLayerView(viewModel: KeyLayerViewModel.preview()) }
#endif

// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SwiftUI

/// Seam over the app-modal window so the gate's logic is testable without AppKit.
///
/// `controller` is OPTIONAL on purpose. The gate holds its controller weakly, so
/// it really can be nil in production (the controller is dropped on sign-out /
/// self-revoke while a notification is still in flight), and the gate's own unit
/// tests drive it with no controller at all. A `fatalError` on that branch would
/// be both a crash risk in the shipping app and an instant test-process abort.
/// The production host logs and does nothing; the fake records the call.
@MainActor
protocol ProfilePairingModalHost: AnyObject {
    func present(controller: SyncKeyController?)
    func dismiss()
    /// Re-drives the load behind a modal that is ALREADY up.
    ///
    /// Without it the window got exactly one load attempt for its whole life:
    /// `present` starts one, and every later announcement returned at the
    /// `isPresented` short circuit. A load that hangs -- the device-B case this
    /// exists for -- then leaves a spinner nothing can restart but the user.
    func reloadPresented()
}

extension ProfilePairingModalHost {
    /// Defaulted so a host that has nothing to re-drive (a test double, or any
    /// future non-window host) is not forced to implement it.
    func reloadPresented() {}
}

/// Owns durable account/device enrollment and explicit setup presentation.
/// Background mapping observations may dismiss a retired session, never open or complete one.
@MainActor
final class ProfilePairingGate {
    static let shared = ProfilePairingGate()

    static let enrollmentDefaultsKey = "sync.pairingEnrollment"
    private var enrollment = SyncPairingEnrollment()
    private(set) var enrollmentGeneration = UUID()
    var isPaired: Bool { enrollment.isPaired }

    func configureEnrollment(deviceKeyID: String, recordData: Data?,
                             saveRecord: @escaping (Data) -> Bool,
                             legacyEvidence: SyncPairingLegacyEvidence? = nil) throws {
        enrollmentGeneration = UUID()
        try enrollment.configure(deviceKeyID: deviceKeyID, recordData: recordData,
                                 saveRecord: saveRecord, legacyEvidence: legacyEvidence)
    }

    func beginEnrollment() throws {
        enrollmentGeneration = UUID()
        defer { NotificationCenter.default.post(name: .phiSyncPairingStateDidChange, object: self) }
        try enrollment.setPaired(false)
    }

    func completeEnrollment(verifiedDeviceKeyID: String? = nil) throws {
        try enrollment.setPaired(true, verifiedDeviceKeyID: verifiedDeviceKeyID)
        NotificationCenter.default.post(name: .phiSyncPairingStateDidChange, object: self)
    }

    var modalHost: ProfilePairingModalHost?

    private weak var controller: SyncKeyController?
    private var isPresented = false
    private var observers: [NSObjectProtocol] = []
    func start(controller: SyncKeyController?) {
        self.controller = controller
        guard observers.isEmpty else { return }
        // `queue: nil` on purpose: every poster of both notifications is already
        // `@MainActor`, so nil-queue delivery is synchronous on the main thread
        // (which keeps `MainActor.assumeIsolated` valid) and a caller that posts
        // and then reads the gate's state sees the effect, instead of racing an
        // operation queued for a later turn of the run loop.
        observers.append(NotificationCenter.default.addObserver(
            forName: .phiProfileMappingsDidResolve, object: nil, queue: nil
        ) { [weak self] note in
            MainActor.assumeIsolated {
                // A retired account's failed unlock can still announce .cleared.
                // Only the controller owning this session may dismiss its setup UI.
                guard let self, let c = note.object as? SyncKeyController,
                      c === self.controller else { return }
                // An announcement with no outcome reads as `.held`: the safe
                // direction, since `.held` is the one value that changes nothing.
                let outcome = (note.userInfo?[SyncKeyController.mappingsOutcomeKey] as? String)
                    .flatMap(SyncKeyController.MappingsOutcome.init(rawValue:)) ?? .held
                self.handleMappingsDidResolve(needsPairing: c.needsPairing,
                                              needsPairingActionable: c.needsPairingActionable,
                                              outcome: outcome, controllerRetired: c.isRetired)
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .phiProfileAutoCreateDidRun, object: nil, queue: nil
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.handleAutoCreateDidRun(note.userInfo) }
        })
    }

    func stop() {
        enrollmentGeneration = UUID()
        enrollment = SyncPairingEnrollment()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        if isPresented { modalHost?.dismiss(); isPresented = false }
    }

    /// Mapping updates never open or finish setup. Profile readiness alone says nothing
    /// about pending Space choices, and a deferred session stays deferred across refreshes.
    ///
    /// Only a RETIRED controller's `.cleared` takes the window down (sign-out, account
    /// switch, self-revoke). A live controller also announces `.cleared` whenever a
    /// background `silentUnlockAndResolve()` finds this device still unjoined or hits a
    /// network error -- exactly the state the join steps inside this window exist for.
    /// Dismissing then would withdraw a pending join request mid-approval and could
    /// drop a recovery code the user has not yet confirmed.
    func handleMappingsDidResolve(needsPairing: Bool, needsPairingActionable: Bool,
                                  outcome: SyncKeyController.MappingsOutcome = .measured,
                                  controllerRetired: Bool = false) {
        if outcome == .cleared, controllerRetired { finishLater() }
    }

    func handleAutoCreateDidRun(_ userInfo: [AnyHashable: Any]?) {}

    func requestPresentation(controller: SyncKeyController) {
        guard !controller.isRetired, !isPresented else { return }
        self.controller = controller
        isPresented = true
        modalHost?.present(controller: controller)
    }

    func finishLater() {
        guard isPresented else { return }
        isPresented = false
        modalHost?.dismiss()
        // Verification may have registered this device even when pairing was deferred.
        // Let the pane reload registration without announcing an enrollment change.
        NotificationCenter.default.post(name: .phiSyncSetupDidDismiss, object: self)
    }

}

extension Notification.Name {
    static let phiSyncSetupDidDismiss = Notification.Name("phiSyncSetupDidDismiss")
}

/// Production host: one closable setup window at modal-panel level. Closing or
/// Escape defers setup unless a confirmed write or recovery-code acknowledgement
/// is in progress. Unpaired data engines stay stopped while read-only previews run.
///
/// THE INVARIANT THAT PROMISE RESTS ON: a nested modal run loop must be entered
/// from a RUN-LOOP-NATIVE callout -- `RunLoop.main.perform(inModes:)`, i.e.
/// `CFRunLoopPerformBlock` -- and NEVER from inside a main-actor task or a
/// `DispatchQueue.main.async` block.
///
/// The main dispatch queue is serial and non-reentrant. A nested run loop
/// started from inside one of its blocks does not drain that queue again while
/// the outer block is still on the stack, so every main-actor continuation the
/// modal depends on -- its own load finishing, the engine's `@MainActor` hops,
/// any `Task.sleep` deadline -- is starved until `runModal` returns, and
/// `runModal` is waiting on exactly those continuations. That is a deadlock,
/// and it is what device B hit: `sample` caught the main thread in
/// `completeTaskWithClosure` -> `-[NSApplication runModalForWindow:]` ->
/// `nextEventMatchingMask` -> `mach_msg`, with the log silent from the moment
/// the window appeared. Deferring to "the next main-actor turn" does not help:
/// the next turn is another main-queue block.
///
/// Entered from the run loop itself, the main queue is idle when the nested
/// loop starts, so read-only previews and main-actor continuations can complete.
@MainActor
final class AppModalPairingHost: NSObject, ProfilePairingModalHost, NSWindowDelegate {
    /// Run-loop modes the modal session may be ENTERED in.
    ///
    /// The same set, for the same reason, as `KeyLayerView.finishDeliveryModes`:
    ///
    ///  * `.eventTracking` is deliberately absent. Entering `runModal` from
    ///    inside an AppKit mouse-tracking loop parks that loop underneath the
    ///    modal for the modal's whole user-bounded life, and the mouse-up that
    ///    would have ended tracking goes to the modal session instead -- the
    ///    T17 step 0 hang, one step worse.
    ///  * `.modalPanel` is deliberately present: `present` is reachable while
    ///    the Devices pane's key-layer window already has the run loop spinning
    ///    there, and a `.default`-only block would then wait for that window to
    ///    go away before the gate could ever open.
    ///  * `.common` is not used: it would pull `.eventTracking` back in.
    static let presentationModes: [RunLoop.Mode] = [.default, .modalPanel]

    /// Hands a block to the run loop. Injected so a test can assert that the
    /// session is SCHEDULED rather than entered on the caller's stack -- the
    /// one property this whole class exists to get right.
    private let scheduler: @MainActor (@escaping () -> Void) -> Void
    /// `NSApp.runModal(for:)` and `NSApp.stopModal()` in production; inert
    /// closures in tests, which must never park the test process in a modal
    /// loop nothing is left to stop.
    private let runModal: @MainActor (NSWindow) -> Void
    private let stopModal: @MainActor () -> Void
    /// The wizard view model's three external dependencies, injected here so
    /// `present()` never reaches for a singleton itself (see `init`).
    private let previewAccountSpaces: () async -> Result<[PhiAccountSpaceSummary], PhiSpacePreviewError>
    private let pairableLocalSpaces: () -> [PhiLocalSpace]
    private let themeDisplayName: (String) -> String?

    /// True for exactly as long as THIS host's `runModal` call is on the stack.
    ///
    /// `NSApp.stopModal()` is process-wide: it ends whatever modal session is
    /// running, which need not be ours. Between `present` and the run loop's
    /// callout there is no session of ours at all, so a `dismiss()` landing in
    /// that window must not call it.
    private var sessionActive = false

    private var window: NSWindow?
    /// The live modal's view model and the controller it was presented for, so
    /// `reloadPresented()` has both halves of `start(controller:)`.
    ///
    /// Weak on purpose, and safe for as long as the window is up: the view model
    /// is retained by `PairingWizardView`'s `@StateObject` inside the hosting
    /// controller `window` holds (`StateObject(wrappedValue:)` captures it
    /// strongly in the root view), and the controller is owned by the key layer
    /// (the gate itself only holds it weakly). Both are cleared in `dismiss()`
    /// alongside `window`.
    ///
    /// The setter stays private -- `present()` and `dismiss()` are still its
    /// only two writers, and `private(set)` is what makes the compiler say so --
    /// but the getter is internal so a test can drive the wizard the user drives
    /// (§10.7 case 1 presses Continue for real).
    private(set) weak var viewModel: PairingWizardViewModel?
    private weak var presentedController: SyncKeyController?
    private var setupModel: KeyLayerViewModel?

    /// Every seam has a production default, preserving AppModalPairingHost() as the application's sole
    /// construction call in PhiChromiumCoordinator.
    ///
    /// The last three are M3-2b wizard dependencies. Inject here rather than inside present so
    /// ProfilePairingGateTests do not initialize PhiChromiumCoordinator.shared and AccountController.shared.
    /// Otherwise singleton coupling would merely move from VM to host.
    init(scheduler: @escaping @MainActor (@escaping () -> Void) -> Void = { block in
             RunLoop.main.perform(inModes: AppModalPairingHost.presentationModes) { block() }
         },
         runModal: @escaping @MainActor (NSWindow) -> Void = { NSApp.runModal(for: $0) },
         stopModal: @escaping @MainActor () -> Void = { NSApp.stopModal() },
         previewAccountSpaces: @escaping () async -> Result<[PhiAccountSpaceSummary], PhiSpacePreviewError>
             = { await PhiChromiumCoordinator.shared.previewAccountSpaces() },
         // Use nonisolated closures because themeDisplayName is passed to the pure SpaceOverwriteDiff.diffs
         // and cannot be MainActor-isolated. Only the MainActor wizard VM calls them, so assumeIsolated is
         // valid.
         pairableLocalSpaces: @escaping () -> [PhiLocalSpace]
             = { MainActor.assumeIsolated { PhiChromiumCoordinator.shared.pairableLocalSpaces() } },
         themeDisplayName: @escaping (String) -> String?
             = { id in MainActor.assumeIsolated { ThemeManager.shared.registeredThemes[id]?.name } }) {
        self.scheduler = scheduler
        self.runModal = runModal
        self.stopModal = stopModal
        self.previewAccountSpaces = previewAccountSpaces
        self.pairableLocalSpaces = pairableLocalSpaces
        self.themeDisplayName = themeDisplayName
        super.init()
    }

    func present(controller: SyncKeyController?) {
        // No controller means the key layer has already been torn down (sign-out
        // or self-revoke, with a notification still in flight). There is nothing
        // to pair against, so blocking the browser would be strictly worse than
        // doing nothing; the next `.phiProfileMappingsDidResolve` from a fresh
        // controller presents properly.
        guard let controller else {
            AppLogWarn("[phi-sync] pairing gate asked to present with no key controller; ignoring")
            return
        }
        guard window == nil else { return }
        let viewModel = PairingWizardViewModel(
            keyLayer: KeyLayerViewModel(manager: controller.manager),
            previewAccountSpaces: previewAccountSpaces,
            pairableLocalSpaces: pairableLocalSpaces,
            themeDisplayName: themeDisplayName)
        let setup = KeyLayerViewModel(manager: controller.manager)
        self.setupModel = setup
        let root = SyncSetupView(keyModel: setup, wizard: viewModel, controller: controller,
                                 onDismiss: { [weak self] in self?.deferSetup() })
        let window = NSWindow(contentViewController: ThemedHostingController(rootView: root))
        // Keep the window nonclosable. Resizing may enlarge it, but cannot shrink below 720×560.
        window.styleMask = [.titled, .closable, .resizable]
        window.delegate = self
        window.title = NSLocalizedString("sync.setup.windowTitle",
                                         value: "Finish setting up sync",
                                         comment: "Sync setup - window title")
        window.level = .modalPanel
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 720, height: 560))
        window.contentMinSize = NSSize(width: 720, height: 560)
        window.center()
        self.window = window
        self.viewModel = viewModel
        self.presentedController = controller
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        Task { @MainActor in await setup.beginSetup(controller: controller) }
        // ONLY the modal session is deferred; everything above stays
        // synchronous. `dismiss()`, `reloadPresented()` and the `window == nil`
        // re-entrancy guard all read state this method just wrote, so deferring
        // the window build too would let a `dismiss()` arriving in between
        // return early and leave the session to open an app-modal window with
        // nothing alive to close it.
        //
        // `NSApp.runModal(for:)` does not return until `stopModal()`, i.e. until
        // the user finishes pairing or removes this device. The hysteresis safety
        // net reaches here from INSIDE an engine round: `PhiSyncEngine.pull()`
        // awaits `refreshAccountProfiles()` -> `SyncKeyController.finishRefresh`,
        // which posts `.phiProfileAutoCreateDidRun` synchronously, and the gate
        // observes that notification with `queue: nil`. So this line runs on a
        // main-actor stack, i.e. inside a main-queue block -- and a nested run
        // loop entered from there never drains that queue again (see the class
        // comment). `scheduler` hands the session to the run loop itself
        // instead, which runs it once the poster's block has returned and the
        // main queue is idle; the nested loop then drains the queue, so the
        // round's suspended continuation, the load's own continuations and the
        // engine's later hops all resume WHILE the window is up.
        //
        // The identity check makes a `dismiss()` that lands before the callout
        // a no-op rather than a session started after its own dismissal.
        scheduler { [weak self, weak window] in
            MainActor.assumeIsolated {
                guard let self, let window, self.window === window else { return }
                // Metadata only (R12). If the "ends" line never follows on a
                // device that closed the modal, the main actor was starved
                // under the session and this invariant has been broken again.
                AppLogInfo("[phi-sync] pairing modal session begins")
                self.sessionActive = true
                self.runModal(window)
                self.sessionActive = false
                AppLogInfo("[phi-sync] pairing modal session ends")
            }
        }
    }

    /// Re-drive rescues stuck loading, not refreshes user input (R-D6-11). Allow only loading and
    /// error/reload; reject profiles, spaces, confirmOverwrite, submitting and done.
    /// Confirmation is interactive and must retain
    /// differences/selections; error/backToSpaces also holds completed step-2 choices. Reusing KeyLayerPhase's
    /// broad error rule would call start each minute and erase that state.
    static func reloadAllowed(for phase: PairingWizardPhase) -> Bool {
        switch phase {
        case .loading: return true
        case .error(_, let resume): return resume == .reload
        case .profiles, .spaces, .confirmOverwrite, .submitting, .done: return false
        }
    }

    /// Restarts the load behind the window that is already up.
    ///
    /// **What actually makes repeated re-drives safe, stated precisely, because
    /// the obvious claim is false.** `keyLayer.startPairing` does cancel its own
    /// in-flight profile load, but the Space preview underneath `start()` cannot
    /// be cancelled at all: `PhiSyncEngine.serialized(_:)` runs the round in an
    /// unstructured `Task {}`, which inherits neither cancellation nor its
    /// caller's lifetime. So a re-drive CAN leave an earlier preview round still
    /// running on the engine's serial queue. Two things keep that harmless:
    ///
    ///  - the abandoned round persists nothing (§4.3) and bounds itself
    ///    (`PhiSyncEngine.previewDeadlineMs`), so it frees the queue on its own;
    ///  - `PairingWizardViewModel.start()` carries a GENERATION token, so a
    ///    superseded run writes nothing at all when it finally lands — it can
    ///    neither flash a stale `.error` over a good page nor wipe selections the
    ///    user has already made.
    ///
    /// In practice a second load is rare: the wizard's own deadline moves a stuck
    /// load to `.error(_, .reload)` at 45 s, before the gate's ~60 s re-drive.
    func reloadPresented() {
        guard let viewModel, let presentedController else { return }
        guard Self.reloadAllowed(for: viewModel.phase) else {
            // Metadata only (R12).
            AppLogInfo("[phi-sync] pairing modal re-drive skipped; the user is choosing pairings")
            return
        }
        Task { @MainActor in await viewModel.start(controller: presentedController) }
    }

    private func deferSetup() {
        guard setupModel?.workingOperation != true,
              setupModel?.phase.requiresAcknowledgement != true,
              viewModel?.leaveWithoutApplying() != false else { return }
        ProfilePairingGate.shared.finishLater()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        deferSetup()
        return false
    }

    func dismiss() {
        guard let window else { return }
        setupModel?.cancelFlow()
        setupModel = nil
        _ = viewModel?.leaveWithoutApplying()
        // `window` is cleared first, so a session that has been scheduled but
        // not yet entered bails on the identity check in `present`.
        self.window = nil
        self.viewModel = nil
        self.presentedController = nil
        // And `sessionActive` is what keeps a dismissal that arrives BEFORE the
        // run loop's callout from calling a process-wide `stopModal()` that
        // would end some other component's modal session instead of ours.
        if sessionActive {
            sessionActive = false
            stopModal()
        }
        window.close()
    }
}

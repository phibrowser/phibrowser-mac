import AppKit
import XCTest
@testable import Phi

@MainActor
final class ProfilePairingGateTests: XCTestCase {
    typealias FakeAPI = AccountKeyManagerTests.FakeAPI
    typealias FakeDeviceKeyProvider = AccountKeyManagerTests.FakeDeviceKeyProvider
    typealias MemoryMappingStore = ProfileKeyManagerTests.MemoryMappingStore
    typealias Box = ProfileAutoCreateTests.Box

    /// Records the modal lifecycle so the gate can be asserted without AppKit.
    /// The controller is optional, which is what lets every case below run
    /// `start(controller: nil)` without building a key stack.
    final class FakeModalHost: ProfilePairingModalHost {
        private(set) var presentCount = 0
        private(set) var dismissCount = 0
        private(set) var reloadCount = 0
        private(set) var lastPresentedController: SyncKeyController?
        func present(controller: SyncKeyController?) {
            presentCount += 1
            lastPresentedController = controller
        }
        func dismiss() { dismissCount += 1 }
        func reloadPresented() { reloadCount += 1 }
    }

    /// A real, never-unlocked controller can post announcement variants through
    /// NotificationCenter without a key stack. The first new case needs access to the
    /// mapping store to assert zero Space writes. Default nil preserves spaceKeys == nil
    /// and leaves existing callers unchanged.
    private func makeController(spaceStore: SpaceSyncMappingStore? = nil) -> SyncKeyController {
        makeController(api: FakeAPI(), provider: FakeDeviceKeyProvider(), spaceStore: spaceStore)
    }

    /// A controller over a caller-supplied fake API (and, optionally, a seeded
    /// mapping store), so a case can drive REAL `resolveMappings()` passes --
    /// the bail-outs included -- instead of calling the handler by hand.
    private func makeController(api: FakeAPI, provider: FakeDeviceKeyProvider,
                                locals: [(profileId: String, displayName: String)] = [],
                                store: ProfileSyncMappingStore = MemoryMappingStore(),
                                spaceStore: SpaceSyncMappingStore? = nil) -> SyncKeyController {
        let mgr = AccountKeyManager(api: api, deviceKeyProvider: provider)
        return SyncKeyController(
            manager: mgr,
            approvals: DeviceApprovalService(api: api, keyManager: mgr, deviceKeyProvider: provider),
            profileKeys: ProfileKeyManager(api: api, keyManager: mgr, mappingStore: store),
            spaceKeys: spaceStore.map { SpaceSyncMappingManager(store: $0) },
            localProfilesProvider: { locals },
            notifyChromium: {})
    }

    private func makeGate(host: FakeModalHost) -> ProfilePairingGate {
        let gate = ProfilePairingGate()
        gate.modalHost = host
        return gate
    }

    private func autoCreateNotification(outcome: String, created: Int, skipped: Int) {
        NotificationCenter.default.post(
            name: .phiProfileAutoCreateDidRun, object: nil,
            userInfo: ["outcome": outcome, "created": created, "skippedUuids": skipped])
    }

    func testBackgroundUpdatesNeverPresentOrCompleteEnrollment() throws {
        let host = FakeModalHost()
        let gate = makeGate(host: host)
        try gate.configureEnrollment(deviceKeyID: "device", recordData: nil, saveRecord: { _ in true })
        try gate.beginEnrollment()
        gate.start(controller: makeController())
        for _ in 0..<10 {
            gate.handleMappingsDidResolve(needsPairing: true, needsPairingActionable: true)
            gate.handleAutoCreateDidRun(["outcome": "unchanged", "created": 0, "skippedUuids": 0])
        }
        gate.handleMappingsDidResolve(needsPairing: false, needsPairingActionable: false)
        XCTAssertFalse(gate.isPaired)
        XCTAssertEqual(host.presentCount, 0)
        gate.stop()
    }

    func testExplicitReentryCreatesAnotherSessionAfterLater() throws {
        let host = FakeModalHost()
        let gate = makeGate(host: host)
        let controller = makeController()
        try gate.configureEnrollment(deviceKeyID: "device", recordData: nil, saveRecord: { _ in true })
        try gate.beginEnrollment()
        gate.requestPresentation(controller: controller)
        gate.requestPresentation(controller: controller)
        XCTAssertEqual(host.presentCount, 1)
        gate.finishLater()
        XCTAssertFalse(gate.isPaired)
        gate.requestPresentation(controller: controller)
        XCTAssertEqual(host.presentCount, 2)
    }

    func testRetryIsOfferedInEveryPhaseTheStatusViewCanRender() {
        for phase in [PairingWizardPhase.loading, .submitting, .done,
                      .error(message: "boom", resume: .reload)] {
            XCTAssertTrue(PairingWizardView.retryEnabled(for: phase, isSubmitting: false),
                          "retry must stay pressable in \(phase)")
        }
    }

    /// The one exception, and it is not about the phase at all: while the
    /// wizard is applying decisions (`isApplying`) it is mutating the mapping
    /// table a fresh load would read, so pressing retry would start a second,
    /// uncoordinated writer of the same state. The button greys for that
    /// window only -- a stalled LOAD is still restartable, which is the defect
    /// this predicate exists to fix.
    func testRetryIsWithheldOnlyWhileASubmitIsInFlight() {
        for phase in [PairingWizardPhase.loading, .submitting, .done,
                      .error(message: "boom", resume: .reload)] {
            XCTAssertFalse(PairingWizardView.retryEnabled(for: phase, isSubmitting: true),
                           "retry must not start a load on top of a submit in \(phase)")
        }
    }

    // MARK: - The modal session must be entered from the run loop (task 21)

    /// Stands in for AppKit's modal machinery so a case can assert on HOW the
    /// session is entered. A real `NSApp.runModal(for:)` here would park the
    /// test process in a modal loop with nothing left to stop it.
    @MainActor
    final class ModalSessionRecorder {
        /// What the host handed to its scheduler instead of running inline.
        private(set) var scheduled: [() -> Void] = []
        private(set) var runModalCount = 0
        private(set) var stopModalCount = 0
        /// Run from INSIDE the fake session, which is where every real
        /// `dismiss()` comes from: the only UI that can close this window lives
        /// in the window itself and is driven by the nested run loop.
        var whileModalIsUp: (@MainActor () -> Void)?

        func schedule(_ block: @escaping () -> Void) { scheduled.append(block) }

        func runModal(_ window: NSWindow) {
            runModalCount += 1
            whileModalIsUp?()
        }

        func stopModal() { stopModalCount += 1 }

        /// Drains what the run loop would have called out to on its next turn.
        func runScheduled() {
            let blocks = scheduled
            scheduled.removeAll()
            blocks.forEach { $0() }
        }
    }

    /// Stub all three new seams from Step 7(e). Otherwise host.present reaches
    /// PhiChromiumCoordinator.shared and AccountController.shared. Gate tests currently
    /// avoid all singletons, and the wizard must preserve that isolation.
    private func makeHost(
        _ recorder: ModalSessionRecorder,
        previewAccountSpaces: @escaping () async -> Result<[PhiAccountSpaceSummary], PhiSpacePreviewError>
            = { .success([]) },
        pairableLocalSpaces: @escaping () -> [PhiLocalSpace] = { [] }
    ) -> AppModalPairingHost {
        AppModalPairingHost(scheduler: { recorder.schedule($0) },
                            runModal: { recorder.runModal($0) },
                            stopModal: { recorder.stopModal() },
                            previewAccountSpaces: previewAccountSpaces,
                            pairableLocalSpaces: pairableLocalSpaces,
                            themeDisplayName: { _ in nil })
    }

    /// The device-B deadlock in one assertion. `present` is reached from a
    /// main-actor task (the gate observes `.phiProfileMappingsDidResolve` with
    /// `queue: nil`, on the poster's stack), and the main dispatch queue is
    /// serial and non-reentrant: a nested run loop started from inside one of
    /// its blocks never drains it again, so every main-actor continuation the
    /// modal is waiting for -- its own load, the engine's hops, `Task.sleep` --
    /// starves until the modal returns, and the modal is waiting on them.
    /// Handing the session to the run loop is what breaks that cycle.
    func testTheModalSessionIsScheduledOnTheRunLoopInsteadOfEnteredInline() {
        let recorder = ModalSessionRecorder()
        let host = makeHost(recorder)
        host.present(controller: makeController())

        XCTAssertEqual(recorder.runModalCount, 0,
                       "the session must not be entered on the caller's stack")
        XCTAssertEqual(recorder.scheduled.count, 1,
                       "it has to be handed to the run loop instead")

        recorder.runScheduled()
        XCTAssertEqual(recorder.runModalCount, 1,
                       "and the run loop's own callout is what enters it")
        host.dismiss()
    }

    /// Only the SESSION is deferred. The window, the view model and the
    /// controller are still set synchronously, so a `dismiss()` that lands in
    /// between finds them -- and the deferred session then finds its window
    /// gone and bails, rather than opening an app-modal window with nothing
    /// left alive to close it.
    func testAnImmediateDismissCancelsTheSessionThatHasNotStartedYet() {
        let recorder = ModalSessionRecorder()
        let host = makeHost(recorder)
        host.present(controller: makeController())
        host.dismiss()

        XCTAssertEqual(recorder.stopModalCount, 0,
                       "stopping a session this host never started would stop somebody else's")
        recorder.runScheduled()
        XCTAssertEqual(recorder.runModalCount, 0,
                       "the deferred session must not open a window that was already dismissed")
    }

    /// `stopModal()` is process-wide: it ends whatever modal session is on the
    /// stack, which need not be this host's. So it is gated on this host's own
    /// session actually being up.
    func testDismissStopsTheSessionOnlyWhileItIsUp() {
        let recorder = ModalSessionRecorder()
        var host: AppModalPairingHost?
        recorder.whileModalIsUp = { host?.dismiss() }
        host = makeHost(recorder)
        host?.present(controller: makeController())
        recorder.runScheduled()

        XCTAssertEqual(recorder.runModalCount, 1)
        XCTAssertEqual(recorder.stopModalCount, 1,
                       "a dismissal from inside the modal has to end the session")

        host?.dismiss()
        XCTAssertEqual(recorder.stopModalCount, 1,
                       "a second dismissal has no session of its own left to stop")
    }

    func testAHostThatNeverPresentedNeverStopsAModal() {
        let recorder = ModalSessionRecorder()
        makeHost(recorder).dismiss()
        XCTAssertEqual(recorder.stopModalCount, 0)
    }

    /// The other half of the fix, and the same rule `KeyLayerView` already
    /// pins: a nested modal loop must never be entered from inside an AppKit
    /// mouse-tracking loop, which would be parked underneath it for the
    /// modal's whole user-bounded life.
    func testTheModalSessionIsNeverEnteredFromAMouseTrackingLoop() {
        let modes = AppModalPairingHost.presentationModes
        XCTAssertTrue(modes.contains(.default),
                      "the session must start on a normal run-loop pass")
        XCTAssertTrue(modes.contains(.modalPanel),
                      "`present` is reachable while the Devices pane's key-layer window "
                      + "already has the run loop spinning in `.modalPanel`")
        XCTAssertFalse(modes.contains(.eventTracking),
                       "a modal session must never be entered from a mouse-tracking loop")
        XCTAssertFalse(modes.contains(.common),
                       "`.common` would pull `.eventTracking` back in")
    }

    // MARK: - A re-drive must not throw away a form the user is filling in

    /// The gate re-drives a presented modal on every measured pass; resolveMappings runs
    /// about once a minute. Refreshing an interactive form would replace its list and
    /// discard user selections. Re-drive rescues a stalled load, not an interactive form.
    ///
    /// 2. Reject measured re-drive in every interactive phase; allow only loading and
    /// error(_, .reload). Test both error resume values because they share a case but
    /// require opposite outcomes; one assertion would miss the dangerous branch.
    func testARedriveIsRefusedInEveryInteractivePhase() {
        let input = SpacePairingModel.Input(locals: [], accountSpaces: [],
                                            localProfileNames: [:], accountProfileNames: [:])
        let interactive: [PairingWizardPhase] = [
            .profiles(locals: [], remotes: []),
            .spaces(input),
            .confirmOverwrite([SpaceOverwriteDiff(localSpaceId: "A", spaceName: "Work",
                                                  spaceIconName: "phi:a",
                                                  changes: [.init(field: .name,
                                                                  local: .text("Job"),
                                                                  account: .text("Work"))])]),
            .submitting,
            .done,
            .error(message: "boom", resume: .backToSpaces)
        ]
        for phase in interactive {
            XCTAssertFalse(AppModalPairingHost.reloadAllowed(for: phase),
                           "\(phase) contains user selections that a re-drive would erase")
        }
        XCTAssertTrue(AppModalPairingHost.reloadAllowed(for: .loading))
        XCTAssertTrue(AppModalPairingHost.reloadAllowed(for: .error(message: "boom", resume: .reload)))
    }

    // MARK: - Wizard (M3-2b §10.7)

    /// 1. The window survives step 1: actually press Continue, with no stopModal call.
    /// Submitting in step 1 would tear down the modal between steps and clear
    /// joinPairingPending, letting this Mac publish before the user makes Space decisions.
    ///
    /// Merely calling present then checking stopModalCount == 0 cannot catch the broken
    /// Continue → submitPairing → clear gate → resolveMappings → dismiss path. Together
    /// assert an active session, a closed gate, and zero Space mapping writes.
    func testTheWindowSurvivesStepOne() async throws {
        try ProfilePairingGate.shared.configureEnrollment(deviceKeyID: "test-device", recordData: nil, saveRecord: { _ in true })
        let recorder = ModalSessionRecorder()
        let spaceStore = PairingWizardViewModelTests.LedgerSpaceMappingStore()
        let host = makeHost(recorder,
                            previewAccountSpaces: { .success([]) },
                            pairableLocalSpaces: { [] })
        let controller = makeController(spaceStore: spaceStore)
        host.present(controller: controller)
        recorder.runScheduled()

        // present starts loading in a Task. Drive start() again directly: it is idempotent
        // because keyLayer.startPairing cancels the in-flight load, and an extra reload
        // cannot affect the three no-side-effect assertions below.
        let wizard = try XCTUnwrap(host.viewModel)
        await wizard.start(controller: controller)
        wizard.continueToSpaces()

        XCTAssertEqual(recorder.stopModalCount, 0, "Step 1 Continue does not invoke a host exit")
        XCTAssertFalse(ProfilePairingGate.shared.isPaired, "The gate must stay closed")
        XCTAssertTrue(spaceStore.map.isEmpty, "No Space mappings have been written")

        // Executable window-lifetime check: the host clears its weak viewModel only in dismiss().
        XCTAssertNotNil(host.viewModel, "The window must survive step 1")
        host.dismiss()
        XCTAssertNil(host.viewModel)
    }

    /// 4. T21: present still schedules the modal session instead of entering it on the
    /// caller's stack; retain the existing assertion through the wizard change.
    func testTheModalSessionIsStillScheduledAfterTheWizardLanded() {
        let recorder = ModalSessionRecorder()
        let host = makeHost(recorder)
        host.present(controller: makeController())
        XCTAssertEqual(recorder.runModalCount, 0)
        recorder.runScheduled()
        XCTAssertEqual(recorder.runModalCount, 1)
    }
}

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

    /// A real, never-unlocked controller: enough to post the announcement
    /// variants through `NotificationCenter` without a key stack.
    /// 第 1 条新用例要断言「Space 映射一条没写」，所以那条用例要能拿到映射 store。
    /// 默认 `nil` = 今天的行为（`spaceKeys == nil`），既有调用点一个不改。
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

    // MARK: - Presentation predicate (§3.2)

    func testTheGateDoesNotPresentAfterTheJoinIsFinished() async throws {
        let host = FakeModalHost()
        let gate = makeGate(host: host)
        gate.joinPairingPendingOverride = false
        gate.start(controller: nil)
        for _ in 0..<5 {
            gate.handleMappingsDidResolve(needsPairing: true, needsPairingActionable: true)
        }
        XCTAssertEqual(host.presentCount, 0,
                       "run-time needsPairing must never interrupt the browser (D3 second revision)")
    }

    func testTheGatePresentsDuringAJoinAndClosesWhenPairingCompletes() {
        let host = FakeModalHost()
        let gate = makeGate(host: host)
        gate.joinPairingPendingOverride = true
        gate.start(controller: nil)
        gate.handleMappingsDidResolve(needsPairing: true, needsPairingActionable: true)
        XCTAssertEqual(host.presentCount, 1)

        gate.handleMappingsDidResolve(needsPairing: false, needsPairingActionable: false)
        XCTAssertEqual(host.dismissCount, 1)
        XCTAssertFalse(gate.joinPairingPendingOverride!)
    }

    func testAnUndecryptableRemoteAloneNeverPresents() {
        let host = FakeModalHost()
        let gate = makeGate(host: host)
        gate.joinPairingPendingOverride = true
        gate.start(controller: nil)
        // needsPairing true, but nothing the user can decide.
        gate.handleMappingsDidResolve(needsPairing: true, needsPairingActionable: false)
        XCTAssertEqual(host.presentCount, 0)
    }

    /// The same pass, one step further: it must also RETIRE the join, with no
    /// window ever up. `submitPairing` sets `sync.joinPairingPending`
    /// unconditionally -- the Devices pane included -- and an account profile
    /// whose envelope will not open keeps `needsPairing` true forever while
    /// `needsPairingActionable` stays false. §3.2 says that class never presents
    /// a modal, so the flag would have no other way out: §3.5's Space gate reads
    /// it, and it would stay shut for good (no Space pull, no Space publish,
    /// `ensureLocalProfilesForAccount` skipped every round) with no UI to say why.
    func testAnUnactionablePairingRetiresTheJoinWithNoWindowUp() {
        let host = FakeModalHost()
        let gate = makeGate(host: host)
        gate.joinPairingPendingOverride = true
        gate.start(controller: nil)
        defer { gate.stop() }
        gate.handleMappingsDidResolve(needsPairing: true, needsPairingActionable: false)
        XCTAssertEqual(host.presentCount, 0, "this class of remote must never present")
        XCTAssertFalse(gate.joinPairingPendingOverride!,
                       "an unactionable pairing must not wedge the Space gate shut")
    }

    func testFalsePredicatesCloseTheModal() {
        let host = FakeModalHost()
        let gate = makeGate(host: host)
        gate.joinPairingPendingOverride = true
        gate.start(controller: nil)
        gate.handleMappingsDidResolve(needsPairing: true, needsPairingActionable: true)
        gate.handleMappingsDidResolve(needsPairing: false, needsPairingActionable: false)
        XCTAssertEqual(host.dismissCount, 1)
    }

    /// The lock / teardown exit, driven through a REAL controller rather than by
    /// calling the handler by hand: `clearResolved()` is the one writer that
    /// flips both predicates false with no `resolveMappings()` pass behind it
    /// (`silentUnlockAndResolve` returns immediately after it), so if it does not
    /// announce, the app-modal window stays up against a controller whose key
    /// layer is gone.
    ///
    /// The window closes; the JOIN does not end. Those false predicates mean
    /// "unknown", and the pairing this join still owes is unchanged by a lock.
    func testClearResolvedClosesTheModalButKeepsTheJoinPending() async throws {
        let controller = makeController()
        let host = FakeModalHost()
        let gate = makeGate(host: host)
        gate.joinPairingPendingOverride = true
        gate.start(controller: controller)
        defer { gate.stop() }
        gate.handleMappingsDidResolve(needsPairing: true, needsPairingActionable: true)
        XCTAssertEqual(host.presentCount, 1)

        controller.clearResolved()   // ARK locked / controller torn down mid-join
        XCTAssertEqual(host.dismissCount, 1,
                       "clearResolved must announce, or the window stays up over a dead key layer")
        XCTAssertTrue(gate.joinPairingPendingOverride!,
                      "a lock is not a finished join -- only a real pass may retire the flag")
    }

    /// The offline-relaunch case, which is the one that silently disarms the gate
    /// forever if a cleared announcement is read as a resolution: the join set
    /// `sync.joinPairingPending`, the app relaunches, `unlockAtStartup()` throws
    /// because the machine is still offline, and `silentUnlockAndResolve()` calls
    /// `clearResolved()` before any pass has ever run. Nothing is presented, so
    /// there is no window to dismiss -- the only thing at stake is the flag.
    func testAClearedAnnouncementKeepsTheFlagAndALaterResolveStillPresents() async throws {
        let controller = makeController()
        let host = FakeModalHost()
        let gate = makeGate(host: host)
        gate.joinPairingPendingOverride = true
        gate.start(controller: controller)
        defer { gate.stop() }

        controller.clearResolved()   // offline seconds after launch
        XCTAssertEqual(host.presentCount, 0)
        XCTAssertEqual(host.dismissCount, 0, "nothing was presented, so nothing to dismiss")
        XCTAssertTrue(gate.joinPairingPendingOverride!,
                      "an unknown pairing picture must not retire sync.joinPairingPending")

        // Network back, ARK unlocked, and the pre-existing profiles on both sides
        // are still unmatched: the modal has to appear now or never.
        gate.handleMappingsDidResolve(needsPairing: true, needsPairingActionable: true)
        XCTAssertEqual(host.presentCount, 1)
    }

    /// The same hazard as the case above, reached through its sibling path: a pass
    /// that RUNS but measures nothing. The join set `sync.joinPairingPending`, the
    /// app relaunches, `unlockAtStartup()` goes through -- and the very next
    /// network call, the account listing, hits a flap. Both predicates are still
    /// their initial `false`, so an announcement that looked like a real pass
    /// would read as "nothing left to pair" and retire the flag for good.
    func testAHeldPassKeepsTheFlagAndALaterMeasuredPassStillPresents() async throws {
        let api = FakeAPI()
        let provider = FakeDeviceKeyProvider()
        _ = try await AccountKeyManager(api: api, deviceKeyProvider: provider).bootstrap()
        // A profile the account held before this device joined: precisely what the
        // modal exists for, and the one thing no machine can match on its own.
        api.profileEnvelopes["stranger"] = Data([0x00, 0x01])
        let controller = makeController(api: api, provider: provider)

        let host = FakeModalHost()
        let gate = makeGate(host: host)
        gate.joinPairingPendingOverride = true
        gate.start(controller: controller)
        defer { gate.stop() }

        struct Offline: Error {}
        api.listProfilesError = Offline()
        await controller.silentUnlockAndResolve()   // unlock fine, listing flaps
        XCTAssertFalse(controller.needsPairing, "the bail-out holds the initial answer")
        XCTAssertEqual(host.presentCount, 0)
        XCTAssertTrue(gate.joinPairingPendingOverride!,
                      "a pass that measured nothing must not retire sync.joinPairingPending")

        // Connectivity settles, and the first pass that actually looks at the
        // account reports the truth.
        api.listProfilesError = nil
        await controller.resolveMappings()
        XCTAssertTrue(controller.needsPairingActionable)
        XCTAssertEqual(host.presentCount, 1,
                       "the modal must still be offered once a real pass can see the account")
    }

    /// The other undecidable path into the same announcement: the account listing
    /// is healthy, but a LOCAL profile's own lookup throws, which poisons the
    /// register/adopt decision for every local and holds both predicates.
    func testAnUnknownLocalHoldsTheFlagToo() async throws {
        let api = FakeAPI()
        let provider = FakeDeviceKeyProvider()
        let mgr = AccountKeyManager(api: api, deviceKeyProvider: provider)
        _ = try await mgr.bootstrap()
        let store = MemoryMappingStore()
        let pkm = ProfileKeyManager(api: api, keyManager: mgr, mappingStore: store)
        _ = try await pkm.registerLocalProfile(profileId: "Default", displayName: "Default")
        // A second account profile with no local counterpart, so a MEASURED pass
        // here is actionable.
        _ = try await pkm.registerLocalProfile(profileId: "temp", displayName: "Work")
        store.removeMapping(forProfileId: "temp")
        let controller = makeController(api: api, provider: provider,
                                        locals: [(profileId: "Default", displayName: "Default")],
                                        store: store)

        let host = FakeModalHost()
        let gate = makeGate(host: host)
        gate.joinPairingPendingOverride = true
        gate.start(controller: controller)
        defer { gate.stop() }

        api.profileEndpointError = KeyAPIError.http(503, "")
        await controller.silentUnlockAndResolve()   // "Default" is UNKNOWN, not unmapped
        XCTAssertFalse(controller.needsPairing, "an unknown local holds the previous answer")
        XCTAssertEqual(host.presentCount, 0)
        XCTAssertTrue(gate.joinPairingPendingOverride!,
                      "an unmeasured pass leaves the join exactly as it found it")

        api.profileEndpointError = nil
        await controller.resolveMappings()
        XCTAssertTrue(controller.needsPairingActionable)
        XCTAssertEqual(host.presentCount, 1)
    }

    /// The other half of the same distinction: a REAL pass that finds nothing left
    /// to pair still ends the join, so the modal does not come back next launch.
    func testARealResolveWithNothingLeftToPairRetiresTheFlag() {
        let host = FakeModalHost()
        let gate = makeGate(host: host)
        gate.joinPairingPendingOverride = true
        gate.start(controller: nil)
        defer { gate.stop() }
        gate.handleMappingsDidResolve(needsPairing: false, needsPairingActionable: false)
        XCTAssertFalse(gate.joinPairingPendingOverride!)
        XCTAssertEqual(host.presentCount, 0)
    }

    /// And the same distinction driven through a real controller in the other
    /// direction, so the marker has to be right ON THE WIRE and not only when the
    /// handler is called by hand: a pass that measures a one-to-one account ends
    /// the join.
    func testAMeasuredPassThroughARealControllerRetiresTheFlag() async throws {
        let api = FakeAPI()
        let provider = FakeDeviceKeyProvider()
        _ = try await AccountKeyManager(api: api, deviceKeyProvider: provider).bootstrap()
        let controller = makeController(api: api, provider: provider,
                                        locals: [(profileId: "Default", displayName: "Default")])
        let host = FakeModalHost()
        let gate = makeGate(host: host)
        gate.joinPairingPendingOverride = true
        gate.start(controller: controller)
        defer { gate.stop() }

        await controller.silentUnlockAndResolve()   // registers "Default"; nothing left over
        XCTAssertFalse(controller.needsPairing)
        XCTAssertEqual(host.presentCount, 0)
        XCTAssertFalse(gate.joinPairingPendingOverride!,
                       "a measured one-to-one account really is a finished join")
    }

    func testAPendingJoinFlagSurvivesARelaunchAndRepresents() {
        let host = FakeModalHost()
        let first = makeGate(host: host)
        first.joinPairingPendingOverride = true
        first.start(controller: nil)
        first.handleMappingsDidResolve(needsPairing: true, needsPairingActionable: true)
        XCTAssertEqual(host.presentCount, 1)

        // "Quit before finishing the pairing", then a fresh gate on next launch.
        let secondHost = FakeModalHost()
        let second = makeGate(host: secondHost)
        second.joinPairingPendingOverride = true
        second.start(controller: nil)
        second.handleMappingsDidResolve(needsPairing: true, needsPairingActionable: true)
        XCTAssertEqual(secondHost.presentCount, 1)
    }

    // MARK: - Hysteresis safety net (§3.2)

    func testThreeIdleRefreshRoundsPresentExactlyOnce() {
        let host = FakeModalHost()
        let gate = makeGate(host: host)
        gate.joinPairingPendingOverride = false
        gate.start(controller: nil)
        gate.handleMappingsDidResolve(needsPairing: true, needsPairingActionable: true)
        for _ in 0..<3 { autoCreateNotification(outcome: "unchanged", created: 0, skipped: 0) }
        XCTAssertEqual(host.presentCount, 1)
        autoCreateNotification(outcome: "unchanged", created: 0, skipped: 0)
        XCTAssertEqual(host.presentCount, 1)
    }

    /// Throttled batch creation is PROGRESS, not a stall: without this the gate
    /// locks a healthy, converging account into an app-modal window and (via the
    /// Space gate) drops the shared marker and replays data type 2000.
    func testChangedRoundsResetTheHysteresisEvenWhenThrottled() {
        let host = FakeModalHost()
        let gate = makeGate(host: host)
        gate.joinPairingPendingOverride = false
        gate.start(controller: nil)
        gate.handleMappingsDidResolve(needsPairing: true, needsPairingActionable: true)
        for _ in 0..<3 { autoCreateNotification(outcome: "changed", created: 3, skipped: 6) }
        XCTAssertEqual(host.presentCount, 0)
    }

    func testFailedOrSkippedRoundsDoNotAdvanceTheHysteresis() {
        let host = FakeModalHost()
        let gate = makeGate(host: host)
        gate.joinPairingPendingOverride = false
        gate.start(controller: nil)
        gate.handleMappingsDidResolve(needsPairing: true, needsPairingActionable: true)
        autoCreateNotification(outcome: "unchanged", created: 0, skipped: 0)
        autoCreateNotification(outcome: "failed", created: 0, skipped: 0)
        autoCreateNotification(outcome: "unchanged", created: 0, skipped: 1)
        autoCreateNotification(outcome: "unchanged", created: 0, skipped: 0)
        XCTAssertEqual(host.presentCount, 0)
    }

    func testTenUndecryptableRoundsNeverPresent() {
        let host = FakeModalHost()
        let gate = makeGate(host: host)
        gate.joinPairingPendingOverride = false
        gate.start(controller: nil)
        // needsPairing true forever, but the only cause is an envelope the modal
        // could not resolve either -- both of its exits throw for that row.
        gate.handleMappingsDidResolve(needsPairing: true, needsPairingActionable: false)
        for _ in 0..<10 { autoCreateNotification(outcome: "unchanged", created: 0, skipped: 1) }
        XCTAssertEqual(host.presentCount, 0)
    }

    /// The safety net is the one writer of `sync.joinPairingPending` that announces NOTHING:
    /// it raises the flag and presents the modal from inside `.phiProfileAutoCreateDidRun`
    /// by calling `handleMappingsDidResolve` directly, so `.phiProfileMappingsDidResolve` is
    /// never posted on this path.
    ///
    /// That is exactly why `PhiChromiumCoordinator.refreshSpaceSyncGate()` has a FOURTH
    /// driver hung on `.phiProfileAutoCreateDidRun`: the mappings-driven ones cannot see this
    /// edge, and the Space section (data type 2000) would otherwise keep pulling, applying and
    /// publishing for the whole of a safety-net modal — unbounded in time, since only the
    /// user's pairing submission ends it — while the profile mapping picture is as ambiguous
    /// as it is during a join.
    func testTheSafetyNetRaisesThePendingFlagWithoutAnnouncingMappings() {
        let host = FakeModalHost()
        let gate = makeGate(host: host)
        gate.joinPairingPendingOverride = false
        gate.start(controller: nil)
        defer { gate.stop() }
        gate.handleMappingsDidResolve(needsPairing: true, needsPairingActionable: true)
        XCTAssertEqual(gate.joinPairingPendingOverride, false, "no join is outstanding yet")

        let announcements = Box(0)
        let token = NotificationCenter.default.addObserver(
            forName: .phiProfileMappingsDidResolve, object: nil,
            queue: nil) { _ in announcements.value += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        for _ in 0..<ProfilePairingGate.pairingStuckRounds {
            autoCreateNotification(outcome: "unchanged", created: 0, skipped: 0)
        }

        XCTAssertEqual(host.presentCount, 1, "the safety net presents on the third idle round")
        // True the moment the third post returns: the gate observes with `queue: nil` and
        // sets `pending` before it presents. So an observer that hops through the main queue
        // — which is how the coordinator's gate drivers are registered, to stay off the
        // poster's stack (this poster is an engine round's main-actor hop) — reads it too.
        XCTAssertEqual(gate.joinPairingPendingOverride, true,
                       "the safety net writes sync.joinPairingPending, so the gate must shut")
        XCTAssertEqual(announcements.value, 0,
                       "and it announces nothing, so a mappings-only driver never re-evaluates")
    }

    // MARK: - Re-driving an already-presented modal (task 20)

    /// The modal used to get exactly one load attempt for its whole life: every
    /// later `.measured` announcement returned at the `isPresented` short
    /// circuit. On device B that meant a window whose load hung for minutes
    /// behind five serial round trips, with nothing able to restart it.
    ///
    /// A second announcement must now RE-DRIVE the window instead. The
    /// present-only-once invariant is unchanged: `presentCount` stays 1.
    func testASecondMeasuredPassRedrivesThePresentedModalInsteadOfPresentingAgain() {
        let host = FakeModalHost()
        let gate = makeGate(host: host)
        gate.joinPairingPendingOverride = true
        gate.start(controller: nil)
        defer { gate.stop() }

        gate.handleMappingsDidResolve(needsPairing: true, needsPairingActionable: true)
        XCTAssertEqual(host.presentCount, 1)
        XCTAssertEqual(host.reloadCount, 0, "the first pass presents; it does not reload")

        gate.handleMappingsDidResolve(needsPairing: true, needsPairingActionable: true)
        XCTAssertEqual(host.presentCount, 1, "one modal per session, still")
        XCTAssertEqual(host.reloadCount, 1, "the live window has to be re-driven, not ignored")
    }

    /// And the terminal shape is untouched by that: a pass with nothing
    /// actionable left still retires the join and takes the window down rather
    /// than reloading it.
    func testAnUnactionablePassStillClosesThePresentedModalWithoutReloading() {
        let host = FakeModalHost()
        let gate = makeGate(host: host)
        gate.joinPairingPendingOverride = true
        gate.start(controller: nil)
        defer { gate.stop() }

        gate.handleMappingsDidResolve(needsPairing: true, needsPairingActionable: true)
        gate.handleMappingsDidResolve(needsPairing: false, needsPairingActionable: false)
        XCTAssertEqual(host.dismissCount, 1)
        XCTAssertEqual(host.reloadCount, 0)
        XCTAssertFalse(gate.joinPairingPendingOverride!)
    }

    /// Retry is the modal's only way out of a stuck load, and the app-modal
    /// window has no close button, so it must never be disabled -- least of all
    /// in `.loading`, which is exactly the phase a stalled load sits in.
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

    /// 三条新接缝（Step 7 的 (e)）在这里**必须**被打桩：不打的话每一次
    /// `host.present(...)` 都会去拉 `PhiChromiumCoordinator.shared` 与它背后的
    /// `AccountController.shared`——今天的 gate 测试一个单例都不碰，向导不该改变这一点。
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

    /// The gate re-drives a presented modal on EVERY `.measured` pass, and
    /// `resolveMappings()` runs about once a minute, so a modal left open gets
    /// a fresh load roughly that often. In every INTERACTIVE phase that would
    /// swap the list out from under the user and discard the selections they
    /// have already made -- a re-drive is a rescue for a load that stalled, not
    /// a refresh of a form.
    ///
    /// 2. `.measured` 重驱在**每一个交互态**被拒，只有 `.loading` 与
    ///    `.error(_, .reload)` 允许。`.error` 的两个 `resume` 各一条：它们是同一个
    ///    case、相反的期望，写一条会漏掉真正危险的那一支。
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
                           "\(phase) 背后是用户已经做完的选择，一次重驱会把它冲掉")
        }
        XCTAssertTrue(AppModalPairingHost.reloadAllowed(for: .loading))
        XCTAssertTrue(AppModalPairingHost.reloadAllowed(for: .error(message: "boom", resume: .reload)))
    }

    // MARK: - 向导（M3-2b §10.7）

    /// 1. 窗口活过第 1 步：**真的按一次 Continue**，`stopModal` 零调用、窗口仍在。
    ///    回归那条拆模态陷阱——在第 1 步就提交，模态会在两步之间被拆掉，而且更糟：
    ///    `joinPairingPending` 一清，Space 段的门就开了，这台 Mac 会在用户还没作任何
    ///    Space 决定之前开始发布。
    ///
    ///    **必须真的按下去**：一条只 `present()` 就断言 `stopModalCount == 0` 的用例，
    ///    在缺陷被重新引入（Continue → `submitPairing` → 清 `joinPairingPending` →
    ///    `resolveMappings()` → `dismiss()`）之后**照样绿**——它从来没走到那条路上。
    ///    三条断言合起来才是「模态没有在两步之间被拆掉」：会话没被停、门还关着、
    ///    Space 映射一条没写。
    func testTheWindowSurvivesStepOne() async throws {
        ProfilePairingGate.staticPendingOverride = true
        defer { ProfilePairingGate.staticPendingOverride = nil }
        let recorder = ModalSessionRecorder()
        let spaceStore = PairingWizardViewModelTests.LedgerSpaceMappingStore()
        let host = makeHost(recorder,
                            previewAccountSpaces: { .success([]) },
                            pairableLocalSpaces: { [] })
        let controller = makeController(spaceStore: spaceStore)
        host.present(controller: controller)
        recorder.runScheduled()

        // `present()` 把首次加载交给一个 `Task`。这里直接再驱一次 `start()`：它是
        // 幂等的（`keyLayer.startPairing` 会取消在飞的那一趟），而且下面三条断言全是
        // 「什么都没发生」型的，一次多余的重载动不了它们中的任何一条。
        let wizard = try XCTUnwrap(host.viewModel)
        await wizard.start(controller: controller)
        wizard.continueToSpaces()

        XCTAssertEqual(recorder.stopModalCount, 0, "第 1 步的 Continue 不经过宿主的任何出口")
        XCTAssertTrue(ProfilePairingGate.joinPairingPending, "门必须还关着")
        XCTAssertTrue(spaceStore.map.isEmpty, "Space 映射一条都还没写")

        // 「窗口仍在」的可执行版本：宿主的 weak `viewModel` 只在 `dismiss()` 里被清掉。
        XCTAssertNotNil(host.viewModel, "第 1 步之后窗口必须还在")
        host.dismiss()
        XCTAssertNil(host.viewModel)
    }

    /// 4. T21：`present()` 仍把 modal session 交给 scheduler，不在调用者栈上进入
    ///    （既有断言，确认未被向导改动破坏）。
    func testTheModalSessionIsStillScheduledAfterTheWizardLanded() {
        let recorder = ModalSessionRecorder()
        let host = makeHost(recorder)
        host.present(controller: makeController())
        XCTAssertEqual(recorder.runModalCount, 0)
        recorder.runScheduled()
        XCTAssertEqual(recorder.runModalCount, 1)
    }
}

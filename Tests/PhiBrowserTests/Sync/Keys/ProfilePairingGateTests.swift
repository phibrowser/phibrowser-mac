import XCTest
@testable import Phi

@MainActor
final class ProfilePairingGateTests: XCTestCase {
    typealias FakeAPI = AccountKeyManagerTests.FakeAPI
    typealias FakeDeviceKeyProvider = AccountKeyManagerTests.FakeDeviceKeyProvider
    typealias MemoryMappingStore = ProfileKeyManagerTests.MemoryMappingStore

    /// Records the modal lifecycle so the gate can be asserted without AppKit.
    /// The controller is optional, which is what lets every case below run
    /// `start(controller: nil)` without building a key stack.
    final class FakeModalHost: ProfilePairingModalHost {
        private(set) var presentCount = 0
        private(set) var dismissCount = 0
        private(set) var lastPresentedController: SyncKeyController?
        func present(controller: SyncKeyController?) {
            presentCount += 1
            lastPresentedController = controller
        }
        func dismiss() { dismissCount += 1 }
    }

    /// A real, never-unlocked controller: enough to post the announcement
    /// variants through `NotificationCenter` without a key stack.
    private func makeController() -> SyncKeyController {
        makeController(api: FakeAPI(), provider: FakeDeviceKeyProvider())
    }

    /// A controller over a caller-supplied fake API (and, optionally, a seeded
    /// mapping store), so a case can drive REAL `resolveMappings()` passes --
    /// the bail-outs included -- instead of calling the handler by hand.
    private func makeController(api: FakeAPI, provider: FakeDeviceKeyProvider,
                                locals: [(profileId: String, displayName: String)] = [],
                                store: ProfileSyncMappingStore = MemoryMappingStore()) -> SyncKeyController {
        let mgr = AccountKeyManager(api: api, deviceKeyProvider: provider)
        return SyncKeyController(
            manager: mgr,
            approvals: DeviceApprovalService(api: api, keyManager: mgr, deviceKeyProvider: provider),
            profileKeys: ProfileKeyManager(api: api, keyManager: mgr, mappingStore: store),
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
}

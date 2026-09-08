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

    func testClearResolvedFlippingNeedsPairingFalseClosesTheModal() {
        let host = FakeModalHost()
        let gate = makeGate(host: host)
        gate.joinPairingPendingOverride = true
        gate.start(controller: nil)
        gate.handleMappingsDidResolve(needsPairing: true, needsPairingActionable: true)
        gate.handleMappingsDidResolve(needsPairing: false, needsPairingActionable: false)
        XCTAssertEqual(host.dismissCount, 1)
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

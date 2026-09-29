import XCTest
import CryptoKit
@testable import Phi

@MainActor
final class DevicesSettingViewModelTests: XCTestCase {
    typealias FakeAPI = AccountKeyManagerTests.FakeAPI
    typealias FakeDeviceKeyProvider = AccountKeyManagerTests.FakeDeviceKeyProvider

    private func unlockedStack() async throws -> (FakeAPI, AccountKeyManager, DeviceApprovalService, FakeDeviceKeyProvider) {
        let api = FakeAPI()
        let provider = FakeDeviceKeyProvider()
        _ = try await AccountKeyManager(api: api, deviceKeyProvider: provider).bootstrap() // account + this device's envelope
        let mgr = AccountKeyManager(api: api, deviceKeyProvider: provider)
        let svc = DeviceApprovalService(api: api, keyManager: mgr, deviceKeyProvider: provider)
        return (api, mgr, svc, provider)
    }

    func testLoadAllUnlockedLoadsPending() async throws {
        let (api, mgr, svc, _) = try await unlockedStack()
        api.pendingSummaries = [JoinRequestSummaryDTO(requestId: "jr-1", requestingPublicKey: Data([1,2,3]),
            name: "Air", platform: "macos", status: "pending", createdAt: FakeAPI.fixedCreatedAt)]
        let vm = DevicesSettingViewModel(manager: mgr, approvals: svc)
        await vm.loadAll()
        XCTAssertEqual(vm.unlockState, .unlocked)
        XCTAssertEqual(vm.pending.count, 1)
        await vm.stopPolling()
    }

    func testLoadAllNeedsJoinAndApproveBlocked() async throws {
        let api = FakeAPI()
        _ = try await AccountKeyManager(api: api, deviceKeyProvider: FakeDeviceKeyProvider()).bootstrap()
        let provider = FakeDeviceKeyProvider()                    // different, unjoined device
        let mgr = AccountKeyManager(api: api, deviceKeyProvider: provider)
        let svc = DeviceApprovalService(api: api, keyManager: mgr, deviceKeyProvider: provider)
        let vm = DevicesSettingViewModel(manager: mgr, approvals: svc)
        await vm.loadAll()
        XCTAssertEqual(vm.unlockState, .needsJoin)

        let joiner = Curve25519.KeyAgreement.PrivateKey()
        await vm.approve(PendingApproval(id: "jr-1", name: "Air", platform: "macos", verificationCode: "X",
            deadline: Date(), requestingPublicKey: joiner.publicKey.rawRepresentation))
        XCTAssertNotNil(vm.actionError)
        XCTAssertTrue(api.approveCalls.isEmpty)
    }

    func testDenyCallsService() async throws {
        let (api, mgr, svc, _) = try await unlockedStack()
        let vm = DevicesSettingViewModel(manager: mgr, approvals: svc)
        await vm.loadAll()
        await vm.deny(PendingApproval(id: "jr-7", name: "Air", platform: "macos", verificationCode: "X",
            deadline: Date(), requestingPublicKey: Data()))
        XCTAssertEqual(api.denyCalls, ["jr-7"])
        await vm.stopPolling()
    }

    func testSyncNowUsesTheRequestAPIAndAnnouncesTheEnd() async throws {
        let (_, mgr, svc, _) = try await unlockedStack()
        let vm = DevicesSettingViewModel(manager: mgr, approvals: svc)
        vm.pairingComplete = { true }
        let started = Date(timeIntervalSince1970: 100)
        var detail = SyncNativeDetail()
        detail.kinds[.bookmarks] = SyncKindStatus(received: 2, sent: 1, activityAt: started, pending: 0, held: 1)
        var report = SyncHelper.Report()
        report.requiredIDs = ["phi"]
        report.snapshots = ["phi": SyncContextSnapshot(id: "phi", phase: .syncing, lastSuccess: nil, revision: 3, detail: detail)]
        report.summary = SyncStatusSummary(phase: .syncing, lastSuccess: nil)
        report.request = .inFlight(startedAt: started)
        var requests = 0
        vm.syncNowReport = { requests += 1; return report }
        vm.syncReport = { _ in report }
        await vm.loadAll()
        await vm.syncNow()
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(vm.requestState, .inFlight(startedAt: started))
        XCTAssertEqual(vm.nativeDetail, detail)
        XCTAssertTrue(vm.syncNowButton.showsProgress)
        XCTAssertFalse(vm.syncNowButton.isEnabled)
        XCTAssertNil(vm.syncNowOutcome)

        report.request = .idle
        report.summary = SyncStatusSummary(phase: .upToDate, lastSuccess: started)
        await vm.refreshStatus()
        XCTAssertEqual(vm.syncNowOutcome, .init(serial: 1, result: .finished))
        XCTAssertTrue(vm.syncNowButton.isEnabled)

        // A request that ends without a newer common success is a failure; a problem recorded
        // before the tap is not named.
        report.request = .inFlight(startedAt: started)
        await vm.syncNow()
        detail.lastProblem = SyncErrorSummary(category: .offline, kind: nil, at: started)
        report.snapshots["phi"] = SyncContextSnapshot(id: "phi", phase: .offline, lastSuccess: started, revision: 4, detail: detail)
        report.summary = SyncStatusSummary(phase: .offline, lastSuccess: started)
        report.request = .idle
        await vm.refreshStatus()
        XCTAssertEqual(vm.syncNowOutcome, .init(serial: 2, result: .failed(nil)))

        // A problem recorded after the tap is named.
        report.request = .inFlight(startedAt: started)
        await vm.syncNow()
        detail.lastProblem = SyncErrorSummary(category: .offline, kind: nil, at: Date())
        report.snapshots["phi"] = SyncContextSnapshot(id: "phi", phase: .offline, lastSuccess: started, revision: 5, detail: detail)
        report.request = .idle
        await vm.refreshStatus()
        XCTAssertEqual(vm.syncNowOutcome, .init(serial: 3, result: .failed(.offline)))

        // A newer common success is finished even when a new round already runs.
        report.request = .inFlight(startedAt: started)
        await vm.syncNow()
        report.summary = SyncStatusSummary(phase: .syncing, lastSuccess: Date())
        report.request = .idle
        await vm.refreshStatus()
        XCTAssertEqual(vm.syncNowOutcome, .init(serial: 4, result: .finished))

        // A request dropped with the helper (no report) ends silently.
        report.request = .inFlight(startedAt: started)
        await vm.syncNow()
        vm.syncReport = { _ in nil }
        await vm.refreshStatus()
        XCTAssertEqual(vm.syncNowOutcome?.serial, 4)
        await vm.stopPolling()
    }

    func testLoadAllSignedOutShowsSignInWithoutKeyRequest() async throws {
        let api = FakeAPI()
        // What the real client throws when there is no token to send.
        api.deviceEnvelopeError = KeyAPIError.transport(URLError(.userAuthenticationRequired))
        let provider = FakeDeviceKeyProvider()
        let mgr = AccountKeyManager(api: api, deviceKeyProvider: provider)
        let svc = DeviceApprovalService(api: api, keyManager: mgr, deviceKeyProvider: provider)
        let vm = DevicesSettingViewModel(manager: mgr, approvals: svc)
        vm.isSignedIn = { false }
        await vm.loadAll()
        XCTAssertEqual(vm.unlockState, .notSignedIn)
        XCTAssertNil(vm.actionError)
    }
}

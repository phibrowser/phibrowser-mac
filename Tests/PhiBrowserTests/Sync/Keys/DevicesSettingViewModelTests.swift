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
}

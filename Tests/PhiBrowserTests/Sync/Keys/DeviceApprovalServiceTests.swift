import XCTest
import CryptoKit
@testable import Phi

final class DeviceApprovalServiceTests: XCTestCase {
    typealias FakeAPI = AccountKeyManagerTests.FakeAPI
    typealias FakeDeviceKeyProvider = AccountKeyManagerTests.FakeDeviceKeyProvider

    func testApproveWhenLockedThrows() async throws {
        let api = FakeAPI()
        let provider = FakeDeviceKeyProvider()
        let mgr = AccountKeyManager(api: api, deviceKeyProvider: provider) // currentARK == nil
        let svc = DeviceApprovalService(api: api, keyManager: mgr, deviceKeyProvider: provider)
        let joiner = Curve25519.KeyAgreement.PrivateKey()
        let item = PendingApproval(id: "jr-1", name: "Air", platform: "macos", verificationCode: "AAAA-AAAA",
            deadline: Date(), requestingPublicKey: joiner.publicKey.rawRepresentation)
        do { try await svc.approve(item); XCTFail("expected notUnlocked") }
        catch DeviceApprovalError.notUnlocked {}
        XCTAssertTrue(api.approveCalls.isEmpty)
    }

    func testApproveSealsArkToRequesterAndSetsResolvedBy() async throws {
        let api = FakeAPI()
        let provider = FakeDeviceKeyProvider()
        let mgr = AccountKeyManager(api: api, deviceKeyProvider: provider)
        _ = try await mgr.bootstrap()                       // mgr.currentARK set
        let arkBytes = mgr.currentARK!.withUnsafeBytes { Data($0) }
        let svc = DeviceApprovalService(api: api, keyManager: mgr, deviceKeyProvider: provider)

        let joinerPriv = Curve25519.KeyAgreement.PrivateKey()
        let item = PendingApproval(id: "jr-1", name: "Air", platform: "macos", verificationCode: "X",
            deadline: Date(), requestingPublicKey: joinerPriv.publicKey.rawRepresentation)
        try await svc.approve(item)

        XCTAssertEqual(api.approveCalls.count, 1)
        let call = api.approveCalls[0]
        XCTAssertEqual(call.id, "jr-1")
        XCTAssertEqual(call.resolvedBy, try provider.deviceKeyId())
        // The joiner can open the sealed envelope and recover the exact ARK.
        let opened = try PhiKeyCrypto.openWithPrivateKey(call.envelope, privateKey: joinerPriv)
        XCTAssertEqual(opened, arkBytes)
    }

    func testListMapsSummariesToApprovals() async throws {
        let api = FakeAPI()
        let provider = FakeDeviceKeyProvider()
        let mgr = AccountKeyManager(api: api, deviceKeyProvider: provider)
        let svc = DeviceApprovalService(api: api, keyManager: mgr, deviceKeyProvider: provider)
        let pub = Data((0..<32).map { UInt8($0) })
        api.pendingSummaries = [JoinRequestSummaryDTO(requestId: "jr-9", requestingPublicKey: pub,
            name: "Air", platform: "macos", status: "pending", createdAt: FakeAPI.fixedCreatedAt)]
        let list = try await svc.listPendingApprovals()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].id, "jr-9")
        XCTAssertEqual(list[0].verificationCode, PhiKeyCrypto.verificationCode(forPublicKey: pub))
        XCTAssertEqual(list[0].deadline, FakeAPI.fixedCreatedAt.addingTimeInterval(900))
    }

    func testDenyCallsEndpoint() async throws {
        let api = FakeAPI()
        let provider = FakeDeviceKeyProvider()
        let svc = DeviceApprovalService(api: api,
            keyManager: AccountKeyManager(api: api, deviceKeyProvider: provider), deviceKeyProvider: provider)
        let item = PendingApproval(id: "jr-3", name: "Air", platform: "macos", verificationCode: "X",
            deadline: Date(), requestingPublicKey: Data())
        try await svc.deny(item)
        XCTAssertEqual(api.denyCalls, ["jr-3"])
    }
}

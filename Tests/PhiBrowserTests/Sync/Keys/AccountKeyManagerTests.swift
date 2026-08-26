import XCTest
import CryptoKit
@testable import Phi

final class AccountKeyManagerTests: XCTestCase {
    // In-memory fake: one account key state plus a set of per-device envelopes.
    final class FakeAPI: KeyEnvelopeAPI {
        var account: AccountKeyStateDTO?
        var envelopes: [String: Data] = [:]
        var initialized = false

        func putAccount(salt: Data, kdfVersion: String, kdfParams: Data, recoveryEnvelope: Data) async throws -> Bool {
            if initialized { return false }
            initialized = true
            account = AccountKeyStateDTO(recoverySalt: salt, kdfVersion: kdfVersion,
                kdfParams: kdfParams, recoveryArkEnvelope: recoveryEnvelope, arkGeneration: 1)
            return true
        }
        func getAccount() async throws -> AccountKeyStateDTO? { account }
        func postDevice(deviceKeyId: String, publicKey: Data, name: String, platform: String, arkEnvelope: Data?) async throws {
            if let arkEnvelope { envelopes[deviceKeyId] = arkEnvelope }
        }
        func getDeviceEnvelope(deviceKeyId: String) async throws -> Data? { envelopes[deviceKeyId] }
    }

    private func makeManager(_ api: FakeAPI) -> AccountKeyManager {
        let store = DeviceKeyStore(service: "test.dev", account: "t-\(UUID().uuidString)")
        addTeardownBlock { try? store.deleteForTesting() }
        return AccountKeyManager(api: api, deviceStore: store)
    }

    func testBootstrapThenStartupUnlocks() async throws {
        let api = FakeAPI()
        let mgr = makeManager(api)
        let code = try await mgr.bootstrap()
        XCTAssertFalse(code.isEmpty)
        XCTAssertNotNil(mgr.currentARK)

        // New process, same device (same store): startup should unwrap the same ARK
        // from the device envelope.
        let fresh = AccountKeyManager(api: api, deviceStore: mgr.deviceStoreForTesting)
        let result = try await fresh.unlockAtStartup()
        XCTAssertEqual(result, .unlocked)
        XCTAssertEqual(fresh.currentARK!.withUnsafeBytes { Data($0) },
                       mgr.currentARK!.withUnsafeBytes { Data($0) })
    }

    func testSecondDeviceJoinsWithRecoveryCode() async throws {
        let api = FakeAPI()
        let first = makeManager(api)
        let code = try await first.bootstrap()
        let firstARK = first.currentARK!.withUnsafeBytes { Data($0) }

        // Second device (different store) joins with the recovery code and gets the same ARK.
        let second = makeManager(api)
        try await second.joinWithRecoveryCode(code)
        XCTAssertEqual(second.currentARK!.withUnsafeBytes { Data($0) }, firstARK)

        // The second device now unlocks normally on subsequent startup.
        let secondStartup = try await second.unlockAtStartup()
        XCTAssertEqual(secondStartup, .unlocked)
    }

    func testBadRecoveryCodeRejected() async throws {
        let api = FakeAPI()
        _ = try await makeManager(api).bootstrap()
        let joiner = makeManager(api)
        do { try await joiner.joinWithRecoveryCode("00000-00000-00000-00000-00000-00"); XCTFail() }
        catch AccountKeyError.badRecoveryCode {} // ok
    }

    func testStartupOnFreshDeviceNeedsJoin() async throws {
        let api = FakeAPI()
        _ = try await makeManager(api).bootstrap()   // account initialized, but this new device has no envelope
        let fresh = makeManager(api)
        let freshStartup = try await fresh.unlockAtStartup()
        XCTAssertEqual(freshStartup, .needsJoin)
    }
}

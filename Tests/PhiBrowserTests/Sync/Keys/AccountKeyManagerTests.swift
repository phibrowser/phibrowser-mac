import XCTest
import CryptoKit
@testable import Phi

final class AccountKeyManagerTests: XCTestCase {
    // In-memory fake: one account key state plus a set of per-device envelopes.
    final class FakeAPI: KeyEnvelopeAPI {
        var account: AccountKeyStateDTO?
        var envelopes: [String: Data] = [:]
        var initialized = false
        var deviceEnvelopeError: Error?

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
        func getDeviceEnvelope(deviceKeyId: String) async throws -> Data? {
            if let deviceEnvelopeError { throw deviceEnvelopeError }
            return envelopes[deviceKeyId]
        }
    }

    // In-memory fake device key: same fingerprinting algorithm as `DeviceKeyStore`
    // (SHA-256 of the public key, first 16 bytes, base64url), but backed by a
    // process-local key instead of the Keychain — keeps this suite independent of
    // the Data Protection Keychain entitlement.
    final class FakeDeviceKeyProvider: DeviceKeyProviding {
        private let privateKey = Curve25519.KeyAgreement.PrivateKey()

        func loadOrCreatePrivateKey() throws -> Curve25519.KeyAgreement.PrivateKey { privateKey }

        func deviceKeyId() throws -> String {
            let digest = SHA256.hash(data: privateKey.publicKey.rawRepresentation)
            let prefix = Data(digest.prefix(16))
            return prefix.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
    }

    private func makeManager(_ api: FakeAPI) -> AccountKeyManager {
        AccountKeyManager(api: api, deviceKeyProvider: FakeDeviceKeyProvider())
    }

    func testBootstrapThenStartupUnlocks() async throws {
        let api = FakeAPI()
        let mgr = makeManager(api)
        let code = try await mgr.bootstrap()
        XCTAssertFalse(code.isEmpty)
        XCTAssertNotNil(mgr.currentARK)

        // New process, same device (same provider): startup should unwrap the same ARK
        // from the device envelope.
        let fresh = AccountKeyManager(api: api, deviceKeyProvider: mgr.deviceKeyProviderForTesting)
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

        // Second device (different provider) joins with the recovery code and gets the same ARK.
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

    func testStartupNotSignedInOn401() async throws {
        let api = FakeAPI()
        api.deviceEnvelopeError = KeyAPIError.http(401, "")
        let mgr = makeManager(api)
        let result = try await mgr.unlockAtStartup()
        XCTAssertEqual(result, .notSignedIn)
    }

    func testRecoveryCodeValidFormatButWrongKeyRejected() async throws {
        let api = FakeAPI()
        _ = try await makeManager(api).bootstrap()

        // A syntactically and checksum-valid recovery code that was never associated
        // with this account's salt/envelope: RecoveryCode.decode() succeeds, but the
        // derived key must fail to open the account's AES-GCM envelope.
        let (unrelatedCode, _) = try RecoveryCode.generate()
        let joiner = makeManager(api)
        do {
            try await joiner.joinWithRecoveryCode(unrelatedCode)
            XCTFail("expected badRecoveryCode")
        } catch AccountKeyError.badRecoveryCode {} // ok: reached via the openWithSymmetric catch, not the decode guard
    }

    func testSecondBootstrapOnSameAccountRejected() async throws {
        let api = FakeAPI()
        let mgr = makeManager(api)
        _ = try await mgr.bootstrap()
        do {
            _ = try await mgr.bootstrap()
            XCTFail("expected alreadyInitialized")
        } catch AccountKeyError.alreadyInitialized {} // ok: FakeAPI.putAccount returns false on the second call
    }

    func testJoinOnNeverBootstrappedAccountRejected() async throws {
        let api = FakeAPI() // never bootstrapped: getAccount() returns nil
        let (code, _) = try RecoveryCode.generate()
        let joiner = makeManager(api)
        do {
            try await joiner.joinWithRecoveryCode(code)
            XCTFail("expected notInitialized")
        } catch AccountKeyError.notInitialized {} // ok: FakeAPI.getAccount() returns nil
    }
}

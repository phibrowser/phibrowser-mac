import XCTest
import CryptoKit
@testable import Phi

final class PhiDomainKeyManagerTests: XCTestCase {
    private func rawBytes(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }

    private func makeUnlockedManager() async throws -> (AccountKeyManagerTests.FakeAPI, AccountKeyManager) {
        let api = AccountKeyManagerTests.FakeAPI()
        let mgr = AccountKeyManager(api: api, deviceKeyProvider: AccountKeyManagerTests.FakeDeviceKeyProvider())
        _ = try await mgr.bootstrap()
        return (api, mgr)
    }

    /// First use on a fresh account: the key is minted locally, escrowed sealed
    /// under the ARK, and reused from the cache on the next call.
    func testDomainKeyMintsThenReuses() async throws {
        let (api, mgr) = try await makeUnlockedManager()
        let dkm = PhiDomainKeyManager(api: api, keyManager: mgr)

        let k1 = try await dkm.domainKey()
        let k2 = try await dkm.domainKey()
        XCTAssertEqual(rawBytes(k1), rawBytes(k2))
        XCTAssertEqual(rawBytes(k1).count, 32)
        XCTAssertNotNil(api.domainEnvelopes[PhiDomainKeyManager.domain])
        // Second call is served from the cache, not from the server.
        XCTAssertEqual(api.getDomainKeyCalls, 1)
        XCTAssertEqual(api.putDomainKeyCalls, 1)

        // The escrowed envelope is ARK-sealed and carries exactly the minted key.
        let (escrowed, _) = try ProfileKeyManager.openProfilePayload(
            api.domainEnvelopes[PhiDomainKeyManager.domain]!, ark: mgr.currentARK!)
        XCTAssertEqual(escrowed, rawBytes(k1))
    }

    /// A second device finds the key already escrowed and adopts it instead of minting.
    func testSecondDeviceAdoptsEscrowedKey() async throws {
        let (api, mgr) = try await makeUnlockedManager()
        let first = try await PhiDomainKeyManager(api: api, keyManager: mgr).domainKey()

        let second = try await PhiDomainKeyManager(api: api, keyManager: mgr).domainKey()
        XCTAssertEqual(rawBytes(first), rawBytes(second))
        XCTAssertEqual(api.putDomainKeyCalls, 1)  // the second manager never PUT
    }

    /// First-use race: GET says 404, but another device wins the PUT. The loser must
    /// discard its locally generated key and adopt the server's envelope.
    func testConcurrentFirstUseAdoptsServerWinner() async throws {
        let (api, mgr) = try await makeUnlockedManager()
        var winnerKey = Data(count: 32)
        winnerKey[0] = 0xAB
        let winnerEnvelope = try ProfileKeyManager.sealProfilePayload(
            key: winnerKey, name: PhiDomainKeyManager.domain, ark: mgr.currentARK!)
        // Simulate the other device landing its PUT between our GET and our PUT.
        api.beforePutDomainKey = { [unowned api] domain in
            api.domainEnvelopes[domain] = winnerEnvelope
        }

        let key = try await PhiDomainKeyManager(api: api, keyManager: mgr).domainKey()
        XCTAssertEqual(rawBytes(key), winnerKey)
        XCTAssertEqual(api.domainEnvelopes[PhiDomainKeyManager.domain], winnerEnvelope)
        XCTAssertEqual(api.getDomainKeyCalls, 2)  // initial miss + re-GET after the 409
    }

    /// A locked account key layer must fail loudly rather than mint an unescrowable key.
    func testLockedAccountThrowsNotUnlocked() async throws {
        let api = AccountKeyManagerTests.FakeAPI()
        let mgr = AccountKeyManager(api: api, deviceKeyProvider: AccountKeyManagerTests.FakeDeviceKeyProvider())
        let dkm = PhiDomainKeyManager(api: api, keyManager: mgr)
        do {
            _ = try await dkm.domainKey()
            XCTFail("expected notUnlocked")
        } catch ProfileKeyManagerError.notUnlocked {
            // expected
        }
        XCTAssertEqual(api.putDomainKeyCalls, 0)
    }

    /// `clear()` drops the cache so the next call refetches (sign-out / ARK change).
    func testClearDropsCache() async throws {
        let (api, mgr) = try await makeUnlockedManager()
        let dkm = PhiDomainKeyManager(api: api, keyManager: mgr)
        let k1 = try await dkm.domainKey()
        dkm.clear()
        let k2 = try await dkm.domainKey()
        XCTAssertEqual(rawBytes(k1), rawBytes(k2))
        XCTAssertEqual(api.getDomainKeyCalls, 2)
    }
}

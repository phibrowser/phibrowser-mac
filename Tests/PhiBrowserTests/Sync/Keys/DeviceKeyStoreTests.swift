import XCTest
import CryptoKit
@testable import Phi

final class DeviceKeyStoreTests: XCTestCase {
    /// A UNIQUE service per call, never the default. The default service plus the
    /// default legacy account IS the developer's real device key, and the legacy
    /// copy-migration in `loadOrCreatePrivateKey()` reads across accounts within one
    /// service -- so a shared fixed service would couple otherwise unrelated cases.
    private func makeStore() -> DeviceKeyStore {
        DeviceKeyStore(service: "com.phibrowser.sync.device-key.test.\(UUID().uuidString)",
                       accountId: "test-\(UUID().uuidString)")
    }

    /// A throwaway service shared by the three account dimensions in one test.
    /// NEVER the default: the default service + the default legacy account IS
    /// the developer's real device key, and `rotateForCurrentAccount()` /
    /// `deleteForTesting()` on it turns this Mac into an unregistered device.
    private func scopedStores() -> (legacy: DeviceKeyStore, a: DeviceKeyStore, b: DeviceKeyStore) {
        let service = "com.phibrowser.sync.device-key.test.\(UUID().uuidString)"
        return (DeviceKeyStore(service: service, accountId: nil),
                DeviceKeyStore(service: service, accountId: "auth0|A"),
                DeviceKeyStore(service: service, accountId: "auth0|B"))
    }

    func testLoadOrCreateIsIdempotent() throws {
        let store = makeStore()
        defer { try? store.deleteForTesting() }
        let k1 = try store.loadOrCreatePrivateKey()
        let k2 = try store.loadOrCreatePrivateKey()
        XCTAssertEqual(k1.rawRepresentation, k2.rawRepresentation)
    }

    func testDeviceKeyIdStableAndWellFormed() throws {
        let store = makeStore()
        defer { try? store.deleteForTesting() }
        _ = try store.loadOrCreatePrivateKey()
        let id1 = try store.deviceKeyId()
        let id2 = try store.deviceKeyId()
        XCTAssertEqual(id1, id2)
        // base64url without padding, length ~= ceil(16/3*4)=22, matches [A-Za-z0-9_-]{8,64}
        XCTAssertTrue(id1.range(of: "^[A-Za-z0-9_-]{8,64}$", options: .regularExpression) != nil)
    }

    func testTwoStoresDifferentAccountsAreIndependent() throws {
        let a = makeStore(); let b = makeStore()
        defer { try? a.deleteForTesting(); try? b.deleteForTesting() }
        XCTAssertNotEqual(try a.loadOrCreatePrivateKey().rawRepresentation,
                          try b.loadOrCreatePrivateKey().rawRepresentation)
    }

    func testTheLegacyItemIsMigratedByCopyingNotRegenerating() throws {
        let (legacy, scoped, _) = scopedStores()
        defer { try? legacy.deleteForTesting(); try? scoped.deleteForTesting() }
        let legacyId = try legacy.deviceKeyId()
        XCTAssertEqual(try scoped.deviceKeyId(), legacyId,
                       "regenerating here would turn a registered device into a stranger (404 -> rejoin)")
        XCTAssertEqual(try legacy.deviceKeyId(), legacyId, "the legacy item is read-only, never deleted")
    }

    func testRotationTouchesOnlyTheCurrentAccountsItem() throws {
        let (legacy, a, b) = scopedStores()
        defer { try? legacy.deleteForTesting(); try? a.deleteForTesting(); try? b.deleteForTesting() }
        let idA = try a.deviceKeyId(), idB = try b.deviceKeyId(), idLegacy = try legacy.deviceKeyId()
        try a.rotateForCurrentAccount()
        XCTAssertNotEqual(try a.deviceKeyId(), idA)
        XCTAssertEqual(try b.deviceKeyId(), idB)
        XCTAssertEqual(try legacy.deviceKeyId(), idLegacy)
    }

    func testRotationDoesNotFallBackToTheRevokedLegacyKey() throws {
        let (legacy, scoped, _) = scopedStores()
        defer { try? legacy.deleteForTesting(); try? scoped.deleteForTesting() }
        _ = try legacy.deviceKeyId()
        let before = try scoped.deviceKeyId()
        try scoped.rotateForCurrentAccount()
        let after = try scoped.deviceKeyId()
        XCTAssertNotEqual(after, before)
        XCTAssertNotEqual(after, try legacy.deviceKeyId(),
                          "the server never un-revokes an id; falling back would make rejoining impossible")
    }
}

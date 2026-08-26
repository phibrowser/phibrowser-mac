import XCTest
import CryptoKit
@testable import Phi

final class DeviceKeyStoreTests: XCTestCase {
    private func makeStore() -> DeviceKeyStore {
        DeviceKeyStore(service: "com.phibrowser.sync.device-key.test", account: "test-\(UUID().uuidString)")
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
}

import CryptoKit
import XCTest
@testable import Phi

final class ServiceBrokerSocketPathTests: XCTestCase {
    func testMatchesSentinelStorageHashAndChannel() {
        let storage = "/Users/test/Library/Application Support/com.phibrowser.canary.Sentinel/auth0_user"
        let digest = SHA256.hash(data: Data(storage.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()

        XCTAssertEqual(
            ServiceBrokerSocketPath.dataSocketPath(storagePath: storage),
            "/tmp/phi-sentinel-\(digest)/sockets/service-broker.sock"
        )
        XCTAssertEqual(
            ServiceBrokerSocketPath.sentinelBundleIdentifier(browserBundleIdentifier: "com.phibrowser.canary.Mac"),
            "com.phibrowser.canary.Sentinel"
        )
        XCTAssertEqual(
            ServiceBrokerSocketPath.sentinelBundleIdentifier(browserBundleIdentifier: "com.phibrowser.dev.Mac"),
            "com.phibrowser.dev.Sentinel"
        )
        XCTAssertEqual(
            ServiceBrokerSocketPath.sentinelBundleIdentifier(browserBundleIdentifier: "com.phibrowser.Mac"),
            "com.phibrowser.Sentinel"
        )
    }

    func testSanitizesAccountPathComponentLikeSentinel() {
        XCTAssertEqual(
            ServiceBrokerSocketPath.sanitizePathComponent("auth0|a/b:c?d"),
            "auth0_a_b_c_d"
        )
    }
}

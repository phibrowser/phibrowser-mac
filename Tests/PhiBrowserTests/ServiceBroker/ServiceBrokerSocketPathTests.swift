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

    func testFallsBackToStorageWhenShortSocketRootIsSymlinked() throws {
        let storage = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .path
        let digest = SHA256.hash(data: Data(storage.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        let shortRoot = "/tmp/phi-sentinel-\(digest)"
        let symlinkTarget = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: symlinkTarget, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: shortRoot,
            withDestinationPath: symlinkTarget.path
        )
        defer {
            try? FileManager.default.removeItem(atPath: shortRoot)
            try? FileManager.default.removeItem(at: symlinkTarget)
        }

        XCTAssertEqual(
            ServiceBrokerSocketPath.dataSocketPath(storagePath: storage),
            (storage as NSString).appendingPathComponent("state/sockets/service-broker.sock")
        )
    }
}

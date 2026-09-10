import Foundation
import XCTest
@testable import Phi

final class SiteMemorySettingsTests: XCTestCase {
    private func temporaryStore() -> SiteMemorySettingsStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return SiteMemorySettingsStore(fileURL: directory.appendingPathComponent("settings.json"))
    }

    func testSettingsPersistAndSeparateProfilesAndExactHosts() throws {
        let store = temporaryStore()
        XCTAssertTrue(try store.collectionEnabled(for: "example.com", profileID: "Default"))
        try store.setCollectionEnabled(false, for: "EXAMPLE.COM.", profileID: "Default")
        let reopened = SiteMemorySettingsStore(fileURL: store.fileURL)
        XCTAssertFalse(try reopened.collectionEnabled(for: "example.com", profileID: "Default"))
        XCTAssertTrue(try reopened.collectionEnabled(for: "www.example.com", profileID: "Default"))
        XCTAssertTrue(try reopened.collectionEnabled(for: "example.com", profileID: "Profile 2"))
        XCTAssertTrue(try temporaryStore().collectionEnabled(for: "example.com", profileID: "Default"))
        try reopened.setCollectionEnabled(true, for: "example.com", profileID: "Default")
        XCTAssertTrue(try store.collectionEnabled(for: "example.com", profileID: "Default"))
    }

    func testConcurrentReadersAndWritersAcrossInstancesDoNotLoseHosts() throws {
        let store = temporaryStore()
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            let instance = SiteMemorySettingsStore(fileURL: store.fileURL)
            do {
                try instance.setCollectionEnabled(false, for: "site\(index).test", profileID: "Default")
                XCTAssertFalse(try instance.collectionEnabled(for: "site\(index).test", profileID: "Default"))
            } catch { XCTFail("Concurrent settings operation failed: \(error)") }
        }
        for index in 0..<100 {
            XCTAssertFalse(try store.collectionEnabled(for: "site\(index).test", profileID: "Default"))
        }
    }

    func testInvalidInputAndCorruptStorageDoNotDefaultToEnabledOrOverwriteData() throws {
        let store = temporaryStore()
        for host in ["", "https://example.com", "*.example.com", "example.com/path", "example.com:443"] {
            XCTAssertThrowsError(try store.setCollectionEnabled(false, for: host, profileID: "Default"))
        }
        XCTAssertThrowsError(try store.collectionEnabled(for: "example.com", profileID: ""))
        try store.setCollectionEnabled(false, for: "example.com", profileID: "Default")
        let corrupt = Data("not JSON".utf8)
        try corrupt.write(to: store.fileURL)
        XCTAssertThrowsError(try store.collectionEnabled(for: "example.com", profileID: "Default"))
        XCTAssertThrowsError(try store.setCollectionEnabled(true, for: "example.com", profileID: "Default"))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), corrupt)
    }

    func testWriteFailureIsReported() throws {
        let store = temporaryStore()
        try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.setCollectionEnabled(false, for: "example.com", profileID: "Default"))
    }

    func testLexingtonQueryIsReadOnlyAndRequiresExplicitProfileAndTrustedSender() throws {
        let store = temporaryStore()
        let sender = "pjgdkljlcbjgedgeppodjijjphfcplno"
        try store.setCollectionEnabled(false, for: "example.com", profileID: "Profile 2")
        let json = try SiteMemoryMessageRouter.query(
            payload: #"{"host":"EXAMPLE.COM","profileId":"Profile 2"}"#,
            senderID: sender, settings: store)
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(response["enabled"] as? Bool, false)
        XCTAssertEqual(response["host"] as? String, "example.com")
        XCTAssertEqual(response["profileId"] as? String, "Profile 2")
        for otherSender in ["", "cdp", "fenmfiepnpdlhplemgijlimpbebebljo"] {
            XCTAssertThrowsError(try SiteMemoryMessageRouter.query(
                payload: #"{"host":"example.com","profileId":"Profile 2"}"#,
                senderID: otherSender, settings: store))
        }
        XCTAssertThrowsError(try SiteMemoryMessageRouter.query(
            payload: #"{"host":"example.com"}"#, senderID: sender, settings: store))
    }
}

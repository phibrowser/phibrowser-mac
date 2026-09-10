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
        XCTAssertFalse(try reopened.collectionEnabled(for: "www.example.com", profileID: "Default"))
        XCTAssertTrue(try reopened.collectionEnabled(for: "gov.example.com", profileID: "Default"))
        XCTAssertTrue(try reopened.collectionEnabled(for: "example.com", profileID: "Profile 2"))
        XCTAssertTrue(try temporaryStore().collectionEnabled(for: "example.com", profileID: "Default"))
        try reopened.setCollectionEnabled(true, for: "example.com", profileID: "Default")
        XCTAssertTrue(try store.collectionEnabled(for: "example.com", profileID: "Default"))
    }

    func testOnlyBareDomainAndWWWShareOneStoredEntryIncludingLegacyOverrides() throws {
        let store = temporaryStore()
        for domain in ["v2ex.com", "example.co.uk", "alice.github.io"] {
            try store.setCollectionEnabled(false, for: "www.\(domain)", profileID: "Default")
            XCTAssertFalse(try store.collectionEnabled(for: domain, profileID: "Default"))
            XCTAssertFalse(try store.collectionEnabled(for: "www.\(domain)", profileID: "Default"))
            XCTAssertTrue(try store.collectionEnabled(for: "gov.\(domain)", profileID: "Default"))
            let saved = try JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: store.fileURL))
            XCTAssertEqual(saved["Default"], [domain])
            try store.setCollectionEnabled(true, for: domain, profileID: "Default")
            XCTAssertTrue(try store.collectionEnabled(for: "www.\(domain)", profileID: "Default"))
        }

        try Data(#"{"Default":["www.v2ex.com","gov.163.com"]}"#.utf8).write(to: store.fileURL)
        XCTAssertFalse(try store.collectionEnabled(for: "v2ex.com", profileID: "Default"))
        try store.setCollectionEnabled(true, for: "v2ex.com", profileID: "Default")
        XCTAssertTrue(try store.collectionEnabled(for: "www.v2ex.com", profileID: "Default"))
        XCTAssertFalse(try store.collectionEnabled(for: "gov.163.com", profileID: "Default"))

        for (host, separateHost) in [
            ("www.163.com", "gov.163.com"),
            ("www.gov.163.com", "gov.163.com"),
            ("gov.163.com", "news.gov.163.com"),
            ("alice.github.io", "bob.github.io"),
            ("co.uk", "www.co.uk"),
            ("github.io", "www.github.io"),
            ("127.0.0.1", "www.127.0.0.1")
        ] {
            let isolated = temporaryStore()
            try isolated.setCollectionEnabled(false, for: host, profileID: "Default")
            XCTAssertTrue(try isolated.collectionEnabled(for: separateHost, profileID: "Default"), host)
        }
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

    func testSwiftDomainMatchingHandlesPublicPrivateWildcardAndExceptionRules() throws {
        for (host, expected) in [
            ("gov.163.com", "163.com"),
            ("news.example.com.cn", "example.com.cn"),
            ("news.example.co.uk", "example.co.uk"),
            ("docs.alice.github.io", "alice.github.io"),
            ("a.b.ck", "a.b.ck"),
            ("news.www.ck", "www.ck"),
            ("news.city.kawasaki.jp", "city.kawasaki.jp")
        ] {
            XCTAssertEqual(SiteMemorySettingsStore.registrableDomain(for: host), expected, host)
        }
        for host in ["com", "co.uk", "github.io", "b.ck", "foo.kawasaki.jp", "localhost", "127.0.0.1", "https://example.com"] {
            XCTAssertNil(SiteMemorySettingsStore.registrableDomain(for: host), host)
        }
        let host = "news.example.xn--55qx5d.cn"
        let domain = "example.xn--55qx5d.cn"
        XCTAssertEqual(SiteMemorySettingsStore.registrableDomain(for: host), domain)
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
            payload: #"{"host":"WWW.EXAMPLE.COM","profileId":"Profile 2"}"#,
            senderID: sender, settings: store)
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(response["enabled"] as? Bool, false)
        XCTAssertEqual(response["host"] as? String, "www.example.com")
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

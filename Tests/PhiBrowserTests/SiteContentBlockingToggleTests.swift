// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// Answers the domain question with the URL's host and records exception
/// writes; the real rule lives in Chromium.
private final class DomainBridge: ContentBlockingBridging {
    var siteExceptions: [String] = []
    var domainQueries: [String] = []
    var exceptionCalls: [(String, String, Bool)] = []
    var acceptWrites = true

    func getContentBlockingSettings(_ profileId: String,
                                    completion: @escaping ((any PhiContentBlockingSettings)?, String?) -> Void) {
        completion(FakeSettings(blockAds: true, blockCookieBanners: true, blockTrackers: true,
                                lists: [], siteExceptions: siteExceptions), nil)
    }

    func setContentBlockingCategory(_ profileId: String, category: PhiContentBlockingCategory, enabled: Bool,
                                    completion: @escaping (Bool, String?) -> Void) {
        completion(true, nil)
    }

    func setContentBlockingList(_ profileId: String, listId: String, enabled: Bool,
                                completion: @escaping (Bool, String?) -> Void) {
        completion(true, nil)
    }

    func setContentBlockingSiteException(_ profileId: String, domain: String, enabled: Bool,
                                         completion: @escaping (Bool, String?) -> Void) {
        exceptionCalls.append((profileId, domain, enabled))
        completion(acceptWrites, acceptWrites ? nil : "nope")
    }

    func contentBlockingSiteExceptionDomain(forURL url: String) -> String {
        domainQueries.append(url)
        guard let parsed = URL(string: url), ["http", "https"].contains(parsed.scheme ?? "") else { return "" }
        return parsed.host ?? ""
    }

    func addContentBlockingCustomList(_ profileId: String, name: String, url: String?, rules: String?,
                                      completion: @escaping (String?, String?) -> Void) {
        completion(nil, "unsupported")
    }

    func removeContentBlockingCustomList(_ profileId: String, listId: String,
                                         completion: @escaping (Bool, String?) -> Void) {
        completion(false, "unsupported")
    }

    func refreshContentBlockingLists(_ profileId: String, completion: @escaping (Bool, String?) -> Void) {
        completion(false, "unsupported")
    }

    func downloadContentBlockingList(_ profileId: String, listId: String,
                                     completion: @escaping (Bool, String?) -> Void) {
        completion(false, "unsupported")
    }

    func deleteContentBlockingListDownload(_ profileId: String, listId: String,
                                           completion: @escaping (Bool, String?) -> Void) {
        completion(false, "unsupported")
    }
}

@MainActor
final class SiteContentBlockingToggleTests: XCTestCase {
    private func toggle(url: String = "https://www.example.com/page",
                        profileId: String = "Profile 2",
                        isIncognito: Bool = false,
                        bridge: DomainBridge) -> SiteContentBlockingToggle? {
        SiteContentBlockingToggle(
            urlString: url, profileId: profileId, isIncognito: isIncognito,
            settings: ContentBlockingSettings(profileId: profileId, bridge: bridge,
                                              notificationCenter: NotificationCenter()))
    }

    func testDomainComesFromTheBridge() throws {
        let bridge = DomainBridge()
        let toggle = try XCTUnwrap(toggle(bridge: bridge))
        XCTAssertEqual(toggle.domain, "www.example.com")
        XCTAssertEqual(bridge.domainQueries, ["https://www.example.com/page"])
    }

    func testNoRowForPrivateWindowsOrNonSites() {
        let bridge = DomainBridge()
        XCTAssertNil(toggle(isIncognito: true, bridge: bridge))
        XCTAssertNil(toggle(profileId: "", bridge: bridge))
        for url in ["", "phi://settings", "chrome://newtab", "file:///tmp/a.html", "about:blank"] {
            XCTAssertNil(toggle(url: url, bridge: bridge), url)
        }
    }

    func testStateIsUnknownUntilRefreshedThenReflectsTheException() throws {
        let bridge = DomainBridge()
        bridge.siteExceptions = ["www.example.com"]
        let toggle = try XCTUnwrap(toggle(bridge: bridge))
        XCTAssertNil(toggle.isBlocking)
        XCTAssertEqual(toggle.menuState, .mixed)

        toggle.settings.refresh()
        let read = expectation(description: "state read")
        DispatchQueue.main.async { read.fulfill() }
        wait(for: [read], timeout: 1)
        XCTAssertEqual(toggle.isBlocking, false)
        XCTAssertEqual(toggle.menuState, .off)
    }

    func testTogglingWritesTheOppositeExceptionAndRevertsOnFailure() throws {
        let bridge = DomainBridge()
        let toggle = try XCTUnwrap(toggle(bridge: bridge))
        toggle.settings.refresh()
        let read = expectation(description: "state read")
        DispatchQueue.main.async { read.fulfill() }
        wait(for: [read], timeout: 1)
        XCTAssertEqual(toggle.isBlocking, true)

        let accepted = expectation(description: "accepted")
        toggle.toggle { ok in
            XCTAssertTrue(ok)
            accepted.fulfill()
        }
        wait(for: [accepted], timeout: 1)
        XCTAssertEqual(bridge.exceptionCalls.count, 1)
        XCTAssertEqual(bridge.exceptionCalls[0].0, "Profile 2")
        XCTAssertEqual(bridge.exceptionCalls[0].1, "www.example.com")
        XCTAssertTrue(bridge.exceptionCalls[0].2)
        XCTAssertEqual(toggle.isBlocking, false)

        bridge.acceptWrites = false
        let rejected = expectation(description: "rejected")
        toggle.toggle { ok in
            XCTAssertFalse(ok)
            rejected.fulfill()
        }
        wait(for: [rejected], timeout: 1)
        XCTAssertFalse(bridge.exceptionCalls[1].2)
        XCTAssertEqual(toggle.isBlocking, false, "a rejected write leaves the previous state")
    }

    func testMenuItemStartsIndeterminateAndFollowsTheState() throws {
        let bridge = DomainBridge()
        let toggle = try XCTUnwrap(toggle(bridge: bridge))
        var reloads = 0
        let item = toggle.makeMenuItem { reloads += 1 }
        XCTAssertEqual(item.title, SiteContentBlockingToggle.title)
        XCTAssertNotNil(item.target)
        XCTAssertNotNil(item.action)

        let read = expectation(description: "state read")
        DispatchQueue.main.async { read.fulfill() }
        wait(for: [read], timeout: 1)
        XCTAssertEqual(item.state, .on)
        XCTAssertTrue(item.isEnabled)

        _ = item.target?.perform(item.action, with: item)
        let written = expectation(description: "written")
        DispatchQueue.main.async { written.fulfill() }
        wait(for: [written], timeout: 1)
        XCTAssertEqual(item.state, .off)
        XCTAssertEqual(reloads, 1)
    }
}

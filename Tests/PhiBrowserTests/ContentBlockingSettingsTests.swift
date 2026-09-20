// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// A bridge stand-in that answers from canned settings and records calls.
private final class FakeContentBlockingBridge: ContentBlockingBridging {
    var settings: (any PhiContentBlockingSettings)?
    var error: String?
    var failWrites = false
    var refreshCount = 0
    var categoryCalls: [(PhiContentBlockingCategory, Bool)] = []
    var listCalls: [(String, Bool)] = []

    func getContentBlockingSettings(_ profileId: String,
                                    completion: @escaping ((any PhiContentBlockingSettings)?, String?) -> Void) {
        refreshCount += 1
        completion(settings, error)
    }

    func setContentBlockingCategory(_ profileId: String,
                                    category: PhiContentBlockingCategory,
                                    enabled: Bool,
                                    completion: @escaping (Bool, String?) -> Void) {
        categoryCalls.append((category, enabled))
        completion(!failWrites, failWrites ? "nope" : nil)
    }

    func setContentBlockingList(_ profileId: String,
                                listId: String,
                                enabled: Bool,
                                completion: @escaping (Bool, String?) -> Void) {
        listCalls.append((listId, enabled))
        completion(!failWrites, failWrites ? "nope" : nil)
    }

    func setContentBlockingSiteException(_ profileId: String,
                                         domain: String,
                                         enabled: Bool,
                                         completion: @escaping (Bool, String?) -> Void) {
        completion(!failWrites, failWrites ? "nope" : nil)
    }

    func contentBlockingSiteExceptionDomain(forURL url: String) -> String {
        URL(string: url)?.host ?? ""
    }

    var customCalls: [(String, String?, String?)] = []
    var removeCalls: [String] = []
    var refreshCalls = 0

    func addContentBlockingCustomList(_ profileId: String, name: String, url: String?, rules: String?,
                                      completion: @escaping (String?, String?) -> Void) {
        customCalls.append((name, url, rules))
        completion(failWrites ? nil : "custom-1", failWrites ? "nope" : nil)
    }

    func removeContentBlockingCustomList(_ profileId: String, listId: String,
                                         completion: @escaping (Bool, String?) -> Void) {
        removeCalls.append(listId)
        completion(!failWrites, failWrites ? "nope" : nil)
    }

    func refreshContentBlockingLists(_ profileId: String, completion: @escaping (Bool, String?) -> Void) {
        refreshCalls += 1
        completion(true, nil)
    }

    var downloadCalls: [String] = []
    var deleteDownloadCalls: [String] = []

    func downloadContentBlockingList(_ profileId: String, listId: String,
                                     completion: @escaping (Bool, String?) -> Void) {
        downloadCalls.append(listId)
        completion(!failWrites, failWrites ? "nope" : nil)
    }

    func deleteContentBlockingListDownload(_ profileId: String, listId: String,
                                           completion: @escaping (Bool, String?) -> Void) {
        deleteDownloadCalls.append(listId)
        completion(!failWrites, failWrites ? "nope" : nil)
    }
}

/// Swift stand-ins for the framework's protocol-typed snapshot objects.
final class FakeListInfo: NSObject, PhiContentBlockingListInfo {
    let listId: String
    let category: String
    let homepage: String
    let license: String
    let langs: [String]
    let checked: Bool
    let defaultChecked: Bool
    var name = ""
    var custom = false
    var sourceURL = ""
    var available = true
    var fetchedAt: TimeInterval = 0
    var lastError = ""

    init(_ id: String, category: String, checked: Bool) {
        listId = id
        self.category = category
        homepage = "https://example.org"
        license = "GPL-3.0"
        langs = []
        self.checked = checked
        defaultChecked = true
    }
}

final class FakeSettings: NSObject, PhiContentBlockingSettings {
    var blockAds: Bool
    var blockCookieBanners: Bool
    var blockTrackers: Bool
    var lists: [any PhiContentBlockingListInfo]
    var siteExceptions: [String]
    var status: String
    var statusDetail: String
    var generationId: Int64
    var builtAt: TimeInterval
    var sessionBlockedCount: UInt64 = 0
    var lastBuildLog: String = ""

    init(blockAds: Bool = true, blockCookieBanners: Bool = true, blockTrackers: Bool = false,
         status: String = "active", lists: [any PhiContentBlockingListInfo]? = nil,
         siteExceptions: [String] = ["example.com"]) {
        self.blockAds = blockAds
        self.blockCookieBanners = blockCookieBanners
        self.blockTrackers = blockTrackers
        self.lists = lists ?? [FakeListInfo("easylist", category: "ads", checked: true),
                               FakeListInfo("adguard-japanese", category: "regional", checked: false)]
        self.siteExceptions = siteExceptions
        self.status = status
        statusDetail = ""
        generationId = 7
        builtAt = 1_700_000_000
    }
}

private func makeSettings(blockAds: Bool = true,
                          status: String = "active") -> any PhiContentBlockingSettings {
    FakeSettings(blockAds: blockAds, status: status)
}

final class ContentBlockingSettingsTests: XCTestCase {
    private var bridge: FakeContentBlockingBridge!
    private var center: NotificationCenter!

    override func setUp() {
        super.setUp()
        bridge = FakeContentBlockingBridge()
        bridge.settings = makeSettings()
        center = NotificationCenter()
    }

    private func makeFacade() -> ContentBlockingSettings {
        ContentBlockingSettings(profileId: "Default", bridge: bridge, notificationCenter: center)
    }

    private func waitForMain() {
        let done = expectation(description: "main queue drained")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    func testDownloadAndDeleteDownloadUpdateTheRowOptimistically() {
        let facade = makeFacade()
        facade.refresh()
        waitForMain()
        facade.deleteListDownload("easylist")
        var list = facade.state?.lists.first { $0.id == "easylist" }
        XCTAssertEqual(bridge.deleteDownloadCalls, ["easylist"])
        XCTAssertEqual(list?.available, false)
        XCTAssertEqual(list?.checked, false)

        facade.downloadList("easylist")
        list = facade.state?.lists.first { $0.id == "easylist" }
        XCTAssertEqual(bridge.downloadCalls, ["easylist"])
        XCTAssertEqual(list?.available, false)
        XCTAssertEqual(list?.lastError, "")

        bridge.failWrites = true
        let before = facade.state
        facade.deleteListDownload("adguard-japanese")
        waitForMain()
        XCTAssertEqual(facade.state, before, "a refused delete reverts the row")
    }

    func testRefreshMapsBridgePayload() {
        let facade = makeFacade()
        facade.refresh()
        waitForMain()

        let state = try? XCTUnwrap(facade.state)
        XCTAssertEqual(state?.blockAds, true)
        XCTAssertEqual(state?.blockCookieBanners, true)
        XCTAssertEqual(state?.blockTrackers, false)
        XCTAssertEqual(state?.status, .active)
        XCTAssertEqual(state?.siteExceptions, ["example.com"])
        XCTAssertEqual(state?.lists.map(\.id), ["easylist", "adguard-japanese"])
        XCTAssertEqual(state?.lists.first?.title, "EasyList")
        XCTAssertEqual(state?.lists.first?.homepage, URL(string: "https://example.org"))
        XCTAssertEqual(state?.lists.first?.checked, true)
        XCTAssertEqual(state?.lists.last?.checked, false)
    }

    func testSetCategoryOptimisticThenConfirmed() {
        let facade = makeFacade()
        facade.refresh()
        waitForMain()

        var confirmed: Bool?
        facade.setCategory(.trackers, enabled: true) { confirmed = $0 }
        // Optimistic: the flag flips before the bridge answers on main.
        XCTAssertEqual(facade.state?.blockTrackers, true)
        waitForMain()
        XCTAssertEqual(confirmed, true)
        XCTAssertEqual(facade.state?.blockTrackers, true)
        XCTAssertEqual(bridge.categoryCalls.count, 1)
        XCTAssertEqual(bridge.categoryCalls.first?.0, .trackers)
        XCTAssertEqual(bridge.categoryCalls.first?.1, true)
    }

    func testSetCategoryRevertsOnFailure() {
        let facade = makeFacade()
        facade.refresh()
        waitForMain()
        bridge.failWrites = true

        var confirmed: Bool?
        facade.setCategory(.ads, enabled: false) { confirmed = $0 }
        XCTAssertEqual(facade.state?.blockAds, false)
        waitForMain()
        XCTAssertEqual(confirmed, false)
        XCTAssertEqual(facade.state?.blockAds, true)

        facade.setList("easylist", checked: false) { _ in }
        XCTAssertEqual(facade.state?.lists.first?.checked, false)
        waitForMain()
        XCTAssertEqual(facade.state?.lists.first?.checked, true)
    }

    func testBridgeUnavailableLeavesStateNil() {
        let facade = ContentBlockingSettings(profileId: "Default", bridge: nil, notificationCenter: center)
        facade.refresh()
        waitForMain()
        XCTAssertNil(facade.state)

        var confirmed: Bool?
        facade.setCategory(.ads, enabled: false) { confirmed = $0 }
        XCTAssertEqual(confirmed, false)
        XCTAssertNil(facade.state)
    }

    func testStatusNotificationTriggersRefresh() {
        let facade = makeFacade()
        facade.refresh()
        waitForMain()
        XCTAssertEqual(bridge.refreshCount, 1)

        center.post(name: .contentBlockingStatusChanged, object: "Other")
        waitForMain()
        XCTAssertEqual(bridge.refreshCount, 1, "another profile's change is ignored")

        bridge.settings = makeSettings(status: "building")
        center.post(name: .contentBlockingStatusChanged, object: "Default")
        waitForMain()
        waitForMain()
        XCTAssertEqual(bridge.refreshCount, 2)
        XCTAssertEqual(facade.state?.status, .building)
        _ = facade
    }
}

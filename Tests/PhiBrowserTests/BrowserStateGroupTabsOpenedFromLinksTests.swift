// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// Records the tab-group operations `BrowserState` hands the Chromium bridge.
final class FakeTabGroupBridge: TabGroupBridging {
    struct Create: Equatable {
        let tabIds: [Int]
        let title: String?
        let windowId: Int
    }

    var creates: [Create] = []
    var adds: [(tabIds: [Int], token: String, windowId: Int)] = []
    var tokenToReturn: String? = "NEWGROUPTOKEN"

    func createGroup(tabIds: [Int], title: String?, windowId: Int) -> String? {
        creates.append(Create(tabIds: tabIds, title: title, windowId: windowId))
        return tokenToReturn
    }

    func addTabs(_ tabIds: [Int], toGroup token: String, windowId: Int) {
        adds.append((tabIds, token, windowId))
    }
}

/// "Group tabs opened from links": a link the user opens in a new tab on
/// purpose from a regular tab that is not in a tab group forms a new tab
/// group with that tab (its Opener), named after the Opener.
@MainActor
final class BrowserStateGroupTabsOpenedFromLinksTests: XCTestCase {
    private var tempDirectories: [URL] = []
    private var originalSetting: Any?
    private let settingKey = PhiPreferences.GeneralSettings.groupTabsOpenedFromLinks.rawValue

    override func setUpWithError() throws {
        originalSetting = UserDefaults.standard.object(forKey: settingKey)
        UserDefaults.standard.set(true, forKey: settingKey)
    }

    override func tearDownWithError() throws {
        if let originalSetting {
            UserDefaults.standard.set(originalSetting, forKey: settingKey)
        } else {
            UserDefaults.standard.removeObject(forKey: settingKey)
        }
        originalSetting = nil
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    private func makeState(bridge: FakeTabGroupBridge,
                           isKioskWindow: Bool = false,
                           isAgentSpace: Bool = false) throws -> BrowserState {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        let store = LocalStore(account: Account(userID: UUID().uuidString),
                               storeDirectoryURL: directory)
        return BrowserState(windowId: 7, localStore: store, profileId: "Default",
                            isKioskWindow: isKioskWindow,
                            isAgentSpace: isAgentSpace,
                            tabGroupBridge: bridge)
    }

    private func waitUntil(timeout: TimeInterval = 1, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTFail("Condition was not met before timeout.")
        return false
    }

    /// Three regular, ungrouped tabs; tab 1 shows an article.
    private func seed(_ state: BrowserState) {
        state.tabs = [
            Tab(guid: 1, url: "https://www.news.example/article", isActive: true, index: 0,
                title: "An Article"),
            Tab(guid: 2, url: "https://b.example", isActive: false, index: 1, title: "B"),
            Tab(guid: 3, url: "https://c.example", isActive: false, index: 2, title: "C"),
        ]
        state.updateNormalTabs()
    }

    private func linkContext(opener: Int?,
                             foreground: Bool = false,
                             userOpened: Bool = true) -> NativeTabCreationContext {
        NativeTabCreationContext(
            isActiveAtCreation: foreground,
            creationKind: foreground ? .linkForeground : .linkBackground,
            openerTabId: opener,
            insertAfterTabId: opener,
            sourceTabId: opener,
            isUserOpenedNewTab: userOpened
        )
    }

    private func arrive(_ state: BrowserState,
                        guid: Int = 10,
                        groupToken: String? = nil,
                        context: NativeTabCreationContext) {
        let tab = Tab(guid: guid, url: "https://linked.example/\(guid)", isActive: false, index: 3)
        tab.groupToken = groupToken
        state.handleNewTabFromChromium(tab, context: context)
    }

    // MARK: - Forming a group

    func testABackgroundLinkOpenedOnPurposeFormsAGroupWithItsOpener() throws {
        let bridge = FakeTabGroupBridge()
        let state = try makeState(bridge: bridge)
        seed(state)

        arrive(state, context: linkContext(opener: 1))

        XCTAssertEqual(bridge.creates, [.init(tabIds: [1, 10], title: "An Article", windowId: 7)])
    }

    func testAForegroundLinkOpenedOnPurposeFormsAGroupWithItsOpener() throws {
        let bridge = FakeTabGroupBridge()
        let state = try makeState(bridge: bridge)
        seed(state)

        arrive(state, context: linkContext(opener: 1, foreground: true))

        XCTAssertEqual(bridge.creates, [.init(tabIds: [1, 10], title: "An Article", windowId: 7)])
    }

    func testTheOpenerAndTheNewTabFormOneRunAndEarlierTabsFromTheOpenerStayOutside() throws {
        let bridge = FakeTabGroupBridge()
        let state = try makeState(bridge: bridge)
        seed(state)
        // A tab the page opened from the Opener earlier sits right after it.
        arrive(state, guid: 4, context: linkContext(opener: 1, userOpened: false))
        XCTAssertEqual(state.normalTabs.map(\.guid), [1, 4, 2, 3])

        arrive(state, context: linkContext(opener: 1))

        XCTAssertEqual(state.normalTabs.map(\.guid), [1, 10, 4, 2, 3])
        XCTAssertEqual(state.normalTabs.filter { $0.groupToken == "NEWGROUPTOKEN" }.map(\.guid),
                       [1, 10])
    }

    func testAnOpenerInASplitBringsTheWholeSplitIntoTheGroup() throws {
        let bridge = FakeTabGroupBridge()
        let state = try makeState(bridge: bridge)
        seed(state)
        state.splits = [SplitGroup(id: "split-1-2", tabIds: [1, 2], layout: .vertical,
                                   fractions: [0.5, 0.5])]
        state.updateNormalTabs()

        arrive(state, context: linkContext(opener: 1))

        XCTAssertEqual(bridge.creates.map(\.tabIds), [[1, 2, 10]])
        XCTAssertEqual(state.normalTabs.map(\.guid), [1, 2, 10, 3])
        XCTAssertEqual(state.normalTabs.filter { $0.groupToken == "NEWGROUPTOKEN" }.map(\.guid),
                       [1, 2, 10])
    }

    func testWhenChromiumRefusesTheGroupTheTabsStayWhereTheyWere() throws {
        let bridge = FakeTabGroupBridge()
        bridge.tokenToReturn = nil
        let state = try makeState(bridge: bridge)
        seed(state)
        arrive(state, guid: 4, context: linkContext(opener: 1, userOpened: false))

        arrive(state, context: linkContext(opener: 1))

        XCTAssertEqual(state.normalTabs.map(\.guid), [1, 4, 10, 2, 3])
        XCTAssertTrue(state.normalTabs.allSatisfy { $0.groupToken == nil })
    }

    func testASearchResultsOpenerNamesTheGroupAfterTheSearchTerms() throws {
        let bridge = FakeTabGroupBridge()
        let state = try makeState(bridge: bridge)
        seed(state)

        // As Chromium sends it for a Cmd-click on a search results page.
        arrive(state, context: NativeTabCreationContext(dictionary: [
            "creationKind": "linkBackground",
            "openerTabId": 1,
            "insertAfterTabId": 1,
            "sourceTabId": 1,
            "isUserOpenedNewTab": true,
            "openerSearchTerms": "rust async",
        ]))

        XCTAssertEqual(bridge.creates.map(\.title), ["rust async"])
    }

    func testAnEmptyOpenerTitleNamesTheGroupAfterTheOpenersSite() throws {
        let bridge = FakeTabGroupBridge()
        let state = try makeState(bridge: bridge)
        seed(state)
        state.tabs[0].title = " "

        arrive(state, context: linkContext(opener: 1))

        XCTAssertEqual(bridge.creates.map(\.title), ["news.example"])
    }

    // MARK: - No group

    func testWithTheSettingOffNoGroupIsFormed() throws {
        UserDefaults.standard.set(false, forKey: settingKey)
        let bridge = FakeTabGroupBridge()
        let state = try makeState(bridge: bridge)
        seed(state)

        arrive(state, context: linkContext(opener: 1))

        XCTAssertEqual(bridge.creates, [])
    }

    func testATabThePageOpenedByItselfFormsNoGroup() throws {
        let bridge = FakeTabGroupBridge()
        let state = try makeState(bridge: bridge)
        seed(state)

        arrive(state, context: linkContext(opener: 1, userOpened: false))

        XCTAssertEqual(bridge.creates, [])
    }

    func testATabThatArrivedInAGroupFormsNoGroup() throws {
        let bridge = FakeTabGroupBridge()
        let state = try makeState(bridge: bridge)
        seed(state)

        arrive(state, groupToken: "USERGROUPTOKEN", context: linkContext(opener: 1))

        XCTAssertEqual(bridge.creates, [])
    }

    func testAnOpenerInAGroupIsNotTakenOutOfIt() throws {
        let bridge = FakeTabGroupBridge()
        let state = try makeState(bridge: bridge)
        seed(state)
        state.tabs[0].groupToken = "USERGROUPTOKEN"

        arrive(state, context: linkContext(opener: 1))

        XCTAssertEqual(bridge.creates, [])
    }

    func testABookmarkTabOpenerFormsNoGroupYet() throws {
        let bridge = FakeTabGroupBridge()
        let state = try makeState(bridge: bridge)
        seed(state)
        state.tabs[0].guidInLocalDB = "bookmark-guid"
        state.updateNormalTabs()

        arrive(state, context: linkContext(opener: 1))

        XCTAssertEqual(bridge.creates, [])
    }

    func testABookmarkedSplitOpenerFormsNoGroupYet() throws {
        let bridge = FakeTabGroupBridge()
        let state = try makeState(bridge: bridge)
        seed(state)
        state.localStore.createBookmark(url: "https://www.news.example/article",
                                        title: "Split",
                                        profileId: state.profileId,
                                        parentId: nil,
                                        guid: "bookmark-split",
                                        spaceId: state.spaceId,
                                        secondaryUrl: "https://b.example")
        guard waitUntil({ state.bookmarkManager.bookmark(withGuid: "bookmark-split") != nil }) else {
            return
        }
        state.splits = [SplitGroup(id: "split-1-2", tabIds: [1, 2], layout: .vertical,
                                   fractions: [0.5, 0.5])]
        state.splitBookmarkBindings["bookmark-split"] = "split-1-2"
        state.updateNormalTabs()

        arrive(state, context: linkContext(opener: 1))

        XCTAssertEqual(bridge.creates, [])
    }

    func testNoGroupIsFormedInAnAgentSpace() throws {
        let bridge = FakeTabGroupBridge()
        let state = try makeState(bridge: bridge, isAgentSpace: true)
        seed(state)

        arrive(state, context: linkContext(opener: 1))

        XCTAssertEqual(bridge.creates, [])
    }

    func testNoGroupIsFormedInAKioskWindow() throws {
        let bridge = FakeTabGroupBridge()
        let state = try makeState(bridge: bridge, isKioskWindow: true)
        seed(state)

        arrive(state, context: linkContext(opener: 1))

        XCTAssertEqual(bridge.creates, [])
    }

    func testATabWithoutAnOpenerFormsNoGroup() throws {
        let bridge = FakeTabGroupBridge()
        let state = try makeState(bridge: bridge)
        seed(state)

        arrive(state, context: linkContext(opener: nil))

        XCTAssertEqual(bridge.creates, [])
    }

    func testAnOpenerInAnotherWindowFormsNoGroup() throws {
        let bridge = FakeTabGroupBridge()
        let state = try makeState(bridge: bridge)
        seed(state)

        arrive(state, context: linkContext(opener: 99))

        XCTAssertEqual(bridge.creates, [])
    }
}

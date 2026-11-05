// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

@MainActor
final class BrowserStateGroupOverviewTests: XCTestCase {

    private var tempDirectories: [URL] = []

    override func tearDownWithError() throws {
        let fileManager = FileManager.default
        for directory in tempDirectories {
            try? fileManager.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    private func makeTemporaryStoreDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        return directory
    }

    private func makeBrowserState(profileId: String = "Default") throws -> BrowserState {
        let directory = try makeTemporaryStoreDirectory()
        let store = LocalStore(account: Account(userID: UUID().uuidString),
                               storeDirectoryURL: directory)
        return BrowserState(windowId: 7, localStore: store, profileId: profileId)
    }

    @discardableResult
    private func seed(state: BrowserState,
                      tabs: [(guid: Int, url: String, token: String?)]) -> [Tab] {
        let constructed: [Tab] = tabs.map { spec in
            Tab(guid: spec.guid, url: spec.url, isActive: false, index: 0)
        }
        state.tabs = constructed
        state.updateNormalTabs()

        let tokens = Set(tabs.compactMap { $0.token })
        for token in tokens {
            let initialIds = tabs.filter { $0.token == token }.map { $0.guid }
            state.handleTabGroupCreated(token: token,
                                        title: "",
                                        color: .blue,
                                        isCollapsed: false,
                                        initialTabIds: initialIds)
        }
        return constructed
    }

    func testShowGroupOverviewStoresOnlyTokenForKnownNonEmptyGroup() throws {
        let state = try makeBrowserState()
        seed(state: state, tabs: [
            (guid: 100, url: "https://n1.example", token: nil),
            (guid: 200, url: "https://a1.example", token: "A"),
        ])

        state.showGroupOverview(token: "A")

        XCTAssertEqual(state.groupOverviewState, GroupOverviewState(groupToken: "A"))
        XCTAssertEqual(state.activeGroupOverviewToken, "A")
    }

    func testShowGroupOverviewCollapsesFocusedAIChatAndSplitPartner() throws {
        let state = try makeBrowserState()
        let tabs = seed(state: state, tabs: [
            (guid: 200, url: "https://a1.example", token: "A"),
            (guid: 201, url: "https://a2.example", token: "A"),
        ])
        state.splits = [
            SplitGroup(id: "split-1",
                       tabIds: [200, 201],
                       layout: .vertical,
                       fractions: [0.5, 0.5])
        ]
        tabs[0].toggleAIChat(false)
        tabs[1].toggleAIChat(false)
        state.focuseTab(tabs[0])

        state.showGroupOverview(token: "A")

        XCTAssertTrue(tabs[0].aiChatCollapsed)
        XCTAssertTrue(tabs[1].aiChatCollapsed)
        XCTAssertTrue(state.aiChatCollapsed)
    }

    func testToggleAIChatDoesNotExpandWhileOverviewIsActive() throws {
        let state = try makeBrowserState()
        let tabs = seed(state: state, tabs: [
            (guid: 200, url: "https://a1.example", token: "A"),
        ])
        tabs[0].aiChatEnabled = true
        state.focuseTab(tabs[0])
        state.showGroupOverview(token: "A")

        state.toggleAIChat(false)

        XCTAssertTrue(tabs[0].aiChatCollapsed)
        XCTAssertTrue(state.aiChatCollapsed)
    }

    func testShowGroupOverviewIgnoresUnknownTokenAndLeavesStateNil() throws {
        let state = try makeBrowserState()
        seed(state: state, tabs: [
            (guid: 200, url: "https://a1.example", token: "A"),
        ])

        state.showGroupOverview(token: "DOES_NOT_EXIST")

        XCTAssertNil(state.groupOverviewState)
    }

    func testHandleTabGroupClosedClearsOverviewForActiveGroup() throws {
        let state = try makeBrowserState()
        seed(state: state, tabs: [
            (guid: 200, url: "https://a1.example", token: "A"),
        ])
        state.showGroupOverview(token: "A")

        state.handleTabGroupClosed(token: "A")

        XCTAssertNil(state.groupOverviewState)
    }

    func testHandleTabLeftGroupKeepsOverviewUntilLastMemberLeaves() throws {
        let state = try makeBrowserState()
        seed(state: state, tabs: [
            (guid: 200, url: "https://a1.example", token: "A"),
            (guid: 201, url: "https://a2.example", token: "A"),
        ])
        state.showGroupOverview(token: "A")

        state.handleTabLeftGroup(tabId: 200, token: "A")

        XCTAssertEqual(state.activeGroupOverviewToken, "A")

        state.handleTabLeftGroup(tabId: 201, token: "A")

        XCTAssertNil(state.groupOverviewState)
    }

    func testFocuseTabClearsOverview() throws {
        let state = try makeBrowserState()
        let tabs = seed(state: state, tabs: [
            (guid: 100, url: "https://n1.example", token: nil),
            (guid: 200, url: "https://a1.example", token: "A"),
        ])
        state.showGroupOverview(token: "A")

        state.focuseTab(tabs[0])

        XCTAssertNil(state.groupOverviewState)
    }

    func testOpenBookmarkClearsOverview() throws {
        let state = try makeBrowserState()
        seed(state: state, tabs: [
            (guid: 200, url: "https://a1.example", token: "A"),
        ])
        state.showGroupOverview(token: "A")
        let bookmark = Bookmark(title: "Bookmark", url: "https://bookmark.example")

        state.openBookmark(bookmark)

        XCTAssertNil(state.groupOverviewState)
    }

    func testOverviewCreatedTabInsertionWaitsForMatchingGroupTab() throws {
        let state = try makeBrowserState()
        seed(state: state, tabs: [
            (guid: 100, url: "https://n1.example", token: nil),
            (guid: 200, url: "https://a1.example", token: "A"),
            (guid: 201, url: "https://a2.example", token: "A"),
        ])
        state.showGroupOverview(token: "A")

        state.createTabInCurrentOverviewGroup(url: "https://created.example")
        let unrelatedTab = Tab(guid: 300, url: "https://unrelated.example", isActive: false, index: 0)
        state.handleNewTabFromChromium(unrelatedTab)

        XCTAssertEqual(state.normalTabs.map(\.guid), [100, 200, 201, 300])

        let createdGroupTab = Tab(guid: 400, url: "https://created.example", isActive: true, index: 0)
        createdGroupTab.groupToken = "A"
        state.handleNewTabFromChromium(createdGroupTab)

        XCTAssertEqual(state.normalTabs.map(\.guid), [100, 400, 200, 201, 300])
    }

    func testOverviewNewTabCardInsertionAppendsToGroup() throws {
        let state = try makeBrowserState()
        seed(state: state, tabs: [
            (guid: 100, url: "https://n1.example", token: nil),
            (guid: 200, url: "https://a1.example", token: "A"),
            (guid: 201, url: "https://a2.example", token: "A"),
            (guid: 300, url: "https://n2.example", token: nil),
        ])
        state.showGroupOverview(token: "A")

        state.createNewTabAtEndOfCurrentOverviewGroup()
        let createdGroupTab = Tab(guid: 400, url: "chrome://newtab/", isActive: true, index: 0)
        createdGroupTab.groupToken = "A"
        state.handleNewTabFromChromium(createdGroupTab)

        XCTAssertEqual(state.normalTabs.map(\.guid), [100, 200, 201, 400, 300])
    }
}

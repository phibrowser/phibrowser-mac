// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

/// Closing the focused tab returns to the tab the user used before it,
/// whatever its position in the strip.
@MainActor
final class BrowserStateCloseSelectionTests: XCTestCase {
    private var tempDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    /// Strip order B, A, C; visited C, then B, then A. Chromium picks A's
    /// right neighbour C, but B was used last before A.
    func testClosingTheFocusedTabSelectsThePreviouslyUsedTab() throws {
        let state = try makeState()
        let a = makeTab(1), b = makeTab(2), c = makeTab(3)
        state.tabs = [b.tab, a.tab, c.tab]
        state.normalTabs = state.tabs
        state.focuseTab(c.tab)
        state.focuseTab(b.tab)
        state.focuseTab(a.tab)

        state.applyTabsRemoved([a.tab.guid], activeTabId: c.tab.guid)

        XCTAssertEqual(b.wrapper.setAsActiveTabCallCount, 1)
        XCTAssertEqual(c.wrapper.setAsActiveTabCallCount, 0)
    }

    /// When Chromium already picked the previously used tab, it is focused
    /// without a second activation.
    func testChromiumPickingThePreviouslyUsedTabIsAccepted() throws {
        let state = try makeState()
        let a = makeTab(1), b = makeTab(2), c = makeTab(3)
        state.tabs = [a.tab, b.tab, c.tab]
        state.normalTabs = state.tabs
        state.focuseTab(c.tab)
        state.focuseTab(b.tab)
        state.focuseTab(a.tab)

        state.applyTabsRemoved([a.tab.guid], activeTabId: b.tab.guid)

        XCTAssertTrue(state.focusingTab === b.tab)
        XCTAssertEqual(b.wrapper.setAsActiveTabCallCount, 0)
        XCTAssertEqual(c.wrapper.setAsActiveTabCallCount, 0)
    }

    /// A focused tab outside the normal strip (an open pinned or bookmark
    /// tab) still returns to the previously used tab, not Chromium's pick.
    func testClosingAFocusedTabOutsideTheStripSelectsThePreviouslyUsedTab() throws {
        let state = try makeState()
        let pinned = makeTab(1), b = makeTab(2), c = makeTab(3)
        state.tabs = [pinned.tab, b.tab, c.tab]
        state.normalTabs = [b.tab, c.tab]
        state.focuseTab(c.tab)
        state.focuseTab(b.tab)
        state.focuseTab(pinned.tab)

        state.applyTabsRemoved([pinned.tab.guid], activeTabId: c.tab.guid)

        XCTAssertEqual(b.wrapper.setAsActiveTabCallCount, 1)
        XCTAssertEqual(c.wrapper.setAsActiveTabCallCount, 0)
    }

    /// With no other tab ever visited, the strip-relative rule still applies:
    /// the right neighbour, not Chromium's pick.
    func testWithNothingElseVisitedTheStripRuleApplies() throws {
        let state = try makeState()
        let a = makeTab(1), b = makeTab(2), c = makeTab(3)
        state.tabs = [a.tab, b.tab, c.tab]
        state.normalTabs = state.tabs
        state.focuseTab(a.tab)

        state.applyTabsRemoved([a.tab.guid], activeTabId: c.tab.guid)

        XCTAssertEqual(b.wrapper.setAsActiveTabCallCount, 1)
        XCTAssertEqual(c.wrapper.setAsActiveTabCallCount, 0)
    }

    /// A pane closing out of a split that stays up keeps focus in the split,
    /// ahead of the previously used tab outside it.
    func testClosingAPaneOfASplitThatStaysUpKeepsFocusInTheSplit() throws {
        let state = try makeState()
        let other = makeTab(1), pane = makeTab(2), second = makeTab(3), third = makeTab(4)
        state.tabs = [other.tab, pane.tab, second.tab, third.tab]
        state.normalTabs = state.tabs
        state.splits = [
            SplitGroup(id: "split", tabIds: [pane.tab.guid, second.tab.guid, third.tab.guid],
                       layout: .vertical, fractions: [1, 1, 1])
        ]
        state.focuseTab(other.tab)
        state.focuseTab(pane.tab)

        state.applyTabsRemoved([pane.tab.guid], activeTabId: other.tab.guid)

        XCTAssertEqual(second.wrapper.setAsActiveTabCallCount, 1)
        XCTAssertEqual(other.wrapper.setAsActiveTabCallCount, 0)
    }

    // MARK: - Helpers

    private func makeState() throws -> BrowserState {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        let store = LocalStore(account: Account(userID: UUID().uuidString),
                               storeDirectoryURL: directory)
        return BrowserState(windowId: 7, localStore: store, profileId: "Default")
    }

    private func makeTab(_ guid: Int) -> (tab: Tab, wrapper: PageColorTestWebContentWrapper) {
        let wrapper = PageColorTestWebContentWrapper(urlString: "https://e\(guid).example")
        let tab = Tab(guid: guid, url: wrapper.urlString, isActive: false, index: 0,
                      webContentView: wrapper)
        return (tab, wrapper)
    }
}

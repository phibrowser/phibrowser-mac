// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

/// A floating surface's tab (a peek, a reader overlay) is a Chromium strip tab
/// kept out of `tabs` and never meant to be active: its opener or origin holds
/// strip-active beneath the panel. Chromium does not know that and can pick it
/// when another tab closes, so the activation goes back to that anchor tab.
/// Staying on the surface's tab would leave nothing mounted in the page area.
@MainActor
final class BrowserStateSurfaceActivationTests: XCTestCase {
    private var tempDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    /// PHI-1858. A pinned opener is not a normal tab, so closing the only
    /// normal tab sets no override and Chromium's pick stands.
    func testClosingTheOnlyNormalTabWhenChromiumPicksAPinnedTabsPeekActivatesTheOpener() throws {
        let state = try makeState()
        let opener = makeTab(1)
        let peek = makeTab(2)
        let closing = makeTab(3)
        state.tabs = [opener.tab, closing.tab]
        state.normalTabs = [closing.tab]
        state.focusingTab = closing.tab
        state.peekState.present(peek.tab, openerTabId: opener.tab.guid)

        state.applyTabsRemoved([closing.tab.guid], activeTabId: peek.tab.guid)

        XCTAssertEqual(opener.wrapper.setAsActiveTabCallCount, 1)
        XCTAssertEqual(peek.wrapper.setAsActiveTabCallCount, 0)

        // Chromium reports the opener active: the page and its peek come back.
        state.handleChromiumActiveTabChanged(opener.tab.guid)

        XCTAssertTrue(state.focusingTab === opener.tab)
        XCTAssertTrue(state.visiblePeek(focusingTab: state.focusingTab)?.tab === peek.tab)
    }

    /// A regular opener is a normal tab, so the close override already corrects
    /// Chromium's pick; the activation must not be sent twice.
    func testARegularOpenerIsActivatedOnceByTheCloseOverride() throws {
        let state = try makeState()
        let opener = makeTab(1)
        let peek = makeTab(2)
        let closing = makeTab(3)
        state.tabs = [opener.tab, closing.tab]
        state.normalTabs = [opener.tab, closing.tab]
        state.focusingTab = closing.tab
        state.peekState.present(peek.tab, openerTabId: opener.tab.guid)

        state.applyTabsRemoved([closing.tab.guid], activeTabId: peek.tab.guid)

        XCTAssertEqual(opener.wrapper.setAsActiveTabCallCount, 1)
    }

    /// One peek per opener: the anchor is that peek's own opener, whichever
    /// tab is focused.
    func testAHiddenPeekActivatesItsOwnOpener() throws {
        let state = try makeState()
        let opener = makeTab(1)
        let peek = makeTab(2)
        let focused = makeTab(3)
        state.tabs = [opener.tab, focused.tab]
        state.focusingTab = focused.tab
        state.peekState.present(peek.tab, openerTabId: opener.tab.guid)

        state.handleChromiumActiveTabChanged(peek.tab.guid)

        XCTAssertEqual(opener.wrapper.setAsActiveTabCallCount, 1)
        XCTAssertEqual(focused.wrapper.setAsActiveTabCallCount, 0)
    }

    func testAReaderActivatesItsOrigin() throws {
        let state = try makeState()
        let origin = makeTab(1)
        let reader = makeTab(2)
        state.tabs = [origin.tab]
        state.readerOverlayState.present(reader.tab, originTabId: origin.tab.guid)

        state.handleChromiumActiveTabChanged(reader.tab.guid)

        XCTAssertEqual(origin.wrapper.setAsActiveTabCallCount, 1)
    }

    /// A peek is no strip anchor itself: its opener holds strip-active.
    func testAReaderOverAPeekActivatesThePeeksOpener() throws {
        let state = try makeState()
        let opener = makeTab(1)
        let peek = makeTab(2)
        let reader = makeTab(3)
        state.tabs = [opener.tab]
        state.peekState.present(peek.tab, openerTabId: opener.tab.guid)
        state.readerOverlayState.present(reader.tab, originTabId: peek.tab.guid)

        state.handleChromiumActiveTabChanged(reader.tab.guid)

        XCTAssertEqual(opener.wrapper.setAsActiveTabCallCount, 1)
        XCTAssertEqual(peek.wrapper.setAsActiveTabCallCount, 0)
    }

    func testAPeekWhoseOpenerIsGoneActivatesNothing() throws {
        let state = try makeState()
        let focused = makeTab(1)
        let peek = makeTab(2)
        state.tabs = [focused.tab]
        state.focusingTab = focused.tab
        state.peekState.present(peek.tab, openerTabId: 99)

        state.handleChromiumActiveTabChanged(peek.tab.guid)

        XCTAssertEqual(focused.wrapper.setAsActiveTabCallCount, 0)
        XCTAssertEqual(peek.wrapper.setAsActiveTabCallCount, 0)
        XCTAssertTrue(state.focusingTab === focused.tab)
    }

    /// "Open as Tab" leaves `peekState` before it activates the page, so that
    /// activation is an ordinary one and must not bounce back to the opener.
    func testAPeekExpandedIntoATabKeepsItsActivation() throws {
        let state = try makeState()
        let opener = makeTab(1)
        let peek = makeTab(2)
        state.tabs = [opener.tab]
        state.focusingTab = opener.tab
        state.peekState.present(peek.tab, openerTabId: opener.tab.guid)

        state.expandPeekIntoTab(peekTabId: peek.tab.guid)
        state.handleChromiumActiveTabChanged(peek.tab.guid)

        XCTAssertEqual(opener.wrapper.setAsActiveTabCallCount, 0)
        XCTAssertTrue(state.focusingTab === peek.tab)
    }

    func testAnOrdinaryTabIsFocusedWithoutAnotherActivation() throws {
        let state = try makeState()
        let first = makeTab(1)
        let second = makeTab(2)
        state.tabs = [first.tab, second.tab]
        state.focusingTab = first.tab

        state.handleChromiumActiveTabChanged(second.tab.guid)

        XCTAssertTrue(state.focusingTab === second.tab)
        XCTAssertEqual(first.wrapper.setAsActiveTabCallCount, 0)
        XCTAssertEqual(second.wrapper.setAsActiveTabCallCount, 0)
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

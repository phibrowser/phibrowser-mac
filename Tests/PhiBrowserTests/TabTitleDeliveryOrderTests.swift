// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

/// Chromium reports a tab's title two ways: `tabTitleUpdated` when a page
/// sets its title, and the wrapper's `title`, which each navigation's
/// metadata sets within the same Chromium call. Both write `Tab.title`, so
/// they have to land in the order Chromium sent them. Going back to a history
/// entry whose title is unchanged sends no new `tabTitleUpdated`, so a title
/// landing after the wrapper's stays: a redirector page's, when its jump is
/// re-homed by a URL rule and the tab goes back to the page before.
@MainActor
final class TabTitleDeliveryOrderTests: XCTestCase {
    private var directory: URL?
    private var accountDirectory: URL?
    private var store: LocalStore?
    private var state: BrowserState?
    private var controller: SpaceSessionController?
    private var window: NSWindow?

    override func setUp() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        let account = Account(userID: "tab-title-order-test-\(UUID().uuidString)")
        accountDirectory = account.userDataStorage
        let store = LocalStore(account: account, storeDirectoryURL: directory, presentsCompatibilityAlerts: false)
        account.localStorage = store
        self.store = store
        let state = BrowserState(windowId: 987654401, localStore: store,
                                 profileId: LocalStore.defaultProfileId, spaceId: UUID().uuidString)
        self.state = state
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        self.window = window
        // A dormant session registers itself, so window-scoped bridge calls
        // for `state.windowId` find `state`.
        controller = SpaceSessionController(window: window, windowId: state.windowId,
                                            profileId: state.profileId, spaceId: state.spaceId,
                                            account: account, browserState: state, dormant: true)
    }

    override func tearDown() async throws {
        controller?.discardDormant()
        window?.close()
        controller = nil
        state = nil
        window = nil
        await drainMainQueue()
        try await store?.closeForAccountDirectoryRemoval()
        store = nil
        for url in [directory, accountDirectory].compactMap({ $0 })
        where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func makeTab(_ guid: Int) -> (Tab, BookmarkLayoutTestWebContentWrapper) {
        let url = "http://127.0.0.1:8765/"
        let tab = Tab(guid: guid, url: url, isActive: true, index: 0)
        let wrapper = BookmarkLayoutTestWebContentWrapper(urlString: url)
        tab.setWebContentsWrapper(wrapper: wrapper)
        return (tab, wrapper)
    }

    /// Runs everything the main queue holds now, EventBus deliveries included.
    private func drainMainQueue() async {
        let drained = expectation(description: "Main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
    }

    func testAPageTitleDoesNotLandAfterTheWrapperTitleThatFollowedIt() async throws {
        let state = try XCTUnwrap(state)
        let (tab, wrapper) = makeTab(31)
        state.tabs = [tab]

        // The redirector page sets its title; then its jump is re-homed and
        // the tab goes back to an entry that already has a title, which only
        // the metadata reports.
        PhiChromiumCoordinator.shared.tabTitleUpdated(Int64(tab.guid), title: "Redirector",
                                                      windowId: Int64(state.windowId))
        wrapper.title = "Earlier page"
        await drainMainQueue()

        XCTAssertEqual(tab.title, "Earlier page")
    }

    /// A title sent while the tab is not listed yet still reaches it once it
    /// is listed before the queue drains.
    func testATitleForATabNotListedYetStillReachesIt() async throws {
        let state = try XCTUnwrap(state)
        let (tab, _) = makeTab(32)

        PhiChromiumCoordinator.shared.tabTitleUpdated(Int64(tab.guid), title: "Page",
                                                      windowId: Int64(state.windowId))
        state.tabs = [tab]
        await drainMainQueue()

        XCTAssertEqual(tab.title, "Page")
    }

    /// Two page titles, the tab listed between them (a Peek expanded into the
    /// strip, say): the later one is the one that stays.
    func testTitlesSentAroundTheTabBeingListedLandInOrder() async throws {
        let state = try XCTUnwrap(state)
        let (tab, _) = makeTab(33)
        let windowId = Int64(state.windowId)

        PhiChromiumCoordinator.shared.tabTitleUpdated(Int64(tab.guid), title: "First", windowId: windowId)
        state.tabs = [tab]
        PhiChromiumCoordinator.shared.tabTitleUpdated(Int64(tab.guid), title: "Second", windowId: windowId)
        await drainMainQueue()

        XCTAssertEqual(tab.title, "Second")
    }

    /// The same order holds for a Peek, which is not in the strip.
    func testAPeeksPageTitleDoesNotLandAfterTheWrapperTitleThatFollowedIt() async throws {
        let state = try XCTUnwrap(state)
        let (opener, _) = makeTab(34)
        let (peek, peekWrapper) = makeTab(35)
        state.tabs = [opener]
        state.peekState.present(peek, openerTabId: opener.guid)

        PhiChromiumCoordinator.shared.tabTitleUpdated(Int64(peek.guid), title: "Redirector",
                                                      windowId: Int64(state.windowId))
        peekWrapper.title = "Earlier page"
        await drainMainQueue()

        XCTAssertEqual(peek.title, "Earlier page")
    }
}

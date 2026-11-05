// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import XCTest
@testable import Phi

/// A tab opened into a new split takes focus before Chromium's split echo
/// reaches `BrowserState.splits`. While it is in
/// `BrowserState.tabsAwaitingSplit` the page container leaves it unmounted,
/// so its partner, the outgoing tab, stays in the window; once the entry
/// clears, the container mounts it (mac ADR 0011).
///
/// The failed creation calls the bridge under a window id Chromium knows no
/// Browser by, so those calls return early (as in
/// `ContentSurfaceControllerRebuildTests`).
@MainActor
final class TabsAwaitingSplitMountTests: XCTestCase {

    private var tempDirectories: [URL] = []
    private var windows: [NSWindow] = []

    override func tearDownWithError() throws {
        windows.forEach { $0.close() }
        windows.removeAll()
        let fileManager = FileManager.default
        for directory in tempDirectories {
            try? fileManager.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    func testTabAwaitingItsSplitIsNotMounted() throws {
        let fixture = try makeFixture()

        focusTabAwaitingSplit(fixture)

        XCTAssertNil(fixture.webViews[1].window, "the waiting tab was mounted")
        XCTAssertNotNil(fixture.webViews[0].window, "the partner left the window")
    }

    /// Once the split lands, the tab is mounted with its partner beside it.
    func testTabIsMountedWithItsSplitOnceTheSplitLands() throws {
        let fixture = try makeFixture()
        focusTabAwaitingSplit(fixture)

        fixture.state.handleSplitCreated(splitId: "awaited-split",
                                         tabIds: [fixture.tabs[0].guid, fixture.tabs[1].guid],
                                         layout: .vertical,
                                         fractions: [0.5, 0.5])

        XCTAssertTrue(fixture.state.tabsAwaitingSplit.isEmpty)
        try waitUntilMounted(fixture.webViews[1])
        XCTAssertNotNil(fixture.webViews[0].window, "the split was mounted without the partner")
    }

    /// Another split landing, as a restore replays every split, leaves the
    /// tab waiting.
    func testAnotherSplitLandingLeavesTheTabWaiting() throws {
        let fixture = try makeFixture(tabCount: 4)
        focusTabAwaitingSplit(fixture)

        fixture.state.handleSplitCreated(splitId: "other-split",
                                         tabIds: [fixture.tabs[2].guid, fixture.tabs[3].guid],
                                         layout: .vertical,
                                         fractions: [0.5, 0.5])
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))

        XCTAssertEqual(fixture.state.tabsAwaitingSplit, [fixture.tabs[1].guid])
        XCTAssertNil(fixture.webViews[1].window, "the waiting tab was mounted")
        XCTAssertNotNil(fixture.webViews[0].window, "the partner left the window")
    }

    /// When Chromium creates no split, the tab stops waiting and is mounted
    /// on its own.
    func testTabIsMountedWhenItsSplitIsNotCreated() throws {
        let fixture = try makeFixture()
        let newPane = fixture.tabs[1]
        let pendingGuid = SplitPendingGuid.partner.mint()
        newPane.guidInLocalDB = pendingGuid
        fixture.state.pendingSplitPartnerByCustomGuid[pendingGuid] = PendingSplitPartner(
            target: .newPair(partnerTabId: fixture.tabs[0].guid,
                             newTabSlot: .right,
                             layout: .vertical)
        )
        var awaiting: [Set<Int>] = []
        let subscription = fixture.state.$tabsAwaitingSplit.sink { awaiting.append($0) }

        // The new pane arrives; `createSplit` finds no Browser and returns nil.
        fixture.state.consumePendingSplitPartner(for: newPane)

        // The pane waited for its split, then stopped waiting.
        XCTAssertEqual(awaiting, [[], [newPane.guid], []])
        subscription.cancel()
        try waitUntilMounted(fixture.webViews[1])
    }

    // MARK: - Helpers

    private struct Fixture {
        let state: BrowserState
        let container: WebContentContainerViewController
        let tabs: [Tab]
        /// Held here: a wrapper's `nativeView` is weak.
        let webViews: [NSView]
    }

    /// `tabCount` tabs in a visible window, the first one focused and mounted.
    private func makeFixture(tabCount: Int = 2) throws -> Fixture {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        tempDirectories.append(directory)
        let store = LocalStore(account: Account(userID: UUID().uuidString),
                               storeDirectoryURL: directory)
        let state = BrowserState(windowId: 123459301, localStore: store, profileId: "Default")

        let webViews = (0..<tabCount).map { _ in
            NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        }
        let tabs = webViews.enumerated().map { index, webView in
            let wrapper = PageColorTestWebContentWrapper(urlString: "https://tab\(index).example/")
            wrapper.nativeView = webView
            return Tab(guid: 900 + index, url: wrapper.urlString, isActive: index == 0,
                       index: index, webContentView: wrapper)
        }
        state.tabs = tabs
        state.updateNormalTabs()
        state.focusingTab = tabs[0]

        let container = WebContentContainerViewController(state: state)
        container.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                              styleMask: [.titled, .resizable],
                              backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        window.contentViewController = container
        window.orderFront(nil)
        try waitUntilMounted(webViews[0])
        return Fixture(state: state, container: container, tabs: tabs, webViews: webViews)
    }

    /// Focuses the second tab while it waits for its split, as
    /// `consumePendingSplitPartner` does, then lets the container's
    /// subscriptions run.
    private func focusTabAwaitingSplit(_ fixture: Fixture) {
        fixture.state.tabsAwaitingSplit.insert(fixture.tabs[1].guid)
        fixture.state.focusingTab = fixture.tabs[1]
        // Would mount the focused tab synchronously.
        fixture.container.mountActiveTabForRestore()
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
    }

    /// Waits for `webView` to join the window, then lets the display cycle
    /// run.
    private func waitUntilMounted(_ webView: NSView,
                                  file: StaticString = #filePath,
                                  line: UInt = #line) throws {
        let deadline = Date().addingTimeInterval(2)
        while webView.window == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        _ = try XCTUnwrap(webView.window, "the tab was never mounted", file: file, line: line)
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
    }
}

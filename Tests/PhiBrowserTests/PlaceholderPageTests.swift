// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

/// Placeholder mode shows the chrome://dino page only in a window that just
/// lost its last tab. A window with no tab to lose (a new window or a Space
/// opened empty under the Omnibox "New tab behavior") mounts nothing, and an
/// empty Space the user switches to takes the page down.
@MainActor
final class PlaceholderPageTests: XCTestCase {

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

    func testAWindowThatNeverHadATabMountsNoPage() throws {
        let state = try makeStateInWindow()
        // Held here: a wrapper's `nativeView` is weak.
        let pageView = makeWebView()

        state.enterPlaceholderMode(wrapper: makeWrapper(pageView, url: "chrome://dino/"))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertTrue(state.isInPlaceholderMode)
        XCTAssertFalse(state.showsPlaceholderPage)
        XCTAssertNil(pageView.superview, "nothing to show but an empty page area")
    }

    func testAWindowThatLostItsLastTabMountsThePage() throws {
        let state = try makeStateInWindow()
        let tabView = makeWebView()
        let tab = makeFocusedTab(in: state, webView: tabView)
        XCTAssertTrue(state.focusingTab === tab, "precondition: the tab is focused")
        let pageView = makeWebView()

        state.enterPlaceholderMode(wrapper: makeWrapper(pageView, url: "chrome://dino/"))

        XCTAssertTrue(state.showsPlaceholderPage)
        XCTAssertNotNil(pageView.window, "the page is mounted in the window")
    }

    /// The order the bridge delivers a close that already reached `tabs`:
    /// only the stale `focusingTab` is left to tell the tab was there.
    func testALastTabAlreadyGoneFromTheListStillCountsAsLost() throws {
        let state = try makeStateInWindow()
        let tabView = makeWebView()
        _ = makeFocusedTab(in: state, webView: tabView)
        state.tabs = []
        state.updateNormalTabs()
        let pageView = makeWebView()

        state.enterPlaceholderMode(wrapper: makeWrapper(pageView, url: "chrome://dino/"))

        XCTAssertTrue(state.showsPlaceholderPage)
        XCTAssertNotNil(pageView.window)
    }

    func testHidingThePageUnmountsItAndKeepsPlaceholderMode() throws {
        let state = try makeStateInWindow()
        let tabView = makeWebView()
        _ = makeFocusedTab(in: state, webView: tabView)
        let pageView = makeWebView()
        state.enterPlaceholderMode(wrapper: makeWrapper(pageView, url: "chrome://dino/"))
        XCTAssertNotNil(pageView.window, "precondition: the page is on screen")

        state.hidePlaceholderPage()

        XCTAssertTrue(state.isInPlaceholderMode)
        XCTAssertFalse(state.showsPlaceholderPage)
        XCTAssertNil(pageView.superview)
    }

    /// The first entry's answer does not stick: a tab opened from the empty
    /// page area and then closed leaves the window like any other last-tab close.
    func testAWindowThatOpensATabAndLosesItMountsThePage() throws {
        let state = try makeStateInWindow()
        let firstPageView = makeWebView()
        state.enterPlaceholderMode(wrapper: makeWrapper(firstPageView, url: "chrome://dino/"))
        XCTAssertFalse(state.showsPlaceholderPage, "precondition: the window starts empty")
        state.exitPlaceholderMode()

        let tabView = makeWebView()
        _ = makeFocusedTab(in: state, webView: tabView)
        let pageView = makeWebView()
        state.enterPlaceholderMode(wrapper: makeWrapper(pageView, url: "chrome://dino/"))

        XCTAssertTrue(state.showsPlaceholderPage)
        XCTAssertNotNil(pageView.window)
    }

    // MARK: - Helpers

    private func makeStateInWindow() throws -> BrowserState {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        tempDirectories.append(directory)
        let store = LocalStore(account: Account(userID: UUID().uuidString),
                               storeDirectoryURL: directory)
        let state = BrowserState(windowId: 14, localStore: store, profileId: "Default")

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
        return state
    }

    private func makeWebView() -> NSView {
        NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
    }

    private func makeWrapper(_ webView: NSView, url: String) -> PageColorTestWebContentWrapper {
        let wrapper = PageColorTestWebContentWrapper(urlString: url)
        wrapper.nativeView = webView
        return wrapper
    }

    private func makeFocusedTab(in state: BrowserState, webView: NSView) -> Tab {
        let wrapper = makeWrapper(webView, url: "https://tab.example/")
        let tab = Tab(guid: 960, url: wrapper.urlString, isActive: true, index: 0,
                      webContentView: wrapper)
        state.tabs = [tab]
        state.updateNormalTabs()
        state.focusingTab = tab
        return tab
    }
}

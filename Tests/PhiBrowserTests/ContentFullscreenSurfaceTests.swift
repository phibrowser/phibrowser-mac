// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

/// A page entering content fullscreen is lifted out of the page container
/// into an overlay over the window. Over a content surface (chromium ADR
/// 0014) the surface's view goes into that overlay first, under the page's
/// host view, so the lifted web views keep drawing through it instead of
/// leaving the surface for a compositor of their own; on exit the surface
/// comes back above the page-area backdrop and the host view to its place.
/// `ContentSurfaceHosting` tells the lifted web views square corners while
/// they are up there, and their rounded ones again on exit.
@MainActor
final class ContentFullscreenSurfaceTests: XCTestCase {

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

    func testTheSurfaceGoesIntoTheOverlayUnderTheLiftedHostView() throws {
        let fixture = try makeFixture()
        let surface = adoptSurface(fixture)
        let hostView = try hostView(fixture)
        let home = try XCTUnwrap(surface.superview)

        enterFullscreen(fixture)

        let overlay = try XCTUnwrap(hostView.superview)
        XCTAssertTrue(overlay.superview === fixture.window.contentView, "the overlay covers the window")
        XCTAssertFalse(overlay === home)
        XCTAssertTrue(surface.superview === overlay, "the surface went up with the page")
        let surfaceIndex = try XCTUnwrap(overlay.subviews.firstIndex(of: surface))
        let hostIndex = try XCTUnwrap(overlay.subviews.firstIndex(of: hostView))
        XCTAssertLessThan(surfaceIndex, hostIndex, "the surface lies under the host view")
        fixture.window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(overlay.frame, fixture.window.contentView?.bounds)
        XCTAssertEqual(surface.frame, overlay.bounds)
        XCTAssertEqual(hostView.frame, overlay.bounds)
    }

    func testOnExitTheSurfaceAndTheHostViewReturnWhereTheyWere() throws {
        let fixture = try makeFixture()
        let surface = adoptSurface(fixture)
        let hostView = try hostView(fixture)
        let home = try XCTUnwrap(surface.superview)
        let homeIndex = try XCTUnwrap(home.subviews.firstIndex(of: surface))
        let hostHome = try XCTUnwrap(hostView.superview)
        let hostIndex = try XCTUnwrap(hostHome.subviews.firstIndex(of: hostView))
        let windowSubviews = fixture.window.contentView?.subviews.count
        enterFullscreen(fixture)
        weak var overlay = hostView.superview
        XCTAssertNotNil(overlay)

        exitFullscreen(fixture)

        XCTAssertTrue(surface.superview === home, "the surface is back in the page container")
        XCTAssertEqual(home.subviews.firstIndex(of: surface), homeIndex,
                       "the surface is back above the page-area backdrop")
        XCTAssertTrue(hostView.superview === hostHome)
        XCTAssertEqual(hostHome.subviews.firstIndex(of: hostView), hostIndex)
        XCTAssertEqual(fixture.window.contentView?.subviews.count, windowSubviews, "the overlay is gone")
        XCTAssertNil(overlay?.superview)
    }

    func testTheLiftedPageIsToldSquareCornersAndItsRoundedOnesAgainOnExit() throws {
        let fixture = try makeFixture()
        _ = adoptSurface(fixture)
        let hosting = try XCTUnwrap(fixture.container.contentSurfaceHostingForTesting)
        var sends: [(address: NSObject, hosting: ContentSurfaceHosting.Hosting)] = []
        hosting.sendForTesting = { sends.append(($0, $1)) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let page = fixture.wrappers[0]
        func lastSent() -> ContentSurfaceHosting.Hosting? {
            sends.last { $0.address === page }?.hosting
        }
        let rounded = try XCTUnwrap(lastSent(), "precondition: the page was told its corners")
        XCTAssertGreaterThan(max(rounded.topLeft, rounded.topRight, rounded.bottomRight, rounded.bottomLeft), 0,
                             "precondition: the page has a rounded corner")

        enterFullscreen(fixture)
        let lifted = try XCTUnwrap(lastSent())
        XCTAssertEqual([lifted.topLeft, lifted.topRight, lifted.bottomRight, lifted.bottomLeft], [0, 0, 0, 0],
                       "the lifted page is square")

        exitFullscreen(fixture)
        XCTAssertEqual(lastSent(), rounded, "the page has its corners back")
    }

    /// A web view that leaves the window, even for a moment, has AppKit drop
    /// its mouse moves until the pointer crosses its edge, which it cannot
    /// over a page filling a fullscreen window.
    func testTheLiftedPageNeverLeavesTheWindow() throws {
        let fixture = try makeFixture()
        _ = adoptSurface(fixture)
        let page = try XCTUnwrap(fixture.webViews[0] as? WindowDepartureCountingView)
        let departures = page.windowDepartures

        enterFullscreen(fixture)
        exitFullscreen(fixture)

        XCTAssertEqual(page.windowDepartures, departures, "the page left the window")
    }

    /// A split pane entering fullscreen is mounted alone first. Its page
    /// moves out of the split within the window: taken out with the split
    /// host, it would leave the window like a lifted page that is removed
    /// first.
    func testASplitPaneEnteringFullscreenNeverLeavesTheWindow() throws {
        let fixture = try makeFixture()
        _ = adoptSurface(fixture)
        try formSplit(fixture)
        let page = try XCTUnwrap(fixture.webViews[0] as? WindowDepartureCountingView)
        let departures = page.windowDepartures

        enterFullscreen(fixture)
        XCTAssertTrue(page.superview === (try hostView(fixture)), "the page is not mounted alone")
        exitFullscreen(fixture)

        XCTAssertEqual(page.windowDepartures, departures, "the page left the window")
        XCTAssertTrue(page.superview?.superview is SplitPaneHostView, "the split is not rebuilt on exit")
    }

    /// A split dissolved (the other pane closed or removed from the split)
    /// leaves the focused pane's page in the window, mounted alone at the
    /// host view's size.
    func testDissolvingASplitKeepsTheFocusedPaneInTheWindow() throws {
        let fixture = try makeFixture()
        try formSplit(fixture)
        let page = try XCTUnwrap(fixture.webViews[0] as? WindowDepartureCountingView)
        let departures = page.windowDepartures

        fixture.state.splits = []
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        let host = try XCTUnwrap(try hostView(fixture) as? WebContentHostView)
        XCTAssertTrue(page.superview === host, "the page is not mounted alone")
        XCTAssertEqual(page.frame, host.contentFrame, "the page does not fill the host view")
        XCTAssertEqual(page.windowDepartures, departures, "the page left the window")
    }

    /// The focused pane keeps the keyboard when its split dissolves: a view
    /// that leaves the window gives its first responder status to the
    /// window, and nothing hands it back.
    func testDissolvingASplitLeavesTheKeyboardWithTheFocusedPane() throws {
        let fixture = try makeFixture(keyWindow: true)
        try formSplit(fixture)
        let widget = FirstResponderCountingView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        fixture.webViews[0].addSubview(widget)
        XCTAssertTrue(fixture.window.makeFirstResponder(widget), "precondition: the page has the keyboard")

        fixture.state.splits = []
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertTrue(fixture.window.firstResponder === widget,
                      "the keyboard left the page: \(String(describing: fixture.window.firstResponder))")
        XCTAssertEqual(widget.resignations, 0, "the page lost the keyboard on the way")
    }

    /// A focused pane with DevTools docked in it collapses the same way: its
    /// page stays in the window, and its DevTools comes back under it in the
    /// host view, with the page laid out by hand beside it.
    func testDissolvingASplitKeepsAPaneWithDockedDevToolsInTheWindow() throws {
        let fixture = try makeFixture()
        try formSplit(fixture)
        let controller = try XCTUnwrap(
            fixture.container.children.compactMap { $0 as? WebContentViewController }.first)
        let host = try XCTUnwrap(controller.hostViewForTesting as? WebContentHostView)
        let page = try XCTUnwrap(fixture.webViews[0] as? WindowDepartureCountingView)
        let splitHost = try XCTUnwrap(page.superview?.superview as? SplitPaneHostView)
        let devTools = NSView()
        controller.attachDevTools(view: devTools)
        XCTAssertTrue(devTools.isDescendant(of: splitHost), "precondition: DevTools is docked in the pane")
        let departures = page.windowDepartures

        fixture.state.splits = []
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertEqual(page.windowDepartures, departures, "the page left the window")
        XCTAssertTrue(page.superview === host, "the page is not mounted alone")
        let devToolsIndex = try XCTUnwrap(host.subviews.firstIndex(of: devTools),
                                          "DevTools is not back in the host view")
        let pageIndex = try XCTUnwrap(host.subviews.firstIndex(of: page))
        XCTAssertLessThan(devToolsIndex, pageIndex, "DevTools is not under the page")
        XCTAssertTrue(host.isFrameSyncPaused, "the page is not laid out by hand beside DevTools")
    }

    /// Closing docked DevTools puts the page back on constraints that fill
    /// its host view. A page then mounted alone where it already is (here a
    /// split whose partner has no view yet) sheds them for the frame it is
    /// given, or the two fight when the window resizes.
    func testAPageKeptInItsHostViewDropsTheDevToolsFillConstraints() throws {
        let fixture = try makeFixture()
        let controller = try XCTUnwrap(
            fixture.container.children.compactMap { $0 as? WebContentViewController }.first)
        let host = try XCTUnwrap(controller.hostViewForTesting as? WebContentHostView)
        let page = fixture.webViews[0]
        controller.attachDevTools(view: NSView())
        controller.detachDevTools()
        let fill = host.constraints.filter { $0.firstItem === page || $0.secondItem === page }
        XCTAssertFalse(fill.isEmpty, "precondition: the page fills its host view by constraints")
        fixture.wrappers[1].nativeView = nil

        fixture.state.splits = [SplitGroup(id: "split-970-971", primaryTabId: 970, secondaryTabId: 971,
                                           layout: .vertical, ratio: 0.5)]
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertTrue(page.superview === host, "the page is not mounted alone")
        XCTAssertFalse(fill.contains { $0.isActive },
                       "the page kept the fill constraints: \(fill.filter { $0.isActive })")
        XCTAssertTrue(page.translatesAutoresizingMaskIntoConstraints, "the page is not on a manual frame")
        fixture.window.setContentSize(NSSize(width: 1000, height: 700))
        fixture.window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(page.frame, host.contentFrame, "the page does not follow its host view")
    }

    /// Chromium's exit never reaches a tab that closes in fullscreen: the
    /// controller is torn down with its page still lifted.
    func testTheOverlayGoesWithItsPageAndTheSurfaceComesHomeWhenTheTabCloses() throws {
        let fixture = try makeFixture()
        let surface = adoptSurface(fixture)
        let hostView = try hostView(fixture)
        let home = try XCTUnwrap(surface.superview)
        let windowSubviews = fixture.window.contentView?.subviews.count
        enterFullscreen(fixture)
        weak var overlay = hostView.superview
        XCTAssertNotNil(overlay)

        fixture.state.tabs = [fixture.tabs[1]]
        fixture.state.updateNormalTabs()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertTrue(surface.superview === home, "the surface is back in the page container")
        XCTAssertEqual(fixture.window.contentView?.subviews.count, windowSubviews, "the overlay is gone")
        XCTAssertNil(overlay?.superview)
    }

    /// Closing the last tab in fullscreen mounts the placeholder page while
    /// the surface is still lent: the bridge enters placeholder mode
    /// synchronously, the tab leaves later. Chromium ignores what the page is
    /// told then and attaches it afresh, square and on top, when the surface
    /// comes home, so it has to be told again.
    func testAWebViewMountedWhileTheSurfaceIsLentIsToldAgainWhenItComesHome() throws {
        let fixture = try makeFixture()
        let surface = adoptSurface(fixture)
        let home = try XCTUnwrap(surface.superview)
        let hosting = try XCTUnwrap(fixture.container.contentSurfaceHostingForTesting)
        var sends: [NSObject] = []
        hosting.sendForTesting = { address, _ in sends.append(address) }
        enterFullscreen(fixture)
        // Held here: a wrapper's `nativeView` is weak.
        let placeholderView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let placeholder = PageColorTestWebContentWrapper(urlString: "chrome://dino/")
        placeholder.nativeView = placeholderView

        // In a pool of its own, as the bridge calls in from a run-loop pass:
        // mounting the shell leaves the container's old `children`, which
        // holds the page's controller, autoreleased, and this test's pool
        // would keep that controller alive past the tab's removal.
        autoreleasepool {
            fixture.state.enterPlaceholderMode(wrapper: placeholder)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(sends.contains { $0 === placeholder },
                      "precondition: the placeholder page was told while the surface was lent")
        let sendsBeforeClose = sends.count

        fixture.state.tabs = []
        fixture.state.updateNormalTabs()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertTrue(surface.superview === home, "the surface is back in the page container")
        XCTAssertTrue(sends[sendsBeforeClose...].contains { $0 === placeholder },
                      "the placeholder page is told again once the surface is home")
    }

    /// The page's own view, the one Chromium makes first responder, keeps the
    /// keyboard while its page is lifted into content fullscreen and back.
    /// Taking it away and giving it back sends the page a blur and a focus in
    /// the same task.
    func testAPageThatHasTheKeyboardKeepsItThroughFullscreen() throws {
        let fixture = try makeFixture(keyWindow: true)
        let widget = FirstResponderCountingView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        fixture.webViews[0].addSubview(widget)
        XCTAssertTrue(fixture.window.makeFirstResponder(widget), "precondition: the page has the keyboard")

        enterFullscreen(fixture)
        XCTAssertTrue(fixture.window.firstResponder === widget,
                      "entry took the keyboard: \(String(describing: fixture.window.firstResponder))")
        exitFullscreen(fixture)

        XCTAssertTrue(fixture.window.firstResponder === widget,
                      "exit took the keyboard: \(String(describing: fixture.window.firstResponder))")
        XCTAssertEqual(widget.resignations, 0, "the page lost the keyboard on the way")
    }

    /// Focusing the page (a split pane the user just clicked) leaves a page
    /// that already has the keyboard alone.
    func testFocusingAPageThatHasTheKeyboardLeavesItAlone() throws {
        let fixture = try makeFixture(keyWindow: true)
        let widget = FirstResponderCountingView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        fixture.webViews[0].addSubview(widget)
        XCTAssertTrue(fixture.window.makeFirstResponder(widget), "precondition: the page has the keyboard")
        let page = try XCTUnwrap(
            fixture.container.children.compactMap { $0 as? WebContentViewController }.first)

        page.focusWebContent()

        XCTAssertTrue(fixture.window.firstResponder === widget,
                      "the keyboard moved: \(String(describing: fixture.window.firstResponder))")
        XCTAssertEqual(widget.resignations, 0, "the page lost the keyboard")
    }

    /// With the keyboard elsewhere (the omnibox), a page entering fullscreen
    /// still takes it, or Esc would never reach the page.
    func testAPageEnteringFullscreenStillTakesTheKeyboardFromElsewhere() throws {
        let fixture = try makeFixture(keyWindow: true)
        let elsewhere = FirstResponderCountingView(frame: NSRect(x: 600, y: 10, width: 40, height: 20))
        try XCTUnwrap(fixture.window.contentView).addSubview(elsewhere)
        XCTAssertTrue(fixture.window.makeFirstResponder(elsewhere), "precondition: another view has the keyboard")

        enterFullscreen(fixture)
        defer { exitFullscreen(fixture) }

        XCTAssertTrue(fixture.window.firstResponder === fixture.webViews[0],
                      "the page did not take the keyboard: \(String(describing: fixture.window.firstResponder))")
    }

    /// A page focused before it has a URL gets Chromium's focus once the URL
    /// arrives. A page that took the keyboard itself in the meantime needs no
    /// such retry, and a later URL change (a same-document navigation) must
    /// not take the keyboard back from the omnibox.
    func testAFocusRetryThePageNoLongerNeedsIsDropped() throws {
        let fixture = try makeFixture(keyWindow: true)
        let wrapper = fixture.wrappers[0]
        let page = try XCTUnwrap(
            fixture.container.children.compactMap { $0 as? WebContentViewController }.first)
        XCTAssertEqual(fixture.tabs[0].lastFocusTarget, .webContent,
                       "precondition: the page is the tab's focus target")
        wrapper.urlString = nil
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertNil(fixture.tabs[0].url, "precondition: the page has no URL yet")
        page.focusWebContent()
        XCTAssertTrue(fixture.window.firstResponder === fixture.webViews[0],
                      "precondition: the unloaded page's container took the keyboard")
        let widget = FirstResponderCountingView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        fixture.webViews[0].addSubview(widget)
        XCTAssertTrue(fixture.window.makeFirstResponder(widget), "precondition: the page has the keyboard")
        wrapper.urlString = "https://tab0.example/loaded"
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let elsewhere = FirstResponderCountingView(frame: NSRect(x: 600, y: 10, width: 40, height: 20))
        try XCTUnwrap(fixture.window.contentView).addSubview(elsewhere)
        XCTAssertTrue(fixture.window.makeFirstResponder(elsewhere), "precondition: another view has the keyboard")

        wrapper.urlString = "https://tab0.example/loaded#later"
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertTrue(fixture.window.firstResponder === elsewhere,
                      "a spent focus retry took the keyboard: \(String(describing: fixture.window.firstResponder))")
    }

    /// A page focused before it has a URL leaves the keyboard on its
    /// container; Chromium's focus call would do nothing yet. Once the URL
    /// arrives the retry still gives the page Chromium's focus: the container
    /// holding the keyboard is not the page having it.
    func testAFocusRetryWhileTheContainerHoldsTheKeyboardGivesThePageChromiumsFocus() throws {
        let fixture = try makeFixture(keyWindow: true)
        let wrapper = fixture.wrappers[0]
        let page = try XCTUnwrap(
            fixture.container.children.compactMap { $0 as? WebContentViewController }.first)
        wrapper.urlString = nil
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertNil(fixture.tabs[0].url, "precondition: the page has no URL yet")
        let callsBeforeFocus = wrapper.restoreFocusCallCount
        page.focusWebContent()
        XCTAssertTrue(fixture.window.firstResponder === fixture.webViews[0],
                      "precondition: the unloaded page's container took the keyboard")
        XCTAssertEqual(wrapper.restoreFocusCallCount, callsBeforeFocus,
                       "precondition: Chromium's focus waits for the URL")

        wrapper.urlString = "https://tab0.example/loaded"
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertEqual(wrapper.restoreFocusCallCount, callsBeforeFocus + 1,
                       "the retry did not give the page Chromium's focus")
        XCTAssertTrue(fixture.window.firstResponder === fixture.webViews[0],
                      "the keyboard left the page: \(String(describing: fixture.window.firstResponder))")
    }

    // MARK: - Helpers

    private struct Fixture {
        let state: BrowserState
        let container: WebContentContainerViewController
        let window: NSWindow
        let tabs: [Tab]
        let wrappers: [PageColorTestWebContentWrapper]
        /// Held here: a wrapper's `nativeView` is weak.
        let webViews: [NSView]
    }

    /// Two tabs in a visible window, the first one focused and mounted, with
    /// no surface yet.
    private func makeFixture(keyWindow: Bool = false) throws -> Fixture {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        tempDirectories.append(directory)
        let store = LocalStore(account: Account(userID: UUID().uuidString),
                               storeDirectoryURL: directory)
        let state = BrowserState(windowId: 14, localStore: store, profileId: "Default")

        let webViews: [NSView] = (0..<2).map { _ in
            WindowDepartureCountingView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        }
        let wrappers = webViews.enumerated().map { index, webView in
            let wrapper = PageColorTestWebContentWrapper(urlString: "https://tab\(index).example/")
            wrapper.nativeView = webView
            return wrapper
        }
        let tabs = wrappers.enumerated().map { index, wrapper in
            Tab(guid: 970 + index, url: wrapper.urlString, isActive: index == 0,
                index: index, webContentView: wrapper)
        }
        state.tabs = tabs
        state.updateNormalTabs()
        state.focusingTab = tabs[0]

        let container = WebContentContainerViewController(state: state)
        container.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        // A hosted test app is not reliably active, so a window that has to
        // be key says so itself.
        let windowClass: NSWindow.Type = keyWindow ? KeyWindowForTesting.self : NSWindow.self
        let window = windowClass.init(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                                      styleMask: [.titled, .resizable],
                                      backing: .buffered,
                                      defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        window.contentViewController = container
        window.orderFront(nil)
        try waitUntilMounted(webViews[0])
        return Fixture(state: state, container: container, window: window, tabs: tabs,
                       wrappers: wrappers, webViews: webViews)
    }

    /// Installs a surface, as Chromium's arrival does, synchronously.
    private func adoptSurface(_ fixture: Fixture) -> NSView {
        let surface = NSView()
        fixture.state.adoptContentSurface(surface)
        return surface
    }

    /// The mounted page's host view, the view lifted into content fullscreen.
    private func hostView(_ fixture: Fixture,
                          file: StaticString = #filePath,
                          line: UInt = #line) throws -> NSView {
        let page = try XCTUnwrap(
            fixture.container.children.compactMap { $0 as? WebContentViewController }.first,
            "no page is mounted", file: file, line: line)
        return page.hostViewForTesting
    }

    /// The two tabs side by side, the focused first one's controller holding
    /// the split, as Chromium's split arrival does.
    private func formSplit(_ fixture: Fixture,
                           file: StaticString = #filePath,
                           line: UInt = #line) throws {
        fixture.state.splits = [SplitGroup(id: "split-970-971", primaryTabId: 970, secondaryTabId: 971,
                                           layout: .vertical, ratio: 0.5)]
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(fixture.webViews[0].superview?.superview is SplitPaneHostView,
                      "precondition: the page is a split pane", file: file, line: line)
        XCTAssertNotNil(fixture.webViews[1].window, "precondition: the partner pane is mounted",
                        file: file, line: line)
    }

    /// The bridge's fullscreen event lands on the tab; the page controller
    /// follows it on the main queue.
    private func enterFullscreen(_ fixture: Fixture) {
        fixture.tabs[0].isInContentFullscreen = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    private func exitFullscreen(_ fixture: Fixture) {
        fixture.tabs[0].isInContentFullscreen = false
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    private func waitUntilMounted(_ webView: NSView,
                                  file: StaticString = #filePath,
                                  line: UInt = #line) throws {
        let deadline = Date().addingTimeInterval(2)
        while webView.window == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        _ = try XCTUnwrap(webView.window, "the view was never mounted", file: file, line: line)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }
}

/// Counts the times it leaves a window.
private final class WindowDepartureCountingView: NSView {
    private(set) var windowDepartures = 0

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window != nil, newWindow == nil {
            windowDepartures += 1
        }
        super.viewWillMove(toWindow: newWindow)
    }
}

/// Takes the keyboard and counts the times it gives it up: a stand-in for
/// Chromium's widget view, or for the omnibox.
private final class FirstResponderCountingView: NSView {
    private(set) var resignations = 0
    override var acceptsFirstResponder: Bool { true }

    override func resignFirstResponder() -> Bool {
        resignations += 1
        return super.resignFirstResponder()
    }
}

/// Key whether or not the test app is active.
private final class KeyWindowForTesting: NSWindow {
    override var isKeyWindow: Bool { true }
}

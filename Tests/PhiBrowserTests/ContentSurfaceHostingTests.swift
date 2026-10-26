// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

/// `ContentSurfaceHosting` tells the content surface (chromium ADR 0014)
/// where each web view is and the part of it that shows, as views tells
/// `NativeViewHostMac` upstream: the surface does not see AppKit move a web
/// view's ancestors, nor clip it to them.
@MainActor
final class ContentSurfaceHostingTests: XCTestCase {

    private var tempDirectories: [URL] = []
    private var windows: [NSWindow] = []

    override func tearDownWithError() throws {
        WebContentContainerViewController.panelSlideDurationForTesting = nil
        windows.forEach { $0.close() }
        windows.removeAll()
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    /// In the window from its top left, as Chromium keeps a view's bounds in
    /// its window, and whole while all of it shows.
    func testAWebViewIsToldItsRectInTheWindowFromTheTopLeft() throws {
        let fixture = try makeFixture()

        let sent = try XCTUnwrap(fixture.lastSent(), "the page was told nothing")

        let inWindow = fixture.webView.convert(fixture.webView.bounds, to: nil)
        XCTAssertEqual(sent.frame, fixture.flipped(inWindow))
        XCTAssertEqual(sent.clip, sent.frame, "the whole page shows")
    }

    func testReconciliationDoesNotReadBackgroundNativeViewsWith200Tabs() throws {
        let fixture = try makeFixture()
        let backgroundPages = (2..<200).map { index in
            let wrapper = PageColorTestWebContentWrapper(urlString: "https://background.example/\(index)")
            fixture.state.tabs.append(Tab(guid: 2400 + index, url: wrapper.urlString,
                                          isActive: false, index: index, webContentView: wrapper))
            return wrapper
        }
        let backgroundChat = PageColorTestWebContentWrapper(urlString: "https://chat.example/")
        fixture.state.aiChatTabs["background"] = Tab(
            guid: 3000, url: backgroundChat.urlString, isActive: false, index: 0,
            webContentView: backgroundChat)
        fixture.state.updateNormalTabs()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(fixture.state.tabs.count, 200)
        let wrappers = backgroundPages + [backgroundChat]
        let reads = wrappers.map(\.nativeViewReadCount)
        let visibleReads = fixture.page.nativeViewReadCount
        let previousFrame = try XCTUnwrap(fixture.lastSent()).frame

        fixture.window.setContentSize(NSSize(width: 1300, height: 800))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertEqual(wrappers.map(\.nativeViewReadCount), reads)
        XCTAssertGreaterThan(fixture.page.nativeViewReadCount, visibleReads)
        XCTAssertNotEqual(try XCTUnwrap(fixture.lastSent()).frame, previousFrame,
                          "the visible page must still receive placement updates")
    }

    func testUnfocusedSplitPaneAndItsDevToolsReceivePlacementUpdates() throws {
        let fixture = try makeFixture()
        let partnerView = NSView(frame: fixture.webView.frame)
        let partner = PageColorTestWebContentWrapper(urlString: "https://partner.example/")
        partner.nativeView = partnerView
        let partnerTab = Tab(guid: 2401, url: partner.urlString, isActive: false, index: 1,
                             webContentView: partner)
        fixture.state.tabs[1] = partnerTab
        fixture.state.updateNormalTabs()
        fixture.state.splits = [SplitGroup(id: "hosting-split", primaryTabId: 2400,
                                           secondaryTabId: 2401, layout: .vertical, ratio: 0.5)]
        waitUntil { partnerView.window != nil }
        XCTAssertTrue(partnerView.window === fixture.window)
        XCTAssertFalse(partnerTab.isActive)

        // The bridge supplies docked DevTools separately from the page wrapper.
        let devTools = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        partnerTab.devToolsView = devTools
        try XCTUnwrap(partnerView.superview).addSubview(devTools)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let previous = try XCTUnwrap(fixture.sends.last { $0.address === partner }).hosting
        XCTAssertNotNil(fixture.sends.last { $0.address === devTools })

        fixture.window.setContentSize(NSSize(width: 1300, height: 800))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        let updated = try XCTUnwrap(fixture.sends.last { $0.address === partner }).hosting
        XCTAssertNotEqual(updated.frame, previous.frame)
        XCTAssertNotNil(fixture.lastSent(), "the focused pane must also remain hosted")
    }

    /// A page laid out wider than its host shows only the part inside it.
    func testAPageWiderThanItsHostIsClippedToTheHost() throws {
        let fixture = try makeFixture()
        let page = try XCTUnwrap(
            fixture.container.children.compactMap { $0 as? WebContentViewController }.first)
        try XCTUnwrap(page.hostViewForTesting as? WebContentHostView).isFrameSyncPaused = true

        fixture.webView.setFrameSize(NSSize(width: fixture.webView.frame.width + 200,
                                            height: fixture.webView.frame.height))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        let sent = try XCTUnwrap(fixture.lastSent())
        let host = page.hostViewForTesting
        let inWindow = fixture.webView.convert(fixture.webView.bounds, to: nil)
        XCTAssertEqual(sent.frame, fixture.flipped(inWindow))
        XCTAssertEqual(sent.clip,
                       fixture.flipped(inWindow.intersection(host.convert(host.bounds, to: nil))))
        XCTAssertLessThan(sent.clip.width, sent.frame.width, "precondition: the page overruns its host")
    }

    /// The surface rounds the part of a page that shows, so a page that
    /// overruns its host keeps the corners its host shows there, as AppKit's
    /// rounded clip gives a page drawing itself.
    func testAPageWiderThanItsHostKeepsItsHostsCorners() throws {
        let fixture = try makeFixture()
        let settled = try XCTUnwrap(fixture.lastSent())
        XCTAssertGreaterThan(settled.bottomRight, 0, "precondition: the page's bottom right is rounded")
        let page = try XCTUnwrap(
            fixture.container.children.compactMap { $0 as? WebContentViewController }.first)
        try XCTUnwrap(page.hostViewForTesting as? WebContentHostView).isFrameSyncPaused = true

        fixture.webView.setFrameSize(NSSize(width: fixture.webView.frame.width + 200,
                                            height: fixture.webView.frame.height))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        let sent = try XCTUnwrap(fixture.lastSent())
        XCTAssertLessThan(sent.clip.width, sent.frame.width, "precondition: the page overruns its host")
        XCTAssertEqual(sent.topLeft, settled.topLeft)
        XCTAssertEqual(sent.topRight, settled.topRight)
        XCTAssertEqual(sent.bottomRight, settled.bottomRight)
        XCTAssertEqual(sent.bottomLeft, settled.bottomLeft)
    }

    /// A framework without the rect and clip takes only the radii and the z
    /// order, so a move, which leaves those alone, sends it nothing.
    func testAFrameworkThatTakesNoPlacementIsNotToldAMove() throws {
        let fixture = try makeFixture()
        fixture.hosting.takesPlacement = false
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(fixture.lastSent()?.frame, .zero, "precondition: the page was told it has no rect")
        let rect = fixture.webView.convert(fixture.webView.bounds, to: nil)
        let sendCount = fixture.sends.count

        fixture.window.setContentSize(NSSize(width: 1300, height: 800))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertNotEqual(fixture.webView.convert(fixture.webView.bounds, to: nil), rect,
                          "precondition: the resize moved the page")
        XCTAssertEqual(fixture.sends.count, sendCount)
    }

    // MARK: - Extension side panel slide

    /// The extension side panel slides in by a Core Animation group, which
    /// puts the views around the page at their end frame at once while the
    /// page follows its card on every frame. The surface's view keeps its
    /// frame, and the page is told each frame what shows, rounded, not the
    /// part the end frame leaves.
    func testASidePanelSlideInTellsThePageWhatShowsOnEveryFrame() throws {
        WebContentContainerViewController.panelSlideDurationForTesting = 0.5
        let fixture = try makeFixture()
        let surfaceFrame = fixture.surfaceView.frame
        let sendCount = fixture.sends.count

        // Through the model, which separates the page card as on device.
        fixture.state.updateExtensionSidePanel(fixture.sidePanelState)
        XCTAssertTrue(fixture.hosting.isHeld, "precondition: the slide holds")
        var surfaceMoved = false
        waitUntil({ !fixture.hosting.isHeld }) {
            surfaceMoved = surfaceMoved || fixture.surfaceView.frame != surfaceFrame
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertFalse(fixture.hosting.isHeld, "the slide never ended")
        XCTAssertFalse(surfaceMoved, "the surface's view moved during the slide")
        let told = fixture.toldPage(since: sendCount)
        let widths = told.map(\.clip.width)
        let settled = try XCTUnwrap(told.last)
        XCTAssertGreaterThan(Set(widths).count, 3, "the page was not told the slide: \(widths)")
        XCTAssertGreaterThan(widths.max() ?? 0, settled.clip.width + 100,
                             "the page was cut to its end frame: \(widths)")
        assertWholeAndRounded(told)
    }

    /// Sliding out, the page grows with its card on every frame and keeps
    /// its bottom right corner rounded.
    func testASidePanelSlideOutTellsThePageWhatShowsOnEveryFrame() throws {
        WebContentContainerViewController.panelSlideDurationForTesting = 0.05
        let fixture = try makeFixture()
        // Through the model, which separates the page card as on device.
        fixture.state.updateExtensionSidePanel(fixture.sidePanelState)
        waitUntil { !fixture.hosting.isHeld }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let sendCount = fixture.sends.count

        WebContentContainerViewController.panelSlideDurationForTesting = 0.5
        fixture.state.updateExtensionSidePanel(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))

        let told = fixture.toldPage(since: sendCount)
        let widths = told.map(\.clip.width)
        XCTAssertGreaterThan(Set(widths).count, 3, "the page was not told the slide: \(widths)")
        XCTAssertGreaterThan(widths.last ?? 0, (widths.first ?? 0) + 100, "the page did not grow")
        assertWholeAndRounded(told)
    }

    /// A web view that leaves the window and comes back is told again, even
    /// what it was told before: the surface attaches it again square and on
    /// top.
    func testAWebViewMountedAgainIsToldAgain() throws {
        let fixture = try makeFixture()
        let told = try XCTUnwrap(fixture.lastSent())
        let tab = try XCTUnwrap(fixture.state.focusingTab)
        fixture.state.focusingTab = fixture.otherTab
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertNil(fixture.webView.window, "precondition: the page left the window")
        let sendCount = fixture.sends.count

        fixture.state.focusingTab = tab
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertNotNil(fixture.webView.window, "precondition: the page is back")
        XCTAssertEqual(fixture.toldPage(since: sendCount).last, told)
    }

    func testTheSlideEndReleasesTheHold() throws {
        WebContentContainerViewController.panelSlideDurationForTesting = 0.05
        let fixture = try makeFixture()
        let sendCount = fixture.sends.count

        fixture.slideInSidePanel()
        XCTAssertTrue(fixture.hosting.isHeld, "precondition: the slide holds")
        let deadline = Date().addingTimeInterval(2)
        while fixture.hosting.isHeld, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertFalse(fixture.hosting.isHeld)
        XCTAssertFalse(fixture.surfaceView.translatesAutoresizingMaskIntoConstraints)
        XCTAssertGreaterThan(fixture.sends.count, sendCount, "the settled page was not told")
    }

    func testATabSwitchReleasesTheHold() throws {
        try assertCuttingTheSlideShortReleasesTheHold { $0.state.focusingTab = $0.otherTab }
    }

    func testClosingTheCurrentTabReleasesTheHold() throws {
        try assertCuttingTheSlideShortReleasesTheHold { fixture in
            fixture.state.tabs = [fixture.otherTab]
            fixture.state.updateNormalTabs()
        }
    }

    func testClosingTheSidePanelReleasesTheHold() throws {
        try assertCuttingTheSlideShortReleasesTheHold { $0.container.detachExtensionSidePanel() }
    }

    func testContentFullscreenReleasesTheHold() throws {
        try assertCuttingTheSlideShortReleasesTheHold { fixture in
            let overlay = NSView(frame: fixture.container.view.bounds)
            fixture.container.view.addSubview(overlay)
            fixture.container.lendContentSurface(to: overlay)
        }
    }

    // MARK: - Page / AI Chat split across a cut-short slide

    /// The split follows its host by autoresizing, which a slide animates.
    /// Closing the panel mid-slide resizes the host again: the split must
    /// go back with it, never wider than its card, and end at its width.
    func testClosingTheSidePanelMidSlideLeavesTheSplitAtItsHostWidth() throws {
        try assertClosingTheSlideShortKeepsTheSplitInItsHost(after: 0.1)
    }

    /// The same before the slide's first frame, while the split still has
    /// its host's old width but is on its way to the narrowed one.
    func testClosingTheSidePanelBeforeItsSlideStartsLeavesTheSplitAtItsHostWidth() throws {
        try assertClosingTheSlideShortKeepsTheSplitInItsHost(after: 0)
    }

    /// Reopening the panel while it slides out: the split narrows with its
    /// host, never narrower than its card, and ends at its width.
    func testReopeningTheSidePanelMidSlideOutLeavesTheSplitAtItsHostWidth() throws {
        WebContentContainerViewController.panelSlideDurationForTesting = 0.05
        let fixture = try makeFixture()
        let (split, superview) = try fixture.contentSplit()
        fixture.slideInSidePanel()
        waitUntil { !fixture.hosting.isHeld }
        WebContentContainerViewController.panelSlideDurationForTesting = 60
        fixture.container.detachExtensionSidePanel()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertLessThan(split.frame.width, superview.bounds.width - 100,
                          "precondition: the slide-out is still running")

        WebContentContainerViewController.panelSlideDurationForTesting = 0.2
        fixture.slideInSidePanel()
        var narrowest = CGFloat.infinity
        waitUntil({ !fixture.hosting.isHeld }) {
            narrowest = min(narrowest, split.frame.width - superview.bounds.width)
        }

        XCTAssertFalse(fixture.hosting.isHeld, "the slide-in never ended")
        XCTAssertGreaterThanOrEqual(narrowest, -0.5, "the split went narrower than its card")
        XCTAssertEqual(split.frame.width, superview.bounds.width, accuracy: 0.5)
    }

    /// A window resize mid-slide, outside the slide's group, is put right
    /// when the slide ends.
    func testResizingTheWindowMidSlideLeavesTheSplitAtItsHostWidth() throws {
        WebContentContainerViewController.panelSlideDurationForTesting = 0.5
        let fixture = try makeFixture()
        let (split, superview) = try fixture.contentSplit()
        fixture.slideInSidePanel()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(fixture.hosting.isHeld, "precondition: the slide is still running")

        fixture.window.setContentSize(NSSize(width: 1300, height: 800))
        waitUntil { !fixture.hosting.isHeld }

        XCTAssertFalse(fixture.hosting.isHeld, "the slide never ended")
        XCTAssertEqual(split.frame.width, superview.bounds.width, accuracy: 0.5)
    }

    /// Another tab's slide never moves this tab's split, so it must not
    /// cancel the alignment this tab's own slide owes it: a window resize
    /// mid-slide, then a switch to the other tab and a panel close there,
    /// all before the slide ends.
    func testAnotherTabsSlideLeavesTheFirstTabsSplitAtItsHostWidth() throws {
        WebContentContainerViewController.panelSlideDurationForTesting = 0.5
        let fixture = try makeFixture()
        let tab = try XCTUnwrap(fixture.state.focusingTab)
        let (split, superview) = try fixture.contentSplit()
        fixture.slideInSidePanel()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        fixture.window.setContentSize(NSSize(width: 1300, height: 800))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        fixture.state.focusingTab = fixture.otherTab
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertNil(split.window, "precondition: the first tab is unmounted")
        XCTAssertNotNil(fixture.container.extensionSidePanelViewForTesting,
                        "precondition: the panel is still open")
        // The slide's completion puts the split on its superview, so a split
        // still off it means that slide has not ended.
        XCTAssertGreaterThan(abs(split.frame.width - superview.bounds.width), 1,
                             "precondition: the first tab's slide is still running")
        WebContentContainerViewController.panelSlideDurationForTesting = 0.2
        fixture.container.detachExtensionSidePanel()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        fixture.state.focusingTab = tab
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertEqual(split.frame.width, superview.bounds.width, accuracy: 0.5)
    }

    // MARK: - Helpers

    /// Closes the panel `delay` into a slide long enough that only the
    /// close ends it, and follows the slide-out to its end.
    private func assertClosingTheSlideShortKeepsTheSplitInItsHost(
        after delay: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        WebContentContainerViewController.panelSlideDurationForTesting = 60
        let fixture = try makeFixture()
        let (split, superview) = try fixture.contentSplit()
        fixture.slideInSidePanel()
        let panel = try XCTUnwrap(fixture.container.extensionSidePanelViewForTesting,
                                  file: file, line: line)
        if delay > 0 {
            RunLoop.main.run(until: Date().addingTimeInterval(delay))
        }

        WebContentContainerViewController.panelSlideDurationForTesting = 0.2
        fixture.container.detachExtensionSidePanel()
        var widest = -CGFloat.infinity
        waitUntil({ panel.superview == nil }) {
            widest = max(widest, split.frame.width - superview.bounds.width)
        }

        XCTAssertNil(panel.superview, "the slide-out never ended", file: file, line: line)
        XCTAssertLessThanOrEqual(widest, 0.5, "the split went wider than its card",
                                 file: file, line: line)
        XCTAssertEqual(split.frame.width, superview.bounds.width, accuracy: 0.5,
                       file: file, line: line)
    }

    /// Every send shows the whole page, which follows its card, never cut to
    /// a container's end frame nor past the card; its bottom corners are the
    /// card's, or the frame's while the card still fills it.
    private func assertWholeAndRounded(_ told: [ContentSurfaceHosting.Hosting],
                                       file: StaticString = #filePath,
                                       line: UInt = #line) {
        let radii: Set<CGFloat> = [LiquidGlassCompatible.webContentInnerComponentsCornerRadius,
                                   LiquidGlassCompatible.webContentContainerCornerRadius]
        for hosting in told {
            // Within a point: on the slide's first frame the frame's layer
            // starts moving before the split does, as AppKit's own clip shows.
            let edges = [hosting.clip.minX - hosting.frame.minX, hosting.clip.maxX - hosting.frame.maxX,
                         hosting.clip.minY - hosting.frame.minY, hosting.clip.maxY - hosting.frame.maxY]
            XCTAssertTrue(edges.allSatisfy { abs($0) < 1 },
                          "clip \(hosting.clip) of page \(hosting.frame)", file: file, line: line)
            XCTAssertTrue(radii.contains(hosting.bottomLeft) && radii.contains(hosting.bottomRight),
                          "bottom radii \(hosting.bottomLeft) / \(hosting.bottomRight)",
                          file: file, line: line)
        }
    }

    /// Runs the main run loop until `done` or two seconds pass, calling
    /// `sample` on every turn.
    private func waitUntil(_ done: () -> Bool, sampling sample: () -> Void = {}) {
        let deadline = Date().addingTimeInterval(2)
        while !done(), Date() < deadline {
            sample()
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
    }

    /// The slide is long enough that only `interrupt` can end it.
    private func assertCuttingTheSlideShortReleasesTheHold(
        _ interrupt: (Fixture) -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        WebContentContainerViewController.panelSlideDurationForTesting = 60
        let fixture = try makeFixture()
        fixture.slideInSidePanel()
        XCTAssertTrue(fixture.hosting.isHeld, "precondition: the slide holds", file: file, line: line)

        interrupt(fixture)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertFalse(fixture.hosting.isHeld, file: file, line: line)
        XCTAssertFalse(fixture.surfaceView.translatesAutoresizingMaskIntoConstraints,
                       "the surface's view is not back on its constraints", file: file, line: line)
    }

    @MainActor
    private final class Fixture {
        let state: BrowserState
        let container: WebContentContainerViewController
        let window: NSWindow
        let page: PageColorTestWebContentWrapper
        /// Held here: a wrapper's `nativeView` is weak.
        let webView: NSView
        /// A second tab, not shown.
        let otherTab: Tab
        let surfaceView: NSView
        let hosting: ContentSurfaceHosting
        private let sidePanel = PageColorTestWebContentWrapper(urlString: "chrome-extension://panel/")
        private let sidePanelView = NSView()
        var sends: [(address: NSObject, hosting: ContentSurfaceHosting.Hosting)] = []

        init(state: BrowserState, container: WebContentContainerViewController, window: NSWindow,
             page: PageColorTestWebContentWrapper, webView: NSView, otherTab: Tab,
             surfaceView: NSView, hosting: ContentSurfaceHosting) {
            self.state = state
            self.container = container
            self.window = window
            self.page = page
            self.webView = webView
            self.otherTab = otherTab
            self.surfaceView = surfaceView
            self.hosting = hosting
            sidePanel.nativeView = sidePanelView
        }

        func lastSent() -> ContentSurfaceHosting.Hosting? {
            sends.last { $0.address === page }?.hosting
        }

        /// What the page was told after the first `count` sends.
        func toldPage(since count: Int) -> [ContentSurfaceHosting.Hosting] {
            sends.dropFirst(count).filter { $0.address === page }.map(\.hosting)
        }

        /// `rect`, in window coordinates, with its origin at the window's top left.
        func flipped(_ rect: NSRect) -> NSRect {
            NSRect(x: rect.minX, y: window.frame.height - rect.maxY,
                   width: rect.width, height: rect.height)
        }

        var sidePanelState: BrowserState.ExtensionSidePanelState {
            BrowserState.ExtensionSidePanelState(
                extensionId: "test-extension", displayName: "Test Extension", iconPNG: nil,
                wrapper: sidePanel)
        }

        /// Opens an extension side panel, which slides in, the window being on screen.
        func slideInSidePanel() {
            container.attachExtensionSidePanel(sidePanelState)
        }

        /// The page / AI Chat split and the view it fills.
        func contentSplit() throws -> (split: NSSplitView, superview: NSView) {
            let page = try XCTUnwrap(
                container.children.compactMap { $0 as? WebContentViewController }.first)
            let split = page.contentSplitViewForTesting
            return (split, try XCTUnwrap(split.superview))
        }
    }

    /// One tab, mounted in a visible window over a content surface, with
    /// every send recorded.
    private func makeFixture() throws -> Fixture {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        let store = LocalStore(account: Account(userID: UUID().uuidString),
                               storeDirectoryURL: directory)
        let state = BrowserState(windowId: 24, localStore: store, profileId: "Default")

        let webView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let page = PageColorTestWebContentWrapper(urlString: "https://page.example/")
        page.nativeView = webView
        let tab = Tab(guid: 2400, url: page.urlString, isActive: true, index: 0, webContentView: page)
        let otherTab = Tab(guid: 2401, url: "https://other.example/", isActive: false, index: 1)
        state.tabs = [tab, otherTab]
        state.updateNormalTabs()
        state.focusingTab = tab

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
        let deadline = Date().addingTimeInterval(2)
        while webView.window == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        _ = try XCTUnwrap(webView.window, "the page was never mounted")

        let surfaceView = NSView()
        state.adoptContentSurface(surfaceView)
        let hosting = try XCTUnwrap(container.contentSurfaceHostingForTesting)
        let fixture = Fixture(state: state, container: container, window: window, page: page,
                              webView: webView, otherTab: otherTab, surfaceView: surfaceView,
                              hosting: hosting)
        hosting.sendForTesting = { [weak fixture] in fixture?.sends.append(($0, $1)) }
        // Whatever framework the host links.
        hosting.takesPlacement = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        return fixture
    }
}

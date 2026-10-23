// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

/// The page container's mount (mac ADR 0011) puts a tab's web view into the
/// window already at the page area's size. A web view resized after it
/// joined makes Chromium embed the new size with a zero deadline, and the
/// grown strip shows the gutter until the page's next frame. The web view
/// joins in the mount turn, except on the container's first mount, where it
/// joins one turn later.
@MainActor
final class WebContentMountGeometryTests: XCTestCase {

    private var tempDirectories: [URL] = []
    private var windows: [NSWindow] = []

    func testFractionalHostBoundsKeepTheWholePageAreaCovered() {
        let host = WebContentHostView(frame: NSRect(x: 0, y: 0, width: 800.5, height: 600.5))
        host.enclosesFractionalBounds = true
        let page = NSView()
        page.translatesAutoresizingMaskIntoConstraints = true
        page.frame = host.contentFrame
        host.addSubview(page)

        XCTAssertEqual(page.frame.size, NSSize(width: 801, height: 601))
        XCTAssertTrue(page.frame.contains(host.bounds))

        host.setFrameSize(NSSize(width: 700.5, height: 500.5))
        host.layout()
        XCTAssertEqual(page.frame.size, NSSize(width: 701, height: 501))
        XCTAssertTrue(page.frame.contains(host.bounds))

        host.enclosesFractionalBounds = false
        host.layout()
        XCTAssertEqual(page.frame, host.bounds)

        host.enclosesFractionalBounds = true

        host.setFrameSize(NSSize(width: 700, height: 500))
        host.layout()
        XCTAssertEqual(page.frame, host.bounds)
    }

    func testFractionalHostDoesNotOverrideManuallyDockedPageBounds() {
        let host = WebContentHostView(frame: NSRect(x: 0, y: 0, width: 800.5, height: 600.5))
        host.enclosesFractionalBounds = true
        let page = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 600))
        host.addSubview(page)
        host.isFrameSyncPaused = true
        let dockedFrame = page.frame

        host.layout()

        XCTAssertEqual(page.frame, dockedFrame)
    }

    func testSharedChatFrameUsesTranslucentFillInBothAppearances() throws {
        let (fixture, controller, _) = try makeHandoffFixture(chatExpanded: true)
        let context = fixture.state.themeContext
        context.mirrorsSharedAppearance = false
        context.mirrorsSharedTheme = false
        // This fixture has a plain NSWindow rather than a browser window controller.
        fixture.container.view.subtreeThemeSource = context
        controller.hasContentSurface = true
        controller.hasContentSurface = false
        context.setUserAppearanceChoice(.dark)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        func assertFill(_ expected: NSColor, file: StaticString = #filePath, line: UInt = #line) {
            guard let cgColor = controller.pageCardView.layer?.backgroundColor,
                  let actual = NSColor(cgColor: cgColor)?.usingColorSpace(.sRGB),
                  let expected = expected.usingColorSpace(.sRGB) else {
                XCTFail("Expected a shared frame fill", file: file, line: line)
                return
            }
            XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.001, file: file, line: line)
            XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.001, file: file, line: line)
            XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.001, file: file, line: line)
            XCTAssertEqual(actual.alphaComponent, expected.alphaComponent, accuracy: 0.001, file: file, line: line)
        }

        XCTAssertTrue(controller.isPageCardSeparated)
        assertFill(.black.withAlphaComponent(0.60))
        context.setUserAppearanceChoice(.light)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        assertFill(.white.withAlphaComponent(0.60))
        context.setUserAppearanceChoice(.dark)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        assertFill(.black.withAlphaComponent(0.60))

        // Surface-backed pages must leave the frame to the backing below them.
        controller.hasContentSurface = true
        XCTAssertNil(controller.pageCardView.layer?.backgroundColor)
        controller.hasContentSurface = false
        assertFill(.black.withAlphaComponent(0.60))

        fixture.state.toggleAIChat(true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.7))
        XCTAssertFalse(controller.isPageCardSeparated)
        assertFill(ThemedColor.contentOverlayBackground.resolve(
            theme: context.currentTheme, appearance: .dark
        ))
    }

    override func tearDownWithError() throws {
        WebContentContainerViewController.panelSlideDurationForTesting = nil
        windows.forEach { $0.close() }
        windows.removeAll()
        let fileManager = FileManager.default
        for directory in tempDirectories {
            try? fileManager.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    /// A background tab that was never shown (opened with Cmd-click next to
    /// docked DevTools, say) gets its controller on its first focus.
    func testNeverShownTabJoinsTheWindowAtThePageAreaSize() throws {
        let fixture = try makeFixture()
        let incoming = fixture.webViews[1]

        fixture.state.focusingTab = fixture.tabs[1]
        try waitUntilMounted(incoming)

        try assertJoinedAtFinalSize(incoming)
    }

    /// A tab mounted before keeps its view tree while away; if the window was
    /// resized meanwhile, it rejoins at the new page area size.
    func testRemountedTabJoinsTheWindowAtTheResizedPageAreaSize() throws {
        let fixture = try makeFixture()
        let outgoing = fixture.webViews[0]
        fixture.state.focusingTab = fixture.tabs[1]
        try waitUntilMounted(fixture.webViews[1])
        XCTAssertNil(outgoing.window)

        let sizeBeforeResize = outgoing.frame.size
        fixture.window.setContentSize(NSSize(width: 1000, height: 640))
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        fixture.state.focusingTab = fixture.tabs[0]
        try waitUntilMounted(outgoing)

        // Precondition: the resize changed the page area.
        XCTAssertNotEqual(outgoing.frame.size, sizeBeforeResize)
        try assertJoinedAtFinalSize(outgoing)
    }

    /// A tab mounted before that comes back to an unchanged page area rejoins
    /// at that size too.
    func testRemountedTabJoinsTheWindowAtAnUnchangedPageAreaSize() throws {
        let fixture = try makeFixture()
        let outgoing = fixture.webViews[0]
        fixture.state.focusingTab = fixture.tabs[1]
        try waitUntilMounted(fixture.webViews[1])
        XCTAssertNil(outgoing.window)

        let sizeWhileAway = outgoing.frame.size
        fixture.state.focusingTab = fixture.tabs[0]
        try waitUntilMounted(outgoing)

        // Precondition: the page area did not change.
        XCTAssertEqual(outgoing.frame.size, sizeWhileAway)
        try assertJoinedAtFinalSize(outgoing)
    }

    /// The first tab a page container mounts (a Space's first reveal, a new
    /// window) is mounted in its turn, but its web view joins the window on
    /// the next one, still at the page area's size.
    func testColdMountedWebViewJoinsTheWindowOnTheNextTurn() throws {
        let fixture = try makeFixture(mountingFirstTab: false)
        let incoming = fixture.webViews[0]

        // Mounts the focused tab synchronously.
        fixture.container.mountActiveTabForRestore()

        XCTAssertNotNil(fixture.container.currentWebPanelSize, "the tab was not mounted")
        XCTAssertNil(incoming.window, "the web view joined the window in the mount turn")
        var joinedByNextTurn: Bool?
        // Queued after the deferred update the mount scheduled.
        DispatchQueue.main.async { joinedByNextTurn = incoming.window != nil }
        try waitUntilMounted(incoming)
        XCTAssertEqual(joinedByNextTurn, true)
        try assertJoinedAtFinalSize(incoming)
    }

    /// The cold-mounted tab's web view takes the window's focus once it is in
    /// the window. The fixture's first mount is into an empty container.
    func testColdMountedWebViewTakesFocus() throws {
        let fixture = try makeFixture()

        XCTAssertTrue(fixture.window.firstResponder === fixture.webViews[0],
                      "first responder: \(String(describing: fixture.window.firstResponder))")
    }

    /// Switching away from a mounted tab stays one turn: the incoming web
    /// view is in the window when the mount returns, the outgoing one is out.
    func testSwitchFromAMountedTabJoinsTheWindowInTheMountTurn() throws {
        let fixture = try makeFixture()

        fixture.state.focusingTab = fixture.tabs[1]
        // Mounts the focused tab synchronously.
        fixture.container.mountActiveTabForRestore()

        XCTAssertNotNil(fixture.webViews[1].window)
        XCTAssertNil(fixture.webViews[0].window)
    }

    /// A never-shown successor of the closed current tab finds nothing
    /// current, but it is not the container's first mount: its web view joins
    /// in the mount turn, as the successor can already draw.
    func testSuccessorOfAClosedTabJoinsTheWindowInTheMountTurn() throws {
        let fixture = try makeFixture()

        // The close reaches the container before the focus change, as on
        // device.
        fixture.state.tabs = [fixture.tabs[1]]
        fixture.state.updateNormalTabs()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertNil(fixture.container.currentWebPanelSize, "the closed tab is still current")
        var deferredAtMount: [Bool] = []
        fixture.container.willMountControllerForTesting = {
            deferredAtMount.append($0.hasDeferredContentUpdate)
        }
        fixture.state.focusingTab = fixture.tabs[1]
        // Mounts the focused tab synchronously.
        fixture.container.mountActiveTabForRestore()

        // Precondition: the successor's content waits for the deferred
        // update, so only the container's earlier mount lets it join now.
        XCTAssertEqual(deferredAtMount, [true])
        XCTAssertNotNil(fixture.webViews[1].window)
    }

    /// While AI Chat expands and collapses, the page's web view follows the
    /// page area on every frame instead of keeping its old size and jumping
    /// at the end, so its card's corners stay on it.
    func testAIChatSlidesResizeThePageOnEveryFrame() throws {
        let restorePreferences = pinAIChatPreferences()
        defer { restorePreferences() }
        let fixture = try makeFixture()
        fixture.state.aiChatTabCreationGateOverrideForTesting = false
        let tab = fixture.tabs[0]
        let webView = fixture.webViews[0]

        fixture.state.setAIChatCollapsed(for: tab, collapsed: false)
        assertFollowsPageArea(webView, in: fixture, "expand")
        fixture.state.setAIChatCollapsed(for: tab, collapsed: true)
        assertFollowsPageArea(webView, in: fixture, "collapse")
    }

    /// A collapse that replaces an expand still in flight keeps the page card
    /// separated until the collapse itself ends. AppKit also runs the
    /// completion of the replaced expand, which must not end the newer
    /// collapse's hold.
    func testCollapseReplacingAnExpandKeepsTheCardUntilItEnds() throws {
        let restorePreferences = pinAIChatPreferences()
        defer { restorePreferences() }
        let fixture = try makeFixture()
        fixture.state.aiChatTabCreationGateOverrideForTesting = false
        let tab = fixture.tabs[0]
        let webView = fixture.webViews[0]
        let pageArea = try XCTUnwrap(webView.superview as? WebContentHostView)
        let card = try XCTUnwrap(pageArea.superview)
        let split = try XCTUnwrap(sequence(first: card, next: \.superview)
            .lazy.compactMap { $0 as? NSSplitView }.first)
        let chatPane = try XCTUnwrap(split.arrangedSubviews.last)
        fixture.state.setAIChatCollapsed(for: tab, collapsed: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        // Collapse, expand and collapse again, each before the last ends.
        for collapsed in [true, false] {
            fixture.state.setAIChatCollapsed(for: tab, collapsed: collapsed)
            RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        }
        fixture.state.setAIChatCollapsed(for: tab, collapsed: true)
        var droppedWhileChatShows = false
        var tallestStrip: CGFloat = 0
        let deadline = Date().addingTimeInterval(2)
        while !chatPane.isHidden, chatPane.frame.width > 0, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            fixture.window.contentView?.layoutSubtreeIfNeeded()
            if !chatPane.isHidden, chatPane.frame.width > 0, card.layer?.borderWidth == 0 {
                droppedWhileChatShows = true
            }
            tallestStrip = max(tallestStrip, pageArea.bounds.maxY - webView.frame.maxY)
        }

        XCTAssertTrue(chatPane.isHidden || chatPane.frame.width == 0, "the collapse never finished")
        XCTAssertFalse(droppedWhileChatShows, "the card dropped its inset mid-collapse")
        XCTAssertEqual(tallestStrip, 0, "uncovered strip above the web view")
    }

    /// While the extension side panel slides in and out, the page's web view
    /// follows the page area on every frame, as it does for AI Chat.
    func testExtensionSidePanelSlidesResizeThePageOnEveryFrame() throws {
        let restorePreferences = pinAIChatPreferences()
        defer { restorePreferences() }
        let fixture = try makeFixture()
        let controller = try showPageColor(in: fixture)
        let webView = fixture.webViews[0]
        let panel = makePanel()
        defer { withExtendedLifetime(panel) {} }

        fixture.state.updateExtensionSidePanel(panel.state)
        assertFollowsPageArea(webView, in: fixture, "slide-in")
        fixture.state.updateExtensionSidePanel(nil)
        assertFollowsPageArea(webView, in: fixture, "slide-out")

        // The card rejoined the header, and the tab strip with it.
        XCTAssertEqual(controller.tabStripPageColorPresentation.appearance, .dark)
    }

    /// AI Chat taking over from the extension side panel: the panel slides
    /// out while the chat slides in, each on its own timing, so the pane
    /// between them widens and narrows again. The page card, and the header
    /// and page in it, only move toward their settled width.
    func testAIChatReplacingExtensionSidePanelResizesThePageOneWay() throws {
        try assertAIChatReplacingExtensionSidePanel(chatWidth: nil, shape: .oneWay)
    }

    /// A chat wider than the panel it replaces narrows the page as it slides
    /// in, not all at once at the end.
    func testWiderAIChatReplacingExtensionSidePanelNarrowsThePageAsItComes() throws {
        try assertAIChatReplacingExtensionSidePanel(chatWidth: 500, shape: .narrowsGradually)
    }

    /// The extension side panel taking over from AI Chat: the chat leaves at
    /// once under its sliding snapshot, and the page card does not fill its
    /// place only to give it back to the incoming panel.
    func testExtensionSidePanelReplacingAIChatResizesThePageOneWay() throws {
        try assertExtensionSidePanelReplacingAIChat(chatWidth: nil, shape: .oneWay)
    }

    /// The panel replacing a wider chat widens the page at once, under the
    /// outgoing chat's snapshot, not when the panel has slid in.
    func testExtensionSidePanelReplacingWiderAIChatWidensThePageAtOnce() throws {
        try assertExtensionSidePanelReplacingAIChat(chatWidth: 500, shape: .settlesAtOnce)
    }

    /// Reopening the chat while the panel that replaced it still slides in:
    /// the page card ends filling its pane, no width cap left behind.
    func testReversingAHandoffMidwayLeavesThePageCardOnItsPane() throws {
        let (fixture, controller, panel) = try makeHandoffFixture(chatExpanded: true)
        defer { withExtendedLifetime(panel) {} }
        fixture.state.extensionSidePanelCloseRequestOverrideForTesting = { [weak state = fixture.state] in
            state?.updateExtensionSidePanel(nil)
        }
        fixture.state.updateExtensionSidePanel(panel.state)
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))

        fixture.state.toggleAIChat(false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))

        // Precondition: the chat took the place back.
        XCTAssertNil(fixture.state.extensionSidePanel)
        XCTAssertFalse(try chatItem(of: controller).isCollapsed)
        try assertPageCardFillsItsPane(controller, in: fixture)
    }

    /// A window resize in the middle of a handoff changes where it settles;
    /// the page card still ends filling its pane.
    func testResizingTheWindowMidHandoffLeavesThePageCardOnItsPane() throws {
        let (fixture, controller, panel) = try makeHandoffFixture(chatExpanded: true)
        defer { withExtendedLifetime(panel) {} }
        fixture.state.updateExtensionSidePanel(panel.state)
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))

        fixture.window.setContentSize(NSSize(width: 1000, height: 800))
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))

        try assertPageCardFillsItsPane(controller, in: fixture)
    }

    /// Switching tabs in the middle of a handoff unmounts the page while its
    /// transitions run out; back on it, its card fills its pane.
    func testSwitchingTabsMidHandoffLeavesThePageCardOnItsPane() throws {
        let (fixture, controller, panel) = try makeHandoffFixture(chatExpanded: true)
        defer { withExtendedLifetime(panel) {} }
        fixture.state.updateExtensionSidePanel(panel.state)
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))

        fixture.state.focusingTab = fixture.tabs[1]
        try waitUntilMounted(fixture.webViews[1])
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        fixture.state.focusingTab = fixture.tabs[0]
        try waitUntilMounted(fixture.webViews[0])

        try assertPageCardFillsItsPane(controller, in: fixture)
    }

    /// AI Chat opening while the extension side panel still slides in, its
    /// close not carried out: no handoff, so the split keeps sliding with
    /// the panel instead of jumping to its end width, and the page card is
    /// not held.
    func testAIChatOpeningBesidePanelStillSlidingInLeavesTheSplitSliding() throws {
        let (fixture, controller, panel) = try makeHandoffFixture(chatExpanded: false)
        defer { withExtendedLifetime(panel) {} }
        WebContentContainerViewController.panelSlideDurationForTesting = 1
        fixture.state.extensionSidePanelCloseRequestOverrideForTesting = {}
        fixture.state.updateExtensionSidePanel(panel.state)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let split = controller.contentSplitViewForTesting
        let splitHost = try XCTUnwrap(split.superview)

        fixture.state.toggleAIChat(false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        // Precondition: the panel stays and slides on.
        XCTAssertNotNil(fixture.state.extensionSidePanel)
        XCTAssertGreaterThan(split.frame.width, splitHost.bounds.width + 50,
                             "the split jumped to the slide's end")
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        try assertPageCardFillsItsPane(controller, in: fixture)
    }

    /// The AI Chat ↔ extension side panel mutex closes the panel before the
    /// chat expands. The tab strip stays on the browser color through the
    /// handoff instead of flashing the page color.
    func testAIChatReplacingExtensionSidePanelKeepsTheTabStripInherited() throws {
        let restorePreferences = pinAIChatPreferences()
        defer { restorePreferences() }
        let fixture = try makeFixture()
        fixture.state.aiChatTabCreationGateOverrideForTesting = false
        let controller = try showPageColor(in: fixture)
        let panel = makePanel()
        defer { withExtendedLifetime(panel) {} }
        fixture.state.updateExtensionSidePanel(panel.state)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        fixture.state.extensionSidePanelCloseRequestOverrideForTesting = { [weak state = fixture.state] in
            state?.updateExtensionSidePanel(nil)
        }
        var presentations: [WebContentHeaderPageColorPresentation] = []
        let subscription = controller.tabStripPageColorPresentationPublisher
            .sink { presentations.append($0) }
        defer { subscription.cancel() }

        fixture.state.toggleAIChat(false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        // Precondition: the chat took over from the panel.
        XCTAssertNil(fixture.state.extensionSidePanel)
        XCTAssertFalse(try chatItem(of: controller).isCollapsed)
        XCTAssertEqual(presentations, [.inherited])
    }

    /// Opening the panel over an expanded chat collapses the chat's split
    /// item synchronously in the container's panel sink. Combine may run
    /// that sink before the tab strip sees the panel; the tab strip stays on
    /// the browser color in between.
    func testExtensionSidePanelReplacingAIChatKeepsTheTabStripInherited() throws {
        let restorePreferences = pinAIChatPreferences()
        defer { restorePreferences() }
        let fixture = try makeFixture()
        fixture.state.aiChatTabCreationGateOverrideForTesting = false
        let controller = try showPageColor(in: fixture)
        fixture.state.toggleAIChat(false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertFalse(try chatItem(of: controller).isCollapsed)
        let panel = makePanel()
        defer { withExtendedLifetime(panel) {} }
        var presentations: [WebContentHeaderPageColorPresentation] = []
        let subscription = controller.tabStripPageColorPresentationPublisher
            .sink { presentations.append($0) }
        defer { subscription.cancel() }

        // The container's sink, run first.
        _ = controller.collapseAIChatForPanelTransition(ghostIn: fixture.container.view)
        fixture.state.updateExtensionSidePanel(panel.state)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        // Precondition: the panel took over from the chat.
        XCTAssertTrue(fixture.tabs[0].aiChatCollapsed)
        XCTAssertEqual(presentations, [.inherited])
    }

    // MARK: - Helpers

    /// An extension side panel and the page view it shows, which the caller
    /// holds: a wrapper's `nativeView` is weak.
    private func makePanel() -> (state: BrowserState.ExtensionSidePanelState, view: NSView) {
        let wrapper = PageColorTestWebContentWrapper(urlString: "chrome-extension://test/panel.html")
        let view = NSView()
        wrapper.nativeView = view
        return (BrowserState.ExtensionSidePanelState(extensionId: "test-extension",
                                                     displayName: "Test Extension",
                                                     iconPNG: nil, wrapper: wrapper), view)
    }

    /// Gives the focused page a black page color and returns its controller,
    /// whose tab strip presentation now carries that color.
    private func showPageColor(in fixture: Fixture) throws -> WebContentViewController {
        try XCTUnwrap(fixture.tabs[0].webContentWrapper as? PageColorTestWebContentWrapper)
            .pageColor = .black
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        let controller = try XCTUnwrap(fixture.container.children
            .compactMap { $0 as? WebContentViewController }.first)
        XCTAssertEqual(controller.tabStripPageColorPresentation.appearance, .dark)
        return controller
    }

    private func chatItem(of controller: WebContentViewController) throws -> NSSplitViewItem {
        let split = try XCTUnwrap(controller.children.compactMap { $0 as? NSSplitViewController }.first)
        return try XCTUnwrap(split.splitViewItems.last)
    }

    /// Pins the comfortable layout and the AI switch on (expanding the chat
    /// is gated on it). The returned closure gives the user's values back;
    /// setting nil removes a key that was absent.
    private func pinAIChatPreferences() -> () -> Void {
        let pins: [(key: String, value: Any)] = [
            (PhiPreferences.GeneralSettings.layoutModeKey, LayoutMode.comfortable.rawValue),
            (PhiPreferences.AISettings.phiAIEnabled.rawValue, true),
        ]
        let originals = pins.map { UserDefaults.standard.object(forKey: $0.key) }
        for pin in pins {
            UserDefaults.standard.set(pin.value, forKey: pin.key)
        }
        return {
            for (pin, original) in zip(pins, originals) {
                UserDefaults.standard.set(original, forKey: pin.key)
            }
        }
    }

    private struct Fixture {
        let state: BrowserState
        let container: WebContentContainerViewController
        let window: NSWindow
        let tabs: [Tab]
        /// Held here: a wrapper's `nativeView` is weak.
        let webViews: [MountGeometryProbeView]
    }

    /// Two tabs in a visible window, the first one focused and, unless
    /// `mountingFirstTab` is false, mounted. Each web view starts at a size
    /// of its own, as Chromium sizes a background tab to the active tab's
    /// container.
    private func makeFixture(mountingFirstTab: Bool = true) throws -> Fixture {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        tempDirectories.append(directory)
        let store = LocalStore(account: Account(userID: UUID().uuidString),
                               storeDirectoryURL: directory)
        let state = BrowserState(windowId: 12, localStore: store, profileId: "Default")

        let webViews = (0..<2).map { _ in
            MountGeometryProbeView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
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
        if mountingFirstTab {
            try waitUntilMounted(webViews[0])
        }
        return Fixture(state: state, container: container, window: window, tabs: tabs,
                       webViews: webViews)
    }

    /// Waits for `webView` to join the window, then lets the display cycle
    /// run, where a late layout would land.
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

    private enum HandoffShape {
        /// Only ever narrows or only ever widens.
        case oneWay
        /// One way, its first step already its last.
        case settlesAtOnce
        /// One way, over several steps.
        case narrowsGradually
    }

    /// A page with AI Chat expanded or collapsed (at `chatWidth` once it
    /// expands, when given) and an extension side panel to open, which the
    /// caller holds.
    private func makeHandoffFixture(
        chatExpanded: Bool,
        chatWidth: CGFloat? = nil
    ) throws -> (Fixture, WebContentViewController, (state: BrowserState.ExtensionSidePanelState, view: NSView)) {
        let restorePreferences = pinAIChatPreferences()
        addTeardownBlock { restorePreferences() }
        let fixture = try makeFixture()
        fixture.state.aiChatTabCreationGateOverrideForTesting = false
        let controller = try showPageColor(in: fixture)
        if let chatWidth {
            controller.applyAIChatWidthFromPartner(chatWidth)
        }
        if chatExpanded {
            fixture.state.toggleAIChat(false)
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        }
        return (fixture, controller, makePanel())
    }

    private func assertAIChatReplacingExtensionSidePanel(chatWidth: CGFloat?, shape: HandoffShape,
                                                         file: StaticString = #filePath,
                                                         line: UInt = #line) throws {
        let (fixture, controller, panel) = try makeHandoffFixture(chatExpanded: false, chatWidth: chatWidth)
        defer { withExtendedLifetime(panel) {} }
        fixture.state.updateExtensionSidePanel(panel.state)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        fixture.state.extensionSidePanelCloseRequestOverrideForTesting = { [weak state = fixture.state] in
            state?.updateExtensionSidePanel(nil)
        }

        try assertHandoffResizesThePage(fixture, controller: controller, shape: shape, file: file, line: line) {
            fixture.state.toggleAIChat(false)
        } checks: {
            // The chat took over from the panel, at its width.
            XCTAssertNil(fixture.state.extensionSidePanel, file: file, line: line)
            let chat = try chatItem(of: controller)
            XCTAssertFalse(chat.isCollapsed, file: file, line: line)
            if let chatWidth {
                XCTAssertEqual(chat.viewController.view.frame.width, chatWidth, accuracy: 0.5,
                               file: file, line: line)
            }
        }
    }

    private func assertExtensionSidePanelReplacingAIChat(chatWidth: CGFloat?, shape: HandoffShape,
                                                         file: StaticString = #filePath,
                                                         line: UInt = #line) throws {
        let (fixture, controller, panel) = try makeHandoffFixture(chatExpanded: true, chatWidth: chatWidth)
        defer { withExtendedLifetime(panel) {} }
        if let chatWidth {
            XCTAssertEqual(try chatItem(of: controller).viewController.view.frame.width, chatWidth,
                           accuracy: 0.5, "precondition: the chat's width", file: file, line: line)
        }

        try assertHandoffResizesThePage(fixture, controller: controller, shape: shape, file: file, line: line) {
            fixture.state.updateExtensionSidePanel(panel.state)
        } checks: {
            // The panel took over from the chat, at its own width.
            XCTAssertTrue(try chatItem(of: controller).isCollapsed, file: file, line: line)
            let panelView = try XCTUnwrap(fixture.container.extensionSidePanelViewForTesting,
                                          file: file, line: line)
            XCTAssertEqual(panelView.frame.width, panelView.preferredWidth, accuracy: 0.5,
                           "the page card pushed the panel", file: file, line: line)
        }
    }

    /// Starts a handoff and follows it for 0.6 seconds, past its end: the
    /// web view fills its page area on every turn, the page card and the web
    /// view in it move in `shape`, and the card ends filling its pane.
    private func assertHandoffResizesThePage(
        _ fixture: Fixture,
        controller: WebContentViewController,
        shape: HandoffShape,
        file: StaticString,
        line: UInt,
        handoff: () -> Void,
        checks: () throws -> Void
    ) throws {
        let card = controller.leftContainerViewForTesting
        let webView = fixture.webViews[0]
        let pageArea = try XCTUnwrap(webView.superview, file: file, line: line)
        var cardWidths: [CGFloat] = [card.frame.width]
        var webWidths: [CGFloat] = [webView.frame.width]
        var offPageArea: [String] = []
        handoff()
        let deadline = Date().addingTimeInterval(0.6)
        repeat {
            fixture.window.contentView?.layoutSubtreeIfNeeded()
            if webView.frame != pageArea.bounds {
                offPageArea.append("\(webView.frame) in \(pageArea.bounds)")
            }
            if cardWidths.last != card.frame.width { cardWidths.append(card.frame.width) }
            if webWidths.last != webView.frame.width { webWidths.append(webView.frame.width) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        } while Date() < deadline
        try checks()
        func oneWay(_ widths: [CGFloat]) -> Bool {
            let steps = zip(widths, widths.dropFirst()).map { $1 - $0 }
            return steps.allSatisfy { $0 <= 0.5 } || steps.allSatisfy { $0 >= -0.5 }
        }
        XCTAssertTrue(oneWay(cardWidths), "card widths \(cardWidths)", file: file, line: line)
        XCTAssertTrue(oneWay(webWidths), "web view widths \(webWidths)", file: file, line: line)
        XCTAssertEqual(offPageArea, [], "the web view left its page area", file: file, line: line)
        switch shape {
        case .oneWay:
            break
        case .settlesAtOnce:
            XCTAssertEqual(cardWidths.count, 2, "card widths \(cardWidths)", file: file, line: line)
        case .narrowsGradually:
            XCTAssertLessThan(cardWidths.last ?? 0, cardWidths.first ?? 0, file: file, line: line)
            XCTAssertGreaterThan(cardWidths.count, 3, "card widths \(cardWidths)", file: file, line: line)
        }
        try assertPageCardFillsItsPane(controller, in: fixture, file: file, line: line)
    }

    /// The page card fills its pane, inset alike on both sides, and the web
    /// view fills its page area, then again once the window widens: no
    /// handoff's width cap is left behind (a cap left at the card's settled
    /// width only shows when the pane changes).
    private func assertPageCardFillsItsPane(_ controller: WebContentViewController,
                                            in fixture: Fixture,
                                            file: StaticString = #filePath,
                                            line: UInt = #line) throws {
        let card = controller.leftContainerViewForTesting
        let pane = try XCTUnwrap(card.superview, file: file, line: line)
        let webView = fixture.webViews[0]
        let pageArea = try XCTUnwrap(webView.superview, file: file, line: line)
        for widening in [0, 400] as [CGFloat] {
            if widening > 0 {
                let size = fixture.window.contentLayoutRect.size
                fixture.window.setContentSize(NSSize(width: size.width + widening, height: size.height))
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
            fixture.window.contentView?.layoutSubtreeIfNeeded()
            XCTAssertEqual(pane.bounds.maxX - card.frame.maxX, card.frame.minX - pane.bounds.minX,
                           accuracy: 0.5, "card \(card.frame) in pane \(pane.bounds), window widened by \(widening)",
                           file: file, line: line)
            XCTAssertEqual(webView.frame, pageArea.bounds, file: file, line: line)
        }
    }

    /// Follows a slide for half a second, past its end: the web view fills
    /// the page area on every turn and takes the slide's sizes on the way.
    private func assertFollowsPageArea(_ webView: NSView,
                                       in fixture: Fixture,
                                       _ slide: String,
                                       file: StaticString = #filePath,
                                       line: UInt = #line) {
        guard let pageArea = webView.superview else {
            return XCTFail("\(slide): the web view is not mounted", file: file, line: line)
        }
        var widths: [CGFloat] = [webView.frame.width]
        var offPageArea: [String] = []
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            fixture.window.contentView?.layoutSubtreeIfNeeded()
            if webView.frame != pageArea.bounds {
                offPageArea.append("\(webView.frame) in \(pageArea.bounds)")
            }
            if widths.last != webView.frame.width {
                widths.append(webView.frame.width)
            }
        }
        XCTAssertEqual(offPageArea, [], "\(slide): the web view left its page area",
                       file: file, line: line)
        XCTAssertGreaterThan(widths.count, 3, "\(slide): widths \(widths)", file: file, line: line)
    }

    private func assertJoinedAtFinalSize(_ webView: MountGeometryProbeView,
                                         file: StaticString = #filePath,
                                         line: UInt = #line) throws {
        let pageArea = try XCTUnwrap(webView.superview, file: file, line: line).bounds.size
        XCTAssertGreaterThan(pageArea.height, 0, file: file, line: line)
        XCTAssertEqual(webView.sizesInWindow, [pageArea],
                       "sizes since joining the window: \(webView.timeline)",
                       file: file, line: line)
    }
}

/// Stands in for a tab's web view: records every size it takes from the
/// moment it joins a window, and takes focus as a web view does.
private final class MountGeometryProbeView: NSView {
    private var entries: [(size: NSSize, uptime: TimeInterval)] = []

    override var acceptsFirstResponder: Bool { true }

    var sizesInWindow: [NSSize] { entries.map(\.size) }

    var timeline: String {
        let start = entries.first?.uptime ?? 0
        return entries.map { entry in
            let ms = Int(((entry.uptime - start) * 1000).rounded())
            return "\(Int(entry.size.width))x\(Int(entry.size.height)) at +\(ms) ms"
        }.joined(separator: ", ")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        entries = []
        record()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard window != nil else { return }
        record()
    }

    private func record() {
        guard entries.last?.size != frame.size else { return }
        entries.append((frame.size, ProcessInfo.processInfo.systemUptime))
    }
}

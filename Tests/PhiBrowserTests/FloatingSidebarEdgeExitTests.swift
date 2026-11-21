// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

/// The floating sidebar stays open when the pointer runs past the window's
/// edge on the sidebar's side, as long as the pointer came from inside the
/// window. A fast pointer can skip the narrow trigger strip at that edge, or
/// first show up in the strip's outer half, so the panel itself has to
/// remember that the pointer reached it. A pointer that only pokes in from
/// outside the window and goes straight back still lets the panel hide.
/// For the same reason a fast pointer leaving the window past that edge
/// reveals the panel, as a slow one crossing the strip on its way out does.
/// A pointer that leaves the window from the panel, past its edge or through
/// the top or bottom, keeps the panel open wherever it goes outside. Coming
/// back into the window over the page lets the panel hide; coming back over
/// the sidebar keeps it. The tests set where the pointer is
/// (`pointerLocationInWindow`) and check what the hide check does.
@MainActor
final class FloatingSidebarEdgeExitTests: XCTestCase {
    private var store: LocalStore!
    private var directory: URL!
    private var accountDirectory: URL!
    private var previousLayout: Any?
    private var slots: [SpaceWindowSlot] = []
    private let manager = SpaceManager(observeAccountChanges: false)
    private var nextWindowId = 223458789
    /// Held here: a wrapper's `nativeView` is weak.
    private var webViews: [NSView] = []
    /// Where the hide check finds the pointer, in window coordinates.
    private var pointer: NSPoint?

    override func setUp() async throws {
        previousLayout = UserDefaults.standard.object(forKey: PhiPreferences.GeneralSettings.layoutModeKey)
        PhiPreferences.GeneralSettings.saveLayoutMode(.performance)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let account = Account(userID: "floating-sidebar-edge-exit-test-\(UUID().uuidString)")
        accountDirectory = account.userDataStorage
        store = LocalStore(account: account, storeDirectoryURL: directory, presentsCompatibilityAlerts: false)
        account.localStorage = store
        let context = try XCTUnwrap(store.getMainContext())
        context.insert(ProfileModel(profileId: LocalStore.defaultProfileId))
        context.insert(SpaceModel(spaceId: "first", profileId: LocalStore.defaultProfileId,
            name: "first", colorHex: "#AAAAAA", iconName: "target", sortOrder: 0))
        try context.save()
        manager.bind(to: store.account)
        await drainMainQueue()
    }

    override func tearDown() async throws {
        manager.discardSpacePrewarm()
        for slot in slots { slot.closeShellIfPresent() }
        slots.removeAll()
        webViews.removeAll()
        await drainMainQueue()
        try await store.closeForAccountDirectoryRemoval()
        store = nil
        for url in [directory, accountDirectory].compactMap({ $0 })
        where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        UserDefaults.standard.set(previousLayout, forKey: PhiPreferences.GeneralSettings.layoutModeKey)
        try await super.tearDown()
    }

    /// The pointer moved into the panel, then left it in one jump past the
    /// window's edge without the strip ever seeing it.
    func testAPointerThatReachedThePanelKeepsItOpenPastTheWindowEdge() throws {
        let (host, panel, window) = try shownPanel()

        send(.mouseEntered, at: point(inside: panel, by: 40), to: panel, in: window)
        send(.mouseExited, at: point(outside: panel, by: 20), to: panel, in: window)
        pointer = point(outside: panel, by: 20)
        host.scheduleFloatingSidebarHide()
        waitPastTheHideCheck()

        XCTAssertTrue(host.isVisible)
    }

    /// A fast pointer coming from the panel can first show up in the strip's
    /// outer half, where a pointer coming in from outside the window lands.
    func testAPointerFromThePanelLandingInTheStripsOuterHalfKeepsItOpen() throws {
        let (host, panel, window) = try shownPanel()
        let strip = host.floatingSidebarTriggerView

        send(.mouseEntered, at: point(inside: panel, by: 40), to: panel, in: window)
        send(.mouseEntered, at: point(inside: strip, by: 2), to: strip, in: window)

        XCTAssertTrue(host.pointerReachedFloatingSidebar)
    }

    /// The strip opened the panel for a pointer coming in from outside the
    /// window, and the pointer then went on into the panel.
    func testAPointerLeavingTheStripInwardHasReachedThePanel() throws {
        let (host, panel, window) = try shownPanel()
        let strip = host.floatingSidebarTriggerView

        try sendWindowEntry(at: point(inside: strip, by: 2), to: host, in: window)
        send(.mouseEntered, at: point(inside: strip, by: 2), to: strip, in: window)
        send(.mouseExited, at: point(inside: panel, by: 30), to: strip, in: window)

        XCTAssertTrue(host.pointerReachedFloatingSidebar)
    }

    /// A pointer passing by from outside the window, say from another
    /// display, must not leave the panel stuck open.
    func testAPointerThatOnlyPokedInFromOutsideHasNotReachedThePanel() throws {
        let (host, panel, window) = try shownPanel()
        let strip = host.floatingSidebarTriggerView

        try sendWindowEntry(at: point(inside: strip, by: 2), to: host, in: window)
        send(.mouseEntered, at: point(inside: strip, by: 2), to: strip, in: window)
        send(.mouseExited, at: point(outside: panel, by: 5), to: strip, in: window)

        XCTAssertFalse(host.pointerReachedFloatingSidebar)
    }

    func testHidingThePanelForgetsThatThePointerReachedIt() throws {
        let (host, panel, window) = try shownPanel()
        send(.mouseEntered, at: point(inside: panel, by: 40), to: panel, in: window)
        XCTAssertTrue(host.pointerReachedFloatingSidebar, "precondition: the pointer reached the panel")

        host.hideFloatingSidebar(animated: false)

        XCTAssertFalse(host.pointerReachedFloatingSidebar)
    }

    /// The pointer jumped from the page to past the window's edge without
    /// the strip seeing it.
    func testAPointerLeavingPastTheSidebarsEdgeRevealsThePanel() throws {
        let (host, window) = try collapsedSidebar()
        let strip = host.floatingSidebarTriggerView

        try sendWindowExit(at: point(outside: strip, by: 30), to: host, in: window)

        XCTAssertTrue(host.isVisible)
        XCTAssertTrue(host.pointerReachedFloatingSidebar,
                      "the pointer came from the page, so running on past the edge keeps the panel open")
    }

    func testAPointerLeavingByTheOppositeEdgeLeavesThePanelHidden() throws {
        let (host, window) = try collapsedSidebar()
        let frame = host.view.convert(host.view.bounds, to: nil)

        try sendWindowExit(at: NSPoint(x: frame.maxX + 30, y: frame.midY), to: host, in: window)

        XCTAssertFalse(host.isVisible)
    }

    func testAPointerLeavingAboveTheStripLeavesThePanelHidden() throws {
        let (host, window) = try collapsedSidebar()
        let strip = host.floatingSidebarTriggerView.convert(host.floatingSidebarTriggerView.bounds, to: nil)

        try sendWindowExit(at: NSPoint(x: strip.minX + 2, y: strip.maxY + 30), to: host, in: window)

        XCTAssertFalse(host.isVisible)
    }

    /// The strip's and the panel's own exits pass up to the overlay; only
    /// the window's edge reveals the panel.
    func testAnExitPassedUpFromTheStripDoesNotRevealThePanel() throws {
        let (host, window) = try collapsedSidebar()
        let strip = host.floatingSidebarTriggerView

        send(.mouseExited, at: point(outside: strip, by: 30), to: host.view, in: window)

        XCTAssertFalse(host.isVisible)
    }

    func testAPointerComingBackOverThePageFromAboveLetsThePanelHide() throws {
        let (host, panel, window) = try shownPanel()
        let page = host.view.convert(host.view.bounds, to: nil)
        let glass = panel.convert(panel.bounds, to: nil)
        send(.mouseEntered, at: point(inside: panel, by: 40), to: panel, in: window)
        pointer = NSPoint(x: glass.midX, y: window.frame.height + 20)
        host.scheduleFloatingSidebarHide()
        waitPastTheHideCheck()
        XCTAssertTrue(host.isVisible, "precondition: held open while the pointer is outside")

        pointer = NSPoint(x: glass.maxX + 200, y: page.maxY - 1)
        waitPastAHideRecheck()

        XCTAssertFalse(host.isVisible)
    }

    func testAPointerComingBackOverTheSidebarFromBelowKeepsThePanel() throws {
        let (host, panel, window) = try shownPanel()
        let glass = panel.convert(panel.bounds, to: nil)
        send(.mouseEntered, at: point(inside: panel, by: 40), to: panel, in: window)
        pointer = NSPoint(x: glass.midX, y: -20)
        host.scheduleFloatingSidebarHide()
        waitPastTheHideCheck()

        pointer = NSPoint(x: glass.midX, y: glass.minY + 10)
        waitPastAHideRecheck()

        XCTAssertTrue(host.isVisible)
    }

    /// The pointer went out past the edge, then drifted above the window
    /// before the hide check ran.
    func testAPointerThatLeftPastTheEdgeKeepsThePanelOpenWhereverItGoes() throws {
        let (host, panel, window) = try shownPanel()
        send(.mouseEntered, at: point(inside: panel, by: 40), to: panel, in: window)
        pointer = point(outside: panel, by: 20)
        host.scheduleFloatingSidebarHide()

        pointer = NSPoint(x: 400, y: window.frame.height + 40)
        waitPastTheHideCheck()

        XCTAssertTrue(host.isVisible)
    }

    func testAPointerLeavingTheWindowFromThePanelThroughTheTopKeepsItOpen() throws {
        let (host, panel, window) = try shownPanel()
        let glass = panel.convert(panel.bounds, to: nil)
        send(.mouseEntered, at: point(inside: panel, by: 40), to: panel, in: window)

        pointer = NSPoint(x: glass.midX, y: window.frame.height + 20)
        host.scheduleFloatingSidebarHide()
        waitPastTheHideCheck()

        XCTAssertTrue(host.isVisible)
    }

    /// Shown without the pointer ever reaching it, the panel hides when the
    /// pointer leaves the window, as it does when the pointer leaves for the
    /// page.
    func testAPointerThatNeverReachedThePanelLetsItHideOutsideTheWindow() throws {
        let (host, panel, window) = try shownPanel()

        pointer = NSPoint(x: panel.convert(panel.bounds, to: nil).maxX + 200, y: window.frame.height + 20)
        host.scheduleFloatingSidebarHide()
        waitPastTheHideCheck()

        XCTAssertFalse(host.isVisible)
    }

    func testAPointerThatOnlyPokedInFromOutsideLetsThePanelHide() throws {
        let (host, panel, window) = try shownPanel()
        let strip = host.floatingSidebarTriggerView

        try sendWindowEntry(at: point(inside: strip, by: 2), to: host, in: window)
        send(.mouseEntered, at: point(inside: strip, by: 2), to: strip, in: window)
        send(.mouseExited, at: point(outside: panel, by: 5), to: strip, in: window)
        pointer = point(outside: panel, by: 5)
        waitPastTheHideCheck()

        XCTAssertFalse(host.isVisible)
    }

    func testComingBackIntoTheWindowAfterLeavingFromThePanelLetsItHide() throws {
        let (host, panel, window) = try shownPanel()
        let glass = panel.convert(panel.bounds, to: nil)
        let page = host.view.convert(host.view.bounds, to: nil)
        send(.mouseEntered, at: point(inside: panel, by: 40), to: panel, in: window)
        pointer = point(outside: panel, by: 20)
        host.scheduleFloatingSidebarHide()
        waitPastTheHideCheck()
        XCTAssertTrue(host.isVisible, "precondition: held open while the pointer is outside")

        pointer = NSPoint(x: glass.maxX + 200, y: page.minY + 1)
        waitPastAHideRecheck()

        XCTAssertFalse(host.isVisible)
    }

    /// A fast pointer from the page can land in the strip's outer half,
    /// where one coming in from outside the window lands.
    func testAPointerFromThePageLandingInTheStripsOuterHalfHasReachedThePanel() throws {
        let (host, window) = try collapsedSidebar()
        let strip = host.floatingSidebarTriggerView

        send(.mouseEntered, at: point(inside: strip, by: 2), to: strip, in: window)

        XCTAssertTrue(host.isVisible, "precondition: the strip revealed the panel")
        XCTAssertTrue(host.pointerReachedFloatingSidebar)
    }

    /// The window's own edge saw the pointer come in through the strip.
    func testAPointerComingIntoTheWindowThroughTheStripHasNotReachedThePanel() throws {
        let (host, window) = try collapsedSidebar()
        let strip = host.floatingSidebarTriggerView

        try sendWindowEntry(at: point(inside: strip, by: 8), to: host, in: window)
        send(.mouseEntered, at: point(inside: strip, by: 8), to: strip, in: window)

        XCTAssertTrue(host.isVisible, "precondition: the strip revealed the panel")
        XCTAssertFalse(host.pointerReachedFloatingSidebar)
    }

    /// AppKit may deliver the strip's entry before the window edge's.
    func testAPointerComingIntoTheWindowThroughTheStripInEitherEventOrderHasNotReachedThePanel() throws {
        let (host, window) = try collapsedSidebar()
        let strip = host.floatingSidebarTriggerView

        send(.mouseEntered, at: point(inside: strip, by: 8), to: strip, in: window)
        try sendWindowEntry(at: point(inside: strip, by: 8), to: host, in: window)

        XCTAssertFalse(host.pointerReachedFloatingSidebar)
    }

    /// The panel had started sliding out when the pointer ran past the edge.
    func testAPointerLeavingPastTheEdgeWhileThePanelHidesBringsItBack() throws {
        let (host, panel, window) = try shownPanel()
        send(.mouseEntered, at: point(inside: panel, by: 40), to: panel, in: window)
        // The strip comes on shortly after the collapse.
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        host.hideFloatingSidebar(animated: true)
        pointer = point(outside: panel, by: 20)
        try sendWindowExit(at: point(outside: panel, by: 20), to: host, in: window)
        waitPastTheHideCheck()

        XCTAssertTrue(host.isVisible)
    }

    func testPastTheEdgeIsLevelWithTheStripAndBeyondItOnTheSidebarsSide() {
        let strip = NSRect(x: 0, y: 0, width: 10, height: 600)
        typealias Host = FloatingSidebarHostViewController
        XCTAssertTrue(Host.isPastFloatingSidebarEdge(NSPoint(x: -1, y: 300), strip: strip, sidebarOnRight: false))
        XCTAssertFalse(Host.isPastFloatingSidebarEdge(NSPoint(x: 5, y: 300), strip: strip, sidebarOnRight: false))
        XCTAssertFalse(Host.isPastFloatingSidebarEdge(NSPoint(x: -1, y: 601), strip: strip, sidebarOnRight: false))

        let rightStrip = NSRect(x: 990, y: 0, width: 10, height: 600)
        XCTAssertTrue(Host.isPastFloatingSidebarEdge(NSPoint(x: 1000, y: 300), strip: rightStrip, sidebarOnRight: true))
        XCTAssertFalse(Host.isPastFloatingSidebarEdge(NSPoint(x: 995, y: 300), strip: rightStrip, sidebarOnRight: true))
        XCTAssertFalse(Host.isPastFloatingSidebarEdge(NSPoint(x: -1, y: 300), strip: rightStrip, sidebarOnRight: true))
    }

    // MARK: - Helpers

    /// Past the hide delay and the panel's minimum time on screen.
    private func waitPastTheHideCheck() {
        RunLoop.main.run(until: Date().addingTimeInterval(
            FloatingSidebarHostViewController.floatingSidebarMinimumVisibleDuration + 0.3))
    }

    /// Past the next look while the hide check holds the panel open, and its
    /// slide-out.
    private func waitPastAHideRecheck() {
        RunLoop.main.run(until: Date().addingTimeInterval(
            FloatingSidebarHostViewController.floatingSidebarHideDelay
                + FloatingSidebarHostViewController.floatingSidebarHideDuration + 0.3))
    }

    /// A point `distance` in from the left edge of `view`, in window
    /// coordinates. The sidebar sits on the left by default.
    private func point(inside view: NSView, by distance: CGFloat) -> NSPoint {
        let frame = view.convert(view.bounds, to: nil)
        return NSPoint(x: frame.minX + distance, y: frame.midY)
    }

    /// A point `distance` past the left edge of `view`, in window coordinates.
    private func point(outside view: NSView, by distance: CGFloat) -> NSPoint {
        let frame = view.convert(view.bounds, to: nil)
        return NSPoint(x: frame.minX - distance, y: frame.midY)
    }

    /// The overlay's own tracking area, the window's edge. AppKit installs
    /// tracking areas lazily; a test window may not have yet.
    private func windowEdge(of host: FloatingSidebarHostViewController) throws -> NSTrackingArea {
        func edge() -> NSTrackingArea? {
            host.view.trackingAreas.first { $0.owner === host.view && $0.options.contains(.mouseEnteredAndExited) }
        }
        if edge() == nil { host.view.updateTrackingAreas() }
        return try XCTUnwrap(edge(), "precondition: the window's edge is tracked")
    }

    /// The window's edge seeing the pointer come in from outside.
    private func sendWindowEntry(at location: NSPoint, to host: FloatingSidebarHostViewController,
                                 in window: NSWindow) throws {
        send(.mouseEntered, at: location, to: host.view, in: window, trackingArea: try windowEdge(of: host))
    }

    /// The window's edge seeing the pointer leave.
    private func sendWindowExit(at location: NSPoint, to host: FloatingSidebarHostViewController,
                                in window: NSWindow) throws {
        send(.mouseExited, at: location, to: host.view, in: window, trackingArea: try windowEdge(of: host))
    }

    /// Sends an enter or exit event. With `trackingArea`, the event comes
    /// from that area, as AppKit's own do; without it, it is one a subview
    /// passed up.
    private func send(_ type: NSEvent.EventType, at location: NSPoint, to view: NSView, in window: NSWindow,
                      timestamp: TimeInterval = 0, trackingArea: NSTrackingArea? = nil,
                      file: StaticString = #filePath, line: UInt = #line) {
        let trackingNumber = trackingArea.map { Int(bitPattern: Unmanaged.passUnretained($0).toOpaque()) } ?? 0
        guard let event = NSEvent.enterExitEvent(with: type, location: location, modifierFlags: [],
                                                 timestamp: timestamp, windowNumber: window.windowNumber,
                                                 context: nil, eventNumber: 0, trackingNumber: trackingNumber,
                                                 userData: nil) else {
            return XCTFail("could not make a \(type) event", file: file, line: line)
        }
        if type == .mouseEntered {
            view.mouseEntered(with: event)
        } else {
            view.mouseExited(with: event)
        }
    }

    /// A shell with the sidebar collapsed, its strip ready and its floating
    /// panel hidden.
    private func collapsedSidebar(file: StaticString = #filePath, line: UInt = #line)
        throws -> (FloatingSidebarHostViewController, NSWindow) {
        let slot = try makeSlot()
        let window = try XCTUnwrap(slot.shell?.window, file: file, line: line)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let split = try XCTUnwrap(slot.shell?.split, file: file, line: line)
        split.setSidebarCollapsed(true, animated: false)
        // The strip comes on shortly after the collapse.
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        split.view.layoutSubtreeIfNeeded()
        let host = split.floatingSidebarHost
        host.pointerLocationInWindow = { [unowned self] in self.pointer }
        XCTAssertFalse(host.floatingSidebarTriggerView.isHidden, "precondition: the strip is on",
                       file: file, line: line)
        XCTAssertFalse(host.isVisible, "precondition: the panel is hidden", file: file, line: line)
        return (host, window)
    }

    /// A shell with the sidebar collapsed and its floating panel shown.
    private func shownPanel(file: StaticString = #filePath, line: UInt = #line)
        throws -> (FloatingSidebarHostViewController, NSView, NSWindow) {
        let slot = try makeSlot()
        let window = try XCTUnwrap(slot.shell?.window, file: file, line: line)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let split = try XCTUnwrap(slot.shell?.split, file: file, line: line)
        split.setSidebarCollapsed(true, animated: false)
        let host = split.floatingSidebarHost
        host.pointerLocationInWindow = { [unowned self] in self.pointer }
        host.showFloatingSidebar()
        XCTAssertTrue(host.isVisible, "precondition: the panel is shown", file: file, line: line)
        let panel = try XCTUnwrap(host.floatingSidebarContainerView, file: file, line: line)
        split.view.layoutSubtreeIfNeeded()
        XCTAssertFalse(host.pointerReachedFloatingSidebar,
                       "precondition: no pointer has reached the panel yet", file: file, line: line)
        return (host, panel, window)
    }

    /// A shell presenting one Space with one focused, mounted tab.
    private func makeSlot() throws -> SpaceWindowSlot {
        let slot = SpaceWindowSlot(manager: manager, initialSpaceId: "first")
        slot.ensureShell(initialFrame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        slots.append(slot)
        nextWindowId += 1
        let state = UnseededBrowserState(windowId: nextWindowId, localStore: store,
            profileId: LocalStore.defaultProfileId, spaceId: "first")
        let webView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        webViews.append(webView)
        let wrapper = PageColorTestWebContentWrapper(urlString: "https://first.example/")
        wrapper.nativeView = webView
        let tab = Tab(guid: nextWindowId, url: wrapper.urlString, isActive: true,
            index: 0, webContentView: wrapper)
        state.tabs = [tab]
        state.updateNormalTabs()
        state.focusingTab = tab
        let session = SpaceSessionController(window: slot.shell!.window, windowId: state.windowId,
            profileId: state.profileId, spaceId: "first", account: store.account,
            slot: slot, browserState: state, dormant: true)
        slot.registerWindow(session, for: "first")
        XCTAssertTrue(session.isPresented, "precondition: the Space is presented")
        slot.shell?.window.orderFront(nil)
        let deadline = Date().addingTimeInterval(2)
        while webView.window == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertNotNil(webView.window, "precondition: the page is mounted")
        return slot
    }

    private func drainMainQueue() async {
        let drained = expectation(description: "Main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
    }
}

/// These Browsers have their tab already, and must never seed one.
private final class UnseededBrowserState: BrowserState {
    override func createQuickLookupTab(customGuid: String? = nil) {}
}

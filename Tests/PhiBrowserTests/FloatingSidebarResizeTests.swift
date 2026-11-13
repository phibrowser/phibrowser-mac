// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

/// The floating panel shown while the sidebar column is collapsed can be
/// resized by dragging its inner edge: the right edge with the sidebar on the
/// left, the left edge with the sidebar on the right. The panel and the docked
/// column share one width: the panel's new width is the one the column docks at.
@MainActor
final class FloatingSidebarResizeTests: XCTestCase {
    private var store: LocalStore!
    private var directory: URL!
    private var accountDirectory: URL!
    private var previousLayout: Any?
    private var previousSidebarPosition: Any?
    private var slots: [SpaceWindowSlot] = []
    private let manager = SpaceManager(observeAccountChanges: false)
    private var nextWindowId = 223458789
    /// Held here: a wrapper's `nativeView` is weak.
    private var webViews: [NSView] = []

    private let minWidth = MainSplitViewController.leftItemMinWidth
    private let maxWidth = MainSplitViewController.leftItemMaxWidth
    private let inset = FloatingSidebarHostViewController.floatingSidebarInset

    override func setUp() async throws {
        previousLayout = UserDefaults.standard.object(forKey: PhiPreferences.GeneralSettings.layoutModeKey)
        PhiPreferences.GeneralSettings.saveLayoutMode(.performance)
        previousSidebarPosition = UserDefaults.standard.object(forKey: PhiPreferences.GeneralSettings.sidebarPositionKey)
        PhiPreferences.GeneralSettings.saveSidebarPosition(.left)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let account = Account(userID: "floating-sidebar-resize-test-\(UUID().uuidString)")
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
        UserDefaults.standard.set(previousSidebarPosition, forKey: PhiPreferences.GeneralSettings.sidebarPositionKey)
        try await super.tearDown()
    }

    func testDraggingThePanelEdgeResizesThePanel() throws {
        let slot = try makeSlot()
        let split = try XCTUnwrap(slot.shell?.split)
        let panel = try showPanel(in: slot)
        let handle = try XCTUnwrap(split.floatingSidebarHost.floatingSidebarResizeHandle)
        let startWidth = panel.frame.width

        drag(handle, by: 60)
        split.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(panel.frame.width, startWidth + 60, accuracy: 0.5)
        XCTAssertEqual(split.lastExpandedSidebarWidth, startWidth - inset + 60, accuracy: 0.5,
                       "the panel's width is the column's width")
        XCTAssertTrue(split.isSidebarCollapsed, "resizing the panel does not dock the column")
    }

    func testThePanelEdgeTakesTheClicksAtThePanelsRightEdge() throws {
        let slot = try makeSlot()
        let window = try XCTUnwrap(slot.shell?.window)
        let split = try XCTUnwrap(slot.shell?.split)
        let panel = try showPanel(in: slot)
        let handle = try XCTUnwrap(split.floatingSidebarHost.floatingSidebarResizeHandle)

        let panelFrame = panel.convert(panel.bounds, to: nil)
        let reach = PhiSplitViewController.dividerHitThickness / 2
        for x in [panelFrame.maxX - reach + 1, panelFrame.maxX - 1, panelFrame.maxX + 1, panelFrame.maxX + reach - 1] {
            let hit = try XCTUnwrap(window.contentView?.hitTest(NSPoint(x: x, y: panelFrame.midY)))
            XCTAssertTrue(hit === handle, "a click \(x - panelFrame.maxX)pt from the panel's right edge grabs the edge, not \(hit)")
        }
        let pastHit = window.contentView?.hitTest(NSPoint(x: panelFrame.maxX + reach + 2, y: panelFrame.midY))
        XCTAssertFalse(pastHit === handle, "clicks further right reach the page")

        split.floatingSidebarHost.hideFloatingSidebar(animated: false)
        XCTAssertTrue(handle.isHidden, "a closed panel has no edge to grab")
    }

    func testThePanelWidthStaysBetweenTheColumnsLimits() throws {
        let slot = try makeSlot()
        let split = try XCTUnwrap(slot.shell?.split)
        let host = split.floatingSidebarHost
        let panel = try showPanel(in: slot)

        host.beginFloatingSidebarResize()
        host.resizeFloatingSidebar(toWidth: 40)
        split.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(panel.frame.width, minWidth + inset, accuracy: 0.5)

        host.resizeFloatingSidebar(toWidth: 4000)
        split.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(panel.frame.width, maxWidth + inset, accuracy: 0.5)
        host.endFloatingSidebarResize()
    }

    func testTheColumnDocksAtThePanelsWidth() throws {
        let slot = try makeSlot()
        let split = try XCTUnwrap(slot.shell?.split)
        let host = split.floatingSidebarHost
        _ = try showPanel(in: slot)

        host.beginFloatingSidebarResize()
        host.resizeFloatingSidebar(toWidth: 320)
        host.endFloatingSidebarResize()

        split.setSidebarCollapsed(false, animated: false)
        split.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(split.sidebarWidth, 320, accuracy: 0.5, "the column docks at the panel's width")

        // The column's own limits are back once it has docked.
        split.setSidebarGeometry(width: 450, collapsed: false)
        split.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(split.sidebarWidth, 450, accuracy: 0.5)
    }

    func testTheColumnDocksAtThePanelsWidthWhenItIsNarrowerThanBefore() throws {
        let slot = try makeSlot()
        let split = try XCTUnwrap(slot.shell?.split)
        let host = split.floatingSidebarHost
        split.setSidebarGeometry(width: 400, collapsed: false)
        split.view.layoutSubtreeIfNeeded()
        _ = try showPanel(in: slot)

        host.beginFloatingSidebarResize()
        host.resizeFloatingSidebar(toWidth: 250)
        host.endFloatingSidebarResize()

        split.setSidebarCollapsed(false, animated: false)
        split.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(split.sidebarWidth, 250, accuracy: 0.5)
    }

    /// Toggling the sidebar docks it with an animation.
    func testTheColumnDocksAtThePanelsWidthWhenAnimated() throws {
        let slot = try makeSlot()
        let split = try XCTUnwrap(slot.shell?.split)
        let host = split.floatingSidebarHost
        _ = try showPanel(in: slot)

        host.beginFloatingSidebarResize()
        host.resizeFloatingSidebar(toWidth: 360)
        host.endFloatingSidebarResize()

        split.setSidebarCollapsed(false, animated: true)
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        split.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(split.sidebarWidth, 360, accuracy: 0.5)

        split.setSidebarGeometry(width: 220, collapsed: false)
        split.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(split.sidebarWidth, 220, accuracy: 0.5, "the column's own limits are back")
    }

    func testThePanelStaysOpenWhileItsEdgeIsDragged() throws {
        let slot = try makeSlot()
        let split = try XCTUnwrap(slot.shell?.split)
        let host = split.floatingSidebarHost
        _ = try showPanel(in: slot)

        host.beginFloatingSidebarResize()
        // The pointer is not over the panel in this fixture, so a scheduled
        // hide would otherwise close it.
        host.scheduleFloatingSidebarHide()
        RunLoop.main.run(until: Date().addingTimeInterval(
            FloatingSidebarHostViewController.floatingSidebarMinimumVisibleDuration + 0.3))
        XCTAssertTrue(host.isVisible, "the panel stays open while its edge is dragged")

        host.endFloatingSidebarResize()
        RunLoop.main.run(until: Date().addingTimeInterval(
            FloatingSidebarHostViewController.floatingSidebarHideDelay
                + FloatingSidebarHostViewController.floatingSidebarHideDuration + 0.3))
        XCTAssertFalse(host.isVisible, "letting go with the pointer outside closes the panel")
    }

    func testTheStripJustRightOfThePanelForgivesASlip() throws {
        let slot = try makeSlot()
        let split = try XCTUnwrap(slot.shell?.split)
        let host = split.floatingSidebarHost
        let panel = try showPanel(in: slot)
        let frame = panel.convert(panel.bounds, to: nil)
        let buffer = FloatingSidebarHostViewController.floatingSidebarEdgeBufferWidth

        XCTAssertTrue(host.floatingSidebarEdgeBufferContains(NSPoint(x: frame.maxX + 1, y: frame.midY)))
        XCTAssertTrue(host.floatingSidebarEdgeBufferContains(NSPoint(x: frame.maxX + buffer, y: frame.midY)))
        XCTAssertFalse(host.floatingSidebarEdgeBufferContains(NSPoint(x: frame.maxX + buffer + 1, y: frame.midY)),
                       "past the strip the panel closes")
        XCTAssertFalse(host.floatingSidebarEdgeBufferContains(NSPoint(x: frame.midX, y: frame.midY)),
                       "the panel itself is not the strip")
        XCTAssertFalse(host.floatingSidebarEdgeBufferContains(NSPoint(x: frame.maxX + 1, y: frame.maxY + 1)),
                       "the strip spans the panel's height only")

        host.hideFloatingSidebar(animated: false)
        XCTAssertFalse(host.floatingSidebarEdgeBufferContains(NSPoint(x: frame.maxX + 1, y: frame.midY)),
                       "a closed panel has no strip")
    }

    // MARK: - Sidebar on the right
    //
    // These check the mirrored geometry without moving a window's sidebar to
    // the right: the side is a shared preference, and test classes run in
    // parallel processes that would see the change.

    func testOnTheRightDraggingLeftWidensThePanel() {
        typealias Host = FloatingSidebarHostViewController
        XCTAssertEqual(Host.floatingSidebarWidth(from: 250, dragOffset: -60, sidebarOnRight: true), 310)
        XCTAssertEqual(Host.floatingSidebarWidth(from: 250, dragOffset: 60, sidebarOnRight: true), 190)
        XCTAssertEqual(Host.floatingSidebarWidth(from: 250, dragOffset: 60, sidebarOnRight: false), 310)
    }

    func testOnTheRightTheSlackStripIsLeftOfThePanel() {
        typealias Host = FloatingSidebarHostViewController
        let frame = NSRect(x: 800, y: 5, width: 200, height: 690)
        let buffer = Host.floatingSidebarEdgeBufferWidth

        XCTAssertTrue(Host.edgeBuffer(of: frame, sidebarOnRight: true, contains: NSPoint(x: frame.minX - 1, y: frame.midY)))
        XCTAssertTrue(Host.edgeBuffer(of: frame, sidebarOnRight: true, contains: NSPoint(x: frame.minX - buffer, y: frame.midY)))
        XCTAssertFalse(Host.edgeBuffer(of: frame, sidebarOnRight: true, contains: NSPoint(x: frame.minX - buffer - 1, y: frame.midY)))
        XCTAssertFalse(Host.edgeBuffer(of: frame, sidebarOnRight: true, contains: NSPoint(x: frame.maxX + 1, y: frame.midY)),
                       "the outer edge has no strip")
        XCTAssertFalse(Host.edgeBuffer(of: frame, sidebarOnRight: true, contains: NSPoint(x: frame.minX - 1, y: frame.maxY + 1)))
    }

    // MARK: - Helpers

    /// Presses the handle, moves the pointer `dx` points right, and lets go.
    private func drag(_ handle: NSView, by dx: CGFloat) {
        let window = handle.window
        let start = handle.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
        func event(_ type: NSEvent.EventType, at x: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: start.y), modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window?.windowNumber ?? 0, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        handle.mouseDown(with: event(.leftMouseDown, at: start.x))
        handle.mouseDragged(with: event(.leftMouseDragged, at: start.x + dx / 2))
        handle.mouseDragged(with: event(.leftMouseDragged, at: start.x + dx))
        handle.mouseUp(with: event(.leftMouseUp, at: start.x + dx))
    }

    /// The sidebar column collapsed and its floating panel shown.
    private func showPanel(in slot: SpaceWindowSlot,
                           file: StaticString = #filePath,
                           line: UInt = #line) throws -> NSView {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let split = try XCTUnwrap(slot.shell?.split, file: file, line: line)
        split.setSidebarCollapsed(true, animated: false)
        let host = split.floatingSidebarHost
        host.showFloatingSidebar()
        XCTAssertTrue(host.isVisible, "precondition: the panel is shown", file: file, line: line)
        let panel = try XCTUnwrap(host.floatingSidebarContainerView, file: file, line: line)
        split.view.layoutSubtreeIfNeeded()
        return panel
    }

    /// A shell presenting one Space with one focused, mounted tab.
    private func makeSlot() throws -> SpaceWindowSlot {
        let slot = SpaceWindowSlot(manager: manager, initialSpaceId: "first")
        slot.ensureShell(initialFrame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        slots.append(slot)
        nextWindowId += 1
        let state = UnseededBrowserState(windowId: nextWindowId, localStore: store,
            profileId: LocalStore.defaultProfileId, spaceId: "first", isIncognito: false)
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

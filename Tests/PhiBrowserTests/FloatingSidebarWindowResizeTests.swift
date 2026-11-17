// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

/// A window resize (the full screen light, a zoom) moves the floating panel
/// under a pointer that has not moved. The panel's tracking area never sees
/// that pointer leave, so the panel re-checks it after the resize: it closes
/// when the pointer is no longer on it and stays open when it still is.
/// Into or out of full screen it checks once the animation has ended, so
/// it slides out in view.
///
/// These tests place the window around the real pointer, so they read the
/// pointer as it is, without moving it.
@MainActor
final class FloatingSidebarWindowResizeTests: XCTestCase {
    private var store: LocalStore!
    private var directory: URL!
    private var accountDirectory: URL!
    private var previousLayout: Any?
    private var previousSidebarPosition: Any?
    private var slots: [SpaceWindowSlot] = []
    private let manager = SpaceManager(observeAccountChanges: false)
    private var nextWindowId = 223459789
    /// Held here: a wrapper's `nativeView` is weak.
    private var webViews: [NSView] = []

    override func setUp() async throws {
        previousLayout = UserDefaults.standard.object(forKey: PhiPreferences.GeneralSettings.layoutModeKey)
        PhiPreferences.GeneralSettings.saveLayoutMode(.performance)
        previousSidebarPosition = UserDefaults.standard.object(forKey: PhiPreferences.GeneralSettings.sidebarPositionKey)
        PhiPreferences.GeneralSettings.saveSidebarPosition(.left)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let account = Account(userID: "floating-sidebar-window-resize-test-\(UUID().uuidString)")
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

    func testThePanelClosesWhenAResizeLeavesThePointerOffIt() throws {
        let slot = try makeSlot()
        let window = try XCTUnwrap(slot.shell?.window)
        let host = try XCTUnwrap(slot.shell?.split).floatingSidebarHost
        try showPanel(in: slot)

        // Far from the pointer, which no tracking area then reports leaving.
        let pointer = NSEvent.mouseLocation
        window.setFrameOrigin(NSPoint(x: pointer.x + 3000, y: pointer.y + 3000))
        XCTAssertFalse(host.isMouseInsideFloatingSidebarVisibleRegion(), "precondition: the pointer is off the panel")
        XCTAssertTrue(host.isVisible, "precondition: moving the window alone leaves the panel open")

        window.setFrame(window.frame.insetBy(dx: -100, dy: -100), display: true)

        XCTAssertTrue(waitUntil { !host.isVisible }, "the panel closes once the resize has left the pointer off it")
    }

    func testIntoFullScreenThePanelWaitsForTheAnimationToEndBeforeClosing() throws {
        let slot = try makeSlot()
        let window = try XCTUnwrap(slot.shell?.window)
        let host = try XCTUnwrap(slot.shell?.split).floatingSidebarHost
        try showPanel(in: slot)
        let pointer = NSEvent.mouseLocation
        window.setFrameOrigin(NSPoint(x: pointer.x + 3000, y: pointer.y + 3000))
        XCTAssertFalse(host.isMouseInsideFloatingSidebarVisibleRegion(), "precondition: the pointer is off the panel")

        // The frame jumps to the full screen size as the animation starts.
        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        window.setFrame(window.frame.insetBy(dx: -100, dy: -100), display: true)
        XCTAssertFalse(waitUntil { !host.isVisible }, "the panel stays while the window animates into full screen")

        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: window)
        XCTAssertTrue(waitUntil { !host.isVisible }, "the panel closes once the window is in full screen")
    }

    func testOutOfFullScreenThePanelWaitsForTheAnimationToEndBeforeClosing() throws {
        let slot = try makeSlot()
        let window = try XCTUnwrap(slot.shell?.window)
        let host = try XCTUnwrap(slot.shell?.split).floatingSidebarHost
        try showPanel(in: slot)
        let pointer = NSEvent.mouseLocation
        window.setFrameOrigin(NSPoint(x: pointer.x + 3000, y: pointer.y + 3000))

        NotificationCenter.default.post(name: NSWindow.willExitFullScreenNotification, object: window)
        window.setFrame(window.frame.insetBy(dx: 100, dy: 100), display: true)
        XCTAssertFalse(waitUntil { !host.isVisible }, "the panel stays while the window animates out of full screen")

        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: window)
        XCTAssertTrue(waitUntil { !host.isVisible }, "the panel closes once the window has left full screen")
    }

    func testThePanelStaysOpenWhenThePointerIsStillOnItAfterAResize() throws {
        let slot = try makeSlot()
        let window = try XCTUnwrap(slot.shell?.window)
        let host = try XCTUnwrap(slot.shell?.split).floatingSidebarHost
        let panel = try showPanel(in: slot)

        // The pointer near the panel's bottom-left; a resize that keeps the
        // window's origin keeps the panel there.
        let panelFrame = panel.convert(panel.bounds, to: nil)
        let onPanel = NSPoint(x: panelFrame.midX, y: panelFrame.minY + 100)
        let pointer = NSEvent.mouseLocation
        window.setFrameOrigin(NSPoint(x: pointer.x - onPanel.x, y: pointer.y - onPanel.y))
        XCTAssertTrue(host.isMouseInsideFloatingSidebarVisibleRegion(), "precondition: the pointer is on the panel")

        var grown = window.frame
        grown.size.width += 200
        grown.size.height += 100
        window.setFrame(grown, display: true)

        XCTAssertFalse(waitUntil { !host.isVisible }, "the panel stays open while the pointer is on it")
    }

    // MARK: - Helpers

    /// Runs the main run loop until `condition` holds or a second has
    /// passed: longer than the panel's minimum time on screen and its hide
    /// delay together.
    private func waitUntil(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(1)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    /// The sidebar column collapsed and its floating panel shown.
    @discardableResult
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

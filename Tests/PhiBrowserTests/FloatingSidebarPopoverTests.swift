// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

/// A popover opened from the floating sidebar, such as a pinned tab's icon
/// picker, holds the panel open while it is up, as the inline create-Space
/// form does. Hover can't see a pointer over the popover's own window, so
/// without the hold the panel would slide away from under an open picker and
/// leave it floating over the page. A forced hide takes the popover down
/// with the panel.
@MainActor
final class FloatingSidebarPopoverTests: XCTestCase {
    private var store: LocalStore!
    private var directory: URL!
    private var accountDirectory: URL!
    private var previousLayout: Any?
    private var slots: [SpaceWindowSlot] = []
    private var popovers: [NSPopover] = []
    private let manager = SpaceManager(observeAccountChanges: false)
    private var nextWindowId = 323458789
    /// Held here: a wrapper's `nativeView` is weak.
    private var webViews: [NSView] = []

    override func setUp() async throws {
        previousLayout = UserDefaults.standard.object(forKey: PhiPreferences.GeneralSettings.layoutModeKey)
        PhiPreferences.GeneralSettings.saveLayoutMode(.performance)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let account = Account(userID: "floating-sidebar-popover-test-\(UUID().uuidString)")
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
        for popover in popovers where popover.isShown { popover.close() }
        popovers.removeAll()
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

    func testAPopoverOpenedFromThePanelHoldsItOpen() throws {
        let (host, panel) = try shownPanel()

        showPopover(from: anchor(in: panel))

        XCTAssertTrue(host.isHeldOpenByPopover)
    }

    func testClosingThePopoverReleasesThePanel() throws {
        let (host, panel) = try shownPanel()
        let popover = showPopover(from: anchor(in: panel))
        XCTAssertTrue(host.isHeldOpenByPopover, "precondition: the popover holds the panel")

        popover.close()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertFalse(host.isHeldOpenByPopover)
    }

    /// A popover posts its show only once it has animated in. A pointer
    /// leaving the panel while the picker opens schedules a hide that would
    /// run before then.
    func testAHideScheduledAsAPopoverStartsOpeningLeavesThePanelUp() throws {
        let (host, _) = try shownPanel()
        let popover = NSPopover()
        popovers.append(popover)

        host.scheduleFloatingSidebarHide()
        NotificationCenter.default.post(name: NSPopover.willShowNotification, object: popover)
        RunLoop.main.run(until: Date().addingTimeInterval(
            FloatingSidebarHostViewController.floatingSidebarMinimumVisibleDuration + 0.3))

        XCTAssertTrue(host.isVisible)
        XCTAssertTrue(host.isHeldOpenByPopover)
    }

    /// A popover from elsewhere in the window, the toolbar say, has nothing
    /// to do with the panel.
    func testAPopoverOpenedAwayFromThePanelDoesNotHoldIt() throws {
        let (host, panel) = try shownPanel()
        let contentView = try XCTUnwrap(panel.window?.contentView)
        let farAnchor = NSView(frame: NSRect(x: contentView.bounds.maxX - 60, y: contentView.bounds.midY,
                                             width: 20, height: 20))
        contentView.addSubview(farAnchor)

        showPopover(from: farAnchor)

        XCTAssertFalse(host.isHeldOpenByPopover)
    }

    /// The sidebar docking, or the window going away, hides the panel
    /// regardless; the popover must not stay behind over the page.
    func testAForcedHideClosesThePopover() throws {
        let (host, panel) = try shownPanel()
        let popover = showPopover(from: anchor(in: panel))

        host.hideFloatingSidebar(animated: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertFalse(popover.isShown)
        XCTAssertFalse(host.isHeldOpenByPopover)
    }

    // MARK: - Helpers

    /// A small view inside the panel to anchor a popover to, as a pinned
    /// tile is.
    private func anchor(in panel: NSView) -> NSView {
        let view = NSView(frame: NSRect(x: 20, y: panel.bounds.midY, width: 30, height: 30))
        panel.addSubview(view)
        return view
    }

    @discardableResult
    private func showPopover(from anchor: NSView, file: StaticString = #filePath, line: UInt = #line) -> NSPopover {
        let popover = NSPopover()
        popover.animates = false
        popover.contentSize = NSSize(width: 200, height: 150)
        popover.contentViewController = NSViewController()
        popover.contentViewController?.view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 150))
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        popovers.append(popover)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(popover.isShown, "precondition: the popover is up", file: file, line: line)
        return popover
    }

    /// A shell with the sidebar collapsed and its floating panel shown.
    private func shownPanel(file: StaticString = #filePath, line: UInt = #line)
        throws -> (FloatingSidebarHostViewController, NSView) {
        let slot = try makeSlot()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let split = try XCTUnwrap(slot.shell?.split, file: file, line: line)
        split.setSidebarCollapsed(true, animated: false)
        let host = split.floatingSidebarHost
        host.showFloatingSidebar()
        XCTAssertTrue(host.isVisible, "precondition: the panel is shown", file: file, line: line)
        let panel = try XCTUnwrap(host.floatingSidebarContainerView, file: file, line: line)
        split.view.layoutSubtreeIfNeeded()
        return (host, panel)
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

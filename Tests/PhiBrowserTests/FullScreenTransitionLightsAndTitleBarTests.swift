// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

/// The window's chrome follows full screen as the transition starts: the
/// floating sidebar's lights go on the way in and come back on the way out,
/// and the title bar takes its windowed look on the way out. AppKit captures
/// the window for its animation right after resizing it, so a later update
/// would leave the old chrome in the animation until it ends. On the way in
/// the title bar keeps its look until the deferred observer runs: switching
/// it as the transition starts sometimes left the window's old contents in
/// the animation.
@MainActor
final class FullScreenTransitionLightsAndTitleBarTests: XCTestCase {
    private var store: LocalStore!
    private var directory: URL!
    private var accountDirectory: URL!
    private var previousLayout: Any?
    private var slots: [SpaceWindowSlot] = []
    private let manager = SpaceManager(observeAccountChanges: false)
    private var nextWindowId = 323468789
    /// Held here: a wrapper's `nativeView` is weak.
    private var webViews: [NSView] = []

    override func setUp() async throws {
        previousLayout = UserDefaults.standard.object(forKey: PhiPreferences.GeneralSettings.layoutModeKey)
        PhiPreferences.GeneralSettings.saveLayoutMode(.performance)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let account = Account(userID: "floating-traffic-lights-full-screen-test-\(UUID().uuidString)")
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

    func testTheLightsGoAsTheWindowStartsIntoFullScreen() throws {
        let (slot, state) = try makeSlot()
        let lights = try trafficLights(in: showPanel(in: slot))
        let window = try XCTUnwrap(lights.window)

        // The window controller marks the Browser full screen as the
        // transition starts; AppKit captures the window before the run loop
        // turns again.
        state.toggleFullScreenMode(true)
        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        XCTAssertTrue(lights.isHidden, "the lights are gone before the run loop turns")
    }

    func testTheLightsComeBackAsTheWindowStartsOutOfFullScreen() throws {
        let (slot, state) = try makeSlot()
        let lights = try trafficLights(in: showPanel(in: slot))
        let window = try XCTUnwrap(lights.window)
        state.toggleFullScreenMode(true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(lights.isHidden, "precondition: no lights in full screen")

        state.toggleFullScreenMode(false)
        NotificationCenter.default.post(name: NSWindow.willExitFullScreenNotification, object: window)
        XCTAssertFalse(lights.isHidden, "the lights are back before the run loop turns")
    }

    func testTheTitleBarTakesItsWindowedLookAsTheWindowStartsOutOfFullScreen() throws {
        let (slot, state) = try makeSlot()
        _ = try showPanel(in: slot)
        let window = try XCTUnwrap(slot.shell?.window)
        state.toggleFullScreenMode(true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertFalse(window.titlebarAppearsTransparent, "precondition: full screen shows the title bar")

        NotificationCenter.default.post(name: NSWindow.willExitFullScreenNotification, object: window)
        XCTAssertTrue(window.titlebarAppearsTransparent, "the title bar is transparent again before the run loop turns")
        XCTAssertEqual(window.standardWindowButton(.closeButton)?.isHidden, true,
                       "the collapsed sidebar's window hides its own lights again before the run loop turns")
    }

    func testTheTitleBarKeepsItsLookAsTheWindowStartsIntoFullScreen() throws {
        let (slot, _) = try makeSlot()
        _ = try showPanel(in: slot)
        let window = try XCTUnwrap(slot.shell?.window)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(window.titlebarAppearsTransparent, "precondition: the window's title bar is transparent")

        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        XCTAssertTrue(window.titlebarAppearsTransparent, "the title bar keeps its look as the transition starts")
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertFalse(window.titlebarAppearsTransparent, "the full screen title bar is set once the run loop turns")
    }

    // MARK: - Helpers

    private func trafficLights(in panel: NSView,
                               file: StaticString = #filePath,
                               line: UInt = #line) throws -> FloatingTrafficLightsView {
        func find(_ view: NSView) -> FloatingTrafficLightsView? {
            if let lights = view as? FloatingTrafficLightsView { return lights }
            return view.subviews.lazy.compactMap(find).first
        }
        let lights = try XCTUnwrap(find(panel), "the panel's header has lights", file: file, line: line)
        XCTAssertFalse(lights.isHidden, "precondition: the lights are shown", file: file, line: line)
        return lights
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

    /// A shell presenting one Space with one focused, mounted tab, and that
    /// Space's Browser.
    private func makeSlot() throws -> (SpaceWindowSlot, BrowserState) {
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
        return (slot, state)
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

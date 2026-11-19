// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

/// With the column collapsed, the floating sidebar's header holds the window's
/// own buttons, and the titlebar's stay hidden meanwhile.
@MainActor
final class SidebarTrafficLightsTests: XCTestCase {
    private var store: LocalStore!
    private var directory: URL!
    private var accountDirectory: URL!
    private var previousLayout: Any?
    private var slots: [SpaceWindowSlot] = []
    private let manager = SpaceManager(observeAccountChanges: false)
    private var nextWindowId = 323458789
    /// Held here: a wrapper's `nativeView` is weak.
    private var webViews: [NSView] = []

    override func setUp() async throws {
        previousLayout = UserDefaults.standard.object(forKey: PhiPreferences.GeneralSettings.layoutModeKey)
        PhiPreferences.GeneralSettings.saveLayoutMode(.performance)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let account = Account(userID: "floating-traffic-lights-test-\(UUID().uuidString)")
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

    private let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

    func testTheFloatingHeaderHoldsTheWindowsOwnButtons() throws {
        let slot = try makeSlot()
        let lights = try trafficLights(in: showPanel(in: slot))
        let window = try XCTUnwrap(lights.window)

        XCTAssertEqual(try buttons(of: lights).map(\.action),
                       types.map { NSWindow.standardWindowButton($0, for: window.styleMask)?.action },
                       "close, minimize and zoom, in order")
        for type in types {
            let own = try XCTUnwrap(window.titlebarButton(type), "the titlebar keeps its own")
            XCTAssertFalse(own.superview is SidebarTrafficLightsView)
            XCTAssertTrue(own.isHidden, "and hides it")
        }
    }

    /// The titlebar's pitch: 23 pt on macOS 26, 20 pt on macOS 14 and 15.
    func testTheLightsAreSpacedLikeTheWindowsOwn() throws {
        let slot = try makeSlot()
        let lights = try trafficLights(in: showPanel(in: slot))
        let window = try XCTUnwrap(lights.window)
        let native = try types.map { try XCTUnwrap(window.titlebarButton($0)).frame.midX }
        let placed = try buttons(of: lights).map { $0.convert(NSPoint(x: $0.bounds.midX, y: 0), to: nil).x }

        XCTAssertEqual(placed[1] - placed[0], native[1] - native[0], accuracy: 0.5, "close to minimize")
        XCTAssertEqual(placed[2] - placed[1], native[2] - native[1], accuracy: 0.5, "minimize to zoom")
    }

    func testTheSidebarButtonKeepsItsGapAfterTheLights() throws {
        let slot = try makeSlot()
        let panel = try showPanel(in: slot)
        let zoom = try XCTUnwrap(buttons(of: trafficLights(in: panel)).last)
        let button = try XCTUnwrap(view(identified: "sidebarHeader.sidebarButton", in: panel))

        let zoomMaxX = zoom.convert(zoom.bounds, to: nil).maxX
        XCTAssertEqual(button.convert(button.bounds, to: nil).minX, zoomMaxX + 10, accuracy: 0.5,
                       "10 pt after the zoom light")
    }

    /// In full screen the bar that slides down with the menu bar carries the
    /// titlebar's own lights, found even while the floating header still
    /// holds its own; the collapsed column hides them again on the way out.
    func testTheFullScreenBarShowsTheTitlebarsOwnLights() throws {
        let slot = try makeSlot()
        let panel = try showPanel(in: slot)
        _ = try trafficLights(in: panel)
        let window = try XCTUnwrap(slot.shell?.window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let own = try types.map { try XCTUnwrap(window.titlebarButton($0)) }
        let root = try XCTUnwrap(window.contentView)
        XCTAssertEqual(own.map(\.isHidden), [true, true, true], "precondition: the floating header has the lights")

        window.toggleFullScreen(nil)
        XCTAssertTrue(wait(until: { window.styleMask.contains(.fullScreen) }), "precondition: in full screen")
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(own.map(\.isHidden), [false, false, false], "the full-screen bar shows the titlebar's own")
        XCTAssertFalse(allLights(in: root).contains(where: \.isActive), "and the header holds none")
        // Asked while a header still holds its own, as when the header hears
        // of full screen after the titlebar has moved to the bar.
        let lingering = SidebarTrafficLightsView()
        root.addSubview(lingering)
        lingering.isActive = true
        XCTAssertTrue(window.titlebarButton(.closeButton) === own[0], "the titlebar's own, found in the bar")
        lingering.removeFromSuperview()

        window.toggleFullScreen(nil)
        XCTAssertTrue(wait(until: { !window.styleMask.contains(.fullScreen) }), "precondition: out of full screen")
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(own.map(\.isHidden), [true, true, true], "the collapsed column hides them again")
    }

    // MARK: - Helpers

    private func buttons(of lights: SidebarTrafficLightsView,
                         file: StaticString = #filePath,
                         line: UInt = #line) throws -> [NSButton] {
        let buttons = lights.subviews.compactMap { $0 as? NSButton }
        XCTAssertEqual(buttons.count, 3, file: file, line: line)
        return buttons
    }

    private func wait(until condition: () -> Bool, timeout: TimeInterval = 8) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    private func allLights(in view: NSView) -> [SidebarTrafficLightsView] {
        if let lights = view as? SidebarTrafficLightsView { return [lights] }
        return view.subviews.flatMap(allLights)
    }

    /// The visible view with `identifier` under `root`.
    private func view(identified identifier: String, in root: NSView) -> NSView? {
        if root.accessibilityIdentifier() == identifier, !root.isHiddenOrHasHiddenAncestor { return root }
        return root.subviews.lazy.compactMap { self.view(identified: identifier, in: $0) }.first
    }

    private func trafficLights(in panel: NSView,
                               file: StaticString = #filePath,
                               line: UInt = #line) throws -> SidebarTrafficLightsView {
        let lights = try XCTUnwrap(allLights(in: panel).first, "the panel's header has lights", file: file, line: line)
        XCTAssertTrue(lights.isActive, "precondition: the lights are in the header", file: file, line: line)
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
        // The collapsed state reaches the titlebar and the header a turn later.
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
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

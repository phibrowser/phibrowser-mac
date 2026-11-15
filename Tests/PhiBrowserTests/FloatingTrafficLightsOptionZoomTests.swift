// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

/// With the sidebar collapsed, the floating sidebar's header draws its own
/// traffic lights. Like the titlebar's, holding Option over them turns the
/// zoom light into a plus, and an Option-click zooms the window instead of
/// entering full screen.
@MainActor
final class FloatingTrafficLightsOptionZoomTests: XCTestCase {
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

    func testHoldingOptionOverTheLightsOffersZoom() throws {
        let slot = try makeSlot()
        let lights = try trafficLights(in: showPanel(in: slot))
        let window = try XCTUnwrap(lights.window)

        lights.mouseEntered(with: mouseEvent(.mouseMoved, at: .zero, in: window))
        XCTAssertFalse(lights.isOptionKeyHeld, "precondition: Option is not held")

        NSApp.sendEvent(flagsChanged([.option], in: window))
        XCTAssertTrue(lights.isOptionKeyHeld, "pressing Option over the lights offers zoom")

        NSApp.sendEvent(flagsChanged([], in: window))
        XCTAssertFalse(lights.isOptionKeyHeld, "releasing Option offers full screen again")

        NSApp.sendEvent(flagsChanged([.option], in: window))
        lights.mouseExited(with: mouseEvent(.mouseMoved, at: .zero, in: window))
        XCTAssertFalse(lights.isOptionKeyHeld, "leaving the lights drops the offer")

        NSApp.sendEvent(flagsChanged([], in: window))
        NSApp.sendEvent(flagsChanged([.option], in: window))
        XCTAssertFalse(lights.isOptionKeyHeld, "Option away from the lights changes nothing")
        NSApp.sendEvent(flagsChanged([], in: window))
    }

    func testOptionClickingTheZoomLightZoomsTheWindow() throws {
        let slot = try makeSlot()
        let lights = try trafficLights(in: showPanel(in: slot))
        let window = try XCTUnwrap(lights.window)
        let zoomLight = try XCTUnwrap(lights.subviews.compactMap { $0 as? NSStackView }.first?.arrangedSubviews.last)
        XCTAssertFalse(window.isZoomed, "precondition: the window is not zoomed")

        click(zoomLight, modifierFlags: .option)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        XCTAssertTrue(window.isZoomed, "an Option-click zooms the window")
        XCTAssertFalse(window.styleMask.contains(.fullScreen), "and does not enter full screen")
    }

    // MARK: - Spacing

    /// The drawn lights stand in for the titlebar's, so they keep its pitch:
    /// 23 pt on macOS 26, 20 pt on macOS 14 and 15.
    func testTheLightsAreSpacedLikeTheWindowsOwn() throws {
        let slot = try makeSlot()
        let lights = try trafficLights(in: showPanel(in: slot))
        let window = try XCTUnwrap(lights.window)
        let native = try [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].map { type in
            try XCTUnwrap(window.standardWindowButton(type)).frame.midX
        }
        let drawn = try dots(of: lights).map { $0.convert(NSPoint(x: $0.bounds.midX, y: 0), to: nil).x }

        XCTAssertEqual(drawn[1] - drawn[0], native[1] - native[0], accuracy: 0.5, "close to minimize")
        XCTAssertEqual(drawn[2] - drawn[1], native[2] - native[1], accuracy: 0.5, "minimize to zoom")
    }

    func testTheSidebarButtonKeepsItsGapAfterTheLights() throws {
        let slot = try makeSlot()
        let panel = try showPanel(in: slot)
        let zoomLight = try XCTUnwrap(dots(of: trafficLights(in: panel)).last)
        let button = try XCTUnwrap(view(identified: "sidebarHeader.sidebarButton", in: panel))

        let zoomMaxX = zoomLight.convert(zoomLight.bounds, to: nil).maxX
        XCTAssertEqual(button.convert(button.bounds, to: nil).minX, zoomMaxX + 10, accuracy: 0.5,
                       "10 pt after the zoom light")
    }

    // MARK: - Helpers

    private func dots(of lights: FloatingTrafficLightsView,
                      file: StaticString = #filePath,
                      line: UInt = #line) throws -> [NSView] {
        let dots = try XCTUnwrap(lights.subviews.compactMap { $0 as? NSStackView }.first?.arrangedSubviews,
                                 file: file, line: line)
        XCTAssertEqual(dots.count, 3, file: file, line: line)
        return dots
    }

    /// The visible view with `identifier` under `root`.
    private func view(identified identifier: String, in root: NSView) -> NSView? {
        if root.accessibilityIdentifier() == identifier, !root.isHiddenOrHasHiddenAncestor { return root }
        return root.subviews.lazy.compactMap { self.view(identified: identifier, in: $0) }.first
    }

    private func click(_ view: NSView, modifierFlags: NSEvent.ModifierFlags) {
        let window = view.window!
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: point, in: window, modifierFlags: modifierFlags))
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: point, in: window, modifierFlags: modifierFlags))
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow,
                            modifierFlags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifierFlags,
                           timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil,
                           eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func flagsChanged(_ flags: NSEvent.ModifierFlags, in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags,
                         timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: window.windowNumber, context: nil,
                         characters: "", charactersIgnoringModifiers: "",
                         isARepeat: false, keyCode: 58)!
    }

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

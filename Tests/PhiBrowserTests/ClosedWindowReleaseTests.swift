// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

/// A closed window releases what it held. The tests assert the outcome
/// through weak references, not how the release is arranged.
///
/// The test bodies are synchronous and wait by running the run loop. In an
/// `async` body, suspending between building the window and closing it kept
/// the shell window alive until the test returned, however it was closed.
@MainActor
final class ClosedWindowReleaseTests: XCTestCase {
    private var store: LocalStore!
    private var directory: URL!
    private var accountDirectory: URL!
    private var previousLayout: Any?
    private let manager = SpaceManager(observeAccountChanges: false)

    override func setUp() async throws {
        previousLayout = UserDefaults.standard.object(forKey: PhiPreferences.GeneralSettings.layoutModeKey)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let account = Account(userID: "closed-window-release-test-\(UUID().uuidString)")
        accountDirectory = account.userDataStorage
        store = LocalStore(account: account, storeDirectoryURL: directory, presentsCompatibilityAlerts: false)
        account.localStorage = store
    }

    override func tearDown() async throws {
        manager.discardSpacePrewarm()
        // Only a window the test failed to close is still registered here.
        for slot in manager.slots { slot.closeShellIfPresent() }
        // Drain queued UI reads before resetting their SwiftData context.
        let drained = expectation(description: "UI updates drained")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
        try await store.closeForAccountDirectoryRemoval()
        store = nil
        for url in [directory, accountDirectory].compactMap({ $0 })
        where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        UserDefaults.standard.set(previousLayout, forKey: PhiPreferences.GeneralSettings.layoutModeKey)
        try await super.tearDown()
    }

    func testClosedWindowReleasesEverythingItHeldInPerformanceLayout() {
        checkClosedWindowReleasesEverythingItHeld(in: .performance)
    }

    func testClosedWindowReleasesEverythingItHeldInBalancedLayout() {
        checkClosedWindowReleasesEverythingItHeld(in: .balanced)
    }

    func testClosedWindowReleasesEverythingItHeldInComfortableLayout() {
        checkClosedWindowReleasesEverythingItHeld(in: .comfortable)
    }

    func testSwitchingSpaceInAnOpenWindowReleasesNothingInPerformanceLayout() {
        checkSwitchingSpaceInAnOpenWindowReleasesNothing(in: .performance)
    }

    func testSwitchingSpaceInAnOpenWindowReleasesNothingInBalancedLayout() {
        checkSwitchingSpaceInAnOpenWindowReleasesNothing(in: .balanced)
    }

    func testSwitchingSpaceInAnOpenWindowReleasesNothingInComfortableLayout() {
        checkSwitchingSpaceInAnOpenWindowReleasesNothing(in: .comfortable)
    }

    private func checkClosedWindowReleasesEverythingItHeld(in layout: LayoutMode) {
        PhiPreferences.GeneralSettings.saveLayoutMode(layout)
        weak var shellWindow: NSWindow?
        weak var slot: SpaceWindowSlot?
        weak var spaceInstance: SpaceSessionController?
        weak var state: BrowserState?
        var chromiumWindows: [NSWindow] = []
        autoreleasepool {
            let newSlot = makeSlot()
            let first = makeSpaceInstance(in: newSlot, spaceId: "first", windowId: 123458001)
            present(first.instance, in: newSlot)
            shellWindow = newSlot.shell?.window
            slot = newSlot
            spaceInstance = first.instance
            state = first.instance.browserState
            chromiumWindows = [first.chromiumWindow]
        }
        // The window lives through a few turns before the user closes it.
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        autoreleasepool {
            XCTAssertNotNil(shellWindow)
            XCTAssertNotNil(slot)
            XCTAssertNotNil(spaceInstance)
            XCTAssertNotNil(state)
            close(shellWindow, chromiumWindows: &chromiumWindows)
        }

        // The state follows the window by about two seconds: the Sidebar
        // address bar holds it until its delayed extension refresh has run.
        for _ in 0..<50 where shellWindow != nil || slot != nil || spaceInstance != nil || state != nil {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertNil(shellWindow, "A closed window must not outlive its close")
        XCTAssertNil(slot, "A closed window's slot must go with it")
        XCTAssertNil(spaceInstance, "A closed window's Space instance must go with it")
        XCTAssertNil(state, "A closed window's window-scoped state must go with it")
    }

    private func checkSwitchingSpaceInAnOpenWindowReleasesNothing(in layout: LayoutMode) {
        PhiPreferences.GeneralSettings.saveLayoutMode(layout)
        weak var shellWindow: NSWindow?
        weak var slot: SpaceWindowSlot?
        weak var firstInstance: SpaceSessionController?
        weak var firstState: BrowserState?
        weak var secondInstance: SpaceSessionController?
        weak var secondState: BrowserState?
        var chromiumWindows: [NSWindow] = []
        autoreleasepool {
            let newSlot = makeSlot()
            let first = makeSpaceInstance(in: newSlot, spaceId: "first", windowId: 123458001)
            present(first.instance, in: newSlot)
            let second = makeSpaceInstance(in: newSlot, spaceId: "second", windowId: 123458002)
            shellWindow = newSlot.shell?.window
            slot = newSlot
            firstInstance = first.instance
            firstState = first.instance.browserState
            secondInstance = second.instance
            secondState = second.instance.browserState
            chromiumWindows = [first.chromiumWindow, second.chromiumWindow]
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        autoreleasepool {
            // The switch to the second Space and the switch back.
            firstInstance?.concealFromShell(removingView: false, deferringChromium: true)
            secondInstance?.presentInShell(completing: false, deferringChromium: true)
            secondInstance?.concealFromShell(removingView: false, deferringChromium: true)
            firstInstance?.presentInShell(completing: false, deferringChromium: true)
        }
        // Longer than a closed window's state takes to follow it.
        RunLoop.current.run(until: Date().addingTimeInterval(3))

        XCTAssertNotNil(shellWindow, "An open window must survive a Space switch")
        XCTAssertNotNil(slot, "An open window's slot must survive a Space switch")
        XCTAssertNotNil(firstInstance, "The Space instance switched back to must survive")
        XCTAssertNotNil(firstState, "The state of the Space switched back to must survive")
        XCTAssertNotNil(secondInstance, "The Space instance switched away from must survive")
        XCTAssertNotNil(secondState, "The state of the Space switched away from must survive")
        autoreleasepool {
            close(shellWindow, chromiumWindows: &chromiumWindows)
        }
    }

    /// A slot in the registry with its shell window.
    private func makeSlot() -> SpaceWindowSlot {
        let slot = manager.createSlot(initialSpaceId: "first")
        slot.ensureShell(initialFrame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        return slot
    }

    /// A Space instance in `slot`'s shell. `chromiumWindow` stands in for the
    /// hidden Chromium window whose close ends the instance. Chromium knows
    /// no Browser under the instance's window id, so the bridge calls made
    /// along the way return early.
    private func makeSpaceInstance(in slot: SpaceWindowSlot, spaceId: String, windowId: Int)
        -> (instance: SpaceSessionController, chromiumWindow: NSWindow) {
        let shell = slot.shell!
        let chromiumWindow = NSWindow(contentRect: shell.window.frame, styleMask: [.titled, .closable],
                                      backing: .buffered, defer: true)
        chromiumWindow.isReleasedWhenClosed = false
        let state = BrowserState(windowId: windowId, localStore: store, profileId: "Default", spaceId: spaceId)
        let instance = SpaceSessionController(window: shell.window, windowId: state.windowId,
            profileId: state.profileId, spaceId: state.spaceId, account: store.account,
            slot: slot, browserState: state, chromiumWindow: chromiumWindow)
        return (instance, chromiumWindow)
    }

    /// Shows `instance` in `slot`'s shell and lays its Sidebar out there.
    private func present(_ instance: SpaceSessionController, in slot: SpaceWindowSlot) {
        slot.presentRequestedSession(instance, activate: false)
        slot.shell?.split.setSidebarGeometry(width: 240, collapsed: false)
        slot.shell?.split.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(slot.visibleController === instance)
    }

    /// The user's close: the shell asks its Space instances to close, and
    /// Chromium answers by closing each instance's own window.
    private func close(_ shellWindow: NSWindow?, chromiumWindows: inout [NSWindow]) {
        shellWindow?.performClose(nil)
        chromiumWindows.forEach { $0.close() }
        chromiumWindows.removeAll()
    }
}

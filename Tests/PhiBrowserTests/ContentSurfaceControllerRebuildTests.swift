// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import XCTest
@testable import Phi

/// The content surface (chromium ADR 0014) is sent once per Space instance,
/// right after its window. When the Mac rebuilds the controller of a Space
/// instance, for a dangling window materialized after login or a window
/// rebound to another account, the new controller has to carry the surface
/// over, or the instance draws without one for the rest of its life.
///
/// The bridge push is faked by calling the coordinator's delegate method.
/// Chromium knows no Browser under these window ids, so the bridge calls
/// made along the way return early (as in `ClosedWindowReleaseTests`).
@MainActor
final class ContentSurfaceControllerRebuildTests: XCTestCase {
    private var store: LocalStore!
    private var directory: URL!
    private var accountDirectory: URL!
    private var otherStore: LocalStore?
    private var otherAccountDirectory: URL?
    private var previousLayout: Any?
    private let manager = SpaceManager(observeAccountChanges: false)
    private var chromiumWindows: [NSWindow] = []
    private var subscriptions = Set<AnyCancellable>()
    /// Dangling records this test added to the process-wide registry; a
    /// record processed one at a time is not removed by the registry.
    private var danglingWindowIds: [Int] = []
    // Counted across tests: the registry is the process-wide singleton, so
    // an id must not repeat within the host process.
    private static var nextWindowId = 123459101

    override func setUp() async throws {
        previousLayout = UserDefaults.standard.object(forKey: PhiPreferences.GeneralSettings.layoutModeKey)
        PhiPreferences.GeneralSettings.saveLayoutMode(.performance)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let account = Account(userID: "surface-rebuild-test-\(UUID().uuidString)")
        accountDirectory = account.userDataStorage
        store = LocalStore(account: account, storeDirectoryURL: directory, presentsCompatibilityAlerts: false)
        account.localStorage = store
        SpaceBandSnapshotCache.shared.accountForTesting = account
    }

    override func tearDown() async throws {
        SpaceBandSnapshotCache.shared.accountForTesting = nil
        subscriptions.removeAll()
        manager.discardSpacePrewarm()
        SpaceSessionControllersManager.shared.danglingWindows
            .removeAll { danglingWindowIds.contains($0.windowId) }
        danglingWindowIds.removeAll()
        for slot in manager.slots { slot.closeShellIfPresent() }
        chromiumWindows.forEach { $0.close() }
        chromiumWindows.removeAll()
        // Drain queued UI reads before resetting their SwiftData context.
        let drained = expectation(description: "UI updates drained")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
        try await store.closeForAccountDirectoryRemoval()
        store = nil
        try await otherStore?.closeForAccountDirectoryRemoval()
        otherStore = nil
        for url in [directory, accountDirectory, otherAccountDirectory].compactMap({ $0 })
        where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        UserDefaults.standard.set(previousLayout, forKey: PhiPreferences.GeneralSettings.layoutModeKey)
        try await super.tearDown()
    }

    func testMaterializedDanglingWindowAdoptsItsSurfaceBeforeReplayingPendingTabs() throws {
        let registry = SpaceSessionControllersManager.shared
        let slot = makeSlot()
        let windowId = Self.takeWindowId()
        let chromiumWindow = makeChromiumWindow(for: slot)
        registry.addDanglingWindow(chromiumWindow, windowId: windowId, browserType: .normal,
                                   profileId: "Default", spaceId: "first", slot: slot)
        danglingWindowIds.append(windowId)
        registry.addPendingTabToDanglingWindow(
            Tab(url: "https://example.com", isActive: true, index: 0), windowId: windowId)
        let hostingView = NSView()
        // Chromium sends the surface right after the window, before login.
        PhiChromiumCoordinator.shared.contentSurfaceCreated(Int64(windowId), hostingView: hostingView)
        let record = try XCTUnwrap(registry.danglingWindows.first { $0.windowId == windowId })
        XCTAssertTrue(record.contentSurfaceView === hostingView,
                      "A dangling window keeps the surface sent for it")

        // Login. The new Space instance must hold the surface before its first
        // replayed tab lands, so that tab mounts into a hosting container.
        var events: [String] = []
        var observations = Set<AnyCancellable>()
        NotificationCenter.default.publisher(for: .mainBrowserWindowCreated)
            .sink { _ in
                guard let state = registry.controller(for: windowId)?.browserState else { return }
                state.$contentSurfaceView.compactMap { $0 }.first()
                    .sink { _ in events.append("surface") }
                    .store(in: &observations)
                state.$tabs.filter { !$0.isEmpty }.first()
                    .sink { _ in events.append("tab") }
                    .store(in: &observations)
            }
            .store(in: &subscriptions)
        registry.processDanglingWindow(record, account: store.account, migrationReceipt: nil)

        let instance = try XCTUnwrap(registry.controller(for: windowId))
        XCTAssertTrue(instance.browserState.contentSurfaceView === hostingView)
        XCTAssertEqual(events, ["surface", "tab"])
        let container = instance.mainSplitViewController.webContentContainerViewController
        XCTAssertTrue(hostingView.isDescendant(of: container.view))
        XCTAssertTrue(container.hasContentSurface)
    }

    func testReboundWindowKeepsItsSurface() throws {
        let registry = SpaceSessionControllersManager.shared
        let slot = makeSlot()
        let windowId = Self.takeWindowId()
        let old = makeSpaceInstance(in: slot, spaceId: "first", windowId: windowId)
        present(old, in: slot)
        let hostingView = NSView()
        PhiChromiumCoordinator.shared.contentSurfaceCreated(Int64(windowId), hostingView: hostingView)
        let oldContainer = old.mainSplitViewController.webContentContainerViewController
        XCTAssertTrue(old.browserState.contentSurfaceView === hostingView)
        XCTAssertTrue(hostingView.isDescendant(of: oldContainer.view))

        // A Guest sign-in, or its rollback, rebuilds every Space instance
        // against the destination account. Chromium does not send the
        // surface again.
        registry.rebindWindowController(old, to: makeOtherAccount(), migrationReceipt: nil)

        let replacement = try XCTUnwrap(registry.controller(for: windowId))
        XCTAssertFalse(replacement === old)
        XCTAssertTrue(replacement.browserState.contentSurfaceView === hostingView)
        let container = replacement.mainSplitViewController.webContentContainerViewController
        XCTAssertTrue(hostingView.isDescendant(of: container.view))
        XCTAssertTrue(container.hasContentSurface)
        XCTAssertFalse(hostingView.isDescendant(of: oldContainer.view))
    }

    func testWindowCreatedWithBrowserAccessAdoptsItsSurfaceDirectly() throws {
        let registry = SpaceSessionControllersManager.shared
        let slot = makeSlot()
        let windowId = Self.takeWindowId()
        let instance = makeSpaceInstance(in: slot, spaceId: "first", windowId: windowId)
        present(instance, in: slot)
        let hostingView = NSView()
        PhiChromiumCoordinator.shared.contentSurfaceCreated(Int64(windowId), hostingView: hostingView)
        XCTAssertTrue(instance.browserState.contentSurfaceView === hostingView)
        XCTAssertFalse(registry.hasDanglingWindow(for: windowId))
        let container = instance.mainSplitViewController.webContentContainerViewController
        XCTAssertTrue(hostingView.isDescendant(of: container.view))
        XCTAssertTrue(container.hasContentSurface)
    }

    private static func takeWindowId() -> Int {
        nextWindowId += 1
        return nextWindowId
    }

    /// A slot in the registry with its shell window.
    private func makeSlot() -> SpaceWindowSlot {
        let slot = manager.createSlot(initialSpaceId: "first")
        slot.ensureShell(initialFrame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        return slot
    }

    /// Stands in for the hidden Chromium window whose close ends a Space
    /// instance; closed in `tearDown`.
    private func makeChromiumWindow(for slot: SpaceWindowSlot) -> NSWindow {
        let window = NSWindow(contentRect: slot.shell!.window.frame, styleMask: [.titled, .closable],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        chromiumWindows.append(window)
        return window
    }

    /// A live Space instance in `slot`'s shell, as `mainBrowserWindowCreated`
    /// builds one with browser access.
    private func makeSpaceInstance(in slot: SpaceWindowSlot, spaceId: String,
                                   windowId: Int) -> SpaceSessionController {
        let chromiumWindow = makeChromiumWindow(for: slot)
        let state = BrowserState(windowId: windowId, localStore: store, profileId: "Default", spaceId: spaceId)
        return SpaceSessionController(window: slot.shell!.window, windowId: windowId,
            profileId: state.profileId, spaceId: state.spaceId, account: store.account,
            slot: slot, browserState: state, chromiumWindow: chromiumWindow)
    }

    /// Shows `instance` in `slot`'s shell and lays its tree out there.
    private func present(_ instance: SpaceSessionController, in slot: SpaceWindowSlot) {
        slot.presentRequestedSession(instance, activate: false)
        slot.shell?.split.setSidebarGeometry(width: 240, collapsed: false)
        slot.shell?.split.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(slot.visibleController === instance)
    }

    /// The account a rebind moves the window to, with its own store.
    private func makeOtherAccount() -> Account {
        let account = Account(userID: "surface-rebuild-other-\(UUID().uuidString)")
        let other = LocalStore(account: account,
                               storeDirectoryURL: directory.appendingPathComponent("other-store"),
                               presentsCompatibilityAlerts: false)
        account.localStorage = other
        otherStore = other
        otherAccountDirectory = account.userDataStorage
        return account
    }
}

// Copyright 2026 Phinomenon Inc.
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SwiftData
import XCTest
@testable import Phi

/// The pairing reset's window handling on real slots: the `default-space`
/// rebind's retry of a replacement that never registered, and the deletion's
/// abandon check ahead of any window close. The test host has no Chromium
/// bridge, so every spawn fails; a dormant session stands in for a Browser
/// that can be spawned, and attaching a plain window to it stands in for the
/// Browser's arrival.
@MainActor
final class SpacePairingResetWindowTests: XCTestCase {
    private var account: Account!
    private var directory: URL!
    private var manager: SpaceManager!
    private var slots: [SpaceWindowSlot] = []
    private var chromiumWindows: [NSWindow] = []
    private var previousLayout: Any?
    private var previousBoundAccount: Any?
    private var nextWindowId = 123458000

    override func setUp() async throws {
        previousLayout = UserDefaults.standard.object(forKey: PhiPreferences.GeneralSettings.layoutModeKey)
        previousBoundAccount = UserDefaults.standard.object(forKey: SpaceManager.lastBoundAccountUserIDKey)
        PhiPreferences.GeneralSettings.saveLayoutMode(.performance)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        account = Account(userID: "space-pairing-reset-window-test-\(UUID().uuidString)")
        account.localStorage = LocalStore(account: account, storeDirectoryURL: directory,
                                          presentsCompatibilityAlerts: false)
        let context = try XCTUnwrap(account.localStorage.getMainContext())
        for (index, id) in [LocalStore.defaultSpaceId, "second"].enumerated() {
            context.insert(SpaceModel(spaceId: id, profileId: "Default", name: id,
                                      colorHex: "#123456", iconName: "circle", sortOrder: index))
        }
        try context.save()
        manager = SpaceManager(observeAccountChanges: false)
        manager.bind(to: account)
        await drain()
    }

    override func tearDown() async throws {
        manager.discardSpacePrewarm()
        for slot in slots { slot.closeShellIfPresent() }
        slots.removeAll()
        chromiumWindows.forEach { $0.close() }
        chromiumWindows.removeAll()
        await drain()
        manager = nil
        try await account.localStorage.closeForAccountDirectoryRemoval()
        for url in [directory, account.userDataStorage].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }
        account = nil
        UserDefaults.standard.set(previousLayout, forKey: PhiPreferences.GeneralSettings.layoutModeKey)
        UserDefaults.standard.set(previousBoundAccount, forKey: SpaceManager.lastBoundAccountUserIDKey)
    }

    // MARK: - Rebind retry

    func testRebindRetriesAReplacementThatNeverRegistered() async throws {
        let spaceId = LocalStore.defaultSpaceId
        let slot = makeShellSlot(showing: spaceId)
        let old = makeSession(in: slot, spaceId: spaceId, profileId: "Doomed")
        attachChromiumWindow(to: old)
        slot.presentRequestedSession(old, activate: false)
        XCTAssertEqual(slot.activeSpaceId, spaceId)
        XCTAssertTrue(liveWindows().contains { $0 === old })

        // The replacement's cold spawn fails (no bridge): the old window has left the index, is
        // still live on the doomed Profile, and waits for a replacement that never comes.
        let first = await manager.settleDefaultSpaceWindowsForPairingReset(onProfileId: "Default",
                                                                          timeout: .milliseconds(500))
        XCTAssertFalse(first)
        XCTAssertNil(slot.windowController(for: spaceId))
        XCTAssertTrue(slot.hasPendingReplacement(for: spaceId))
        XCTAssertEqual(slot.activeSpaceId, spaceId)
        XCTAssertTrue(liveWindows().contains { $0 === old })

        // A Browser can be spawned now. The retry must activate the Space again: only that
        // presents the stand-in, and only the stand-in's arrival closes the old window.
        let replacement = makeSession(in: slot, spaceId: spaceId, profileId: "Default")
        let retry = Task { @MainActor [manager] in
            await manager!.settleDefaultSpaceWindowsForPairingReset(onProfileId: "Default", timeout: .seconds(5))
        }
        let presented = await waitUntil { slot.visibleController === replacement }
        XCTAssertTrue(presented, "the retry did not activate the Space again")
        attachChromiumWindow(to: replacement)
        let second = await retry.value
        XCTAssertTrue(second)
        XCTAssertTrue(slot.windowController(for: spaceId) === replacement)
        XCTAssertEqual(slot.windowController(for: spaceId)?.profileId, "Default")
        XCTAssertFalse(slot.hasPendingReplacement(for: spaceId))
        XCTAssertFalse(liveWindows().contains { $0 === old })
    }

    // MARK: - Deletion abandon

    func testCloseRefusedBeforeEvictionLeavesWindowsAndRow() async throws {
        let slot = try makeSlot(showing: "second")
        let background = try makeSlot(showing: LocalStore.defaultSpaceId, target: "second")
        let settled = expectation(description: "Close settled")
        var closed: Bool?
        var asked = false
        manager.closeSpaceWindows(spaceId: "second", animated: false,
                                  retreatTargetSpaceId: LocalStore.defaultSpaceId,
                                  proceed: { asked = true; return false }) { succeeded in
            closed = succeeded
            settled.fulfill()
        }
        await fulfillment(of: [settled], timeout: 5)
        XCTAssertTrue(asked)
        XCTAssertEqual(closed, false)
        // The retreat itself ran; nothing of the Space was evicted or closed.
        XCTAssertEqual(slot.visibleController?.spaceId, LocalStore.defaultSpaceId)
        XCTAssertNotNil(slot.windowController(for: "second"))
        XCTAssertNotNil(background.windowController(for: "second"))
        XCTAssertTrue(account.localStorage.getAllSpaces().contains { $0.spaceId == "second" })
    }

    func testPairingResetDeletionStillDeletesWhenTheCommitIsClaimed() async throws {
        let slot = try makeSlot(showing: "second")
        let result = await manager.deleteSpaceForPairingReset(spaceId: "second", timeout: .seconds(5))
        XCTAssertEqual(result, .deleted)
        XCTAssertEqual(slot.visibleController?.spaceId, LocalStore.defaultSpaceId)
        XCTAssertNil(slot.windowController(for: "second"))
        XCTAssertFalse(manager.pendingDeletionSpaceIds.contains("second"))
        XCTAssertFalse(account.localStorage.getAllSpaces().contains { $0.spaceId == "second" })
    }

    // MARK: - Helpers

    private func liveWindows() -> [SpaceSessionController] {
        SpaceSessionControllersManager.shared.getAllWindows()
    }

    private func makeShellSlot(showing spaceId: String) -> SpaceWindowSlot {
        let slot = manager.createSlot(initialSpaceId: spaceId)
        slots.append(slot)
        slot.ensureShell(initialFrame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        return slot
    }

    /// A dormant session of `spaceId` on `profileId` in `slot`'s shell, queued in the slot's
    /// dormant map (as a pre-built Space is) and not registered as a window.
    private func makeSession(in slot: SpaceWindowSlot, spaceId: String, profileId: String) -> SpaceSessionController {
        nextWindowId += 1
        let state = BrowserState(windowId: nextWindowId, localStore: account.localStorage,
                                 profileId: profileId, spaceId: spaceId)
        state.tabs = [Tab(guid: nextWindowId, url: "https://example.test", isActive: true,
                          index: 0, title: spaceId)]
        state.updateNormalTabs()
        return SpaceSessionController(window: slot.shell!.window, windowId: nextWindowId,
            profileId: profileId, spaceId: spaceId, account: account, slot: slot,
            browserState: state, dormant: true)
    }

    /// Stands in for the hidden window of the Browser Chromium spawns for `session`: the session
    /// goes live and registers with its slot.
    private func attachChromiumWindow(to session: SpaceSessionController) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        chromiumWindows.append(window)
        session.attachChromiumWindow(window)
    }

    private func makeSlot(showing source: String, target: String = LocalStore.defaultSpaceId) throws -> SpaceWindowSlot {
        let slot = makeShellSlot(showing: source)
        for id in [source, target] {
            let session = makeSession(in: slot, spaceId: id, profileId: "Default")
            slot.registerWindow(session, for: id)
            if id == source { slot.presentRequestedSession(session, activate: false) }
        }
        let split = try XCTUnwrap(slot.shell?.split)
        split.setSidebarGeometry(width: 240, collapsed: false)
        split.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(slot.visibleController?.spaceId, source)
        return slot
    }

    private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    private func drain() async {
        let drained = expectation(description: "Drain UI updates")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
    }
}

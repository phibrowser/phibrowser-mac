// Copyright 2026 Phinomenon Inc.
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import SwiftData
import XCTest
@testable import Phi

@MainActor
final class SpaceDeletionTests: XCTestCase {
    private var account: Account!
    private var directory: URL!
    private var manager: SpaceManager!
    private var slots: [SpaceWindowSlot] = []
    private var subscriptions = Set<AnyCancellable>()
    private var previousLayout: Any?
    private var previousBoundAccount: Any?
    private var nextWindowId = 123457000

    override func setUp() async throws {
        previousLayout = UserDefaults.standard.object(forKey: PhiPreferences.GeneralSettings.layoutModeKey)
        previousBoundAccount = UserDefaults.standard.object(forKey: SpaceManager.lastBoundAccountUserIDKey)
        PhiPreferences.GeneralSettings.saveLayoutMode(.performance)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        account = Account(userID: "space-deletion-test-\(UUID().uuidString)")
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
        subscriptions.removeAll()
        manager.discardSpacePrewarm()
        for slot in slots { slot.closeShellIfPresent() }
        slots.removeAll()
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

    func testRegularDeletionHidesPipButRetainsDataUntilEveryWindowSettles() async throws {
        let first = try makeSlot(showing: "second")
        let second = try makeSlot(showing: "second")
        let deleted = expectation(description: "Space deleted after both retreats")
        manager.$spaces.filter { !$0.contains(where: { $0.spaceId == "second" }) }.prefix(1)
            .sink { _ in deleted.fulfill() }.store(in: &subscriptions)

        manager.deleteSpace(spaceId: "second")
        XCTAssertTrue(manager.pendingDeletionSpaceIds.contains("second"))
        XCTAssertFalse(first.presentedSpaces.contains { $0.spaceId == "second" })
        XCTAssertTrue(manager.spaces.contains { $0.spaceId == "second" })
        XCTAssertTrue(account.localStorage.getAllSpaces().contains { $0.spaceId == "second" })
        XCTAssertNotNil(first.windowController(for: "second"))
        XCTAssertNotNil(second.windowController(for: "second"))
        // A second delete cannot retire the last surviving regular Space.
        manager.deleteSpace(spaceId: LocalStore.defaultSpaceId)
        XCTAssertFalse(manager.pendingDeletionSpaceIds.contains(LocalStore.defaultSpaceId))

        await fulfillment(of: [deleted], timeout: 5)
        for slot in [first, second] {
            XCTAssertEqual(slot.visibleController?.spaceId, LocalStore.defaultSpaceId)
            XCTAssertNil(slot.windowController(for: "second"))
        }
        XCTAssertFalse(account.localStorage.getAllSpaces().contains { $0.spaceId == "second" })
    }

    func testIncognitoDescriptorSurvivesUntilRetreatCompletes() async throws {
        let id = manager.createIncognitoSpace()
        let slot = try makeSlot(showing: id)
        let deleted = expectation(description: "Incognito descriptor removed after retreat")
        manager.$spaces.filter { !$0.contains(where: { $0.spaceId == id }) }.prefix(1)
            .sink { _ in deleted.fulfill() }.store(in: &subscriptions)
        manager.closeIncognitoSpace(spaceId: id)
        XCTAssertTrue(manager.pendingDeletionSpaceIds.contains(id))
        XCTAssertFalse(slot.presentedSpaces.contains { $0.spaceId == id })
        XCTAssertTrue(manager.spaces.contains { $0.spaceId == id })
        XCTAssertNotNil(slot.windowController(for: id))
        // Repeated close requests must not settle or restart the first retreat.
        manager.closeIncognitoSpace(spaceId: id)
        XCTAssertNotNil(slot.windowController(for: id))
        await fulfillment(of: [deleted], timeout: 5)
        XCTAssertEqual(slot.visibleController?.spaceId, LocalStore.defaultSpaceId)
        XCTAssertNil(slot.windowController(for: id))
        XCTAssertFalse(manager.pendingDeletionSpaceIds.contains(id))
    }

    func testFailedRetreatRestoresPipAndPreservesSpace() async throws {
        let slot = manager.createSlot(initialSpaceId: "second")
        slots.append(slot)
        // No live replacement and no Chromium bridge: cold activation fails.
        let restored = expectation(description: "Failed retreat restores presentation")
        manager.$pendingDeletionSpaceIds.dropFirst().filter { $0.isEmpty }.prefix(1)
            .sink { _ in restored.fulfill() }.store(in: &subscriptions)
        manager.deleteSpace(spaceId: "second")
        XCTAssertTrue(manager.pendingDeletionSpaceIds.contains("second"))
        await fulfillment(of: [restored], timeout: 5)
        XCTAssertTrue(slot.presentedSpaces.contains { $0.spaceId == "second" })
        XCTAssertTrue(account.localStorage.getAllSpaces().contains { $0.spaceId == "second" })
    }

    func testDeletingDefaultRetreatsBeforeHandingOffDefaultRole() async throws {
        let slot = try makeSlot(showing: LocalStore.defaultSpaceId, target: "second")
        let deleted = expectation(description: "Default deleted")
        manager.$spaces.filter { !$0.contains(where: { $0.spaceId == LocalStore.defaultSpaceId }) }.prefix(1)
            .sink { _ in deleted.fulfill() }.store(in: &subscriptions)
        manager.deleteSpace(spaceId: LocalStore.defaultSpaceId)
        XCTAssertNotNil(slot.windowController(for: LocalStore.defaultSpaceId))
        await fulfillment(of: [deleted], timeout: 5)
        XCTAssertEqual(slot.visibleController?.spaceId, "second")
        XCTAssertEqual(manager.currentDefaultSpaceId, "second")
    }

    func testWindowlessIncognitoClosesImmediately() {
        let id = manager.createIncognitoSpace()
        manager.closeIncognitoSpace(spaceId: id)
        XCTAssertFalse(manager.spaces.contains { $0.spaceId == id })
        XCTAssertTrue(manager.pendingDeletionSpaceIds.isEmpty)
    }

    private func makeSlot(showing source: String, target: String = LocalStore.defaultSpaceId) throws -> SpaceWindowSlot {
        let slot = manager.createSlot(initialSpaceId: source)
        slots.append(slot)
        slot.ensureShell(initialFrame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        for id in [source, target] {
            nextWindowId += 1
            let state = BrowserState(windowId: nextWindowId, localStore: account.localStorage,
                                     profileId: "Default", spaceId: id)
            state.tabs = [Tab(guid: nextWindowId, url: "https://example.test", isActive: true,
                              index: 0, title: id)]
            state.updateNormalTabs()
            let session = SpaceSessionController(window: slot.shell!.window, windowId: nextWindowId,
                profileId: state.profileId, spaceId: id, account: account, slot: slot,
                browserState: state, dormant: true)
            slot.registerWindow(session, for: id)
            if id == source { slot.presentRequestedSession(session, activate: false) }
        }
        let split = try XCTUnwrap(slot.shell?.split)
        split.setSidebarGeometry(width: 240, collapsed: false)
        split.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(slot.visibleController?.spaceId, source)
        return slot
    }

    private func drain() async {
        let drained = expectation(description: "Drain UI updates")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
    }
}

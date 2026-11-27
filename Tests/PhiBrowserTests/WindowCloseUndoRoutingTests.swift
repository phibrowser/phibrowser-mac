// Copyright 2026 Phinomenon Inc.
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import ObjectiveC
import SwiftData
import XCTest
@testable import Phi

/// Records the window-close calls a slot makes over the bridge, in order, and
/// forwards everything else to the live bridge. The closes are recorded, not
/// forwarded: the window ids are fake.
private final class WindowCloseBridgeStub: NSObject {
    enum Call: Hashable {
        case closeRecord(windowIds: [Int], front: Int)
        case clearCloseRecord(windowIds: [Int])
        case closeWindow(Int)
    }

    var calls: [Call] = []
    var forwardingBridge: PhiChromiumBridgeProtocol?

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || forwardingBridge?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? { forwardingBridge }

    @objc(setWindowCloseId:forWindowIds:frontWindowId:)
    func setWindowCloseId(_ closeId: String, forWindowIds windowIds: [NSNumber], frontWindowId: Int64) {
        let ids = windowIds.map(\.intValue).sorted()
        calls.append(closeId.isEmpty ? .clearCloseRecord(windowIds: ids)
                                     : .closeRecord(windowIds: ids, front: Int(frontWindowId)))
    }

    /// Every window stays open: the cascade reads as vetoed.
    @objc(windowCloseStateForWindowId:)
    func windowCloseState(forWindowId windowId: Int64) -> PhiWindowCloseState {
        .notAttempting
    }

    @objc(executeCommand:windowId:)
    func executeCommand(_ commandId: Int32, windowId: Int64) {
        if commandId == Int32(CommandWrapper.IDC_CLOSE_WINDOW.rawValue) {
            calls.append(.closeWindow(Int(windowId)))
        }
    }
}

/// Undo Close of a Window that closed as a whole (ADR 0013), Mac half: the
/// close record goes out before the cascade's first close, and the windows
/// Chromium brings back under one close id land in one Window, the front one
/// presented, until the set settles.
@MainActor
final class WindowCloseUndoRoutingTests: XCTestCase {
    private var account: Account!
    private var directory: URL!
    private var manager: SpaceManager!
    private var originalBridge: PhiChromiumBridgeProtocol?
    private var previousLayout: Any?
    private var nextWindowId = 123458000
    private let second = "second"

    override func setUp() async throws {
        originalBridge = ChromiumLauncher.sharedInstance().bridge
        previousLayout = UserDefaults.standard.object(forKey: PhiPreferences.GeneralSettings.layoutModeKey)
        PhiPreferences.GeneralSettings.saveLayoutMode(.performance)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        account = Account(userID: "window-close-undo-test-\(UUID().uuidString)")
        account.localStorage = LocalStore(account: account, storeDirectoryURL: directory,
                                          presentsCompatibilityAlerts: false)
        let context = try XCTUnwrap(account.localStorage.getMainContext())
        for (index, id) in [LocalStore.defaultSpaceId, second].enumerated() {
            context.insert(SpaceModel(spaceId: id, profileId: "Default", name: id,
                                      colorHex: "#123456", iconName: "circle", sortOrder: index))
        }
        try context.save()
        manager = SpaceManager(observeAccountChanges: false)
        manager.bind(to: account)
        await drain()
    }

    override func tearDown() async throws {
        ChromiumLauncher.sharedInstance().bridge = originalBridge
        manager.discardSpacePrewarm()
        for slot in manager.slots { slot.closeShellIfPresent() }
        await drain()
        manager = nil
        try await account.localStorage.closeForAccountDirectoryRemoval()
        for url in [directory, account.userDataStorage].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }
        account = nil
        UserDefaults.standard.set(previousLayout, forKey: PhiPreferences.GeneralSettings.layoutModeKey)
    }

    // MARK: - Routing

    func testMembersOfOneWindowCloseShareTheSlotTheFirstMinted() {
        let front = manager.slotForTabRestoredWindow(spaceId: LocalStore.defaultSpaceId, windowCloseId: "close-1")
        let sibling = manager.slotForTabRestoredWindow(spaceId: second, windowCloseId: "close-1")

        XCTAssertTrue(front === sibling)
        XCTAssertEqual(front.activeSpaceId, LocalStore.defaultSpaceId)
        XCTAssertEqual(manager.slots.count, 1)
    }

    func testAnotherWindowCloseGetsItsOwnSlot() {
        let first = manager.slotForTabRestoredWindow(spaceId: LocalStore.defaultSpaceId, windowCloseId: "close-1")
        let other = manager.slotForTabRestoredWindow(spaceId: second, windowCloseId: "close-2")

        XCTAssertFalse(first === other)
    }

    func testSettledEndsRouting() {
        let before = manager.slotForTabRestoredWindow(spaceId: LocalStore.defaultSpaceId, windowCloseId: "close-1")
        manager.windowCloseSetDidSettle("close-1")
        let after = manager.slotForTabRestoredWindow(spaceId: second, windowCloseId: "close-1")

        XCTAssertFalse(before === after)
    }

    func testARemovedSlotIsNotJoined() {
        let gone = manager.slotForTabRestoredWindow(spaceId: LocalStore.defaultSpaceId, windowCloseId: "close-1")
        manager.removeSlot(gone)
        let late = manager.slotForTabRestoredWindow(spaceId: second, windowCloseId: "close-1")

        XCTAssertFalse(gone === late)
        XCTAssertEqual(manager.slots.count, 1)
    }

    func testAWindowWithoutACloseIdOpensItsOwnWindowOnItsSpace() {
        let first = manager.slotForTabRestoredWindow(spaceId: LocalStore.defaultSpaceId, windowCloseId: nil)
        let other = manager.slotForTabRestoredWindow(spaceId: second, windowCloseId: nil)

        XCTAssertFalse(first === other)
        XCTAssertEqual(other.activeSpaceId, second)
    }

    func testFrontMemberIsPresentedAndSiblingStaysHidden() throws {
        let slot = manager.slotForTabRestoredWindow(spaceId: LocalStore.defaultSpaceId, windowCloseId: "close-1")
        slot.ensureShell(initialFrame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        let front = arrive(in: slot, spaceId: LocalStore.defaultSpaceId)
        XCTAssertTrue(manager.slotForTabRestoredWindow(spaceId: second, windowCloseId: "close-1") === slot)
        let sibling = arrive(in: slot, spaceId: second)

        // Chromium shows every window it restores; the sibling's show is not
        // the user switching to it.
        slot.presentRequestedSession(sibling, activate: true)

        XCTAssertTrue(slot.visibleController === front)
        XCTAssertTrue(slot.windowController(for: second) === sibling)
    }

    // MARK: - Close record

    func testCloseRecordIsSentBeforeTheCascadesFirstClose() throws {
        let bridge = try installBridge()
        let slot = manager.createSlot(initialSpaceId: LocalStore.defaultSpaceId)
        slot.ensureShell(initialFrame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        let front = arrive(in: slot, spaceId: LocalStore.defaultSpaceId)
        let sibling = arrive(in: slot, spaceId: second)
        slot.presentRequestedSession(front, activate: false)
        XCTAssertTrue(slot.visibleController === front)

        XCTAssertFalse(slot.shellRequestedClose())

        XCTAssertEqual(bridge.calls.first,
                       .closeRecord(windowIds: [front.windowId, sibling.windowId].sorted(), front: front.windowId))
        XCTAssertEqual(Set(bridge.calls.dropFirst()),
                       [.closeWindow(front.windowId), .closeWindow(sibling.windowId)])
        XCTAssertEqual(bridge.calls.count, 3)
    }

    func testAVetoedCascadeTakesTheCloseRecordBack() async throws {
        let bridge = try installBridge()
        let slot = manager.createSlot(initialSpaceId: LocalStore.defaultSpaceId)
        slot.ensureShell(initialFrame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        let front = arrive(in: slot, spaceId: LocalStore.defaultSpaceId)
        let sibling = arrive(in: slot, spaceId: second)
        let ids = [front.windowId, sibling.windowId].sorted()

        XCTAssertFalse(slot.shellRequestedClose())
        // No window closed: the veto recovery runs at its first deadline.
        try await Task.sleep(for: .seconds(2.5))

        XCTAssertEqual(bridge.calls.last, .clearCloseRecord(windowIds: ids))
    }

    // MARK: - Helpers

    /// A window Chromium re-created for `spaceId` registering with `slot`, as
    /// the coordinator registers a member of a window close: siblings of the
    /// Space the slot opened on are marked for concealment first.
    @discardableResult
    private func arrive(in slot: SpaceWindowSlot, spaceId: String) -> SpaceSessionController {
        if SpaceWindowSlot.concealsRestoredSibling(isRestoredWindow: true,
                                                   slotActiveSpaceId: slot.activeSpaceId,
                                                   windowSpaceId: spaceId) {
            slot.markRestoredSiblingForConcealment(spaceId: spaceId)
        }
        nextWindowId += 1
        let state = BrowserState(windowId: nextWindowId, localStore: account.localStorage,
                                 profileId: "Default", spaceId: spaceId)
        state.tabs = [Tab(guid: nextWindowId, url: "https://example.test", isActive: true,
                          index: 0, title: spaceId)]
        state.updateNormalTabs()
        let session = SpaceSessionController(window: slot.shell!.window, windowId: nextWindowId,
            profileId: state.profileId, spaceId: spaceId, account: account, slot: slot,
            browserState: state, dormant: true)
        slot.registerWindow(session, for: spaceId)
        return session
    }

    private func installBridge() throws -> WindowCloseBridgeStub {
        let bridge = WindowCloseBridgeStub()
        bridge.forwardingBridge = originalBridge
        let bridgeProtocol = try XCTUnwrap(objc_getProtocol("PhiChromiumBridgeProtocol"))
        class_addProtocol(WindowCloseBridgeStub.self, bridgeProtocol)
        ChromiumLauncher.sharedInstance().bridge = try XCTUnwrap(bridge as? PhiChromiumBridgeProtocol)
        return bridge
    }

    private func drain() async {
        let drained = expectation(description: "Drain UI updates")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
    }
}

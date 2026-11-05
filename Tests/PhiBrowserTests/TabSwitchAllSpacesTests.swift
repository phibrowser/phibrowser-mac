// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

/// The Tab Switcher with "Tab Switcher includes all Spaces" on: a step goes
/// through `handleStep` in a real shell with several Spaces, and committing
/// to a tab in another Space switches the shell to that Space.
@MainActor
final class TabSwitchAllSpacesTests: XCTestCase {
    private var store: LocalStore!
    private var directory: URL!
    private var accountDirectory: URL!
    private var previousLayout: Any?
    private var previousAllSpaces: Any?
    private var slots: [SpaceWindowSlot] = []
    private var sessions: [SpaceSessionController] = []
    private let manager = SpaceManager(observeAccountChanges: false)
    private var nextWindowId = 223457789
    /// Held here: a wrapper's `nativeView` is weak.
    private var webViews: [NSView] = []
    private var wrappers: [Int: PageColorTestWebContentWrapper] = [:]

    private let allSpacesKey = PhiPreferences.GeneralSettings.tabSwitcherIncludesAllSpaces.rawValue

    override func setUp() async throws {
        previousLayout = UserDefaults.standard.object(forKey: PhiPreferences.GeneralSettings.layoutModeKey)
        previousAllSpaces = UserDefaults.standard.object(forKey: allSpacesKey)
        PhiPreferences.GeneralSettings.saveLayoutMode(.performance)
        UserDefaults.standard.set(true, forKey: allSpacesKey)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let account = Account(userID: "tab-switch-all-spaces-test-\(UUID().uuidString)")
        accountDirectory = account.userDataStorage
        store = LocalStore(account: account, storeDirectoryURL: directory, presentsCompatibilityAlerts: false)
        account.localStorage = store
        // A switch goes only to a Space the manager knows.
        let context = try XCTUnwrap(store.getMainContext())
        context.insert(ProfileModel(profileId: LocalStore.defaultProfileId))
        for (index, spaceId) in ["a", "b"].enumerated() {
            context.insert(SpaceModel(spaceId: spaceId, profileId: LocalStore.defaultProfileId,
                name: spaceId, colorHex: "#AAAAAA", iconName: "target", sortOrder: index))
        }
        try context.save()
        manager.bind(to: store.account)
        await drainMainQueue()
    }

    override func tearDown() async throws {
        for session in sessions { session.browserState.tabSwitchManager.cancelSession() }
        sessions.removeAll()
        manager.discardSpacePrewarm()
        for slot in slots { slot.closeShellIfPresent() }
        slots.removeAll()
        webViews.removeAll()
        wrappers.removeAll()
        await drainMainQueue()
        try await store.closeForAccountDirectoryRemoval()
        store = nil
        for url in [directory, accountDirectory].compactMap({ $0 })
        where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        UserDefaults.standard.set(previousLayout, forKey: PhiPreferences.GeneralSettings.layoutModeKey)
        UserDefaults.standard.set(previousAllSpaces, forKey: allSpacesKey)
        try await super.tearDown()
    }

    /// The review's scenario: a1, a2 in Space A, b1 in Space B. After
    /// switching to B, one step goes back to a2; from there the next step
    /// goes to b1, not a1.
    func testStepsFollowRecencyAcrossSpaceSwitches() async throws {
        let (slot, a, b) = try makeSlot(tabsBySpace: [("a", [101, 102]), ("b", [201])])
        // a1 and a2 are used after b1, so only leaving B can make b1 newer than a1.
        for id in [101, 102] { a.browserState.focuseTab(try XCTUnwrap(a.browserState.tabs.first { $0.guid == id })) }
        slot.activate(spaceId: "b", animated: false)
        XCTAssertTrue(slot.visibleController === b, "precondition: Space B is presented")

        let a1Before = activations(101)
        let a2Before = activations(102)
        b.browserState.tabSwitchManager.handleStep(.forward, initiatingKey: nil)
        await waitUntil { slot.visibleController === a }
        XCTAssertTrue(slot.visibleController === a, "the step from B switches back to A")
        await waitUntil { self.activations(102) > a2Before }
        XCTAssertGreaterThan(activations(102), a2Before, "a2, A's last focused tab, is activated")

        let b1Before = activations(201)
        a.browserState.tabSwitchManager.handleStep(.forward, initiatingKey: nil)
        await waitUntil { slot.visibleController === b }
        XCTAssertTrue(slot.visibleController === b, "the next step goes to b1, the more recent tab")
        await waitUntil { self.activations(201) > b1Before }
        XCTAssertGreaterThan(activations(201), b1Before)
        XCTAssertEqual(activations(101), a1Before, "a1 is older than both and is never picked")
    }

    /// From an empty Space, the first step lands on the newest tab in
    /// another Space rather than skipping it.
    func testStepFromEmptySpaceGoesToNewestTabElsewhere() async throws {
        let (slot, a, b) = try makeSlot(tabsBySpace: [("a", [101, 102]), ("b", [])])
        slot.activate(spaceId: "b", animated: false)
        XCTAssertNil(b.browserState.focusingTab, "precondition: Space B is empty")

        let a2Before = activations(102)
        b.browserState.tabSwitchManager.handleStep(.forward, initiatingKey: nil)
        await waitUntil { slot.visibleController === a }
        XCTAssertTrue(slot.visibleController === a)
        await waitUntil { self.activations(102) > a2Before }
        XCTAssertGreaterThan(activations(102), a2Before, "a2 is the newest tab and is not skipped")
    }

    /// With the setting off, nothing changes: an empty Space has nothing to
    /// switch to.
    func testSettingOffKeepsStepsInTheCurrentSpace() async throws {
        UserDefaults.standard.set(false, forKey: allSpacesKey)
        let (slot, _, b) = try makeSlot(tabsBySpace: [("a", [101, 102]), ("b", [])])
        slot.activate(spaceId: "b", animated: false)
        let before = activations(101) + activations(102)

        b.browserState.tabSwitchManager.handleStep(.forward, initiatingKey: nil)
        await drainMainQueue()
        XCTAssertTrue(slot.visibleController === b, "the switcher stays in Space B")
        XCTAssertEqual(activations(101) + activations(102), before)
    }

    func testHistoryOnlyMergesAcrossTheSameProfileAndIncognitoState() {
        let base = BrowserState(windowId: 1, localStore: store, spaceId: "a")
        let sameProfile = BrowserState(windowId: 2, localStore: store, spaceId: "b")
        let otherProfile = BrowserState(windowId: 3, localStore: store, profileId: "Other", spaceId: "b")
        let incognito = BrowserState(windowId: 4, localStore: store, spaceId: "b", isIncognito: true)
        let agent = BrowserState(windowId: 5, localStore: store, spaceId: "b", isAgentSpace: true)

        XCTAssertTrue(TabSwitchManager.canMergeHistory(of: sameProfile, into: base))
        XCTAssertFalse(TabSwitchManager.canMergeHistory(of: otherProfile, into: base))
        XCTAssertFalse(TabSwitchManager.canMergeHistory(of: incognito, into: base))
        XCTAssertFalse(TabSwitchManager.canMergeHistory(of: base, into: incognito))
        XCTAssertFalse(TabSwitchManager.canMergeHistory(of: agent, into: base))
    }

    // MARK: - Helpers

    /// A shell presenting the first Space. Each Space's tabs are focused in
    /// the order given, so the last one is focused and newest.
    private func makeSlot(
        tabsBySpace: [(spaceId: String, tabIDs: [Int])]
    ) throws -> (SpaceWindowSlot, SpaceSessionController, SpaceSessionController) {
        let slot = SpaceWindowSlot(manager: manager, initialSpaceId: tabsBySpace[0].spaceId)
        slot.ensureShell(initialFrame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        slots.append(slot)
        let made = tabsBySpace.map { spaceId, tabIDs in
            nextWindowId += 1
            let state = UnseededBrowserState(windowId: nextWindowId, localStore: store,
                profileId: LocalStore.defaultProfileId, spaceId: spaceId)
            state.tabs = tabIDs.enumerated().map { index, id in
                let webView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
                webViews.append(webView)
                let wrapper = PageColorTestWebContentWrapper(urlString: "https://\(spaceId).example/\(id)")
                wrapper.nativeView = webView
                wrappers[id] = wrapper
                return Tab(guid: id, url: wrapper.urlString, isActive: false, index: index, webContentView: wrapper)
            }
            state.updateNormalTabs()
            let session = SpaceSessionController(window: slot.shell!.window, windowId: state.windowId,
                profileId: state.profileId, spaceId: spaceId, account: store.account,
                slot: slot, browserState: state, dormant: true)
            slot.registerWindow(session, for: spaceId)
            for tab in state.tabs { state.focuseTab(tab) }
            sessions.append(session)
            return session
        }
        XCTAssertTrue(slot.visibleController === made[0], "precondition: the first Space is presented")
        return (slot, made[0], made[1])
    }

    private func activations(_ tabID: Int) -> Int {
        wrappers[tabID]?.setAsActiveTabCallCount ?? 0
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            await drainMainQueue()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func drainMainQueue() async {
        let drained = expectation(description: "Main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
    }
}

/// A switch seeds an empty Browser with a tab through the bridge; these
/// Browsers have theirs already, and must never reach it.
private final class UnseededBrowserState: BrowserState {
    override func createQuickLookupTab(customGuid: String? = nil) {}
}

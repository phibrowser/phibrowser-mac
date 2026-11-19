// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import SwiftData
import XCTest
@testable import Phi

/// A tab's binding names the bookmark or pinned record it belongs to. The
/// window state changes it in one place, which keeps three things together:
/// the binding the Mac records, the one Chromium stores, and the AI Chat
/// panel, which finds its tab by binding.
@MainActor
final class BrowserStateTabBindingTests: XCTestCase {
    private var tempDirectories: [URL] = []
    nonisolated(unsafe) private static var replacedLayout: Any?

    /// Bookmark Tabs exist only outside the Comfortable layout: under it a
    /// window unbinds them on its first defaults change. The host app's own
    /// layout setting must not decide these tests. Any other layout is left
    /// alone, and the write happens once per class: each one makes the host
    /// app lay its windows out again.
    override class func setUp() {
        super.setUp()
        guard PhiPreferences.GeneralSettings.loadLayoutMode().isTraditional else { return }
        replacedLayout = UserDefaults.standard.object(forKey: PhiPreferences.GeneralSettings.layoutModeKey)
        PhiPreferences.GeneralSettings.saveLayoutMode(.performance)
    }

    override class func tearDown() {
        if let replacedLayout {
            UserDefaults.standard.set(replacedLayout, forKey: PhiPreferences.GeneralSettings.layoutModeKey)
            Self.replacedLayout = nil
        }
        super.tearDown()
    }

    override func tearDownWithError() throws {
        // The transfer test changes the pinned tab scope; see
        // `clearPinnedTabScopeMirrorDefaults`.
        clearPinnedTabScopeMirrorDefaults()
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    // MARK: - The entry

    func testBindingAnUnboundTabKeepsItsAIChatPanelAndReachesChromium() throws {
        let state = try makeState()
        let live = addLiveTab(to: state, guid: 1)
        let panel = addPanel(to: live.tab, in: state)

        state.setBinding("pin", for: live.tab)

        XCTAssertEqual(live.tab.guidInLocalDB, "pin")
        XCTAssertEqual(live.wrapper.customValues.last, "pin")
        XCTAssertTrue(state.aiChatTabs[state.getTabIdentifier(for: live.tab)] === panel)
    }

    func testRebindingATabKeepsItsAIChatPanelAndReachesChromium() throws {
        let state = try makeState()
        let live = addLiveTab(to: state, guid: 1, binding: "old")
        let panel = addPanel(to: live.tab, in: state)

        state.setBinding("new", for: live.tab)

        XCTAssertEqual(live.tab.guidInLocalDB, "new")
        XCTAssertEqual(live.wrapper.customValues.last, "new")
        XCTAssertTrue(state.aiChatTabs[state.getTabIdentifier(for: live.tab)] === panel)
    }

    func testClearingABindingKeepsTheAIChatPanelAndReachesChromium() throws {
        let state = try makeState()
        let live = addLiveTab(to: state, guid: 1, binding: "pin")
        let panel = addPanel(to: live.tab, in: state)

        state.setBinding(nil, for: live.tab)

        XCTAssertNil(live.tab.guidInLocalDB)
        XCTAssertEqual(live.wrapper.customValues.last, "")
        XCTAssertTrue(state.aiChatTabs[state.getTabIdentifier(for: live.tab)] === panel)
    }

    /// Forming a split out of a Bookmark Tab turns it into a normal tab.
    func testBookmarkTabTurnedNormalForASplitKeepsItsAIChatPanel() throws {
        let state = try makeState()
        let live = addLiveTab(to: state, guid: 1, binding: "bookmark")
        let panel = addPanel(to: live.tab, in: state)

        state.makeTabNormalOpened(tabId: 1)

        XCTAssertNil(live.tab.guidInLocalDB)
        XCTAssertEqual(live.wrapper.customValues.last, "")
        XCTAssertTrue(state.aiChatTabs[state.getTabIdentifier(for: live.tab)] === panel)
    }

    // MARK: - Peek

    func testRebindingAnOpenerPointsItsPeekAtTheNewBinding() throws {
        let state = try makeState()
        let opener = addLiveTab(to: state, guid: 1, binding: "old")
        let peek = addPeek(to: opener.tab, in: state)

        state.setBinding("new", for: opener.tab)

        XCTAssertEqual(peek.tab.guidInLocalDB, "phi-peek:new")
        XCTAssertEqual(peek.wrapper.customValues.last, "phi-peek:new")
    }

    func testClearingAnOpenersBindingLeavesItAnOpenerMarkerItsPeekPointsAt() throws {
        let state = try makeState()
        let opener = addLiveTab(to: state, guid: 1, binding: "pin")
        let peek = addPeek(to: opener.tab, in: state)

        state.setBinding(nil, for: opener.tab)

        let marker = try XCTUnwrap(opener.tab.guidInLocalDB)
        XCTAssertTrue(BrowserState.isPeekOpenerGuid(marker))
        XCTAssertEqual(opener.wrapper.customValues.last, marker)
        XCTAssertEqual(peek.tab.guidInLocalDB, "phi-peek:" + marker)
        XCTAssertEqual(peek.wrapper.customValues.last, "phi-peek:" + marker)
    }

    func testBindingANormalOpenerReplacesItsOpenerMarker() throws {
        let state = try makeState()
        let opener = addLiveTab(to: state, guid: 1, binding: "phi-peek-opener:pair")
        let peek = addPeek(to: opener.tab, in: state)

        state.setBinding("pin", for: opener.tab)

        XCTAssertEqual(opener.wrapper.customValues.last, "pin")
        XCTAssertEqual(peek.tab.guidInLocalDB, "phi-peek:pin")
        XCTAssertEqual(peek.wrapper.customValues.last, "phi-peek:pin")
    }

    /// A Peek opener marker is not a pin: the Pin command pins the tab.
    func testPinCommandPinsANormalTabThatCarriesAPeek() throws {
        let state = try makeState()
        let opener = addLiveTab(to: state, guid: 1, binding: "phi-peek-opener:pair")
        let peek = addPeek(to: opener.tab, in: state)

        state.toggleTabPinStatus(1, guidInDB: opener.tab.guidInLocalDB)

        XCTAssertTrue(opener.tab.isPinned)
        let binding = try XCTUnwrap(opener.tab.guidInLocalDB)
        XCTAssertFalse(BrowserState.isPeekOpenerGuid(binding))
        XCTAssertEqual(opener.wrapper.customValues.last, binding)
        XCTAssertEqual(peek.tab.guidInLocalDB, "phi-peek:" + binding)
    }

    /// A session saved before a pinned tab scope change can restore a normal
    /// tab that still carries the guid of its pre-change record. The current
    /// scope holds a record of the same lineage under a new guid.
    func testPinCommandOnANormalTabWithAStaleBindingKeepsTheExistingRecord() async throws {
        let store = try makeStore()
        try await seedPinnedTabUnderSpaceScope(in: store)
        let state = BrowserState(windowId: 1, localStore: store, profileId: "Default", spaceId: "space-a")
        let existing = try XCTUnwrap(state.pinnedTabs.first?.guidInLocalDB)
        XCTAssertNotEqual(existing, "pin")
        let live = addLiveTab(to: state, guid: 1, binding: "pin")

        state.toggleTabPinStatus(1, guidInDB: "pin")
        await store.performBackgroundWriteAndWait { _ in }

        XCTAssertTrue(store.isPinnedTabInActiveScope(guid: existing))
        XCTAssertTrue(live.tab.isPinned)
        let binding = try XCTUnwrap(live.tab.guidInLocalDB)
        XCTAssertFalse(["pin", existing].contains(binding))
        XCTAssertEqual(live.wrapper.customValues.last, binding)
        XCTAssertTrue(store.isPinnedTabInActiveScope(guid: binding))
    }

    func testPinCommandPinsABookmarkTabAsANewRecord() throws {
        let state = try makeState()
        _ = try addBookmark(to: state, url: "https://bookmark.example")
        let live = addLiveTab(to: state, guid: 1, binding: "bookmark")

        state.toggleTabPinStatus(1, guidInDB: "bookmark")

        XCTAssertTrue(live.tab.isPinned)
        let binding = try XCTUnwrap(live.tab.guidInLocalDB)
        XCTAssertNotEqual(binding, "bookmark")
        XCTAssertEqual(live.wrapper.customValues.last, binding)
        XCTAssertNotNil(state.bookmarkManager.bookmark(withGuid: "bookmark"))
    }

    /// The live tab of a restored pinned tab is not flagged pinned; its
    /// binding to a current record is what makes the command an unpin.
    func testPinCommandUnpinsAnUnflaggedTabBoundToACurrentRecord() async throws {
        let store = try makeStore()
        try await seedPinnedTabUnderSpaceScope(in: store)
        let state = BrowserState(windowId: 1, localStore: store, profileId: "Default", spaceId: "space-a")
        let existing = try XCTUnwrap(state.pinnedTabs.first?.guidInLocalDB)
        let live = addLiveTab(to: state, guid: 1, binding: existing)

        state.toggleTabPinStatus(1, guidInDB: existing)
        await store.performBackgroundWriteAndWait { _ in }

        XCTAssertFalse(store.isPinnedTabInActiveScope(guid: existing))
        XCTAssertNil(live.tab.guidInLocalDB)
        XCTAssertEqual(live.wrapper.customValues.last, "")
    }

    func testRebindingATabWithoutAPeekWritesOnlyItsBinding() throws {
        let state = try makeState()
        let live = addLiveTab(to: state, guid: 1, binding: "old")
        let other = addLiveTab(to: state, guid: 2)

        state.setBinding("new", for: live.tab)

        XCTAssertEqual(live.wrapper.customValues, ["new"])
        XCTAssertEqual(other.wrapper.customValues, [])
    }

    // MARK: - Rebinding paths

    func testPinnedTabSavedAsABookmarkIsBoundToTheBookmarkInChromium() throws {
        let state = try makeState()
        let record = Tab(guid: 1, url: "https://pin.example", isActive: false, index: 0,
                         title: "Pin", customGuid: "pin")
        record.isOpenned = true
        state.pinnedTabs = [record]
        let live = addLiveTab(to: state, guid: 1, binding: "pin")
        live.tab.isPinned = true

        state.movePinnedTabOut(pinnedGuid: "pin", toBookmark: nil, index: 0)

        let binding = try XCTUnwrap(live.tab.guidInLocalDB)
        XCTAssertNotEqual(binding, "pin")
        XCTAssertEqual(live.wrapper.customValues.last, binding)
    }

    func testBookmarkTabPinnedIsBoundToThePinnedRecordInChromium() throws {
        let state = try makeState()
        let bookmark = try addBookmark(to: state, url: "https://bookmark.example")
        let live = addLiveTab(to: state, guid: 1, binding: "bookmark")
        state.syncAllBookmarksOpenedState()

        let pinnedGuid = try XCTUnwrap(state.moveBookmarkOut(bookmark, afterPinnedGuid: nil))

        XCTAssertEqual(live.tab.guidInLocalDB, pinnedGuid)
        XCTAssertEqual(live.wrapper.customValues.last, pinnedGuid)
    }

    /// The window's first defaults change lands between the Bookmark Tab
    /// opening and the pin. Under the Comfortable layout that change unbinds
    /// the tab; under any other layout the pin must still rebind it.
    func testBookmarkTabPinnedRightAfterOpeningIsBoundToThePinnedRecord() throws {
        let state = try makeState()
        let bookmark = try addBookmark(to: state, url: "https://bookmark.example")
        let live = addLiveTab(to: state, guid: 1, binding: "bookmark")
        state.handleBookmarkTabOpened(live.tab)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: UserDefaults.standard)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let pinnedGuid = try XCTUnwrap(state.moveBookmarkOut(bookmark, afterPinnedGuid: nil))
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))

        XCTAssertEqual(live.tab.guidInLocalDB, pinnedGuid)
        XCTAssertEqual(live.wrapper.customValues.last, pinnedGuid)
    }

    func testSplitBookmarkPinnedBindsEachPaneToItsPinnedRecordInChromium() throws {
        let state = try makeState()
        let bookmark = try addBookmark(to: state, url: "https://left.example",
                                       secondaryUrl: "https://right.example")
        let left = addLiveTab(to: state, guid: 1)
        let right = addLiveTab(to: state, guid: 2)
        state.splits = [SplitGroup(id: "split", tabIds: [1, 2], layout: .vertical, fractions: [0.5, 0.5])]
        state.splitBookmarkBindings["bookmark"] = "split"

        XCTAssertNotNil(state.moveBookmarkOut(bookmark, afterPinnedGuid: nil))

        let leftBinding = try XCTUnwrap(left.tab.guidInLocalDB)
        let rightBinding = try XCTUnwrap(right.tab.guidInLocalDB)
        XCTAssertNotEqual(leftBinding, rightBinding)
        XCTAssertEqual(left.wrapper.customValues.last, leftBinding)
        XCTAssertEqual(right.wrapper.customValues.last, rightBinding)
    }

    /// A split dragged onto bookmarks out of a tab group stays in the group;
    /// a pinned tab cannot be in one.
    func testSplitBookmarkPinnedTakesItsPanesOutOfTheirTabGroup() throws {
        let state = try makeState()
        let bookmark = try addBookmark(to: state, url: "https://left.example",
                                       secondaryUrl: "https://right.example")
        let left = addLiveTab(to: state, guid: 1)
        let right = addLiveTab(to: state, guid: 2)
        left.tab.groupToken = "A"
        right.tab.groupToken = "A"
        state.splits = [SplitGroup(id: "split", tabIds: [1, 2], layout: .vertical, fractions: [0.5, 0.5])]
        state.splitBookmarkBindings["bookmark"] = "split"

        XCTAssertNotNil(state.moveBookmarkOut(bookmark, afterPinnedGuid: nil))

        XCTAssertNil(left.tab.groupToken)
        XCTAssertNil(right.tab.groupToken)
        XCTAssertNotNil(left.tab.guidInLocalDB)
        XCTAssertNotNil(right.tab.guidInLocalDB)
    }

    /// Under Space scope a pin dragged to another Space's window is copied to
    /// a new record there.
    func testPinnedTabMovedToAnotherOwnerIsBoundToItsNewRecordInChromium() async throws {
        let store = try makeStore()
        try await seedPinnedTabUnderSpaceScope(in: store)
        let source = BrowserState(windowId: 1, localStore: store, profileId: "Default", spaceId: "space-a")
        let target = BrowserState(windowId: 2, localStore: store, profileId: "Default", spaceId: "space-b")
        let record = try XCTUnwrap(source.pinnedTabs.first)
        let oldBinding = try XCTUnwrap(record.guidInLocalDB)
        let live = addLiveTab(to: source, guid: 1, binding: oldBinding)

        try await source.commitCrossWindowPinnedDrop(pinnedGuid: oldBinding, to: target, destinationIndex: 0)

        let binding = try XCTUnwrap(live.tab.guidInLocalDB)
        XCTAssertNotEqual(binding, oldBinding)
        XCTAssertEqual(live.wrapper.customValues.last, binding)
    }

    // MARK: - Fixtures

    private func makeStore() throws -> LocalStore {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        return LocalStore(account: Account(userID: UUID().uuidString),
                          storeDirectoryURL: directory,
                          presentsCompatibilityAlerts: false)
    }

    private func makeState() throws -> BrowserState {
        BrowserState(windowId: 1, localStore: try makeStore(), profileId: "Default")
    }

    /// An open tab in `state` whose wrapper records what Chromium is told.
    private func addLiveTab(
        to state: BrowserState,
        guid: Int,
        binding: String? = nil
    ) -> (tab: Tab, wrapper: PinnedScopeVariantWebContentWrapperSpy) {
        let wrapper = PinnedScopeVariantWebContentWrapperSpy(urlString: "https://e\(guid).example", title: nil)
        let tab = Tab(guid: guid, url: wrapper.urlString, isActive: false, index: state.tabs.count,
                      webContentView: wrapper, customGuid: binding)
        state.tabs.append(tab)
        return (tab, wrapper)
    }

    /// A Peek open on `opener`, marked the way opening one marks it. Like a
    /// real Peek, its tab is not in the window's tab list.
    private func addPeek(
        to opener: Tab,
        in state: BrowserState
    ) -> (tab: Tab, wrapper: PinnedScopeVariantWebContentWrapperSpy) {
        let wrapper = PinnedScopeVariantWebContentWrapperSpy(urlString: "https://peek.example", title: nil)
        let tab = Tab(guid: opener.guid * 1000, url: wrapper.urlString, isActive: false, index: 0,
                      webContentView: wrapper, customGuid: "phi-peek:" + (opener.guidInLocalDB ?? ""))
        state.peekState.present(tab, openerTabId: opener.guid)
        return (tab, wrapper)
    }

    /// A stored bookmark with guid "bookmark", once the window knows it.
    private func addBookmark(
        to state: BrowserState,
        url: String,
        secondaryUrl: String? = nil
    ) throws -> Bookmark {
        state.localStore.createBookmark(url: url, title: "Bookmark", profileId: state.profileId,
                                        parentId: nil, guid: "bookmark", spaceId: state.spaceId,
                                        secondaryUrl: secondaryUrl)
        let deadline = Date().addingTimeInterval(2)
        while state.bookmarkManager.bookmark(withGuid: "bookmark") == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return try XCTUnwrap(state.bookmarkManager.bookmark(withGuid: "bookmark"))
    }

    /// Gives `tab` an AI Chat panel, filed the way a new panel tab is.
    private func addPanel(to tab: Tab, in state: BrowserState) -> Tab {
        let panel = Tab(guid: tab.guid * 100, url: "chrome://conversation/", isActive: false, index: 0)
        state.aiChatTabs[state.getTabIdentifier(for: tab)] = panel
        return panel
    }

    private func seedPinnedTabUnderSpaceScope(in store: LocalStore) async throws {
        let context = try XCTUnwrap(store.getMainContext())
        let profile = ProfileModel(profileId: "Default")
        context.insert(profile)
        for (order, spaceId) in ["space-a", "space-b"].enumerated() {
            context.insert(SpaceModel(spaceId: spaceId, profileId: "Default", name: spaceId,
                                      colorHex: "#000000", iconName: "star", sortOrder: order))
        }
        let pin = TabDataModel(title: "Pin", guid: "pin", index: 0,
                               url: try XCTUnwrap(URL(string: "https://pin.example")),
                               favicon: nil, createdDate: Date(), updatedDate: Date())
        pin.dataType = .pinnedTab
        pin.profileId = profile.profileId
        pin.pinLineageId = "pin"
        context.insert(pin)
        pin.profile = profile
        try context.save()
        try await store.changePinnedTabScope(to: .space, preferredProfileId: "Default",
                                             preferredSpaceId: "space-a")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
}

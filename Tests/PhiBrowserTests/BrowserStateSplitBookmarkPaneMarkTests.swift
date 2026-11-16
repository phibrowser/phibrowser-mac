// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// The panes of an open Split Bookmark are marked bound in Chromium, so Space
/// URL rules leave them in place; the mark follows the window's Split
/// Bookmark bindings and split membership. A URL typed in a marked pane opens
/// in a new tab, as from every other bound tab.
@MainActor
final class BrowserStateSplitBookmarkPaneMarkTests: XCTestCase {
    private var tempDirectories: [URL] = []
    private var originalLayoutRawValue: String?

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalLayoutRawValue = UserDefaults.standard.string(forKey: PhiPreferences.GeneralSettings.layoutModeKey)
        PhiPreferences.GeneralSettings.saveLayoutMode(.performance)
    }

    override func tearDownWithError() throws {
        if let originalLayoutRawValue {
            UserDefaults.standard.set(originalLayoutRawValue,
                                      forKey: PhiPreferences.GeneralSettings.layoutModeKey)
        } else {
            UserDefaults.standard.removeObject(forKey: PhiPreferences.GeneralSettings.layoutModeKey)
        }
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification,
                                        object: UserDefaults.standard)
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
        try super.tearDownWithError()
    }

    // MARK: - Opening

    /// The first pane loses its split-pending marker as it arrives, before
    /// its split exists; it is marked first, so no part of its first load
    /// goes unmarked.
    func testFirstPaneOfAnOpeningSplitBookmarkIsMarkedBeforeItsMarkerGoes() throws {
        let (state, bookmark) = try makeStateWithSplitBookmark(guid: "opening-first")
        state.openBookmark(bookmark)
        let pendingGuid = try XCTUnwrap(state.pendingPrimarySplitTargetByGuid.first {
            $0.value.boundBookmarkGuid == bookmark.guid
        }?.key)
        let primary = PageColorTestWebContentWrapper(urlString: "https://primary.example")

        state.handleNewTabFromChromium(Tab(guid: 51, url: "https://primary.example", isActive: true,
                                           index: 0, webContentView: primary, customGuid: pendingGuid))

        XCTAssertEqual(primary.bindingPushLog, ["bound=true", "customValue="])
    }

    func testSecondPaneOfAnOpeningSplitBookmarkIsMarkedBeforeItsMarkerGoes() throws {
        let (state, bookmark) = try makeStateWithSplitBookmark(guid: "opening-second")
        let wrappers = addTabs(to: state)
        let pendingGuid = SplitPendingGuid.partner.mint()
        state.pendingSplitPartnerByCustomGuid[pendingGuid] = PendingSplitPartner(
            target: .newPair(partnerTabId: 51, newTabSlot: .right, layout: .vertical),
            boundBookmarkGuid: bookmark.guid)
        let partner = PageColorTestWebContentWrapper(urlString: "https://secondary.example")

        state.handleNewTabFromChromium(Tab(guid: 53, url: "https://secondary.example", isActive: false,
                                           index: 3, webContentView: partner, customGuid: pendingGuid))

        // The test host has no Browser for this window, so the split request
        // then fails and the pane is let go.
        XCTAssertEqual(Array(partner.bindingPushLog.prefix(2)), ["bound=true", "customValue="])
        XCTAssertTrue(wrappers.allSatisfy { $0.boundTabPushes.isEmpty })
    }

    /// The panes are marked on arrival, then held by the binding once
    /// Chromium reports their split; they are never unmarked in between.
    func testPanesStayMarkedWhileTheirSplitForms() throws {
        let (state, bookmark) = try makeStateWithSplitBookmark(guid: "forming")
        let wrappers = addTabs(to: state)

        state.splitPaneIdsOpeningBehindBookmark.formUnion([51, 52])
        state.splitBookmarkBindings[bookmark.guid] = "split-1"
        state.handleSplitCreated(splitId: "split-1", tabIds: [51, 52],
                                 layout: .vertical, fractions: [0.5, 0.5])

        XCTAssertTrue(state.splitPaneIdsOpeningBehindBookmark.isEmpty)
        XCTAssertEqual(wrappers.map(\.boundTabPushes), [[], [true], [true]])
    }

    func testPaneOfASplitThatNeverFormsIsUnmarked() throws {
        let state = try makeState()
        let pane = PageColorTestWebContentWrapper(urlString: "https://primary.example")
        state.splitPaneIdsOpeningBehindBookmark.insert(51)
        state.tabs = [Tab(guid: 51, url: "https://primary.example", isActive: true,
                          index: 0, webContentView: pane)]

        state.listPanesNoLongerOpeningBehindBookmark([51])

        XCTAssertEqual(pane.boundTabPushes, [true, false])
    }

    // MARK: - Restoring

    /// The split is bound again inside the restore transaction, which runs in
    /// Chromium's replay stack; the marks reach Chromium after it.
    func testRestoredSplitPanesAreMarkedAfterTheRestoreTransaction() throws {
        let (state, bookmark) = try makeStateWithSplitBookmark(guid: "restored")
        state.localStore.account.userDefaults.set(["split-1": bookmark.guid],
                                                  forKey: BrowserState.savedSplitBookmarkBindingsKey)
        let wrappers = [50, 51, 52].map { PageColorTestWebContentWrapper(urlString: "https://e\($0).example") }

        state.handleRestoredWindowSnapshot(restoredWindow(wrappers: wrappers, splitId: "split-1"))

        XCTAssertEqual(state.splitBookmarkBindings, [bookmark.guid: "split-1"])
        XCTAssertTrue(wrappers.allSatisfy { $0.boundTabPushes.isEmpty },
                      "Nothing is pushed from inside the transaction")
        drainPageColorUpdates()
        XCTAssertEqual(wrappers.map(\.boundTabPushes), [[], [true], [true]])
    }

    // MARK: - Ending the binding

    func testBreakingUpTheSplitUnmarksItsPanes() throws {
        let (state, wrappers) = try makeBoundSplit()

        state.handleSplitRemoved(splitId: "split-1")

        XCTAssertEqual(wrappers.map(\.boundTabPushes), [[], [true, false], [true, false]])
    }

    func testRemovingTheBindingUnmarksThePanes() throws {
        let (state, wrappers) = try makeBoundSplit()

        state.splitBookmarkBindings.removeValue(forKey: "bookmark")

        XCTAssertEqual(wrappers.map(\.boundTabPushes), [[], [true, false], [true, false]])
    }

    /// Tab 50 takes the place of pane 52.
    func testReplacedPaneIsUnmarkedAndItsReplacementMarked() throws {
        let (state, wrappers) = try makeBoundSplit()

        state.handleSplitContentsChanged(splitId: "split-1", tabIds: [51, 50])

        XCTAssertEqual(wrappers.map(\.boundTabPushes), [[true], [true], [true, false]])
    }

    /// Chromium replaces a pane by removing the split and creating it again
    /// under its id, the binding missing in between. Tab 50 takes pane 51's
    /// place; pane 52 stays marked throughout.
    func testReplacingAPaneThroughSplitRecreationKeepsTheOtherPanesMarked() throws {
        let (state, wrappers) = try makeBoundSplit()

        state.swapTabInSplit("split-1", slotIndex: 0, withTabId: 50, swap: true)
        state.handleSplitRemoved(splitId: "split-1")
        state.handleSplitCreated(splitId: "split-1", tabIds: [50, 52],
                                 layout: .vertical, fractions: [0.5, 0.5])

        XCTAssertEqual(state.splitBookmarkBindings, ["bookmark": "split-1"])
        XCTAssertEqual(wrappers.map(\.boundTabPushes), [[true], [true, false], [true]])
    }

    /// A bookmark dragged onto a pane opens as a tab under a swap marker,
    /// which goes as the tab arrives and asks for the swap; the tab is
    /// marked in that same call.
    func testTabOpenedToReplaceAPaneIsMarkedAsItArrives() throws {
        let (state, _) = try makeBoundSplit()
        let pendingGuid = SplitPendingGuid.swapSlot.mint()
        state.pendingSplitSlotSwapByCustomGuid[pendingGuid] = PendingSplitSlotSwap(splitId: "split-1",
                                                                                   slotIndex: 1)
        let incoming = PageColorTestWebContentWrapper(urlString: "https://incoming.example")

        state.handleNewTabFromChromium(Tab(guid: 53, url: "https://incoming.example", isActive: false,
                                           index: 3, webContentView: incoming, customGuid: pendingGuid))

        XCTAssertEqual(incoming.bindingPushLog, ["customValue=", "bound=true"])
    }

    /// A pane that leaves the window still alive is unmarked through the
    /// wrapper it was marked through.
    func testPaneLeavingTheWindowIsUnmarked() throws {
        let (state, wrappers) = try makeBoundSplit()

        state.tabs.removeAll { $0.guid == 52 }

        XCTAssertEqual(wrappers[2].boundTabPushes, [true, false])
    }

    // MARK: - Splits that are not Split Bookmarks

    func testOrdinarySplitIsNotMarked() throws {
        let state = try makeState()
        let wrappers = addTabs(to: state)

        state.handleSplitCreated(splitId: "split-1", tabIds: [51, 52],
                                 layout: .vertical, fractions: [0.5, 0.5])

        XCTAssertTrue(wrappers.allSatisfy { $0.boundTabPushes.isEmpty })
    }

    /// Each pane of a pinned split carries its pinned record's custom value,
    /// which Chromium already treats as bound.
    func testPinnedSplitIsNotMarked() throws {
        let state = try makeState()
        let wrappers = addTabs(to: state)
        state.pendingPinnedSplitMarkByCreateId.insert("split-1")

        state.handleSplitCreated(splitId: "split-1", tabIds: [51, 52],
                                 layout: .vertical, fractions: [0.5, 0.5])

        XCTAssertEqual(state.splitGroup(forId: "split-1")?.isPinned, true)
        XCTAssertTrue(wrappers.allSatisfy { $0.boundTabPushes.isEmpty })
    }

    // MARK: - Address bar

    /// A URL typed while a pane has focus opens in a new tab, which the rules
    /// route, as it does from a pinned tab or Bookmark Tab; loaded in the
    /// marked pane it would skip them.
    func testAddressBarSubmissionInAPaneOpensANewTab() throws {
        let (state, _) = try makeBoundSplit()

        XCTAssertEqual(try [50, 51, 52].map { state.addressBarNavigationOpensNewTab(for: try tab($0, in: state)) },
                       [false, true, true])
    }

    func testAddressBarSubmissionInAPaneOfABrokenUpSplitNavigatesInPlace() throws {
        let (state, _) = try makeBoundSplit()

        state.handleSplitRemoved(splitId: "split-1")

        XCTAssertFalse(state.addressBarNavigationOpensNewTab(for: try tab(51, in: state)))
    }

    func testAddressBarSubmissionInAPaneNavigatesInPlaceOnceItsBindingIsGone() throws {
        let (state, _) = try makeBoundSplit()

        state.splitBookmarkBindings.removeValue(forKey: "bookmark")

        XCTAssertFalse(state.addressBarNavigationOpensNewTab(for: try tab(51, in: state)))
    }

    func testAddressBarSubmissionInAnOrdinarySplitPaneNavigatesInPlace() throws {
        let state = try makeState()
        _ = addTabs(to: state)

        state.handleSplitCreated(splitId: "split-1", tabIds: [51, 52],
                                 layout: .vertical, fractions: [0.5, 0.5])

        XCTAssertFalse(state.addressBarNavigationOpensNewTab(for: try tab(51, in: state)))
    }

    func testAddressBarSubmissionInAPinnedSplitPaneOpensANewTab() throws {
        let state = try makeState()
        state.pinnedTabs = [51, 52].map(pinnedTab)
        state.tabs = [51, 52].map(pinnedTab)
        state.pendingPinnedSplitMarkByCreateId.insert("split-1")

        state.handleSplitCreated(splitId: "split-1", tabIds: [51, 52],
                                 layout: .vertical, fractions: [0.5, 0.5])

        XCTAssertTrue(state.addressBarNavigationOpensNewTab(for: try tab(51, in: state)))
    }

    func testAddressBarSubmissionInABookmarkTabOpensANewTab() throws {
        let state = try makeState()
        state.localStore.createBookmark(url: "https://saved.example",
                                        title: "Bookmark",
                                        profileId: state.profileId,
                                        parentId: nil,
                                        guid: "bookmark-tab",
                                        spaceId: state.spaceId)
        XCTAssertTrue(waitUntil { state.bookmarkManager.bookmark(withGuid: "bookmark-tab") != nil })
        let bookmarkTab = Tab(guid: 51, url: "https://saved.example", isActive: false,
                              index: 0, customGuid: "bookmark-tab")
        state.tabs = [bookmarkTab]

        XCTAssertTrue(state.addressBarNavigationOpensNewTab(for: bookmarkTab))
    }

    /// The traditional layout keeps plain same-tab navigation in a pinned tab.
    func testAddressBarSubmissionInAPinnedTabNavigatesInPlaceInTheComfortableLayout() throws {
        let state = try makeState()
        state.pinnedTabs = [pinnedTab(51)]
        let pinned = pinnedTab(51)
        state.tabs = [pinned]
        XCTAssertTrue(state.addressBarNavigationOpensNewTab(for: pinned))

        state.layoutMode = .comfortable

        XCTAssertFalse(state.addressBarNavigationOpensNewTab(for: pinned))
    }

    // MARK: - Helpers

    private func makeStore() throws -> LocalStore {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        return LocalStore(account: Account(userID: UUID().uuidString),
                          storeDirectoryURL: directory)
    }

    private func makeState() throws -> BrowserState {
        BrowserState(windowId: 7, localStore: try makeStore(), profileId: "Default")
    }

    /// A window whose store has already delivered a split-view bookmark.
    private func makeStateWithSplitBookmark(guid: String) throws -> (BrowserState, Bookmark) {
        let state = try makeState()
        state.localStore.createBookmark(url: "https://primary.example",
                                        title: "Bookmark",
                                        profileId: state.profileId,
                                        parentId: nil,
                                        guid: guid,
                                        spaceId: state.spaceId,
                                        secondaryUrl: "https://secondary.example")
        XCTAssertTrue(waitUntil { state.bookmarkManager.bookmark(withGuid: guid) != nil })
        return (state, try XCTUnwrap(state.bookmarkManager.bookmark(withGuid: guid)))
    }

    /// Tabs 50, 51 and 52, each with a wrapper, returned in that order.
    private func addTabs(to state: BrowserState) -> [PageColorTestWebContentWrapper] {
        let wrappers = [50, 51, 52].map { PageColorTestWebContentWrapper(urlString: "https://e\($0).example") }
        state.tabs = zip([50, 51, 52], wrappers).map { guid, wrapper in
            Tab(guid: guid, url: wrapper.urlString, isActive: false, index: guid, webContentView: wrapper)
        }
        return wrappers
    }

    private func tab(_ guid: Int, in state: BrowserState) throws -> Tab {
        try XCTUnwrap(state.tabs.first { $0.guid == guid })
    }

    /// A tab carrying the custom value of the pinned record "pinned-<guid>";
    /// stands for both the record and its live tab.
    private func pinnedTab(_ guid: Int) -> Tab {
        Tab(guid: guid, url: "https://e\(guid).example", isActive: false,
            index: guid, customGuid: "pinned-\(guid)")
    }

    /// Tabs 50, 51 and 52, the last two as the split "split-1" bound to the
    /// Split Bookmark "bookmark". Returns the three tabs' wrappers.
    private func makeBoundSplit() throws -> (BrowserState, [PageColorTestWebContentWrapper]) {
        let (state, bookmark) = try makeStateWithSplitBookmark(guid: "bookmark")
        let wrappers = addTabs(to: state)
        state.handleSplitCreated(splitId: "split-1", tabIds: [51, 52],
                                 layout: .vertical, fractions: [0.5, 0.5])
        state.splitBookmarkBindings[bookmark.guid] = "split-1"
        XCTAssertEqual(wrappers.map(\.boundTabPushes), [[], [true], [true]])
        return (state, wrappers)
    }

    /// Tabs 50, 51 and 52 with `wrappers`, the last two as the split `splitId`.
    private func restoredWindow(wrappers: [PageColorTestWebContentWrapper],
                                splitId: String) -> BrowserState.RestoredWindowSnapshot {
        var previousGuid: Int?
        let items = zip([50, 51, 52], wrappers).map { guid, wrapper -> (tab: Tab, context: NativeTabCreationContext) in
            let tab = Tab(guid: guid, url: wrapper.urlString, isActive: false, index: 0, webContentView: wrapper)
            let context = NativeTabCreationContext(isActiveAtCreation: false,
                                                   creationKind: .restore,
                                                   insertAfterTabId: previousGuid)
            previousGuid = guid
            return (tab, context)
        }
        return BrowserState.RestoredWindowSnapshot(
            tabs: items,
            activeTabId: 50,
            splitActions: [.created(splitId: splitId, tabIds: [51, 52], layout: .vertical, fractions: [0.5, 0.5])])
    }

    private func waitUntil(timeout: TimeInterval = 5, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }
}

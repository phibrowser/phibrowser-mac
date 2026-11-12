// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// A split holds two to four panes in slot order. These cover the parts of
/// `SplitGroup` and `BrowserState+Split` that a wider split exercises and a
/// pair never did: share normalisation, the middle pane position, adjacency
/// of a longer run, drops around it, and a split that grows or shrinks while
/// it stays up.
private final class SplitCloseRecordingBrowserState: BrowserState {
    var closedTabBatches: [[Int]] = []

    override func closeTabs(_ tabs: [Tab]) {
        closedTabBatches.append(tabs.map(\.guid))
    }
}

@MainActor
final class BrowserStateSplitPanesTests: XCTestCase {
    private var tempDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    private func makeState() throws -> BrowserState {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        let store = LocalStore(account: Account(userID: UUID().uuidString),
                               storeDirectoryURL: directory)
        // No Chromium Browser exists for this ID; bridge requests cannot affect real tabs.
        return BrowserState(windowId: -982641, localStore: store, profileId: "Default")
    }

    private func makeCloseRecordingState() throws -> SplitCloseRecordingBrowserState {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        let store = LocalStore(account: Account(userID: UUID().uuidString),
                               storeDirectoryURL: directory)
        return SplitCloseRecordingBrowserState(windowId: -982641, localStore: store, profileId: "Default")
    }

    /// `guids` as plain normal tabs, the first one focused, in that order.
    private func seed(_ state: BrowserState, guids: [Int]) {
        state.tabs = guids.enumerated().map { index, guid in
            Tab(guid: guid, url: "https://e\(guid).example", isActive: index == 0, index: index)
        }
        state.updateNormalTabs()
        state.focusingTab = state.tabs.first
    }

    private func assertEqual(_ fractions: [Double], _ expected: [Double],
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(fractions.count, expected.count, file: file, line: line)
        for (value, want) in zip(fractions, expected) {
            XCTAssertEqual(value, want, accuracy: 1e-9, file: file, line: line)
        }
    }

    // MARK: - A split that takes a new pane belongs to the normal list

    /// A live pinned split of `liveIds`, whose records also list `closedDBs`
    /// (panes closed since it opened).
    private func seedPinnedSplit(_ state: BrowserState,
                                 liveIds: [Int],
                                 closedDBs: [String] = []) {
        let liveDBs = liveIds.map { "db-\($0)" }
        let dbGuids = liveDBs + closedDBs
        let records = dbGuids.enumerated().map { index, db -> Tab in
            let guid = index < liveIds.count ? liveIds[index] : -(index + 1)
            let record = Tab(guid: guid, url: "https://\(db).example",
                             isActive: false, index: index, customGuid: db)
            record.isOpenned = index < liveIds.count
            record.splitPaneGuids = dbGuids.count > 2 ? dbGuids : []
            if dbGuids.count == 2 { record.splitPartnerGuid = dbGuids[1 - index] }
            return record
        }
        state.pinnedTabs = records
        state.tabs = liveIds.enumerated().map { index, guid in
            let tab = Tab(guid: guid, url: "https://db-\(guid).example",
                          isActive: index == 0, index: index, customGuid: "db-\(guid)")
            tab.isPinned = true
            return tab
        }
        state.splits = [SplitGroup(id: "pinned", tabIds: liveIds, layout: .vertical,
                                   fractions: SplitGroup.equalFractions(paneCount: liveIds.count),
                                   isPinned: true)]
        state.updateNormalTabs()
        state.focusingTab = state.tabs.first
    }

    func testMakeSplitNormalOpenedIsANoOpForASplitAlreadyInTheList() throws {
        let state = try makeState()
        seed(state, guids: [1, 2, 3])
        state.splits = [SplitGroup(id: "s", tabIds: [1, 2], layout: .vertical, fractions: [0.5, 0.5])]

        XCTAssertTrue(state.makeSplitNormalOpened("s"))
        XCTAssertEqual(state.normalTabs.map(\.guid), [1, 2, 3])
        XCTAssertFalse(state.makeSplitNormalOpened("missing"))
    }

    func testMakeSplitNormalOpenedMovesAPinnedSplitToTheTopOfTheList() throws {
        let state = try makeState()
        seedPinnedSplit(state, liveIds: [1, 2, 3])
        let plain = Tab(guid: 9, url: "https://plain.example", isActive: false, index: 3)
        state.tabs.append(plain)
        state.updateNormalTabs()
        XCTAssertEqual(state.normalTabs.map(\.guid), [9])

        XCTAssertTrue(state.makeSplitNormalOpened("pinned"))

        XCTAssertEqual(state.splitGroup(forId: "pinned")?.isPinned, false)
        XCTAssertEqual(state.splitGroup(forId: "pinned")?.tabIds, [1, 2, 3])
        XCTAssertEqual(state.normalTabs.map(\.guid), [1, 2, 3, 9])
        for guid in [1, 2, 3] {
            let tab = try XCTUnwrap(state.tabs.first { $0.guid == guid })
            XCTAssertNil(tab.guidInLocalDB, "Pane \(guid) must leave its pinned record")
            XCTAssertFalse(tab.isPinned)
        }
    }

    func testMakeSplitNormalOpenedKeepsLivePanesOfAPartlyClosedPinnedSplit() throws {
        let state = try makeState()
        seedPinnedSplit(state, liveIds: [1, 2], closedDBs: ["db-closed"])

        XCTAssertTrue(state.makeSplitNormalOpened("pinned"))

        XCTAssertEqual(state.splitGroup(forId: "pinned")?.isPinned, false)
        XCTAssertEqual(state.normalTabs.map(\.guid), [1, 2])
    }

    func testMakeSplitNormalOpenedFailsWhenAPinnedPaneHasNoRecord() throws {
        let state = try makeState()
        seedPinnedSplit(state, liveIds: [1, 2])
        state.pinnedTabs = []

        XCTAssertFalse(state.makeSplitNormalOpened("pinned"))
        XCTAssertEqual(state.splitGroup(forId: "pinned")?.isPinned, true)
    }

    func testMakeSplitNormalOpenedReleasesABookmarkBoundSplit() throws {
        let state = try makeState()
        seed(state, guids: [1, 2, 3, 4])
        state.splits = [SplitGroup(id: "s", tabIds: [1, 2, 3], layout: .vertical,
                                   fractions: [0.5, 0.25, 0.25])]
        state.splitBookmarkBindings["bookmark"] = "s"
        state.updateNormalTabs()
        XCTAssertEqual(state.normalTabs.map(\.guid), [4], "A bound split hides behind its bookmark")

        XCTAssertTrue(state.makeSplitNormalOpened("s"))

        XCTAssertNil(state.splitBookmarkBindings["bookmark"])
        XCTAssertEqual(state.normalTabs.map(\.guid), [1, 2, 3, 4])
    }

    func testAddTabToSplitMovesAPinnedSplitToTheListFirst() throws {
        let state = try makeState()
        seedPinnedSplit(state, liveIds: [1, 2, 3])
        state.tabs.append(Tab(guid: 9, url: "https://plain.example", isActive: false, index: 3))
        state.updateNormalTabs()

        XCTAssertTrue(state.addTabToSplit("pinned", tabId: 9, slot: 3))

        XCTAssertEqual(state.splitGroup(forId: "pinned")?.isPinned, false)
        XCTAssertTrue(state.tabsAwaitingSplit.contains(9))
    }

    func testAddTabToSplitRefusesAFullSplitAndATabAlreadyInASplit() throws {
        let state = try makeState()
        seed(state, guids: [1, 2, 3, 4, 5, 6, 7])
        state.splits = [
            SplitGroup(id: "full", tabIds: [1, 2, 3, 4], layout: .vertical,
                       fractions: SplitGroup.equalFractions(paneCount: 4)),
            SplitGroup(id: "pair", tabIds: [5, 6], layout: .vertical, fractions: [0.5, 0.5]),
        ]

        XCTAssertFalse(state.addTabToSplit("full", tabId: 7, slot: 0))
        XCTAssertFalse(state.addTabToSplit("pair", tabId: 1, slot: 0), "A pane of another split")
        XCTAssertFalse(state.addTabToSplit("pair", tabId: 5, slot: 0), "Already a pane here")
        XCTAssertFalse(state.addTabToSplit("pair", tabId: 99, slot: 0), "No such tab")
        XCTAssertFalse(state.addTabToSplit("missing", tabId: 7, slot: 0))
        XCTAssertTrue(state.tabsAwaitingSplit.isEmpty)
    }

    func testOpenNewTabIntoSplitRefusesAFullSplit() throws {
        let state = try makeState()
        seed(state, guids: [1, 2, 3, 4])
        state.splits = [SplitGroup(id: "full", tabIds: [1, 2, 3, 4], layout: .vertical,
                                   fractions: SplitGroup.equalFractions(paneCount: 4))]

        XCTAssertFalse(state.openNewTabIntoSplit(splitId: "full", slot: 4, navigateURL: nil))
        XCTAssertFalse(state.openNewTabIntoSplit(splitId: "missing", slot: 0, navigateURL: nil))
    }

    func testSplitWithNewTabIsOfferedUntilTheSplitIsFullPinnedOrNot() throws {
        let state = try makeState()
        seedPinnedSplit(state, liveIds: [1, 2, 3])
        XCTAssertTrue(state.canSplitFocusedTabWithNewTab)

        seedPinnedSplit(state, liveIds: [1, 2, 3, 4])
        XCTAssertFalse(state.canSplitFocusedTabWithNewTab)

        seed(state, guids: [1, 2, 3])
        state.splits = [SplitGroup(id: "s", tabIds: [1, 2, 3], layout: .vertical,
                                   fractions: [0.5, 0.25, 0.25])]
        XCTAssertTrue(state.canSplitFocusedTabWithNewTab)
        state.splits = []
        XCTAssertTrue(state.canSplitFocusedTabWithNewTab, "A plain focused tab")
    }

    func testSplitWithCurrentIsOfferedWhenTheFocusedSplitHasRoom() throws {
        let state = try makeState()
        seed(state, guids: [1, 2, 3, 4, 5])
        let other = try XCTUnwrap(state.tabs.first { $0.guid == 5 })
        XCTAssertTrue(other.canSplitWithFocusedTab(in: state), "Focused tab in no split")

        state.splits = [SplitGroup(id: "s", tabIds: [1, 2], layout: .vertical, fractions: [0.5, 0.5])]
        XCTAssertTrue(other.canSplitWithFocusedTab(in: state))
        let focusedPane = try XCTUnwrap(state.tabs.first { $0.guid == 1 })
        XCTAssertFalse(focusedPane.canSplitWithFocusedTab(in: state), "The focused pane itself")

        state.splits[0].isPinned = true
        XCTAssertTrue(other.canSplitWithFocusedTab(in: state), "A pinned split takes a pane too")

        state.splits = [SplitGroup(id: "s", tabIds: [1, 2, 3, 4], layout: .vertical,
                                   fractions: SplitGroup.equalFractions(paneCount: 4))]
        XCTAssertFalse(other.canSplitWithFocusedTab(in: state), "A full split")

        state.splits = [
            SplitGroup(id: "s", tabIds: [1, 2], layout: .vertical, fractions: [0.5, 0.5]),
            SplitGroup(id: "t", tabIds: [3, 5], layout: .vertical, fractions: [0.5, 0.5]),
        ]
        XCTAssertFalse(other.canSplitWithFocusedTab(in: state), "A pane of another split")
    }

    func testSplitActionRouteCoversEveryFocusAndMembershipCase() {
        let insertion = TabSplitActionRoute.SplitInsertion(splitId: "s", slot: 1)
        func route(selected: Int = 2, focused: Int? = 1, selectedInSplit: Bool = false,
                   focusedInSplit: Bool = false,
                   insertion: TabSplitActionRoute.SplitInsertion? = nil) -> TabSplitActionRoute? {
            TabSplitActionRoute.resolve(selectedTabId: selected, focusedTabId: focused,
                                        selectedTabIsInSplit: selectedInSplit,
                                        focusedTabIsInSplit: focusedInSplit,
                                        focusedSplitInsertion: insertion)
        }
        XCTAssertNil(route(focused: nil))
        XCTAssertEqual(route(selected: 1), .openNewPartner)
        XCTAssertEqual(route(selected: 1, focusedInSplit: true, insertion: insertion), .openNewPane(insertion))
        XCTAssertNil(route(selected: 1, focusedInSplit: true), "Focused split is full")
        XCTAssertEqual(route(), .splitWithFocused(tabId: 1))
        XCTAssertEqual(route(focusedInSplit: true, insertion: insertion), .joinFocusedSplit(insertion))
        XCTAssertNil(route(focusedInSplit: true), "Focused split is full")
        XCTAssertNil(route(selectedInSplit: true), "Selected tab is a pane already")
        XCTAssertNil(route(selectedInSplit: true, focusedInSplit: true, insertion: insertion))
    }

    /// A pane added while the row is on screen reaches the cached item before
    /// the cell has a segment for it; the strip update must not index past
    /// the segments. Regression for a crash during a drag onto a split.
    func testSidebarSplitCellSurvivesAPaneAddedBeforeItRebinds() throws {
        let state = try makeState()
        seed(state, guids: [1, 2, 3])
        let tabs = state.tabs
        let item = SplitSidebarItem(groupId: "s", panes: [tabs[0], tabs[1]], browserState: state)
        let cell = SidebarSplitCellView(frame: NSRect(x: 0, y: 0, width: 320, height: 40))
        cell.configure(with: item)

        // Out of strip order, which is what sent the cell down the reorder path.
        item.panes = [tabs[0], tabs[2], tabs[1]]
        state.normalTabs = state.normalTabs
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        XCTAssertEqual(cell.faviconOpacity(paneIndex: 2), 1, "The cell rebinds to all three panes")
    }

    // MARK: - SplitGroup

    func testNormalizedFractionsScaleSharesToOneAndFallBackToEqualShares() {
        assertEqual(SplitGroup.normalizedFractions([2, 1, 1], paneCount: 3), [0.5, 0.25, 0.25])
        assertEqual(SplitGroup.normalizedFractions([0.3, 0.7], paneCount: 2), [0.3, 0.7])
        assertEqual(SplitGroup.equalFractions(paneCount: 4), [0.25, 0.25, 0.25, 0.25])

        // One share per pane, or the shares are replaced wholesale.
        assertEqual(SplitGroup.normalizedFractions([0.5, 0.5], paneCount: 3), [1.0 / 3, 1.0 / 3, 1.0 / 3])
        assertEqual(SplitGroup.normalizedFractions([], paneCount: 2), [0.5, 0.5])
        assertEqual(SplitGroup.normalizedFractions([0, 0, 0], paneCount: 3), [1.0 / 3, 1.0 / 3, 1.0 / 3])
        assertEqual(SplitGroup.normalizedFractions([-1, 2], paneCount: 2), [0.5, 0.5])
        assertEqual(SplitGroup.normalizedFractions([.nan, 1], paneCount: 2), [0.5, 0.5])
    }

    func testInitNormalisesSharesAndAWiderSplitHasNoPair() throws {
        let three = SplitGroup(id: "three", tabIds: [1, 2, 3], layout: .vertical, fractions: [1, 1, 2])
        assertEqual(three.fractions, [0.25, 0.25, 0.5])
        XCTAssertEqual(three.paneCount, 3)
        XCTAssertFalse(three.isPair)
        XCTAssertTrue(three.canAddPane)
        XCTAssertNil(three.pair?.primary)
        XCTAssertNil(three.pairRatio)
        XCTAssertEqual(three.firstTabId, 1)
        XCTAssertEqual(three.lastTabId, 3)
        XCTAssertEqual(three.slot(of: 2), 1)
        XCTAssertNil(three.slot(of: 9))
        XCTAssertEqual(three.otherTabIds(of: 2), [1, 3])
        XCTAssertEqual(three.otherTabIds(of: 9), [])
        XCTAssertNil(three.pairPartnerTabId(of: 1))

        let pair = SplitGroup(id: "pair", tabIds: [4, 5], layout: .horizontal, fractions: [0.3, 0.7])
        XCTAssertTrue(pair.isPair)
        XCTAssertEqual(pair.pair?.primary, 4)
        XCTAssertEqual(pair.pair?.secondary, 5)
        XCTAssertEqual(try XCTUnwrap(pair.pairRatio), 0.3, accuracy: 1e-9)
        XCTAssertEqual(pair.pairPartnerTabId(of: 5), 4)

        let four = SplitGroup(id: "four", tabIds: [1, 2, 3, 4], layout: .vertical, fractions: [])
        assertEqual(four.fractions, [0.25, 0.25, 0.25, 0.25])
        XCTAssertFalse(four.canAddPane)
    }

    // MARK: - Pane position

    func testPanePositionOfAThreePaneSplitHasAMiddle() throws {
        let state = try makeState()
        seed(state, guids: [1, 2, 3, 4])
        state.splits = [SplitGroup(id: "split-2-3-4", tabIds: [2, 3, 4],
                                   layout: .vertical, fractions: [0.5, 0.25, 0.25])]
        state.updateNormalTabs()

        XCTAssertNil(state.splitPanePosition(forTabId: 1))
        XCTAssertEqual(state.splitPanePosition(forTabId: 2), .first)
        XCTAssertEqual(state.splitPanePosition(forTabId: 3), .middle)
        XCTAssertEqual(state.splitPanePosition(forTabId: 4), .last)
    }

    /// The merged bar assumes physical adjacency: a split whose panes are
    /// not consecutive in `normalTabs` renders as plain tabs instead.
    func testPanePositionIsNilWhileTheSplitIsNotContiguous() throws {
        let state = try makeState()
        seed(state, guids: [1, 2, 3, 4])
        // Bypass `updateNormalTabs` so the adjacency pass does not run.
        state.normalTabs = state.tabs
        state.splits = [SplitGroup(id: "apart", tabIds: [1, 3, 4],
                                   layout: .vertical, fractions: [1, 1, 1])]

        XCTAssertNil(state.splitPanePosition(forTabId: 1))
        XCTAssertNil(state.splitPanePosition(forTabId: 3))
        XCTAssertNil(state.splitPanePosition(forTabId: 4))
        XCTAssertTrue(state.splitRunsInNormalTabs().isEmpty)
    }

    // MARK: - Adjacency

    func testEnforceSplitAdjacencyPullsAThreePaneSplitTogetherInSlotOrder() throws {
        let state = try makeState()
        seed(state, guids: [1, 2, 3, 4, 5])
        // Slot order 4, 2, 5: the run sits where its first pane (4) is.
        state.splits = [SplitGroup(id: "split-4-2-5", tabIds: [4, 2, 5],
                                   layout: .horizontal, fractions: [1, 1, 1])]

        state.updateNormalTabs()

        XCTAssertEqual(state.normalTabs.map(\.guid), [1, 3, 4, 2, 5])
        XCTAssertFalse(state.enforceSplitAdjacency(), "an adjacent split is left alone")
        XCTAssertEqual(state.splitPanePosition(forTabId: 4), .first)
        XCTAssertEqual(state.splitPanePosition(forTabId: 2), .middle)
        XCTAssertEqual(state.splitPanePosition(forTabId: 5), .last)
        XCTAssertEqual(state.splitRunsInNormalTabs().map { [$0.lower, $0.count] }, [[2, 3]])
        XCTAssertEqual(state.splitLastTabIdByMemberMap(), [4: 5, 2: 5, 5: 5])
    }

    // MARK: - Drops around a split

    /// A drop may never land strictly between two panes: for a run at
    /// indices 1...3 the indices 2 and 3 snap past the run on the side the
    /// drag came from.
    func testSnapDropOutsideSplitSkipsTheWholeThreePaneRun() throws {
        let state = try makeState()
        seed(state, guids: [1, 2, 3, 4, 5, 6])
        state.splits = [SplitGroup(id: "split-2-3-4", tabIds: [2, 3, 4],
                                   layout: .vertical, fractions: [1, 1, 1])]
        state.updateNormalTabs()

        // Dragged from before the run: land after it.
        XCTAssertEqual(state.snapDropOutsideSplit(toIndex: 2, fromIndex: 0), 4)
        XCTAssertEqual(state.snapDropOutsideSplit(toIndex: 3, fromIndex: 0), 4)
        // Dragged from after the run: land before it.
        XCTAssertEqual(state.snapDropOutsideSplit(toIndex: 2, fromIndex: 5), 1)
        XCTAssertEqual(state.snapDropOutsideSplit(toIndex: 3, fromIndex: 5), 1)
        // The run's own edges are legal.
        XCTAssertEqual(state.snapDropOutsideSplit(toIndex: 1, fromIndex: 5), 1)
        XCTAssertEqual(state.snapDropOutsideSplit(toIndex: 4, fromIndex: 0), 4)
        XCTAssertEqual(state.snapDropOutsideSplit(toIndex: 0, fromIndex: 5), 0)
        XCTAssertEqual(state.snapDropOutsideSplit(toIndex: 6, fromIndex: 0), 6)
    }

    // MARK: - Membership changes

    /// A pane joining a pair makes a three-pane split: the new member is
    /// placed next to the others, gets an equal share until Chromium's
    /// visuals echo lands, and stops waiting for its split.
    func testContentsChangedGrowsAPairToThreePanes() throws {
        let state = try makeState()
        seed(state, guids: [1, 2, 3, 4])
        state.handleSplitCreated(splitId: "split", tabIds: [1, 2], layout: .vertical, fractions: [0.4, 0.6])
        XCTAssertEqual(state.normalTabs.map(\.guid), [1, 2, 3, 4])
        state.tabsAwaitingSplit.insert(4)

        state.handleSplitContentsChanged(splitId: "split", tabIds: [1, 2, 4])

        let group = try XCTUnwrap(state.splitGroup(forId: "split"))
        XCTAssertEqual(group.tabIds, [1, 2, 4])
        assertEqual(group.fractions, [1.0 / 3, 1.0 / 3, 1.0 / 3])
        XCTAssertFalse(group.isPinned)
        XCTAssertFalse(group.isPair)
        XCTAssertTrue(state.tabsAwaitingSplit.isEmpty)
        XCTAssertEqual(state.normalTabs.map(\.guid), [1, 2, 4, 3])
        XCTAssertEqual(state.splitPanePosition(forTabId: 2), .middle)
        XCTAssertNotNil(state.splitGroup(forTabId: 4))

        // Chromium's shares for the three panes then apply as given.
        state.handleSplitVisualsChanged(splitId: "split", layout: .horizontal, fractions: [0.2, 0.3, 0.5])
        let resized = try XCTUnwrap(state.splitGroup(forId: "split"))
        XCTAssertEqual(resized.layout, .horizontal)
        assertEqual(resized.fractions, [0.2, 0.3, 0.5])

        // Shares that do not match the pane count spread evenly instead.
        state.handleSplitVisualsChanged(splitId: "split", layout: .horizontal, fractions: [0.5, 0.5])
        assertEqual(try XCTUnwrap(state.splitGroup(forId: "split")).fractions, [1.0 / 3, 1.0 / 3, 1.0 / 3])
    }

    /// A pane leaving a three-pane split leaves the other two split, back
    /// to a pair with equal shares, and the survivors stay adjacent.
    func testContentsChangedShrinksAThreePaneSplitToAPair() throws {
        let state = try makeState()
        seed(state, guids: [1, 2, 3, 4])
        state.handleSplitCreated(splitId: "split", tabIds: [1, 2, 3], layout: .vertical, fractions: [0.2, 0.3, 0.5])

        state.handleSplitContentsChanged(splitId: "split", tabIds: [1, 3])

        let group = try XCTUnwrap(state.splitGroup(forId: "split"))
        XCTAssertEqual(group.tabIds, [1, 3])
        XCTAssertTrue(group.isPair)
        XCTAssertEqual(group.pairRatio, 0.5)
        XCTAssertNil(state.splitGroup(forTabId: 2))
        XCTAssertEqual(state.normalTabs.map(\.guid), [1, 3, 2, 4])
        XCTAssertEqual(state.splitPanePosition(forTabId: 1), .first)
        XCTAssertEqual(state.splitPanePosition(forTabId: 3), .last)
        XCTAssertNil(state.splitPanePosition(forTabId: 2))
    }

    // MARK: - Close Tab on a split saved in the sidebar

    /// Close Tab on a pane of a pinned split closes every pane, in a pair
    /// as in a wider split.
    func testCloseTabOnAPinnedSplitPaneClosesTheWholeSplit() throws {
        for liveIds in [[1, 2], [1, 2, 3]] {
            let state = try makeCloseRecordingState()
            seedPinnedSplit(state, liveIds: liveIds)

            XCTAssertTrue(state.closeSplitSavedInSidebar(containingTabId: 2))
            XCTAssertEqual(state.closedTabBatches, [liveIds])
        }
    }

    func testCloseTabOnABookmarkBoundSplitPaneClosesTheWholeSplit() throws {
        let state = try makeCloseRecordingState()
        seed(state, guids: [1, 2, 3])
        state.splits = [SplitGroup(id: "s", tabIds: [2, 3], layout: .vertical, fractions: [0.5, 0.5])]
        state.splitBookmarkBindings["bookmark"] = "s"

        XCTAssertTrue(state.closeSplitSavedInSidebar(containingTabId: 3))
        XCTAssertEqual(state.closedTabBatches, [[2, 3]])
    }

    /// A split in the tab list, and a tab in no split, close the usual way.
    func testCloseTabOnASplitInTheTabListIsLeftToTheCaller() throws {
        let state = try makeCloseRecordingState()
        seed(state, guids: [1, 2, 3])
        state.splits = [SplitGroup(id: "s", tabIds: [1, 2], layout: .vertical, fractions: [0.5, 0.5])]

        XCTAssertFalse(state.closeSplitSavedInSidebar(containingTabId: 1))
        XCTAssertFalse(state.closeSplitSavedInSidebar(containingTabId: 3))
        XCTAssertEqual(state.closedTabBatches, [])
    }

    /// A pane that leaves while the split, window or app closes keeps its
    /// pinned record in the split.
    func testPaneLeavingKeepsThePinnedSplitRecords() throws {
        let state = try makeState()
        seedPinnedSplit(state, liveIds: [1, 2, 3])

        state.handleSplitContentsChanged(splitId: "pinned", tabIds: [1, 3])

        XCTAssertEqual(state.pinnedTabs.map(\.splitPaneGuids),
                       Array(repeating: ["db-1", "db-2", "db-3"], count: 3))
    }

    func testReorderingAPinnedSplitResequencesItsRecords() throws {
        let state = try makeState()
        seedPinnedSplit(state, liveIds: [1, 2, 3])

        state.handleSplitContentsChanged(splitId: "pinned", tabIds: [3, 1, 2])

        XCTAssertEqual(state.pinnedTabs.map(\.splitPaneGuids),
                       Array(repeating: ["db-3", "db-1", "db-2"], count: 3))
    }

    /// A reorder keeps the shares (one per pane) and re-sequences the strip.
    func testContentsChangedReordersThePanesAndKeepsTheirShares() throws {
        let state = try makeState()
        seed(state, guids: [1, 2, 3])
        state.handleSplitCreated(splitId: "split", tabIds: [1, 2, 3], layout: .vertical, fractions: [0.2, 0.3, 0.5])

        state.handleSplitContentsChanged(splitId: "split", tabIds: [3, 1, 2])

        let group = try XCTUnwrap(state.splitGroup(forId: "split"))
        XCTAssertEqual(group.tabIds, [3, 1, 2])
        assertEqual(group.fractions, [0.2, 0.3, 0.5])
        XCTAssertEqual(state.normalTabs.map(\.guid), [3, 1, 2])
    }

    func testSplitCreatedIgnoresASinglePaneAndKeepsUpToFourPanes() throws {
        let state = try makeState()
        seed(state, guids: [1, 2, 3, 4, 5])

        state.handleSplitCreated(splitId: "lonely", tabIds: [1], layout: .vertical, fractions: [1])
        XCTAssertTrue(state.splits.isEmpty)

        state.handleSplitCreated(splitId: "wide", tabIds: [5, 4, 3, 2], layout: .vertical,
                                 fractions: [0.1, 0.2, 0.3, 0.4])
        let group = try XCTUnwrap(state.splitGroup(forId: "wide"))
        XCTAssertEqual(group.tabIds, [5, 4, 3, 2])
        XCTAssertFalse(group.canAddPane)
        XCTAssertEqual(state.normalTabs.map(\.guid), [1, 5, 4, 3, 2])
        XCTAssertEqual(state.splitPanePosition(forTabId: 4), .middle)
        XCTAssertEqual(state.splitPanePosition(forTabId: 3), .middle)
        XCTAssertFalse(state.isSplitMembersAllPinned(tabIds: group.tabIds), "none of these panes is pinned")
    }

    // MARK: - Persisted wider splits

    func testSplitBookmarkFieldsPutPanesAfterTheSecondInExtraPanes() throws {
        let fields = try XCTUnwrap(SplitBookmarkFields(panes: [
            (url: "https://a.example/", title: "A"),
            (url: "https://b.example/", title: "A"),
            (url: "https://c.example/", title: "C"),
            (url: "https://d.example/", title: ""),
        ]))
        XCTAssertEqual(fields.title, "A")
        XCTAssertEqual(fields.url, "https://a.example/")
        XCTAssertEqual(fields.secondaryUrl, "https://b.example/")
        XCTAssertNil(fields.secondaryTitle, "A title repeating the first pane's is dropped")
        XCTAssertEqual(fields.extraPanes, [
            SplitBookmarkExtraPane(url: "https://c.example/", title: "C"),
            SplitBookmarkExtraPane(url: "https://d.example/", title: nil),
        ])
    }

    func testSplitBookmarkFieldsRejectAPaneWithoutAURLAndOddCounts() {
        XCTAssertNil(SplitBookmarkFields(panes: [(url: "https://a.example/", title: "A")]))
        XCTAssertNil(SplitBookmarkFields(panes: [
            (url: "https://a.example/", title: "A"),
            (url: nil, title: "B"),
        ]))
    }

    func testBookmarkListsEveryPaneInSlotOrder() {
        let bookmark = Bookmark(title: "A",
                                url: "https://a.example/",
                                secondaryUrl: "https://b.example/",
                                secondaryTitle: "B",
                                splitExtraPanes: [SplitBookmarkExtraPane(url: "https://c.example/", title: nil)])
        XCTAssertEqual(bookmark.splitPaneURLs,
                       ["https://a.example/", "https://b.example/", "https://c.example/"])
        XCTAssertEqual(bookmark.representedTabCount, 3)
        XCTAssertEqual(Bookmark(title: "Solo", url: "https://a.example/").representedTabCount, 1)
    }

    func testSplitPaneColumnCodingTreatsEmptyAndDamagedTextAsNoPanes() {
        XCTAssertNil(SplitPaneColumnCoding.encode([String]()))
        XCTAssertEqual(SplitPaneColumnCoding.decode(nil) as [String], [])
        XCTAssertEqual(SplitPaneColumnCoding.decode("not json") as [String], [])
        let encoded = SplitPaneColumnCoding.encode(["a", "b", "c"])
        XCTAssertEqual(SplitPaneColumnCoding.decode(encoded) as [String], ["a", "b", "c"])
    }
}

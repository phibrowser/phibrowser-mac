// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
import Combine
@testable import Phi

/// Regression guard for closing a pinned split right after moving it into the
/// pinned area.
///
/// Repro: a live split is pinned (`pinSplitInsertingAtPinnedIndex`), which
/// persists `splitPartnerGuid` to the store asynchronously. The in-memory
/// pinned records only learn the partner on a later publisher emission. If the
/// user closes the split before that echo lands, the live `SplitGroup` is
/// removed (`handleSplitRemoved`) while the records are still unlinked — and
/// the merged pinned-split cell splinters into two separate pinned tabs.
///
/// These tests assert the linkage survives the live group's removal so the
/// pair keeps resolving as one merged cell via `pinnedSplitDBGuids`.
@MainActor
final class BrowserStatePinnedSplitCloseTests: XCTestCase {
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
        return BrowserState(windowId: 11, localStore: store, profileId: "Default")
    }

    /// Build the post-pin in-memory state: two live panes bound to two pinned
    /// records and a live `isPinned` `SplitGroup`, but with the pinned records
    /// NOT yet carrying `splitPartnerGuid` (the partner write is still in
    /// flight, so the publisher delivered them unlinked).
    private func seedFreshlyPinnedSplit(_ state: BrowserState,
                                        leftDB: String = "db-left",
                                        rightDB: String = "db-right") -> (left: Tab, right: Tab) {
        let leftPinned = Tab(guid: 100, url: "https://left.example",
                             isActive: true, index: 0, customGuid: leftDB)
        let rightPinned = Tab(guid: 101, url: "https://right.example",
                              isActive: false, index: 1, customGuid: rightDB)
        leftPinned.isOpenned = true
        rightPinned.isOpenned = true
        state.pinnedTabs = [leftPinned, rightPinned]

        let leftLive = Tab(guid: 100, url: "https://left.example",
                           isActive: true, index: 0, customGuid: leftDB)
        let rightLive = Tab(guid: 101, url: "https://right.example",
                            isActive: false, index: 1, customGuid: rightDB)
        leftLive.isPinned = true
        rightLive.isPinned = true
        state.tabs = [leftLive, rightLive]
        state.splits = [
            SplitGroup(id: "split-100-101",
                       tabIds: [100, 101],
                       layout: .vertical,
                       fractions: [0.5, 0.5],
                       isPinned: true)
        ]
        state.updateNormalTabs()
        return (leftPinned, rightPinned)
    }

    /// While the live pinned group exists the pair already resolves; the bug
    /// only surfaces once the group is gone, so guard that precondition.
    func test_livePinnedSplitResolvesAsOneCell() throws {
        let state = try makeState()
        let (leftPinned, _) = seedFreshlyPinnedSplit(state)
        XCTAssertNotNil(state.pinnedSplitDBGuids(forPinnedTab: leftPinned),
                        "A live pinned split should resolve as one merged cell")
    }

    /// The core regression: closing the split (which removes the live group)
    /// right after pinning must keep the two pinned records linked so they
    /// stay one merged cell instead of breaking into two pinned tabs.
    func test_closingPinnedSplitRightAfterPinKeepsItMerged() throws {
        let state = try makeState()
        let (leftPinned, rightPinned) = seedFreshlyPinnedSplit(state)

        // User closes the pinned split: Chromium dissolves the underlying
        // split (split-removed event) and both live panes go away.
        state.handleSplitRemoved(splitId: "split-100-101")
        leftPinned.isOpenned = false
        rightPinned.isOpenned = false
        state.tabs = []

        // The pair must still resolve as one merged cell, ordered (left, right).
        let pair = state.pinnedSplitDBGuids(forPinnedTab: leftPinned)
        XCTAssertEqual(pair?[0], "db-left",
                       "Pinned split must stay merged after close, not split into two tabs")
        XCTAssertEqual(pair?[1], "db-right")
        XCTAssertEqual(leftPinned.splitPartnerGuid, "db-right")
        XCTAssertEqual(rightPinned.splitPartnerGuid, "db-left")

        // Resolving from the right record yields the same ordered pair.
        let mirror = state.pinnedSplitDBGuids(forPinnedTab: rightPinned)
        XCTAssertEqual(mirror?[0], "db-left")
        XCTAssertEqual(mirror?[1], "db-right")
    }

    /// End-to-end repro through the real drag-to-pin entry point. Dragging a
    /// split onto the pinned area calls `pinSplitInsertingAtPinnedIndex`
    /// (PinnedTabViewController.handleNormalTabDropToFavorites), which writes
    /// the two pinned records and their `splitPartnerGuid` to the store
    /// asynchronously. We wait only until the records materialize — the
    /// partner-guid write is still in flight at that instant — then close the
    /// split and assert immediately, before the partner write can echo back.
    /// Without the fix the records are unlinked at that moment and the merged
    /// cell breaks into two pinned tabs.
    func test_dragPinThenImmediateCloseKeepsItMerged() throws {
        let state = try makeState()

        // Two live tabs forming a non-pinned split, as right before a
        // drag-to-pinned-area drop.
        let leftLive = Tab(guid: 200, url: "https://l.example", isActive: true, index: 0)
        let rightLive = Tab(guid: 201, url: "https://r.example", isActive: false, index: 1)
        state.tabs = [leftLive, rightLive]
        state.splits = [
            SplitGroup(id: "split-200-201", tabIds: [200, 201],
                       layout: .vertical, fractions: [0.5, 0.5])
        ]
        state.updateNormalTabs()

        // Drag-to-pin: exactly what handleNormalTabDropToFavorites calls for a
        // split. Records + partner guid are persisted asynchronously.
        state.pinSplitInsertingAtPinnedIndex("split-200-201", atIndex: 0)

        // Wait only until both pinned records exist (the create-writes echoed).
        // The partner-guid writes are queued right after and have NOT echoed
        // to the in-memory records yet.
        let appeared = expectation(description: "pinned records materialize")
        appeared.assertForOverFulfill = false
        let cancellable = state.$pinnedTabs.sink { tabs in
            if tabs.count == 2 { appeared.fulfill() }
        }
        wait(for: [appeared], timeout: 5)
        cancellable.cancel()

        guard let leftDB = leftLive.guidInLocalDB, let rightDB = rightLive.guidInLocalDB else {
            return XCTFail("Live panes did not bind to pinned-record guids")
        }

        // Close the pinned split right away: Chromium dissolves the split and
        // both panes go away. Assert synchronously, before returning to the
        // run loop lets the partner-guid write echo and "heal" the linkage.
        state.handleSplitRemoved(splitId: "split-200-201")
        state.tabs = []

        guard let leftPinned = state.pinnedTabs.first(where: { $0.guidInLocalDB == leftDB }) else {
            return XCTFail("Left pinned record missing after close")
        }
        let pair = state.pinnedSplitDBGuids(forPinnedTab: leftPinned)
        XCTAssertEqual(pair?[0], leftDB,
                       "Pinned split broke into two tabs after closing right after drag-to-pin")
        XCTAssertEqual(pair?[1], rightDB)
    }

    /// Relaunch repro: only one direction of `splitPartnerGuid` reached disk
    /// before quit (linked->unlinked persisted, the reverse write was dropped),
    /// so the pair restores half-linked with the UNLINKED record sorted first.
    /// Pairing must still resolve as one split from either side — otherwise the
    /// first paint on relaunch splinters the merged cell into two pinned tabs
    /// (the "shows two cells, then merges" bug).
    func test_halfPersistedSplitPartnerStillResolvesAsPair() throws {
        let state = try makeState()
        // Unlinked record sorts first (index 0); only its partner carries the
        // persisted link.
        let unlinked = Tab(guid: 300, url: "https://u.example",
                           isActive: false, index: 0, customGuid: "db-unlinked")
        let linked = Tab(guid: 301, url: "https://l.example",
                         isActive: false, index: 1, customGuid: "db-linked")
        unlinked.isOpenned = false
        linked.isOpenned = false
        linked.splitPartnerGuid = "db-unlinked"   // reverse link only
        state.pinnedTabs = [unlinked, linked]

        let fromUnlinked = state.pinnedSplitDBGuids(forPinnedTab: unlinked)
        XCTAssertEqual(fromUnlinked?[0], "db-unlinked",
                       "Half-persisted pinned split must still resolve as one pair")
        XCTAssertEqual(fromUnlinked?[1], "db-linked")
        let fromLinked = state.pinnedSplitDBGuids(forPinnedTab: linked)
        XCTAssertEqual(fromLinked?[0], "db-unlinked")
        XCTAssertEqual(fromLinked?[1], "db-linked")
    }

    func testClosedPinnedSplitLayoutDefaultsAndConvertsInMemory() throws {
        let state = try makeState()
        let left = Tab(guid: 350, url: "https://left.example",
                       isActive: false, index: 0, customGuid: "db-left")
        let right = Tab(guid: 351, url: "https://right.example",
                        isActive: false, index: 1, customGuid: "db-right")
        left.splitPartnerGuid = "db-right"
        right.splitPartnerGuid = "db-left"
        state.pinnedTabs = [left, right]

        XCTAssertEqual(state.pinnedSplitLayout(dbGuids: ["db-left", "db-right"]),
                       .vertical)

        state.updatePinnedSplitLayout(dbGuids: ["db-left", "db-right"],
                                      layout: .horizontal)

        XCTAssertEqual(left.splitLayout, .horizontal)
        XCTAssertEqual(right.splitLayout, .horizontal)
        XCTAssertEqual(state.pinnedSplitLayout(dbGuids: ["db-left", "db-right"]),
                       .horizontal)
    }

    /// A pinned split of three panes is one unit from any of its records,
    /// including a record whose copy of the list has not landed yet.
    func test_widerPinnedSplitResolvesEveryPaneFromAnyRecord() throws {
        let state = try makeState()
        let first = Tab(guid: 500, url: "https://a.example", isActive: false, index: 0, customGuid: "db-a")
        let second = Tab(guid: 501, url: "https://b.example", isActive: false, index: 1, customGuid: "db-b")
        let third = Tab(guid: 502, url: "https://c.example", isActive: false, index: 2, customGuid: "db-c")
        first.isOpenned = false
        second.isOpenned = false
        third.isOpenned = false
        first.splitPaneGuids = ["db-a", "db-b", "db-c"]
        second.splitPaneGuids = ["db-a", "db-b", "db-c"]
        state.pinnedTabs = [first, second, third]

        for record in [first, second, third] {
            XCTAssertEqual(state.pinnedSplitDBGuids(forPinnedTab: record), ["db-a", "db-b", "db-c"])
        }
        XCTAssertEqual(state.splitMembership(forCellTab: third)?.paneCount, 3)
    }

    /// Closing a pane of a pinned split shrinks the live group but not the
    /// record: the merged cell keeps the pane and reopens it on the next click.
    func test_widerPinnedSplitRecordKeepsClosedPane() throws {
        let state = try makeState()
        let records = ["db-a", "db-b", "db-c"].enumerated().map { index, db -> Tab in
            let record = Tab(guid: 600 + index, url: "https://\(db).example",
                             isActive: false, index: index, customGuid: db)
            record.splitPaneGuids = ["db-a", "db-b", "db-c"]
            record.splitLayout = .vertical
            return record
        }
        state.pinnedTabs = records
        let live = ["db-a", "db-b"].enumerated().map { index, db -> Tab in
            let tab = Tab(guid: 600 + index, url: "https://\(db).example",
                          isActive: index == 0, index: index, customGuid: db)
            tab.isPinned = true
            return tab
        }
        state.tabs = live
        state.splits = [SplitGroup(id: "split-600-601", tabIds: [600, 601], layout: .vertical,
                                   fractions: [0.5, 0.5], isPinned: true)]

        state.reconcilePinnedSplitPartners()

        XCTAssertEqual(records[2].splitPaneGuids, ["db-a", "db-b", "db-c"])
        XCTAssertEqual(state.pinnedSplitDBGuids(forPinnedTab: records[0]), ["db-a", "db-b", "db-c"])
    }

    /// During restore, one pinned-split pane can be live and focused before
    /// Chromium reports the recreated `SplitGroup`. Option-clicking another
    /// tab in that window must not treat the focused pane as a plain tab and
    /// dismantle its persisted pinned pair.
    func testOptionSplitRejectsFocusedPaneFromPersistedPinnedSplitDuringRestore() throws {
        let state = try makeState()
        let leftPinned = Tab(guid: 400, url: "https://left.example",
                             isActive: true, index: 0, customGuid: "db-left")
        let rightPinned = Tab(guid: 401, url: "https://right.example",
                              isActive: false, index: 1, customGuid: "db-right")
        leftPinned.splitPartnerGuid = "db-right"
        rightPinned.splitPartnerGuid = "db-left"
        state.pinnedTabs = [leftPinned, rightPinned]

        let focusedLive = Tab(guid: 400, url: "https://left.example",
                              isActive: true, index: 0, customGuid: "db-left")
        let selectedTab = Tab(guid: 402, url: "https://selected.example",
                              isActive: false, index: 1)
        state.tabs = [focusedLive, selectedTab]
        state.splits = []
        state.updateNormalTabs()
        state.focusingTab = focusedLive

        XCTAssertFalse(selectedTab.performSplitAction(in: state))
        XCTAssertEqual(leftPinned.splitPartnerGuid, "db-right")
        XCTAssertEqual(rightPinned.splitPartnerGuid, "db-left")
        XCTAssertEqual(state.pinnedSplitDBGuids(forPinnedTab: leftPinned)?[0], "db-left")
        XCTAssertEqual(state.pinnedSplitDBGuids(forPinnedTab: leftPinned)?[1], "db-right")
        XCTAssertEqual(focusedLive.guidInLocalDB, "db-left")
    }

    /// Keep the direct live-group guard as well: while Chromium is reporting
    /// a split, its partner can be absent from `tabs` briefly, which prevents
    /// `splitMembership` from constructing a complete pane pair.
    func testOptionSplitRejectsFocusedIncompleteLiveGroup() throws {
        let state = try makeState()
        let focusedTab = Tab(guid: 500, url: "https://focused.example",
                             isActive: true, index: 0)
        let selectedTab = Tab(guid: 502, url: "https://selected.example",
                              isActive: false, index: 1, customGuid: "bookmark-selected")
        state.tabs = [focusedTab, selectedTab]
        state.splits = [
            SplitGroup(id: "split-500-501",
                       tabIds: [500, 501],
                       layout: .vertical,
                       fractions: [0.5, 0.5])
        ]
        state.updateNormalTabs()
        state.focusingTab = focusedTab

        XCTAssertFalse(selectedTab.performSplitAction(in: state))
        XCTAssertEqual(selectedTab.guidInLocalDB, "bookmark-selected")
    }

    /// The clicked tab needs the same fail-closed behavior when its live
    /// group's partner has not reached `tabs` yet.
    func testOptionSplitRejectsSelectedIncompleteLiveGroup() throws {
        let state = try makeState()
        let selectedTab = Tab(guid: 600, url: "https://selected.example",
                              isActive: false, index: 0, customGuid: "bookmark-selected")
        let focusedTab = Tab(guid: 602, url: "https://focused.example",
                             isActive: true, index: 1)
        state.tabs = [selectedTab, focusedTab]
        state.splits = [
            SplitGroup(id: "split-600-601",
                       tabIds: [600, 601],
                       layout: .vertical,
                       fractions: [0.5, 0.5])
        ]
        state.updateNormalTabs()
        state.focusingTab = focusedTab

        XCTAssertFalse(selectedTab.performSplitAction(in: state))
        XCTAssertEqual(selectedTab.guidInLocalDB, "bookmark-selected")
    }
}

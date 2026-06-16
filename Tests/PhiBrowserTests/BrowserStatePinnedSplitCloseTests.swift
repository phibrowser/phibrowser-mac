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
/// pair keeps resolving as one merged cell via `pinnedSplitDBPair`.
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
                       primaryTabId: 100,
                       secondaryTabId: 101,
                       layout: .vertical,
                       ratio: 0.5,
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
        XCTAssertNotNil(state.pinnedSplitDBPair(forPinnedTab: leftPinned),
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
        let pair = state.pinnedSplitDBPair(forPinnedTab: leftPinned)
        XCTAssertEqual(pair?.0, "db-left",
                       "Pinned split must stay merged after close, not split into two tabs")
        XCTAssertEqual(pair?.1, "db-right")
        XCTAssertEqual(leftPinned.splitPartnerGuid, "db-right")
        XCTAssertEqual(rightPinned.splitPartnerGuid, "db-left")

        // Resolving from the right record yields the same ordered pair.
        let mirror = state.pinnedSplitDBPair(forPinnedTab: rightPinned)
        XCTAssertEqual(mirror?.0, "db-left")
        XCTAssertEqual(mirror?.1, "db-right")
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
            SplitGroup(id: "split-200-201", primaryTabId: 200, secondaryTabId: 201,
                       layout: .vertical, ratio: 0.5)
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
        let pair = state.pinnedSplitDBPair(forPinnedTab: leftPinned)
        XCTAssertEqual(pair?.0, leftDB,
                       "Pinned split broke into two tabs after closing right after drag-to-pin")
        XCTAssertEqual(pair?.1, rightDB)
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

        let fromUnlinked = state.pinnedSplitDBPair(forPinnedTab: unlinked)
        XCTAssertEqual(fromUnlinked?.0, "db-unlinked",
                       "Half-persisted pinned split must still resolve as one pair")
        XCTAssertEqual(fromUnlinked?.1, "db-linked")
        let fromLinked = state.pinnedSplitDBPair(forPinnedTab: linked)
        XCTAssertEqual(fromLinked?.0, "db-unlinked")
        XCTAssertEqual(fromLinked?.1, "db-linked")
    }
}

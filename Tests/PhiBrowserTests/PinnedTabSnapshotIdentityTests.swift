// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

private enum PinnedTabSnapshotTestSection: Hashable {
    case tabs
}

@MainActor
final class PinnedTabSnapshotIdentityTests: XCTestCase {
    func testSnapshotItemKeepsCapturedIdentityWhenDatabaseGuidIsRebound() {
        let tab = Tab(
            url: "https://example.com",
            isActive: false,
            index: 0,
            customGuid: "profile-guid"
        )
        let profileItem = PinnedTabViewController.PinnedTabSnapshotItem(tab: tab)
        let identifiers = Set([profileItem])

        tab.guidInLocalDB = "app-guid"

        XCTAssertEqual(profileItem.identifier, "profile-guid")
        XCTAssertTrue(identifiers.contains(profileItem))
        XCTAssertTrue(profileItem.tab === tab)

        let appItem = PinnedTabViewController.PinnedTabSnapshotItem(tab: tab)
        XCTAssertEqual(appItem.identifier, "app-guid")
        XCTAssertNotEqual(profileItem, appItem)
    }

    func testDiffableSnapshotAppliesReboundTabsInReversedOrder() {
        let collectionView = NSCollectionView(
            frame: NSRect(x: 0, y: 0, width: 200, height: 200)
        )
        collectionView.collectionViewLayout = NSCollectionViewFlowLayout()
        let dataSource = NSCollectionViewDiffableDataSource<
            PinnedTabSnapshotTestSection,
            PinnedTabViewController.PinnedTabSnapshotItem
        >(collectionView: collectionView) { _, _, _ in
            NSCollectionViewItem()
        }

        let firstTab = makeTab(guid: "profile-a", index: 0)
        let secondTab = makeTab(guid: "profile-b", index: 1)
        var initialSnapshot = NSDiffableDataSourceSnapshot<
            PinnedTabSnapshotTestSection,
            PinnedTabViewController.PinnedTabSnapshotItem
        >()
        initialSnapshot.appendSections([.tabs])
        initialSnapshot.appendItems([
            PinnedTabViewController.PinnedTabSnapshotItem(tab: firstTab),
            PinnedTabViewController.PinnedTabSnapshotItem(tab: secondTab),
        ])
        dataSource.apply(initialSnapshot, animatingDifferences: false)

        firstTab.guidInLocalDB = "app-a"
        secondTab.guidInLocalDB = "app-b"
        var appSnapshot = NSDiffableDataSourceSnapshot<
            PinnedTabSnapshotTestSection,
            PinnedTabViewController.PinnedTabSnapshotItem
        >()
        appSnapshot.appendSections([.tabs])
        appSnapshot.appendItems([
            PinnedTabViewController.PinnedTabSnapshotItem(tab: secondTab),
            PinnedTabViewController.PinnedTabSnapshotItem(tab: firstTab),
        ])
        dataSource.apply(appSnapshot, animatingDifferences: true)

        XCTAssertEqual(
            dataSource.snapshot().itemIdentifiers.map(\.identifier),
            ["app-b", "app-a"]
        )
    }

    private func makeTab(guid: String, index: Int) -> Tab {
        Tab(
            url: "https://example.com/\(index)",
            isActive: false,
            index: index,
            customGuid: guid
        )
    }
}

// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

/// Sidebar diffable-snapshot identity contract: identifiers remain stable while retained
/// by the data source. Mac B, 2026-09-15 01:20:27, build 825: switching Profile scope
/// to Space, then unpinning two seconds later, crashed with an uncaught Objective-C
/// exception in -[__NSDiffableDataSource _applyDifferencesFromSnapshot:]. The store
/// had no duplicate guid or (space, lineage), so the duplication existed only in memory.
///
/// The retained snapshot's identifiers mutated: Item.tabItem hashed Tab.guidInLocalDB,
/// a mutable property on a reference type. Scope migration rebindPinnedTabAfterScopeMigrationIfNeeded
/// in BrowserState+PinnedTabScope.swift changes it in place to preserve live WebContents.
/// Members then occupied the wrong hash buckets, and the next Foundation diff reported
/// duplicate identifiers and threw.
@MainActor
final class PhiSyncPinnedTabSnapshotIdentityTests: XCTestCase {
    private func makeTab(chromiumGuid: Int, rowGuid: String) -> Tab {
        Tab(guid: chromiumGuid,
            url: "https://example.test/\(rowGuid)",
            isActive: false,
            index: 0,
            title: rowGuid,
            customGuid: rowGuid)
    }

    /// ① An existing item's identifier remains unchanged after in-place physical-row migration.
    /// Set.contains checks the hash bucket before equality, as the retained snapshot does.
    /// The old implementation returned not found here, exposing an already-corrupt ordered set.
    func testAnItemIdentifierSurvivesAScopeMigrationRebind() throws {
        let tab = makeTab(chromiumGuid: 1, rowGuid: "row-old")
        let item = PinnedTabViewController.Item.tab(tab)
        let applied: Set<PinnedTabViewController.Item> = [item]

        // Scope migration points the same Tab object at a newly created physical row.
        tab.guidInLocalDB = "row-new"

        XCTAssertTrue(applied.contains(item),
                      "① An item's identifier freezes at creation and cannot change during migration")
        XCTAssertEqual(PinnedTabViewController.Item.tab(tab), PinnedTabViewController.Item.tab(tab),
                       "② Two new items for the same tab still agree on the new identifier")
    }

    /// ② Two existing items stay distinct after one Tab is rebound to the other's row.
    /// During the incident, migration rewrote guidInLocalDB values sequentially, temporarily
    /// giving two objects the same value. Previously their retained identifiers became equal,
    /// and NSOrderedSet diffing threw on the duplicate.
    func testTwoItemsStayDistinctAfterOneTabIsReboundOntoTheOthersRow() throws {
        let first = makeTab(chromiumGuid: 1, rowGuid: "row-a")
        let second = makeTab(chromiumGuid: 2, rowGuid: "row-b")
        let firstItem = PinnedTabViewController.Item.tab(first)
        let secondItem = PinnedTabViewController.Item.tab(second)
        XCTAssertNotEqual(firstItem, secondItem, "① The initial items are distinct")

        first.guidInLocalDB = "row-b"

        XCTAssertNotEqual(firstItem, secondItem,
                          "② Rebinding preserves distinct identifiers; they do not follow the rows")
        XCTAssertEqual(Set([firstItem, secondItem]).count, 2,
                       "③ The set still contains two items without an identifier collision")
    }

    /// ③ Identifiers that should be equal remain equal: freeze the timing, not the equality rule.
    func testTwoItemsForTheSameRowRemainEqual() throws {
        let tab = makeTab(chromiumGuid: 1, rowGuid: "row-a")
        let other = makeTab(chromiumGuid: 2, rowGuid: "row-a")
        XCTAssertEqual(PinnedTabViewController.Item.tab(tab),
                       PinnedTabViewController.Item.tab(other),
                       "Two runtime objects for one physical row still share one identifier")
    }

    /// ④ Follower timeline, Mac A, 2026-09-15 16:20–16:24: account scope becomes Space;
    /// applyAccountPinnedTabScope → changePinnedTabScope rebinds Tabs at 16:20:57. Parked
    /// entities apply at 16:21:56 (applied=5); two minutes later the remote unpin triggers
    /// a sidebar rebuild and crash.
    /// At the identifier level, the retained pre-rebind item must remain findable, while
    /// the rebuilt item has a different identifier. Diffing sees a real delete/add, never
    /// two identifiers collapsing into one.
    func testAFollowerRebindThenALaterRebuildYieldsTwoDistinctIdentifiers() throws {
        let tab = makeTab(chromiumGuid: 7, rowGuid: "row-profile")
        let applied = PinnedTabViewController.Item.tab(tab)
        var retainedSnapshot: Set<PinnedTabViewController.Item> = [applied]

        // 16:20:57 follower migration: the same object points at the new Space row.
        tab.guidInLocalDB = "row-space"
        XCTAssertTrue(retainedSnapshot.contains(applied),
                      "① The retained snapshot identifier does not follow the row")

        // 16:21:56 parked entities apply and the sidebar rebuilds its items.
        let rebuilt = PinnedTabViewController.Item.tab(tab)
        XCTAssertNotEqual(applied, rebuilt, "② The rebuilt item identifies the new row")
        retainedSnapshot.insert(rebuilt)
        XCTAssertEqual(retainedSnapshot.count, 2,
                       "③ Old and new items stay distinct so diffing sees a delete and an add")
    }

    /// ⑤ Defense: applySnapshot drops and counts duplicate identifiers without throwing.
    /// The preceding cases prevent duplicates; this ensures an upstream defect omits a cell
    /// rather than terminates the app. NSDiffableDataSourceSnapshot throws an uncaught
    /// exception for duplicate identifiers instead of ignoring them.
    func testDuplicateIdentifiersAreDroppedInsteadOfReachingTheSnapshot() throws {
        let first = makeTab(chromiumGuid: 1, rowGuid: "row-a")
        let copyOfFirst = makeTab(chromiumGuid: 2, rowGuid: "row-a")
        let second = makeTab(chromiumGuid: 3, rowGuid: "row-b")
        let items = [
            PinnedTabViewController.Item.tab(first),
            PinnedTabViewController.Item.tab(copyOfFirst),
            PinnedTabViewController.Item.tab(second),
        ]

        var seen = Set<PinnedTabViewController.Item>()
        var dropped = 0
        let unique = PinnedTabViewController.deduplicatedItems(items, seen: &seen, dropped: &dropped)

        XCTAssertEqual(unique.count, 2, "① The duplicate is dropped")
        XCTAssertEqual(dropped, 1, "② The drop count is recorded; the log reports only this count")
        XCTAssertEqual(unique.first, PinnedTabViewController.Item.tab(first), "③ The first item is retained")
    }

    /// ⑥ Share seen across sections: NSDiffableDataSourceSnapshot requires identifiers
    /// to be unique across the whole snapshot, not merely within each section.
    func testTheSeenSetIsSharedAcrossSections() throws {
        let model = PinnedTabItemModel(id: "ext-1", title: "Ext", icon: nil)
        var seen = Set<PinnedTabViewController.Item>()
        var dropped = 0

        _ = PinnedTabViewController.deduplicatedItems([.extensionItem(model)],
                                                      seen: &seen, dropped: &dropped)
        let second = PinnedTabViewController.deduplicatedItems([.extensionItem(model)],
                                                               seen: &seen, dropped: &dropped)

        XCTAssertTrue(second.isEmpty, "① The duplicate in the second section is excluded")
        XCTAssertEqual(dropped, 1, "② It counts as one dropped item")
    }
}

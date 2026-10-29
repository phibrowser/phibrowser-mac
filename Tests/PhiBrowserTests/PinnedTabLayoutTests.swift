// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

/// Serves fixed item counts for the extensions and tabs sections.
private final class FixedCountDataSource: NSObject, NSCollectionViewDataSource {
    let extensionCount: Int
    let tabCount: Int

    init(extensionCount: Int, tabCount: Int) {
        self.extensionCount = extensionCount
        self.tabCount = tabCount
    }

    func numberOfSections(in collectionView: NSCollectionView) -> Int { 2 }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        section == PinnedTabLayout.Section.extensions.rawValue ? extensionCount : tabCount
    }

    func collectionView(_ collectionView: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        NSCollectionViewItem()
    }
}

/// The sidebar band's height is the sum its sidebars rely on to keep 8 pt
/// around it: its insets plus the grid, with 28 pt extension rows, 45 pt tab
/// rows and 8 pt between sections. One row of each at this width.
@MainActor
final class PinnedTabLayoutTests: XCTestCase {
    private static let width: CGFloat = 259

    /// Lays the grid out once; the layout keeps the computed height and
    /// frames after the collection view it measured goes away.
    private func prepared(_ layout: PinnedTabLayout, extensions: Int, tabs: Int) -> PinnedTabLayout {
        let dataSource = FixedCountDataSource(extensionCount: extensions, tabCount: tabs)
        let collectionView = NSCollectionView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 200))
        collectionView.dataSource = dataSource
        collectionView.collectionViewLayout = layout
        collectionView.reloadData()
        layout.configure(parentWidth: Self.width, tabCount: tabs, extensionCount: extensions)
        layout.prepare()
        return layout
    }

    func testSidebarBandWithOnlyExtensionsIsInsetPlusOneRow() {
        let layout = prepared(PinnedTabLayout(topInset: 5, bottomInset: 6), extensions: 3, tabs: 0)
        XCTAssertEqual(layout.contentHeight, 5 + 28 + 6)
    }

    func testSidebarBandWithOnlyTabsStartsItsFirstRowAtTheTopInset() {
        let layout = prepared(PinnedTabLayout(topInset: 5, bottomInset: 6), extensions: 0, tabs: 2)
        XCTAssertEqual(layout.contentHeight, 5 + 45 + 6)
        let firstTab = layout.layoutAttributesForItem(
            at: IndexPath(item: 0, section: PinnedTabLayout.Section.tabs.rawValue))
        XCTAssertEqual(firstTab?.frame.minY, 5,
                       "The top inset leaves room for a corner badge overhanging the first row")
    }

    func testSidebarBandWithBothSectionsSpacesThemBySectionSpacing() {
        let layout = prepared(PinnedTabLayout(topInset: 5, bottomInset: 6), extensions: 3, tabs: 2)
        XCTAssertEqual(layout.contentHeight, 5 + 28 + 8 + 45 + 6)
    }

    func testEmptyBandCollapsesToZero() {
        let layout = prepared(PinnedTabLayout(topInset: 5, bottomInset: 6), extensions: 0, tabs: 0)
        XCTAssertEqual(layout.contentHeight, 0)
    }

    func testDefaultInsetsAreEightOnBothSides() {
        let layout = prepared(PinnedTabLayout(), extensions: 0, tabs: 2)
        XCTAssertEqual(layout.contentHeight, 8 + 45 + 8)
    }
}

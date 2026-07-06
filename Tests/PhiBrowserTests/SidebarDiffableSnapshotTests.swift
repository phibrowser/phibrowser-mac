// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

private final class SnapshotSidebarItem: SidebarItem {
    let id: AnyHashable
    let title: String
    let childrenItems: [SidebarItem]
    private let isExpandableOverride: Bool?
    private let itemTypeOverride: SidebarItemType?

    init(
        id: String,
        title: String? = nil,
        children: [SidebarItem] = [],
        isExpandable: Bool? = nil,
        itemType: SidebarItemType? = nil
    ) {
        self.id = AnyHashable(id)
        self.title = title ?? id
        self.childrenItems = children
        self.isExpandableOverride = isExpandable
        self.itemTypeOverride = itemType
    }

    var url: String? { nil }
    var iconName: String? { nil }
    var faviconUrl: String? { nil }
    var isExpandable: Bool { isExpandableOverride ?? !childrenItems.isEmpty }
    var hasChildren: Bool { isExpandable }
    var depth: Int { 0 }
    var itemType: SidebarItemType { itemTypeOverride ?? (isExpandable ? .bookmarkFolder : .bookmark) }
    var isActive: Bool { false }
    var isSelectable: Bool { true }
    var isBookmark: Bool { true }

    func performAction(with owner: SidebarTabListItemOwner?) {}
}

final class SidebarDiffableSnapshotTests: XCTestCase {
    func testSidebarSnapshotUsesStableItemIDs() {
        let child = SnapshotSidebarItem(id: "child")
        let parent = SnapshotSidebarItem(id: "parent", children: [child])

        let snapshot = SidebarDiffableSnapshotBuilder(rootItems: [parent]).makeSnapshot()

        XCTAssertEqual(snapshot.rootIDs, [AnyHashable("parent")])
        XCTAssertEqual(snapshot.childIDs(of: AnyHashable("parent")), [AnyHashable("child")])
        XCTAssertTrue(snapshot.item(for: AnyHashable("parent")) === parent)
        XCTAssertTrue(snapshot.item(for: AnyHashable("child")) === child)
    }

    func testSidebarSnapshotFiltersHiddenItem() {
        let hidden = SnapshotSidebarItem(id: "hidden")
        let visible = SnapshotSidebarItem(id: "visible")
        let parent = SnapshotSidebarItem(id: "parent", children: [hidden, visible])

        let snapshot = SidebarDiffableSnapshotBuilder(
            rootItems: [parent],
            hiddenItemID: AnyHashable("hidden")
        ).makeSnapshot()

        XCTAssertEqual(snapshot.childIDs(of: AnyHashable("parent")), [AnyHashable("visible")])
        XCTAssertNil(snapshot.item(for: AnyHashable("hidden")))
    }

    func testSidebarSnapshotInsertsVirtualItemAtRoot() {
        let first = SnapshotSidebarItem(id: "first")
        let second = SnapshotSidebarItem(id: "second")
        let virtual = SnapshotSidebarItem(id: "virtual")

        let snapshot = SidebarDiffableSnapshotBuilder(
            rootItems: [first, second],
            virtualInsertion: .init(item: virtual, parentID: nil, index: 1)
        ).makeSnapshot()

        XCTAssertEqual(snapshot.rootIDs, [AnyHashable("first"), AnyHashable("virtual"), AnyHashable("second")])
        XCTAssertTrue(snapshot.item(for: AnyHashable("virtual")) === virtual)
    }

    func testSidebarSnapshotInsertsVirtualItemInParent() {
        let first = SnapshotSidebarItem(id: "first")
        let second = SnapshotSidebarItem(id: "second")
        let virtual = SnapshotSidebarItem(id: "virtual")
        let parent = SnapshotSidebarItem(id: "parent", children: [first, second])

        let snapshot = SidebarDiffableSnapshotBuilder(
            rootItems: [parent],
            virtualInsertion: .init(item: virtual, parentID: AnyHashable("parent"), index: 1)
        ).makeSnapshot()

        XCTAssertEqual(
            snapshot.childIDs(of: AnyHashable("parent")),
            [AnyHashable("first"), AnyHashable("virtual"), AnyHashable("second")]
        )
    }

    func testSidebarSnapshotTreatsNonExpandableItemsAsLeaves() {
        let member = SnapshotSidebarItem(id: "member")
        let group = SnapshotSidebarItem(
            id: "group",
            children: [member],
            isExpandable: false,
            itemType: .tabGroup
        )

        let snapshot = SidebarDiffableSnapshotBuilder(rootItems: [group]).makeSnapshot()

        XCTAssertEqual(snapshot.rootIDs, [AnyHashable("group")])
        XCTAssertEqual(snapshot.childIDs(of: AnyHashable("group")), [])
        XCTAssertTrue(snapshot.item(for: AnyHashable("group")) === group)
        XCTAssertNil(snapshot.item(for: AnyHashable("member")))
    }
}

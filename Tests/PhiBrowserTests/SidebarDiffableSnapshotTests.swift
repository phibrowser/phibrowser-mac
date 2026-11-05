// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

private final class SnapshotSidebarItem: SidebarItem {
    let id: AnyHashable
    let title: String
    var childrenItems: [SidebarItem]
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

@MainActor
private final class TabSectionChangeRecorder: TabSectionDelegate {
    private(set) var changes: [TabSectionChange] = []

    func tabSectionDidUpdate(with change: TabSectionChange) {
        changes.append(change)
    }

    func focusingTabChanged(_ tab: Tab?) {}
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

    func testSidebarSnapshotHidesRealItemAndInsertsVirtualReplacement() {
        let real = SnapshotSidebarItem(id: "real")
        let sibling = SnapshotSidebarItem(id: "sibling")
        let virtual = SnapshotSidebarItem(id: "virtual")
        let parent = SnapshotSidebarItem(id: "parent", children: [real, sibling])

        let snapshot = SidebarDiffableSnapshotBuilder(
            rootItems: [parent],
            virtualInsertion: .init(item: virtual, parentID: AnyHashable("parent"), index: 0),
            hiddenItemID: AnyHashable("real")
        ).makeSnapshot()

        XCTAssertEqual(
            snapshot.childIDs(of: AnyHashable("parent")),
            [AnyHashable("virtual"), AnyHashable("sibling")]
        )
        XCTAssertNil(snapshot.item(for: AnyHashable("real")))
        XCTAssertTrue(snapshot.item(for: AnyHashable("virtual")) === virtual)
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

    func testStructureComparisonUsesCapturedChildrenWhenItemsMutateInPlace() {
        let first = SnapshotSidebarItem(id: "first")
        let second = SnapshotSidebarItem(id: "second")
        let parent = SnapshotSidebarItem(
            id: "parent",
            children: [first],
            isExpandable: true
        )
        let accepted = SidebarDiffableSnapshotBuilder(rootItems: [parent]).makeSnapshot()

        parent.childrenItems = [second]
        let updated = SidebarDiffableSnapshotBuilder(rootItems: [parent]).makeSnapshot()

        XCTAssertTrue(
            SidebarTabListViewController.hasOutlineStructureChanges(
                from: accepted,
                to: updated
            )
        )
    }

    func testStructureComparisonIgnoresMemberChangesInsideNonExpandableGroup() {
        let first = SnapshotSidebarItem(id: "first")
        let second = SnapshotSidebarItem(id: "second")
        let group = SnapshotSidebarItem(
            id: "group",
            children: [first],
            isExpandable: false,
            itemType: .tabGroup
        )
        let accepted = SidebarDiffableSnapshotBuilder(rootItems: [group]).makeSnapshot()

        group.childrenItems = [second]
        let updated = SidebarDiffableSnapshotBuilder(rootItems: [group]).makeSnapshot()

        XCTAssertFalse(
            SidebarTabListViewController.hasOutlineStructureChanges(
                from: accepted,
                to: updated
            )
        )
    }

    func testSingleRootInsertionIndexFindsOnlyInsertedRoot() {
        XCTAssertEqual(
            SidebarTabListViewController.singleRootInsertionIndex(
                from: ["a", "b", "c"],
                to: ["a", "inserted", "b", "c"]
            ),
            1
        )
        XCTAssertEqual(
            SidebarTabListViewController.singleRootInsertionIndex(
                from: ["a", "b"],
                to: ["a", "b", "inserted"]
            ),
            2
        )
    }

    func testSingleRootInsertionIndexRejectsOtherStructuralChanges() {
        XCTAssertNil(
            SidebarTabListViewController.singleRootInsertionIndex(
                from: ["a", "b"],
                to: ["b", "a", "inserted"]
            )
        )
        XCTAssertNil(
            SidebarTabListViewController.singleRootInsertionIndex(
                from: ["a", "b"],
                to: ["inserted-1", "a", "inserted-2", "b"]
            )
        )
        XCTAssertNil(
            SidebarTabListViewController.singleRootInsertionIndex(
                from: ["a", "b"],
                to: ["a"]
            )
        )
    }

    func testTabSectionChangeAllowsLayoutRepairForIsolatedRootChange() {
        XCTAssertTrue(
            TabSectionChange(
                rootItemsChanged: true,
                affectedGroupTokens: [],
                affectedSplitIds: []
            ).allowsInsertedRootTabLayoutRepair
        )
    }

    func testTabSectionChangeRejectsLayoutRepairForRelatedHiddenChanges() {
        XCTAssertFalse(
            TabSectionChange(
                rootItemsChanged: true,
                affectedGroupTokens: ["group"],
                affectedSplitIds: []
            ).allowsInsertedRootTabLayoutRepair
        )
        XCTAssertFalse(
            TabSectionChange(
                rootItemsChanged: true,
                affectedGroupTokens: [],
                affectedSplitIds: ["split"]
            ).allowsInsertedRootTabLayoutRepair
        )
        XCTAssertFalse(
            TabSectionChange(
                rootItemsChanged: false,
                affectedGroupTokens: [],
                affectedSplitIds: []
            ).allowsInsertedRootTabLayoutRepair
        )
    }

    func testTabSectionRootItemsTreatsRepeatedObjectsAsUnchanged() {
        let first = SnapshotSidebarItem(id: "first")
        let second = SnapshotSidebarItem(id: "second")

        XCTAssertFalse(
            TabSectionController.rootItemsChanged(
                from: [first, second],
                to: [first, second]
            )
        )
    }

    func testTabSectionRootItemsTreatsSameIDReplacementAsChanged() {
        let oldItem = SnapshotSidebarItem(id: "item")
        let replacement = SnapshotSidebarItem(id: "item")

        XCTAssertTrue(
            TabSectionController.rootItemsChanged(
                from: [oldItem],
                to: [replacement]
            )
        )
    }

    func testTabSectionRootItemsTreatsReorderAsChanged() {
        let first = SnapshotSidebarItem(id: "first")
        let second = SnapshotSidebarItem(id: "second")

        XCTAssertTrue(
            TabSectionController.rootItemsChanged(
                from: [first, second],
                to: [second, first]
            )
        )
    }

    func testTabSectionRootItemsTreatsInsertAsChanged() {
        let first = SnapshotSidebarItem(id: "first")
        let second = SnapshotSidebarItem(id: "second")

        XCTAssertTrue(
            TabSectionController.rootItemsChanged(
                from: [first],
                to: [first, second]
            )
        )
    }
}

@MainActor
final class SidebarTabSectionFastPathTests: XCTestCase {
    func testSpaceRootAppearsForFirstItemAndDisappearsAfterLastItemIsRemoved() throws {
        let state = try makeState()
        let tab = seedActiveTab(in: state, guid: 713)
        let (controller, outline) = try makeActiveSidebar(for: state)
        let (floating, floatingOutline) = try makeActiveSidebar(for: state)
        defer { controller.setActive(false); floating.setActive(false) }
        guard waitUntil({ state.bookmarkManager.didApplyFirstStoreDelivery && outline.row(forItem: tab) >= 0 }) else { return }

        func hasRoot(_ view: NSOutlineView) -> Bool {
            (0..<view.numberOfRows).contains { view.item(atRow: $0) is SpaceRootSidebarItem }
        }
        func hasSeparator(_ view: NSOutlineView) -> Bool {
            (0..<view.numberOfRows).contains { view.item(atRow: $0) is SeparatorItem }
        }
        XCTAssertFalse(hasRoot(outline))
        XCTAssertFalse(hasRoot(floatingOutline))
        XCTAssertFalse(hasSeparator(outline))
        XCTAssertNil(controller.spaceRootDropIndex(item: nil, index: 0))

        for isFolder in [true, false] {
            let guid = UUID().uuidString
            if isFolder {
                state.bookmarkManager.addFolder(title: "Folder", guid: guid)
            } else {
                state.localStore.createBookmark(url: "https://bookmark.example", title: "Bookmark",
                                                profileId: state.profileId, parentId: nil,
                                                guid: guid, spaceId: state.spaceId)
            }
            guard waitUntil({ hasRoot(outline) && hasRoot(floatingOutline) }) else { return }
            let item = try XCTUnwrap(state.bookmarkManager.bookmark(withGuid: guid))
            XCTAssertTrue(hasSeparator(outline))
            let root = try XCTUnwrap(outline.item(atRow: 0) as? SpaceRootSidebarItem)
            if state.isBookmarkRootExpanded {
                controller.toggleItemExpanded(root)
                guard waitUntil({ !outline.isItemExpanded(root) }) else { return }
            }
            XCTAssertTrue(hasRoot(outline), "A collapsed root still represents existing items")
            state.bookmarkManager.removeBookmark(item)
            guard waitUntil({ !hasRoot(outline) && !hasRoot(floatingOutline) }) else { return }
            XCTAssertFalse(hasSeparator(outline))
            XCTAssertFalse(hasSeparator(floatingOutline))
            XCTAssertGreaterThanOrEqual(outline.row(forItem: tab), 0)
            XCTAssertNil(controller.spaceRootDropIndex(item: root, index: 0))
        }
    }

    func testFastSecondClickOnSpaceRootTogglesAgain() throws {
        let state = try makeState()
        state.bookmarkManager.addFolder(title: "Folder", guid: "space-root-double-click")
        let (controller, outline) = try makeActiveSidebar(for: state)
        let window = NSWindow(contentRect: controller.view.frame, styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(controller.view)
        defer { controller.setActive(false); window.close() }
        guard waitUntil({ outline.item(atRow: 0) is SpaceRootSidebarItem }) else { return }
        let rect = outline.rect(ofRow: 0)
        let point = outline.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        func click(count: Int) throws {
            func event(_ type: NSEvent.EventType) throws -> NSEvent {
                try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                timestamp: 0, windowNumber: window.windowNumber,
                                                context: nil, eventNumber: 0, clickCount: count, pressure: 1))
            }
            // The outline's tracking loop consumes the queued mouseUp.
            NSApp.postEvent(try event(.leftMouseUp), atStart: false)
            outline.mouseDown(with: try event(.leftMouseDown))
        }
        XCTAssertTrue(state.isBookmarkRootExpanded)
        try click(count: 1)
        XCTAssertFalse(state.isBookmarkRootExpanded)
        // AppKit routes the second click of a double-click to `doubleAction`.
        try click(count: 2)
        XCTAssertTrue(state.isBookmarkRootExpanded)
    }

    func testSpaceRootIndentsBookmarksAndSharesCollapseAcrossSidebarSurfaces() throws {
        let state = try makeState()
        state.bookmarkManager.addFolder(title: "Folder", guid: "space-root-folder")
        guard waitUntil({ state.bookmarkManager.bookmark(withGuid: "space-root-folder") != nil }) else { return }
        let folder = try XCTUnwrap(state.bookmarkManager.bookmark(withGuid: "space-root-folder"))
        state.bookmarkManager.addBookmark(title: "Child", url: "https://child.example", to: folder)
        guard waitUntil({ !folder.children.isEmpty }) else { return }
        let child = try XCTUnwrap(folder.children.first)
        let (controller, outline) = try makeActiveSidebar(for: state)
        let (floating, floatingOutline) = try makeActiveSidebar(for: state)
        defer { controller.setActive(false); floating.setActive(false) }
        guard waitUntil({ outline.row(forItem: folder) >= 0 && floatingOutline.row(forItem: folder) >= 0 }) else { return }
        let root = try XCTUnwrap(outline.item(atRow: 0) as? SpaceRootSidebarItem)
        let cell = try XCTUnwrap(outline.view(atColumn: 0, row: 0, makeIfNecessary: true) as? SpaceRootCellView)
        cell.layoutSubtreeIfNeeded()
        let chevron = try XCTUnwrap(cell.backgoundView.subviews.compactMap { $0 as? SpaceRootChevronView }.first)
        XCTAssertEqual(cos(chevron.rotationAngle), 0, accuracy: 0.001,
                       "The expanded chevron must remain vertical after AppKit layout")
        XCTAssertEqual(chevron.layer?.sublayers?.first?.transform.m11 ?? 1, 0, accuracy: 0.001)
        XCTAssertNil(controller.outlineView(outline, pasteboardWriterForItem: root))
        XCTAssertNil(folder.parent, "The presentation root must not change persisted bookmark ownership")
        XCTAssertEqual(outline.level(forItem: folder), 1)
        controller.toggleItemExpanded(folder)
        guard waitUntil({ outline.isItemExpanded(folder) && folder.isExpanded }) else { return }
        controller.toggleItemExpanded(root)
        guard waitUntil({ !outline.isItemExpanded(root) && floatingOutline.row(forItem: folder) == -1 }) else { return }
        XCTAssertTrue(folder.isExpanded)
        cell.layoutSubtreeIfNeeded()
        XCTAssertEqual(chevron.rotationAngle, 0)
        XCTAssertEqual(outline.row(forItem: child), -1)
        XCTAssertNotNil((0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? SidebarItem)?.itemType == .newTabButton })
        controller.toggleItemExpanded(root)
        guard waitUntil({ outline.row(forItem: child) >= 0 && floatingOutline.row(forItem: folder) >= 0 }) else { return }
        XCTAssertEqual(outline.level(forItem: child), 2)
        XCTAssertTrue(folder.isExpanded)
    }

    func testSpaceRootCollapseIsRememberedPerSpace() throws {
        let state = try makeState()
        let other = try makeState()
        state.isBookmarkRootExpanded = false
        XCTAssertFalse(try makeState(spaceId: state.spaceId).isBookmarkRootExpanded)
        XCTAssertTrue(try makeState(spaceId: other.spaceId).isBookmarkRootExpanded)
        state.isBookmarkRootExpanded = true
        XCTAssertTrue(try makeState(spaceId: state.spaceId).isBookmarkRootExpanded)
    }

    func testCollapsedSpaceRootStillRestoresAutosavedFolders() throws {
        let autosaveKey = "NSOutlineView Items SidebarTabList"
        let savedItems = UserDefaults.standard.object(forKey: autosaveKey)
        defer { UserDefaults.standard.set(savedItems, forKey: autosaveKey) }
        let state = try makeState()
        state.isBookmarkRootExpanded = false
        let guid = "collapsed-root-folder"
        UserDefaults.standard.set([guid], forKey: autosaveKey)
        let (controller, outline) = try makeActiveSidebar(for: state)
        defer { controller.setActive(false) }
        state.bookmarkManager.addFolder(title: "Folder", guid: guid)
        guard waitUntil({ outline.autosaveName != nil && outline.item(atRow: 0) is SpaceRootSidebarItem }) else { return }
        let root = try XCTUnwrap(outline.item(atRow: 0) as? SpaceRootSidebarItem)
        let folder = try XCTUnwrap(state.bookmarkManager.bookmark(withGuid: guid))
        XCTAssertFalse(outline.isItemExpanded(root))
        XCTAssertFalse(state.isBookmarkRootExpanded)
        XCTAssertTrue(folder.isExpanded)
        state.bookmarkManager.addBookmark(title: "Child", url: "https://child.example", to: folder)
        guard waitUntil({ !folder.children.isEmpty }) else { return }
        let child = try XCTUnwrap(folder.children.first)
        controller.toggleItemExpanded(root)
        guard waitUntil({ outline.row(forItem: child) >= 0 }) else { return }
        XCTAssertTrue(outline.isItemExpanded(folder))
    }

    func testCollapsedSpaceRootKeepsFocusedBookmarkBelowHeaderAndRestoresAfterReactivation() throws {
        let state = try makeState()
        let guid = "space-root-active"
        state.localStore.createBookmark(url: "https://active.example", title: "Active", profileId: state.profileId,
                                        parentId: nil, guid: guid, spaceId: state.spaceId)
        guard waitUntil({ state.bookmarkManager.bookmark(withGuid: guid) != nil }) else { return }
        let bookmark = try XCTUnwrap(state.bookmarkManager.bookmark(withGuid: guid))
        let tab = seedActiveTab(in: state, guid: 712)
        tab.guidInLocalDB = guid
        bookmark.isOpened = true
        let (controller, outline) = try makeActiveSidebar(for: state)
        defer { controller.setActive(false) }
        guard waitUntil({ outline.row(forItem: bookmark) >= 0 }) else { return }
        let root = try XCTUnwrap(outline.item(atRow: 0) as? SpaceRootSidebarItem)
        controller.toggleItemExpanded(root)
        guard waitUntil({ !outline.isItemExpanded(root) && outline.item(atRow: 1) is SidebarTabListViewController.FocusedBookmarkSidebarItem }) else { return }
        let proxy = try XCTUnwrap(outline.item(atRow: 1) as? SidebarTabListViewController.FocusedBookmarkSidebarItem)
        XCTAssertTrue(proxy.underlyingBookmark === bookmark)
        XCTAssertEqual(proxy.indentationLevelOverride, 1)
        XCTAssertEqual(state.visibleBookmarkTabs.map(\.guid), [guid])
        XCTAssertEqual(outline.row(forItem: bookmark), -1)
        controller.setActive(false)
        controller.setActive(true)
        guard waitUntil({ outline.item(atRow: 1) is SidebarTabListViewController.FocusedBookmarkSidebarItem }) else { return }
        XCTAssertFalse(state.isBookmarkRootExpanded)
        controller.toggleItemExpanded(root)
        guard waitUntil({ outline.row(forItem: bookmark) >= 0 }) else { return }
        XCTAssertFalse((0..<outline.numberOfRows).contains { outline.item(atRow: $0) is SidebarTabListViewController.FocusedBookmarkSidebarItem })
    }

    func testSpaceRootDropCoordinatesDoNotUseBookmarkCountAsTabOffset() throws {
        let state = try makeState()
        for index in 0..<5 {
            state.localStore.createBookmark(url: "https://example.test/\(index)", title: "Bookmark \(index)",
                                            profileId: state.profileId, parentId: nil, guid: "root-drop-\(index)", spaceId: state.spaceId)
        }
        guard waitUntil({ state.bookmarkManager.rootFolder.children.count == 5 }) else { return }
        let (controller, outline) = try makeActiveSidebar(for: state)
        defer { controller.setActive(false) }
        guard waitUntil({ outline.item(atRow: 0) is SpaceRootSidebarItem }) else { return }
        let root = try XCTUnwrap(outline.item(atRow: 0) as? SpaceRootSidebarItem)
        XCTAssertEqual(controller.spaceRootDropIndex(item: root, index: 4), 4)
        XCTAssertEqual(controller.spaceRootDropIndex(item: nil, index: 1), 5)
        XCTAssertNil(controller.spaceRootDropIndex(item: nil, index: 2), "New Tab belongs to the normal-tab section")
        let fourth = try XCTUnwrap(state.bookmarkManager.bookmark(withGuid: "root-drop-3"))
        XCTAssertEqual(controller.spaceRootDropIndex(item: fourth, index: NSOutlineViewDropOnItemIndex), 3)
        controller.toggleItemExpanded(root)
        guard waitUntil({ !outline.isItemExpanded(root) }) else { return }
        XCTAssertNil(controller.spaceRootDropIndex(item: nil, index: 2))
    }


    func testCreateSpaceOverlaySuppressionHidesOutlineTrackingSubtreeWithoutHidingLayoutRoot() throws {
        let state = try makeState()
        let (controller, _) = try makeActiveSidebar(for: state)
        let scrollView = try XCTUnwrap(
            controller.view.subviews.compactMap { $0 as? NSScrollView }.first
        )

        controller.setCreateSpaceOverlayInteractionSuppressed(true)

        XCTAssertTrue(scrollView.isHidden)
        XCTAssertFalse(controller.view.isHidden)

        controller.setCreateSpaceOverlayInteractionSuppressed(false)

        XCTAssertFalse(scrollView.isHidden)
    }

    func testCreateSpaceOverlaySuppressionHidesPinnedTrackingRoot() throws {
        let controller = PinnedTabViewController(state: try makeState())
        controller.loadViewIfNeeded()

        controller.setCreateSpaceOverlayInteractionSuppressed(true)
        XCTAssertTrue(controller.view.isHidden)

        controller.setCreateSpaceOverlayInteractionSuppressed(false)
        XCTAssertFalse(controller.view.isHidden)
    }

    func testCreateSpaceOverlaySuppressionHidesFloatingNewTabAcrossLayoutAndRecreation() throws {
        let state = try makeState()
        state.tabs = (0..<40).map { index in
            Tab(guid: 1000 + index, url: "https://tab.example/\(index)",
                isActive: false, index: index, title: "Tab \(index)")
        }
        state.updateNormalTabs()
        let (controller, outlineView) = try makeActiveSidebar(for: state)
        defer { controller.setActive(false) }
        let scrollView = try XCTUnwrap(outlineView.enclosingScrollView)
        guard waitUntil({ outlineView.numberOfRows >= 41 }) else { return }
        controller.view.layoutSubtreeIfNeeded()
        let newTabRow = try XCTUnwrap((0..<outlineView.numberOfRows).first {
            (outlineView.item(atRow: $0) as? SidebarItem)?.itemType == .newTabButton
        })
        let floatingOffset = outlineView.rect(ofRow: newTabRow).maxY + 1

        func scroll(to offset: CGFloat) {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            controller.viewDidLayout()
        }

        scroll(to: floatingOffset)
        let floatingView = try XCTUnwrap(
            controller.view.subviews.compactMap { $0 as? FloatingNewTabView }.first
        )
        XCTAssertFalse(floatingView.isHidden)

        controller.setCreateSpaceOverlayInteractionSuppressed(true)
        XCTAssertTrue(floatingView.isHidden)
        XCTAssertFalse(controller.view.isHidden)
        controller.viewDidLayout()
        XCTAssertTrue(floatingView.isHidden)

        scroll(to: 0)
        XCTAssertNil(floatingView.superview)
        scroll(to: floatingOffset)
        let recreatedView = try XCTUnwrap(
            controller.view.subviews.compactMap { $0 as? FloatingNewTabView }.first
        )
        XCTAssertTrue(recreatedView.isHidden)
        XCTAssertTrue(recreatedView.cellView.isHiddenOrHasHiddenAncestor)

        controller.setCreateSpaceOverlayInteractionSuppressed(false)
        XCTAssertFalse(recreatedView.isHidden)
        XCTAssertFalse(scrollView.isHidden)
    }

    func testCreateSpaceOverlaySuppressionHidesBottomBarHostingContentOnly() throws {
        let bottomBar = SidebarBottomBarSwiftUIView()
        let hostingView = try XCTUnwrap(bottomBar.subviews.first)

        bottomBar.setCreateSpaceOverlayInteractionSuppressed(true)

        XCTAssertTrue(hostingView.isHidden)
        XCTAssertFalse(bottomBar.isHidden)

        bottomBar.setCreateSpaceOverlayInteractionSuppressed(false)

        XCTAssertFalse(hostingView.isHidden)
    }

    private var tempDirectories: [URL] = []
    private let collapsedRootsKey = "SidebarCollapsedBookmarkRootSpaceIds"
    private var savedCollapsedRoots: Any?

    override func setUpWithError() throws {
        try super.setUpWithError()
        savedCollapsedRoots = UserDefaults.standard.object(forKey: collapsedRootsKey)
    }

    override func tearDownWithError() throws {
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
        UserDefaults.standard.set(savedCollapsedRoots, forKey: collapsedRootsKey)
        try super.tearDownWithError()
    }

    func testNoOpTabSectionUpdateRefreshesSelectionAndVisibleBookmarks() throws {
        let state = try makeState()
        let bookmarkGuid = "fast-path-bookmark"
        state.localStore.createBookmark(
            url: "https://bookmark.example",
            title: "Bookmark",
            profileId: state.profileId,
            parentId: nil,
            guid: bookmarkGuid,
            spaceId: state.spaceId
        )
        guard waitUntil({
            state.bookmarkManager.bookmark(withGuid: bookmarkGuid) != nil
        }) else { return }
        let bookmark = try XCTUnwrap(state.bookmarkManager.bookmark(withGuid: bookmarkGuid))
        let tab = seedActiveTab(in: state, guid: 101)
        let (controller, outlineView) = try makeActiveSidebar(for: state)
        defer { controller.setActive(false) }
        guard waitUntil({
            outlineView.row(forItem: bookmark) >= 0
                && outlineView.row(forItem: tab) >= 0
                && state.visibleBookmarkTabs.map(\.guid) == [bookmarkGuid]
        }) else { return }
        waitForMainQueueUpdates()

        outlineView.deselectAll(nil)
        state.visibleBookmarkTabs = []

        controller.tabSectionDidUpdate(with: TabSectionChange(
            rootItemsChanged: false,
            affectedGroupTokens: [],
            affectedSplitIds: []
        ))

        XCTAssertEqual(
            outlineView.selectedRowIndexes,
            IndexSet(integer: outlineView.row(forItem: tab))
        )
        guard waitUntil({
            state.visibleBookmarkTabs.map(\.guid) == [bookmarkGuid]
        }) else { return }
    }

    func testSameIDReplacementUsesFullDiffablePath() throws {
        let state = try makeState()
        let oldTab = seedActiveTab(in: state, guid: 201)
        let (controller, outlineView) = try makeActiveSidebar(for: state)
        defer { controller.setActive(false) }
        guard waitUntil({
            outlineView.row(forItem: oldTab) >= 0
        }) else { return }

        let replacement = Tab(
            guid: oldTab.guid,
            url: "https://replacement.example",
            isActive: true,
            index: 0,
            title: "Replacement"
        )
        state.tabs = [replacement]
        state.updateNormalTabs()

        guard waitUntil({
            (0..<outlineView.numberOfRows).contains { row in
                (outlineView.item(atRow: row) as? Tab) === replacement
            }
        }) else { return }
        XCTAssertFalse((0..<outlineView.numberOfRows).contains { row in
            (outlineView.item(atRow: row) as? Tab) === oldTab
        })
    }

    func testPlainTabInsertionProducesIsolatedLayoutRepairProvenance() throws {
        let state = try makeState()
        let existingTab = seedActiveTab(in: state, guid: 301)
        let recorder = TabSectionChangeRecorder()
        let sectionController = TabSectionController()
        sectionController.delegate = recorder
        sectionController.browserState = state

        let insertedTab = Tab(
            guid: 302,
            url: "https://inserted.example",
            isActive: false,
            index: 1,
            title: "Inserted"
        )
        state.tabs = [existingTab, insertedTab]
        state.updateNormalTabs()

        guard waitUntil({
            recorder.changes.contains { $0.rootItemsChanged }
        }) else { return }
        let change = try XCTUnwrap(
            recorder.changes.first { $0.rootItemsChanged }
        )
        XCTAssertTrue(change.affectedGroupTokens.isEmpty)
        XCTAssertTrue(change.affectedSplitIds.isEmpty)
        XCTAssertTrue(change.allowsInsertedRootTabLayoutRepair)
    }

    func testLeavingGroupRejectsInsertedRootTabLayoutRepair() throws {
        let state = try makeState()
        let first = Tab(
            guid: 401,
            url: "https://first.example",
            isActive: true,
            index: 0,
            title: "First"
        )
        let second = Tab(
            guid: 402,
            url: "https://second.example",
            isActive: false,
            index: 1,
            title: "Second"
        )
        state.tabs = [first, second]
        state.updateNormalTabs()
        state.handleTabGroupCreated(
            token: "group",
            title: "Group",
            color: .blue,
            isCollapsed: false,
            initialTabIds: [first.guid, second.guid]
        )

        let recorder = TabSectionChangeRecorder()
        let sectionController = TabSectionController()
        sectionController.delegate = recorder
        sectionController.browserState = state

        state.handleTabLeftGroup(tabId: first.guid, token: "group")

        guard waitUntil({
            recorder.changes.contains {
                $0.rootItemsChanged && $0.affectedGroupTokens.contains("group")
            }
        }) else { return }
        let change = try XCTUnwrap(
            recorder.changes.first {
                $0.rootItemsChanged && $0.affectedGroupTokens.contains("group")
            }
        )
        XCTAssertTrue(change.affectedSplitIds.isEmpty)
        XCTAssertFalse(change.allowsInsertedRootTabLayoutRepair)
    }

    private func makeState(spaceId: String = UUID().uuidString) throws -> BrowserState {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        let store = LocalStore(
            account: Account(userID: UUID().uuidString),
            storeDirectoryURL: directory
        )
        return BrowserState(windowId: 7, localStore: store, profileId: "Default", spaceId: spaceId)
    }

    private func seedActiveTab(in state: BrowserState, guid: Int) -> Tab {
        let tab = Tab(
            guid: guid,
            url: "https://tab.example",
            isActive: true,
            index: 0,
            title: "Tab"
        )
        state.tabs = [tab]
        state.updateNormalTabs()
        state.focuseTab(tab)
        return tab
    }

    private func makeActiveSidebar(
        for state: BrowserState
    ) throws -> (SidebarTabListViewController, SideBarOutlineView) {
        let controller = SidebarTabListViewController(state: state)
        controller.loadViewIfNeeded()
        controller.view.frame = NSRect(x: 0, y: 0, width: 320, height: 640)
        controller.setActive(true)
        controller.view.layoutSubtreeIfNeeded()
        let scrollView = try XCTUnwrap(
            controller.view.subviews.compactMap { $0 as? NSScrollView }.first
        )
        let outlineView = try XCTUnwrap(scrollView.documentView as? SideBarOutlineView)
        return (controller, outlineView)
    }

    private func waitForMainQueueUpdates() {
        let updatesFinished = expectation(description: "Main queue updates finished")
        DispatchQueue.main.async {
            DispatchQueue.main.async {
                updatesFinished.fulfill()
            }
        }
        wait(for: [updatesFinished], timeout: 1)
    }

    @discardableResult
    private func waitUntil(
        timeout: TimeInterval = 1,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTFail("Condition was not met before timeout.")
        return false
    }
}

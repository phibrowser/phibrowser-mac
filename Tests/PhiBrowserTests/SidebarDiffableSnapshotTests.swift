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
        let key = "newTabsAtTop"
        let layoutKey = PhiPreferences.GeneralSettings.layoutModeKey
        let oldPreference = UserDefaults.standard.object(forKey: key)
        let oldLayout = UserDefaults.standard.object(forKey: layoutKey)
        defer {
            UserDefaults.standard.set(oldPreference, forKey: key)
            UserDefaults.standard.set(oldLayout, forKey: layoutKey)
        }
        PhiPreferences.GeneralSettings.saveLayoutMode(.performance)
        for atTop in [true, false] {
            UserDefaults.standard.set(atTop, forKey: key)
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
            let buttonRect = outlineView.rect(ofRow: newTabRow)
            let floatingOffset = atTop ? buttonRect.maxY + 1 : 0
            let inlineOffset = atTop ? 0 : max(0, buttonRect.maxY - scrollView.contentView.bounds.height)

            func scroll(to offset: CGFloat) {
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
                scrollView.reflectScrolledClipView(scrollView.contentView)
                controller.viewDidLayout()
            }

            scroll(to: floatingOffset)
            let floatingView = try XCTUnwrap(
                controller.view.subviews.compactMap { $0 as? FloatingSidebarRowView }.first
            )
            XCTAssertFalse(floatingView.isHidden)

            controller.setCreateSpaceOverlayInteractionSuppressed(true)
            XCTAssertTrue(floatingView.isHidden)
            XCTAssertFalse(controller.view.isHidden)
            controller.viewDidLayout()
            XCTAssertTrue(floatingView.isHidden)

            scroll(to: inlineOffset)
            XCTAssertNil(floatingView.superview)
            scroll(to: floatingOffset)
            let recreatedView = try XCTUnwrap(
                controller.view.subviews.compactMap { $0 as? FloatingSidebarRowView }.first
            )
            XCTAssertTrue(recreatedView.isHidden)
            XCTAssertTrue(recreatedView.cellView.isHiddenOrHasHiddenAncestor)

            controller.setCreateSpaceOverlayInteractionSuppressed(false)
            XCTAssertFalse(recreatedView.isHidden)
            XCTAssertFalse(scrollView.isHidden)
        }
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

    func testBottomNewTabPreferencePlacesStableButtonAfterTabs() throws {
        let key = "newTabsAtTop"
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(false, forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }
        let state = try makeState()
        _ = seedActiveTab(in: state, guid: 901)
        let section = TabSectionController()
        section.browserState = state
        XCTAssertEqual(section.tabItems.first?.itemType, .tab)
        XCTAssertEqual(section.tabItems.last?.itemType, .newTabButton)
    }

    func testNewTabButtonMovesLiveWithPreferenceAndDestinationLayout() throws {
        let key = "newTabsAtTop"
        let oldPreference = UserDefaults.standard.object(forKey: key)
        let layoutKey = PhiPreferences.GeneralSettings.layoutModeKey
        let oldLayout = UserDefaults.standard.object(forKey: layoutKey)
        UserDefaults.standard.set(false, forKey: key)
        PhiPreferences.GeneralSettings.saveLayoutMode(.performance)
        defer {
            UserDefaults.standard.set(oldPreference, forKey: key)
            UserDefaults.standard.set(oldLayout, forKey: layoutKey)
        }
        let state = try makeState()
        _ = seedActiveTab(in: state, guid: 902)
        let section = TabSectionController()
        section.browserState = state
        let button = try XCTUnwrap(section.tabItems.last)
        XCTAssertEqual(button.itemType, .newTabButton)
        UserDefaults.standard.set(true, forKey: key)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: UserDefaults.standard)
        guard waitUntil({ section.tabItems.first?.itemType == .newTabButton }) else { return }
        XCTAssertTrue(section.tabItems.first === button)
        state.layoutMode = .comfortable
        guard waitUntil({ section.tabItems.last?.itemType == .newTabButton }) else { return }
        XCTAssertTrue(section.tabItems.last === button)
        state.layoutMode = .performance
        guard waitUntil({ section.tabItems.first?.itemType == .newTabButton }) else { return }
        XCTAssertTrue(section.tabItems.first === button)
    }

    func testPreferenceChangeAfterDestinationLayoutChangeDoesNotUseStalePolicyCache() throws {
        let key = PhiPreferences.GeneralSettings.newTabsAtTop.rawValue
        let layoutKey = PhiPreferences.GeneralSettings.layoutModeKey
        let oldPreference = UserDefaults.standard.object(forKey: key)
        let oldLayout = UserDefaults.standard.object(forKey: layoutKey)
        defer {
            UserDefaults.standard.set(oldPreference, forKey: key)
            UserDefaults.standard.set(oldLayout, forKey: layoutKey)
        }
        UserDefaults.standard.set(true, forKey: key)
        PhiPreferences.GeneralSettings.saveLayoutMode(.performance)
        let state = try makeState()
        _ = seedActiveTab(in: state, guid: 903)
        state.layoutMode = .comfortable
        let section = TabSectionController()
        section.browserState = state
        XCTAssertEqual(section.tabItems.last?.itemType, .newTabButton)
        state.layoutMode = .performance
        guard waitUntil({ section.tabItems.first?.itemType == .newTabButton }) else { return }
        UserDefaults.standard.set(false, forKey: key)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: UserDefaults.standard)
        guard waitUntil({ section.tabItems.last?.itemType == .newTabButton }) else { return }
    }

    func testBottomButtonDropMappingDoesNotTreatSecondTabAsFirst() throws {
        let key = "newTabsAtTop"
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(false, forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }
        let state = try makeState()
        let tabs = (1...3).map { Tab(guid: $0, url: "https://tab.example/\($0)", isActive: false, index: $0 - 1) }
        state.tabs = tabs
        state.updateNormalTabs()
        let (controller, outline) = try makeActiveSidebar(for: state)
        defer { controller.setActive(false) }
        guard waitUntil({ outline.row(forItem: tabs[1]) >= 0 }) else { return }
        XCTAssertEqual(controller.calculateTabDestinationIndex(from: outline.row(forItem: tabs[1])), 1)
        let buttonRow = try XCTUnwrap((0..<outline.numberOfRows).first {
            (outline.item(atRow: $0) as? SidebarItem)?.itemType == .newTabButton
        })
        XCTAssertEqual(controller.calculateTabDestinationIndex(from: buttonRow), 3)
        XCTAssertEqual(controller.calculateTabDestinationIndex(from: buttonRow + 1), 3)
    }

    func testButtonDropMappingPreservesFourPaneBoundaryAndEmptyList() throws {
        let key = "newTabsAtTop"
        let previous = UserDefaults.standard.object(forKey: key)
        let layoutKey = PhiPreferences.GeneralSettings.layoutModeKey
        let oldLayout = UserDefaults.standard.object(forKey: layoutKey)
        PhiPreferences.GeneralSettings.saveLayoutMode(.performance)
        defer {
            UserDefaults.standard.set(previous, forKey: key)
            UserDefaults.standard.set(oldLayout, forKey: layoutKey)
        }
        for atTop in [false, true] {
            UserDefaults.standard.set(atTop, forKey: key)
            let state = try makeState()
            let tabs = (1...4).map { Tab(guid: $0, url: "https://tab.example/\($0)", isActive: false, index: $0 - 1) }
            state.tabs = tabs
            state.splits = [SplitGroup(id: "four", tabIds: [1, 2, 3, 4], layout: .vertical,
                                      fractions: SplitGroup.equalFractions(paneCount: 4))]
            state.updateNormalTabs()
            let (controller, outline) = try makeActiveSidebar(for: state)
            defer { controller.setActive(false) }
            guard waitUntil({ (0..<outline.numberOfRows).contains { outline.item(atRow: $0) is SplitSidebarItem } }) else { return }
            let splitRow = try XCTUnwrap((0..<outline.numberOfRows).first { outline.item(atRow: $0) is SplitSidebarItem })
            XCTAssertEqual(controller.calculateTabDestinationIndex(from: splitRow), 0)
            XCTAssertEqual(controller.calculateTabDestinationIndex(from: splitRow + 1), 4)
            state.tabs = []
            state.updateNormalTabs()
            guard waitUntil({ !(0..<outline.numberOfRows).contains { outline.item(atRow: $0) is SplitSidebarItem } }) else { return }
            let buttonRow = try XCTUnwrap((0..<outline.numberOfRows).first {
                (outline.item(atRow: $0) as? SidebarItem)?.itemType == .newTabButton
            })
            XCTAssertEqual(controller.calculateTabDestinationIndex(from: buttonRow), 0)
        }
    }

    func testPlainTabInsertionReportsOnlyARootChange() throws {
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
    }

    func testLeavingGroupReportsRootAndGroupChanges() throws {
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
    }

    func testSpaceRowStaysLockedAtTheTopAtEveryScrollOffset() throws {
        let sidebar = try makeScrollableSidebar(tabCount: 40, pinCount: 1, newTabsAtTop: false)
        defer { sidebar.controller.setActive(false) }

        sidebar.scroll(to: 0)
        let pinned = try XCTUnwrap(sidebar.pinnedSpaceRow())
        let lockedFrame = pinned.frame
        XCTAssertFalse(pinned.isHidden)
        XCTAssertEqual((pinned.cellView as? SpaceRootCellView)?.accessibilityLabel(),
                       sidebar.outline.item(atRow: 0).flatMap { ($0 as? SidebarItem)?.title })
        let realCell = try XCTUnwrap(sidebar.outline.view(atColumn: 0, row: 0, makeIfNecessary: false))
        XCTAssertTrue(realCell.isHidden)

        for offset in [CGFloat(1), sidebar.outline.rect(ofRow: 0).maxY + 1, 300, 0] {
            sidebar.scroll(to: offset)
            XCTAssertTrue(sidebar.pinnedSpaceRow() === pinned, "offset \(offset)")
            XCTAssertEqual(pinned.frame, lockedFrame, "offset \(offset)")
        }

        // Rubber-banding past the top moves the list, never the Space row.
        sidebar.scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: -30))
        sidebar.controller.viewDidLayout()
        XCTAssertTrue(sidebar.pinnedSpaceRow() === pinned)
        XCTAssertEqual(pinned.frame, lockedFrame)
    }

    func testFoldingFromPinnedRowKeepsItLocked() throws {
        let sidebar = try makeScrollableSidebar(tabCount: 3, pinCount: 30, newTabsAtTop: false)
        defer { sidebar.controller.setActive(false) }
        XCTAssertTrue(sidebar.state.isBookmarkRootExpanded)

        sidebar.scroll(to: sidebar.outline.rect(ofRow: 0).maxY + 1)
        let pinned = try XCTUnwrap(sidebar.pinnedSpaceRow())
        let lockedFrame = pinned.frame
        let clickAction = try XCTUnwrap(pinned.clickAction)
        clickAction()

        XCTAssertFalse(sidebar.state.isBookmarkRootExpanded)
        // Folded: Space root + separator + tabs + New Tab.
        guard waitUntil(timeout: 2, { sidebar.outline.numberOfRows <= 6 }) else { return }
        sidebar.controller.viewDidLayout()
        XCTAssertTrue(sidebar.pinnedSpaceRow() === pinned)
        XCTAssertEqual(pinned.frame, lockedFrame)

        clickAction()
        XCTAssertTrue(sidebar.state.isBookmarkRootExpanded)
    }

    func testSpaceRowShowsHairlineOnlyWithContentUnderIt() throws {
        let sidebar = try makeScrollableSidebar(tabCount: 40, pinCount: 1, newTabsAtTop: false)
        defer { sidebar.controller.setActive(false) }

        sidebar.scroll(to: 0)
        let pinned = try XCTUnwrap(sidebar.pinnedSpaceRow())
        XCTAssertFalse(pinned.showsSeparator)
        sidebar.scroll(to: 300)
        XCTAssertTrue(pinned.showsSeparator)
        sidebar.scroll(to: 0)
        XCTAssertFalse(pinned.showsSeparator)
    }

    func testClickOnSpaceNameTextFoldsFromLockedRow() throws {
        let sidebar = try makeScrollableSidebar(tabCount: 40, pinCount: 1, newTabsAtTop: false)
        let window = NSWindow(contentRect: sidebar.controller.view.frame, styleMask: [],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(sidebar.controller.view)
        defer { sidebar.controller.setActive(false); window.close() }
        sidebar.scroll(to: 0)
        let pinned = try XCTUnwrap(sidebar.pinnedSpaceRow())
        let title = try XCTUnwrap(Self.textField(in: pinned.cellView))
        let point = title.convert(NSPoint(x: title.bounds.midX, y: title.bounds.midY), to: nil)
        let hit = try XCTUnwrap(window.contentView?.hitTest(point))
        XCTAssertTrue(hit === pinned, "A click on the name must reach the row, not the label")

        func event(_ type: NSEvent.EventType, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags,
                                            timestamp: 0, windowNumber: window.windowNumber,
                                            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        XCTAssertTrue(sidebar.state.isBookmarkRootExpanded)
        hit.mouseDown(with: try event(.leftMouseDown))
        hit.mouseUp(with: try event(.leftMouseUp))
        XCTAssertFalse(sidebar.state.isBookmarkRootExpanded)

        // Control-click opens the menu; it never folds.
        hit.mouseUp(with: try event(.leftMouseUp, .control))
        XCTAssertFalse(sidebar.state.isBookmarkRootExpanded)
    }

    func testLockedSpaceRowKeepsTheRealRowsContextMenu() throws {
        let sidebar = try makeScrollableSidebar(tabCount: 40, pinCount: 1, newTabsAtTop: false)
        defer { sidebar.controller.setActive(false) }
        sidebar.scroll(to: 0)
        let pinned = try XCTUnwrap(sidebar.pinnedSpaceRow())
        XCTAssertTrue(pinned.menu === sidebar.controller.blankAreaContextMenu)
    }

    func testHoveringLockedSpaceRowKeepsTabsSuppressedWhileNewTabUnpins() throws {
        let sidebar = try makeScrollableSidebar(tabCount: 40, pinCount: 1, newTabsAtTop: false)
        defer { sidebar.controller.setActive(false) }
        sidebar.scroll(to: 0)
        let space = try XCTUnwrap(sidebar.pinnedSpaceRow())
        XCTAssertNotNil(sidebar.pinnedRows().first { $0.cellView is NewTabButtonCellView },
                        "A long list pins New Tab to the bottom")
        let entered = try XCTUnwrap(NSEvent.enterExitEvent(
            with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        space.mouseEntered(with: entered)
        XCTAssertTrue(sidebar.controller.isTabHoverSuppressed)

        // Scrolling to the end hands New Tab back to its real row.
        sidebar.scroll(to: sidebar.outline.frame.height)
        XCTAssertNil(sidebar.pinnedRows().first { $0.cellView is NewTabButtonCellView })
        XCTAssertTrue(sidebar.controller.isTabHoverSuppressed)

        let exited = try XCTUnwrap(NSEvent.enterExitEvent(
            with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        space.mouseExited(with: exited)
        XCTAssertFalse(sidebar.controller.isTabHoverSuppressed)
    }

    func testLockedSpaceRowsMoreButtonKeepsItsClickAndOpensTheSpaceMenu() throws {
        let sidebar = try makeScrollableSidebar(tabCount: 40, pinCount: 1, newTabsAtTop: false)
        let window = NSWindow(contentRect: sidebar.controller.view.frame, styleMask: [],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(sidebar.controller.view)
        defer { sidebar.controller.setActive(false); window.close() }
        sidebar.scroll(to: 0)
        let pinned = try XCTUnwrap(sidebar.pinnedSpaceRow())
        let cell = try XCTUnwrap(pinned.cellView as? SpaceRootCellView)
        let menu = try XCTUnwrap(cell.makeMoreMenu?())
        XCTAssertFalse(menu.items.isEmpty, "The pinned copy opens the real row's Space menu")

        // The button shows on hover; show it the way hovering does.
        let button = try XCTUnwrap(Self.subview(of: HoverableButtonNSView.self, in: cell))
        button.isHidden = false
        window.contentView?.layoutSubtreeIfNeeded()
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        let hit = try XCTUnwrap(window.contentView?.hitTest(point))
        XCTAssertTrue(hit !== pinned, "A click on the button must not fold the Space")
        XCTAssertTrue(hit !== button && hit.isDescendant(of: button),
                      "The button's hosted view, which runs its action, takes the click")
    }

    func testHoveringLockedSpaceRowKeepsPinsUnderItFromHighlighting() throws {
        let sidebar = try makeScrollableSidebar(tabCount: 40, pinCount: 1, newTabsAtTop: false)
        defer { sidebar.controller.setActive(false) }
        sidebar.scroll(to: 0)
        let space = try XCTUnwrap(sidebar.pinnedSpaceRow())
        let pinRow = try XCTUnwrap(sidebar.row(of: .bookmark))
        let pin = try XCTUnwrap(sidebar.outline.view(atColumn: 0, row: pinRow, makeIfNecessary: false)
            as? BookmarkCellView)
        XCTAssertFalse(pin.isHoverSuppressed)

        let entered = try XCTUnwrap(NSEvent.enterExitEvent(
            with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        space.mouseEntered(with: entered)
        XCTAssertTrue(pin.isHoverSuppressed)

        let exited = try XCTUnwrap(NSEvent.enterExitEvent(
            with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        space.mouseExited(with: exited)
        XCTAssertFalse(pin.isHoverSuppressed)
    }

    private static func subview<T: NSView>(of type: T.Type, in view: NSView) -> T? {
        for subview in view.subviews {
            if let match = subview as? T { return match }
            if let match = self.subview(of: type, in: subview) { return match }
        }
        return nil
    }

    private static func textField(in view: NSView) -> NSTextField? {
        for subview in view.subviews {
            if let field = subview as? NSTextField { return field }
            if let field = textField(in: subview) { return field }
        }
        return nil
    }

    func testSpaceRowStaysLockedThroughADrag() throws {
        let sidebar = try makeScrollableSidebar(tabCount: 40, pinCount: 1, newTabsAtTop: false)
        defer { sidebar.controller.setActive(false) }
        sidebar.scroll(to: 300)
        let pinned = try XCTUnwrap(sidebar.pinnedSpaceRow())
        let lockedFrame = pinned.frame
        let drag = StubDraggingInfo(location: .zero)

        sidebar.controller.outlineView(sidebar.outline, draggingEntered: drag)
        XCTAssertTrue(sidebar.pinnedSpaceRow() === pinned)
        XCTAssertEqual(pinned.frame, lockedFrame)
        XCTAssertNil(sidebar.pinnedRows().first { $0.cellView is NewTabButtonCellView },
                     "New Tab still steps aside during drags")
        XCTAssertEqual(sidebar.outline.dragAutoscrollTopObstructionHeight, lockedFrame.height, accuracy: 0.5)

        sidebar.controller.outlineView(sidebar.outline, draggingEnded: drag)
        XCTAssertTrue(sidebar.pinnedSpaceRow() === pinned)
    }

    func testDragOverLockedSpaceRowScrollsTheListUpWithoutDropping() throws {
        let sidebar = try makeScrollableSidebar(tabCount: 40, pinCount: 1, newTabsAtTop: false)
        let window = NSWindow(contentRect: sidebar.controller.view.frame, styleMask: [],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(sidebar.controller.view)
        defer { sidebar.controller.setActive(false); window.close() }
        sidebar.scroll(to: 300)
        let pinned = try XCTUnwrap(sidebar.pinnedSpaceRow())
        XCTAssertFalse(sidebar.outline.registeredDraggedTypes.isEmpty)
        XCTAssertEqual(Set(pinned.registeredDraggedTypes), Set(sidebar.outline.registeredDraggedTypes))
        XCTAssertTrue(pinned.wantsPeriodicDraggingUpdates())

        let point = pinned.convert(NSPoint(x: pinned.bounds.midX, y: pinned.bounds.midY), to: nil)
        let operation = pinned.draggingUpdated(StubDraggingInfo(location: point))
        XCTAssertEqual(operation, [])
        XCTAssertLessThan(sidebar.scrollView.contentView.bounds.origin.y, 300)
    }

    func testScrollerInsetsHoldStillWhileNewTabPinsAndUnpins() throws {
        for atTop in [true, false] {
            let sidebar = try makeScrollableSidebar(tabCount: 40, pinCount: 6, newTabsAtTop: atTop)
            defer { sidebar.controller.setActive(false) }
            let row = try XCTUnwrap(sidebar.row(of: .newTabButton))
            let rect = sidebar.outline.rect(ofRow: row)
            let range: StrideThrough<CGFloat> = atTop
                ? stride(from: rect.minY - 80, through: rect.minY + 20, by: 2)
                : stride(from: rect.maxY - sidebar.scrollView.contentView.bounds.height - 20,
                         through: rect.maxY - sidebar.scrollView.contentView.bounds.height + 20, by: 2)
            var seen = Set<String>()
            var pinStates = Set<Bool>()
            for offset in range {
                sidebar.scroll(to: offset)
                pinStates.insert(sidebar.pinnedRows().contains { $0.cellView is NewTabButtonCellView })
                let insets = sidebar.scrollView.scrollerInsets
                seen.insert("\(insets.top)/\(insets.bottom)")
            }
            XCTAssertEqual(pinStates, [true, false], "atTop \(atTop): the range crosses the pin point")
            // A knob dragged across the pin point must not see its track move.
            XCTAssertEqual(seen.count, 1, "atTop \(atTop): scroller insets changed: \(seen)")
        }
    }

    func testNewTabPinsInTheSameTurnAsTheScroll() throws {
        let sidebar = try makeScrollableSidebar(tabCount: 40, pinCount: 1, newTabsAtTop: true)
        defer { sidebar.controller.setActive(false) }
        let spaceHeight = sidebar.outline.rect(ofRow: 0).height
        let newTabRect = sidebar.outline.rect(ofRow: try XCTUnwrap(sidebar.row(of: .newTabButton)))
        let clipView = sidebar.scrollView.contentView
        func hasPinnedNewTab() -> Bool {
            sidebar.pinnedRows().contains { $0.cellView is NewTabButtonCellView }
        }

        // No layout pass and no main-queue turn: a frame drawn right after
        // the scroll must already show the pinned row.
        clipView.scroll(to: NSPoint(x: 0, y: newTabRect.minY - spaceHeight + 4))
        XCTAssertTrue(hasPinnedNewTab())
        clipView.scroll(to: .zero)
        XCTAssertFalse(hasPinnedNewTab())
    }

    func testNewTabPinsBelowPinnedSpaceRow() throws {
        let sidebar = try makeScrollableSidebar(tabCount: 40, pinCount: 1, newTabsAtTop: true)
        defer { sidebar.controller.setActive(false) }
        let spaceHeight = sidebar.outline.rect(ofRow: 0).height
        let newTabRow = try XCTUnwrap(sidebar.row(of: .newTabButton))
        let newTabRect = sidebar.outline.rect(ofRow: newTabRow)

        // New Tab still sits below the visible top, but under the pinned Space row.
        sidebar.scroll(to: newTabRect.minY - spaceHeight + 1)
        let space = try XCTUnwrap(sidebar.pinnedSpaceRow())
        let newTab = try XCTUnwrap(sidebar.pinnedRows().first { $0.cellView is NewTabButtonCellView })
        XCTAssertFalse(space.showsSeparator)
        XCTAssertTrue(newTab.showsSeparator)
        if sidebar.controller.view.isFlipped {
            XCTAssertEqual(newTab.frame.minY, space.frame.maxY, accuracy: 0.5)
        } else {
            XCTAssertEqual(newTab.frame.maxY, space.frame.minY, accuracy: 0.5)
        }
        XCTAssertEqual(sidebar.scrollView.scrollerInsets.top, space.frame.height + newTab.frame.height, accuracy: 0.5)
    }

    func testPinnedSpaceRowGoesAwayWhenSpaceHasNoPins() throws {
        let sidebar = try makeScrollableSidebar(tabCount: 40, pinCount: 1, newTabsAtTop: false)
        defer { sidebar.controller.setActive(false) }

        sidebar.scroll(to: sidebar.outline.rect(ofRow: 0).maxY + 1)
        let pinned = try XCTUnwrap(sidebar.pinnedSpaceRow())
        let pin = try XCTUnwrap(sidebar.state.bookmarkManager.rootFolder.children.first)
        sidebar.state.bookmarkManager.removeBookmark(pin)

        guard waitUntil(timeout: 2, { pinned.superview == nil }) else { return }
        XCTAssertNil(sidebar.pinnedSpaceRow())
        XCTAssertEqual(sidebar.scrollView.scrollerInsets.top, 0)
    }

    func testCreateSpaceOverlaySuppressionHidesPinnedSpaceRow() throws {
        let sidebar = try makeScrollableSidebar(tabCount: 40, pinCount: 1, newTabsAtTop: false)
        defer { sidebar.controller.setActive(false) }

        sidebar.scroll(to: sidebar.outline.rect(ofRow: 0).maxY + 1)
        let pinned = try XCTUnwrap(sidebar.pinnedSpaceRow())
        sidebar.controller.setCreateSpaceOverlayInteractionSuppressed(true)
        XCTAssertTrue(pinned.isHidden)
        sidebar.controller.viewDidLayout()
        XCTAssertTrue(pinned.isHidden)

        sidebar.controller.setCreateSpaceOverlayInteractionSuppressed(false)
        XCTAssertFalse(pinned.isHidden)
    }

    /// A Performance-layout sidebar with `tabCount` tabs and `pinCount` pins
    /// in the Space root, laid out and ready to scroll.
    private func makeScrollableSidebar(tabCount: Int, pinCount: Int,
                                       newTabsAtTop: Bool) throws -> ScrollableSidebar {
        let key = PhiPreferences.GeneralSettings.newTabsAtTop.rawValue
        let layoutKey = PhiPreferences.GeneralSettings.layoutModeKey
        let oldPreference = UserDefaults.standard.object(forKey: key)
        let oldLayout = UserDefaults.standard.object(forKey: layoutKey)
        addTeardownBlock {
            UserDefaults.standard.set(oldPreference, forKey: key)
            UserDefaults.standard.set(oldLayout, forKey: layoutKey)
        }
        UserDefaults.standard.set(newTabsAtTop, forKey: key)
        PhiPreferences.GeneralSettings.saveLayoutMode(.performance)

        let state = try makeState()
        state.tabs = (0..<tabCount).map { index in
            Tab(guid: 2000 + index, url: "https://tab.example/\(index)",
                isActive: false, index: index, title: "Tab \(index)")
        }
        state.updateNormalTabs()
        for index in 0..<pinCount {
            state.localStore.createBookmark(url: "https://pin.example/\(index)", title: "Pin \(index)",
                                            profileId: state.profileId, parentId: nil,
                                            guid: UUID().uuidString, spaceId: state.spaceId)
        }
        let (controller, outline) = try makeActiveSidebar(for: state)
        let scrollView = try XCTUnwrap(outline.enclosingScrollView)
        // Space root + pins + separator + tabs + New Tab.
        let expectedRows = 1 + pinCount + 1 + tabCount + 1
        guard waitUntil(timeout: 2, {
            outline.item(atRow: 0) is SpaceRootSidebarItem && outline.numberOfRows >= expectedRows
        }) else { throw XCTSkip("Sidebar did not finish loading") }
        controller.view.layoutSubtreeIfNeeded()
        return ScrollableSidebar(state: state, controller: controller, outline: outline, scrollView: scrollView)
    }

    private struct ScrollableSidebar {
        let state: BrowserState
        let controller: SidebarTabListViewController
        let outline: SideBarOutlineView
        let scrollView: NSScrollView

        func scroll(to offset: CGFloat) {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            controller.viewDidLayout()
        }

        func pinnedRows() -> [FloatingSidebarRowView] {
            controller.view.subviews.compactMap { $0 as? FloatingSidebarRowView }
        }

        func pinnedSpaceRow() -> FloatingSidebarRowView? {
            pinnedRows().first { $0.cellView is SpaceRootCellView }
        }

        func row(of type: SidebarItemType) -> Int? {
            (0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? SidebarItem)?.itemType == type }
        }
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

/// The few `NSDraggingInfo` members the sidebar reads, for driving drags
/// without a real drag session.
private final class StubDraggingInfo: NSObject, NSDraggingInfo {
    let draggingLocation: NSPoint
    init(location: NSPoint) { draggingLocation = location }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    let draggingPasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
        classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}

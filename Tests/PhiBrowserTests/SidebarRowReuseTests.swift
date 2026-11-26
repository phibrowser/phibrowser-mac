// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import class SwiftUI.NSHostingView
import XCTest
@testable import Phi

@MainActor
final class SidebarRowReuseTests: XCTestCase {
    private var tempDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    func testScrollingReusesRowsAndKeepsCellsBoundToTheirItems() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        let store = LocalStore(account: Account(userID: UUID().uuidString), storeDirectoryURL: directory)
        let state = BrowserState(windowId: 740, localStore: store, profileId: "Default")
        state.tabs = (0..<80).map {
            Tab(guid: 7400 + $0, url: "data:text/html,\($0)", isActive: $0 == 0,
                index: $0, title: "Row \($0)")
        }
        state.updateNormalTabs()
        state.focusingTab = state.tabs[0]
        let controller = SidebarTabListViewController(state: state)
        controller.view.frame = NSRect(x: 0, y: 0, width: 320, height: 440)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 440),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            controller.setActive(false)
            window.close()
        }
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 320, height: 440))
        controller.setActive(true)
        window.orderFront(nil)
        let scroll = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? NSScrollView }.first)
        let outline = try XCTUnwrap(scroll.documentView as? NSOutlineView)
        let deadline = Date().addingTimeInterval(2)
        while outline.numberOfRows < 80, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertGreaterThanOrEqual(outline.numberOfRows, 80)
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(outline.visibleRect.height, 300)

        // Retain identities so address recycling cannot make new rows appear reused.
        var rowViews: [ObjectIdentifier: NSTableRowView] = [:]
        var visitedTabs = Set<Int>()
        for row in stride(from: 0, to: outline.numberOfRows, by: 5) {
            outline.scrollRowToVisible(row)
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            outline.layoutSubtreeIfNeeded()
            let visible = outline.rows(in: outline.visibleRect)
            for index in visible.location..<NSMaxRange(visible) {
                guard let tab = outline.item(atRow: index) as? Tab,
                      let rowView = outline.rowView(atRow: index, makeIfNecessary: false),
                      let cell = outline.view(atColumn: 0, row: index, makeIfNecessary: false) as? SidebarTabCellView else {
                    continue
                }
                visitedTabs.insert(tab.guid)
                rowViews[ObjectIdentifier(rowView)] = rowView
                XCTAssertTrue(cell.item === tab, "a reused cell retained another tab")
                XCTAssertEqual(cell.frame.height, rowView.bounds.height, accuracy: 0.5)
                XCTAssertEqual(cell.frame.width, rowView.bounds.width, accuracy: 0.5)
            }
        }
        XCTAssertGreaterThan(visitedTabs.count, 60)
        XCTAssertLessThan(rowViews.count, visitedTabs.count / 2,
                          "scrolling should reuse a bounded set of row views")
    }

    func testScrollingExpandedBookmarksReusesRowsAndCellsWithCorrectIndentation() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        let store = LocalStore(account: Account(userID: UUID().uuidString), storeDirectoryURL: directory)
        let state = BrowserState(windowId: 742, localStore: store, profileId: "Default")
        let controller = SidebarTabListViewController(state: state)
        // Exercise the production row/cell factories and outline geometry with
        // an in-memory tree, independent of store delivery and saved expansion.
        let source = BookmarkReuseOutlineSource(controller: controller)
        let outline = SideBarOutlineView(frame: NSRect(x: 0, y: 0, width: 320, height: 440))
        outline.headerView = nil
        outline.style = .fullWidth
        outline.rowSizeStyle = .default
        outline.rowHeight = 36
        outline.autoresizingMask = [.width]
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Bookmarks"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.autoresizesOutlineColumn = true
        outline.dataSource = source
        outline.delegate = source
        let scroll = NSScrollView(frame: outline.frame)
        scroll.documentView = outline
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = scroll
        window.orderFront(nil)
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
        XCTAssertEqual(outline.numberOfRows, 88)

        // Retain views so allocator address recycling cannot fake reuse.
        var rows: [ObjectIdentifier: NSTableRowView] = [:]
        var cells: [ObjectIdentifier: BookmarkCellView] = [:]
        var visited = Set<String>()
        var levels = Set<Int>()
        for width in [320.0, 220.0] {
            window.setContentSize(NSSize(width: width, height: 440))
            scroll.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            let stops = Array(stride(from: 0, to: outline.numberOfRows, by: 5)) + [outline.numberOfRows - 1]
            for row in stops {
                outline.scrollRowToVisible(row)
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                outline.layoutSubtreeIfNeeded()
                let visible = outline.rows(in: outline.visibleRect)
                for index in visible.location..<NSMaxRange(visible) {
                    let bookmark = try XCTUnwrap(outline.item(atRow: index) as? Bookmark)
                    let rowView = try XCTUnwrap(outline.rowView(atRow: index, makeIfNecessary: false))
                    let cell = try XCTUnwrap(outline.view(atColumn: 0, row: index,
                                                         makeIfNecessary: false) as? BookmarkCellView)
                    rows[ObjectIdentifier(rowView)] = rowView
                    cells[ObjectIdentifier(cell)] = cell
                    visited.insert(bookmark.guid)
                    levels.insert(outline.level(forRow: index))
                    XCTAssertTrue(cell.item === bookmark)
                    XCTAssertEqual(cell.accessibilityLabel(), bookmark.title)
                    let indent = CGFloat(outline.level(forRow: index) * SideBarOutlineView.indentation)
                    XCTAssertEqual(cell.frame.minX, indent, accuracy: 0.5)
                    XCTAssertEqual(cell.frame.width, outline.bounds.width - indent, accuracy: 0.5)
                    XCTAssertEqual(cell.frame.height, 36, accuracy: 0.5)
                    let content = try XCTUnwrap(cell.subviews.compactMap { $0 as? SidebarBookmarkRowContentView }.first)
                    XCTAssertEqual(content.frame, cell.bounds)
                }
            }
        }
        print("Bookmark scrolling: \(visited.count) items, \(rows.count) row views, \(cells.count) cells")
        XCTAssertEqual(visited.count, 88)
        XCTAssertEqual(levels, [0, 1])
        XCTAssertLessThan(rows.count, visited.count / 2, "bookmark rows must be reused while scrolling")
        XCTAssertLessThan(cells.count, visited.count / 2, "bookmark cells must be reused while scrolling")

        outline.collapseItem(nil, collapseChildren: true)
        XCTAssertEqual(outline.numberOfRows, 8)
        outline.expandItem(nil, expandChildren: true)
        XCTAssertEqual(outline.numberOfRows, 88)
    }

    func testRemovedGroupReleasesItsCellWithoutAnotherGroupRow() throws {
        try assertRemovedGroupReleasesItsCell(windowId: 742) { state, _ in
            Self.ungroupAll(in: state)
        }
    }

    func testGroupRemovedWhileInactiveReleasesItsCellOnReactivation() throws {
        try assertRemovedGroupReleasesItsCell(windowId: 744) { state, controller in
            controller.setActive(false)
            Self.ungroupAll(in: state)
            controller.setActive(true)
        }
    }

    /// Shows one group, removes it through `removeGroup` without showing any
    /// other group, and expects the group's cell to be released.
    private func assertRemovedGroupReleasesItsCell(
        windowId: Int,
        removeGroup: (BrowserState, SidebarTabListViewController) -> Void
    ) throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        let store = LocalStore(account: Account(userID: UUID().uuidString), storeDirectoryURL: directory)
        let state = BrowserState(windowId: windowId, localStore: store, profileId: "Default")
        state.groups["released-group"] = WebContentGroupInfo(token: "released-group", title: "Group",
                                                             color: .blue, isCollapsed: false)
        state.tabs = (0..<4).map {
            Tab(guid: windowId * 10 + $0, url: "data:text/html,\($0)", isActive: $0 == 0,
                index: $0, title: "Member \($0)")
        }
        for tab in state.tabs {
            tab.groupToken = "released-group"
        }
        state.updateNormalTabs()
        let controller = SidebarTabListViewController(state: state)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 440),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            controller.setActive(false)
            window.close()
        }
        // The sidebar's own row lookups autorelease the cell. The app's event
        // loop drains those pools every turn; the test must drain them too.
        autoreleasepool {
            controller.view.frame = NSRect(x: 0, y: 0, width: 320, height: 440)
            window.contentViewController = controller
            controller.setActive(true)
            window.orderFront(nil)
        }
        let outline = try XCTUnwrap(controller.view.subviews
            .compactMap { ($0 as? NSScrollView)?.documentView as? NSOutlineView }.first)

        weak var groupCell: TabGroupCellView?
        let deadline = Date().addingTimeInterval(2)
        while groupCell == nil, Date() < deadline {
            autoreleasepool {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                outline.layoutSubtreeIfNeeded()
                for row in 0..<outline.numberOfRows {
                    if let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? TabGroupCellView {
                        groupCell = cell
                    }
                }
            }
        }
        XCTAssertNotNil(groupCell)

        autoreleasepool {
            removeGroup(state, controller)
        }
        let releaseDeadline = Date().addingTimeInterval(2)
        while groupCell != nil, Date() < releaseDeadline {
            autoreleasepool {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                outline.layoutSubtreeIfNeeded()
            }
        }
        XCTAssertNil(groupCell, "a removed group's cell must not stay cached")
    }

    private static func ungroupAll(in state: BrowserState) {
        for tab in state.tabs {
            tab.groupToken = nil
        }
        state.groups.removeAll()
        state.updateNormalTabs()
    }

    func testGroupHeaderStaysAtTheTopAcrossRowHeightChanges() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        let store = LocalStore(account: Account(userID: UUID().uuidString), storeDirectoryURL: directory)
        let state = BrowserState(windowId: 741, localStore: store, profileId: "Default")
        let controller = SidebarTabListViewController(state: state)
        let group = WebContentGroupInfo(token: "animated-group", title: "Group",
                                       color: .blue, isCollapsed: false)
        let item = TabGroupSidebarItem(group: group, browserState: state)
        let row = try XCTUnwrap(controller.outlineView(NSOutlineView(), rowViewForItem: item))
        row.frame = NSRect(x: 0, y: 0, width: 240, height: 152)
        let cell = TabGroupCellView(frame: row.bounds)
        row.addSubview(cell)
        let window = NSWindow(contentRect: row.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView?.addSubview(row)
        window.orderFront(nil)
        let header = try XCTUnwrap(cell.subviews.flatMap(\.subviews)
            .compactMap { $0 as? NSHostingView<TabGroupHeaderView> }.first)

        // Exercise intermediate heights as well as both endpoints. Checking only
        // the final cell frame misses a header detached from the resizing row.
        for height in [152.0, 116.0, 80.0, 36.0, 80.0, 116.0, 152.0] {
            row.setFrameSize(NSSize(width: 240, height: height))
            row.layoutSubtreeIfNeeded()
            XCTAssertEqual(cell.frame, row.bounds)
            let headerRect = header.convert(header.bounds, to: row)
            let topInset = row.isFlipped ? headerRect.minY : row.bounds.maxY - headerRect.maxY
            XCTAssertEqual(topInset, TabGroupCellView.containerVerticalInset, accuracy: 0.5)
        }
    }

    func testGroupMemberRowSpanLocatesTheMemberInsideALongGroup() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        let store = LocalStore(account: Account(userID: UUID().uuidString), storeDirectoryURL: directory)
        let state = BrowserState(windowId: 743, localStore: store, profileId: "Default")
        state.tabs = (0..<30).map {
            Tab(guid: 7430 + $0, url: "data:text/html,\($0)", isActive: false,
                index: $0, title: "Member \($0)")
        }
        state.tabs.forEach { $0.groupToken = "long-group" }
        state.updateNormalTabs()
        let group = WebContentGroupInfo(token: "long-group", title: "Group",
                                       color: .blue, isCollapsed: false)
        let item = TabGroupSidebarItem(group: group, browserState: state)

        let span = try XCTUnwrap(TabGroupCellView.memberRowSpan(of: state.tabs[25], in: item,
                                                                browserState: state))
        let expectedMinY = TabGroupCellView.containerVerticalInset
            + TabGroupCellView.headerHeight
            + TabGroupCellView.innerTableTopInset
            + 25 * TabGroupCellView.memberRowHeight
        XCTAssertEqual(span.minY, expectedMinY, accuracy: 0.5)
        XCTAssertEqual(span.height, TabGroupCellView.memberRowHeight, accuracy: 0.5)
        XCTAssertLessThanOrEqual(span.minY + span.height,
                                 TabGroupCellView.desiredHeight(for: item, browserState: state))

        let collapsed = TabGroupSidebarItem(
            group: WebContentGroupInfo(token: "long-group", title: "Group",
                                       color: .blue, isCollapsed: true),
            browserState: state)
        XCTAssertNil(TabGroupCellView.memberRowSpan(of: state.tabs[25], in: collapsed,
                                                    browserState: state))
    }

    func testTabContentFillsItsRowAfterResizeAndReuse() throws {
        let cell = SidebarTabCellView(frame: NSRect(x: 0, y: 0, width: 240, height: 36))
        let window = NSWindow(contentRect: cell.frame, styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = cell
        window.orderFront(nil)
        let tabView = try XCTUnwrap(cell.subviews.compactMap { $0 as? SideTabView }.first)
        for (index, width) in [180.0, 320.0, 240.0].enumerated() {
            cell.prepareForReuse()
            let tab = Tab(guid: 7500 + index, url: "data:text/html,\(index)", isActive: false,
                          index: index, title: String(repeating: "Long tab title ", count: 10))
            cell.configure(with: tab)
            window.setContentSize(NSSize(width: width, height: 36))
            cell.layoutSubtreeIfNeeded()
            XCTAssertEqual(tabView.frame, cell.bounds)
            XCTAssertTrue(cell.item === tab)
        }
    }
}

@MainActor
private final class BookmarkReuseOutlineSource: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let controller: SidebarTabListViewController
    let folders: [Bookmark]

    init(controller: SidebarTabListViewController) {
        self.controller = controller
        folders = (0..<8).map { folderIndex in
            let folder = Bookmark(folderTitle: "Folder \(folderIndex)")
            for index in 0..<10 {
                folder.addChild(Bookmark(title: "Bookmark \(folderIndex)-\(index)",
                                         url: "data:text/html,\(folderIndex)-\(index)"))
            }
            return folder
        }
        super.init()
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Bookmark)?.children.count ?? folders.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? Bookmark)?.children ?? folders)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? Bookmark)?.isFolder == true
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        controller.outlineView(outlineView, heightOfRowByItem: item)
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        controller.outlineView(outlineView, rowViewForItem: item)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        controller.outlineView(outlineView, viewFor: tableColumn, item: item)
    }
}

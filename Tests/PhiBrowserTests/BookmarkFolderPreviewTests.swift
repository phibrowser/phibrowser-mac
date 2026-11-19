// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

@MainActor
final class BookmarkFolderPreviewTests: XCTestCase {
    private typealias Layout = BookmarkFolderPreviewLayout

    // MARK: Data

    func testRecursivelyFlattensFoldersAndSplitPanesInOrder() {
        let split = Bookmark(title: "First pane", url: "https://one.example",
                             secondaryUrl: "https://two.example", secondaryTitle: "Second pane",
                             splitExtraPanes: [SplitBookmarkExtraPane(url: "https://three.example", title: "Third pane")])
        let nested = Bookmark(title: "Nested", children: [split])
        let root = Bookmark(title: "Root", children: [
            Bookmark(title: "First", url: "https://first.example"), nested,
            Bookmark(folderTitle: "Empty"), Bookmark(title: "Last", url: "https://last.example")
        ])
        let items = BookmarkFolderPreviewItem.contents(of: root)
        XCTAssertEqual(items.map(\.title), ["First", "First pane", "Second pane", "Third pane", "Last"])
        XCTAssertEqual(items.map(\.paneIndex), [0, 0, 1, 2, 0])
        XCTAssertTrue(items[2].bookmark === split)
    }

    func testSearchMatchesTitleOrURLWithoutCaseSensitivity() {
        let folder = Bookmark(title: "Root", children: [Bookmark(title: "Café", url: "https://example.com/HiddenPath")])
        let item = BookmarkFolderPreviewItem.contents(of: folder)[0]
        XCTAssertTrue(item.matches("CAFE"))
        XCTAssertTrue(item.matches("hiddenpath"))
        XCTAssertTrue(item.matches("  Café  "))
        XCTAssertTrue(item.matches("  "))
        XCTAssertFalse(item.matches("missing"))
    }

    func testEmptyDescendantFoldersDoNotProduceRows() {
        let folder = Bookmark(title: "Root", children: [Bookmark(folderTitle: "Empty")])
        XCTAssertTrue(BookmarkFolderPreviewItem.contents(of: folder).isEmpty)
    }

    func testFolderSourceIsPreviewableOnlyWhileClosedAndNotRenamed() {
        let folder = Bookmark(title: "Root", children: [Bookmark(title: "Page", url: "https://page.example")])
        XCTAssertTrue(BookmarkFolderPreviewSource.folder(folder).isCollapsed)
        folder.isExpanded = true
        XCTAssertFalse(BookmarkFolderPreviewSource.folder(folder).isCollapsed)
        folder.isExpanded = false
        folder.isEditing = true
        XCTAssertFalse(BookmarkFolderPreviewSource.folder(folder).isCollapsed)
        XCTAssertFalse(BookmarkFolderPreviewSource.folder(Bookmark(title: "Page", url: "https://page.example")).isCollapsed)
    }

    func testSpaceSourceListsEveryBookmarkOfTheSpaceWhileCollapsed() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = BrowserState(windowId: 7, localStore: LocalStore(account: Account(userID: UUID().uuidString),
                                                                     storeDirectoryURL: directory),
                                 profileId: "Default")
        let wasExpanded = state.isBookmarkRootExpanded
        defer { state.isBookmarkRootExpanded = wasExpanded }
        let root = state.bookmarkManager.rootFolder
        root.addChild(Bookmark(title: "Top", url: "https://top.example"))
        root.addChild(Bookmark(title: "Folder", children: [Bookmark(title: "Nested", url: "https://nested.example")]))
        let source = BookmarkFolderPreviewSource.space(SpaceRootSidebarItem(browserState: state))

        XCTAssertEqual(source.items.map(\.title), ["Top", "Nested"])
        state.isBookmarkRootExpanded = false
        XCTAssertTrue(source.isCollapsed)
        state.isBookmarkRootExpanded = true
        XCTAssertFalse(source.isCollapsed)
    }

    func testDisplayTitleFallsBackToHostOnlyWhenTitleIsMissingOrTheURL() {
        let folder = Bookmark(title: "Root", children: [
            Bookmark(title: "Readable", url: "https://a.example/x"),
            Bookmark(title: "https://b.example/y", url: "https://b.example/y")
        ])
        let items = BookmarkFolderPreviewItem.contents(of: folder)
        XCTAssertEqual(items.map(\.displayTitle), ["Readable", "b.example"])
    }

    func testLastOpenedTextUsesMinutesHoursYesterdayThenDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let now = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14 22:13 UTC
        func text(_ secondsAgo: TimeInterval) -> String {
            BookmarkFolderPreviewLastOpened.text(for: now.addingTimeInterval(-secondsAgo), now: now, calendar: calendar)
        }
        XCTAssertEqual(text(10), "1 min ago")
        XCTAssertEqual(text(-30), "1 min ago", "A clock skew into the future reads as just opened")
        XCTAssertEqual(text(59 * 60), "59 min ago")
        XCTAssertEqual(text(3600), "1 hour ago")
        XCTAssertEqual(text(5 * 3600 + 120), "5 hours ago")
        XCTAssertEqual(text(23 * 3600), "Yesterday", "Earlier than today's midnight is yesterday")
        XCTAssertEqual(text(2 * 86_400), "2 days ago")
        XCTAssertEqual(text(9 * 86_400), "9 days ago")
    }

    // MARK: Height and resizing

    func testHeightShrinksWithFewerResultsAndCapsAtFiveRows() {
        let one = Layout.contentHeight(resultCount: 1)
        let three = Layout.contentHeight(resultCount: 3)
        let five = Layout.contentHeight(resultCount: 5)
        XCTAssertLessThan(one, three)
        XCTAssertLessThan(three, five)
        XCTAssertEqual(Layout.contentHeight(resultCount: 50), five)
        XCTAssertEqual(five, Layout.headerHeight + Layout.separatorHeight
            + 5 * Layout.rowHeight + 2 * Layout.listVerticalInset)
        XCTAssertLessThanOrEqual(Layout.contentHeight(resultCount: 0), one,
                                 "The no-match state must stay as compact as a single row")
    }

    func testFilteringResizesFromTheBottomAndKeepsSearchPinnedToTop() {
        let host = makeHostedPreview(itemCount: 12)
        let view = host.view
        let window = host.window
        XCTAssertEqual(window.frame.height, Layout.contentHeight(resultCount: 12))
        let initialTop = window.frame.maxY
        let initialSearchTopInset = searchTopInsetInWindow(view)
        XCTAssertLessThanOrEqual(view.searchField.frame.maxY, Layout.headerHeight)

        view.setSearchText("Page 1") // Page 1, Page 10, Page 11
        XCTAssertEqual(view.results.count, 3)
        XCTAssertEqual(window.frame.height, Layout.contentHeight(resultCount: 3))
        XCTAssertEqual(window.frame.maxY, initialTop, "The panel must resize from its bottom edge")
        XCTAssertEqual(searchTopInsetInWindow(view), initialSearchTopInset, accuracy: 0.5,
                       "The search field must stay at the top while results resize")
        XCTAssertEqual(view.scrollView.frame.minY, Layout.headerHeight + Layout.separatorHeight)
        XCTAssertEqual(view.scrollView.frame.maxY, view.bounds.height)

        view.setSearchText("")
        XCTAssertEqual(window.frame.height, Layout.contentHeight(resultCount: 12))
        XCTAssertEqual(window.frame.maxY, initialTop)
        XCTAssertEqual(searchTopInsetInWindow(view), initialSearchTopInset, accuracy: 0.5)
    }

    func testMoreThanFiveResultsScrollInsideAFixedHeight() {
        let view = makeHostedPreview(itemCount: 12).view
        XCTAssertEqual(view.bounds.height, Layout.contentHeight(resultCount: 5))
        XCTAssertEqual(view.tableView.numberOfRows, 12)
        let visibleRowsHeight = view.scrollView.contentView.bounds.height - 2 * Layout.listVerticalInset
        XCTAssertEqual(visibleRowsHeight, 5 * Layout.rowHeight, accuracy: 0.5)
        XCTAssertGreaterThan(view.tableView.frame.height, visibleRowsHeight)
        XCTAssertEqual(view.scrollView.contentView.bounds.minY, -Layout.listVerticalInset, accuracy: 0.5,
                       "The list starts scrolled to its top padding")
    }

    func testNoMatchesShowsACompactEmptyStateUnderTheSearch() {
        let host = makeHostedPreview(itemCount: 4)
        let view = host.view
        view.setSearchText("nothing matches this")
        XCTAssertTrue(view.results.isEmpty)
        XCTAssertEqual(host.window.frame.height, Layout.contentHeight(resultCount: 0))
        XCTAssertTrue(view.scrollView.isHidden)
        XCTAssertFalse(view.emptyLabel.isHidden)
        XCTAssertFalse(view.emptyLabel.stringValue.isEmpty)
        XCTAssertGreaterThanOrEqual(view.emptyLabel.frame.minY, Layout.headerHeight + Layout.separatorHeight)
        XCTAssertLessThanOrEqual(view.emptyLabel.frame.maxY, view.bounds.height)

        view.setSearchText("Page")
        XCTAssertTrue(view.emptyLabel.isHidden)
        XCTAssertFalse(view.scrollView.isHidden)
    }

    // MARK: Row layout

    func testLongTitleTailTruncatesInsideTheRow() {
        let longTitle = String(repeating: "A very long bookmarked page title ", count: 12)
        let folder = Bookmark(title: "Root", children: (0..<8).map {
            Bookmark(title: longTitle, url: "https://long\($0).example")
        })
        let view = makeHostedPreview(items: BookmarkFolderPreviewItem.contents(of: folder)).view
        let clipWidth = view.scrollView.contentSize.width
        XCTAssertLessThanOrEqual(view.tableView.tableColumns[0].width, clipWidth + 0.5)
        XCTAssertLessThanOrEqual(view.tableView.frame.width, clipWidth + 0.5,
                                 "The table must never be wider than the visible list")

        let cell = view.tableView.view(atColumn: 0, row: 0, makeIfNecessary: true) as? BookmarkFolderPreviewCell
        XCTAssertNotNil(cell)
        guard let cell else { return }
        cell.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(cell.frame.maxX, clipWidth + 0.5)
        let titleFrame = cell.titleLabel.frame
        XCTAssertEqual(titleFrame.minX, Layout.textLeading)
        XCTAssertLessThanOrEqual(titleFrame.maxX, cell.bounds.width - Layout.textTrailing + 0.5)
        XCTAssertLessThanOrEqual(cell.convert(titleFrame, to: view).maxX, view.bounds.width - Layout.textTrailing + 0.5)
        XCTAssertGreaterThan(cell.titleLabel.intrinsicContentSize.width, titleFrame.width,
                             "The title is longer than its frame, so it must be truncated")
        XCTAssertEqual(cell.titleLabel.lineBreakMode, .byTruncatingTail)
        XCTAssertLessThanOrEqual(titleFrame.height, Layout.rowHeight)
        XCTAssertEqual(cell.iconView.frame.minX, Layout.iconLeading)
    }

    func testLastOpenedTimeIsASecondLineUnderTheTitle() {
        let longTitle = String(repeating: "A very long bookmarked page title ", count: 12)
        let folder = Bookmark(title: "Root", children: [
            Bookmark(title: longTitle, url: "https://seen.example", lastSeen: Date().addingTimeInterval(-3 * 86_400)),
            Bookmark(title: longTitle, url: "https://never.example")
        ])
        let view = makeHostedPreview(items: BookmarkFolderPreviewItem.contents(of: folder)).view
        let seen = view.tableView.view(atColumn: 0, row: 0, makeIfNecessary: true) as? BookmarkFolderPreviewCell
        let never = view.tableView.view(atColumn: 0, row: 1, makeIfNecessary: true) as? BookmarkFolderPreviewCell
        guard let seen, let never else { return XCTFail("Missing cells") }
        seen.layoutSubtreeIfNeeded()
        never.layoutSubtreeIfNeeded()

        let title = seen.titleLabel.frame
        let time = seen.lastOpenedLabel.frame
        XCTAssertFalse(seen.lastOpenedLabel.isHidden)
        XCTAssertEqual(seen.lastOpenedLabel.stringValue, "3 days ago")
        XCTAssertEqual(time.minX, Layout.textLeading)
        XCTAssertEqual(title.maxX, seen.bounds.width - Layout.textTrailing, accuracy: 0.5,
                       "The title keeps the full row width")
        XCTAssertGreaterThanOrEqual(time.minY, title.maxY, "The time sits below the title")
        XCTAssertGreaterThanOrEqual(title.minY, 0)
        XCTAssertLessThanOrEqual(time.maxY, seen.bounds.height)
        XCTAssertEqual(title.minY, seen.bounds.height - time.maxY, accuracy: 1, "The two lines are centered together")

        XCTAssertTrue(never.lastOpenedLabel.isHidden, "Pages never opened show no time")
        XCTAssertEqual(never.titleLabel.frame.midY, never.bounds.midY, accuracy: 1)
    }

    func testSearchFieldIsAFlatFieldWithoutBezelOrFocusRing() {
        let view = makeHostedPreview(itemCount: 2).view
        let field = view.searchField
        XCTAssertFalse(field is NSSearchField)
        XCTAssertFalse(field.isBezeled)
        XCTAssertFalse(field.isBordered)
        XCTAssertFalse(field.drawsBackground)
        XCTAssertEqual(field.focusRingType, .none)
        XCTAssertEqual(field.frame.minX, Layout.textLeading)
        XCTAssertEqual(field.placeholderAttributedString?.string, "Search Root…")
        XCTAssertEqual(view.tableView.selectionHighlightStyle, .none)
        XCTAssertEqual(view.tableView.style, .plain)
    }

    // MARK: Interaction

    func testKeyboardHighlightWrapsAroundTheResultsAndActivates() {
        let view = makeHostedPreview(itemCount: 3).view
        var activated: [String] = []
        view.onActivate = { activated.append($0.title) }
        XCTAssertNil(view.highlightedRow)

        XCTAssertTrue(sendCommand(#selector(NSResponder.moveDown(_:)), to: view))
        XCTAssertEqual(view.highlightedRow, 0)
        XCTAssertTrue(sendCommand(#selector(NSResponder.moveUp(_:)), to: view))
        XCTAssertEqual(view.highlightedRow, 2, "Up from the first result wraps to the last")
        XCTAssertTrue(sendCommand(#selector(NSResponder.moveDown(_:)), to: view))
        XCTAssertEqual(view.highlightedRow, 0, "Down from the last result wraps to the first")
        XCTAssertTrue(sendCommand(#selector(NSResponder.moveDown(_:)), to: view))
        XCTAssertTrue(sendCommand(#selector(NSResponder.insertNewline(_:)), to: view))
        XCTAssertEqual(activated, ["Page 1"])
    }

    func testTypingHighlightsTheFirstMatchAndReturnOpensIt() {
        let view = makeHostedPreview(itemCount: 12).view
        var activated: [String] = []
        view.onActivate = { activated.append($0.title) }
        view.setSearchText("page 11")
        XCTAssertEqual(view.highlightedRow, 0)
        view.activateHighlightedRow()
        XCTAssertEqual(activated, ["Page 11"])

        view.setSearchText("no such page")
        XCTAssertNil(view.highlightedRow)
        view.moveHighlight(by: 1)
        view.activateHighlightedRow()
        XCTAssertEqual(activated, ["Page 11"], "Nothing opens when there are no results")
    }

    func testPointerHoverHighlightsTheRowUnderIt() {
        let view = makeHostedPreview(itemCount: 4).view
        view.tableView.onPointerRowChange?(2)
        XCTAssertEqual(view.highlightedRow, 2)
        let rowView = view.tableView.rowView(atRow: 2, makeIfNecessary: false) as? BookmarkFolderPreviewRowView
        if let rowView { XCTAssertTrue(rowView.showsHighlight) }
        view.tableView.onPointerRowChange?(nil)
        XCTAssertNil(view.highlightedRow)
        if let rowView { XCTAssertFalse(rowView.showsHighlight) }
    }

    func testKeyboardScrollingKeepsTheKeyboardHighlightUnderAStillPointer() {
        let view = makeHostedPreview(itemCount: 12).view
        let clipView = view.scrollView.contentView
        let pointer = clipView.convert(NSPoint(x: clipView.bounds.midX, y: clipView.bounds.midY), to: nil)
        view.tableView.pointerLocationInWindow = { _ in pointer }

        for _ in 0..<8 { view.moveHighlight(by: 1) }
        XCTAssertEqual(view.highlightedRow, 7)
        XCTAssertTrue(view.tableView.rows(in: view.tableView.visibleRect).contains(7))

        clipView.scroll(to: NSPoint(x: 0, y: -Layout.listVerticalInset))
        let rowUnderPointer = view.tableView.row(at: view.tableView.convert(pointer, from: nil))
        XCTAssertGreaterThanOrEqual(rowUnderPointer, 0)
        XCTAssertEqual(view.highlightedRow, rowUnderPointer, "Scrolling the list by other means still follows the pointer")
    }

    func testEscapeInSearchFieldDismisses() {
        let view = makeHostedPreview(itemCount: 2).view
        var dismissed = false
        view.onDismiss = { dismissed = true }
        XCTAssertTrue(sendCommand(#selector(NSResponder.cancelOperation(_:)), to: view))
        XCTAssertTrue(dismissed)
        XCTAssertFalse(sendCommand(#selector(NSResponder.deleteBackward(_:)), to: view),
                       "Editing commands stay with the field editor")
    }

    func testTextEditingInTheBrowserWindowBlocksThePreview() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        hostWindows.append(window)
        let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 200, height: 24))
        window.contentView?.addSubview(field)
        XCTAssertFalse(BookmarkFolderPreview.isEditingText(in: window))

        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertTrue(BookmarkFolderPreview.isEditingText(in: window), "An active field editor blocks the preview")

        let readOnly = NSTextView(frame: NSRect(x: 10, y: 40, width: 200, height: 24))
        readOnly.isEditable = false
        window.contentView?.addSubview(readOnly)
        XCTAssertTrue(window.makeFirstResponder(readOnly))
        XCTAssertFalse(BookmarkFolderPreview.isEditingText(in: window))
    }

    // MARK: Placement

    func testLeftSidebarOpensToTheRightWithTheFirstRowLevelWithTheFolder() {
        let anchor = CGRect(x: 0, y: 500, width: 240, height: 36)
        let frame = Layout.initialFrame(contentHeight: 217, anchorScreenRect: anchor,
                                        visibleFrame: screen, opensTowardMaxX: true)
        XCTAssertEqual(frame.minX, anchor.maxX + Layout.anchorGap)
        XCTAssertEqual(frame.width, Layout.width)
        XCTAssertEqual(frame.maxY - Layout.firstRowCenterFromTop, anchor.midY, accuracy: 1)
    }

    func testFirstRowCenterMatchesTheHostedRow() {
        let view = makeHostedPreview(itemCount: 3).view
        let rowRect = view.tableView.rect(ofRow: 0)
        let rowInView = view.convert(rowRect, from: view.tableView)
        XCTAssertEqual(rowInView.midY, Layout.firstRowCenterFromTop, accuracy: 0.5)
    }

    func testRightSidebarOpensToTheLeft() {
        let anchor = CGRect(x: 1200, y: 500, width: 240, height: 36)
        let frame = Layout.initialFrame(contentHeight: 217, anchorScreenRect: anchor,
                                        visibleFrame: screen, opensTowardMaxX: false)
        XCTAssertEqual(frame.maxX, anchor.minX - Layout.anchorGap)
    }

    func testPlacementFlipsAndClampsAtScreenEdges() {
        let nearRightEdge = CGRect(x: 1300, y: 500, width: 130, height: 36)
        let flipped = Layout.initialFrame(contentHeight: 217, anchorScreenRect: nearRightEdge,
                                          visibleFrame: screen, opensTowardMaxX: true)
        XCTAssertEqual(flipped.maxX, nearRightEdge.minX - Layout.anchorGap)

        let nearBottom = CGRect(x: 0, y: 2, width: 240, height: 36)
        let clamped = Layout.initialFrame(contentHeight: 217, anchorScreenRect: nearBottom,
                                          visibleFrame: screen, opensTowardMaxX: true)
        XCTAssertGreaterThanOrEqual(clamped.minY, screen.minY + Layout.screenMargin)
        XCTAssertLessThanOrEqual(clamped.maxY, screen.maxY - Layout.screenMargin)
    }

    func testResizeKeepsTheTopEdgeUnlessTheBottomWouldLeaveTheScreen() {
        let frame = CGRect(x: 100, y: 300, width: Layout.width, height: 217)
        let shrunk = Layout.resizedFrame(frame, contentHeight: 89, visibleFrame: screen)
        XCTAssertEqual(shrunk.maxY, frame.maxY)
        XCTAssertEqual(shrunk.height, 89)
        XCTAssertEqual(shrunk.minX, frame.minX)

        let lowFrame = CGRect(x: 100, y: Layout.screenMargin, width: Layout.width, height: 89)
        let grown = Layout.resizedFrame(lowFrame, contentHeight: 217, visibleFrame: screen)
        XCTAssertEqual(grown.minY, screen.minY + Layout.screenMargin)
        XCTAssertEqual(grown.height, 217)
    }

    func testHoverRegionBridgesTheGapBetweenRowAndPanel() {
        let anchor = CGRect(x: 0, y: 500, width: 240, height: 36)
        let panel = CGRect(x: 246, y: 410, width: Layout.width, height: 217)
        XCTAssertTrue(Layout.hoverRegionContains(CGPoint(x: 100, y: 510), anchorScreenRect: anchor, panelFrame: panel))
        XCTAssertTrue(Layout.hoverRegionContains(CGPoint(x: 243, y: 518), anchorScreenRect: anchor, panelFrame: panel))
        XCTAssertTrue(Layout.hoverRegionContains(CGPoint(x: 300, y: 420), anchorScreenRect: anchor, panelFrame: panel))
        XCTAssertFalse(Layout.hoverRegionContains(CGPoint(x: 243, y: 600), anchorScreenRect: anchor, panelFrame: panel),
                       "The gap only bridges at the row's height")
        XCTAssertFalse(Layout.hoverRegionContains(CGPoint(x: 100, y: 300), anchorScreenRect: anchor, panelFrame: panel))

        let rightAnchor = CGRect(x: 1200, y: 500, width: 240, height: 36)
        let leftPanel = CGRect(x: 954, y: 410, width: Layout.width, height: 217)
        XCTAssertTrue(Layout.hoverRegionContains(CGPoint(x: 1197, y: 518), anchorScreenRect: rightAnchor, panelFrame: leftPanel))
    }

    // MARK: Helpers

    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private var hostWindows: [NSWindow] = []

    override func tearDown() {
        hostWindows.forEach { $0.orderOut(nil) }
        hostWindows.removeAll()
        super.tearDown()
    }

    private func makeHostedPreview(itemCount: Int) -> (view: BookmarkFolderPreviewContentView, window: NSWindow) {
        let folder = Bookmark(title: "Root", children: (0..<itemCount).map {
            Bookmark(title: "Page \($0)", url: "https://page\($0).example")
        })
        return makeHostedPreview(items: BookmarkFolderPreviewItem.contents(of: folder))
    }

    /// Hosts the view in a borderless window that resizes with the same rule as the preview panel.
    private func makeHostedPreview(items: [BookmarkFolderPreviewItem]) -> (view: BookmarkFolderPreviewContentView, window: NSWindow) {
        let view = BookmarkFolderPreviewContentView(items: items, placeholder: "Search Root…",
                                                    faviconLoader: { _, _ in nil })
        let window = NSWindow(contentRect: NSRect(x: 200, y: 300, width: Layout.width, height: view.preferredHeight),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.onPreferredHeightChange = { [weak window] height in
            guard let window else { return }
            window.setFrame(Layout.resizedFrame(window.frame, contentHeight: height, visibleFrame: nil), display: false)
        }
        view.layoutSubtreeIfNeeded()
        hostWindows.append(window)
        return (view, window)
    }

    /// Distance from the window's top edge to the search field's top edge.
    private func searchTopInsetInWindow(_ view: BookmarkFolderPreviewContentView) -> CGFloat {
        let field = view.searchField
        let frameInWindow = field.convert(field.bounds, to: nil)
        return (view.window?.frame.height ?? 0) - frameInWindow.maxY
    }

    private func sendCommand(_ selector: Selector, to view: BookmarkFolderPreviewContentView) -> Bool {
        view.control(view.searchField, textView: NSTextView(), doCommandBy: selector)
    }
}

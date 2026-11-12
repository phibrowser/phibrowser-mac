// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

@MainActor
final class BookmarkManagerCellViewTests: XCTestCase {
    private let scope = BookmarkManagementScope(
        accountId: "account-1",
        profileId: "profile-1",
        spaceId: "space-1"
    )

    func testSplitMarkerSymbolMatchesBookmarkLayout() {
        XCTAssertEqual(
            BookmarkManagerCellView.splitMarkerSymbolName(for: .horizontal),
            "square.split.1x2"
        )
        XCTAssertEqual(
            BookmarkManagerCellView.splitMarkerSymbolName(for: .vertical),
            "rectangle.split.2x1"
        )
        XCTAssertEqual(
            BookmarkManagerCellView.splitMarkerSymbolName(for: nil),
            "rectangle.split.2x1"
        )
    }

    func testSplitPanesDisplayAllLanesAndClearThemOnReuse() {
        let cell = BookmarkManagerCellView(frame: NSRect(x: 0, y: 0, width: 320, height: 116))
        for count in [2, 3, 4, 2] {
            let bookmark = Bookmark(
                title: "First",
                url: "https://first.example",
                secondaryUrl: "https://second.example",
                secondaryTitle: "Second",
                splitExtraPanes: (2..<count).map {
                    SplitBookmarkExtraPane(url: "https://pane\($0 + 1).example", title: "Pane \($0 + 1)")
                }
            )
            for column in [BookmarkManagerCellView.Column.website, .address] {
                cell.frame.size.height = CGFloat(count) * 29
                cell.configure(bookmark: bookmark, scope: scope, column: column, onCommit: nil)
                cell.layoutSubtreeIfNeeded()
                let fields = cell.subviews.compactMap { $0 as? NSTextField }.filter { !$0.isHidden }
                let expected = column == .website
                    ? ["First", "Second"] + (2..<count).map { "Pane \($0 + 1)" }
                    : bookmark.splitPaneURLs
                XCTAssertEqual(fields.map(\.stringValue), expected)
                XCTAssertEqual(fields.map(\.toolTip), expected.map { Optional($0) })
                XCTAssertEqual(cell.subviews.compactMap { $0 as? NSBox }.filter { !$0.isHidden }.count, count - 1)
                for index in 1..<fields.count {
                    XCTAssertEqual(abs(fields[index].frame.midY - fields[index - 1].frame.midY), 29, accuracy: 0.5)
                }
            }
        }
        cell.prepareForReuse()
        cell.configure(bookmark: Bookmark(title: "Single", url: "https://single.example"),
                       scope: scope, column: .address, onCommit: nil)
        let fields = cell.subviews.compactMap { $0 as? NSTextField }.filter { !$0.isHidden }
        XCTAssertEqual(fields.map(\.stringValue), ["https://single.example"])
        XCTAssertTrue(cell.subviews.compactMap { $0 as? NSBox }.allSatisfy(\.isHidden))
    }

    func testAddressColumnDisplaysPhiBrandedNewTabURL() throws {
        let bookmark = Bookmark(
            guid: "new-tab",
            title: "New Tab",
            url: "chrome://newtab"
        )
        let cell = BookmarkManagerCellView(frame: NSRect(x: 0, y: 0, width: 320, height: 28))

        cell.configure(
            bookmark: bookmark,
            scope: scope,
            column: .address,
            onCommit: nil
        )

        XCTAssertEqual(try XCTUnwrap(cell.textField).stringValue, "phi://newtab")
    }

    func testInlineAddressEditingStartsWithPhiBrandedURL() throws {
        let bookmark = Bookmark(
            guid: "new-tab",
            title: "New Tab",
            url: "chrome://newtab"
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 28),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let cell = BookmarkManagerCellView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = cell
        cell.configure(
            bookmark: bookmark,
            scope: scope,
            column: .address,
            onCommit: { _ in true }
        )

        cell.beginEditing()

        XCTAssertEqual(try XCTUnwrap(cell.textField).stringValue, "phi://newtab")
    }

    func testCollapsingAncestorWhileEditingLastRowCommitsOnceAfterRemoval() throws {
        for nested in [false, true] {
            let fixture = BookmarkEditingOutlineFixture(scope: scope, nested: nested)
            defer { fixture.close() }
            let (cell, editor) = try fixture.beginEditingLastRow()
            editor.string = "  Renamed folder  "

            fixture.outlineView.collapseItem(fixture.parent)

            XCTAssertEqual(fixture.outlineView.numberOfRows, 11)
            XCTAssertTrue(fixture.commits.isEmpty)
            drainMainQueue()
            XCTAssertEqual(fixture.commits, ["Renamed folder"])
            XCTAssertFalse(try XCTUnwrap(cell.textField).isEditable)
            XCTAssertNil(cell.textField?.currentEditor())
        }
    }

    func testReturnCommitsOnceAfterReleasingEditor() throws {
        let fixture = BookmarkEditingOutlineFixture(scope: scope)
        defer { fixture.close() }
        let (cell, editor) = try fixture.beginEditingLastRow()
        let field = try XCTUnwrap(cell.textField)
        editor.string = "Renamed"
        fixture.onCommit = { _ in XCTAssertNil(field.currentEditor()) }

        XCTAssertTrue(cell.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))

        drainMainQueue()
        XCTAssertEqual(fixture.commits, ["Renamed"])
        XCTAssertEqual(field.stringValue, "Renamed")
        XCTAssertFalse(field.isEditable)
    }

    func testEscapeAndEmptyInputRestoreOriginalValue() throws {
        for cancel in [true, false] {
            let fixture = BookmarkEditingOutlineFixture(scope: scope)
            defer { fixture.close() }
            let (cell, editor) = try fixture.beginEditingLastRow()
            let field = try XCTUnwrap(cell.textField)
            editor.string = cancel ? "Discarded" : "   "
            let command = cancel
                ? #selector(NSResponder.cancelOperation(_:))
                : #selector(NSResponder.insertNewline(_:))

            XCTAssertTrue(cell.control(field, textView: editor, doCommandBy: command))

            drainMainQueue()
            XCTAssertTrue(fixture.commits.isEmpty)
            XCTAssertEqual(field.stringValue, "Child")
            XCTAssertFalse(field.isEditable)
            XCTAssertNil(field.currentEditor())
        }
    }

    func testDeferredCommitSurvivesReuseWithoutChangingNewBookmark() throws {
        let fixture = BookmarkEditingOutlineFixture(scope: scope)
        defer { fixture.close() }
        let (cell, editor) = try fixture.beginEditingLastRow()
        editor.string = "Original bookmark renamed"
        XCTAssertTrue(fixture.window.makeFirstResponder(nil))
        XCTAssertTrue(fixture.commits.isEmpty)

        cell.prepareForReuse()
        cell.configure(
            bookmark: Bookmark(guid: "replacement", title: "Replacement", isFolder: true),
            scope: scope,
            column: .website,
            onCommit: { _ in XCTFail("The old edit must not commit to the replacement"); return true }
        )

        drainMainQueue()
        XCTAssertEqual(fixture.commits, ["Original bookmark renamed"])
        XCTAssertEqual(cell.textField?.stringValue, "Replacement")
        XCTAssertFalse(try XCTUnwrap(cell.textField).isEditable)
    }

    func testDeferredFinishDoesNotEndNewEditingSession() throws {
        let fixture = BookmarkEditingOutlineFixture(scope: scope)
        defer { fixture.close() }
        let (cell, editor) = try fixture.beginEditingLastRow()
        editor.string = "First edit"
        XCTAssertTrue(fixture.window.makeFirstResponder(nil))
        cell.beginEditing()
        let newEditor = try XCTUnwrap(cell.textField?.currentEditor())
        newEditor.string = "Second edit in progress"

        drainMainQueue()

        XCTAssertEqual(fixture.commits, ["First edit"])
        XCTAssertTrue(try XCTUnwrap(cell.textField).isEditable)
        XCTAssertTrue(cell.textField?.currentEditor() === newEditor)
        XCTAssertEqual(newEditor.string, "Second edit in progress")
        cell.prepareForReuse()
    }

    func testCommitThatReconfiguresCellDoesNotRestoreOldAppearance() throws {
        let fixture = BookmarkEditingOutlineFixture(scope: scope)
        defer { fixture.close() }
        let (cell, editor) = try fixture.beginEditingLastRow()
        let field = try XCTUnwrap(cell.textField)
        editor.string = "Submitted"
        fixture.onCommit = { [scope] _ in
            cell.configure(
                bookmark: Bookmark(guid: "updated", title: "Updated by model", isFolder: true),
                scope: scope,
                column: .website,
                onCommit: { _ in true }
            )
        }

        XCTAssertTrue(cell.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))

        XCTAssertEqual(fixture.commits, ["Submitted"])
        XCTAssertEqual(field.stringValue, "Updated by model")
    }

    private func drainMainQueue() {
        let drained = expectation(description: "Deferred editing has completed")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }
}

@MainActor
private final class BookmarkEditingOutlineFixture: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let window: NSWindow
    let outlineView = NSOutlineView()
    let parent = Bookmark(guid: "parent", title: "Parent", isFolder: true)
    var commits: [String] = []
    var onCommit: ((String) -> Void)?
    private let scope: BookmarkManagementScope
    private let roots: [Bookmark]

    init(scope: BookmarkManagementScope, nested: Bool = false) {
        self.scope = scope
        roots = (0..<10).map { Bookmark(title: "Sibling \($0)", isFolder: true) } + [parent]
        let child = Bookmark(guid: "child", title: "Child", isFolder: true)
        if nested {
            let inner = Bookmark(guid: "inner", title: "Inner", isFolder: true)
            inner.addChild(child)
            parent.addChild(inner)
        } else {
            parent.addChild(child)
        }
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 500),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        super.init()
        window.isReleasedWhenClosed = false
        let scrollView = NSScrollView(frame: window.contentView!.bounds)
        let column = NSTableColumn(identifier: .init("website"))
        column.width = 380
        outlineView.frame = scrollView.bounds
        outlineView.headerView = nil
        outlineView.rowHeight = 30
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.dataSource = self
        outlineView.delegate = self
        scrollView.documentView = outlineView
        window.contentView = scrollView
        outlineView.reloadData()
        outlineView.expandItem(parent, expandChildren: true)
        window.contentView?.layoutSubtreeIfNeeded()
    }

    func beginEditingLastRow() throws -> (BookmarkManagerCellView, NSTextView) {
        let row = outlineView.numberOfRows - 1
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        let cell = try XCTUnwrap(
            outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? BookmarkManagerCellView
        )
        cell.beginEditing()
        let editor = try XCTUnwrap(cell.textField?.currentEditor() as? NSTextView)
        return (cell, editor)
    }

    func close() {
        onCommit = nil
        window.makeFirstResponder(nil)
        outlineView.delegate = nil
        outlineView.dataSource = nil
        window.close()
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Bookmark)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? Bookmark)?.children ?? roots)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? Bookmark)?.children.isEmpty == false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let bookmark = item as? Bookmark else { return nil }
        let cell = BookmarkManagerCellView(frame: NSRect(x: 0, y: 0, width: 380, height: 30))
        cell.configure(bookmark: bookmark, scope: scope, column: .website, onCommit: { [weak self] value in
            self?.commits.append(value)
            self?.onCommit?(value)
            return true
        })
        return cell
    }
}

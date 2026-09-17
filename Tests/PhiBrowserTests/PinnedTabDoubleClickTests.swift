// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

@MainActor
final class PinnedTabDoubleClickTests: XCTestCase {
    func testHoverableViewRoutesSecondClickToDoubleClickAction() throws {
        let view = HoverableView()
        var clickCount = 0
        var doubleClickCount = 0
        var doubleClickModifierFlags: NSEvent.ModifierFlags = []
        view.clickAction = { clickCount += 1 }
        view.doubleClickAction = { event in
            doubleClickCount += 1
            doubleClickModifierFlags = event.modifierFlags
        }

        view.mouseUp(with: try makeMouseEvent(at: .zero, clickCount: 1))
        view.mouseUp(with: try makeMouseEvent(
            at: .zero,
            clickCount: 2,
            modifierFlags: [.command]
        ))

        XCTAssertEqual(clickCount, 1)
        XCTAssertEqual(doubleClickCount, 1)
        XCTAssertTrue(doubleClickModifierFlags.contains(.command))
    }

    func testHoverableViewPreservesSingleClickModifierFlags() throws {
        let view = HoverableView()
        var clickModifierFlags: NSEvent.ModifierFlags = []
        view.clickActionWithModifierFlags = { modifierFlags in
            clickModifierFlags = modifierFlags
        }

        view.mouseDown(with: try makeMouseEvent(
            type: .leftMouseDown,
            at: .zero,
            clickCount: 1,
            modifierFlags: [.option]
        ))
        view.mouseUp(with: try makeMouseEvent(at: .zero, clickCount: 1))

        XCTAssertTrue(clickModifierFlags.isPureOptionClick)
    }

    func testSidebarPinnedSplitDoubleClickRoutesToClickedPane() throws {
        let leftTab = Tab(guid: 1, url: "https://left.example", isActive: true, index: 0)
        let rightTab = Tab(guid: 2, url: "https://right.example", isActive: false, index: 1)
        let item = PinnedSplitItem()
        item.view.frame = CGRect(x: 0, y: 0, width: 54, height: 54)
        item.configure(leftTab: leftTab, rightTab: rightTab, themeProvider: ThemeManager.shared)
        let window = makeHostWindow(for: item.view)
        item.view.layoutSubtreeIfNeeded()

        let backgroundView = try XCTUnwrap(item.view.subviews.first as? HoverableView)
        var doubleClickedTab: Tab?
        var doubleClickModifierFlags: NSEvent.ModifierFlags = []
        item.itemDoubleClicked = { tab, modifierFlags in
            doubleClickedTab = tab
            doubleClickModifierFlags = modifierFlags
        }

        backgroundView.mouseUp(with: try makeMouseEvent(
            at: NSPoint(x: backgroundView.bounds.maxX - 1, y: backgroundView.bounds.midY),
            clickCount: 2,
            modifierFlags: [.command],
            windowNumber: window.windowNumber
        ))
        XCTAssertTrue(doubleClickedTab === rightTab)
        XCTAssertTrue(doubleClickModifierFlags.contains(.command))

        backgroundView.mouseUp(with: try makeMouseEvent(
            at: NSPoint(x: backgroundView.bounds.minX + 1, y: backgroundView.bounds.midY),
            clickCount: 2,
            windowNumber: window.windowNumber
        ))
        XCTAssertTrue(doubleClickedTab === leftTab)
    }

    func testHorizontalPinnedSplitDoubleClickRoutesToClickedPane() throws {
        let leftTab = Tab(guid: 1, url: "https://left.example", isActive: true, index: 0)
        let rightTab = Tab(guid: 2, url: "https://right.example", isActive: false, index: 1)
        let view = TabItemView()
        view.frame = CGRect(x: 0, y: 0, width: 64, height: TabStripMetrics.Strip.tabHeight)
        view.configure(with: TabRenderData(
            id: "left",
            title: "Left",
            url: "https://left.example",
            isActive: true,
            isPinned: true,
            isSplitGroupActive: true,
            pinnedSplitPartner: rightTab,
            sourceTab: leftTab
        ))
        let window = makeHostWindow(for: view)

        var selectedPane = ""
        var doubleClickModifierFlags: NSEvent.ModifierFlags = []
        view.onSecondarySelect = { _ in selectedPane = "right-single" }
        view.onDoubleSelect = { modifierFlags in
            selectedPane = "left"
            doubleClickModifierFlags = modifierFlags
        }
        view.onSecondaryDoubleSelect = { modifierFlags in
            selectedPane = "right"
            doubleClickModifierFlags = modifierFlags
        }

        view.mouseUp(with: try makeMouseEvent(
            at: NSPoint(x: view.bounds.maxX - 1, y: view.bounds.midY),
            clickCount: 2,
            modifierFlags: [.command],
            windowNumber: window.windowNumber
        ))
        XCTAssertEqual(selectedPane, "right")
        XCTAssertTrue(doubleClickModifierFlags.contains(.command))

        view.mouseUp(with: try makeMouseEvent(
            at: NSPoint(x: view.bounds.minX + 1, y: view.bounds.midY),
            clickCount: 2,
            windowNumber: window.windowNumber
        ))
        XCTAssertEqual(selectedPane, "left")
    }

    func testHoverableTabSelectsOnPressOnlyOnceAndPreservesDoubleClick() throws {
        let view = HoverableView()
        view.shouldClickOnMouseDown = { true }
        var selections = 0
        var doubleClicks = 0
        view.clickAction = { selections += 1 }
        view.doubleClickAction = { _ in doubleClicks += 1 }

        view.mouseDown(with: try makeMouseEvent(type: .leftMouseDown, at: .zero, clickCount: 1))
        XCTAssertEqual(selections, 1)
        view.mouseUp(with: try makeMouseEvent(at: .zero, clickCount: 1))
        XCTAssertEqual(selections, 1)
        view.mouseDown(with: try makeMouseEvent(type: .leftMouseDown, at: .zero, clickCount: 2))
        XCTAssertEqual(doubleClicks, 0)
        view.mouseUp(with: try makeMouseEvent(at: .zero, clickCount: 2))
        XCTAssertEqual(selections, 1)
        XCTAssertEqual(doubleClicks, 1)
    }

    func testHorizontalTabSelectsBeforeDragAndKeepsFivePointThreshold() throws {
        let view = TabItemView()
        view.frame = CGRect(x: 0, y: 0, width: 200, height: TabStripMetrics.Strip.tabHeight)
        let window = makeHostWindow(for: view)
        var selections = 0
        var dragStarts = 0
        var dragEnds = 0
        view.onSelect = { _ in selections += 1 }
        view.onDragStart = { _ in dragStarts += 1 }
        view.onDragEnd = { dragEnds += 1 }
        let start = NSPoint(x: 100, y: view.bounds.midY)
        func event(_ type: NSEvent.EventType, dx: CGFloat = 0) throws -> NSEvent {
            try makeMouseEvent(type: type, at: NSPoint(x: start.x + dx, y: start.y),
                               clickCount: 1, windowNumber: window.windowNumber)
        }

        view.mouseDown(with: try event(.leftMouseDown))
        XCTAssertEqual(selections, 1)
        // Selecting a tab may change its frame without moving the pointer.
        view.frame.origin.x += 20
        view.mouseDragged(with: try event(.leftMouseDragged, dx: 5))
        XCTAssertEqual(dragStarts, 0)
        view.mouseDragged(with: try event(.leftMouseDragged, dx: 6))
        XCTAssertEqual(dragStarts, 1)
        view.mouseUp(with: try event(.leftMouseUp, dx: 6))
        XCTAssertEqual(selections, 1)
        XCTAssertEqual(dragEnds, 1)
    }

    func testHorizontalTabCanDeferSelectionForMultiSelectionDrag() throws {
        let view = TabItemView()
        view.frame = CGRect(x: 0, y: 0, width: 200, height: TabStripMetrics.Strip.tabHeight)
        let window = makeHostWindow(for: view)
        view.shouldSelectOnMouseDown = { false }
        var selections = 0
        view.onSelect = { _ in selections += 1 }
        let point = NSPoint(x: 100, y: view.bounds.midY)
        view.mouseDown(with: try makeMouseEvent(type: .leftMouseDown, at: point,
                                               clickCount: 1, windowNumber: window.windowNumber))
        XCTAssertEqual(selections, 0)
        view.mouseUp(with: try makeMouseEvent(at: point, clickCount: 1,
                                             windowNumber: window.windowNumber))
        XCTAssertEqual(selections, 1)
    }

    func testGroupedSplitPanePressIsNotActivatedAgainByParentTable() throws {
        let fixture = GroupedSplitPressFixture()
        let window = makeHostWindow(for: fixture.table)
        fixture.table.reloadData()
        let cell = try XCTUnwrap(fixture.table.view(atColumn: 0, row: 0, makeIfNecessary: true)
            as? SidebarSplitPairCellView)
        window.contentView?.layoutSubtreeIfNeeded()
        let panes = cell.subviews.flatMap(\.subviews).compactMap { $0 as? HoverableView }
            .filter { $0.shouldClickOnMouseDown != nil }
            .sorted { $0.frame.minX < $1.frame.minX }
        XCTAssertEqual(panes.count, 2)

        for (index, pane) in panes.enumerated() {
            fixture.rowClicks = 0
            var paneClicks = 0
            pane.clickAction = { paneClicks += 1 }
            let point = pane.convert(NSPoint(x: pane.bounds.midX, y: pane.bounds.midY), to: nil)
            pane.mouseDown(with: try makeMouseEvent(type: .leftMouseDown, at: point,
                                                   clickCount: 1, windowNumber: window.windowNumber))
            XCTAssertEqual(paneClicks, 1, "Pane \(index) should activate immediately")
            XCTAssertEqual(fixture.rowClicks, 0, "The parent must not override the clicked pane")
            pane.mouseUp(with: try makeMouseEvent(at: point, clickCount: 1,
                                                 windowNumber: window.windowNumber))
            XCTAssertEqual(paneClicks, 1)
            XCTAssertEqual(fixture.rowClicks, 0, "Release must not activate the whole split")
        }
    }

    func testGroupedSplitPaneStillStartsParentDragAfterFivePoints() throws {
        let fixture = GroupedSplitPressFixture()
        let window = makeHostWindow(for: fixture.table)
        fixture.table.reloadData()
        let cell = try XCTUnwrap(fixture.table.view(atColumn: 0, row: 0, makeIfNecessary: true)
            as? SidebarSplitPairCellView)
        window.contentView?.layoutSubtreeIfNeeded()
        let pane = try XCTUnwrap(cell.subviews.flatMap(\.subviews).compactMap { $0 as? HoverableView }
            .first { $0.shouldClickOnMouseDown != nil })
        var paneClicks = 0
        pane.clickAction = { paneClicks += 1 }
        let point = pane.convert(NSPoint(x: pane.bounds.midX, y: pane.bounds.midY), to: nil)
        func event(_ type: NSEvent.EventType, dx: CGFloat = 0) throws -> NSEvent {
            try makeMouseEvent(type: type, at: NSPoint(x: point.x + dx, y: point.y),
                               clickCount: 1, windowNumber: window.windowNumber)
        }
        pane.mouseDown(with: try event(.leftMouseDown))
        pane.mouseDragged(with: try event(.leftMouseDragged, dx: 5))
        XCTAssertEqual(fixture.dragStarts, 0)
        pane.mouseDragged(with: try event(.leftMouseDragged, dx: 6))
        XCTAssertEqual(fixture.dragStarts, 1, "The parent must still track pane drags")
        pane.mouseUp(with: try event(.leftMouseUp, dx: 6))
        XCTAssertEqual(paneClicks, 1)
        XCTAssertEqual(fixture.rowClicks, 0)
    }

    private func makeHostWindow(for view: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        window.contentView?.addSubview(view)
        return window
    }

    private func makeMouseEvent(
        type: NSEvent.EventType = .leftMouseUp,
        at location: NSPoint,
        clickCount: Int,
        modifierFlags: NSEvent.ModifierFlags = [],
        windowNumber: Int = 0
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: modifierFlags,
            timestamp: 0,
            windowNumber: windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1
        ))
    }
}

@MainActor
private final class GroupedSplitPressFixture: NSObject, NSTableViewDataSource,
    NSTableViewDelegate, GroupTabsTableViewDelegate {
    let table = GroupTabsTableView(frame: NSRect(x: 0, y: 0, width: 320, height: 40))
    let cell = SidebarSplitPairCellView(frame: NSRect(x: 0, y: 0, width: 320, height: 36))
    var rowClicks = 0
    var dragStarts = 0

    override init() {
        super.init()
        table.headerView = nil
        table.rowHeight = 36
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tab")))
        table.tableColumns[0].width = 320
        table.dataSource = self
        table.delegate = self
        table.phiTableDelegate = self
        table.shouldSelectOnMouseDown = { true }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { 1 }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        cell
    }
    func tableView(_ tableView: GroupTabsTableView, didClickRow row: Int,
                   modifierFlags: NSEvent.ModifierFlags) { rowClicks += 1 }
    func tableView(_ tableView: GroupTabsTableView, beginDraggingRow row: Int,
                   with event: NSEvent) { dragStarts += 1 }
    func tableView(_ tableView: GroupTabsTableView, didMiddleClickRow row: Int,
                   at location: NSPoint) {}
    func tableView(_ tableView: GroupTabsTableView, didRequest target: GroupTabsTableInteractionTarget,
                   row: Int) {}
}

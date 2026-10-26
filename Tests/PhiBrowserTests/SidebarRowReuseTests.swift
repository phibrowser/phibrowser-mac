// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
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

    func testTabContentFillsItsRowAfterResizeAndReuse() throws {
        let cell = SidebarTabCellView(frame: NSRect(x: 0, y: 0, width: 240, height: 36))
        let window = NSWindow(contentRect: cell.frame, styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = cell
        window.orderFront(nil)
        let hosting = try XCTUnwrap(cell.subviews.compactMap { $0 as? ThemedHostingView }.first)
        for (index, width) in [180.0, 320.0, 240.0].enumerated() {
            cell.prepareForReuse()
            let tab = Tab(guid: 7500 + index, url: "data:text/html,\(index)", isActive: false,
                          index: index, title: String(repeating: "Long tab title ", count: 10))
            cell.configure(with: tab)
            window.setContentSize(NSSize(width: width, height: 36))
            cell.layoutSubtreeIfNeeded()
            XCTAssertEqual(hosting.frame, cell.bounds)
            XCTAssertTrue(cell.item === tab)
        }
    }
}

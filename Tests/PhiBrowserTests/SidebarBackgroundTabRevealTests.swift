// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import XCTest
@testable import Phi

/// A live sidebar tab list in a 320×440 window, for tests that scroll it.
@MainActor
final class SidebarTabListHarness {
    let state: BrowserState
    let controller: SidebarTabListViewController
    let scrollView: NSScrollView
    let outline: NSOutlineView
    private let window: NSWindow
    private let store: LocalStore
    private let directory: URL
    private var nextGuid: Int

    /// `ungrouped` plain tabs, then `grouped` tabs in one expanded group "g",
    /// then `trailing` plain tabs. `splitAt` joins that tab and the next into
    /// a split row.
    init(windowId: Int, ungrouped: Int, grouped: Int = 0, trailing: Int = 0, splitAt: Int? = nil) throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = LocalStore(account: Account(userID: UUID().uuidString), storeDirectoryURL: directory)
        state = BrowserState(windowId: windowId, localStore: store, profileId: "Default")
        let count = ungrouped + grouped + trailing
        state.tabs = (0..<count).map {
            Tab(guid: windowId * 1000 + $0, url: "data:text/html,\($0)", isActive: $0 == 0,
                index: $0, title: "Row \($0)")
        }
        if grouped > 0 {
            state.groups["g"] = WebContentGroupInfo(token: "g", title: "Group", color: .blue, isCollapsed: false)
            state.tabs[ungrouped..<(ungrouped + grouped)].forEach { $0.groupToken = "g" }
        }
        nextGuid = windowId * 1000 + count
        if let splitAt {
            state.splits = [SplitGroup(id: "split", tabIds: [state.tabs[splitAt].guid, state.tabs[splitAt + 1].guid],
                                       layout: .vertical, fractions: SplitGroup.equalFractions(paneCount: 2))]
        }
        state.updateNormalTabs()
        state.focusingTab = state.tabs[0]
        controller = SidebarTabListViewController(state: state)
        controller.view.frame = NSRect(x: 0, y: 0, width: 320, height: 440)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 440),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 320, height: 440))
        controller.setActive(true)
        window.orderFront(nil)
        scrollView = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? NSScrollView }.first)
        outline = try XCTUnwrap(scrollView.documentView as? NSOutlineView)
        pump(until: { self.outline.numberOfRows >= ungrouped })
        controller.view.layoutSubtreeIfNeeded()
        pump(0.3)
    }

    /// Closes the store before deleting its folder, so no pending save hits
    /// a missing database.
    func tearDown() async {
        controller.setActive(false)
        window.close()
        try? await store.closeForAccountDirectoryRemoval()
        try? FileManager.default.removeItem(at: directory)
    }

    func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func pump(until condition: () -> Bool, timeout: TimeInterval = 2) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    var visibleRect: NSRect { scrollView.contentView.documentVisibleRect }

    /// Height of the sticky New Tab row covering the list's bottom, or 0.
    var bottomOverlayHeight: CGFloat {
        controller.view.subviews.first { $0 is FloatingNewTabView }?.frame.height ?? 0
    }

    /// The part of the list no sticky row covers.
    var unobscuredVisibleRect: NSRect {
        var rect = visibleRect
        rect.size.height -= bottomOverlayHeight
        return rect
    }

    func rowRect(of tab: Tab) -> NSRect? {
        let row = outline.row(forItem: tab)
        return row >= 0 ? outline.rect(ofRow: row) : nil
    }

    func isFullyVisible(_ rect: NSRect?) -> Bool {
        guard let rect else { return false }
        let visible = unobscuredVisibleRect
        return rect.minY >= visible.minY - 0.5 && rect.maxY <= visible.maxY + 0.5
    }

    func scroll(toY y: CGFloat) {
        let clip = scrollView.contentView
        let maxY = max(0, outline.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: max(0, min(y, maxY))))
        scrollView.reflectScrolledClipView(clip)
        pump(0.05)
    }

    func focus(_ tab: Tab) {
        state.focuseTab(tab)
        pump(0.4)
    }

    /// Scrolls so `tab`'s row ends just above the sticky row at the bottom.
    func placeAtBottom(_ tab: Tab) throws {
        let rect = try XCTUnwrap(rowRect(of: tab))
        scroll(toY: rect.maxY + bottomOverlayHeight - visibleRect.height + 1)
    }

    @discardableResult
    func openInBackground(from opener: Tab, groupToken: String? = nil,
                          kind: NativeTabCreationKind = .linkBackground, active: Bool = false) -> Tab {
        let tab = Tab(guid: nextGuid, url: "https://example.test/\(nextGuid)", isActive: active,
                      index: state.tabs.count, title: "Opened \(nextGuid)")
        nextGuid += 1
        tab.groupToken = groupToken
        state.handleNewTabFromChromium(tab, context: NativeTabCreationContext(
            isActiveAtCreation: active, creationKind: kind, openerTabId: opener.guid))
        return tab
    }
}

@MainActor
final class SidebarBackgroundTabRevealTests: XCTestCase {
    private var harness: SidebarTabListHarness?

    override func tearDown() async throws {
        await harness?.tearDown()
        harness = nil
    }

    func testBackgroundLinkTabSendsSignalOnlyForInactiveLinkBackground() throws {
        let harness = try SidebarTabListHarness(windowId: 9810, ungrouped: 3)
        self.harness = harness
        var received: [Int] = []
        let subscription = harness.state.backgroundTabOpened.sink { received.append($0.guid) }
        defer { subscription.cancel() }
        let opener = harness.state.tabs[0]
        for kind: NativeTabCreationKind in [.linkForeground, .restore, .moveFromOtherWindow, .unknown] {
            harness.openInBackground(from: opener, kind: kind)
        }
        harness.openInBackground(from: opener, active: true)
        XCTAssertTrue(received.isEmpty)
        let background = harness.openInBackground(from: opener)
        XCTAssertEqual(received, [background.guid])
    }

    func testBackgroundTabBelowVisibleAreaScrollsIntoView() throws {
        let harness = try SidebarTabListHarness(windowId: 9811, ungrouped: 60)
        self.harness = harness
        let opener = harness.state.tabs[20]
        harness.focus(opener)
        try harness.placeAtBottom(opener)
        XCTAssertTrue(harness.isFullyVisible(harness.rowRect(of: opener)))

        let tab = harness.openInBackground(from: opener)
        harness.pump(until: { harness.rowRect(of: tab) != nil })
        XCTAssertFalse(harness.isFullyVisible(harness.rowRect(of: tab)), "lands under the sticky row first")
        harness.pump(0.6)

        XCTAssertTrue(harness.isFullyVisible(harness.rowRect(of: tab)))
        XCTAssertTrue(harness.isFullyVisible(harness.rowRect(of: opener)), "minimal scroll keeps the opener")
    }

    func testRevealScrollsGently() throws {
        let harness = try SidebarTabListHarness(windowId: 9816, ungrouped: 60)
        self.harness = harness
        let opener = harness.state.tabs[20]
        harness.focus(opener)
        try harness.placeAtBottom(opener)
        let tab = harness.openInBackground(from: opener)
        harness.pump(until: { harness.rowRect(of: tab) != nil })
        harness.pump(0.2)
        XCTAssertFalse(harness.isFullyVisible(harness.rowRect(of: tab)), "reveal finished within 0.2 s")
        harness.pump(0.5)
        XCTAssertTrue(harness.isFullyVisible(harness.rowRect(of: tab)))
    }

    func testBackgroundTabAlreadyVisibleDoesNotScroll() throws {
        let harness = try SidebarTabListHarness(windowId: 9812, ungrouped: 60)
        self.harness = harness
        let opener = harness.state.tabs[0]
        harness.focus(opener)
        harness.scroll(toY: 0)
        let tab = harness.openInBackground(from: opener)
        harness.pump(0.6)
        XCTAssertTrue(harness.isFullyVisible(harness.rowRect(of: tab)))
        XCTAssertEqual(harness.visibleRect.minY, 0, accuracy: 0.5)
    }

    func testBurstOfBackgroundTabsEndsOnLastOne() throws {
        let harness = try SidebarTabListHarness(windowId: 9813, ungrouped: 60)
        self.harness = harness
        let opener = harness.state.tabs[20]
        harness.focus(opener)
        try harness.placeAtBottom(opener)
        var last: Tab?
        for _ in 0..<5 {
            last = harness.openInBackground(from: opener)
        }
        harness.pump(0.8)
        XCTAssertTrue(harness.isFullyVisible(harness.rowRect(of: try XCTUnwrap(last))))
    }

    func testNoRevealWhileDragging() throws {
        let harness = try SidebarTabListHarness(windowId: 9814, ungrouped: 60)
        self.harness = harness
        let opener = harness.state.tabs[20]
        harness.focus(opener)
        try harness.placeAtBottom(opener)
        let originY = harness.visibleRect.minY
        harness.state.isDraggingTab = true
        defer { harness.state.isDraggingTab = false }
        harness.openInBackground(from: opener)
        harness.pump(0.6)
        XCTAssertEqual(harness.visibleRect.minY, originY, accuracy: 0.5)
    }

    func testBackgroundTabInGroupRevealsItsMemberRow() throws {
        let harness = try SidebarTabListHarness(windowId: 9815, ungrouped: 40, grouped: 3)
        self.harness = harness
        harness.focus(harness.state.tabs[0])
        harness.scroll(toY: 0)
        let opener = harness.state.tabs[42]
        let tab = harness.openInBackground(from: opener, groupToken: "g")
        harness.pump(0.8)

        let groupRow = (0..<harness.outline.numberOfRows).first {
            harness.outline.item(atRow: $0) is TabGroupSidebarItem
        }
        let row = try XCTUnwrap(groupRow)
        let item = try XCTUnwrap(harness.outline.item(atRow: row) as? TabGroupSidebarItem)
        let span = try XCTUnwrap(TabGroupCellView.memberRowSpan(of: tab, in: item, browserState: harness.state))
        var memberRect = harness.outline.rect(ofRow: row)
        memberRect.origin.y += span.minY
        memberRect.size.height = span.height
        XCTAssertTrue(harness.isFullyVisible(memberRect))
    }
}

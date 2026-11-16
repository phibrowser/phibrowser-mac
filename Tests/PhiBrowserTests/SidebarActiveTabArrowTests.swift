// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

@MainActor
final class SidebarActiveTabArrowTests: XCTestCase {
    private var harness: SidebarTabListHarness?

    override func tearDown() async throws {
        await harness?.tearDown()
        harness = nil
    }

    private func arrow(in harness: SidebarTabListHarness) -> SidebarActiveTabArrowView? {
        harness.controller.view.subviews.compactMap { $0 as? SidebarActiveTabArrowView }.first
    }

    func testArrowPointsUpAfterScrollingActiveTabAboveView() throws {
        let harness = try SidebarTabListHarness(windowId: 9820, ungrouped: 60)
        self.harness = harness
        harness.focus(harness.state.tabs[0])
        harness.scroll(toY: .greatestFiniteMagnitude)
        let arrow = try XCTUnwrap(arrow(in: harness))
        XCTAssertEqual(arrow.edge, .top)
        XCTAssertFalse(arrow.isHidden)
    }

    func testArrowPointsDownWhenActiveTabIsBelowViewAndClearsTheStickyRow() throws {
        let harness = try SidebarTabListHarness(windowId: 9821, ungrouped: 60)
        self.harness = harness
        harness.focus(harness.state.tabs[55])
        harness.scroll(toY: 0)
        let arrow = try XCTUnwrap(arrow(in: harness))
        XCTAssertEqual(arrow.edge, .bottom)
        harness.pump(0.3)
        let sticky = try XCTUnwrap(harness.controller.view.subviews.first {
            ($0 as? FloatingSidebarRowView)?.cellView is NewTabButtonCellView
        })
        let button = try XCTUnwrap(arrow.subviews.compactMap { $0 as? NSButton }.first)
        let buttonFrame = arrow.convert(button.frame, to: harness.controller.view)
        XCTAssertFalse(buttonFrame.intersects(sticky.frame), "arrow covers the sticky New Tab row")
    }

    func testArrowHidesWhenActiveTabIsVisible() throws {
        let harness = try SidebarTabListHarness(windowId: 9822, ungrouped: 60)
        self.harness = harness
        harness.focus(harness.state.tabs[0])
        harness.scroll(toY: .greatestFiniteMagnitude)
        harness.scroll(toY: 0)
        harness.pump(0.4)
        let arrow = try XCTUnwrap(arrow(in: harness))
        XCTAssertNil(arrow.edge)
        XCTAssertTrue(arrow.isHidden)
    }

    func testClickingArrowScrollsActiveTabBackAndHidesArrow() throws {
        let harness = try SidebarTabListHarness(windowId: 9823, ungrouped: 60)
        self.harness = harness
        let active = harness.state.tabs[0]
        harness.focus(active)
        harness.scroll(toY: .greatestFiniteMagnitude)
        let arrow = try XCTUnwrap(arrow(in: harness))
        XCTAssertEqual(arrow.edge, .top)
        arrow.clickAction?()
        harness.pump(0.6)
        XCTAssertTrue(harness.isFullyVisible(harness.rowRect(of: active)))
        XCTAssertNil(arrow.edge)
    }

    func testBackgroundBurstPushingActiveTabOutShowsArrow() throws {
        let harness = try SidebarTabListHarness(windowId: 9824, ungrouped: 60)
        self.harness = harness
        let active = harness.state.tabs[20]
        harness.focus(active)
        try harness.placeAtBottom(active)
        var last: Tab?
        for _ in 0..<15 {
            last = harness.openInBackground(from: active)
            harness.pump(0.05)
        }
        harness.pump(0.6)
        XCTAssertTrue(harness.isFullyVisible(harness.rowRect(of: try XCTUnwrap(last))))
        XCTAssertFalse(harness.isFullyVisible(harness.rowRect(of: active)))
        XCTAssertEqual(try XCTUnwrap(arrow(in: harness)).edge, .top)
    }

    func testReduceMotionJumpsToActiveTabWithoutAnimating() throws {
        let harness = try SidebarTabListHarness(windowId: 9826, ungrouped: 60)
        self.harness = harness
        harness.controller.prefersReducedMotion = { true }
        let active = harness.state.tabs[0]
        harness.focus(active)
        harness.scroll(toY: .greatestFiniteMagnitude)
        let arrow = try XCTUnwrap(arrow(in: harness))
        arrow.clickAction?()
        harness.pump(0.02)
        // The animated scroll takes 0.14 s; one turn later it is still on its way.
        XCTAssertTrue(harness.isFullyVisible(harness.rowRect(of: active)), "scroll animated under Reduce Motion")
    }

    func testArrowHidesWhenRowsAboveShrinkWithoutAScroll() throws {
        let harness = try SidebarTabListHarness(windowId: 9827, ungrouped: 3, grouped: 30, trailing: 3)
        self.harness = harness
        let active = try XCTUnwrap(harness.state.tabs.last)
        harness.focus(active)
        harness.scroll(toY: 0)
        harness.pump(0.3)
        let arrow = try XCTUnwrap(arrow(in: harness))
        XCTAssertEqual(arrow.edge, .bottom)

        harness.state.groups["g"]?.isCollapsed = true
        harness.pump(0.8)
        XCTAssertTrue(harness.isFullyVisible(harness.rowRect(of: active)), "collapse brings the row into view")
        XCTAssertNil(arrow.edge)
    }

    func testDragHidesArrowAndEndingItBringsItBack() throws {
        let harness = try SidebarTabListHarness(windowId: 9828, ungrouped: 60)
        self.harness = harness
        harness.focus(harness.state.tabs[0])
        harness.scroll(toY: .greatestFiniteMagnitude)
        let arrow = try XCTUnwrap(arrow(in: harness))
        XCTAssertEqual(arrow.edge, .top)
        harness.state.isDraggingTab = true
        harness.pump(0.1)
        XCTAssertNil(arrow.edge)
        harness.state.isDraggingTab = false
        harness.pump(0.1)
        XCTAssertEqual(arrow.edge, .top)
    }

    func testSwitchingToAnOffscreenTabDoesNotFlashTheArrow() throws {
        let harness = try SidebarTabListHarness(windowId: 9829, ungrouped: 60)
        self.harness = harness
        harness.focus(harness.state.tabs[0])
        harness.scroll(toY: 0)
        let target = harness.state.tabs[55]
        harness.state.focuseTab(target)
        var shownEdges: [SidebarActiveTabArrowEdge] = []
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            harness.pump(0.01)
            if let edge = arrow(in: harness)?.edge { shownEdges.append(edge) }
        }
        XCTAssertTrue(harness.isFullyVisible(harness.rowRect(of: target)))
        XCTAssertTrue(shownEdges.isEmpty, "arrow flashed in during the focus scroll: \(Set(shownEdges))")
    }

    func testHoveringTheArrowIsWiredToRowHoverSuppression() throws {
        let harness = try SidebarTabListHarness(windowId: 9830, ungrouped: 60)
        self.harness = harness
        harness.focus(harness.state.tabs[0])
        harness.scroll(toY: .greatestFiniteMagnitude)
        XCTAssertNotNil(try XCTUnwrap(arrow(in: harness)).hoverStateChanged)
    }

    func testArrowExitsUnderTheNewTabRowAtTheEndOfTheList() throws {
        let harness = try SidebarTabListHarness(windowId: 9832, ungrouped: 60)
        self.harness = harness
        let active = harness.state.tabs[58]
        harness.focus(active)
        let row = try XCTUnwrap(harness.rowRect(of: active))
        // Row tucked under the sticky bar: fully out of the unobscured area.
        harness.scroll(toY: row.minY + 30 - harness.visibleRect.height)
        harness.pump(0.4)
        let arrow = try XCTUnwrap(arrow(in: harness))
        XCTAssertEqual(arrow.edge, .bottom)

        // Scroll to the end: the sticky bar goes, the real New Tab row arrives.
        harness.scroll(toY: .greatestFiniteMagnitude)
        harness.pump(0.05)
        XCTAssertNil(arrow.edge)
        let newTabRow = try XCTUnwrap((0..<harness.outline.numberOfRows).first {
            (harness.outline.item(atRow: $0) as? SidebarItem)?.itemType == .newTabButton
        })
        let view = harness.controller.view
        let newTabRect = view.convert(harness.outline.rect(ofRow: newTabRow), from: harness.outline)
        let clip = arrow.convert(try XCTUnwrap(arrow.clipRect), to: view)
        XCTAssertEqual(clip.minY, newTabRect.maxY, accuracy: 0.5, "arrow exits under the New Tab row")
    }

    func testArrowLeadsBackToAnActiveSplitRow() throws {
        let harness = try SidebarTabListHarness(windowId: 9833, ungrouped: 60, splitAt: 40)
        self.harness = harness
        let pane = harness.state.tabs[41]
        harness.focus(pane)
        harness.scroll(toY: 0)
        harness.pump(0.4)
        let arrow = try XCTUnwrap(arrow(in: harness))
        XCTAssertEqual(arrow.edge, .bottom)

        arrow.clickAction?()
        harness.pump(0.6)
        let splitRow = try XCTUnwrap((0..<harness.outline.numberOfRows).first {
            harness.outline.item(atRow: $0) is SplitSidebarItem
        })
        XCTAssertTrue(harness.isFullyVisible(harness.outline.rect(ofRow: splitRow)))
        XCTAssertNil(arrow.edge)
    }

    func testDeactivateHidesArrowWithoutAnimation() throws {
        let harness = try SidebarTabListHarness(windowId: 9825, ungrouped: 60)
        self.harness = harness
        harness.focus(harness.state.tabs[0])
        harness.scroll(toY: .greatestFiniteMagnitude)
        let arrow = try XCTUnwrap(arrow(in: harness))
        XCTAssertEqual(arrow.edge, .top)
        harness.controller.setActive(false)
        XCTAssertNil(arrow.edge)
        XCTAssertTrue(arrow.isHidden)
    }
}

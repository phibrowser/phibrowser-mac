// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class SidebarSpacePaginationTests: XCTestCase {
    private typealias Layout = SidebarSpacePagination

    func testShowsIconsOnceEverySpaceFitsAtTheMinimumSlotWidth() {
        // 10 × 24 = 240 fits a 260pt row (240pt viewport) exactly.
        XCTAssertEqual(Layout.mode(count: 10, rowWidth: 260), .icons)
        XCTAssertEqual(Layout.mode(count: 10, rowWidth: 259), .dots)
        XCTAssertEqual(Layout.mode(count: 11, rowWidth: 260), .dots)
    }

    func testIconSlotsGrowWithTheRowUpToTheMaximum() {
        XCTAssertEqual(Layout.iconSlotWidth(count: 10, rowWidth: 260), 24)
        XCTAssertEqual(Layout.iconSlotWidth(count: 10, rowWidth: 300), 28)
        XCTAssertEqual(Layout.iconSlotWidth(count: 10, rowWidth: 305), 28)
        XCTAssertEqual(Layout.iconSlotWidth(count: 10, rowWidth: 600), Layout.maxIconSlotWidth)
    }

    func testBackgroundsShrinkWithNarrowSlots() {
        XCTAssertEqual(Layout.backgroundSize(forSlotWidth: 32), CGSize(width: 30, height: 26))
        XCTAssertEqual(Layout.backgroundSize(forSlotWidth: 24), CGSize(width: 22, height: 22))
    }

    func testHoveredSpaceTakesTheIconSlotFromTheActiveOne() {
        XCTAssertEqual(Layout.expandedIndex(hovered: nil, active: 2), 2)
        XCTAssertEqual(Layout.expandedIndex(hovered: 0, active: 2), 0)
        XCTAssertNil(Layout.expandedIndex(hovered: nil, active: nil))
    }

    func testDotRowSharesTheRowAndKeepsItsWidthWhileTheExpandedSlotMoves() {
        // 80pt viewport: one 22pt icon slot, three 58 / 3pt dot slots.
        let atRest = Layout.slotWidths(count: 4, rowWidth: 100, expandedIndex: 2)
        let hovering = Layout.slotWidths(count: 4, rowWidth: 100, expandedIndex: 0)

        XCTAssertEqual(atRest[2], Layout.expandedSlotWidth)
        XCTAssertEqual(atRest[0], 58.0 / 3, accuracy: 0.001)
        XCTAssertEqual(atRest.reduce(0, +), 80, accuracy: 0.001)
        XCTAssertEqual(hovering.reduce(0, +), 80, accuracy: 0.001)
    }

    func testDotSlotsStopAtTheirMinimumAndScroll() {
        let widths = Layout.slotWidths(count: 20, rowWidth: 100, expandedIndex: 0)
        XCTAssertEqual(widths[1], Layout.minDotSlotWidth)
        XCTAssertGreaterThan(Layout.maxScrollOffset(widths: widths, viewportWidth: 80), 0)
    }

    func testDotSlotsWideEnoughForAnIconStayEven() {
        let widths = Layout.slotWidths(count: 10, rowWidth: 250, expandedIndex: 3)
        XCTAssertEqual(widths, Array(repeating: 23, count: 10))
    }

    func testSwitchingModesKeepsTheRowWidth() {
        let dots = Layout.slotWidths(count: 10, rowWidth: 259, expandedIndex: 3)
        let icons = Layout.slotWidths(count: 10, rowWidth: 260, expandedIndex: 3)
        XCTAssertEqual(dots.reduce(0, +), 239, accuracy: 0.001)
        XCTAssertEqual(icons.reduce(0, +), 240)
    }

    func testIconRowUsesEqualSlots() {
        XCTAssertEqual(Layout.slotWidths(count: 3, rowWidth: 400, expandedIndex: 1),
                       Array(repeating: Layout.maxIconSlotWidth, count: 3))
    }

    func testFittingRowIsCenteredAndIgnoresScrollOffset() {
        let origins = Layout.slotOrigins(widths: [10, 20], viewportWidth: 100, scrollOffset: 40)
        XCTAssertEqual(origins, [35, 45])
    }

    func testOverflowingRowScrollsJustEnoughToRevealTheActiveSpace() {
        let widths = Array(repeating: CGFloat(10), count: 20)

        XCTAssertEqual(Layout.scrollOffset(revealing: 15, widths: widths, viewportWidth: 100, current: 0), 60)
        XCTAssertEqual(Layout.scrollOffset(revealing: 2, widths: widths, viewportWidth: 100, current: 60), 20)
        XCTAssertEqual(Layout.scrollOffset(revealing: 10, widths: widths, viewportWidth: 100, current: 60), 60)
        XCTAssertEqual(Layout.slotOrigins(widths: widths, viewportWidth: 100, scrollOffset: 60).first, -60)
    }

    func testViewportKeepsEqualEdgeInsets() {
        XCTAssertEqual(Layout.viewportWidth(for: 148), 128)
        XCTAssertEqual(Layout.viewportWidth(for: 15), 0)
    }
}

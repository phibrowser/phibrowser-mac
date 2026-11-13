// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class SidebarNewTabStickyResolverTests: XCTestCase {
    func testShowsFloatingCellAfterNewTabRowCrossesVisibleTop() {
        let rowRect = CGRect(x: 0, y: 80, width: 240, height: 36)
        let visibleRect = CGRect(x: 0, y: 90, width: 240, height: 400)

        XCTAssertTrue(SidebarNewTabStickyResolver.shouldShowFloatingNewTab(rowRect: rowRect, visibleRect: visibleRect))
    }

    func testDoesNotShowFloatingCellWhenNewTabRowIsAtVisibleTop() {
        let rowRect = CGRect(x: 0, y: 80, width: 240, height: 36)
        let visibleRect = CGRect(x: 0, y: 80, width: 240, height: 400)

        XCTAssertFalse(SidebarNewTabStickyResolver.shouldShowFloatingNewTab(rowRect: rowRect, visibleRect: visibleRect))
    }

    func testDoesNotShowFloatingCellBeforeNewTabRowReachesVisibleTop() {
        let rowRect = CGRect(x: 0, y: 120, width: 240, height: 36)
        let visibleRect = CGRect(x: 0, y: 80, width: 240, height: 400)

        XCTAssertFalse(SidebarNewTabStickyResolver.shouldShowFloatingNewTab(rowRect: rowRect, visibleRect: visibleRect))
    }

    func testVisibleRectExcludesTopOverlayHeight() {
        let visibleRect = CGRect(x: 0, y: 80, width: 240, height: 400)

        let result = SidebarNewTabStickyResolver.visibleRectExcludingTopOverlay(
            visibleRect: visibleRect,
            overlayHeight: 36
        )

        XCTAssertEqual(result, CGRect(x: 0, y: 116, width: 240, height: 364))
    }

    func testVisibleRectExcludingTopOverlayClampsToVisibleHeight() {
        let visibleRect = CGRect(x: 0, y: 80, width: 240, height: 40)

        let result = SidebarNewTabStickyResolver.visibleRectExcludingTopOverlay(
            visibleRect: visibleRect,
            overlayHeight: 80
        )

        XCTAssertEqual(result, CGRect(x: 0, y: 120, width: 240, height: 0))
    }

    func testVisibleRectExcludingTopOverlayIgnoresNegativeHeight() {
        let visibleRect = CGRect(x: 0, y: 80, width: 240, height: 400)

        let result = SidebarNewTabStickyResolver.visibleRectExcludingTopOverlay(
            visibleRect: visibleRect,
            overlayHeight: -12
        )

        XCTAssertEqual(result, visibleRect)
    }

    func testBottomCellFloatsWhenPartlyOrFullyBeyondViewport() {
        let viewport = CGRect(x: 0, y: 80, width: 240, height: 400)
        for y in [CGFloat(460), CGFloat(500)] {
            XCTAssertTrue(SidebarNewTabStickyResolver.shouldShowFloatingNewTab(
                rowRect: CGRect(x: 0, y: y, width: 240, height: 36),
                visibleRect: viewport, atTop: false))
        }
    }

    func testBottomCellRemainsInFlowWhenShortOrExactlyAtViewportBottom() {
        let viewport = CGRect(x: 0, y: 80, width: 240, height: 400)
        for y in [CGFloat(120), CGFloat(444)] {
            XCTAssertFalse(SidebarNewTabStickyResolver.shouldShowFloatingNewTab(
                rowRect: CGRect(x: 0, y: y, width: 240, height: 36),
                visibleRect: viewport, atTop: false))
        }
    }

    func testBottomOverlayExcludesTrailingAreaInBothCoordinateSystems() {
        let viewport = CGRect(x: 4, y: 80, width: 240, height: 400)
        XCTAssertEqual(SidebarNewTabStickyResolver.visibleRectExcludingOverlay(
            visibleRect: viewport, overlayHeight: 36, atTop: false),
            CGRect(x: 4, y: 80, width: 240, height: 364))
        XCTAssertEqual(SidebarNewTabStickyResolver.visibleRectExcludingOverlay(
            visibleRect: viewport, overlayHeight: 36, atTop: false, isFlipped: false),
            CGRect(x: 4, y: 116, width: 240, height: 364))
    }

    func testFloatingFrameAnchorsCorrectEdgeWhenResizedOrFlipped() {
        let scroll = CGRect(x: 8, y: 20, width: 240, height: 400)
        for flipped in [true, false] {
            let top = SidebarNewTabStickyResolver.floatingFrame(
                scrollFrame: scroll, contentWidth: 230, rowHeight: 36,
                atTop: true, containerIsFlipped: flipped)
            let bottom = SidebarNewTabStickyResolver.floatingFrame(
                scrollFrame: scroll, contentWidth: 230, rowHeight: 36,
                atTop: false, containerIsFlipped: flipped)
            XCTAssertEqual(top.minY, flipped ? 20 : 384)
            XCTAssertEqual(bottom.minY, flipped ? 384 : 20)
            XCTAssertEqual(bottom.size, CGSize(width: 230, height: 36))
        }
        XCTAssertEqual(SidebarNewTabStickyResolver.floatingFrame(
            scrollFrame: CGRect(x: 0, y: 0, width: 240, height: 20),
            contentWidth: 230, rowHeight: 36, atTop: false, containerIsFlipped: true).height, 20)
    }

    func testDragAutoscrollUsesTopOverlayAsObstructedArea() {
        let visibleRect = CGRect(x: 0, y: 100, width: 240, height: 400)

        let delta = SidebarDragAutoscrollResolver.scrollDelta(
            dragY: 150,
            visibleRect: visibleRect,
            isFlipped: true,
            topObstructionHeight: 36,
            hotZoneHeight: 92,
            minStep: 5,
            maxStep: 22
        )

        XCTAssertLessThan(delta, 0)
    }

    func testDragAutoscrollIgnoresPointerOutsideExpandedTopZone() {
        let visibleRect = CGRect(x: 0, y: 100, width: 240, height: 400)

        let delta = SidebarDragAutoscrollResolver.scrollDelta(
            dragY: 240,
            visibleRect: visibleRect,
            isFlipped: true,
            topObstructionHeight: 36,
            hotZoneHeight: 92,
            minStep: 5,
            maxStep: 22
        )

        XCTAssertEqual(delta, 0)
    }

    func testDragAutoscrollScrollsDownNearBottomEdge() {
        let visibleRect = CGRect(x: 0, y: 100, width: 240, height: 400)

        let delta = SidebarDragAutoscrollResolver.scrollDelta(
            dragY: 480,
            visibleRect: visibleRect,
            isFlipped: true,
            topObstructionHeight: 36,
            hotZoneHeight: 92,
            minStep: 5,
            maxStep: 22
        )

        XCTAssertGreaterThan(delta, 0)
    }
}

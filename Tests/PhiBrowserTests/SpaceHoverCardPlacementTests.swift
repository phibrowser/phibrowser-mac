// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// Where a Space pip's hover card lands relative to the cursor: lower right by
/// default, flipped left / above near the screen's right / bottom edge.
final class SpaceHoverCardPlacementTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let inset: CGFloat = 8
    // A 200×28 visible card plus the 8pt shadow inset on every side.
    private var panelSize: CGSize { CGSize(width: 200 + 2 * inset, height: 28 + 2 * inset) }

    private func visibleCard(cursor: CGPoint) -> CGRect {
        let origin = SpaceHoverTooltipController.panelOrigin(
            cursor: cursor, panelSize: panelSize, visibleFrame: screen)
        return CGRect(x: origin.x + inset, y: origin.y + inset, width: 200, height: 28)
    }

    func testCardSitsAtLowerRightOfCursor() {
        let cursor = CGPoint(x: 300, y: 600)
        let card = visibleCard(cursor: cursor)
        let offset = SpaceHoverTooltipController.cursorOffset
        XCTAssertEqual(card.minX, cursor.x + offset.width)
        XCTAssertEqual(card.maxY, cursor.y - offset.height)
    }

    func testCardFlipsLeftNearRightEdge() {
        let cursor = CGPoint(x: 950, y: 600)
        let card = visibleCard(cursor: cursor)
        XCTAssertEqual(card.maxX, cursor.x - SpaceHoverTooltipController.cursorFlipGap)
        XCTAssertLessThan(card.maxY, cursor.y)
    }

    func testCardFlipsAboveNearBottomEdge() {
        let cursor = CGPoint(x: 300, y: 30)
        let card = visibleCard(cursor: cursor)
        XCTAssertEqual(card.minY, cursor.y + SpaceHoverTooltipController.cursorFlipGap)
        XCTAssertGreaterThan(card.minX, cursor.x)
    }

    func testCardStaysOnScreenInCorner() {
        let card = visibleCard(cursor: CGPoint(x: 995, y: 5))
        XCTAssertTrue(screen.insetBy(dx: SpaceHoverTooltipController.screenMargin,
                                     dy: SpaceHoverTooltipController.screenMargin).contains(card))
    }
}

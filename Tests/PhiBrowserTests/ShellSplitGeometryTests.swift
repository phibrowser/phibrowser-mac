// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// The split's width rules: the user's preferred width, and the effective
/// one a container leaves it.
final class ShellSplitGeometryTests: XCTestCase {
    private let size = CGSize(width: 1000, height: 700)

    func testTheEffectiveWidthLeavesThePageItsMinimumDownToTheColumnsOwn() {
        let cases: [(preferred: CGFloat, container: CGFloat, expected: CGFloat)] = [
            (300, 1000, 300), (300, 500, 300), (300, 499, 299), (300, 400, 200), (300, 393, 193),
            (300, 300, 193), (300, 100, 193),
            (500, 700, 500), (500, 699, 499), (500, 2560, 500),
            (193, 393, 193), (193, 200, 193),
            (100, 1000, 193), (800, 1000, 500), (800, 600, 400),
        ]
        for item in cases {
            XCTAssertEqual(
                ShellSplitGeometry.effectiveWidth(preferred: item.preferred, inContainerOfWidth: item.container),
                item.expected, "preferred \(item.preferred) in \(item.container)")
        }
    }

    func testAContainerNotLaidOutYetLimitsNothing() {
        XCTAssertEqual(ShellSplitGeometry.effectiveWidth(preferred: 444, inContainerOfWidth: 0), 444)
        XCTAssertEqual(ShellSplitGeometry.maxWidth(inContainerOfWidth: 0), ShellSplitGeometry.sidebarMaxWidth)
    }

    func testTheColumnAndThePageTileTheContainerOnEitherSide() {
        var geometry = ShellSplitGeometry(sidebarOnRight: false, preferredWidth: 300, columnTakesPageSpace: true)
        XCTAssertEqual(geometry.columnFrame(in: size), CGRect(x: 0, y: 0, width: 300, height: 700))
        XCTAssertEqual(geometry.pageFrame(in: size), CGRect(x: 300, y: 0, width: 700, height: 700))
        XCTAssertEqual(geometry.dividerPosition(in: size), 300)

        geometry.sidebarOnRight = true
        XCTAssertEqual(geometry.columnFrame(in: size), CGRect(x: 700, y: 0, width: 300, height: 700))
        XCTAssertEqual(geometry.pageFrame(in: size), CGRect(x: 0, y: 0, width: 700, height: 700))
        XCTAssertEqual(geometry.dividerPosition(in: size), 700)
    }

    /// Collapsed or in flight, the page area spans the container and the
    /// column keeps its place at the edge.
    func testAColumnThatTakesNoSpaceLeavesThePageTheWholeContainer() {
        for onRight in [false, true] {
            let geometry = ShellSplitGeometry(sidebarOnRight: onRight, preferredWidth: 300,
                                              columnTakesPageSpace: false)
            XCTAssertEqual(geometry.pageFrame(in: size), CGRect(origin: .zero, size: size))
            XCTAssertEqual(geometry.columnFrame(in: size).width, 300)
            XCTAssertEqual(geometry.columnFrame(in: size).minX, onRight ? 700 : 0)
        }
    }

    func testTheDividerIsCentredOnTheColumnsInnerEdge() {
        for onRight in [false, true] {
            let geometry = ShellSplitGeometry(sidebarOnRight: onRight, preferredWidth: 300)
            let divider = geometry.dividerFrame(in: size)
            XCTAssertEqual(divider.width, ShellSplitGeometry.dividerHitThickness)
            XCTAssertEqual(divider.midX, onRight ? 700 : 300)
            XCTAssertEqual(divider.height, 700)
        }
    }

    func testASqueezedColumnStaysFlushWithItsEdge() {
        let narrow = CGSize(width: 450, height: 700)
        for onRight in [false, true] {
            let geometry = ShellSplitGeometry(sidebarOnRight: onRight, preferredWidth: 500)
            let column = geometry.columnFrame(in: narrow)
            let page = geometry.pageFrame(in: narrow)
            XCTAssertEqual(column.width, 250)
            XCTAssertEqual(page.width, 200)
            XCTAssertEqual(onRight ? column.maxX : column.minX, onRight ? 450 : 0)
            XCTAssertEqual(onRight ? page.maxX : column.maxX, onRight ? column.minX : page.minX)
        }
    }
}

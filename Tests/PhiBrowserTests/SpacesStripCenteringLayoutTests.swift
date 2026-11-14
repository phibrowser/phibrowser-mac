// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// In the sidebar header's control row, the Spaces strip sits flush right
/// while every pip fits. Narrower than its pips, it keeps the active pip
/// centered, never sliding past either end of the row, and it moves
/// continuously with the width: a narrower sidebar never makes it jump.
final class SpacesStripCenteringLayoutTests: XCTestCase {
    /// Six pips 24pt wide, 4pt apart.
    private let rowWidth: CGFloat = 6 * 24 + 5 * 4
    private func center(ofPip index: Int) -> CGFloat { CGFloat(index) * 28 + 12 }

    private func offset(_ viewportWidth: CGFloat, active index: Int) -> CGFloat {
        SpacesStripCenteringLayout.offset(rowWidth: rowWidth, viewportWidth: viewportWidth,
                                          activeCenter: center(ofPip: index))
    }

    func testARowThatFitsSitsFlushRight() {
        XCTAssertEqual(offset(rowWidth + 40, active: 0), 40)
        XCTAssertEqual(offset(rowWidth, active: 3), 0)
    }

    func testANarrowerRowCentersTheActivePip() {
        let width: CGFloat = 100
        let x = offset(width, active: 3)
        XCTAssertEqual(x + center(ofPip: 3), width / 2, accuracy: 0.001, "the active pip sits mid-row")
    }

    func testTheRowNeverSlidesPastItsEnds() {
        XCTAssertEqual(offset(100, active: 0), 0, "the first pip keeps the row against its leading end")
        XCTAssertEqual(offset(100, active: 5), 100 - rowWidth, "the last pip keeps it against its trailing end")
    }

    func testTheRowMovesContinuouslyAsTheSidebarNarrows() {
        for active in 0..<6 {
            var width = rowWidth + 60
            var previous = offset(width, active: active)
            while width > 30 {
                width -= 0.5
                let next = offset(width, active: active)
                XCTAssertLessThanOrEqual(abs(next - previous), 0.5 + 0.0001,
                    "pip \(active) jumped at width \(width)")
                previous = next
            }
        }
    }
}

// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class TabStripMultiSelectionRangeTests: XCTestCase {
    func testForwardRangeIncludesEveryVisibleUnit() {
        let units: [TabStripMultiSelectionUnit] = [
            .tab(1),
            .tab(2),
            .tab(3),
            .tab(4)
        ]

        let result = TabStripMultiSelectionRangeResolver.resolve(
            visibleUnits: units,
            storedAnchor: .tab(2),
            firstSelectedUnit: nil,
            focusedUnit: nil,
            target: .tab(4)
        )

        XCTAssertEqual(result.anchor, .tab(2))
        XCTAssertEqual(result.tabIds, [2, 3, 4])
        XCTAssertTrue(result.bookmarkGuids.isEmpty)
    }

    func testReverseRangeKeepsOriginalAnchor() {
        let units: [TabStripMultiSelectionUnit] = [
            .tab(1),
            .tab(2),
            .tab(3),
            .tab(4)
        ]

        let result = TabStripMultiSelectionRangeResolver.resolve(
            visibleUnits: units,
            storedAnchor: .tab(4),
            firstSelectedUnit: nil,
            focusedUnit: nil,
            target: .tab(2)
        )

        XCTAssertEqual(result.anchor, .tab(4))
        XCTAssertEqual(result.tabIds, [2, 3, 4])
    }

    func testSplitPairContributesBothPanesAsOneUnit() {
        let split = TabStripMultiSelectionUnit.splitPair(left: 2, right: 3)
        let units: [TabStripMultiSelectionUnit] = [
            .tab(1),
            split,
            .tab(4)
        ]

        let result = TabStripMultiSelectionRangeResolver.resolve(
            visibleUnits: units,
            storedAnchor: split,
            firstSelectedUnit: nil,
            focusedUnit: nil,
            target: .tab(4)
        )

        XCTAssertEqual(result.tabIds, [2, 3, 4])
    }

    func testRangeCarriesBookmarkBackedUnits() {
        let units: [TabStripMultiSelectionUnit] = [
            .tab(1),
            .bookmark("bookmark-a"),
            .tab(3)
        ]

        let result = TabStripMultiSelectionRangeResolver.resolve(
            visibleUnits: units,
            storedAnchor: .tab(1),
            firstSelectedUnit: nil,
            focusedUnit: nil,
            target: .tab(3)
        )

        XCTAssertEqual(result.tabIds, [1, 3])
        XCTAssertEqual(result.bookmarkGuids, ["bookmark-a"])
    }

    func testMissingStoredAnchorFallsBackToTargetOnly() {
        let units: [TabStripMultiSelectionUnit] = [.tab(1), .tab(2)]

        let result = TabStripMultiSelectionRangeResolver.resolve(
            visibleUnits: units,
            storedAnchor: .tab(99),
            firstSelectedUnit: .tab(1),
            focusedUnit: .tab(1),
            target: .tab(2)
        )

        XCTAssertEqual(result.anchor, .tab(2))
        XCTAssertEqual(result.tabIds, [2])
    }

    func testFocusedUnitSeedsRangeWhenNoAnchorOrSelectionExists() {
        let units: [TabStripMultiSelectionUnit] = [.tab(1), .tab(2), .tab(3)]

        let result = TabStripMultiSelectionRangeResolver.resolve(
            visibleUnits: units,
            storedAnchor: nil,
            firstSelectedUnit: nil,
            focusedUnit: .tab(1),
            target: .tab(3)
        )

        XCTAssertEqual(result.anchor, .tab(1))
        XCTAssertEqual(result.tabIds, [1, 2, 3])
    }
}

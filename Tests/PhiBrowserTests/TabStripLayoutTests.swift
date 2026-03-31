// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class TabStripLayoutTests: XCTestCase {

    /// Scenario: with ample container space, tabs should use the ideal width of 160 px.
    func testLayoutWhenSpaceIsAmple() {
        // 1. Build the input data.
        // Assume startOffset = 2, based on inverseCornerRadius = 8, pinnedSpacing = 2, gap = 4.
        let input = TabStripLayoutInput(
            containerWidth: 1000,   // 1000 px is wide enough for all items.
            tabCount: 3,            // Three tabs.
            activeTabIndex: 0,      // The first tab is active.
            spacing: 2,             // 2 px spacing.
            idealTabWidth: 160,     // Ideal width is 160 px.
            minTabWidth: 36,        // Minimum width is 36 px.
            activeTabWidth: 100,    // Active tab minimum preserved width is 100 px.
            tabHeight: 32,          // Tab height is 32 px.
            excludedTabIndex: nil,
            gapAtIndex: nil,
            gapWidth: nil
        )

        // 2. Run the layout calculation.
        let output = TabStripLayoutEngine.layoutNormal(input: input)

        // 3. Validate the result.

        // A. Validate counts.
        XCTAssertEqual(output.tabFrames.count, 3, "Expected frames for all three tabs.")
        XCTAssertEqual(output.separatorXPositions.count, 3, "Expected separator positions for the three-tab layout.")

        // B. Validate widths.
        // With ample space, every tab should keep the ideal width of 160 px.
        for (index, frame) in output.tabFrames.enumerated() {
            XCTAssertEqual(frame.width, 160, "Tab \(index) should have width 160 px.")
            XCTAssertEqual(frame.height, 32, "Each tab should have height 32 px.")
        }

        // C. Validate origin positions on the X axis.
        // GAP: G = 2 (leading spacing) + 1 (separator width) + 2 (trailing spacing) = 5 px.
        // Formula: startOffset = 6 (8 - 2).
        // Tab 0: 6 + 2 = 8
        // Tab 1: 8 + 160 + 5 = 173
        // Tab 2: 173 + 160 + 5 = 338
        XCTAssertEqual(output.tabFrames[0].origin.x, 8, "The first tab X origin should be 8.")
        XCTAssertEqual(output.tabFrames[1].origin.x, 173, "The second tab X origin should be 173.")
        XCTAssertEqual(output.tabFrames[2].origin.x, 338, "The third tab X origin should be 338.")

        // D. Validate the new tab button position.
        // The button should be after the last tab: lastTab.maxX + spacing = 338 + 160 + G = 503.
        XCTAssertEqual(output.newTabButtonFrame.origin.x, 503, "The new tab button X origin should be 503.")

        // E. Validate separator positions.
        // The separator is centered in the spacing: Tab0.maxX + spacing = 8 + 160 + 2 = 170.
        XCTAssertEqual(output.separatorXPositions[0], 170, "The first separator X position should be 170.")
    }

    // MARK: - Dynamic Width Tests
    /// Scenario: with slightly limited space, tab widths should shrink.
    func testLayoutWhenSpaceIsTight() {
        let input = TabStripLayoutInput(
            containerWidth: 450,
            tabCount: 3,
            activeTabIndex: 0,
            spacing: 2,
            idealTabWidth: 160,
            minTabWidth: 36,
            activeTabWidth: 100,
            tabHeight: 32,
            excludedTabIndex: nil,
            gapAtIndex: nil,
            gapWidth: nil
        )
        let output = TabStripLayoutEngine.layoutNormal(input: input)
        // Validate counts.
        XCTAssertEqual(output.tabFrames.count, 3)
        // Widths should shrink below 160 px, while staying above 36 px.
        for (index, frame) in output.tabFrames.enumerated() {
            XCTAssertLessThan(frame.width, 160, "Tab \(index) width should be below the ideal width.")
            XCTAssertGreaterThan(frame.width, 36, "Tab \(index) width should stay above the minimum width.")
        }
        // All non-active tabs should have the same width.
        let width1 = output.tabFrames[1].width
        let width2 = output.tabFrames[2].width
        XCTAssertEqual(width1, width2, "Non-active tabs should have the same width.")
    }

    /// Scenario: with extremely limited space, tabs should use the minimum width.
    func testLayoutWhenSpaceIsVeryTight() {
        // With only 100 px available, all three tabs must use the minimum width.
        let input = TabStripLayoutInput(
            containerWidth: 100,
            tabCount: 3,
            activeTabIndex: nil,
            spacing: 2,
            idealTabWidth: 160,
            minTabWidth: 36,
            activeTabWidth: 100,
            tabHeight: 32,
            excludedTabIndex: nil,
            gapAtIndex: nil,
            gapWidth: nil
        )
        let output = TabStripLayoutEngine.layoutNormal(input: input)
        // Validate counts.
        XCTAssertEqual(output.tabFrames.count, 3)

        // Every tab should use the minimum width.
        for (index, frame) in output.tabFrames.enumerated() {
            XCTAssertEqual(frame.width, 36, "Tab \(index) width should be the 36 px minimum.")
        }
    }

    /// Scenario: with extremely limited space, non-active tabs should use the minimum width while the active tab stays wide enough.
    func testLayoutWhenSpaceIsVeryTightWithActiveTab() {
        // With only 100 px available, non-active tabs must use the minimum width.
        let input = TabStripLayoutInput(
            containerWidth: 100,
            tabCount: 3,
            activeTabIndex: 1,
            spacing: 2,
            idealTabWidth: 160,
            minTabWidth: 36,
            activeTabWidth: 100,
            tabHeight: 32,
            excludedTabIndex: nil,
            gapAtIndex: nil,
            gapWidth: nil
        )
        let output = TabStripLayoutEngine.layoutNormal(input: input)
        // Validate counts.
        XCTAssertEqual(output.tabFrames.count, 3)

        let width0 = output.tabFrames[0].width
        let width2 = output.tabFrames[2].width
        let activeWidth = output.tabFrames[1].width
        XCTAssertEqual(activeWidth, 100, "The active tab width should remain 100 px.")
        XCTAssertEqual(width0, width2, "Non-active tabs should have the same width.")
    }
}

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

    /// A merged three-pane split's protected width (192) exceeds the ideal
    /// width (180): with ample room it must still get it, not shrink to
    /// ideal and fall into its favicon-only compact rendering.
    func testActiveWideSplitKeepsItsProtectedWidthWhenSpaceIsAmple() {
        let output = TabStripLayoutEngine.layoutNormal(input: splitInput(containerWidth: 2000))

        XCTAssertEqual(output.tabFrames[1].width, 192)
        XCTAssertEqual(output.tabFrames[0].width, 180)
        XCTAssertEqual(output.tabFrames[2].width, 180)
    }

    func testActiveWideSplitWidthNeverShrinksAsTheStripWidens() {
        var previousActive: CGFloat = 0
        var previousInactive: CGFloat = 0
        for containerWidth in stride(from: CGFloat(300), through: 1200, by: 10) {
            let output = TabStripLayoutEngine.layoutNormal(input: splitInput(containerWidth: containerWidth))
            let active = output.tabFrames[1].width
            let inactive = output.tabFrames[0].width
            XCTAssertGreaterThanOrEqual(active, previousActive, "containerWidth=\(containerWidth)")
            XCTAssertGreaterThanOrEqual(inactive, previousInactive, "containerWidth=\(containerWidth)")
            XCTAssertGreaterThanOrEqual(active, 192, "containerWidth=\(containerWidth)")
            previousActive = active
            previousInactive = inactive
        }
    }

    func testGroupedActiveWideSplitKeepsItsProtectedWidthWhenSpaceIsAmple() {
        let token = "g1"
        let output = TabStripLayoutEngine.layoutNormal(input: splitInput(
            containerWidth: 2000,
            groupRuns: [GroupRun(token: token, range: 2...3, isCollapsed: false)],
            chipFullWidths: [token: 120]
        ))

        XCTAssertEqual(output.tabFrames[1].width, 192)
        XCTAssertEqual(output.tabFrames[0].width, 180)
    }

    private func splitInput(
        containerWidth: CGFloat,
        groupRuns: [GroupRun] = [],
        chipFullWidths: [String: CGFloat] = [:]
    ) -> TabStripLayoutInput {
        TabStripLayoutInput(
            containerWidth: containerWidth,
            tabCount: 4,
            activeTabIndex: 1,
            spacing: 2,
            idealTabWidth: 180,
            minTabWidth: 36,
            activeTabWidth: 192,
            tabHeight: 32,
            groupRuns: groupRuns,
            chipFullWidths: chipFullWidths
        )
    }

    // MARK: - Chip width cache miss

    /// Regression: `chipFullWidths` is populated asynchronously by
    /// `TabStrip.refreshChipWidth(...)`, so a visible `GroupRun` may
    /// briefly appear with no cached measurement (newly-created group,
    /// cross-window join, frame between cache eviction and reconfigure).
    /// The engine must reserve a nonzero, hit-testable area for that
    /// chip; otherwise click / context-menu / whole-group drag silently
    /// vanish for that group until the cache catches up.
    func testGroupedLayoutFallsBackToMaxFullWidthWhenChipMeasurementMissing() {
        let token = "g1"
        let input = TabStripLayoutInput(
            containerWidth: 1000,
            tabCount: 4,
            activeTabIndex: 0,
            spacing: 2,
            idealTabWidth: 160,
            minTabWidth: 36,
            activeTabWidth: 100,
            tabHeight: 32,
            groupRuns: [GroupRun(token: token, range: 1...2, isCollapsed: false)],
            chipFullWidths: [:]  // cache miss
        )

        let output = TabStripLayoutEngine.layoutNormal(input: input)

        guard let placement = output.chipFrames[token] else {
            XCTFail("Visible group should produce a chip frame even with no cached width.")
            return
        }
        XCTAssertEqual(placement.frame.width, TabGroupChipView.maxFullWidth,
            "Cache miss must reserve `maxFullWidth` so the chip stays hit-testable.")
        XCTAssertGreaterThan(placement.frame.width, 0,
            "Chip frame must have a nonzero hit-test area.")
    }

    // MARK: - Chip right separator

    /// Expanded chip emits a right separator positioned between chip
    /// and its first member tab, with neighbor index = run.lowerBound.
    func testExpandedChipEmitsRightSeparatorTargetingFirstMember() {
        let token = "g1"
        let input = TabStripLayoutInput(
            containerWidth: 1000,
            tabCount: 4,
            activeTabIndex: 0,
            spacing: 2,
            idealTabWidth: 160,
            minTabWidth: 36,
            activeTabWidth: 100,
            tabHeight: 32,
            groupRuns: [GroupRun(token: token, range: 1...2, isCollapsed: false)],
            chipFullWidths: [token: 120]
        )

        let output = TabStripLayoutEngine.layoutNormal(input: input)
        guard let placement = output.chipFrames[token] else {
            XCTFail("Expected chip placement for visible expanded group.")
            return
        }
        XCTAssertNotNil(placement.rightSeparatorX,
            "Expanded chip with a following member must emit a right separator.")
        XCTAssertEqual(placement.rightSeparatorNeighborIndex, 1,
            "Right separator neighbor index should be run.lowerBound (the first member).")
        if let sepX = placement.rightSeparatorX {
            XCTAssertGreaterThan(sepX, placement.frame.maxX,
                "Right separator sits to the right of the chip frame.")
        }
    }

    /// Collapsed chip targets the first tab AFTER the run for hide-rule
    /// purposes (its members are zero-width placeholders).
    func testCollapsedChipRightSeparatorTargetsTabAfterRun() {
        let token = "g1"
        let input = TabStripLayoutInput(
            containerWidth: 1000,
            tabCount: 4,
            activeTabIndex: 0,
            spacing: 2,
            idealTabWidth: 160,
            minTabWidth: 36,
            activeTabWidth: 100,
            tabHeight: 32,
            groupRuns: [GroupRun(token: token, range: 1...2, isCollapsed: true)],
            chipFullWidths: [token: 120]
        )

        let output = TabStripLayoutEngine.layoutNormal(input: input)
        guard let placement = output.chipFrames[token] else {
            XCTFail("Expected chip placement for visible collapsed group.")
            return
        }
        XCTAssertNotNil(placement.rightSeparatorX,
            "Collapsed chip with a following tab must emit a right separator.")
        XCTAssertEqual(placement.rightSeparatorNeighborIndex, 3,
            "Collapsed chip's right separator neighbor should be run.upperBound + 1.")
    }

    /// Group occupying the strip's tail (no tab after) emits no right
    /// separator — there is no neighbor to draw against.
    func testChipAtStripEndEmitsNoRightSeparator() {
        let token = "g1"
        let input = TabStripLayoutInput(
            containerWidth: 1000,
            tabCount: 3,
            activeTabIndex: 0,
            spacing: 2,
            idealTabWidth: 160,
            minTabWidth: 36,
            activeTabWidth: 100,
            tabHeight: 32,
            groupRuns: [GroupRun(token: token, range: 1...2, isCollapsed: true)],
            chipFullWidths: [token: 120]
        )

        let output = TabStripLayoutEngine.layoutNormal(input: input)
        guard let placement = output.chipFrames[token] else {
            XCTFail("Expected chip placement for visible group.")
            return
        }
        XCTAssertNil(placement.rightSeparatorX,
            "Collapsed group at strip end has no neighbor → no right separator.")
        XCTAssertNil(placement.rightSeparatorNeighborIndex,
            "Neighbor index must be nil when there is no separator.")
    }

    // MARK: - Drag exclusion double-count

    /// Regression: `TabStrip.layout()` passes the dragged index through
    /// BOTH `excludedTabIndex` and `excludedTabIndices`. Counting the two
    /// forms separately removes a phantom second slot from
    /// `effectiveTabCount`, so every remaining tab visibly widens during
    /// a drag even though the reserved gap already compensates for the
    /// dragged tab's own slot.
    func testDragExclusionInBothFormsDoesNotWidenRemainingTabs() {
        // Baseline: 5 tabs in 673 px. fixed = 6 + 5*5 + 2 + 40 = 73,
        // available = 600, base = 120 (medium pressure: all tabs 120).
        let baseline = TabStripLayoutInput(
            containerWidth: 673,
            tabCount: 5,
            activeTabIndex: 0,
            spacing: 2,
            idealTabWidth: 160,
            minTabWidth: 36,
            activeTabWidth: 100,
            tabHeight: 32
        )
        let baselineOutput = TabStripLayoutEngine.layoutNormal(input: baseline)
        for frame in baselineOutput.tabFrames {
            XCTAssertEqual(frame.width, 120, accuracy: 0.001)
        }

        // Drag tab 2: excluded via both forms, gap reserves its slot.
        // Correct: effective = 4, fixed = 6 + 4*5 + 2 + 40 + 120 = 188,
        // available = 485, base = 121.25 — within one overhead unit of
        // the baseline. Double-counting would yield effective = 3,
        // base = 163.3 → clamped to ideal 160 (visible widening).
        let dragging = TabStripLayoutInput(
            containerWidth: 673,
            tabCount: 5,
            activeTabIndex: 0,
            spacing: 2,
            idealTabWidth: 160,
            minTabWidth: 36,
            activeTabWidth: 100,
            tabHeight: 32,
            excludedTabIndex: 2,
            excludedTabIndices: [2],
            gapAtIndex: 2,
            gapWidth: 120
        )
        let output = TabStripLayoutEngine.layoutNormal(input: dragging)

        XCTAssertEqual(output.tabFrames[2], .zero, "Dragged tab gets a placeholder frame.")
        for index in [0, 1, 3, 4] {
            XCTAssertEqual(output.tabFrames[index].width, 121.25, accuracy: 0.001,
                "Tab \(index) must keep ~its pre-drag width while tab 2 is dragged.")
        }
    }

    /// Same regression for the group-aware path: a group on the strip
    /// routes layout through `layoutNormalWithGroups`, which counted the
    /// single and set exclusion forms separately too.
    func testGroupedDragExclusionInBothFormsDoesNotWidenRemainingTabs() {
        // 5 tabs, expanded group over 0...1 with a 100 px chip.
        // chipsOverhead = 100 + 4 + 1 = 105.
        // Correct: effective = 4, fixed = 6 + 4*5 + 2 + 40 + 120 = 188,
        // available = 778 - 188 - 105 = 485, base = 121.25.
        // Double-counting would yield effective = 3, base = 163.3 →
        // clamped to ideal 160 (visible widening).
        let token = "g1"
        let input = TabStripLayoutInput(
            containerWidth: 778,
            tabCount: 5,
            activeTabIndex: 2,
            spacing: 2,
            idealTabWidth: 160,
            minTabWidth: 36,
            activeTabWidth: 100,
            tabHeight: 32,
            excludedTabIndex: 3,
            excludedTabIndices: [3],
            gapAtIndex: 3,
            gapWidth: 120,
            groupRuns: [GroupRun(token: token, range: 0...1, isCollapsed: false)],
            chipFullWidths: [token: 100]
        )
        let output = TabStripLayoutEngine.layoutNormal(input: input)

        XCTAssertEqual(output.tabFrames[3], .zero, "Dragged tab gets a placeholder frame.")
        for index in [0, 1, 2, 4] {
            XCTAssertEqual(output.tabFrames[index].width, 121.25, accuracy: 0.001,
                "Tab \(index) must keep ~its pre-drag width while tab 3 is dragged.")
        }
    }

    /// Whole-group drag form (`excludedGroupRange`) overlapping the other
    /// two exclusion forms must count each index once. Pre-fix, range +
    /// set + single were subtracted independently (5 - 2 - 1 - 1 = 1
    /// effective tab instead of 3).
    func testGroupRangeOverlappingOtherFormsCountsEachIndexOnce() {
        // Union = {1, 2} → effective = 3, fixed = 6 + 3*5 + 2 + 40 = 63,
        // available = 423 - 63 = 360, base = 120 (medium pressure).
        let input = TabStripLayoutInput(
            containerWidth: 423,
            tabCount: 5,
            activeTabIndex: 4,
            spacing: 2,
            idealTabWidth: 160,
            minTabWidth: 36,
            activeTabWidth: 100,
            tabHeight: 32,
            excludedTabIndex: 1,
            excludedGroupRange: 1...2,
            excludedTabIndices: [1]
        )
        let output = TabStripLayoutEngine.layoutNormal(input: input)

        XCTAssertEqual(output.tabFrames[1], .zero)
        XCTAssertEqual(output.tabFrames[2], .zero)
        for index in [0, 3, 4] {
            XCTAssertEqual(output.tabFrames[index].width, 120, accuracy: 0.001,
                "Tab \(index) must reflect a 3-way split of the available width.")
        }
    }

    /// Production whole-group drag shape: the dragged group is
    /// temp-collapsed before the drag, so `excludedGroupRange` fully
    /// overlaps `collapsedMemberSet`. The overlap must be subtracted
    /// exactly once (collapsed members are already zero-width).
    func testWholeGroupDragOfCollapsedGroupIsNotDoubleSubtracted() {
        // collapsed = {0, 1}, range = 0...1 → net drag exclusion = 0,
        // effective = 3. chipsOverhead = 100 + 4 + 1 = 105,
        // fixed = 6 + 3*5 + 2 + 40 = 63, available = 528 - 63 - 105 = 360,
        // base = 120. Double-subtracting would yield effective = 1 →
        // base clamped to ideal 160.
        let token = "g1"
        let input = TabStripLayoutInput(
            containerWidth: 528,
            tabCount: 5,
            activeTabIndex: 4,
            spacing: 2,
            idealTabWidth: 160,
            minTabWidth: 36,
            activeTabWidth: 100,
            tabHeight: 32,
            excludedGroupRange: 0...1,
            groupRuns: [GroupRun(token: token, range: 0...1, isCollapsed: true)],
            chipFullWidths: [token: 100]
        )
        let output = TabStripLayoutEngine.layoutNormal(input: input)

        XCTAssertEqual(output.tabFrames[0], .zero)
        XCTAssertEqual(output.tabFrames[1], .zero)
        for index in [2, 3, 4] {
            XCTAssertEqual(output.tabFrames[index].width, 120, accuracy: 0.001,
                "Tab \(index) must reflect a 3-way split; the collapsed run is not subtracted twice.")
        }
    }

    /// Split-pair drag shape: a two-element set (dragged tab + partner)
    /// with the single form mirroring one of them, plus a two-slot gap.
    /// Pre-fix this combination triple-counted (5 - 2 - 1 = 2 effective).
    func testSplitPairExclusionWithTwoSlotGapKeepsWidthsStable() {
        // Union = {2, 3} → effective = 3,
        // fixed = 6 + 3*5 + 2 + 40 + 240 = 303,
        // available = 678 - 303 = 375, base = 125 (medium pressure).
        let input = TabStripLayoutInput(
            containerWidth: 678,
            tabCount: 5,
            activeTabIndex: 0,
            spacing: 2,
            idealTabWidth: 160,
            minTabWidth: 36,
            activeTabWidth: 100,
            tabHeight: 32,
            excludedTabIndex: 2,
            excludedTabIndices: [2, 3],
            gapAtIndex: 2,
            gapWidth: 240
        )
        let output = TabStripLayoutEngine.layoutNormal(input: input)

        XCTAssertEqual(output.tabFrames[2], .zero)
        XCTAssertEqual(output.tabFrames[3], .zero)
        for index in [0, 1, 4] {
            XCTAssertEqual(output.tabFrames[index].width, 125, accuracy: 0.001,
                "Tab \(index) must keep ~its pre-drag width while the split pair is dragged.")
        }
    }

    /// Regression: during a whole-group drag the active tab can sit INSIDE
    /// the dragged range (`excludedGroupRange` only — no single/set form).
    /// The tight branch must not reserve the active minimum for it,
    /// otherwise every remaining tab shrinks and dead slack opens before
    /// the new-tab button for the whole drag.
    func testGroupedTightLayoutSkipsActiveReservationWhenActiveInsideDraggedGroup() {
        // Run covers 1...3, active = 2 (inside), whole range excluded →
        // effective = 6 - 3 = 3.
        // chipsOverhead = 40 + 2*2 + 1 = 45,
        // fixed = 6 (start) + 3*5 (per tab) + 2 + 40 (button) = 63,
        // available = 348 - 63 - 45 = 240 → base = 80 (tight, < 100).
        let input = TabStripLayoutInput(
            containerWidth: 348,
            tabCount: 6,
            activeTabIndex: 2,
            spacing: 2,
            idealTabWidth: 180,
            minTabWidth: 36,
            activeTabWidth: 100,
            tabHeight: 32,
            excludedGroupRange: 1...3,
            groupRuns: [GroupRun(token: "g", range: 1...3, isCollapsed: false)],
            chipFullWidths: ["g": 40]
        )
        let output = TabStripLayoutEngine.layoutNormal(input: input)

        for index in [1, 2, 3] {
            XCTAssertEqual(output.tabFrames[index], .zero,
                "Dragged group member \(index) must be lifted out of the flow.")
        }
        for index in [0, 4, 5] {
            XCTAssertEqual(output.tabFrames[index].width, 80, accuracy: 0.001,
                "Tab \(index) must get an even 3-way split; no active reservation for the lifted-out group member.")
        }
    }

    /// Ungrouped companion: the dragged active tab arriving via the single
    /// exclusion form alone must not keep its width reservation either.
    func testTightLayoutSkipsActiveReservationWhenActiveDraggedViaSingleForm() {
        // fixed = 6 + 3*5 + 2 + 40 = 63, available = 303 - 63 = 240 → base 80.
        let input = TabStripLayoutInput(
            containerWidth: 303,
            tabCount: 4,
            activeTabIndex: 1,
            spacing: 2,
            idealTabWidth: 180,
            minTabWidth: 36,
            activeTabWidth: 100,
            tabHeight: 32,
            excludedTabIndex: 1
        )
        let output = TabStripLayoutEngine.layoutNormal(input: input)

        XCTAssertEqual(output.tabFrames[1], .zero, "The dragged tab must be lifted out of the flow.")
        for index in [0, 2, 3] {
            XCTAssertEqual(output.tabFrames[index].width, 80, accuracy: 0.001,
                "Tab \(index) must get an even 3-way split when the active tab is dragged out.")
        }
    }

    /// The separator visually left of a tab skips split-secondary slots
    /// (zero-width, separators parked off-screen): a tab right of a merged
    /// pair must resolve to the pair host's separator, otherwise the
    /// active/hover "hide my left separator" rules target the phantom.
    func testVisibleLeftSeparatorIndexSkipsSplitSecondarySlots() {
        // Plain neighbor: no collapsed slots in between.
        XCTAssertEqual(TabStripLayoutEngine.visibleLeftSeparatorIndex(of: 5, skippingCollapsed: []), 4)
        // Tab after a merged pair (3, 4): the visible separator is the host's (3).
        XCTAssertEqual(TabStripLayoutEngine.visibleLeftSeparatorIndex(of: 5, skippingCollapsed: [4]), 3)
        // Adjacent pairs (2, 3) and (4, 5): tab 6 resolves to host 4.
        XCTAssertEqual(TabStripLayoutEngine.visibleLeftSeparatorIndex(of: 6, skippingCollapsed: [3, 5]), 4)
        // Pair at the strip start (0, 1): tab 2 resolves to host 0.
        XCTAssertEqual(TabStripLayoutEngine.visibleLeftSeparatorIndex(of: 2, skippingCollapsed: [1]), 0)
        // Strip start has no left separator.
        XCTAssertEqual(TabStripLayoutEngine.visibleLeftSeparatorIndex(of: 0, skippingCollapsed: []), -1)
    }

    // MARK: - Quick-close width lock

    /// Quick-close lock: widths come verbatim from `lockedInactiveTabWidth`
    /// (inactive) and `activeTabWidth` (active), bypassing container-width
    /// allocation entirely — the container is far too narrow here, yet no
    /// tab shrinks or grows.
    func testLockedWidthLayoutKeepsWidthsRegardlessOfContainerWidth() {
        let input = TabStripLayoutInput(
            containerWidth: 100,
            tabCount: 3,
            activeTabIndex: 0,
            spacing: 2,
            idealTabWidth: 160,
            minTabWidth: 36,
            activeTabWidth: 100,
            tabHeight: 32,
            lockedInactiveTabWidth: 50
        )
        let output = TabStripLayoutEngine.layoutNormal(input: input)

        XCTAssertEqual(output.tabFrames[0].width, 100, "Active tab must keep the active minimum width while locked.")
        XCTAssertEqual(output.tabFrames[1].width, 50, "Inactive tab must keep the locked width verbatim.")
        XCTAssertEqual(output.tabFrames[2].width, 50, "Inactive tab must keep the locked width verbatim.")
    }

    /// Medium-pressure regime lock: tabs sit between `activeTabWidth` and
    /// the ideal width, so the active tab shares the uniform width rather
    /// than the protected minimum. Freezing must keep it at that shared
    /// width — clamping it down to `activeTabWidth` would shift every tab
    /// after it the moment the lock engages.
    func testLockedWidthLayoutKeepsActiveAtLockedWidthInMediumRegime() {
        let input = TabStripLayoutInput(
            containerWidth: 100,
            tabCount: 3,
            activeTabIndex: 0,
            spacing: 2,
            idealTabWidth: 160,
            minTabWidth: 36,
            activeTabWidth: 100,
            tabHeight: 32,
            lockedInactiveTabWidth: 120
        )
        let output = TabStripLayoutEngine.layoutNormal(input: input)

        XCTAssertEqual(output.tabFrames[0].width, 120,
            "Active tab must keep the shared pre-close width, not be clamped to the active minimum.")
        XCTAssertEqual(output.tabFrames[1].width, 120, "Inactive tab must keep the locked width verbatim.")
        XCTAssertEqual(output.tabFrames[2].width, 120, "Inactive tab must keep the locked width verbatim.")
    }

    /// Regression: the quick-close lock used to run a hand-rolled layout
    /// that ignored `excludedTabIndices`, so a split pair's collapsed
    /// second pane received a full-width slot during the locked period —
    /// a phantom gap next to the merged split cell until mouse-exit
    /// relayout. The locked path must collapse it to `.zero` like the
    /// normal path does.
    func testLockedWidthLayoutCollapsesSplitSecondaryPane() {
        // Split pair at (1, 2): index 2 is the collapsed second pane.
        let input = TabStripLayoutInput(
            containerWidth: 100,
            tabCount: 4,
            activeTabIndex: 0,
            spacing: 2,
            idealTabWidth: 160,
            minTabWidth: 36,
            activeTabWidth: 100,
            tabHeight: 32,
            excludedTabIndices: [2],
            lockedInactiveTabWidth: 50
        )
        let output = TabStripLayoutEngine.layoutNormal(input: input)

        XCTAssertEqual(output.tabFrames[2], .zero,
            "Collapsed split-secondary pane must occupy no slot while the layout is locked.")
        // GAP: G = 2 (leading spacing) + 1 (separator width) + 2 (trailing spacing) = 5 px.
        // startOffset = 6 (8 - 2).
        // Tab 0: 6 + 2 = 8 (active, width 100)
        // Tab 1: 8 + 100 + 5 = 113 (merged split host, width 50)
        // Tab 3: 113 + 50 + 5 = 168 — directly after the host, no phantom slot.
        XCTAssertEqual(output.tabFrames[0].origin.x, 8)
        XCTAssertEqual(output.tabFrames[1].origin.x, 113)
        XCTAssertEqual(output.tabFrames[3].origin.x, 168,
            "The tab after the split pair must sit directly after the merged cell, not one slot away.")
        XCTAssertEqual(output.tabFrames[3].width, 50)
    }

    /// Regression: the quick-close lock used to bypass the engine with a
    /// hand-rolled layout whose output carried no `chipFrames`, so
    /// `applyChipPlacements` treated every group as vanished and tore the
    /// chips down (and `groupGeometries` lost its underline anchor) for
    /// the whole locked period. The locked path must keep emitting chip
    /// placements and collapsed-member `.zero` frames like the normal path.
    func testLockedWidthLayoutKeepsGroupChipAndCollapsedMembers() {
        let token = "g1"
        let input = TabStripLayoutInput(
            containerWidth: 100,
            tabCount: 4,
            activeTabIndex: 0,
            spacing: 2,
            idealTabWidth: 160,
            minTabWidth: 36,
            activeTabWidth: 100,
            tabHeight: 32,
            groupRuns: [GroupRun(token: token, range: 1...2, isCollapsed: true)],
            chipFullWidths: [token: 120],
            lockedInactiveTabWidth: 50
        )
        let output = TabStripLayoutEngine.layoutNormal(input: input)

        XCTAssertNotNil(output.chipFrames[token],
            "Chip placement must survive the locked period so the chip view is not torn down.")
        XCTAssertEqual(output.tabFrames[1], .zero,
            "Collapsed group member must stay collapsed while the layout is locked.")
        XCTAssertEqual(output.tabFrames[2], .zero,
            "Collapsed group member must stay collapsed while the layout is locked.")
        XCTAssertEqual(output.tabFrames[0].width, 100, "Active tab keeps the active minimum width.")
        XCTAssertEqual(output.tabFrames[3].width, 50, "Ungrouped tab keeps the locked width.")
    }

    /// Grouped-path companion to the medium-regime test: the grouped
    /// layout path duplicates the width-allocation logic, so the freeze
    /// must hold there as well.
    func testLockedWidthLayoutKeepsActiveAtLockedWidthInMediumRegimeOnGroupedPath() {
        let token = "g1"
        let input = TabStripLayoutInput(
            containerWidth: 100,
            tabCount: 4,
            activeTabIndex: 0,
            spacing: 2,
            idealTabWidth: 160,
            minTabWidth: 36,
            activeTabWidth: 100,
            tabHeight: 32,
            groupRuns: [GroupRun(token: token, range: 1...2, isCollapsed: false)],
            chipFullWidths: [token: 120],
            lockedInactiveTabWidth: 120
        )
        let output = TabStripLayoutEngine.layoutNormal(input: input)

        XCTAssertEqual(output.tabFrames[0].width, 120,
            "Active tab must keep the shared pre-close width on the grouped path.")
        for index in 1...3 {
            XCTAssertEqual(output.tabFrames[index].width, 120, accuracy: 0.001,
                "Tab \(index) must keep the locked width verbatim on the grouped path.")
        }
    }

    /// Chip right-separator suppression must honor the SET exclusion form
    /// like the tab-side hiding does: an expanded chip whose first member
    /// is drag-excluded gets no right separator.
    func testChipRightSeparatorHiddenWhenNeighborExcludedViaSetForm() {
        let token = "g1"
        let input = TabStripLayoutInput(
            containerWidth: 1000,
            tabCount: 4,
            activeTabIndex: 0,
            spacing: 2,
            idealTabWidth: 160,
            minTabWidth: 36,
            activeTabWidth: 100,
            tabHeight: 32,
            excludedTabIndices: [1],
            groupRuns: [GroupRun(token: token, range: 1...2, isCollapsed: false)],
            chipFullWidths: [token: 120]
        )
        let output = TabStripLayoutEngine.layoutNormal(input: input)

        guard let placement = output.chipFrames[token] else {
            XCTFail("Expected chip placement for visible expanded group.")
            return
        }
        XCTAssertNil(placement.rightSeparatorX,
            "Set-form excluded neighbor must hide the chip's right separator, matching the single form.")
        XCTAssertNil(placement.rightSeparatorNeighborIndex,
            "Neighbor index must be nil when there is no separator.")
    }

    // MARK: - Narrow window: pinned overflow and the sticky active tab

    /// Six pinned tabs: each ends 30 pt after the one before, the zone is 182 pt.
    private let sixPinned = TabStripLayoutEngine.layoutPinned(tabCount: 6)
    private let slimButton: CGFloat = 16

    private func cut(budget: CGFloat) -> CGFloat? {
        TabStripLayoutEngine.pinnedOverflowCut(
            pinnedLayout: sixPinned,
            budget: budget,
            overflowButtonWidth: slimButton,
            firstCutLead: slimButton + TabStripMetrics.PinnedTab.spacing
        )
    }

    func testPinnedTabsAllStayWhileTheyFitWithRoomForTheOverflowButton() {
        XCTAssertEqual(sixPinned.totalContentWidth, 182, "precondition: six 28 pt tabs, 2 pt apart")
        XCTAssertNil(cut(budget: 200))
        XCTAssertNil(cut(budget: 1000))
    }

    func testTheFirstPinnedTabLeavesOneOverflowButtonEarly() {
        XCTAssertEqual(cut(budget: 199.5), 152, "five pins stay, the sixth makes way for the button")
        XCTAssertEqual(cut(budget: 182), 152)
        XCTAssertEqual(cut(budget: 170), 152)
    }

    func testPinnedTabsLeaveOneTabWidthApart() {
        // The first leaves below 200 pt, then one every 30 pt.
        var leaves: [CGFloat] = []
        var lastCut = cut(budget: 300)
        for budget in stride(from: CGFloat(300), through: 0, by: -0.5) {
            let current = cut(budget: budget)
            if current != lastCut { leaves.append(budget) }
            lastCut = current
        }
        XCTAssertEqual(leaves, [199.5, 169.5, 139.5, 109.5, 79.5, 49.5])
    }

    func testOnlyTheOverflowButtonStaysWhenNoPinnedTabFits() {
        XCTAssertEqual(cut(budget: 40), TabStripMetrics.PinnedTab.spacing)
        XCTAssertEqual(cut(budget: 0), TabStripMetrics.PinnedTab.spacing)
    }

    func testPinnedOverflowCutKeepsOnlyWholeTabs() {
        let ends = Set(sixPinned.tabFrames.map { $0.maxX + TabStripMetrics.PinnedTab.spacing })
        for budget in stride(from: CGFloat(0), through: 199, by: 1) {
            let value = cut(budget: budget)
            XCTAssertNotNil(value)
            if let value, value > TabStripMetrics.PinnedTab.spacing {
                XCTAssertTrue(ends.contains(value), "budget \(budget): cut \(value) falls inside a tab")
                XCTAssertLessThanOrEqual(value + slimButton + TabStripMetrics.PinnedTab.spacing, budget)
            }
        }
    }

    /// A scrolled active tab stops where the flow puts a tab at each end, so
    /// it doesn't move the moment it starts to stick.
    func testStickyActiveTabStopsWhereTheFlowPutsATab() {
        let input = TabStripLayoutInput(
            containerWidth: 0,
            tabCount: 1,
            activeTabIndex: 0,
            spacing: TabStripMetrics.Tab.spacing,
            idealTabWidth: TabStripMetrics.Tab.idealWidth,
            minTabWidth: TabStripMetrics.Tab.minWidth,
            activeTabWidth: 192,
            tabHeight: 32
        )
        let flow = TabStripLayoutEngine.layoutNormal(input: input)
        let tab = flow.tabFrames[0]
        let visibleWidth = flow.totalContentWidth

        XCTAssertEqual(TabStripLayoutEngine.stickyActiveTabX(-50, width: tab.width, visibleWidth: visibleWidth),
                       tab.minX, "sticks at the first tab's spot")
        XCTAssertEqual(TabStripLayoutEngine.stickyActiveTabX(500, width: tab.width, visibleWidth: visibleWidth),
                       tab.minX, "and before the new-tab button, as far from it as the flow puts it")
        XCTAssertEqual(TabStripLayoutEngine.stickyActiveTabX(tab.minX, width: tab.width, visibleWidth: visibleWidth),
                       tab.minX)

        let wider = visibleWidth + 300
        let stuckRight = TabStripLayoutEngine.stickyActiveTabX(1000, width: tab.width, visibleWidth: wider)
        let stickyButtonX = wider - TabStripMetrics.NewTabButton.size.width - TabStripMetrics.NewTabButton.insets.right
        XCTAssertEqual(stickyButtonX - (stuckRight + tab.width), flow.newTabButtonFrame.minX - tab.maxX,
                       "same gap to the pinned-right new-tab button as in the flow")
        XCTAssertEqual(TabStripLayoutEngine.stickyActiveTabX(120, width: tab.width, visibleWidth: wider), 120,
                       "a tab already in view stays put")
    }
}

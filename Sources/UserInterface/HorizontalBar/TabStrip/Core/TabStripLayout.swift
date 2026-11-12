// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

// MARK: - Layout Input

/// Input for the tab-strip layout engine.
struct TabStripLayoutInput {
    /// Total container width including the normal-tab area and new-tab button.
    let containerWidth: CGFloat
    /// Number of normal tabs.
    let tabCount: Int
    /// Index of the active tab.
    let activeTabIndex: Int?
    /// Spacing around each tab.
    let spacing: CGFloat
    /// Ideal width for each tab.
    let idealTabWidth: CGFloat
    /// Minimum width for inactive tabs.
    let minTabWidth: CGFloat
    /// Minimum width reserved for the active tab.
    let activeTabWidth: CGFloat
    /// Tab height.
    let tabHeight: CGFloat

    /// Index excluded from layout, typically the dragged tab.
    let excludedTabIndex: Int?
    /// Inclusive range of normal-tab indices excluded from layout in
    /// whole-group drag (chip + every member of the dragged group).
    /// Treated like a multi-tab variant of `excludedTabIndex`: each
    /// excluded index gets a `.zero` placeholder frame and contributes
    /// no width or spacing to the flow. The chip whose run start lies
    /// in this range is kept in `chipFrames` (so `applyChipPlacements`
    /// doesn't tear it down) but does not advance `currentX`; the
    /// caller leaves its visible frame at the drag-start value and
    /// drives cursor follow via a `layer.transform` translation.
    let excludedGroupRange: ClosedRange<Int>?
    /// General multi-index exclusion form: split drags carry the dragged
    /// tab and the other panes of its split so they all lift together;
    /// idle layout carries the collapsed split-pane indices (a merged
    /// split renders as a single slot, so every pane after the host
    /// collapses); single-tab drags may mirror `excludedTabIndex` here.
    /// The engine unions all three exclusion forms before counting, so
    /// overlap between them is safe.
    let excludedTabIndices: Set<Int>
    /// Split-merged host cells (the split's first pane; the other panes
    /// sit in `excludedTabIndices`), keyed by index with the split's pane
    /// count as value. Only `layoutPinned` widens these cells to one slot
    /// per pane; the normal-zone paths ignore this map on purpose — a
    /// merged cell occupies a single tab slot so its per-pane hit regions
    /// can't spill into the next cell.
    let wideTabPaneCounts: [Int: Int]
    /// Gap insertion index.
    let gapAtIndex: Int?
    /// Gap width.
    let gapWidth: CGFloat?

    /// Visible groups in this strip, in tab-strip order. Empty (default)
    /// → engine takes the byte-equivalent ungrouped fast path.
    let groupRuns: [GroupRun]

    /// Pre-measured chip widths keyed by token. Computed by `TabStrip`
    /// (via `TabGroupChipView.chipWidth(...)`) once per chip when
    /// title / color / member count change.
    let chipFullWidths: [String: CGFloat]

    /// When `gapAtIndex` lands at a group's leading edge (= the
    /// run's lowerBound), this flag picks the visual: `true` → gap
    /// opens before the chip (chip slides right alongside its first
    /// member); `false` (default) → gap opens after the chip (chip
    /// stays put, only the first member slides right). Set by
    /// `TabStripDragController` based on whether the cursor sits on
    /// the chip's left or right half.
    let gapBeforeRunStartChip: Bool

    /// Quick-close width lock: when set, inactive tabs keep exactly this
    /// width (and the active tab keeps `max(lockedInactiveTabWidth,
    /// activeTabWidth)` — its own pre-close width in both the compressed
    /// and medium regimes) instead of going through container-width
    /// allocation. `TabStrip` sets it after a close with the cursor still
    /// inside the strip, so the next tab's close button stays under the
    /// cursor. Everything else (split collapse, group runs, chips,
    /// exclusions) lays out as usual.
    let lockedInactiveTabWidth: CGFloat?

    init(containerWidth: CGFloat,
         tabCount: Int,
         activeTabIndex: Int?,
         spacing: CGFloat,
         idealTabWidth: CGFloat,
         minTabWidth: CGFloat,
         activeTabWidth: CGFloat,
         tabHeight: CGFloat,
         excludedTabIndex: Int? = nil,
         excludedGroupRange: ClosedRange<Int>? = nil,
         excludedTabIndices: Set<Int> = [],
         wideTabPaneCounts: [Int: Int] = [:],
         gapAtIndex: Int? = nil,
         gapWidth: CGFloat? = nil,
         groupRuns: [GroupRun] = [],
         chipFullWidths: [String: CGFloat] = [:],
         gapBeforeRunStartChip: Bool = false,
         lockedInactiveTabWidth: CGFloat? = nil) {
        self.containerWidth = containerWidth
        self.tabCount = tabCount
        self.activeTabIndex = activeTabIndex
        self.spacing = spacing
        self.idealTabWidth = idealTabWidth
        self.minTabWidth = minTabWidth
        self.activeTabWidth = activeTabWidth
        self.tabHeight = tabHeight
        self.excludedTabIndex = excludedTabIndex
        self.excludedGroupRange = excludedGroupRange
        self.excludedTabIndices = excludedTabIndices
        self.wideTabPaneCounts = wideTabPaneCounts
        self.gapAtIndex = gapAtIndex
        self.gapWidth = gapWidth
        self.groupRuns = groupRuns
        self.chipFullWidths = chipFullWidths
        self.gapBeforeRunStartChip = gapBeforeRunStartChip
        self.lockedInactiveTabWidth = lockedInactiveTabWidth
    }
}

// MARK: - Layout Output

/// Output produced by the tab-strip layout engine.
///
/// - Extension Point [Animation/Drag]: This could be extended to:
///   ```
///   struct TabFrame {
///       let id: String
///       let frame: CGRect
///   }
///   let tabFrames: [TabFrame]
///   ```
///   That would let `applyLayout` avoid matching views through the external tab
///   array and would make virtual drag layouts easier to compute.
struct TabStripLayoutOutput {
    /// Frame for each tab.
    let tabFrames: [CGRect]
    /// X positions for separator lines.
    let separatorXPositions: [CGFloat]
    /// Frame for the new-tab button.
    let newTabButtonFrame: CGRect
    /// Total logical content width including tabs, spacing, button, and trailing inset.
    let totalContentWidth: CGFloat

    /// Frame for each visible group's chip. Empty when `groupRuns`
    /// was empty in input.
    let chipFrames: [String: ChipPlacement]

    init(tabFrames: [CGRect],
         separatorXPositions: [CGFloat],
         newTabButtonFrame: CGRect,
         totalContentWidth: CGFloat,
         chipFrames: [String: ChipPlacement] = [:]) {
        self.tabFrames = tabFrames
        self.separatorXPositions = separatorXPositions
        self.newTabButtonFrame = newTabButtonFrame
        self.totalContentWidth = totalContentWidth
        self.chipFrames = chipFrames
    }
}

enum TabStripLayoutEngine {
    static func layoutPinned(
        tabCount: Int,
        excludedTabIndices: Set<Int> = [],
        wideTabPaneCounts: [Int: Int] = [:],
        gapAtIndex: Int? = nil
    ) -> TabStripLayoutOutput {
        var frames: [CGRect] = []

        let spacing = TabStripMetrics.PinnedTab.spacing
        let itemWidth = TabStripMetrics.PinnedTab.width
        let itemHeight = TabStripMetrics.PinnedTab.height // 28
        // Center pinned tabs vertically in the 32pt strip.
        let containerHeight = TabStripMetrics.Strip.tabHeight // 32
        let y = (containerHeight - itemHeight) / 2.0

        var currentX: CGFloat = 0

        currentX += spacing

        for i in 0..<tabCount {
            if let gapIndex = gapAtIndex {
                if i == gapIndex {
                    currentX += itemWidth
                    currentX += spacing
                }
            }
            if excludedTabIndices.contains(i) {
                // Keep indices aligned by inserting a placeholder frame.
                frames.append(.zero)
                continue
            }

            // Wide cells (pinned splits) span one slot per pane plus the
            // spacing that would have sat between those slots, so the cell
            // visually "absorbs" its collapsed panes' slots.
            let width = wideTabPaneCounts[i].map {
                TabStripMetrics.PinnedTab.mergedWidth(paneCount: $0)
            } ?? itemWidth
            let frame = CGRect(x: currentX, y: y, width: width, height: itemHeight)
            frames.append(frame)
            currentX += width + spacing
        }

        if let gapIndex = gapAtIndex {
            if gapIndex >= tabCount {
                currentX += (itemWidth + spacing)
            }
        }

        return TabStripLayoutOutput(
            tabFrames: frames,
            separatorXPositions: [],
            newTabButtonFrame: .zero,
            totalContentWidth: currentX
        )
    }

    static func layoutNormal(input: TabStripLayoutInput) -> TabStripLayoutOutput {
        // Fast path: no groups in this window — execute the original
        // ungrouped logic byte-equivalent.
        if input.groupRuns.isEmpty {
            return layoutNormalUngrouped(input: input)
        }
        return layoutNormalWithGroups(input: input)
    }

    private static func layoutNormalUngrouped(input: TabStripLayoutInput) -> TabStripLayoutOutput {
        // Start offset keeps the leading inverse corner visible.
        let startOffsetX = calculateStartXOffset()
        // Fixed spacing and separator overhead per tab.
        let perTabOverhead: CGFloat = input.spacing * 2 + 1.0 // 2px * 2 + 1px
        // New-tab button width plus its trailing inset.
        let btnSize = TabStripMetrics.NewTabButton.size
        let buttonOverhead = btnSize.width + TabStripMetrics.NewTabButton.insets.right
        // Excluding the dragged tab(s) changes the available width
        // calculation. excludedTabIndex (single-tab drag),
        // excludedGroupRange (whole-group drag), and excludedTabIndices
        // (split drag) can overlap — `TabStrip.layout()` passes the
        // dragged index through both the single and the set form — so
        // union them before counting. Subtracting each form separately
        // double-counts the dragged tab and hands its phantom slot's
        // width to every remaining tab (visible widening during drag).
        var excludedIndices = input.excludedTabIndices
        if let excluded = input.excludedTabIndex {
            excludedIndices.insert(excluded)
        }
        if let groupRange = input.excludedGroupRange {
            excludedIndices.formUnion(groupRange)
        }
        let effectiveTabCount = max(0, input.tabCount - excludedIndices.count)
        // Total width consumed before tab widths are assigned.
        var totalFixedOverhead = startOffsetX
                               + CGFloat(effectiveTabCount) * perTabOverhead
                               + input.spacing  // Spacing between the last tab and the button.
                               + buttonOverhead
        if let gapWidth = input.gapWidth, input.gapAtIndex != nil {
            totalFixedOverhead += gapWidth
        }

        // Remaining width is distributed across visible tabs.
        let availableForTabs = input.containerWidth - totalFixedOverhead

        // Allocate widths.
        var activeW: CGFloat = input.idealTabWidth
        var inactiveW: CGFloat = input.idealTabWidth
        if let lockedW = input.lockedInactiveTabWidth {
            // Quick-close lock: keep the pre-close widths verbatim so the
            // remaining tabs don't move under the cursor; skip clamping so
            // the frozen width survives unchanged. max() reproduces the
            // active tab's own pre-close width in both regimes: below the
            // protected minimum it sat at `activeTabWidth`, in the medium
            // regime it shared the uniform (= locked) width.
            activeW = max(lockedW, input.activeTabWidth)
            inactiveW = lockedW
        } else if effectiveTabCount > 0 {
            let baseWidth = max(0, availableForTabs / CGFloat(effectiveTabCount))
            if baseWidth >= input.idealTabWidth {
                // Plenty of space: use ideal widths.
                activeW = input.idealTabWidth
                inactiveW = input.idealTabWidth
            } else if baseWidth >= input.activeTabWidth {
                // Medium pressure: shrink all tabs evenly.
                activeW = baseWidth
                inactiveW = baseWidth
            } else {
                // Tight space: protect the active tab — unless it is lifted
                // out of the flow in any exclusion form (single, set, or
                // group range): reserving width for an excluded tab shrinks
                // every remaining tab and leaves dead slack at the strip end.
                let isActiveExcluded = (input.activeTabIndex.map { excludedIndices.contains($0) } ?? false)
                if input.activeTabIndex != nil && !isActiveExcluded {
                    activeW = input.activeTabWidth
                    let remainingForInactive = availableForTabs - activeW
                    let inactiveCount = effectiveTabCount - 1
                    if inactiveCount > 0 {
                        inactiveW = remainingForInactive / CGFloat(inactiveCount)
                    } else {
                        inactiveW = 0
                    }
                } else {
                    // No active tab, or it is being dragged out, so use the shared width.
                    activeW = baseWidth
                    inactiveW = baseWidth
                }
            }
            if inactiveW < input.minTabWidth { inactiveW = input.minTabWidth }
            if activeW < input.minTabWidth { activeW = input.minTabWidth }
        }

        var tabFrames: [CGRect] = []
        var separatorXs: [CGFloat] = []

        var currentX = startOffsetX

        for i in 0..<input.tabCount {
            if let gapIndex = input.gapAtIndex, let gapW = input.gapWidth {
                if i == gapIndex {
                    currentX += gapW
                }
            }
            // Drag/split exclusions in any form (single, set, or group
            // range): zero placeholder, no width. Uses the same union as
            // the width math above so counting and placement can't
            // disagree about which slots exist.
            if excludedIndices.contains(i) {
                tabFrames.append(.zero)
                separatorXs.append(-1000)
                continue
            }
            currentX += input.spacing
            let isActive = (input.activeTabIndex != nil && i == input.activeTabIndex!)
            let width = isActive ? activeW : inactiveW
            // Split-merged cells occupy a single normal-tab slot (no
            // widening). Fitting every pane inside the same width as one
            // tab keeps the per-pane hit regions from spilling into the
            // next cell.
            let frame = CGRect(
                x: currentX,
                y: TabStripMetrics.Strip.bottomSpacing, // 4
                width: width,
                height: input.tabHeight
            )
            tabFrames.append(frame)

            // Advance to the end of the tab.
            currentX += width

            // Separator sits one spacing unit after the tab.
            let separatorX = currentX + (input.spacing)
            separatorXs.append(separatorX)
            // Skip spacing plus separator width before the next tab.
            currentX += input.spacing + 1.0
        }

        if let gapIndex = input.gapAtIndex, let gapW = input.gapWidth  {
            if gapIndex >= input.tabCount {
                currentX += gapW
            }
        }

        currentX += input.spacing // 4 px spacing before the button.

        let newTabFrame = CGRect(
            x: currentX,
            y: TabStripMetrics.Strip.bottomSpacing,
            width: btnSize.width,
            height: btnSize.height
        )

        currentX += btnSize.width
        currentX += TabStripMetrics.NewTabButton.insets.right

        let totalWidth = currentX

        return TabStripLayoutOutput(
            tabFrames: tabFrames,
            separatorXPositions: separatorXs,
            newTabButtonFrame: newTabFrame,
            totalContentWidth: totalWidth
        )
    }

    /// Group-aware variant. Reserves chip width up front (from the
    /// pre-measured `input.chipFullWidths`), then runs the same
    /// three-tier width allocation (Spacious / Medium / Tight) and
    /// active-tab protection as `layoutNormalUngrouped` against a
    /// smaller `availableForTabs`.
    private static func layoutNormalWithGroups(input: TabStripLayoutInput) -> TabStripLayoutOutput {
        let startOffsetX = calculateStartXOffset()
        let perTabOverhead: CGFloat = input.spacing * 2 + 1.0
        let btnSize = TabStripMetrics.NewTabButton.size
        let buttonOverhead = btnSize.width + TabStripMetrics.NewTabButton.insets.right

        // ── Effective tab count: exclude collapsed-group members and
        // (optionally) the dragged tab.
        let collapsedMemberSet: Set<Int> = input.groupRuns
            .filter { $0.isCollapsed }
            .reduce(into: Set<Int>()) { acc, run in
                for i in run.range { acc.insert(i) }
            }
        // The three drag-exclusion forms can overlap (`TabStrip.layout()`
        // passes the dragged index through both the single and the set
        // form), so union them before counting — mirrors
        // `layoutNormalUngrouped`. The set also carries the collapsed
        // split panes (from `normalSplitCollapseInfo`) that collapse to
        // zero-width so the merged cell renders as a single slot.
        var dragExcludedIndices = input.excludedTabIndices
        if let excluded = input.excludedTabIndex {
            dragExcludedIndices.insert(excluded)
        }
        if let groupRange = input.excludedGroupRange {
            dragExcludedIndices.formUnion(groupRange)
        }
        // Members already counted as collapsed don't shrink width
        // again (collapsed members are already zero-width).
        let netExcluded = dragExcludedIndices.subtracting(collapsedMemberSet).count
        let effectiveTabCount = max(0, input.tabCount - collapsedMemberSet.count - netExcluded)

        // ── Per-chip slot width = chip width + spacing-after-chip.
        // Visible groups are all groups (collapsed and expanded both have
        // a chip on the strip).
        let visibleTokens = input.groupRuns.map { $0.token }

        // Fallback for cache misses: `chipFullWidths` is populated by
        // `TabStrip.refreshChipWidth(...)` in response to group state
        // changes, so a visible run may briefly appear with no cached
        // measurement (newly-created group, cross-window join, the
        // frame between `removeValue(forKey:)` and the next configure).
        // Reserve `maxFullWidth` for those tokens so (a) the chip frame
        // always has a hit-testable area and (b) the post-measurement
        // jump only shrinks the chip (tabs gain width, never lose it).
        //
        // Per-chip overhead = spacing (leading) + chipWidth + spacing
        // (trailing) + 1 (right separator), mirroring the per-tab
        // pattern. The 1pt over-allocation for end-of-strip chips is
        // a deliberate simplification (position isn't known here).
        let chipsOverhead: CGFloat = visibleTokens.reduce(0.0) { acc, token in
            acc + (input.chipFullWidths[token] ?? TabGroupChipView.maxFullWidth) + input.spacing * 2 + 1.0
        }

        var fixedOverheadBase = startOffsetX
                              + CGFloat(effectiveTabCount) * perTabOverhead
                              + input.spacing
                              + buttonOverhead
        if let gapWidth = input.gapWidth, input.gapAtIndex != nil {
            fixedOverheadBase += gapWidth
        }

        let availableForTabs = input.containerWidth - fixedOverheadBase - chipsOverhead
        let baseWidth: CGFloat = effectiveTabCount > 0
            ? max(0, availableForTabs / CGFloat(effectiveTabCount))
            : 0

        // ── Width allocation — byte-identical logic to ungrouped path.
        var activeW: CGFloat = input.idealTabWidth
        var inactiveW: CGFloat = input.idealTabWidth
        if let lockedW = input.lockedInactiveTabWidth {
            // Quick-close lock: see `layoutNormalUngrouped`.
            activeW = max(lockedW, input.activeTabWidth)
            inactiveW = lockedW
        } else if effectiveTabCount > 0 {
            if baseWidth >= input.idealTabWidth {
                activeW = input.idealTabWidth
                inactiveW = input.idealTabWidth
            } else if baseWidth >= input.activeTabWidth {
                activeW = baseWidth
                inactiveW = baseWidth
            } else {
                // Mirror `layoutNormalUngrouped`: an active tab lifted out
                // in ANY exclusion form (single, set, or whole-group range)
                // earns no width reservation.
                if let activeIdx = input.activeTabIndex,
                   !dragExcludedIndices.contains(activeIdx),
                   !collapsedMemberSet.contains(activeIdx) {
                    activeW = input.activeTabWidth
                    let remainingForInactive = availableForTabs - activeW
                    let inactiveCount = effectiveTabCount - 1
                    inactiveW = inactiveCount > 0 ? remainingForInactive / CGFloat(inactiveCount) : 0
                } else {
                    activeW = baseWidth
                    inactiveW = baseWidth
                }
            }
            if inactiveW < input.minTabWidth { inactiveW = input.minTabWidth }
            if activeW < input.minTabWidth { activeW = input.minTabWidth }
        }

        // ── Build a fast lookup for "which run starts at this index".
        let runStarts: [Int: GroupRun] = Dictionary(
            uniqueKeysWithValues: input.groupRuns.map { ($0.range.lowerBound, $0) }
        )

        var tabFrames: [CGRect] = []
        var separatorXs: [CGFloat] = []
        var chipFrames: [String: ChipPlacement] = [:]

        var currentX = startOffsetX

        for i in 0..<input.tabCount {
            let isGapHere = (input.gapAtIndex == i)
            let isRunStart = (runStarts[i] != nil)
            let gapBeforeChip = isGapHere && isRunStart && input.gapBeforeRunStartChip

            // When the drag's gap target is the group's leading edge
            // AND the cursor is on the chip's left half, insert the
            // gap BEFORE the chip so the chip slides right along
            // with its first member.
            if gapBeforeChip, let gapW = input.gapWidth {
                currentX += gapW
            }

            if let run = runStarts[i] {
                // Whole-group drag: the chip of the dragged group is kept
                // in chipFrames so applyChipPlacements doesn't tear it
                // down, but consumes no width — the chip view's frame
                // stays at the drag-start value and `layer.transform`
                // handles cursor follow.
                let runIsExcluded: Bool = {
                    guard let groupRange = input.excludedGroupRange else { return false }
                    return groupRange.contains(run.range.lowerBound)
                }()

                // Leading spacing for the chip — mirrors the
                // `currentX += spacing` that every tab placement does
                // below. Without it, chip sits flush against the prior
                // tab's right separator (0pt gap) instead of the
                // standard 2pt, making chip's hover bg and color dot
                // visually 2pt closer to the separator than the
                // equivalent tab/favicon geometry.
                if !runIsExcluded {
                    currentX += input.spacing
                }

                // Same fallback semantics as chipsOverhead above.
                let chipWidth: CGFloat = input.chipFullWidths[run.token] ?? TabGroupChipView.maxFullWidth
                // Chip Y centers within the tab cell (not the full strip).
                let chipY = TabStripMetrics.Strip.bottomSpacing
                          + (TabStripMetrics.Strip.tabHeight - TabGroupChipView.height) / 2.0
                let chipFrame = CGRect(x: currentX, y: chipY,
                                        width: chipWidth, height: TabGroupChipView.height)

                // Right-neighbor index for the chip's right separator:
                // collapsed group → first tab after the run; expanded →
                // run's first member. Nil when no neighbor exists or
                // the neighbor is drag-excluded in any form (matches
                // the tab-side -1000 hiding, which the per-form
                // placeholder branches below implement).
                let rightNeighborIdx: Int? = {
                    let candidate = run.isCollapsed
                        ? run.range.upperBound + 1
                        : run.range.lowerBound
                    guard candidate < input.tabCount else { return nil }
                    if dragExcludedIndices.contains(candidate) { return nil }
                    return candidate
                }()

                var rightSepX: CGFloat? = nil
                if !runIsExcluded {
                    currentX += chipWidth + input.spacing
                    if rightNeighborIdx != nil {
                        rightSepX = currentX
                        currentX += 1.0  // separator width
                    }
                }

                chipFrames[run.token] = ChipPlacement(
                    frame: chipFrame,
                    rightSeparatorX: rightSepX,
                    rightSeparatorNeighborIndex: rightSepX == nil ? nil : rightNeighborIdx
                )
            }

            // Default gap placement: AFTER chip (when gap is at
            // runStart) so chip stays put and only the first member
            // slides right, leaving a slot between chip and first
            // member that the dragged tab can settle into. Also the
            // ordinary case for gaps not at any runStart.
            if isGapHere, !gapBeforeChip, let gapW = input.gapWidth {
                currentX += gapW
            }

            // Collapsed-group member: skip frame allocation.
            if collapsedMemberSet.contains(i) {
                tabFrames.append(.zero)
                separatorXs.append(-1000)
                continue
            }

            // Drag/split exclusions in any form (single, set — which
            // carries the collapsed split panes from
            // `normalSplitCollapseInfo`, folded under their merged
            // cell — or whole-group range): zero placeholder, no width.
            // Uses the same union as the width math above so counting
            // and placement can't disagree about which slots exist.
            if dragExcludedIndices.contains(i) {
                tabFrames.append(.zero)
                separatorXs.append(-1000)
                continue
            }

            currentX += input.spacing
            let isActive = (input.activeTabIndex == i)
            let width = isActive ? activeW : inactiveW
            // Split-merged cells occupy a single normal-tab slot (no
            // widening). Fitting every pane inside the same width as one
            // tab keeps the per-pane hit regions from spilling into the
            // next cell.
            let frame = CGRect(x: currentX, y: TabStripMetrics.Strip.bottomSpacing,
                                width: width, height: input.tabHeight)
            tabFrames.append(frame)

            currentX += width
            let separatorX = currentX + input.spacing
            separatorXs.append(separatorX)
            currentX += input.spacing + 1.0
        }

        if let gapIndex = input.gapAtIndex, let gapW = input.gapWidth,
           gapIndex >= input.tabCount {
            currentX += gapW
        }
        currentX += input.spacing

        let newTabFrame = CGRect(x: currentX, y: TabStripMetrics.Strip.bottomSpacing,
                                  width: btnSize.width, height: btnSize.height)
        currentX += btnSize.width + TabStripMetrics.NewTabButton.insets.right
        let totalWidth = currentX

        return TabStripLayoutOutput(
            tabFrames: tabFrames,
            separatorXPositions: separatorXs,
            newTabButtonFrame: newTabFrame,
            totalContentWidth: totalWidth,
            chipFrames: chipFrames
        )
    }

    private static func calculateStartXOffset() -> CGFloat {
        // Preserve enough leading room so the inverse corner does not get clipped.
        return max(0, TabStripMetrics.Tab.inverseCornerRadius - TabStripMetrics.Tab.spacing)
    }

    /// Index of the separator that sits visually to the LEFT of
    /// `tabIndex`'s cell: normally `tabIndex - 1`, but collapsed split-pane
    /// slots are zero-width with off-screen separators, so walk past
    /// them to the previous real slot (the split's host, whose separator
    /// is the merged cell's right edge). Returns -1 at the strip start,
    /// matching the no-separator case of the plain `tabIndex - 1` form.
    static func visibleLeftSeparatorIndex(of tabIndex: Int, skippingCollapsed collapsed: Set<Int>) -> Int {
        var index = tabIndex - 1
        while index >= 0, collapsed.contains(index) { index -= 1 }
        return index
    }
}

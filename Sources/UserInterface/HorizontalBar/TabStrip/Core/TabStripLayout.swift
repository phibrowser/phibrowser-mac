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
    /// Gap insertion index.
    let gapAtIndex: Int?
    /// Gap width.
    let gapWidth: CGFloat?
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
}

enum TabStripLayoutEngine {
    static func layoutPinned(
        tabCount: Int,
        excludedTabIndex: Int? = nil,
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
            if let excluded = excludedTabIndex, i == excluded {
                // Keep indices aligned by inserting a placeholder frame.
                frames.append(.zero)
                continue
            }

            let frame = CGRect(x: currentX, y: y, width: itemWidth, height: itemHeight)
            frames.append(frame)
            currentX += itemWidth + spacing
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
        // Start offset keeps the leading inverse corner visible.
        let startOffsetX = calculateStartXOffset()
        // Fixed spacing and separator overhead per tab.
        let perTabOverhead: CGFloat = input.spacing * 2 + 1.0 // 2px * 2 + 1px
        // New-tab button width plus its trailing inset.
        let btnSize = TabStripMetrics.NewTabButton.size
        let buttonOverhead = btnSize.width + TabStripMetrics.NewTabButton.insets.right
        // Excluding the dragged tab changes the available width calculation.
        var effectiveTabCount = input.tabCount
        if input.excludedTabIndex != nil {
            effectiveTabCount -= 1
        }
        effectiveTabCount = max(0, effectiveTabCount)
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
        if effectiveTabCount > 0 {
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
                // Tight space: protect the active tab.
                let isActiveExcluded = (input.excludedTabIndex != nil && input.excludedTabIndex == input.activeTabIndex)
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
            if let excluded = input.excludedTabIndex, i == excluded {
                // Keep indices aligned by inserting a placeholder frame.
                tabFrames.append(.zero)
                separatorXs.append(-1000)
                continue
            }
            currentX += input.spacing
            let isActive = (input.activeTabIndex != nil && i == input.activeTabIndex!)
            let width = isActive ? activeW : inactiveW
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
    private static func calculateStartXOffset() -> CGFloat {
        // Preserve enough leading room so the inverse corner does not get clipped.
        return max(0, TabStripMetrics.Tab.inverseCornerRadius - TabStripMetrics.Tab.spacing)
    }
}

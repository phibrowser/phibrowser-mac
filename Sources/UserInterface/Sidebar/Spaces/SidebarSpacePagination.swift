// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

enum SidebarSpaceStripPosition: String {
    case top
    case bottom
}

/// Layout of the bottom Space switcher. Every Space keeps a slot sized to share
/// the row, within each mode's bounds. The row shows icons once every slot
/// fits the icon minimum; below that it shows dots, and one slot stays wide
/// enough for the icon of the Space under the pointer, or the active one at
/// rest. The dot maximum meets the icon minimum, so a switch keeps the row's
/// width.
enum SidebarSpacePagination {
    enum Mode: Equatable {
        case dots
        case icons
    }

    static let edgeInset: CGFloat = 10
    static let minDotSlotWidth: CGFloat = 14
    static let maxDotSlotWidth: CGFloat = minIconSlotWidth
    static let expandedSlotWidth: CGFloat = 22
    static let minIconSlotWidth: CGFloat = 24
    static let maxIconSlotWidth: CGFloat = 32

    static func viewportWidth(for rowWidth: CGFloat) -> CGFloat {
        guard rowWidth.isFinite else { return 0 }
        return max(0, rowWidth - 2 * edgeInset)
    }

    static func mode(count: Int, rowWidth: CGFloat) -> Mode {
        CGFloat(count) * minIconSlotWidth <= viewportWidth(for: rowWidth) ? .icons : .dots
    }

    /// Whole points, so icons stay on the pixel grid.
    static func iconSlotWidth(count: Int, rowWidth: CGFloat) -> CGFloat {
        guard count > 0 else { return maxIconSlotWidth }
        return min(maxIconSlotWidth, floor(viewportWidth(for: rowWidth) / CGFloat(count)))
    }

    /// Hover and selection backgrounds keep a 1pt gap inside their slot.
    static func backgroundSize(forSlotWidth slotWidth: CGFloat) -> CGSize {
        let width = min(30, slotWidth - 2)
        return CGSize(width: width, height: min(26, width))
    }

    /// The Space whose icon a dot row shows: the hovered one, else the active one.
    static func expandedIndex(hovered: Int?, active: Int?) -> Int? {
        hovered ?? active
    }

    static func slotWidths(count: Int, rowWidth: CGFloat, expandedIndex: Int?) -> [CGFloat] {
        guard count > 0 else { return [] }
        switch mode(count: count, rowWidth: rowWidth) {
        case .icons:
            return Array(repeating: iconSlotWidth(count: count, rowWidth: rowWidth), count: count)
        case .dots:
            let viewport = viewportWidth(for: rowWidth)
            let shared = viewport / CGFloat(count)
            guard let expandedIndex, shared < expandedSlotWidth else {
                return Array(repeating: min(max(shared, minDotSlotWidth), maxDotSlotWidth), count: count)
            }
            let remaining = count > 1 ? (viewport - expandedSlotWidth) / CGFloat(count - 1) : 0
            let dotWidth = max(remaining, minDotSlotWidth)
            return (0..<count).map { $0 == expandedIndex ? expandedSlotWidth : dotWidth }
        }
    }

    /// Slot origins inside the viewport: centered when the row fits, else
    /// shifted left by `scrollOffset`.
    static func slotOrigins(widths: [CGFloat], viewportWidth: CGFloat, scrollOffset: CGFloat) -> [CGFloat] {
        let contentWidth = widths.reduce(0, +)
        var x = contentWidth <= viewportWidth ? (viewportWidth - contentWidth) / 2 : -scrollOffset
        return widths.map { width in
            defer { x += width }
            return x
        }
    }

    static func maxScrollOffset(widths: [CGFloat], viewportWidth: CGFloat) -> CGFloat {
        max(0, widths.reduce(0, +) - viewportWidth)
    }

    /// The smallest move of `current` that brings slot `index` fully into view.
    static func scrollOffset(revealing index: Int, widths: [CGFloat], viewportWidth: CGFloat,
                             current: CGFloat) -> CGFloat {
        let maxOffset = maxScrollOffset(widths: widths, viewportWidth: viewportWidth)
        guard widths.indices.contains(index) else { return min(max(0, current), maxOffset) }
        let minX = widths.prefix(index).reduce(0, +)
        let maxX = minX + widths[index]
        var offset = current
        if minX < offset {
            offset = minX
        } else if maxX > offset + viewportWidth {
            offset = maxX - viewportWidth
        }
        return min(max(0, offset), maxOffset)
    }
}

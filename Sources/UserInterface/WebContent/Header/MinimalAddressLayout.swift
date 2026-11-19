// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import CoreGraphics

/// Places the Minimal address on the window's center (in a split, on the
/// header's own), within the space the toolbar's side zones leave free.
enum MinimalAddressLayout {
    /// The centered unit: the address leading section's buttons, the address
    /// text, then the trailing section's buttons, in the slot's coordinates.
    struct Unit: Equatable {
        var minX: CGFloat
        var leadingWidth: CGFloat
        var textWidth: CGFloat
        var trailingWidth: CGFloat

        var textMinX: CGFloat { minX + leadingWidth }
        var trailingMinX: CGFloat { textMinX + textWidth }
        var width: CGFloat { leadingWidth + textWidth + trailingWidth }
    }

    /// Centers the whole unit on `centerX`, slides it toward the free side
    /// when one side is short of room, and then truncates the text only: the
    /// buttons keep their widths. Buttons wider than the free space get a
    /// text width of zero and run past `freeMaxX`.
    ///
    /// The customize-only widths are the parts of each section drawn only
    /// while customizing (`ToolbarCustomizeOnlyItemsKey`). The unit is placed
    /// as if they were absent and they extend outward, so the text stays where
    /// it is when customizing starts.
    ///
    /// The minimum widths are an empty section's reserve while customizing
    /// (`ToolbarCustomizationLayout.addressSectionReserve`): a narrower
    /// section is widened to it, and the added width counts as customize-only,
    /// so it too extends outward and the text stays put.
    static func unit(
        leadingWidth drawnLeadingWidth: CGFloat,
        textWidth: CGFloat,
        trailingWidth drawnTrailingWidth: CGFloat,
        centerX: CGFloat,
        freeMinX: CGFloat,
        freeMaxX: CGFloat,
        leadingCustomizeOnlyWidth: CGFloat = 0,
        trailingCustomizeOnlyWidth: CGFloat = 0,
        leadingMinimumWidth: CGFloat = 0,
        trailingMinimumWidth: CGFloat = 0
    ) -> Unit {
        let leadingWidth = max(drawnLeadingWidth, leadingMinimumWidth)
        let trailingWidth = max(drawnTrailingWidth, trailingMinimumWidth)
        let leadingExtra = min(max(leadingCustomizeOnlyWidth, 0) + leadingWidth - drawnLeadingWidth, leadingWidth)
        let trailingExtra = min(max(trailingCustomizeOnlyWidth, 0) + trailingWidth - drawnTrailingWidth, trailingWidth)
        let buttonsWidth = (leadingWidth - leadingExtra) + (trailingWidth - trailingExtra)
        let placed = frame(
            textWidth: buttonsWidth + textWidth,
            centerX: centerX,
            freeMinX: freeMinX,
            freeMaxX: freeMaxX
        )
        return Unit(
            minX: placed.minX - leadingExtra,
            leadingWidth: leadingWidth,
            textWidth: max(0, placed.width - buttonsWidth),
            trailingWidth: trailingWidth
        )
    }

    /// How much of a section's drawn width its customize-only items take:
    /// each one's width plus the spacing it adds. A section of only such
    /// items comes to one spacing more than its width, which `unit` clamps.
    static func customizeOnlyWidth(itemWidths: [CGFloat], spacing: CGFloat) -> CGFloat {
        itemWidths.reduce(0) { $0 + $1 + spacing }
    }

    /// Centers a span `textWidth` wide on `centerX`, slid toward the free
    /// side when one side is short of room, and cut to the free width.
    static func frame(
        textWidth: CGFloat,
        centerX: CGFloat,
        freeMinX: CGFloat,
        freeMaxX: CGFloat
    ) -> (minX: CGFloat, width: CGFloat) {
        let freeWidth = max(0, freeMaxX - freeMinX)
        guard textWidth <= freeWidth else { return (freeMinX, freeWidth) }
        let minX = min(max(centerX - textWidth / 2, freeMinX), freeMaxX - textWidth)
        return (minX, textWidth)
    }

    /// The window's horizontal midpoint in the header's own coordinates.
    static func windowCenterX(windowWidth: CGFloat, headerMinXInWindow: CGFloat) -> CGFloat {
        windowWidth / 2 - headerMinXInWindow
    }

    /// Where the address centers, in the header's own coordinates: on the
    /// window, or while the header shows a split, on the header itself, which
    /// spans only the split's panes.
    static func centerX(
        windowWidth: CGFloat,
        headerMinXInWindow: CGFloat,
        headerWidth: CGFloat,
        isSplitViewVisible: Bool
    ) -> CGFloat {
        if isSplitViewVisible { return headerWidth / 2 }
        return windowCenterX(windowWidth: windowWidth, headerMinXInWindow: headerMinXInWindow)
    }
}

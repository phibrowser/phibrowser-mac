// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

enum TabStripMetrics {
    // Global constants for the tab strip container.
    enum Strip {
        static let tabHeight: CGFloat = 32
        static let bottomSpacing: CGFloat = 4
        static let height: CGFloat = tabHeight + bottomSpacing
        static let insets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        static let backgroundColor = NSColor.clear

        static let pinnedContainerCornerRadius: CGFloat = 8

        static let gapBetweenPinnedAndNormal: CGFloat = 4
    }

    // Dimensions and spacing for regular tabs.
    enum Tab {
        static let spacing: CGFloat = 2
        static let idealWidth: CGFloat = 180
        static let minWidth: CGFloat = 36
        static let activeMinWidth: CGFloat = 100
        static let cornerRadius: CGFloat = 8
        static let inverseCornerRadius: CGFloat = cornerRadius
    }

    // Dimensions and spacing for pinned tabs.
    enum PinnedTab {
        static let height: CGFloat = 28
        static let width: CGFloat = 28
        static let spacing: CGFloat = 2
    }

    // Layout constants for tab content.
    enum Content {
        static let faviconSize = CGSize(width: 16, height: 16)
        static let faviconCornerRadius: CGFloat = 4
        static let faviconLeading: CGFloat = 6

        static let titleFontSize: CGFloat = 13
        static let titleFont = NSFont.systemFont(ofSize: titleFontSize, weight: .regular)
        static let titleHeight: CGFloat = ceil(titleFont.ascender - titleFont.descender + titleFont.leading)
        static let titleToFavicon: CGFloat = 8
        static let titleTrailing: CGFloat = 10
        static let titleToCloseButton: CGFloat = 6
        static let titleColor = NSColor(calibratedWhite: 0, alpha: 0.80)

        static let closeButtonSize = CGSize(width: 24, height: 24)
        static let closeButtonCornerRadius: CGFloat = 4
        static let closeButtonTrailing: CGFloat = 4
        static let closeButtonIconSize: CGFloat = 12
        static let closeButtonIconPointSize: CGFloat = 9
        static let closeButtonIconColor = NSColor(calibratedWhite: 0, alpha: 0.7)
        static let closeButtonHoverColor = NSColor(calibratedWhite: 0, alpha: 0.04)

        static let separatorSize = CGSize(width: 1, height: 16)
        static let separatorColor = ThemedColor { _, appearance in
            DefaultColors.separator.color(for: appearance)
        }

        // FaviconLeading 6 + FaviconSize 16 + titleToCloseButton 14 + CloseButtonSize 24 + CloseButtonTrailing 4
        static let compactModeThreshold: CGFloat = 64
    }

    enum NewTabButton {
        static let size: CGSize = CGSize(width: 32, height: 32)
        static let insets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        static let cornerRadius: CGFloat = 4
    }

    // MARK: - Active-tab outline geometry

    /// Appends the active-tab outer outline (right inverse curve → right side →
    /// top → left side → left inverse curve), going clockwise, to `path`. The
    /// helper performs the initial `move(to:)` to the right apex and ends with
    /// the path's current point at the left apex; the caller closes or
    /// continues the path as needed.
    ///
    /// Both `TabBackgroundLayer.createPath` (for the active tab fill, in tab-
    /// local coords) and `WebContentContainerViewController.updateContentOuterBorder`
    /// (for the unified content border, in WCC-view coords) call this so the
    /// curve geometry stays in one place.
    ///
    /// - Parameters:
    ///   - leftX/rightX: x-coordinates of the tab's left/right sides; the
    ///     inverse-curve apexes sit at `leftX − invR` and `rightX + invR`.
    ///   - apexY: y-coordinate where the inverse-curve apexes meet the strip's
    ///     bottom (= splitView's top edge in the unified path; = `-bottomSpacing`
    ///     in tab-local coords).
    ///   - tabTopY: y-coordinate of the tab's top edge.
    static func appendActiveTabOutline(
        to path: CGMutablePath,
        leftX: CGFloat,
        rightX: CGFloat,
        apexY: CGFloat,
        tabTopY: CGFloat
    ) {
        let invR = Tab.inverseCornerRadius
        let cornerR = Tab.cornerRadius

        // Right apex → up the right inverse curve to the tab's right side.
        path.move(to: CGPoint(x: rightX + invR, y: apexY))
        path.addCurve(
            to: CGPoint(x: rightX, y: apexY + invR),
            control1: CGPoint(x: rightX + invR / 2, y: apexY),
            control2: CGPoint(x: rightX, y: apexY + invR / 2)
        )
        // Up the right side.
        path.addLine(to: CGPoint(x: rightX, y: tabTopY - cornerR))
        // Top-right corner.
        path.addCurve(
            to: CGPoint(x: rightX - cornerR, y: tabTopY),
            control1: CGPoint(x: rightX, y: tabTopY - cornerR / 2),
            control2: CGPoint(x: rightX - cornerR / 2, y: tabTopY)
        )
        // Top edge, going left.
        path.addLine(to: CGPoint(x: leftX + cornerR, y: tabTopY))
        // Top-left corner.
        path.addCurve(
            to: CGPoint(x: leftX, y: tabTopY - cornerR),
            control1: CGPoint(x: leftX + cornerR / 2, y: tabTopY),
            control2: CGPoint(x: leftX, y: tabTopY - cornerR / 2)
        )
        // Down the left side.
        path.addLine(to: CGPoint(x: leftX, y: apexY + invR))
        // Left inverse curve down to the left apex.
        path.addCurve(
            to: CGPoint(x: leftX - invR, y: apexY),
            control1: CGPoint(x: leftX, y: apexY + invR / 2),
            control2: CGPoint(x: leftX - invR / 2, y: apexY)
        )
    }
}

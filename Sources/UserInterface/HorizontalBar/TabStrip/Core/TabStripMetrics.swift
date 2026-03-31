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
        static let idealWidth: CGFloat = 160
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
}

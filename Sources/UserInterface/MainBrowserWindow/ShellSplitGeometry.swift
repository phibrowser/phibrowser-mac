// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Where a sidebar | page split puts its column, page area and divider.
///
/// The column has two widths. The preferred one is the user's: a divider
/// drag, a floating panel resize or an explicit geometry call sets it, and
/// it is the one stored. The effective one is what fits the container now:
/// the page area keeps its minimum ahead of the column, down to the
/// column's own minimum. A container that grows gives the column back up to
/// its preferred width.
struct ShellSplitGeometry: Equatable {
    static let sidebarMinWidth = MainSplitViewController.leftItemMinWidth
    static let sidebarMaxWidth = MainSplitViewController.leftItemMaxWidth
    static let pageMinWidth: CGFloat = 200
    static let dividerHitThickness = PhiSplitViewController.dividerHitThickness

    var sidebarOnRight = false
    var preferredWidth = ShellSplitGeometry.sidebarMinWidth
    /// Whether the column takes its width from the page area. False while
    /// the column is collapsed and while a toggle is in flight: the page
    /// area then spans the container, under the column.
    var columnTakesPageSpace = true

    static func clampedToLimits(_ width: CGFloat) -> CGFloat {
        min(max(width, sidebarMinWidth), sidebarMaxWidth)
    }

    /// The widest the column can be in a container `containerWidth` wide. A
    /// container not laid out yet (no width) limits nothing.
    static func maxWidth(inContainerOfWidth containerWidth: CGFloat) -> CGFloat {
        guard containerWidth > 0 else { return sidebarMaxWidth }
        return max(sidebarMinWidth, min(sidebarMaxWidth, containerWidth - pageMinWidth))
    }

    static func effectiveWidth(preferred: CGFloat, inContainerOfWidth containerWidth: CGFloat) -> CGFloat {
        min(clampedToLimits(preferred), maxWidth(inContainerOfWidth: containerWidth)).rounded()
    }

    func effectiveWidth(inContainerOfWidth containerWidth: CGFloat) -> CGFloat {
        Self.effectiveWidth(preferred: preferredWidth, inContainerOfWidth: containerWidth)
    }

    /// The column's place when shown: flush with its edge of the container.
    /// A collapsed column keeps it, hidden.
    func columnFrame(in size: CGSize) -> CGRect {
        let width = effectiveWidth(inContainerOfWidth: size.width)
        return CGRect(x: sidebarOnRight ? size.width - width : 0, y: 0, width: width, height: size.height)
    }

    func pageFrame(in size: CGSize) -> CGRect {
        guard columnTakesPageSpace else { return CGRect(origin: .zero, size: size) }
        let width = effectiveWidth(inContainerOfWidth: size.width)
        return CGRect(x: sidebarOnRight ? 0 : width, y: 0, width: size.width - width, height: size.height)
    }

    /// The column's inner edge, the one facing the page.
    func dividerPosition(in size: CGSize) -> CGFloat {
        let column = columnFrame(in: size)
        return sidebarOnRight ? column.minX : column.maxX
    }

    func dividerFrame(in size: CGSize) -> CGRect {
        CGRect(x: dividerPosition(in: size) - Self.dividerHitThickness / 2, y: 0,
               width: Self.dividerHitThickness, height: size.height)
    }
}

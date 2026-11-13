// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa

class PhiSplitView: NSSplitView {

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
    }

//    override func drawDivider(in rect: NSRect) {
//
//    }
    override var dividerColor: NSColor { .clear }
    override var dividerThickness: CGFloat { 0 }
}

/// With a zero-thickness divider AppKit only gives it a ~5pt hit area, so
/// widen the effective rect around the drawn divider for dragging and the
/// resize cursor.
class PhiSplitViewController: NSSplitViewController {
    static let dividerHitThickness: CGFloat = 14

    override func splitView(_ splitView: NSSplitView,
                            effectiveRect proposedEffectiveRect: NSRect,
                            forDrawnRect drawnRect: NSRect,
                            ofDividerAt dividerIndex: Int) -> NSRect {
        let rect = super.splitView(splitView, effectiveRect: proposedEffectiveRect, forDrawnRect: drawnRect, ofDividerAt: dividerIndex)
        let isNextToCollapsedItem = splitViewItems[dividerIndex...].prefix(2).contains { $0.isCollapsed }
        guard !isNextToCollapsedItem else { return rect }
        if splitView.isVertical {
            let width = max(rect.width, Self.dividerHitThickness)
            return NSRect(x: drawnRect.midX - width / 2, y: rect.minY, width: width, height: rect.height)
        } else {
            let height = max(rect.height, Self.dividerHitThickness)
            return NSRect(x: rect.minX, y: drawnRect.midY - height / 2, width: rect.width, height: height)
        }
    }
}

extension NSSplitViewItem {
    /// Expands a collapsed item at exactly `width`, instead of the width it
    /// had when it collapsed, which AppKit restores on its own. The sidebar
    /// column docks this way after its floating panel was resized while the
    /// column was collapsed. The item's thickness limits are pinned to
    /// `width` for the expansion, so the animation runs to that width, and
    /// restored once it has finished.
    func expand(atWidth width: CGFloat, animated: Bool, in splitView: NSSplitView) {
        guard isCollapsed else { return }
        let minimum = minimumThickness
        let maximum = maximumThickness
        minimumThickness = width
        maximumThickness = width
        let restoreLimits = { [weak self] in
            self?.minimumThickness = minimum
            self?.maximumThickness = maximum
        }
        if animated {
            // The expand animation runs to the collapsed view's own size,
            // regardless of the limits.
            viewController.view.setFrameSize(NSSize(width: width, height: viewController.view.frame.height))
            NSAnimationContext.runAnimationGroup({ _ in
                self.animator().isCollapsed = false
            }, completionHandler: restoreLimits)
        } else {
            isCollapsed = false
            splitView.layoutSubtreeIfNeeded()
            restoreLimits()
        }
    }
}

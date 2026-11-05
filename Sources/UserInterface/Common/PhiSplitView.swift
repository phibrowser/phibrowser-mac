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

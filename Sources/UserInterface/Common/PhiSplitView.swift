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

enum SidebarToggleAnimation {
    static let duration: TimeInterval = 0.125
}

extension NSSplitViewItem {
    /// AppKit animates `isCollapsed` with the item's "collapsed" animation and
    /// ignores `NSAnimationContext.duration`, so the duration is set there.
    func setCollapsedAnimated(_ collapsed: Bool,
                              duration: TimeInterval = SidebarToggleAnimation.duration,
                              completion: (() -> Void)? = nil) {
        let animation: CABasicAnimation
        if let base = Self.defaultAnimation(forKey: "collapsed") as? CABasicAnimation,
           let copy = base.copy() as? CABasicAnimation {
            animation = copy
        } else {
            animation = CABasicAnimation()
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        }
        animation.duration = duration
        animations["collapsed"] = animation
        NSAnimationContext.runAnimationGroup({ _ in
            self.animator().isCollapsed = collapsed
        }, completionHandler: completion)
    }

    /// Expands a collapsed item at exactly `width`, instead of the width it
    /// had when it collapsed, which AppKit restores on its own. The sidebar
    /// column docks this way after its floating panel was resized while the
    /// column was collapsed. The item's thickness limits are pinned to
    /// `width` for the expansion, so the animation runs to that width, and
    /// set back to `limits` once it has finished. `limits` comes from the
    /// caller rather than the item: an expansion cut short would otherwise
    /// leave the pinned width behind as the item's own limits.
    func expand(atWidth width: CGFloat, animated: Bool, in splitView: NSSplitView,
                limits: ClosedRange<CGFloat>, completion: (() -> Void)? = nil) {
        guard isCollapsed else { return }
        minimumThickness = width
        maximumThickness = width
        let restoreLimits = { [weak self] in
            self?.minimumThickness = limits.lowerBound
            self?.maximumThickness = limits.upperBound
            completion?()
        }
        if animated {
            // The expand animation runs to the collapsed view's own size,
            // regardless of the limits.
            viewController.view.setFrameSize(NSSize(width: width, height: viewController.view.frame.height))
            setCollapsedAnimated(false, completion: restoreLimits)
        } else {
            isCollapsed = false
            splitView.layoutSubtreeIfNeeded()
            restoreLimits()
        }
    }
}

/// Tracks the sidebar column's collapse/expand animation, so a toggle that
/// arrives while one is running can be dropped instead of reversing it from
/// a half-way frame.
final class SidebarToggleAnimationGate {
    /// How long past the animation's duration a missing completion is waited
    /// for. AppKit can skip it, and the column must not stay locked then.
    private static let completionGrace: TimeInterval = 0.5

    private(set) var isAnimating = false
    private var generation = 0

    /// Marks an animation as running and returns the handler that ends it.
    /// The handler does nothing once a later `begin` or `reset` has
    /// superseded this animation.
    func begin() -> () -> Void {
        generation += 1
        isAnimating = true
        let generation = generation
        let end = { [weak self] in
            guard let self, generation == self.generation else { return }
            self.isAnimating = false
        }
        DispatchQueue.main.asyncAfter(
            deadline: .now() + SidebarToggleAnimation.duration + Self.completionGrace
        ) { [weak self] in
            guard let self, generation == self.generation, self.isAnimating else { return }
            AppLogDebug("[SidebarToggle] animation completion never arrived; unlocking")
            end()
        }
        return end
    }

    /// A non-animated change takes over from whatever animation was running.
    func reset() {
        generation += 1
        isAnimating = false
    }
}

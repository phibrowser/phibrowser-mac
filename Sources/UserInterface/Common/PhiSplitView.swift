// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Combine

class PhiSplitView: NSSplitView {
    override var dividerColor: NSColor { .clear }
    override var dividerThickness: CGFloat { 0 }
}

/// With a zero-thickness divider AppKit only gives it a ~5pt hit area, so
/// widen the effective rect around the drawn divider for dragging and the
/// resize cursor.
class PhiSplitViewController: NSSplitViewController {
    static let dividerHitThickness: CGFloat = 14

    let sidebarExpansionDidFinish = PassthroughSubject<Void, Never>()
    private var sidebarTargetCollapsed = false
    private var sidebarTransitions = 0
    private var pendingExpansion: Int?
    /// An animated expansion has started and not finished. AppKit publishes
    /// the expanded state as soon as the animation starts.
    var isSidebarExpanding: Bool { pendingExpansion != nil }

    func setSidebarCollapsed(_ collapsed: Bool, item: NSSplitViewItem, animated: Bool,
                             dockWidth: CGFloat?) {
        sidebarTargetCollapsed = collapsed
        sidebarTransitions += 1
        let transition = sidebarTransitions
        pendingExpansion = animated && !collapsed ? transition : nil
        let finished = { [weak self] in
            guard let self, self.pendingExpansion == transition else { return }
            self.pendingExpansion = nil
            self.sidebarExpansionDidFinish.send()
        }

        if !collapsed, let dockWidth {
            item.expand(atWidth: dockWidth, animated: animated, in: splitView,
                        limits: MainSplitViewController.leftItemMinWidth...MainSplitViewController.leftItemMaxWidth,
                        completion: finished)
        } else if animated {
            item.setCollapsedAnimated(collapsed) { [weak self, weak item] in
                // AppKit can hide the column when a superseded collapse completes.
                if collapsed, self?.sidebarTargetCollapsed == false, let item, item.isCollapsed {
                    item.isCollapsed = false
                }
                finished()
            }
        } else {
            item.isCollapsed = collapsed
        }
    }

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
    static let duration: TimeInterval = 0.11
    static let timingFunction = CAMediaTimingFunction(controlPoints: 0.1, 0.4, 0.6, 1)
}

extension NSSplitViewItem {
    /// AppKit animates `isCollapsed` with the item's "collapsed" animation and
    /// ignores `NSAnimationContext`'s duration and timing function, so both
    /// are set there.
    func setCollapsedAnimated(_ collapsed: Bool,
                              duration: TimeInterval = SidebarToggleAnimation.duration,
                              completion: (() -> Void)? = nil) {
        let animation: CABasicAnimation
        if let base = Self.defaultAnimation(forKey: "collapsed") as? CABasicAnimation,
           let copy = base.copy() as? CABasicAnimation {
            animation = copy
        } else {
            animation = CABasicAnimation()
        }
        animation.duration = duration
        animation.timingFunction = SidebarToggleAnimation.timingFunction
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
        guard isCollapsed else {
            completion?()
            return
        }
        minimumThickness = width
        maximumThickness = width
        let restoreLimits = { [weak self] in
            self?.minimumThickness = limits.lowerBound
            self?.maximumThickness = limits.upperBound
        }
        if animated {
            // The expand animation runs to the collapsed view's own size,
            // regardless of the limits.
            viewController.view.setFrameSize(NSSize(width: width, height: viewController.view.frame.height))
            setCollapsedAnimated(false) {
                restoreLimits()
                completion?()
            }
        } else {
            isCollapsed = false
            splitView.layoutSubtreeIfNeeded()
            restoreLimits()
            completion?()
        }
    }
}

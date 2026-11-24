// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Combine

class PhiSplitView: NSSplitView {
    /// The thick and pane-splitter styles draw a dimple at the divider's
    /// center even when its thickness is zero.
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        dividerStyle = .thin
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        dividerStyle = .thin
    }

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
    /// A divider drag released past the collapse threshold slides the column
    /// out over this, slower than a toggle so the hand-off from the pointer
    /// reads as a motion rather than a jump.
    static let dragReleaseDuration: TimeInterval = 0.22
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

@MainActor
extension NSSplitViewController {
    /// Moves the sidebar item to the other side, keeping its collapsed state.
    /// `width` is the destination side's own last expanded width (0 keeps the
    /// current width); it is applied to a visible column, and to a collapsed
    /// one's hidden view so the next expand opens at it.
    func repositionSidebarItem(_ previous: NSSplitViewItem, onRight: Bool, width destinationWidth: CGFloat, autosaveName: String) -> NSSplitViewItem {
        let restoringExistingGeometry = splitView.autosaveName != nil
        let collapsed = previous.isCollapsed
        let currentWidth = max(previous.minimumThickness, previous.viewController.view.frame.width)
        if restoringExistingGeometry, !collapsed {
            // The outgoing side's width is only in its autosaved frames,
            // which the move drops; keep it for the next switch back.
            AccountController.shared.localDataAccount?.userDefaults
                .setLastKnownSidebarWidth(currentWidth, for: onRight ? .left : .right)
        }
        let width = destinationWidth > 0
            ? min(max(destinationWidth, previous.minimumThickness), previous.maximumThickness)
            : currentWidth
        splitView.autosaveName = nil
        // AppKit restores the frames saved under a name as soon as it is
        // assigned, setting the subviews' hidden state behind the item's
        // `isCollapsed` (the split then reports collapsed while the column
        // shows, or expands to zero width), and offers no way to assign a
        // name without that restore. A live move therefore drops the frames
        // saved under the destination name: the destination side's width is
        // carried by `width` instead, and the frames applied below are what
        // AppKit saves under that name next.
        if restoringExistingGeometry {
            UserDefaults.standard.removeObject(forKey: "NSSplitView Subview Frames \(autosaveName)")
        }
        removeSplitViewItem(previous)
        let item: NSSplitViewItem
        if #available(macOS 26.0, *) {
            item = previous
        } else {
            // Before macOS 26 the move rebuilds the item. It is a plain item
            // on both sides; see `MainSplitViewController.setupLeftSplitViewItem`.
            item = NSSplitViewItem(viewController: previous.viewController)
            item.minimumThickness = previous.minimumThickness
            item.maximumThickness = previous.maximumThickness
            item.holdingPriority = previous.holdingPriority
            item.canCollapse = previous.canCollapse
        }
        item.collapseBehavior = onRight ? .preferResizingSiblingsWithFixedSplitView : .default
        item.isCollapsed = collapsed
        let index = onRight ? 1 : 0
        insertSplitViewItem(item, at: index)
        if restoringExistingGeometry { splitView.autosaveName = autosaveName }
        item.isCollapsed = collapsed
        view.layoutSubtreeIfNeeded()
        if restoringExistingGeometry {
            if collapsed {
                // A collapsed subview keeps its size while hidden and
                // expands back to it.
                if splitView.arrangedSubviews.indices.contains(index) {
                    let column = splitView.arrangedSubviews[index]
                    column.setFrameSize(NSSize(width: width, height: column.frame.height))
                }
            } else {
                splitView.setPosition(onRight ? splitView.bounds.width - splitView.dividerThickness - width : width, ofDividerAt: 0)
            }
        }
        return item
    }
}

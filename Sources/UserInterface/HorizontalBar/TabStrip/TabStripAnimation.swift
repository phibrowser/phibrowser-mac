// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import QuartzCore

/// Triggers for tab-strip layout animations.
enum TabStripAnimationContext {
    case none
    case dataChanged
    case dragReorder
    case stateChanged
}

/// Animation configuration for a tab-strip transition.
struct TabStripAnimationConfig {
    let duration: TimeInterval
    let timingFunction: CAMediaTimingFunction
    let allowsImplicitAnimation: Bool

    static func config(for context: TabStripAnimationContext) -> TabStripAnimationConfig {
        switch context {
        case .none:
            return TabStripAnimationConfig(
                duration: 0,
                timingFunction: CAMediaTimingFunction(name: .linear),
                allowsImplicitAnimation: false
            )
        case .dataChanged:
            return TabStripAnimationConfig(
                duration: 0.18,
                timingFunction: CAMediaTimingFunction(name: .easeInEaseOut),
                allowsImplicitAnimation: true
            )
        case .dragReorder:
            return TabStripAnimationConfig(
                duration: 0.18,
                timingFunction: CAMediaTimingFunction(name: .default),
                allowsImplicitAnimation: true
            )
        case .stateChanged:
            return TabStripAnimationConfig(
                duration: 0.25,
                timingFunction: CAMediaTimingFunction(name: .easeOut),
                allowsImplicitAnimation: true
            )
        }
    }
}

/// Helper for tab-strip layout animations.
enum TabStripAnimationHelper {
    
    /// Performs a layout animation for the given context.
    /// - Parameters:
    ///   - context: Animation trigger.
    ///   - animations: Layout changes to animate.
    ///   - completion: Optional completion handler.
    static func performLayout(
        _ context: TabStripAnimationContext,
        animations: @escaping () -> Void,
        completion: (() -> Void)? = nil
    ) {
        let config = TabStripAnimationConfig.config(for: context)
        
        if config.duration > 0 {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = config.duration
                ctx.timingFunction = config.timingFunction
                ctx.allowsImplicitAnimation = config.allowsImplicitAnimation
                animations()
            }, completionHandler: completion)
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            animations()
            CATransaction.commit()
            completion?()
        }
    }

    /// Applies the lifted drag appearance.
    static func animateLift(_ view: NSView) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            
            view.layer?.zPosition = 1000
            view.layer?.transform = CATransform3DMakeScale(1.05, 1.05, 1.0)
            
            view.layer?.shadowColor = NSColor.black.cgColor
            view.layer?.shadowOffset = CGSize(width: 0, height: -4)
            view.layer?.shadowRadius = 8
            view.layer?.shadowOpacity = 0
        }
    }

    /// Restores the default appearance after drag completes.
    static func animateDrop(_ view: NSView, finalZOrder: CGFloat = 0) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            
            view.layer?.transform = CATransform3DIdentity
            view.layer?.shadowOpacity = 0
            view.layer?.zPosition = finalZOrder
        }
    }
}

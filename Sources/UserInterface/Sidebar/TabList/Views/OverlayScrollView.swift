// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa

class OverlayScrollView: NSScrollView {
    /// Routing decision for the current trackpad gesture, latched on the first
    /// non-zero delta and held through momentum so a swipe that drifts
    /// diagonally doesn't alternate between scrolling and forwarding.
    private enum GestureAxis {
        case undecided
        case horizontal
        case vertical
    }
    private var gestureAxis: GestureAxis = .undecided

    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set {}
    }

    /// NSScrollView consumes every phased gesture once one of its axes is
    /// scrollable, so the sidebar-wide swipe-to-switch-Space handler
    /// (SidebarViewController.scrollWheel) would never see sideways swipes
    /// over the tab list. Route horizontal-dominant gestures up the responder
    /// chain instead; vertical ones scroll the list as usual.
    override func scrollWheel(with event: NSEvent) {
        // Legacy wheel events carry no gesture phases; always scroll.
        guard event.phase != [] || event.momentumPhase != [] else {
            super.scrollWheel(with: event)
            return
        }

        if event.phase == .mayBegin || event.phase == .began {
            gestureAxis = .undecided
        }

        if gestureAxis == .undecided {
            let dx = abs(event.scrollingDeltaX)
            let dy = abs(event.scrollingDeltaY)
            if dx > dy {
                gestureAxis = .horizontal
            } else if dy > dx {
                gestureAxis = .vertical
            }
        }

        if gestureAxis == .horizontal {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

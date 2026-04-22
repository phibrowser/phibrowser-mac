// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

/// Helpers for computing the anchor point passed to Chromium via
/// `triggerExtension(withId:pointInScreen:windowId:)`.
///
/// Chromium's `ExtensionPopup::GetBubbleBounds` treats the supplied point as
/// the popup bubble's top-left origin (with an internal horizontal-centering
/// heuristic). Passing a view's visual bottom-left corner makes the popup's
/// top edge align with the icon's bottom edge.
@MainActor
enum ExtensionPopupAnchor {
    /// Returns `view`'s visual bottom-left corner in Chromium screen
    /// coordinates (top-left origin). Returns `nil` if `view` is not
    /// attached to a window.
    static func pointBelowView(_ view: NSView) -> NSPoint? {
        guard let window = view.window else { return nil }
        let rectInWindow = view.convert(view.bounds, to: nil)
        let rectInScreen = window.convertToScreen(rectInWindow)
        // `rectInScreen` is in AppKit's bottom-left-origin screen space, so
        // `minY` is the visual bottom edge.
        return chromiumScreenPoint(from: NSPoint(x: rectInScreen.minX, y: rectInScreen.minY))
    }

    /// Returns the current mouse location in Chromium screen coordinates
    /// (top-left origin). Used as a defensive fallback when a view-based
    /// anchor is not yet available.
    static func mouseFallback() -> NSPoint {
        chromiumScreenPoint(from: NSEvent.mouseLocation)
    }

    /// Flips an AppKit (bottom-left-origin) screen point to Chromium's
    /// top-left-origin convention using the primary display, which matches
    /// Chromium's `screen_mac.mm` conversion logic.
    static func chromiumScreenPoint(
        from point: NSPoint,
        primaryScreenFrame: NSRect? = NSScreen.screens.first?.frame
    ) -> NSPoint {
        let screenHeight = primaryScreenFrame?.height ?? 0
        return NSPoint(x: point.x, y: screenHeight - point.y)
    }
}

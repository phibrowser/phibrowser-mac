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
        return flipToChromiumScreen(
            NSPoint(x: rectInScreen.minX, y: rectInScreen.minY)
        )
    }

    /// Returns the current mouse location in Chromium screen coordinates
    /// (top-left origin). Used as a defensive fallback when a view-based
    /// anchor is not yet available.
    static func mouseFallback() -> NSPoint {
        flipToChromiumScreen(NSEvent.mouseLocation)
    }

    /// Flips an AppKit (bottom-left-origin) screen point to Chromium's
    /// top-left-origin convention.
    ///
    /// Known limitation: uses `NSScreen.main?.frame.height` (the key-window
    /// screen), which is NOT the screen that anchors AppKit's coordinate
    /// system in a multi-display setup. This preserves the pre-existing
    /// behavior of all five extension trigger call sites. To fix multi-screen
    /// accuracy, replace `NSScreen.main?.frame.height ?? 0` with
    /// `NSScreen.screens.map { $0.frame.maxY }.max() ?? 0` — see
    /// `TabDraggingSession.swift` (`snapshotImageUsingWindowServer`) for the
    /// correct pattern already used elsewhere in this codebase.
    private static func flipToChromiumScreen(_ point: NSPoint) -> NSPoint {
        let screenHeight = NSScreen.main?.frame.height ?? 0
        return NSPoint(x: point.x, y: screenHeight - point.y)
    }
}

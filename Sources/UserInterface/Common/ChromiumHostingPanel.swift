// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

/// Base class for the child panels that host a live Chromium tab view over the
/// page pane — the Peek panel and the Reader View overlay.
///
/// Such a panel takes key and makes the re-parented Chromium view its first
/// responder, and that pairing used to swallow every keyboard shortcut:
///
///   1. AppKit sends `performKeyEquivalent:` to the key window, this panel. A
///      plain `NSPanel` carries no Chromium `CommandDispatcher`, so neither
///      Chromium's shortcut table nor Phi's `CommandDispatcher` bridge — both
///      hang off `prePerformKeyEquivalent` — ever runs.
///   2. The default implementation walks the view hierarchy instead, where
///      `RenderWidgetHostViewCocoa`, first responder in the app's key window,
///      hands the event to the renderer and answers YES.
///   3. YES reads as "consumed", so the main menu never gets its turn either.
///   4. The renderer declines, and the unhandled-key path looks the owning
///      browser window up from `NSEvent.window` — this panel, which is not a
///      views widget window. The event was dropped there instead of being
///      redispatched.
///
/// Step 4 is where the chain is repaired, on the Chromium side:
/// `UnhandledKeyboardEventHandler::HandleNativeKeyboardEvent` now walks up to
/// the browser window that owns the WebContents. That restores the same order
/// a normal browser window uses — the hosted page keeps first crack at the
/// event, and only what it declines reaches the command layer and NSMenu.
///
/// This class supplies the one piece that has to live on the panel: declining
/// the redispatched event so it can land in the main menu. Without it the
/// redispatch loops straight back into the view that already passed on the
/// event.
class ChromiumHostingPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // A redispatched event: the renderer declined it, so Chromium re-sent
        // it with the browser window stamped into `NSEvent.window`, but AppKit
        // routes key equivalents to the key window — us. Chromium's own
        // `CommandDispatcher` recognises the redispatch by that stamp and skips
        // ahead to `postPerformKeyEquivalent`; a plain panel has no dispatcher,
        // so decline instead. AppKit then moves on to the main menu, which is
        // where the menu-only commands (⌘Q, ⌘M, ⌘,) are waiting.
        //
        // Handing it to `super` here would instead feed it back to the hosted
        // web view, which would forward it to the renderer, which would decline
        // it again — an unbounded redispatch loop.
        if let eventWindow = event.window, eventWindow !== self {
            return false
        }
        return super.performKeyEquivalent(with: event)
    }
}

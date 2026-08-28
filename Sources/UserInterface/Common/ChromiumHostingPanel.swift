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
/// This class supplies the two pieces that have to live on the panel, both of
/// them the plain-`NSPanel` stand-in for what `CommandDispatcher` does on every
/// Chromium-owned window: recognise a redispatched event by the window stamped
/// into it, and refuse to hand it back to the hosted view that already passed
/// on it once.
class ChromiumHostingPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    /// Whether `event` is one Chromium redispatched after the renderer declined
    /// it. `-[CommandDispatcher redispatchKeyEvent:]` rewrites the event's
    /// window to the browser window that owns the dispatcher before sending it
    /// back through `-[NSApp sendEvent:]`, so a key event that arrives here
    /// carrying any window other than this panel is a second pass.
    ///
    /// Chromium's own windows make this same test through
    /// `-[CommandDispatcher isEventBeingRedispatched:]`, which additionally
    /// reads the `_isRedispatchingKeyEvent` flag off the stamped window's
    /// dispatcher — not reachable from here, and not needed: AppKit only ever
    /// routes a key event to the key window, so the stamp alone separates a
    /// first pass from a redispatch.
    private func isRedispatchedKeyEvent(_ event: NSEvent) -> Bool {
        switch event.type {
        case .keyDown, .keyUp, .flagsChanged:
            guard let eventWindow = event.window else { return false }
            return eventWindow !== self
        default:
            return false
        }
    }

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
        if isRedispatchedKeyEvent(event) {
            return false
        }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        // The other half of the redispatch guard, and the one plain typing
        // needs. A printable keystroke is not a key equivalent, so AppKit never
        // offers it to `performKeyEquivalent:` above — it goes straight to the
        // key window's responder chain. That path doubled every character typed
        // into a hosted page:
        //
        //   1. `keyDown:` reaches the hosted `RenderWidgetHostViewCocoa`, which
        //      inserts the character and forwards the raw key event.
        //   2. The renderer declines the raw key event — text insertion already
        //      happened through the input system — so Chromium redispatches it
        //      to the browser window, restamping the event on the way.
        //   3. AppKit routes key events to the key window, still this panel, and
        //      a plain `NSPanel` has nothing to stop it: the responder chain
        //      hands the same keystroke to the same view, which inserts the
        //      character a second time.
        //   4. That second insertion's raw key event is declined too, but the
        //      redispatch stops there — the event is stamped with the browser
        //      window by now, and `redispatchKeyEvent:` refuses to redispatch to
        //      a window that is not key. Hence exactly two characters, not a
        //      runaway loop.
        //
        // Every Chromium-owned window drops the event at this point instead,
        // through `-[CommandDispatcher preSendEvent:]`, whose whole job on a
        // redispatch is to "stop native -sendEvent handling". By then the
        // redispatch has already served its purpose inside `-[NSApp sendEvent:]`
        // — the key-equivalent pass and the main menu have both had their turn —
        // so there is nothing left to deliver.
        if isRedispatchedKeyEvent(event) {
            return
        }
        super.sendEvent(event)
    }
}

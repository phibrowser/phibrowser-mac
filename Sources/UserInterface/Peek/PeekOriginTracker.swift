// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

/// Remembers where in the page pane the user last pressed the mouse, so a
/// peek can fly out of the link that opened it instead of appearing from
/// nowhere.
///
/// Chromium reports no coordinates for the link that spawned the tab
/// (`NativeTabCreationContext` carries ids only), but both peek entry points
/// are mouse-driven and both put the press on the link itself: a plain click
/// on a bound tab's cross-site link, and the right-click that opens the
/// "Open Link in Peek View" menu — the menu item's own click lands in the
/// menu's window, so it cannot overwrite the link press recorded here.
///
/// The origin is ONE-SHOT and pane-scoped: each press funds at most one
/// flight, and presses outside the page pane are ignored. A peek that opens
/// without a fresh press — keyboard, session restore, a tab switch revealing
/// an existing peek — therefore gets no origin and simply appears the way it
/// did before the flight existed.
final class PeekOriginTracker {
    /// How long a recorded press stays usable. Generous on purpose: the peek
    /// decision waits for the candidate's first URL (up to
    /// `BrowserState.peekDecisionTimeoutSeconds`), and the context-menu path
    /// additionally waits for the user to read the menu. Any newer press in
    /// the pane replaces the old one anyway — this bound only stops a peek
    /// arriving much later from flying out of a long-forgotten click.
    private static let freshnessWindow: TimeInterval = 15

    /// Held as the controller, not the view: reading `.view` would force the
    /// page pane to load, and nothing else about installing this tracker
    /// should pull Chromium's content views up earlier than they already
    /// load. An unloaded pane also means there is no peek to fly.
    private weak var paneViewController: NSViewController?
    private var monitor: Any?
    private var pressScreenPoint: NSPoint?
    private var pressedAt: Date?

    /// - Parameter paneViewController: the web-content pane's controller;
    ///   only presses that hit-test into its view hierarchy are recorded.
    init(paneViewController: NSViewController) {
        self.paneViewController = paneViewController
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            self?.record(event)
            return event
        }
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    /// The last press in the pane, in screen coordinates, or nil when there
    /// is none, it has gone stale, or it was already spent on a flight.
    func consumeOrigin() -> NSPoint? {
        defer { invalidate() }
        guard let pressScreenPoint, let pressedAt,
              Date().timeIntervalSince(pressedAt) <= Self.freshnessWindow else { return nil }
        return pressScreenPoint
    }

    /// Drops the recorded press without spending it on a flight. The window
    /// controller calls this whenever the focused tab changes: a press only
    /// belongs to the peek it opened, and the focused tab does not change on
    /// that path (the opener stays focused while its peek is created), so a
    /// focus change means the press and the next peek are unrelated.
    func invalidate() {
        pressScreenPoint = nil
        pressedAt = nil
    }

    private func record(_ event: NSEvent) {
        guard let paneView = paneViewController?.viewIfLoaded,
              let window = paneView.window,
              event.window === window else { return }
        // Hit-test rather than a frame check: the sidebar, the toolbar and any
        // overlay above the pane must not be mistaken for a link press. Same
        // filter shape as `SplitPaneHostView`'s pane click monitor.
        guard let hitView = window.contentView?.hitTest(event.locationInWindow),
              hitView.isDescendant(of: paneView) else { return }
        pressScreenPoint = window.convertPoint(toScreen: event.locationInWindow)
        pressedAt = Date()
    }
}

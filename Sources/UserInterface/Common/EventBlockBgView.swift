// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa

class EventBlockBgView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
    }
    
    var mouseDown: ((NSEvent) -> Void)?

    /// When set, the overlay owns only the returned view (and its subviews):
    /// a hit anywhere else answers nil, so the click falls through to whatever
    /// sits beneath this view in the same window instead of being swallowed
    /// (and `mouseDown` is never invoked for it). nil keeps the overlay modal.
    var clickThroughOutside: (() -> NSView?)?

    /// Called once per mouse-down that fell through `clickThroughOutside`,
    /// before the click reaches the view beneath. Callers that dismiss the
    /// overlay must do so on a later turn: the click is still being hit-tested.
    var clickedThroughOutside: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard let keep = clickThroughOutside?() else { return hit }
        var view = hit
        while let current = view {
            if current === keep { return hit }
            view = current.superview
        }
        // Hit testing also runs for hover and cursor updates; only a press
        // counts as a click outside.
        if let type = NSApp.currentEvent?.type,
           type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
            clickedThroughOutside?()
        }
        return nil
    }

    // Transparent but intercepts events. None of the left-button events go
    // to `super`: AppKit hands an unhandled mouse event to the view beneath
    // this one (it hit-tests the window again), which would click the
    // control the overlay covers. Owners act on `mouseDown` and forward a
    // click outside themselves explicitly.
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) {
        mouseDown?(event)
    }

    override func mouseMoved(with event: NSEvent) {

    }

    override func mouseDragged(with event: NSEvent) {

    }

    override func mouseUp(with event: NSEvent) {

    }
    
    override func rightMouseDown(with event: NSEvent) {
        
    }
    
    override func rightMouseUp(with event: NSEvent) {
        
    }
    
    // Swallow hit-testing so A never receives click/hover when B is visible
//    override func hitTest(_ point: NSPoint) -> NSView? {
//        let p = convert(point, from: superview)
//        return bounds.contains(p) ? self : nil
//    }
//
//    // Force arrow cursor over the whole overlay (preempts A's cursor)
//    override func resetCursorRects() {
//        super.resetCursorRects()
//        discardCursorRects()
//        addCursorRect(bounds, cursor: .arrow)
//    }
}

/// A clear borderless child window over a browser window that takes the
/// pointer while an icon picker popover is open. Tracking areas fire only in
/// the window under the pointer, so nothing under the picker reacts to hover:
/// a hovered folder opened its preview, which took key and closed the picker.
/// A popover shown after the shield sits above it. A click on the shield
/// closes the transient popover, as any click outside it does, and reaches
/// nothing under it.
@MainActor
final class HoverShield {
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    /// Covers `parent` until `remove()`.
    func cover(_ parent: NSWindow) {
        remove()
        let shield = Self.makeWindow(over: parent)
        parent.addChildWindow(shield, ordered: .above)
        window = shield
    }

    /// Covers `parent` until `popover` starts to close. Call it before
    /// showing the popover; the shield keeps itself alive until then.
    static func cover(_ parent: NSWindow, until popover: NSPopover) {
        let shield = HoverShield()
        shield.cover(parent)
        shield.closeObserver = NotificationCenter.default.addObserver(
            forName: NSPopover.willCloseNotification, object: popover, queue: .main
        ) { _ in
            MainActor.assumeIsolated { shield.remove() }
        }
        // Lifts the shield if the popover never shows.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak popover] in
            guard popover?.isShown != true else { return }
            shield.remove()
        }
    }

    func remove() {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
            self.closeObserver = nil
        }
        guard let window else { return }
        window.parent?.removeChildWindow(window)
        window.orderOut(nil)
        self.window = nil
    }

    static func makeWindow(over parent: NSWindow) -> NSWindow {
        let shield = NSWindow(contentRect: parent.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        shield.isReleasedWhenClosed = false
        shield.isOpaque = false
        shield.backgroundColor = .clear
        shield.hasShadow = false
        shield.ignoresMouseEvents = false
        shield.contentView = ShieldView()
        return shield
    }

    /// Takes clicks, scrolls and the cursor so nothing under the shield gets
    /// them.
    private final class ShieldView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {}
        override func rightMouseDown(with event: NSEvent) {}
        override func otherMouseDown(with event: NSEvent) {}
        override func scrollWheel(with event: NSEvent) {}
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .arrow)
        }
    }
}

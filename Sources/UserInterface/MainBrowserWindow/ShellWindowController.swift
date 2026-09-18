// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa

/// Hosted-window mode: the one visible NSWindow of a `SpaceWindowSlot`.
///
/// In hosted-window mode (`SpaceManager.isHostedWindowMode`) Chromium never
/// shows a browser window of its own. The slot owns this shell, and each Space
/// it has surfaced is a `SpaceSessionController` session whose split
/// view is installed as the shell's content while that Space is presented.
/// Switching Space swaps the content view controller; the hidden Chromium
/// windows behind the sessions only carry the Browser's lifecycle and mirror
/// the shell's frame.
///
/// Main-menu items carry Chromium's `commandDispatch:` action. On a
/// Chromium-created window AppKit finds that selector on the window itself;
/// here the shell forwards it — and its validation — to the presented
/// session's Chromium window, so the existing pipeline (Chromium's
/// CommandDispatcher → PhiCommandHandler → `PhiChromiumCoordinator`
/// → `CommandDispatcher`) runs unchanged and resolves back to the presented
/// session through `SpaceSessionControllersManager.findControllerWith`.
final class ShellWindow: NSWindow {
    /// The presented session's hidden Chromium window, which owns the
    /// command pipeline. Set by `SpaceSessionController.presentInShell`.
    weak var commandTargetWindow: NSWindow?

    /// The controller that owns this window (sessions reach the shell's
    /// window-level state, such as the traffic-light positioner, through it).
    weak var shellController: ShellWindowController?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    @objc func commandDispatch(_ sender: Any?) {
        forwardCommand(#selector(ShellWindow.commandDispatch(_:)), sender: sender)
    }

    @objc func commandDispatchUsingKeyModifiers(_ sender: Any?) {
        forwardCommand(#selector(ShellWindow.commandDispatchUsingKeyModifiers(_:)), sender: sender)
    }

    private func forwardCommand(_ selector: Selector, sender: Any?) {
        guard let target = commandTargetWindow, target.responds(to: selector) else { return }
        _ = target.perform(selector, with: sender)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        guard item.action == #selector(ShellWindow.commandDispatch(_:))
                || item.action == #selector(ShellWindow.commandDispatchUsingKeyModifiers(_:)) else {
            return super.validateUserInterfaceItem(item)
        }
        guard let target = commandTargetWindow else { return false }
        return target.validateUserInterfaceItem(item)
    }

    /// A key event the presented session's Chromium window is redispatching.
    ///
    /// A shortcut the page declines (⌘T with the web content focused) comes
    /// back through Chromium's `CommandDispatcher` on that hidden window,
    /// which re-sends it with `NSEvent.window` set to itself. AppKit still
    /// routes key events to the key window, this shell, so the shell hands
    /// them straight back to that window: its dispatcher recognises the
    /// second pass, skips the page, and lets the main menu (or a non-menu
    /// accelerator) run the command. Handling the pass here instead would
    /// send the event to the page a second time and loop.
    private func redispatchTarget(for event: NSEvent) -> NSWindow? {
        guard let target = commandTargetWindow, event.window === target else { return nil }
        switch event.type {
        case .keyDown, .keyUp, .flagsChanged:
            return target
        default:
            return nil
        }
    }

    override func sendEvent(_ event: NSEvent) {
        if let target = redispatchTarget(for: event) {
            // Nothing took the second pass: the Chromium window's
            // `sendEvent` marks the redispatch unhandled and stops.
            target.sendEvent(event)
            return
        }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let target = redispatchTarget(for: event) {
            return target.performKeyEquivalent(with: event)
        }
        // Phi-only shortcuts and the agent lock are intercepted here, exactly
        // where a Chromium window's command dispatcher lets the Mac side see
        // the event first (`PhiCommandDispatcherDelegate`).
        if CommandDispatcher.handleKeyEquivalent(event, window: self) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Owns a slot's shell window and relays its AppKit lifecycle — key status,
/// fullscreen, frame changes, close — to the slot. Deliberately not an
/// `NSWindowController`: the presented session's controller takes the
/// window's `windowController` role so the responder chain and
/// `SpaceSessionControllersManager` resolve to the Space on screen.
final class ShellWindowController: NSObject, NSWindowDelegate {
    static let defaultContentSize = SpaceSessionController.defaultWindowSize

    let window: ShellWindow
    private(set) weak var slot: SpaceWindowSlot?

    /// Set by the slot once its sessions have drained, so the pending close
    /// that `windowShouldClose` refused can go through.
    var allowsClose = false

    /// The one traffic-light positioner of this window. Sessions come and go
    /// inside the shell; the lights belong to the window and must not move
    /// on a Space switch, so the positioner is rebuilt only when the layout
    /// mode changes (or dropped for fullscreen), never per session.
    private var trafficLightPositioner: TrafficLightPositioner?
    private var trafficLightLayoutMode: LayoutMode?

    @MainActor
    func updateTrafficLightPlacement(fullScreen: Bool) {
        guard !fullScreen else {
            // AppKit rebuilds the titlebar across the transition and restores
            // the default placement on its own.
            trafficLightPositioner?.stop(restoringPlacement: false)
            trafficLightPositioner = nil
            trafficLightLayoutMode = nil
            return
        }
        let layoutMode = PhiPreferences.GeneralSettings.loadLayoutMode()
        guard trafficLightLayoutMode != layoutMode || trafficLightPositioner == nil else { return }
        trafficLightPositioner?.stop(restoringPlacement: true)
        let positioner = TrafficLightPositioner(
            window: window,
            centerFromWindowTop: SpaceSessionController.chromeRowCenter(for: layoutMode)
        )
        trafficLightPositioner = positioner
        trafficLightLayoutMode = layoutMode
        positioner.start()
    }

    init(slot: SpaceWindowSlot, frame: NSRect?) {
        self.slot = slot
        let contentRect = frame ?? Self.defaultFrame()
        window = ShellWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor.windowBackgroundColor
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Phi"
        window.isMovableByWindowBackground = true
        window.animationBehavior = .none
        // Chromium owns session restore and the slot owns frame continuity,
        // exactly as for the adopted Chromium windows (see
        // `SpaceSessionController.setupWindow`).
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.minSize = NSSize(width: 400, height: 300)
        // Sessions install their trees as subviews of this root; see
        // `SpaceSessionController.presentInShell`.
        let root = NSView(frame: NSRect(origin: .zero, size: contentRect.size))
        root.wantsLayer = true
        root.autoresizesSubviews = true
        window.contentView = root
        window.shellController = self
        window.delegate = self
        if frame != nil {
            window.setFrame(contentRect, display: false)
        }
    }

    private static func defaultFrame() -> NSRect {
        let size = defaultContentSize
        guard let screen = NSScreen.main else {
            return NSRect(origin: .zero, size: size)
        }
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        )
        return NSRect(origin: origin, size: size)
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
    }

    /// Closes the shell for good. Only the slot calls this, after its
    /// sessions have drained.
    func closeForTeardown() {
        allowsClose = true
        window.delegate = nil
        window.close()
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if allowsClose { return true }
        guard let slot else { return true }
        // A user close of the shell is a window-driven close of the whole
        // slot: every session is closed through Chromium first, and the shell
        // goes once the last one is gone.
        return slot.shellRequestedClose()
    }

    func windowWillClose(_ notification: Notification) {
        slot?.shellDidClose()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        SpaceSessionControllersManager.shared.noteWindowBecameKey(window)
        slot?.shellDidBecomeKey()
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        slot?.shellFullScreenWillChange(isFullScreen: true)
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        slot?.shellFullScreenWillChange(isFullScreen: false)
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        slot?.shellFullScreenDidSettle()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        slot?.shellFullScreenDidSettle()
    }

    func windowDidResize(_ notification: Notification) {
        slot?.shellFrameDidChange()
    }

    func windowDidMove(_ notification: Notification) {
        slot?.shellFrameDidChange()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        slot?.shellDidDeminiaturize()
    }
}

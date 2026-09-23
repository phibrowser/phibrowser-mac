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
    /// command pipeline. Set by `SpaceSessionController.presentInShell`; nil
    /// while a dormant session is presented ahead of its Browser.
    weak var commandTargetWindow: NSWindow? {
        didSet { replayPendingCommands() }
    }

    /// The controller that owns this window (sessions reach the shell's
    /// window-level state, such as the traffic-light positioner, through it).
    weak var shellController: ShellWindowController?

    /// Commands dispatched while the presented session had no Chromium window
    /// yet (a dormant session presented ahead of its spawn). Replayed on the
    /// window that arrives, so ⌘T/⌘W pressed right after a cold switch are
    /// not lost. Bounded: a burst beyond this is more likely a stuck key.
    private var pendingCommands: [(sessionId: Int, selector: Selector, sender: Any?)] = []
    private static let pendingCommandLimit = 8

    /// True while the presented session is waiting for its Browser.
    private var presentedSessionIsDormant: Bool {
        (windowController as? SpaceSessionController)?.isDormant == true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    @objc func commandDispatch(_ sender: Any?) {
        forwardCommand(#selector(ShellWindow.commandDispatch(_:)), sender: sender)
    }

    @objc func commandDispatchUsingKeyModifiers(_ sender: Any?) {
        forwardCommand(#selector(ShellWindow.commandDispatchUsingKeyModifiers(_:)), sender: sender)
    }

    private func forwardCommand(_ selector: Selector, sender: Any?) {
        guard let target = commandTargetWindow else {
            if let session = windowController as? SpaceSessionController,
               session.isDormant, pendingCommands.count < Self.pendingCommandLimit,
               !Self.isRepeatedNewTabOrWindow(sender) {
                pendingCommands.append((session.windowId, selector, sender))
            }
            return
        }
        guard target.responds(to: selector) else { return }
        _ = target.perform(selector, with: sender)
    }

    /// Chromium drops an autorepeated New Tab/Window before dispatch; a
    /// dormant session has no Browser to run that pass, so the menu path
    /// applies the same rule before a repeat is queued.
    private static func isRepeatedNewTabOrWindow(_ sender: Any?) -> Bool {
        // `isARepeat` asserts on anything but a key event, and the menu path
        // also runs from mouse clicks, scripted dispatch and no event at all.
        guard let event = NSApp.currentEvent, event.type == .keyDown || event.type == .keyUp,
              event.isARepeat, let item = sender as? NSMenuItem else { return false }
        return [CommandWrapper.IDC_NEW_TAB, .IDC_NEW_WINDOW, .IDC_NEW_INCOGNITO_WINDOW]
            .contains { $0.rawValue == item.tag }
    }

    private func replayPendingCommands() {
        guard let target = commandTargetWindow,
              let session = windowController as? SpaceSessionController,
              !pendingCommands.isEmpty else { return }
        let sessionId = session.windowId
        let commands = pendingCommands.filter { $0.sessionId == sessionId }
        pendingCommands.removeAll()
        // One turn later: the spawn that attached the window seeds the
        // Space's first tab synchronously after `createBrowser` returns, and
        // the replayed commands belong after that tab.
        DispatchQueue.main.async { [weak self, weak target, weak session] in
            guard let self, let target, let session else { return }
            for command in commands {
                // A previous command can close or switch the session too.
                guard self.windowController === session,
                      self.commandTargetWindow === target else { return }
                guard target.responds(to: command.selector) else { continue }
                _ = target.perform(command.selector, with: command.sender)
            }
        }
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        guard item.action == #selector(ShellWindow.commandDispatch(_:))
                || item.action == #selector(ShellWindow.commandDispatchUsingKeyModifiers(_:)) else {
            return super.validateUserInterfaceItem(item)
        }
        guard let target = commandTargetWindow else {
            // A dormant session's Browser is ~150 ms away; keep the items
            // usable and queue what is chosen.
            return presentedSessionIsDormant
        }
        return target.validateUserInterfaceItem(item)
    }

    // MARK: - Child-window key status

    /// Whether the key window is a child of this shell: the omnibox host
    /// panel, the peek and reader panels, and — in hosted mode — every child
    /// window Chromium attaches here for the presented browser (find bar,
    /// permission bubble, dialogs). The chain is a finite acyclic AppKit
    /// window hierarchy, so the walk terminates.
    var childWindowIsKey: Bool {
        guard let key = NSApp.keyWindow, key !== self else { return false }
        return isAncestor(of: key)
    }

    /// Whether `window` is one of this shell's descendants (see
    /// `childWindowIsKey` for what those are).
    func isAncestor(of window: NSWindow) -> Bool {
        var ancestor = window.parent
        while let current = ancestor {
            if current === self { return true }
            ancestor = current.parent
        }
        return false
    }

    /// The shell and its descendants as one key-owning group: what a real
    /// browser window is to Chromium, which keeps painting a window active
    /// while one of its child widgets has focus.
    var groupOwnsKey: Bool {
        isKeyWindow || childWindowIsKey
    }

    /// The key-reclaim rule the Chromium browser window carried for adopted
    /// windows (`BrowserNativeWidgetWindow`, remote_cocoa): AppKit's
    /// `makeFirstResponder:` makes the receiving window key as a side effect
    /// when it is not, which would steal key from an open child window and
    /// break keyboard input in it. Block the call while a child is key;
    /// intentional interactions (a click, a shortcut) reclaim key explicitly
    /// in `sendEvent` first.
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if childWindowIsKey { return false }
        return super.makeFirstResponder(responder)
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
        switch event.type {
        case .keyDown:
            // AppKit does not run performKeyEquivalent for Option-only keys;
            // Chromium treats them as key equivalents (extension commands
            // run before the page). A Chromium window synthesises that pass
            // in its own sendEvent, so the shell does the same.
            let modifiers = event.modifierFlags.intersection([.command, .control, .option])
            if modifiers == [.option], performKeyEquivalent(with: event) {
                return
            }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // macOS does not hand key back from a child window to its parent
            // on a click. Reclaim it before dispatch so the
            // `makeFirstResponder` guard does not swallow the click and tabs,
            // sidebar and page handle it at once instead of on a second try.
            if childWindowIsKey {
                makeKey()
            }
        default:
            break
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
        if event.modifierFlags.contains(.command) {
            // Chromium's command dispatcher refreshes the Close Tab/Close
            // Window menu roles before matching shortcuts. The shell's
            // NSWindow path skips that dispatcher, so refresh through the
            // existing menu owner before AppKit matches the event.
            if let fileMenu = NSApp.mainMenu?.items.first(where: {
                ChromiumMainMenuRole(tag: $0.tag) == .file
            })?.submenu {
                fileMenu.delegate?.menuNeedsUpdate?(fileMenu)
            }
            // Mirror PhiCommandDispatcherDelegate's placeholder handling:
            // its WebContents consumes command equivalents without replaying
            // them. Let AppKit run the menu action instead (Cmd+W becomes
            // Close Window when no tabs remain). Plain keys still reach the
            // placeholder page.
            if (windowController as? SpaceSessionController)?.browserState.isInPlaceholderMode == true {
                return false
            }
        }
        // Chromium reserves browser commands and checks extension accelerators
        // before web content. Run only that first pass on the backing browser;
        // AppKit still sends unhandled shortcuts to the real responder here.
        guard let session = windowController as? SpaceSessionController else {
            return super.performKeyEquivalent(with: event)
        }
        switch session.preHandleKeyEquivalent(event) {
        case .handled: return true
        case .passToMainMenu: return false
        case .unhandled: break
        @unknown default: break
        }
        if super.performKeyEquivalent(with: event) {
            return true
        }
        // A native responder (sidebar search, address field) declined the
        // key: the pass a Chromium window runs after its view hierarchy,
        // which executes non-menu browser commands. Web content never gets
        // here: it claims the key and redispatches through `redispatchTarget`.
        switch session.postHandleKeyEquivalent(event) {
        case .handled: return true
        case .passToMainMenu, .unhandled: return false
        @unknown default: return false
        }
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

    /// The sidebar | content split this window owns across every Space it
    /// presents.
    private(set) var split: ShellSplitViewController!

    /// Set by the slot once its sessions have drained, so the pending close
    /// that `windowShouldClose` refused can go through.
    var allowsClose = false

    /// The one traffic-light positioner of this window. Sessions come and go
    /// inside the shell; the lights belong to the window and must not move
    /// on a Space switch, so the positioner is rebuilt only when the layout
    /// mode changes (or dropped for fullscreen), never per session.
    private var trafficLightPositioner: TrafficLightPositioner?
    private var trafficLightLayoutMode: LayoutMode?

    /// Whether the shell's key group (`ShellWindow.groupOwnsKey`) owned key
    /// at the last reconcile — the state Chromium was last told.
    private var groupOwnedKey = false
    private var keyGroupReconcileScheduled = false
    private var keyStatusObservers: [NSObjectProtocol] = []

    /// Key ownership is tracked for the shell and its descendants as one
    /// group, from AppKit's key notifications for any window in it. The
    /// shell's own delegate callbacks are not enough: the reader and peek
    /// panels, the omnibox host and every child window Chromium parents
    /// here are windows of their own, so key leaving one of THEM for another
    /// shell, a standalone Incognito or Kiosk window or another app — or
    /// coming straight back into one — never passes through the shell.
    ///
    /// Decided one turn after the notification, once AppKit has made the
    /// next window key; only a change of the group's ownership is forwarded,
    /// so key moving within the group (shell to find bar, panel to shell) is
    /// silent, as it is for a real browser window and its child widgets.
    private func observeKeyStatusChanges() {
        let center = NotificationCenter.default
        keyStatusObservers = [NSWindow.didBecomeKeyNotification,
                              NSWindow.didResignKeyNotification].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let self, let changed = notification.object as? NSWindow,
                      changed === self.window || self.window.isAncestor(of: changed) else { return }
                MainActor.assumeIsolated { self.scheduleKeyGroupReconcile() }
            }
        }
    }

    @MainActor
    private func scheduleKeyGroupReconcile() {
        guard !keyGroupReconcileScheduled else { return }
        keyGroupReconcileScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.keyGroupReconcileScheduled = false
            self.reconcileKeyGroup()
        }
    }

    @MainActor
    private func reconcileKeyGroup() {
        let ownsKey = window.groupOwnsKey
        guard ownsKey != groupOwnedKey else { return }
        groupOwnedKey = ownsKey
        if ownsKey {
            // Key came back through a child window (a reader or peek panel
            // clicked directly), so the shell's own become-key path did not
            // run: the native active-controller bookkeeping that menu
            // actions read (Toggle Sidebar, Bookmark This Tab) has to move
            // to this shell's presented session here as well.
            AppLogDebug("[ShellWindow] key regained through child window: \(NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "nil")")
            SpaceSessionControllersManager.shared.noteWindowBecameKey(window)
            slot?.shellGroupDidGainKey()
        } else {
            AppLogDebug("[ShellWindow] key left the shell group for: \(NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "nil")")
            slot?.shellDidResignKey()
        }
    }

    deinit {
        for observer in keyStatusObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

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
        // The window's one split — sidebar column | page area — which every
        // presented session contributes its views to; see
        // `SpaceSessionController.presentInShell`.
        split = ShellSplitViewController()
        // Sized before it becomes the content view controller: AppKit takes
        // the window's content size from the controller's view.
        split.view.frame = NSRect(origin: .zero, size: contentRect.size)
        window.contentViewController = split
        window.shellController = self
        window.delegate = self
        if frame != nil {
            window.setFrame(contentRect, display: false)
        }
        observeKeyStatusChanges()
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
        // The shell itself becoming key re-presents (and so activates) the
        // session synchronously; the group observer then has nothing to add.
        groupOwnedKey = true
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

    /// A will-enter that never lands: AppKit cancels or fails the transition
    /// without a will-exit, so the state the will-enter promised is settled
    /// here from the window's actual style mask.
    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        slot?.shellFullScreenDidFail()
    }

    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        slot?.shellFullScreenDidFail()
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

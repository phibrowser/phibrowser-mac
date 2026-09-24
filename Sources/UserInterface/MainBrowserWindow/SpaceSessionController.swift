// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Combine
import SnapKit
import SwiftUI
class SpaceSessionController: NSWindowController {
    static let defaultWindowSize = NSSize(width: 1280, height: 860)
    
    let mainSplitViewController: MainSplitViewController
    
    let account: Account
    let browserType: ChromiumBrowserType
    let profileId: String
    let spaceId: String
    /// The window-group this controller belongs to. Set by the caller
    /// (`PhiChromiumCoordinator.mainBrowserWindowCreated`,
    /// `SpaceSessionControllersManager.processDanglingWindow`) right
    /// after construction. Weak so the controller doesn't pin a slot the
    /// manager has already dropped from its registry.
    weak var slot: SpaceWindowSlot?

    /// Hosted-window mode (`SpaceManager.isHostedWindowMode`): the hidden
    /// Chromium window whose Browser backs this session. `window` is then the
    /// slot's shared `ShellWindow`, which every session of the slot presents
    /// into in turn. nil in legacy mode, where `window` IS the Chromium window.
    private(set) var hostedChromiumWindow: NSWindow?
    /// Hosted mode: a session built ahead of its Browser. The slot creates
    /// one per Space it presents, keyed by a window id reserved from
    /// Chromium's session-id generator, so the Swift side of the Space —
    /// sidebar, pinned tabs, bookmarks, strip — exists before the Space is
    /// first visited. The first switch spawns the Browser under that id and
    /// `attachChromiumWindow` turns this into an ordinary hosted session.
    private(set) var isDormant = false
    var isHosted: Bool { hostedChromiumWindow != nil || isDormant }
    /// The window whose close ends this controller's life: the Chromium window
    /// in hosted mode (the shell outlives its sessions), `window` otherwise.
    /// A dormant session has none yet.
    var lifecycleWindow: NSWindow? {
        if isDormant { return nil }
        return hostedChromiumWindow ?? window
    }
    /// Hosted mode: whether this session's split view is installed in the
    /// shell right now.
    private(set) var isPresented = false
    /// True when the user sees this controller's content through `window`:
    /// always in legacy mode, only while presented in hosted mode. Gates every
    /// window-level side effect (panels, traffic lights, overlays) that a
    /// background session of the shared shell must not perform.
    var isPresentedOrLegacy: Bool { !isHosted || isPresented }
    
    var omniBoxContainerViewController: OmniBoxContainerViewController?
    
    var searchTabsContainerViewController: SearchTabsContainerViewController?
    
    private lazy var toastContainerViewController: OverlayToastViewController = {
        return OverlayToastViewController(state: browserState)
    }()

    private lazy var imagePreviewOverlayViewController: ImagePreviewOverlayViewController = {
        ImagePreviewOverlayViewController(state: browserState.imagePreviewState)
    }()

    /// Window-scoped Library view, created on first use.
    private var libraryOverlayController: LibraryOverlayController?
    private var libraryWindowController: LibraryWindowController?

    func openLibraryInNewWindow(section: LibraryViewModule.Section? = nil) {
        guard let window else { return }
        libraryOverlayController?.dismiss(animated: false)
        if libraryWindowController == nil {
            libraryWindowController = LibraryWindowController(parent: window, browserState: browserState)
        }
        libraryWindowController?.present(section: section)
    }

    func showLibrary(from source: NSView, section: LibraryViewModule.Section? = nil) {
        guard let window, source.window === window else { return }
        if libraryOverlayController == nil {
            libraryOverlayController = LibraryOverlayController(parent: window, browserState: browserState)
        }
        libraryOverlayController?.show(from: source, section: section)
    }

    @discardableResult
    func dismissLibraryIfVisible() -> Bool {
        guard libraryOverlayController?.isVisible == true else { return false }
        libraryOverlayController?.dismiss()
        return true
    }

    /// Peek popup panel, created on first present. Exposed to the
    /// coordinator (`tabWillBeRemove`) for the synchronous view detach.
    private var peekPanelController: PeekPanelController?
    var peekPanelControllerIfLoaded: PeekPanelController? { peekPanelController }
    /// Feeds the peek panel's appear flight. Lives here rather than in the
    /// panel controller because it has to be recording before the first peek
    /// opens — which is when that controller is built.
    private var peekOriginTracker: PeekOriginTracker?
    /// Peek tab id per opener as of the previous `peeksByOpener` emission.
    /// What makes "the user just opened this peek" decidable: mounting
    /// content in the panel happens both for a fresh peek and for switching
    /// to another opener's existing one, and only the first may fly.
    private var previousPeekTabIdsByOpener: [Int: Int] = [:]
    /// Focused tab id as of the previous emission, so a focus change can
    /// invalidate a recorded press before it funds an unrelated peek.
    private var lastFocusedTabIdForPeek: Int?

    /// Reader View overlay panel, created on first present. Exposed to the
    /// coordinator (`tabWillBeRemove`) for the synchronous view detach.
    private var readerPanelController: ReaderPanelController?
    var readerPanelControllerIfLoaded: ReaderPanelController? { readerPanelController }

    /// Child window hosting the omnibox overlay ABOVE the peek/reader
    /// panels: those are child windows themselves, and a child window draws
    /// above every in-window view — an in-window omnibox would be covered by
    /// them. It stays in the browser window's own level so it keeps the
    /// window's place in the inter-app stacking order (any level above
    /// `.normal` would leave it floating over other apps once ours
    /// deactivates); the ordering above the peek/reader panels comes from
    /// sibling order among the children instead. Created on first use, and
    /// taken off screen again when the overlay dismisses.
    private(set) var omniBoxHostPanel: NSPanel?
    private var omniBoxHostResizeObserver: NSObjectProtocol?

    var centeredOmniBoxHorizontalInset: CGFloat { 0 }

    private final class KeyableOverlayPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    /// Returns the omnibox host panel attached to this window, sized to its
    /// content area and accepting events, creating it on first use.
    @discardableResult
    func attachAndShowOmniBoxHostPanel() -> NSPanel? {
        guard let window = self.window else { return nil }
        if omniBoxHostPanel == nil {
            let panel = KeyableOverlayPanel(
                contentRect: .zero,
                styleMask: [.borderless, .fullSizeContentView],
                backing: .buffered,
                defer: true
            )
            panel.isOpaque = false
            panel.hasShadow = false
            panel.backgroundColor = .clear
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.contentView = NSView()
            omniBoxHostPanel = panel
            // Child windows do not follow parent resizes on their own.
            omniBoxHostResizeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.syncOmniBoxHostPanelFrame()
            }
        }
        guard let panel = omniBoxHostPanel else { return nil }
        // Keep system text, selection, and caret colors aligned with the owning window.
        panel.appearanceSource = window
        // Share the browser window's level so the pair moves through the
        // inter-app window order as one — the overlay must never outlive our
        // activation on top of another app's windows.
        panel.level = window.level
        if panel.parent == nil {
            // Re-attaching on every show lands the host above the peek and
            // reader panels, the siblings it has to cover.
            window.addChildWindow(panel, ordered: .above)
        }
        panel.ignoresMouseEvents = false
        syncOmniBoxHostPanelFrame()
        panel.makeKeyAndOrderFront(nil)
        return panel
    }

    /// Takes the emptied host panel off screen once the overlay has detached
    /// its content, so a dismissed omnibox leaves no window behind.
    private func retireOmniBoxHostPanelIfIdle() {
        guard let panel = omniBoxHostPanel,
              omniBoxContainerViewController?.hasShown != true else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func syncOmniBoxHostPanelFrame() {
        guard let window = self.window,
              let panel = omniBoxHostPanel,
              let contentView = window.contentView else { return }
        let inWindow = contentView.convert(contentView.bounds, to: nil)
        panel.setFrame(window.convertToScreen(inWindow), display: true)
    }
    
    lazy var omnibackgroundView: EventBlockBgView = {
       return EventBlockBgView()
    }()

    lazy var searchTabsBackgroundView: EventBlockBgView = {
        EventBlockBgView()
    }()
    
    private var originalContentView: NSView?
    /// Holds the native traffic lights on the chrome row beside them;
    /// see `updateTrafficLightPlacement(fullScreen:)`.
    private var trafficLightPositioner: TrafficLightPositioner?
    /// The layout the live positioner was built for, so the titlebar is
    /// only handed back and re-shifted when the layout actually changes.
    private var trafficLightLayoutMode: LayoutMode?
    private var kioskContentViewController: KioskBrowserContentViewController?
    lazy var cancellables = Set<AnyCancellable>()
    private var multiSelectionEscapeMonitor: Any?
    private(set) var windowId = 0
    @Published private(set) var browserState: BrowserState
    var tabStripView: TabStrip? {
        guard !browserState.isKioskWindow else { return nil }
        return mainSplitViewController.webContentContainerViewController.tabStripView
    }
    
    required init?(coder: NSCoder) {
        fatalError("not support")
    }
    
    init(window: NSWindow,
         windowId: Int,
         browserType: ChromiumBrowserType = .normal,
         profileId: String = LocalStore.defaultProfileId,
         spaceId: String = SpaceManager.shared.currentDefaultSpaceId,
         account: Account = AccountController.shared.account ?? AccountController.defaultAccount,
         slot: SpaceWindowSlot? = nil,
         browserState suppliedBrowserState: BrowserState? = nil,
         chromiumWindow: NSWindow? = nil,
         dormant: Bool = false,
         prewarmedContent: MainSplitViewController? = nil) {
        self.hostedChromiumWindow = chromiumWindow
        self.isDormant = dormant && chromiumWindow == nil
        let state = suppliedBrowserState ?? BrowserState(
            windowId: windowId,
            localStore: account.localStorage,
            profileId: profileId,
            spaceId: spaceId,
            isIncognito: browserType == .incognito
                || browserType == .incognitoSpace
                || browserType == .kioskIncognito,
            isIncognitoSpace: browserType == .incognitoSpace,
            isAgentSpace: browserType == .agentSpace
        )
        self.browserState = state
        self.windowId = windowId
        self.account = account
        self.browserType = browserType
        self.profileId = profileId
        self.spaceId = spaceId
        // Adopt the Space's persisted theme BEFORE any view reads the theme
        // context: the register-time apply below runs after the view
        // hierarchy is built, and its corrective update is deferred behind a
        // busy main queue during session restore — the restored window's
        // first paint would show the default theme and repaint later. No-op
        // for Spaces without persisted customization (shared mirroring stays
        // as configured) and for incognito windows, whose fixed incognito
        // theme must survive the real Space id they are created with.
        SpaceManager.shared.seedPersistedTheme(into: state, spaceId: spaceId)
        assert(prewarmedContent == nil || (dormant && prewarmedContent?.state === state))
        self.mainSplitViewController = prewarmedContent ?? MainSplitViewController(
            state: state,
            hosted: chromiumWindow != nil || (dormant && chromiumWindow == nil))
        super.init(window: window)
        self.slot = slot
        browserState.windowController = self
        if isDormant {
            // The Browser-bound wiring waits for `attachChromiumWindow`.
            setupHostedSession()
            installMultiSelectionEscapeMonitor()
            SpaceSessionControllersManager.shared.retainDormantSession(self)
            slot?.registerDormantSession(self, for: spaceId)
            // `NSWindowController.init(window:)` made this dormant session the
            // shell's window controller; the responder chain, menu validation
            // and `NSView.unsafeBrowserWindowController` must keep pointing
            // at the presented session (same repair as `registerHostedSession`
            // does for a live background session).
            if let visible = slot?.visibleController, visible !== self {
                window.windowController = visible
            }
            return
        }
        // The shell is bound before the mouse-down ownership is set: the
        // page view reads the flag off the window that contains it, which in
        // hosted mode is the shell, and the bridge mirrors the flag onto the
        // shell only once it knows which shell that is.
        if isHosted {
            Self.setPresentationHostIfSupported(window, windowId: windowId)
        }
        ChromiumLauncher.sharedInstance().bridge?
            .setWebContentsOwnsMouseDown(
                true,
                windowId: Int64(windowId)
            )
        if isHosted {
            setupHostedSession()
        } else {
            setupWindow()
        }
        installMultiSelectionEscapeMonitor()
        SpaceSessionControllersManager.shared.retainWindowControllerUntilWindowClosed(self)
        // Normal, Incognito Space, and agent-Space windows participate in the
        // Space mapping; standalone incognito and shadow windows are orthogonal
        // to Spaces. Agent-Space windows are hidden TYPE_NORMAL windows the user
        // can switch to, so they must register too — otherwise the Space has no
        // `windowsBySpaceId[spaceId]` entry, its seed tab is never created, and
        // surfacing the pip shows an empty Space even though the Chromium window
        // has live tabs. The slot was resolved by the caller
        // (PhiChromiumCoordinator / SpaceSessionControllersManager), which
        // treats `.normal`, `.incognitoSpace`, and `.agentSpace` identically.
        if browserType == .normal || browserType == .incognitoSpace || browserType == .agentSpace {
            slot?.registerWindow(self, for: spaceId)
        }

        NotificationCenter.default.post(name: .mainBrowserWindowCreated, object: window)
    }

    deinit {
        removeMultiSelectionEscapeMonitor()
    }
    
    override var windowNibName: NSNib.Name? { "" }

    private func installMultiSelectionEscapeMonitor() {
        guard multiSelectionEscapeMonitor == nil else { return }
        multiSelectionEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self, let window = self.window, self.isPresentedOrLegacy else { return event }
            return Self.handleMultiSelectionEscape(
                event,
                in: window,
                browserState: self.browserState
            )
        }
    }

    private func removeMultiSelectionEscapeMonitor() {
        guard let multiSelectionEscapeMonitor else { return }
        NSEvent.removeMonitor(multiSelectionEscapeMonitor)
        self.multiSelectionEscapeMonitor = nil
    }

    @MainActor
    static func handleMultiSelectionEscape(
        _ event: NSEvent,
        in window: NSWindow,
        browserState: BrowserState
    ) -> NSEvent? {
        if event.type == .keyDown,
           event.window === window,
           SpaceSessionControllersManager.shared
            .isGuestTransitionInteractionBlocked {
            let modifiers = event.modifierFlags.intersection([
                .command,
                .option,
                .shift,
                .control,
            ])
            if modifiers == [.command],
               event.charactersIgnoringModifiers?.lowercased() == "q" {
                return event
            }
            return nil
        }

        guard event.type == .keyDown,
              event.keyCode == 53,
              event.window === window,
              browserState.multiSelection.isActive else {
            return event
        }
        browserState.clearMultiSelection()
        return nil
    }
    
    /// Hosted-mode counterpart of `setupWindow()`. The shell is dressed by
    /// `ShellWindowController`; this session only wires what is its own —
    /// teardown on ITS Chromium window's close, theme following while
    /// presented, and the content tree, which `presentInShell()` installs.
    private func setupHostedSession() {
        observeChromiumWindowClose()
        browserState.themeContext.themeAppearancePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                guard let self, self.isPresented, let window = self.window else { return }
                self.applyThemeAppearance(to: window)
            }
            .store(in: &cancellables)
        WindowThemeMessageRouter.shared.observeWindow(browserState)
        NotificationCenter.default.publisher(for: .appearanceDidChange, object: ThemeManager.shared)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.isPresented, let window = self.window else { return }
                guard self.browserState.themeContext.hasFixedWindowAppearance else { return }
                self.applyThemeAppearance(to: window)
            }
            .store(in: &cancellables)
        setupContentView()
        observeBlockingOverlayVisibility()
    }

    private func observeChromiumWindowClose() {
        guard let chromiumWindow = hostedChromiumWindow else { return }
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(myWindowWillClose(_:)),
                                               name: NSWindow.willCloseNotification,
                                               object: chromiumWindow)
    }

    /// Builds and hosts the dormant session's tree hidden, so a first switch
    /// into its Space has nothing left to construct or attach. `presentInShell` would
    /// otherwise load it on the switch.
    func warmUpDormantTree() {
        guard isDormant else { return }
        mainSplitViewController.loadViewIfNeeded()
        mainSplitViewController.adoptAutosavedSplitPositionNow()
        if let bounds = window?.contentView?.bounds {
            mainSplitViewController.view.frame = NSRect(origin: .zero, size: bounds.size)
        }
        mainSplitViewController.view.layoutSubtreeIfNeeded()
        hostSidebarViewInShell()
        SpaceBandSnapshotCache.shared.prefetch(spaceId: spaceId,
                                               appearanceOf: mainSplitViewController.sidebarViewController.view)
    }

    /// The Browser spawned under this dormant session's reserved window id
    /// has arrived: `chromiumWindow` is its hidden NSWindow. Wires everything
    /// `init` skipped for a dormant session and registers with the slot as a
    /// live hosted session. If the session is presented already (the switch
    /// showed it ahead of the spawn), Chromium learns that now.
    func attachChromiumWindow(_ chromiumWindow: NSWindow) {
        guard isDormant, hostedChromiumWindow == nil, let window = self.window else { return }
        isDormant = false
        hostedChromiumWindow = chromiumWindow
        // Shell first, then the flag it mirrors — as in `init`.
        Self.setPresentationHostIfSupported(window, windowId: windowId)
        ChromiumLauncher.sharedInstance().bridge?
            .setWebContentsOwnsMouseDown(true, windowId: Int64(windowId))
        observeChromiumWindowClose()
        SpaceSessionControllersManager.shared.noteChromiumWindowAttached(self)
        if isPresented {
            (window as? ShellWindow)?.commandTargetWindow = chromiumWindow
            mirrorFrameToChromiumWindow()
            pushPresentedToChromium(true)
            pushShellFullscreenToChromium(window.styleMask.contains(.fullScreen))
        }
        if browserType == .normal || browserType == .incognitoSpace || browserType == .agentSpace {
            slot?.registerWindow(self, for: spaceId)
        }
        NotificationCenter.default.post(name: .mainBrowserWindowCreated, object: window)
        replayPendingBrowserCalls()
    }

    /// Tab-opening bridge calls made while this session is dormant. Chromium
    /// has no Browser under the reserved window id yet and would open the URL
    /// in a new window of the last-used profile instead, so they wait for
    /// `attachChromiumWindow`. Bounded, like the shell's command queue.
    private var pendingBrowserCalls: [() -> Void] = []
    private static let pendingBrowserCallLimit = 8

    /// Runs `call` now, or once the Browser arrives if the session is dormant.
    func performWithBrowser(_ call: @escaping () -> Void) {
        guard isDormant else {
            call()
            return
        }
        guard pendingBrowserCalls.count < Self.pendingBrowserCallLimit else {
            AppLogWarn("[SpaceSessionController] dropping a bridge call for dormant session \(windowId): queue full")
            return
        }
        pendingBrowserCalls.append(call)
    }

    private func replayPendingBrowserCalls() {
        guard !pendingBrowserCalls.isEmpty else { return }
        let calls = pendingBrowserCalls
        pendingBrowserCalls.removeAll()
        // One turn later: the spawn seeds the Space's first tab synchronously
        // after `createBrowser` returns, and the queued tabs belong after it.
        DispatchQueue.main.async {
            calls.forEach { $0() }
        }
    }

    /// Drops a dormant session that will never get a Browser: its Space left
    /// the slot, its profile changed, or the slot closed. A live session is
    /// retired through its Chromium window's close instead.
    func discardDormant() {
        guard isDormant else { return }
        pendingBrowserCalls.removeAll()
        leaveShell()
        removeMultiSelectionEscapeMonitor()
        cancellables.removeAll()
        WindowThemeMessageRouter.shared.stopObservingWindow(windowId: windowId)
        SpaceSessionControllersManager.shared.releaseDormantSession(self)
    }

    private func setupWindow() {
        guard let window = self.window else { return }
        
        window.contentView?.removeFromSuperview()
        
        originalContentView = window.contentView
        
        window.backgroundColor = NSColor.windowBackgroundColor
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.animationBehavior = .none
        // Do NOT let AppKit secure-state restoration bring these windows back in
        // fullscreen. On a slot that owned several Space windows in one
        // fullscreen Space at quit, AppKit re-applies the persisted `.fullScreen`
        // styleMask per window on cold launch; combined with Chromium's own
        // session restore recreating the windows, that leaves an orphaned, empty
        // fullscreen Space (the blank desktop in Mission Control). Chromium owns
        // session restore (tabs/content) and `SpaceWindowSlot` owns frame/Space
        // continuity, so AppKit window restoration is redundant here — turning it
        // off makes restored windows come back as normal windows.
        window.isRestorable = false
        //        window.delegate = self
        // No frame autosave name. Chromium owns window placement (CreateParams
        // override bounds / WindowSizer / saved-placement prefs /
        // --window-size/--window-position), and a shared "mainBrowserWindow"
        // autosave slot would clobber that for every windows.create window:
        // AppKit re-applies one window's saved frame to sister windows when
        // they're shown — including across the hidden-then-surfaced Space-switch
        // swap, which makes the window jump to the last position any sibling was
        // dragged to. Frame continuity across Space switches is instead owned by
        // `SpaceWindowSlot` (inheritedFrame in `activate`, `pendingFrameByWindowId`
        // in the spawn path). The not-logged-in/dangling window is hidden then
        // force-sized on restore, so it never depended on this autosave either.
        let frameToRestore = window.frame
        // Pin the window's appearance before the content tree exists, so the
        // split view's first layout already resolves against the final theme
        // instead of repainting once the theme lands (same reasoning as the
        // `seedPersistedTheme` call in `init`). Only the window and the
        // outgoing Chromium content view are reachable here: the guards inside
        // stop this call from force-loading the split view, so the tree is
        // built by `setupContentView()` below instead of as a side effect of
        // setting an appearance. `MainSplitViewController.viewDidLoad`
        // therefore runs after the observers registered below — safe, because
        // none of them fire during this function and `viewDidLoad` neither
        // mutates `browserState` nor posts notifications.
        applyThemeAppearance(to: window)

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(myWindowWillEnterFullScreen),
                                               name: NSWindow.willEnterFullScreenNotification,
                                               object: window)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(myWindowWillExitFullScreen),
                                               name: NSWindow.willExitFullScreenNotification,
                                               object: window)
        // The will-hooks above flip the slot's fullscreen flag optimistically;
        // a transition can settle differently than promised (a failed or
        // cancelled enter fires neither did-enter nor will-exit). At did-time
        // the styleMask is authoritative — let the slot re-derive from it.
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(myWindowDidEnterFullScreen),
                                               name: NSWindow.didEnterFullScreenNotification,
                                               object: window)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(myWindowDidExitFullScreen),
                                               name: NSWindow.didExitFullScreenNotification,
                                               object: window)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(myWindowWillClose(_:)),
                                               name: NSWindow.willCloseNotification,
                                               object: window)
        // A window created minimized never runs its content view-appearance
        // lifecycle; restore it when the window is deminiaturized from the Dock.
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleWindowDidDeminiaturize(_:)),
                                               name: NSWindow.didDeminiaturizeNotification,
                                               object: window)
        browserState.themeContext.themeAppearancePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                guard let self, let window = self.window else { return }
                self.applyThemeAppearance(to: window)
            }
            .store(in: &cancellables)
        WindowThemeMessageRouter.shared.observeWindow(browserState)
        NotificationCenter.default.publisher(for: .appearanceDidChange, object: ThemeManager.shared)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, let window = self.window else { return }
                guard self.browserState.themeContext.hasFixedWindowAppearance else { return }
                self.applyThemeAppearance(to: window)
            }
            .store(in: &cancellables)
        setupContentView()
        observeBlockingOverlayVisibility()
        // Not a repeat of the call above: that one ran before the split view
        // existed, so this is the only one that reaches the content tree.
        applyThemeAppearance(to: window)
        window.setFrame(frameToRestore, display: true)
    }

    /// A window created minimized never runs its content view-appearance
    /// lifecycle (AppKit doesn't run appearance for a Dock/off-screen window),
    /// and deminiaturizing doesn't re-trigger it — leaving the restored window
    /// blank. Drive the content setup now that the window is visible again.
    @objc private func handleWindowDidDeminiaturize(_ note: Notification) {
        guard !browserState.isKioskWindow else { return }
        mainSplitViewController.phiHandleRestoreFromMinimized()
    }

    /// Applies the window's theme appearance without dragging the content view
    /// hierarchy into existence.
    ///
    /// Reading `.view` on a not-yet-loaded `NSViewController` forces
    /// `loadView`/`viewDidLoad`. Without the `isViewLoaded` guards below, the
    /// first call from `setupWindow()` pulled the whole split-view tree
    /// (sidebar, split items, web content container) into window
    /// initialization purely to assign an appearance — and in the default
    /// "follow the system" case the value being assigned is `nil`.
    ///
    /// Because of those guards, an appearance change that arrives while the
    /// views are unloaded is **dropped, not queued**. Any code that defers
    /// building the hierarchy must therefore re-run a full
    /// `applyThemeAppearance(to:)` once it materializes the views, or the
    /// window shows up wearing the theme it had when it was deferred.
    private func applyThemeAppearance(to window: NSWindow) {
        let appearance = browserState.themeContext.windowAppearance
        window.appearance = appearance
        window.contentView?.appearance = appearance
        if let contentViewController, contentViewController.isViewLoaded {
            contentViewController.view.appearance = appearance
        }
        if mainSplitViewController.isViewLoaded {
            mainSplitViewController.view.appearance = appearance
            if isHosted {
                mainSplitViewController.sidebarViewController.view.appearance = appearance
                if !PhiPreferences.GeneralSettings.loadLayoutMode().isTraditional {
                    mainSplitViewController.floatingSidebarContent.view.appearance = appearance
                }
            }
        }
    }

    /// Hosted mode: pins this session's own trees (page tree, docked and
    /// floating sidebar content) to the appearance they draw in, resolved to
    /// a concrete one even when it follows the system. Those trees otherwise
    /// inherit the shell window's appearance, which is the presented
    /// session's and changes only when a slide lands (`applyWindowChrome`):
    /// during a switch between Spaces of different appearances — an
    /// Incognito Space is always dark — both trees drew in the leaving one's,
    /// and the entering Space flipped to its own after the landing. The
    /// landing's `applyThemeAppearance` hands them back to the window.
    func pinContentAppearanceForSwitch() {
        guard isHosted, mainSplitViewController.isViewLoaded else { return }
        let appearance = resolvedContentAppearance
        mainSplitViewController.view.appearance = appearance
        mainSplitViewController.sidebarViewController.view.appearance = appearance
        if !PhiPreferences.GeneralSettings.loadLayoutMode().isTraditional {
            mainSplitViewController.floatingSidebarContent.view.appearance = appearance
        }
    }

    /// The appearance this session's content draws in: its fixed window
    /// appearance, or the one the app currently resolves to.
    var resolvedContentAppearance: NSAppearance? {
        let context = browserState.themeContext
        return context.windowAppearance ?? context.currentAppearance.nsAppearance
    }
    
    private func setupContentView() {
        guard let _ = self.window else { return }

        if let kioskState = browserState as? KioskBrowserState {
            let controller = KioskBrowserContentViewController(state: kioskState)
            kioskContentViewController = controller
            contentViewController = controller
            window?.standardWindowButton(.closeButton)?.isHidden = false
            window?.standardWindowButton(.miniaturizeButton)?.isHidden = false
            window?.standardWindowButton(.zoomButton)?.isHidden = false
            return
        }
        
        if !isHosted {
            self.contentViewController = mainSplitViewController
        }
        
        $browserState.compactMap { $0 }
            .flatMap { state in
                state.sidebarCollapsedPublisher.combineLatest(
                    state.$isInFullScreenMode,
                    NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
                        .map { _ in }
                        .prepend(())
                )
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] collapsed, fullScreen, _ in
                guard let self, self.isPresentedOrLegacy else { return }
                self.applyTrafficLightVisibility(collapsed: collapsed, fullScreen: fullScreen)
            }
            .store(in: &cancellables)

        // Again, synchronously, because the sink above delivers on the main
        // queue: its first pass lands a turn after this window is built, and a
        // Space switched to cold builds and presents its window inside that
        // turn. The lights would be drawn once where AppKit put them and then
        // visibly step onto the row. A warm Space was placed long before it is
        // shown, which is why only a cold one shows the step. The layout guard
        // inside makes the sink's own first pass a no-op.
        if !isHosted {
            updateTrafficLightPlacement(
                fullScreen: browserState.isInFullScreenMode
            )
            self.contentViewController = mainSplitViewController
        }

        mainSplitViewController.addChild(toastContainerViewController)
        mainSplitViewController.view.addSubview(toastContainerViewController.view)
        toastContainerViewController.view.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        mainSplitViewController.addChild(imagePreviewOverlayViewController)
        mainSplitViewController.view.addSubview(imagePreviewOverlayViewController.view)
        imagePreviewOverlayViewController.view.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        // A peek's appear flight starts from the press that opened it, which
        // is long gone by the time the panel is built — start recording now.
        peekOriginTracker = PeekOriginTracker(
            paneViewController: mainSplitViewController.webContentContainerViewController
        )

        // Peek popup: each peek belongs to its opener tab, so the one panel
        // always shows the focused tab's peek — switching tabs swaps the
        // hosted content to the newly focused opener's peek, hides the panel
        // while the focused tab has none, and dismisses it only when no peek
        // is left in the window.
        $browserState
            .flatMap { state in
                state.peekState.$peeksByOpener
                    .combineLatest(state.$focusingTab)
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] peeksByOpener, focusingTab in
                guard let self else { return }
                let peekTabIds = peeksByOpener.mapValues { $0.guid }
                let previousPeekTabIds = self.previousPeekTabIdsByOpener
                self.previousPeekTabIdsByOpener = peekTabIds
                // A press funds only the peek it opened. The focused tab does
                // not change while a peek is created (the opener stays
                // focused), so a focus change means the recorded press and
                // whatever peek shows up next are unrelated — drop it, or a
                // peek revealed later flies out of an unrelated click.
                if focusingTab?.guid != self.lastFocusedTabIdForPeek {
                    self.lastFocusedTabIdForPeek = focusingTab?.guid
                    self.peekOriginTracker?.invalidate()
                }
                guard !peeksByOpener.isEmpty else {
                    self.peekPanelController?.dismiss()
                    return
                }
                if let focusingTab, let tab = peeksByOpener[focusingTab.guid] {
                    self.presentPeekPanel(
                        for: tab,
                        flyIn: Self.isFreshlyOpenedPeek(
                            previousPeekTabIdsByOpener: previousPeekTabIds,
                            openerTabId: focusingTab.guid,
                            peekTabId: tab.guid
                        )
                    )
                } else {
                    self.peekPanelController?.hide()
                }
            }
            .store(in: &cancellables)

        // Reader View overlay: each reader belongs to its origin tab, so the
        // one panel always shows the focused tab's reader — switching tabs
        // swaps the hosted content to the newly focused origin's reader,
        // hides the panel while the focused tab has none, and dismisses it
        // only when no reader is left in the window.
        $browserState
            .flatMap { state in
                state.readerOverlayState.$readersByOrigin
                    .combineLatest(state.$focusingTab)
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] readersByOrigin, focusingTab in
                guard let self else { return }
                guard !readersByOrigin.isEmpty else {
                    self.readerPanelController?.dismiss()
                    return
                }
                if let focusingTab, let tab = readersByOrigin[focusingTab.guid] {
                    self.presentReaderPanel(for: tab)
                } else {
                    self.readerPanelController?.hide()
                }
            }
            .store(in: &cancellables)
    }

    /// Handles blocking overlays for every browser window. The Omnibox host
    /// panel must stop accepting input when it dismisses; regular windows also
    /// use this signal to eclipse peek/reader panels or conceal them for tab
    /// search. Kiosk returns before that regular content setup, but shares the
    /// same full-window Omnibox host and therefore needs this observer too.
    private func observeBlockingOverlayVisibility() {
        NotificationCenter.default.publisher(for: .phiInWindowOverlayVisibilityChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self,
                      let visible = notification.userInfo?["visible"] as? Bool else { return }
                // Hosted mode: every session of the shell sees the shell's
                // overlays, so they carry the posting session. Its own hide
                // must still land after it left the shell — `concealFromShell`
                // dismisses the overlays once `isPresented` is already false,
                // and possibly after its tree (tab search included) left the
                // window — or its peek/reader stay eclipsed or concealed on
                // return.
                if let owner = notification.userInfo?["windowId"] as? Int {
                    guard owner == self.windowId,
                          !visible || self.isPresentedOrLegacy else { return }
                } else {
                    guard notification.object as? NSWindow === self.window,
                          self.isPresentedOrLegacy else { return }
                }
                if notification.userInfo?["surface"] as? String == "omnibox" {
                    if !visible {
                        // The empty host must neither eat clicks nor hold
                        // key while its hide animation plays out.
                        self.omniBoxHostPanel?.ignoresMouseEvents = true
                        self.window?.makeKey()
                    }
                    self.peekPanelController?.setEclipsedByInWindowOverlay(
                        visible, by: self.omniBoxHostPanel)
                    self.readerPanelController?.setEclipsedByInWindowOverlay(
                        visible, by: self.omniBoxHostPanel)
                    if !visible {
                        self.retireOmniBoxHostPanelIfIdle()
                    }
                } else {
                    self.peekPanelController?.setConcealedByInWindowOverlay(visible)
                    self.readerPanelController?.setConcealedByInWindowOverlay(visible)
                }
            }
            .store(in: &cancellables)
    }

    /// Whether the focused opener's peek is one the user just opened, rather
    /// than one that was already mounted under that opener — switching back
    /// to an existing peek must not spend a press on a flight.
    static func isFreshlyOpenedPeek(previousPeekTabIdsByOpener: [Int: Int],
                                    openerTabId: Int,
                                    peekTabId: Int) -> Bool {
        previousPeekTabIdsByOpener[openerTabId] != peekTabId
    }

    private func presentPeekPanel(for tab: Tab, flyIn: Bool) {
        // A background session of a hosted shell owns no on-screen surface;
        // its panel is re-shown by the peek/reader sinks once presented.
        guard let window = self.window, isPresentedOrLegacy else { return }
        if peekPanelController == nil {
            let container = mainSplitViewController.webContentContainerViewController
            peekPanelController = PeekPanelController(
                browserState: browserState,
                parentWindow: window,
                anchorView: container.view,
                cardViewProvider: { [weak container] in container?.currentPageCardView },
                originTracker: peekOriginTracker
            )
        }
        peekPanelController?.present(tab: tab, flyIn: flyIn)
    }

    private func presentReaderPanel(for tab: Tab) {
        guard let window = self.window, isPresentedOrLegacy else { return }
        if readerPanelController == nil {
            let container = mainSplitViewController.webContentContainerViewController
            readerPanelController = ReaderPanelController(
                browserState: browserState,
                parentWindow: window,
                anchorView: container.view,
                cardViewProvider: { [weak container] in container?.currentPageCardView }
            )
        }
        readerPanelController?.present(tab: tab)
    }

    // MARK: - Hosted window mode

    /// Installs this session's content in the slot's shell and makes it the
    /// window's controller, so the responder chain, menu validation and
    /// `SpaceSessionControllersManager.findControllerWith` resolve to
    /// the Space on screen. The previous session's content leaves the window
    /// with the content-view-controller swap, which is what takes its tab's
    /// native view out of the window and lets Chromium mark it hidden.
    /// `installingView: false` leaves the tree out of the shell for a slide
    /// that places it itself (`installSessionViewInShell` later);
    /// `completing: false` defers the focus and panel hand-over to
    /// `completePresentationInShell`, called when that slide lands.
    ///
    /// `deferringChromium` keeps the Chromium round trips (frame mirror,
    /// `setPresented:`) off the current run-loop pass: a switch that animates
    /// wants its first frame on screen before anything else runs, and the
    /// slot pushes both sides' presentation to Chromium one turn later.
    func presentInShell(installingView: Bool = true,
                        completing: Bool = true,
                        deferringChromium: Bool = false) {
        guard isHosted, let window = self.window else { return }
        isPresented = true
        window.windowController = self
        (window as? ShellWindow)?.commandTargetWindow = hostedChromiumWindow
        // The shell stays key across a Space switch, so no key notification
        // tells the manager that the active controller changed.
        SpaceSessionControllersManager.shared.notePresentedInShell(self)
        // A freshly built tree would otherwise show the default sidebar width
        // for one tick and then jump to the saved one.
        mainSplitViewController.adoptAutosavedSplitPositionNow()
        if installingView {
            installSessionViewInShell()
        }
        if !deferringChromium {
            pushPresentationToChromium()
        }
        if completing {
            completePresentationInShell()
        }
    }

    /// The Chromium half of presenting: the hidden window takes the shell's
    /// frame and its Browser learns it is the presented one.
    func pushPresentationToChromium() {
        guard isPresented else { return }
        mirrorFrameToChromiumWindow()
        pushPresentedToChromium(true)
    }

    /// The deferred half of `concealFromShell(deferringChromium: true)`.
    func pushConcealmentToChromium() {
        guard !isPresented else { return }
        pushPresentedToChromium(false)
    }

    /// Hosted mode: tells Chromium the presented Browser lost (or regained)
    /// the activation a key window carries. Presentation is not activation:
    /// this session stays presented in its shell while the user works in
    /// another shell, a standalone Incognito or Kiosk window, or another
    /// app, and Chromium's activation order — `chrome.windows.getLastFocused`,
    /// the Dock's "New Window", external URL opens — has to follow key, not
    /// what is on screen. The shell resigning key is the only signal for
    /// that: its hidden browser window is never key itself.
    func pushActiveToChromium(_ active: Bool) {
        guard isHosted, isPresented, hostedChromiumWindow != nil,
              let bridge = ChromiumLauncher.sharedInstance().bridge,
              bridge.responds(to: #selector(PhiChromiumBridgeProtocol.setHostedActive(_:forWindowId:)))
        else { return }
        AppLogDebug("[SpaceSessionController] hosted \(windowId) active=\(active)")
        bridge.setHostedActive(active, forWindowId: Int64(windowId))
    }

    /// Hosted mode: mirrors the shell's native fullscreen state onto this
    /// session's Browser. Chromium never fullscreens the hidden window, so a
    /// transition the user starts on the shell — the green button, the menu
    /// item — reaches Chromium only through here; without it a tab's DOM
    /// fullscreen survives the shell's exit. Idempotent on the Chromium
    /// side, so the transitions Chromium started itself (content
    /// fullscreen, press-and-hold Esc — answered by `requestShellFullscreen`) are
    /// no-ops. Dormant sessions have no Browser to tell yet;
    /// `attachChromiumWindow` catches a presented one up.
    func pushShellFullscreenToChromium(_ fullscreen: Bool) {
        guard isHosted, hostedChromiumWindow != nil,
              let bridge = ChromiumLauncher.sharedInstance().bridge,
              bridge.responds(to: #selector(PhiChromiumBridgeProtocol.setHostedFullscreen(_:forWindowId:)))
        else { return }
        let windowId = Int64(self.windowId)
        // Same deferral as `pushPresentedToChromium`: a fullscreen state
        // change runs Chromium's transition callbacks, not something to do
        // from inside Browser::Create.
        if SpaceSessionControllersManager.shared.isInsideWindowCreatedCallback {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isPresented, self.hostedChromiumWindow != nil,
                      let window = self.window,
                      window.styleMask.contains(.fullScreen) == fullscreen else { return }
                AppLogDebug("[SpaceSessionController] hosted \(windowId) fullscreen=\(fullscreen) (deferred)")
                bridge.setHostedFullscreen(fullscreen, forWindowId: windowId)
            }
            return
        }
        AppLogDebug("[SpaceSessionController] hosted \(windowId) fullscreen=\(fullscreen)")
        bridge.setHostedFullscreen(fullscreen, forWindowId: windowId)
    }

    /// Hosted mode: re-announces this presented session to Chromium. The
    /// shell becoming key (the user clicking from one shell to another) is
    /// not a widget activation Chromium can observe, so the activation order
    /// that `chrome.windows.getLastFocused`, the Dock's "New Window" and
    /// external URL opens follow is refreshed by hand. Idempotent on the
    /// Chromium side.
    func reassertPresentedToChromium() {
        guard isHosted, isPresented else { return }
        pushPresentedToChromium(true)
    }

    /// Window-level chrome for this session: appearance, fullscreen state,
    /// traffic lights. Applied when the session takes the whole shell — at
    /// once for an instant present, when the slide lands for an animated one,
    /// so the titlebar and background do not change ahead of the content.
    private func applyWindowChrome() {
        guard let window else { return }
        applyThemeAppearance(to: window)
        let isNativeFullScreen = window.styleMask.contains(.fullScreen)
        if browserState.isInFullScreenMode != isNativeFullScreen {
            browserState.toggleFullScreenMode(isNativeFullScreen)
        }
        // A session presented into a shell that is already fullscreen (or
        // no longer is) takes the shell's state on the Chromium side too.
        pushShellFullscreenToChromium(isNativeFullScreen)
        applyTrafficLightVisibility(collapsed: browserState.sidebarCollapsed,
                                    fullScreen: isNativeFullScreen)
    }

    /// The session's tree as a subview of the shell's root — not the window's
    /// content view controller: two trees coexist during a switch (the
    /// leaving one animates out live), and installing a view never resizes
    /// the window the way a content view controller does.
    func installSessionViewInShell() {
        guard isHosted, let split = shellSplit else { return }
        presentSidebarViewInShell()
        installPageTreeInShell()
        split.sidebarHost.followTheme(of: self)
        split.contentHost.followTheme(of: self)
        split.floatingSidebarHost.present(browserState)
    }

    /// The page tree alone, into the shell's page area, above whatever is
    /// there (the band slide brings the entering page tree in at its start
    /// and cross-fades it over the leaving one).
    func installPageTreeInShell() {
        guard isHosted, let split = shellSplit else { return }
        let t0 = CACurrentMediaTime()
        split.contentHost.install(mainSplitViewController.view)
        AppLogDebug("[SpaceSessionController] page tree installed in \(Int((CACurrentMediaTime() - t0) * 1000))ms (dormant=\(isDormant))")
    }

    /// Makes this session's page and sidebar content resident in the shell
    /// (hidden until presented), sized by their respective hosts. Done as soon
    /// as a session has a shell — dormant or background — so its first
    /// switch has nothing to bring into the window.
    func hostSidebarViewInShell() {
        guard isHosted, let split = shellSplit else { return }
        mainSplitViewController.loadViewIfNeeded()
        split.contentHost.host(mainSplitViewController.view)
        mainSplitViewController.sidebarViewController.bindSpaceStripToSession()
        mainSplitViewController.webContentContainerViewController.bindSpacesPickerToSession()
        let sidebar = mainSplitViewController.sidebarViewController.view
        split.sidebarHost.host(sidebar)
        sidebar.layoutSubtreeIfNeeded()
        if !PhiPreferences.GeneralSettings.loadLayoutMode().isTraditional {
            split.floatingSidebarHost.host(browserState)
        }
    }

    /// Shows the resident sidebar content as the column's (the band slide
    /// shows it itself, ahead of the page tree, so this is separate).
    func presentSidebarViewInShell() {
        guard isHosted, let split = shellSplit else { return }
        let sidebar = mainSplitViewController.sidebarViewController.view
        sidebar.layer?.transform = CATransform3DIdentity
        split.sidebarHost.present(sidebar)
    }

    /// The shell split this session presents into, once it has a shell.
    var shellSplit: ShellSplitViewController? {
        (window as? ShellWindow)?.shellController?.split
    }

    /// Focus and panel hand-over, one turn after the tree is in the shell (or
    /// when a slide has landed on it).
    func completePresentationInShell() {
        guard isPresented else { return }
        applyWindowChrome()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isPresented, self.window?.isKeyWindow == true else { return }
            self.mainSplitViewController.webContentContainerViewController.restoreFocusAfterPresentation()
            self.reshowOverlayPanelsAfterPresent()
        }
    }

    /// The peek and reader sinks only act while presented, so a session
    /// re-entering the shell re-shows the panels its focused tab owns.
    private func reshowOverlayPanelsAfterPresent() {
        guard let focusingTab = browserState.focusingTab else { return }
        if let peekTab = browserState.peekState.peeksByOpener[focusingTab.guid] {
            presentPeekPanel(for: peekTab, flyIn: false)
        }
        if let readerTab = browserState.readerOverlayState.readersByOrigin[focusingTab.guid] {
            presentReaderPanel(for: readerTab)
        }
    }

    /// Content fullscreen (video, `requestFullscreen`) on one of this
    /// session's tabs. Nothing to do for the window here in either mode:
    /// Chromium fullscreens a legacy window itself, and in hosted mode its
    /// change to the hidden window's fullscreen state reaches the shell
    /// through `windowRequestedFullscreen:` (`requestShellFullscreen`) —
    /// which also carries the cases a content notification cannot, such as
    /// a page leaving fullscreen inside a window the user had fullscreened.
    func handleTabContentFullscreen(isFullscreen: Bool) {}

    /// Hosted mode: Chromium changed this session's Browser fullscreen
    /// state; the shell follows while this session is presented.
    func requestShellFullscreen(_ fullscreen: Bool, targetDisplayId: Int64 = -1) {
        guard isHosted else {
            // Chromium hosts this Browser but this side does not follow it;
            // nothing will answer the request, so end the transition Chromium
            // is waiting on.
            Self.completeHostedFullscreenTransition(windowId: windowId)
            return
        }
        guard let slot else {
            completeShellFullscreenTransition()
            return
        }
        slot.sessionRequestedShellFullscreen(self, fullscreen: fullscreen,
                                             targetDisplayId: targetDisplayId)
    }

    func preHandleKeyEquivalent(_ event: NSEvent) -> PhiKeyEquivalentHandling {
        guard isHosted, isPresented, hostedChromiumWindow != nil,
              let bridge = ChromiumLauncher.sharedInstance().bridge,
              bridge.responds(to: #selector(PhiChromiumBridgeProtocol.preHandleHostedKeyEquivalent(_:forWindowId:)))
        else { return .unhandled }
        return bridge.preHandleHostedKeyEquivalent(event, forWindowId: Int64(windowId))
    }

    func postHandleKeyEquivalent(_ event: NSEvent) -> PhiKeyEquivalentHandling {
        guard isHosted, isPresented, hostedChromiumWindow != nil,
              let bridge = ChromiumLauncher.sharedInstance().bridge,
              bridge.responds(to: #selector(PhiChromiumBridgeProtocol.postHandleHostedKeyEquivalent(_:forWindowId:)))
        else { return .unhandled }
        return bridge.postHandleHostedKeyEquivalent(event, forWindowId: Int64(windowId))
    }

    func completeShellFullscreenTransition() {
        guard isHosted, hostedChromiumWindow != nil else { return }
        Self.completeHostedFullscreenTransition(windowId: windowId)
    }

    /// Ends the fullscreen transition Chromium marked pending for a hosted
    /// Browser when it asked the shell to follow its fullscreen change.
    static func completeHostedFullscreenTransition(windowId: Int) {
        guard let bridge = ChromiumLauncher.sharedInstance().bridge,
              bridge.responds(to: #selector(PhiChromiumBridgeProtocol.hostedFullscreenTransitionDidComplete(forWindowId:)))
        else { return }
        bridge.hostedFullscreenTransitionDidComplete(forWindowId: Int64(windowId))
    }

    /// Withdraws this session from the shell without removing its content:
    /// the entering session's `presentInShell()` replaces it. Window-level
    /// surfaces this session put up (panels, traffic-light positioner) are
    /// dropped so the entering session can take them over.
    ///
    /// `removingView` false is the Space switch: the entering session takes
    /// over the page area and the leaving sidebar content stays resident.
    /// True means the session is leaving the shell, sidebar content included.
    /// `deferringChromium` leaves `setPresented:NO` to the slot, which pushes
    /// it together with the entering session's `setPresented:YES` after the
    /// switch's first frame.
    func concealFromShell(removingView: Bool = true, deferringChromium: Bool = false) {
        guard isHosted, isPresented else { return }
        isPresented = false
        if removingView {
            removeSessionViewFromShell(evictingSidebar: true)
        }
        peekPanelController?.hide()
        readerPanelController?.hide()
        // Transient overlays are dismissed, not carried across the switch:
        // `reshowOverlayPanelsAfterPresent` does not bring them back, and a
        // stale `hasShown` would make the next ⌘T/⌘L/⌘W act on an overlay
        // that is no longer on screen.
        if omniBoxContainerViewController?.hasShown == true {
            omniBoxContainerViewController?.hideOmniBox()
        }
        if searchTabsContainerViewController?.hasShown == true {
            searchTabsContainerViewController?.hideSearchTabs()
        }
        // A Ctrl+Tab session is watched through the shell, which a switch
        // (⌃1…⌃9 shares its modifier) keeps key; left running, releasing
        // Ctrl would select a tab in this hidden Space.
        browserState.tabSwitchManager.cancelSession()
        // An unanswered ask-Space chooser is a child of the shell, not of
        // this Space's tree; it resolves as declined instead of staying over
        // the next Space.
        PhiChromiumCoordinator.shared.declineChooser(windowId: Int64(windowId))
        if let panel = omniBoxHostPanel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        if !deferringChromium {
            pushPresentedToChromium(false)
        }
    }

    /// Takes this session out of the shell entirely — page tree and resident
    /// sidebar content — whether or not it was presented. For a session
    /// that is leaving the slot (closing in the background, dropped while
    /// dormant); a presented one goes through `concealFromShell()`.
    func leaveShell() {
        guard isHosted else { return }
        if isPresented {
            concealFromShell()
        } else {
            removeSessionViewFromShell(evictingSidebar: true)
        }
    }

    /// Hides the resident sidebar content (the band slide hides the leaving
    /// band ahead of the page tree).
    func concealSidebarViewInShell() {
        guard isHosted, mainSplitViewController.isViewLoaded, let split = shellSplit else { return }
        split.sidebarHost.conceal(mainSplitViewController.sidebarViewController.view)
    }

    /// Conceals the resident page and sidebar trees for the next switch.
    /// Chromium observes the page's hidden ancestor through viewDidHide.
    /// `evictingSidebar` removes both trees when the session leaves the shell
    /// (closing, rebinding, or a dormant session being dropped).
    func removeSessionViewFromShell(evictingSidebar: Bool = false) {
        guard isHosted, mainSplitViewController.isViewLoaded else { return }
        if evictingSidebar {
            shellSplit?.floatingSidebarHost.evictContent(for: browserState)
        }
        // A fullscreen page is lifted out of the page tree, under the
        // shell's content view; hiding the tree would leave it on screen.
        mainSplitViewController.webContentContainerViewController
            .collapseContentFullscreenForConcealment()
        let content = mainSplitViewController.view
        if let host = shellSplit?.contentHost {
            if evictingSidebar {
                host.evict(content)
            } else {
                host.conceal(content)
            }
        } else {
            content.removeFromSuperview()
        }
        let sidebar = mainSplitViewController.sidebarViewController.view
        sidebar.layer?.transform = CATransform3DIdentity
        if let host = shellSplit?.sidebarHost {
            if evictingSidebar {
                host.evict(sidebar)
            } else {
                host.conceal(sidebar)
            }
        } else if sidebar.superview != nil {
            sidebar.removeFromSuperview()
        }
    }

    /// Keeps the hidden Chromium window's frame equal to the shell's so
    /// Chromium's bounds-dependent logic (popup placement, `chrome.windows`
    /// bounds, new-window cascading) answers for the window the user sees.
    func mirrorFrameToChromiumWindow() {
        guard let chromiumWindow = hostedChromiumWindow, let window = self.window else { return }
        let target = window.frame
        if chromiumWindow.frame != target {
            chromiumWindow.setFrame(target, display: false)
        }
    }

    /// Closes the window whose close ends this controller: the Chromium
    /// window (through Chromium's own Browser close) in hosted mode, the
    /// adopted window otherwise. Callers that retire a Space's window must
    /// use this rather than `window?.close()`, which in hosted mode would
    /// close the whole shell.
    func closeChromiumWindow() {
        lifecycleWindow?.close()
    }

    private static func setPresentationHostIfSupported(_ shell: NSWindow?, windowId: Int) {
        guard let bridge = ChromiumLauncher.sharedInstance().bridge,
              bridge.responds(to: #selector(PhiChromiumBridgeProtocol.setPresentationHost(_:forWindowId:)))
        else { return }
        bridge.setPresentationHost(shell, forWindowId: Int64(windowId))
    }

    /// Tells Chromium whether this session is the one presented in its shell.
    /// Nothing is sent for a dormant session (no Browser answers to its id
    /// yet; `attachChromiumWindow` sends the state once one does).
    ///
    /// Presenting drives `Browser::DidBecomeActive()`. From inside Chromium's
    /// synchronous window-created callback that would re-enter a Browser
    /// still under construction (the same hazard the deferred close in
    /// `SpaceWindowSlot.registerWindow` avoids), so the call is deferred one
    /// turn there, and dropped if the session's state moved on meanwhile.
    private func pushPresentedToChromium(_ presented: Bool) {
        guard hostedChromiumWindow != nil,
              let bridge = ChromiumLauncher.sharedInstance().bridge,
              bridge.responds(to: #selector(PhiChromiumBridgeProtocol.setPresented(_:forWindowId:)))
        else { return }
        let windowId = Int64(self.windowId)
        if SpaceSessionControllersManager.shared.isInsideWindowCreatedCallback {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isPresented == presented,
                      self.hostedChromiumWindow != nil else { return }
                bridge.setPresented(presented, forWindowId: windowId)
            }
            return
        }
        bridge.setPresented(presented, forWindowId: windowId)
    }

    // MARK: - Traffic light placement

    /// Shows or hides the native traffic lights for the sidebar state and
    /// re-places them on the chrome row. Driven by the sidebar/fullscreen sink
    /// and, in hosted mode, re-applied when a session is presented (the sink
    /// is silent for background sessions).
    private func applyTrafficLightVisibility(collapsed: Bool, fullScreen: Bool) {
        guard let window else { return }
        let traditionalLayout = PhiPreferences.GeneralSettings.loadLayoutMode().isTraditional
        let hideTrafficLights = !fullScreen && collapsed && !traditionalLayout

        window.standardWindowButton(.closeButton)?.isHidden = hideTrafficLights
        window.standardWindowButton(.miniaturizeButton)?.isHidden = hideTrafficLights
        window.standardWindowButton(.zoomButton)?.isHidden = hideTrafficLights

        window.titlebarAppearsTransparent = !fullScreen
        updateTrafficLightPlacement(fullScreen: fullScreen)
    }

    /// Centre line of the chrome row that runs beside the traffic lights, as a
    /// distance from the top of the window.
    ///
    /// `.performance` and `.balanced` are both `SidebarHeaderView`'s 24pt
    /// control row, at its default 8pt and legacy 15.5pt top insets;
    /// `.comfortable` is the horizontal tab strip, whose 32pt tab row starts
    /// `WebContentConstant.edgesSpacing - 2` below the top of the window.
    static func chromeRowCenter(for layoutMode: LayoutMode) -> CGFloat {
        switch layoutMode {
        case .performance:
            return 20
        case .balanced:
            return 27.5
        case .comfortable:
            return 22
        }
    }

    /// Shifts the native traffic lights onto the chrome row beside them.
    ///
    /// AppKit centres the discs in the titlebar height Chromium reports, which
    /// is the same place in all three layouts while Phi's own row sits
    /// somewhere different in each — so left alone the lights line up with at
    /// most one layout. The lights are what moves, rather than the rows: a row
    /// carries the header's vertical rhythm and the strip's hit targets with
    /// it, and the lights carry nothing.
    /// `KioskBrowserWindowController` moves its own lights the same way, by
    /// `KioskBrowserToolbar.titlebarVerticalShift`.
    ///
    /// The row centre is handed over as an absolute distance from the top of
    /// the window rather than as a shift off AppKit's placement, so a titlebar
    /// AppKit re-tiles or re-heights later — which is what a system overlay
    /// over the window does — cannot leave the lights describing the place the
    /// row used to be.
    private func updateTrafficLightPlacement(fullScreen: Bool) {
        guard let window else { return }
        // Hosted: the lights belong to the shell window, which keeps one
        // positioner across every Space it presents.
        if isHosted {
            (window as? ShellWindow)?.shellController?.updateTrafficLightPlacement(fullScreen: fullScreen)
            return
        }
        guard !fullScreen else {
            // AppKit rebuilds the titlebar across the transition and restores
            // the default placement on its own.
            trafficLightPositioner?.stop(restoringPlacement: false)
            trafficLightPositioner = nil
            trafficLightLayoutMode = nil
            return
        }
        let layoutMode = PhiPreferences.GeneralSettings.loadLayoutMode()
        guard trafficLightLayoutMode != layoutMode
                || trafficLightPositioner == nil else { return }

        trafficLightPositioner?.stop(restoringPlacement: true)
        let positioner = TrafficLightPositioner(
            window: window,
            centerFromWindowTop: Self.chromeRowCenter(for: layoutMode)
        )
        trafficLightPositioner = positioner
        trafficLightLayoutMode = layoutMode
        positioner.start()
    }

    @objc private func myWindowWillEnterFullScreen(_ noti: Notification) {
        if noti.object as? NSWindow === self.window {
            browserState.toggleFullScreenMode(true)
            // Drop `.moveToActiveSpace` before macOS finalizes this window's
            // own fullscreen Space, so a second slot entering fullscreen can't
            // drag it back out and leave a blank desktop in Mission Control.
            slot?.windowFullScreenStateChanged(isFullScreen: true)
        }
    }

    @objc private func myWindowWillExitFullScreen(_ noti: Notification) {
        if noti.object as? NSWindow === self.window {
            browserState.toggleFullScreenMode(false)
            // Back to a normal window — restore the sibling-follow behavior.
            slot?.windowFullScreenStateChanged(isFullScreen: false)
        }
    }

    @objc private func myWindowDidEnterFullScreen(_ noti: Notification) {
        if noti.object as? NSWindow === self.window {
            slot?.reconcileFullScreenWithWindowState()
        }
    }

    @objc private func myWindowDidExitFullScreen(_ noti: Notification) {
        if noti.object as? NSWindow === self.window {
            slot?.reconcileFullScreenWithWindowState()
        }
    }

    @objc private func myWindowWillClose(_ notification: Notification) {
        libraryWindowController?.close()
        libraryWindowController = nil
        // Defensive teardown for placeholder mode. In practice Chromium's
        // Browser::~Browser → HidePlaceholder fires first and clears state,
        // making this a no-op; kept as a backstop in case the destruction
        // order ever shifts. See spec §9.1 / §9.4.
        libraryOverlayController?.dismiss(animated: false, restoreFocus: false)
        browserState.exitPlaceholderMode()
        // Drop peek bookkeeping and the panel; the peek tab itself is torn
        // down by Chromium together with the window's tab strip.
        browserState.teardownPeekForWindowClose()
        peekPanelController?.dismiss()
        // Same for the reader overlay and its surface tab.
        browserState.teardownReaderOverlayForWindowClose()
        readerPanelController?.dismiss()
    }


    /// Restore and show a window that was previously hidden (e.g., dangling window after login)
    /// This restores the window to normal state and makes it visible
    func restoreAndShowWindow() {
        guard let window = self.window else { return }

        if isHosted {
            // `window` is the slot's shared shell, placed by the slot; only the
            // hidden Chromium window was parked by `hideDanglingWindow`. Undo
            // that without showing it, and front the shell only for the
            // session it presents.
            if let chromiumWindow = hostedChromiumWindow {
                chromiumWindow.level = .normal
                chromiumWindow.alphaValue = 1.0
            }
            mirrorFrameToChromiumWindow()
            if isPresented {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            AppLogInfo("🪟 [WindowController] Hosted dangling session restored - windowId: \(windowId) presented: \(isPresented)")
            return
        }
        
        window.level = .normal
        window.setContentSize(Self.defaultWindowSize)
        window.alphaValue = 1.0
        window.setIsVisible(true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        
        // Ensure the app is activated
        NSApp.activate(ignoringOtherApps: true)

        AppLogInfo("🪟 [WindowController] Window restored and displayed - windowId: \(windowId)")
    }

    /// Rubber-band nudge for traditional layout, played when a swipe-to-switch
    /// can't proceed because the active Space is already the first or last one.
    /// Mirrors the horizontal window slide's motion — the live window content
    /// shifts a short distance in the swipe's push direction and springs back —
    /// without swapping windows. `forward` follows the swap convention:
    /// next-Space swipes push the content left, previous-Space swipes push it
    /// right. The window clips the overshoot and the traffic lights live in the
    /// titlebar (outside contentView), so they stay put as in a real slide.
    func bounceContentForSpaceSwitchEdge(forward: Bool) {
        guard let subviews = window?.contentView?.subviews, !subviews.isEmpty else { return }
        let offset: CGFloat = forward ? -32 : 32
        for view in subviews {
            view.wantsLayer = true
            guard let layer = view.layer else { continue }
            let bounce = CAKeyframeAnimation(keyPath: "transform.translation.x")
            bounce.values = [0, offset, 0]
            bounce.keyTimes = [0, 0.4, 1]
            bounce.timingFunctions = [
                CAMediaTimingFunction(name: .easeInEaseOut),
                CAMediaTimingFunction(name: .easeInEaseOut)
            ]
            bounce.duration = 0.3
            layer.add(bounce, forKey: "spaceSwitchEdgeBounce")
        }
    }

    func containsTabDragBoundary(at screenLocation: CGPoint) -> Bool {
        guard !browserState.isKioskWindow else { return false }
        if tabStripView?.containsScreenLocation(screenLocation) == true {
            return true
        }
        return mainSplitViewController.containsSidebarTabDragBoundary(at: screenLocation)
    }

    // =========================================================================
    // Flicker fix: Tab visibility synchronization
    // =========================================================================

    /// Called when Chromium has hidden the previous tab and it's ready for cleanup.
    /// Forwards to WebContentContainerViewController to remove the old NSView.
    func handlePreviousTabReadyForCleanup(tabId: Int) {
        if let kioskContentViewController {
            kioskContentViewController.handlePreviousTabReadyForCleanup(tabId: tabId)
            return
        }
        mainSplitViewController.webContentContainerViewController
            .handlePreviousTabReadyForCleanup(tabId: tabId)
    }

    /// Called when a new tab has completed its first visually non-empty paint.
    /// Forwards to WebContentContainerViewController to bring the new tab's view to front.
    func handleTabReadyToDisplay(tabId: Int) {
        if let kioskContentViewController {
            kioskContentViewController.handleTabReadyToDisplay(tabId: tabId)
            return
        }
        mainSplitViewController.webContentContainerViewController
            .handleTabReadyToDisplay(tabId: tabId)
    }

    // =========================================================================
    // DevTools embedding
    // =========================================================================

    func handleDevToolsDidAttach(tabId: Int, devToolsView: NSView) {
        mainSplitViewController.webContentContainerViewController
            .handleDevToolsDidAttach(tabId: tabId, devToolsView: devToolsView)
    }

    func handleDevToolsDidDetach(tabId: Int) {
        mainSplitViewController.webContentContainerViewController
            .handleDevToolsDidDetach(tabId: tabId)
    }

    func handleUpdateInspectedPageBounds(tabId: Int, bounds: CGRect, hide: Bool) {
        mainSplitViewController.webContentContainerViewController
            .handleUpdateInspectedPageBounds(tabId: tabId, bounds: bounds, hide: hide)
    }

}

extension NSNotification.Name {
    static let mainBrowserWindowCreated = NSNotification.Name("MainBrowserWindowCreated")
}

extension NSView {
    func containsScreenLocation(_ screenLocation: CGPoint) -> Bool {
        guard let window else { return false }
        let pointInWindow = window.convertPoint(fromScreen: NSPoint(x: screenLocation.x, y: screenLocation.y))
        let pointInView = convert(pointInWindow, from: nil)
        return bounds.contains(pointInView)
    }
}

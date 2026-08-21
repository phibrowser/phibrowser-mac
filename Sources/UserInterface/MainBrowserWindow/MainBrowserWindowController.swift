// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Combine
import SnapKit
import SwiftUI
class MainBrowserWindowController: NSWindowController {
    static let defaultWindowSize = NSSize(width: 1280, height: 860)
    
    let mainSplitViewController: MainSplitViewController
    
    let account: Account
    let browserType: ChromiumBrowserType
    let profileId: String
    let spaceId: String
    /// The window-group this controller belongs to. Set by the caller
    /// (`PhiChromiumCoordinator.mainBrowserWindowCreated`,
    /// `MainBrowserWindowControllersManager.processDanglingWindow`) right
    /// after construction. Weak so the controller doesn't pin a slot the
    /// manager has already dropped from its registry.
    weak var slot: SpaceWindowSlot?
    
    var omniBoxContainerViewController: OmniBoxContainerViewController?
    var searchTabsContainerViewController: SearchTabsContainerViewController?
    
    private lazy var toastContainerViewController: OverlayToastViewController = {
        return OverlayToastViewController(state: browserState)
    }()

    private lazy var imagePreviewOverlayViewController: ImagePreviewOverlayViewController = {
        ImagePreviewOverlayViewController(state: browserState.imagePreviewState)
    }()

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
    /// them. One level above `.normal` keeps the omnibox over the panels and
    /// below `.floating` surfaces (tooltips). Created on first use; stays
    /// attached with `ignoresMouseEvents` flipped on dismissal so the hide
    /// animation can finish inside it.
    private(set) var omniBoxHostPanel: NSPanel?
    private var omniBoxHostResizeObserver: NSObjectProtocol?

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
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + 1)
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
        if panel.parent == nil {
            window.addChildWindow(panel, ordered: .above)
        }
        panel.ignoresMouseEvents = false
        syncOmniBoxHostPanelFrame()
        panel.makeKeyAndOrderFront(nil)
        return panel
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
    lazy var cancellables = Set<AnyCancellable>()
    private var multiSelectionEscapeMonitor: Any?
    private(set) var windowId = 0
    @Published private(set) var browserState: BrowserState
    var tabStripView: TabStrip? { mainSplitViewController.webContentContainerViewController.tabStripView }
    
    required init?(coder: NSCoder) {
        fatalError("not support")
    }
    
    init(window: NSWindow,
         windowId: Int,
         browserType: ChromiumBrowserType = .normal,
         profileId: String = LocalStore.defaultProfileId,
         spaceId: String = LocalStore.defaultSpaceId,
         account: Account = AccountController.shared.account ?? AccountController.defaultAccount,
         slot: SpaceWindowSlot? = nil) {
        let state = BrowserState(
            windowId: windowId,
            localStore: account.localStorage,
            profileId: profileId,
            spaceId: spaceId,
            isIncognito: browserType == .incognito || browserType == .incognitoSpace,
            isIncognitoSpace: browserType == .incognitoSpace
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
        self.mainSplitViewController = MainSplitViewController(state: state)
        super.init(window: window)
        ChromiumLauncher.sharedInstance().bridge?
            .setWebContentsOwnsMouseDown(
                true,
                windowId: Int64(windowId)
            )
        self.slot = slot
        browserState.windowController = self
        setupWindow()
        installMultiSelectionEscapeMonitor()
        MainBrowserWindowControllersManager.shared.retainWindowControllerUntilWindowClosed(self)
        // Normal, Incognito Space, and agent-Space windows participate in the
        // Space mapping; standalone incognito and shadow windows are orthogonal
        // to Spaces. Agent-Space windows are hidden TYPE_NORMAL windows the user
        // can switch to, so they must register too — otherwise the Space has no
        // `windowsBySpaceId[spaceId]` entry, its seed tab is never created, and
        // surfacing the pip shows an empty Space even though the Chromium window
        // has live tabs. The slot was resolved by the caller
        // (PhiChromiumCoordinator / MainBrowserWindowControllersManager), which
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
            guard let self, let window = self.window else { return event }
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
           MainBrowserWindowControllersManager.shared
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
        }
    }
    
    private func setupContentView() {
        guard let _ = self.window else { return }
        
        self.contentViewController = mainSplitViewController
        
        $browserState.compactMap { $0 }
            .flatMap { state in
                state.$sidebarCollapsed.combineLatest(
                    state.$isInFullScreenMode,
                    NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
                        .map { _ in }
                        .prepend(())
                )
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] collapsed, fullScreen, _ in
                guard let self, let window = self.window  else { return }
                let traditionalLayout = PhiPreferences.GeneralSettings.loadLayoutMode().isTraditional
                let hideTrafficLights = !fullScreen && collapsed && !traditionalLayout
                
                window.standardWindowButton(.closeButton)?.isHidden = hideTrafficLights
                window.standardWindowButton(.miniaturizeButton)?.isHidden = hideTrafficLights
                window.standardWindowButton(.zoomButton)?.isHidden = hideTrafficLights
                
                window.titlebarAppearsTransparent = !fullScreen
                
            }
            .store(in: &cancellables)
        self.contentViewController = mainSplitViewController
        
        
        
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

        // Blocking-overlay interplay with the peek/reader panels (child
        // windows, which draw above every in-window view):
        // - The omnibox floats in its own child window one level above the
        //   panels, so they stay visible beneath it — but must go inert
        //   (their key monitors would fight the omnibox for Esc/shortcuts)
        //   and take key back when it dismisses.
        // - Tab search is still an in-window view, so the panels step fully
        //   aside while it is up.
        NotificationCenter.default.publisher(for: .phiInWindowOverlayVisibilityChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self,
                      notification.object as? NSWindow === self.window,
                      let visible = notification.userInfo?["visible"] as? Bool else { return }
                if notification.userInfo?["surface"] as? String == "omnibox" {
                    if !visible {
                        // The empty host must neither eat clicks nor hold
                        // key while its hide animation plays out.
                        self.omniBoxHostPanel?.ignoresMouseEvents = true
                        self.window?.makeKey()
                    }
                    self.peekPanelController?.setEclipsedByInWindowOverlay(visible)
                    self.readerPanelController?.setEclipsedByInWindowOverlay(visible)
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
        guard let window = self.window else { return }
        if peekPanelController == nil {
            peekPanelController = PeekPanelController(
                browserState: browserState,
                parentWindow: window,
                anchorView: mainSplitViewController.webContentContainerViewController.view,
                originTracker: peekOriginTracker
            )
        }
        peekPanelController?.present(tab: tab, flyIn: flyIn)
    }

    private func presentReaderPanel(for tab: Tab) {
        guard let window = self.window else { return }
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
        // Defensive teardown for placeholder mode. In practice Chromium's
        // Browser::~Browser → HidePlaceholder fires first and clears state,
        // making this a no-op; kept as a backstop in case the destruction
        // order ever shifts. See spec §9.1 / §9.4.
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
        mainSplitViewController.webContentContainerViewController
            .handlePreviousTabReadyForCleanup(tabId: tabId)
    }

    /// Called when a new tab has completed its first visually non-empty paint.
    /// Forwards to WebContentContainerViewController to bring the new tab's view to front.
    func handleTabReadyToDisplay(tabId: Int) {
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

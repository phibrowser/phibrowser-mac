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
    
    lazy var omnibackgroundView: EventBlockBgView = {
       return EventBlockBgView()
    }()

    lazy var searchTabsBackgroundView: EventBlockBgView = {
        EventBlockBgView()
    }()
    
    private var originalContentView: NSView?
    lazy var cancellables = Set<AnyCancellable>()
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
        self.mainSplitViewController = MainSplitViewController(state: state)
        super.init(window: window)
        self.slot = slot
        browserState.windowController = self
        setupWindow()
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
    
    override var windowNibName: NSNib.Name? { "" }
    
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

    private func applyThemeAppearance(to window: NSWindow) {
        let appearance = browserState.themeContext.windowAppearance
        window.appearance = appearance
        window.contentView?.appearance = appearance
        contentViewController?.view.appearance = appearance
        mainSplitViewController.view.appearance = appearance
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

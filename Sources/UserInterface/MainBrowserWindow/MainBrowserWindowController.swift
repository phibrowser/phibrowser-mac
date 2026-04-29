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
    
    var omniBoxContainerViewController: OmniBoxContainerViewController?
    
    private lazy var toastContainerViewController: OverlayToastViewController = {
        return OverlayToastViewController(state: browserState)
    }()

    private lazy var imagePreviewOverlayViewController: ImagePreviewOverlayViewController = {
        ImagePreviewOverlayViewController(state: browserState.imagePreviewState)
    }()
    
    lazy var omnibackgroundView: EventBlockBgView = {
       return EventBlockBgView()
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
         account: Account = AccountController.shared.account ?? AccountController.defaultAccount) {
        let state = BrowserState(
            windowId: windowId,
            localStore: account.localStorage,
            profileId: profileId,
            isIncognito: browserType == .incognito
        )
        self.browserState = state
        self.windowId = windowId
        self.account = account
        self.browserType = browserType
        self.profileId = profileId
        self.mainSplitViewController = MainSplitViewController(state: state)
        super.init(window: window)
        browserState.windowController = self
        setupWindow()
        MainBrowserWindowControllersManager.shared.retainWindowControllerUntilWindowClosed(self)
        
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
        //        window.delegate = self
        window.setFrameAutosaveName("mainBrowserWindow")
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
        browserState.themeContext.themeAppearancePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                guard let self, let window = self.window else { return }
                self.applyThemeAppearance(to: window)
            }
            .store(in: &cancellables)
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
        }
    }
    
    @objc private func myWindowWillExitFullScreen(_ noti: Notification) {
        if noti.object as? NSWindow === self.window {
            browserState.toggleFullScreenMode(false)
        }
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

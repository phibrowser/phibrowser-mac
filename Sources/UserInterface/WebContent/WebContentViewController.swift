// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

/*
 WebContentViewController
 ========================
 
 Each WebContentViewController is bound one-to-one with a Tab, responsible for
 displaying its web content and optional AI Chat sidebar.
 Lifecycle is managed by WebContentContainerViewController.
 
 View hierarchy:
 
 view (ColoredVisualEffectView)
 ├── titleAwareArea                  // Titlebar-aware region (handles double-click maximize, etc.)
 └── splitViewContainer              // SplitView container (rounded corners, background)
     └── contentSplitViewController.view
         ├── [Left] leftContainerWrapper
         │   └── leftContainerView       // Web content container (rounded corners, border)
         │       ├── headerView          // Navigation bar (address bar, back/forward, Chat button)
         │       ├── bookmarkBarSlotView  // Stable host slot for an attached bookmark bar
         │       └── hostView            // Web content host
         │           └── webContentView  // Chromium-rendered web view
         │
         └── [Right] embeddedChatViewController.view  // AI Chat sidebar
             └── contentView             // AI Chat content container
                 └── aiChatWebView       // AI Chat WebView
 
 Layout constraints:
 - splitViewContainer: trailing/bottom inset 8pt from view edges, top is 0
 - leading inset is 0 when the sidebar is expanded, 8pt when collapsed or in traditional layout
 - leftContainerView: 4pt inset + border when AI Chat is expanded; no inset/border when collapsed
 - embeddedChatViewController: min width 300, max width 600, collapsible
 
 AI Chat state management:
 - Tab.aiChatEnabled: whether AI Chat can be expanded (false on NTP)
 - Tab.aiChatCollapsed: current expand/collapse state
 - Auto-collapses when aiChatEnabled becomes false
 - Follows aiChatCollapsed when aiChatEnabled is true
 */

import Cocoa
import Combine
import SnapKit
import SwiftUI

enum WebContentConstant {
    static let edgesSpacing: CGFloat = 8.0
    static let headerHeight: CGFloat = 40  // WebContentHeader
    static let topBarHeight: CGFloat = TabStripMetrics.Strip.height  // horizontal tab strip
    static let bookmarkBarHeight: CGFloat = 32
    static let contentEdgeSpacing = 4
}


class WebContentViewController: NSViewController {
    private lazy var cancellables = Set<AnyCancellable>()
    /// Cancellables for tab-specific observers (need to be reset when tab changes)
    private var tabObserverCancellables = Set<AnyCancellable>()
    /// Cancellables for content switching based on URL changes.
    private var contentObserverCancellables = Set<AnyCancellable>()
    /// Cancellable for content-fullscreen subscription on the associated tab.
    private var contentFullscreenCancellable: AnyCancellable?
    /// Saved superview reference while hostView is re-parented to window.contentView
    /// for HTML5 content fullscreen. Nil when not in fullscreen.
    private weak var savedHostViewSuperview: NSView?
    private var progressObserverCancellables = Set<AnyCancellable>()
    private var lastProgressLogBucket: Int?
    private var isSubscriptionsSetup = false
    private enum ContentMode: Equatable {
        case nativeNtp
        case webContent
        case groupOverview(token: String)
    }
    private var contentMode: ContentMode? {
        didSet {
            // Mirror to the tab so consumers outside this controller (e.g.
            // CommandDispatcher) can tell whether a WebContents is visible.
            associatedTab?.isShowingNativeNTP = (contentMode == .nativeNtp)
        }
    }
    
    /// Flag to prevent reentrant updates between splitViewItem and tab state
    private var isUpdatingAIChatState = false
    /// Last known expanded width for AI Chat sidebar.
    private var lastKnownAIChatWidth: CGFloat = 360
    /// Target width for the next expand animation.  Set before uncollapsing so
    /// `animateAIChatCollapseTransition` can temporarily raise `minimumThickness`.
    /// Cleared in the animation completion handler.
    private var pendingAIChatWidthRestore: CGFloat?
    /// Set once when the AI Chat sidebar is first expanded during this
    /// controller's lifetime.  After the first expand, cached-width restoration
    /// is skipped — the sidebar simply uses `lastKnownAIChatWidth`.
    private var hasRestoredAIChatWidth = false
    /// True while the AI Chat split item is animating its expand transition.
    /// Frame-change processing is skipped during this window to avoid interfering
    /// with the animation (e.g. persisting intermediate widths).
    private var isAnimatingAIChatExpansion = false
    
    /// Chromium's `restoreFocus` / `focus` silently fails on pages that haven't
    /// loaded yet (url=nil).  When set, the `$url` observer will re-trigger
    /// `restoreFocusForCurrentTab` once the URL arrives and the page is ready.
    private var pendingChromeRefocusOnUrlReady = false
    
    // MARK: - Left Content Area
    /// Wrapper that provides the adjustable inset for the left content area.
    private lazy var leftContainerWrapper = NSView()
    /// Main left container hosting the header, bookmark bar, and content host.
    private lazy var leftContainerView = NSView()
    /// Stable slot between the header and content host for the bookmark bar.
    private lazy var bookmarkBarSlotView = NSView()
    private lazy var hostView = WebContentHostView()
    private lazy var webContentProgressBar = WebContentProgressBarView()
    private lazy var headerView = WebContentHeader(browserState: browserState)

    var addressBarAnchorView: NSView? { headerView.addressBarAnchorView }

    private var titleAwareArea = TitlebarAwareView()
    private var headerHeightConstraint: Constraint?

    private var bookmarkBarHeightConstraint: Constraint?
    private weak var attachedBookmarkBar: BookmarkBar?
    private var leftContainerInsetConstraint: Constraint?
    private var splitViewLeadingConstraint: Constraint?
    private var nativeNtpController: NewTabViewController?
    private var groupOverviewController: GroupOverviewViewController?

    // MARK: - Agent Animation Overlay
    private lazy var agentAnimationOverlay: EdgeFogOverlayView = {
        let overlay = EdgeFogOverlayView()
        overlay.alphaValue = 0
        overlay.layer?.cornerRadius = 0
        return overlay
    }()

    // MARK: - AI Chat Split View
    /// Split-view container that owns the rounded background and spacing.
    private lazy var splitViewContainer = NSView()
    private lazy var contentSplitViewController = NSSplitViewController()
    private var webContentSplitViewItem: NSSplitViewItem!
    private var aiChatSplitViewItem: NSSplitViewItem?
    /// Embedded AI Chat controller paired one-to-one with the associated tab.
    private lazy var embeddedChatViewController: EmbeddedChatViewController? = {
        guard let state = browserState else { return nil }
        return EmbeddedChatViewController(with: state, tab: associatedTab)
    }()

    override func loadView() {
        let view = ColoredVisualEffectView()
        view.themedBackgroundColor = .windowOverlayBackground
        view.material = .fullScreenUI
        view.wantsLayer = true
        self.view = view
        setupView()
    }
    private weak var browserState: BrowserState?
    
    /// The associated Tab for this WebContentViewController
    /// Each WebContentViewController is uniquely associated with one Tab
    private(set) weak var associatedTab: Tab?
    
    init(state: BrowserState?, tab: Tab? = nil) {
        self.browserState = state
        self.associatedTab = tab
        super.init(nibName: nil, bundle: nil)
        // Subscribe to the initial tab's content-fullscreen state so a brand-new
        // controller (created when a tab is first opened) picks up future
        // fullscreen toggles. updateAssociatedTab re-binds on tab switch.
        rebindContentFullscreenObserver(for: tab)
    }
    
    /// Update the associated tab (called when switching tabs in legacy mode)
    func updateAssociatedTab(_ tab: Tab) {
        let tabChanged = tab !== associatedTab
        if tabChanged {
            pendingChromeRefocusOnUrlReady = false
        }
        self.associatedTab = tab
        headerView.currentTab = tab
        
        // Track focus transitions so tab switches can restore the right target.
        setupFocusCallbackForTab(tab)
        
        // Update embedded chat's associated tab
        embeddedChatViewController?.updateAssociatedTab(tab)
        
        // Rebind tab observers if tab object changed
        if tabChanged, let aiChatSplitViewItem {
            // Rebinding also performs the initial AI Chat state sync.
            rebindTabObservers(for: tab, splitViewItem: aiChatSplitViewItem)
        }
        
        // Update AI Chat state from tab (only if tab object didn't change, otherwise already synced above)
        if let aiChatSplitViewItem {
            if !tabChanged {
                // Same tab instance, but its AI Chat flags may still have changed.
                syncAIChatState(from: tab, to: aiChatSplitViewItem)
            }
            
            // Keep the left container styling aligned with the chat state.
            updateLeftContainerStyle(isAIChatExpanded: !aiChatSplitViewItem.isCollapsed)
        }
        
        bindContentObservers(for: tab)
        bindProgressObservers(for: tab)
        rebindContentFullscreenObserver(for: tab)
        updateContentForTab(tab)
        updateAgentAnimationOverlay()

        // Restore focus whenever the associated tab changes.
        restoreFocusForCurrentTab()
    }
    
    /// Installs focus callbacks for the associated tab.
    private func setupFocusCallbackForTab(_ tab: Tab) {
        let url = tab.url ?? "nil"
        let isNTP = tab.isNTP
        AppLogDebug("🔍 [Focus] setupFocusCallbackForTab - url: \(url), isNTP: \(isNTP), isFocused: \(tab.webContentWrapper?.isFocused ?? false), lastFocusTarget: \(String(describing: tab.lastFocusTarget))")
        
        tab.onFocusGained = { [weak tab] in
            AppLogDebug("🔍 [Focus] onFocusGained triggered - url: \(tab?.url ?? "nil"), isNTP: \(tab?.isNTP ?? false)")
            tab?.updateFocusTarget(.webContent)
        }
        
        // Catch focus that may have been acquired before the callback was installed.
        if tab.webContentWrapper?.isFocused == true {
            AppLogDebug("🔍 [Focus] Tab already focused, setting lastFocusTarget to .webContent")
            tab.updateFocusTarget(.webContent)
        }
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewWillAppear() {
        super.viewWillAppear()

        // Refresh the header and bookmark-slot state when the controller first appears.
        updateHeaderVisibility()

        // Wire the downloads manager into the header download button.
        if let downloadsManager = browserState?.downloadsManager {
            headerView.bindDownloadsManager(downloadsManager)
        }

        // Install one-time subscriptions.
        setupSubscriptionsIfNeeded()
    }
    
    override func viewDidAppear() {
        super.viewDidAppear()
        // Restore focus after the view enters the hierarchy.
        restoreFocusForCurrentTab()
        // If this controller became associated with a fullscreen tab before
        // its view was in a window (so applyContentFullscreenState bailed
        // out early), catch up now that hostView.window is available.
        if associatedTab?.isInContentFullscreen == true,
           savedHostViewSuperview == nil {
            applyContentFullscreenState(true)
        }
    }
    
    // MARK: - Focus Management
    
    /// Restores focus based on the associated tab's last focus target.
    private func restoreFocusForCurrentTab() {
        guard let tab = associatedTab else {
            AppLogDebug("🔍 [Focus] restoreFocusForCurrentTab - no associatedTab")
            return
        }

        if agentAnimationOverlay.superview != nil {
            view.window?.makeFirstResponder(agentAnimationOverlay)
            return
        }
        
        let url = tab.url ?? "nil"
        let isNTP = tab.isNTP
        AppLogDebug("🔍 [Focus] restoreFocusForCurrentTab - url: \(url), isNTP: \(isNTP), lastFocusTarget: \(String(describing: tab.lastFocusTarget)), isFocused: \(tab.webContentWrapper?.isFocused ?? false)")
        
        switch tab.lastFocusTarget {
        case .webContent:
            AppLogDebug("🔍 [Focus] Restoring focus to webContent")
            focusWebContent()
        case .aiChat:
            // Fall back to web content if AI Chat is currently collapsed.
            if aiChatSplitViewItem?.isCollapsed == false {
                AppLogDebug("🔍 [Focus] Restoring focus to aiChat")
                embeddedChatViewController?.focusAIChat()
            } else {
                AppLogDebug("🔍 [Focus] AI Chat collapsed, restoring focus to webContent")
                focusWebContent()
            }
        case nil:
            // Leave focus unchanged when no prior target is recorded.
            AppLogDebug("🔍 [Focus] lastFocusTarget is nil, not restoring focus")
            break
        }
    }
    
    /// Focuses the active web content view.
    private func focusWebContent() {
        guard let tab = associatedTab else {
            AppLogDebug("🔍 [Focus] focusWebContent - no tab or webView")
            return
        }

        if shouldShowNativeNtp(for: tab) {
            showNativeNtp(for: tab)
            nativeNtpController?.focusOmnibox()
            return
        }

        guard let webView = tab.webContentView else {
            AppLogDebug("🔍 [Focus] focusWebContent - no tab or webView")
            return
        }

        let mfrResult = view.window?.makeFirstResponder(webView) ?? false

        guard let wrapper = tab.webContentWrapper,
              wrapper.responds(to: #selector(WebContentWrapper.focus)) else {
            return
        }

        if !mfrResult {
            return
        }

        if tab.url == nil {
            pendingChromeRefocusOnUrlReady = true
            AppLogDebug("🔍 [Focus] Chromium focus deferred — page not loaded yet (tabGuid: \(tab.guid))")
            return
        }
        pendingChromeRefocusOnUrlReady = false
        if tab.isNTP {
            if !wrapper.isFocused {
                wrapper.focus()
            }
        } else {
            wrapper.restoreFocus()
        }
    }

    // MARK: - Subscriptions Setup
    
    private func setupSubscriptionsIfNeeded() {
        guard !isSubscriptionsSetup else { return }
        isSubscriptionsSetup = true
        
        // Seed the initial state when the controller already has an associated tab.
        if let tab = associatedTab {
            headerView.currentTab = tab
            // Install focus tracking for the initial tab.
            setupFocusCallbackForTab(tab)
            bindContentObservers(for: tab)
            bindProgressObservers(for: tab)
            updateContentForTab(tab)
        }
        
        browserState?.themeContext.themeAppearancePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                self?.updateTheme()
            }
            .store(in: &cancellables)

        AgentAnimationManager.shared.stateChanged
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tabId in
                guard let self, self.associatedTab?.guid == tabId else { return }
                self.updateAgentAnimationOverlay()
            }
            .store(in: &cancellables)
        updateAgentAnimationOverlay()

        // Observe AI Chat collapse state once the split item exists.
        setupAIChatObserver()

        browserState?.$sidebarCollapsed
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateSplitViewLeadingInset()
            }
            .store(in: &cancellables)

        browserState?.$groupOverviewState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.updateGroupOverviewState(state)
            }
            .store(in: &cancellables)

        // Re-render content when split membership/visuals change for the
        // associated tab. Chromium is source of truth; we just react.
        // Only the controller whose tab is currently focused mounts the
        // split host — otherwise two controllers in the same split race
        // to re-parent each other's webContentView. Inactive controllers
        // refresh on switch via refreshSplitContentIfNeeded().
        browserState?.$splits
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, let tab = self.associatedTab else { return }
                // AI Chat autohide depends on split membership: a pane leaving
                // a split must collapse its now-orphaned sidebar immediately,
                // not wait for the next focus switch to re-sync. Runs for every
                // controller (focused or not) so a partner pane that has just
                // been split off also converges.
                if let aiChatSplitViewItem = self.aiChatSplitViewItem {
                    self.syncAIChatState(from: tab, to: aiChatSplitViewItem)
                }
                guard self.browserState?.focusingTab?.guid == tab.guid else { return }
                // Each pane tracks its own `lastKnownAIChatWidth`, so a
                // freshly-formed split would otherwise expand the partner
                // pane at its stale (often default) width. Push the focused
                // pane's width into the partner now — runs before the
                // partner's own aiChatCollapsed observer fires the expand.
                self.syncAIChatWidthToSplitPartner(self.lastKnownAIChatWidth)
                self.updateContentForTab(tab)
            }
            .store(in: &cancellables)
    }

    private func updateSplitViewLeadingInset() {
        let traditionalLayout = PhiPreferences.GeneralSettings.loadLayoutMode().isTraditional
        let sidebarCollapsed = browserState?.sidebarCollapsed ?? true
        let leadingInset: CGFloat = (traditionalLayout || sidebarCollapsed)
            ? WebContentConstant.edgesSpacing
            : 0
        splitViewLeadingConstraint?.update(inset: leadingInset)
    }

    private func updateTheme() {
        splitViewContainer.phiLayer?.setBackgroundColor(ThemedColor.contentOverlayBackground)
        // Theme change writes into ColoredVisualEffectView's colorView layer,
        // whose CA transaction commit re-applies kCAFilterPlusL on hostView's
        // layer-backed descendants. Re-clear (sync + post-commit) to keep
        // webContentView / devToolsView free of the vibrancy tint.
        hostView.scheduleVibrancyClear()
    }
    
    // MARK: - AI Chat Observer
    
    private func setupAIChatObserver() {
        guard browserState?.isIncognito != true, let aiChatSplitViewItem else { return }
        
        // Observe the associated tab's AI Chat flags.
        if let tab = associatedTab {
            bindTabObservers(for: tab, splitViewItem: aiChatSplitViewItem)
        }
        
        // Observe split-item collapse changes directly.
        aiChatSplitViewItem.publisher(for: \.isCollapsed)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isCollapsed in
                guard let self else { return }
                
                // Ignore KVO while we are already synchronizing state ourselves.
                guard !self.isUpdatingAIChatState else {
                    self.updateLeftContainerStyle(isAIChatExpanded: !isCollapsed)
                    return
                }
                
                let tabAiChatCollapsed = self.associatedTab?.aiChatCollapsed ?? true
                
                // Skip no-op updates to avoid loops.
                guard tabAiChatCollapsed != isCollapsed else {
                    self.updateLeftContainerStyle(isAIChatExpanded: !isCollapsed)
                    return
                }
                
                // Guard against feedback loops while mirroring state back to the tab.
                self.isUpdatingAIChatState = true
                defer { self.isUpdatingAIChatState = false }
                
                // Mirror the split view state back into the tab model (and its
                // split partner, so both panes share one collapse state).
                if let tab = self.associatedTab {
                    self.browserState?.setAIChatCollapsed(for: tab, collapsed: isCollapsed)
                }
                // Keep styling in sync with the chat state.
                self.updateLeftContainerStyle(isAIChatExpanded: !isCollapsed)
                self.persistAIChatSidebarStateIfNeeded(for: self.associatedTab)
            }
            .store(in: &cancellables)

        // Track frame changes directly because split-view delegate callbacks are unreliable here.
        aiChatSplitViewItem.viewController.view.postsFrameChangedNotifications = true
        NotificationCenter.default.publisher(
            for: NSView.frameDidChangeNotification,
            object: aiChatSplitViewItem.viewController.view
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            guard let self else { return }
            guard !aiChatSplitViewItem.isCollapsed else { return }
            let width = aiChatSplitViewItem.viewController.view.frame.width
            guard width > 0 else { return }
            // Skip during expand animation to avoid persisting intermediate widths.
            guard !self.isAnimatingAIChatExpansion else { return }
            let newWidth = self.clampAIChatWidth(width)
            // Bounce guard: when a split partner pushed this width onto us via
            // `applyAIChatWidthFromPartner`, our split-view re-lays-out and
            // fires this notification with the same value. Skip the re-emit
            // so we don't ping-pong with the partner.
            guard abs(newWidth - self.lastKnownAIChatWidth) > 0.5 else { return }
            self.lastKnownAIChatWidth = newWidth
            self.persistAIChatSidebarStateIfNeeded(for: self.associatedTab)
            self.syncAIChatWidthToSplitPartner(newWidth)
        }
        .store(in: &cancellables)
    }

    /// In a split both panes have independent `aiChatSplitViewItem` geometry,
    /// but the chat itself is shared. After a manual resize on the active
    /// pane, push the new width into the partner pane's split item so that
    /// switching focus does not snap the chat back to the partner's stale
    /// width.
    private func syncAIChatWidthToSplitPartner(_ width: CGFloat) {
        guard let state = browserState,
              let tab = associatedTab,
              let group = state.splitGroup(forTabId: tab.guid),
              let partnerId = group.partnerTabId(of: tab.guid),
              let container = parent as? WebContentContainerViewController,
              let partner = container.findController(forTabId: partnerId),
              partner !== self else { return }
        partner.applyAIChatWidthFromPartner(width)
    }

    /// Apply a chat width pushed in from this controller's split partner.
    /// Updates `lastKnownAIChatWidth` so any future expand uses the synced
    /// value, and if the split item is currently uncollapsed, drives the
    /// divider to match so the visible width stays consistent across pane
    /// focus changes. Bounce-protected via the equality check in the frame
    /// observer.
    func applyAIChatWidthFromPartner(_ width: CGFloat) {
        let clamped = clampAIChatWidth(width)
        guard abs(clamped - lastKnownAIChatWidth) > 0.5 else { return }
        lastKnownAIChatWidth = clamped
        guard let aiChatSplitViewItem,
              !aiChatSplitViewItem.isCollapsed else { return }
        let splitView = contentSplitViewController.splitView
        let total = splitView.bounds.width
        guard total > 0 else { return }
        let dividerThickness = splitView.dividerThickness
        let position = max(0, total - clamped - dividerThickness)
        splitView.setPosition(position, ofDividerAt: 0)
    }
    
    /// Rebind tab observers when associated tab changes
    private func rebindTabObservers(for tab: Tab, splitViewItem: NSSplitViewItem) {
        // Cancel observers tied to the previous associated tab.
        tabObserverCancellables.removeAll()
        // Bind observers for the new associated tab.
        bindTabObservers(for: tab, splitViewItem: splitViewItem)
    }
    
    /// Bind observers for a specific tab
    private func bindTabObservers(for tab: Tab, splitViewItem: NSSplitViewItem) {
        // `dropFirst()` skips the initial state, so sync once up front.
        syncAIChatState(from: tab, to: splitViewItem)
        
        observeTabAIChatState(tab, splitViewItem: splitViewItem)
        observeTabAIChatEnabled(tab, splitViewItem: splitViewItem)
    }
    
    /// Sync AI Chat state from tab to splitViewItem (one-time, with animation)
    private func syncAIChatState(from tab: Tab, to splitViewItem: NSSplitViewItem) {
        // In a split the chat is shared, so autohide only when *both* panes
        // disable chat (e.g. both panes are on NTP). When the partner pane
        // still has chat enabled, mirror the shared collapsed state instead.
        guard tab.aiChatEnabled || partnerHasAIChatEnabled() else {
            if !splitViewItem.isCollapsed {
                isUpdatingAIChatState = true
                splitViewItem.animator().isCollapsed = true
                isUpdatingAIChatState = false
            }
            return
        }

        // Mirror the tab's collapsed state into the split item.
        if tab.aiChatCollapsed != splitViewItem.isCollapsed {
            if !tab.aiChatCollapsed {
                prepareAIChatWidthBeforeExpand(for: tab)
            }
            isUpdatingAIChatState = true
            animateAIChatCollapseTransition(splitViewItem, collapsed: tab.aiChatCollapsed)
            isUpdatingAIChatState = false
        }
    }
    
    /// Observe a specific tab's AI Chat collapsed state
    private func observeTabAIChatState(_ tab: Tab, splitViewItem: NSSplitViewItem) {
        tab.$aiChatCollapsed
            .dropFirst() // Initial sync happens through `syncAIChatState`.
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak splitViewItem, weak tab] collapsed in
                guard let self, let splitViewItem, let tab else { return }

                // Prevent observer feedback loops.
                guard !self.isUpdatingAIChatState else { return }

                // Ignore collapse changes while AI Chat is disabled — unless a
                // split partner still has chat enabled, in which case this
                // pane participates in the shared expand/collapse state so the
                // sidebar can be toggled from either pane of the split.
                guard tab.aiChatEnabled || self.partnerHasAIChatEnabled() else { return }

                if collapsed != splitViewItem.isCollapsed {
                    if !collapsed {
                        self.prepareAIChatWidthBeforeExpand(for: tab)
                        // When the focused pane in a split expands chat, push
                        // our width to the partner now (before its own expand
                        // observer fires) so both panes open to the same size.
                        if self.browserState?.focusingTab?.guid == tab.guid {
                            self.syncAIChatWidthToSplitPartner(self.lastKnownAIChatWidth)
                        }
                    }
                    // Guard against feedback loops while mirroring KVO back into the tab.
                    self.isUpdatingAIChatState = true
                    self.animateAIChatCollapseTransition(splitViewItem, collapsed: collapsed)
                    self.isUpdatingAIChatState = false
                    self.persistAIChatSidebarStateIfNeeded(for: tab)
                }
            }
            .store(in: &tabObserverCancellables)
    }
    
    /// Observe a specific tab's AI Chat enabled state
    private func observeTabAIChatEnabled(_ tab: Tab, splitViewItem: NSSplitViewItem) {
        tab.$aiChatEnabled
            .dropFirst() // The initial value is handled by the explicit sync step.
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak splitViewItem] enabled in
                guard let self, let splitViewItem else { return }

                // Ignore recursive updates triggered by our own state sync.
                guard !self.isUpdatingAIChatState else { return }

                // In a split the chat is shared. Skip autohide while the
                // partner pane still has chat enabled — collapsing would
                // pull the sidebar out from under the partner's webpage.
                guard !enabled, !self.partnerHasAIChatEnabled() else {
                    return
                }

                if !splitViewItem.isCollapsed {
                    self.isUpdatingAIChatState = true
                    splitViewItem.animator().isCollapsed = true
                    self.isUpdatingAIChatState = false
                }
                // Each pane only observes its own tab's aiChatEnabled, so the
                // partner pane needs an explicit poke to re-evaluate once both
                // panes are NTP and the sidebar must collapse on both sides.
                self.refreshSplitPartnerAIChatSidebarState()
            }
            .store(in: &tabObserverCancellables)
    }

    /// True when this pane sits in a split whose other pane still has AI Chat
    /// enabled. Used by the autohide path so the sidebar stays open while at
    /// least one pane of the split can use chat.
    private func partnerHasAIChatEnabled() -> Bool {
        guard let state = browserState,
              let tab = associatedTab,
              let group = state.splitGroup(forTabId: tab.guid),
              let partnerId = group.partnerTabId(of: tab.guid),
              let partner = state.tabs.first(where: { $0.guid == partnerId }) else {
            return false
        }
        return partner.aiChatEnabled
    }

    /// Ask this pane's split partner controller to re-sync its AI Chat
    /// sidebar against the latest combined state. Used when this pane's
    /// autohide kicks in so the partner pane converges on the new state
    /// rather than holding its own sidebar open.
    private func refreshSplitPartnerAIChatSidebarState() {
        guard let state = browserState,
              let tab = associatedTab,
              let group = state.splitGroup(forTabId: tab.guid),
              let partnerId = group.partnerTabId(of: tab.guid),
              let container = parent as? WebContentContainerViewController,
              let partner = container.findController(forTabId: partnerId),
              partner !== self else {
            return
        }
        partner.refreshAIChatSidebarStateForPartnerNotification()
    }

    /// Re-run the AI Chat sidebar sync against the current tab and partner
    /// states. Called by a split partner that has just flipped its own
    /// `aiChatEnabled` so this pane mirrors the new combined autohide state.
    func refreshAIChatSidebarStateForPartnerNotification() {
        guard let aiChatSplitViewItem, let tab = associatedTab else { return }
        syncAIChatState(from: tab, to: aiChatSplitViewItem)
    }

    private func setupView() {
        // Build the split view that hosts web content and optional AI Chat.
        setupContentSplitView()

        view.addSubview(titleAwareArea)
        titleAwareArea.snp.makeConstraints { make in
            make.leading.trailing.top.equalToSuperview()
            make.height.equalTo(12)
        }

        // Set initial visibility state
        updateHeaderVisibility()

        // Observe configuration changes
        setupConfigObserver()
    }
    
    /// Sets up the internal layout for the left content container.
    private func setupLeftContainerLayout() {
        leftContainerView.wantsLayer = true
        leftContainerView.layer?.cornerCurve = .continuous
        leftContainerView.layer?.cornerRadius = LiquidGlassCompatible.webContentInnerComponentsCornerRadius
        leftContainerView.layer?.masksToBounds = true
        leftContainerView.phiLayer?.backgroundColor = NSColor.white <> NSColor.black
        // Border visibility is updated later based on the current layout mode.
        
        // Pin the header to the top edge of the left container.
        leftContainerView.addSubview(headerView)
        headerView.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview()
            make.top.equalToSuperview()
            headerHeightConstraint = make.height.equalTo(0).constraint
        }
        headerView.onCurrentTabUrlChanged = { [weak self] url in
            self?.updateHeaderVisibility()
        }

        // Reserve a stable slot for the bookmark bar between the header and host.
        leftContainerView.addSubview(bookmarkBarSlotView)
        bookmarkBarSlotView.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview()
            make.top.equalTo(headerView.snp.bottom)
            bookmarkBarHeightConstraint = make.height.equalTo(0).constraint
        }

        // Keep the host view directly below the bookmark slot; corner clipping stays on the parent.
        leftContainerView.addSubview(hostView)
        hostView.wantsLayer = true
        hostView.layer?.masksToBounds = true
        hostView.snp.makeConstraints { make in
            make.leading.trailing.bottom.equalToSuperview()
            make.top.equalTo(bookmarkBarSlotView.snp.bottom)
        }

        leftContainerView.addSubview(webContentProgressBar, positioned: .above, relativeTo: hostView)
        webContentProgressBar.snp.makeConstraints { make in
            make.leading.trailing.equalTo(hostView)
            make.top.equalTo(hostView)
            make.height.equalTo(2)
        }

        installAttachedBookmarkBarIfNeeded()
    }
    
    // MARK: - Content SplitView Setup
    
    /// Builds the split view containing the left content area and AI Chat.
    private func setupContentSplitView() {
        // Rounded container that wraps the split view.
        view.addSubview(splitViewContainer)
        splitViewContainer.wantsLayer = true
        splitViewContainer.layer?.cornerCurve = .continuous
        splitViewContainer.layer?.cornerRadius = LiquidGlassCompatible.webContentContainerCornerRadius
        splitViewContainer.layer?.masksToBounds = true
        splitViewContainer.phiLayer?.setBackgroundColor(ThemedColor.contentOverlayBackground)
        splitViewContainer.snp.makeConstraints { make in
            splitViewLeadingConstraint = make.leading.equalToSuperview().constraint
            make.trailing.bottom.equalToSuperview().inset(WebContentConstant.edgesSpacing)
            make.top.equalToSuperview()
        }
        updateSplitViewLeadingInset()
        
        // Use `PhiSplitView` to hide the default divider styling.
        let phiSplitView = PhiSplitView()
        phiSplitView.isVertical = true
        contentSplitViewController.splitView = phiSplitView
        
        // Embed the split-view controller inside the rounded container.
        addChild(contentSplitViewController)
        splitViewContainer.addSubview(contentSplitViewController.view)
        contentSplitViewController.view.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        
        // Build the left-side content stack.
        setupLeftContainerLayout()
        
        // Wrap the left content so layout mode can adjust its inset.
        leftContainerWrapper.addSubview(leftContainerView)
        leftContainerView.snp.makeConstraints { make in
            leftContainerInsetConstraint = make.edges.equalToSuperview().inset(0).constraint
        }
        
        // Left split item hosts the web content container.
        let leftContainerVC = NSViewController()
        leftContainerVC.view = leftContainerWrapper
        
        webContentSplitViewItem = NSSplitViewItem(viewController: leftContainerVC)
        webContentSplitViewItem.holdingPriority = .init(rawValue: 240)
        contentSplitViewController.addSplitViewItem(webContentSplitViewItem)
        
        // Skip AI Chat entirely in incognito mode.
        guard browserState?.isIncognito != true, let chatVC = embeddedChatViewController else { return }
        
        let aiChatSplitViewItem = NSSplitViewItem(viewController: chatVC)
        aiChatSplitViewItem.minimumThickness = 300
        aiChatSplitViewItem.maximumThickness = 800
        aiChatSplitViewItem.canCollapse = true
        aiChatSplitViewItem.isCollapsed = true
        aiChatSplitViewItem.holdingPriority = .init(rawValue: 260)
        contentSplitViewController.addSplitViewItem(aiChatSplitViewItem)
        self.aiChatSplitViewItem = aiChatSplitViewItem
    }
    
    /// Returns the splitView container's frame in the given coordinate space —
    /// used by the outer-border coordinator on the parent controller.
    func splitViewContainerFrame(in coordView: NSView) -> CGRect {
        splitViewContainer.convert(splitViewContainer.bounds, to: coordView)
    }

    func setSplitViewContainerBorderVisible(_ isVisible: Bool) {
        splitViewContainer.layer?.borderWidth = isVisible ? 1 : 0
        if isVisible {
            splitViewContainer.phiLayer?.setBorderColor(.border)
        }
    }

    /// Returns the actual web-page area (below the header and bookmark bar)
    /// in the given coordinate space. The split-drop hint uses this to
    /// confine its highlight to the page region.
    func pageContentAreaFrame(in coordView: NSView) -> CGRect {
        hostView.convert(hostView.bounds, to: coordView)
    }

    /// Toggles the AI Chat panel when the associated tab allows it.
    func toggleAIChatInTraditionalLayout() {
        guard associatedTab?.aiChatEnabled == true else { return }
        // Updating the tab model is enough; observers drive the UI update.
        associatedTab?.toggleAIChat()
    }

    private func bindContentObservers(for tab: Tab) {
        contentObserverCancellables.removeAll()
        tab.$url
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak tab] url in
                self?.updateContentForTab(tab)
                self?.persistAIChatSidebarStateIfNeeded(for: tab)
                if self?.pendingChromeRefocusOnUrlReady == true,
                   let url,
                   !url.isEmpty {
                    AppLogDebug("🔍 [Focus] URL arrived — retrying Chromium focus (tabGuid: \(tab?.guid ?? -1))")
                    self?.restoreFocusForCurrentTab()
                }
            }
            .store(in: &contentObserverCancellables)
    }

    private func bindProgressObservers(for tab: Tab) {
        progressObserverCancellables.removeAll()
        lastProgressLogBucket = nil
        webContentProgressBar.resetForNewTab()

        AppLogDebug("[ProgressBar] Bind progress observer tabId=\(tab.guid), isNTP=\(tab.isNTP), progress=\(tab.loadingProgress), layoutEnabled=\(webContentProgressBar.isLayoutEnabled)")

        let updateProgress: (CGFloat) -> Void = { [weak self, weak tab] progress in
            guard let self else { return }
            if tab?.isNTP == true {
                self.webContentProgressBar.setProgress(0, animated: false)
            } else {
                self.webContentProgressBar.setProgress(progress, animated: false)
            }
        }

        updateProgress(tab.loadingProgress)
        logProgressIfNeeded(progress: tab.isNTP ? 0 : tab.loadingProgress, tabId: tab.guid, isNTP: tab.isNTP)

        tab.$loadingProgress
            .removeDuplicates()
            .combineLatest(tab.$isLoading)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak tab] progress, isLoading in
                guard let self else { return }
                let isNTP = tab?.isNTP == true
                var effectiveProgress: CGFloat = isNTP ? 0 : progress
                if !isLoading {
                    effectiveProgress = 0
                }
                AppLogDebug("progress: \(progress), isloading: \(isLoading)")
                self.webContentProgressBar.setProgress(effectiveProgress)
                self.logProgressIfNeeded(progress: effectiveProgress, tabId: tab?.guid, isNTP: isNTP)
            }
            .store(in: &progressObserverCancellables)
    }

    private func logProgressIfNeeded(progress: CGFloat, tabId: Int?, isNTP: Bool) {
        let bucket: Int
        if progress <= 0 {
            bucket = 0
        } else if progress >= 1 {
            bucket = 2
        } else {
            bucket = 1
        }
        guard bucket != lastProgressLogBucket else { return }
        lastProgressLogBucket = bucket
        AppLogDebug("[ProgressBar] tabId=\(tabId ?? -1) stateBucket=\(bucket) progress=\(progress) isNTP=\(isNTP)")
    }

    private func updateContentForTab(_ tab: Tab?) {
        guard let tab else { return }
        if browserState?.groupOverviewState != nil {
            return
        }
        // For split members, only the focused VC may run this — same rule the
        // `$splits` subscription enforces. Other entry points (`tab.$url`
        // re-emit on a background member, the deferred re-run below) can fire
        // on a member whose VC is currently behind another's; letting them
        // run installSplitContent steals BOTH panes back into the hidden VC's
        // split host, and the visible VC renders an empty host (both panes
        // blank) until the user switches away and back.
        if browserState?.splitGroup(forTabId: tab.guid) != nil,
           browserState?.focusingTab?.guid != tab.guid {
            return
        }
        // setupView calls this from inside loadView, before the controller's
        // view has been added to its superview — so view.window is nil. In
        // the "Open as Split" flow, state.splits already contains the new
        // split at this point, so installSplitContent runs and reparents the
        // partner pane into a windowless host. The whole subtree then
        // transitions windowless→window in one batch when addSubview finally
        // happens, and RenderWidgetHostViewCocoa for the brand-new tab
        // mis-resumes its compositor through that batch transition — the
        // pane stays blank. Defer until we have a window so the mount is a
        // stable in-window operation.
        if view.window == nil {
            DispatchQueue.main.async { [weak self, weak tab] in
                guard let self, let tab else { return }
                self.updateContentForTab(tab)
            }
            return
        }
        if shouldShowNativeNtp(for: tab) {
            showNativeNtp(for: tab)
        } else if let webView = tab.webContentView {
            showWebContent(webView, tabId: tab.guid)
        }
    }

    /// Re-mount content when this controller becomes current.
    /// One WebContentViewController exists per tab. When two split tabs
    /// trade focus, each `installSplitContent` reparents the partner's
    /// `webContentView` into its own split host, so the previously-active
    /// controller ends up with a split host whose views have been stolen.
    /// Similarly, a controller can be left holding a stale split host
    /// after its split was dissolved while it was inactive. Re-running
    /// the mount path here re-claims views and reconciles the hierarchy.
    func refreshContentForCurrentTab() {
        guard let tab = associatedTab else { return }
        updateContentForTab(tab)
        // Re-attach the AI Chat view synchronously while the outgoing
        // controller is still in-window. Switching the active pane of a split
        // swaps the visible controller; the split shares one chat tab, so its
        // Chromium webContentView must move between the two panes' chat hosts.
        // Doing it here (same-window move) avoids the windowless transition
        // that blanks the renderer — mirrors the split-content remount above.
        if view.window != nil {
            embeddedChatViewController?.reattachAIChatViewIfNeeded()
        }
    }

    /// The active split this controller's tab is part of, or nil.
    /// Content-fullscreen still forces a single-view fallback (the page owns
    /// the whole window). DevTools is now scoped to the inspected pane via
    /// `SplitPaneHostView.attachDevTools(pane:…)`, so we keep rendering the
    /// split when DevTools is open — otherwise focusing the inspected tab
    /// would collapse the split and the inspected page would take over the
    /// whole hostView.
    private func activeSplitForCurrentTab() -> SplitGroup? {
        guard let tab = associatedTab, let state = browserState else { return nil }
        if tab.isInContentFullscreen { return nil }
        return state.splitGroup(forTabId: tab.guid)
    }

    private func partnerTab(for group: SplitGroup, ownTabId: Int) -> Tab? {
        let partnerId = group.primaryTabId == ownTabId ? group.secondaryTabId : group.primaryTabId
        return browserState?.tabs.first { $0.guid == partnerId }
    }

    private func shouldShowNativeNtp(for tab: Tab) -> Bool {
        guard tab.usesNativeNTP else { return false }
        if tab.isNTP {
            return true
        }
        if let url = tab.url, !url.isEmpty {
            return false
        }
        return contentMode != .webContent
    }

    private func showNativeNtp(for tab: Tab) {
        guard let state = browserState else { return }

        let controller: NewTabViewController
        if let existing = nativeNtpController {
            controller = existing
        } else {
            let created = NewTabViewController(state: state)
            nativeNtpController = created
            controller = created
        }

        if controller.parent == nil {
            addChild(controller)
        }

        if controller.view.superview !== hostView {
            hostView.subviews.forEach { $0.removeFromSuperview() }
            hostView.addSubview(controller.view)
            controller.view.snp.makeConstraints { make in
                make.edges.equalToSuperview()
            }
        }

        controller.updateForTab(tab)
        contentMode = .nativeNtp
    }

    private func showWebContent(_ contentView: NSView, tabId: Int) {
        if let group = activeSplitForCurrentTab() {
            installSplitContent(group: group, ownTabId: tabId, ownNativeView: contentView)
            contentMode = .webContent
            updateLeftContainerStyleForCurrentAIChatState()
            return
        }
        // Tear down any leftover split host before re-mounting single content.
        if let existing = currentSplitHost {
            existing.removeFromSuperview()
            currentSplitHost = nil
        }
        // Check if content view is already the primary view in hostView
        if hostView.subviews.contains(contentView),
           contentView.superview === hostView {
            updateLeftContainerStyleForCurrentAIChatState()
            return
        }
        addWebContentView(contentView, tabId: tabId)
        contentMode = .webContent
        updateLeftContainerStyleForCurrentAIChatState()
    }

    /// Mount or update the SplitPaneHostView so that this tab and its partner
    /// render side-by-side. Falls back to single-view if partner's nativeView
    /// is missing (e.g. partner not yet finished loading its WebContents).
    private func installSplitContent(group: SplitGroup,
                                     ownTabId: Int,
                                     ownNativeView: NSView) {
        guard let partner = partnerTab(for: group, ownTabId: ownTabId),
              let partnerNativeView = partner.webContentView else {
            // Partner not ready — show ourself alone for now; the splits
            // subscription will re-trigger when the partner's view arrives.
            addWebContentView(ownNativeView, tabId: ownTabId)
            return
        }

        // Give the new tab's webContentView a window via hostView before the
        // split host moves it. In the "Open as Split" flow this view arrives
        // orphan; a direct addSubview into the split host would be a
        // windowless→window transition that RenderWidgetHostViewCocoa does
        // not always cleanly resume — the new pane stays blank. Parking it
        // in the (already-in-window) hostView first lets the renderer's
        // window transition happen in a stable container, so the subsequent
        // split-host attach is a same-window move that skips the transition.
        if ownNativeView.window == nil, hostView.window != nil {
            ownNativeView.removeFromSuperview()
            hostView.addSubview(ownNativeView)
        }
        if partnerNativeView.window == nil, hostView.window != nil {
            partnerNativeView.removeFromSuperview()
            hostView.addSubview(partnerNativeView)
        }

        let (primaryView, secondaryView): (NSView, NSView)
        if group.primaryTabId == ownTabId {
            primaryView = ownNativeView
            secondaryView = partnerNativeView
        } else {
            primaryView = partnerNativeView
            secondaryView = ownNativeView
        }

        let host: SplitPaneHostView
        if let existing = currentSplitHost, existing.superview === hostView {
            existing.update(primary: primaryView, secondary: secondaryView)
            existing.update(layout: group.layout, ratio: group.ratio)
            host = existing
        } else {
            // Mount the host BEFORE attaching panes: SplitPaneHostView.init no
            // longer reparents the Chromium native views, because doing so
            // while the host is windowless tears down the renderer compositor
            // and blanks both panes. Once the host is in hostView it has a
            // window, and update(primary:secondary:) can move both panes in
            // atomically without a viewWillMoveToWindow(nil) transition.
            //
            // Do NOT pre-clear hostView.subviews here. When the new tab in an
            // "Open as Split" flow gets focused before the split notification
            // arrives, switchToWebContentController has already mounted its
            // webContentView directly in hostView. Wiping subviews first would
            // briefly orphan that view (windowless) and the renderer would not
            // cleanly resume, blanking the new-tab pane. Mount the host on top
            // instead, then let update() atomically reparent both panes (a
            // same-window addSubview move skips viewWillMoveToWindow(nil)).
            let newHost = SplitPaneHostView(layout: group.layout, ratio: group.ratio)
            newHost.translatesAutoresizingMaskIntoConstraints = false
            hostView.addSubview(newHost)
            newHost.snp.makeConstraints { $0.edges.equalToSuperview() }
            newHost.update(primary: primaryView, secondary: secondaryView)
            // Drop anything else still parked in hostView (e.g. a stale
            // native-NTP view from a prior render). The two panes already
            // moved into newHost above, so they will not match here.
            for subview in hostView.subviews where subview !== newHost {
                subview.removeFromSuperview()
            }
            currentSplitHost = newHost
            host = newHost
        }

        // installSplitContent only runs on the focused VC's mount path, so
        // the host's "focused pane" is always the side that matches ownTabId.
        host.focusedPane = (group.primaryTabId == ownTabId) ? .primary : .secondary

        // After the panes are mounted, replay any DevTools that was already
        // open on either side. Covers split rebuild on controller switch and
        // DevTools-already-open-before-split cases.
        restorePerPaneDevToolsState(host: host, group: group)

        let splitId = group.id
        host.onRatioCommit = { [weak self] newRatio in
            self?.browserState?.updateSplitRatio(splitId, ratio: newRatio)
        }

        // Clicking either pane focuses that pane's tab — same as native
        // browsers. The host reports interactions in its own coordinates
        // (.primary / .secondary); we map back to Chromium's primary/
        // secondary tab ids using the group.
        let primaryTabId = group.primaryTabId
        let secondaryTabId = group.secondaryTabId
        host.onPaneInteraction = { [weak self] pane in
            guard let self else { return }
            let targetTabId = (pane == .primary) ? primaryTabId : secondaryTabId
            guard let tab = self.browserState?.tabs.first(where: { $0.guid == targetTabId }),
                  !tab.isActive else { return }
            tab.makeSelfActive()
        }
    }

    private weak var currentSplitHost: SplitPaneHostView?

    private var isSplitContentMounted: Bool {
        guard let currentSplitHost else { return false }
        return currentSplitHost.superview === hostView
    }

    private func addWebContentView(_ contentView: NSView, tabId: Int) {
        hostView.subviews.forEach { $0.removeFromSuperview() }
        contentView.translatesAutoresizingMaskIntoConstraints = true
        contentView.autoresizingMask = []
        contentView.frame = hostView.bounds
        hostView.addSubview(contentView)

        if let tab = associatedTab, tab.devToolsAttached {
            // Tab has DevTools: restore DevTools view hierarchy and manual frame layout.
            restoreDevToolsState()
        } else {
            // Safety net: clear any stuck-paused state left behind by a prior
            // DevTools session that never got a clean detach (renderer crash,
            // tab cleanup racing the Chromium detach callback, etc.). Without
            // this, hostView.layout()'s frame-sync stays disabled and plain
            // web content no longer auto-resizes with the window.
            if hostView.isFrameSyncPaused {
                AppLogInfo("[DevTools] clearing stale isFrameSyncPaused on plain webContent install (tabId=\(tabId))")
                hostView.isFrameSyncPaused = false
            }
        }
    }

    private func updateGroupOverviewState(_ state: GroupOverviewState?) {
        guard let browserState else { return }
        guard let state else {
            hideGroupOverviewIfNeeded()
            updateContentForTab(associatedTab)
            return
        }
        showGroupOverview(token: state.groupToken, browserState: browserState)
    }

    private func showGroupOverview(token: String, browserState: BrowserState) {
        if case .groupOverview(let currentToken) = contentMode,
           currentToken == token {
            return
        }

        hostView.subviews.forEach { $0.removeFromSuperview() }
        groupOverviewController?.view.removeFromSuperview()
        groupOverviewController?.removeFromParent()

        let controller = GroupOverviewViewController(browserState: browserState,
                                                     groupToken: token)
        addChild(controller)
        hostView.addSubview(controller.view)
        controller.view.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        groupOverviewController = controller
        contentMode = .groupOverview(token: token)
    }

    private func hideGroupOverviewIfNeeded() {
        guard groupOverviewController != nil else { return }
        groupOverviewController?.view.removeFromSuperview()
        groupOverviewController?.removeFromParent()
        groupOverviewController = nil
        if case .groupOverview = contentMode {
            contentMode = nil
        }
    }

    // MARK: - Content Fullscreen (HTML5 requestFullscreen)

    deinit {
        // If this controller is being torn down while still in content
        // fullscreen, hostView sits under window.contentView — NOT inside
        // self.view's subtree — so normal view-hierarchy teardown leaves
        // it orphaned on top of the window. This happens specifically on
        // close: Chromium's async DidToggleFullscreenModeForTab(false) can
        // arrive after TabsProxy::OnTabWillBeRemoved has already erased the
        // observer, so the terminal exit event never reaches Mac. Detach
        // here as the last-resort guarantee.
        if savedHostViewSuperview != nil {
            hostView.removeFromSuperview()
        }
    }

    /// Rebind the content-fullscreen observer to the given tab. Called from
    /// `updateAssociatedTab`. If the controller is still in fullscreen from a
    /// previous tab (shouldn't happen under normal flow, but guard anyway),
    /// restore hostView first so re-binding starts from a clean state.
    private func rebindContentFullscreenObserver(for tab: Tab?) {
        contentFullscreenCancellable = nil
        // Force-exit any lingering fullscreen state before switching tabs.
        // Under normal flow Chromium fires ExitFullscreen on tab deactivate,
        // which already flips isInContentFullscreen to false upstream, but the
        // visible guarantee must be that hostView is back in its original
        // superview before we attach to a different tab's state.
        applyContentFullscreenState(false)

        guard let tab else { return }
        contentFullscreenCancellable = tab.$isInContentFullscreen
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isFullscreen in
                self?.applyContentFullscreenState(isFullscreen)
            }
    }

    /// Enter or exit HTML5 content fullscreen by re-parenting `hostView`
    /// directly under `window.contentView`. This covers every other Phi
    /// chrome element (tab strip, sidebar, header, AI chat, traffic lights)
    /// in one move, and needs no per-element visibility toggling.
    private func applyContentFullscreenState(_ isFullscreen: Bool) {
        if isFullscreen {
            guard savedHostViewSuperview == nil else { return }
            guard let window = hostView.window,
                  let contentView = window.contentView else {
                // The controller's view is not currently in a window (cached
                // controller for an inactive tab). Ignore — viewDidAppear
                // catches up once the view reaches a window.
                return
            }
            savedHostViewSuperview = hostView.superview
            // Deactivate progress bar constraints before removing hostView —
            // they reference hostView and would otherwise be torn down by
            // AutoLayout with an `unsatisfiable` log.
            webContentProgressBar.snp.removeConstraints()
            hostView.removeFromSuperview()
            contentView.addSubview(hostView, positioned: .above, relativeTo: nil)
            hostView.snp.remakeConstraints { make in
                make.edges.equalToSuperview()
            }
            // Re-parent transiently detaches webContentView from the window,
            // which causes NSWindow to clear first responder. Without this,
            // keyboard events (including ESC to exit fullscreen) never reach
            // Chromium and the "Press Esc to exit full screen" toast is
            // inert until the user clicks into the video area.
            restoreWebContentFirstResponder()
        } else {
            guard let original = savedHostViewSuperview else { return }
            hostView.removeFromSuperview()
            original.addSubview(hostView)
            hostView.snp.remakeConstraints { make in
                make.leading.trailing.bottom.equalToSuperview()
                make.top.equalTo(bookmarkBarSlotView.snp.bottom)
            }
            if webContentProgressBar.superview === original {
                original.addSubview(webContentProgressBar,
                                    positioned: .above,
                                    relativeTo: hostView)
                webContentProgressBar.snp.remakeConstraints { make in
                    make.leading.trailing.equalTo(hostView)
                    make.top.equalTo(hostView)
                    make.height.equalTo(2)
                }
            }
            savedHostViewSuperview = nil
            // Re-clear AppKit's kCAFilterPlusL after moving hostView back into
            // the ColoredVisualEffectView hierarchy (matches DevTools paths).
            hostView.scheduleVibrancyClear()
            // Same first-responder recovery as on entry (removeFromSuperview
            // resets responder chain in both directions).
            restoreWebContentFirstResponder()
        }
    }

    private func restoreWebContentFirstResponder() {
        guard let tab = associatedTab,
              let webView = tab.webContentView,
              let window = hostView.window else { return }
        window.makeFirstResponder(webView)
        // makeFirstResponder puts Cocoa's responder chain at webView, but
        // Chromium's internal focus tracker also needs an explicit nudge to
        // route keyboard events to the renderer — without it, ESC on the
        // "Press Esc to exit full screen" toast doesn't reach the fullscreen
        // handler until the user clicks inside the video area. Use
        // restoreFocus() (not focus()) so the page's previously focused
        // element survives the fullscreen detach/reattach: on macOS,
        // WebContentsViewMac::Focus() clears the stored focus target.
        guard let wrapper = tab.webContentWrapper,
              wrapper.responds(to: #selector(WebContentWrapper.restoreFocus)) else {
            return
        }
        wrapper.restoreFocus()
    }

    // MARK: - DevTools Embedding

    /// Attach a docked DevTools view to this tab's hostView.
    /// DevTools goes full-size below webContentView; webContentView stays full-size
    /// initially (covering DevTools) until the first bounds callback shrinks it.
    ///
    /// When this tab is currently a pane of a split mounted in this
    /// controller's `currentSplitHost`, the DevTools view is scoped to that
    /// pane's container instead of `hostView` — otherwise it would cover the
    /// whole split, hiding the other pane.
    func attachDevTools(view devToolsView: NSView) {
        guard let tab = associatedTab else { return }
        if let host = currentSplitHost,
           let pane = splitPane(forTabId: tab.guid) {
            attachDevToolsToPane(tabId: tab.guid,
                                 pane: pane,
                                 devToolsView: devToolsView,
                                 host: host,
                                 tab: tab)
            return
        }
        guard let webContentView = tab.webContentView else { return }

        // Idempotent: same view already attached in hostView — no-op.
        // Right-click "Inspect" on an already-open DevTools re-enters Show()'s
        // docked path and sends another OnDevToolsDidAttach; skip it.
        if tab.devToolsAttached, tab.devToolsView === devToolsView,
           devToolsView.superview === hostView {
            return
        }

        // Defensive: if webContentView is not in hostView (e.g. native NTP overlay),
        // transition to web content mode first so relativeTo: is valid.
        if webContentView.superview !== hostView {
            hostView.subviews.forEach { $0.removeFromSuperview() }
            hostView.addSubview(webContentView)
            contentMode = .webContent
        }

        // Force layer-backing before addSubview so the layer exists when Cocoa
        // establishes the view's position in a layer-hosting hierarchy.
        devToolsView.wantsLayer = true

        // Pause hostView.layout()'s frame-sync: it forces any
        // translatesAutoresizingMaskIntoConstraints=true subview to hostView.bounds.
        // With DevTools attached we need webContentView at the partial bounds
        // DevTools JS computes — otherwise the next layout pass overrides our
        // explicit frame and webContentView covers the whole hostView (hiding
        // DevTools and routing all events to the webpage).
        hostView.isFrameSyncPaused = true

        // Defensive: a stale devToolsView from a prior attach may still be in
        // hostView if Chromium re-sends attach with a different NSView instance
        // without a detach in between (e.g. renderer restart). Remove it so we
        // don't leak orphaned subviews.
        if tab.devToolsAttached, let staleView = tab.devToolsView, staleView !== devToolsView {
            AppLogWarn("[DevTools] attach received with new view while previous view still attached; removing stale view")
            staleView.removeFromSuperview()
        }

        // Insert DevTools below webContentView (Z-order: DevTools behind content)
        hostView.addSubview(devToolsView, positioned: .below, relativeTo: webContentView)
        devToolsView.frame = hostView.bounds
        devToolsView.autoresizingMask = [.width, .height]

        // Switch webContentView from auto-layout to manual frame management.
        // Clear autoresizingMask so the mask-to-constraints translation doesn't
        // generate fill-superview constraints that fight our explicit frame.
        webContentView.snp.removeConstraints()
        webContentView.autoresizingMask = []
        webContentView.translatesAutoresizingMaskIntoConstraints = true
        webContentView.frame = hostView.bounds

        // Update tab state (overwrite any stale values)
        tab.devToolsAttached = true
        tab.devToolsView = devToolsView
        tab.inspectedPageBounds = nil
        tab.hideInspectedContents = false

        hostView.scheduleVibrancyClear()
    }

    /// Detach DevTools from this tab's hostView and restore webContentView to full size.
    func detachDevTools() {
        guard let tab = associatedTab else { return }
        if let host = currentSplitHost,
           let pane = splitPane(forTabId: tab.guid) {
            detachDevToolsFromPane(tabId: tab.guid, pane: pane, host: host, tab: tab)
            return
        }

        // Remove DevTools view
        tab.devToolsView?.removeFromSuperview()

        // Restore webContentView to auto-layout (full-size)
        if let webContentView = tab.webContentView, webContentView.superview === hostView {
            webContentView.translatesAutoresizingMaskIntoConstraints = false
            webContentView.snp.remakeConstraints { make in
                make.edges.equalToSuperview()
            }
            webContentView.isHidden = false
        }

        // Clear tab state
        tab.devToolsAttached = false
        tab.devToolsView = nil
        tab.inspectedPageBounds = nil
        tab.hideInspectedContents = false

        // Resume frame-sync last, after webContentView is back on SnapKit fill
        // constraints. Symmetric with attachDevTools (which pauses before any
        // mutation) so no layout pass can fire against a half-restored view.
        hostView.isFrameSyncPaused = false

        hostView.scheduleVibrancyClear()
    }

    /// Update the inspected page bounds (called continuously as DevTools JS resizes).
    /// Bounds are in web coordinate system (origin top-left, relative to hostView
    /// for single-content mode, or relative to the pane container for split mode).
    func updateInspectedPageBounds(_ bounds: CGRect, hide: Bool) {
        guard let tab = associatedTab else { return }
        if let host = currentSplitHost,
           let pane = splitPane(forTabId: tab.guid) {
            updateInspectedPageBoundsForPane(tabId: tab.guid,
                                             pane: pane,
                                             bounds: bounds,
                                             hide: hide,
                                             host: host,
                                             tab: tab)
            return
        }
        guard let webContentView = tab.webContentView,
              webContentView.superview === hostView else { return }

        // Cache for tab switch restore
        tab.inspectedPageBounds = bounds
        tab.hideInspectedContents = hide

        if hide {
            webContentView.isHidden = true
            return
        }

        webContentView.isHidden = false

        // Convert from web coordinates (origin top-left) to NSView (origin bottom-left).
        let hostHeight = hostView.bounds.height
        let flippedY = hostHeight - bounds.origin.y - bounds.size.height
        let nsRect = NSRect(x: bounds.origin.x, y: flippedY,
                            width: bounds.size.width, height: bounds.size.height)
        webContentView.frame = nsRect
    }

    // MARK: - DevTools (split-pane scoped)

    /// Returns the pane (`.primary` / `.secondary`) the given tab currently
    /// occupies in this controller's split host, or `nil` when the tab isn't
    /// part of a split mounted in this controller. Routing helper for the
    /// DevTools attach/detach/bounds-update paths.
    func splitPane(forTabId tabId: Int) -> SplitPaneHostView.Pane? {
        guard currentSplitHost != nil,
              let group = browserState?.splitGroup(forTabId: tabId) else { return nil }
        return group.primaryTabId == tabId ? .primary : .secondary
    }

    /// Attach DevTools to a specific pane of the current split host. Lets the
    /// container reroute DevTools events for the partner pane (which lives in
    /// a different tab's controller) into this controller's mounted split.
    func attachDevToolsToPane(tabId: Int,
                              pane: SplitPaneHostView.Pane,
                              devToolsView: NSView) {
        guard let host = currentSplitHost,
              let tab = browserState?.tabs.first(where: { $0.guid == tabId }) else { return }
        attachDevToolsToPane(tabId: tabId,
                             pane: pane,
                             devToolsView: devToolsView,
                             host: host,
                             tab: tab)
    }

    func detachDevToolsFromPane(tabId: Int, pane: SplitPaneHostView.Pane) {
        guard let host = currentSplitHost,
              let tab = browserState?.tabs.first(where: { $0.guid == tabId }) else { return }
        detachDevToolsFromPane(tabId: tabId, pane: pane, host: host, tab: tab)
    }

    func updateInspectedPageBoundsForPane(tabId: Int,
                                          pane: SplitPaneHostView.Pane,
                                          bounds: CGRect,
                                          hide: Bool) {
        guard let host = currentSplitHost,
              let tab = browserState?.tabs.first(where: { $0.guid == tabId }) else { return }
        updateInspectedPageBoundsForPane(tabId: tabId,
                                         pane: pane,
                                         bounds: bounds,
                                         hide: hide,
                                         host: host,
                                         tab: tab)
    }

    private func attachDevToolsToPane(tabId: Int,
                                      pane: SplitPaneHostView.Pane,
                                      devToolsView: NSView,
                                      host: SplitPaneHostView,
                                      tab: Tab) {
        if tab.devToolsAttached, tab.devToolsView === devToolsView,
           devToolsView.superview != nil {
            return
        }
        if tab.devToolsAttached, let stale = tab.devToolsView, stale !== devToolsView {
            stale.removeFromSuperview()
        }
        host.attachDevTools(pane: pane, devToolsView: devToolsView)
        tab.devToolsAttached = true
        tab.devToolsView = devToolsView
        tab.inspectedPageBounds = nil
        tab.hideInspectedContents = false
    }

    private func detachDevToolsFromPane(tabId: Int,
                                        pane: SplitPaneHostView.Pane,
                                        host: SplitPaneHostView,
                                        tab: Tab) {
        host.detachDevTools(pane: pane)
        tab.devToolsAttached = false
        tab.devToolsView = nil
        tab.inspectedPageBounds = nil
        tab.hideInspectedContents = false
    }

    private func updateInspectedPageBoundsForPane(tabId: Int,
                                                  pane: SplitPaneHostView.Pane,
                                                  bounds: CGRect,
                                                  hide: Bool,
                                                  host: SplitPaneHostView,
                                                  tab: Tab) {
        tab.inspectedPageBounds = bounds
        tab.hideInspectedContents = hide
        host.updateInspectedPageBounds(pane: pane, bounds: bounds, hide: hide)
    }

    /// After a split host is created / reused / re-attached, re-mount any
    /// pre-existing per-tab DevTools view into the matching pane container.
    /// Handles three cases at once: (a) the user opens DevTools on a tab that
    /// is already in a split, (b) the user joins a tab with attached DevTools
    /// into a new split (DevTools needs to migrate from hostView), and
    /// (c) the controller-switch path where the split host is rebuilt from
    /// scratch (DevTools needs to migrate from the previous host).
    private func restorePerPaneDevToolsState(host: SplitPaneHostView, group: SplitGroup) {
        guard let state = browserState else { return }
        for (tabId, pane) in [(group.primaryTabId, SplitPaneHostView.Pane.primary),
                              (group.secondaryTabId, SplitPaneHostView.Pane.secondary)] {
            guard let tab = state.tabs.first(where: { $0.guid == tabId }),
                  tab.devToolsAttached,
                  let devToolsView = tab.devToolsView else { continue }
            host.attachDevTools(pane: pane, devToolsView: devToolsView)
            if let cachedBounds = tab.inspectedPageBounds {
                host.updateInspectedPageBounds(pane: pane,
                                               bounds: cachedBounds,
                                               hide: tab.hideInspectedContents)
            }
        }
        // The hostView-level `isFrameSyncPaused` only matters for content
        // directly in hostView. In split mode that's only the splitHost
        // (snp-constrained, so the flag doesn't affect it). Resume here so a
        // future single-content transition starts from a clean state.
        if hostView.isFrameSyncPaused {
            hostView.isFrameSyncPaused = false
        }
    }

    /// Restore DevTools state when switching back to a tab that has DevTools attached.
    /// Called by WebContentContainerViewController during tab switch.
    func restoreDevToolsState() {
        guard let tab = associatedTab, tab.devToolsAttached,
              let devToolsView = tab.devToolsView else { return }

        // Pause frame-sync (see attachDevTools) so webContentView's partial
        // frame isn't overridden by hostView.layout() on the next pass.
        hostView.isFrameSyncPaused = true

        // Re-add DevTools view if not already in hostView
        if devToolsView.superview !== hostView {
            let webContentView = tab.webContentView
            devToolsView.wantsLayer = true
            hostView.addSubview(devToolsView, positioned: .below, relativeTo: webContentView)
            devToolsView.frame = hostView.bounds
            devToolsView.autoresizingMask = [.width, .height]
        }

        // Restore webContentView to manual frame mode
        if let webContentView = tab.webContentView, webContentView.superview === hostView {
            webContentView.snp.removeConstraints()
            webContentView.autoresizingMask = []  // see attachDevTools for why
            webContentView.translatesAutoresizingMaskIntoConstraints = true

            // Restore cached bounds, or full-size if no cached bounds yet
            if let cachedBounds = tab.inspectedPageBounds {
                updateInspectedPageBounds(cachedBounds, hide: tab.hideInspectedContents)
            } else {
                webContentView.frame = hostView.bounds
            }
        }

        hostView.scheduleVibrancyClear()
    }

    // MARK: - Bookmark Bar Hosting

    /// Update headerView visibility based on configuration
    /// Note: topBarView is now managed by WebContentContainerViewController
    private func updateHeaderVisibility() {
        let layoutMode = PhiPreferences.GeneralSettings.loadLayoutMode()
        let navigationAtTop = layoutMode.showsNavigationAtTop
        let traditionalLayout = layoutMode.isTraditional
        let bookmarkCount = attachedBookmarkBar?.bookmarkCount ?? 0
        
        // Update container styling before toggling visibility.
        let isAIChatExpanded = aiChatSplitViewItem?.isCollapsed == false
        updateLeftContainerStyle(isAIChatExpanded: isAIChatExpanded)

        if traditionalLayout {
            // Traditional layout shows the header and optional bookmark bar.
            // topBar is now managed by WebContentContainerViewController
            titleAwareArea.isHidden = true // Avoid interfering with tab dragging.

            headerView.isHidden = false
            headerHeightConstraint?.update(offset: WebContentConstant.headerHeight)
        } else if navigationAtTop {
            // Navigation-at-top mode shows only the header.
            titleAwareArea.isHidden = false

            headerView.isHidden = false
            headerHeightConstraint?.update(offset: WebContentConstant.headerHeight)
        } else {
            // Default sidebar layout hides the top header.
            titleAwareArea.isHidden = false

            headerView.isHidden = true
            headerHeightConstraint?.update(offset: 0)
        }

        updateBookmarkBarVisibility(bookmarkCount: bookmarkCount)

        let isDefaultLayout = !navigationAtTop && !traditionalLayout
        updateWebContentProgressBarVisibility(isDefaultLayout: isDefaultLayout)
        updateSplitViewLeadingInset()
    }

    /// Attach a bookmark bar into the stable bookmark slot.
    func attachBookmarkBar(_ bookmarkBar: BookmarkBar) {
        if attachedBookmarkBar === bookmarkBar {
            installAttachedBookmarkBarIfNeeded()
            updateHeaderVisibility()
            return
        }

        detachBookmarkBarIfAttached()
        attachedBookmarkBar = bookmarkBar

        installAttachedBookmarkBarIfNeeded()
        updateHeaderVisibility()
    }

    /// Detach the currently attached bookmark bar, if any.
    /// The shared bar's active state is driven by updateBookmarkBarVisibility
    /// based on layout/preferences; we must not deactivate here, otherwise
    /// every tab switch would tear down and rebuild BookmarkItemViews and
    /// reload favicons, producing a visible flicker.
    func detachBookmarkBarIfAttached() {
        guard let attachedBookmarkBar else {
            updateBookmarkBarVisibility(bookmarkCount: 0)
            return
        }

        let bookmarkCount = attachedBookmarkBar.bookmarkCount
        if attachedBookmarkBar.superview === bookmarkBarSlotView {
            attachedBookmarkBar.removeFromSuperview()
        }
        self.attachedBookmarkBar = nil
        updateBookmarkBarVisibility(bookmarkCount: bookmarkCount)
    }

    /// Update bookmark bar visibility and the slot height for the current layout mode.
    func updateBookmarkBarVisibility(bookmarkCount: Int) {
        if browserState?.isIncognito == true {
            attachedBookmarkBar?.setActive(false)
            bookmarkBarSlotView.isHidden = true
            bookmarkBarHeightConstraint?.update(offset: 0)
            attachedBookmarkBar?.isHidden = true
            return
        }

        let layoutMode = PhiPreferences.GeneralSettings.loadLayoutMode()
        let traditionalLayout = layoutMode.isTraditional
        let alwaysShowBookmarkBar = PhiPreferences.GeneralSettings.alwaysShowBookmarkBar.loadValue()
        let showBookmarkBarOnNewTabPage = PhiPreferences.GeneralSettings.showBookmarkBarOnNewTabPage.loadValue()
        let isNewTabPage = associatedTab?.isNTP == true
        let isNativeNtpContext = associatedTab?.usesNativeNTP == true &&
            (associatedTab?.isNTP == true || associatedTab?.url?.isEmpty != false)

        let shouldShowBookmarkBar: Bool = {
            guard traditionalLayout else { return false }
            if bookmarkCount == 0 {
                return showBookmarkBarOnNewTabPage && isNativeNtpContext
            }
            if alwaysShowBookmarkBar { return true }
            if showBookmarkBarOnNewTabPage && (isNativeNtpContext || isNewTabPage) { return true }
            return false
        }()

        // Keep data subscriptions alive whenever the bar could potentially appear.
        // When preferences make it impossible to show, deactivate to avoid rendering
        // overhead. Preference changes trigger updateHeaderVisibility via
        // UserDefaults.didChangeNotification, so re-activation happens automatically.
        let bookmarkBarSupported = traditionalLayout && (alwaysShowBookmarkBar || showBookmarkBarOnNewTabPage)
        attachedBookmarkBar?.setActive(bookmarkBarSupported)

        bookmarkBarSlotView.isHidden = !shouldShowBookmarkBar
        bookmarkBarHeightConstraint?.update(offset: shouldShowBookmarkBar ? WebContentConstant.bookmarkBarHeight : 0)
        attachedBookmarkBar?.isHidden = !shouldShowBookmarkBar
    }

    private func installAttachedBookmarkBarIfNeeded() {
        guard let attachedBookmarkBar else { return }
        if attachedBookmarkBar.superview !== bookmarkBarSlotView {
            attachedBookmarkBar.removeFromSuperview()
            bookmarkBarSlotView.addSubview(attachedBookmarkBar)
            attachedBookmarkBar.snp.makeConstraints { make in
                make.edges.equalToSuperview()
            }
        }
    }

    private func updateWebContentProgressBarVisibility(isDefaultLayout: Bool) {
        webContentProgressBar.isLayoutEnabled = isDefaultLayout
    }
    
    /// Updates left-container border and inset styling for AI Chat state.
    /// - Parameter isAIChatExpanded: Whether the AI Chat sidebar is expanded.
    private func updateLeftContainerStyle(isAIChatExpanded: Bool) {
        let isPerformanceSplitContent =
            PhiPreferences.GeneralSettings.loadLayoutMode() == .performance &&
            isSplitContentMounted
        let shouldSeparateExpandedChat = isAIChatExpanded && !isPerformanceSplitContent

        if shouldSeparateExpandedChat {
            leftContainerView.layer?.borderWidth = 1
            leftContainerView.phiLayer?.setBorderColor(.border)
            leftContainerInsetConstraint?.update(inset: WebContentConstant.contentEdgeSpacing)
        } else {
            leftContainerView.layer?.borderWidth = 0
            leftContainerInsetConstraint?.update(inset: 0)
        }
    }

    private func updateLeftContainerStyleForCurrentAIChatState() {
        updateLeftContainerStyle(isAIChatExpanded: aiChatSplitViewItem?.isCollapsed == false)
    }
    
    /// Collapses AI Chat when the associated tab disables it.
    private func collapseAIChatIfNeeded() {
        if aiChatSplitViewItem?.isCollapsed == false {
            aiChatSplitViewItem?.animator().isCollapsed = true
        }
    }

    /// Animate AI Chat sidebar expand/collapse with proper width handling.
    ///
    /// For **expand**: temporarily raises `minimumThickness` to the pending
    /// cached width so NSSplitView's uncollapse animation targets the correct
    /// width directly — avoiding the default "expand to minimumThickness then
    /// jump" visual artifact.  The original `minimumThickness` is restored in
    /// the completion handler so the user can still freely resize afterwards.
    ///
    /// - Important: Callers must set `isUpdatingAIChatState = true` **before**
    ///   invoking this method and reset it afterwards to prevent reentrant KVO
    ///   loops.
    private func animateAIChatCollapseTransition(
        _ splitViewItem: NSSplitViewItem,
        collapsed: Bool
    ) {
        let expanding = !collapsed
        isAnimatingAIChatExpansion = expanding

        // For expand: temporarily raise minimumThickness so the uncollapse
        // animation targets the cached width instead of the default minimum.
        var savedMinThickness: CGFloat?
        if expanding, let targetWidth = pendingAIChatWidthRestore {
            savedMinThickness = splitViewItem.minimumThickness
            let clampedTarget = min(
                max(targetWidth, savedMinThickness ?? targetWidth),
                splitViewItem.maximumThickness
            )
            splitViewItem.minimumThickness = clampedTarget
            AppLogDebug("[AIChatSidebarCache] temporarily set minimumThickness=\(clampedTarget) for expand animation (original=\(savedMinThickness ?? 0))")
        }

        hostView.isFrameSyncPaused = true

        NSAnimationContext.runAnimationGroup({ _ in
            splitViewItem.animator().isCollapsed = collapsed
        }, completionHandler: { [weak self, weak splitViewItem] in
            guard let self else { return }
            if let savedMinThickness, let splitViewItem {
                splitViewItem.minimumThickness = savedMinThickness
                AppLogDebug("[AIChatSidebarCache] restored minimumThickness=\(savedMinThickness)")
            }

            // If DevTools is docked, it owns hostView.isFrameSyncPaused (keeps it
            // true for the duration of the attachment) and manages webContentView's
            // partial frame explicitly via DevTools JS bounds. Resetting the flag
            // or force-syncing here would collapse webContentView to hostView.bounds,
            // hiding DevTools and routing events to the webpage.
            if self.associatedTab?.devToolsAttached != true {
                self.hostView.isFrameSyncPaused = false
                self.hostView.forceSyncAllSubviewFrames()
            }

            self.isAnimatingAIChatExpansion = false
            if expanding {
                self.pendingAIChatWidthRestore = nil
                AppLogDebug("[AIChatSidebarCache] expand animation completed, cleared pendingAIChatWidthRestore")
            }
        })
    }

    private func clampAIChatWidth(_ width: CGFloat) -> CGFloat {
        guard let aiChatSplitViewItem else { return width }
        return min(max(width, aiChatSplitViewItem.minimumThickness), aiChatSplitViewItem.maximumThickness)
    }

    private func currentAIChatWidth() -> CGFloat? {
        guard let aiChatSplitViewItem else { return nil }
        let width = aiChatSplitViewItem.viewController.view.frame.width
        if width > 0 {
            return clampAIChatWidth(width)
        }
        return clampAIChatWidth(lastKnownAIChatWidth)
    }

    /// Determine the target width and set `pendingAIChatWidthRestore` before an
    /// expand animation.
    ///
    /// On the **first** expand during this controller's lifetime, the width is
    /// read from the per-URL cache (via `AIChatSidebarStateStore`).  After that,
    /// `lastKnownAIChatWidth` (maintained by the frame-change observer) is used.
    private func prepareAIChatWidthBeforeExpand(for tab: Tab) {
        guard let url = tab.url else { return }

        let targetWidth: CGFloat
        if !hasRestoredAIChatWidth,
           browserState?.isIncognito != true,
           tab.aiChatEnabled,
           let cached = AIChatSidebarStateStore.shared.state(for: url) {
            targetWidth = clampAIChatWidth(CGFloat(cached.width))
            hasRestoredAIChatWidth = true
            AppLogDebug("[AIChatSidebarCache] first expand — restored from cache url=\(url) width=\(targetWidth)")
        } else {
            targetWidth = clampAIChatWidth(lastKnownAIChatWidth)
            AppLogDebug("[AIChatSidebarCache] expand — using lastKnownAIChatWidth url=\(url) width=\(targetWidth)")
        }

        pendingAIChatWidthRestore = targetWidth

        // Set preferredThicknessFraction as a hint for NSSplitView.
        if let aiChatSplitViewItem,
           let splitView = contentSplitViewController.splitView as NSSplitView?,
           splitView.bounds.width > 0 {
            let fraction = min(max(targetWidth / splitView.bounds.width, 0.0), 1.0)
            aiChatSplitViewItem.preferredThicknessFraction = fraction
        }
    }


    private func persistAIChatSidebarStateIfNeeded(for tab: Tab?) {
        guard browserState?.isIncognito != true,
              let tab,
              tab.aiChatEnabled,
              let url = tab.url else {
            return
        }

        let isCollapsed = aiChatSplitViewItem?.isCollapsed ?? true
        let width: CGFloat
        if isCollapsed {
            // Never overwrite persisted width with a default value while sidebar is collapsed.
            guard let cachedState = AIChatSidebarStateStore.shared.cachedState(for: url) else { return }
            width = clampAIChatWidth(CGFloat(cachedState.width))
        } else {
            guard let expandedWidth = currentAIChatWidth() else { return }
            width = expandedWidth
        }

        AIChatSidebarStateStore.shared.record(
            urlString: url,
            isCollapsed: isCollapsed,
            width: width
        )
    }

    /// Observe configuration changes
    private func setupConfigObserver() {
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateHeaderVisibility()
            }
            .store(in: &cancellables)
    }

    // MARK: - Agent Animation Overlay

    private func updateAgentAnimationOverlay() {
        guard let tab = associatedTab else {
            hideAgentAnimationOverlay()
            return
        }
        if AgentAnimationManager.shared.isActive(for: tab.guid) {
            showAgentAnimationOverlay()
        } else {
            hideAgentAnimationOverlay()
        }
    }

    private func showAgentAnimationOverlay() {
        if agentAnimationOverlay.superview == nil {
            agentAnimationOverlay.alphaValue = 0
            agentAnimationOverlay.isAnimationPaused = false
            leftContainerView.addSubview(agentAnimationOverlay, positioned: .above, relativeTo: nil)
            agentAnimationOverlay.snp.makeConstraints { make in
                make.edges.equalToSuperview()
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                self.agentAnimationOverlay.animator().alphaValue = 1
            }
        }
        if associatedTab === browserState?.focusingTab {
            view.window?.makeFirstResponder(agentAnimationOverlay)
        }
    }

    private func hideAgentAnimationOverlay() {
        guard agentAnimationOverlay.superview != nil else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            self.agentAnimationOverlay.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.agentAnimationOverlay.isAnimationPaused = true
            self.agentAnimationOverlay.removeFromSuperview()
            self.restoreFocusForCurrentTab()
        })
    }
}

/// Host view for Chromium-rendered content (webContentView, devToolsView).
///
/// **Vibrancy suppression**: Our ancestor `ColoredVisualEffectView`
/// (`NSVisualEffectView`) causes AppKit to auto-apply `kCAFilterPlusL` on
/// layer-backed descendants at window-compositor level — `isOpaque`, opaque
/// `backgroundColor`, and `layout()`-only clearing are all insufficient.
/// Apple provides no opt-out API; their guidance is "don't place non-vibrant
/// content inside NSVisualEffectView."  Short of a full view-hierarchy
/// restructure, KVO on each subview layer's `compositingFilter` is the only
/// mechanism that catches every re-application — appearance changes can
/// trigger backdrop re-renders across multiple CA commits, and post-commit
/// `DispatchQueue.main.async` clears empirically miss some of them.
///
/// The observer matches **only** `kCAFilterPlusL` ("plusL"). Any other
/// `compositingFilter` value — `nil`, a `CIFilter`, or another CA filter
/// name — is left alone, so legitimate filters set by Chromium or other UI
/// code survive untouched. The value-equality check also self-coalesces:
/// once we write `nil` the observer fires again with `nil`, fails the
/// PlusL match, and exits without further work.
class WebContentHostView: NSView {
    var isFrameSyncPaused = false

    /// Underlying string value of Apple's `kCAFilterPlusL` (Plus Lighter
    /// additive blend, declared in `<QuartzCore/CALayer.h>`). The constant
    /// itself is not bridged to Swift — `CA_EXTERN NSString * const` doesn't
    /// surface as a Swift symbol — so we match its raw filter name directly.
    /// The value is documented and ABI-stable since macOS 10.4.
    private static let vibrancyFilterName = "plusL"

    /// Per-subview KVO tokens on `layer.compositingFilter`.
    private var filterObservers: [ObjectIdentifier: NSKeyValueObservation] = [:]

    deinit {
        filterObservers.values.forEach { $0.invalidate() }
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        installFilterObserver(on: subview)
    }

    override func willRemoveSubview(_ subview: NSView) {
        removeFilterObserver(from: subview)
        super.willRemoveSubview(subview)
    }

    private func installFilterObserver(on subview: NSView) {
        let key = ObjectIdentifier(subview)
        guard filterObservers[key] == nil else { return }
        subview.wantsLayer = true
        guard let layer = subview.layer else { return }
        Self.stripVibrancyFilter(on: layer)
        filterObservers[key] = layer.observe(\.compositingFilter, options: [.new]) { observedLayer, _ in
            Self.stripVibrancyFilter(on: observedLayer)
        }
    }

    private func removeFilterObserver(from subview: NSView) {
        let key = ObjectIdentifier(subview)
        filterObservers[key]?.invalidate()
        filterObservers.removeValue(forKey: key)
    }

    /// Strip only AppKit's vibrancy filter (`kCAFilterPlusL`).  No-op for
    /// every other value (`nil`, `CIFilter`, unrelated CA filter name), so
    /// legitimate filters survive and the call is free when nothing is set.
    /// On a future macOS where AppKit ships PlusL in a non-`String`
    /// representation this matcher silently stops working — the debug log
    /// below makes that change discoverable instead of mysterious.
    private static func stripVibrancyFilter(on layer: CALayer) {
        guard let filter = layer.compositingFilter else { return }
        if let name = filter as? String, name == Self.vibrancyFilterName {
            layer.compositingFilter = nil
            return
        }
        AppLogDebug("[PHI_DEBUG][Vibrancy] unrecognized compositingFilter type=\(type(of: filter)) value=\(filter) — left untouched")
    }

    /// Sync sweep over all subview layers. KVO catches subsequent
    /// re-applications; this exists for the moment right after a subview
    /// mutation when AppKit's first apply may already be queued in the same
    /// CA transaction. Cheap thanks to `stripVibrancyFilter`'s early-out.
    func scheduleVibrancyClear() {
        for subview in subviews {
            if let layer = subview.layer {
                Self.stripVibrancyFilter(on: layer)
            }
        }
    }

    override func layout() {
        super.layout()
        guard !isFrameSyncPaused else { return }
        let target = bounds
        for subview in subviews where subview.translatesAutoresizingMaskIntoConstraints {
            if subview.frame != target {
                subview.frame = target
            }
        }
    }

    func forceSyncAllSubviewFrames() {
        let target = bounds
        for subview in subviews where subview.translatesAutoresizingMaskIntoConstraints {
            subview.frame = target
        }
    }
}

class TitlebarAwareView: NSView, TitlebarAwareHitTestable {
    func shouldConsumeHitTest(at point: NSPoint) -> Bool {
        return false
    }
}

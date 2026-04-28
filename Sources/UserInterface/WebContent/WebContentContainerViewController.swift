// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Combine
import SnapKit
import SwiftUI

/// Container for managing multiple WebContentViewController instances (one per tab)
/// Also manages the global topBarView (TabStrip) for traditional layout mode
class WebContentContainerViewController: NSViewController {
    weak var browserState: BrowserState?
    private var cancellables = Set<AnyCancellable>()
    private var isSubscriptionsSetup = false
    
    /// Tab identifier -> WebContentViewController mapping
    private var webContentControllers: [String: WebContentViewController] = [:]
    
    /// Currently focused tab identifier
    private var currentTabIdentifier: String?
    
    /// Currently displayed WebContentViewController
    private weak var currentWebContentController: WebContentViewController?

    /// Shared bookmark bar owned once per window and moved between controllers.
    private var sharedBookmarkBar: BookmarkBar?
    /// Current host for the shared bookmark bar.
    private weak var sharedBookmarkBarHostController: WebContentViewController?

    var addressBarAnchorView: NSView? { currentWebContentController?.addressBarAnchorView }

    // =========================================================================
    // Tab switch
    // Purpose: avoid flicker by delaying SetHidden(old) until Mac finishes view switch.
    //
    // Chromium                    Bridge                      Mac
    //      │                          │                          │
    //      │ DeferHide(old)           │                          │
    //      │─────────────────────────▶│                          │
    //      │                          │                          │ Defer cleanup
    //      │                          │                          │
    //      │◀─────────────────────────│◀─────────────────────────│ notifyViewSwitchCompleted
    //      │ ConfirmViewSwitchCompleted                          │
    //      │ SetHidden(old)           │                          │
    //      │─────────────────────────▶│─────────────────────────▶│
    //      │ OnPreviousTabReadyForCleanup                          │
    //      │─────────────────────────▶│─────────────────────────▶│ handlePreviousTabReadyForCleanup
    //      │                          │                          │ remove old NSView
    //
    // New tab (first paint gating)
    //
    // Chromium                    Bridge                      Mac
    //      │                          │                          │
    //      │ OnTabCreated             │                          │ newTabCreated
    //      │─────────────────────────▶│                          │
    //      │ OnActiveTabChanged       │                          │ activeTabChanged
    //      │─────────────────────────▶│─────────────────────────▶│ handleFocusingTabChanged
    //      │                          │                          │ hasFirstPaint? no
    //      │                          │                          │ switchToNewUnpaintedTab
    //      │ FirstPaint               │                          │
    //      │ OnTabReadyToDisplay      │                          │ tabReadyToDisplay
    //      │─────────────────────────▶│─────────────────────────▶│ handleTabReadyToDisplay
    //      │                          │                          │ bring new view to front
    //      │◀─────────────────────────│◀─────────────────────────│ notifyViewSwitchCompleted
    //      │ ConfirmViewSwitchCompleted                          │
    //      │ SetHidden(old)            │                          │
    //      │ OnPreviousTabReadyForCleanup                          │
    //      │─────────────────────────▶│─────────────────────────▶│ handlePreviousTabReadyForCleanup
    //      │                          │                          │ remove old NSView
    // =========================================================================

    // =========================================================================
    // Flicker fix: Pending state for tab visibility synchronization
    // =========================================================================

    /// Scenario 1: Previous controller/view waiting to be cleaned up after Chromium confirms hiding.
    /// We defer cleanup until Chromium sends previousTabReadyForCleanup notification.
    private var pendingViewCleanup: (controller: WebContentViewController, view: NSView)?

    /// Scenario 2: New tab controller waiting for first paint before being shown.
    /// The new controller's view is added below the current view until first paint completes.
    /// Structure: (controller, tabId, identifier)
    private var pendingNewTabSwitch: (controller: WebContentViewController, tabId: Int, identifier: String)?

    /// Timeout work item for scenario 2 - fallback if first paint notification doesn't arrive
    private var pendingNewTabTimeoutWorkItem: DispatchWorkItem?

    /// Timeout duration for waiting for first paint (in seconds)
    private static let firstPaintTimeoutSeconds: Double = 0.05

    // MARK: - UI Components

    /// Status URL view model for SwiftUI
    private let statusURLViewModel = StatusURLViewModel()

    /// Status URL hosting controller for displaying link hover information
    private var statusURLHostingController: ThemedHostingController<StatusURLView>?

    /// Global TabStrip bar controller - only visible in traditional layout mode
    /// Contains TabStrip and right-side buttons (CardEntryButton, etc.)
    private var tabStripBarController: TabStripBarController?
    var tabStripView: TabStrip? { tabStripBarController?.tabStrip }

    private var topBarHeightConstraint: Constraint?
    private var topBarTopConstraint: Constraint?
    
    /// Container view for the current WebContentViewController
    private lazy var contentContainer: NSView = {
        let view = NSView()
        view.wantsLayer = true
        return view
    }()

    /// Single CAShapeLayer that strokes a unified path covering the active
    /// tab's outline (top + sides + inverse curves) AND splitViewContainer's
    /// rounded-rect outline. Hosted on this view's layer so its z is above
    /// both the tab strip (in barController.view) and the content (in
    /// contentContainer); otherwise the active tab's fill or splitView's fill
    /// would clip half of the stroke.
    private let outerBorderLayer = CAShapeLayer()
    private var outerBorderThemeObservation: AnyObject?

    private enum LayerZIndex {
        /// Stacks above every sibling sublayer in `view.layer` so the active
        /// tab's fill (in barController.view) and splitViewContainer's fill
        /// (in contentContainer → webContentVC.view) can't clip the stroke.
        /// Bump only if a higher-z layer is intentionally introduced.
        static let contentOuterBorder: CGFloat = 1000
    }
    
    /// Titlebar aware area for handling double-click on titlebar
    private var titleAwareArea = TitlebarAwareView()
    
    /// Left resize handle for adjusting sidebar width
    private lazy var resizeHandle = SplitViewResizeHandle()

    /// Left-edge hover trigger for showing floating sidebar when main sidebar is collapsed.
    lazy var floatingSidebarTriggerView = MouseTrackingAreaView()

    var floatingSidebarContainerView: NSView?
    var floatingSidebarViewController: FloatingSidebarViewController?
    var floatingSidebarLeadingConstraint: Constraint?
    var floatingSidebarWidthConstraint: Constraint?
    var floatingSidebarHideWorkItem: DispatchWorkItem?
    var floatingSidebarEnableWorkItem: DispatchWorkItem?
    var floatingSidebarLastShownAt: Date?
    var floatingSidebarShownFromRightToLeft = false
    var isPointerInsideFloatingSidebar = false
    var isPointerInsideFloatingSidebarTrigger = false
    /// Tracks the last non-zero sidebar width so the floating panel can match it after collapse.
    var lastKnownSidebarWidth: CGFloat = 0
    
    // MARK: - Initialization
    
    init(state: BrowserState) {
        self.browserState = state
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let hostController = sharedBookmarkBarHostController {
            hostController.detachBookmarkBarIfAttached()
        }
    }
    
    // MARK: - Lifecycle
    
    override func loadView() {
        let view = ColoredVisualEffectView()
        view.themedBackgroundColor = .windowOverlayBackground
        view.material = .fullScreenUI
        view.wantsLayer = true
        self.view = view
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }
    
    override func viewWillAppear() {
        super.viewWillAppear()
        setupTopBarIfNeeded()
        setupSubscriptionsIfNeeded()
        updateLayoutForMode()
    }
    
    // MARK: - UI Setup
    
    private func setupUI() {
        // Add content container
        view.addSubview(contentContainer)
        contentContainer.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        // Outer border layer sits on this view's layer so it can render above
        // both the tab strip's tab fills and splitViewContainer's fill.
        outerBorderLayer.fillColor = NSColor.clear.cgColor
        outerBorderLayer.strokeColor = NSColor.clear.cgColor
        outerBorderLayer.lineWidth = 1
        outerBorderLayer.lineCap = .butt
        outerBorderLayer.lineJoin = .round
        outerBorderLayer.zPosition = LayerZIndex.contentOuterBorder
        // strokeColor / lineWidth never animate; path is conditionally
        // animated in updateContentOuterBorder() to match the surrounding
        // tab-strip animation context (so the gap morphs while tabs slide,
        // but snaps on plain relayouts like window resize).
        outerBorderLayer.actions = [
            "strokeColor": NSNull(),
            "lineWidth": NSNull()
        ]
        view.layer?.addSublayer(outerBorderLayer)
        outerBorderThemeObservation = view.subscribe { [weak self] _, _ in
            guard let self else { return }
            self.outerBorderLayer.strokeColor = ThemedColor.border.resolve(in: self.view).cgColor
        }
        
        // Add resize handle for sidebar adjustment
        view.addSubview(resizeHandle)
        resizeHandle.snp.makeConstraints { make in
            make.left.equalToSuperview()
            make.top.bottom.equalToSuperview()
            make.width.equalTo(10)
        }
        resizeHandle.onDragEnded = { [weak self] in
            self?.updateLayoutForMode()
        }

        // Add left-edge hover trigger for floating sidebar.
        view.addSubview(floatingSidebarTriggerView, positioned: .above, relativeTo: resizeHandle)
        floatingSidebarTriggerView.snp.makeConstraints { make in
            make.leading.top.bottom.equalToSuperview()
            make.width.equalTo(Self.floatingSidebarTriggerWidth)
        }
        setupFloatingSidebarTrigger()
        
        // Add titlebar aware area
        view.addSubview(titleAwareArea)
        titleAwareArea.snp.makeConstraints { make in
            make.leading.trailing.top.equalToSuperview()
            make.height.equalTo(12)
        }
        
        // Observe configuration changes
        setupConfigObserver()

        // Setup status URL view
        setupStatusURLView()
    }

    private func setupStatusURLView() {
        let hostingController = StatusURLView.makeHostingController(viewModel: statusURLViewModel, themeSource: browserState?.themeContext)
        statusURLHostingController = hostingController
        let hostingView = hostingController.view

        contentContainer.addSubview(hostingView)

        // Position: bottom-left corner, max width 50% of container
        hostingView.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(12)
            make.bottom.equalToSuperview().offset(-12)
            make.width.lessThanOrEqualToSuperview().multipliedBy(0.5)
        }
    }

    private func setupTopBarIfNeeded() {
        guard tabStripBarController == nil, let state = browserState else { return }

        let barController = TabStripBarController(browserState: state)
        tabStripBarController = barController
        barController.onTabStripLayoutChanged = { [weak self] in
            self?.updateContentOuterBorder()
        }
        
        // Note: CardEntryButton tap is now handled internally by TabStripBarController
        // which manages the NotificationCardPanel directly
        
        // Add as child view controller
        addChild(barController)
        
        // Add topBar view above titleAwareArea, so tab items receive clicks
        // in the overlap zone while titleAwareArea still handles the gap above the bar
        view.addSubview(barController.view, positioned: .above, relativeTo: titleAwareArea)
        barController.view.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview()
            topBarTopConstraint = make.top.equalToSuperview().inset(WebContentConstant.edgesSpacing).constraint
            topBarHeightConstraint = make.height.equalTo(0).constraint
        }
        
        // Update content container constraints to be below topBar
        contentContainer.snp.remakeConstraints { make in
            make.leading.trailing.bottom.equalToSuperview()
            make.top.equalTo(barController.view.snp.bottom)
        }
    }
    
    // MARK: - Subscriptions Setup
    
    private func setupSubscriptionsIfNeeded() {
        guard !isSubscriptionsSetup else { return }
        isSubscriptionsSetup = true
        
        // Listen to focusingTab changes to switch WebContentViewController
        browserState?.$focusingTab
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tab in
                self?.handleFocusingTabChanged(tab)
            }
            .store(in: &cancellables)
        
        // Listen to tabs changes to detect tab closures
        browserState?.$tabs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tabs in
                self?.handleTabsChanged(tabs)
            }
            .store(in: &cancellables)

        browserState?.$sidebarCollapsed
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateLayoutForMode()
            }
            .store(in: &cancellables)

        if lastKnownSidebarWidth <= 0 {
            let cached = AccountController.shared.account?.userDefaults.lastKnownSidebarWidth ?? 0
            if cached > 0 {
                lastKnownSidebarWidth = cached
            }
        }

        browserState?.$sidebarWidth
            .receive(on: DispatchQueue.main)
            .sink { [weak self] width in
                guard let self else { return }
                // Only cache widths >= the split-view minimum. This includes the user-chosen
                // minimum width (185), but excludes 0 (collapsed) and the small transient
                // frames produced during the collapse animation, which would otherwise
                // shrink the floating sidebar below the real sidebar's minimum.
                if width >= MainSplitViewController.leftItemMinWidth {
                    self.lastKnownSidebarWidth = width
                }
                self.updateFloatingSidebarWidth()
            }
            .store(in: &cancellables)

        browserState?.$layoutMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateFloatingSidebarAvailability()
            }
            .store(in: &cancellables)
        
        // Listen to layout mode changes
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateLayoutForMode()
            }
            .store(in: &cancellables)

        // Listen to targetURL changes to update status bubble
        browserState?.$targetURL
            .receive(on: DispatchQueue.main)
            .sink { [weak self] url in
                self?.updateStatusURL(url)
            }
            .store(in: &cancellables)
    }
    
    private func setupConfigObserver() {
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateLayoutForMode()
            }
            .store(in: &cancellables)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateContentOuterBorder()
    }

    /// Computes and applies the unified content border path. The path traces:
    /// active tab (top + sides + inverse curves) → splitViewContainer
    /// (rounded-rect outline) as one closed shape, so a single stroke renders
    /// across the whole boundary without seams. In sidebar layouts (no
    /// horizontal tab strip) it intentionally falls back to a plain
    /// rounded-rect outline — we still want the content container to carry
    /// its own outline in Balanced/Performance, just without the active-tab
    /// gap that only makes sense when a horizontal tab strip is present.
    private func updateContentOuterBorder() {
        guard let controller = currentWebContentController else {
            outerBorderLayer.path = nil
            return
        }
        let r = controller.splitViewContainerFrame(in: view)
        guard r.width > 0, r.height > 0 else {
            outerBorderLayer.path = nil
            return
        }

        let cornerR = LiquidGlassCompatible.webContentContainerCornerRadius
        let invR = TabStripMetrics.Tab.inverseCornerRadius
        let kappa: CGFloat = 0.55228
        let h = cornerR * kappa

        let leftX = r.minX
        let rightX = r.maxX
        let topY = r.maxY
        let bottomY = r.minY

        // Tie the gap to the *visible* controller's tab rather than
        // browserState.focusingTab. During the deferred-first-paint switch
        // path, focusingTab updates before currentWebContentController is
        // promoted; using the visible tab keeps the outline attached to the
        // tab whose page is actually onscreen.
        let activeFrame: CGRect? = PhiPreferences.GeneralSettings.loadLayoutMode().isTraditional
            ? tabStripBarController?.tabFrame(for: controller.associatedTab, in: view)
            : nil

        let path = CGMutablePath()

        if let af = activeFrame,
           af.minX - invR > leftX + cornerR,
           af.maxX + invR < rightX - cornerR {
            // Unified clockwise path: right apex → up tab → top → down tab →
            // left apex → splitView outline → close.
            let rightApex = CGPoint(x: af.maxX + invR, y: topY)

            // Tab outline (right apex → top → left apex), shared with TabBackgroundLayer.
            TabStripMetrics.appendActiveTabOutline(
                to: path,
                leftX: af.minX,
                rightX: af.maxX,
                apexY: topY,
                tabTopY: af.maxY
            )
            // Continue clockwise along splitView's top edge to the left corner.
            path.addLine(to: CGPoint(x: leftX + cornerR, y: topY))
            path.addCurve(
                to: CGPoint(x: leftX, y: topY - cornerR),
                control1: CGPoint(x: leftX + cornerR - h, y: topY),
                control2: CGPoint(x: leftX, y: topY - cornerR + h)
            )
            path.addLine(to: CGPoint(x: leftX, y: bottomY + cornerR))
            path.addCurve(
                to: CGPoint(x: leftX + cornerR, y: bottomY),
                control1: CGPoint(x: leftX, y: bottomY + cornerR - h),
                control2: CGPoint(x: leftX + cornerR - h, y: bottomY)
            )
            path.addLine(to: CGPoint(x: rightX - cornerR, y: bottomY))
            path.addCurve(
                to: CGPoint(x: rightX, y: bottomY + cornerR),
                control1: CGPoint(x: rightX - cornerR + h, y: bottomY),
                control2: CGPoint(x: rightX, y: bottomY + cornerR - h)
            )
            path.addLine(to: CGPoint(x: rightX, y: topY - cornerR))
            path.addCurve(
                to: CGPoint(x: rightX - cornerR, y: topY),
                control1: CGPoint(x: rightX, y: topY - cornerR + h),
                control2: CGPoint(x: rightX - cornerR + h, y: topY)
            )
            path.addLine(to: rightApex)
            path.closeSubpath()
        } else {
            // Closed rounded rect outline (no active tab gap).
            path.move(to: CGPoint(x: leftX + cornerR, y: topY))
            path.addLine(to: CGPoint(x: rightX - cornerR, y: topY))
            path.addCurve(
                to: CGPoint(x: rightX, y: topY - cornerR),
                control1: CGPoint(x: rightX - cornerR + h, y: topY),
                control2: CGPoint(x: rightX, y: topY - cornerR + h)
            )
            path.addLine(to: CGPoint(x: rightX, y: bottomY + cornerR))
            path.addCurve(
                to: CGPoint(x: rightX - cornerR, y: bottomY),
                control1: CGPoint(x: rightX, y: bottomY + cornerR - h),
                control2: CGPoint(x: rightX - cornerR + h, y: bottomY)
            )
            path.addLine(to: CGPoint(x: leftX + cornerR, y: bottomY))
            path.addCurve(
                to: CGPoint(x: leftX, y: bottomY + cornerR),
                control1: CGPoint(x: leftX + cornerR - h, y: bottomY),
                control2: CGPoint(x: leftX, y: bottomY + cornerR - h)
            )
            path.addLine(to: CGPoint(x: leftX, y: topY - cornerR))
            path.addCurve(
                to: CGPoint(x: leftX + cornerR, y: topY),
                control1: CGPoint(x: leftX, y: topY - cornerR + h),
                control2: CGPoint(x: leftX + cornerR - h, y: topY)
            )
            path.closeSubpath()
        }

        // Animate path morphing when the caller (tab strip) is inside an
        // NSAnimationContext with implicit animations enabled; snap otherwise.
        // This keeps the gap aligned with tabs during select/close/scroll/drag
        // animations without making it morph during plain layout passes.
        let shouldAnimate = NSAnimationContext.current.allowsImplicitAnimation
        CATransaction.begin()
        CATransaction.setDisableActions(!shouldAnimate)
        outerBorderLayer.path = path
        outerBorderLayer.strokeColor = ThemedColor.border.resolve(in: view).cgColor
        CATransaction.commit()
    }
    
    // MARK: - Tab Management
    
    private func handleFocusingTabChanged(_ tab: Tab?) {
        guard let tab, let state = browserState else { return }

        let identifier = state.getTabIdentifier(for: tab)
        // Skip if already showing this tab
        guard identifier != currentTabIdentifier else { return }

        // Clear status URL when switching tabs
        state.targetURL = ""

        cancelPendingNewTabSwitchIfNeeded(nextTabId: tab.guid, nextIdentifier: identifier)

        // Get or create WebContentViewController for this tab
        let controller = getOrCreateWebContentController(for: tab, identifier: identifier)

        // =========================================================================
        // Flicker fix: Choose switch strategy based on whether tab has painted
        // =========================================================================

        if tab.hasFirstPaint {
            // Scenario 1: Tab has already painted, switch immediately (bring to front)
            // AppLogDebug("[FlickerFix][Mac] Tab has first paint, using immediate switch (scenario 1)")
            switchToWebContentController(controller)
            currentTabIdentifier = identifier
        } else {
            // Scenario 2: New tab hasn't painted yet, add view below current and wait for first paint
            // AppLogDebug("[FlickerFix][Mac] 📤 New tab hasn't painted, deferring display until first paint (scenario 2)")
            switchToNewUnpaintedTab(controller: controller, tab: tab, identifier: identifier)
        }
    }
    
    private func handleTabsChanged(_ tabs: [Tab]) {
        guard let state = browserState else { return }
        
        // Build a set of current tab identifiers and chromium guids
        let currentIdentifiers = Set(tabs.map { state.getTabIdentifier(for: $0) })
        let currentTabGuids = Set(tabs.map { $0.guid })
        
        // Find controllers to remove - only remove if:
        // 1. The key (identifier) is not in currentIdentifiers, AND
        // 2. The controller's associatedTab.guid is not in currentTabGuids
        // This prevents removing controllers when identifier changes (e.g., pin/unpin)
        let controllersToRemove = webContentControllers.filter { key, controller in
            let identifierMismatch = !currentIdentifiers.contains(key)
            let tabGuid = controller.associatedTab?.guid ?? -1
            let tabStillExists = currentTabGuids.contains(tabGuid)
            
            // Only remove if identifier doesn't match AND tab no longer exists
            return identifierMismatch && !tabStillExists
        }.map { $0.key }
        
        for identifier in controllersToRemove {
            removeWebContentController(for: identifier)
        }
    }
    
    private func getOrCreateWebContentController(for tab: Tab, identifier: String) -> WebContentViewController {
        // Return existing controller if available
        if let existing = webContentControllers[identifier] {
            // Update the associated tab in case properties changed
            existing.updateAssociatedTab(tab)
            return existing
        }
        
        // Fallback: try to find controller by chromium guid if identifier is guidInLocalDB
        // This handles the case when a tab is moved to/from pinned (identifier changes)
        let chromiumGuidKey = String(tab.guid)
        if identifier != chromiumGuidKey, let existing = webContentControllers[chromiumGuidKey] {
            // Found controller with old key, migrate to new key
            webContentControllers.removeValue(forKey: chromiumGuidKey)
            webContentControllers[identifier] = existing
            existing.updateAssociatedTab(tab)
            AppLogInfo("🔄 [WebContent] Migrated controller from '\(chromiumGuidKey)' to '\(identifier)'")
            return existing
        }
        
        // Fallback: try to find controller by any guidInLocalDB that matches this tab's guid
        // This handles the case when a tab is moved out of pinned (identifier changes back to chromium guid)
        if let existingEntry = webContentControllers.first(where: { key, controller in
            controller.associatedTab?.guid == tab.guid && key != identifier
        }) {
            let oldKey = existingEntry.key
            let existing = existingEntry.value
            webContentControllers.removeValue(forKey: oldKey)
            webContentControllers[identifier] = existing
            existing.updateAssociatedTab(tab)
            AppLogInfo("🔄 [WebContent] Migrated controller from '\(oldKey)' to '\(identifier)' (by tab.guid)")
            return existing
        }
        
        // Create new controller with the associated tab
        let controller = WebContentViewController(state: browserState, tab: tab)
        webContentControllers[identifier] = controller
        AppLogInfo("🆕 [WebContent] Created new controller for identifier '\(identifier)', tab.guid: \(tab.guid)")
        
        return controller
    }

    private func ensureSharedBookmarkBar() -> BookmarkBar? {
        if let sharedBookmarkBar {
            return sharedBookmarkBar
        }

        guard let state = browserState else { return nil }

        let bookmarkBar = BookmarkBar(browserState: state)
        bookmarkBar.onBookmarksChanged = { [weak self] bookmarkCount in
            guard let self else { return }
            self.sharedBookmarkBarHostController?.updateBookmarkBarVisibility(bookmarkCount: bookmarkCount)
        }
        sharedBookmarkBar = bookmarkBar
        return bookmarkBar
    }

    private func attachSharedBookmarkBar(to controller: WebContentViewController) {
        guard let bookmarkBar = ensureSharedBookmarkBar() else { return }

        if sharedBookmarkBarHostController === controller {
            controller.attachBookmarkBar(bookmarkBar)
            controller.updateBookmarkBarVisibility(bookmarkCount: bookmarkBar.bookmarkCount)
            return
        }

        sharedBookmarkBarHostController?.detachBookmarkBarIfAttached()
        controller.attachBookmarkBar(bookmarkBar)
        sharedBookmarkBarHostController = controller
        controller.updateBookmarkBarVisibility(bookmarkCount: bookmarkBar.bookmarkCount)
    }

    private func detachSharedBookmarkBar(from controller: WebContentViewController) {
        guard sharedBookmarkBarHostController === controller else { return }

        controller.detachBookmarkBarIfAttached()
        sharedBookmarkBarHostController = nil
    }
    
    /// Scenario 1: Switch to an already-painted tab (immediate switch, bring to front)
    private func switchToWebContentController(_ controller: WebContentViewController) {
        // Flicker fix: Don't remove old view immediately, defer until Chromium confirms.
        // Save old controller/view for later cleanup.
        if let current = currentWebContentController, current !== controller {
            pendingViewCleanup = (controller: current, view: current.view)
            AppLogDebug("[WebContent] Deferring cleanup of previous controller, waiting for Chromium confirmation")
        }

        // Add new controller
        if controller.parent !== self {
            addChild(controller)
        }

        // Add new view on top (old view stays underneath until cleanup)
        if controller.view.superview !== contentContainer {
            contentContainer.addSubview(controller.view)
            controller.view.snp.remakeConstraints { make in
                make.edges.equalToSuperview()
            }
        } else {
            // If already in container, bring to front
            contentContainer.addSubview(controller.view, positioned: .above, relativeTo: nil)
        }

        attachSharedBookmarkBar(to: controller)

        currentWebContentController = controller
        updateContentOuterBorder()

        // Notify Chromium that view switch is complete, it can now hide the old WebContents
        notifyViewSwitchCompleted()
    }

    /// Scenario 2: Switch to a new unpainted tab (add view below, wait for first paint)
    private func switchToNewUnpaintedTab(controller: WebContentViewController, tab: Tab, identifier: String) {
        // Cancel any existing timeout
        pendingNewTabTimeoutWorkItem?.cancel()
        pendingNewTabTimeoutWorkItem = nil

        // Add new controller
        if controller.parent !== self {
            addChild(controller)
        }

        // Add new view BELOW the current view (old view stays on top and visible)
        if controller.view.superview !== contentContainer {
            // Insert at the bottom of the subview stack
            contentContainer.addSubview(controller.view, positioned: .below, relativeTo: currentWebContentController?.view)
            controller.view.snp.remakeConstraints { make in
                make.edges.equalToSuperview()
            }
        }

        // Save pending state - we'll complete the switch when first paint arrives
        pendingNewTabSwitch = (controller: controller, tabId: tab.guid, identifier: identifier)

        // AppLogDebug("[FlickerFix][Mac] New tab view added below current, waiting for tabReadyToDisplay, tabId=\(tab.guid)")

        // Start timeout timer as fallback in case first paint notification doesn't arrive
        let tabId = tab.guid
        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            self?.handleFirstPaintTimeout(tabId: tabId)
        }
        pendingNewTabTimeoutWorkItem = timeoutWorkItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.firstPaintTimeoutSeconds,
            execute: timeoutWorkItem
        )

        // AppLogDebug("[FlickerFix][Mac] Started \(Self.firstPaintTimeoutSeconds)s timeout for first paint")

        // Note: We do NOT call notifyViewSwitchCompleted() here.
        // We'll call it after we receive tabReadyToDisplay and bring the new view to front.
    }

    /// Timeout handler for scenario 2 - force switch if first paint doesn't arrive in time
    private func handleFirstPaintTimeout(tabId: Int) {
        guard let pending = pendingNewTabSwitch, pending.tabId == tabId else {
            // Pending state was cleared (first paint arrived or tab changed)
            return
        }

        // AppLogDebug("[FlickerFix][Mac] ⚠️ First paint timeout reached for tabId=\(tabId), forcing switch")

        // Force the switch using the same logic as handleTabReadyToDisplay
        handleTabReadyToDisplay(tabId: tabId)
    }

    private func cancelPendingNewTabSwitchIfNeeded(nextTabId: Int, nextIdentifier: String) {
        guard let pending = pendingNewTabSwitch else { return }
        guard pending.tabId != nextTabId else { return }

        // AppLogDebug("[FlickerFix][Mac] Cancelling pending new tab switch (pendingTabId=\(pending.tabId), nextTabId=\(nextTabId), nextIdentifier=\(nextIdentifier))")

        // Delayed-first-paint tabs keep the shared bookmark bar on the visible controller
        // until promotion. If this ever fires while the pending controller owns it, the
        // promotion/detach ordering has regressed.
        assert(sharedBookmarkBarHostController !== pending.controller, "Pending unpainted tab must not host the shared bookmark bar yet")

        pendingNewTabTimeoutWorkItem?.cancel()
        pendingNewTabTimeoutWorkItem = nil
        pendingNewTabSwitch = nil

        if pending.controller.view.superview === contentContainer {
            pending.controller.view.removeFromSuperview()
            // AppLogDebug("[FlickerFix][Mac] Removed pending new tab view from hierarchy")
        }
    }
    
    private func removeWebContentController(for identifier: String) {
        guard let controller = webContentControllers[identifier] else { return }

        detachSharedBookmarkBar(from: controller)
        
        // If this is the current controller, remove from view
        if controller === currentWebContentController {
            controller.view.removeFromSuperview()
            controller.removeFromParent()
            currentWebContentController = nil
            currentTabIdentifier = nil
            // Clear the unified outline so it doesn't linger over the now
            // detached content area until the next focus/layout pass.
            updateContentOuterBorder()
        }
        
        // Remove from dictionary
        webContentControllers.removeValue(forKey: identifier)
    }
    
    // MARK: - Layout Mode
    
    private func updateLayoutForMode() {
        let traditionalLayout = PhiPreferences.GeneralSettings.loadLayoutMode().isTraditional
        
        if traditionalLayout {
            // Traditional layout (horizontal tabs): show topBar
            tabStripBarController?.view.isHidden = false
            tabStripBarController?.setActive(true)
            topBarHeightConstraint?.update(offset: WebContentConstant.topBarHeight)
            topBarTopConstraint?.update(inset: WebContentConstant.edgesSpacing - 2) // align with traffic light
        } else {
            // Vertical sidebar layout: hide topBar
            tabStripBarController?.setActive(false)
            tabStripBarController?.view.isHidden = true
            topBarHeightConstraint?.update(offset: 0)
            topBarTopConstraint?.update(inset: WebContentConstant.edgesSpacing)
            titleAwareArea.isHidden = false
        }

        // Keep the resize handle visible during an active drag so the user can
        // re-expand the sidebar without releasing the mouse button.
        resizeHandle.isHidden = shouldEnableFloatingSidebar() && !resizeHandle.isDragging
        updateFloatingSidebarAvailability()
    }

    // MARK: - AI Chat Toggle
    
    /// Toggle AI Chat for the current tab
    /// This toggles the AI Chat state on the currently focused tab
    func toggleAIChat() {
        // Toggle on the current WebContentViewController (which will update the associated tab)
        if let controller = currentWebContentController {
            controller.toggleAIChatInTraditionalLayout()
        } else {
            // Fallback: directly toggle the focusingTab's state
            browserState?.focusingTab?.toggleAIChat()
        }
    }

    // =========================================================================
    // Flicker fix: Tab visibility synchronization
    // =========================================================================

    /// Notify Chromium that view switch has completed.
    /// Chromium will then hide the previous WebContents and send cleanup notification.
    private func notifyViewSwitchCompleted() {
        guard let windowId = browserState?.windowId else {
            AppLogDebug("[WebContent] Cannot notify view switch: no windowId")
            return
        }
        AppLogDebug("[WebContent] Notifying Chromium: view switch completed, windowId=\(windowId)")
        ChromiumLauncher.sharedInstance().bridge?.confirmViewSwitchCompleted(Int64(windowId))
    }

    /// Called when Chromium has hidden the previous tab and it's ready for cleanup.
    /// Now we can safely remove the old view from the view hierarchy.
    func handlePreviousTabReadyForCleanup(tabId: Int) {
        AppLogDebug("[WebContent] Received cleanup notification for tabId=\(tabId)")

        guard let pending = pendingViewCleanup else {
            AppLogDebug("[WebContent] No pending view to cleanup")
            return
        }

        guard pending.controller.associatedTab?.guid == tabId else {
            AppLogDebug("[WebContent] Ignoring cleanup for mismatched tabId=\(tabId), pendingTabId=\(pending.controller.associatedTab?.guid ?? -1)")
            return
        }

        detachSharedBookmarkBar(from: pending.controller)

        // Remove the old view and controller
        pending.view.removeFromSuperview()
        pending.controller.removeFromParent()
        pendingViewCleanup = nil

        AppLogDebug("[WebContent] Cleaned up previous view after Chromium confirmation")
    }

    /// Called when a new tab has completed its first visually non-empty paint.
    /// If there's a pending new tab waiting to be shown, bring it to the front now.
    func handleTabReadyToDisplay(tabId: Int) {
        // AppLogDebug("[FlickerFix][Mac] ⬅️ tabReadyToDisplay received, tabId=\(tabId)")

        // Check if we have a pending new tab switch waiting for this tab
        guard let pending = pendingNewTabSwitch else {
            // AppLogDebug("[FlickerFix][Mac] No pending new tab switch (first paint for already-visible tab)")
            return
        }

        // Verify it's the tab we're waiting for
        guard pending.tabId == tabId else {
            // AppLogDebug("[FlickerFix][Mac] tabReadyToDisplay for different tab (pending=\(pending.tabId), received=\(tabId))")
            return
        }

        // Cancel timeout since we received the notification
        pendingNewTabTimeoutWorkItem?.cancel()
        pendingNewTabTimeoutWorkItem = nil

        // AppLogDebug("[FlickerFix][Mac] ✅ Bringing new tab to front after first paint, tabId=\(tabId)")

        // Save old view for cleanup (scenario 1 logic)
        if let current = currentWebContentController, current !== pending.controller {
            pendingViewCleanup = (controller: current, view: current.view)
        }

        // Bring new view to front
        contentContainer.addSubview(pending.controller.view, positioned: .above, relativeTo: nil)

        attachSharedBookmarkBar(to: pending.controller)

        // Update current controller and identifier
        currentWebContentController = pending.controller
        currentTabIdentifier = pending.identifier
        updateContentOuterBorder()

        // Clear pending state
        pendingNewTabSwitch = nil

        // Now notify Chromium that view switch is complete
        // This triggers the old tab to be hidden and cleanup flow
        notifyViewSwitchCompleted()

        // AppLogDebug("[FlickerFix][Mac] ➡️ Sent confirmViewSwitchCompleted after new tab first paint")
    }

    // =========================================================================
    // DevTools embedding
    // =========================================================================

    /// Find the WebContentViewController managing a given Chromium tab ID.
    private func findController(forTabId tabId: Int) -> WebContentViewController? {
        webContentControllers.values.first { $0.associatedTab?.guid == tabId }
    }

    /// Called when Chromium attaches docked DevTools to a tab.
    func handleDevToolsDidAttach(tabId: Int, devToolsView: NSView) {
        guard let controller = findController(forTabId: tabId) else {
            AppLogInfo("[DevTools] No controller found for tabId=\(tabId)")
            return
        }
        controller.attachDevTools(view: devToolsView)
    }

    /// Called when Chromium detaches DevTools from a tab (closed or undocked).
    func handleDevToolsDidDetach(tabId: Int) {
        guard let controller = findController(forTabId: tabId) else {
            AppLogInfo("[DevTools] No controller found for tabId=\(tabId)")
            return
        }
        controller.detachDevTools()
    }

    /// Called when DevTools JS updates the inspected page bounds.
    func handleUpdateInspectedPageBounds(tabId: Int, bounds: CGRect, hide: Bool) {
        guard let controller = findController(forTabId: tabId) else { return }
        controller.updateInspectedPageBounds(bounds, hide: hide)
    }

    // MARK: - Status URL Display

    private func updateStatusURL(_ url: String) {
        statusURLViewModel.url = url
    }
}

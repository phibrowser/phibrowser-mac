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
    private final class TitlebarAwareView: NSView, TitlebarAwareHitTestable {
        func shouldConsumeHitTest(at point: NSPoint) -> Bool {
            false
        }
    }

    weak var browserState: BrowserState?
    private var cancellables = Set<AnyCancellable>()
    private var isSubscriptionsSetup = false
    
    /// Tab identifier -> WebContentViewController mapping
    private var webContentControllers: [String: WebContentViewController] = [:]
    
    /// Currently focused tab identifier
    private var currentTabIdentifier: String?
    
    /// Currently displayed WebContentViewController
    private weak var currentWebContentController: WebContentViewController?

    /// The visible tab's web-content panel size, or nil when nothing is
    /// mounted (placeholder mode, window still restoring). See
    /// `WebContentViewController.webPanelSize`.
    var currentWebPanelSize: CGSize? { currentWebContentController?.webPanelSize }

    /// The visible tab's rounded page card, or nil when nothing is mounted.
    /// The Reader overlay panel sizes itself to this — the container's own
    /// view also spans the window margins and the tab strip, which the card
    /// excludes. See `WebContentViewController.pageCardView`.
    var currentPageCardView: NSView? { currentWebContentController?.pageCardView }

    /// Owned by this controller while in placeholder mode; released on exit.
    /// Mutually exclusive with the active tab's WCVC (only one is visible
    /// in contentContainer at a time).
    private var placeholderShell: PlaceholderShellViewController?

    /// Static snapshot of the closing active tab, laid over the content area to hide
    /// the flash during the view swap. Single slot; independent of `placeholderShell`.
    private var closePlaceholder: NSImageView?

    /// Fallback that clears `closePlaceholder` if no swap-completion signal arrives.
    private var closePlaceholderTimeout: DispatchWorkItem?

    /// Shared bookmark bar owned once per window and moved between controllers.
    private var sharedBookmarkBar: BookmarkBar?
    /// Current host for the shared bookmark bar.
    private weak var sharedBookmarkBarHostController: WebContentViewController?

    var addressBarAnchorView: NSView? {
        // In placeholder mode the shell owns the anchor — needed for the
        // omnibox popup when invoked via cmd+L.
        if let shell = placeholderShell {
            return shell.addressBarAnchorView
        }
        return currentWebContentController?.addressBarAnchorView
    }

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

    /// Fallback duration to clear the close-snapshot placeholder when no swap signal arrives (in seconds)
    private static let closeSnapshotTimeoutSeconds: Double = 0.8

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
    
    /// Container view for the current WebContentViewController. Also serves
    /// as the drop target for "drag a tab onto the left third → make a split".
    private lazy var contentContainer: SplitTabDropContainer = {
        let view = SplitTabDropContainer()
        view.wantsLayer = true
        view.browserState = self.browserState
        view.pageAreaProvider = { [weak self, weak view] in
            guard let self, let view,
                  let current = self.currentWebContentController else { return nil }
            return current.pageContentAreaFrame(in: view)
        }
        return view
    }()

    /// Exposed so the horizontal TabStrip (comfortable layout) can show the
    /// split-drop hint while a tab is being torn out — TabStrip drives drags
    /// with raw mouse events, not an NSDraggingSession, so the container's
    /// NSDraggingDestination callbacks never fire in that mode.
    var splitTabDropContainer: SplitTabDropContainer { contentContainer }

    /// NTP-colored backdrop pinned under every other subview of
    /// `contentContainer`, tracing the page panel's exact geometry
    /// (`WebContentViewController.splitViewContainer`: same insets, corner
    /// radius, and `.contentOverlayBackground` fill). Only visible while no
    /// tab content is mounted above it — the zero-tab gap of a freshly
    /// spawned Space window whose seed NTP hasn't mounted yet. Without it
    /// that gap shows the window background, so the page area pops from
    /// window color to NTP color when the tab lands; with it the page area
    /// reads as an NTP from the first frame.
    private var pageAreaBackdropLeadingConstraint: Constraint?
    private lazy var pageAreaBackdrop: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerCurve = .continuous
        view.layer?.cornerRadius = LiquidGlassCompatible.webContentContainerCornerRadius
        view.phiLayer?.setBackgroundColor(ThemedColor.contentOverlayBackground)
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

    /// Per-group colored stroke that traces a single unified path:
    /// horizontal underline from the chip's leading edge → up-and-over
    /// the active tab's outline (when the active tab is in this group)
    /// → horizontal underline to the last member tab's trailing edge.
    /// One layer per visible expanded group, keyed by token.
    ///
    /// Replaces what would otherwise be (a) a separate filled band in
    /// `TabStrip.normalContainer.layer` and (b) a separate stroke
    /// covering the active tab outline. Two-shape rendering creates a
    /// perpendicular seam at the inverse-curve apex that no padding /
    /// corner-radius tweak can fully eliminate; one path eliminates it
    /// by construction.
    private var groupBoundaryLayers: [String: CAShapeLayer] = [:]

    /// Per-group `objectWillChange` subscriptions — needed because the
    /// active tab's group color and the active tab's groupToken can both
    /// flip without `BrowserState.$focusingTab` or `$groups` republishing.
    /// Mirrors the pattern used in `TabStrip.bindData`.
    private var groupChangeCancellables: [String: AnyCancellable] = [:]

    enum LayerZIndex {
        /// Stacks above every sibling sublayer in `view.layer` so the active
        /// tab's fill (in barController.view) and splitViewContainer's fill
        /// (in contentContainer → webContentVC.view) can't clip the stroke.
        /// Bump only if a higher-z layer is intentionally introduced.
        static let contentOuterBorder: CGFloat = 1000
        /// Floating sidebar slides in above the content area; must sit above
        /// `contentOuterBorder` so the outer-border stroke doesn't render on
        /// top of the panel.
        static let floatingSidebar: CGFloat = 1100
    }
    
    /// Single window-level region for titlebar drag and double-click handling.
    /// Child tab and placeholder controllers must not add their own copies:
    /// those overlays stack above the page when performance mode hides its header.
    private var titleAwareArea = TitlebarAwareView()
    private var titleAwareAreaHeightConstraint: Constraint?
    
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
    /// Hides the panel when its window leaves the screen (a Space switch
    /// orders the leaving window out with its panel still up) — without
    /// this the stale panel would greet the user when that window next
    /// surfaces. See `ensureFloatingSidebarOcclusionObserver`.
    var floatingSidebarOcclusionObserver: NSObjectProtocol?
    var isPointerInsideFloatingSidebar = false
    var isPointerInsideFloatingSidebarTrigger = false
    /// Tracks the last non-zero sidebar width so the floating panel can match it after collapse.
    var lastKnownSidebarWidth: CGFloat = 0

    /// The docked agent console currently hosted by this window, if any.
    /// Owned by `AgentTranscriptPanelController`; see `attachTranscriptDock`.
    private(set) var transcriptDockView: AgentTranscriptDockView?
    private var transcriptDockEdge: AgentTranscriptDockEdge?

    /// Window-level chrome for the extension side panel NSView adopted from
    /// Chromium: one per window, beside the per-tab content stack, so the
    /// panel survives tab switches without joining per-tab view churn.
    /// Carries the header (extension icon, name, close button), the AI-Chat
    /// -style card looks, and the drag-resizable width.
    private var extensionSidePanelView: ExtensionSidePanelView?

    /// Per-window width memory for the extension side panel, shared across
    /// extensions (v1 semantics; mirrors `lastKnownSidebarWidth`'s role for
    /// the left rail). Seeded with Chromium's default side panel content
    /// width; captured from the slot on detach so a close/reopen restores
    /// the last dragged width.
    private var extensionSidePanelPreferredWidth: CGFloat = 360

    /// The panel view currently playing its slide-out animation. Already
    /// detached from `extensionSidePanelView` (state first, animation as
    /// afterglow) and frame-driven; its Chromium content is gone, replaced
    /// by a window-server snapshot. Single slot: a reopen during the
    /// slide-out drops the ghost immediately.
    private var closingExtensionSidePanelView: ExtensionSidePanelView?

    /// Snapshot of an AI Chat closed by the panel-open mutex, sliding out
    /// to the right edge while the panel slides in. The real chat leaves
    /// the split layout before the container narrows — an NSSplitView
    /// -animated collapse would stay inside the narrowing container and be
    /// dragged left under the incoming panel instead of exiting right.
    /// Single slot: dropped early by a panel detach (the chat may be
    /// re-expanding right there) and whenever another controller takes
    /// over the content area (see `dropClosingAIChatGhost`).
    private var closingAIChatGhostView: NSView?

    /// Companion of the panel slot: fills the content frame's interior
    /// around the panel card with the same `contentOverlayBackground` that
    /// `splitViewContainer` paints behind the page and chat cards, so the
    /// panel reads as a sub-card inside one frame (AI Chat parity) instead
    /// of floating on the window background. Sits just above
    /// `contentContainer` in z (the container's vibrancy view overlaps 8pt
    /// under the panel and would otherwise show through as a
    /// focus-dependent notch); nil whenever the panel is detached. During
    /// a slide-out it is frozen in place, demoted below the container so
    /// the re-expanding page covers it, and removed with the ghost.
    private var extensionSidePanelFrameBackdrop: NSView?

    /// Test seam: skips the panel slide animations so attach/detach settle
    /// synchronously and layout tests can assert the end state.
    static var panelSlideAnimationsDisabledForTesting = false

    /// True when a panel attach/detach should settle immediately instead of
    /// sliding: the test seam is on, or there is no window to animate in.
    private var skipsPanelSlideAnimation: Bool {
        Self.panelSlideAnimationsDisabledForTesting || view.window == nil
    }

    /// Test-only view of the mounted panel slot.
    var extensionSidePanelViewForTesting: ExtensionSidePanelView? { extensionSidePanelView }

    /// Test-only view of the panel's frame-interior fill.
    var extensionSidePanelFrameBackdropForTesting: NSView? { extensionSidePanelFrameBackdrop }
    
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
        if let observer = floatingSidebarOcclusionObserver {
            NotificationCenter.default.removeObserver(observer)
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

        // First child of contentContainer, so every later subview (the tab's
        // WebContentViewController, placeholder shell, close snapshot) stacks
        // above it and covers it whenever real content is mounted.
        contentContainer.addSubview(pageAreaBackdrop)
        pageAreaBackdrop.snp.makeConstraints { make in
            pageAreaBackdropLeadingConstraint = make.leading.equalToSuperview().constraint
            make.trailing.bottom.equalToSuperview().inset(WebContentConstant.edgesSpacing)
            make.top.equalToSuperview()
        }
        updatePageAreaBackdropLeadingInset()

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
            // Group boundary layers use `group.color.nsColor.cgColor`,
            // which doesn't auto-rebind on appearance change. Refresh
            // each live layer here so the underline tracks the system
            // theme. Wrap in `performAsCurrentDrawingAppearance` to
            // ensure resolution picks the correct asset variant.
            self.view.effectiveAppearance.performAsCurrentDrawingAppearance {
                for (token, layer) in self.groupBoundaryLayers {
                    guard let group = self.browserState?.groups[token] else { continue }
                    layer.strokeColor = group.color.nsColor.cgColor
                }
            }
        }
        
        // Add left-edge hover trigger for floating sidebar.
        view.addSubview(floatingSidebarTriggerView)
        floatingSidebarTriggerView.snp.makeConstraints { make in
            make.leading.top.bottom.equalToSuperview()
            make.width.equalTo(Self.floatingSidebarTriggerWidth)
        }
        setupFloatingSidebarTrigger()
        
        // Add titlebar aware area
        view.addSubview(titleAwareArea)
        titleAwareArea.snp.makeConstraints { make in
            make.leading.trailing.top.equalToSuperview()
            titleAwareAreaHeightConstraint = make.height.equalTo(
                WebContentConstant.titleAwareAreaHeight(
                    for: PhiPreferences.GeneralSettings.loadLayoutMode()
                )
            ).constraint
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
        remakeContentLayout()
    }

    // MARK: - Agent transcript dock

    /// Installs the docked agent console (see `AgentTranscriptPanelController`)
    /// along the given edge, shrinking the content area to make room. One
    /// dock view exists app-wide; the controller moves it between windows as
    /// the frontmost browser window changes.
    func attachTranscriptDock(_ dock: AgentTranscriptDockView, edge: AgentTranscriptDockEdge) {
        guard transcriptDockView !== dock || transcriptDockEdge != edge else { return }
        transcriptDockView?.removeFromSuperview()
        transcriptDockView = dock
        transcriptDockEdge = edge
        view.addSubview(dock)
        dock.updateLeadingInset(pageAreaLeadingInset)
        remakeContentLayout()
    }

    func detachTranscriptDock() {
        guard let dock = transcriptDockView else { return }
        dock.removeFromSuperview()
        transcriptDockView = nil
        transcriptDockEdge = nil
        remakeContentLayout()
    }

    /// Single owner of `contentContainer`'s outer constraints: below the tab
    /// strip (once created), beside the extension side panel (when attached)
    /// and beside/above the transcript dock (when attached). Every path that
    /// changes any of those edges funnels here so no remake can drop
    /// another's constraint. Right-edge order: [content | extension side
    /// panel | right transcript dock].
    private func remakeContentLayout() {
        let panelView = extensionSidePanelView?.superview === view
            ? extensionSidePanelView : nil
        contentContainer.snp.remakeConstraints { make in
            if let bar = tabStripBarController?.view, bar.superview === view {
                make.top.equalTo(bar.snp.bottom)
            } else {
                make.top.equalToSuperview()
            }
            make.leading.equalToSuperview()
            if let panelView {
                // A docked panel separates the page card (4pt inset inside
                // splitViewContainer, see updateLeftContainerStyle) exactly
                // like an expanded AI Chat. Overlap the container a full
                // edgesSpacing under the panel so splitViewContainer's
                // right edge (8pt margin inside the container) lands
                // exactly on the panel's leading edge: its background then
                // paints the 4pt page-card ↔ panel-card seam, matching the
                // chat card's seam fill. Nothing else draws in the
                // overlapped strip.
                make.trailing.equalTo(panelView.snp.leading)
                    .offset(WebContentConstant.edgesSpacing)
            }
            if let dock = transcriptDockView, let edge = transcriptDockEdge {
                switch edge {
                case .right:
                    if panelView == nil {
                        make.trailing.equalTo(dock.snp.leading)
                    }
                    make.bottom.equalToSuperview()
                case .bottom:
                    if panelView == nil {
                        make.trailing.equalToSuperview()
                    }
                    make.bottom.equalTo(dock.snp.top)
                }
            } else {
                if panelView == nil {
                    make.trailing.equalToSuperview()
                }
                make.bottom.equalToSuperview()
            }
        }
        if let dock = transcriptDockView, let edge = transcriptDockEdge {
            // The dock's own thickness constraint lives on the dock view
            // (plain NSLayoutConstraint, untouched by this snp remake).
            dock.snp.remakeConstraints { make in
                switch edge {
                case .right:
                    make.trailing.equalToSuperview()
                    make.top.equalTo(contentContainer.snp.top)
                    make.bottom.equalToSuperview()
                case .bottom:
                    make.leading.trailing.bottom.equalToSuperview()
                }
            }
        }
        if let panelView {
            // The panel's own width constraint lives on the panel view
            // (plain NSLayoutConstraint, untouched by this snp remake) —
            // same split as the transcript dock's thickness constraint.
            //
            // The panel sits inside the content frame as a sub-card with
            // the same contentEdgeSpacing breathing room the chat card
            // keeps: 4pt below the frame's top line and 4pt off its right
            // and bottom edges (the frame itself keeps the shared
            // edgesSpacing window margins).
            let panelInset = CGFloat(WebContentConstant.contentEdgeSpacing)
            panelView.snp.remakeConstraints { make in
                make.top.equalTo(contentContainer.snp.top).offset(panelInset)
                make.bottom.equalTo(contentContainer.snp.bottom)
                    .offset(-(WebContentConstant.edgesSpacing + panelInset))
                if let dock = transcriptDockView, transcriptDockEdge == .right {
                    make.trailing.equalTo(dock.snp.leading)
                } else {
                    make.trailing.equalToSuperview()
                        .inset(WebContentConstant.edgesSpacing + panelInset)
                }
            }
            let backdrop = ensureExtensionSidePanelFrameBackdrop()
            // The fill must stay ABOVE contentContainer: the container
            // (with the per-tab vibrancy view inside it) overlaps 8pt
            // under the panel, and vibrancy material shifts with window
            // activation while the plain fill colors don't — left
            // underneath, that strip reads as a focus-dependent notch in
            // the frame interior. A detach demotes the backdrop below the
            // container again (see detachExtensionSidePanel); re-promote
            // here when a reopen reclaims it.
            if let idx = view.subviews.firstIndex(of: backdrop),
               let containerIdx = view.subviews.firstIndex(of: contentContainer),
               idx < containerIdx {
                view.addSubview(backdrop, positioned: .above,
                                relativeTo: contentContainer)
            }
            backdrop.translatesAutoresizingMaskIntoConstraints = false
            backdrop.snp.remakeConstraints { make in
                // Same vertical extent as splitViewContainer (top at the
                // frame's top line, bottom at the shared 8pt window
                // margin), extended right to wrap the panel card plus its
                // 4pt margin. The leading edge meets the page container's
                // right edge (same fill color) exactly at the panel's
                // leading edge.
                make.top.equalTo(contentContainer.snp.top)
                make.bottom.equalTo(panelView.snp.bottom).offset(panelInset)
                make.leading.equalTo(panelView.snp.leading)
                make.trailing.equalTo(panelView.snp.trailing).offset(panelInset)
            }
        }
        view.needsLayout = true
    }

    /// Creates (or returns) the panel's frame-interior fill. Constraint
    /// installation stays in `remakeContentLayout`;
    /// `slideInExtensionSidePanel` pre-seeds it frame-driven so the fill
    /// rides the same implicit animation as the panel instead of growing
    /// in from a zero rect.
    private func ensureExtensionSidePanelFrameBackdrop() -> NSView {
        if let existing = extensionSidePanelFrameBackdrop { return existing }
        let backdrop = NSView()
        backdrop.wantsLayer = true
        backdrop.layer?.cornerCurve = .continuous
        backdrop.layer?.cornerRadius = LiquidGlassCompatible.webContentContainerCornerRadius
        // Only the frame's outer (right) corners are rounded; the left edge
        // is an interior boundary meeting the page container's fill, and a
        // rounded corner there would carve a see-through notch showing the
        // vibrancy material beneath. splitViewContainer squares its right
        // corners for the same reason while the panel is open (see
        // WebContentViewController.updateLeftContainerStyle).
        backdrop.layer?.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        backdrop.phiLayer?.setBackgroundColor(ThemedColor.contentOverlayBackground)
        view.addSubview(backdrop, positioned: .above, relativeTo: contentContainer)
        extensionSidePanelFrameBackdrop = backdrop
        return backdrop
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

        // Placeholder mode attach/detach.
        //
        // SYNCHRONOUS by design (no `.receive(on:)`, no `Task { @MainActor }`).
        // See spec §9.1: the UAF contract requires the NSView to be detached
        // from the AppKit hierarchy before `exitPlaceholderMode` returns to
        // Chromium, which then resets `placeholder_web_contents_` and destroys
        // the underlying NSView. Any async hop here would dangle.
        browserState?.$isInPlaceholderMode
            .removeDuplicates()
            .sink { [weak self] isPlaceholder in
                guard let self else { return }
                if isPlaceholder {
                    self.attachPlaceholderShell()
                } else {
                    self.detachPlaceholderShell()
                }
            }
            .store(in: &cancellables)

        // Extension side panel attach/detach.
        //
        // SYNCHRONOUS by design (no `.receive(on:)`), sharing the placeholder
        // sink's UAF contract: Chromium may destroy the outgoing panel view
        // right after its bridge push returns, so the slot must react in the
        // same turn. On a close, BrowserState.updateExtensionSidePanel
        // publishes BEFORE detaching the outgoing NSView so this sink can
        // snapshot it for the slide-out and detach it itself (BrowserState's
        // backstop then no-ops); on a content replacement the outgoing view
        // is already detached when the publish arrives. Uses the emitted
        // value, not the property — @Published emits on willSet, when the
        // property still holds the old value.
        browserState?.$extensionSidePanel
            .sink { [weak self] panel in
                guard let self else { return }
                if let panel {
                    self.attachExtensionSidePanel(panel)
                } else {
                    self.detachExtensionSidePanel()
                }
            }
            .store(in: &cancellables)

        browserState?.$sidebarCollapsed
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateLayoutForMode()
                self?.updateContentOuterBorder()
            }
            .store(in: &cancellables)

        if lastKnownSidebarWidth <= 0 {
            let cached =
                AccountController.shared.localDataAccount?.userDefaults.lastKnownSidebarWidth
                ?? 0
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

        // Active-tab outline tinting follows group state. `$groups` only
        // fires on dict add/remove, so we (re)subscribe to each group's
        // `objectWillChange` to catch color flips and active-tab join/
        // leave events that nudge `info.objectWillChange.send()`. This
        // mirrors `TabStrip.rebuildGroupChangeSubscriptions`.
        browserState?.$groups
            .receive(on: DispatchQueue.main)
            .sink { [weak self] groups in
                guard let self else { return }
                self.rebuildGroupChangeSubscriptions(groups: groups)
                self.updateContentOuterBorder()
            }
            .store(in: &cancellables)

        browserState?.$groupOverviewState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateContentOuterBorder()
            }
            .store(in: &cancellables)
    }

    private func rebuildGroupChangeSubscriptions(groups: [String: WebContentGroupInfo]) {
        WebContentGroupInfo.reconcileSubscriptions(
            groups: groups,
            cancellables: &groupChangeCancellables
        ) { [weak self] _ in
            self?.updateContentOuterBorder()
        }
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

    /// Computes and applies the unified content border path for comfortable
    /// layout, where the outline needs to connect with the active horizontal tab.
    private func updateContentOuterBorder() {
        guard let controller = currentWebContentController else {
            outerBorderLayer.path = nil
            clearGroupBoundaryLayers()
            return
        }
        let isComfortableLayout = PhiPreferences.GeneralSettings.loadLayoutMode().isTraditional
        let panelMounted = extensionSidePanelView?.superview === view
        // The vertical layouts frame the content with splitViewContainer's
        // own 1pt layer border — except while an extension side panel is
        // docked: then this unified outline wraps [page card | panel card]
        // as one frame (AI Chat parity), and svc's border would draw a
        // second frame around the page alone.
        controller.setSplitViewContainerBorderVisible(!isComfortableLayout && !panelMounted)
        guard isComfortableLayout || panelMounted else {
            outerBorderLayer.path = nil
            clearGroupBoundaryLayers()
            return
        }

        let r = controller.splitViewContainerFrame(in: view)
        guard r.width > 0, r.height > 0 else {
            outerBorderLayer.path = nil
            clearGroupBoundaryLayers()
            return
        }

        let cornerR = LiquidGlassCompatible.webContentContainerCornerRadius
        let invR = TabStripMetrics.Tab.inverseCornerRadius
        let kappa: CGFloat = 0.55228
        let h = cornerR * kappa

        let leftX = r.minX
        // With the extension side panel mounted the outline keeps its right
        // edge at the window margin instead of following the shrunken page
        // card: the frame wraps the panel sub-card (which sits 4pt inside
        // it), and — critically for comfortable — the active-tab notch
        // guard below stays satisfiable for tabs whose chips sit over the
        // panel region; against the narrow card edge they would fail the
        // right-side bound and lose their outline entirely.
        let rightX = panelMounted
            ? max(r.maxX, view.bounds.maxX - WebContentConstant.edgesSpacing)
            : r.maxX
        let topY = r.maxY
        let bottomY = r.minY

        // Tie the gap to the *visible* controller's tab rather than
        // browserState.focusingTab. During the deferred-first-paint switch
        // path, focusingTab updates before currentWebContentController is
        // promoted; using the visible tab keeps the outline attached to the
        // tab whose page is actually onscreen. The notch only exists in
        // comfortable — the vertical layouts (reachable here with a panel
        // mounted) have no horizontal chips, so their frame is the plain
        // closed outline below.
        let overviewActive = browserState?.groupOverviewState != nil
        let activeTabForBorder =
            (overviewActive || !isComfortableLayout) ? nil : controller.associatedTab
        let activeFrame = isComfortableLayout
            ? tabStripBarController?.tabFrame(for: activeTabForBorder, in: view)
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

        updateGroupBoundaryLayers(apexY: topY, invR: invR, activeTab: activeTabForBorder)

        CATransaction.commit()
    }

    /// Builds / refreshes one `CAShapeLayer` per visible expanded group,
    /// each tracing a unified path: horizontal underline from chip to
    /// the active tab's left apex (if the group contains the active
    /// tab) → up over the active tab outline → down to the right apex
    /// → horizontal underline to the last member tab. For groups that
    /// don't contain the active tab the path is just the horizontal
    /// segment.
    ///
    /// Single path means the seam at the inverse-curve apex no longer
    /// exists by construction — stroke is one continuous shape.
    private func updateGroupBoundaryLayers(apexY: CGFloat, invR: CGFloat, activeTab: Tab?) {
        let traditionalLayout = PhiPreferences.GeneralSettings.loadLayoutMode().isTraditional
        guard traditionalLayout,
              let geometries = tabStripBarController?.groupGeometries(in: view,
                                                                       activeTab: activeTab) else {
            clearGroupBoundaryLayers()
            return
        }

        // Tear down vanished tokens.
        let liveTokens = Set(geometries.map { $0.token })
        for (token, layer) in groupBoundaryLayers where !liveTokens.contains(token) {
            layer.removeFromSuperlayer()
            groupBoundaryLayers.removeValue(forKey: token)
        }

        let cornerR = TabStripMetrics.Tab.cornerRadius
        let activeFrame = tabStripBarController?.tabFrame(for: activeTab, in: view)

        for geom in geometries {
            guard let group = browserState?.groups[geom.token] else { continue }

            let layer: CAShapeLayer
            if let existing = groupBoundaryLayers[geom.token] {
                layer = existing
            } else {
                layer = CAShapeLayer()
                layer.fillColor = NSColor.clear.cgColor
                layer.lineWidth = 1
                layer.lineCap = .butt
                layer.lineJoin = .round
                layer.zPosition = LayerZIndex.contentOuterBorder + 1
                layer.actions = ["strokeColor": NSNull(), "lineWidth": NSNull()]
                view.layer?.addSublayer(layer)
                groupBoundaryLayers[geom.token] = layer
            }

            // Inset the horizontal segment ends so the underline
            // doesn't bleed into an adjacent (non-member) active
            // tab's inverse-curve "shadow". An active tab's apex
            // tip extends `invR − interTabGap` (= 8 − 3 = 5pt) past
            // its neighboring chip's leading edge; without this
            // inset our underline pokes 5pt under that adjacent
            // apex curve, leaving a small triangular seam between
            // the (gray) curve and the (colored) horizontal line.
            //
            // For groups whose active member sits at this boundary
            // we keep the path extending all the way to its own
            // apex tip via `min`/`max` — the inset only affects the
            // free, non-curving end.
            let edgeInset: CGFloat = invR - 3
            let leftInsetX = geom.leftX + edgeInset
            let rightInsetX = geom.rightX - edgeInset

            let path = CGMutablePath()
            if geom.containsActive, let af = activeFrame {
                let leftLineStart = min(leftInsetX, af.minX - invR)
                let rightLineEnd = max(rightInsetX, af.maxX + invR)
                path.move(to: CGPoint(x: leftLineStart, y: apexY))
                path.addLine(to: CGPoint(x: af.minX - invR, y: apexY))
                // up the left inverse curve
                path.addCurve(
                    to: CGPoint(x: af.minX, y: apexY + invR),
                    control1: CGPoint(x: af.minX - invR / 2, y: apexY),
                    control2: CGPoint(x: af.minX, y: apexY + invR / 2)
                )
                // up the left side
                path.addLine(to: CGPoint(x: af.minX, y: af.maxY - cornerR))
                // top-left corner
                path.addCurve(
                    to: CGPoint(x: af.minX + cornerR, y: af.maxY),
                    control1: CGPoint(x: af.minX, y: af.maxY - cornerR / 2),
                    control2: CGPoint(x: af.minX + cornerR / 2, y: af.maxY)
                )
                // top edge
                path.addLine(to: CGPoint(x: af.maxX - cornerR, y: af.maxY))
                // top-right corner
                path.addCurve(
                    to: CGPoint(x: af.maxX, y: af.maxY - cornerR),
                    control1: CGPoint(x: af.maxX - cornerR / 2, y: af.maxY),
                    control2: CGPoint(x: af.maxX, y: af.maxY - cornerR / 2)
                )
                // down the right side
                path.addLine(to: CGPoint(x: af.maxX, y: apexY + invR))
                // down the right inverse curve
                path.addCurve(
                    to: CGPoint(x: af.maxX + invR, y: apexY),
                    control1: CGPoint(x: af.maxX, y: apexY + invR / 2),
                    control2: CGPoint(x: af.maxX + invR / 2, y: apexY)
                )
                // right apex → horizontal → group-right (or apex tip
                // itself if active is the rightmost / only member).
                path.addLine(to: CGPoint(x: rightLineEnd, y: apexY))
            } else {
                // No active tab in this group — just a horizontal
                // underline along the strip's bottom edge, with the
                // same 5pt edge inset so adjacent active apexes
                // outside this group don't clip our line.
                path.move(to: CGPoint(x: leftInsetX, y: apexY))
                path.addLine(to: CGPoint(x: rightInsetX, y: apexY))
            }

            layer.path = path
            // `NSColor(resource:).cgColor` resolves against
            // `NSAppearance.currentDrawing()`, which isn't pinned here
            // — `updateGroupBoundaryLayers` runs from `viewDidLayout`,
            // a layout callback (not a draw callback). Pin it to the
            // host view's appearance so the underline picks up the
            // same variant the chip dot uses.
            view.effectiveAppearance.performAsCurrentDrawingAppearance {
                layer.strokeColor = group.color.nsColor.cgColor
            }
        }
    }

    private func clearGroupBoundaryLayers() {
        for (_, layer) in groupBoundaryLayers {
            layer.removeFromSuperlayer()
        }
        groupBoundaryLayers.removeAll()
    }
    
    // MARK: - Tab Management
    
    private func handleFocusingTabChanged(_ tab: Tab?) {
        guard let tab, let state = browserState else { return }

        let identifier = state.getTabIdentifier(for: tab)
        // Skip if already showing this exact tab. Identifier alone can
        // collide: when a bookmark-bound tab is detached (its `guidInLocalDB`
        // cleared as it joins a split) and then a fresh tab is opened with
        // the same bookmark guid via `customGuid`, both share the bookmark
        // guid as identifier even though they're different Chromium tabs.
        // If we relied on identifier alone we'd short-circuit here and the
        // old split-pane controller would stay mounted under the new tab's
        // focus, leaving the splitview on screen. Require the underlying
        // Chromium tab to match too.
        let alreadyShowingExactTab = identifier == currentTabIdentifier
            && currentWebContentController?.associatedTab?.guid == tab.guid

        // Cancel a stale unpainted-tab switch BEFORE the early return below.
        // Focus can bounce back to the already-mounted tab while a pending
        // switch for another tab is still armed — e.g. the space-routing
        // throttle closes a target=_blank popup right after it was activated.
        // Returning without cancelling would let the first-paint timeout
        // promote the dead popup's view over the live tab, blanking the
        // content area until the user manually switches tabs.
        cancelPendingNewTabSwitchIfNeeded(nextTabId: tab.guid, nextIdentifier: identifier)

        guard !alreadyShowingExactTab else { return }

        // Any move to a different tab invalidates a flying chat ghost. The
        // per-controller drop sites below miss the identifier-collision
        // case above, where the SAME controller is rebound to a different
        // Chromium tab and swaps its content without a controller switch.
        dropClosingAIChatGhost()

        // Clear status URL when switching tabs
        state.targetURL = ""

        // Get or create WebContentViewController for this tab
        let controller = getOrCreateWebContentController(for: tab, identifier: identifier)

        // =========================================================================
        // Flicker fix: Choose switch strategy based on whether tab has painted
        // =========================================================================

        let leavingSplit = currentWebContentController?.associatedTab.map {
            state.splitGroup(forTabId: $0.guid) != nil
        } ?? false
        let enteringSplit = state.splitGroup(forTabId: tab.guid) != nil

        if tab.hasFirstPaint {
            // Scenario 1: Tab has already painted, switch immediately (bring to front)
            // AppLogDebug("[FlickerFix][Mac] Tab has first paint, using immediate switch (scenario 1)")
            switchToWebContentController(controller)
            currentTabIdentifier = identifier
        } else if leavingSplit && !enteringSplit {
            // Leaving a split for a non-split tab — the split's pane host
            // shouldn't linger via the flicker-fix deferral. Force the
            // immediate switch so the new tab takes over.
            switchToWebContentController(controller)
            currentTabIdentifier = identifier
        } else {
            // Scenario 2: New tab hasn't painted yet, add view below current and wait for first paint
            // AppLogDebug("[FlickerFix][Mac] 📤 New tab hasn't painted, deferring display until first paint (scenario 2)")
            switchToNewUnpaintedTab(controller: controller, tab: tab, identifier: identifier)
        }
    }
    
    /// Drive the active tab's content mount after the window is restored from
    /// the Dock. A window created minimized never runs `viewWillAppear` for
    /// this controller (AppKit doesn't run appearance for a Dock/off-screen
    /// window, and deminiaturizing doesn't re-trigger it), so the `$focusingTab`
    /// subscription that mounts tab content was never installed. Re-run the
    /// appearance-time setup (idempotent) and drive the current tab.
    func mountActiveTabForRestore() {
        viewWillAppear()
        if let tab = browserState?.focusingTab {
            handleFocusingTabChanged(tab)
        }
    }

    /// Forces the active tab's new-tab page back to a clean state after a Space
    /// URL rule routed a new-tab navigation elsewhere. The active
    /// `WebContentViewController` owns whether that means a Chromium-rendered NTP
    /// or the native incognito NTP.
    func refreshActiveNewTab() {
        currentWebContentController?.resetToCleanNewTab()
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
    
    /// Resolve the controller owning `tab`'s content WITHOUT the
    /// `updateAssociatedTab` side effects of the focus-switch path. Used by a
    /// focused split pane's controller to borrow its PARTNER pane's content
    /// view — the native incognito NTP view is owned by the partner tab's
    /// controller, unlike `Tab.webContentView` which lives on the Tab itself.
    ///
    /// MUST stay side-effect-free with respect to mounting: it is called from
    /// inside `installSplitContent`, and running `updateAssociatedTab` here
    /// re-enters the partner's own mount path — with two native-NTP panes the
    /// two controllers then remount each other forever (stack overflow).
    /// Creating a missing controller is safe (init only stores the tab); the
    /// cascade lives in `updateAssociatedTab`, which this never calls.
    /// Deliberately does not read `currentWebContentController` (see the NB
    /// in `switchToWebContentController` about lookups reachable from
    /// `refreshContentForCurrentTab`).
    func splitPaneCompanionController(for tab: Tab) -> WebContentViewController? {
        guard let state = browserState else { return nil }
        let identifier = state.getTabIdentifier(for: tab)
        if let existing = webContentControllers[identifier] {
            return existing
        }
        if let byGuid = webContentControllers.first(where: { $0.value.associatedTab?.guid == tab.guid })?.value {
            return byGuid
        }
        let controller = WebContentViewController(state: state, tab: tab)
        webContentControllers[identifier] = controller
        return controller
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

    private func prepareSharedBookmarkBarSlot(for controller: WebContentViewController) {
        guard let bookmarkBar = ensureSharedBookmarkBar() else { return }
        controller.updateBookmarkBarVisibility(bookmarkCount: bookmarkBar.bookmarkCount)
    }
    
    // MARK: - Placeholder Shell

    /// Mount the placeholder shell inside `contentContainer` and ask it to
    /// host the placeholder WebContents NSView. Idempotent: re-mounts the
    /// nativeView on the existing shell if one is already attached.
    @MainActor
    private func attachPlaceholderShell() {
        guard let wrapper = browserState?.placeholderWrapper,
              let nativeView = wrapper.nativeView else {
            AppLogWarn("🦖 [Container] attachPlaceholderShell: no wrapper/nativeView")
            return
        }

        let shell: PlaceholderShellViewController
        if let existing = placeholderShell {
            shell = existing
        } else {
            shell = PlaceholderShellViewController(browserState: browserState)
            addChild(shell)
            contentContainer.addSubview(shell.view)
            shell.view.snp.remakeConstraints { make in
                make.edges.equalToSuperview()
            }
            placeholderShell = shell
        }
        shell.mountPlaceholderNativeView(nativeView)

        // Focus the placeholder so the user can immediately press Space to
        // start the dino game without first clicking the canvas.
        // Two-step focus matches WebContentViewController.focusWebContent:
        //   1. Cocoa-level: window.makeFirstResponder routes Cocoa events.
        //   2. Chromium-level: wrapper.focus() routes Chromium's internal
        //      focus tracker so the renderer receives keystrokes. Without
        //      it, makeFirstResponder alone may leave the renderer in a
        //      "not focused" state and keyDown events go nowhere.
        // wrapper.focus() may silently fail if chrome://dino hasn't
        // committed navigation yet (URL=nil), but the page loads fast
        // enough that the first user keystroke arrives after commit.
        nativeView.window?.makeFirstResponder(nativeView)
        if wrapper.responds(to: #selector(WebContentWrapper.focus)) {
            wrapper.focus()
        }

        AppLogInfo("🦖 [Container] attached placeholder shell + focused")
    }

    /// Tear down the placeholder shell. Synchronous structural cleanup —
    /// `BrowserState.exitPlaceholderMode` already removed the underlying
    /// NSView from the hierarchy (the Combine sink fires synchronously).
    /// See spec §9.1.
    @MainActor
    private func detachPlaceholderShell() {
        placeholderShell?.unmountPlaceholderNativeView()
        placeholderShell?.view.removeFromSuperview()
        placeholderShell?.removeFromParent()
        placeholderShell = nil
        AppLogInfo("🦖 [Container] detached placeholder shell")
    }

    // MARK: - Extension side panel (window-level right slot)

    /// Mount the extension side panel's NSView in the window-level right
    /// slot, creating the slot on first open. Re-mounts on content change
    /// (the bridge pushes a new wrapper when the shown panel is replaced).
    /// The mount ordering (addSubview first, then
    /// translatesAutoresizingMaskIntoConstraints, then snp) mirrors the
    /// placeholder shell — the ordering AppKit needs for out-of-band
    /// Chromium WebContents views to render. A fresh open slides the slot
    /// in from the right edge (AI Chat's expand feel); a content
    /// replacement swaps the payload in place, matching Chrome's
    /// no-animation tab-switch recomputation.
    ///
    /// Internal (not private) only so layout tests can drive the slot
    /// directly; production traffic must keep flowing through the
    /// `BrowserState.$extensionSidePanel` sink above.
    @MainActor
    func attachExtensionSidePanel(_ panel: BrowserState.ExtensionSidePanelState) {
        guard let nativeView = panel.wrapper.nativeView else {
            AppLogWarn("[ExtSidePanel] [Container] attach: wrapper has no nativeView")
            return
        }
        // A reopen while the previous panel is still sliding out: drop the
        // outgoing ghost immediately so two cards never overlap.
        if let closing = closingExtensionSidePanelView {
            closing.removeFromSuperview()
            closingExtensionSidePanelView = nil
        }
        let isFreshOpen = extensionSidePanelView == nil
        let panelView: ExtensionSidePanelView
        if let existing = extensionSidePanelView {
            panelView = existing
        } else {
            panelView = ExtensionSidePanelView(
                initialWidth: extensionSidePanelPreferredWidth)
            panelView.onCloseRequested = { [weak self] in
                self?.browserState?.requestExtensionSidePanelClose()
            }
            view.addSubview(panelView)
        }
        panelView.updateHeader(displayName: panel.displayName,
                               iconPNG: panel.iconPNG)

        let hostView = panelView.contentHostView
        if nativeView.superview !== hostView {
            nativeView.removeFromSuperview()
            hostView.addSubview(nativeView)
            nativeView.translatesAutoresizingMaskIntoConstraints = false
            nativeView.snp.remakeConstraints { make in
                make.edges.equalToSuperview()
            }
        }

        if isFreshOpen {
            slideInExtensionSidePanel(panelView)
            // Chrome focuses the panel when it opens; mirror the placeholder
            // shell's two-step focus so typing lands in the panel page
            // without a click. Content changes (tab-switch recomputation)
            // must not steal focus, hence fresh-open only.
            nativeView.window?.makeFirstResponder(nativeView)
            if panel.wrapper.responds(to: #selector(WebContentWrapper.focus)) {
                panel.wrapper.focus()
            }
        }
        AppLogInfo("[ExtSidePanel] [Container] attached panel extensionId=\(panel.extensionId) freshOpen=\(isFreshOpen)")
    }

    /// Settle a freshly opened panel into the right slot, animating it in
    /// from the window's right edge while the page area shrinks in the same
    /// animation group (matching the AI Chat expand: default
    /// NSAnimationContext duration, page frame sync paused for the ride).
    /// The panel starts frame-driven just off-screen; re-installing its
    /// constraints inside the group makes the implicit animation
    /// interpolate every affected frame to the settled layout.
    @MainActor
    private func slideInExtensionSidePanel(_ panelView: ExtensionSidePanelView) {
        extensionSidePanelView = panelView
        guard !skipsPanelSlideAnimation else {
            remakeContentLayout()
            settlePanelTransitionOuterBorder()
            return
        }

        view.layoutSubtreeIfNeeded()
        // An expanded AI Chat must leave the split layout before this
        // group targets the narrowed container: the mutex sweep in
        // `BrowserState.updateExtensionSidePanel` flips the tab model only
        // after the panel publish, and its per-tab observer lands a turn
        // later — so this turn's constraint solution would still contain
        // the expanded chat and the animation would drag the chat card
        // left. The chat detaches now (state first) and its snapshot ghost
        // slides out to the right edge — the slide-out afterglow pattern
        // of `detachExtensionSidePanel`, mirrored. The item flip stays
        // un-laid-out until the panel group's layout pass so the page
        // pane's reflow rides the same implicit animation.
        let chatGhost = currentWebContentController?
            .collapseAIChatForPanelTransition(ghostIn: view)
        if let chatGhost {
            dropClosingAIChatGhost()
            closingAIChatGhostView = chatGhost
            view.addSubview(chatGhost, positioned: .above, relativeTo: panelView)
            AppLogInfo("[ExtSidePanel] [Container] chat ghost sliding out for panel open")
            // The slide kicks off one turn later, NOT inside the panel
            // group below: the ghost only enters the layer tree at this
            // turn's commit, and a same-transaction frame change is
            // coalesced into that first commit instead of animating — the
            // ghost pops straight off-screen and the chat appears to
            // vanish (observed on-device). One turn later it animates
            // from its committed on-screen frame; the single-frame
            // stagger against the panel group is the same offset the
            // approved panel-close ↔ chat-expand transition has.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.closingAIChatGhostView === chatGhost
                else { return }
                NSAnimationContext.runAnimationGroup({ context in
                    context.allowsImplicitAnimation = true
                    chatGhost.frame.origin.x =
                        self.view.bounds.maxX + WebContentConstant.edgesSpacing
                }, completionHandler: { [weak self] in
                    guard let self,
                          self.closingAIChatGhostView === chatGhost
                    else { return }
                    chatGhost.removeFromSuperview()
                    self.closingAIChatGhostView = nil
                })
            }
        }
        // Off-screen starting frame. y/height only approximate the settled
        // slot (they assume the default non-flipped geometry); any offset
        // is absorbed by the animation converging on the constraint
        // solution.
        let containerFrame = contentContainer.frame
        let panelInset = CGFloat(WebContentConstant.contentEdgeSpacing)
        panelView.translatesAutoresizingMaskIntoConstraints = true
        panelView.frame = NSRect(
            x: view.bounds.maxX + WebContentConstant.edgesSpacing,
            y: containerFrame.minY + WebContentConstant.edgesSpacing + panelInset,
            width: ExtensionSidePanelView.clampedWidth(extensionSidePanelPreferredWidth),
            height: max(0, containerFrame.height - WebContentConstant.edgesSpacing
                        - panelInset * 2))
        // Pre-seed the frame-interior fill frame-driven at the panel's
        // off-screen origin so the animation group slides both in
        // together; remakeContentLayout switches it to constraints.
        let backdrop = ensureExtensionSidePanelFrameBackdrop()
        backdrop.translatesAutoresizingMaskIntoConstraints = true
        backdrop.frame = NSRect(
            x: panelView.frame.minX,
            y: panelView.frame.minY - panelInset,
            width: panelView.frame.width + panelInset,
            height: panelView.frame.height + panelInset * 2)

        let pausedController = currentWebContentController
        pausedController?.setContentFrameSyncPausedForPanelTransition(true)
        NSAnimationContext.runAnimationGroup({ context in
            context.allowsImplicitAnimation = true
            panelView.translatesAutoresizingMaskIntoConstraints = false
            remakeContentLayout()
            view.layoutSubtreeIfNeeded()
        }, completionHandler: { [weak self, weak pausedController] in
            pausedController?.setContentFrameSyncPausedForPanelTransition(false)
            // Settle on completion only: during the slide the stale outline
            // still traces the full-width card the panel is covering, while
            // an immediate snap would draw the narrow outline across the
            // not-yet-shrunk page.
            self?.settlePanelTransitionOuterBorder()
        })
    }

    /// Drops a mid-flight AI Chat ghost. The snapshot belongs to the pane
    /// it was captured from: once another controller takes over the
    /// content area (tab switch, current-tab close, deferred first-paint
    /// promotion) the afterglow would parade the previous tab's chat
    /// pixels over the new content, so it goes down with its pane instead
    /// of finishing the slide.
    private func dropClosingAIChatGhost() {
        closingAIChatGhostView?.removeFromSuperview()
        closingAIChatGhostView = nil
    }

    /// Remove the right slot, sliding the card out to the right edge while
    /// the page area grows back (AI Chat's collapse feel). The Chromium
    /// panel NSView still detaches SYNCHRONOUSLY inside this sink —
    /// `BrowserState.updateExtensionSidePanel` publishes the close before
    /// its backstop detach precisely so the still-attached view can be
    /// snapshotted here first (Chromium may destroy it right after the
    /// bridge push returns); the slide-out shows that snapshot instead.
    /// State flips first (`extensionSidePanelView` nils out, the layout
    /// funnel returns to the no-panel solution); the ghost card animating
    /// off-screen is pure afterglow.
    ///
    /// Internal (not private) only so layout tests can drive the slot
    /// directly; production traffic must keep flowing through the
    /// `BrowserState.$extensionSidePanel` sink above.
    @MainActor
    func detachExtensionSidePanel() {
        guard let panelView = extensionSidePanelView else { return }
        extensionSidePanelPreferredWidth = panelView.preferredWidth

        // A chat ghost from the opening transition must not outlive the
        // panel: when this close comes from the AI Chat mutex the real
        // chat is about to re-expand exactly where the ghost still flies.
        dropClosingAIChatGhost()

        // Window-server snapshot of the closing content (maskClosingTab's
        // capture path — local snapshot APIs return blank for the remote
        // Chromium layer). Best effort: without it the card slides out
        // with its header over an empty background.
        let snapshot = WebContentSnapshotter.captureOnScreen(
            panelView.contentHostView, resolution: .bestResolution)
        for subview in panelView.contentHostView.subviews {
            subview.removeFromSuperview()
        }
        if let snapshot {
            let imageView = NSImageView()
            imageView.image = snapshot
            imageView.imageScaling = .scaleAxesIndependently
            imageView.frame = panelView.contentHostView.bounds
            panelView.contentHostView.addSubview(imageView)
        }

        extensionSidePanelView = nil

        if skipsPanelSlideAnimation {
            panelView.removeFromSuperview()
            extensionSidePanelFrameBackdrop?.removeFromSuperview()
            extensionSidePanelFrameBackdrop = nil
            remakeContentLayout()
        } else {
            closingExtensionSidePanelView = panelView
            let pausedController = currentWebContentController
            pausedController?.setContentFrameSyncPausedForPanelTransition(true)
            NSAnimationContext.runAnimationGroup({ context in
                context.allowsImplicitAnimation = true
                // Freeze the card at its current frame, then slide it off
                // the right edge; the layout funnel (no-panel solution now)
                // animates the page area back to full width in the same
                // group.
                let frozenFrame = panelView.frame
                panelView.snp.removeConstraints()
                panelView.translatesAutoresizingMaskIntoConstraints = true
                panelView.frame = frozenFrame
                // The frame-interior fill stays put (frozen, not slid): the
                // re-expanding page container covers it during the group,
                // so removing it with the ghost is invisible. Sliding it
                // with the card would expose window background behind the
                // ghost mid-flight. Demote it below contentContainer for
                // the ride — while mounted it sits above the container (to
                // cover the vibrancy strip), but here the growing page must
                // paint over it.
                if let backdrop = extensionSidePanelFrameBackdrop {
                    let backdropFrame = backdrop.frame
                    backdrop.snp.removeConstraints()
                    backdrop.translatesAutoresizingMaskIntoConstraints = true
                    backdrop.frame = backdropFrame
                    view.addSubview(backdrop, positioned: .below,
                                    relativeTo: contentContainer)
                }
                remakeContentLayout()
                panelView.frame.origin.x =
                    view.bounds.maxX + WebContentConstant.edgesSpacing
                view.layoutSubtreeIfNeeded()
            }, completionHandler: { [weak self, weak pausedController] in
                pausedController?.setContentFrameSyncPausedForPanelTransition(false)
                self?.settlePanelTransitionOuterBorder()
                guard let self, self.closingExtensionSidePanelView === panelView
                else { return }
                panelView.removeFromSuperview()
                self.closingExtensionSidePanelView = nil
                self.extensionSidePanelFrameBackdrop?.removeFromSuperview()
                self.extensionSidePanelFrameBackdrop = nil
            })
        }
        settlePanelTransitionOuterBorder()
        AppLogInfo("[ExtSidePanel] [Container] detached panel slot")

        // Closing the panel usually leaves the window with no meaningful
        // first responder: the panel content is already off the hierarchy
        // (BrowserState detached it synchronously) and the header's close
        // button died with the slot. Hand focus back to the page — the same
        // destination Chrome picks after a side panel closes. Skip when
        // something else (omnibox, sidebar) legitimately holds focus.
        // Deferred one turn: this sink runs inside Chromium's synchronous
        // bridge push, where focus work could re-enter Chromium; the hop
        // also skips the restore naturally when the window is being torn
        // down (view.window is gone by the time it fires).
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.extensionSidePanelView == nil,
                  let window = self.view.window,
                  window.firstResponder == nil || window.firstResponder === window
            else { return }
            self.currentWebContentController?.focusWebContent()
        }
    }

    /// Re-derives the content outline once a panel transition's layout has
    /// settled. The viewDidLayout recompute that fires inside the
    /// transition's own layout pass reads `splitViewContainerFrame` before
    /// the split-view subtree has re-laid out (top-down layout order), so
    /// the outline is left at the pre-transition geometry — a stray border
    /// line over the page after a close — and, with the container not laid
    /// out again, nothing heals it until the next window resize. Same
    /// stale-convert hazard `switchToWebContentController` documents before
    /// its own explicit recompute.
    private func settlePanelTransitionOuterBorder() {
        view.layoutSubtreeIfNeeded()
        updateContentOuterBorder()
    }

    // MARK: - Close Snapshot Placeholder
    //
    // Hides the gray/black flash when closing the ACTIVE tab. Must run SYNCHRONOUSLY
    // from PhiChromiumCoordinator.tabWillBeRemove — the async EventBus close fires
    // only after Chromium destroys the WebContents, too late to capture pixels.

    /// Lay a static snapshot of the closing active tab over the content area.
    /// No-op (degrades to today's flash) if the closing tab isn't on-screen or capture fails.
    @MainActor
    func maskClosingTab(tabId: Int) {
        guard let controller = currentWebContentController,
              controller.associatedTab?.guid == tabId else {
            return
        }
        // Single slot: clear any prior snapshot before capturing (rapid close).
        clearClosePlaceholder()

        // Snapshot only the inset web-content region, not the side margins: covering
        // them makes AppKit additively re-tint that vibrancy strip, and it flickers.
        let contentView = controller.closeSnapshotSourceView
        // Comfortable draws a 1pt active-tab outline (outerBorderLayer) ABOVE this
        // snapshot and re-morphs it on close; inset past it so the live layer owns it.
        let borderInset: CGFloat = outerBorderLayer.path == nil ? 0 : outerBorderLayer.lineWidth
        guard let image = WebContentSnapshotter.captureOnScreen(contentView, resolution: .bestResolution, insetBy: borderInset) else {
            AppLogDebug("[CloseSnapshot] capture failed for tab \(tabId) — falling back to flash")
            return
        }

        let imageView = NSImageView()
        imageView.image = image
        imageView.imageScaling = .scaleAxesIndependently
        // Mirror the source's rounded corners (shrunk by the inset) so it lines up.
        imageView.wantsLayer = true
        if let sourceLayer = contentView.layer {
            imageView.layer?.cornerCurve = sourceLayer.cornerCurve
            imageView.layer?.cornerRadius = max(0, sourceLayer.cornerRadius - borderInset)
            imageView.layer?.masksToBounds = true
        }
        // Cover only the inset content region; margins (and the outline) stay live.
        imageView.frame = contentView.convert(contentView.bounds, to: contentContainer).insetBy(dx: borderInset, dy: borderInset)
        contentContainer.addSubview(imageView)
        // Commit the snapshot to the WindowServer synchronously, before this bridge
        // callback returns and Chromium destroys the closing tab. Otherwise its CA
        // commit can land a frame AFTER the remote layer has blanked (async, on the
        // GPU/WindowServer side) → a 1-frame blank that then "recovers" = the flicker.
        imageView.display()
        CATransaction.flush()
        closePlaceholder = imageView

        let timeout = DispatchWorkItem { [weak self] in
            self?.clearClosePlaceholder()
        }
        closePlaceholderTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.closeSnapshotTimeoutSeconds, execute: timeout)
    }

    /// Remove the close snapshot placeholder and cancel its timeout. Idempotent.
    @MainActor
    private func clearClosePlaceholder() {
        guard closePlaceholder != nil || closePlaceholderTimeout != nil else { return }
        closePlaceholderTimeout?.cancel()
        closePlaceholderTimeout = nil
        closePlaceholder?.removeFromSuperview()
        closePlaceholder = nil
    }

    /// Scenario 1: Switch to an already-painted tab (immediate switch, bring to front)
    private func switchToWebContentController(_ controller: WebContentViewController) {
        // Flicker fix: Don't remove old view immediately, defer until Chromium confirms.
        // Save old controller/view for later cleanup.
        if let current = currentWebContentController, current !== controller {
            pendingViewCleanup = (controller: current, view: current.view)
            // Outgoing focused VC no longer owns the split host — drop its
            // partner-crash subscription (its own observers won't re-run).
            current.cancelPartnerCrashSubscription()
            // A chat ghost snapped from the outgoing pane must not slide
            // over the incoming tab's content.
            dropClosingAIChatGhost()
            AppLogDebug("[WebContent] Deferring cleanup of previous controller, waiting for Chromium confirmation")
        }

        // Add new controller
        if controller.parent !== self {
            addChild(controller)
        }

        let controllerView = controller.view
        prepareSharedBookmarkBarSlot(for: controller)

        // Add new view on top (old view stays underneath until cleanup)
        if controllerView.superview !== contentContainer {
            contentContainer.addSubview(controllerView)
            controllerView.snp.remakeConstraints { make in
                make.edges.equalToSuperview()
            }
        } else {
            // If already in container, bring to front
            contentContainer.addSubview(controllerView, positioned: .above, relativeTo: nil)
        }

        attachSharedBookmarkBar(to: controller)

        // Re-mount content before we mark this controller as current.
        // For split tabs, the partner's webContentView may have been
        // reparented into another controller's split host. For tabs whose
        // split was dissolved while they were inactive, a stale split host
        // may still be hanging around. In both cases this reconciles.
        //
        // NB: code reachable from `refreshContentForCurrentTab` must NOT read
        // `currentWebContentController` — it still points at the outgoing VC
        // until the assignment below. Today the reachable code stays inside
        // the controller's own host; if you add a container-level lookup,
        // consult the `controller` parameter explicitly instead.
        controller.refreshContentForCurrentTab()

        currentWebContentController = controller
        // Now the focused split host (if in a split) — watch the partner pane's
        // crashState so a non-focused-pane crash shows without a focus switch.
        controller.updatePartnerCrashSubscription()
        // Force a full layout sweep before reading splitViewContainer's frame.
        // Otherwise — if the window was just resized (e.g. titlebar
        // double-click zoom) and a layout pass is still pending — the convert
        // chain (splitViewContainer → controller.view → contentContainer →
        // self.view) returns a stale rect, and the path gets drawn at the
        // previous size until the next viewDidLayout corrects it.
        view.layoutSubtreeIfNeeded()
        updateContentOuterBorder()

        // Notify Chromium that view switch is complete, it can now hide the old WebContents
        notifyViewSwitchCompleted()

        // Settled successor is now painted on top — drop the close snapshot (if any).
        clearClosePlaceholder()

        cleanUpPendingSplitPartnerViewIfNeeded(incoming: controller)
    }

    /// A focus trade between the two panes of one split never gets the
    /// "previous tab hidden" confirmation from Chromium — the outgoing tab
    /// stays visible as the other pane — so the flicker-fix deferral above
    /// would leave the outgoing controller's view mounted behind the incoming
    /// one for the life of the split. NSTrackingAreas ignore sibling
    /// occlusion, so that buried view's header keeps reacting to hover (e.g.
    /// a ghost Reader View shortcut tooltip at the buried reader button's
    /// spot). Both panes' web content was already reparented into the
    /// incoming controller's split host by refreshContentForCurrentTab, so
    /// removing the buried view immediately is visually a no-op.
    private func cleanUpPendingSplitPartnerViewIfNeeded(incoming controller: WebContentViewController) {
        guard let pending = pendingViewCleanup,
              let state = browserState,
              let outgoingTabId = pending.controller.associatedTab?.guid,
              let incomingTabId = controller.associatedTab?.guid,
              let group = state.splitGroup(forTabId: incomingTabId),
              group.partnerTabId(of: incomingTabId) == outgoingTabId else { return }

        detachSharedBookmarkBar(from: pending.controller)
        pending.view.removeFromSuperview()
        pending.controller.removeFromParent()
        pendingViewCleanup = nil

        AppLogDebug("[WebContent] Cleaned up split-partner view immediately (no Chromium hide expected for a visible pane)")
    }

    /// Scenario 2: Switch to a new unpainted tab (add view below, wait for first paint)
    private func switchToNewUnpaintedTab(controller: WebContentViewController, tab: Tab, identifier: String) {
        // Defensive: a live host controller can be handed back here when a
        // controller is reused for a colliding bookmark/pinned identifier.
        // Re-pointing the current live host into the unpainted-pending slot
        // would later trip the bookmark-bar host assertion in
        // cancelPendingNewTabSwitchIfNeeded. If this controller is already the
        // live host, switch to it synchronously instead of pending it. The
        // duplicate-binding root cause is fixed Chromium-side at restore; this
        // guard remains as a second layer.
        if controller === currentWebContentController {
            switchToWebContentController(controller)
            currentTabIdentifier = identifier
            return
        }

        // Cancel any existing timeout
        pendingNewTabTimeoutWorkItem?.cancel()
        pendingNewTabTimeoutWorkItem = nil

        // Add new controller
        if controller.parent !== self {
            addChild(controller)
        }

        let controllerView = controller.view
        prepareSharedBookmarkBarSlot(for: controller)

        // Add new view BELOW the current view (old view stays on top and visible)
        if controllerView.superview !== contentContainer {
            // Insert at the bottom of the subview stack
            contentContainer.addSubview(controllerView, positioned: .below, relativeTo: currentWebContentController?.view)
            controllerView.snp.remakeConstraints { make in
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

        // If this tab closed while still waiting for its first paint, drop the
        // pending switch too — otherwise the first-paint timeout would promote
        // the dead controller's view over the live tab.
        if let pending = pendingNewTabSwitch, pending.controller === controller {
            pendingNewTabTimeoutWorkItem?.cancel()
            pendingNewTabTimeoutWorkItem = nil
            pendingNewTabSwitch = nil
            if pending.controller.view.superview === contentContainer {
                pending.controller.view.removeFromSuperview()
            }
        }

        // If this is the current controller, remove from view
        if controller === currentWebContentController {
            controller.view.removeFromSuperview()
            controller.removeFromParent()
            currentWebContentController = nil
            currentTabIdentifier = nil
            // A chat ghost snapped from the removed pane dies with it.
            dropClosingAIChatGhost()
            // Clear the unified outline so it doesn't linger over the now
            // detached content area until the next focus/layout pass.
            updateContentOuterBorder()
        }
        
        // Remove from dictionary
        webContentControllers.removeValue(forKey: identifier)
    }
    
    // MARK: - Layout Mode
    
    private func updateLayoutForMode() {
        let layoutMode = PhiPreferences.GeneralSettings.loadLayoutMode()
        let traditionalLayout = layoutMode.isTraditional

        titleAwareAreaHeightConstraint?.update(
            offset: WebContentConstant.titleAwareAreaHeight(for: layoutMode)
        )
        
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
            // This owns only the 8pt non-web gap above WebContents.
            titleAwareArea.isHidden = false
        }

        updateFloatingSidebarAvailability()
        updateContentOuterBorder()
        updatePageAreaBackdropLeadingInset()
    }

    /// Mirror of `WebContentViewController.updateSplitViewLeadingInset`, so
    /// the backdrop hugs the same leading edge the mounted panel uses.
    private var pageAreaLeadingInset: CGFloat {
        let traditionalLayout = PhiPreferences.GeneralSettings.loadLayoutMode().isTraditional
        let sidebarCollapsed = browserState?.sidebarCollapsed ?? true
        return (traditionalLayout || sidebarCollapsed)
            ? WebContentConstant.edgesSpacing
            : 0
    }

    /// Called from `updateLayoutForMode`, which already re-runs on layout-mode
    /// and sidebar-collapse changes. A bottom transcript dock shares the page
    /// panel's left edge, so it follows the same inset.
    private func updatePageAreaBackdropLeadingInset() {
        let inset = pageAreaLeadingInset
        pageAreaBackdropLeadingConstraint?.update(inset: inset)
        transcriptDockView?.updateLeadingInset(inset)
    }

    // MARK: - AI Chat Toggle
    
    /// Toggle AI Chat for the current tab
    /// This toggles the AI Chat state on the currently focused tab
    func toggleAIChat(trigger: BrowserState.AIChatSidebarOpenTrigger = .button) {
        guard browserState?.groupOverviewState == nil else { return }
        // Toggle on the current WebContentViewController (which will update the associated tab)
        if let controller = currentWebContentController {
            controller.toggleAIChatInTraditionalLayout(trigger: trigger)
        } else {
            // Fallback: directly toggle the focusingTab's state
            if let tab = browserState?.focusingTab {
                if tab.aiChatCollapsed {
                    browserState?.prepareAIChatSidebarOpen(trigger: trigger)
                }
                tab.toggleAIChat()
            }
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
            current.cancelPartnerCrashSubscription()
            // Same as switchToWebContentController: a chat ghost snapped
            // from the outgoing pane must not slide over the promoted tab.
            dropClosingAIChatGhost()
        }

        // Bring new view to front
        contentContainer.addSubview(pending.controller.view, positioned: .above, relativeTo: nil)

        attachSharedBookmarkBar(to: pending.controller)

        // Update current controller and identifier
        currentWebContentController = pending.controller
        currentTabIdentifier = pending.identifier
        // Same partner-crash subscription handoff as switchToWebContentController
        // — this deferred first-paint promotion is the other path that swaps the
        // focused split host.
        pending.controller.updatePartnerCrashSubscription()
        // Same reason as switchToWebContentController: force layout so the
        // splitViewContainer frame chain is fresh before computing the path.
        view.layoutSubtreeIfNeeded()
        updateContentOuterBorder()

        // Clear pending state
        pendingNewTabSwitch = nil

        // Now notify Chromium that view switch is complete
        // This triggers the old tab to be hidden and cleanup flow
        notifyViewSwitchCompleted()

        // New view is on top now — real first paint, or forced by the first-paint
        // timeout (successor may still be blank, accepted). Drop the close snapshot.
        clearClosePlaceholder()

        // "Open as Split" promotes the freshly-painted pane over its still-
        // visible partner — same no-Chromium-hide situation as a same-split
        // focus trade, so the deferred cleanup must not wait either.
        cleanUpPendingSplitPartnerViewIfNeeded(incoming: pending.controller)

        // AppLogDebug("[FlickerFix][Mac] ➡️ Sent confirmViewSwitchCompleted after new tab first paint")
    }

    // =========================================================================
    // DevTools embedding
    // =========================================================================

    /// Find the WebContentViewController managing a given Chromium tab ID.
    func findController(forTabId tabId: Int) -> WebContentViewController? {
        webContentControllers.values.first { $0.associatedTab?.guid == tabId }
    }

    /// True when the inspected tab is part of a split currently mounted by
    /// the visible WebContentViewController. In that case DevTools must dock
    /// into the matching pane's container — routing through the inspected
    /// tab's own (offscreen) controller would dump DevTools into a hostView
    /// that isn't in the window hierarchy.
    private func mountedSplitPane(forInspectedTabId tabId: Int)
        -> (controller: WebContentViewController, pane: SplitPaneHostView.Pane)? {
        guard let state = browserState,
              let group = state.splitGroup(forTabId: tabId),
              let mounted = currentWebContentController,
              let mountedTabId = mounted.associatedTab?.guid,
              group.contains(tabId: mountedTabId) else { return nil }
        let pane: SplitPaneHostView.Pane = group.primaryTabId == tabId ? .primary : .secondary
        return (mounted, pane)
    }

    /// Called when Chromium attaches docked DevTools to a tab.
    func handleDevToolsDidAttach(tabId: Int, devToolsView: NSView) {
        if let target = mountedSplitPane(forInspectedTabId: tabId) {
            target.controller.attachDevToolsToPane(tabId: tabId,
                                                   pane: target.pane,
                                                   devToolsView: devToolsView)
            return
        }
        guard let controller = findController(forTabId: tabId) else {
            AppLogInfo("[DevTools] No controller found for tabId=\(tabId)")
            return
        }
        controller.attachDevTools(view: devToolsView)
    }

    /// Called when Chromium detaches DevTools from a tab (closed or undocked).
    func handleDevToolsDidDetach(tabId: Int) {
        if let target = mountedSplitPane(forInspectedTabId: tabId) {
            target.controller.detachDevToolsFromPane(tabId: tabId, pane: target.pane)
            return
        }
        guard let controller = findController(forTabId: tabId) else {
            AppLogInfo("[DevTools] No controller found for tabId=\(tabId)")
            return
        }
        controller.detachDevTools()
    }

    /// Called when DevTools JS updates the inspected page bounds.
    func handleUpdateInspectedPageBounds(tabId: Int, bounds: CGRect, hide: Bool) {
        if let target = mountedSplitPane(forInspectedTabId: tabId) {
            target.controller.updateInspectedPageBoundsForPane(tabId: tabId,
                                                               pane: target.pane,
                                                               bounds: bounds,
                                                               hide: hide)
            return
        }
        guard let controller = findController(forTabId: tabId) else { return }
        controller.updateInspectedPageBounds(bounds, hide: hide)
    }

    // MARK: - Status URL Display

    private func updateStatusURL(_ url: String) {
        statusURLViewModel.url = url
    }
}

// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import SnapKit
import SwiftUI
import Combine

final class SpacesStripHostingView: ThemedHostingView {
    /// Converts wheel scrolling over the strip row into pip viewport steps for
    /// the hosted SpacesStripView (see SpacesStripWheelTracker), assigned by
    /// the controller that builds the strip. Vertical scrolling is consumed
    /// here so an overflowing row can be scrolled in place; horizontal
    /// trackpad gestures fall through to the sidebar controller's
    /// swipe-to-switch-Space handler up the responder chain.
    var wheelTracker: SpacesStripWheelTracker?

    /// The hosted strip's live pip/viewport geometry and chip-concealment
    /// flag, assigned by the controller that builds the strip (same wiring
    /// shape as `wheelTracker`). Nil only if a builder skips it — every
    /// flight entry point guards.
    var stripGeometry: SpacesStripGeometry?

    /// The stand-in chip currently flying, nil when idle. One flight at a
    /// time: a new begin sweeps the previous one first.
    private var chipFlightLayer: CALayer?

    override func scrollWheel(with event: NSEvent) {
        if wheelTracker?.handle(event) == true { return }
        super.scrollWheel(with: event)
    }

    /// Flies the glass chip from the source pip to the target pip as an
    /// EXPLICIT Core Animation layer animation — the one animation kind that
    /// keeps playing in the render server while the main thread is blocked
    /// (the materialize rebuild, the spawn's createBrowser; SwiftUI and
    /// NSAnimationContext view animations both freeze there). The SwiftUI
    /// chip is concealed in the same runloop turn, so the same CATransaction
    /// commits the swap — no doubled and no missing chip frame. The stand-in
    /// is swept by `cancelSpacesChipFlight` when the switch resolves.
    ///
    /// Returns false — with zero side effects — when the flight can't run
    /// (no geometry published yet, either pip not wholly inside the
    /// viewport's clip frame, degenerate input); the strip then behaves
    /// exactly as it did before this feature existed.
    func beginSpacesChipFlight(fromSpaceId: String,
                               toSpaceId: String,
                               duration: TimeInterval) -> Bool {
        guard let geometry = stripGeometry, let hostLayer = layer else { return false }
        // Eligibility first, sweep second: an ineligible begin must leave a
        // flight already on this strip untouched, or "returns false with
        // zero side effects" would hold only while no flight is live.
        guard let endpoints = Self.chipFlightEndpoints(
            fromSpaceId: fromSpaceId,
            toSpaceId: toSpaceId,
            pipFrames: geometry.pipFrames,
            viewportFrame: geometry.viewportFrame,
            duration: duration) else { return false }
        cancelSpacesChipFlight()
        let from = Self.chipLayerRect(endpoints.from, boundsHeight: bounds.height,
                                      isFlipped: isFlipped)
        let to = Self.chipLayerRect(endpoints.to, boundsHeight: bounds.height,
                                    isFlipped: isFlipped)
        var fill = NSColor(resource: .sidebarTabSelected).cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            fill = NSColor(resource: .sidebarTabSelected).cgColor
        }
        let chip = Self.makeChipFlightLayer(from: from, to: to, duration: duration,
                                            fillColor: fill)
        // Below the SwiftUI content, like the chip it stands in for — the
        // pips draw on top of it (zPosition < 0 sublayers composite under
        // the hosting view's SwiftUI layers; probed for the design).
        hostLayer.insertSublayer(chip, at: 0)
        chipFlightLayer = chip
        geometry.isChipConcealed = true
        return true
    }

    /// Sweeps the stand-in and restores the SwiftUI chip. Idempotent — wired
    /// into the switch's shared restoreLeaving, which every resolution
    /// (reveal, failure, supersession) funnels through.
    func cancelSpacesChipFlight() {
        chipFlightLayer?.removeFromSuperlayer()
        chipFlightLayer = nil
        if let geometry = stripGeometry, geometry.isChipConcealed {
            geometry.isChipConcealed = false
        }
    }

    /// Resolves a flight's endpoints, or nil ("don't fly") unless both pips
    /// have published frames lying ENTIRELY inside the viewport's clip
    /// frame. The stand-in layer is not subject to SwiftUI's `.clipped()`,
    /// so flying to or from a pip in the overflow region would show a chip
    /// floating outside the row; those switches keep today's behavior.
    static func chipFlightEndpoints(
        fromSpaceId: String,
        toSpaceId: String,
        pipFrames: [String: CGRect],
        viewportFrame: CGRect,
        duration: TimeInterval
    ) -> (from: CGRect, to: CGRect)? {
        guard duration > 0,
              fromSpaceId != toSpaceId,
              !viewportFrame.isEmpty,
              let from = pipFrames[fromSpaceId],
              let to = pipFrames[toSpaceId],
              viewportFrame.contains(from),
              viewportFrame.contains(to) else { return nil }
        return (from, to)
    }

    /// A frame measured in the strip root's SwiftUI coordinate space as this
    /// view's layer frame. NSHostingView is flipped (probed for the design),
    /// so the rect passes through; the y-flip branch guards a framework
    /// change, not a live path.
    static func chipLayerRect(_ rect: CGRect, boundsHeight: CGFloat,
                              isFlipped: Bool) -> CGRect {
        guard !isFlipped else { return rect }
        return CGRect(x: rect.minX, y: boundsHeight - rect.maxY,
                      width: rect.width, height: rect.height)
    }

    /// Builds the stand-in: the glass chip's look (8pt continuous corners,
    /// sidebar-tab-selected fill, the SwiftUI shadow's black 0.15 / radius 1
    /// / 1pt-down offset), with its MODEL geometry already at the target —
    /// the explicit animation plays the travel, and when CA removes it on
    /// completion the settled model shows. A model left at the source would
    /// snap the chip back mid-block the moment the animation expired.
    static func makeChipFlightLayer(from: CGRect, to: CGRect,
                                    duration: TimeInterval,
                                    fillColor: CGColor) -> CALayer {
        let chip = CALayer()
        chip.frame = to
        chip.backgroundColor = fillColor
        chip.cornerRadius = 8
        chip.cornerCurve = .continuous
        chip.shadowColor = NSColor.black.cgColor
        chip.shadowOpacity = 0.15
        chip.shadowRadius = 1
        chip.shadowOffset = CGSize(width: 0, height: 1)
        chip.zPosition = -1
        let slide = CABasicAnimation(keyPath: "position")
        slide.fromValue = CGPoint(x: from.midX, y: from.midY)
        slide.toValue = CGPoint(x: to.midX, y: to.midY)
        slide.duration = duration
        slide.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        chip.add(slide, forKey: "phiSpacesChipFlight")
        return chip
    }

    // Native AppKit tab groups can temporarily adjust titlebar/safe-area metrics
    // while their NSTabView/NSTabBar accessory is created or hidden. The Space
    // row is already positioned by SidebarHeaderView's fixed constraints, so its
    // SwiftUI content should ignore those transient safe-area changes.
    override var safeAreaInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }

    override var safeAreaRect: NSRect {
        bounds
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
}

class SidebarViewController: NSViewController {
    private static let defaultFavoriteHeight: CGFloat = 0
    private static let pinnedHeightPersistenceThreshold: CGFloat = 20
    private static let pinnedHeightCacheKey = "Sidebar.pinnedTabsContainerHeight.v1"

    /// Main vertical stack view for the sidebar layout.
    private lazy var mainStackView: NSStackView = {
        let stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .centerX
        stackView.spacing = 0
        stackView.distribution = .fill
        return stackView
    }()
    
    private lazy var headerView = SidebarHeaderView(state: state)
    private lazy var pinnedTabViewController = PinnedTabViewController(state: state, hostVC: self)
    private lazy var tabList = SidebarTabListViewController(state: state, hostVC: self)
    private var state: BrowserState
    /// Guards one-time download manager binding (see `bindDownloadsManagerIfNeeded`).
    private var didBindDownloadsManager = false
    /// SwiftUI-backed bottom toolbar.
    private(set) lazy var bottomBarSwiftUI: SidebarBottomBarSwiftUIView = {
        let view = SidebarBottomBarSwiftUIView()
        view.onFeedbackTap = { [weak self] in
            self?.state.windowController?.showFeedbackWindow()
        }
        view.onBookmarkTap = { [weak self] in
            let url = "phi://bookmarks"
            self?.state.openTab(URLProcessor.processUserInput(url))
        }
        view.onChatTap = { [weak self] in
            guard let self else { return }
            // Defense in depth: chat entry should be hidden in placeholder
            // mode. Early-return if a stale tap reaches this handler.
            guard self.state.isInPlaceholderMode == false,
                  self.state.groupOverviewState == nil else {
                NSSound.beep()
                return
            }
            FeatureEntryAnalytics.capture(.chat, surface: .sidebar)
            self.state.toggleAIChat()
        }
        view.onCardEntryTap = { [weak self] in
            self?.showMessageCardTemporarily()
        }
        view.onMemoryTap = {
            guard let state = BrowserState.currentState() else { return }
            FeatureEntryAnalytics.capture(.memory, surface: .sidebar)
            state.createTab(
                "chrome://memory/memory.html",
                focusAfterCreate: true
            )
            FirstTimeActionTracker.capture(.memoryOpened)
        }
        view.onDownloadTap = {
            FeatureEntryAnalytics.capture(.download, surface: .sidebar)
        }
        return view
    }()
    
    /// Wraps the pinned tab controller so its height can be adjusted independently.
    private lazy var pinnedTabContainerView: NSView = {
        let view = NSView()
        view.wantsLayer = true
        return view
    }()

    /// Per-Space tint painted behind the tab area — the active Space's
    /// `colorHex` fading from the top of the sidebar to clear at the bottom.
    /// During a vertical-layout Space switch this gradient ramps to the new
    /// color in step with the content-band push-in (see
    /// `SpaceManager.performVerticalSidebarPushIn`); because it sits behind
    /// `mainStackView` it shows through the band's transparent snapshot as it
    /// slides. Re-resolved when the slot's `activeSpaceId` changes or the
    /// underlying Space is recolored.
    private let spaceTintGradientLayer: CAGradientLayer = {
        let layer = CAGradientLayer()
        layer.startPoint = CGPoint(x: 0.5, y: 0)
        layer.endPoint = CGPoint(x: 0.5, y: 1)
        return layer
    }()

    private lazy var spaceTintBackgroundView: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.addSublayer(spaceTintGradientLayer)
        return view
    }()
    
    /// Container above the bottom bar for transient notification content.
    private lazy var notificationContainerView: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.isHidden = true
        return view
    }()
    
    /// Container above the bottom bar for message cards.
    private lazy var messageCardContainerView: NSView = {
        let view = NSView()
        view.wantsLayer = true
        return view
    }()

    /// Hosting controller for the Spaces strip — placed just above the bottom
    /// toolbar so the row of Space pips is the last per-Space element before
    /// the global actions. Reports its intrinsic height so the strip can grow
    /// to multiple rows when pips wrap.
    ///
    /// The strip is bound to its hosting window's `SpaceWindowSlot` so that
    /// clicks here only switch THIS window's active Space. The slot is
    /// resolved via `state.windowController?.slot`; for the early-init case
    /// where the window controller isn't wired up yet (BrowserState is
    /// constructed before the controller assigns itself in
    /// `MainBrowserWindowController.init`), fall back to the manager's
    /// `keySlot` as a stand-in — at cold start that IS this window's own slot.
    /// A stand-in only: `init` wires the controller before `setupWindow()`
    /// loads this view tree, so the first resolution is the one that answers
    /// in practice.
    /// The slot driving this sidebar's Spaces strip, resolved once so the
    /// create-Space overlay can flip the same instance's `isCreatingSpace`
    /// flag that the strip observes (see `showCreateSpaceOverlay`).
    ///
    /// Nil when neither resolves, and then no strip is mounted at all: a
    /// window with no slot must NOT mint one just to have something to bind
    /// to. A slot minted here registers no window, so `slots` never empties
    /// again and every later Dock reopen bypasses
    /// `reopenOnPersistedSpaceIfWindowless` and falls back to Chromium's own
    /// handler, landing on the wrong Space until the app restarts (see
    /// `SpaceManager.reclaimsMintedSlot`). `participatesInSpaces` does not
    /// keep that out on its own: a shadow window passes it (it is not
    /// incognito) and builds this sidebar from `viewDidLoad`, which runs even
    /// for a window that is never shown.
    private lazy var spacesStripSlot: SpaceWindowSlot? = state.windowController?.slot
        ?? SpaceManager.shared.keySlot

    private lazy var spacesStripHostingView: SpacesStripHostingView? = {
        guard let slot = spacesStripSlot else { return nil }
        let wheelTracker = SpacesStripWheelTracker()
        let stripGeometry = SpacesStripGeometry()
        let hostingView = SpacesStripHostingView(
            rootView: SpacesStripView(
                manager: SpaceManager.shared,
                slot: slot,
                rowHeight: SpacesStripView.sidebarHeight,
                resolveOwnerController: { [weak state] in state?.windowController },
                wheelTracker: wheelTracker,
                stripGeometry: stripGeometry
            ),
            themeSource: state.themeContext
        )
        hostingView.wheelTracker = wheelTracker
        hostingView.stripGeometry = stripGeometry
        if #available(macOS 13.0, *) {
            hostingView.sizingOptions = []
        }
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        return hostingView
    }()

    /// The Spaces strip row's AppKit view, resolved live by the slot's
    /// pointer-vs-row test (`SpaceWindowSlot.stripRowContainsPointer()`) so
    /// the geometry always comes from the window actually consulted. Set at
    /// mount; stays nil for incognito windows and for windows that resolve no
    /// slot (see `spacesStripSlot`), neither of which mounts the strip.
    private(set) weak var spacesStripRowView: NSView?

    /// Hosting controller for the sidebar message card view.
    private lazy var messageCardHostingController: ThemedHostingController<NotificationMessageCardView> = {
        let hostingController = ThemedHostingController(
            rootView: NotificationMessageCardView(
                manager: NotificationCardManager.shared,
                layoutMode: .sidebar,
                onRun: { card in
                    NotificationCardManager.shared.decide(card: card, decision: .accept)
                },
                onDismiss: { _ in
                    NotificationCardManager.shared.hideCard()
                },
                onDelete: { card in
                    NotificationCardManager.shared.decide(card: card, decision: .reject)
                }
            ),
            themeSource: state.themeContext
        )
        if #available(macOS 13.0, *) {
            hostingController.sizingOptions = []
        }
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        hostingController.view.setContentHuggingPriority(.required, for: .vertical)
        hostingController.view.setContentCompressionResistancePriority(.required, for: .vertical)
        return hostingController
    }()
    
    // MARK: - Private Properties
    
    private var cancellables = Set<AnyCancellable>()
    private var contentCancellables = Set<AnyCancellable>()
    private var headerHeightConstraint: Constraint?
    private var pinnedTabsHeightConstraint: Constraint?
    private var pinSpacerHeightConstraint: Constraint?
    private var bottomBarHeightConstraint: Constraint?
    private var messageCardHeightConstraint: Constraint?
    private var hasSetupObservers = false
    private var hasSetupConfigObserver = false
    private var isSidebarContentActive = false
    private var lastPersistedFavoriteHeight: CGFloat?

    /// Swipe-to-switch-Space gesture state (see `SpaceSwipeTracker`).
    private let spaceSwipe = SpaceSwipeTracker()
    
    init(browserState: BrowserState) {
        self.state = browserState
        super.init(nibName: nil, bundle: nil)
    }
    
    
    @MainActor required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    // MARK: - Lifecycle
    
    override func loadView() {
        let view = ColoredVisualEffectView()
        view.themedBackgroundColor = .windowOverlayBackground
        view.material = .fullScreenUI
        self.view = view
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        lastPersistedFavoriteHeight = loadCachedFavoriteHeight()
        setupStackView()
        setupObserversIfNeeded()
        setupConfigObserverIfNeeded()
        updateHeaderHeight()
        updateChatButtonVisibility()
        updateMemoryButtonVisibility()
        updateSidebarContentActivation()
        updateSpaceTintGradient()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // CAGradientLayer is a sublayer (not the host layer), so it doesn't
        // pick up the host view's autoresizing — sync the frame each pass.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spaceTintGradientLayer.frame = spaceTintBackgroundView.bounds
        CATransaction.commit()
    }
    
    override func viewWillAppear() {
        super.viewWillAppear()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        bindDownloadsManagerIfNeeded()
    }

    /// Binds the bottom bar's download button to the downloads manager exactly
    /// once. A window created minimized never runs `viewDidAppear` for this
    /// tree, so the restore-from-minimized path drives this explicitly; the
    /// guard keeps it idempotent across repeated deminiaturize.
    func bindDownloadsManagerIfNeeded() {
        guard !didBindDownloadsManager else { return }
        didBindDownloadsManager = true
        bottomBarSwiftUI.bindDownloadsManager(state.downloadsManager)
    }

    // MARK: - Swipe to switch Space

    /// Catches trackpad gestures anywhere in the sidebar that no subview
    /// consumed — the tab list's scroll view routes horizontal-dominant
    /// gestures up the chain (see OverlayScrollView.scrollWheel), and the
    /// remaining sidebar views don't scroll at all. A sideways swipe switches
    /// this window's active Space.
    override func scrollWheel(with event: NSEvent) {
        // While the create-Space overlay is up it covers the sidebar; a swipe
        // there must not switch out from under the form, so skip the
        // space-swipe tracker entirely and let the event scroll as usual.
        guard createSpaceOverlay == nil else {
            super.scrollWheel(with: event)
            return
        }
        switch spaceSwipe.handle(event) {
        case .passthrough:
            super.scrollWheel(with: event)
        case .consumed:
            break
        case .trigger(let step):
            activateAdjacentSpace(by: step, state: state)
        }
    }

    /// Update chat button visibility based on configuration and current tab's aiChatEnabled
    private func updateChatButtonVisibility() {
        let navigationAtTop = PhiPreferences.GeneralSettings.loadLayoutMode().showsNavigationAtTop
        let overviewActive = state.groupOverviewState != nil
        let focusedAIChat = state.focusingTab?.aiChatEnabled ?? false
        // Outside overview, split chat is shared with the partner pane. Keep
        // the button visible while either pane has chat enabled.
        let partnerAIChat = focusingTabSplitPartner()?.aiChatEnabled ?? false
        let aiChatEnabled = focusedAIChat || partnerAIChat
        let phiAIEnabled = UserDefaults.standard.bool(forKey: PhiPreferences.AISettings.phiAIEnabled.rawValue)
        let shouldHideChat = overviewActive || state.isIncognito || navigationAtTop || !aiChatEnabled || !phiAIEnabled
        bottomBarSwiftUI.setChatHidden(shouldHideChat)
    }

    /// Resolve the current focused tab's split partner, if any.
    private func focusingTabSplitPartner() -> Tab? {
        guard let tab = state.focusingTab,
              let group = state.splitGroup(forTabId: tab.guid),
              let partnerId = group.partnerTabId(of: tab.guid) else {
            return nil
        }
        return state.tabs.first { $0.guid == partnerId }
    }

    /// Hide the AI memory button when Phi AI is disabled or in incognito mode.
    private func updateMemoryButtonVisibility() {
        let phiAIEnabled = UserDefaults.standard.bool(forKey: PhiPreferences.AISettings.phiAIEnabled.rawValue)
        let shouldHideMemory = state.isIncognito || !phiAIEnabled
        bottomBarSwiftUI.setMemoryHidden(shouldHideMemory)
    }

    /// Update header height based on configuration. The header now also hosts
    /// the Spaces switch (below the nav row, above the address bar), so both
    /// heights include room for that row — see `SidebarHeaderView.mountSpaceSwitch`.
    private func updateHeaderHeight() {
        let addressInSidebar = !PhiPreferences.GeneralSettings.loadLayoutMode().showsNavigationAtTop
        // The Spaces switch row is only shown when the feature is on, the window
        // is not incognito (see `setupView`), and more than one Space exists
        // (see `SidebarHeaderView.updateSpaceSwitchVisibility`). Reserve its
        // height under the exact same condition, or the header would keep an
        // empty 32pt gap below the address bar for a row that isn't shown.
        let spacesEnabled = PhiPreferences.GeneralSettings.spacesFeatureEnabled.loadValue()
            && state.participatesInSpaces
            && (SpaceManager.shared.spaces.count > 1 || headerView.forcesSpaceSwitchVisible)
        // Base = nav row (+ address bar in sidebar layouts). The Spaces switch
        // adds its row height plus the 8pt gap below the nav row only while it
        // is shown, so the header reclaims the full band when it is hidden.
        // In top-navigation layouts, 42.5pt leaves the Space strip exactly
        // 8pt above the next sidebar band once the 5pt header spacer below is
        // included. The half point follows the legacy header controls' 15.5pt
        // top alignment.
        let base: CGFloat = addressInSidebar ? 80 : 42.5
        let spacesBandHeight = SpacesStripView.sidebarHeight + 8
        let headerHeight = base + (spacesEnabled ? spacesBandHeight : 0)
        headerHeightConstraint?.update(offset: headerHeight)
    }

    /// Observe configuration changes
    private func setupConfigObserverIfNeeded() {
        guard hasSetupConfigObserver == false else { return }
        hasSetupConfigObserver = true
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateChatButtonVisibility()
                self?.updateMemoryButtonVisibility()
                self?.headerView.updateSpaceSwitchVisibility()
                self?.updateHeaderHeight()
            }
            .store(in: &cancellables)

        // The Spaces switch row hides while only one Space exists, so its
        // visibility (and the header height that reserves its 32pt) must also
        // re-resolve when Spaces are created or deleted — those arrive via the
        // manager's published list, not UserDefaults.
        SpaceManager.shared.$spaces
            .map(\.count)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.headerView.updateSpaceSwitchVisibility()
                self?.updateHeaderHeight()
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Setup
    
    private func setupStackView() {
        // Added before mainStackView so it stays behind every stack item.
        // The ColoredVisualEffectView's own `colorView` is already pinned
        // at the back by NSVisualEffectView.commonInit, so the tint sits
        // between the theme fill (below) and the content stack (above).
        view.addSubview(spaceTintBackgroundView)
        spaceTintBackgroundView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        view.addSubview(mainStackView)
        mainStackView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        
        mainStackView.addArrangedSubview(headerView)
        headerView.snp.makeConstraints { make in
            headerHeightConstraint = make.height.equalTo(73).constraint
            make.leading.trailing.equalToSuperview()
        }
        
        updateHeaderHeight()

        let headerSpacer = createSpacer(height: 5)
        mainStackView.addArrangedSubview(headerSpacer)

        // The pinned-tab (favorites) band is a per-profile feature with no
        // meaning in an incognito session, which has no favorites. Skip mounting
        // it entirely — along with its trailing spacer — so the tab list and its
        // "+ New Tab" row sit directly below the address bar instead of under an
        // empty reserved band (matching how the Spaces strip / AI chat / memory
        // are suppressed for incognito).
        if !state.isIncognito {
            setupFavoriteContainer()
            let initialPinnedHeight = loadCachedFavoriteHeight()
            mainStackView.addArrangedSubview(pinnedTabContainerView)
            pinnedTabContainerView.snp.makeConstraints { make in
                make.leading.trailing.equalToSuperview()
                pinnedTabsHeightConstraint = make.height.equalTo(initialPinnedHeight).constraint
            }

            let pinSpacer = NSView()
            pinSpacer.snp.makeConstraints { make in
                pinSpacerHeightConstraint = make.height.equalTo(initialPinnedHeight > 0 ? 3 : 0).constraint
            }
            mainStackView.addArrangedSubview(pinSpacer)
        }

        // The Spaces switch is mounted at the TOP of the sidebar — inside the
        // header, below the nav row and above the address bar — rather than
        // here in the tab band, so it reads as the top-most per-Space control
        // and scrolls its label vertically on switch (see SpacesStripView).
        // It remains a child hosting controller of this VC for theming; only
        // its view lives in the header.
        //
        // Standalone incognito windows have no Spaces: an off-the-record
        // session outside a slot is a single ephemeral context, so skip
        // mounting entirely (matching how AI chat and memory are suppressed
        // above); not mounting leaves the header's address bar pinned directly
        // under the nav row and avoids spinning up a SpaceWindowSlot. The
        // Incognito Space's window DOES mount the strip — it lives in a
        // slot and the strip is how the user switches back out of it.
        //
        // A window that resolves no slot skips the strip for the same reason
        // said the other way round: there is nothing to bind it to, and
        // minting a binding-only slot strands the registry (see
        // `spacesStripSlot`). Shadow windows are the reachable case — they
        // pass `participatesInSpaces` and build this sidebar even though they
        // never appear on screen.
        if state.participatesInSpaces, let stripHostingView = spacesStripHostingView {
            headerView.mountSpaceSwitch(stripHostingView)
            spacesStripRowView = stripHostingView
        }

        tabList.enableContextMenuClickRouting()
        mainStackView.addArrangedSubview(tabList.view)
        tabList.view.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview()
        }
        tabList.view.setContentHuggingPriority(.defaultLow, for: .vertical)
        tabList.view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        
        let tabListSpacer = createSpacer(height: 3)
        mainStackView.addArrangedSubview(tabListSpacer)
        
        mainStackView.addArrangedSubview(notificationContainerView)
        notificationContainerView.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview()
            make.height.equalTo(0)
        }
        
        setupMessageCardContainer()
        mainStackView.addArrangedSubview(messageCardContainerView)
        messageCardContainerView.setContentHuggingPriority(.defaultLow, for: .vertical)
        messageCardContainerView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        messageCardContainerView.snp.makeConstraints { make in
            make.leading.equalToSuperview().inset(8)
            make.trailing.equalToSuperview()
            messageCardHeightConstraint = make.height.equalTo(0).constraint
        }
        
        mainStackView.addArrangedSubview(bottomBarSwiftUI)
        bottomBarSwiftUI.snp.makeConstraints { make in
            bottomBarHeightConstraint = make.height.equalTo(SidebarBottomBarState.singleRowHeight).constraint
            make.leading.trailing.equalToSuperview()
        }

        bottomBarSwiftUI.onHeightChange = { [weak self] newHeight in
            self?.updateBottomBarHeight(newHeight)
        }

        let bottomSpacer = createSpacer(height: 8)
        mainStackView.addArrangedSubview(bottomSpacer)
    }
    
    private func setupFavoriteContainer() {
        pinnedTabViewController.enableContextMenuClickRouting()
        pinnedTabContainerView.addSubview(pinnedTabViewController.view)
        pinnedTabViewController.view.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }
    
    private func setupMessageCardContainer() {
//        messageCardContainerView.layer?.masksToBounds = true
        messageCardContainerView.addSubview(messageCardHostingController.view)
        messageCardHostingController.view.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }
    
    private func createSpacer(height: CGFloat) -> NSView {
        let spacer = NSView()
        spacer.snp.makeConstraints { make in
            make.height.equalTo(height)
        }
        return spacer
    }
    
    // MARK: - Observers

    private func setupObserversIfNeeded() {
        guard hasSetupObservers == false else { return }
        hasSetupObservers = true
        setupObservers(state)
    }
    
    private func setupObservers(_ state: BrowserState) {
        state.$layoutMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateSidebarContentActivation()
            }
            .store(in: &cancellables)
        
        state.$focusingTab
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tab in
                self?.observeFocusingTabAIChatEnabled(tab)
                self?.updateChatButtonVisibility()
            }
            .store(in: &cancellables)

        // Split membership controls whether we treat the partner's
        // aiChatEnabled as a fallback for the button. Rebind the partner
        // observer and refresh on every splits change so the button reacts
        // when a tab joins or leaves a split.
        state.$splits
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.observeFocusingTabAIChatEnabled(self.state.focusingTab)
                self.updateChatButtonVisibility()
            }
            .store(in: &cancellables)

        state.$groupOverviewState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateChatButtonVisibility()
            }
            .store(in: &cancellables)

        NotificationCardManager.shared.shouldShowInSidebar
            .receive(on: DispatchQueue.main)
            .sink { [weak self] shouldShow in
                self?.updateMessageCardVisibility(shouldShow: shouldShow)
            }
            .store(in: &cancellables)
        
        NotificationCardManager.shared.$currentIndex
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                if NotificationCardManager.shared.currentCard != nil {
                    self?.updateMessageCardHeight()
                }
            }
            .store(in: &cancellables)

        // Mirror the SpacesStripView fallback chain so the gradient still
        // resolves before MainBrowserWindowController has wired up its slot.
        let slot = state.windowController?.slot ?? SpaceManager.shared.keySlot
        slot?.$activeSpaceId
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateSpaceTintGradient() }
            .store(in: &cancellables)

        SpaceManager.shared.$spaces
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateSpaceTintGradient() }
            .store(in: &cancellables)
    }

    /// Recompute the tint gradient from the active Space's `colorHex` and
    /// cross-fade to it over the layout's swap-animation duration (see
    /// `PhiPreferences.GeneralSettings.loadSwitchSpaceAnimationDuration`).
    /// Initial paint before any prior colors are set is forced instant —
    /// animating from nothing to the first colors causes a visible flash.
    private func updateSpaceTintGradient() {
        // A vertical Space-switch push-in drives the tint ramp explicitly via
        // `rampSpaceTint`; the slot-observation that calls this fires a runloop
        // later and would otherwise remove that in-flight ramp (snapping the
        // background to the target color). Defer to the explicit ramp while it
        // runs.
        guard !isRampingSpaceTint else { return }
        let slot = state.windowController?.slot ?? SpaceManager.shared.keySlot
        let spaceId = slot?.activeSpaceId
        let colorHex: String?
        if let spaceId,
           let space = SpaceManager.shared.spaces.first(where: { $0.spaceId == spaceId }) {
            colorHex = space.colorHex
        } else {
            colorHex = nil
        }
        let newColors = spaceTintColors(forHex: colorHex)
        let oldColors = spaceTintGradientLayer.colors as? [CGColor]
        let duration = PhiPreferences.GeneralSettings.loadSwitchSpaceAnimationDuration()

        guard let oldColors, duration > 0 else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            spaceTintGradientLayer.colors = newColors
            CATransaction.commit()
            return
        }

        // Drive the cross-fade with an explicit CABasicAnimation so the
        // duration is exactly the configured value rather than the default
        // implicit-action timing (~0.25s) that CAGradientLayer would otherwise
        // use. Model value is set first with actions disabled so the explicit
        // animation is the only thing the user sees.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spaceTintGradientLayer.colors = newColors
        CATransaction.commit()

        spaceTintGradientLayer.removeAnimation(forKey: "spaceTintColors")
        let animation = CABasicAnimation(keyPath: "colors")
        animation.fromValue = oldColors
        animation.toValue = newColors
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.isRemovedOnCompletion = true
        spaceTintGradientLayer.add(animation, forKey: "spaceTintColors")
    }

    /// The two-stop tint colors for a Space `colorHex`.
    ///
    /// The per-Space tint is disabled so the sidebar keeps its pre-Spaces
    /// appearance (plain visual-effect material, no colored wash). Always
    /// returns clear; switch the stops back to the active color at 22% alpha
    /// fading to transparent to re-enable it.
    private func spaceTintColors(forHex hex: String?) -> [CGColor] {
        return [NSColor.clear.cgColor, NSColor.clear.cgColor]
    }

    // MARK: - Space-switch push-in support

    /// True while `rampSpaceTint` owns the tint animation, so the
    /// slot-observation update (`updateSpaceTintGradient`) doesn't clobber it.
    private var isRampingSpaceTint = false
    private var tintRampTimer: Timer?

    /// Ramps the tint gradient from `fromHex` to `toHex` over `duration`, in
    /// lockstep with the push-in slide, so the background visibly transitions
    /// from the source Space's color to the target's *during* the slide rather
    /// than jumping at the end.
    ///
    /// Driven by a per-frame timer that sets the gradient's MODEL color each
    /// tick. A plain `CABasicAnimation` only updates the layer's presentation
    /// value, which the host `NSVisualEffectView` snaps back to the model when
    /// it re-composites its material — so the interpolation was never visible.
    /// Writing the model each frame (the same approach the horizontal window
    /// slide uses) is immune to that. `.common` run-loop mode keeps it ticking
    /// during modal tracking.
    func rampSpaceTint(fromHex: String?, toHex: String?, duration: TimeInterval) {
        tintRampTimer?.invalidate()
        tintRampTimer = nil
        spaceTintGradientLayer.removeAnimation(forKey: "spaceTintColors")

        let from = (fromHex.map { NSColor(hexString: $0) } ?? .clear).usingColorSpace(.sRGB) ?? .clear
        let to = (toHex.map { NSColor(hexString: $0) } ?? .clear).usingColorSpace(.sRGB) ?? .clear

        guard duration > 0 else {
            setSpaceTintBase(to)
            return
        }

        isRampingSpaceTint = true
        setSpaceTintBase(from)
        let start = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let progress = min(1.0, (CACurrentMediaTime() - start) / duration)
            let eased: CGFloat = progress < 0.5
                ? 2 * progress * progress
                : 1 - pow(-2 * progress + 2, 2) / 2
            self.setSpaceTintBase(self.lerpColor(from, to, eased))
            if progress >= 1.0 {
                t.invalidate()
                self.tintRampTimer = nil
                self.isRampingSpaceTint = false
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tintRampTimer = timer
    }

    /// Sets the gradient model to the two-stop tint for `base` with implicit
    /// animation disabled (the timer supplies the motion).
    ///
    /// The per-Space tint is disabled to preserve the pre-Spaces sidebar look,
    /// so this always paints clear regardless of `base`; restore the 0.22/0
    /// alpha stops here (and in `spaceTintColors`) to bring the wash back.
    private func setSpaceTintBase(_ base: NSColor) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spaceTintGradientLayer.colors = [
            NSColor.clear.cgColor,
            NSColor.clear.cgColor
        ]
        CATransaction.commit()
    }

    private func lerpColor(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
        NSColor(
            srgbRed: a.redComponent + (b.redComponent - a.redComponent) * t,
            green: a.greenComponent + (b.greenComponent - a.greenComponent) * t,
            blue: a.blueComponent + (b.blueComponent - a.blueComponent) * t,
            alpha: a.alphaComponent + (b.alphaComponent - a.alphaComponent) * t
        )
    }

    private func shouldActivateSidebarContent() -> Bool { state.layoutMode != .comfortable }

    private func updateSidebarContentActivation() {
        let shouldActivate = shouldActivateSidebarContent()
        guard shouldActivate != isSidebarContentActive else { return }
        isSidebarContentActive = shouldActivate

        contentCancellables.removeAll()
        // Incognito windows don't mount the pinned-tab band (see `setupView`),
        // so leave its controller dormant and skip the favorite-height
        // observation that drives the band's layout.
        if !state.isIncognito {
            pinnedTabViewController.setActive(shouldActivate)
        }
        tabList.setActive(shouldActivate)

        guard shouldActivate, !state.isIncognito else { return }

        pinnedTabViewController.$contentHeight
            .combineLatest(state.$isDraggingTab)
            .debounce(for: .seconds(0.01), scheduler: DispatchQueue.main)
            .sink { [weak self] newHeight, draggingTab in
                self?.updateFavoriteHeight(newHeight, isDragging: draggingTab)
            }
            .store(in: &contentCancellables)

        // Restore-transaction signal: synchronous by design (no receive(on:),
        // mirroring TabSectionController), so the pinned band is formed and
        // its height applied before `frontRestoredWindowOnSnapshotApplied`
        // reveals the window later in this same main-thread turn. The
        // debounced `$contentHeight` pipeline above re-delivers the same
        // height a beat later, which `updateFavoriteHeight` absorbs.
        state.restoredWindowTransactionSignal
            .sink { [weak self] in
                guard let self else { return }
                self.pinnedTabViewController.formRestoredContentNow()
                self.updateFavoriteHeight(self.pinnedTabViewController.contentHeight,
                                          isDragging: self.state.isDraggingTab)
            }
            .store(in: &contentCancellables)

        updateFavoriteHeight(pinnedTabViewController.contentHeight, isDragging: state.isDraggingTab)
    }
    
    /// Subscription for the current focusing tab's `aiChatEnabled` state.
    private var focusingTabAIChatEnabledCancellable: AnyCancellable?
    /// Subscription for the focused tab's split-partner `aiChatEnabled` state,
    /// rebuilt whenever the focused tab or split membership changes.
    private var focusingTabPartnerAIChatEnabledCancellable: AnyCancellable?

    /// Observe `aiChatEnabled` on the current focusing tab.
    private func observeFocusingTabAIChatEnabled(_ tab: Tab?) {
        focusingTabAIChatEnabledCancellable?.cancel()
        focusingTabAIChatEnabledCancellable = nil
        focusingTabPartnerAIChatEnabledCancellable?.cancel()
        focusingTabPartnerAIChatEnabledCancellable = nil

        guard let tab else { return }

        focusingTabAIChatEnabledCancellable = tab.$aiChatEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateChatButtonVisibility()
            }

        if let partner = focusingTabSplitPartner() {
            focusingTabPartnerAIChatEnabledCancellable = partner.$aiChatEnabled
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.updateChatButtonVisibility()
                }
        }
    }
    
    // MARK: - Update Methods
    
    private func updateFavoriteHeight(_ newHeight: CGFloat, isDragging: Bool = false) {
        let clampedHeight: CGFloat
        if newHeight < 20 && isDragging {
            clampedHeight = 100
        } else {
            clampedHeight = newHeight
        }

        pinnedTabsHeightConstraint?.update(offset: clampedHeight)
        pinSpacerHeightConstraint?.update(offset: clampedHeight > 0 ? 3 : 0)
        view.layoutSubtreeIfNeeded()
        persistFavoriteHeightIfNeeded(clampedHeight, isDragging: isDragging)
    }

    private func loadCachedFavoriteHeight() -> CGFloat {
        let cached = UserDefaults.standard.double(forKey: Self.pinnedHeightCacheKey)
        guard cached > 0 else { return Self.defaultFavoriteHeight }
        return CGFloat(cached)
    }

    private func persistFavoriteHeightIfNeeded(_ height: CGFloat, isDragging: Bool) {
        guard isDragging == false else { return }
        guard height >= Self.pinnedHeightPersistenceThreshold else { return }
        if let lastPersistedFavoriteHeight, abs(lastPersistedFavoriteHeight - height) < 0.5 {
            return
        }
        lastPersistedFavoriteHeight = height
        UserDefaults.standard.set(Double(height), forKey: Self.pinnedHeightCacheKey)
    }
    
    /// Update the bottom toolbar height.
    private func updateBottomBarHeight(_ newHeight: CGFloat) {
        bottomBarHeightConstraint?.update(offset: newHeight)
        
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.allowsImplicitAnimation = true
            view.layoutSubtreeIfNeeded()
        }
    }
    
    /// Maximum sidebar message-card height.
    private let messageCardMaxHeight: CGFloat = 200
    
    /// Update message-card visibility from `NotificationCardManager.shouldShowInSidebar`.
    private func updateMessageCardVisibility(shouldShow: Bool, animated: Bool = false) {
        guard shouldShow else {
            hideMessageCard(animated: animated)
            return
        }
        
        // Show container before updating height
        messageCardContainerView.isHidden = false
        messageCardHostingController.view.isHidden = false
        view.layoutSubtreeIfNeeded()
        
        updateMessageCardHeight(animated: animated)
    }
    
    /// Hide the sidebar message card.
    private func hideMessageCard(animated: Bool) {
        messageCardHeightConstraint?.update(offset: 0)
        if animated {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                context.allowsImplicitAnimation = true
                view.layoutSubtreeIfNeeded()
            }) { [weak self] in
                self?.messageCardHostingController.view.isHidden = true
            }
        } else {
            view.layoutSubtreeIfNeeded()
            messageCardHostingController.view.isHidden = true
        }
    }
    
    /// Recalculate the message-card height.
    private func updateMessageCardHeight(animated: Bool = false) {
        guard !messageCardHostingController.view.isHidden else { return }
        
        let availableWidth = max(view.bounds.width - 16, 200)
        let targetSize = NSSize(width: availableWidth, height: CGFloat.greatestFiniteMagnitude)
        let fittingSize = messageCardHostingController.sizeThatFits(in: targetSize)
        let fittingHeight = fittingSize.height > 0 ? fittingSize.height : messageCardHostingController.view.fittingSize.height
        let cardHeight = min(fittingHeight, messageCardMaxHeight)
        
        messageCardHeightConstraint?.update(offset: cardHeight)
        
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.allowsImplicitAnimation = true
                view.layoutSubtreeIfNeeded()
            }
        } else {
            view.layoutSubtreeIfNeeded()
        }
    }
    
    /// Temporarily show the message card even when popup mode is muted.
    private func showMessageCardTemporarily(animated: Bool = false) {
        NotificationCardManager.shared.showManually(for: .sidebar)
    }
    
    // MARK: - Public Methods
    
    /// Show a view in the notification container.
    func showNotificationView(_ view: NSView, height: CGFloat) {
        notificationContainerView.subviews.forEach { $0.removeFromSuperview() }
        
        notificationContainerView.addSubview(view)
        view.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(NSEdgeInsets(top: 0, left: 10, bottom: 2, right: 0))
        }
        
        notificationContainerView.snp.updateConstraints { make in
            make.height.equalTo(height)
        }
        
        notificationContainerView.alphaValue = 0
        notificationContainerView.isHidden = false
        
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.allowsImplicitAnimation = true
            notificationContainerView.animator().alphaValue = 1
            self.view.layoutSubtreeIfNeeded()
        }
    }
    
    /// Hide the notification container.
    func hideNotificationView(animated: Bool = true) {
        if animated {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.3
                context.allowsImplicitAnimation = true
                notificationContainerView.animator().alphaValue = 0
                notificationContainerView.snp.updateConstraints { make in
                    make.height.equalTo(0)
                }
                self.view.layoutSubtreeIfNeeded()
            }) { [weak self] in
                self?.notificationContainerView.subviews.forEach { $0.removeFromSuperview() }
            }
        } else {
            notificationContainerView.alphaValue = 0
            notificationContainerView.snp.updateConstraints { make in
                make.height.equalTo(0)
            }
            notificationContainerView.subviews.forEach { $0.removeFromSuperview() }
        }
    }

    // MARK: - Create Space Overlay

    /// Inline "Create a Space" form filling the sidebar in vertical layouts.
    /// The horizontal layout routes to a floating window instead — the choice
    /// is made in `CreateSpacePanel.requestCreation`.
    private var createSpaceOverlay: ThemedHostingController<CreateSpacePanel>?
    /// Themed backdrop painted behind the create-Space form so it matches the
    /// active Space's sidebar — same visual-effect recipe as the sidebar root
    /// (`loadView`), resolved against this window's theme context.
    private var createSpaceOverlayBackdrop: ColoredVisualEffectView?

    func showCreateSpaceOverlay(initialProfileId: String?) {
        // A successful create retains the source theme until activation
        // finishes. Do not start another preview session during that handoff.
        guard createSpaceOverlay == nil,
              themeBeforeCreateSpacePreview == nil else { return }
        let panel = CreateSpacePanel(
            style: .sidebar,
            manager: .shared,
            profileManager: .shared,
            initialProfileId: initialProfileId,
            initialThemeId: state.themeContext.currentTheme.id
        ) { [weak self] restorePreviewTheme in
            self?.dismissCreateSpaceOverlay(
                restorePreviewTheme: restorePreviewTheme
            )
        } onThemeSelectionChange: { [weak self] theme in
            self?.previewCreateSpaceOverlayTheme(theme)
        } onCreatedSpaceActivationFinished: { [weak self] in
            self?.restoreCreateSpacePreviewTheme()
        }
        // Keep the Spaces icon row visible above the form while creating. Force
        // it on even with a single Space and reserve its header height before
        // the overlay anchors so the strip's frame is settled.
        headerView.forcesSpaceSwitchVisible = true
        updateHeaderHeight()
        view.layoutSubtreeIfNeeded()
        // Pin the overlay below the visible strip. Keep a full-sidebar fallback
        // for hosts that do not participate in Spaces and never mounted it.
        let stripRow = spacesStripRowView
        let anchorsBelowStrip = stripRow?.isHidden == false

        // Match the current Space's sidebar background (color + opacity) by
        // reusing the sidebar root's visual-effect recipe; the form hosting
        // view above is transparent so this shows through. User theme changes
        // preview through the same window-scoped context.
        //
        // Must blend within the window, not behind it: behind-window material
        // is composited by WindowServer and leaves this region transparent in
        // the window's own backing store, and screen captures (ScreenCaptureKit
        // ignores window alpha) resolve it against the concealed sibling Space
        // window stacked behind — the background Space showed through the form
        // in recordings. Within-window frosts the sidebar content this sheet
        // covers and renders entirely in-process, so captures match the screen.
        let backdrop = ColoredVisualEffectView()
        backdrop.themedBackgroundColor = .windowOverlayBackground
        backdrop.material = .fullScreenUI
        backdrop.blendingMode = .withinWindow
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(backdrop)
        backdrop.snp.makeConstraints { make in
            make.leading.trailing.bottom.equalToSuperview()
            if anchorsBelowStrip, let stripRow {
                make.top.equalTo(stripRow.snp.bottom)
            } else {
                make.top.equalToSuperview()
            }
        }

        let host = ThemedHostingController(rootView: panel, themeSource: state.themeContext)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        // Fill the sidebar at its current width — never let the form's intrinsic
        // size (the icon grid is wider than a narrow sidebar) push the sidebar
        // wider while creating a Space.
        if #available(macOS 13.0, *) {
            host.sizingOptions = []
        }
        addChild(host)
        view.addSubview(host.view)
        host.view.snp.makeConstraints { make in
            make.leading.trailing.bottom.equalToSuperview()
            if anchorsBelowStrip, let stripRow {
                make.top.equalTo(stripRow.snp.bottom)
            } else {
                make.top.equalToSuperview()
            }
        }
        backdrop.alphaValue = 0
        host.view.alphaValue = 0
        createSpaceOverlay = host
        createSpaceOverlayBackdrop = backdrop
        themeBeforeCreateSpacePreview = state.themeContext.currentTheme
        // Keep the visible strip read-only while creating so a pip click cannot
        // switch the form's window away.
        spacesStripSlot?.isCreatingSpace = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.allowsImplicitAnimation = true
            backdrop.animator().alphaValue = 1
            host.view.animator().alphaValue = 1
        }
    }

    /// The active Space theme inherited when the form opened. Theme selection
    /// previews are restored on cancel, after the new target fronts, or when
    /// activation fails.
    private var themeBeforeCreateSpacePreview: Theme?

    private func previewCreateSpaceOverlayTheme(_ theme: Theme) {
        guard createSpaceOverlay != nil else { return }
        state.themeContext.setTheme(theme)
    }

    func dismissCreateSpaceOverlay(restorePreviewTheme: Bool = true) {
        guard let host = createSpaceOverlay else { return }
        let backdrop = createSpaceOverlayBackdrop
        createSpaceOverlay = nil
        createSpaceOverlayBackdrop = nil
        if restorePreviewTheme {
            restoreCreateSpacePreviewTheme()
        }
        spacesStripSlot?.isCreatingSpace = false
        // Release forced visibility. Normal Space-count rules take over again.
        headerView.forcesSpaceSwitchVisible = false
        updateHeaderHeight()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.allowsImplicitAnimation = true
            host.view.animator().alphaValue = 0
            backdrop?.animator().alphaValue = 0
        }) {
            host.view.removeFromSuperview()
            host.removeFromParent()
            backdrop?.removeFromSuperview()
        }
    }

    /// Restores the source Space only after it is hidden behind the activated
    /// target. Activation failures call the same path while the source remains
    /// visible, so the preview can never become its lasting theme.
    private func restoreCreateSpacePreviewTheme() {
        guard let savedTheme = themeBeforeCreateSpacePreview else { return }
        themeBeforeCreateSpacePreview = nil
        state.themeContext.setTheme(savedTheme)
    }
}

// MARK: - SpaceSwitchBandSurface

extension SidebarViewController: SpaceSwitchBandSurface {
    // The Spaces switch lives in the header (with its own scroll animation),
    // so the push-in band is just the pinned strip and the tab list.
    var spaceSwitchBandViews: [NSView] { [pinnedTabContainerView, tabList.view] }
    var spaceSwitchBandContainer: NSView { mainStackView }
}

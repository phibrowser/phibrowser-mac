// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import SnapKit
import SwiftUI
import Combine

class SidebarViewController: NSViewController {
    private static let defaultFavoriteHeight: CGFloat = 10
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
            self.state.toggleAIChat()
        }
        view.onCardEntryTap = { [weak self] in
            self?.showMessageCardTemporarily()
        }
        view.onMemoryTap = {
            BrowserState.currentState()?.createTab("chrome://memory/memory.html", focusAfterCreate: true)
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
    /// `keySlot` so the strip stays functional rather than crashing.
    private lazy var spacesStripHostingController: ThemedHostingController<SpacesStripView> = {
        let slot = state.windowController?.slot
            ?? SpaceManager.shared.keySlot
            ?? SpaceManager.shared.createSlot(initialSpaceId: nil)
        let hostingController = ThemedHostingController(
            rootView: SpacesStripView(manager: SpaceManager.shared, slot: slot, rowHeight: SpacesStripView.sidebarHeight),
            themeSource: state.themeContext
        )
        if #available(macOS 13.0, *) {
            hostingController.sizingOptions = [.intrinsicContentSize]
        }
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        return hostingController
    }()
    
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
            activateAdjacentSpace(by: step)
        }
    }

    /// Switches THIS window's active Space, clamped at the first/last Space
    /// (no wrap-around) so the push-in animation direction always matches the
    /// swipe. At a clamp edge the switch can't proceed, so a rubber-band end
    /// effect plays instead of the swipe being swallowed. Vertical layouts only.
    private func activateAdjacentSpace(by step: Int) {
        guard !PhiPreferences.GeneralSettings.loadLayoutMode().isTraditional,
              PhiPreferences.GeneralSettings.spacesFeatureEnabled.loadValue() else { return }
        let spaces = SpaceManager.shared.spaces
        guard let slot = state.windowController?.slot ?? SpaceManager.shared.keySlot,
              let currentId = slot.activeSpaceId,
              let currentIdx = spaces.firstIndex(where: { $0.spaceId == currentId }) else { return }
        let targetIdx = currentIdx + step
        guard spaces.indices.contains(targetIdx) else {
            // Already at the first/last Space (or only one exists) — there's
            // nowhere to switch, so play the rubber-band end effect instead of
            // silently swallowing the swipe.
            bounceSpaceSwitchBand(forward: step > 0)
            return
        }
        slot.activate(spaceId: spaces[targetIdx].spaceId)
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
        let spacesEnabled = PhiPreferences.GeneralSettings.spacesFeatureEnabled.loadValue()
        // Base = nav row (+ address bar in sidebar layouts). The Spaces switch
        // row adds 32 (24 row + 8 gap) only when the feature is enabled, so the
        // header reclaims the row's height when Spaces is off.
        let base: CGFloat = addressInSidebar ? 80 : 42
        let headerHeight = base + (spacesEnabled ? 32 : 0)
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
        
        setupFavoriteContainer()
        mainStackView.addArrangedSubview(pinnedTabContainerView)
        pinnedTabContainerView.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview()
            pinnedTabsHeightConstraint = make.height.equalTo(loadCachedFavoriteHeight()).constraint
        }

        let pinSpacer = createSpacer(height: 3)
        mainStackView.addArrangedSubview(pinSpacer)

        // The Spaces switch is mounted at the TOP of the sidebar — inside the
        // header, below the nav row and above the address bar — rather than
        // here in the tab band, so it reads as the top-most per-Space control
        // and scrolls its label vertically on switch (see SpacesStripView).
        // It remains a child hosting controller of this VC for theming; only
        // its view lives in the header.
        addChild(spacesStripHostingController)
        headerView.mountSpaceSwitch(spacesStripHostingController.view)

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

    /// The two-stop tint colors for a Space `colorHex` (or clear when nil):
    /// the active color at 22% alpha fading to fully transparent.
    private func spaceTintColors(forHex hex: String?) -> [CGColor] {
        let base = hex.map { NSColor(hexString: $0) } ?? .clear
        return [
            base.withAlphaComponent(0.22).cgColor,
            base.withAlphaComponent(0).cgColor
        ]
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
    private func setSpaceTintBase(_ base: NSColor) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spaceTintGradientLayer.colors = [
            base.withAlphaComponent(0.22).cgColor,
            base.withAlphaComponent(0).cgColor
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

    /// The contiguous per-Space content band — pinned tabs, the Spaces strip
    /// (name + switcher), and the tab list (which also hosts bookmarks) — in
    /// this view's coordinate space. `SpaceManager` snapshots this region from
    /// the entering window's sidebar and slides it in over the leaving
    /// window's matching region during a vertical Space switch. The header
    /// (address bar) above and the bottom toolbar below are deliberately
    /// excluded so they stay put through the push.
    var spaceSwitchBandFrame: NSRect {
        // The Spaces switch now lives in the header (with its own scroll
        // animation), so the push-in band is just the pinned strip and the
        // tab list.
        let bandViews: [NSView] = [
            pinnedTabContainerView,
            tabList.view
        ]
        let rects = bandViews.compactMap { v -> NSRect? in
            guard v.superview != nil else { return nil }
            return view.convert(v.bounds, from: v)
        }
        guard let first = rects.first else { return .zero }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }

    /// Content-only snapshot of `spaceSwitchBandFrame`. The tint gradient
    /// lives in a sibling layer behind `mainStackView`, so it is NOT captured
    /// here — the band image carries a transparent background and the ramping
    /// gradient shows through during the slide. Renders even while the host
    /// window is off-screen, since AppKit layout/`cacheDisplay` is independent
    /// of window visibility.
    func snapshotSpaceSwitchBand() -> NSImage? {
        view.layoutSubtreeIfNeeded()
        let bandInStack = mainStackView.convert(spaceSwitchBandFrame, from: view)
        guard bandInStack.width > 0, bandInStack.height > 0,
              let rep = mainStackView.bitmapImageRepForCachingDisplay(in: bandInStack) else {
            return nil
        }
        mainStackView.cacheDisplay(in: bandInStack, to: rep)
        let image = NSImage(size: bandInStack.size)
        image.addRepresentation(rep)
        return image
    }

    /// Hides/reveals the live band content while the push-in overlay (which
    /// carries the same content as a transparent snapshot) plays on top.
    /// Without this the static live content shows through the snapshot's
    /// transparent areas and reads as a doubled, non-moving copy. Uses alpha
    /// rather than `isHidden` so the stack layout — and the tint gradient
    /// painted behind it — is unaffected.
    func setSwitchBandContentHidden(_ hidden: Bool) {
        let alpha: CGFloat = hidden ? 0 : 1
        pinnedTabContainerView.alphaValue = alpha
        tabList.view.alphaValue = alpha
    }

    /// Rubber-band nudge on the per-Space content band, played when a
    /// swipe-to-switch can't proceed because the active Space is already the
    /// first or last one. The band (pinned strip + tab list) shifts a short
    /// distance in the swipe's push direction and springs back — the same
    /// horizontal motion as the push-in swap, minus the Space change — so the
    /// gesture still resolves with feedback the user can feel. `forward`
    /// follows the swap convention: next-Space swipes push the band left,
    /// previous-Space swipes push it right.
    func bounceSpaceSwitchBand(forward: Bool) {
        let bandViews: [NSView] = [pinnedTabContainerView, tabList.view]
        let offset: CGFloat = forward ? -22 : 22

        // Clip the nudge to the sidebar so the shifted band reveals the
        // background on the trailing edge instead of poking over the web
        // content; restored once the bounce settles.
        mainStackView.wantsLayer = true
        let priorMasksToBounds = mainStackView.layer?.masksToBounds ?? false
        mainStackView.layer?.masksToBounds = true

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            self?.mainStackView.layer?.masksToBounds = priorMasksToBounds
        }
        for bandView in bandViews {
            bandView.wantsLayer = true
            guard let layer = bandView.layer else { continue }
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
        CATransaction.commit()
    }

    private func shouldActivateSidebarContent() -> Bool { state.layoutMode != .comfortable }

    private func updateSidebarContentActivation() {
        let shouldActivate = shouldActivateSidebarContent()
        guard shouldActivate != isSidebarContentActive else { return }
        isSidebarContentActive = shouldActivate

        contentCancellables.removeAll()
        pinnedTabViewController.setActive(shouldActivate)
        tabList.setActive(shouldActivate)

        guard shouldActivate else { return }

        pinnedTabViewController.$contentHeight
            .combineLatest(state.$isDraggingTab)
            .debounce(for: .seconds(0.01), scheduler: DispatchQueue.main)
            .sink { [weak self] newHeight, draggingTab in
                self?.updateFavoriteHeight(newHeight, isDragging: draggingTab)
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
        guard createSpaceOverlay == nil else { return }
        let panel = CreateSpacePanel(
            style: .sidebar,
            manager: .shared,
            profileManager: .shared,
            initialProfileId: initialProfileId
        ) { [weak self] in
            self?.dismissCreateSpaceOverlay()
        }
        // Match the current Space's sidebar background (color + opacity) by
        // reusing the sidebar root's visual-effect recipe; the form hosting
        // view above is transparent so this shows through.
        let backdrop = ColoredVisualEffectView()
        backdrop.themedBackgroundColor = .windowOverlayBackground
        backdrop.material = .fullScreenUI
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(backdrop)
        backdrop.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        let host = ThemedHostingController(rootView: panel, themeSource: state.themeContext)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.addSubview(host.view)
        host.view.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        backdrop.alphaValue = 0
        host.view.alphaValue = 0
        createSpaceOverlay = host
        createSpaceOverlayBackdrop = backdrop
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.allowsImplicitAnimation = true
            backdrop.animator().alphaValue = 1
            host.view.animator().alphaValue = 1
        }
    }

    func dismissCreateSpaceOverlay() {
        guard let host = createSpaceOverlay else { return }
        let backdrop = createSpaceOverlayBackdrop
        createSpaceOverlay = nil
        createSpaceOverlayBackdrop = nil
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
}

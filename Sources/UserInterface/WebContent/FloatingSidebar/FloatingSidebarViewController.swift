// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Combine
import AppKit
import SnapKit
/// Floating sidebar shown when the primary sidebar is collapsed in non-comfortable layouts.
/// Lightweight mirror of SidebarViewController.
class FloatingSidebarViewController: NSViewController {
    private static let defaultFavoriteHeight: CGFloat = 0
    private let messageCardMaxHeight: CGFloat = 200

    /// Main vertical stack
    private lazy var mainStackView: NSStackView = {
        let stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .centerX
        stackView.spacing = 0
        stackView.distribution = .fill
        return stackView
    }()

    private var state: BrowserState
    private lazy var headerView = SidebarHeaderView(state: state, isFloating: true)
    private lazy var pinnedTabViewController = PinnedTabViewController(state: state)
    private lazy var tabList = SidebarTabListViewController(state: state)

    private lazy var pinnedTabsContainerView: NSView = {
        let view = NSView()
        view.wantsLayer = true
        return view
    }()

    private lazy var messageCardContainerView: NSView = {
        let view = NSView()
        view.wantsLayer = true
        return view
    }()

    /// The slot driving this floating strip, resolved the same way as the
    /// docked sidebar's (see `SidebarViewController.spacesStripSlot`): the
    /// window controller's slot, falling back to the manager's key slot for
    /// the early-init case where the controller isn't wired up yet.
    private lazy var spacesStripSlot: SpaceWindowSlot = state.windowController?.slot
        ?? SpaceManager.shared.keySlot
        ?? SpaceManager.shared.createSlot(initialSpaceId: nil)

    /// Hosting view for the Spaces strip, mounted into the header — below the
    /// nav row, above the address bar — mirroring the docked sidebar so the
    /// floating panel offers the same Space switching.
    private lazy var spacesStripHostingView: SpacesStripHostingView = {
        let wheelTracker = SpacesStripWheelTracker()
        let stripGeometry = SpacesStripGeometry()
        let hostingView = SpacesStripHostingView(
            rootView: SpacesStripView(
                manager: SpaceManager.shared,
                slot: spacesStripSlot,
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

    /// The floating strip row's AppKit view, consulted by the slot's
    /// pointer-vs-row test while the floating panel is the strip actually
    /// presenting (see `SpaceWindowSlot.stripRowContainsPointer`). Set at
    /// mount; stays nil for windows that don't participate in Spaces,
    /// which never mount the strip.
    private(set) weak var spacesStripRowView: NSView?

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
        view.onCardEntryTap = {
            NotificationCardManager.shared.showManually(for: .sidebar)
        }
        view.onMemoryTap = {
            BrowserState.currentState()?.createTab("chrome://memory/memory.html", focusAfterCreate: true)
        }
        return view
    }()

    /// Swipe-to-switch-Space gesture state (see `SpaceSwipeTracker`).
    private let spaceSwipe = SpaceSwipeTracker()

    private var cancellables = Set<AnyCancellable>()
    private var contentCancellables = Set<AnyCancellable>()
    private var focusingTabAIChatEnabledCancellable: AnyCancellable?
    private var focusingTabPartnerAIChatEnabledCancellable: AnyCancellable?
    private var headerHeightConstraint: Constraint?
    private var pinnedHeightConstraint: Constraint?
    private var bottomBarHeightConstraint: Constraint?
    private var messageCardHeightConstraint: Constraint?
    private var hasSetupObservers = false
    private var hasSetupConfigObserver = false
    private var isContentActive = false

    init(browserState: BrowserState) {
        self.state = browserState
        super.init(nibName: nil, bundle: nil)
    }

    @MainActor required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let view: NSView
        if #available(macOS 26, *) {
            view = NSView()
            view.wantsLayer = true
            view.phiLayer?.setBackgroundColor(.windowOverlayBackground)
            
        } else {
            let _view = ColoredVisualEffectView()
            _view.themedBackgroundColor = .windowOverlayBackground
            _view.blendingMode = .behindWindow
            view = _view
        }
        self.view = view
       
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupStackView()
        setupObserversIfNeeded()
        setupConfigObserverIfNeeded()
        updateHeaderHeight()
        updateChatButtonVisibility()
        updateMemoryButtonVisibility()
        setContentActive(false)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        bottomBarSwiftUI.bindDownloadsManager(state.downloadsManager)
    }

    func refreshFloatingTrafficLights() {
        headerView.refreshFloatingTrafficLights()
    }

    /// Catches trackpad gestures anywhere in the floating panel that no
    /// subview consumed — the tab list's scroll view routes
    /// horizontal-dominant gestures up the chain (see
    /// OverlayScrollView.scrollWheel), and the remaining panel views don't
    /// scroll at all. A sideways swipe switches this window's active Space,
    /// mirroring the docked sidebar.
    override func scrollWheel(with event: NSEvent) {
        // While the create-Space form covers the panel a swipe must not
        // switch out from under it — same guard as the docked sidebar.
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

    deinit {
        tabList.tearDown()
    }

    private func setupStackView() {
        if !state.isIncognito {
            addChild(pinnedTabViewController)
        }
        addChild(tabList)

        view.addSubview(mainStackView)
        mainStackView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        // 1. Header
        mainStackView.addArrangedSubview(headerView)
        headerView.snp.makeConstraints { make in
            headerHeightConstraint = make.height.equalTo(73).constraint
            make.leading.trailing.equalToSuperview()
        }

        // The Spaces switch mounts INSIDE the header — below the nav row,
        // above the address bar — matching the docked sidebar (see
        // SidebarViewController.setupStackView). Standalone incognito windows
        // have no Spaces, so skip mounting entirely — same gating as the docked
        // sidebar.
        if state.participatesInSpaces {
            headerView.mountSpaceSwitch(spacesStripHostingView)
            spacesStripRowView = spacesStripHostingView
        }

        // 2. Header spacer
        mainStackView.addArrangedSubview(createSpacer(height: 5))

        // 3. Pinned tabs + their spacer. The pinned-tab (favorites) band is a
        // per-profile feature with no meaning in an incognito session; mounting
        // it here would expose the default profile's favorites as a drop target
        // whose writes land in the default Space. Skip it entirely, matching
        // the docked sidebar (see SidebarViewController.setupStackView).
        if !state.isIncognito {
            pinnedTabViewController.enableContextMenuClickRouting()
            pinnedTabsContainerView.addSubview(pinnedTabViewController.view)
            pinnedTabViewController.view.snp.makeConstraints { make in
                make.edges.equalToSuperview()
            }
            mainStackView.addArrangedSubview(pinnedTabsContainerView)
            pinnedTabsContainerView.snp.makeConstraints { make in
                make.leading.trailing.equalToSuperview()
                pinnedHeightConstraint = make.height.equalTo(Self.defaultFavoriteHeight).constraint
            }

            // 4. Favorites spacer
            mainStackView.addArrangedSubview(createSpacer(height: 3))
        }

        // 5. Tab list
        tabList.enableContextMenuClickRouting()
        mainStackView.addArrangedSubview(tabList.view)
        tabList.view.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview()
        }
        tabList.view.setContentHuggingPriority(.defaultLow, for: .vertical)
        tabList.view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        // 6. Tab list bottom spacer
        mainStackView.addArrangedSubview(createSpacer(height: 3))

        // 7. Message card container
        setupMessageCardContainer()
        mainStackView.addArrangedSubview(messageCardContainerView)
        messageCardContainerView.setContentHuggingPriority(.defaultLow, for: .vertical)
        messageCardContainerView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        messageCardContainerView.snp.makeConstraints { make in
            make.leading.equalToSuperview().inset(8)
            make.trailing.equalToSuperview().inset(WebContentConstant.edgesSpacing)
            messageCardHeightConstraint = make.height.equalTo(0).constraint
        }

        // 8. Bottom bar
        mainStackView.addArrangedSubview(bottomBarSwiftUI)
        bottomBarSwiftUI.snp.makeConstraints { make in
            bottomBarHeightConstraint = make.height.equalTo(SidebarBottomBarState.singleRowHeight).constraint
            make.leading.trailing.equalToSuperview()
        }
        bottomBarSwiftUI.onHeightChange = { [weak self] newHeight in
            self?.updateBottomBarHeight(newHeight)
        }

        // 9. Bottom spacer
        mainStackView.addArrangedSubview(createSpacer(height: 8))
    }

    private func setupMessageCardContainer() {
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

    private func setupObserversIfNeeded() {
        guard hasSetupObservers == false else { return }
        hasSetupObservers = true

        state.$layoutMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateHeaderHeight()
            }
            .store(in: &cancellables)

        state.$focusingTab
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tab in
                self?.observeFocusingTabAIChatEnabled(tab)
                self?.updateChatButtonVisibility()
            }
            .store(in: &cancellables)

        // Split membership affects whether the partner pane's chat state
        // keeps the button visible. Refresh observers and visibility on every
        // splits change so the button reacts when a tab joins or leaves a split.
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
    }

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
        // re-resolve when Spaces are created or deleted — those arrive via
        // the manager's published list, not UserDefaults (mirrors the docked
        // sidebar's observer).
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

    /// Resolve the current focused tab's split partner, if any.
    private func focusingTabSplitPartner() -> Tab? {
        guard let tab = state.focusingTab,
              let group = state.splitGroup(forTabId: tab.guid),
              let partnerId = group.partnerTabId(of: tab.guid) else {
            return nil
        }
        return state.tabs.first { $0.guid == partnerId }
    }

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

    /// Hide the AI memory button when Phi AI is disabled or in incognito mode,
    /// mirroring the docked sidebar (`SidebarViewController`).
    private func updateMemoryButtonVisibility() {
        let phiAIEnabled = UserDefaults.standard.bool(forKey: PhiPreferences.AISettings.phiAIEnabled.rawValue)
        let shouldHideMemory = state.isIncognito || !phiAIEnabled
        bottomBarSwiftUI.setMemoryHidden(shouldHideMemory)
    }

    private func updateBottomBarHeight(_ newHeight: CGFloat) {
        bottomBarHeightConstraint?.update(offset: newHeight)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.allowsImplicitAnimation = true
            view.layoutSubtreeIfNeeded()
        }
    }

    private func updateMessageCardVisibility(shouldShow: Bool, animated: Bool = false) {
        guard shouldShow else {
            hideMessageCard(animated: animated)
            return
        }

        messageCardContainerView.isHidden = false
        messageCardHostingController.view.isHidden = false
        view.layoutSubtreeIfNeeded()

        updateMessageCardHeight(animated: animated)
    }

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

    func setContentActive(_ active: Bool) {
        guard active != isContentActive else { return }
        isContentActive = active

        contentCancellables.removeAll()
        tabList.setActive(active)

        // The pinned band is not mounted off-the-record (see setupStackView),
        // so don't spin up its controller or height bindings either.
        guard !state.isIncognito else { return }
        pinnedTabViewController.setActive(active)

        guard active else { return }

        pinnedTabViewController.$contentHeight
            .combineLatest(state.$isDraggingTab)
            .debounce(for: .seconds(0.01), scheduler: DispatchQueue.main)
            .sink { [weak self] newHeight, dragging in
                self?.updateFavoriteHeight(newHeight, isDragging: dragging)
            }
            .store(in: &contentCancellables)

        updateFavoriteHeight(pinnedTabViewController.contentHeight, isDragging: state.isDraggingTab)
    }

    private func updateHeaderHeight() {
        let showInSidebar = !PhiPreferences.GeneralSettings.loadLayoutMode().showsNavigationAtTop
        // Reserve the Spaces switch row's height under the exact conditions
        // the header shows the row (see
        // `SidebarHeaderView.updateSpaceSwitchVisibility`), mirroring the
        // docked sidebar's updateHeaderHeight: the row adds 32 (24 row + 8
        // gap) only while shown, so the header reclaims it when hidden.
        let spacesEnabled = PhiPreferences.GeneralSettings.spacesFeatureEnabled.loadValue()
            && state.participatesInSpaces
            && (SpaceManager.shared.spaces.count > 1 || headerView.forcesSpaceSwitchVisible)
        let base: CGFloat = showInSidebar ? 73 : 41
        let headerHeight = base + (spacesEnabled ? 32 : 0)
        headerHeightConstraint?.update(offset: headerHeight)
    }

    // MARK: - Create Space Overlay

    /// Inline "Create a Space" form filling the floating panel — the same
    /// per-Space flow the docked sidebar hosts (see
    /// `SidebarViewController.showCreateSpaceOverlay`); while the sidebar is
    /// collapsed the panel IS the sidebar surface, so creation stays inline
    /// instead of detouring through the standalone window. The panel pins
    /// itself open while the form is up (see
    /// `WebContentContainerViewController.scheduleFloatingSidebarHide`).
    private var createSpaceOverlay: ThemedHostingController<CreateSpacePanel>?

    /// Whether the inline create-Space form is up — consulted by the panel's
    /// hide scheduling so a pointer exit can't dismiss the form mid-typing.
    var hasCreateSpaceOverlay: Bool { createSpaceOverlay != nil }

    /// The active Space theme inherited when the form opened, restored on
    /// cancel, after the new target fronts, or when activation fails.
    private var themeBeforeCreateSpacePreview: Theme?

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
        // Keep the Spaces icon row visible above the form, even with a single
        // Space, and settle its header band before anchoring the overlay.
        headerView.forcesSpaceSwitchVisible = true
        updateHeaderHeight()
        view.layoutSubtreeIfNeeded()
        let stripRow = spacesStripRowView
        let anchorsBelowStrip = stripRow?.isHidden == false

        // No backdrop, unlike the docked flow: the docked sidebar keeps its
        // content in place and stands a matching visual-effect sheet over it,
        // but that recipe doesn't reproduce THIS panel's background (plain
        // themed layer inside the glass container on macOS 26) and read as
        // the wrong shade. Fading the panel's own content out below the form
        // lets the panel background itself be the sheet — an exact match by
        // construction.
        let host = ThemedHostingController(rootView: panel, themeSource: state.themeContext)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        // Fill the panel at its current width — never let the form's intrinsic
        // size (the icon grid is wider than a narrow panel) push it wider.
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
        host.view.alphaValue = 0
        createSpaceOverlay = host
        themeBeforeCreateSpacePreview = state.themeContext.currentTheme
        // Keep the visible strip read-only while creating so a pip click cannot
        // switch the form's window away.
        spacesStripSlot.isCreatingSpace = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.allowsImplicitAnimation = true
            host.view.animator().alphaValue = 1
            setContentFadedForCreateOverlay(true)
        }
    }

    private func previewCreateSpaceOverlayTheme(_ theme: Theme) {
        guard createSpaceOverlay != nil else { return }
        state.themeContext.setTheme(theme)
    }

    func dismissCreateSpaceOverlay(restorePreviewTheme: Bool = true) {
        guard let host = createSpaceOverlay else { return }
        createSpaceOverlay = nil
        if restorePreviewTheme {
            restoreCreateSpacePreviewTheme()
        }
        spacesStripSlot.isCreatingSpace = false
        // Release forced visibility. Normal Space-count rules take over again.
        headerView.forcesSpaceSwitchVisible = false
        updateHeaderHeight()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.allowsImplicitAnimation = true
            host.view.animator().alphaValue = 0
            setContentFadedForCreateOverlay(false)
        }) {
            host.view.removeFromSuperview()
            host.removeFromParent()
        }
        // The form no longer pins the panel open; re-run the pointer-driven
        // hide so the panel retracts if the pointer has already left.
        (parent as? WebContentContainerViewController)?.scheduleFloatingSidebarHide()
    }

    /// Restores the source Space after the new target fronts, or immediately
    /// when activation fails and the source window remains visible.
    private func restoreCreateSpacePreviewTheme() {
        guard let savedTheme = themeBeforeCreateSpacePreview else { return }
        themeBeforeCreateSpacePreview = nil
        state.themeContext.setTheme(savedTheme)
    }

    /// Fades the panel content below the strip row while the create-Space
    /// form covers it, so nothing ghosts through the form and the panel's
    /// themed background serves as the form's sheet. Alpha (not `isHidden`)
    /// so the stack layout is untouched and the fade can animate.
    private func setContentFadedForCreateOverlay(_ faded: Bool) {
        let alpha: CGFloat = faded ? 0 : 1
        pinnedTabsContainerView.animator().alphaValue = alpha
        tabList.view.animator().alphaValue = alpha
        messageCardContainerView.animator().alphaValue = alpha
        bottomBarSwiftUI.animator().alphaValue = alpha
    }

    private func updateFavoriteHeight(_ newHeight: CGFloat, isDragging: Bool = false) {
        let clampedHeight: CGFloat
        if newHeight < 20 && isDragging {
            clampedHeight = 100
        } else {
            clampedHeight = newHeight
        }

        pinnedHeightConstraint?.update(offset: clampedHeight)
        view.layoutSubtreeIfNeeded()
    }
}

// MARK: - SpaceSwitchBandSurface

extension FloatingSidebarViewController: SpaceSwitchBandSurface {
    // Same band as the docked sidebar: the Spaces switch lives in the header
    // (with its own scroll animation), so the push-in band is just the pinned
    // strip and the tab list.
    var spaceSwitchBandViews: [NSView] { [pinnedTabsContainerView, tabList.view] }
    var spaceSwitchBandContainer: NSView { mainStackView }

    func rampSpaceTint(fromHex: String?, toHex: String?, duration: TimeInterval) {
        // The floating panel paints no per-Space tint gradient; its themed
        // background follows the window theme ramp that the swap drives
        // (see SpaceWindowSlot.rampWindowTheme).
    }
}

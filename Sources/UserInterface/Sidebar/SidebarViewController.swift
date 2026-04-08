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
            self?.state.toggleAIChat()
        }
        view.onCardEntryTap = { [weak self] in
            self?.showMessageCardTemporarily()
        }
        return view
    }()
    
    /// Wraps the pinned tab controller so its height can be adjusted independently.
    private lazy var pinnedTabContainerView: NSView = {
        let view = NSView()
        view.wantsLayer = true
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
    
    private var messageCardThemeObserver = ThemeObserver.shared
    
    /// Hosting controller for the sidebar message card view.
    private lazy var messageCardHostingController: NSHostingController<AnyView> = {
        let hostingController = NSHostingController(rootView: makeMessageCardRootView())
        if #available(macOS 13.0, *) {
            // Avoid intrinsic size constraints from NSHostingController; we measure explicitly.
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
        updateSidebarContentActivation()
    }
    
    override func viewWillAppear() {
        super.viewWillAppear()
        updateSwiftUIThemeObservers()
    }
    
    override func viewDidAppear() {
        super.viewDidAppear()
        updateSwiftUIThemeObservers()
        bottomBarSwiftUI.bindDownloadsManager(state.downloadsManager)
    }

    /// Update chat button visibility based on configuration and current tab's aiChatEnabled
    private func updateChatButtonVisibility() {
        let navigationAtTop = PhiPreferences.GeneralSettings.loadLayoutMode().showsNavigationAtTop
        let aiChatEnabled = state.focusingTab?.aiChatEnabled ?? false
        let phiAIEnabled = UserDefaults.standard.bool(forKey: PhiPreferences.AISettings.phiAIEnabled.rawValue)
        let shouldHideChat = state.isIncognito || navigationAtTop || !aiChatEnabled || !phiAIEnabled
        bottomBarSwiftUI.setChatHidden(shouldHideChat)
    }

    /// Update header height based on configuration
    private func updateHeaderHeight() {
        let showInSidebar = !PhiPreferences.GeneralSettings.loadLayoutMode().showsNavigationAtTop
        let headerHeight: CGFloat = showInSidebar ? 73 : 41
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
                self?.updateHeaderHeight()
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Setup
    
    private func setupStackView() {
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
    
    private func updateSwiftUIThemeObservers() {
        messageCardThemeObserver = ThemeObserver(themeSource: view.themeStateProvider)
        messageCardHostingController.rootView = makeMessageCardRootView()
    }
    
    private func makeMessageCardRootView() -> AnyView {
        AnyView(
            NotificationMessageCardView(
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
            )
            .phiThemeObserver(messageCardThemeObserver)
        )
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
    
    /// Observe `aiChatEnabled` on the current focusing tab.
    private func observeFocusingTabAIChatEnabled(_ tab: Tab?) {
        focusingTabAIChatEnabledCancellable?.cancel()
        focusingTabAIChatEnabledCancellable = nil
        
        guard let tab else { return }
        
        focusingTabAIChatEnabledCancellable = tab.$aiChatEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateChatButtonVisibility()
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
}

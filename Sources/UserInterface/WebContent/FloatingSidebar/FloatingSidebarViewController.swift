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
    private static let defaultFavoriteHeight: CGFloat = 10
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
            self?.state.toggleAIChat()
        }
        view.onCardEntryTap = {
            NotificationCardManager.shared.showManually(for: .sidebar)
        }
        view.onMemoryTap = {
            BrowserState.currentState()?.createTab("chrome://memory/memory.html", focusAfterCreate: true)
        }
        return view
    }()

    private var cancellables = Set<AnyCancellable>()
    private var contentCancellables = Set<AnyCancellable>()
    private var focusingTabAIChatEnabledCancellable: AnyCancellable?
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

    deinit {
        tabList.tearDown()
    }

    private func setupStackView() {
        addChild(pinnedTabViewController)
        addChild(tabList)

        view.addSubview(mainStackView)
        mainStackView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        // 1. Header
        mainStackView.addArrangedSubview(headerView)
        headerView.snp.makeConstraints { make in
            headerHeightConstraint = make.height.equalTo(73).constraint
            make.leading.equalToSuperview()
            make.trailing.equalToSuperview().inset(WebContentConstant.edgesSpacing)
        }

        // 2. Header spacer
        mainStackView.addArrangedSubview(createSpacer(height: 5))

        // 3. pinned tabs
        pinnedTabsContainerView.addSubview(pinnedTabViewController.view)
        pinnedTabViewController.view.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        mainStackView.addArrangedSubview(pinnedTabsContainerView)
        pinnedTabsContainerView.snp.makeConstraints { make in
            make.leading.equalToSuperview()
            make.trailing.equalToSuperview().inset(WebContentConstant.edgesSpacing)
            pinnedHeightConstraint = make.height.equalTo(Self.defaultFavoriteHeight).constraint
        }

        // 4. Favorites spacer
        mainStackView.addArrangedSubview(createSpacer(height: 3))

        // 5. Tab list
        mainStackView.addArrangedSubview(tabList.view)
        tabList.view.snp.makeConstraints { make in
            make.leading.equalToSuperview()
            make.trailing.equalToSuperview().inset(WebContentConstant.edgesSpacing)
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
            make.leading.equalToSuperview()
            make.trailing.equalToSuperview().inset(WebContentConstant.edgesSpacing)
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
                self?.updateHeaderHeight()
            }
            .store(in: &cancellables)
    }

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

    private func updateChatButtonVisibility() {
        let navigationAtTop = PhiPreferences.GeneralSettings.loadLayoutMode().showsNavigationAtTop
        let aiChatEnabled = state.focusingTab?.aiChatEnabled ?? false
        let phiAIEnabled = UserDefaults.standard.bool(forKey: PhiPreferences.AISettings.phiAIEnabled.rawValue)
        let shouldHideChat = state.isIncognito || navigationAtTop || !aiChatEnabled || !phiAIEnabled
        bottomBarSwiftUI.setChatHidden(shouldHideChat)
    }

    private func updateMemoryButtonVisibility() {
        let phiAIEnabled = UserDefaults.standard.bool(forKey: PhiPreferences.AISettings.phiAIEnabled.rawValue)
        bottomBarSwiftUI.setMemoryHidden(!phiAIEnabled)
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
        pinnedTabViewController.setActive(active)
        tabList.setActive(active)

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
        let headerHeight: CGFloat = showInSidebar ? 73 : 41
        headerHeightConstraint?.update(offset: headerHeight)
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

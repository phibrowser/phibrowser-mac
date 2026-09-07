// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI
import Combine

// MARK: - State

struct WebContentHeaderPageColorPresentation: Equatable {
    let backgroundColor: NSColor?
    let appearance: Appearance?

    static let inherited = WebContentHeaderPageColorPresentation(
        backgroundColor: nil,
        appearance: nil
    )
}

class WebContentHeaderState: ObservableObject {
    @Published var showAddressBar: Bool = false
    @Published var showNavigationButtons: Bool = false
    @Published var showChatButton: Bool = false
    @Published var showFeedbackButton: Bool = false
    @Published var isFeedbackIconOnly: Bool = false
    @Published var showDownloadButton: Bool = false
    @Published var showMemoryButton: Bool = false
    @Published var showSidebarButton: Bool = false
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false
    @Published var loadingProgress: Double = 0
    @Published var isLoading: Bool = false
    @Published var isProgressVisible: Bool = false
    @Published var isDownloadPopoverShown: Bool = false
    @Published var isIncognito: Bool = false
    @Published var isInPlaceholderMode: Bool = false
    @Published var pageColorPresentation = WebContentHeaderPageColorPresentation.inherited

    var pageBackgroundColor: NSColor? { pageColorPresentation.backgroundColor }
    var pageAppearance: Appearance? { pageColorPresentation.appearance }

    init() {
        let layoutMode = PhiPreferences.GeneralSettings.loadLayoutMode()
        let navigationAtTop = layoutMode.showsNavigationAtTop
        let traditionalLayout = layoutMode.isTraditional
        let phiAIEnabled = UserDefaults.standard.bool(forKey: PhiPreferences.AISettings.phiAIEnabled.rawValue)
        self.showAddressBar = navigationAtTop
        self.showNavigationButtons = navigationAtTop
        self.showDownloadButton = traditionalLayout
        self.showMemoryButton = traditionalLayout && phiAIEnabled
        self.showFeedbackButton = traditionalLayout
            && !ApplicationState.shared.isGuest
        self.isFeedbackIconOnly = traditionalLayout
        self.showChatButton = false
    }

    func updateProgressVisibility(isNTP: Bool, isLoading: Bool, progress: Double) {
        if isNTP || !isLoading {
            isProgressVisible = false
            return
        }
        
        if progress == 0 {
            isProgressVisible = false
        } else if progress >= 1.0 {
            if isProgressVisible {
                isProgressVisible = false
            }
        } else {
            isProgressVisible = true
        }
    }
}

// MARK: - NSView Bridge

class WebContentHeader: NSView {
    var currentTab: Tab? {
        didSet {
            if currentTab !== oldValue {
                setupObservers()
                updateHostingRoot()
            }
        }
    }

    var onCurrentTabUrlChanged: ((String?) -> Void)?

    var pageColorPresentation: WebContentHeaderPageColorPresentation {
        state.pageColorPresentation
    }
    var pageColorPresentationPublisher: AnyPublisher<WebContentHeaderPageColorPresentation, Never> {
        state.$pageColorPresentation.eraseToAnyPublisher()
    }

    private(set) var addressBarAnchorView: NSView?
    private weak var sidebarButtonAnchorView: NSView?
    private weak var chatButtonAnchorView: NSView?
    private var hostingView: ZeroSafeAreaHostingView<AnyView>?
    private let state = WebContentHeaderState()
    private let downloadViewModel = DownloadButtonViewModel()
    private var cancellables = Set<AnyCancellable>()
    /// Subscription for the current tab's split-partner `aiChatEnabled` state,
    /// rebuilt whenever the tab or split membership changes.
    private var partnerAIChatEnabledCancellable: AnyCancellable?
    private weak var browserState: BrowserState?
    private var didSetupHostingView = false
    private var themeObserver = ThemeObserver.shared

    private var owningBrowserState: BrowserState? { unsafeBrowserState ?? browserState }
    private var headerThemeProvider: ThemeStateProvider {
        owningBrowserState?.themeContext ?? themeStateProvider
    }

    private lazy var bottomSeparator: NSView = {
        let view = NSView()
        view.wantsLayer = true
        return view
    }()

    static func shouldShowBottomSeparator(
        isSplitViewVisible: Bool,
        isBookmarkBarVisible: Bool
    ) -> Bool {
        !isSplitViewVisible || isBookmarkBarVisible
    }

    func updateBottomSeparatorVisibility(
        isSplitViewVisible: Bool,
        isBookmarkBarVisible: Bool
    ) {
        bottomSeparator.isHidden = !Self.shouldShowBottomSeparator(
            isSplitViewVisible: isSplitViewVisible,
            isBookmarkBarVisible: isBookmarkBarVisible
        )
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupHostingView()
    }

    init(browserState: BrowserState?) {
        self.browserState = browserState
        super.init(frame: .zero)
        setupHostingView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupHostingView()
    }

    // MARK: - Hosting View Setup

    private func setupHostingView() {
        guard !didSetupHostingView else { return }
        didSetupHostingView = true

        wantsLayer = true
        themeObserver = ThemeObserver(themeSource: headerThemeProvider)
        let swiftUIView = makeSwiftUIView()

        let hosting = ZeroSafeAreaHostingView(rootView: swiftUIView)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)

        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        self.hostingView = hosting

        addSubview(bottomSeparator)
        bottomSeparator.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bottomSeparator.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomSeparator.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomSeparator.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomSeparator.heightAnchor.constraint(equalToConstant: 1)
        ])
        setupObservers()
    }

    private func makeSwiftUIView() -> AnyView {
        AnyView(WebContentHeaderView(
            state: state,
            downloadViewModel: downloadViewModel,
            currentTab: currentTab,
            browserState: browserState,
            onSidebarTap: { [weak self] in
                self?.sidebarButtonClicked()
            },
            onBackTap: { [weak self] in
                self?.backButtonClicked()
            },
            onForwardTap: { [weak self] in
                self?.forwardButtonClicked()
            },
            onRefreshTap: { [weak self] in
                self?.refreshButtonClicked()
            },
            onStopLoadingTap: { [weak self] in
                self?.stopLoadingButtonClicked()
            },
            onChatTap: { [weak self] in
                self?.aiChatButtonClicked()
            },
            onFeedbackTap: { [weak self] in
                self?.feedbackButtonClicked()
            },
            onMemoryTap: { [weak self] in
                self?.memoryButtonClicked()
            },
            onDownloadTap: { [weak self] in
                self?.downloadButtonClicked()
            },
            onOpenLocationBar: { [weak self] anchorView in
                self?.unsafeBrowserWindowController?.openLocationBar(anchorView)
            },
            onAnchorResolved: { [weak self] view in
                self?.addressBarAnchorView = view
            },
            onSidebarAnchorResolved: { [weak self] view in
                self?.sidebarButtonAnchorView = view
            },
            onChatAnchorResolved: { [weak self] view in
                self?.chatButtonAnchorView = view
            }
        )
        .phiThemeObserver(themeObserver))
    }

    private func updateHostingRoot() {
        hostingView?.rootView = makeSwiftUIView()
    }

    // MARK: - Observers

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            let provider = headerThemeProvider
            AppLogDebug("[ThemeDebug] WebContentHeader.viewDidMoveToWindow: provider=\(type(of: provider)), theme=\(provider.currentTheme.id), appearance=\(provider.currentAppearance)")
            themeObserver.rebind(to: provider)
        }
        setupObservers()
        updateLayoutVisibility()
    }

    private func setupConfigObserver() {
        guard let unsafeBrowserState = owningBrowserState else { return }
        unsafeBrowserState
            .$layoutMode
            .combineLatest(unsafeBrowserState.$lastPhiAIEnabled)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateLayoutVisibility()
            }
            .store(in: &cancellables)

        // Re-run layout visibility when entering/leaving placeholder mode so
        // navigation + chat buttons hide alongside the placeholder shell.
        unsafeBrowserState.$isInPlaceholderMode
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateLayoutVisibility()
            }
            .store(in: &cancellables)
    }

    private func setupObservers() {
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
        partnerAIChatEnabledCancellable?.cancel()
        partnerAIChatEnabledCancellable = nil
        setupConfigObserver()

        headerThemeProvider.themeAppearancePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updatePageColor()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .browserAccessStateDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateLayoutVisibility()
            }
            .store(in: &cancellables)

        owningBrowserState?.$sidebarCollapsed
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateLayoutVisibility()
            }
            .store(in: &cancellables)

        owningBrowserState?.$groupOverviewState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateLayoutVisibility()
            }
            .store(in: &cancellables)

        // Split membership controls whether we treat the partner's
        // aiChatEnabled as a fallback for the chat button. Rebind the partner
        // observer and refresh on every splits change so the button reacts
        // when this tab joins or leaves a split.
        owningBrowserState?.$splits
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.observePartnerAIChatEnabled()
                self?.updateLayoutVisibility()
            }
            .store(in: &cancellables)

        state.loadingProgress = 0
        state.isLoading = false
        state.isProgressVisible = false
        updateLayoutVisibility()
        guard let currentTab else { return }

        currentTab.$pageColor
            .combineLatest(currentTab.$url, currentTab.$crashState, currentTab.$hasWebContent)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak currentTab] _ in
                guard let self, let currentTab, self.currentTab === currentTab else { return }
                self.updatePageColor()
            }
            .store(in: &cancellables)

        currentTab.$loadingProgress
            .combineLatest(currentTab.$isLoading)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] progress, isLoading in
                guard let self else { return }
                let isNTP = self.currentTab?.isNTP == true
                self.state.isLoading = isLoading
                self.state.loadingProgress = Double(progress)
                self.state.updateProgressVisibility(isNTP: isNTP, isLoading: isLoading, progress: Double(progress))
            }
            .store(in: &cancellables)

        currentTab.$canGoBack
            .combineLatest(currentTab.$canGoForward)
            .sink { [weak self] canGoBack, canGoForward in
                self?.state.canGoBack = canGoBack
                self?.state.canGoForward = canGoForward
            }
            .store(in: &cancellables)

        currentTab.$url
            .receive(on: DispatchQueue.main)
            .sink { [weak self] url in
                self?.onCurrentTabUrlChanged?(url)
            }
            .store(in: &cancellables)

        currentTab.$aiChatEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateLayoutVisibility()
            }
            .store(in: &cancellables)

        observePartnerAIChatEnabled()
    }

    /// Resolve the current tab's split partner, if any.
    private func splitPartner() -> Tab? {
        guard let state = owningBrowserState,
              let tab = currentTab,
              let group = state.splitGroup(forTabId: tab.guid),
              let partnerId = group.partnerTabId(of: tab.guid) else {
            return nil
        }
        return state.tabs.first { $0.guid == partnerId }
    }

    /// Observe `aiChatEnabled` on the current tab's split partner so the chat
    /// button stays visible while either pane has chat enabled.
    private func observePartnerAIChatEnabled() {
        partnerAIChatEnabledCancellable?.cancel()
        partnerAIChatEnabledCancellable = nil
        guard let partner = splitPartner() else { return }
        partnerAIChatEnabledCancellable = partner.$aiChatEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateLayoutVisibility()
            }
    }

    private func updateLayoutVisibility() {
        updatePageColor()
        let layoutMode = PhiPreferences.GeneralSettings.loadLayoutMode()
        let navigationAtTop = layoutMode.showsNavigationAtTop
        let traditionalLayout = layoutMode.isTraditional
        let isCollapsed = owningBrowserState?.sidebarCollapsed ?? false
        let isIncognito = owningBrowserState?.isIncognito ?? false
        let overviewActive = owningBrowserState?.groupOverviewState != nil
        let focusedAIChat = currentTab?.aiChatEnabled ?? false
        // In a split the chat is shared between the two panes, so keep the
        // button visible while either pane has chat enabled (e.g. one side
        // is an NTP and the other is a real page).
        let partnerAIChat = splitPartner()?.aiChatEnabled ?? false
        let aiChatEnabled = focusedAIChat || partnerAIChat
        let isInPlaceholder = owningBrowserState?.isInPlaceholderMode ?? false
        let phiAIEnabled = UserDefaults.standard.bool(forKey: PhiPreferences.AISettings.phiAIEnabled.rawValue)
        let isGuest = ApplicationState.shared.isGuest

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.state.showAddressBar = navigationAtTop
            self.state.showNavigationButtons = navigationAtTop && !isInPlaceholder
            self.state.showChatButton = navigationAtTop && !overviewActive && !isIncognito && aiChatEnabled && phiAIEnabled && !isInPlaceholder
            self.state.showFeedbackButton =
                (traditionalLayout || (navigationAtTop && isCollapsed))
                && !isInPlaceholder
                && !isGuest
            self.state.isFeedbackIconOnly = traditionalLayout
            self.state.showDownloadButton = (traditionalLayout || (navigationAtTop && isCollapsed)) && !isInPlaceholder
            self.state.showMemoryButton = (traditionalLayout || (navigationAtTop && isCollapsed)) && phiAIEnabled && !isIncognito && !isInPlaceholder
            self.state.showSidebarButton = !traditionalLayout && navigationAtTop && isCollapsed
            self.state.isIncognito = isIncognito
            self.state.isInPlaceholderMode = isInPlaceholder
        }
    }

    // MARK: - Page Color

    private func updatePageColor() {
        let provider = headerThemeProvider
        let theme = provider.currentTheme
        let fallbackAppearance = provider.currentAppearance
        let fallback = ThemedColor.windowBackground.resolve(theme: theme, appearance: fallbackAppearance)
        let tab = currentTab
        let canApplyPageColor = tab?.hasWebContent == true
            && tab?.isNTP != true
            && tab?.crashState == nil
            && !BookmarkManagerRoute.matches(tab?.url)
            && owningBrowserState?.isInPlaceholderMode != true
            && owningBrowserState?.groupOverviewState == nil
            && tab.map { owningBrowserState?.splitGroup(forTabId: $0.guid) == nil } == true
        let background = canApplyPageColor
            ? tab?.pageColor.map { Self.compositePageColor($0, over: fallback) }
            : nil
        let pageAppearance: Appearance? = background.map {
            $0.contrastRatio(with: .white) > $0.contrastRatio(with: .black) ? .dark : .light
        }

        // Own both layer colors here so a theme binding cannot overwrite the page override.
        layer?.backgroundColor = (background ?? fallback).cgColor
        bottomSeparator.layer?.backgroundColor = ThemedColor.separator.resolve(
            theme: theme, appearance: pageAppearance ?? fallbackAppearance
        ).cgColor
        let pageColorPresentation = WebContentHeaderPageColorPresentation(
            backgroundColor: background,
            appearance: pageAppearance
        )
        if state.pageColorPresentation != pageColorPresentation {
            state.pageColorPresentation = pageColorPresentation
        }
        if appearance?.phiAppearance != pageAppearance { appearance = pageAppearance?.nsAppearance }
    }

    /// Composite the supplied alpha over the existing header surface before choosing its ink.
    static func compositePageColor(_ pageColor: NSColor, over background: NSColor) -> NSColor {
        guard let foreground = pageColor.usingColorSpace(.sRGB),
              let background = background.usingColorSpace(.sRGB) else { return background }
        let alpha = foreground.alphaComponent
        let backgroundAlpha = background.alphaComponent * (1 - alpha)
        let resultAlpha = alpha + backgroundAlpha
        guard resultAlpha > 0 else { return .clear }
        return NSColor(
            srgbRed: (foreground.redComponent * alpha + background.redComponent * backgroundAlpha) / resultAlpha,
            green: (foreground.greenComponent * alpha + background.greenComponent * backgroundAlpha) / resultAlpha,
            blue: (foreground.blueComponent * alpha + background.blueComponent * backgroundAlpha) / resultAlpha,
            alpha: resultAlpha
        )
    }

    // MARK: - Actions

    @objc private func sidebarButtonClicked() {
        unsafeBrowserState?.toggleSidebar()
    }

    @objc private func backButtonClicked() {
        if unsafeBrowserState?.closePeekForBackForwardNavigation() == true { return }
        if unsafeBrowserState?.closeReaderOverlayForBackForwardNavigation() == true { return }
        unsafeBrowserState?.focusingTab?.goBack()
    }

    @objc private func forwardButtonClicked() {
        if unsafeBrowserState?.closePeekForBackForwardNavigation() == true { return }
        if unsafeBrowserState?.closeReaderOverlayForBackForwardNavigation() == true { return }
        unsafeBrowserState?.focusingTab?.goForward()
    }

    @objc private func refreshButtonClicked() {
        unsafeBrowserState?.focusingTab?.reload()
    }

    @objc private func stopLoadingButtonClicked() {
        unsafeBrowserState?.focusingTab?.stopLoading()
    }

    @objc private func aiChatButtonClicked() {
        // Defense in depth: chat button should already be hidden in placeholder
        // mode (see updateLayoutVisibility). Belt-and-braces guard avoids
        // toggling chat if a stale tap somehow reaches this handler.
        guard unsafeBrowserState?.isInPlaceholderMode != true else {
            NSSound.beep()
            return
        }
        guard unsafeBrowserState?.groupOverviewState == nil else {
            NSSound.beep()
            return
        }
        FeatureEntryAnalytics.capture(.chat, surface: .webContentHeader)
        unsafeBrowserState?.toggleAIChat()
    }

    @objc private func feedbackButtonClicked() {
        unsafeBrowserState?.windowController?.showFeedbackWindow()
    }

    @objc private func memoryButtonClicked() {
        guard let state = BrowserState.currentState() else { return }
        FeatureEntryAnalytics.capture(.memory, surface: .webContentHeader)
        state.createTab(
            "chrome://memory/memory.html",
            focusAfterCreate: true
        )
        FirstTimeActionTracker.capture(.memoryOpened)
    }

    private func downloadButtonClicked() {
        FeatureEntryAnalytics.capture(.download, surface: .webContentHeader)
    }

    // MARK: - Public Methods

    func bindDownloadsManager(_ manager: DownloadsManager) {
        downloadViewModel.bindTo(manager)
    }

    func containsAgentOverlayPassthroughControl(at point: NSPoint, from sourceView: NSView) -> Bool {
        guard !isHidden, window != nil else { return false }
        return [sidebarButtonAnchorView, chatButtonAnchorView].contains { anchor in
            guard let anchor,
                  anchor.window === window,
                  !anchor.isHidden,
                  !anchor.bounds.isEmpty else {
                return false
            }
            let pointInAnchor = anchor.convert(point, from: sourceView)
            return anchor.bounds.contains(pointInAnchor)
        }
    }
}

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
    /// True for a change within the same tab. A tab switch swaps the page
    /// instantly, so the chrome swaps with it.
    var animatesChange = false

    static let inherited = WebContentHeaderPageColorPresentation(
        backgroundColor: nil,
        appearance: nil
    )
}

extension WebContentHeaderPageColorPresentation {
    static let transitionDuration: CFTimeInterval = 0.25

    /// Crossfades from the on-screen color when `animated`; an unanimated
    /// change cancels a crossfade still in flight.
    static func setColor<Layer: CALayer>(
        _ color: CGColor,
        for keyPath: ReferenceWritableKeyPath<Layer, CGColor?>,
        key: String,
        on layer: Layer,
        animated: Bool
    ) {
        let current = layer[keyPath: keyPath]
        guard current != color else { return }
        let onScreen = layer.presentation()?[keyPath: keyPath] ?? current
        layer[keyPath: keyPath] = color
        guard animated,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let onScreen else {
            layer.removeAnimation(forKey: key)
            return
        }
        let transition = CABasicAnimation(keyPath: key)
        transition.fromValue = onScreen
        transition.toValue = color
        transition.duration = transitionDuration
        transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(transition, forKey: key)
    }
}

class WebContentHeaderState: ObservableObject {
    @Published var showAddressBar: Bool = false
    @Published var showNavigationButtons: Bool = false
    @Published var showChatButton: Bool = false
    @Published var showFeedbackButton: Bool = false
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
    /// Balanced only: dragging its Content Address Bar moves the window.
    @Published var allowsWindowDrag: Bool = false
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
            && PhiPreferences.GeneralSettings.topBarShowsDownloads.loadValue()
        self.showMemoryButton = traditionalLayout && phiAIEnabled
            && PhiPreferences.GeneralSettings.topBarShowsMemory.loadValue()
        self.showFeedbackButton = traditionalLayout
            && !ApplicationState.shared.isGuest
            && PhiPreferences.GeneralSettings.topBarShowsFeedback.loadValue()
        self.allowsWindowDrag = layoutMode == .balanced
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
    /// Subscriptions to `aiChatEnabled` on the other panes of the current
    /// tab's split, rebuilt whenever the tab or split membership changes.
    private var partnerAIChatEnabledCancellables = Set<AnyCancellable>()
    private weak var browserState: BrowserState?
    private var didSetupHostingView = false
    private var themeObserver = ThemeObserver.shared
    private weak var pageColorTab: Tab?

    /// The state the header was built with, or (for a header created without
    /// one) the window's. In hosted mode the window is the shared shell,
    /// whose lookup answers the presented Space, so a resident header of a
    /// background Space must not let it win.
    private var owningBrowserState: BrowserState? { browserState ?? unsafeBrowserState }
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
                self?.owningBrowserState?.windowController?.openLocationBar(anchorView)
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
        // A cached tab's header remounts on a tab switch, which snaps.
        layer?.removeAnimation(forKey: "backgroundColor")
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
        partnerAIChatEnabledCancellables.removeAll()
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

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .map { _ in
                [PhiPreferences.GeneralSettings.topBarShowsDownloads,
                 .topBarShowsMemory,
                 .topBarShowsFeedback].map { $0.loadValue() }
            }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateLayoutVisibility()
            }
            .store(in: &cancellables)

        owningBrowserState?.sidebarCollapsedPublisher
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

        // Split membership controls whether we treat the other panes'
        // aiChatEnabled as a fallback for the chat button. Rebind the pane
        // observers and refresh on every splits change so the button reacts
        // when this tab joins or leaves a split, or a pane is added/removed.
        owningBrowserState?.$splits
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.observePartnerAIChatEnabled()
                self?.updateLayoutVisibility()
            }
            .store(in: &cancellables)

        owningBrowserState?.$pendingSplitPreview
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updatePageColor()
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

    /// The other panes of the current tab's split, in slot order; empty when
    /// the tab is not in a split.
    private func splitPartners() -> [Tab] {
        guard let state = owningBrowserState,
              let tab = currentTab,
              let group = state.splitGroup(forTabId: tab.guid) else {
            return []
        }
        return group.otherTabIds(of: tab.guid).compactMap { partnerId in
            state.tabs.first { $0.guid == partnerId }
        }
    }

    /// Observe `aiChatEnabled` on the other panes of the current tab's split
    /// so the chat button stays visible while any pane has chat enabled.
    private func observePartnerAIChatEnabled() {
        partnerAIChatEnabledCancellables.removeAll()
        for partner in splitPartners() {
            partner.$aiChatEnabled
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.updateLayoutVisibility()
                }
                .store(in: &partnerAIChatEnabledCancellables)
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
        // In a split the chat is shared between the panes, so keep the
        // button visible while any pane has chat enabled (e.g. one pane
        // is an NTP and another is a real page).
        let partnerAIChat = splitPartners().contains { $0.aiChatEnabled }
        let aiChatEnabled = focusedAIChat || partnerAIChat
        let isInPlaceholder = owningBrowserState?.isInPlaceholderMode ?? false
        let phiAIEnabled = UserDefaults.standard.bool(forKey: PhiPreferences.AISettings.phiAIEnabled.rawValue)
        let isGuest = ApplicationState.shared.isGuest
        // The Comfortable top bar honors its own button settings; Balanced
        // only borrows these buttons while the sidebar is collapsed.
        let showsTopBarDownloads = !traditionalLayout
            || PhiPreferences.GeneralSettings.topBarShowsDownloads.loadValue()
        let showsTopBarMemory = !traditionalLayout
            || PhiPreferences.GeneralSettings.topBarShowsMemory.loadValue()
        let showsTopBarFeedback = !traditionalLayout
            || PhiPreferences.GeneralSettings.topBarShowsFeedback.loadValue()

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.state.showAddressBar = navigationAtTop
            self.state.showNavigationButtons = navigationAtTop && !isInPlaceholder
            self.state.showChatButton = navigationAtTop && !overviewActive && !isIncognito && aiChatEnabled && phiAIEnabled && !isInPlaceholder
            self.state.showFeedbackButton =
                (traditionalLayout || (navigationAtTop && isCollapsed))
                && !isInPlaceholder
                && !isGuest
                && showsTopBarFeedback
            self.state.allowsWindowDrag = layoutMode == .balanced
            self.state.showDownloadButton = (traditionalLayout || (navigationAtTop && isCollapsed)) && !isInPlaceholder
                && showsTopBarDownloads
            self.state.showMemoryButton = (traditionalLayout || (navigationAtTop && isCollapsed)) && phiAIEnabled && !isIncognito && !isInPlaceholder
                && showsTopBarMemory
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
        let fallback = theme.extensionSurfaceBackground(for: fallbackAppearance)
        // The blank split pane has no page color while its URL is being chosen.
        let isSplitPreview = currentTab.map {
            owningBrowserState?.pendingSplitPreview?.partnerTabId == $0.guid
        } ?? false
        let tab = isSplitPreview ? nil : currentTab
        let canApplyPageStyle = tab?.hasWebContent == true
            && tab?.crashState == nil
            && !BookmarkManagerRoute.matches(tab?.url)
            && owningBrowserState?.isInPlaceholderMode != true
            && owningBrowserState?.groupOverviewState == nil
            && tab.map { owningBrowserState?.splitGroup(forTabId: $0.guid) == nil } == true
        let usesExtensionSurface = tab == nil
            || tab?.isNTP == true
            || tab?.url?.isLocalUrlString == true
            || tab?.hasWebContent == false
            || tab?.crashState != nil
            || BookmarkManagerRoute.matches(tab?.url)
            || owningBrowserState?.isInPlaceholderMode == true
            || owningBrowserState?.groupOverviewState != nil
        let pageBackground = canApplyPageStyle && !usesExtensionSurface
            ? tab?.pageColor.map { Self.compositePageColor($0, over: fallback) }
            : nil
        // Share the NTP/Chat surface when page colors are unavailable, including
        // the address bar and adjacent chrome that consume this presentation.
        let background = pageBackground ?? fallback
        let pageAppearance: Appearance? = pageBackground.map {
            $0.isLight() ? .light : .dark
        }
        let animatesChange = tab != nil && tab === pageColorTab
        pageColorTab = tab

        // Own both layer colors here so a theme binding cannot overwrite the page override.
        if let layer {
            WebContentHeaderPageColorPresentation.setColor(
                background.cgColor,
                for: \.backgroundColor,
                key: "backgroundColor",
                on: layer,
                animated: animatesChange
            )
        }
        bottomSeparator.layer?.backgroundColor = ThemedColor.separator.resolve(
            theme: theme, appearance: pageAppearance ?? fallbackAppearance
        ).cgColor
        let pageColorPresentation = WebContentHeaderPageColorPresentation(
            backgroundColor: background,
            appearance: pageAppearance,
            animatesChange: animatesChange
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
        owningBrowserState?.toggleSidebar()
    }

    @objc private func backButtonClicked() {
        if owningBrowserState?.closePeekForBackForwardNavigation() == true { return }
        if owningBrowserState?.closeReaderOverlayForBackForwardNavigation() == true { return }
        owningBrowserState?.focusingTab?.goBack()
    }

    @objc private func forwardButtonClicked() {
        if owningBrowserState?.closePeekForBackForwardNavigation() == true { return }
        if owningBrowserState?.closeReaderOverlayForBackForwardNavigation() == true { return }
        owningBrowserState?.focusingTab?.goForward()
    }

    @objc private func refreshButtonClicked() {
        owningBrowserState?.focusingTab?.reload()
    }

    @objc private func stopLoadingButtonClicked() {
        owningBrowserState?.focusingTab?.stopLoading()
    }

    @objc private func aiChatButtonClicked() {
        // Defense in depth: chat button should already be hidden in placeholder
        // mode (see updateLayoutVisibility). Belt-and-braces guard avoids
        // toggling chat if a stale tap somehow reaches this handler.
        guard owningBrowserState?.isInPlaceholderMode != true else {
            NSSound.beep()
            return
        }
        guard owningBrowserState?.groupOverviewState == nil else {
            NSSound.beep()
            return
        }
        FeatureEntryAnalytics.capture(.chat, surface: .webContentHeader)
        owningBrowserState?.toggleAIChat()
    }

    @objc private func feedbackButtonClicked() {
        owningBrowserState?.windowController?.showFeedbackWindow()
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

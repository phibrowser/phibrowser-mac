// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI
import Combine

// MARK: - State

class WebContentHeaderState: ObservableObject {
    @Published var showAddressBar: Bool = false
    @Published var showNavigationButtons: Bool = false
    @Published var showChatButton: Bool = false
    @Published var showFeedbackButton: Bool = false
    @Published var showDownloadButton: Bool = false
    @Published var showSidebarButton: Bool = false
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false
    @Published var loadingProgress: Double = 0
    @Published var isLoading: Bool = false
    @Published var isProgressVisible: Bool = false
    @Published var isDownloadPopoverShown: Bool = false
    @Published var isIncognito: Bool = false

    init() {
        let layoutMode = PhiPreferences.GeneralSettings.loadLayoutMode()
        let navigationAtTop = layoutMode.showsNavigationAtTop
        let traditionalLayout = layoutMode.isTraditional
        self.showAddressBar = navigationAtTop
        self.showNavigationButtons = navigationAtTop
        self.showDownloadButton = traditionalLayout
        self.showFeedbackButton = traditionalLayout
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
            if currentTab?.guid != oldValue?.guid {
                setupObservers()
                updateHostingRoot()
            }
        }
    }

    var onCurrentTabUrlChanged: ((String?) -> Void)?

    private(set) var addressBarAnchorView: NSView?
    private var hostingView: ZeroSafeAreaHostingView<WebContentHeaderView>?
    private let state = WebContentHeaderState()
    private let downloadViewModel = DownloadButtonViewModel()
    private var cancellables = Set<AnyCancellable>()
    private weak var browserState: BrowserState?
    private var didSetupHostingView = false

    private lazy var bottomSeparator: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.phiLayer?.setBackgroundColor(.separator)
        return view
    }()

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
        phiLayer?.setBackgroundColor(.contentOverlayBackground)

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
    }

    private func makeSwiftUIView() -> WebContentHeaderView {
        WebContentHeaderView(
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
            onOpenLocationBar: { [weak self] anchorView in
                self?.unsafeBrowserWindowController?.openLocationBar(anchorView)
            },
            onAnchorResolved: { [weak self] view in
                self?.addressBarAnchorView = view
            }
        )
    }

    private func updateHostingRoot() {
        hostingView?.rootView = makeSwiftUIView()
    }

    // MARK: - Observers

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        setupObservers()
        updateLayoutVisibility()
    }

    private func setupConfigObserver() {
        guard let unsafeBrowserState else { return }
        unsafeBrowserState
            .$layoutMode
            .combineLatest(unsafeBrowserState.$lastPhiAIEnabled)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateLayoutVisibility()
            }
            .store(in: &cancellables)
    }

    private func setupObservers() {
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
        setupConfigObserver()

        unsafeBrowserState?.$sidebarCollapsed
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateLayoutVisibility()
            }
            .store(in: &cancellables)

        state.loadingProgress = 0
        state.isLoading = false
        state.isProgressVisible = false
        guard let currentTab else { return }

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
    }

    private func updateLayoutVisibility() {
        let layoutMode = PhiPreferences.GeneralSettings.loadLayoutMode()
        let navigationAtTop = layoutMode.showsNavigationAtTop
        let traditionalLayout = layoutMode.isTraditional
        let isCollapsed = unsafeBrowserState?.sidebarCollapsed ?? false
        let isIncognito = unsafeBrowserState?.isIncognito ?? false
        let aiChatEnabled = currentTab?.aiChatEnabled ?? false
        let phiAIEnabled = UserDefaults.standard.bool(forKey: PhiPreferences.AISettings.phiAIEnabled.rawValue)

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.state.showAddressBar = navigationAtTop
            self.state.showNavigationButtons = navigationAtTop
            self.state.showChatButton = navigationAtTop && !isIncognito && aiChatEnabled && phiAIEnabled
            self.state.showFeedbackButton = traditionalLayout || (navigationAtTop && isCollapsed)
            self.state.showDownloadButton = traditionalLayout || (navigationAtTop && isCollapsed)
            self.state.showSidebarButton = !traditionalLayout && navigationAtTop && isCollapsed
            self.state.isIncognito = isIncognito
        }
    }

    // MARK: - Actions

    @objc private func sidebarButtonClicked() {
        unsafeBrowserState?.toggleSidebar()
    }

    @objc private func backButtonClicked() {
        unsafeBrowserState?.focusingTab?.goBack()
    }

    @objc private func forwardButtonClicked() {
        unsafeBrowserState?.focusingTab?.goForward()
    }

    @objc private func refreshButtonClicked() {
        unsafeBrowserState?.focusingTab?.reload()
    }

    @objc private func stopLoadingButtonClicked() {
        unsafeBrowserState?.focusingTab?.stopLoading()
    }

    @objc private func aiChatButtonClicked() {
        unsafeBrowserState?.toggleAIChat()
    }

    @objc private func feedbackButtonClicked() {
        unsafeBrowserState?.windowController?.showFeedbackWindow()
    }

    // MARK: - Public Methods

    func bindDownloadsManager(_ manager: DownloadsManager) {
        downloadViewModel.bindTo(manager)
    }
}

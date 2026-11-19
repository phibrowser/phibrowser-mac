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
    /// Downloads, Memory and Feedback: whether the button exists in this
    /// window's toolbar. Where it shows is up to `layoutShowsBottomBarItem`.
    @Published var showFeedbackButton: Bool = false
    @Published var showDownloadButton: Bool = false
    @Published var showMemoryButton: Bool = false
    /// Balanced with the sidebar docked: Downloads, Memory and Feedback sit
    /// in the sidebar's bottom bar (see `sidebarKeepsBottomBarItems`).
    @Published var sidebarKeepsBottomBarItems: Bool = false
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
    /// The stored arrangement, reconciled with this window's pinned extensions.
    @Published var arrangement = ToolbarArrangement.standard
    /// Where the Minimal address centers: the window's center, or in a split
    /// the header's own (see `MinimalAddressLayout.centerX`). Not
    /// `@Published`: it moves on every frame of a sidebar drag, and only the
    /// Minimal address observes it, so the rest of the header stays put.
    let windowCenter = HeaderWindowCenter()
    /// Customize Toolbar is on in this header: every placed item shows and
    /// can be dragged, and buttons do nothing when clicked.
    @Published var isCustomizing = false
    /// The toolbar item or the address bar being dragged from this toolbar
    /// while customizing (`ToolbarCustomizationController.draggedPayload`).
    /// Transient: the toolbar lays out without it (`layoutArrangement`),
    /// while `arrangement` and storage keep it until it lands or leaves.
    @Published var draggedPayload: ToolbarDragPayload?
    /// Whether Phi AI's buttons (Memory, Chat, Site Memories) exist in this
    /// window at all; while customizing they show whenever they exist, except
    /// Memory, which `layoutShowsBottomBarItem` still gates.
    @Published var isPhiAIAvailable = false
    @Published var isGuest = false

    /// Whether the layout lets the toolbar show Downloads, Memory or
    /// Feedback. While the sidebar keeps them in its bottom bar, the toolbar
    /// shows only those the user placed while customizing; the default
    /// arrangement's copies show once the sidebar collapses, as before.
    /// `arrangement` evaluates the rule for another arrangement than the
    /// stored one (the sheet's default row passes `.standard`).
    func layoutShowsBottomBarItem(_ item: ToolbarItemID, in arrangement: ToolbarArrangement? = nil) -> Bool {
        !sidebarKeepsBottomBarItems || (arrangement ?? self.arrangement).isPlacedByUser(item)
    }

    /// Whether the toolbar shows Toggle Sidebar: where the layout shows it
    /// (Balanced with the sidebar collapsed), or, while the docked sidebar's
    /// header has its own, where the user placed it while customizing.
    func layoutShowsSidebarToggle(in arrangement: ToolbarArrangement? = nil) -> Bool {
        showSidebarButton || (sidebarKeepsBottomBarItems && (arrangement ?? self.arrangement).isPlacedByUser(.sidebarToggle))
    }

    /// Balanced with the sidebar docked keeps Downloads, Memory and Feedback
    /// in the sidebar's bottom bar. Comfortable has no such bar, and
    /// Performance no toolbar that draws them.
    static func sidebarKeepsBottomBarItems(layoutMode: LayoutMode, sidebarCollapsed: Bool) -> Bool {
        layoutMode == .balanced && !sidebarCollapsed
    }

    /// Balanced drags the window by its address bar, except while customizing.
    var allowsAddressBarWindowDrag: Bool { allowsWindowDrag && !isCustomizing }

    /// Whether the header draws the address bar: the layout shows the
    /// toolbar and the arrangement has not removed the bar. The empty-window
    /// placeholder keeps its bar, its only way to start browsing by mouse.
    var drawsAddressBar: Bool {
        showAddressBar && (layoutArrangement.showsAddressBar || isInPlaceholderMode)
    }

    /// What the toolbar lays out: `arrangement`, less the item or the
    /// address bar being dragged from it while customizing, so the zones,
    /// the address bar and the overflow reflow as if it were gone. Outside
    /// customizing, `arrangement` itself.
    var layoutArrangement: ToolbarArrangement {
        Self.layoutArrangement(arrangement, dragging: isCustomizing ? draggedPayload : nil)
    }

    static func layoutArrangement(_ arrangement: ToolbarArrangement, dragging payload: ToolbarDragPayload?) -> ToolbarArrangement {
        var result = arrangement
        switch payload {
        case .item(let item): result.remove(item)
        case .addressBar: result.showsAddressBar = false
        case .defaultSet, nil: break
        }
        return result
    }

    var pageBackgroundColor: NSColor? { pageColorPresentation.backgroundColor }
    var pageAppearance: Appearance? { pageColorPresentation.appearance }

    init() {
        let layoutMode = PhiPreferences.GeneralSettings.loadLayoutMode()
        let navigationAtTop = layoutMode.showsNavigationAtTop
        let phiAIEnabled = UserDefaults.standard.bool(forKey: PhiPreferences.AISettings.phiAIEnabled.rawValue)
        self.showAddressBar = navigationAtTop
        self.showNavigationButtons = navigationAtTop
        self.showDownloadButton = navigationAtTop
        self.showMemoryButton = navigationAtTop && phiAIEnabled
        self.showFeedbackButton = navigationAtTop
            && !ApplicationState.shared.isGuest
        self.sidebarKeepsBottomBarItems = Self.sidebarKeepsBottomBarItems(layoutMode: layoutMode, sidebarCollapsed: false)
        self.allowsWindowDrag = layoutMode == .balanced
        self.showChatButton = false
        self.isPhiAIAvailable = phiAIEnabled
        self.isGuest = ApplicationState.shared.isGuest
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

/// Where the Minimal address centers, in the header's coordinates: the
/// window's horizontal center, which is far from the header's own midpoint
/// when the sidebar is docked, since the header spans only the page area. In
/// a split it is the header's own midpoint instead.
final class HeaderWindowCenter: ObservableObject {
    @Published var x: CGFloat = 0
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

    /// Where the location bar (⌘L) and the share picker drop down from: the
    /// address bar, or while the arrangement has removed it, a strip centered
    /// along the toolbar's bottom edge (`centeredLocationBarAnchor`).
    var addressBarAnchorView: NSView? {
        state.showAddressBar && !state.drawsAddressBar ? centeredLocationBarAnchor : resolvedAddressBarAnchorView
    }
    /// The address bar's own anchor, as its view last reported it.
    private var resolvedAddressBarAnchorView: NSView?
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
    private lazy var customization = makeCustomizationController()
    /// Ends customizing on Escape while this header is being customized.
    private var customizingEscapeMonitor: Any?
    /// The Customize Toolbar sheet, up exactly while this header is being customized.
    private var customizationSheet: ToolbarCustomizationSheet?

    /// The state the header was built with, or (for a header created without
    /// one) the window's. In hosted mode the window is the shared shell,
    /// whose lookup answers the presented Space, so a resident header of a
    /// background Space must not let it win.
    private var owningBrowserState: BrowserState? { browserState ?? unsafeBrowserState }
    private var headerThemeProvider: ThemeStateProvider {
        owningBrowserState?.themeContext ?? themeStateProvider
    }

    /// The location bar's anchor without an address bar: as wide as an
    /// address bar usually is, centered, along the toolbar's bottom edge, so
    /// the location bar hangs centered under the toolbar.
    private let centeredLocationBarAnchor = CenteredLocationBarAnchorView()
    static let centeredLocationBarAnchorWidth: CGFloat = 600
    static let centeredLocationBarAnchorInset: CGFloat = 16

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

    /// Whether the content under this header shows a split. Pushed by the
    /// owning controller with the separator update; the Minimal address
    /// centers on the header instead of the window meanwhile.
    private var isSplitViewVisible = false

    func updateBottomSeparatorVisibility(
        isSplitViewVisible: Bool,
        isBookmarkBarVisible: Bool
    ) {
        bottomSeparator.isHidden = !Self.shouldShowBottomSeparator(
            isSplitViewVisible: isSplitViewVisible,
            isBookmarkBarVisible: isBookmarkBarVisible
        )
        if self.isSplitViewVisible != isSplitViewVisible {
            self.isSplitViewVisible = isSplitViewVisible
            updateWindowCenter()
        }
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

    deinit {
        if let customizingEscapeMonitor {
            NSEvent.removeMonitor(customizingEscapeMonitor)
        }
        customizationSheet?.close()
    }

    // MARK: - Hosting View Setup

    private func setupHostingView() {
        guard !didSetupHostingView else { return }
        didSetupHostingView = true

        wantsLayer = true
        themeObserver = ThemeObserver(themeSource: headerThemeProvider)
        let swiftUIView = makeSwiftUIView()

        let hosting = WebContentHeaderHostingView(rootView: swiftUIView)
        hosting.onRightMouseDown = { [weak self] event in
            self?.showContextMenu(for: event) ?? false
        }
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

        addSubview(centeredLocationBarAnchor)
        centeredLocationBarAnchor.translatesAutoresizingMaskIntoConstraints = false
        // 600 points, narrowed to leave the inset on each side; never empty,
        // so it stays a valid anchor in a header not laid out yet. Its width
        // gives way to the header's: a split view places its dividers below
        // `defaultHigh`, so a stronger anchor would hold the page column
        // open and stop the sidebar column from widening.
        let preferredWidth = centeredLocationBarAnchor.widthAnchor.constraint(equalToConstant: Self.centeredLocationBarAnchorWidth)
        preferredWidth.priority = NSLayoutConstraint.Priority(NSLayoutConstraint.Priority.defaultLow.rawValue - 1)
        let fitsWidth = centeredLocationBarAnchor.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -2 * Self.centeredLocationBarAnchorInset)
        fitsWidth.priority = NSLayoutConstraint.Priority(NSLayoutConstraint.Priority.defaultHigh.rawValue + 1)
        NSLayoutConstraint.activate([
            centeredLocationBarAnchor.centerXAnchor.constraint(equalTo: centerXAnchor),
            centeredLocationBarAnchor.bottomAnchor.constraint(equalTo: bottomAnchor),
            centeredLocationBarAnchor.heightAnchor.constraint(equalToConstant: 1),
            centeredLocationBarAnchor.widthAnchor.constraint(greaterThanOrEqualToConstant: 1),
            fitsWidth,
            preferredWidth,
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
                self?.resolvedAddressBarAnchorView = view
            },
            onSidebarAnchorResolved: { [weak self] view in
                self?.sidebarButtonAnchorView = view
            },
            onChatAnchorResolved: { [weak self] view in
                self?.chatButtonAnchorView = view
            },
            onMinimalAddressLayout: { [weak self] in
                self?.updateWindowCenter()
            },
            onCustomizeToolbar: { [weak self] in
                self?.beginCustomizingToolbar()
            },
            customization: customization
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
        if window == nil {
            // A header out of its window (a cached tab's, on a tab switch) stops customizing.
            endCustomizingToolbar()
        } else {
            let provider = headerThemeProvider
            AppLogDebug("[ThemeDebug] WebContentHeader.viewDidMoveToWindow: provider=\(type(of: provider)), theme=\(provider.currentTheme.id), appearance=\(provider.currentAppearance)")
            themeObserver.rebind(to: provider)
        }
        setupObservers()
        updateLayoutVisibility()
        updateWindowCenter()
    }

    override func viewDidHide() {
        super.viewDidHide()
        // A Space switch conceals the leaving Space's page tree in the same window.
        endCustomizingToolbar()
    }

    override func layout() {
        super.layout()
        updateWindowCenter()
    }

    /// Only writes the center when the value moved, and only mutates observed
    /// state (never view geometry), so it cannot feed back into layout. Only
    /// the Minimal style reads it, so Standard skips the write.
    private func updateWindowCenter() {
        guard state.arrangement.addressBarStyle == .minimal,
              let window, let content = window.contentView else { return }
        let center = MinimalAddressLayout.centerX(
            windowWidth: content.bounds.width,
            headerMinXInWindow: convert(bounds, to: nil).minX,
            headerWidth: bounds.width,
            isSplitViewVisible: isSplitViewVisible
        )
        guard center != state.windowCenter.x else { return }
        state.windowCenter.x = center
    }

    private func setupWindowCenterObservers() {
        postsFrameChangedNotifications = true
        NotificationCenter.default.publisher(for: NSView.frameDidChangeNotification, object: self)
            .sink { [weak self] _ in self?.updateWindowCenter() }
            .store(in: &cancellables)
        guard let window else { return }
        NotificationCenter.default.publisher(for: NSWindow.didResizeNotification, object: window)
            .sink { [weak self] _ in self?.updateWindowCenter() }
            .store(in: &cancellables)
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
        setupWindowCenterObservers()

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

        observeToolbarArrangement()

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

    /// Keeps `state.arrangement` in step with the stored arrangement and this
    /// window's pinned extensions. Applied once synchronously so the first
    /// frame draws it, then on every change.
    private func observeToolbarArrangement() {
        let manager = owningBrowserState?.extensionManager
        applyToolbarArrangement(pinnedIDs: Self.pinnedExtensionIDs(manager?.pinedExtensions ?? []))

        // Every defaults write posts the notification; decode only when the
        // stored bytes change. The value only says that it changed: it is
        // read again on the main queue, where it is applied.
        let storedData = { UserDefaults.standard.data(forKey: PhiPreferences.GeneralSettings.toolbarArrangementKey) }
        // Any thread can post the notification: hop to main before reading
        // and decoding, which can migrate and write.
        let stored = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .map { _ in storedData() }
            .prepend(storedData())
            .removeDuplicates()
            .map { _ in PhiPreferences.GeneralSettings.loadToolbarArrangement() }
            .removeDuplicates()
        let pinnedIDs: AnyPublisher<[String], Never> = manager.map {
            $0.$pinedExtensions.map(Self.pinnedExtensionIDs).eraseToAnyPublisher()
        } ?? Just([]).eraseToAnyPublisher()
        stored
            .combineLatest(pinnedIDs.removeDuplicates())
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, pinnedIDs in
                self?.customization.pinnedExtensionsDidChange(pinnedIDs)
                self?.applyToolbarArrangement(pinnedIDs: pinnedIDs)
            }
            .store(in: &cancellables)
    }

    /// Draws the stored arrangement reconciled with this window's pins (see
    /// `ToolbarCustomizationController.drawnArrangement`). An extension placed
    /// while its pin is in flight stays drawn meanwhile, and one dragged out
    /// stays out while its unpin is in flight.
    private func applyToolbarArrangement(pinnedIDs: [String]) {
        let drawn = customization.drawnArrangement(pinnedIDs: pinnedIDs)
        let dragged = customization.draggedPayload
        if state.draggedPayload != dragged {
            state.draggedPayload = dragged
        }
        if state.arrangement != drawn {
            state.arrangement = drawn
            updateWindowCenter()
        }
    }

    /// Redraws right after Customize Toolbar or a direct extension reorder
    /// changed the stored arrangement, without waiting for the defaults
    /// notification.
    private func applyStoredToolbarArrangement() {
        applyToolbarArrangement(
            pinnedIDs: Self.pinnedExtensionIDs(owningBrowserState?.extensionManager.pinedExtensions ?? [])
        )
    }

    /// Chromium's pinned order, as the header's extensions model sorts it.
    private static func pinnedExtensionIDs(_ extensions: [Extension]) -> [String] {
        extensions.sorted { lhs, rhs in
            if lhs.pinnedIndex == rhs.pinnedIndex {
                return lhs.name < rhs.name
            }
            return lhs.pinnedIndex < rhs.pinnedIndex
        }.map(\.id)
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

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.state.showAddressBar = navigationAtTop
            self.state.showNavigationButtons = navigationAtTop && !isInPlaceholder
            self.state.showChatButton = navigationAtTop && !overviewActive && !isIncognito && aiChatEnabled && phiAIEnabled && !isInPlaceholder
            self.state.showFeedbackButton = navigationAtTop && !isInPlaceholder && !isGuest
            self.state.allowsWindowDrag = layoutMode == .balanced
            self.state.showDownloadButton = navigationAtTop && !isInPlaceholder
            self.state.showMemoryButton = navigationAtTop && phiAIEnabled && !isIncognito && !isInPlaceholder
            self.state.sidebarKeepsBottomBarItems = WebContentHeaderState.sidebarKeepsBottomBarItems(
                layoutMode: layoutMode,
                sidebarCollapsed: isCollapsed
            )
            self.state.showSidebarButton = !traditionalLayout && navigationAtTop && isCollapsed
            self.state.isIncognito = isIncognito
            self.state.isInPlaceholderMode = isInPlaceholder
            self.state.isPhiAIAvailable = phiAIEnabled && !isIncognito
            self.state.isGuest = isGuest
            // Performance and the empty-window placeholder have no toolbar to customize.
            if !navigationAtTop || isInPlaceholder {
                self.endCustomizingToolbar()
            }
        }
    }

    // MARK: - Context Menu

    /// What a right-click on the toolbar opens.
    enum ContextMenuChoice: Equatable {
        /// The Site Menu, at the pointer. It ends with Customize Toolbar….
        case siteMenu
        /// A menu with only Customize Toolbar….
        case customizeToolbar
    }

    /// A right-click on the address bar opens the Site Menu; anywhere else
    /// it offers Customize Toolbar, unless the address bar is removed: then
    /// the whole toolbar opens the Site Menu, which stays reachable that way.
    static func contextMenuChoice(showsAddressBar: Bool, isOverAddressBar: Bool) -> ContextMenuChoice {
        !showsAddressBar || isOverAddressBar ? .siteMenu : .customizeToolbar
    }

    /// Opens `contextMenuChoice`'s menu at the pointer. Performance's header
    /// only carries extensions and the empty-window placeholder cannot be
    /// customized, so neither offers a menu.
    private func showContextMenu(for event: NSEvent) -> Bool {
        guard state.showAddressBar, !state.isInPlaceholderMode else { return false }
        // While customizing, only the buttons' own menus (Always / On Hover)
        // open; the sheet's Done and Escape end it.
        if state.isCustomizing { return true }
        let browserState = owningBrowserState
        let onCustomize: () -> Void = { [weak self] in self?.beginCustomizingToolbar() }
        let showsAddressBar = state.arrangement.showsAddressBar
        let addressBar = showsAddressBar ? resolvedAddressBarAnchorView : nil
        let isOverAddressBar = addressBar.map {
            $0.window === window && $0.bounds.contains($0.convert(event.locationInWindow, from: nil))
        } ?? false
        switch Self.contextMenuChoice(showsAddressBar: showsAddressBar, isOverAddressBar: isOverAddressBar) {
        case .siteMenu:
            WebContentAddressBarMenuPresenter.present(
                browserState: browserState,
                currentTab: currentTab,
                anchorView: addressBar ?? centeredLocationBarAnchor,
                contextMenuEvent: event,
                showsSiteMemoriesEntry: WebContentAddressBarMenuPresenter.showsSiteMemoriesEntry(
                    arrangement: state.arrangement,
                    browserState: browserState,
                    currentTab: currentTab
                ),
                onCustomize: onCustomize
            ) { _ in }
        case .customizeToolbar:
            effectiveAppearance.performAsCurrentDrawingAppearance {
                NSMenu.popUpContextMenu(ToolbarCustomizationMenu.toolbarMenu(onCustomize: onCustomize), with: event, for: self)
            }
        }
        return true
    }

    // MARK: - Customize Toolbar

    /// The single entry point of every Customize Toolbar menu item: turns
    /// customizing on and opens the sheet under this header.
    func beginCustomizingToolbar() {
        guard !state.isCustomizing, state.showAddressBar, !state.isInPlaceholderMode,
              window != nil, !isHiddenOrHasHiddenAncestor else { return }
        state.isCustomizing = true
        // The zones take drops on themselves; the header takes the default
        // set and a removed address bar anywhere else.
        registerForDraggedTypes([ToolbarDragPayload.pasteboardType])
        let sheet = makeCustomizationSheet()
        customizationSheet = sheet
        // What changes the sheet's height: which buttons and extensions it lists.
        let availability = state.$isPhiAIAvailable.combineLatest(state.$isGuest).map { _ in () }
        let extensions = owningBrowserState?.extensionManager.$extensions.map { _ in () }.eraseToAnyPublisher()
            ?? Empty().eraseToAnyPublisher()
        sheet.present(under: self, contentDidChange: availability.merge(with: extensions).eraseToAnyPublisher())
        // Escape in the toolbar's window or in the sheet, whichever is key,
        // unless it is meant for the text being edited there.
        customizingEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak sheetWindow = sheet.window] event in
            guard let self, event.keyCode == Self.escapeKeyCode, let eventWindow = event.window,
                  eventWindow === self.window || eventWindow === sheetWindow,
                  Self.escapeEndsCustomizing(firstResponder: eventWindow.firstResponder) else { return event }
            self.endCustomizingToolbar()
            return nil
        }
    }

    /// Ends customizing and closes the sheet, whichever ends first: Done,
    /// Escape, or this header leaving its window or being hidden.
    func endCustomizingToolbar() {
        if let customizingEscapeMonitor {
            NSEvent.removeMonitor(customizingEscapeMonitor)
            self.customizingEscapeMonitor = nil
        }
        customizationSheet?.close()
        customizationSheet = nil
        guard state.isCustomizing else { return }
        unregisterDraggedTypes()
        state.isCustomizing = false
    }

    // MARK: - Default set and address bar drop

    /// A drag over the toolbar outside every zone: the default set, a
    /// removed address bar and the bar being dragged from this toolbar are
    /// taken (`ToolbarCustomizationController.isAcceptedOverToolbar`), an
    /// item is not.
    private func wholeToolbarDragOperation(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard state.isCustomizing,
              let payload = ToolbarDragPayload(pasteboard: sender.draggingPasteboard),
              ToolbarCustomizationController.isAcceptedOverToolbar(
                payload,
                showsAddressBar: state.arrangement.showsAddressBar,
                isDraggedFromToolbar: customization.draggedPayload == payload
              ) else { return [] }
        return .move
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        wholeToolbarDragOperation(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        wholeToolbarDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard state.isCustomizing, let payload = ToolbarDragPayload(pasteboard: sender.draggingPasteboard) else { return false }
        return customization.dropOverToolbar(payload)
    }

    private func makeCustomizationSheet() -> ToolbarCustomizationSheet {
        ToolbarCustomizationSheet(content: ToolbarCustomizationSheetView(
            state: state,
            extensionManager: owningBrowserState?.extensionManager,
            customization: customization,
            onDone: { [weak self] in self?.endCustomizingToolbar() }
        )
        .phiThemeObserver(themeObserver))
    }

    private static let escapeKeyCode: UInt16 = 53

    /// Escape ends customizing unless text is being edited (the omnibox, the
    /// find bar), whose Escape closes it first. A popover or menu that is up
    /// gets its Escape before this window does.
    static func escapeEndsCustomizing(firstResponder: NSResponder?) -> Bool {
        // A text view, or the field editor of a text field being edited.
        !(firstResponder is NSText)
    }

    private func makeCustomizationController() -> ToolbarCustomizationController {
        let model: (String) -> Extension? = { [weak self] id in
            self?.owningBrowserState?.extensionManager.extensions.first { $0.id == id }
        }
        let controller = ToolbarCustomizationController(extensions: .init(
            isPinned: { model($0)?.isPinned ?? false },
            pin: { [weak self] id in
                guard let ext = model(id), !ext.isPinned else { return }
                self?.owningBrowserState?.extensionManager.togglePin(ext)
            },
            unpin: { [weak self] id in
                guard let ext = model(id), ext.isPinned else { return }
                self?.owningBrowserState?.extensionManager.togglePin(ext)
            },
            isForcePinned: { model($0)?.isForcePinned ?? false }
        ))
        controller.onChange = { [weak self] in self?.applyStoredToolbarArrangement() }
        controller.isCustomizing = { [weak self] in self?.state.isCustomizing ?? false }
        return controller
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

/// The location bar's anchor while the address bar is removed. It draws
/// nothing and never takes clicks.
private final class CenteredLocationBarAnchorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Hands right-clicks and Control-clicks on the toolbar to
/// `WebContentHeader`, which offers a menu for them. Controls with a menu of
/// their own (extension icons) take their right-clicks before they get here.
private final class WebContentHeaderHostingView: ZeroSafeAreaHostingView<AnyView> {
    var onRightMouseDown: ((NSEvent) -> Bool)?

    override func rightMouseDown(with event: NSEvent) {
        if onRightMouseDown?(event) == true { return }
        super.rightMouseDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), onRightMouseDown?(event) == true { return }
        super.mouseDown(with: event)
    }
}

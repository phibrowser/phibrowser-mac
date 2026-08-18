// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Combine
import SnapKit

/// Small top-right badge on a pinned cell showing the favicon of the Peek
/// attached to that tab; hovering dims the favicon behind a minus glyph and
/// clicking closes the peek. Handles its own mouse events (without calling
/// super on mouseDown) so the cell's HoverableView click action never fires
/// for badge clicks.
private final class PinnedPeekBadgeView: NSView {
    var onClose: (() -> Void)?
    var faviconImage: NSImage? {
        didSet { faviconView.image = faviconImage }
    }

    private let faviconView = NSImageView()
    private let minusView = NSImageView()
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovered = false {
        didSet { updateHoverState() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        updateBackground()

        faviconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(faviconView)
        faviconView.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(3)
        }

        minusView.image = NSImage(systemSymbolName: "minus", accessibilityDescription: nil)
        minusView.symbolConfiguration = .init(pointSize: 12, weight: .bold)
        minusView.contentTintColor = .labelColor
        minusView.isHidden = true
        addSubview(minusView)
        minusView.snp.makeConstraints { make in
            make.center.equalToSuperview()
        }

        toolTip = NSLocalizedString(
            "peek.pinnedTab.closePeekTooltip",
            value: "Close Peek",
            comment: "Pinned tab cell - Tooltip of the corner badge that closes the floating page preview opened from this pinned tab"
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovered = false
    }

    override func mouseDown(with event: NSEvent) {
        // Swallow deliberately: forwarding to super would walk the responder
        // chain into the cell's HoverableView and activate the pinned tab.
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) {
            onClose?()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }

    private func updateHoverState() {
        faviconView.alphaValue = isHovered ? 0.25 : 1
        minusView.isHidden = !isHovered
    }

    private func updateBackground() {
        // Layers don't track appearance changes; resolve the dynamic color
        // under the current effective appearance before assigning.
        effectiveAppearance.performAsCurrentDrawingAppearance { [self] in
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }
}

class PinnedTabItem: NSCollectionViewItem, NSMenuDelegate {
    static var reuseIdentifier: NSUserInterfaceItemIdentifier { .init(rawValue: "\(Self.self)") }
    /// Identifier stamped on every visible sidebar pinned-grid item (solo
    /// tab or pinned split — see also `PinnedSplitItem`).
    static let accessibilityIdentifier = "sidebarPinnedTab"
    private var iconImageView: NSImageView!
    private var backgroundView: HoverableView!
    private var peekBadge: PinnedPeekBadgeView!
    private var tab: Tab?
    private weak var browserState: BrowserState?
    private var cancellables = Set<AnyCancellable>()
    /// Reset whenever the attached peek changes; feeds the badge favicon.
    private var peekFaviconCancellables = Set<AnyCancellable>()
    private var faviconLoadHandle: ProfileScopedFaviconLoadHandle?
    private weak var themeProvider: ThemeStateProvider?
    private var themeSubscription: AnyObject?
    private let tabPreviewRegistration = TabPreviewRegistration()
    private var showsTabPreview = false

    var itemClicked: ((Tab?, NSEvent.ModifierFlags) -> Void)?
    var itemDoubleClicked: ((Tab?, NSEvent.ModifierFlags) -> Void)?
    // Shared context menu bound to the entire pinned item.
    private lazy var contextMenu: NSMenu = {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }()

    override func loadView() {
        view = NSView()
        setupUI()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancellables.removeAll()
        peekFaviconCancellables.removeAll()
        themeSubscription = nil
        themeProvider = nil
        faviconLoadHandle?.cancel()
        faviconLoadHandle = nil
        iconImageView.image = nil
        tabPreviewRegistration.invalidate()
        peekBadge.isHidden = true
        peekBadge.faviconImage = nil
        tab = nil
        browserState = nil
    }

    private func setupUI() {
        view.wantsLayer = true

        // Interactive background view.
        backgroundView = HoverableView()
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerCurve = .continuous
        backgroundView.layer?.cornerRadius = 8
        backgroundView.backgroundColor  = .sidebarTabHovered
        backgroundView.hoveredColor = .sidebarTabHoveredColorEmphasized
        backgroundView.selectedColor = .sidebarTabSelected
        backgroundView.enableClickAnimation = true
        backgroundView.clickActionWithModifierFlags = { [weak self] modifierFlags in
            self?.tabPreviewRegistration.cancelForInteraction()
            self?.itemClicked?(self?.tab, modifierFlags)
        }
        backgroundView.doubleClickAction = { [weak self] event in
            self?.tabPreviewRegistration.cancelForInteraction()
            self?.itemDoubleClicked?(self?.tab, event.modifierFlags)
        }
        backgroundView.hoverStateChanged = { [weak self] isHovered in
            self?.tabPreviewRegistration.setHovering(isHovered)
        }
        tabPreviewRegistration.onEligibilityChanged = { [weak self] isEligible in
            self?.showsTabPreview = isEligible
            self?.updateToolTip()
        }
        
        // Favicon image view.
        iconImageView = NSImageView()
        iconImageView.imageScaling = .scaleProportionallyUpOrDown
        iconImageView.wantsLayer = true
        iconImageView.layer?.cornerCurve = .continuous
        iconImageView.layer?.cornerRadius = 4
        iconImageView.layer?.cornerCurve = .continuous
        iconImageView.layer?.masksToBounds = true

        view.addSubview(backgroundView)
        backgroundView.addSubview(iconImageView)

        // Layout.
        backgroundView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        iconImageView.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.size.equalTo(CGSize(width: 18, height: 18))
        }

        // Peek badge: top-right corner, above the favicon.
        peekBadge = PinnedPeekBadgeView()
        peekBadge.isHidden = true
        peekBadge.onClose = { [weak self] in
            guard let self, let tab = self.tab else { return }
            self.browserState?.closePeek(forOpener: tab.guid)
        }
        backgroundView.addSubview(peekBadge)
        peekBadge.snp.makeConstraints { make in
            make.top.trailing.equalToSuperview().inset(1)
            make.size.equalTo(CGSize(width: 25, height: 25))
        }

        // Route right-click handling through the full item view.
        view.menu = contextMenu
    }

    func configure(
        with tab: Tab,
        browserState: BrowserState?,
        themeProvider: ThemeStateProvider
    ) {
        self.tab = tab
        self.themeProvider = themeProvider
        self.browserState = browserState
        cancellables.removeAll()
        peekFaviconCancellables.removeAll()
        themeSubscription = nil
        faviconLoadHandle?.cancel()
        faviconLoadHandle = nil

        setupFavicon()
        if let browserState {
            tabPreviewRegistration.configure(
                anchorView: view,
                target: .tab(tab),
                browserState: browserState,
                placement: .belowAttached
            )
        } else {
            tabPreviewRegistration.invalidate()
        }
        updateToolTip()

        // Expose to UI testing — the pinned grid is a collection view with no
        // stable query surface for the test reset to find and unpin items.
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        view.setAccessibilityIdentifier(PinnedTabItem.accessibilityIdentifier)
        view.setAccessibilityLabel(tab.title)

        // Selection state is driven by the view controller.
        self.isSelected = tab.isActive
        if let menu = view.menu {
            tab.makeContextMenu(on: menu)
        }
        
        tab.$liveFaviconData
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.setupFavicon()
            }
            .store(in: &cancellables)

        tab.$cachedFaviconData
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.setupFavicon()
            }
            .store(in: &cancellables)

        tab.$url
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.setupFavicon()
            }
            .store(in: &cancellables)
        
        tab.$title
            .combineLatest(tab.$url)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] title, url in
                guard let self else { return }
                self.updateToolTip()
            }
            .store(in: &cancellables)

        tab.$isActive
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isActive in
                self?.isSelected = isActive
            }
            .store(in: &cancellables)

        if let browserState {
            browserState.peekState.$peeksByOpener
                .receive(on: DispatchQueue.main)
                .sink { [weak self] peeksByOpener in
                    self?.updatePeekBadge(peeksByOpener: peeksByOpener)
                }
                .store(in: &cancellables)
        } else {
            updatePeekBadge(peeksByOpener: [:])
        }

        rebindThemeSubscription()
    }

    /// Shows the corner badge when a live Peek belongs to this pinned
    /// tab's bound live tab (also while the peek is hidden behind another
    /// focused tab — the badge is what tells the user a peek is attached).
    private func updatePeekBadge(peeksByOpener: [Int: Tab]) {
        peekFaviconCancellables.removeAll()
        guard let tab, tab.isOpenned,
              let peekTab = peeksByOpener[tab.guid] else {
            peekBadge.isHidden = true
            peekBadge.faviconImage = nil
            return
        }
        peekBadge.isHidden = false
        peekTab.$liveFaviconData
            .combineLatest(peekTab.$cachedFaviconData)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] liveData, cachedData in
                if let data = liveData ?? cachedData, let image = NSImage(data: data) {
                    self?.peekBadge.faviconImage = image
                } else {
                    self?.peekBadge.faviconImage = NSImage(systemSymbolName: "globe",
                                                           accessibilityDescription: nil)
                }
            }
            .store(in: &peekFaviconCancellables)
    }

    
    override var isSelected: Bool {
        didSet {
            updateSelectedState()
        }
    }

    private func rebindThemeSubscription() {
        themeSubscription = nil
        let provider = themeProvider ?? ThemeManager.shared
        themeSubscription = provider.subscribe { [weak self] _, _ in
            self?.updateSelectedState()
        }
    }

    private func updateSelectedState() {
        if isSelected {
            backgroundView.isSelected = true
            backgroundView.layer?.borderWidth = 2
            let provider = themeProvider ?? ThemeManager.shared
            backgroundView.layer?.borderColor = ThemedColor.themeColor
                .resolve(theme: provider.currentTheme, appearance: provider.currentAppearance)
                .cgColor
        } else {
            backgroundView.isSelected = false
            backgroundView.layer?.borderWidth = 0
            backgroundView.layer?.borderColor = NSColor.clear.cgColor
        }
    }

    private func setupFavicon() {
        guard let tab = tab else { return }
        faviconLoadHandle?.cancel()
        faviconLoadHandle = nil
        self.isSelected = tab.isActive

        if let liveFaviconData = tab.liveFaviconData,
           let image = NSImage(data: liveFaviconData) {
            iconImageView.image = image
            return
        }

        let pageURLString = tab.isOpenned ? (tab.url ?? tab.pinnedUrl) : (tab.pinnedUrl ?? tab.url)
        let request = ProfileScopedFaviconRequest(
            profileId: tab.profileId,
            pageURLString: pageURLString,
            snapshotData: tab.cachedFaviconData
        )

        faviconLoadHandle = ProfileScopedFaviconRepository.shared.loadFavicon(for: request) { [weak self, weak tab] result in
            self?.iconImageView.image = result.image
            if result.source == .chromium, let data = result.data {
                tab?.updateProfileScopedFaviconData(data)
            }
        }
    }

    private func updateToolTip() {
        guard let tab, !showsTabPreview else {
            view.toolTip = nil
            return
        }
        view.toolTip = "\(tab.title)\n\(tab.url ?? "")"
    }

    func cancelTabPreviewForInteraction() {
        tabPreviewRegistration.cancelForInteraction()
    }

    private func setDefaultIcon() {
        if let defaultIcon = NSImage(systemSymbolName: "globe", accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
            iconImageView.image = defaultIcon.withSymbolConfiguration(config)
        }
    }
    
    func menuNeedsUpdate(_ menu: NSMenu) {
        tabPreviewRegistration.cancelForInteraction()
        tab?.makeContextMenu(on: menu)
    }
}

// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Combine
import SnapKit

class PinnedTabItem: NSCollectionViewItem, NSMenuDelegate {
    static var reuseIdentifier: NSUserInterfaceItemIdentifier { .init(rawValue: "\(Self.self)") }
    /// Identifier stamped on every visible sidebar pinned-grid item (solo
    /// tab or pinned split — see also `PinnedSplitItem`).
    static let accessibilityIdentifier = "sidebarPinnedTab"
    private var iconImageView: NSImageView!
    private var backgroundView: HoverableView!
    private var tab: Tab?
    private var cancellables = Set<AnyCancellable>()
    private var faviconLoadHandle: ProfileScopedFaviconLoadHandle?
    private weak var themeProvider: ThemeStateProvider?
    private var themeSubscription: AnyObject?

    var itemClicked: ((Tab?) -> Void)?
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
        themeSubscription = nil
        themeProvider = nil
        faviconLoadHandle?.cancel()
        faviconLoadHandle = nil
        iconImageView.image = nil
        tab = nil
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
        backgroundView.clickAction = { [weak self] in
            self?.itemClicked?(self?.tab)
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
        
        // Route right-click handling through the full item view.
        view.menu = contextMenu
    }

    func configure(with tab: Tab, themeProvider: ThemeStateProvider) {
        self.tab = tab
        self.themeProvider = themeProvider
        cancellables.removeAll()
        themeSubscription = nil
        faviconLoadHandle?.cancel()
        faviconLoadHandle = nil

        setupFavicon()
        view.toolTip = "\(tab.title)\n\(tab.url ?? "")"

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
                self.view.toolTip = "\(title)\n\(url ?? "")"
            }
            .store(in: &cancellables)

        tab.$isActive
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isActive in
                self?.isSelected = isActive
            }
            .store(in: &cancellables)

        rebindThemeSubscription()
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
                tab?.updateCachedFaviconData(data)
            }
        }
    }

    private func setDefaultIcon() {
        if let defaultIcon = NSImage(systemSymbolName: "globe", accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
            iconImageView.image = defaultIcon.withSymbolConfiguration(config)
        }
    }
    
    func menuNeedsUpdate(_ menu: NSMenu) {
        tab?.makeContextMenu(on: menu)
    }
}

// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Combine
import SnapKit

/// A single pinned-grid cell that represents a pinned split — both panes
/// rendered as two favicons side-by-side inside one rounded background, so
/// the pair reads as one item. The cell shares the dimensions and chrome of
/// `PinnedTabItem`; click and right-click route through the first pane (the
/// left/top tab), which carries the split-aware context menu.
class PinnedSplitItem: NSCollectionViewItem, NSMenuDelegate {
    static var reuseIdentifier: NSUserInterfaceItemIdentifier { .init(rawValue: "\(Self.self)") }

    private var leftIconView: NSImageView!
    private var rightIconView: NSImageView!
    private var backgroundView: HoverableView!
    private var leftTab: Tab?
    private var rightTab: Tab?
    private var cancellables = Set<AnyCancellable>()
    private var leftFaviconHandle: ProfileScopedFaviconLoadHandle?
    private var rightFaviconHandle: ProfileScopedFaviconLoadHandle?
    private weak var themeProvider: ThemeStateProvider?
    private var themeSubscription: AnyObject?

    /// Tab whose action runs when the cell is clicked (the pane the user
    /// most recently interacted with, or the left pane as fallback).
    var itemClicked: ((Tab?) -> Void)?

    private lazy var contextMenu: NSMenu = {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }()

    override func loadView() {
        view = NSView()
        setupUI()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancellables.removeAll()
        themeSubscription = nil
        themeProvider = nil
        leftFaviconHandle?.cancel()
        leftFaviconHandle = nil
        rightFaviconHandle?.cancel()
        rightFaviconHandle = nil
        leftIconView.image = nil
        rightIconView.image = nil
        leftTab = nil
        rightTab = nil
    }

    private func setupUI() {
        view.wantsLayer = true

        backgroundView = HoverableView()
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerCurve = .continuous
        backgroundView.layer?.cornerRadius = 8
        backgroundView.backgroundColor = .sidebarTabHovered
        backgroundView.hoveredColor = .sidebarTabHoveredColorEmphasized
        backgroundView.selectedColor = .sidebarTabSelected
        backgroundView.enableClickAnimation = true
        backgroundView.clickAction = { [weak self] in
            self?.itemClicked?(self?.preferredClickTab())
        }

        leftIconView = makeIconView()
        rightIconView = makeIconView()

        view.addSubview(backgroundView)
        backgroundView.addSubview(leftIconView)
        backgroundView.addSubview(rightIconView)

        backgroundView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        // Two 16x16 favicons centered as a pair, separated by a small gap.
        // 16 + 4 + 16 = 36pt total — fits inside the 54pt-wide background
        // without crowding the rounded corners.
        leftIconView.snp.makeConstraints { make in
            make.centerY.equalToSuperview()
            make.centerX.equalToSuperview().offset(-10)
            make.size.equalTo(CGSize(width: 16, height: 16))
        }
        rightIconView.snp.makeConstraints { make in
            make.centerY.equalToSuperview()
            make.centerX.equalToSuperview().offset(10)
            make.size.equalTo(CGSize(width: 16, height: 16))
        }

        view.menu = contextMenu
    }

    private func makeIconView() -> NSImageView {
        let iv = NSImageView()
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.wantsLayer = true
        iv.layer?.cornerCurve = .continuous
        iv.layer?.cornerRadius = 3
        iv.layer?.masksToBounds = true
        return iv
    }

    func configure(leftTab: Tab, rightTab: Tab, themeProvider: ThemeStateProvider) {
        self.leftTab = leftTab
        self.rightTab = rightTab
        self.themeProvider = themeProvider
        cancellables.removeAll()
        themeSubscription = nil
        leftFaviconHandle?.cancel()
        leftFaviconHandle = nil
        rightFaviconHandle?.cancel()
        rightFaviconHandle = nil

        refreshFavicon(for: leftTab)
        refreshFavicon(for: rightTab)
        view.toolTip = "\(leftTab.title) | \(rightTab.title)"

        // Expose to UI testing, sharing the pinned-grid identifier with
        // `PinnedTabItem` so the test reset can find and unpin every item.
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        view.setAccessibilityIdentifier(PinnedTabItem.accessibilityIdentifier)
        view.setAccessibilityLabel("\(leftTab.title) | \(rightTab.title)")

        self.isSelected = leftTab.isActive || rightTab.isActive

        // Drive the context menu off the left pane so the user gets the
        // split-aware items (Unpin Split, Remove from Split, etc.).
        if let menu = view.menu {
            leftTab.makeContextMenu(on: menu)
        }

        subscribeFaviconUpdates(for: leftTab)
        subscribeFaviconUpdates(for: rightTab)

        Publishers.CombineLatest(leftTab.$isActive, rightTab.$isActive)
            .removeDuplicates { $0 == $1 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] leftActive, rightActive in
                self?.isSelected = leftActive || rightActive
            }
            .store(in: &cancellables)

        rebindThemeSubscription()
    }

    override var isSelected: Bool {
        didSet { updateSelectedState() }
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

    /// Choose which pane a click should focus: the one currently active in
    /// the split (Chromium keeps focus on whichever was last clicked),
    /// otherwise the left pane.
    private func preferredClickTab() -> Tab? {
        if let rightTab, rightTab.isActive { return rightTab }
        return leftTab
    }

    private func subscribeFaviconUpdates(for tab: Tab) {
        tab.$liveFaviconData
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshFavicon(for: tab) }
            .store(in: &cancellables)

        tab.$cachedFaviconData
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshFavicon(for: tab) }
            .store(in: &cancellables)

        tab.$url
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshFavicon(for: tab) }
            .store(in: &cancellables)

        Publishers.CombineLatest(tab.$title, tab.$url)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                guard let self, let l = self.leftTab, let r = self.rightTab else { return }
                self.view.toolTip = "\(l.title) | \(r.title)"
            }
            .store(in: &cancellables)
    }

    /// Dispatch a favicon refresh to whichever side `tab` occupies in this
    /// cell. No-op if the cell has been recycled away from `tab`.
    private func refreshFavicon(for tab: Tab) {
        if tab === leftTab {
            setupFavicon(for: tab, into: leftIconView, handle: &leftFaviconHandle)
        } else if tab === rightTab {
            setupFavicon(for: tab, into: rightIconView, handle: &rightFaviconHandle)
        }
    }

    private func setupFavicon(for tab: Tab,
                              into imageView: NSImageView,
                              handle: inout ProfileScopedFaviconLoadHandle?) {
        handle?.cancel()
        handle = nil

        if let liveFaviconData = tab.liveFaviconData,
           let image = NSImage(data: liveFaviconData) {
            imageView.image = image
            return
        }

        let pageURLString = tab.isOpenned ? (tab.url ?? tab.pinnedUrl) : (tab.pinnedUrl ?? tab.url)
        let request = ProfileScopedFaviconRequest(
            profileId: tab.profileId,
            pageURLString: pageURLString,
            snapshotData: tab.cachedFaviconData
        )

        handle = ProfileScopedFaviconRepository.shared.loadFavicon(for: request) { [weak imageView, weak tab] result in
            imageView?.image = result.image
            if result.source == .chromium, let data = result.data {
                tab?.updateCachedFaviconData(data)
            }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        leftTab?.makeContextMenu(on: menu)
    }
}

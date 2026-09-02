// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Combine
import SnapKit
import SwiftUI

/// A single pinned-grid cell that represents a pinned split — both panes
/// rendered as two favicons side-by-side inside one rounded background, so
/// the pair reads as one item. The cell shares the dimensions and chrome of
/// `PinnedTabItem`; click and right-click route through the first pane (the
/// left/top tab), which carries the split-aware context menu.
class PinnedSplitItem: NSCollectionViewItem, NSMenuDelegate {
    static var reuseIdentifier: NSUserInterfaceItemIdentifier { .init(rawValue: "\(Self.self)") }
    private static let faviconSize: CGFloat = 16
    private static let faviconCornerRadius: CGFloat = 3
    private static let defaultFaviconCenterOffset: CGFloat = 10

    private var leftIconView: NSImageView!
    private var rightIconView: NSImageView!
    private var backgroundView: HoverableView!
    private var stateBorderView: PinnedTabStateBorderView!
    private var statusBadgeHost: TabDecorativeHostingView!
    private let leftStatusModel = TabStatusModel()
    private let rightStatusModel = TabStatusModel()
    private var leftTab: Tab?
    private var rightTab: Tab?
    private var cancellables = Set<AnyCancellable>()
    private var leftFaviconHandle: ProfileScopedFaviconLoadHandle?
    private var rightFaviconHandle: ProfileScopedFaviconLoadHandle?
    private weak var themeProvider: ThemeStateProvider?
    private var themeSubscription: AnyObject?
    private let splitTabPreviewRegistration = SplitTabPreviewRegistration()
    private var showsSplitTabPreview = false

    /// Tab whose action runs when the cell is clicked (the pane the user
    /// most recently interacted with, or the left pane as fallback).
    var itemClicked: ((Tab?) -> Void)?
    var itemDoubleClicked: ((Tab?, NSEvent.ModifierFlags) -> Void)?

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
        leftIconView.alphaValue = 1
        rightIconView.alphaValue = 1
        leftStatusModel.prepareForReuse()
        rightStatusModel.prepareForReuse()
        stateBorderView.update(style: .none, color: .clear)
        splitTabPreviewRegistration.invalidate()
        leftTab = nil
        rightTab = nil
    }

    private func setupUI() {
        view.wantsLayer = true
        view.layer?.masksToBounds = false

        backgroundView = HoverableView()
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerCurve = .continuous
        backgroundView.layer?.cornerRadius = 8
        backgroundView.backgroundColor = .sidebarTabHovered
        backgroundView.hoveredColor = .sidebarTabHoveredColorEmphasized
        backgroundView.selectedColor = .sidebarTabSelected
        backgroundView.enableClickAnimation = true
        backgroundView.clickAction = { [weak self] in
            self?.splitTabPreviewRegistration.cancelForInteraction()
            self?.itemClicked?(self?.preferredClickTab())
        }
        backgroundView.doubleClickAction = { [weak self] event in
            guard let self else { return }
            self.splitTabPreviewRegistration.cancelForInteraction()
            let point = self.backgroundView.convert(event.locationInWindow, from: nil)
            self.itemDoubleClicked?(self.tab(at: point), event.modifierFlags)
        }
        backgroundView.hoverStateChanged = { [weak self] isHovered in
            self?.splitTabPreviewRegistration.setHovering(isHovered)
        }
        splitTabPreviewRegistration.onEligibilityChanged = { [weak self] isEligible in
            self?.showsSplitTabPreview = isEligible
            self?.updateToolTip()
        }

        leftIconView = makeIconView()
        rightIconView = makeIconView()

        view.addSubview(backgroundView)
        backgroundView.addSubview(leftIconView)
        backgroundView.addSubview(rightIconView)

        stateBorderView = PinnedTabStateBorderView()
        backgroundView.addSubview(stateBorderView)

        backgroundView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        leftIconView.snp.makeConstraints { make in
            make.centerY.equalToSuperview()
            make.centerX.equalToSuperview().offset(-Self.defaultFaviconCenterOffset)
            make.size.equalTo(CGSize(
                width: Self.faviconSize,
                height: Self.faviconSize
            ))
        }
        rightIconView.snp.makeConstraints { make in
            make.centerY.equalToSuperview()
            make.centerX.equalToSuperview().offset(Self.defaultFaviconCenterOffset)
            make.size.equalTo(CGSize(
                width: Self.faviconSize,
                height: Self.faviconSize
            ))
        }

        stateBorderView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        statusBadgeHost = TabDecorativeHostingView(
            rootView: MergedTabCornerBadgeView(
                primaryModel: leftStatusModel,
                secondaryModel: rightStatusModel
            )
        )
        view.addSubview(statusBadgeHost)
        statusBadgeHost.snp.makeConstraints { make in
            make.top.trailing.equalTo(backgroundView)
                .inset(-TabCornerBadgeMetrics.overhang)
            make.size.equalTo(CGSize(
                width: TabCornerBadgeMetrics.visualSize,
                height: TabCornerBadgeMetrics.visualSize
            ))
        }

        view.menu = contextMenu
    }

    private func makeIconView() -> NSImageView {
        let iv = NSImageView()
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.wantsLayer = true
        iv.layer?.cornerCurve = .continuous
        iv.layer?.cornerRadius = Self.faviconCornerRadius
        iv.layer?.masksToBounds = true
        return iv
    }

    func configure(
        leftTab: Tab,
        rightTab: Tab,
        browserState: BrowserState? = nil,
        themeProvider: ThemeStateProvider
    ) {
        self.leftTab = leftTab
        self.rightTab = rightTab
        self.themeProvider = themeProvider
        cancellables.removeAll()
        themeSubscription = nil
        leftFaviconHandle?.cancel()
        leftFaviconHandle = nil
        rightFaviconHandle?.cancel()
        rightFaviconHandle = nil
        leftStatusModel.configure(with: leftTab, in: browserState)
        rightStatusModel.configure(with: rightTab, in: browserState)

        Publishers.CombineLatest(
            Publishers.CombineLatest3(
                leftTab.$hasWebContent,
                leftTab.$isDiscarded,
                leftTab.$isUnloaded
            ),
            Publishers.CombineLatest3(
                rightTab.$hasWebContent,
                rightTab.$isDiscarded,
                rightTab.$isUnloaded
            )
        )
        .map { left, right in
            TabStateBorderStyle.resolve(
                isOpened: left.0 || right.0,
                isDiscarded: left.1 || right.1,
                isUnloaded: left.2 || right.2
            )
        }
        .removeDuplicates()
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            self?.updateSelectedState()
        }
        .store(in: &cancellables)

        refreshFavicon(for: leftTab)
        refreshFavicon(for: rightTab)
        if let browserState,
           let target = SplitTabPreviewTarget.make(representing: leftTab, in: browserState) {
            splitTabPreviewRegistration.configure(
                anchorView: view,
                target: target,
                browserState: browserState,
                placement: .belowAttached
            )
        } else {
            splitTabPreviewRegistration.invalidate()
        }
        updateToolTip()

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
        backgroundView.isSelected = isSelected
        backgroundView.layer?.borderWidth = 0
        backgroundView.layer?.borderColor = NSColor.clear.cgColor

        let borderStyle = isSelected ? TabStateBorderStyle.none : TabStateBorderStyle.resolve(
            isOpened: leftTab?.hasWebContent == true || rightTab?.hasWebContent == true,
            isDiscarded: leftTab?.isDiscarded == true || rightTab?.isDiscarded == true,
            isUnloaded: leftTab?.isUnloaded == true || rightTab?.isUnloaded == true
        )
        let provider = themeProvider ?? ThemeManager.shared
        let borderColor = ThemedColor.border.resolve(
            theme: provider.currentTheme,
            appearance: provider.currentAppearance
        )
        stateBorderView.update(style: borderStyle, color: borderColor)
    }

    /// Choose which pane a click should focus: the one currently active in
    /// the split (Chromium keeps focus on whichever was last clicked),
    /// otherwise the left pane.
    private func preferredClickTab() -> Tab? {
        if let rightTab, rightTab.isActive { return rightTab }
        return leftTab
    }

    private func tab(at point: NSPoint) -> Tab? {
        point.x > backgroundView.bounds.midX ? rightTab : leftTab
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
                self?.updateToolTip()
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
                tab?.updateProfileScopedFaviconData(
                    data,
                    sourceURLString: request.pageURLString
                )
            }
        }
    }

    private func updateToolTip() {
        guard let leftTab, let rightTab, !showsSplitTabPreview else {
            view.toolTip = nil
            return
        }
        view.toolTip = "\(leftTab.title) | \(rightTab.title)"
    }

    func cancelTabPreviewForInteraction() {
        splitTabPreviewRegistration.cancelForInteraction()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        splitTabPreviewRegistration.cancelForInteraction()
        leftTab?.makeContextMenu(on: menu)
    }
}

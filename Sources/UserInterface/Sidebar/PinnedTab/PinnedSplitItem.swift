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
    private static let separatedFaviconCenterOffset: CGFloat = 11

    private var leftIconView: TabFaviconImageView!
    private var rightIconView: TabFaviconImageView!
    private var backgroundView: HoverableView!
    private var openIndicatorHost: TabDecorativeHostingView!
    private var leftDiscardedOutlineHost: TabDecorativeHostingView!
    private var rightDiscardedOutlineHost: TabDecorativeHostingView!
    private var statusBadgeHost: TabDecorativeHostingView!
    private var leftIconCenterXConstraint: Constraint?
    private var rightIconCenterXConstraint: Constraint?
    private let leftStatusModel = TabStatusModel()
    private let rightStatusModel = TabStatusModel()
    private var leftTab: Tab?
    private var rightTab: Tab?
    private var cancellables = Set<AnyCancellable>()
    private var leftFaviconHandle: ProfileScopedFaviconLoadHandle?
    private var rightFaviconHandle: ProfileScopedFaviconLoadHandle?
    private let splitTabPreviewRegistration = SplitTabPreviewRegistration()
    private var showsSplitTabPreview = false

    /// Tab whose action runs when the cell is clicked (the pane the user
    /// most recently interacted with, or the left pane as fallback).
    var itemClicked: ((Tab?) -> Void)?
    var itemDoubleClicked: ((Tab?, NSEvent.ModifierFlags) -> Void)?

    /// An embedding surface supplies actions with its own explicit owner.
    var populateContextMenu: ((NSMenu) -> Void)?

    private lazy var contextMenu: NSMenu = {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }()

    override func loadView() {
        view = PinnedGridItemView()
        setupUI()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        populateContextMenu = nil
        cancellables.removeAll()
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
        updateFaviconCenterOffset(separatesDashedOutlines: false)
        openIndicatorHost.isHidden = true
        openIndicatorHost.alphaValue = 1
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
        backgroundView.shouldClickOnMouseDown = { true }
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

        leftIconView = TabFaviconImageView(model: leftStatusModel, cornerRadius: Self.faviconCornerRadius)
        rightIconView = TabFaviconImageView(model: rightStatusModel, cornerRadius: Self.faviconCornerRadius)

        view.addSubview(backgroundView)
        backgroundView.addSubview(leftIconView)
        backgroundView.addSubview(rightIconView)

        openIndicatorHost = TabDecorativeHostingView(rootView: TabOpenIndicatorView())
        openIndicatorHost.isHidden = true
        backgroundView.addSubview(openIndicatorHost)

        leftDiscardedOutlineHost = TabDecorativeHostingView(
            rootView: TabDiscardedFaviconOutline(
                model: leftStatusModel,
                faviconSize: Self.faviconSize,
                faviconCornerRadius: Self.faviconCornerRadius
            )
        )
        rightDiscardedOutlineHost = TabDecorativeHostingView(
            rootView: TabDiscardedFaviconOutline(
                model: rightStatusModel,
                faviconSize: Self.faviconSize,
                faviconCornerRadius: Self.faviconCornerRadius
            )
        )
        backgroundView.addSubview(leftDiscardedOutlineHost)
        backgroundView.addSubview(rightDiscardedOutlineHost)

        backgroundView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        leftIconView.snp.makeConstraints { make in
            make.centerY.equalToSuperview()
            leftIconCenterXConstraint = make.centerX.equalToSuperview()
                .offset(-Self.defaultFaviconCenterOffset).constraint
            make.size.equalTo(CGSize(
                width: Self.faviconSize,
                height: Self.faviconSize
            ))
        }
        rightIconView.snp.makeConstraints { make in
            make.centerY.equalToSuperview()
            rightIconCenterXConstraint = make.centerX.equalToSuperview()
                .offset(Self.defaultFaviconCenterOffset).constraint
            make.size.equalTo(CGSize(
                width: Self.faviconSize,
                height: Self.faviconSize
            ))
        }

        openIndicatorHost.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.top.equalTo(leftIconView.snp.bottom)
                .offset(TabOpenIndicatorMetrics.pinnedSpacing)
            make.size.equalTo(CGSize(
                width: TabOpenIndicatorMetrics.diameter,
                height: TabOpenIndicatorMetrics.diameter
            ))
        }

        leftDiscardedOutlineHost.snp.makeConstraints { make in
            make.center.equalTo(leftIconView)
            make.size.equalTo(CGSize(
                width: TabCornerBadgeMetrics.discardedOutlineSize(
                    for: Self.faviconSize,
                    cornerRadius: Self.faviconCornerRadius
                ),
                height: TabCornerBadgeMetrics.discardedOutlineSize(
                    for: Self.faviconSize,
                    cornerRadius: Self.faviconCornerRadius
                )
            ))
        }
        rightDiscardedOutlineHost.snp.makeConstraints { make in
            make.center.equalTo(rightIconView)
            make.size.equalTo(CGSize(
                width: TabCornerBadgeMetrics.discardedOutlineSize(
                    for: Self.faviconSize,
                    cornerRadius: Self.faviconCornerRadius
                ),
                height: TabCornerBadgeMetrics.discardedOutlineSize(
                    for: Self.faviconSize,
                    cornerRadius: Self.faviconCornerRadius
                )
            ))
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

    func configure(
        leftTab: Tab,
        rightTab: Tab,
        browserState: BrowserState? = nil,
        themeProvider _: ThemeStateProvider
    ) {
        self.leftTab = leftTab
        self.rightTab = rightTab
        cancellables.removeAll()
        leftFaviconHandle?.cancel()
        leftFaviconHandle = nil
        rightFaviconHandle?.cancel()
        rightFaviconHandle = nil
        leftStatusModel.configure(with: leftTab, in: browserState)
        rightStatusModel.configure(with: rightTab, in: browserState)

        Publishers.CombineLatest(leftTab.$hasWebContent, rightTab.$hasWebContent)
        .map { $0 || $1 }
        .removeDuplicates()
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            self?.updateSelectedState()
        }
        .store(in: &cancellables)

        updateFaviconCenterOffset(
            separatesDashedOutlines: bothFaviconsShowDashedOutline
        )

        Publishers.CombineLatest(
            Publishers.CombineLatest4(
                leftStatusModel.$isDiscarded,
                leftStatusModel.$isUnloaded,
                rightStatusModel.$isDiscarded,
                rightStatusModel.$isUnloaded
            ),
            TabFaviconPresentation.dimmingEnabledPublisher
        )
        .map { states, dimmingEnabled in
            dimmingEnabled && (states.0 || states.1) && (states.2 || states.3)
        }
        .removeDuplicates()
        .receive(on: DispatchQueue.main)
        .sink { [weak self] separatesDashedOutlines in
            self?.updateFaviconCenterOffset(
                separatesDashedOutlines: separatesDashedOutlines
            )
        }
        .store(in: &cancellables)

        refreshFavicon(for: leftTab)
        refreshFavicon(for: rightTab)
        updateOpenIndicatorOpacity()
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
            if let populateContextMenu { populateContextMenu(menu) }
            else { leftTab.makeContextMenu(on: menu) }
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

    }

    private var bothFaviconsShowDashedOutline: Bool {
        TabFaviconPresentation.showsDashedOutline(
            isDiscarded: leftStatusModel.isDiscarded,
            isUnloaded: leftStatusModel.isUnloaded
        ) && TabFaviconPresentation.showsDashedOutline(
            isDiscarded: rightStatusModel.isDiscarded,
            isUnloaded: rightStatusModel.isUnloaded
        )
    }

    private func updateFaviconCenterOffset(separatesDashedOutlines: Bool) {
        let offset = separatesDashedOutlines
            ? Self.separatedFaviconCenterOffset
            : Self.defaultFaviconCenterOffset
        leftIconCenterXConstraint?.update(offset: -offset)
        rightIconCenterXConstraint?.update(offset: offset)
    }

    override var isSelected: Bool {
        didSet { updateSelectedState() }
    }

    private func updateSelectedState() {
        backgroundView.isSelected = isSelected
        backgroundView.layer?.borderWidth = 0
        backgroundView.layer?.borderColor = NSColor.clear.cgColor
        let showsOpenIndicator = TabFaviconPresentation.showsOpenIndicator(
            isOpened: leftTab?.hasWebContent == true || rightTab?.hasWebContent == true,
            isActive: isSelected
        )
        openIndicatorHost.isHidden = !showsOpenIndicator
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
        Publishers.CombineLatest3(
            tab.$isDiscarded,
            tab.$isUnloaded,
            TabFaviconPresentation.dimmingEnabledPublisher
        )
            .map { isDiscarded, isUnloaded, dimmingEnabled in
                TabFaviconPresentation.opacity(
                    isDiscarded: isDiscarded,
                    isUnloaded: isUnloaded,
                    dimmingEnabled: dimmingEnabled
                )
            }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateOpenIndicatorOpacity()
            }
            .store(in: &cancellables)

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

    private func updateOpenIndicatorOpacity() {
        openIndicatorHost.alphaValue = TabFaviconPresentation.opacity(
            isDiscarded: leftTab?.isDiscarded == true || rightTab?.isDiscarded == true,
            isUnloaded: leftTab?.isUnloaded == true || rightTab?.isUnloaded == true
        )
    }

    private func setupFavicon(for tab: Tab,
                              into imageView: TabFaviconImageView,
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
        if let populateContextMenu { populateContextMenu(menu) }
        else { leftTab?.makeContextMenu(on: menu) }
    }
}

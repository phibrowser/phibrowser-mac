// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Combine
import SnapKit
import SwiftUI

/// A single pinned-grid cell that represents a pinned split — every pane
/// rendered as a favicon side-by-side inside one rounded background, so the
/// panes read as one item. The cell shares the dimensions and chrome of
/// `PinnedTabItem`; click and right-click route through the first pane (the
/// left/top tab), which carries the split-aware context menu.
class PinnedSplitItem: NSCollectionViewItem, NSMenuDelegate {
    static var reuseIdentifier: NSUserInterfaceItemIdentifier { .init(rawValue: "\(Self.self)") }
    private static let faviconCornerRadius: CGFloat = 3

    /// Favicon geometry for a pane count: wider splits use smaller favicons
    /// set closer together, so four panes still fit the grid cell.
    private struct PaneMetrics {
        let faviconSize: CGFloat
        let centerSpacing: CGFloat
        /// Spacing that keeps every favicon's dashed outline apart.
        let separatedCenterSpacing: CGFloat

        static func forPaneCount(_ count: Int) -> PaneMetrics {
            switch count {
            case ...2: return PaneMetrics(faviconSize: 16, centerSpacing: 20, separatedCenterSpacing: 22)
            case 3: return PaneMetrics(faviconSize: 14, centerSpacing: 17, separatedCenterSpacing: 19)
            default: return PaneMetrics(faviconSize: 12, centerSpacing: 14, separatedCenterSpacing: 16)
            }
        }
    }

    /// One favicon position in the cell. Every slot exists up front; a split
    /// uses as many as it has panes and hides the rest.
    @MainActor
    private final class PaneSlot {
        let statusModel = TabStatusModel()
        var iconView: TabFaviconImageView!
        var outlineHost: TabDecorativeHostingView?
        /// The favicon size `outlineHost` was built for.
        var outlineFaviconSize: CGFloat?
        var centerXConstraint: Constraint?
        var tab: Tab?
        var faviconHandle: ProfileScopedFaviconLoadHandle?

        func clearFaviconHandle() {
            faviconHandle?.cancel()
            faviconHandle = nil
        }
    }

    private var slots: [PaneSlot] = []
    private var activeSlots: ArraySlice<PaneSlot> { slots.prefix(panes.count) }
    private var panes: [Tab] = []
    private var backgroundView: HoverableView!
    private var openIndicatorHost: TabDecorativeHostingView!
    private var statusBadgeHost: TabDecorativeHostingView!
    private var cancellables = Set<AnyCancellable>()
    private let splitTabPreviewRegistration = SplitTabPreviewRegistration()
    private var showsSplitTabPreview = false

    /// Tab whose action runs when the cell is clicked (the pane the user
    /// most recently interacted with, or the first pane as fallback).
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
        for slot in slots {
            slot.clearFaviconHandle()
            slot.iconView.image = nil
            slot.iconView.alphaValue = 1
            slot.statusModel.prepareForReuse()
            slot.tab = nil
        }
        panes = []
        applyPaneLayout(separatesDashedOutlines: false)
        openIndicatorHost.isHidden = true
        openIndicatorHost.alphaValue = 1
        splitTabPreviewRegistration.invalidate()
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

        view.addSubview(backgroundView)

        slots = (0..<SplitGroup.maxPaneCount).map { _ in
            let slot = PaneSlot()
            slot.iconView = TabFaviconImageView(model: slot.statusModel, cornerRadius: Self.faviconCornerRadius)
            backgroundView.addSubview(slot.iconView)
            return slot
        }

        openIndicatorHost = TabDecorativeHostingView(rootView: TabOpenIndicatorView())
        openIndicatorHost.isHidden = true
        backgroundView.addSubview(openIndicatorHost)

        backgroundView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        for slot in slots {
            slot.iconView.snp.makeConstraints { make in
                make.centerY.equalToSuperview()
                slot.centerXConstraint = make.centerX.equalToSuperview().constraint
                make.size.equalTo(CGSize(width: 16, height: 16))
            }
        }

        openIndicatorHost.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.top.equalTo(slots[0].iconView.snp.bottom)
                .offset(TabOpenIndicatorMetrics.pinnedSpacing)
            make.size.equalTo(CGSize(
                width: TabOpenIndicatorMetrics.diameter,
                height: TabOpenIndicatorMetrics.diameter
            ))
        }

        statusBadgeHost = TabDecorativeHostingView(
            rootView: MergedTabCornerBadgeView(
                models: slots.map(\.statusModel)
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
        panes: [Tab],
        browserState: BrowserState? = nil,
        themeProvider _: ThemeStateProvider
    ) {
        let shownPanes = Array(panes.prefix(slots.count))
        self.panes = shownPanes
        cancellables.removeAll()
        for (index, slot) in slots.enumerated() {
            slot.clearFaviconHandle()
            slot.statusModel.prepareForReuse()
            slot.tab = index < shownPanes.count ? shownPanes[index] : nil
            if let tab = slot.tab {
                slot.statusModel.configure(with: tab, in: browserState)
            }
        }
        applyPaneLayout(separatesDashedOutlines: everyFaviconShowsDashedOutline)

        Publishers.MergeMany(shownPanes.map(\.$hasWebContent))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateSelectedState()
            }
            .store(in: &cancellables)

        Publishers.CombineLatest(
            Publishers.MergeMany(activeSlots.flatMap { [$0.statusModel.$isDiscarded, $0.statusModel.$isUnloaded] }),
            TabFaviconPresentation.dimmingEnabledPublisher
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _, dimmingEnabled in
            guard let self else { return }
            self.applyPaneLayout(
                separatesDashedOutlines: dimmingEnabled && self.everyFaviconShowsDashedOutline
            )
        }
        .store(in: &cancellables)

        shownPanes.forEach { refreshFavicon(for: $0) }
        updateOpenIndicatorOpacity()
        if let browserState,
           let first = shownPanes.first,
           let target = SplitTabPreviewTarget.make(representing: first, in: browserState) {
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
        view.setAccessibilityLabel(shownPanes.map(\.title).joined(separator: " | "))

        self.isSelected = shownPanes.contains(where: \.isActive)

        // Drive the context menu off the first pane so the user gets the
        // split-aware items (Unpin Split, Remove from Split, etc.).
        if let menu = view.menu {
            if let populateContextMenu { populateContextMenu(menu) }
            else { shownPanes.first?.makeContextMenu(on: menu) }
        }

        shownPanes.forEach { subscribeFaviconUpdates(for: $0) }

        Publishers.MergeMany(shownPanes.map(\.$isActive))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.isSelected = self.panes.contains(where: \.isActive)
            }
            .store(in: &cancellables)
    }

    private var everyFaviconShowsDashedOutline: Bool {
        !activeSlots.isEmpty && activeSlots.allSatisfy { slot in
            TabFaviconPresentation.showsDashedOutline(
                isDiscarded: slot.statusModel.isDiscarded,
                isUnloaded: slot.statusModel.isUnloaded
            )
        }
    }

    /// Centers the used favicons in the cell and hides the rest.
    private func applyPaneLayout(separatesDashedOutlines: Bool) {
        let count = panes.count
        let metrics = PaneMetrics.forPaneCount(count)
        let spacing = separatesDashedOutlines ? metrics.separatedCenterSpacing : metrics.centerSpacing
        for (index, slot) in slots.enumerated() {
            let isUsed = index < count
            slot.iconView.isHidden = !isUsed
            slot.outlineHost?.isHidden = !isUsed
            guard isUsed else { continue }
            let offset = (CGFloat(index) - CGFloat(count - 1) / 2) * spacing
            slot.centerXConstraint?.update(offset: offset)
            slot.iconView.snp.updateConstraints { make in
                make.size.equalTo(CGSize(width: metrics.faviconSize, height: metrics.faviconSize))
            }
            installOutline(in: slot, faviconSize: metrics.faviconSize)
        }
    }

    /// The outline view takes its favicon size at construction, so a slot gets
    /// a new one when the pane count changes its size.
    private func installOutline(in slot: PaneSlot, faviconSize: CGFloat) {
        guard slot.outlineFaviconSize != faviconSize else { return }
        slot.outlineHost?.removeFromSuperview()
        let host = TabDecorativeHostingView(
            rootView: TabDiscardedFaviconOutline(
                model: slot.statusModel,
                faviconSize: faviconSize,
                faviconCornerRadius: Self.faviconCornerRadius
            )
        )
        backgroundView.addSubview(host)
        let outlineSize = TabCornerBadgeMetrics.discardedOutlineSize(
            for: faviconSize,
            cornerRadius: Self.faviconCornerRadius
        )
        host.snp.makeConstraints { make in
            make.center.equalTo(slot.iconView)
            make.size.equalTo(CGSize(width: outlineSize, height: outlineSize))
        }
        slot.outlineHost = host
        slot.outlineFaviconSize = faviconSize
    }

    override var isSelected: Bool {
        didSet { updateSelectedState() }
    }

    private func updateSelectedState() {
        backgroundView.isSelected = isSelected
        backgroundView.layer?.borderWidth = 0
        backgroundView.layer?.borderColor = NSColor.clear.cgColor
        let showsOpenIndicator = TabFaviconPresentation.showsOpenIndicator(
            isOpened: panes.contains(where: \.hasWebContent),
            isActive: isSelected
        )
        openIndicatorHost.isHidden = !showsOpenIndicator
    }

    /// Choose which pane a click should focus: the one currently active in
    /// the split (Chromium keeps focus on whichever was last clicked),
    /// otherwise the first pane.
    private func preferredClickTab() -> Tab? {
        panes.first(where: \.isActive) ?? panes.first
    }

    private func tab(at point: NSPoint) -> Tab? {
        guard !panes.isEmpty, backgroundView.bounds.width > 0 else { return panes.first }
        let index = Int(point.x / backgroundView.bounds.width * CGFloat(panes.count))
        return panes[max(0, min(index, panes.count - 1))]
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

    /// Dispatch a favicon refresh to the slot `tab` occupies in this cell.
    /// No-op if the cell has been recycled away from `tab`.
    private func refreshFavicon(for tab: Tab) {
        guard let slot = slots.first(where: { $0.tab === tab }) else { return }
        setupFavicon(for: tab, into: slot)
    }

    private func updateOpenIndicatorOpacity() {
        openIndicatorHost.alphaValue = TabFaviconPresentation.opacity(
            isDiscarded: panes.contains(where: \.isDiscarded),
            isUnloaded: panes.contains(where: \.isUnloaded)
        )
    }

    private func setupFavicon(for tab: Tab, into slot: PaneSlot) {
        slot.clearFaviconHandle()
        let imageView = slot.iconView!

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

        slot.faviconHandle = ProfileScopedFaviconRepository.shared.loadFavicon(for: request) { [weak imageView, weak tab] result in
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
        guard panes.count >= 2, !showsSplitTabPreview else {
            view.toolTip = nil
            return
        }
        view.toolTip = panes.map(\.title).joined(separator: " | ")
    }

    func cancelTabPreviewForInteraction() {
        splitTabPreviewRegistration.cancelForInteraction()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        splitTabPreviewRegistration.cancelForInteraction()
        if let populateContextMenu { populateContextMenu(menu) }
        else { panes.first?.makeContextMenu(on: menu) }
    }
}

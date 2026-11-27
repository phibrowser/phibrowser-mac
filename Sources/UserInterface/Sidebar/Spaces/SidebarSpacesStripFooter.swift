// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import SnapKit
import SwiftUI

/// The bottom mount shared by docked and floating sidebars. Keeping it in the
/// vertical stack lets notification and media cards reserve their own space
/// above the switcher rather than overlap it.
final class SidebarSpacesStripFooter: NSView {
    private lazy var rowHeight = heightAnchor.constraint(equalToConstant: 0)
    private var switcher: SidebarSpaceSwitcherView?
    private(set) var isActive = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        rowHeight.isActive = true
    }

    required init?(coder: NSCoder) { nil }

    func bind(slot: SpaceWindowSlot, resolveOwnerController: @escaping () -> SpaceSessionController?) {
        guard switcher == nil else { return }
        let switcher = SidebarSpaceSwitcherView(slot: slot, resolveOwnerController: resolveOwnerController)
        addSubview(switcher)
        switcher.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        self.switcher = switcher
        updateVisibility()
    }

    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        updateVisibility()
    }

    func updateVisibility() {
        let visible = isActive && switcher != nil
            && PhiPreferences.GeneralSettings.spacesFeatureEnabled.loadValue()
            && SpaceManager.shared.spaces.count > 1
        rowHeight.constant = visible ? SpacesStripView.sidebarHeight : 0
        switcher?.isHidden = !visible
    }
}

/// One slot per Space. Hover and clicks are resolved here against the slot
/// layout rather than by the item views, which overlap while a dot row widens
/// the slot under the pointer.
final class SidebarSpaceSwitcherView: NSView {
    private typealias Layout = SidebarSpacePagination

    private static let transitionDuration: TimeInterval = 0.15
    private static let hoverCardDelay: TimeInterval = 0.3
    /// Matches the header strip's peek: half an icon plus the gap.
    private static let edgeFadeWidth: CGFloat = 16

    private let slot: SpaceWindowSlot
    private let manager = SpaceManager.shared
    private let resolveOwnerController: () -> SpaceSessionController?
    private let viewport = NSView()
    private let selectionLayer = CALayer()
    private let edgeFadeMask = CAGradientLayer()
    private let tooltipController = SpaceHoverTooltipController()

    private var items: [SidebarSpaceSwitcherItemView] = []
    private var activeSpaceId: String?
    private var hoveredSpaceId: String?
    private var pressedSpaceId: String?
    private var scrollOffset: CGFloat = 0
    private var mode: Layout.Mode = .dots
    private var laidOutSize: NSSize = .zero
    private var needsReload = true
    private var pendingTooltipWork: DispatchWorkItem?
    private var trackingArea: NSTrackingArea?
    private var cancellables: Set<AnyCancellable> = []
    private var themeSubscription: AnyObject?

    init(slot: SpaceWindowSlot, resolveOwnerController: @escaping () -> SpaceSessionController?) {
        self.slot = slot
        self.resolveOwnerController = resolveOwnerController
        super.init(frame: .zero)
        wantsLayer = true
        viewport.wantsLayer = true
        viewport.layer?.masksToBounds = true
        addSubview(viewport)
        // Same chip as the header strip's selection.
        selectionLayer.cornerRadius = SidebarSpaceSwitcherItemView.backgroundCornerRadius
        selectionLayer.cornerCurve = .continuous
        selectionLayer.shadowColor = NSColor.black.cgColor
        selectionLayer.shadowOpacity = 0.15
        selectionLayer.shadowRadius = 1
        selectionLayer.shadowOffset = CGSize(width: 0, height: -1)
        selectionLayer.zPosition = -1
        selectionLayer.opacity = 0
        viewport.layer?.addSublayer(selectionLayer)
        edgeFadeMask.startPoint = CGPoint(x: 0, y: 0.5)
        edgeFadeMask.endPoint = CGPoint(x: 1, y: 0.5)
        viewport.layer?.mask = edgeFadeMask
        bindModel()
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override var isHidden: Bool {
        didSet {
            if isHidden {
                setHoveredSpace(nil, animated: false)
            } else if needsReload {
                reload(relayout: true)
            }
        }
    }

    private func bindModel() {
        // @Published fires before the store changes; read on the next turn.
        manager.objectWillChange
            .merge(with: AgentSpaceManager.shared.objectWillChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reload() }
            .store(in: &cancellables)
        slot.$activeSpaceId
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.activeSpaceChanged() }
            .store(in: &cancellables)
        themeSubscription = subscribe { [weak self] _, _ in
            self?.updateSelectionColor()
            self?.refreshIcons()
        }
    }

    private func reload(relayout: Bool = false) {
        guard !isHidden else {
            needsReload = true
            return
        }
        needsReload = false
        let spaces = slot.presentedSpaces
        let ids = spaces.map(\.spaceId)
        // Most publishes change nothing here; relaying out would cut short a
        // running hover transition. Selection changes animate separately.
        let structureChanged = ids != items.map(\.spaceId)
        if structureChanged {
            var reusable = Dictionary(uniqueKeysWithValues: items.map { ($0.spaceId, $0) })
            items = ids.map { id in
                if let item = reusable.removeValue(forKey: id) { return item }
                let item = SidebarSpaceSwitcherItemView(spaceId: id)
                item.onPress = { [weak self] in self?.activate(id) }
                viewport.addSubview(item)
                return item
            }
            reusable.values.forEach { $0.removeFromSuperview() }
        }
        if let hovered = hoveredSpaceId, !ids.contains(hovered) {
            setHoveredSpace(nil, animated: false)
        }
        if let pressed = pressedSpaceId, !ids.contains(pressed) { pressedSpaceId = nil }
        tooltipController.dismissIfOwnerMissing(liveSpaceIds: ids)
        updateAccessibility(spaces: spaces)
        refreshIcons()
        guard structureChanged || relayout else { return }
        activeSpaceId = slot.activeSpaceId
        updateAccessibility(spaces: spaces)
        revealActiveSpace()
        applyLayout(animated: false)
    }

    private func activeSpaceChanged() {
        guard !isHidden else {
            needsReload = true
            return
        }
        activeSpaceId = slot.activeSpaceId
        updateAccessibility(spaces: slot.presentedSpaces)
        revealActiveSpace()
        applyLayout(animated: true)
    }

    private func liveSpace(_ spaceId: String) -> Space? {
        slot.presentedSpaces.first { $0.spaceId == spaceId }
    }

    private func updateAccessibility(spaces: [Space]) {
        let format = NSLocalizedString("sidebar.spacesStrip.pageAccessibilityValue", value: "Page %1$ld of %2$ld",
            comment: "Sidebar Space dot accessibility value; the current dot's one-based position, then the total number of Spaces")
        for (index, space) in spaces.enumerated() where items.indices.contains(index) {
            let item = items[index]
            item.setAccessibilityLabel(space.name)
            item.setAccessibilityValue(String.localizedStringWithFormat(format, index + 1, spaces.count))
            item.setAccessibilitySelected(space.spaceId == activeSpaceId)
        }
    }

    private func refreshIcons() {
        guard !isHidden else { return }
        let isDark = currentAppearance.isDark
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let tasks = AgentSpaceManager.shared.tasksBySpaceId
        for space in slot.presentedSpaces {
            guard let item = items.first(where: { $0.spaceId == space.spaceId }) else { continue }
            let badge = tasks[space.spaceId].map { AgentDriverBadge.make(agentName: $0.agentName, origin: $0.origin) }
            let key = SidebarSpaceSwitcherItemView.IconKey(
                iconName: space.iconName, agentAsset: badge?.assetName, agentSymbol: badge?.symbol,
                isDark: isDark, scale: scale)
            guard item.iconKey != key else { continue }
            let image = badge.flatMap { Self.badgeImage($0, isDark: isDark) }
                ?? SpaceIconView.rasterizedImage(for: space.iconName, canvasSize: SidebarSpaceSwitcherItemView.iconCanvasSize,
                                                 scale: scale, isDark: isDark, tint: isDark ? .white : .black)
            item.setIcon(image, key: key, scale: scale)
        }
    }

    /// Matches the header pip: brand assets carry padding around their ink, so
    /// they draw larger to line up with SF Symbols.
    private static func badgeImage(_ badge: AgentDriverBadge, isDark: Bool) -> NSImage? {
        let canvas = SidebarSpaceSwitcherItemView.iconCanvasSize
        let glyphSize: CGFloat = 14
        let image: NSImage?
        let drawSize: NSSize
        if let asset = badge.assetName {
            image = NSImage(named: asset)
            let side = glyphSize / AgentDriverBadge.assetInkRatio
            drawSize = NSSize(width: side, height: side)
        } else {
            image = NSImage(systemSymbolName: badge.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: glyphSize, weight: .semibold))
            drawSize = image?.size ?? .zero
        }
        guard let image else { return nil }
        let tint = isDark ? NSColor.white : NSColor.black
        return NSImage(size: NSSize(width: canvas, height: canvas), flipped: false) { rect in
            let target = NSRect(x: rect.midX - drawSize.width / 2, y: rect.midY - drawSize.height / 2,
                                width: drawSize.width, height: drawSize.height)
            image.draw(in: target)
            tint.set()
            target.fill(using: .sourceAtop)
            return true
        }
    }

    override func layout() {
        super.layout()
        guard bounds.size != laidOutSize else { return }
        laidOutSize = bounds.size
        revealActiveSpace()
        applyLayout(animated: false)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refreshIcons()
    }

    private var viewportWidth: CGFloat { Layout.viewportWidth(for: bounds.width) }

    private func index(of spaceId: String?) -> Int? {
        guard let spaceId else { return nil }
        return items.firstIndex { $0.spaceId == spaceId }
    }

    private func slotWidths() -> [CGFloat] {
        let expanded = Layout.expandedIndex(hovered: index(of: hoveredSpaceId), active: index(of: activeSpaceId))
        return Layout.slotWidths(count: items.count, rowWidth: bounds.width, expandedIndex: expanded)
    }

    /// Only the active Space scrolls into view; hovering never moves the row.
    private func revealActiveSpace() {
        let widths = Layout.slotWidths(count: items.count, rowWidth: bounds.width,
                                       expandedIndex: index(of: activeSpaceId))
        scrollOffset = Layout.scrollOffset(revealing: index(of: activeSpaceId) ?? -1, widths: widths,
                                           viewportWidth: viewportWidth, current: scrollOffset)
    }

    private var animatesTransitions: Bool {
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            && window?.occlusionState.contains(.visible) == true
    }

    private func updateSelectionColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            selectionLayer.backgroundColor = NSColor(resource: .sidebarTabSelected).cgColor
        }
    }

    private func applyLayout(animated: Bool) {
        viewport.frame = NSRect(x: Layout.edgeInset, y: 0, width: viewportWidth, height: bounds.height)
        mode = Layout.mode(count: items.count, rowWidth: bounds.width)
        let widths = slotWidths()
        scrollOffset = min(scrollOffset, Layout.maxScrollOffset(widths: widths, viewportWidth: viewportWidth))
        let origins = Layout.slotOrigins(widths: widths, viewportWidth: viewportWidth, scrollOffset: scrollOffset)
        let itemWidth = SidebarSpaceSwitcherItemView.width
        let backgroundSize = Layout.backgroundSize(
            forSlotWidth: Layout.iconSlotWidth(count: items.count, rowWidth: bounds.width))
        let hoveredIndex = index(of: hoveredSpaceId)
        let activeIndex = index(of: activeSpaceId)
        let expandedIndex = Layout.expandedIndex(hovered: hoveredIndex, active: activeIndex)
        let animate = animated && animatesTransitions
        CATransaction.begin()
        CATransaction.setDisableActions(!animate)
        CATransaction.setAnimationDuration(Self.transitionDuration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        selectionLayer.bounds = CGRect(origin: .zero, size: backgroundSize)
        if let activeIndex {
            selectionLayer.position = CGPoint(x: origins[activeIndex] + widths[activeIndex] / 2,
                                              y: viewport.bounds.midY)
        }
        selectionLayer.opacity = mode == .icons && activeIndex != nil ? 1 : 0
        updateEdgeFades(maxScrollOffset: Layout.maxScrollOffset(widths: widths, viewportWidth: viewportWidth))
        CATransaction.commit()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animate ? Self.transitionDuration : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = animate
            for (index, item) in items.enumerated() {
                let center = origins[index] + widths[index] / 2
                let frame = viewport.backingAlignedRect(
                    NSRect(x: center - itemWidth / 2, y: 0, width: itemWidth, height: bounds.height),
                    options: .alignAllEdgesNearest)
                if animate {
                    item.animator().frame = frame
                } else {
                    item.frame = frame
                }
                let state: SidebarSpaceSwitcherItemView.State
                switch mode {
                case .icons:
                    let isEmphasized = index == hoveredIndex || item.spaceId == activeSpaceId
                    state = isEmphasized
                        ? .icon(hoverBackground: index == hoveredIndex && index != activeIndex)
                        : .mutedIcon
                case .dots:
                    state = index == expandedIndex ? .icon(hoverBackground: false) : .dot
                }
                item.apply(state, backgroundSize: backgroundSize, animated: animate, duration: Self.transitionDuration)
            }
        }
    }

    /// Fades an edge only while Spaces are scrolled out past it.
    private func updateEdgeFades(maxScrollOffset: CGFloat) {
        let width = viewport.bounds.width
        edgeFadeMask.frame = viewport.bounds
        guard width > 0 else { return }
        let fade = min(Self.edgeFadeWidth, width / 2) / width
        let opaque = NSColor.black.cgColor
        let clear = NSColor.clear.cgColor
        edgeFadeMask.colors = [scrollOffset > 0.5 ? clear : opaque, opaque, opaque,
                               scrollOffset < maxScrollOffset - 0.5 ? clear : opaque]
        edgeFadeMask.locations = [0, fade, 1 - fade, 1].map { NSNumber(value: Double($0)) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    private func spaceId(at event: NSEvent) -> String? {
        let point = viewport.convert(event.locationInWindow, from: nil)
        guard viewport.bounds.contains(point) else { return nil }
        let widths = slotWidths()
        let origins = Layout.slotOrigins(widths: widths, viewportWidth: viewportWidth, scrollOffset: scrollOffset)
        guard let index = origins.indices.first(where: { point.x >= origins[$0] && point.x < origins[$0] + widths[$0] })
        else { return nil }
        return items[index].spaceId
    }

    override func mouseEntered(with event: NSEvent) {
        setHoveredSpace(spaceId(at: event), animated: true)
    }

    override func mouseMoved(with event: NSEvent) {
        setHoveredSpace(spaceId(at: event), animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        setHoveredSpace(nil, animated: true)
    }

    override func mouseDown(with event: NSEvent) {
        pressedSpaceId = spaceId(at: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressedSpaceId = nil }
        guard let pressed = pressedSpaceId, spaceId(at: event) == pressed else { return }
        activate(pressed)
    }

    override func scrollWheel(with event: NSEvent) {
        let widths = slotWidths()
        let maxOffset = Layout.maxScrollOffset(widths: widths, viewportWidth: viewportWidth)
        guard maxOffset > 0 else {
            super.scrollWheel(with: event)
            return
        }
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        let step = event.hasPreciseScrollingDeltas ? delta : delta * Layout.minDotSlotWidth
        scrollOffset = min(max(0, scrollOffset - step), maxOffset)
        applyLayout(animated: false)
        setHoveredSpace(spaceId(at: event), animated: true)
    }

    private func setHoveredSpace(_ spaceId: String?, animated: Bool) {
        guard hoveredSpaceId != spaceId else { return }
        if let old = hoveredSpaceId { hoverEnded(old) }
        hoveredSpaceId = spaceId
        if let spaceId { hoverBegan(spaceId) }
        applyLayout(animated: animated)
    }

    /// Same rules as the header strip: moving onto another Space, or back onto
    /// the clicked one after the hand-off window, lifts the click suppression.
    private func hoverBegan(_ spaceId: String) {
        if let suppressed = slot.hoverCardSuppressedSpaceId,
           suppressed != spaceId || slot.isHoverCardSuppressionStale {
            slot.hoverCardSuppressedSpaceId = nil
        }
        pendingTooltipWork?.cancel()
        pendingTooltipWork = nil
        if tooltipController.isWarm {
            presentHoverCard(for: spaceId)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.pendingTooltipWork = nil
            self?.presentHoverCard(for: spaceId)
        }
        pendingTooltipWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverCardDelay, execute: work)
    }

    /// Only the visible window may lift the click suppression: the leaving
    /// window's switcher also sees an exit when it orders out after the swap.
    private func hoverEnded(_ spaceId: String) {
        if slot.hoverCardSuppressedSpaceId == spaceId {
            let owner = resolveOwnerController()
            if owner == nil || owner === slot.visibleController {
                slot.hoverCardSuppressedSpaceId = nil
            }
        }
        pendingTooltipWork?.cancel()
        pendingTooltipWork = nil
        tooltipController.dismiss(spaceId: spaceId)
    }

    private func presentHoverCard(for spaceId: String) {
        guard hoveredSpaceId == spaceId,
              slot.hoverCardSuppressedSpaceId != spaceId,
              let window,
              let space = liveSpace(spaceId),
              let index = index(of: spaceId) else { return }
        let widths = slotWidths()
        let origins = Layout.slotOrigins(widths: widths, viewportWidth: viewportWidth, scrollOffset: scrollOffset)
        let slotRect = NSRect(x: origins[index], y: 0, width: widths[index], height: viewport.bounds.height)
            .intersection(viewport.bounds)
        let screenRect = window.convertToScreen(viewport.convert(slotRect, to: nil))
        let provider = themeStateProvider
        let card = SpaceHoverCard(space: space, manager: manager,
                                  theme: provider.currentTheme, appearance: provider.currentAppearance)
        tooltipController.present(spaceId: spaceId, card: AnyView(card), anchorScreenRect: screenRect,
                                  screen: window.screen)
    }

    private func activate(_ spaceId: String) {
        guard let space = liveSpace(spaceId),
              manager.acceptsStoreAction(from: space.storeIdentifier),
              // The create form keeps the switcher visible for reference only.
              !slot.isCreatingSpace else { return }
        pendingTooltipWork?.cancel()
        pendingTooltipWork = nil
        tooltipController.dismiss(spaceId: spaceId)
        // Keep the card down across the window swap until the pointer leaves.
        slot.suppressHoverCard(spaceId: spaceId)
        slot.activate(spaceId: spaceId, userInitiated: true)
    }
}

private final class SidebarSpaceSwitcherItemView: NSView {
    struct IconKey: Equatable {
        let iconName: String
        let agentAsset: String?
        let agentSymbol: String?
        let isDark: Bool
        let scale: CGFloat
    }

    enum State: Equatable {
        case dot
        case icon(hoverBackground: Bool)
        case mutedIcon
    }

    static let iconCanvasSize: CGFloat = 18
    private static let dotDiameter: CGFloat = 5
    private static let dotOpacity: Float = 0.4
    private static let mutedIconOpacity: Float = 0.4
    /// Slots narrower than this overlap; the switcher hit-tests by slot.
    static let width = SidebarSpacePagination.maxIconSlotWidth
    static let backgroundCornerRadius: CGFloat = 8

    let spaceId: String
    private(set) var iconKey: IconKey?
    var onPress: (() -> Void)?

    private let hoverLayer = CALayer()
    private let dotLayer = CALayer()
    private let iconLayer = CALayer()

    init(spaceId: String) {
        self.spaceId = spaceId
        super.init(frame: .zero)
        wantsLayer = true
        hoverLayer.cornerRadius = Self.backgroundCornerRadius
        hoverLayer.cornerCurve = .continuous
        hoverLayer.opacity = 0
        hoverLayer.phi(source: self).setBackgroundColor(.sidebarTabHoveredBackground)
        dotLayer.cornerRadius = Self.dotDiameter / 2
        dotLayer.phi(source: self).setBackgroundColor(.textPrimary)
        iconLayer.contentsGravity = .resizeAspect
        iconLayer.opacity = 0
        layer?.addSublayer(hoverLayer)
        layer?.addSublayer(dotLayer)
        layer?.addSublayer(iconLayer)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        hoverLayer.position = center
        dotLayer.bounds = CGRect(x: 0, y: 0, width: Self.dotDiameter, height: Self.dotDiameter)
        dotLayer.position = center
        iconLayer.bounds = CGRect(x: 0, y: 0, width: Self.iconCanvasSize, height: Self.iconCanvasSize)
        iconLayer.position = center
        CATransaction.commit()
    }

    func setIcon(_ image: NSImage?, key: IconKey, scale: CGFloat) {
        iconKey = key
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        iconLayer.contentsScale = image?.recommendedLayerContentsScale(scale) ?? scale
        iconLayer.contents = image?.layerContents(forContentsScale: iconLayer.contentsScale)
        CATransaction.commit()
    }

    func apply(_ state: State, backgroundSize: CGSize, animated: Bool, duration: TimeInterval) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        hoverLayer.bounds = CGRect(origin: .zero, size: backgroundSize)
        switch state {
        case .dot:
            dotLayer.opacity = Self.dotOpacity
            iconLayer.opacity = 0
            hoverLayer.opacity = 0
        case .icon(let hoverBackground):
            dotLayer.opacity = 0
            iconLayer.opacity = 1
            hoverLayer.opacity = hoverBackground ? 1 : 0
        case .mutedIcon:
            dotLayer.opacity = 0
            iconLayer.opacity = Self.mutedIconOpacity
            hoverLayer.opacity = 0
        }
        CATransaction.commit()
    }
}

// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Combine
import Lottie
import SnapKit
import SwiftUI

// MARK: - Base Cell View
class SidebarCellView: NSTableCellView {
    var cancellables = Set<AnyCancellable>()
    weak var item: SidebarItem?
    
    lazy var backgoundView: HoverableView = {
        let view = HoverableView()
        view.enableClickAnimation = false
        view.responseToClickAction = true
        view.shadow = selectedShadow
        return view
    }()
    
    lazy var selectedShadow: NSShadow = {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.15)
        shadow.shadowBlurRadius = 1
        shadow.shadowOffset = CGSizeMake(0, -1)
        return shadow
    }()
    
    override func prepareForReuse() {
        super.prepareForReuse()
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
        item = nil
    }
    
    func configure(with item: SidebarItem) {
        self.item = item
        configureAppearance()
    }
    
    func configureAppearance() {
        // Override in subclasses
    }
    
    override var draggingImageComponents: [NSDraggingImageComponent] {
        let targetView = backgoundView.superview != nil ? backgoundView : self
        
        guard let snapshot = createDraggingImage() else {
            return super.draggingImageComponents
        }
        
        let component = NSDraggingImageComponent(key: .icon)
        component.contents = snapshot
        // Use the subview's actual frame in the cell's coordinate space so the snap-back
        // animation targets the correct position. When targetView is self, origin is (0,0).
        let componentOrigin = targetView === self ? CGPoint.zero : targetView.frame.origin
        component.frame = CGRect(origin: componentOrigin, size: snapshot.size)
        
        return [component]
    }
    
    func createDraggingImage() -> NSImage? {
        let targetView = backgoundView.superview != nil ? backgoundView : self
        return targetView.createDraggingSnapshot()
    }
}

// MARK: - NSView Dragging Snapshot Extension
extension NSView {
    /// Creates a rounded snapshot of the view for dragging.
    /// - Parameter cornerRadius: Corner radius applied to the snapshot.
    /// - Returns: Snapshot image with rounded corners.
    func createDraggingSnapshot(cornerRadius: CGFloat = 8) -> NSImage? {
        let targetBounds = self.bounds
        
        guard targetBounds.width > 0 && targetBounds.height > 0 else {
            return nil
        }
        
        // Rasterize the current view into a bitmap first.
        guard let bitmapRep = self.bitmapImageRepForCachingDisplay(in: targetBounds) else {
            return nil
        }
        
        self.cacheDisplay(in: targetBounds, to: bitmapRep)
        
        // Draw into a rounded image canvas.
        let image = NSImage(size: targetBounds.size)
        image.addRepresentation(bitmapRep)
        
        // Clip to the rounded path before drawing the cached bitmap.
        let roundedImage = NSImage(size: targetBounds.size)
        roundedImage.lockFocus()
        
        let path = NSBezierPath(roundedRect: NSRect(origin: .zero, size: targetBounds.size),
                                 xRadius: cornerRadius,
                                 yRadius: cornerRadius)
        path.addClip()
        image.draw(in: NSRect(origin: .zero, size: targetBounds.size))
        
        roundedImage.unlockFocus()
         
        return roundedImage
    }
}

final class TrailingFadeTextField: NSTextField {
    private static let fadeWidth: CGFloat = 10

    private let fadeMaskLayer = CAGradientLayer()

    init() {
        super.init(frame: .zero)
        configureLabel()
        configureFadeMask()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLabel()
        configureFadeMask()
    }

    override func layout() {
        super.layout()
        updateFadeMask()
    }

    private func configureLabel() {
        isBordered = false
        isEditable = false
        isSelectable = false
        drawsBackground = false
        backgroundColor = .clear
        lineBreakMode = .byClipping
        maximumNumberOfLines = 1
        cell?.lineBreakMode = .byClipping
        cell?.truncatesLastVisibleLine = false
    }

    private func configureFadeMask() {
        wantsLayer = true
        fadeMaskLayer.startPoint = CGPoint(x: 0, y: 0.5)
        fadeMaskLayer.endPoint = CGPoint(x: 1, y: 0.5)
        fadeMaskLayer.colors = [
            NSColor.black.cgColor,
            NSColor.black.cgColor,
            NSColor.clear.cgColor
        ]
        layer?.mask = fadeMaskLayer
    }

    private func updateFadeMask() {
        guard bounds.width > 0, bounds.height > 0 else {
            layer?.mask = nil
            return
        }

        let opaqueEnd = max(0, (bounds.width - Self.fadeWidth) / bounds.width)
        fadeMaskLayer.frame = bounds
        fadeMaskLayer.locations = [
            0,
            NSNumber(value: Double(opaqueEnd)),
            1
        ]
        fadeMaskLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        layer?.mask = fadeMaskLayer
    }
}

// MARK: - Tab Hover Region

/// Transparent overlay that owns hover tracking for sidebar tabs.
/// NSHostingView sits underneath and does not reliably deliver parent tracking-area events,
/// so this view drives hover via its own tracking area while staying transparent to hit-testing
/// — clicks fall through to the SwiftUI buttons (close / mute) inside the hosting view.
/// Shared by ungrouped `SidebarTabCellView` and `TabGroupCellView` container hover.
final class SidebarTabHoverRegionView: NSView {
    var onHoverChanged: ((Bool) -> Void)?

    private var trackingArea: NSTrackingArea?

    // Pass clicks through to the hostingView below. Manually forwarding via
    // `mouseDown(with:)` doesn't trigger SwiftUI's gesture system (the X
    // close button never fires), so let AppKit deliver events the normal way.
    // Hover detection still works because NSTrackingArea fires entered/exited
    // independent of hit testing.
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
        syncHoverStateForCurrentMouseLocation()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverChanged?(false)
    }

    private func syncHoverStateForCurrentMouseLocation() {
        guard let window else {
            onHoverChanged?(false)
            return
        }
        let screenPoint = NSEvent.mouseLocation
        let screenRect = CGRect(x: screenPoint.x, y: screenPoint.y, width: 1, height: 1)
        let windowPoint = window.convertFromScreen(screenRect).origin
        let point = convert(windowPoint, from: nil)
        onHoverChanged?(bounds.contains(point))
    }
}

/// Clears tab hover when the cursor is in the trailing strip beside the split divider.
/// Transparent to hit-testing for the same reason as the hover region above.
private final class SidebarTabHoverDeadZoneView: NSView {
    var onEntered: (() -> Void)?

    private var trackingArea: NSTrackingArea?

    // Same hit-transparent strategy as `SidebarTabHoverRegionView`.
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onEntered?()
    }
}

// MARK: - Tab Cell View (reused from existing)
class SidebarTabCellView: SidebarCellView, TabPreviewInteractionCancelling {
    private var hostingView: ThemedHostingView!
    private let hoverRegionView = SidebarTabHoverRegionView()
    private let hoverDeadZoneView = SidebarTabHoverDeadZoneView()
    private let viewModel = TabViewModel()
    /// Feeds the trailing peek indicator's favicon while a Peek is attached
    /// to this row's tab.
    private let peekTabViewModel = TabViewModel()
    private let tabPreviewRegistration = TabPreviewRegistration()
    private weak var configuredTab: Tab?
    private var activeSuppressed = false
    weak var delegate: TabCellDelegate?


    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }
    
    override func prepareForReuse() {
        super.prepareForReuse()
        // Only cancel subscriptions and reset interaction state.
        // Visual state (title, favicon, etc.) is preserved until configure()
        // overwrites it, avoiding a blank-frame flicker between prepareForReuse
        // and the next SwiftUI render cycle.
        viewModel.cancelSubscriptions()
        viewModel.setHoverSuppressed(false)
        viewModel.setActiveSuppressed(false, activeValue: false)
        viewModel.setHovered(false)
        viewModel.isPressed = false
        // Peek attachment is tab identity, not preservable visual state — a
        // reused row must never show the previous tab's peek indicator.
        viewModel.showsPeek = false
        peekTabViewModel.prepareForReuse()
        tabPreviewRegistration.invalidate()
        configuredTab = nil
        activeSuppressed = false
    }

    /// Cancel Combine subscriptions without resetting visual state.
    /// Used before reloadData to prevent orphan events while keeping
    /// the current frame on screen (avoids blank-frame flicker).
    func invalidateSubscriptions() {
        viewModel.cancelSubscriptions()
        peekTabViewModel.cancelSubscriptions()
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
    }

    func setHoverSuppressed(_ suppressed: Bool) {
        viewModel.setHoverSuppressed(suppressed)
        if suppressed {
            tabPreviewRegistration.setHovering(false)
        }
    }

    func setHovered(_ hovered: Bool) {
        viewModel.setHovered(hovered)
        tabPreviewRegistration.setHovering(hovered && !viewModel.isHoverSuppressed)
    }

    func cancelTabPreviewForInteraction() {
        tabPreviewRegistration.cancelForInteraction()
    }

    func setActiveSuppressed(_ suppressed: Bool) {
        activeSuppressed = suppressed
        viewModel.setActiveSuppressed(suppressed, activeValue: configuredTab?.isActive ?? false)
    }
    
    private func setupViews() {
        wantsLayer = true
        layer?.masksToBounds = false
        hostingView = ThemedHostingView(rootView: SideTabView(
            model: viewModel,
            onClose: { [weak self] in
                self?.closeButtonTapped()
            },
            peekModel: peekTabViewModel,
            onClosePeek: { [weak self] in
                self?.closePeekTapped()
            }
        ))
        // The outline row and edge constraints own this view's size.
        // Avoid measuring minimum, ideal and maximum SwiftUI content sizes.
        hostingView.sizingOptions = []
        hostingView.wantsLayer = true
        hostingView.layer?.masksToBounds = false
        addSubview(hostingView)
        hostingView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        tabPreviewRegistration.onEligibilityChanged = { [weak self] isEligible in
            self?.viewModel.showsTabPreview = isEligible
        }

        hoverRegionView.onHoverChanged = { [weak self] isHovered in
            self?.setHovered(isHovered)
        }
        addSubview(hoverRegionView)
        hoverRegionView.snp.makeConstraints { make in
            make.leading.top.bottom.equalToSuperview()
            make.trailing.equalToSuperview().inset(SideTabView.trailingHoverDeadZoneWidth)
        }

        hoverDeadZoneView.onEntered = { [weak self] in
            self?.setHovered(false)
        }
        addSubview(hoverDeadZoneView)
        hoverDeadZoneView.snp.makeConstraints { make in
            make.top.bottom.trailing.equalToSuperview()
            make.width.equalTo(SideTabView.trailingHoverDeadZoneWidth)
        }

        setupPressAnimation()
    }
    
    // MARK: - Press Animation
    
    private func setupPressAnimation() {
        let press = NSPressGestureRecognizer(target: self, action: #selector(handlePress(_:)))
        press.minimumPressDuration = 0
        press.allowableMovement = 5
        // Don't delay events — let them reach NSHostingView's SwiftUI Button simultaneously
        press.delaysPrimaryMouseButtonEvents = false
        addGestureRecognizer(press)
    }
    
    @objc private func handlePress(_ recognizer: NSPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            viewModel.isPressed = true
        case .ended, .cancelled, .failed:
            viewModel.isPressed = false
        default:
            break
        }
    }

    private func closeButtonTapped() {
        guard let tab = item as? Tab else { return }
        tabPreviewRegistration.cancelForInteraction()
        delegate?.tabCellDidRequestClose(tab)
    }

    private func closePeekTapped() {
        guard let tab = item as? Tab else { return }
        SpaceSessionControllersManager.shared
            .controller(for: tab.windowId)?.browserState
            .closePeek(forOpener: tab.guid)
    }

    override func configureAppearance() {
        guard let tab = item as? Tab else { return }
        configuredTab = tab
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()

        let state = SpaceSessionControllersManager.shared
            .controller(for: tab.windowId)?.browserState
        viewModel.configure(with: tab, in: state)
        if let state {
            tabPreviewRegistration.configure(
                anchorView: self,
                target: .tab(tab),
                browserState: state,
                placement: .rightTopAttached,
                anchorRectProvider: { [weak tab] view in
                    let bounds = view.bounds
                    let leadingInset = WebContentConstant.edgesSpacing
                    let trailingInset = tab?.groupToken == nil
                        ? WebContentConstant.edgesSpacing
                        : 2
                    return CGRect(
                        x: bounds.minX + leadingInset,
                        y: bounds.minY + 2,
                        width: max(0, bounds.width - leadingInset - trailingInset),
                        height: max(0, bounds.height - 4)
                    )
                }
            )
        } else {
            tabPreviewRegistration.invalidate()
        }
        viewModel.setActiveSuppressed(activeSuppressed, activeValue: tab.isActive)
        viewModel.onToggleMute = { [weak tab] in
            guard let tab else { return }
            tab.toggleAudioMuted()
        }

        if let state {
            state.peekState.$peeksByOpener
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak tab, weak state] peeksByOpener in
                    guard let self, let tab else { return }
                    self.updatePeekIndicator(peekTab: peeksByOpener[tab.guid],
                                             browserState: state)
                }
                .store(in: &cancellables)
        } else {
            updatePeekIndicator(peekTab: nil, browserState: nil)
        }
    }

    /// Shows the trailing peek indicator when a live Peek belongs to this
    /// row's tab (also while the peek is hidden behind another focused tab —
    /// the icon is what tells the user a peek is attached).
    private func updatePeekIndicator(peekTab: Tab?, browserState: BrowserState?) {
        peekTabViewModel.prepareForReuse()
        if let peekTab {
            peekTabViewModel.configure(with: peekTab, in: browserState)
        }
        viewModel.showsPeek = peekTab != nil
    }
}

// MARK: - Split Cell View
/// Sidebar row representing a non-pinned split as a single merged cell.
/// One segment per pane (two to `SplitGroup.maxPaneCount`) stands
/// side-by-side inside one rounded background, separated by thin seams;
/// each segment shows its favicon, title, and an x close button that
/// appears on cell hover. The whole cell becomes the solid selected pill
/// when any pane's tab is focused; otherwise it stays at the cell-level
/// hover tint.
class SidebarSplitCellView: SidebarCellView, TabPreviewInteractionCancelling {
    private static let faviconSize: CGFloat = 16
    private static let faviconCornerRadius: CGFloat = 3
    private static let closeButtonSize: CGFloat = 24
    private static let titleTrailingSpacing: CGFloat = 5
    /// The first segment is already inset 2 points from the row
    /// background, so 4 points aligns its favicon at the normal tab's
    /// 6-point leading edge.
    private static let firstIconLeadingSpacing: CGFloat = 4
    /// Keep extra breathing room between a divider and the next favicon.
    private static let dividedIconLeadingSpacing: CGFloat = 8
    /// Gap between neighbouring segments; the divider seam sits in it.
    private static let segmentSpacing: CGFloat = 2

    /// Views of one pane segment. Segments are created on demand (at most
    /// `SplitGroup.maxPaneCount`) and shown or hidden to match the
    /// configured pane count, so a reused cell never rebuilds its tree.
    @MainActor
    private final class PaneSegment {
        let pane = HoverableView()
        let statusModel = TabStatusModel()
        let iconView: TabFaviconImageView
        let discardedOutlineHost: TabDecorativeHostingView
        let titleLabel = TrailingFadeTextField()
        let closeHost: ZeroSafeAreaHostingView<AnyView>
        let muteHost: ZeroSafeAreaHostingView<AnyView>
        /// Recording badge overlaid on the favicon. Mirrors the corner
        /// badge `UnifiedTabFaviconView` draws on a normal tab so a split
        /// pane using the microphone / camera / screen share reads the same.
        let recordingHost: TabRecordingIconHostingView
        var muteWidth: Constraint?
        var titlePaneTrailing: Constraint?
        var titleCloseTrailing: Constraint?
        var faviconHandle: ProfileScopedFaviconLoadHandle?
        weak var tab: Tab?

        init(faviconCornerRadius: CGFloat,
             faviconSize: CGFloat,
             closeTapped: @escaping () -> Void,
             themeObserver: ThemeObserver) {
            iconView = TabFaviconImageView(model: statusModel, cornerRadius: faviconCornerRadius)
            discardedOutlineHost = TabDecorativeHostingView(
                rootView: TabDiscardedFaviconOutline(
                    model: statusModel,
                    faviconSize: faviconSize,
                    faviconCornerRadius: faviconCornerRadius
                )
            )
            // Match normal-tab close buttons (24x24 with rounded hover fill)
            // by reusing `UnifiedTabCloseButton`. Hosted inside the segment
            // so the SwiftUI button receives its own hover events.
            closeHost = ZeroSafeAreaHostingView(rootView: AnyView(
                UnifiedTabCloseButton(action: closeTapped)
                    .phiThemeObserver(themeObserver)
            ))
            closeHost.isHidden = true
            // Mute toggle. Hidden + zero width by default so the title fills
            // the same space when no audio is present; shown with 20pt
            // width when the pane's tab is audible or muted.
            muteHost = ZeroSafeAreaHostingView(rootView: AnyView(EmptyView()))
            muteHost.isHidden = true
            // Recording badge (the pulsing red dot). Only its visibility is
            // toggled; the host builds the dot on each show and drops it on
            // hide. The observer is captured by value so the host's closure
            // does not retain the cell.
            recordingHost = TabRecordingIconHostingView {
                AnyView(UnifiedTabRecordingIcon().phiThemeObserver(themeObserver))
            }
            recordingHost.isHidden = true
        }

        func prepareForReuse() {
            faviconHandle?.cancel()
            faviconHandle = nil
            iconView.image = nil
            iconView.alphaValue = 1
            statusModel.prepareForReuse()
            titleLabel.stringValue = ""
            titleLabel.toolTip = nil
            closeHost.isHidden = true
            muteHost.isHidden = true
            recordingHost.isHidden = true
            muteWidth?.update(offset: 0)
            tab = nil
        }
    }

    private let outerBackground = HoverableView()
    private var segments: [PaneSegment] = []
    /// Seams drawn in the gap between neighbouring segments so the split
    /// always reads as grouped tabs. Mirrors `splitDividerView` in the
    /// horizontal strip. `dividers[i]` sits after `segments[i]`.
    private var dividers: [NSView] = []
    private var statusBadgeHost: TabDecorativeHostingView?
    private var configuredPaneCount = 0
    private var configuredSplitId: String?
    private let splitTabPreviewRegistration = SplitTabPreviewRegistration()
    private var showsSplitTabPreview = false
    private var themeObserver = ThemeObserver.shared
    /// Owning window's BrowserState. Lets the cell re-resolve the pane
    /// order after Chromium reorders the strip (e.g. via the "Reverse
    /// Panes" / "Move Pane" context-menu actions or a drag) — the
    /// `SplitSidebarItem.id` is keyed on the SplitGroup alone so the diff
    /// path treats a strip reorder as a no-op, but the underlying
    /// `normalTabs` adjacency tells us which pane is now where.
    weak var browserState: BrowserState?
    private var hoverTrackingArea: NSTrackingArea?
    private var isCellHovered = false {
        didSet {
            guard oldValue != isCellHovered else { return }
            updateHoverChrome()
        }
    }
    private var isHoverSuppressed = false
    /// Controller that owns the outline view. Routed through so a click
    /// on any segment triggers the same selection flow as a normal tab
    /// click (clears group overview, updates lastSelectedItem, etc.).
    weak var owner: SidebarTabListItemOwner?

    /// Segments currently bound to a pane, in on-screen order.
    private var visibleSegments: ArraySlice<PaneSegment> {
        segments.prefix(configuredPaneCount)
    }

    private var configuredPanes: [Tab] {
        visibleSegments.compactMap(\.tab)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    func handledPaneClick(onMouseDown event: NSEvent) -> Bool {
        visibleSegments.contains { $0.pane.handledClick(onMouseDown: event) }
    }

    @discardableResult
    func handleDoubleClick(with event: NSEvent) -> Bool {
        // Functional controls retain their own actions, including double-clicks.
        for segment in visibleSegments {
            for control in [segment.closeHost, segment.muteHost] where !control.isHidden {
                if control.bounds.contains(control.convert(event.locationInWindow, from: nil)) {
                    return false
                }
            }
        }
        for segment in visibleSegments {
            if segment.pane.bounds.contains(segment.pane.convert(event.locationInWindow, from: nil)) {
                return segment.pane.handleDoubleClick(with: event)
            }
        }
        return false
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        for segment in segments {
            segment.prepareForReuse()
        }
        toolTip = nil
        configuredSplitId = nil
        splitTabPreviewRegistration.invalidate()
        outerBackground.isSelected = false
        isCellHovered = false
        setCloseButtonSpaceReserved(false)
    }

    private func setupViews() {
        themeObserver = ThemeObserver(themeSource: themeStateProvider)
        outerBackground.backgroundColor = .clear
        outerBackground.hoveredColor = NSColor(resource: .sidebarTabHovered)
        outerBackground.selectedColor = NSColor(resource: .sidebarTabSelected)
        outerBackground.enableClickAnimation = false
        outerBackground.responseToClickAction = false
        outerBackground.layer?.cornerRadius = 8
        outerBackground.layer?.cornerCurve = .continuous
        splitTabPreviewRegistration.onEligibilityChanged = { [weak self] isEligible in
            self?.showsSplitTabPreview = isEligible
            self?.updatePaneToolTips()
        }
        addSubview(outerBackground)
        _ = outerBackground.phi.subscribe { [weak self] _, _ in
            self?.updateSelected()
        }
        outerBackground.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(NSEdgeInsets(
                top: 2, left: WebContentConstant.edgesSpacing, bottom: 2, right: WebContentConstant.edgesSpacing))
        }
    }

    /// Returns the segment for pane `index`, creating it (and its divider)
    /// on first use. Segments stay in the view tree across reuse.
    private func segment(at index: Int) -> PaneSegment {
        while segments.count <= index {
            let segmentIndex = segments.count
            let segment = PaneSegment(
                faviconCornerRadius: Self.faviconCornerRadius,
                faviconSize: Self.faviconSize,
                closeTapped: { [weak self] in self?.closeTapped(index: segmentIndex) },
                themeObserver: themeObserver
            )
            configureSegment(segment, index: segmentIndex)
            outerBackground.addSubview(segment.pane)
            segments.append(segment)
            if segmentIndex > 0 {
                let divider = NSView()
                divider.wantsLayer = true
                divider.phiLayer?.setBackgroundColor(ThemedColor.separator)
                outerBackground.addSubview(divider)
                dividers.append(divider)
            }
        }
        return segments[index]
    }

    private func configureSegment(_ segment: PaneSegment, index: Int) {
        let pane = segment.pane
        // Selection is owned by the outer background — the whole cell
        // becomes the white pill when any pane is active, not just the
        // active segment. Leave the segment's own background tints clear
        // so the outer chrome shows through.
        pane.backgroundColor = .clear
        pane.hoveredColor = .clear
        pane.selectedColor = .clear
        pane.enableClickAnimation = false
        pane.responseToClickAction = true
        pane.layer?.cornerRadius = 6
        pane.layer?.cornerCurve = .continuous
        pane.layer?.masksToBounds = false
        pane.shouldClickOnMouseDown = { [weak self] in
            self?.browserState?.multiSelection.isActive != true
        }
        pane.clickAction = { [weak self] in
            self?.handlePaneClick(index: index)
        }
        pane.doubleClickAction = { [weak self] event in
            self?.handlePaneDoubleClick(index: index, event: event)
        }
        // Long titles must defer to the segment's geometric width — without
        // lowering compression resistance, NSTextField's intrinsic width
        // pulls the segment wider than its equal share and the trailing
        // segments shift out of the cell entirely.
        segment.titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        segment.titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pane.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let icon = segment.iconView
        pane.addSubview(icon)
        icon.snp.makeConstraints { make in
            make.centerY.equalToSuperview()
            make.leading.equalToSuperview()
                .offset(index == 0 ? Self.firstIconLeadingSpacing : Self.dividedIconLeadingSpacing)
            make.size.equalTo(CGSize(
                width: Self.faviconSize,
                height: Self.faviconSize
            ))
        }

        pane.addSubview(segment.discardedOutlineHost)
        segment.discardedOutlineHost.snp.makeConstraints { make in
            make.center.equalTo(icon)
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

        // Recording badge sits at the favicon's top-trailing corner, matching
        // `UnifiedTabFaviconView`'s overlay (8pt dot offset out by 3pt).
        // Hosted on the segment rather than the icon so the icon's masked
        // corners don't clip it. Hidden until the pane's tab starts capturing.
        pane.addSubview(segment.recordingHost)
        segment.recordingHost.snp.makeConstraints { make in
            make.top.equalTo(icon.snp.top).offset(-3)
            make.trailing.equalTo(icon.snp.trailing).offset(3)
            make.size.equalTo(CGSize(width: 8, height: 8))
        }

        let title = segment.titleLabel
        title.font = NSFont.systemFont(ofSize: 13)
        title.phi.setTextColor(.textPrimary)
        title.lineBreakMode = .byClipping
        title.maximumNumberOfLines = 1
        title.cell?.lineBreakMode = .byClipping
        title.cell?.truncatesLastVisibleLine = false
        pane.addSubview(title)

        // Mute sits between favicon and title. Width is driven dynamically
        // by the cell so it collapses to 0 when the pane is silent; the
        // 2 / 4 offsets sum to the original 6pt icon→title gap, keeping
        // the silent layout pixel-identical to a normal tab.
        pane.addSubview(segment.muteHost)
        segment.muteHost.snp.makeConstraints { make in
            make.centerY.equalToSuperview()
            make.leading.equalTo(icon.snp.trailing).offset(2)
            make.height.equalTo(20)
            segment.muteWidth = make.width.equalTo(0).constraint
        }

        pane.addSubview(segment.closeHost)
        segment.closeHost.snp.makeConstraints { make in
            make.centerY.equalToSuperview()
            make.trailing.equalToSuperview().offset(-2)
            make.size.equalTo(CGSize(width: Self.closeButtonSize, height: Self.closeButtonSize))
        }

        title.snp.makeConstraints { make in
            make.centerY.equalToSuperview()
            make.leading.equalTo(segment.muteHost.snp.trailing).offset(4)
            // Fill the available region so the trailing fade only overlaps
            // text when the title actually reaches the segment or close
            // button. The title's low compression resistance lets mute/close
            // controls keep their required widths as this region shrinks.
            segment.titlePaneTrailing = make.trailing.equalToSuperview()
                .offset(-Self.titleTrailingSpacing).constraint
            segment.titleCloseTrailing = make.trailing.equalTo(segment.closeHost.snp.leading)
                .offset(-Self.titleTrailingSpacing).constraint
        }
        segment.titleCloseTrailing?.deactivate()
    }

    /// Lays out `count` equal-width segments across the background with a
    /// divider seam in each gap, hiding the rest. Re-run whenever the pane
    /// count changes; a same-count rebind keeps the existing constraints.
    private func applyPaneCountLayout(_ count: Int) {
        guard count != configuredPaneCount else { return }
        configuredPaneCount = count
        for index in 0..<count { _ = segment(at: index) }
        for (index, segment) in segments.enumerated() {
            segment.pane.isHidden = index >= count
            segment.pane.snp.removeConstraints()
        }
        for (index, divider) in dividers.enumerated() {
            divider.isHidden = index >= count - 1
            divider.snp.removeConstraints()
        }
        for index in 0..<count {
            let pane = segments[index].pane
            pane.snp.makeConstraints { make in
                make.top.bottom.equalToSuperview().inset(2)
                if index == 0 {
                    make.leading.equalToSuperview().inset(2)
                } else {
                    make.leading.equalTo(segments[index - 1].pane.snp.trailing)
                        .offset(Self.segmentSpacing)
                    make.width.equalTo(segments[0].pane)
                }
                if index == count - 1 {
                    make.trailing.equalToSuperview().inset(2)
                }
            }
        }
        for index in 0..<(count - 1) {
            dividers[index].snp.makeConstraints { make in
                make.centerX.equalTo(segments[index].pane.snp.trailing)
                    .offset(Self.segmentSpacing / 2)
                make.centerY.equalToSuperview()
                make.width.equalTo(1)
                make.height.equalTo(16)
            }
        }
        installStatusBadge(models: segments.prefix(count).map(\.statusModel))
    }

    /// Treat the split as one tab for chat and agent status. Each pane feeds
    /// its own model, while the merged view applies the shared priority and
    /// renders a single badge on the whole cell.
    private func installStatusBadge(models: [TabStatusModel]) {
        statusBadgeHost?.removeFromSuperview()
        let host = TabDecorativeHostingView(rootView: MergedTabCornerBadgeView(models: models))
        addSubview(host)
        host.snp.makeConstraints { make in
            make.top.trailing.equalTo(outerBackground)
                .inset(-TabCornerBadgeMetrics.overhang)
            make.size.equalTo(CGSize(
                width: TabCornerBadgeMetrics.visualSize,
                height: TabCornerBadgeMetrics.visualSize
            ))
        }
        statusBadgeHost = host
    }

    private func handlePaneDoubleClick(index: Int, event: NSEvent) {
        guard let tab = segments[index].tab else { return }
        cancelTabPreviewForInteraction()
        if !tab.closeOnDoubleClick(modifierFlags: event.modifierFlags) {
            handlePaneClick(index: index)
        }
    }

    private func handlePaneClick(index: Int) {
        guard let tab = segments[index].tab else { return }
        cancelTabPreviewForInteraction()
        let modifierFlags = NSApp.currentEvent?.modifierFlags ?? []
        let panes = configuredPanes
        if panes.count == configuredPaneCount, panes.count >= 2 {
            if owner?.splitPaneClicked(
                panes: panes,
                index: index,
                modifierFlags: modifierFlags) == true {
                return
            }
            // No owner (embedded without the tab-list controller): toggle the
            // whole split in the multi-selection directly.
            if owner == nil,
               modifierFlags.contains(.command),
               browserState?.toggleMultiSelectionForSplit(panes: panes) == true {
                return
            }
        }
        if browserState?.multiSelection.isActive == true {
            browserState?.clearMultiSelection()
        }
        tab.performAction(with: owner)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            splitTabPreviewRegistration.invalidate()
            return
        }
        themeObserver.rebind(to: themeStateProvider)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = hoverTrackingArea {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(false)
    }

    func setHoverSuppressed(_ suppressed: Bool) {
        isHoverSuppressed = suppressed
        outerBackground.isHoverSuppressed = suppressed
        if suppressed {
            setHovered(false)
        }
    }

    func setHovered(_ hovered: Bool) {
        isCellHovered = hovered && !isHoverSuppressed
        splitTabPreviewRegistration.setHovering(isCellHovered)
    }

    private func closeTapped(index: Int) {
        cancelTabPreviewForInteraction()
        guard index < configuredPaneCount else { return }
        segments[index].tab?.close()
    }

    private func updateHoverChrome() {
        setCloseButtonSpaceReserved(isCellHovered)
        for segment in visibleSegments {
            segment.closeHost.isHidden = !isCellHovered
        }
    }

    private func setCloseButtonSpaceReserved(_ reserved: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            CATransaction.begin()
            CATransaction.setDisableActions(true)

            self.applyCloseButtonSpaceReservation(reserved)
            self.outerBackground.layoutSubtreeIfNeeded()

            CATransaction.commit()
        }
    }

    private func applyCloseButtonSpaceReservation(_ reserved: Bool) {
        for segment in segments {
            if reserved {
                segment.titlePaneTrailing?.deactivate()
                segment.titleCloseTrailing?.activate()
            } else {
                segment.titleCloseTrailing?.deactivate()
                segment.titlePaneTrailing?.activate()
            }
        }
    }

    override func configureAppearance() {
        guard let split = item as? SplitSidebarItem else { return }
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
        let panes = split.panes
        guard panes.count >= 2 else { return }
        applyPaneCountLayout(panes.count)
        configuredSplitId = split.groupId
        let state = browserState ?? split.browserState
        for (index, tab) in panes.enumerated() {
            bindSegment(at: index, to: tab, in: state)
        }
        for segment in segments.dropFirst(panes.count) {
            segment.prepareForReuse()
        }
        if let state,
           let target = SplitTabPreviewTarget.make(representing: split.firstPane, in: state) {
            splitTabPreviewRegistration.configure(
                anchorView: self,
                target: target,
                browserState: state,
                placement: .rightTopAttached,
                anchorRectProvider: { view in
                    CGRect(
                        x: view.bounds.minX + WebContentConstant.edgesSpacing,
                        y: view.bounds.minY + 2,
                        width: max(0, view.bounds.width - WebContentConstant.edgesSpacing * 2),
                        height: max(0, view.bounds.height - 4)
                    )
                }
            )
        } else {
            splitTabPreviewRegistration.invalidate()
        }
        toolTip = nil
        updateSelected()
        updateHoverChrome()

        for tab in panes {
            // Subscribe to each tab's audio state and route by tab identity
            // so a post-reorder event lands in the correct segment — the
            // configured segment order changes via
            // `reresolvePaneOrderIfNeeded` without re-creating these
            // subscriptions. Same pattern as the title binding below.
            tab.$isCurrentlyAudible
                .combineLatest(tab.audioMutePublisher)
                .removeDuplicates { $0 == $1 }
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak tab] audible, muted in
                    guard let self, let tab, let index = self.segmentIndex(of: tab) else { return }
                    self.updateMute(index: index, audible: audible, muted: muted)
                }
                .store(in: &cancellables)

            // Same identity-routed binding for the capture flags so each
            // segment's recording badge tracks its own tab, matching a
            // standalone tab.
            Publishers.CombineLatest3(tab.$isCapturingAudio,
                                      tab.$isCapturingVideo,
                                      tab.$isSharingScreen)
                .map { $0 || $1 || $2 }
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak tab] capturing in
                    guard let self, let tab, let index = self.segmentIndex(of: tab) else { return }
                    self.updateRecording(index: index, capturing: capturing)
                }
                .store(in: &cancellables)

            tab.$isActive
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.updateSelected() }
                .store(in: &cancellables)

            tab.$liveFaviconData
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak tab] _ in
                    guard let self, let tab else { return }
                    self.refreshFaviconForTab(tab)
                }
                .store(in: &cancellables)
            tab.$cachedFaviconData
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak tab] _ in
                    guard let self, let tab else { return }
                    self.refreshFaviconForTab(tab)
                }
                .store(in: &cancellables)
            tab.$url
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak tab] _ in
                    guard let self, let tab else { return }
                    self.refreshFaviconForTab(tab)
                }
                .store(in: &cancellables)
            tab.$title
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak tab] newTitle in
                    guard let self, let tab, let index = self.segmentIndex(of: tab) else { return }
                    self.updatePaneTitle(index: index, title: newTitle)
                }
                .store(in: &cancellables)
        }

        // Re-resolve the pane order when the strip order changes (reverse /
        // move-pane actions, drag-to-reorder, etc). The SplitSidebarItem
        // keeps the same id across a reorder so the outline-view diff skips
        // this row; we rebind ourselves instead of waiting for an item-level
        // reload.
        if let state = browserState {
            state.$normalTabs
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.reresolvePaneOrderIfNeeded()
                }
                .store(in: &cancellables)
            state.$multiSelection
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.updateSelected()
                }
                .store(in: &cancellables)
        }
    }

    /// Points segment `index` at `tab`: status model, favicon, title, mute
    /// and recording chrome. Subscriptions are owned by `configureAppearance`
    /// and route by tab identity, so a rebind never touches them.
    private func bindSegment(at index: Int, to tab: Tab, in state: BrowserState?) {
        let segment = segments[index]
        segment.tab = tab
        segment.statusModel.configure(with: tab, in: state)
        refreshFavicon(segment: segment, for: tab)
        updatePaneTitle(index: index, title: tab.title)
        updateMute(index: index, audible: tab.isCurrentlyAudible, muted: tab.isMuted)
        updateRecording(index: index, capturing: tab.isCapturingMedia)
    }

    private func segmentIndex(of tab: Tab) -> Int? {
        visibleSegments.firstIndex { $0.tab === tab }
    }

    private func updatePaneTitle(index: Int, title: String) {
        let label = segments[index].titleLabel
        label.stringValue = title
        label.toolTip = showsSplitTabPreview ? nil : title
    }

    private func updatePaneToolTips() {
        for segment in visibleSegments {
            segment.titleLabel.toolTip = showsSplitTabPreview ? nil : segment.tab?.title
        }
    }

    func cancelTabPreviewForInteraction() {
        splitTabPreviewRegistration.cancelForInteraction()
    }

    private func refreshFaviconForTab(_ tab: Tab) {
        guard let index = segmentIndex(of: tab) else { return }
        refreshFavicon(segment: segments[index], for: tab)
    }

    private func refreshFavicon(segment: PaneSegment, for tab: Tab) {
        segment.faviconHandle?.cancel()
        segment.faviconHandle = nil
        let imageView = segment.iconView
        if let live = tab.liveFaviconData, let image = NSImage(data: live) {
            imageView.image = image
            return
        }
        let pageURLString = tab.isOpenned ? (tab.url ?? tab.pinnedUrl) : (tab.pinnedUrl ?? tab.url)
        let request = ProfileScopedFaviconRequest(
            profileId: tab.profileId,
            pageURLString: pageURLString,
            snapshotData: tab.cachedFaviconData
        )
        segment.faviconHandle = ProfileScopedFaviconRepository.shared.loadFavicon(for: request) { [weak imageView, weak tab] result in
            imageView?.image = result.image
            if result.source == .chromium, let data = result.data {
                tab?.updateProfileScopedFaviconData(
                    data,
                    sourceURLString: request.pageURLString
                )
            }
        }
    }

    /// Show or hide a segment's mute toggle based on its tab's audio state.
    /// Mirrors the audible-or-muted condition `SideTabView` uses for the
    /// regular sidebar row so split panes match unsplit panes visually.
    private func updateMute(index: Int, audible: Bool, muted: Bool) {
        let hasAudio = audible || muted
        let segment = segments[index]
        segment.muteHost.isHidden = !hasAudio
        segment.muteWidth?.update(offset: hasAudio ? 20 : 0)
        guard hasAudio else { return }
        segment.muteHost.rootView = AnyView(
            SplitPaneMuteButton(isMuted: muted) { [weak self] in
                guard let self, index < self.configuredPaneCount,
                      let tab = self.segments[index].tab else { return }
                tab.toggleAudioMuted()
            }
            .phiThemeObserver(themeObserver)
        )
    }

    /// Show or hide a segment's recording badge based on its tab's capture
    /// state. Mirrors the corner badge a standalone tab shows via
    /// `UnifiedTabFaviconView` so split panes match unsplit panes.
    private func updateRecording(index: Int, capturing: Bool) {
        segments[index].recordingHost.isHidden = !capturing
    }

    /// Test seam: whether the segment for pane `paneIndex` currently shows
    /// its recording badge.
    func isRecordingIndicatorVisible(paneIndex: Int) -> Bool {
        guard paneIndex < configuredPaneCount else { return false }
        return !segments[paneIndex].recordingHost.isHidden
    }

    /// Test seam: current memory-reclaimed opacity for the given pane's favicon.
    func faviconOpacity(paneIndex: Int) -> CGFloat {
        guard paneIndex < configuredPaneCount else { return 1 }
        return segments[paneIndex].iconView.alphaValue
    }

    private func updateSelected() {
        guard let split = item as? SplitSidebarItem else { return }
        // Match SideTabView: active split rows use the regular selected
        // fill, while temporary multi-selection uses the sub-selected fill.
        let state = browserState ?? split.browserState
        let isBookmarkSelected = split.boundBookmarkGuid(in: state).map {
            state?.multiSelection.containsBookmark($0) == true
        } ?? false
        let isMultiSelected = split.panes.contains { state?.multiSelection.contains($0.guid) == true }
            || isBookmarkSelected
        let isActive = split.panes.contains { $0.isActive }
        outerBackground.selectedColor = isActive
            ? NSColor(resource: .sidebarTabSelected)
            : ThemedColor.tabSubSelectionBackground.resolve(in: outerBackground)
        outerBackground.isSelected = isActive || isMultiSelected
    }

    /// Re-binds the cell when the split's membership changed in place — a
    /// drag-to-replace, pane add or pane remove mutates the cached
    /// `SplitSidebarItem` while the row id survives, so the outline diff
    /// never reloads this row. `reresolvePaneOrderIfNeeded` below only
    /// covers reorders of the already-bound tabs; identity drift needs the
    /// full re-bind so the title/favicon/audio subscriptions attach to the
    /// new Tabs. Driven by
    /// `SidebarTabListViewController.pushPaneUpdatesToSplitCells`.
    func rebindPanesIfNeeded() {
        guard let split = item as? SplitSidebarItem else { return }
        let configured = configuredPanes
        guard split.panes.count != configured.count
                || zip(split.panes, configured).contains(where: { $0.0 !== $0.1 }) else {
            return
        }
        configureAppearance()
    }

    /// If Chromium reordered the panes (reverse / move-pane actions, drag),
    /// reflect the new order in the cell. The SplitGroup's slot order
    /// updates first; the strip's `normalTabs` then re-sequences. We compare
    /// the cell's current order against the live `normalTabs` order and
    /// re-sequence the segments if the visible mapping is stale.
    private func reresolvePaneOrderIfNeeded() {
        guard let split = item as? SplitSidebarItem,
              let state = browserState else { return }
        // A pane added or removed reaches the cached item before this cell
        // has segments for it, and a reorder only re-sequences bound panes.
        guard split.panes.count == configuredPanes.count else {
            rebindPanesIfNeeded()
            return
        }
        var indices: [Int] = []
        for pane in split.panes {
            guard let index = state.normalTabs.firstIndex(where: { $0.guid == pane.guid }) else { return }
            indices.append(index)
        }
        guard indices != indices.sorted() else { return }
        let ordered = zip(indices, split.panes).sorted { $0.0 < $1.0 }.map(\.1)
        split.panes = ordered
        for (index, tab) in ordered.enumerated() {
            bindSegment(at: index, to: tab, in: split.browserState)
        }
        updateSelected()
    }
}

// MARK: - Farringdon Organize Completion

extension Notification.Name {
    /// Posted (main thread) when a Farringdon "organize tabs" run is triggered by
    /// the keyboard shortcut (the broom button starts its own animation directly),
    /// so the broom button can show its in-progress animation.
    static let farringdonOrganizeDidStart = Notification.Name("farringdonOrganizeDidStart")

    /// Posted (main thread) when the Kensington extension reports that a
    /// Farringdon "organize tabs" run has finished, so the broom button can stop
    /// its in-progress animation. Carries no payload — the only animating button
    /// is the one in the window the user clicked.
    static let farringdonOrganizeDidFinish = Notification.Name("farringdonOrganizeDidFinish")
}

/// Single entry point for triggering a Farringdon "organize tabs" run. Posts the
/// start notification (so any visible broom button animates) and broadcasts the
/// request to the Kensington extension, which resolves the focused window itself.
/// Used by the sidebar broom, the horizontal-tab broom, and the keyboard shortcut.
enum FarringdonOrganizer {
    /// Organizing a handful of pages isn't worth a Farringdon run, so the broom
    /// only appears once the current Space has more eligible pages than this.
    static let minimumEligibleTabCount = 7

    static func isTabCountEligible(_ tabCount: Int) -> Bool {
        tabCount > minimumEligibleTabCount
    }

    static func eligibleTabCount(in tabs: [Tab]) -> Int {
        tabs.lazy.filter { !$0.isLocalPage }.count
    }

    static func canOrganizeTabs(phiAIEnabled: Bool,
                                isIncognito: Bool,
                                eligibleTabCount: Int) -> Bool {
        phiAIEnabled && !isIncognito && isTabCountEligible(eligibleTabCount)
    }

    static func canOrganizeTabs(in browserState: BrowserState) -> Bool {
        canOrganizeTabs(
            phiAIEnabled: PhiPreferences.AISettings.phiAIEnabled.loadValue(),
            isIncognito: browserState.isIncognito,
            eligibleTabCount: eligibleTabCount(in: browserState.normalTabs)
        )
    }

    @MainActor
    static func organizeFocusedWindow(eligibleTabCount: Int? = nil) {
        // Buttons and shortcuts share the same eligibility gate; this is the
        // backstop for hidden UI and direct command dispatch.
        guard let state = SpaceSessionControllersManager.shared.getActiveWindowState() else {
            return
        }
        let count = eligibleTabCount ?? Self.eligibleTabCount(in: state.normalTabs)
        guard canOrganizeTabs(
            phiAIEnabled: PhiPreferences.AISettings.phiAIEnabled.loadValue(),
            isIncognito: state.isIncognito,
            eligibleTabCount: count
        ) else { return }
        NotificationCenter.default.post(name: .farringdonOrganizeDidStart, object: nil)
        ExtensionMessaging.shared.broadcast(type: "farringdon.toggleTabs", payload: "{}")
    }
}

enum BroomAnimation {
    static let minimumPlaybackDuration =
        LottieAnimation.named(
            "broom",
            bundle: .main,
            subdirectory: "LottieFiles"
        )?.duration ?? 1.5
}

// MARK: - Sidebar Cleanup Button

/// Both separator actions share AppKit hover rendering. Lottie only draws the
/// icon: organizing loops while a run is active, and clearing plays on click.
final class SidebarCleanupButton: NSButton {
    enum Kind: String {
        case organize = "broom"
        case clear = "clear-tabs"
    }

    let kind: Kind
    private var trackingArea: NSTrackingArea?
    private var isHovering = false { didSet { updateAppearance() } }
    private(set) var isOrganizing = false
    private var organizeStartedAt: Date?
    private var safetyTimer: Timer?
    private var clearPlaybackID: UUID?

    // Matches the 24x24 frame used by `UnifiedTabCloseButton` in `SideTabView`.
    static let buttonSize: CGFloat = 24

    private static let cornerRadius: CGFloat = 4
    private static let safetyTimeout: TimeInterval = 8.0

    private lazy var animationView: LottieAnimationNSView = {
        let config = LottieAnimationViewConfig(
            animationName: kind.rawValue,
            size: CGSize(width: Self.buttonSize, height: Self.buttonSize),
            animationTrigger: .manual,
            themedTintColor: .textMuted,
            loopMode: kind == .organize ? .loop : .playOnce,
            allowsHitTesting: false
        )
        return LottieAnimationNSView(config: config)
    }()

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        configure()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        safetyTimer?.invalidate()
    }

    private func configure() {
        isBordered = false
        bezelStyle = .shadowlessSquare
        title = ""
        attributedTitle = NSAttributedString(string: "")
        alternateTitle = ""
        setButtonType(.momentaryChange)
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.cornerCurve = .continuous
        addSubview(animationView)
        animationView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        updateAppearance()
        guard kind == .organize else { return }
        toolTip = NSLocalizedString("sidebar.newTabRow.aiOrganizeTooltip", value: "Organize tabs with AI",
            comment: "Sidebar separator - Organize tabs button tooltip")
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOrganizeDidStart),
            name: .farringdonOrganizeDidStart,
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOrganizeDidFinish),
            name: .farringdonOrganizeDidFinish,
            object: nil)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
        updateHoverForCurrentMouseLocation()
    }

    override var isHidden: Bool {
        didSet { updateHoverForCurrentMouseLocation() }
    }

    private func updateHoverForCurrentMouseLocation() {
        guard let window, !isHiddenOrHasHiddenAncestor else {
            isHovering = false
            return
        }
        isHovering = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isEnabled, !isHidden, alphaValue > 0, bounds.contains(convert(point, from: superview)) else {
            return nil
        }
        return self
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovering = false
    }

    private func updateAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.backgroundColor = isHovering
                ? NSColor(resource: .sidebarTabHovered).cgColor
                : NSColor.clear.cgColor
            CATransaction.commit()
        }
    }

    func playClearAnimation(completion: @escaping () -> Void) {
        guard kind == .clear, clearPlaybackID == nil else { return }
        let playbackID = UUID()
        clearPlaybackID = playbackID
        animationView.triggerAnimation { [weak self] completed in
            guard let self, self.clearPlaybackID == playbackID else { return }
            self.clearPlaybackID = nil
            if completed { completion() }
        }
    }

    func cancelClearAnimation() {
        guard clearPlaybackID != nil else { return }
        clearPlaybackID = nil
        animationView.stopAnimation()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { cancelClearAnimation() }
    }

    // MARK: Organizing animation

    func startOrganizing() {
        guard kind == .organize, !isOrganizing else { return }
        isOrganizing = true
        organizeStartedAt = Date()
        animationView.triggerAnimation()

        // Stop even if the completion signal never arrives.
        safetyTimer?.invalidate()
        safetyTimer = Timer.scheduledTimer(
            withTimeInterval: Self.safetyTimeout, repeats: false
        ) { [weak self] _ in
            self?.stopOrganizing()
        }
    }

    func stopOrganizing() {
        guard isOrganizing else { return }
        safetyTimer?.invalidate()
        safetyTimer = nil

        // Complete at least one full playback even when the organize run finishes immediately.
        let elapsed = organizeStartedAt.map { Date().timeIntervalSince($0) }
            ?? BroomAnimation.minimumPlaybackDuration
        let remaining = max(0, BroomAnimation.minimumPlaybackDuration - elapsed)
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
            guard let self, self.isOrganizing else { return }
            self.isOrganizing = false
            self.organizeStartedAt = nil
            self.animationView.stopAnimation()
        }
    }

    @objc private func handleOrganizeDidStart() {
        // Only the window that triggered the run (the key window) animates —
        // and in it only the Space on screen: every Space's sidebar is
        // resident, hidden, in the shared shell.
        guard !isHiddenOrHasHiddenAncestor, window?.isKeyWindow == true else { return }
        startOrganizing()
    }

    @objc private func handleOrganizeDidFinish() {
        stopOrganizing()
    }
}

// MARK: - New Tab Button Cell View
class NewTabButtonCellView: SidebarCellView {
    var clickAction: (() -> Void)?
    private var iconHoverState = false
    private var didPlayForwardAnimationForCurrentHover = false

    private lazy var iconView: LottieAnimationNSView = {
        let config = LottieAnimationViewConfig(
            animationName: "new-tab",
            reverseAnimationName: "new-tab-reverse",
            size: CGSize(width: 16, height: 16),
            animationTrigger: .manual,
            themedTintColor: .textTertiary,
            reverseOnHoverExit: true,
            allowsHitTesting: false
        )
        return LottieAnimationNSView(config: config)
    }()

    private var titleLabel: NSTextField = {
        let titleLabel = NSTextField(labelWithString: NSLocalizedString("sidebar.newTabRow.title", value: "New Tab", comment: "side bar new tab button text"))
        titleLabel.font = NSFont.systemFont(ofSize: 13)
        titleLabel.phi.setTextColor(.textTertiary)
        return titleLabel
    }()
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        iconHoverState = false
        didPlayForwardAnimationForCurrentHover = false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard clickAction != nil, bounds.contains(point) else {
            return super.hitTest(point)
        }
        return self
    }

    override func mouseUp(with event: NSEvent) {
        guard let clickAction else {
            super.mouseUp(with: event)
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        clickAction()
    }
    
    private func setupViews() {
        addSubview(backgoundView)
        backgoundView.shadow = nil
        backgoundView.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(WebContentConstant.edgesSpacing)
            make.top.bottom.equalToSuperview().inset(2)
        }
        backgoundView.enableClickAnimation = false
        backgoundView.layer?.cornerRadius = 8
        backgoundView.layer?.cornerCurve = .continuous
        backgoundView.backgroundColor = .clear
        backgoundView.hoveredColor = NSColor(resource: .sidebarTabHovered)
        backgoundView.hoverStateChanged = { [weak self] hovered in
            guard let self else { return }
            AppLogDebug("hover changed: \(hovered) - \(self.backgoundView.responseToHoverAnimation)")
            let shouldAnimate = self.backgoundView.responseToHoverAnimation
            let hoverChanged = hovered != self.iconHoverState
            self.iconHoverState = hovered

            guard shouldAnimate, hoverChanged else {
                return
            }
            if hovered {
                self.didPlayForwardAnimationForCurrentHover = true
                self.iconView.triggerAnimation()
            } else if self.didPlayForwardAnimationForCurrentHover {
                self.didPlayForwardAnimationForCurrentHover = false
                self.iconView.triggerReverseAnimation()
            }
        }
       
        backgoundView.addSubview(iconView)
        backgoundView.addSubview(titleLabel)

        iconView.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(6)
            make.centerY.equalToSuperview()
            make.size.equalTo(16)
        }

        titleLabel.snp.makeConstraints { make in
            make.leading.equalTo(iconView.snp.trailing).offset(8)
            make.trailing.lessThanOrEqualToSuperview().inset(8)
            make.centerY.equalToSuperview()
        }
    }
}

// MARK: - Separator Cell View
class SeparatorCellView: SidebarCellView {
    /// Triggers the Farringdon "organize tabs with AI" action. When nil, the
    /// trailing broom button is hidden.
    var cleanupAction: (() -> Void)? {
        didSet { updateButtonVisibility() }
    }

    private lazy var cleanupButton: SidebarCleanupButton = {
        let button = SidebarCleanupButton(kind: .organize)
        button.target = self
        button.action = #selector(cleanupButtonClicked)
        button.isHidden = true
        return button
    }()

    private func updateButtonVisibility() {
        // Sidebar updates can arrive inside an outline animation transaction.
        // Visibility and the adjacent line must still change immediately.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for view in [cleanupButton, clearTabsButton, separatorView] {
                view.layer?.removeAllAnimations()
            }
            cleanupButton.isHidden = cleanupAction == nil
            clearTabsButton.isHidden = clearTabsAction == nil
            updateSeparatorWidth()
            layoutSubtreeIfNeeded()
            CATransaction.commit()
        }
    }

    @objc private func cleanupButtonClicked() {
        guard !cleanupButton.isOrganizing, let cleanupAction else { return }
        // `cleanupAction` triggers the organize run, which posts
        // `.farringdonOrganizeDidStart`; the button animates via that observer.
        FeatureEntryAnalytics.capture(.organizeTabs, surface: .sidebar)
        cleanupAction()
    }

    @objc private func clearTabsButtonClicked() {
        guard let clearTabsAction else { return }
        clearTabsButton.playClearAnimation(completion: clearTabsAction)
    }

    var clearTabsAction: (() -> Void)? {
        didSet { updateButtonVisibility() }
    }

    private let separatorView = NSView()
    private lazy var clearTabsButton: SidebarCleanupButton = {
        let button = SidebarCleanupButton(kind: .clear)
        button.target = self
        button.action = #selector(clearTabsButtonClicked)
        button.toolTip = NSLocalizedString("sidebar.separator.clearTabsTooltip", value: "Clear unselected tabs", comment: "Sidebar separator - Close background ordinary tabs, keeping the currently displayed tab or split")
        button.setAccessibilityLabel(button.toolTip)
        button.isHidden = true
        return button
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        clearTabsButton.cancelClearAnimation()
        cleanupAction = nil
        clearTabsAction = nil
        cleanupButton.stopOrganizing()
    }

    private func updateSeparatorWidth() {
        guard separatorView.superview != nil else { return }
        separatorView.snp.updateConstraints { make in
            make.trailing.equalToSuperview().inset(
                WebContentConstant.edgesSpacing + (cleanupAction != nil ? 64 : clearTabsAction != nil ? 36 : 0))
        }
    }

    private func setupViews() {
        separatorView.wantsLayer = true
        separatorView.phiLayer?.setBackgroundColor(.separator)
        addSubview(separatorView)
        addSubview(cleanupButton)
        addSubview(clearTabsButton)
        separatorView.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(WebContentConstant.edgesSpacing)
            make.centerY.equalToSuperview()
            make.height.equalTo(1)
        }
        clearTabsButton.snp.makeConstraints { make in
            make.trailing.equalToSuperview().inset(WebContentConstant.edgesSpacing + 4)
            make.centerY.equalToSuperview()
            make.size.equalTo(24)
        }
        cleanupButton.snp.makeConstraints { make in
            make.trailing.equalTo(clearTabsButton.snp.leading).offset(-4)
            make.centerY.equalToSuperview()
            make.size.equalTo(SidebarCleanupButton.buttonSize)
        }
    }
}

protocol TabCellDelegate: AnyObject {
    func tabCellDidRequestClose(_ tab: Tab)
}

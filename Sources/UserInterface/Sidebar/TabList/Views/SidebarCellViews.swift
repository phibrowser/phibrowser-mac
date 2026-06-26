// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Combine
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
        
        guard let snapshot = targetView.createDraggingSnapshot() else {
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
class SidebarTabCellView: SidebarCellView {
    private var hostingView: ThemedHostingView!
    private let hoverRegionView = SidebarTabHoverRegionView()
    private let hoverDeadZoneView = SidebarTabHoverDeadZoneView()
    private let viewModel = TabViewModel()
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
        configuredTab = nil
        activeSuppressed = false
    }

    /// Cancel Combine subscriptions without resetting visual state.
    /// Used before reloadData to prevent orphan events while keeping
    /// the current frame on screen (avoids blank-frame flicker).
    func invalidateSubscriptions() {
        viewModel.cancelSubscriptions()
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
    }

    func setHoverSuppressed(_ suppressed: Bool) {
        viewModel.setHoverSuppressed(suppressed)
    }

    func setHovered(_ hovered: Bool) {
        viewModel.setHovered(hovered)
    }

    func setActiveSuppressed(_ suppressed: Bool) {
        activeSuppressed = suppressed
        viewModel.setActiveSuppressed(suppressed, activeValue: configuredTab?.isActive ?? false)
    }
    
    private func setupViews() {
        hostingView = ThemedHostingView(rootView: SideTabView(model: viewModel) { [weak self] in
            self?.closeButtonTapped()
        })
        addSubview(hostingView)
        hostingView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        hoverRegionView.onHoverChanged = { [weak self] isHovered in
            self?.viewModel.isHovered = isHovered
        }
        addSubview(hoverRegionView)
        hoverRegionView.snp.makeConstraints { make in
            make.leading.top.bottom.equalToSuperview()
            make.trailing.equalToSuperview().inset(SideTabView.trailingHoverDeadZoneWidth)
        }

        hoverDeadZoneView.onEntered = { [weak self] in
            self?.viewModel.isHovered = false
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
        delegate?.tabCellDidRequestClose(tab)
    }

    override func configureAppearance() {
        guard let tab = item as? Tab else { return }
        configuredTab = tab
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()

        let state = MainBrowserWindowControllersManager.shared
            .controller(for: tab.windowId)?.browserState
        viewModel.configure(with: tab, in: state)
        viewModel.setActiveSuppressed(activeSuppressed, activeValue: tab.isActive)
        viewModel.onToggleMute = { [weak tab] in
            guard let tab else { return }
            tab.setAudioMuted(!tab.isAudioMuted)
        }
    }
}

// MARK: - Split Pair Cell View
/// Sidebar row representing a non-pinned split as a single merged cell.
/// Two halves stand side-by-side inside one rounded background; each
/// half shows its favicon, title, and an x close button that appears on
/// cell hover. The pane whose tab is focused gets a solid white pill,
/// the other half stays at the cell-level hover tint.
class SidebarSplitPairCellView: SidebarCellView {
    private static let closeButtonSize: CGFloat = 24
    private static let titleTrailingSpacing: CGFloat = 5
    private let outerBackground = HoverableView()
    private let leftPane = HoverableView()
    private let rightPane = HoverableView()
    private let leftIconView = NSImageView()
    private let rightIconView = NSImageView()
    private let leftTitleLabel = TrailingFadeTextField()
    private let rightTitleLabel = TrailingFadeTextField()
    private var leftCloseHost: ZeroSafeAreaHostingView<AnyView>!
    private var rightCloseHost: ZeroSafeAreaHostingView<AnyView>!
    private var leftMuteHost: ZeroSafeAreaHostingView<AnyView>!
    private var rightMuteHost: ZeroSafeAreaHostingView<AnyView>!
    /// Per-pane recording badge overlaid on each pane's favicon. Mirrors the
    /// corner badge `UnifiedTabFaviconView` draws on a normal tab so a split
    /// pane using the microphone / camera / screen share reads the same.
    private var leftRecordingHost: ZeroSafeAreaHostingView<AnyView>!
    private var rightRecordingHost: ZeroSafeAreaHostingView<AnyView>!
    private var leftMuteWidth: Constraint?
    private var rightMuteWidth: Constraint?
    private var leftTitlePaneTrailing: Constraint?
    private var leftTitleCloseTrailing: Constraint?
    private var rightTitlePaneTrailing: Constraint?
    private var rightTitleCloseTrailing: Constraint?
    private let dividerView = NSView()
    private var themeObserver = ThemeObserver.shared
    private var leftFaviconHandle: ProfileScopedFaviconLoadHandle?
    private var rightFaviconHandle: ProfileScopedFaviconLoadHandle?
    private weak var configuredLeftTab: Tab?
    private weak var configuredRightTab: Tab?
    private var configuredSplitId: String?
    /// Owning window's BrowserState. Lets the cell re-resolve which pane
    /// is "left" after Chromium reorders the strip (e.g. via the
    /// "Reverse Panes" context-menu action or a drag) — the
    /// `SplitPairSidebarItem.id` is keyed on the SplitGroup alone so the
    /// diff path treats a strip swap as a no-op, but the underlying
    /// `normalTabs` adjacency tells us which guid is now first.
    weak var browserState: BrowserState?
    private var hoverTrackingArea: NSTrackingArea?
    private var isCellHovered = false {
        didSet {
            guard oldValue != isCellHovered else { return }
            updateHoverChrome()
        }
    }
    /// Controller that owns the outline view. Routed through so a click
    /// on either half triggers the same selection flow as a normal tab
    /// click (clears group overview, updates lastSelectedItem, etc.).
    weak var owner: SidebarTabListItemOwner?

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
        leftFaviconHandle?.cancel()
        leftFaviconHandle = nil
        rightFaviconHandle?.cancel()
        rightFaviconHandle = nil
        leftIconView.image = nil
        rightIconView.image = nil
        leftTitleLabel.stringValue = ""
        rightTitleLabel.stringValue = ""
        leftTitleLabel.toolTip = nil
        rightTitleLabel.toolTip = nil
        toolTip = nil
        configuredLeftTab = nil
        configuredRightTab = nil
        configuredSplitId = nil
        outerBackground.isSelected = false
        isCellHovered = false
        setCloseButtonSpaceReserved(false)
        leftCloseHost.isHidden = true
        rightCloseHost.isHidden = true
        leftMuteHost.isHidden = true
        rightMuteHost.isHidden = true
        leftRecordingHost.isHidden = true
        rightRecordingHost.isHidden = true
        leftMuteWidth?.update(offset: 0)
        rightMuteWidth?.update(offset: 0)
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
        addSubview(outerBackground)
        outerBackground.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(NSEdgeInsets(
                top: 2, left: WebContentConstant.edgesSpacing, bottom: 2, right: WebContentConstant.edgesSpacing))
        }

        // Match normal-tab close buttons (24x24 with rounded hover fill) by
        // reusing `UnifiedTabCloseButton`. Hosted inside each pane so the
        // SwiftUI button receives its own hover events independently.
        leftCloseHost = ZeroSafeAreaHostingView(rootView: AnyView(
            UnifiedTabCloseButton { [weak self] in self?.leftCloseTapped() }
                .phiThemeObserver(themeObserver)
        ))
        rightCloseHost = ZeroSafeAreaHostingView(rootView: AnyView(
            UnifiedTabCloseButton { [weak self] in self?.rightCloseTapped() }
                .phiThemeObserver(themeObserver)
        ))
        leftCloseHost.isHidden = true
        rightCloseHost.isHidden = true

        // Per-pane mute toggles. Hidden + zero width by default so the
        // title fills the same space as before when no audio is present;
        // shown with 20pt width when the pane's tab is audible or muted.
        leftMuteHost = ZeroSafeAreaHostingView(rootView: AnyView(EmptyView()))
        rightMuteHost = ZeroSafeAreaHostingView(rootView: AnyView(EmptyView()))
        leftMuteHost.isHidden = true
        rightMuteHost.isHidden = true

        // Recording badges. Static content (the pulsing red dot); only their
        // visibility is toggled, so the root view is built once here.
        leftRecordingHost = ZeroSafeAreaHostingView(rootView: AnyView(
            UnifiedTabRecordingIcon().phiThemeObserver(themeObserver)))
        rightRecordingHost = ZeroSafeAreaHostingView(rootView: AnyView(
            UnifiedTabRecordingIcon().phiThemeObserver(themeObserver)))
        leftRecordingHost.isHidden = true
        rightRecordingHost.isHidden = true

        leftMuteWidth = configurePane(leftPane,
                                      icon: leftIconView,
                                      title: leftTitleLabel,
                                      mute: leftMuteHost,
                                      recording: leftRecordingHost,
                                      close: leftCloseHost,
                                      paneTrailing: &leftTitlePaneTrailing,
                                      closeTrailing: &leftTitleCloseTrailing)
        rightMuteWidth = configurePane(rightPane,
                                       icon: rightIconView,
                                       title: rightTitleLabel,
                                       mute: rightMuteHost,
                                       recording: rightRecordingHost,
                                       close: rightCloseHost,
                                       paneTrailing: &rightTitlePaneTrailing,
                                       closeTrailing: &rightTitleCloseTrailing)
        outerBackground.addSubview(leftPane)
        outerBackground.addSubview(rightPane)

        leftPane.snp.makeConstraints { make in
            make.top.bottom.leading.equalToSuperview().inset(2)
            make.width.equalTo(rightPane)
        }
        rightPane.snp.makeConstraints { make in
            make.top.bottom.trailing.equalToSuperview().inset(2)
            make.leading.equalTo(leftPane.snp.trailing).offset(2)
        }
        // Long titles must defer to the pane's geometric width — without
        // lowering compression resistance, NSTextField's intrinsic width
        // pulls the pane past `centerX` and the right pane shifts out
        // of the cell entirely.
        leftTitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        rightTitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        leftTitleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        rightTitleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        leftPane.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        rightPane.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        leftPane.clickAction = { [weak self] in
            guard let self, let tab = self.configuredLeftTab else { return }
            tab.performAction(with: self.owner)
        }
        rightPane.clickAction = { [weak self] in
            guard let self, let tab = self.configuredRightTab else { return }
            tab.performAction(with: self.owner)
        }

        // Vertical seam in the gap between the two panes so the pair
        // always reads as two grouped tabs. Mirrors `splitDividerView`
        // in the horizontal strip.
        dividerView.wantsLayer = true
        dividerView.phiLayer?.setBackgroundColor(ThemedColor.separator)
        outerBackground.addSubview(dividerView)
        dividerView.snp.makeConstraints { make in
            make.centerX.equalTo(outerBackground.snp.centerX)
            make.centerY.equalToSuperview()
            make.width.equalTo(1)
            make.height.equalTo(16)
        }
    }

    @discardableResult
    private func configurePane(_ pane: HoverableView,
                               icon: NSImageView,
                               title: NSTextField,
                               mute: NSView,
                               recording: NSView,
                               close: NSView,
                               paneTrailing: inout Constraint?,
                               closeTrailing: inout Constraint?) -> Constraint? {
        // Selection is owned by the outer background — the whole cell
        // becomes the white pill when either pane is active, not just
        // the active half. Leave the pane's own background tints clear
        // so the outer chrome shows through.
        pane.backgroundColor = .clear
        pane.hoveredColor = .clear
        pane.selectedColor = .clear
        pane.enableClickAnimation = false
        pane.responseToClickAction = true
        pane.layer?.cornerRadius = 6
        pane.layer?.cornerCurve = .continuous

        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.wantsLayer = true
        icon.layer?.cornerRadius = 3
        icon.layer?.masksToBounds = true
        pane.addSubview(icon)
        icon.snp.makeConstraints { make in
            make.centerY.equalToSuperview()
            make.leading.equalToSuperview().offset(8)
            make.size.equalTo(CGSize(width: 16, height: 16))
        }

        // Recording badge sits at the favicon's top-trailing corner, matching
        // `UnifiedTabFaviconView`'s overlay (8pt dot offset out by 3pt).
        // Hosted on the pane rather than the icon so the icon's masked corners
        // don't clip it. Hidden until the pane's tab starts capturing.
        pane.addSubview(recording)
        recording.snp.makeConstraints { make in
            make.top.equalTo(icon.snp.top).offset(-3)
            make.trailing.equalTo(icon.snp.trailing).offset(3)
            make.size.equalTo(CGSize(width: 8, height: 8))
        }

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
        // the silent layout pixel-identical to before.
        pane.addSubview(mute)
        var muteWidthConstraint: Constraint?
        mute.snp.makeConstraints { make in
            make.centerY.equalToSuperview()
            make.leading.equalTo(icon.snp.trailing).offset(2)
            make.height.equalTo(20)
            muteWidthConstraint = make.width.equalTo(0).constraint
        }

        pane.addSubview(close)
        close.snp.makeConstraints { make in
            make.centerY.equalToSuperview()
            make.trailing.equalToSuperview().offset(-2)
            make.size.equalTo(CGSize(width: Self.closeButtonSize, height: Self.closeButtonSize))
        }

        title.snp.makeConstraints { make in
            make.centerY.equalToSuperview()
            make.leading.equalTo(mute.snp.trailing).offset(4)
            paneTrailing = make.trailing.lessThanOrEqualToSuperview().offset(-Self.titleTrailingSpacing).constraint
            closeTrailing = make.trailing.lessThanOrEqualTo(close.snp.leading).offset(-Self.titleTrailingSpacing).constraint
        }
        closeTrailing?.deactivate()

        return muteWidthConstraint
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
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
        isCellHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isCellHovered = false
    }

    private func leftCloseTapped() {
        configuredLeftTab?.close()
    }

    private func rightCloseTapped() {
        configuredRightTab?.close()
    }

    private func updateHoverChrome() {
        setCloseButtonSpaceReserved(isCellHovered)
        leftCloseHost.isHidden = !isCellHovered
        rightCloseHost.isHidden = !isCellHovered
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
        if reserved {
            leftTitlePaneTrailing?.deactivate()
            rightTitlePaneTrailing?.deactivate()
            leftTitleCloseTrailing?.activate()
            rightTitleCloseTrailing?.activate()
        } else {
            leftTitleCloseTrailing?.deactivate()
            rightTitleCloseTrailing?.deactivate()
            leftTitlePaneTrailing?.activate()
            rightTitlePaneTrailing?.activate()
        }
    }

    override func configureAppearance() {
        guard let pair = item as? SplitPairSidebarItem else { return }
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
        configuredLeftTab = pair.leftTab
        configuredRightTab = pair.rightTab
        configuredSplitId = pair.groupId

        refreshFavicon(into: leftIconView, for: pair.leftTab, handle: &leftFaviconHandle)
        refreshFavicon(into: rightIconView, for: pair.rightTab, handle: &rightFaviconHandle)
        updatePaneTitles(leftTitle: pair.leftTab.title, rightTitle: pair.rightTab.title)
        updateSelected()
        updateHoverChrome()
        updateMute(isLeft: true,
                   audible: pair.leftTab.isCurrentlyAudible,
                   muted: pair.leftTab.isAudioMuted)
        updateMute(isLeft: false,
                   audible: pair.rightTab.isCurrentlyAudible,
                   muted: pair.rightTab.isAudioMuted)
        updateRecording(isLeft: true, capturing: pair.leftTab.isCapturingMedia)
        updateRecording(isLeft: false, capturing: pair.rightTab.isCapturingMedia)

        // Subscribe to each tab's audio state and route by tab identity so a
        // post-swap event lands in the correct pane — the configured left/right
        // mapping changes via `reresolvePairOrderIfNeeded` without re-creating
        // these subscriptions. Same pattern as the title binding above.
        for tab in [pair.leftTab, pair.rightTab] {
            tab.$isCurrentlyAudible
                .combineLatest(tab.$isAudioMuted)
                .removeDuplicates { $0 == $1 }
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak tab] audible, muted in
                    guard let self, let tab else { return }
                    if tab === self.configuredLeftTab {
                        self.updateMute(isLeft: true, audible: audible, muted: muted)
                    } else if tab === self.configuredRightTab {
                        self.updateMute(isLeft: false, audible: audible, muted: muted)
                    }
                }
                .store(in: &cancellables)
        }

        // Same identity-routed binding for the capture flags so each pane's
        // recording badge tracks its own tab, matching a standalone tab.
        for tab in [pair.leftTab, pair.rightTab] {
            Publishers.CombineLatest3(tab.$isCapturingAudio,
                                      tab.$isCapturingVideo,
                                      tab.$isSharingScreen)
                .map { $0 || $1 || $2 }
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak tab] capturing in
                    guard let self, let tab else { return }
                    if tab === self.configuredLeftTab {
                        self.updateRecording(isLeft: true, capturing: capturing)
                    } else if tab === self.configuredRightTab {
                        self.updateRecording(isLeft: false, capturing: capturing)
                    }
                }
                .store(in: &cancellables)
        }

        Publishers.CombineLatest(pair.leftTab.$isActive, pair.rightTab.$isActive)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.updateSelected() }
            .store(in: &cancellables)

        // Re-resolve left/right when the strip order changes (swap button,
        // drag-to-reorder, etc). The SplitPairSidebarItem keeps the same id
        // across a swap so the outline-view diff skips this row; we rebind
        // ourselves instead of waiting for an item-level reload.
        if let state = browserState {
            state.$normalTabs
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.reresolvePairOrderIfNeeded()
                }
                .store(in: &cancellables)
        }

        for tab in [pair.leftTab, pair.rightTab] {
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
                    guard let self, let tab else { return }
                    if tab === self.configuredLeftTab {
                        self.updatePaneTitle(isLeft: true, title: newTitle)
                    } else if tab === self.configuredRightTab {
                        self.updatePaneTitle(isLeft: false, title: newTitle)
                    }
                }
                .store(in: &cancellables)
        }
    }

    private func updatePaneTitles(leftTitle: String, rightTitle: String) {
        toolTip = nil
        updatePaneTitle(isLeft: true, title: leftTitle)
        updatePaneTitle(isLeft: false, title: rightTitle)
    }

    private func updatePaneTitle(isLeft: Bool, title: String) {
        let label = isLeft ? leftTitleLabel : rightTitleLabel
        label.stringValue = title
        label.toolTip = title
    }

    private func refreshFaviconForTab(_ tab: Tab) {
        if tab === configuredLeftTab {
            refreshFavicon(into: leftIconView, for: tab, handle: &leftFaviconHandle)
        } else if tab === configuredRightTab {
            refreshFavicon(into: rightIconView, for: tab, handle: &rightFaviconHandle)
        }
    }

    private func refreshFavicon(into imageView: NSImageView,
                                for tab: Tab,
                                handle: inout ProfileScopedFaviconLoadHandle?) {
        handle?.cancel()
        handle = nil
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
        handle = ProfileScopedFaviconRepository.shared.loadFavicon(for: request) { [weak imageView, weak tab] result in
            imageView?.image = result.image
            if result.source == .chromium, let data = result.data {
                tab?.updateCachedFaviconData(data)
            }
        }
    }

    /// Show or hide a pane's mute toggle based on its tab's audio state.
    /// Mirrors the audible-or-muted condition `SideTabView` uses for the
    /// regular sidebar row so split panes match unsplit panes visually.
    private func updateMute(isLeft: Bool, audible: Bool, muted: Bool) {
        let hasAudio = audible || muted
        let host = isLeft ? leftMuteHost : rightMuteHost
        let widthConstraint = isLeft ? leftMuteWidth : rightMuteWidth
        host?.isHidden = !hasAudio
        widthConstraint?.update(offset: hasAudio ? 20 : 0)
        guard hasAudio else { return }
        host?.rootView = AnyView(
            SplitPaneMuteButton(isMuted: muted) { [weak self] in
                guard let self else { return }
                let tab = isLeft ? self.configuredLeftTab : self.configuredRightTab
                guard let tab else { return }
                tab.setAudioMuted(!tab.isAudioMuted)
            }
            .phiThemeObserver(themeObserver)
        )
    }

    /// Show or hide a pane's recording badge based on its tab's capture
    /// state. Mirrors the corner badge a standalone tab shows via
    /// `UnifiedTabFaviconView` so split panes match unsplit panes.
    private func updateRecording(isLeft: Bool, capturing: Bool) {
        let host = isLeft ? leftRecordingHost : rightRecordingHost
        host?.isHidden = !capturing
    }

    /// Test seam: whether the given pane currently shows its recording badge.
    func isRecordingIndicatorVisible(isLeft: Bool) -> Bool {
        !(isLeft ? leftRecordingHost : rightRecordingHost).isHidden
    }

    private func updateSelected() {
        guard let pair = item as? SplitPairSidebarItem else { return }
        // Whole cell flips to the selected pill when *either* pane is the
        // focusing tab. The HoverableView prioritizes its `selectedColor`
        // over its hover tint, so the cell-level NSTrackingArea-driven
        // hover background underneath cleanly yields to the active fill.
        outerBackground.isSelected = pair.leftTab.isActive || pair.rightTab.isActive
    }

    /// Re-binds the cell when the pair's membership changed in place — a
    /// drag-to-replace swaps one pane's Tab object on the cached
    /// `SplitPairSidebarItem` while the row id survives, so the outline
    /// diff never reloads this row. `reresolvePairOrderIfNeeded` below only
    /// covers order swaps of the two already-bound tabs; identity drift
    /// needs the full re-bind so the title/favicon/audio subscriptions
    /// attach to the new Tab. Driven by
    /// `SidebarTabListViewController.pushPaneUpdatesToSplitPairCells`.
    func rebindPanesIfNeeded() {
        guard let pair = item as? SplitPairSidebarItem,
              pair.leftTab !== configuredLeftTab || pair.rightTab !== configuredRightTab else {
            return
        }
        configureAppearance()
    }

    /// If Chromium reordered the pair (swap button / drag), reflect the new
    /// order in the cell. The SplitGroup's primary/secondary updates first;
    /// the strip's `normalTabs` then re-sequences. We compare the cell's
    /// current left/right against the live `normalTabs` order and swap if
    /// the visible mapping is stale.
    private func reresolvePairOrderIfNeeded() {
        guard let pair = item as? SplitPairSidebarItem,
              let state = browserState,
              let leftIdx = state.normalTabs.firstIndex(where: { $0.guid == pair.leftTab.guid }),
              let rightIdx = state.normalTabs.firstIndex(where: { $0.guid == pair.rightTab.guid }) else {
            return
        }
        if leftIdx > rightIdx {
            let oldLeft = pair.leftTab
            pair.leftTab = pair.rightTab
            pair.rightTab = oldLeft
            configuredLeftTab = pair.leftTab
            configuredRightTab = pair.rightTab
            updatePaneTitles(leftTitle: pair.leftTab.title, rightTitle: pair.rightTab.title)
            refreshFavicon(into: leftIconView, for: pair.leftTab, handle: &leftFaviconHandle)
            refreshFavicon(into: rightIconView, for: pair.rightTab, handle: &rightFaviconHandle)
            updateSelected()
            updateMute(isLeft: true,
                       audible: pair.leftTab.isCurrentlyAudible,
                       muted: pair.leftTab.isAudioMuted)
            updateMute(isLeft: false,
                       audible: pair.rightTab.isCurrentlyAudible,
                       muted: pair.rightTab.isAudioMuted)
            updateRecording(isLeft: true, capturing: pair.leftTab.isCapturingMedia)
            updateRecording(isLeft: false, capturing: pair.rightTab.isCapturingMedia)
        }
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
    @MainActor
    static func organizeFocusedWindow() {
        NotificationCenter.default.post(name: .farringdonOrganizeDidStart, object: nil)
        ExtensionMessaging.shared.broadcast(type: "farringdon.toggleTabs", payload: "{}")
    }
}

// MARK: - Broom Button

/// The "organize tabs with AI" (Farringdon) button shown at the trailing edge of
/// the New Tab row. Owns its own hover feedback (tint + subtle fill) and a
/// sweeping animation that plays while a run is in progress.
final class BroomButton: NSButton {
    private var trackingArea: NSTrackingArea?
    private var isHovering = false { didSet { updateAppearance() } }
    private(set) var isOrganizing = false
    private var organizeStartedAt: Date?
    private var safetyTimer: Timer?

    private static let sweepKey = "farringdonSweep"
    private static let minVisibleDuration: TimeInterval = 0.6
    private static let safetyTimeout: TimeInterval = 8.0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        safetyTimer?.invalidate()
    }

    private func configure() {
        isBordered = false
        bezelStyle = .shadowlessSquare
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyUpOrDown
        setButtonType(.momentaryChange)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.cornerCurve = .continuous
        let broom = NSImage(named: NSImage.Name("farringdon-broom"))
        broom?.isTemplate = true
        image = broom
        toolTip = NSLocalizedString(
            "Organize tabs with AI",
            comment: "side bar new tab row - organize tabs button tooltip")
        updateAppearance()
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
        // Prominent (matches the design's solid black broom); adapts to the
        // theme so it stays visible in dark mode. Hover adds a subtle fill.
        phi.setContentTintColor(.textPrimary)
        layer?.backgroundColor = isHovering
            ? NSColor.labelColor.withAlphaComponent(0.10).cgColor
            : NSColor.clear.cgColor
    }

    // MARK: Organizing animation

    func startOrganizing() {
        guard !isOrganizing else { return }
        isOrganizing = true
        organizeStartedAt = Date()

        // Keep in sync with the horizontal-tab broom (TabStripFarringdonButton):
        // ~16° sweep around the center, ~0.8s full cycle.
        let sweep = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        sweep.values = [0, -0.28, 0, 0.28, 0]
        sweep.keyTimes = [0, 0.25, 0.5, 0.75, 1]
        sweep.duration = 0.8
        sweep.repeatCount = .infinity
        sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer?.add(sweep, forKey: Self.sweepKey)

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

        // Keep the sweep visible for a beat so a sub-100ms run still registers.
        let elapsed = organizeStartedAt.map { Date().timeIntervalSince($0) } ?? Self.minVisibleDuration
        let remaining = max(0, Self.minVisibleDuration - elapsed)
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
            guard let self, self.isOrganizing else { return }
            self.isOrganizing = false
            self.organizeStartedAt = nil
            self.layer?.removeAnimation(forKey: Self.sweepKey)
        }
    }

    @objc private func handleOrganizeDidStart() {
        guard !isHidden else { return }
        startOrganizing()
    }

    @objc private func handleOrganizeDidFinish() {
        stopOrganizing()
    }
}

// MARK: - New Tab Button Cell View
class NewTabButtonCellView: SidebarCellView {
    var clickAction: (() -> Void)?
    /// Triggers the Farringdon "organize tabs with AI" action. When nil, the
    /// trailing broom button is hidden.
    var cleanupAction: (() -> Void)? {
        didSet { cleanupButton.isHidden = (cleanupAction == nil) }
    }
    private var iconHoverState = false
    private var didPlayForwardAnimationForCurrentHover = false

    private lazy var cleanupButton: BroomButton = {
        let button = BroomButton(frame: .zero)
        button.target = self
        button.action = #selector(cleanupButtonClicked)
        button.isHidden = true
        return button
    }()

    @objc private func cleanupButtonClicked() {
        guard !cleanupButton.isOrganizing else { return }
        // `cleanupAction` triggers the organize run, which posts
        // `.farringdonOrganizeDidStart`; the button animates via that observer.
        cleanupAction?()
    }

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
        let titleLabel = NSTextField(labelWithString: NSLocalizedString("New Tab", comment: "side bar new tab button text"))
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
        cleanupButton.stopOrganizing()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Let the trailing broom button claim its own clicks before the cell
        // swallows the whole row (used by the floating new-tab variant where
        // `clickAction` opens a new tab).
        if let hit = super.hitTest(point),
           hit == cleanupButton || hit.isDescendant(of: cleanupButton) {
            return hit
        }
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
        backgoundView.addSubview(cleanupButton)

        iconView.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(6)
            make.centerY.equalToSuperview()
            make.size.equalTo(16)
        }

        cleanupButton.snp.makeConstraints { make in
            make.trailing.equalToSuperview().inset(8)
            make.centerY.equalToSuperview()
            make.size.equalTo(22)
        }

        titleLabel.snp.makeConstraints { make in
            make.leading.equalTo(iconView.snp.trailing).offset(8)
            make.trailing.lessThanOrEqualTo(cleanupButton.snp.leading).offset(-8)
            make.centerY.equalToSuperview()
        }
    }
}

// MARK: - Separator Cell View
class SeparatorCellView: SidebarCellView {
    private var separatorView: NSView!
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }
    
    private func setupViews() {
        separatorView = NSView()
        separatorView.wantsLayer = true
        separatorView.phiLayer?.setBackgroundColor(.separator)
        addSubview(separatorView)

        separatorView.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(WebContentConstant.edgesSpacing)
            make.centerY.equalToSuperview()
            make.height.equalTo(1)
        }
    }
}

protocol TabCellDelegate: AnyObject {
    func tabCellDidRequestClose(_ tab: Tab)
}

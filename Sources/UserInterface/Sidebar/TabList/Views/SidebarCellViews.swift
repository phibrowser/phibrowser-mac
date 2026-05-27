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

// MARK: - Tab Hover Region

/// Transparent overlay that owns hover tracking for sidebar tabs.
/// NSHostingView sits underneath and does not reliably deliver parent tracking-area events.
private final class SidebarTabHoverRegionView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    weak var mouseEventForwardTarget: NSView?

    private var trackingArea: NSTrackingArea?

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

    override func mouseDown(with event: NSEvent) {
        forwardMouseEvent(event)
    }

    override func mouseUp(with event: NSEvent) {
        forwardMouseEvent(event)
    }

    override func rightMouseDown(with event: NSEvent) {
        forwardMouseEvent(event)
    }

    private func forwardMouseEvent(_ event: NSEvent) {
        guard let mouseEventForwardTarget,
              let window = mouseEventForwardTarget.window else {
            return
        }
        let point = mouseEventForwardTarget.convert(event.locationInWindow, from: nil)
        guard mouseEventForwardTarget.bounds.contains(point) else { return }
        switch event.type {
        case .leftMouseDown:
            mouseEventForwardTarget.mouseDown(with: event)
        case .leftMouseUp:
            mouseEventForwardTarget.mouseUp(with: event)
        case .rightMouseDown:
            mouseEventForwardTarget.rightMouseDown(with: event)
        default:
            break
        }
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
private final class SidebarTabHoverDeadZoneView: NSView {
    var onEntered: (() -> Void)?
    weak var mouseEventForwardTarget: NSView?

    private var trackingArea: NSTrackingArea?

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

    override func mouseDown(with event: NSEvent) {
        forwardMouseEvent(event)
    }

    override func mouseUp(with event: NSEvent) {
        forwardMouseEvent(event)
    }

    override func rightMouseDown(with event: NSEvent) {
        forwardMouseEvent(event)
    }

    private func forwardMouseEvent(_ event: NSEvent) {
        guard let mouseEventForwardTarget,
              let window = mouseEventForwardTarget.window else {
            return
        }
        let point = mouseEventForwardTarget.convert(event.locationInWindow, from: nil)
        guard mouseEventForwardTarget.bounds.contains(point) else { return }
        switch event.type {
        case .leftMouseDown:
            mouseEventForwardTarget.mouseDown(with: event)
        case .leftMouseUp:
            mouseEventForwardTarget.mouseUp(with: event)
        case .rightMouseDown:
            mouseEventForwardTarget.rightMouseDown(with: event)
        default:
            break
        }
    }
}

// MARK: - Tab Cell View (reused from existing)
class SidebarTabCellView: SidebarCellView {
    private var hostingView: ThemedHostingView!
    private let hoverRegionView = SidebarTabHoverRegionView()
    private let hoverDeadZoneView = SidebarTabHoverDeadZoneView()
    private let viewModel = TabViewModel()
    weak var delegate: TabCellDelegate?
    /// Owning window's BrowserState. Set by the controller when the cell is
    /// configured so `updateSplitMembership` resolves split info against this
    /// window's data — not the globally-active window's. Without this, a
    /// newly-created window (e.g. via drag-out) whose key state hasn't taken
    /// over yet would consult the source window's splits and render its split
    /// pair as two unmerged rows until something else triggered a refresh.
    weak var browserState: BrowserState?
    
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
        viewModel.setHovered(false)
        viewModel.isPressed = false
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
    
    private func setupViews() {
        hostingView = ThemedHostingView(rootView: SideTabView(model: viewModel) { [weak self] in
            self?.closeButtonTapped()
        })
        addSubview(hostingView)
        hostingView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        hoverRegionView.mouseEventForwardTarget = hostingView
        hoverRegionView.onHoverChanged = { [weak self] isHovered in
            self?.viewModel.isHovered = isHovered
        }
        addSubview(hoverRegionView)
        hoverRegionView.snp.makeConstraints { make in
            make.leading.top.bottom.equalToSuperview()
            make.trailing.equalToSuperview().inset(SideTabView.trailingHoverDeadZoneWidth)
        }

        hoverDeadZoneView.mouseEventForwardTarget = hostingView
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
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()

        let state = MainBrowserWindowControllersManager.shared
            .controller(for: tab.windowId)?.browserState
        viewModel.configure(with: tab, in: state)
        viewModel.onToggleMute = { [weak tab] in
            guard let tab else { return }
            tab.setAudioMuted(!tab.isAudioMuted)
        }
        updateSplitMembership()
    }

    /// Recompute split-pair position and active-group flag from BrowserState.
    /// Cheap; safe to call from a global $splits / $focusingTab subscription
    /// to update visible cells without going through reloadData().
    func updateSplitMembership() {
        guard let tab = item as? Tab,
              let state = browserState else {
            viewModel.splitPairPosition = nil
            viewModel.isSplitGroupActive = false
            return
        }
        if let group = state.splitGroup(forTabId: tab.guid) {
            viewModel.splitPairPosition = state.splitPairPosition(forTabId: tab.guid)
            viewModel.isSplitGroupActive = state.isSplitGroupActive(group)
        } else {
            viewModel.splitPairPosition = nil
            viewModel.isSplitGroupActive = false
        }
    }
}

// MARK: - New Tab Button Cell View
class NewTabButtonCellView: SidebarCellView {
    var clickAction: (() -> Void)?

    private lazy var iconView: LottieAnimationNSView = {
        let config = LottieAnimationViewConfig(
            animationName: "new-tab",
            reverseAnimationName: "new-tab-reverse",
            size: CGSize(width: 16, height: 16),
            animationTrigger: .manual,
            themedTintColor: .textTertiary,
            reverseOnHoverExit: true
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
            guard self.backgoundView.responseToHoverAnimation else {
                return
            }
            if hovered {
                self.iconView.triggerAnimation()
            } else {
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
            make.trailing.equalToSuperview().inset(8)
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

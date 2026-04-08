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

// MARK: - Tab Cell View (reused from existing)
class SidebarTabCellView: SidebarCellView {
    private var hostingView: NSHostingView<AnyView>!
    private let viewModel = TabViewModel()
    private var themeObserver = ThemeObserver.shared
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
        viewModel.isPressed = false
        viewModel.cancelSubscriptions()
    }
    
    private func setupViews() {
        updateThemeObserver()
        hostingView = NSHostingView(rootView: makeRootView())
        addSubview(hostingView)
        hostingView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        setupPressAnimation()
    }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateThemeObserver()
        hostingView.rootView = makeRootView()
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

    private func updateThemeObserver() {
        themeObserver = ThemeObserver(themeSource: themeStateProvider)
    }

    private func makeRootView() -> AnyView {
        AnyView(
            SideTabView(model: viewModel) { [weak self] in
                self?.closeButtonTapped()
            }
            .phiThemeObserver(themeObserver)
        )
    }

    private func closeButtonTapped() {
        guard let tab = item as? Tab else { return }
        delegate?.tabCellDidRequestClose(tab)
    }
    
    override func configureAppearance() {
        guard let tab = item as? Tab else { return }
        
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
        
        viewModel.configure(with: tab)
        viewModel.onToggleMute = { [weak tab] in
            guard let tab else { return }
            tab.setAudioMuted(!tab.isAudioMuted)
        }
    }
}

// MARK: - New Tab Button Cell View
class NewTabButtonCellView: SidebarCellView {
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
    
    private func setupViews() {
        addSubview(backgoundView)
        backgoundView.shadow = nil
        backgoundView.snp.makeConstraints { make in
            make.left.equalToSuperview().inset(10)
            make.top.bottom.trailing.equalToSuperview().inset(2)
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
            make.leading.trailing.equalToSuperview()
            make.centerY.equalToSuperview()
            make.height.equalTo(1)
        }
    }
}


protocol TabCellDelegate: AnyObject {
    func tabCellDidRequestClose(_ tab: Tab)
}

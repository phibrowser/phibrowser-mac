// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Combine
import SnapKit

/// Owns the glyph layer so AppKit can lay out the view without resetting its rotation.
final class SpaceRootChevronView: NSView {
    private let glyphLayer = CALayer()
    private let symbol = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
    var tintColor: NSColor? {
        didSet { updateGlyph() }
    }
    private(set) var rotationAngle: Double = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        glyphLayer.contentsGravity = .resizeAspect
        layer?.addSublayer(glyphLayer)
        updateGlyph()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Keep the glyph at its configured size inside the icon slot.
        glyphLayer.bounds = NSRect(origin: .zero, size: symbol?.size ?? NSSize(width: 10, height: 10))
        glyphLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        glyphLayer.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
    }

    private func updateGlyph() {
        let color = tintColor ?? ThemedColor.textMuted.resolve(in: self)
        // Tint opaquely so source-atop blending cannot mix in the symbol's original color.
        glyphLayer.contents = symbol?.tinted(with: color.withAlphaComponent(1)).cgImage(forProposedRect: nil, context: nil, hints: nil)
        glyphLayer.opacity = Float(color.alphaComponent)
    }

    func setExpanded(_ expanded: Bool, animated: Bool) {
        let from = glyphLayer.presentation()?.value(forKeyPath: "transform.rotation.z") ?? rotationAngle
        rotationAngle = expanded ? -Double.pi / 2 : 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glyphLayer.setValue(rotationAngle, forKeyPath: "transform.rotation.z")
        CATransaction.commit()
        glyphLayer.removeAnimation(forKey: "disclosure")
        guard animated else { return }
        let spring = CASpringAnimation(keyPath: "transform.rotation.z")
        spring.stiffness = 420
        spring.damping = 38
        spring.mass = 1
        spring.fromValue = from
        spring.toValue = rotationAngle
        spring.duration = spring.settlingDuration
        glyphLayer.add(spring, forKey: "disclosure")
    }
}

/// Space bookmark header, shared by both sidebar surfaces.
final class SpaceRootCellView: SidebarCellView {
    static var disclosureAnimationDuration: TimeInterval {
        let spring = CASpringAnimation()
        spring.stiffness = 420
        spring.damping = 38
        spring.mass = 1
        return spring.settlingDuration
    }
    var onToggle: (() -> Void)?
    var makeMoreMenu: (() -> NSMenu)?
    private let chevron = SpaceRootChevronView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let folderPreview = BookmarkFolderPreview()
    private var expanded: Bool?
    private var isRowHovered = false
    private var isMoreMenuPresented = false
    private lazy var moreButton: HoverableButtonNSView = {
        let config = HoverableButtonConfig(imageSize: NSSize(width: 14, height: 14), systemName: "ellipsis",
                                           hoverBackgroundColor: .hover, imageTintColor: .textMuted,
                                           cornerRadius: 6)
        let button = HoverableButtonNSView(config: config) { [weak self] in
            self?.showMoreMenu()
        }
        let label = NSLocalizedString("sidebar.spaceRoot.moreButton", value: "More", comment: "Sidebar Space folder row - Button that opens the Space actions menu")
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.isHidden = true
        return button
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        addSubview(backgoundView)
        backgoundView.backgroundColor = .clear
        backgoundView.hoveredColor = NSColor(resource: .sidebarTabHovered)
        backgoundView.selectedColor = NSColor(resource: .sidebarTabSelected)
        backgoundView.layer?.cornerRadius = 8
        backgoundView.shadow = nil
        backgoundView.responseToClickAction = false
        folderPreview.onPresentationChange = { [weak self] isPresented in
            self?.backgoundView.isHoverPinned = isPresented
        }
        backgoundView.snp.makeConstraints {
            $0.leading.trailing.equalToSuperview().inset(WebContentConstant.edgesSpacing)
            $0.top.bottom.equalToSuperview().inset(2)
        }
        backgoundView.addSubview(chevron)
        backgoundView.addSubview(titleLabel)
        backgoundView.addSubview(moreButton)
        chevron.snp.makeConstraints {
            $0.leading.equalToSuperview().offset(6)
            $0.centerY.equalToSuperview()
            $0.width.equalTo(16)
            $0.height.equalTo(20)
        }
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.snp.makeConstraints {
            $0.leading.equalTo(chevron.snp.trailing).offset(8)
            $0.trailing.equalTo(moreButton.snp.leading).offset(-4)
            $0.centerY.equalToSuperview()
        }
        moreButton.snp.makeConstraints {
            $0.trailing.equalToSuperview().inset(4)
            $0.centerY.equalToSuperview()
            $0.width.height.equalTo(24)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.disclosureTriangle)
        setAccessibilityChildren([])
        chevron.setAccessibilityElement(false)
        titleLabel.setAccessibilityElement(false)
    }

    override func configure(with item: SidebarItem) {
        cancellables.removeAll()
        expanded = nil
        folderPreview.invalidate()
        super.configure(with: item)
        guard let root = item as? SpaceRootSidebarItem, let state = root.browserState else { return }
        backgoundView.hoverStateChanged = { [weak self, weak root, weak state] isHovered in
            guard let self, let root, let state else { return }
            self.isRowHovered = isHovered
            self.updateMoreButtonVisibility()
            self.folderPreview.setHovering(isHovered, source: .space(root), anchor: self.backgoundView,
                                           browserState: state)
        }
        chevron.phi(source: state.themeContext)[\.tintColor] = ThemedColor.textMuted.nsColorMapper
        titleLabel.phi(source: state.themeContext).setTextColor(.textMuted)
        updateTitle(root.title)
        state.$isBookmarkRootExpanded
            .sink { [weak self] in self?.setExpanded($0) }
            .store(in: &cancellables)
        SpaceManager.shared.$spaces
            .map { spaces -> AnyPublisher<String, Never> in
                guard let space = spaces.first(where: { $0.spaceId == state.spaceId }) else {
                    return Just(root.title).eraseToAnyPublisher()
                }
                return space.$content.map(\.name).eraseToAnyPublisher()
            }
            .switchToLatest()
            .sink { [weak self] in self?.updateTitle($0) }
            .store(in: &cancellables)
    }

    private func updateTitle(_ title: String) {
        titleLabel.stringValue = title
        setAccessibilityLabel(title)
    }

    private func setExpanded(_ value: Bool) {
        guard expanded != value else { return }
        let animate = expanded != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        expanded = value
        if value { folderPreview.invalidate() }
        chevron.setExpanded(value, animated: animate)
        setAccessibilityValue(value ? 1 : 0)
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    private func updateMoreButtonVisibility() {
        moreButton.isHidden = !(isRowHovered || isMoreMenuPresented)
    }

    private func showMoreMenu() {
        guard let menu = makeMoreMenu?() else { return }
        folderPreview.invalidate()
        isMoreMenuPresented = true
        backgoundView.isHoverPinned = true
        updateMoreButtonVisibility()
        let origin = NSPoint(x: 0, y: moreButton.isFlipped ? moreButton.bounds.maxY + 4 : -4)
        menu.popUp(positioning: nil, at: origin, in: moreButton)
        isMoreMenuPresented = false
        backgoundView.isHoverPinned = false
        updateMoreButtonVisibility()
    }

    func setDropTargetHighlighted(_ highlighted: Bool) {
        guard backgoundView.isSelected != highlighted else { return }
        backgoundView.isSelected = highlighted
    }

    override func accessibilityPerformPress() -> Bool {
        onToggle?()
        return onToggle != nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { folderPreview.invalidate() }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        folderPreview.invalidate()
        backgoundView.hoverStateChanged = nil
        onToggle = nil
        makeMoreMenu = nil
        isRowHovered = false
        updateMoreButtonVisibility()
        expanded = nil
        backgoundView.isSelected = false
        chevron.setExpanded(false, animated: false)
    }
}

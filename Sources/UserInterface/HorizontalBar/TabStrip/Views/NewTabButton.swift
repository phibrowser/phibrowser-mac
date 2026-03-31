// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SnapKit

final class NewTabButton: NSView {
    // MARK: - Properties

    var onTap: (() -> Void)?

    private var isHovered = false {
        didSet {
            if oldValue != isHovered {
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.12)
                hoverLayer.opacity = isHovered ? 1.0 : 0.0
                CATransaction.commit()
            }
        }
    }

    // MARK: - Subviews
    private lazy var hoverLayer: CALayer = {
        let layer = CALayer()
        layer.backgroundColor = NSColor(resource: .sidebarTabHovered).cgColor
        layer.cornerRadius = TabStripMetrics.NewTabButton.cornerRadius
        layer.opacity = 0
        return layer
    }()
    private lazy var iconView: NSImageView = {
        let imageView = NSImageView()
        imageView.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")
        imageView.symbolConfiguration = .init(pointSize: 16, weight: .medium)
        return imageView
    }()


    // MARK: - Initialization
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup UI
    private func setupUI() {
        wantsLayer = true
        layer?.addSublayer(hoverLayer)

        addSubview(iconView)
        iconView.snp.makeConstraints { make in
            make.center.equalToSuperview()
        }
        iconView.phi.setContentTintColor(.textTertiary)
    }

    // MARK: - Layout
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hoverLayer.frame = bounds
        CATransaction.commit()
    }


    // MARK: - Mouse Events
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        let trackingArea = NSTrackingArea(rect: bounds,
                                          options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                          owner: self,
                                          userInfo: nil)
        addTrackingArea(trackingArea)
        if let window = window {
            let mouseLocation = window.mouseLocationOutsideOfEventStream
            let localPoint = convert(mouseLocation, from: nil)
            let shouldBeHovered = bounds.contains(localPoint)
            if isHovered != shouldBeHovered {
                isHovered = shouldBeHovered
            }
        }
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) {
            onTap?()
        }
    }
}

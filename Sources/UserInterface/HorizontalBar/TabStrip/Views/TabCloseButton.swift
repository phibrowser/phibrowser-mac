// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

final class TabCloseButton: NSView {
    // MARK: - Properties

    var onTap: (() -> Void)?

    private var isHovered = false {
        didSet {
            guard oldValue != isHovered else { return }
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.1)
            hoverLayer.opacity = isHovered ? 1.0 : 0.0
            CATransaction.commit()
        }
    }

    // MARK: - Layers & Subviews

    private let hoverLayer: CALayer = {
        let layer = CALayer()
        layer.backgroundColor = TabStripMetrics.Content.closeButtonHoverColor.cgColor
        layer.cornerRadius = TabStripMetrics.Content.closeButtonCornerRadius
        layer.opacity = 0.0
        return layer
    }()

    private let iconView: NSImageView = {
        let imageView = NSImageView()
        imageView.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")
        imageView.imageScaling = .scaleProportionallyDown
        imageView.symbolConfiguration = .init(
            pointSize: TabStripMetrics.Content.closeButtonIconPointSize,
            weight: .bold
        )
//        imageView.contentTintColor = TabStripMetrics.Content.closeButtonIconColor
        return imageView
    }()

    // MARK: - Initialization

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupUI() {
        wantsLayer = true
        layer?.addSublayer(hoverLayer)
        addSubview(iconView)
    }

    // MARK: - Layout

    override func layout() {
        super.layout()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hoverLayer.frame = bounds

        let iconSize = TabStripMetrics.Content.closeButtonIconSize
        iconView.frame = CGRect(
            x: (bounds.width - iconSize) / 2,
            y: (bounds.height - iconSize) / 2,
            width: iconSize,
            height: iconSize
        )
        CATransaction.commit()
    }

    // MARK: - Mouse Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onTap?()
        }
    }
}

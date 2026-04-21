// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Kingfisher

final class TabSwitchCellView: NSView {
    private let previewContainer = NSView()
    private let previewImageView = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let faviconImageView = NSImageView()

    private(set) var isHighlighted = false
    private(set) var isHovered = false
    private var trackingArea: NSTrackingArea?
    private var faviconDownloadTask: DownloadTask?

    var onClicked: (() -> Void)?
    var onHovered: ((Bool) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = TabSwitchMetrics.cellCornerRadius

        previewContainer.wantsLayer = true
        let shadow = NSShadow()
        shadow.shadowColor = .black.withAlphaComponent(0.25)
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.shadowBlurRadius = 6
        previewContainer.shadow = shadow
        previewContainer.layer?.cornerRadius = TabSwitchMetrics.previewCornerRadius
        addSubview(previewContainer)

        previewImageView.wantsLayer = true
        previewImageView.layer?.contentsGravity = .resizeAspectFill
        previewImageView.layer?.cornerCurve = .continuous
        previewImageView.layer?.cornerRadius = TabSwitchMetrics.previewCornerRadius
        previewImageView.layer?.masksToBounds = true
        previewContainer.addSubview(previewImageView)

        faviconImageView.imageScaling = .scaleProportionallyDown
        faviconImageView.wantsLayer = true
        faviconImageView.layer?.cornerRadius = 3
        faviconImageView.layer?.cornerCurve = .continuous
        faviconImageView.layer?.masksToBounds = true
        addSubview(faviconImageView)

        titleLabel.maximumNumberOfLines = TabSwitchMetrics.titleLineLimit
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.alignment = .left
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        addSubview(titleLabel)
    }

    deinit {
        faviconDownloadTask?.cancel()
    }

    func configure(with item: TabSwitchItem, themeProvider: ThemeStateProvider) {
        previewImageView.layer?.contents = item.snapshotImage
        titleLabel.stringValue = item.title

        faviconDownloadTask?.cancel()
        faviconDownloadTask = nil

        if let live = item.liveFaviconImage {
            faviconImageView.image = live
        } else {
            faviconImageView.image = nil
            let config = FaviconConfiguration(
                cornerRadius: 3,
                fadeTransition: 0.2,
                cacheOriginalImage: true,
                placeholder: NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
            )
            faviconDownloadTask = faviconImageView.setFavicon(for: item.faviconPageURL, configuration: config)
        }

        titleLabel.textColor = ThemedColor.textPrimary.resolve(
            theme: themeProvider.currentTheme,
            appearance: themeProvider.currentAppearance
        )
    }

    func setHighlighted(_ highlighted: Bool, themeProvider: ThemeStateProvider) {
        isHighlighted = highlighted
        updateBackgroundAppearance(themeProvider: themeProvider)
    }

    private func updateBackgroundAppearance(themeProvider: ThemeStateProvider) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = TabSwitchMetrics.hoverAnimationDuration
            if isHighlighted {
                layer?.backgroundColor = ThemedColor.themeColor.resolve(
                    theme: themeProvider.currentTheme,
                    appearance: themeProvider.currentAppearance
                ).withAlphaComponent(0.6).cgColor
            } else if isHovered {
                let hoverColor: NSColor = themeProvider.currentAppearance.isDark
                    ? .white.withAlphaComponent(0.08)
                    : .black.withAlphaComponent(0.05)
                layer?.backgroundColor = hoverColor.cgColor
            } else {
                layer?.backgroundColor = nil
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self,
            userInfo: nil
        )
        if let trackingArea {
            addTrackingArea(trackingArea)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        onHovered?(true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        onHovered?(false)
    }

    override func layout() {
        super.layout()
        let metrics = TabSwitchMetrics.self
        let imageInset = metrics.previewInset
        let contentInset = metrics.cellContentInset
        let previewWidth = bounds.width - imageInset * 2

        let faviconSize: CGFloat = 14
        let titleRowHeight: CGFloat = 16

        let previewFrame = NSRect(
            x: imageInset,
            y: bounds.height - imageInset - metrics.previewHeight,
            width: previewWidth,
            height: metrics.previewHeight
        )
        previewContainer.frame = previewFrame
        previewImageView.frame = previewContainer.bounds

        let titleY = previewFrame.minY - metrics.titleTopSpacing - titleRowHeight
        faviconImageView.frame = NSRect(
            x: contentInset,
            y: titleY + (titleRowHeight - faviconSize) / 2,
            width: faviconSize,
            height: faviconSize
        )
        let titleX = faviconImageView.frame.maxX + 4
        titleLabel.frame = NSRect(
            x: titleX,
            y: titleY,
            width: bounds.width - contentInset - titleX,
            height: titleRowHeight
        )
    }

    override func mouseDown(with event: NSEvent) {
        onClicked?()
    }
}

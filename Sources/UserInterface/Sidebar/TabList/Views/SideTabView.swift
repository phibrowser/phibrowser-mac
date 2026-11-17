// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import Kingfisher
import Lottie
import SwiftUI

// MARK: - SideTabView

/// The sidebar tab row. AppKit views laid out by frame: rows are created
/// while the list scrolls, and a SwiftUI graph per row made each one cost a
/// full hosting-view layout.
///
/// `TabViewModel` stays the source of truth. `layout()` reads it inside
/// `withObservationTracking`, and a change to anything it read asks for the
/// next layout, so the row redraws within the same display cycle.
final class SideTabView: NSView {
    static let trailingHoverDeadZoneWidth: CGFloat = 6

    private static let cornerRadius: CGFloat = 8
    private static let faviconSlotSize: CGFloat = 16
    private static let buttonSize: CGFloat = 24
    private static let itemSpacing: CGFloat = 8
    private static let contentLeadingInset: CGFloat = 6
    private static let contentTrailingInset: CGFloat = 4
    private static let splitPaneSpacing: CGFloat = 4

    private let model: TabViewModel
    private let peekModel: TabViewModel
    private let onClose: () -> Void
    private let onClosePeek: () -> Void

    /// Scaled as a whole while the row is pressed.
    private let contentView = SideTabContainerView()
    private let backgroundView = SideTabPassthroughView()
    private let faviconView = SideTabFaviconView()
    private let muteButton = SideTabIconButton()
    private let titleView = SideTabTitleView()
    private let peekButton = SideTabPeekButton()
    private let closeButton = SideTabIconButton()
    private let badgeView = SideTabCornerBadgeView()
    private var splitPlaceholder: SideTabSplitPlaceholderView?

    private var theme: Theme?
    private var phiAppearance: Appearance = .light
    private var dimmingEnabled = PhiPreferences.GeneralSettings.showUnloadedTabIndicators.loadValue()
    private var cancellables = Set<AnyCancellable>()
    private var pressedScale = SideTabPressedScale()

    private lazy var activeShadow: NSShadow = {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.15)
        shadow.shadowBlurRadius = 1
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        return shadow
    }()

    init(model: TabViewModel,
         peekModel: TabViewModel,
         onClose: @escaping () -> Void,
         onClosePeek: @escaping () -> Void) {
        self.model = model
        self.peekModel = peekModel
        self.onClose = onClose
        self.onClosePeek = onClosePeek
        super.init(frame: .zero)
        setupViews()
        setupSubscriptions()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    private func setupViews() {
        wantsLayer = true
        layer?.masksToBounds = false
        contentView.wantsLayer = true
        contentView.layer?.masksToBounds = false
        addSubview(contentView)

        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = Self.cornerRadius
        backgroundView.layer?.cornerCurve = .continuous
        contentView.addSubview(backgroundView)

        contentView.addSubview(faviconView)
        contentView.addSubview(titleView)

        muteButton.onClick = { [weak self] in self?.model.onToggleMute?() }
        contentView.addSubview(muteButton)

        peekButton.onClick = { [weak self] in self?.onClosePeek() }
        peekButton.toolTip = NSLocalizedString(
            "peek.bookmarkCell.closePeekTooltip",
            value: "Close Peek",
            comment: "Bookmark sidebar row - Tooltip of the minus button that closes the floating page preview opened from this bookmark"
        )
        contentView.addSubview(peekButton)

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        closeButton.onClick = { [weak self] in self?.onClose() }
        contentView.addSubview(closeButton)

        contentView.addSubview(badgeView)
    }

    private func setupSubscriptions() {
        _ = phi.subscribe { [weak self] theme, appearance in
            self?.theme = theme
            self?.phiAppearance = appearance
            self?.needsLayout = true
        }
        // The status models are `ObservableObject`s, outside Observation.
        for status in [model.status, peekModel.status] {
            status.objectWillChange
                .sink { [weak self] _ in self?.needsLayout = true }
                .store(in: &cancellables)
        }
        TabFaviconPresentation.dimmingEnabledPublisher
            .dropFirst()
            .sink { [weak self] enabled in
                self?.dimmingEnabled = enabled
                self?.needsLayout = true
            }
            .store(in: &cancellables)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        withObservationTracking {
            render()
        } onChange: { [weak self] in
            MainActor.assumeIsolated {
                self?.needsLayout = true
            }
        }
    }

    // MARK: Rendering

    private func render() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let bounds = self.bounds
        contentView.frame = bounds
        pressedScale.apply(model.isPressed, to: contentView.layer, in: bounds)

        let leading = WebContentConstant.edgesSpacing
        let trailing = model.isInGroup ? 2 : WebContentConstant.edgesSpacing
        let rowRect = NSRect(
            x: leading,
            y: 2,
            width: max(0, bounds.width - leading - trailing),
            height: max(0, bounds.height - 4)
        )

        var tabRect = rowRect
        let splitDropSide = model.splitDropSide
        if let splitDropSide {
            let paneWidth = max(0, (rowRect.width - Self.splitPaneSpacing) / 2)
            var placeholderRect = rowRect
            placeholderRect.size.width = paneWidth
            tabRect.size.width = paneWidth
            if splitDropSide == .left {
                tabRect.origin.x = rowRect.minX + paneWidth + Self.splitPaneSpacing
            } else {
                placeholderRect.origin.x = rowRect.minX + paneWidth + Self.splitPaneSpacing
            }
            let placeholder = splitPlaceholder ?? makeSplitPlaceholder()
            placeholder.isHidden = false
            placeholder.frame = placeholderRect
        } else {
            splitPlaceholder?.isHidden = true
        }

        renderBackground(in: tabRect)

        let midY = tabRect.midY
        var x = tabRect.minX + Self.contentLeadingInset
        faviconView.frame = NSRect(
            x: x,
            y: midY - Self.faviconSlotSize / 2,
            width: Self.faviconSlotSize,
            height: Self.faviconSlotSize
        )
        faviconView.render(model: model, dimmingEnabled: dimmingEnabled,
                           theme: theme, appearance: phiAppearance)
        x += Self.faviconSlotSize + Self.itemSpacing

        let hasAudio = model.isCurrentlyAudible || model.isMuted
        muteButton.isHidden = !hasAudio
        if hasAudio {
            muteButton.image = NSImage(resource: model.isMuted ? .speakerMute : .speakerWave)
            muteButton.frame = buttonFrame(x: x, midY: midY)
            x += Self.buttonSize + Self.itemSpacing
        }

        var titleMaxX = tabRect.maxX - Self.contentTrailingInset
        let showsPeek = model.showsPeek
        let showsClose = (model.isHovered || model.isTouchRevealed)
            && !showsPeek && splitDropSide == nil
        peekButton.isHidden = !showsPeek
        closeButton.isHidden = !showsClose
        if showsPeek {
            peekButton.frame = buttonFrame(x: titleMaxX - Self.buttonSize, midY: midY)
            peekButton.render(model: peekModel, isTouchRevealed: model.isTouchRevealed,
                              dimmingEnabled: dimmingEnabled, theme: theme, appearance: phiAppearance)
            titleMaxX -= Self.buttonSize + Self.itemSpacing
        } else if showsClose {
            closeButton.frame = buttonFrame(x: titleMaxX - Self.buttonSize, midY: midY)
            titleMaxX -= Self.buttonSize + Self.itemSpacing
        }
        let hoverFill = theme.map { ThemedColor.hover.resolve(theme: $0, appearance: phiAppearance) } ?? .clear
        for button in [muteButton, closeButton, peekButton] as [SideTabIconButton] {
            button.hoverFillColor = hoverFill
        }

        let titleHeight = SideTabTitleView.titleHeight
        titleView.frame = NSRect(
            x: x,
            y: midY - titleHeight / 2,
            width: max(0, titleMaxX - x),
            height: titleHeight
        )
        titleView.render(title: model.displayTitle, isShimmering: model.isShimmering)

        let badgeSize = TabCornerBadgeMetrics.visualSize
        badgeView.frame = NSRect(
            x: tabRect.maxX - badgeSize + TabCornerBadgeMetrics.overhang,
            y: tabRect.minY - TabCornerBadgeMetrics.overhang,
            width: badgeSize,
            height: badgeSize
        )
        let isBadgeSuppressed = showsPeek || splitDropSide != nil
        badgeView.render(status: isBadgeSuppressed ? nil : model.status.cornerBadgeStatus,
                         theme: theme, appearance: phiAppearance)

        let toolTip = model.showsTabPreview ? nil : model.displayTitle
        if self.toolTip != toolTip {
            self.toolTip = toolTip
        }
    }

    private func renderBackground(in rect: NSRect) {
        backgroundView.frame = rect
        let fill: NSColor
        if model.splitDropSide != nil {
            fill = NSColor(resource: .sidebarTabHovered)
        } else if model.isActive {
            fill = NSColor(resource: .sidebarTabSelected)
        } else if model.isMultiSelected, let theme {
            fill = ThemedColor.tabSubSelectionBackground.resolve(theme: theme, appearance: phiAppearance)
        } else if model.isHovered {
            fill = NSColor(resource: .sidebarTabHovered)
        } else {
            fill = .clear
        }
        guard let layer = backgroundView.layer else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = fill.cgColor
        }
        let isActive = model.isActive
        let showsBorder = isActive && phiAppearance == .dark
        layer.borderWidth = showsBorder ? 1 : 0
        layer.borderColor = showsBorder ? NSColor.white.withAlphaComponent(0.2).cgColor : nil
        let shadow = isActive ? activeShadow : nil
        if backgroundView.shadow !== shadow {
            backgroundView.shadow = shadow
        }
    }

    private func buttonFrame(x: CGFloat, midY: CGFloat) -> NSRect {
        NSRect(x: x, y: midY - Self.buttonSize / 2, width: Self.buttonSize, height: Self.buttonSize)
    }

    private func makeSplitPlaceholder() -> SideTabSplitPlaceholderView {
        let placeholder = SideTabSplitPlaceholderView()
        contentView.addSubview(placeholder, positioned: .below, relativeTo: backgroundView)
        splitPlaceholder = placeholder
        return placeholder
    }
}

// MARK: - Building blocks

/// Shrinks a row's content slightly while the row is pressed.
struct SideTabPressedScale {
    private static let scale: CGFloat = 0.985

    private var isShownPressed = false

    mutating func apply(_ pressed: Bool, to layer: CALayer?, in bounds: NSRect) {
        guard let layer else { return }
        let target = pressed ? Self.scaleTransform(in: bounds) : CATransform3DIdentity
        if pressed != isShownPressed {
            isShownPressed = pressed
            let animation = CABasicAnimation(keyPath: "transform")
            animation.fromValue = layer.presentation()?.transform ?? layer.transform
            animation.toValue = target
            animation.duration = 0.08
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(animation, forKey: "pressedScale")
        }
        layer.transform = target
    }

    /// The view's layer is anchored at its origin, so scaling about the
    /// center moves the origin with it.
    private static func scaleTransform(in bounds: NSRect) -> CATransform3D {
        let midX = bounds.width / 2
        let midY = bounds.height / 2
        var transform = CATransform3DMakeTranslation(midX, midY, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        return CATransform3DTranslate(transform, -midX, -midY, 0)
    }
}

/// Decorative view that never takes the mouse, so clicks reach the row.
class SideTabPassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Lets clicks through its own area but not its subviews', so the buttons
/// it holds still take them.
final class SideTabContainerView: NSView {
    /// The rows lay their parts out top-down; a parent's flipping does not
    /// carry over to this view.
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// 24-point glyph button with the rounded hover fill of the tab row's
/// close and mute buttons.
class SideTabIconButton: NSButton {
    var onClick: (() -> Void)?
    var hoverFillColor: NSColor = .clear {
        didSet {
            if hoverFillColor != oldValue { updateFill() }
        }
    }
    private(set) var isPointerInside = false {
        didSet {
            if isPointerInside != oldValue { pointerInsideChanged() }
        }
    }
    private var trackingArea: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        isBordered = false
        setButtonType(.momentaryPushIn)
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        focusRingType = .none
        refusesFirstResponder = true
        contentTintColor = .labelColor
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.cornerCurve = .continuous
        target = self
        action = #selector(clicked)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isHidden: Bool {
        didSet {
            if isHidden { isPointerInside = false }
        }
    }

    @objc private func clicked() {
        onClick?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
        if let window {
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            isPointerInside = !isHidden && bounds.contains(point)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
    }

    func pointerInsideChanged() {
        updateFill()
    }

    private func updateFill() {
        guard let layer else { return }
        let color = isPointerInside ? hoverFillColor : .clear
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = color.cgColor
        }
        CATransaction.commit()
    }
}

/// Close button for a Peek attached to the row's tab: the peeked page's
/// favicon, which dims behind a minus glyph on hover.
final class SideTabPeekButton: SideTabIconButton {
    private let faviconView = SideTabFaviconView()
    private let minusImage = NSImage(systemSymbolName: "minus", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
    private var isTouchRevealed = false

    override init() {
        super.init()
        addSubview(faviconView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(model: TabViewModel, isTouchRevealed: Bool, dimmingEnabled: Bool,
                theme: Theme?, appearance: Appearance) {
        self.isTouchRevealed = isTouchRevealed
        let size = SideTabFaviconView.imageSize
        faviconView.frame = NSRect(
            x: (bounds.width - size) / 2,
            y: (bounds.height - size) / 2,
            width: size,
            height: size
        )
        faviconView.render(model: model, dimmingEnabled: dimmingEnabled,
                           theme: theme, appearance: appearance)
        updateGlyph()
    }

    override func pointerInsideChanged() {
        super.pointerInsideChanged()
        updateGlyph()
    }

    private func updateGlyph() {
        let showsMinus = isPointerInside || isTouchRevealed
        faviconView.alphaValue = showsMinus ? 0.25 : 1
        image = showsMinus ? minusImage : nil
    }
}

/// The tab's favicon in its slot: the pinned icon or favicon, shrunk inside
/// a dashed ring while the tab is unloaded, with the recording dot while the
/// tab captures media.
final class SideTabFaviconView: SideTabPassthroughView {
    static let imageSize: CGFloat = 14
    private static let imageCornerRadius: CGFloat = 3

    private let imageView = NSImageView()
    private let outlineLayer = CAShapeLayer()
    private var recordingBadge: SideTabRecordingBadgeView?
    /// What `imageView` was last asked to show, so a render that changes
    /// nothing neither reloads nor restarts a fade.
    private var displayedSource: ImageSource?

    private enum ImageSource: Equatable {
        case pinnedIcon(String)
        case image(ObjectIdentifier)
        case remote(url: String?, revision: Int)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerCurve = .continuous
        imageView.layer?.masksToBounds = true
        addSubview(imageView)
        outlineLayer.fillColor = nil
        outlineLayer.lineWidth = TabCornerBadgeMetrics.discardedOutlineLineWidth
        outlineLayer.lineCap = .round
        outlineLayer.lineDashPattern = [3, 3]
        outlineLayer.isHidden = true
        layer?.addSublayer(outlineLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    func render(model: TabViewModel, dimmingEnabled: Bool, theme: Theme?, appearance: Appearance) {
        let status = model.status
        let showsOutline = TabFaviconPresentation.showsDashedOutline(
            isDiscarded: status.isDiscarded,
            isUnloaded: status.isUnloaded,
            dimmingEnabled: dimmingEnabled
        )
        let scale: CGFloat = showsOutline ? 0.8 : 1
        renderImage(model: model)
        layoutImage(scale: scale)

        outlineLayer.isHidden = !showsOutline
        if showsOutline {
            let outlineSize = TabCornerBadgeMetrics.discardedOutlineSize(
                for: Self.imageSize,
                cornerRadius: Self.imageCornerRadius
            )
            let rect = CGRect(
                x: (bounds.width - outlineSize) / 2,
                y: (bounds.height - outlineSize) / 2,
                width: outlineSize,
                height: outlineSize
            )
            outlineLayer.frame = bounds
            outlineLayer.path = CGPath(ellipseIn: rect, transform: nil)
            let stroke: NSColor
            if appearance.isLight, let theme {
                stroke = BookmarkFolderIcon.strokeColor(theme: theme, appearance: appearance)
                    .withAlphaComponent(0.13)
            } else {
                stroke = NSColor.white.withAlphaComponent(0.06)
            }
            outlineLayer.strokeColor = stroke.cgColor
        }

        if model.isCapturingMedia && !model.hidesRecordingBadge {
            let badge = recordingBadge ?? makeRecordingBadge()
            let badgeSize = SideTabRecordingBadgeView.size
            let imageMaxX = (bounds.width + Self.imageSize) / 2
            let imageMinY = (bounds.height - Self.imageSize) / 2
            badge.frame = NSRect(
                x: imageMaxX + 3 - badgeSize,
                y: imageMinY - 3,
                width: badgeSize,
                height: badgeSize
            )
        } else if let recordingBadge {
            recordingBadge.removeFromSuperview()
            self.recordingBadge = nil
        }
    }

    /// Shows a page's icon outside any tab: `image` when there is one,
    /// otherwise the favicon fetched for `pageURL`.
    func render(image: NSImage?, pageURL: String?, revision: Int) {
        outlineLayer.isHidden = true
        recordingBadge?.removeFromSuperview()
        recordingBadge = nil
        if let image {
            show(.image(ObjectIdentifier(image)), image: image)
        } else {
            show(.remote(url: pageURL, revision: revision), image: nil)
        }
        layoutImage(scale: 1)
    }

    private func layoutImage(scale: CGFloat) {
        let size = Self.imageSize * scale
        imageView.frame = NSRect(
            x: (bounds.width - size) / 2,
            y: (bounds.height - size) / 2,
            width: size,
            height: size
        )
        imageView.layer?.cornerRadius = Self.imageCornerRadius * scale
    }

    private func renderImage(model: TabViewModel) {
        if let icon = model.pinnedIcon, IconPickerSelection.fromStorageValue(icon) != nil {
            show(.pinnedIcon(icon), image: nil)
        } else if let image = model.liveFaviconImage ?? model.profileFaviconImage {
            show(.image(ObjectIdentifier(image)), image: image)
        } else {
            show(.remote(url: model.faviconLoadURL ?? model.url, revision: model.faviconRevision), image: nil)
        }
    }

    private func show(_ source: ImageSource, image: NSImage?) {
        guard source != displayedSource else { return }
        displayedSource = source
        imageView.kf.cancelDownloadTask()
        switch source {
        case .pinnedIcon(let icon):
            imageView.image = IconPickerSelection.fromStorageValue(icon).flatMap(Self.image(for:))
        case .image:
            imageView.image = image
        case .remote(let url, _):
            imageView.setFavicon(
                for: url,
                configuration: FaviconConfiguration(cornerRadius: Self.imageCornerRadius)
            )
        }
    }

    private static func image(for selection: IconPickerSelection) -> NSImage? {
        switch selection {
        case .phiIcon(let id):
            return NSImage(named: PhiIconCatalog.canonicalId(for: id) ?? id)
        case .emoji(_, let text):
            let size = NSSize(width: imageSize, height: imageSize)
            return NSImage(size: size, flipped: false) { rect in
                let string = NSAttributedString(
                    string: text,
                    attributes: [.font: NSFont.systemFont(ofSize: imageSize * 0.85)]
                )
                let textSize = string.size()
                string.draw(at: NSPoint(x: rect.midX - textSize.width / 2,
                                        y: rect.midY - textSize.height / 2))
                return true
            }
        }
    }

    private func makeRecordingBadge() -> SideTabRecordingBadgeView {
        let badge = SideTabRecordingBadgeView()
        addSubview(badge)
        recordingBadge = badge
        return badge
    }
}

/// The pulsing red dot shown while a tab uses the camera, microphone or
/// screen.
final class SideTabRecordingBadgeView: SideTabPassthroughView {
    static let size: CGFloat = 8

    private let dotLayer = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
        layer?.cornerRadius = Self.size / 2
        dotLayer.backgroundColor = NSColor.systemRed.cgColor
        dotLayer.cornerRadius = (Self.size - 2) / 2
        layer?.addSublayer(dotLayer)
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.2
        pulse.duration = 1
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dotLayer.add(pulse, forKey: "pulse")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        dotLayer.frame = bounds.insetBy(dx: 1, dy: 1)
    }
}

/// The tab title: one clipped line that fades out at its trailing edge,
/// with a moving shimmer while the page loads.
final class SideTabTitleView: SideTabPassthroughView {
    private static let font = NSFont.systemFont(ofSize: 13)
    private static let emphasizedFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let titleHeight = ceil(font.ascender - font.descender + font.leading)
    private static let fadeWidth: CGFloat = 24
    private static let shimmerDuration: CFTimeInterval = 1.5
    private static let shimmerBandSize: CGFloat = 0.5
    private static let shimmerKey = "shimmer"

    private let label = NSTextField(labelWithString: "")
    /// Carries the shimmer mask. A text field's own layer mask is not
    /// reliably kept by AppKit.
    private let shimmerView = NSView()
    private let fadeMask = CAGradientLayer()
    private let shimmerMask = CAGradientLayer()
    private var shimmerSize: CGSize?
    private var isEmphasized = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        shimmerView.wantsLayer = true
        addSubview(shimmerView)
        label.font = Self.font
        label.lineBreakMode = .byClipping
        label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = false
        label.phi.setTextColor(.textPrimary)
        shimmerView.addSubview(label)

        fadeMask.startPoint = CGPoint(x: 0, y: 0.5)
        fadeMask.endPoint = CGPoint(x: 1, y: 0.5)
        fadeMask.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]

        shimmerMask.colors = [
            NSColor.black.cgColor,
            NSColor.black.withAlphaComponent(0.1).cgColor,
            NSColor.black.cgColor
        ]
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    /// Medium weight in the strong text color, as folder titles use.
    func setEmphasized(_ emphasized: Bool) {
        guard emphasized != isEmphasized else { return }
        isEmphasized = emphasized
        label.font = emphasized ? Self.emphasizedFont : Self.font
        label.phi.setTextColor(emphasized ? .textPrimaryStrong : .textPrimary)
    }

    func render(title: String, isShimmering: Bool) {
        if label.stringValue != title {
            label.stringValue = title
        }
        shimmerView.frame = bounds
        let width = max(bounds.width, ceil(label.intrinsicContentSize.width))
        label.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)

        fadeMask.frame = bounds
        let fadeStart = bounds.width > 0
            ? max(0, (bounds.width - min(Self.fadeWidth, bounds.width)) / bounds.width)
            : 0
        fadeMask.locations = [0, NSNumber(value: Double(fadeStart)), 1]
        if layer?.mask !== fadeMask {
            layer?.mask = fadeMask
        }

        guard let shimmerLayer = shimmerView.layer else { return }
        guard isShimmering else {
            if shimmerLayer.mask != nil {
                shimmerMask.removeAnimation(forKey: Self.shimmerKey)
                shimmerLayer.mask = nil
                shimmerSize = nil
            }
            return
        }
        let size = shimmerView.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        shimmerMask.frame = shimmerView.bounds
        if shimmerLayer.mask !== shimmerMask {
            shimmerLayer.mask = shimmerMask
        }
        if shimmerSize != size || shimmerMask.animation(forKey: Self.shimmerKey) == nil {
            shimmerSize = size
            shimmerMask.add(Self.makeShimmerAnimation(size: size), forKey: Self.shimmerKey)
        }
    }

    /// The SwiftUI shimmer's band: a gradient running from
    /// (-band + (1 + band) * phase, -band) to ((1 + band) * phase, 1 + band)
    /// in y-down unit points, with its stripes perpendicular in points.
    /// CAGradientLayer draws its stripes perpendicular in unit space, so the
    /// end point is moved to give the same stripes at this size, and y flips
    /// for the layer's y-up unit space.
    private static func makeShimmerAnimation(size: CGSize) -> CAAnimation {
        let band = shimmerBandSize
        let axis = CGVector(dx: band * size.width, dy: (1 + 2 * band) * size.height)
        let axisLengthSquared = axis.dx * axis.dx + axis.dy * axis.dy
        let unitGradient = CGVector(
            dx: axis.dx * size.width / axisLengthSquared,
            dy: axis.dy * size.height / axisLengthSquared
        )
        let unitGradientLengthSquared = unitGradient.dx * unitGradient.dx + unitGradient.dy * unitGradient.dy
        let offset = CGVector(
            dx: unitGradient.dx / unitGradientLengthSquared,
            dy: -unitGradient.dy / unitGradientLengthSquared
        )

        let startFrom = CGPoint(x: -band, y: 1 + band)
        let startTo = CGPoint(x: 1, y: 1 + band)
        let start = CABasicAnimation(keyPath: "startPoint")
        start.fromValue = startFrom
        start.toValue = startTo
        let end = CABasicAnimation(keyPath: "endPoint")
        end.fromValue = CGPoint(x: startFrom.x + offset.dx, y: startFrom.y + offset.dy)
        end.toValue = CGPoint(x: startTo.x + offset.dx, y: startTo.y + offset.dy)
        let group = CAAnimationGroup()
        group.animations = [start, end]
        group.duration = shimmerDuration
        group.repeatCount = .infinity
        // Every loading row shares one phase, read off the wall clock as the
        // SwiftUI timeline did.
        group.timeOffset = Date().timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: shimmerDuration)
        return group
    }
}

/// The agent / chat status badge at the row's top-trailing corner.
final class SideTabCornerBadgeView: SideTabPassthroughView {
    private var renderedStatus: TabCornerBadgeStatus?
    private var renderedColor: NSColor?
    private var contentView: NSView?

    func render(status: TabCornerBadgeStatus?, theme: Theme?, appearance: Appearance) {
        let color = theme.map { BookmarkFolderIcon.strokeColor(theme: $0, appearance: appearance) }
        guard status != renderedStatus || color != renderedColor else { return }
        if status != renderedStatus {
            contentView?.removeFromSuperview()
            contentView = status.map { makeContent(for: $0) }
            if let contentView {
                contentView.frame = bounds
                contentView.autoresizingMask = [.width, .height]
                addSubview(contentView)
            }
        }
        renderedStatus = status
        renderedColor = color
        applyColor(color ?? .labelColor)
    }

    private func makeContent(for status: TabCornerBadgeStatus) -> NSView {
        let name: String
        let fallbackSymbol: String
        switch status {
        case .agent:
            name = "agent"
            fallbackSymbol = "sparkle"
        case .inputting, .chat:
            name = "inputting"
            fallbackSymbol = "ellipsis"
        }
        guard let animation = LottieAnimation.named(name, bundle: .main, subdirectory: "LottieFiles") else {
            let imageView = NSImageView()
            imageView.image = NSImage(systemSymbolName: fallbackSymbol, accessibilityDescription: nil)
            imageView.imageScaling = .scaleProportionallyUpOrDown
            return imageView
        }
        let animationView = Lottie.LottieAnimationView(
            animation: animation,
            configuration: LottieConfiguration(renderingEngine: .mainThread)
        )
        if status == .chat {
            animationView.currentProgress = 0
        } else {
            animationView.loopMode = .loop
            animationView.play()
        }
        return animationView
    }

    private func applyColor(_ color: NSColor) {
        if let animationView = contentView as? Lottie.LottieAnimationView {
            animationView.setValueProvider(
                ColorValueProvider(color.lottieColor),
                keypath: AnimationKeypath(keypath: "**.Color")
            )
        } else if let imageView = contentView as? NSImageView {
            imageView.contentTintColor = color
        }
    }
}

/// Stands beside the row where a dragged tab would land as a split pane.
final class SideTabSplitPlaceholderView: SideTabPassthroughView {
    private let symbolView = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        symbolView.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        symbolView.contentTintColor = NSColor.secondaryLabelColor.withAlphaComponent(0.65)
        addSubview(symbolView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let size = symbolView.intrinsicContentSize
        symbolView.frame = NSRect(x: (bounds.width - size.width) / 2,
                                  y: (bounds.height - size.height) / 2,
                                  width: size.width, height: size.height)
        updateFill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateFill()
    }

    private func updateFill() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        }
    }
}

/// Stands where a dragged tab would land as a pane: inside a split row it
/// would join.
struct TabSplitDropPlaceholder: View {
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.primary.opacity(0.08))
            .overlay {
                Image(systemName: "rectangle.split.2x1")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.secondary.opacity(0.65))
            }
    }
}

// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

/// Native overlay for an agent Space's content area. Renders the agent cursor
/// and a status/control pill, and — in watch mode — swallows content input so
/// a watching user can't disturb the agent's page; ownership transfers only
/// through the pill's explicit "Take control" button. A native layer is used
/// (not injected DOM) so it survives navigation, works over any page, and can
/// reliably act as the input interceptor.
final class AgentSpaceOverlayView: NSView {
    var onTakeControl: (() -> Void)?
    var onHandBack: (() -> Void)?
    var onFinish: (() -> Void)?

    private var ownership: AgentTaskOwnership = .agent

    private let cursorLayer = CALayer()
    private let cursorFillLayer = CAGradientLayer()
    private let cursorStrokeLayer = CAShapeLayer()
    /// Distinguishes a sampled cursor path from an occasional endpoint update.
    /// Rapid samples get a short linear bridge; isolated updates retain the
    /// longer native glide used by older drivers.
    private var lastCursorTargetUpdate: CFTimeInterval?
    /// The current typing-pulse outline, replaced (not stacked) on rapid fills.
    private weak var typingPulseLayer: CALayer?
    private let pill = NSVisualEffectView()
    /// Badge for the driving code agent: an SF Symbol glyph plus a short name
    /// ("Claude Code", "Codex", …), so a watching user sees who controls this
    /// Space, not just that "an agent" does.
    private let agentIcon = NSImageView()
    /// Sized per icon source in `update`: brand assets pad their ink (see
    /// `AgentDriverBadge.assetInkRatio`) and get a wider slot so the visible
    /// glyph matches the 14pt the SF Symbol fallback occupies.
    private var agentIconWidth: NSLayoutConstraint?
    private var agentIconHeight: NSLayoutConstraint?
    private let agentLabel = NSTextField(labelWithString: "")
    private let agentDivider = NSBox()
    private let captionLabel = NSTextField(labelWithString: "")
    private let primaryButton = NSButton()
    private let secondaryButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setupCursor()
        setupPill()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Setup

    /// The cursor glyph's design-asset size (viewBox units) and its scale to
    /// the rendered 27pt-tall cursor.
    private static let cursorDesignSize = CGSize(width: 14.0089, height: 15.9927)
    private static let cursorScale: CGFloat = 27.0 / cursorDesignSize.height

    private func setupCursor() {
        // The arrow is a path, not an image, so its fill and border can follow
        // the Space's theme — colors are applied by `applyTheme`, called from
        // the hosting controller on mount and on every theme change.
        let path = Self.makeCursorPath()
        let pad = Self.cursorScale  // room for the centered border stroke
        cursorLayer.bounds = CGRect(
            x: 0, y: 0,
            width: path.boundingBoxOfPath.maxX + pad,
            height: path.boundingBoxOfPath.maxY + pad)
        // Pin the glyph's tip (top-left) to the reported cursor point, the way
        // a real pointer's hotspot sits at its tip.
        cursorLayer.anchorPoint = CGPoint(x: 0.1, y: 0.89)
        cursorLayer.isHidden = true

        let mask = CAShapeLayer()
        mask.path = path
        mask.frame = cursorLayer.bounds
        cursorFillLayer.frame = cursorLayer.bounds
        cursorFillLayer.mask = mask
        // Pale at the visual top of the arrow, theme color at the bottom
        // (unit coords are y-up in an unflipped view).
        cursorFillLayer.startPoint = CGPoint(x: 0.5, y: 1)
        cursorFillLayer.endPoint = CGPoint(x: 0.5, y: 0)
        cursorLayer.addSublayer(cursorFillLayer)

        cursorStrokeLayer.path = path
        cursorStrokeLayer.frame = cursorLayer.bounds
        cursorStrokeLayer.fillColor = nil
        cursorStrokeLayer.lineWidth = Self.cursorScale  // the design's 1px border
        cursorStrokeLayer.lineJoin = .round
        cursorLayer.addSublayer(cursorStrokeLayer)

        layer?.addSublayer(cursorLayer)
    }

    /// Tints the agent cursor from the Space's theme. Light appearance fills
    /// the arrow with a vertical gradient from a pale tint of the theme color
    /// down to the theme color itself, bordered in a dark shade of the same
    /// hue; dark appearance fills with the theme color outlined in white.
    func applyTheme(_ theme: Theme, appearance: Appearance) {
        guard let themeColor = theme.color(for: .themeColor, appearance: appearance)
            .usingColorSpace(.sRGB) else { return }
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        themeColor.getHue(
            &hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        switch appearance {
        case .light:
            let tint = NSColor(
                hue: hue, saturation: saturation * 0.28,
                brightness: max(brightness, 0.96), alpha: 1)
            let border = NSColor(
                hue: hue, saturation: min(saturation + 0.05, 1),
                brightness: 0.3, alpha: 1)
            cursorFillLayer.colors = [tint.cgColor, themeColor.cgColor]
            cursorStrokeLayer.strokeColor = border.cgColor
        case .dark:
            cursorFillLayer.colors = [themeColor.cgColor, themeColor.cgColor]
            cursorStrokeLayer.strokeColor = NSColor.white.cgColor
        }

        accentFill = themeColor
        applyPrimaryButtonTint(title: primaryButton.title)
    }

    /// The arrow glyph from the design, authored y-down in a
    /// 14.0089 × 15.9927 viewBox and flipped/scaled into layer space.
    private static func makeCursorPath() -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 0.5039, y: 1.8181))
        p.addCurve(
            to: CGPoint(x: 2.8730, y: 0.8133),
            control1: CGPoint(x: 0.5893, y: 0.6644),
            control2: CGPoint(x: 1.9677, y: 0.1012))
        p.addLine(to: CGPoint(x: 12.9990, y: 8.7879))
        p.addCurve(
            to: CGPoint(x: 12.1641, y: 11.1219),
            control1: CGPoint(x: 14.0076, y: 9.5821),
            control2: CGPoint(x: 13.3921, y: 11.1219))
        p.addLine(to: CGPoint(x: 6.5400, y: 11.1219))
        p.addCurve(
            to: CGPoint(x: 6.1689, y: 11.2039),
            control1: CGPoint(x: 6.4112, y: 11.1219),
            control2: CGPoint(x: 6.2842, y: 11.1504))
        p.addCurve(
            to: CGPoint(x: 5.8750, y: 11.4285),
            control1: CGPoint(x: 6.0539, y: 11.2573),
            control2: CGPoint(x: 5.9535, y: 11.3341))
        p.addLine(to: CGPoint(x: 2.8984, y: 15.0076))
        p.addCurve(
            to: CGPoint(x: 0.5000, y: 14.1668),
            control1: CGPoint(x: 2.1136, y: 15.9510),
            control2: CGPoint(x: 0.5001, y: 15.4459))
        p.addLine(to: CGPoint(x: 0.5000, y: 1.9314))
        p.closeSubpath()
        var flip = CGAffineTransform(scaleX: cursorScale, y: -cursorScale)
            .translatedBy(x: 0, y: -cursorDesignSize.height)
        return p.copy(using: &flip) ?? p
    }

    private func setupPill() {
        pill.material = .hudWindow
        pill.blendingMode = .withinWindow
        pill.state = .active
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 16
        pill.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pill)

        agentIcon.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        agentIcon.contentTintColor = .labelColor
        agentIcon.imageScaling = .scaleProportionallyUpOrDown
        agentIcon.translatesAutoresizingMaskIntoConstraints = false
        agentIcon.setContentHuggingPriority(.required, for: .horizontal)
        agentIconWidth = agentIcon.widthAnchor.constraint(equalToConstant: 14)
        agentIconHeight = agentIcon.heightAnchor.constraint(equalToConstant: 14)
        NSLayoutConstraint.activate([agentIconWidth!, agentIconHeight!])

        agentLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        agentLabel.textColor = .labelColor
        agentLabel.lineBreakMode = .byTruncatingTail
        agentLabel.translatesAutoresizingMaskIntoConstraints = false
        agentLabel.setContentHuggingPriority(.required, for: .horizontal)

        agentDivider.boxType = .separator
        agentDivider.translatesAutoresizingMaskIntoConstraints = false

        captionLabel.font = .systemFont(ofSize: 12, weight: .medium)
        captionLabel.textColor = .labelColor
        captionLabel.lineBreakMode = .byTruncatingTail
        captionLabel.translatesAutoresizingMaskIntoConstraints = false

        configureButton(primaryButton, action: #selector(primaryTapped))
        configureButton(secondaryButton, action: #selector(secondaryTapped))

        let stack = NSStackView(views: [
            agentIcon, agentLabel, agentDivider, captionLabel,
            primaryButton, secondaryButton])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        stack.setCustomSpacing(6, after: agentIcon)
        stack.setCustomSpacing(10, after: agentDivider)
        stack.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(stack)

        NSLayoutConstraint.activate([
            agentDivider.heightAnchor.constraint(equalToConstant: 18),
        ])

        NSLayoutConstraint.activate([
            pill.centerXAnchor.constraint(equalTo: centerXAnchor),
            pill.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),
            pill.heightAnchor.constraint(equalToConstant: 40),
            stack.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -16),
            stack.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
        ])
    }

    private func configureButton(_ button: NSButton, action: Selector) {
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    // MARK: - Primary action tint

    /// Fill for the ownership-transfer button, from the Space theme. Held
    /// because the button's title changes with ownership and every title change
    /// discards the attributed string carrying its text color.
    private var accentFill: NSColor?

    /// Paints the primary action in the Space theme, so the one control that
    /// transfers ownership reads as part of the mask rather than as a system
    /// button sitting on top of it.
    private func applyPrimaryButtonTint(title: String) {
        guard let fill = accentFill else { return }
        primaryButton.bezelColor = fill
        primaryButton.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .foregroundColor: Self.onAccentColor(for: fill),
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            ])
    }

    /// The design's own rule for text on the primary color, so this button and
    /// the buttons the page recoloring paints resolve their contrast the same
    /// way rather than drifting apart.
    private static func onAccentColor(for fill: NSColor) -> NSColor {
        let color = fill.usingColorSpace(.sRGB) ?? fill
        let high = max(color.redComponent, color.greenComponent, color.blueComponent)
        let low = min(color.redComponent, color.greenComponent, color.blueComponent)
        return (high + low) / 2 > 0.66
            ? NSColor(srgbRed: 0x17 / 255, green: 0x15 / 255, blue: 0x1A / 255, alpha: 1)
            : .white
    }

    /// True when `point` — in `sourceView`'s coordinates — lands on the control
    /// pill. The pill is the only live control this overlay exposes, so the
    /// operating mask mounted below it asks before claiming input or the
    /// pointer, which would otherwise strand the user with no way to take
    /// control back.
    func containsControlPill(at point: NSPoint, from sourceView: NSView) -> Bool {
        guard window != nil, !pill.isHidden, !pill.bounds.isEmpty else { return false }
        return pill.bounds.contains(pill.convert(point, from: sourceView))
    }

    // MARK: - Update

    func update(with task: AgentTask?) {
        guard let task else { return }
        ownership = task.ownership

        let badge = AgentDriverBadge.make(agentName: task.agentName, origin: task.origin)
        if let assetName = badge.assetName, let image = NSImage(named: assetName) {
            image.isTemplate = true  // tint with contentTintColor
            agentIcon.image = image
            agentIconWidth?.constant = 14 / AgentDriverBadge.assetInkRatio
            agentIconHeight?.constant = 14 / AgentDriverBadge.assetInkRatio
        } else {
            agentIcon.image = NSImage(systemSymbolName: badge.symbol,
                                      accessibilityDescription: badge.label)
            agentIconWidth?.constant = 14
            agentIconHeight?.constant = 14
        }
        agentLabel.stringValue = badge.label
        agentIcon.toolTip = badge.label
        agentLabel.toolTip = badge.label

        switch task.status {
        case .failed(let message):
            captionLabel.stringValue = "⚠︎ \(message)"
            captionLabel.textColor = .systemRed
        default:
            captionLabel.stringValue = task.statusCaption.isEmpty
                ? (ownership == .agent ? "Agent is working…" : "Agent paused")
                : task.statusCaption
            captionLabel.textColor = .labelColor
        }

        let primaryTitle: String
        switch ownership {
        case .agent:
            primaryTitle = "Take control"
            primaryButton.isHidden = false
            secondaryButton.isHidden = true
        case .user:
            primaryTitle = "Hand back"
            secondaryButton.title = "Finish"
            primaryButton.isHidden = false
            secondaryButton.isHidden = false
        }
        primaryButton.title = primaryTitle
        applyPrimaryButtonTint(title: primaryTitle)

        if let point = task.cursor {
            // Cursor point is in view coordinates (converted by the mounter).
            let wasHidden = cursorLayer.isHidden
            cursorLayer.isHidden = false
            let current = cursorLayer.presentation()?.position ?? cursorLayer.position
            let previousTarget = cursorLayer.position
            let distance = hypot(point.x - current.x, point.y - current.y)
            let targetChanged = hypot(point.x - previousTarget.x, point.y - previousTarget.y) >= 0.5
            let now = CACurrentMediaTime()
            let updateGap = targetChanged ? lastCursorTargetUpdate.map { now - $0 } : nil
            if targetChanged {
                lastCursorTargetUpdate = now
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            cursorLayer.position = point
            CATransaction.commit()
            if !wasHidden && distance >= 2 {
                // A sampled driver reports the same path points it dispatches
                // into the page. Bridge rapid points over approximately one
                // sample interval so the overlay follows that curved trace.
                // Older drivers report isolated endpoints; retain their longer
                // eased glide. First appearance skips animation because there
                // is no meaningful prior position.
                let glide = CABasicAnimation(keyPath: "position")
                glide.fromValue = current
                glide.toValue = point
                if let updateGap, updateGap < 0.09 {
                    glide.duration = min(0.05, max(1.0 / 120.0, updateGap * 1.15))
                    glide.timingFunction = CAMediaTimingFunction(name: .linear)
                } else {
                    glide.duration = min(0.45, max(0.18, distance / 1000))
                    glide.timingFunction = CAMediaTimingFunction(
                        controlPoints: 0.3, 0.0, 0.15, 1.0)
                }
                cursorLayer.add(glide, forKey: "glide")
            } else {
                cursorLayer.removeAnimation(forKey: "glide")
            }
        } else {
            cursorLayer.isHidden = true
            lastCursorTargetUpdate = nil
        }
    }

    // MARK: - Transient input effects

    /// Plays a short, self-removing animation mirroring one agent input action
    /// so a watching user can follow what the agent is doing. `point` is in
    /// this view's coordinate space (converted by the mounter).
    func playEffect(kind: AgentEffect.Kind, at point: CGPoint, size: CGSize?, dy: CGFloat?) {
        switch kind {
        case .click: playClickRipple(at: point)
        case .type: playTypingPulse(at: point, size: size)
        case .scroll: playScrollHint(at: point, dy: dy ?? 1)
        }
    }

    private var effectColor: CGColor {
        NSColor.controlAccentColor.cgColor
    }

    private func addTransientLayer(_ transient: CALayer, removeAfter delay: TimeInterval) {
        layer?.addSublayer(transient)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak transient] in
            transient?.removeFromSuperlayer()
        }
    }

    /// Two staggered rings expanding out of the click point over a brief
    /// center dot — reads as a "tap" even at a glance.
    private func playClickRipple(at point: CGPoint) {
        let dot = CAShapeLayer()
        dot.path = CGPath(ellipseIn: CGRect(x: -4, y: -4, width: 8, height: 8), transform: nil)
        dot.fillColor = effectColor
        dot.position = point
        let dotFade = CABasicAnimation(keyPath: "opacity")
        dotFade.fromValue = 1.0
        dotFade.toValue = 0.0
        dotFade.duration = 0.35
        dotFade.isRemovedOnCompletion = false
        dotFade.fillMode = .forwards
        dot.add(dotFade, forKey: "fade")
        addTransientLayer(dot, removeAfter: 0.4)

        for (index, delay) in [0.0, 0.14].enumerated() {
            let ring = CAShapeLayer()
            let radius: CGFloat = index == 0 ? 18 : 26
            ring.path = CGPath(
                ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2),
                transform: nil)
            ring.fillColor = nil
            ring.strokeColor = effectColor
            ring.lineWidth = 2.5
            ring.position = point
            ring.opacity = 0

            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.25
            scale.toValue = 1.0
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0.0, 0.85, 0.0]
            fade.keyTimes = [0, 0.25, 1]
            let group = CAAnimationGroup()
            group.animations = [scale, fade]
            group.duration = 0.5
            group.beginTime = CACurrentMediaTime() + delay
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ring.add(group, forKey: "ripple")
            addTransientLayer(ring, removeAfter: delay + 0.55)
        }
    }

    /// A pulsing outline around the field being typed into, with three
    /// "typing…" dots blinking under its trailing edge.
    private func playTypingPulse(at point: CGPoint, size: CGSize?) {
        // Replace any still-visible pulse: rapid fills must not stack outlines.
        typingPulseLayer?.removeFromSuperlayer()

        let width = min(max(size?.width ?? 160, 40), max(bounds.width, 40))
        let height = min(max(size?.height ?? 32, 22), max(bounds.height, 22))
        let boxSize = CGSize(width: width + 8, height: height + 8)
        let box = CAShapeLayer()
        box.path = CGPath(
            roundedRect: CGRect(origin: .zero, size: boxSize),
            cornerWidth: 7, cornerHeight: 7, transform: nil)
        box.bounds = CGRect(origin: .zero, size: boxSize)
        box.position = point
        box.strokeColor = effectColor
        box.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.07).cgColor
        box.lineWidth = 2

        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.45
        pulse.duration = 0.4
        pulse.autoreverses = true
        pulse.repeatCount = 2
        box.add(pulse, forKey: "pulse")

        // Group opacity carries the dots out with the box.
        let fadeOut = CABasicAnimation(keyPath: "opacity")
        fadeOut.fromValue = 1.0
        fadeOut.toValue = 0.0
        fadeOut.duration = 0.25
        fadeOut.beginTime = CACurrentMediaTime() + 1.6
        fadeOut.isRemovedOnCompletion = false
        fadeOut.fillMode = .forwards
        box.add(fadeOut, forKey: "fadeOut")

        for i in 0..<3 {
            let typingDot = CAShapeLayer()
            typingDot.path = CGPath(
                ellipseIn: CGRect(x: -2.5, y: -2.5, width: 5, height: 5), transform: nil)
            typingDot.fillColor = effectColor
            // Under the box's bottom-right corner (unflipped coords: below = -y).
            typingDot.position = CGPoint(x: boxSize.width - 30 + CGFloat(i) * 11, y: -9)
            typingDot.opacity = 0.2
            let blink = CAKeyframeAnimation(keyPath: "opacity")
            blink.values = [0.2, 1.0, 0.2]
            blink.keyTimes = [0, 0.5, 1]
            blink.duration = 0.6
            blink.repeatCount = 3
            blink.beginTime = CACurrentMediaTime() + Double(i) * 0.15
            typingDot.add(blink, forKey: "blink")
            box.addSublayer(typingDot)
        }

        typingPulseLayer = box
        addTransientLayer(box, removeAfter: 1.95)
    }

    /// Three chevrons drifting in the scroll direction from the wheel's anchor
    /// point. `dy` follows the wheel convention: positive scrolls the page
    /// down, so the hint drifts down-screen (-y in unflipped view coords).
    private func playScrollHint(at point: CGPoint, dy: CGFloat) {
        let downOnScreen = dy >= 0
        let travel: CGFloat = downOnScreen ? -34 : 34
        let apexY: CGFloat = downOnScreen ? -5 : 5
        for i in 0..<3 {
            let chevron = CAShapeLayer()
            let path = CGMutablePath()
            path.move(to: CGPoint(x: -10, y: -apexY))
            path.addLine(to: CGPoint(x: 0, y: apexY))
            path.addLine(to: CGPoint(x: 10, y: -apexY))
            chevron.path = path
            chevron.strokeColor = effectColor
            chevron.fillColor = nil
            chevron.lineWidth = 3
            chevron.lineCap = .round
            chevron.lineJoin = .round
            chevron.position = point
            chevron.opacity = 0

            let move = CABasicAnimation(keyPath: "position.y")
            move.fromValue = point.y - travel * 0.5
            move.toValue = point.y + travel
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0.0, 0.9, 0.0]
            fade.keyTimes = [0, 0.35, 1]
            let group = CAAnimationGroup()
            group.animations = [move, fade]
            group.duration = 0.55
            group.beginTime = CACurrentMediaTime() + Double(i) * 0.12
            group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            chevron.add(group, forKey: "drift")
            addTransientLayer(chevron, removeAfter: Double(i) * 0.12 + 0.6)
        }
    }

    // MARK: - Actions

    @objc private func primaryTapped() {
        switch ownership {
        case .agent: onTakeControl?()
        case .user: onHandBack?()
        }
    }

    @objc private func secondaryTapped() {
        onFinish?()
    }

    // MARK: - Input interception

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Always let the pill's controls receive events.
        let pointInPill = convert(point, to: pill)
        if pill.bounds.contains(pointInPill), let hit = super.hitTest(point) {
            return hit
        }
        // Watch mode: swallow all content input so a watching user can't
        // interfere with the agent — but taking control requires the explicit
        // "Take control" button, NOT a stray page click. User mode: pass
        // content through so the user can browse.
        return ownership == .agent ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        // Agent mode: swallow the click (no-op). Do NOT take control — only the
        // "Take control" button (primaryTapped) transfers ownership.
    }

    override func scrollWheel(with event: NSEvent) {
        // Agent mode: swallow scroll so a watching user can't move the agent's
        // page. (In user mode this view isn't in the hit path.)
        if ownership != .agent { super.scrollWheel(with: event) }
    }

    override func rightMouseDown(with event: NSEvent) {
        if ownership != .agent { super.rightMouseDown(with: event) }
    }

    override func otherMouseDown(with event: NSEvent) {
        if ownership != .agent { super.otherMouseDown(with: event) }
    }

    override func mouseDragged(with event: NSEvent) {
        if ownership != .agent { super.mouseDragged(with: event) }
    }

    override func magnify(with event: NSEvent) {
        if ownership != .agent { super.magnify(with: event) }
    }

    override func swipe(with event: NSEvent) {
        if ownership != .agent { super.swipe(with: event) }
    }

    override func keyDown(with event: NSEvent) {
        // Agent mode: swallow keys (no-op) so they neither reach the page nor
        // take control. User mode: this view isn't in the hit path.
        if ownership != .agent {
            super.keyDown(with: event)
        }
    }

    override var acceptsFirstResponder: Bool { ownership == .agent }
}

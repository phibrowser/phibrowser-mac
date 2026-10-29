// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import CryptoKit
import QuartzCore

/// A native foil card shared by onboarding and account settings. Geometry is
/// authored at the reference's 292 x 423 points; resizing never rebuilds its art.
final class HolographicCardView: NSView {
    static let designSize = HolographicCardArtwork.size

    static func formattedJoinDate(_ value: String) -> String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = parser.date(from: value)
        if date == nil {
            parser.formatOptions = [.withInternetDateTime]
            date = parser.date(from: value)
        }
        guard let date else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy.MM"
        return formatter.string(from: date)
    }

    /// First 16 hex digits of the SHA-256 of the Auth0 `sub`.
    static func memberID(sub: String) -> String {
        guard !sub.isEmpty else { return "" }
        return SHA256.hash(data: Data(sub.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Builds artwork ahead of time; a card stays hidden until its artwork is ready.
    static func prepareArtwork(for style: HolographicCardStyle = .default) {
        Task.detached(priority: .utility) {
            _ = await HolographicCardArtwork.cache.material(for: style)
        }
    }

    var name = "Phi" { didSet { updateCopy() } }
    var memberID = "" { didSet { updateCopy() } }
    var joinedDate = "" { didSet { updateCopy() } }
    var style: HolographicCardStyle { didSet { if oldValue != style { updateMaterial() } } }
    var showsReverse = false { didSet { renderMotion() } }
    var animatesIdleTilt = false { didSet { updateAnimationState() } }

    func replayEntrance() {
        motion = HolographicCardMotion()
        lastTick = nil
        updateAnimationState()
    }

    var isPresentationActive = true { didSet { updateAnimationState() } }

    private let rotor = CATransformLayer()
    private let front: HolographicCardFace
    private let back: HolographicCardFace
    private var materialTask: Task<Void, Never>?
    private(set) var renderedStyle: HolographicCardStyle?
    private var tracking: NSTrackingArea?
    private var timer: Timer?
    private var lastTick: CFTimeInterval?
    private var motion = HolographicCardMotion()
    private var pointer: CGPoint? {
        didSet { if oldValue != pointer { updateAnimationState() } }
    }
    private(set) var isAnimating = false

    private var needsMotion: Bool {
        animatesIdleTilt || motion.entrance < 1 || pointer != nil || motion.position != .zero
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override convenience init(frame frameRect: NSRect) {
        self.init(frame: frameRect, style: .default)
    }

    init(frame frameRect: NSRect = .zero, style: HolographicCardStyle, showsShadow: Bool = true) {
        self.style = style
        front = HolographicCardFace(isBack: false, showsShadow: showsShadow)
        back = HolographicCardFace(isBack: true, showsShadow: showsShadow)
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.addSublayer(rotor)
        rotor.isHidden = true
        rotor.bounds = CGRect(origin: .zero, size: Self.designSize)
        rotor.addSublayer(front.layer)
        rotor.addSublayer(back.layer)
        back.layer.transform = CATransform3DMakeRotation(.pi, 0, 1, 0)
        updateCopy()
        updateMaterial()
        setAccessibilityElement(true)
        setAccessibilityRole(.image)

        NotificationCenter.default.addObserver(self, selector: #selector(windowVisibilityChanged),
            name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(motionPreferenceChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        materialTask?.cancel()
        timer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    override func layout() {
        super.layout()
        renderMotion()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        pointer = nil
        updateAnimationState()
    }

    override func viewDidHide() {
        super.viewDidHide()
        updateAnimationState()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateAnimationState()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { updatePointer(event) }
    override func mouseMoved(with event: NSEvent) { updatePointer(event) }
    override func mouseDragged(with event: NSEvent) { updatePointer(event) }
    override func mouseExited(with event: NSEvent) { pointer = nil }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        updatePointer(event)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: pointer = CGPoint(x: -0.7, y: 0)
        case 124: pointer = CGPoint(x: 0.7, y: 0)
        case 125: pointer = CGPoint(x: 0, y: 0.7)
        case 126: pointer = CGPoint(x: 0, y: -0.7)
        default: super.keyDown(with: event)
        }
    }

    override func resignFirstResponder() -> Bool {
        pointer = nil
        return super.resignFirstResponder()
    }

    private func updatePointer(_ event: NSEvent) {
        pointer = HolographicCardMotion.normalizedPointer(
            convert(event.locationInWindow, from: nil), in: bounds)
    }

    @objc private func windowVisibilityChanged(_ notification: Notification) {
        guard let changedWindow = notification.object as? NSWindow, changedWindow === window else { return }
        updateAnimationState()
    }

    @objc private func motionPreferenceChanged() { updateAnimationState() }

    private func updateAnimationState() {
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduced { motion.finishEntrance() }
        let shouldAnimate = renderedStyle != nil && isPresentationActive && !reduced && !isHiddenOrHasHiddenAncestor
            && window?.occlusionState.contains(.visible) == true
            && needsMotion
        if shouldAnimate && timer == nil {
            lastTick = nil
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            timer.tolerance = 1.0 / 240
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !shouldAnimate {
            timer?.invalidate()
            timer = nil
            lastTick = nil
            pointer = nil
        }
        isAnimating = shouldAnimate
        renderMotion()
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let delta = min(1.0 / 15, max(0, now - (lastTick ?? now)))
        lastTick = now
        guard !visibleRect.isEmpty else { return }
        motion.advance(by: delta, pointer: pointer ?? (animatesIdleTilt ? nil : .zero))
        if !needsMotion {
            updateAnimationState()
        } else {
            renderMotion()
        }
    }

    private func renderMotion() {
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let entrance = reduced ? 1 : motion.entrance
        let x = reduced ? 0 : motion.position.x
        let y = reduced ? 0 : motion.position.y
        let spin = -2 * CGFloat.pi * (1 - entrance) + (showsReverse ? .pi : 0)
        let scale = min(bounds.width / Self.designSize.width, bounds.height / Self.designSize.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rotor.position = CGPoint(x: bounds.midX, y: bounds.midY)
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / 1100
        layer?.sublayerTransform = perspective
        var transform = CATransform3DMakeScale(scale * (0.16 + 0.84 * entrance), scale * (0.16 + 0.84 * entrance), scale)
        transform = CATransform3DRotate(transform, -y * 10 * .pi / 180 * entrance, 1, 0, 0)
        transform = CATransform3DRotate(transform, x * 1.7 * .pi / 180 * entrance, 0, 0, 1)
        transform = CATransform3DRotate(transform, x * 13 * .pi / 180 * entrance + spin, 0, 1, 0)
        rotor.transform = transform
        rotor.opacity = Float(min(1, motion.elapsed / (1.7 * 0.18)))
        if reduced { rotor.opacity = 1 }
        front.light(x: x + 1.45 * sin(spin), y: y + 0.25 * (1 - cos(spin)), facing: cos(spin))
        back.light(x: x + 1.45 * sin(spin + .pi), y: y + 0.25 * (1 - cos(spin + .pi)), facing: cos(spin + .pi))
        CATransaction.commit()
    }

    private func updateCopy() {
        front.setCopy(name: name, identifier: memberID, joinedDate: joinedDate)
        setAccessibilityLabel([name, memberID, joinedDate].filter { !$0.isEmpty }.joined(separator: ", "))
    }

    private func updateMaterial() {
        materialTask?.cancel()
        let requestedStyle = style
        materialTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let material = await HolographicCardArtwork.cache.material(for: requestedStyle)
            guard !Task.isCancelled, let self, self.style == requestedStyle else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.front.setStyle(requestedStyle, artwork: material)
            self.back.setStyle(requestedStyle, artwork: material)
            self.renderedStyle = requestedStyle
            self.rotor.isHidden = false
            CATransaction.commit()
            self.updateAnimationState()
        }
    }

    /// Export the fully readable front, independently of an in-flight 3D spin.
    /// Await artwork even if export is requested before the live card is ready.
    func frontImage(scale: CGFloat = 3) async -> NSImage? {
        guard scale > 0, scale <= 4 else { return nil }
        let style = style, name = name, memberID = memberID, joinedDate = joinedDate
        let artwork = await HolographicCardArtwork.cache.material(for: style)
        guard !Task.isCancelled else { return nil }
        let face = HolographicCardFace(isBack: false)
        face.setStyle(style, artwork: artwork)
        face.setCopy(name: name, identifier: memberID, joinedDate: joinedDate)
        face.light(x: 0, y: 0, facing: 1)
        guard let image = face.image(scale: scale) else { return nil }
        return NSImage(cgImage: image, size: Self.designSize)
    }
}

struct HolographicCardMotion {
    private(set) var elapsed: TimeInterval = 0
    private(set) var position = CGPoint.zero
    var entrance: CGFloat { 1 - pow(1 - min(1, elapsed / 1.7), 3) }

    mutating func finishEntrance() { elapsed = max(elapsed, 1.7) }

    mutating func advance(by delta: TimeInterval, pointer: CGPoint?) {
        guard delta.isFinite, delta > 0 else { return }
        elapsed += delta
        let target = pointer ?? CGPoint(x: sin(elapsed * 0.55) * 0.65, y: cos(elapsed * 0.43) * 0.45)
        // Preserve the reference's 60 Hz response at other display refresh rates.
        let smoothing = 1 - pow(1 - 0.075, delta * 60)
        position.x += (target.x - position.x) * smoothing
        position.y += (target.y - position.y) * smoothing
        if target == .zero && abs(position.x) < 0.0001 && abs(position.y) < 0.0001 {
            position = .zero
        }
    }

    static func normalizedPointer(_ point: CGPoint, in bounds: CGRect) -> CGPoint {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        return CGPoint(x: max(-1, min(1, (point.x - bounds.minX) / bounds.width * 2 - 1)),
                       y: max(-1, min(1, (point.y - bounds.minY) / bounds.height * 2 - 1)))
    }
}

@MainActor
private final class HolographicCardFace {
    let layer = CALayer()
    private let surface = CALayer()
    private let material = CAGradientLayer()
    private let iridescenceGroup = CALayer()
    private let iridescence = CAGradientLayer()
    private let foil = CALayer()
    private let grain = CALayer()
    private let sealGroove = CAGradientLayer()
    private let sealGrooveMask = CAShapeLayer()
    private let sealReflectionMask = CAShapeLayer()
    private var style = HolographicCardStyle.default
    private let sheen = CAGradientLayer()
    private let logoSweep = CAGradientLayer()
    private let sealReflection = CAGradientLayer()
    private let shade = CALayer()
    private let name = CATextLayer()
    private let identifier = CATextLayer()
    private let dateLabel = CATextLayer()
    private let date = CATextLayer()
    private let isBack: Bool
    private let bounds = CGRect(origin: .zero, size: HolographicCardView.designSize)

    init(isBack: Bool, showsShadow: Bool = true) {
        self.isBack = isBack
        layer.frame = bounds
        layer.isDoubleSided = false
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = showsShadow ? 0.24 : 0
        layer.shadowRadius = 20
        layer.shadowOffset = CGSize(width: 0, height: 14)
        layer.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 28, cornerHeight: 28, transform: nil)
        surface.frame = bounds
        layer.addSublayer(surface)
        let mask = CAShapeLayer()
        mask.path = HolographicCardArtwork.ticketPath
        mask.fillRule = .evenOdd
        surface.mask = mask
        surface.addSublayer(material)
        material.frame = bounds
        iridescenceGroup.frame = bounds
        iridescence.frame = bounds
        iridescenceGroup.addSublayer(iridescence)
        surface.addSublayer(iridescenceGroup)
        foil.frame = bounds
        surface.addSublayer(foil)
        sheen.frame = bounds
        sheen.colors = ([0.0, 0, 136.0 / 255, 17.0 / 255] as [CGFloat]).map { HolographicCardArtwork.hex(0xffffff, alpha: $0) }
            + [HolographicCardArtwork.hex(0x19224d, alpha: 74.0 / 255), NSColor.clear.cgColor]
        sheen.locations = [0.1, 0.24, 0.39, 0.49, 0.66, 0.85]
        surface.addSublayer(sheen)
        grain.frame = bounds
        grain.opacity = 0.13
        grain.compositingFilter = "multiplyBlendMode"
        surface.addSublayer(grain)

        if !isBack {
            setupSeal()
            setupLogo()
            let tear = CAShapeLayer()
            let path = CGMutablePath()
            path.move(to: CGPoint(x: bounds.width * 0.05, y: bounds.height * 0.69))
            path.addLine(to: CGPoint(x: bounds.width * 0.95, y: bounds.height * 0.69))
            tear.path = path
            tear.strokeColor = NSColor.black.withAlphaComponent(0.15).cgColor
            tear.lineWidth = 0.7
            tear.lineDashPattern = [2, 2]
            surface.addSublayer(tear)
            identifier.isHidden = true
            for text in [name, identifier, dateLabel, date] {
                text.contentsScale = 3
                text.foregroundColor = NSColor(srgbRed: 0.19, green: 0.21, blue: 0.25, alpha: 1).cgColor
                text.truncationMode = .end
                surface.addSublayer(text)
            }
        }

        let edge = CAShapeLayer()
        edge.path = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 28, cornerHeight: 28, transform: nil)
        edge.fillColor = nil
        edge.strokeColor = NSColor.white.withAlphaComponent(isBack ? 0.14 : 0.55).cgColor
        edge.lineWidth = 1
        surface.addSublayer(edge)
        shade.frame = bounds
        shade.backgroundColor = NSColor.black.cgColor
        surface.addSublayer(shade)
    }

    func setStyle(_ style: HolographicCardStyle, artwork: HolographicCardArtwork.Material) {
        grain.contents = artwork.grain
        self.style = style
        let hex = HolographicCardArtwork.hex
        let colors = style.palette.colors
        if isBack {
            material.colors = [0x08090b, 0x171a1e, 0x050607].map { hex($0, 1) }
            material.locations = [0, 0.42, 1]
        } else if style.palette == .silver {
            material.colors = [0x898e95, 0xd0d3d7, 0xf1f2f3, 0xb2b7be, 0xdadddf, 0x9299a2, 0xe0e3e6].map { hex($0, 1) }
            material.locations = [0, 0.22, 0.36, 0.5, 0.68, 0.86, 1]
        } else {
            material.colors = [colors[1], colors[0], colors[2]].map { hex($0, 1) }
            material.locations = [0, 0.43, 1]
        }
        let silver = style.palette == .silver
        iridescence.colors = (silver ? [0x929ba9, 0xebedef, 0xbbc2c9, 0xf5f5f4, 0xa8a5ad, 0xcdd4d8]
            : [colors[1], colors[0], colors[2], colors[1]]).map { hex($0, 1) }
        iridescence.locations = silver ? [0, 0.25, 0.45, 0.58, 0.78, 1] : [0, 0.4, 0.76, 1]
        iridescenceGroup.isHidden = isBack
        iridescenceGroup.opacity = HolographicCardStyle.iridescenceOpacity
        iridescenceGroup.compositingFilter = silver ? "softLightBlendMode" : nil
        foil.contents = artwork.foil
        foil.opacity = HolographicCardStyle.textureOpacity * (isBack ? 0.85 : 1)
        foil.compositingFilter = isBack ? "softLightBlendMode" : "overlayBlendMode"
        sheen.compositingFilter = isBack || silver ? "screenBlendMode" : "overlayBlendMode"
        sheen.opacity = isBack ? 0.32 : (silver ? 0.6 : 0.95)
        if !isBack {
            let path = artwork.seal.value
            let enhanced = style.ornament.enhanced
            sealGrooveMask.path = path
            sealGrooveMask.lineWidth = enhanced ? 0.26 : 0.22
            sealGroove.opacity = enhanced ? 0.95 : 0.7
            var offset = CGAffineTransform(translationX: enhanced ? 0.2 : 0.16, y: enhanced ? 0.25 : 0.2)
            sealReflectionMask.path = path.copy(using: &offset)
            sealReflectionMask.lineWidth = enhanced ? 0.21 : 0.16
            sealReflection.colors = (enhanced
                ? [0x596572, 0x6f7e8c, 0xd3edf7, 0xffffff, 0xffffff, 0xb6d1df, 0x5e6c7b, 0x788695]
                : [0x707b87, 0x8795a2, 0xd3edf7, 0xffffff, 0xffffff, 0xb6d1df, 0x768391, 0x929daa]).map { hex($0, 1) }
            let ink = hex(silver ? 0x303640 : 0x233338, 1)
            for text in [name, identifier, dateLabel, date] { text.foregroundColor = ink }
        }
        light(x: 0, y: 0, facing: 1)
    }

    /// CALayer.render does not implement compositingFilter. Export each surface
    /// layer separately and apply the corresponding Core Graphics blend mode.
    func image(scale: CGFloat) -> CGImage? {
        let children = surface.sublayers ?? []
        let root = CALayer()
        root.frame = bounds
        root.isGeometryFlipped = true
        return HolographicCardArtwork.bitmap(scale: scale) { context in
            context.addPath(HolographicCardArtwork.ticketPath)
            context.clip(using: .evenOdd)
            for child in children where !child.isHidden {
                let filter = child.compositingFilter as? String
                child.compositingFilter = nil
                root.addSublayer(child)
                let image = HolographicCardArtwork.bitmap(scale: scale) { root.render(in: $0) }
                child.removeFromSuperlayer()
                guard let image else { continue }
                context.saveGState()
                switch filter {
                case "overlayBlendMode": context.setBlendMode(.overlay)
                case "softLightBlendMode": context.setBlendMode(.softLight)
                case "hardLightBlendMode": context.setBlendMode(.hardLight)
                case "screenBlendMode": context.setBlendMode(.screen)
                case "multiplyBlendMode": context.setBlendMode(.multiply)
                default: context.setBlendMode(.normal)
                }
                context.translateBy(x: 0, y: bounds.height)
                context.scaleBy(x: 1, y: -1)
                context.draw(image, in: bounds)
                context.restoreGState()
            }
        }
    }

    func setCopy(name value: String, identifier id: String, joinedDate: String) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let font = NSFont.brandDisplay("IvyPrestoHeadline-Light", size: 31, renders: value, weight: .regular)
        setText(name, value, font: font, frame: CGRect(x: 23.36, y: 304, width: 247, height: 42))
        setText(identifier, id, font: .monospacedSystemFont(ofSize: 10, weight: .regular),
                frame: CGRect(x: 23.36, y: 348, width: 210, height: 15))
        setText(dateLabel, joinedDate.isEmpty ? "" : NSLocalizedString("profile.card.dateJoined", value: "Date Joined",
            comment: "Profile membership card - Label above the account creation date"),
                font: .systemFont(ofSize: 7), frame: CGRect(x: 23.36, y: 377, width: 145, height: 12))
        dateLabel.opacity = 0.66
        setText(date, joinedDate, font: .systemFont(ofSize: 11), frame: CGRect(x: 23.36, y: 390, width: 155, height: 16))
        CATransaction.commit()
    }

    private func setText(_ layer: CATextLayer, _ value: String, font: NSFont, frame: CGRect) {
        layer.frame = frame
        layer.font = font
        layer.fontSize = font.pointSize
        layer.string = value
    }

    func light(x: CGFloat, y: CGFloat, facing: CGFloat) {
        let lightAngle = 125 + x * 24 - y * 20
        func position(_ gradient: CAGradientLayer, angle: CGFloat, factor: CGFloat = 1, moving: Bool = false) {
            let radians = angle * .pi / 180, dx = sin(radians), dy = -cos(radians)
            let width = bounds.width * factor, height = bounds.height * factor
            let length = abs(dx) * width + abs(dy) * height
            let mx: CGFloat = moving ? 0.5 + x * 0.35 : 0.5
            let my: CGFloat = moving ? 0.5 + y * 0.35 : 0.5
            let center = CGPoint(x: (bounds.width - width) * mx + width / 2,
                                 y: (bounds.height - height) * my + height / 2)
            gradient.startPoint = CGPoint(x: (center.x - dx * length / 2) / bounds.width,
                                          y: (center.y - dy * length / 2) / bounds.height)
            gradient.endPoint = CGPoint(x: (center.x + dx * length / 2) / bounds.width,
                                        y: (center.y + dy * length / 2) / bounds.height)
        }
        position(material, angle: isBack ? lightAngle : HolographicCardStyle.gradientAngle)
        position(iridescence, angle: HolographicCardStyle.gradientAngle + (style.palette == .silver ? 0 : 38) + x * 32 + y * 22,
                 factor: style.palette == .silver ? 2 : 1.25, moving: true)
        position(sheen, angle: lightAngle, factor: 2.2, moving: true)
        position(logoSweep, angle: lightAngle, factor: 2.2, moving: true)
        // Keep the logo dark at rest and fade its reflection in as the card tilts.
        logoSweep.opacity = Float(min(1, hypot(x, y) / 0.35))
        // Translate and rotate the SVG's 0,0 -> 100,100 gradient in local space.
        let rotation = (lightAngle - 135 + 12) * .pi / 180
        func sealPoint(_ p: CGFloat) -> CGPoint {
            CGPoint(x: (50 + (p - 50) * cos(rotation) - (p - 50) * sin(rotation) + x * 34) / 100,
                    y: (50 + (p - 50) * sin(rotation) + (p - 50) * cos(rotation) + y * 30) / 100)
        }
        for gradient in [sealGroove, sealReflection] {
            gradient.startPoint = sealPoint(0)
            gradient.endPoint = sealPoint(100)
        }
        shade.opacity = Float(0.34 * (1 - max(0, facing)))
    }

    private func setupLogo() {
        let ink = CAShapeLayer()
        ink.path = HolographicCardArtwork.logoPath
        ink.fillColor = NSColor.black.cgColor
        surface.addSublayer(ink)
        logoSweep.frame = bounds
        logoSweep.colors = [0.0, 0.015, 0.06, 0.18, 0.44, 0.78, 0.94, 0.94, 0.78, 0.44, 0.18, 0.06, 0.015, 0.0]
            .map { NSColor.white.withAlphaComponent($0).cgColor }
        logoSweep.locations = [0.2, 0.25, 0.29, 0.32, 0.345, 0.365, 0.38, 0.4, 0.415, 0.435, 0.46, 0.49, 0.53, 0.58]
        let mask = CAShapeLayer()
        mask.path = HolographicCardArtwork.logoPath
        logoSweep.mask = mask
        surface.addSublayer(logoSweep)
    }

    private func setupSeal() {
        let container = CALayer()
        container.frame = bounds
        container.compositingFilter = "hardLightBlendMode"
        let local = CALayer()
        local.bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let width = bounds.width * 0.46
        local.position = CGPoint(x: bounds.width * 1.11 - width / 2, y: bounds.height * 1.07 - width / 2)
        var transform = CATransform3DMakeScale(width / 100, width / 100, 1)
        transform = CATransform3DRotate(transform, -12 * .pi / 180, 0, 0, 1)
        local.transform = transform
        container.addSublayer(local)
        surface.addSublayer(container)
        for (gradient, mask) in [(sealGroove, sealGrooveMask), (sealReflection, sealReflectionMask)] {
            gradient.frame = local.bounds
            mask.fillColor = nil
            mask.strokeColor = NSColor.white.cgColor
            mask.contentsScale = 3
            gradient.mask = mask
            local.addSublayer(gradient)
        }
        sealGroove.colors = [0x25303d, 0x151e29, 0x56616d, 0x1c2734, 0x455260].map { HolographicCardArtwork.hex($0) }
        sealGroove.locations = [0, 0.38, 0.56, 0.78, 1]
        sealReflection.locations = [0, 0.3, 0.42, 0.49, 0.54, 0.63, 0.76, 1]
    }
}

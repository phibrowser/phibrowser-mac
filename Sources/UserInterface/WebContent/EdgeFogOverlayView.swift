// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import QuartzCore

/// The agent operating mask: a flat wash of the Space theme color laid over a
/// tab while the agent drives it, plus a lit, slowly rotating ring around the
/// content edge — so a watching user can see at a glance that the page is the
/// agent's, and that it is still live. The view is also the input barrier for
/// that tab: it swallows content clicks and keys, and only the header controls
/// that `hitTestPassthroughHandler` opts into stay reachable.
///
/// Mounted below `AgentSpaceOverlayView`, so the agent cursor and the control
/// pill draw above both.
final class EdgeFogOverlayView: NSView {
    /// Wash strength, from the design. Applied in both appearances — the
    /// design's dark variant restyles the edge lights only and leaves the
    /// wash at this single value.
    private static let tintOpacity: CGFloat = 0.2

    /// Alpha of the 1pt edge line, per appearance. The line reads against the
    /// washed page behind it, so the design runs it hotter in dark mode
    /// (`.edge-lights` border alpha .5 light, .72 dark).
    private static let edgeLineAlphaLight: CGFloat = 0.5
    private static let edgeLineAlphaDark: CGFloat = 0.72

    /// Used until `applyTheme` runs. Matches the tint the mask carried before
    /// it was themed, so a window without a theme context still reads as
    /// masked rather than untouched.
    private static let fallbackTint = NSColor(
        calibratedRed: 0.42, green: 0.56, blue: 0.63, alpha: 1)

    // MARK: Edge-light geometry and cadence, from the design

    /// Width of the lit ring; it sits flush inside the content edge.
    private static let ringWidth: CGFloat = 2

    /// Added to the panel's corner radius to round the ring more than the
    /// panel itself. `cornerCurve = .continuous` draws a border's inner edge as
    /// a squircle of `radius - width`, but a squircle's true offset curve is
    /// not another squircle — so on the panel's own small radius the band
    /// visibly loses width at the corner diagonal. A rounder corner spreads
    /// that error over a longer arc and the ring reads at full width. Tune
    /// here if the corner should hug the panel more tightly. Dropped entirely
    /// while `hugsPanelCorners` — a separated page card's own corners are
    /// visible and the ring must match them.
    private static let ringCornerBoost: CGFloat = 6
    /// One full revolution of the conic sweep.
    private static let flowDuration: CFTimeInterval = 3.0
    /// Full breathe cycle. CA autoreverses, so each leg runs half of it.
    private static let breatheDuration: CFTimeInterval = 3.4

    var hitTestPassthroughHandler: ((NSPoint) -> Bool)?

    /// The appearance the mask was last themed for; picks the edge line
    /// strength. Named apart from NSView's own `appearance`. Seeded from the
    /// app so the pre-theme fallback already reads right in a dark window.
    private var themeAppearance: Appearance = appAppearance

    /// True while the page panel renders as its own separated card (AI Chat
    /// sidebar expanded or an extension side panel docked). The card's own,
    /// tighter corner clip and hairline border are visible then, so the ring
    /// gives up `ringCornerBoost` and follows the panel's corners exactly —
    /// a boosted ring visibly pulls away from the card's corners.
    var hugsPanelCorners = false {
        didSet {
            guard hugsPanelCorners != oldValue else { return }
            needsLayout = true
        }
    }

    private let tintLayer = CALayer()
    /// The 1pt edge line, and the source of the breathing glow.
    private let edgeGlowLayer = CALayer()
    /// Clipped to the ring band; the conic sweep rotates inside it.
    private let edgeRingLayer = CALayer()
    private let edgeRingMask = CALayer()
    private let edgeConicLayer = CAGradientLayer()

    private var cursorTrackingArea: NSTrackingArea?
    private var reduceMotionObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    override func makeBackingLayer() -> CALayer {
        CALayer()
    }

    override var acceptsFirstResponder: Bool { true }

    private func commonInit() {
        wantsLayer = true
        layerContentsRedrawPolicy = .never

        guard let rootLayer = layer else { return }
        rootLayer.masksToBounds = true
        rootLayer.backgroundColor = NSColor.clear.cgColor

        tintLayer.backgroundColor = Self.fallbackTint
            .withAlphaComponent(Self.tintOpacity).cgColor
        rootLayer.addSublayer(tintLayer)

        setupEdgeLights(in: rootLayer)
        applyEdgeColors(Self.fallbackTint)
        installReduceMotionObserver()
    }

    deinit {
        if let reduceMotionObserver {
            NotificationCenter.default.removeObserver(reduceMotionObserver)
        }
    }

    // MARK: - Edge lights

    /// The ring is built from layer borders rather than a stroked `CGPath`.
    /// The content panel clips with `cornerCurve = .continuous`, and a
    /// `CGPath` rounded rect is a plain circular corner — the two curves
    /// diverge, so the panel's squircle clip shaved the path's corners off and
    /// the sweep only showed along the straight edges. Layer borders take the
    /// same `cornerCurve`, so the ring now follows the panel exactly.
    private func setupEdgeLights(in rootLayer: CALayer) {
        edgeGlowLayer.backgroundColor = NSColor.clear.cgColor
        edgeGlowLayer.borderWidth = 1
        edgeGlowLayer.cornerCurve = .continuous
        edgeGlowLayer.shadowOffset = .zero

        // The conic layer is square and centred so a full revolution never
        // pulls an uncovered corner into the ring; the mask keeps only the
        // band at the edge, the same result CSS gets from `mask-composite`.
        edgeConicLayer.type = .conic
        edgeConicLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        edgeConicLayer.endPoint = CGPoint(x: 0.5, y: 0)

        // A mask keys off its own rendered alpha, so a bordered layer masks to
        // exactly the border band.
        edgeRingMask.backgroundColor = NSColor.clear.cgColor
        edgeRingMask.borderColor = NSColor.black.cgColor
        edgeRingMask.borderWidth = Self.ringWidth
        edgeRingMask.cornerCurve = .continuous
        edgeRingLayer.mask = edgeRingMask
        edgeRingLayer.addSublayer(edgeConicLayer)

        rootLayer.addSublayer(edgeGlowLayer)
        rootLayer.addSublayer(edgeRingLayer)
    }

    /// Re-fits the ring and re-centres the conic sweep. Called from `layout`
    /// because all of it is bounds-derived.
    private func layoutEdgeLights() {
        let panelRadius = LiquidGlassCompatible.webContentInnerComponentsCornerRadius
        let ringRadius = panelRadius + (hugsPanelCorners ? 0 : Self.ringCornerBoost)

        // The wash matches the panel's own clip so it stops on the same curve;
        // the ring is rounder, so its corners sit just inside that clip and
        // keep their full width.
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = panelRadius

        edgeGlowLayer.frame = bounds
        edgeGlowLayer.cornerRadius = ringRadius
        edgeRingLayer.frame = bounds
        edgeRingMask.frame = bounds
        edgeRingMask.cornerRadius = ringRadius

        let side = hypot(bounds.width, bounds.height)
        edgeConicLayer.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        edgeConicLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    /// Recolours the ring from one theme color. The conic stops are the
    /// design's, including its two `color-mix` steps; `secondary` and
    /// `tertiary` are the design's hue rotations of the same source color.
    private func applyEdgeColors(_ primary: NSColor) {
        let base = primary.usingColorSpace(.sRGB) ?? primary
        let hsl = Self.toHSL(base)
        let saturation = max(42, min(86, hsl.s))
        let secondary = Self.fromHSL(
            h: (hsl.h + 34).truncatingRemainder(dividingBy: 360),
            s: max(46, saturation - 10), l: 58)
        let tertiary = Self.fromHSL(
            h: (hsl.h + 166).truncatingRemainder(dividingBy: 360),
            s: max(38, saturation - 20), l: 48)
        let white = NSColor.white
        let deep = NSColor(calibratedRed: 0x11 / 255, green: 0x10 / 255,
                           blue: 0x15 / 255, alpha: 1)

        edgeConicLayer.colors = [
            white.cgColor,
            Self.mix(base, white, ratio: 0.42).cgColor,
            base.cgColor,
            tertiary.cgColor,
            white.cgColor,
            Self.mix(base, deep, ratio: 0.72).cgColor,
            secondary.cgColor,
            white.cgColor,
            white.cgColor,
        ]
        // The design's stop angles, as fractions of a turn.
        edgeConicLayer.locations = [0, 42, 88, 142, 190, 238, 286, 330, 360]
            .map { NSNumber(value: $0 / 360.0) }

        edgeGlowLayer.borderColor = base.withAlphaComponent(
            themeAppearance.isDark ? Self.edgeLineAlphaDark : Self.edgeLineAlphaLight).cgColor
        edgeGlowLayer.shadowColor = base.cgColor
    }

    private func installReduceMotionObserver() {
        reduceMotionObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshEdgeAnimations()
        }
    }

    /// The design turns the edge animation off under Reduce Motion; the lit
    /// ring itself stays, so the mask still reads as active when still.
    private func refreshEdgeAnimations() {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard !reduceMotion else {
            edgeConicLayer.removeAllAnimations()
            edgeRingLayer.removeAllAnimations()
            edgeGlowLayer.removeAllAnimations()
            edgeRingLayer.opacity = 1
            edgeGlowLayer.shadowOpacity = 0.45
            edgeGlowLayer.shadowRadius = 12
            return
        }
        guard edgeConicLayer.animation(forKey: "flow") == nil else { return }

        // Negative z: an unflipped view is y-up, so this sweeps clockwise, the
        // direction a CSS conic gradient turns as its angle grows.
        let flow = CABasicAnimation(keyPath: "transform.rotation.z")
        flow.fromValue = 0
        flow.toValue = -2 * Double.pi
        flow.duration = Self.flowDuration
        flow.repeatCount = .infinity
        flow.isRemovedOnCompletion = false
        edgeConicLayer.add(flow, forKey: "flow")

        edgeRingLayer.add(
            Self.breathe(keyPath: "opacity", from: 0.82, to: 1.0), forKey: "breathe")
        edgeGlowLayer.add(
            Self.breathe(keyPath: "shadowOpacity", from: 0.30, to: 0.66), forKey: "breathe")
        edgeGlowLayer.add(
            Self.breathe(keyPath: "shadowRadius", from: 8, to: 18), forKey: "breatheRadius")
    }

    /// One leg of the design's breathe: CA autoreverses, so each leg is half
    /// the stated cycle.
    private static func breathe(keyPath: String,
                                from: CGFloat, to: CGFloat) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = breatheDuration / 2
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return animation
    }

    // MARK: - Color math

    /// HSL, not AppKit's HSB: the design's stops are authored with lightness
    /// clamps that have no HSB equivalent.
    private static func toHSL(_ color: NSColor) -> (h: CGFloat, s: CGFloat, l: CGFloat) {
        let r = color.redComponent, g = color.greenComponent, b = color.blueComponent
        let maxV = max(r, g, b), minV = min(r, g, b)
        let delta = maxV - minV
        let l = (maxV + minV) / 2
        var h: CGFloat = 0
        if delta != 0 {
            if maxV == r {
                h = 60 * (((g - b) / delta).truncatingRemainder(dividingBy: 6))
            } else if maxV == g {
                h = 60 * ((b - r) / delta + 2)
            } else {
                h = 60 * ((r - g) / delta + 4)
            }
        }
        let s = delta == 0 ? 0 : delta / (1 - abs(2 * l - 1))
        return ((h + 360).truncatingRemainder(dividingBy: 360), s * 100, l * 100)
    }

    private static func fromHSL(h: CGFloat, s: CGFloat, l: CGFloat) -> NSColor {
        let sat = s / 100, light = l / 100
        let c = (1 - abs(2 * light - 1)) * sat
        let x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = light - c / 2
        let rgb: (CGFloat, CGFloat, CGFloat)
        switch h {
        case ..<60:  rgb = (c, x, 0)
        case ..<120: rgb = (x, c, 0)
        case ..<180: rgb = (0, c, x)
        case ..<240: rgb = (0, x, c)
        case ..<300: rgb = (x, 0, c)
        default:     rgb = (c, 0, x)
        }
        return NSColor(srgbRed: rgb.0 + m, green: rgb.1 + m, blue: rgb.2 + m, alpha: 1)
    }

    /// `color-mix(in srgb, a <ratio>, b)`.
    private static func mix(_ a: NSColor, _ b: NSColor, ratio: CGFloat) -> NSColor {
        let lhs = a.usingColorSpace(.sRGB) ?? a
        let rhs = b.usingColorSpace(.sRGB) ?? b
        return NSColor(
            srgbRed: lhs.redComponent * ratio + rhs.redComponent * (1 - ratio),
            green: lhs.greenComponent * ratio + rhs.greenComponent * (1 - ratio),
            blue: lhs.blueComponent * ratio + rhs.blueComponent * (1 - ratio),
            alpha: 1)
    }

    /// Tints the mask from the Space's theme, using the same theme slot as
    /// `AgentSpaceOverlayView` so the wash and the agent cursor always carry
    /// the same color. Called by the hosting controller on mount and on every
    /// theme change.
    func applyTheme(_ theme: Theme, appearance: Appearance) {
        guard let themeColor = theme.color(for: .themeColor, appearance: appearance)
            .usingColorSpace(.sRGB) else { return }
        themeAppearance = appearance
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tintLayer.backgroundColor = themeColor
            .withAlphaComponent(Self.tintOpacity).cgColor
        applyEdgeColors(themeColor)
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        guard let rootLayer = layer else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rootLayer.frame = bounds
        tintLayer.frame = bounds
        layoutEdgeLights()
        CATransaction.commit()
    }

    // MARK: - Cursor

    /// The mask swallows content input, so the pointer must stop advertising
    /// interactions the page can no longer accept — no I-beam over text, no
    /// pointing hand over links. Chromium sets those from mouse-moved events
    /// that the mask intercepts, so it is this view's job to state the blocked
    /// state instead.
    ///
    /// `.mouseMoved` is tracked alongside `.cursorUpdate` because a single
    /// tracking area only reports cursor updates on enter and exit, and the
    /// passthrough controls sit *inside* this area — without per-move updates
    /// the blocked cursor would stick while crossing onto them.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTrackingArea { removeTrackingArea(cursorTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .cursorUpdate, .mouseMoved],
            owner: self,
            userInfo: nil)
        addTrackingArea(area)
        cursorTrackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        applyCursor(for: event)
    }

    override func mouseMoved(with event: NSEvent) {
        applyCursor(for: event)
    }

    private func applyCursor(for event: NSEvent) {
        // Same coordinate space the hit-test passthrough is evaluated in.
        let point = convert(event.locationInWindow, from: nil)
        if hitTestPassthroughHandler?(point) == true {
            // These controls stay live under the mask; keep them clickable.
            NSCursor.arrow.set()
        } else {
            NSCursor.operationNotAllowed.set()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            // Unmounting does not move the pointer, so the blocked cursor
            // would otherwise persist over the page the user just got back.
            NSCursor.arrow.set()
            // Nothing to drive off-screen; re-added on the next mount.
            edgeConicLayer.removeAllAnimations()
            edgeRingLayer.removeAllAnimations()
            edgeGlowLayer.removeAllAnimations()
        } else {
            refreshEdgeAnimations()
        }
    }

    // MARK: - Input interception

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        if hitTestPassthroughHandler?(point) == true {
            return nil
        }
        return self
    }

    override func keyDown(with event: NSEvent) {}

    override func keyUp(with event: NSEvent) {}

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) {
            let char = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if ["q", "w", "m", "h", ",", "`", "n", "t", "s"].contains(char) {
                return false
            }
        }
        return true
    }
}

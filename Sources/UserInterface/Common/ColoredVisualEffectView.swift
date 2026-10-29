// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Combine

class ColoredVisualEffectView: NSVisualEffectView {
    // Dedicated backing view that carries the resolved color fill.
    private let colorView = NSView()
    private let paletteLayer = CAGradientLayer()
    private var themeSubscription: AnyCancellable?
    private weak var subscribedProvider: ThemeStateProvider?
    private var renderedAppearance: Appearance?
    private var renderedPaletteColors: [NSColor]?

    /// Opt in only for navigation backdrops; ordinary themed surfaces keep
    /// resolving their existing semantic solid color.
    var usesThemePalette = false {
        didSet { updateColor() }
    }

    /// Align split navigation backdrops to one continuous palette.
    weak var paletteCoordinateView: NSView? {
        didSet { needsLayout = true }
    }

    /// Static background color synced onto the backing view.
    /// The alpha channel still participates in the visual-effect blend.
    var backgroundColor: NSColor? {
        didSet {
            updateColor()
        }
    }
    
    /// Theme-driven background color. Takes precedence over `backgroundColor`.
    var themedBackgroundColor: ThemedColor? {
        didSet {
            if themedBackgroundColor != nil {
                subscribeToThemeChanges()
            } else {
                themeSubscription?.cancel()
                themeSubscription = nil
            }
            updateColor()
        }
    }
    
    /// Optional alpha override applied after color resolution.
    var colorAlphaComponent: CGFloat? {
        didSet {
            updateColor()
        }
    }

    // MARK: - Overrides

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }
    
    deinit {
        themeSubscription?.cancel()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Keep the color view behind all visual-effect content.
        if colorView.superview != self {
            addSubview(colorView, positioned: .below, relativeTo: nil)
        }
        if themedBackgroundColor != nil {
            themeSubscription?.cancel()
            themeSubscription = nil
            subscribedProvider = nil
            subscribeToThemeChanges()
        }
        updateColor()
    }

    private func commonInit() {
        colorView.wantsLayer = true
        colorView.layer?.masksToBounds = true
        colorView.layer?.backgroundColor = makeBackgroundColor().cgColor
        paletteLayer.startPoint = CGPoint(x: 0.5, y: 1)
        paletteLayer.endPoint = CGPoint(x: 0.5, y: 0)
        paletteLayer.contentsFormat = .RGBA16Float
        paletteLayer.isHidden = true
        colorView.layer?.addSublayer(paletteLayer)
        
        colorView.autoresizingMask = [.width, .height]
        colorView.frame = self.bounds
        
        addSubview(colorView, positioned: .below, relativeTo: nil)
    }
    
    /// Re-resolves the theme provider this view follows. The provider is
    /// found through the responder chain, so a view whose provider changes
    /// without the view moving — the shell's sidebar backdrop when the
    /// presented session changes — asks for it again here.
    func rebindThemeProvider() {
        guard themedBackgroundColor != nil else { return }
        themeSubscription?.cancel()
        themeSubscription = nil
        subscribedProvider = nil
        subscribeToThemeChanges()
        updateColor()
    }

    private func subscribeToThemeChanges() {
        let provider = themeStateProvider
        if let subscribedProvider, subscribedProvider === provider, themeSubscription != nil {
            return
        }
        
        subscribedProvider = provider
        themeSubscription = provider.themeAppearancePublisher
            .map { _ in () }
        .sink { [weak self] _ in
            if Thread.isMainThread {
                self?.updateColor()
            } else {
                DispatchQueue.main.async { [weak self] in self?.updateColor() }
            }
        }
    }

    private func updateColor() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let provider = themeStateProvider
        let appearance = provider.currentAppearance
        let changesAppearance = renderedAppearance.map { $0 != appearance } ?? false
        renderedAppearance = appearance
        let previousFill = colorView.layer?.presentation()?.backgroundColor ?? colorView.layer?.backgroundColor
        let previousColors = paletteLayer.presentation()?.colors ?? paletteLayer.colors
        let wasGradient = !paletteLayer.isHidden
        let palette = usesThemePalette && themedBackgroundColor != nil
            ? provider.currentTheme.navigationPalette : nil
        if let palette, palette.colorCount > 1 {
            colorView.layer?.backgroundColor = nil
            paletteLayer.startPoint = CGPoint(x: 0.5, y: 1)
            paletteLayer.endPoint = CGPoint(x: 0.5, y: 0)
            paletteLayer.locations = nil
            let colors = palette.colors(for: appearance).map {
                $0.withAlphaComponent(colorAlphaComponent ?? $0.alphaComponent)
            }
            if colors != renderedPaletteColors {
                paletteLayer.colors = Self.gradientColors(colors)
                renderedPaletteColors = colors
            }
            paletteLayer.isHidden = false
        } else {
            paletteLayer.isHidden = true
            paletteLayer.colors = nil
            renderedPaletteColors = nil
            paletteLayer.locations = nil
        }
        if paletteLayer.isHidden {
            colorView.layer?.backgroundColor = makeBackgroundColor().cgColor
        }
        guard changesAppearance, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let ramp: CABasicAnimation
        let targetLayer: CALayer
        if !paletteLayer.isHidden, wasGradient,
           let previousColors, previousColors.count == paletteLayer.colors?.count {
            ramp = CABasicAnimation(keyPath: "colors")
            ramp.fromValue = previousColors
            ramp.toValue = paletteLayer.colors
            targetLayer = paletteLayer
        } else if paletteLayer.isHidden, !wasGradient, let previousFill, let layer = colorView.layer {
            ramp = CABasicAnimation(keyPath: "backgroundColor")
            ramp.fromValue = previousFill
            ramp.toValue = layer.backgroundColor
            targetLayer = layer
        } else {
            return
        }
        ramp.duration = 0.3
        ramp.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
        targetLayer.add(ramp, forKey: "phi.appearanceRamp")
    }

    /// Sample one continuous blend in Oklab to avoid RGB brightness dips and
    /// the slope changes of separately joined color segments.
    static func gradientColors(_ colors: [NSColor]) -> [CGColor] {
        let components = colors.map { oklabComponents($0) }
        // Saturated endpoints need finer samples through the sRGB transfer curve.
        let intervals = 512
        return (0...intervals).map { index in
            if index == 0 { return colors[0].cgColor }
            if index == intervals { return colors[colors.count - 1].cgColor }
            let position = Double(index) / Double(intervals)
            let value: SIMD4<Double>
            if colors.count == 3 {
                // Squared progress keeps the primary dominant in the upper
                // half, with both supporting colors overlapping below it.
                let t = position * position
                let remaining = 1 - t
                value = components[0] * (remaining * remaining)
                    + components[1] * (2 * remaining * t)
                    + components[2] * (t * t)
            } else {
                value = components[0] * (1 - position) + components[1] * position
            }
            return colorFromOklab(value)
        }
    }

    private static func oklabComponents(_ color: NSColor) -> SIMD4<Double> {
        let color = color.usingColorSpace(.sRGB) ?? color
        func linear(_ value: CGFloat) -> Double {
            let value = Double(value)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let r = linear(color.redComponent)
        let g = linear(color.greenComponent)
        let b = linear(color.blueComponent)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return SIMD4(
            0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
            Double(color.alphaComponent)
        )
    }

    private static let gradientColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    private static func colorFromOklab(_ value: SIMD4<Double>) -> CGColor {
        let lRoot = value.x + 0.3963377774 * value.y + 0.2158037573 * value.z
        let mRoot = value.x - 0.1055613458 * value.y - 0.0638541728 * value.z
        let sRoot = value.x - 0.0894841775 * value.y - 1.2914855480 * value.z
        let l = lRoot * lRoot * lRoot
        let m = mRoot * mRoot * mRoot
        let s = sRoot * sRoot * sRoot
        func encoded(_ value: Double) -> CGFloat {
            let value = min(max(value, 0), 1)
            return CGFloat(value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055)
        }
        // Build sRGB samples directly. NSColor.cgColor repeats ColorSync
        // profile resolution for every sample on every pointer update.
        return CGColor(colorSpace: gradientColorSpace, components: [
            encoded(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
            encoded(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
            encoded(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s),
            CGFloat(value.w)
        ])!
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        paletteLayer.frame = paletteCoordinateView.map {
            colorView.convert($0.bounds, from: $0)
        } ?? colorView.bounds
        CATransaction.commit()
    }

    /// The fill as it shows right now: mid-animation, the presentation
    /// value; otherwise the model.
    var presentedFillColor: CGColor? {
        if !paletteLayer.isHidden {
            let colors = (paletteLayer.presentation()?.colors ?? paletteLayer.colors) as? [CGColor]
            return colors?.first
        }
        guard let layer = colorView.layer else { return nil }
        return layer.presentation()?.backgroundColor ?? layer.backgroundColor
    }

    /// Ramps the fill from `from` to the current color as a Core Animation
    /// animation on the caller's clock (`startTime` in `CACurrentMediaTime`
    /// terms), so it plays in step with other animations on that clock and
    /// through main-thread stalls. The model already holds the destination.
    func animateFill(from: CGColor, duration: TimeInterval, startTime: CFTimeInterval) {
        guard let layer = colorView.layer, duration > 0 else { return }
        let ramp = CABasicAnimation(keyPath: "backgroundColor")
        ramp.fromValue = from
        ramp.toValue = layer.backgroundColor
        ramp.duration = duration
        ramp.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        ramp.beginTime = layer.convertTime(startTime, from: nil)
        layer.add(ramp, forKey: "phi.fillRamp")
    }
    
    private func makeBackgroundColor() -> NSColor {
        // Prefer the theme-driven color when present.
        if let themedColor = themedBackgroundColor {
            let resolvedColor = themedColor.resolve(in: self)
            if let alpha = colorAlphaComponent {
                return resolvedColor.withAlphaComponent(alpha)
            }
            return resolvedColor
        }
        
        // Fall back to the static background color.
        guard let backgroundColor else {
            return .clear
        }
        if let alpha = colorAlphaComponent {
            return backgroundColor.withAlphaComponent(alpha)
        }
        return backgroundColor
    }
}

/// A plain view whose themed vibrancy backdrop is its bottom-most subview
/// rather than the view itself, so turning the backdrop off hides only that
/// subview. An `NSVisualEffectView` root could hide its material only behind
/// a `maskImage`, which AppKit re-renders at the view's full size on every
/// resize; each masked page-area view then stalled the sidebar's collapse
/// animation on every frame.
class BackdropContainerView: NSView {
    /// Created the first time the view paints a backdrop, so a view that
    /// never paints one (a hosted session's page tree) never has one.
    private(set) var backdrop: ColoredVisualEffectView?
    private let configureBackdrop: (ColoredVisualEffectView) -> Void

    var paintsBackdrop: Bool {
        didSet {
            guard paintsBackdrop != oldValue else { return }
            applyBackdropPainting()
        }
    }

    init(paintsBackdrop: Bool = true,
         configureBackdrop: @escaping (ColoredVisualEffectView) -> Void = BackdropContainerView.configureNavigationBackdrop) {
        self.paintsBackdrop = paintsBackdrop
        self.configureBackdrop = configureBackdrop
        super.init(frame: .zero)
        wantsLayer = true
        applyBackdropPainting()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// An unhandled scroll passes up the responder chain, to the owning view
    /// controller (the sidebar's swipe-to-switch-Space handler), as it did
    /// while the root was an `NSVisualEffectView`. A plain `NSView` would
    /// instead hand it to the view behind it under the pointer.
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }

    static func configureNavigationBackdrop(_ backdrop: ColoredVisualEffectView) {
        backdrop.themedBackgroundColor = .windowOverlayBackground
        backdrop.usesThemePalette = true
        backdrop.material = .fullScreenUI
    }

    private func applyBackdropPainting() {
        if paintsBackdrop, backdrop == nil {
            let backdrop = BackdropEffectView(frame: bounds)
            backdrop.autoresizingMask = [.width, .height]
            configureBackdrop(backdrop)
            addSubview(backdrop, positioned: .below, relativeTo: nil)
            self.backdrop = backdrop
        }
        backdrop?.isHidden = !paintsBackdrop
    }
}

/// Leaves hits to its container, which received them while it was itself
/// the visual-effect view.
private final class BackdropEffectView: ColoredVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

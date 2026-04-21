import Cocoa
import QuartzCore

final class EdgeFogOverlayView: NSView {
    struct Configuration {
        var themeColor = NSColor(calibratedRed: 0.42, green: 0.56, blue: 0.63, alpha: 1)
        var overlayOpacity: Float = 0.28
        var particleIntensity: Float = 0.9
    }

    var configuration = Configuration() {
        didSet {
            rebuildNoiseTextures()
            rebuildParticleSystem()
            updateAppearance()
        }
    }

    var isAnimationPaused = false {
        didSet {
            updateAnimationState()
        }
    }

    private let animationContainer = CALayer()
    private let fogContainer = CALayer()
    private let falloffMaskLayer = CALayer()
    private let baseTintLayer = CALayer()
    private let noiseLayerA = CALayer()
    private let noiseLayerB = CALayer()
    private let particleLayer = CAEmitterLayer()

    private var lastRenderedSize: CGSize = .zero
    private var isReduceMotionEnabled = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private var reduceMotionObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    deinit {
        if let reduceMotionObserver {
            NotificationCenter.default.removeObserver(reduceMotionObserver)
        }
    }

    override func makeBackingLayer() -> CALayer {
        CALayer()
    }

    override var acceptsFirstResponder: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
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

    override func layout() {
        super.layout()
        guard let rootLayer = layer else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        rootLayer.frame = bounds
        animationContainer.frame = bounds
        fogContainer.frame = bounds
        falloffMaskLayer.frame = bounds
        baseTintLayer.frame = bounds

        let noiseInsetX = bounds.width * 0.32
        let noiseInsetY = bounds.height * 0.28
        let expandedBounds = bounds.insetBy(dx: -noiseInsetX, dy: -noiseInsetY)
        noiseLayerA.frame = expandedBounds
        noiseLayerB.frame = expandedBounds.offsetBy(dx: -expandedBounds.width * 0.08, dy: expandedBounds.height * 0.06)

        particleLayer.frame = bounds
        particleLayer.emitterPosition = CGPoint(x: bounds.midX, y: bounds.midY)
        particleLayer.emitterSize = CGSize(width: bounds.width, height: bounds.height)

        CATransaction.commit()

        rebuildStaticAssetsIfNeeded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAnimationState()
    }

    private func commonInit() {
        wantsLayer = true
        layerContentsRedrawPolicy = .never

        guard let rootLayer = layer else { return }
        rootLayer.masksToBounds = true
        rootLayer.cornerRadius = 28
        rootLayer.backgroundColor = NSColor.clear.cgColor

        fogContainer.mask = falloffMaskLayer
        fogContainer.masksToBounds = true

        baseTintLayer.backgroundColor = configuration.themeColor.withAlphaComponent(CGFloat(configuration.overlayOpacity)).cgColor
        noiseLayerA.opacity = 0.62
        noiseLayerB.opacity = 0.42

        animationContainer.addSublayer(fogContainer)
        fogContainer.addSublayer(baseTintLayer)
        fogContainer.addSublayer(noiseLayerA)
        fogContainer.addSublayer(noiseLayerB)
        rootLayer.addSublayer(animationContainer)
        rootLayer.addSublayer(particleLayer)

        configureParticleLayer()
        rebuildNoiseTextures()
        updateAppearance()
        installAccessibilityObserver()
    }

    private func installAccessibilityObserver() {
        reduceMotionObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.isReduceMotionEnabled = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            self.updateAnimationState()
        }
    }

    private func configureParticleLayer() {
        particleLayer.emitterShape = CAEmitterLayerEmitterShape.rectangle
        particleLayer.emitterMode = CAEmitterLayerEmitterMode.volume
        particleLayer.renderMode = CAEmitterLayerRenderMode.oldestLast
        particleLayer.preservesDepth = false
        particleLayer.birthRate = 1
        rebuildParticleSystem()
    }

    private func rebuildParticleSystem() {
        let particleImage = makeParticleImage(diameter: 30)

        let cell = CAEmitterCell()
        cell.contents = particleImage
        cell.birthRate = 5.0 * configuration.particleIntensity
        cell.lifetime = 6.0
        cell.lifetimeRange = 1.8
        cell.velocity = 20
        cell.velocityRange = 2.5
        cell.yAcceleration = 0
        cell.xAcceleration = 0
        cell.emissionLongitude = .pi / 2
        cell.emissionRange = 0
        cell.alphaRange = 0.12
        cell.alphaSpeed = -0.14
        cell.scale = 0.18
        cell.scaleRange = 0.12
        cell.scaleSpeed = 0.024
        cell.spin = 0
        cell.spinRange = 0

        particleLayer.emitterCells = [cell]
    }

    private func updateAppearance() {
        baseTintLayer.backgroundColor = configuration.themeColor.withAlphaComponent(CGFloat(configuration.overlayOpacity)).cgColor
    }

    private func rebuildStaticAssetsIfNeeded() {
        let currentSize = bounds.size.integralSize
        guard currentSize.width > 0, currentSize.height > 0 else { return }
        guard currentSize != lastRenderedSize else { return }

        lastRenderedSize = currentSize
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2

        falloffMaskLayer.contents = makeFalloffMaskImage(size: currentSize, scale: scale)
        rebuildNoiseTextures()
        installAnimations()
    }

    private func rebuildNoiseTextures() {
        guard !bounds.isEmpty || lastRenderedSize != .zero else { return }
        let noiseSize = CGSize(width: 260, height: 260)
        noiseLayerA.contents = makeNoiseTexture(size: noiseSize, tint: configuration.themeColor.withAlphaComponent(0.23), seed: 1)
        noiseLayerB.contents = makeNoiseTexture(size: noiseSize, tint: configuration.themeColor.withAlphaComponent(0.17), seed: 2)
        noiseLayerA.contentsGravity = .resizeAspectFill
        noiseLayerB.contentsGravity = .resizeAspectFill
    }

    private func installAnimations() {
        animationContainer.removeAllAnimations()
        noiseLayerA.removeAllAnimations()
        noiseLayerB.removeAllAnimations()

        guard !isReduceMotionEnabled else {
            particleLayer.birthRate = 0
            updateAnimationState()
            return
        }

        particleLayer.birthRate = 1

        let breath = CABasicAnimation(keyPath: "opacity")
        breath.fromValue = 0.32
        breath.toValue = 0.95
        breath.duration = 1.8
        breath.autoreverses = true
        breath.repeatCount = .infinity
        breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animationContainer.add(breath, forKey: "breath")

        noiseLayerA.add(makeNoiseAnimation(
            positionOffset: CGPoint(x: 44, y: -32),
            scale: 1.14,
            opacityFrom: 0.36,
            opacityTo: 0.64,
            duration: 13.5
        ), forKey: "driftA")

        noiseLayerB.add(makeNoiseAnimation(
            positionOffset: CGPoint(x: -36, y: 26),
            scale: 1.18,
            opacityFrom: 0.18,
            opacityTo: 0.44,
            duration: 17.2
        ), forKey: "driftB")

        updateAnimationState()
    }

    private func makeNoiseAnimation(
        positionOffset: CGPoint,
        scale: CGFloat,
        opacityFrom: Float,
        opacityTo: Float,
        duration: CFTimeInterval
    ) -> CAAnimationGroup {
        let position = CABasicAnimation(keyPath: "position")
        position.byValue = NSValue(point: NSPoint(x: positionOffset.x, y: positionOffset.y))

        let transform = CABasicAnimation(keyPath: "transform.scale")
        transform.fromValue = 1.0
        transform.toValue = scale

        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = opacityFrom
        opacity.toValue = opacityTo
        opacity.autoreverses = true

        let group = CAAnimationGroup()
        group.animations = [position, transform, opacity]
        group.duration = duration
        group.autoreverses = true
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        group.isRemovedOnCompletion = false
        return group
    }

    private func updateAnimationState() {
        let shouldPause = isAnimationPaused || isReduceMotionEnabled || window == nil
        setPaused(shouldPause, for: layer)
    }

    private func setPaused(_ paused: Bool, for layer: CALayer?) {
        guard let layer else { return }

        if paused {
            guard layer.speed != 0 else { return }
            let pausedTime = layer.convertTime(CACurrentMediaTime(), from: nil)
            layer.speed = 0
            layer.timeOffset = pausedTime
        } else {
            let pausedTime = layer.timeOffset
            layer.speed = 1
            layer.timeOffset = 0
            layer.beginTime = 0
            let timeSincePause = layer.convertTime(CACurrentMediaTime(), from: nil) - pausedTime
            layer.beginTime = timeSincePause
        }
    }

    private func makeFalloffMaskImage(size: CGSize, scale: CGFloat) -> CGImage? {
        let width = max(Int(size.width * scale), 1)
        let height = max(Int(size.height * scale), 1)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.scaleBy(x: scale, y: scale)

        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = hypot(size.width / 2, size.height / 2)
        let colors = [
            NSColor.white.withAlphaComponent(0.0).cgColor,
            NSColor.white.withAlphaComponent(0.0).cgColor,
            NSColor.white.withAlphaComponent(0.20).cgColor,
            NSColor.white.withAlphaComponent(0.52).cgColor,
            NSColor.white.withAlphaComponent(0.86).cgColor,
            NSColor.white.withAlphaComponent(1.0).cgColor,
        ] as CFArray
        let locations: [CGFloat] = [0.0, 0.20, 0.40, 0.60, 0.80, 1.0]

        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: locations) else {
            return nil
        }

        context.drawRadialGradient(
            gradient,
            startCenter: center,
            startRadius: 0,
            endCenter: center,
            endRadius: radius,
            options: [.drawsAfterEndLocation]
        )

        return context.makeImage()
    }

    private func makeNoiseTexture(size: CGSize, tint: NSColor, seed: UInt64) -> CGImage? {
        let width = Int(size.width)
        let height = Int(size.height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.clear(CGRect(origin: .zero, size: size))

        var generator = SeededGenerator(seed: seed)
        let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext

        for _ in 0..<55 {
            let diameter = CGFloat.random(in: size.width * 0.18...size.width * 0.62, using: &generator)
            let origin = CGPoint(
                x: CGFloat.random(in: -diameter * 0.2...(size.width - diameter * 0.8), using: &generator),
                y: CGFloat.random(in: -diameter * 0.2...(size.height - diameter * 0.8), using: &generator)
            )
            let rect = CGRect(origin: origin, size: CGSize(width: diameter, height: diameter))

            let shadow = NSShadow()
            shadow.shadowBlurRadius = diameter * 0.22
            shadow.shadowColor = tint.withAlphaComponent(0.66)
            shadow.shadowOffset = .zero
            shadow.set()

            let alpha = CGFloat.random(in: 0.08...0.22, using: &generator)
            tint.withAlphaComponent(alpha).setFill()
            NSBezierPath(ovalIn: rect).fill()
        }

        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    private func makeParticleImage(diameter: CGFloat) -> CGImage? {
        let size = CGSize(width: diameter, height: diameter)
        let width = Int(size.width)
        let height = Int(size.height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext

        let shadow = NSShadow()
        shadow.shadowBlurRadius = diameter * 0.35
        shadow.shadowColor = NSColor.white.withAlphaComponent(0.9)
        shadow.shadowOffset = .zero
        shadow.set()

        NSColor.white.withAlphaComponent(0.95).setFill()
        NSBezierPath(ovalIn: CGRect(x: diameter * 0.28, y: diameter * 0.28, width: diameter * 0.44, height: diameter * 0.44)).fill()

        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x123456789ABCDEF : seed
    }

    mutating func next() -> UInt64 {
        state = 2862933555777941757 &* state &+ 3037000493
        return state
    }
}

private extension CGSize {
    var integralSize: CGSize {
        CGSize(width: ceil(width), height: ceil(height))
    }
}

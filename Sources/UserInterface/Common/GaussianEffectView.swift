// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

//  Provides Gaussian blur effect extension for NSView
//  Inspired by FMBlurable for iOS

import AppKit
import QuartzCore

// MARK: - Blurable Protocol

protocol Blurable {
    var layer: CALayer? { get }
    var subviews: [NSView] { get }
    var frame: CGRect { get }
    var superview: NSView? { get }
    
    func addSubview(_ view: NSView)
    func removeFromSuperview()
    
    func blur(blurRadius: CGFloat)
    func unBlur()
    
    var isBlurred: Bool { get }
}

// MARK: - BlurableKey

private struct BlurableKey {
    static var blurable = "blurable"
    static var blurLayer = "blurLayer"
}

// MARK: - BlurOverlay

class BlurOverlay: NSImageView {
    override var isFlipped: Bool {
        return true
    }
}

// MARK: - Blurable Extension

extension Blurable where Self: NSView {
    
    /// Applies a Gaussian blur overlay to the view.
    /// - Parameter blurRadius: Blur radius. Larger values produce stronger blur.
    func blur(blurRadius: CGFloat) {
        guard let superview = self.superview else {
            return
        }
        
        // Ensure the view is layer-backed before rendering.
        self.wantsLayer = true
        
        guard let layer = self.layer else {
            return
        }
        
        // Render the view into an image first.
        guard let bitmapRep = bitmapImageRepForCachingDisplay(in: bounds) else {
            return
        }
        
        cacheDisplay(in: bounds, to: bitmapRep)
        
        let image = NSImage(size: bounds.size)
        image.addRepresentation(bitmapRep)
        
        // Blur the rendered image.
        guard let blurredImage = applyGaussianBlur(to: image, radius: blurRadius) else {
            return
        }
        
        // Create the overlay that displays the blurred snapshot.
        let blurOverlay = BlurOverlay()
        blurOverlay.frame = self.frame
        blurOverlay.image = blurredImage
        blurOverlay.imageScaling = .scaleAxesIndependently
        blurOverlay.wantsLayer = true
        
        // `NSStackView` needs the overlay inserted differently.
        if let stackView = superview as? NSStackView,
           let index = stackView.arrangedSubviews.firstIndex(of: self) {
            self.removeFromSuperview()
            stackView.insertArrangedSubview(blurOverlay, at: index)
        } else {
            blurOverlay.frame.origin = self.frame.origin
            
            // Fade the blur overlay in.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                self.animator().alphaValue = 0
            } completionHandler: {
                superview.addSubview(blurOverlay)
                self.removeFromSuperview()
                self.alphaValue = 1
            }
        }
        
        // Retain the overlay through associated storage.
        objc_setAssociatedObject(
            self,
            &BlurableKey.blurable,
            blurOverlay,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }
    
    /// Removes the Gaussian blur overlay.
    func unBlur() {
        guard let blurOverlay = objc_getAssociatedObject(self, &BlurableKey.blurable) as? BlurOverlay,
              let superview = blurOverlay.superview else {
            return
        }
        
        // `NSStackView` needs the overlay removed differently.
        if let stackView = superview as? NSStackView,
           let index = stackView.arrangedSubviews.firstIndex(of: blurOverlay) {
            blurOverlay.removeFromSuperview()
            stackView.insertArrangedSubview(self, at: index)
        } else {
            self.frame.origin = blurOverlay.frame.origin
            
            // Fade the blur overlay out.
            self.alphaValue = 0
            superview.addSubview(self)
            
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                self.animator().alphaValue = 1
                blurOverlay.animator().alphaValue = 0
            } completionHandler: {
                blurOverlay.removeFromSuperview()
            }
        }
        
        // Clear the associated storage entry.
        objc_setAssociatedObject(
            self,
            &BlurableKey.blurable,
            nil,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }
    
    /// Whether the view currently has a blur overlay.
    var isBlurred: Bool {
        return objc_getAssociatedObject(self, &BlurableKey.blurable) is BlurOverlay
    }
    
    /// Applies `CIGaussianBlur` to an image.
    private func applyGaussianBlur(to image: NSImage, radius: CGFloat) -> NSImage? {
        guard let tiffData = image.tiffRepresentation,
              let ciImage = CIImage(data: tiffData) else {
            return nil
        }
        
        guard let blurFilter = CIFilter(name: "CIGaussianBlur") else {
            return nil
        }
        
        blurFilter.setValue(ciImage, forKey: kCIInputImageKey)
        blurFilter.setValue(radius, forKey: kCIInputRadiusKey)
        
        guard let outputImage = blurFilter.outputImage else {
            return nil
        }
        
        // `CIGaussianBlur` expands the image bounds, so crop back to the source size.
        let croppedImage = outputImage.cropped(to: ciImage.extent)
        
        let ciContext = CIContext(options: nil)
        guard let cgImage = ciContext.createCGImage(croppedImage, from: croppedImage.extent) else {
            return nil
        }
        
        return NSImage(cgImage: cgImage, size: image.size)
    }
}

// MARK: - NSView Blurable Conformance

extension NSView: Blurable {}

// MARK: - NSView Layer-Based Blur Extension

extension NSView {
    
    /// Adds a live Gaussian blur via `CALayer` filters without replacing the view.
    /// - Parameter radius: Blur radius.
    func addGaussianBlurEffect(radius: CGFloat = 10.0) {
        wantsLayer = true
        
        guard let layer = self.layer else { return }
        
        // Build the Core Animation blur filter.
        let blurFilter = CIFilter(name: "CIGaussianBlur")
        blurFilter?.setValue(radius, forKey: kCIInputRadiusKey)
        
        // Apply the filter to the layer background.
        layer.backgroundFilters = [blurFilter].compactMap { $0 }
        layer.masksToBounds = true
        
        // Retain the filter reference.
        objc_setAssociatedObject(
            self,
            &BlurableKey.blurLayer,
            blurFilter,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }
    
    /// Removes the blur effect installed by `addGaussianBlurEffect`.
    func removeGaussianBlurEffect() {
        layer?.backgroundFilters = nil
        
        objc_setAssociatedObject(
            self,
            &BlurableKey.blurLayer,
            nil,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }
    
    /// Updates the blur radius for the installed Gaussian blur effect.
    func updateGaussianBlurRadius(_ radius: CGFloat) {
        if let blurFilter = objc_getAssociatedObject(self, &BlurableKey.blurLayer) as? CIFilter {
            blurFilter.setValue(radius, forKey: kCIInputRadiusKey)
            layer?.backgroundFilters = [blurFilter]
        }
    }
    
    /// Returns whether a layer-backed Gaussian blur effect is active.
    var hasGaussianBlurEffect: Bool {
        return objc_getAssociatedObject(self, &BlurableKey.blurLayer) != nil
    }
}

// MARK: - GaussianBlurView

/// View that displays a configurable Gaussian blur background effect.
class GaussianBlurView: NSView {
    
    /// Blur radius.
    var blurRadius: CGFloat = 10.0 {
        didSet {
            if !isAnimating {
                updateBlurEffect()
            }
        }
    }
    
    /// Saturation applied alongside the blur effect.
    var saturation: CGFloat = 1.0 {
        didSet {
            if !isAnimating {
                updateBlurEffect()
            }
        }
    }
    
    /// Animation state.
    private var displayLink: CVDisplayLink?
    private var isAnimating = false
    private var animationStartTime: CFTimeInterval = 0
    private var animationDuration: CFTimeInterval = 0
    private var startBlurRadius: CGFloat = 0
    private var targetBlurRadius: CGFloat = 0
    private var startSaturation: CGFloat = 1.0
    private var targetSaturation: CGFloat = 1.0
    private var animationCompletion: (() -> Void)?
    
    /// Supported timing curves for blur animations.
    enum TimingFunction {
        case linear
        case easeIn
        case easeOut
        case easeInOut
        
        func apply(_ t: CGFloat) -> CGFloat {
            switch self {
            case .linear:
                return t
            case .easeIn:
                return t * t
            case .easeOut:
                return 1 - (1 - t) * (1 - t)
            case .easeInOut:
                return t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
            }
        }
    }
    
    private var timingFunction: TimingFunction = .easeOut
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupBlurEffect()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupBlurEffect()
    }
    
    deinit {
        stopAnimation()
    }
    
    private func setupBlurEffect() {
        wantsLayer = true
        layer?.masksToBounds = true
        updateBlurEffect()
    }
    
    private func updateBlurEffect() {
        guard let layer = self.layer else { return }
        
        var filters: [CIFilter] = []
        
        if let blurFilter = CIFilter(name: "CIGaussianBlur") {
            blurFilter.setValue(blurRadius, forKey: kCIInputRadiusKey)
            filters.append(blurFilter)
        }
        
        if saturation != 1.0, let saturationFilter = CIFilter(name: "CIColorControls") {
            saturationFilter.setValue(saturation, forKey: kCIInputSaturationKey)
            filters.append(saturationFilter)
        }
        
        layer.backgroundFilters = filters
    }
    
    // MARK: - Animation Methods
    
    /// Animates the blur radius.
    /// - Parameters:
    ///   - toRadius: Target blur radius.
    ///   - duration: Animation duration in seconds.
    ///   - timing: Timing function.
    ///   - completion: Optional completion handler.
    func animateBlurRadius(
        to toRadius: CGFloat,
        duration: TimeInterval = 0.3,
        timing: TimingFunction = .easeOut,
        completion: (() -> Void)? = nil
    ) {
        animateBlur(
            toRadius: toRadius,
            toSaturation: saturation,
            duration: duration,
            timing: timing,
            completion: completion
        )
    }
    
    /// Animates the saturation value.
    /// - Parameters:
    ///   - toSaturation: Target saturation.
    ///   - duration: Animation duration in seconds.
    ///   - timing: Timing function.
    ///   - completion: Optional completion handler.
    func animateSaturation(
        to toSaturation: CGFloat,
        duration: TimeInterval = 0.3,
        timing: TimingFunction = .easeOut,
        completion: (() -> Void)? = nil
    ) {
        animateBlur(
            toRadius: blurRadius,
            toSaturation: toSaturation,
            duration: duration,
            timing: timing,
            completion: completion
        )
    }
    
    /// Animates blur radius and saturation together.
    /// - Parameters:
    ///   - toRadius: Target blur radius.
    ///   - toSaturation: Target saturation.
    ///   - duration: Animation duration in seconds.
    ///   - timing: Timing function.
    ///   - completion: Optional completion handler.
    func animateBlur(
        toRadius: CGFloat,
        toSaturation: CGFloat,
        duration: TimeInterval = 0.3,
        timing: TimingFunction = .easeOut,
        completion: (() -> Void)? = nil
    ) {
        stopAnimation()
        
        startBlurRadius = blurRadius
        targetBlurRadius = toRadius
        startSaturation = saturation
        targetSaturation = toSaturation
        animationDuration = duration
        timingFunction = timing
        animationCompletion = completion
        animationStartTime = CACurrentMediaTime()
        isAnimating = true
        
        startTimerAnimation()
    }
    
    private var animationTimer: Timer?
    
    private func startTimerAnimation() {
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.updateAnimation()
        }
        RunLoop.main.add(animationTimer!, forMode: .common)
    }
    
    private func updateAnimation() {
        let currentTime = CACurrentMediaTime()
        let elapsed = currentTime - animationStartTime
        var progress = CGFloat(elapsed / animationDuration)
        
        if progress >= 1.0 {
            progress = 1.0
            stopAnimation()
        }
        
        let easedProgress = timingFunction.apply(progress)
        
        let currentBlurRadius = startBlurRadius + (targetBlurRadius - startBlurRadius) * easedProgress
        let currentSaturation = startSaturation + (targetSaturation - startSaturation) * easedProgress
        
        updateBlurEffectWithValues(blurRadius: currentBlurRadius, saturation: currentSaturation)
        
        if progress >= 1.0 {
            blurRadius = targetBlurRadius
            saturation = targetSaturation
            animationCompletion?()
            animationCompletion = nil
        }
    }
    
    private func updateBlurEffectWithValues(blurRadius: CGFloat, saturation: CGFloat) {
        guard let layer = self.layer else { return }
        
        var filters: [CIFilter] = []
        
        if let blurFilter = CIFilter(name: "CIGaussianBlur") {
            blurFilter.setValue(blurRadius, forKey: kCIInputRadiusKey)
            filters.append(blurFilter)
        }
        
        if saturation != 1.0, let saturationFilter = CIFilter(name: "CIColorControls") {
            saturationFilter.setValue(saturation, forKey: kCIInputSaturationKey)
            filters.append(saturationFilter)
        }
        
        layer.backgroundFilters = filters
    }
    
    /// Stops the active blur animation.
    func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        isAnimating = false
    }
}

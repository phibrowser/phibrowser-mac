// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import QuartzCore

/// Yellow frame around a tab's page card while its content is mirrored to a
/// remote screen-share consumer (#259, Arc-style shared-tab indicator).
final class ScreenShareMirroredBorderOverlayView: NSView {
    private static let borderWidth: CGFloat = 3
    private static let pulseDuration: CFTimeInterval = 1.2

    private let borderLayer = CAShapeLayer()

    var cornerRadius: CGFloat = LiquidGlassCompatible.webContentInnerComponentsCornerRadius {
        didSet {
            guard cornerRadius != oldValue else { return }
            needsLayout = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        let inset = Self.borderWidth / 2
        let rect = bounds.insetBy(dx: inset, dy: inset)
        borderLayer.path = CGPath(
            roundedRect: rect,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
        borderLayer.frame = bounds
    }

    func setActive(_ active: Bool) {
        isHidden = !active
        guard active else {
            borderLayer.removeAnimation(forKey: "opacityPulse")
            borderLayer.opacity = 1
            return
        }
        applyPulseIfNeeded()
    }

    private func commonInit() {
        wantsLayer = true
        layer?.masksToBounds = false
        borderLayer.fillColor = nil
        borderLayer.strokeColor = NSColor.systemYellow.cgColor
        borderLayer.lineWidth = Self.borderWidth
        borderLayer.opacity = 1
        layer?.addSublayer(borderLayer)
    }

    private func applyPulseIfNeeded() {
        borderLayer.removeAnimation(forKey: "opacityPulse")
        guard !isHidden else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            borderLayer.opacity = 1
            return
        }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1
        animation.toValue = 0.55
        animation.duration = Self.pulseDuration
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        borderLayer.add(animation, forKey: "opacityPulse")
    }
}

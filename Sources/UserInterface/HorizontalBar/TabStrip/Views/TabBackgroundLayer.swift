// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import QuartzCore

final class TabBackgroundLayer: CAShapeLayer {
    enum State {
        case inactive
        case hovered
        case active
    }

    var tabState: State = .inactive {
        didSet {
            if oldValue != tabState {
                updatePath(in: bounds)
            }
        }
    }

    var isPinned: Bool = false {
        didSet {
            if oldValue != isPinned {
                updatePath(in: bounds)
            }
        }
    }

    override init() {
        super.init()
        setupLayer()
    }

    override init(layer: Any) {
        super.init(layer: layer)
        if let other = layer as? TabBackgroundLayer {
            self.tabState = other.tabState
            self.isPinned = other.isPinned
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupLayer() {
        self.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        self.fillColor = NSColor.clear.cgColor
        self.actions = ["path": NSNull(), "fillColor": NSNull()]
    }

    func updatePath(in bounds: CGRect) {
        guard bounds.width > 0 && bounds.height > 0 else { return }
        let path = createPath(for: bounds, state: tabState, isPinned: isPinned)
        self.path = path
        updateAppearance()
    }

    private func updateAppearance() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.1)

        switch tabState {
            case .active:
                fillColor = ThemedColor.contentOverlayBackground.resolved().cgColor
            case .hovered:
                fillColor = ThemedColor.hover.resolved().cgColor
            case .inactive:
                fillColor = NSColor.clear.cgColor
        }

        CATransaction.commit()
    }

    private func createPath(for bounds: CGRect, state: State, isPinned: Bool) -> CGPath {
        let path = NSBezierPath()
        let width = bounds.width
        let height = bounds.height
        let cornerRadius = TabStripMetrics.Tab.cornerRadius

        if isPinned {
            return NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).cgPath
        }

        if state == .active {
            let invRadius = TabStripMetrics.Tab.inverseCornerRadius
            let extensionHeight = TabStripMetrics.Strip.bottomSpacing
            let extendedBottomY = -extensionHeight

            path.move(to: CGPoint(x: -invRadius, y: extendedBottomY))

            path.curve(to: CGPoint(x: 0, y: extendedBottomY + invRadius),
                       controlPoint1: CGPoint(x: -invRadius / 2, y: extendedBottomY),
                       controlPoint2: CGPoint(x: 0, y: extendedBottomY + invRadius / 2))

            path.line(to: CGPoint(x: 0, y: height - cornerRadius))

            path.curve(to: CGPoint(x: cornerRadius, y: height),
                       controlPoint1: CGPoint(x: 0, y: height - cornerRadius / 2),
                       controlPoint2: CGPoint(x: cornerRadius / 2, y: height))

            path.line(to: CGPoint(x: width - cornerRadius, y: height))

            path.curve(to: CGPoint(x: width, y: height - cornerRadius),
                       controlPoint1: CGPoint(x: width - cornerRadius / 2, y: height),
                       controlPoint2: CGPoint(x: width, y: height - cornerRadius / 2))

            path.line(to: CGPoint(x: width, y: extendedBottomY + invRadius))

            path.curve(to: CGPoint(x: width + invRadius, y: extendedBottomY),
                       controlPoint1: CGPoint(x: width, y: extendedBottomY + invRadius / 2),
                       controlPoint2: CGPoint(x: width + invRadius / 2, y: extendedBottomY))

            path.close()
        } else {
            let rectPath = NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius)
            path.append(rectPath)
        }

        return path.cgPath
    }
}

// MARK: - Extensions
extension NSBezierPath {
    var cgPath: CGPath {
        let path = CGMutablePath()
        var points = [CGPoint](repeating: .zero, count: 3)
        for i in 0 ..< self.elementCount {
            let type = self.element(at: i, associatedPoints: &points)
            switch type {
            case .moveTo: path.move(to: points[0])
            case .lineTo: path.addLine(to: points[0])
            case .curveTo: path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .closePath: path.closeSubpath()
            @unknown default: break
            }
        }
        return path
    }
}

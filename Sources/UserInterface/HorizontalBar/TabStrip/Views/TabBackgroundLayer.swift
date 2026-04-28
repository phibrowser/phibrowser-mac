// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import QuartzCore

final class TabBackgroundLayer: CAShapeLayer {
    weak var sourceView: NSView?

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
        self.path = createPath(for: bounds, state: tabState, isPinned: isPinned)
        updateAppearance()
    }

    private func updateAppearance() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.1)

        // Border (top + sides + inverse curves) for the active normal tab is
        // drawn by WebContentViewController's outerBorderLayer as part of a
        // unified path, so this layer only paints the fill.
        switch tabState {
            case .active:
                fillColor = ThemedColor.contentOverlayBackground.resolve(in: sourceView).cgColor
            case .hovered:
                fillColor = ThemedColor.hover.resolve(in: sourceView).cgColor
            case .inactive:
                fillColor = NSColor.clear.cgColor
        }

        CATransaction.commit()
    }

    func refreshAppearance() {
        updateAppearance()
    }

    private func createPath(for bounds: CGRect, state: State, isPinned: Bool) -> CGPath {
        let cornerRadius = TabStripMetrics.Tab.cornerRadius

        if isPinned || state != .active {
            return NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).cgPath
        }

        // Active normal tab: outer outline traced by the shared helper, then
        // closed along the apex y so the fill region matches the original path.
        let path = CGMutablePath()
        TabStripMetrics.appendActiveTabOutline(
            to: path,
            leftX: 0,
            rightX: bounds.width,
            apexY: -TabStripMetrics.Strip.bottomSpacing,
            tabTopY: bounds.height
        )
        path.closeSubpath()
        return path
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

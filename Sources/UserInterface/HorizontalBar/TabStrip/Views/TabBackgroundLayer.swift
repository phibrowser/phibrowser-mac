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
        case subSelected
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

    /// Position within a Chromium split pair, if any. Drives merged-bar shape.
    var splitPairPosition: SplitPairPosition? {
        didSet {
            if oldValue != splitPairPosition {
                updatePath(in: bounds)
            }
        }
    }

    /// True when the split this tab belongs to contains the focusing tab.
    /// Both halves fill with the active color in that case, so the merged bar
    /// reads as a single selected unit.
    var isSplitGroupActive: Bool = false {
        didSet {
            if oldValue != isSplitGroupActive {
                updateAppearance()
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
            self.splitPairPosition = other.splitPairPosition
            self.isSplitGroupActive = other.isSplitGroupActive
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupLayer() {
        self.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        self.fillColor = NSColor.clear.cgColor
        self.strokeColor = NSColor.clear.cgColor
        self.lineWidth = 0
        self.actions = [
            "path": NSNull(),
            "fillColor": NSNull(),
            "strokeColor": NSNull(),
            "lineWidth": NSNull(),
            "lineDashPattern": NSNull(),
        ]
    }

    func updatePath(in bounds: CGRect) {
        // A cell the layout engine has taken out of the flow gets a `.zero`
        // frame (collapsed group member, drag placeholder, collapsed split
        // pane) and must paint nothing. Keeping the previous path would keep
        // drawing it at its old size: `TabItemView` sets
        // `layer.masksToBounds = false` on purpose — the active tab's inverse
        // curves reach past the cell — so nothing clips a stale path back to
        // the empty bounds. `layout()` rebuilds it once the cell is measured
        // again.
        guard bounds.width > 0 && bounds.height > 0 else {
            self.path = nil
            return
        }
        self.path = createPath(for: bounds, state: tabState, isPinned: isPinned)
        updateAppearance()
    }

    private func updateAppearance() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.1)
        lineDashPattern = nil

        // Border (top + sides + inverse curves) for the active normal tab is
        // drawn by WebContentViewController's outerBorderLayer as part of a
        // unified path, so this layer only paints the fill.
        // Active horizontal tabs visually connect to WebContentHeader, which
        // uses windowBackground. Pure dark gives windowOverlayBackground a
        // separate brightness curve, so contentOverlayBackground leaves a seam.
        // Split-paired tabs: the focused half fills with the active color;
        // its partner uses the same color muted so the bar still reads as a
        // single selected unit while the focused half visually stands out.
        if splitPairPosition != nil {
            if tabState == .active {
                fillColor = ThemedColor.windowBackground.resolve(in: sourceView).cgColor
                strokeColor = NSColor.clear.cgColor
                lineWidth = 0
            } else if isSplitGroupActive {
                // Unfocused half of a focused split: keep the active fill
                // mostly opaque so it reads as part of the same selected
                // group as the focused half, just slightly muted.
                fillColor = ThemedColor.windowBackground
                    .resolve(in: sourceView)
                    .withAlphaComponent(0.7)
                    .cgColor
                strokeColor = NSColor.clear.cgColor
                lineWidth = 0
            } else {
                // Inactive split pair: outline each half so the merged bar
                // reads as a single grouped unit even when the split isn't
                // focused. The two halves' inner edges overlap at the seam
                // and double as a thin separator between the two tabs.
                fillColor = ThemedColor.hover.resolve(in: sourceView).cgColor
                strokeColor = ThemedColor.border.resolve(in: sourceView).cgColor
                lineWidth = 1
            }
            CATransaction.commit()
            return
        }

        switch tabState {
            case .active:
                fillColor = ThemedColor.windowBackground.resolve(in: sourceView).cgColor
            case .subSelected:
                fillColor = ThemedColor.tabSubSelectionBackground.resolve(in: sourceView).cgColor
            case .hovered:
                fillColor = ThemedColor.hover.resolve(in: sourceView).cgColor
            case .inactive:
                fillColor = NSColor.clear.cgColor
        }
        strokeColor = NSColor.clear.cgColor
        lineWidth = 0
        CATransaction.commit()
    }

    func refreshAppearance() {
        updateAppearance()
    }

    private func createPath(for bounds: CGRect, state: State, isPinned: Bool) -> CGPath {
        let cornerRadius = TabStripMetrics.Tab.cornerRadius

        // Split-paired tabs render as half of a merged rounded bar: the
        // corners that touch the partner are flat. Skip the Chromium-style
        // inverse-curve outline entirely — a single horizontal bar wrapping
        // both tabs reads more clearly than two separate pendant shapes.
        if let position = splitPairPosition {
            return mergedSplitPath(in: bounds,
                                   cornerRadius: cornerRadius,
                                   position: position)
        }

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

    /// Half-bar path for a split-paired tab: round the corners on the outer
    /// edge, flatten the corners that abut the partner. The two halves
    /// rendered edge-to-edge form a single continuous rounded bar.
    private func mergedSplitPath(in bounds: CGRect,
                                 cornerRadius: CGFloat,
                                 position: SplitPairPosition) -> CGPath {
        let path = CGMutablePath()
        let leftRadius: CGFloat = position == .first ? cornerRadius : 0
        let rightRadius: CGFloat = position == .second ? cornerRadius : 0
        let minX = bounds.minX
        let maxX = bounds.maxX
        let minY = bounds.minY
        let maxY = bounds.maxY

        path.move(to: CGPoint(x: minX + leftRadius, y: minY))
        path.addLine(to: CGPoint(x: maxX - rightRadius, y: minY))
        if rightRadius > 0 {
            path.addArc(center: CGPoint(x: maxX - rightRadius, y: minY + rightRadius),
                        radius: rightRadius,
                        startAngle: -.pi / 2, endAngle: 0,
                        clockwise: false)
        }
        path.addLine(to: CGPoint(x: maxX, y: maxY - rightRadius))
        if rightRadius > 0 {
            path.addArc(center: CGPoint(x: maxX - rightRadius, y: maxY - rightRadius),
                        radius: rightRadius,
                        startAngle: 0, endAngle: .pi / 2,
                        clockwise: false)
        }
        path.addLine(to: CGPoint(x: minX + leftRadius, y: maxY))
        if leftRadius > 0 {
            path.addArc(center: CGPoint(x: minX + leftRadius, y: maxY - leftRadius),
                        radius: leftRadius,
                        startAngle: .pi / 2, endAngle: .pi,
                        clockwise: false)
        }
        path.addLine(to: CGPoint(x: minX, y: minY + leftRadius))
        if leftRadius > 0 {
            path.addArc(center: CGPoint(x: minX + leftRadius, y: minY + leftRadius),
                        radius: leftRadius,
                        startAngle: .pi, endAngle: 3 * .pi / 2,
                        clockwise: false)
        }
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

// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
/// Custom slider cell that draws the track and knob with optional assets.
class ImageSliderCell: NSSliderCell {
    /// Track image used for the slider bar.
    @IBInspectable var trackImage: NSImage?
    /// Knob image used when a custom view or drawn knob is not provided.
    @IBInspectable var knobImage: NSImage?
    /// Custom knob view rendered into an image during drawing.
    var knobView: NSView?
    /// Optional override for the track drawing size.
    var barSize: NSSize?
    /// Optional override for the knob drawing size.
    var knobSize: NSSize?

    /// Primary color for the drawn knob border and center dot.
    var knobColor: NSColor?
    /// Fill color for the drawn knob interior.
    var knobFillColor: NSColor?
    /// Border width for the drawn knob.
    var knobBorderWidth: CGFloat = 2.0
    /// Diameter of the drawn knob center dot.
    var knobDotDiameter: CGFloat = 8.0

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        guard let image = trackImage else {
            super.drawBar(inside: rect, flipped: flipped)
            return
        }

        let drawSize = barSize ?? image.size
        var targetRect = rect

        targetRect.origin.y += (rect.height - drawSize.height) / 2.0
        targetRect.size.height = drawSize.height

        if let controlView = controlView {
            targetRect = controlView.backingAlignedRect(targetRect, options: .alignAllEdgesNearest)
        }

        image.draw(in: targetRect,
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .sourceOver,
                   fraction: 1.0,
                   respectFlipped: true,
                   hints: nil)
    }

    override func drawKnob(_ knobRect: NSRect) {
        if let primaryColor = knobColor {
            let fillColor = knobFillColor ?? .white
            let diameter: CGFloat
            if let size = knobSize {
                diameter = min(size.width, size.height)
            } else {
                diameter = min(knobRect.width, knobRect.height)
            }

            var circleRect = NSRect(
                x: knobRect.midX - diameter / 2.0,
                y: knobRect.midY - diameter / 2.0,
                width: diameter,
                height: diameter
            )
            if let controlView = controlView {
                circleRect = controlView.backingAlignedRect(circleRect, options: .alignAllEdgesNearest)
            }

            let innerRect = circleRect.insetBy(dx: knobBorderWidth, dy: knobBorderWidth)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: innerRect).fill()
            fillColor.setFill()
            NSBezierPath(ovalIn: innerRect).fill()

            let borderPath = NSBezierPath(ovalIn: circleRect.insetBy(dx: knobBorderWidth / 2.0, dy: knobBorderWidth / 2.0))
            borderPath.lineWidth = knobBorderWidth
            primaryColor.setStroke()
            borderPath.stroke()

            let dotRect = NSRect(
                x: circleRect.midX - knobDotDiameter / 2.0,
                y: circleRect.midY - knobDotDiameter / 2.0,
                width: knobDotDiameter,
                height: knobDotDiameter
            )
            primaryColor.setFill()
            NSBezierPath(ovalIn: dotRect).fill()

            return
        }

        if let view = knobView {
            let drawSize = knobSize ?? view.bounds.size

            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) ?? NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width), pixelsHigh: Int(view.bounds.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            view.cacheDisplay(in: view.bounds, to: rep)
            let image = NSImage(size: view.bounds.size)
            image.addRepresentation(rep)
            
            var targetRect = NSRect(
                x: knobRect.midX - drawSize.width / 2.0,
                y: knobRect.midY - drawSize.height / 2.0,
                width: drawSize.width,
                height: drawSize.height
            )
            if let controlView = controlView {
                targetRect = controlView.backingAlignedRect(targetRect, options: .alignAllEdgesNearest)
            }
            image.draw(in: targetRect)
            return
        }

        guard let image = knobImage else {
            super.drawKnob(knobRect)
            return
        }

        let drawSize = knobSize ?? image.size
        var targetRect = NSRect(
            x: knobRect.midX - drawSize.width / 2.0,
            y: knobRect.midY - drawSize.height / 2.0,
            width: drawSize.width,
            height: drawSize.height
        )

        if let controlView = controlView {
            targetRect = controlView.backingAlignedRect(targetRect, options: .alignAllEdgesNearest)
        }

        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: targetRect,
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .sourceOver,
                   fraction: 1.0,
                   respectFlipped: true,
                   hints: [.interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)])
    }
}

/// Slider wrapper that exposes the custom cell configuration to Interface Builder.
class CustomSlider: NSSlider {

    /// Track image configurable from Interface Builder or code.
    @IBInspectable var trackImage: NSImage? {
        didSet {
            (cell as? ImageSliderCell)?.trackImage = trackImage
            needsDisplay = true
        }
    }

    /// Knob image configurable from Interface Builder or code.
    @IBInspectable var knobImage: NSImage? {
        didSet {
            (cell as? ImageSliderCell)?.knobImage = knobImage
            needsDisplay = true
        }
    }

    /// Custom knob view rendered by the backing cell.
    var knobView: NSView? {
        didSet {
            (cell as? ImageSliderCell)?.knobView = knobView
            needsDisplay = true
        }
    }

    /// Optional override for track drawing size.
    var barSize: NSSize? {
        didSet {
            (cell as? ImageSliderCell)?.barSize = barSize
            needsDisplay = true
        }
    }

    /// Optional override for knob drawing size.
    var knobSize: NSSize? {
        didSet {
            (cell as? ImageSliderCell)?.knobSize = knobSize
            needsDisplay = true
        }
    }

    /// Primary color for the drawn knob border and center dot.
    var knobColor: NSColor? {
        didSet {
            (cell as? ImageSliderCell)?.knobColor = knobColor
            needsDisplay = true
        }
    }

    /// Fill color for the drawn knob interior.
    var knobFillColor: NSColor? {
        didSet {
            (cell as? ImageSliderCell)?.knobFillColor = knobFillColor
            needsDisplay = true
        }
    }

    /// Border width for the drawn knob.
    var knobBorderWidth: CGFloat = 2.0 {
        didSet {
            (cell as? ImageSliderCell)?.knobBorderWidth = knobBorderWidth
            needsDisplay = true
        }
    }

    /// Diameter of the drawn knob center dot.
    var knobDotDiameter: CGFloat = 8.0 {
        didSet {
            (cell as? ImageSliderCell)?.knobDotDiameter = knobDotDiameter
            needsDisplay = true
        }
    }

    override class var cellClass: AnyClass? {
        get { ImageSliderCell.self }
        set { }
    }

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        // Keep the cell-specific state in sync when the slider uses `ImageSliderCell`.
        if let existing = cell as? ImageSliderCell {
            existing.trackImage = trackImage
            existing.knobImage = knobImage
            existing.knobView = knobView
            existing.barSize = barSize
            existing.knobSize = knobSize
            existing.knobColor = knobColor
            existing.knobFillColor = knobFillColor
            existing.knobBorderWidth = knobBorderWidth
            existing.knobDotDiameter = knobDotDiameter
        } else {
            let newCell = ImageSliderCell()
            newCell.minValue = minValue
            newCell.maxValue = maxValue
            newCell.doubleValue = doubleValue
            newCell.allowsTickMarkValuesOnly = allowsTickMarkValuesOnly
            newCell.numberOfTickMarks = numberOfTickMarks
            newCell.target = target
            newCell.action = action
            newCell.isContinuous = isContinuous
            newCell.trackImage = trackImage
            newCell.knobImage = knobImage
            newCell.knobView = knobView
            newCell.barSize = barSize
            newCell.knobSize = knobSize
            newCell.knobColor = knobColor
            newCell.knobFillColor = knobFillColor
            newCell.knobBorderWidth = knobBorderWidth
            newCell.knobDotDiameter = knobDotDiameter
            cell = newCell
        }
    }

    override func awakeFromNib() {
        super.awakeFromNib()
        if let cell = cell as? ImageSliderCell {
            cell.trackImage = trackImage
            cell.knobImage = knobImage
            cell.knobView = knobView
            cell.barSize = barSize
            cell.knobSize = knobSize
            cell.knobColor = knobColor
            cell.knobFillColor = knobFillColor
            cell.knobBorderWidth = knobBorderWidth
            cell.knobDotDiameter = knobDotDiameter
        }
    }
}

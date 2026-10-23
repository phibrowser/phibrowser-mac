// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import CoreImage
import SwiftUI

// Theme slider shared by the General and Spaces panes.

func normalizedThemeSliderTrackColor(from color: NSColor) -> NSColor {
    let resolvedColor = color.usingColorSpace(.extendedSRGB) ?? color
    return resolvedColor.withAlphaComponent(1)
}

enum ThemeSliderTrackStyle {
    case saturation
    case pureBrightness(Appearance)
}

struct ThemeOpacitySliderView: NSViewRepresentable {
    @Binding var value: Double
    let trackColor: NSColor
    let borderColor: NSColor
    var trackStyle: ThemeSliderTrackStyle = .saturation
    /// Control width; the track image is generated at this width so the
    /// gradient is never stretched. Callers must match their `.frame` width.
    var width: CGFloat = 324
    var knobDiameter: CGFloat = 18

    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value)
    }

    func makeNSView(context: Context) -> CustomSlider {
        let slider = ThemeOpacityCustomSlider(frame: NSRect(origin: .zero, size: NSSize(width: width, height: 20)))
        slider.minValue = 0
        slider.maxValue = 100
        slider.doubleValue = value
        slider.isContinuous = true
        slider.barSize = NSSize(width: width, height: 10)
        slider.knobSize = NSSize(width: knobDiameter, height: knobDiameter)
        slider.knobView = ThemeOpacitySliderKnobView(
            frame: NSRect(origin: .zero, size: NSSize(width: knobDiameter, height: knobDiameter)),
            borderColor: borderColor
        )
        slider.trackImage = makeTrackImage(color: trackColor, borderColor: borderColor)
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.sliderValueChanged(_:))
        return slider
    }

    func updateNSView(_ slider: CustomSlider, context: Context) {
        context.coordinator.value = $value
        slider.barSize = NSSize(width: width, height: 10)
        slider.knobSize = NSSize(width: knobDiameter, height: knobDiameter)
        slider.knobView?.frame.size = NSSize(width: knobDiameter, height: knobDiameter)
        slider.trackImage = makeTrackImage(color: trackColor, borderColor: borderColor)
        if let knobView = slider.knobView as? ThemeOpacitySliderKnobView {
            knobView.borderColor = borderColor
        }
        if slider.doubleValue != value {
            AppLogDebug("[ThemeSlider] updateNSView push slider \(slider.doubleValue) → \(value)")
            slider.doubleValue = value
        }
    }

    private func makeTrackImage(color: NSColor, borderColor: NSColor) -> NSImage {
        let size = NSSize(width: width, height: 10)
        let image = NSImage(size: size)
        image.lockFocus()

        let rect = NSRect(origin: .zero, size: size)
        let path = NSBezierPath(roundedRect: rect, xRadius: size.height / 2, yRadius: size.height / 2)
        path.addClip()

        let baseColor = normalizedThemeSliderTrackColor(from: color)
        let startColor: NSColor
        let endColor: NSColor
        switch trackStyle {
        case .saturation:
            startColor = baseColor.withHSBSaturation(
                CGFloat(OverlaySaturationScale.minSaturation),
                alpha: 1
            )
            endColor = baseColor.withHSBSaturation(
                CGFloat(OverlaySaturationScale.maxSaturation),
                alpha: 1
            )
        case .pureBrightness(let appearance):
            startColor = baseColor.withHSBBrightness(
                CGFloat(
                    PureThemeBrightnessScale.brightness(
                        forSlider: 0,
                        appearance: appearance
                    )
                ),
                alpha: 1
            )
            endColor = baseColor.withHSBBrightness(
                CGFloat(
                    PureThemeBrightnessScale.brightness(
                        forSlider: 100,
                        appearance: appearance
                    )
                ),
                alpha: 1
            )
        }
        let gradient = NSGradient(starting: startColor, ending: endColor)
        gradient?.draw(in: path, angle: 0)

        borderColor.setStroke()
        path.lineWidth = 1
        path.stroke()

        image.unlockFocus()
        return image
    }

    final class Coordinator: NSObject {
        var value: Binding<Double>

        init(value: Binding<Double>) {
            self.value = value
        }

        @objc func sliderValueChanged(_ sender: NSSlider) {
            AppLogDebug("[ThemeSlider] NSSlider action value=\(sender.doubleValue)")
            value.wrappedValue = sender.doubleValue
        }
    }
}

private final class ThemeOpacitySliderKnobView: NSView {
    var borderColor: NSColor {
        didSet {
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        self.borderColor = ThemedColor.border.resolved()
        super.init(frame: frameRect)
        wantsLayer = true
    }

    init(frame frameRect: NSRect, borderColor: NSColor) {
        self.borderColor = borderColor
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        self.borderColor = ThemedColor.border.resolved()
        super.init(coder: coder)
        wantsLayer = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Inset by half the stroke width so the 1pt border sits exactly on the
        // view edge, leaving no visible gap when the knob rests at the bar end.
        let strokeWidth: CGFloat = 1
        let circleRect = bounds.insetBy(dx: strokeWidth / 2, dy: strokeWidth / 2)
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.16)
        shadow.set()

        let fillPath = NSBezierPath(ovalIn: circleRect)
        NSColor.white.setFill()
        fillPath.fill()

        NSGraphicsContext.current?.saveGraphicsState()
        NSShadow().set()
        borderColor.setStroke()
        fillPath.lineWidth = strokeWidth
        fillPath.stroke()
        NSGraphicsContext.current?.restoreGraphicsState()
    }
}

/// Slider variant whose cell positions the knob using the configured `knobSize`
/// instead of AppKit's default `knobThickness` (~21pt). Other CustomSlider
/// callers use a 20pt knob, where the resulting ~0.5pt gap is invisible; our
/// 16pt knob produces a ~2.5pt visible gap, so we take over the layout.
private final class ThemeOpacityCustomSlider: CustomSlider {
    override class var cellClass: AnyClass? {
        get { ThemeOpacitySliderCell.self }
        set { _ = newValue }
    }
}

private final class ThemeOpacitySliderCell: ImageSliderCell {
    override var knobThickness: CGFloat {
        knobSize?.width ?? super.knobThickness
    }

    /// Span the whole control width so the gradient track image (also generated
    /// at full width) is not squeezed into AppKit's default knob padding.
    override func barRect(flipped: Bool) -> NSRect {
        guard let controlView else {
            return super.barRect(flipped: flipped)
        }
        let bounds = controlView.bounds
        let drawHeight = barSize?.height ?? bounds.height
        return NSRect(
            x: 0,
            y: (bounds.height - drawHeight) / 2.0,
            width: bounds.width,
            height: drawHeight
        )
    }

    override func knobRect(flipped: Bool) -> NSRect {
        guard let controlView else {
            return super.knobRect(flipped: flipped)
        }
        let bounds = controlView.bounds
        let knobWidth = knobSize?.width ?? super.knobThickness
        let knobHeight = knobSize?.height ?? bounds.height
        let denominator = maxValue - minValue
        let ratio: CGFloat = denominator > 0 ? CGFloat((doubleValue - minValue) / denominator) : 0
        let travel = max(0, bounds.width - knobWidth)
        let x = ratio * travel
        let y = (bounds.height - knobHeight) / 2.0
        return NSRect(x: x, y: y, width: knobWidth, height: knobHeight)
    }
}

private struct SpaceThemeEditorGlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active

        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct ThemeEditorControlBoundsKey: PreferenceKey {
    static var defaultValue: [Anchor<CGRect>] { [] }

    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) {
        value.append(contentsOf: nextValue())
    }
}

/// Uses resolved colors as a guide, then softens the field for presentation.
/// Handles retain exact colors; the field favors gentle, continuous transitions.
enum ThemeEditorPaletteRenderer {
    static func image(brightness: Double, appearance: Appearance, pixelSize: Int = 512) -> CGImage? {
        guard pixelSize > 0 else { return nil }
        let palette = ThemePalette(hue: 0, saturation: 0, brightness: brightness)
        var pixels = [UInt16](repeating: .max, count: pixelSize * pixelSize * 4)
        for y in 0..<pixelSize {
            for x in 0..<pixelSize {
                let point = CGPoint(
                    x: (Double(x) + 0.5) / Double(pixelSize),
                    y: (Double(y) + 0.5) / Double(pixelSize)
                )
                guard let color = palette.color(at: point, appearance: appearance).usingColorSpace(.sRGB) else { return nil }
                let offset = (y * pixelSize + x) * 4
                pixels[offset] = UInt16((color.redComponent * 65535).rounded())
                pixels[offset + 1] = UInt16((color.greenComponent * 65535).rounded())
                pixels[offset + 2] = UInt16((color.blueComponent * 65535).rounded())
            }
        }
        let data = pixels.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        guard let image = CGImage(
            width: pixelSize, height: pixelSize, bitsPerComponent: 16, bitsPerPixel: 64,
            bytesPerRow: pixelSize * 8, space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
                .union(.byteOrder16Little),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        ) else { return nil }

        // Work in linear light at half-float precision. Clamp before blurring
        // so the cropped field remains opaque all the way to its corners.
        let source = CIImage(cgImage: image)
        let softened = source.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: Double(pixelSize) * 0.07])
            .cropped(to: source.extent)
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0.84,
                kCIInputContrastKey: 0.96
            ])
        let context = CIContext(options: [.workingFormat: CIFormat.RGBAh])
        return context.createCGImage(softened, from: source.extent, format: .RGBA16, colorSpace: colorSpace)
    }
}

private struct ThemeEditorPaletteField: NSViewRepresentable {
    let brightness: Double
    let appearance: Appearance

    func makeNSView(context: Context) -> FieldView {
        let view = FieldView()
        view.imageScaling = .scaleAxesIndependently
        view.wantsLayer = true
        view.layer?.contentsFormat = .RGBA16Float
        return view
    }

    func updateNSView(_ view: FieldView, context: Context) {
        // Hue, saturation and harmony edits only move handles; the field stays
        // cached. Legacy brightness changes are the only reason to regenerate it.
        guard view.renderedBrightness != brightness || view.renderedAppearance != appearance else { return }
        guard let image = ThemeEditorPaletteRenderer.image(brightness: brightness, appearance: appearance) else { return }
        view.image = NSImage(cgImage: image, size: NSSize(width: 244, height: 244))
        view.renderedBrightness = brightness
        view.renderedAppearance = appearance
    }

    final class FieldView: NSImageView {
        var renderedBrightness: Double?
        var renderedAppearance: Appearance?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Both appearances share the same softening and crossfade between cached fields.
private struct ThemeEditorPaletteBackground: View {
    @Environment(\.phiAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let brightness: Double

    var body: some View {
        ZStack {
            ThemeEditorPaletteField(brightness: brightness, appearance: .light)
            ThemeEditorPaletteField(brightness: brightness, appearance: .dark)
                .opacity(appearance.isDark ? 1 : 0)
        }
        .allowsHitTesting(false)
        .animation(reduceMotion ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.3), value: appearance)
        .accessibilityHidden(true)
    }
}

/// Claims only blank editor background. Controls keep their native/SwiftUI
/// mouse tracking, while AppKit owns window dragging outside their bounds.
private struct ThemeEditorWindowDragSurface: NSViewRepresentable {
    let controlRects: [CGRect]

    func makeNSView(context: Context) -> DragView {
        DragView()
    }

    func updateNSView(_ view: DragView, context: Context) {
        view.controlRects = controlRects
    }

    final class DragView: NSView {
        var controlRects: [CGRect] = []
        private var mouseDownLocation: NSPoint?
        override var isFlipped: Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let window, window.isMovable, !isHidden else { return nil }
            let localPoint = convert(point, from: superview)
            guard bounds.contains(localPoint),
                  !controlRects.contains(where: { $0.contains(localPoint) }) else { return nil }
            switch NSApp.currentEvent?.type {
            case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
                return self
            default:
                return nil
            }
        }

        override func mouseDown(with event: NSEvent) {
            mouseDownLocation = event.locationInWindow
        }

        override func mouseDragged(with event: NSEvent) {
            guard let window, let mouseDownLocation,
                  hypot(event.locationInWindow.x - mouseDownLocation.x,
                        event.locationInWindow.y - mouseDownLocation.y) >= 3 else { return }
            self.mouseDownLocation = nil
            // Start after the drag threshold: on macOS 27 a mouse-down
            // performDrag call can return before tracking begins.
            window.performDrag(with: event)
        }

        override func mouseUp(with event: NSEvent) {
            mouseDownLocation = nil
        }
    }
}

/// The existing Space theme editor, with a linked palette and live window updates.
struct SpaceThemeEditorView: View {
    static let contentSize = NSSize(width: 260, height: 296)
    static let menuContentSize = contentSize

    let spaceId: String?
    let isEmbeddedInMenu: Bool
    let allowsWindowDragging: Bool
    let onDismiss: () -> Void

    @ObservedObject private var spaceManager = SpaceManager.shared
    @Environment(\.phiAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var palette: ThemePalette
    @State private var draggedHandle: Int?
    @State private var hoveredHarmony: ThemePalette.Harmony?
    private let storeIdentifier: UUID?
    /// New Spaces edit the form's draft until creation commits it.
    private let draftPalette: Binding<ThemePalette>?

    init(spaceId: String, isEmbeddedInMenu: Bool = false, allowsWindowDragging: Bool = false, onDismiss: @escaping () -> Void) {
        self.spaceId = spaceId
        draftPalette = nil
        self.isEmbeddedInMenu = isEmbeddedInMenu
        self.allowsWindowDragging = allowsWindowDragging
        self.onDismiss = onDismiss
        let manager = SpaceManager.shared
        storeIdentifier = manager.storeIdentifier
        let appearance = ThemeManager.shared.currentAppearance
        _palette = State(initialValue: manager.themePalette(forSpaceId: spaceId) ?? ThemePalette(
            color: manager.resolvedTheme(forSpaceId: spaceId).color(for: .windowOverlayBackground, appearance: appearance),
            appearance: appearance
        ).settingBrightness(1))
    }

    init(palette: Binding<ThemePalette>, onDismiss: @escaping () -> Void) {
        spaceId = nil
        isEmbeddedInMenu = false
        allowsWindowDragging = false
        self.onDismiss = onDismiss
        storeIdentifier = nil
        draftPalette = palette
        _palette = State(initialValue: palette.wrappedValue)
    }

    var body: some View {
        VStack(spacing: 10) {
            colorField
            toolbar
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .frame(width: Self.contentSize.width, height: Self.contentSize.height)
        .background { SpaceThemeEditorGlassBackground() }
        // Standalone panels use AppKit's system window mask, shared with the
        // browser. Embedded editors still need a continuous content mask.
        .clipShape(RoundedRectangle(
            cornerRadius: allowsWindowDragging ? 0 : LiquidGlassCompatible.cornerRadius,
            style: .continuous
        ))
        .overlayPreferenceValue(ThemeEditorControlBoundsKey.self) { anchors in
            if allowsWindowDragging {
                GeometryReader { geometry in
                    ThemeEditorWindowDragSurface(controlRects: anchors.map { geometry[$0] })
                }
            }
        }
        .onAppear(perform: syncControls)
        .onDisappear {
            if draggedHandle != nil { update(palette) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .spaceThemeDidChange)) { notification in
            guard let spaceId,
                  notification.userInfo?["spaceId"] as? String == spaceId else { return }
            syncControls()
        }
        .onReceive(NotificationCenter.default.publisher(for: .themeDidChange)) { _ in syncControls() }
        .onReceive(NotificationCenter.default.publisher(for: .appearanceDidChange)) { _ in syncControls() }
        .onChange(of: spaceManager.storeIdentifier) { _, _ in onDismiss() }
        .onChange(of: spaceManager.spaces.map(\.spaceId)) { _, ids in
            if let spaceId, !ids.contains(spaceId) { onDismiss() }
        }
        .onChange(of: draftPalette?.wrappedValue) { _, _ in syncControls() }
    }

    private var toolbar: some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                appearanceButton(.light, asset: "sun", label: NSLocalizedString(
                    "themes.appearance.lightOption", value: "Light", comment: "Appearance choice: always light mode"
                ))
                appearanceButton(.dark, asset: "moon", label: NSLocalizedString(
                    "themes.appearance.darkOption", value: "Dark", comment: "Appearance choice: always dark mode"
                ))
            }
            .padding(1)
            .overlay {
                Capsule().strokeBorder(Color.primary.opacity(appearance.isDark ? 0.2 : 0.06), lineWidth: 1)
            }
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                ForEach(ThemePalette.Harmony.allCases, id: \.self) { harmony in
                    harmonyButton(harmony)
                }
            }
            .padding(1)
            .overlay {
                Capsule().strokeBorder(Color.primary.opacity(appearance.isDark ? 0.2 : 0.06), lineWidth: 1)
            }
        }
        .frame(height: 24)
    }

    private func harmonyButton(_ harmony: ThemePalette.Harmony) -> some View {
        let selected = palette.harmony == harmony
        let mode = appearance.isDark ? "dark" : "light"
        let label: String
        let assetName: String
        switch harmony {
        case .single:
            label = NSLocalizedString(
                "theme.editor.singleColor", value: "Single color",
                comment: "Theme editor - select a palette with one color"
            )
            assetName = "theme-editor-one-ring-" + mode
        case .analogous:
            label = NSLocalizedString(
                "theme.editor.analogousColors", value: "Analogous colors",
                comment: "Theme editor - select two linked neighboring colors separated by 45 degrees"
            )
            assetName = "theme-editor-analogous-" + mode
        case .complementary:
            label = NSLocalizedString(
                "theme.editor.twoColors", value: "Two colors",
                comment: "Theme editor - select two linked complementary colors"
            )
            assetName = "theme-editor-count-two-" + mode
        case .splitComplementary:
            label = NSLocalizedString(
                "theme.editor.threeColors", value: "Three colors",
                comment: "Theme editor - select three linked split complementary colors"
            )
            assetName = "theme-editor-count-three-" + mode
        }
        return Button {
            update(palette.settingHarmony(harmony))
        } label: {
            ZStack {
                Image(assetName)
                if harmony == .single {
                    Image("theme-editor-one-dot")
                        .renderingMode(.template)
                        .foregroundStyle(Color.primary)
                }
            }
            .frame(width: 22, height: 22)
            .background {
                Circle().fill(Color.primary.opacity(selected
                    ? (appearance.isDark ? 0.2 : 0.06)
                    : (hoveredHarmony == harmony ? 0.04 : 0)))
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hoveredHarmony = $0 ? harmony : nil }
        .anchorPreference(key: ThemeEditorControlBoundsKey.self, value: .bounds) { [$0] }
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier(harmony == .analogous
            ? "theme.editor.harmony.analogous"
            : "theme.editor.colorCount.\(harmony.colorCount)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func appearanceButton(_ choice: UserAppearanceChoice, asset: String, label: String) -> some View {
        let selected = appearance.isDark == (choice == .dark)
        return Button {
            ThemeManager.shared.setUserAppearanceChoice(choice)
        } label: {
            Image("theme-editor-" + asset)
                .renderingMode(.template)
                .foregroundStyle(Color.primary.opacity(selected ? 1 : 0.3))
                .frame(width: 22, height: 22)
                .background { Circle().fill(Color.primary.opacity(selected ? (appearance.isDark ? 0.2 : 0.06) : 0)) }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .anchorPreference(key: ThemeEditorControlBoundsKey.self, value: .bounds) { [$0] }
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var colorField: some View {
        GeometryReader { geometry in
            let colors = palette.colors(for: appearance)
            ZStack {
                ThemeEditorPaletteBackground(brightness: palette.brightness)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                ForEach(0..<palette.colorCount, id: \.self) { index in
                    let point = palette.handlePosition(at: index)
                    let diameter: CGFloat = index == 0 ? 38 : (index == 1 ? 28 : 14)
                    Circle()
                        .fill(Color(nsColor: colors[index].withAlphaComponent(1)))
                        .overlay { Circle().strokeBorder(.white, lineWidth: 2) }
                        .animation(reduceMotion ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.3), value: appearance)
                        .frame(width: diameter, height: diameter)
                        .frame(width: 40, height: 40)
                        .contentShape(Circle())
                        .focusable()
                        .focusEffectDisabled()
                        .onKeyPress(.leftArrow) { update(palette.rotatingHue(by: -1 / 360)); return .handled }
                        .onKeyPress(.rightArrow) { update(palette.rotatingHue(by: 1 / 360)); return .handled }
                        .accessibilityElement()
                        .accessibilityLabel(String(format: NSLocalizedString(
                            "theme.editor.colorHandle", value: "Color %d",
                            comment: "Theme editor - accessible color handle label; placeholder is the color number, from one to three"
                        ), index + 1))
                        .accessibilityValue(colors[index].hexRGBString)
                        .accessibilityAdjustableAction { direction in
                            update(palette.rotatingHue(by: direction == .increment ? 1 / 360 : -1 / 360))
                        }
                        .position(x: point.x * geometry.size.width, y: point.y * geometry.size.height)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                if draggedHandle == nil {
                    let handles = (0..<palette.colorCount).map { index in
                        let point = palette.handlePosition(at: index)
                        return (index: index, distance: hypot(
                            point.x * geometry.size.width - value.startLocation.x,
                            point.y * geometry.size.height - value.startLocation.y
                        ))
                    }
                    draggedHandle = handles.filter { $0.distance <= 20 }
                        .min { $0.distance < $1.distance }?.index ?? 0
                }
                guard hypot(value.translation.width, value.translation.height) >= 3 else { return }
                update(palette.movingHandle(at: draggedHandle ?? 0, to: CGPoint(
                    x: value.location.x / geometry.size.width, y: value.location.y / geometry.size.height
                ), snappingToCenter: true), preview: true)
            }.onEnded { value in
                let isClick = hypot(value.translation.width, value.translation.height) < 3
                update(palette.movingHandle(at: isClick ? 0 : (draggedHandle ?? 0), to: CGPoint(
                    x: value.location.x / geometry.size.width, y: value.location.y / geometry.size.height
                ), snappingToCenter: true), animated: isClick)
                draggedHandle = nil
            })
        }
        .frame(width: 244, height: 244)
        .clipShape(RoundedRectangle(cornerRadius: LiquidGlassCompatible.cornerRadius, style: .continuous))
        .anchorPreference(key: ThemeEditorControlBoundsKey.self, value: .bounds) { [$0] }
        .accessibilityIdentifier("theme.editor.palette")
    }

    private func update(_ newPalette: ThemePalette, animated: Bool = false, preview: Bool = false) {
        guard draftPalette != nil || spaceManager.acceptsStoreAction(from: storeIdentifier) else {
            onDismiss()
            return
        }
        guard !preview || newPalette != palette else { return }
        withAnimation(animated && !reduceMotion ? .timingCurve(0.22, 1, 0.36, 1, duration: 0.3) : nil) {
            palette = newPalette
            if let draftPalette {
                draftPalette.wrappedValue = newPalette
            } else if let spaceId {
                if preview {
                    spaceManager.previewThemePalette(newPalette, forSpaceId: spaceId, expectedStoreIdentifier: storeIdentifier)
                } else {
                    spaceManager.setThemePalette(newPalette, forSpaceId: spaceId, expectedStoreIdentifier: storeIdentifier)
                }
            }
        }
    }

    private func syncControls() {
        if let draftPalette {
            palette = draftPalette.wrappedValue
            return
        }
        guard let spaceId, spaceManager.acceptsStoreAction(from: storeIdentifier) else { onDismiss(); return }
        guard draggedHandle == nil else { return }
        palette = spaceManager.themePalette(forSpaceId: spaceId) ?? ThemePalette(
            color: spaceManager.resolvedTheme(forSpaceId: spaceId).color(for: .windowOverlayBackground, appearance: appearance),
            appearance: appearance
        ).settingBrightness(1)
    }
}

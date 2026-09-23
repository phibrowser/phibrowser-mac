// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SwiftUI

// Theme slider shared by the General pane, Spaces pane, and Create Space panel.

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
        view.blendingMode = .withinWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = 10
        view.layer?.masksToBounds = true

        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Compact editor used by the existing "Edit Theme" menu actions. It shares
/// the persistent Space theme and color-component paths used by the General
/// and Spaces settings panes.
struct SpaceThemeEditorView: View {
    static let contentSize = NSSize(width: 328, height: 99)
    static let menuContentSize = NSSize(width: 248, height: 76)

    private static let innerCardSize = NSSize(width: 312, height: 83)
    private static let swatchGroupWidth: CGFloat = 200
    private static let sliderWidth: CGFloat = 199
    private static let panelDivider = Color(nsColor: .separatorColor)
    private static let panelInnerBorder = Color(nsColor: .separatorColor)

    let spaceId: String
    let isEmbeddedInMenu: Bool
    let onDismiss: () -> Void

    @ObservedObject private var spaceManager = SpaceManager.shared
    @Environment(\.phiAppearance) private var appearance

    @State private var selectedThemeId: String
    @State private var sliderValue: Double

    init(spaceId: String, isEmbeddedInMenu: Bool = false, onDismiss: @escaping () -> Void) {
        self.spaceId = spaceId
        self.isEmbeddedInMenu = isEmbeddedInMenu
        self.onDismiss = onDismiss

        let themeId = SpaceManager.shared.resolvedThemeId(forSpaceId: spaceId)
        let appearance = ThemeManager.shared.currentAppearance
        _selectedThemeId = State(initialValue: themeId)
        _sliderValue = State(
            initialValue: Self.sliderValue(
                forSpaceId: spaceId,
                themeId: themeId,
                appearance: appearance
            )
        )
    }

    var body: some View {
        Group {
            if isEmbeddedInMenu {
                GeometryReader { geometry in
                    VStack(spacing: 8) {
                        colorRow
                            .frame(height: 24)
                        saturationRow(width: geometry.size.width)
                            .frame(height: 28)
                    }
                }
                // Match the native menu's content column, leaving room for checkmarks.
                .padding(.leading, 30)
                .padding(.trailing, 16)
                .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    colorRow
                        .frame(height: 40)
                    Rectangle()
                        .fill(Self.panelDivider)
                        .frame(height: 1)
                    saturationRow(width: Self.sliderWidth)
                        .frame(height: 42)
                }
                .padding(.horizontal, 12)
                .frame(width: Self.innerCardSize.width, height: Self.innerCardSize.height)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(0.01))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Self.panelInnerBorder, lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .padding(8)
                .frame(width: Self.contentSize.width, height: Self.contentSize.height)
                .background { SpaceThemeEditorGlassBackground() }
            }
        }
        .onAppear(perform: syncControls)
        .onReceive(NotificationCenter.default.publisher(for: .spaceThemeDidChange)) { notification in
            guard let changedSpaceId = notification.userInfo?["spaceId"] as? String,
                  changedSpaceId == spaceId else { return }
            syncControls()
        }
        .onReceive(NotificationCenter.default.publisher(for: .themeDidChange)) { _ in
            syncControls()
        }
        .onReceive(NotificationCenter.default.publisher(for: .appearanceDidChange)) { _ in
            syncControls()
        }
        .onChange(of: spaceManager.spaces.map(\.spaceId)) { _, spaceIds in
            if !spaceIds.contains(spaceId) {
                onDismiss()
            }
        }
    }

    private var colorRow: some View {
        HStack(spacing: 0) {
            if !isEmbeddedInMenu {
                Text(NSLocalizedString("settings.spaces.theme.colorLabel", value: "Color", comment: "Spaces settings - theme color row label"))
                    .font(.body)
                    .foregroundStyle(.primary)

                Spacer(minLength: 0)
            }

            HStack(spacing: 0) {
                ForEach(ThemeManager.shared.orderedThemes, id: \.id) { theme in
                    ThemeSwatchView(
                        fillColor: theme == .pure
                            ? .white
                            : Color(theme.color(for: .themeColor, appearance: appearance)),
                        ringColor: Color(theme.color(for: .themeColor, appearance: appearance)),
                        selected: selectedThemeId == theme.id,
                        title: nil,
                        showsContrastBorder: theme == .pure,
                        dotDiameter: 16,
                        ringDiameter: 20,
                        action: { selectTheme(theme.id) }
                    )
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(theme.name)
                }
            }
            .frame(width: isEmbeddedInMenu ? nil : Self.swatchGroupWidth)
        }
    }

    private func saturationRow(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            if !isEmbeddedInMenu {
                Text(NSLocalizedString("settings.spaces.theme.saturationLabel", value: "Saturation", comment: "Spaces settings - theme saturation row label for the per-Space window colors"))
                    .font(.body)
                    .foregroundStyle(.primary)

                Spacer(minLength: 0)
            }

            ThemeOpacitySliderView(
                value: sliderBinding,
                trackColor: sliderTrackColor,
                borderColor: .separatorColor,
                trackStyle: sliderTrackStyle,
                width: width,
                knobDiameter: 16
            )
            .frame(width: width, height: 20)
            .accessibilityLabel(NSLocalizedString("settings.spaces.theme.saturationLabel", value: "Saturation", comment: "Spaces settings - theme saturation row label for the per-Space window colors"))
        }
    }

    private var sliderBinding: Binding<Double> {
        Binding(
            get: { sliderValue },
            set: { newValue in
                sliderValue = newValue
                if selectedThemeId == Theme.pure.id {
                    spaceManager.setPureThemeSliderValue(newValue, forSpaceId: spaceId)
                } else {
                    spaceManager.setOverlaySaturation(
                        CGFloat(OverlaySaturationScale.saturation(forSlider: newValue)),
                        forSpaceId: spaceId,
                        appearance: appearance
                    )
                }
            }
        )
    }

    private var sliderTrackColor: NSColor {
        spaceManager.resolvedTheme(forSpaceId: spaceId)
            .color(for: .windowOverlayBackground, appearance: appearance)
    }

    private var sliderTrackStyle: ThemeSliderTrackStyle {
        selectedThemeId == Theme.pure.id ? .pureBrightness(appearance) : .saturation
    }

    private var displayedTheme: Theme {
        ThemeManager.shared.registeredThemes[selectedThemeId]
            ?? Theme.builtInThemes.first(where: { $0.id == selectedThemeId })
            ?? ThemeManager.shared.currentTheme
    }

    private func selectTheme(_ themeId: String) {
        guard selectedThemeId != themeId else { return }
        selectedThemeId = themeId
        spaceManager.setTheme(forSpaceId: spaceId, themeId: themeId)
        syncControls()
    }

    private func syncControls() {
        let themeId = spaceManager.resolvedThemeId(forSpaceId: spaceId)
        selectedThemeId = themeId
        sliderValue = Self.sliderValue(
            forSpaceId: spaceId,
            themeId: themeId,
            appearance: appearance
        )
    }

    private static func sliderValue(
        forSpaceId spaceId: String,
        themeId: String,
        appearance: Appearance
    ) -> Double {
        if themeId == Theme.pure.id {
            return SpaceManager.shared.effectivePureThemeSliderValue(
                forSpaceId: spaceId,
                appearance: appearance
            )
        }
        return OverlaySaturationScale.sliderValue(
            forSaturation: Double(
                SpaceManager.shared.effectiveOverlaySaturation(
                    forSpaceId: spaceId,
                    appearance: appearance
                )
            )
        )
    }
}

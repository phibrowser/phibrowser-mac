// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import CoreImage
import SwiftUI

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

    /// The field depends on brightness and appearance only, so a few entries
    /// cover every Space. NSCache drops them under memory pressure.
    private static let renderedFields: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 4
        return cache
    }()
    @MainActor private static var waitingFieldHandlers: [NSString: [(CGImage) -> Void]] = [:]

    private static func fieldKey(brightness: Double, appearance: Appearance) -> NSString {
        "\(appearance.rawValue):\(brightness)" as NSString
    }

    /// Renders the fields a palette opens with, so the first editor does not
    /// wait for them.
    @MainActor static func prewarmFields() {
        for appearance in [Appearance.light, .dark] {
            field(brightness: 1, appearance: appearance, qos: .utility) { _ in }
        }
    }

    /// Delivers a cached field synchronously. Otherwise renders it once off
    /// the main thread and delivers it to every caller waiting for that key.
    @MainActor static func field(
        brightness: Double,
        appearance: Appearance,
        qos: DispatchQoS.QoSClass = .userInitiated,
        completion: @escaping (CGImage) -> Void
    ) {
        let key = fieldKey(brightness: brightness, appearance: appearance)
        if let image = renderedFields.object(forKey: key) {
            completion(image)
            return
        }
        guard waitingFieldHandlers[key] == nil else {
            waitingFieldHandlers[key]?.append(completion)
            return
        }
        waitingFieldHandlers[key] = [completion]
        DispatchQueue.global(qos: qos).async {
            let rendered = Self.image(brightness: brightness, appearance: appearance)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let handlers = waitingFieldHandlers.removeValue(forKey: key) ?? []
                    guard let rendered else { return }
                    renderedFields.setObject(rendered, forKey: key)
                    handlers.forEach { $0(rendered) }
                }
            }
        }
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
        guard view.requestedBrightness != brightness || view.requestedAppearance != appearance else { return }
        view.requestedBrightness = brightness
        view.requestedAppearance = appearance
        ThemeEditorPaletteRenderer.field(brightness: brightness, appearance: appearance) { [weak view] image in
            guard let view, view.requestedBrightness == brightness, view.requestedAppearance == appearance else { return }
            view.image = NSImage(cgImage: image, size: NSSize(width: 244, height: 244))
        }
    }

    final class FieldView: NSImageView {
        var requestedBrightness: Double?
        var requestedAppearance: Appearance?
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

/// Lands the latest pointer preview once per display frame. A slow main
/// thread drops intermediate palettes instead of queueing a window re-theme
/// for every mouse event.
@MainActor
private final class ThemeEditorPreviewThrottle: NSObject {
    private var pendingPreview: (() -> Void)?
    private var displayLink: CADisplayLink?

    func schedule(_ preview: @escaping () -> Void) {
        pendingPreview = preview
        guard displayLink == nil else { return }
        guard let link = NSScreen.main?.displayLink(target: self, selector: #selector(displayLinkFired(_:))) else {
            flush()
            return
        }
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func flush() {
        let preview = pendingPreview
        pendingPreview = nil
        preview?()
    }

    func cancel() {
        pendingPreview = nil
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        guard pendingPreview != nil else {
            cancel()
            return
        }
        flush()
    }
}

/// The existing Space theme editor, with a linked palette and live window updates.
struct SpaceThemeEditorView: View {
    static let contentSize = NSSize(width: 260, height: 328)

    let spaceId: String?
    let allowsWindowDragging: Bool
    let onDismiss: () -> Void

    @ObservedObject private var spaceManager = SpaceManager.shared
    @Environment(\.phiAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var palette: ThemePalette
    @State private var draggedHandle: Int?
    @State private var hoveredHarmony: ThemePalette.Harmony?
    @State private var previewThrottle = ThemeEditorPreviewThrottle()
    @AppStorage(PhiPreferences.ThemeSettings.savedPalettes.rawValue) private var savedPaletteData = Data()
    @State private var presetPage = 0
    @State private var hoveredPreset: Int?
    @State private var deletablePreset: Int?
    @State private var uneditedPalette: ThemePalette?
    private let storeIdentifier: UUID?
    /// New Spaces edit the form's draft until creation commits it.
    private let draftPalette: Binding<ThemePalette>?

    init(spaceId: String, allowsWindowDragging: Bool = false, onDismiss: @escaping () -> Void) {
        self.spaceId = spaceId
        draftPalette = nil
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
        allowsWindowDragging = false
        self.onDismiss = onDismiss
        storeIdentifier = nil
        draftPalette = palette
        _palette = State(initialValue: palette.wrappedValue)
    }

    var body: some View {
        VStack(spacing: 10) {
            toolbar
            VStack(spacing: 8) {
                colorField
                presetStrip
            }
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
        .onAppear {
            syncControls()
            focusSelectedPreset()
        }
        .onDisappear {
            if draggedHandle != nil { update(palette) }
            previewThrottle.cancel()
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
            Spacer().frame(width: 29)
            HStack(spacing: 0) {
                ForEach(ThemePalette.Harmony.allCases, id: \.self) { harmony in
                    harmonyButton(harmony)
                }
            }
            .padding(1)
            .overlay {
                Capsule().strokeBorder(Color.primary.opacity(appearance.isDark ? 0.2 : 0.06), lineWidth: 1)
            }
            Spacer(minLength: 0)
        }
        .overlay(alignment: .trailing) {
            if uneditedPalette != nil {
                HStack(spacing: 2) {
                    editorButton(asset: "reset", label: NSLocalizedString(
                        "theme.editor.reset", value: "Reset",
                        comment: "Theme editor - restore the palette before manual adjustments"
                    ), identifier: "theme.editor.reset") {
                        guard let original = uneditedPalette else { return }
                        uneditedPalette = nil
                        update(original, animated: true)
                    }
                    editorButton(asset: "save", label: NSLocalizedString(
                        "theme.editor.save", value: "Save color",
                        comment: "Theme editor - save the current solid or gradient palette as a custom swatch"
                    ), identifier: "theme.editor.save", action: savePalette)
                }
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
            edit(palette.settingHarmony(harmony))
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
                        .onKeyPress(.leftArrow) { edit(palette.rotatingHue(by: -1 / 360)); return .handled }
                        .onKeyPress(.rightArrow) { edit(palette.rotatingHue(by: 1 / 360)); return .handled }
                        .accessibilityElement()
                        .accessibilityLabel(String(format: NSLocalizedString(
                            "theme.editor.colorHandle", value: "Color %d",
                            comment: "Theme editor - accessible color handle label; placeholder is the color number, from one to three"
                        ), index + 1))
                        .accessibilityValue(colors[index].hexRGBString)
                        .accessibilityAdjustableAction { direction in
                            edit(palette.rotatingHue(by: direction == .increment ? 1 / 360 : -1 / 360))
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
                edit(palette.movingHandle(at: draggedHandle ?? 0, to: CGPoint(
                    x: value.location.x / geometry.size.width, y: value.location.y / geometry.size.height
                ), snappingToCenter: true), preview: true)
            }.onEnded { value in
                let isClick = hypot(value.translation.width, value.translation.height) < 3
                edit(palette.movingHandle(at: isClick ? 0 : (draggedHandle ?? 0), to: CGPoint(
                    x: value.location.x / geometry.size.width, y: value.location.y / geometry.size.height
                ), snappingToCenter: true), animated: isClick)
                draggedHandle = nil
            })
        }
        .frame(width: 244, height: 244)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .anchorPreference(key: ThemeEditorControlBoundsKey.self, value: .bounds) { [$0] }
        .accessibilityIdentifier("theme.editor.palette")
    }

    /// Appends custom palettes after three complete pages of recommendations.
    private var savedPalettes: [ThemePalette] {
        (try? JSONDecoder().decode([ThemePalette].self, from: savedPaletteData)) ?? []
    }

    private var presets: [ThemePalette] { Self.recommendedPalettes + savedPalettes }
    private var pageCount: Int { (presets.count + 6) / 7 }

    // Dusty solids, tonal pairs and balanced accents. These stay inside the
    // dark field's neutral-center branch, avoiding its highly saturated ring.
    private static let recommendedPalettes: [ThemePalette] = [
        ThemePalette(hue: 0.595, saturation: 0.25, brightness: 0.86), // Mist blue
        ThemePalette(hue: 0.375, saturation: 0.23, brightness: 0.80), // Sage
        ThemePalette(hue: 0.105, saturation: 0.22, brightness: 0.90), // Champagne
        ThemePalette(hue: 0.735, saturation: 0.24, brightness: 0.86), // Heather
        ThemePalette(hue: 0.960, saturation: 0.23, brightness: 0.82), // Dusty rose
        ThemePalette(hue: 0.055, saturation: 0.25, brightness: 0.88), // Apricot
        ThemePalette(hue: 0.490, saturation: 0.20, brightness: 0.92), // Sea glass
        ThemePalette(hue: 0.540, saturation: 0.27, brightness: 0.86, harmony: .analogous), // Coast
        ThemePalette(hue: 0.085, saturation: 0.24, brightness: 0.86, harmony: .analogous), // Meadow
        ThemePalette(hue: 0.815, saturation: 0.26, brightness: 0.82, harmony: .analogous), // Orchid
        ThemePalette(hue: 0.360, saturation: 0.25, brightness: 0.80, harmony: .analogous), // Eucalyptus
        ThemePalette(hue: 0.660, saturation: 0.28, brightness: 0.82, harmony: .analogous), // Twilight
        ThemePalette(hue: 0.965, saturation: 0.25, brightness: 0.88, harmony: .analogous), // Peach blossom
        ThemePalette(hue: 0.215, saturation: 0.22, brightness: 0.84, harmony: .analogous), // Olive grove
        ThemePalette(hue: 0.600, saturation: 0.28, brightness: 0.80, harmony: .complementary), // Blue and clay
        ThemePalette(hue: 0.920, saturation: 0.25, brightness: 0.84, harmony: .complementary), // Rose and mint
        ThemePalette(hue: 0.290, saturation: 0.23, brightness: 0.82, harmony: .complementary), // Fern and mauve
        ThemePalette(hue: 0.075, saturation: 0.27, brightness: 0.86, harmony: .splitComplementary), // Dawn
        ThemePalette(hue: 0.720, saturation: 0.26, brightness: 0.80, harmony: .splitComplementary), // Iris garden
        ThemePalette(hue: 0.460, saturation: 0.24, brightness: 0.84, harmony: .splitComplementary), // Tidal pool
        ThemePalette(hue: 0.000, saturation: 0.22, brightness: 0.88, harmony: .splitComplementary) // Porcelain
    ]

    private var presetStrip: some View {
        let availablePresets = presets
        return HStack(spacing: 0) {
            editorButton(asset: "previous", label: NSLocalizedString(
                "theme.editor.previousColors", value: "Previous colors",
                comment: "Theme editor - show the previous group of seven color swatches"
            ), identifier: "theme.editor.previousColors") { changePage(by: -1) }
            ForEach(0..<7, id: \.self) { slot in
                Spacer(minLength: 0)
                let index = presetPage * 7 + slot
                if availablePresets.indices.contains(index) {
                    presetButton(availablePresets[index], at: index)
                } else {
                    Color.clear.frame(width: 24, height: 24)
                }
            }
            Spacer(minLength: 0)
            editorButton(asset: "next", label: NSLocalizedString(
                "theme.editor.nextColors", value: "Next colors",
                comment: "Theme editor - show the next group of seven color swatches"
            ), identifier: "theme.editor.nextColors") { changePage(by: 1) }
        }
        .frame(height: 24)
        .anchorPreference(key: ThemeEditorControlBoundsKey.self, value: .bounds) { [$0] }
        .onChange(of: savedPaletteData) { _, _ in
            presetPage = min(presetPage, pageCount - 1)
            hoveredPreset = nil
            deletablePreset = nil
        }
    }

    private func presetButton(_ preset: ThemePalette, at index: Int) -> some View {
        let selected = preset == palette
        let borderColor = appearance.isDark ? Color.white : Color.black
        let colors = preset.colors(for: appearance).map { $0.withAlphaComponent(1) }
        let gradientColors = colors.count > 1
            ? ColoredVisualEffectView.gradientColors(colors).map { Color(cgColor: $0) }
            : colors.map { Color(nsColor: $0) }
        let label = String(format: NSLocalizedString(
            "theme.editor.presetColor", value: "Color palette %d",
            comment: "Theme editor - accessible swatch label; placeholder is its one-based position"
        ), index + 1)
        let deleteLabel = NSLocalizedString(
            "theme.editor.deleteColor", value: "Delete saved color",
            comment: "Theme editor - remove a user-created palette from the saved swatches"
        )
        return ZStack(alignment: .bottomTrailing) {
            Button {
                uneditedPalette = nil
                update(preset, animated: true)
            } label: {
                ZStack(alignment: .center) {
                    Circle()
                        .fill(LinearGradient(colors: gradientColors, startPoint: .top, endPoint: .bottom))
                        .overlay {
                            Circle().strokeBorder(borderColor.opacity(appearance.isDark ? 0.3 : 0.1), lineWidth: 1)
                        }
                        .frame(width: 18, height: 18)
                    Circle()
                        .strokeBorder(borderColor.opacity(selected ? (appearance.isDark ? 0.3 : 0.18) : 0), lineWidth: 1)
                        .frame(width: 24, height: 24)
                }
                .frame(width: 24, height: 24, alignment: .center)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(label)
            .accessibilityLabel(label)
            .accessibilityIdentifier("theme.editor.preset.\(index)")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityActions {
                if index >= Self.recommendedPalettes.count {
                    Button(deleteLabel) { deletePalette(at: index) }
                }
            }
            if index >= Self.recommendedPalettes.count {
                Button {
                    deletePalette(at: index)
                } label: {
                    Image("theme-editor-remove")
                        .renderingMode(.original)
                        .environment(\.colorScheme, appearance.isDark ? .dark : .light)
                        .frame(width: 10, height: 10)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                // Keep the hit area at the badge's size, outside the swatch
                // center. It only accepts clicks after a deliberate hover.
                .opacity(hoveredPreset == index ? 1 : 0)
                .allowsHitTesting(hoveredPreset == index && deletablePreset == index)
                .offset(x: -0.25, y: 1)
                .help(deleteLabel)
                .accessibilityLabel(deleteLabel)
                .accessibilityIdentifier("theme.editor.deletePreset.\(index)")
            }
        }
        .frame(width: 24, height: 24)
        .contentShape(Rectangle().inset(by: -1))
        .onHover { isHovered in
            if isHovered {
                deletablePreset = nil
                hoveredPreset = index
            } else if hoveredPreset == index {
                hoveredPreset = nil
                deletablePreset = nil
            }
        }
        .task(id: hoveredPreset == index) {
            guard hoveredPreset == index, index >= Self.recommendedPalettes.count else { return }
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            guard !Task.isCancelled, hoveredPreset == index else { return }
            deletablePreset = index
        }
    }

    private func editorButton(asset: String, label: String, identifier: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image("theme-editor-" + asset)
                .rotationEffect(.degrees(asset == "next" ? 180 : 0))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
        .anchorPreference(key: ThemeEditorControlBoundsKey.self, value: .bounds) { [$0] }
    }

    private func changePage(by delta: Int) {
        hoveredPreset = nil
        deletablePreset = nil
        presetPage = (presetPage + delta + pageCount) % pageCount
    }

    private func focusSelectedPreset() {
        if let index = presets.firstIndex(of: palette) { presetPage = index / 7 }
    }

    private func savePalette() {
        let saved = savedPalettes + [palette]
        guard let data = try? JSONEncoder().encode(saved) else { return }
        savedPaletteData = data
        uneditedPalette = nil
        presetPage = (Self.recommendedPalettes.count + saved.count - 1) / 7
        hoveredPreset = nil
        deletablePreset = nil
    }

    private func deletePalette(at index: Int) {
        var saved = savedPalettes
        let savedIndex = index - Self.recommendedPalettes.count
        guard saved.indices.contains(savedIndex) else { return }
        saved.remove(at: savedIndex)
        guard let data = try? JSONEncoder().encode(saved) else { return }
        savedPaletteData = data
        presetPage = min(presetPage, (Self.recommendedPalettes.count + saved.count - 1) / 7)
        hoveredPreset = nil
        deletablePreset = nil
    }

    private func edit(_ newPalette: ThemePalette, animated: Bool = false, preview: Bool = false) {
        if newPalette != palette, uneditedPalette == nil { uneditedPalette = palette }
        if newPalette == uneditedPalette { uneditedPalette = nil }
        update(newPalette, animated: animated, preview: preview)
    }

    private func update(_ newPalette: ThemePalette, animated: Bool = false, preview: Bool = false) {
        guard draftPalette != nil || spaceManager.acceptsStoreAction(from: storeIdentifier) else {
            onDismiss()
            return
        }
        if preview {
            guard newPalette != palette else { return }
            palette = newPalette
            previewThrottle.schedule { publish(newPalette, preview: true) }
            return
        }
        // Land the pending preview first so windows see the same sequence as
        // an unthrottled drag before the commit.
        previewThrottle.flush()
        withAnimation(animated && !reduceMotion ? .timingCurve(0.22, 1, 0.36, 1, duration: 0.3) : nil) {
            palette = newPalette
            publish(newPalette, preview: false)
        }
    }

    private func publish(_ newPalette: ThemePalette, preview: Bool) {
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

    private func syncControls() {
        if let draftPalette {
            // Throttled previews reach the draft up to a frame late; keep the
            // handle on the pointer until the drag ends.
            guard draggedHandle == nil else { return }
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

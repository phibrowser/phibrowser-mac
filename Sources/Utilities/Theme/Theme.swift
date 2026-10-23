// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

/// A semantic color pair for light and dark appearance.
public struct ColorPair: Hashable {
    public let light: NSColor
    public let dark: NSColor
    
    public init(light: NSColor, dark: NSColor) {
        self.light = light
        self.dark = dark
    }
    
    /// Initializes a color pair that uses the same color for both appearances.
    public init(_ color: NSColor) {
        self.light = color
        self.dark = color
    }
    
    /// Resolves the color for a specific appearance.
    public func color(for appearance: Appearance) -> NSColor {
        appearance.isDark ? dark : light
    }
}

enum ThemeDefaults {
    static let overlayLightOpacity: CGFloat = ThemeColorAdjustment.defaultOverlayAlpha
    static let overlayDarkOpacity: CGFloat = ThemeColorAdjustment.defaultOverlayAlpha
}

/// Linear mapping between the slider position (0...100) and saturation
/// (0.1...0.9).
enum OverlaySaturationScale {
    static let minSaturation: Double = 0.1
    static let maxSaturation: Double = 0.9

    static func saturation(forSlider sliderValue: Double) -> Double {
        let clamped = min(max(sliderValue, 0), 100)
        return minSaturation + (maxSaturation - minSaturation) * (clamped / 100)
    }

    static func sliderValue(forSaturation saturation: Double) -> Double {
        let clamped = min(max(saturation, minSaturation), maxSaturation)
        return (clamped - minSaturation) / (maxSaturation - minSaturation) * 100
    }
}

/// Maps the Pure-theme slider from lighter on the left to darker on the
/// right. The light overlay uses 0.94...0.84, the dark overlay uses
/// 0.40...0, and the dark window background uses 0.30...0.20.
enum PureThemeBrightnessScale {
    static func brightnessRange(for appearance: Appearance) -> ClosedRange<Double> {
        appearance.isDark ? 0...0.40 : 0.84...0.94
    }

    static func brightness(forSlider sliderValue: Double, appearance: Appearance) -> Double {
        brightness(forSlider: sliderValue, range: brightnessRange(for: appearance))
    }

    static func darkWindowBackgroundBrightness(forSlider sliderValue: Double) -> Double {
        brightness(forSlider: sliderValue, range: 0.20...0.30)
    }

    static func sliderValue(forBrightness brightness: Double, appearance: Appearance) -> Double {
        let range = brightnessRange(for: appearance)
        let clamped = min(max(brightness, range.lowerBound), range.upperBound)
        return (range.upperBound - clamped) / (range.upperBound - range.lowerBound) * 100
    }

    private static func brightness(
        forSlider sliderValue: Double,
        range: ClosedRange<Double>
    ) -> Double {
        let clamped = min(max(sliderValue, 0), 100)
        return range.upperBound - (range.upperBound - range.lowerBound) * (clamped / 100)
    }
}

struct StoredRGBAColor: Codable, Equatable {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let alpha: CGFloat

    init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(_ color: NSColor) {
        let resolvedColor = color.usingColorSpace(.extendedSRGB) ?? color
        self.init(
            red: resolvedColor.redComponent,
            green: resolvedColor.greenComponent,
            blue: resolvedColor.blueComponent,
            alpha: resolvedColor.alphaComponent
        )
    }

    func asColor() -> NSColor {
        NSColor(red: red, green: green, blue: blue, alpha: alpha)
    }
}

struct StoredColorPair: Codable, Equatable {
    let light: StoredRGBAColor
    let dark: StoredRGBAColor

    init(light: StoredRGBAColor, dark: StoredRGBAColor) {
        self.light = light
        self.dark = dark
    }

    init(_ pair: ColorPair) {
        self.init(light: StoredRGBAColor(pair.light), dark: StoredRGBAColor(pair.dark))
    }

    func asColorPair() -> ColorPair {
        ColorPair(light: light.asColor(), dark: dark.asColor())
    }
}

struct ThemeEditableColors: Codable, Equatable {
    let windowOverlayBackground: StoredColorPair
    let windowBackground: StoredColorPair
    let themeColor: StoredColorPair
    let extensionActonColor: StoredColorPair

    /// Theme-color V2 uses fixed alpha values. Keep alpha in the wire format
    /// for schema compatibility, but normalize previously persisted values
    /// instead of treating them as user customization.
    func standardizingThemeAlpha() -> ThemeEditableColors {
        ThemeEditableColors(
            windowOverlayBackground: StoredColorPair(
                light: StoredRGBAColor(
                    red: windowOverlayBackground.light.red,
                    green: windowOverlayBackground.light.green,
                    blue: windowOverlayBackground.light.blue,
                    alpha: ThemeColorAdjustment.defaultOverlayAlpha
                ),
                dark: StoredRGBAColor(
                    red: windowOverlayBackground.dark.red,
                    green: windowOverlayBackground.dark.green,
                    blue: windowOverlayBackground.dark.blue,
                    alpha: ThemeColorAdjustment.defaultOverlayAlpha
                )
            ),
            windowBackground: StoredColorPair(
                light: StoredRGBAColor(
                    red: windowBackground.light.red,
                    green: windowBackground.light.green,
                    blue: windowBackground.light.blue,
                    alpha: ThemeColorAdjustment.defaultWindowBackgroundAlpha
                ),
                dark: StoredRGBAColor(
                    red: windowBackground.dark.red,
                    green: windowBackground.dark.green,
                    blue: windowBackground.dark.blue,
                    alpha: ThemeColorAdjustment.defaultWindowBackgroundAlpha
                )
            ),
            themeColor: themeColor,
            extensionActonColor: extensionActonColor
        )
    }

}

struct ThemeSnapshot: Codable, Equatable {
    static let version1 = 1
    static let currentVersion = 2

    let version: Int
    let id: String
    let name: String
    let colors: ThemeEditableColors

    init(
        version: Int = Self.currentVersion,
        id: String,
        name: String,
        colors: ThemeEditableColors
    ) {
        self.version = version
        self.id = id
        self.name = name
        self.colors = colors
    }

    /// Restores the editable RGB payload on top of the latest matching theme.
    /// Built-ins keep semantic roles added after the snapshot was written;
    /// unmatched custom themes fall back to the snapshot's own identity.
    /// Persisted overlay/background alpha is normalized to the V2 constants.
    func makeTheme(matching canonicalTheme: Theme? = nil) -> Theme {
        let theme = canonicalTheme?.duplicating() ?? Theme(id: id, name: name)
        theme.applyEditableColors(colors.standardizingThemeAlpha())
        return ThemeColorAdjustment.applyingStandardAlpha(to: theme)
    }

    /// Upgrades a snapshot to the schema's current semantics. Version 1
    /// built-in snapshots may contain stale or experiment-mutated RGB, so
    /// they are rebuilt from the latest canonical theme with the current
    /// default color adjustment. Unmatched IDs are user-defined themes and
    /// keep their RGB payload while adopting the fixed V2 alpha values.
    func migratedToCurrentVersion(matching canonicalTheme: Theme?) -> ThemeSnapshot? {
        switch version {
        case Self.currentVersion:
            return makeTheme(matching: canonicalTheme).makeSnapshot()
        case Self.version1:
            let migratedTheme: Theme
            if let canonicalTheme {
                migratedTheme = ThemeColorAdjustment
                    .applyingDefaultColorComponent(to: canonicalTheme)
            } else {
                migratedTheme = makeTheme()
            }
            return migratedTheme.makeSnapshot()
        default:
            return nil
        }
    }
}

/// A linked color harmony. Dragging any handle preserves its hue relationships.
struct ThemePalette: Codable, Equatable {
    enum Harmony: String, Codable, CaseIterable, Hashable {
        case single
        case analogous
        case complementary
        case splitComplementary

        var colorCount: Int {
            switch self {
            case .single: return 1
            case .analogous, .complementary: return 2
            case .splitComplementary: return 3
            }
        }

        init(colorCount: Int) {
            switch min(max(colorCount, 1), 3) {
            case 1: self = .single
            case 2: self = .complementary
            default: self = .splitComplementary
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version, hue, saturation, brightness, colorCount, harmony
    }

    private let version = 3
    private(set) var hue: Double
    private(set) var saturation: Double
    private(set) var brightness: Double
    private(set) var harmony: Harmony
    var colorCount: Int { harmony.colorCount }

    init(hue: Double, saturation: Double, brightness: Double = 1, colorCount: Int = 1) {
        self.init(hue: hue, saturation: saturation, brightness: brightness, harmony: Harmony(colorCount: colorCount))
    }

    init(hue: Double, saturation: Double, brightness: Double = 1, harmony: Harmony) {
        self.hue = Self.wrappedHue(hue)
        self.saturation = Self.unit(saturation)
        self.brightness = Self.unit(brightness)
        self.harmony = harmony
    }

    init(color: NSColor, appearance: Appearance) {
        let color = color.usingColorSpace(.sRGB) ?? .white
        let lower = appearance.isDark ? 0.12 : 0.65
        let saturation: Double
        if appearance.isDark {
            let colorSaturation = min(Double(color.saturationComponent), Self.darkInnerSaturation)
            // Invert the squared smoothstep used by the inner field.
            let innerMix = sqrt(colorSaturation / Self.darkInnerSaturation)
            let innerRadius = Self.darkInnerRadius * (0.5 - sin(asin(1 - 2 * innerMix) / 3))
            let outerRadius = Self.unit(Self.darkInnerRadius + (1 - Self.darkInnerRadius)
                * sqrt((Self.darkInnerSaturation - colorSaturation) / (Self.darkInnerSaturation - Self.darkOuterSaturation)))
            // Two radii can share a saturation. Prefer the outer one when it can
            // represent the input brightness; otherwise use the neutral-center branch.
            saturation = colorSaturation >= Self.darkOuterSaturation - 0.000001
                && Double(color.brightnessComponent) <= 0.36 + 0.54 * outerRadius + 0.000001
                ? outerRadius : innerRadius
        } else {
            saturation = Self.unit(Double(color.saturationComponent) / 0.52)
        }
        let span = appearance.isDark ? 0.24 + 0.54 * saturation : 0.35
        self.init(
            hue: Double(color.hueComponent),
            saturation: saturation,
            brightness: (Double(color.brightnessComponent) - lower) / span
        )
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let storedVersion = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        let storedColorCount = try values.decode(Int.self, forKey: .colorCount)
        let storedHarmony = try values.decodeIfPresent(String.self, forKey: .harmony)
        let harmony = storedHarmony.flatMap(Harmony.init(rawValue:))
            ?? Harmony(colorCount: storedColorCount)
        self.init(
            hue: try values.decode(Double.self, forKey: .hue),
            saturation: try values.decode(Double.self, forKey: .saturation),
            // The removed editor slider finishes at its rightmost endpoint.
            // Upgrade older saved palettes before any window resolves them.
            brightness: storedVersion < 2 ? 1 : try values.decode(Double.self, forKey: .brightness),
            harmony: harmony
        )
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encode(hue, forKey: .hue)
        try values.encode(saturation, forKey: .saturation)
        try values.encode(brightness, forKey: .brightness)
        try values.encode(colorCount, forKey: .colorCount)
        try values.encode(harmony, forKey: .harmony)
    }

    func hue(at index: Int) -> Double {
        Self.wrappedHue(hue + hueOffset(at: index))
    }

    private func hueOffset(at index: Int) -> Double {
        switch harmony {
        case .single: return 0
        case .analogous: return Double(index) * 45 / 360
        case .complementary: return Double(index) / 2
        case .splitComplementary:
            switch index {
            case 1: return 150 / 360
            case 2: return 210 / 360
            default: return 0
            }
        }
    }

    func colors(for appearance: Appearance) -> [NSColor] {
        (0..<colorCount).map { resolvedColor(hue: hue(at: $0), appearance: appearance) }
    }

    /// Samples the field with the same coordinate mapping and color resolution
    /// used by the handles. Presentation can make this opaque without changing RGB.
    func color(at point: CGPoint, appearance: Appearance) -> NSColor {
        let sample = movingHandle(at: 0, to: point)
        return sample.resolvedColor(hue: sample.hue, appearance: appearance)
    }

    private static let darkInnerRadius = 0.4
    private static let darkInnerSaturation = 0.9
    private static let darkOuterSaturation = 0.45

    private var darkSaturation: Double {
        if saturation <= Self.darkInnerRadius {
            let progress = saturation / Self.darkInnerRadius
            let smooth = progress * progress * (3 - 2 * progress)
            return Self.darkInnerSaturation * smooth * smooth
        }
        let progress = (saturation - Self.darkInnerRadius) / (1 - Self.darkInnerRadius)
        return Self.darkInnerSaturation
            - (Self.darkInnerSaturation - Self.darkOuterSaturation) * progress * progress
    }

    private func resolvedColor(hue: Double, appearance: Appearance) -> NSColor {
        NSColor(
            hue: CGFloat(hue),
            saturation: CGFloat(appearance.isDark ? darkSaturation : saturation * 0.52),
            brightness: CGFloat(appearance.isDark
                ? 0.12 + brightness * (0.24 + saturation * 0.54)
                : 0.65 + brightness * 0.35),
            alpha: ThemeColorAdjustment.defaultOverlayAlpha
        )
    }

    func settingColorCount(_ count: Int) -> ThemePalette {
        settingHarmony(Harmony(colorCount: count))
    }

    func settingHarmony(_ value: Harmony) -> ThemePalette {
        ThemePalette(hue: hue, saturation: saturation, brightness: brightness, harmony: value)
    }

    func settingBrightness(_ value: Double) -> ThemePalette {
        ThemePalette(hue: hue, saturation: saturation, brightness: value, harmony: harmony)
    }

    /// The supplied Figma field has nonuniform angular color stops. Map hue
    /// through those same stops so the handles track the displayed spectrum.
    private static let spectrumHues: [Double] = [0, 1.0 / 12, 1.0 / 6, 1.0 / 3, 0.5, 2.0 / 3, 5.0 / 6, 1]
    private static let spectrumAngles: [Double] = [0, 0.149, 0.332, 0.486, 0.620, 0.784, 0.880, 1]
    private static let fieldRadius = 0.42

    func handlePosition(at index: Int) -> CGPoint {
        let angle = Self.interpolate(hue(at: index), from: Self.spectrumHues, to: Self.spectrumAngles) * 2 * .pi - .pi / 4
        let radius = saturation * Self.fieldRadius
        return CGPoint(x: 0.5 + cos(angle) * radius, y: 0.5 + sin(angle) * radius)
    }

    func movingHandle(at index: Int, to point: CGPoint, snappingToCenter: Bool = false) -> ThemePalette {
        let x = Double(point.x) - 0.5
        let y = Double(point.y) - 0.5
        let radius = hypot(x, y)
        // Interaction snaps within about 6 points in the 244-point field.
        // Color sampling keeps the continuous mapping by leaving this disabled.
        if snappingToCenter, radius <= 0.025 {
            return ThemePalette(hue: hue, saturation: 0, brightness: brightness, harmony: harmony)
        }
        // Retain the hue at the white center, where angle is undefined.
        let angle = Self.wrappedHue((atan2(y, x) + .pi / 4) / (2 * .pi))
        let movedHue = radius < 0.0001 ? hue(at: index)
            : Self.interpolate(angle, from: Self.spectrumAngles, to: Self.spectrumHues)
        return ThemePalette(
            hue: movedHue - hueOffset(at: index),
            saturation: radius / Self.fieldRadius,
            brightness: brightness,
            harmony: harmony
        )
    }

    func rotatingHue(by delta: Double) -> ThemePalette {
        ThemePalette(hue: hue + delta, saturation: saturation, brightness: brightness, harmony: harmony)
    }

    private static func interpolate(_ value: Double, from source: [Double], to target: [Double]) -> Double {
        let index = (1..<source.count).first { value <= source[$0] } ?? source.count - 1
        let fraction = (value - source[index - 1]) / (source[index] - source[index - 1])
        return target[index - 1] + fraction * (target[index] - target[index - 1])
    }

    private static func wrappedHue(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return value - floor(value)
    }

    private static func unit(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0
    }

    func applying(to base: Theme) -> Theme {
        let theme = base.duplicating()
        theme.navigationPalette = self
        let light = colors(for: .light)[0]
        let dark = colors(for: .dark)[0]
        let lightAccent = NSColor(hue: CGFloat(hue), saturation: 0.65, brightness: 0.6, alpha: 1)
        let darkAccent = NSColor(hue: CGFloat(hue), saturation: 0.5, brightness: 0.85, alpha: 1)
        theme.setColor(light: light, dark: dark, for: .windowOverlayBackground)
        theme.setColor(light: lightAccent, dark: darkAccent, for: .themeColor)
        theme.setColor(light: lightAccent.adjustingBrightness(percent: -5), dark: darkAccent.adjustingBrightness(percent: 5), for: .themeColorOnHover)
        return theme
    }
}

/// Theme definition backed by semantic color roles.
public class Theme: NSObject {
    /// Shared by native internal-page chrome and extension NTP/Chat surfaces.
    /// WindowThemeMessageRouter forwards this value to extension CSS.
    static let extensionSurfaceScrimOpacity: CGFloat = 0.80

    func extensionSurfaceBackground(for appearance: Appearance) -> NSColor {
        guard appearance.isDark else { return .white }
        guard let primary = color(for: .windowOverlayBackground, appearance: appearance)
            .usingColorSpace(.sRGB) else { return .black }
        let visible = 1 - Self.extensionSurfaceScrimOpacity
        return NSColor(
            srgbRed: primary.redComponent * visible,
            green: primary.greenComponent * visible,
            blue: primary.blueComponent * visible,
            alpha: 1
        )
    }

    public let id: String
    public let name: String
    private var colorPalette: [ColorRole: ColorPair]
    var navigationPalette: ThemePalette?
    
    public init(id: String, name: String, colorPalette: [ColorRole: ColorPair] = [:]) {
        self.id = id
        self.name = name
        self.colorPalette = colorPalette
        super.init()
    }
    
    /// Resolves a color for the given role and appearance.
    public func color(for role: ColorRole, appearance: Appearance) -> NSColor {
        colorPair(for: role).color(for: appearance)
    }

    public func colorPair(for role: ColorRole) -> ColorPair {
        let pair = colorPalette[role] ?? DefaultColors.colorPair(for: role)
        switch role {
        case .windowOverlayBackground:
            return ColorPair(
                light: pair.light.withAlphaComponent(
                    ThemeColorAdjustment.defaultOverlayAlpha
                ),
                dark: pair.dark.withAlphaComponent(
                    ThemeColorAdjustment.defaultOverlayAlpha
                )
            )
        case .windowBackground:
            return ColorPair(
                light: pair.light.withAlphaComponent(
                    ThemeColorAdjustment.defaultWindowBackgroundAlpha
                ),
                dark: pair.dark.withAlphaComponent(
                    ThemeColorAdjustment.defaultWindowBackgroundAlpha
                )
            )
        default:
            return pair
        }
    }
    
    /// Sets the color pair for a semantic role.
    public func setColor(_ pair: ColorPair, for role: ColorRole) {
        colorPalette[role] = pair
    }
    
    /// Sets light and dark colors for a semantic role.
    public func setColor(light: NSColor, dark: NSColor, for role: ColorRole) {
        colorPalette[role] = ColorPair(light: light, dark: dark)
    }

    /// Full palette copy carrying the same id/name. Used to derive per-window
    /// color-component variants without mutating the registered instance. Not
    /// a snapshot round-trip: `makeSnapshot()` only carries the four editable
    /// roles, which would drop the rest of a built-in theme's palette.
    public func duplicating() -> Theme {
        let copy = Theme(id: id, name: name, colorPalette: colorPalette)
        copy.navigationPalette = navigationPalette
        return copy
    }

    public func windowOverlayOpacity(for appearance: Appearance) -> CGFloat {
        color(for: .windowOverlayBackground, appearance: appearance).alphaComponent
    }

    @available(*, deprecated, message: "Theme overlay alpha is fixed by ThemeColorAdjustment in ThemeSnapshot V2.")
    public func setWindowOverlayOpacity(_ opacity: CGFloat, for appearance: Appearance) {
        _ = opacity
        let existingPair = colorPair(for: .windowOverlayBackground)

        switch appearance {
        case .light:
            setColor(
                light: existingPair.light,
                dark: existingPair.dark,
                for: .windowOverlayBackground
            )
        case .dark:
            setColor(
                light: existingPair.light,
                dark: existingPair.dark,
                for: .windowOverlayBackground
            )
        }
    }

    func makeSnapshot() -> ThemeSnapshot {
        let standardizedTheme = ThemeColorAdjustment.applyingStandardAlpha(to: self)
        return ThemeSnapshot(
            id: id,
            name: name,
            colors: ThemeEditableColors(
                windowOverlayBackground: StoredColorPair(
                    standardizedTheme.colorPair(for: .windowOverlayBackground)
                ),
                windowBackground: StoredColorPair(
                    standardizedTheme.colorPair(for: .windowBackground)
                ),
                themeColor: StoredColorPair(standardizedTheme.colorPair(for: .themeColor)),
                extensionActonColor: StoredColorPair(
                    standardizedTheme.colorPair(for: .extensionActonColor)
                )
            )
        )
    }

    func applyEditableColors(_ editableColors: ThemeEditableColors) {
        setColor(editableColors.windowOverlayBackground.asColorPair(), for: .windowOverlayBackground)
        setColor(editableColors.windowBackground.asColorPair(), for: .windowBackground)

        let themeColorPair = editableColors.themeColor.asColorPair()
        setColor(themeColorPair, for: .themeColor)
        setColor(editableColors.extensionActonColor.asColorPair(), for: .extensionActonColor)
        setColor(
            light: themeColorPair.light.adjustingBrightness(percent: -5),
            dark: themeColorPair.dark.adjustingBrightness(percent: 5),
            for: .themeColorOnHover
        )
    }
    
    // MARK: - Hashable
    
    public override var hash: Int {
        id.hashValue
    }
    
    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Theme else { return false }
        return id == other.id
    }
}

/// Applies the user-adjustable overlay color components without mutating the
/// registered base theme. Snapshot migration and per-Space resolution share
/// these formulas so persisted and live themes cannot drift apart.
enum ThemeColorAdjustment {
    static let defaultOverlayAlpha: CGFloat = 0.8
    static let defaultWindowBackgroundAlpha: CGFloat = 1
    static let defaultSaturation: CGFloat = 0.40
    static let defaultPureSliderValue: Double = 50

    /// Returns a palette copy with the fixed V2 alpha contract applied:
    /// overlay colors are always 0.8 and window backgrounds are always 1.0.
    static func applyingStandardAlpha(to base: Theme) -> Theme {
        let derived = base.duplicating()
        let overlayPair = derived.colorPair(for: .windowOverlayBackground)
        derived.setColor(
            light: overlayPair.light.withAlphaComponent(defaultOverlayAlpha),
            dark: overlayPair.dark.withAlphaComponent(defaultOverlayAlpha),
            for: .windowOverlayBackground
        )

        let windowBackgroundPair = derived.colorPair(for: .windowBackground)
        derived.setColor(
            light: windowBackgroundPair.light.withAlphaComponent(defaultWindowBackgroundAlpha),
            dark: windowBackgroundPair.dark.withAlphaComponent(defaultWindowBackgroundAlpha),
            for: .windowBackground
        )
        return derived
    }

    static func applyingSaturation(
        light: CGFloat?,
        dark: CGFloat?,
        darkWindowBackground: CGFloat?,
        to base: Theme
    ) -> Theme {
        let derived = applyingStandardAlpha(to: base)
        guard light != nil || dark != nil || darkWindowBackground != nil else {
            return derived
        }

        let overlayPair = derived.colorPair(for: .windowOverlayBackground)
        derived.setColor(
            light: light.map {
                overlayPair.light.withHSBSaturation(
                    $0,
                    alpha: defaultOverlayAlpha
                )
            } ?? overlayPair.light,
            dark: dark.map {
                overlayPair.dark.withHSBSaturation(
                    $0,
                    alpha: defaultOverlayAlpha
                )
            } ?? overlayPair.dark,
            for: .windowOverlayBackground
        )

        if let darkWindowBackground {
            let windowBackgroundPair = derived.colorPair(for: .windowBackground)
            derived.setColor(
                light: windowBackgroundPair.light,
                dark: windowBackgroundPair.dark.withHSBSaturation(
                    darkWindowBackground,
                    alpha: defaultWindowBackgroundAlpha
                ),
                for: .windowBackground
            )
        }
        return derived
    }

    static func applyingPureBrightness(
        sliderValue: Double,
        to base: Theme
    ) -> Theme {
        let lightBrightness = CGFloat(
            PureThemeBrightnessScale.brightness(
                forSlider: sliderValue,
                appearance: .light
            )
        )
        let darkBrightness = CGFloat(
            PureThemeBrightnessScale.brightness(
                forSlider: sliderValue,
                appearance: .dark
            )
        )
        let darkWindowBackgroundBrightness = CGFloat(
            PureThemeBrightnessScale.darkWindowBackgroundBrightness(
                forSlider: sliderValue
            )
        )

        let derived = applyingStandardAlpha(to: base)
        let overlayPair = derived.colorPair(for: .windowOverlayBackground)
        derived.setColor(
            light: overlayPair.light.withHSBBrightness(
                lightBrightness,
                alpha: defaultOverlayAlpha
            ),
            dark: overlayPair.dark.withHSBBrightness(
                darkBrightness,
                alpha: defaultOverlayAlpha
            ),
            for: .windowOverlayBackground
        )

        let windowBackgroundPair = derived.colorPair(for: .windowBackground)
        derived.setColor(
            light: windowBackgroundPair.light,
            dark: windowBackgroundPair.dark.withHSBBrightness(
                darkWindowBackgroundBrightness,
                alpha: defaultWindowBackgroundAlpha
            ),
            for: .windowBackground
        )
        return derived
    }

    static func applyingDefaultColorComponent(to canonicalTheme: Theme) -> Theme {
        if canonicalTheme.id == Theme.pure.id {
            return applyingPureBrightness(
                sliderValue: defaultPureSliderValue,
                to: canonicalTheme
            )
        }
        return applyingSaturation(
            light: defaultSaturation,
            dark: defaultSaturation,
            darkWindowBackground: defaultSaturation,
            to: canonicalTheme
        )
    }
}

// MARK: - Default Theme

public extension Theme {
    /// Default built-in theme.
    static let `default` = Theme.pure
}

extension NSColor {
    var hsbSaturationComponent: CGFloat {
        let color = usingColorSpace(.extendedSRGB) ?? self
        var saturation: CGFloat = 0
        color.getHue(nil, saturation: &saturation, brightness: nil, alpha: nil)
        return saturation
    }

    var hsbBrightnessComponent: CGFloat {
        let color = usingColorSpace(.extendedSRGB) ?? self
        var brightness: CGFloat = 0
        color.getHue(nil, saturation: nil, brightness: &brightness, alpha: nil)
        return brightness
    }

    func withHSBSaturation(_ saturation: CGFloat, alpha: CGFloat) -> NSColor {
        let color = usingColorSpace(.extendedSRGB) ?? self
        var hue: CGFloat = 0
        var brightness: CGFloat = 0
        color.getHue(&hue, saturation: nil, brightness: &brightness, alpha: nil)
        return NSColor(
            colorSpace: .extendedSRGB,
            hue: hue,
            saturation: min(max(saturation, 0), 1),
            brightness: brightness,
            alpha: min(max(alpha, 0), 1)
        )
    }

    func withHSBBrightness(_ brightness: CGFloat, alpha: CGFloat) -> NSColor {
        let color = usingColorSpace(.extendedSRGB) ?? self
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: nil, alpha: nil)
        return NSColor(
            colorSpace: .extendedSRGB,
            hue: hue,
            saturation: saturation,
            brightness: min(max(brightness, 0), 1),
            alpha: min(max(alpha, 0), 1)
        )
    }

    func adjustingBrightness(percent delta: CGFloat) -> NSColor {
        let color = usingColorSpace(.extendedSRGB) ?? self
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let adjustedBrightness = min(max(brightness + (delta / 100), 0), 1)
        return NSColor(calibratedHue: hue, saturation: saturation, brightness: adjustedBrightness, alpha: alpha)
    }
}

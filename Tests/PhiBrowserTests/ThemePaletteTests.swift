// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

@MainActor
final class ThemePaletteTests: XCTestCase {
    func testCenterSnapCentersEveryLinkedHandleAndPreservesPaletteSettings() {
        for harmony in ThemePalette.Harmony.allCases {
            let count = harmony.colorCount
            let original = ThemePalette(hue: 0.73, saturation: 0.8, brightness: 0.4, harmony: harmony)
            for draggedIndex in 0..<count {
                for point in [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.524, y: 0.5), CGPoint(x: 0.49, y: 0.51)] {
                    let snapped = original.movingHandle(at: draggedIndex, to: point, snappingToCenter: true)
                    XCTAssertEqual(snapped.hue, original.hue)
                    XCTAssertEqual(snapped.colorCount, count)
                    XCTAssertEqual(snapped.harmony, harmony)
                    XCTAssertEqual(snapped.brightness, original.brightness)
                    XCTAssertEqual(snapped.saturation, 0)
                    for index in 0..<count {
                        XCTAssertEqual(snapped.handlePosition(at: index), CGPoint(x: 0.5, y: 0.5))
                    }
                }
            }
        }
    }

    func testCenterSnapIsSmallCircularAndDoesNotFlattenColorSampling() {
        let original = ThemePalette(hue: 0.4, saturation: 0.7, colorCount: 3)
        for point in [CGPoint(x: 0.526, y: 0.5), CGPoint(x: 0.524, y: 0.524)] {
            let moved = original.movingHandle(at: 1, to: point, snappingToCenter: true)
            XCTAssertGreaterThan(moved.saturation, 0)
            XCTAssertEqual(moved, original.movingHandle(at: 1, to: point))
            XCTAssertEqual(moved.handlePosition(at: 1).x, point.x, accuracy: 0.000001)
            XCTAssertEqual(moved.handlePosition(at: 1).y, point.y, accuracy: 0.000001)
        }
        let nearCenter = CGPoint(x: 0.51, y: 0.5)
        XCTAssertEqual(original.movingHandle(at: 0, to: nearCenter, snappingToCenter: true).saturation, 0)
        XCTAssertGreaterThan(original.movingHandle(at: 0, to: nearCenter).saturation, 0)
        XCTAssertGreaterThan(original.color(at: nearCenter, appearance: .light).saturationComponent, 0,
                             "Rendering must remain continuous inside the interaction snap radius.")
        let centered = original.movingHandle(at: 2, to: nearCenter, snappingToCenter: true)
        let destination = CGPoint(x: 0.7, y: 0.4)
        XCTAssertEqual(centered.movingHandle(at: 2, to: destination, snappingToCenter: true),
                       original.movingHandle(at: 2, to: destination),
                       "Dragging beyond the snap radius must resume normal linked tracking.")
    }

    func testColorCountBoundsAndHarmony() {
        let palette = ThemePalette(hue: 0.9, saturation: 0.6)
        XCTAssertEqual(palette.settingColorCount(0).colorCount, 1)
        XCTAssertEqual(palette.settingColorCount(4).colorCount, 3)
        let complementary = palette.settingColorCount(2)
        XCTAssertEqual(complementary.hue(at: 1), 0.4, accuracy: 0.000001)
        let splitComplementary = palette.settingColorCount(3)
        XCTAssertEqual(splitComplementary.hue(at: 0), palette.hue)
        XCTAssertEqual(splitComplementary.hue(at: 1), 0.3166666667, accuracy: 0.000001)
        XCTAssertEqual(splitComplementary.hue(at: 2), 0.4833333333, accuracy: 0.000001)
    }

    func testSplitComplementaryNeighborsWrapAcrossTheHueBoundary() {
        let nearCyan = ThemePalette(hue: 0.52, saturation: 0.8, colorCount: 3)
        XCTAssertEqual(nearCyan.hue(at: 1), 0.9366666667, accuracy: 0.000001)
        XCTAssertEqual(nearCyan.hue(at: 2), 0.1033333333, accuracy: 0.000001)
        let distance = (nearCyan.hue(at: 2) - nearCyan.hue(at: 1) + 1)
            .truncatingRemainder(dividingBy: 1)
        XCTAssertEqual(distance, 60 / 360, accuracy: 0.000001)
    }

    func testDraggingAnyHandleMovesEntireHarmonyToThePointer() {
        for harmony in ThemePalette.Harmony.allCases {
            let count = harmony.colorCount
            for index in 0..<count {
                let original = ThemePalette(hue: 0.93, saturation: 0.5, harmony: harmony)
                let destination = ThemePalette(hue: 0.08, saturation: 0.8, harmony: harmony)
                let pointer = destination.handlePosition(at: index)
                let moved = original.movingHandle(at: index, to: pointer)
                XCTAssertEqual(moved.hue, destination.hue, accuracy: 0.000001)
                XCTAssertEqual(moved.saturation, destination.saturation, accuracy: 0.000001)
                XCTAssertEqual(moved.brightness, original.brightness)
                XCTAssertEqual(moved.harmony, harmony)
                for other in 0..<count {
                    XCTAssertEqual(moved.hue(at: other), destination.hue(at: other), accuracy: 0.000001)
                    XCTAssertEqual(moved.handlePosition(at: other).x, destination.handlePosition(at: other).x, accuracy: 0.000001)
                    XCTAssertEqual(moved.handlePosition(at: other).y, destination.handlePosition(at: other).y, accuracy: 0.000001)
                }
            }
        }
    }

    func testAnalogousColorsStayFortyFiveDegreesApartAcrossTheHueBoundary() {
        let palette = ThemePalette(hue: 0.96, saturation: 0.65, brightness: 0.4, harmony: .analogous)
        XCTAssertEqual(palette.colorCount, 2)
        XCTAssertEqual(palette.hue(at: 0), 0.96, accuracy: 0.000001)
        XCTAssertEqual(palette.hue(at: 1), 0.085, accuracy: 0.000001)
        XCTAssertEqual(palette.rotatingHue(by: 0.1).harmony, .analogous)
        XCTAssertEqual(palette.settingBrightness(0.8).harmony, .analogous)
        for harmony in ThemePalette.Harmony.allCases {
            let switched = palette.settingHarmony(harmony)
            XCTAssertEqual(switched.hue, palette.hue)
            XCTAssertEqual(switched.saturation, palette.saturation)
            XCTAssertEqual(switched.brightness, palette.brightness)
            XCTAssertEqual(switched.harmony, harmony)
        }
    }

    func testEveryHarmonySurvivesEncodingAndLegacyCountsKeepTheirMeaning() throws {
        for harmony in ThemePalette.Harmony.allCases {
            let palette = ThemePalette(hue: 0.7, saturation: 0.45, brightness: 0.6, harmony: harmony)
            let encoded = try JSONEncoder().encode(palette)
            XCTAssertEqual(try JSONDecoder().decode(ThemePalette.self, from: encoded), palette)
        }
        for (count, harmony) in [(1, ThemePalette.Harmony.single), (2, .complementary), (3, .splitComplementary)] {
            let old = Data("{\"version\":2,\"hue\":0.4,\"saturation\":0.6,\"brightness\":0.7,\"colorCount\":\(count)}".utf8)
            let decoded = try JSONDecoder().decode(ThemePalette.self, from: old)
            XCTAssertEqual(decoded.harmony, harmony)
            XCTAssertEqual(decoded.brightness, 0.7)
        }
        let unknown = Data(#"{"version":3,"hue":0.4,"saturation":0.6,"brightness":0.7,"colorCount":2,"harmony":"unknown"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(ThemePalette.self, from: unknown).harmony, .complementary)
    }

    func testFieldCenterAndOutsideDragsAreStable() {
        let palette = ThemePalette(hue: 0.7, saturation: 0.5, colorCount: 3)
        let center = palette.movingHandle(at: 2, to: CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(center.hue, palette.hue, accuracy: 0.000001)
        XCTAssertEqual(center.saturation, 0)
        let outside = palette.movingHandle(at: 1, to: CGPoint(x: -10, y: 20))
        XCTAssertEqual(outside.saturation, 1)
        for index in 0..<3 {
            let point = outside.handlePosition(at: index)
            XCTAssertTrue((0...1).contains(point.x))
            XCTAssertTrue((0...1).contains(point.y))
        }
    }

    func testPaletteSurvivesAccountPreferenceReloadWithoutChangingOtherSpaces() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("defaults.plist")
        let account = Account(userID: UUID().uuidString)
        let preferences = AccountUserDefaults(account: account, storeURL: url)
        let first = ThemePalette(hue: 0.95, saturation: 0.65, brightness: 0.4, colorCount: 3)
        let second = ThemePalette(hue: 0.3, saturation: 0.2, brightness: 0.8, harmony: .analogous)
        XCTAssertTrue(preferences.setSpaceThemePalettes(["first": first, "second": second]))
        let reloaded = AccountUserDefaults(account: account, storeURL: url)
        XCTAssertEqual(reloaded.spaceThemePalettes(), ["first": first, "second": second])
        var palettes = reloaded.spaceThemePalettes()
        palettes["first"] = first.rotatingHue(by: 0.2)
        XCTAssertTrue(reloaded.setSpaceThemePalettes(palettes))
        XCTAssertEqual(reloaded.spaceThemePalettes()["second"], second)
        XCTAssertTrue(reloaded.spaceThemeIds().isEmpty)
    }

    func testDerivedPalettePreservesBaseAndWindowContextCopies() {
        let base = Theme(id: "palette-base", name: "Palette base")
        base.setColor(ColorPair(.red), for: .windowOverlayBackground)
        let palette = ThemePalette(hue: 0.2, saturation: 0.7, colorCount: 3)
        let derived = palette.applying(to: base)
        XCTAssertNil(base.navigationPalette)
        XCTAssertEqual(base.color(for: .windowOverlayBackground, appearance: .light).redComponent, 1)
        XCTAssertEqual(ThemeColorAdjustment.applyingStandardAlpha(to: derived).navigationPalette, palette)
        for appearance in [Appearance.light, .dark] {
            XCTAssertEqual(palette.colors(for: appearance).count, 3)
            XCTAssertEqual(derived.windowOverlayOpacity(for: appearance), 0.8)
            XCTAssertEqual(derived.color(for: .windowBackground, appearance: appearance).alphaComponent, 1)
            XCTAssertEqual(derived.color(for: .windowBackground, appearance: appearance),
                           base.color(for: .windowBackground, appearance: appearance),
                           "Navigation palettes must not tint ordinary page fallback backgrounds.")
        }
    }

    func testDecodedPaletteClampsInvalidCountAndComponents() throws {
        let data = Data(#"{"version":2,"hue":-0.2,"saturation":2,"brightness":-1,"colorCount":100}"#.utf8)
        let palette = try JSONDecoder().decode(ThemePalette.self, from: data)
        XCTAssertEqual(palette.hue, 0.8, accuracy: 0.000001)
        XCTAssertEqual(palette.saturation, 1)
        XCTAssertEqual(palette.brightness, 0)
        XCTAssertEqual(palette.colorCount, 3)
    }

    func testRemovedBrightnessSliderMigratesLegacyPalettesToItsRightEndpoint() throws {
        let legacy = Data(#"{"hue":0.3,"saturation":0.7,"brightness":0.2,"colorCount":3}"#.utf8)
        let palette = try JSONDecoder().decode(ThemePalette.self, from: legacy)
        XCTAssertEqual(palette.brightness, 1)
        XCTAssertEqual(palette.hue, 0.3)
        XCTAssertEqual(palette.saturation, 0.7)
        XCTAssertEqual(palette.colorCount, 3)
        let encoded = try JSONEncoder().encode(palette)
        XCTAssertEqual(try JSONDecoder().decode(ThemePalette.self, from: encoded), palette)
        XCTAssertEqual(ThemePalette(hue: 0.3, saturation: 0.7).brightness, 1)
    }

    func testDarkOuterColorsAreBrighterAndMoreDistinctThanTheCenter() {
        let center = ThemePalette(hue: 0.6, saturation: 0).colors(for: .dark)[0]
        let edge = ThemePalette(hue: 0.6, saturation: 1).colors(for: .dark)[0]
        XCTAssertGreaterThan(edge.brightnessComponent - center.brightnessComponent, 0.2)
        XCTAssertGreaterThan(edge.saturationComponent, center.saturationComponent)
        let lightEdge = ThemePalette(hue: 0.6, saturation: 1).colors(for: .light)[0]
        XCTAssertEqual(edge.saturationComponent, 0.45, accuracy: 0.000001)
        XCTAssertEqual(lightEdge.saturationComponent, 0.52, accuracy: 0.000001)
        XCTAssertEqual(center.brightnessComponent, 0.36, accuracy: 0.000001)
        XCTAssertEqual(edge.brightnessComponent, 0.9, accuracy: 0.000001)
        XCTAssertEqual(edge.alphaComponent, center.alphaComponent)
    }

    func testDarkSaturationPeaksInsideAndFadesTowardTheBrighterEdge() {
        let radii = [0.0, 0.1, 0.2, 0.4, 0.6, 0.8, 1.0]
        let colors = radii.map { ThemePalette(hue: 0.6, saturation: $0).colors(for: .dark)[0] }
        XCTAssertEqual(colors[0].saturationComponent, 0, accuracy: 0.000001)
        XCTAssertEqual(colors[3].saturationComponent, 0.9, accuracy: 0.000001)
        XCTAssertEqual(colors[2].saturationComponent, 0.225, accuracy: 0.000001,
                       "The inner half of the transition must offer muted colors away from the center.")
        for index in 1..<colors.count {
            XCTAssertGreaterThan(colors[index].brightnessComponent, colors[index - 1].brightnessComponent)
            if index <= 3 {
                XCTAssertGreaterThan(colors[index].saturationComponent, colors[index - 1].saturationComponent)
            } else {
                XCTAssertLessThan(colors[index].saturationComponent, colors[index - 1].saturationComponent)
            }
        }
        for color in colors {
            let restored = ThemePalette(color: color, appearance: .dark).colors(for: .dark)[0]
            XCTAssertEqual(restored.redComponent, color.redComponent, accuracy: 0.000001)
            XCTAssertEqual(restored.greenComponent, color.greenComponent, accuracy: 0.000001)
            XCTAssertEqual(restored.blueComponent, color.blueComponent, accuracy: 0.000001)
        }
    }

    func testDarkInnerTransitionOffersMutedColorsAwayFromTheCenter() {
        for hue in [0.0, 0.17, 0.33, 0.5, 0.67, 0.83] {
            for radius in [0.1, 0.2] {
                let color = ThemePalette(hue: hue, saturation: radius).colors(for: .dark)[0]
                XCTAssertLessThanOrEqual(color.saturationComponent, radius == 0.1 ? 0.05 : 0.25)
                XCTAssertLessThan(color.brightnessComponent, 0.5)
                let restored = ThemePalette(color: color, appearance: .dark).colors(for: .dark)[0]
                XCTAssertEqual(restored.redComponent, color.redComponent, accuracy: 0.000001)
                XCTAssertEqual(restored.greenComponent, color.greenComponent, accuracy: 0.000001)
                XCTAssertEqual(restored.blueComponent, color.blueComponent, accuracy: 0.000001)
            }
        }
    }

    func testFieldSamplesMatchEveryLinkedHandleColor() throws {
        for brightness in [0.0, 0.35, 1.0] {
            for saturation in [0.0, 0.02, 0.5, 1.0] {
                for step in 0..<24 {
                    let palette = ThemePalette(
                        hue: Double(step) / 24, saturation: saturation,
                        brightness: brightness, colorCount: 3
                    )
                    for appearance in [Appearance.light, .dark] {
                        for (index, handle) in palette.colors(for: appearance).enumerated() {
                            let field = try XCTUnwrap(palette.color(
                                at: palette.handlePosition(at: index), appearance: appearance
                            ).usingColorSpace(.sRGB))
                            let expected = try XCTUnwrap(handle.usingColorSpace(.sRGB))
                            XCTAssertEqual(field.redComponent, expected.redComponent, accuracy: 0.000001)
                            XCTAssertEqual(field.greenComponent, expected.greenComponent, accuracy: 0.000001)
                            XCTAssertEqual(field.blueComponent, expected.blueComponent, accuracy: 0.000001)
                        }
                    }
                }
            }
        }
    }

    func testRenderedFieldsAreOpaqueAndSoftenedWithoutLosingHueDirection() throws {
        let size = 128
        for appearance in [Appearance.light, .dark] {
            var previousBrightness: [Int: CGFloat] = [:]
            for brightness in [0.0, 0.4, 1.0] {
                let image = try XCTUnwrap(ThemeEditorPaletteRenderer.image(brightness: brightness, appearance: appearance, pixelSize: size))
                XCTAssertEqual(image.bitsPerComponent, 16)
                XCTAssertEqual(image.colorSpace?.name, CGColorSpace.sRGB)
                let bitmap = NSBitmapImageRep(cgImage: image)
                let palette = ThemePalette(hue: 0, saturation: 0.9, brightness: brightness)
                for step in 0..<12 {
                    let sample = palette.rotatingHue(by: Double(step) / 12)
                    let position = sample.handlePosition(at: 0)
                    let color = try XCTUnwrap(bitmap.colorAt(
                        x: Int(position.x * Double(size)), y: Int(position.y * Double(size))
                    )?.usingColorSpace(.sRGB))
                    XCTAssertEqual(color.alphaComponent, 1, accuracy: 0.0001)
                    if let previous = previousBrightness[step] {
                        XCTAssertGreaterThan(color.brightnessComponent, previous)
                    }
                    previousBrightness[step] = color.brightnessComponent
                    if brightness == 1 {
                        let expected = try XCTUnwrap(sample.colors(for: appearance)[0].usingColorSpace(.sRGB))
                        let difference = abs(color.hueComponent - expected.hueComponent)
                        XCTAssertLessThan(min(difference, 1 - difference), 0.06,
                                          "Softening must preserve the color direction at every handle.")
                        XCTAssertLessThan(color.saturationComponent, expected.saturationComponent,
                                          "The field is deliberately quieter than the exact handle color.")
                    }
                }
                for (x, y) in [(0, 0), (127, 0), (0, 127), (127, 127)] {
                    XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: x, y: y)).alphaComponent, 1, accuracy: 0.0001,
                                   "Blur must not introduce translucent fringes.")
                }
            }
        }
    }

    func testDarkFieldHasNoColorSeamOrAbruptSteps() throws {
        let palette = ThemePalette(hue: 0, saturation: 0)
        for radius in [0.01, 0.2, 0.42, 0.6] {
            var previous: NSColor?
            for step in 0...720 {
                let angle = Double(step) / 720 * 2 * .pi
                let color = try XCTUnwrap(palette.color(at: CGPoint(
                    x: 0.5 + cos(angle) * radius, y: 0.5 + sin(angle) * radius
                ), appearance: .dark).usingColorSpace(.sRGB))
                if let previous {
                    XCTAssertLessThan(abs(color.redComponent - previous.redComponent), 0.015)
                    XCTAssertLessThan(abs(color.greenComponent - previous.greenComponent), 0.015)
                    XCTAssertLessThan(abs(color.blueComponent - previous.blueComponent), 0.015)
                }
                previous = color
            }
        }
    }

    func testNavigationBackdropUpdatesLiveAndReturnsToSolidColor() throws {
        let base = Theme(id: "palette-backdrop", name: "Palette backdrop")
        let context = BrowserThemeContext(configuration: BrowserThemeConfiguration(
            currentTheme: base, userAppearanceChoice: .light,
            mirrorsSharedTheme: false, mirrorsSharedAppearance: false
        ))
        let backdrop = ColoredVisualEffectView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        backdrop.subtreeThemeSource = context
        backdrop.themedBackgroundColor = .windowOverlayBackground
        backdrop.usesThemePalette = true
        backdrop.layoutSubtreeIfNeeded()
        let backing = try XCTUnwrap(backdrop.subviews.first)
        let gradient = try XCTUnwrap(backing.layer?.sublayers?.first as? CAGradientLayer)
        XCTAssertTrue(gradient.isHidden)

        let palette = ThemePalette(hue: 0.95, saturation: 0.6, colorCount: 3)
        context.setTheme(palette.applying(to: base))
        drainThemeUpdates()
        XCTAssertFalse(gradient.isHidden)
        XCTAssertNil(backing.layer?.backgroundColor)
        let lightColors = try XCTUnwrap(gradient.colors as? [CGColor])
        XCTAssertEqual(lightColors.first, palette.colors(for: .light).first?.cgColor)
        XCTAssertEqual(lightColors.last, palette.colors(for: .light).last?.cgColor)

        context.setTheme(palette.applying(to: base))
        drainThemeUpdates()
        let repeatedColors = try XCTUnwrap(gradient.colors as? [CGColor])
        XCTAssertTrue(zip(lightColors, repeatedColors).allSatisfy { $0 === $1 },
                      "Repeated theme notifications must reuse unchanged gradient samples.")

        context.setUserAppearanceChoice(.dark)
        drainThemeUpdates()
        let darkColors = try XCTUnwrap(gradient.colors as? [CGColor])
        XCTAssertEqual(darkColors.first, palette.colors(for: .dark).first?.cgColor)
        XCTAssertEqual(darkColors.last, palette.colors(for: .dark).last?.cgColor)

        context.setTheme(palette.settingColorCount(1).applying(to: base))
        drainThemeUpdates()
        XCTAssertTrue(gradient.isHidden)
        XCTAssertNotNil(backing.layer?.backgroundColor)
        context.setTheme(base)
        drainThemeUpdates()
        XCTAssertTrue(gradient.isHidden)
    }

    func testSplitNavigationBackdropsShareOnePaletteCoordinateSpace() throws {
        let sidebar = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 800))
        let header = ColoredVisualEffectView(frame: NSRect(x: 0, y: 700, width: 300, height: 100))
        let form = ColoredVisualEffectView(frame: NSRect(x: 0, y: 0, width: 300, height: 700))
        sidebar.addSubview(header)
        sidebar.addSubview(form)

        for backdrop in [header, form] {
            backdrop.paletteCoordinateView = sidebar
            backdrop.layoutSubtreeIfNeeded()
            let backing = try XCTUnwrap(backdrop.subviews.first)
            let gradient = try XCTUnwrap(backing.layer?.sublayers?.first as? CAGradientLayer)
            let frameInSidebar = sidebar.convert(gradient.frame, from: backing)
            XCTAssertEqual(frameInSidebar, sidebar.bounds)
        }
    }

    private func drainThemeUpdates() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    func testNavigationGradientsHaveNoAbruptColorOrSlopeChanges() throws {
        for count in [2, 3] {
            for appearance in [Appearance.light, .dark] {
                for hue in [0.0, 1.0 / 3, 2.0 / 3] {
                    let palette = ThemePalette(hue: hue, saturation: 1, colorCount: count)
                    let base = Theme(id: "smooth-gradient", name: "Smooth gradient")
                    let context = BrowserThemeContext(configuration: BrowserThemeConfiguration(
                        currentTheme: palette.applying(to: base),
                        userAppearanceChoice: appearance.isDark ? .dark : .light,
                        mirrorsSharedTheme: false, mirrorsSharedAppearance: false
                    ))
                    let view = ColoredVisualEffectView(frame: NSRect(x: 0, y: 0, width: 300, height: 800))
                    view.subtreeThemeSource = context
                    view.themedBackgroundColor = .windowOverlayBackground
                    view.usesThemePalette = true
                    let gradient = try XCTUnwrap(view.subviews.first?.layer?.sublayers?.first as? CAGradientLayer)
                    let colors = try XCTUnwrap(gradient.colors as? [CGColor])
                    XCTAssertGreaterThan(colors.count, palette.colorCount)
                    XCTAssertEqual(colors.first, palette.colors(for: appearance).first?.cgColor)
                    XCTAssertEqual(colors.last, palette.colors(for: appearance).last?.cgColor)
                    let channels = try colors.map { color -> [CGFloat] in
                        let rgb = try XCTUnwrap(NSColor(cgColor: color)?.usingColorSpace(.sRGB))
                        XCTAssertEqual(rgb.alphaComponent, ThemeColorAdjustment.defaultOverlayAlpha, accuracy: 0.00001)
                        return [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
                    }
                    for channel in 0..<3 {
                        let changes = zip(channels, channels.dropFirst()).map { $1[channel] - $0[channel] }
                        for change in changes {
                            XCTAssertLessThan(abs(change), 0.06, "Neighboring samples should blend without a jump.")
                        }
                        for (previous, next) in zip(changes, changes.dropFirst()) {
                            XCTAssertLessThan(abs(next - previous), 0.015, "The transition rate should remain continuous.")
                        }
                    }
                }
            }
        }
    }

    func testAppearanceSwitchAnimatesSolidAndGradientWindowBackdrops() throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            throw XCTSkip("Appearance transitions respect Reduce Motion.")
        }
        let manager = ThemeManager.shared
        let previousChoice = manager.userAppearanceChoice
        defer { manager.setUserAppearanceChoice(previousChoice) }
        manager.setUserAppearanceChoice(.light)

        let base = Theme(id: "appearance-transition", name: "Appearance transition")
        let palettes = [1, 3].map { ThemePalette(hue: 0.3, saturation: 0.7, colorCount: $0) }
        let contexts = palettes.map { palette in
            BrowserThemeContext(configuration: BrowserThemeConfiguration(
                currentTheme: palette.applying(to: base), userAppearanceChoice: .light,
                mirrorsSharedTheme: false, mirrorsSharedAppearance: true
            ))
        }
        let backdrops = contexts.map { context in
            let view = ColoredVisualEffectView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
            view.subtreeThemeSource = context
            view.themedBackgroundColor = .windowOverlayBackground
            view.usesThemePalette = true
            return view
        }
        let windows = backdrops.enumerated().map { index, view in
            let window = NSWindow(
                contentRect: NSRect(x: index * 310, y: 0, width: 300, height: 200),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.orderFront(nil)
            // Only a window-backed layer has a render clock. Pause it so
            // test-host startup cannot finish the ramp before inspection.
            view.subviews.first?.layer?.speed = 0
            return window
        }
        defer { windows.forEach { $0.close() } }
        let lightGradient = try XCTUnwrap(backdrops[1].subviews.first?.layer?.sublayers?.first as? CAGradientLayer)
        let lightGradientColors = try XCTUnwrap(lightGradient.colors as? [CGColor])
        let observers = contexts.map { ThemeObserver(themeSource: $0) }
        manager.setUserAppearanceChoice(.dark)
        for index in contexts.indices {
            XCTAssertEqual(contexts[index].currentAppearance, .dark, "Window appearance updates in the click handler.")
            XCTAssertEqual(observers[index].appearance, .dark, "The editor receives immediate selection feedback.")
            let backing = try XCTUnwrap(backdrops[index].subviews.first?.layer)
            let target = index == 0 ? backing : try XCTUnwrap(backing.sublayers?.first)
            XCTAssertNotNil(target.animation(forKey: "phi.appearanceRamp"), "The transition starts without queueing.")
        }
        drainThemeUpdates()

        for index in backdrops.indices {
            let backing = try XCTUnwrap(backdrops[index].subviews.first?.layer)
            let target = index == 0 ? backing : try XCTUnwrap(backing.sublayers?.first)
            XCTAssertEqual(contexts[index].currentAppearance, .dark)
            XCTAssertEqual(observers[index].appearance, .dark, "Deferred initial binding cannot restore stale appearance.")
            let ramp = try XCTUnwrap(target.animation(forKey: "phi.appearanceRamp") as? CABasicAnimation,
                                    "Backdrop \(index) should interpolate its appearance colors.")
            XCTAssertEqual(ramp.duration, 0.3)
            if index == 0 {
                XCTAssertEqual(ramp.keyPath, "backgroundColor")
                XCTAssertEqual(try XCTUnwrap(ramp.fromValue) as! CGColor, palettes[index].colors(for: .light)[0].cgColor)
                XCTAssertEqual(try XCTUnwrap(ramp.toValue) as! CGColor, palettes[index].colors(for: .dark)[0].cgColor)
            } else {
                XCTAssertEqual(ramp.keyPath, "colors")
                XCTAssertEqual(ramp.fromValue as? [CGColor], lightGradientColors)
                XCTAssertEqual(ramp.toValue as? [CGColor], (target as? CAGradientLayer)?.colors as? [CGColor])
            }
            target.removeAnimation(forKey: "phi.appearanceRamp")
            contexts[index].setTheme(palettes[index].rotatingHue(by: 0.1).applying(to: base))
        }
        drainThemeUpdates()
        for (index, view) in backdrops.enumerated() {
            let backing = try XCTUnwrap(view.subviews.first?.layer)
            let target = index == 0 ? backing : try XCTUnwrap(backing.sublayers?.first)
            XCTAssertNil(target.animation(forKey: "phi.appearanceRamp"), "Direct color edits stay immediate.")
        }
    }

    func testSpacePaletteResolvesThroughLegacyControlsAndPresetClearsIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let account = Account(userID: "theme-palette-test-" + UUID().uuidString)
        let store = LocalStore(account: account, storeDirectoryURL: directory, presentsCompatibilityAlerts: false)
        account.localStorage = store
        let manager = SpaceManager.makeForTesting(boundTo: account)
        let spaceId = "palette-test-space"
        let palette = ThemePalette(hue: 0.95, saturation: 0.6, colorCount: 3)
        manager.previewThemePalette(palette, forSpaceId: spaceId, expectedStoreIdentifier: manager.storeIdentifier)
        XCTAssertNil(manager.themePalette(forSpaceId: spaceId), "Pointer previews must not persist intermediate edits.")
        manager.setThemePalette(palette, forSpaceId: spaceId)
        XCTAssertEqual(manager.resolvedTheme(forSpaceId: spaceId).navigationPalette, palette)
        manager.setOverlaySaturation(0.5, forSpaceId: spaceId, appearance: .light)
        XCTAssertEqual(manager.themePalette(forSpaceId: spaceId)?.saturation ?? -1, 0.5, accuracy: 0.000001)
        XCTAssertEqual(manager.themePalette(forSpaceId: spaceId)?.colorCount, 3)
        manager.setPureThemeSliderValue(25, forSpaceId: spaceId)
        XCTAssertEqual(manager.themePalette(forSpaceId: spaceId)?.brightness, 0.75)
        manager.setTheme(forSpaceId: spaceId, themeId: Theme.mint.id)
        XCTAssertNil(manager.themePalette(forSpaceId: spaceId))
        XCTAssertNil(manager.resolvedTheme(forSpaceId: spaceId).navigationPalette)
        XCTAssertEqual(manager.resolvedThemeId(forSpaceId: spaceId), Theme.mint.id)
        try await store.closeForAccountDirectoryRemoval()
        try FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: account.userDataStorage)
    }
}

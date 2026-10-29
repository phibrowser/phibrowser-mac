// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import XCTest
@testable import Phi

@MainActor
final class HolographicCardViewTests: XCTestCase {
    private func waitForMaterial(in view: HolographicCardView) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while view.renderedStyle != view.style {
            guard ContinuousClock.now < deadline else {
                XCTFail("Card material did not finish loading.")
                throw NSError(domain: "HolographicCardViewTests", code: 1)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testInitialUserStyleLoadsWithoutShowingOrAnimatingDefaultArtwork() async throws {
        let style = HolographicCardStyle(palette: .gold, texture: .brushed, ornament: .none)
        let view = HolographicCardView(style: style)
        let rotor = try XCTUnwrap(view.layer?.sublayers?.first)
        XCTAssertEqual(view.style, style)
        XCTAssertNil(view.renderedStyle)
        XCTAssertTrue(rotor.isHidden)
        XCTAssertFalse(view.isAnimating)
        try await waitForMaterial(in: view)
        XCTAssertEqual(view.renderedStyle, style)
        XCTAssertFalse(rotor.isHidden)
        XCTAssertFalse(view.isAnimating, "A detached card must not start its entrance.")
    }

    func testLatestStyleWinsWhenChangedBeforeArtworkIsReady() async throws {
        let view = HolographicCardView(style: .init(texture: .waves, ornament: .lotus))
        view.style = .init(palette: .blue, texture: .diamond, ornament: .periodic)
        let latest = HolographicCardStyle(palette: .pink, texture: .stardust, ornament: .none)
        view.style = latest
        try await waitForMaterial(in: view)
        XCTAssertEqual(view.renderedStyle, latest)
        // Allow cancelled requests to resume; none may replace the latest material.
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(view.renderedStyle, latest)
    }

    func testMaterialDiskCacheSurvivesNewCacheAndPaletteChanges() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let style = HolographicCardStyle(palette: .gold, texture: .brushed, ornament: .lotus)
        let first = await HolographicCardArtwork.Cache(directory: folder).material(for: style)
        let directory = folder.appendingPathComponent("v1-584x846")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(Set(files.map(\.lastPathComponent)), ["grain.png", "foil-brushed.png", "seal-lotus.plist"])
        let timestamp = Date(timeIntervalSince1970: 1234)
        for file in files {
            try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: file.path)
        }
        var anotherPalette = style
        anotherPalette.palette = .blue
        let restored = await HolographicCardArtwork.Cache(directory: folder).material(for: anotherPalette)
        XCTAssertEqual(first.seal.value, restored.seal.value)
        try assertSamePixels(first.grain, restored.grain)
        try assertSamePixels(first.foil, restored.foil)
        for file in files {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            XCTAssertEqual(attributes[.modificationDate] as? Date, timestamp, "Disk hits must not regenerate or rewrite artwork.")
        }
    }

    func testInvalidDiskMaterialIsRegenerated() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let style = HolographicCardStyle(texture: .brushed, ornament: .lace)
        let original = await HolographicCardArtwork.Cache(directory: folder).material(for: style)
        let directory = folder.appendingPathComponent("v1-584x846")
        try Data("broken image".utf8).write(to: directory.appendingPathComponent("grain.png"))
        let tinyContext = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let tinyImage = try XCTUnwrap(tinyContext.makeImage())
        let tinyPNG = try XCTUnwrap(NSBitmapImageRep(cgImage: tinyImage).representation(using: .png, properties: [:]))
        try tinyPNG.write(to: directory.appendingPathComponent("foil-brushed.png"))
        let invalidSeal = try PropertyListSerialization.data(fromPropertyList: ["contours": []], format: .binary, options: 0)
        try invalidSeal.write(to: directory.appendingPathComponent("seal-lace.plist"))
        let repaired = await HolographicCardArtwork.Cache(directory: folder).material(for: style)
        try assertSamePixels(original.grain, repaired.grain)
        try assertSamePixels(original.foil, repaired.foil)
        XCTAssertEqual(original.seal.value, repaired.seal.value)
        XCTAssertNotEqual(try Data(contentsOf: directory.appendingPathComponent("grain.png")), Data("broken image".utf8))
        XCTAssertNotEqual(try Data(contentsOf: directory.appendingPathComponent("foil-brushed.png")), tinyPNG)
        XCTAssertNotEqual(try Data(contentsOf: directory.appendingPathComponent("seal-lace.plist")), invalidSeal)
    }

    func testUnavailableDiskCacheDoesNotPreventMaterialGeneration() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("not a directory".utf8).write(to: file)
        let material = await HolographicCardArtwork.Cache(directory: file).material(
            for: .init(texture: .stardust, ornament: .none))
        XCTAssertNotNil(material.grain)
        XCTAssertNotNil(material.foil)
        XCTAssertTrue(material.seal.value.isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), Data("not a directory".utf8))
    }

    private func assertSamePixels(_ first: CGImage?, _ second: CGImage?, file: StaticString = #filePath, line: UInt = #line) throws {
        func pixels(_ image: CGImage?) throws -> [UInt8] {
            let image = try XCTUnwrap(image)
            let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
        }
        let lhs = try pixels(first), rhs = try pixels(second)
        XCTAssertEqual(first?.width, second?.width, file: file, line: line)
        XCTAssertEqual(first?.height, second?.height, file: file, line: line)
        // PNG can round alpha unpremultiplication by one byte; compare decoded pixels.
        XCTAssertEqual(lhs.count, rhs.count, file: file, line: line)
        XCTAssertTrue(zip(lhs, rhs).allSatisfy { abs(Int($0) - Int($1)) <= 1 }, file: file, line: line)
    }

    func testPointerClampsOutsideCardAndHandlesEmptyLayout() {
        let bounds = CGRect(x: 20, y: 40, width: 292, height: 423)
        XCTAssertEqual(HolographicCardMotion.normalizedPointer(CGPoint(x: bounds.midX, y: bounds.midY), in: bounds), .zero)
        XCTAssertEqual(HolographicCardMotion.normalizedPointer(CGPoint(x: -100, y: 900), in: bounds), CGPoint(x: -1, y: 1))
        XCTAssertEqual(HolographicCardMotion.normalizedPointer(CGPoint(x: 10, y: 10), in: .zero), .zero)
    }

    func testPointerResponseIsIndependentOfRefreshRate() {
        let pointer = CGPoint(x: 0.7, y: -0.4)
        var sixty = HolographicCardMotion()
        var oneTwenty = HolographicCardMotion()
        for _ in 0..<60 { sixty.advance(by: 1.0 / 60, pointer: pointer) }
        for _ in 0..<120 { oneTwenty.advance(by: 1.0 / 120, pointer: pointer) }
        XCTAssertEqual(sixty.position.x, oneTwenty.position.x, accuracy: 0.000001)
        XCTAssertEqual(sixty.position.y, oneTwenty.position.y, accuracy: 0.000001)
    }

    func testReducedMotionCompletesEntranceWithoutStartingOver() {
        var motion = HolographicCardMotion()
        motion.advance(by: 0.2, pointer: nil)
        motion.finishEntrance()
        XCTAssertEqual(motion.entrance, 1)
        motion.advance(by: 0.1, pointer: nil)
        XCTAssertEqual(motion.entrance, 1)
        motion.advance(by: .nan, pointer: nil)
        XCTAssertTrue(motion.position.x.isFinite)
    }

    func testJoinDateAcceptsFractionalSecondsAndRejectsMissingDates() {
        XCTAssertEqual(HolographicCardView.formattedJoinDate("2026-10-15T12:00:00Z"), "2026.10")
        XCTAssertEqual(HolographicCardView.formattedJoinDate("2026-10-15T12:00:00.123Z"), "2026.10")
        XCTAssertEqual(HolographicCardView.formattedJoinDate(""), "")
        XCTAssertEqual(HolographicCardView.formattedJoinDate("invalid"), "")
    }

    func testExportIsReadableEvenBeforeEntranceAndHasNoSideCutouts() async throws {
        let view = HolographicCardView(frame: .zero)
        view.name = "张三 — A very long profile name"
        view.memberID = "12345"
        view.joinedDate = "2026.10"
        let exported = await view.frontImage(scale: 1)
        let image = try XCTUnwrap(exported)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        XCTAssertEqual(rep.pixelsWide, 292)
        XCTAssertEqual(rep.pixelsHigh, 423)
        XCTAssertEqual(try XCTUnwrap(rep.colorAt(x: 0, y: 0)).alphaComponent, 0, accuracy: 0.01)
        XCTAssertGreaterThan(try XCTUnwrap(rep.colorAt(x: 1, y: 292)).alphaComponent, 0.99)
        XCTAssertGreaterThan(try XCTUnwrap(rep.colorAt(x: 290, y: 292)).alphaComponent, 0.99)
        XCTAssertGreaterThan(try XCTUnwrap(rep.colorAt(x: 146, y: 211)).alphaComponent, 0.99)
        XCTAssertGreaterThan(try XCTUnwrap(rep.colorAt(x: 10, y: 180)).alphaComponent, 0.99)
        XCTAssertFalse(view.isAnimating)
        let invalidExport = await view.frontImage(scale: 0)
        XCTAssertNil(invalidExport)
    }

    func testDetachedCardDoesNotRetainAnAnimationTimer() {
        weak var released: HolographicCardView?
        autoreleasepool {
            let view = HolographicCardView(frame: CGRect(origin: .zero, size: HolographicCardView.designSize))
            released = view
            XCTAssertFalse(view.isAnimating)
            view.isPresentationActive = false
            XCTAssertFalse(view.isAnimating)
        }
        XCTAssertNil(released)
    }

    func testVisibleCardPausesWhenHiddenAndDetached() async throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            throw XCTSkip("The system's Reduce Motion preference disables animation.")
        }
        let view = HolographicCardView(frame: CGRect(origin: .zero, size: HolographicCardView.designSize))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        defer { window.close() }
        try await waitForMaterial(in: view)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(view.isAnimating)
        view.isHidden = true
        XCTAssertFalse(view.isAnimating)
        view.isHidden = false
        XCTAssertTrue(view.isAnimating)
        view.isPresentationActive = false
        XCTAssertFalse(view.isAnimating)
        view.isPresentationActive = true
        XCTAssertTrue(view.isAnimating)
        try await Task.sleep(for: .seconds(3))
        XCTAssertFalse(view.isAnimating)
        view.isHidden = true
        view.isHidden = false
        XCTAssertFalse(view.isAnimating)
        let rotor = try XCTUnwrap(view.layer?.sublayers?.first)
        let restingTransform = rotor.transform
        let location = view.convert(CGPoint(x: view.bounds.maxX, y: view.bounds.midY), to: nil)
        let mouseMove = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: location,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        view.mouseMoved(with: mouseMove)
        XCTAssertTrue(view.isAnimating)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNotEqual(rotor.transform.m13, restingTransform.m13)
        let mouseExit = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseExited, location: location,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        view.mouseExited(with: mouseExit)
        try await Task.sleep(for: .seconds(3))
        XCTAssertFalse(view.isAnimating)
        XCTAssertEqual(rotor.transform.m13, restingTransform.m13, accuracy: 0.000001)
        view.replayEntrance()
        XCTAssertTrue(view.isAnimating)
        view.removeFromSuperview()
        XCTAssertFalse(view.isAnimating)
    }

    func testProfileControllerUpdatesTheSharedCardWithRealProfileData() throws {
        let controller = ProfileCardViewController()
        let card = try XCTUnwrap(controller.view as? HolographicCardView)
        XCTAssertFalse(card.animatesIdleTilt)
        controller.profile = Profile(id: 12345, auth0_id: "fixture", email: "fixture@example.com",
            name: "张三", picture: "", last_login: "", created_at: "2026-10-15T12:00:00.123Z")
        XCTAssertEqual(card.name, "张三")
        XCTAssertEqual(card.memberID, "f16d05ec6b29248d")
        XCTAssertEqual(card.joinedDate, "2026.10")
        controller.profile?.name = "Updated Name"
        XCTAssertEqual(card.name, "Updated Name")
    }

    func testProfileCardKeepsItsSavedStyleAcrossThemeAndAppearanceChanges() throws {
        let originalAccount = AccountController.shared.account
        let originalTheme = ThemeManager.shared.currentTheme
        let originalAppearance = ThemeManager.shared.userAppearanceChoice
        let account = Account(userID: UUID().uuidString)
        defer {
            AccountController.shared.account = originalAccount
            ThemeManager.shared.currentTheme = originalTheme
            ThemeManager.shared.userAppearanceChoice = originalAppearance
            try? FileManager.default.removeItem(at: account.userDataStorage)
        }
        AccountController.shared.account = account
        let style = HolographicCardStyle(palette: .gold, texture: .brushed, ornament: .modulated)
        XCTAssertTrue(account.userDefaults.set(style, forCodableKey: AccountUserDefaults.DefaultsKey.profileCardStyle.rawValue))
        ThemeManager.shared.switchTheme(to: "pure")

        let controller = ProfileCardViewController()
        let card = try XCTUnwrap(controller.view as? HolographicCardView)
        XCTAssertEqual(card.style, style)
        ThemeManager.shared.switchTheme(to: "mint")
        XCTAssertEqual(card.style, style)
        ThemeManager.shared.userAppearanceChoice = .dark
        ThemeManager.shared.userAppearanceChoice = .light
        XCTAssertEqual(card.style, style)

        let reopened = ProfileCardViewController()
        XCTAssertEqual(try XCTUnwrap(reopened.view as? HolographicCardView).style, style)
    }

    func testProfileCardRandomizationPersistsWithoutChangingBrowserTheme() throws {
        let originalAccount = AccountController.shared.account
        let originalTheme = ThemeManager.shared.currentTheme
        let account = Account(userID: UUID().uuidString)
        defer {
            AccountController.shared.account = originalAccount
            ThemeManager.shared.currentTheme = originalTheme
            try? FileManager.default.removeItem(at: account.userDataStorage)
        }
        AccountController.shared.account = account
        let controller = ProfileCardViewController()
        let card = try XCTUnwrap(controller.view as? HolographicCardView)
        for _ in 0..<12 {
            controller.randomizeCard()
            XCTAssertTrue(ThemeManager.shared.currentTheme === originalTheme)
            let saved: HolographicCardStyle? = account.userDefaults.codableValue(
                forKey: AccountUserDefaults.DefaultsKey.profileCardStyle.rawValue)
            XCTAssertEqual(saved, card.style)
            let reopened = ProfileCardViewController()
            XCTAssertEqual(try XCTUnwrap(reopened.view as? HolographicCardView).style, card.style)
        }
    }

    func testWelcomeUsesTheSameNativeCardWithinItsExistingLayout() throws {
        let controller = OnboardingWelcomeViewController()
        controller.userName = "Welcome Fixture"
        controller.view.frame = CGRect(x: 0, y: 0, width: 640, height: 800)
        controller.view.layoutSubtreeIfNeeded()
        let card = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? HolographicCardView }.first)
        XCTAssertFalse(card.animatesIdleTilt)
        XCTAssertEqual(card.name, "Welcome Fixture")
        XCTAssertEqual(card.frame.width, 292, accuracy: 0.5)
        XCTAssertEqual(card.frame.height, 423, accuracy: 0.5)
        XCTAssertTrue(controller.view.bounds.contains(card.frame))
        XCTAssertEqual(card.joinedDate, "")
    }
    func testReferenceDefaultsAndThemeMapping() {
        XCTAssertEqual(HolographicCardStyle.default.palette, .silver)
        XCTAssertEqual(HolographicCardStyle.default.texture, .arcs)
        XCTAssertEqual(HolographicCardStyle.default.ornament, .lace)
        XCTAssertEqual(HolographicCardStyle.gradientAngle, 200)
        XCTAssertEqual(HolographicCardStyle.textureOpacity, 0.72)
        XCTAssertEqual(HolographicCardStyle.iridescenceOpacity, 0.78)
        XCTAssertEqual(HolographicCardStyle.textureContrast, 1.18)
        XCTAssertEqual(Set(HolographicCardStyle.Palette.allCases.map(\.themeID)), Set(Theme.builtInThemes.map(\.id)))
        XCTAssertEqual(HolographicCardStyle.Palette(themeID: Theme.default.id), .silver)
        XCTAssertEqual(HolographicCardStyle.Palette(themeID: "custom"), .silver)
        XCTAssertEqual(HolographicCardStyle.Palette.blue.colors, [0x63CFFD, 0x83E4C5, 0xA777E8])
        XCTAssertEqual(HolographicCardStyle.Palette.aqua.themeID, "aqua")
        XCTAssertEqual(HolographicCardStyle.Palette.blue.themeID, "mist")
    }

    func testRandomSelectionReachesEveryIndependentCombination() {
        struct Seeded: RandomNumberGenerator {
            var state: UInt64 = 91
            mutating func next() -> UInt64 {
                state &+= 0x9e3779b97f4a7c15
                var value = state
                value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
                value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
                return value ^ (value >> 31)
            }
        }
        var generator = Seeded()
        var selected = Set<HolographicCardStyle>()
        for _ in 0..<10_000 { selected.insert(.random(using: &generator)) }
        XCTAssertEqual(selected.count, 8 * 6 * 6)
    }

    func testEveryTextureHasDistinctCachedArtwork() async throws {
        var data = Set<Data>()
        for texture in HolographicCardStyle.Texture.allCases {
            let generated = await HolographicCardArtwork.cache.foil(texture)
            let image = try XCTUnwrap(generated)
            XCTAssertEqual(image.width, 584)
            XCTAssertEqual(image.height, 846)
            let cached = await HolographicCardArtwork.cache.foil(texture)
            XCTAssertTrue(image === cached)
            data.insert(try XCTUnwrap(image.dataProvider?.data) as Data)
        }
        XCTAssertEqual(data.count, 6)
    }

    func testFormulaOrnamentsStayOpenAndNoneIsEmpty() async {
        for ornament in HolographicCardStyle.Ornament.allCases {
            let cachedPath = await HolographicCardArtwork.cache.sealPath(ornament)
            let path = cachedPath.value
            var closed = 0, moves = 0, lines = 0
            path.applyWithBlock { element in
                switch element.pointee.type {
                case .closeSubpath: closed += 1
                case .moveToPoint: moves += 1
                case .addLineToPoint: lines += 1
                default: break
                }
            }
            if ornament == .none {
                XCTAssertTrue(path.isEmpty)
            } else if ornament == .lace || ornament == .lotus {
                XCTAssertEqual(closed, 6)
                XCTAssertEqual(moves, 6)
                XCTAssertEqual(lines, 6 * 2880)
            } else {
                XCTAssertEqual(closed, 0)
                XCTAssertEqual(moves, 1)
                XCTAssertEqual(lines, (ornament == .epicycloid ? 16 : 20) * 720)
            }
        }
    }

    func testCardStylePersistsAcrossReloadAndIsAccountScoped() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let account = Account(userID: UUID().uuidString)
        let url = folder.appendingPathComponent("card.plist")
        let defaults = AccountUserDefaults(account: account, storeURL: url)
        let key = AccountUserDefaults.DefaultsKey.profileCardStyle.rawValue
        let style = HolographicCardStyle(palette: .gold, texture: .brushed, ornament: .modulated)
        XCTAssertTrue(defaults.set(style, forCodableKey: key))
        let reloaded: HolographicCardStyle? = AccountUserDefaults(account: account, storeURL: url).codableValue(forKey: key)
        XCTAssertEqual(reloaded, style)
        let other = AccountUserDefaults(account: Account(userID: UUID().uuidString), storeURL: folder.appendingPathComponent("other.plist"))
        let missing: HolographicCardStyle? = other.codableValue(forKey: key)
        XCTAssertNil(missing)
    }

    func testWelcomeStartsWithDefaultsAndRandomButtonUpdatesTheTheme() throws {
        let originalTheme = ThemeManager.shared.currentTheme.id
        defer { ThemeManager.shared.switchTheme(to: originalTheme) }
        let controller = OnboardingWelcomeViewController()
        controller.view.layoutSubtreeIfNeeded()
        let card = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? HolographicCardView }.first)
        XCTAssertEqual(card.style, .default)
        let random = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? NSButton }.first { $0.action == NSSelectorFromString("randomizeCard") })
        XCTAssertFalse(random.frame.intersects(card.frame))
        for _ in 0..<5 {
            random.performClick(nil)
            XCTAssertEqual(ThemeManager.shared.currentTheme.id, card.style.palette.themeID)
        }
        let selection = card.style
        controller.viewWillDisappear()
        controller.viewWillAppear()
        XCTAssertEqual(card.style, selection, "Revisiting must not reroll or reset the selected texture.")
        controller.viewWillDisappear()
    }

    #if DEBUG
    func testDebugControlsPreviewEveryOptionWithoutChangingBrowserTheme() throws {
        let originalTheme = ThemeManager.shared.currentTheme.id
        let controller = HolographicCardDebugViewController()
        _ = controller.view
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let controls = descendants(controller.view).compactMap { $0 as? NSPopUpButton }
        XCTAssertEqual(controls.map(\.numberOfItems), [8, 6, 6])
        for control in controls {
            for index in 0..<control.numberOfItems {
                control.selectItem(at: index)
                NSApp.sendAction(try XCTUnwrap(control.action), to: control.target, from: control)
            }
        }
        XCTAssertEqual(controller.cardView.style, HolographicCardStyle(palette: .gold, texture: .stardust, ornament: .none))
        let reset = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSButton }.first { $0.title == "Restore Defaults" })
        reset.performClick(nil)
        XCTAssertEqual(controller.cardView.style, .default)
        XCTAssertEqual(ThemeManager.shared.currentTheme.id, originalTheme)
    }
    #endif
}

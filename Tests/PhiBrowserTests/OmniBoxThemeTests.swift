// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

@MainActor
final class OmniBoxThemeTests: XCTestCase {
    private var directory: URL?
    private var store: LocalStore?

    override func tearDown() async throws {
        try await store?.closeForAccountDirectoryRemoval()
        store = nil
        if let directory { try FileManager.default.removeItem(at: directory) }
        directory = nil
        try await super.tearDown()
    }

    func testOmniBoxTracksWindowThemeWhileVisibleAndAfterReopening() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        let store = LocalStore(account: Account(userID: UUID().uuidString), storeDirectoryURL: directory)
        self.store = store
        let state = BrowserState(windowId: UUID().hashValue, localStore: store, profileId: "Default")
        let context = state.themeContext
        let red = Theme(id: "omnibox-red", name: "Red", colorPalette: [.windowOverlayBackground: ColorPair(.red)])
        let yellow = Theme(id: "omnibox-yellow", name: "Yellow", colorPalette: [.windowOverlayBackground: ColorPair(.yellow)])

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let controller = SpaceSessionController(window: window, windowId: state.windowId,
                                                     profileId: state.profileId, account: store.account,
                                                     browserState: state)
        context.mirrorsSharedTheme = false
        context.mirrorsSharedAppearance = false
        context.setUserAppearanceChoice(.dark)
        context.setTheme(red)
        drainThemeUpdates()
        defer {
            controller.omniBoxHostPanel?.orderOut(nil)
            window.close()
            withExtendedLifetime(controller) {}
        }

        let panel = try XCTUnwrap(controller.attachAndShowOmniBoxHostPanel())
        let omnibox = OmniBoxViewController(viewModel: .init(windowState: state), state: state)
        panel.contentView?.addSubview(omnibox.view)
        let background = try XCTUnwrap(omnibox.view.subviews.first)
        XCTAssertTrue(panel.themeStateProvider === context)
        XCTAssertTrue(background.themeStateProvider === context)
        XCTAssertEqual(panel.effectiveAppearance.phiAppearance, .dark)
        assertBackground(background, .red)

        // Updating the active Space's window context must refresh an already mounted overlay.
        context.setTheme(yellow)
        drainThemeUpdates()
        assertBackground(background, .yellow)

        // Reuse the same panel and views, as the production dismiss/show path does.
        omnibox.view.removeFromSuperview()
        window.removeChildWindow(panel)
        panel.orderOut(nil)
        context.setTheme(red)
        drainThemeUpdates()
        XCTAssertTrue(controller.attachAndShowOmniBoxHostPanel() === panel)
        panel.contentView?.addSubview(omnibox.view)
        XCTAssertEqual(panel.effectiveAppearance.phiAppearance, .dark)
        assertBackground(background, .red)

        context.setUserAppearanceChoice(.light)
        drainThemeUpdates()
        XCTAssertEqual(panel.effectiveAppearance.phiAppearance, .light)
        assertBackground(background, .white)
        context.setUserAppearanceChoice(.dark)
        drainThemeUpdates()
        XCTAssertEqual(panel.effectiveAppearance.phiAppearance, .dark)
        assertBackground(background, .red)
    }

    func testIncognitoOmniBoxUsesLightInputTextWhenAppAppearanceIsLight() throws {
        let originalAppearance = NSApp.appearance
        defer { NSApp.appearance = originalAppearance }
        NSApp.appearance = NSAppearance(named: .aqua)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        let store = LocalStore(account: Account(userID: UUID().uuidString), storeDirectoryURL: directory)
        self.store = store
        let state = BrowserState(windowId: UUID().hashValue, localStore: store,
                                 profileId: "Default", isIncognito: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let controller = SpaceSessionController(window: window, windowId: state.windowId,
                                                     profileId: state.profileId, account: store.account,
                                                     browserState: state)
        defer {
            controller.omniBoxHostPanel?.orderOut(nil)
            window.close()
            withExtendedLifetime(controller) {}
        }

        let panel = try XCTUnwrap(controller.attachAndShowOmniBoxHostPanel())
        let omnibox = OmniBoxViewController(viewModel: .init(windowState: state), state: state)
        panel.contentView?.addSubview(omnibox.view)
        let background = try XCTUnwrap(omnibox.view.subviews.first)
        let input = try XCTUnwrap(background.subviews.flatMap(\.subviews)
            .compactMap { $0 as? OmniBoxTextField }.first)
        input.updateDisplayText("google.com")
        omnibox.focusTextField()
        let editor = try XCTUnwrap(input.textFiled.currentEditor() as? NSTextView)

        XCTAssertEqual(NSApp.effectiveAppearance.phiAppearance, .light)
        XCTAssertEqual(window.effectiveAppearance.phiAppearance, .dark)
        XCTAssertEqual(panel.effectiveAppearance.phiAppearance, .dark)
        XCTAssertEqual(input.textFiled.effectiveAppearance.phiAppearance, .dark)
        XCTAssertEqual(editor.effectiveAppearance.phiAppearance, .dark)
        var textBrightness: CGFloat?
        editor.effectiveAppearance.performAsCurrentDrawingAppearance {
            textBrightness = editor.textColor?.usingColorSpace(.genericGray)?.whiteComponent
        }
        XCTAssertGreaterThan(try XCTUnwrap(textBrightness), 0.5)
    }

    func testUnownedPanelKeepsGlobalThemeFallback() {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        XCTAssertNil(panel.browserThemeContext)
        XCTAssertTrue(panel.themeStateProvider === ThemeManager.shared)
    }

    func testReusedEngineRowRestoresThemeColorsForAnUnknownKeyword() throws {
        func suggestion(keyword: String, name: String) -> OmniBoxSuggestion {
            OmniBoxSuggestion(chromiumDic: [
                "type": "search-other-engine", "contents": "music", "description": name,
                "keywordSearchKeyword": keyword, "keywordSearchName": name,
                "destinationUrl": "", "fillIntoEdit": "", "line": 0
            ])
        }
        let spotify = suggestion(keyword: "spotify.com", name: "My music")
        let cell = OmniBoxSuggestionCellView(suggestion: spotify, index: 0, showsSwitchToTabHint: false)
        let background = try XCTUnwrap(cell.subviews.first as? HoverableView)
        let red = Theme(id: "engine-red", name: "Red", colorPalette: [.themeColor: ColorPair(.red)])
        let blue = Theme(id: "engine-blue", name: "Blue", colorPalette: [.themeColor: ColorPair(.blue)])

        cell.configure(with: spotify, index: 0)
        let brandMapper = try XCTUnwrap(background.phi.selectedColor)
        XCTAssertEqual(brandMapper[red, .light], NSColor(hex: 0x1DB954))
        XCTAssertEqual(brandMapper[blue, .dark], NSColor(hex: 0x1DB954))

        // A custom engine named Spotify must not inherit a previously used row's brand.
        cell.configure(with: suggestion(keyword: "example.com", name: "Spotify"), index: 1)
        let fallbackMapper = try XCTUnwrap(background.phi.selectedColor)
        let hoverMapper = try XCTUnwrap(background.phi.hoveredColor)
        for theme in [red, blue] {
            for appearance in [Appearance.light, .dark] {
                let expected = ThemedColor.themeColor.resolve(theme: theme, appearance: appearance)
                XCTAssertEqual(fallbackMapper[theme, appearance], expected)
                XCTAssertEqual(hoverMapper[theme, appearance], expected.withAlphaComponent(0.16))
            }
        }

        cell.configure(with: suggestion(keyword: "twitter.com", name: "X"), index: 2)
        XCTAssertEqual(try XCTUnwrap(background.phi.selectedColor)[blue, .dark], NSColor(hex: 0x000000))
    }

    private func drainThemeUpdates() {
        let drained = expectation(description: "Theme updates delivered")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
    }

    private func assertBackground(_ view: NSView, _ expected: NSColor,
                                  file: StaticString = #filePath, line: UInt = #line) {
        guard let cgColor = view.layer?.backgroundColor,
              let actual = NSColor(cgColor: cgColor)?.usingColorSpace(.sRGB),
              let expected = expected.usingColorSpace(.sRGB) else {
            XCTFail("Expected an sRGB omnibox background", file: file, line: line)
            return
        }
        XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.alphaComponent, expected.alphaComponent, accuracy: 0.001, file: file, line: line)
    }
}

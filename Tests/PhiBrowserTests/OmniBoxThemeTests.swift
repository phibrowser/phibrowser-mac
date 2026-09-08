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
        let controller = MainBrowserWindowController(window: window, windowId: state.windowId,
                                                     profileId: state.profileId, account: store.account,
                                                     browserState: state)
        context.mirrorsSharedTheme = false
        context.mirrorsSharedAppearance = false
        context.setUserAppearanceChoice(.dark)
        context.setTheme(red)
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
        assertBackground(background, .red)

        context.setUserAppearanceChoice(.light)
        drainThemeUpdates()
        assertBackground(background, .white)
        context.setUserAppearanceChoice(.dark)
        drainThemeUpdates()
        assertBackground(background, .red)
    }

    func testUnownedPanelKeepsGlobalThemeFallback() {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        XCTAssertNil(panel.browserThemeContext)
        XCTAssertTrue(panel.themeStateProvider === ThemeManager.shared)
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

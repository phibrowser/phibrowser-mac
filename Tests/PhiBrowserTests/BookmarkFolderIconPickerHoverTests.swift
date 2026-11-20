// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

/// While a folder's icon picker is open, a clear window over the browser
/// window takes the pointer, so nothing under the picker reacts to hover and a
/// folder preview can't open over the picker and close it.
@MainActor
final class BookmarkFolderIconPickerHoverTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        windows.forEach { $0.close() }
        windows = []
    }

    func testTheShieldCoversTheBrowserWindowAndTakesThePointer() {
        let browser = makeWindow()
        let shield = HoverShield.makeWindow(over: browser)
        windows.append(shield)
        XCTAssertEqual(shield.frame, browser.frame)
        XCTAssertFalse(shield.ignoresMouseEvents, "The shield must take the pointer from the window under it")
        XCTAssertEqual(shield.styleMask, [.borderless])
    }

    func testTheShieldDrawsNothing() {
        let shield = HoverShield.makeWindow(over: makeWindow())
        windows.append(shield)
        XCTAssertFalse(shield.isOpaque)
        XCTAssertEqual(shield.backgroundColor, .clear)
        XCTAssertFalse(shield.hasShadow)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        return window
    }
}

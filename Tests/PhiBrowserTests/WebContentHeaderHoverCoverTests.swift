// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SwiftUI
import XCTest
@testable import Phi

/// SwiftUI hover in the page header ignores views on top of the header, so
/// the floating sidebar's panel left the address bar under it highlighted.
/// `WebContentHeaderHostingView.isPointerCovered(by:)` decides when the
/// pointer is on such a view.
@MainActor
final class WebContentHeaderHoverCoverTests: XCTestCase {
    private var window: NSWindow?

    override func tearDown() async throws {
        window?.close()
        window = nil
    }

    func testThePointerOnTheHeaderBesideThePanelIsNotCovered() throws {
        let (header, _) = makeWindow()
        XCTAssertFalse(header.isPointerCovered(by: try move(to: NSPoint(x: 400, y: 350))))
    }

    func testThePointerOnThePanelOverTheHeaderIsCovered() throws {
        let (header, _) = makeWindow()
        XCTAssertTrue(header.isPointerCovered(by: try move(to: NSPoint(x: 100, y: 350))))
    }

    func testThePointerOnThePanelsEmptyTitlebarSpaceIsCovered() throws {
        let (header, _) = makeWindow()
        let point = NSPoint(x: 100, y: 395)
        let root = try XCTUnwrap(window?.contentView)
        XCTAssertNil(root.hitTest(root.superview?.convert(point, from: nil) ?? point),
                     "The window must give the panel's empty titlebar space to itself")
        XCTAssertTrue(header.isPointerCovered(by: try move(to: point)))
    }

    func testThePointerWhereAHiddenPanelSitsIsNotCovered() throws {
        let (header, panel) = makeWindow()
        panel.isHidden = true
        XCTAssertFalse(header.isPointerCovered(by: try move(to: NSPoint(x: 100, y: 350))))
        XCTAssertFalse(header.isPointerCovered(by: try move(to: NSPoint(x: 100, y: 395))))
    }

    /// A 600 × 400 window with the shell's titlebar-aware content view, the
    /// header along its top 70 pt and, on top, a panel along its left edge
    /// whose empty space in the titlebar band goes to the window.
    private func makeWindow() -> (WebContentHeaderHostingView, NSView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        self.window = window
        let root = TitlebarTransparentView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView = root
        let header = WebContentHeaderHostingView(rootView: AnyView(Color.red))
        header.frame = NSRect(x: 0, y: 330, width: 600, height: 70)
        root.addSubview(header)
        let panel = TitlebarPassingPanel(frame: NSRect(x: 5, y: 5, width: 204, height: 390))
        root.addSubview(panel)
        root.layoutSubtreeIfNeeded()
        return (header, panel)
    }

    private func move(to point: NSPoint) throws -> NSEvent {
        let window = try XCTUnwrap(window)
        return try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [],
                                                timestamp: 0, windowNumber: window.windowNumber,
                                                context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
    }

    /// Gives its empty titlebar space to the window, as the floating
    /// sidebar's header does.
    private final class TitlebarPassingPanel: NSView, TitlebarAwareHitTestable {
        func shouldConsumeHitTest(at point: NSPoint) -> Bool { false }
    }
}

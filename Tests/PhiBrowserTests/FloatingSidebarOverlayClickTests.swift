// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

/// A click on the floating panel that nothing in it handles comes up the
/// panel's responder chain to `FloatingSidebarOverlayView`. Passed on, it
/// reached the page header under the panel and opened the address bar.
@MainActor
final class FloatingSidebarOverlayClickTests: XCTestCase {
    private var window: NSWindow?

    override func tearDown() async throws {
        window?.close()
        window = nil
    }

    func testAnUnhandledClickOnTheVisiblePanelEndsAtTheOverlay() throws {
        let (overlay, panel, next) = makeOverlay()
        overlay.visiblePanel = { panel }

        try click(overlay, at: NSPoint(x: 100, y: 300))
        XCTAssertEqual(next.events, [], "The click must not pass on to what lies under the panel")
    }

    func testAClickBesideThePanelStillPassesOn() throws {
        let (overlay, panel, next) = makeOverlay()
        overlay.visiblePanel = { panel }

        try click(overlay, at: NSPoint(x: 400, y: 300))
        XCTAssertEqual(next.events, [.leftMouseDown, .leftMouseDragged, .leftMouseUp])
    }

    func testAClickWhereAHiddenPanelSitsStillPassesOn() throws {
        let (overlay, _, next) = makeOverlay()
        overlay.visiblePanel = { nil }

        try click(overlay, at: NSPoint(x: 100, y: 300))
        XCTAssertEqual(next.events, [.leftMouseDown, .leftMouseDragged, .leftMouseUp])
    }

    /// An overlay over a 600 × 400 window, with the panel along its left edge
    /// and a recorder as the next responder in the overlay's place.
    private func makeOverlay() -> (FloatingSidebarOverlayView, NSView, EventRecorder) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        self.window = window
        let overlay = FloatingSidebarOverlayView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView = overlay
        let panel = NSView(frame: NSRect(x: 5, y: 5, width: 204, height: 390))
        overlay.addSubview(panel)
        let next = EventRecorder()
        overlay.nextResponder = next
        return (overlay, panel, next)
    }

    private func click(_ overlay: NSView, at point: NSPoint) throws {
        let window = try XCTUnwrap(overlay.window)
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                             timestamp: 0, windowNumber: window.windowNumber,
                                             context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        overlay.mouseDown(with: try event(.leftMouseDown))
        overlay.mouseDragged(with: try event(.leftMouseDragged))
        overlay.mouseUp(with: try event(.leftMouseUp))
    }

    private final class EventRecorder: NSResponder {
        var events: [NSEvent.EventType] = []
        override func mouseDown(with event: NSEvent) { events.append(event.type) }
        override func mouseDragged(with event: NSEvent) { events.append(event.type) }
        override func mouseUp(with event: NSEvent) { events.append(event.type) }
    }
}

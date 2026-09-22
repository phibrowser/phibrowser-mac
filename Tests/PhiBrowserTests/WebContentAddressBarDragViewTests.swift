// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

@MainActor
final class WebContentAddressBarDragViewTests: XCTestCase {
    func testClaimsLeftButtonPressReleaseAndDrag() {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp, .leftMouseDragged] {
            XCTAssertTrue(
                WebContentAddressBarDragView.claimsEvent(ofType: type),
                "Expected the surface to claim \(type)"
            )
        }
    }

    func testLeavesHoverRightClickAndScrollToTheSwiftUIBar() {
        let passthroughTypes: [NSEvent.EventType] = [
            .mouseMoved, .mouseEntered, .mouseExited, .cursorUpdate,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .scrollWheel
        ]
        for type in passthroughTypes {
            XCTAssertFalse(
                WebContentAddressBarDragView.claimsEvent(ofType: type),
                "Expected \(type) to fall through to the SwiftUI bar"
            )
        }
    }

    func testDoesNotClaimWithoutACurrentEvent() {
        XCTAssertFalse(WebContentAddressBarDragView.claimsEvent(ofType: nil))
    }

    func testReleaseAtFivePointsIsAClick() {
        XCTAssertTrue(WebContentAddressBarDragView.isClick(
            from: NSPoint(x: 100, y: 100),
            to: NSPoint(x: 105, y: 95)
        ))
    }

    func testReleaseAtThePressIsAClick() {
        XCTAssertTrue(WebContentAddressBarDragView.isClick(
            from: NSPoint(x: 100, y: 100),
            to: NSPoint(x: 100, y: 100)
        ))
    }

    func testReleaseBeyondFivePointsHorizontallyIsNotAClick() {
        XCTAssertFalse(WebContentAddressBarDragView.isClick(
            from: NSPoint(x: 100, y: 100),
            to: NSPoint(x: 94.5, y: 100)
        ))
    }

    func testReleaseBeyondFivePointsVerticallyIsNotAClick() {
        XCTAssertFalse(WebContentAddressBarDragView.isClick(
            from: NSPoint(x: 100, y: 100),
            to: NSPoint(x: 100, y: 106)
        ))
    }

    // The gesture tests leave `allowsWindowDrag` off: the real window drag
    // cannot run in a hosted test, and the click decision does not depend on it.

    func testStillPressAndReleaseOpensTheOmnibox() throws {
        let (view, window) = makeDragView()
        var clicks = 0
        view.onClick = { clicks += 1 }

        view.mouseDown(with: try mouseEvent(.leftMouseDown, at: NSPoint(x: 50, y: 13), in: window))
        view.mouseUp(with: try mouseEvent(.leftMouseUp, at: NSPoint(x: 52, y: 13), in: window))

        XCTAssertEqual(clicks, 1)
    }

    func testDragPastTheThresholdIsNeverAClick() throws {
        let (view, window) = makeDragView()
        var clicks = 0
        view.onClick = { clicks += 1 }

        view.mouseDown(with: try mouseEvent(.leftMouseDown, at: NSPoint(x: 50, y: 13), in: window))
        view.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: NSPoint(x: 80, y: 13), in: window))
        view.mouseUp(with: try mouseEvent(.leftMouseUp, at: NSPoint(x: 50, y: 13), in: window))

        XCTAssertEqual(clicks, 0)
    }

    private func makeDragView() -> (WebContentAddressBarDragView, NSWindow) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 26),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let view = WebContentAddressBarDragView(frame: window.contentView!.bounds)
        window.contentView?.addSubview(view)
        return (view, window)
    }

    private func mouseEvent(
        _ type: NSEvent.EventType,
        at location: NSPoint,
        in window: NSWindow
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
    }
}

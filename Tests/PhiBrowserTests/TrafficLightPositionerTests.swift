// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

@MainActor
final class TrafficLightPositionerTests: XCTestCase {
    func testMatchingInsetsPreserveEveryLayoutRowCenterAndNativeButtonSpacing() throws {
        let window = makeWindow()
        defer { window.close() }
        let buttons = try windowButtons(in: window)
        let nativeFrames = buttons.map { $0.convert($0.bounds, to: nil) }
        let nativeSuperviews = buttons.map(\.superview)

        for (layout, expectedCenter) in [(LayoutMode.performance, CGFloat(20)), (.balanced, 27.5), (.comfortable, 22)] {
            let positioner = TrafficLightPositioner(window: window,
                centerFromWindowTop: SpaceSessionController.chromeRowCenter(for: layout))
            positioner.start()
            let frames = buttons.map { $0.convert($0.bounds, to: nil) }
            let topInset = window.frame.height - frames[0].maxY
            XCTAssertEqual(frames[0].minX, topInset, accuracy: 0.01, "\(layout)")
            for index in buttons.indices {
                XCTAssertEqual(window.frame.height - frames[index].midY, expectedCenter, accuracy: 0.01)
                XCTAssertEqual(frames[index].minX - frames[0].minX,
                    nativeFrames[index].minX - nativeFrames[0].minX, accuracy: 0.01)
                XCTAssertTrue(buttons[index].superview === nativeSuperviews[index])
            }
            positioner.stop(restoringPlacement: true)
            for index in buttons.indices {
                let restored = buttons[index].convert(buttons[index].bounds, to: nil)
                XCTAssertEqual(restored.minX, nativeFrames[index].minX, accuracy: 0.01)
                XCTAssertEqual(restored.minY, nativeFrames[index].minY, accuracy: 0.01)
            }
        }
    }

    func testHorizontalRetilingIsCorrectedEvenWhenVerticalPlacementAlreadyHolds() throws {
        let window = makeWindow()
        defer { window.close() }
        let buttons = try windowButtons(in: window)
        let positioner = TrafficLightPositioner(window: window, centerFromWindowTop: 27.5)
        positioner.start()
        defer { positioner.stop(restoringPlacement: true) }
        let shiftedFrames = buttons.map(\.frame)

        for button in buttons {
            let origin = button.frame.origin
            button.setFrameOrigin(NSPoint(x: origin.x - 4, y: origin.y))
            XCTAssertEqual(button.frame.minX, origin.x, accuracy: 0.01)
        }

        // A silent AppKit move must also be caught by the placement check.
        let zoom = buttons[2]
        zoom.postsFrameChangedNotifications = false
        zoom.setFrameOrigin(NSPoint(x: zoom.frame.minX + 8, y: zoom.frame.minY))
        positioner.apply()
        zoom.postsFrameChangedNotifications = true
        XCTAssertEqual(zoom.frame.minX, shiftedFrames[2].minX, accuracy: 0.01)
        XCTAssertEqual(zoom.frame.minY, shiftedFrames[2].minY, accuracy: 0.01)
    }

    private func makeWindow() -> NSWindow {
        let window = ShellWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.tabbingMode = .disallowed
        window.layoutIfNeeded()
        return window
    }

    private func windowButtons(in window: NSWindow) throws -> [NSButton] {
        try [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].map {
            try XCTUnwrap(window.standardWindowButton($0))
        }
    }
}

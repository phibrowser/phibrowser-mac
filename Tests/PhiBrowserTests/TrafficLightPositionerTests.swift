// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

@MainActor
final class TrafficLightPositionerTests: XCTestCase {
    func testLayoutAlignmentPreservesEveryRowCenterAndNativeButtonSpacing() throws {
        let window = makeWindow()
        defer { window.close() }
        let buttons = try windowButtons(in: window)
        let nativeFrames = buttons.map { $0.convert($0.bounds, to: nil) }
        let nativeSuperviews = buttons.map(\.superview)

        for (layout, expectedCenter) in [(LayoutMode.performance, CGFloat(20)), (.balanced, 27.5), (.comfortable, 22)] {
            let positioner = TrafficLightPositioner(window: window,
                centerFromWindowTop: SpaceSessionController.chromeRowCenter(for: layout, edgeToEdgeEnabled: false),
                centerFromWindowLeading: layout == .balanced ? 22 : nil)
            positioner.start()
            let frames = buttons.map { $0.convert($0.bounds, to: nil) }
            let topInset = window.frame.height - frames[0].maxY
            if layout == .balanced {
                XCTAssertEqual(frames[0].midX, 22, accuracy: 0.01)
            } else {
                XCTAssertEqual(frames[0].minX, topInset, accuracy: 0.01, "\(layout)")
            }
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

/// `apply()` runs on every main run-loop pass in every window, so it must not
/// look the traffic lights up each time: `standardWindowButton` searches the
/// whole frame view. It reuses the buttons it last found while they are still
/// in the window, and looks them up again only once AppKit has replaced them.
@MainActor
final class TrafficLightPositionerButtonCacheTests: XCTestCase {
    private let centerFromWindowTop: CGFloat = 30

    func test_repeatedApplyReusesTheButtonsItFound() throws {
        let window = makeWindow()
        let positioner = TrafficLightPositioner(
            window: window,
            centerFromWindowTop: centerFromWindowTop
        )
        defer { positioner.stop(restoringPlacement: false) }

        positioner.apply()
        try assertLightsHeld(in: window)
        let lookupsAfterFirstApply = window.buttonLookups
        XCTAssertGreaterThan(
            lookupsAfterFirstApply,
            0,
            "Precondition: the first apply finds the buttons."
        )

        for _ in 0..<10 {
            positioner.apply()
        }

        XCTAssertEqual(
            window.buttonLookups,
            lookupsAfterFirstApply,
            "Applies whose cached buttons are still in the window must not "
            + "search the window for them again."
        )
        try assertLightsHeld(in: window)
    }

    func test_applyLooksTheButtonsUpAgainOnceAppKitReplacesOne() throws {
        let window = makeWindow()
        let positioner = TrafficLightPositioner(
            window: window,
            centerFromWindowTop: centerFromWindowTop
        )
        defer { positioner.stop(restoringPlacement: false) }
        positioner.apply()
        try assertLightsHeld(in: window)

        // What AppKit rebuilding the titlebar leaves behind: a new close
        // button in the old one's place, and the old one out of the tree.
        let oldClose = try XCTUnwrap(window.uncountedButton(.closeButton))
        let titlebarView = try XCTUnwrap(oldClose.superview)
        let newClose = NSButton(frame: oldClose.frame)
        titlebarView.addSubview(newClose)
        oldClose.removeFromSuperview()
        window.replacementCloseButton = newClose

        var lookupsBefore = window.buttonLookups
        positioner.apply()
        XCTAssertEqual(
            window.buttonLookups - lookupsBefore,
            3,
            "A cached button that left the window must send the next apply "
                + "back to the window for all three."
        )

        lookupsBefore = window.buttonLookups
        positioner.apply()
        XCTAssertEqual(
            window.buttonLookups - lookupsBefore,
            0,
            "The replacement buttons must be cached in turn."
        )
    }

    /// The per-pass observer exists for the moves AppKit makes without a
    /// notification; reading the buttons from the cache may not skip
    /// putting them back.
    func test_applyRestoresALightMovedWithoutNotice() throws {
        let window = makeWindow()
        let positioner = TrafficLightPositioner(
            window: window,
            centerFromWindowTop: centerFromWindowTop
        )
        defer { positioner.stop(restoringPlacement: false) }
        positioner.apply()
        try assertLightsHeld(in: window)

        let zoom = try XCTUnwrap(window.uncountedButton(.zoomButton))
        let heldOrigin = zoom.frame.origin
        zoom.postsFrameChangedNotifications = false
        zoom.setFrameOrigin(NSPoint(x: heldOrigin.x, y: heldOrigin.y - 6))
        XCTAssertNotEqual(zoom.frame.origin, heldOrigin, "Precondition: moved.")

        let lookupsBefore = window.buttonLookups
        positioner.apply()

        XCTAssertEqual(zoom.frame.origin, heldOrigin)
        try assertLightsHeld(in: window)
        XCTAssertEqual(
            window.buttonLookups - lookupsBefore,
            0,
            "The cached buttons are still in the window; the correction must "
                + "not search for them."
        )
    }

    // MARK: - Helpers

    private func makeWindow() -> ButtonLookupCountingWindow {
        let window = ButtonLookupCountingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [
                .titled,
                .closable,
                .miniaturizable,
                .resizable,
                .fullSizeContentView,
            ],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    /// Every light's centre sits `centerFromWindowTop` below the top of the
    /// window.
    private func assertLightsHeld(
        in window: ButtonLookupCountingWindow,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        for type in [
            NSWindow.ButtonType.closeButton,
            .miniaturizeButton,
            .zoomButton,
        ] {
            let button = try XCTUnwrap(
                window.uncountedButton(type),
                file: file,
                line: line
            )
            let frameInWindow = button.convert(button.bounds, to: nil)
            XCTAssertEqual(
                window.frame.height - frameInWindow.midY,
                centerFromWindowTop,
                accuracy: 0.5,
                "\(type.rawValue) is not on the held line",
                file: file,
                line: line
            )
        }
    }
}

/// Counts every `standardWindowButton(_:)` call, and can stand a new close
/// button in for the window's own.
private final class ButtonLookupCountingWindow: NSWindow {
    private(set) var buttonLookups = 0
    var replacementCloseButton: NSButton?

    override func standardWindowButton(
        _ button: NSWindow.ButtonType
    ) -> NSButton? {
        buttonLookups += 1
        if button == .closeButton, let replacementCloseButton {
            return replacementCloseButton
        }
        return super.standardWindowButton(button)
    }

    /// The button the positioner should be holding, without counting a
    /// lookup.
    func uncountedButton(_ button: NSWindow.ButtonType) -> NSButton? {
        if button == .closeButton, let replacementCloseButton {
            return replacementCloseButton
        }
        return super.standardWindowButton(button)
    }
}

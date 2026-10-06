// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Lottie
import XCTest
@testable import Phi

@MainActor
final class LottieAnimationViewEngineTests: XCTestCase {
    /// Lottie's default engine builds Core Animation animations again each time
    /// its view rejoins a window. Header, address bar and sidebar buttons built
    /// on this view rejoin on every tab mount, so that work would hold the main
    /// thread before the incoming page reaches the screen.
    func testForwardAndReverseAnimationsRenderOnTheMainThread() {
        let button = LottieAnimationNSView(config: LottieAnimationViewConfig(
            animationName: "new-tab",
            reverseAnimationName: "new-tab-reverse"
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 24, height: 24),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = button
        button.layoutSubtreeIfNeeded()

        let engines = lottieViews(in: button).map(\.configuration.renderingEngine)

        XCTAssertEqual(engines.count, 2, "Expected the forward and the reverse animation views.")
        XCTAssertEqual(Set(engines), [.mainThread])
    }

    private func lottieViews(in view: NSView) -> [Lottie.LottieAnimationView] {
        view.subviews.flatMap { subview -> [Lottie.LottieAnimationView] in
            if let animationView = subview as? Lottie.LottieAnimationView {
                return [animationView]
            }
            return lottieViews(in: subview)
        }
    }
}

// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

/// Below 84 pt a tab shows only its favicon, centered; at 84 pt and up, its
/// title. Crossing that width animates in either direction.
@MainActor
final class TabItemViewTitleSwitchTests: XCTestCase {
    private var window: NSWindow!
    private var view: TabItemView!

    override func setUp() async throws {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        view = TabItemView()
        view.prefersReducedMotion = { false }
        view.configure(with: TabRenderData(
            id: "tab-1",
            title: "Example",
            url: "https://example.com",
            isActive: false,
            isPinned: false,
            isSplitGroupActive: false,
            sourceTab: nil
        ))
    }

    override func tearDown() async throws {
        view.removeFromSuperview()
        window.close()
        view = nil
        window = nil
    }

    private func layOut(width: CGFloat) {
        if view.superview == nil { window.contentView?.addSubview(view) }
        view.frame = NSRect(x: 0, y: 0, width: width, height: 32)
        view.layout()
    }

    private func waitForTheTransition() {
        let deadline = Date().addingTimeInterval(1)
        while view.titleProgressStateForTesting.isAnimating && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private func assertShowsTitle(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let state = view.titleProgressStateForTesting
        XCTAssertFalse(state.isAnimating, message, file: file, line: line)
        XCTAssertEqual(state.titleAlpha, 1, message, file: file, line: line)
        XCTAssertLessThan(state.faviconFrame.midX, view.bounds.midX - 10, "favicon leads: \(message)", file: file, line: line)
    }

    private func assertShowsFaviconOnly(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let state = view.titleProgressStateForTesting
        XCTAssertFalse(state.isAnimating, message, file: file, line: line)
        XCTAssertEqual(state.titleAlpha, 0, message, file: file, line: line)
        XCTAssertEqual(state.faviconFrame.midX, view.bounds.midX, accuracy: 0.5, "favicon centered: \(message)", file: file, line: line)
    }

    func testATabLaidOutNarrowShowsOnlyItsFaviconWithoutAnimating() {
        layOut(width: 70)
        assertShowsFaviconOnly("a tab appears in its final state")
    }

    func testNarrowingPastTheSwitchWidthAnimatesTheTitleOut() {
        layOut(width: 120)
        assertShowsTitle("precondition: a wide tab shows its title")
        layOut(width: 80)
        XCTAssertTrue(view.titleProgressStateForTesting.isAnimating, "crossing 84 pt starts the transition")
        waitForTheTransition()
        assertShowsFaviconOnly("the transition finishes on its own")
    }

    func testTheSwitchIsAtTheSameWidthBothWays() {
        layOut(width: 120)
        layOut(width: 84)
        waitForTheTransition()
        assertShowsTitle("84 pt still shows the title")
        layOut(width: 83)
        waitForTheTransition()
        assertShowsFaviconOnly("below 84 pt, favicon only")
        layOut(width: 84)
        waitForTheTransition()
        assertShowsTitle("back at 84 pt, the title returns")
    }

    func testReversingMidwayTurnsBackWithoutAJump() {
        layOut(width: 120)
        layOut(width: 80)
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        let midway = view.titleProgressStateForTesting.titleAlpha
        XCTAssertGreaterThan(midway, 0, "precondition: partway through")
        XCTAssertLessThan(midway, 1, "precondition: partway through")
        layOut(width: 120)
        XCTAssertEqual(view.titleProgressStateForTesting.titleAlpha, midway, accuracy: 0.05,
                       "turning back starts from where the title was")
        waitForTheTransition()
        assertShowsTitle("and ends with the title")
    }

    func testReduceMotionSwitchesAtOnce() {
        view.prefersReducedMotion = { true }
        layOut(width: 120)
        layOut(width: 80)
        assertShowsFaviconOnly("no transition with Reduce Motion")
    }
}

// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

/// Geometry of the agent Space control pill. The caption is agent-authored, so
/// its length is unbounded — and before the pill was clamped a long one grew it
/// past the content pane, carrying "Hand back" and "Finish" off screen and
/// leaving the user no way to take the Space back.
@MainActor
final class AgentSpaceOverlayPillLayoutTests: XCTestCase {
    /// A real overflowing caption: what an agent narrated before handing back
    /// on a shopping page (one unbroken run of CJK text, no spaces to wrap on).
    private let longCaption = """
        当前推荐选为 4 mm 模型椴木层板：珑凡模玩 60×30 cm 单张页面当前约 10.21 元、\
        账号优惠后约 5.91 元，另有同店激光切割免费；杨木板还有 3/5 mm 多为 E1 家具板级；\
        奥古曼没有找到明确的 4 mm 规格
        """

    private func makeOverlay(size: NSSize,
                             ownership: AgentTaskOwnership,
                             caption: String) -> AgentSpaceOverlayView {
        let overlay = AgentSpaceOverlayView(frame: NSRect(origin: .zero, size: size))
        // The pill's material only resolves inside a window, and the layout
        // pass needs one anyway.
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSView(frame: NSRect(origin: .zero, size: size))
        // The pane behind the pill is a web page; white stands in for it.
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.white.cgColor
        window.contentView = host
        host.addSubview(overlay)
        overlay.update(with: task(ownership: ownership, caption: caption))
        overlay.layoutSubtreeIfNeeded()
        return overlay
    }

    /// Resizes the pane the way a window resize does — the overlay is pinned to
    /// the content pane's edges, so its own width is what changes underneath.
    private func resize(_ overlay: AgentSpaceOverlayView, toWidth width: CGFloat) {
        guard let host = overlay.superview else { return XCTFail("overlay not mounted") }
        let size = NSSize(width: width, height: host.frame.height)
        host.window?.setContentSize(size)
        host.frame = NSRect(origin: .zero, size: size)
        overlay.frame = host.bounds
        overlay.layoutSubtreeIfNeeded()
    }

    private func task(ownership: AgentTaskOwnership, caption: String) -> AgentTask {
        AgentTask(
            taskId: "overlay-layout-test",
            spaceId: "space",
            profileId: "profile",
            origin: .cdp,
            driverPrincipalId: nil,
            number: 1,
            windowId: 1,
            ownership: ownership,
            status: .running,
            statusCaption: caption,
            cursor: nil,
            hasUnseenError: false,
            agentName: "Claude Code")
    }

    /// The handback case from the bug report: both ownership buttons are on the
    /// pill, and the caption is long enough to have pushed them off screen.
    func testLongCaptionKeepsPillInsideThePane() {
        let size = NSSize(width: 1000, height: 700)
        let overlay = makeOverlay(size: size, ownership: .user, caption: longCaption)

        let pill = overlay.controlPillFrameForTesting
        XCTAssertGreaterThanOrEqual(pill.minX, 16, "pill spills past the pane's leading edge")
        XCTAssertLessThanOrEqual(pill.maxX, size.width - 16,
                                 "pill spills past the pane's trailing edge")
        XCTAssertLessThanOrEqual(pill.width, 720, "pill grew past its line-length cap")
    }

    /// A pane narrower than the line-length cap clamps on the pane instead.
    func testNarrowPaneClampsThePill() {
        let size = NSSize(width: 460, height: 600)
        let overlay = makeOverlay(size: size, ownership: .user, caption: longCaption)

        let pill = overlay.controlPillFrameForTesting
        XCTAssertGreaterThanOrEqual(pill.minX, 16)
        XCTAssertLessThanOrEqual(pill.maxX, size.width - 16)
    }

    /// Watch mode overflowed the same way — one button, same unbounded caption.
    func testLongCaptionKeepsPillInsideThePaneWhileTheAgentDrives() {
        let size = NSSize(width: 1000, height: 700)
        let overlay = makeOverlay(size: size, ownership: .agent, caption: longCaption)

        let pill = overlay.controlPillFrameForTesting
        XCTAssertGreaterThanOrEqual(pill.minX, 16)
        XCTAssertLessThanOrEqual(pill.maxX, size.width - 16)
    }

    /// The pane resizes constantly — window resize, sidebar toggle, split view.
    /// Nothing recomputes the pill on those; it has to fall out of the layout.
    func testPillFollowsAPaneResize() {
        let overlay = makeOverlay(size: NSSize(width: 1000, height: 700),
                                  ownership: .user, caption: longCaption)

        for width in [1600.0, 520.0, 900.0, 460.0, 1200.0] as [CGFloat] {
            resize(overlay, toWidth: width)
            let pill = overlay.controlPillFrameForTesting
            XCTAssertGreaterThanOrEqual(pill.minX, 16, "spills leading at \(width)pt")
            XCTAssertLessThanOrEqual(pill.maxX, width - 16, "spills trailing at \(width)pt")
            XCTAssertLessThanOrEqual(pill.width, 720, "past the cap at \(width)pt")
            XCTAssertEqual(pill.midX, width / 2, accuracy: 1, "off centre at \(width)pt")
        }
    }

    /// Clamping must not stretch the ordinary case: a short caption still gets
    /// a pill sized to its content, centered in the pane.
    func testShortCaptionKeepsThePillCompact() {
        let size = NSSize(width: 1000, height: 700)
        let overlay = makeOverlay(size: size, ownership: .agent, caption: "Reading results…")

        let pill = overlay.controlPillFrameForTesting
        XCTAssertLessThan(pill.width, 600, "short caption should not fill the pane")
        XCTAssertEqual(pill.midX, size.width / 2, accuracy: 1, "pill should stay centered")
    }

    // MARK: - Minimise

    /// Minimised: only the ownership buttons survive, parked in the corner.
    func testCollapsedPillKeepsOnlyTheOwnershipButtons() {
        let size = NSSize(width: 1000, height: 700)
        let overlay = makeOverlay(size: size, ownership: .user, caption: longCaption)
        overlay.toggleCollapsedForTesting()
        overlay.layoutSubtreeIfNeeded()

        XCTAssertEqual(overlay.controlPillVisibleItemsForTesting, ["Hand back", "Finish"])
        let pill = overlay.controlPillFrameForTesting
        XCTAssertEqual(pill.maxX, size.width - 24, accuracy: 1, "should park in the corner")
        XCTAssertLessThan(pill.width, 220, "collapsed pill should be button-sized")
    }

    /// Watch mode collapses to the one button that matters there.
    func testCollapsedPillInWatchModeKeepsTakeControl() {
        let overlay = makeOverlay(size: NSSize(width: 1000, height: 700),
                                  ownership: .agent, caption: longCaption)
        overlay.toggleCollapsedForTesting()
        overlay.layoutSubtreeIfNeeded()

        XCTAssertEqual(overlay.controlPillVisibleItemsForTesting, ["Take control"])
    }

    /// Collapsing is the user's choice, so a later status update — or an
    /// ownership flip — must not quietly re-expand the pill over their page.
    func testCollapseSurvivesUpdatesAndOwnershipFlips() {
        let size = NSSize(width: 1000, height: 700)
        let overlay = makeOverlay(size: size, ownership: .agent, caption: "Reading results…")
        overlay.toggleCollapsedForTesting()

        overlay.update(with: task(ownership: .user, caption: longCaption))
        overlay.layoutSubtreeIfNeeded()

        XCTAssertEqual(overlay.controlPillVisibleItemsForTesting, ["Hand back", "Finish"])
        XCTAssertEqual(overlay.controlPillFrameForTesting.maxX, size.width - 24, accuracy: 1)
    }

    /// Expanding puts it back where it was: centred, caption and badge on.
    func testExpandingRestoresTheFullPill() {
        let size = NSSize(width: 1000, height: 700)
        let overlay = makeOverlay(size: size, ownership: .user, caption: longCaption)
        overlay.toggleCollapsedForTesting()
        overlay.toggleCollapsedForTesting()
        overlay.layoutSubtreeIfNeeded()

        XCTAssertEqual(overlay.controlPillVisibleItemsForTesting,
                       ["badge", "caption", "Hand back", "Finish"])
        let pill = overlay.controlPillFrameForTesting
        XCTAssertEqual(pill.midX, size.width / 2, accuracy: 1)
        XCTAssertLessThanOrEqual(pill.width, 720)
    }

    /// The collapsed pill rides a resize too — it stays in the corner.
    func testCollapsedPillFollowsAPaneResize() {
        let overlay = makeOverlay(size: NSSize(width: 1000, height: 700),
                                  ownership: .user, caption: longCaption)
        overlay.toggleCollapsedForTesting()

        for width in [1600.0, 520.0, 460.0] as [CGFloat] {
            resize(overlay, toWidth: width)
            let pill = overlay.controlPillFrameForTesting
            XCTAssertEqual(pill.maxX, width - 24, accuracy: 1, "off the corner at \(width)pt")
            XCTAssertGreaterThanOrEqual(pill.minX, 16, "spills leading at \(width)pt")
        }
    }

    /// The fold must never reach the ownership buttons. Squeezing the pill
    /// itself used to compress the row, so "Hand back" shrank on the way in
    /// and sprang back at the end.
    func testOwnershipButtonKeepsItsSizeThroughTheFold() {
        let overlay = makeOverlay(size: NSSize(width: 1000, height: 700),
                                  ownership: .user, caption: longCaption)
        let expanded = overlay.controlPillPrimaryButtonFrameForTesting.width

        for step in stride(from: 0.0, through: 1.0, by: 0.125) {
            overlay.setFoldProgressForTesting(CGFloat(step))
            XCTAssertEqual(overlay.controlPillPrimaryButtonFrameForTesting.width,
                           expanded, accuracy: 0.5,
                           "button resized \(Int(step * 100))% through the fold")
        }
    }

    /// Writes a PNG of the pill for a visual check when
    /// `PHI_OVERLAY_SNAPSHOT_DIR` is set; a no-op in an ordinary test run.
    func testSnapshotForVisualReview() throws {
        guard let dir = ProcessInfo.processInfo.environment["PHI_OVERLAY_SNAPSHOT_DIR"] else {
            throw XCTSkip("PHI_OVERLAY_SNAPSHOT_DIR not set")
        }
        let cases: [(String, NSSize, AgentTaskOwnership, String)] = [
            ("handback-long-caption", NSSize(width: 1000, height: 220), .user, longCaption),
            ("watch-long-caption", NSSize(width: 1000, height: 220), .agent, longCaption),
            ("handback-short-caption", NSSize(width: 1000, height: 220), .user, "Waiting for you to sign in"),
            ("narrow-pane", NSSize(width: 460, height: 220), .user, longCaption),
            ("resize-1400", NSSize(width: 1400, height: 140), .user, longCaption),
            ("resize-900", NSSize(width: 900, height: 140), .user, longCaption),
            ("resize-620", NSSize(width: 620, height: 140), .user, longCaption),
            ("collapsed-handback", NSSize(width: 1000, height: 140), .user, longCaption),
            ("collapsed-watch", NSSize(width: 1000, height: 140), .agent, longCaption),
        ]
        for (name, size, ownership, caption) in cases {
            let overlay = makeOverlay(size: size, ownership: ownership, caption: caption)
            if name.hasPrefix("collapsed-") {
                overlay.toggleCollapsedForTesting()
                overlay.layoutSubtreeIfNeeded()
            }
            guard let host = overlay.superview,
                  let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                XCTFail("could not build a bitmap for \(name)")
                return
            }
            host.cacheDisplay(in: host.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
            try png.write(to: url)
        }
    }
}

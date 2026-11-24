// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

final class SidebarActiveTabArrowResolverTests: XCTestCase {
    private let visibleRect = CGRect(x: 0, y: 76, width: 240, height: 400)

    func testRowAboveVisibleAreaPointsUp() {
        XCTAssertEqual(SidebarActiveTabArrowResolver.edge(
            activeRowRect: CGRect(x: 0, y: 40, width: 240, height: 36),
            unobscuredVisibleRect: visibleRect), .top)
    }

    func testRowBelowVisibleAreaPointsDown() {
        XCTAssertEqual(SidebarActiveTabArrowResolver.edge(
            activeRowRect: CGRect(x: 0, y: 476, width: 240, height: 36),
            unobscuredVisibleRect: visibleRect), .bottom)
    }

    func testPartlyVisibleRowShowsNoArrow() {
        XCTAssertNil(SidebarActiveTabArrowResolver.edge(
            activeRowRect: CGRect(x: 0, y: 60, width: 240, height: 36),
            unobscuredVisibleRect: visibleRect))
        XCTAssertNil(SidebarActiveTabArrowResolver.edge(
            activeRowRect: CGRect(x: 0, y: 460, width: 240, height: 36),
            unobscuredVisibleRect: visibleRect))
    }

    func testNoActiveRowShowsNoArrow() {
        XCTAssertNil(SidebarActiveTabArrowResolver.edge(
            activeRowRect: nil, unobscuredVisibleRect: visibleRect))
    }

    func testClipEndsAtTheStickyNewTabBar() {
        let clip = SidebarActiveTabArrowResolver.clipRect(
            visibleRect: CGRect(x: 0, y: 100, width: 240, height: 400), overlayHeight: 36,
            newTabRowRect: CGRect(x: 0, y: 600, width: 240, height: 36), newTabAtTop: false)
        XCTAssertEqual(clip, CGRect(x: 0, y: 100, width: 240, height: 364))
    }

    func testClipEndsAtTheNewTabRowOnceItScrollsIntoView() {
        let clip = SidebarActiveTabArrowResolver.clipRect(
            visibleRect: CGRect(x: 0, y: 100, width: 240, height: 400), overlayHeight: 0,
            newTabRowRect: CGRect(x: 0, y: 450, width: 240, height: 36), newTabAtTop: false)
        XCTAssertEqual(clip, CGRect(x: 0, y: 100, width: 240, height: 350))
    }

    func testClipStartsBelowTheNewTabRowAtTheTop() {
        let sticky = SidebarActiveTabArrowResolver.clipRect(
            visibleRect: CGRect(x: 0, y: 100, width: 240, height: 400), overlayHeight: 36,
            newTabRowRect: CGRect(x: 0, y: 20, width: 240, height: 36), newTabAtTop: true)
        XCTAssertEqual(sticky, CGRect(x: 0, y: 136, width: 240, height: 364))
        let scrolledIn = SidebarActiveTabArrowResolver.clipRect(
            visibleRect: CGRect(x: 0, y: 100, width: 240, height: 400), overlayHeight: 0,
            newTabRowRect: CGRect(x: 0, y: 120, width: 240, height: 36), newTabAtTop: true)
        XCTAssertEqual(scrolledIn, CGRect(x: 0, y: 156, width: 240, height: 344))
    }

    func testBottomStripSitsAboveStickyNewTabRow() {
        // The unobscured rect already leaves out a 36 pt sticky row at the
        // bottom of an unflipped container.
        let frame = SidebarActiveTabArrowResolver.stripFrame(
            unobscuredRect: CGRect(x: 0, y: 36, width: 240, height: 364),
            edge: .bottom, containerIsFlipped: false)
        XCTAssertEqual(frame, CGRect(x: 0, y: 36, width: 240, height: 36))
    }

    func testTopStripSitsAtTopOfUnobscuredRect() {
        let frame = SidebarActiveTabArrowResolver.stripFrame(
            unobscuredRect: CGRect(x: 0, y: 0, width: 240, height: 364),
            edge: .top, containerIsFlipped: false)
        XCTAssertEqual(frame, CGRect(x: 0, y: 328, width: 240, height: 36))
    }

    func testStripFollowsFlippedContainer() {
        let frame = SidebarActiveTabArrowResolver.stripFrame(
            unobscuredRect: CGRect(x: 0, y: 36, width: 240, height: 364),
            edge: .top, containerIsFlipped: true)
        XCTAssertEqual(frame, CGRect(x: 0, y: 36, width: 240, height: 36))
    }

    func testStripNeverTallerThanTheList() {
        let frame = SidebarActiveTabArrowResolver.stripFrame(
            unobscuredRect: CGRect(x: 0, y: 0, width: 240, height: 20),
            edge: .bottom, containerIsFlipped: false)
        XCTAssertEqual(frame.height, 20)
    }
}

@MainActor
final class SidebarActiveTabArrowViewTests: XCTestCase {
    private func makeView() -> SidebarActiveTabArrowView {
        SidebarActiveTabArrowView(frame: CGRect(x: 0, y: 0, width: 240, height: 36))
    }

    private func button(in view: SidebarActiveTabArrowView) throws -> NSButton {
        try XCTUnwrap(view.subviews.compactMap { $0 as? NSButton }.first)
    }

    func testHiddenArrowTakesNoClicks() {
        let view = makeView()
        view.setEdge(nil, animated: false)
        XCTAssertTrue(view.isHidden)
        XCTAssertNil(view.edge)
        XCTAssertNil(view.hitTest(CGPoint(x: 120, y: 18)))
    }

    func testShownArrowIsALabelledButton() throws {
        let view = makeView()
        view.setEdge(.top, animated: false)
        XCTAssertFalse(view.isHidden)
        XCTAssertEqual(view.edge, .top)
        XCTAssertEqual(try button(in: view).accessibilityLabel(), "Show Active Tab")
    }

    func testStripOutsideTheButtonPassesClicksToTheRows() throws {
        let view = makeView()
        view.setEdge(.bottom, animated: false)
        view.layoutSubtreeIfNeeded()
        let button = try button(in: view)
        XCTAssertNil(view.hitTest(CGPoint(x: 2, y: 18)))
        XCTAssertNotNil(view.hitTest(CGPoint(x: button.frame.midX, y: button.frame.midY)))
    }

    func testArrowPointsTheWayOfItsEdge() throws {
        let view = makeView()
        view.setEdge(.top, animated: false)
        let up = try button(in: view).image
        view.setEdge(.bottom, animated: false)
        let down = try button(in: view).image
        XCTAssertNotNil(up)
        XCTAssertNotNil(down)
        XCTAssertFalse(up === down)
    }

    func testSameEdgeDoesNotRestartTheSlide() throws {
        let view = makeView()
        view.setEdge(.bottom, animated: false)
        let button = try button(in: view)
        let frame = button.frame
        view.setEdge(.bottom, animated: true, reduceMotion: false)
        XCTAssertEqual(button.frame, frame)
    }

    private func crossing(_ type: NSEvent.EventType) throws -> NSEvent {
        try XCTUnwrap(NSEvent.enterExitEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                                             windowNumber: 0, context: nil, eventNumber: 0,
                                             trackingNumber: 0, userData: nil))
    }

    func testPointerOverTheButtonReportsHoverAndHidingEndsIt() throws {
        let view = makeView()
        var states: [Bool] = []
        view.hoverStateChanged = { states.append($0) }
        view.setEdge(.top, animated: false)
        view.mouseEntered(with: try crossing(.mouseEntered))
        XCTAssertEqual(states, [true])
        view.setEdge(nil, animated: false)
        XCTAssertEqual(states, [true, false], "hiding under the pointer must end the hover")
        view.mouseExited(with: try crossing(.mouseExited))
        XCTAssertEqual(states, [true, false])
    }

    func testCircleIsStrongTextAndArrowUsesArrowFill() throws {
        let view = makeView()
        view.setEdge(.top, animated: false)
        XCTAssertEqual(view.paletteColors.count, 2, "[arrow, circle]")
        let arrow = try XCTUnwrap(view.paletteColors.first)
        let circle = try XCTUnwrap(view.paletteColors.last)
        XCTAssertEqual(arrow, SidebarActiveTabArrowView.arrowFill.resolve(in: view))
        XCTAssertEqual(circle, ThemedColor.textPrimaryStrong.resolve(in: view))
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            try XCTUnwrap(NSAppearance(named: name)).performAsCurrentDrawingAppearance {
                XCTAssertEqual(circle.usingColorSpace(.sRGB)?.alphaComponent ?? 0, 1, accuracy: 0.001, "\(name.rawValue)")
            }
        }
    }

    func testArrowIsTheOppositeModesPrimaryTextColor() throws {
        let theme = ThemeManager.shared.currentTheme
        XCTAssertEqual(SidebarActiveTabArrowView.arrowFill.resolver(theme, .dark),
                       theme.color(for: .textPrimary, appearance: .light))
        XCTAssertEqual(SidebarActiveTabArrowView.arrowFill.resolver(theme, .light),
                       theme.color(for: .textPrimary, appearance: .dark))
    }

    func testArrowIsDrawnAt24Points() throws {
        let view = makeView()
        view.setEdge(.bottom, animated: false)
        let button = try button(in: view)
        let image = try XCTUnwrap(button.image)
        XCTAssertGreaterThanOrEqual(image.size.height, 24)
        XCTAssertGreaterThanOrEqual(button.frame.height, image.size.height)
        XCTAssertLessThanOrEqual(button.frame.height, SidebarActiveTabArrowResolver.stripHeight)
    }

    func testArrowRestsInItsStripAndLeavesPastTheClipEdge() throws {
        let view = SidebarActiveTabArrowView(frame: CGRect(x: 0, y: 0, width: 240, height: 200))
        view.stripRect = CGRect(x: 0, y: 40, width: 240, height: 36)
        view.clipRect = CGRect(x: 0, y: 40, width: 240, height: 160)
        view.setEdge(.bottom, animated: false)
        let button = try button(in: view)
        XCTAssertEqual(button.frame.midY, 58, accuracy: 0.5, "centered in the strip")
        XCTAssertEqual(view.layer?.mask?.frame, view.clipRect)
        view.setEdge(nil, animated: true, reduceMotion: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        XCTAssertEqual(button.frame.maxY, 40, accuracy: 0.5, "slides out past the clip edge")
    }

    func testClickRunsTheAction() throws {
        let view = makeView()
        var clicks = 0
        view.clickAction = { clicks += 1 }
        view.setEdge(.top, animated: false)
        try button(in: view).performClick(nil)
        XCTAssertEqual(clicks, 1)
    }
}

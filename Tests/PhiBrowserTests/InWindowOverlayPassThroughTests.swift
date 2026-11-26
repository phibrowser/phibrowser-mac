// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

/// An in-window overlay (the omnibox, tab search) is drawn over controls in
/// the same window. Neither its clicks nor hover tooltips may reach the
/// control it covers.
@MainActor
final class InWindowOverlayPassThroughTests: XCTestCase {
    private final class MouseRecorderView: NSView {
        private(set) var received: [NSEvent.EventType] = []

        override func mouseDown(with event: NSEvent) { received.append(event.type) }
        override func mouseDragged(with event: NSEvent) { received.append(event.type) }
        override func mouseUp(with event: NSEvent) { received.append(event.type) }
    }

    /// Mirrors the SwiftUI tooltip anchor, which never takes a hit.
    private final class HitTransparentView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    private var windows: [NSWindow] = []
    private var tooltipHosts: [NSView] = []

    override func tearDown() {
        tooltipHosts.forEach { $0.removeCustomTooltip() }
        tooltipHosts.removeAll()
        windows.forEach { $0.close() }
        windows.removeAll()
        super.tearDown()
    }

    // MARK: - Backdrop clicks

    func testBackdropDoesNotForwardMouseUpToTheCoveredView() throws {
        let (window, covered, backdrop) = makeCoveredFixture()

        backdrop.mouseUp(with: try mouseEvent(.leftMouseUp, at: center(of: covered), in: window))

        XCTAssertEqual(covered.received, [])
    }

    func testBackdropDoesNotForwardMouseDownToTheCoveredView() throws {
        let (window, covered, backdrop) = makeCoveredFixture()

        backdrop.mouseDown(with: try mouseEvent(.leftMouseDown, at: center(of: covered), in: window))

        XCTAssertEqual(covered.received, [])
    }

    func testBackdropDoesNotForwardMouseDraggedToTheCoveredView() throws {
        let (window, covered, backdrop) = makeCoveredFixture()

        backdrop.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: center(of: covered), in: window))

        XCTAssertEqual(covered.received, [])
    }

    func testBackdropStillReportsMouseDownToItsOwner() throws {
        let (window, covered, backdrop) = makeCoveredFixture()
        var reported: [NSEvent.EventType] = []
        backdrop.mouseDown = { reported.append($0.type) }

        backdrop.mouseDown(with: try mouseEvent(.leftMouseDown, at: center(of: covered), in: window))

        XCTAssertEqual(reported, [.leftMouseDown])
    }

    // MARK: - Tooltips under an overlay

    func testTooltipDoesNotShowForAnAnchorCoveredByABackdrop() throws {
        let (window, contentView) = makeWindow()
        let anchor = NSView(frame: CGRect(x: 40, y: 40, width: 120, height: 32))
        contentView.addSubview(anchor)
        let backdrop = EventBlockBgView(frame: contentView.bounds)
        backdrop.addSubview(NSView(frame: backdrop.bounds))
        contentView.addSubview(backdrop)
        let registration = installTooltip(on: anchor)

        try enter(anchor, registration: registration, in: window)

        XCTAssertFalse(registration.isHovering)
    }

    func testTooltipShowsWhereTheBackdropPassesClicksThrough() throws {
        let (window, contentView) = makeWindow()
        let anchor = NSView(frame: CGRect(x: 40, y: 40, width: 120, height: 32))
        contentView.addSubview(anchor)
        let backdrop = EventBlockBgView(frame: contentView.bounds)
        let box = NSView(frame: CGRect(x: 220, y: 180, width: 120, height: 80))
        backdrop.addSubview(box)
        backdrop.clickThroughOutside = { box }
        contentView.addSubview(backdrop)
        let registration = installTooltip(on: anchor)

        try enter(anchor, registration: registration, in: window)

        XCTAssertTrue(registration.isHovering)
    }

    func testTooltipShowsForAnAnchorInsideTheBackdrop() throws {
        let (window, contentView) = makeWindow()
        let backdrop = EventBlockBgView(frame: contentView.bounds)
        let anchor = NSView(frame: CGRect(x: 40, y: 40, width: 120, height: 32))
        backdrop.addSubview(anchor)
        contentView.addSubview(backdrop)
        let registration = installTooltip(on: anchor)

        try enter(anchor, registration: registration, in: window)

        XCTAssertTrue(registration.isHovering)
    }

    func testTooltipShowsForAHitTransparentAnchorWithoutAnOverlay() throws {
        let (window, contentView) = makeWindow()
        let host = NSView(frame: CGRect(x: 40, y: 40, width: 120, height: 32))
        let anchor = HitTransparentView(frame: host.bounds)
        host.addSubview(anchor)
        contentView.addSubview(host)
        let registration = installTooltip(on: anchor)

        try enter(anchor, registration: registration, in: window)

        XCTAssertTrue(registration.isHovering)
    }

    // MARK: - Fixtures

    private func makeWindow() -> (NSWindow, NSView) {
        let window = NSWindow(
            contentRect: CGRect(x: 100, y: 100, width: 400, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let contentView = NSView(frame: CGRect(origin: .zero, size: window.frame.size))
        window.contentView = contentView
        windows.append(window)
        return (window, contentView)
    }

    private func makeCoveredFixture() -> (NSWindow, MouseRecorderView, EventBlockBgView) {
        let (window, contentView) = makeWindow()
        let covered = MouseRecorderView(frame: CGRect(x: 40, y: 40, width: 120, height: 32))
        contentView.addSubview(covered)
        let backdrop = EventBlockBgView(frame: contentView.bounds)
        contentView.addSubview(backdrop)
        return (window, covered, backdrop)
    }

    private func installTooltip(on view: NSView) -> CustomTooltipRegistration {
        view.setCustomTooltip("Tooltip")
        tooltipHosts.append(view)
        return view.customTooltipRegistration!
    }

    private func center(of view: NSView) -> NSPoint {
        let rect = view.convert(view.bounds, to: nil)
        return NSPoint(x: rect.midX, y: rect.midY)
    }

    private func enter(
        _ anchor: NSView,
        registration: CustomTooltipRegistration,
        in window: NSWindow
    ) throws {
        let event = try XCTUnwrap(NSEvent.enterExitEvent(
            with: .mouseEntered,
            location: center(of: anchor),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            trackingNumber: 0,
            userData: nil
        ))
        registration.perform(NSSelectorFromString("mouseEntered:"), with: event)
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
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1
        ))
    }
}

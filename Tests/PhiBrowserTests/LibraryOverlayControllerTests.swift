// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

@MainActor
final class LibraryOverlayControllerTests: XCTestCase {
    private var directory: URL?
    private var store: LocalStore?

    override func tearDown() async throws {
        try await store?.closeForAccountDirectoryRemoval()
        store = nil
        if let directory { try FileManager.default.removeItem(at: directory) }
        directory = nil
        try await super.tearDown()
    }

    func testHoverFilteringBlocksOnlyConfirmedBackgroundAreas() {
        let content = NSView()
        let tab = NSView()
        let overlay = NSView()
        let libraryButton = NSView()
        content.addSubview(tab)
        content.addSubview(overlay)
        overlay.addSubview(libraryButton)
        let privateOwner = NSObject()
        let backgroundArea = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways], owner: privateOwner)
        let libraryArea = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways], owner: privateOwner)
        tab.addTrackingArea(backgroundArea)
        libraryButton.addTrackingArea(libraryArea)

        XCTAssertTrue(LibraryOverlayController.isBackgroundTrackingArea(backgroundArea, in: content, overlay: overlay))
        XCTAssertFalse(LibraryOverlayController.isBackgroundTrackingArea(libraryArea, in: content, overlay: overlay))
        XCTAssertFalse(LibraryOverlayController.isBackgroundTrackingArea(nil, in: content, overlay: overlay))

        // Private SwiftUI tracking events need not appear in a view's area list.
        let privateArea = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways], owner: privateOwner)
        XCTAssertFalse(LibraryOverlayController.isBackgroundTrackingArea(privateArea, in: content, overlay: overlay))
        content.addTrackingArea(privateArea)
        XCTAssertFalse(LibraryOverlayController.isBackgroundTrackingArea(privateArea, in: content, overlay: overlay))
        libraryButton.removeFromSuperview()
        XCTAssertFalse(LibraryOverlayController.isBackgroundTrackingArea(libraryArea, in: content, overlay: overlay))
    }

    func testFlightStartsAtAvatarForBothLayerAnchorsAndLayoutPositions() {
        let card = CGRect(x: 32, y: 32, width: 1100, height: 740)
        for origin in [CGRect(x: 24, y: 20, width: 24, height: 24),
                       CGRect(x: 1100, y: 790, width: 24, height: 24)] {
            for anchor in [CGPoint.zero, CGPoint(x: 0.5, y: 0.5)] {
                let transform = LibraryOverlayController.flightTransform(card: card, origin: origin, anchorPoint: anchor)
                let centerX = card.minX + card.width * anchor.x + (card.width / 2 - card.width * anchor.x) * transform.m11 + transform.m41
                let centerY = card.minY + card.height * anchor.y + (card.height / 2 - card.height * anchor.y) * transform.m22 + transform.m42
                XCTAssertEqual(centerX, origin.midX, accuracy: 0.001)
                XCTAssertEqual(centerY, origin.midY, accuracy: 0.001)
                XCTAssertLessThan(transform.m11, 1)
            }
        }
    }

    func testOverlayUsesParentViewAndRestoresFocusWithoutChildWindows() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        let store = LocalStore(account: Account(userID: UUID().uuidString), storeDirectoryURL: directory)
        self.store = store
        let state = BrowserState(windowId: UUID().hashValue, localStore: store, profileId: "Default")
        let parent = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 650),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        defer { parent.close() }
        let content = try XCTUnwrap(parent.contentView)
        let source = NSButton(frame: NSRect(x: 24, y: 20, width: 24, height: 24))
        content.addSubview(source)
        parent.makeKeyAndOrderFront(nil)
        parent.makeFirstResponder(source)
        let previousResponder = parent.firstResponder
        let controller = LibraryOverlayController(parent: parent, browserState: state)
        controller.show(from: source, animated: false)
        controller.show(from: source, animated: false)
        XCTAssertTrue(controller.isVisible)
        XCTAssertTrue(parent.childWindows?.isEmpty ?? true)
        XCTAssertEqual(content.subviews.count, 2)
        let overlay = try XCTUnwrap(content.subviews.last)
        XCTAssertEqual(overlay.frame, content.bounds)
        parent.setContentSize(NSSize(width: 1100, height: 750))
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(overlay.frame, content.bounds)
        controller.dismiss(animated: false)
        XCTAssertFalse(controller.isVisible)
        XCTAssertTrue(parent.firstResponder === previousResponder)
        XCTAssertEqual(content.subviews.count, 1)
        controller.show(from: source, animated: false)
        parent.close()
        XCTAssertFalse(controller.isVisible)
    }

    func testBlankContentClickKeepsLibraryOpenButScrimClickDismisses() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        let store = LocalStore(account: Account(userID: UUID().uuidString), storeDirectoryURL: directory)
        self.store = store
        let state = BrowserState(windowId: UUID().hashValue, localStore: store, profileId: "Default")
        let parent = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 650),
                              styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        defer { parent.close() }
        let content = try XCTUnwrap(parent.contentView)
        let source = NSButton(frame: NSRect(x: 20, y: 20, width: 24, height: 24))
        content.addSubview(source)
        parent.makeKeyAndOrderFront(nil)
        let controller = LibraryOverlayController(parent: parent, browserState: state)
        controller.show(from: source, animated: false)
        let overlay = try XCTUnwrap(content.subviews.last)
        let card = try XCTUnwrap(overlay.subviews.first)

        func click(_ point: NSPoint) throws {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: .leftMouseDown, location: overlay.convert(point, to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: parent.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            // Reproduce an unhandled hosting-view click reaching the overlay.
            overlay.mouseDown(with: event)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        }

        try click(NSPoint(x: card.frame.midX, y: card.frame.midY))
        XCTAssertTrue(controller.isVisible, "Blank Library content must not dismiss the overlay")
        try click(NSPoint(x: 8, y: overlay.bounds.midY))
        XCTAssertFalse(controller.isVisible, "The scrim outside the Library card must dismiss it")
    }

    func testReopeningDuringDismissalKeepsOverlayMounted() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        let store = LocalStore(account: Account(userID: UUID().uuidString), storeDirectoryURL: directory)
        self.store = store
        let state = BrowserState(windowId: UUID().hashValue, localStore: store, profileId: "Default")
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        defer { parent.close() }
        let source = NSButton(frame: NSRect(x: 20, y: 20, width: 24, height: 24))
        parent.contentView?.addSubview(source)
        parent.makeKeyAndOrderFront(nil)
        let controller = LibraryOverlayController(parent: parent, browserState: state)
        controller.show(from: source, animated: false)
        controller.dismiss()
        controller.show(from: source, animated: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(controller.isVisible)
        controller.dismiss(animated: false)
    }
}

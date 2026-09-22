// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SwiftUI
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

    func testStandaloneBlankClickEndsEditingAndKeepsWindowOpen() throws {
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
        let controller = LibraryWindowController(parent: parent, browserState: state)
        defer { controller.close() }
        controller.present()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let window = try XCTUnwrap(controller.window)
        let module = try XCTUnwrap(window.contentViewController as? LibraryViewModule)
        func searchField(in view: NSView) -> NSSearchField? {
            if let field = view as? NSSearchField { return field }
            return view.subviews.lazy.compactMap { searchField(in: $0) }.first
        }
        let search = try XCTUnwrap(searchField(in: module.view))
        search.stringValue = "report"
        XCTAssertTrue(window.makeFirstResponder(search))
        XCTAssertNotNil(search.currentEditor())

        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 700, y: 400),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        // Exercise propagation from the hosting view through its controllers.
        module.view.mouseDown(with: event)

        XCTAssertNil(search.currentEditor())
        XCTAssertEqual(search.stringValue, "report")
        XCTAssertTrue(window.firstResponder === module)
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(window.makeFirstResponder(search))
        XCTAssertNotNil(search.currentEditor(), "Controls must remain focusable after a blank click")
    }

    func testDownloadCopyButtonEndsSearchEditingBeforeAction() throws {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var query = "report"
        var copied = false
        weak var search: NSSearchField?
        let host = NSHostingController(rootView: HStack {
            DownloadsSearchField(text: Binding(get: { query }, set: { query = $0 }))
                .frame(width: 240, height: 32)
            DownloadCopyLinkButton(action: {
                XCTAssertNil(search?.currentEditor(), "Editing must end before the button action")
                copied = true
            }, tooltip: "Copy Link")
        }.frame(width: 400, height: 100))
        window.contentViewController = host
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        func findSearch(in view: NSView) -> NSSearchField? {
            if let field = view as? NSSearchField { return field }
            return view.subviews.lazy.compactMap { findSearch(in: $0) }.first
        }
        search = try XCTUnwrap(findSearch(in: host.view))
        XCTAssertTrue(window.makeFirstResponder(search))
        XCTAssertNotNil(search?.currentEditor())
        let field = try XCTUnwrap(search)
        let frame = field.convert(field.bounds, to: nil)
        let point = NSPoint(x: frame.maxX + 20, y: frame.midY)
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point,
            modifierFlags: [], timestamp: down.timestamp + 0.1,
            windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        NSApp.postEvent(up, atStart: true)
        NSApp.postEvent(down, atStart: true)
        while let event = NSApp.nextEvent(matching: [.leftMouseDown, .leftMouseUp],
                                         until: Date().addingTimeInterval(0.2),
                                         inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(copied)
        XCTAssertNil(field.currentEditor())
        XCTAssertEqual(query, "report")
        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertNotNil(field.currentEditor())
    }

    func testFolioStaysInsideDetailWhenSidebarResizesAndCollapses() throws {
        let parent = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1200, height: 650),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        defer { parent.close() }
        let host = NSHostingController(rootView:
            NavigationSplitView {
                Text("Sidebar").navigationSplitViewColumnWidth(min: 64, ideal: 200, max: 240)
            } detail: {
                FolioLibraryView(model: FolioLibraryModel(profileId: UUID().uuidString),
                                 openURL: { _ in }, openArchive: { _ in }, reveal: { _ in })
                    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
            .navigationSplitViewStyle(.balanced)
        )
        let content = try XCTUnwrap(parent.contentView)
        host.view.frame = content.bounds
        host.view.autoresizingMask = [.width, .height]
        content.addSubview(host.view)
        parent.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        func splits(in view: NSView) -> [NSSplitView] {
            let current = (view as? NSSplitView).map { [$0] } ?? []
            return current + view.subviews.flatMap { splits(in: $0) }
        }
        let nativeSplits = splits(in: host.view)
        XCTAssertEqual(nativeSplits.count, 2)
        let outer = try XCTUnwrap(nativeSplits.first)
        let folio = try XCTUnwrap(nativeSplits.last)
        let controller = try XCTUnwrap(outer.delegate as? NSSplitViewController)
        let sidebar = try XCTUnwrap(controller.splitViewItems.first)

        for width: CGFloat in [200, 240, 140] {
            outer.setPosition(width, ofDividerAt: 0)
            for collapsed in [false, true, false] {
                sidebar.isCollapsed = collapsed
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                let frame = folio.convert(folio.bounds, to: outer)
                let sidebarFrame = sidebar.viewController.view.convert(sidebar.viewController.view.bounds, to: outer)
                let leading = collapsed ? outer.bounds.minX : sidebarFrame.maxX
                XCTAssertGreaterThanOrEqual(frame.minX, leading - 0.5, "Folio must not extend under the Library sidebar")
                XCTAssertLessThanOrEqual(frame.minX, leading + 2, "Folio must follow the sidebar without a stale inset")
                XCTAssertEqual(frame.maxX, outer.bounds.maxX, accuracy: 2)
            }
        }
    }

    func testStandaloneSidebarResizesWithoutToolbarOrContentInsets() throws {
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
        parent.makeKeyAndOrderFront(nil)
        let controller = LibraryWindowController(parent: parent, browserState: state)
        defer { controller.close() }
        controller.present()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let window = try XCTUnwrap(controller.window)
        let module = try XCTUnwrap(window.contentViewController as? LibraryViewModule)
        controller.present(section: .spaces)
        XCTAssertEqual(module.navigationState.selection, .spaces)
        controller.present(section: .downloads)
        XCTAssertEqual(module.navigationState.selection, .downloads)
        let content = try XCTUnwrap(window.contentView)
        XCTAssertTrue(parent.childWindows?.isEmpty ?? true)
        XCTAssertFalse(window.toolbar?.isVisible ?? false, "Standalone Library must not show a toolbar")
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))

        let split = try XCTUnwrap(nativeSplit(in: content))
        let splitController = try XCTUnwrap(split.delegate as? NSSplitViewController)
        let sidebar = try XCTUnwrap(splitController.splitViewItems.first)
        func searchField(in view: NSView) -> NSSearchField? {
            if let field = view as? NSSearchField { return field }
            return view.subviews.lazy.compactMap { searchField(in: $0) }.first
        }
        let search = try XCTUnwrap(searchField(in: content))
        for width: CGFloat in [200, 100, 80, 64, 200, 64] {
            split.setPosition(width, ofDividerAt: 0)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            XCTAssertFalse(sidebar.isCollapsed)
            XCTAssertEqual(sidebar.viewController.view.frame.width, width, accuracy: 1)
            XCTAssertEqual(sidebar.minimumThickness, 64)
            XCTAssertEqual(sidebar.maximumThickness, 240)
        }
        splitController.toggleSidebar(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertTrue(sidebar.isCollapsed)
        splitController.toggleSidebar(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertFalse(sidebar.isCollapsed)
        XCTAssertEqual(sidebar.viewController.view.frame.width, 64, accuracy: 1)

        for size in [NSSize(width: 1120, height: 780), NSSize(width: 900, height: 650)] {
            window.setContentSize(size)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            let frame = split.convert(split.bounds, to: nil)
            let contentFrame = content.convert(content.bounds, to: nil)
            XCTAssertEqual(frame.minX, contentFrame.minX, accuracy: 1)
            XCTAssertEqual(frame.maxX, contentFrame.maxX, accuracy: 1)
            XCTAssertEqual(frame.minY, contentFrame.minY, accuracy: 1)
            XCTAssertEqual(frame.maxY, contentFrame.maxY, accuracy: 1)
            let visibleFrame = split.convert(split.visibleRect, to: nil)
            XCTAssertEqual(visibleFrame.minY, contentFrame.minY, accuracy: 1)
            XCTAssertEqual(visibleFrame.maxY, contentFrame.maxY, accuracy: 1,
                           "Standalone Library must remain visible beneath the title bar")
            let searchFrame = search.convert(search.bounds, to: nil)
            XCTAssertGreaterThan(searchFrame.maxY, window.contentLayoutRect.maxY,
                                 "Library content must extend into the transparent title bar")
            XCTAssertEqual(search.visibleRect.intersection(search.bounds).height, search.bounds.height, accuracy: 1,
                           "The title bar must not clip the search field")
        }

        controller.close()
        XCTAssertNil(window.contentViewController)
        controller.present()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(controller.window === window)
        XCTAssertFalse(window.toolbar?.isVisible ?? false, "Reopening Library must not restore a toolbar")
        XCTAssertNotNil(nativeSplit(in: try XCTUnwrap(window.contentView)))
        splitController.toggleSidebar(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertTrue(sidebar.isCollapsed)
    }

    private func nativeSplit(in view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView { return split }
        return view.subviews.lazy.compactMap { self.nativeSplit(in: $0) }.first
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
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertNil(nativeSplit(in: overlay), "Embedded Library must not expose a draggable sidebar")
        XCTAssertNil(parent.toolbar, "Embedded Library must not add a sidebar toggle to the browser toolbar")
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

    func testDismissEndsSearchEditingBeforeAnimationAndPreservesFocusOwnership() throws {
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
        let otherControl = NSTextField(frame: NSRect(x: 60, y: 20, width: 200, height: 24))
        content.addSubview(source)
        content.addSubview(otherControl)
        parent.makeKeyAndOrderFront(nil)
        XCTAssertTrue(parent.makeFirstResponder(source))
        let controller = LibraryOverlayController(parent: parent, browserState: state)
        controller.show(from: source, animated: false)
        let overlay = try XCTUnwrap(content.subviews.last)
        let search = NSSearchField(frame: NSRect(x: 50, y: 50, width: 240, height: 32))
        overlay.addSubview(search)
        search.stringValue = "report"
        XCTAssertTrue(parent.makeFirstResponder(search))
        XCTAssertNotNil(search.currentEditor())

        controller.dismiss()

        XCTAssertTrue(controller.isVisible, "The card stays mounted during its exit animation")
        XCTAssertNil(search.currentEditor(), "Search editing must end before the exit animation")
        XCTAssertEqual(search.stringValue, "report")
        XCTAssertTrue(parent.firstResponder === overlay)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertFalse(controller.isVisible)
        XCTAssertTrue(parent.firstResponder === source)

        controller.show(from: source, animated: false)
        XCTAssertTrue(parent.makeFirstResponder(search))
        controller.dismiss()
        XCTAssertTrue(parent.makeFirstResponder(otherControl))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertFalse(controller.isVisible)
        XCTAssertNotNil(otherControl.currentEditor(), "Dismissal must not steal newly assigned focus")
        XCTAssertTrue(parent.firstResponder === otherControl.currentEditor())
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

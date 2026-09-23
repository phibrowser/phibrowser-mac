// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

@MainActor
final class ImagePreviewWindowTests: XCTestCase {
    private final class Loader: ImagePreviewLoading {
        var cancellationCount = 0

        func load(_ item: ImagePreviewItem) async throws -> ImagePreviewAsset {
            throw ImagePreviewError.fileNotFound
        }

        func preloadAdjacentItems(around items: [ImagePreviewItem], currentIndex: Int) {}
        func cancelCurrentLoad() { cancellationCount += 1 }
    }

    private let items = ImagePreviewItem.items(fromAddressStrings: ["/tmp/preview-a.png", "/tmp/preview-b.png"])

    func testOverlayPreservesSidebarWidthAndResizingInWideWindows() throws {
        let split = NSSplitViewController()
        split.splitView = PhiSplitView()
        split.splitView.isVertical = true
        let sidebar = NSViewController()
        sidebar.view = NSView()
        let sidebarItem = NSSplitViewItem(viewController: sidebar)
        sidebarItem.minimumThickness = MainSplitViewController.leftItemMinWidth
        sidebarItem.maximumThickness = MainSplitViewController.leftItemMaxWidth
        sidebarItem.holdingPriority = ShellSplitViewController.sidebarHoldingPriority
        split.addSplitViewItem(sidebarItem)

        let content = NSViewController()
        content.view = NSView()
        let contentItem = NSSplitViewItem(contentListWithViewController: content)
        contentItem.holdingPriority = ShellSplitViewController.contentHoldingPriority
        split.addSplitViewItem(contentItem)

        let overlay = ImagePreviewOverlayViewController(state: BrowserImagePreviewState(loader: Loader()))
        content.addChild(overlay)
        overlay.view.translatesAutoresizingMaskIntoConstraints = false
        content.view.addSubview(overlay.view)
        NSLayoutConstraint.activate([
            overlay.view.leadingAnchor.constraint(equalTo: content.view.leadingAnchor),
            overlay.view.trailingAnchor.constraint(equalTo: content.view.trailingAnchor),
            overlay.view.topAnchor.constraint(equalTo: content.view.topAnchor),
            overlay.view.bottomAnchor.constraint(equalTo: content.view.bottomAnchor),
        ])
        let panel = try XCTUnwrap(overlay.children.first?.view.superview)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 1000),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        split.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 1000)
        window.contentViewController = split
        window.contentView?.layoutSubtreeIfNeeded()
        split.splitView.setPosition(250, ofDividerAt: 0)

        // Hidden previews remain in the layout tree of every hosted Space.
        // Both hidden and visible panels must yield when their size is capped.
        for hidden in [true, false] {
            overlay.view.isHidden = hidden
            for width: CGFloat in [1000, 1920, 2560, 1000] {
                window.setContentSize(NSSize(width: width, height: 1000))
                window.contentView?.layoutSubtreeIfNeeded()
                XCTAssertEqual(sidebar.view.frame.width, 250, accuracy: 0.5)

                for sidebarWidth: CGFloat in [500, 193, 250] {
                    split.splitView.setPosition(sidebarWidth, ofDividerAt: 0)
                    window.contentView?.layoutSubtreeIfNeeded()
                    XCTAssertEqual(sidebar.view.frame.width, sidebarWidth, accuracy: 0.5)
                    XCTAssertEqual(panel.frame.width, min(content.view.bounds.width * 0.84, 1080), accuracy: 0.5)
                    XCTAssertEqual(panel.frame.height, min(content.view.bounds.height * 0.84, 820), accuracy: 0.5)
                }
            }
        }
    }

    func testOverlayEntryOpensIndependentWindowAtCurrentImage() throws {
        let source = BrowserImagePreviewState(loader: Loader())
        source.open(items: items, currentIndex: 1)
        let overlay = ImagePreviewOverlayViewController(state: source)
        _ = overlay.view
        let preview = try XCTUnwrap(overlay.children.first as? ImagePreviewViewController)
        let open = try XCTUnwrap(preview.onOpenInWindow)
        open()

        let controller = try XCTUnwrap(NSApp.windows.compactMap {
            $0.windowController as? ImagePreviewWindowController
        }.first)
        defer { controller.close() }
        XCTAssertFalse(source.isVisible)
        XCTAssertEqual(controller.state.items, items)
        XCTAssertEqual(controller.state.currentIndex, 1)

        source.open(items: [items[0]], currentIndex: 0)
        source.close()
        XCTAssertTrue(controller.state.isVisible)
        XCTAssertEqual(controller.state.items, items)
        controller.state.showPrevious()
        XCTAssertEqual(controller.state.currentIndex, 0)
    }

    func testKeyboardNavigationAndEscapeCloseStandaloneWindow() throws {
        let loader = Loader()
        let controller = ImagePreviewWindowController(items: items, currentIndex: 0, loader: loader)
        controller.showWindow(nil)
        defer { controller.close() }
        XCTAssertEqual(controller.window?.contentView?.frame.size, NSSize(width: 960, height: 720))
        let preview = try XCTUnwrap(controller.contentViewController as? ImagePreviewViewController)
        XCTAssertNil(preview.onOpenInWindow)
        XCTAssertTrue(preview.handleKeyDown(key(124)))
        XCTAssertEqual(controller.state.currentIndex, 1)
        XCTAssertFalse(preview.handleKeyDown(key(123, modifiers: .command)))
        XCTAssertEqual(controller.state.currentIndex, 1)
        XCTAssertTrue(preview.handleKeyDown(key(123)))
        XCTAssertEqual(controller.state.currentIndex, 0)
        XCTAssertTrue(preview.handleKeyDown(key(53)))
        XCTAssertFalse(controller.state.isVisible)
        XCTAssertFalse(try XCTUnwrap(controller.window).isVisible)
        XCTAssertEqual(loader.cancellationCount, 1)
    }

    func testWindowRetainsControllerUntilClosed() throws {
        weak var retainedController: ImagePreviewWindowController?
        autoreleasepool {
            let controller = ImagePreviewWindowController(items: items, currentIndex: 0, loader: Loader())
            controller.showWindow(nil)
            retainedController = controller
        }
        XCTAssertNotNil(retainedController)
        autoreleasepool {
            retainedController?.close()
        }
        XCTAssertNil(retainedController)
    }

    private func key(_ code: UInt16, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: code
        )!
    }
}

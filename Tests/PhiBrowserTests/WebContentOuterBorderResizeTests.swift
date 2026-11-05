// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

/// In the comfortable layout the page container strokes one outline around
/// the active tab and the page card. It recomputes that outline in its
/// `viewDidLayout`, reading the card's frame two levels down. AppKit lays a
/// tree out top-down, so in that callback the card still has its frame from
/// the previous pass: after a one-shot height change (a step of a window-edge
/// drag, a programmatic `setFrame`) the outline's top edge sat where
/// the card's top used to be, and the active tab's sides ran down through
/// the page to meet it. A window whose tab strip relaid out in the same
/// pass (one showing the Space picker) recomputed again with the settled
/// frame and hid the defect; a standalone Incognito window and a single-Space
/// window did not.
@MainActor
final class WebContentOuterBorderResizeTests: XCTestCase {

    private var tempDirectories: [URL] = []
    private var windows: [NSWindow] = []
    private var previousLayout: Any?

    override func setUpWithError() throws {
        previousLayout = UserDefaults.standard.object(forKey: PhiPreferences.GeneralSettings.layoutModeKey)
        PhiPreferences.GeneralSettings.saveLayoutMode(.comfortable)
    }

    override func tearDownWithError() throws {
        windows.forEach { $0.close() }
        windows.removeAll()
        UserDefaults.standard.set(previousLayout, forKey: PhiPreferences.GeneralSettings.layoutModeKey)
        previousLayout = nil
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    func testOutlineFollowsTheCardTopAfterAHeightOnlyResize() throws {
        let (container, window) = try makeMountedContainer()
        try assertOutlineStartsAtTheCardTop(container.contentOuterBorderPathForTesting,
                                            of: container, "before the resize")

        // The first recompute after the resize is the one the user sees: a
        // window whose tab strip does not relayout (no Space picker, as
        // here) gets no later one. The hook catches it before any pass a
        // SwiftUI subview might add on this host could paper over it.
        var firstPathAfterResize: CGPath?
        container.contentOuterBorderDidUpdateForTesting = { path in
            if firstPathAfterResize == nil { firstPathAfterResize = path }
        }
        // Grows within any screen: AppKit clamps a window to the visible
        // frame, which would shrink or even cancel a larger step.
        window.setContentSize(NSSize(width: 1200, height: 800))
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        container.contentOuterBorderDidUpdateForTesting = nil

        try assertOutlineStartsAtTheCardTop(firstPathAfterResize, of: container,
                                            "on the first recompute after growing 300pt taller")
        try assertOutlineStartsAtTheCardTop(container.contentOuterBorderPathForTesting,
                                            of: container, "once the resize settled")
    }

    // MARK: - Helpers

    /// The outline encloses the card, so a point just inside the card's
    /// top-left corner is inside the path only when the path's top edge is
    /// the card's current top; a point just above that corner, left of the
    /// active tab, is outside either way.
    private func assertOutlineStartsAtTheCardTop(_ path: CGPath?,
                                                of container: WebContentContainerViewController,
                                                _ when: String,
                                                file: StaticString = #filePath,
                                                line: UInt = #line) throws {
        let controller = try XCTUnwrap(
            container.children.lazy.compactMap { $0 as? WebContentViewController }.first,
            "no tab controller mounted \(when)", file: file, line: line)
        let path = try XCTUnwrap(path, "no outline \(when)", file: file, line: line)
        let card = controller.splitViewContainerFrame(in: container.view)
        let x = card.minX + LiquidGlassCompatible.webContentContainerCornerRadius + 2
        XCTAssertTrue(path.contains(CGPoint(x: x, y: card.maxY - 1)),
                      "outline does not reach the card's top edge \(when): card \(card), "
                      + "outline \(path.boundingBox)", file: file, line: line)
        XCTAssertFalse(path.contains(CGPoint(x: x, y: card.maxY + 2)),
                       "outline extends above the card beside the tab strip \(when)",
                       file: file, line: line)
    }

    /// One tab in a visible 1200x500 window, mounted.
    private func makeMountedContainer() throws -> (WebContentContainerViewController, NSWindow) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        let store = LocalStore(account: Account(userID: UUID().uuidString),
                               storeDirectoryURL: directory)
        let state = BrowserState(windowId: 13, localStore: store, profileId: "Default")

        let webView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let wrapper = PageColorTestWebContentWrapper(urlString: "https://tab.example/")
        wrapper.nativeView = webView
        let tab = Tab(guid: 910, url: wrapper.urlString, isActive: true, index: 0,
                      webContentView: wrapper)
        state.tabs = [tab]
        state.updateNormalTabs()
        state.focusingTab = tab

        let container = WebContentContainerViewController(state: state)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 500),
                              styleMask: [.titled, .resizable],
                              backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        window.contentViewController = container
        window.orderFront(nil)

        let deadline = Date().addingTimeInterval(2)
        while webView.window == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        _ = try XCTUnwrap(webView.window, "the tab was never mounted")
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        return (container, window)
    }
}

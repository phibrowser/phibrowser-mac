// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

/// A page entering content fullscreen is lifted out of the page container
/// into an overlay over the window. Over a content surface (chromium ADR
/// 0014) the surface's view goes into that overlay first, under the page's
/// host view, so the lifted web views keep drawing through it instead of
/// leaving the surface for a compositor of their own; on exit the surface
/// comes back above the page-area backdrop and the host view to its place.
/// `ContentSurfaceHosting` tells the lifted web views square corners while
/// they are up there, and their rounded ones again on exit.
@MainActor
final class ContentFullscreenSurfaceTests: XCTestCase {

    private var tempDirectories: [URL] = []
    private var windows: [NSWindow] = []

    override func tearDownWithError() throws {
        windows.forEach { $0.close() }
        windows.removeAll()
        let fileManager = FileManager.default
        for directory in tempDirectories {
            try? fileManager.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    func testTheSurfaceGoesIntoTheOverlayUnderTheLiftedHostView() throws {
        let fixture = try makeFixture()
        let surface = adoptSurface(fixture)
        let hostView = try hostView(fixture)
        let home = try XCTUnwrap(surface.superview)

        enterFullscreen(fixture)

        let overlay = try XCTUnwrap(hostView.superview)
        XCTAssertTrue(overlay.superview === fixture.window.contentView, "the overlay covers the window")
        XCTAssertFalse(overlay === home)
        XCTAssertTrue(surface.superview === overlay, "the surface went up with the page")
        let surfaceIndex = try XCTUnwrap(overlay.subviews.firstIndex(of: surface))
        let hostIndex = try XCTUnwrap(overlay.subviews.firstIndex(of: hostView))
        XCTAssertLessThan(surfaceIndex, hostIndex, "the surface lies under the host view")
        fixture.window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(overlay.frame, fixture.window.contentView?.bounds)
        XCTAssertEqual(surface.frame, overlay.bounds)
        XCTAssertEqual(hostView.frame, overlay.bounds)
    }

    func testOnExitTheSurfaceAndTheHostViewReturnWhereTheyWere() throws {
        let fixture = try makeFixture()
        let surface = adoptSurface(fixture)
        let hostView = try hostView(fixture)
        let home = try XCTUnwrap(surface.superview)
        let homeIndex = try XCTUnwrap(home.subviews.firstIndex(of: surface))
        let hostHome = try XCTUnwrap(hostView.superview)
        let hostIndex = try XCTUnwrap(hostHome.subviews.firstIndex(of: hostView))
        let windowSubviews = fixture.window.contentView?.subviews.count
        enterFullscreen(fixture)
        weak var overlay = hostView.superview
        XCTAssertNotNil(overlay)

        exitFullscreen(fixture)

        XCTAssertTrue(surface.superview === home, "the surface is back in the page container")
        XCTAssertEqual(home.subviews.firstIndex(of: surface), homeIndex,
                       "the surface is back above the page-area backdrop")
        XCTAssertTrue(hostView.superview === hostHome)
        XCTAssertEqual(hostHome.subviews.firstIndex(of: hostView), hostIndex)
        XCTAssertEqual(fixture.window.contentView?.subviews.count, windowSubviews, "the overlay is gone")
        XCTAssertNil(overlay?.superview)
    }

    func testTheLiftedPageIsToldSquareCornersAndItsRoundedOnesAgainOnExit() throws {
        let fixture = try makeFixture()
        _ = adoptSurface(fixture)
        let hosting = try XCTUnwrap(fixture.container.contentSurfaceHostingForTesting)
        var sends: [(address: NSObject, hosting: ContentSurfaceHosting.Hosting)] = []
        hosting.sendForTesting = { sends.append(($0, $1)) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let page = fixture.wrappers[0]
        func lastSent() -> ContentSurfaceHosting.Hosting? {
            sends.last { $0.address === page }?.hosting
        }
        let rounded = try XCTUnwrap(lastSent(), "precondition: the page was told its corners")
        XCTAssertGreaterThan(max(rounded.topLeft, rounded.topRight, rounded.bottomRight, rounded.bottomLeft), 0,
                             "precondition: the page has a rounded corner")

        enterFullscreen(fixture)
        let lifted = try XCTUnwrap(lastSent())
        XCTAssertEqual([lifted.topLeft, lifted.topRight, lifted.bottomRight, lifted.bottomLeft], [0, 0, 0, 0],
                       "the lifted page is square")

        exitFullscreen(fixture)
        XCTAssertEqual(lastSent(), rounded, "the page has its corners back")
    }

    /// Chromium's exit never reaches a tab that closes in fullscreen: the
    /// controller is torn down with its page still lifted.
    func testTheOverlayGoesWithItsPageAndTheSurfaceComesHomeWhenTheTabCloses() throws {
        let fixture = try makeFixture()
        let surface = adoptSurface(fixture)
        let hostView = try hostView(fixture)
        let home = try XCTUnwrap(surface.superview)
        let windowSubviews = fixture.window.contentView?.subviews.count
        enterFullscreen(fixture)
        weak var overlay = hostView.superview
        XCTAssertNotNil(overlay)

        fixture.state.tabs = [fixture.tabs[1]]
        fixture.state.updateNormalTabs()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertTrue(surface.superview === home, "the surface is back in the page container")
        XCTAssertEqual(fixture.window.contentView?.subviews.count, windowSubviews, "the overlay is gone")
        XCTAssertNil(overlay?.superview)
    }

    // MARK: - Helpers

    private struct Fixture {
        let state: BrowserState
        let container: WebContentContainerViewController
        let window: NSWindow
        let tabs: [Tab]
        let wrappers: [PageColorTestWebContentWrapper]
        /// Held here: a wrapper's `nativeView` is weak.
        let webViews: [NSView]
    }

    /// Two tabs in a visible window, the first one focused and mounted, with
    /// no surface yet.
    private func makeFixture() throws -> Fixture {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        tempDirectories.append(directory)
        let store = LocalStore(account: Account(userID: UUID().uuidString),
                               storeDirectoryURL: directory)
        let state = BrowserState(windowId: 14, localStore: store, profileId: "Default")

        let webViews = (0..<2).map { _ in
            NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        }
        let wrappers = webViews.enumerated().map { index, webView in
            let wrapper = PageColorTestWebContentWrapper(urlString: "https://tab\(index).example/")
            wrapper.nativeView = webView
            return wrapper
        }
        let tabs = wrappers.enumerated().map { index, wrapper in
            Tab(guid: 970 + index, url: wrapper.urlString, isActive: index == 0,
                index: index, webContentView: wrapper)
        }
        state.tabs = tabs
        state.updateNormalTabs()
        state.focusingTab = tabs[0]

        let container = WebContentContainerViewController(state: state)
        container.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                              styleMask: [.titled, .resizable],
                              backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        window.contentViewController = container
        window.orderFront(nil)
        try waitUntilMounted(webViews[0])
        return Fixture(state: state, container: container, window: window, tabs: tabs,
                       wrappers: wrappers, webViews: webViews)
    }

    /// Installs a surface, as Chromium's arrival does, synchronously.
    private func adoptSurface(_ fixture: Fixture) -> NSView {
        let surface = NSView()
        fixture.state.adoptContentSurface(surface)
        return surface
    }

    /// The mounted page's host view, the view lifted into content fullscreen.
    private func hostView(_ fixture: Fixture,
                          file: StaticString = #filePath,
                          line: UInt = #line) throws -> NSView {
        let page = try XCTUnwrap(
            fixture.container.children.compactMap { $0 as? WebContentViewController }.first,
            "no page is mounted", file: file, line: line)
        return page.hostViewForTesting
    }

    /// The bridge's fullscreen event lands on the tab; the page controller
    /// follows it on the main queue.
    private func enterFullscreen(_ fixture: Fixture) {
        fixture.tabs[0].isInContentFullscreen = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    private func exitFullscreen(_ fixture: Fixture) {
        fixture.tabs[0].isInContentFullscreen = false
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    private func waitUntilMounted(_ webView: NSView,
                                  file: StaticString = #filePath,
                                  line: UInt = #line) throws {
        let deadline = Date().addingTimeInterval(2)
        while webView.window == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        _ = try XCTUnwrap(webView.window, "the view was never mounted", file: file, line: line)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }
}

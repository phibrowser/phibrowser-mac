// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

/// A content surface (chromium ADR 0014) is installed below every page of
/// the page container, and a page painting its own vibrancy backdrop would
/// cover it. A hosted Space instance's pages never paint one; once a surface
/// reaches a window that paints its own backdrop, a standalone Incognito
/// window (chromium ADR 0016), its pages and placeholder shell stop painting
/// theirs too, while the container's own root view, below the surface, keeps
/// painting. Without a surface nothing changes.
@MainActor
final class ContentSurfaceBackdropTests: XCTestCase {

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

    /// The standalone Incognito window: the container paints its backdrop,
    /// and so do its pages until the surface arrives.
    func testPagesOverASurfaceStopPaintingTheirBackdropWhileTheContainerKeepsIts() throws {
        let fixture = try makeFixture()
        let mountedPage = try pageRoot(above: fixture.webViews[0], in: fixture.container)
        XCTAssertFalse(mountedPage.suppressesBackdrop,
                       "precondition: without a surface the page paints its backdrop")
        XCTAssertFalse(try containerRoot(fixture).suppressesBackdrop)

        fixture.state.adoptContentSurface(NSView())
        XCTAssertTrue(fixture.container.hasContentSurface)

        XCTAssertTrue(mountedPage.suppressesBackdrop,
                      "a page mounted before the surface paints no backdrop over it")
        XCTAssertFalse(try containerRoot(fixture).suppressesBackdrop,
                       "the container's own root view, below the surface, still paints")

        // A page created after the install.
        fixture.state.focusingTab = fixture.tabs[1]
        try waitUntilMounted(fixture.webViews[1])
        XCTAssertTrue(try pageRoot(above: fixture.webViews[1], in: fixture.container).suppressesBackdrop,
                      "a page created after the surface paints no backdrop over it")

        // The placeholder shell, created after the install.
        let placeholderView = try enterPlaceholderMode(fixture)
        XCTAssertTrue(try pageRoot(above: placeholderView, in: fixture.container).suppressesBackdrop,
                      "the placeholder shell paints no backdrop over the surface")
        XCTAssertFalse(try containerRoot(fixture).suppressesBackdrop)
    }

    /// With the feature off no window receives a surface: the pages, the
    /// placeholder shell and the container paint as before.
    func testWithoutASurfaceThePagesAndTheContainerPaintAsBefore() throws {
        let fixture = try makeFixture()
        XCTAssertFalse(fixture.container.hasContentSurface)

        XCTAssertFalse(try pageRoot(above: fixture.webViews[0], in: fixture.container).suppressesBackdrop)
        XCTAssertFalse(try containerRoot(fixture).suppressesBackdrop)

        fixture.state.focusingTab = fixture.tabs[1]
        try waitUntilMounted(fixture.webViews[1])
        XCTAssertFalse(try pageRoot(above: fixture.webViews[1], in: fixture.container).suppressesBackdrop)

        let placeholderView = try enterPlaceholderMode(fixture)
        XCTAssertFalse(try pageRoot(above: placeholderView, in: fixture.container).suppressesBackdrop)
        XCTAssertFalse(try containerRoot(fixture).suppressesBackdrop)
    }

    /// A hosted Space instance's container and pages paint nothing (the
    /// shell's page-area host does), with or without a surface.
    func testAHostedContainerPaintsNothingWithOrWithoutASurface() throws {
        let fixture = try makeFixture(hosted: true)
        let mountedPage = try pageRoot(above: fixture.webViews[0], in: fixture.container)
        XCTAssertTrue(mountedPage.suppressesBackdrop)
        XCTAssertTrue(try containerRoot(fixture).suppressesBackdrop)

        fixture.state.adoptContentSurface(NSView())
        XCTAssertTrue(fixture.container.hasContentSurface)

        XCTAssertTrue(mountedPage.suppressesBackdrop)
        XCTAssertTrue(try containerRoot(fixture).suppressesBackdrop)
        let placeholderView = try enterPlaceholderMode(fixture)
        XCTAssertTrue(try pageRoot(above: placeholderView, in: fixture.container).suppressesBackdrop)
    }

    // MARK: - Helpers

    private struct Fixture {
        let state: BrowserState
        let container: WebContentContainerViewController
        let window: NSWindow
        let tabs: [Tab]
        /// Held here: a wrapper's `nativeView` is weak.
        let webViews: [NSView]
    }

    /// Two tabs in a visible window, the first one focused and mounted. A
    /// hosted container is told it paints no backdrop before it is shown, as
    /// `MainSplitViewController.setupHostedContent` does.
    private func makeFixture(hosted: Bool = false) throws -> Fixture {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        tempDirectories.append(directory)
        let store = LocalStore(account: Account(userID: UUID().uuidString),
                               storeDirectoryURL: directory)
        let state = BrowserState(windowId: 13, localStore: store, profileId: "Default")

        let webViews = (0..<2).map { _ in
            NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        }
        let tabs = webViews.enumerated().map { index, webView in
            let wrapper = PageColorTestWebContentWrapper(urlString: "https://tab\(index).example/")
            wrapper.nativeView = webView
            return Tab(guid: 950 + index, url: wrapper.urlString, isActive: index == 0,
                       index: index, webContentView: wrapper)
        }
        state.tabs = tabs
        state.updateNormalTabs()
        state.focusingTab = tabs[0]

        let container = WebContentContainerViewController(state: state)
        if hosted {
            container.paintsOwnBackdrop = false
        }
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
                       webViews: webViews)
    }

    /// Closes every tab and enters placeholder mode; returns the placeholder
    /// web view, mounted by the container's synchronous placeholder sink.
    private func enterPlaceholderMode(_ fixture: Fixture,
                                      file: StaticString = #filePath,
                                      line: UInt = #line) throws -> NSView {
        fixture.state.tabs = []
        fixture.state.updateNormalTabs()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let placeholderView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let wrapper = PageColorTestWebContentWrapper(urlString: "chrome://placeholder/")
        wrapper.nativeView = placeholderView
        fixture.state.enterPlaceholderMode(wrapper: wrapper)
        try waitUntilMounted(placeholderView, file: file, line: line)
        return placeholderView
    }

    /// The root view of the page or placeholder shell that holds `webView`:
    /// the outermost `ColoredVisualEffectView` between the web view and the
    /// container's own root view.
    private func pageRoot(above webView: NSView,
                          in container: WebContentContainerViewController,
                          file: StaticString = #filePath,
                          line: UInt = #line) throws -> ColoredVisualEffectView {
        var root: ColoredVisualEffectView?
        var view = webView.superview
        while let current = view, current !== container.view {
            if let effectView = current as? ColoredVisualEffectView {
                root = effectView
            }
            view = current.superview
        }
        return try XCTUnwrap(root, "no page root above the web view", file: file, line: line)
    }

    private func containerRoot(_ fixture: Fixture,
                               file: StaticString = #filePath,
                               line: UInt = #line) throws -> ColoredVisualEffectView {
        try XCTUnwrap(fixture.container.view as? ColoredVisualEffectView,
                      "the container's root view is not a ColoredVisualEffectView",
                      file: file, line: line)
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

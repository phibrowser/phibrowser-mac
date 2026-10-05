// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

/// The page container's mount (mac ADR 0011) puts a tab's web view into the
/// window already at the page area's size. A web view resized after it
/// joined makes Chromium embed the new size with a zero deadline, and the
/// grown strip shows the gutter until the page's next frame.
@MainActor
final class WebContentMountGeometryTests: XCTestCase {

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

    /// A background tab that was never shown (opened with Cmd-click next to
    /// docked DevTools, say) gets its controller on its first focus.
    func testNeverShownTabJoinsTheWindowAtThePageAreaSize() throws {
        let fixture = try makeFixture()
        let incoming = fixture.webViews[1]

        fixture.state.focusingTab = fixture.tabs[1]
        try waitUntilMounted(incoming)

        try assertJoinedAtFinalSize(incoming)
    }

    /// A tab mounted before keeps its view tree while away; if the window was
    /// resized meanwhile, it rejoins at the new page area size.
    func testRemountedTabJoinsTheWindowAtTheResizedPageAreaSize() throws {
        let fixture = try makeFixture()
        let outgoing = fixture.webViews[0]
        fixture.state.focusingTab = fixture.tabs[1]
        try waitUntilMounted(fixture.webViews[1])
        XCTAssertNil(outgoing.window)

        let sizeBeforeResize = outgoing.frame.size
        fixture.window.setContentSize(NSSize(width: 1000, height: 640))
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        fixture.state.focusingTab = fixture.tabs[0]
        try waitUntilMounted(outgoing)

        // Precondition: the resize changed the page area.
        XCTAssertNotEqual(outgoing.frame.size, sizeBeforeResize)
        try assertJoinedAtFinalSize(outgoing)
    }

    // MARK: - Helpers

    private struct Fixture {
        let state: BrowserState
        let window: NSWindow
        let tabs: [Tab]
        /// Held here: a wrapper's `nativeView` is weak.
        let webViews: [MountGeometryProbeView]
    }

    /// Two tabs in a visible window, the first one mounted. Each web view
    /// starts at a size of its own, as Chromium sizes a background tab to the
    /// active tab's container.
    private func makeFixture() throws -> Fixture {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        tempDirectories.append(directory)
        let store = LocalStore(account: Account(userID: UUID().uuidString),
                               storeDirectoryURL: directory)
        let state = BrowserState(windowId: 12, localStore: store, profileId: "Default")

        let webViews = (0..<2).map { _ in
            MountGeometryProbeView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        }
        let tabs = webViews.enumerated().map { index, webView in
            let wrapper = PageColorTestWebContentWrapper(urlString: "https://tab\(index).example/")
            wrapper.nativeView = webView
            return Tab(guid: 900 + index, url: wrapper.urlString, isActive: index == 0,
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
        return Fixture(state: state, window: window, tabs: tabs, webViews: webViews)
    }

    /// Waits for `webView` to join the window, then lets the display cycle
    /// run, where a late layout would land.
    private func waitUntilMounted(_ webView: NSView,
                                  file: StaticString = #filePath,
                                  line: UInt = #line) throws {
        let deadline = Date().addingTimeInterval(2)
        while webView.window == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        _ = try XCTUnwrap(webView.window, "the tab was never mounted", file: file, line: line)
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
    }

    private func assertJoinedAtFinalSize(_ webView: MountGeometryProbeView,
                                         file: StaticString = #filePath,
                                         line: UInt = #line) throws {
        let pageArea = try XCTUnwrap(webView.superview, file: file, line: line).bounds.size
        XCTAssertGreaterThan(pageArea.height, 0, file: file, line: line)
        XCTAssertEqual(webView.sizesInWindow, [pageArea],
                       "sizes since joining the window: \(webView.timeline)",
                       file: file, line: line)
    }
}

/// Stands in for a tab's web view: records every size it takes from the
/// moment it joins a window.
private final class MountGeometryProbeView: NSView {
    private var entries: [(size: NSSize, uptime: TimeInterval)] = []

    var sizesInWindow: [NSSize] { entries.map(\.size) }

    var timeline: String {
        let start = entries.first?.uptime ?? 0
        return entries.map { entry in
            let ms = Int(((entry.uptime - start) * 1000).rounded())
            return "\(Int(entry.size.width))x\(Int(entry.size.height)) at +\(ms) ms"
        }.joined(separator: ", ")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        entries = []
        record()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard window != nil else { return }
        record()
    }

    private func record() {
        guard entries.last?.size != frame.size else { return }
        entries.append((frame.size, ProcessInfo.processInfo.systemUptime))
    }
}

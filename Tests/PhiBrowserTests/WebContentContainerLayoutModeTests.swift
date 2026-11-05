// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

/// The page container lays out its tab strip and page area for the layout
/// mode and page geometry preferences. Defaults notifications fire for every
/// key, so unrelated writes must not relay the page area out.
@MainActor
final class WebContentContainerLayoutModeTests: XCTestCase {

    private static let unrelatedKey = "WebContentContainerLayoutModeTests.unrelated"

    private var tempDirectories: [URL] = []
    private var windows: [NSWindow] = []
    private var states: [BrowserState] = []
    private var previousLayout: Any?

    override func setUpWithError() throws {
        previousLayout = UserDefaults.standard.object(forKey: PhiPreferences.GeneralSettings.layoutModeKey)
        PhiPreferences.GeneralSettings.saveLayoutMode(.performance)
    }

    override func tearDownWithError() throws {
        windows.forEach { $0.close() }
        windows.removeAll()
        states.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.unrelatedKey)
        UserDefaults.standard.set(previousLayout, forKey: PhiPreferences.GeneralSettings.layoutModeKey)
        previousLayout = nil
        let fileManager = FileManager.default
        for directory in tempDirectories {
            try? fileManager.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    func testWritingAnotherDefaultDoesNotRelayOutThePageArea() throws {
        let tabStripBar = try makeContainerTabStripBar()
        XCTAssertTrue(tabStripBar.isHidden, "precondition: performance hides the tab strip")

        // Undo the layout by hand; only a relayout puts it back.
        tabStripBar.isHidden = false
        UserDefaults.standard.set(UUID().uuidString, forKey: Self.unrelatedKey)
        drainMainQueue()

        XCTAssertFalse(tabStripBar.isHidden, "a write to another default relaid out the page area")
    }

    func testChangingTheLayoutModeRelaysOutThePageArea() throws {
        let tabStripBar = try makeContainerTabStripBar()

        PhiPreferences.GeneralSettings.saveLayoutMode(.comfortable)
        drainMainQueue()
        XCTAssertFalse(tabStripBar.isHidden, "comfortable shows the tab strip")

        PhiPreferences.GeneralSettings.saveLayoutMode(.performance)
        drainMainQueue()
        XCTAssertTrue(tabStripBar.isHidden, "performance hides it again")
    }

    // MARK: - Helpers

    /// A page container with no tabs, shown in a window; returns the view of
    /// its tab strip bar, which only the comfortable layout shows.
    private func makeContainerTabStripBar() throws -> NSView {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        tempDirectories.append(directory)
        let store = LocalStore(account: Account(userID: UUID().uuidString),
                               storeDirectoryURL: directory)
        let state = BrowserState(windowId: 17, localStore: store, profileId: "Default")
        states.append(state)

        let container = WebContentContainerViewController(state: state)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                              styleMask: [.titled, .resizable],
                              backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        window.contentViewController = container
        window.orderFront(nil)
        // The sidebar-collapse subscription relays out once, asynchronously.
        drainMainQueue()

        let tabStripBar = container.children.lazy
            .compactMap { $0 as? TabStripBarController }
            .first
        return try XCTUnwrap(tabStripBar, "the container built no tab strip bar").view
    }

    /// The container learns of a new mode on the main queue. Runs the loop
    /// until everything queued on it so far has run, a few rounds deep for
    /// chained hops: a fixed wait fell short while earlier tests' teardown
    /// was still draining. A round that does not drain within 2 s fails the
    /// test, or the negative case would pass on a relayout that never ran.
    private func drainMainQueue() {
        for _ in 0..<3 {
            let drained = expectation(description: "Main queue drained")
            DispatchQueue.main.async { drained.fulfill() }
            wait(for: [drained], timeout: 2)
        }
    }
}

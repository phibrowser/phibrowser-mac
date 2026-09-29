// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

@MainActor
final class SplitTabDragFocusTests: XCTestCase {
    private var storeDirectory: URL!
    private var state: BrowserState!
    private var window: NSWindow!
    private var container: SplitTabDropContainer!
    private var tabA: Tab!
    private var tabB: Tab!

    override func setUpWithError() throws {
        storeDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        let store = LocalStore(account: Account(userID: UUID().uuidString), storeDirectoryURL: storeDirectory)
        state = BrowserState(windowId: 8, localStore: store, profileId: "Default")
        tabA = Tab(guid: 100, url: "https://example.com/a", isActive: false, index: 0)
        tabB = Tab(guid: 101, url: "https://example.com/b", isActive: false, index: 1)
        state.tabs = [tabA, tabB]
        state.updateNormalTabs()
        state.focuseTab(tabA)
        container = SplitTabDropContainer(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        container.browserState = state
        window = NSWindow(contentRect: container.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
    }

    override func tearDownWithError() throws {
        state.tabDraggingSession.cancel()
        window.close()
        container = nil
        window = nil
        state = nil
        try FileManager.default.removeItem(at: storeDirectory)
    }

    private func beginDraggingB() {
        state.tabDraggingSession.recordFocusBeforeMouseDown()
        state.focuseTab(tabB)
        state.tabDraggingSession.begin(draggingItem: tabB, screenLocation: nil)
    }

    private func hover(_ point: CGPoint, count: Int = 1) -> Bool {
        container.isSplitDragContextValid(
            at: window.convertPoint(toScreen: point), draggedTabId: tabB.guid, draggedTabCount: count)
    }

    func testRestoresPartnerOnlyWhenDragEntersPageAndOnlyOnce() {
        beginDraggingB()
        XCTAssertEqual(state.focusingTab?.guid, tabB.guid)
        XCTAssertFalse(hover(CGPoint(x: -20, y: 300)))
        XCTAssertEqual(state.focusingTab?.guid, tabB.guid)
        XCTAssertTrue(hover(CGPoint(x: 450, y: 300)))
        XCTAssertEqual(state.focusingTab?.guid, tabA.guid)
        XCTAssertNil(state.tabDraggingSession.previousFocusedTabId)
        // Re-entry must not undo a later deliberate focus change.
        state.focuseTab(tabB)
        XCTAssertTrue(hover(CGPoint(x: 100, y: 300)))
        XCTAssertEqual(state.focusingTab?.guid, tabB.guid)
    }

    func testMultiTabDragDoesNotRestoreFocus() {
        beginDraggingB()
        XCTAssertFalse(hover(CGPoint(x: 100, y: 300), count: 2))
        XCTAssertEqual(state.focusingTab?.guid, tabB.guid)
    }

    func testDraggingAlreadyActiveTabPreservesFocus() {
        state.focuseTab(tabB)
        beginDraggingB()
        XCTAssertTrue(hover(CGPoint(x: 100, y: 300)))
        XCTAssertEqual(state.focusingTab?.guid, tabB.guid)
    }

    func testClosedPreviousTabIsNotRestored() {
        beginDraggingB()
        state.tabs = [tabB]
        state.updateNormalTabs()
        XCTAssertTrue(hover(CGPoint(x: 100, y: 300)))
        XCTAssertEqual(state.focusingTab?.guid, tabB.guid)
    }

    func testCancelledDragDoesNotLeakPartnerIntoNextDrag() {
        beginDraggingB()
        state.tabDraggingSession.cancel()
        state.tabDraggingSession.begin(draggingItem: tabB, screenLocation: nil)
        XCTAssertTrue(hover(CGPoint(x: 100, y: 300)))
        XCTAssertEqual(state.focusingTab?.guid, tabB.guid)
    }
}

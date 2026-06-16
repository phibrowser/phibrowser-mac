// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest

/// UI tests for the split-view flow.
///
/// Split view has no keyboard shortcut and no accessibility identifiers
/// today, so the test drives it through the only stable surface — the
/// sidebar tab cell's right-click menu.
///
/// Two complementary signals are used (WKWebView is NOT bridged as
/// `XCUIElement.ElementType.webView` on macOS, and Phi's `Splitter`
/// elements are zero-thickness, so neither is usable directly):
///
/// 1. `SplitGroup` count — each live tab's web content is hosted in its
///    own `PhiSplitView` (web view + optional AI Chat), so the count
///    equals (outer window split) + (one per live tab web-host). Opening
///    a split creates a second pane TAB, so the count rises by one. It
///    does NOT fall on "Remove from Split", because both panes survive
///    as independent tabs — so this is the signal for OPEN, not REMOVE.
///
/// 2. Sidebar row count — a split is shown as a single merged
///    "split-pair" row. "Remove from Split" turns that one row back into
///    two separate tab rows, so the row count rises by one. This is the
///    signal for REMOVE.
///
/// Each test resets to a deterministic single-tab state first
/// (`resetToSingleTab`) rather than trusting Phi's session restore.
final class SplitViewTests: XCTestCase {

    /// Launched once per class and reused across tests. A cold relaunch per
    /// test (Chromium cold start + session restore + Sentinel) dominated the
    /// suite's runtime; every test re-establishes a known state through
    /// `resetToSingleTab`, so a shared app is safe.
    private static var sharedApp: XCUIApplication!
    private var app: XCUIApplication { Self.sharedApp }

    override class func setUp() {
        super.setUp()
        launchSharedApp()
    }

    override class func tearDown() {
        sharedApp?.terminate()
        sharedApp = nil
        super.tearDown()
    }

    private static func launchSharedApp() {
        let app = XCUIApplication()
        // `--user-data-dir` (a `--` arg, which `ChromiumLauncher` forwards
        // straight to Chromium) gives the test an isolated profile so it
        // neither collides with a running Phi's process-singleton nor mutates
        // the real dev profile's tabs/bookmarks.
        app.launchArguments += [
            "-uitest", "1",
            // Unique per launch so a stale Chromium SingletonLock left by an
            // earlier (possibly hung) run can't make this launch hand off to a
            // dead instance.
            "--user-data-dir=\(NSTemporaryDirectory())PhiUITest-\(ProcessInfo.processInfo.globallyUniqueString)",
        ]
        app.launch()
        sharedApp = app
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        // Reuse the running app; relaunch only if a prior test crashed it.
        if Self.sharedApp == nil || Self.sharedApp.state == .notRunning {
            Self.launchSharedApp()
        }

        let window = app.windows.firstMatch
        // Cold launch is slow: Chromium cold start + session restore +
        // Sentinel can take well over 45s on the first test of a run. Later
        // tests reuse the already-running app, so this returns immediately.
        XCTAssertTrue(window.waitForExistence(timeout: 120),
                      "Main window did not appear (Phi cold start + session restore can be slow)")
        app.activate()
        // Dismiss any context menu / address field a prior failed test left open.
        app.typeKey(.escape, modifierFlags: [])
    }

    override func tearDownWithError() throws {
        // Intentionally NOT terminated — the app is reused across tests and
        // torn down once in `class func tearDown()`.
    }

    @MainActor
    func test_openAsSplit_addsInnerSplitGroup() throws {
        let baseline = try enterSplit()
        XCTAssertTrue(waitForSplitGroupCount(atLeast: baseline + 1, timeout: 15),
                      "Open-as-Split should add an inner SplitGroup")
        attachDiagnostics(label: "after-open-as-split")
    }

    @MainActor
    func test_removeFromSplit_collapsesBack() throws {
        let baseline = try enterSplit()
        XCTAssertTrue(waitForSplitGroupCount(atLeast: baseline + 1, timeout: 15),
                      "Open-as-Split should add an inner SplitGroup")
        // When split, the sidebar shows a single merged split-pair row.
        let rowsWhenSplit = sidebarCellCount()

        try runStep("Remove from Split") {
            try self.rightClickFocusedSidebarTab()
            try self.clickMenuItem(matching: ["Remove from Split"])
        }
        // Dissolving the split turns the one merged row into two separate
        // tab rows. The SplitGroup (web-host) count does NOT drop, because
        // both panes survive as independent live tabs — the sidebar row
        // count is the signal that the split itself dissolved.
        XCTAssertTrue(waitForSidebarCellCount(equalTo: rowsWhenSplit + 1, timeout: 15),
                      "Remove-from-Split should split the merged row into two tab rows")
        attachDiagnostics(label: "after-remove-from-split")
    }

    @MainActor
    func test_reversePanes_keepsSplit() throws {
        let baseline = try enterSplit()
        XCTAssertTrue(waitForSplitGroupCount(atLeast: baseline + 1, timeout: 15),
                      "Open-as-Split should add an inner SplitGroup")
        let split = currentSplitGroupCount()

        try runStep("Reverse Panes") {
            try self.rightClickFocusedSidebarTab()
            try self.clickMenuItem(matching: ["Reverse Panes"])
        }
        // Reverse Panes must swap panes without destroying one.
        XCTAssertTrue(waitForSplitGroupCount(equalTo: split, timeout: 5),
                      "Reverse Panes should keep the SplitGroup count unchanged")
        attachDiagnostics(label: "after-reverse-panes")
    }

    @MainActor
    func test_dragToFormSplit_addsSplit() throws {
        // Drag-to-split needs two tabs: a focused one (becomes a pane) and a
        // non-focused one to drag onto the page's right third.
        try runStep("Reset to two tabs") {
            try self.resetToSingleTab(url: "https://example.com")
            self.app.typeKey("t", modifierFlags: .command)   // second tab, becomes focused
            XCTAssertTrue(self.waitForSidebarCellCount(equalTo: 3, timeout: 10),
                          "Expected New Tab button + two tab rows")
        }
        let rowsBeforeDrag = sidebarCellCount()

        try runStep("Drag a sidebar tab onto the page right-third") {
            // Row 0 is the New Tab button; row 1 is the first real (non-focused) tab.
            let outline = self.app.windows.firstMatch.outlines["sidebarTabList"]
            try self.dragSidebarTabOntoPage(sourceCell: outline.cells.element(boundBy: 1),
                                            zone: .right)
        }
        // Drag-to-split pairs two EXISTING tabs, so the two separate tab
        // rows merge into a single split-pair row. (Unlike "Open as Split",
        // which spawns a new blank pane tab and so raises the SplitGroup
        // web-host count, drag-to-split adds no tab — the row count is the
        // signal.)
        XCTAssertTrue(waitForSidebarCellCount(equalTo: rowsBeforeDrag - 1, timeout: 15),
                      "Dragging a tab onto the page should merge two tab rows into one split-pair row")
        attachDiagnostics(label: "after-drag-to-split")
    }

    @MainActor
    func test_formSplitInTabGroup_createsSplitInGroup() throws {
        try runStep("Reset to single tab") {
            try self.resetToSingleTab(url: "https://example.com")
        }
        let baseline = currentSplitGroupCount()

        try runStep("Create a tab group from the tab") {
            try self.rightClickFocusedSidebarTab()
            try self.clickMenuItem(matching: ["New Tab Group"])
        }
        attachDiagnostics(label: "after-create-group")

        try runStep("Open as Split inside the group") {
            try self.rightClickFocusedSidebarTab()
            try self.clickMenuItem(matching: ["Open as Split", "Split with Current"])
        }
        XCTAssertTrue(waitForSplitGroupCount(atLeast: baseline + 1, timeout: 15),
                      "Forming a split inside a tab group should add an inner SplitGroup")
        attachDiagnostics(label: "after-split-in-group")
    }

    @MainActor
    func test_replacePaneInSplit_swapsDraggedTabIntoPane() throws {
        // Arrange: a focused split plus a third standalone tab to drag in.
        let baseline = try enterSplit()
        XCTAssertTrue(waitForSplitGroupCount(atLeast: baseline + 1, timeout: 15),
                      "Open-as-Split should add an inner SplitGroup")

        let outline = app.windows.firstMatch.outlines["sidebarTabList"]
        try runStep("Add a third tab to drag in") {
            self.app.typeKey("t", modifierFlags: .command)
            XCTAssertTrue(self.waitForSidebarCellCount(equalTo: 3, timeout: 10),
                          "Expected New Tab button + split-pair + third tab")
        }

        try runStep("Focus the split, then drag the third tab onto its right pane") {
            // Replace mode requires the focused tab to BE the split, but ⌘T
            // left the third tab focused — click the split-pair row first.
            outline.cells.element(boundBy: 1)
                .coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)).click()
            // Drag the third tab (last row) onto the right pane.
            try self.dragSidebarTabOntoPage(sourceCell: outline.cells.element(boundBy: 2),
                                            zone: .right)
        }
        // The right pane held an empty new-tab page; replacing it evicts and
        // closes that empty pane and absorbs the dragged third tab into the
        // split, so its standalone row disappears (3 → 2 rows) while the
        // split-pair remains.
        XCTAssertTrue(waitForSidebarCellCount(equalTo: 2, timeout: 15),
                      "Replacing a pane should absorb the dragged tab into the split (3 → 2 rows)")
        attachDiagnostics(label: "after-replace-pane")
    }

    @MainActor
    func test_closeSplit_disposesBothPanes() throws {
        let baseline = try enterSplit()
        XCTAssertTrue(waitForSplitGroupCount(atLeast: baseline + 1, timeout: 15),
                      "Open-as-Split should add an inner SplitGroup")

        try runStep("Close the split") {
            try self.rightClickFocusedSidebarTab()
            try self.clickMenuItem(matching: ["Close"])
        }
        // Closing a split disposes BOTH panes (unlike Remove-from-Split,
        // which keeps them as separate tabs), so the web-host count drops
        // back to the at-rest baseline.
        XCTAssertTrue(waitForSplitGroupCount(equalTo: baseline, timeout: 15),
                      "Closing a split should dispose both panes (back to baseline)")
        attachDiagnostics(label: "after-close-split")
    }

    @MainActor
    func test_splitWithCurrent_pairsExistingTabs() throws {
        try runStep("Reset to two tabs") {
            try self.resetToSingleTab(url: "https://example.com")
            self.app.typeKey("t", modifierFlags: .command)   // second tab, becomes focused
            XCTAssertTrue(self.waitForSidebarCellCount(equalTo: 3, timeout: 10),
                          "Expected New Tab button + two tab rows")
        }

        try runStep("Split with Current on the non-focused tab") {
            // Right-click row 1 (the non-focused first tab); the focused
            // second tab pairs with it. Right-clicking the focused tab would
            // offer "Open as Split" (a new blank pane) instead.
            try self.rightClickSidebarCell(index: 1)
            try self.clickMenuItem(matching: ["Split with Current"])
        }
        // Pairing two EXISTING tabs merges their two rows into one
        // split-pair row (no new tab created).
        XCTAssertTrue(waitForSidebarCellCount(equalTo: 2, timeout: 15),
                      "Split with Current should merge two tab rows into one split-pair")
        attachDiagnostics(label: "after-split-with-current")
    }

    @MainActor
    func test_pinSplit_movesOutOfTabListKeepingPanes() throws {
        let baseline = try enterSplit()
        XCTAssertTrue(waitForSplitGroupCount(atLeast: baseline + 1, timeout: 15),
                      "Open-as-Split should add an inner SplitGroup")
        let splitGroupsWhileSplit = currentSplitGroupCount()
        let rowsBeforePin = sidebarCellCount()

        try runStep("Pin Split") {
            try self.rightClickFocusedSidebarTab()
            try self.clickMenuItem(matching: ["Pin Split"])
        }
        // Pinning moves the split out of the tab list into the pinned strip,
        // so the tab list loses the split-pair row...
        XCTAssertTrue(waitForSidebarCellCount(equalTo: rowsBeforePin - 1, timeout: 15),
                      "Pinning a split should remove its row from the tab list")
        // ...but both panes stay live (web-host count unchanged), which is
        // what distinguishes pinning from closing the split.
        XCTAssertEqual(currentSplitGroupCount(), splitGroupsWhileSplit,
                       "Pinning should keep both panes alive (not dispose them)")
        attachDiagnostics(label: "after-pin-split")
    }

    @MainActor
    func test_duplicateSplit_createsSecondSplit() throws {
        try runStep("Reset to single tab") {
            try self.resetToSingleTab(url: "https://example.com")
        }
        try runStep("Open as Split, then navigate the blank pane") {
            try self.rightClickFocusedSidebarTab()
            try self.clickMenuItem(matching: ["Open as Split", "Split with Current"])
            // Duplicate Split bails unless BOTH panes have non-empty URLs;
            // the freshly-opened pane is blank and active, so give it a URL.
            self.app.typeKey("l", modifierFlags: .command)
            self.app.typeText("https://example.com")
            self.app.typeKey("\r", modifierFlags: [])
        }
        let rowsBeforeDuplicate = sidebarCellCount()

        try runStep("Duplicate Split") {
            try self.rightClickFocusedSidebarTab()
            try self.clickMenuItem(matching: ["Duplicate Split"])
        }
        // Duplicating both panes adds a second split-pair row.
        XCTAssertTrue(waitForSidebarCellCount(equalTo: rowsBeforeDuplicate + 1, timeout: 15),
                      "Duplicate Split should add a second split-pair row")
        attachDiagnostics(label: "after-duplicate-split")
    }

    private enum PageDropZone { case left, right }

    /// Drag a sidebar tab cell onto the left/right third of the active page
    /// area. With a non-split focused tab this forms a new split; with a
    /// split focused tab it replaces the corresponding pane. The drop
    /// target is the inner web-content `SplitGroup` (index 1); the outer
    /// window split is index 0.
    @MainActor
    private func dragSidebarTabOntoPage(sourceCell: XCUIElement, zone: PageDropZone) throws {
        guard sourceCell.waitForExistence(timeout: 10) else {
            attachDiagnostics(label: "drag: no source tab")
            XCTFail("Drag source sidebar cell not found")
            return
        }
        let source = sourceCell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))

        let webArea = app.windows.firstMatch.splitGroups.element(boundBy: 1)
        guard webArea.waitForExistence(timeout: 5) else {
            attachDiagnostics(label: "drag: no web area")
            XCTFail("Inner web-content SplitGroup not found")
            return
        }
        let dx: CGFloat = (zone == .right) ? 0.83 : 0.17
        let dest = webArea.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: 0.5))

        source.press(forDuration: 0.6, thenDragTo: dest)
    }

    /// Shared arrange step: reset to one fresh tab, then "Open as Split".
    /// Returns the at-rest baseline SplitGroup count (before the split).
    @MainActor
    @discardableResult
    private func enterSplit() throws -> Int {
        // Reset to a deterministic state instead of trusting session
        // restore: close everything, then open one fresh tab on a URL.
        try runStep("Reset to a single fresh tab") {
            try self.resetToSingleTab(url: "https://example.com")
        }

        XCTAssertTrue(waitForSplitGroupCount(atLeast: 2, timeout: 10),
                      "Window should have at least the outer + inner SplitGroup at rest")
        let baseline = currentSplitGroupCount()

        try runStep("Open as Split") {
            try self.rightClickFocusedSidebarTab()
            try self.clickMenuItem(matching: ["Open as Split", "Split with Current"])
        }
        return baseline
    }

    // MARK: - Deterministic reset

    /// Bring the browser to a near-fresh state: a single plain tab pointed at
    /// `url` — no split, no tab group, no pinned tabs, no bookmarks.
    ///
    /// Session restore is non-deterministic (it can bring back splits, groups,
    /// pinned tabs and bookmarks), and — because tests reuse one app instance
    /// per class — state created by an earlier test leaks into the next. So we
    /// delete every bookmark row and unpin every pinned-grid item, then open a
    /// fresh tab and "Close Other Tabs" on it to dispose everything else
    /// (including the now-unpinned former-pinned tabs and any restored
    /// split/group), and navigate the survivor to `url`.
    @MainActor
    private func resetToSingleTab(url: String) throws {
        let outline = app.windows.firstMatch.outlines["sidebarTabList"]
        XCTAssertTrue(outline.waitForExistence(timeout: 15),
                      "Sidebar outline 'sidebarTabList' not found")

        // Clear accumulated bookmarks and pinned tabs first (sidebar bookmarks
        // are always-present rows; pinned tabs live in the pinned grid).
        clearSidebarBookmarks()
        unpinAllSidebarPinnedTabs()

        // Open a fresh blank tab to keep. It is a plain tab, so it carries
        // the `Selected` AX attribute (split-pair cells do not).
        app.typeKey("t", modifierFlags: .command)
        let newTab = outline.cells.matching(NSPredicate(format: "selected == true")).firstMatch
        XCTAssertTrue(newTab.waitForExistence(timeout: 10),
                      "Fresh tab did not appear after ⌘T")

        // Close every other tab (also disposes the now-unpinned former-pinned
        // tabs and dissolves any restored split/group).
        newTab.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)).rightClick()
        let closeOthers = app.menuItems["Close Other Tabs"]
        if closeOthers.waitForExistence(timeout: 3) {
            closeOthers.click()
        } else {
            // Only one tab existed — nothing else to close.
            app.typeKey(.escape, modifierFlags: [])
        }

        // Navigate the single remaining tab to the URL.
        app.typeKey("l", modifierFlags: .command)
        app.typeText(url)
        app.typeKey("\r", modifierFlags: [])

        // Verify the clean state: New Tab button row + exactly one tab, no pinned.
        let isClean = NSPredicate { _, _ in outline.cells.count == 2 }
        let exp = XCTNSPredicateExpectation(predicate: isClean, object: nil)
        if XCTWaiter.wait(for: [exp], timeout: 15) != .completed {
            attachDiagnostics(label: "reset-not-clean (\(outline.cells.count) rows)")
            XCTFail("Reset did not reach a single-tab state — sidebar has \(outline.cells.count) rows")
        }
        XCTAssertTrue(waitForSidebarPinnedCellCount(equalTo: 0, timeout: 5),
                      "Reset should leave no pinned tabs")
    }

    /// Visible sidebar pinned-grid items (solo tab or pinned split).
    @MainActor
    private func sidebarPinnedTabs() -> XCUIElementQuery {
        app.windows.firstMatch.buttons.matching(identifier: "sidebarPinnedTab")
    }

    /// Visible sidebar bookmark rows.
    @MainActor
    private func sidebarBookmarks() -> XCUIElementQuery {
        app.windows.firstMatch.buttons.matching(identifier: "sidebarBookmark")
    }

    /// Click the first matching item in the currently-open context menu.
    /// Scoped to the window's menus so it does not collide with always-present
    /// menu-bar items of the same title (e.g. the Edit menu's "Delete"). A
    /// failed match dismisses the menu so a left-open menu can't block app
    /// termination. Returns whether an item was clicked.
    @MainActor
    @discardableResult
    private func clickContextMenuItem(_ candidates: [String], timeout: TimeInterval = 2) -> Bool {
        let menu = app.windows.firstMatch.menus.firstMatch
        for title in candidates {
            let item = menu.menuItems[title]
            if item.waitForExistence(timeout: timeout) {
                item.click()
                return true
            }
        }
        app.typeKey(.escape, modifierFlags: [])
        return false
    }

    /// Delete every bookmark row in the sidebar. Capped so a stuck/absent
    /// menu can't loop forever.
    @MainActor
    private func clearSidebarBookmarks() {
        let bookmarks = sidebarBookmarks()
        var iterations = 0
        while bookmarks.count > 0 && iterations < 30 {
            iterations += 1
            let item = bookmarks.element(boundBy: 0)
            guard item.waitForExistence(timeout: 2) else { break }
            item.rightClick()
            if !clickContextMenuItem(["Delete"]) { break }
        }
    }

    /// Unpin every sidebar pinned-grid item (solo tab or pinned split) so a
    /// later Close Other Tabs can dispose the resulting normal tabs.
    @MainActor
    private func unpinAllSidebarPinnedTabs() {
        let pinned = sidebarPinnedTabs()
        var iterations = 0
        while pinned.count > 0 && iterations < 30 {
            iterations += 1
            let cell = pinned.element(boundBy: 0)
            guard cell.waitForExistence(timeout: 2) else { break }
            cell.rightClick()
            if !clickContextMenuItem(["Unpin", "Unpin Split"]) { break }
        }
    }

    @MainActor
    private func waitForSidebarPinnedCellCount(equalTo count: Int, timeout: TimeInterval) -> Bool {
        let pinned = sidebarPinnedTabs()
        let predicate = NSPredicate { _, _ in pinned.count == count }
        let exp = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        return XCTWaiter.wait(for: [exp], timeout: timeout) == .completed
    }

    // MARK: - Step / diagnostics

    @MainActor
    private func runStep(_ name: String, _ body: () throws -> Void) throws {
        try XCTContext.runActivity(named: name) { _ in
            attachDiagnostics(label: "before \(name)")
            do {
                try body()
            } catch {
                attachDiagnostics(label: "failed \(name)")
                throw error
            }
            attachDiagnostics(label: "after \(name)")
        }
    }

    @MainActor
    private func attachDiagnostics(label: String) {
        let shot = XCUIScreen.main.screenshot()
        let imageAttachment = XCTAttachment(screenshot: shot)
        imageAttachment.name = "screen — \(label)"
        imageAttachment.lifetime = .keepAlways
        add(imageAttachment)

        let tree = app.windows.firstMatch.debugDescription
        let treeAttachment = XCTAttachment(string: tree)
        treeAttachment.name = "axtree — \(label)"
        treeAttachment.lifetime = .keepAlways
        add(treeAttachment)
    }

    // MARK: - App actions

    /// Right-click the active tab cell in the sidebar.
    ///
    /// Targets the LAST row of `sidebarTabList` (an `Outline` identifier
    /// wired in `SidebarTabListViewController`). After `resetToSingleTab`
    /// the sidebar is `[New Tab button, the tab]`, so the last row is the
    /// tab pre-split and the split-pair cell post-split. We don't use a
    /// `selected == true` predicate because a split-pair cell is not
    /// marked `Selected` in the AX tree.
    @MainActor
    private func rightClickFocusedSidebarTab() throws {
        let outline = app.windows.firstMatch.outlines["sidebarTabList"]
        guard outline.waitForExistence(timeout: 10) else {
            attachDiagnostics(label: "no sidebar outline")
            XCTFail("Sidebar outline 'sidebarTabList' not found")
            return
        }
        guard outline.cells.firstMatch.waitForExistence(timeout: 5) else {
            attachDiagnostics(label: "no tab cell")
            XCTFail("Sidebar outline never populated a cell")
            return
        }

        let count = outline.cells.count
        let target = outline.cells.element(boundBy: count - 1)
        guard target.waitForExistence(timeout: 5) else {
            attachDiagnostics(label: "last cell missing")
            XCTFail("Last sidebar cell not resolvable")
            return
        }
        // Click ~8% in from the left edge rather than the geometric center:
        // a split-pair cell renders two mini-tabs with a dead-space gap at
        // the center that swallows the right-click.
        target.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)).rightClick()
    }

    /// Right-click a specific sidebar row by index (row 0 is the New Tab
    /// button). Clicks ~8% in from the left edge to dodge a split-pair
    /// cell's centre dead-space gap.
    @MainActor
    private func rightClickSidebarCell(index: Int) throws {
        let outline = app.windows.firstMatch.outlines["sidebarTabList"]
        let cell = outline.cells.element(boundBy: index)
        guard cell.waitForExistence(timeout: 10) else {
            attachDiagnostics(label: "no sidebar cell at \(index)")
            XCTFail("No sidebar cell at index \(index)")
            return
        }
        cell.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)).rightClick()
    }

    /// Click the first context-menu item whose title matches any of
    /// `candidates`. Dumps all visible menu items if none match.
    @MainActor
    private func clickMenuItem(matching candidates: [String]) throws {
        for title in candidates {
            let item = app.menuItems[title]
            if item.waitForExistence(timeout: 3) {
                item.click()
                return
            }
        }
        // Cheap dump: only the frontmost context menu's items. Enumerating
        // every menu-bar menu (allElementsBoundByIndex over app.menus) is
        // slow enough to drop the app connection, so avoid it.
        let frontMenu = app.windows.firstMatch.menus.firstMatch
        let titles = frontMenu.exists
            ? frontMenu.menuItems.allElementsBoundByIndex.prefix(40).map { $0.title }
            : []
        let attachment = XCTAttachment(string: titles.isEmpty ? "<no context menu open>" : titles.joined(separator: "\n"))
        attachment.name = "menu-items-on-failure"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTFail("None of the expected menu items appeared: \(candidates).")
    }

    // MARK: - SplitGroup count

    @MainActor
    private func currentSplitGroupCount() -> Int {
        app.windows.firstMatch.descendants(matching: .splitGroup).count
    }

    @MainActor
    private func sidebarCellCount() -> Int {
        app.windows.firstMatch.outlines["sidebarTabList"].cells.count
    }

    @MainActor
    private func waitForSidebarCellCount(equalTo count: Int, timeout: TimeInterval) -> Bool {
        let outline = app.windows.firstMatch.outlines["sidebarTabList"]
        let predicate = NSPredicate { _, _ in outline.cells.count == count }
        let exp = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        return XCTWaiter.wait(for: [exp], timeout: timeout) == .completed
    }

    @MainActor
    private func waitForSplitGroupCount(atLeast count: Int, timeout: TimeInterval) -> Bool {
        let window = app.windows.firstMatch
        let predicate = NSPredicate { _, _ in
            window.descendants(matching: .splitGroup).count >= count
        }
        let exp = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        return XCTWaiter.wait(for: [exp], timeout: timeout) == .completed
    }

    @MainActor
    private func waitForSplitGroupCount(equalTo count: Int, timeout: TimeInterval) -> Bool {
        let window = app.windows.firstMatch
        let predicate = NSPredicate { _, _ in
            window.descendants(matching: .splitGroup).count == count
        }
        let exp = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        return XCTWaiter.wait(for: [exp], timeout: timeout) == .completed
    }
}

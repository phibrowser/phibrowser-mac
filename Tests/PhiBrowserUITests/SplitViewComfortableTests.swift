// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest

/// UI tests for the split-view flow in the **Comfortable** (horizontal-tab)
/// layout. The companion `SplitViewTests` covers the same flows in the
/// vertical sidebar layout; this suite drives them through the horizontal
/// `TabStrip` instead, since the sidebar is collapsed away in Comfortable.
///
/// Layout is selected with a non-persistent launch argument
/// (`-layoutMode comfortable`), which lands in `UserDefaults`' argument
/// domain — higher precedence than the persisted value, but written to no
/// store. Driving the View-menu item instead would call `saveLayoutMode`
/// and persist Comfortable, contaminating the sidebar suite on the next
/// launch. (The View menu is still the user-facing way to switch — see
/// `selectLayoutMode` — the launch arg is purely a test affordance.)
///
/// Two complementary signals, mirroring `SplitViewTests`:
///
/// 1. `SplitGroup` count — layout-independent. Each live tab's web content
///    is hosted in its own `PhiSplitView`, so the count equals (outer
///    window split) + (one per live tab web-host). Opening a split creates
///    a second pane TAB, so the count rises by one. It does NOT fall on
///    "Remove from Split", because both panes survive as independent tabs —
///    so this is the signal for OPEN, not REMOVE.
///
/// 2. Strip tab-cell count — each visible normal-section strip tab carries
///    the `tabStripTab` accessibility identifier; a split renders as ONE
///    merged cell (its second pane collapses out of the layout), so forming
///    a split lowers the count and dissolving one raises it. Pinned-section
///    cells carry a distinct `tabStripPinnedTab` identifier so a pinned
///    split can be told apart from a normal-list tab.
///
/// Each test resets to a deterministic single-tab state first
/// (`resetToSingleTab`) rather than trusting Phi's session restore.
final class SplitViewComfortableTests: XCTestCase {

    /// Accessibility identifier stamped on every visible normal-section
    /// strip tab cell (see `TabItemView.normalAccessibilityIdentifier`).
    private static let stripTabIdentifier = "tabStripTab"
    /// Accessibility identifier stamped on every visible pinned-section
    /// strip tab cell (see `TabItemView.pinnedAccessibilityIdentifier`).
    private static let stripPinnedTabIdentifier = "tabStripPinnedTab"
    /// Accessibility value stamped on a cell that merges a split pair (see
    /// `TabItemView.splitPairAccessibilityValue`).
    private static let splitPairValue = "splitPair"
    /// Accessibility identifier stamped on every bookmark-bar item (see
    /// `BookmarkItemView.accessibilityIdentifier`).
    private static let bookmarkBarItemIdentifier = "bookmarkBarItem"

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
        // `-layoutMode comfortable` boots the window straight into the
        // horizontal-tab layout via the UserDefaults argument domain,
        // without persisting the choice. `--user-data-dir` (a `--` arg, which
        // `ChromiumLauncher` forwards straight to Chromium) gives the test an
        // isolated profile so it neither collides with a running Phi's
        // process-singleton nor mutates the real dev profile's tabs/bookmarks.
        app.launchArguments += [
            "-uitest", "1",
            "-layoutMode", "comfortable",
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

        // Confirm the horizontal strip actually mounted — proves the
        // Comfortable launch arg took effect before any test runs.
        let anyStripTab = window.buttons.matching(identifier: Self.stripTabIdentifier).firstMatch
        XCTAssertTrue(anyStripTab.waitForExistence(timeout: 30),
                      "Horizontal tab strip never appeared — Comfortable layout may not be active")
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
        // When split, the strip shows a single merged split-pair cell.
        let cellsWhenSplit = stripTabCellCount()

        try runStep("Remove from Split") {
            try self.rightClickFocusedStripTab()
            try self.clickMenuItem(matching: ["Remove from Split"])
        }
        // Dissolving the split turns the one merged cell into two separate
        // tab cells. The SplitGroup (web-host) count does NOT drop, because
        // both panes survive as independent live tabs — the strip cell
        // count is the signal that the split itself dissolved.
        XCTAssertTrue(waitForStripTabCellCount(equalTo: cellsWhenSplit + 1, timeout: 15),
                      "Remove-from-Split should split the merged cell into two tab cells")
        attachDiagnostics(label: "after-remove-from-split")
    }

    @MainActor
    func test_reversePanes_keepsSplit() throws {
        let baseline = try enterSplit()
        XCTAssertTrue(waitForSplitGroupCount(atLeast: baseline + 1, timeout: 15),
                      "Open-as-Split should add an inner SplitGroup")
        let split = currentSplitGroupCount()

        try runStep("Reverse Panes") {
            try self.rightClickFocusedStripTab()
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
            XCTAssertTrue(self.waitForStripTabCellCount(equalTo: 2, timeout: 10),
                          "Expected two strip tab cells")
        }
        let cellsBeforeDrag = stripTabCellCount()

        try runStep("Drag a strip tab onto the page right-third") {
            // Index 0 is the first (non-focused) tab; the focused second tab
            // pairs with it when it is dropped onto the page.
            try self.dragStripTabOntoPage(sourceCell: self.stripTabs().element(boundBy: 0),
                                          zone: .right)
        }
        // Drag-to-split pairs two EXISTING tabs, so the two separate tab
        // cells merge into a single split-pair cell. (Unlike "Open as Split",
        // which spawns a new blank pane tab and so raises the SplitGroup
        // web-host count, drag-to-split adds no tab — the cell count is the
        // signal.)
        XCTAssertTrue(waitForStripTabCellCount(equalTo: cellsBeforeDrag - 1, timeout: 15),
                      "Dragging a tab onto the page should merge two tab cells into one split-pair cell")
        attachDiagnostics(label: "after-drag-to-split")
    }

    @MainActor
    func test_formSplitInTabGroup_createsSplitInGroup() throws {
        try runStep("Reset to single tab") {
            try self.resetToSingleTab(url: "https://example.com")
        }
        let baseline = currentSplitGroupCount()

        try runStep("Create a tab group from the tab") {
            try self.rightClickFocusedStripTab()
            try self.clickMenuItem(matching: ["New Tab Group"])
        }
        attachDiagnostics(label: "after-create-group")

        try runStep("Open as Split inside the group") {
            try self.rightClickFocusedStripTab()
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

        try runStep("Add a third tab to drag in") {
            self.app.typeKey("t", modifierFlags: .command)
            XCTAssertTrue(self.waitForStripTabCellCount(equalTo: 2, timeout: 10),
                          "Expected split-pair cell + third tab cell")
        }

        try runStep("Focus the split, then drag the third tab onto its right pane") {
            // Replace mode requires the focused tab to BE the split, but ⌘T
            // left the third tab focused — click the split-pair cell first.
            // Click ~8% in from the left edge (the split cell's left/primary
            // half) to dodge the merged cell's centre dead-space gap.
            self.stripTabs().element(boundBy: 0)
                .coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)).click()
            // Drag the third tab (index 1) onto the right pane.
            try self.dragStripTabOntoPage(sourceCell: self.stripTabs().element(boundBy: 1),
                                          zone: .right)
        }
        // The right pane held an empty new-tab page; replacing it evicts and
        // closes that empty pane and absorbs the dragged third tab into the
        // split, so its standalone cell disappears (2 → 1 cells) while the
        // split-pair remains.
        XCTAssertTrue(waitForStripTabCellCount(equalTo: 1, timeout: 15),
                      "Replacing a pane should absorb the dragged tab into the split (2 → 1 cells)")
        attachDiagnostics(label: "after-replace-pane")
    }

    @MainActor
    func test_closeSplit_disposesBothPanes() throws {
        let baseline = try enterSplit()
        XCTAssertTrue(waitForSplitGroupCount(atLeast: baseline + 1, timeout: 15),
                      "Open-as-Split should add an inner SplitGroup")

        try runStep("Close the split") {
            try self.rightClickFocusedStripTab()
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
            XCTAssertTrue(self.waitForStripTabCellCount(equalTo: 2, timeout: 10),
                          "Expected two strip tab cells")
        }

        try runStep("Split with Current on the non-focused tab") {
            // Right-click index 0 (the non-focused first tab); the focused
            // second tab pairs with it. Right-clicking the focused tab would
            // offer "Open as Split" (a new blank pane) instead.
            try self.rightClickStripTab(index: 0)
            try self.clickMenuItem(matching: ["Split with Current"])
        }
        // Pairing two EXISTING tabs merges their two cells into one
        // split-pair cell (no new tab created).
        XCTAssertTrue(waitForStripTabCellCount(equalTo: 1, timeout: 15),
                      "Split with Current should merge two tab cells into one split-pair")
        attachDiagnostics(label: "after-split-with-current")
    }

    @MainActor
    func test_pinSplit_movesOutOfNormalStripKeepingPanes() throws {
        let baseline = try enterSplit()
        XCTAssertTrue(waitForSplitGroupCount(atLeast: baseline + 1, timeout: 15),
                      "Open-as-Split should add an inner SplitGroup")
        let splitGroupsWhileSplit = currentSplitGroupCount()
        let normalCellsBeforePin = stripTabCellCount()

        try runStep("Pin Split") {
            try self.rightClickFocusedStripTab()
            try self.clickMenuItem(matching: ["Pin Split"])
        }
        // Pinning moves the split out of the normal strip section into the
        // pinned section, so the normal-list cell count drops...
        XCTAssertTrue(waitForStripTabCellCount(equalTo: normalCellsBeforePin - 1, timeout: 15),
                      "Pinning a split should remove its cell from the normal strip section")
        // ...it reappears as a merged cell in the pinned section...
        XCTAssertTrue(waitForStripPinnedCellCount(atLeast: 1, timeout: 15),
                      "Pinning a split should add a merged cell to the pinned strip section")
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
            try self.rightClickFocusedStripTab()
            try self.clickMenuItem(matching: ["Open as Split", "Split with Current"])
            // Duplicate Split bails unless BOTH panes have non-empty URLs;
            // the freshly-opened pane is blank and active, so give it a URL.
            self.app.typeKey("l", modifierFlags: .command)
            self.app.typeText("https://example.com")
            self.app.typeKey("\r", modifierFlags: [])
        }
        let cellsBeforeDuplicate = stripTabCellCount()

        try runStep("Duplicate Split") {
            try self.rightClickFocusedStripTab()
            try self.clickMenuItem(matching: ["Duplicate Split"])
        }
        // Duplicating both panes adds a second split-pair cell.
        XCTAssertTrue(waitForStripTabCellCount(equalTo: cellsBeforeDuplicate + 1, timeout: 15),
                      "Duplicate Split should add a second split-pair cell")
        attachDiagnostics(label: "after-duplicate-split")
    }

    @MainActor
    func test_dragPinnedTabToSplit_formsMergedCell() throws {
        // Arrange: one normal tab (the split partner) plus one pinned tab to
        // drag in.
        try runStep("Reset, add a second tab, and pin it") {
            try self.resetToSingleTab(url: "https://example.com")
            self.app.typeKey("t", modifierFlags: .command)   // second tab, focused
            XCTAssertTrue(self.waitForStripTabCellCount(equalTo: 2, timeout: 10),
                          "Expected two normal strip tab cells")
            // Pin the focused (last) tab so it moves into the pinned section.
            try self.rightClickFocusedStripTab()
            try self.clickMenuItem(matching: ["Pin"])
            XCTAssertTrue(self.waitForStripPinnedCellCount(atLeast: 1, timeout: 10),
                          "Expected the tab to move into the pinned section")
            XCTAssertTrue(self.waitForStripTabCellCount(equalTo: 1, timeout: 10),
                          "Expected one normal tab remaining as the split partner")
        }

        try runStep("Focus the normal tab so it becomes the split partner") {
            self.stripTabs().element(boundBy: 0)
                .coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)).click()
        }
        let baseline = currentSplitGroupCount()

        try runStep("Drag the pinned tab onto the page right-third") {
            try self.dragStripTabOntoPage(sourceCell: self.stripPinnedTabs().element(boundBy: 0),
                                          zone: .right)
        }
        // The split must form...
        XCTAssertTrue(waitForSplitGroupCount(atLeast: baseline + 1, timeout: 15),
                      "Dragging a pinned tab onto the page should form a split")
        // ...AND render as a single merged normal-section cell. Before the
        // fix the dragged pinned tab stayed pinned, so the split straddled
        // the pinned + normal sections and neither section merged it — no
        // cell carried the split-pair marker, so this assertion failed.
        XCTAssertTrue(waitForStripSplitPairCellCount(equalTo: 1, timeout: 15),
                      "The split should render as one merged split-pair cell, not two separate tabs")
        attachDiagnostics(label: "after-drag-pinned-to-split")
    }

    private enum PageDropZone { case left, right }

    /// Drag a strip tab cell onto the left/right third of the active page
    /// area. With a non-split focused tab this forms a new split; with a
    /// split focused tab it replaces the corresponding pane. The drop
    /// target is the inner web-content `SplitGroup` (index 1); the outer
    /// window split is index 0. (The outer split survives in Comfortable
    /// layout — the sidebar pane is collapsed, not removed — so the index
    /// matches the sidebar suite.)
    @MainActor
    private func dragStripTabOntoPage(sourceCell: XCUIElement, zone: PageDropZone) throws {
        guard sourceCell.waitForExistence(timeout: 10) else {
            attachDiagnostics(label: "drag: no source tab")
            XCTFail("Drag source strip cell not found")
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
            try self.rightClickFocusedStripTab()
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
    /// open a fresh new-tab page (which surfaces the bookmark bar), clear the
    /// bookmarks and unpin every pinned tab, then "Close Other Tabs" on a
    /// final fresh tab to dispose everything else (including the now-unpinned
    /// former-pinned tabs and any restored split/group), and navigate to `url`.
    @MainActor
    private func resetToSingleTab(url: String) throws {
        XCTAssertTrue(stripTabs().firstMatch.waitForExistence(timeout: 15),
                      "Horizontal strip never populated a tab cell")

        // A fresh new-tab page shows the bookmark bar, so clear bookmarks while
        // it is focused (deleting bookmarks doesn't disturb the tab/focus).
        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(waitForStripTabCellCount(atLeast: 1, timeout: 10),
                      "Fresh tab did not appear after ⌘T")
        clearBookmarkBar()

        // Unpin every pinned tab so the Close Other Tabs pass below disposes
        // them — Close Other Tabs spares pinned tabs, so they must be demoted
        // to normal first. Unpinning may shift focus onto a former-pinned tab.
        unpinAllPinnedTabs()

        // A second fresh tab gives a known focused tab to keep, regardless of
        // where the unpins above left focus.
        app.typeKey("t", modifierFlags: .command)
        try closeOtherTabsOnFocusedStripTab()

        // Navigate the single remaining tab to the URL.
        app.typeKey("l", modifierFlags: .command)
        app.typeText(url)
        app.typeKey("\r", modifierFlags: [])

        // Verify the clean state: one normal-section tab cell, no pinned cells.
        if !waitForStripTabCellCount(equalTo: 1, timeout: 15) {
            attachDiagnostics(label: "reset-not-clean (\(stripTabCellCount()) normal cells)")
            XCTFail("Reset did not reach a single-tab state — strip has \(stripTabCellCount()) normal cells")
        }
        XCTAssertTrue(waitForStripPinnedCellCount(equalTo: 0, timeout: 5),
                      "Reset should leave no pinned tabs")
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

    /// Delete every bookmark in the horizontal bookmark bar. The bar is only
    /// visible while focused on a new-tab page (the caller arranges that).
    /// Capped so a stuck/absent menu can't loop forever.
    @MainActor
    private func clearBookmarkBar() {
        let bookmarks = app.windows.firstMatch.buttons.matching(identifier: Self.bookmarkBarItemIdentifier)
        var iterations = 0
        while bookmarks.count > 0 && iterations < 30 {
            iterations += 1
            let item = bookmarks.element(boundBy: 0)
            guard item.waitForExistence(timeout: 2) else { break }
            item.rightClick()
            if !clickContextMenuItem(["Delete"]) { break }
        }
    }

    /// Unpin every pinned strip cell (solo tab or pinned split) so a later
    /// Close Other Tabs can dispose the resulting normal tabs.
    @MainActor
    private func unpinAllPinnedTabs() {
        let pinned = stripPinnedTabs()
        var iterations = 0
        while pinned.count > 0 && iterations < 30 {
            iterations += 1
            let cell = pinned.element(boundBy: 0)
            guard cell.waitForExistence(timeout: 2) else { break }
            cell.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)).rightClick()
            if !clickContextMenuItem(["Unpin", "Unpin Split"]) { break }
        }
    }

    /// Right-click the focused (last) strip tab and choose Close Other Tabs,
    /// falling back to dismissing the menu when there is nothing else to close.
    @MainActor
    private func closeOtherTabsOnFocusedStripTab() throws {
        try rightClickFocusedStripTab()
        let closeOthers = app.menuItems["Close Other Tabs"]
        if closeOthers.waitForExistence(timeout: 3) {
            closeOthers.click()
        } else {
            app.typeKey(.escape, modifierFlags: [])
        }
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

    /// Query for the visible normal-section strip tab cells. A split renders
    /// as a single merged cell, so its second pane is excluded.
    @MainActor
    private func stripTabs() -> XCUIElementQuery {
        app.windows.firstMatch.buttons.matching(identifier: Self.stripTabIdentifier)
    }

    /// Query for the visible pinned-section strip tab cells.
    @MainActor
    private func stripPinnedTabs() -> XCUIElementQuery {
        app.windows.firstMatch.buttons.matching(identifier: Self.stripPinnedTabIdentifier)
    }

    /// Right-click the focused tab cell in the strip.
    ///
    /// Targets the LAST normal-section cell. After `resetToSingleTab` the
    /// strip has exactly one normal cell (the focused tab); after a split
    /// forms it is the merged split-pair cell; after ⌘T the freshly-focused
    /// tab is appended last. We click ~8% in from the left edge rather than
    /// the geometric centre: a split-pair cell renders two mini-tabs with a
    /// dead-space gap at the centre that swallows the right-click.
    @MainActor
    private func rightClickFocusedStripTab() throws {
        let tabs = stripTabs()
        guard tabs.firstMatch.waitForExistence(timeout: 10) else {
            attachDiagnostics(label: "no strip tab cell")
            XCTFail("Strip never populated a tab cell")
            return
        }
        let count = tabs.count
        let target = tabs.element(boundBy: count - 1)
        guard target.waitForExistence(timeout: 5) else {
            attachDiagnostics(label: "last strip cell missing")
            XCTFail("Last strip cell not resolvable")
            return
        }
        target.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)).rightClick()
    }

    /// Right-click a specific normal-section strip cell by index. Clicks
    /// ~8% in from the left edge to dodge a split-pair cell's centre
    /// dead-space gap.
    @MainActor
    private func rightClickStripTab(index: Int) throws {
        let cell = stripTabs().element(boundBy: index)
        guard cell.waitForExistence(timeout: 10) else {
            attachDiagnostics(label: "no strip cell at \(index)")
            XCTFail("No strip cell at index \(index)")
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

    // MARK: - Counts

    @MainActor
    private func currentSplitGroupCount() -> Int {
        app.windows.firstMatch.descendants(matching: .splitGroup).count
    }

    @MainActor
    private func stripTabCellCount() -> Int {
        stripTabs().count
    }

    @MainActor
    private func waitForStripTabCellCount(equalTo count: Int, timeout: TimeInterval) -> Bool {
        let tabs = stripTabs()
        let predicate = NSPredicate { _, _ in tabs.count == count }
        let exp = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        return XCTWaiter.wait(for: [exp], timeout: timeout) == .completed
    }

    @MainActor
    private func waitForStripTabCellCount(atLeast count: Int, timeout: TimeInterval) -> Bool {
        let tabs = stripTabs()
        let predicate = NSPredicate { _, _ in tabs.count >= count }
        let exp = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        return XCTWaiter.wait(for: [exp], timeout: timeout) == .completed
    }

    @MainActor
    private func waitForStripPinnedCellCount(atLeast count: Int, timeout: TimeInterval) -> Bool {
        let tabs = stripPinnedTabs()
        let predicate = NSPredicate { _, _ in tabs.count >= count }
        let exp = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        return XCTWaiter.wait(for: [exp], timeout: timeout) == .completed
    }

    @MainActor
    private func waitForStripPinnedCellCount(equalTo count: Int, timeout: TimeInterval) -> Bool {
        let tabs = stripPinnedTabs()
        let predicate = NSPredicate { _, _ in tabs.count == count }
        let exp = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        return XCTWaiter.wait(for: [exp], timeout: timeout) == .completed
    }

    /// Visible normal-section cells that merge a split pair (carry the
    /// `splitPair` accessibility value). A split that fails to merge into one
    /// cell leaves zero of these.
    @MainActor
    private func stripSplitPairCells() -> XCUIElementQuery {
        stripTabs().matching(NSPredicate(format: "value == %@", Self.splitPairValue))
    }

    @MainActor
    private func waitForStripSplitPairCellCount(equalTo count: Int, timeout: TimeInterval) -> Bool {
        let q = stripSplitPairCells()
        let predicate = NSPredicate { _, _ in q.count == count }
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

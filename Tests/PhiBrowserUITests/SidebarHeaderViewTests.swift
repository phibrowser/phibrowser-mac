// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest

/// UI coverage for the sidebar header's responsive chrome.
///
/// The suite boots Phi with launch arguments instead of mutating persisted
/// preferences: `-layoutMode` selects the layout, `-sidebarHeaderWidth` aligns
/// the real split-view divider, and `-sidebarHeaderUpdateVersion` exercises the
/// same visible state Sparkle enters after an update has downloaded. Vertical
/// layouts are expanded through the View menu when needed, matching the product
/// path for reopening a collapsed sidebar.
final class SidebarHeaderViewTests: XCTestCase {
    private enum HeaderID {
        static let sidebarButton = "sidebarHeader.sidebarButton"
        static let searchTabsButton = "sidebarHeader.searchTabsButton"
        static let upgradeButton = "sidebarHeader.upgradeButton"
        static let backButton = "sidebarHeader.backButton"
        static let forwardButton = "sidebarHeader.forwardButton"
        static let refreshButton = "sidebarHeader.refreshButton"
        static let addressView = "sidebarHeader.addressView"
    }

    private enum LayoutMode: String {
        case balanced
        case performance
        case comfortable
    }

    private static let sidebarOutlineIdentifier = "sidebarTabList"
    private static let viewMenuTitle = "View"
    private static let toggleSidebarMenuTitle = "Toggle Sidebar"

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    @MainActor
    func test_performanceLayoutWithoutUpdateShowsSidebarNavigation() throws {
        try launch(layoutMode: .performance, sidebarWidth: 260)

        assertVisible(HeaderID.sidebarButton)
        assertVisible(HeaderID.backButton)
        assertVisible(HeaderID.forwardButton)
        assertVisible(HeaderID.refreshButton)
        assertVisible(HeaderID.addressView)
        assertNotVisible(HeaderID.upgradeButton)
        assertNotVisible(HeaderID.searchTabsButton)
    }

    @MainActor
    func test_performanceLayoutWithUpdateShowsUpgradeWhenWideEnough() throws {
        try launch(layoutMode: .performance, sidebarWidth: 260, updateVersion: "1.2.3")

        assertVisible(HeaderID.upgradeButton)
        assertVisible(HeaderID.backButton)
        assertVisible(HeaderID.forwardButton)
        assertVisible(HeaderID.refreshButton)
        assertVisible(HeaderID.addressView)
        assertNotVisible(HeaderID.sidebarButton)
        assertNotVisible(HeaderID.searchTabsButton)
    }

    @MainActor
    func test_performanceLayoutWithUpdateKeepsSidebarButtonWhenNarrow() throws {
        try launch(layoutMode: .performance, sidebarWidth: 193, updateVersion: "1.2.3")

        assertVisible(HeaderID.sidebarButton)
        assertVisible(HeaderID.backButton)
        assertVisible(HeaderID.forwardButton)
        assertVisible(HeaderID.refreshButton)
        assertVisible(HeaderID.addressView)
        assertNotVisible(HeaderID.upgradeButton)
        assertNotVisible(HeaderID.searchTabsButton)
    }

    @MainActor
    func test_balancedLayoutWithUpdateShowsHeaderActionsWithoutSidebarNavigation() throws {
        try launch(layoutMode: .balanced, sidebarWidth: 260, updateVersion: "1.2.3")

        assertVisible(HeaderID.sidebarButton)
        assertVisible(HeaderID.searchTabsButton)
        assertVisible(HeaderID.upgradeButton)
        assertNotVisible(HeaderID.backButton)
        assertNotVisible(HeaderID.forwardButton)
        assertNotVisible(HeaderID.refreshButton)
        assertNotVisible(HeaderID.addressView)

        let sidebarButton = element(matching: HeaderID.sidebarButton)
        let searchTabsButton = element(matching: HeaderID.searchTabsButton)
        let upgradeButton = element(matching: HeaderID.upgradeButton)
        XCTAssertEqual(upgradeButton.frame.midY, sidebarButton.frame.midY, accuracy: 0.5)
        XCTAssertEqual(upgradeButton.frame.midY, searchTabsButton.frame.midY, accuracy: 0.5)
    }

    @MainActor
    func test_comfortableLayoutDoesNotExposeSidebarHeaderControls() throws {
        try launch(layoutMode: .comfortable, sidebarWidth: 260, updateVersion: "1.2.3")

        let stripTab = app.windows.firstMatch.buttons.matching(identifier: "tabStripTab").firstMatch
        XCTAssertTrue(stripTab.waitForExistence(timeout: 30),
                      "Horizontal tab strip never appeared; Comfortable layout may not be active")
        assertNotVisible(HeaderID.sidebarButton)
        assertNotVisible(HeaderID.searchTabsButton)
        assertNotVisible(HeaderID.upgradeButton)
        assertNotVisible(HeaderID.backButton)
        assertNotVisible(HeaderID.forwardButton)
        assertNotVisible(HeaderID.refreshButton)
        assertNotVisible(HeaderID.addressView)
    }

    @MainActor
    private func launch(
        layoutMode: LayoutMode,
        sidebarWidth: CGFloat,
        updateVersion: String? = nil
    ) throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-uitest", "1",
            "-layoutMode", layoutMode.rawValue,
            "-spacesFeatureEnabled", "NO",
            "-sidebarHeaderWidth", "\(Int(sidebarWidth))",
            "--user-data-dir=\(NSTemporaryDirectory())PhiUITest-\(ProcessInfo.processInfo.globallyUniqueString)",
        ]

        if let updateVersion {
            app.launchArguments += ["-sidebarHeaderUpdateVersion", updateVersion]
        }

        app.launch()
        self.app = app

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 120),
                      "Main window did not appear")
        app.activate()

        if layoutMode != .comfortable {
            try ensureSidebarExpanded()
        }
    }

    @MainActor
    private func assertVisible(
        _ identifier: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let element = element(matching: identifier)
        let exists = element.waitForExistence(timeout: 20)
        if !exists {
            attachDiagnostics(label: "missing \(identifier)")
        }
        XCTAssertTrue(exists, "\(identifier) should be visible", file: file, line: line)
        guard exists else { return }
        XCTAssertFalse(element.frame.isEmpty, "\(identifier) should have a non-empty frame", file: file, line: line)
    }

    @MainActor
    private func assertNotVisible(
        _ identifier: String,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element(matching: identifier).exists {
                return
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        }

        if element(matching: identifier).exists {
            attachDiagnostics(label: "unexpected \(identifier)")
        }
        XCTAssertFalse(element(matching: identifier).exists, "\(identifier) should not be visible", file: file, line: line)
    }

    @MainActor
    private func element(matching identifier: String) -> XCUIElement {
        app.windows.firstMatch.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func ensureSidebarExpanded() throws {
        let outline = app.windows.firstMatch.outlines[Self.sidebarOutlineIdentifier]
        if outline.waitForExistence(timeout: 2) {
            return
        }

        try toggleSidebarFromViewMenu()
        XCTAssertTrue(outline.waitForExistence(timeout: 20),
                      "Sidebar should expand after View > Toggle Sidebar")
    }

    @MainActor
    private func toggleSidebarFromViewMenu() throws {
        let viewMenu = app.menuBars.menuBarItems[Self.viewMenuTitle]
        guard viewMenu.waitForExistence(timeout: 10) else {
            attachDiagnostics(label: "no View menu")
            XCTFail("View menu unavailable")
            return
        }
        viewMenu.click()

        let toggleSidebar = app.menuBars.menuItems[Self.toggleSidebarMenuTitle]
        guard toggleSidebar.waitForExistence(timeout: 5) else {
            attachDiagnostics(label: "no Toggle Sidebar item")
            XCTFail("Toggle Sidebar menu item unavailable")
            return
        }
        toggleSidebar.click()
    }

    @MainActor
    private func attachDiagnostics(label: String) {
        let shot = XCUIScreen.main.screenshot()
        let imageAttachment = XCTAttachment(screenshot: shot)
        imageAttachment.name = "screen - \(label)"
        imageAttachment.lifetime = .keepAlways
        add(imageAttachment)

        let tree = app.windows.firstMatch.debugDescription
        let treeAttachment = XCTAttachment(string: tree)
        treeAttachment.name = "axtree - \(label)"
        treeAttachment.lifetime = .keepAlways
        add(treeAttachment)
    }
}

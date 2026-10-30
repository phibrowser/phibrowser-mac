// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest

/// Run with the OpenSource scheme and PHI_TAB_DOUBLE_CLICK_UI_TESTS=1.
/// Uses disposable browser data and restores the visible Advanced preference.
final class TabDoubleClickCloseUITests: XCTestCase {
    private var app: XCUIApplication!
    private var launchArguments: [String] = []

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PHI_TAB_DOUBLE_CLICK_UI_TESTS"] == "1",
                          "Opt in to the isolated OpenSource browser UI test")
        app = XCUIApplication()
        launchArguments = [
            "-uitest", "1", "-skip-onboarding", "-AppleLanguages", "(en)",
            "-authRequiresExplicitLogin", "YES", "-spacesFeatureEnabled", "NO",
            "-openNewTabPageOnCmdT", "YES",
            "--user-data-dir=\(NSTemporaryDirectory())PhiTabDoubleClickUITest-\(UUID().uuidString)",
        ]
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    @MainActor
    func testDoubleClickClosesOnlyWhenEnabledInEveryLayout() throws {
        for layout in ["balanced", "performance", "comfortable"] {
            for enabled in [false, true] {
                app.launchArguments = launchArguments + [
                    "-layoutMode", layout, "-doubleClickToCloseTabs", enabled ? "YES" : "NO",
                ]
                app.launch()
                XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 60))
                app.activate()
                if layout != "comfortable", !app.outlines["sidebarTabList"].exists {
                    app.menuBars.menuBarItems["View"].click()
                    let toggleSidebar = app.menuBars.menuItems["Toggle Sidebar"]
                    XCTAssertTrue(toggleSidebar.waitForExistence(timeout: 5))
                    toggleSidebar.click()
                    XCTAssertTrue(app.outlines["sidebarTabList"].waitForExistence(timeout: 10))
                }
                app.typeKey("t", modifierFlags: .command)
                app.typeKey("t", modifierFlags: .command)
                app.typeKey(.escape, modifierFlags: [])
                let tabs = layout == "comfortable"
                    ? app.buttons.matching(identifier: "tabStripTab")
                    : app.outlines["sidebarTabList"].cells
                XCTAssertTrue(waitUntil { tabs.count >= 2 })
                let before = tabs.count
                let target = tabs.element(boundBy: before - 1)
                XCTAssertTrue(target.isHittable)
                target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleClick()
                if enabled {
                    XCTAssertTrue(waitUntil { tabs.count == before - 1 }, "Double-click must close one tab in \(layout)")
                } else {
                    XCTAssertEqual(tabs.count, before, "Disabled double-click must preserve the tab in \(layout)")
                }
                app.terminate()
            }
        }
    }

    @MainActor
    func testAdvancedSwitchPersistsAfterRelaunch() throws {
        app.launchArguments = launchArguments + ["-layoutMode", "balanced"]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 60))
        let toggle = try openAdvancedToggle()
        let original = try XCTUnwrap(toggle.value as? String)
        defer {
            if app.state == .notRunning { app.launch() }
            if let restoredToggle = try? openAdvancedToggle(), restoredToggle.value as? String != original {
                restoredToggle.click()
            }
        }
        toggle.click()
        let changed = try XCTUnwrap(toggle.value as? String)
        XCTAssertNotEqual(changed, original)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 60))
        let reopened = try openAdvancedToggle()
        XCTAssertEqual(reopened.value as? String, changed)
        reopened.click()
        XCTAssertEqual(reopened.value as? String, original)
    }

    @MainActor
    private func openAdvancedToggle() throws -> XCUIElement {
        app.activate()
        app.typeKey(",", modifierFlags: .command)
        let advanced = app.toolbars.buttons["Advanced"]
        XCTAssertTrue(advanced.waitForExistence(timeout: 10))
        advanced.click()
        let toggle = app.descendants(matching: .any)
            .matching(identifier: "settings.tabs.doubleClickToClose").firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        return toggle
    }

    private func waitUntil(_ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if predicate() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return predicate()
    }
}

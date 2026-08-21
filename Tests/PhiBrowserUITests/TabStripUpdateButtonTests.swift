// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest

final class TabStripUpdateButtonTests: XCTestCase {
    private enum AccessibilityID {
        static let updateButton = "tabStrip.updateButton"
        static let searchTabsButton = "tabStrip.searchTabsButton"
    }

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false

        let app = XCUIApplication()
        app.launchArguments += [
            "-uitest", "1",
            "-layoutMode", "comfortable",
            "-spacesFeatureEnabled", "NO",
            "-tabStripUpdateVersion", "1.2.3",
            "--user-data-dir=\(NSTemporaryDirectory())PhiUITest-\(ProcessInfo.processInfo.globallyUniqueString)",
        ]
        app.launch()
        self.app = app

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 120),
                      "Main window did not appear")
        app.activate()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    @MainActor
    func test_downloadedUpdateAppearsBeforeSearchTabs() throws {
        let window = app.windows.firstMatch
        let updateButton = window.buttons[AccessibilityID.updateButton]
        let searchTabsButton = window.buttons[AccessibilityID.searchTabsButton]

        XCTAssertTrue(updateButton.waitForExistence(timeout: 30),
                      "The downloaded-update action should appear in the tab strip")
        XCTAssertTrue(searchTabsButton.waitForExistence(timeout: 30),
                      "The Search Tabs action should appear in the tab strip")
        XCTAssertFalse(updateButton.frame.isEmpty,
                       "The update action should have a visible frame")
        XCTAssertLessThanOrEqual(
            updateButton.frame.maxX,
            searchTabsButton.frame.minX,
            "The update action should appear before Search Tabs"
        )
    }
}

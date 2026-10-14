// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

@MainActor
final class WebContentHeaderStateTests: XCTestCase {
    private var originalLayoutRawValue: String?

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalLayoutRawValue = UserDefaults.standard.string(
            forKey: PhiPreferences.GeneralSettings.layoutModeKey
        )
    }

    override func tearDownWithError() throws {
        if let originalLayoutRawValue {
            UserDefaults.standard.set(
                originalLayoutRawValue,
                forKey: PhiPreferences.GeneralSettings.layoutModeKey
            )
        } else {
            UserDefaults.standard.removeObject(
                forKey: PhiPreferences.GeneralSettings.layoutModeKey
            )
        }
        NotificationCenter.default.post(
            name: UserDefaults.didChangeNotification,
            object: UserDefaults.standard
        )
        try super.tearDownWithError()
    }

    func testFeedbackIconFitsBesideDownloadAtNinetyPoints() {
        let fit = HeaderTrailingArea.widthFit(
            availableWidth: 90,
            pinnedCount: 0,
            showDownload: true,
            showMemory: false,
            showFeedback: true,
            showChat: false
        )

        XCTAssertTrue(fit.showFeedback)
        XCTAssertTrue(fit.showDownload)
    }

    func testFeedbackIconCollapsesWhenItsSlotDoesNotFit() {
        let fit = HeaderTrailingArea.widthFit(
            availableWidth: 59,
            pinnedCount: 0,
            showDownload: false,
            showMemory: false,
            showFeedback: true,
            showChat: false
        )

        XCTAssertFalse(fit.showFeedback)
    }

    func testBalancedLayoutAllowsWindowDrag() {
        PhiPreferences.GeneralSettings.saveLayoutMode(.balanced)

        XCTAssertTrue(WebContentHeaderState().allowsWindowDrag)
    }

    func testOtherLayoutsDoNotAllowWindowDrag() {
        for layoutMode in [LayoutMode.performance, .comfortable] {
            PhiPreferences.GeneralSettings.saveLayoutMode(layoutMode)

            XCTAssertFalse(
                WebContentHeaderState().allowsWindowDrag,
                "Expected no window drag in \(layoutMode.rawValue) layout"
            )
        }
    }

    func testNonSplitHeaderShowsBottomSeparatorWithoutBookmarkBar() {
        XCTAssertTrue(
            WebContentHeader.shouldShowBottomSeparator(
                isSplitViewVisible: false,
                isBookmarkBarVisible: false
            )
        )
    }

    func testSplitHeaderWithoutBookmarkBarHidesBottomSeparator() {
        XCTAssertFalse(
            WebContentHeader.shouldShowBottomSeparator(
                isSplitViewVisible: true,
                isBookmarkBarVisible: false
            )
        )
    }

    func testSplitHeaderWithBookmarkBarShowsBottomSeparator() {
        XCTAssertTrue(
            WebContentHeader.shouldShowBottomSeparator(
                isSplitViewVisible: true,
                isBookmarkBarVisible: true
            )
        )
    }

    func testFeatureEntryAnalyticsUsesOnlySupportedButtons() {
        XCTAssertEqual(
            FeatureEntryAnalytics.Button.allCases.map(\.rawValue),
            ["chat", "memory", "download", "organize_tabs"]
        )
    }

    func testFeatureEntryAnalyticsUsesStableSurfaces() {
        XCTAssertEqual(
            FeatureEntryAnalytics.Surface.allCases.map(\.rawValue),
            ["sidebar", "web_content_header"]
        )
    }
}

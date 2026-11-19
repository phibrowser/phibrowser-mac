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

    private func trailingFit(_ items: [ToolbarItemID], availableWidth: CGFloat) -> ToolbarOverflow.Fit {
        ToolbarOverflow.fit(
            items,
            width: HeaderTrailingArea.slotWidth(for:),
            available: availableWidth - HeaderTrailingArea.trailingPadding,
            overflowButtonWidth: HeaderTrailingArea.overflowSlotWidth
        )
    }

    func testFeedbackIconFitsBesideDownloadAtNinetyPoints() {
        let fit = trailingFit([.extensionsButton, .downloads, .feedback], availableWidth: 90)

        XCTAssertEqual(fit.folded, [])
        XCTAssertEqual(fit.visible, [.extensionsButton, .downloads, .feedback])
    }

    func testFeedbackIconCollapsesWhenItsSlotDoesNotFit() {
        let fit = trailingFit([.extensionsButton, .feedback], availableWidth: 59)

        XCTAssertEqual(fit.folded, [.feedback])
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

    func testTheToolbarLaysOutWithoutTheItemBeingDragged() {
        let standard = ToolbarArrangement.standard
        let withoutReload = WebContentHeaderState.layoutArrangement(standard, dragging: .item(.reload))
        XCTAssertEqual(withoutReload.placements(in: .left).map(\.item), [.sidebarToggle, .back, .forward])
        XCTAssertEqual(withoutReload.placements(in: .right), standard.placements(in: .right))
        XCTAssertTrue(withoutReload.showsAddressBar)

        let withoutBar = WebContentHeaderState.layoutArrangement(standard, dragging: .addressBar)
        XCTAssertFalse(withoutBar.showsAddressBar)
        XCTAssertEqual(withoutBar.placements(in: .addressTrailing), standard.placements(in: .addressTrailing),
                       "its buttons come back with it")

        XCTAssertEqual(WebContentHeaderState.layoutArrangement(standard, dragging: nil), standard)
        XCTAssertEqual(WebContentHeaderState.layoutArrangement(standard, dragging: .defaultSet), standard)
    }

    func testTheDraggedItemIsLeftOutOnlyWhileCustomizingAndNeverFromTheArrangement() {
        let state = WebContentHeaderState()
        state.showAddressBar = true
        state.arrangement = .standard
        state.draggedPayload = .addressBar
        XCTAssertEqual(state.layoutArrangement, .standard, "outside customizing nothing changes")
        XCTAssertTrue(state.drawsAddressBar)

        state.isCustomizing = true
        XCTAssertFalse(state.drawsAddressBar, "the toolbar reflows as if the bar were gone")
        XCTAssertEqual(state.arrangement, .standard, "until it lands or leaves")

        state.draggedPayload = .item(.chat)
        XCTAssertTrue(state.drawsAddressBar)
        XCTAssertFalse(state.layoutArrangement.placements(in: .right).contains { $0.item == .chat })
        XCTAssertTrue(state.arrangement.placements(in: .right).contains { $0.item == .chat })

        state.draggedPayload = nil
        XCTAssertEqual(state.layoutArrangement, .standard, "a cancelled drag puts it back where it was")
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

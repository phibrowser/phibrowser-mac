// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class ToolbarOverflowTests: XCTestCase {
    private func fit(_ items: [ToolbarItemID], _ available: CGFloat) -> ToolbarOverflow.Fit {
        ToolbarOverflow.fit(items, width: { _ in 30 }, available: available, overflowButtonWidth: 30)
    }

    func testEverythingFits() {
        XCTAssertEqual(fit([.back, .downloads], 60).folded, [])
    }

    func testFoldsInTodaysPriority() {
        // 150pt of items in 120pt: the "…" takes 30, leaving 90 for items.
        let f = fit([.extensionAction("a"), .extensionAction("b"), .memory, .downloads, .feedback], 120)
        XCTAssertEqual(f.folded, [.feedback, .extensionAction("b")])
        XCTAssertEqual(f.visible, [.extensionAction("a"), .memory, .downloads])
    }

    func testItemsThatNeverFoldStay() {
        XCTAssertEqual(fit([.back, .copyURL, .downloads], 30).visible, [.back, .copyURL])
    }

    // MARK: - Segments

    func testTheStandardRightZoneDrawsTodaysCapsule() {
        let segments = ToolbarZoneSegment.segments(
            [.extensionAction("a"), .extensionAction("b"), .extensionsButton, .memory, .downloads, .feedback, .chat],
            overflowAnchor: nil
        )
        XCTAssertEqual(segments, [
            .extensions(ids: ["a", "b"], menuButton: .trailing, group: 0),
            .item(.memory), .item(.downloads), .item(.feedback), .item(.chat),
        ])
    }

    func testASegmentDrawsItsItemsInTheZonesOrder() {
        // While customizing a capsule's items are dragged one by one, in the order the zone has them.
        let zones: [[ToolbarItemID]] = [
            [.extensionAction("a"), .extensionAction("b"), .extensionsButton, .memory, .downloads, .feedback, .chat],
            [.back, .extensionsButton, .extensionAction("a"), .reload],
            [.extensionAction("a"), .back, .extensionAction("b")],
            [],
        ]
        for items in zones {
            XCTAssertEqual(ToolbarZoneSegment.segments(items, overflowAnchor: nil).flatMap(\.items), items)
        }
        XCTAssertEqual(ToolbarZoneSegment.overflow.items, [])
    }

    func testTheExtensionsButtonAloneIsAPlainButton() {
        XCTAssertEqual(
            ToolbarZoneSegment.segments([.extensionsButton, .memory], overflowAnchor: nil),
            [.item(.extensionsButton), .item(.memory)]
        )
    }

    func testTheOverflowButtonTakesTheFoldedItemsPlace() {
        // Today's narrow window: Feedback folded, so the "…" sits between Downloads and Chat.
        XCTAssertEqual(
            ToolbarZoneSegment.segments(
                [.extensionAction("a"), .extensionsButton, .memory, .downloads, .chat],
                overflowAnchor: 4
            ),
            [.extensions(ids: ["a"], menuButton: .trailing, group: 0), .item(.memory), .item(.downloads), .overflow, .item(.chat)]
        )
    }

    func testTheOverflowButtonNeverSplitsACapsule() {
        XCTAssertEqual(
            ToolbarZoneSegment.segments(
                [.extensionAction("a"), .extensionsButton, .downloads],
                overflowAnchor: 1
            ),
            [.extensions(ids: ["a"], menuButton: .trailing, group: 0), .overflow, .item(.downloads)]
        )
    }

    func testExtensionsInARunFollowThePresentedPinOrder() {
        // While the header's drag-to-reorder preview is up, a run of icons follows the presented order.
        XCTAssertEqual(
            ToolbarZoneSegment.orderingExtensionRuns(
                [.extensionAction("a"), .extensionAction("b"), .extensionsButton, .extensionAction("c")],
                by: ["c", "b", "a"]
            ),
            [.extensionAction("b"), .extensionAction("a"), .extensionsButton, .extensionAction("c")]
        )
    }

    @MainActor
    func testPerformanceDrawsChromiumsOrderAndAlwaysTheExtensionsButton() {
        // Performance ignores the arrangement: the sidebar reorders Chromium's order, and the button cannot be removed there.
        let items = WebContentHeaderView.performanceItems(extensionIDs: ["b", "a"])
        XCTAssertEqual(items, [.extensionAction("b"), .extensionAction("a"), .extensionsButton])
        XCTAssertEqual(
            ToolbarZoneSegment.segments(items, overflowAnchor: nil),
            [.extensions(ids: ["b", "a"], menuButton: .trailing, group: 0)]
        )
        XCTAssertEqual(WebContentHeaderView.performanceItems(extensionIDs: []), [.extensionsButton])
    }

    @MainActor
    func testTheAddressBarReservesRoomForTheButtonsPlacedInIt() {
        let standard: [ToolbarItemID] = [.readerView, .siteMemories, .copyURL, .siteMenu]
        XCTAssertEqual(WebContentHeaderView.addressBarReservedWidth(addressItems: standard), 200, "unchanged for the default toolbar")
        XCTAssertEqual(WebContentHeaderView.addressBarReservedWidth(addressItems: [.copyURL]), 200, "never less")
        let two: [ToolbarItemID] = [.extensionAction("a"), .back] + standard
        let added = ToolbarItemView.naturalWidth(of: .extensionAction("a")) + ToolbarItemView.naturalWidth(of: .back) + 2 * 2
        XCTAssertEqual(WebContentHeaderView.addressBarReservedWidth(addressItems: two), 200 + added, accuracy: 0.001)
    }

    // MARK: - Where the "…" goes

    private let standardRight: [ToolbarItemID] = [.extensionAction("a"), .extensionsButton, .memory, .downloads, .feedback, .chat]

    func testTheOverflowButtonTakesFeedbacksSlotWhenFeedbackFolds() {
        let fit = ToolbarOverflow.Fit(visible: [.extensionAction("a"), .extensionsButton, .memory, .downloads, .chat], folded: [.feedback])
        // Between Downloads and Chat.
        XCTAssertEqual(ToolbarOverflow.overflowIndex(arranged: standardRight, fit: fit), 4)
    }

    func testTheOverflowButtonKeepsFeedbacksSlotWhileFeedbackIsHidden() {
        // A guest has no Feedback; Memory folds and Downloads still fits: the "…" stays after Downloads.
        let fit = ToolbarOverflow.Fit(visible: [.extensionAction("a"), .extensionsButton, .downloads, .chat], folded: [.memory])
        XCTAssertEqual(ToolbarOverflow.overflowIndex(arranged: standardRight, fit: fit), 3)
    }

    func testFoldedExtensionsAloneShowNoOverflowButton() {
        let fit = ToolbarOverflow.Fit(visible: [.extensionsButton, .memory, .downloads, .chat], folded: [.extensionAction("a")])
        XCTAssertNil(ToolbarOverflow.overflowIndex(arranged: standardRight, fit: fit))
    }
}

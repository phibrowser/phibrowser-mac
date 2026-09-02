// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class TabStatusTests: XCTestCase {
    func testCornerBadgeIsHiddenWithoutAnActiveStatus() {
        XCTAssertNil(TabCornerBadgeStatus.resolve(
            isAgentActive: false,
            isChatGenerating: false,
            hasPairedChat: false,
            hasStartedChatGeneration: false,
            isChatCollapsed: false
        ))
    }

    func testCornerBadgeShowsChatAfterPairedConversationStartsGenerating() {
        XCTAssertEqual(TabCornerBadgeStatus.resolve(
            isAgentActive: false,
            isChatGenerating: false,
            hasPairedChat: true,
            hasStartedChatGeneration: true,
            isChatCollapsed: false
        ), .chat)
    }

    func testChatBadgeIsHiddenBeforePairedConversationStartsGenerating() {
        XCTAssertNil(TabCornerBadgeStatus.resolve(
            isAgentActive: false,
            isChatGenerating: false,
            hasPairedChat: true,
            hasStartedChatGeneration: false,
            isChatCollapsed: false
        ))
    }

    func testInputtingBadgeTakesPriorityOverChat() {
        XCTAssertEqual(TabCornerBadgeStatus.resolve(
            isAgentActive: false,
            isChatGenerating: true,
            hasPairedChat: true,
            hasStartedChatGeneration: false,
            isChatCollapsed: true
        ), .inputting)
    }

    func testAgentBadgeTakesPriorityOverEveryChatStatus() {
        XCTAssertEqual(TabCornerBadgeStatus.resolve(
            isAgentActive: true,
            isChatGenerating: true,
            hasPairedChat: true,
            hasStartedChatGeneration: true,
            isChatCollapsed: true
        ), .agent)
    }

    func testAgentBadgeIsShownWithoutAPairedChat() {
        XCTAssertEqual(TabCornerBadgeStatus.resolve(
            isAgentActive: true,
            isChatGenerating: false,
            hasPairedChat: false,
            hasStartedChatGeneration: false,
            isChatCollapsed: false
        ), .agent)
    }

    func testChatBadgeIsHiddenWhileChatIsCollapsed() {
        XCTAssertNil(TabCornerBadgeStatus.resolve(
            isAgentActive: false,
            isChatGenerating: false,
            hasPairedChat: true,
            hasStartedChatGeneration: true,
            isChatCollapsed: true
        ))
    }

    func testHighestPriorityCombinesMultipleLiveBookmarkPanes() {
        XCTAssertEqual(
            TabCornerBadgeStatus.highestPriority([.chat, .agent, .inputting]),
            .agent
        )
    }

    func testSplitInputtingBadgeTakesPriorityOverChatPane() {
        XCTAssertEqual(
            TabCornerBadgeStatus.highestPriority([.chat, .inputting]),
            .inputting
        )
    }

    func testDiscardedOutlineClearsRoundedFaviconCorners() {
        XCTAssertEqual(
            TabCornerBadgeMetrics.discardedOutlineSize(
                for: 14,
                cornerRadius: 3
            ),
            21
        )
        XCTAssertEqual(
            TabCornerBadgeMetrics.discardedOutlineSize(
                for: 18,
                cornerRadius: 4
            ),
            26
        )
        XCTAssertEqual(
            TabCornerBadgeMetrics.discardedOutlineSize(
                for: 16,
                cornerRadius: 3
            ),
            24
        )
    }

    func testNormalDiscardedAndUnloadedFaviconsUseDashedOutline() {
        XCTAssertFalse(TabFaviconPresentation.showsDashedOutline(
            isDiscarded: false,
            isUnloaded: false
        ))
        XCTAssertTrue(TabFaviconPresentation.showsDashedOutline(
            isDiscarded: true,
            isUnloaded: false
        ))
        XCTAssertTrue(TabFaviconPresentation.showsDashedOutline(
            isDiscarded: false,
            isUnloaded: true
        ))
        XCTAssertTrue(TabFaviconPresentation.showsDashedOutline(
            isDiscarded: true,
            isUnloaded: true
        ))
    }

    func testOpenPinnedAndBookmarkTabsUseSolidBorder() {
        XCTAssertEqual(
            TabStateBorderStyle.resolve(
                isOpened: true,
                isDiscarded: false,
                isUnloaded: false
            ),
            .solid
        )
        XCTAssertEqual(
            TabStateBorderStyle.resolve(
                isOpened: false,
                isDiscarded: false,
                isUnloaded: false
            ),
            .none
        )
    }

    func testDiscardedAndUnloadedTabsUseDashedBorder() {
        XCTAssertEqual(
            TabStateBorderStyle.resolve(
                isOpened: true,
                isDiscarded: true,
                isUnloaded: false
            ),
            .dashed
        )
        XCTAssertEqual(
            TabStateBorderStyle.resolve(
                isOpened: true,
                isDiscarded: false,
                isUnloaded: true
            ),
            .dashed
        )
    }

    func testAIOutputBecomesChatAfterGeneratingCompletes() {
        var tracker = SidecarAIOutputStateTracker()

        let generating = tracker.apply(SidecarAIOutputPayload(
            tabId: 42,
            windowId: 7,
            active: true,
            phase: .submitted,
            seq: 1
        ))
        XCTAssertEqual(generating?.active, true)
        XCTAssertEqual(generating?.hasStartedGeneration, true)
        XCTAssertEqual(generating?.hasCompletedOutput, false)

        let completed = tracker.apply(SidecarAIOutputPayload(
            tabId: 42,
            windowId: 7,
            active: false,
            phase: .idle,
            seq: 2
        ))
        XCTAssertEqual(completed?.active, false)
        XCTAssertEqual(completed?.hasStartedGeneration, true)
        XCTAssertEqual(completed?.hasCompletedOutput, true)
    }

    func testAIOutputPreservesChatWhileASecondResponseGenerates() {
        var tracker = SidecarAIOutputStateTracker()
        _ = tracker.apply(SidecarAIOutputPayload(
            tabId: 42,
            windowId: 7,
            active: true,
            phase: .streaming,
            seq: 1
        ))
        _ = tracker.apply(SidecarAIOutputPayload(
            tabId: 42,
            windowId: 7,
            active: false,
            phase: .idle,
            seq: 2
        ))

        let generatingAgain = tracker.apply(SidecarAIOutputPayload(
            tabId: 42,
            windowId: 8,
            active: true,
            phase: .submitted,
            seq: 3
        ))
        XCTAssertEqual(generatingAgain?.active, true)
        XCTAssertEqual(generatingAgain?.hasCompletedOutput, true)
        XCTAssertEqual(generatingAgain?.windowId, 8)
    }

    func testAIOutputDropsStaleAndInconsistentMessages() {
        var tracker = SidecarAIOutputStateTracker()
        _ = tracker.apply(SidecarAIOutputPayload(
            tabId: 42,
            windowId: 7,
            active: true,
            phase: .submitted,
            seq: 3
        ))

        XCTAssertNil(tracker.apply(SidecarAIOutputPayload(
            tabId: 42,
            windowId: 7,
            active: false,
            phase: .idle,
            seq: 2
        )))
        XCTAssertNil(tracker.apply(SidecarAIOutputPayload(
            tabId: 42,
            windowId: 7,
            active: false,
            phase: .streaming,
            seq: 4
        )))
        XCTAssertEqual(tracker.statesByTabId[42]?.seq, 3)
    }

    func testIdleWithoutPriorOutputDoesNotCreateChat() {
        var tracker = SidecarAIOutputStateTracker()

        let idle = tracker.apply(SidecarAIOutputPayload(
            tabId: 42,
            windowId: 7,
            active: false,
            phase: .idle,
            seq: 1
        ))

        XCTAssertEqual(idle?.hasStartedGeneration, false)
        XCTAssertEqual(idle?.hasCompletedOutput, false)
    }

    func testRemovingAIOutputStateAllowsARecreatedSidecarSequence() {
        var tracker = SidecarAIOutputStateTracker()
        _ = tracker.apply(SidecarAIOutputPayload(
            tabId: 42,
            windowId: 7,
            active: true,
            phase: .streaming,
            seq: 100
        ))

        tracker.remove(tabId: 42)

        let recreated = tracker.apply(SidecarAIOutputPayload(
            tabId: 42,
            windowId: 7,
            active: true,
            phase: .submitted,
            seq: 1
        ))
        XCTAssertEqual(recreated?.seq, 1)
    }
}

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

    func testDiscardedAndUnloadedFaviconsUseThirtyPercentOpacity() {
        XCTAssertEqual(TabFaviconPresentation.opacity(
            isDiscarded: false,
            isUnloaded: false
        ), 1)
        XCTAssertEqual(TabFaviconPresentation.opacity(
            isDiscarded: true,
            isUnloaded: false
        ), 0.3)
        XCTAssertEqual(TabFaviconPresentation.opacity(
            isDiscarded: false,
            isUnloaded: true
        ), 0.3)
        XCTAssertEqual(TabFaviconPresentation.opacity(
            isDiscarded: true,
            isUnloaded: true
        ), 0.3)
    }

    func testOpenIndicatorOnlyShowsForInactiveOpenTabs() {
        XCTAssertTrue(TabFaviconPresentation.showsOpenIndicator(
            isOpened: true,
            isActive: false
        ))
        XCTAssertFalse(TabFaviconPresentation.showsOpenIndicator(
            isOpened: true,
            isActive: true
        ))
        XCTAssertFalse(TabFaviconPresentation.showsOpenIndicator(
            isOpened: false,
            isActive: false
        ))
    }

    func testOpenIndicatorMetricsMatchPinnedAndBookmarkSpacing() {
        XCTAssertEqual(TabOpenIndicatorMetrics.diameter, 2)
        XCTAssertEqual(TabOpenIndicatorMetrics.pinnedSpacing, 3)
        XCTAssertEqual(TabOpenIndicatorMetrics.comfortablePinnedSpacing, 2)
        XCTAssertEqual(TabOpenIndicatorMetrics.bookmarkSpacing, 2)
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

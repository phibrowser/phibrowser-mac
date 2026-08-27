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
            hasPairedChat: false
        ))
    }

    func testCornerBadgeShowsChatForAPairedConversation() {
        XCTAssertEqual(TabCornerBadgeStatus.resolve(
            isAgentActive: false,
            isChatGenerating: false,
            hasPairedChat: true
        ), .chat)
    }

    func testInputtingBadgeTakesPriorityOverChat() {
        XCTAssertEqual(TabCornerBadgeStatus.resolve(
            isAgentActive: false,
            isChatGenerating: true,
            hasPairedChat: true
        ), .inputting)
    }

    func testAgentBadgeTakesPriorityOverEveryChatStatus() {
        XCTAssertEqual(TabCornerBadgeStatus.resolve(
            isAgentActive: true,
            isChatGenerating: true,
            hasPairedChat: true
        ), .agent)
    }

    func testHighestPriorityCombinesMultipleLiveBookmarkPanes() {
        XCTAssertEqual(
            TabCornerBadgeStatus.highestPriority([.chat, .agent, .inputting]),
            .agent
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
}

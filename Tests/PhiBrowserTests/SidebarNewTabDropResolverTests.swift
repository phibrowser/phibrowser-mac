// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class SidebarNewTabDropResolverTests: XCTestCase {
    // Root rows: Space root 0, separator 1, tabs 2...4, New Tab 5.
    func testBottomButtonPullsADropBelowItAboveIt() {
        XCTAssertEqual(SidebarNewTabDropResolver.rootDropIndex(
            proposed: 6, newTabButtonIndex: 5, buttonAtTop: false), 5)
    }

    func testBottomButtonKeepsDropsAmongTheTabs() {
        for proposed in [0, 2, 4, 5] {
            XCTAssertEqual(SidebarNewTabDropResolver.rootDropIndex(
                proposed: proposed, newTabButtonIndex: 5, buttonAtTop: false), proposed)
        }
    }

    // Root rows: Space root 0, separator 1, New Tab 2, tabs 3...5.
    func testTopButtonPushesADropAboveItBelowIt() {
        XCTAssertEqual(SidebarNewTabDropResolver.rootDropIndex(
            proposed: 2, newTabButtonIndex: 2, buttonAtTop: true), 3)
    }

    func testTopButtonKeepsDropsAmongTheTabsAndInTheBookmarks() {
        for proposed in [0, 1, 3, 6] {
            XCTAssertEqual(SidebarNewTabDropResolver.rootDropIndex(
                proposed: proposed, newTabButtonIndex: 2, buttonAtTop: true), proposed)
        }
    }

    func testDropOnBottomButtonLandsJustAboveIt() {
        XCTAssertEqual(SidebarNewTabDropResolver.rootDropIndex(
            forDropOnButtonAt: 5, buttonAtTop: false), 5)
    }

    func testDropOnTopButtonLandsJustBelowIt() {
        XCTAssertEqual(SidebarNewTabDropResolver.rootDropIndex(
            forDropOnButtonAt: 2, buttonAtTop: true), 3)
    }

    func testListWithoutButtonKeepsTheProposal() {
        XCTAssertEqual(SidebarNewTabDropResolver.rootDropIndex(
            proposed: 4, newTabButtonIndex: nil, buttonAtTop: false), 4)
    }
}

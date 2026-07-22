// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

final class TabMultiSelectionTests: XCTestCase {
    func testEmptyIsNotActive() {
        XCTAssertFalse(TabMultiSelection.empty.isActive)
        XCTAssertTrue(TabMultiSelection.empty.guids.isEmpty)
    }

    func testToggleAddsThenRemoves() {
        var sel = TabMultiSelection.empty
        sel.toggle(10)
        XCTAssertTrue(sel.isActive)
        XCTAssertTrue(sel.contains(10))
        sel.toggle(10)
        XCTAssertFalse(sel.isActive)
        XCTAssertFalse(sel.contains(10))
    }

    func testToggleMultiple() {
        var sel = TabMultiSelection.empty
        sel.toggle(1); sel.toggle(2); sel.toggle(3); sel.toggle(2)
        XCTAssertEqual(sel.guids, [1, 3])
    }

    func testPureOptionClickExcludesSelectionModifiers() {
        var modifiers: NSEvent.ModifierFlags = [.option]
        XCTAssertTrue(modifiers.isPureOptionClick)

        for modifier in [NSEvent.ModifierFlags.command, .shift, .control] {
            modifiers.insert(modifier)
            XCTAssertFalse(modifiers.isPureOptionClick)
            modifiers.remove(modifier)
        }
    }

    func testTabSplitActionRouteChoosesTheExpectedSplitCommand() {
        XCTAssertEqual(
            TabSplitActionRoute.resolve(
                selectedTabId: 1,
                focusedTabId: 1,
                selectedTabIsInSplit: false,
                focusedTabIsInSplit: false
            ),
            .openNewPartner
        )
        XCTAssertEqual(
            TabSplitActionRoute.resolve(
                selectedTabId: 2,
                focusedTabId: 1,
                selectedTabIsInSplit: false,
                focusedTabIsInSplit: false
            ),
            .splitWithFocused(tabId: 1)
        )
    }

    func testTabSplitActionRouteRejectsMissingOrSplitParticipants() {
        XCTAssertNil(
            TabSplitActionRoute.resolve(
                selectedTabId: 1,
                focusedTabId: nil,
                selectedTabIsInSplit: false,
                focusedTabIsInSplit: false
            )
        )
        XCTAssertNil(
            TabSplitActionRoute.resolve(
                selectedTabId: 2,
                focusedTabId: 1,
                selectedTabIsInSplit: true,
                focusedTabIsInSplit: false
            )
        )
        XCTAssertNil(
            TabSplitActionRoute.resolve(
                selectedTabId: 2,
                focusedTabId: 1,
                selectedTabIsInSplit: false,
                focusedTabIsInSplit: true
            )
        )
    }
}

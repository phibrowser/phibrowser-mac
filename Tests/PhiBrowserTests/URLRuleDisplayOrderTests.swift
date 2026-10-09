// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// Pins the URL Rules editor's display order (`SpaceManager.displayOrderedRules`)
/// and its drag-drop restriction (`URLRulesEditor.reorderDestination`). Both are
/// pure, so no store, sync or window is involved.
@MainActor
final class URLRuleDisplayOrderTests: XCTestCase {

    private func rule(_ id: String, _ spaceId: String, _ sortOrder: Int,
                      syncId: String? = nil) -> SpaceRoutingRule {
        SpaceRoutingRule(id: id, spaceId: spaceId, host: "\(id).example",
                         sortOrder: sortOrder, syncId: syncId)
    }

    private func ordered(_ rules: [SpaceRoutingRule], _ spaceOrder: [String]) -> [String] {
        SpaceManager.displayOrderedRules(rules, spaceOrder: spaceOrder).map(\.id)
    }

    func testRulesGroupBySpaceStripOrderNotSpaceIdString() {
        // "z-work" sorts after "a-home" as a string, but is first in the strip.
        let rules = [
            rule("home0", "a-home", 0),
            rule("work0", "z-work", 0),
            rule("home1", "a-home", 1),
        ]
        XCTAssertEqual(ordered(rules, ["z-work", "a-home"]), ["work0", "home0", "home1"])
    }

    func testRulesWithinASpaceFollowSortOrderThenStableKey() {
        let rules = [
            rule("r2", "s1", 2),
            rule("r0", "s1", 0),
            rule("rb", "s1", 1, syncId: "sync-b"),
            rule("ra", "s1", 1, syncId: "sync-a"),
        ]
        XCTAssertEqual(ordered(rules, ["s1"]), ["r0", "ra", "rb", "r2"])
    }

    func testNonSpaceTargetsGoLastInAFixedOrder() {
        let rules = [
            rule("unknown", "missing-space", 0),
            rule("kiosk", SpaceManager.kioskRuleTargetId, 0),
            rule("staleIncognito", SpaceManager.incognitoSpaceIdPrefix + ".runtime-1", 0),
            rule("incognito", SpaceManager.incognitoRuleTargetId, 0),
            rule("space", "s1", 0),
        ]
        // A live Incognito Space in the strip does not pull rules ahead of user Spaces.
        let strip = ["s1", SpaceManager.incognitoSpaceIdPrefix + ".runtime-1"]
        XCTAssertEqual(ordered(rules, strip),
                       ["space", "incognito", "kiosk", "unknown", "staleIncognito"])
    }

    func testDevicesWithDifferentLocalSpaceIdsShowTheSameOrder() {
        // Same account-level rules and Space strip; each device maps the Spaces to its own local ids,
        // with opposite string order.
        func rules(work: String, home: String) -> [SpaceRoutingRule] {
            [
                rule("home0", home, 0, syncId: "h0"),
                rule("work1", work, 1, syncId: "w1"),
                rule("work0", work, 0, syncId: "w0"),
                rule("home1", home, 1, syncId: "h1"),
            ]
        }
        let deviceA = ordered(rules(work: "aaaa", home: "zzzz"), ["aaaa", "zzzz"])
        let deviceB = ordered(rules(work: "zzzz", home: "aaaa"), ["zzzz", "aaaa"])
        XCTAssertEqual(deviceA, ["work0", "work1", "home0", "home1"])
        XCTAssertEqual(deviceA, deviceB)
    }

    // MARK: - Drag restriction

    private func row(_ spaceId: String) -> URLRulesEditor.Row {
        URLRulesEditor.Row(defaultSpaceId: spaceId)
    }

    func testDropWithinTheSameSpaceGroupIsAccepted() {
        let rows = [row("a"), row("a"), row("b"), row("b")]
        // Drag the first "a" row below the second one (drop above index 2).
        XCTAssertEqual(URLRulesEditor.reorderDestination(rows: rows, sourceRow: 0, dropRow: 2), 1)
        // Drag the last "b" row to the top of its group.
        XCTAssertEqual(URLRulesEditor.reorderDestination(rows: rows, sourceRow: 3, dropRow: 2), 2)
    }

    func testDropIntoAnotherSpaceGroupIsRefused() {
        let rows = [row("a"), row("a"), row("b"), row("b")]
        // Between the two "b" rows: the position would snap back after reload.
        XCTAssertNil(URLRulesEditor.reorderDestination(rows: rows, sourceRow: 0, dropRow: 3))
        XCTAssertNil(URLRulesEditor.reorderDestination(rows: rows, sourceRow: 0, dropRow: 4))
        // The only rule of its Space cannot be reordered at all.
        let single = [row("a"), row("b"), row("b")]
        XCTAssertNil(URLRulesEditor.reorderDestination(rows: single, sourceRow: 0, dropRow: 2))
        XCTAssertNil(URLRulesEditor.reorderDestination(rows: single, sourceRow: 0, dropRow: 3))
    }

    func testNoOpAndOutOfRangeDropsAreRefused() {
        let rows = [row("a"), row("a")]
        XCTAssertNil(URLRulesEditor.reorderDestination(rows: rows, sourceRow: 0, dropRow: 0))
        XCTAssertNil(URLRulesEditor.reorderDestination(rows: rows, sourceRow: 0, dropRow: 1))
        XCTAssertNil(URLRulesEditor.reorderDestination(rows: rows, sourceRow: 5, dropRow: 0))
    }
}

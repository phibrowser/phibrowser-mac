// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// The menu-bar Spaces menu caches a POSITION → Space mapping: each item holds
/// the spaceId that sat at its position when the menu was last built, plus that
/// position's ⌃-number key equivalent. AppKit fires those key equivalents while
/// the menu is closed, so the mapping has to be rebuilt whenever the order
/// changes — not only when the user pulls the menu down, which is all
/// `menuWillOpen` ever gave it. Agent Spaces come and go without anyone opening
/// that menu, so with several agents running the mapping drifted and ⌃N
/// activated the Space that used to occupy slot N, while clicking the pip (which
/// carries its own Space's id) still landed correctly.
///
/// `spaceOrderDidChange` is the trigger for that rebuild. This table pins the
/// property the fix depends on: it is ORDER-sensitive, not set-sensitive.
/// Re-expressing it over `Set` — the obvious "same Spaces, nothing to do"
/// optimization — would silently restore the bug for the two cases that move
/// Spaces between positions without adding or removing any: the agent-group
/// partition in `handleSpacesUpdate` and a drag reorder commit.
final class SpacesMenuRebuildTriggerTests: XCTestCase {
    func testUnchangedOrderNeedsNoRebuild() {
        XCTAssertFalse(SpaceManager.spaceOrderDidChange(
            from: ["work", "personal", "R1"],
            to: ["work", "personal", "R1"]))
    }

    func testEmptyToEmptyNeedsNoRebuild() {
        XCTAssertFalse(SpaceManager.spaceOrderDidChange(from: [], to: []))
    }

    /// An agent Space starting: appended at the end of the list. The Spaces
    /// ahead of it keep their ⌃-numbers, but the new one needs its own.
    func testAgentSpaceAppearingNeedsRebuild() {
        XCTAssertTrue(SpaceManager.spaceOrderDidChange(
            from: ["work", "personal"],
            to: ["work", "personal", "R1"]))
    }

    /// An agent Space ending: every agent Space behind it shifts one position
    /// down, which is the shape the user hit — ⌃4 kept naming the Space that had
    /// moved to ⌃3.
    func testAgentSpaceEndingNeedsRebuild() {
        XCTAssertTrue(SpaceManager.spaceOrderDidChange(
            from: ["work", "R1", "R2", "R3"],
            to: ["work", "R2", "R3"]))
    }

    /// Same ids, different positions — the agent-group partition regrouping a
    /// user Space created while agents were live. Nothing was added or removed,
    /// and every cached binding is still wrong.
    func testSameIdsReorderedNeedsRebuild() {
        XCTAssertTrue(SpaceManager.spaceOrderDidChange(
            from: ["work", "R1", "personal"],
            to: ["work", "personal", "R1"]))
    }

    /// A drag reorder commit: two user Spaces swapped, no agent Space involved.
    func testUserReorderNeedsRebuild() {
        XCTAssertTrue(SpaceManager.spaceOrderDidChange(
            from: ["work", "personal"],
            to: ["personal", "work"]))
    }
}

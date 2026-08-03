// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// A lazy reopen replays only part of the restore snapshot and parks the rest
/// in the session file, so this classification decides what the user gets back
/// immediately and what waits behind its Space. Misclassifying eager costs one
/// window's replay time; misclassifying ghost strands a window nothing can
/// navigate to — so every rule here fails toward eager, and only a window
/// whose Space is provably on the strip may park.
///
/// The rules, pinned row by row below: a slot's landing Space replays (R1);
/// a window whose Space is alive but not the landing point parks (R2); a
/// window whose Space is gone replays (R3); a slot whose landing Space owns
/// no window promotes its first surviving window, so a Dock reopen never
/// comes back empty-handed (R4); and Incognito / agent Space windows join
/// neither set, because neither kind exists in the saved session (R5).
final class RestoreWindowClassificationTests: XCTestCase {
    private func classify(
        slots: [(activeSpaceId: String?, windowMap: [Int: String])],
        liveSpaceIds: Set<String>,
        agentSpaceIds: Set<String> = []
    ) -> SpaceManager.RestoreWindowClassification {
        SpaceManager.classifyRestoreWindows(
            slots: slots,
            liveSpaceIds: liveSpaceIds,
            agentSpaceIds: agentSpaceIds
        )
    }

    // MARK: - R1 / R2: landing replays, the rest of the slot parks

    func testLandingSpaceWindowIsEagerAndSiblingsPark() {
        let result = classify(
            slots: [(activeSpaceId: "space-a", windowMap: [1: "space-a", 2: "space-b"])],
            liveSpaceIds: ["space-a", "space-b"]
        )

        XCTAssertEqual(result.eagerWindowIds, [1])
        // The sibling keeps its Space in the answer: it is what maps the
        // parked window back to the strip entry that can materialize it.
        XCTAssertEqual(result.ghostSpaceIdsByWindowId, [2: "space-b"])
    }

    func testSingleSpaceSlotDegeneratesToAllEager() {
        // The common case — one Space per slot — must classify exactly as
        // today's full restore: everything eager, nothing parked.
        let result = classify(
            slots: [(activeSpaceId: "space-a", windowMap: [1: "space-a"])],
            liveSpaceIds: ["space-a"]
        )

        XCTAssertEqual(result.eagerWindowIds, [1])
        XCTAssertTrue(result.ghostSpaceIdsByWindowId.isEmpty)
    }

    // MARK: - R3: a window whose Space is gone fails toward eager

    func testDeletedSpaceWindowIsEagerNotGhost() {
        // "space-b" is no longer in the store, so no strip entry could ever
        // materialize its window. Parking it would strand the window's tabs in
        // the session file for good; replaying it hands them back visibly.
        let result = classify(
            slots: [(activeSpaceId: "space-a", windowMap: [1: "space-a", 2: "space-b"])],
            liveSpaceIds: ["space-a"]
        )

        XCTAssertEqual(result.eagerWindowIds, [1, 2])
        XCTAssertTrue(result.ghostSpaceIdsByWindowId.isEmpty)
    }

    func testPartiallyDeliveredSpaceStoreFailsEager() {
        // Same mechanics as deletion, pinned for the other reason it happens:
        // the SwiftData store's first delivery can be a partial list, and a
        // Space absent from a partial snapshot is NOT deleted. The classifier
        // cannot tell the two apart — which is exactly why absence must widen
        // the eager set rather than park anything. Callers owe it the
        // converged store; a partial one only costs replay time.
        let result = classify(
            slots: [(activeSpaceId: "space-a", windowMap: [1: "space-a", 2: "space-b"])],
            liveSpaceIds: ["space-a"]  // "space-b" exists but has not been delivered yet.
        )

        XCTAssertEqual(result.eagerWindowIds, [1, 2])
        XCTAssertTrue(result.ghostSpaceIdsByWindowId.isEmpty)
    }

    // MARK: - R4: a slot with no landing window still replays one

    func testSlotWithoutLandingWindowPromotesFirstSurvivingSpaceWindow() {
        // The landing Space owns no window (closed separately last session),
        // so the slot would otherwise park everything and a Dock reopen would
        // bring back nothing. Snapshot order within one slot is ascending
        // previous-session window id, and the space names sort the opposite
        // way from their ids — a promotion keyed on names or on dictionary
        // iteration would pick window 7.
        let result = classify(
            slots: [(activeSpaceId: "space-c", windowMap: [7: "aaa-space", 3: "zzz-space"])],
            liveSpaceIds: ["aaa-space", "zzz-space", "space-c"]
        )

        XCTAssertEqual(result.eagerWindowIds, [3])
        XCTAssertEqual(result.ghostSpaceIdsByWindowId, [7: "aaa-space"])
    }

    func testSlotWithNoRecordedLandingSpacePromotesToo() {
        // An entry written before activeSpaceId existed names no landing
        // Space at all; the slot still owes the reopen one window.
        let result = classify(
            slots: [(activeSpaceId: nil, windowMap: [5: "space-a", 8: "space-b"])],
            liveSpaceIds: ["space-a", "space-b"]
        )

        XCTAssertEqual(result.eagerWindowIds, [5])
        XCTAssertEqual(result.ghostSpaceIdsByWindowId, [8: "space-b"])
    }

    func testPromotionPicksTheFirstSurvivingSpaceNotTheFirstWindow() {
        // Window 2 comes first in snapshot order but its Space is gone — R3
        // already replays it. The promotion is what guarantees a window the
        // user can WANT back (a surviving Space's), so it must skip the dead
        // one rather than count it as the slot's guaranteed window.
        let result = classify(
            slots: [(activeSpaceId: "space-c", windowMap: [2: "deleted-space", 9: "space-b"])],
            liveSpaceIds: ["space-b", "space-c"]
        )

        XCTAssertEqual(result.eagerWindowIds, [2, 9])
        XCTAssertTrue(result.ghostSpaceIdsByWindowId.isEmpty)
    }

    func testSlotWhoseEverySpaceIsGoneReplaysEverythingWithNothingToPromote() {
        let result = classify(
            slots: [(activeSpaceId: "space-c", windowMap: [1: "gone-a", 2: "gone-b"])],
            liveSpaceIds: ["space-c"]
        )

        XCTAssertEqual(result.eagerWindowIds, [1, 2])
        XCTAssertTrue(result.ghostSpaceIdsByWindowId.isEmpty)
    }

    func testSlotWithALandingWindowDoesNotPromoteASecondOne() {
        // The guarantee is "at least one", delivered by the landing window
        // itself here — a promotion on top would eat into the lazy win for
        // nothing.
        let result = classify(
            slots: [(
                activeSpaceId: "space-a",
                windowMap: [1: "space-a", 2: "space-b", 3: "space-c"]
            )],
            liveSpaceIds: ["space-a", "space-b", "space-c"]
        )

        XCTAssertEqual(result.eagerWindowIds, [1])
        XCTAssertEqual(result.ghostSpaceIdsByWindowId, [2: "space-b", 3: "space-c"])
    }

    // MARK: - R5: Incognito and agent Space windows join neither set

    func testIncognitoAndAgentSpaceWindowsAreExcludedFromBothSets() {
        // Neither window exists in the saved session (Incognito sessions die
        // with their windows; agent browsers opt out of session restore), so
        // eager would name a window the replay cannot find, and ghost would
        // mint an entry no materialization can ever satisfy.
        let result = classify(
            slots: [(
                activeSpaceId: "space-a",
                windowMap: [
                    1: "space-a",
                    2: "space.incognito-1A2B",
                    3: "agent-space",
                ]
            )],
            liveSpaceIds: ["space-a", "agent-space"],
            agentSpaceIds: ["agent-space"]
        )

        XCTAssertEqual(result.eagerWindowIds, [1])
        XCTAssertTrue(result.ghostSpaceIdsByWindowId.isEmpty)
    }

    func testAgentLandingSpaceStillLeavesTheSlotOneEagerWindow() {
        // An old snapshot can name an agent Space as the landing point. Its
        // window is excluded wholesale, so the slot falls back to promoting
        // its first surviving user-Space window.
        let result = classify(
            slots: [(activeSpaceId: "agent-space", windowMap: [4: "agent-space", 6: "space-b"])],
            liveSpaceIds: ["agent-space", "space-b"],
            agentSpaceIds: ["agent-space"]
        )

        XCTAssertEqual(result.eagerWindowIds, [6])
        XCTAssertTrue(result.ghostSpaceIdsByWindowId.isEmpty)
    }

    func testSweptAgentSpaceWindowFallsBackToEager() {
        // An agent Space that was orphan-swept is in neither the store nor the
        // live agent set, so its window cannot be recognized as agent-owned
        // anymore. It lands on the deleted-Space rule instead — eager — which
        // is harmless: no saved window matches its id, so the replay simply
        // has nothing to do for it. The fail direction matters, not the label.
        let result = classify(
            slots: [(activeSpaceId: nil, windowMap: [8: "swept-agent-space"])],
            liveSpaceIds: []
        )

        XCTAssertEqual(result.eagerWindowIds, [8])
        XCTAssertTrue(result.ghostSpaceIdsByWindowId.isEmpty)
    }

    // MARK: - Several slots

    func testSlotsClassifyIndependentlyAndTheSetsUnion() {
        // Two slots, deliberately on Spaces bound to different profiles — the
        // classification is per window and profile-blind, so each slot
        // contributes its own landing window and its own parked sibling.
        let result = classify(
            slots: [
                (activeSpaceId: "space-a", windowMap: [1: "space-a", 2: "space-b"]),
                (activeSpaceId: "space-c", windowMap: [10: "space-c", 11: "space-d"]),
            ],
            liveSpaceIds: ["space-a", "space-b", "space-c", "space-d"]
        )

        XCTAssertEqual(result.eagerWindowIds, [1, 10])
        XCTAssertEqual(result.ghostSpaceIdsByWindowId, [2: "space-b", 11: "space-d"])
    }

    func testEverySingleSpaceSlotReopensExactlyAsToday() {
        // The multi-slot shape most users actually have: one Space per slot.
        // Lazy restore must be invisible here — all eager, nothing parked.
        let result = classify(
            slots: [
                (activeSpaceId: "space-a", windowMap: [1: "space-a"]),
                (activeSpaceId: "space-b", windowMap: [10: "space-b"]),
            ],
            liveSpaceIds: ["space-a", "space-b"]
        )

        XCTAssertEqual(result.eagerWindowIds, [1, 10])
        XCTAssertTrue(result.ghostSpaceIdsByWindowId.isEmpty)
    }

    func testEmptySnapshotClassifiesToNothing() {
        let result = classify(slots: [], liveSpaceIds: ["space-a"])

        XCTAssertTrue(result.eagerWindowIds.isEmpty)
        XCTAssertTrue(result.ghostSpaceIdsByWindowId.isEmpty)
    }

    func testDuplicateWindowIdAcrossSlotsStaysEagerNotGhost() {
        // A window id can appear in two slots only in a corrupt snapshot —
        // live registration puts each window in exactly one slot. The two
        // sets are a partition to every consumer, and eager is its safe
        // side: honoring the ghost claim would park a window another slot
        // replays.
        let result = classify(
            slots: [
                (activeSpaceId: "space-a", windowMap: [1: "space-a"]),
                (activeSpaceId: "space-b", windowMap: [10: "space-b", 1: "space-c"]),
            ],
            liveSpaceIds: ["space-a", "space-b", "space-c"]
        )

        XCTAssertEqual(result.eagerWindowIds, [1, 10])
        XCTAssertTrue(result.ghostSpaceIdsByWindowId.isEmpty)
    }
}

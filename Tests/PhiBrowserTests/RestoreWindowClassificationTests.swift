// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// A lazy reopen replays only part of the restore snapshot and parks the rest
/// in the session file, so this classification decides what the user gets back
/// immediately and what waits behind its Space.
///
/// A reopen brings back ONE window: the landing entry's active Space — the
/// Space the user was on in the window group that closed last. Everything else
/// parks and comes back when its Space is activated, whether it is a sibling
/// Space of that same group or another group entirely.
///
/// The rules, pinned row by row below: the landing entry's active Space
/// replays (R1); every other window whose Space is alive parks, including the
/// landing entry's own siblings and every window of every other entry (R2); a
/// window whose Space is gone replays instead, because a wrong ghost strands a
/// window nothing can navigate to (R3); a landing entry whose active Space
/// owns no window promotes NOTHING in its place (R4); and Incognito / agent
/// Space windows join neither set, because neither kind exists in the saved
/// session (R5).
final class RestoreWindowClassificationTests: XCTestCase {
    private func classify(
        slots: [(activeSpaceId: String?, windowMap: [Int: String], isLandingEntry: Bool)],
        liveSpaceIds: Set<String>,
        agentSpaceIds: Set<String> = []
    ) -> SpaceManager.RestoreWindowClassification {
        SpaceManager.classifyRestoreWindows(
            slots: slots,
            liveSpaceIds: liveSpaceIds,
            agentSpaceIds: agentSpaceIds
        )
    }

    // MARK: - R1 / R2: the landing Space replays, everything else parks

    func testLandingSpaceWindowIsEagerAndSiblingsPark() {
        let result = classify(
            slots: [(activeSpaceId: "space-a",
                     windowMap: [1: "space-a", 2: "space-b"],
                     isLandingEntry: true)],
            liveSpaceIds: ["space-a", "space-b"]
        )

        XCTAssertEqual(result.eagerWindowIds, [1])
        // The sibling keeps its Space in the answer: it is what maps the
        // parked window back to the strip entry that can materialize it.
        XCTAssertEqual(result.ghostSpaceIdsByWindowId, [2: "space-b"])
    }

    func testSingleSpaceLandingEntryDegeneratesToAllEager() {
        // The common case — one Space, one window — must classify exactly as
        // today's full restore: everything eager, nothing parked.
        let result = classify(
            slots: [(activeSpaceId: "space-a",
                     windowMap: [1: "space-a"],
                     isLandingEntry: true)],
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
        // This is the one rule that can put a second window on screen, and it
        // stays that way on purpose.
        let result = classify(
            slots: [(activeSpaceId: "space-a",
                     windowMap: [1: "space-a", 2: "space-b"],
                     isLandingEntry: true)],
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
            slots: [(activeSpaceId: "space-a",
                     windowMap: [1: "space-a", 2: "space-b"],
                     isLandingEntry: true)],
            liveSpaceIds: ["space-a"]  // "space-b" exists but has not been delivered yet.
        )

        XCTAssertEqual(result.eagerWindowIds, [1, 2])
        XCTAssertTrue(result.ghostSpaceIdsByWindowId.isEmpty)
    }

    // MARK: - R4: no landing window means no window, not a substitute one

    func testLandingEntryWithoutItsLandingWindowPromotesNothing() {
        // The landing Space owns no window — the user left the slot on a Space
        // showing its placeholder. That Space is still the only thing the
        // reopen may bring back, so nothing is promoted in its place and the
        // reopen replays no window at all. The old rule promoted the first
        // surviving Space's window here, which is what made closing one window
        // give a different one back.
        let result = classify(
            slots: [(activeSpaceId: "space-c",
                     windowMap: [7: "aaa-space", 3: "zzz-space"],
                     isLandingEntry: true)],
            liveSpaceIds: ["aaa-space", "zzz-space", "space-c"]
        )

        XCTAssertTrue(result.eagerWindowIds.isEmpty)
        XCTAssertEqual(result.ghostSpaceIdsByWindowId,
                       [7: "aaa-space", 3: "zzz-space"])
    }

    func testEntryWithNoRecordedLandingSpaceParksEverything() {
        // An entry written before activeSpaceId existed names no landing
        // Space at all. Nothing is promoted for it either.
        let result = classify(
            slots: [(activeSpaceId: nil,
                     windowMap: [5: "space-a", 8: "space-b"],
                     isLandingEntry: true)],
            liveSpaceIds: ["space-a", "space-b"]
        )

        XCTAssertTrue(result.eagerWindowIds.isEmpty)
        XCTAssertEqual(result.ghostSpaceIdsByWindowId,
                       [5: "space-a", 8: "space-b"])
    }

    func testLandingEntryReplaysExactlyOneWindow() {
        // Three Spaces in the group the user closed; only the one they were
        // on comes back.
        let result = classify(
            slots: [(
                activeSpaceId: "space-a",
                windowMap: [1: "space-a", 2: "space-b", 3: "space-c"],
                isLandingEntry: true
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
                ],
                isLandingEntry: true
            )],
            liveSpaceIds: ["space-a", "agent-space"],
            agentSpaceIds: ["agent-space"]
        )

        XCTAssertEqual(result.eagerWindowIds, [1])
        XCTAssertTrue(result.ghostSpaceIdsByWindowId.isEmpty)
    }

    func testAgentLandingSpaceLeavesTheReopenWithNoEagerWindow() {
        // An old snapshot can name an agent Space as the landing point. Its
        // window is excluded wholesale, and nothing is promoted in its place,
        // so the surviving user Space simply parks.
        let result = classify(
            slots: [(activeSpaceId: "agent-space",
                     windowMap: [4: "agent-space", 6: "space-b"],
                     isLandingEntry: true)],
            liveSpaceIds: ["agent-space", "space-b"],
            agentSpaceIds: ["agent-space"]
        )

        XCTAssertTrue(result.eagerWindowIds.isEmpty)
        XCTAssertEqual(result.ghostSpaceIdsByWindowId, [6: "space-b"])
    }

    func testSweptAgentSpaceWindowFallsBackToEager() {
        // An agent Space that was orphan-swept is in neither the store nor the
        // live agent set, so its window cannot be recognized as agent-owned
        // anymore. It lands on the deleted-Space rule instead — eager — which
        // is harmless: no saved window matches its id, so the replay simply
        // has nothing to do for it. The fail direction matters, not the label.
        let result = classify(
            slots: [(activeSpaceId: nil,
                     windowMap: [8: "swept-agent-space"],
                     isLandingEntry: true)],
            liveSpaceIds: []
        )

        XCTAssertEqual(result.eagerWindowIds, [8])
        XCTAssertTrue(result.ghostSpaceIdsByWindowId.isEmpty)
    }

    // MARK: - Several entries: only the landing one contributes an eager window

    func testNonLandingEntryParksEverythingIncludingItsOwnActiveSpace() {
        // Two groups, deliberately on Spaces bound to different profiles. The
        // group the user did not close last contributes NO eager window — not
        // even for its own active Space. That is what makes a reopen give back
        // one window instead of one per group, and it holds across profiles
        // exactly as it does within one.
        let result = classify(
            slots: [
                (activeSpaceId: "space-a",
                 windowMap: [1: "space-a", 2: "space-b"],
                 isLandingEntry: true),
                (activeSpaceId: "space-c",
                 windowMap: [10: "space-c", 11: "space-d"],
                 isLandingEntry: false),
            ],
            liveSpaceIds: ["space-a", "space-b", "space-c", "space-d"]
        )

        XCTAssertEqual(result.eagerWindowIds, [1])
        XCTAssertEqual(result.ghostSpaceIdsByWindowId,
                       [2: "space-b", 10: "space-c", 11: "space-d"])
    }

    func testLandingEntryNeedNotBeTheFirstEntry() {
        // The record lists live slots in registry order, which is not the
        // order they were closed in; the marker is what says which one the
        // user was in.
        let result = classify(
            slots: [
                (activeSpaceId: "space-a",
                 windowMap: [1: "space-a"],
                 isLandingEntry: false),
                (activeSpaceId: "space-b",
                 windowMap: [10: "space-b"],
                 isLandingEntry: true),
            ],
            liveSpaceIds: ["space-a", "space-b"]
        )

        XCTAssertEqual(result.eagerWindowIds, [10])
        XCTAssertEqual(result.ghostSpaceIdsByWindowId, [1: "space-a"])
    }

    func testEverySingleSpaceEntryStillReopensExactlyOneWindow() {
        // One Space per group, several groups: still one window back.
        let result = classify(
            slots: [
                (activeSpaceId: "space-a",
                 windowMap: [1: "space-a"],
                 isLandingEntry: true),
                (activeSpaceId: "space-b",
                 windowMap: [10: "space-b"],
                 isLandingEntry: false),
            ],
            liveSpaceIds: ["space-a", "space-b"]
        )

        XCTAssertEqual(result.eagerWindowIds, [1])
        XCTAssertEqual(result.ghostSpaceIdsByWindowId, [10: "space-b"])
    }

    func testUnmarkedRecordLandsOnItsFirstEntry() {
        // A record written before the marker existed has its live slots first,
        // so entry 0 is that record's landing group. Without this fallback such
        // a record would park every window it names and the reopen would come
        // back with nothing.
        let result = classify(
            slots: [
                (activeSpaceId: "space-a",
                 windowMap: [1: "space-a"],
                 isLandingEntry: false),
                (activeSpaceId: "space-b",
                 windowMap: [10: "space-b"],
                 isLandingEntry: false),
            ],
            liveSpaceIds: ["space-a", "space-b"]
        )

        XCTAssertEqual(result.eagerWindowIds, [1])
        XCTAssertEqual(result.ghostSpaceIdsByWindowId, [10: "space-b"])
    }

    func testSeveralMarkedEntriesResolveToTheFirstMarked() {
        // Only a corrupt record marks two. Resolving to the first keeps the
        // answer deterministic and still yields exactly one eager window.
        let result = classify(
            slots: [
                (activeSpaceId: "space-a",
                 windowMap: [1: "space-a"],
                 isLandingEntry: true),
                (activeSpaceId: "space-b",
                 windowMap: [10: "space-b"],
                 isLandingEntry: true),
            ],
            liveSpaceIds: ["space-a", "space-b"]
        )

        XCTAssertEqual(result.eagerWindowIds, [1])
        XCTAssertEqual(result.ghostSpaceIdsByWindowId, [10: "space-b"])
    }

    func testEmptySnapshotClassifiesToNothing() {
        let result = classify(slots: [], liveSpaceIds: ["space-a"])

        XCTAssertTrue(result.eagerWindowIds.isEmpty)
        XCTAssertTrue(result.ghostSpaceIdsByWindowId.isEmpty)
    }

    func testDuplicateWindowIdAcrossEntriesStaysEagerNotGhost() {
        // A window id can appear in two entries only in a corrupt snapshot —
        // live registration puts each window in exactly one slot. The two
        // sets are a partition to every consumer, and eager is its safe
        // side: honoring the ghost claim would park a window the reopen
        // replays.
        let result = classify(
            slots: [
                (activeSpaceId: "space-a",
                 windowMap: [1: "space-a"],
                 isLandingEntry: true),
                (activeSpaceId: "space-b",
                 windowMap: [10: "space-b", 1: "space-c"],
                 isLandingEntry: false),
            ],
            liveSpaceIds: ["space-a", "space-b", "space-c"]
        )

        XCTAssertEqual(result.eagerWindowIds, [1])
        XCTAssertEqual(result.ghostSpaceIdsByWindowId, [10: "space-b"])
    }

    // MARK: - Cold start: every group that was on screen lands its own Space

    // A cold start restores what the user had open when they quit, which is
    // as many window groups as they had — each still eager on its OWN active
    // Space. Same rules as above otherwise; only which entries may land
    // changes, which is why it is a mode rather than an edit to the rules.

    private func classifyColdStart(
        slots: [(activeSpaceId: String?, windowMap: [Int: String], isLandingEntry: Bool)],
        liveSpaceIds: Set<String>,
        parkedOnlyEntryIndices: Set<Int> = [],
        agentSpaceIds: Set<String> = []
    ) -> SpaceManager.RestoreWindowClassification {
        SpaceManager.classifyRestoreWindows(
            slots: slots,
            liveSpaceIds: liveSpaceIds,
            agentSpaceIds: agentSpaceIds,
            mode: .everyOnScreenEntry(
                parkedOnlyEntryIndices: parkedOnlyEntryIndices)
        )
    }

    func testEveryOnScreenGroupLandsItsOwnActiveSpace() {
        // Two windows on screen at quit, two Spaces each. Both come back, and
        // each brings only the Space it was showing.
        let result = classifyColdStart(
            slots: [
                (activeSpaceId: "space-a",
                 windowMap: [1: "space-a", 2: "space-b"],
                 isLandingEntry: true),
                (activeSpaceId: "space-c",
                 windowMap: [3: "space-c", 4: "space-d"],
                 isLandingEntry: false),
            ],
            liveSpaceIds: ["space-a", "space-b", "space-c", "space-d"]
        )

        XCTAssertEqual(result.eagerWindowIds, [1, 3])
        XCTAssertEqual(result.ghostSpaceIdsByWindowId,
                       [2: "space-b", 4: "space-d"])
    }

    func testAGroupTheUserAlreadyClosedLandsNothing() {
        // Entry 0 is a window group closed before the quit; entry 1 was on
        // screen. Only the second comes back — the whole point of the marker.
        let result = classifyColdStart(
            slots: [
                (activeSpaceId: "space-a",
                 windowMap: [1: "space-a"],
                 isLandingEntry: false),
                (activeSpaceId: "space-c",
                 windowMap: [3: "space-c"],
                 isLandingEntry: true),
            ],
            liveSpaceIds: ["space-a", "space-c"],
            parkedOnlyEntryIndices: [0]
        )

        XCTAssertEqual(result.eagerWindowIds, [3])
        XCTAssertEqual(result.ghostSpaceIdsByWindowId, [1: "space-a"])
    }

    func testAnUnmarkedEntryIsTreatedAsHavingBeenOnScreen() {
        // Records written before the marker existed carry it nowhere, and
        // they must still come back. Failing toward eager here is the same
        // direction the marker's own decoder fails in.
        let result = classifyColdStart(
            slots: [
                (activeSpaceId: "space-a",
                 windowMap: [1: "space-a"],
                 isLandingEntry: true),
                (activeSpaceId: "space-c",
                 windowMap: [3: "space-c"],
                 isLandingEntry: false),
            ],
            liveSpaceIds: ["space-a", "space-c"]
        )

        XCTAssertEqual(result.eagerWindowIds, [1, 3])
        XCTAssertTrue(result.ghostSpaceIdsByWindowId.isEmpty)
    }

    func testTheLandingMarkerDoesNotNarrowAColdStart() {
        // `isLandingEntry` decides the reopen's single window; a cold start
        // ignores it entirely. Marking entry 1 must not stop entry 0 landing.
        let result = classifyColdStart(
            slots: [
                (activeSpaceId: "space-a",
                 windowMap: [1: "space-a"],
                 isLandingEntry: false),
                (activeSpaceId: "space-c",
                 windowMap: [3: "space-c"],
                 isLandingEntry: true),
            ],
            liveSpaceIds: ["space-a", "space-c"]
        )

        XCTAssertEqual(result.eagerWindowIds, [1, 3])
    }

    func testTheSameSnapshotStillLandsOneWindowForAReopen() {
        // The control for every case above: the same record, classified the
        // reopen way, still comes back as ONE window. A cold-start edit that
        // widened the shared path would show up here.
        let result = classify(
            slots: [
                (activeSpaceId: "space-a",
                 windowMap: [1: "space-a", 2: "space-b"],
                 isLandingEntry: true),
                (activeSpaceId: "space-c",
                 windowMap: [3: "space-c", 4: "space-d"],
                 isLandingEntry: false),
            ],
            liveSpaceIds: ["space-a", "space-b", "space-c", "space-d"]
        )

        XCTAssertEqual(result.eagerWindowIds, [1])
    }
}

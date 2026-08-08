// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// A parked ghost's Space stays on the strip while its window exists only in
/// the session file, and the slot snapshot is the ONE record tying the two
/// together. Which snapshot entry each ghost rides with therefore decides
/// whether the next launch can pair them up again.
///
/// That used to be decided by a live `SpaceWindowSlot` — an object that dies
/// first. Closing a window group, or an eager window that never arrived, left
/// the record with nobody to speak for it, and the next ordinary write erased
/// the ghosts while Chromium still held their windows: the next launch replayed
/// them as loose windows of a group the snapshot no longer named. Ghosts now
/// ride with the saved entry they were classified from, which is what
/// Chromium's own record is keyed by.
///
/// This table pins the whole window-map layer of one write: what a live slot's
/// map becomes, that a ghost never migrates into another entry, that an entry
/// whose slot is gone is still written (after the live ones, in saved order),
/// and that a write with nothing live in it is refused outright — the refusal
/// that freezes the last layout when the user closes the final window group.
/// The merge rule itself stays where it was (`persistedWindowMap`, pinned by
/// `SlotSnapshotGhostPreservationTests`); this is the layer above it.
final class SlotSnapshotEntryPlanTests: XCTestCase {
    /// Every Space these cases name, so a case that is not about retirement
    /// does not have to say so.
    private static let allSpaces: Set<String> =
        ["space-a", "space-b", "space-c", "space-d"]

    /// `unclaimedWindowIds` defaults to "nothing has been claimed yet", which
    /// is the state a reopen leaves behind and the one most cases are about.
    private func plan(
        liveSlots: [(restoreIndex: Int?, windowMap: [Int: String])] = [],
        savedEntries: [[Int: String]] = [],
        parkedGhosts: [Int: String] = [:],
        closedGroups: [Int: [Int: String]] = [:],
        unclaimedWindowIds: Set<Int>? = nil,
        liveSpaceIds: Set<String> = allSpaces
    ) -> [SpaceManager.PlannedSnapshotEntry] {
        SpaceManager.plannedSnapshotEntries(
            liveSlots: liveSlots,
            restoreEntryWindowMaps: savedEntries,
            parkedGhosts: parkedGhosts,
            closedGroupWindowMaps: closedGroups,
            unclaimedWindowIds: unclaimedWindowIds ?? Set(parkedGhosts.keys),
            liveSpaceIds: liveSpaceIds
        )
    }

    // MARK: - Which entry a parked ghost rides with

    func testAnEntryOwnsExactlyTheParkedWindowsItsOwnMapNames() {
        XCTAssertEqual(
            SpaceManager.entryParkedGhosts(
                recorded: [55: "space-b", 56: "space-c"],
                entryWindowMap: [7: "space-a", 55: "space-b"]),
            [55: "space-b"]
        )
    }

    func testAnEntryThatNamesNoParkedWindowOwnsNone() {
        XCTAssertEqual(
            SpaceManager.entryParkedGhosts(
                recorded: [55: "space-b"],
                entryWindowMap: [7: "space-a"]),
            [:]
        )
    }

    // MARK: - Live entries

    func testASettledSlotWithNothingParkedWritesItsMapUnchanged() {
        // The rollback story, and every run whose reopen did not arm the lazy
        // filter: the record is exactly the one written before ghosts existed.
        XCTAssertEqual(
            plan(liveSlots: [(restoreIndex: 0, windowMap: [101: "space-a"])],
                 savedEntries: [[7: "space-a"]]),
            [SpaceManager.PlannedSnapshotEntry(
                source: .liveSlot(0), windowMap: [101: "space-a"])]
        )
    }

    func testALiveSlotFoldsInTheGhostsOfItsOwnSavedEntry() {
        XCTAssertEqual(
            plan(liveSlots: [(restoreIndex: 0, windowMap: [101: "space-a"])],
                 savedEntries: [[7: "space-a", 55: "space-b"]],
                 parkedGhosts: [55: "space-b"]),
            [SpaceManager.PlannedSnapshotEntry(
                source: .liveSlot(0), windowMap: [101: "space-a", 55: "space-b"])]
        )
    }

    func testAGhostNeverMigratesIntoAnotherGroupsEntry() {
        // Slot 0 reattached to saved entry 0; window 55 was saved with entry 1.
        // Folding it into slot 0 would move a Space into a window group the
        // user never put it in — and the group it belongs to would then be
        // reopened without it.
        XCTAssertEqual(
            plan(liveSlots: [(restoreIndex: 0, windowMap: [101: "space-a"])],
                 savedEntries: [[7: "space-a"], [9: "space-c", 55: "space-b"]],
                 parkedGhosts: [55: "space-b"]),
            [
                SpaceManager.PlannedSnapshotEntry(
                    source: .liveSlot(0), windowMap: [101: "space-a"]),
                SpaceManager.PlannedSnapshotEntry(
                    source: .parkedOnly(1), windowMap: [55: "space-b"]),
            ]
        )
    }

    func testASlotThatClaimedNoSavedEntryFoldsInNothing() {
        // A window opened this run (Cmd+N, a spawn, a materialization) never
        // claimed a saved entry, so it speaks for none of them — and the entry
        // the ghosts were saved with is still written on its own.
        XCTAssertEqual(
            plan(liveSlots: [(restoreIndex: nil, windowMap: [101: "space-a"])],
                 savedEntries: [[7: "space-a", 55: "space-b"]],
                 parkedGhosts: [55: "space-b"]),
            [
                SpaceManager.PlannedSnapshotEntry(
                    source: .liveSlot(0), windowMap: [101: "space-a"]),
                SpaceManager.PlannedSnapshotEntry(
                    source: .parkedOnly(0), windowMap: [55: "space-b"]),
            ]
        )
    }

    // MARK: - Entries nothing live speaks for

    func testAClosedGroupsGhostsSurviveTheNextUnrelatedWrite() {
        // The defect this layer exists for: the user closes the whole group
        // (its write is refused, freezing the record) and then opens one fresh
        // window. That window's write used to rewrite the record from live
        // slots only, erasing ghost entries Chromium still held — and the next
        // launch replayed those windows into whatever group happened to claim
        // them.
        XCTAssertEqual(
            plan(liveSlots: [(restoreIndex: nil, windowMap: [201: "space-a"])],
                 savedEntries: [[7: "space-a", 55: "space-b", 56: "space-c"]],
                 parkedGhosts: [55: "space-b", 56: "space-c"]),
            [
                SpaceManager.PlannedSnapshotEntry(
                    source: .liveSlot(0), windowMap: [201: "space-a"]),
                SpaceManager.PlannedSnapshotEntry(
                    source: .parkedOnly(0),
                    windowMap: [55: "space-b", 56: "space-c"]),
            ]
        )
    }

    func testGhostsOfAnEagerWindowThatNeverArrivedAreStillWritten() {
        // A saved entry whose eager window is no longer in the session file is
        // never claimed, so it has no live slot from the moment the reopen arms
        // — the classifier's R3 rule treats a stale snapshot as routine. Its
        // ghosts must still reach the record, or the reopen's own settle write
        // would erase them.
        XCTAssertEqual(
            plan(liveSlots: [(restoreIndex: 0, windowMap: [101: "space-a"])],
                 savedEntries: [[7: "space-a"], [9: "space-c", 55: "space-b"]],
                 parkedGhosts: [55: "space-b"]).last,
            SpaceManager.PlannedSnapshotEntry(
                source: .parkedOnly(1), windowMap: [55: "space-b"])
        )
    }

    func testAnIncognitoOnlySlotDoesNotTakeItsGhostsDownWithIt() {
        // Slot 0 has windows, but all of them on Incognito Spaces, so it
        // contributes no entry. It must not carry its saved entry's ghosts out
        // of the record on the way past — that was the same defect by another
        // route.
        XCTAssertEqual(
            plan(liveSlots: [
                    (restoreIndex: 0, windowMap: [:]),
                    (restoreIndex: 1, windowMap: [102: "space-c"]),
                 ],
                 savedEntries: [[7: "space-a", 55: "space-b"], [9: "space-c"]],
                 parkedGhosts: [55: "space-b"]),
            [
                SpaceManager.PlannedSnapshotEntry(
                    source: .liveSlot(1), windowMap: [102: "space-c"]),
                SpaceManager.PlannedSnapshotEntry(
                    source: .parkedOnly(0), windowMap: [55: "space-b"]),
            ]
        )
    }

    func testParkedOnlyEntriesFollowTheLiveOnesInSavedOrder() {
        // Live groups first, so a claim contest at the next launch resolves in
        // favour of a group that is actually on screen; the rest in the order
        // they were saved, which is the ordering every other snapshot rule
        // uses.
        XCTAssertEqual(
            plan(liveSlots: [(restoreIndex: 1, windowMap: [101: "space-a"])],
                 savedEntries: [
                    [55: "space-b"], [7: "space-a"], [56: "space-c"],
                 ],
                 parkedGhosts: [55: "space-b", 56: "space-c"]).map(\.source),
            [.liveSlot(0), .parkedOnly(0), .parkedOnly(2)]
        )
    }

    func testAParkedOnlyEntryRetiresGhostsTheSameWayALiveOneDoes() {
        // Window 55 materialized (its id is no longer unclaimed) and Space-c's
        // row was deleted, so neither still describes a parked window. An entry
        // left with nothing is not written at all.
        XCTAssertEqual(
            plan(liveSlots: [(restoreIndex: nil, windowMap: [201: "space-a"])],
                 savedEntries: [[55: "space-b"], [56: "space-c"]],
                 parkedGhosts: [55: "space-b", 56: "space-c"],
                 unclaimedWindowIds: [56],
                 liveSpaceIds: ["space-a", "space-b"]),
            [SpaceManager.PlannedSnapshotEntry(
                source: .liveSlot(0), windowMap: [201: "space-a"])]
        )
    }

    // MARK: - Groups closed while another slot kept writing

    func testAClosedGroupStaysInTheRecordWhileAnotherSlotWrites() {
        // Two groups on screen, and the user closes the one they were working
        // in first. Nothing of it is parked — every Space it held was on
        // screen — so before this the entry matched no rule at all and the
        // surviving slot's next write dropped it. The user then closed that
        // slot too, and the freeze froze a record already missing a whole
        // group: not one window of it came back.
        XCTAssertEqual(
            plan(liveSlots: [(restoreIndex: 1, windowMap: [102: "space-c"])],
                 savedEntries: [[7: "space-a"], [9: "space-c"]],
                 closedGroups: [0: [101: "space-a", 103: "space-b"]]),
            [
                SpaceManager.PlannedSnapshotEntry(
                    source: .liveSlot(0), windowMap: [102: "space-c"]),
                SpaceManager.PlannedSnapshotEntry(
                    source: .parkedOnly(0),
                    windowMap: [101: "space-a", 103: "space-b"]),
            ]
        )
    }

    func testDeletingASpaceTakesItOutOfAClosedGroupsEntry() {
        // The other half of the rule: closing a group keeps it, deleting its
        // Spaces is what removes it. Space-b's row is gone, so the window
        // naming it goes with it and the group comes back with what is left.
        XCTAssertEqual(
            plan(liveSlots: [(restoreIndex: 1, windowMap: [102: "space-c"])],
                 savedEntries: [[7: "space-a"], [9: "space-c"]],
                 closedGroups: [0: [101: "space-a", 103: "space-b"]],
                 liveSpaceIds: ["space-a", "space-c"]).last,
            SpaceManager.PlannedSnapshotEntry(
                source: .parkedOnly(0), windowMap: [101: "space-a"])
        )
    }

    func testDeletingEverySpaceOfAClosedGroupDropsTheEntry() {
        XCTAssertEqual(
            plan(liveSlots: [(restoreIndex: 1, windowMap: [102: "space-c"])],
                 savedEntries: [[7: "space-a"], [9: "space-c"]],
                 closedGroups: [0: [101: "space-a", 103: "space-b"]],
                 liveSpaceIds: ["space-c"]),
            [SpaceManager.PlannedSnapshotEntry(
                source: .liveSlot(0), windowMap: [102: "space-c"])]
        )
    }

    func testAGroupThatWasNeverOnScreenThisRunIsNotResurrected() {
        // No live slot ever spoke for entry 0 and it has nothing parked, so
        // there is no close to remember: the group was already gone when the
        // record was written. Writing it anyway is how a group the user closed
        // in an earlier run comes back on every launch forever.
        XCTAssertEqual(
            plan(liveSlots: [(restoreIndex: 1, windowMap: [102: "space-c"])],
                 savedEntries: [[7: "space-a"], [9: "space-c"]]),
            [SpaceManager.PlannedSnapshotEntry(
                source: .liveSlot(0), windowMap: [102: "space-c"])]
        )
    }

    func testAClosedGroupCarriesItsStillParkedGhostsToo() {
        // A group can close with some of its Spaces parked from an earlier
        // reopen. Both halves ride the same entry, each on its own terms: the
        // ghost retires when its window is claimed, the closed window when its
        // Space is deleted.
        XCTAssertEqual(
            plan(liveSlots: [(restoreIndex: 1, windowMap: [102: "space-c"])],
                 savedEntries: [[7: "space-a", 55: "space-b"], [9: "space-c"]],
                 parkedGhosts: [55: "space-b"],
                 closedGroups: [0: [101: "space-a"]]).last,
            SpaceManager.PlannedSnapshotEntry(
                source: .parkedOnly(0),
                windowMap: [101: "space-a", 55: "space-b"])
        )
    }

    // MARK: - When the whole write is refused

    func testNoLiveEntryRefusesTheWholeWrite() {
        // Closing the last window group. The record it wrote while it was
        // whole has to stand — that freeze is what the next reopen restores
        // from.
        XCTAssertEqual(plan(savedEntries: [[7: "space-a"]]), [])
    }

    func testParkedOnlyEntriesCannotStandAWriteUpOnTheirOwn() {
        // The easiest way to break the freeze: let the leftovers count as
        // content. The record would then name only the parked Spaces of the
        // group the user just closed, and every window that was on screen
        // would be gone from it.
        XCTAssertEqual(
            plan(savedEntries: [[7: "space-a", 55: "space-b"]],
                 parkedGhosts: [55: "space-b"]),
            []
        )
    }

    func testAClosedGroupCannotStandAWriteUpOnItsOwnEither() {
        // The last window group to close leaves a remembered map behind like
        // any other. It must not count as content: the freeze is what the next
        // reopen restores from, and a record naming only groups that are gone
        // would come back without the one that was on screen.
        XCTAssertEqual(
            plan(savedEntries: [[7: "space-a"]],
                 closedGroups: [0: [101: "space-a"]]),
            []
        )
    }

    func testASlotWithNothingWritableRefusesJustLikeNoSlotAtAll() {
        // Every live window on an Incognito Space is the same state as no live
        // window: nothing the next launch can reattach to.
        XCTAssertEqual(
            plan(liveSlots: [(restoreIndex: 0, windowMap: [:])],
                 savedEntries: [[7: "space-a", 55: "space-b"]],
                 parkedGhosts: [55: "space-b"]),
            []
        )
    }

    // MARK: - Which planned entry the reopen lands on

    /// The landing marker is what tells the next reopen which group the user
    /// was in, and therefore which single Space it may replay. Everything else
    /// in the record parks (`RestoreWindowClassificationTests`), so picking the
    /// wrong entry here means reopening onto the wrong Space — with every
    /// window of the right one parked behind it.
    func testTheKeySlotsEntryIsTheLandingEntry() {
        let planned = plan(
            liveSlots: [(restoreIndex: 0, windowMap: [1: "space-a"]),
                        (restoreIndex: 1, windowMap: [2: "space-b"])])

        XCTAssertEqual(
            SpaceManager.landingEntryPosition(planned: planned,
                                              keyLiveSlotPosition: 1),
            1)
    }

    func testTheFirstEntryLandsWhenThereIsNoKeySlot() {
        // No key slot at all (the weak reference cleared as the group came
        // down). Live slots are planned first, so entry 0 is a live one.
        let planned = plan(
            liveSlots: [(restoreIndex: 0, windowMap: [1: "space-a"])],
            savedEntries: [[1: "space-a"], [9: "space-b"]],
            parkedGhosts: [9: "space-b"])

        XCTAssertEqual(planned.count, 2)
        XCTAssertEqual(
            SpaceManager.landingEntryPosition(planned: planned,
                                              keyLiveSlotPosition: nil),
            0)
    }

    func testAKeySlotThatContributedNoEntryFallsBackToTheFirst() {
        // The key slot had every window on an Incognito Space, so it is not in
        // the plan at all. Landing must still name a real entry.
        let planned = plan(
            liveSlots: [(restoreIndex: 0, windowMap: [1: "space-a"]),
                        (restoreIndex: 1, windowMap: [:])])

        XCTAssertEqual(planned.count, 1)
        XCTAssertEqual(
            SpaceManager.landingEntryPosition(planned: planned,
                                              keyLiveSlotPosition: 1),
            0)
    }

    func testAnEmptyPlanHasNoLandingEntry() {
        XCTAssertNil(
            SpaceManager.landingEntryPosition(planned: [],
                                              keyLiveSlotPosition: 0))
    }
}

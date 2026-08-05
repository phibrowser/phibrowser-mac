// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// The slot restore snapshot is the only record of which Spaces shared a macOS
/// window, and the next launch reattaches restored windows from it. Three
/// states make the live layout a transient rather than that record — quit
/// teardown, a reopen still replaying, and a slot draining its windows — and in
/// each of them the last complete snapshot has to stand.
///
/// The rule used to be inline guards nobody could test. These pin it down by
/// table, so a fourth reason added later cannot quietly drop one of the three.
///
/// A fourth reason — a record with nothing live in it — cannot be answered
/// from these three, so it reaches the second table below as an argument; what
/// decides it is pinned separately by `SlotSnapshotEntryPlanTests`.
///
/// What a table cannot reach, and what therefore rests on the comments at each
/// site plus on-device evidence: that `persistSlotsSnapshot` consults these at
/// all, that its arguments are bound to the right properties, that the reopen's
/// completion clears the flag and writes in that order, and — the one the
/// second table is closest to but still does not reach — that `removeSlot`
/// really pairs its ghost drop to the write's answer. Building a
/// `SpaceManager` to cover them is not something this suite can do;
/// `SlotRestoreFrameTests` draws the same line.
final class SlotsSnapshotPersistGateTests: XCTestCase {
    /// A settled single-window session: nothing is tearing down, quitting, or
    /// being restored. Overriding one argument is how each case below names the
    /// single state under test.
    private func mayPersist(
        isTerminating: Bool = false,
        isSessionRestoreInFlight: Bool = false,
        isAnySlotTearingDown: Bool = false
    ) -> Bool {
        SpaceManager.mayPersistSlotsSnapshot(
            isTerminating: isTerminating,
            isSessionRestoreInFlight: isSessionRestoreInFlight,
            isAnySlotTearingDown: isAnySlotTearingDown
        )
    }

    func testWritesWheneverTheLayoutIsSettled() {
        // Load-bearing for every case below: without it a gate that refused
        // everything would satisfy all of them, and the snapshot would simply
        // stop being written.
        XCTAssertTrue(mayPersist())
    }

    func testRefusesWhileAReopenIsStillReplayingTheSession() {
        // The reopen registers its windows one at a time; a write from any of
        // them would replace a healthy group with however much of it exists so
        // far. If the replay never finishes, that half is what the next launch
        // would restore from.
        XCTAssertFalse(mayPersist(isSessionRestoreInFlight: true))
    }

    func testRefusesWhileASlotIsDrainingItsWindows() {
        XCTAssertFalse(mayPersist(isAnySlotTearingDown: true))
    }

    func testRefusesOnceQuitHasBegun() {
        XCTAssertFalse(mayPersist(isTerminating: true))
    }

    func testKeepsRefusingWhenSeveralReasonsOverlap() {
        // A quit landing on a reopen that is still replaying, and a cascade
        // running inside one. Reasons combine; none cancels another out.
        XCTAssertFalse(mayPersist(isTerminating: true, isSessionRestoreInFlight: true))
        XCTAssertFalse(mayPersist(isSessionRestoreInFlight: true, isAnySlotTearingDown: true))
        XCTAssertFalse(mayPersist(isTerminating: true, isAnySlotTearingDown: true))
        XCTAssertFalse(mayPersist(
            isTerminating: true, isSessionRestoreInFlight: true, isAnySlotTearingDown: true))
    }

    // MARK: - The answer the ghost drop pairs to

    /// `removeSlot` retires a removed slot's parked ghosts from the chromium
    /// store — the session file included — only when the write that took them
    /// out of the snapshot actually landed. That answer is this function, and
    /// it has to name all four refusals: the three above, plus a record with
    /// nothing live in it (which only the built record can answer, so it
    /// arrives as `hasLiveSlotEntry`).
    ///
    /// `removeSlot` used to keep its own copy of the list and held one and a
    /// half of the four: a slot closing while a sibling drained its windows
    /// dropped ghosts out of Chromium while the write meant to drop them from
    /// the snapshot was refused, leaving entries the next reopen classified as
    /// ghosts nothing could ever materialize.
    private func writeLands(
        isTerminating: Bool = false,
        isSessionRestoreInFlight: Bool = false,
        isAnySlotTearingDown: Bool = false,
        hasLiveSlotEntry: Bool = true
    ) -> Bool {
        SpaceManager.slotsSnapshotWriteLands(
            isTerminating: isTerminating,
            isSessionRestoreInFlight: isSessionRestoreInFlight,
            isAnySlotTearingDown: isAnySlotTearingDown,
            hasLiveSlotEntry: hasLiveSlotEntry
        )
    }

    func testAWriteOnASettledLayoutLands() {
        // Load-bearing for the cases below, the same way the first case of the
        // gate table is: a function that answered false to everything would
        // satisfy all of them, and no ghost would ever leave the store.
        XCTAssertTrue(writeLands())
    }

    func testARecordWithNothingLiveInItNeverLands() {
        XCTAssertFalse(writeLands(hasLiveSlotEntry: false))
    }

    func testEveryReasonTheGateRefusesIsAReasonNothingLanded() {
        XCTAssertFalse(writeLands(isTerminating: true))
        XCTAssertFalse(writeLands(isSessionRestoreInFlight: true))
        // The one the hand-copied guard was missing, and the one with no
        // bound on how long it lasts: a cascade stalls on an unanswered
        // beforeunload prompt for as long as the user ignores it.
        XCTAssertFalse(writeLands(isAnySlotTearingDown: true))
    }

    // MARK: - The watchdog on the reopen freeze

    /// `isSessionRestoreInFlight` gates every snapshot write, and only the
    /// reopen's completion clears it. A profile whose restore hangs rather than
    /// fails signals no terminal, so the flag would stay set for the life of
    /// the process — the app looks normal and silently stops recording its
    /// layout, losing every window move the user makes afterwards. The watchdog
    /// bounds that.

    func testTheWatchdogDoesNothingWhenTheRestoreAlreadySettled() {
        // The overwhelmingly common case: the deadline arrives after the
        // completion cancelled it, or races it and loses.
        let outcome = SpaceManager.sessionRestoreWatchdogOutcome(isSessionRestoreInFlight: false)
        XCTAssertFalse(outcome.releasesFreeze)
        XCTAssertFalse(outcome.writesSnapshot)
    }

    func testTheWatchdogReleasesTheFreezeWithoutWriting() {
        let outcome = SpaceManager.sessionRestoreWatchdogOutcome(isSessionRestoreInFlight: true)
        XCTAssertTrue(outcome.releasesFreeze)
        // The load-bearing half, and the one a later edit is most likely to get
        // wrong: writing here would persist the very half-restored group the
        // freeze exists to keep out — reintroducing the defect P-D fixed, just
        // at a later moment. Releasing is enough; the next ordinary layout
        // change writes whatever the user actually has by then.
        XCTAssertFalse(outcome.writesSnapshot)
    }
}

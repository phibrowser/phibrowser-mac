// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// The lazy-restore wiring hangs its decisions off pure rules, pinned here
/// the way the classifier and the snapshot writer already are:
///
///   * whether a reopen arms the eager filter at all (`armedEagerWindowIds`)
///     — the switch, the framework probe, and the "parking nothing buys
///     nothing" floor;
///   * whether an activation arriving during that reopen is dropped
///     (`reopenDropsActivations`) — which is what keeps the switch a real
///     rollback rather than a change to the default reopen;
///   * which parked window an activation of a Space materializes
///     (`parkedGhostWindowId(in:forSpaceId:)`) — including the deterministic
///     pick on a corrupt duplicate;
///   * what a failed materialization tells the user
///     (`GhostMaterializeFailureCopy`) — the two outcomes promise opposite
///     things about switching again;
///   * where the coordinator's fallback mint may land
///     (`steeredFallbackMintSpaceId`) — the one resolution that CREATES a
///     window, which must not land on a Space whose window is parked;
///   * which arriving window the coordinator conceals
///     (`concealsRestoredSibling`) — a rebase-fragile anchor whose drift
///     makes a materialized window permanently invisible;
///   * whether a slot minted for a window that never arrived is reclaimed
///     (`reclaimsMintedSlot`) — the drop above gave every mint-then-activate
///     call site a new way to end without a window, and a slot stranded that
///     way disables the windowless reopen for the rest of the run;
///   * which snapshot windows a by-profile claim may take over
///     (`fallbackClaimIndex`) — restore's own stand-in window claims by
///     profile with no grace period, and a parked window's claim surface
///     belongs to the materialization that brings it back.
///
/// What they cannot reach — that `activate`, `deleteSpace`, `changeProfile`
/// and the coordinator feed these rules their real state — rests on the
/// call-site comments, the same line `SlotsSnapshotPersistGateTests` draws.
final class LazySpaceRestoreWiringTests: XCTestCase {
    // MARK: - Arming (what the reopen sends over the bridge)

    private static func classification(
        eager: Set<Int>, ghosts: [Int: String]
    ) -> SpaceManager.RestoreWindowClassification {
        SpaceManager.RestoreWindowClassification(
            eagerWindowIds: eager, ghostSpaceIdsByWindowId: ghosts)
    }

    func testArmingRequiresTheSwitch() {
        XCTAssertNil(SpaceManager.armedEagerWindowIds(
            featureEnabled: false,
            bridgeSupportsLazyRestore: true,
            classification: Self.classification(eager: [1], ghosts: [2: "space-b"])
        ))
    }

    func testArmingRequiresTheSelectorFamily() {
        // An older framework cannot materialize or drop what this reopen
        // would park — so nothing may park.
        XCTAssertNil(SpaceManager.armedEagerWindowIds(
            featureEnabled: true,
            bridgeSupportsLazyRestore: false,
            classification: Self.classification(eager: [1], ghosts: [2: "space-b"])
        ))
    }

    func testArmingThatParksNothingStaysUnarmed() {
        // The eager set is a whitelist to the replay: a saved window outside
        // it parks. With nothing to park, arming buys nothing over the full
        // replay and only widens what a snapshot gap could fall through.
        XCTAssertNil(SpaceManager.armedEagerWindowIds(
            featureEnabled: true,
            bridgeSupportsLazyRestore: true,
            classification: Self.classification(eager: [1, 2], ghosts: [:])
        ))
    }

    func testArmedEagerSetIsSortedAscending() {
        XCTAssertEqual(
            SpaceManager.armedEagerWindowIds(
                featureEnabled: true,
                bridgeSupportsLazyRestore: true,
                classification: Self.classification(
                    eager: [55, 7, 102], ghosts: [9: "space-b"])
            ),
            [7, 55, 102].map { NSNumber(value: $0) }
        )
    }

    // MARK: - Whether a reopen in flight drops activations

    /// The drop exists because an armed reopen leaves part of the group in the
    /// session file while it replays the rest: switching, spawning or
    /// materializing into that races the replay and its per-profile session
    /// commit. An UNARMED reopen replays what this app has always replayed, so
    /// it has to keep meeting activations exactly as it always did — that is
    /// what makes the switch a rollback instead of a change to the shipped
    /// reopen path, which every Dock click takes.

    func testActivationsSurviveAnOrdinaryReopen() {
        // The switch off (and an older framework, and a run that classified
        // nothing as parkable) all land here: a reopen is in flight and
        // activations go through, byte for byte as before the feature.
        XCTAssertFalse(SpaceManager.reopenDropsActivations(
            isSessionRestoreInFlight: true, isLazyReopenArmed: false))
    }

    func testActivationsAreDroppedWhileAnArmedReopenReplays() {
        XCTAssertTrue(SpaceManager.reopenDropsActivations(
            isSessionRestoreInFlight: true, isLazyReopenArmed: true))
    }

    func testNothingIsDroppedOutsideAReopen() {
        // Load-bearing: the latch outlives the reopen that set it (nothing
        // clears it until the next one arms), so the in-flight flag is what
        // bounds the drop. A rule that forgot it would drop every activation
        // for the rest of the run.
        XCTAssertFalse(SpaceManager.reopenDropsActivations(
            isSessionRestoreInFlight: false, isLazyReopenArmed: true))
        XCTAssertFalse(SpaceManager.reopenDropsActivations(
            isSessionRestoreInFlight: false, isLazyReopenArmed: false))
    }

    // MARK: - Which parked window an activation materializes

    func testNoParkedWindowMeansNoMaterialization() {
        XCTAssertNil(SpaceManager.parkedGhostWindowId(
            in: [:], forSpaceId: "space-a"))
        XCTAssertNil(SpaceManager.parkedGhostWindowId(
            in: [55: "space-b"], forSpaceId: "space-a"))
    }

    func testTheSpacesParkedWindowIsFound() {
        XCTAssertEqual(
            SpaceManager.parkedGhostWindowId(
                in: [55: "space-b", 7: "space-a"], forSpaceId: "space-b"),
            55
        )
    }

    func testCorruptDuplicateParkPicksTheLowestIdDeterministically() {
        // A Space maps 1:1 to a window, so two parked ids naming one Space is
        // damage — but the pick must still be the same every time, not
        // whatever a hash walk yields first. Lowest id is the project's one
        // deterministic ordering over snapshot windows.
        XCTAssertEqual(
            SpaceManager.parkedGhostWindowId(
                in: [102: "space-b", 55: "space-b", 7: "space-a"],
                forSpaceId: "space-b"),
            55
        )
    }

    // MARK: - What a failed materialization tells the user

    /// The two outcomes differ in the one way the user acts on: whether the
    /// parked record survived. Kept, switching again retries the same window;
    /// dropped, switching again opens an empty Space. One copy for both made
    /// the second case a lie — it told the user to try again, and trying
    /// again silently replaced their saved tabs with a blank window.

    private static func copy(
        _ outcome: SpaceManager.GhostMaterializeFailure
    ) -> SpaceManager.GhostMaterializeFailureAlertCopy {
        SpaceManager.GhostMaterializeFailureCopy.alert(for: outcome)
    }

    func testEveryFailureHasCopy() {
        // Over `allCases`, not a hand-written pair: a third outcome added
        // later has to bring its copy with it rather than silently escaping.
        for outcome in SpaceManager.GhostMaterializeFailure.allCases {
            XCTAssertFalse(Self.copy(outcome).title.isEmpty, "Missing title for \(outcome)")
            XCTAssertFalse(Self.copy(outcome).message.isEmpty, "Missing message for \(outcome)")
            XCTAssertFalse(Self.copy(outcome).dismissButton.isEmpty,
                           "Missing dismiss button for \(outcome)")
        }
    }

    func testAKeptRecordInvitesAnotherAttempt() {
        XCTAssertTrue(
            Self.copy(.recordKept).message
                .localizedCaseInsensitiveContains("try switching to it again"),
            "A record that survived the failure is worth retrying, and the copy has to say so")
    }

    func testADroppedRecordSaysSwitchingAgainOpensAnEmptyWindow() {
        // The specific promise that has to be there: not "try again", but
        // what actually happens next.
        XCTAssertTrue(
            Self.copy(.recordDropped).message
                .localizedCaseInsensitiveContains("empty window"),
            "A dropped record cannot be retried — the copy has to name what a second switch does")
    }

    func testTheTwoOutcomesNeverReadAlike() {
        XCTAssertNotEqual(Self.copy(.recordKept).message, Self.copy(.recordDropped).message)
        XCTAssertNotEqual(Self.copy(.recordKept).title, Self.copy(.recordDropped).title)
    }

    // MARK: - Where the fallback mint may land

    private static let candidates: [(spaceId: String, profileId: String, isSwitchTarget: Bool)] = [
        (spaceId: "agent", profileId: "p1", isSwitchTarget: false),
        (spaceId: "ghosted", profileId: "p1", isSwitchTarget: true),
        (spaceId: "other-profile", profileId: "p2", isSwitchTarget: true),
        (spaceId: "clear", profileId: "p1", isSwitchTarget: true),
    ]

    func testMintOnANonGhostSpaceStandsUnchanged() {
        XCTAssertEqual(
            SpaceManager.steeredFallbackMintSpaceId(
                resolved: "clear",
                ghostSpaceIds: ["ghosted"],
                candidates: Self.candidates,
                profileId: "p1"),
            "clear"
        )
    }

    func testMintOnAGhostSpaceSteersToTheProfilesFirstClearSwitchTarget() {
        // "agent" is skipped (not a switch target), "other-profile" is
        // skipped (wrong profile) — strip order lands on "clear".
        XCTAssertEqual(
            SpaceManager.steeredFallbackMintSpaceId(
                resolved: "ghosted",
                ghostSpaceIds: ["ghosted"],
                candidates: Self.candidates,
                profileId: "p1"),
            "clear"
        )
    }

    func testMintWithAnEmptyProfileMaySteerAnywhereClear() {
        // A window with no profile constraint takes the first clear switch
        // target in strip order, whatever profile it belongs to.
        XCTAssertEqual(
            SpaceManager.steeredFallbackMintSpaceId(
                resolved: "ghosted",
                ghostSpaceIds: ["ghosted", "clear"],
                candidates: Self.candidates,
                profileId: ""),
            "other-profile"
        )
    }

    func testMintWithNoClearAlternativeKeepsTheGhostSpace() {
        // Every Space of the profile is parked (or unusable): the doubled
        // record is the lesser evil next to presenting the window as another
        // profile's Space, so the resolution stands and the caller logs it.
        XCTAssertEqual(
            SpaceManager.steeredFallbackMintSpaceId(
                resolved: "ghosted",
                ghostSpaceIds: ["ghosted", "clear"],
                candidates: Self.candidates,
                profileId: "p1"),
            "ghosted"
        )
    }

    // MARK: - Which arriving window the coordinator conceals

    /// One of the rebase-fragile anchors this feature registers: concealment
    /// is applied before the window controller exists and undone only by the
    /// restore burst's reveal, so a window concealed by mistake is simply
    /// never seen again.

    func testARestoredSiblingSpaceIsConcealed() {
        XCTAssertTrue(SpaceWindowSlot.concealsRestoredSibling(
            isRestoredWindow: true,
            slotActiveSpaceId: "landing",
            windowSpaceId: "sibling"))
    }

    func testTheRestoredWindowTheSlotLandsOnIsNotConcealed() {
        XCTAssertFalse(SpaceWindowSlot.concealsRestoredSibling(
            isRestoredWindow: true,
            slotActiveSpaceId: "landing",
            windowSpaceId: "landing"))
    }

    func testAWindowThatDidNotComeBackThroughSessionRestoreIsNeverConcealed() {
        // The half that matters for lazy restore: a materialized ghost
        // arrives through the pending-spawn claim, into a slot still showing
        // the Space being switched away from. Comparing Spaces alone would
        // conceal the very window the user asked for.
        XCTAssertFalse(SpaceWindowSlot.concealsRestoredSibling(
            isRestoredWindow: false,
            slotActiveSpaceId: "previous",
            windowSpaceId: "materialized"))
        XCTAssertFalse(SpaceWindowSlot.concealsRestoredSibling(
            isRestoredWindow: false,
            slotActiveSpaceId: nil,
            windowSpaceId: "materialized"))
    }

    func testARestoredWindowIsConcealedWhenTheSlotHasNoLandingSpace() {
        // Pinned because it is the case an extraction is most likely to
        // "clean up" into the opposite answer: a slot whose entry named no
        // active Space conceals its restored windows all the same, and the
        // post-burst reconcile picks which one becomes visible.
        XCTAssertTrue(SpaceWindowSlot.concealsRestoredSibling(
            isRestoredWindow: true,
            slotActiveSpaceId: nil,
            windowSpaceId: "sibling"))
    }

    // MARK: - Whether a minted slot is reclaimed when no window arrives

    /// A slot minted for a window that never arrives is not merely untidy: it
    /// makes `slots.isEmpty` false forever, and that is the whole test the
    /// windowless Dock reopen gates on. Every later reopen then falls back to
    /// Chromium's handler and lands on the wrong Space until the app restarts.
    /// The three inputs are what keeps the cure from being worse than that.

    func testAMintThatNeverGotAWindowIsReclaimed() {
        XCTAssertTrue(SpaceManager.reclaimsMintedSlot(
            mintedForThisAttempt: true, hostsWindow: false, awaitsSpawnedWindow: false))
    }

    func testASlotThisAttemptDidNotMintIsNeverReclaimed() {
        // The call sites resolve `keySlot ?? slots.first ?? mint`, so the
        // failure path routinely holds a slot full of the user's windows —
        // and, while the app is windowless, an empty one another attempt is
        // still waiting on. Neither is this attempt's to drop.
        XCTAssertFalse(SpaceManager.reclaimsMintedSlot(
            mintedForThisAttempt: false, hostsWindow: true, awaitsSpawnedWindow: false))
        XCTAssertFalse(SpaceManager.reclaimsMintedSlot(
            mintedForThisAttempt: false, hostsWindow: false, awaitsSpawnedWindow: false))
    }

    func testAFailureReportedOverALiveWindowReclaimsNothing() {
        // A reported failure does not mean no window: the spawn path reports
        // one when the user switched Space mid-spawn, leaving the spawned
        // window registered and merely hidden. Reclaiming there would take a
        // live window's slot out of the registry.
        XCTAssertFalse(SpaceManager.reclaimsMintedSlot(
            mintedForThisAttempt: true, hostsWindow: true, awaitsSpawnedWindow: false))
    }

    func testAWindowStillOnItsWayKeepsTheSlot() {
        // Nor does a reported failure mean none is coming: a `createBrowser`
        // whose registration callback did not run synchronously reports
        // failure while the windowId-keyed claim still routes the arriving
        // window into this slot — which would then register into a slot the
        // manager no longer knows about.
        XCTAssertFalse(SpaceManager.reclaimsMintedSlot(
            mintedForThisAttempt: true, hostsWindow: false, awaitsSpawnedWindow: true))
    }

    // MARK: - Which snapshot windows a by-profile claim may take over

    /// The by-profile fallback is how restore's own stand-in window finds its
    /// slot, and it matches on profile alone — no id, no grace period. A
    /// parked window is in the restore index all the same (the by-id claim a
    /// materialization makes needs it there, and the persist keeps its ghost
    /// entry alive off it), so without this narrowing that stand-in window
    /// could consume a parked window's claim surface: the entry would retire
    /// while the park record stayed, and the user's Space would answer every
    /// click with a materialization that has nothing left to claim.

    func testAParkedWindowIsNotAvailableToAByProfileClaim() {
        XCTAssertEqual(
            SpaceManager.fallbackClaimIndex(
                [55: 0, 7: 0], parkedGhosts: [55: "space-b"]),
            [7: 0]
        )
    }

    func testUnparkedWindowsOfTheSameEntryStayAvailable() {
        // The park set is per window, not per snapshot entry: a slot that had
        // one Space parked and another restored eagerly still offers the
        // eager one to a by-profile claim.
        XCTAssertEqual(
            SpaceManager.fallbackClaimIndex(
                [55: 0, 7: 0, 102: 1], parkedGhosts: [55: "space-b"]),
            [7: 0, 102: 1]
        )
    }

    func testEveryWindowParkedLeavesNothingToClaim() {
        // The shape the defect surfaced in: a profile whose windows were all
        // parked. The claim finds nobody and the coordinator mints a fresh
        // slot, which is what keeps every parked Space materializable.
        XCTAssertEqual(
            SpaceManager.fallbackClaimIndex(
                [55: 0, 7: 0], parkedGhosts: [55: "space-b", 7: "space-a"]),
            [:]
        )
    }

    func testAReopenThatParkedNothingOffersTheWholeIndex() {
        // The rollback story, here as everywhere else: with nothing parked
        // (switch off, older framework, nothing parkable, or any cold start)
        // the fallback ranks exactly the candidates it always did.
        XCTAssertEqual(
            SpaceManager.fallbackClaimIndex([55: 0, 7: 0], parkedGhosts: [:]),
            [55: 0, 7: 0]
        )
    }
}

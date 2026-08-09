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
///   * which live slots a landed snapshot write adopts into the saved-entry
///     system (`slotAdoptionPlan`) — a minted group without an entry used to
///     fall out of the record on the write that followed its close;
///   * whether an activation arriving during that reopen is dropped
///     (`reopenDropsActivations`) — which is what keeps the switch a real
///     rollback rather than a change to the default reopen;
///   * which parked window an activation of a Space materializes
///     (`parkedGhostWindowId(in:forSpaceId:)`) — including the deterministic
///     pick on a corrupt duplicate;
///   * what a failed materialization tells the user
///     (`GhostMaterializeFailureCopy`) — the two outcomes promise opposite
///     things about switching again;
///   * what Chromium's answer does to the parked record
///     (`materializeFailure(for:)`) — a refusal that leaves the ghost parked
///     must keep it, or the next switch opens an empty window beside the
///     window the session file still describes;
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
///     profile with no grace period, and consuming a parked window's entry
///     would drop that ghost from the next persist AND leave an empty window
///     shadowing the Space it was saved for;
///   * what the reopen does once its restore settles
///     (`reopenSettleOutcome`) — a restore can report success and still put no
///     window on screen, which leaves the app windowless and repeating that
///     same result on every later Dock click until it is restarted;
///   * what Chromium's park receipt does to the recorded ghosts
///     (`reconcileGhostReceipt`) — the record is replaced by the receipt
///     rather than merged with the prediction, and the two ways they can
///     disagree have opposite answers: a predicted ghost Chromium never
///     parked is retired, a parked window this side cannot place is reported
///     and left alone.
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

    // MARK: - Adoption (which live slots a landed write gives a saved entry)

    func testAdoptionPlanSkipsSlotsWithASavedEntry() {
        XCTAssertTrue(SpaceManager.slotAdoptionPlan(
            savedEntryCount: 1,
            liveSlots: [(restoreIndex: 0, windowMap: [1: "space-a"])]
        ).isEmpty)
    }

    func testAdoptionPlanSkipsSlotsWithNothingWritable() {
        // The bar a live slot must clear to be planned at all — and what
        // keeps a slot minted ahead of a window that never arrived from
        // occupying an entry.
        XCTAssertTrue(SpaceManager.slotAdoptionPlan(
            savedEntryCount: 0,
            liveSlots: [(restoreIndex: nil, windowMap: [:])]
        ).isEmpty)
    }

    func testAdoptionAppendsMintedSlotsAfterTheExistingEntries() {
        let plan = SpaceManager.slotAdoptionPlan(
            savedEntryCount: 2,
            liveSlots: [(restoreIndex: 0, windowMap: [1: "space-a"]),
                        (restoreIndex: nil, windowMap: [2: "space-b"]),
                        (restoreIndex: nil, windowMap: [3: "space-c"])])
        XCTAssertEqual(plan.map(\.position), [1, 2])
        XCTAssertEqual(plan.map(\.newIndex), [2, 3])
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

    // MARK: - Which parked window an activation FROM A SLOT materializes

    /// The activation lookup is scoped to the saved entry the activating slot
    /// reattached to — `entryParkedGhosts` (the snapshot writer's ownership
    /// rule) feeding the same deterministic pick as the unscoped lookup. A
    /// ghost belongs to the (entry, Space) combination it was parked from,
    /// and a slot that owns no entry — Cmd+N, a spawn, a materialization —
    /// owns no ghosts. Before this scope, whichever window activated a Space
    /// first claimed any entry's parked ghost (ticket 26).

    private static func entryScopedGhost(
        recorded: [Int: String],
        entryWindowMap: [Int: String],
        spaceId: String
    ) -> Int? {
        SpaceManager.parkedGhostWindowId(
            in: SpaceManager.entryParkedGhosts(
                recorded: recorded, entryWindowMap: entryWindowMap),
            forSpaceId: spaceId)
    }

    func testAnEntryScopedLookupFindsTheEntrysOwnGhost() {
        XCTAssertEqual(
            Self.entryScopedGhost(
                recorded: [55: "space-b", 7: "space-a"],
                entryWindowMap: [55: "space-b", 3: "space-c"],
                spaceId: "space-b"),
            55
        )
    }

    func testAGhostParkedForAnotherEntryIsNotClaimed() {
        // The ticket-26 shape: space-b's ghost (55) was parked from an entry
        // this slot did not reattach to. The unscoped rule handed it over;
        // the scoped one must spawn fresh instead.
        XCTAssertNil(Self.entryScopedGhost(
            recorded: [55: "space-b"],
            entryWindowMap: [9: "space-a"],
            spaceId: "space-b"))
    }

    func testAnEmptyEntryOwnsNoGhosts() {
        XCTAssertNil(Self.entryScopedGhost(
            recorded: [55: "space-b"],
            entryWindowMap: [:],
            spaceId: "space-b"))
    }

    func testEntryScopedDuplicatePickStaysTheLowestId() {
        // Same deterministic ordering as the unscoped rule, applied after the
        // entry filter: only the entry's own duplicates compete.
        XCTAssertEqual(
            Self.entryScopedGhost(
                recorded: [102: "space-b", 55: "space-b", 7: "space-b"],
                entryWindowMap: [102: "space-b", 55: "space-b"],
                spaceId: "space-b"),
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

    // MARK: - What Chromium's answer does to the parked record

    /// The record is the only thing between a refusal and a doubled Space:
    /// drop it and the next switch spawns a fresh window beside the one the
    /// session file still describes, while the alert has already told the
    /// user their tabs are gone. So only the one answer that means "nothing
    /// will ever satisfy this intent" may retire it.

    func testARebuiltGhostIsNotAFailure() {
        XCTAssertNil(SpaceManager.materializeFailure(for: .materialized))
    }

    func testARefusalForNowKeepsTheRecord() {
        // Chromium's transient refusals — the profile not loaded there, a
        // reopen replay of it still in flight — all arrive as this one
        // answer, and every one of them leaves the ghost parked.
        XCTAssertEqual(SpaceManager.materializeFailure(for: .refusedForNow),
                       .recordKept)
    }

    func testOnlyAMissingGhostDropsTheRecord() {
        XCTAssertEqual(SpaceManager.materializeFailure(for: .noSuchGhost),
                       .recordDropped)
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

    func testMintWithNoCandidatesKeepsTheGhostSpace() {
        // Early in a launch the Spaces list is delivered partially and can
        // still be empty — with nothing to steer to, the resolution stands
        // rather than answering an id no Space carries.
        XCTAssertEqual(
            SpaceManager.steeredFallbackMintSpaceId(
                resolved: "ghosted",
                ghostSpaceIds: ["ghosted"],
                candidates: [],
                profileId: "p1"),
            "ghosted"
        )
    }

    func testMintWhoseOnlyCandidateIsTheGhostKeepsIt() {
        // The ghost Space is never its own alternative: steering to it would
        // read as a steer in the log while changing nothing.
        XCTAssertEqual(
            SpaceManager.steeredFallbackMintSpaceId(
                resolved: "ghosted",
                ghostSpaceIds: ["ghosted"],
                candidates: [
                    (spaceId: "ghosted", profileId: "p1", isSwitchTarget: true),
                ],
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
    /// parked window sits in the restore index all the same, because that
    /// index is what the persist writes its ghost entry back from. Without
    /// this narrowing the stand-in window could consume that entry: the ghost
    /// would leave the snapshot at the next persist, and the stand-in would
    /// register on the ghost's own Space — an empty window shadowing the
    /// parked session, with no materialization and no alert.

    func testAParkedWindowIsNotAvailableToAByProfileClaim() {
        // Excluded per window, not per snapshot entry: 7 was saved with the
        // same slot as the parked 55 and still has to be claimable, or a
        // reopen that parked one Space of a slot would strand the rest.
        XCTAssertEqual(
            SpaceManager.fallbackClaimIndex(
                [55: 0, 7: 0], parkedGhosts: [55: "space-b"]),
            [7: 0]
        )
    }

    func testEveryWindowParkedLeavesNothingToClaim() {
        // The shape the defect surfaced in: a profile whose windows were all
        // parked — here across two saved slots. The claim finds nobody and
        // the coordinator mints a fresh slot, which is what keeps every
        // parked Space materializable.
        XCTAssertEqual(
            SpaceManager.fallbackClaimIndex(
                [55: 0, 7: 1], parkedGhosts: [55: "space-b", 7: "space-a"]),
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

    // MARK: - What the reopen does once its restore settles

    /// `restoredAnyWindow` answers whether a profile STARTED a replay, not
    /// whether a window appeared, and a reopen that parks every window of the
    /// session satisfies the first while failing the second. Deciding on it
    /// alone left the app windowless and self-repeating; `reopenSettleOutcome`
    /// takes "did one arrive" as its own input. The source comment carries the
    /// mechanism; this table pins the four quadrants and which one is the
    /// anomaly.

    func testAReopenThatBroughtWindowsBackRepairsTheirSlots() {
        // Load-bearing for the three below: a rule that spawned in every
        // quadrant would satisfy them all, and every ordinary reopen would end
        // with a stray extra window.
        XCTAssertEqual(
            SpaceManager.reopenSettleOutcome(
                restoredAnyWindow: true, isStillWindowless: false),
            .repairSlotsWithAbsentActiveSpace)
    }

    func testARestoreThatReportedAReplayButProducedNoWindowStillSpawns() {
        // The defect. The restore succeeded on chromium's terms and the user's
        // tabs are safe in the session file, but not one window reached this
        // side, so the Dock click the user just made has to produce one — and
        // this is the quadrant that says so in the log.
        XCTAssertEqual(
            SpaceManager.reopenSettleOutcome(
                restoredAnyWindow: true, isStillWindowless: true),
            .spawnPersistedSpaceWindow(restoreProducedNoWindow: true))
    }

    func testNothingRestorableSpawnsAsItAlwaysDid() {
        // Not the anomaly: nothing replayed, so no window was owed by one.
        XCTAssertEqual(
            SpaceManager.reopenSettleOutcome(
                restoredAnyWindow: false, isStillWindowless: true),
            .spawnPersistedSpaceWindow(restoreProducedNoWindow: false))
    }

    func testNothingRestorableSpawnsEvenWithAWindowAlreadyThere() {
        // The quadrant nothing in the product is known to reach, pinned so the
        // narrowing above cannot quietly change it: `restoredAnyWindow ==
        // false` spawned before this rule existed and still does. A window
        // arriving from somewhere else in the gap is not a reason to withhold
        // the one the reopen owes the user.
        XCTAssertEqual(
            SpaceManager.reopenSettleOutcome(
                restoredAnyWindow: false, isStillWindowless: false),
            .spawnPersistedSpaceWindow(restoreProducedNoWindow: false))
    }

    // MARK: - The park receipt (what chromium says it actually parked)

    func testReceiptReplacesThePredictionRatherThanMergingWithIt() {
        // 10 was predicted and really parked; 11 was predicted and never
        // parked; 12 parked without being predicted. Only the receipt
        // survives — a merge would keep 11 and route a Space switch to a
        // materialization that can only fail.
        let reconciliation = SpaceManager.reconcileGhostReceipt(
            receiptWindowIds: [10, 12],
            predicted: [10: "space-a", 11: "space-b"],
            snapshotSpaceIdsByWindowId: [10: "space-a", 11: "space-b",
                                         12: "space-c"])

        XCTAssertEqual(reconciliation.parkedGhostSpaceIdsByWindowId,
                       [10: "space-a", 12: "space-c"])
        XCTAssertEqual(reconciliation.unparked, [11])
        XCTAssertEqual(reconciliation.unmapped, [])
    }

    func testEmptyReceiptClearsEveryRecord() {
        // The arming chromium refused, and the profile that never replayed:
        // nothing is parked, so nothing may stay recorded.
        let reconciliation = SpaceManager.reconcileGhostReceipt(
            receiptWindowIds: [],
            predicted: [10: "space-a", 11: "space-b"],
            snapshotSpaceIdsByWindowId: [10: "space-a", 11: "space-b"])

        XCTAssertEqual(reconciliation.parkedGhostSpaceIdsByWindowId, [:])
        XCTAssertEqual(reconciliation.unparked, [10, 11])
        XCTAssertEqual(reconciliation.unmapped, [])
    }

    func testReceiptWindowNoSpaceMapsToIsReportedNotRecorded() {
        // The reverse divergence, and the half the receipt cannot fix:
        // windowId → spaceId lives only in the snapshot, so a window it never
        // named cannot be placed. It stays parked on the chromium side (the
        // next full restore hands it back) and is reported here.
        let reconciliation = SpaceManager.reconcileGhostReceipt(
            receiptWindowIds: [10, 99],
            predicted: [10: "space-a"],
            snapshotSpaceIdsByWindowId: [10: "space-a"])

        XCTAssertEqual(reconciliation.parkedGhostSpaceIdsByWindowId,
                       [10: "space-a"])
        XCTAssertEqual(reconciliation.unparked, [])
        XCTAssertEqual(reconciliation.unmapped, [99])
    }

    func testReceiptPlacesGhostsOfAProfileThatDidNotReplayFromTheSnapshot() {
        // A profile this reopen never replayed keeps the ghosts an earlier one
        // parked, and this reopen's classification never predicted them. The
        // snapshot still names their Spaces, which is what keeps them
        // reachable instead of stranded.
        let reconciliation = SpaceManager.reconcileGhostReceipt(
            receiptWindowIds: [7],
            predicted: [:],
            snapshotSpaceIdsByWindowId: [7: "space-old"])

        XCTAssertEqual(reconciliation.parkedGhostSpaceIdsByWindowId,
                       [7: "space-old"])
        XCTAssertEqual(reconciliation.unmapped, [])
    }

    func testReceiptReportsBothDivergencesSorted() {
        // Both directions at once, and the order is deterministic so a log
        // bundle reads the same way twice.
        let reconciliation = SpaceManager.reconcileGhostReceipt(
            receiptWindowIds: [30, 20],
            predicted: [12: "space-a", 11: "space-b"],
            snapshotSpaceIdsByWindowId: [11: "space-b", 12: "space-a"])

        XCTAssertEqual(reconciliation.parkedGhostSpaceIdsByWindowId, [:])
        XCTAssertEqual(reconciliation.unparked, [11, 12])
        XCTAssertEqual(reconciliation.unmapped, [20, 30])
    }
}

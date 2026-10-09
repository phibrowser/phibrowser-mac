import Foundation
@main struct StatusTests {
    static func main() async {
        let state = SyncStatusState()
        let round = state.update(.syncing)
        state.update(.syncing)
        state.update(.upToDate, completing: round)
        precondition(state.snapshot.phase == .syncing && state.snapshot.lastSuccess == nil)
        let next = state.update(.syncing)
        state.update(.upToDate, completing: next)
        precondition(state.snapshot.phase == .upToDate && state.snapshot.lastSuccess != nil)
        let ok = SyncContextSnapshot(id: "phi", phase: .upToDate, lastSuccess: Date(timeIntervalSince1970: 100), revision: 1)
        precondition(SyncStatusSummary.reduce(paired: false, requiredIDs: ["phi"], snapshots: [ok]).phase == .notStarted)
        precondition(SyncStatusSummary.reduce(paired: true, requiredIDs: ["phi", "p"], snapshots: [ok]).phase == .checking)
        precondition(SyncStatusSummary.reduce(paired: true, requiredIDs: [], snapshots: [ok]).phase == .checking)
        let bad = SyncContextSnapshot(id: "p", phase: .needsAttention, lastSuccess: nil, revision: 2)
        precondition(SyncStatusSummary.reduce(paired: true, requiredIDs: ["phi", "p"], snapshots: [ok, bad]).phase == .needsAttention)
        for phase in [SyncContextPhase.checking, .offline, .initialSync, .syncing] {
            let other = SyncContextSnapshot(id: "p", phase: phase, lastSuccess: nil, revision: 2)
            precondition(SyncStatusSummary.reduce(paired: true, requiredIDs: ["phi", "p"], snapshots: [ok, other]).phase.rawValue == phase.rawValue)
        }
        let older = SyncContextSnapshot(id: "phi", phase: .needsAttention, lastSuccess: nil, revision: 0)
        precondition(SyncStatusSummary.reduce(paired: true, requiredIDs: ["phi"], snapshots: [ok, older]).phase == .upToDate)
        let other = SyncContextSnapshot(id: "p", phase: .upToDate, lastSuccess: Date(timeIntervalSince1970: 50), revision: 1)
        precondition(SyncStatusSummary.reduce(paired: true, requiredIDs: ["phi", "p"], snapshots: [ok, other]).lastSuccess == Date(timeIntervalSince1970: 50))
        for failing in -1..<6 {
            var flags = [true, true, true, false, false, false]
            if failing >= 0 { flags[failing].toggle() }
            let completion = SyncRoundCompletion(pullDrained: flags[0], outboundAccepted: flags[1], persistenceSucceeded: flags[2], pendingInbound: flags[3], pendingOutbound: flags[4], followupQueued: flags[5])
            precondition(completion.succeeded == (failing == -1))
        }
        print("PASS status: unpaired, missing contexts, partial failure, revisions, timestamp, complete-round predicates")
        testDetailMerge()
        testRoundProblemPrecedence()
        testSyncNowButton()
        testStatusStateDetail()
        testRoundDetail()
        testRoundProblems()
        testNeedsAttentionIsExplained()
        await testConflictStatus()
        await testDomainKeyStatus()
    }
}

func testDetailMerge() {
    let t1 = Date(timeIntervalSince1970: 1000), t2 = Date(timeIntervalSince1970: 2000)
    var first = SyncRoundDetail()
    first.kinds[.settings] = SyncKindStatus(received: 2, sent: 1, pending: 0, held: 0)
    first.kinds[.spaces] = SyncKindStatus(received: 0, sent: 3, pending: 1, held: 2)
    first.kinds[.bookmarks] = SyncKindStatus(received: 5, sent: 0, pending: 0, held: 0)
    let detail = SyncNativeDetail().merging(round: first, at: t1)
    precondition(detail.kinds[.settings] == SyncKindStatus(received: 2, sent: 1, activityAt: t1, pending: 0, held: 0))
    precondition(detail.kinds[.spaces] == SyncKindStatus(received: 0, sent: 3, activityAt: t1, pending: 1, held: 2))
    precondition(detail.kinds[.pinnedTabs] == nil && detail.lastProblem == nil)

    // Settings-only round with no activity: settings keeps its counts and time, other kinds are
    // untouched because the round did not visit them.
    var quiet = SyncRoundDetail()
    quiet.kinds[.settings] = SyncKindStatus(received: 0, sent: 0, activityAt: t2, pending: 0, held: 1)
    let kept = detail.merging(round: quiet, at: t2)
    precondition(kept.kinds[.settings] == SyncKindStatus(received: 2, sent: 1, activityAt: t1, pending: 0, held: 1),
                 "A zero-activity round must keep the previous received/sent and their time")
    precondition(kept.kinds[.spaces] == detail.kinds[.spaces] && kept.kinds[.bookmarks] == detail.kinds[.bookmarks],
                 "Kinds a round did not visit must keep their previous values")

    // A visited kind always takes the table state, even when its activity is kept.
    var drained = SyncRoundDetail()
    drained.kinds[.spaces] = SyncKindStatus(received: 0, sent: 0, pending: 0, held: 0)
    drained.kinds[.bookmarks] = SyncKindStatus(received: 1, sent: 4, pending: 2, held: 0)
    let next = kept.merging(round: drained, at: t2)
    precondition(next.kinds[.spaces] == SyncKindStatus(received: 0, sent: 3, activityAt: t1, pending: 0, held: 0))
    precondition(next.kinds[.bookmarks] == SyncKindStatus(received: 1, sent: 4, activityAt: t2, pending: 2, held: 0))

    var failing = SyncRoundDetail()
    failing.note(.offline)
    let failed = next.merging(round: failing, at: t2)
    precondition(failed.lastProblem == SyncErrorSummary(category: .offline, kind: nil, at: t2))
    precondition(failed.merging(round: SyncRoundDetail(), at: t2.addingTimeInterval(1)).lastProblem == failed.lastProblem,
                 "A round without a problem must not clear the last problem by itself")

    precondition(SyncKind(ownedLabel: "bookmarks") == .bookmarks && SyncKind(ownedLabel: "pins") == .pinnedTabs
                 && SyncKind(ownedLabel: "urlrules") == .urlRules && SyncKind(ownedLabel: "spaces") == nil)
    print("PASS detail merge: unvisited kinds, zero-activity rounds, table state, problem replacement, owned labels")
}

func testRoundProblemPrecedence() {
    let order = SyncProblemCategory.allCases
    for (index, winner) in order.enumerated() {
        for loser in order[index...] {
            for reversed in [false, true] {
                var round = SyncRoundDetail()
                if reversed { round.note(loser, kind: .spaces); round.note(winner, kind: .bookmarks) }
                else { round.note(winner, kind: .bookmarks); round.note(loser, kind: .spaces) }
                precondition(round.problem == winner, "\(winner) must win over \(loser)")
                if winner != loser || !reversed { precondition(round.problemKind == .bookmarks) }
            }
        }
    }
    precondition(Array(order.prefix(8)) == [.resetRequired, .saveFailedOnThisMac, .readFailedOnThisMac,
                                             .signInExpired, .offline, .rejectedByServer, .serverError,
                                             .unreadableRemoteData])
    print("PASS problem precedence: most severe category wins, first report of a category keeps its kind")
}

func testSyncNowButton() {
    typealias B = SyncNowButtonState
    let at = Date(timeIntervalSince1970: 10)
    let cases: [(SyncRequestState, B)] = [
        (.idle, B(isVisible: true, isEnabled: true, showsProgress: false, hint: .none)),
        (.inFlight(startedAt: at), B(isVisible: true, isEnabled: false, showsProgress: true, hint: .none)),
        (.queued(reason: .busy, notBefore: nil), B(isVisible: true, isEnabled: false, showsProgress: true, hint: .waitingForCurrentSync)),
        (.queued(reason: .rateLimited, notBefore: at), B(isVisible: true, isEnabled: false, showsProgress: true, hint: .startingShortly)),
        (.queued(reason: .unobservable, notBefore: nil), B(isVisible: true, isEnabled: false, showsProgress: true, hint: .waitingForProfiles)),
        (.rejected, B(isVisible: true, isEnabled: true, showsProgress: false, hint: .failed)),
    ]
    let running = B(isVisible: true, isEnabled: false, showsProgress: true, hint: .none)
    for summary in [SyncSummaryPhase.checking, .initialSync, .syncing, .upToDate, .offline, .needsAttention] {
        for (request, expected) in cases {
            // Any running sync disables an idle control, including rounds the request did not start.
            let busy = request == .idle && (summary == .syncing || summary == .initialSync)
            precondition(B.reduce(summary: summary, request: request) == (busy ? running : expected),
                         "\(summary) \(request)")
        }
    }
    for (request, _) in cases {
        precondition(B.reduce(summary: .notStarted, request: request)
                     == B(isVisible: false, isEnabled: false, showsProgress: false, hint: .none))
    }
    print("PASS Sync now button: truth table over summary phases and request states")
}

func testStatusStateDetail() {
    let state = SyncStatusState()
    precondition(state.snapshot.detail == nil, "No detail before the first round")
    let older = state.update(.syncing)
    var failing = SyncRoundDetail()
    failing.kinds[.settings] = SyncKindStatus(received: 1)
    failing.note(.offline)
    let newer = state.update(.offline, round: failing)
    precondition(newer > older && state.snapshot.detail?.lastProblem?.category == .offline)
    // An older round completing after newer detail neither clears its problem nor its counts.
    let completed = state.update(.upToDate, completing: older, round: SyncRoundDetail())
    precondition(completed > newer && state.snapshot.phase == .syncing)
    precondition(state.snapshot.detail?.lastProblem?.category == .offline
                 && state.snapshot.detail?.kinds[.settings]?.received == 1,
                 "An older revision must not overwrite newer detail")
    // Local edits and other phase-only updates carry the detail forward.
    state.update(.syncing)
    precondition(state.snapshot.detail?.kinds[.settings]?.received == 1)
    let round = state.update(.syncing)
    state.update(.upToDate, completing: round, round: SyncRoundDetail())
    precondition(state.snapshot.phase == .upToDate && state.snapshot.detail?.lastProblem == nil
                 && state.snapshot.detail?.kinds[.settings]?.received == 1)
    precondition(SyncContextSnapshot(id: "p", phase: .upToDate, lastSuccess: nil, revision: 1).detail == nil)
    print("PASS status state detail: revision per detail change, older round cannot clear newer problem, success clears it")
}

func testRoundDetail() {
    let f = ConflictFixture(kind: .space, retryResult: .accepted)
    f.canPublishThisRound = true
    f.settingsReceivedThisRound = 2; f.settingsSentThisRound = 1
    f.spaceCounters = SpaceRoundCounters(tombstones: 1, pushed: 2, conflicts: 1, applied: 3)
    var deleting = PhiSpaceCursor(); deleting.pendingDelete = true
    var projecting = PhiSpaceCursor(); projecting.pendingProjection = Data([1])
    var parked = PhiSpaceCursor(); parked.pendingApply = Data([1])
    var held = PhiSpaceCursor(); held.heldProfileUuid = "profile"
    var tombstoned = PhiSpaceCursor(); tombstoned.pendingTombstone = true
    f.spaceTable.cursors = ["a": deleting, "b": projecting, "c": parked, "d": held, "e": tombstoned, "f": PhiSpaceCursor()]
    var ownedDelete = PhiOwnedItemCursor(); ownedDelete.pendingDelete = true
    var ownedParked = PhiOwnedItemCursor(); ownedParked.pendingApply = Data([1])
    var ownedTombstone = PhiOwnedItemCursor(); ownedTombstone.pendingTombstone = true
    var ownedPartner = PhiOwnedItemCursor(); ownedPartner.pendingPartnerLineage = "lineage"
    f.ownedTables["bookmarks"] = PhiOwnedItemTable(cursors: ["x": ownedDelete, "y": ownedParked, "z": ownedTombstone,
                                                             "w": ownedPartner])
    // pendingPublish (2) already includes the over-budget delete "x"; the status must not add it twice.
    f.ownedCounters["bookmarks"] = OwnedRoundCounters(pendingPublish: 2, tombstones: 1, pushed: 1, applied: 4,
                                                      liveUnpublished: 1, publicationCounted: true)
    f.ownedTables["pins"] = PhiOwnedItemTable()
    let first = f.finish()
    let firstKinds = first.detail?.kinds ?? [:]
    let at = firstKinds[.settings]?.activityAt
    precondition(at != nil)
    precondition(firstKinds[.settings] == SyncKindStatus(received: 2, sent: 1, activityAt: at, pending: 0, held: 0))
    precondition(firstKinds[.spaces] == SyncKindStatus(received: 3, sent: 3, activityAt: at, pending: 2, held: 3),
                 "Space pending/held come from the table, received/sent from the round counters")
    precondition(firstKinds[.bookmarks] == SyncKindStatus(received: 4, sent: 2, activityAt: at, pending: 2, held: 3),
                 "Owned pending is unpublished live edits plus pending-delete cursors, each counted once; "
                 + "held is parked, tombstone-parked or waiting for a split partner")
    precondition(firstKinds[.pinnedTabs] == SyncKindStatus() && firstKinds[.urlRules] == nil,
                 "A loaded kind without activity reports zeros; an unloaded kind is left out")
    precondition(first.phase == .needsAttention && first.detail?.lastProblem == nil,
                 "Held items alone explain Needs attention through the held count, not a problem category")

    // Gate shut, settings-only round with a local save failure.
    f.spaceSectionEnabled = false
    f.settingsReceivedThisRound = 0; f.settingsSentThisRound = 0
    f.spaceCounters = SpaceRoundCounters(); f.ownedCounters = [:]; f.spaceTable.cursors = [:]
    f.cursorSaveFailures = 1
    let second = f.finish()
    precondition(second.revision > first.revision)
    precondition(second.detail?.kinds[.spaces] == SyncKindStatus(received: 3, sent: 3, activityAt: at, pending: 0, held: 0),
                 "A gate-shut round still reads the Space table: activity is kept, pending and held follow the table")
    precondition(second.detail?.kinds[.bookmarks] == firstKinds[.bookmarks],
                 "Owned kinds a gate-shut round did not visit keep their values")
    precondition(second.detail?.kinds[.settings] == firstKinds[.settings], "A zero-activity round keeps received/sent")
    precondition(second.phase == .needsAttention && second.detail?.lastProblem?.category == .saveFailedOnThisMac)

    // Gate open again, drained tables, nothing loaded for owned kinds: success clears the problem.
    f.spaceSectionEnabled = true; f.cursorSaveFailures = 0; f.ownedTables = [:]
    let third = f.finish()
    precondition(third.phase == .upToDate && third.detail?.lastProblem == nil)
    precondition(third.detail?.kinds[.spaces] == SyncKindStatus(received: 3, sent: 3, activityAt: at, pending: 0, held: 0))
    precondition(third.detail?.kinds[.bookmarks] == firstKinds[.bookmarks])

    // A loaded owned kind whose publication pass did not run keeps its last known pending count.
    f.ownedTables = ["bookmarks": PhiOwnedItemTable()]
    f.ownedCounters = ["bookmarks": OwnedRoundCounters()]
    let unpublished = f.finish()
    precondition(unpublished.detail?.kinds[.bookmarks]?.pending == 2 && unpublished.detail?.kinds[.bookmarks]?.held == 0)
    f.ownedCounters = ["bookmarks": OwnedRoundCounters(publicationCounted: true)]
    precondition(f.finish().detail?.kinds[.bookmarks]?.pending == 0, "A publication pass with nothing left clears it")
    f.ownedTables = [:]; f.ownedCounters = [:]

    // A problem stays through a round that neither fails nor succeeds.
    f.noteError(URLError(.notConnectedToInternet))
    precondition(f.finish().detail?.lastProblem?.category == .offline)
    f.spaceTable.cursors = ["b": projecting]
    let pending = f.finish()
    precondition(pending.phase == .syncing && pending.detail?.lastProblem?.category == .offline,
                 "Only a fully successful round clears the last problem")
    f.spaceTable.cursors = [:]
    f.requiresReconfiguration = true
    let reset = f.finish()
    precondition(reset.phase == .needsAttention && reset.detail?.lastProblem?.category == .resetRequired)
    print("PASS round detail: Space/owned/settings counts, unvisited kinds, held without category, clearing rule, reset")
}

/// Whenever a native round ends Needs attention, the pane can explain it: some held count is
/// non-zero or a problem category is recorded. One fresh round per Needs-attention condition of
/// `finishStatusRound`.
func testNeedsAttentionIsExplained() {
    typealias Stage = (ConflictFixture) -> Void
    func owned(_ edit: @escaping (inout PhiOwnedItemCursor) -> Void) -> Stage {
        { var cursor = PhiOwnedItemCursor(); edit(&cursor)
          $0.ownedTables["bookmarks"] = PhiOwnedItemTable(cursors: ["b": cursor]) }
    }
    func space(_ edit: @escaping (inout PhiSpaceCursor) -> Void) -> Stage {
        { var cursor = PhiSpaceCursor(); edit(&cursor); $0.spaceTable.cursors = ["s": cursor] }
    }
    let stages: [(String, Stage)] = [
        ("outbound failure", { $0.roundOutboundFailed = true }),
        ("cursor save failure", { $0.cursorSaveFailures = 1 }),
        ("cursor save outcome", { $0.roundOutcome = .cursorSaveFailed }),
        ("pull failure", { $0.noteError(PhiSyncProtocolError.http(500)); $0.roundOutcome = .pullFailed }),
        ("unusable settings", { $0.roundOutcome = .unusableSettings }),
        ("unreadable settings", { $0.unreadableSettingsRecord = Data() }),
        ("Space pendingApply", space { $0.pendingApply = Data([1]) }),
        ("Space held for a Profile", space { $0.heldProfileUuid = "profile" }),
        ("Space pendingTombstone", space { $0.pendingTombstone = true }),
        ("Space parked, gate shut", { f in
            f.spaceSectionEnabled = false
            var cursor = PhiSpaceCursor(); cursor.pendingApply = Data([1]); f.spaceTable.cursors = ["s": cursor] }),
        ("unreadable tags", { $0.spaceTable.unreadableTagHashes = ["tag": "reason"] }),
        ("owned pendingApply", owned { $0.pendingApply = Data([1]) }),
        ("owned pendingTombstone", owned { $0.pendingTombstone = true }),
        ("owned pendingPartnerLineage", owned { $0.pendingPartnerLineage = "lineage" }),
        ("owned local read failure", { $0.ownedReadFailed = ["bookmarks"] }),
        ("reconfiguration required", { $0.requiresReconfiguration = true }),
    ]
    for (name, stage) in stages {
        let f = ConflictFixture(kind: .space, retryResult: .accepted)
        f.canPublishThisRound = true
        stage(f)
        let snapshot = f.finish()
        precondition(snapshot.phase == .needsAttention, "\(name): expected Needs attention, got \(snapshot.phase)")
        let held = snapshot.detail?.kinds.values.contains { $0.held > 0 } ?? false
        precondition(held || snapshot.detail?.lastProblem != nil, "\(name): Needs attention without a held count or a category")
    }
    print("PASS needs attention: every condition leaves a held count or a problem category")
}

func testRoundProblems() {
    typealias Stage = (ConflictFixture) -> Void
    let cases: [(Stage, SyncProblemCategory, SyncKind?)] = [
        ({ $0.noteError(PhiSyncProtocolError.http(502)) }, .serverError, nil),
        ({ $0.noteError(PhiSyncProtocolError.http(401)) }, .signInExpired, nil),
        ({ $0.noteError(PhiSyncProtocolError.http(403)) }, .signInExpired, nil),
        ({ $0.noteError(URLError(.cannotConnectToHost)) }, .offline, nil),
        ({ $0.unreadableSettingsRecord = Data() }, .unreadableRemoteData, .settings),
        ({ $0.roundOutcome = .unusableSettings }, .unreadableRemoteData, .settings),
        // The Space table also quarantines owned kinds' tags, so the category carries no kind.
        ({ $0.spaceTable.unreadableTagHashes = ["tag": "reason"] }, .unreadableRemoteData, nil),
        ({ $0.ownedReadFailed = ["urlrules", "pins"] }, .readFailedOnThisMac, .pinnedTabs),
        ({ $0.roundOutcome = .cursorSaveFailed }, .saveFailedOnThisMac, nil),
        // Owned unreadable arrivals do not fail a round by themselves; with a parked row they explain it.
        ({ var parked = PhiOwnedItemCursor(); parked.pendingApply = Data([1])
           $0.ownedTables["pins"] = PhiOwnedItemTable(cursors: ["p": parked])
           $0.ownedCounters["pins"] = OwnedRoundCounters(unreadable: 1) },
         .unreadableRemoteData, .pinnedTabs),
        // Precedence inside one round.
        ({ $0.cursorSaveFailures = 1; $0.noteError(URLError(.notConnectedToInternet)) }, .saveFailedOnThisMac, nil),
        ({ $0.noteError(PhiSyncProtocolError.http(500)); $0.noteError(URLError(.timedOut)) }, .offline, nil),
        ({ $0.spaceTable.unreadableTagHashes = ["tag": "reason"]; $0.noteError(PhiSyncProtocolError.http(500)) },
         .serverError, nil),
        ({ $0.cursorSaveFailures = 1; $0.requiresReconfiguration = true }, .resetRequired, nil),
    ]
    for (index, (stage, category, kind)) in cases.enumerated() {
        let f = ConflictFixture(kind: .space, retryResult: .accepted)
        f.canPublishThisRound = true
        stage(f)
        let snapshot = f.finish()
        precondition(snapshot.detail?.lastProblem?.category == category && snapshot.detail?.lastProblem?.kind == kind,
                     "case \(index): expected \(category) \(String(describing: kind)), got \(String(describing: snapshot.detail?.lastProblem))")
        precondition(snapshot.phase != .upToDate)
    }
    print("PASS round problems: HTTP 5xx/401/403, offline, unreadable settings/Spaces/owned, save failure, reset, precedence")
}

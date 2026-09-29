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
    precondition(Array(order.prefix(7)) == [.resetRequired, .saveFailedOnThisMac, .signInExpired, .offline,
                                             .rejectedByServer, .serverError, .unreadableRemoteData])
    print("PASS problem precedence: most severe category wins, first report of a category keeps its kind")
}

func testSyncNowButton() {
    typealias B = SyncNowButtonState
    let at = Date(timeIntervalSince1970: 10)
    let cases: [(SyncRequestState, B)] = [
        (.idle, B(isVisible: true, isEnabled: true, showsProgress: false, hint: .none)),
        (.inFlight(startedAt: at), B(isVisible: true, isEnabled: false, showsProgress: true, hint: .none)),
        (.queued(reason: .busy, notBefore: nil), B(isVisible: true, isEnabled: false, showsProgress: true, hint: .waitingForCurrentSync)),
        (.queued(reason: .rateLimited, notBefore: at), B(isVisible: true, isEnabled: false, showsProgress: true, hint: .waitingForCurrentSync)),
        (.queued(reason: .unobservable, notBefore: nil), B(isVisible: true, isEnabled: false, showsProgress: true, hint: .waitingForProfiles)),
        (.rejected, B(isVisible: true, isEnabled: true, showsProgress: false, hint: .failed)),
    ]
    for summary in [SyncSummaryPhase.checking, .initialSync, .syncing, .upToDate, .offline, .needsAttention] {
        for (request, expected) in cases {
            precondition(B.reduce(summary: summary, request: request) == expected, "\(summary) \(request)")
        }
    }
    for (request, _) in cases {
        precondition(B.reduce(summary: .notStarted, request: request)
                     == B(isVisible: false, isEnabled: false, showsProgress: false, hint: .none))
    }
    print("PASS Sync now button: truth table over summary phases and request states")
}

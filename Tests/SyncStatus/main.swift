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
        await testConflictStatus()
        await testDomainKeyStatus()
    }
}

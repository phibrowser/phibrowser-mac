import Foundation

@MainActor final class Fixture {
    var time = Date(timeIntervalSince1970: 100)
    var paired = true
    var ids = ["phi", "profile"]
    var snapshots: [String: SyncContextSnapshot] = [:]
    var requests: [String: Int] = [:]
    var saved: Date?
    var saves = 0
    var canSave = true
    func status(_ id: String, _ phase: SyncContextPhase, at time: TimeInterval? = nil) {
        snapshots[id] = SyncContextSnapshot(id: id, phase: phase,
            lastSuccess: time.map(Date.init(timeIntervalSince1970:)), revision: (snapshots[id]?.revision ?? 0) + 1)
    }
    func participant(_ id: String) -> SyncHelper.Participant {
        SyncHelper.Participant(id: id, read: { self.snapshots[id] }, requestSync: {
            self.requests[id, default: 0] += 1
        })
    }
    func helper() -> SyncHelper {
        SyncHelper(isEligible: { self.paired }, participants: { self.ids.map(self.participant) },
                   lastSuccess: saved, saveSuccess: { date in
                       self.saves += 1
                       guard self.canSave else { return false }
                       self.saved = date; return true
                   }, now: { self.time })
    }
}

@main struct HelperTests {
    @MainActor static func main() async {
        let f = Fixture(), helper = f.helper()
        f.status("phi", .upToDate, at: 90); f.status("profile", .upToDate, at: 80)
        await helper.refresh()
        precondition(helper.report.summary.phase == .syncing && helper.report.summary.lastSuccess == nil,
                     "Old independent successes must start a new coordinated round")
        precondition(f.requests == ["phi": 1, "profile": 1])
        f.time = Date(timeIntervalSince1970: 103)
        f.status("phi", .upToDate, at: 102)
        await helper.refresh()
        precondition(f.saved == nil, "Native success cannot advance the common time alone")
        f.status("profile", .upToDate, at: 103)
        await helper.refresh()
        precondition(f.saved == f.time && helper.report.summary.phase == .upToDate)
        await helper.refresh()
        precondition(f.saves == 1 && f.requests["phi"] == 1, "Refresh completions must not feed back into endless rounds")
        f.time = Date(timeIntervalSince1970: 110)
        f.status("profile", .upToDate, at: 109)
        await helper.refresh()
        precondition(f.requests["phi"] == 2 && helper.report.summary.lastSuccess == Date(timeIntervalSince1970: 103))
        f.status("phi", .upToDate, at: 112); f.status("profile", .offline)
        await helper.refresh()
        precondition(helper.report.summary.phase == .offline && f.saved == Date(timeIntervalSince1970: 103))
        f.status("profile", .upToDate, at: 111); f.time = Date(timeIntervalSince1970: 113); f.canSave = false
        await helper.refresh()
        precondition(helper.report.summary.phase == .needsAttention && f.saved == Date(timeIntervalSince1970: 103))
        f.canSave = true
        await helper.refresh()
        precondition(f.saved == f.time)
        helper.registerUpstream(f.participant("sentinel"))
        await helper.refresh()
        precondition(helper.report.requiredIDs.contains("sentinel") && helper.report.summary.phase == .checking)
        f.time = Date(timeIntervalSince1970: 120)
        for id in ["phi", "profile", "sentinel"] { f.status(id, .upToDate, at: 119) }
        await helper.refresh()
        precondition(helper.report.summary.phase == .upToDate && f.saved == f.time)
        f.ids.append("second")
        await helper.refresh()
        precondition(helper.report.summary.phase == .checking && f.requests["second"] == 1)
        helper.unregisterUpstream(id: "sentinel")
        await helper.refresh() // Establish a new nonempty round without an upstream hook.
        f.ids = []
        await helper.refresh()
        precondition(helper.report.summary.phase == .checking)
        let requestsBeforeRestore = f.requests["phi"]!
        f.ids = ["phi", "profile"]
        await helper.refresh()
        precondition(f.requests["phi"] == requestsBeforeRestore + 1,
                     "Empty enumeration discards the previous barrier before participants return")
        f.paired = false
        await helper.refresh()
        precondition(helper.report.summary.phase == .notStarted && helper.report.summary.lastSuccess == nil)
        helper.stop()
        print("PASS helper: coordinated barrier, partial failures, no feedback, persisted time, membership, Sentinel, unpaired")

        let race = Fixture()
        var holdProfile = false
        var profileReply: CheckedContinuation<SyncContextSnapshot?, Never>?
        let raced = SyncHelper(isEligible: { true }, participants: {
            [SyncHelper.Participant(id: "phi", read: { race.snapshots["phi"] }, requestSync: {},
                                    currentSnapshot: { race.snapshots["phi"] }),
             SyncHelper.Participant(id: "profile", read: {
                 if holdProfile { return await withCheckedContinuation { profileReply = $0 } }
                 return race.snapshots["profile"]
             }, requestSync: {})]
        }, lastSuccess: nil, saveSuccess: { date in race.saved = date; return true }, now: { race.time })
        race.status("phi", .upToDate, at: 90); race.status("profile", .upToDate, at: 90)
        await raced.refresh() // Establish a barrier at 100.
        race.time = Date(timeIntervalSince1970: 110)
        race.status("phi", .upToDate, at: 105); race.status("profile", .upToDate, at: 106)
        holdProfile = true
        let racing = Task { await raced.refresh() }
        while profileReply == nil { await Task.yield() }
        race.status("phi", .needsAttention, at: 105)
        profileReply?.resume(returning: race.snapshots["profile"])
        await racing.value
        precondition(raced.report.summary.phase == .needsAttention && race.saved == nil,
                     "Native failure during a delayed Profile read must prevent common completion")
        print("PASS helper: native final fence rejects stale success across bridge awaits")
        raced.stop()

        let delayed = Fixture()
        var resume: CheckedContinuation<SyncContextSnapshot?, Never>?
        let lateHelper = SyncHelper(isEligible: { true }, participants: {
            [SyncHelper.Participant(id: "phi", read: { await withCheckedContinuation { resume = $0 } }, requestSync: {})]
        }, lastSuccess: nil, saveSuccess: { _ in preconditionFailure("Retired account wrote a timestamp") })
        let pending = Task { await lateHelper.refresh() }
        while resume == nil { await Task.yield() }
        lateHelper.stop()
        resume?.resume(returning: SyncContextSnapshot(id: "phi", phase: .upToDate, lastSuccess: delayed.time, revision: 1))
        await pending.value
        precondition(lateHelper.report.summary.phase == .notStarted)
        print("PASS helper: account retirement rejects late bridge replies")
    }
}

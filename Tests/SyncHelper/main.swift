import Foundation

@MainActor final class Fixture {
    var time = Date(timeIntervalSince1970: 100)
    var paired = true
    var ids = ["phi", "profile"]
    var snapshots: [String: SyncContextSnapshot] = [:]
    var requests: [String: Int] = [:]
    var enumerations = 0
    var saved: Date?
    var saves = 0
    var canSave = true
    var acceptsRequests = true
    func tick(_ time: TimeInterval) { self.time = Date(timeIntervalSince1970: time) }
    func status(_ id: String, _ phase: SyncContextPhase, at time: TimeInterval? = nil) {
        snapshots[id] = SyncContextSnapshot(id: id, phase: phase,
            lastSuccess: time.map(Date.init(timeIntervalSince1970:)), revision: (snapshots[id]?.revision ?? 0) + 1)
    }
    func succeed(at time: TimeInterval) {
        tick(time)
        for id in ids { status(id, .upToDate, at: time) }
    }
    func participant(_ id: String) -> SyncHelper.Participant {
        SyncHelper.Participant(id: id, read: { self.snapshots[id] }, requestSync: {
            self.requests[id, default: 0] += 1
            return self.acceptsRequests
        })
    }
    func helper() -> SyncHelper {
        SyncHelper(isEligible: { self.paired }, participants: {
            self.enumerations += 1
            return self.ids.map(self.participant)
        }, lastSuccess: saved, saveSuccess: { date in
            self.saves += 1
            guard self.canSave else { return false }
            self.saved = date; return true
        }, now: { self.time })
    }
    func completedHelper() async -> SyncHelper {
        let helper = helper()
        status("phi", .upToDate, at: 90); status("profile", .upToDate, at: 80)
        await helper.refresh()
        precondition(requests == ["phi": 1, "profile": 1] && helper.report.summary.phase == .syncing)
        succeed(at: 103)
        await helper.refresh()
        precondition(saved == time && helper.report.summary.phase == .upToDate)
        return helper
    }
}

@main struct HelperTests {
    @MainActor static func main() async {
        await waitingStatesRemainObservational()
        await persistenceFailureSurvivesWaitingAndRetries()
        await completionBarrier()
        await lateSuccessAndBrowsingDoNotRequestRounds()
        await explicitRefreshIsRateLimited()
        await failuresStalenessAndTimeout()
        await rejectedRequestsDoNotCreateRounds()
        await membershipAndUpstream()
        await delayedObservations()
    }

    @MainActor static func waitingStatesRemainObservational() async {
        var failures: [String] = []
        func expect(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }
        // Nil reads and the adapter's nil-payload decoding both describe a
        // Profile that can remain unloaded for an entire browsing session.
        for decodedChecking in [false, true] {
            let f = Fixture()
            f.saved = Date(timeIntervalSince1970: 50)
            f.status("phi", .upToDate, at: 90)
            if decodedChecking { f.status("profile", .checking) }
            let helper = f.helper()
            for second in stride(from: 100, through: 1000, by: 60) {
                f.tick(Double(second))
                await helper.refresh()
            }
            expect(helper.report.summary.phase == .checking && f.requests.isEmpty && f.saves == 0,
                   "Unobservable Profiles must remain Checking without catch-up traffic, even when other evidence ages")
            expect(helper.report.summary.lastSuccess == Date(timeIntervalSince1970: 50),
                   "An unloaded Profile must preserve the historical common time")
            f.succeed(at: 1001)
            await helper.refresh()
            expect(f.requests["phi"] == 1 && f.saves == 0,
                   "A newly observable Profile must establish a fresh barrier before advancing common time")
            f.succeed(at: 1004)
            await helper.refresh()
            expect(f.saved == f.time && helper.report.summary.phase == .upToDate,
                   "Loading the Profile must allow one complete coordinated round")
            helper.stop()
        }
        // Losing a previously observable Profile during a requested round must
        // not turn the timeout into an error/retry loop either.
        let missing = Fixture(), missingHelper = await missing.completedHelper()
        missing.tick(160)
        await missingHelper.refresh(requestSync: true)
        missing.status("profile", .checking)
        for second in stride(from: 220, through: 1000, by: 60) {
            missing.tick(Double(second))
            await missingHelper.refresh()
        }
        expect(missingHelper.report.summary.phase == .checking && missing.requests["phi"] == 2,
               "A round losing status visibility must expire to Checking without periodic forced retries")
        expect(missing.saved == Date(timeIntervalSince1970: 103), "Incomplete visibility cannot advance common time")
        missingHelper.stop()

        for phase in [SyncContextPhase.initialSync, .syncing] {
            let f = Fixture(), helper = await f.completedHelper()
            f.tick(160)
            await helper.refresh(requestSync: true)
            f.status("profile", phase) // Healthy work, but no completed evidence yet.
            for second in stride(from: 220, through: 1000, by: 60) {
                f.tick(Double(second))
                await helper.refresh()
                expect(helper.report.summary.phase.rawValue == phase.rawValue,
                       "A healthy \(phase.rawValue) must survive the deadline without synthetic Checking or Needs attention")
            }
            expect(f.requests["phi"] == 2 && f.saved == Date(timeIntervalSince1970: 103),
                   "Long-running work must not cause forced rounds or a false common success")
            f.succeed(at: 1001)
            await helper.refresh()
            expect(f.requests["phi"] == 3, "Once work settles, deferred coordination can run once")
            f.succeed(at: 1004)
            await helper.refresh()
            expect(f.saved == f.time && helper.report.summary.phase == .upToDate,
                   "A slow but healthy engine must converge after it settles")
            helper.stop()
        }
        let reopened = Fixture(), reopenedHelper = await reopened.completedHelper()
        for second in [110, 130, 159] {
            reopened.tick(Double(second))
            await reopenedHelper.refresh(requestSync: true)
            expect(reopenedHelper.report.summary.phase == .upToDate
                   && reopenedHelper.report.summary.lastSuccess == Date(timeIntervalSince1970: 103),
                   "A throttled pane reload must preserve Up to date and its common time")
        }
        expect(reopened.requests["phi"] == 1, "Repeated pane opens must coalesce while throttled")
        reopened.tick(160)
        await reopenedHelper.refresh()
        expect(reopened.requests["phi"] == 2 && reopenedHelper.report.summary.phase == .syncing,
               "A queued explicit request may change status only when dispatched")
        reopenedHelper.stop()
        precondition(failures.isEmpty, failures.joined(separator: "\n"))
        print("PASS helper: lazy Profiles, long-running healthy work and throttled pane reloads remain observational")
    }

    @MainActor static func persistenceFailureSurvivesWaitingAndRetries() async {
        for phase in [SyncContextPhase.checking, .initialSync, .syncing] {
            let f = Fixture()
            f.saved = Date(timeIntervalSince1970: 50)
            let helper = f.helper()
            f.status("phi", .upToDate, at: 90); f.status("profile", .upToDate, at: 80)
            await helper.refresh()
            f.canSave = false; f.succeed(at: 103)
            await helper.refresh()
            precondition(helper.report.summary.phase == .needsAttention)
            f.tick(160); f.status("profile", phase)
            await helper.refresh()
            precondition(helper.report.summary.phase == .needsAttention,
                         "Round expiry must not erase a genuine persistence failure")
            f.tick(170); f.ids.append("second"); f.status("second", .upToDate, at: 100)
            helper.membershipDidChange()
            precondition(helper.report.summary.phase == .needsAttention,
                         "Membership invalidation must retain a same-account storage error")
            await helper.refresh()
            precondition(f.requests["phi"] == 1 && helper.report.summary.phase == .needsAttention)
            f.tick(171); f.ids = []
            helper.membershipDidChange()
            await helper.refresh()
            precondition(helper.report.summary.phase == .needsAttention,
                         "Empty membership cannot mask an unresolved local write failure")
            f.ids = ["phi", "profile", "second"]
            helper.membershipDidChange()
            f.succeed(at: 220); f.acceptsRequests = false
            await helper.refresh()
            precondition(helper.report.summary.phase == .needsAttention && f.requests["phi"] == 2)
            f.tick(280); f.acceptsRequests = true
            await helper.refresh()
            precondition(helper.report.summary.phase == .needsAttention && f.requests["phi"] == 3,
                         "Rejecting then accepting a retry cannot prove the storage error recovered")
            precondition(f.saved == Date(timeIntervalSince1970: 50))
            f.canSave = true; f.succeed(at: 283)
            await helper.refresh()
            precondition(helper.report.summary.phase == .upToDate && f.saved == f.time,
                         "Only a successful common-time write clears the storage error")
            helper.stop()
        }
        print("PASS helper: persistence failures survive timeout, membership and retries until a successful write")
    }

    @MainActor static func completionBarrier() async {
        let f = Fixture(), helper = f.helper()
        f.status("phi", .upToDate, at: 90); f.status("profile", .upToDate, at: 80)
        await helper.refresh()
        precondition(f.enumerations == 1, "Each observation must enumerate participants only once")
        precondition(helper.report.summary.phase == .syncing && f.saved == nil)
        f.tick(103); f.status("phi", .upToDate, at: 102)
        await helper.refresh()
        precondition(f.saved == nil, "Native success alone cannot advance the common time")
        f.status("profile", .offline, at: 80)
        await helper.refresh()
        precondition(helper.report.summary.phase == .offline && f.saved == nil)
        f.status("profile", .upToDate, at: 103); f.canSave = false
        await helper.refresh()
        precondition(helper.report.summary.phase == .needsAttention && f.saved == nil)
        f.canSave = true
        await helper.refresh()
        precondition(f.saved == f.time && f.requests["phi"] == 1)
        helper.stop()
        print("PASS helper: common barrier, one enumeration, partial failure, persistence retry")
    }

    @MainActor static func lateSuccessAndBrowsingDoNotRequestRounds() async {
        let f = Fixture(), helper = await f.completedHelper()
        // Another cycle satisfied the observed barrier at 103. The originally
        // requested catch-up finishes later; it must not become another request.
        f.succeed(at: 110)
        await helper.refresh()
        precondition(f.requests["phi"] == 1, "Late completion of an earlier request must not start a new round")
        // Ordinary navigations alternate pending and commit-only success cycles,
        // including beyond the minimum request interval. Native remote applies
        // may also succeed naturally. Neither is a reason for extra catch-up.
        for second in stride(from: 113, through: 260, by: 3) {
            f.tick(Double(second))
            f.status("phi", .upToDate, at: Double(second))
            f.status("profile", second % 2 == 0 ? .upToDate : .syncing, at: Double(second - 1))
            await helper.refresh()
        }
        precondition(f.requests == ["phi": 1, "profile": 1] && f.saves == 1,
                     "Browsing and remote changes must not create refresh traffic or false common timestamps")
        helper.stop()
        print("PASS helper: late prior completion and sustained browsing produce no extra rounds")
    }

    @MainActor static func explicitRefreshIsRateLimited() async {
        let f = Fixture(), helper = await f.completedHelper()
        f.tick(110)
        await helper.refresh(requestSync: true)
        await helper.refresh(requestSync: true)
        precondition(f.requests["phi"] == 1 && f.saved == Date(timeIntervalSince1970: 103))
        f.tick(160)
        await helper.refresh()
        precondition(f.requests["phi"] == 2)
        await helper.refresh(requestSync: true) // Coalesce with the active round.
        f.succeed(at: 164)
        await helper.refresh()
        f.tick(224)
        await helper.refresh()
        precondition(f.requests["phi"] == 2 && f.saves == 2,
                     "Explicit requests during a round must not queue another round")
        helper.stop()
        print("PASS helper: explicit refresh coalesces and respects minimum request interval")
    }

    @MainActor static func failuresStalenessAndTimeout() async {
        let f = Fixture(), helper = await f.completedHelper()
        f.tick(104); f.status("profile", .offline, at: 103)
        await helper.refresh()
        precondition(f.requests["phi"] == 1 && helper.report.summary.phase == .offline)
        f.tick(160)
        await helper.refresh()
        precondition(f.requests["phi"] == 2)
        f.succeed(at: 165)
        await helper.refresh()
        f.tick(466) // The evidence is now stale, even though the phase is healthy.
        await helper.refresh()
        precondition(f.requests["phi"] == 3 && helper.report.summary.phase == .syncing)
        f.tick(526) // An accepted request can still be dropped by the transport.
        await helper.refresh()
        precondition(helper.report.summary.phase == .needsAttention && f.saved == Date(timeIntervalSince1970: 165),
                     "A missing completion must expire instead of leaving Syncing forever")
        f.tick(527); f.status("profile", .checking)
        await helper.refresh()
        precondition(helper.report.summary.phase == .checking, "A previous timeout must not override unavailable status")
        f.tick(528); f.status("profile", .syncing)
        await helper.refresh()
        precondition(helper.report.summary.phase == .syncing, "A previous timeout must not override later healthy work")
        f.succeed(at: 529)
        await helper.refresh()
        precondition(f.requests["phi"] == 3 && f.saved == Date(timeIntervalSince1970: 165),
                     "Late evidence after a timeout cannot finish the expired round or bypass retry delay")
        f.tick(586)
        await helper.refresh()
        precondition(f.requests["phi"] == 4)
        f.succeed(at: 590)
        await helper.refresh()
        precondition(f.saved == f.time && helper.report.summary.phase == .upToDate)
        helper.stop()
        print("PASS helper: bounded failure/stale retries, deadline, late evidence, recovery")
    }

    @MainActor static func rejectedRequestsDoNotCreateRounds() async {
        let f = Fixture(), helper = f.helper()
        f.status("phi", .upToDate, at: 90); f.status("profile", .upToDate, at: 80)
        f.acceptsRequests = false
        await helper.refresh()
        precondition(helper.report.summary.phase == .needsAttention && f.requests["phi"] == 1)
        f.succeed(at: 103)
        await helper.refresh()
        precondition(f.saved == nil && f.requests["phi"] == 1,
                     "Unrelated success cannot complete a rejected request")
        f.acceptsRequests = true; f.tick(160)
        await helper.refresh()
        precondition(f.requests["phi"] == 2 && helper.report.summary.phase == .syncing)
        f.paired = false
        await helper.refresh()
        precondition(helper.report.summary.phase == .notStarted && helper.report.summary.lastSuccess == nil)
        helper.stop()
        print("PASS helper: rejected requests never enter Syncing or advance common time; eligibility gates requests")
    }

    @MainActor static func membershipAndUpstream() async {
        let f = Fixture(), helper = await f.completedHelper()
        f.tick(110); f.ids.append("second")
        f.status("second", .upToDate, at: 100)
        helper.membershipDidChange()
        await helper.refresh()
        precondition(f.requests["phi"] == 1, "Membership changes must not bypass the request interval")
        f.tick(160)
        await helper.refresh()
        precondition(f.requests["second"] == 1 && helper.report.requiredIDs.contains("second"))
        f.succeed(at: 164)
        await helper.refresh()
        helper.registerUpstream(f.participant("sentinel"))
        f.status("sentinel", .upToDate, at: 100)
        f.tick(220)
        await helper.refresh()
        precondition(helper.report.requiredIDs.contains("sentinel") && f.requests["sentinel"] == 1)
        f.succeed(at: 224); f.status("sentinel", .upToDate, at: 224)
        await helper.refresh()
        precondition(helper.report.summary.phase == .upToDate)
        helper.unregisterUpstream(id: "sentinel")
        f.ids = []
        await helper.refresh()
        precondition(helper.report.summary.phase == .checking)
        f.ids = ["phi", "profile"]; f.tick(280)
        await helper.refresh()
        precondition(f.requests["phi"] == 4 && !helper.report.requiredIDs.contains("sentinel"))
        helper.stop()
        print("PASS helper: bounded membership rounds, empty enumeration and Sentinel participation")
    }

    @MainActor static func delayedObservations() async {
        let race = Fixture()
        var holdProfile = false
        var profileReply: CheckedContinuation<SyncContextSnapshot?, Never>?
        let raced = SyncHelper(isEligible: { true }, participants: {
            [SyncHelper.Participant(id: "phi", read: { race.snapshots["phi"] }, requestSync: { true },
                                    currentSnapshot: { race.snapshots["phi"] }),
             SyncHelper.Participant(id: "profile", read: {
                 if holdProfile { return await withCheckedContinuation { profileReply = $0 } }
                 return race.snapshots["profile"]
             }, requestSync: { true })]
        }, lastSuccess: nil, saveSuccess: { date in race.saved = date; return true }, now: { race.time })
        race.status("phi", .upToDate, at: 90); race.status("profile", .upToDate, at: 90)
        await raced.refresh()
        race.succeed(at: 110)
        holdProfile = true
        let racing = Task { await raced.refresh() }
        while profileReply == nil { await Task.yield() }
        race.status("phi", .needsAttention, at: 105)
        profileReply?.resume(returning: race.snapshots["profile"])
        await racing.value
        precondition(raced.report.summary.phase == .needsAttention && race.saved == nil,
                     "Native failure during a delayed Profile read must prevent common completion")
        profileReply = nil
        race.succeed(at: 111)
        let membershipRace = Task { await raced.refresh() }
        while profileReply == nil { await Task.yield() }
        raced.membershipDidChange()
        profileReply?.resume(returning: race.snapshots["profile"])
        await membershipRace.value
        precondition(raced.report.summary.phase == .checking && race.saved == nil,
                     "Membership change during a bridge await must fence the old observation")
        raced.stop()

        var resume: CheckedContinuation<SyncContextSnapshot?, Never>?
        let lateHelper = SyncHelper(isEligible: { true }, participants: {
            [SyncHelper.Participant(id: "phi", read: { await withCheckedContinuation { resume = $0 } }, requestSync: { true })]
        }, lastSuccess: nil, saveSuccess: { _ in preconditionFailure("Retired account wrote a timestamp") })
        let pending = Task { await lateHelper.refresh() }
        while resume == nil { await Task.yield() }
        lateHelper.stop()
        resume?.resume(returning: SyncContextSnapshot(id: "phi", phase: .upToDate, lastSuccess: race.time, revision: 1))
        await pending.value
        precondition(lateHelper.report.summary.phase == .notStarted)
        print("PASS helper: native, membership and account fences reject delayed replies")
    }
}

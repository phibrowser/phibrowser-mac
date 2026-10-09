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
    /// Runs inside a participant's asynchronous read, before it returns.
    var onRead: ((String) -> Void)?
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
        SyncHelper.Participant(id: id, read: { self.onRead?(id); return self.snapshots[id] }, requestSync: {
            self.requests[id, default: 0] += 1
            return self.acceptsRequests
        }, isNative: id == "phi")
    }
    func helper(policy: SyncHelper.ExplicitRequestPolicy = .waitForAllObservable) -> SyncHelper {
        SyncHelper(isEligible: { self.paired }, participants: {
            self.enumerations += 1
            return self.ids.map(self.participant)
        }, lastSuccess: saved, saveSuccess: { date in
            self.saves += 1
            guard self.canSave else { return false }
            self.saved = date; return true
        }, now: { self.time }, unobservablePolicy: policy)
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
        await syncNowRequestStates()
        await syncNowRateLimitAndCoalescing()
        await syncNowRejectionAndResets()
        await syncNowUnobservablePolicies()
        await syncNowIgnoresOtherDemand()
        await failingRoundEndsEarly()
        await earlyEndKeepsLateSuccess()
        await syncNowFailsFastWhileNativeOffline()
        await reportCarriesNativeDetail()
        await profileMappingPauseGrace()
        await profileMappingPauseCancelsRoundObservation()
        await profileMappingPauseQueuesSyncNow()
        await profileMappingPauseCheckedAfterEveryRead()
        await profileListNotEnumeratedIsReported()
        statusPresentationOverlaysThePause()
        statusPresentationPrecedence()
        statusPresentationGraceAndCancelledSyncNow()
        statusPresentationProfileListWait()
        statusPresentationProfileNames()
        statusPresentationReadsNamesOnlyForThePause()
        statusPresentationAnnouncesResume()
    }

    static let overlayNow = Date(timeIntervalSince1970: 10_000)
    static let overlayNames = ["Profile 1": "Work", "Profile 2": "Home", "Profile 3": "alpha",
                               "Profile 4": "Travel", "Profile 5": "Kids"]

    static func overlay(_ summary: SyncSummaryPhase, _ pause: SyncProfileMappingPauseStatus = .none,
                        request: SyncRequestState = .idle, cancelled: Bool = false,
                        listSince: TimeInterval? = nil, reset: Bool = false,
                        names: [String: String] = overlayNames) -> SyncStatusPresentation {
        SyncStatusPresentation.present(summary: summary, request: request, profileMappingPause: pause,
            syncNowCancelledByPause: cancelled,
            profileListNotEnumeratedSince: listSince.map { overlayNow.addingTimeInterval(-$0) },
            resetRequired: reset, profileNames: { names }, now: overlayNow)
    }

    /// Every value of the helper's pause, each reason and failure category.
    static func statusPresentationOverlaysThePause() {
        let idleButton = SyncNowButtonState.reduce(summary: .upToDate, request: .idle)
        for pause in [SyncProfileMappingPauseStatus.none, .grace] {
            let shown = overlay(.upToDate, pause)
            precondition(shown.headline == .phase(.upToDate) && shown.pause == nil && !shown.showsRetry
                         && shown.syncNow == idleButton && !shown.showsProfileListWait,
                         "Nothing about the pause is shown outside the shown pause (\(pause))")
        }
        let reasons: [SyncProfileMappingPause.Reason] = [.registering, .retrying, .needsAttention]
        let failures: [SyncProfileMappingFailureCategory?] = [nil, .offline, .signInExpired, .serverError, .other]
        for reason in reasons {
            for failure in failures {
                let shown = overlay(.upToDate, .paused(reason: reason, failureCategory: failure,
                                                       unmappedProfileIds: ["Profile 2"]))
                precondition(shown.headline == .paused && shown.showsRetry && !shown.syncNow.isVisible
                             && shown.pause == .init(reason: reason, failure: failure, profiles: .names(["Home"])),
                             "The shown pause must carry its reason and category (\(reason), \(String(describing: failure)))")
            }
        }
        print("PASS overlay: none and grace show nothing; the shown pause carries reason, category, Profiles and Retry")
    }

    /// Reset wins over the pause; the pause wins over Syncing (a leftover from a round queued before the gate included),
    /// Up to date, Offline and Needs attention; Not started shows nothing of it.
    static func statusPresentationPrecedence() {
        let pause = SyncProfileMappingPauseStatus.paused(reason: .retrying, failureCategory: .offline,
                                                         unmappedProfileIds: ["Profile 1"])
        for summary in [SyncSummaryPhase.syncing, .upToDate, .offline, .needsAttention, .checking, .initialSync] {
            let shown = overlay(summary, pause, request: .inFlight(startedAt: overlayNow))
            precondition(shown.headline == .paused && shown.showsRetry && !shown.syncNow.isVisible,
                         "The shown pause must win over \(summary)")
        }
        let reset = overlay(.needsAttention, pause, reset: true)
        precondition(reset.headline == .phase(.needsAttention) && reset.pause == nil && !reset.showsRetry
                     && reset.syncNow == SyncNowButtonState.reduce(summary: .needsAttention, request: .idle),
                     "Reset required must win over the pause: Retry cannot fix a reset")
        let resetWaiting = overlay(.checking, listSince: 600, reset: true)
        precondition(resetWaiting.headline == .phase(.checking) && !resetWaiting.showsProfileListWait,
                     "Reset required must win over the list wait")
        let notStarted = overlay(.notStarted, pause)
        precondition(notStarted.headline == .phase(.notStarted) && notStarted.pause == nil
                     && !notStarted.showsRetry && !notStarted.syncNow.isVisible, "Not started shows no pause")
        let both = overlay(.checking, pause, listSince: 600)
        precondition(both.headline == .paused && !both.showsProfileListWait, "The shown pause wins over the list wait")
        print("PASS overlay: reset wins over the pause; the pause wins over Syncing, Up to date, Offline and the list wait")
    }

    /// A Sync now during the grace shows as waiting; a request the pause cancelled
    /// returns the control to idle without an announcement.
    static func statusPresentationGraceAndCancelledSyncNow() {
        let grace = overlay(.syncing, .grace, request: .queued(reason: .busy, notBefore: nil))
        precondition(grace.headline == .phase(.syncing) && grace.pause == nil && !grace.showsRetry
                     && grace.syncNow == .init(isVisible: true, isEnabled: false, showsProgress: true,
                                               hint: .waitingForCurrentSync) && grace.announcesSyncNowOutcome,
                     "A Sync now during the grace shows as queued Busy")
        let pause = SyncProfileMappingPauseStatus.paused(reason: .registering, failureCategory: nil,
                                                         unmappedProfileIds: ["Profile 1"])
        let cancelled = overlay(.upToDate, pause, cancelled: true)
        precondition(!cancelled.announcesSyncNowOutcome && cancelled.syncNow.hint == .none
                     && !cancelled.syncNow.showsProgress, "A cancelled Sync now is neither announced nor failed")
        let resumed = overlay(.upToDate, .none, cancelled: false)
        precondition(resumed.announcesSyncNowOutcome && resumed.syncNow == SyncNowButtonState.reduce(summary: .upToDate, request: .idle),
                     "After the pause the control is idle and outcomes are announced again")
        print("PASS overlay: a Sync now in the grace shows as waiting; a cancelled one ends silently")
    }

    /// AM-1 / review R3: the unread Profile list shows a line from 30 s and Needs attention
    /// from 5 minutes, never Retry.
    static func statusPresentationProfileListWait() {
        let early = overlay(.checking, listSince: 29)
        precondition(early.headline == .phase(.checking) && !early.showsProfileListWait, "Under 30 s shows nothing")
        let line = overlay(.checking, listSince: 30)
        precondition(line.headline == .phase(.checking) && line.showsProfileListWait && !line.showsRetry,
                     "From 30 s the waiting line is shown with the summary")
        let late = overlay(.checking, listSince: 299)
        precondition(late.headline == .phase(.checking) && late.showsProfileListWait)
        let attention = overlay(.checking, listSince: 300)
        precondition(attention.headline == .phase(.needsAttention) && attention.showsProfileListWait
                     && !attention.showsRetry && attention.syncNow.isVisible && attention.pause == nil,
                     "From 5 minutes Needs attention with the line, and no Retry")
        let read = overlay(.upToDate, listSince: nil)
        precondition(read.headline == .phase(.upToDate) && !read.showsProfileListWait)
        print("PASS overlay: the unread Profile list shows a line from 30 s and Needs attention from 5 minutes, no Retry")
    }

    /// Names for one to three Profiles, a count above that; an id that no longer resolves is left out.
    static func statusPresentationProfileNames() {
        func profiles(_ ids: [String]) -> SyncStatusPresentation.PausedProfiles? {
            overlay(.upToDate, .paused(reason: .registering, failureCategory: nil, unmappedProfileIds: ids)).pause?.profiles
        }
        precondition(profiles(["Profile 1", "Profile 3", "Profile 2"]) == .names(["alpha", "Home", "Work"]),
                     "Up to three names, sorted for display")
        precondition(profiles(["Profile 1", "Profile 2", "Profile 3", "Profile 4"]) == .count(4), "Four are counted")
        precondition(profiles(["Profile 1", "Gone"]) == .names(["Work"]), "An id that does not resolve is not listed")
        precondition(profiles(["Profile 1", "Profile 2", "Profile 3", "Gone", "Also gone"]) == .names(["alpha", "Home", "Work"]),
                     "Only resolved names are counted")
        precondition(profiles(["Gone"]) == .unnamed, "No resolved name: the card says a profile without naming it")
        print("PASS overlay: one to three Profiles by name, more by count; unresolved ids are left out")
    }

    /// The Profile names are read only for a shown pause, not on every read of the status row.
    static func statusPresentationReadsNamesOnlyForThePause() {
        var reads = 0
        func present(_ summary: SyncSummaryPhase, _ pause: SyncProfileMappingPauseStatus,
                     reset: Bool = false) -> SyncStatusPresentation {
            SyncStatusPresentation.present(summary: summary, request: .idle, profileMappingPause: pause,
                syncNowCancelledByPause: false, profileListNotEnumeratedSince: overlayNow.addingTimeInterval(-600),
                resetRequired: reset, profileNames: { reads += 1; return overlayNames }, now: overlayNow)
        }
        _ = present(.upToDate, .none)
        _ = present(.syncing, .grace)
        _ = present(.needsAttention, shownPause, reset: true)
        _ = present(.notStarted, shownPause)
        precondition(reads == 0, "The Profile names were read without a shown pause")
        precondition(present(.upToDate, shownPause).pause?.profiles == .names(["Home"]) && reads == 1,
                     "A shown pause reads the Profile names once")
        print("PASS overlay: the Profile names are read only for a shown pause")
    }

    /// "Sync resumed" only when a shown pause gives way to a normal summary: not to a reset,
    /// Not started (the account key became unavailable) or another shown pause.
    static func statusPresentationAnnouncesResume() {
        func resumes(wasPaused: Bool = true, _ presentation: SyncStatusPresentation, reset: Bool = false) -> Bool {
            SyncStatusPresentation.announcesResume(wasPaused: wasPaused, now: presentation, resetRequired: reset)
        }
        for summary in [SyncSummaryPhase.upToDate, .syncing, .offline, .needsAttention, .checking] {
            precondition(resumes(overlay(summary)), "A pause that gives way to \(summary) resumed sync")
        }
        precondition(resumes(overlay(.checking, listSince: 600)), "The list wait is a normal summary")
        precondition(!resumes(wasPaused: false, overlay(.upToDate)), "No shown pause, nothing resumed")
        precondition(!resumes(overlay(.notStarted)), "A pause that gives way to Not started has not resumed sync")
        precondition(!resumes(overlay(.needsAttention, reset: true), reset: true),
                     "A pause that gives way to a reset has not resumed sync")
        precondition(!resumes(overlay(.upToDate, shownPause)), "A pause still shown has not resumed sync")
        print("PASS overlay: Sync resumed only when a shown pause gives way to a normal summary")
    }

    /// Review R3: the report says since when the engine gate has been on because the Profile
    /// list has not been enumerated; membership changes and ineligibility keep it, and it
    /// changes nothing else.
    @MainActor static func profileListNotEnumeratedIsReported() async {
        let f = Fixture(), helper = await f.completedHelper()
        let since = Date(timeIntervalSince1970: 42)
        let requests = f.requests
        helper.setProfileListNotEnumerated(since: since)
        precondition(helper.report.profileListNotEnumeratedSince == since && helper.report.summary.phase == .upToDate)
        helper.membershipDidChange()
        precondition(helper.report.profileListNotEnumeratedSince == since, "A membership change dropped the field")
        f.paired = false
        await helper.refresh()
        precondition(helper.report.profileListNotEnumeratedSince == since, "Ineligibility dropped the field")
        f.paired = true
        precondition(f.requests == requests, "The field dispatched a round")
        helper.setProfileListNotEnumerated(since: nil)
        precondition(helper.report.profileListNotEnumeratedSince == nil)
        helper.setProfileListNotEnumerated(since: since)
        helper.stop()
        precondition(helper.report.profileListNotEnumeratedSince == nil, "A stopped helper kept the field")
        print("PASS helper: the report carries since when the Profile list has not been enumerated")
    }

    static let shownPause = SyncProfileMappingPauseStatus.paused(
        reason: .retrying, failureCategory: .offline, unmappedProfileIds: ["Profile 2"])

    /// Under 15 seconds the helper dispatches nothing and keeps its last report;
    /// ending the pause is not a membership change.
    @MainActor static func profileMappingPauseGrace() async {
        let f = Fixture(), helper = await f.completedHelper()
        let before = helper.report.summary
        let reads = f.enumerations
        helper.setProfileMappingPause(.grace)
        for second in stride(from: 110, through: 500, by: 30) {
            f.tick(Double(second))
            await helper.refresh(requestSync: true)
        }
        precondition(f.requests == ["phi": 1, "profile": 1] && f.enumerations == reads,
                     "The helper read or dispatched during the grace")
        precondition(helper.report.summary == before && helper.report.profileMappingPause == .none
                     && helper.report.request == .idle, "The grace changed the report")
        helper.setProfileMappingPause(.none)
        precondition(helper.report.summary == before, "Ending the pause reset the report like a membership change")
        f.succeed(at: 501)
        await helper.refresh()
        precondition(f.requests["phi"] == 2, "Ending the pause did not ask for a fresh round")
        f.succeed(at: 505)
        await helper.refresh()
        precondition(f.saved == f.time && helper.report.summary.phase == .upToDate)
        helper.stop()
        print("PASS helper: a pause under 15 seconds dispatches nothing and keeps the report; its end asks for a fresh round")
    }

    /// AM-2: a round dispatched just before an episode starts is invalidated; its Sync now
    /// request stays queued, is cancelled once the pause is shown, and a fresh round runs
    /// after the episode.
    @MainActor static func profileMappingPauseCancelsRoundObservation() async {
        let f = Fixture(), helper = await f.completedHelper()
        f.tick(170)
        let state = await helper.requestSyncNow()
        precondition(state == .inFlight(startedAt: f.time) && f.requests["phi"] == 2)
        helper.setProfileMappingPause(.grace)
        precondition(helper.report.request == .queued(reason: .busy, notBefore: nil),
                     "The Sync now request of an invalidated round must stay queued")
        f.succeed(at: 172)
        await helper.refresh()
        precondition(f.saved == Date(timeIntervalSince1970: 103), "An invalidated round recorded a coordinated success")
        helper.setProfileMappingPause(shownPause)
        precondition(helper.report.request == .idle && helper.report.syncNowCancelledByPause
                     && helper.report.profileMappingPause == shownPause,
                     "The shown pause must cancel the queued request and report the pause")
        await helper.refresh()
        precondition(helper.report.profileMappingPause == shownPause && helper.report.syncNowCancelledByPause)
        helper.membershipDidChange()
        precondition(helper.report.profileMappingPause == shownPause, "A membership change dropped the shown pause")
        helper.setProfileMappingPause(.none)
        precondition(helper.report.profileMappingPause == .none && !helper.report.syncNowCancelledByPause)
        f.tick(240); f.succeed(at: 240)
        await helper.refresh()
        precondition(f.requests["phi"] == 3 && helper.report.request == .idle, "No fresh round after the episode")
        f.succeed(at: 244)
        await helper.refresh()
        precondition(f.saved == f.time)
        helper.stop()
        print("PASS helper: an episode invalidates the round in flight, keeps then cancels its Sync now, and a fresh round follows")
    }

    /// A Sync now during the grace stays queued and is dispatched when the
    /// episode ends; one during the shown pause is cancelled at once.
    @MainActor static func profileMappingPauseQueuesSyncNow() async {
        let f = Fixture(), helper = await f.completedHelper()
        helper.setProfileMappingPause(.grace)
        f.tick(170)
        var state = await helper.requestSyncNow()
        precondition(state == .queued(reason: .busy, notBefore: nil) && f.requests["phi"] == 1)
        helper.setProfileMappingPause(.none)
        precondition(helper.report.request == .queued(reason: .busy, notBefore: nil))
        f.succeed(at: 171)
        await helper.refresh()
        precondition(f.requests["phi"] == 2 && helper.report.request == .inFlight(startedAt: f.time),
                     "The queued Sync now was not dispatched when the episode ended")
        helper.setProfileMappingPause(shownPause)
        f.tick(300)
        state = await helper.requestSyncNow()
        precondition(state == .idle && helper.report.syncNowCancelledByPause && f.requests["phi"] == 2,
                     "A Sync now while the pause is shown must be cancelled, not dispatched")
        helper.stop()
        print("PASS helper: Sync now queues through the grace and dispatches at its end; the shown pause cancels it")
    }

    /// AM-2: the pause is checked again after every asynchronous participant read.
    @MainActor static func profileMappingPauseCheckedAfterEveryRead() async {
        let f = Fixture(), helper = await f.completedHelper()
        f.tick(170); f.succeed(at: 170)
        var fired = false
        f.onRead = { id in
            guard id == "profile", !fired else { return }
            fired = true
            helper.setProfileMappingPause(.grace)
        }
        await helper.refresh(requestSync: true)
        precondition(fired && f.requests["phi"] == 1, "A round was dispatched after the pause began mid-observation")
        helper.stop()
        print("PASS helper: the pause is checked after every asynchronous participant read")
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

    @MainActor static func syncNowRequestStates() async {
        let f = Fixture(), helper = await f.completedHelper()
        precondition(helper.report.request == .idle)
        f.tick(170); f.status("profile", .syncing)
        var state = await helper.requestSyncNow()
        precondition(state == .queued(reason: .busy, notBefore: nil) && f.requests["phi"] == 1,
                     "A request while an engine is busy must queue, not dispatch")
        f.succeed(at: 171)
        await helper.refresh() // The helper's own poll dispatches the queued request.
        precondition(helper.report.request == .inFlight(startedAt: f.time) && f.requests["phi"] == 2)
        f.succeed(at: 175)
        await helper.refresh()
        precondition(helper.report.request == .idle && f.saved == f.time && helper.report.summary.phase == .upToDate,
                     "Completion returns the request to idle")
        // A settled helper outside the interval dispatches immediately.
        f.tick(240)
        state = await helper.requestSyncNow()
        precondition(state == .inFlight(startedAt: f.time) && f.requests["phi"] == 3)
        helper.stop()
        print("PASS helper Sync now: idle, queued while busy, dispatched by the poll, in flight, idle on completion")
    }

    @MainActor static func syncNowRateLimitAndCoalescing() async {
        let f = Fixture(), helper = await f.completedHelper()
        f.tick(110)
        var state = await helper.requestSyncNow()
        let notBefore = Date(timeIntervalSince1970: 160)
        precondition(state == .queued(reason: .rateLimited, notBefore: notBefore) && f.requests["phi"] == 1,
                     "A request within the interval must say when it can run")
        f.tick(130)
        await helper.refresh()
        precondition(helper.report.request == .queued(reason: .rateLimited, notBefore: notBefore)
                     && helper.report.summary.phase == .upToDate,
                     "A queued request survives polls and preserves the observed phase")
        f.tick(160)
        await helper.refresh()
        precondition(helper.report.request == .inFlight(startedAt: notBefore) && f.requests["phi"] == 2,
                     "The queued request dispatches on its own once the interval passes")
        f.tick(162)
        state = await helper.requestSyncNow()
        precondition(state == .inFlight(startedAt: notBefore) && f.requests["phi"] == 2,
                     "A request during a round coalesces with it")
        f.succeed(at: 164)
        await helper.refresh()
        f.tick(230)
        await helper.refresh()
        precondition(helper.report.request == .idle && f.requests["phi"] == 2 && f.saves == 2,
                     "A coalesced request must not queue another round")

        // A tap during an observation in progress is not lost.
        var hold = false
        var reply: CheckedContinuation<SyncContextSnapshot?, Never>?
        let g = Fixture()
        g.status("phi", .upToDate, at: 90); g.status("profile", .upToDate, at: 90)
        let raced = SyncHelper(isEligible: { true }, participants: {
            [g.participant("phi"),
             SyncHelper.Participant(id: "profile", read: {
                 if hold { return await withCheckedContinuation { reply = $0 } }
                 return g.snapshots["profile"]
             }, requestSync: { g.requests["profile", default: 0] += 1; return true })]
        }, lastSuccess: nil, saveSuccess: { _ in true }, now: { g.time })
        await raced.refresh()
        g.succeed(at: 103)
        await raced.refresh()
        g.tick(170); hold = true
        let poll = Task { await raced.refresh() }
        while reply == nil { await Task.yield() }
        let tap = Task { await raced.requestSyncNow() }
        for _ in 0..<10 { await Task.yield() }
        hold = false
        reply?.resume(returning: g.snapshots["profile"])
        await poll.value
        state = await tap.value
        precondition(state == .inFlight(startedAt: g.time) && g.requests["phi"] == 2,
                     "A request recorded during a poll dispatches without waiting for the next poll")
        raced.stop()
        helper.stop()
        print("PASS helper Sync now: rate-limited queue with notBefore, auto-dispatch, coalescing, tap during a poll")
    }

    @MainActor static func syncNowRejectionAndResets() async {
        let f = Fixture(), helper = await f.completedHelper()
        f.tick(170); f.acceptsRequests = false
        var state = await helper.requestSyncNow()
        precondition(state == .rejected && f.requests["phi"] == 2, "A participant refusal reports rejected")
        f.tick(175)
        await helper.refresh()
        precondition(helper.report.request == .rejected)
        helper.membershipDidChange()
        precondition(helper.report.request == .idle, "Membership changes reset the request state")
        f.tick(240); f.acceptsRequests = true
        state = await helper.requestSyncNow()
        precondition(state == .inFlight(startedAt: f.time) && f.requests["phi"] == 3)
        f.paired = false
        state = await helper.requestSyncNow()
        precondition(state == .idle && helper.report.summary.phase == .notStarted, "Ineligibility resets to idle")
        helper.stop()
        state = await helper.requestSyncNow()
        precondition(state == .idle)
        print("PASS helper Sync now: refusal reports rejected; membership, ineligibility and stop reset to idle")
    }

    @MainActor static func syncNowUnobservablePolicies() async {
        // Default policy: a lazy Profile keeps an explicit request queued, without traffic.
        for decodedChecking in [false, true] {
            let f = Fixture()
            f.status("phi", .upToDate, at: 90)
            if decodedChecking { f.status("profile", .checking) }
            let helper = f.helper()
            let state = await helper.requestSyncNow()
            precondition(state == .queued(reason: .unobservable, notBefore: nil) && f.requests.isEmpty)
            for second in stride(from: 103, through: 400, by: 3) {
                f.tick(Double(second))
                await helper.refresh()
            }
            precondition(helper.report.request == .queued(reason: .unobservable, notBefore: nil) && f.requests.isEmpty,
                         "Under waitForAllObservable the request waits for every participant")
            helper.stop()
        }

        // dispatchToObservable: the request dispatches; the barrier still requires the Profile.
        let f = Fixture()
        f.saved = Date(timeIntervalSince1970: 50)
        f.status("phi", .upToDate, at: 90); f.status("profile", .checking)
        let helper = f.helper(policy: .dispatchToObservable)
        await helper.refresh()
        precondition(f.requests.isEmpty, "Automatic demand still waits for every participant")
        var state = await helper.requestSyncNow()
        precondition(state == .inFlight(startedAt: f.time) && f.requests == ["phi": 1, "profile": 1],
                     "An explicit request dispatches to all participants once the observable ones are settled")
        f.tick(103); f.status("phi", .upToDate, at: 103)
        await helper.refresh()
        precondition(f.saves == 0 && helper.report.summary.phase == .checking
                     && helper.report.request == .inFlight(startedAt: Date(timeIntervalSince1970: 100)),
                     "The unobservable Profile stays in the completion barrier")
        f.tick(160)
        await helper.refresh()
        precondition(helper.report.request == .idle && helper.report.summary.phase == .checking
                     && f.saved == Date(timeIntervalSince1970: 50),
                     "Expiry without the Profile returns to idle without an error or a common time")
        for second in stride(from: 163, through: 600, by: 3) {
            f.tick(Double(second))
            await helper.refresh()
        }
        precondition(f.requests["phi"] == 1, "Expiry must not start automatic retries while the Profile is unobservable")
        f.tick(601); f.status("phi", .syncing, at: 103)
        state = await helper.requestSyncNow()
        precondition(state == .queued(reason: .busy, notBefore: nil), "Observable busy engines still queue the request")
        f.status("phi", .upToDate, at: 602); f.tick(602)
        await helper.refresh()
        precondition(helper.report.request == .inFlight(startedAt: f.time) && f.requests["phi"] == 2)
        helper.stop()

        let nothing = Fixture()
        nothing.status("phi", .checking); nothing.status("profile", .checking)
        let blind = nothing.helper(policy: .dispatchToObservable)
        state = await blind.requestSyncNow()
        precondition(state == .queued(reason: .unobservable, notBefore: nil) && nothing.requests.isEmpty,
                     "Without any observable participant nothing dispatches")
        blind.stop()
        print("PASS helper Sync now: unobservable Profile queues under waitForAllObservable, dispatches under dispatchToObservable with the barrier kept")
    }

    @MainActor static func syncNowIgnoresOtherDemand() async {
        // The pane-open request queues without a tap: the button stays idle.
        let f = Fixture(), helper = await f.completedHelper()
        f.tick(110)
        await helper.refresh(requestSync: true)
        precondition(helper.report.request == .idle, "The pane-open request must not show on the button")
        f.tick(160)
        await helper.refresh()
        precondition(f.requests["phi"] == 2 && helper.report.request == .idle,
                     "A round the pane-open request started is not the button's round")
        f.tick(162)
        var state = await helper.requestSyncNow()
        precondition(state == .inFlight(startedAt: Date(timeIntervalSince1970: 160)) && f.requests["phi"] == 2,
                     "A tap joins the running round and shows it")
        f.succeed(at: 164)
        await helper.refresh()
        precondition(helper.report.request == .idle)
        helper.stop()

        // An automatic dispatch refused at startup is not the button's failure.
        let g = Fixture(), automatic = g.helper()
        g.status("phi", .upToDate, at: 90); g.status("profile", .upToDate, at: 80)
        g.acceptsRequests = false
        await automatic.refresh()
        precondition(g.requests["phi"] == 1 && automatic.report.request == .idle,
                     "A refused automatic dispatch must not report the button as rejected")
        g.tick(170)
        state = await automatic.requestSyncNow()
        precondition(state == .rejected && g.requests["phi"] == 2, "A refused Sync now dispatch is rejected")
        g.acceptsRequests = true; g.tick(240)
        await automatic.refresh()
        precondition(g.requests["phi"] == 3 && automatic.report.request == .idle,
                     "An accepted automatic dispatch clears the rejection without showing on the button")
        automatic.stop()
        print("PASS helper Sync now: pane-open and automatic demand stay off the button; a tap joins a running round")
    }

    @MainActor static func failingRoundEndsEarly() async {
        let f = Fixture(), helper = await f.completedHelper()
        f.tick(170); f.status("phi", .offline, at: 103)
        var state = await helper.requestSyncNow()
        precondition(state == .inFlight(startedAt: f.time) && f.requests["phi"] == 2)
        f.tick(171)
        await helper.refresh()
        precondition(helper.report.request == .inFlight(startedAt: Date(timeIntervalSince1970: 170)),
                     "Failure evidence from before the request cannot end the round")
        f.tick(173); f.status("phi", .syncing, at: 103); f.status("profile", .upToDate, at: 103)
        await helper.refresh()
        precondition(helper.report.request == .inFlight(startedAt: Date(timeIntervalSince1970: 170)),
                     "A participant still working keeps the round")
        f.tick(175); f.status("phi", .offline, at: 103)
        await helper.refresh()
        precondition(helper.report.request == .inFlight(startedAt: Date(timeIntervalSince1970: 170)),
                     "One failed sample may be transient")
        f.tick(178)
        await helper.refresh()
        precondition(helper.report.request == .idle && helper.report.summary.phase == .offline
                     && f.saved == Date(timeIntervalSince1970: 103),
                     "A round every participant has settled on a failure since the request ends at the second such sample")
        // Automatic demand keeps today's cadence: the timeout (230) plus the interval (290).
        for second in stride(from: 181, through: 289, by: 3) {
            f.tick(Double(second))
            await helper.refresh()
        }
        precondition(f.requests["phi"] == 2, "An early end must not retry failing sync sooner than a timeout would")
        f.tick(290)
        await helper.refresh()
        precondition(f.requests["phi"] == 3 && helper.report.request == .idle,
                     "The automatic retry runs on the old schedule and stays off the button")
        helper.stop()

        // A tap after an early end only waits for the ordinary minimum interval.
        let g = Fixture(), tapped = await g.completedHelper()
        g.tick(170); g.status("phi", .needsAttention, at: 103)
        _ = await tapped.requestSyncNow()
        g.tick(172); g.status("phi", .needsAttention, at: 103); g.status("profile", .upToDate, at: 103)
        await tapped.refresh()
        g.tick(175)
        await tapped.refresh()
        precondition(tapped.report.request == .idle && g.requests["phi"] == 2)
        g.tick(200)
        state = await tapped.requestSyncNow()
        precondition(state == .queued(reason: .rateLimited, notBefore: Date(timeIntervalSince1970: 230)))
        g.tick(230)
        await tapped.refresh()
        precondition(g.requests["phi"] == 3 && tapped.report.request == .inFlight(startedAt: g.time),
                     "An explicit request is limited by the minimum interval, not the automatic retry delay")
        tapped.stop()
        print("PASS helper: a round that fails after the request ends early; automatic retries keep their cadence")
    }

    /// Ends a Sync now round early: tapped at 170, failure first seen at 173, ended at 176.
    @MainActor static func earlyEndedHelper(_ f: Fixture) async -> SyncHelper {
        let helper = await f.completedHelper()
        f.tick(170); f.status("phi", .offline, at: 103)
        _ = await helper.requestSyncNow()
        f.tick(173); f.status("phi", .offline, at: 103); f.status("profile", .offline, at: 103)
        await helper.refresh()
        f.tick(176)
        await helper.refresh()
        precondition(helper.report.request == .idle && f.requests["phi"] == 2)
        return helper
    }

    @MainActor static func earlyEndKeepsLateSuccess() async {
        // Overlapping refresh sources observing 0.2 s apart cannot end the round.
        let e = Fixture(), quick = await e.completedHelper()
        e.tick(170); e.status("phi", .offline, at: 103)
        _ = await quick.requestSyncNow()
        e.tick(173); e.status("phi", .offline, at: 103); e.status("profile", .offline, at: 103)
        await quick.refresh()
        e.time = Date(timeIntervalSince1970: 173.2)
        await quick.refresh()
        precondition(quick.report.request == .inFlight(startedAt: Date(timeIntervalSince1970: 170)),
                     "Two failing observations 0.2 s apart must not end the round")
        quick.stop()

        // Recovery inside the window records the success the running round would have.
        let f = Fixture(), helper = await earlyEndedHelper(f)
        f.succeed(at: 180)
        await helper.refresh()
        precondition(f.saved == Date(timeIntervalSince1970: 180) && helper.report.summary.phase == .upToDate,
                     "A late success inside the window is recorded")
        f.tick(183)
        await helper.refresh()
        precondition(helper.report.summary.phase == .upToDate && helper.report.request == .idle
                     && f.requests["phi"] == 2, "The recovered round leaves no demand and never shows as Checking")
        helper.stop()

        // Recovery after the window records nothing until the next round.
        let g = Fixture(), late = await earlyEndedHelper(g)
        g.succeed(at: 231)
        await late.refresh()
        precondition(g.saved == Date(timeIntervalSince1970: 103) && late.report.summary.phase == .checking,
                     "A success after the window does not complete the ended round")
        g.tick(290); g.succeed(at: 290)
        await late.refresh()
        precondition(g.requests["phi"] == 3, "The next automatic round runs on the old schedule")
        late.stop()

        // A membership change after an early end drops the retry delay: minimum interval only.
        let h = Fixture(), moved = await earlyEndedHelper(h)
        moved.membershipDidChange()
        h.tick(227)
        await moved.refresh()
        precondition(h.requests["phi"] == 2)
        h.tick(230)
        await moved.refresh()
        precondition(h.requests["phi"] == 3, "Membership change must not keep the early-end retry delay")
        moved.stop()
        print("PASS helper: early end needs a failure one poll apart and keeps a late success inside the timeout")
    }

    @MainActor static func syncNowFailsFastWhileNativeOffline() async {
        // Inside the minimum interval (160), a tap while the native engine is Offline dispatches
        // at once, and its round ends on native evidence alone while a Profile keeps syncing.
        let f = Fixture(), helper = await f.completedHelper()
        f.tick(110); f.status("phi", .offline, at: 103)
        var state = await helper.requestSyncNow()
        precondition(state == .inFlight(startedAt: f.time) && f.requests["phi"] == 2,
                     "A Sync now request while natively Offline skips the minimum interval")
        f.tick(112); f.status("phi", .offline, at: 103); f.status("profile", .syncing, at: 103)
        await helper.refresh()
        precondition(helper.report.request == .inFlight(startedAt: Date(timeIntervalSince1970: 110)),
                     "One native Offline sample may be transient")
        f.tick(115); f.status("profile", .syncing, at: 103)
        await helper.refresh()
        precondition(helper.report.request == .idle && helper.report.summary.phase == .offline
                     && f.saved == Date(timeIntervalSince1970: 103),
                     "A Sync now round ends once the native engine stays Offline for one poll interval")
        helper.stop()

        // Other explicit demand keeps the interval, and a round no tap joined keeps waiting for
        // every participant.
        let g = Fixture(), other = await g.completedHelper()
        g.tick(110); g.status("phi", .offline, at: 103)
        await other.refresh(requestSync: true)
        precondition(g.requests["phi"] == 1, "The pane-open request does not skip the minimum interval")
        g.tick(160)
        await other.refresh()
        precondition(g.requests["phi"] == 2 && other.report.request == .idle)
        g.tick(162); g.status("phi", .offline, at: 103); g.status("profile", .syncing, at: 103)
        await other.refresh()
        g.tick(165); g.status("profile", .syncing, at: 103)
        await other.refresh()
        g.tick(166)
        state = await other.requestSyncNow()
        precondition(state == .inFlight(startedAt: Date(timeIntervalSince1970: 160)) && g.requests["phi"] == 2,
                     "Native Offline alone does not end a round without a tap; a tap joins it")
        g.tick(169)
        await other.refresh()
        precondition(other.report.request == .idle && g.saved == Date(timeIntervalSince1970: 103),
                     "Once joined, the round ends on native Offline one poll interval later")
        other.stop()

        // Without a native participant nothing changes: the request waits for the interval.
        let h = Fixture(), plain = SyncHelper(isEligible: { true }, participants: {
            [SyncHelper.Participant(id: "phi", read: { h.snapshots["phi"] }, requestSync: {
                h.requests["phi", default: 0] += 1; return true })]
        }, lastSuccess: nil, saveSuccess: { _ in true }, now: { h.time })
        h.ids = ["phi"]; h.status("phi", .upToDate, at: 90)
        await plain.refresh()
        h.succeed(at: 103)
        await plain.refresh()
        h.tick(110); h.status("phi", .offline, at: 103)
        state = await plain.requestSyncNow()
        precondition(state == .queued(reason: .rateLimited, notBefore: Date(timeIntervalSince1970: 160))
                     && h.requests["phi"] == 1, "Only the native participant's Offline skips the interval")
        plain.stop()
        print("PASS helper Sync now: native Offline dispatches at once and ends the round without waiting for Profiles")
    }

    @MainActor static func reportCarriesNativeDetail() async {
        let f = Fixture(), helper = f.helper()
        var round = SyncRoundDetail()
        round.kinds[.spaces] = SyncKindStatus(received: 1, sent: 2, pending: 3, held: 4)
        round.note(.rejectedByServer, kind: .spaces)
        let detail = SyncNativeDetail().merging(round: round, at: Date(timeIntervalSince1970: 90))
        f.snapshots["phi"] = SyncContextSnapshot(id: "phi", phase: .needsAttention, lastSuccess: nil,
                                                 revision: 7, detail: detail)
        f.status("profile", .upToDate, at: 90)
        await helper.refresh()
        precondition(helper.report.snapshots["phi"]?.detail == detail && helper.report.snapshots["profile"]?.detail == nil,
                     "The report carries the native detail unchanged")
        helper.stop()
        print("PASS helper: report carries the native per-kind detail unchanged")
    }
}

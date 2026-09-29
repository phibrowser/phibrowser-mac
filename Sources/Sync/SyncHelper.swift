import Foundation

/// Account-scoped completion coordinator. Engines own data, keys and transport;
/// observing their progress must never feed back into unbounded refresh requests.
@MainActor
final class SyncHelper {
    static let lastSuccessDefaultsKey = "sync.lastCoordinatedSuccess"

    struct Participant {
        let id: String
        let read: @MainActor () async -> SyncContextSnapshot?
        /// True only when the owner accepted the request. Transport completion is
        /// observed separately; a bridge that drops an accepted request times out.
        let requestSync: @MainActor () -> Bool
        // Native state can change while asynchronous bridge observations are outstanding.
        var currentSnapshot: (@MainActor () -> SyncContextSnapshot?)? = nil
    }

    struct Report {
        var requiredIDs: Set<String> = []
        var snapshots: [String: SyncContextSnapshot] = [:]
        var summary = SyncStatusSummary(phase: .notStarted, lastSuccess: nil)
        var request: SyncRequestState = .idle
    }

    /// What an explicit request does while a participant is unobservable (missing or Checking),
    /// such as a lazy Profile that is never loaded. Automatic demand always waits.
    enum ExplicitRequestPolicy {
        /// Wait until every participant is observable and settled.
        case waitForAllObservable
        /// Dispatch once every observable participant is settled. Unobservable participants
        /// still receive the request and remain in the completion barrier.
        case dispatchToObservable
    }

    private struct Round {
        let startedAt: Date
        let previousSuccesses: [String: Date]
        /// Started by, or joined by, a Sync now request; only such a round is shown on the button.
        var syncNow: Bool
    }

    private enum CoordinationFailure { case timedOut, requestRejected, persistence }

    private let isEligible: () -> Bool
    private let participants: () -> [Participant]
    private let saveSuccess: (Date) -> Bool
    private let now: () -> Date
    private let minimumRoundInterval: TimeInterval
    private let staleInterval: TimeInterval
    private let roundTimeout: TimeInterval
    private let unobservablePolicy: ExplicitRequestPolicy
    private var upstream: [String: Participant] = [:]
    private var lastSuccess: Date?
    private var observedIDs: Set<String>?
    private var needsRound = true
    private var explicitRefreshPending = false
    /// Set only by `requestSyncNow()`; the button's queued and rejected states derive from it
    /// alone, so the pane-open request and automatic demand never show on the button.
    private var syncNowPending = false
    /// A dispatch that consumed `syncNowPending` was refused.
    private var requestRejected = false
    private var coordinationFailure: CoordinationFailure?
    private var nextRequestAt: Date?
    private var round: Round?
    private var generation = UUID()
    private var retired = false
    private var pollTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private(set) var report = Report()

    init(isEligible: @escaping () -> Bool, participants: @escaping () -> [Participant],
         lastSuccess: Date?, saveSuccess: @escaping (Date) -> Bool,
         now: @escaping () -> Date = Date.init,
         minimumRoundInterval: TimeInterval = 60, staleInterval: TimeInterval = 300,
         roundTimeout: TimeInterval = 60,
         unobservablePolicy: ExplicitRequestPolicy = .waitForAllObservable) {
        self.isEligible = isEligible
        self.participants = participants
        self.lastSuccess = lastSuccess
        self.saveSuccess = saveSuccess
        self.now = now
        self.minimumRoundInterval = minimumRoundInterval
        self.staleInterval = staleInterval
        self.roundTimeout = roundTimeout
        self.unobservablePolicy = unobservablePolicy
    }

    /// Sentinel's future authenticated adapter registers here, using a namespaced id.
    /// Until registered it is not part of the completion barrier. No IPC or keys are owned here.
    func registerUpstream(_ participant: Participant) {
        guard !retired, !participants().contains(where: { $0.id == participant.id }) else { return }
        upstream[participant.id] = participant
        membershipDidChange()
    }

    func unregisterUpstream(id: String) {
        guard upstream.removeValue(forKey: id) != nil else { return }
        membershipDidChange()
    }

    /// The owner forwards cached membership changes synchronously, including changes
    /// during a bridge await. This fences replies without enumerating Profiles twice.
    func membershipDidChange() {
        guard !retired else { return }
        generation = UUID()
        refreshTask?.cancel()
        refreshTask = nil
        round = nil
        observedIDs = nil
        needsRound = true
        explicitRefreshPending = false
        syncNowPending = false
        requestRejected = false
        updateTransientFailure(nil)
        report = Report(summary: SyncStatusSummary(
            phase: coordinationFailure == .persistence ? .needsAttention : .checking, lastSuccess: lastSuccess))
    }

    func start() {
        guard !retired, pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(for: .seconds(3)) }
                catch { return }
            }
        }
    }

    /// Ordinary pane/background polls only observe. An explicit pane reload may
    /// request a round, coalesced with in-flight work and the same minimum interval.
    func refresh(requestSync: Bool = false) async {
        guard !retired else { return }
        if requestSync && round == nil { explicitRefreshPending = true }
        if let refreshTask { await refreshTask.value; return }
        let expected = generation
        let pending = Task<Void, Never> { [weak self] in
            await self?.observe(generation: expected)
        }
        refreshTask = pending
        await pending.value
        if generation == expected, refreshTask == pending { refreshTask = nil }
    }

    /// Sync now: an explicit request with the pane reload's semantics (coalesced with an
    /// active round, same minimum interval). It joins an observation in progress and then
    /// observes once more, because the joined one may have passed its dispatch point before
    /// this request was recorded. A request that cannot dispatch yet stays queued for the
    /// helper's own poll; the returned state says why.
    func requestSyncNow() async -> SyncRequestState {
        guard !retired else { return .idle }
        requestRejected = false
        if round == nil { syncNowPending = true } else { round?.syncNow = true }
        if let joined = refreshTask {
            await joined.value
            if refreshTask == joined { refreshTask = nil }
        }
        await refresh()
        return report.request
    }

    func stop() {
        retired = true
        generation = UUID()
        pollTask?.cancel(); pollTask = nil
        refreshTask?.cancel(); refreshTask = nil
        round = nil
        report = Report()
    }

    private func resetIneligible() {
        round = nil
        observedIDs = nil
        needsRound = true
        explicitRefreshPending = false
        syncNowPending = false
        requestRejected = false
        coordinationFailure = nil
        report = Report()
    }

    private func updateTransientFailure(_ failure: CoordinationFailure?) {
        // Neither new observations nor request acceptance prove a failed local
        // write recovered. Keep it until a successful save or lifecycle reset.
        guard coordinationFailure != .persistence else { return }
        coordinationFailure = failure
    }

    private func observe(generation expected: UUID) async {
        guard !retired, generation == expected else { return }
        guard isEligible() else { resetIneligible(); return }
        let base = participants()
        let baseIDs = Set(base.map(\.id))
        let sources = base + upstream.values.filter { !baseIDs.contains($0.id) }.sorted { $0.id < $1.id }
        let ids = Set(sources.map(\.id))
        if observedIDs != ids {
            observedIDs = ids
            round = nil
            needsRound = true
            updateTransientFailure(nil)
        }
        var snapshots: [String: SyncContextSnapshot] = [:]
        for source in sources {
            let snapshot = await source.read()
            guard !retired, generation == expected else { return }
            guard isEligible() else { resetIneligible(); return }
            if let snapshot, snapshot.id == source.id { snapshots[source.id] = snapshot }
        }
        for source in sources {
            if let current = source.currentSnapshot {
                snapshots[source.id] = current().flatMap { $0.id == source.id ? $0 : nil }
            }
        }
        report.requiredIDs = ids
        report.snapshots = snapshots
        guard !ids.isEmpty else {
            report.summary = SyncStatusSummary(
                phase: coordinationFailure == .persistence ? .needsAttention : .checking, lastSuccess: lastSuccess)
            report.request = requestState(ids: ids, snapshots: snapshots, time: now())
            return
        }
        let observed = SyncStatusSummary.reduce(paired: true, requiredIDs: ids, snapshots: Array(snapshots.values))
        let successes = snapshots.compactMapValues(\.lastSuccess)
        let time = now()
        if let round {
            if time.timeIntervalSince(round.startedAt) >= roundTimeout {
                self.round = nil
                needsRound = true
                // Expiry invalidates the barrier, not an engine's healthy progress
                // or a lazy Profile's lack of visibility. Only claimed success
                // without fresh evidence is a coordination timeout error.
                updateTransientFailure(observed.phase == .upToDate ? .timedOut : nil)
                nextRequestAt = time.addingTimeInterval(minimumRoundInterval)
            } else if observed.phase == .upToDate, ids.allSatisfy({ id in
                guard let success = successes[id], success >= round.startedAt else { return false }
                return round.previousSuccesses[id].map { success > $0 } ?? true
            }) {
                if saveSuccess(time) {
                    lastSuccess = time
                    self.round = nil
                    coordinationFailure = nil
                } else {
                    coordinationFailure = .persistence
                }
            }
        }
        // Commit-only cycles, late replies and ordinary pending work are observations,
        // never demand. The engines' own schedulers handle local/remote changes.
        let failed = observed.phase == .offline || observed.phase == .needsAttention
        let stale = snapshots.values.contains { snapshot in
            snapshot.phase == .upToDate
                && (snapshot.lastSuccess.map { time.timeIntervalSince($0) >= staleInterval } ?? false)
        }
        // A missing/Checking Profile may be deliberately unloaded. Busy engines
        // already own their work. Neither can benefit from an all-context forced
        // round; retain demand until every participant is observable and settled.
        let canRequest = ids.allSatisfy { snapshots[$0].map(Self.isSettled) ?? false }
        // Only an explicit request may skip unobservable participants, and only by policy.
        let canRequestExplicitly: Bool
        switch unobservablePolicy {
        case .waitForAllObservable: canRequestExplicitly = canRequest
        case .dispatchToObservable:
            let observable = ids.compactMap { snapshots[$0] }.filter(Self.isObservable)
            canRequestExplicitly = !observable.isEmpty && observable.allSatisfy(Self.isSettled)
        }
        let explicit = explicitRefreshPending || syncNowPending
        if round == nil,
           (canRequest && (needsRound || explicit || failed || stale))
            || (explicit && canRequestExplicitly),
           nextRequestAt.map({ time >= $0 }) ?? true {
            nextRequestAt = time.addingTimeInterval(minimumRoundInterval)
            let bySyncNow = syncNowPending
            explicitRefreshPending = false
            syncNowPending = false
            let accepted = sources.allSatisfy { $0.requestSync() }
            guard !retired, generation == expected else { return }
            guard isEligible() else { resetIneligible(); return }
            if accepted {
                round = Round(startedAt: time, previousSuccesses: successes, syncNow: bySyncNow)
                needsRound = false
                requestRejected = false
                updateTransientFailure(nil)
            } else {
                needsRound = true
                if bySyncNow { requestRejected = true }
                updateTransientFailure(.requestRejected)
            }
        }
        let phase: SyncSummaryPhase
        if failed { phase = observed.phase }
        else if let failure = coordinationFailure,
                failure != .timedOut || observed.phase == .upToDate { phase = .needsAttention }
        else if round != nil && observed.phase == .upToDate { phase = .syncing }
        else if needsRound && observed.phase == .upToDate { phase = .checking }
        else { phase = observed.phase }
        report.summary = SyncStatusSummary(phase: phase, lastSuccess: lastSuccess)
        report.request = requestState(ids: ids, snapshots: snapshots, time: time)
    }

    /// Checking, and success without a timestamp, are no evidence (see `SyncStatusSummary`).
    private static func isObservable(_ snapshot: SyncContextSnapshot) -> Bool {
        snapshot.phase != .checking && !(snapshot.phase == .upToDate && snapshot.lastSuccess == nil)
    }

    private static func isSettled(_ snapshot: SyncContextSnapshot) -> Bool {
        switch snapshot.phase {
        case .upToDate: return snapshot.lastSuccess != nil
        case .offline, .needsAttention: return true
        case .checking, .initialSync, .syncing: return false
        }
    }

    /// The Sync now request only: in flight while a round it started or joined runs; otherwise
    /// why it has not dispatched yet, in the order the blocks clear: visibility, then busy
    /// engines, then the shared minimum interval.
    private func requestState(ids: Set<String>, snapshots: [String: SyncContextSnapshot],
                              time: Date) -> SyncRequestState {
        if let round, round.syncNow { return .inFlight(startedAt: round.startedAt) }
        guard syncNowPending else { return requestRejected ? .rejected : .idle }
        let observable = ids.compactMap { snapshots[$0] }.filter(Self.isObservable)
        if observable.isEmpty
            || (observable.count != ids.count && unobservablePolicy == .waitForAllObservable) {
            return .queued(reason: .unobservable, notBefore: nil)
        }
        if observable.contains(where: { $0.phase == .initialSync || $0.phase == .syncing }) {
            return .queued(reason: .busy, notBefore: nil)
        }
        if let nextRequestAt, time < nextRequestAt {
            return .queued(reason: .rateLimited, notBefore: nextRequestAt)
        }
        // Recorded after this observation's dispatch point; the next observation dispatches it.
        return .queued(reason: .busy, notBefore: nil)
    }
}

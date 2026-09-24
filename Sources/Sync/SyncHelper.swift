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
    }

    private struct Round {
        let startedAt: Date
        let previousSuccesses: [String: Date]
    }

    private enum CoordinationFailure { case timedOut, requestRejected, persistence }

    private let isEligible: () -> Bool
    private let participants: () -> [Participant]
    private let saveSuccess: (Date) -> Bool
    private let now: () -> Date
    private let minimumRoundInterval: TimeInterval
    private let staleInterval: TimeInterval
    private let roundTimeout: TimeInterval
    private var upstream: [String: Participant] = [:]
    private var lastSuccess: Date?
    private var observedIDs: Set<String>?
    private var needsRound = true
    private var explicitRefreshPending = false
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
         roundTimeout: TimeInterval = 60) {
        self.isEligible = isEligible
        self.participants = participants
        self.lastSuccess = lastSuccess
        self.saveSuccess = saveSuccess
        self.now = now
        self.minimumRoundInterval = minimumRoundInterval
        self.staleInterval = staleInterval
        self.roundTimeout = roundTimeout
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
        if generation == expected { refreshTask = nil }
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
        let canRequest = ids.allSatisfy { id in
            guard let snapshot = snapshots[id] else { return false }
            switch snapshot.phase {
            case .upToDate: return snapshot.lastSuccess != nil
            case .offline, .needsAttention: return true
            case .checking, .initialSync, .syncing: return false
            }
        }
        if round == nil, canRequest, needsRound || explicitRefreshPending || failed || stale,
           nextRequestAt.map({ time >= $0 }) ?? true {
            nextRequestAt = time.addingTimeInterval(minimumRoundInterval)
            explicitRefreshPending = false
            let accepted = sources.allSatisfy { $0.requestSync() }
            guard !retired, generation == expected else { return }
            guard isEligible() else { resetIneligible(); return }
            if accepted {
                round = Round(startedAt: time, previousSuccesses: successes)
                needsRound = false
                updateTransientFailure(nil)
            } else {
                needsRound = true
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
    }
}

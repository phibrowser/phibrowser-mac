import Foundation

/// Account-scoped completion coordinator. Engines own data, keys and transport;
/// this helper only requests rounds and records their common completion barrier.
@MainActor
final class SyncHelper {
    static let lastSuccessDefaultsKey = "sync.lastCoordinatedSuccess"

    struct Participant {
        let id: String
        let read: @MainActor () async -> SyncContextSnapshot?
        let requestSync: @MainActor () -> Void
        // Native state can change while asynchronous bridge observations are outstanding.
        // Its owner supplies a non-suspending read for the final completion fence.
        var currentSnapshot: (@MainActor () -> SyncContextSnapshot?)? = nil
    }

    struct Report {
        var requiredIDs: Set<String> = []
        var snapshots: [String: SyncContextSnapshot] = [:]
        var summary = SyncStatusSummary(phase: .notStarted, lastSuccess: nil)
    }

    private struct Round {
        let startedAt: Date
        let ids: Set<String>
        let previousSuccesses: [String: Date]
    }

    private let isEligible: () -> Bool
    private let participants: () -> [Participant]
    private let saveSuccess: (Date) -> Bool
    private let now: () -> Date
    private var upstream: [String: Participant] = [:]
    private var lastSuccess: Date?
    private var completedEvidence: [String: Date]?
    private var round: Round?
    private var generation = UUID()
    private var retired = false
    private var pollTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private(set) var report = Report()

    init(isEligible: @escaping () -> Bool, participants: @escaping () -> [Participant],
         lastSuccess: Date?, saveSuccess: @escaping (Date) -> Bool,
         now: @escaping () -> Date = Date.init) {
        self.isEligible = isEligible
        self.participants = participants
        self.lastSuccess = lastSuccess
        self.saveSuccess = saveSuccess
        self.now = now
    }

    /// Sentinel's future authenticated adapter registers here, using a namespaced id
    /// such as "sentinel". Until registered it is not part of the completion barrier.
    /// No IPC, data transfer or Sentinel key ownership is implied by this hook.
    func registerUpstream(_ participant: Participant) {
        guard !retired, !participants().contains(where: { $0.id == participant.id }) else { return }
        upstream[participant.id] = participant
        invalidateMembership()
    }

    func unregisterUpstream(id: String) {
        guard upstream.removeValue(forKey: id) != nil else { return }
        invalidateMembership()
    }

    private func invalidateMembership() {
        generation = UUID()
        refreshTask?.cancel()
        refreshTask = nil
        round = nil
        completedEvidence = nil
        report.summary = SyncStatusSummary(phase: .checking, lastSuccess: lastSuccess)
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

    /// Coalesces the background observation and a pane's immediate refresh.
    func refresh() async {
        guard !retired else { return }
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
        completedEvidence = nil
        report = Report()
    }

    private func currentParticipants() -> [Participant] {
        let base = participants()
        let ids = Set(base.map(\.id))
        return base + upstream.values.filter { !ids.contains($0.id) }.sorted { $0.id < $1.id }
    }

    private func observe(generation expected: UUID) async {
        guard isEligible() else {
            round = nil; completedEvidence = nil; report = Report()
            return
        }
        let sources = currentParticipants()
        let ids = Set(sources.map(\.id))
        var snapshots: [String: SyncContextSnapshot] = [:]
        for source in sources {
            let snapshot = await source.read()
            guard !retired, generation == expected else { return }
            guard isEligible() else { round = nil; completedEvidence = nil; report = Report(); return }
            if let snapshot, snapshot.id == source.id { snapshots[source.id] = snapshot }
        }
        // Profile creation/removal while a bridge reply is pending invalidates this observation.
        guard ids == Set(currentParticipants().map(\.id)) else {
            round = nil; completedEvidence = nil
            report.summary = SyncStatusSummary(phase: .checking, lastSuccess: lastSuccess)
            return
        }
        for source in sources {
            if let current = source.currentSnapshot {
                snapshots[source.id] = current().flatMap { $0.id == source.id ? $0 : nil }
            }
        }
        report.requiredIDs = ids
        report.snapshots = snapshots
        let observed = SyncStatusSummary.reduce(paired: true, requiredIDs: ids, snapshots: Array(snapshots.values))
        let successes = snapshots.compactMapValues(\.lastSuccess)
        if ids.isEmpty {
            round = nil; completedEvidence = nil
            report.summary = SyncStatusSummary(phase: .checking, lastSuccess: lastSuccess)
            return
        }
        let changed = completedEvidence == nil || completedEvidence != successes || observed.phase != .upToDate
        if !ids.isEmpty && (round.map { $0.ids != ids } == true || (round == nil && changed)) {
            round = Round(startedAt: now(), ids: ids, previousSuccesses: successes)
            for source in sources { source.requestSync() }
        }
        if let round, observed.phase == .upToDate,
           ids.allSatisfy({ id in
               guard let time = successes[id], time >= round.startedAt else { return false }
               return round.previousSuccesses[id].map { time > $0 } ?? true
           }) {
            let completion = now()
            guard saveSuccess(completion) else {
                report.summary = SyncStatusSummary(phase: .needsAttention, lastSuccess: lastSuccess)
                return
            }
            lastSuccess = completion
            completedEvidence = successes
            self.round = nil
        }
        report.summary = SyncStatusSummary(
            phase: round != nil && observed.phase == .upToDate ? .syncing : observed.phase,
            lastSuccess: lastSuccess)
    }
}

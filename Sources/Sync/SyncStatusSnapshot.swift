import Foundation

enum SyncContextPhase: String, Codable, Sendable {
    case checking, initialSync, syncing, upToDate, offline, needsAttention
}

struct SyncContextSnapshot: Equatable, Sendable {
    let id: String
    let phase: SyncContextPhase
    let lastSuccess: Date?
    let revision: UInt64
    /// Native engine only; Chromium Profiles report phases without per-kind numbers.
    var detail: SyncNativeDetail? = nil
}

/// Phi data kinds the native engine syncs. Profiles join once they have their own numbers.
enum SyncKind: String, CaseIterable, Sendable {
    case settings, spaces, bookmarks, pinnedTabs, urlRules

    /// Owned-kind registration labels in `PhiSyncEngine`.
    init?(ownedLabel: String) {
        switch ownedLabel {
        case "bookmarks": self = .bookmarks
        case "pins": self = .pinnedTabs
        case "urlrules": self = .urlRules
        default: return nil
        }
    }
}

/// Counts only. `received`/`sent` belong to the most recent round in which the kind had
/// activity (`activityAt`); `pending`/`held` are the kind's table state after the last round
/// that visited it. Held in memory only, so a relaunch starts without counts.
struct SyncKindStatus: Equatable, Sendable {
    var received = 0
    var sent = 0
    var activityAt: Date?
    var pending = 0
    var held = 0
}

/// Ordered by precedence: when one round hits several, the earliest case wins.
enum SyncProblemCategory: String, CaseIterable, Sendable {
    case resetRequired, saveFailedOnThisMac, readFailedOnThisMac, signInExpired, offline,
         rejectedByServer, serverError, unreadableRemoteData, waitingForProfilePairing
}

/// Metadata only (R12): a category, an optional kind and a time. No field can carry text.
struct SyncErrorSummary: Equatable, Sendable {
    let category: SyncProblemCategory
    let kind: SyncKind?
    let at: Date
}

/// What one completed engine round contributes. Kinds the round did not visit are absent.
/// `activityAt` of the supplied statuses is ignored; the merge stamps the round time.
struct SyncRoundDetail: Equatable, Sendable {
    var kinds: [SyncKind: SyncKindStatus] = [:]
    private(set) var problem: SyncProblemCategory?
    private(set) var problemKind: SyncKind?

    init(kinds: [SyncKind: SyncKindStatus] = [:]) { self.kinds = kinds }

    /// Keeps the most severe category of the round; the first report of a category keeps its kind.
    mutating func note(_ category: SyncProblemCategory, kind: SyncKind? = nil) {
        let order = SyncProblemCategory.allCases
        if let problem, order.firstIndex(of: problem)! <= order.firstIndex(of: category)! { return }
        problem = category
        problemKind = kind
    }
}

struct SyncNativeDetail: Equatable, Sendable {
    var kinds: [SyncKind: SyncKindStatus] = [:]
    var lastProblem: SyncErrorSummary?

    /// Unvisited kinds keep their values. A zero-activity round keeps the previous
    /// received/sent and their time; pending/held always follow a visited kind's table.
    /// A round problem replaces the last one; clearing is the caller's success rule.
    func merging(round: SyncRoundDetail, at time: Date) -> SyncNativeDetail {
        var merged = self
        for (kind, counts) in round.kinds {
            var status = merged.kinds[kind] ?? SyncKindStatus()
            if counts.received != 0 || counts.sent != 0 {
                status.received = counts.received
                status.sent = counts.sent
                status.activityAt = time
            }
            status.pending = counts.pending
            status.held = counts.held
            merged.kinds[kind] = status
        }
        if let problem = round.problem {
            merged.lastProblem = SyncErrorSummary(category: problem, kind: round.problemKind, at: time)
        }
        return merged
    }
}

/// The outcome of an explicit "Sync now" request as `SyncHelper` last observed it.
enum SyncRequestState: Equatable, Sendable {
    case idle
    case queued(reason: QueueReason, notBefore: Date?)
    case inFlight(startedAt: Date)
    case rejected

    enum QueueReason: String, Sendable { case busy, rateLimited, unobservable }
}

/// One rule for the Sync now control, shared by the pane and the hostless tests.
struct SyncNowButtonState: Equatable {
    enum Hint: Equatable { case none, waitingForCurrentSync, startingShortly, waitingForProfiles, failed }
    let isVisible: Bool
    let isEnabled: Bool
    let showsProgress: Bool
    let hint: Hint

    static func reduce(summary: SyncSummaryPhase, request: SyncRequestState) -> Self {
        guard summary != .notStarted else {
            return Self(isVisible: false, isEnabled: false, showsProgress: false, hint: .none)
        }
        switch request {
        case .idle: return Self(isVisible: true, isEnabled: true, showsProgress: false, hint: .none)
        case .inFlight: return Self(isVisible: true, isEnabled: false, showsProgress: true, hint: .none)
        case .queued(.unobservable, _):
            return Self(isVisible: true, isEnabled: false, showsProgress: true, hint: .waitingForProfiles)
        case .queued(.rateLimited, _):
            return Self(isVisible: true, isEnabled: false, showsProgress: true, hint: .startingShortly)
        case .queued:
            return Self(isVisible: true, isEnabled: false, showsProgress: true, hint: .waitingForCurrentSync)
        case .rejected: return Self(isVisible: true, isEnabled: true, showsProgress: false, hint: .failed)
        }
    }
}

enum SyncSummaryPhase: String { case notStarted, checking, initialSync, syncing, upToDate, offline, needsAttention }

struct SyncStatusSummary: Equatable {
    let phase: SyncSummaryPhase
    let lastSuccess: Date?

    static func reduce(paired: Bool, requiredIDs: Set<String>, snapshots: [SyncContextSnapshot]) -> Self {
        guard paired else { return Self(phase: .notStarted, lastSuccess: nil) }
        var newest: [String: SyncContextSnapshot] = [:]
        for snapshot in snapshots where requiredIDs.contains(snapshot.id) {
            if let old = newest[snapshot.id], old.revision > snapshot.revision { continue }
            newest[snapshot.id] = snapshot
        }
        let phases = newest.values.map(\.phase)
        let times = newest.values.compactMap(\.lastSuccess)
        let last = !requiredIDs.isEmpty && times.count == requiredIDs.count ? times.min() : nil
        if phases.contains(.needsAttention) { return Self(phase: .needsAttention, lastSuccess: last) }
        if requiredIDs.isEmpty || newest.count != requiredIDs.count || phases.contains(.checking) {
            return Self(phase: .checking, lastSuccess: last)
        }
        for phase in [SyncContextPhase.offline, .initialSync, .syncing] where phases.contains(phase) {
            return Self(phase: SyncSummaryPhase(rawValue: phase.rawValue)!, lastSuccess: last)
        }
        // Even a supplied success phase without a timestamp is incomplete evidence.
        return Self(phase: last == nil ? .checking : .upToDate, lastSuccess: last)
    }
}

struct SyncRoundCompletion: Equatable, Sendable {
    let pullDrained: Bool
    let outboundAccepted: Bool
    let persistenceSucceeded: Bool
    let pendingInbound: Bool
    let pendingOutbound: Bool
    let followupQueued: Bool
    var succeeded: Bool {
        pullDrained && outboundAccepted && persistenceSucceeded
            && !pendingInbound && !pendingOutbound && !followupQueued
    }
}

/// Engine-owned metadata. Local notifications can invalidate success before debounced
/// work reaches the actor; an older round cannot clear that newer pending edit.
final class SyncStatusState: @unchecked Sendable {
    private let lock = NSLock()
    private var value = SyncContextSnapshot(id: "phi", phase: .checking, lastSuccess: nil, revision: 0)

    var snapshot: SyncContextSnapshot {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    /// Every update bumps the revision, so a sample carrying newer detail always wins the
    /// newest-revision rule. A round's detail merges into the previous one; only a final
    /// Up to date clears the last problem.
    @discardableResult
    func update(_ phase: SyncContextPhase, completing revision: UInt64? = nil,
                round: SyncRoundDetail? = nil) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        let finalPhase: SyncContextPhase = phase == .upToDate && revision != nil && revision != value.revision
            ? .syncing : phase
        let time = Date()
        var detail = value.detail
        if let round { detail = (detail ?? SyncNativeDetail()).merging(round: round, at: time) }
        if finalPhase == .upToDate { detail?.lastProblem = nil }
        value = SyncContextSnapshot(id: value.id, phase: finalPhase,
            lastSuccess: finalPhase == .upToDate ? time : value.lastSuccess,
            revision: value.revision &+ 1, detail: detail)
        return value.revision
    }
}

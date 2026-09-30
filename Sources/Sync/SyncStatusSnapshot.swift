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

/// What the Sync pane shows for the helper's report, with the Profile mapping pause and the
/// unread Profile list laid over the summary (docs/sync.md, "Sync status contract"). Computed
/// from the report on every read and never stored: the completion of a round admitted before
/// the pause still writes the phase, so a pause written once would be overwritten.
///
/// Precedence, highest first:
/// 1. Reset required or reconfiguration: the summary and the Sync now control as they are,
///    nothing about the pause or the list. Retry cannot fix a reset.
/// 2. Not started (unpaired or ineligible): as it is.
/// 3. Pause shown (`.paused`): headline Sync paused over any summary (Syncing, Up to date,
///    Offline, Needs attention, a leftover Syncing from a round admitted before the gate), the reason, the failure
///    category, the Profiles, and Retry in place of Sync now.
/// 4. Profile list not enumerated for `profileListWaitLine` or more: the summary with the
///    waiting line; from `profileListWaitAttention` the headline is Needs attention. Sync now
///    stays; no Retry, because the list read is retried automatically.
/// 5. Otherwise, the grace included: the summary and Sync now as they are. A Sync now during
///    the grace is reported queued Busy by the helper and shows as waiting.
///
/// Foundation only: carries enums, counts and local Profile display names, never identifiers.
struct SyncStatusPresentation: Equatable {
    enum Headline: Equatable {
        case phase(SyncSummaryPhase)
        case paused
    }

    /// The local Profiles the pause waits for, by display name. Ids that no longer resolve
    /// to a name (a Profile deleted meanwhile) are left out.
    enum PausedProfiles: Equatable {
        /// One to `maximumNamedProfiles` names, sorted for display.
        case names([String])
        /// More names than that.
        case count(Int)
        /// None of the ids resolved.
        case unnamed
    }

    struct Pause: Equatable {
        let reason: SyncProfileMappingPause.Reason
        let failure: SyncProfileMappingFailureCategory?
        let profiles: PausedProfiles
    }

    let headline: Headline
    /// The Sync now control; hidden while Retry is shown.
    let syncNow: SyncNowButtonState
    /// Retry in the Sync now slot; it runs the Profile mapping repair pass.
    let showsRetry: Bool
    let pause: Pause?
    /// The Profile list has not been enumerated for `profileListWaitLine` or more.
    let showsProfileListWait: Bool
    /// False when the pause cancelled the Sync now request: the control returns to idle and
    /// nothing is announced for that request.
    let announcesSyncNowOutcome: Bool

    /// The unread list is shown as a problem line after this long (the list retry reaches
    /// its 30-second cap at about this time).
    static let profileListWaitLine: TimeInterval = 30
    /// ... and as Needs attention after this long: several capped retries have failed.
    static let profileListWaitAttention: TimeInterval = 5 * 60
    /// Up to this many Profiles are named; more are counted.
    static let maximumNamedProfiles = 3

    static func present(summary: SyncSummaryPhase, request: SyncRequestState,
                        profileMappingPause: SyncProfileMappingPauseStatus,
                        syncNowCancelledByPause: Bool, profileListNotEnumeratedSince: Date?,
                        resetRequired: Bool, profileNames: () -> [String: String], now: Date) -> Self {
        let button = SyncNowButtonState.reduce(summary: summary, request: request)
        let announces = !syncNowCancelledByPause
        guard !resetRequired, summary != .notStarted else {
            return Self(headline: .phase(summary), syncNow: button, showsRetry: false, pause: nil,
                        showsProfileListWait: false, announcesSyncNowOutcome: announces)
        }
        if case let .paused(reason, failure, ids) = profileMappingPause {
            let resolved = profileNames()
            let names = ids.compactMap { resolved[$0] }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            let profiles: PausedProfiles = names.isEmpty ? .unnamed
                : names.count > maximumNamedProfiles ? .count(names.count) : .names(names)
            let hidden = SyncNowButtonState(isVisible: false, isEnabled: false, showsProgress: false, hint: .none)
            return Self(headline: .paused, syncNow: hidden, showsRetry: true,
                        pause: Pause(reason: reason, failure: failure, profiles: profiles),
                        showsProfileListWait: false, announcesSyncNowOutcome: announces)
        }
        let waited = profileListNotEnumeratedSince.map { now.timeIntervalSince($0) } ?? -1
        let headline: Headline = waited >= profileListWaitAttention ? .phase(.needsAttention) : .phase(summary)
        return Self(headline: headline, syncNow: button, showsRetry: false, pause: nil,
                    showsProfileListWait: waited >= profileListWaitLine, announcesSyncNowOutcome: announces)
    }

    /// Whether "Sync resumed" is announced: a shown pause gave way to a normal summary. One that
    /// gives way to a reset, to Not started (for example the account key became unavailable) or
    /// to another shown pause has not resumed sync.
    static func announcesResume(wasPaused: Bool, now presentation: Self, resetRequired: Bool) -> Bool {
        wasPaused && !resetRequired && presentation.pause == nil
            && presentation.headline != .phase(.notStarted)
    }
}

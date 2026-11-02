// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import PostHog

/// Why sync needs attention, as reported to telemetry. Held reasons are `SyncHeldReason` with a
/// `held` prefix; then the engine's `SyncProblemCategory` (Offline excluded: it is not Needs
/// attention); then the conditions `SyncHelper` and the status presentation add on their own.
/// Raw values are stable: they are PostHog properties, Sentry tags and feedback keys.
enum SyncAttentionReason: String, Codable, CaseIterable, Sendable {
    case heldUnmappedProfileOwner, heldUnmappedSpaceOwner, heldIneligibleSpaceOwner, heldLineageExists,
         heldLandingFailed, heldStoreError, heldUnknown
    case resetRequired, saveFailedOnThisMac, readFailedOnThisMac, signInExpired, rejectedByServer,
         serverError, unreadableRemoteData, waitingForProfilePairing
    case persistenceFailure, profileListNotEnumerated, pinScopeMigrationFailed, profileMappingPaused, unknown

    init(held: SyncHeldReason) {
        switch held {
        case .unmappedProfileOwner: self = .heldUnmappedProfileOwner
        case .unmappedSpaceOwner: self = .heldUnmappedSpaceOwner
        case .ineligibleSpaceOwner: self = .heldIneligibleSpaceOwner
        case .lineageExists: self = .heldLineageExists
        case .landingFailed: self = .heldLandingFailed
        case .storeError: self = .heldStoreError
        case .unknown: self = .heldUnknown
        }
    }

    /// Nil for Offline, which never makes a problem.
    init?(category: SyncProblemCategory) {
        switch category {
        case .offline: return nil
        case .resetRequired: self = .resetRequired
        case .saveFailedOnThisMac: self = .saveFailedOnThisMac
        case .readFailedOnThisMac: self = .readFailedOnThisMac
        case .signInExpired: self = .signInExpired
        case .rejectedByServer: self = .rejectedByServer
        case .serverError: self = .serverError
        case .unreadableRemoteData: self = .unreadableRemoteData
        case .waitingForProfilePairing: self = .waitingForProfilePairing
        }
    }

    /// Reasons that point at a defect rather than a state the user or the network explains. Only
    /// these reach Sentry; every reason reaches PostHog.
    var isUnexpected: Bool {
        switch self {
        case .heldLineageExists, .heldLandingFailed, .heldStoreError, .heldUnknown, .saveFailedOnThisMac,
             .readFailedOnThisMac, .rejectedByServer, .unreadableRemoteData, .persistenceFailure,
             .pinScopeMigrationFailed:
            return true
        default:
            return false
        }
    }
}

/// The dedupe identity of one Needs attention problem. No Profile, Space or account identifier is
/// part of it: every Chromium Profile shares the one `chromium` context.
struct SyncAttentionProblem: Hashable, Codable, Sendable {
    enum Context: String, Codable, Sendable {
        /// The native Phi engine.
        case phi
        /// Any Chromium Profile.
        case chromium
        /// Conditions `SyncHelper` reports beside the engines: coordination persistence, the Profile
        /// list wait, the Profile mapping pause and the pin scope follower.
        case helper
    }

    let context: Context
    let kind: SyncKind?
    let reason: SyncAttentionReason

    /// `context:kind:reason`, with `none` for no kind. Persistence and feedback key.
    var key: String { "\(context.rawValue):\(kind?.rawValue ?? "none"):\(reason.rawValue)" }
}

/// The numbers that accompany a Sentry report: counts and an age, nothing else.
struct SyncAttentionObservation: Equatable, Sendable {
    let heldCount: Int
    let ageSeconds: Int
}

/// Reports sync Needs attention problems to PostHog, to Sentry for unexpected reasons, and to the
/// Feedback V2 metadata, each problem once (docs/sync.md, "Sync status contract"). `SyncHelper` feeds
/// it every report it publishes. State is persisted, so an app restart never reports a problem again.
@MainActor
final class SyncAttentionReporter {
    static let activeDefaultsKey = "sync.attention.active"
    static let sentryHistoryDefaultsKey = "sync.attention.sentryHistory"
    /// When the current uninterrupted run of Not started summaries began.
    static let notStartedSinceDefaultsKey = "sync.attention.notStartedSince"
    /// Not started this long, continuously, means sync is off: tracked problems are forgotten.
    /// Shorter runs (launch before unlock, a transient key discard) change nothing.
    static let notStartedDropAfter: TimeInterval = 10 * 60
    /// A problem must be present this long, continuously, before it is reported.
    static let entryDelay: TimeInterval = 60
    /// An entered problem must be absent this long, continuously, before it is reported cleared.
    static let clearGrace: TimeInterval = 60
    static let snapshotInterval: TimeInterval = 24 * 60 * 60
    static let sentryInterval: TimeInterval = 7 * 24 * 60 * 60

    typealias PostHogCapture = (_ event: String, _ properties: [String: Any]) -> Void
    typealias SentryCapture = (SyncAttentionProblem, SyncAttentionObservation) -> Void

    /// One tracked problem: present but not yet entered (`enteredAt == nil`) or entered.
    struct Entry: Codable, Equatable {
        var problem: SyncAttentionProblem
        var firstSeenAt: Date
        var lastSeenAt: Date
        var enteredAt: Date?
        var absentSince: Date?
        var lastSnapshotAt: Date?
        var lastSentryAt: Date?
        var appVersionAtEntry: String?
        var lastHeldCount: Int
    }

    private let defaults: UserDefaults
    private let appVersion: String
    private let postHogCapture: PostHogCapture
    private let sentryCapture: SentryCapture
    private var entries: [String: Entry]
    private var sentryHistory: [String: Date]
    private var lastPhase: SyncSummaryPhase?
    /// When `entries` was last written. `lastSeenAt` alone advances every observation, so it is
    /// written at most once per `clearGrace`; every other change is written at once.
    private var savedAt: Date?

    init(defaults: UserDefaults, appVersion: String,
         postHogCapture: @escaping PostHogCapture, sentryCapture: @escaping SentryCapture) {
        self.defaults = defaults
        self.appVersion = appVersion
        self.postHogCapture = postHogCapture
        self.sentryCapture = sentryCapture
        entries = Self.load([String: Entry].self, defaults, Self.activeDefaultsKey) ?? [:]
        sentryHistory = Self.load([String: Date].self, defaults, Self.sentryHistoryDefaultsKey) ?? [:]
    }

    /// The production reporter for an account's defaults.
    static func live(defaults: UserDefaults) -> SyncAttentionReporter {
        SyncAttentionReporter(
            defaults: defaults, appVersion: SystemUtils.appVersion,
            postHogCapture: { event, properties in PostHogSDK.shared.capture(event, properties: properties) },
            sentryCapture: { problem, observation in
                SentryService.captureSyncAttention(
                    kind: problem.kind?.rawValue ?? "none", reason: problem.reason.rawValue,
                    context: problem.context.rawValue,
                    details: ["held_count": observation.heldCount, "age_seconds": observation.ageSeconds])
            })
    }

    /// Feeds one helper report. `persistenceFailure` is the helper's failed common-time write.
    func observe(_ report: SyncHelper.Report, persistenceFailure: Bool, now: Date) {
        lastPhase = report.summary.phase
        let before = (entries, sentryHistory)
        defer {
            if entries != before.0,
               Self.withoutLastSeen(entries) != Self.withoutLastSeen(before.0)
                || savedAt.map({ now.timeIntervalSince($0) >= Self.clearGrace }) ?? true {
                Self.save(entries, defaults, Self.activeDefaultsKey)
                savedAt = now
            }
            if sentryHistory != before.1 { Self.save(sentryHistory, defaults, Self.sentryHistoryDefaultsKey) }
        }
        // Not started (launch before unlock, locked, unpaired, signed out) proves nothing: problems
        // are neither present nor absent, so neither debounce nor grace advances. Only a long run
        // means sync is off; then everything is forgotten without a cleared event.
        let notStartedSince = defaults.object(forKey: Self.notStartedSinceDefaultsKey) as? Date
        guard report.summary.phase != .notStarted else {
            guard let since = notStartedSince else {
                defaults.set(now, forKey: Self.notStartedSinceDefaultsKey)
                return
            }
            if now.timeIntervalSince(since) >= Self.notStartedDropAfter { entries = [:] }
            return
        }
        if notStartedSince != nil {
            defaults.removeObject(forKey: Self.notStartedSinceDefaultsKey)
            // The run of Not started is a gap in the evidence: restart debounce and grace.
            for key in entries.keys {
                entries[key]?.absentSince = nil
                if entries[key]?.enteredAt == nil {
                    entries[key]?.firstSeenAt = now
                    entries[key]?.lastSeenAt = now
                }
            }
        }
        let evidence = Self.evidence(in: report, persistenceFailure: persistenceFailure, now: now)
        for (key, found) in evidence.present.sorted(by: { $0.key < $1.key }) {
            var entry = entries[key] ?? Entry(problem: found.problem, firstSeenAt: now, lastSeenAt: now,
                                              lastHeldCount: found.held)
            // A gap in the evidence breaks continuity before entry.
            if entry.enteredAt == nil, now.timeIntervalSince(entry.lastSeenAt) > Self.clearGrace {
                entry.firstSeenAt = now
            }
            entry.lastSeenAt = now
            entry.absentSince = nil
            entry.lastHeldCount = found.held
            if entry.enteredAt == nil {
                if now.timeIntervalSince(entry.firstSeenAt) >= Self.entryDelay { enter(&entry, now: now) }
            } else if entry.lastSnapshotAt.map({ now.timeIntervalSince($0) >= Self.snapshotInterval }) ?? true {
                entry.lastSnapshotAt = now
                var properties = Self.properties(entry.problem, held: entry.lastHeldCount)
                properties["age_seconds"] = Self.seconds(now, since: entry.enteredAt ?? now)
                postHogCapture("sync_attention_snapshot", properties)
            }
            entries[key] = entry
        }
        for (key, var entry) in entries.sorted(by: { $0.key < $1.key }) where evidence.present[key] == nil {
            // A context that is checking, syncing or offline neither confirms nor denies its problems.
            guard evidence.decided.contains(entry.problem.context) else { continue }
            guard let enteredAt = entry.enteredAt else {
                entries[key] = nil
                continue
            }
            let absentSince = entry.absentSince ?? now
            guard now.timeIntervalSince(absentSince) >= Self.clearGrace else {
                entry.absentSince = absentSince
                entries[key] = entry
                continue
            }
            var properties = Self.properties(entry.problem, held: entry.lastHeldCount)
            properties["duration_seconds"] = Self.seconds(now, since: enteredAt)
            properties["cleared_by"] = entry.appVersionAtEntry == appVersion ? "resolved" : "upgrade"
            postHogCapture("sync_attention_cleared", properties)
            AppLogInfo("[sync-attention] cleared " + Self.logFields(entry.problem, held: entry.lastHeldCount))
            entries[key] = nil
        }
    }

    /// Feedback V2 `extra` keys: `sync_phase` always; with tracked problems also
    /// `sync_attention_problems` (`context:kind:reason=held_count`, `;`-joined, sorted),
    /// `sync_attention_oldest_age_seconds` and `sync_attention_entered_count`.
    func feedbackMetadata(now: Date) -> [String: String] {
        var metadata = ["sync_phase": lastPhase?.rawValue ?? "unknown"]
        guard !entries.isEmpty else { return metadata }
        let sorted = entries.values.sorted { $0.problem.key < $1.problem.key }
        metadata["sync_attention_problems"] = sorted
            .map { "\($0.problem.key)=\($0.lastHeldCount)" }.joined(separator: ";")
        let oldest = sorted.map { Self.seconds(now, since: $0.enteredAt ?? $0.firstSeenAt) }.max() ?? 0
        metadata["sync_attention_oldest_age_seconds"] = String(oldest)
        metadata["sync_attention_entered_count"] = String(sorted.filter { $0.enteredAt != nil }.count)
        return metadata
    }

    private func enter(_ entry: inout Entry, now: Date) {
        entry.enteredAt = now
        entry.lastSnapshotAt = now
        entry.appVersionAtEntry = appVersion
        postHogCapture("sync_attention_entered", Self.properties(entry.problem, held: entry.lastHeldCount))
        AppLogInfo("[sync-attention] entered " + Self.logFields(entry.problem, held: entry.lastHeldCount))
        let key = entry.problem.key
        guard entry.problem.reason.isUnexpected,
              sentryHistory[key].map({ now.timeIntervalSince($0) >= Self.sentryInterval }) ?? true else { return }
        sentryHistory[key] = now
        entry.lastSentryAt = now
        sentryCapture(entry.problem, SyncAttentionObservation(heldCount: entry.lastHeldCount, ageSeconds: 0))
    }

    // MARK: - Deriving problems

    struct Evidence {
        /// Problem key to the problem and its held count.
        var present: [String: (problem: SyncAttentionProblem, held: Int)] = [:]
        /// Contexts whose state proves the absence of any problem not in `present`. Chromium and the
        /// helper always do; Phi only when Up to date or in Needs attention.
        var decided: Set<SyncAttentionProblem.Context> = [.helper, .chromium]

        mutating func add(_ context: SyncAttentionProblem.Context, _ kind: SyncKind?,
                          _ reason: SyncAttentionReason, held: Int) {
            let problem = SyncAttentionProblem(context: context, kind: kind, reason: reason)
            present[problem.key] = (problem, (present[problem.key]?.held ?? 0) + held)
        }
    }

    /// The problems a report shows and the contexts whose absence it proves.
    static func evidence(in report: SyncHelper.Report, persistenceFailure: Bool, now: Date) -> Evidence {
        var evidence = Evidence()
        let isPhi: (SyncContextSnapshot) -> Bool = { $0.detail != nil || $0.id == "phi" }
        let chromium = report.snapshots.values.filter { !isPhi($0) }
        for snapshot in report.snapshots.values where isPhi(snapshot) {
            switch snapshot.phase {
            case .upToDate:
                evidence.decided.insert(.phi)
            case .needsAttention:
                evidence.decided.insert(.phi)
                let before = evidence.present.count
                let detail = snapshot.detail ?? SyncNativeDetail()
                for kind in SyncKind.allCases {
                    guard let status = detail.kinds[kind], status.held > 0 else { continue }
                    var accounted = 0
                    for (reason, count) in status.heldByReason where count > 0 {
                        evidence.add(.phi, kind, SyncAttentionReason(held: reason), held: count)
                        accounted += count
                    }
                    // Held with no recorded reason that the last problem names (unreadable settings):
                    // the category explains it, so it is one problem, not two.
                    let explained = accounted == 0 && detail.lastProblem?.kind == kind
                        && detail.lastProblem.flatMap { SyncAttentionReason(category: $0.category) } != nil
                    if accounted < status.held, !explained {
                        evidence.add(.phi, kind, .heldUnknown, held: status.held - accounted)
                    }
                }
                if let problem = detail.lastProblem, let reason = SyncAttentionReason(category: problem.category) {
                    evidence.add(.phi, problem.kind, reason, held: problem.kind.flatMap { detail.kinds[$0]?.held } ?? 0)
                }
                if evidence.present.count == before { evidence.add(.phi, nil, .unknown, held: 0) }
            case .checking, .initialSync, .syncing, .offline:
                break
            }
        }
        // Present iff a Chromium Profile needs attention, absent otherwise: a Profile can sit in
        // Syncing or Checking indefinitely, so settledness cannot gate the clear.
        if chromium.contains(where: { $0.phase == .needsAttention }) {
            evidence.add(.chromium, nil, .unknown, held: 0)
        }
        if persistenceFailure { evidence.add(.helper, nil, .persistenceFailure, held: 0) }
        if let since = report.profileListNotEnumeratedSince,
           now.timeIntervalSince(since) >= SyncStatusPresentation.profileListWaitAttention {
            evidence.add(.helper, nil, .profileListNotEnumerated, held: 0)
        }
        if report.pinScopeMigrationFailure != nil {
            evidence.add(.helper, .pinnedTabs, .pinScopeMigrationFailed, held: 0)
        }
        if case .paused(.needsAttention, _, _) = report.profileMappingPause {
            evidence.add(.helper, nil, .profileMappingPaused, held: 0)
        }
        return evidence
    }

    // MARK: - Helpers

    private static func properties(_ problem: SyncAttentionProblem, held: Int) -> [String: Any] {
        ["sync_context": problem.context.rawValue, "sync_kind": problem.kind?.rawValue ?? "none",
         "sync_reason": problem.reason.rawValue, "held_count": held]
    }

    private static func logFields(_ problem: SyncAttentionProblem, held: Int) -> String {
        "context=\(problem.context.rawValue) kind=\(problem.kind?.rawValue ?? "none") "
            + "reason=\(problem.reason.rawValue) held=\(held)"
    }

    private static func withoutLastSeen(_ entries: [String: Entry]) -> [String: Entry] {
        entries.mapValues { entry in
            var entry = entry
            entry.lastSeenAt = .distantPast
            return entry
        }
    }

    private static func seconds(_ now: Date, since start: Date) -> Int {
        max(0, Int(now.timeIntervalSince(start)))
    }

    private static func load<T: Decodable>(_ type: T.Type, _ defaults: UserDefaults, _ key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func save<T: Encodable>(_ value: T, _ defaults: UserDefaults, _ key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}

import Foundation

/// Loads every mapped user Profile that is not in memory, so that its Chromium sync runs
/// without a window (plan 2026-09-29, section 4.6; docs/sync.md, "Profile loading").
/// Decisions only: the owner supplies the Profile list, the checks, the load call and a
/// timer, which is what lets `build-scripts/test-sync-profile-loader.sh` run it hostless.
///
/// One load at a time. The first waits `initialDelay` after `syncDidStart()`; each later one
/// waits `gap` after the previous load ended. `loadNow()` (Sync now) skips both, once, for
/// every Profile that needs a load at that moment. A failed load is retried after a delay
/// that doubles up to `maximumRetryDelay`; the other Profiles go on meanwhile. While started,
/// the owner is asked for a fresh Profile list every `recheckInterval`: nothing tells this
/// side that a Profile unloaded after its last window closed.
///
/// A requested load cannot be cancelled. After `stop()`, or once it is older than
/// `loadTimeout`, its completion is ignored.
@MainActor
final class SyncProfileLoader {
    struct Profile {
        let id: String
        let isLoaded: Bool
        /// False for the agent's fallback Profile, which never syncs.
        var isUserAssignable = true
    }

    struct Timing {
        var initialDelay: TimeInterval = 30
        var gap: TimeInterval = 5
        var recheckInterval: TimeInterval = 60
        var firstRetryDelay: TimeInterval = 30
        var maximumRetryDelay: TimeInterval = 600
        var loadTimeout: TimeInterval = 60
    }

    /// Developer switch in `UserDefaults.standard`, for measuring memory without the loader.
    /// Absent or false: the loader runs. Not a synced setting and has no UI.
    static let disabledDefaultsKey = "phi.sync.debug.profileLoadingDisabled"

    /// The cached Profile list; reading it must not refresh it.
    private let profiles: @MainActor () -> [Profile]
    private let refreshProfiles: @MainActor () -> Void
    /// The key layer would hand this Profile's key to Chromium right now.
    private let hasDeliverableKey: @MainActor (String) -> Bool
    /// Enrolled, unlocked, signed in to the account the owner was built for.
    private let isEligible: @MainActor () -> Bool
    private let isPaused: @MainActor () -> Bool
    private let isProfileListEnumerated: @MainActor () -> Bool
    private let isEnabled: @MainActor () -> Bool
    private let load: @MainActor (String, @escaping @MainActor (Bool) -> Void) -> Void
    /// Asks the owner to call `evaluate()` after the delay, replacing the previous request.
    private let wake: @MainActor (TimeInterval) -> Void
    private let now: () -> Date
    private let log: @MainActor (String) -> Void
    private let timing: Timing

    private var startedAt: Date?
    private var stopped = false
    private var inFlight: (id: String, token: UInt64, since: Date)?
    private var lastToken: UInt64 = 0
    private var lastLoadEndedAt: Date?
    private var lastRecheckAt: Date?
    private var failures: [String: (count: Int, retryAt: Date)] = [:]
    /// Successful loads, so a list that has not been refreshed since does not ask again at once.
    private var loadedAt: [String: Date] = [:]
    private var loadNowRequested = false
    private var urgent: Set<String> = []
    private var evaluating = false
    private var evaluateAgain = false

    init(profiles: @escaping @MainActor () -> [Profile],
         refreshProfiles: @escaping @MainActor () -> Void,
         hasDeliverableKey: @escaping @MainActor (String) -> Bool,
         isEligible: @escaping @MainActor () -> Bool,
         isPaused: @escaping @MainActor () -> Bool = { false },
         isProfileListEnumerated: @escaping @MainActor () -> Bool = { true },
         isEnabled: @escaping @MainActor () -> Bool,
         load: @escaping @MainActor (String, @escaping @MainActor (Bool) -> Void) -> Void,
         wake: @escaping @MainActor (TimeInterval) -> Void,
         now: @escaping () -> Date = Date.init,
         log: @escaping @MainActor (String) -> Void = { _ in },
         timing: Timing = Timing()) {
        self.profiles = profiles
        self.refreshProfiles = refreshProfiles
        self.hasDeliverableKey = hasDeliverableKey
        self.isEligible = isEligible
        self.isPaused = isPaused
        self.isProfileListEnumerated = isProfileListEnumerated
        self.isEnabled = isEnabled
        self.load = load
        self.wake = wake
        self.now = now
        self.log = log
        self.timing = timing
    }

    /// Sync has started for the account. The first call arms the initial delay; later calls
    /// (a re-pairing restarts the schedule) keep it.
    func syncDidStart() {
        guard !stopped else { return }
        if startedAt == nil {
            startedAt = now()
            log("profile loading armed; first load in \(Int(timing.initialDelay)) s")
        }
        evaluate()
    }

    /// Sync now: every Profile that needs a load right now is loaded without the initial
    /// delay, the gap, a pending retry delay or a recent-load wait. Dropped while the loader
    /// could not load anyway (not started, disabled, ineligible, paused, list not enumerated).
    func loadNow() {
        guard !stopped, startedAt != nil else { return }
        loadNowRequested = true
        evaluate()
    }

    /// Re-reads the conditions and the cached list: the owner's timer, a change of the
    /// Profile list, and the end of a pause call this. Idempotent.
    func evaluate() {
        guard !stopped else { return }
        // A load completing synchronously, or a list publisher firing inside a closure,
        // must not start a second load from inside this one.
        guard !evaluating else { evaluateAgain = true; return }
        evaluating = true
        defer { evaluating = false }
        repeat {
            evaluateAgain = false
            step()
        } while evaluateAgain && !stopped
    }

    /// Stops for good (sign-out, account switch, retirement). A load in flight completes
    /// in Chromium; its completion is ignored.
    func stop() {
        stopped = true
        inFlight = nil
        urgent = []
        loadNowRequested = false
    }

    private func step() {
        let time = now()
        if let flight = inFlight {
            guard time.timeIntervalSince(flight.since) >= timing.loadTimeout else {
                schedule(flight.since.addingTimeInterval(timing.loadTimeout), from: time)
                return
            }
            inFlight = nil
            log("profile load for sync timed out after \(Int(timing.loadTimeout)) s")
            record(flight.id, success: false, since: flight.since, at: time)
        }
        guard let startedAt else { return }
        guard isEnabled(), isEligible(), isProfileListEnumerated(), !isPaused() else {
            loadNowRequested = false
            urgent = []
            schedule(time.addingTimeInterval(timing.recheckInterval), from: time)
            return
        }
        if lastRecheckAt.map({ time.timeIntervalSince($0) >= timing.recheckInterval }) ?? true {
            lastRecheckAt = time
            refreshProfiles()
        }
        let listed = profiles()
        let listedIds = Set(listed.map(\.id))
        failures = failures.filter { listedIds.contains($0.key) }
        loadedAt = loadedAt.filter { listedIds.contains($0.key) }
        // Loaded by a window or by an earlier load: a past failure no longer applies.
        for profile in listed where profile.isLoaded { failures[profile.id] = nil }
        let needing = listed.filter { $0.isUserAssignable && !$0.isLoaded && hasDeliverableKey($0.id) }.map(\.id)
        if loadNowRequested {
            loadNowRequested = false
            urgent = Set(needing)
        }
        urgent.formIntersection(needing)
        if let id = needing.first(where: urgent.contains) {
            start(id, at: time)
            return
        }
        let earliest = max(startedAt.addingTimeInterval(timing.initialDelay),
                           (lastLoadEndedAt ?? .distantPast).addingTimeInterval(timing.gap))
        var next = (lastRecheckAt ?? time).addingTimeInterval(timing.recheckInterval)
        for id in needing {
            var dueAt = earliest
            if let failure = failures[id] { dueAt = max(dueAt, failure.retryAt) }
            if let loaded = loadedAt[id] { dueAt = max(dueAt, loaded.addingTimeInterval(timing.recheckInterval)) }
            if dueAt <= time {
                start(id, at: time)
                return
            }
            next = min(next, dueAt)
        }
        schedule(next, from: time)
    }

    private func start(_ id: String, at time: Date) {
        urgent.remove(id)
        lastToken &+= 1
        let token = lastToken
        inFlight = (id, token, time)
        schedule(time.addingTimeInterval(timing.loadTimeout), from: time)
        load(id) { [weak self] success in self?.complete(token: token, success: success) }
    }

    private func complete(token: UInt64, success: Bool) {
        guard !stopped, let flight = inFlight, flight.token == token else { return }
        inFlight = nil
        record(flight.id, success: success, since: flight.since, at: now())
        evaluate()
    }

    private func record(_ id: String, success: Bool, since: Date, at time: Date) {
        lastLoadEndedAt = time
        let milliseconds = Int(time.timeIntervalSince(since) * 1000)
        if success {
            failures[id] = nil
            loadedAt[id] = time
            log("loaded a profile for sync in \(milliseconds) ms")
        } else {
            let count = (failures[id]?.count ?? 0) + 1
            let delay = min(timing.firstRetryDelay * pow(2, Double(count - 1)), timing.maximumRetryDelay)
            failures[id] = (count, time.addingTimeInterval(delay))
            log("profile load for sync failed after \(milliseconds) ms (attempt \(count)); retry in \(Int(delay)) s")
        }
    }

    private func schedule(_ date: Date, from time: Date) {
        wake(max(0, date.timeIntervalSince(time)))
    }
}

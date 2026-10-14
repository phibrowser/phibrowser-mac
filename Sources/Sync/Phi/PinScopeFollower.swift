// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Makes the pin scope row follow the `PhiPinnedTabScope` key (B-3 stage 1, design 3.2). The key is
/// the desired scope, written by Settings or by settings sync; the row
/// (`BrowserDataSettingsModel.pinnedTabScopeRawValue`) is the actual scope, changed only by
/// `LocalStore.changePinnedTabScope`. This object runs that migration until the two agree.
///
/// - Triggers: `trigger()` on a key change (local write or settings landing), on mount, at the start
///   of every pin round, and from its own retry timer; `followNow(preferredSpaceId:)` for Settings,
///   which names its Space through `setPreferredSpaceHint(_:)` before it writes the key.
/// - One job at a time. A trigger during a job sets a "run again" flag; the job reads the key again
///   after every suspension, so no target is carried across one.
/// - It never writes the key or its sidecars (design principle 3).
/// - Failure retries after a delay that doubles from `firstRetryDelay` to `maximumRetryDelay`; the
///   consecutive count and the last kind go to `publishFailure`. Nothing is persisted: after a
///   relaunch the mount trigger sees row != key and starts over.
/// - `retire()` is synchronous and one-way. A retired follower starts no job and checks retirement
///   after every suspension. A store job already queued targets its own account's store and writes
///   no shared state, so it is left to finish.
///
/// Decisions only: the coordinator supplies the key and row reads, the migration, the status sink
/// and the timer (the shape of `SyncProfileMappingPauseReconciler`), so a fixture can drive it.
@MainActor
final class PinScopeFollower {
    /// The end of one attempt, as `followNow()` reports it.
    enum AttemptResult: Equatable {
        /// The row equals the key the attempt read.
        case applied
        /// The migration threw; a retry is scheduled.
        case failed(SyncPinScopeMigrationFailure.Kind)
        /// The migration threw and nothing will retry it: only
        /// `PhiChromiumCoordinator.followPinnedTabScopeNow` reports it, for a store no mounted follower
        /// covers. The caller undoes its key write.
        case failedNoRetry(SyncPinScopeMigrationFailure.Kind)
        /// No attempt ran: the follower is retired, or no key is set.
        case deferred
    }

    struct Timing {
        var firstRetryDelay: TimeInterval = 5
        var maximumRetryDelay: TimeInterval = 300
    }

    struct Effects {
        /// The key now; nil when it is missing or unrecognized.
        var desiredScope: @MainActor () -> PinnedTabScope?
        /// The row now, through the main context; nil when the store is unreadable.
        var rowScope: @MainActor () -> PinnedTabScope?
        /// `LocalStore.changePinnedTabScope(to:)` with the preferred owner read at call time. The second
        /// argument is the Space `followNow(preferredSpaceId:)` named for this attempt, if any.
        var migrate: @MainActor (PinnedTabScope, String?) async throws -> Void
        /// The failure state after every change of it; nil once an attempt succeeds or the
        /// follower retires.
        var publishFailure: @MainActor (SyncPinScopeMigrationFailure?) -> Void
        /// Calls the closure after the delay unless the returned cancel runs first.
        var schedule: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> (@MainActor () -> Void)
        var log: @MainActor (String) -> Void = { _ in }
    }

    private let effects: Effects
    private let timing: Timing
    /// The store whose row this follower moves, so its owner can tell which store it covers.
    let storeIdentity: ObjectIdentifier?
    /// One attempt per `followNow()`, no run-again: the unmounted path's follower, which is retired as
    /// soon as that attempt reports. A key that moves during the attempt (an account switch rewriting
    /// the shared key) is not taken as a new target for a store nothing mounted.
    private let singleAttempt: Bool

    /// A job is running. The pin round's block predicate reads it through
    /// `PhiPinnedTabLocalAccess.scopeFollowerBusy()`.
    private(set) var isRunning = false
    private(set) var isRetired = false
    private(set) var failure: SyncPinScopeMigrationFailure?

    private var runAgain = false
    /// The Space Settings last named (`setPreferredSpaceHint(_:)` or `followNow(preferredSpaceId:)`);
    /// the next attempt to start takes it.
    private var preferredSpaceHint: String?
    /// Attempts started so far; `followNow()` waits for the first one after its call.
    private var attemptSerial: UInt64 = 0
    private var waiters: [(after: UInt64, resume: (AttemptResult) -> Void)] = []
    private var nextRetryDelay: TimeInterval
    private var cancelRetry: (@MainActor () -> Void)?
    /// The key of the failed attempt that armed the retry. A trigger naming the same key waits for the
    /// timer, so round-start triggers do not defeat the backoff; a different key runs at once.
    private var failedKey: PinnedTabScope?

    init(effects: Effects, timing: Timing = Timing(), storeIdentity: ObjectIdentifier? = nil,
         singleAttempt: Bool = false) {
        self.effects = effects
        self.timing = timing
        self.storeIdentity = storeIdentity
        self.singleAttempt = singleAttempt
        self.nextRetryDelay = timing.firstRetryDelay
    }

    /// Whether this follower still has work: a job running, or a key the row does not match yet.
    /// Settings shows the key's scope as finishing in the background while it does. The browser
    /// migration runner does not read it: it waits only for a job in flight (design 3.6 as amended).
    var isPending: Bool {
        guard !isRetired else { return false }
        if isRunning { return true }
        guard let key = effects.desiredScope() else { return false }
        return effects.rowScope() != key
    }

    /// Starts a job unless one is running (then it runs again), the follower is retired, or the row
    /// already equals the key. Synchronous up to the job's start, so a pin round that triggers and
    /// then samples `isRunning` sees the job it started.
    func trigger() {
        guard !isRetired else { return }
        if isRunning { runAgain = true; return }
        guard let key = effects.desiredScope() else { return }
        if cancelRetry != nil, key == failedKey { return }
        // Row == key with no job needed: the account (or Settings) moved the key back to the row after
        // a failed attempt, so the failure is over as surely as after a successful migration.
        guard effects.rowScope() != key else { settle(); return }
        start()
    }

    /// Settings, before it writes the key: the Space the next attempt to start prefers. Set ahead of
    /// the key, so a trigger-started attempt that runs before `followNow()` (a round's trigger, the
    /// retry timer) takes it as well. One-shot like `followNow`'s.
    func setPreferredSpaceHint(_ spaceId: String?) {
        guard !isRetired else { return }
        preferredSpaceHint = spaceId
    }

    /// Settings: run now, past any retry wait, and return the outcome of the first attempt that
    /// starts after this call. A non-nil `preferredSpaceId` goes to that attempt's migration, which
    /// still prefers the active Space when there is one; nil keeps a hint set earlier.
    func followNow(preferredSpaceId: String? = nil) async -> AttemptResult {
        guard !isRetired else { return .deferred }
        let after = attemptSerial
        if let preferredSpaceId { preferredSpaceHint = preferredSpaceId }
        return await withCheckedContinuation { continuation in
            waiters.append((after: after, resume: { continuation.resume(returning: $0) }))
            if isRunning {
                runAgain = true
            } else {
                start()
            }
        }
    }

    /// Sign-out and account switch. Synchronous and one-way: the retry timer is cancelled, waiters
    /// get `.deferred`, and a job in flight stops at its next check.
    func retire() {
        guard !isRetired else { return }
        isRetired = true
        cancelRetry?()
        cancelRetry = nil
        failedKey = nil
        runAgain = false
        preferredSpaceHint = nil
        if failure != nil {
            failure = nil
            effects.publishFailure(nil)
        }
        resolveAll(.deferred)
    }

    private func start() {
        cancelRetry?()
        cancelRetry = nil
        failedKey = nil
        isRunning = true
        Task { @MainActor [weak self] in
            await self?.run()
        }
    }

    private func run() async {
        defer { isRunning = false }
        repeat {
            runAgain = false
            attemptSerial &+= 1
            let attempt = attemptSerial
            // Taken by the attempt that starts now, so it never outlives the call that named it.
            let hint = preferredSpaceHint
            preferredSpaceHint = nil
            guard !isRetired else { return }
            // Read now, never carried in from the trigger.
            guard let key = effects.desiredScope() else {
                resolve(upTo: attempt, .deferred)
                continue
            }
            guard let row = effects.rowScope() else {
                fail(.storeUnavailable, key: key, attempt: attempt)
                continue
            }
            if row == key {
                succeed(attempt: attempt)
                continue
            }
            do {
                try await effects.migrate(key, hint)
            } catch {
                guard !isRetired else { return }
                effects.log("pinned-tab scope migration to \(key.rawValue) failed (\(PhiSyncLog.describe(error)))")
                fail(Self.kind(of: error), key: key, attempt: attempt)
                continue
            }
            guard !isRetired else { return }
            effects.log("pinned-tab scope migrated to \(key.rawValue)")
            succeed(attempt: attempt)
            // The store's transaction established row == key in its own context; the main context
            // may not have merged it yet, so the row is not read back here. The key is: one that
            // moved during the migration is a new target.
            if effects.desiredScope() != key { runAgain = true }
        } while runAgain && !isRetired && !singleAttempt
    }

    private func succeed(attempt: UInt64) {
        settle()
        resolve(upTo: attempt, .applied)
    }

    /// Row == key: the retry and the failure state end, whether a migration established it or the key
    /// came back to the row.
    private func settle() {
        cancelRetry?()
        cancelRetry = nil
        failedKey = nil
        nextRetryDelay = timing.firstRetryDelay
        if failure != nil {
            failure = nil
            effects.publishFailure(nil)
        }
    }

    private func fail(_ kind: SyncPinScopeMigrationFailure.Kind, key: PinnedTabScope, attempt: UInt64) {
        let next = SyncPinScopeMigrationFailure(attempts: (failure?.attempts ?? 0) + 1, lastKind: kind)
        failure = next
        effects.publishFailure(next)
        resolve(upTo: attempt, .failed(kind))
        cancelRetry?()
        cancelRetry = nil
        // A `followNow()` made during this attempt is owed an attempt of its own: run it now. Any
        // other trigger that arrived meanwhile is answered by the retry, so the backoff holds.
        guard waiters.isEmpty else {
            runAgain = true
            return
        }
        // The key moved during this attempt: a new target, which runs now like any trigger naming a
        // different key, instead of waiting out a retry armed with the old one.
        if effects.desiredScope() != key {
            runAgain = true
            return
        }
        runAgain = false
        let delay = nextRetryDelay
        nextRetryDelay = min(delay * 2, timing.maximumRetryDelay)
        failedKey = key
        cancelRetry = effects.schedule(delay) { [weak self] in
            guard let self, !self.isRetired else { return }
            self.cancelRetry = nil
            self.failedKey = nil
            self.trigger()
        }
    }

    private func resolve(upTo attempt: UInt64, _ result: AttemptResult) {
        var remaining: [(after: UInt64, resume: (AttemptResult) -> Void)] = []
        var due: [(AttemptResult) -> Void] = []
        for waiter in waiters {
            if waiter.after < attempt { due.append(waiter.resume) } else { remaining.append(waiter) }
        }
        waiters = remaining
        for resume in due { resume(result) }
    }

    private func resolveAll(_ result: AttemptResult) {
        let due = waiters
        waiters = []
        for waiter in due { waiter.resume(result) }
    }

    private static func kind(of error: Error) -> SyncPinScopeMigrationFailure.Kind {
        switch error as? LocalStoreWriteError {
        case .migrationInFlight?: return .browserMigrationRunning
        case .storeUnavailable?: return .storeUnavailable
        default: return .writeFailed
        }
    }
}

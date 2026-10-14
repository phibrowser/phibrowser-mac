import Foundation

// Drives the production PinScopeFollower (B-3 stage 1, design 3.2) over injected effects: the key and
// the row are plain values, the migration is a gate the test opens, and the retry timer is a manual
// schedule. The scope types below are sliced from LocalStore+PinnedTabScope.swift.
/* PRODUCTION_SCOPE_TYPES */

enum PhiSyncLog { static func describe(_ error: Error) -> String { String(describing: error) } }

struct OtherError: Error {}

@MainActor
final class Box<Value> { var value: Value? }

@MainActor
final class World {
    final class Timer {
        let delay: TimeInterval
        let fire: @MainActor () -> Void
        var cancelled = false
        init(delay: TimeInterval, fire: @escaping @MainActor () -> Void) { self.delay = delay; self.fire = fire }
    }

    /// The `PhiPinnedTabScope` key. Only the test writes it; the follower can only read it.
    var key: PinnedTabScope? = .profile
    var row: PinnedTabScope? = .profile
    var migrateCalls: [PinnedTabScope] = []
    /// The preferred Space each migration was handed, in call order.
    var migrateHints: [String?] = []
    /// Runs inside the next unheld migration, before it throws or succeeds; then cleared.
    var duringMigrate: (@MainActor () -> Void)?
    var inFlight = 0, maxInFlight = 0
    /// While true, every migration suspends until `finish` resumes it.
    var hold = false
    /// Thrown by every unheld migration while set.
    var failWith: Error?
    private var held: [(target: PinnedTabScope, resume: CheckedContinuation<Void, Error>)] = []
    var published: [SyncPinScopeMigrationFailure?] = []
    var timers: [Timer] = []
    var logs: [String] = []

    var effects: PinScopeFollower.Effects {
        PinScopeFollower.Effects(
            desiredScope: { [unowned self] in self.key },
            rowScope: { [unowned self] in self.row },
            migrate: { [unowned self] target, hint in
                self.migrateCalls.append(target)
                self.migrateHints.append(hint)
                if let during = self.duringMigrate { self.duringMigrate = nil; during() }
                self.inFlight += 1
                self.maxInFlight = max(self.maxInFlight, self.inFlight)
                defer { self.inFlight -= 1 }
                if self.hold {
                    try await withCheckedThrowingContinuation { continuation in
                        self.held.append((target, continuation))
                    }
                } else if let error = self.failWith {
                    throw error
                }
                // `changePinnedTabScope` establishes row == target in its own transaction.
                self.row = target
            },
            publishFailure: { [unowned self] in self.published.append($0) },
            schedule: { [unowned self] delay, fire in
                let timer = Timer(delay: delay, fire: fire)
                self.timers.append(timer)
                return { timer.cancelled = true }
            },
            log: { [unowned self] in self.logs.append($0) })
    }

    var heldCount: Int { held.count }

    /// Resumes the oldest suspended migration: success, or the given error.
    func finish(throwing error: Error? = nil) {
        let (_, continuation) = held.removeFirst()
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }

    var liveTimers: [Timer] { timers.filter { !$0.cancelled } }

    func fireLiveTimer() {
        let live = liveTimers
        precondition(live.count == 1, "expected exactly one armed retry timer, found \(live.count)")
        live[0].cancelled = true    // Consumed: a fired timer is no longer armed.
        live[0].fire()
    }
}

@MainActor
func drain() async {
    for _ in 0..<50 { await Task.yield() }
}

@MainActor
func makeFollower(_ world: World) -> PinScopeFollower {
    PinScopeFollower(effects: world.effects)
}

@main
struct PinScopeFollowerTests {
    @MainActor
    static func main() async {
        await follows()
        await rerunsOnKeyChangeDuringRun()
        await failureAndRetry()
        await keyMovesDuringAFailingAttempt()
        await preferredSpaceHint()
        await retirement()
        await singleFlight()
        noKeyWrite()
        await followNowResults()
        await failureEndsWhenKeyReturnsToRow()
        await singleAttemptDoesNotRunAgain()
    }

    @MainActor
    static func follows() async {
        let world = World()
        world.key = .app
        let follower = makeFollower(world)
        precondition(follower.isPending, "row != key is pending work")
        follower.trigger()
        precondition(follower.isRunning, "trigger starts the job synchronously so a round sampling busy sees it")
        await drain()
        precondition(world.migrateCalls == [.app], "migrates to the key: \(world.migrateCalls)")
        precondition(world.row == .app && !follower.isRunning && !follower.isPending)
        precondition(follower.failure == nil && world.published.isEmpty && world.timers.isEmpty)
        // Row already equals the key: no job.
        follower.trigger()
        precondition(!follower.isRunning)
        await drain()
        precondition(world.migrateCalls == [.app])
        // No key: nothing to follow.
        world.key = nil
        follower.trigger()
        precondition(!follower.isRunning && !follower.isPending)
        print("PASS follower follows: row != key migrates to the key and applies; row == key or no key starts no job")
    }

    @MainActor
    static func rerunsOnKeyChangeDuringRun() async {
        // A trigger during the run, with the key changed while the migration is suspended.
        do {
            let world = World()
            world.key = .app
            world.hold = true
            let follower = makeFollower(world)
            follower.trigger()
            await drain()
            precondition(world.migrateCalls == [.app] && world.heldCount == 1)
            world.key = .space
            follower.trigger()
            world.finish()
            await drain()
            precondition(world.migrateCalls == [.app, .space],
                         "second migration reads the key now, not the captured .app: \(world.migrateCalls)")
            precondition(world.heldCount == 1)
            world.finish()
            await drain()
            precondition(world.row == .space && !follower.isRunning && world.migrateCalls.count == 2)
        }
        // The key moves during the migration with no trigger at all: the post-migration re-read still
        // catches it.
        do {
            let world = World()
            world.key = .app
            world.hold = true
            let follower = makeFollower(world)
            follower.trigger()
            await drain()
            world.key = .space
            world.finish()
            await drain()
            precondition(world.migrateCalls == [.app, .space], "re-read after a suspension: \(world.migrateCalls)")
            world.finish()
            await drain()
            precondition(world.row == .space && !follower.isRunning)
        }
        print("PASS follower re-runs on a key change during a run: second migration takes the new key, with or without a trigger")
    }

    @MainActor
    static func failureAndRetry() async {
        let world = World()
        world.key = .app
        world.failWith = LocalStoreWriteError.storeUnavailable
        let follower = makeFollower(world)
        follower.trigger()
        await drain()
        precondition(world.migrateCalls == [.app] && !follower.isRunning)
        precondition(follower.failure == SyncPinScopeMigrationFailure(attempts: 1, lastKind: .storeUnavailable))
        precondition(world.published.last! == SyncPinScopeMigrationFailure(attempts: 1, lastKind: .storeUnavailable))
        precondition(world.liveTimers.map(\.delay) == [5])

        // A trigger for the same failing key waits for the timer (a round start must not defeat backoff).
        follower.trigger()
        await drain()
        precondition(world.migrateCalls.count == 1 && world.liveTimers.count == 1)

        // The delay doubles to the 300 s cap; the count and the last kind follow each attempt.
        var delays: [TimeInterval] = [5]
        let kinds: [(Error, SyncPinScopeMigrationFailure.Kind)] = [
            (LocalStoreWriteError.migrationInFlight, .browserMigrationRunning),
            (OtherError(), .writeFailed),
            (LocalStoreWriteError.storeUnavailable, .storeUnavailable)]
        for attempt in 2...9 {
            let (error, kind) = kinds[attempt % kinds.count]
            world.failWith = error
            world.fireLiveTimer()
            await drain()
            precondition(world.migrateCalls.count == attempt)
            precondition(follower.failure == SyncPinScopeMigrationFailure(attempts: attempt, lastKind: kind),
                         "attempt \(attempt): \(String(describing: follower.failure))")
            delays.append(world.liveTimers[0].delay)
        }
        precondition(delays == [5, 10, 20, 40, 80, 160, 300, 300, 300], "backoff: \(delays)")

        // A different key runs at once and cancels the armed timer.
        world.failWith = OtherError()
        let armed = world.liveTimers[0]
        world.key = .space
        follower.trigger()
        precondition(armed.cancelled && follower.isRunning, "a new key does not wait for the old key's retry")
        await drain()
        precondition(world.migrateCalls.last == .space && follower.failure?.attempts == 10)
        precondition(world.liveTimers.map(\.delay) == [300], "backoff is not reset by a key change alone")

        // followNow runs at once past the retry wait and reports that attempt.
        world.failWith = LocalStoreWriteError.migrationInFlight
        let before = world.migrateCalls.count
        let result = await follower.followNow()
        precondition(result == .failed(.browserMigrationRunning), "followNow: \(result)")
        precondition(world.migrateCalls.count == before + 1)

        // Success clears the failure (published as nil) and resets the backoff.
        world.failWith = nil
        let applied = await follower.followNow()
        precondition(applied == .applied && follower.failure == nil && world.published.last! == nil)
        precondition(world.liveTimers.isEmpty && world.row == .space)
        world.key = .profile
        world.failWith = OtherError()
        follower.trigger()
        await drain()
        precondition(world.liveTimers.map(\.delay) == [5], "backoff restarts after a success")
        precondition(follower.failure == SyncPinScopeMigrationFailure(attempts: 1, lastKind: .writeFailed))
        print("PASS follower failure and retry: 5 s doubling capped at 300 s, count and kind exposed, same key waits, new key and followNow run at once, success resets")
    }

    @MainActor
    static func retirement() async {
        // Before a run: nothing starts.
        do {
            let world = World()
            world.key = .app
            let follower = makeFollower(world)
            follower.retire()
            follower.trigger()
            precondition(!follower.isRunning && !follower.isPending)
            let result = await follower.followNow()
            precondition(result == .deferred)
            await drain()
            precondition(world.migrateCalls.isEmpty && world.published.isEmpty)
        }
        // During a run: the in-flight store job finishes (it is left to), but the follower produces no
        // effect after it — no log of success, no re-run for a moved key, no failure, no timer.
        for outcome in [nil, OtherError() as Error?] {
            let world = World()
            world.key = .app
            world.hold = true
            let follower = makeFollower(world)
            follower.trigger()
            await drain()
            let waiterResult = Box<PinScopeFollower.AttemptResult>()
            Task { @MainActor in waiterResult.value = await follower.followNow() }
            await drain()
            world.key = .space
            follower.retire()
            await drain()
            precondition(waiterResult.value == .deferred, "retire resolves waiters with .deferred")
            let publishedBefore = world.published.count
            world.finish(throwing: outcome)
            await drain()
            precondition(world.migrateCalls == [.app], "no job after retirement: \(world.migrateCalls)")
            precondition(world.published.count == publishedBefore && follower.failure == nil)
            precondition(world.timers.isEmpty && world.logs.isEmpty && !follower.isRunning)
            follower.trigger()
            await drain()
            precondition(world.migrateCalls == [.app])
        }
        // Retirement with a retry armed: the timer is cancelled, the failure is withdrawn, and a stale
        // firing does nothing.
        do {
            let world = World()
            world.key = .app
            world.failWith = OtherError()
            let follower = makeFollower(world)
            follower.trigger()
            await drain()
            let timer = world.liveTimers[0]
            follower.retire()
            precondition(timer.cancelled && follower.failure == nil && world.published.last! == nil)
            timer.fire()
            await drain()
            precondition(world.migrateCalls.count == 1 && !follower.isRunning)
        }
        print("PASS follower retirement: before a run starts nothing; during a run the job's end has no effect; an armed retry is cancelled")
    }

    @MainActor
    static func singleFlight() async {
        let world = World()
        world.key = .app
        world.hold = true
        let follower = makeFollower(world)
        follower.trigger()
        follower.trigger()
        await drain()
        follower.trigger()
        follower.trigger()
        await drain()
        precondition(world.migrateCalls == [.app] && world.heldCount == 1, "one job at a time")
        world.finish()
        await drain()
        // The coalesced re-run read the key again, found row == key and migrated nothing.
        precondition(world.migrateCalls == [.app] && !follower.isRunning && world.maxInFlight == 1)

        // Several triggers across a key change coalesce into one more migration.
        world.key = .space
        follower.trigger()
        await drain()
        world.key = .profile
        follower.trigger(); follower.trigger(); follower.trigger()
        world.finish()
        await drain()
        precondition(world.migrateCalls == [.app, .space, .profile], "\(world.migrateCalls)")
        world.finish()
        await drain()
        precondition(!follower.isRunning && world.maxInFlight == 1 && world.row == .profile)
        print("PASS follower single-flight: triggers during a job set one run-again flag; never two migrations at once")
    }

    @MainActor
    static func noKeyWrite() {
        // The follower's only capabilities are its effects, and none can write the key: two reads
        // returning a value, the migration, the status sink, the timer and the log. That holds by
        // construction, so there is no key write to count; this pins the effect list so a new effect
        // gets reviewed against design principle 3, and the script's source scan keeps
        // UserDefaults out of the follower itself.
        let world = World()
        let labels = Mirror(reflecting: world.effects).children.compactMap(\.label)
        precondition(labels == ["desiredScope", "rowScope", "migrate", "publishFailure", "schedule", "log"],
                     "a new effect needs review against design principle 3: \(labels)")
        print("PASS follower writes no key: its effects are key read, row read, migrate, status, timer and log only (source scan in the script finds no UserDefaults)")
    }

    @MainActor
    static func keyMovesDuringAFailingAttempt() async {
        // Review round 1 F3: the key moves while an attempt is failing. The new key runs at once; no
        // retry is armed with the old one.
        let world = World()
        world.key = .app
        world.failWith = OtherError()
        let follower = makeFollower(world)
        world.duringMigrate = { [unowned world, unowned follower] in
            world.key = .space
            follower.trigger()   // The settings landing's trigger: the follower is busy, so it only re-runs.
        }
        follower.trigger()
        await drain()
        precondition(world.migrateCalls == [.app, .space],
                     "the moved key runs right after the failed attempt: \(world.migrateCalls)")
        // The second attempt failed too, with the key unchanged: that one arms the retry, with the new key.
        precondition(world.timers.count == 1 && world.liveTimers.count == 1, "only the new key's retry is armed: \(world.timers.count)")
        precondition(follower.failure?.attempts == 2)
        // The same move without a trigger: the failing attempt still reads the key before arming.
        let quiet = World()
        quiet.key = .app
        quiet.failWith = OtherError()
        let quietFollower = makeFollower(quiet)
        quiet.duringMigrate = { [unowned quiet] in quiet.key = .space }
        quietFollower.trigger()
        await drain()
        precondition(quiet.migrateCalls == [.app, .space] && quiet.timers.count == 1, "\(quiet.migrateCalls)")
        print("PASS follower key moves during a failing attempt: the new key runs at once instead of waiting for a retry armed with the old key")
    }

    @MainActor
    static func preferredSpaceHint() async {
        // Review round 1 F6: the Space Settings names reaches the attempt `followNow` starts, and only it.
        let world = World()
        world.key = .app
        let follower = makeFollower(world)
        let result = await follower.followNow(preferredSpaceId: "space-selected")
        precondition(result == .applied && world.migrateHints == ["space-selected"], "\(world.migrateHints)")
        world.key = .space
        follower.trigger()
        await drain()
        precondition(world.migrateHints == ["space-selected", nil], "a trigger-driven attempt has no hint: \(world.migrateHints)")
        // While busy: the hint goes to the owed attempt, not the running one.
        world.hold = true
        world.key = .profile
        follower.trigger()
        await drain()
        let owed = Box<PinScopeFollower.AttemptResult>()
        Task { @MainActor in owed.value = await follower.followNow(preferredSpaceId: "space-later") }
        await drain()
        world.key = .app
        world.finish()
        await drain()
        world.finish()
        await drain()
        precondition(owed.value == .applied)
        precondition(world.migrateHints == ["space-selected", nil, nil, "space-later"], "\(world.migrateHints)")
        // Review round 2 R1: Settings hands its Space over before it writes the key, so an attempt a
        // trigger starts ahead of followNow (a round, the retry timer) takes it; still one-shot.
        let early = World()
        let earlyFollower = makeFollower(early)
        earlyFollower.setPreferredSpaceHint("space-first")
        early.key = .space
        earlyFollower.trigger()
        await drain()
        let earlyResult = await earlyFollower.followNow()
        precondition(earlyResult == .applied && early.migrateHints == ["space-first"],
                     "a trigger-started attempt ahead of followNow takes the hint: \(early.migrateHints)")
        early.key = .app
        earlyFollower.trigger()
        await drain()
        precondition(early.migrateHints == ["space-first", nil], "the hint is one-shot: \(early.migrateHints)")
        print("PASS follower preferred Space: the Space Settings names goes to the first attempt after it (followNow's or a trigger's ahead of it) and to no other")
    }

    @MainActor
    static func followNowResults() async {
        // Idle with row == key: the attempt it starts applies without migrating.
        do {
            let world = World()
            let follower = makeFollower(world)
            let result = await follower.followNow()
            precondition(result == .applied && world.migrateCalls.isEmpty)
        }
        // No key: deferred.
        do {
            let world = World()
            world.key = nil
            let follower = makeFollower(world)
            let result = await follower.followNow()
            precondition(result == .deferred && world.migrateCalls.isEmpty)
        }
        // Busy: followNow does not return the running attempt's result; it is owed an attempt that starts
        // after the call. Here the running attempt fails and the owed one applies, with no retry wait.
        do {
            let world = World()
            world.key = .app
            world.hold = true
            let follower = makeFollower(world)
            follower.trigger()
            await drain()
            let result = Box<PinScopeFollower.AttemptResult>()
            Task { @MainActor in result.value = await follower.followNow() }
            await drain()
            precondition(result.value == nil, "followNow while busy waits for the next attempt")
            world.finish(throwing: OtherError())
            await drain()
            precondition(result.value == nil && world.migrateCalls == [.app, .app] && world.liveTimers.isEmpty,
                         "the owed attempt runs at once, not after the retry delay")
            world.finish()
            await drain()
            precondition(result.value == .applied, "followNow reports its own attempt: \(String(describing: result.value))")
            precondition(follower.failure == nil && !follower.isRunning)
        }
        print("PASS follower followNow: idle returns its first attempt's result, no key is .deferred, busy waits for the next attempt (not the running one)")
    }

    /// PR #191 review finding 3: after a failed attempt the account moves the key back to the row.
    /// No migration is needed, and the failure must end as it would after a successful one.
    @MainActor
    static func failureEndsWhenKeyReturnsToRow() async {
        let world = World()
        world.key = .app
        world.failWith = OtherError()
        let follower = makeFollower(world)
        follower.trigger()
        await drain()
        precondition(follower.failure?.attempts == 1 && world.liveTimers.count == 1 && world.published.last??.attempts == 1)
        // Another device reverts the scope: the landing writes the key back to the row.
        world.key = .profile
        follower.trigger()
        precondition(!follower.isRunning && world.migrateCalls == [.app], "row == key: no job")
        precondition(follower.failure == nil, "failure ends when row == key without a migration")
        precondition(world.published.last == .some(nil), "the status sink sees the failure cleared: \(world.published)")
        precondition(world.liveTimers.isEmpty, "the armed retry is cancelled")
        precondition(!follower.isPending)
        // The backoff restarted: the next failure arms the first delay again, not the doubled one.
        world.key = .app
        follower.trigger()
        await drain()
        precondition(follower.failure?.attempts == 1 && world.liveTimers.count == 1 && world.liveTimers[0].delay == 5,
                     "backoff reset after the key returned to the row: \(world.liveTimers.map(\.delay))")
        print("PASS follower failure ends when the key returns to the row: status cleared, retry cancelled, backoff reset, no migration")
    }

    /// PR #191 review finding 1: the unmounted path's follower runs one attempt. A key that moves while
    /// its migration is suspended (an account switch rewriting the shared key) is not followed into the
    /// store it was built for.
    @MainActor
    static func singleAttemptDoesNotRunAgain() async {
        let world = World()
        world.key = .app
        world.hold = true
        let follower = PinScopeFollower(effects: world.effects, singleAttempt: true)
        let result = Box<PinScopeFollower.AttemptResult>()
        Task { @MainActor in result.value = await follower.followNow() }
        await drain()
        precondition(world.migrateCalls == [.app] && world.heldCount == 1)
        world.key = .space          // The next account's key, written during the wait.
        follower.trigger()          // Any trigger during the run would set run-again on a mounted follower.
        world.finish()
        await drain()
        precondition(result.value == .applied && !follower.isRunning)
        precondition(world.migrateCalls == [.app], "single attempt: the moved key starts no second migration: \(world.migrateCalls)")
        precondition(world.row == .app)
        print("PASS follower single attempt: a key that moves during the attempt starts no second migration")
    }
}

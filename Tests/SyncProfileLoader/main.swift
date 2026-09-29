import Foundation

@MainActor final class Fixture {
    var time: TimeInterval = 0
    /// id -> loaded; order is the list order.
    var list: [(id: String, loaded: Bool, assignable: Bool)] = []
    var mapped: Set<String> = []
    var keyReady: Set<String> = []
    var eligible = true
    var paused = false
    var enumerated = true
    var enabled = true
    /// Completes the load synchronously with this answer; nil leaves it pending.
    var answerAtOnce: Bool?
    var started: [String] = []
    var pending: [(id: String, done: @MainActor (Bool) -> Void)] = []
    var wakes: [TimeInterval] = []
    var refreshes = 0
    /// Chromium unloaded these; the cached list shows it after the next refresh.
    var unloadOnRefresh: Set<String> = []
    var logs: [String] = []
    lazy var loader = SyncProfileLoader(
        profiles: { self.list.map { .init(id: $0.id, isLoaded: $0.loaded, isUserAssignable: $0.assignable) } },
        refreshProfiles: {
            self.refreshes += 1
            for id in self.unloadOnRefresh { self.setLoaded(id, false) }
            self.unloadOnRefresh = []
        },
        hasDeliverableKey: { self.mapped.contains($0) && self.keyReady.contains($0) },
        isEligible: { self.eligible },
        isPaused: { self.paused },
        isProfileListEnumerated: { self.enumerated },
        isEnabled: { self.enabled },
        load: { id, done in
            self.started.append(id)
            guard let answer = self.answerAtOnce else { self.pending.append((id, done)); return }
            if answer { self.setLoaded(id, true) }
            done(answer)
        },
        wake: { self.wakes.append($0) },
        now: { Date(timeIntervalSince1970: self.time) },
        log: { self.logs.append($0) })

    init(_ ids: [String]) {
        list = ids.map { ($0, false, true) }
        mapped = Set(ids)
        keyReady = Set(ids)
    }

    /// The owner's timer firing at `time`.
    func at(_ time: TimeInterval) {
        self.time = time
        loader.evaluate()
    }

    func finish(_ success: Bool, at time: TimeInterval) {
        self.time = time
        let load = pending.removeFirst()
        if success, let index = list.firstIndex(where: { $0.id == load.id }) { list[index].loaded = true }
        load.done(success)
    }

    func setLoaded(_ id: String, _ loaded: Bool) {
        if let index = list.firstIndex(where: { $0.id == id }) { list[index].loaded = loaded }
    }
}

@main struct ProfileLoaderTests {
    @MainActor static func main() {
        selection()
        initialDelay()
        oneAtATimeWithGap()
        reloadAfterUnload()
        syncNowSkipsDelays()
        waitsWhilePausedOrNotEnumerated()
        stopIgnoresLateCompletion()
        failureRetriesWithoutBlocking()
        developerSwitchAndEligibility()
        timeoutMovesOn()
        synchronousCompletion()
    }

    @MainActor static func selection() {
        let f = Fixture(["Default", "Unmapped", "NoKey", "Open", "Agent", "Target"])
        f.mapped.remove("Unmapped")
        f.keyReady.remove("NoKey")
        f.setLoaded("Open", true)
        f.list[4].assignable = false
        f.answerAtOnce = true
        f.loader.syncDidStart()
        for step in stride(from: 30.0, through: 200, by: 5) { f.at(step) }
        precondition(f.started == ["Default", "Target"],
                     "Only user-assignable, mapped, key-ready Profiles that are not loaded: \(f.started)")
        print("PASS profile loader: skips unmapped, key not ready, already loaded and non-assignable Profiles")
    }

    @MainActor static func initialDelay() {
        let f = Fixture(["A"])
        f.at(100)
        precondition(f.started.isEmpty && f.wakes.isEmpty, "Nothing before sync has started")
        f.time = 0
        f.loader.syncDidStart()
        precondition(f.started.isEmpty && f.wakes.last == 30, "First wake at the initial delay")
        f.at(29.9)
        precondition(f.started.isEmpty)
        f.at(30)
        precondition(f.started == ["A"])
        print("PASS profile loader: first load no earlier than the initial delay after sync started")
    }

    @MainActor static func oneAtATimeWithGap() {
        let f = Fixture(["A", "B", "C"])
        f.loader.syncDidStart()
        f.at(30)
        f.at(31)
        precondition(f.started == ["A"], "One load at a time")
        f.finish(true, at: 32)
        precondition(f.started == ["A"] && f.wakes.last == 5, "The gap runs from the end of the previous load")
        f.at(36.9)
        precondition(f.started == ["A"])
        f.at(37)
        precondition(f.started == ["A", "B"])
        f.finish(true, at: 37.2)
        f.at(42.2)
        precondition(f.started == ["A", "B", "C"])
        f.finish(true, at: 42.5)
        f.at(100)
        precondition(f.started.count == 3, "Nothing left to load")
        print("PASS profile loader: one load at a time, waiting for its completion, with a gap")
    }

    @MainActor static func reloadAfterUnload() {
        let f = Fixture(["A"])
        f.loader.syncDidStart()
        f.at(30)
        f.finish(true, at: 30.2)
        f.at(60)
        precondition(f.started == ["A"])
        let refreshesBefore = f.refreshes
        // The last window of A closed; the next list refresh reports it unloaded.
        f.unloadOnRefresh = ["A"]
        f.at(119)
        precondition(f.started == ["A"] && f.refreshes == refreshesBefore,
                     "No refresh before the recheck interval")
        f.at(120)
        precondition(f.refreshes == refreshesBefore + 1, "The periodic recheck refreshes the list")
        precondition(f.started == ["A", "A"], "A Profile reported unloaded again is loaded again")
        // A stale list right after a successful load does not load again at once.
        f.finish(true, at: 120.1)
        f.setLoaded("A", false)
        f.at(125.1)
        precondition(f.started == ["A", "A"], "A recent successful load waits for the recheck")
        print("PASS profile loader: reloads a Profile that a later list refresh reports unloaded")
    }

    @MainActor static func syncNowSkipsDelays() {
        let f = Fixture(["A", "B", "C"])
        f.loader.syncDidStart()
        f.time = 5
        f.loader.loadNow()
        precondition(f.started == ["A"], "Sync now skips the initial delay")
        f.finish(true, at: 5.1)
        precondition(f.started == ["A", "B"], "Sync now skips the gap")
        f.finish(false, at: 5.2)
        precondition(f.started == ["A", "B", "C"], "A failure does not end the Sync now pass")
        f.finish(true, at: 5.3)
        precondition(f.pending.isEmpty && f.started.count == 3, "Each Profile once per Sync now")
        // B is in its retry delay; another Sync now tries it at once.
        f.time = 6
        f.loader.loadNow()
        precondition(f.started == ["A", "B", "C", "B"], "Sync now skips a pending retry delay")
        f.finish(true, at: 6.1)
        precondition(f.started.count == 4)
        print("PASS profile loader: Sync now loads at once, without the initial delay and the gap")
    }

    @MainActor static func waitsWhilePausedOrNotEnumerated() {
        for blocker in ["paused", "enumerated"] {
            let f = Fixture(["A", "B"])
            if blocker == "paused" { f.paused = true } else { f.enumerated = false }
            f.loader.syncDidStart()
            f.at(30)
            f.time = 31
            f.loader.loadNow()
            f.at(200)
            precondition(f.started.isEmpty, "Nothing while \(blocker)")
            precondition(f.wakes.last.map { $0 > 0 } == true, "Keeps rechecking while \(blocker)")
            f.paused = false
            f.enumerated = true
            f.at(201)
            precondition(f.started == ["A"], "Continues when \(blocker) clears")
            f.finish(true, at: 201.1)
            precondition(f.started == ["A"], "The dropped Sync now does not skip the gap afterwards")
            f.at(206.1)
            precondition(f.started == ["A", "B"])
        }
        // A pause that begins while a load is in flight lets it finish and starts nothing more.
        let f = Fixture(["A", "B"])
        f.loader.syncDidStart()
        f.at(30)
        f.paused = true
        f.finish(true, at: 30.5)
        f.at(40)
        precondition(f.started == ["A"])
        f.at(200)
        precondition(f.wakes.last == 60, "A long pause rechecks at the interval, never in a tight loop")
        print("PASS profile loader: nothing while paused or before the list is enumerated, continues afterwards")
    }

    @MainActor static func stopIgnoresLateCompletion() {
        let f = Fixture(["A", "B"])
        f.loader.syncDidStart()
        f.at(30)
        let wakes = f.wakes.count
        f.loader.stop()
        f.finish(true, at: 31)
        f.at(100)
        f.loader.loadNow()
        f.loader.syncDidStart()
        precondition(f.started == ["A"] && f.wakes.count == wakes, "Nothing after stop, late completion ignored")
        print("PASS profile loader: stop ends loading and ignores a late completion")
    }

    @MainActor static func failureRetriesWithoutBlocking() {
        let f = Fixture(["A", "B"])
        f.loader.syncDidStart()
        f.at(30)
        f.finish(false, at: 30.1)
        f.at(35.1)
        precondition(f.started == ["A", "B"], "A failed load does not block the others")
        f.finish(true, at: 35.2)
        f.at(59)
        precondition(f.started == ["A", "B"])
        precondition(f.wakes.last.map { $0 > 0 && $0 <= 1.1 + 0.001 } == true, "Next wake no later than the retry time")
        f.at(60.1)
        precondition(f.started == ["A", "B", "A"], "Retried after the first delay")
        f.finish(false, at: 60.2)
        f.at(119)
        precondition(f.started.count == 3)
        f.at(120.2)
        precondition(f.started == ["A", "B", "A", "A"], "The retry delay doubles")
        f.finish(false, at: 120.3)
        // Opened by the user meanwhile: the failure no longer applies.
        f.setLoaded("A", true)
        f.at(125)
        f.setLoaded("A", false)
        f.at(186)
        precondition(f.started.count == 5, "A Profile seen loaded forgets its failures")
        precondition(!f.logs.isEmpty && f.logs.allSatisfy { !$0.contains("\"A\"") && !$0.contains(" A ") },
                     "Logs carry no Profile identifiers")
        print("PASS profile loader: a failed load is retried with a growing delay and blocks no other Profile")
    }

    @MainActor static func developerSwitchAndEligibility() {
        let f = Fixture(["A"])
        f.enabled = false
        f.loader.syncDidStart()
        f.at(30)
        f.at(90)
        precondition(f.started.isEmpty, "The developer switch turns loading off")
        f.enabled = true
        f.eligible = false
        f.at(150)
        precondition(f.started.isEmpty, "Nothing while ineligible (not enrolled, locked or signed out)")
        f.eligible = true
        f.at(151)
        precondition(f.started == ["A"])
        print("PASS profile loader: developer switch and eligibility")
    }

    @MainActor static func timeoutMovesOn() {
        let f = Fixture(["A", "B"])
        f.loader.syncDidStart()
        f.at(30)
        precondition(f.wakes.last == 60, "A wake at the load timeout")
        f.at(89)
        precondition(f.started == ["A"])
        f.at(90)
        precondition(f.started == ["A"], "The timed-out load counts as ended, then the gap")
        f.at(95)
        precondition(f.started == ["A", "B"])
        // The first request answers late.
        let late = f.pending.removeFirst()
        late.done(true)
        precondition(f.started == ["A", "B"] && f.pending.count == 1, "A late completion is ignored")
        f.finish(true, at: 95.5)
        f.at(100.5)
        precondition(f.started == ["A", "B"], "A is in its retry delay")
        f.at(120)
        precondition(f.started == ["A", "B", "A"])
        print("PASS profile loader: a load that never completes times out and the others go on")
    }

    @MainActor static func synchronousCompletion() {
        let f = Fixture(["A", "B"])
        f.answerAtOnce = true
        f.loader.syncDidStart()
        f.at(30)
        precondition(f.started == ["A"], "A synchronous completion does not start the next load inside the gap")
        f.at(35)
        precondition(f.started == ["A", "B"])
        print("PASS profile loader: a synchronous completion is handled once")
    }
}

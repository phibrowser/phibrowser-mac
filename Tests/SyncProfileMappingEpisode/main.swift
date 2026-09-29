import Foundation

final class Handle {}

@MainActor final class Timer {
    let at: TimeInterval
    let fire: @MainActor () -> Void
    var cancelled = false
    var fired = false
    init(at: TimeInterval, fire: @escaping @MainActor () -> Void) { self.at = at; self.fire = fire }
}

@MainActor final class Fixture {
    typealias Reconciler = SyncProfileMappingPauseReconciler
    var time: TimeInterval = 0
    var engine: Handle? = Handle()
    var controller: Handle? = Handle()
    var paired = true
    var unlocked = true
    var retired = false
    /// `nativeSyncRequiresReconfiguration`: a prerequisite, and read again when a pass falls due.
    var reconfiguring = false
    /// Forbids a pass without touching the prerequisites, to observe the skipped pass alone.
    var repairBlocked = false
    var enumerated = true
    var syncable = ["Default"]
    var mappings = ["Default": "u-default"]
    var known: Set<String> = []
    var creating: Set<String> = []
    var passResult: SyncProfileMappingPassResult?
    var category: SyncProfileMappingFailureCategory?

    var gate = false
    var gateCalls: [Bool] = []
    var keysWithdrawn = false
    var keyCalls: [Bool] = []
    var notifications = 0
    var status: SyncProfileMappingPauseStatus = .none
    var statusCalls: [SyncProfileMappingPauseStatus] = []
    var resumes = 0
    /// Repair passes started, with the time each started.
    var passes: [TimeInterval] = []
    /// Completes a pass at once when set; otherwise the completion waits in `pendingPasses`.
    var passAtOnce: (@MainActor () -> Void)?
    var pendingPasses: [@MainActor () -> Void] = []
    var listReads = 0
    /// What a list read finds: enumerates the list when true.
    var listReadSucceeds = false
    var timers: [Timer] = []
    var logs: [String] = []
    /// Every effect, in order, to prove idempotence and ordering.
    var effects: [String] = []

    lazy var reconciler: Reconciler = Reconciler(effects: Reconciler.Effects(
        setEngineGate: { self.gate = $0; self.gateCalls.append($0); self.effects.append("gate \($0)") },
        setKeysWithdrawn: { self.keysWithdrawn = $0; self.keyCalls.append($0); self.effects.append("keys \($0)") },
        notifyKeysChanged: {
            // The bridge reads the committed state when notified.
            precondition((self.reconciler.applied.keysWithdrawnController != nil) == self.keysWithdrawn,
                         "The bridge was notified before the state was committed")
            self.notifications += 1; self.effects.append("notify")
        },
        publishStatus: { self.status = $0; self.statusCalls.append($0); self.effects.append("status") },
        resume: { self.resumes += 1; self.effects.append("resume") },
        runRepairPass: { done in
            self.passes.append(self.time)
            self.effects.append("pass")
            if let passAtOnce = self.passAtOnce { passAtOnce(); done() } else { self.pendingPasses.append(done) }
        },
        canRunRepairPass: { !self.reconfiguring && !self.repairBlocked },
        refreshProfileList: {
            self.listReads += 1
            if self.listReadSucceeds { self.enumerated = true; self.reconcile() }
        },
        reconcileNow: { self.reconcile() },
        schedule: { delay, fire in
            let timer = Timer(at: self.time + delay, fire: fire)
            self.timers.append(timer)
            return { timer.cancelled = true }
        },
        now: { Date(timeIntervalSince1970: self.time) },
        log: { self.logs.append($0) }))

    var armed: [Timer] { timers.filter { !$0.cancelled && !$0.fired } }

    func inputs() -> Reconciler.Inputs {
        let prerequisites = engine != nil && controller != nil && paired && unlocked && !retired && !reconfiguring
        var pause = SyncProfileMappingPause.notPaused
        if prerequisites, enumerated {
            pause = .evaluate(syncableProfileIds: syncable, persistedMappings: mappings,
                              knownUnmappedProfileIds: known, profileIdsBeingCreated: creating,
                              lastPassResult: passResult)
        }
        return .init(engine: engine.map(ObjectIdentifier.init), controller: controller.map(ObjectIdentifier.init),
                     prerequisitesMet: prerequisites, isProfileListEnumerated: enumerated,
                     pause: pause, failureCategory: category)
    }

    func reconcile() { reconciler.reconcile(inputs()) }

    /// Moves the clock, firing every armed timer that falls due on the way, in order.
    func advance(to target: TimeInterval) {
        while let next = armed.filter({ $0.at <= target }).min(by: { $0.at < $1.at }) {
            time = max(time, next.at)
            next.fired = true
            next.fire()
        }
        time = target
    }

    func finishPass() { pendingPasses.removeFirst()() }

    /// A new unmapped local Profile.
    func addProfile(_ id: String) { syncable.append(id) }
    func map(_ id: String) { mappings[id] = "u-\(id)"; known.remove(id) }
}

@main struct ProfileMappingEpisodeTests {
    @MainActor static func main() {
        pureRulesOverEveryInput()
        idempotentAndOrderIndependent()
        shortEpisodeWithdrawsNothing()
        longEpisodeWithdrawsOnceAndRestoresOnce()
        secondProfileDoesNotRestartTheDelay()
        repairLoopBackoffRetryAndEnd()
        startupWaitsForEnumeration()
        profileListFollowUp()
        teardownDuringEpisode()
        profileBeingCreatedByTheKeyLayer()
        deviceWithoutEpisodeDoesNothing()
        reconfigurationStopsTheEpisode()
    }

    /// Review R1: an account reset by another device keeps enrollment and the key, but no
    /// episode may run a repair pass for it.
    @MainActor static func reconfigurationStopsTheEpisode() {
        // No episode while reconfiguration is required.
        let f = Fixture()
        f.reconfiguring = true
        f.addProfile("New")
        f.reconcile()
        precondition(f.reconciler.episode == nil && f.passes.isEmpty && f.armed.isEmpty && !f.gate,
                     "An episode started while this Mac requires reconfiguration")

        // An episode that exists when the flag becomes set ends at the next reconciliation.
        let g = Fixture()
        g.passAtOnce = {}
        g.addProfile("New")
        g.reconcile()
        g.advance(to: 20)
        precondition(g.keysWithdrawn && !g.armed.isEmpty)
        g.reconfiguring = true
        g.reconcile()
        precondition(g.reconciler.episode == nil && g.armed.isEmpty && !g.keysWithdrawn,
                     "The episode outlived the reconfiguration state or kept a timer")

        // A pass that falls due while the flag is set (the engine set it without a
        // reconciliation) does nothing, and the episode ends there.
        let h = Fixture()
        h.passAtOnce = {}
        h.addProfile("New")
        h.reconcile()
        precondition(h.passes == [0] && h.armed.contains { $0.at == 5 })
        h.reconfiguring = true
        h.advance(to: 5)
        precondition(h.passes == [0], "A repair pass ran while reconfiguration is required")
        precondition(h.reconciler.episode == nil && h.armed.isEmpty, "The skipped pass did not end the episode")

        // A skipped pass is not a failure: the next wait keeps the delay.
        let k = Fixture()
        k.passAtOnce = {}
        k.addProfile("New")
        k.reconcile()
        k.advance(to: 15.5)  // passes at 0, 5 and 15; the next is due at 35, then 40 s later
        k.repairBlocked = true
        k.advance(to: 76)     // skipped at 35 and at 75
        precondition(k.passes == [0, 5, 15] && k.reconciler.episode != nil)
        precondition(k.armed.contains { $0.at == 115 }, "A skipped pass lengthened the backoff: \(k.armed.map(\.at))")
        k.repairBlocked = false
        k.advance(to: 115)
        precondition(k.passes == [0, 5, 15, 115] && k.armed.contains { $0.at == 155 },
                     "The first pass after the skips waits the delay it would have waited")
        print("PASS profile mapping episode: no episode and no repair pass while this Mac requires reconfiguration")
    }

    /// 10.2 steps 1 to 4 as pure functions, over every combination of the inputs they
    /// distinguish and every episode age.
    @MainActor static func pureRulesOverEveryInput() {
        typealias R = SyncProfileMappingPauseReconciler
        let engine = ObjectIdentifier(Handle()), controller = ObjectIdentifier(Handle())
        let start = Date(timeIntervalSince1970: 100)
        let paused = SyncProfileMappingPause.evaluate(syncableProfileIds: ["New"], persistedMappings: [:],
                                                      knownUnmappedProfileIds: [], profileIdsBeingCreated: [],
                                                      lastPassResult: .heldTransient)
        var cases = 0
        for hasEngine in [false, true] {
            for hasController in [false, true] {
                for prerequisites in [false, true] {
                    for enumerated in [false, true] {
                        for isPaused in [false, true] {
                            for existing in [nil, R.Episode(id: 7, startedAt: start)] {
                                for age in [0.0, 14.9, 15.0, 600.0] {
                                    cases += 1
                                    let inputs = R.Inputs(engine: hasEngine ? engine : nil,
                                                          controller: hasController ? controller : nil,
                                                          prerequisitesMet: prerequisites,
                                                          isProfileListEnumerated: enumerated,
                                                          pause: isPaused ? paused : .notPaused,
                                                          failureCategory: .offline)
                                    let now = start.addingTimeInterval(age)
                                    let episode = R.nextEpisode(existing, inputs: inputs, now: now, nextId: 8)
                                    let episodeWanted = prerequisites && hasEngine && hasController && enumerated && isPaused
                                    precondition((episode != nil) == episodeWanted, "Episode rule, case \(cases)")
                                    if let episode {
                                        precondition(episode == (existing ?? R.Episode(id: 8, startedAt: now)),
                                                     "A running episode keeps its identity and start")
                                    }
                                    let outputs = R.desiredOutputs(inputs: inputs, episode: episode, now: now,
                                                                   statusDelay: 15)
                                    let gateWanted = hasEngine && (!enumerated || episode != nil)
                                    precondition((outputs.gateEngine != nil) == gateWanted, "Gate rule, case \(cases)")
                                    let aged = episode.map { now.timeIntervalSince($0.startedAt) >= 15 } ?? false
                                    precondition((outputs.keysWithdrawnController != nil) == aged, "Key rule, case \(cases)")
                                    switch outputs.status {
                                    case .none: precondition(episode == nil)
                                    case .grace: precondition(episode != nil && !aged)
                                    case .paused(let reason, let category, let ids):
                                        precondition(aged && reason == .retrying && category == .offline && ids == ["New"])
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        print("PASS profile mapping episode: episode, gate, keys and status rules over \(cases) input combinations")
    }

    /// Applying the reconciliation twice changes nothing, and the order in which the
    /// triggers deliver the same final inputs does not change the outcome.
    @MainActor static func idempotentAndOrderIndependent() {
        let f = Fixture()
        f.addProfile("New")
        f.reconcile()
        let effects = f.effects, applied = f.reconciler.applied, episode = f.reconciler.episode
        f.reconcile()
        f.reconcile()
        let unchanged = f.reconciler.applied == applied && f.reconciler.episode == episode
        precondition(f.effects == effects && unchanged, "A second reconciliation of the same inputs applied something")
        f.advance(to: 20)
        let aged = f.effects
        f.reconcile()
        precondition(f.effects == aged, "A second reconciliation after the mark applied something")

        // Three triggers set three inputs (a mapping appears, a pass result arrives, the known
        // evidence clears); every order lands in the same state with one resume.
        let changes: [(Fixture) -> Void] = [
            { $0.mappings["New"] = "u-new" },
            { $0.passResult = .measured },
            { $0.known = [] },
        ]
        var outcomes: [String] = []
        for order in [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]] {
            let g = Fixture()
            g.addProfile("New"); g.known = ["New"]
            g.reconcile()
            g.advance(to: 30)
            for index in order { changes[index](g); g.reconcile() }
            precondition(g.reconciler.episode == nil && !g.gate && !g.keysWithdrawn && g.status == .none
                         && g.resumes == 1 && g.keyCalls == [true, false] && g.armed.isEmpty,
                         "Order \(order) ended differently")
            outcomes.append("\(g.reconciler.applied) \(g.resumes) \(g.notifications)")
        }
        precondition(Set(outcomes).count == 1)
        print("PASS profile mapping episode: idempotent, and the order of the triggers does not matter")
    }

    /// An episode that ends inside 15 seconds never withdraws keys and never shows the pause.
    @MainActor static func shortEpisodeWithdrawsNothing() {
        let f = Fixture()
        f.addProfile("New")
        f.time = 100
        f.reconcile()
        precondition(f.gate && f.gateCalls == [true] && f.status == .grace && f.passes == [100])
        precondition(f.effects == ["pass", "gate true", "status"], "Order: the loop starts, then the gate, then the helper")
        f.advance(to: 110)
        f.map("New")
        f.reconcile()
        precondition(f.reconciler.episode == nil && !f.gate && f.gateCalls == [true, false])
        precondition(f.keyCalls.isEmpty && f.notifications == 0, "Keys were withdrawn inside the first 15 seconds")
        precondition(f.statusCalls == [.grace, .none], "A reason was published inside the first 15 seconds")
        precondition(f.resumes == 1 && f.effects.last == "resume", "Resume runs once, after the gate is off")
        f.advance(to: 200)
        precondition(f.armed.isEmpty && f.keyCalls.isEmpty, "The 15-second mark outlived the episode")
        print("PASS profile mapping episode: an episode under 15 seconds withdraws no key and shows nothing")
    }

    /// An episode longer than 15 seconds withdraws the keys once and restores them once;
    /// the reason follows the pass result while shown.
    @MainActor static func longEpisodeWithdrawsOnceAndRestoresOnce() {
        let f = Fixture()
        f.addProfile("New")
        f.reconcile()
        f.advance(to: 14.9)
        precondition(f.keyCalls.isEmpty && f.status == .grace)
        f.advance(to: 15)
        precondition(f.keyCalls == [true] && f.notifications == 1 && f.keysWithdrawn)
        precondition(f.status == .paused(reason: .registering, failureCategory: nil, unmappedProfileIds: ["New"]))
        f.passResult = .heldTransient; f.category = .offline
        f.reconcile()
        precondition(f.status == .paused(reason: .retrying, failureCategory: .offline, unmappedProfileIds: ["New"])
                     && f.keyCalls == [true] && f.notifications == 1, "A new reason re-published the keys")
        f.advance(to: 400)
        precondition(f.keyCalls == [true], "The keys were withdrawn twice")
        f.map("New"); f.passResult = .measured; f.category = nil
        f.reconcile()
        precondition(f.keyCalls == [true, false] && f.notifications == 2 && !f.keysWithdrawn)
        precondition(f.status == .none && f.resumes == 1 && !f.gate)
        let order = f.effects.suffix(5)
        precondition(Array(order) == ["gate false", "keys false", "notify", "status", "resume"], "Resume order: \(order)")
        print("PASS profile mapping episode: a long episode withdraws once at 15 seconds and restores once at its end")
    }

    @MainActor static func secondProfileDoesNotRestartTheDelay() {
        let f = Fixture()
        f.addProfile("A")
        f.reconcile()
        let episode = f.reconciler.episode
        f.advance(to: 10)
        f.addProfile("B")
        f.reconcile()
        precondition(f.reconciler.episode == episode && f.passes == [0], "A second unmapped Profile started a new episode")
        f.advance(to: 15)
        precondition(f.keyCalls == [true], "The second Profile moved the 15-second mark")
        precondition(f.status == .paused(reason: .registering, failureCategory: nil, unmappedProfileIds: ["A", "B"]))
        f.map("A"); f.reconcile()
        precondition(f.reconciler.episode == episode && f.keyCalls == [true])
        f.map("B"); f.reconcile()
        precondition(f.reconciler.episode == nil && f.keyCalls == [true, false] && f.resumes == 1)
        print("PASS profile mapping episode: a second unmapped Profile does not restart the 15 seconds")
    }

    @MainActor static func repairLoopBackoffRetryAndEnd() {
        let f = Fixture()
        f.passAtOnce = {}
        f.addProfile("New")
        f.reconcile()
        f.advance(to: 1000)
        let waits = zip(f.passes.dropFirst(), f.passes).map { $0 - $1 }
        precondition(Array(waits.prefix(8)) == [5, 10, 20, 40, 80, 160, 300, 300], "Backoff: \(waits)")
        // Retry: an immediate pass, then the first delay again.
        let before = f.passes.count
        f.reconciler.kickRepair()
        precondition(f.passes.count == before + 1 && f.passes.last == 1000)
        f.advance(to: 1005)
        precondition(f.passes.last == 1005 && f.armed.filter { $0.at == 1015 }.count == 1, "Retry did not reset the delay")
        // A kick while a pass runs: one more pass right after it, not two beside it.
        f.passAtOnce = nil
        f.reconciler.kickRepair()
        f.reconciler.kickRepair()
        precondition(f.pendingPasses.count == 1)
        f.finishPass()
        precondition(f.pendingPasses.count == 1, "The kick during a pass did not run once after it")
        f.finishPass()
        precondition(f.pendingPasses.isEmpty && f.armed.contains { $0.at == 1010 })
        // The end of the episode stops the loop; a late completion changes nothing.
        f.reconciler.kickRepair()
        f.map("New"); f.reconcile()
        precondition(f.armed.isEmpty, "A repair wait outlived the episode")
        let count = f.passes.count
        f.finishPass()
        f.advance(to: 5000)
        f.reconciler.kickRepair()
        precondition(f.passes.count == count && f.armed.isEmpty, "The loop ran outside an episode")
        print("PASS profile mapping episode: repair loop backs off 5 s to 5 min, Retry resets it, the episode end stops it")
    }

    /// AM-1: no round is admitted before the list is enumerated; a first enumeration with
    /// nothing unmapped opens the gate once, with one resume and no episode.
    @MainActor static func startupWaitsForEnumeration() {
        let f = Fixture()
        f.enumerated = false
        f.reconcile()
        precondition(f.gate && f.reconciler.episode == nil && f.resumes == 0 && f.keyCalls.isEmpty
                     && f.statusCalls.isEmpty && f.passes.isEmpty, "Before enumeration: gate only")
        f.addProfile("Unread")
        f.reconcile()
        precondition(f.reconciler.episode == nil, "An episode started before the list was enumerated")
        f.syncable = ["Default"]
        // The list read retries with the repair loop's delays while it fails.
        f.advance(to: 40)
        precondition(f.listReads == 3 && f.armed.map(\.at) == [75], "List retry delays: \(f.armed.map(\.at))")
        f.listReadSucceeds = true
        f.advance(to: 75)
        precondition(f.enumerated && !f.gate && f.gateCalls == [true, false] && f.resumes == 1)
        precondition(f.armed.isEmpty && f.reconciler.episode == nil && f.passes.isEmpty && f.keyCalls.isEmpty,
                     "The first enumeration with nothing unmapped did more than open the gate")
        f.reconcile(); f.reconcile()
        precondition(f.resumes == 1, "A catch-up storm after the first enumeration")

        // Enumerated with an unmapped Profile: the gate stays on and the episode starts.
        let g = Fixture()
        g.enumerated = false
        g.reconcile()
        g.addProfile("New"); g.enumerated = true
        g.reconcile()
        precondition(g.gate && g.gateCalls == [true] && g.resumes == 0 && g.reconciler.episode != nil)
        precondition(g.armed.count == 1, "Only the 15-second mark is armed; the list retry ended")

        // A new engine before enumeration gets its own gate.
        let h = Fixture()
        h.enumerated = false
        h.reconcile()
        h.engine = Handle()
        h.reconcile()
        precondition(h.gateCalls == [true, true] && h.resumes == 0, "A rebuilt engine started ungated")
        print("PASS profile mapping episode: no round before enumeration, one resume after it, no episode before it")
    }

    /// AM-4: the Profile-list sink's follow-up.
    @MainActor static func profileListFollowUp() {
        typealias R = SyncProfileMappingPauseReconciler
        precondition(R.profileListFollowUp(hadEpisode: false, hasEpisode: false, isUnlocked: true) == .silentUnlockAndResolve)
        precondition(R.profileListFollowUp(hadEpisode: false, hasEpisode: false, isUnlocked: false) == .silentUnlockAndResolve)
        precondition(R.profileListFollowUp(hadEpisode: true, hasEpisode: false, isUnlocked: true) == .silentUnlockAndResolve)
        precondition(R.profileListFollowUp(hadEpisode: true, hasEpisode: true, isUnlocked: false) == .silentUnlockAndResolve)
        precondition(R.profileListFollowUp(hadEpisode: false, hasEpisode: true, isUnlocked: true) == .nothing)
        precondition(R.profileListFollowUp(hadEpisode: true, hasEpisode: true, isUnlocked: true) == .repairPass)
        print("PASS profile mapping episode: the repair pass replaces the silent unlock in the list sink only during an episode")
    }

    /// 10.8: sign-out, account switch and retirement end the episode and clear every output.
    @MainActor static func teardownDuringEpisode() {
        for variant in 0..<3 {
            let f = Fixture()
            f.passAtOnce = {}
            f.addProfile("New")
            f.reconcile()
            f.advance(to: 20)
            precondition(f.keysWithdrawn && f.armed.count == 1, "The repair wait is armed")
            switch variant {
            case 0: // `stopPhiSync()`: the engine and helper are gone, the controller not yet.
                f.engine = nil
            case 1: f.retired = true
            default: f.unlocked = false
            }
            f.reconcile()
            precondition(f.reconciler.episode == nil && f.armed.isEmpty, "Teardown \(variant) left a timer")
            precondition(!f.keysWithdrawn && f.notifications == 2, "Teardown \(variant) left the keys withdrawn")
            if variant == 0 {
                precondition(f.gateCalls == [true] && f.resumes == 0 && f.statusCalls.last != SyncProfileMappingPauseStatus.none,
                             "A gone engine and helper are not touched and nothing resumes")
            } else {
                precondition(!f.gate && f.status == .none, "Outputs stayed set without prerequisites")
            }
            let settled = f.effects.count
            f.controller = nil; f.engine = nil
            f.reconcile()
            f.advance(to: 10_000)
            precondition(f.armed.isEmpty && f.effects.count == settled, "Teardown \(variant) kept working")
        }
        print("PASS profile mapping episode: teardown during an episode ends it, clears its outputs and leaves no timer")
    }

    /// 10.4: a Profile the key layer creates may start an episode before its adopt; it ends
    /// when the adopt ends, and nothing shows inside 15 seconds.
    @MainActor static func profileBeingCreatedByTheKeyLayer() {
        let f = Fixture()
        f.addProfile("Created")
        f.reconcile()  // the list sink sees it before the key layer names it
        precondition(f.reconciler.episode != nil)
        f.creating = ["Created"]
        f.reconcile()
        precondition(f.reconciler.episode == nil && f.keyCalls.isEmpty && f.statusCalls == [.grace, .none])
        f.creating = []; f.map("Created")
        f.reconcile()
        precondition(f.reconciler.episode == nil && f.gateCalls == [true, false])
        print("PASS profile mapping episode: a Profile the key layer creates ends its episode with its adopt")
    }

    /// I7: a device on which the predicate stays clear sees nothing of this feature.
    @MainActor static func deviceWithoutEpisodeDoesNothing() {
        let f = Fixture()
        f.syncable = ["Default", "Work"]; f.mappings["Work"] = "u-work"
        for second in stride(from: 0.0, through: 600, by: 7) {
            f.time = second
            f.reconcile()
            f.reconciler.kickRepair()
            if second == 301 { f.engine = Handle(); f.controller = Handle() }
        }
        f.passResult = .heldTransient; f.category = .offline
        f.reconcile()
        precondition(f.timers.isEmpty && f.effects.isEmpty && f.logs.isEmpty && f.listReads == 0,
                     "A device with no episode registered a timer or applied something: \(f.effects)")
        print("PASS profile mapping episode: a device with no episode registers no timer and applies nothing")
    }
}

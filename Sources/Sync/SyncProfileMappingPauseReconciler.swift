import Foundation

/// The episode of the pause while a local Profile is not mapped to an account Profile, and
/// the one reconciliation that derives every output of that pause from the current inputs
/// (plan 2026-09-29, section 10; docs/sync.md, "Enrollment and setup"). Decisions only:
/// `PhiChromiumCoordinator` owns the one instance, computes the inputs and supplies the
/// effects and a timer, which is what lets `build-scripts/test-sync-profile-mapping-episode.sh`
/// run it hostless.
///
/// State is the episode and the outputs last applied (10.1); everything else is derived.
/// `reconcile(_:)` is idempotent: it computes the episode (step 3) and the desired outputs
/// (step 4) from the inputs and the clock, commits both, and only then applies the
/// difference (step 5), so a bridge callback made while the difference is applied already
/// reads the new state. Outputs are bound to the object they were applied to: a new engine
/// starts with its gate off, a new helper with no pause, a new key controller with its keys
/// delivered, so an output applied to an object that is gone is forgotten, not cleared.
///
/// Timers exist only while they have work: the 15-second mark and the repair loop's wait
/// while an episode exists, and the Profile list retry while an engine exists and the list
/// has not been enumerated (AM-1). The episode ending cancels the first two; the list
/// being enumerated, or the engine going, cancels the third.
@MainActor
final class SyncProfileMappingPauseReconciler {
    struct Inputs: Equatable {
        /// The current engine, which the helper is built and retired with; nil without one.
        var engine: ObjectIdentifier?
        /// The current key controller; nil without one.
        var controller: ObjectIdentifier?
        /// Step 1: enrollment complete, account key unlocked, engine present, controller not
        /// retired, and the account not reset by another device (this Mac does not require
        /// reconfiguration).
        var prerequisitesMet: Bool
        /// AM-1: `ProfileManager.isProfileListEnumerated`.
        var isProfileListEnumerated: Bool
        /// Step 2, evaluated on the Profile list the trigger passed. `.notPaused` whenever
        /// the prerequisites are missing or the list has not been enumerated.
        var pause: SyncProfileMappingPause
        /// The key layer's status-only category of the latest mapping failure.
        var failureCategory: SyncProfileMappingFailureCategory?
    }

    struct Episode: Equatable {
        let id: UInt64
        let startedAt: Date
    }

    /// The outputs of the pause, each with the object it applies to.
    struct Outputs: Equatable {
        /// The engine whose gate is on.
        var gateEngine: ObjectIdentifier?
        /// The controller whose Chromium keys are withdrawn.
        var keysWithdrawnController: ObjectIdentifier?
        /// What the helper built with `statusEngine` has been handed.
        var status: SyncProfileMappingPauseStatus = .none
        var statusEngine: ObjectIdentifier?
    }

    struct Timing {
        /// Keys are withdrawn and the pause is shown once an episode is this old (R2, R3).
        var statusDelay: TimeInterval = 15
        /// The repair loop's first wait, doubling up to `maximumRetryDelay` (10.5); the
        /// Profile list retry of AM-1 uses the same delays.
        var firstRetryDelay: TimeInterval = 5
        var maximumRetryDelay: TimeInterval = 300
    }

    /// What the owner does for the reconciliation. Each acts on the current object only.
    struct Effects {
        var setEngineGate: @MainActor (Bool) -> Void
        /// Sets `SyncKeyController.chromiumKeysWithdrawn`; the bridge is notified separately.
        var setKeysWithdrawn: @MainActor (Bool) -> Void
        var notifyKeysChanged: @MainActor () -> Void
        var publishStatus: @MainActor (SyncProfileMappingPauseStatus) -> Void
        /// The gate went from on to off on the current engine: catch-up, retention sweep,
        /// Profile loader (plan implementation notes, "P4 must call", item 3).
        var resume: @MainActor () -> Void
        /// `SyncKeyController.runMappingRepairPass()`; calls the completion when it returns.
        var runRepairPass: @MainActor (@escaping @MainActor () -> Void) -> Void
        /// Read right before every pass: false while this Mac requires reconfiguration. The
        /// engine sets that state without telling the owner, so the prerequisites of the last
        /// reconciliation cannot be relied on when a pass falls due.
        var canRunRepairPass: @MainActor () -> Bool = { true }
        /// AM-1: reads the Profile list again; a successful read publishes it.
        var refreshProfileList: @MainActor () -> Void
        /// Computes the inputs from the current state and calls `reconcile(_:)`.
        var reconcileNow: @MainActor () -> Void
        /// Calls the closure after the delay unless the returned cancel runs first.
        var schedule: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> (@MainActor () -> Void)
        var now: () -> Date = Date.init
        var log: @MainActor (String) -> Void = { _ in }
    }

    private struct RepairLoop {
        let episode: UInt64
        var delay: TimeInterval
        var running = false
        /// A kick arrived while a pass was running: one more pass right after it.
        var again = false
        var cancelWait: (@MainActor () -> Void)?
    }

    private(set) var episode: Episode?
    private(set) var applied = Outputs()
    private var lastEpisodeId: UInt64 = 0
    private var cancelStatusTimer: (@MainActor () -> Void)?
    private var repairLoop: RepairLoop?
    private var listRetryDelay: TimeInterval?
    private var cancelListRetry: (@MainActor () -> Void)?
    private var reconciling = false
    private var pendingInputs: Inputs?

    private let effects: Effects
    private let timing: Timing

    init(effects: Effects, timing: Timing = Timing()) {
        self.effects = effects
        self.timing = timing
    }

    /// Whether any timer of this type is armed; the harness proves teardown leaves none.
    var hasArmedTimer: Bool {
        cancelStatusTimer != nil || repairLoop?.cancelWait != nil || cancelListRetry != nil
    }

    /// Step 3, pure: an episode exists exactly while the prerequisites hold, the list has
    /// been enumerated and the predicate pauses. A running episode keeps its start.
    nonisolated static func nextEpisode(_ current: Episode?, inputs: Inputs, now: Date,
                                        nextId: UInt64) -> Episode? {
        guard inputs.prerequisitesMet, inputs.engine != nil, inputs.controller != nil,
              inputs.isProfileListEnumerated, inputs.pause.isPaused else { return nil }
        return current ?? Episode(id: nextId, startedAt: now)
    }

    /// Step 4, pure: the gate is on while the list has not been enumerated (AM-1) or an
    /// episode exists; keys are withdrawn and the pause is shown once the episode is
    /// `statusDelay` old; before that the helper is in its grace.
    nonisolated static func desiredOutputs(inputs: Inputs, episode: Episode?, now: Date,
                                           statusDelay: TimeInterval) -> Outputs {
        var outputs = Outputs()
        guard let engine = inputs.engine else { return outputs }
        if !inputs.isProfileListEnumerated || episode != nil { outputs.gateEngine = engine }
        guard let episode else { return outputs }
        outputs.statusEngine = engine
        guard now.timeIntervalSince(episode.startedAt) >= statusDelay else {
            outputs.status = .grace
            return outputs
        }
        outputs.keysWithdrawnController = inputs.controller
        outputs.status = .paused(reason: inputs.pause.reason ?? .registering,
                                 failureCategory: inputs.failureCategory,
                                 unmappedProfileIds: inputs.pause.unmappedProfileIds)
        return outputs
    }

    /// The one reconciliation (10.2). Reentrant calls, from an effect that publishes the
    /// Profile list or posts a mapping announcement, run after the current one with the
    /// latest inputs.
    func reconcile(_ inputs: Inputs) {
        guard !reconciling else { pendingInputs = inputs; return }
        reconciling = true
        defer { reconciling = false }
        var next: Inputs? = inputs
        while let current = next {
            pendingInputs = nil
            step(current)
            next = pendingInputs
        }
    }

    /// What the Profile-list sink runs after it has reconciled (10.5, AM-4).
    enum ProfileListFollowUp: Equatable {
        /// The startup path, unchanged for a device with no episode.
        case silentUnlockAndResolve
        /// An immediate pass of the running episode's repair loop.
        case repairPass
        /// The episode this change started runs its first repair pass already.
        case nothing
    }

    /// AM-4: the repair pass replaces `silentUnlockAndResolve()` only while an episode exists
    /// and the account key is unlocked, so a failed device-envelope lookup no longer clears
    /// the key cache during an episode. Everywhere else the sink does what it did before.
    nonisolated static func profileListFollowUp(hadEpisode: Bool, hasEpisode: Bool,
                                                isUnlocked: Bool) -> ProfileListFollowUp {
        guard hasEpisode, isUnlocked else { return .silentUnlockAndResolve }
        return hadEpisode ? .repairPass : .nothing
    }

    /// Foreground, wake, unlock and the pane's Retry (10.5): an immediate repair pass and
    /// the first delay again, only while an episode exists. Outside one it does nothing.
    func kickRepair() {
        guard var loop = repairLoop else { return }
        loop.delay = timing.firstRetryDelay
        if loop.running {
            loop.again = true
            repairLoop = loop
            return
        }
        repairLoop = loop
        runRepair()
    }

    private func step(_ inputs: Inputs) {
        let time = effects.now()
        let previous = episode
        let current = Self.nextEpisode(previous, inputs: inputs, now: time, nextId: lastEpisodeId + 1)
        let desired = Self.desiredOutputs(inputs: inputs, episode: current, now: time,
                                          statusDelay: timing.statusDelay)
        let old = applied
        // Committed before any effect runs (10.10, "Notifying the bridge").
        episode = current
        applied = desired
        if let current, current.id != previous?.id { lastEpisodeId = current.id }

        if previous?.id != current?.id {
            if let previous { endEpisode(previous, at: time) }
            if let current { beginEpisode(current, unmapped: inputs.pause.unmappedProfileIds.count) }
        }
        if let current, desired.status == .grace, cancelStatusTimer == nil {
            // One timer for the episode's 15-second mark, armed again only if the clock
            // it fired on ran ahead of `now`.
            let remaining = max(0, timing.statusDelay - time.timeIntervalSince(current.startedAt))
            let id = current.id
            cancelStatusTimer = effects.schedule(remaining) { [weak self] in
                guard let self, self.episode?.id == id else { return }
                self.cancelStatusTimer = nil
                self.effects.reconcileNow()
            }
        }
        updateListRetry(inputs)
        apply(old: old, desired: desired, inputs: inputs)
    }

    private func beginEpisode(_ episode: Episode, unmapped: Int) {
        effects.log("profile mapping pause: episode started; unmapped=\(unmapped)")
        repairLoop = RepairLoop(episode: episode.id, delay: timing.firstRetryDelay)
        runRepair()
    }

    private func endEpisode(_ episode: Episode, at time: Date) {
        effects.log("profile mapping pause: episode ended after \(Int(time.timeIntervalSince(episode.startedAt))) s")
        cancelStatusTimer?()
        cancelStatusTimer = nil
        // A pass in flight completes in the key layer; its completion finds no loop.
        repairLoop?.cancelWait?()
        repairLoop = nil
    }

    private func runRepair() {
        guard var loop = repairLoop, !loop.running else { return }
        loop.cancelWait?()
        loop.cancelWait = nil
        loop.again = false
        let id = loop.episode
        guard effects.canRunRepairPass() else {
            // No pass and no network work. Not a failure either: the delay does not grow.
            // The state that forbids the pass is a missing prerequisite, so reconciling now
            // ends the episode; the wait below only matters if it does not.
            repairLoop = loop
            effects.log("profile mapping pause: repair pass skipped; reconfiguration required")
            effects.reconcileNow()
            guard repairLoop?.episode == id, repairLoop?.running == false else { return }
            armRepairWait(episode: id, delay: loop.delay)
            return
        }
        loop.running = true
        repairLoop = loop
        effects.runRepairPass { [weak self] in self?.repairPassEnded(episode: id) }
    }

    private func armRepairWait(episode id: UInt64, delay: TimeInterval) {
        repairLoop?.cancelWait?()
        repairLoop?.cancelWait = effects.schedule(delay) { [weak self] in
            guard let self, self.repairLoop?.episode == id else { return }
            self.repairLoop?.cancelWait = nil
            self.runRepair()
        }
    }

    private func repairPassEnded(episode id: UInt64) {
        guard var loop = repairLoop, loop.episode == id else { return }
        loop.running = false
        if loop.again {
            repairLoop = loop
            runRepair()
            return
        }
        let delay = loop.delay
        loop.delay = min(loop.delay * 2, timing.maximumRetryDelay)
        repairLoop = loop
        armRepairWait(episode: id, delay: delay)
    }

    /// AM-1: while an engine exists and the list has not been enumerated, read it again
    /// after the repair loop's delays. A successful read publishes the list, whose sink
    /// reconciles; `reconcileNow` covers a read that publishes nothing.
    private func updateListRetry(_ inputs: Inputs) {
        guard inputs.engine != nil, !inputs.isProfileListEnumerated else {
            cancelListRetry?()
            cancelListRetry = nil
            listRetryDelay = nil
            return
        }
        guard cancelListRetry == nil else { return }
        let delay = listRetryDelay ?? timing.firstRetryDelay
        listRetryDelay = min(delay * 2, timing.maximumRetryDelay)
        cancelListRetry = effects.schedule(delay) { [weak self] in
            guard let self else { return }
            self.cancelListRetry = nil
            self.effects.refreshProfileList()
            self.effects.reconcileNow()
        }
    }

    /// Step 5: the difference between what was applied and what is desired. The gate first,
    /// then the key flag and the bridge, then the helper, then what resuming requires.
    private func apply(old: Outputs, desired: Outputs, inputs: Inputs) {
        var resumed = false
        if desired.gateEngine != old.gateEngine {
            if desired.gateEngine != nil {
                effects.setEngineGate(true)
            } else if old.gateEngine == inputs.engine {
                effects.setEngineGate(false)
                resumed = true
            }
        }
        if desired.keysWithdrawnController != old.keysWithdrawnController {
            if desired.keysWithdrawnController != nil {
                effects.setKeysWithdrawn(true)
                effects.log("profile mapping pause: chromium keys withdrawn")
                effects.notifyKeysChanged()
            } else if old.keysWithdrawnController == inputs.controller {
                effects.setKeysWithdrawn(false)
                effects.log("profile mapping pause: chromium keys restored")
                effects.notifyKeysChanged()
            }
        }
        if desired.status != old.status || desired.statusEngine != old.statusEngine {
            if desired.statusEngine != nil {
                effects.publishStatus(desired.status)
            } else if old.statusEngine != nil, old.statusEngine == inputs.engine {
                effects.publishStatus(.none)
            }
        }
        if resumed { effects.resume() }
    }
}

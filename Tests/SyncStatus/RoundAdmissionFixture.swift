import Foundation

// The runner inserts the production round queue (`serialized`), round entry and tail (`run`), the
// stop signal, the unmapped-Profile gate and `markLocalChangePending`. Round bodies are stand-ins
// that record what ran, so this regression stays independent of the AppKit test host.
func AppLogInfo(_ message: String) {}
struct SpaceRoundCounters {}
struct PhiSpaceSyncTable {
    var deleted: [String] = []
    mutating func recordLocalDeletion(spaceId: String) -> Bool { deleted.append(spaceId); return true }
}

actor RoundAdmissionFixture {
    enum RoundOutcome { case ok }
    final class PreviewBox {}

    /* STOP_SIGNAL */
    private let stopSignal = StopSignal(paired: true)
    private var activePairingRevision: UInt64 = 0
    /* IS_STOPPED */
    /* GATE */
    /* ROUND */
    nonisolated let statusState = SyncStatusState()
    /* REQUIRES_RECONFIGURATION */
    /* MARK_PENDING */

    private var roundQueue: Task<Void, Never>?
    private var queuedDataRounds = 0
    /* SERIALIZED */
    /* RUN */

    // Round state `run` resets; the stand-ins below never read it.
    private var roundOutboundFailed = false, roundOffline = false
    private var roundDetail = SyncRoundDetail()
    private var settingsReceivedThisRound = 0, settingsSentThisRound = 0
    private var spaceCounters = SpaceRoundCounters()
    private var canPublishThisRound = false
    private var ownedCounters: [String: Int] = [:], ownedTagIndices: [String: Int] = [:]
    private var ownedTables: [String: Int] = [:], ownedMustRepublish: [String: Int] = [:]
    private var ownedDeferredOwners: [String: Int] = [:]
    private var ownedReadFailed: Set<String> = [], ownedRoundStarted: Set<String> = []
    private var ownedLossObservedAtEntry: Set<String> = [], ownedParkedRetryDone: Set<String> = []
    private var ownedMapsThisRound: Int?
    private var cursorSaveFailures = 0, roundPages = 0
    private var roundOutcome = RoundOutcome.ok
    private var roundMarkerAdvanced = false
    private var faviconCandidatesThisRound: [Int] = [], faviconPinCandidatesThisRound: [Int] = []
    private var didRefreshProfilesThisRound = false
    private var isApplyingRemote = false
    private var hasAdopted = true

    // What ran, in order. A data round records its writes after its network suspension, where a
    // pause that came on meanwhile would have to stop it if anything inside the round read the gate.
    private(set) var events: [String] = []
    private(set) var table = PhiSpaceSyncTable()
    private var holdNetwork = false
    private(set) var parkedInNetwork = false

    func setHoldNetwork(_ hold: Bool) { holdNetwork = hold }
    private func network(_ name: String) async {
        events.append(name + ":entered")
        parkedInNetwork = true
        while holdNetwork { await Task.yield() }
        parkedInNetwork = false
        guard !isStopped else { return }
        events.append(name + ":landed")
        events.append(name + ":cursorSaved")
        events.append(name + ":published")
    }

    private func pull(thenPush: Bool) async -> Bool { await network("pull"); return true }
    private func push(retryOnConflict: Bool) async { await network("push") }
    private func snapshotLocalSettings() -> Int? { events.append("stamp"); return nil }
    private func stampLocalSpaceEdits() async { events.append("stampSpaces") }
    private func applySpaceGate(_ enabled: Bool) { events.append("spaceGate:\(enabled)") }
    private func applyRetentionSweep() async { events.append("retentionSweep") }
    @discardableResult
    private func runSpaceIntent(_ body: (inout PhiSpaceSyncTable) -> Bool) -> Bool {
        body(&table)
    }
    private func recordLocalDeletionWhileBlocked(_ uuid: String) { events.append("deletionWhileBlocked") }
    private func runPreview(into box: PreviewBox) async { events.append("preview") }
    private func logRoundOutcome() { events.append("outcome") }
    private func finishStatusRound(revision: UInt64) {
        events.append("finishStatus")
        statusState.update(.upToDate, completing: revision)
    }
    private func logSpaceRound() async {}
    private func logOwnedRounds() {}
    private func runFaviconBackfill() async { events.append("favicon") }

    func pullOnce() async { await serialized(.pull) }
    func pushLocalSettings() async { await serialized(.push) }
    func handleLocalDefaultsChange() async { await serialized(.localChange) }
    func handleLocalSpacesChange() async { await serialized(.localSpaceChange) }
    func handleLocalOwnedChange(label: String) async { await serialized(.localOwnedChange(label)) }
    func runRetentionSweep() async { await serialized(.retentionSweep) }
    func setSpaceSyncEnabled(_ enabled: Bool) async { await serialized(.spaceGate(enabled)) }
    func recordLocalDeletion(syncUuid: String) async { await serialized(.recordLocalDeletion(syncUuid)) }
    func previewAccountSpaces() async { await serialized(.preview(PreviewBox())) }
    func clearEvents() { events = [] }

    /// Test hook: returns once `count` data rounds have entered the production queue.
    /// `serialized(_:)` counts a data round and makes it the queue's tail in one synchronous
    /// actor step, before its first suspension, so the count is the acknowledgement that a
    /// round is queued; nothing about admission has been decided at that point.
    func waitUntilQueued(dataRounds count: Int) async {
        while queuedDataRounds < count { await Task.yield() }
    }
}

enum AdmissionFailure: Error { case assertion(String) }

@main struct RoundAdmissionTests {
    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw AdmissionFailure.assertion(message) }
    }

    static func main() async throws {
        try await testGateNeverSet()
        try await testQueuedRoundsTurnedAway()
        try await testAdmittedRoundFinishes()
        try await testExemptions()
        try await testClearingAdmitsNextRound()
        try await testNoSyncingWhileGated()
        try await testAdmissionIsDecidedWhenTheRoundRuns()
        print("PASS round admission: gate never set, rounds turned away, admitted round finishes, "
              + "exemptions without favicon tail, clearing admits, no Syncing while gated, "
              + "admission decided when a round runs, not when it is queued")
    }

    /// I7: an engine whose gate is never set runs every round and its favicon tail as before.
    static func testGateNeverSet() async throws {
        let engine = RoundAdmissionFixture()
        try expect(!engine.isProfileMappingPaused, "A new engine starts with the gate off")
        await engine.pullOnce()
        await engine.setSpaceSyncEnabled(true)
        await engine.recordLocalDeletion(syncUuid: "space-a")
        await engine.runRetentionSweep()
        let events = await engine.events
        try expect(events == ["pull:entered", "pull:landed", "pull:cursorSaved", "pull:published",
                              "outcome", "finishStatus", "favicon",
                              "spaceGate:true", "outcome", "favicon",
                              "outcome", "favicon",
                              "retentionSweep", "outcome", "favicon"],
                   "Without the gate every round and its favicon tail run: \(events)")
        try expect(await engine.table.deleted == ["space-a"], "The deletion is recorded as before")
    }

    /// I1: a pull, push, local-change round or retention sweep queued while the gate is on is
    /// not admitted and writes nothing.
    static func testQueuedRoundsTurnedAway() async throws {
        let engine = RoundAdmissionFixture()
        engine.setProfileMappingPause(true)
        try expect(engine.isProfileMappingPaused, "The setter turns the gate on")
        let before = engine.statusState.snapshot
        await engine.pullOnce()
        await engine.pushLocalSettings()
        await engine.handleLocalDefaultsChange()
        await engine.handleLocalSpacesChange()
        await engine.handleLocalOwnedChange(label: "bookmarks")
        await engine.runRetentionSweep()
        try expect(await engine.events.isEmpty,
                   "No gated round may start while the gate is on: \(await engine.events)")
        let after = engine.statusState.snapshot
        try expect(after.phase == before.phase && after.revision == before.revision,
                   "A round turned away must not touch the status")
    }

    /// I2 and R3 as amended: a round admitted before the gate came on finishes with all its writes
    /// and its tail. The round queued behind it meets the gate.
    static func testAdmittedRoundFinishes() async throws {
        let engine = RoundAdmissionFixture()
        await engine.setHoldNetwork(true)
        let inFlight = Task { await engine.pullOnce() }
        while !(await engine.parkedInNetwork) { await Task.yield() }
        engine.setProfileMappingPause(true)
        let queued = Task { await engine.pushLocalSettings() }
        for _ in 0..<50 { await Task.yield() }
        await engine.setHoldNetwork(false)
        await inFlight.value
        await queued.value
        let events = await engine.events
        try expect(events == ["pull:entered", "pull:landed", "pull:cursorSaved", "pull:published",
                              "outcome", "finishStatus", "favicon"],
                   "The admitted round finishes with every write and its tail; the queued push is turned away: \(events)")
    }

    /// Review R8, the admission constraint: a round queued while the gate is off and
    /// still waiting when it comes on is turned away when it runs. Round A is parked in its
    /// network call; round B is queued behind it with the gate off; only after the fixture
    /// acknowledges that B is in the queue does the gate come on; A then finishes completely.
    static func testAdmissionIsDecidedWhenTheRoundRuns() async throws {
        let engine = RoundAdmissionFixture()
        await engine.setHoldNetwork(true)
        let roundA = Task { await engine.pullOnce() }
        while !(await engine.parkedInNetwork) { await Task.yield() }
        try expect(!engine.isProfileMappingPaused, "Round B is queued with the gate off")
        let roundB = Task { await engine.pushLocalSettings() }
        await engine.waitUntilQueued(dataRounds: 2)
        engine.setProfileMappingPause(true)
        await engine.setHoldNetwork(false)
        await roundA.value
        await roundB.value
        let events = await engine.events
        try expect(events == ["pull:entered", "pull:landed", "pull:cursorSaved", "pull:published",
                              "outcome", "finishStatus", "favicon"],
                   "Round A finishes with its favicon tail; round B, queued before the gate, is turned away: \(events)")
    }

    /// Exemptions (AM-3): the preview, the Space gate edge and the local deletion intent
    /// run while the gate is on; the last two skip the favicon tail.
    static func testExemptions() async throws {
        let engine = RoundAdmissionFixture()
        engine.setProfileMappingPause(true)
        await engine.previewAccountSpaces()
        await engine.setSpaceSyncEnabled(false)
        await engine.recordLocalDeletion(syncUuid: "space-b")
        let events = await engine.events
        try expect(events == ["preview", "spaceGate:false", "outcome", "outcome"],
                   "Exempt rounds run while gated, without the favicon tail: \(events)")
        try expect(await engine.table.deleted == ["space-b"], "The deletion intent is recorded while gated")
        try expect(!events.contains("favicon"), "No favicon request while gated")
    }

    /// Turning the gate off admits the next round, which runs its favicon tail again; an exempt
    /// round admitted with the gate off is an ordinary round.
    static func testClearingAdmitsNextRound() async throws {
        let engine = RoundAdmissionFixture()
        engine.setProfileMappingPause(true)
        await engine.pullOnce()
        try expect(await engine.events.isEmpty, "The gated pull is turned away")
        engine.setProfileMappingPause(false)
        try expect(!engine.isProfileMappingPaused, "The setter turns the gate off")
        await engine.pullOnce()
        await engine.setSpaceSyncEnabled(true)
        let events = await engine.events
        try expect(events == ["pull:entered", "pull:landed", "pull:cursorSaved", "pull:published",
                              "outcome", "finishStatus", "favicon", "spaceGate:true", "outcome", "favicon"],
                   "Clearing the gate admits the next round with its tail: \(events)")
        try expect(engine.statusState.snapshot.phase == .upToDate, "The admitted round completes the status")
    }

    /// Neither `markLocalChangePending()` nor the queue's Syncing update shows Syncing while the
    /// gate is on; both do again once it is off.
    static func testNoSyncingWhileGated() async throws {
        let engine = RoundAdmissionFixture()
        engine.statusState.update(.upToDate)
        engine.setProfileMappingPause(true)
        let gated = engine.statusState.snapshot.revision
        engine.markLocalChangePending()
        await engine.handleLocalDefaultsChange()
        try expect(engine.statusState.snapshot.phase == .upToDate
                   && engine.statusState.snapshot.revision == gated,
                   "No Syncing while the gate is on")
        engine.setProfileMappingPause(false)
        engine.markLocalChangePending()
        try expect(engine.statusState.snapshot.phase == .syncing,
                   "markLocalChangePending shows Syncing again once the gate is off")
    }
}

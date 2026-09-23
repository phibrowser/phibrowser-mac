import Foundation

// The runner inserts production outcome handlers, retry tails and round completion.
// Storage/wire stand-ins keep this regression independent of the AppKit test host.
func AppLogError(_ message: String) {}
func AppLogWarn(_ message: String) {}
struct PhiCommitEntry { var deleted = false; var clientTagHash = "test-tag" }
struct Phi_PhiSpaceEntity { func serializedData() throws -> Data { Data([1]) } }
enum PhiCommitOutcome {
    case applied(entityId: String, version: Int64, storeBirthday: String)
    case conflict(entityId: String?, serverVersion: Int64?)
    case invalidMessage
    case rejected(String)
}
struct PhiSpaceCursor {
    var entityId: String?
    var version: Int64 = 0
    var pendingDelete = false, pendingTombstone = false, hidden = false
    var deleteRejectRounds = 0
    var reconciled: Data?, server: Data?, pendingProjection: Data?, pendingApply: Data?
    var deletedAtMs: Int64?
    var heldProfileUuid: String?
}
struct PhiSpaceSyncTable {
    var cursors: [String: PhiSpaceCursor] = [:]
    var unreadableTagHashes: [String: String] = [:]
    var drainInProgress = false
}
struct PhiOwnedItemCursor {
    var entityId = ""
    var version: Int64 = 0
    var pendingDelete = false, pendingTombstone = false
    var deleteRejectRounds = 0
    var rekeyRejectRounds: Int?
    var reconciled: Data?, server: Data?, pendingApply: Data?
    var deletedAtMs: Int64?
    var pendingPartnerLineage: String?, ownerUuid: String?
}
struct PhiOwnedItemTable { var cursors: [String: PhiOwnedItemCursor] = [:] }
struct OwnedRoundCounters { var pendingPublish = 0, tombstones = 0, pushed = 0, resurrected = 0 }
struct SpaceRoundCounters { var tombstones = 0, pushed = 0, conflicts = 0 }
struct OwnedKindRegistration { let label: String }
struct OwnedOwnerMaps {}

final class ConflictFixture {
    enum Kind: CaseIterable { case space, owned }
    enum RetryResult { case accepted, noRemainingChanges, conflict, rejected, transportFailure }
    let kind: Kind
    let retryResult: RetryResult
    var failRecoveryPull = false
    var attempts = 0
    var spaceTable = PhiSpaceSyncTable()
    var ownedTables: [String: PhiOwnedItemTable] = [:]
    var ownedCounters: [String: OwnedRoundCounters] = [:]
    var spaceCounters = SpaceRoundCounters()
    var storedBirthday = "birthday"
    var roundOutboundFailed = false, roundOffline = false
    var canPublishThisRound = true
    enum RoundOutcome { case ok, pageBudgetExhausted, pullFailed }
    var roundOutcome = RoundOutcome.ok
    var cursorSaveFailures = 0, queuedDataRounds = 1
    var ownedReadFailed: Set<String> = []
    var unreadableSettingsRecord: Data?
    struct StopSignal { var isStopped = false }
    var stopSignal = StopSignal()
    var isStopped = false, requiresReconfiguration = false
    let statusState = SyncStatusState()
    static let tombstoneRejectGiveUpRounds = 3, rekeyRejectGiveUpRounds = 3

    init(kind: Kind, retryResult: RetryResult) { self.kind = kind; self.retryResult = retryResult }
    func now() -> Int64 { 100 }
    func loadSpaceTable() -> PhiSpaceSyncTable { spaceTable }
    func harvestTriple(into cursor: inout PhiOwnedItemCursor, entityId: String, version: Int64) {
        if !entityId.isEmpty { cursor.entityId = entityId }
        cursor.version = max(cursor.version, version)
    }
    func pull(thenPush: Bool) async -> Bool {
        if failRecoveryPull {
            noteStatusError(URLError(.notConnectedToInternet))
            roundOutcome = .pullFailed
            return false
        }
        return true
    }
    func nextOutcome() -> PhiCommitOutcome? {
        attempts += 1
        if attempts == 1 { return .conflict(entityId: nil, serverVersion: nil) }
        switch retryResult {
        case .accepted: return .applied(entityId: "server-id", version: 2, storeBirthday: "birthday")
        case .noRemainingChanges: return nil
        case .conflict: return .conflict(entityId: nil, serverVersion: nil)
        case .rejected: return .rejected("test-rejection")
        case .transportFailure:
            noteStatusError(URLError(.notConnectedToInternet))
            return nil
        }
    }
    func pushSpaces(retryOnConflict: Bool, onlyUuids: Set<String>? = nil) async {
        guard let outcome = nextOutcome() else { return }
        var table = spaceTable, conflicted = Set<String>(), tombstoned = Set<String>()
        applySpaceCommitOutcome(outcome,
            for: (uuid: "space", entry: PhiCommitEntry(), outgoing: Phi_PhiSpaceEntity()),
            table: &table, conflicted: &conflicted, tombstoned: &tombstoned)
        spaceTable = table
        /* SPACE_RETRY */
    }
    func publishOwnedKind(_ registration: OwnedKindRegistration, maps: OwnedOwnerMaps,
                          retryOnConflict: Bool, onlyIdentities: Set<String>? = nil) async {
        guard let outcome = nextOutcome() else { return }
        var table = ownedTables[registration.label] ?? PhiOwnedItemTable()
        var counters = OwnedRoundCounters(), conflicted = Set<String>()
        applyOwnedCommitOutcome(outcome,
            for: (identity: "bookmark", entry: PhiCommitEntry(), payload: Data([1])),
            registration: registration, owner: "space", rekeying: false,
            table: &table, counters: &counters, conflicted: &conflicted)
        ownedTables[registration.label] = table
        ownedCounters[registration.label] = counters
        /* OWNED_RETRY */
    }
    /* SPACE_OUTCOME */
    /* OWNED_OUTCOME */
    /* FINISH_STATUS */
    /* STATUS_ERROR */

    func run() async -> SyncContextSnapshot {
        let revision = statusState.update(.initialSync)
        switch kind {
        case .space: await pushSpaces(retryOnConflict: true)
        case .owned:
            await publishOwnedKind(OwnedKindRegistration(label: "bookmarks"), maps: OwnedOwnerMaps(),
                                   retryOnConflict: true)
        }
        finishStatusRound(revision: revision)
        return statusState.snapshot
    }
}

func testConflictStatus() async {
    for kind in ConflictFixture.Kind.allCases {
        for retry in [ConflictFixture.RetryResult.accepted, .noRemainingChanges] {
            let recovered = ConflictFixture(kind: kind, retryResult: retry)
            let success = await recovered.run()
            precondition(success.phase == .upToDate && success.lastSuccess != nil,
                         "A resolved \(kind) conflict must report success in the same round")
            precondition(recovered.attempts == 2)
            let mixed = ConflictFixture(kind: kind, retryResult: retry)
            mixed.roundOutboundFailed = true // Another item already failed in this round.
            let failure = await mixed.run()
            precondition(failure.phase == .needsAttention && failure.lastSuccess == nil,
                         "Recovering one conflict must not erase another publication failure")
        }
        for retry in [ConflictFixture.RetryResult.conflict, .rejected] {
            let fixture = ConflictFixture(kind: kind, retryResult: retry)
            let failed = await fixture.run()
            precondition(failed.phase == .needsAttention && failed.lastSuccess == nil,
                         "An exhausted or rejected retry must remain a failure")
            precondition(fixture.attempts == 2, "Conflict retries must stay bounded")
        }
        for failPull in [true, false] {
            let fixture = ConflictFixture(kind: kind, retryResult: .transportFailure)
            fixture.failRecoveryPull = failPull
            let offline = await fixture.run()
            precondition(offline.phase == .offline && offline.lastSuccess == nil)
            precondition(fixture.attempts == (failPull ? 1 : 2))
        }
    }
    print("PASS conflict status: resolved, exhausted, mixed failure, failed recovery pull/commit for Spaces and owned items")
}

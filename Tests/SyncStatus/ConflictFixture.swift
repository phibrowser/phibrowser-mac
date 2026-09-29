import CryptoKit
import Foundation

// The runner inserts production outcome handlers, key preflights, retry tails and round completion.
// Storage/wire stand-ins keep this regression independent of the AppKit test host.
func AppLogError(_ message: String) {}
func AppLogWarn(_ message: String) {}
/* KEY_API_ERROR */
enum PhiSyncLog { static func describe(_ error: Error) -> String { "test-error" } }
enum PhiSyncProtocolError: Error { case http(Int) }
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
struct OwnedRoundCounters {
    var pendingPublish = 0, tombstones = 0, pushed = 0, resurrected = 0, applied = 0, unreadable = 0
}
struct SpaceRoundCounters { var tombstones = 0, pushed = 0, conflicts = 0, applied = 0 }
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
    enum RoundOutcome { case ok, pageBudgetExhausted, pullFailed, unusableSettings }
    var roundOutcome = RoundOutcome.ok
    var cursorSaveFailures = 0, queuedDataRounds = 1
    var ownedReadFailed: Set<String> = []
    var unreadableSettingsRecord: Data?
    struct StopSignal { var isStopped = false }
    var stopSignal = StopSignal()
    var isStopped = false, requiresReconfiguration = false
    let statusState = SyncStatusState()
    var roundDetail = SyncRoundDetail()
    var settingsReceivedThisRound = 0, settingsSentThisRound = 0
    var spaceSectionEnabled = true
    var spaceStore: Any? = "store"
    var ownedKinds = [OwnedKindRegistration(label: "bookmarks"), OwnedKindRegistration(label: "pins"),
                      OwnedKindRegistration(label: "urlrules")]
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
    /* ROUND_DETAIL */
    /* RESET_ROUND */
    /* STATUS_ERROR */

    struct DomainKeys {
        var error: Error?
        func domainKey() async throws -> SymmetricKey {
            if let error { throw error }
            return SymmetricKey(size: .bits256)
        }
    }
    enum KeyStage: CaseIterable { case pull, push }
    var domainKeys = DomainKeys()
    /* PULL_KEY */
    private func readPushDomainKey() async {
        /* PUSH_KEY */
    }

    func runKeyRound(_ stage: KeyStage, error: Error?) async -> SyncContextSnapshot {
        domainKeys.error = error
        roundOutboundFailed = false
        roundOffline = false
        roundDetail = SyncRoundDetail()
        roundOutcome = .ok
        // A settings push is reached only after this round has already drained a pull.
        canPublishThisRound = stage == .push
        let revision = statusState.update(statusState.snapshot.lastSuccess == nil ? .initialSync : .syncing)
        switch stage {
        case .pull: _ = await readPullDomainKey(thenPush: true)
        case .push: await readPushDomainKey()
        }
        finishStatusRound(revision: revision)
        return statusState.snapshot
    }

    func noteError(_ error: Error) { noteStatusError(error) }

    /// Round tail only: the caller staged this round's counters, tables and failures.
    func finish() -> SyncContextSnapshot {
        let revision = statusState.update(statusState.snapshot.lastSuccess == nil ? .initialSync : .syncing)
        finishStatusRound(revision: revision)
        roundDetail = SyncRoundDetail()
        roundOutboundFailed = false
        roundOffline = false
        return statusState.snapshot
    }

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
            precondition(success.detail?.lastProblem == nil)
            let kindKey: SyncKind = kind == .space ? .spaces : .bookmarks
            precondition(success.detail?.kinds[kindKey]?.sent == (retry == .accepted ? 1 : 0))
            let mixed = ConflictFixture(kind: kind, retryResult: retry)
            mixed.roundOutboundFailed = true // Another item already failed in this round.
            let failure = await mixed.run()
            precondition(failure.phase == .needsAttention && failure.lastSuccess == nil,
                         "Recovering one conflict must not erase another publication failure")
            precondition(failure.detail?.lastProblem?.category == .serverError,
                         "An outbound failure without an error value still needs a category")
        }
        for retry in [ConflictFixture.RetryResult.conflict, .rejected] {
            let fixture = ConflictFixture(kind: kind, retryResult: retry)
            let failed = await fixture.run()
            precondition(failed.phase == .needsAttention && failed.lastSuccess == nil,
                         "An exhausted or rejected retry must remain a failure")
            precondition(failed.detail?.lastProblem?.category == .rejectedByServer
                         && failed.detail?.lastProblem?.kind == (kind == .space ? .spaces : .bookmarks),
                         "An exhausted conflict or a rejected commit is a kind-specific server rejection")
            precondition(fixture.attempts == 2, "Conflict retries must stay bounded")
        }
        for failPull in [true, false] {
            let fixture = ConflictFixture(kind: kind, retryResult: .transportFailure)
            fixture.failRecoveryPull = failPull
            let offline = await fixture.run()
            precondition(offline.phase == .offline && offline.lastSuccess == nil)
            precondition(offline.detail?.lastProblem?.category == .offline && offline.detail?.lastProblem?.kind == nil)
            precondition(fixture.attempts == (failPull ? 1 : 2))
        }
    }
    print("PASS conflict status: resolved, exhausted, mixed failure, failed recovery pull/commit for Spaces and owned items, with problem categories")
}

func testDomainKeyStatus() async {
    let failures: [(Error, SyncContextPhase, SyncProblemCategory)] = [
        (KeyAPIError.transport(URLError(.notConnectedToInternet)), .offline, .offline),
        (KeyAPIError.transport(URLError(.timedOut)), .offline, .offline),
        (KeyAPIError.http(503, "unavailable"), .needsAttention, .serverError),
        (KeyAPIError.http(401, "unauthorized"), .needsAttention, .signInExpired),
        (KeyAPIError.http(403, "forbidden"), .needsAttention, .signInExpired),
        (KeyAPIError.decode, .needsAttention, .serverError),
        (KeyAPIError.transport(URLError(.userAuthenticationRequired)), .needsAttention, .signInExpired)
    ]
    for stage in ConflictFixture.KeyStage.allCases {
        for (error, expected, category) in failures {
            let fixture = ConflictFixture(kind: .space, retryResult: .accepted)
            let failed = await fixture.runKeyRound(stage, error: error)
            precondition(failed.phase == expected, "A failed \(stage) domain key must report \(expected), got \(failed.phase)")
            precondition(failed.lastSuccess == nil)
            precondition(failed.detail?.lastProblem?.category == category,
                         "A failed \(stage) domain key must report \(category), got \(String(describing: failed.detail?.lastProblem))")
            if stage == .pull { precondition(fixture.roundOutcome == .pullFailed && !fixture.canPublishThisRound) }

            let recovered = await fixture.runKeyRound(stage, error: nil)
            precondition(recovered.phase == .upToDate && recovered.lastSuccess != nil)
            precondition(recovered.detail?.lastProblem == nil, "A successful round clears the last problem")
            let failedAgain = await fixture.runKeyRound(stage, error: error)
            precondition(failedAgain.phase == expected && failedAgain.lastSuccess == recovered.lastSuccess,
                         "Key failures must preserve, never advance, the last successful sync time")
        }
    }
    print("PASS domain key status: pull/push offline, HTTP, decode, auth, categories, recovery and preserved success time")
}

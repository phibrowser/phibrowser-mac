import Foundation

// Runs the production owned-item publication path (`publishOwnedKind` with its slice, commit-outcome
// and table-doctoring helpers, sliced from PhiSyncEngine.swift) for the pin kind, with the production
// pin block predicate: `PinSyncRoundState` (sample, rescan, scopeBlocked) and the registration's
// `beginRound` and `publicationBlocked` closures, all sliced. B-3 stage 1, design 3.4: a blocked round publishes no
// queued tombstone and no dead-owner deletion, and the commit fence drops a commit when the
// generation moves between the snapshot and the submit.
//
// Stubbed: the wire client (records commits, answers applied), the domain key (a hook lets a test
// land a migration during that suspension), envelope sealing, durable table storage, and the pin
// snapshot and deletion diff. The snapshot and diff stubs deliberately ignore the block, so the
// engine-level check is what withholds their output.
/* PRODUCTION_TYPES */

enum PhiSpaceSyncState { static let retentionMs: Int64 = 30 * 24 * 3600 * 1000 }
enum PhiSyncLog { static func describe(_ error: Error) -> String { "test-error" } }
enum PhiSyncProtocolError: Error { case notMyBirthday }
enum PhiCommitOutcome {
    case applied(entityId: String, version: Int64, storeBirthday: String)
    case conflict(entityId: String?, serverVersion: Int64?)
    case invalidMessage
    case rejected(Int)
}
enum PhiSyncEntity { static func clientTagHash(for tag: String) -> String { "hash-\(tag)" } }
struct Phi_PhiEntity { init(serializedBytes: Data) throws {} }
enum PhiEntityCodec { static func encrypt(_ envelope: Phi_PhiEntity, key: Int) throws -> Data { Data([9]) } }
struct OwnedItemApplyStep {
    enum StepKind { case delete }
    var identity: String, kind: StepKind, newParentUuid: String?, newRank: String?, payload: Data?
}
struct OwnedLandingInput { var steps: [OwnedItemApplyStep]; var table: PhiOwnedItemTable; var maps: OwnedOwnerMaps }
struct OwnedLandingOutcome { var landed: Set<String> = [] }
struct OwnedOwnerMaps {
    struct Resolver { func localSpaceId(_ uuid: String) -> String? { nil } }
    var deadSpaceUuids: Set<String> = []
    var resolver: Resolver { Resolver() }
}
struct PhiSpaceCursor { var hidden = false; var purgedAtMs: Int64? }
struct PhiSpaceSyncTable { var cursors: [String: PhiSpaceCursor] = [:]; var unreadableTagHashes: [String: Int64] = [:] }
func AppLogInfo(_ message: String) {}
func AppLogWarn(_ message: String) {}
func AppLogError(_ message: String) {}

protocol PhiPinnedTabLocalAccess: AnyObject {
    func currentScope() -> PinnedTabScope
    func accountScope() -> PinnedTabScope?
    func pinScopeGeneration() -> UInt64
    func scopeFollowerBusy() -> Bool
    func requestScopeFollow()
    func allPins() throws -> [PhiLocalPin]
}

/// The row scope, the key's scope, the store generation and the follower, as the round probes them.
final class FakePinAccess: PhiPinnedTabLocalAccess {
    var row: PinnedTabScope = .profile
    var key: PinnedTabScope? = .profile
    var generation: UInt64 = 0
    var followerBusy = false
    /// A follow request starts a job (the follower found work the sample cannot see, such as a row
    /// the main context has not merged yet).
    var followStartsJob = false
    /// Runs inside the rows read, then is cleared: a migration committing between two sample reads.
    var duringAllPins: (() -> Void)?
    /// Every probe, in order.
    var reads: [String] = []
    func currentScope() -> PinnedTabScope { reads.append("row"); return row }
    func accountScope() -> PinnedTabScope? { reads.append("key"); return key }
    func pinScopeGeneration() -> UInt64 { reads.append("generation"); return generation }
    func scopeFollowerBusy() -> Bool { reads.append("busy"); return followerBusy }
    func requestScopeFollow() {
        reads.append("follow")
        if followStartsJob { followerBusy = true }
    }
    func allPins() throws -> [PhiLocalPin] {
        reads.append("rows")
        if let during = duringAllPins { duringAllPins = nil; during() }
        return []
    }
}

/// The production pin registration's `beginRound`, over this round state and access.
@MainActor
func pinBeginRound(state: PinSyncRoundState, access: any PhiPinnedTabLocalAccess) -> @MainActor () throws -> Void {
    /* PRODUCTION_PIN_BEGIN_ROUND */
}

struct OwnedKindRegistration {
    let label: String
    let entityName: String
    let tombstoneYieldsToLocalEdits: Bool
    let clientTag: (String) -> String
    let owners: (Data) -> [String]
    let clearedSplitPartners: (@MainActor ([String: Data], Int64, OwnedOwnerMaps) -> [String: Data])?
    let localIdentities: @MainActor () -> Set<String>
    let snapshot: @MainActor (PhiOwnedItemTable, OwnedOwnerMaps, Int64, Int64, Int64) -> OwnedSnapshotBytes
    let tombstones: @MainActor (PhiOwnedItemTable, OwnedOwnerMaps, Int64) throws -> OwnedItemTombstoneResult
    let land: @MainActor (OwnedLandingInput) async -> OwnedLandingOutcome
    let claimIdentities: @MainActor ([String: String]) async -> Set<String>
    let notePublishApplied: @MainActor (Set<String>) async -> Void
    let clearPendingLocalEdits: @MainActor (Set<String>) async -> Void
    var hardDeleteAfterTombstone: (@MainActor (Set<String>) async -> Void)? = nil
    var publicationBlocked: (@MainActor () -> Bool)? = nil
}

/// What the stubs saw, for the assertions.
@MainActor
final class Recorder {
    var commits: [[PhiCommitEntry]] = []
    var notedPublished: Set<String> = []
    var claimed: [String: String] = [:]
    var hardDeleted: Set<String> = []
    var domainKeyReads = 0
    /// Runs inside the domain-key suspension, on the read with this number.
    var onDomainKeyRead: [Int: @MainActor () -> Void] = [:]
}

@MainActor
func pinRegistration(state: PinSyncRoundState, access: any PhiPinnedTabLocalAccess, recorder: Recorder,
                     snapshot: @escaping @MainActor () -> OwnedSnapshotBytes,
                     diff: @escaping @MainActor (PhiOwnedItemTable) -> OwnedItemTombstoneResult) -> OwnedKindRegistration {
    OwnedKindRegistration(
        label: "pins", entityName: "pin", tombstoneYieldsToLocalEdits: false,
        clientTag: { "pin:\($0)" }, owners: { _ in [] }, clearedSplitPartners: nil,
        localIdentities: { [] },
        snapshot: { _, _, _, _, _ in snapshot() },
        tombstones: { table, _, _ in diff(table) },
        land: { _ in OwnedLandingOutcome() },
        claimIdentities: { minted in recorder.claimed.merge(minted) { $1 }; return Set(minted.keys) },
        notePublishApplied: { recorder.notedPublished.formUnion($0) },
        clearPendingLocalEdits: { _ in },
        hardDeleteAfterTombstone: { recorder.hardDeleted.formUnion($0) },
        publicationBlocked: /* PRODUCTION_PIN_PUBLICATION_BLOCKED */)
}

struct FakeClock { var maxSeen: Int64 = 1_000 }

actor PublicationFixture {
    struct DomainKeys {
        let recorder: Recorder
        func domainKey() async throws -> Int {
            await MainActor.run {
                recorder.domainKeyReads += 1
                recorder.onDomainKeyRead[recorder.domainKeyReads]?()
            }
            return 1
        }
    }
    struct Client {
        let recorder: Recorder
        func commit(entries: [PhiCommitEntry], storeBirthday: String) async throws -> [PhiCommitOutcome] {
            await MainActor.run { recorder.commits.append(entries) }
            return entries.enumerated().map { offset, entry in
                .applied(entityId: entry.entityId ?? "minted-\(offset)", version: entry.baseVersion + 1,
                         storeBirthday: "birthday")
            }
        }
    }

    static let maxOwnedCommitsPerRound = 250
    static let maxCommitEntriesPerBatch = 2
    static let tombstoneRejectGiveUpRounds = 3
    static let rekeyRejectGiveUpRounds = 3

    let domainKeys: DomainKeys
    let client: Client
    var isStopped = false
    var canPublishThisRound = true
    var ownedReadFailed: Set<String> = []
    var ownedItemsPublishAllowed = true
    var cursorSaveFailures = 0
    var ownedLossObservedAtEntry: Set<String> = []
    var ownedCounters: [String: OwnedRoundCounters] = [:]
    var ownedMustRepublish: [String: Set<String>] = [:]
    var ownedDeferredOwners: [String: Set<String>] = [:]
    /// The durable cursor table, as the next round's load sees it.
    var ownedTables: [String: PhiOwnedItemTable] = [:]
    var tableWrites = 0
    var hlcClock = FakeClock()
    var wallClockOffsetMs: Int64 = 0
    var storedBirthday = "birthday"
    var roundOutboundFailed = false
    var roundDetail = SyncRoundDetail()

    init(recorder: Recorder) {
        domainKeys = DomainKeys(recorder: recorder)
        client = Client(recorder: recorder)
    }

    func seed(_ table: PhiOwnedItemTable, label: String) { ownedTables[label] = table }
    func table(_ label: String) -> PhiOwnedItemTable { ownedTables[label] ?? PhiOwnedItemTable() }
    func counters(_ label: String) -> OwnedRoundCounters { ownedCounters[label] ?? OwnedRoundCounters() }
    func startRound() { ownedCounters = [:] }

    func publish(_ registration: OwnedKindRegistration, maps: OwnedOwnerMaps) async {
        await publishOwnedKind(registration, maps: maps, retryOnConflict: false)
    }

    private func now() -> Int64 { 5_000 }
    private func hlcNow() -> Int64 { 5_000 }
    private func observeServerDate() {}
    private func requireReconfiguration() {}
    private func noteStatusError(_ error: Error) {}
    private func pull(thenPush: Bool) async -> Bool { false }
    private func loadSpaceTable() -> PhiSpaceSyncTable { PhiSpaceSyncTable() }
    private func loadOwnedTable(_ registration: OwnedKindRegistration, armsReplayOnLoss: Bool,
                                lossObservedEarlier: Bool = false)
        -> (table: PhiOwnedItemTable, lost: Bool, reportedLoss: Bool) {
        (ownedTables[registration.label] ?? PhiOwnedItemTable(), false, false)
    }
    @discardableResult
    private func writeOwnedTable(_ registration: OwnedKindRegistration, _ table: PhiOwnedItemTable) -> Bool {
        tableWrites += 1
        ownedTables[registration.label] = table
        return true
    }
    private func harvestTriple(into cursor: inout PhiOwnedItemCursor, entityId: String, version: Int64) {
        if !entityId.isEmpty { cursor.entityId = entityId }
        cursor.version = max(cursor.version, version)
    }

    /* PRODUCTION_ENGINE_METHODS */
}

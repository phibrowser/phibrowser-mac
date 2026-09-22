import CryptoKit
import Foundation
import XCTest
@testable import Phi

/// 8b-1 tests for spec §12.1 URL Rule M-* cases and D30's first section. Pure predicates cover M-28/29/30 via
/// URLRuleKind static functions; real engine plus FakeURLRuleAccess/memory stores cover
/// M-1/2/2b/8/8b/9/11/13/14/18/20 through pullOnce only. M-31 lives in PhiOwnedItemStateTests; M-32 uses real
/// LocalStore in LocalStoreURLRuleThrowingTests. Main-actor fakes require @MainActor, as in
/// SyncableOwnedItemsTests.swift:11–12.
/// Two fixture invariants apply throughout: remoteStamp is newer than local createdDate so remote wins all
/// three units in no-baseline merge (§8.2), eliminating legitimate mustRepublish noise from adoption
/// assertions. Within a bucket, arrival ranks V/W/X increase with arrival order so adopted sortOrder agrees
/// with baseline rank and snapshots need not mint ranks.
@MainActor
final class URLRuleMergeTests: XCTestCase {
    typealias FakePhiSyncClient = PhiSyncEngineTests.FakePhiSyncClient
    typealias StubDomainKeys = PhiSyncEngineTests.StubDomainKeys
    typealias MemorySpaceStore = PhiSyncEngineSpaceTests.MemorySpaceStore

    private struct Boom: Error {}

    private let resolve = OwnerResolver.fixture()
    private let normalize = URLRuleSignatureQueries.normalize

    private var defaults: UserDefaults!
    private var suiteName: String!
    private let key = SymmetricKey(size: .bits256)
    /// Temporary directories for 8b-2 CASE M2-d real-LocalStore cases. Remove only directories created by this
    /// test.
    private var mergeTempDirectories: [URL] = []

    private static let now: Int64 = 1_700_000_000_000
    /// Newer than PhiLocalURLRule.fixture's createdDate, 1_000 seconds = 1_000_000 ms; see file header.
    private static let remoteStamp: Int64 = 5_000_000

    override func setUp() {
        super.setUp()
        suiteName = "URLRuleMergeTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        for directory in mergeTempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        mergeTempDirectories.removeAll()
        super.tearDown()
    }

    // MARK: - Fixtures (matching URLRuleKindTests Task 6)

    /// Paired device with space-a/b/c → su-1/2/3, matching OwnerResolver.fixture's local IDs.
    private func makeSpaceAccess() -> FakePhiSpaceAccess {
        let access = FakePhiSpaceAccess()
        let mappings = ["space-a": "su-1", "space-b": "su-2", "space-c": "su-3"]
        access.spaceMappings = mappings
        access.spaces = mappings.keys.sorted().map {
            PhiLocalSpace(spaceId: $0, profileId: "Default", name: "S", colorHex: "#3A6FF8",
                          iconName: "emoji:1F4BC", sortOrder: 0,
                          createdDate: Date(timeIntervalSince1970: 1), themeId: nil,
                          opacityLight: nil, opacityDark: nil)
        }
        access.uuidByProfileId = ["Default": "pu-1"]
        access.profileIdByUuid = ["pu-1": "Default"]
        access.knownLocalProfileIds = ["Default"]
        return access
    }

    /// Preseed hasDrainedFullReplay true to satisfy publication guard ①; silence settings and Spaces.
    private func drainedSpaceStore() throws -> MemorySpaceStore {
        let store = MemorySpaceStore()
        store.table.hasDrainedFullReplay = true
        try silenceOtherSections(store)
        return store
    }

    /// Silence settings/Space publication as in URLRuleKindTests.silenceOtherSections so client.commits
    /// measures rules alone.
    private func silenceOtherSections(_ spaceStore: MemorySpaceStore) throws {
        for uuid in ["su-1", "su-2", "su-3"] {
            spaceStore.table.unreadableTagHashes[
                PhiSyncEntity.clientTagHash(for: PhiSyncEntity.spaceClientTag(uuid))] = 1
        }
        defaults.set(try Phi_PhiSettingEntity().serializedData(),
                     forKey: PhiSyncEngine.lastEntityStateKey)
    }

    private func markerStore(marker: String?) -> MemoryMarkerStore {
        MemoryMarkerStore(file: PhiSyncMarkerFile(marker: marker.map { Data($0.utf8) },
                                                  storeBirthday: "birthday-1"))
    }

    private func makeEngine(client: FakePhiSyncClient,
                            markerStore: any PhiSyncMarkerStore,
                            spaceStore: any PhiSpaceSyncStateStore,
                            ownedKinds: [OwnedKindRegistration]) -> PhiSyncEngine {
        PhiSyncEngine(domainKeys: StubDomainKeys(key: key), client: client,
                      defaults: defaults, deviceKeyId: "devA", settings: [],
                      spaceAccess: makeSpaceAccess(), spaceStore: spaceStore,
                      markerStore: markerStore, ownedKinds: ownedKinds,
                      now: { Self.now })
    }

    private func ruleTag(_ uuid: String) -> String { PhiSyncEntity.urlRuleClientTag(uuid) }

    private func ruleHash(_ uuid: String) -> String {
        PhiSyncEntity.clientTagHash(for: ruleTag(uuid))
    }

    private func ruleEntity(_ payload: Phi_PhiURLRuleEntity, version: Int64) -> PhiRemoteEntity {
        remoteEntity(envelope(payload), tag: ruleTag(payload.ruleUuid), version: version,
                     entityId: "srv-\(payload.ruleUuid)", key: key)
    }

    /// Remote entity with all three stamps set to remoteStamp; see file header.
    private func remote(uuid: String, target: String = "su-1", host: String = "github.com",
                        pathPrefix: String = "", rank: String = "V") -> Phi_PhiURLRuleEntity {
        urlRulePayload(uuid: uuid, targetSpaceUuid: target, host: host, pathPrefix: pathPrefix,
                       rank: rank, contentStamp: Self.remoteStamp, targetStamp: Self.remoteStamp,
                       rankStamp: Self.remoteStamp)
    }

    private func ruleCommits(_ client: FakePhiSyncClient) -> [FakePhiSyncClient.CommitCall] {
        client.commits.filter { $0.name == PhiSyncEntity.urlRuleEntityName }
    }

    /// Live published cursor with equal server/reconciled, server metadata and known ownership.
    private func publishedRuleCursor(_ payload: Phi_PhiURLRuleEntity,
                                     entityId: String = "srv-1", version: Int64 = 1,
                                     owner: String = "su-1") -> PhiOwnedItemCursor {
        ownedCursor(reconciled: baselineBytes(payload), server: baselineBytes(payload),
                    entityId: entityId, version: version, ownerUuid: owner)
    }

    private func createCount(_ ops: [URLRuleSyncOp]) -> Int {
        ops.filter { if case .create = $0 { return true } else { return false } }.count
    }

    private func rekeyCount(_ ops: [URLRuleSyncOp]) -> Int {
        ops.filter { if case .rekey = $0 { return true } else { return false } }.count
    }

    private func claimNotes(_ access: FakeURLRuleAccess) -> [Int] {
        access.calls.compactMap { if case .notePersistedClaims(let count) = $0 { return count } else { return nil } }
    }

    private func counters(_ engine: PhiSyncEngine) async -> OwnedRoundCounters? {
        await engine.lastOwnedRoundCountersForTesting["urlrules"]
    }

    private func isAtRest(_ row: PhiLocalURLRule, _ cursor: PhiOwnedItemCursor?,
                          tombstones: Set<String> = []) -> Bool {
        URLRuleKind.isAtRest(row: row, cursor: cursor, resolve: resolve, normalize: normalize,
                             tombstonesThisPage: tombstones)
    }

    // MARK: - CASE M-1 (initial-sync adoption)

    /// Delete-then-create would temporarily remove identity or duplicate the row; §5.7 diff tombstones an
    /// identity with a cursor but no local row.
    func testM1_firstSyncClaimsTheLocalRowByReKeyingIt() async throws {
        let access = FakeURLRuleAccess(rows: [.fixture(id: "i1", syncId: "local-a", host: "github.com")])
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([ruleEntity(remote(uuid: "remote-b"), version: 7)], marker: "7")]
        let engine = makeEngine(client: client, markerStore: markerStore(marker: "0"),
                                spaceStore: try drainedSpaceStore(),
                                ownedKinds: [.urlRules(access: access, store: store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        // ① Rekey the existing row without changing id or creating another row.
        XCTAssertEqual(access.rows.count, 1)
        XCTAssertEqual(access.rows.first?.id, "i1")
        XCTAssertEqual(access.rows.first?.syncId, "remote-b")
        XCTAssertEqual(rekeyCount(access.lastAppliedOps), 1)
        XCTAssertEqual(createCount(access.lastAppliedOps), 0)
        // ② Remove the old cursor completely; the new identity has baseline and server metadata.
        XCTAssertNil(store.table.cursors["local-a"])
        XCTAssertNotNil(store.table.cursors["remote-b"]?.reconciled)
        XCTAssertEqual(store.table.cursors["remote-b"]?.entityId, "srv-remote-b")
        XCTAssertEqual(store.table.cursors["remote-b"]?.version, 7)
        // ③
        let first = await counters(engine)
        XCTAssertEqual(first?.adopted, 1)
        XCTAssertEqual(first?.applied, 1)
        XCTAssertTrue(ruleCommits(client).isEmpty, "Remote wins all three units; nothing needs republication")

        // ④ Another round produces no pushes or tombstones.
        await engine.pullOnce()
        let second = await counters(engine)
        XCTAssertEqual(second?.pushed, 0)
        XCTAssertEqual(second?.tombstones, 0)
        XCTAssertTrue(ruleCommits(client).isEmpty)
        XCTAssertEqual(access.rows.first?.syncId, "remote-b")
    }

    /// ⑤ One transaction: landing failure preserves old syncId and old cursor state (absent here), while the
    /// new identity parks without baseline. Deleting the old cursor before landing would leave an unchanged
    /// row without its cursor and permit blind baseVersion 0 publication. Retry parking through the same
    /// arrivals ∪ parked adoption domain and converge to ①.
    func testM1_aFailedLandingLeavesTheRowOnItsOldIdentityAndWritesNoBaseline() async throws {
        let access = FakeURLRuleAccess(rows: [.fixture(id: "i1", syncId: "local-a", host: "github.com")])
        access.failApplyOnce = true
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([ruleEntity(remote(uuid: "remote-b"), version: 7)], marker: "7")]
        let engine = makeEngine(client: client, markerStore: markerStore(marker: "0"),
                                spaceStore: try drainedSpaceStore(),
                                ownedKinds: [.urlRules(access: access, store: store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertEqual(access.rows.count, 1)
        XCTAssertEqual(access.rows.first?.syncId, "local-a")
        XCTAssertNil(store.table.cursors["local-a"], "Never existed and was not created")
        XCTAssertNil(store.table.cursors["remote-b"]?.reconciled, "No baseline")
        XCTAssertNotNil(store.table.cursors["remote-b"]?.pendingApply, "Park the whole batch")
        let first = await counters(engine)
        XCTAssertEqual(first?.parked, 1)
        XCTAssertEqual(first?.applied, 0)

        await engine.pullOnce()
        XCTAssertEqual(access.rows.count, 1)
        XCTAssertEqual(access.rows.first?.id, "i1")
        XCTAssertEqual(access.rows.first?.syncId, "remote-b", "Parking retry uses the same adoption path")
        XCTAssertNotNil(store.table.cursors["remote-b"]?.reconciled)
        XCTAssertNil(store.table.cursors["remote-b"]?.pendingApply)
        let second = await counters(engine)
        XCTAssertEqual(second?.adopted, 1)
    }

    // MARK: - CASE M-2 (baseline prevents adoption)

    /// Checking only cursor absence could rekey a published row and delete its baseline-bearing old cursor,
    /// leaving an undeletable account orphan. 8b-2 adds assertion ③: when both rows become still in round two,
    /// soft-delete the larger syncId and count collapsed 1; the initial 8b-1 case covers ①/②.
    func testM2_aRowWithABaselineIsNotClaimable() async throws {
        let access = FakeURLRuleAccess(rows: [.fixture(id: "i1", syncId: "local-a", host: "github.com")])
        let store = MemoryOwnedItemStore()
        let published = urlRulePayload(uuid: "local-a")
        store.table.cursors["local-a"] = publishedRuleCursor(published, entityId: "e-a", version: 3)
        let client = FakePhiSyncClient()
        // Seed the actual account entity so fake updates can match entityId/baseVersion.
        client.seed(tagHash: ruleHash("local-a"), ciphertext: Data(), version: 3, entityId: "e-a")
        client.pagesByMarker = [page([ruleEntity(remote(uuid: "remote-b", rank: "W"), version: 7)],
                                     marker: "7")]
        let engine = makeEngine(client: client, markerStore: markerStore(marker: "0"),
                                spaceStore: try drainedSpaceStore(),
                                ownedKinds: [.urlRules(access: access, store: store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        // ① First round: no adoption; inbound entity lands as a second row.
        let first = await counters(engine)
        XCTAssertEqual(first?.adopted, 0)
        XCTAssertEqual(access.rows.count, 2)
        XCTAssertEqual(access.rows.first { $0.id == "i1" }?.syncId, "local-a")
        XCTAssertEqual(createCount(access.lastAppliedOps), 1)
        XCTAssertEqual(rekeyCount(access.lastAppliedOps), 0)
        // ② The newly landed identity's cursor persists only after land returns, so stillness predicate 1 is
        // false this round (R-M3-4a-67).
        XCTAssertEqual(first?.collapsed, 0)
        // ④ Preserve the published entity's entire cursor and baseline instead of deleting it as an old
        // adoption cursor.
        XCTAssertEqual(store.table.cursors["local-a"]?.entityId, "e-a")
        XCTAssertNotNil(store.table.cursors["local-a"]?.reconciled)
        XCTAssertNil(store.table.cursors["local-a"]?.deletedAtMs)

        await engine.pullOnce()
        // ③ 8b-2: both rows are still next round; larger remote-b is soft-deleted with collapsed 1, while
        // published winner local-a stays unchanged.
        let second = await counters(engine)
        XCTAssertEqual(second?.collapsed, 1)
        XCTAssertNil(store.table.cursors["local-a"]?.deletedAtMs, "The winner's cursor is unchanged")
        XCTAssertNil(access.rows.first { $0.syncId == "local-a" }?.deletedDate)
        XCTAssertNotNil(access.rows.first { $0.syncId == "remote-b" }?.deletedDate, "The loser is soft-deleted")
        XCTAssertEqual(access.rows.first { $0.syncId == "remote-b" }?.mergePartnerSyncId, "local-a")
        XCTAssertEqual(access.rows.filter { $0.deletedDate == nil }.count, 1, "One live row after convergence")
    }

    // MARK: - CASE M-2b (birthday-reset cursors cannot be adopted)

    /// entityId empty plus server nil is insufficient: birthday reset retains reconciled, and every reset
    /// cursor would otherwise become adoptable and lose its baseline. This mirrors R-exec-13 rekey
    /// eligibility. Throw on page 2 to stop before legitimate publication-side rekey harvest obscures the
    /// unchanged adoption prepass assertion.
    func testM2b_aBirthdayResetCursorIsNotClaimable() async throws {
        let access = FakeURLRuleAccess(rows: [.fixture(id: "i1", syncId: "local-a", host: "github.com")])
        let store = MemoryOwnedItemStore()
        let reset = ownedCursor(reconciled: baselineBytes(urlRulePayload(uuid: "local-a")),
                                ownerUuid: "su-1")
        XCTAssertEqual(reset.entityId, "")
        XCTAssertEqual(reset.version, 0)
        XCTAssertNil(reset.server)
        store.table.cursors["local-a"] = reset
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([ruleEntity(remote(uuid: "remote-b", rank: "W"), version: 7)],
                                     marker: "7", changesRemaining: true)]
        client.getUpdatesErrorAfterPages = (pages: 1, error: Boom())
        let engine = makeEngine(client: client, markerStore: markerStore(marker: "0"),
                                spaceStore: try drainedSpaceStore(),
                                ownedKinds: [.urlRules(access: access, store: store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let first = await counters(engine)
        XCTAssertEqual(first?.adopted, 0)
        XCTAssertEqual(store.table.cursors["local-a"], reset, "Unchanged byte for byte")
        XCTAssertEqual(access.rows.first { $0.id == "i1" }?.syncId, "local-a")
        XCTAssertEqual(access.rows.count, 2, "The inbound entity lands as a second row")
        XCTAssertEqual(rekeyCount(access.lastAppliedOps), 0)
    }

    // MARK: - CASE M-8 (signatures compare normalized values)

    /// Raw-byte signatures would split equivalent rules; missing conversion between wire empty path and local
    /// nil must also fail this case.
    func testM8_signaturesCompareNormalizedValues() async throws {
        let access = FakeURLRuleAccess(rows: [
            .fixture(id: "i1", syncId: "local-a", host: "GitHub.com.", pathPrefix: nil),
        ])
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([ruleEntity(remote(uuid: "remote-b", host: "github.com",
                                                        pathPrefix: ""), version: 7)],
                                     marker: "7")]
        let engine = makeEngine(client: client, markerStore: markerStore(marker: "0"),
                                spaceStore: try drainedSpaceStore(),
                                ownedKinds: [.urlRules(access: access, store: store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let first = await counters(engine)
        XCTAssertEqual(first?.adopted, 1)
        XCTAssertEqual(access.rows.count, 1)
        XCTAssertEqual(access.rows.first?.syncId, "remote-b")
        XCTAssertEqual(access.rows.first?.host, "github.com", "Landing writes normalized values")
    }

    /// Same-batch negative control: identical paths with different targets conflict rather than duplicate.
    /// Retain both rows for §9 arbitration.
    func testM8_aDifferentTargetIsAConflictNotADuplicate() async throws {
        let access = FakeURLRuleAccess(rows: [
            .fixture(id: "i1", syncId: "local-a", host: "GitHub.com.", pathPrefix: nil),
        ])
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([ruleEntity(remote(uuid: "remote-b", target: "su-2",
                                                        host: "github.com"), version: 7)],
                                     marker: "7")]
        let engine = makeEngine(client: client, markerStore: markerStore(marker: "0"),
                                spaceStore: try drainedSpaceStore(),
                                ownedKinds: [.urlRules(access: access, store: store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let first = await counters(engine)
        XCTAssertEqual(first?.adopted, 0)
        XCTAssertEqual(access.rows.filter { $0.deletedDate == nil }.count, 2)
        XCTAssertEqual(access.rows.first { $0.id == "i1" }?.syncId, "local-a")
        XCTAssertEqual(access.rows.first { $0.syncId == "remote-b" }?.spaceId, "space-b")
    }

    // MARK: - CASE M-8b (signature ownership is account-global)

    /// Keying signatureIndex by local spaceId would never match account keys in the first case; excluding
    /// reserved constants fails the second.
    func testM8b_signatureOwnerIsTheAccountLevelUuid() async throws {
        let access = FakeURLRuleAccess(rows: [.fixture(id: "i1", syncId: "local-a", spaceId: "space-a")])
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([ruleEntity(remote(uuid: "remote-b", target: "su-1"), version: 7)],
                                     marker: "7")]
        let engine = makeEngine(client: client, markerStore: markerStore(marker: "0"),
                                spaceStore: try drainedSpaceStore(),
                                ownedKinds: [.urlRules(access: access, store: store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let first = await counters(engine)
        XCTAssertEqual(first?.adopted, 1)
        XCTAssertEqual(access.rows.count, 1)
        XCTAssertEqual(access.rows.first?.syncId, "remote-b")
    }

    func testM8b_theReservedIncognitoConstantIsASignatureOwnerToo() async throws {
        let access = FakeURLRuleAccess(rows: [
            .fixture(id: "i1", syncId: "local-a", spaceId: SpaceManager.incognitoRuleTargetId),
        ])
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([ruleEntity(remote(uuid: "remote-b",
                                                        target: SyncableSpaces.incognitoSpaceUuid),
                                                 version: 7)],
                                     marker: "7")]
        let engine = makeEngine(client: client, markerStore: markerStore(marker: "0"),
                                spaceStore: try drainedSpaceStore(),
                                ownedKinds: [.urlRules(access: access, store: store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let first = await counters(engine)
        XCTAssertEqual(first?.adopted, 1)
        XCTAssertEqual(access.rows.count, 1)
        XCTAssertEqual(access.rows.first?.syncId, "remote-b")
        XCTAssertEqual(access.rows.first?.spaceId, SpaceManager.incognitoRuleTargetId)
    }

    // MARK: - CASE M-9 (parked, pending-delete, rekey and pending-tombstone members are not still)

    /// Missing predicate 5 could select a winner with pending remote deletion, tombstone absorbed losers, then
    /// lose the winner too, emptying the signature group everywhere. Missing predicate 9 could eliminate a
    /// rekey candidate. collapsed assertions belong to 8b-2.
    func testM9_parkedPendingDeleteUnkeyedAndPendingTombstoneMembersAreNotAtRest() {
        let a = PhiLocalURLRule.fixture(id: "ia", syncId: "a", sortOrder: 0)
        let b = PhiLocalURLRule.fixture(id: "ib", syncId: "b", sortOrder: 1)
        let cursorA = publishedRuleCursor(urlRulePayload(uuid: "a"), entityId: "srv-a")
        let baseB = publishedRuleCursor(urlRulePayload(uuid: "b", rank: "W"), entityId: "srv-b")
        XCTAssertTrue(isAtRest(a, cursorA))
        XCTAssertTrue(isAtRest(b, baseB), "Baseline: both rows are still")

        var parked = baseB
        parked.pendingApply = Data([0x01])
        var pendingDelete = baseB
        pendingDelete.pendingDelete = true
        var unkeyed = baseB
        unkeyed.entityId = ""
        var pendingTombstone = baseB
        pendingTombstone.pendingTombstone = true

        for (label, variant) in [("(a) pendingApply", parked), ("(b) pendingDelete", pendingDelete),
                                 ("(c) Rekey state", unkeyed), ("(d) pendingTombstone", pendingTombstone)] {
            XCTAssertTrue(isAtRest(a, cursorA), label)
            XCTAssertFalse(isAtRest(b, variant), label)
        }
        // In (c), b still meets PhiSyncEngine's unkeyed candidate predicate; rekey remains active.
        XCTAssertTrue(unkeyed.entityId.isEmpty && unkeyed.reconciled != nil
                      && unkeyed.deletedAtMs == nil && unkeyed.pendingApply == nil
                      && !unkeyed.pendingDelete && (unkeyed.rekeyRejectRounds ?? 0) < 3)
    }

    // MARK: - CASE M-11 (V11 backfill and two devices' initial sync)

    /// Putting M1 behind ownedItemsPublishAllowed fails adoption during initial drain, where that gate is
    /// false. §12.2 step 13d describes the resulting adopted 0 and four rules. This also validates D30(a)
    /// through the real upgrade path.
    func testM11_aFreshDeviceClaimsAllThreeBackfilledRowsDuringItsFirstDrain() async throws {
        let access = FakeURLRuleAccess(rows: [
            .fixture(id: "i1", syncId: "local-1", host: "a.example", sortOrder: 0),
            .fixture(id: "i2", syncId: "local-2", host: "b.example", sortOrder: 1),
            .fixture(id: "i3", syncId: "local-3", host: "c.example", sortOrder: 2),
        ])
        let store = MemoryOwnedItemStore()
        // Initial drain: hasDrainedFullReplay false; setSpaceSyncEnabled(true) arms drain.
        let spaceStore = MemorySpaceStore()
        try silenceOtherSections(spaceStore)
        let client = FakePhiSyncClient()
        let arrivals = [remote(uuid: "acc-1", host: "a.example", rank: "V"),
                        remote(uuid: "acc-2", host: "b.example", rank: "W"),
                        remote(uuid: "acc-3", host: "c.example", rank: "X")]
        for (offset, entity) in arrivals.enumerated() {
            client.seed(tagHash: ruleHash(entity.ruleUuid), ciphertext: Data(), version: Int64(offset + 1),
                        entityId: "srv-\(entity.ruleUuid)")
        }
        client.pagesByMarker = [page(arrivals.enumerated().map { ruleEntity($1, version: Int64($0 + 1)) },
                                     marker: "3")]
        let engine = makeEngine(client: client, markerStore: markerStore(marker: "0"),
                                spaceStore: spaceStore,
                                ownedKinds: [.urlRules(access: access, store: store)])
        await engine.setSpaceSyncEnabled(true)
        XCTAssertFalse(spaceStore.table.hasDrainedFullReplay, "Adoption runs before drain completes")
        await engine.pullOnce()

        let first = await counters(engine)
        XCTAssertEqual(first?.adopted, 3)
        XCTAssertEqual(access.rows.count, 3)
        XCTAssertEqual(access.rows.first { $0.id == "i1" }?.syncId, "acc-1")
        XCTAssertEqual(access.rows.first { $0.id == "i2" }?.syncId, "acc-2")
        XCTAssertEqual(access.rows.first { $0.id == "i3" }?.syncId, "acc-3")
        for retired in ["local-1", "local-2", "local-3"] {
            XCTAssertNil(store.table.cursors[retired], "Old cursor \(retired) is completely absent")
        }
        for adopted in ["acc-1", "acc-2", "acc-3"] {
            XCTAssertNotNil(store.table.cursors[adopted]?.reconciled)
        }
        XCTAssertEqual(first?.pushed, 0)
        XCTAssertEqual(first?.tombstones, 0)

        await engine.pullOnce()
        let second = await counters(engine)
        XCTAssertEqual(second?.pushed, 0)
        XCTAssertEqual(second?.tombstones, 0)
        XCTAssertTrue(ruleCommits(client).isEmpty)
        XCTAssertEqual(client.stored.count, 3, "Exactly three account entities")
        XCTAssertTrue(client.stored.values.allSatisfy { !$0.deleted })
    }

    // MARK: - CASE M-13 (one-to-one pairing)

    /// Without one-to-one matching, two claims rekey the same row and the second guard fails, rolling
    /// back/parking the entire batch. Replaying the same page would fail indefinitely and prevent B-2 marker
    /// advancement.
    func testM13_twoSameSignatureArrivalsClaimOneRowAndCreateTheOther() async throws {
        let access = FakeURLRuleAccess(rows: [.fixture(id: "i1", syncId: "local-a")])
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        let marker = markerStore(marker: "0")
        client.pagesByMarker = [page([ruleEntity(remote(uuid: "r-2", rank: "W"), version: 6),
                                      ruleEntity(remote(uuid: "r-1", rank: "V"), version: 7)],
                                     marker: "7")]
        let engine = makeEngine(client: client, markerStore: marker,
                                spaceStore: try drainedSpaceStore(),
                                ownedKinds: [.urlRules(access: access, store: store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let first = await counters(engine)
        XCTAssertEqual(first?.adopted, 1)
        XCTAssertEqual(access.rows.first { $0.id == "i1" }?.syncId, "r-1", "Lexicographically first")
        XCTAssertEqual(access.rows.count, 2)
        XCTAssertNotNil(access.rows.first { $0.syncId == "r-2" }, "The other entity lands as a second row")
        XCTAssertEqual(rekeyCount(access.lastAppliedOps), 1)
        XCTAssertEqual(createCount(access.lastAppliedOps), 1)
        XCTAssertEqual(first?.refused, 0, "No errors thrown")
        XCTAssertEqual(first?.parked, 0)
        XCTAssertEqual(first?.applied, 2)
        XCTAssertEqual(marker.file.marker, Data("7".utf8), "Marker advances normally")
    }

    /// Symmetric case: one arrival and two adoptable rows choose the smaller local syncId, leaving the other
    /// untouched.
    func testM13_oneArrivalAgainstTwoClaimableRowsClaimsTheFirstBySyncId() async throws {
        let access = FakeURLRuleAccess(rows: [
            .fixture(id: "i2", syncId: "local-b", sortOrder: 0),
            .fixture(id: "i1", syncId: "local-a", sortOrder: 1),
        ])
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([ruleEntity(remote(uuid: "r-1"), version: 7)], marker: "7")]
        let engine = makeEngine(client: client, markerStore: markerStore(marker: "0"),
                                spaceStore: try drainedSpaceStore(),
                                ownedKinds: [.urlRules(access: access, store: store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let first = await counters(engine)
        XCTAssertEqual(first?.adopted, 1)
        XCTAssertEqual(access.rows.count, 2)
        XCTAssertEqual(access.rows.first { $0.id == "i1" }?.syncId, "r-1", "`local-a` < `local-b`")
        let other = access.rows.first { $0.id == "i2" }
        XCTAssertEqual(other?.syncId, "local-b")
        XCTAssertEqual(other?.id, "i2")
        XCTAssertNil(store.table.cursors["local-a"])
        XCTAssertNil(store.table.cursors["local-b"], "The unclaimed row had no cursor and none was created")
    }

    // MARK: - CASE M-14 (rows without signatures remain inert)

    /// Never replace nil owner with empty string or local spaceId. Checking only the first gate gives case (c)
    /// a signature despite exclusion from snapshots.
    func testM14_rowsWithoutASignatureAreInert() async throws {
        // (a) Two unmapped agent Spaces yield nil eligibilityOwner; (b) expired incognito runtime ID
        // (R-M3-4a-8).
        let stale = SpaceManager.incognitoRuleTargetId + ".stale-runtime"
        let segments: [(label: String, rows: [PhiLocalURLRule])] = [
            ("(a) agent", [.fixture(id: "i1", syncId: "local-a", spaceId: "agent-space-1"),
                           .fixture(id: "i2", syncId: "local-b", spaceId: "agent-space-2")]),
            ("(b) stale incognito", [.fixture(id: "i1", syncId: "local-a", spaceId: stale),
                                     .fixture(id: "i2", syncId: "local-b", spaceId: "agent-space-2")]),
        ]
        for segment in segments {
            for row in segment.rows {
                XCTAssertNil(URLRuleKind.signature(of: row, resolve: resolve, normalize: normalize),
                             segment.label)
            }
            let access = FakeURLRuleAccess(rows: segment.rows)
            let store = MemoryOwnedItemStore()
            let client = FakePhiSyncClient()
            client.pagesByMarker = [page([ruleEntity(remote(uuid: "remote-b"), version: 7)], marker: "7")]
            let engine = makeEngine(client: client, markerStore: markerStore(marker: "0"),
                                    spaceStore: try drainedSpaceStore(),
                                    ownedKinds: [.urlRules(access: access, store: store)])
            await engine.setSpaceSyncEnabled(true)
            await engine.pullOnce()

            let first = await counters(engine)
            XCTAssertEqual(first?.adopted, 0, segment.label)
            XCTAssertEqual(first?.collapsed, 0, segment.label)
            XCTAssertEqual(access.rows.first { $0.id == "i1" }?.syncId, "local-a", segment.label)
            XCTAssertEqual(access.rows.first { $0.id == "i2" }?.syncId, "local-b", segment.label)
            XCTAssertTrue(access.rows.allSatisfy { $0.deletedDate == nil }, segment.label)
        }
    }

    /// (c) Hidden local Space retains mapping: localSpaceId resolves but isEligibleSpace is false. The second
    /// gate makes signature nil and snapshot increments skippedIneligibleOwner.
    func testM14c_aHiddenTargetFailsTheSecondGateAndStaysOutOfTheSnapshot() async throws {
        let rows: [PhiLocalURLRule] = [.fixture(id: "i1", syncId: "local-a", spaceId: "space-a"),
                                       .fixture(id: "i2", syncId: "local-b", spaceId: "space-b")]
        let hidden = OwnerResolver.fixture(ineligible: ["su-1"])
        XCTAssertNotNil(hidden.localSpaceId("su-1"), "The mapping remains")
        XCTAssertNil(URLRuleKind.signature(of: rows[0], resolve: hidden, normalize: normalize))
        XCTAssertNotNil(URLRuleKind.signature(of: rows[1], resolve: hidden, normalize: normalize))
        let snapshot = SyncableOwnedItems.snapshot(URLRuleKind.self, locals: rows,
                                                   table: PhiOwnedItemTable(), resolve: hidden,
                                                   scope: nil, now: Self.now)
        XCTAssertEqual(snapshot.skippedIneligibleOwner, 1)
        XCTAssertNil(snapshot.entities["local-a"])
        XCTAssertNotNil(snapshot.entities["local-b"])

        let access = FakeURLRuleAccess(rows: rows)
        let store = MemoryOwnedItemStore()
        let spaceStore = try drainedSpaceStore()
        var cursor = PhiSpaceCursor()
        cursor.entityId = "srv-space-1"
        cursor.version = 4
        cursor.hidden = true
        cursor.deletedAtMs = 1
        spaceStore.table.cursors["su-1"] = cursor
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([ruleEntity(remote(uuid: "remote-b", target: "su-1"), version: 7)],
                                     marker: "7")]
        let engine = makeEngine(client: client, markerStore: markerStore(marker: "0"),
                                spaceStore: spaceStore,
                                ownedKinds: [.urlRules(access: access, store: store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let first = await counters(engine)
        XCTAssertEqual(first?.adopted, 0)
        XCTAssertEqual(first?.collapsed, 0)
        XCTAssertEqual(access.rows.first { $0.id == "i1" }?.syncId, "local-a")
        XCTAssertEqual(access.rows.first { $0.id == "i2" }?.syncId, "local-b")
        XCTAssertTrue(access.rows.allSatisfy { $0.deletedDate == nil })
        XCTAssertEqual(rekeyCount(access.lastAppliedOps), 0)
    }

    // MARK: - CASE M-18 (adoption on page 1, diff after page 2)

    /// Frozen entry projections would cause both erroneous publications in ② and delete the newly adopted
    /// account identity. This end-to-end case covers per-page reread and both in-place refresh sites.
    func testM18_aClaimOnPageOneIsVisibleToPageTwoAndToTheEndOfRoundDiff() async throws {
        let access = FakeURLRuleAccess(rows: [.fixture(id: "i1", syncId: "local-a")])
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.pagesByMarker = [
            page([ruleEntity(remote(uuid: "remote-b"), version: 7)], marker: "7", changesRemaining: true),
            page([], marker: "9"),
        ]
        let engine = makeEngine(client: client, markerStore: markerStore(marker: "0"),
                                spaceStore: try drainedSpaceStore(),
                                ownedKinds: [.urlRules(access: access, store: store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let pages = await engine.lastRoundPagesForTesting
        XCTAssertEqual(pages, 2)
        let first = await counters(engine)
        XCTAssertEqual(first?.adopted, 1)
        // ② Publication uses refreshed rows: old syncId is not recreated as cursorless, and new identity is
        // not treated as baseline-bearing but locally absent.
        XCTAssertEqual(first?.pushed, 0)
        XCTAssertEqual(first?.tombstones, 0)
        XCTAssertTrue(ruleCommits(client).isEmpty)
        XCTAssertEqual(access.rows.count, 1)
        XCTAssertEqual(access.rows.first?.syncId, "remote-b")
        XCTAssertEqual(claimNotes(access), [1], "The in-place refresh entry point ran exactly once")
        XCTAssertNil(store.table.cursors["local-a"])
        XCTAssertNotNil(store.table.cursors["remote-b"]?.reconciled)
    }

    /// Cross-page adoption variant: two same-signature arrivals across two pages and one adoptable row yield
    /// adopted 1, then a second created row without errors and normal marker advancement. Reusing the entry
    /// signature index would rekey the claimed row again and roll back page 2.
    func testM18_aSecondSameSignatureArrivalOnPageTwoDoesNotReKeyTheRowAgain() async throws {
        let access = FakeURLRuleAccess(rows: [.fixture(id: "i1", syncId: "local-a")])
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        let marker = markerStore(marker: "0")
        client.pagesByMarker = [
            page([ruleEntity(remote(uuid: "remote-b", rank: "V"), version: 7)], marker: "7",
                 changesRemaining: true),
            page([ruleEntity(remote(uuid: "remote-c", rank: "W"), version: 9)], marker: "9"),
        ]
        let engine = makeEngine(client: client, markerStore: marker,
                                spaceStore: try drainedSpaceStore(),
                                ownedKinds: [.urlRules(access: access, store: store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let first = await counters(engine)
        XCTAssertEqual(first?.adopted, 1)
        XCTAssertEqual(first?.refused, 0, "Landing throws no errors")
        XCTAssertEqual(first?.parked, 0)
        XCTAssertEqual(first?.applied, 2)
        XCTAssertEqual(access.rows.count, 2)
        XCTAssertEqual(access.rows.first { $0.id == "i1" }?.syncId, "remote-b")
        XCTAssertNotNil(access.rows.first { $0.syncId == "remote-c" })
        XCTAssertEqual(createCount(access.lastAppliedOps), 1, "The page-2 entity uses create")
        XCTAssertEqual(rekeyCount(access.lastAppliedOps), 0, "Page 2 performs no second rekey")
        XCTAssertEqual(marker.file.marker, Data("9".utf8))
        XCTAssertEqual(first?.pushed, 0)
        XCTAssertEqual(first?.tombstones, 0)
    }

    // MARK: - CASE M-20 (engine rekey never sets pendingLocalEdit)

    /// Setting pendingLocalEdit during adoption would make it yield to the next remote deletion (§8.4.4);
    /// clearing a pre-existing bit would lose a genuine unpublished user edit. Task 9 / 8b-4 cover user
    /// deletion and Space cascade counterparts.
    func testM20_reKeyNeverSetsThePendingLocalEditFlag() async throws {
        let access = FakeURLRuleAccess(rows: [
            .fixture(id: "i1", syncId: "local-a", pendingLocalEdit: false),
        ])
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([ruleEntity(remote(uuid: "remote-b"), version: 7)], marker: "7")]
        let engine = makeEngine(client: client, markerStore: markerStore(marker: "0"),
                                spaceStore: try drainedSpaceStore(),
                                ownedKinds: [.urlRules(access: access, store: store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let row = access.rows.first { $0.id == "i1" }
        XCTAssertEqual(row?.syncId, "remote-b")
        XCTAssertEqual(row?.pendingLocalEdit, false, "Rekey, merged-field landing, renumbering and normalization do not set pending")
    }

    func testM20_reKeyNeitherClearsAPendingLocalEditNorTouchesTheMergePartner() async throws {
        let access = FakeURLRuleAccess(rows: [
            .fixture(id: "i1", syncId: "local-a", pendingLocalEdit: true, mergePartnerSyncId: "w"),
        ])
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([ruleEntity(remote(uuid: "remote-b"), version: 7)], marker: "7")]
        let engine = makeEngine(client: client, markerStore: markerStore(marker: "0"),
                                spaceStore: try drainedSpaceStore(),
                                ownedKinds: [.urlRules(access: access, store: store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let first = await counters(engine)
        XCTAssertEqual(first?.adopted, 1)
        let row = access.rows.first { $0.id == "i1" }
        XCTAssertEqual(row?.syncId, "remote-b")
        XCTAssertEqual(row?.pendingLocalEdit, true, "Preserve the flag; only §8.4.5's two paths clear it (8b-4)")
        XCTAssertEqual(row?.mergePartnerSyncId, "w", "RR10-8: rekey leaves this column unchanged")
    }

    // MARK: - CASE M-28 (one negative case per stillness predicate)

    /// Predicate 10 is added by R-M3-4a-86; predicates 5 and 10 protect two remote-deletion timings. Missing
    /// either can empty a signature group on both devices and account. Nil syncId must never be
    /// force-unwrapped.
    func testM28_everyOneOfTheTenConjunctsIsIndividuallyFalsifiable() throws {
        let r = PhiLocalURLRule.fixture(id: "ir", syncId: "r", spaceId: "space-a")
        var base = publishedRuleCursor(urlRulePayload(uuid: "r"), entityId: "e", version: 2)
        base.deletedAtMs = nil
        XCTAssertTrue(isAtRest(r, base), "Baseline: all ten predicates hold")

        func cursor(_ mutate: (inout PhiOwnedItemCursor) -> Void) -> PhiOwnedItemCursor {
            var out = base
            mutate(&out)
            return out
        }
        // Predicates 1–5 and 9: toggle one cursor field at a time.
        XCTAssertFalse(isAtRest(r, cursor { $0.server = nil }), "1 Published")
        XCTAssertFalse(isAtRest(r, cursor { $0.server = Data([0x01]) }), "2 server == reconciled")
        XCTAssertFalse(isAtRest(r, cursor { $0.pendingApply = Data() }), "3 pendingApply")
        XCTAssertFalse(isAtRest(r, cursor { $0.pendingDelete = true }), "4 pendingDelete")
        XCTAssertFalse(isAtRest(r, cursor { $0.pendingTombstone = true }), "5 pendingTombstone")
        XCTAssertFalse(isAtRest(r, cursor { $0.entityId = "" }), "9 Rekey state with reconciled retained")
        XCTAssertFalse(isAtRest(r, nil), "1 No cursor")
        // Predicates 6/7: toggle one row field at a time.
        var pendingEdit = r
        pendingEdit.pendingLocalEdit = true
        XCTAssertFalse(isAtRest(pendingEdit, base), "6 pendingLocalEdit")
        var deleted = r
        deleted.deletedDate = Date()
        XCTAssertFalse(isAtRest(deleted, base), "7 deletedDate")
        // Predicate 8: agent-Space target gives nil eligibilityOwner.
        var agent = r
        agent.spaceId = "agent-space"
        XCTAssertFalse(isAtRest(agent, base), "8 No signature")
        // Predicate 10: this page contains its tombstone.
        XCTAssertFalse(isAtRest(r, base, tombstones: ["r"]), "10 tombstonesThisPage")
        // Precondition: never force-unwrap a row's nil syncId.
        var unkeyedRow = r
        unkeyedRow.syncId = nil
        XCTAssertFalse(isAtRest(unkeyedRow, base), "syncId == nil")

        // (a) mergePartners returns X with mergePartnerSyncId r for the base case, excluding it under variants
        // 5/10.
        let x = PhiLocalURLRule.fixture(id: "ix", syncId: "x", host: "other.example",
                                        mergePartnerSyncId: "r")
        let access = FakeURLRuleAccess(rows: [r, x])
        var table = PhiOwnedItemTable()
        table.cursors["r"] = base
        XCTAssertEqual(access.mergePartners(table: table, resolve: resolve, tombstonesThisPage: []),
                       ["x": "r"])
        var tombstoned = PhiOwnedItemTable()
        tombstoned.cursors["r"] = cursor { $0.pendingTombstone = true }
        XCTAssertEqual(access.mergePartners(table: tombstoned, resolve: resolve, tombstonesThisPage: []),
                       [:], "Variant 5: nonstill W is excluded from this table")
        XCTAssertEqual(access.mergePartners(table: table, resolve: resolve, tombstonesThisPage: ["r"]),
                       [:], "Variant 10: nonstill W is excluded from this table")
        // (b) Variant 10 keeps R in signatureIndex: it changes stillness, not grouping.
        let signature = try XCTUnwrap(URLRuleKind.signature(of: r, resolve: resolve, normalize: normalize))
        XCTAssertEqual(access.signatureIndex(resolve: resolve)[signature]?.map(\.id), ["ir"])
    }

    // MARK: - CASE M-29 (two signature gates and inert-row exclusion)

    /// First-gate-only logic incorrectly indexes (c); passing reserved constants through ordinary
    /// isEligibleSpace excludes (b). Sort members consistently so §8.4.2's lexical first choice agrees across
    /// devices.
    func testM29_bothGatesAndTheGroupOrderOfTheSignatureIndex() throws {
        let hidden = OwnerResolver.fixture(ineligible: ["su-2"])
        let a = PhiLocalURLRule.fixture(id: "i1", syncId: "a", spaceId: "space-a", host: "a.example")
        let b = PhiLocalURLRule.fixture(id: "i2", syncId: "b", spaceId: SpaceManager.incognitoRuleTargetId,
                                        host: "b.example")
        let c = PhiLocalURLRule.fixture(id: "i3", syncId: "c", spaceId: "space-b", host: "c.example")
        let d = PhiLocalURLRule.fixture(id: "i4", syncId: "d", spaceId: "agent-space", host: "d.example")
        let softDeleted = PhiLocalURLRule.fixture(id: "i5", syncId: "e", spaceId: "space-a",
                                                  host: "a.example", deletedDate: Date())
        // Three same-signature rows sort ascending by (syncId ?? empty, id): nil syncId first, then aa before
        // zz.
        let dupZ = PhiLocalURLRule.fixture(id: "i9", syncId: "zz", spaceId: "space-a", host: "dup.example")
        let dupA = PhiLocalURLRule.fixture(id: "i8", syncId: "aa", spaceId: "space-a", host: "dup.example")
        let dupNil = PhiLocalURLRule.fixture(id: "i7", syncId: nil, spaceId: "space-a", host: "dup.example")

        XCTAssertEqual(URLRuleKind.signature(of: a, resolve: hidden, normalize: normalize)?.owner, "su-1")
        XCTAssertEqual(URLRuleKind.signature(of: b, resolve: hidden, normalize: normalize)?.owner,
                       "incognito-space")
        XCTAssertNil(URLRuleKind.signature(of: c, resolve: hidden, normalize: normalize), "(c) Second gate")
        XCTAssertNil(URLRuleKind.signature(of: d, resolve: hidden, normalize: normalize), "(d) First gate")

        let access = FakeURLRuleAccess(rows: [dupZ, a, b, c, d, softDeleted, dupA, dupNil])
        let index = access.signatureIndex(resolve: hidden)
        let indexed = Set(index.values.flatMap { $0 }.map(\.id))
        XCTAssertEqual(indexed, ["i1", "i2", "i7", "i8", "i9"])
        XCTAssertFalse(indexed.contains("i5"), "No soft-deleted rows are included")
        let dup = try XCTUnwrap(URLRuleKind.signature(of: dupA, resolve: hidden, normalize: normalize))
        XCTAssertEqual(index[dup]?.map(\.id), ["i7", "i8", "i9"])
    }

    // MARK: - CASE M-30 (baselineSignature fails closed)

    /// Empty-owner fallback, bypassing gate two or returning an empty signature on decode failure would
    /// wrongly select W in §8.4.4 fallback. Case (e) verifies baseline and current signatures share the same
    /// function.
    func testM30_baselineSignatureFailsClosedAndMatchesTheRowSignature() throws {
        let hidden = OwnerResolver.fixture(ineligible: ["su-2"])
        var table = PhiOwnedItemTable()
        table.cursors["b"] = ownedCursor(server: Data([0x01]))
        table.cursors["c"] = ownedCursor(reconciled: Data("not a protobuf envelope".utf8))
        table.cursors["c2"] = ownedCursor(reconciled: baselineBytes(bookmarkPayload(uuid: "bk")))
        table.cursors["d"] = ownedCursor(reconciled: baselineBytes(
            urlRulePayload(uuid: "d", targetSpaceUuid: "su-2", host: "d.example")))
        table.cursors["e"] = ownedCursor(reconciled: baselineBytes(
            urlRulePayload(uuid: "e", targetSpaceUuid: "su-1", host: "E.example.", pathPrefix: "/docs")))

        func baseline(_ identity: String) -> RuleSignature? {
            URLRuleKind.baselineSignature(identity: identity, table: table, resolve: hidden,
                                          normalize: normalize)
        }
        XCTAssertNil(baseline("a"), "(a) Identity absent")
        XCTAssertNil(baseline("b"), "(b) No reconciled baseline")
        XCTAssertNil(baseline("c"), "(c) Cannot decode Phi_PhiEntity")
        XCTAssertNil(baseline("c2"), "(c) Envelope decodes but is not a rule")
        XCTAssertNil(baseline("d"), "(d) Target is currently hidden")
        let e = try XCTUnwrap(baseline("e"))
        // Signature exactly matches the local row materialized from reconciled.
        let landed = PhiLocalURLRule.fixture(id: "ie", syncId: "e", spaceId: "space-a",
                                             host: "E.example.", pathPrefix: "/docs")
        XCTAssertEqual(URLRuleKind.signature(of: landed, resolve: hidden, normalize: normalize), e)
        XCTAssertEqual(e, RuleSignature(host: "e.example", pathPrefix: "/docs", owner: "su-1"))
    }

    // MARK: - 8b-2 (M2 convergence): fixtures

    /// Convert milliseconds to Date, inverse to URLRuleKind's conversion. This preserves effective account
    /// stamps.
    private func stampDate(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

    /// A still published row and cursor satisfying all ten predicates. accountStamp populates baseline stamps
    /// and intentionally differs from rowContentUpdatedDate. R-M3-4a-94: stillness implies an equal
    /// server/reconciled baseline, not equality of row and baseline stamps; fixtures must support that
    /// distinction.
    @discardableResult
    private func seedSettled(_ syncId: String, id: String,
                             host: String = "github.com", pathPrefix: String? = nil,
                             ask: Bool = false, spaceId: String = "space-a",
                             target: String = "su-1", sortOrder: Int = 0,
                             accountStamp: Int64, rank: String? = nil,
                             rowContentUpdatedDate: Date? = nil,
                             createdDate: Date = Date(timeIntervalSince1970: 1_000),
                             pendingLocalEdit: Bool = false,
                             mergePartnerSyncId: String? = nil,
                             rows: inout [PhiLocalURLRule],
                             table: inout PhiOwnedItemTable) -> PhiLocalURLRule {
        // Distinct ranks must follow sortOrder within a bucket, as stated in the file header. Otherwise
        // snapshots remint ranks and create spurious publication in zero-commit cases.
        let ladder = ["V", "W", "X", "Y", "Z"]
        let payload = urlRulePayload(uuid: syncId, targetSpaceUuid: target, host: host,
                                     pathPrefix: pathPrefix ?? "", ask: ask,
                                     rank: rank ?? ladder[min(max(sortOrder, 0), ladder.count - 1)],
                                     contentStamp: accountStamp, targetStamp: accountStamp,
                                     rankStamp: accountStamp)
        table.cursors[syncId] = publishedRuleCursor(payload, entityId: "srv-\(syncId)", version: 1)
        let row = PhiLocalURLRule.fixture(id: id, syncId: syncId, spaceId: spaceId, host: host,
                                          pathPrefix: pathPrefix, askBeforeRouting: ask,
                                          sortOrder: sortOrder, createdDate: createdDate,
                                          contentUpdatedDate: rowContentUpdatedDate,
                                          pendingLocalEdit: pendingLocalEdit,
                                          mergePartnerSyncId: mergePartnerSyncId)
        rows.append(row)
        return row
    }

    /// mergePass helper; default publishedIdentities uses cursor server != nil per R-M3-4a-95, matching land's
    /// expression.
    private func mergePass(rows: [PhiLocalURLRule], table: PhiOwnedItemTable,
                           atRest: Set<String>, convergeAllowed: Bool = true,
                           landedThisPage: Set<String> = [],
                           published: Set<String>? = nil,
                           preLanding: [String: RuleSignature] = [:],
                           landed: [String: URLRuleLandingValues] = [:],
                           rebaselined: [String: Data] = [:]) -> URLRuleMergeResult {
        URLRuleKind.mergePass(
            rows: rows, landedThisPage: landedThisPage,
            publishedIdentities: published
                ?? Set(table.cursors.filter { $0.value.server != nil }.keys),
            preLandingSignatures: preLanding, atRest: atRest, landed: landed,
            rebaselined: rebaselined, table: table, convergeAllowed: convergeAllowed,
            resolve: resolve)
    }

    private func pointerPass(_ liveRows: [PhiLocalURLRule],
                             landedThisPage: Set<String> = [],
                             published: Set<String>,
                             preLanding: [String: RuleSignature] = [:]) -> [String: String] {
        URLRuleKind.mergePointerPass(liveRows: liveRows, landedThisPage: landedThisPage,
                                     publishedIdentities: published,
                                     preLandingSignatures: preLanding, resolve: resolve)
    }

    /// M2's additional operations recorded by FakeURLRuleAccess on this page.
    private func mergeOps(_ access: FakeURLRuleAccess) -> [URLRuleSyncOp] { access.lastMergeOps }

    private func refreshCalls(_ access: FakeURLRuleAccess) -> Int {
        access.calls.filter { $0 == .refreshRoutingTable }.count
    }

    private func applyCalls(_ access: FakeURLRuleAccess) -> Int {
        access.calls.filter { if case .apply = $0 { return true } else { return false } }.count
    }

    private func liveRows(_ access: FakeURLRuleAccess) -> [PhiLocalURLRule] {
        access.rows.filter { $0.deletedDate == nil }
    }

    private func row(_ access: FakeURLRuleAccess, _ syncId: String) -> PhiLocalURLRule? {
        access.rows.first { $0.syncId == syncId }
    }

    /// Rules-only engine with one page, empty by default to exercise landsEmptyBatch.
    private func makeRuleEngine(_ access: FakeURLRuleAccess, _ store: MemoryOwnedItemStore,
                                client: FakePhiSyncClient,
                                drained: Bool = true) throws -> PhiSyncEngine {
        let spaceStore = MemorySpaceStore()
        spaceStore.table.hasDrainedFullReplay = drained
        try silenceOtherSections(spaceStore)
        return makeEngine(client: client, markerStore: markerStore(marker: "0"),
                          spaceStore: spaceStore,
                          ownedKinds: [.urlRules(access: access, store: store)])
    }

    // MARK: - CASE M-6b (reduce the group before one absorption write; R-M3-4a-82)

    /// Comparing each loser against a fixed W snapshot could write true@30 then regress to true@20 because 20
    /// still exceeds snapshot 10. Member order would then cause cross-device divergence.
    func testM6b_absorptionReducesTheWholeGroupOnceInsteadOfPerLoser() throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        seedSettled("a", id: "i-a", ask: false, accountStamp: 10, rows: &rows, table: &table)
        seedSettled("b", id: "i-b", ask: true, accountStamp: 30, rows: &rows, table: &table)
        seedSettled("c", id: "i-c", ask: true, accountStamp: 20, rows: &rows, table: &table)

        let signature = try XCTUnwrap(URLRuleKind.signature(of: rows[0], resolve: resolve,
                                                            normalize: normalize))
        let stamps = ["a": stampDate(10), "b": stampDate(30), "c": stampDate(20)]
        let converged = URLRuleKind.convergePass(groups: [signature: rows],
                                                 atRest: ["a", "b", "c"],
                                                 accountStamps: stamps)
        // One write selects the whole group's source true@30 and copies its stamp.
        XCTAssertEqual(converged.contentGroupWrites.count, 1)
        XCTAssertEqual(converged.contentGroupWrites.first?.syncId, "a", "The smallest syncId wins")
        XCTAssertEqual(converged.contentGroupWrites.first?.ask, true)
        XCTAssertEqual(converged.contentGroupWrites.first?.contentUpdatedDate, stampDate(30))
        XCTAssertEqual(converged.collapsed, 2)
        XCTAssertEqual(converged.softDeletes.map(\.syncId).sorted(), ["b", "c"])
        XCTAssertTrue(converged.softDeletes.allSatisfy { $0.mergePartnerSyncId == "a" })
        XCTAssertEqual(converged.touchedBuckets, ["space-a"])

        // (a) Equal content with newer stamp still advances W to 30. Otherwise the same loser keeps winning
        // against stale W@10 next round, breaking monotonic stamps.
        var advanced = rows
        advanced[0].askBeforeRouting = true
        let advancedOut = URLRuleKind.convergePass(groups: [signature: advanced],
                                                   atRest: ["a", "b", "c"],
                                                   accountStamps: stamps)
        XCTAssertEqual(advancedOut.contentGroupWrites.count, 1)
        XCTAssertEqual(advancedOut.contentGroupWrites.first?.contentUpdatedDate, stampDate(30))
        XCTAssertEqual(advancedOut.contentGroupWrites.first?.ask, true)

        // (b) Equal-stamp true@30/false@30 ties use syncId lexical order, producing one identical write even
        // after shuffling members.
        var tied: [PhiLocalURLRule] = []
        var tiedTable = PhiOwnedItemTable()
        seedSettled("a", id: "i-a", ask: true, accountStamp: 30, rows: &tied, table: &tiedTable)
        seedSettled("b", id: "i-b", ask: false, accountStamp: 30, rows: &tied, table: &tiedTable)
        let tiedStamps = ["a": stampDate(30), "b": stampDate(30)]
        let first = URLRuleKind.convergePass(groups: [signature: tied], atRest: ["a", "b"],
                                             accountStamps: tiedStamps)
        let reversed = URLRuleKind.convergePass(groups: [signature: tied.reversed()],
                                                atRest: ["a", "b"], accountStamps: tiedStamps)
        XCTAssertEqual(first.contentGroupWrites.count, 1)
        XCTAssertEqual(first, reversed, "Member order does not affect final state")
        XCTAssertEqual(first.softDeletes.map(\.syncId), ["b"])
    }

    // MARK: - CASE M2-a (never overwrite a pointer already targeting a live row)

    /// Weakening this precondition rewrites non-anchor pointers in both passes on every page, and pass two
    /// overwrites step 2(b)'s final pointer (RR11-2).
    func testM2a_thePointerNeverOverwritesAValueThatAlreadyPointsAtALiveRow() throws {
        let a = PhiLocalURLRule.fixture(id: "i-a", syncId: "a")
        let b = PhiLocalURLRule.fixture(id: "i-b", syncId: "b", sortOrder: 1,
                                        mergePartnerSyncId: "c")
        let c = PhiLocalURLRule.fixture(id: "i-c", syncId: "c", sortOrder: 2,
                                        mergePartnerSyncId: "zz")
        let out = pointerPass([a, b, c], published: ["a", "b", "c"])
        XCTAssertNil(out["b"], "Already points to a live row; leave unchanged")
        XCTAssertEqual(out["c"], "a", "Dangling pointer is rewritten to the anchor")
        XCTAssertNil(out["a"], "The anchor's own pointer remains nil (RR13-7)")

        // A pointer is dangling whenever no live row matches; targeting an already-converged soft-deleted row
        // also qualifies.
        var cPointsAtDeleted = c
        cPointsAtDeleted.mergePartnerSyncId = "gone"
        let deleted = PhiLocalURLRule.fixture(id: "i-gone", syncId: "gone", sortOrder: 3,
                                              deletedDate: Date(timeIntervalSince1970: 9))
        XCTAssertEqual(deleted.deletedDate != nil, true)
        let dangling = pointerPass([a, b, cPointsAtDeleted], published: ["a", "b", "c", "gone"])
        XCTAssertEqual(dangling["c"], "a")

        // Negative control / R-M3-4a-95: A0 has syncId minted by M1 but was never published. syncId presence
        // cannot make it an anchor: unpublished rows are never still, so §8.4.4 partner lookup would fail for
        // the entire group (RR13-5).
        let a0 = PhiLocalURLRule.fixture(id: "i-a0", syncId: "A0", sortOrder: 4)
        let control = pointerPass([a0, a, b, c], published: ["a", "b", "c"])
        XCTAssertEqual(control["A0"], "a", "The anchor remains a; A0 also appears in the result")
        XCTAssertEqual(control["c"], "a")
        XCTAssertNil(control["a"])
        XCTAssertNil(control["b"])

        // Fewer than two anchors means no pointer writes for the group.
        XCTAssertTrue(pointerPass([a0, a], published: ["a"]).isEmpty)
    }

    /// F1 / 8b-2 fix round 1: first-pass anchor cardinality uses the pre-convergence live set. Published still
    /// A/B plus unpublished, unlanded C converge by soft-deleting B. Recomputing anchors afterward would leave
    /// only A and skip C's pointer at count < 2. §8.4.3 checks > 1 before convergence and writes every
    /// non-anchor, including C (RR10-8 lifecycle).
    func testM2a_theAnchorCardinalityIsEvaluatedBeforeTheSoftDeletes() throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        seedSettled("a", id: "i-a", accountStamp: 100, rows: &rows, table: &table)
        seedSettled("b", id: "i-b", sortOrder: 1, accountStamp: 100, rows: &rows, table: &table)
        // C has insertion-minted syncId (R-M3-4a-23) but no cursor; it is neither published nor landedThisPage
        // and is not a still convergence member.
        rows.append(.fixture(id: "i-c", syncId: "c-local", sortOrder: 2, pendingLocalEdit: true))

        let out = mergePass(rows: rows, table: table, atRest: ["a", "b"])
        XCTAssertEqual(out.collapsed, 1, "B is soft-deleted")
        XCTAssertEqual(out.ops, [
            .softDelete(syncId: "b", mergePartnerSyncId: "a"),
            .setMergePartner(syncId: "c-local", mergePartnerSyncId: "a"),
        ], "C still receives a pointer to anchor A")

        // Closed-gate control performs no soft deletion and gives C the identical pointer. Live B gets its own
        // non-anchor pointer too. C's equality proves the convergePass-first ordering deviation is safe here.
        let gated = mergePass(rows: rows, table: table, atRest: ["a", "b"], convergeAllowed: false)
        XCTAssertEqual(gated.ops, [
            .setMergePartner(syncId: "b", mergePartnerSyncId: "a"),
            .setMergePartner(syncId: "c-local", mergePartnerSyncId: "a"),
        ])
    }

    /// Fix round 2: the second pass must use the post-deletion live set. p moved from K2/su-2 to K1/su-1 and
    /// converged into smaller m this page; live z remains in pre-landing K2. Including deleted p would falsely
    /// make two K2 anchors and point z at p, soft-deleted in the same transaction. The anchor ≤ winner < loser
    /// argument applies only when pointer grouping matches convergePass, which the second pass does not.
    func testM2a_theSecondPassNeverAnchorsOnARowCollapsedThisPage() throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        seedSettled("m", id: "i-m", accountStamp: 100, rows: &rows, table: &table)
        seedSettled("p", id: "i-p", sortOrder: 1, accountStamp: 100, rows: &rows, table: &table)
        seedSettled("z", id: "i-z", spaceId: "space-b", target: "su-2", accountStamp: 100,
                    rows: &rows, table: &table)
        // p just landed a su-2 → su-1 move; its pre-landing signature is K2.
        let k2 = RuleSignature(host: "github.com", pathPrefix: nil, owner: "su-2")
        let preLanding = ["p": k2]

        let out = mergePass(rows: rows, table: table, atRest: ["m", "p", "z"],
                            landedThisPage: ["p"], preLanding: preLanding)
        XCTAssertEqual(out.collapsed, 1)
        XCTAssertEqual(out.ops, [.softDelete(syncId: "p", mergePartnerSyncId: "m")],
                       "z needs no pointer as K2's sole live member")
        XCTAssertFalse(out.ops.contains(.setMergePartner(syncId: "z", mergePartnerSyncId: "p")),
                       "Never point to a row soft-deleted in the same transaction")

        // Control keeps p live by closing the gate: pass two correctly points z to p, while pass one points p
        // to m. That write is wrong only after p has been soft-deleted.
        let alive = mergePass(rows: rows, table: table, atRest: ["m", "p", "z"],
                              convergeAllowed: false, landedThisPage: ["p"],
                              preLanding: preLanding)
        XCTAssertEqual(alive.ops, [
            .setMergePartner(syncId: "p", mergePartnerSyncId: "m"),
            .setMergePartner(syncId: "z", mergePartnerSyncId: "p"),
        ])
    }

    // MARK: - CASE M2-c (gate affects only step 2; channel assertions)

    /// A gate around the whole pass or inside mergePointerPass can evade pure-value coverage. Pointer writes
    /// must not set changedRouting or CASE M-7's no-refresh behavior becomes a refresh per page.
    func testM2c_theGateOnlyStopsTheSecondStep() throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        seedSettled("a", id: "i-a", ask: false, accountStamp: 10, rows: &rows, table: &table)
        seedSettled("b", id: "i-b", ask: true, sortOrder: 1, accountStamp: 20,
                    rows: &rows, table: &table)

        let closed = mergePass(rows: rows, table: table, atRest: ["a", "b"], convergeAllowed: false)
        XCTAssertEqual(closed.ops, [.setMergePartner(syncId: "b", mergePartnerSyncId: "a")],
                       "Closed gate: only step-1 pointers")
        XCTAssertEqual(closed.collapsed, 0)
        XCTAssertFalse(closed.changedRouting, "Pointer-only writes do not refresh routing")

        let open = mergePass(rows: rows, table: table, atRest: ["a", "b"], convergeAllowed: true)
        XCTAssertEqual(open.ops, [
            .setContentGroup(syncId: "a", host: "github.com", pathPrefix: nil, ask: true,
                             contentUpdatedDate: stampDate(20)),
            .softDelete(syncId: "b", mergePartnerSyncId: "a"),
        ], "Open gate: content group precedes soft deletion")
        XCTAssertEqual(open.collapsed, 1)
        XCTAssertTrue(open.changedRouting)
    }

    // MARK: - CASE M-4 (content absorption copies source stamps, never now)

    /// Minting now gives machine-transferred content false freshness over real user edits (D33 / §8.4.1(5)).
    /// Variant three excludes device-specific createdDate from source selection.
    func testM4_absorptionCopiesTheSourceStampAndNeverMintsNow() throws {
        /// Variants α/β differ only in the row stamp and must yield identical results because account stamps
        /// govern (R-M3-4a-94).
        func run(rowStamps: Bool) -> URLRuleMergeResult {
            var rows: [PhiLocalURLRule] = []
            var table = PhiOwnedItemTable()
            seedSettled("a", id: "i-a", ask: false, accountStamp: 100,
                        rowContentUpdatedDate: rowStamps ? stampDate(100) : nil,
                        rows: &rows, table: &table)
            seedSettled("b", id: "i-b", ask: true, sortOrder: 1, accountStamp: 300,
                        rowContentUpdatedDate: rowStamps ? stampDate(300) : nil,
                        rows: &rows, table: &table)
            return mergePass(rows: rows, table: table, atRest: ["a", "b"])
        }
        for rowStamps in [true, false] {
            let out = run(rowStamps: rowStamps)
            XCTAssertEqual(out.ops.first,
                           .setContentGroup(syncId: "a", host: "github.com", pathPrefix: nil,
                                            ask: true, contentUpdatedDate: stampDate(300)),
                           "rowStamps=\(rowStamps): absorb true@300, not now")
            XCTAssertEqual(out.collapsed, 1)
        }

        // Variant one: equal content and stamps preserve ask/contentUpdatedDate byte for byte.
        var same: [PhiLocalURLRule] = []
        var sameTable = PhiOwnedItemTable()
        seedSettled("a", id: "i-a", ask: true, accountStamp: 300, rows: &same, table: &sameTable)
        seedSettled("b", id: "i-b", ask: true, sortOrder: 1, accountStamp: 300,
                    rows: &same, table: &sameTable)
        let identical = mergePass(rows: same, table: sameTable, atRest: ["a", "b"])
        XCTAssertEqual(identical.ops, [.softDelete(syncId: "b", mergePartnerSyncId: "a")],
                       "No extra commit because no content group is written")
        XCTAssertEqual(identical.collapsed, 1)

        // Variants two/three: older loser content with different ask is not absorbed. Moving its device-local
        // createdDate far into the future does not change the result.
        for loserCreated in [Date(timeIntervalSince1970: 1_000), Date(timeIntervalSince1970: 9_000)] {
            var older: [PhiLocalURLRule] = []
            var olderTable = PhiOwnedItemTable()
            seedSettled("a", id: "i-a", ask: false, accountStamp: 300, rows: &older,
                        table: &olderTable)
            seedSettled("b", id: "i-b", ask: true, sortOrder: 1, accountStamp: 100,
                        createdDate: loserCreated, rows: &older, table: &olderTable)
            let out = mergePass(rows: older, table: olderTable, atRest: ["a", "b"])
            XCTAssertEqual(out.ops, [.softDelete(syncId: "b", mergePartnerSyncId: "a")],
                           "createdDate=\(loserCreated): do not absorb the content group")
        }
    }

    // MARK: - CASE M-3b (unpublished rows never win or delete published entities)

    /// Omitting stillness predicate 1 would make a-local win and delete a published account entity, violating
    /// D30. Across devices it could make A delete the account entity while B deletes its own row.
    func testM3b_anUnpublishedRowNeverWinsAndNeverKillsAPublishedEntity() throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        seedSettled("m-account", id: "i-acc", accountStamp: 100, rows: &rows, table: &table)
        // New unpublished local row with insertion-minted syncId (R-M3-4a-23) but no cursor.
        rows.append(.fixture(id: "i-local", syncId: "a-local", sortOrder: 1, pendingLocalEdit: true))

        let out = mergePass(rows: rows, table: table, atRest: ["m-account"])
        XCTAssertEqual(out.collapsed, 0)
        XCTAssertTrue(out.ops.isEmpty, "Only one anchor means no pointer writes")

        // Cross-device cases place local identity below and above account identity; neither device converges
        // them.
        for localId in ["a-local", "z-local"] {
            var variant: [PhiLocalURLRule] = []
            var variantTable = PhiOwnedItemTable()
            seedSettled("m-account", id: "i-acc", accountStamp: 100, rows: &variant,
                        table: &variantTable)
            variant.append(.fixture(id: "i-local", syncId: localId, sortOrder: 1,
                                    pendingLocalEdit: true))
            XCTAssertEqual(mergePass(rows: variant, table: variantTable,
                                     atRest: ["m-account"]).collapsed, 0, localId)
        }
    }

    // MARK: - CASE M-10 (convergence never revives user-deleted rows)

    /// The tail hook includes soft-deleted rows for addressing. Without live filtering, a user-deleted row
    /// could win and absorb content, making a deleted rule appear edited again.
    func testM10_convergenceNeverResurrectsARowTheUserDeleted() throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        seedSettled("a", id: "i-a", ask: false, accountStamp: 10, rows: &rows, table: &table)
        let deletedAt = Date(timeIntervalSince1970: 4_242)
        seedSettled("b", id: "i-b", ask: true, sortOrder: 1, accountStamp: 900,
                    rows: &rows, table: &table)
        rows[1].deletedDate = deletedAt

        let out = mergePass(rows: rows, table: table, atRest: ["a", "b"])
        XCTAssertEqual(out.collapsed, 0, "Exclude the soft-deleted row, leaving one member")
        XCTAssertTrue(out.ops.isEmpty, "a needs no write; its pointer is already nil")
        XCTAssertEqual(rows[1].deletedDate, deletedAt, "M2 left it unchanged byte for byte")
    }

    // MARK: - CASE M-27 (M2 never selects a winner dying on this page; R-M3-4a-86)

    /// Choosing Z as winner by recomputing atRest in the tail hook without predicate 10 would absorb X,
    /// tombstone X, then hard-delete Z in this page's delete phase. The group disappears everywhere with only
    /// collapsed in the log.
    func testM27_theMergeNeverPicksAWinnerThatDiesOnThisPage() throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        let z = seedSettled("a", id: "i-z", ask: false, accountStamp: 10, rows: &rows, table: &table)
        seedSettled("b", id: "i-x", ask: true, sortOrder: 1, accountStamp: 20,
                    rows: &rows, table: &table)
        // Z's tombstone arrives this page, so 8b-1 predicate 10 excludes Z from atRestIdentities.
        XCTAssertFalse(isAtRest(z, table.cursors["a"], tombstones: ["a"]), "Predicate 10")

        let out = mergePass(rows: rows, table: table, atRest: ["b"])
        XCTAssertEqual(out.collapsed, 0, "Only one still member remains")
        XCTAssertFalse(out.changedRouting)
        // X changes only its step-1 pointer; neither content nor deletedDate is written.
        XCTAssertEqual(out.ops, [.setMergePartner(syncId: "b", mergePartnerSyncId: "a")])

        // Next page: Z is hard-deleted and X is the sole member, so no duplicate remains.
        var afterDelete = [rows[1]]
        afterDelete[0].mergePartnerSyncId = "a"
        var afterTable = table
        afterTable.cursors["a"] = nil
        let next = mergePass(rows: afterDelete, table: afterTable, atRest: ["b"])
        XCTAssertEqual(next.collapsed, 0)
        // Clear rule ①: a sole still member clears its stale partner pointer.
        XCTAssertEqual(next.ops, [.setMergePartner(syncId: "b", mergePartnerSyncId: nil)])
    }

    // MARK: - CASE M-33 (same-page M3 → M2 uses all three effective-account-stamp sources)

    /// Variant (b) covers the landed-value stamp source. Baseline-only selection would choose W@30 and discard
    /// the latest account content.
    func testM33b_theEffectiveStampOfAnIdentityLandedThisPageIsItsLandingValue() throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        seedSettled("a", id: "i-w", ask: false, accountStamp: 30,
                    rowContentUpdatedDate: stampDate(30), rows: &rows, table: &table)
        // B landed this page as ask true/stamp 40, but land's cursor table still says 20 because bookkeeping
        // follows land.
        seedSettled("b", id: "i-b", ask: true, sortOrder: 1, accountStamp: 20,
                    rowContentUpdatedDate: stampDate(40), rows: &rows, table: &table)
        let landed = ["b": URLRuleLandingValues.fixture(syncId: "b", spaceId: "space-a",
                                                        host: "github.com",
                                                        askBeforeRouting: true, sortOrder: 1,
                                                        contentUpdatedDate: stampDate(40),
                                                        targetUpdatedDate: stampDate(40))]
        let out = mergePass(rows: rows, table: table, atRest: ["a", "b"],
                            landedThisPage: ["b"], landed: landed)
        XCTAssertEqual(out.ops, [
            .setContentGroup(syncId: "a", host: "github.com", pathPrefix: nil, ask: true,
                             contentUpdatedDate: stampDate(40)),
            .softDelete(syncId: "b", mergePartnerSyncId: "a"),
        ], "Source uses this page's landed stamp 40, not cursor stamp 20")
        XCTAssertEqual(out.collapsed, 1)
    }

    /// Variant (c): row stamps are not authoritative. Reading A's distantPast or device-local createdDate
    /// fallback would choose B and overwrite newer account content.
    func testM33c_theRowStampIsNeverTheSourceOfTruth() throws {
        // Test nil row stamp (Task 5 ruling 5 new-row shape) and stale 10 (rebaselined changes only baseline).
        // Results must match.
        for rowStamp in [nil, stampDate(10)] as [Date?] {
            var rows: [PhiLocalURLRule] = []
            var table = PhiOwnedItemTable()
            seedSettled("a", id: "i-a", ask: false, accountStamp: 30,
                        rowContentUpdatedDate: rowStamp, rows: &rows, table: &table)
            seedSettled("b", id: "i-b", ask: true, sortOrder: 1, accountStamp: 20,
                        rowContentUpdatedDate: stampDate(20), rows: &rows, table: &table)
            let out = mergePass(rows: rows, table: table, atRest: ["a", "b"])
            XCTAssertEqual(out.ops, [.softDelete(syncId: "b", mergePartnerSyncId: "a")],
                           "rowStamp=\(String(describing: rowStamp)): source is A, which remains unchanged")
            XCTAssertEqual(out.collapsed, 1)
        }
    }

    /// Variant (d) covers this page's rebaselined stamp source (R-M3-4a-97). With no operations, candidate
    /// subtraction, phase ordering and transaction exclusion cannot protect it; rebaselined is essential.
    func testM33d_theEffectiveStampFallsBackToThisPagesRebaselinedBytes() throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        seedSettled("a", id: "i-a", ask: false, accountStamp: 10, rows: &rows, table: &table)
        seedSettled("b", id: "i-b", ask: true, sortOrder: 1, accountStamp: 20,
                    rows: &rows, table: &table)
        // A arrives with identical false value and newer stamp 30, so plan emits no steps and puts A in
        // rebaselined.
        let rebased = baselineBytes(urlRulePayload(uuid: "a", targetSpaceUuid: "su-1",
                                                   host: "github.com", ask: false,
                                                   contentStamp: 30, targetStamp: 30,
                                                   rankStamp: 30))
        let out = mergePass(rows: rows, table: table, atRest: ["a", "b"],
                            rebaselined: ["a": rebased])
        XCTAssertEqual(out.ops, [.softDelete(syncId: "b", mergePartnerSyncId: "a")],
                       "Source A wins 30 > 20; soft-delete B and leave A unchanged")
        XCTAssertEqual(out.collapsed, 1)

        // A two-source implementation using only landed values/baseline leaves A@10, selects B and overwrites
        // A with true@20 before soft-deleting it. This is the required negative shape.
        let twoLayers = mergePass(rows: rows, table: table, atRest: ["a", "b"])
        XCTAssertEqual(twoLayers.ops.first,
                       .setContentGroup(syncId: "a", host: "github.com", pathPrefix: nil,
                                        ask: true, contentUpdatedDate: stampDate(20)),
                       "Control: omitting the second source layer absorbs B@20")
    }

    // MARK: - CASE M-25 (immediate pointer inputs; R-M3-4a-74 / 75 / 95)

    /// (a) Z/X first land from the account without cursors; the same page must write X → Z. Anchors must union
    /// landedThisPage with publishedIdentities or the empty published set yields no pointers.
    func testM25a_thePointerIsWrittenOnTheVeryPageBothSidesFirstLand() throws {
        let z = PhiLocalURLRule.fixture(id: "i-z", syncId: "a")
        let x = PhiLocalURLRule.fixture(id: "i-x", syncId: "b", sortOrder: 1)
        let out = pointerPass([z, x], landedThisPage: ["a", "b"], published: [])
        XCTAssertEqual(out, ["b": "a"])
        XCTAssertTrue(pointerPass([z, x], landedThisPage: [], published: []).isEmpty,
                      "Both union terms are required; landedThisPage alone also cannot write this pointer")
    }

    /// (b)(d) Closed gate during initial drain/loss replay still permits pointers, with collapsed 0 on the
    /// same page.
    func testM25bd_theGateNeverStopsThePointer() throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        seedSettled("a", id: "i-z", accountStamp: 10, rows: &rows, table: &table)
        seedSettled("b", id: "i-x", sortOrder: 1, accountStamp: 20, rows: &rows, table: &table)
        let out = mergePass(rows: rows, table: table, atRest: ["a", "b"], convergeAllowed: false,
                            landedThisPage: ["a"])
        XCTAssertEqual(out.ops, [.setMergePartner(syncId: "b", mergePartnerSyncId: "a")])
        XCTAssertEqual(out.collapsed, 0)
        XCTAssertFalse(out.changedRouting)
    }

    /// (c) Z moves this page while X has no steps. Current signatures differ in pass one, but
    /// preLandingSignatures[Z] groups them in pass two and writes X → Z. This catches restricting the domain
    /// to cursor identities (excluding X), deriving old signatures by rereading after landing, or using
    /// newOwnerUuid as the old target.
    func testM25c_theSecondPassGroupsByThePreLandingSignature() throws {
        // Z just moved to space-b/su-2; X remains in space-a/su-1.
        let z = PhiLocalURLRule.fixture(id: "i-z", syncId: "a", spaceId: "space-b")
        let x = PhiLocalURLRule.fixture(id: "i-x", syncId: "b", spaceId: "space-a",
                                        sortOrder: 1, pendingLocalEdit: true)
        let preLanding = ["a": RuleSignature(host: "github.com", pathPrefix: nil, owner: "su-1")]
        XCTAssertTrue(pointerPass([z, x], published: ["a", "b"]).isEmpty,
                      "Current signatures alone form two singleton groups and write nothing")
        XCTAssertEqual(pointerPass([z, x], published: ["a", "b"], preLanding: preLanding),
                       ["b": "a"])

        // If Z's pre-landing target cannot resolve, omit it from preLandingSignatures and skip pass two safely
        // without force-unwrapping.
        XCTAssertTrue(pointerPass([z, x], published: ["a", "b"], preLanding: [:]).isEmpty)
    }

    /// (e) Interleaving B: neither X nor Z has preLandingSignatures. Current signatures differ and fallback
    /// preserves that distinction, so neither pointer pass writes.
    func testM25e_theInterleavedShapeWritesNoPointerAtAll() throws {
        let z = PhiLocalURLRule.fixture(id: "i-z", syncId: "a", spaceId: "space-b")
        let x = PhiLocalURLRule.fixture(id: "i-x", syncId: "b", spaceId: "space-a", sortOrder: 1)
        XCTAssertTrue(pointerPass([z, x], landedThisPage: ["a"], published: ["a", "b"]).isEmpty)
        XCTAssertNil(z.mergePartnerSyncId)
        XCTAssertNil(x.mergePartnerSyncId)
    }

    // MARK: - CASE M-3c / M-17 (unpublished edits prevent stillness but still get pointers)

    /// Tying pointer writes to a still winner leaves §8.4.6 race 3 without a prior pointer and ends with two
    /// rules. Stillness also must honor pendingLocalEdit and server/reconciled state rather than an
    /// alternative projection comparison.
    func testM3c_aMemberWithAnUnpublishedEditIsNotAtRestButStillGetsThePointer() throws {
        /// The edited row is not still due to pendingLocalEdit or server != reconciled; the other is the
        /// anchor.
        func run(editedIsLarger: Bool, viaServerMismatch: Bool) -> (URLRuleMergeResult, String) {
            let editedId = editedIsLarger ? "b" : "a"
            let otherId = editedIsLarger ? "a" : "b"
            var rows: [PhiLocalURLRule] = []
            var table = PhiOwnedItemTable()
            seedSettled(otherId, id: "i-other", accountStamp: 10, rows: &rows, table: &table)
            seedSettled(editedId, id: "i-edited", ask: true, sortOrder: 1, accountStamp: 20,
                        pendingLocalEdit: !viaServerMismatch, rows: &rows, table: &table)
            if viaServerMismatch {
                table.cursors[editedId]?.server = Data([0x07])
            }
            return (mergePass(rows: rows, table: table, atRest: [otherId]), editedId)
        }

        // The edited row has larger syncId and points to the smallest published syncId in its group.
        let (larger, _) = run(editedIsLarger: true, viaServerMismatch: false)
        XCTAssertEqual(larger.collapsed, 0)
        XCTAssertEqual(larger.ops, [.setMergePartner(syncId: "b", mergePartnerSyncId: "a")])

        // Symmetric case: the edited row is the smaller anchor, so the other row points to it.
        let (smaller, _) = run(editedIsLarger: false, viaServerMismatch: false)
        XCTAssertEqual(smaller.collapsed, 0)
        XCTAssertEqual(smaller.ops, [.setMergePartner(syncId: "b", mergePartnerSyncId: "a")])

        // Second control: server != reconciled fails predicate 2, still yielding no convergence but a pointer
        // write.
        let (mismatch, _) = run(editedIsLarger: true, viaServerMismatch: true)
        XCTAssertEqual(mismatch.collapsed, 0)
        XCTAssertEqual(mismatch.ops, [.setMergePartner(syncId: "b", mergePartnerSyncId: "a")])
    }

    /// M-17's M2 half: a retargeted winner soft-deletes the loser while preserving its own rank and target. M2
    /// never restores the loser; it only sets deletedDate, never clears it.
    func testM17_theLoserIsSoftDeletedAndTheWinnerIsNeverTouchedOrPulledBack() throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        // Equal effective account stamps require no content write. CASE M-6b(a) separately covers stamp-only
        // advancement.
        seedSettled("a", id: "i-z", sortOrder: 0, accountStamp: 10, rows: &rows, table: &table)
        seedSettled("b", id: "i-x", sortOrder: 1, accountStamp: 10, rows: &rows, table: &table)

        let out = mergePass(rows: rows, table: table, atRest: ["a", "b"])
        XCTAssertEqual(out.collapsed, 1)
        XCTAssertEqual(out.ops, [.softDelete(syncId: "b", mergePartnerSyncId: "a")],
                       "Winner Z has no operations; rank and target remain unchanged")

        // Feed soft-deleted X back unchanged: live filtering excludes it, collapsed remains 0, and M2 never
        // moves it back to S2.
        var afterCollapse = rows
        afterCollapse[1].deletedDate = Date(timeIntervalSince1970: 7)
        afterCollapse[1].mergePartnerSyncId = "a"
        let next = mergePass(rows: afterCollapse, table: table, atRest: ["a", "b"])
        XCTAssertEqual(next.collapsed, 0)
        XCTAssertTrue(next.ops.isEmpty, "The winner's pointer is already nil; clear rule ① has nothing to write")
        XCTAssertEqual(afterCollapse[1].deletedDate, Date(timeIntervalSince1970: 7))
    }

    // MARK: - CASE M-16 (yielding also covers user deletion; M2 coverage here)

    /// A singleton must not receive a self-pointer (RR7-13). Otherwise branch (i) transfers an edit to itself,
    /// then the tombstone hard-deletes it and loses the edit silently.
    func testM16_aLoneMemberNeverGetsAPointerAndIsNeverCollapsed() async throws {
        let access = FakeURLRuleAccess(rows: [
            .fixture(id: "i1", syncId: "a", host: "github.com", askBeforeRouting: true,
                     contentUpdatedDate: Date(timeIntervalSince1970: 30), pendingLocalEdit: true),
        ])
        let store = MemoryOwnedItemStore()
        store.table.cursors["a"] = publishedRuleCursor(urlRulePayload(uuid: "a"),
                                                       entityId: "srv-a")
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([], marker: "7")]
        let engine = try makeRuleEngine(access, store, client: client)
        await engine.setSpaceSyncEnabled(true)

        for _ in 0..<3 {
            await engine.pullOnce()
            let counters = await counters(engine)
            XCTAssertEqual(counters?.collapsed, 0)
            XCTAssertNil(row(access, "a")?.mergePartnerSyncId,
                         "members.count == 1 keeps the pointer nil, the structural precondition for yielding branch (ii)")
            XCTAssertNil(row(access, "a")?.deletedDate, "M2 never modified its deletedDate")
        }
        XCTAssertEqual(row(access, "a")?.contentUpdatedDate, Date(timeIntervalSince1970: 30),
                       "M2 preserved all three stamps")
    }

    // MARK: - CASE M-3 (deterministic convergence winner and pointer priority, engine coverage)

    /// Winner selection must not depend on device-local creation order, id, sortOrder or createdDate; only
    /// account identities provide shared ordering. Pointer assertions cover RR11-2.
    func testM3_theWinnerIsDeterministicAndTheLosersPointAtIt() async throws {
        /// Run the same three live same-signature members under a supplied arrangement.
        func run(order: [(syncId: String, id: String, sortOrder: Int, created: TimeInterval)])
            async throws -> FakeURLRuleAccess {
            var rows: [PhiLocalURLRule] = []
            var table = PhiOwnedItemTable()
            for entry in order {
                seedSettled(entry.syncId, id: entry.id, sortOrder: entry.sortOrder,
                            accountStamp: 100,
                            createdDate: Date(timeIntervalSince1970: entry.created),
                            rows: &rows, table: &table)
            }
            let access = FakeURLRuleAccess(rows: rows)
            let store = MemoryOwnedItemStore()
            store.table = table
            let client = FakePhiSyncClient()
            client.pagesByMarker = [page([], marker: "7")]
            let engine = try makeRuleEngine(access, store, client: client)
            await engine.setSpaceSyncEnabled(true)
            await engine.pullOnce()
            let counters = await counters(engine)
            XCTAssertEqual(counters?.collapsed, 2)
            return access
        }

        // ① Baseline arrangement.
        let base = try await run(order: [("b", "i-b", 0, 1_000), ("a", "i-a", 1, 2_000),
                                          ("c", "i-c", 2, 3_000)])
        XCTAssertNil(row(base, "a")?.deletedDate, "The winner is a")
        XCTAssertNotNil(row(base, "b")?.deletedDate)
        XCTAssertNotNil(row(base, "c")?.deletedDate)
        XCTAssertEqual(row(base, "b")?.mergePartnerSyncId, "a")
        XCTAssertEqual(row(base, "c")?.mergePartnerSyncId, "a")
        XCTAssertNil(row(base, "a")?.mergePartnerSyncId, "The winner's own pointer is empty")

        // ② Shuffle insertion order, id, sortOrder and createdDate; winner remains a.
        let shuffled = try await run(order: [("c", "z-1", 2, 9_000), ("b", "z-2", 0, 5_000),
                                             ("a", "z-9", 1, 7_000)])
        XCTAssertNil(row(shuffled, "a")?.deletedDate)
        XCTAssertEqual(row(shuffled, "b")?.mergePartnerSyncId, "a")
        XCTAssertEqual(row(shuffled, "c")?.mergePartnerSyncId, "a")
    }

    /// Control: smaller published A0 has pendingLocalEdit and becomes anchor, but a is the still winner. Loser
    /// mergePartnerSyncId must point to a, not A0. Unconditional second-pass overwrite would permanently
    /// mispoint soft-deleted losers, which leave allURLRules and never receive another M2 pointer write.
    func testM3_theLoserPointerIsTheWinnerNotTheAnchor() async throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        seedSettled("A0", id: "i-a0", accountStamp: 100, pendingLocalEdit: true,
                    rows: &rows, table: &table)
        seedSettled("a", id: "i-a", sortOrder: 1, accountStamp: 100, rows: &rows, table: &table)
        seedSettled("b", id: "i-b", sortOrder: 2, accountStamp: 100, rows: &rows, table: &table)
        seedSettled("c", id: "i-c", sortOrder: 3, accountStamp: 100, rows: &rows, table: &table)

        let access = FakeURLRuleAccess(rows: rows)
        let store = MemoryOwnedItemStore()
        store.table = table
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([], marker: "7")]
        let engine = try makeRuleEngine(access, store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let counters = await counters(engine)
        XCTAssertEqual(counters?.collapsed, 2, "A0 is not still; still members are a/b/c")
        XCTAssertEqual(row(access, "b")?.mergePartnerSyncId, "a", "Losers point to the winner")
        XCTAssertEqual(row(access, "c")?.mergePartnerSyncId, "a")
        XCTAssertNil(row(access, "A0")?.deletedDate, "The row with an unpublished edit is unchanged")
        XCTAssertNil(row(access, "A0")?.mergePartnerSyncId, "It is the anchor, so its own pointer remains nil")
        XCTAssertEqual(row(access, "a")?.mergePartnerSyncId, "A0",
                       "In the post-deletion live set, a is not the anchor and receives a pointer to it")
    }

    // MARK: - CASE M-5 (idempotence and no simultaneous local loss)

    /// Including settled.first among losers would erase the entire local signature group. Non-idempotent
    /// absorption/deletion would write and emit publisher events on every page instead of reaching steady
    /// state.
    func testM5_convergenceIsIdempotentAndAlwaysLeavesOneLiveRow() async throws {
        for count in [2, 3, 5] {
            var rows: [PhiLocalURLRule] = []
            var table = PhiOwnedItemTable()
            for offset in 0..<count {
                seedSettled("r\(offset)", id: "i\(offset)", sortOrder: offset, accountStamp: 100,
                            rows: &rows, table: &table)
            }
            let access = FakeURLRuleAccess(rows: rows)
            let store = MemoryOwnedItemStore()
            store.table = table
            let client = FakePhiSyncClient()
            client.pagesByMarker = [page([], marker: "7")]
            let engine = try makeRuleEngine(access, store, client: client)
            await engine.setSpaceSyncEnabled(true)

            await engine.pullOnce()
            let first = await counters(engine)
            XCTAssertEqual(first?.collapsed, count - 1, "count=\(count)")
            XCTAssertEqual(liveRows(access).count, 1, "count=\(count): at least one live row remains after convergence")
            XCTAssertEqual(liveRows(access).first?.syncId, "r0")
            let refreshesAfterFirst = refreshCalls(access)

            // Second page has no landing steps but runs the tail hook: collapsed 0, empty ops and zero row
            // writes.
            await engine.pullOnce()
            let second = await counters(engine)
            XCTAssertEqual(second?.collapsed, 0, "count=\(count)")
            XCTAssertTrue(mergeOps(access).isEmpty, "count=\(count): no operations on page 2")
            XCTAssertTrue(access.lastAppliedOps.isEmpty)
            XCTAssertEqual(refreshCalls(access), refreshesAfterFirst,
                           "count=\(count): no steady-state refresh")
            XCTAssertEqual(liveRows(access).count, 1)
        }
    }

    // MARK: - CASE M-7 (no convergence echo; no-op pointers and singleton clearing)

    /// RR12-7 requires calling pointer writes only for live non-anchor rows with nil/dangling pointers.
    /// Relying only on primitive no-op behavior still rewrites through two passes for every page/member.
    /// Assert refresh-hook counts only; the test process has no routing bridge to inspect payload contents.
    func testM7_anAlreadyPointedGroupWritesNothingAndRefreshesNothing() async throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        seedSettled("a", id: "i-a", accountStamp: 100, rows: &rows, table: &table)
        // The non-anchor already points to the anchor and has an unpublished edit, so it is not still and no
        // further convergence is possible.
        seedSettled("b", id: "i-b", sortOrder: 1, accountStamp: 100, pendingLocalEdit: true,
                    mergePartnerSyncId: "a", rows: &rows, table: &table)

        let access = FakeURLRuleAccess(rows: rows)
        let store = MemoryOwnedItemStore()
        store.table = table
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([], marker: "7")]
        let engine = try makeRuleEngine(access, store, client: client)
        await engine.setSpaceSyncEnabled(true)

        let before = access.rows
        for _ in 0..<3 { await engine.pullOnce() }
        let counters = await counters(engine)
        XCTAssertEqual(counters?.collapsed, 0)
        XCTAssertTrue(mergeOps(access).isEmpty, "No SpaceURLRule row writes")
        XCTAssertEqual(access.rows, before, "Unchanged byte for byte across three rounds")
        XCTAssertEqual(refreshCalls(access), 0, "No post-landing refresh calls")
        XCTAssertTrue(ruleCommits(client).isEmpty, "Equivalent assertion for no urlRulesPublisher emissions")
    }

    /// Clear rule ①: a still winner alone in its signature group (members.count == 1) clears its partner.
    /// RR9-4's literal wording 'not in any signature group' would never match and miss this stale-pointer
    /// exit.
    func testM7_aLoneSettledMemberGetsItsStalePartnerCleared() async throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        seedSettled("a", id: "i-a", accountStamp: 100, mergePartnerSyncId: "gone",
                    rows: &rows, table: &table)

        let access = FakeURLRuleAccess(rows: rows)
        let store = MemoryOwnedItemStore()
        store.table = table
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([], marker: "7")]
        let engine = try makeRuleEngine(access, store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertEqual(mergeOps(access), [.setMergePartner(syncId: "a", mergePartnerSyncId: nil)])
        XCTAssertNil(row(access, "a")?.mergePartnerSyncId)
        XCTAssertEqual(refreshCalls(access), 0, "Pointer writes do not refresh routing")
        // Idempotent: once cleared, do not write again.
        await engine.pullOnce()
        XCTAssertTrue(mergeOps(access).isEmpty)
    }

    // MARK: - CASE M-15 (drain/replay skips step 2 but still runs step 1)

    /// Assert step 2 is skipped, not zero writes overall: pointer writes remain required by R-M3-4a-74(3).
    /// Gating pointers too would leave retargets arriving during drain/loss replay without links and end with
    /// two rules.
    func testM15_theGateStopsTheSecondStepButNeverThePointer() async throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        seedSettled("a", id: "i-a", accountStamp: 100, rows: &rows, table: &table)
        seedSettled("b", id: "i-b", sortOrder: 1, accountStamp: 100, rows: &rows, table: &table)

        let access = FakeURLRuleAccess(rows: rows)
        let store = MemoryOwnedItemStore()
        store.table = table
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([], marker: "7")]
        let spaceStore = MemorySpaceStore()
        spaceStore.table.hasDrainedFullReplay = false      // The gate is closed
        try silenceOtherSections(spaceStore)
        let engine = makeEngine(client: client, markerStore: markerStore(marker: "0"),
                                spaceStore: spaceStore,
                                ownedKinds: [.urlRules(access: access, store: store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let gated = await counters(engine)
        XCTAssertEqual(gated?.collapsed, 0, "No soft deletion or content absorption")
        XCTAssertNil(row(access, "a")?.deletedDate)
        XCTAssertNil(row(access, "b")?.deletedDate)
        XCTAssertEqual(row(access, "b")?.mergePartnerSyncId, "a", "The pointer targets the anchor on the same page")
        XCTAssertEqual(refreshCalls(access), 0, "Pointer-only writes cause no refresh")

        // The next page after opening the gate has collapsed 1.
        spaceStore.table.hasDrainedFullReplay = true
        await engine.pullOnce()
        let opened = await counters(engine)
        XCTAssertEqual(opened?.collapsed, 1)
        XCTAssertNotNil(row(access, "b")?.deletedDate)
        XCTAssertNil(row(access, "a")?.deletedDate)
    }

    // MARK: - CASE M-35 (empty pages converge through the full engine; R-M3-4a-99 / 56)

    /// Relaxing only Task 8's nonempty-ops guard and land's early return is insufficient if applyOwnedKind
    /// still skips empty batches. Most steady-state pages have all three inputs empty; local-only duplicate
    /// convergence must continue after initial drain.
    func testM35_anEmptyPageStillRunsTheMergeThroughTheFullEngineEntry() async throws {
        /// (i) A page with only a Space update; (ii) a completely empty page.
        for carriesSpace in [true, false] {
            var rows: [PhiLocalURLRule] = []
            var table = PhiOwnedItemTable()
            seedSettled("a", id: "i-a", accountStamp: 100, rows: &rows, table: &table)
            seedSettled("b", id: "i-b", sortOrder: 1, accountStamp: 100, rows: &rows, table: &table)

            let access = FakeURLRuleAccess(rows: rows)
            let store = MemoryOwnedItemStore()
            store.table = table
            let client = FakePhiSyncClient()
            let entities: [PhiRemoteEntity] = carriesSpace
                ? [remoteEntity(envelope(spacePayload(uuid: "su-9")),
                                tag: PhiSyncEntity.spaceClientTag("su-9"), version: 3, key: key)]
                : []
            client.pagesByMarker = [page(entities, marker: "7")]
            let engine = try makeRuleEngine(access, store, client: client)
            await engine.setSpaceSyncEnabled(true)
            await engine.pullOnce()

            let label = carriesSpace ? "(i) Space only" : "(ii) Empty page"
            // Both plan and land ran: the fake records apply even though ops is empty.
            XCTAssertEqual(applyCalls(access), 1, label)
            XCTAssertTrue(access.lastAppliedOps.isEmpty, "\(label): no landing operations")
            let counters = await counters(engine)
            XCTAssertEqual(counters?.collapsed, 1, label)
            XCTAssertNotNil(row(access, "b")?.deletedDate, label)
            XCTAssertEqual(row(access, "b")?.mergePartnerSyncId, "a", label)
            // mergeChangedRouting true triggers Task 6's post-landing refresh once (plan ruling seven).
            XCTAssertEqual(refreshCalls(access), 1, "\(label): §6.6 row 8")

            // Then run two steady-state rounds.
            for _ in 0..<2 { await engine.pullOnce() }
            let steady = await self.counters(engine)
            XCTAssertEqual(steady?.collapsed, 0, label)
            XCTAssertEqual(refreshCalls(access), 1, "\(label): no further refresh in steady state")
        }
    }

    /// Structural negative control: landsEmptyBatch is the guard's fourth disjunct and true only for rules.
    /// False or omitted makes applyOwnedKind return before plan, leaving collapsed 0 and both rows forever.
    func testM35_onlyTheRuleKindLandsAnEmptyBatch() {
        let ruleStore = MemoryOwnedItemStore()
        let rules = OwnedKindRegistration.urlRules(access: FakeURLRuleAccess(), store: ruleStore)
        let bookmarks = OwnedKindRegistration.bookmarks(access: FakeBookmarkAccess(),
                                                        store: MemoryOwnedItemStore())
        let pins = OwnedKindRegistration.pins(access: FakePinAccess(scope: .profile),
                                              store: MemoryOwnedItemStore())
        XCTAssertTrue(rules.landsEmptyBatch)
        XCTAssertFalse(bookmarks.landsEmptyBatch, "Preserve the bookmark early return")
        XCTAssertFalse(pins.landsEmptyBatch, "Preserve the pin early return")
    }

    /// Bookmark/pin control: neither kind applies on the same empty page; landsEmptyBatch remains false and
    /// existing early returns are unchanged.
    func testM35_bookmarksAndPinsStillTakeTheirEarlyReturnOnAnEmptyPage() async throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        seedSettled("a", id: "i-a", accountStamp: 100, rows: &rows, table: &table)
        seedSettled("b", id: "i-b", sortOrder: 1, accountStamp: 100, rows: &rows, table: &table)

        let ruleAccess = FakeURLRuleAccess(rows: rows)
        let ruleStore = MemoryOwnedItemStore()
        ruleStore.table = table
        let bookmarkAccess = FakeBookmarkAccess(rows: [.fixture(guid: "G1", syncId: "bk1",
                                                                spaceId: "space-a")])
        let pinAccess = FakePinAccess(scope: .profile)
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([], marker: "7")]
        let spaceStore = MemorySpaceStore()
        spaceStore.table.hasDrainedFullReplay = true
        try silenceOtherSections(spaceStore)
        let engine = makeEngine(
            client: client, markerStore: markerStore(marker: "0"), spaceStore: spaceStore,
            ownedKinds: [.bookmarks(access: bookmarkAccess, store: MemoryOwnedItemStore()),
                         .pins(access: pinAccess, store: MemoryOwnedItemStore()),
                         .urlRules(access: ruleAccess, store: ruleStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertEqual(applyCalls(ruleAccess), 1, "The rule kind completed land")
        XCTAssertFalse(bookmarkAccess.calls.contains { if case .apply = $0 { return true } else { return false } },
                       "No bookmark apply calls")
        XCTAssertFalse(pinAccess.calls.contains { if case .apply = $0 { return true } else { return false } },
                       "No pin apply calls")
    }

    // MARK: - CASE M-36 (post-prepass local edits narrow the still set; R-M3-4a-100)

    /// A user Save can occur between main-actor prepass and write-queue transaction. Reusing prepass atRest
    /// without transaction exclusion would select B@20 over baseline W@10 and overwrite W's fresh unpublished
    /// Save on the same page.
    func testM36_aLocalSaveBetweenThePrePassAndTheTransactionLeavesTheCandidateSet() async throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        seedSettled("a", id: "i-w", ask: false, accountStamp: 10, rows: &rows, table: &table)
        seedSettled("b", id: "i-b", ask: true, sortOrder: 1, accountStamp: 20,
                    rows: &rows, table: &table)

        let access = FakeURLRuleAccess(rows: rows)
        let store = MemoryOwnedItemStore()
        store.table = table
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([], marker: "7")]
        // Perform a real editor-style user write between prepass and transaction; never manually mutate row or
        // cursor fields.
        access.beforeLandingTransaction = { [weak access] in
            access?.applyEditorSave(syncId: "a", ask: true, at: Date(timeIntervalSince1970: 0.030))
        }
        let engine = try makeRuleEngine(access, store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let counters = await counters(engine)
        XCTAssertEqual(counters?.collapsed, 0, "W leaves candidates, leaving B as the sole still member")
        XCTAssertNil(row(access, "b")?.deletedDate, "B was not soft-deleted")
        let w = try XCTUnwrap(row(access, "a"))
        XCTAssertEqual(w.askBeforeRouting, true, "M2 left W unchanged byte for byte")
        XCTAssertEqual(w.contentUpdatedDate, Date(timeIntervalSince1970: 0.030),
                       "The stamp remains Save's 30, not B's 20")
        XCTAssertTrue(w.pendingLocalEdit)
        XCTAssertNil(row(access, "b")?.mergePartnerSyncId,
                     "The singleton clear rule does not write because B's pointer is already nil")
    }

    // MARK: - CASE M2-b (preLandingSignatures uses pre-landing targets per page; RR12-5)

    /// A frozen round-entry projection gives page 2 a two-pages-old grouping and wrong pointer anchor. The
    /// nil/dangling-only guard then makes that silent error persist. Module probe: when plan emits a step, it
    /// looks up identity in context.localSignatures; missing signatures stay absent without forced unwrap or
    /// placeholder values.
    func testM2b_thePlanRecordsThePreLandingSignatureWhenItEmitsTheStep() throws {
        var table = PhiOwnedItemTable()
        table.cursors["a"] = publishedRuleCursor(
            urlRulePayload(uuid: "a", host: "old.example", contentStamp: 100), entityId: "srv-a")
        let arrival = OwnedItemArrival(
            entity: urlRulePayload(uuid: "a", host: "new.example", contentStamp: 900),
            entityId: "srv-a", version: 7)
        let signature = RuleSignature(host: "old.example", pathPrefix: nil, owner: "su-1")

        var context = OwnedItemPlanContext()
        context.localSignatures = ["a": signature]
        let recorded = SyncableOwnedItems.plan(URLRuleKind.self, arrivals: [arrival], parked: [:],
                                               table: table, resolve: resolve, context: context)
        XCTAssertTrue(recorded.steps.contains { $0.identity == "a" && $0.kind == .update },
                      "This page actually produced an update")
        XCTAssertEqual(recorded.preLandingSignatures["a"], signature,
                       "Record pre-landing old.example, not the new payload value")

        // Unresolvable signatures are omitted without force-unwrapping or empty placeholders.
        let missing = SyncableOwnedItems.plan(URLRuleKind.self, arrivals: [arrival], parked: [:],
                                              table: table, resolve: resolve,
                                              context: OwnedItemPlanContext())
        XCTAssertTrue(missing.preLandingSignatures.isEmpty)

        // Bookmark/pin paths never populate localSignatures, so this field remains empty and behavior
        // unchanged.
        var bookmarkTable = PhiOwnedItemTable()
        bookmarkTable.cursors["bk"] = ownedCursor(
            reconciled: baselineBytes(bookmarkPayload(uuid: "bk", title: "old")),
            server: baselineBytes(bookmarkPayload(uuid: "bk", title: "old")),
            entityId: "srv-bk", version: 1, ownerUuid: "su-1")
        let bookmarkPlan = SyncableOwnedItems.plan(
            BookmarkKind.self,
            arrivals: [OwnedItemArrival(entity: bookmarkPayload(uuid: "bk", title: "new",
                                                                contentStamp: 900),
                                        entityId: "srv-bk", version: 7)],
            parked: [:], table: bookmarkTable, resolve: resolve, context: OwnedItemPlanContext())
        XCTAssertTrue(bookmarkPlan.preLandingSignatures.isEmpty, "Always empty for bookmarks")
    }

    /// Engine probe: Z moves twice in one round while X never lands. Page 2 uses Z's target at that page's
    /// entry, after page 1 landing, and writes X → Z.
    func testM2b_thePreLandingSignatureIsRecomputedEveryPage() async throws {
        // Z moves space-c/su-3 → space-b/su-2 on page 1, then space-a/su-1 on page 2. X stays in space-b with
        // an unpublished user edit and no landing steps.
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        seedSettled("a", id: "i-z", spaceId: "space-c", target: "su-3", accountStamp: 100,
                    rows: &rows, table: &table)
        seedSettled("b", id: "i-x", spaceId: "space-b", target: "su-2", sortOrder: 1,
                    accountStamp: 100, pendingLocalEdit: true, rows: &rows, table: &table)

        let access = FakeURLRuleAccess(rows: rows)
        let store = MemoryOwnedItemStore()
        store.table = table
        let client = FakePhiSyncClient()
        client.pagesByMarker = [
            page([ruleEntity(urlRulePayload(uuid: "a", targetSpaceUuid: "su-2",
                                            rank: "V", contentStamp: 100, targetStamp: 900,
                                            rankStamp: 900), version: 7)],
                 marker: "7", changesRemaining: true),
            page([ruleEntity(urlRulePayload(uuid: "a", targetSpaceUuid: "su-1",
                                            rank: "V", contentStamp: 100, targetStamp: 1_900,
                                            rankStamp: 1_900), version: 8)],
                 marker: "8"),
        ]
        let engine = try makeRuleEngine(access, store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertEqual(row(access, "a")?.spaceId, "space-a", "Moves from both pages landed")
        XCTAssertEqual(row(access, "b")?.mergePartnerSyncId, "a",
                       "X points to Z because pass two groups by pre-landing targets")
        XCTAssertNil(row(access, "a")?.mergePartnerSyncId, "Z is the anchor")
        let counters = await counters(engine)
        XCTAssertEqual(counters?.collapsed, 0, "Nonstill X leaves fewer than two still members")
    }

    // MARK: - CASE M-6 (concurrent creates converge on one identity; R-M3-4a-67)

    /// Both devices must choose the same survivor despite different local id, createdDate, sortOrder and
    /// insertion order. Depending on any device-specific value deletes different identities on each device.
    /// syncId lexical order is the shared account-level ordering key.
    func testM6_twoDevicesPickTheSameSurvivorDespiteDifferentLocalQuantities() async throws {
        /// One device has the same published, still account pair rule-a/rule-b.
        func makeDevice(_ name: String, layout: [(syncId: String, id: String, sortOrder: Int,
                                                  created: TimeInterval)]) throws
            -> (engine: PhiSyncEngine, access: FakeURLRuleAccess, suite: String) {
            let suite = "URLRuleMergeTests.M6.\(name).\(UUID().uuidString)"
            let deviceDefaults = UserDefaults(suiteName: suite)!
            deviceDefaults.set(try Phi_PhiSettingEntity().serializedData(),
                               forKey: PhiSyncEngine.lastEntityStateKey)
            var rows: [PhiLocalURLRule] = []
            var table = PhiOwnedItemTable()
            for entry in layout {
                seedSettled(entry.syncId, id: entry.id, sortOrder: entry.sortOrder,
                            accountStamp: 100,
                            createdDate: Date(timeIntervalSince1970: entry.created),
                            rows: &rows, table: &table)
            }
            let access = FakeURLRuleAccess(rows: rows)
            let store = MemoryOwnedItemStore()
            store.table = table
            let spaceStore = MemorySpaceStore()
            spaceStore.table.hasDrainedFullReplay = true
            for uuid in ["su-1", "su-2", "su-3"] {
                spaceStore.table.unreadableTagHashes[
                    PhiSyncEntity.clientTagHash(for: PhiSyncEntity.spaceClientTag(uuid))] = 1
            }
            let client = FakePhiSyncClient()
            client.pagesByMarker = [page([], marker: "7")]
            let engine = PhiSyncEngine(domainKeys: StubDomainKeys(key: key), client: client,
                                       defaults: deviceDefaults, deviceKeyId: "dev-\(name)",
                                       settings: [], spaceAccess: makeSpaceAccess(),
                                       spaceStore: spaceStore,
                                       markerStore: markerStore(marker: "0"),
                                       ownedKinds: [.urlRules(access: access, store: store)],
                                       now: { Self.now })
            return (engine, access, suite)
        }

        // A inserts rule-a later, with larger id, later bucket position and newer createdDate.
        let deviceA = try makeDevice("A", layout: [("rule-b", "z-row", 0, 1_000),
                                                   ("rule-a", "a-row", 1, 9_000)])
        // B reverses all device-specific ordering inputs.
        let deviceB = try makeDevice("B", layout: [("rule-a", "z-row", 0, 9_000),
                                                   ("rule-b", "a-row", 1, 1_000)])
        defer {
            UserDefaults.standard.removePersistentDomain(forName: deviceA.suite)
            UserDefaults.standard.removePersistentDomain(forName: deviceB.suite)
        }
        await deviceA.engine.setSpaceSyncEnabled(true)
        await deviceB.engine.setSpaceSyncEnabled(true)
        await deviceA.engine.pullOnce()
        await deviceB.engine.pullOnce()

        let a = await deviceA.engine.lastOwnedRoundCountersForTesting["urlrules"]
        let b = await deviceB.engine.lastOwnedRoundCountersForTesting["urlrules"]
        XCTAssertEqual(a?.collapsed, 1)
        XCTAssertEqual(b?.collapsed, 1)
        // Both soft-delete the identical identity; smallest syncId rule-a survives.
        XCTAssertEqual(liveRows(deviceA.access).compactMap(\.syncId), ["rule-a"])
        XCTAssertEqual(liveRows(deviceB.access).compactMap(\.syncId), ["rule-a"])
        XCTAssertEqual(row(deviceA.access, "rule-b")?.mergePartnerSyncId, "rule-a")
        XCTAssertEqual(row(deviceB.access, "rule-b")?.mergePartnerSyncId, "rule-a")

        // Steady state: two more rounds have collapsed 0.
        for _ in 0..<2 {
            await deviceA.engine.pullOnce()
            await deviceB.engine.pullOnce()
        }
        let steadyA = await deviceA.engine.lastOwnedRoundCountersForTesting["urlrules"]
        let steadyB = await deviceB.engine.lastOwnedRoundCountersForTesting["urlrules"]
        XCTAssertEqual(steadyA?.collapsed, 0)
        XCTAssertEqual(steadyB?.collapsed, 0)
    }

    // MARK: - CASE M2-d (three primitives in one atomic transaction, real LocalStore)

    /// Opening performBackgroundWriteAndWaitThrowing separately per primitive inside the write block
    /// self-deadlocks (R-exec-2). Use throwing public wrappers plus private Body(..., in:) methods; the tail
    /// hook invokes only bodies. Run it before dense reordering or loser removal leaves index gaps that affect
    /// Specificity before arbitration.
    func testM2d_theThreePrimitivesShareOneTransactionAndTheTailRunsBeforeTheDensify() async throws {
        let store = try makeMergeStore()
        try await seedMergeRows(in: store)

        let tail = URLRuleMergeTail { _ in
            URLRuleMergeResult(
                ops: [.setContentGroup(syncId: "W", host: "github.com", pathPrefix: nil,
                                       ask: true, contentUpdatedDate: Date(timeIntervalSince1970: 0.3)),
                      .softDelete(syncId: "L1", mergePartnerSyncId: "W"),
                      .softDelete(syncId: "L2", mergePartnerSyncId: "W"),
                      .setMergePartner(syncId: "M", mergePartnerSyncId: "W")],
                collapsed: 2, touchedBuckets: ["space-a"], changedRouting: true)
        }
        let landing = URLRuleLandingValues.fixture(syncId: "M", spaceId: "space-a",
                                                   host: "other.example", sortOrder: 3)
        let outcome = try await store.applyURLRuleSyncBatchThrowing([.update(landing)],
                                                                    mergeTail: tail)
        XCTAssertEqual(outcome.collapsed, 2)
        XCTAssertTrue(outcome.mergeChangedRouting)
        XCTAssertTrue(outcome.deferredTombstones.isEmpty, "M2 never populates it")

        let after = try mergeRows(in: store)
        let winner = try XCTUnwrap(after["W"])
        XCTAssertTrue(winner.askBeforeRouting, "The content group persisted")
        XCTAssertEqual(winner.contentUpdatedDate, Date(timeIntervalSince1970: 0.3))
        XCTAssertNil(winner.deletedDate)
        for loser in ["L1", "L2"] {
            XCTAssertNotNil(after[loser]?.deletedDate, loser)
            XCTAssertEqual(after[loser]?.mergePartnerSyncId, "W", "\(loser): both columns share one row write")
            XCTAssertFalse(after[loser]?.pendingLocalEdit ?? true, "\(loser): leave pending unchanged")
        }
        XCTAssertEqual(after["M"]?.mergePartnerSyncId, "W")
        // Tail-hook writes precede dense reordering, leaving no gaps after two losers depart.
        let live = after.values.filter { $0.deletedDate == nil }
            .sorted { $0.sortOrder < $1.sortOrder }
        XCTAssertEqual(live.map(\.sortOrder), Array(0..<live.count))
    }

    /// Conflict rolls back the entire batch: after update, absorbed content and first soft deletion, a later
    /// rekey throws rowAlreadyMapped and none persist. Use rekey collision because primitives address by
    /// syncId through bySyncId, making their defensive identity-mismatch guard unreachable under current
    /// addressing. The assertion covers rollback of already executed tail-hook writes.
    func testM2d_aConflictInsideTheTailRollsTheWholeBatchBack() async throws {
        let store = try makeMergeStore()
        try await seedMergeRows(in: store)
        let before = try mergeRows(in: store)

        let tail = URLRuleMergeTail { rows in
            let loser = rows.first { $0.syncId == "L2" }
            return URLRuleMergeResult(
                ops: [.setContentGroup(syncId: "W", host: "github.com", pathPrefix: nil,
                                       ask: true, contentUpdatedDate: Date(timeIntervalSince1970: 0.3)),
                      .softDelete(syncId: "L1", mergePartnerSyncId: "W"),
                      // Rekey L2 to the identity already owned by W, producing rowAlreadyMapped.
                      .rekey(localId: loser?.id ?? "missing", to: "W", values: nil)],
                collapsed: 1, touchedBuckets: ["space-a"], changedRouting: true)
        }
        let landing = URLRuleLandingValues.fixture(syncId: "M", spaceId: "space-a",
                                                   host: "other.example", sortOrder: 3)
        do {
            _ = try await store.applyURLRuleSyncBatchThrowing([.update(landing)], mergeTail: tail)
            XCTFail("expected rowAlreadyMapped")
        } catch {
            XCTAssertEqual(error as? LocalStoreWriteError, .rowAlreadyMapped)
        }

        let after = try mergeRows(in: store)
        XCTAssertEqual(after, before, "W content, L1 deletedDate and M pointer all failed to persist")
    }

    // MARK: - Real-store fixtures for M2-d

    private func makeMergeStore() throws -> LocalStore {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        mergeTempDirectories.append(directory)
        return LocalStore(account: Account(userID: "merge-test-user"),
                          storeDirectoryURL: directory,
                          presentsCompatibilityAlerts: false)
    }

    /// Four live siblings: winner W, losers L1/L2 and bystander M.
    private func seedMergeRows(in store: LocalStore) async throws {
        try await store.performBackgroundWriteAndWaitThrowing { context in
            for (offset, syncId) in ["W", "L1", "L2", "M"].enumerated() {
                context.insert(SpaceURLRule(
                    id: "row-\(syncId)", spaceId: "space-a", host: "github.com",
                    pathPrefix: nil, askBeforeRouting: false, sortOrder: offset,
                    createdDate: Date(timeIntervalSince1970: 1_000), syncId: syncId,
                    contentUpdatedDate: nil, targetUpdatedDate: nil, deletedDate: nil,
                    pendingLocalEdit: false, mergePartnerSyncId: nil))
            }
        }
    }

    private func mergeRows(in store: LocalStore) throws -> [String: PhiLocalURLRule] {
        guard let context = store.getMainContext() else {
            throw LocalStoreWriteError.storeUnavailable
        }
        let models = try store.allURLRuleModelsIncludingDeleted(in: context)
        var out: [String: PhiLocalURLRule] = [:]
        for model in models {
            guard let syncId = model.syncId else { continue }
            out[syncId] = PhiLocalURLRule(
                id: model.id, syncId: model.syncId, spaceId: model.spaceId, host: model.host,
                pathPrefix: model.pathPrefix, askBeforeRouting: model.askBeforeRouting,
                sortOrder: model.sortOrder, createdDate: model.createdDate,
                contentUpdatedDate: model.contentUpdatedDate,
                targetUpdatedDate: model.targetUpdatedDate, deletedDate: model.deletedDate,
                pendingLocalEdit: model.pendingLocalEdit,
                mergePartnerSyncId: model.mergePartnerSyncId)
        }
        return out
    }

    // MARK: - 8b-3 (§8.4.4 yielding): fixtures

    /// Helper for transferSource(of:resolve:); fail immediately if resolution fails because all fixtures are
    /// valid entities.
    private func projection(_ payload: Phi_PhiURLRuleEntity) throws -> RuleProjection {
        try XCTUnwrap(URLRuleKind.transferSource(of: payload, resolve: resolve))
    }

    /// Readable plan steps as phase:identity, with destination for transfers, to assert execution order.
    private func stepSummary(_ steps: [OwnedItemApplyStep]) -> [String] {
        steps.map { step in
            switch step.kind {
            case .claim: return "claim:\(step.identity)"
            case .create: return "create:\(step.identity)"
            case .move: return "move:\(step.identity)"
            case .update: return "update:\(step.identity)"
            case .transfer(_, let to): return "transfer:\(step.identity)->\(to)"
            case .delete: return "delete:\(step.identity)"
            }
        }
    }

    /// Fake-recorded apply operations after URLRuleApplyBatch's four-phase sorting.
    private func opSummary(_ ops: [URLRuleSyncOp]) -> [String] {
        ops.map { op in
            switch op {
            case .create(let values): return "create:\(values.syncId)"
            case .update(let values): return "update:\(values.syncId)"
            case .move(let values): return "move:\(values.syncId)"
            case .reorder(let syncId, _, _): return "reorder:\(syncId)"
            case .delete(let syncId): return "delete:\(syncId)"
            case .rekey(_, let to, _): return "rekey:\(to)"
            case .softDelete(let syncId, _): return "softDelete:\(syncId)"
            case .setMergePartner(let syncId, _): return "setMergePartner:\(syncId)"
            case .setContentGroup(let syncId, _, _, _, _): return "setContentGroup:\(syncId)"
            case .transfer(let from, let to, _, _): return "transfer:\(from)->\(to)"
            }
        }
    }

    // MARK: - CASE 8b-3.1, as amended by ruling C4 (every kind yields)

    /// M3-3 kept the yield switch off for bookmarks and pins on grounds of volume; ruling C4
    /// reverses that, so all three kinds yield now. What stays kind-specific is the TRANSFER
    /// half: bookmarks and pins have no merge partner, so even a populated `mergePartners` can
    /// only produce a yield for them, because their transfer source is always nil.
    func test8b31_everyKindYieldsButOnlyRulesCanTransfer() throws {
        XCTAssertTrue(BookmarkKind.tombstoneYieldsToLocalEdits, "C4: bookmarks yield")
        XCTAssertTrue(PinKind.tombstoneYieldsToLocalEdits, "C4: pins yield")
        XCTAssertTrue(URLRuleKind.tombstoneYieldsToLocalEdits)
        XCTAssertNil(BookmarkKind.transferSource(of: bookmarkPayload(uuid: "bk"), resolve: resolve),
                     "Bookmark transfer source is always nil")
        XCTAssertNil(PinKind.transferSource(of: pinPayload(lineage: "LX"), resolve: resolve),
                     "Pin transfer source is always nil")

        // A bookmark with an unpublished local edit (server != reconciled) receives its tombstone this round.
        var table = PhiOwnedItemTable()
        table.cursors["bk"] = ownedCursor(
            reconciled: baselineBytes(bookmarkPayload(uuid: "bk", title: "local")),
            server: baselineBytes(bookmarkPayload(uuid: "bk", title: "remote")),
            entityId: "srv-bk", version: 1, ownerUuid: "su-1")
        // Populate all four inputs, including the two the bookmark adapter never fills: a
        // partner it cannot describe must still end in a yield, never in a transfer step.
        var context = OwnedItemPlanContext()
        context.tombstonedIdentities = ["bk"]
        context.pendingLocalEdits = ["bk"]
        context.unpublished = ["bk"]
        context.mergePartners = ["bk": "other"]
        let plan = SyncableOwnedItems.plan(BookmarkKind.self, arrivals: [], parked: [:],
                                           table: table, resolve: resolve, context: context)
        XCTAssertTrue(plan.steps.isEmpty, "No delete and no transfer")
        XCTAssertEqual(plan.yieldedTombstones, ["bk"])
        XCTAssertTrue(plan.parkedTombstones.isEmpty)

        // A yielded cursor is excluded from the deletion diff by reconciled == nil and
        // deletedAtMs != nil, so a yield can never tombstone the row it just saved.
        var yielded = PhiOwnedItemTable()
        var cursor = table.cursors["bk"] ?? PhiOwnedItemCursor()
        cursor.reconciled = nil
        cursor.server = nil
        cursor.deletedAtMs = 5_000
        yielded.cursors["bk"] = cursor
        let diff = SyncableOwnedItems.tombstones(BookmarkKind.self, locals: [], table: yielded,
                                                 resolve: resolve, scope: nil, nowMs: 100)
        XCTAssertTrue(diff.identities.isEmpty, "The yield is not echoed back as a local deletion")
    }

    // MARK: - CASE M-22b (C4-a: direction (ii) for rules, and the collapse boundary)

    /// Ruling C4-a extends A9's first conjunct from the target stamp to any merge unit, for rules
    /// too. The collapse loser is kept out of it by BRANCH ORDER rather than by a second
    /// predicate: while its winner exists the transfer or park branch runs first, so an
    /// engine-authored collapse deletion is never the one a content edit cancels.
    func testM22b_aContentEditCancelsARuleDeleteButNotACollapseLosersSoftDelete() throws {
        let baseline = urlRulePayload(uuid: "b", host: "github.com", contentStamp: 100,
                                      targetStamp: 100)
        var table = PhiOwnedItemTable()
        var cursor = publishedRuleCursor(baseline, entityId: "srv-b")
        cursor.pendingDelete = true
        cursor.deleteDecidedAtMs = 200
        table.cursors["b"] = cursor
        // The target is unchanged; only the content group moved, which A9 used to ignore.
        let edited = urlRulePayload(uuid: "b", host: "gitlab.com", contentStamp: 900,
                                    targetStamp: 100)
        let arrival = OwnedItemArrival(entity: edited, entityId: "srv-b", version: 9)

        func planFor(_ mutate: (inout OwnedItemPlanContext) -> Void) -> OwnedItemPlan {
            var context = OwnedItemPlanContext()
            mutate(&context)
            return SyncableOwnedItems.plan(URLRuleKind.self, arrivals: [arrival], parked: [:],
                                           table: table, resolve: resolve, context: context)
        }

        let userDelete = planFor { _ in }
        XCTAssertEqual(userDelete.cancelledDeletes, ["b"],
                       "A content edit newer than the decision now cancels the deletion")
        XCTAssertEqual(userDelete.supersededByDelete, 0)

        // A collapse loser still points at its winner, so the transfer branch runs before A9 and
        // the engine-authored soft delete stands.
        let collapseLoser = planFor { $0.mergePartners = ["b": "a"] }
        XCTAssertEqual(stepSummary(collapseLoser.steps), ["transfer:b->a"])
        XCTAssertTrue(collapseLoser.cancelledDeletes.isEmpty,
                      "A collapse loser's soft delete is not a user delete an edit may beat")

        let busyWinner = planFor { $0.partnerNotAtRest = ["b"] }
        XCTAssertTrue(busyWinner.cancelledDeletes.isEmpty, "Parking still precedes A9")
        XCTAssertNotNil(busyWinner.parked["b"])
    }

    // MARK: - CASE 8b-3.2 (parkedTombstones on normal return)

    /// Filling parkedTombstones only on §7.3's whole-batch early return leaves normal returns at default
    /// empty, silently losing deletion after metadata harvest and marker advancement.
    func test8b32_aParkedTombstoneRidesTheNormalReturnPathAlongsideALanding() throws {
        var table = PhiOwnedItemTable()
        table.cursors["b"] = publishedRuleCursor(urlRulePayload(uuid: "b"), entityId: "srv-b")
        table.cursors["y"] = publishedRuleCursor(urlRulePayload(uuid: "y", host: "y.example"),
                                                 entityId: "srv-y")
        var context = OwnedItemPlanContext()
        context.tombstonedIdentities = ["b"]
        context.pendingLocalEdits = ["b"]
        context.partnerNotAtRest = ["b"]          // W exists but is not still
        let arrival = OwnedItemArrival(
            entity: urlRulePayload(uuid: "y", host: "y2.example", contentStamp: 900),
            entityId: "srv-y", version: 7)
        let plan = SyncableOwnedItems.plan(URLRuleKind.self, arrivals: [arrival], parked: [:],
                                           table: table, resolve: resolve, context: context)

        XCTAssertEqual(plan.parkedTombstones, ["b"], "Per-identity parking follows the normal return path")
        XCTAssertTrue(plan.yieldedTombstones.isEmpty, "Parking is not yielding")
        XCTAssertFalse(plan.steps.contains { $0.identity == "b" },
                       "No delete is produced; the row remains unchanged")
        XCTAssertEqual(stepSummary(plan.steps), ["update:y"], "Other identities on the same page land normally")
    }

    // MARK: - CASE M-12 / M-21 / M-24 (three α outcomes, module coverage)

    /// α outcomes: still W transfers then deletes X normally; present-but-not-still W parks without delete;
    /// absent partner takes (ii) without delete. Falling back to (ii) for temporarily ineligible W leaves two
    /// rules (RR8-7). Soft deletion after α instead of hard deletion emits an unnecessary next-round tombstone
    /// (M-21).
    func testM12_theThreeOutcomesOfAnInboundTombstoneMeetingALocalEdit() throws {
        let xPayload = urlRulePayload(uuid: "b", targetSpaceUuid: "su-2", contentStamp: 30,
                                      targetStamp: 30)
        var table = PhiOwnedItemTable()
        table.cursors["a"] = publishedRuleCursor(urlRulePayload(uuid: "a"), entityId: "srv-a")
        table.cursors["b"] = publishedRuleCursor(xPayload, entityId: "srv-b")

        func planFor(_ mutate: (inout OwnedItemPlanContext) -> Void) -> OwnedItemPlan {
            var context = OwnedItemPlanContext()
            context.tombstonedIdentities = ["b"]
            context.pendingLocalEdits = ["b"]
            context.localProjections["b"] = baselineBytes(xPayload)
            mutate(&context)
            return SyncableOwnedItems.plan(URLRuleKind.self, arrivals: [], parked: [:],
                                           table: table, resolve: resolve, context: context)
        }

        // Branch (i): transfer in phase 3, hard delete in phase 4, in one batch/transaction.
        let transferred = planFor { $0.mergePartners = ["b": "a"] }
        XCTAssertEqual(stepSummary(transferred.steps), ["transfer:b->a", "delete:b"],
                       "Transfer precedes hard deletion")
        XCTAssertTrue(transferred.yieldedTombstones.isEmpty)
        XCTAssertTrue(transferred.parkedTombstones.isEmpty)
        let expectedSource = try projection(xPayload)
        if case .transfer(let source, let to) = transferred.steps[0].kind {
            XCTAssertEqual(to, "a")
            XCTAssertEqual(source, expectedSource, "Source values come from X's local projection")
            XCTAssertEqual(source.targetSpaceId, "space-b", "Account target resolves to a local Space ID")
        } else {
            XCTFail("The first step must be transfer")
        }

        // Parking branch emits no delete.
        let parked = planFor { $0.partnerNotAtRest = ["b"] }
        XCTAssertEqual(parked.parkedTombstones, ["b"])
        XCTAssertTrue(parked.steps.isEmpty, "The row remains unchanged byte for byte")

        // Branch (ii): no partner row exists.
        let yielded = planFor { _ in }
        XCTAssertEqual(yielded.yieldedTombstones, ["b"])
        XCTAssertTrue(yielded.steps.isEmpty, "Plan emits no delete step for it")
        XCTAssertTrue(yielded.parkedTombstones.isEmpty, "Yielding is not parking")

        // Missing projection/source values take (ii), without parking or hard deletion (ruling 3 final
        // paragraph / C-19).
        var unresolvable = OwnedItemPlanContext()
        unresolvable.tombstonedIdentities = ["b"]
        unresolvable.pendingLocalEdits = ["b"]
        unresolvable.mergePartners = ["b": "a"]
        let noSource = SyncableOwnedItems.plan(URLRuleKind.self, arrivals: [], parked: [:],
                                               table: table, resolve: resolve,
                                               context: unresolvable)
        XCTAssertEqual(noSource.yieldedTombstones, ["b"], "Missing projection takes branch (ii)")
        XCTAssertTrue(noSource.steps.isEmpty)

        // M-24 race 4: no local intent on the loser means neither disjunct holds, so hard-delete normally.
        var settled = OwnedItemPlanContext()
        settled.tombstonedIdentities = ["b"]
        settled.mergePartners = ["b": "a"]
        settled.localProjections["b"] = baselineBytes(xPayload)
        let hardDeleted = SyncableOwnedItems.plan(URLRuleKind.self, arrivals: [], parked: [:],
                                                  table: table, resolve: resolve, context: settled)
        XCTAssertEqual(stepSummary(hardDeleted.steps), ["delete:b"], "No transfer")
        XCTAssertTrue(hardDeleted.yieldedTombstones.isEmpty)
    }

    /// α also yields when unpublished alone is true. Checking only pendingLocalEdit would miss a local field
    /// won during landing but not yet published (M-19(e)).
    func testM19e_theUnpublishedDisjunctAloneIsEnoughToYield() throws {
        var table = PhiOwnedItemTable()
        table.cursors["b"] = publishedRuleCursor(urlRulePayload(uuid: "b"), entityId: "srv-b")
        var context = OwnedItemPlanContext()
        context.tombstonedIdentities = ["b"]
        context.unpublished = ["b"]               // pendingLocalEdit is false
        let plan = SyncableOwnedItems.plan(URLRuleKind.self, arrivals: [], parked: [:],
                                           table: table, resolve: resolve, context: context)
        XCTAssertEqual(plan.yieldedTombstones, ["b"])
        XCTAssertTrue(plan.steps.isEmpty)
    }

    // MARK: - CASE M-22 (race 2: β, module coverage)

    /// β outcomes: still W receives transfer while X retains soft deletion/pendingDelete; present nonstill W
    /// parks the live arrival in parked, not parkedTombstones; otherwise retain A9 behavior. Copying α's
    /// live-row/disjunction requirements would never yield and leave Z@S2 plus X@S1. Source values must come
    /// from inbound payload, not X's stale soft-deleted row.
    func testM22_theThreeOutcomesOfTheA9Branch() throws {
        // Published X is pendingDelete after B's M2 tombstone conflicted; inbound payload is A's retarget.
        let baseline = urlRulePayload(uuid: "b", targetSpaceUuid: "su-2", contentStamp: 100,
                                      targetStamp: 100)
        var table = PhiOwnedItemTable()
        var cursor = publishedRuleCursor(baseline, entityId: "srv-b")
        cursor.pendingDelete = true
        cursor.deleteDecidedAtMs = 200
        table.cursors["b"] = cursor
        let inbound = urlRulePayload(uuid: "b", targetSpaceUuid: "su-1", contentStamp: 100,
                                     targetStamp: 900)
        let arrival = OwnedItemArrival(entity: inbound, entityId: "srv-b", version: 9)

        func planFor(_ mutate: (inout OwnedItemPlanContext) -> Void) -> OwnedItemPlan {
            var context = OwnedItemPlanContext()
            mutate(&context)
            return SyncableOwnedItems.plan(URLRuleKind.self, arrivals: [arrival], parked: [:],
                                           table: table, resolve: resolve, context: context)
        }

        // Still W receives transfer from the inbound entity, not the soft-deleted local row.
        let transferred = planFor { $0.mergePartners = ["b": "a"] }
        XCTAssertEqual(stepSummary(transferred.steps), ["transfer:b->a"],
                       "No delete is produced; X retains soft deletion and pendingDelete")
        XCTAssertTrue(transferred.cancelledDeletes.isEmpty, "Do not cancel the local deletion")
        XCTAssertTrue(transferred.parked.isEmpty, "The inbound entity neither lands nor parks")
        if case .transfer(let source, _) = transferred.steps[0].kind {
            XCTAssertEqual(source.targetOwnerUuid, "su-1", "Source target comes from inbound merged payload")
            XCTAssertEqual(source.targetUpdatedDate,
                           Date(timeIntervalSince1970: 0.9), "Copy the inbound target stamp")
        } else {
            XCTFail("Must be transfer")
        }

        // Present nonstill W parks the inbound live entity in parked, never parkedTombstones.
        let parked = planFor { $0.partnerNotAtRest = ["b"] }
        XCTAssertTrue(parked.steps.isEmpty)
        XCTAssertNotNil(parked.parked["b"], "Cursor retains pendingApply and pendingOwnerUuid")
        XCTAssertEqual(parked.parked["b"]?.pendingOwnerUuid, "su-1")
        XCTAssertTrue(parked.parkedTombstones.isEmpty, "Never set pendingTombstone")
        XCTAssertTrue(parked.cancelledDeletes.isEmpty)

        // Otherwise A9 applies: location newer than deletion decision with a live parent cancels deletion.
        let a9 = planFor { _ in }
        XCTAssertEqual(a9.cancelledDeletes, ["b"], "A9's three conjunction terms remain unchanged")
        XCTAssertTrue(a9.steps.contains { $0.identity == "b" })
    }

    // MARK: - CASE M-34 ① (transfer between update and delete; R-M3-4a-93)

    /// Putting transfer in phase 1 would apply X@30 to pre-landing W@10, then overwrite it with plan's
    /// precomputed update true@20 before deleting X. The newer edit would be irretrievably lost; update must
    /// precede transfer.
    func testM34_theTransferPhaseRunsAfterTheUpdateAndBeforeTheDelete() throws {
        let wBaseline = urlRulePayload(uuid: "a", host: "w.example", ask: false, contentStamp: 10)
        let xProjection = urlRulePayload(uuid: "c", host: "w.example", ask: false, contentStamp: 30)
        var table = PhiOwnedItemTable()
        table.cursors["a"] = publishedRuleCursor(wBaseline, entityId: "srv-a")
        table.cursors["c"] = publishedRuleCursor(xProjection, entityId: "srv-c")

        var context = OwnedItemPlanContext()
        context.tombstonedIdentities = ["c"]
        context.pendingLocalEdits = ["c"]
        context.mergePartners = ["c": "a"]
        context.localProjections["c"] = baselineBytes(xProjection)
        let arrival = OwnedItemArrival(
            entity: urlRulePayload(uuid: "a", host: "w.example", ask: true, contentStamp: 20),
            entityId: "srv-a", version: 9)
        let plan = SyncableOwnedItems.plan(URLRuleKind.self, arrivals: [arrival], parked: [:],
                                           table: table, resolve: resolve, context: context)
        XCTAssertEqual(stepSummary(plan.steps), ["update:a", "transfer:c->a", "delete:c"],
                       "Four-phase order: update, transfer, delete")

        // Verify the same order in URLRuleApplyBatch's three operation groups.
        let values = URLRuleLandingValues.fixture(syncId: "a", spaceId: "space-a")
        let batch = URLRuleApplyBatch(unordered: [
            .delete(syncId: "c"),
            .transfer(fromSyncId: "c", toSyncId: "a", source: try projection(xProjection),
                      targetEffectiveStamps: URLRuleEffectiveStamps()),
            .update(values),
        ])
        XCTAssertEqual(opSummary(batch.ops), ["update:a", "transfer:c->a", "delete:c"],
                       "Phase ordering overrides input order while remaining stable within each phase")
    }

    // MARK: - CASE 8b-3.3 (deferredDeletions performs no bookkeeping)

    /// Filtering only at slice construction after normal diff would clear pendingApply and rewrite
    /// deleteDecidedAtMs. Next round the guard's second conjunction fails, and A9's comparison threshold
    /// continually moves forward.
    func test8b33_aDeferredDeletionWritesNothingAtAllIntoTheCursorTable() throws {
        var table = PhiOwnedItemTable()
        var deferred = pendingDeleteCursor(decidedAtMs: 700, entityId: "srv-b", version: 3,
                                           reconciled: baselineBytes(urlRulePayload(uuid: "b")))
        deferred.server = deferred.reconciled
        deferred.ownerUuid = "su-1"
        deferred.pendingApply = baselineBytes(urlRulePayload(uuid: "b", targetSpaceUuid: "su-2"))
        deferred.pendingOwnerUuid = "su-2"
        table.cursors["b"] = deferred
        // Control: another locally absent identity outside the guard emits its tombstone normally.
        table.cursors["z"] = ownedCursor(reconciled: baselineBytes(urlRulePayload(uuid: "z")),
                                         server: baselineBytes(urlRulePayload(uuid: "z")),
                                         entityId: "srv-z", version: 4, ownerUuid: "su-1")

        let result = SyncableOwnedItems.tombstones(URLRuleKind.self, locals: [], table: table,
                                                   resolve: resolve, scope: nil, nowMs: 900,
                                                   deferredDeletions: ["b"])
        XCTAssertEqual(result.identities, ["z"], "Guarded identities are excluded from identities")
        XCTAssertNil(result.cursorUpdates["b"], "No cursorUpdates")
        XCTAssertEqual(result.deferred, ["b"], "Return unchanged")
        XCTAssertNotNil(result.cursorUpdates["z"], "Other identities receive normal bookkeeping in this pass")
        // Engine guard's third term must subtract deferred: an already pendingDelete identity creates no new
        // cursorUpdate but still enters candidates through the existing filter.
        XCTAssertTrue(table.cursors["b"]?.pendingDelete == true
                        && table.cursors["b"]?.deletedAtMs == nil,
                      "Both conjunction terms of the existing filter hold")
    }

    // MARK: - CASE M-23 control 2 / M-26 (partner lookup order and two result sets)

    /// RR10-7 lookup order: use a still pointer target; if missing or nonstill, try fallback; if neither
    /// yields one, distinguish a present nonstill partner from no partner. Pointer-only parking fails M-23
    /// control 2; conflating those last outcomes violates RR10-3.
    func testM23b_thePartnerLookupFallsBackWhenThePointerIsNotAtRest() throws {
        var table = PhiOwnedItemTable()
        // X needs reconsideration and points to an anchor that can never become still because its hidden
        // target loses signature eligibility.
        let baseline = urlRulePayload(uuid: "x")
        table.cursors["x"] = publishedRuleCursor(baseline, entityId: "srv-x")
        table.cursors["anchor"] = publishedRuleCursor(urlRulePayload(uuid: "anchor"),
                                                      entityId: "srv-anchor")
        table.cursors["settled"] = publishedRuleCursor(urlRulePayload(uuid: "settled"),
                                                       entityId: "srv-settled")
        let rows = [
            PhiLocalURLRule.fixture(id: "i-x", syncId: "x", pendingLocalEdit: true,
                                    mergePartnerSyncId: "anchor"),
            // The anchor is live but targets an agent Space with no signature, permanently failing stillness
            // predicate 8.
            PhiLocalURLRule.fixture(id: "i-anchor", syncId: "anchor", spaceId: "agent-space",
                                    sortOrder: 1),
            PhiLocalURLRule.fixture(id: "i-settled", syncId: "settled", sortOrder: 2),
        ]
        let access = FakeURLRuleAccess(rows: rows)
        let partners = access.mergePartners(table: table, resolve: resolve, tombstonesThisPage: [])
        XCTAssertEqual(partners["x"], "settled", "Fallback selects the still live row")
        XCTAssertFalse(access.partnerNotAtRest(table: table, rows: rows, resolve: resolve,
                                               tombstonesThisPage: []).contains("x"),
                       "Resolvable W prevents parking")
    }

    /// M-26 predicate 10: W's tombstone also arrives this page, so W is not still and X enters
    /// partnerNotAtRest parking, not (ii). Only after W disappears may (ii) apply.
    func testM26_aPartnerDyingOnThisPageParksInsteadOfYielding() throws {
        var table = PhiOwnedItemTable()
        table.cursors["a"] = publishedRuleCursor(urlRulePayload(uuid: "a"), entityId: "srv-a")
        table.cursors["b"] = publishedRuleCursor(urlRulePayload(uuid: "b"), entityId: "srv-b")
        let rows = [
            PhiLocalURLRule.fixture(id: "i-a", syncId: "a"),
            PhiLocalURLRule.fixture(id: "i-b", syncId: "b", sortOrder: 1, pendingLocalEdit: true,
                                    mergePartnerSyncId: "a"),
        ]
        let access = FakeURLRuleAccess(rows: rows)
        let settled = access.mergePartners(table: table, resolve: resolve, tombstonesThisPage: [])
        XCTAssertEqual(settled["b"], "a", "W is still without this page's tombstone")
        XCTAssertTrue(access.mergePartners(table: table, resolve: resolve,
                                           tombstonesThisPage: ["a", "b"]).isEmpty,
                      "Predicate 10 makes W nonstill on this page")
        XCTAssertTrue(access.partnerNotAtRest(table: table, rows: rows, resolve: resolve,
                                              tombstonesThisPage: ["a", "b"]).contains("b"),
                      "Present nonstill W parks rather than taking (ii)")

        // W is absent: no still partner and no partner row, so neither set contains X and branch (ii) applies.
        let orphan = FakeURLRuleAccess(rows: [rows[1]])
        XCTAssertTrue(orphan.mergePartners(table: table, resolve: resolve,
                                           tombstonesThisPage: []).isEmpty)
        XCTAssertTrue(orphan.partnerNotAtRest(table: table, rows: [rows[1]], resolve: resolve,
                                              tombstonesThisPage: []).isEmpty,
                      "A dangling pointer is not a present partner, which would park indefinitely")
    }

    /// β's domain includes soft-deleted rows (RR8-1). Copying α's deletedDate == nil filter empties both
    /// lookup tables for β and defeats reconsideration protection.
    func testM22_theGuardDomainIncludesSoftDeletedRows() throws {
        var table = PhiOwnedItemTable()
        table.cursors["a"] = publishedRuleCursor(urlRulePayload(uuid: "a"), entityId: "srv-a")
        var pending = publishedRuleCursor(urlRulePayload(uuid: "b"), entityId: "srv-b")
        pending.pendingDelete = true
        table.cursors["b"] = pending
        // W is nonstill with parked payload; soft-deleted X points to W.
        table.cursors["a"]?.pendingApply = baselineBytes(urlRulePayload(uuid: "a"))
        let rows = [
            PhiLocalURLRule.fixture(id: "i-a", syncId: "a"),
            PhiLocalURLRule.fixture(id: "i-b", syncId: "b", sortOrder: 1,
                                    deletedDate: Date(timeIntervalSince1970: 5),
                                    mergePartnerSyncId: "a"),
        ]
        let access = FakeURLRuleAccess(rows: rows)
        XCTAssertEqual(access.partnerNotAtRest(table: table, rows: rows, resolve: resolve,
                                               tombstonesThisPage: []),
                       ["b"], "Soft-deleted X still enters the guard")
        XCTAssertTrue(access.partnerNotAtRest(table: table,
                                              rows: rows.filter { $0.deletedDate == nil },
                                              resolve: resolve, tombstonesThisPage: []).isEmpty,
                      "Using allURLRules for rows must fail this assertion")
    }

    // MARK: - CASE 8b-3.5 / 8b-3.6 / M-34(b)(c) (per-unit transfer LWW, value coverage)

    /// Four parts of ruling 9: unconditional flagging leaves W permanently pending (8b-3.5); field-by-field
    /// transfer wrongly copies X's ask/content stamp (8b-3.6); using only W's row stamp overwrites newer
    /// account values in M-34(c).
    func test8b35_theTransferWritesOnlyTheUnitsItWins() throws {
        let target = PhiLocalURLRule.fixture(id: "i-w", syncId: "a", host: "w.example",
                                             contentUpdatedDate: stampDate(100),
                                             targetUpdatedDate: stampDate(100))

        // 8b-3.5: both units lose, so no write, pending flag or transferred count.
        let stale = try projection(urlRulePayload(uuid: "b", targetSpaceUuid: "su-2",
                                                  host: "x.example", contentStamp: 10,
                                                  targetStamp: 10))
        let lost = URLRuleKind.transferDecision(target: target, source: stale,
                                                targetEffectiveStamps: URLRuleEffectiveStamps())
        XCTAssertEqual(lost.written, 0)
        XCTAssertTrue(lost.contentSuperseded)

        // 8b-3.6: newer target but older content transfers only the target unit, leaving all three content
        // fields untouched.
        let split = try projection(urlRulePayload(uuid: "b", targetSpaceUuid: "su-2",
                                                  host: "x.example", contentStamp: 10,
                                                  targetStamp: 900))
        let partial = URLRuleKind.transferDecision(target: target, source: split,
                                                   targetEffectiveStamps: URLRuleEffectiveStamps())
        XCTAssertFalse(partial.writesContent, "Do not transfer any content-group fields")
        XCTAssertTrue(partial.writesTarget)
        XCTAssertEqual(partial.written, 1)
        XCTAssertTrue(partial.contentSuperseded, "Count one superseded_by_delete")

        // M-34(c): W has account stamp 40 and stale row stamp 10; max is 40, so source 30 loses.
        let laggingRow = PhiLocalURLRule.fixture(id: "i-w", syncId: "a", host: "w.example",
                                                 contentUpdatedDate: stampDate(10))
        let edit = try projection(urlRulePayload(uuid: "c", host: "w.example", ask: true,
                                                 contentStamp: 30, targetStamp: 30))
        let againstAccount = URLRuleKind.transferDecision(
            target: laggingRow, source: edit,
            targetEffectiveStamps: URLRuleEffectiveStamps(content: stampDate(40), target: nil))
        XCTAssertFalse(againstAccount.writesContent,
                       "max(row stamp 10, account stamp 40) defeats 30; row-only comparison must fail")
        // Related case: nil row stamp (Task 5 ruling 5) with account stamp 40 yields the same result.
        let freshRow = PhiLocalURLRule.fixture(id: "i-w", syncId: "a", host: "w.example")
        XCTAssertFalse(URLRuleKind.transferDecision(
            target: freshRow, source: edit,
            targetEffectiveStamps: URLRuleEffectiveStamps(content: stampDate(40),
                                                          target: nil)).writesContent)
        // Conversely, absent account stamp falls back to row stamp; 30 beats 10, preserving the prior
        // fail-open behavior.
        XCTAssertTrue(URLRuleKind.transferDecision(
            target: laggingRow, source: edit,
            targetEffectiveStamps: URLRuleEffectiveStamps()).writesContent)

        // Nil targetSpaceId skips target transfer without writing, failing closed.
        var unmapped = try projection(urlRulePayload(uuid: "b", contentStamp: 10,
                                                     targetStamp: 900))
        unmapped.targetSpaceId = nil
        XCTAssertFalse(URLRuleKind.transferDecision(
            target: target, source: unmapped,
            targetEffectiveStamps: URLRuleEffectiveStamps()).writesTarget)
    }

    // MARK: - CASE M-37 (transaction rechecks source after prepass; R-M3-4a-102)

    /// Value-level recheck predicate. Without it, transfer uses E1 then deletes the row containing E2, losing
    /// E2 everywhere. Always parking would instead prevent branch (i) from ever finishing.
    func testM37_theInTransactionSourceRecheck() throws {
        let row = PhiLocalURLRule.fixture(id: "i-x", syncId: "b", host: "e1.example",
                                          contentUpdatedDate: stampDate(30),
                                          pendingLocalEdit: true, mergePartnerSyncId: "a")
        let source = try projection(urlRulePayload(uuid: "b", host: "e1.example",
                                                   contentStamp: 30, targetStamp: 30))
        XCTAssertTrue(URLRuleKind.transferSourceUnchanged(row: row, source: source),
                      "Unchanged source preserves the existing path")

        var saved = row
        saved.host = "e2.example"
        saved.contentUpdatedDate = stampDate(40)
        XCTAssertFalse(URLRuleKind.transferSourceUnchanged(row: saved, source: source),
                       "The user saved between prepass and transaction")

        var retargeted = row
        retargeted.spaceId = "space-c"
        retargeted.targetUpdatedDate = stampDate(40)
        XCTAssertFalse(URLRuleKind.transferSourceUnchanged(row: retargeted, source: source),
                       "A target-only Save also blocks transfer")

        var softDeleted = row
        softDeleted.deletedDate = Date(timeIntervalSince1970: 9)
        XCTAssertFalse(URLRuleKind.transferSourceUnchanged(row: softDeleted, source: source),
                       "Nonnil deletedDate also counts as changed; soft deletion requires branch β")
        XCTAssertFalse(URLRuleKind.transferSourceUnchanged(row: nil, source: source),
                       "The row is absent")

        // Sub-millisecond differences do not count: convert both sides to milliseconds before comparing
        // (ruling 11).
        var jittered = row
        jittered.contentUpdatedDate = Date(timeIntervalSince1970: 0.0300001)
        XCTAssertTrue(URLRuleKind.transferSourceUnchanged(row: jittered, source: source),
                      "Unconditionally parking for one round must fail")
    }

    // MARK: - transferTargets versus landedIdentities (R-M3-4a-90 / RR12-6)

    /// Transfer targets leave this page's M2 candidate set. Transfer identities do not enter landedIdentities;
    /// outcome.landed is a superset and cannot replace it.
    func testM33_transferTargetsLeaveThisPagesMergeCandidateSet() throws {
        let steps = [
            OwnedItemApplyStep(identity: "c", kind: .transfer(source: try projection(
                urlRulePayload(uuid: "c")), to: "a"), newParentUuid: nil, newRank: nil,
                               payload: nil),
            OwnedItemApplyStep(identity: "y", kind: .update, newParentUuid: nil, newRank: nil,
                               payload: nil),
            OwnedItemApplyStep(identity: "c", kind: .delete, newParentUuid: nil, newRank: nil,
                               payload: nil),
        ]
        XCTAssertEqual(URLRuleKind.transferTargets(in: steps), ["a"])
        XCTAssertEqual(URLRuleKind.landedIdentities(in: steps), ["y"],
                       "Neither transfer nor delete belongs to this set")
    }

    // MARK: - CASE M-12 / M-21 (full engine round through α branch (i))

    /// A page contains only X's tombstone; X has an unpublished edit and points to still W. End with one rule,
    /// not two. Soft-deleting after α rather than hard-deleting would emit an unnecessary tombstone next round
    /// and retain the row for 30 days (RR8-5).
    func testM21_anInboundTombstoneTransfersTheEditAndHardDeletesTheLoser() async throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        seedSettled("a", id: "i-a", ask: false, accountStamp: 10, rows: &rows, table: &table)
        seedSettled("b", id: "i-b", ask: true, sortOrder: 1, accountStamp: 30,
                    rowContentUpdatedDate: stampDate(30), pendingLocalEdit: true,
                    mergePartnerSyncId: "a", rows: &rows, table: &table)

        let access = FakeURLRuleAccess(rows: rows)
        let store = MemoryOwnedItemStore()
        store.table = table
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([remoteTombstone(tag: ruleTag("b"), version: 40,
                                                      entityId: "srv-b")], marker: "7")]
        let engine = try makeRuleEngine(access, store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        // ① No W update arrives, so operation order is just transfer then hard delete.
        XCTAssertEqual(opSummary(access.lastAppliedOps), ["transfer:b->a", "delete:b"])
        // ② W receives the edit; X is absent even from allURLRulesIncludingDeleted.
        let w = try XCTUnwrap(row(access, "a"))
        XCTAssertEqual(w.askBeforeRouting, true, "The whole content group transfers")
        XCTAssertEqual(w.contentUpdatedDate, stampDate(30), "Copy the source stamp without minting now")
        XCTAssertTrue(w.pendingLocalEdit, "Writing a unit sets pending")
        XCTAssertNil(row(access, "b"), "X is hard-deleted, not soft-deleted")
        let counters = await counters(engine)
        XCTAssertEqual(counters?.transferred, 1)
        XCTAssertEqual(counters?.resurrected, 0)
        XCTAssertEqual(counters?.yieldNoPartner, 0)
        // ③ X's cursor follows ordinary tombstone bookkeeping.
        let cursor = await engine.ownedTableForTesting("urlrules").cursors["b"]
        XCTAssertNil(cursor?.reconciled)
        XCTAssertNil(cursor?.server)
        XCTAssertNotNil(cursor?.deletedAtMs)
        XCTAssertEqual(cursor?.pendingDelete, false)
        XCTAssertEqual(cursor?.pendingTombstone, false)
    }

    /// Landing failure rolls back transfer and delete together in one transaction, preserving both rows byte
    /// for byte.
    func testM21_aFailedLandingRollsBackBothTheTransferAndTheDelete() async throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        seedSettled("a", id: "i-a", ask: false, accountStamp: 10, rows: &rows, table: &table)
        seedSettled("b", id: "i-b", ask: true, sortOrder: 1, accountStamp: 30,
                    rowContentUpdatedDate: stampDate(30), pendingLocalEdit: true,
                    mergePartnerSyncId: "a", rows: &rows, table: &table)

        let access = FakeURLRuleAccess(rows: rows)
        access.failApplyOnce = true
        let store = MemoryOwnedItemStore()
        store.table = table
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([remoteTombstone(tag: ruleTag("b"), version: 40,
                                                      entityId: "srv-b")], marker: "7")]
        let engine = try makeRuleEngine(access, store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertEqual(row(access, "a")?.askBeforeRouting, false, "W's row is unchanged")
        XCTAssertFalse(try XCTUnwrap(row(access, "a")).pendingLocalEdit)
        XCTAssertNotNil(row(access, "b"), "X's row remains")
        let counters = await counters(engine)
        XCTAssertEqual(counters?.transferred, 0)
        let cursor = await engine.ownedTableForTesting("urlrules").cursors["b"]
        XCTAssertEqual(cursor?.pendingTombstone, true, "Park the whole batch for next-round reconsideration")
        XCTAssertNotNil(cursor?.reconciled, "No baseline bytes were written")
    }

    // MARK: - CASE 8b-3.5 (no-op transfer leaves flags/count unchanged; X still hard-deletes)

    /// Unconditional pending flagging would make W permanently nonstill and yield to every future remote
    /// deletion.
    func test8b35_aZeroUnitTransferStillHardDeletesTheLoser() async throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        // Both W account stamps are newer than X, so both units lose.
        seedSettled("a", id: "i-a", ask: false, accountStamp: 900, rows: &rows, table: &table)
        seedSettled("b", id: "i-b", ask: true, sortOrder: 1, accountStamp: 30,
                    rowContentUpdatedDate: stampDate(30), pendingLocalEdit: true,
                    mergePartnerSyncId: "a", rows: &rows, table: &table)

        let access = FakeURLRuleAccess(rows: rows)
        let store = MemoryOwnedItemStore()
        store.table = table
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([remoteTombstone(tag: ruleTag("b"), version: 40,
                                                      entityId: "srv-b")], marker: "7")]
        let engine = try makeRuleEngine(access, store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let w = try XCTUnwrap(row(access, "a"))
        XCTAssertEqual(w.askBeforeRouting, false, "W's row is unchanged byte for byte")
        XCTAssertNil(w.contentUpdatedDate)
        XCTAssertFalse(w.pendingLocalEdit, "No writes means no pending flag")
        XCTAssertNil(row(access, "b"), "The delete still proceeds despite no transfer writes")
        let counters = await counters(engine)
        XCTAssertEqual(counters?.transferred, 0)
        XCTAssertEqual(counters?.supersededByDelete, 1, "Count the losing content group once (§13.3)")
    }

    // MARK: - CASE M-37 (real user Save after prepass, engine coverage; R-M3-4a-102)

    /// A reachable user Save occurs between main-actor prepass and write-queue transaction. Without recheck,
    /// E1 transfers before deleting X containing E2, silently losing E2 locally and remotely.
    func testM37_anEditToTheSourceRowBetweenThePrePassAndTheTransactionDefersBothOps() async throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        seedSettled("a", id: "i-a", ask: false, accountStamp: 10, rows: &rows, table: &table)
        seedSettled("b", id: "i-b", ask: true, sortOrder: 1, accountStamp: 30,
                    rowContentUpdatedDate: stampDate(30), pendingLocalEdit: true,
                    mergePartnerSyncId: "a", rows: &rows, table: &table)

        let access = FakeURLRuleAccess(rows: rows)
        let store = MemoryOwnedItemStore()
        store.table = table
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([remoteTombstone(tag: ruleTag("b"), version: 40,
                                                      entityId: "srv-b")], marker: "7")]
        // Inject a real editor-style user write immediately before the transaction, after prepass froze E1.
        access.beforeLandingTransaction = { [weak access] in
            access?.applyEditorSave(syncId: "b", host: "e2.example",
                                    at: Date(timeIntervalSince1970: 0.040))
        }
        let engine = try makeRuleEngine(access, store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        // W remains unchanged and X survives with E2.
        let w = try XCTUnwrap(row(access, "a"))
        XCTAssertEqual(w.askBeforeRouting, false)
        XCTAssertNil(w.contentUpdatedDate)
        XCTAssertFalse(w.pendingLocalEdit)
        let x = try XCTUnwrap(row(access, "b"))
        XCTAssertEqual(x.host, "e2.example")
        XCTAssertEqual(x.contentUpdatedDate, Date(timeIntervalSince1970: 0.040))
        XCTAssertTrue(x.pendingLocalEdit)
        let counters = await counters(engine)
        XCTAssertEqual(counters?.transferred, 0)
        XCTAssertEqual(counters?.resurrected, 0)
        // Cursor sets pendingTombstone and harvests metadata, preserving both baselines and deletedAtMs.
        let cursor = await engine.ownedTableForTesting("urlrules").cursors["b"]
        XCTAssertEqual(cursor?.pendingTombstone, true)
        XCTAssertEqual(cursor?.version, 40, "Harvest server metadata normally")
        XCTAssertNotNil(cursor?.reconciled)
        XCTAssertNotNil(cursor?.server)
        XCTAssertNil(cursor?.deletedAtMs, "Never enter deleted")

        // Next round retries the parked tombstone; prepass now captures E2.
        access.beforeLandingTransaction = nil
        client.pagesByMarker = [page([], marker: "8")]
        await engine.pullOnce()

        let movedOn = try XCTUnwrap(row(access, "a"))
        XCTAssertEqual(movedOn.host, "e2.example", "Transfer uses E2")
        XCTAssertEqual(movedOn.contentUpdatedDate, Date(timeIntervalSince1970: 0.040))
        XCTAssertTrue(movedOn.pendingLocalEdit)
        XCTAssertNil(row(access, "b"), "Only then is X hard-deleted")
        let second = await self.counters(engine)
        XCTAssertEqual(second?.transferred, 1)
    }

    /// No-op-hook control leaves projections equal, allowing transfer and delete normally. Recheck blocks only
    /// real changes, not every first attempt.
    func testM37_anUnchangedSourceRowExecutesBothOpsExactlyAsBefore() async throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        seedSettled("a", id: "i-a", ask: false, accountStamp: 10, rows: &rows, table: &table)
        seedSettled("b", id: "i-b", ask: true, sortOrder: 1, accountStamp: 30,
                    rowContentUpdatedDate: stampDate(30), pendingLocalEdit: true,
                    mergePartnerSyncId: "a", rows: &rows, table: &table)

        let access = FakeURLRuleAccess(rows: rows)
        let store = MemoryOwnedItemStore()
        store.table = table
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([remoteTombstone(tag: ruleTag("b"), version: 40,
                                                      entityId: "srv-b")], marker: "7")]
        access.beforeLandingTransaction = { }
        let engine = try makeRuleEngine(access, store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertEqual(row(access, "a")?.askBeforeRouting, true)
        XCTAssertNil(row(access, "b"))
        let counters = await counters(engine)
        XCTAssertEqual(counters?.transferred, 1)
        let cursor = await engine.ownedTableForTesting("urlrules").cursors["b"]
        XCTAssertEqual(cursor?.pendingTombstone, false)
        XCTAssertNotNil(cursor?.deletedAtMs)
    }

    // MARK: - CASE M-12(ii) (yield followed by round-end 3b republication)

    /// No partner takes (ii): retain the row, clear both baselines and set/retain deletedAtMs. Round-end 3b
    /// republishes using the tombstone version. Clearing deletedAtMs prematurely prevents 3b; kind-local soft
    /// deletion without a delete step would emit an unnecessary tombstone.
    func testM12_theYieldBranchRepublishesTheRuleAtTheEndOfTheRound() async throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        seedSettled("b", id: "i-b", ask: true, accountStamp: 30,
                    rowContentUpdatedDate: stampDate(30), pendingLocalEdit: true,
                    rows: &rows, table: &table)

        let access = FakeURLRuleAccess(rows: rows)
        let store = MemoryOwnedItemStore()
        store.table = table
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([remoteTombstone(tag: ruleTag("b"), version: 40,
                                                      entityId: "srv-b")], marker: "7")]
        // Seed the account tombstone entity so round-end 3b updates it and receives applied.
        client.seed(tagHash: ruleHash("b"), ciphertext: Data(), version: 40, entityId: "srv-b",
                    deleted: true)
        let engine = try makeRuleEngine(access, store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        // The row retains syncId with nil deletedDate; plan emits no delete step.
        let x = try XCTUnwrap(row(access, "b"))
        XCTAssertNil(x.deletedDate)
        XCTAssertEqual(x.askBeforeRouting, true, "The unpublished edit remains unchanged")
        XCTAssertTrue(access.lastAppliedOps.isEmpty, "No landing operations")
        XCTAssertTrue(access.hardDeleteCalls.isEmpty)
        // Round-end 3b uses the tombstone's base_version.
        let commits = ruleCommits(client)
        XCTAssertEqual(commits.count, 1, "One 3b republication")
        XCTAssertEqual(commits.first?.baseVersion, 40)
        XCTAssertEqual(commits.first?.deleted, false)
        let counters = await counters(engine)
        XCTAssertEqual(counters?.yieldNoPartner, 1, "Cause: empty pointer and no fallback match")
        XCTAssertEqual(counters?.transferred, 0)
        XCTAssertEqual(counters?.tombstones, 1, "Counts the arrival, not a local publication")
        // Applied resurrection under §4.2(3b) clears deletedAtMs and restores both baselines.
        XCTAssertEqual(counters?.resurrected, 1)
        let cursor = await engine.ownedTableForTesting("urlrules").cursors["b"]
        XCTAssertNil(cursor?.deletedAtMs, "Only applied clears it (RR5-3)")
        XCTAssertNotNil(cursor?.reconciled)
        XCTAssertEqual(cursor?.reconciled, cursor?.server, "R-exec-7: write both baselines")
        XCTAssertEqual(cursor?.pendingDelete, false)
        XCTAssertEqual(cursor?.pendingTombstone, false)
        // pendingLocalEdit clearing belongs to 8b-4 clearing rule (b), outside this task.
        XCTAssertTrue(try XCTUnwrap(row(access, "b")).pendingLocalEdit)
    }


    // MARK: - 8b-3 fix round 1: engine guard wiring and two failed 3b readmission paths

    /// Actual outbound rule tombstone commits: an incorrect guard is observable as an extra entry here.
    private func ruleTombstoneCommits(_ client: FakePhiSyncClient) -> [FakePhiSyncClient.CommitCall] {
        ruleCommits(client).filter(\.deleted)
    }

    /// Rules-only engine with case-owned Space access/store. 3b readmission cause two modifies Space cursors;
    /// cause three modifies currentSpaces, beyond makeRuleEngine's fixture interface.
    private func makeYieldEngine(_ access: FakeURLRuleAccess, _ store: MemoryOwnedItemStore,
                                 client: FakePhiSyncClient,
                                 spaceAccess: FakePhiSpaceAccess,
                                 spaceStore: MemorySpaceStore) -> PhiSyncEngine {
        PhiSyncEngine(domainKeys: StubDomainKeys(key: key), client: client,
                      defaults: defaults, deviceKeyId: "devA", settings: [],
                      spaceAccess: spaceAccess, spaceStore: spaceStore,
                      markerStore: markerStore(marker: "0"),
                      ownedKinds: [.urlRules(access: access, store: store)],
                      now: { Self.now })
    }

    /// Cursor after (ii): nil baselines, retained deletedAtMs and three cleared pending flags, as written by
    /// applyOwnedKind's yielding bookkeeping. This is the 3b recheck domain.
    private func yieldedCursor(entityId: String = "srv-b", version: Int64 = 40,
                               owner: String = "su-1") -> PhiOwnedItemCursor {
        var cursor = PhiOwnedItemCursor()
        cursor.entityId = entityId
        cursor.version = version
        cursor.reconciled = nil
        cursor.server = nil
        cursor.ownerUuid = owner
        cursor.deletedAtMs = Self.now - 1_000
        return cursor
    }

    /// β parking fixture: X is soft-deleted, pendingDelete and points to live but nonstill W with an
    /// unpublished edit. Row values equal their respective baselines, isolating the guard in zero-commit
    /// assertions.
    private func seedBetaPark(rows: inout [PhiLocalURLRule], table: inout PhiOwnedItemTable,
                              decidedAtMs: Int64 = 700) {
        seedSettled("a", id: "i-a", accountStamp: 100, pendingLocalEdit: true,
                    rows: &rows, table: &table)
        let payload = urlRulePayload(uuid: "b", host: "github.com", rank: "W", contentStamp: 100,
                                     targetStamp: 100, rankStamp: 100)
        var cursor = publishedRuleCursor(payload, entityId: "srv-b", version: 1)
        cursor.pendingDelete = true
        cursor.deleteDecidedAtMs = decidedAtMs
        table.cursors["b"] = cursor
        rows.append(.fixture(id: "i-b", syncId: "b", spaceId: "space-a", host: "github.com",
                             sortOrder: 1, deletedDate: Date(timeIntervalSince1970: 5),
                             mergePartnerSyncId: "a"))
    }

    // MARK: - CASE M-22 engine / 8b-3.3 full round (R-M3-4a-84 guard wiring)

    /// Drive the full pullOnce publication sequence: plan → land → diff → slice → batch. The engine computes
    /// partnerNotAtRest intersected with nonnil pendingApply inside tombstones; do not inject the guard set
    /// manually. An empty guard would let diff clear pendingApply and enqueue X's accepted tombstone,
    /// hard-delete the reconsidered row, then create it again next round, ending with two rules.
    func testM22_theEngineComputedGuardSuppressesTheTombstoneThroughAFullRound() async throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        seedBetaPark(rows: &rows, table: &table)

        let access = FakeURLRuleAccess(rows: rows)
        let store = MemoryOwnedItemStore()
        store.table = table
        let client = FakePhiSyncClient()
        // B's tombstone conflicted, so this page brings X's live entity back.
        client.pagesByMarker = [page([ruleEntity(remote(uuid: "b", rank: "W"), version: 40)],
                                     marker: "7")]
        let engine = try makeRuleEngine(access, store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        // ① β actually parks: no landing, with payload and pending owner retained in cursor.
        let cursor = await engine.ownedTableForTesting("urlrules").cursors["b"]
        XCTAssertNotNil(cursor?.pendingApply, "Park the inbound entity without diff clearing it")
        XCTAssertEqual(cursor?.pendingOwnerUuid, "su-1")
        XCTAssertEqual(cursor?.pendingTombstone, false, "That flag belongs to α")
        // ② The guard performs no diff bookkeeping; all four fields match entry state (full-round 8b-3.3).
        XCTAssertEqual(cursor?.pendingDelete, true)
        XCTAssertEqual(cursor?.deleteDecidedAtMs, 700, "The comparison threshold does not keep moving forward")
        XCTAssertEqual(cursor?.reconciled, table.cursors["b"]?.reconciled, "No baseline bytes were written")
        // ③ client.commit contains no X tombstone.
        XCTAssertTrue(ruleTombstoneCommits(client).isEmpty, "An always-empty guard must fail here")
        let counters = await counters(engine)
        XCTAssertEqual(counters?.tombstones, 0)
        // ④ X's row remains unchanged byte for byte.
        let x = try XCTUnwrap(row(access, "b"))
        XCTAssertEqual(x.deletedDate, Date(timeIntervalSince1970: 5), "Still soft-deleted")
        XCTAssertEqual(x.mergePartnerSyncId, "a")
        XCTAssertEqual(x.spaceId, "space-a")
        XCTAssertTrue(access.hardDeleteCalls.isEmpty)
    }

    /// Control two: owner-resolution parking is outside the guard. X waits for an unmapped Space and is not in
    /// partnerNotAtRest; existing user deletion must still emit its tombstone. Guarding on pendingApply alone
    /// would indefinitely block legitimate deletion during §5.5 step-4 owner parking.
    func testM22_anOwnerShapedParkIsNotCoveredByTheGuard() async throws {
        let payload = urlRulePayload(uuid: "b", host: "github.com", contentStamp: 100)
        var table = PhiOwnedItemTable()
        var cursor = publishedRuleCursor(payload, entityId: "srv-b", version: 1)
        cursor.pendingDelete = true
        cursor.deleteDecidedAtMs = 700
        // Owner parking waits for an unmapped Space, independent of partner stillness.
        cursor.pendingApply = baselineBytes(urlRulePayload(uuid: "b", targetSpaceUuid: "su-9"))
        cursor.pendingOwnerUuid = "su-9"
        table.cursors["b"] = cursor
        // No second row means partnerNotAtRest is always empty for X.
        let rows: [PhiLocalURLRule] = [
            .fixture(id: "i-b", syncId: "b", spaceId: "space-a", host: "github.com",
                     deletedDate: Date(timeIntervalSince1970: 5)),
        ]
        let access = FakeURLRuleAccess(rows: rows)
        XCTAssertTrue(access.partnerNotAtRest(table: table, rows: rows, resolve: resolve,
                                              tombstonesThisPage: []).isEmpty,
                      "No partner row means exclusion from this guard")

        let store = MemoryOwnedItemStore()
        store.table = table
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([], marker: "7")]
        // Seed the actual server row so its update-style tombstone is accepted.
        client.seed(tagHash: ruleHash("b"), ciphertext: Data(), version: 1, entityId: "srv-b")
        let engine = try makeRuleEngine(access, store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertEqual(ruleTombstoneCommits(client).count, 1, "Publish the legitimate user deletion normally")
        XCTAssertEqual(ruleTombstoneCommits(client).first?.baseVersion, 1)
        let counters = await counters(engine)
        XCTAssertEqual(counters?.tombstones, 1)
    }

    /// Control three: localOwnedChange on persisted β parking must also produce no tombstone, retain
    /// soft-deleted X and preserve pendingDelete/pendingApply. Computing the guard inside tombstones covers
    /// every publication round. Also verify the guard reads all rows including soft deletion; allURLRules
    /// would structurally omit β's X and empty the guard.
    func testM22_theGuardAlsoHoldsOnAPushOnlyRound() async throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        seedBetaPark(rows: &rows, table: &table)
        // Parking already persisted from the previous β round; this operation pulls no pages.
        table.cursors["b"]?.pendingApply = baselineBytes(
            urlRulePayload(uuid: "b", host: "github.com", rank: "W", contentStamp: 100))
        table.cursors["b"]?.pendingOwnerUuid = "su-1"
        let parkedPayload = table.cursors["b"]?.pendingApply

        let access = FakeURLRuleAccess(rows: rows)
        // Domain check: including soft-deleted rows activates the guard; live-only rows leave it empty.
        XCTAssertTrue(access.partnerNotAtRest(table: table, rows: rows, resolve: resolve,
                                              tombstonesThisPage: []).contains("b"))
        XCTAssertTrue(access.partnerNotAtRest(table: table,
                                              rows: rows.filter { $0.deletedDate == nil },
                                              resolve: resolve,
                                              tombstonesThisPage: []).isEmpty,
                      "Using allURLRules for rows must fail")

        let store = MemoryOwnedItemStore()
        store.table = table
        let client = FakePhiSyncClient()
        let engine = try makeRuleEngine(access, store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.handleLocalOwnedChange(label: "urlrules")

        XCTAssertTrue(ruleTombstoneCommits(client).isEmpty, "The push-only round also publishes nothing")
        let cursor = await engine.ownedTableForTesting("urlrules").cursors["b"]
        XCTAssertEqual(cursor?.pendingApply, parkedPayload, "pendingApply is unchanged byte for byte")
        XCTAssertEqual(cursor?.pendingDelete, true)
        XCTAssertEqual(cursor?.deleteDecidedAtMs, 700)
        XCTAssertEqual(row(access, "b")?.deletedDate, Date(timeIntervalSince1970: 5))
    }

    // MARK: - CASE 8b-3.4 (3b recheck with unusable server metadata performs no writes)

    /// An identity after (ii) has a live row, deletedAtMs, nil reconciled, unusable entityId/version and a
    /// hidden target Space. Missing metadata must not enter revocation and hard-delete a live local row
    /// without an executable server tombstone. Conversely, pendingDelete false cannot mean no executable
    /// tombstone (RR13-6), because (ii) already cleared all pending flags.
    func test8b34_aYieldWithNoUsableServerTripleWritesNothing() async throws {
        for (label, entityId, version) in [("Empty entityId", "", Int64(40)),
                                           ("version == 0", "srv-b", Int64(0))] {
            let rows: [PhiLocalURLRule] = [
                .fixture(id: "i-b", syncId: "b", spaceId: "space-a", host: "github.com",
                         contentUpdatedDate: stampDate(30), pendingLocalEdit: true),
            ]
            var table = PhiOwnedItemTable()
            table.cursors["b"] = yieldedCursor(entityId: entityId, version: version)

            let access = FakeURLRuleAccess(rows: rows)
            let store = MemoryOwnedItemStore()
            store.table = table
            let client = FakePhiSyncClient()
            client.pagesByMarker = [page([], marker: "7")]
            let spaceStore = try drainedSpaceStore()
            // Cause two also holds because the target is purged; check cause one first to avoid wrongful hard
            // deletion.
            spaceStore.table.cursors["su-1"] = purgedSpaceCursor()
            let engine = makeYieldEngine(access, store, client: client,
                                         spaceAccess: makeSpaceAccess(), spaceStore: spaceStore)
            await engine.setSpaceSyncEnabled(true)
            await engine.pullOnce()

            // Write no bytes.
            let survivor = try XCTUnwrap(row(access, "b"), label)
            XCTAssertNil(survivor.deletedDate, "\(label): the row remains")
            XCTAssertTrue(survivor.pendingLocalEdit, "\(label): pendingLocalEdit is unchanged")
            XCTAssertEqual(survivor.contentUpdatedDate, stampDate(30), label)
            let cursor = await engine.ownedTableForTesting("urlrules").cursors["b"]
            XCTAssertEqual(cursor?.deletedAtMs, Self.now - 1_000, "\(label): deletedAtMs remains")
            XCTAssertNil(cursor?.reconciled, label)
            XCTAssertNil(cursor?.server, label)
            XCTAssertTrue(ruleCommits(client).isEmpty, "\(label): publish neither tombstones nor 3b")
            XCTAssertFalse(access.lastAppliedOps.contains { if case .delete = $0 { return true }
                                                            else { return false } },
                           "\(label): the revocation branch did not run")
            XCTAssertTrue(access.hardDeleteCalls.isEmpty, label)
        }
    }

    // MARK: - CASE M-12 variants (2)/(4) (cross-round recheck revokes yielding and hard-deletes)

    /// Round one passes readmission but 3b and its scoped retry conflict, preserving yielded state. Only next
    /// round does the target become hidden; recheck must still revoke yielding and hard-delete. Variant (4)
    /// has pendingLocalEdit false because unpublished alone caused yielding, and both baselines are now nil.
    /// Requiring pendingLocalEdit or unpublished again would permanently exclude it. Binding recheck only to
    /// this round's yieldedTombstones also misses round two.
    func testM12_variant2_theRecheckRevokesTheYieldOnALaterRound() async throws {
        let rows: [PhiLocalURLRule] = [
            .fixture(id: "i-b", syncId: "b", spaceId: "space-a", host: "github.com",
                     contentUpdatedDate: stampDate(30), pendingLocalEdit: false),
        ]
        var table = PhiOwnedItemTable()
        table.cursors["b"] = yieldedCursor()

        let access = FakeURLRuleAccess(rows: rows)
        let store = MemoryOwnedItemStore()
        store.table = table
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([], marker: "7"), page([], marker: "8")]
        // Both first-round 3b attempts conflict. forcedConflicts runs before server-row lookup, so no stored
        // seed is needed.
        client.forcedConflicts = 2
        let spaceStore = try drainedSpaceStore()
        let engine = makeYieldEngine(access, store, client: client,
                                     spaceAccess: makeSpaceAccess(), spaceStore: spaceStore)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        // Round one: readmission passes and 3b actually publishes with the tombstone base_version, but is not
        // accepted.
        XCTAssertEqual(ruleCommits(client).count, 2, "One 3b publication and one scoped retry")
        XCTAssertEqual(ruleCommits(client).first?.baseVersion, 40)
        XCTAssertEqual(ruleCommits(client).first?.deleted, false)
        XCTAssertNotNil(row(access, "b"), "Yielded state remains unchanged")
        var cursor = await engine.ownedTableForTesting("urlrules").cursors["b"]
        XCTAssertEqual(cursor?.deletedAtMs, Self.now - 1_000, "Conflict writes no baselines")
        XCTAssertNil(cursor?.reconciled)

        // Round two: hidden target triggers recheck/revocation despite an empty current yieldedTombstones set.
        spaceStore.table.cursors["su-1"] = purgedSpaceCursor()
        await engine.pullOnce()

        XCTAssertNil(row(access, "b"), "Revoke yielding and hard-delete the row")
        XCTAssertTrue(access.lastAppliedOps.contains { if case .delete(let syncId) = $0 {
            return syncId == "b" } else { return false } }, "Uses registration.land([.delete])")
        cursor = await engine.ownedTableForTesting("urlrules").cursors["b"]
        XCTAssertEqual(cursor?.deletedAtMs, Self.now, "Preserve the bookkeeping specified at :3195-3201")
        XCTAssertEqual(cursor?.pendingDelete, false)
        XCTAssertNil(cursor?.reconciled)
        XCTAssertNil(cursor?.server)
        XCTAssertEqual(ruleCommits(client).count, 2, "Revocation publishes nothing because the identity left the slice")
    }

    // MARK: - CASE M-12 variant (3) (unresolved differs from hidden; no writes)

    /// A target temporarily absent from currentSpaces with no hidden/purged cursor must not cause hard
    /// deletion or tombstones. Preserve row, pendingLocalEdit and deletedAtMs; skip 3b until mapping resolves,
    /// then publish normally with resurrected 1. Blanket hard deletion would erase a still-used rule and its
    /// unpublished edit.
    func testM12_variant3_anUnresolvableOwnerWritesNothingAndRepublishesLater() async throws {
        let rows: [PhiLocalURLRule] = [
            .fixture(id: "i-b", syncId: "b", spaceId: "space-a", host: "github.com",
                     contentUpdatedDate: stampDate(30), pendingLocalEdit: true),
        ]
        var table = PhiOwnedItemTable()
        table.cursors["b"] = yieldedCursor()

        let access = FakeURLRuleAccess(rows: rows)
        let store = MemoryOwnedItemStore()
        store.table = table
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([], marker: "7"), page([], marker: "8")]
        // Seed the actual account tombstone so 3b can be accepted.
        client.seed(tagHash: ruleHash("b"), ciphertext: Data(), version: 40, entityId: "srv-b",
                    deleted: true)
        let spaceAccess = makeSpaceAccess()
        let restored = spaceAccess.spaces
        // Space list is not loaded: mapping remains, but currentSpaces excludes the target. Ineligible
        // ownership makes the row inert and absent from snapshot; readmission fails, while absent Space cursor
        // means cause two is false.
        spaceAccess.spaces = []
        let spaceStore = try drainedSpaceStore()
        let engine = makeYieldEngine(access, store, client: client,
                                     spaceAccess: spaceAccess, spaceStore: spaceStore)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let survivor = try XCTUnwrap(row(access, "b"), "No hard deletion")
        XCTAssertTrue(survivor.pendingLocalEdit, "pendingLocalEdit is unchanged")
        XCTAssertEqual(survivor.contentUpdatedDate, stampDate(30))
        var cursor = await engine.ownedTableForTesting("urlrules").cursors["b"]
        XCTAssertEqual(cursor?.deletedAtMs, Self.now - 1_000, "Retain deletedAtMs")
        XCTAssertTrue(ruleCommits(client).isEmpty, "That round also skips 3b")
        XCTAssertTrue(access.hardDeleteCalls.isEmpty)

        // After mapping becomes available, readmission permits 3b, applied and resurrection.
        spaceAccess.spaces = restored
        await engine.pullOnce()

        XCTAssertEqual(ruleCommits(client).count, 1, "3b published")
        XCTAssertEqual(ruleCommits(client).first?.baseVersion, 40)
        XCTAssertEqual(ruleCommits(client).first?.deleted, false)
        cursor = await engine.ownedTableForTesting("urlrules").cursors["b"]
        XCTAssertNil(cursor?.deletedAtMs, "§4.2(3b) resurrection clears deletedAtMs")
        XCTAssertNotNil(cursor?.reconciled)
        let counters = await counters(engine)
        XCTAssertEqual(counters?.resurrected, 1)
        XCTAssertNotNil(row(access, "b"), "The row remained throughout")
    }


    // MARK: - 8b-4 (§8.4.5's two pending-flag clearing paths): fixtures

    typealias Gate = PhiSyncEngineTests.Gate

    /// Client returns only empty pages. stored models account state for commit base-version checks and never
    /// feeds undecodable entities into getUpdates. Seed each entity to match seedSettled's srv-<id>/version 1
    /// cursor.
    private func publishingClient(seeding identities: [String] = [],
                                  version: Int64 = 1) -> FakePhiSyncClient {
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([], marker: "1")]
        for identity in identities {
            client.seed(tagHash: ruleHash(identity), ciphertext: Data(), version: version,
                        entityId: "srv-\(identity)")
        }
        return client
    }

    /// Ordered clearing-(a) primitive calls. One call is one row write clearing flag and pointer together.
    private func clearCalls(_ access: FakeURLRuleAccess) -> [String] {
        access.calls.compactMap {
            if case .clearPendingLocalEdit(let syncId) = $0 { return syncId } else { return nil }
        }
    }

    /// Entry counts passed to clearing-(b) primitives. Empty work skips the call, leaving this list empty.
    private func clearIfUnchangedCalls(_ access: FakeURLRuleAccess) -> [Int] {
        access.calls.compactMap {
            if case .clearPendingLocalEditIfUnchanged(let count) = $0 { return count } else { return nil }
        }
    }

    private func flag(_ access: FakeURLRuleAccess, _ syncId: String) -> Bool? {
        row(access, syncId)?.pendingLocalEdit
    }

    // MARK: - CASE M-7 (applied clearing; §8.4.5(a) / §8.4.3 lifecycle row 2)

    /// Published still R has an M2 pointer. A user ask edit sets pending; accepted publication clears
    /// pendingLocalEdit and mergePartnerSyncId in one primitive/row write. Three later rounds have no commits
    /// or clearing. Separate pointer clearing would add an emission/routing refresh (§6.6) and a crash window
    /// with cleared flag but stale pointer.
    func testM7_anAppliedLivePublishClearsTheFlagAndThePartnerInOneRowWrite() async throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        seedSettled("R", id: "i-R", accountStamp: 100, rowContentUpdatedDate: stampDate(100),
                    mergePartnerSyncId: "w", rows: &rows, table: &table)
        let access = FakeURLRuleAccess(rows: rows)
        let store = MemoryOwnedItemStore()
        store.table = table
        let client = publishingClient(seeding: ["R"])
        let engine = try makeRuleEngine(access, store, client: client)
        await engine.setSpaceSyncEnabled(true)

        // A real user ask edit through the fake's user-write interface sets pending; do not assign the row
        // manually.
        access.applyEditorSave(syncId: "R", ask: true, at: stampDate(200))
        XCTAssertEqual(flag(access, "R"), true)

        await engine.pullOnce()

        XCTAssertEqual(ruleCommits(client).count, 1, "E1 published")
        XCTAssertEqual(ruleCommits(client).first?.deleted, false)
        XCTAssertEqual(clearCalls(access), ["R"], "One primitive call equals one row write")
        XCTAssertEqual(flag(access, "R"), false, "Applied triggers clearing (a)")
        XCTAssertNil(row(access, "R")?.mergePartnerSyncId, "Pointer and flag share one row write")
        let cursor = await engine.ownedTableForTesting("urlrules").cursors["R"]
        XCTAssertNotNil(cursor?.reconciled)
        XCTAssertEqual(cursor?.reconciled, cursor?.server, "R-exec-7: both baselines match the published payload")

        // Three further rounds: no commits or row writes.
        for _ in 0..<3 { await engine.pullOnce() }
        XCTAssertEqual(ruleCommits(client).count, 1, "pushed == 0")
        XCTAssertEqual(clearCalls(access), ["R"], "No second clearing-(a) call")
        XCTAssertTrue(clearIfUnchangedCalls(access).isEmpty,
                      "(b) Empty filtered work skips the primitive and transaction")
    }

    // MARK: - CASE M-7b (clearing (a) E1/E2 window; R-M3-4a-79)

    /// ① Save E1 ask edit and send its snapshot. ② Save E2 path edit while commit is in flight. ③ Applied
    /// acknowledges E1: current E2 differs, so retain pending but clear pointer. ④ Next-round remote tombstone
    /// must yield and preserve E2. ⑤ Publishing E2 successfully then clears pending. Unconditional clearing at
    /// ③ loses yielding protection and permanently destroys E2 at ④.
    func testM7b_anEditInFlightKeepsTheFlagAndTheYieldProtection() async throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        seedSettled("R", id: "i-R", accountStamp: 100, rowContentUpdatedDate: stampDate(100),
                    mergePartnerSyncId: "w", rows: &rows, table: &table)
        let access = FakeURLRuleAccess(rows: rows)
        let store = MemoryOwnedItemStore()
        store.table = table
        let client = publishingClient(seeding: ["R"])
        // Round one gets empty page watermark 1; round two gets the inbound tombstone at watermark 40.
        client.pagesByMarker = [page([], marker: "1"),
                                page([remoteTombstone(tag: ruleTag("R"), version: 300,
                                                      entityId: "srv-R")], marker: "300")]
        let engine = try makeRuleEngine(access, store, client: client)
        await engine.setSpaceSyncEnabled(true)

        // ① E1。
        access.applyEditorSave(syncId: "R", ask: true, at: stampDate(200))
        // ② Save E2 while the commit is in flight.
        let arrived = Gate()
        let release = Gate()
        client.gatedCommitTagHash = ruleHash("R")
        client.arrivedInCommit = arrived
        client.commitGate = release
        let round = Task { await engine.pullOnce() }
        await arrived.wait()
        access.applyEditorSave(syncId: "R", pathPrefix: "/anthropics", at: stampDate(300))
        await release.open()
        await round.value

        // ③ Applied acknowledges E1: retain pending, clear pointer.
        XCTAssertEqual(clearCalls(access), ["R"], "(a) Ran once normally")
        XCTAssertEqual(flag(access, "R"), true, "Current row E2 differs from baseline E1, so retain pending")
        XCTAssertNil(row(access, "R")?.mergePartnerSyncId, "The pointer still clears")
        XCTAssertEqual(row(access, "R")?.pathPrefix, "/anthropics", "E2 remains unchanged in the row")

        // ④ Next-round tombstone yields instead of hard-deleting. Round-end 3b republishes E2; ⑤ applied now
        // finds row/baseline equal and clears pending.
        client.gatedCommitTagHash = nil
        client.arrivedInCommit = nil
        client.commitGate = nil
        // The account currently holds the tombstone version used by 3b as base_version.
        client.seed(tagHash: ruleHash("R"), ciphertext: Data(), version: 300, entityId: "srv-R",
                    deleted: true)
        await engine.pullOnce()
        XCTAssertTrue(access.hardDeleteCalls.isEmpty, "④ No hard deletion")
        XCTAssertEqual(row(access, "R")?.pathPrefix, "/anthropics", "④ E2's pathPrefix remains")
        XCTAssertNil(row(access, "R")?.deletedDate)
        let counters = await counters(engine)
        XCTAssertEqual(counters?.yieldNoPartner, 1, "No partner takes branch (ii)")
        XCTAssertEqual(counters?.resurrected, 1, "⑤ Round-end 3b republishes E2 and receives acceptance")
        XCTAssertEqual(flag(access, "R"), false, "⑤ Clear pending only after E2 reaches the account")

        // Three further rounds: no commits or flag clearing.
        let commitsSoFar = ruleCommits(client).count
        let clearsSoFar = clearCalls(access).count
        for _ in 0..<3 { await engine.pullOnce() }
        XCTAssertEqual(ruleCommits(client).count, commitsSoFar, "pushed == 0")
        XCTAssertEqual(clearCalls(access).count, clearsSoFar)
    }

    /// Control omits in-flight Save ②; applied at ③ clears pending normally, preserving prior behavior.
    func testM7b_withoutTheInFlightEditTheAppliedPublishClearsAtOnce() async throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        seedSettled("R", id: "i-R", accountStamp: 100, rowContentUpdatedDate: stampDate(100),
                    mergePartnerSyncId: "w", rows: &rows, table: &table)
        let access = FakeURLRuleAccess(rows: rows)
        let store = MemoryOwnedItemStore()
        store.table = table
        let client = publishingClient(seeding: ["R"])
        let engine = try makeRuleEngine(access, store, client: client)
        await engine.setSpaceSyncEnabled(true)

        access.applyEditorSave(syncId: "R", ask: true, at: stampDate(200))
        await engine.pullOnce()

        XCTAssertEqual(flag(access, "R"), false)
        XCTAssertNil(row(access, "R")?.mergePartnerSyncId)
    }

    // MARK: - CASE M-7c (clearing (b) preserves mergePartnerSyncId)

    /// A normalized-away edit leaves pending true, pointer w, equal server/reconciled and snapshot equal to
    /// reconciled. Clearing (b) resets pending but retains w. §8.4.3 clears pointers only after live applied
    /// publication or for a still singleton; clearing here would change next-round yielding from transfer to
    /// partnerless branch (ii).
    func testM7c_theSelfHealClearsTheFlagButNeverThePartnerPointer() async throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        seedSettled("R", id: "i-R", accountStamp: 100, pendingLocalEdit: true,
                    mergePartnerSyncId: "w", rows: &rows, table: &table)
        let access = FakeURLRuleAccess(rows: rows)
        let store = MemoryOwnedItemStore()
        store.table = table
        let client = publishingClient(seeding: ["R"])
        let engine = try makeRuleEngine(access, store, client: client)
        await engine.setSpaceSyncEnabled(true)

        await engine.pullOnce()

        XCTAssertEqual(clearIfUnchangedCalls(access), [1], "(b) One transaction for one identity")
        XCTAssertTrue(clearCalls(access).isEmpty, "This round has no applied outcomes")
        XCTAssertEqual(flag(access, "R"), false, "(b) Cleared the pending flag")
        XCTAssertEqual(row(access, "R")?.mergePartnerSyncId, "w", "Leave the pointer unchanged byte for byte")
        XCTAssertTrue(ruleCommits(client).isEmpty, "pushed == 0")
    }

    // MARK: - CASE M-7d (3b resurrection applied still compares current row; ruling 13)

    /// Main case: X after yielding (ii) has deletedAtMs, nil baselines/pointer. Next-round 3b applied clears
    /// deletedAtMs, counts resurrected 1 and clears pendingLocalEdit.
    func testM7d_theResurrectingRepublishAlsoClearsTheFlag() async throws {
        let access = FakeURLRuleAccess(rows: [
            .fixture(id: "i-X", syncId: "X", spaceId: "space-a", host: "github.com",
                     contentUpdatedDate: stampDate(200), pendingLocalEdit: true),
        ])
        let store = MemoryOwnedItemStore()
        store.table.cursors["X"] = yieldedCursor(entityId: "srv-X", version: 40)
        let client = publishingClient(seeding: ["X"], version: 40)
        let engine = try makeRuleEngine(access, store, client: client)
        await engine.setSpaceSyncEnabled(true)

        await engine.pullOnce()

        XCTAssertEqual(ruleCommits(client).count, 1, "3b republishes")
        XCTAssertEqual(ruleCommits(client).first?.baseVersion, 40)
        let cursor = await engine.ownedTableForTesting("urlrules").cursors["X"]
        XCTAssertNil(cursor?.deletedAtMs, "Applied completes resurrection")
        let counters = await counters(engine)
        XCTAssertEqual(counters?.resurrected, 1)
        XCTAssertEqual(flag(access, "X"), false, "That applied outcome means the user edit finally reached the account")
        XCTAssertNil(row(access, "X")?.mergePartnerSyncId)
    }

    /// Variant (b): another Save during 3b flight keeps pending true because projections differ, while
    /// deletedAtMs still clears and resurrected remains 1. No unconditional 3b clearing exception; flag
    /// comparison and resurrection bookkeeping are independent.
    func testM7d_anEditInFlightDuringTheResurrectingRepublishKeepsTheFlag() async throws {
        let access = FakeURLRuleAccess(rows: [
            .fixture(id: "i-X", syncId: "X", spaceId: "space-a", host: "github.com",
                     contentUpdatedDate: stampDate(200), pendingLocalEdit: true),
        ])
        let store = MemoryOwnedItemStore()
        store.table.cursors["X"] = yieldedCursor(entityId: "srv-X", version: 40)
        let client = publishingClient(seeding: ["X"], version: 40)
        let arrived = Gate()
        let release = Gate()
        client.gatedCommitTagHash = ruleHash("X")
        client.arrivedInCommit = arrived
        client.commitGate = release
        let engine = try makeRuleEngine(access, store, client: client)
        await engine.setSpaceSyncEnabled(true)

        let round = Task { await engine.pullOnce() }
        await arrived.wait()
        access.applyEditorSave(syncId: "X", host: "changed.example", at: stampDate(300))
        await release.open()
        await round.value

        let cursor = await engine.ownedTableForTesting("urlrules").cursors["X"]
        XCTAssertNil(cursor?.deletedAtMs, "deletedAtMs still clears")
        let counters = await counters(engine)
        XCTAssertEqual(counters?.resurrected, 1)
        XCTAssertEqual(flag(access, "X"), true, "Unequal comparison keeps pending true")
        XCTAssertEqual(row(access, "X")?.host, "changed.example")
    }

    // MARK: - CASE M-7e (clearing (b) E2 between evaluation and write; R-M3-4a-91)

    /// Entry models E1 applied last round but clearing (a)'s row write failed: pending true, equal E1
    /// baselines and pointer w. Publication selects R for (b), passing publishBaseline E1 to the primitive.
    /// Between evaluation and write, user Save E2 makes the transaction's recomputed projection differ, so
    /// retain both pending and pointer.
    /// An identity-only primitive guarding merely pendingLocalEdit would clear E2's protection, allowing
    /// next-round tombstone to hard-delete its unpublished edit. Inject at clearPendingLocalEditIfUnchanged,
    /// the layer that sees entries.
    func testM7e_aSaveBetweenTheDecisionAndTheWriteKeepsTheFlag() async throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        // E1 ask true@200 is already in account and row baselines, but pending remains set.
        seedSettled("R", id: "i-R", ask: true, accountStamp: 200,
                    rowContentUpdatedDate: stampDate(200), pendingLocalEdit: true,
                    mergePartnerSyncId: "w", rows: &rows, table: &table)
        let access = FakeURLRuleAccess(rows: rows)
        let store = MemoryOwnedItemStore()
        store.table = table
        let client = publishingClient(seeding: ["R"])
        client.pagesByMarker = [page([], marker: "1"),
                                page([remoteTombstone(tag: ruleTag("R"), version: 40,
                                                      entityId: "srv-R")], marker: "40")]
        let engine = try makeRuleEngine(access, store, client: client)
        await engine.setSpaceSyncEnabled(true)

        // Perform real local Save E2 between evaluation and write.
        access.beforeClearPendingLocalEditIfUnchanged = { [weak access] in
            access?.applyEditorSave(syncId: "R", host: "e2.example", at: Date(timeIntervalSince1970: 3))
        }

        await engine.pullOnce()

        XCTAssertEqual(clearIfUnchangedCalls(access), [1], "(b) Actually included R in entries")
        XCTAssertEqual(flag(access, "R"), true, "Recomputed E2 projection prevents clearing")
        XCTAssertEqual(row(access, "R")?.mergePartnerSyncId, "w", "Leave the pointer unchanged byte for byte")
        XCTAssertEqual(row(access, "R")?.host, "e2.example")

        // Next-round remote tombstone yields, preserving E2. Round-end 3b publishes it; applied clearing (a)
        // finds equality and clears flag/pointer together.
        access.beforeClearPendingLocalEditIfUnchanged = nil
        client.seed(tagHash: ruleHash("R"), ciphertext: Data(), version: 40, entityId: "srv-R",
                    deleted: true)
        await engine.pullOnce()
        XCTAssertTrue(access.hardDeleteCalls.isEmpty, "Yield without hard deletion")
        XCTAssertEqual(row(access, "R")?.host, "e2.example", "E2 survives")
        XCTAssertNil(row(access, "R")?.deletedDate)
        XCTAssertEqual(flag(access, "R"), false, "Clear pending only after E2 reaches the account")
        XCTAssertNil(row(access, "R")?.mergePartnerSyncId)
    }

    /// No-hook control clears pending normally through (b) while retaining w. The new predicate only restricts
    /// clearing in the race window.
    func testM7e_withoutTheInjectedSaveTheSelfHealClearsAsBefore() async throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        seedSettled("R", id: "i-R", ask: true, accountStamp: 200,
                    rowContentUpdatedDate: stampDate(200), pendingLocalEdit: true,
                    mergePartnerSyncId: "w", rows: &rows, table: &table)
        let access = FakeURLRuleAccess(rows: rows)
        let store = MemoryOwnedItemStore()
        store.table = table
        let engine = try makeRuleEngine(access, store, client: publishingClient(seeding: ["R"]))
        await engine.setSpaceSyncEnabled(true)

        await engine.pullOnce()

        XCTAssertEqual(flag(access, "R"), false)
        XCTAssertEqual(row(access, "R")?.mergePartnerSyncId, "w")
    }

    // MARK: - CASE M-19 (pendingLocalEdit recovery through clearing (b); R-M3-4a-68 / RR8-8 / RR9-2)

    /// (a)/(b)/(c): normalization, ask edit reverted, and transfer losing both units each leave values
    /// identical to baseline. One round clears all pending flags with pushed 0; later inbound tombstones
    /// hard-delete normally with resurrected 0. Applied-only clearing would leave these rows permanently
    /// nonstill and yielding to every deletion.
    func testM19_theSelfHealClearsAnAbsorbedEditAndTheTombstoneThenHardDeletes() async throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        for (offset, syncId) in ["a", "b", "c"].enumerated() {
            seedSettled(syncId, id: "i-\(syncId)", host: "\(syncId).example", sortOrder: offset,
                        accountStamp: 100, pendingLocalEdit: true, rows: &rows, table: &table)
        }
        let access = FakeURLRuleAccess(rows: rows)
        let store = MemoryOwnedItemStore()
        store.table = table
        let client = publishingClient(seeding: ["a", "b", "c"])
        client.pagesByMarker = [
            page([], marker: "1"),
            page(["a", "b", "c"].map { remoteTombstone(tag: ruleTag($0), version: 40,
                                                       entityId: "srv-\($0)") }, marker: "40"),
        ]
        let engine = try makeRuleEngine(access, store, client: client)
        await engine.setSpaceSyncEnabled(true)

        await engine.pullOnce()

        XCTAssertEqual(clearIfUnchangedCalls(access), [3], "One transaction for three identities")
        for syncId in ["a", "b", "c"] {
            XCTAssertEqual(flag(access, syncId), false, syncId)
        }
        XCTAssertTrue(ruleCommits(client).isEmpty, "pushed == 0")

        // Inbound tombstone hard-deletes normally because both disjuncts of yielding conjunction (4) are
        // false.
        await engine.pullOnce()
        XCTAssertEqual(access.hardDeleteCalls.count, 0, "Hard deletion uses a landing operation, not exit 1")
        for syncId in ["a", "b", "c"] {
            XCTAssertNil(row(access, syncId), "\(syncId) was hard-deleted")
        }
        let counters = await counters(engine)
        XCTAssertEqual(counters?.resurrected, 0, "No entities yielded")
        XCTAssertEqual(counters?.yieldNoPartner, 0)
    }

    /// (d) Inject failNextClearPendingLocalEdit for clearing (a): the round does not crash or roll back other
    /// work, including cursor baseline. Next round (b) repairs the flag.
    func testM19d_aFailedClearingWriteIsHealedByTheNextRound() async throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        seedSettled("R", id: "i-R", accountStamp: 100, rowContentUpdatedDate: stampDate(100),
                    rows: &rows, table: &table)
        let access = FakeURLRuleAccess(rows: rows)
        let store = MemoryOwnedItemStore()
        store.table = table
        let client = publishingClient(seeding: ["R"])
        let engine = try makeRuleEngine(access, store, client: client)
        await engine.setSpaceSyncEnabled(true)

        access.applyEditorSave(syncId: "R", ask: true, at: stampDate(200))
        access.failNextClearPendingLocalEdit = true

        await engine.pullOnce()

        XCTAssertEqual(ruleCommits(client).count, 1, "The commit publishes and is accepted normally")
        XCTAssertEqual(clearCalls(access), ["R"], "(a) Was called, but its write threw")
        XCTAssertEqual(flag(access, "R"), true, "The pending flag remains")
        var cursor = await engine.ownedTableForTesting("urlrules").cursors["R"]
        XCTAssertEqual(cursor?.reconciled, cursor?.server, "Other work does not roll back; both baselines persist")

        // Next round, server == reconciled and snapshot == reconciled enable (b) recovery.
        await engine.pullOnce()
        XCTAssertEqual(clearIfUnchangedCalls(access), [1])
        XCTAssertEqual(flag(access, "R"), false, "The next round repairs it automatically")
        cursor = await engine.ownedTableForTesting("urlrules").cursors["R"]
        XCTAssertNotNil(cursor?.reconciled)
        XCTAssertEqual(ruleCommits(client).count, 1, "The recovery round has no commits")
    }

    /// (e) Local content wins landing merge: reconciled is merged but server remains remote. Their inequality
    /// excludes (b), preserving pending; an arriving tombstone yields through α's unpublished disjunct.
    /// Omitting server == reconciled would wrongly clear it.
    func testM19e_aLandedMergeKeepsTheFlagBecauseServerDiffersFromReconciled() async throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        seedSettled("R", id: "i-R", ask: true, accountStamp: 200,
                    rowContentUpdatedDate: stampDate(200), pendingLocalEdit: true,
                    rows: &rows, table: &table)
        // server contains account remote bytes; reconciled contains the different locally landed merge.
        var cursor = try XCTUnwrap(table.cursors["R"])
        cursor.server = baselineBytes(urlRulePayload(uuid: "R", host: "github.com", rank: "V",
                                                     contentStamp: 150, targetStamp: 150,
                                                     rankStamp: 150))
        table.cursors["R"] = cursor
        let access = FakeURLRuleAccess(rows: rows)
        let store = MemoryOwnedItemStore()
        store.table = table
        let client = publishingClient(seeding: ["R"])
        client.pagesByMarker = [page([], marker: "1"),
                                page([remoteTombstone(tag: ruleTag("R"), version: 40,
                                                      entityId: "srv-R")], marker: "40")]
        // Fail commit transport so no applied clearing (a) occurs. A conflict would introduce nested retry
        // pull and consume the next page prematurely.
        client.commitErrorOnce = Boom()
        let engine = try makeRuleEngine(access, store, client: client)
        await engine.setSpaceSyncEnabled(true)

        await engine.pullOnce()

        XCTAssertTrue(clearIfUnchangedCalls(access).isEmpty,
                      "server != reconciled excludes it from candidates")
        XCTAssertTrue(clearCalls(access).isEmpty, "No applied outcomes means (a) does not run")
        XCTAssertEqual(flag(access, "R"), true, "Still true")

        // The arriving tombstone yields, leaving the row alive.
        await engine.pullOnce()
        XCTAssertNotNil(row(access, "R"), "Yielding preserves the row")
        XCTAssertNil(row(access, "R")?.deletedDate)
        XCTAssertTrue(access.hardDeleteCalls.isEmpty)
    }

    /// (f) Unpublished pure reorder retains server == reconciled but assignRanks makes snapshot bytes differ.
    /// Clearing (b)'s second conjunction fails, preserving pending and yielding. urlRuleLocalProjections uses
    /// baseline rank (§5.6(1)) and would miss the reorder, clear pending, then lose the user's drag to a
    /// tombstone.
    func testM19f_anUnpublishedPureReorderKeepsTheFlag() async throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        // Baseline ranks R1 V < R2 W, but the user reordered locals to [R2,R1].
        seedSettled("R1", id: "i-1", host: "one.example", sortOrder: 1, accountStamp: 100,
                    rank: "V", pendingLocalEdit: true, rows: &rows, table: &table)
        seedSettled("R2", id: "i-2", host: "two.example", sortOrder: 0, accountStamp: 100,
                    rank: "W", rows: &rows, table: &table)
        let access = FakeURLRuleAccess(rows: rows)
        let store = MemoryOwnedItemStore()
        store.table = table
        let client = publishingClient(seeding: ["R1", "R2"])
        client.pagesByMarker = [page([], marker: "1"),
                                page([remoteTombstone(tag: ruleTag("R1"), version: 40,
                                                      entityId: "srv-R1")], marker: "40")]
        // Fail publication as in M-19(e) to isolate pending clearing.
        client.commitErrorOnce = Boom()
        let engine = try makeRuleEngine(access, store, client: client)
        await engine.setSpaceSyncEnabled(true)

        await engine.pullOnce()

        XCTAssertTrue(clearIfUnchangedCalls(access).isEmpty,
                      "Snapshot bytes differ from reconciled, excluding it from candidates")
        XCTAssertEqual(flag(access, "R1"), true, "Still true")

        // The arriving tombstone yields, leaving the row alive.
        await engine.pullOnce()
        XCTAssertNotNil(row(access, "R1"), "Yielding preserves the row")
        XCTAssertNil(row(access, "R1")?.deletedDate)
        XCTAssertTrue(access.hardDeleteCalls.isEmpty)
    }

    // MARK: - CASE M-19x (three clearing-(b) boundaries)

    /// (x1) Four pending rows excluded from snapshots: inert/no signature, pendingTombstone, pendingApply and
    /// pendingDelete. Three rounds must retain all flags. Clearing based merely on absence from
    /// candidates/republish violates RR9-2 and lets a retried tombstone hard-delete without yielding.
    func testM19x1_rowsThatNeverEnterTheSnapshotKeepTheirFlag() async throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        // ① Inert unsigned row: target Space cannot map to an account UUID.
        rows.append(.fixture(id: "i-lazy", syncId: "lazy", spaceId: "dead-space",
                             host: "lazy.example", pendingLocalEdit: true))
        // ②/③/④ each exercise one pending state.
        seedSettled("tomb", id: "i-tomb", host: "tomb.example", sortOrder: 1, accountStamp: 100,
                    pendingLocalEdit: true, rows: &rows, table: &table)
        seedSettled("apply", id: "i-apply", host: "apply.example", sortOrder: 2, accountStamp: 100,
                    pendingLocalEdit: true, rows: &rows, table: &table)
        seedSettled("del", id: "i-del", host: "del.example", sortOrder: 3, accountStamp: 100,
                    pendingLocalEdit: true, rows: &rows, table: &table)
        table.cursors["tomb"]?.pendingTombstone = true
        table.cursors["del"]?.pendingDelete = true
        if var parked = table.cursors["apply"] {
            parked.pendingApply = parked.reconciled
            table.cursors["apply"] = parked
        }

        let access = FakeURLRuleAccess(rows: rows)
        let store = MemoryOwnedItemStore()
        store.table = table
        let client = publishingClient(seeding: ["tomb", "apply", "del"])
        // The pending-delete tombstone always fails invalidMessage so its row remains observable.
        client.refuseCommitsForTagHashes = [ruleHash("del")]
        let engine = try makeRuleEngine(access, store, client: client)
        await engine.setSpaceSyncEnabled(true)

        for _ in 0..<3 { await engine.pullOnce() }

        for syncId in ["lazy", "tomb", "apply", "del"] {
            XCTAssertEqual(flag(access, syncId), true, "\(syncId): pending remains set")
        }
        XCTAssertTrue(clearIfUnchangedCalls(access).isEmpty, "All four are excluded from clearing-(b) candidates")
    }

    /// (x2) A never-accepted row with nil server must not clear even when snapshot matches reconciled; the
    /// predicate fails closed. Optional server == reconciled can incorrectly consider two nil values equal and
    /// clear flags broadly.
    func testM19x2_aCursorWithoutAServerBaselineIsNeverCleared() async throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        seedSettled("R", id: "i-R", accountStamp: 100, pendingLocalEdit: true,
                    rows: &rows, table: &table)
        var cursor = try XCTUnwrap(table.cursors["R"])
        cursor.server = nil                 // The account never accepted it
        table.cursors["R"] = cursor
        let access = FakeURLRuleAccess(rows: rows)
        let store = MemoryOwnedItemStore()
        store.table = table
        // Equal snapshot/reconciled plus usable server metadata leaves no publication work, so no commit stub
        // is needed. Clearing (a) is structurally unreachable; isolate (b)'s predicate.
        let client = publishingClient(seeding: ["R"])
        let engine = try makeRuleEngine(access, store, client: client)
        await engine.setSpaceSyncEnabled(true)

        await engine.pullOnce()

        XCTAssertTrue(clearIfUnchangedCalls(access).isEmpty, "nil server prevents clearing")
        XCTAssertTrue(clearCalls(access).isEmpty)
        XCTAssertEqual(flag(access, "R"), true)
    }

    /// (x3) N clean rules across three rounds cause zero primitive calls at either clearing site and zero
    /// commits. Rewriting every clean row each round triggers publisher/routing refresh noise (RR7-14), the
    /// same failure family as M3-3's created_at_ms storm.
    func testM19x3_aCleanTableWritesNothingAtAllAcrossThreeRounds() async throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        for offset in 0..<5 {
            seedSettled("r\(offset)", id: "i-\(offset)", host: "h\(offset).example",
                        sortOrder: offset, accountStamp: 100, rows: &rows, table: &table)
        }
        let access = FakeURLRuleAccess(rows: rows)
        let store = MemoryOwnedItemStore()
        store.table = table
        let client = publishingClient(seeding: (0..<5).map { "r\($0)" })
        let engine = try makeRuleEngine(access, store, client: client)
        await engine.setSpaceSyncEnabled(true)

        for _ in 0..<3 { await engine.pullOnce() }

        XCTAssertTrue(clearCalls(access).isEmpty, "No clearing-(a) calls")
        XCTAssertTrue(clearIfUnchangedCalls(access).isEmpty, "No clearing-(b) calls; empty work skips the primitive")
        XCTAssertTrue(ruleCommits(client).isEmpty, "No commits")
        XCTAssertEqual(refreshCalls(access), 0, "No §6.6 routing refreshes")
        XCTAssertTrue(access.rows.allSatisfy { !$0.pendingLocalEdit })
    }

    // MARK: - CASE M-20 (deletion and all engine writes preserve clear pending flags; real LocalStore)

    /// Exercise create/update/move/reorder/rekey, all three M2 writes and inbound hard deletion on real
    /// storage. Every surviving row keeps pendingLocalEdit false; editor soft deletion also leaves it false
    /// (R-M3-4a-69 / RR5-8). Engine-created pending flags would falsely claim D32(a)'s unpublished user edit
    /// and cause unwarranted yielding to later deletion.
    func testM20_noEngineWriteAndNoDeleteEverSetsThePendingLocalEditFlag() async throws {
        let store = try makeMergeStore()
        try await store.performBackgroundWriteAndWaitThrowing { context in
            // Four identified rows plus one unidentified rekey target.
            for (offset, syncId) in ["W", "L1", "L2", "M"].enumerated() {
                context.insert(SpaceURLRule(
                    id: "row-\(syncId)", spaceId: "space-a", host: "github.com",
                    pathPrefix: nil, askBeforeRouting: false, sortOrder: offset,
                    createdDate: Date(timeIntervalSince1970: 1_000), syncId: syncId,
                    contentUpdatedDate: nil, targetUpdatedDate: nil, deletedDate: nil,
                    pendingLocalEdit: false, mergePartnerSyncId: nil))
            }
            context.insert(SpaceURLRule(
                id: "row-unclaimed", spaceId: "space-a", host: "unclaimed.example",
                pathPrefix: nil, askBeforeRouting: false, sortOrder: 4,
                createdDate: Date(timeIntervalSince1970: 1_000), syncId: nil,
                contentUpdatedDate: nil, targetUpdatedDate: nil, deletedDate: nil,
                pendingLocalEdit: false, mergePartnerSyncId: nil))
        }

        let tail = URLRuleMergeTail { _ in
            URLRuleMergeResult(
                ops: [.setContentGroup(syncId: "W", host: "github.com", pathPrefix: nil,
                                       ask: true,
                                       contentUpdatedDate: Date(timeIntervalSince1970: 0.3)),
                      .softDelete(syncId: "L1", mergePartnerSyncId: "W"),
                      .setMergePartner(syncId: "M", mergePartnerSyncId: "W")],
                collapsed: 1, touchedBuckets: ["space-a"], changedRouting: true)
        }
        _ = try await store.applyURLRuleSyncBatchThrowing([
            // Exercise missing-identity create, update, move, reorder and rekey.
            .create(URLRuleLandingValues.fixture(syncId: "NEW", spaceId: "space-a",
                                                 host: "new.example", sortOrder: 5)),
            .update(URLRuleLandingValues.fixture(syncId: "M", spaceId: "space-a",
                                                 host: "m-changed.example", sortOrder: 3)),
            .move(URLRuleLandingValues.fixture(syncId: "W", spaceId: "space-b",
                                               host: "github.com", sortOrder: 0)),
            .reorder(syncId: "L2", spaceId: "space-a", sortOrder: 0),
            .rekey(localId: "row-unclaimed", to: "CLAIMED", values: nil),
            // Inbound tombstone hard-deletes.
            .delete(syncId: "L2"),
        ], mergeTail: tail)

        let after = try mergeRows(in: store)
        XCTAssertNil(after["L2"], "Inbound tombstone hard-deleted it, removing this column with the row")
        for syncId in ["W", "L1", "M", "NEW", "CLAIMED"] {
            XCTAssertEqual(after[syncId]?.pendingLocalEdit, false,
                           "\(syncId): this engine write left pending unchanged")
        }
        XCTAssertNotNil(after["L1"]?.deletedDate, "M2 soft deletion still lands")
        XCTAssertEqual(after["L1"]?.mergePartnerSyncId, "W")
        XCTAssertEqual(after["M"]?.mergePartnerSyncId, "W")

        // Editor delete set soft-deletes without setting pending (R-M3-4a-69).
        let target = try XCTUnwrap(after["M"]?.id)
        try await store.applyURLRuleEditsThrowing(upserts: [], deletedIds: [target])
        let afterDelete = try mergeRows(in: store)
        XCTAssertNotNil(afterDelete["M"]?.deletedDate)
        XCTAssertEqual(afterDelete["M"]?.pendingLocalEdit, false, "Deletion is not an edit")
    }


    // MARK: - CASE M-7b and clearing-(b) rank variants (ruling 3)

    /// Two published siblings. ① E1 edits R1 ask and sends a snapshot at sortOrder 0. ② An in-flight pure drag
    /// moves it to position 2, leaving all value fields unchanged. ③ Applied acknowledges E1, but rank-unit
    /// mismatch keeps pending true while clearing pointer. Omitting
    /// RuleProjection.sortOrder/clearingProjectionMatches' sortOrder guard would falsely clear protection and
    /// lose the drag plus row to remote deletion (ruling 3).
    func testM7b_aPureReorderInFlightKeepsTheFlagBecauseRankIsAMergeUnit() async throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        seedSettled("R1", id: "i-1", host: "one.example", sortOrder: 0, accountStamp: 100,
                    rowContentUpdatedDate: stampDate(100), mergePartnerSyncId: "w",
                    rows: &rows, table: &table)
        seedSettled("R2", id: "i-2", host: "two.example", sortOrder: 1, accountStamp: 100,
                    rows: &rows, table: &table)
        let access = FakeURLRuleAccess(rows: rows)
        let store = MemoryOwnedItemStore()
        store.table = table
        let client = publishingClient(seeding: ["R1", "R2"])
        let engine = try makeRuleEngine(access, store, client: client)
        await engine.setSpaceSyncEnabled(true)

        // ① E1 edits only ask.
        access.applyEditorSave(syncId: "R1", ask: true, at: stampDate(200))
        XCTAssertEqual(row(access, "R1")?.sortOrder, 0)

        // ② In-flight pure drag changes only position, not field values.
        let arrived = Gate()
        let release = Gate()
        client.gatedCommitTagHash = ruleHash("R1")
        client.arrivedInCommit = arrived
        client.commitGate = release
        let round = Task { await engine.pullOnce() }
        await arrived.wait()
        access.applyEditorReorder(syncId: "R1", toSortOrder: 1)
        await release.open()
        await round.value

        // ③ Applied acknowledges E1 at sortOrder 0 while the row is now at 1.
        XCTAssertEqual(clearCalls(access), ["R1"], "(a) Ran once normally")
        XCTAssertEqual(row(access, "R1")?.sortOrder, 1, "The drag reached the row")
        XCTAssertEqual(row(access, "R1")?.askBeforeRouting, true, "Field values match E1")
        XCTAssertEqual(flag(access, "R1"), true, "The third merge unit differs; retain pending")
        XCTAssertNil(row(access, "R1")?.mergePartnerSyncId, "The pointer still clears")
        XCTAssertEqual(flag(access, "R2"), false, "Renumbering does not set pending")
    }

    /// Clearing-(b) equivalent: E1 reached the account but (a) failed, leaving equal baselines and pending.
    /// After selecting R1 and its snapshot baseline, a pure drag occurs before write. Transaction sortOrder
    /// comparison must retain pending with no row write or pointer change. Omitting that eighth projection
    /// member would clear the unpublished drag's yielding protection.
    func testM7e_aPureReorderBetweenTheDecisionAndTheWriteKeepsTheFlag() async throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        seedSettled("R1", id: "i-1", host: "one.example", sortOrder: 0, accountStamp: 100,
                    pendingLocalEdit: true, mergePartnerSyncId: "w", rows: &rows, table: &table)
        seedSettled("R2", id: "i-2", host: "two.example", sortOrder: 1, accountStamp: 100,
                    rows: &rows, table: &table)
        let access = FakeURLRuleAccess(rows: rows)
        let store = MemoryOwnedItemStore()
        store.table = table
        let engine = try makeRuleEngine(access, store,
                                        client: publishingClient(seeding: ["R1", "R2"]))
        await engine.setSpaceSyncEnabled(true)

        access.beforeClearPendingLocalEditIfUnchanged = { [weak access] in
            access?.applyEditorReorder(syncId: "R1", toSortOrder: 1)
        }

        await engine.pullOnce()

        XCTAssertEqual(clearIfUnchangedCalls(access), [1], "(b) Actually included R1 in entries")
        XCTAssertEqual(access.lastClearEntries["R1"]?.sortOrder, 0, "Baseline records position at snapshot time")
        XCTAssertEqual(row(access, "R1")?.sortOrder, 1, "The drag reached the row")
        XCTAssertEqual(flag(access, "R1"), true, "Rank-unit mismatch prevents clearing")
        XCTAssertEqual(row(access, "R1")?.mergePartnerSyncId, "w", "(b) Leaves the pointer unchanged byte for byte")
        XCTAssertEqual(flag(access, "R2"), false)
    }

    /// No-op-hook control clears through (b), proving rank mismatch alone blocks the preceding case, not
    /// merely having a second row.
    func testM7e_withoutTheReorderTheSelfHealStillClears() async throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        seedSettled("R1", id: "i-1", host: "one.example", sortOrder: 0, accountStamp: 100,
                    pendingLocalEdit: true, mergePartnerSyncId: "w", rows: &rows, table: &table)
        seedSettled("R2", id: "i-2", host: "two.example", sortOrder: 1, accountStamp: 100,
                    rows: &rows, table: &table)
        let access = FakeURLRuleAccess(rows: rows)
        let store = MemoryOwnedItemStore()
        store.table = table
        let engine = try makeRuleEngine(access, store,
                                        client: publishingClient(seeding: ["R1", "R2"]))
        await engine.setSpaceSyncEnabled(true)

        await engine.pullOnce()

        XCTAssertEqual(flag(access, "R1"), false)
        XCTAssertEqual(row(access, "R1")?.mergePartnerSyncId, "w")
    }

}

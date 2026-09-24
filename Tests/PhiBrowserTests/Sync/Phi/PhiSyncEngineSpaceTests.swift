import CryptoKit
import XCTest
@testable import Phi

@MainActor
final class PhiSyncEngineSpaceTests: XCTestCase {
    typealias FakePhiSyncClient = PhiSyncEngineTests.FakePhiSyncClient
    typealias StubDomainKeys = PhiSyncEngineTests.StubDomainKeys
    /// A one-shot gate, so a test can park a round inside `getUpdates` and act while it sits
    /// there. Reused from `PhiSyncEngineTests` rather than re-declared.
    typealias Gate = PhiSyncEngineTests.Gate

    final class MemorySpaceStore: PhiSpaceSyncStateStore {
        var table = PhiSpaceSyncTable()
        /// When true, save returns false without changing table, modeling memory and
        /// disk retaining the old table after failure (R-M3-4a-83). Tests reset it to allow writes.
        var failNextSave = false
        /// Fail only save number N, counting saveCalls from 1, without changing table.
        /// B-2 needs precise failures such as the derived-flag write at round end.
        var failSaveOnCallNumber: Int?
        private(set) var saveCalls = 0
        func load() -> PhiSpaceSyncTable { table }
        @discardableResult
        func save(_ table: PhiSpaceSyncTable) -> Bool {
            saveCalls += 1
            guard !failNextSave, failSaveOnCallNumber != saveCalls else { return false }
            self.table = table
            return true
        }
    }

    /// The engine's clock, so a test can step past `profileRefreshMinIntervalMs`
    /// instead of sleeping. `now:` is already an init parameter.
    final class Clock {
        var nowMs: Int64 = 1_700_000_000_000
        /// Advance this many milliseconds per clock read; default zero preserves the
        /// frozen clock. Preview deadline tests use this deterministic slow-network model
        /// because the preview checks its budget at page boundaries.
        var advancePerRead: Int64 = 0

        func read() -> Int64 {
            defer { nowMs += advancePerRead }
            return nowMs
        }
    }

    private var defaults: UserDefaults!
    private var suiteName: String!
    private let key = SymmetricKey(size: .bits256)
    /// The process-wide closure replaced by CASE 2a.9, restored unchanged in tearDown.
    private var previousLocalSpaceIdLookup: ((String) -> String?)?

    override func setUp() {
        super.setUp()
        suiteName = "PhiSyncEngineSpaceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        previousLocalSpaceIdLookup = PhiSpaceSyncState.shared.localSpaceIdLookup
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil; suiteName = nil
        // CASE 2a.9 installs a counting resolver on PhiSpaceSyncState.shared. Restore
        // the previous resolver, not nil: this process-wide singleton may already have
        // a real resolver installed by the host app, and leaving the fake pollutes later tests.
        PhiSpaceSyncState.shared.localSpaceIdLookup = previousLocalSpaceIdLookup
        previousLocalSpaceIdLookup = nil
        super.tearDown()
    }

    /// Reference box for CASE 2a.9's escaping localSpaceIdLookup counter, avoiding
    /// mutable local captures that stricter concurrency checks could reject.
    final class LookupCounter {
        private(set) var calls = 0
        func bump() { calls += 1 }
    }

    // MARK: - Helpers

    private func spaceEntity(_ uuid: String, name: String = "Work",
                             profileUuid: String? = "uuid-a") -> Phi_PhiSpaceEntity {
        func v(_ s: String, _ ts: Int64 = 100) -> Phi_PhiSettingValue {
            var out = Phi_PhiSettingValue(); out.updatedAtMs = ts; out.stringValue = s; return out
        }
        var entity = Phi_PhiSpaceEntity()
        entity.spaceUuid = uuid
        entity.name = v(name)
        entity.iconName = v("emoji:1F4BC")
        entity.colorHex = v("#3A6FF8")
        entity.rank = v("V", 0)
        if uuid != LocalStore.defaultSpaceId {
            // `phi_entity.proto`: "Every field is ALWAYS emitted, never
            // omitted-when-empty", and `SyncableSpaces.snapshot` obeys that --
            // a Space with no pinned theme carries the explicit "". A fixture
            // that omitted `theme_id` therefore differed from its own snapshot
            // in `has_theme_id` alone, and every "this round publishes nothing"
            // assertion below would see one spurious no-op commit.
            entity.themeID = v("")
            if let profileUuid { entity.profileUuid = v(profileUuid) }
        }
        var light = Phi_PhiSettingValue(); light.intValue = -1
        entity.overlayOpacityLight = light
        entity.overlayOpacityDark = light
        entity.createdAtMs = 1_000
        return entity
    }

    private func rankedEntity(_ uuid: String, name: String = "Work",
                              rank: String) -> Phi_PhiSpaceEntity {
        var entity = spaceEntity(uuid, name: name)
        var value = Phi_PhiSettingValue(); value.updatedAtMs = 0; value.stringValue = rank
        entity.rank = value
        return entity
    }

    private func ciphertext(_ entity: Phi_PhiSpaceEntity) throws -> Data {
        var wrapper = Phi_PhiEntity()
        wrapper.space = entity
        return try PhiEntityCodec.encrypt(wrapper, key: key)
    }

    private func spaceHash(_ uuid: String) -> String {
        PhiSyncEntity.clientTagHash(for: PhiSyncEntity.spaceClientTag(uuid))
    }

    /// M3-2b: cursors use syncUuid keys, local rows use spaceId, and access mappings
    /// connect them. Build identity-bearing fixtures here so the Space is explicit
    /// in every case. The drain flag is fixed here; tests of its false value use
    /// PhiSpaceSyncTable directly, including drain/marker cases.
    private func makeSpaceTable(mappings: [String: String] = [:],
                                access: FakePhiSpaceAccess? = nil) -> PhiSpaceSyncTable {
        access?.spaceMappings = mappings
        var table = PhiSpaceSyncTable()
        table.hasDrainedFullReplay = true
        return table
    }

    /// `settings: []` is NOT cosmetic. Without it the engine builds against the
    /// production `SyncableSettings.all` registry over a throwaway defaults
    /// suite, and every round snapshots and commits a real settings entity into
    /// the same `client.commits` these tests count -- exactly what R10/R3
    /// established when `PhiSyncEngineTests` started passing a one-element
    /// registry. An empty registry still emits ONE settings commit on a first
    /// push (`storedLastEntity == nil`, so :553's early return does not fire),
    /// which is why every count assertion below goes through `spaceCommits(_:)`
    /// rather than `client.commits.count`.
    private func makeEngine(access: FakePhiSpaceAccess,
                            store: MemorySpaceStore,
                            client: FakePhiSyncClient,
                            markerStore: (any PhiSyncMarkerStore)? = nil,
                            replayToken: UUID? = nil,
                            clock: Clock = Clock()) -> PhiSyncEngine {
        PhiSyncEngine(domainKeys: StubDomainKeys(key: key), client: client,
                      defaults: defaults, deviceKeyId: "devA", pairingComplete: true,
                      enrollmentSpaceReplayToken: replayToken,
                      settings: [],
                      spaceAccess: access, spaceStore: store,
                      markerStore: markerStore,
                      now: { clock.read() })
    }

    /// Space-tagged commit entries only. The settings entity rides the same
    /// `commits` list and is not what any of these tests is about.
    private func spaceCommits(_ client: FakePhiSyncClient) -> [FakePhiSyncClient.CommitCall] {
        client.commits.filter { $0.clientTagHash != PhiSyncEntity.settingsClientTagHash }
    }

    // MARK: - Routing (§5.2)

    func testFailedPreflightBlocksEveryEntityKindAndPreservesPendingLocalData() async throws {
        try await assertFailedPullBlocksPublication(afterConflict: false)
    }

    func testFailedSpaceConflictPullAlsoBlocksLaterOwnedKinds() async throws {
        try await assertFailedPullBlocksPublication(afterConflict: true)
    }

    func testPreflightPreservesUnpublishedSpaceEditsAndOrder() async throws {
        let access = FakePhiSpaceAccess()
        access.uuidByProfileId = ["Default": "uuid-a", "Profile B": "uuid-b"]
        access.profileIdByUuid = ["uuid-a": "Default", "uuid-b": "Profile B"]
        access.spaces = ["s-1", "s-2"].enumerated().map { index, id in
            PhiLocalSpace(spaceId: id, profileId: "Default", name: "Work", colorHex: "#3A6FF8",
                          iconName: "emoji:1F4BC", sortOrder: index,
                          createdDate: Date(timeIntervalSince1970: 1), themeId: nil,
                          opacityLight: nil, opacityDark: nil)
        }
        let store = MemorySpaceStore()
        store.table = makeSpaceTable(mappings: ["s-1": "sync-1", "s-2": "sync-2"], access: access)
        let client = FakePhiSyncClient()
        let clock = Clock()
        clock.nowMs = 1_000
        let engine = makeEngine(access: access, store: store, client: client, clock: clock)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()
        await engine.pullOnce() // Consume our own writes before the concurrent edit.
        let peerRow = try XCTUnwrap(client.stored[spaceHash("sync-1")])
        client.nextVersion += 10
        client.reseed(tagHash: spaceHash("sync-1"), ciphertext: peerRow.ciphertext, version: client.nextVersion)
        clock.nowMs = 2_000
        access.spaces[0].name = "Renamed locally"
        access.spaces[0].profileId = "Profile B"
        access.spaces[0].sortOrder = 1
        access.spaces[1].sortOrder = 0
        access.spaces.sort { $0.sortOrder < $1.sortOrder }

        await engine.handleLocalSpacesChange()

        let local = try XCTUnwrap(access.spaces.first { $0.spaceId == "s-1" })
        XCTAssertEqual(local.name, "Renamed locally")
        XCTAssertEqual(local.profileId, "Profile B")
        XCTAssertEqual(access.spaces.sorted { $0.sortOrder < $1.sortOrder }.map(\.spaceId), ["s-2", "s-1"])
        let published = try XCTUnwrap(client.stored[spaceHash("sync-1")])
        let entity = try PhiEntityCodec.decrypt(published.ciphertext, key: key).space
        XCTAssertEqual(entity.name.stringValue, "Renamed locally")
        XCTAssertEqual(entity.profileUuid.stringValue, "uuid-b")
        let siblingRow = try XCTUnwrap(client.stored[spaceHash("sync-2")])
        let sibling = try PhiEntityCodec.decrypt(siblingRow.ciphertext, key: key).space
        XCTAssertLessThan(sibling.rank.stringValue, entity.rank.stringValue,
                          "The locally dragged sibling must keep its order on the server too")
    }

    /// Review A6: a peer reorders the strip; this device lands the new rank baselines but the
    /// account-wide reorder of its local rows fails. The old code swallowed that failure and
    /// kept the baselines, so the very next snapshot stamped the stale local order with a
    /// fresh timestamp and pushed it — reverting the peer's drag for the whole account. The
    /// reorder is a persistence failure of the page: the page's table changes roll back, the
    /// marker does not advance, nothing publishes, and the replay applies the order.
    func testAFailedAccountWideReorderReplaysThePageInsteadOfRepublishingTheStaleOrder() async throws {
        struct ReorderFailed: Error {}
        let access = FakePhiSpaceAccess()
        access.uuidByProfileId = ["Default": "uuid-a"]
        access.profileIdByUuid = ["uuid-a": "Default"]
        access.spaces = ["s-1", "s-2"].enumerated().map { index, id in
            PhiLocalSpace(spaceId: id, profileId: "Default", name: "Work", colorHex: "#3A6FF8",
                          iconName: "emoji:1F4BC", sortOrder: index,
                          createdDate: Date(timeIntervalSince1970: 1), themeId: nil,
                          opacityLight: nil, opacityDark: nil)
        }
        let store = MemorySpaceStore()
        store.table = makeSpaceTable(mappings: ["s-1": "sync-1", "s-2": "sync-2"], access: access)
        let client = FakePhiSyncClient()
        // The peer's order puts s-2 first.
        client.seed(tagHash: spaceHash("sync-1"),
                    ciphertext: try ciphertext(rankedEntity("sync-1", rank: "b")), version: 3)
        client.seed(tagHash: spaceHash("sync-2"),
                    ciphertext: try ciphertext(rankedEntity("sync-2", rank: "a")), version: 4)
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)

        access.applyOrderError = ReorderFailed()
        let cursorsBefore = store.table.cursors
        await engine.pullOnce()

        let outcome = await engine.lastRoundOutcomeForTesting
        XCTAssertEqual(outcome, .cursorSaveFailed)
        XCTAssertEqual(store.table.cursors, cursorsBefore,
                       "no baseline may describe a local order that was never written")
        XCTAssertNil(defaults.data(forKey: PhiSyncEngine.markerStateKey), "the page marker did not advance")
        XCTAssertTrue(spaceCommits(client).isEmpty,
                      "the stale local order must not be republished over the peer's")
        XCTAssertEqual(access.spaces.sorted { $0.sortOrder < $1.sortOrder }.map(\.spaceId), ["s-1", "s-2"])

        access.applyOrderError = nil
        await engine.pullOnce()

        XCTAssertEqual(access.spaces.sorted { $0.sortOrder < $1.sortOrder }.map(\.spaceId), ["s-2", "s-1"],
                       "the replayed page applies the peer's order")
        XCTAssertTrue(spaceCommits(client).isEmpty, "converged: there is nothing to republish")
        XCTAssertNotNil(defaults.data(forKey: PhiSyncEngine.markerStateKey))
    }

    private func assertFailedPullBlocksPublication(afterConflict: Bool) async throws {
        let access = FakePhiSpaceAccess()
        access.spaces = [PhiLocalSpace(spaceId: "s-1", profileId: "Default", name: "Work",
                                      colorHex: "#3A6FF8", iconName: "emoji:1F4BC", sortOrder: 0,
                                      createdDate: Date(timeIntervalSince1970: 1), themeId: nil,
                                      opacityLight: nil, opacityDark: nil)]
        access.uuidByProfileId = ["Default": "pu-1"]
        access.profileIdByUuid = ["pu-1": "Default"]
        access.knownLocalProfileIds = ["Default"]
        let store = MemorySpaceStore()
        store.table = makeSpaceTable(mappings: ["s-1": "su-1"], access: access)
        let bookmarks = FakeBookmarkAccess(rows: [.fixture(guid: "local-bookmark", spaceId: "s-1")])
        let pins = FakePinAccess(scope: .space, account: .space,
                                 rows: [.fixture(lineageId: "local-pin", spaceId: "s-1", profileId: nil)])
        let client = FakePhiSyncClient()
        let clock = Clock()
        clock.nowMs = 2_000
        let engine = PhiSyncEngine(domainKeys: StubDomainKeys(key: key), client: client,
                                   defaults: defaults, deviceKeyId: "devA", pairingComplete: true, settings: [],
                                   spaceAccess: access, spaceStore: store,
                                   ownedKinds: [.bookmarks(access: bookmarks, store: MemoryOwnedItemStore()),
                                                .pins(access: pins, store: MemoryOwnedItemStore())],
                                   now: { clock.read() })
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()
        let published = client.commits.count
        clock.nowMs = 3_000
        access.spaces[0].name = "Renamed"
        bookmarks.rows[0].title = "Renamed"
        pins.rows[0].title = "Renamed"
        if afterConflict {
            client.conflictOnceForTagHashes = [spaceHash("su-1")]
            client.getUpdatesErrorAfterPages = (1, URLError(.notConnectedToInternet))
        } else {
            client.getUpdatesErrorOnce = URLError(.notConnectedToInternet)
        }

        await engine.handleLocalOwnedChange(label: "bookmarks")

        let attempted = Array(client.commits.dropFirst(published))
        XCTAssertEqual(attempted.count, afterConflict ? 1 : 0)
        XCTAssertFalse(attempted.contains { $0.name == PhiSyncEntity.bookmarkEntityName || $0.name == PhiSyncEntity.pinEntityName },
                       "A failed pull must also block later entity kinds")
        XCTAssertEqual(bookmarks.rows.count, 1)
        XCTAssertEqual(pins.rows.count, 1)
        let beforeRecovery = client.commits.count
        await engine.handleLocalSpacesChange()
        let recovered = Array(client.commits.dropFirst(beforeRecovery))
        XCTAssertTrue(recovered.contains { $0.name == PhiSyncEntity.spaceEntityName })
        XCTAssertTrue(recovered.contains { $0.name == PhiSyncEntity.bookmarkEntityName })
        XCTAssertTrue(recovered.contains { $0.name == PhiSyncEntity.pinEntityName })
    }

    func testAGatedOffEngineNeverHandsSpaceEntitiesToTheSpaceSection() async throws {
        let access = FakePhiSpaceAccess()
        let store = MemorySpaceStore()
        let client = FakePhiSyncClient()
        client.seed(tagHash: spaceHash("u1"),
                    ciphertext: try ciphertext(spaceEntity("u1")), version: 3)
        let engine = makeEngine(access: access, store: store, client: client)
        // gate left shut
        await engine.pullOnce()
        XCTAssertTrue(access.calls.filter { $0 != .refreshProfiles }.isEmpty)
        XCTAssertTrue(store.table.cursors.isEmpty)
        // A pull that moved the marker while the gate was shut must be recorded.
        XCTAssertTrue(store.table.markerMovedWhileGateShut)
        // Guard 1 must NOT be satisfied by a gated-off drain (§5.5 guard 1).
        XCTAssertFalse(store.table.hasDrainedFullReplay)
        XCTAssertFalse(store.table.drainInProgress)
    }

    func testAnUnknownKindIsIgnoredWithoutTouchingTheMarkerOrTheSettings() async throws {
        let access = FakePhiSpaceAccess()
        let store = MemorySpaceStore()
        let client = FakePhiSyncClient()
        // An UNASSIGNED oneof field: a future client's payload. Field 7 (0x3A = 7 << 3 | 2,
        // then a zero length), deliberately above everything `PhiEntity.kind` names today --
        // M3-3 took field 3 for the bookmark kind and field 4 for pinned tabs, so the
        // original seed here stopped being an unknown kind the moment those landed.
        client.seed(tagHash: "future-hash",
                    ciphertext: try PhiKeyCrypto.sealWithSymmetric(Data([0x3A, 0x00]), key: key),
                    version: 2)
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()
        XCTAssertNotNil(defaults.data(forKey: PhiSyncEngine.markerStateKey),
                        "an unknown kind must never rewind the shared marker")
        XCTAssertTrue(store.table.unreadableTagHashes.isEmpty)
    }

    func testAnUndecryptableSpaceEntityIsRecordedByTagHashAndSkipped() async throws {
        let access = FakePhiSpaceAccess()
        let store = MemorySpaceStore()
        let client = FakePhiSyncClient()
        let goodHash = spaceHash("good")
        let badHash = spaceHash("bad")
        client.seed(tagHash: goodHash, ciphertext: try ciphertext(spaceEntity("good")), version: 3)
        client.seed(tagHash: badHash, ciphertext: Data([0xDE, 0xAD]), version: 4)
        access.profileIdByUuid = ["uuid-a": "Default"]
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertEqual(Set(store.table.unreadableTagHashes.keys), [badHash])
        XCTAssertNil(store.table.unreadableTagHashes[goodHash],
                     "one bad entity must not stop the good ones")
        // Task 9's apply path lands `good` and writes its cursor; `bad` never
        // decoded, so it has none and lives only in `unreadableTagHashes`.
        XCTAssertNil(store.table.cursors["bad"])
        XCTAssertNotNil(store.table.cursors["good"])
        // A pull that reached the Space section still counts as a drain.
        XCTAssertTrue(store.table.hasDrainedFullReplay)
    }

    func testATagHashThatDoesNotMatchThePayloadUuidIsRefused() async throws {
        let access = FakePhiSpaceAccess()
        let store = MemorySpaceStore()
        let client = FakePhiSyncClient()
        let wrongHash = spaceHash("other")
        client.seed(tagHash: wrongHash, ciphertext: try ciphertext(spaceEntity("u1")), version: 3)
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()
        XCTAssertEqual(Set(store.table.unreadableTagHashes.keys), [wrongHash])
        XCTAssertNil(store.table.cursors["u1"])
    }

    func testATombstoneIsRoutedBeforeAnyDecryptAttempt() async throws {
        let access = FakePhiSpaceAccess()
        let store = MemorySpaceStore()
        // A tombstone carries the type's default specifics, i.e. no ciphertext
        // at all: routing it after the decrypt would file every remote delete
        // under `unreadableTagHashes` and lose it with the marker.
        store.table.cursors["u1"] = PhiSpaceCursor()
        let client = FakePhiSyncClient()
        client.seed(tagHash: spaceHash("u1"), ciphertext: Data(), version: 5, deleted: true)
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()
        XCTAssertTrue(store.table.unreadableTagHashes.isEmpty)
    }

    // MARK: - Guard 1: drain (§5.5)

    func testDrainCompletesAcrossPagesAndFollowUpRounds() async throws {
        let access = FakePhiSpaceAccess()
        let store = MemorySpaceStore()
        let client = FakePhiSyncClient()
        // A supply of `changes_remaining` pages that outlasts the engine's own
        // budget AND every bounded follow-up round it queues (64 pages x 5
        // rounds). A supply of exactly 64 would be spent by the first round, and
        // the unawaited follow-up would then drain and race the assertions below.
        client.pageBudgetExhaustsAfter = 1_000     // first pull hits the page cap
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()
        XCTAssertTrue(store.table.drainInProgress)
        XCTAssertFalse(store.table.hasDrainedFullReplay,
                       "a page-budget cut ends the round, it does not end the drain")

        client.pageBudgetExhaustsAfter = nil     // the follow-up round finishes it
        await engine.pullOnce()
        XCTAssertTrue(store.table.hasDrainedFullReplay)
        XCTAssertFalse(store.table.drainInProgress)
    }

    // MARK: - Guard 2: replay on the shut -> open edge (§5.5)

    func testOpeningTheGateAfterAMarkerMoveReplaysTheWholeType() async throws {
        let access = FakePhiSpaceAccess()
        let store = MemorySpaceStore()
        let client = FakePhiSyncClient()
        // Something for the shared marker to walk past while the gate is shut.
        client.seed(tagHash: spaceHash("u1"),
                    ciphertext: try ciphertext(spaceEntity("u1")), version: 3)
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.pullOnce()                       // gate shut, marker moves
        XCTAssertTrue(store.table.markerMovedWhileGateShut)

        await engine.setSpaceSyncEnabled(true)
        XCTAssertNil(defaults.data(forKey: PhiSyncEngine.markerStateKey),
                     "opening the gate must drop the shared marker and replay")
        XCTAssertFalse(store.table.markerMovedWhileGateShut)
        XCTAssertTrue(store.table.drainInProgress)
        XCTAssertFalse(store.table.hasDrainedFullReplay)
    }

    func testASecondClosedEpisodeReplaysAgain() async throws {
        let access = FakePhiSpaceAccess()
        let store = MemorySpaceStore()
        let client = FakePhiSyncClient()
        client.seed(tagHash: spaceHash("u1"),
                    ciphertext: try ciphertext(spaceEntity("u1")), version: 3)
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()
        XCTAssertTrue(store.table.hasDrainedFullReplay)
        XCTAssertNotNil(defaults.data(forKey: PhiSyncEngine.markerStateKey))

        await engine.setSpaceSyncEnabled(false)       // ARK locked / self-revoke / safety-net modal
        client.seed(tagHash: spaceHash("u2"),
                    ciphertext: try ciphertext(spaceEntity("u2")), version: 7)
        await engine.pullOnce()                       // settings keep pulling; the marker moves
        XCTAssertTrue(store.table.markerMovedWhileGateShut)
        await engine.setSpaceSyncEnabled(true)
        XCTAssertNil(defaults.data(forKey: PhiSyncEngine.markerStateKey),
                     "a one-shot replay flag would lose every update from the second shut episode")
    }

    /// The M3-1 -> M3-2 upgrade path, which no flag in the table can describe:
    /// a device that has synced settings for months already holds a non-nil
    /// `phi.sync.marker`, has an empty `sync.phiSpaces` (`hadRecords == false`,
    /// so guard 2's second trigger is off) and never set
    /// `markerMovedWhileGateShut` because the flag did not exist. Guard 1 must
    /// still be armed the first time the gate opens, or the device never drains
    /// and therefore never publishes a single Space.
    func testTheFirstEverEnablementReplaysEvenWithNoRecordedMarkerMove() async throws {
        let access = FakePhiSpaceAccess()
        let store = MemorySpaceStore()
        let client = FakePhiSyncClient()
        // An M3-1 device's state: a marker on disk, an untouched Space table.
        defaults.set(Data("m3-1-marker".utf8), forKey: PhiSyncEngine.markerStateKey)
        XCTAssertFalse(store.table.markerMovedWhileGateShut)
        XCTAssertFalse(store.table.hasDrainedFullReplay)
        XCTAssertFalse(store.table.hadRecords)

        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        XCTAssertNil(defaults.data(forKey: PhiSyncEngine.markerStateKey),
                     "the first enablement must drop the settings-era marker")
        XCTAssertTrue(store.table.drainInProgress)

        await engine.pullOnce()
        XCTAssertTrue(store.table.hasDrainedFullReplay)
        XCTAssertFalse(store.table.drainInProgress)
    }

    /// Review A1: `marker.json` and the Space table cannot be written atomically, so opening the
    /// gate must persist the nil marker FIRST and only then consume `markerMovedWhileGateShut`
    /// and arm the drain — the same order guard 2 and the owned-kind loss path use. If the
    /// marker write fails, the latch must survive and the next pull must retry the replay;
    /// otherwise the old marker stands past every Space entity the shut episode walked over,
    /// the next incremental pull stamps `hasDrainedFullReplay`, and those entities are lost.
    func testAFailedNilMarkerWriteWhenTheGateOpensKeepsTheLatchAndRetriesNextRound() async throws {
        let access = FakePhiSpaceAccess()
        access.uuidByProfileId = ["Default": "uuid-a"]
        access.profileIdByUuid = ["uuid-a": "Default"]
        let store = MemorySpaceStore()
        let marker = MemoryMarkerStore()
        let client = FakePhiSyncClient()
        client.seed(tagHash: spaceHash("u1"),
                    ciphertext: try ciphertext(spaceEntity("u1")), version: 3)
        let engine = makeEngine(access: access, store: store, client: client, markerStore: marker)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()
        XCTAssertTrue(store.table.hasDrainedFullReplay)
        let markerAfterFirstDrain = marker.file.marker
        XCTAssertNotNil(markerAfterFirstDrain)

        await engine.setSpaceSyncEnabled(false)
        client.seed(tagHash: spaceHash("u2"),
                    ciphertext: try ciphertext(spaceEntity("u2")), version: 7)
        await engine.pullOnce()                       // gated-off pull; the marker walks past u2
        XCTAssertTrue(store.table.markerMovedWhileGateShut)
        let markerBeforeReopen = marker.file.marker
        XCTAssertNotEqual(markerBeforeReopen, markerAfterFirstDrain)

        marker.failSaveOnCallNumber = marker.saves.count + 1
        await engine.setSpaceSyncEnabled(true)        // the nil-marker write fails
        let gateOutcome = await engine.lastRoundOutcomeForTesting
        XCTAssertEqual(gateOutcome, .cursorSaveFailed)
        XCTAssertEqual(marker.file.marker, markerBeforeReopen, "a failed write must leave the marker as it was")
        XCTAssertTrue(store.table.markerMovedWhileGateShut,
                      "the latch is the only record of the gap; it may be consumed only after the nil marker is on disk")
        XCTAssertFalse(store.table.drainInProgress)
        XCTAssertTrue(store.table.hasDrainedFullReplay,
                      "the drain flags must not be touched while the old marker still stands")
        XCTAssertTrue(store.table.spaceSectionEnabled)

        // The next round retries from the persisted latch: nil marker first, then the flags.
        let getUpdatesBefore = client.getUpdatesCalls.count
        await engine.pullOnce()
        XCTAssertNil(client.getUpdatesCalls[getUpdatesBefore].marker,
                     "the retry must replay the data type from the beginning")
        XCTAssertFalse(store.table.markerMovedWhileGateShut)
        XCTAssertFalse(store.table.drainInProgress)
        XCTAssertTrue(store.table.hasDrainedFullReplay)
        XCTAssertTrue(access.spaces.contains { access.syncUuid(forSpaceId: $0.spaceId) == "u2" },
                      "the Space the shut episode walked past must land on the retry")
    }

    /// Review A3: the account's settings entity is sealed with a key this device does not hold
    /// (a re-mint it has not caught up with). That refusal is settings-only. The first drain must
    /// still finalize, the marker must persist, and the Spaces this device holds must publish —
    /// otherwise a fresh device could never publish a single Space for as long as the entity
    /// stayed unreadable, and it re-downloaded the whole type every round trying.
    func testAnUnreadableSettingsEntityDoesNotHoldTheDrainOrSpacePublication() async throws {
        let access = FakePhiSpaceAccess()
        access.uuidByProfileId = ["Default": "uuid-a"]
        access.profileIdByUuid = ["uuid-a": "Default"]
        access.spaces = [PhiLocalSpace(spaceId: "s-1", profileId: "Default", name: "Work",
                                       colorHex: "#3A6FF8", iconName: "emoji:1F4BC", sortOrder: 0,
                                       createdDate: Date(timeIntervalSince1970: 1), themeId: nil,
                                       opacityLight: nil, opacityDark: nil)]
        let store = MemorySpaceStore()
        let marker = MemoryMarkerStore()
        let client = FakePhiSyncClient()
        var wrapper = Phi_PhiEntity()
        wrapper.space = spaceEntity("ignored")
        client.seed(tagHash: PhiSyncEntity.settingsClientTagHash,
                    ciphertext: try PhiEntityCodec.encrypt(wrapper, key: SymmetricKey(size: .bits256)),
                    version: 5)
        client.seed(tagHash: spaceHash("u1"),
                    ciphertext: try ciphertext(spaceEntity("u1")), version: 6)
        let engine = makeEngine(access: access, store: store, client: client, markerStore: marker)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let outcome = await engine.lastRoundOutcomeForTesting
        XCTAssertEqual(outcome, .unusableSettings)
        XCTAssertTrue(store.table.hasDrainedFullReplay, "the drain saw every page; settings alone were refused")
        XCTAssertFalse(store.table.drainInProgress)
        XCTAssertNotNil(marker.file.marker, "the shared marker persists; only the settings entity is held")
        XCTAssertTrue(access.spaces.contains { access.syncUuid(forSpaceId: $0.spaceId) == "u1" },
                      "the Space on the same drain lands")
        XCTAssertFalse(spaceCommits(client).isEmpty,
                       "this device's own Space publishes in the same round")
        XCTAssertFalse(client.commits.contains { $0.clientTagHash == PhiSyncEntity.settingsClientTagHash },
                       "settings publication stays refused")

        // A second round under the same key does not re-download the type.
        let calls = client.getUpdatesCalls.count
        await engine.pullOnce()
        XCTAssertEqual(client.getUpdatesCalls[calls].marker, marker.file.marker)
    }

    func testOpeningTheGateWithNoMarkerMovementDoesNotReplay() async throws {
        let access = FakePhiSpaceAccess()
        let store = MemorySpaceStore()
        let client = FakePhiSyncClient()
        client.seed(tagHash: spaceHash("u1"),
                    ciphertext: try ciphertext(spaceEntity("u1")), version: 3)
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()
        let marker = defaults.data(forKey: PhiSyncEngine.markerStateKey)
        XCTAssertNotNil(marker)
        await engine.setSpaceSyncEnabled(false)
        await engine.setSpaceSyncEnabled(true)
        XCTAssertEqual(defaults.data(forKey: PhiSyncEngine.markerStateKey), marker)
    }

    /// While unpaired no round runs, so the gate close is dropped and no pull moves the
    /// marker. Setup completion must still replay the type under the confirmed mappings;
    /// legacy activation (no replay request) must not.
    func testCompletingSetupReplaysTheTypeEvenThoughTheGateNeverClosed() async throws {
        let access = FakePhiSpaceAccess()
        let store = MemorySpaceStore()
        let client = FakePhiSyncClient()
        client.seed(tagHash: spaceHash("u1"),
                    ciphertext: try ciphertext(spaceEntity("u1")), version: 3)
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()
        let marker = defaults.data(forKey: PhiSyncEngine.markerStateKey)
        XCTAssertNotNil(marker)

        engine.suspendForPairing()
        await engine.setSpaceSyncEnabled(false)
        await engine.enableAfterPairing()
        await engine.setSpaceSyncEnabled(true)
        XCTAssertEqual(defaults.data(forKey: PhiSyncEngine.markerStateKey), marker,
                       "Legacy activation keeps the marker")

        engine.suspendForPairing()
        await engine.setSpaceSyncEnabled(false)
        await engine.enableAfterPairing(replayToken: UUID())
        await engine.setSpaceSyncEnabled(true)
        XCTAssertNil(defaults.data(forKey: PhiSyncEngine.markerStateKey),
                     "Setup completion drops the marker so the type replays")
    }

    func testEnrollmentReplayRetriesLatchFailureAndLandsTheConfirmedSpace() async throws {
        let access = FakePhiSpaceAccess()
        let store = MemorySpaceStore()
        let client = FakePhiSyncClient()
        client.seed(tagHash: spaceHash("u1"),
                    ciphertext: try ciphertext(spaceEntity("u1", name: "Account Work")), version: 3)
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()
        let priorCalls = client.getUpdatesCalls.count
        engine.suspendForPairing()
        access.spaces = [localSpace("LOCAL-1", "Local Work", order: 1)]
        access.spaceMappings = ["LOCAL-1": "u1"]
        access.profileIdByUuid = ["uuid-a": "Default"]
        access.uuidByProfileId = ["Default": "uuid-a"]
        let token = UUID()
        await engine.enableAfterPairing(replayToken: token)
        store.failNextSave = true
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()
        XCTAssertEqual(client.getUpdatesCalls.count, priorCalls,
                       "A failed latch write blocks the old incremental pull")
        store.failNextSave = false
        await engine.pullOnce()
        XCTAssertNil(client.getUpdatesCalls[priorCalls].marker)
        XCTAssertEqual(store.table.lastEnrollmentReplayToken, token)
        XCTAssertEqual(access.spaces.first { $0.spaceId == "LOCAL-1" }?.name, "Account Work")
    }

    func testRestartRestoresEnrollmentReplayBeforeActivationAndConsumesItOnce() async throws {
        let access = FakePhiSpaceAccess()
        let store = MemorySpaceStore()
        let client = FakePhiSyncClient()
        let first = makeEngine(access: access, store: store, client: client)
        await first.setSpaceSyncEnabled(true)
        await first.pullOnce()
        first.suspendForPairing()
        let token = UUID()
        let restarted = makeEngine(access: access, store: store, client: client, replayToken: token)
        let priorCalls = client.getUpdatesCalls.count
        await restarted.pullOnce()
        XCTAssertNil(client.getUpdatesCalls[priorCalls].marker)
        XCTAssertEqual(store.table.lastEnrollmentReplayToken, token)
        let marker = defaults.data(forKey: PhiSyncEngine.markerStateKey)
        XCTAssertNotNil(marker)
        restarted.suspendForPairing()
        let again = makeEngine(access: access, store: store, client: client, replayToken: token)
        let nextCalls = client.getUpdatesCalls.count
        await again.pullOnce()
        XCTAssertEqual(client.getUpdatesCalls[nextCalls].marker, marker,
                       "The same enrollment cannot replay on every startup")
    }

    func testAnEmptyTableWithHadRecordsReplaysExactlyOnce() async throws {
        let access = FakePhiSpaceAccess()
        let store = MemorySpaceStore()
        store.table.hadRecords = true
        store.table.hasDrainedFullReplay = true
        let client = FakePhiSyncClient()
        // Every account Space fails to decrypt, so `cursors` stays empty forever:
        // the guard must be the one-shot flag, not `hadRecords`.
        client.seed(tagHash: spaceHash("u1"), ciphertext: Data([0xDE, 0xAD]), version: 3)
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()
        XCTAssertTrue(store.table.didReplayForEmptyTable)
        XCTAssertNil(defaults.data(forKey: PhiSyncEngine.markerStateKey),
                     "the replay drops the shared marker so the next round replays the type")
        await engine.pullOnce()
        XCTAssertNotNil(defaults.data(forKey: PhiSyncEngine.markerStateKey),
                        "the empty-table replay is one-shot: the second round keeps its marker")
    }

    // MARK: - NOT_MY_BIRTHDAY (§5.1)

    func testNotMyBirthdayPreservesSpaceMetadata() async throws {
        let access = FakePhiSpaceAccess()
        let store = MemorySpaceStore()
        store.table = makeSpaceTable(access: access)
        var cursor = PhiSpaceCursor()
        cursor.entityId = "srv-1"; cursor.version = 9
        cursor.reconciled = Data([0x01]); cursor.server = Data([0x02])
        cursor.deleteRejectRounds = 2
        store.table.cursors["sync-1"] = cursor
        store.table.unreadableTagHashes["h"] = 1

        let client = FakePhiSyncClient()
        client.throwNotMyBirthdayOnce = true
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        let before = store.table
        await engine.pullOnce()
        XCTAssertEqual(store.table, before)
        XCTAssertTrue(engine.requiresReconfiguration)
    }

    // MARK: - Second local-change trigger (§5.4)

    func testHandleLocalSpacesChangeRunsAPushRound() async throws {
        let access = FakePhiSpaceAccess()
        access.uuidByProfileId = ["Default": "uuid-a"]
        access.spaces = [PhiLocalSpace(spaceId: "LOCAL-1", profileId: "Default", name: "Work",
                                       colorHex: "#3A6FF8", iconName: "emoji:1F4BC", sortOrder: 0,
                                       createdDate: Date(timeIntervalSince1970: 1),
                                       themeId: nil, opacityLight: nil, opacityDark: nil)]
        let store = MemorySpaceStore()
        // `pushSpaces` refuses to publish anything until D2 has been answered
        // (§8). Task 13 is what sets this automatically ("no local-only Spaces"
        // or "empty account" -> keepBoth); until then every push-side fixture
        // seeds it through `makeSpaceTable`, or it asserts commits that can
        // never happen.
        store.table = makeSpaceTable(mappings: ["LOCAL-1": "sync-1"], access: access)
        let client = FakePhiSyncClient()
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.handleLocalSpacesChange()
        // The round really ran: `.localSpaceChange` reaches `push`, which pulls
        // first because this device has never synced.
        XCTAssertFalse(client.getUpdatesCalls.isEmpty)
        // ...and with Task 9 Step 4.0/4.1 in place the trigger now reaches
        // `pushSpaces`: `push` runs the settings half and then the Space half
        // unconditionally, so the one local Space is published this round --
        // under its mapped syncUuid, never under the local row id.
        XCTAssertEqual(spaceCommits(client).map(\.clientTagHash), [spaceHash("sync-1")])
    }

    // MARK: - Durability of the Space-side state (fix round 1)

    /// The shared marker is persisted page by page, so everything derived from it has to be
    /// persisted page by page too. A gated-off round whose second page throws has already
    /// moved the marker past whatever page 1 carried — a peer's Space rename, say. If
    /// `markerMovedWhileGateShut` were written only on the round's success path, the next gate
    /// open would take neither disjunct in `applySpaceGate`, never replay, and that rename
    /// would be lost on this device until some peer touched the Space again.
    func testAGatedOffRoundThatFailsOnALaterPageStillRecordsTheMarkerMove() async throws {
        let access = FakePhiSpaceAccess()
        let store = MemorySpaceStore()
        // A device that drained during an earlier open episode: only `markerMovedWhileGateShut`
        // can arm the replay below, which is what makes this test discriminating.
        store.table.hasDrainedFullReplay = true
        let client = FakePhiSyncClient()
        client.seed(tagHash: spaceHash("u1"),
                    ciphertext: try ciphertext(spaceEntity("u1")), version: 3)
        client.pageBudgetExhaustsAfter = 8                    // page 1 says "more to come"
        client.getUpdatesErrorAfterPages = (pages: 1, error: URLError(.timedOut))
        let engine = makeEngine(access: access, store: store, client: client)

        await engine.pullOnce()                               // gate shut; page 2 throws
        XCTAssertEqual(client.getUpdatesCalls.count, 2)
        XCTAssertNotNil(defaults.data(forKey: PhiSyncEngine.markerStateKey),
                        "page 1's marker advance is durable — which is the whole problem")
        XCTAssertTrue(store.table.markerMovedWhileGateShut,
                      "the record of the move must be as durable as the move")

        await engine.setSpaceSyncEnabled(true)
        XCTAssertNil(defaults.data(forKey: PhiSyncEngine.markerStateKey),
                     "so the gate open still replays what the failed round walked past")
    }

    /// The same rule on the drain side. Guard 1 is armed at the pull's entry from
    /// `storedMarker == nil`, and page 1 makes the marker non-nil. An arming that lived only
    /// in the round's local copy of the table would be thrown away when page 2 throws, leaving
    /// a non-nil marker beside `drainInProgress == false` — a state whose entry precondition
    /// can never be met again, so `hasDrainedFullReplay` would stay false for the whole
    /// session and Task 9's `pushSpaces` guard would block every publish until relaunch.
    func testADrainArmedByARoundThatFailsMidWaySurvivesAndCompletesLater() async throws {
        let access = FakePhiSpaceAccess()
        let store = MemorySpaceStore()
        // Live and already drained once; the marker was dropped by something else (a
        // NOT_MY_BIRTHDAY reset, the empty-table replay), so the arming happens at the pull's
        // entry rather than on the gate edge.
        store.table.spaceSectionEnabled = true
        store.table.hasDrainedFullReplay = true
        let client = FakePhiSyncClient()
        client.seed(tagHash: spaceHash("u1"),
                    ciphertext: try ciphertext(spaceEntity("u1")), version: 3)
        client.pageBudgetExhaustsAfter = 8
        client.getUpdatesErrorAfterPages = (pages: 1, error: URLError(.timedOut))
        let engine = makeEngine(access: access, store: store, client: client)

        await engine.pullOnce()
        XCTAssertTrue(store.table.drainInProgress,
                      "the arming belongs on disk, not in the round that armed it")
        XCTAssertFalse(store.table.hasDrainedFullReplay)

        client.pageBudgetExhaustsAfter = nil
        await engine.pullOnce()
        XCTAssertTrue(store.table.hasDrainedFullReplay, "the next round finishes the drain")
        XCTAssertFalse(store.table.drainInProgress)
    }

    /// Finish the drain by replaying, rather than continuing past the failure.
    /// Under M3-4a B-2's page boundary, page 1 applies u1 immediately and the marker
    /// passes only fully applied pages, so the old gap argument no longer applies.
    /// Task 2b ruling 10 still requires one complete armed drain: resuming from the
    /// advanced marker could mark hasDrainedFullReplay=true without traversing the
    /// entire type. Neither applySpaceGate disjunct could then re-arm replay, since
    /// markerMovedWhileGateShut=false and hasDrainedFullReplay=true. Owned kinds
    /// read this guard before publishing.
    /// Keep dropping the marker while drainInProgress is armed; restart from the
    /// beginning and never declare completion between failed rounds. The incremental
    /// variant retaining the last applied marker is CASE B2-8(a), PhiSyncMarkerBoundaryTests.
    func testADrainInterruptedMidWayReplaysFromScratchInsteadOfCompletingOverTheGap() async throws {
        let access = FakePhiSpaceAccess()
        let store = MemorySpaceStore()
        store.table.spaceSectionEnabled = true
        // Already drained once, so the arming happens at the pull's entry (`storedMarker ==
        // nil`) rather than on a gate edge — the gate never moves in this test, which is what
        // makes `markerMovedWhileGateShut` powerless to save the replay afterwards.
        store.table.hasDrainedFullReplay = true
        let client = FakePhiSyncClient()
        client.seed(tagHash: spaceHash("u1"),
                    ciphertext: try ciphertext(spaceEntity("u1")), version: 3)
        client.pageBudgetExhaustsAfter = 8                    // page 1 says "more to come"
        client.getUpdatesErrorAfterPages = (pages: 1, error: URLError(.timedOut))
        let engine = makeEngine(access: access, store: store, client: client)

        await engine.pullOnce()                               // page 1 lands u1; page 2 throws
        XCTAssertEqual(client.getUpdatesCalls.count, 2)
        XCTAssertNil(defaults.data(forKey: PhiSyncEngine.markerStateKey),
                     "an interrupted armed drain drops the marker so the replay restarts")
        XCTAssertTrue(store.table.drainInProgress, "and stays armed until a whole replay lands")
        XCTAssertFalse(store.table.hasDrainedFullReplay)

        client.pageBudgetExhaustsAfter = nil
        await engine.pullOnce()
        // The fake answers from a watermark parsed out of the marker, so a marker that had
        // survived the failure would filter u1 out of this round exactly as the real server
        // would — and the drain would then complete having never delivered it.
        let lastCall = try XCTUnwrap(client.getUpdatesCalls.last)
        XCTAssertNil(lastCall.marker, "the follow-up round replays the type from scratch")
        XCTAssertTrue(store.table.hasDrainedFullReplay)
        XCTAssertFalse(store.table.drainInProgress)
    }

    /// Reentrancy: the engine is an actor, so an awaited gate open can land while a round is
    /// parked in `getUpdates`. A round that read the table before that point and wrote its
    /// whole copy back afterwards would revert the edge — `spaceSectionEnabled`, the dropped
    /// marker and the re-armed drain in one write — leaving the engine live in memory with a
    /// drain nothing can arm again. The edge is a queued round, so it lands strictly between
    /// rounds whichever way the two tasks interleave.
    func testAGateOpenAwaitedDuringAParkedRoundIsNotRevertedByThatRound() async throws {
        let access = FakePhiSpaceAccess()
        let store = MemorySpaceStore()
        let client = FakePhiSyncClient()
        client.seed(tagHash: spaceHash("u1"),
                    ciphertext: try ciphertext(spaceEntity("u1")), version: 3)
        let arrived = Gate()
        let release = Gate()
        client.arrivedInGetUpdates = arrived
        client.getUpdatesGate = release
        let engine = makeEngine(access: access, store: store, client: client)

        let round = Task { await engine.pullOnce() }        // gate shut
        await arrived.wait()                                // ... and parked in getUpdates
        let opened = Task { await engine.setSpaceSyncEnabled(true) }
        await release.open()
        await round.value
        await opened.value

        XCTAssertTrue(store.table.spaceSectionEnabled)
        XCTAssertTrue(store.table.drainInProgress,
                      "the gate edge must outlive the round it was awaited against")
        XCTAssertFalse(store.table.hasDrainedFullReplay)
        XCTAssertFalse(store.table.markerMovedWhileGateShut)
        XCTAssertNil(defaults.data(forKey: PhiSyncEngine.markerStateKey),
                     "the replay drops the marker the parked round advanced, not the reverse")
    }

    // MARK: - apply (§6.2)

    func testARemoteSpaceIsAdoptedWholesaleWhenThereIsNoBaseline() async throws {
        let access = FakePhiSpaceAccess()
        access.profileIdByUuid = ["uuid-a": "Profile 2"]
        let store = MemorySpaceStore()
        let client = FakePhiSyncClient()
        client.seed(tagHash: spaceHash("u1"),
                    ciphertext: try ciphertext(spaceEntity("u1", name: "Reading")), version: 7)
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertEqual(access.currentSpaces().first?.name, "Reading")
        XCTAssertEqual(access.currentSpaces().first?.profileId, "Profile 2")
        let cursor = try XCTUnwrap(store.table.cursors["u1"])
        XCTAssertEqual(cursor.entityId, client.entityId(forTagHash: spaceHash("u1")))
        XCTAssertEqual(cursor.version, 7)
        XCTAssertNotNil(cursor.reconciled)
        XCTAssertNotNil(cursor.server)
        XCTAssertNil(cursor.pendingApply)
    }

    func testARemoteRebindGoesThroughRebindAndNotARawFieldWrite() async throws {
        let access = FakePhiSpaceAccess()
        access.profileIdByUuid = ["uuid-b": "Profile 3"]
        access.spaces = [PhiLocalSpace(spaceId: "LOCAL-1", profileId: "Default", name: "Work",
                                       colorHex: "#3A6FF8", iconName: "emoji:1F4BC", sortOrder: 0,
                                       createdDate: Date(timeIntervalSince1970: 1),
                                       themeId: nil, opacityLight: nil, opacityDark: nil)]
        let store = MemorySpaceStore()
        store.table = makeSpaceTable(mappings: ["LOCAL-1": "sync-1"], access: access)
        var seeded = PhiSpaceCursor()
        seeded.entityId = "srv-1"; seeded.version = 3
        seeded.reconciled = try spaceEntity("sync-1").serializedData()
        seeded.server = seeded.reconciled
        store.table.cursors["sync-1"] = seeded

        let client = FakePhiSyncClient()
        var rebound = spaceEntity("sync-1", profileUuid: "uuid-b")
        rebound.profileUuid.updatedAtMs = 500
        client.seed(tagHash: spaceHash("sync-1"), ciphertext: try ciphertext(rebound), version: 8)
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()
        XCTAssertTrue(access.calls.contains(.rebind(spaceId: "LOCAL-1", toProfileId: "Profile 3")))
    }

    /// §6.2 A0 / §3.6's sole exception and only dead-mapping repair path. Reverse
    /// lookup succeeds, but its local Chromium Profile was deleted. Otherwise every
    /// application throws for a nonexistent profileId and parks the entity forever.
    func testADeadMappingIsDroppedAndTheProfileIsRebuiltNextRound() async throws {
        let access = FakePhiSpaceAccess()
        access.profileIdByUuid = ["uuid-a": "P-deleted"]   // the mapping is still there
        access.knownLocalProfileIds = []                   // the local profile is not
        let store = MemorySpaceStore()
        let client = FakePhiSyncClient()
        client.seed(tagHash: spaceHash("u1"),
                    ciphertext: try ciphertext(spaceEntity("u1")), version: 7)
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertEqual(access.droppedMappings, ["P-deleted"],
                       "removeMapping(forProfileId:) must fire exactly once")
        // D6: the local row id is minted by `land`, so naming one here would be
        // an assertion that can never fail. Ask for "no create at all" instead.
        XCTAssertTrue(access.calls.filter {
            if case .create = $0 { return true } else { return false }
        }.isEmpty)
        XCTAssertTrue(access.calls.filter {
            if case .rebind = $0 { return true } else { return false }
        }.isEmpty)
        XCTAssertNil(store.table.cursors["u1"]?.reconciled)
        XCTAssertNotNil(store.table.cursors["u1"]?.pendingApply, "parked, not dropped")

        // Next round §3.6 sees the uuid in `missing` again and rebuilds a local
        // profile under its registered name; the parked entity then lands.
        // Driven directly rather than through `access.onRefresh`: nothing in the
        // engine calls `refreshAccountProfiles()` until Task 11 Step 6, so the
        // hook would never fire and this round would simply re-park.
        access.profileIdByUuid["uuid-a"] = "P-rebuilt"
        access.knownLocalProfileIds = ["P-rebuilt"]
        await engine.pullOnce()
        XCTAssertEqual(access.currentSpaces().first?.profileId, "P-rebuilt")
        XCTAssertNil(store.table.cursors["u1"]?.pendingApply)
        XCTAssertEqual(access.droppedMappings, ["P-deleted"], "and only once")
    }

    /// §3.5 fallback A is transient. Once the held uuid resolves -- §3.6 created
    /// the profile -- the row must actually move onto it and the next snapshot
    /// must emit the mapping-derived `profile_uuid`, not the frozen echo.
    func testAHeldBindingLandsAndClearsOnceTheProfileResolves() async throws {
        let access = FakePhiSpaceAccess()
        access.uuidByProfileId = ["Default": "uuid-a"]
        access.profileIdByUuid = ["uuid-a": "Default"]
        access.knownLocalProfileIds = ["Default"]
        access.spaces = [PhiLocalSpace(spaceId: "LOCAL-1", profileId: "Default", name: "Work",
                                       colorHex: "#3A6FF8", iconName: "emoji:1F4BC", sortOrder: 0,
                                       createdDate: Date(timeIntervalSince1970: 1),
                                       themeId: nil, opacityLight: nil, opacityDark: nil)]
        let store = MemorySpaceStore()
        store.table = makeSpaceTable(mappings: ["LOCAL-1": "sync-1"], access: access)
        var seeded = PhiSpaceCursor()
        seeded.entityId = "srv-1"; seeded.version = 3
        seeded.reconciled = try spaceEntity("sync-1").serializedData()
        seeded.server = seeded.reconciled
        store.table.cursors["sync-1"] = seeded

        let client = FakePhiSyncClient()
        var rebound = spaceEntity("sync-1", profileUuid: "uuid-\u{65b0}")
        rebound.profileUuid.updatedAtMs = 500
        client.seed(tagHash: spaceHash("sync-1"), ciphertext: try ciphertext(rebound), version: 8)
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()
        XCTAssertEqual(store.table.cursors["sync-1"]?.heldProfileUuid, "uuid-\u{65b0}")
        XCTAssertEqual(store.table.cursors["sync-1"]?.heldForLocalProfileId, "Default")
        XCTAssertTrue(spaceCommits(client).isEmpty, "a held binding never produces a commit")

        // §3.6 creates the profile on the next round. Driven directly here for
        // the same reason as the dead-mapping case above.
        access.profileIdByUuid["uuid-\u{65b0}"] = "P-new"
        access.uuidByProfileId["P-new"] = "uuid-\u{65b0}"
        access.knownLocalProfileIds = ["Default", "P-new"]
        await engine.pullOnce()
        XCTAssertTrue(access.calls.contains(.rebind(spaceId: "LOCAL-1", toProfileId: "P-new")))
        XCTAssertNil(store.table.cursors["sync-1"]?.heldProfileUuid)
        XCTAssertNil(store.table.cursors["sync-1"]?.heldForLocalProfileId)
        XCTAssertTrue(spaceCommits(client).isEmpty,
                      "landing the held value is convergence, not a new local edit")
    }

    /// The held re-park is the one path that feeds the apply loop an entity the
    /// server never sent — the device's own baseline. Recording THAT as `server`
    /// makes `spaceCommitEntries`' `toSend == server` true for every field this
    /// device still owes the account, and the owed value is never published
    /// again. Same invariant as `testAMergedLocalEditIsStillPublishedNextRound`,
    /// re-entered through the re-park.
    func testAReParkedHeldBaselineDoesNotOverwriteWhatTheServerHolds() async throws {
        let access = FakePhiSpaceAccess()
        access.uuidByProfileId = ["Default": "uuid-a", "P-new": "uuid-\u{65b0}"]
        access.profileIdByUuid = ["uuid-a": "Default", "uuid-\u{65b0}": "P-new"]
        access.knownLocalProfileIds = ["Default", "P-new"]
        access.spaces = [PhiLocalSpace(spaceId: "LOCAL-1", profileId: "Default", name: "Work2",
                                       colorHex: "#3A6FF8", iconName: "emoji:1F4BC", sortOrder: 0,
                                       createdDate: Date(timeIntervalSince1970: 1),
                                       themeId: nil, opacityLight: nil, opacityDark: nil)]
        let store = MemorySpaceStore()
        store.table = makeSpaceTable(mappings: ["LOCAL-1": "sync-1"], access: access)
        // The state an earlier round left behind, seeded rather than driven: this
        // device holds the account's rename and has not published it (any round
        // that does not publish -- offline, a commit throw -- ends exactly here),
        // and a peer that never saw the rename rebound the Space onto a profile
        // this Mac did not have at the time. §3.6 has since created it, which is
        // what makes THIS round re-park the held baseline.
        //
        // Nothing is seeded on the wire on purpose: the re-park must be the only
        // entity the apply loop sees this round, or an arrival for the same uuid
        // would write `server` itself and mask the bug under test.
        var baseline = spaceEntity("sync-1", name: "Work2", profileUuid: "uuid-\u{65b0}")
        baseline.name.updatedAtMs = 800
        baseline.profileUuid.updatedAtMs = 900
        var rebound = spaceEntity("sync-1", name: "Work", profileUuid: "uuid-\u{65b0}")
        rebound.profileUuid.updatedAtMs = 900
        var seeded = PhiSpaceCursor()
        seeded.entityId = "srv-1"; seeded.version = 9
        seeded.reconciled = try baseline.serializedData()
        seeded.server = try rebound.serializedData()
        seeded.heldProfileUuid = "uuid-\u{65b0}"
        seeded.heldForLocalProfileId = "Default"
        store.table.cursors["sync-1"] = seeded

        let client = FakePhiSyncClient()
        // The account moved on between this round's pull and its push, so the one
        // commit is answered CONFLICT and the store is left untouched. That keeps
        // `server` readable below as whatever the RE-PARK left there -- an
        // accepted commit would overwrite it with what it just published and say
        // nothing about the re-park.
        client.conflictOnceForTagHashes = [spaceHash("sync-1")]
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertTrue(access.calls.contains(.rebind(spaceId: "LOCAL-1", toProfileId: "P-new")))
        XCTAssertNil(store.table.cursors["sync-1"]?.heldProfileUuid, "the hold resolved")
        XCTAssertEqual(store.table.cursors["sync-1"]?.server,
                       try rebound.serializedData(),
                       "re-landing the local baseline says nothing about what the server holds")
        let commits = spaceCommits(client)
        XCTAssertEqual(commits.count, 1, "the rename this device still owes the account goes out")
        let sent = try Phi_PhiSpaceEntity(serializedBytes:
            try PhiEntityCodec.decrypt(commits[0].ciphertext!, key: key).space.serializedData())
        XCTAssertEqual(sent.name.stringValue, "Work2")
        XCTAssertEqual(sent.profileUuid.stringValue, "uuid-\u{65b0}")
    }

    /// §5.6's invariant, and the reason every write in `PhiSpaceLocalAccess` throws.
    func testAFailedLandingWritesNoBaselineAndParksTheEntity() async throws {
        struct Boom: Error {}
        let access = FakePhiSpaceAccess()
        access.profileIdByUuid = ["uuid-a": "Default"]
        access.errorOnNextWrite = Boom()
        let store = MemorySpaceStore()
        let client = FakePhiSyncClient()
        client.seed(tagHash: spaceHash("u1"),
                    ciphertext: try ciphertext(spaceEntity("u1")), version: 7)
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let cursor = try XCTUnwrap(store.table.cursors["u1"])
        XCTAssertNil(cursor.reconciled)
        XCTAssertNil(cursor.server)
        XCTAssertNotNil(cursor.pendingApply, "the entity is retried next round, never dropped")

        await engine.pullOnce()      // the armed error is one-shot
        XCTAssertNil(store.table.cursors["u1"]!.pendingApply)
        XCTAssertNotNil(store.table.cursors["u1"]!.reconciled)
    }

    /// Pins `server = remote`, not `merged`: recording the merge result as "what
    /// the server holds" makes a local edit that survived the merge equal to both
    /// baselines at once, and it is never published again.
    ///
    /// Two things this fixture has to spell out that the plan's sketch did not,
    /// both forced by the code as it stands. (1) The surviving edit must be in
    /// the BASELINE with a newer timestamp than the remote's: `land` rewrites the
    /// row from `merged`, so an unstamped local rename is overwritten before any
    /// snapshot can see it, and there would be nothing left to publish. (2) The
    /// profile the rebind moves the row onto needs a mapping of its own, or
    /// `SyncableSpaces.snapshot` skips the whole Space rather than putting a
    /// device-local Chromium basename on the wire — and then no commit happens
    /// for either choice of baseline, so the test could not discriminate.
    func testAMergedLocalEditIsStillPublishedNextRound() async throws {
        let access = FakePhiSpaceAccess()
        access.uuidByProfileId = ["Default": "uuid-a", "Profile 3": "uuid-b"]
        access.profileIdByUuid = ["uuid-a": "Default", "uuid-b": "Profile 3"]
        access.spaces = [PhiLocalSpace(spaceId: "LOCAL-1", profileId: "Default", name: "Work2",
                                       colorHex: "#3A6FF8", iconName: "emoji:1F4BC", sortOrder: 0,
                                       createdDate: Date(timeIntervalSince1970: 1),
                                       themeId: nil, opacityLight: nil, opacityDark: nil)]
        let store = MemorySpaceStore()
        store.table = makeSpaceTable(mappings: ["LOCAL-1": "sync-1"], access: access)
        // This account renamed the Space to "Work2" and this device has the
        // rename in its baseline; the row on the server is still the older one.
        var baseline = spaceEntity("sync-1", name: "Work2")
        baseline.name.updatedAtMs = 800
        var seeded = PhiSpaceCursor()
        seeded.entityId = "srv-1"; seeded.version = 3
        seeded.reconciled = try baseline.serializedData()
        seeded.server = try spaceEntity("sync-1", name: "Work").serializedData()
        store.table.cursors["sync-1"] = seeded

        let client = FakePhiSyncClient()
        // A peer that has not seen the rename rebinds the Space: its own `name`
        // is still "Work" at the older timestamp, so the merge keeps "Work2".
        var rebound = spaceEntity("sync-1", name: "Work", profileUuid: "uuid-b")
        rebound.profileUuid.updatedAtMs = 900
        client.seed(tagHash: spaceHash("sync-1"), ciphertext: try ciphertext(rebound), version: 9)
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let commits = spaceCommits(client)
        XCTAssertEqual(commits.count, 1)
        let commit = try XCTUnwrap(commits.first)
        let sent = try Phi_PhiSpaceEntity(serializedBytes:
            try PhiEntityCodec.decrypt(XCTUnwrap(commit.ciphertext), key: key).space.serializedData())
        XCTAssertEqual(store.table.cursors["sync-1"]?.server, try sent.serializedData(),
                       "After an accepted commit, the server baseline tracks the acknowledged payload")
        XCTAssertEqual(sent.name.stringValue, "Work2")
        XCTAssertEqual(sent.profileUuid.stringValue, "uuid-b")
        XCTAssertEqual(commits[0].baseVersion, 9)
    }

    /// §5.2 change 3 covers the direction formerly swallowed by settings: Space
    /// publication proceeds even when the account settings entity is unreadable.
    /// maySettingsPublish=false and pushSettings early returns concern one settings
    /// row, not Spaces.
    func testAnUnreadableSettingsEntityDoesNotStopSpaceCommits() async throws {
        let access = FakePhiSpaceAccess()
        access.uuidByProfileId = ["Default": "uuid-a"]
        access.spaces = [PhiLocalSpace(spaceId: "LOCAL-1", profileId: "Default", name: "Work",
                                       colorHex: "#3A6FF8", iconName: "emoji:1F4BC", sortOrder: 0,
                                       createdDate: Date(timeIntervalSince1970: 1),
                                       themeId: nil, opacityLight: nil, opacityDark: nil)]
        let store = MemorySpaceStore()
        store.table = makeSpaceTable(mappings: ["LOCAL-1": "sync-1"], access: access)
        let client = FakePhiSyncClient()
        // A settings entity this build cannot open: the pull records the id but
        // no baseline, so `maySettingsPublish` goes false and `pushSettings`
        // bails at its "no readable baseline" guard before it reaches a commit.
        client.seed(tagHash: PhiSyncEntity.settingsClientTagHash,
                    ciphertext: Data([0xDE, 0xAD]), version: 3)
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertTrue(client.commits.allSatisfy {
            $0.clientTagHash != PhiSyncEntity.settingsClientTagHash
        }, "the unreadable settings row must not be overwritten")
        XCTAssertEqual(spaceCommits(client).count, 1,
                       "the Space section publishes regardless of the settings half")
    }

    /// The steady state, and the reason `pushSpaces` cannot hang off the end of
    /// `pushSettings`: on almost every round the settings entity is unchanged and
    /// that half returns at `if let last, outgoing == last` long before its last
    /// statement.
    func testARoundWithNoSettingsChangeStillCommitsARenamedSpace() async throws {
        let access = FakePhiSpaceAccess()
        access.uuidByProfileId = ["Default": "uuid-a"]
        access.spaces = [PhiLocalSpace(spaceId: "LOCAL-1", profileId: "Default", name: "Work",
                                       colorHex: "#3A6FF8", iconName: "emoji:1F4BC", sortOrder: 0,
                                       createdDate: Date(timeIntervalSince1970: 1),
                                       themeId: nil, opacityLight: nil, opacityDark: nil)]
        let store = MemorySpaceStore()
        store.table = makeSpaceTable(mappings: ["LOCAL-1": "sync-1"], access: access)
        let client = FakePhiSyncClient()
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pushLocalSettings()          // round 1: settings entity created
        let settingsCommits = client.commits.count - spaceCommits(client).count
        XCTAssertGreaterThan(settingsCommits, 0)

        // Round 2: the user renames the Space; the settings entity is untouched.
        access.spaces[0].name = "Work2"
        let before = spaceCommits(client).count
        await engine.handleLocalSpacesChange()
        XCTAssertEqual(spaceCommits(client).count, before + 1)
        XCTAssertEqual(client.commits.count - spaceCommits(client).count, settingsCommits,
                       "the settings half correctly published nothing this round")
    }

    // MARK: - Edit-time stamping (C2-a / design option S2)

    /// One local Space, already published, with the account's own values on both sides: the
    /// cursor's baselines and the server row the commit path has to match on id and version.
    private func offlineEditFixture() throws
        -> (FakePhiSpaceAccess, MemorySpaceStore, FakePhiSyncClient) {
        let access = FakePhiSpaceAccess()
        access.uuidByProfileId = ["Default": "uuid-a"]
        access.profileIdByUuid = ["uuid-a": "Default"]
        access.spaces = [PhiLocalSpace(spaceId: "LOCAL-1", profileId: "Default", name: "Work",
                                       colorHex: "#3A6FF8", iconName: "emoji:1F4BC", sortOrder: 0,
                                       createdDate: Date(timeIntervalSince1970: 1),
                                       themeId: nil, opacityLight: nil, opacityDark: nil)]
        let store = MemorySpaceStore()
        store.table = makeSpaceTable(mappings: ["LOCAL-1": "sync-1"], access: access)
        let published = try spaceEntity("sync-1", name: "Work")
        var seeded = PhiSpaceCursor()
        seeded.entityId = "srv-1"
        seeded.version = 3
        seeded.reconciled = try published.serializedData()
        seeded.server = seeded.reconciled
        store.table.cursors["sync-1"] = seeded
        let client = FakePhiSyncClient()
        client.seed(tagHash: spaceHash("sync-1"), ciphertext: try ciphertext(published),
                    version: 3, entityId: "srv-1")
        return (access, store, client)
    }

    private func sentSpaceEntity(_ commit: FakePhiSyncClient.CommitCall) throws
        -> Phi_PhiSpaceEntity {
        try Phi_PhiSpaceEntity(serializedBytes:
            try PhiEntityCodec.decrypt(XCTUnwrap(commit.ciphertext), key: key).space.serializedData())
    }

    /// The headline regression C2-a exists for. The publish pass runs only after a successful
    /// pull, so a Space renamed on a plane used to leave carrying the RECONNECT time and beat a
    /// peer's genuinely later edit. The stamping pass runs ahead of that gate, so the rename
    /// leaves with its own time however long the machine stays offline.
    func testASpaceRenamedOfflineIsPublishedWithItsRenameTime() async throws {
        let (access, store, client) = try offlineEditFixture()
        let clock = Clock()
        let engine = makeEngine(access: access, store: store, client: client, clock: clock)
        await engine.setSpaceSyncEnabled(true)

        // Offline: the pull throws, so `canPublishThisRound` never opens.
        let renameMs = clock.nowMs
        access.spaces[0].name = "Travel"
        client.getUpdatesErrorOnce = URLError(.notConnectedToInternet)
        await engine.handleLocalSpacesChange()
        XCTAssertTrue(spaceCommits(client).isEmpty, "an offline round publishes nothing")
        let pendingBytes = try XCTUnwrap(store.table.cursors["sync-1"]?.pendingProjection,
                                         "the stamping pass runs behind a shut pull gate")
        let pending = try Phi_PhiSpaceEntity(serializedBytes: pendingBytes)
        XCTAssertEqual(pending.name.stringValue, "Travel")
        XCTAssertEqual(pending.name.updatedAtMs, renameMs)

        // An hour later the machine reconnects and the round finally publishes.
        clock.nowMs = renameMs + 3_600_000
        await engine.pullOnce()
        let commits = spaceCommits(client)
        XCTAssertEqual(commits.count, 1)
        let sent = try sentSpaceEntity(XCTUnwrap(commits.first))
        XCTAssertEqual(sent.name.stringValue, "Travel")
        XCTAssertEqual(sent.name.updatedAtMs, renameMs,
                       "the rename must carry its own time, not the reconnect's")
        XCTAssertNil(store.table.cursors["sync-1"]?.pendingProjection,
                     "an accepted commit spends the pending projection")
        XCTAssertEqual(store.table.cursors["sync-1"]?.reconciled, try sent.serializedData())
    }

    /// R-exec-14 under S2: the merge's local side is this round's local projection, and that
    /// projection now carries the edit-time stamps. Stamping it at the landing round's clock
    /// instead would make the offline rename win a field it should lose, and re-stamping it
    /// after the merge would publish an edit that never happened.
    func testALandingMergesAgainstThePendingProjectionAndThenSpendsIt() async throws {
        let (access, store, client) = try offlineEditFixture()
        let clock = Clock()
        let engine = makeEngine(access: access, store: store, client: client, clock: clock)
        await engine.setSpaceSyncEnabled(true)

        let renameMs = clock.nowMs
        access.spaces[0].name = "Travel"
        client.getUpdatesErrorOnce = URLError(.notConnectedToInternet)
        await engine.handleLocalSpacesChange()
        XCTAssertNotNil(store.table.cursors["sync-1"]?.pendingProjection)

        // A peer recoloured the same Space while this one was away, and left the name alone.
        // `reseed`, so the row keeps the id the cursor already points at.
        var fromPeer = spaceEntity("sync-1", name: "Work")
        fromPeer.colorHex.stringValue = "#FF00FF"
        fromPeer.colorHex.updatedAtMs = renameMs + 1_000
        client.reseed(tagHash: spaceHash("sync-1"), ciphertext: try ciphertext(fromPeer), version: 9)

        clock.nowMs = renameMs + 3_600_000
        await engine.pullOnce()

        // The peer's colour landed on the row; the local rename survived the merge.
        XCTAssertTrue(access.calls.contains(.update("LOCAL-1")))
        let reconciled = try Phi_PhiSpaceEntity(
            serializedBytes: XCTUnwrap(store.table.cursors["sync-1"]?.reconciled))
        XCTAssertEqual(reconciled.name.stringValue, "Travel")
        XCTAssertEqual(reconciled.name.updatedAtMs, renameMs)
        XCTAssertEqual(reconciled.colorHex.stringValue, "#FF00FF")
        XCTAssertNil(store.table.cursors["sync-1"]?.pendingProjection,
                     "the merged baseline already carries both sides' stamps")

        let sent = try sentSpaceEntity(XCTUnwrap(spaceCommits(client).first))
        XCTAssertEqual(sent.name.updatedAtMs, renameMs,
                       "the republish must not restamp the rename at the landing round's clock")
        XCTAssertEqual(sent.colorHex.updatedAtMs, fromPeer.colorHex.updatedAtMs,
                       "the field the remote won is no longer a local edit")
    }

    /// A field put back before it was ever published is not an edit at all: the projection
    /// collapses onto `reconciled`, the pending copy is dropped and nothing goes on the wire.
    func testAnEditRevertedBeforePublishingDropsThePendingProjectionAndCommitsNothing() async throws {
        let (access, store, client) = try offlineEditFixture()
        let clock = Clock()
        let engine = makeEngine(access: access, store: store, client: client, clock: clock)
        await engine.setSpaceSyncEnabled(true)

        access.spaces[0].name = "Travel"
        client.getUpdatesErrorOnce = URLError(.notConnectedToInternet)
        await engine.handleLocalSpacesChange()
        XCTAssertNotNil(store.table.cursors["sync-1"]?.pendingProjection)

        access.spaces[0].name = "Work"
        clock.nowMs += 60_000
        client.getUpdatesErrorOnce = URLError(.notConnectedToInternet)
        await engine.handleLocalSpacesChange()
        XCTAssertNil(store.table.cursors["sync-1"]?.pendingProjection)

        clock.nowMs += 60_000
        await engine.pullOnce()
        XCTAssertTrue(spaceCommits(client).isEmpty, "a revert publishes no phantom edit")
    }

    /// The gate the stamping pass DOES honour. A shut Space section means this device is not
    /// taking part in Space sync, and `previewAccountSpaces` is the only Space-shaped work
    /// allowed behind it precisely because it writes nothing.
    func testTheStampingPassIsHeldByAShutSpaceGate() async throws {
        let (access, store, client) = try offlineEditFixture()
        let engine = makeEngine(access: access, store: store, client: client)
        // Deliberately no `setSpaceSyncEnabled(true)`.
        access.spaces[0].name = "Travel"
        await engine.handleLocalSpacesChange()
        XCTAssertNil(store.table.cursors["sync-1"]?.pendingProjection)
    }

    /// A stamping pass whose table write fails must lose nothing that is not derivable -- the
    /// edit is still on the row and the next pass re-projects it -- and it must not publish:
    /// `pull` refuses `canPublishThisRound` for any round that counted a cursor save failure.
    func testAFailedStampingWriteNeitherLosesTheEditNorPublishes() async throws {
        let (access, store, client) = try offlineEditFixture()
        let clock = Clock()
        let engine = makeEngine(access: access, store: store, client: client, clock: clock)
        await engine.setSpaceSyncEnabled(true)

        access.spaces[0].name = "Travel"
        store.failNextSave = true
        await engine.handleLocalSpacesChange()
        XCTAssertNil(store.table.cursors["sync-1"]?.pendingProjection)
        XCTAssertTrue(spaceCommits(client).isEmpty,
                      "a round with a cursor save failure publishes nothing")

        store.failNextSave = false
        let retryMs = clock.nowMs + 60_000
        clock.nowMs = retryMs
        await engine.handleLocalSpacesChange()
        let sent = try sentSpaceEntity(XCTUnwrap(spaceCommits(client).first))
        XCTAssertEqual(sent.name.stringValue, "Travel")
        XCTAssertEqual(sent.name.updatedAtMs, retryMs, "re-derived from the row, at the retry's time")
    }

    // MARK: - Guard 3 (§5.5)

    func testNothingIsCommittedForATagThisDeviceCannotRead() async throws {
        let access = FakePhiSpaceAccess()
        access.uuidByProfileId = ["Default": "uuid-a"]
        access.spaces = [
            PhiLocalSpace(spaceId: LocalStore.defaultSpaceId, profileId: "Default", name: "Default",
                          colorHex: "#3A6FF8", iconName: "phi:x", sortOrder: 0,
                          createdDate: Date(timeIntervalSince1970: 1),
                          themeId: nil, opacityLight: nil, opacityDark: nil),
            PhiLocalSpace(spaceId: "LOCAL-2", profileId: "Default", name: "Reading",
                          colorHex: "#111111", iconName: "phi:y", sortOrder: 1,
                          createdDate: Date(timeIntervalSince1970: 2),
                          themeId: nil, opacityLight: nil, opacityDark: nil),
        ]
        // Not `makeSpaceTable`: the drain assertion below is only worth
        // anything while `hasDrainedFullReplay` starts false.
        access.spaceMappings = ["LOCAL-2": "sync-2"]
        let store = MemorySpaceStore()
        let client = FakePhiSyncClient()
        let defaultHash = spaceHash(LocalStore.defaultSpaceId)
        client.seed(tagHash: defaultHash, ciphertext: Data([0xDE, 0xAD]), version: 4)
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertTrue(store.table.hasDrainedFullReplay, "an undecryptable entity does not stop the drain")
        let hashes = Set(spaceCommits(client).map(\.clientTagHash))
        XCTAssertFalse(hashes.contains(defaultHash),
                       "a version-0 create here takes the server's ON CONFLICT DO UPDATE path and destroys the account's row")
        XCTAssertTrue(hashes.contains(spaceHash("sync-2")), "the readable Spaces still sync")

        // Once the entity becomes readable again the refusal lifts by itself.
        client.reseed(tagHash: defaultHash,
                      ciphertext: try ciphertext(spaceEntity(LocalStore.defaultSpaceId)), version: 5)
        await engine.pullOnce()
        XCTAssertTrue(store.table.unreadableTagHashes.isEmpty)
    }

    // MARK: - Tombstones (§5.1 / §9.1)

    func testALocalDeleteEmitsOneTombstoneAndFinalizesOnSuccess() async throws {
        let access = FakePhiSpaceAccess()
        access.profileIdByUuid = ["uuid-a": "Default"]
        let store = MemorySpaceStore()
        store.table = makeSpaceTable(access: access)
        var cursor = PhiSpaceCursor()
        cursor.entityId = "srv-1"; cursor.version = 6
        cursor.reconciled = try spaceEntity("sync-1").serializedData()
        cursor.server = cursor.reconciled
        cursor.pendingDelete = true
        store.table.cursors["sync-1"] = cursor
        let client = FakePhiSyncClient()
        // The remote row is still live. Preflight must retain the pending local deletion,
        // rather than recreate the missing local Space from this incoming entity.
        client.seed(tagHash: spaceHash("sync-1"), ciphertext: try ciphertext(spaceEntity("sync-1")),
                    version: 6, entityId: "srv-1")
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pushLocalSettings()

        let commits = spaceCommits(client)
        XCTAssertEqual(commits.count, 1)
        let commit = try XCTUnwrap(commits.first)
        XCTAssertTrue(commit.deleted)
        XCTAssertNil(commit.ciphertext)
        XCTAssertEqual(commit.name, PhiSyncEntity.spaceEntityName)
        XCTAssertTrue(access.spaces.isEmpty, "Preflight must not recreate a locally deleted Space")
        let after = try XCTUnwrap(store.table.cursors["sync-1"])
        XCTAssertFalse(after.pendingDelete)
        XCTAssertNotNil(after.deletedAtMs)
        XCTAssertNil(after.reconciled)
        XCTAssertNil(after.server)
        XCTAssertNotNil(after.entityId, "the cursor stays as a permanent tombstone record")
    }

    func testARejectedTombstoneIsResentUnchangedAndOnlyGivesUpAfterThree() async throws {
        let access = FakePhiSpaceAccess()
        let store = MemorySpaceStore()
        store.table = makeSpaceTable(access: access)
        var cursor = PhiSpaceCursor()
        cursor.entityId = "srv-1"; cursor.version = 6
        cursor.reconciled = try spaceEntity("sync-1").serializedData()
        cursor.server = cursor.reconciled
        cursor.pendingDelete = true
        store.table.cursors["sync-1"] = cursor
        let client = FakePhiSyncClient()
        client.seed(tagHash: spaceHash("sync-1"), ciphertext: try ciphertext(spaceEntity("sync-1")),
                    version: 6, entityId: "srv-1")
        client.forceInvalidMessage = true
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)

        await engine.pushLocalSettings()
        var after = try XCTUnwrap(store.table.cursors["sync-1"])
        XCTAssertTrue(after.pendingDelete, "INVALID_MESSAGE does not prove the row is gone")
        XCTAssertEqual(after.deleteRejectRounds, 1)
        XCTAssertNil(after.deletedAtMs)
        XCTAssertEqual(after.entityId, "srv-1")

        client.forceInvalidMessage = false
        await engine.pushLocalSettings()
        after = try XCTUnwrap(store.table.cursors["sync-1"])
        XCTAssertFalse(after.pendingDelete)
        XCTAssertEqual(after.deleteRejectRounds, 0)
        XCTAssertNotNil(after.deletedAtMs)
        let commits = spaceCommits(client)
        XCTAssertEqual(commits.count, 2)
        XCTAssertEqual(commits[0].baseVersion, commits[1].baseVersion)
    }

    func testThreeRejectionsFinalizeTheDeleteAndStopResending() async throws {
        let access = FakePhiSpaceAccess()
        let store = MemorySpaceStore()
        store.table = makeSpaceTable(access: access)
        var cursor = PhiSpaceCursor()
        cursor.entityId = "srv-1"; cursor.version = 6
        cursor.pendingDelete = true
        store.table.cursors["sync-1"] = cursor
        let client = FakePhiSyncClient()
        client.forceInvalidMessage = true
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        for _ in 0..<3 { await engine.pushLocalSettings() }
        XCTAssertFalse(store.table.cursors["sync-1"]!.pendingDelete)
        XCTAssertNotNil(store.table.cursors["sync-1"]!.deletedAtMs)
        let sent = spaceCommits(client).count
        await engine.pushLocalSettings()
        XCTAssertEqual(spaceCommits(client).count, sent, "no per-round resend loop")
    }

    func testAPendingDeleteWithNoEntityIdIsDroppedBeforeItIsSent() async throws {
        let access = FakePhiSpaceAccess()
        let store = MemorySpaceStore()
        store.table = makeSpaceTable(access: access)
        var cursor = PhiSpaceCursor()
        cursor.pendingDelete = true      // never published: no entityId, version 0
        store.table.cursors["ghost"] = cursor
        let client = FakePhiSyncClient()
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pushLocalSettings()
        XCTAssertTrue(spaceCommits(client).isEmpty)
        XCTAssertFalse(store.table.cursors["ghost"]!.pendingDelete)
        XCTAssertNotNil(store.table.cursors["ghost"]!.deletedAtMs)
    }

    // MARK: - Per-entity conflict retry (§5.1)

    func testOneConflictDoesNotAbandonTheRestOfTheBatch() async throws {
        let access = FakePhiSpaceAccess()
        access.uuidByProfileId = ["Default": "uuid-a"]
        access.spaces = (1...3).map { i in
            PhiLocalSpace(spaceId: "LOCAL-\(i)", profileId: "Default", name: "S\(i)",
                          colorHex: "#3A6FF8", iconName: "phi:x", sortOrder: i,
                          createdDate: Date(timeIntervalSince1970: TimeInterval(i)),
                          themeId: nil, opacityLight: nil, opacityDark: nil)
        }
        let store = MemorySpaceStore()
        store.table = makeSpaceTable(mappings: ["LOCAL-1": "sync-1", "LOCAL-2": "sync-2",
                                                "LOCAL-3": "sync-3"], access: access)
        let client = FakePhiSyncClient()
        client.conflictOnceForTagHashes = [spaceHash("sync-2")]
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pushLocalSettings()

        XCTAssertNotNil(store.table.cursors["sync-1"]?.server)
        XCTAssertNotNil(store.table.cursors["sync-3"]?.server)
        XCTAssertNotNil(store.table.cursors["sync-2"]?.server, "the conflicting one is retried, not dropped")
        XCTAssertEqual(engine.statusSnapshot.phase, .upToDate,
                       "A conflict recovered in this round is not a remaining failure")
        XCTAssertNotNil(engine.statusSnapshot.lastSuccess)
        // The retry is SCOPED: only the conflicting uuid goes back through the
        // wire, not the whole batch recomputed from scratch.
        XCTAssertEqual(spaceCommits(client).filter { $0.clientTagHash == spaceHash("sync-2") }.count, 2)
        for uuid in ["sync-1", "sync-3"] {
            XCTAssertEqual(spaceCommits(client).filter { $0.clientTagHash == spaceHash(uuid) }.count, 1,
                           "\(uuid) already succeeded and must not be re-sent")
        }
    }

    // MARK: - Echo suppression (§6.6)

    func testASnapshotTakenRightAfterApplyStampsNothingAndCommitsNothing() async throws {
        let access = FakePhiSpaceAccess()
        access.uuidByProfileId = ["Default": "uuid-a"]
        access.profileIdByUuid = ["uuid-a": "Default"]
        let store = MemorySpaceStore()
        // Without the decision `pushSpaces` returns at §8's guard and both sides
        // of the comparison below are 0 whatever the apply path wrote — the test
        // would pass over re-stamped fields, wrong baselines and a push on every
        // round alike.
        store.table = makeSpaceTable(access: access)
        let client = FakePhiSyncClient()
        client.seed(tagHash: spaceHash("sync-1"),
                    ciphertext: try ciphertext(spaceEntity("sync-1")), version: 7)
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()
        let commitsAfterApply = spaceCommits(client).count
        XCTAssertEqual(commitsAfterApply, 0, "a pure remote apply publishes nothing")
        await engine.handleLocalSpacesChange()
        XCTAssertEqual(spaceCommits(client).count, commitsAfterApply)
    }

    /// The coordinator's second trigger (§5.4) is a DEBOUNCED subscription to the local
    /// Space rows, and a remote apply writes those rows — so the trigger sees its own echo
    /// and fires `handleLocalSpacesChange()` behind every apply. `isApplyingRemote` is not
    /// set around the Space landing (it guards the settings path), so nothing stops that
    /// round from running: what stops the loop is that the round is a pure reader.
    ///
    /// This is the pin for that: after an apply, the local-change round must publish nothing
    /// AND write nothing locally. One local write here would emit a new value from
    /// `spacesPublisher()`, which would schedule another round, which would write again.
    func testALocalSpaceChangeRoundBehindAnApplyWritesNothingLocallyAndCannotStorm() async throws {
        let access = FakePhiSpaceAccess()
        access.uuidByProfileId = ["Default": "uuid-a"]
        access.profileIdByUuid = ["uuid-a": "Default"]
        let store = MemorySpaceStore()
        store.table = makeSpaceTable(access: access)
        let client = FakePhiSyncClient()
        client.seed(tagHash: spaceHash("sync-1"),
                    ciphertext: try ciphertext(spaceEntity("sync-1")), version: 7)
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()
        // D6: the created row's id is minted by `land`, so the assertion asks for
        // "a create happened", not for a particular id.
        XCTAssertTrue(access.calls.contains { if case .create = $0 { return true } else { return false } },
                      "the apply is what arms the echo")

        let callsAfterApply = access.calls.count
        // Twice: the debounce coalesces a burst into one round, but a second burst (a theme
        // notification arriving just after) must be just as inert as the first.
        await engine.handleLocalSpacesChange()
        await engine.handleLocalSpacesChange()

        let sinceApply = access.calls.suffix(from: callsAfterApply)
        XCTAssertTrue(sinceApply.allSatisfy { $0 == .refreshProfiles },
                      "a local-change round may re-list profiles; it may not touch a Space row")
        XCTAssertTrue(spaceCommits(client).isEmpty,
                      "the baselines the apply wrote are what suppress the echo")
    }

    // MARK: - Retirement (§3.3 step 2.0)

    func testAnInFlightRoundWritesNothingAfterShutdown() async throws {
        let access = FakePhiSpaceAccess()
        let store = MemorySpaceStore()
        let client = FakePhiSyncClient()
        let gate = Gate()
        client.getUpdatesGate = gate
        client.seed(tagHash: spaceHash("u1"),
                    ciphertext: try ciphertext(spaceEntity("u1")), version: 7)
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)

        let round = Task { await engine.pullOnce() }
        try await Task.sleep(nanoseconds: 50_000_000)
        engine.shutdown()
        store.table = PhiSpaceSyncTable()
        for key in PhiSyncEngine.stateKeys { defaults.removeObject(forKey: key) }
        await gate.open()
        await round.value

        XCTAssertEqual(store.table, PhiSpaceSyncTable())
        XCTAssertTrue(access.calls.filter { $0 != .refreshProfiles }.isEmpty)
        XCTAssertTrue(client.commits.isEmpty)
        XCTAssertTrue(PhiSyncEngine.stateKeys.allSatisfy { defaults.object(forKey: $0) == nil })
    }

    // MARK: - Per-round profile refresh (§3.6)

    func testTheProfileRefreshRunsOncePerPullRoundEvenWithNoSpaceEntities() async throws {
        let access = FakePhiSpaceAccess()
        let store = MemorySpaceStore()
        let client = FakePhiSyncClient()
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()
        XCTAssertEqual(access.calls.filter { $0 == .refreshProfiles }.count, 1,
                       "waiting for a Space to arrive would hide a peer's new empty Profile forever")
    }

    func testAGatedOffEngineNeverRefreshesTheProfileList() async throws {
        let access = FakePhiSpaceAccess()
        let store = MemorySpaceStore()
        let client = FakePhiSyncClient()
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.pullOnce()
        XCTAssertEqual(access.calls.filter { $0 == .refreshProfiles }.count, 0)
    }

    func testTheMinimumIntervalSuppressesASecondRefreshButNotOneAfterAFailure() async throws {
        let access = FakePhiSpaceAccess()
        let store = MemorySpaceStore()
        let client = FakePhiSyncClient()
        // The interval is measured on the engine's own clock, so the test drives
        // it explicitly rather than trying to outrun a 30 s wall-clock window.
        let clock = Clock()
        let engine = makeEngine(access: access, store: store, client: client, clock: clock)
        func refreshes() -> Int { access.calls.filter { $0 == .refreshProfiles }.count }

        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()
        XCTAssertEqual(refreshes(), 1)
        await engine.pullOnce()          // same instant: inside the 30 s window
        XCTAssertEqual(refreshes(), 1, "the minimum interval suppresses the second round")

        clock.nowMs += 31_000
        access.refreshOutcome = .failed
        await engine.pullOnce()
        XCTAssertEqual(refreshes(), 2)
        // A failure must NOT arm the interval, or "retry next round" is a lie:
        // the very next round refreshes again although no time has passed.
        await engine.pullOnce()
        XCTAssertEqual(refreshes(), 3)
    }

    func testAnUnknownBindingLandsInTheSameRoundOnceTheRefreshResolvesIt() async throws {
        let access = FakePhiSpaceAccess()
        let store = MemorySpaceStore()
        let client = FakePhiSyncClient()
        // The refresh is what creates the local profile the binding needs.
        access.refreshOutcome = .changed
        access.onRefresh = { access.profileIdByUuid["uuid-a"] = "P-new" }
        client.seed(tagHash: PhiSyncEntity.clientTagHash(for: PhiSyncEntity.spaceClientTag("u1")),
                    ciphertext: try ciphertext(spaceEntity("u1")), version: 7)
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()
        XCTAssertEqual(access.currentSpaces().first?.profileId, "P-new")
        XCTAssertNil(store.table.cursors["u1"]?.pendingApply)
    }

    func testAFailedRefreshParksTheUnknownBindingAndLandsItNextRound() async throws {
        let access = FakePhiSpaceAccess()
        let store = MemorySpaceStore()
        // otherwise the push guard hides the point
        store.table = makeSpaceTable(access: access)
        let client = FakePhiSyncClient()
        access.refreshOutcome = .failed
        client.seed(tagHash: PhiSyncEntity.clientTagHash(for: PhiSyncEntity.spaceClientTag("u1")),
                    ciphertext: try ciphertext(spaceEntity("u1")), version: 7)
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()
        XCTAssertTrue(access.calls.filter {
            if case .create = $0 { return true } else { return false }
        }.isEmpty)
        XCTAssertNil(store.table.cursors["u1"]?.reconciled)
        XCTAssertNotNil(store.table.cursors["u1"]?.pendingApply)
        XCTAssertTrue(spaceCommits(client).isEmpty,
                      "standing in a local Default profile here would stamp `now` and win the account's LWW")

        access.refreshOutcome = .changed
        access.onRefresh = { access.profileIdByUuid["uuid-a"] = "P-new" }
        await engine.pullOnce()
        XCTAssertEqual(access.currentSpaces().first?.profileId, "P-new")
        XCTAssertNil(store.table.cursors["u1"]?.pendingApply)
    }

    /// D6 opened a hole that §5.6 had closed on the APPLY side only: a mapping
    /// can now exist before the account's entity for that uuid has ever landed,
    /// so a parked uuid can reach `SyncableSpaces.snapshot` — which iterates
    /// LOCAL rows — with no baseline at all.
    ///
    /// The headline path is the wizard's own: step 2 maps this Mac's Space onto
    /// an account Space whose `profile_uuid` this ARK cannot resolve (§3.2
    /// deliberately lets step 1 finish with exactly such an account profile), the
    /// entity parks on fallback B, and the SAME round's `pushSpaces` would then
    /// stamp name / icon / colour / theme / opacity AND `profile_uuid` `now` and
    /// commit them at the parked cursor's harvested `entityId` / `version` — an
    /// UPDATE the server accepts, replacing account-wide exactly the values the
    /// user was just promised would replace *this Mac's* (D7).
    ///
    /// The existing fallback-B case seeds no local Space, so its `outgoing` is
    /// empty and it cannot see this.
    func testAParkedUuidIsNeverPublishedOverAlthoughTheLocalRowIsMapped() async throws {
        let access = FakePhiSpaceAccess()
        // The local row's own profile IS mapped, so nothing else in `snapshot`
        // would skip this Space and the assertion really is about the park.
        access.uuidByProfileId = ["Default": "uuid-local"]
        access.profileIdByUuid = ["uuid-local": "Default"]
        access.knownLocalProfileIds = ["Default"]
        access.spaces = [localSpace("LOCAL-1", "Work", order: 0)]
        let store = MemorySpaceStore()
        store.table = makeSpaceTable(mappings: ["LOCAL-1": "sync-1"], access: access)
        let client = FakePhiSyncClient()
        client.seed(tagHash: spaceHash("sync-1"),
                    ciphertext: try ciphertext(spaceEntity("sync-1", name: "Work",
                                                           profileUuid: "uuid-unresolvable")),
                    version: 7)
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let cursor = try XCTUnwrap(store.table.cursors["sync-1"])
        XCTAssertNotNil(cursor.pendingApply, "fallback B: parked, never landed")
        XCTAssertNil(cursor.reconciled, "and therefore no baseline")
        XCTAssertTrue(spaceCommits(client).isEmpty,
                      "publishing with no baseline stamps `now` on every field and wins the whole account's LWW")
    }

    /// The file-wide local-row fixture. Every case that needs a Space on disk
    /// builds it here, so a row's id, name and sort order are the only things
    /// a case has to spell out.
    private func localSpace(_ id: String, _ name: String, order: Int) -> PhiLocalSpace {
        PhiLocalSpace(spaceId: id, profileId: "Default", name: name, colorHex: "#3A6FF8",
                      iconName: "phi:x", sortOrder: order,
                      createdDate: Date(timeIntervalSince1970: TimeInterval(order + 1)),
                      themeId: nil, opacityLight: nil, opacityDark: nil)
    }

    // MARK: - Remote tombstones (§9.2)

    func testARemoteTombstoneSoftDeletesAndKeepsEveryRowOnDisk() async throws {
        let access = FakePhiSpaceAccess()
        access.spaces = [localSpace("LOCAL-1", "Work", order: 1)]
        let store = MemorySpaceStore()
        store.table = makeSpaceTable(mappings: ["LOCAL-1": "sync-1"], access: access)
        var cursor = PhiSpaceCursor()
        cursor.entityId = "srv-1"; cursor.version = 4
        cursor.reconciled = try spaceEntity("sync-1").serializedData()
        cursor.server = cursor.reconciled
        store.table.cursors["sync-1"] = cursor

        let client = FakePhiSyncClient()
        client.seed(tagHash: spaceHash("sync-1"), ciphertext: Data(), version: 9,
                    entityId: "srv-1", deleted: true)
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertTrue(store.table.cursors["sync-1"]!.hidden)
        XCTAssertNotNil(store.table.cursors["sync-1"]!.deletedAtMs)
        XCTAssertTrue(access.calls.contains(.hide("LOCAL-1")))
        XCTAssertTrue(access.currentSpaces().contains { $0.spaceId == "LOCAL-1" },
                      "the 30-day window is only real if the data is still here")
        XCTAssertTrue(access.calls.filter { if case .purge = $0 { return true } else { return false } }.isEmpty)
    }

    /// Regression for §5.2's ordering rule: routing the tombstone AFTER the
    /// decrypt classifies every remote delete as "undecryptable" and, because the
    /// marker has already moved past that page, loses it permanently.
    func testATombstoneIsNeverTreatedAsADecryptFailure() async throws {
        let access = FakePhiSpaceAccess()
        access.spaces = [localSpace("LOCAL-1", "Work", order: 1)]
        let store = MemorySpaceStore()
        store.table = makeSpaceTable(mappings: ["LOCAL-1": "sync-1"], access: access)
        var cursor = PhiSpaceCursor(); cursor.entityId = "srv-1"; cursor.version = 4
        store.table.cursors["sync-1"] = cursor
        let client = FakePhiSyncClient()
        client.seed(tagHash: spaceHash("sync-1"), ciphertext: Data(), version: 9,
                    entityId: "srv-1", deleted: true)
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()
        XCTAssertTrue(store.table.unreadableTagHashes.isEmpty,
                      "a tombstone in that set would block the soft delete AND any later rebuild")
    }

    func testATombstoneForAnUnknownHashIsIgnoredWithoutCreatingACursor() async throws {
        let access = FakePhiSpaceAccess()
        let store = MemorySpaceStore()
        store.table = makeSpaceTable(access: access)
        let client = FakePhiSyncClient()
        client.seed(tagHash: "hash-nobody-knows", ciphertext: Data(), version: 3,
                    entityId: "srv-9", deleted: true)
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()
        XCTAssertTrue(store.table.cursors.isEmpty)
    }

    /// C1: the `default-space` IDENTITY is an ordinary deletable Space now. Its tombstone used
    /// to be ignored here on the strength of a stale comment, so the account held a delete
    /// every peer dropped; it must land like any other — hide, `deletedAtMs`, retention.
    func testTheDefaultSpaceTombstoneLandsLikeAnyOtherSpace() async throws {
        let access = FakePhiSpaceAccess()
        access.spaces = [localSpace(LocalStore.defaultSpaceId, "Default", order: 0),
                         localSpace("LOCAL-1", "Work", order: 1)]
        let store = MemorySpaceStore()
        store.table = makeSpaceTable(mappings: ["LOCAL-1": "sync-1"], access: access)
        let client = FakePhiSyncClient()
        client.seed(tagHash: spaceHash(SyncableSpaces.defaultSpaceUuid), ciphertext: Data(), version: 3,
                    entityId: "srv-d", deleted: true)
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertTrue(access.calls.contains(.hide(LocalStore.defaultSpaceId)))
        let cursor = try XCTUnwrap(store.table.cursors[SyncableSpaces.defaultSpaceUuid])
        XCTAssertTrue(cursor.hidden)
        XCTAssertNotNil(cursor.deletedAtMs, "the 30-day retention window starts here")
    }

    /// C1 safety case: the deleting device had a successor, this one has not received it yet.
    /// Hiding would leave zero live user Spaces, which is the invariant `deleteSpace` holds
    /// locally, so the tombstone parks on the existing `pendingTombstone` machinery and lands
    /// on the round after another user Space becomes live.
    func testTheDefaultSpaceTombstoneIsDeferredWhileItWouldHideTheLastLiveUserSpace() async throws {
        let access = FakePhiSpaceAccess()
        access.spaces = [localSpace(LocalStore.defaultSpaceId, "Default", order: 0)]
        let store = MemorySpaceStore()
        store.table = makeSpaceTable(access: access)
        let client = FakePhiSyncClient()
        client.seed(tagHash: spaceHash(SyncableSpaces.defaultSpaceUuid), ciphertext: Data(), version: 3,
                    entityId: "srv-d", deleted: true)
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertTrue(access.calls.filter { $0 == .hide(LocalStore.defaultSpaceId) }.isEmpty)
        let parked = try XCTUnwrap(store.table.cursors[SyncableSpaces.defaultSpaceUuid])
        XCTAssertTrue(parked.pendingTombstone,
                      "the shared marker has moved past it; the intent must survive here or it is lost")
        XCTAssertNil(parked.deletedAtMs)

        // The successor arrives (a later page, or a Space the wizard has now paired).
        access.spaces.append(localSpace("LOCAL-1", "Work", order: 1))
        access.spaceMappings["LOCAL-1"] = "sync-1"
        await engine.pullOnce()   // the tombstone is NOT redelivered

        XCTAssertTrue(access.calls.contains(.hide(LocalStore.defaultSpaceId)))
        let landed = try XCTUnwrap(store.table.cursors[SyncableSpaces.defaultSpaceUuid])
        XCTAssertTrue(landed.hidden)
        XCTAssertFalse(landed.pendingTombstone)
    }

    /// C1 / defect 0.3-2: a live `default-space` entity on a device whose default row was
    /// deleted used to park forever — the engine left `profileId` nil for the identity and
    /// `land` threw `unresolvedProfile`. It is created under this device's own Default
    /// profile, and D1 still applies: no `theme_id`, no rebind.
    func testTheDefaultIdentityIsCreatedUnderTheDevicesOwnProfileWhenItsRowIsGone() async throws {
        let access = FakePhiSpaceAccess()
        access.uuidByProfileId = ["Default": "uuid-a"]
        access.profileIdByUuid = ["uuid-a": "Default"]
        access.spaces = [localSpace("LOCAL-1", "Work", order: 0)]
        let store = MemorySpaceStore()
        store.table = makeSpaceTable(mappings: ["LOCAL-1": "sync-1"], access: access)
        let client = FakePhiSyncClient()
        client.seed(tagHash: spaceHash(SyncableSpaces.defaultSpaceUuid),
                    ciphertext: try ciphertext(spaceEntity(SyncableSpaces.defaultSpaceUuid,
                                                           name: "Default")), version: 3)
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertTrue(access.calls.contains(.create(LocalStore.defaultSpaceId)),
                      "the well-known row is recreated under its own id, never a minted one")
        let created = try XCTUnwrap(access.spaces.first { $0.spaceId == LocalStore.defaultSpaceId })
        XCTAssertEqual(created.profileId, "Default")
        XCTAssertNil(created.themeId, "D1: the identity carries no theme_id")
        XCTAssertFalse(access.calls.contains(.themeState(LocalStore.defaultSpaceId)),
                       "D1: no theme state is applied for the identity")
        XCTAssertTrue(access.calls.filter { if case .rebind = $0 { return true }; return false }.isEmpty,
                      "D1: the identity is never rebound")
        XCTAssertNil(access.spaceMappings[LocalStore.defaultSpaceId],
                     "the identity resolves through the constant branch, never a mapping row")
        XCTAssertNotNil(store.table.cursors[SyncableSpaces.defaultSpaceUuid]?.reconciled)
    }

    func testAnImportLockDefersTheTombstoneAndPersistsTheIntent() async throws {
        let access = FakePhiSpaceAccess()
        access.spaces = [localSpace("LOCAL-1", "Work", order: 1)]
        // The import lock is asked about the LOCAL row, so the tombstone has to be
        // translated before the question can even be posed.
        access.importingSpaceIds = ["LOCAL-1"]
        let store = MemorySpaceStore()
        store.table = makeSpaceTable(mappings: ["LOCAL-1": "sync-1"], access: access)
        var cursor = PhiSpaceCursor(); cursor.entityId = "srv-1"; cursor.version = 4
        store.table.cursors["sync-1"] = cursor
        let client = FakePhiSyncClient()
        client.seed(tagHash: spaceHash("sync-1"), ciphertext: Data(), version: 9,
                    entityId: "srv-1", deleted: true)
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertTrue(store.table.cursors["sync-1"]!.pendingTombstone,
                      "the shared marker has moved past it; the intent must survive here or it is lost")
        XCTAssertFalse(store.table.cursors["sync-1"]!.hidden)

        access.importingSpaceIds = []
        await engine.pullOnce()   // the tombstone is NOT redelivered
        XCTAssertTrue(store.table.cursors["sync-1"]!.hidden)
        XCTAssertFalse(store.table.cursors["sync-1"]!.pendingTombstone)
    }

    func testASoftDeletedSpaceIsNeverResurrectedBySnapshotOrByAReplayedTombstone() async throws {
        let access = FakePhiSpaceAccess()
        access.uuidByProfileId = ["Default": "uuid-a"]
        access.spaces = [localSpace("LOCAL-1", "Work", order: 1)]
        let store = MemorySpaceStore()
        store.table = makeSpaceTable(mappings: ["LOCAL-1": "sync-1"], access: access)
        var cursor = PhiSpaceCursor()
        cursor.entityId = "srv-1"; cursor.version = 9
        cursor.hidden = true; cursor.deletedAtMs = 5_000
        store.table.cursors["sync-1"] = cursor
        let client = FakePhiSyncClient()
        client.seed(tagHash: spaceHash("sync-1"), ciphertext: Data(), version: 9,
                    entityId: "srv-1", deleted: true)
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()
        XCTAssertTrue(spaceCommits(client).isEmpty)
        XCTAssertEqual(store.table.cursors["sync-1"]!.deletedAtMs, 5_000)
    }

    // MARK: - Retention sweep (§9.2)

    /// 7b. Thirty-day cleanup passes local id to purge, removes the mapping, and
    /// retains the cursor with purgedAtMs. This extends
    /// testTheSweepCascadesTheDataAndKeepsThePermanentTombstone to the mapping lifecycle
    /// after rekeying, preserving its reconciled assertion.
    func testTheRetentionPurgeUsesTheLocalIdThenDropsTheMappingAndKeepsTheCursor() async throws {
        let clock = Clock()
        let access = FakePhiSpaceAccess()
        access.spaces = [localSpace("LOCAL-1", "Work", order: 0)]
        let store = MemorySpaceStore()
        store.table = makeSpaceTable(mappings: ["LOCAL-1": "sync-1"], access: access)
        var softDeleted = PhiSpaceCursor()
        softDeleted.entityId = "srv-1"
        softDeleted.version = 4
        softDeleted.hidden = true
        softDeleted.deletedAtMs = clock.nowMs
        softDeleted.reconciled = Data([0x01])
        store.table.cursors["sync-1"] = softDeleted
        let engine = makeEngine(access: access, store: store,
                                client: FakePhiSyncClient(), clock: clock)
        await engine.setSpaceSyncEnabled(true)

        clock.nowMs += PhiSpaceSyncState.retentionMs + 1
        await engine.runRetentionSweep()

        XCTAssertTrue(access.calls.contains(.purge("LOCAL-1")))
        XCTAssertFalse(access.currentSpaces().contains { $0.spaceId == "LOCAL-1" })
        XCTAssertNil(access.spaceMappings["LOCAL-1"])
        let cursor = try XCTUnwrap(store.table.cursors["sync-1"], "The cursor is the permanent tombstone record")
        XCTAssertNotNil(cursor.purgedAtMs)
        XCTAssertNotNil(cursor.deletedAtMs)
        XCTAssertNil(cursor.reconciled, "purgeExpired also clears the baseline")
    }

    /// 7d. Failed cascade must retain the mapping. Removing it lets pushSpaces
    /// lazily mint a new syncUuid for the surviving disk row, permanently republishing
    /// the purged Space: phase 1 already set purgedAtMs, so cleanup never retries.
    /// Before D6, the same try? was harmless because local-id-keyed cursors let
    /// snapshot's deletedAtMs filter always exclude the row.
    func testAFailedRetentionPurgeKeepsTheMappingSoTheRowCannotComeBack() async throws {
        struct Boom: Error {}
        let clock = Clock()
        let access = FakePhiSpaceAccess()
        access.spaces = [localSpace("LOCAL-1", "Work", order: 0)]
        access.uuidByProfileId = ["Default": "uuid-a"]
        let store = MemorySpaceStore()
        store.table = makeSpaceTable(mappings: ["LOCAL-1": "sync-1"], access: access)
        var softDeleted = PhiSpaceCursor()
        softDeleted.entityId = "srv-1"
        softDeleted.version = 4
        softDeleted.hidden = true
        softDeleted.deletedAtMs = clock.nowMs
        store.table.cursors["sync-1"] = softDeleted
        let client = FakePhiSyncClient()
        let engine = makeEngine(access: access, store: store, client: client, clock: clock)
        await engine.setSpaceSyncEnabled(true)

        clock.nowMs += PhiSpaceSyncState.retentionMs + 1
        access.errorOnNextWrite = Boom()
        await engine.runRetentionSweep()

        XCTAssertEqual(access.spaceMappings["LOCAL-1"], "sync-1",
                       "Failed purge retains the mapping to the cursor with deletedAtMs")
        await engine.pushLocalSettings()   // The engine's only public push entry point
        XCTAssertTrue(spaceCommits(client).isEmpty,
                      "The surviving disk row must not be republished under any identity")
    }

    // MARK: - Delete origin (§9.1)

    func testRecordLocalDeletionOnlyMarksAPublishedSpace() async throws {
        let access = FakePhiSpaceAccess()
        let store = MemorySpaceStore()
        store.table = makeSpaceTable(mappings: ["LOCAL-P": "sync-published",
                                                "LOCAL-A": "sync-agent"], access: access)
        var published = PhiSpaceCursor(); published.entityId = "srv-1"; published.version = 3
        var refused = PhiSpaceCursor(); refused.refusedAtMs = 1
        store.table.cursors = ["sync-published": published, "sync-agent": refused]
        let client = FakePhiSyncClient()
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        // The facade's parameter is a LOCAL spaceId in all three calls (§3.4).
        await engine.recordLocalDeletion(spaceId: "LOCAL-P")
        await engine.recordLocalDeletion(spaceId: "LOCAL-A")
        await engine.recordLocalDeletion(spaceId: "LOCAL-NEVER")
        XCTAssertTrue(store.table.cursors["sync-published"]!.pendingDelete)
        XCTAssertFalse(store.table.cursors["sync-agent"]!.pendingDelete)
        XCTAssertEqual(store.table.cursors.count, 2,
                       "an unmapped local id is not a tombstone; it must not mint a cursor")
    }

    /// The single-writer rule (§5.3): the facade delivers an INTENT that runs on
    /// the engine's serial queue rather than writing the table from the main
    /// thread, so the delete is still there when the next round assembles its
    /// batch. The interleaved case -- an intent raised while a round is parked
    /// inside `client.commit` -- is pinned separately, below.
    func testADeletionIntentSurvivesAConcurrentSnapshot() async throws {
        let access = FakePhiSpaceAccess()
        access.uuidByProfileId = ["Default": "uuid-a"]
        access.spaces = [localSpace("LOCAL-1", "Work", order: 1)]
        let store = MemorySpaceStore()
        store.table = makeSpaceTable(mappings: ["LOCAL-1": "sync-1"], access: access)
        var cursor = PhiSpaceCursor(); cursor.entityId = "srv-1"; cursor.version = 3
        cursor.reconciled = try spaceEntity("sync-1").serializedData()
        cursor.server = cursor.reconciled
        store.table.cursors["sync-1"] = cursor
        let client = FakePhiSyncClient()
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.recordLocalDeletion(spaceId: "LOCAL-1")
        await engine.handleLocalSpacesChange()
        XCTAssertTrue(store.table.cursors["sync-1"]!.pendingDelete
                      || store.table.cursors["sync-1"]!.deletedAtMs != nil)
    }

    /// §5.3 single writer: a round reads a snapshot, the user deletes a Space, then
    /// the engine writes its stale table. pushSpaces loads before its batch loop
    /// and saves after commit, so a reentrant deletion in between would be silently
    /// and permanently erased. Without pendingDelete, the UUID never enters the
    /// commit union; without deletedAtMs, later delivery recreates the deleted Space.
    /// Route intent through roundQueue: assert it has not applied while the round
    /// is parked and has applied when the round completes.
    func testADeleteRaisedWhileACommitIsInFlightIsNotOverwrittenByTheRoundsTail() async throws {
        let access = FakePhiSpaceAccess()
        access.uuidByProfileId = ["Default": "uuid-a"]
        access.profileIdByUuid = ["uuid-a": "Default"]
        access.spaces = [localSpace("LOCAL-1", "Work", order: 1)]
        let store = MemorySpaceStore()
        store.table = makeSpaceTable(mappings: ["LOCAL-1": "sync-1"], access: access)
        let client = FakePhiSyncClient()
        client.seed(tagHash: spaceHash("sync-1"),
                    ciphertext: try ciphertext(spaceEntity("sync-1")), version: 3)
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        // One ordinary round first, so `sync-1` owns a published cursor (entityId +
        // version + baselines) rather than a hand-built one.
        await engine.pullOnce()
        let published = try XCTUnwrap(store.table.cursors["sync-1"])
        XCTAssertNotNil(published.entityId)
        XCTAssertFalse(published.pendingDelete)

        // A local rename gives the next round something to commit, which is what
        // opens the suspension window this test needs.
        access.spaces = [localSpace("LOCAL-1", "Renamed", order: 1)]
        let arrived = Gate()
        let release = Gate()
        client.gatedCommitTagHash = spaceHash("sync-1")
        client.arrivedInCommit = arrived
        client.commitGate = release

        let round = Task { await engine.handleLocalSpacesChange() }
        await arrived.wait()          // the push is parked inside commit, table copy in hand

        let deletion = Task { await engine.recordLocalDeletion(spaceId: "LOCAL-1") }
        for _ in 0..<32 { await Task.yield() }
        XCTAssertFalse(store.table.cursors["sync-1"]!.pendingDelete,
                       "the intent must queue behind the round, not run inside its table window")

        await release.open()
        await round.value
        await deletion.value
        XCTAssertTrue(store.table.cursors["sync-1"]!.pendingDelete,
                      "the delete must survive the round's writeSpaceTable and ship a tombstone")
    }

    /// §9.2's landing is TERMINAL for that uuid: a local delete queued a moment
    /// earlier (`SpaceManager.deleteSpace` -> `recordLocalDeletion`) is owed to
    /// nobody once the peer's tombstone is here. `spaceCommitEntries` unions
    /// EVERY `pendingDelete` cursor into the next batch, so a flag left standing
    /// ships a redundant `deleted: true` commit for a row the server has already
    /// tombstoned -- and its `.applied` outcome re-stamps `deletedAtMs = now()`,
    /// restarting the 30-day window from the echo instead of from the delete.
    func testARemoteTombstoneCancelsAQueuedLocalDeleteInsteadOfEchoingIt() async throws {
        let access = FakePhiSpaceAccess()
        access.uuidByProfileId = ["Default": "uuid-a"]
        access.spaces = [localSpace("LOCAL-1", "Work", order: 1)]
        let store = MemorySpaceStore()
        store.table = makeSpaceTable(mappings: ["LOCAL-1": "sync-1"], access: access)
        var cursor = PhiSpaceCursor()
        cursor.entityId = "srv-1"; cursor.version = 4
        cursor.reconciled = try spaceEntity("sync-1").serializedData()
        cursor.server = cursor.reconciled
        // The local delete is already queued when the peer's tombstone arrives,
        // and it has been rejected twice, so the streak must be reset too.
        cursor.pendingDelete = true
        cursor.deleteRejectRounds = 2
        store.table.cursors["sync-1"] = cursor
        let client = FakePhiSyncClient()
        client.seed(tagHash: spaceHash("sync-1"), ciphertext: Data(), version: 9,
                    entityId: "srv-1", deleted: true)
        let clock = Clock()
        let engine = makeEngine(access: access, store: store, client: client, clock: clock)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let landed = try XCTUnwrap(store.table.cursors["sync-1"])
        XCTAssertFalse(landed.pendingDelete)
        XCTAssertEqual(landed.deleteRejectRounds, 0)
        XCTAssertTrue(spaceCommits(client).isEmpty,
                      "the account already holds this tombstone; echoing it costs a commit and the window")
        XCTAssertEqual(landed.deletedAtMs, clock.nowMs,
                       "the 30-day window runs from the delete, never from an echo of it")
    }

    // MARK: - D6: Inbound identity translation (§3.4)

    /// 1. A remote-only Space writes its mapping before creating the row (R-M3-4a-87),
    /// using a local id preminted by the engine.
    func testAnAccountSpaceWithNoLocalRowLandsUnderAFreshLocalIdAndThenMaps() async throws {
        let access = FakePhiSpaceAccess()
        access.uuidByProfileId = ["Default": "uuid-a"]
        access.profileIdByUuid = ["uuid-a": "Default"]
        let store = MemorySpaceStore()
        store.table = makeSpaceTable(access: access)
        let client = FakePhiSyncClient()
        client.seed(tagHash: spaceHash("sync-new"),
                    ciphertext: try ciphertext(spaceEntity("sync-new", name: "Reading")), version: 3)
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let created = try XCTUnwrap(access.spaces.first)
        XCTAssertNotEqual(created.spaceId, "sync-new", "Never use a wire UUID as a local row id")
        XCTAssertEqual(access.spaceMappings[created.spaceId], "sync-new")
        XCTAssertNotNil(store.table.cursors["sync-new"]?.reconciled)
    }

    /// 1b. If create throws, the mapping is already persisted but no row or baseline
    /// exists, and the entity remains pendingApply (R-M3-4a-87). Next round's A0
    /// dead-mapping repair drops that dangling mapping and retries clean application
    /// (CASE B2-17, PhiSyncMarkerBoundaryTests).
    func testAFailedCreateLeavesADanglingMappingAndNoRowForTheNextRoundToHeal() async throws {
        let access = FakePhiSpaceAccess()
        access.uuidByProfileId = ["Default": "uuid-a"]
        access.profileIdByUuid = ["uuid-a": "Default"]
        access.errorOnNextWrite = NSError(domain: "test", code: 1)
        let store = MemorySpaceStore()
        store.table = makeSpaceTable(access: access)
        let client = FakePhiSyncClient()
        client.seed(tagHash: spaceHash("sync-new"),
                    ciphertext: try ciphertext(spaceEntity("sync-new")), version: 3)
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertEqual(access.spaceMappings.count, 1, "The dangling mapping is persisted and awaits repair")
        XCTAssertEqual(access.spaceMappings.values.first, "sync-new")
        XCTAssertTrue(access.spaces.isEmpty, "No row was created")
        XCTAssertNil(store.table.cursors["sync-new"]?.reconciled)
        XCTAssertNotNil(store.table.cursors["sync-new"]?.pendingApply)
    }

    /// 2. Mapped Space: no create calls; all three write APIs receive local ids.
    func testAMappedSpaceUpdatesTheLocalRowAndNeverCreates() async throws {
        let access = FakePhiSpaceAccess()
        access.uuidByProfileId = ["Default": "uuid-a"]
        access.profileIdByUuid = ["uuid-a": "Default"]
        access.spaces = [localSpace("LOCAL-1", "Old", order: 0)]
        let store = MemorySpaceStore()
        store.table = makeSpaceTable(mappings: ["LOCAL-1": "sync-1"], access: access)
        let client = FakePhiSyncClient()
        client.seed(tagHash: spaceHash("sync-1"),
                    ciphertext: try ciphertext(spaceEntity("sync-1", name: "New")), version: 3)
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertFalse(access.calls.contains { if case .create = $0 { return true }; return false })
        XCTAssertTrue(access.calls.contains(.update("LOCAL-1")))
        XCTAssertEqual(access.spaces.first?.name, "New")
    }

    /// 3. Failed reverse lookup creates a new Space without claiming an unmapped
    /// local namesake. Claiming belongs to the wizard; the engine must not guess.
    func testAnUnmappedSameNamedLocalSpaceIsNeverAdoptedByTheEngine() async throws {
        let access = FakePhiSpaceAccess()
        access.uuidByProfileId = ["Default": "uuid-a"]
        access.profileIdByUuid = ["uuid-a": "Default"]
        access.spaces = [localSpace("LOCAL-1", "Work", order: 0)]
        let store = MemorySpaceStore()
        store.table = makeSpaceTable(access: access)
        let client = FakePhiSyncClient()
        client.seed(tagHash: spaceHash("sync-x"),
                    ciphertext: try ciphertext(spaceEntity("sync-x", name: "Work")), version: 3)
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertEqual(access.spaces.count, 2, "Matching names do not establish identity")
        // The round-end push lazily mints this unpublished local row's own UUID
        // (R-D6-7). Assert it was not claimed by the remote entity, rather than that it has no mapping.
        XCTAssertNotEqual(access.spaceMappings["LOCAL-1"], "sync-x")
    }

    /// 4. Two local Spaces never map to one syncUuid: seed a mapping and apply that UUID again.
    func testLandingAnAlreadyMappedUuidTakesTheUpdatePathAndAddsNoSecondMapping() async throws {
        let access = FakePhiSpaceAccess()
        access.uuidByProfileId = ["Default": "uuid-a"]
        access.profileIdByUuid = ["uuid-a": "Default"]
        access.spaces = [localSpace("LOCAL-1", "Work", order: 0)]
        let store = MemorySpaceStore()
        store.table = makeSpaceTable(mappings: ["LOCAL-1": "sync-1"], access: access)
        let client = FakePhiSyncClient()
        client.seed(tagHash: spaceHash("sync-1"),
                    ciphertext: try ciphertext(spaceEntity("sync-1", name: "Renamed")), version: 3)
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertEqual(access.spaceMappings, ["LOCAL-1": "sync-1"])
        XCTAssertEqual(access.spaces.count, 1)
    }

    /// 4b. Dead-mapping repair: reverse lookup without a local row drops the mapping
    /// and applies the entity as a new, unmapped Space.
    func testADeadSpaceMappingIsDroppedAndTheEntityLandsAsANewSpace() async throws {
        let access = FakePhiSpaceAccess()
        access.uuidByProfileId = ["Default": "uuid-a"]
        access.profileIdByUuid = ["uuid-a": "Default"]
        access.spaces = []                       // The local row is gone
        access.knownLocalSpaceIds = []           // It is also absent from getAllSpaces()
        let store = MemorySpaceStore()
        store.table = makeSpaceTable(mappings: ["LOCAL-GONE": "sync-1"], access: access)
        let client = FakePhiSyncClient()
        client.seed(tagHash: spaceHash("sync-1"),
                    ciphertext: try ciphertext(spaceEntity("sync-1")), version: 3)
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertTrue(access.calls.contains(.dropSpaceMapping("LOCAL-GONE")))
        let created = try XCTUnwrap(access.spaces.first)
        XCTAssertEqual(access.spaceMappings[created.spaceId], "sync-1")
        XCTAssertNil(access.spaceMappings["LOCAL-GONE"])
    }

    /// 5. Rank translation: applyOrder must receive local ids. Omitting translation
    /// is a silent no-op, demonstrated by
    /// SyncableSpacesTests.testPlannedOrderIsASilentNoOpWhenHandedSyncUuidKeys.
    func testTheAccountWideReorderIsAppliedWithLocalIds() async throws {
        let access = FakePhiSpaceAccess()
        access.uuidByProfileId = ["Default": "uuid-a"]
        access.profileIdByUuid = ["uuid-a": "Default"]
        access.spaces = [localSpace("LOCAL-1", "A", order: 0), localSpace("LOCAL-2", "B", order: 1)]
        let store = MemorySpaceStore()
        store.table = makeSpaceTable(mappings: ["LOCAL-1": "sync-1", "LOCAL-2": "sync-2"],
                                     access: access)
        let client = FakePhiSyncClient()
        // F precedes V: account sync-2 sorts before sync-1.
        client.seed(tagHash: spaceHash("sync-1"),
                    ciphertext: try ciphertext(spaceEntity("sync-1", name: "A")), version: 3)
        client.seed(tagHash: spaceHash("sync-2"),
                    ciphertext: try ciphertext(rankedEntity("sync-2", name: "B", rank: "F")), version: 3)
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let order = access.calls.compactMap { if case .order(let ids) = $0 { return ids }; return nil }.last
        XCTAssertEqual(order, ["LOCAL-2", "LOCAL-1"])
    }

    /// 6a. A tombstone with a local row calls hide using the local id.
    func testARemoteTombstoneHidesTheLocalRowWhenOneExists() async throws {
        let access = FakePhiSpaceAccess()
        access.uuidByProfileId = ["Default": "uuid-a"]
        access.profileIdByUuid = ["uuid-a": "Default"]
        access.spaces = [localSpace("LOCAL-1", "Work", order: 0)]
        let store = MemorySpaceStore()
        store.table = makeSpaceTable(mappings: ["LOCAL-1": "sync-1"], access: access)
        var published = PhiSpaceCursor()
        published.entityId = "srv-1"
        published.version = 4
        published.reconciled = try spaceEntity("sync-1").serializedData()
        published.server = published.reconciled
        store.table.cursors["sync-1"] = published
        let client = FakePhiSyncClient()
        client.seed(tagHash: spaceHash("sync-1"), ciphertext: Data(), version: 9,
                    entityId: "srv-1", deleted: true)
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertTrue(access.calls.contains(.hide("LOCAL-1")))
        let cursor = try XCTUnwrap(store.table.cursors["sync-1"])
        XCTAssertTrue(cursor.hidden)
        XCTAssertNotNil(cursor.deletedAtMs)
        XCTAssertEqual(access.spaceMappings["LOCAL-1"], "sync-1",
                       "Remote soft deletion retains the mapping as the sole account-identity record for 30 days")
    }

    /// 6b. Without a local row, skip hide but still record hidden and deletedAtMs.
    /// The account entity was deleted even if this device never had it; the cursor
    /// must remember that or replaying a create would resurrect it.
    func testARemoteTombstoneWithNoLocalRowStillWritesTheCursorGuard() async throws {
        let access = FakePhiSpaceAccess()
        access.uuidByProfileId = ["Default": "uuid-a"]
        access.profileIdByUuid = ["uuid-a": "Default"]
        let store = MemorySpaceStore()
        store.table = makeSpaceTable(access: access)
        var published = PhiSpaceCursor()
        published.entityId = "srv-1"
        published.version = 4
        store.table.cursors["sync-orphan"] = published
        let client = FakePhiSyncClient()
        client.seed(tagHash: spaceHash("sync-orphan"), ciphertext: Data(), version: 9,
                    entityId: "srv-1", deleted: true)
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertTrue(access.calls.filter { if case .hide = $0 { return true }; return false }.isEmpty)
        let cursor = try XCTUnwrap(store.table.cursors["sync-orphan"])
        XCTAssertTrue(cursor.hidden)
        XCTAssertNotNil(cursor.deletedAtMs, "The resurrection guard reads deletedAtMs")
    }

    func testTheTagIndexIsSeededFromTheMappingTableSoAnUncommittedSpaceCanBeTombstoned() async throws {
        // Recognize a tombstone for a just-paired Space that has a mapping but no cursor or prior commit.
        let access = FakePhiSpaceAccess()
        access.spaces = [localSpace("LOCAL-1", "Work", order: 0)]
        access.uuidByProfileId = ["Default": "uuid-a"]
        access.profileIdByUuid = ["uuid-a": "Default"]
        let store = MemorySpaceStore()
        store.table = makeSpaceTable(mappings: ["LOCAL-1": "sync-1"], access: access)
        let client = FakePhiSyncClient()
        client.seed(tagHash: spaceHash("sync-1"), ciphertext: Data(), version: 9,
                    entityId: "srv-1", deleted: true)
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertTrue(access.calls.contains(.hide("LOCAL-1")))
        XCTAssertNotNil(store.table.cursors["sync-1"]?.deletedAtMs)
    }

    /// 7a. Accepted local-deletion tombstone removes the mapping but retains the cursor (R-D6-10).
    func testALocalDeleteDropsTheMappingWhenItsTombstoneIsAccepted() async throws {
        let access = FakePhiSpaceAccess()
        access.uuidByProfileId = ["Default": "uuid-a"]
        access.profileIdByUuid = ["uuid-a": "Default"]
        access.spaces = [localSpace("LOCAL-1", "Work", order: 0)]
        // Remove the local row from spaces below while keeping the mapping known.
        // Otherwise applySpaces' isKnownLocalSpace repair deletes it first and this case
        // never exercises step 4.
        access.knownLocalSpaceIds = ["LOCAL-1"]
        let store = MemorySpaceStore()
        store.table = makeSpaceTable(mappings: ["LOCAL-1": "sync-1"], access: access)
        var published = PhiSpaceCursor()
        published.entityId = "srv-1"
        published.version = 4
        published.reconciled = try spaceEntity("sync-1").serializedData()
        published.server = published.reconciled
        store.table.cursors["sync-1"] = published
        let client = FakePhiSyncClient()
        client.seed(tagHash: spaceHash("sync-1"),
                    ciphertext: try ciphertext(spaceEntity("sync-1")), version: 4, entityId: "srv-1")
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        // Run a round first to advance the shared marker past the entity, preventing
        // the next push's initial pull from replaying it and recreating the local row.
        await engine.pullOnce()

        access.spaces = []                                   // The local row is already deleted
        await engine.recordLocalDeletion(spaceId: "LOCAL-1") // The facade accepts a local id
        await engine.handleLocalSpacesChange()               // One push sends and accepts the tombstone

        XCTAssertTrue(spaceCommits(client).contains { $0.deleted })
        XCTAssertTrue(access.calls.filter { if case .create = $0 { return true }; return false }.isEmpty,
                      "The accepted tombstone removes the mapping, not dead-mapping repair")
        XCTAssertNil(access.spaceMappings["LOCAL-1"], "The mapping is removed when the tombstone is applied")
        let cursor = try XCTUnwrap(store.table.cursors["sync-1"])
        XCTAssertNotNil(cursor.deletedAtMs, "The cursor remains as a permanent tombstone record")
        XCTAssertFalse(cursor.pendingDelete)
    }

    /// 7c. Replaying the tombstone after cleanup is a no-op; snapshot cannot resurrect its UUID.
    func testAPurgedUuidIsNeverResurrected() async throws {
        let clock = Clock()
        let access = FakePhiSpaceAccess()
        access.uuidByProfileId = ["Default": "uuid-a"]
        access.profileIdByUuid = ["uuid-a": "Default"]
        let store = MemorySpaceStore()
        store.table = makeSpaceTable(access: access)
        var purged = PhiSpaceCursor()
        purged.entityId = "srv-1"
        purged.version = 4
        purged.hidden = true
        purged.deletedAtMs = clock.nowMs
        purged.purgedAtMs = clock.nowMs
        store.table.cursors["sync-1"] = purged
        let client = FakePhiSyncClient()
        client.seed(tagHash: spaceHash("sync-1"),
                    ciphertext: try ciphertext(spaceEntity("sync-1")), version: 9)
        let engine = makeEngine(access: access, store: store, client: client, clock: clock)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertTrue(access.spaces.isEmpty, "Create replay cannot resurrect a soft-deleted UUID")
        XCTAssertTrue(spaceCommits(client).isEmpty)
    }

    /// 8. recordLocalDeletion receives local id at the boundary. Without a mapping,
    /// it is a no-op: no cursor creation and no commit.
    func testRecordLocalDeletionTranslatesTheLocalIdAndNoOpsWithNoMapping() async throws {
        let access = FakePhiSpaceAccess()
        access.spaces = [localSpace("LOCAL-1", "Work", order: 0),
                         localSpace("LOCAL-2", "Reading", order: 1)]
        let store = MemorySpaceStore()
        store.table = makeSpaceTable(mappings: ["LOCAL-1": "sync-1"], access: access)
        var published = PhiSpaceCursor()
        published.entityId = "srv-1"
        published.version = 4
        store.table.cursors["sync-1"] = published
        let engine = makeEngine(access: access, store: store, client: FakePhiSyncClient())
        await engine.setSpaceSyncEnabled(true)

        await engine.recordLocalDeletion(spaceId: "LOCAL-1")
        XCTAssertTrue(store.table.cursors["sync-1"]!.pendingDelete)

        await engine.recordLocalDeletion(spaceId: "LOCAL-2")   // Never published
        XCTAssertEqual(store.table.cursors.count, 1, "Without a mapping there is no tombstone to send or cursor to create")
    }

    /// 9. Lazy minting (R-D6-7): a Space created locally after pairing mints once, never again next round.
    func testANewLocalSpaceIsMintedExactlyOnceAndThenPublished() async throws {
        let access = FakePhiSpaceAccess()
        access.uuidByProfileId = ["Default": "uuid-a"]
        access.profileIdByUuid = ["uuid-a": "Default"]
        access.spaces = [localSpace("LOCAL-NEW", "Work", order: 0)]
        let store = MemorySpaceStore()
        store.table = makeSpaceTable(access: access)
        let client = FakePhiSyncClient()
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertEqual(access.spaceMappings["LOCAL-NEW"], "sync-LOCAL-NEW")
        XCTAssertEqual(access.calls.filter { $0 == .ensureMapped("LOCAL-NEW") }.count, 1)
        XCTAssertEqual(spaceCommits(client).map(\.clientTagHash), [spaceHash("sync-LOCAL-NEW")])

        await engine.pullOnce()
        XCTAssertEqual(access.calls.filter { $0 == .ensureMapped("LOCAL-NEW") }.count, 1,
                       "The second round reuses the mapping through ensureMapped")
    }

    /// 10. Repair after formatVersion reset (§3.6): an empty table with a marker
    /// drops the marker on the gate-open edge, replays the whole type, arms
    /// drainInProgress, and sends no commits until drain completion. hadRecords=false
    /// prevents guard ② from triggering a second replay.
    func testAnEmptyTableAfterTheFormatCutReplaysExactlyOnce() async throws {
        let access = FakePhiSpaceAccess()
        access.uuidByProfileId = ["Default": "uuid-a"]
        access.profileIdByUuid = ["uuid-a": "Default"]
        access.spaces = [localSpace("LOCAL-1", "Work", order: 0)]
        // Post-reset disk state: empty table with hadRecords=false and
        // hasDrainedFullReplay=false, plus the previous version's marker.
        defaults.set(Data([0xAB]), forKey: PhiSyncEngine.markerStateKey)
        let store = MemorySpaceStore()
        store.table = PhiSpaceSyncTable()
        let client = FakePhiSyncClient()
        client.seed(tagHash: spaceHash("sync-1"),
                    ciphertext: try ciphertext(spaceEntity("sync-1")), version: 3)
        let engine = makeEngine(access: access, store: store, client: client)

        await engine.setSpaceSyncEnabled(true)
        XCTAssertNil(defaults.data(forKey: PhiSyncEngine.markerStateKey),
                     "Opening the gate drops the marker and replays the entire type")
        XCTAssertTrue(store.table.drainInProgress)
        XCTAssertFalse(store.table.didReplayForEmptyTable,
                       "hadRecords=false excludes guard ②, so replay happens once")

        await engine.pullOnce()
        XCTAssertTrue(store.table.hasDrainedFullReplay)
        XCTAssertFalse(store.table.didReplayForEmptyTable)
        XCTAssertEqual(client.getUpdatesCalls.first?.marker, nil)
    }

    // MARK: - Preview (§4)

    func testUnpairedPreviewAfterServerResetKeepsPersistentSyncStateUntouched() async throws {
        let access = FakePhiSpaceAccess()
        let store = MemorySpaceStore()
        store.table = makeSpaceTable(access: access)
        let tableBefore = store.table
        let oldMarker = PhiSyncMarkerFile(marker: Data([0xAB]), storeBirthday: "old-server")
        let markerStore = MemoryMarkerStore(file: oldMarker)
        let client = FakePhiSyncClient()
        client.rejectStaleStoreBirthday = true
        client.storeBirthday = "new-server"
        client.seed(tagHash: spaceHash("sync-1"),
                    ciphertext: try ciphertext(spaceEntity("sync-1", name: "Work")), version: 3)
        let engine = PhiSyncEngine(domainKeys: StubDomainKeys(key: key), client: client,
                                   defaults: defaults, deviceKeyId: "device", pairingComplete: false,
                                   settings: [], spaceAccess: access, spaceStore: store,
                                   markerStore: markerStore)

        await engine.pullOnce()
        XCTAssertTrue(client.getUpdatesCalls.isEmpty, "Unpaired regular sync must remain stopped")
        let result = await engine.previewAccountSpaces()
        guard case .failure(.transport("not_my_birthday")) = result else {
            return XCTFail("Expected explicit reconfiguration: \(result)")
        }
        XCTAssertNil(client.getUpdatesCalls.first?.marker)
        XCTAssertEqual(client.getUpdatesCalls.first?.storeBirthday, "")
        var paused = oldMarker
        paused.requiresReconfiguration = true
        XCTAssertEqual(markerStore.file, paused)
        XCTAssertEqual(store.table, tableBefore)
        XCTAssertEqual(store.saveCalls, 0)
        XCTAssertTrue(client.commits.isEmpty)
        _ = await engine.previewAccountSpaces()
        await engine.pullOnce()
        XCTAssertEqual(client.getUpdatesCalls.count, 1, "Retry cannot clear old state")
        XCTAssertEqual(markerStore.file, paused)
    }

    /// 11. Preview writes nothing.
    func testThePreviewPersistsNothingAtAll() async throws {
        let access = FakePhiSpaceAccess()
        let store = MemorySpaceStore()
        store.table = makeSpaceTable(access: access)
        let client = FakePhiSyncClient()
        client.seed(tagHash: spaceHash("sync-1"),
                    ciphertext: try ciphertext(spaceEntity("sync-1", name: "Work")), version: 3)
        let engine = makeEngine(access: access, store: store, client: client)
        // Keep the gate closed: preview is the only Space-shaped read permitted in this state.
        defaults.set(Data([0xAB]), forKey: PhiSyncEngine.markerStateKey)
        let tableBefore = store.table

        let result = await engine.previewAccountSpaces()
        guard case .success(let summaries) = result else { return XCTFail("expected success") }
        XCTAssertEqual(summaries.map(\.syncUuid), ["sync-1"])

        XCTAssertEqual(defaults.data(forKey: PhiSyncEngine.markerStateKey), Data([0xAB]),
                       "The marker remains byte-for-byte unchanged")
        XCTAssertNil(defaults.string(forKey: PhiSyncEngine.entityIdStateKey))
        XCTAssertNil(defaults.object(forKey: PhiSyncEngine.versionStateKey))
        XCTAssertEqual(store.table, tableBefore, "The Space table remains equal in every field")
        XCTAssertTrue(access.calls.isEmpty, "No PhiSpaceLocalAccess calls")
        XCTAssertTrue(client.commits.isEmpty, "No commits")

        // The next normal pull still starts from the original marker.
        await engine.setSpaceSyncEnabled(false)
        await engine.pullOnce()
        XCTAssertEqual(client.getUpdatesCalls.last?.marker, Data([0xAB]))
    }

    /// 12. Preview uses the same round queue. If a settings pull blocks in getUpdates,
    /// preview's first getUpdates begins only after that pull completes.
    func testThePreviewRunsOnTheRoundQueueAndNeverInterleaves() async throws {
        let access = FakePhiSpaceAccess()
        let store = MemorySpaceStore()
        store.table = makeSpaceTable(access: access)
        let client = FakePhiSyncClient()
        let arrived = Gate()
        let release = Gate()
        client.arrivedInGetUpdates = arrived
        client.getUpdatesGate = release
        let engine = makeEngine(access: access, store: store, client: client)

        let pull = Task { await engine.pullOnce() }
        await arrived.wait()                       // The pull round is blocked in getUpdates
        let preview = Task { await engine.previewAccountSpaces() }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(client.getUpdatesCalls.count, 1, "Preview did not interleave with the pull")
        await release.open()
        _ = await pull.value
        _ = await preview.value
        XCTAssertGreaterThan(client.getUpdatesCalls.count, 1)
    }

    /// Enforce §4.5's deadline inside the round, not only in the wizard. serialized
    /// uses an unstructured Task that wizard cancellation cannot stop. Without this
    /// guard, slow networking occupies the queue for previewMaxPages times 60 seconds
    /// per request. Raising the page budget from 64 to 400 makes the actual elapsed-time
    /// cap more essential.
    func testThePreviewStopsPagingOnceItsOwnDeadlineHasPassed() async throws {
        let access = FakePhiSpaceAccess()
        let store = MemorySpaceStore()
        store.table = makeSpaceTable(access: access)
        let client = FakePhiSyncClient()
        client.pageBudgetExhaustsAfter = 1_000     // Always report changesRemaining=true
        client.seed(tagHash: spaceHash("sync-1"),
                    ciphertext: try ciphertext(spaceEntity("sync-1")), version: 3)
        let clock = Clock()
        clock.advancePerRead = 50_000              // Advance 50 seconds per clock read
        let engine = makeEngine(access: access, store: store, client: client, clock: clock)

        let result = await engine.previewAccountSpaces()
        guard case .failure(let error) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(error, .timedOut, "truncated means page-budget exhaustion; timeout is distinct")
        // 120/50 seconds exceeds the deadline after two pages; allow one extra page
        // to avoid failing merely because another now() read was added.
        XCTAssertGreaterThan(client.getUpdatesCalls.count, 0)
        XCTAssertLessThanOrEqual(client.getUpdatesCalls.count, 3,
                                 "The deadline must stop pagination well before the 400-page budget")
    }

    /// 13. Exhausting the page budget returns truncated, without partial results.
    func testAnExhaustedPageBudgetReturnsTruncatedWithNoPartialResult() async throws {
        let access = FakePhiSpaceAccess()
        let store = MemorySpaceStore()
        store.table = makeSpaceTable(access: access)
        let client = FakePhiSyncClient()
        client.pageBudgetExhaustsAfter = 1_000     // Always report changesRemaining=true
        client.seed(tagHash: spaceHash("sync-1"),
                    ciphertext: try ciphertext(spaceEntity("sync-1")), version: 3)
        let engine = makeEngine(access: access, store: store, client: client)

        let result = await engine.previewAccountSpaces()
        guard case .failure(let error) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(error, .truncated)
    }

    /// 14. Filter settings, tombstones, undecryptable entities, both agent signatures,
    /// and default-space without writing unreadableTagHashes. Do not assert incognito:
    /// §3.4 removed refuses' UUID criterion in Task 3, so incognito-shaped payloads can pass.
    func testThePreviewFiltersSettingsTombstonesUnreadablesAgentsAndTheDefaultSpace() async throws {
        let access = FakePhiSpaceAccess()
        let store = MemorySpaceStore()
        store.table = makeSpaceTable(access: access)
        let client = FakePhiSyncClient()
        client.seed(ciphertext: Data([0x01]), version: 2)                        // Settings entity
        client.seed(tagHash: spaceHash("sync-dead"), ciphertext: Data(), version: 3,
                    deleted: true)                                               // tombstone
        client.seed(tagHash: "garbage-hash", ciphertext: Data([0x09]), version: 3) // Undecryptable
        client.seed(tagHash: spaceHash(SyncableSpaces.defaultSpaceUuid),
                    ciphertext: try ciphertext(spaceEntity(SyncableSpaces.defaultSpaceUuid)),
                    version: 3)                                                  // Default Space
        // Both agent signatures exactly match the pair asserted in SyncableSpacesTests.
        func agentShaped(_ uuid: String, name: String, color: String) throws -> Data {
            var entity = spaceEntity(uuid, name: name)
            var icon = Phi_PhiSettingValue(); icon.updatedAtMs = 100; icon.stringValue = "emoji:1F916"
            entity.iconName = icon
            var hex = Phi_PhiSettingValue(); hex.updatedAtMs = 100; hex.stringValue = color
            entity.colorHex = hex
            return try ciphertext(entity)
        }
        client.seed(tagHash: spaceHash("sync-agent"),
                    ciphertext: try agentShaped("sync-agent", name: "R3", color: "#8E8E93"),
                    version: 3)                                              // ephemeral agent
        client.seed(tagHash: spaceHash("sync-agent-p"),
                    ciphertext: try agentShaped("sync-agent-p", name: "task-42", color: "#5856D6"),
                    version: 3)                                              // persistent agent
        client.seed(tagHash: spaceHash("sync-ok"),
                    ciphertext: try ciphertext(spaceEntity("sync-ok", name: "Work")), version: 3)
        let engine = makeEngine(access: access, store: store, client: client)

        let result = await engine.previewAccountSpaces()
        guard case .success(let summaries) = result else { return XCTFail("expected success") }
        XCTAssertEqual(summaries.map(\.syncUuid), ["sync-ok"])
        XCTAssertFalse(summaries.contains { $0.isDefault },
                       "isDefault is always false because default Spaces are excluded (§4.3 rule 6)")
        XCTAssertTrue(store.table.unreadableTagHashes.isEmpty, "Preview writes no persistent state")
    }

    /// 15. Copy D7's three fields exactly without normalization. Incorrect normalization
    /// can silently hide every difference in the UI.
    func testThePreviewCarriesTheThemeAndOpacityEncodingsVerbatim() async throws {
        let access = FakePhiSpaceAccess()
        let store = MemorySpaceStore()
        store.table = makeSpaceTable(access: access)
        var entity = spaceEntity("sync-1", name: "Work")
        var theme = Phi_PhiSettingValue(); theme.updatedAtMs = 1; theme.stringValue = "coral"
        entity.themeID = theme
        var light = Phi_PhiSettingValue(); light.updatedAtMs = 1; light.intValue = 850
        entity.overlayOpacityLight = light
        var dark = Phi_PhiSettingValue(); dark.updatedAtMs = 1; dark.intValue = -1
        entity.overlayOpacityDark = dark
        let client = FakePhiSyncClient()
        client.seed(tagHash: spaceHash("sync-1"), ciphertext: try ciphertext(entity), version: 3)
        let engine = makeEngine(access: access, store: store, client: client)

        let result = await engine.previewAccountSpaces()
        guard case .success(let summaries) = result, let summary = summaries.first else {
            return XCTFail("expected one summary")
        }
        XCTAssertEqual(summary.themeId, "coral")
        XCTAssertEqual(summary.overlayOpacityLightMilli, 850)
        XCTAssertEqual(summary.overlayOpacityDarkMilli, -1, "Preserve the -1 sentinel without converting it to nil or zero")
        XCTAssertEqual(summary.profileUuid, "uuid-a")
    }

    // MARK: - CASE 2a.9 / 2a.10(a)（R-M3-4a-83 / R-M3-4a-16）

    /// CASE 2a.9: refreshCaches is never called when writeSpaceTable returns false.
    /// Observe localSpaceIdLookup, called once per hiddenSyncUuids member: it is
    /// refreshCaches' only externally observable side effect, while cached properties
    /// are private(set) and proving an async Task absent is weak.
    /// Use the closed-gate path with recordsGatedMarkerMoves: advancing the first
    /// page's marker writes the Space table exactly once. This checks R-M3-4a-83's
    /// second boundary. Scheduling refreshCaches outside successful save would expose
    /// unpersisted hiddenSpaceIds and hide a live Space until restart. Include the
    /// positive control, or deleting refreshCaches altogether would also pass.
    func testAFailedSpaceTableWriteSkipsTheMainActorCacheRefresh() async throws {
        let access = FakePhiSpaceAccess()
        let store = MemorySpaceStore()
        var hidden = PhiSpaceCursor()
        hidden.entityId = "srv-h"
        hidden.version = 1
        hidden.hidden = true
        hidden.deletedAtMs = 1
        store.table.cursors["sync-hidden"] = hidden
        store.failNextSave = true
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([remoteSettingsEntity(key: "theme.dark", value: "on",
                                                           version: 10, key: key)],
                                     marker: "m1")]
        let counter = LookupCounter()
        PhiSpaceSyncState.shared.localSpaceIdLookup = { _ in counter.bump(); return nil }
        let drainedBefore = PhiSpaceSyncState.shared.hasDrainedFullReplay

        // Keep the gate closed; do not enable Space sync.
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.pullOnce()
        await Task.yield()   // Yield the main actor so the scheduled refresh task can run

        XCTAssertEqual(store.saveCalls, 1, "One write attempt without internal retry")
        XCTAssertEqual(counter.calls, 0, "A failed write never refreshes main-thread caches")
        XCTAssertEqual(PhiSpaceSyncState.shared.hasDrainedFullReplay, drainedBefore,
                       "The failed round advances no main-thread cache state")

        store.failNextSave = false
        client.scriptedPages = [page([remoteSettingsEntity(key: "theme.dark", value: "off",
                                                           version: 11, key: key)],
                                     marker: "m2")]
        await engine.pullOnce()
        await Task.yield()

        XCTAssertEqual(store.saveCalls, 2, "Rollback keeps the guard correct and permits a second write attempt")
        XCTAssertGreaterThanOrEqual(counter.calls, 1, "Positive control: successful persistence refreshes caches")
    }

    /// CASE 2a.10(a): early return for nil spaceStore is not failure. A settings-only
    /// M3-1 engine legitimately has none. Returning false from the nil-store guard
    /// would stop marker advancement and settings sync when Task 2b lands, so this
    /// regression must be covered already in 2a. The Bool is not yet observable
    /// because both callers discard it; assert a normal completed settings round
    /// and zero Space-store calls, since no store exists.
    func testASettingsOnlyEngineStillAdvancesItsMarkerWithNoSpaceStore() async throws {
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([remoteSettingsEntity(key: "theme.dark", value: "on",
                                                           version: 10, key: key)],
                                     marker: "m1")]
        let engine = PhiSyncEngine(domainKeys: StubDomainKeys(key: key), client: client,
                                   defaults: defaults, deviceKeyId: "devA", pairingComplete: true, settings: [],
                                   spaceAccess: nil, spaceStore: nil,
                                   now: { 1_700_000_000_000 })

        await engine.pullOnce()

        XCTAssertEqual(defaults.data(forKey: PhiSyncEngine.markerStateKey), Data("m1".utf8),
                       "The marker advances normally")
        XCTAssertNotNil(defaults.data(forKey: PhiSyncEngine.lastEntityStateKey),
                        "Settings apply normally")
    }
}

// MARK: - C2 / R2.1: what the hybrid logical clock observes

extension PhiSyncEngineSpaceTests {

    private var hlcMax: Int64? {
        (defaults.object(forKey: PhiSyncEngine.hlcMaxStateKey) as? NSNumber)?.int64Value
    }

    /// Landing an entity folds its LWW stamps into logical time, so the next stamp this device
    /// issues cannot fall under a value it has just merged.
    func testLandingASpaceEntityRaisesTheHybridClockToItsStamps() async throws {
        let access = FakePhiSpaceAccess()
        let store = MemorySpaceStore()
        store.table = makeSpaceTable(mappings: ["s-1": "u1"], access: access)
        let client = FakePhiSyncClient()
        var entity = spaceEntity("u1")
        entity.name.updatedAtMs = 9_000_000
        client.seed(tagHash: spaceHash("u1"), ciphertext: try ciphertext(entity), version: 3)
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)

        await engine.pullOnce()

        XCTAssertEqual(hlcMax, 9_000_000)
    }

    /// `created_at_ms` is NOT a logical stamp: it is a creation instant merged with `min()`, and
    /// a peer (or a broken clock) claiming the year 2099 must not drag the whole account's
    /// logical time with it -- every later stamp on every device would inherit the skew.
    func testAYear2099CreationDateDoesNotRaiseTheHybridClock() async throws {
        let access = FakePhiSpaceAccess()
        let store = MemorySpaceStore()
        store.table = makeSpaceTable(mappings: ["s-1": "u1"], access: access)
        let client = FakePhiSyncClient()
        var entity = spaceEntity("u1")
        let year2099: Int64 = 4_070_908_800_000
        entity.createdAtMs = year2099
        client.seed(tagHash: spaceHash("u1"), ciphertext: try ciphertext(entity), version: 3)
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)

        await engine.pullOnce()

        XCTAssertLessThan(try XCTUnwrap(hlcMax), year2099,
                          "a creation instant must never become the account's logical time")
    }
}

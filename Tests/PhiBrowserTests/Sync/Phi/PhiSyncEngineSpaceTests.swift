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
        func load() -> PhiSpaceSyncTable { table }
        func save(_ table: PhiSpaceSyncTable) { self.table = table }
    }

    /// The engine's clock, so a test can step past `profileRefreshMinIntervalMs`
    /// instead of sleeping. `now:` is already an init parameter.
    final class Clock {
        var nowMs: Int64 = 1_700_000_000_000
    }

    private var defaults: UserDefaults!
    private var suiteName: String!
    private let key = SymmetricKey(size: .bits256)

    override func setUp() {
        super.setUp()
        suiteName = "PhiSyncEngineSpaceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil; suiteName = nil
        super.tearDown()
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

    /// M3-2b：游标按 syncUuid 键，本地行按本地 spaceId 键，两者由 `access` 上的
    /// 映射表连起来。凡是带「身份」的 fixture 一律经这个辅助建，于是「这条 fixture
    /// 到底用的哪个空间」在每一个用例里都是显式的。
    ///
    /// 排水位是写死的，所以**断言它的反面**的 fixture 不经这里，仍手写
    /// `PhiSpaceSyncTable()`：drain / marker 用例断言 `hasDrainedFullReplay == false`。
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
                            clock: Clock = Clock()) -> PhiSyncEngine {
        PhiSyncEngine(domainKeys: StubDomainKeys(key: key), client: client,
                      defaults: defaults, deviceKeyId: "devA",
                      settings: [],
                      spaceAccess: access, spaceStore: store,
                      now: { clock.nowMs })
    }

    /// Space-tagged commit entries only. The settings entity rides the same
    /// `commits` list and is not what any of these tests is about.
    private func spaceCommits(_ client: FakePhiSyncClient) -> [FakePhiSyncClient.CommitCall] {
        client.commits.filter { $0.clientTagHash != PhiSyncEntity.settingsClientTagHash }
    }

    // MARK: - Routing (§5.2)

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
        // field 3 of the oneof: a future client's payload.
        client.seed(tagHash: "future-hash",
                    ciphertext: try PhiKeyCrypto.sealWithSymmetric(Data([0x1A, 0x00]), key: key),
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

    func testNotMyBirthdayClearsServerTriplesAndGuardsButKeepsReconciled() async throws {
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
        await engine.pullOnce()

        let after = try XCTUnwrap(store.table.cursors["sync-1"])
        XCTAssertNil(after.entityId)
        XCTAssertEqual(after.version, 0)
        XCTAssertNil(after.server)
        XCTAssertEqual(after.deleteRejectRounds, 0)
        XCTAssertEqual(after.reconciled, Data([0x01]), "local timestamp history survives")
        XCTAssertTrue(store.table.unreadableTagHashes.isEmpty)
        // The reset re-arms guard 1; the retry pull that immediately follows it
        // replays the whole type from a nil marker and drains it again, which is
        // exactly what "re-armed" is supposed to produce.
        XCTAssertTrue(store.table.hasDrainedFullReplay)
        XCTAssertFalse(store.table.drainInProgress)
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

    /// ...and it must finish the drain by *replaying* it, not by continuing over the hole the
    /// failure left. An interrupted round consumed its pages: the shared marker moved past
    /// them for good, while everything the routing decoded from them (`SpacePullBatch.decoded`
    /// / `.tombstones` — Task 9's apply input) died with the throw. A later round resuming
    /// from that advanced marker would reach `drained == true` and stamp
    /// `hasDrainedFullReplay = true` over the gap, and from then on *neither* disjunct in
    /// `applySpaceGate` can re-arm the replay: `markerMovedWhileGateShut` is false (the gate
    /// was open the whole time) and `hasDrainedFullReplay` is true. The Spaces page 1 carried
    /// would be missing until some peer happened to touch them, and Task 9's `pushSpaces`
    /// would publish against a Space set this device never fully received. Dropping the
    /// marker on the failure path makes the drain restart instead; `drainInProgress` stays
    /// true, so nothing in between may declare it complete.
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
                     "a gapped drain drops the marker instead of counting page 1 as delivered")
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

    /// §6.2 A0 / §3.6's "唯一的例外, 也是死映射的唯一自愈路径". The reverse
    /// lookup resolves, but the local Chromium profile behind the mapping was
    /// deleted, so every landing would throw on a profileId that no longer
    /// exists and the entity would park forever with no self-heal path.
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
        var rebound = spaceEntity("sync-1", profileUuid: "uuid-新")
        rebound.profileUuid.updatedAtMs = 500
        client.seed(tagHash: spaceHash("sync-1"), ciphertext: try ciphertext(rebound), version: 8)
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()
        XCTAssertEqual(store.table.cursors["sync-1"]?.heldProfileUuid, "uuid-新")
        XCTAssertEqual(store.table.cursors["sync-1"]?.heldForLocalProfileId, "Default")
        XCTAssertTrue(spaceCommits(client).isEmpty, "a held binding never produces a commit")

        // §3.6 creates the profile on the next round. Driven directly here for
        // the same reason as the dead-mapping case above.
        access.profileIdByUuid["uuid-新"] = "P-new"
        access.uuidByProfileId["P-new"] = "uuid-新"
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
        access.uuidByProfileId = ["Default": "uuid-a", "P-new": "uuid-新"]
        access.profileIdByUuid = ["uuid-a": "Default", "uuid-新": "P-new"]
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
        var baseline = spaceEntity("sync-1", name: "Work2", profileUuid: "uuid-新")
        baseline.name.updatedAtMs = 800
        baseline.profileUuid.updatedAtMs = 900
        var rebound = spaceEntity("sync-1", name: "Work", profileUuid: "uuid-新")
        rebound.profileUuid.updatedAtMs = 900
        var seeded = PhiSpaceCursor()
        seeded.entityId = "srv-1"; seeded.version = 9
        seeded.reconciled = try baseline.serializedData()
        seeded.server = try rebound.serializedData()
        seeded.heldProfileUuid = "uuid-新"
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
        XCTAssertEqual(sent.profileUuid.stringValue, "uuid-新")
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

        XCTAssertEqual(store.table.cursors["sync-1"]!.server,
                       try rebound.serializedData(),
                       "server must be the entity we pulled, not the merge result")
        let commits = spaceCommits(client)
        XCTAssertEqual(commits.count, 1)
        let sent = try Phi_PhiSpaceEntity(serializedBytes:
            try PhiEntityCodec.decrypt(commits[0].ciphertext!, key: key).space.serializedData())
        XCTAssertEqual(sent.name.stringValue, "Work2")
        XCTAssertEqual(sent.profileUuid.stringValue, "uuid-b")
        XCTAssertEqual(commits[0].baseVersion, 9)
    }

    /// §5.2 改动三, in the direction the settings path used to swallow: the
    /// Space section must publish even when the account's SETTINGS entity is
    /// unreadable. `maySettingsPublish == false` and `pushSettings`'s early
    /// returns are statements about one settings row, not about Spaces.
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
        let store = MemorySpaceStore()
        store.table = makeSpaceTable(access: access)
        var cursor = PhiSpaceCursor()
        cursor.entityId = "srv-1"; cursor.version = 6
        cursor.reconciled = try spaceEntity("sync-1").serializedData()
        cursor.server = cursor.reconciled
        cursor.pendingDelete = true
        store.table.cursors["sync-1"] = cursor
        let client = FakePhiSyncClient()
        // The row the cursor points at, already tombstoned: the fake's update
        // path THROWS on a missing row, which would abandon the whole batch
        // before any outcome was applied. Seeding it as a tombstone also keeps
        // the pull that precedes the push free of side effects — a deleted
        // entity is routed to `batch.tombstones`, whose apply path is Task 14.
        client.seed(tagHash: spaceHash("sync-1"), ciphertext: Data(),
                    version: 6, entityId: "srv-1", deleted: true)
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pushLocalSettings()

        let commits = spaceCommits(client)
        XCTAssertEqual(commits.count, 1)
        XCTAssertTrue(commits[0].deleted)
        XCTAssertNil(commits[0].ciphertext)
        XCTAssertEqual(commits[0].name, PhiSyncEntity.spaceEntityName)
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
        client.seed(tagHash: spaceHash("sync-1"), ciphertext: Data(),
                    version: 6, entityId: "srv-1", deleted: true)
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

    func testTheDefaultSpaceTombstoneIsIgnored() async throws {
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
        XCTAssertNil(store.table.cursors[SyncableSpaces.defaultSpaceUuid]?.deletedAtMs)
        XCTAssertTrue(access.calls.filter { $0 == .hide(LocalStore.defaultSpaceId) }.isEmpty)
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

    /// 7b. 30 天清理：`purge` 收到**本地** id、映射行被删、游标仍在且带 `purgedAtMs`。
    /// （这条就是原来的 `testTheSweepCascadesTheDataAndKeepsThePermanentTombstone`，
    /// 改键之后连同映射生命周期一起断言；`reconciled` 那一条原样保留。）
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
        let cursor = try XCTUnwrap(store.table.cursors["sync-1"], "游标是永久 tombstone 记录")
        XCTAssertNotNil(cursor.purgedAtMs)
        XCTAssertNotNil(cursor.deletedAtMs)
        XCTAssertNil(cursor.reconciled, "`purgeExpired` 一并清掉基线")
    }

    /// 7d. 级联失败 ⇒ 映射**不许**被删。删了就等于让下一趟 `pushSpaces` 拿这条还在
    /// 盘上的本地行走懒铸造（`ensureMapped`）铸一个**新** syncUuid，把一条刚被清理掉
    /// 的 Space 以新身份重新发布出去；而 Phase 1 已经盖上 `purgedAtMs`，清理不会再来
    /// 第二次，复活是永久的。D6 之前同一处 `try?` 无害：游标那时按本地 id 键，
    /// `snapshot` 的 `cursor.deletedAtMs == nil` 过滤永远排除它。
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
                       "purge 失败 ⇒ 映射留着，syncUuid 仍指向那条带 deletedAtMs 的游标")
        await engine.pushLocalSettings()   // 引擎里唯一的公开 push 入口
        XCTAssertTrue(spaceCommits(client).isEmpty,
                      "那条还在盘上的本地行不许以任何身份被重新发布")
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

    /// §5.3's single writer, in the shape the spec names verbatim: "一轮 snapshot
    /// 读表 → 用户删除一个 Space → 引擎用手里的旧快照 writeSpaceTable"。
    ///
    /// `pushSpaces` loads the table before its batch loop and writes it back
    /// after `client.commit`, so a delete that ran *inside* that window on the
    /// reentrant actor would be erased by the tail write -- permanently and
    /// silently: no `pendingDelete` means the uuid never enters
    /// `spaceCommitEntries`' union again, so no tombstone is ever sent and, with
    /// no `deletedAtMs` either, the next delivery of that entity re-creates the
    /// Space the user deleted. Routing the intent through `roundQueue` is what
    /// makes that impossible, and both assertions below are about the queue: the
    /// intent must not have landed while the round is parked, and it must have
    /// landed once the round is done.
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

    // MARK: - D6：入站身份翻译（§3.4）

    /// 1. 账户里有、本机没有的 Space：新建一行本地 id，落地成功之后才写映射。
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
        XCTAssertNotEqual(created.spaceId, "sync-new", "线上 uuid 绝不当本地行 id 用")
        XCTAssertEqual(access.spaceMappings[created.spaceId], "sync-new")
        XCTAssertNotNil(store.table.cursors["sync-new"]?.reconciled)
    }

    /// 1b. `create` 抛错的那一版：映射**没有**被写、基线**没有**被写、实体留在
    /// `pendingApply`。重试会再次走 create 分支，因为没有映射行、不会撞上半成品。
    func testAFailedCreateWritesNeitherAMappingNorABaseline() async throws {
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

        XCTAssertTrue(access.spaceMappings.isEmpty)
        XCTAssertNil(store.table.cursors["sync-new"]?.reconciled)
        XCTAssertNotNil(store.table.cursors["sync-new"]?.pendingApply)
    }

    /// 2. 已映射的 Space：`create` 零调用，三个写方法收到的都是**本地** id。
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

    /// 3. 反查落空 ⇒ 新建而不是复活：本机有一个同名 Space（无映射）时，引擎**不**去
    /// 认领它——认领是向导的职责，引擎不猜。
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

        XCTAssertEqual(access.spaces.count, 2, "同名不是身份")
        // 本轮尾部的 push 会给这条从未上过账户的本地行**懒铸**一个自己的 uuid
        // （R-D6-7），所以判据是「它没有被账户里那条实体认领」，不是「它没有映射」。
        XCTAssertNotEqual(access.spaceMappings["LOCAL-1"], "sync-x")
    }

    /// 4. 两个本地 Space 永远不会映射到同一个 syncUuid：预置一条，再落地同一个 uuid。
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

    /// 4b. 死映射自愈：反查命中但本地行不在 ⇒ 丢映射、按无映射处理、当新 Space 落地。
    func testADeadSpaceMappingIsDroppedAndTheEntityLandsAsANewSpace() async throws {
        let access = FakePhiSpaceAccess()
        access.uuidByProfileId = ["Default": "uuid-a"]
        access.profileIdByUuid = ["uuid-a": "Default"]
        access.spaces = []                       // 本地行没了
        access.knownLocalSpaceIds = []           // `getAllSpaces()` 里也没有
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

    /// 5. ranks 的边界翻译：`applyOrder` 收到的必须是一串**本地** id。
    ///    把翻译去掉的那一版是**静默 no-op**，所以这条用例的反证在
    ///    `SyncableSpacesTests.testPlannedOrderIsASilentNoOpWhenHandedSyncUuidKeys`。
    func testTheAccountWideReorderIsAppliedWithLocalIds() async throws {
        let access = FakePhiSpaceAccess()
        access.uuidByProfileId = ["Default": "uuid-a"]
        access.profileIdByUuid = ["uuid-a": "Default"]
        access.spaces = [localSpace("LOCAL-1", "A", order: 0), localSpace("LOCAL-2", "B", order: 1)]
        let store = MemorySpaceStore()
        store.table = makeSpaceTable(mappings: ["LOCAL-1": "sync-1", "LOCAL-2": "sync-2"],
                                     access: access)
        let client = FakePhiSyncClient()
        // "F" < "V"：账户里 sync-2 排在 sync-1 前面。
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

    /// 6a. tombstone：syncUuid 有本地行 ⇒ `hide` 收到**本地** id。
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
                       "远端软删**保留**映射：它是 30 天里「这一行属于账户的哪条实体」的唯一记录")
    }

    /// 6b. syncUuid **没有**本地行 ⇒ `hide` 零调用，游标**照样**写 `hidden` +
    ///     `deletedAtMs`：账户里那条确实被删了，这台机器只是本来就没有它，游标必须
    ///     记住，否则同一条实体的 create 重放会把它复活。
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
        XCTAssertNotNil(cursor.deletedAtMs, "防复活守卫读的就是它")
    }

    func testTheTagIndexIsSeededFromTheMappingTableSoAnUncommittedSpaceCanBeTombstoned() async throws {
        // 一个刚被向导映射、还没 commit 过的 Space（有映射行、没有游标）的 tombstone
        // 必须能被识别。
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

    /// 7a. 本地删除 → tombstone `.applied` ⇒ **映射行被删、游标留下**（R-D6-10）。
    func testALocalDeleteDropsTheMappingWhenItsTombstoneIsAccepted() async throws {
        let access = FakePhiSpaceAccess()
        access.uuidByProfileId = ["Default": "uuid-a"]
        access.profileIdByUuid = ["uuid-a": "Default"]
        access.spaces = [localSpace("LOCAL-1", "Work", order: 0)]
        // 本地行下面会从 `spaces` 里删掉，但映射不是死映射：否则 Task 3 的自愈
        // （`applySpaces` 的 `isKnownLocalSpace` 分支）会抢先删掉映射，本用例就
        // 测不到 Step 4 的那一段。
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
        // 先跑一轮，让共享 marker 越过这条实体：下一轮 push 的初始 pull 就不会把它
        // 重放回来，本地行也不会被重新落地。
        await engine.pullOnce()

        access.spaces = []                                   // 本地行已经删了
        await engine.recordLocalDeletion(spaceId: "LOCAL-1") // 门面收的是**本地** id
        await engine.handleLocalSpacesChange()               // 一轮 push：tombstone 发出并被接受

        XCTAssertTrue(spaceCommits(client).contains { $0.deleted })
        XCTAssertTrue(access.calls.filter { if case .create = $0 { return true }; return false }.isEmpty,
                      "映射是被 `.applied` 的 tombstone 删掉的，不是被死映射自愈顺手删掉的")
        XCTAssertNil(access.spaceMappings["LOCAL-1"], "映射行随 `.applied` 一起删")
        let cursor = try XCTUnwrap(store.table.cursors["sync-1"])
        XCTAssertNotNil(cursor.deletedAtMs, "游标留下：永久 tombstone 记录")
        XCTAssertFalse(cursor.pendingDelete)
    }

    /// 7c. 清理之后重放同一条 tombstone 是 no-op，snapshot 也不复活该 uuid。
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

        XCTAssertTrue(access.spaces.isEmpty, "软删过的 uuid 不会被一次 create 重放复活")
        XCTAssertTrue(spaceCommits(client).isEmpty)
    }

    /// 8. `recordLocalDeletion` 的边界翻译：门面传本地 id；无映射 ⇒ **no-op**
    ///    （不建游标、不发 commit）。
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

        await engine.recordLocalDeletion(spaceId: "LOCAL-2")   // 从来没发布过
        XCTAssertEqual(store.table.cursors.count, 1, "无映射 = 无 tombstone 可发，不建游标")
    }

    /// 9. 懒铸造（R-D6-7）：向导之后本机新建的 Space 恰好铸一次，第二轮不再铸。
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
                       "第二轮不再铸——`ensureMapped` 命中既有映射就直接返回")
    }

    /// 10. `formatVersion` 重置后的自愈（§3.6）：空表 + 非 nil marker ⇒ 门开边沿丢
    ///     marker、重放整类型、`drainInProgress` 置真、回放收尾前一条 commit 都不发；
    ///     `hadRecords == false` 所以保护② **不**同时触发（只回放一次，不是两次）。
    func testAnEmptyTableAfterTheFormatCutReplaysExactlyOnce() async throws {
        let access = FakePhiSpaceAccess()
        access.uuidByProfileId = ["Default": "uuid-a"]
        access.profileIdByUuid = ["uuid-a": "Default"]
        access.spaces = [localSpace("LOCAL-1", "Work", order: 0)]
        // 硬切之后的盘上状态：空表（`hadRecords == false`、`hasDrainedFullReplay ==
        // false`）+ 一个上个版本留下的 marker。
        defaults.set(Data([0xAB]), forKey: PhiSyncEngine.markerStateKey)
        let store = MemorySpaceStore()
        store.table = PhiSpaceSyncTable()
        let client = FakePhiSyncClient()
        client.seed(tagHash: spaceHash("sync-1"),
                    ciphertext: try ciphertext(spaceEntity("sync-1")), version: 3)
        let engine = makeEngine(access: access, store: store, client: client)

        await engine.setSpaceSyncEnabled(true)
        XCTAssertNil(defaults.data(forKey: PhiSyncEngine.markerStateKey),
                     "门开边沿丢 marker 并重放整个 data type")
        XCTAssertTrue(store.table.drainInProgress)
        XCTAssertFalse(store.table.didReplayForEmptyTable,
                       "`hadRecords == false` ⇒ 保护② 不参与，只回放一次")

        await engine.pullOnce()
        XCTAssertTrue(store.table.hasDrainedFullReplay)
        XCTAssertFalse(store.table.didReplayForEmptyTable)
        XCTAssertEqual(client.getUpdatesCalls.first?.marker, nil)
    }

    // MARK: - 预览（§4）

    /// 11. 预览什么都不写。
    func testThePreviewPersistsNothingAtAll() async throws {
        let access = FakePhiSpaceAccess()
        let store = MemorySpaceStore()
        store.table = makeSpaceTable(access: access)
        let client = FakePhiSyncClient()
        client.seed(tagHash: spaceHash("sync-1"),
                    ciphertext: try ciphertext(spaceEntity("sync-1", name: "Work")), version: 3)
        let engine = makeEngine(access: access, store: store, client: client)
        // 门**关着**：预览是唯一一条允许在门关着时执行的 Space 形状的读。
        defaults.set(Data([0xAB]), forKey: PhiSyncEngine.markerStateKey)
        let tableBefore = store.table

        let result = await engine.previewAccountSpaces()
        guard case .success(let summaries) = result else { return XCTFail("expected success") }
        XCTAssertEqual(summaries.map(\.syncUuid), ["sync-1"])

        XCTAssertEqual(defaults.data(forKey: PhiSyncEngine.markerStateKey), Data([0xAB]),
                       "marker 一个字节都不动")
        XCTAssertNil(defaults.string(forKey: PhiSyncEngine.entityIdStateKey))
        XCTAssertNil(defaults.object(forKey: PhiSyncEngine.versionStateKey))
        XCTAssertEqual(store.table, tableBefore, "Space 表 Equatable 意义上完全未变")
        XCTAssertTrue(access.calls.isEmpty, "`PhiSpaceLocalAccess` 零调用")
        XCTAssertTrue(client.commits.isEmpty, "零 commit")

        // 紧接着一次正常 pull 仍从**原来的** marker 出发。
        await engine.setSpaceSyncEnabled(false)
        await engine.pullOnce()
        XCTAssertEqual(client.getUpdatesCalls.last?.marker, Data([0xAB]))
    }

    /// 12. 预览排在同一条 round 队列上：一次设置 pull 停在 `getUpdates` 上时，预览的
    ///     第一个 `getUpdates` 严格在那次 pull 完成之后才发出。
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
        await arrived.wait()                       // 一轮 pull 已经停在 getUpdates 里
        let preview = Task { await engine.previewAccountSpaces() }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(client.getUpdatesCalls.count, 1, "预览没有插进去")
        await release.open()
        _ = await pull.value
        _ = await preview.value
        XCTAssertGreaterThan(client.getUpdatesCalls.count, 1)
    }

    /// 13. 页预算用尽 ⇒ `.truncated`，**没有部分结果**。
    func testAnExhaustedPageBudgetReturnsTruncatedWithNoPartialResult() async throws {
        let access = FakePhiSpaceAccess()
        let store = MemorySpaceStore()
        store.table = makeSpaceTable(access: access)
        let client = FakePhiSyncClient()
        client.pageBudgetExhaustsAfter = 1_000     // 永远 changesRemaining == true
        client.seed(tagHash: spaceHash("sync-1"),
                    ciphertext: try ciphertext(spaceEntity("sync-1")), version: 3)
        let engine = makeEngine(access: access, store: store, client: client)

        let result = await engine.previewAccountSpaces()
        guard case .failure(let error) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(error, .truncated)
    }

    /// 14. 过滤：设置实体 / tombstone / 解不开的实体 / 两种 agent 特征 /
    ///     `spaceUuid == "default-space"` 各一条都不出现，`unreadableTagHashes` 未被写。
    ///     **这里不断言 incognito**：§3.4 删掉了 `refuses` 里的 uuid 判据（Task 3），
    ///     一条「incognito 形状」的载荷本来就过得去。
    func testThePreviewFiltersSettingsTombstonesUnreadablesAgentsAndTheDefaultSpace() async throws {
        let access = FakePhiSpaceAccess()
        let store = MemorySpaceStore()
        store.table = makeSpaceTable(access: access)
        let client = FakePhiSyncClient()
        client.seed(ciphertext: Data([0x01]), version: 2)                        // 设置实体
        client.seed(tagHash: spaceHash("sync-dead"), ciphertext: Data(), version: 3,
                    deleted: true)                                               // tombstone
        client.seed(tagHash: "garbage-hash", ciphertext: Data([0x09]), version: 3) // 解不开
        client.seed(tagHash: spaceHash(SyncableSpaces.defaultSpaceUuid),
                    ciphertext: try ciphertext(spaceEntity(SyncableSpaces.defaultSpaceUuid)),
                    version: 3)                                                  // 默认 Space
        // 两条 agent 特征（值与 `SyncableSpacesTests` 里钉住的那对完全一致）。
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
                       "`isDefault` 在返回值里恒为 false —— 默认 Space 整条被丢掉（§4.3 第 6 条）")
        XCTAssertTrue(store.table.unreadableTagHashes.isEmpty, "预览不写任何持久状态")
    }

    /// 15. D7 要的三个字段**逐字**搬运，不做任何归一化。一次错误的归一化在界面上表现
    ///     为「什么差异都算不出来」，没有任何其它信号。
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
        XCTAssertEqual(summary.overlayOpacityDarkMilli, -1, "-1 哨兵原样带出，不换成 nil、不换成 0")
        XCTAssertEqual(summary.profileUuid, "uuid-a")
    }
}

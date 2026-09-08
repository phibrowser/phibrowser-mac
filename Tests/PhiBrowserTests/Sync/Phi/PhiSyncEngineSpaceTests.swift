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

    private func ciphertext(_ entity: Phi_PhiSpaceEntity) throws -> Data {
        var wrapper = Phi_PhiEntity()
        wrapper.space = entity
        return try PhiEntityCodec.encrypt(wrapper, key: key)
    }

    private func spaceHash(_ uuid: String) -> String {
        PhiSyncEntity.clientTagHash(for: PhiSyncEntity.spaceClientTag(uuid))
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
        var cursor = PhiSpaceCursor()
        cursor.entityId = "srv-1"; cursor.version = 9
        cursor.reconciled = Data([0x01]); cursor.server = Data([0x02])
        cursor.deleteRejectRounds = 2
        store.table.cursors["u1"] = cursor
        store.table.firstSyncDecision = "keepBoth"
        store.table.hasDrainedFullReplay = true
        store.table.unreadableTagHashes["h"] = 1

        let client = FakePhiSyncClient()
        client.throwNotMyBirthdayOnce = true
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let after = try XCTUnwrap(store.table.cursors["u1"])
        XCTAssertNil(after.entityId)
        XCTAssertEqual(after.version, 0)
        XCTAssertNil(after.server)
        XCTAssertEqual(after.deleteRejectRounds, 0)
        XCTAssertEqual(after.reconciled, Data([0x01]), "local timestamp history survives")
        XCTAssertEqual(store.table.firstSyncDecision, "keepBoth")
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
        access.spaces = [PhiLocalSpace(spaceId: "u1", profileId: "Default", name: "Work",
                                       colorHex: "#3A6FF8", iconName: "emoji:1F4BC", sortOrder: 0,
                                       createdDate: Date(timeIntervalSince1970: 1),
                                       themeId: nil, opacityLight: nil, opacityDark: nil)]
        let store = MemorySpaceStore()
        store.table.hasDrainedFullReplay = true
        // `pushSpaces` refuses to publish anything until D2 has been answered
        // (§8). Task 13 is what sets this automatically ("no local-only Spaces"
        // or "empty account" -> keepBoth); until then every push-side fixture
        // seeds it explicitly, or it asserts commits that can never happen.
        store.table.firstSyncDecision = "keepBoth"
        let client = FakePhiSyncClient()
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.handleLocalSpacesChange()
        // The round really ran: `.localSpaceChange` reaches `push`, which pulls
        // first because this device has never synced.
        XCTAssertFalse(client.getUpdatesCalls.isEmpty)
        // ...and with Task 9 Step 4.0/4.1 in place the trigger now reaches
        // `pushSpaces`: `push` runs the settings half and then the Space half
        // unconditionally, so the one local Space is published this round.
        XCTAssertEqual(spaceCommits(client).count, 1)
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
        access.spaces = [PhiLocalSpace(spaceId: "u1", profileId: "Default", name: "Work",
                                       colorHex: "#3A6FF8", iconName: "emoji:1F4BC", sortOrder: 0,
                                       createdDate: Date(timeIntervalSince1970: 1),
                                       themeId: nil, opacityLight: nil, opacityDark: nil)]
        let store = MemorySpaceStore()
        var seeded = PhiSpaceCursor()
        seeded.entityId = "srv-1"; seeded.version = 3
        seeded.reconciled = try spaceEntity("u1").serializedData()
        seeded.server = seeded.reconciled
        store.table.cursors["u1"] = seeded
        store.table.hasDrainedFullReplay = true

        let client = FakePhiSyncClient()
        var rebound = spaceEntity("u1", profileUuid: "uuid-b")
        rebound.profileUuid.updatedAtMs = 500
        client.seed(tagHash: spaceHash("u1"), ciphertext: try ciphertext(rebound), version: 8)
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()
        XCTAssertTrue(access.calls.contains(.rebind(spaceId: "u1", toProfileId: "Profile 3")))
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
        XCTAssertTrue(access.calls.filter { $0 == .create("u1") }.isEmpty)
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
        access.spaces = [PhiLocalSpace(spaceId: "u1", profileId: "Default", name: "Work",
                                       colorHex: "#3A6FF8", iconName: "emoji:1F4BC", sortOrder: 0,
                                       createdDate: Date(timeIntervalSince1970: 1),
                                       themeId: nil, opacityLight: nil, opacityDark: nil)]
        let store = MemorySpaceStore()
        var seeded = PhiSpaceCursor()
        seeded.entityId = "srv-1"; seeded.version = 3
        seeded.reconciled = try spaceEntity("u1").serializedData()
        seeded.server = seeded.reconciled
        store.table.cursors["u1"] = seeded
        store.table.hasDrainedFullReplay = true
        store.table.firstSyncDecision = "keepBoth"

        let client = FakePhiSyncClient()
        var rebound = spaceEntity("u1", profileUuid: "uuid-新")
        rebound.profileUuid.updatedAtMs = 500
        client.seed(tagHash: spaceHash("u1"), ciphertext: try ciphertext(rebound), version: 8)
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()
        XCTAssertEqual(store.table.cursors["u1"]?.heldProfileUuid, "uuid-新")
        XCTAssertEqual(store.table.cursors["u1"]?.heldForLocalProfileId, "Default")
        XCTAssertTrue(spaceCommits(client).isEmpty, "a held binding never produces a commit")

        // §3.6 creates the profile on the next round. Driven directly here for
        // the same reason as the dead-mapping case above.
        access.profileIdByUuid["uuid-新"] = "P-new"
        access.uuidByProfileId["P-new"] = "uuid-新"
        access.knownLocalProfileIds = ["Default", "P-new"]
        await engine.pullOnce()
        XCTAssertTrue(access.calls.contains(.rebind(spaceId: "u1", toProfileId: "P-new")))
        XCTAssertNil(store.table.cursors["u1"]?.heldProfileUuid)
        XCTAssertNil(store.table.cursors["u1"]?.heldForLocalProfileId)
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
        access.uuidByProfileId = ["Default": "uuid-a"]
        access.profileIdByUuid = ["uuid-a": "Default"]
        access.knownLocalProfileIds = ["Default"]
        access.spaces = [PhiLocalSpace(spaceId: "u1", profileId: "Default", name: "Work2",
                                       colorHex: "#3A6FF8", iconName: "emoji:1F4BC", sortOrder: 0,
                                       createdDate: Date(timeIntervalSince1970: 1),
                                       themeId: nil, opacityLight: nil, opacityDark: nil)]
        let store = MemorySpaceStore()
        // This device holds the account's rename and has not published it yet.
        var baseline = spaceEntity("u1", name: "Work2")
        baseline.name.updatedAtMs = 800
        var seeded = PhiSpaceCursor()
        seeded.entityId = "srv-1"; seeded.version = 3
        seeded.reconciled = try baseline.serializedData()
        seeded.server = try spaceEntity("u1", name: "Work").serializedData()
        store.table.cursors["u1"] = seeded
        store.table.hasDrainedFullReplay = true
        // `firstSyncDecision` stays nil for this round on purpose: D2 is still
        // unanswered, so §8's guard stops the round from publishing the rename.
        // Any other reason a round does not publish (offline, a commit throw,
        // guard 1 re-armed) reaches the next round in exactly this state.

        let client = FakePhiSyncClient()
        // A peer that never saw the rename rebinds the Space onto a profile this
        // device does not have yet.
        var rebound = spaceEntity("u1", name: "Work", profileUuid: "uuid-新")
        rebound.profileUuid.updatedAtMs = 900
        client.seed(tagHash: spaceHash("u1"), ciphertext: try ciphertext(rebound), version: 9)
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()
        XCTAssertEqual(store.table.cursors["u1"]?.heldProfileUuid, "uuid-新")
        XCTAssertTrue(spaceCommits(client).isEmpty, "D2 is unanswered: nothing may be published")
        XCTAssertEqual(store.table.cursors["u1"]?.server, try rebound.serializedData())

        // §3.6 creates the profile, so the hold resolves and the baseline is
        // re-landed. Driven directly here for the same reason as the
        // dead-mapping case above: nothing calls `refreshAccountProfiles()`
        // until Task 11.
        access.profileIdByUuid["uuid-新"] = "P-new"
        access.uuidByProfileId["P-new"] = "uuid-新"
        access.knownLocalProfileIds = ["Default", "P-new"]
        store.table.firstSyncDecision = "keepBoth"   // Task 13 sets this automatically
        await engine.pullOnce()

        XCTAssertTrue(access.calls.contains(.rebind(spaceId: "u1", toProfileId: "P-new")))
        XCTAssertEqual(store.table.cursors["u1"]?.server,
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
        access.spaces = [PhiLocalSpace(spaceId: "u1", profileId: "Default", name: "Work2",
                                       colorHex: "#3A6FF8", iconName: "emoji:1F4BC", sortOrder: 0,
                                       createdDate: Date(timeIntervalSince1970: 1),
                                       themeId: nil, opacityLight: nil, opacityDark: nil)]
        let store = MemorySpaceStore()
        // This account renamed the Space to "Work2" and this device has the
        // rename in its baseline; the row on the server is still the older one.
        var baseline = spaceEntity("u1", name: "Work2")
        baseline.name.updatedAtMs = 800
        var seeded = PhiSpaceCursor()
        seeded.entityId = "srv-1"; seeded.version = 3
        seeded.reconciled = try baseline.serializedData()
        seeded.server = try spaceEntity("u1", name: "Work").serializedData()
        store.table.cursors["u1"] = seeded
        store.table.hasDrainedFullReplay = true
        store.table.firstSyncDecision = "keepBoth"   // Task 13 sets this automatically

        let client = FakePhiSyncClient()
        // A peer that has not seen the rename rebinds the Space: its own `name`
        // is still "Work" at the older timestamp, so the merge keeps "Work2".
        var rebound = spaceEntity("u1", name: "Work", profileUuid: "uuid-b")
        rebound.profileUuid.updatedAtMs = 900
        client.seed(tagHash: spaceHash("u1"), ciphertext: try ciphertext(rebound), version: 9)
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertEqual(store.table.cursors["u1"]!.server,
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
        access.spaces = [PhiLocalSpace(spaceId: "u1", profileId: "Default", name: "Work",
                                       colorHex: "#3A6FF8", iconName: "emoji:1F4BC", sortOrder: 0,
                                       createdDate: Date(timeIntervalSince1970: 1),
                                       themeId: nil, opacityLight: nil, opacityDark: nil)]
        let store = MemorySpaceStore()
        store.table.hasDrainedFullReplay = true
        store.table.firstSyncDecision = "keepBoth"
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
        access.spaces = [PhiLocalSpace(spaceId: "u1", profileId: "Default", name: "Work",
                                       colorHex: "#3A6FF8", iconName: "emoji:1F4BC", sortOrder: 0,
                                       createdDate: Date(timeIntervalSince1970: 1),
                                       themeId: nil, opacityLight: nil, opacityDark: nil)]
        let store = MemorySpaceStore()
        store.table.hasDrainedFullReplay = true
        store.table.firstSyncDecision = "keepBoth"
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
            PhiLocalSpace(spaceId: "u2", profileId: "Default", name: "Reading",
                          colorHex: "#111111", iconName: "phi:y", sortOrder: 1,
                          createdDate: Date(timeIntervalSince1970: 2),
                          themeId: nil, opacityLight: nil, opacityDark: nil),
        ]
        let store = MemorySpaceStore()
        store.table.firstSyncDecision = "keepBoth"   // Task 13 sets this automatically
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
        XCTAssertTrue(hashes.contains(spaceHash("u2")), "the readable Spaces still sync")

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
        var cursor = PhiSpaceCursor()
        cursor.entityId = "srv-1"; cursor.version = 6
        cursor.reconciled = try spaceEntity("u1").serializedData()
        cursor.server = cursor.reconciled
        cursor.pendingDelete = true
        store.table.cursors["u1"] = cursor
        store.table.hasDrainedFullReplay = true
        store.table.firstSyncDecision = "keepBoth"   // Task 13 sets this automatically
        let client = FakePhiSyncClient()
        // The row the cursor points at, already tombstoned: the fake's update
        // path THROWS on a missing row, which would abandon the whole batch
        // before any outcome was applied. Seeding it as a tombstone also keeps
        // the pull that precedes the push free of side effects — a deleted
        // entity is routed to `batch.tombstones`, whose apply path is Task 14.
        client.seed(tagHash: spaceHash("u1"), ciphertext: Data(),
                    version: 6, entityId: "srv-1", deleted: true)
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pushLocalSettings()

        let commits = spaceCommits(client)
        XCTAssertEqual(commits.count, 1)
        XCTAssertTrue(commits[0].deleted)
        XCTAssertNil(commits[0].ciphertext)
        XCTAssertEqual(commits[0].name, PhiSyncEntity.spaceEntityName)
        let after = try XCTUnwrap(store.table.cursors["u1"])
        XCTAssertFalse(after.pendingDelete)
        XCTAssertNotNil(after.deletedAtMs)
        XCTAssertNil(after.reconciled)
        XCTAssertNil(after.server)
        XCTAssertNotNil(after.entityId, "the cursor stays as a permanent tombstone record")
    }

    func testARejectedTombstoneIsResentUnchangedAndOnlyGivesUpAfterThree() async throws {
        let access = FakePhiSpaceAccess()
        let store = MemorySpaceStore()
        var cursor = PhiSpaceCursor()
        cursor.entityId = "srv-1"; cursor.version = 6
        cursor.reconciled = try spaceEntity("u1").serializedData()
        cursor.server = cursor.reconciled
        cursor.pendingDelete = true
        store.table.cursors["u1"] = cursor
        store.table.hasDrainedFullReplay = true
        store.table.firstSyncDecision = "keepBoth"   // Task 13 sets this automatically
        let client = FakePhiSyncClient()
        client.seed(tagHash: spaceHash("u1"), ciphertext: Data(),
                    version: 6, entityId: "srv-1", deleted: true)
        client.forceInvalidMessage = true
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)

        await engine.pushLocalSettings()
        var after = try XCTUnwrap(store.table.cursors["u1"])
        XCTAssertTrue(after.pendingDelete, "INVALID_MESSAGE does not prove the row is gone")
        XCTAssertEqual(after.deleteRejectRounds, 1)
        XCTAssertNil(after.deletedAtMs)
        XCTAssertEqual(after.entityId, "srv-1")

        client.forceInvalidMessage = false
        await engine.pushLocalSettings()
        after = try XCTUnwrap(store.table.cursors["u1"])
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
        var cursor = PhiSpaceCursor()
        cursor.entityId = "srv-1"; cursor.version = 6
        cursor.pendingDelete = true
        store.table.cursors["u1"] = cursor
        store.table.hasDrainedFullReplay = true
        store.table.firstSyncDecision = "keepBoth"   // Task 13 sets this automatically
        let client = FakePhiSyncClient()
        client.forceInvalidMessage = true
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        for _ in 0..<3 { await engine.pushLocalSettings() }
        XCTAssertFalse(store.table.cursors["u1"]!.pendingDelete)
        XCTAssertNotNil(store.table.cursors["u1"]!.deletedAtMs)
        let sent = spaceCommits(client).count
        await engine.pushLocalSettings()
        XCTAssertEqual(spaceCommits(client).count, sent, "no per-round resend loop")
    }

    func testAPendingDeleteWithNoEntityIdIsDroppedBeforeItIsSent() async throws {
        let access = FakePhiSpaceAccess()
        let store = MemorySpaceStore()
        var cursor = PhiSpaceCursor()
        cursor.pendingDelete = true      // never published: no entityId, version 0
        store.table.cursors["ghost"] = cursor
        store.table.hasDrainedFullReplay = true
        store.table.firstSyncDecision = "keepBoth"   // Task 13 sets this automatically
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
            PhiLocalSpace(spaceId: "u\(i)", profileId: "Default", name: "S\(i)",
                          colorHex: "#3A6FF8", iconName: "phi:x", sortOrder: i,
                          createdDate: Date(timeIntervalSince1970: TimeInterval(i)),
                          themeId: nil, opacityLight: nil, opacityDark: nil)
        }
        let store = MemorySpaceStore()
        store.table.hasDrainedFullReplay = true
        store.table.firstSyncDecision = "keepBoth"   // Task 13 sets this automatically
        let client = FakePhiSyncClient()
        client.conflictOnceForTagHashes = [spaceHash("u2")]
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pushLocalSettings()

        XCTAssertNotNil(store.table.cursors["u1"]?.server)
        XCTAssertNotNil(store.table.cursors["u3"]?.server)
        XCTAssertNotNil(store.table.cursors["u2"]?.server, "the conflicting one is retried, not dropped")
        // The retry is SCOPED: only the conflicting uuid goes back through the
        // wire, not the whole batch recomputed from scratch.
        XCTAssertEqual(spaceCommits(client).filter { $0.clientTagHash == spaceHash("u2") }.count, 2)
        for uuid in ["u1", "u3"] {
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
        store.table.firstSyncDecision = "keepBoth"   // Task 13 sets this automatically
        let client = FakePhiSyncClient()
        client.seed(tagHash: spaceHash("u1"),
                    ciphertext: try ciphertext(spaceEntity("u1")), version: 7)
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()
        let commitsAfterApply = spaceCommits(client).count
        XCTAssertEqual(commitsAfterApply, 0, "a pure remote apply publishes nothing")
        await engine.handleLocalSpacesChange()
        XCTAssertEqual(spaceCommits(client).count, commitsAfterApply)
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
        store.table.firstSyncDecision = "keepBoth"   // otherwise the push guard hides the point
        let client = FakePhiSyncClient()
        access.refreshOutcome = .failed
        client.seed(tagHash: PhiSyncEntity.clientTagHash(for: PhiSyncEntity.spaceClientTag("u1")),
                    ciphertext: try ciphertext(spaceEntity("u1")), version: 7)
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()
        XCTAssertTrue(access.calls.filter { $0 == .create("u1") }.isEmpty)
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

    // MARK: - §8 D2: the first-sync question

    private func localSpace(_ id: String, _ name: String, order: Int) -> PhiLocalSpace {
        PhiLocalSpace(spaceId: id, profileId: "Default", name: name, colorHex: "#3A6FF8",
                      iconName: "phi:x", sortOrder: order,
                      createdDate: Date(timeIntervalSince1970: TimeInterval(order + 1)),
                      themeId: nil, opacityLight: nil, opacityDark: nil)
    }

    func testTheQuestionIsAskedOnlyWhenBothSidesAreNonEmpty() async throws {
        let access = FakePhiSpaceAccess()
        access.uuidByProfileId = ["Default": "uuid-a"]
        access.profileIdByUuid = ["uuid-a": "Default"]
        access.spaces = [localSpace(LocalStore.defaultSpaceId, "Default", order: 0),
                         localSpace("mine", "Work", order: 1)]
        let store = MemorySpaceStore()
        let client = FakePhiSyncClient()
        client.seed(tagHash: PhiSyncEntity.clientTagHash(for: PhiSyncEntity.spaceClientTag("theirs")),
                    ciphertext: try ciphertext(spaceEntity("theirs", name: "Reading")), version: 4)

        var payload: [AnyHashable: Any]?
        let token = NotificationCenter.default.addObserver(
            forName: .phiSpaceFirstSyncNeeded, object: nil, queue: .main) { payload = $0.userInfo }
        defer { NotificationCenter.default.removeObserver(token) }

        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertEqual(payload?["localNames"] as? [String], ["Work"])
        XCTAssertEqual(payload?["accountCount"] as? Int, 1,
                       "the default Space is the one being MERGED, not another Space in the account")
        XCTAssertTrue(spaceCommits(client).isEmpty, "no Space is published before the answer")
        XCTAssertNotNil(store.table.cursors["theirs"]?.pendingApply, "the pulled entity is parked, not lost")
        XCTAssertNil(store.table.firstSyncDecision)
    }

    func testASecondMacWithOnlyTheDefaultSpaceIsNeverAsked() async throws {
        let access = FakePhiSpaceAccess()
        access.uuidByProfileId = ["Default": "uuid-a"]
        access.profileIdByUuid = ["uuid-a": "Default"]
        access.spaces = [localSpace(LocalStore.defaultSpaceId, "Default", order: 0)]
        let store = MemorySpaceStore()
        let client = FakePhiSyncClient()
        client.seed(tagHash: PhiSyncEntity.clientTagHash(for: PhiSyncEntity.spaceClientTag("theirs")),
                    ciphertext: try ciphertext(spaceEntity("theirs")), version: 4)
        var asked = 0
        let token = NotificationCenter.default.addObserver(
            forName: .phiSpaceFirstSyncNeeded, object: nil, queue: .main) { _ in asked += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()
        XCTAssertEqual(asked, 0)
        XCTAssertEqual(store.table.firstSyncDecision, "keepBoth")
    }

    func testTheFirstDeviceInAnEmptyAccountIsNeverAsked() async throws {
        let access = FakePhiSpaceAccess()
        access.uuidByProfileId = ["Default": "uuid-a"]
        access.spaces = [localSpace(LocalStore.defaultSpaceId, "Default", order: 0),
                         localSpace("mine", "Work", order: 1)]
        let store = MemorySpaceStore()
        let client = FakePhiSyncClient()
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()
        XCTAssertEqual(store.table.firstSyncDecision, "keepBoth")
        XCTAssertFalse(spaceCommits(client).isEmpty)
    }

    func testAccountWinsHidesLocalOnlySpacesWithoutDeletingAnything() async throws {
        let access = FakePhiSpaceAccess()
        access.uuidByProfileId = ["Default": "uuid-a"]
        access.profileIdByUuid = ["uuid-a": "Default"]
        access.spaces = [localSpace(LocalStore.defaultSpaceId, "Default", order: 0),
                         localSpace("mine", "Work", order: 1)]
        let store = MemorySpaceStore()
        let client = FakePhiSyncClient()
        client.seed(tagHash: PhiSyncEntity.clientTagHash(for: PhiSyncEntity.spaceClientTag("theirs")),
                    ciphertext: try ciphertext(spaceEntity("theirs")), version: 4)
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()
        await engine.submitFirstSyncDecision(.accountWins)

        XCTAssertTrue(store.table.cursors["mine"]!.hidden)
        XCTAssertNil(store.table.cursors["mine"]!.deletedAtMs)
        XCTAssertTrue(access.calls.filter { if case .purge = $0 { return true } else { return false } }.isEmpty,
                      "M3-2 does not sync bookmarks; deleting here would destroy the only copy")
        XCTAssertTrue(access.currentSpaces().contains { $0.spaceId == "mine" })
        XCTAssertTrue(access.calls.contains(.hide("mine")))
        XCTAssertFalse(client.commits.contains {
            $0.clientTagHash == PhiSyncEntity.clientTagHash(for: PhiSyncEntity.spaceClientTag("mine"))
        })
    }

    func testKeepBothPublishesEveryLocalOnlySpaceUnderItsOwnUuid() async throws {
        let access = FakePhiSpaceAccess()
        access.uuidByProfileId = ["Default": "uuid-a"]
        access.profileIdByUuid = ["uuid-a": "Default"]
        access.spaces = [localSpace(LocalStore.defaultSpaceId, "Default", order: 0),
                         localSpace("mine", "Work", order: 1)]
        let store = MemorySpaceStore()
        let client = FakePhiSyncClient()
        client.seed(tagHash: PhiSyncEntity.clientTagHash(for: PhiSyncEntity.spaceClientTag("theirs")),
                    ciphertext: try ciphertext(spaceEntity("theirs")), version: 4)
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()
        await engine.submitFirstSyncDecision(.keepBoth)
        XCTAssertTrue(client.commits.contains {
            $0.clientTagHash == PhiSyncEntity.clientTagHash(for: PhiSyncEntity.spaceClientTag("mine"))
        })
        XCTAssertNil(store.table.cursors["theirs"]?.pendingApply, "the parked entity lands on the answer")
    }

    func testTheQuestionIsAskedOnlyOnceAcrossRounds() async throws {
        let access = FakePhiSpaceAccess()
        access.uuidByProfileId = ["Default": "uuid-a"]
        access.profileIdByUuid = ["uuid-a": "Default"]
        access.spaces = [localSpace(LocalStore.defaultSpaceId, "Default", order: 0),
                         localSpace("mine", "Work", order: 1)]
        let store = MemorySpaceStore()
        let client = FakePhiSyncClient()
        client.seed(tagHash: PhiSyncEntity.clientTagHash(for: PhiSyncEntity.spaceClientTag("theirs")),
                    ciphertext: try ciphertext(spaceEntity("theirs")), version: 4)
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()
        await engine.submitFirstSyncDecision(.accountWins)
        var askedAfterAnswer = 0
        let token = NotificationCenter.default.addObserver(
            forName: .phiSpaceFirstSyncNeeded, object: nil, queue: .main) { _ in askedAfterAnswer += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        await engine.pullOnce()
        XCTAssertEqual(askedAfterAnswer, 0)

        // A Space created AFTER the decision syncs normally: accountWins is a
        // fixed set, not a mode.
        access.spaces.append(localSpace("later", "Client", order: 2))
        await engine.handleLocalSpacesChange()
        XCTAssertTrue(client.commits.contains {
            $0.clientTagHash == PhiSyncEntity.clientTagHash(for: PhiSyncEntity.spaceClientTag("later"))
        })
    }

    /// The D2 sheet must not stall the M3-1 settings path. `pull` may NOT
    /// return early while the question is open -- its trailing settings push is
    /// after that point, and a joining Mac that leaves the sheet open would stop
    /// converging settings entirely, breaking "设置路径必须行为逐字节不变".
    func testAnUnansweredD2SheetStillLetsSettingsPublish() async throws {
        let access = FakePhiSpaceAccess()
        access.uuidByProfileId = ["Default": "uuid-a"]
        access.profileIdByUuid = ["uuid-a": "Default"]
        access.spaces = [localSpace(LocalStore.defaultSpaceId, "Default", order: 0),
                         localSpace("mine", "Work", order: 1)]
        let store = MemorySpaceStore()
        let client = FakePhiSyncClient()
        client.seed(tagHash: PhiSyncEntity.clientTagHash(for: PhiSyncEntity.spaceClientTag("theirs")),
                    ciphertext: try ciphertext(spaceEntity("theirs")), version: 4)
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertNil(store.table.firstSyncDecision, "the question is still open")
        XCTAssertTrue(spaceCommits(client).isEmpty, "no Space is published before the answer")
        XCTAssertTrue(client.commits.contains {
            $0.clientTagHash == PhiSyncEntity.settingsClientTagHash
        }, "the settings entity must still publish while the sheet is open")
    }

    // MARK: - Remote tombstones (§9.2)

    func testARemoteTombstoneSoftDeletesAndKeepsEveryRowOnDisk() async throws {
        let access = FakePhiSpaceAccess()
        access.spaces = [localSpace("u1", "Work", order: 1)]
        let store = MemorySpaceStore()
        var cursor = PhiSpaceCursor()
        cursor.entityId = "srv-1"; cursor.version = 4
        cursor.reconciled = try spaceEntity("u1").serializedData()
        cursor.server = cursor.reconciled
        store.table.cursors["u1"] = cursor
        store.table.hasDrainedFullReplay = true
        store.table.firstSyncDecision = "keepBoth"

        let client = FakePhiSyncClient()
        client.seed(tagHash: spaceHash("u1"), ciphertext: Data(), version: 9,
                    entityId: "srv-1", deleted: true)
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertTrue(store.table.cursors["u1"]!.hidden)
        XCTAssertNotNil(store.table.cursors["u1"]!.deletedAtMs)
        XCTAssertTrue(access.calls.contains(.hide("u1")))
        XCTAssertTrue(access.currentSpaces().contains { $0.spaceId == "u1" },
                      "the 30-day window is only real if the data is still here")
        XCTAssertTrue(access.calls.filter { if case .purge = $0 { return true } else { return false } }.isEmpty)
    }

    /// Regression for §5.2's ordering rule: routing the tombstone AFTER the
    /// decrypt classifies every remote delete as "undecryptable" and, because the
    /// marker has already moved past that page, loses it permanently.
    func testATombstoneIsNeverTreatedAsADecryptFailure() async throws {
        let access = FakePhiSpaceAccess()
        access.spaces = [localSpace("u1", "Work", order: 1)]
        let store = MemorySpaceStore()
        var cursor = PhiSpaceCursor(); cursor.entityId = "srv-1"; cursor.version = 4
        store.table.cursors["u1"] = cursor
        store.table.hasDrainedFullReplay = true
        store.table.firstSyncDecision = "keepBoth"
        let client = FakePhiSyncClient()
        client.seed(tagHash: spaceHash("u1"), ciphertext: Data(), version: 9,
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
        store.table.hasDrainedFullReplay = true
        store.table.firstSyncDecision = "keepBoth"
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
        store.table.hasDrainedFullReplay = true
        store.table.firstSyncDecision = "keepBoth"
        let client = FakePhiSyncClient()
        client.seed(tagHash: spaceHash(LocalStore.defaultSpaceId), ciphertext: Data(), version: 3,
                    entityId: "srv-d", deleted: true)
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()
        XCTAssertNil(store.table.cursors[LocalStore.defaultSpaceId]?.deletedAtMs)
        XCTAssertTrue(access.calls.filter { $0 == .hide(LocalStore.defaultSpaceId) }.isEmpty)
    }

    func testAnImportLockDefersTheTombstoneAndPersistsTheIntent() async throws {
        let access = FakePhiSpaceAccess()
        access.spaces = [localSpace("u1", "Work", order: 1)]
        access.importingSpaceIds = ["u1"]
        let store = MemorySpaceStore()
        var cursor = PhiSpaceCursor(); cursor.entityId = "srv-1"; cursor.version = 4
        store.table.cursors["u1"] = cursor
        store.table.hasDrainedFullReplay = true
        store.table.firstSyncDecision = "keepBoth"
        let client = FakePhiSyncClient()
        client.seed(tagHash: spaceHash("u1"), ciphertext: Data(), version: 9,
                    entityId: "srv-1", deleted: true)
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertTrue(store.table.cursors["u1"]!.pendingTombstone,
                      "the shared marker has moved past it; the intent must survive here or it is lost")
        XCTAssertFalse(store.table.cursors["u1"]!.hidden)

        access.importingSpaceIds = []
        await engine.pullOnce()   // the tombstone is NOT redelivered
        XCTAssertTrue(store.table.cursors["u1"]!.hidden)
        XCTAssertFalse(store.table.cursors["u1"]!.pendingTombstone)
    }

    func testASoftDeletedSpaceIsNeverResurrectedBySnapshotOrByAReplayedTombstone() async throws {
        let access = FakePhiSpaceAccess()
        access.uuidByProfileId = ["Default": "uuid-a"]
        access.spaces = [localSpace("u1", "Work", order: 1)]
        let store = MemorySpaceStore()
        var cursor = PhiSpaceCursor()
        cursor.entityId = "srv-1"; cursor.version = 9
        cursor.hidden = true; cursor.deletedAtMs = 5_000
        store.table.cursors["u1"] = cursor
        store.table.hasDrainedFullReplay = true
        store.table.firstSyncDecision = "keepBoth"
        let client = FakePhiSyncClient()
        client.seed(tagHash: spaceHash("u1"), ciphertext: Data(), version: 9,
                    entityId: "srv-1", deleted: true)
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()
        XCTAssertTrue(spaceCommits(client).isEmpty)
        XCTAssertEqual(store.table.cursors["u1"]!.deletedAtMs, 5_000)
    }

    // MARK: - Retention sweep (§9.2)

    func testTheSweepCascadesTheDataAndKeepsThePermanentTombstone() async throws {
        let access = FakePhiSpaceAccess()
        access.spaces = [localSpace("u1", "Work", order: 1)]
        let store = MemorySpaceStore()
        var cursor = PhiSpaceCursor()
        cursor.entityId = "srv-1"; cursor.version = 9
        cursor.hidden = true; cursor.deletedAtMs = 1
        cursor.reconciled = Data([0x01])
        store.table.cursors["u1"] = cursor
        let client = FakePhiSyncClient()
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.runRetentionSweep()

        XCTAssertTrue(access.calls.contains(.purge("u1")))
        XCTAssertFalse(access.currentSpaces().contains { $0.spaceId == "u1" })
        let tombstone = try XCTUnwrap(store.table.cursors["u1"])
        XCTAssertNotNil(tombstone.purgedAtMs)
        XCTAssertNotNil(tombstone.deletedAtMs)
        XCTAssertNil(tombstone.reconciled)
    }

    // MARK: - Join account sync (§8.3, moved here from Task 13's batch because
    // `PhiSyncEngine.joinAccountSync` is produced by Step 4 of THIS task)

    func testJoinAccountSyncPublishesAHiddenSpaceAsAPlainCreate() async throws {
        let access = FakePhiSpaceAccess()
        access.uuidByProfileId = ["Default": "uuid-a"]
        access.spaces = [localSpace("mine", "Work", order: 1)]
        let store = MemorySpaceStore()
        store.table.firstSyncDecision = "accountWins"
        store.table.hasDrainedFullReplay = true
        var hidden = PhiSpaceCursor(); hidden.hidden = true
        store.table.cursors["mine"] = hidden
        let client = FakePhiSyncClient()
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.joinAccountSync(spaceId: "mine")
        XCTAssertFalse(store.table.cursors["mine"]!.hidden)
        XCTAssertTrue(spaceCommits(client).contains { $0.clientTagHash == spaceHash("mine") })
    }

    // MARK: - Delete origin (§9.1)

    func testRecordLocalDeletionOnlyMarksAPublishedSpace() async throws {
        let access = FakePhiSpaceAccess()
        let store = MemorySpaceStore()
        var published = PhiSpaceCursor(); published.entityId = "srv-1"; published.version = 3
        var refused = PhiSpaceCursor(); refused.refusedAtMs = 1
        store.table.cursors = ["published": published, "agent": refused]
        let client = FakePhiSyncClient()
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.recordLocalDeletion(spaceId: "published")
        await engine.recordLocalDeletion(spaceId: "agent")
        await engine.recordLocalDeletion(spaceId: "never-seen")
        XCTAssertTrue(store.table.cursors["published"]!.pendingDelete)
        XCTAssertFalse(store.table.cursors["agent"]!.pendingDelete)
        XCTAssertNil(store.table.cursors["never-seen"])
    }

    /// The single-writer rule (§5.3): the facade delivers an INTENT that runs on
    /// the engine's serial queue rather than writing the table from the main
    /// thread, so the delete is still there when the next round assembles its
    /// batch. It deliberately does NOT claim immunity from a round already in
    /// flight -- `pushSpaces` holds one table copy across its whole batch loop,
    /// so an intent landing inside that window is still overwritten by its tail
    /// (see the corrections file's D9). The ordering below is the one §5.3
    /// actually promises: intent first, then the round that must honour it.
    func testADeletionIntentSurvivesAConcurrentSnapshot() async throws {
        let access = FakePhiSpaceAccess()
        access.uuidByProfileId = ["Default": "uuid-a"]
        access.spaces = [localSpace("u1", "Work", order: 1)]
        let store = MemorySpaceStore()
        var cursor = PhiSpaceCursor(); cursor.entityId = "srv-1"; cursor.version = 3
        cursor.reconciled = try spaceEntity("u1").serializedData()
        cursor.server = cursor.reconciled
        store.table.cursors["u1"] = cursor
        store.table.hasDrainedFullReplay = true
        store.table.firstSyncDecision = "keepBoth"
        let client = FakePhiSyncClient()
        let engine = makeEngine(access: access, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.recordLocalDeletion(spaceId: "u1")
        await engine.handleLocalSpacesChange()
        XCTAssertTrue(store.table.cursors["u1"]!.pendingDelete
                      || store.table.cursors["u1"]!.deletedAtMs != nil)
    }
}

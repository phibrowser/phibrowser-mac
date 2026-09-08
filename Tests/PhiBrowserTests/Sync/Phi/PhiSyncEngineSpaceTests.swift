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
        if let profileUuid, uuid != LocalStore.defaultSpaceId { entity.profileUuid = v(profileUuid) }
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
        // Task 8 only ROUTES: the cursor for `good` is written by Task 9's apply
        // path, so neither uuid has one yet.
        XCTAssertNil(store.table.cursors["bad"])
        XCTAssertNil(store.table.cursors["good"])
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
        // Task 8 wires the TRIGGER only -- `pushSpaces` is Task 9 Step 4.1, and
        // Step 5 explicitly forbids hanging it off this round here. That task
        // turns this count into 1.
        XCTAssertEqual(spaceCommits(client).count, 0)
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
}

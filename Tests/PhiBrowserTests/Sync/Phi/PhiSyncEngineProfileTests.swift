import CryptoKit
import XCTest
@testable import Phi

/// In-memory `PhiProfileLocalAccess`: `profiles` are every user Profile, `mappings` the persisted
/// localProfileId -> account uuid table.
@MainActor
final class FakePhiProfileAccess: PhiProfileLocalAccess {
    var profiles: [PhiLocalProfile] = []
    var mappings: [String: String] = [:]
    var enumerated = true
    /// When set, the next rename fails.
    var failNextRename = false
    private(set) var renames: [(profileId: String, name: String)] = []
    private(set) var droppedMappings: [String] = []

    func currentProfiles() -> [PhiLocalProfile] { profiles.filter { mappings[$0.profileId] != nil } }
    func allProfileMappings() -> [String: String] { mappings }
    func isProfileListEnumerated() -> Bool { enumerated }

    func applyRemoteName(profileId: String, name: String) async -> String? {
        if failNextRename { failNextRename = false; return nil }
        let target = SyncKeyController.uniqueDisplayName(basedOn: name) { candidate in
            self.profiles.contains {
                $0.profileId != profileId && $0.displayName.caseInsensitiveCompare(candidate) == .orderedSame
            }
        }
        guard let index = profiles.firstIndex(where: { $0.profileId == profileId }) else { return nil }
        profiles[index].displayName = target
        renames.append((profileId, target))
        return target
    }

    func dropMapping(forProfileId profileId: String) {
        droppedMappings.append(profileId)
        mappings.removeValue(forKey: profileId)
    }

    func isKnownLocalProfile(_ profileId: String) -> Bool { profiles.contains { $0.profileId == profileId } }

    // Deletion
    var intents: [String: String] = [:]
    var inFlight: Set<String> = []
    var blockers: [String: ProfileDeletionBlockers] = [:]
    /// Results of the next Chromium deletions; true when empty.
    var deleteResults: [Bool] = []
    private(set) var remoteDeletions: [String] = []

    func profileDeletionIntents() -> [String: String] { intents }
    func finishLocalProfileDeletion(syncUuid: String) { intents.removeValue(forKey: syncUuid) }
    func isProfileBeingDeletedLocally(syncUuid: String) -> Bool { inFlight.contains(syncUuid) }
    func profileDeletionBlockers(localProfileId: String) -> ProfileDeletionBlockers {
        blockers[localProfileId] ?? ProfileDeletionBlockers()
    }
    func deleteForRemoteTombstone(localProfileId: String) async -> Bool {
        remoteDeletions.append(localProfileId)
        let ok = deleteResults.isEmpty ? true : deleteResults.removeFirst()
        if ok { profiles.removeAll { $0.profileId == localProfileId } }
        return ok
    }
}

@MainActor
final class PhiSyncEngineProfileTests: XCTestCase {
    typealias FakePhiSyncClient = PhiSyncEngineTests.FakePhiSyncClient
    typealias StubDomainKeys = PhiSyncEngineTests.StubDomainKeys
    typealias MemorySpaceStore = PhiSyncEngineSpaceTests.MemorySpaceStore

    private var defaults: UserDefaults!
    private var suiteName: String!
    private let key = SymmetricKey(size: .bits256)
    private var nowMs: Int64 = 1_700_000_000_000

    override func setUp() {
        super.setUp()
        suiteName = "PhiSyncEngineProfileTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil; suiteName = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func profileEntity(_ uuid: String, _ name: String, at stamp: Int64 = 100) -> Phi_PhiProfileEntity {
        var entity = Phi_PhiProfileEntity()
        entity.profileUuid = uuid
        entity.name.stringValue = name
        entity.name.updatedAtMs = stamp
        return entity
    }

    private func ciphertext(_ entity: Phi_PhiProfileEntity) throws -> Data {
        var wrapper = Phi_PhiEntity()
        wrapper.profile = entity
        return try PhiEntityCodec.encrypt(wrapper, key: key)
    }

    private func hash(_ uuid: String) -> String {
        PhiSyncEntity.clientTagHash(for: PhiSyncEntity.profileClientTag(uuid))
    }

    private func drainedStore() -> MemorySpaceStore {
        let store = MemorySpaceStore()
        store.table.hasDrainedFullReplay = true
        return store
    }

    private func makeEngine(spaces: FakePhiSpaceAccess? = nil,
                            profiles: FakePhiProfileAccess,
                            store: MemorySpaceStore,
                            client: FakePhiSyncClient) -> PhiSyncEngine {
        PhiSyncEngine(domainKeys: StubDomainKeys(key: key), client: client,
                      defaults: defaults, deviceKeyId: "devA", pairingComplete: true,
                      settings: [], spaceAccess: spaces ?? FakePhiSpaceAccess(), spaceStore: store,
                      profileAccess: profiles, now: { [unowned self] in self.nowMs })
    }

    private func profileCommits(_ client: FakePhiSyncClient) -> [FakePhiSyncClient.CommitCall] {
        client.commits.filter { $0.name == PhiSyncEntity.profileEntityName }
    }

    private func published(_ client: FakePhiSyncClient, _ uuid: String) throws -> Phi_PhiProfileEntity {
        let row = try XCTUnwrap(client.stored[hash(uuid)])
        return try PhiEntityCodec.decrypt(row.ciphertext, key: key).profile
    }

    // MARK: - Landing

    func testAnEntityForAProfileThisDeviceLacksIsStoredAsALiveBaseline() async throws {
        let profiles = FakePhiProfileAccess()
        let store = drainedStore()
        let client = FakePhiSyncClient()
        client.seed(tagHash: hash("pu-new"), ciphertext: try ciphertext(profileEntity("pu-new", "Work")), version: 5)
        let engine = makeEngine(profiles: profiles, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)

        await engine.pullOnce()

        let cursor = try XCTUnwrap(store.table.profileCursors["pu-new"])
        XCTAssertEqual(cursor.version, 5)
        XCTAssertNotNil(cursor.reconciled)
        XCTAssertNil(cursor.localNameAtBaseline)
        XCTAssertEqual(store.table.liveProfileEntityNames, ["pu-new": "Work"])
        XCTAssertTrue(profiles.renames.isEmpty)
    }

    func testAPeerRenameIsAppliedAndSuffixedOnACollision() async throws {
        let profiles = FakePhiProfileAccess()
        profiles.profiles = [PhiLocalProfile(profileId: "P1", displayName: "Work", createdAtMs: 0),
                             PhiLocalProfile(profileId: "P2", displayName: "Office", createdAtMs: 0)]
        profiles.mappings = ["P1": "pu-1"]
        let store = drainedStore()
        let client = FakePhiSyncClient()
        client.seed(tagHash: hash("pu-1"), ciphertext: try ciphertext(profileEntity("pu-1", "Work")), version: 3)
        let engine = makeEngine(profiles: profiles, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()
        XCTAssertTrue(profiles.renames.isEmpty, "the local name already is the account name")

        client.reseed(tagHash: hash("pu-1"), ciphertext: try ciphertext(profileEntity("pu-1", "Office", at: 900)),
                      version: 7)
        await engine.pullOnce()

        XCTAssertEqual(profiles.renames.last?.name, "Office (2)", "local names stay unique")
        XCTAssertEqual(store.table.profileCursors["pu-1"]?.localNameAtBaseline, "Office (2)")
        XCTAssertTrue(profileCommits(client).isEmpty, "a suffixed twin never renames the account")
        XCTAssertEqual(try published(client, "pu-1").name.stringValue, "Office")
    }

    func testAFailedRenameParksTheEntityAndRetriesIt() async throws {
        let profiles = FakePhiProfileAccess()
        profiles.profiles = [PhiLocalProfile(profileId: "P1", displayName: "Work", createdAtMs: 0)]
        profiles.mappings = ["P1": "pu-1"]
        profiles.failNextRename = true
        let store = drainedStore()
        let client = FakePhiSyncClient()
        client.seed(tagHash: hash("pu-1"), ciphertext: try ciphertext(profileEntity("pu-1", "Home")), version: 3)
        let engine = makeEngine(profiles: profiles, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)

        await engine.pullOnce()
        XCTAssertNotNil(store.table.profileCursors["pu-1"]?.pendingApply)
        XCTAssertNil(store.table.profileCursors["pu-1"]?.reconciled)
        XCTAssertTrue(profileCommits(client).isEmpty, "a parked Profile is not published over")

        await engine.pullOnce()
        XCTAssertNil(store.table.profileCursors["pu-1"]?.pendingApply)
        XCTAssertEqual(profiles.profiles[0].displayName, "Home")
    }

    // MARK: - Publication

    func testALocalRenamePublishesAndItsEchoCommitsNothing() async throws {
        let profiles = FakePhiProfileAccess()
        profiles.profiles = [PhiLocalProfile(profileId: "P1", displayName: "Work", createdAtMs: 0)]
        profiles.mappings = ["P1": "pu-1"]
        let store = drainedStore()
        let client = FakePhiSyncClient()
        client.seed(tagHash: hash("pu-1"), ciphertext: try ciphertext(profileEntity("pu-1", "Work")), version: 3)
        let engine = makeEngine(profiles: profiles, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        await engine.handleLocalProfilesChange()
        XCTAssertTrue(profileCommits(client).isEmpty, "nothing changed")

        nowMs += 10_000
        profiles.profiles[0].displayName = "Office"
        await engine.handleLocalProfilesChange()

        XCTAssertEqual(profileCommits(client).count, 1)
        let entity = try published(client, "pu-1")
        XCTAssertEqual(entity.name.stringValue, "Office")
        XCTAssertGreaterThan(entity.name.updatedAtMs, 100)
        XCTAssertEqual(store.table.profileCursors["pu-1"]?.localNameAtBaseline, "Office")

        await engine.handleLocalProfilesChange()
        XCTAssertEqual(profileCommits(client).count, 1, "the published rename is not republished")
    }

    func testAProfileEntityIsCommittedBeforeTheSpacesBoundToIt() async throws {
        let profiles = FakePhiProfileAccess()
        profiles.profiles = [PhiLocalProfile(profileId: "Default", displayName: "Personal", createdAtMs: 42)]
        profiles.mappings = ["Default": "pu-1"]
        let spaces = FakePhiSpaceAccess()
        spaces.uuidByProfileId = ["Default": "pu-1"]
        spaces.profileIdByUuid = ["pu-1": "Default"]
        spaces.spaces = [PhiLocalSpace(spaceId: "s-1", profileId: "Default", name: "Work", colorHex: "#3A6FF8",
                                       iconName: "emoji:1F4BC", sortOrder: 0,
                                       createdDate: Date(timeIntervalSince1970: 1), themeId: nil,
                                       opacityLight: nil, opacityDark: nil)]
        spaces.spaceMappings = ["s-1": "su-1"]
        let store = drainedStore()
        let client = FakePhiSyncClient()
        let engine = makeEngine(spaces: spaces, profiles: profiles, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)

        await engine.pullOnce()

        let names = client.commits.map(\.name)
        let profileIndex = try XCTUnwrap(names.firstIndex(of: PhiSyncEntity.profileEntityName))
        let spaceIndex = try XCTUnwrap(names.firstIndex(of: PhiSyncEntity.spaceEntityName))
        XCTAssertLessThan(profileIndex, spaceIndex)
        let entity = try published(client, "pu-1")
        XCTAssertEqual(entity.name.stringValue, "Personal")
        XCTAssertEqual(entity.name.updatedAtMs, 0, "a first publication never beats a real rename")
        XCTAssertEqual(entity.createdAtMs, 42)
    }

    func testAConflictRetriesOnlyThatProfile() async throws {
        let profiles = FakePhiProfileAccess()
        profiles.profiles = [PhiLocalProfile(profileId: "P1", displayName: "Work", createdAtMs: 0),
                             PhiLocalProfile(profileId: "P2", displayName: "Home", createdAtMs: 0)]
        profiles.mappings = ["P1": "pu-1", "P2": "pu-2"]
        let store = drainedStore()
        let client = FakePhiSyncClient()
        client.conflictOnceForTagHashes = [hash("pu-1")]
        let engine = makeEngine(profiles: profiles, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)

        await engine.pushLocalSettings()

        let tags = profileCommits(client).map(\.clientTagHash)
        XCTAssertEqual(tags.filter { $0 == hash("pu-1") }.count, 2, "committed, conflicted, retried")
        XCTAssertEqual(tags.filter { $0 == hash("pu-2") }.count, 1, "the other Profile is not retried")
        XCTAssertNotNil(client.stored[hash("pu-1")])
        XCTAssertNotNil(store.table.profileCursors["pu-1"]?.reconciled)
    }

    func testNothingIsPublishedBeforeTheFullReplayDrained() async throws {
        let profiles = FakePhiProfileAccess()
        profiles.profiles = [PhiLocalProfile(profileId: "P1", displayName: "Work", createdAtMs: 0)]
        profiles.mappings = ["P1": "pu-1"]
        let store = MemorySpaceStore()
        store.table.drainInProgress = true
        let client = FakePhiSyncClient()
        client.keepReportingChangesRemaining = true
        let engine = makeEngine(profiles: profiles, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)

        await engine.pushLocalSettings()

        XCTAssertTrue(profileCommits(client).isEmpty)
    }

    // MARK: - Tombstones and resurrection

    func testARemoteTombstoneIsRecordedAndNeverRepublished() async throws {
        let profiles = FakePhiProfileAccess()
        profiles.profiles = [PhiLocalProfile(profileId: "P1", displayName: "Work", createdAtMs: 0)]
        profiles.mappings = ["P1": "pu-1"]
        let store = drainedStore()
        let client = FakePhiSyncClient()
        client.seed(tagHash: hash("pu-1"), ciphertext: try ciphertext(profileEntity("pu-1", "Work")), version: 3)
        let engine = makeEngine(profiles: profiles, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        client.seed(tagHash: hash("pu-1"), ciphertext: Data(), version: 9,
                    entityId: client.entityId(forTagHash: hash("pu-1")), deleted: true)
        await engine.pullOnce()

        let cursor = try XCTUnwrap(store.table.profileCursors["pu-1"])
        XCTAssertEqual(cursor.deletedAtMs, nowMs)
        XCTAssertEqual(cursor.version, 9)
        XCTAssertTrue(store.table.deletedProfileUuids.contains("pu-1"))
        // A Profile with the same mapping created again locally never republishes the uuid.
        profiles.profiles = [PhiLocalProfile(profileId: "P1", displayName: "Renamed", createdAtMs: 0)]
        nowMs += 10_000
        await engine.handleLocalProfilesChange()
        XCTAssertTrue(profileCommits(client).isEmpty, "a deleted account Profile is never republished")
    }

    func testANewerLiveEntityResurrectsADeletedProfileAndDropsItsDeadMapping() async throws {
        let profiles = FakePhiProfileAccess()
        profiles.mappings = ["Gone": "pu-1"]           // the local Profile was deleted here
        let store = drainedStore()
        var deleted = PhiProfileCursor()
        deleted.entityId = "srv-1"
        deleted.version = 9
        deleted.deletedAtMs = 1
        store.table.profileCursors["pu-1"] = deleted
        let client = FakePhiSyncClient()
        client.seed(tagHash: hash("pu-1"), ciphertext: try ciphertext(profileEntity("pu-1", "Work")),
                    version: 12, entityId: "srv-1")
        let engine = makeEngine(profiles: profiles, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)

        await engine.pullOnce()

        let cursor = try XCTUnwrap(store.table.profileCursors["pu-1"])
        XCTAssertNil(cursor.deletedAtMs)
        XCTAssertEqual(cursor.version, 12)
        XCTAssertEqual(store.table.liveProfileEntityUuids, ["pu-1"])
        XCTAssertEqual(profiles.droppedMappings, ["Gone"], "auto-create now sees the uuid missing")
    }

    func testAnOlderReplayedCreateDoesNotResurrectADeletedProfile() async throws {
        let profiles = FakePhiProfileAccess()
        let store = drainedStore()
        var deleted = PhiProfileCursor()
        deleted.entityId = "srv-1"
        deleted.version = 9
        deleted.deletedAtMs = 1
        store.table.profileCursors["pu-1"] = deleted
        let client = FakePhiSyncClient()
        client.seed(tagHash: hash("pu-1"), ciphertext: try ciphertext(profileEntity("pu-1", "Work")),
                    version: 4, entityId: "srv-1")
        let engine = makeEngine(profiles: profiles, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)

        await engine.pullOnce()

        XCTAssertEqual(store.table.profileCursors["pu-1"]?.deletedAtMs, 1)
        XCTAssertTrue(store.table.liveProfileEntityUuids.isEmpty)
    }

    // MARK: - Facade view

    func testTheEntityViewIsNilUntilTheFirstDrain() {
        let state = PhiSpaceSyncState.shared
        var table = PhiSpaceSyncTable()
        var live = PhiProfileCursor()
        live.entityId = "srv-1"
        table.profileCursors["pu-1"] = live
        state.refreshCaches(from: table)
        XCTAssertNil(state.accountProfileEntityView)

        table.hasDrainedFullReplay = true
        state.refreshCaches(from: table)
        XCTAssertEqual(state.accountProfileEntityView?.liveUuids, ["pu-1"])
        state.refreshCaches(from: PhiSpaceSyncTable())
    }

    // MARK: - Deleting device (step 3)

    /// A mapped Profile whose entity landed, as `pullOnce` leaves it.
    private func landedProfile(_ profiles: FakePhiProfileAccess, _ client: FakePhiSyncClient,
                               store: MemorySpaceStore) async throws -> PhiSyncEngine {
        profiles.profiles = [PhiLocalProfile(profileId: "P1", displayName: "Work", createdAtMs: 0)]
        profiles.mappings = ["P1": "pu-1"]
        client.seed(tagHash: hash("pu-1"), ciphertext: try ciphertext(profileEntity("pu-1", "Work")), version: 3)
        let engine = makeEngine(profiles: profiles, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()
        return engine
    }

    /// Chromium has deleted P1; its intent is in the journal.
    private func deleteLocally(_ profiles: FakePhiProfileAccess) {
        profiles.intents["pu-1"] = "P1"
        profiles.profiles.removeAll { $0.profileId == "P1" }
    }

    func testALocalDeletionPublishesATombstoneAndClearsTheJournal() async throws {
        let profiles = FakePhiProfileAccess()
        let store = drainedStore()
        let client = FakePhiSyncClient()
        let engine = try await landedProfile(profiles, client, store: store)
        deleteLocally(profiles)

        await engine.recordLocalProfileDeletion(syncUuid: "pu-1")
        XCTAssertEqual(store.table.profileCursors["pu-1"]?.pendingDelete, true)
        XCTAssertEqual(profiles.intents, ["pu-1": "P1"], "the journal entry stays until the tombstone commits")

        await engine.handleLocalProfilesChange()

        let tombstone = try XCTUnwrap(profileCommits(client).last)
        XCTAssertTrue(tombstone.deleted)
        XCTAssertEqual(tombstone.baseVersion, 3)
        XCTAssertNotNil(store.table.profileCursors["pu-1"]?.deletedAtMs)
        XCTAssertTrue(profiles.intents.isEmpty)
        XCTAssertEqual(profiles.mappings, ["P1": "pu-1"], "the mapping is kept until retention")
    }

    func testAJournalEntryForAProfileThatStillExistsIsDropped() async throws {
        let profiles = FakePhiProfileAccess()
        let store = drainedStore()
        let client = FakePhiSyncClient()
        let engine = try await landedProfile(profiles, client, store: store)
        profiles.intents["pu-1"] = "P1"            // a crash before Chromium deleted anything

        await engine.handleLocalProfilesChange()

        XCTAssertTrue(profiles.intents.isEmpty)
        XCTAssertNil(store.table.profileCursors["pu-1"]?.deletedAtMs)
        XCTAssertFalse(profileCommits(client).contains { $0.deleted })
    }

    func testAnIntentIsKeptWhileItsDeletionIsInFlightOrTheTableDoesNotKnowTheAccount() async throws {
        let profiles = FakePhiProfileAccess()
        let store = drainedStore()
        let client = FakePhiSyncClient()
        let engine = try await landedProfile(profiles, client, store: store)
        profiles.intents["pu-1"] = "P1"
        profiles.inFlight = ["pu-1"]
        await engine.handleLocalProfilesChange()
        XCTAssertEqual(profiles.intents, ["pu-1": "P1"], "Chromium is still deleting it")

        // A lost table: no cursor, and the replay has not drained.
        profiles.inFlight = []
        profiles.profiles = []
        store.table = PhiSpaceSyncTable()
        store.table.drainInProgress = true
        await engine.recordLocalProfileDeletion(syncUuid: "pu-1")
        XCTAssertEqual(profiles.intents, ["pu-1": "P1"], "the journal outlives the table")
        XCTAssertNil(store.table.profileCursors["pu-1"])
    }

    func testANeverPublishedProfileIsFinalizedWithoutATombstone() async throws {
        let profiles = FakePhiProfileAccess()
        profiles.intents["pu-9"] = "P9"
        let store = drainedStore()
        let client = FakePhiSyncClient()
        let engine = makeEngine(profiles: profiles, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)

        await engine.recordLocalProfileDeletion(syncUuid: "pu-9")

        XCTAssertNotNil(store.table.profileCursors["pu-9"]?.deletedAtMs)
        XCTAssertTrue(profiles.intents.isEmpty)
        XCTAssertTrue(profileCommits(client).isEmpty)
    }

    func testTheDeletionIsRecordedWhileSyncIsPausedForAnUnmappedProfile() async throws {
        let profiles = FakePhiProfileAccess()
        let store = drainedStore()
        let client = FakePhiSyncClient()
        let engine = try await landedProfile(profiles, client, store: store)
        deleteLocally(profiles)
        engine.setProfileMappingPause(true)

        await engine.recordLocalProfileDeletion(syncUuid: "pu-1")

        XCTAssertEqual(store.table.profileCursors["pu-1"]?.pendingDelete, true)
    }

    func testDeleteBeatsAConcurrentPeerRename() async throws {
        let profiles = FakePhiProfileAccess()
        let store = drainedStore()
        let client = FakePhiSyncClient()
        let engine = try await landedProfile(profiles, client, store: store)
        deleteLocally(profiles)
        client.reseed(tagHash: hash("pu-1"), ciphertext: try ciphertext(profileEntity("pu-1", "Office", at: 900)),
                      version: 8)

        await engine.pushLocalSettings()

        XCTAssertTrue(profiles.renames.isEmpty)
        let tombstone = try XCTUnwrap(profileCommits(client).last)
        XCTAssertTrue(tombstone.deleted)
        XCTAssertEqual(tombstone.baseVersion, 8, "the tombstone is sent at the version the rename created")
    }

    func testASpaceBoundToADeletedProfileParksWithoutDroppingTheMapping() async throws {
        let profiles = FakePhiProfileAccess()
        let spaces = FakePhiSpaceAccess()
        spaces.profileIdByUuid = ["pu-1": "P1"]
        spaces.knownLocalProfileIds = []          // P1 is gone here
        let store = drainedStore()
        var deleted = PhiProfileCursor()
        deleted.entityId = "srv-p"
        deleted.version = 4
        deleted.deletedAtMs = 1
        store.table.profileCursors["pu-1"] = deleted
        let client = FakePhiSyncClient()
        var space = Phi_PhiSpaceEntity()
        space.spaceUuid = "su-1"
        space.name.stringValue = "Work"
        space.profileUuid.stringValue = "pu-1"
        var wrapper = Phi_PhiEntity()
        wrapper.space = space
        client.seed(tagHash: PhiSyncEntity.clientTagHash(for: PhiSyncEntity.spaceClientTag("su-1")),
                    ciphertext: try PhiEntityCodec.encrypt(wrapper, key: key), version: 6)
        let engine = makeEngine(spaces: spaces, profiles: profiles, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)

        await engine.pullOnce()

        XCTAssertNotNil(store.table.cursors["su-1"]?.pendingApply)
        XCTAssertTrue(spaces.droppedMappings.isEmpty, "no repair may let auto-create grow the Profile back")
    }

    func testRetentionTrimsTheCursorAndDropsTheDeadMapping() async throws {
        let profiles = FakePhiProfileAccess()
        profiles.mappings = ["P1": "pu-1"]
        let store = drainedStore()
        var deleted = PhiProfileCursor()
        deleted.entityId = "srv-p"
        deleted.version = 4
        deleted.reconciled = Data([0x01])
        deleted.deletedAtMs = 1
        store.table.profileCursors["pu-1"] = deleted
        let engine = makeEngine(profiles: profiles, store: store, client: FakePhiSyncClient())

        await engine.runRetentionSweep()

        XCTAssertNotNil(store.table.profileCursors["pu-1"]?.purgedAtMs)
        XCTAssertNil(store.table.profileCursors["pu-1"]?.reconciled)
        XCTAssertEqual(profiles.droppedMappings, ["P1"])
    }

    // MARK: - Follower (step 4)

    private func tombstone(_ client: FakePhiSyncClient, version: Int64) {
        client.seed(tagHash: hash("pu-1"), ciphertext: Data(), version: version,
                    entityId: client.entityId(forTagHash: hash("pu-1")), deleted: true)
    }

    func testARemoteTombstoneDeletesAnEmptyLocalProfile() async throws {
        let profiles = FakePhiProfileAccess()
        let store = drainedStore()
        let client = FakePhiSyncClient()
        let engine = try await landedProfile(profiles, client, store: store)
        tombstone(client, version: 9)

        await engine.pullOnce()

        XCTAssertEqual(profiles.remoteDeletions, ["P1"])
        XCTAssertNotNil(store.table.profileCursors["pu-1"]?.deletedAtMs)
        XCTAssertEqual(profiles.mappings, ["P1": "pu-1"])
        XCTAssertFalse(profileCommits(client).contains { !$0.deleted }, "nothing is republished")
    }

    func testAnAgentSpaceDefersTheTombstoneUntilItIsGone() async throws {
        let profiles = FakePhiProfileAccess()
        let store = drainedStore()
        let client = FakePhiSyncClient()
        let engine = try await landedProfile(profiles, client, store: store)
        profiles.blockers["P1"] = ProfileDeletionBlockers(hasAgentSpaces: true)
        tombstone(client, version: 9)

        await engine.pullOnce()
        XCTAssertEqual(store.table.profileCursors["pu-1"]?.pendingTombstone, true)
        XCTAssertTrue(profiles.remoteDeletions.isEmpty)

        profiles.blockers = [:]
        await engine.pullOnce()
        XCTAssertEqual(profiles.remoteDeletions, ["P1"])
        XCTAssertEqual(store.table.profileCursors["pu-1"]?.pendingTombstone, false)
    }

    func testTheDefaultProfileIsUndeletedAndRepublishedAtTheTombstoneVersion() async throws {
        let profiles = FakePhiProfileAccess()
        let store = drainedStore()
        let client = FakePhiSyncClient()
        let engine = try await landedProfile(profiles, client, store: store)
        profiles.blockers["P1"] = ProfileDeletionBlockers(isDefaultProfile: true)
        tombstone(client, version: 9)

        await engine.pullOnce()

        XCTAssertTrue(profiles.remoteDeletions.isEmpty)
        let republished = try XCTUnwrap(profileCommits(client).last)
        XCTAssertFalse(republished.deleted)
        XCTAssertEqual(republished.baseVersion, 9)
        XCTAssertNil(store.table.profileCursors["pu-1"]?.deletedAtMs)
        XCTAssertEqual(try published(client, "pu-1").name.stringValue, "Work")
    }

    func testALiveUserSpaceUndeletes() async throws {
        let profiles = FakePhiProfileAccess()
        let store = drainedStore()
        let client = FakePhiSyncClient()
        let engine = try await landedProfile(profiles, client, store: store)
        profiles.blockers["P1"] = ProfileDeletionBlockers(liveUserSpaceSyncUuids: [nil])
        tombstone(client, version: 9)

        await engine.pullOnce()

        XCTAssertTrue(profiles.remoteDeletions.isEmpty)
        XCTAssertEqual(profileCommits(client).last?.deleted, false)
    }

    func testAChromiumDeletionThatKeepsFailingIsUndeletedAfterThreeRounds() async throws {
        let profiles = FakePhiProfileAccess()
        let store = drainedStore()
        let client = FakePhiSyncClient()
        let engine = try await landedProfile(profiles, client, store: store)
        profiles.deleteResults = [false, false, false]
        tombstone(client, version: 9)

        await engine.pullOnce()
        await engine.pullOnce()
        XCTAssertEqual(store.table.profileCursors["pu-1"]?.pendingTombstone, true)
        XCTAssertEqual(store.table.profileCursors["pu-1"]?.tombstoneDeferRounds, 2)
        await engine.pullOnce()

        XCTAssertEqual(profiles.remoteDeletions.count, 3)
        XCTAssertNil(store.table.profileCursors["pu-1"]?.deletedAtMs)
        XCTAssertEqual(profileCommits(client).last?.deleted, false, "the entity is republished")
    }

    func testATombstoneForAProfileDeletedHereFinalizesAndClearsTheJournal() async throws {
        let profiles = FakePhiProfileAccess()
        let store = drainedStore()
        let client = FakePhiSyncClient()
        let engine = try await landedProfile(profiles, client, store: store)
        profiles.intents["pu-1"] = "P1"
        profiles.inFlight = ["pu-1"]               // still deleting here when the peer's tombstone lands
        tombstone(client, version: 9)

        await engine.pullOnce()

        XCTAssertTrue(profiles.remoteDeletions.isEmpty)
        XCTAssertNotNil(store.table.profileCursors["pu-1"]?.deletedAtMs)
        XCTAssertTrue(profiles.intents.isEmpty)
    }
}

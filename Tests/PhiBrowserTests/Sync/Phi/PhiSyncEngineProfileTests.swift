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
    /// What the key registry listed, for `knownAccountProfileUuids()`.
    var registryUuids: Set<String> = []
    func knownAccountProfileUuids() -> Set<String> { registryUuids }
    func isProfileListEnumerated() -> Bool { enumerated }

    func applyRemoteName(profileId: String, name: String) async -> String? {
        if failNextRename { failNextRename = false; return nil }
        let target = SyncKeyController.uniqueDisplayName(basedOn: name) { candidate in
            self.isDisplayNameTaken(candidate, excluding: profileId)
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
    /// Names held by local Profiles this fake does not list as user Profiles (Phi Chat and so on).
    var otherLocalNames: [String] = []
    func isDisplayNameTaken(_ name: String, excluding profileId: String) -> Bool {
        otherLocalNames.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
            || profiles.contains {
                $0.profileId != profileId && $0.displayName.caseInsensitiveCompare(name) == .orderedSame
            }
    }

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
    /// What `refreshProfileList()` answers; false models a bridge read that failed.
    var refreshSucceeds = true
    private(set) var removedRows: [String] = []
    func freshProfileIds() -> Set<String>? { refreshSucceeds ? Set(profiles.map(\.profileId)) : nil }
    /// The extra hidden Space uuids each `removeLocalRows` call carried, in call order.
    private(set) var removedRowsAlsoHidden: [Set<String>] = []
    func removeLocalRows(ofDeletedProfile localProfileId: String, alsoHiddenSyncUuids: Set<String>) async {
        removedRows.append(localProfileId)
        removedRowsAlsoHidden.append(alsoHiddenSyncUuids)
    }
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

    // MARK: - Cursor loss

    /// An older build rewrote `sync.phiSpaces` without `profileCursors` and moved the marker past
    /// every Profile entity: a mapped Profile has no cursor, its create CONFLICTs, and the retry's
    /// pull delivers nothing. pu-1's row is one even the replay never delivers, so it keeps
    /// conflicting and must not replay again; pu-9's create succeeds and gives the replay a marker.
    func testACreateThatStillConflictsAfterThePullReplaysOnce() async throws {
        let profiles = FakePhiProfileAccess()
        profiles.profiles = [PhiLocalProfile(profileId: "P1", displayName: "Work", createdAtMs: 0),
                             PhiLocalProfile(profileId: "P9", displayName: "Home", createdAtMs: 0)]
        profiles.mappings = ["P1": "pu-1", "P9": "pu-9"]
        let store = drainedStore()
        let client = FakePhiSyncClient()
        client.bareConflictRoundsForTagHashes = [hash("pu-1"): 100]
        defaults.set(Data("999".utf8), forKey: PhiSyncEngine.markerStateKey)
        let engine = makeEngine(profiles: profiles, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)

        await engine.pushLocalSettings()

        let creates = profileCommits(client).filter { $0.clientTagHash == hash("pu-1") }
        XCTAssertEqual(creates.count, 2, "the create and its scoped retry")
        XCTAssertTrue(creates.allSatisfy { $0.entityId == nil && $0.baseVersion == 0 })
        XCTAssertTrue(client.getUpdatesCalls.allSatisfy { $0.marker == Data("999".utf8) },
                      "precondition: the marker is past every row")
        XCTAssertTrue(store.table.profilesReplayedForEmptyTable)
        XCTAssertFalse(store.table.hasDrainedFullReplay)
        XCTAssertTrue(store.table.drainInProgress)

        await engine.pullOnce()
        XCTAssertNil(client.getUpdatesCalls.last?.marker, "the marker was dropped: a full replay")
        XCTAssertTrue(store.table.hasDrainedFullReplay)
        XCTAssertTrue(store.table.profilesReplayedForEmptyTable, "pu-1 is still without a baseline")

        await engine.pullOnce()
        XCTAssertNotNil(client.getUpdatesCalls.last?.marker)
        XCTAssertEqual(client.getUpdatesCalls.filter { $0.marker == nil }.count, 1, "one replay only")
        XCTAssertTrue(store.table.hasDrainedFullReplay)
        XCTAssertGreaterThan(profileCommits(client).filter { $0.clientTagHash == hash("pu-1") }.count, 2,
                             "pu-1 still conflicts every round")
    }

    func testTheReplayRestoresTheBaselineAndTheNextPublicationIsAnUpdate() async throws {
        let profiles = FakePhiProfileAccess()
        profiles.profiles = [PhiLocalProfile(profileId: "P1", displayName: "Work", createdAtMs: 0)]
        profiles.mappings = ["P1": "pu-1"]
        let store = drainedStore()
        let client = FakePhiSyncClient()
        client.conflictsOnLiveCreate = true
        client.seed(tagHash: hash("pu-1"), ciphertext: try ciphertext(profileEntity("pu-1", "Work")), version: 5,
                    entityId: "srv-pu-1")
        defaults.set(Data("999".utf8), forKey: PhiSyncEngine.markerStateKey)
        let engine = makeEngine(profiles: profiles, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pushLocalSettings()
        XCTAssertTrue(store.table.profilesReplayedForEmptyTable, "precondition: the replay is armed")

        await engine.pullOnce()

        XCTAssertNil(client.getUpdatesCalls.last?.marker)
        let cursor = try XCTUnwrap(store.table.profileCursors["pu-1"])
        XCTAssertEqual(cursor.entityId, "srv-pu-1")
        XCTAssertEqual(cursor.version, 5)
        XCTAssertNotNil(cursor.reconciled)
        XCTAssertNotNil(cursor.server)
        XCTAssertEqual(cursor.localNameAtBaseline, "Work")
        XCTAssertFalse(store.table.profilesReplayedForEmptyTable, "a restored baseline rearms the latch")
        XCTAssertTrue(store.table.hasDrainedFullReplay)

        nowMs += 10_000
        profiles.profiles[0].displayName = "Office"
        await engine.handleLocalProfilesChange()

        let last = try XCTUnwrap(profileCommits(client).last)
        XCTAssertEqual(last.entityId, "srv-pu-1", "an update, not another create")
        XCTAssertEqual(last.baseVersion, 5)
        XCTAssertEqual(try published(client, "pu-1").name.stringValue, "Office")
    }

    func testAConflictOnAPublishedProfileDoesNotReplay() async throws {
        let profiles = FakePhiProfileAccess()
        profiles.profiles = [PhiLocalProfile(profileId: "P1", displayName: "Work", createdAtMs: 0)]
        profiles.mappings = ["P1": "pu-1"]
        let store = drainedStore()
        let client = FakePhiSyncClient()
        client.seed(tagHash: hash("pu-1"), ciphertext: try ciphertext(profileEntity("pu-1", "Work")), version: 3)
        let engine = makeEngine(profiles: profiles, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        nowMs += 10_000
        profiles.profiles[0].displayName = "Office"
        client.bareConflictRoundsForTagHashes = [hash("pu-1"): 2]
        await engine.pushLocalSettings()

        let commits = profileCommits(client)
        XCTAssertEqual(commits.count, 2, "the update and its scoped retry")
        XCTAssertTrue(commits.allSatisfy { $0.entityId != nil && $0.baseVersion == 3 })
        XCTAssertFalse(store.table.profilesReplayedForEmptyTable)
        XCTAssertTrue(store.table.hasDrainedFullReplay)
        XCTAssertFalse(store.table.drainInProgress)

        await engine.pullOnce()
        XCTAssertEqual(client.getUpdatesCalls.filter { $0.marker == nil }.count, 1, "only the first pull")
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

    // MARK: - Pins of a Profile this device never mapped

    // A replay (fresh install, or "Remove from sync" + rejoin) can deliver a pin owned by an account
    // Profile deleted before this device knew it, together with that Profile's tombstone. The pin
    // names the uuid, so the pull indexes it under its Profile tag; the tombstone records a deleted
    // Profile cursor and landing discards the pin (dead owner, as R-M3-4a-78 does for Spaces) instead
    // of parking it every round (PR #181 acceptance 2026-10-12).

    private func pinTag(_ lineage: String, owner: String) -> String {
        PhiSyncEntity.pinClientTag(lineage, ownerKey: owner)
    }

    private func pinEntity(_ lineage: String, owner: String, version: Int64) -> PhiRemoteEntity {
        remoteEntity(envelope(pinPayload(lineage: lineage, ownerKey: owner)),
                     tag: pinTag(lineage, owner: owner), version: version, entityId: "srv-pin", key: key)
    }

    private func profileTombstone(_ uuid: String, version: Int64) -> PhiRemoteEntity {
        remoteTombstone(tag: PhiSyncEntity.profileClientTag(uuid), version: version, entityId: "srv-\(uuid)")
    }

    /// Profile-scoped pins on a device whose only Profile is Default (pu-1); pu-gone is unknown here.
    private func makePinEngine(pins: FakePinAccess, pinStore: MemoryOwnedItemStore,
                               store: MemorySpaceStore, client: FakePhiSyncClient,
                               profiles: FakePhiProfileAccess? = nil) -> PhiSyncEngine {
        let profiles = profiles ?? FakePhiProfileAccess()
        let spaces = FakePhiSpaceAccess()
        spaces.profileIdByUuid = ["pu-1": "Default"]
        spaces.uuidByProfileId = ["Default": "pu-1"]
        spaces.knownLocalProfileIds = ["Default"]
        profiles.profiles = [PhiLocalProfile(profileId: "Default", displayName: "Personal", createdAtMs: 0)]
        profiles.mappings = ["Default": "pu-1"]
        return PhiSyncEngine(domainKeys: StubDomainKeys(key: key), client: client,
                             defaults: defaults, deviceKeyId: "devA", pairingComplete: true,
                             settings: [], spaceAccess: spaces, spaceStore: store,
                             profileAccess: profiles, ownedKinds: [.pins(access: pins, store: pinStore)],
                             now: { [unowned self] in self.nowMs })
    }

    /// The shared outcome: a deleted Profile cursor, never a Space cursor, and the pin discarded.
    private func assertDeadProfileDiscardedThePin(_ engine: PhiSyncEngine, store: MemorySpaceStore,
                                                  pins: FakePinAccess,
                                                  file: StaticString = #filePath, line: UInt = #line) async {
        let cursor = store.table.profileCursors["pu-gone"]
        XCTAssertEqual(cursor?.deletedAtMs, nowMs, "① the tombstone records a deleted Profile", file: file, line: line)
        XCTAssertEqual(cursor?.entityId, "srv-pu-gone", file: file, line: line)
        XCTAssertTrue(store.table.deletedProfileUuids.contains("pu-gone"), file: file, line: line)
        XCTAssertNil(store.table.cursors["pu-gone"], "② not routed as a Space tombstone", file: file, line: line)
        let table = await engine.ownedTableForTesting("pins")
        let counters = await engine.lastOwnedRoundCountersForTesting["pins"]
        XCTAssertNil(table.cursors["lx:pu-gone"]?.pendingApply, "③ the pin is not parked", file: file, line: line)
        XCTAssertEqual(counters?.parked, 0, "④ nothing waits for the dead owner", file: file, line: line)
        XCTAssertTrue(pins.rows.isEmpty, "⑤ no row is created for a dead owner", file: file, line: line)
    }

    func testAPinAndTheTombstoneOfItsUnknownProfileOnOnePageDiscardThePin() async throws {
        let pins = FakePinAccess(scope: .profile, account: .profile)
        let pinStore = MemoryOwnedItemStore()
        let store = drainedStore()
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([pinEntity("lx", owner: "pu-gone", version: 8),
                                      profileTombstone("pu-gone", version: 9)], marker: "10")]
        let engine = makePinEngine(pins: pins, pinStore: pinStore, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)

        await engine.pullOnce()

        await assertDeadProfileDiscardedThePin(engine, store: store, pins: pins)
    }

    func testATombstoneOnAnEarlierPageIsCarriedUntilAPinNamesItsProfile() async throws {
        let pins = FakePinAccess(scope: .profile, account: .profile)
        let pinStore = MemoryOwnedItemStore()
        let store = drainedStore()
        let client = FakePhiSyncClient()
        // Page one: only the tombstone, whose tag no index knows yet. Page two: the pin naming it.
        client.pagesByMarker = [page([profileTombstone("pu-gone", version: 9)], marker: "10",
                                     changesRemaining: true),
                                page([pinEntity("lx", owner: "pu-gone", version: 18)], marker: "20")]
        let engine = makePinEngine(pins: pins, pinStore: pinStore, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)

        await engine.pullOnce()

        XCTAssertGreaterThanOrEqual(client.getUpdatesCalls.count, 2, "both pages were pulled in one round")
        await assertDeadProfileDiscardedThePin(engine, store: store, pins: pins)
    }

    func testAPinParkedOnAnEarlierPageIsDiscardedWhenItsProfileTombstoneArrives() async throws {
        let pins = FakePinAccess(scope: .profile, account: .profile)
        let pinStore = MemoryOwnedItemStore()
        let store = drainedStore()
        let client = FakePhiSyncClient()
        // Page one parks the pin behind its unknown owner; page two brings the owner's tombstone.
        client.pagesByMarker = [page([pinEntity("lx", owner: "pu-gone", version: 8)], marker: "10",
                                     changesRemaining: true),
                                page([profileTombstone("pu-gone", version: 19)], marker: "20")]
        let engine = makePinEngine(pins: pins, pinStore: pinStore, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)

        await engine.pullOnce()

        XCTAssertGreaterThanOrEqual(client.getUpdatesCalls.count, 2, "both pages were pulled in one round")
        await assertDeadProfileDiscardedThePin(engine, store: store, pins: pins)
    }

    /// The tombstone's page marker is persisted, so the tombstone must be too: the pin naming its
    /// owner arrives only in the next pull (after a quit, or once the page budget ended the round).
    func testATombstoneFromAnEarlierPullIsKeptUntilAPinNamesItsProfile() async throws {
        let pins = FakePinAccess(scope: .profile, account: .profile)
        let pinStore = MemoryOwnedItemStore()
        let store = drainedStore()
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([profileTombstone("pu-gone", version: 9)], marker: "10")]
        let engine = makePinEngine(pins: pins, pinStore: pinStore, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)

        await engine.pullOnce()
        XCTAssertNil(store.table.profileCursors["pu-gone"])
        XCTAssertEqual(store.table.unmatchedTombstones.map(\.clientTagHash), [hash("pu-gone")],
                       "persisted with the page's marker")

        client.pagesByMarker.append(page([pinEntity("lx", owner: "pu-gone", version: 18)], marker: "20"))
        await engine.pullOnce()

        await assertDeadProfileDiscardedThePin(engine, store: store, pins: pins)
        XCTAssertTrue(store.table.unmatchedTombstones.isEmpty, "a matched tombstone leaves the list")
    }

    private func liveProfile(_ uuid: String, _ name: String, version: Int64) throws -> PhiRemoteEntity {
        var wrapper = Phi_PhiEntity()
        wrapper.profile = profileEntity(uuid, name)
        return remoteEntity(wrapper, tag: PhiSyncEntity.profileClientTag(uuid), version: version,
                            entityId: "srv-\(uuid)", key: key)
    }

    /// A carried tombstone is superseded when its Profile is recreated: the live entity evicts it,
    /// so a pin naming the Profile later does not delete the recreated Profile.
    func testARecreatedProfileEvictsItsCarriedTombstone() async throws {
        let pins = FakePinAccess(scope: .profile, account: .profile)
        let pinStore = MemoryOwnedItemStore()
        let store = drainedStore()
        let client = FakePhiSyncClient()
        let profiles = FakePhiProfileAccess()
        client.pagesByMarker = [page([profileTombstone("pu-gone", version: 10)], marker: "10")]
        let engine = makePinEngine(pins: pins, pinStore: pinStore, store: store, client: client, profiles: profiles)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()
        XCTAssertEqual(store.table.unmatchedTombstones.map(\.clientTagHash), [hash("pu-gone")])

        client.pagesByMarker.append(page([try liveProfile("pu-gone", "Work", version: 20)], marker: "20"))
        await engine.pullOnce()
        XCTAssertEqual(store.table.profileCursors["pu-gone"]?.version, 20)
        XCTAssertTrue(store.table.unmatchedTombstones.isEmpty, "the live entity evicted the stale tombstone")
        // Auto-create recreates the local Profile from the entity.
        profiles.profiles.append(PhiLocalProfile(profileId: "Profile 2", displayName: "Work", createdAtMs: 0))
        profiles.mappings["Profile 2"] = "pu-gone"

        client.pagesByMarker.append(page([pinEntity("lx", owner: "pu-gone", version: 30)], marker: "30"))
        await engine.pullOnce()

        XCTAssertTrue(profiles.remoteDeletions.isEmpty)
        XCTAssertEqual(store.table.profileCursors["pu-gone"]?.version, 20)
        XCTAssertNil(store.table.profileCursors["pu-gone"]?.deletedAtMs)
        XCTAssertFalse(store.table.unmatchedTombstones.contains { $0.clientTagHash == hash("pu-gone") })
    }

    /// A tombstone older than the live cursor (a stale carried one) deletes nothing.
    func testAProfileTombstoneOlderThanTheLiveCursorIsIgnored() async throws {
        let profiles = FakePhiProfileAccess()
        profiles.profiles = [PhiLocalProfile(profileId: "P1", displayName: "Work", createdAtMs: 0)]
        profiles.mappings = ["P1": "pu-1"]
        let store = drainedStore()
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([try liveProfile("pu-1", "Work", version: 20)], marker: "20")]
        let engine = makeEngine(profiles: profiles, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()
        let before = store.table.profileCursors["pu-1"]
        XCTAssertEqual(before?.version, 20)

        client.pagesByMarker.append(page([profileTombstone("pu-1", version: 10)], marker: "30"))
        await engine.pullOnce()

        XCTAssertTrue(profiles.remoteDeletions.isEmpty)
        XCTAssertEqual(store.table.profileCursors["pu-1"], before, "no cursor write")
    }

    /// The key registry names every account Profile, so a tombstone for one this device never
    /// mapped and nothing names resolves on its own page and is never carried.
    func testAProfileTombstoneKnownOnlyToTheRegistryLandsOnItsOwnPage() async throws {
        let profiles = FakePhiProfileAccess()
        profiles.registryUuids = ["pu-old"]
        let store = drainedStore()
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([profileTombstone("pu-old", version: 9)], marker: "10")]
        let engine = makeEngine(profiles: profiles, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)

        await engine.pullOnce()

        XCTAssertEqual(store.table.profileCursors["pu-old"]?.deletedAtMs, nowMs)
        XCTAssertEqual(store.table.profileCursors["pu-old"]?.entityId, "srv-pu-old")
        XCTAssertTrue(store.table.unmatchedTombstones.isEmpty, "never enters the carried list")
        XCTAssertTrue(profiles.remoteDeletions.isEmpty, "no local Profile to delete")
    }

    func testATombstoneNoOwnedItemNamesIsStillIgnored() async throws {
        let pins = FakePinAccess(scope: .profile, account: .profile)
        let pinStore = MemoryOwnedItemStore()
        let store = drainedStore()
        let client = FakePhiSyncClient()
        // The pin names pu-gone, but the only tombstone is pu-other's, which nothing names.
        client.pagesByMarker = [page([pinEntity("lx", owner: "pu-gone", version: 8),
                                      profileTombstone("pu-other", version: 9)], marker: "10")]
        let engine = makePinEngine(pins: pins, pinStore: pinStore, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)

        await engine.pullOnce()

        XCTAssertNil(store.table.profileCursors["pu-other"], "an unknown tag creates no Profile cursor")
        XCTAssertNil(store.table.cursors["pu-other"], "nor a Space cursor")
        XCTAssertNil(store.table.profileCursors["pu-gone"], "indexing an owner alone records nothing")
        let table = await engine.ownedTableForTesting("pins")
        let counters = await engine.lastOwnedRoundCountersForTesting["pins"]
        XCTAssertNotNil(table.cursors["lx:pu-gone"]?.pendingApply, "without its owner's tombstone the pin parks")
        XCTAssertEqual(table.cursors["lx:pu-gone"]?.pendingOwnerUuid, "pu-gone")
        XCTAssertEqual(counters?.parked, 1)
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

    /// A Space hidden by a tombstone on the same page as its Profile's tombstone is not in the
    /// stored table yet; the row removal is told about it, so the hidden row goes with the Profile.
    func testSpacesHiddenOnTheSamePageAreRemovedWithTheProfile() async throws {
        let profiles = FakePhiProfileAccess()
        profiles.profiles = [PhiLocalProfile(profileId: "P1", displayName: "Work", createdAtMs: 0)]
        profiles.mappings = ["P1": "pu-1"]
        let spaces = FakePhiSpaceAccess()
        spaces.spaceMappings = ["S1": "su-1"]
        let store = drainedStore()
        var spaceCursor = PhiSpaceCursor()
        spaceCursor.entityId = "srv-su-1"
        spaceCursor.version = 2
        store.table.cursors["su-1"] = spaceCursor
        let client = FakePhiSyncClient()
        client.seed(tagHash: hash("pu-1"), ciphertext: try ciphertext(profileEntity("pu-1", "Work")), version: 3)
        let engine = makeEngine(spaces: spaces, profiles: profiles, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()
        XCTAssertFalse(store.table.hiddenSyncUuids.contains("su-1"))

        // One page: the Space's tombstone, then its Profile's.
        client.seed(tagHash: PhiSyncEntity.clientTagHash(for: PhiSyncEntity.spaceClientTag("su-1")),
                    ciphertext: Data(), version: 10, entityId: "srv-su-1", deleted: true)
        tombstone(client, version: 11)
        await engine.pullOnce()

        XCTAssertEqual(profiles.remoteDeletions, ["P1"])
        XCTAssertTrue(store.table.hiddenSyncUuids.contains("su-1"))
        let index = try XCTUnwrap(profiles.removedRows.firstIndex(of: "P1"))
        XCTAssertTrue(profiles.removedRowsAlsoHidden[index].contains("su-1"),
                      "the page's working table names the Space it just hid")
    }

    func testAnAgentSpaceDefersTheTombstoneUntilItIsGone() async throws {
        let profiles = FakePhiProfileAccess()
        let store = drainedStore()
        let client = FakePhiSyncClient()
        let engine = try await landedProfile(profiles, client, store: store)
        profiles.blockers["P1"] = ProfileDeletionBlockers(hasRunningAgentSpace: true)
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
        deleteLocally(profiles)                    // committed here when the peer's tombstone lands
        tombstone(client, version: 9)

        await engine.pullOnce()

        XCTAssertTrue(profiles.remoteDeletions.isEmpty)
        XCTAssertNotNil(store.table.profileCursors["pu-1"]?.deletedAtMs)
        XCTAssertTrue(profiles.intents.isEmpty)
    }

    // MARK: - Review fixes

    func testAProfileDeletedBeforePublicationIsTombstonedWhenAPeerPublishesIt() async throws {
        let profiles = FakePhiProfileAccess()
        profiles.mappings = ["P1": "pu-1"]
        profiles.intents["pu-1"] = "P1"
        let store = drainedStore()
        let client = FakePhiSyncClient()
        let engine = makeEngine(profiles: profiles, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.recordLocalProfileDeletion(syncUuid: "pu-1")
        XCTAssertEqual(store.table.profileCursors["pu-1"]?.deletedBeforePublish, true)
        XCTAssertTrue(profiles.intents.isEmpty)
        XCTAssertEqual(profiles.removedRows, ["P1"], "leftover rows are removed again")

        client.seed(tagHash: hash("pu-1"), ciphertext: try ciphertext(profileEntity("pu-1", "Work")), version: 5)
        await engine.pullOnce()

        let tombstone = try XCTUnwrap(profileCommits(client).last)
        XCTAssertTrue(tombstone.deleted, "delete beats create")
        XCTAssertEqual(tombstone.baseVersion, 5)
        XCTAssertTrue(profiles.droppedMappings.isEmpty, "never resurrected")
        XCTAssertNotNil(store.table.profileCursors["pu-1"]?.deletedAtMs)
        XCTAssertTrue(store.table.liveProfileEntityUuids.isEmpty)
    }

    func testAPeerTombstoneWaitsForAnInFlightLocalDeletionThatThenFails() async throws {
        let profiles = FakePhiProfileAccess()
        let store = drainedStore()
        let client = FakePhiSyncClient()
        let engine = try await landedProfile(profiles, client, store: store)
        profiles.intents["pu-1"] = "P1"
        profiles.inFlight = ["pu-1"]
        tombstone(client, version: 9)

        await engine.pullOnce()
        XCTAssertEqual(store.table.profileCursors["pu-1"]?.pendingTombstone, true)
        XCTAssertNil(store.table.profileCursors["pu-1"]?.deletedAtMs)
        XCTAssertEqual(profiles.intents, ["pu-1": "P1"], "the journal entry survives the in-flight deletion")

        // The Chromium deletion fails: the intent is cancelled and P1 stays.
        profiles.intents = [:]
        profiles.inFlight = []
        await engine.pullOnce()
        XCTAssertEqual(profiles.remoteDeletions, ["P1"], "the follower decides it like any tombstone")
        XCTAssertNotNil(store.table.profileCursors["pu-1"]?.deletedAtMs)
    }

    func testADeletedCursorWhoseLocalProfileSurvivedIsDecidedAgain() async throws {
        let profiles = FakePhiProfileAccess()
        let store = drainedStore()
        let client = FakePhiSyncClient()
        let engine = try await landedProfile(profiles, client, store: store)
        store.table.profileCursors["pu-1"]?.deletedAtMs = 1   // recorded, never applied
        profiles.blockers["P1"] = ProfileDeletionBlockers(isDefaultProfile: true)

        await engine.pullOnce()

        XCTAssertNil(store.table.profileCursors["pu-1"]?.deletedAtMs)
        XCTAssertEqual(profileCommits(client).last?.deleted, false, "kept and republished")
    }

    func testAPersistentAgentSpaceUndeletesAtOnce() async throws {
        let profiles = FakePhiProfileAccess()
        let store = drainedStore()
        let client = FakePhiSyncClient()
        let engine = try await landedProfile(profiles, client, store: store)
        profiles.blockers["P1"] = ProfileDeletionBlockers(hasPersistentAgentSpace: true)
        tombstone(client, version: 9)

        await engine.pullOnce()

        XCTAssertTrue(profiles.remoteDeletions.isEmpty)
        XCTAssertEqual(store.table.profileCursors["pu-1"]?.pendingTombstone, false)
        XCTAssertEqual(profileCommits(client).last?.deleted, false)
    }

    func testARunningAgentSpaceDefersAtMostTwoHours() async throws {
        let profiles = FakePhiProfileAccess()
        let store = drainedStore()
        let client = FakePhiSyncClient()
        let engine = try await landedProfile(profiles, client, store: store)
        profiles.blockers["P1"] = ProfileDeletionBlockers(hasRunningAgentSpace: true)
        tombstone(client, version: 9)

        for _ in 0..<12 { await engine.pullOnce() }
        nowMs += PhiSyncEngine.profileTombstoneDeferLimitMs - 1
        await engine.pullOnce()
        XCTAssertEqual(store.table.profileCursors["pu-1"]?.pendingTombstone, true, "rounds alone never undelete")
        nowMs += 1
        await engine.pullOnce()

        XCTAssertEqual(store.table.profileCursors["pu-1"]?.pendingTombstone, false)
        XCTAssertNil(store.table.profileCursors["pu-1"]?.firstDeferredAtMs)
        XCTAssertNil(store.table.profileCursors["pu-1"]?.deletedAtMs)
        XCTAssertEqual(profileCommits(client).last?.deleted, false)
        XCTAssertTrue(profiles.remoteDeletions.isEmpty)
    }

    func testADeferralAndOneChromiumFailureDoNotUndelete() async throws {
        let profiles = FakePhiProfileAccess()
        let store = drainedStore()
        let client = FakePhiSyncClient()
        let engine = try await landedProfile(profiles, client, store: store)
        profiles.blockers["P1"] = ProfileDeletionBlockers(isImporting: true)
        tombstone(client, version: 9)
        await engine.pullOnce()
        await engine.pullOnce()
        profiles.blockers = [:]
        profiles.deleteResults = [false]

        await engine.pullOnce()

        XCTAssertEqual(store.table.profileCursors["pu-1"]?.pendingTombstone, true)
        XCTAssertEqual(store.table.profileCursors["pu-1"]?.tombstoneDeferRounds, 1)
        await engine.pullOnce()
        XCTAssertEqual(profiles.remoteDeletions, ["P1", "P1"])
        XCTAssertNotNil(store.table.profileCursors["pu-1"]?.deletedAtMs)
    }

    func testAPurgedProfileDeletedBeforePublicationIsStillTombstoned() async throws {
        let profiles = FakePhiProfileAccess()
        profiles.mappings = ["P1": "pu-1"]
        let store = drainedStore()
        var cursor = PhiProfileCursor()
        cursor.deletedAtMs = nowMs
        cursor.deletedBeforePublish = true
        store.table.profileCursors["pu-1"] = cursor
        let client = FakePhiSyncClient()
        let engine = makeEngine(profiles: profiles, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        nowMs += PhiSpaceSyncState.retentionMs + 1
        await engine.runRetentionSweep()
        XCTAssertNotNil(store.table.profileCursors["pu-1"]?.purgedAtMs)
        XCTAssertEqual(store.table.profileCursors["pu-1"]?.deletedBeforePublish, true)

        client.seed(tagHash: hash("pu-1"), ciphertext: try ciphertext(profileEntity("pu-1", "Work")), version: 1)
        await engine.pullOnce()

        XCTAssertEqual(profileCommits(client).last?.deleted, true, "tombstoned, never resurrected")
        XCTAssertTrue(store.table.liveProfileEntityUuids.isEmpty)
    }

    func testAnInFlightLocalDeletionThatSucceedsAfterAPeerTombstoneCommitsNothing() async throws {
        let profiles = FakePhiProfileAccess()
        let store = drainedStore()
        let client = FakePhiSyncClient()
        let engine = try await landedProfile(profiles, client, store: store)
        profiles.intents["pu-1"] = "P1"
        profiles.inFlight = ["pu-1"]
        tombstone(client, version: 9)
        await engine.pullOnce()
        XCTAssertEqual(store.table.profileCursors["pu-1"]?.pendingTombstone, true)

        // Chromium's deletion succeeds.
        profiles.inFlight = []
        profiles.profiles = []
        await engine.recordLocalProfileDeletion(syncUuid: "pu-1")
        await engine.handleLocalProfilesChange()

        XCTAssertFalse(profileCommits(client).contains { $0.deleted }, "the peer's tombstone already stands")
        XCTAssertNotNil(store.table.profileCursors["pu-1"]?.deletedAtMs)
        XCTAssertEqual(store.table.profileCursors["pu-1"]?.pendingTombstone, false)
        XCTAssertTrue(profiles.intents.isEmpty)
    }

    func testAnIntentIsKeptWhenTheProfileListCouldNotBeReread() async throws {
        let profiles = FakePhiProfileAccess()
        let store = drainedStore()
        let client = FakePhiSyncClient()
        let engine = try await landedProfile(profiles, client, store: store)
        profiles.intents["pu-1"] = "P1"
        profiles.refreshSucceeds = false

        await engine.handleLocalProfilesChange()

        XCTAssertEqual(profiles.intents, ["pu-1": "P1"], "a stale list proves nothing")
        XCTAssertFalse(profileCommits(client).contains { $0.deleted })
    }

    func testAnUndeleteKeepsANewerClientsReservedFields() async throws {
        let profiles = FakePhiProfileAccess()
        profiles.profiles = [PhiLocalProfile(profileId: "P1", displayName: "Work", createdAtMs: 0)]
        profiles.mappings = ["P1": "pu-1"]
        profiles.blockers["P1"] = ProfileDeletionBlockers(isDefaultProfile: true)
        let store = drainedStore()
        let client = FakePhiSyncClient()
        let withReserved = try Phi_PhiProfileEntity(
            serializedBytes: try profileEntity("pu-1", "Work").serializedData() + Data([0x20, 0x05]))
        client.seed(tagHash: hash("pu-1"), ciphertext: try ciphertext(withReserved), version: 3)
        let engine = makeEngine(profiles: profiles, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()
        tombstone(client, version: 9)

        await engine.pullOnce()

        XCTAssertEqual([UInt8](try published(client, "pu-1").unknownFields.data), [0x20, 0x05])
    }

    /// `created_at_ms` is published from the local Profile row and merged with min() of the
    /// non-zero values: the earliest device's creation instant wins everywhere.
    func testTheEarliestCreationInstantWinsOnTheAccount() async throws {
        let profiles = FakePhiProfileAccess()
        profiles.profiles = [PhiLocalProfile(profileId: "P1", displayName: "Work", createdAtMs: 900)]
        profiles.mappings = ["P1": "pu-1"]
        let store = drainedStore()
        let client = FakePhiSyncClient()
        var peer = profileEntity("pu-1", "Work")
        peer.createdAtMs = 500
        client.seed(tagHash: hash("pu-1"), ciphertext: try ciphertext(peer), version: 3)
        let engine = makeEngine(profiles: profiles, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)

        await engine.pullOnce()
        XCTAssertTrue(profileCommits(client).isEmpty, "the later local instant changes nothing")

        // A device that published first, with a later instant, is corrected by the earlier one.
        let other = FakePhiProfileAccess()
        other.profiles = [PhiLocalProfile(profileId: "Q1", displayName: "Home", createdAtMs: 300)]
        other.mappings = ["Q1": "pu-2"]
        var late = profileEntity("pu-2", "Home")
        late.createdAtMs = 800
        client.seed(tagHash: hash("pu-2"), ciphertext: try ciphertext(late), version: 4)
        let second = makeEngine(profiles: other, store: drainedStore(), client: client)
        await second.setSpaceSyncEnabled(true)
        await second.pullOnce()

        XCTAssertEqual(try published(client, "pu-2").createdAtMs, 300)
        XCTAssertEqual(try published(client, "pu-1").createdAtMs, 500)
    }

    // MARK: - Duplicate names across devices

    /// Two Macs on one account, one fake server. Each has the two Profiles X and Y mapped.
    private struct Mac {
        let profiles: FakePhiProfileAccess
        let store: MemorySpaceStore
        let engine: PhiSyncEngine
    }

    private func mac(_ client: FakePhiSyncClient, suite: String) -> Mac {
        let profiles = FakePhiProfileAccess()
        profiles.profiles = [PhiLocalProfile(profileId: "X", displayName: "Work", createdAtMs: 0),
                             PhiLocalProfile(profileId: "Y", displayName: "Home", createdAtMs: 0)]
        profiles.mappings = ["X": "pu-x", "Y": "pu-y"]
        let store = drainedStore()
        let suiteDefaults = UserDefaults(suiteName: "\(suiteName!).\(suite)")!
        let engine = PhiSyncEngine(domainKeys: StubDomainKeys(key: key), client: client,
                                   defaults: suiteDefaults, deviceKeyId: suite, pairingComplete: true,
                                   settings: [], spaceAccess: FakePhiSpaceAccess(), spaceStore: store,
                                   profileAccess: profiles, now: { [unowned self] in self.nowMs })
        return Mac(profiles: profiles, store: store, engine: engine)
    }

    private func names(_ mac: Mac) -> [String: String] {
        Dictionary(uniqueKeysWithValues: mac.profiles.profiles.map { ($0.profileId, $0.displayName) })
    }

    func testTwoMacsGivingDifferentProfilesTheSameNameConverge() async throws {
        let client = FakePhiSyncClient()
        let a = mac(client, suite: "A")
        let b = mac(client, suite: "B")
        for m in [a, b] { await m.engine.setSpaceSyncEnabled(true) }
        await a.engine.pullOnce()           // publishes X and Y
        await b.engine.pullOnce()           // lands them

        nowMs += 1_000
        a.profiles.profiles[0].displayName = "Gemma"      // A: X -> Gemma at t1
        await a.engine.handleLocalProfilesChange()
        nowMs += 1_000
        b.profiles.profiles[1].displayName = "Gemma"      // B (not yet synced): Y -> Gemma at t2
        await b.engine.handleLocalProfilesChange()

        for _ in 0..<4 {
            nowMs += 1_000
            await a.engine.pullOnce()
            await b.engine.pullOnce()
        }

        XCTAssertEqual(names(a), ["X": "Gemma", "Y": "Gemma (2)"])
        XCTAssertEqual(names(b), ["X": "Gemma", "Y": "Gemma (2)"])
        XCTAssertEqual(try published(client, "pu-x").name.stringValue, "Gemma")
        XCTAssertEqual(try published(client, "pu-y").name.stringValue, "Gemma (2)")
    }

    /// The loser's own local rename can land suffixed ("Gemma (3)") while its twin still holds the
    /// local "Gemma (2)"; the reclaim then settles both on the account names within two rounds
    /// (X first, which frees "Gemma (2)" for Y).
    func testTheReclaimReleasesALocalSuffixInTheNextRound() async throws {
        let profiles = FakePhiProfileAccess()
        profiles.profiles = [PhiLocalProfile(profileId: "X", displayName: "Gemma (2)", createdAtMs: 0),
                             PhiLocalProfile(profileId: "Y", displayName: "Gemma (3)", createdAtMs: 0)]
        profiles.mappings = ["X": "pu-x", "Y": "pu-y"]
        let store = drainedStore()
        for (uuid, name, local) in [("pu-x", "Gemma", "Gemma (2)"), ("pu-y", "Gemma (2)", "Gemma (3)")] {
            var cursor = PhiProfileCursor()
            cursor.entityId = "e-\(uuid)"
            cursor.version = 5
            cursor.reconciled = try profileEntity(uuid, name).serializedData()
            cursor.server = cursor.reconciled
            cursor.localNameAtBaseline = local
            store.table.profileCursors[uuid] = cursor
        }
        let client = FakePhiSyncClient()
        let engine = makeEngine(profiles: profiles, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)

        await engine.pullOnce()
        XCTAssertEqual(profiles.profiles[0].displayName, "Gemma", "X reclaims its account name first")
        await engine.pullOnce()
        XCTAssertEqual(profiles.profiles.map(\.displayName), ["Gemma", "Gemma (2)"])
        XCTAssertEqual(store.table.profileCursors["pu-y"]?.localNameAtBaseline, "Gemma (2)")
        XCTAssertTrue(profileCommits(client).isEmpty, "a reclaim publishes nothing")
    }

    func testANameHeldByALocalOnlyProfileStaysALocalSuffix() async throws {
        let profiles = FakePhiProfileAccess()
        profiles.otherLocalNames = ["Work"]               // e.g. an unmapped local Profile
        profiles.profiles = [PhiLocalProfile(profileId: "P1", displayName: "Work (2)", createdAtMs: 0)]
        profiles.mappings = ["P1": "pu-1"]
        let store = drainedStore()
        let client = FakePhiSyncClient()
        client.seed(tagHash: hash("pu-1"), ciphertext: try ciphertext(profileEntity("pu-1", "Work")), version: 3)
        let engine = makeEngine(profiles: profiles, store: store, client: client)
        await engine.setSpaceSyncEnabled(true)

        await engine.pullOnce()
        await engine.pullOnce()

        XCTAssertEqual(profiles.profiles[0].displayName, "Work (2)")
        XCTAssertTrue(profileCommits(client).isEmpty, "the local suffix is never published")
    }
}

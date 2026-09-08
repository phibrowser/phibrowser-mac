import XCTest
@testable import Phi

final class PhiSpaceSyncStateTests: XCTestCase {

    final class FakeStore: PhiSpaceSyncStateStore {
        var table = PhiSpaceSyncTable()
        private(set) var saves = 0
        func load() -> PhiSpaceSyncTable { table }
        func save(_ table: PhiSpaceSyncTable) { self.table = table; saves += 1 }
    }

    private func published(_ uuid: String, entityId: String = "srv-1") -> PhiSpaceCursor {
        var cursor = PhiSpaceCursor()
        cursor.entityId = entityId
        cursor.version = 4
        cursor.reconciled = Data([0x01])
        cursor.server = Data([0x01])
        return cursor
    }

    func testTableRoundTripsThroughCodable() throws {
        var table = PhiSpaceSyncTable()
        table.cursors["u1"] = published("u1")
        table.firstSyncDecision = "keepBoth"
        table.hasDrainedFullReplay = true
        table.unreadableTagHashes["abcd1234"] = 99
        let bytes = try JSONEncoder().encode(table)
        XCTAssertEqual(try JSONDecoder().decode(PhiSpaceSyncTable.self, from: bytes), table)
    }

    // MARK: - recordLocalDeletion (§9.1: the criterion is entityId, not "has a cursor")

    func testRecordLocalDeletionMarksAPublishedSpace() {
        var table = PhiSpaceSyncTable()
        table.cursors["u1"] = published("u1")
        XCTAssertTrue(table.recordLocalDeletion(spaceId: "u1"))
        XCTAssertTrue(table.cursors["u1"]!.pendingDelete)
    }

    func testRecordLocalDeletionIgnoresANeverPublishedSpace() {
        var table = PhiSpaceSyncTable()
        XCTAssertFalse(table.recordLocalDeletion(spaceId: "never"))
        XCTAssertNil(table.cursors["never"])
    }

    /// The exact case the "has a cursor" criterion would get wrong: a refused
    /// agent entity owns a cursor carrying only `refusedAtMs`.
    func testRecordLocalDeletionIgnoresARefusedAgentEntity() {
        var table = PhiSpaceSyncTable()
        var refused = PhiSpaceCursor()
        refused.refusedAtMs = 1_700_000_000_000
        table.cursors["agent"] = refused
        XCTAssertFalse(table.recordLocalDeletion(spaceId: "agent"))
        XCTAssertFalse(table.cursors["agent"]!.pendingDelete)
    }

    func testRecordLocalDeletionIgnoresHiddenAndSoftDeletedSpaces() {
        var table = PhiSpaceSyncTable()
        var hidden = published("h")
        hidden.hidden = true
        hidden.entityId = nil
        table.cursors["h"] = hidden
        var softDeleted = published("d")
        softDeleted.deletedAtMs = 1_700_000_000_000
        table.cursors["d"] = softDeleted
        XCTAssertFalse(table.recordLocalDeletion(spaceId: "h"))
        XCTAssertFalse(table.recordLocalDeletion(spaceId: "d"))
    }

    // MARK: - hidden vs unsynced (§8.3)

    func testUnsyncedExcludesSoftDeletedWhileHiddenIncludesIt() {
        var table = PhiSpaceSyncTable()
        var d2Hidden = PhiSpaceCursor()
        d2Hidden.hidden = true
        table.cursors["local-only"] = d2Hidden
        var softDeleted = published("gone")
        softDeleted.hidden = true
        softDeleted.deletedAtMs = 1_700_000_000_000
        table.cursors["gone"] = softDeleted

        XCTAssertEqual(table.hiddenSpaceIds, ["local-only", "gone"])
        XCTAssertEqual(table.unsyncedSpaceIds, ["local-only"])
    }

    func testJoinAccountSyncIsANoOpForSoftDeletedOrAlreadyPublished() {
        var table = PhiSpaceSyncTable()
        var softDeleted = published("gone")
        softDeleted.hidden = true
        softDeleted.deletedAtMs = 1
        table.cursors["gone"] = softDeleted
        var published2 = published("pub")
        published2.hidden = true
        table.cursors["pub"] = published2
        var d2 = PhiSpaceCursor()
        d2.hidden = true
        table.cursors["local"] = d2

        XCTAssertFalse(table.joinAccountSync(spaceId: "gone"))
        XCTAssertTrue(table.cursors["gone"]!.hidden)
        XCTAssertFalse(table.joinAccountSync(spaceId: "pub"))
        XCTAssertTrue(table.cursors["pub"]!.hidden)
        XCTAssertTrue(table.joinAccountSync(spaceId: "local"))
        XCTAssertFalse(table.cursors["local"]!.hidden)
    }

    // MARK: - 30-day sweep (§9.2)

    func testPurgeExpiredTrimsTheCursorToATombstoneAndKeepsIt() {
        var table = PhiSpaceSyncTable()
        var softDeleted = published("gone")
        softDeleted.hidden = true
        softDeleted.deletedAtMs = 1_000
        softDeleted.pendingApply = Data([0x09])
        softDeleted.heldProfileUuid = "held"
        table.cursors["gone"] = softDeleted

        let purged = table.purgeExpired(nowMs: 1_000 + PhiSpaceSyncState.retentionMs + 1)
        XCTAssertEqual(purged, ["gone"])
        let tombstone = try! XCTUnwrap(table.cursors["gone"])
        XCTAssertNotNil(tombstone.deletedAtMs)
        XCTAssertNotNil(tombstone.purgedAtMs)
        XCTAssertNotNil(tombstone.entityId)
        XCTAssertNil(tombstone.reconciled)
        XCTAssertNil(tombstone.server)
        XCTAssertNil(tombstone.pendingApply)
        XCTAssertNil(tombstone.heldProfileUuid)
    }

    func testPurgeExpiredLeavesFreshSoftDeletesAlone() {
        var table = PhiSpaceSyncTable()
        var softDeleted = published("gone")
        softDeleted.deletedAtMs = 1_000
        table.cursors["gone"] = softDeleted
        XCTAssertTrue(table.purgeExpired(nowMs: 1_000 + 60_000).isEmpty)
        XCTAssertNil(table.cursors["gone"]!.purgedAtMs)
    }

    // MARK: - profile references (§9.4 criteria 1 and 2)

    func testReferencesProfileUuidSeesBaselinesAndHeldBindings() throws {
        var entity = Phi_PhiSpaceEntity()
        entity.spaceUuid = "u1"
        var binding = Phi_PhiSettingValue()
        binding.updatedAtMs = 5
        binding.stringValue = "profile-uuid-a"
        entity.profileUuid = binding

        var table = PhiSpaceSyncTable()
        var cursor = published("u1")
        cursor.server = try entity.serializedData()
        table.cursors["u1"] = cursor
        var held = PhiSpaceCursor()
        held.entityId = "srv-2"
        held.heldProfileUuid = "profile-uuid-b"
        table.cursors["u2"] = held

        XCTAssertTrue(table.referencesProfileUuid("profile-uuid-a"))
        XCTAssertTrue(table.referencesProfileUuid("profile-uuid-b"))
        XCTAssertFalse(table.referencesProfileUuid("profile-uuid-c"))
    }

    func testReferencesProfileUuidIgnoresSoftDeletedCursors() throws {
        var entity = Phi_PhiSpaceEntity()
        entity.spaceUuid = "u1"
        var binding = Phi_PhiSettingValue()
        binding.stringValue = "profile-uuid-a"
        entity.profileUuid = binding
        var table = PhiSpaceSyncTable()
        var cursor = published("u1")
        cursor.server = try entity.serializedData()
        cursor.deletedAtMs = 42
        table.cursors["u1"] = cursor
        XCTAssertFalse(table.referencesProfileUuid("profile-uuid-a"))
    }

    // MARK: - single-writer facade fallback (§5.3 exception)

    @MainActor
    func testIntentsGoToTheSinkWhenAnEngineExists() {
        let state = PhiSpaceSyncState()
        var delivered: [String] = []
        state.intentSink = { intent in
            if case .recordLocalDeletion(let id) = intent { delivered.append(id) }
        }
        state.recordLocalDeletion(spaceId: "u1")
        XCTAssertEqual(delivered, ["u1"])
    }

    @MainActor
    func testIntentsHitDiskDirectlyWhenNoEngineExists() {
        let store = FakeStore()
        store.table.cursors["u1"] = published("u1")
        let state = PhiSpaceSyncState()
        state.directStore = store
        state.recordLocalDeletion(spaceId: "u1")
        XCTAssertTrue(store.table.cursors["u1"]!.pendingDelete)
        XCTAssertEqual(store.saves, 1)
    }

    @MainActor
    func testBlocksProfileDeletionCoversHiddenLocalSpaces() {
        let state = PhiSpaceSyncState()
        var table = PhiSpaceSyncTable()
        table.hasDrainedFullReplay = true
        var hidden = PhiSpaceCursor()
        hidden.hidden = true
        table.cursors["hidden-space"] = hidden
        state.refreshCaches(from: table)
        state.globalUuidLookup = { _ in nil }
        state.localSpaceProfileIds = { [(spaceId: "hidden-space", profileId: "Profile 2")] }
        XCTAssertTrue(state.blocksProfileDeletion(localProfileId: "Profile 2"))
        XCTAssertFalse(state.blocksProfileDeletion(localProfileId: "Profile 3"))
    }

    /// R4: `blocksProfileDeletion` and `referencesProfileUuid` must be reading
    /// the SAME rule. Two copies of "deserialize both baselines, skip the
    /// soft-deleted, compare `profileUuid`" would drift and disagree about
    /// whether a Profile is deletable.
    @MainActor
    func testTheFacadeCacheAgreesWithTheTablePredicate() throws {
        var entity = Phi_PhiSpaceEntity()
        entity.spaceUuid = "u1"
        var binding = Phi_PhiSettingValue()
        binding.updatedAtMs = 5
        binding.stringValue = "uuid-a"
        entity.profileUuid = binding

        var table = PhiSpaceSyncTable()
        table.hasDrainedFullReplay = true
        var cursor = published("u1")
        cursor.server = try entity.serializedData()
        table.cursors["u1"] = cursor
        var held = PhiSpaceCursor()
        held.entityId = "srv-2"
        held.heldProfileUuid = "uuid-b"
        table.cursors["u2"] = held

        XCTAssertEqual(table.referencedProfileUuids(), ["uuid-a", "uuid-b"])
        let state = PhiSpaceSyncState()
        state.refreshCaches(from: table)
        state.localSpaceProfileIds = { [] }
        for (profileId, uuid) in [("P-a", "uuid-a"), ("P-b", "uuid-b"), ("P-c", "uuid-c")] {
            state.globalUuidLookup = { $0 == profileId ? uuid : nil }
            XCTAssertEqual(state.blocksProfileDeletion(localProfileId: profileId),
                           table.referencesProfileUuid(uuid),
                           "the facade cache and the table predicate disagree about \(uuid)")
        }
    }

    @MainActor
    func testBlocksProfileDeletionFailsOpenBeforeTheFirstDrain() {
        let state = PhiSpaceSyncState()
        var table = PhiSpaceSyncTable()
        table.hasDrainedFullReplay = false
        var cursor = PhiSpaceCursor()
        cursor.entityId = "srv"
        cursor.heldProfileUuid = "uuid-a"
        table.cursors["u1"] = cursor
        state.refreshCaches(from: table)
        state.globalUuidLookup = { $0 == "Profile 2" ? "uuid-a" : nil }
        state.localSpaceProfileIds = { [] }
        XCTAssertFalse(state.blocksProfileDeletion(localProfileId: "Profile 2"))
    }
}

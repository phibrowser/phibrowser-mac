import XCTest
@testable import Phi

final class PhiSpaceSyncStateTests: XCTestCase {

    final class FakeStore: PhiSpaceSyncStateStore {
        var table = PhiSpaceSyncTable()
        private(set) var saves = 0
        /// When true, every save returns false without changing table, modeling R-M3-4a-83.
        var failNextSave = false
        private(set) var saveCalls = 0
        func load() -> PhiSpaceSyncTable { table }
        @discardableResult
        func save(_ table: PhiSpaceSyncTable) -> Bool {
            saves += 1
            saveCalls += 1
            guard !failNextSave else { return false }
            self.table = table
            return true
        }
    }

    private func published(_ uuid: String, entityId: String = "srv-1") -> PhiSpaceCursor {
        var cursor = PhiSpaceCursor()
        cursor.entityId = entityId
        cursor.version = 4
        cursor.reconciled = Data([0x01])
        cursor.server = Data([0x01])
        return cursor
    }

    func testTableRoundTripsThroughCodableFieldByField() throws {
        var cursor = PhiSpaceCursor()
        cursor.entityId = "srv-1"
        cursor.version = 4
        cursor.reconciled = Data([0x01])
        cursor.server = Data([0x02])
        cursor.pendingApply = Data([0x03])
        cursor.heldProfileUuid = "held-uuid"
        cursor.heldForLocalProfileId = "Profile 1"
        cursor.pendingDelete = true
        cursor.deleteRejectRounds = 2
        cursor.pendingTombstone = true
        cursor.deletedAtMs = 11
        cursor.hidden = true
        cursor.refusedAtMs = 12
        cursor.purgedAtMs = 13

        var table = PhiSpaceSyncTable()
        table.cursors["sync-u1"] = cursor
        table.drainInProgress = true
        table.hasDrainedFullReplay = true
        table.hadRecords = true
        table.spaceSectionEnabled = true
        table.markerMovedWhileGateShut = true
        table.didReplayForEmptyTable = true
        table.lastDrainedBirthday = "b-1"
        table.unreadableTagHashes["abcd1234"] = 99

        let bytes = try JSONEncoder().encode(table)
        let back = try JSONDecoder().decode(PhiSpaceSyncTable.self, from: bytes)
        XCTAssertEqual(back, table)
        XCTAssertEqual(back.formatVersion, PhiSpaceSyncTable.currentFormatVersion)
        // Assign nondefault values to all fourteen cursor fields. Synthesized Equatable
        // then makes back == table a field-by-field assertion; omitted fields could otherwise escape detection.
        XCTAssertEqual(back.cursors["sync-u1"], cursor)
    }

    /// Previous formatVersion=2 tables lack M3-3's four per-kind flags plus M3-4a's
    /// two additions. They must decode normally with all six false. Synthesized
    /// Decodable ignores property defaults for required fields; new required keys
    /// could invalidate every installed device's table. codableValue swallows failure
    /// as nil, loaded returns an empty table losing cursors, both baselines, hadRecords,
    /// lastDrainedBirthday, and unreadableTagHashes. isStaleFormat can then misclassify
    /// the same failure as old format, overwrite the file, and reopen pairing.
    /// formatVersion cannot prevent this because field additions do not bump it.
    func testATableWrittenBeforeThePerKindFlagsStillDecodes() throws {
        var cursor = PhiSpaceCursor()
        cursor.entityId = "srv-1"
        cursor.version = 7
        cursor.reconciled = Data([0x01])
        var table = PhiSpaceSyncTable()
        table.cursors["sync-u1"] = cursor
        table.hadRecords = true
        table.hasDrainedFullReplay = true
        table.spaceSectionEnabled = true
        table.lastDrainedBirthday = "b-1"
        table.unreadableTagHashes["abcd1234"] = 99
        // M3-4a Task 6: give the third kind's two flags nondefault values and check all six keys.
        table.urlRulesHadRecords = true
        table.urlRulesReplayedForEmptyTable = true
        let encoded = try JSONEncoder().encode(table)
        // Positive case: all six keys decode, with both new flags true; synthesized CodingKeys includes them.
        let full = try JSONDecoder().decode(PhiSpaceSyncTable.self, from: encoded)
        XCTAssertTrue(full.urlRulesHadRecords)
        XCTAssertTrue(full.urlRulesReplayedForEmptyTable)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for key in ["bookmarksHadRecords", "pinsHadRecords",
                    "bookmarksReplayedForEmptyTable", "pinsReplayedForEmptyTable",
                    "urlRulesHadRecords", "urlRulesReplayedForEmptyTable"] {
            XCTAssertNotNil(object.removeValue(forKey: key), "\(key) must be present in the encoding")
        }
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(PhiSpaceSyncTable.self, from: legacy)

        XCTAssertEqual(decoded.formatVersion, PhiSpaceSyncTable.currentFormatVersion)
        XCTAssertEqual(decoded.cursors["sync-u1"], cursor)
        XCTAssertTrue(decoded.hadRecords)
        XCTAssertTrue(decoded.hasDrainedFullReplay)
        XCTAssertTrue(decoded.spaceSectionEnabled)
        XCTAssertEqual(decoded.lastDrainedBirthday, "b-1")
        XCTAssertEqual(decoded.unreadableTagHashes, ["abcd1234": 99])
        XCTAssertFalse(decoded.bookmarksHadRecords)
        XCTAssertFalse(decoded.pinsHadRecords)
        XCTAssertFalse(decoded.bookmarksReplayedForEmptyTable)
        XCTAssertFalse(decoded.pinsReplayedForEmptyTable)
        XCTAssertFalse(decoded.urlRulesHadRecords)
        XCTAssertFalse(decoded.urlRulesReplayedForEmptyTable)
        // Also ensure these bytes are not treated as stale format, discarded, and sent to pairing.
        XCTAssertFalse(PhiSpaceSyncTable.isStaleFormat(rawData: legacy))
    }

    // MARK: - formatVersion reset (§3.6)

    func testAnOlderFormatIsDiscardedIntoAnEmptyTable() throws {
        var old = PhiSpaceSyncTable()
        old.formatVersion = 1
        old.cursors["stale"] = PhiSpaceCursor()
        XCTAssertEqual(PhiSpaceSyncTable.loaded(from: old), PhiSpaceSyncTable())
        XCTAssertTrue(PhiSpaceSyncTable.isStaleFormat(rawData: try JSONEncoder().encode(old)))
    }

    func testACurrentFormatTableIsReturnedUnchanged() throws {
        var current = PhiSpaceSyncTable()
        current.cursors["sync-u1"] = PhiSpaceCursor()
        XCTAssertEqual(PhiSpaceSyncTable.loaded(from: current), current)
        XCTAssertFalse(PhiSpaceSyncTable.isStaleFormat(rawData: try JSONEncoder().encode(current)))
    }

    /// The plist written by f7f37725 lacks formatVersion, so synthesized decoding
    /// throws keyNotFound. This is the actual reset path; the >= 2 check states the rule explicitly.
    func testATableWithNoFormatVersionKeyCannotEvenDecode() {
        let raw = Data(#"{"cursors":{},"drainInProgress":false}"#.utf8)
        XCTAssertNil(try? JSONDecoder().decode(PhiSpaceSyncTable.self, from: raw))
        XCTAssertTrue(PhiSpaceSyncTable.isStaleFormat(rawData: raw))
        XCTAssertEqual(PhiSpaceSyncTable.loaded(from: nil), PhiSpaceSyncTable())
    }

    /// A missing key is not an old table: newly signed-in, never-synced, or persistently
    /// ARK-locked machines may have none. Otherwise every first launch appears discarded
    /// and sets joinPairingPending, which only a measured pass can retire. An offline
    /// launch would silently leave Space sync closed without showing a modal.
    func testAbsentDataIsNotAStaleTable() {
        XCTAssertFalse(PhiSpaceSyncTable.isStaleFormat(rawData: nil))
    }

    func testUndecodableBytesCountAsStale() {
        XCTAssertTrue(PhiSpaceSyncTable.isStaleFormat(rawData: Data([0x00, 0x01, 0x02])))
    }

    // MARK: - Three discardIfStaleFormat cases (§10.3)

    /// Use a fresh random userID per case and remove its users/<uuid>/ subtree
    /// under phiBrowserDataDirectory in tearDown.
    private var scratchAccounts: [Account] = []

    override func tearDown() {
        for account in scratchAccounts {
            // CASE 2a.8 makes defaults/ read-only to force persistence failure; restore permissions before deletion.
            try? Self.setDefaultsDirectoryWritable(true, for: account)
            try? FileManager.default.removeItem(at: account.userDataStorage)
        }
        scratchAccounts = []
        super.tearDown()
    }

    private func makeAccountStateStore() -> (AccountPhiSpaceSyncStateStore, AccountUserDefaults) {
        let (store, defaults, _) = makeAccountStateStoreWithAccount()
        return (store, defaults)
    }

    /// CASE 2a.8 needs Account to change directory permissions, so add a version
    /// returning it while preserving the original helper and its three existing callers.
    private func makeAccountStateStoreWithAccount()
        -> (AccountPhiSpaceSyncStateStore, AccountUserDefaults, Account) {
        let account = Account(userID: UUID().uuidString)
        scratchAccounts.append(account)
        return (AccountPhiSpaceSyncStateStore(defaults: account.userDefaults),
                account.userDefaults, account)
    }

    /// 0o500 allows reads/traversal but prevents the same-directory temporary file required by atomic writes.
    private static func setDefaultsDirectoryWritable(_ writable: Bool, for account: Account) throws {
        let directory = account.userDataStorage
            .appendingPathComponent("defaults", isDirectory: true)
        try FileManager.default.setAttributes([.posixPermissions: writable ? 0o700 : 0o500],
                                              ofItemAtPath: directory.path)
    }

    func testAStaleTableOnDiskIsDiscardedIntoAnEmptyOne() throws {
        let (store, defaults) = makeAccountStateStore()
        var old = PhiSpaceSyncTable()
        old.formatVersion = 1
        old.cursors["stale"] = PhiSpaceCursor()
        defaults.set(old, forCodableKey: AccountPhiSpaceSyncStateStore.defaultsKey)

        XCTAssertTrue(store.discardIfStaleFormat())
        XCTAssertEqual(store.load(), PhiSpaceSyncTable(), "Discard writes an empty table in the current format")
    }

    func testUndecodableBytesOnDiskAreDiscardedToo() {
        let (store, defaults) = makeAccountStateStore()
        defaults.set(Data([0x00, 0x01, 0x02]), forKey: AccountPhiSpaceSyncStateStore.defaultsKey)
        XCTAssertTrue(store.discardIfStaleFormat())
        XCTAssertEqual(store.load(), PhiSpaceSyncTable())
    }

    /// (c) Missing key returns false with no save; the key remaining absent is this
    /// store's observable no-save evidence. Leave joinPairingPending unchanged or every
    /// first launch could be treated as discarded and permanently close Space sync.
    @MainActor
    func testAnAbsentKeyIsNotDiscardedAndWritesNothing() {
        ProfilePairingGate.staticPendingOverride = false
        defer { ProfilePairingGate.staticPendingOverride = nil }
        let (store, defaults) = makeAccountStateStore()
        XCTAssertNil(defaults.data(forKey: AccountPhiSpaceSyncStateStore.defaultsKey))

        XCTAssertFalse(store.discardIfStaleFormat())

        XCTAssertNil(defaults.data(forKey: AccountPhiSpaceSyncStateStore.defaultsKey),
                     "Guard before save: a missing key must cause zero writes")
        XCTAssertFalse(ProfilePairingGate.joinPairingPending,
                       "The store never changes this flag; the coordinator sets it in step 5")
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

    // MARK: - hidden（§9.2）

    func testHiddenSyncUuidsCoverEveryHiddenCursor() {
        var table = PhiSpaceSyncTable()
        var softDeleted = PhiSpaceCursor()
        softDeleted.entityId = "srv-1"
        softDeleted.hidden = true
        softDeleted.deletedAtMs = 1_700_000_000_000
        table.cursors["sync-gone"] = softDeleted
        XCTAssertEqual(table.hiddenSyncUuids, ["sync-gone"])
    }

    // MARK: - hidden implies deletedAtMs is nonnil (R-D6-9)

    /// After D6, hidden means only remote soft deletion. D2 was the sole producer
    /// of hidden without deletedAtMs and disappears in Task 9. Violations silently
    /// remove rows from the strip, with no remaining settings-section D2 rescue path.
    func assertHiddenImpliesDeleted(_ table: PhiSpaceSyncTable,
                                    file: StaticString = #filePath, line: UInt = #line) {
        for (uuid, cursor) in table.cursors where cursor.hidden {
            XCTAssertNotNil(cursor.deletedAtMs,
                            "cursor \(uuid) is hidden with no deletedAtMs", file: file, line: line)
        }
    }

    func testEveryTableMutatorKeepsHiddenImplyingDeleted() {
        var table = PhiSpaceSyncTable()
        var published = PhiSpaceCursor()
        published.entityId = "srv-1"
        published.version = 3
        table.cursors["sync-u1"] = published
        var softDeleted = PhiSpaceCursor()
        softDeleted.entityId = "srv-2"
        softDeleted.version = 3
        softDeleted.hidden = true
        softDeleted.deletedAtMs = 1_000
        table.cursors["sync-u2"] = softDeleted

        table.recordLocalDeletion(spaceId: "sync-u1")
        assertHiddenImpliesDeleted(table)
        _ = table.purgeExpired(nowMs: 1_000 + PhiSpaceSyncState.retentionMs + 1)
        assertHiddenImpliesDeleted(table)
    }

    // MARK: - Derived sets (§3.5)

    func testPublishedSyncUuidsHoldsOnlyCursorsWithAnEntityId() {
        var table = PhiSpaceSyncTable()
        var published = PhiSpaceCursor()
        published.entityId = "srv-1"
        table.cursors["sync-pub"] = published
        var refusedOnly = PhiSpaceCursor()
        refusedOnly.refusedAtMs = 5
        table.cursors["sync-refused"] = refusedOnly
        table.cursors["sync-never"] = PhiSpaceCursor()

        XCTAssertEqual(table.publishedSyncUuids, ["sync-pub"])
    }

    @MainActor
    func testHiddenSyncUuidsAreTranslatedBackToLocalIdsAndUnresolvableOnesAreDropped() {
        let state = PhiSpaceSyncState()
        state.localSpaceIdLookup = { $0 == "sync-a" ? "LOCAL-A" : nil }
        var table = PhiSpaceSyncTable()
        for uuid in ["sync-a", "sync-orphan"] {
            var cursor = PhiSpaceCursor()
            cursor.hidden = true
            cursor.deletedAtMs = 1
            table.cursors[uuid] = cursor
        }
        state.refreshCaches(from: table)
        XCTAssertEqual(state.hiddenSpaceIds, ["LOCAL-A"],
                       "SpaceManager receives local ids only; omit unresolved identities")
        XCTAssertTrue(state.isHidden("LOCAL-A"))
    }

    @MainActor
    func testPublishedSyncUuidsDoNotFireTheHiddenSetNotification() {
        let state = PhiSpaceSyncState()
        state.localSpaceIdLookup = { _ in nil }
        var posts = 0
        let token = NotificationCenter.default.addObserver(
            forName: .phiSpaceHiddenSetDidChange, object: nil, queue: nil) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        var table = PhiSpaceSyncTable()
        var published = PhiSpaceCursor()
        published.entityId = "srv-1"
        table.cursors["sync-pub"] = published
        state.refreshCaches(from: table)
        XCTAssertEqual(state.publishedSyncUuids, ["sync-pub"])
        XCTAssertEqual(posts, 0, "phiSpaceHiddenSetDidChange still depends only on hidden")
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

    /// R-D6-9 changes the third criterion from hidden local Spaces to mapped local
    /// Spaces whose entities have published. Hidden now means remote soft deletion,
    /// and those rows must no longer block Profile deletion.
    @MainActor
    func testBlocksProfileDeletionCoversMappedAndPublishedLocalSpaces() {
        let state = PhiSpaceSyncState()
        var table = PhiSpaceSyncTable()
        table.hasDrainedFullReplay = true
        var published = PhiSpaceCursor()
        published.entityId = "srv-1"
        table.cursors["sync-pub"] = published
        table.cursors["sync-never"] = PhiSpaceCursor()   // Mapped but never published
        state.refreshCaches(from: table)
        state.globalUuidLookup = { _ in nil }
        state.syncUuidLookup = { spaceId in
            ["LOCAL-PUB": "sync-pub", "LOCAL-NEVER": "sync-never"][spaceId]
        }
        state.localSpaceProfileIds = {
            [(spaceId: "LOCAL-PUB", profileId: "Profile 2"),
             (spaceId: "LOCAL-NEVER", profileId: "Profile 3"),
             (spaceId: "LOCAL-UNMAPPED", profileId: "Profile 4")]
        }
        XCTAssertTrue(state.blocksProfileDeletion(localProfileId: "Profile 2"))
        XCTAssertFalse(state.blocksProfileDeletion(localProfileId: "Profile 3"),
                       "Mapped but unpublished Spaces have no account entity to orphan on Profile deletion")
        XCTAssertFalse(state.blocksProfileDeletion(localProfileId: "Profile 4"), "Unmapped Spaces do not block deletion")

        // §10.3 final clause: hasDrainedFullReplay=false always returns false, preserving
        // fail-open behavior. The new third criterion must follow the same guard as the
        // first two; blocking before replay drains could permanently disable Profile
        // deletion on a newly joined machine.
        var undrained = table
        undrained.hasDrainedFullReplay = false
        state.refreshCaches(from: undrained)
        XCTAssertFalse(state.blocksProfileDeletion(localProfileId: "Profile 2"),
                       "Undrained replay remains fail-open for the third criterion too")
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
        state.syncUuidLookup = { _ in nil }
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
        state.syncUuidLookup = { _ in nil }
        XCTAssertFalse(state.blocksProfileDeletion(localProfileId: "Profile 2"))
    }

    // MARK: - CASE 2a.8（R-M3-4a-83）

    /// CASE 2a.8: load returns the old table after save returns false. Preserve
    /// symmetry with the three JSON stores (§2.5 rule 6, paragraph 2). Without rollback,
    /// load returns T2 after failure, and mutateSpaceTable's table != before guard
    /// then exits forever without another save attempt.
    func testAFailedSpaceTableSaveReportsItAndLeavesLoadOnTheOldTable() throws {
        let (store, _, account) = makeAccountStateStoreWithAccount()
        var t1 = PhiSpaceSyncTable()
        t1.cursors["sync-1"] = published("sync-1")
        XCTAssertTrue(store.save(t1), "A successful write returns true")
        XCTAssertEqual(store.load(), t1)

        var t2 = t1
        t2.hasDrainedFullReplay = true
        XCTAssertNotEqual(t1, t2, "Precondition: the tables differ")

        try Self.setDefaultsDirectoryWritable(false, for: account)
        XCTAssertFalse(store.save(t2), "A failed disk write returns false")
        XCTAssertEqual(store.load(), t1, "Rollback keeps memory from getting ahead of disk")

        try Self.setDefaultsDirectoryWritable(true, for: account)
        XCTAssertTrue(store.save(t2))
        XCTAssertEqual(store.load(), t2)
        XCTAssertEqual(
            AccountPhiSpaceSyncStateStore(defaults: AccountUserDefaults(account: account)).load(),
            t2,
            "A fresh instance for the same account reads the persisted value")
    }
}

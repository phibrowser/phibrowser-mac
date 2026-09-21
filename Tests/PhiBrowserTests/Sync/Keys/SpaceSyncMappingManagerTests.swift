import XCTest
@testable import Phi

/// D6 §2.1 mapping-layer safety: one account identity per Space. Duplicate minting
/// creates an unmergeable account Space; an incorrect claim fuses different devices'
/// Spaces. Once written, no UI can undo the mapping.
@MainActor
final class SpaceSyncMappingManagerTests: XCTestCase {

    /// In-memory fake matching ProfileKeyManagerTests.MemoryMappingStore
    /// (ProfileKeyManagerTests.swift:9–16).
    final class MemorySpaceMappingStore: SpaceSyncMappingStore {
        var map: [String: String] = [:]
        /// When true, every setSyncUuid returns false without changing map. A failed disk
        /// write rolls memory back, leaving no UUID behind (R-M3-4a-83).
        var failNextSet = false
        private(set) var setCalls = 0
        func syncUuid(forSpaceId spaceId: String) -> String? { map[spaceId] }
        func setSyncUuid(_ uuid: String, forSpaceId spaceId: String) -> Bool {
            setCalls += 1
            guard !failNextSet else { return false }
            map[spaceId] = uuid
            return true
        }
        func allMappings() -> [String: String] { map }
        func removeMapping(forSpaceId spaceId: String) { map.removeValue(forKey: spaceId) }
        func removeAllMappings() { map = [:] }
    }

    private func makeManager() -> (SpaceSyncMappingManager, MemorySpaceMappingStore) {
        let store = MemorySpaceMappingStore()
        return (SpaceSyncMappingManager(store: store), store)
    }

    /// Local spaceId comes from UUID().uuidString, uppercase (SpaceManager.swift:960).
    private let localId = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"

    // MARK: - 1. Minting

    func testMintWritesALowercaseUuidThatIsNeverTheLocalSpaceId() throws {
        let (keys, store) = makeManager()
        let minted = try keys.mintSyncUuid(forSpaceId: localId)
        XCTAssertEqual(minted, minted.lowercased(),
                       "Lowercase syncUuid makes accidental local-id reuse visible in logs and plists")
        XCTAssertNotEqual(minted, localId, "Never reuse the local spaceId")
        XCTAssertEqual(store.map, [localId: minted])
        XCTAssertEqual(keys.syncUuid(forSpaceId: localId), minted)
    }

    // MARK: - 2. The C-1 safety guarantee

    func testMintRefusesASecondUuidForAnAlreadyMappedSpaceAndLeavesTheTableAlone() throws {
        let (keys, store) = makeManager()
        let first = try keys.mintSyncUuid(forSpaceId: localId)
        XCTAssertThrowsError(try keys.mintSyncUuid(forSpaceId: localId)) { error in
            XCTAssertEqual(error as? SpaceSyncMappingError, .alreadyMapped)
        }
        XCTAssertEqual(store.map, [localId: first], "A transient failure must not mint a second UUID")
    }

    // MARK: - 3. Claiming

    func testMapClaimsAnAccountSpaceAndRefusesADoubleClaim() throws {
        let (keys, store) = makeManager()
        try keys.map(spaceId: localId, toSyncUuid: "acct-1")
        XCTAssertEqual(store.map, [localId: "acct-1"])

        XCTAssertThrowsError(try keys.map(spaceId: "OTHER", toSyncUuid: "acct-1")) { error in
            XCTAssertEqual(error as? SpaceSyncMappingError, .syncUuidAlreadyClaimed)
        }
        XCTAssertThrowsError(try keys.map(spaceId: localId, toSyncUuid: "acct-2")) { error in
            XCTAssertEqual(error as? SpaceSyncMappingError, .alreadyMapped)
        }
        XCTAssertEqual(store.map, [localId: "acct-1"], "Neither rejection may change the table")
    }

    // MARK: - 4. Reverse lookup and tie-breaking

    func testReverseLookupResolvesAndTieBreaksLexicographically() {
        let (keys, store) = makeManager()
        // The syncUuidAlreadyClaimed guard normally prevents this; construct the invalid state directly in the fake.
        store.map = ["ZZZ": "acct-1", "AAA": "acct-1"]
        XCTAssertEqual(keys.localSpaceId(forSyncUuid: "acct-1"), "AAA")
        XCTAssertNil(keys.localSpaceId(forSyncUuid: "acct-nope"))
    }

    // MARK: - 5. Default Space constants in both directions (R-D6-2)

    func testTheDefaultSpaceResolvesBothWaysWithoutAMappingRow() {
        let (keys, store) = makeManager()
        XCTAssertEqual(keys.syncUuid(forSpaceId: LocalStore.defaultSpaceId),
                       SyncableSpaces.defaultSpaceUuid)
        XCTAssertEqual(keys.localSpaceId(forSyncUuid: SyncableSpaces.defaultSpaceUuid),
                       LocalStore.defaultSpaceId)
        XCTAssertTrue(store.map.isEmpty, "The default Space has no persisted mapping row")

        XCTAssertThrowsError(try keys.mintSyncUuid(forSpaceId: LocalStore.defaultSpaceId)) {
            XCTAssertEqual($0 as? SpaceSyncMappingError, .defaultSpaceIsImplicit)
        }
        XCTAssertThrowsError(try keys.map(spaceId: LocalStore.defaultSpaceId, toSyncUuid: "x")) {
            XCTAssertEqual($0 as? SpaceSyncMappingError, .defaultSpaceIsImplicit)
        }
    }

    /// §2.1: equal constant values are a convention asserted here, not a compile-time
    /// dependency. Do not define defaultSpaceUuid as LocalStore.defaultSpaceId.
    func testTheTwoDefaultConstantsAgreeByTestRatherThanByAlias() {
        XCTAssertEqual(SyncableSpaces.defaultSpaceUuid, LocalStore.defaultSpaceId)
        XCTAssertEqual(SyncableSpaces.defaultSpaceUuid, "default-space")
    }

    // MARK: - 6/7. Deletion

    func testRemoveMappingDropsOnlyThatEntry() {
        let (keys, store) = makeManager()
        store.map = ["a": "acct-a", "b": "acct-b"]
        keys.removeMapping(forSpaceId: "a")
        XCTAssertEqual(store.map, ["b": "acct-b"])
        keys.removeMapping(forSpaceId: LocalStore.defaultSpaceId)   // no-op
        XCTAssertEqual(store.map, ["b": "acct-b"])
    }

    /// Self-revoke empties the table, but default-Space resolution must survive. This is
    /// why it uses a constant branch: a stored default-space mapping would be deleted,
    /// and rejoin could no longer send this device's updates to that account entity.
    func testRemoveAllMappingsKeepsTheDefaultSpaceResolvable() {
        let (keys, store) = makeManager()
        store.map = ["a": "acct-a"]
        keys.removeAllMappings()
        XCTAssertTrue(store.map.isEmpty)
        XCTAssertEqual(keys.syncUuid(forSpaceId: LocalStore.defaultSpaceId),
                       SyncableSpaces.defaultSpaceUuid)
        XCTAssertEqual(keys.localSpaceId(forSyncUuid: SyncableSpaces.defaultSpaceUuid),
                       LocalStore.defaultSpaceId)
    }

    // MARK: - 8. Lazy-minting idempotence (R-D6-7)

    func testEnsureMappedIsIdempotent() throws {
        let (keys, store) = makeManager()
        let first = try keys.ensureMapped(spaceId: localId)
        let second = try keys.ensureMapped(spaceId: localId)
        XCTAssertEqual(first, second)
        XCTAssertEqual(store.map.count, 1)
        XCTAssertEqual(try keys.ensureMapped(spaceId: LocalStore.defaultSpaceId),
                       SyncableSpaces.defaultSpaceUuid, "The default Space uses constants without minting or writing the table")
        XCTAssertEqual(store.map.count, 1)
    }

    // MARK: - 9. Reject reserved ids on both sides (R-M3-4a-6, CASE U-R2 / U-R3)

    /// Mapping incognitoRuleTargetId would make it look like a real Space, subjecting its
    /// rules to isEligibleSpace and retention cascades. Yet it has no SpaceModel or Space
    /// cursor and is excluded at the source by currentSpaces().
    func testMapRefusesTheLocalIncognitoReservedIds() {
        let (keys, store) = makeManager()
        XCTAssertThrowsError(try keys.map(spaceId: SpaceManager.incognitoRuleTargetId,
                                          toSyncUuid: "su-9")) {
            XCTAssertEqual($0 as? SpaceSyncMappingError, .reservedSpaceId)
        }
        XCTAssertThrowsError(try keys.map(spaceId: "space.incognito.ABC-123", toSyncUuid: "su-9")) {
            XCTAssertEqual($0 as? SpaceSyncMappingError, .reservedSpaceId)
        }
        XCTAssertTrue(store.allMappings().isEmpty)
    }

    /// The arguments belong to different namespaces (RT-17): spaceId is an uppercase
    /// local UUID and cannot match a reserved sync UUID. One guard inevitably misses one side.
    func testMapRefusesTheAccountReservedUuids() {
        let (keys, store) = makeManager()
        XCTAssertThrowsError(try keys.map(spaceId: "S-1", toSyncUuid: SyncableSpaces.defaultSpaceUuid)) {
            XCTAssertEqual($0 as? SpaceSyncMappingError, .reservedSyncUuid)
        }
        XCTAssertThrowsError(try keys.map(spaceId: "S-1", toSyncUuid: SyncableSpaces.incognitoSpaceUuid)) {
            XCTAssertEqual($0 as? SpaceSyncMappingError, .reservedSyncUuid)
        }
        XCTAssertTrue(store.allMappings().isEmpty)
        // The constant branch is unaffected: the default Space still resolves both ways.
        XCTAssertEqual(keys.localSpaceId(forSyncUuid: SyncableSpaces.defaultSpaceUuid),
                       LocalStore.defaultSpaceId)
        XCTAssertNil(keys.localSpaceId(forSyncUuid: SyncableSpaces.incognitoSpaceUuid),
                     "The reserved constant is not a Space identity and has no mapping")
    }

    // MARK: - Production store (spec §10.1 final row)

    /// AccountUserDefaults requires a real Account (AccountUserDefaults.swift:15–29),
    /// but tests can construct the internal Account(userID:userInfo:) with lazy userDefaults.
    /// AccountPhiSpaceAccessMappingTests.makeAccess already does this in PhiSpaceLocalAccessTests.
    /// The real side effect is users/<uuid>/defaults/ beneath phiBrowserDataDirectory;
    /// use a fresh random userID per case and remove its subtree in tearDown.
    ///
    /// These tests cover removeMapping's missing-key early return and removeAllMappings
    /// saving an empty dictionary rather than removing the key. Both can silently lose
    /// data, and in-memory fakes cannot exercise either persistence path.
    private var scratchAccounts: [Account] = []

    private func makeAccountStore() -> AccountSpaceSyncMappingStore {
        let account = Account(userID: UUID().uuidString)
        scratchAccounts.append(account)
        return AccountSpaceSyncMappingStore(defaults: account.userDefaults)
    }

    override func tearDown() {
        for account in scratchAccounts {
            // B2-18(c) makes defaults/ read-only to force persistence failure; restore permissions before deleting.
            try? Self.setDefaultsDirectoryWritable(true, for: account)
            try? FileManager.default.removeItem(at: account.userDataStorage)
        }
        scratchAccounts = []
        super.tearDown()
    }

    /// 0o500 permits reading/traversal but not writing, preventing the temporary file
    /// needed by atomic writes. This failure is deterministic for the non-root test process.
    private static func setDefaultsDirectoryWritable(_ writable: Bool, for account: Account) throws {
        let directory = account.userDataStorage
            .appendingPathComponent("defaults", isDirectory: true)
        try FileManager.default.setAttributes([.posixPermissions: writable ? 0o700 : 0o500],
                                              ofItemAtPath: directory.path)
    }

    /// The key name defines account isolation; renaming it silently loses existing mappings.
    func testTheAccountStoreUsesTheKeyTheDesignNames() {
        XCTAssertEqual(AccountSpaceSyncMappingStore.defaultsKey, "sync.spaceGlobalUuids")
    }

    func testTheAccountStoreRoundTripsEveryMethodThroughTheAccountPlist() {
        let store = makeAccountStore()
        XCTAssertEqual(store.allMappings(), [:], "An unwritten table reads as empty without a nil crash")

        XCTAssertTrue(store.setSyncUuid("sync-1", forSpaceId: "LOCAL-1"), "A successful write returns true")
        XCTAssertTrue(store.setSyncUuid("sync-2", forSpaceId: "LOCAL-2"))
        XCTAssertEqual(store.syncUuid(forSpaceId: "LOCAL-1"), "sync-1")
        XCTAssertEqual(store.allMappings(), ["LOCAL-1": "sync-1", "LOCAL-2": "sync-2"])

        store.removeMapping(forSpaceId: "LOCAL-1")
        XCTAssertNil(store.syncUuid(forSpaceId: "LOCAL-1"))
        XCTAssertEqual(store.allMappings(), ["LOCAL-2": "sync-2"], "Delete only this row and preserve every other value")
        // Early return: deleting a missing row must not clear the table.
        store.removeMapping(forSpaceId: "LOCAL-404")
        XCTAssertEqual(store.allMappings(), ["LOCAL-2": "sync-2"])

        store.removeAllMappings()
        XCTAssertEqual(store.allMappings(), [:])
    }

    /// Persistence: a second store on the same Account reads the same table. Account
    /// switches require no cleanup because the table belongs to the plist, not the store instance.
    func testASecondStoreOverTheSameAccountReadsTheSameTable() {
        let account = Account(userID: UUID().uuidString)
        scratchAccounts.append(account)
        XCTAssertTrue(AccountSpaceSyncMappingStore(defaults: account.userDefaults)
            .setSyncUuid("sync-1", forSpaceId: "LOCAL-1"))
        XCTAssertEqual(AccountSpaceSyncMappingStore(defaults: account.userDefaults).allMappings(),
                       ["LOCAL-1": "sync-1"])
    }

    // MARK: - B2-18 variant (c) (R-M3-4a-83): Lazy minting

    /// B2-18(c): a SpaceSyncMappingManager backed by a real AccountSpaceSyncMappingStore
    /// with a read-only persistence directory throws persistFailed from ensureMapped.
    /// Immediately afterward syncUuid returns nil and allMappings is empty.
    ///
    /// Rollback happens inside AccountUserDefaults; only a real persistLocked failure
    /// proves no trace remains. Swallowing failure leaves an unpersisted UUID in memory
    /// that pushSpaces publishes. Restart loses the mapping and mints another UUID,
    /// leaving one local Space represented twice in the account.
    func testLazyMintingOnARealStoreLeavesNoTraceWhenThePlistWriteFails() throws {
        let account = Account(userID: UUID().uuidString)
        scratchAccounts.append(account)
        let store = AccountSpaceSyncMappingStore(defaults: account.userDefaults)
        let keys = SpaceSyncMappingManager(store: store)

        try Self.setDefaultsDirectoryWritable(false, for: account)
        XCTAssertThrowsError(try keys.ensureMapped(spaceId: localId)) { error in
            XCTAssertEqual(error as? SpaceSyncMappingError, .persistFailed)
        }
        XCTAssertNil(keys.syncUuid(forSpaceId: localId), "The mapping is absent immediately after the throw")
        XCTAssertNil(store.syncUuid(forSpaceId: localId))
        XCTAssertEqual(store.allMappings(), [:], "Rollback keeps memory from getting ahead of disk")
        XCTAssertNil(keys.localSpaceId(forSyncUuid: localId))

        try Self.setDefaultsDirectoryWritable(true, for: account)
        let minted = try keys.ensureMapped(spaceId: localId)
        XCTAssertEqual(store.allMappings(), [localId: minted])
        XCTAssertEqual(
            AccountSpaceSyncMappingStore(defaults: AccountUserDefaults(account: account))
                .allMappings(),
            [localId: minted],
            "The write persists after permissions are restored")
    }
}

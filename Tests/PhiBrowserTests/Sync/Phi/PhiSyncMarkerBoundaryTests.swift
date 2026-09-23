import CryptoKit
import Foundation
import XCTest
@testable import Phi

/// B-2 marker-boundary tests. Task 2a covers the store halves of B2-4d / B2-10 / B2-18; engine outcomes,
/// marker advancement and push suppression are covered by Task 2b below.
/// Task 3 covers marker.json migration (§2.10 / R-M3-4a-18), B2-11a…d and CASE 3.1 / 3.3 / 3.4 / 3.5. CASE 3.2
/// (self-revoke deletes marker.json again) lives in SelfRevokeTests, which owns the complete SyncKeyController
/// fixture.
/// Task 2b covers B2-1 / 1b / 1c / 1d / 1e / 2 / 4 / 4b / 4c / 4d / 5 / 5b / 6 / 6b / 6c / 7 / 7b / 7c / 8(a)
/// / 8(b) / 8b / 9 / 10 / 12 / 13 / 14 / 15 / 16 / 18. B2-2b's real-LocalStore rowAlreadyMapped case lives in
/// PinnedTabScopeTests. Task 6 / 3b adds B2-3 / B2-17 and the URL-rule assertions in five-kind cases. Crash
/// windows use a fake returning false at the precise boundary and a second engine sharing the stores; no
/// abort() or debug keys are used.
/// Task 3b covers mapping before Space creation (R-M3-4a-87): B2-17 tests A0 recovery after mapping but before
/// row creation; B2-17a tests update after row creation but before cursor save; B2-4d-x tests rollback and
/// replay deduplication after mapping failure. B2-17neg is a documented negative control, not duplicate test
/// code. Task 6 adds rule-side assertions to B2-17.
/// B2-18 variant (b), zero localSpaceIdLookup calls after failNextSave, lives in
/// PhiSyncEngineSpaceTests.testAFailedSpaceTableWriteSkipsTheMainActorCacheRefresh (CASE 2a.9, with a positive
/// control). Variant (c), real-store lazy minting throwing persistFailed, lives in
/// SpaceSyncMappingManagerTests.testLazyMintingOnARealStoreLeavesNoTraceWhenThePlistWriteFails.
/// The fixtures and SpaceSyncMappingManager require @MainActor, so the class is isolated.
@MainActor
final class PhiSyncMarkerBoundaryTests: XCTestCase {
    typealias FakePhiSyncClient = PhiSyncEngineTests.FakePhiSyncClient
    typealias StubDomainKeys = PhiSyncEngineTests.StubDomainKeys
    typealias MemorySpaceStore = PhiSyncEngineSpaceTests.MemorySpaceStore
    typealias MemorySpaceMappingStore = SpaceSyncMappingManagerTests.MemorySpaceMappingStore
    /// One-shot getUpdates gate for CASE 3.5A, shared with PhiSyncEngineTests.
    typealias Gate = PhiSyncEngineTests.Gate

    private var defaults: UserDefaults!
    private var suiteName: String!
    private let key = SymmetricKey(size: .bits256)
    private var scratchAccounts: [Account] = []
    /// Temporary directories for FilePhiSyncMarkerStore cases, removed in tearDown.
    private var scratchDirectories: [URL] = []

    /// Local spaceId uses uppercase UUID().uuidString (SpaceManager.swift); syncUuid is lowercase.
    private let localId = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"

    override func setUp() {
        super.setUp()
        suiteName = "PhiSyncMarkerBoundaryTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        for account in scratchAccounts {
            // Restore permissions before removal so read-only directories do not accumulate.
            try? Self.setDefaultsDirectoryWritable(true, for: account)
            try? FileManager.default.removeItem(at: account.userDataStorage)
        }
        scratchAccounts = []
        for directory in scratchDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        scratchDirectories = []
        super.tearDown()
    }

    // MARK: - Helpers

    /// An empty temporary directory. Do not precreate marker.json: absence is the B2-11a / B2-11d(i)
    /// precondition.
    private func makeScratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhiSyncMarkerBoundaryTests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        scratchDirectories.append(directory)
        return directory
    }

    private func makeFileMarkerStore() throws -> FilePhiSyncMarkerStore {
        FilePhiSyncMarkerStore(fileURL: try makeScratchDirectory().appendingPathComponent("marker.json"))
    }

    /// Matches PhiSyncEngineSpaceTests.makeEngine with markerStore injection. Empty settings prevent the
    /// production registry from committing real settings through this disposable defaults suite.
    private func makeEngine(client: FakePhiSyncClient,
                            markerStore: any PhiSyncMarkerStore,
                            spaceStore: MemorySpaceStore = MemorySpaceStore()) -> PhiSyncEngine {
        PhiSyncEngine(domainKeys: StubDomainKeys(key: key), client: client,
                      defaults: defaults, deviceKeyId: "devA", pairingComplete: true, settings: [],
                      spaceAccess: makeSpaceAccess(), spaceStore: spaceStore,
                      markerStore: markerStore,
                      now: { 1_700_000_000_000 })
    }

    private func makeAccount() -> Account {
        let account = Account(userID: UUID().uuidString)
        scratchAccounts.append(account)
        // userDefaults is lazy; this access creates the defaults/ directory.
        _ = account.userDefaults
        return account
    }

    /// 0o500 permits reading and traversal but denies writes. Atomic persistence needs a sibling temporary
    /// file, so it deterministically fails in this non-root test process. B2-18 needs the real persistLocked
    /// failure, which a memory fake cannot exercise.
    private static func setDefaultsDirectoryWritable(_ writable: Bool, for account: Account) throws {
        let directory = account.userDataStorage
            .appendingPathComponent("defaults", isDirectory: true)
        try FileManager.default.setAttributes([.posixPermissions: writable ? 0o700 : 0o500],
                                              ofItemAtPath: directory.path)
    }

    private func setWritable(_ writable: Bool, for account: Account) throws {
        try Self.setDefaultsDirectoryWritable(writable, for: account)
    }

    /// An already-paired device with complete Space and bidirectional profile mappings. Matches the private
    /// PhiSyncEngineOwnedItemsTests.makeSpaceAccess fixture.
    private func makeSpaceAccess(_ mappings: [String: String] = ["s-1": "su-1"])
        -> FakePhiSpaceAccess {
        let access = FakePhiSpaceAccess()
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

    private func settingsPage(value: String, version: Int64, marker: String)
        -> FakePhiSyncClient.Page {
        page([remoteSettingsEntity(key: "theme.dark", value: value, version: version, key: key)],
             marker: marker)
    }

    // MARK: - CASE B2-4d (store coverage)

    /// CASE B2-4d: setSyncUuid failure propagates as persistFailed through SpaceSyncMappingManager. Mint,
    /// claim and lazy mint each use a separate store; each must throw and roll back both lookup directions.
    /// This guards §2.5(2): swallowing failure exposes an unpersisted UUID to pushSpaces; restarting loses it
    /// and mints another, duplicating one local Space in the account with no UI to undo the mapping. Task 2b
    /// exercises applySpaces/mapSpace catching the error, cursor_save_failed, unchanged marker and
    /// deduplicated replay using FakePhiSpaceAccess.errorOnNextMapping.
    func testEveryMappingEntryThrowsPersistFailedAndLeavesNoTrace() throws {
        // (a) Mint.
        let mintStore = MemorySpaceMappingStore()
        mintStore.failNextSet = true
        let mintKeys = SpaceSyncMappingManager(store: mintStore)
        XCTAssertThrowsError(try mintKeys.mintSyncUuid(forSpaceId: localId)) { error in
            XCTAssertEqual(error as? SpaceSyncMappingError, .persistFailed)
        }
        XCTAssertEqual(mintStore.map, [:], "Throwing leaves no trace")
        XCTAssertNil(mintKeys.syncUuid(forSpaceId: localId))
        XCTAssertEqual(mintStore.setCalls, 1, "One attempt, without internal retry")

        // (b) Claim.
        let mapStore = MemorySpaceMappingStore()
        mapStore.failNextSet = true
        let mapKeys = SpaceSyncMappingManager(store: mapStore)
        XCTAssertThrowsError(try mapKeys.map(spaceId: localId, toSyncUuid: "sync-x")) { error in
            XCTAssertEqual(error as? SpaceSyncMappingError, .persistFailed)
        }
        XCTAssertEqual(mapStore.map, [:])
        XCTAssertNil(mapKeys.syncUuid(forSpaceId: localId))
        XCTAssertNil(mapKeys.localSpaceId(forSyncUuid: "sync-x"), "Reverse lookup is unresolved too")
        XCTAssertEqual(mapStore.setCalls, 1)

        // (c) Lazy mint; unchanged ensureMapped inherits the mintSyncUuid error.
        let ensureStore = MemorySpaceMappingStore()
        ensureStore.failNextSet = true
        let ensureKeys = SpaceSyncMappingManager(store: ensureStore)
        XCTAssertThrowsError(try ensureKeys.ensureMapped(spaceId: localId)) { error in
            XCTAssertEqual(error as? SpaceSyncMappingError, .persistFailed)
        }
        XCTAssertEqual(ensureStore.map, [:])
        XCTAssertNil(ensureKeys.syncUuid(forSpaceId: localId))
        XCTAssertEqual(ensureStore.setCalls, 1)

        // Allow writes and retry: all three operations succeed.
        mintStore.failNextSet = false
        mapStore.failNextSet = false
        ensureStore.failNextSet = false
        _ = try mintKeys.mintSyncUuid(forSpaceId: localId)
        try mapKeys.map(spaceId: localId, toSyncUuid: "sync-x")
        _ = try ensureKeys.ensureMapped(spaceId: localId)
        XCTAssertEqual(mintStore.map.count, 1)
        XCTAssertEqual(mapStore.map, [localId: "sync-x"])
        XCTAssertEqual(ensureStore.map.count, 1)
    }

    // MARK: - CASE B2-10 (store coverage)

    /// CASE B2-10: a failed save must not set …HadRecords (§2.5(7)). The flag means a cursor with entityId has
    /// actually been persisted. Consuming this loss-detection predicate prematurely can prevent the full-kind
    /// replay needed to realign the bookmark tree.
    /// Assert only a lower bound for saveCalls: writeOwnedTable runs during landing and publishing, and an
    /// exact total would couple this store case to engine structure. B2-4d's setCalls == 1 and
    /// FileOwnedItemStateStore CASE 2a.7 cover no internal retry; Task 2b checks exact engine write counts.
    func testAFailedCursorSaveDoesNotArmTheHadRecordsFlag() async throws {
        let spaceAccess = makeSpaceAccess()
        let spaceStore = MemorySpaceStore()
        spaceStore.table.hasDrainedFullReplay = true
        let access = FakeBookmarkAccess()
        let ownedStore = MemoryOwnedItemStore()
        ownedStore.failNextSave = true
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([
            remoteEntity(envelope(bookmarkPayload(uuid: "b1")),
                         tag: PhiSyncEntity.bookmarkClientTag("b1"),
                         version: 7, entityId: "e1", key: key),
        ], marker: "m1")]

        let engine = PhiSyncEngine(domainKeys: StubDomainKeys(key: key), client: client,
                                   defaults: defaults, deviceKeyId: "devA", pairingComplete: true, settings: [],
                                   spaceAccess: spaceAccess, spaceStore: spaceStore,
                                   ownedKinds: [.bookmarks(access: access, store: ownedStore)],
                                   now: { 1_700_000_000_000 })
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertFalse(spaceStore.table.bookmarksHadRecords,
                       "An unpersisted write must not consume per-kind loss detection")
        XCTAssertGreaterThanOrEqual(ownedStore.saveCalls, 1, "The persistence entry point was called")
        XCTAssertTrue(ownedStore.table.cursors.isEmpty, "The failed save persisted no cursors")
        XCTAssertEqual(access.rows.count, 1, "Landing precedes cursor persistence: the local bookmark row already exists")

        // Allow writes and replay the same page; only the successful save may set the flag.
        ownedStore.failNextSave = false
        client.scriptedPages = [page([
            remoteEntity(envelope(bookmarkPayload(uuid: "b1")),
                         tag: PhiSyncEntity.bookmarkClientTag("b1"),
                         version: 8, entityId: "e1", key: key),
        ], marker: "m2")]
        await engine.pullOnce()

        XCTAssertTrue(spaceStore.table.bookmarksHadRecords,
                      "Only a successful write sets the flag")
    }

    // MARK: - CASE B2-18 (store coverage)

    /// CASE B2-18: an in-process cache must not bypass a failed plist write. Exercise AccountUserDefaults
    /// rollback rather than MemorySpaceStore. With spaceSectionEnabled false, recordsGatedMarkerMoves is true
    /// and each page advancement writes the Space table.
    /// Without rollback, loadSpaceTable reads the cached true flag and mutateSpaceTable exits at table ==
    /// before without saving. Disk then has an advanced marker without the flag; a previously drained device
    /// will never replay pages skipped while gated. Task 2b verifies cursor_save_failed and no first-round
    /// advancement, then exactly two save attempts and markerMoveRecorded only after successful persistence.
    func testAFailedPlistWriteIsNotBypassedByTheInProcessCache() async throws {
        let account = makeAccount()
        let store = AccountPhiSpaceSyncStateStore(defaults: account.userDefaults)
        let client = FakePhiSyncClient()
        client.scriptedPages = [settingsPage(value: "on", version: 10, marker: "m1")]
        let engine = PhiSyncEngine(domainKeys: StubDomainKeys(key: key), client: client,
                                   defaults: defaults, deviceKeyId: "devA", pairingComplete: true, settings: [],
                                   spaceAccess: makeSpaceAccess(), spaceStore: store,
                                   now: { 1_700_000_000_000 })

        try setWritable(false, for: account)
        await engine.pullOnce()
        XCTAssertFalse(store.load().markerMovedWhileGateShut,
                       "Rollback keeps memory consistent with disk after failure")

        try setWritable(true, for: account)
        client.scriptedPages = [settingsPage(value: "off", version: 11, marker: "m2")]
        await engine.pullOnce()

        XCTAssertTrue(store.load().markerMovedWhileGateShut, "Round two makes another actual write")
        XCTAssertTrue(
            AccountPhiSpaceSyncStateStore(defaults: AccountUserDefaults(account: account))
                .load().markerMovedWhileGateShut,
            "A new instance for the same account reads the persisted value")
    }

    /// B2-18 variant (a): permissions remain 0o500 in round two. Both memory and disk stay false, with one
    /// attempt per round and no internal retry.
    func testTwoRoundsAgainstAReadOnlyDirectoryBothLeaveTheFlagFalse() async throws {
        let account = makeAccount()
        let store = AccountPhiSpaceSyncStateStore(defaults: account.userDefaults)
        let client = FakePhiSyncClient()
        client.scriptedPages = [settingsPage(value: "on", version: 10, marker: "m1")]
        let engine = PhiSyncEngine(domainKeys: StubDomainKeys(key: key), client: client,
                                   defaults: defaults, deviceKeyId: "devA", pairingComplete: true, settings: [],
                                   spaceAccess: makeSpaceAccess(), spaceStore: store,
                                   now: { 1_700_000_000_000 })

        try setWritable(false, for: account)
        await engine.pullOnce()
        XCTAssertFalse(store.load().markerMovedWhileGateShut)

        client.scriptedPages = [settingsPage(value: "off", version: 11, marker: "m2")]
        await engine.pullOnce()
        XCTAssertFalse(store.load().markerMovedWhileGateShut, "Both rounds fail; memory retains the old table")

        try setWritable(true, for: account)
        XCTAssertFalse(
            AccountPhiSpaceSyncStateStore(defaults: AccountUserDefaults(account: account))
                .load().markerMovedWhileGateShut,
            "Disk is also false; memory and disk never diverged")
    }

    // MARK: - CASE B2-11a…d (one-time marker.json migration, §2.10 / R-M3-4a-18)

    /// CASE B2-11a: both legacy keys exist and the file is absent. Migrate, clear the keys, then do nothing on
    /// a second call. Without migration an M3-1 upgrade replays the whole type; retaining keys creates
    /// divergent cursor stores and breaks R-M3-4a-18's atomic import requirement.
    func testMigrationMovesBothLegacyKeysIntoTheFileExactlyOnce() throws {
        let store = try makeFileMarkerStore()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        defaults.set(Data("M9".utf8), forKey: PhiSyncEngine.markerStateKey)
        defaults.set("B", forKey: PhiSyncEngine.storeBirthdayStateKey)

        let first = PhiSyncMarkerMigration.migrateLegacyMarker(from: defaults, into: store)
        let second = PhiSyncMarkerMigration.migrateLegacyMarker(from: defaults, into: store)

        XCTAssertTrue(first, "The first call performs migration")
        XCTAssertFalse(second, "Both keys are absent on the second call, so it does nothing")
        let expected = PhiSyncMarkerFile(formatVersion: 1, marker: Data("M9".utf8), storeBirthday: "B")
        XCTAssertEqual(store.load(), expected)
        XCTAssertNil(defaults.data(forKey: PhiSyncEngine.markerStateKey), "The key is cleared")
        XCTAssertNil(defaults.string(forKey: PhiSyncEngine.storeBirthdayStateKey), "The key is cleared")
        let bytes = try Data(contentsOf: store.fileURL)
        XCTAssertEqual(try JSONDecoder().decode(PhiSyncMarkerFile.self, from: bytes), expected,
                       "On-disk bytes decode to the same value")
    }

    /// CASE B2-11b: an existing file wins; ignore the keys without clearing them or writing. Overwriting from
    /// stale keys could replay old pages or permanently skip intervening pages. After import it would also
    /// restore a cursor ahead of the rolled-back database, violating R-M3-4a-18.
    func testMigrationIgnoresTheLegacyKeysWhenTheFileAlreadyHasContent() {
        let onDisk = PhiSyncMarkerFile(marker: Data("M-file".utf8), storeBirthday: "B-file")
        let store = MemoryMarkerStore(file: onDisk)
        defaults.set(Data("M-old".utf8), forKey: PhiSyncEngine.markerStateKey)
        defaults.set("B-old", forKey: PhiSyncEngine.storeBirthdayStateKey)

        let migrated = PhiSyncMarkerMigration.migrateLegacyMarker(from: defaults, into: store)

        XCTAssertFalse(migrated)
        XCTAssertTrue(store.saves.isEmpty, "No writes occurred")
        XCTAssertEqual(store.file, onDisk, "The file is unchanged byte for byte")
        XCTAssertEqual(defaults.data(forKey: PhiSyncEngine.markerStateKey), Data("M-old".utf8),
                       "The key remains; §12.2 reset and account-switch erasure own cleanup")
        XCTAssertEqual(defaults.string(forKey: PhiSyncEngine.storeBirthdayStateKey), "B-old")
    }

    /// CASE B2-11c: failed persistence returns false and retains keys so migration can succeed at next
    /// startup. Clearing first loses both marker and birthday on failure. An empty birthday on subsequent
    /// getUpdates has no error signal here and can cause repeated full-type replay.
    func testAFailedMigrationWriteKeepsTheLegacyKeysForTheNextLaunch() {
        let store = MemoryMarkerStore()
        store.failSave = true
        defaults.set(Data("M9".utf8), forKey: PhiSyncEngine.markerStateKey)
        defaults.set("B", forKey: PhiSyncEngine.storeBirthdayStateKey)

        XCTAssertFalse(PhiSyncMarkerMigration.migrateLegacyMarker(from: defaults, into: store))
        XCTAssertEqual(defaults.data(forKey: PhiSyncEngine.markerStateKey), Data("M9".utf8),
                       "Failed persistence retains the keys")
        XCTAssertEqual(defaults.string(forKey: PhiSyncEngine.storeBirthdayStateKey), "B")
        XCTAssertEqual(store.file, PhiSyncMarkerFile(), "The memory fake leaves file unchanged on failure")

        store.failSave = false
        XCTAssertTrue(PhiSyncMarkerMigration.migrateLegacyMarker(from: defaults, into: store),
                      "Retry at next startup completes migration")
        XCTAssertEqual(store.file, PhiSyncMarkerFile(marker: Data("M9".utf8), storeBirthday: "B"))
        XCTAssertNil(defaults.object(forKey: PhiSyncEngine.markerStateKey))
        XCTAssertNil(defaults.object(forKey: PhiSyncEngine.storeBirthdayStateKey))
    }

    /// CASE B2-11d: missing or undecodable files load as an empty table without writing any bytes. A nil
    /// marker arms full-type replay (§10). Writing an empty replacement would disguise real cursor loss as a
    /// valid empty table and prevent loss detection.
    func testAMissingOrUndecodableFileReadsAsNoMarkerAndIsNotWrittenBack() async throws {
        // (i) Missing file.
        try await assertReplayIsArmed(prepare: { _ in })
        // (ii) Undecodable file bytes.
        try await assertReplayIsArmed(prepare: { store in
            try Data([0xDE, 0xAD]).write(to: store.fileURL)
        }, undecodableBytes: Data([0xDE, 0xAD]))
    }

    private func assertReplayIsArmed(prepare: (FilePhiSyncMarkerStore) throws -> Void,
                                     undecodableBytes: Data? = nil,
                                     file: StaticString = #filePath,
                                     line: UInt = #line) async throws {
        let store = try makeFileMarkerStore()
        try prepare(store)
        XCTAssertNil(defaults.object(forKey: PhiSyncEngine.markerStateKey), file: file, line: line)
        XCTAssertNil(defaults.object(forKey: PhiSyncEngine.storeBirthdayStateKey), file: file, line: line)
        let client = FakePhiSyncClient()
        client.scriptedPages = [settingsPage(value: "on", version: 10, marker: "m1")]
        let engine = makeEngine(client: client, markerStore: store)

        XCTAssertEqual(store.load(), PhiSyncMarkerFile(), "Unreadable data loads as an empty table", file: file, line: line)
        if let undecodableBytes {
            XCTAssertEqual(try Data(contentsOf: store.fileURL), undecodableBytes,
                           "No bytes are written back", file: file, line: line)
        } else {
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path),
                           "No bytes are written back", file: file, line: line)
        }

        await engine.pullOnce()

        XCTAssertEqual(client.getUpdatesCalls.count, 1, file: file, line: line)
        XCTAssertNil(client.getUpdatesCalls.first?.marker, "Replay from scratch", file: file, line: line)
        XCTAssertEqual(client.getUpdatesCalls.first?.storeBirthday, "", file: file, line: line)
        let after = store.load()
        XCTAssertNotNil(after.marker, "The round-end marker persists in the file", file: file, line: line)
        XCTAssertEqual(after.storeBirthday, "birthday-1", file: file, line: line)
    }

    // MARK: - CASE 3.1 (three-field round trip)

    /// CASE 3.1: formatVersion, marker and storeBirthday round-trip; deleteFile removes the file and load
    /// returns an empty table. Birthday must persist per page (§2.4 note 1), or requests can loop through
    /// NOT_MY_BIRTHDAY → resetForNewStoreBirthday → pull with another stale birthday.
    func testTheFileRoundTripsAllThreeFields() throws {
        let store = try makeFileMarkerStore()
        let a = PhiSyncMarkerFile(marker: Data([0x00, 0x01, 0xFF]), storeBirthday: "srv-birthday-1")
        let b = PhiSyncMarkerFile()

        XCTAssertTrue(store.save(a))
        let loadedA = store.load()
        XCTAssertEqual(loadedA, a)
        XCTAssertEqual(loadedA.formatVersion, 1)

        XCTAssertTrue(store.save(b))
        XCTAssertEqual(store.load(), b, "An empty table is a real write: marker == nil persists on disk")

        store.deleteFile()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        XCTAssertEqual(store.load(), PhiSyncMarkerFile())
    }

    /// CASE 3.1 also distinguishes absent marker (nil, replay) from zero-length marker (Data(), advance). The
    /// store needs Data? for that distinction; the engine separately normalizes an empty marker to nil.
    func testAZeroLengthMarkerIsNotTheSameAsNoMarkerOnDisk() throws {
        let store = try makeFileMarkerStore()
        XCTAssertTrue(store.save(PhiSyncMarkerFile(marker: Data(), storeBirthday: "b")))
        let loaded = store.load()
        XCTAssertNotNil(loaded.marker)
        XCTAssertEqual(loaded.marker, Data())
        XCTAssertTrue(store.save(PhiSyncMarkerFile(marker: nil, storeBirthday: "b")))
        XCTAssertNil(store.load().marker)
    }

    // MARK: - CASE 3.3 (resetForNewStoreBirthday clears marker; birthday persists per page in the same file)

    /// CASE 3.3: NOT_MY_BIRTHDAY makes the second request use an empty birthday and no marker. Both persist in
    /// the file by round end, with neither legacy key written to UserDefaults. Keeping birthday in defaults
    /// would split import rollback state. clearRemoteCursor must persist storedMarker = nil so restarting
    /// cannot resurrect an old marker against a new store (§2.4 note 1).
    func testANewStoreBirthdayClearsTheMarkerAndBothFieldsLandInTheSameFile() async throws {
        let markerStore = MemoryMarkerStore(
            file: PhiSyncMarkerFile(marker: Data("4".utf8), storeBirthday: "stale-birthday"))
        let client = FakePhiSyncClient()
        client.getUpdatesErrorOnce = PhiSyncProtocolError.notMyBirthday
        client.storeBirthday = "birthday-1"
        client.scriptedPages = [settingsPage(value: "on", version: 10, marker: "m1")]
        let engine = makeEngine(client: client, markerStore: markerStore)

        await engine.pullOnce()

        XCTAssertEqual(client.getUpdatesCalls.count, 2)
        XCTAssertEqual(client.getUpdatesCalls[0].storeBirthday, "stale-birthday", "Reads the injected file")
        XCTAssertEqual(client.getUpdatesCalls[0].marker, Data("4".utf8))
        XCTAssertEqual(client.getUpdatesCalls[1].storeBirthday, "")
        XCTAssertNil(client.getUpdatesCalls[1].marker)
        XCTAssertEqual(markerStore.file.storeBirthday, "birthday-1")
        XCTAssertNotNil(markerStore.file.marker)
        XCTAssertTrue(markerStore.saves.contains(PhiSyncMarkerFile()),
                      "marker == nil must actually persist to the file")
        XCTAssertNil(defaults.object(forKey: PhiSyncEngine.markerStateKey),
                     "An injected store prevents all defaults writes")
        XCTAssertNil(defaults.object(forKey: PhiSyncEngine.storeBirthdayStateKey))
    }

    // MARK: - CASE 3.4 (stateKeys contraction)

    /// CASE 3.4: stateKeys has exactly five entries and excludes both marker keys; legacyMarkerStateKeys
    /// remains. This specifically detects the forbidden R-M3-4a-18 shape where importing replaces the account
    /// directory but leaves a non-rollback cursor in UserDefaults, even if file-based engine tests otherwise
    /// pass.
    func testStateKeysShrankAndTheLegacyKeysStillExist() {
        let expected: Set<String> = [
            PhiSyncEngine.entityIdStateKey, PhiSyncEngine.versionStateKey,
            PhiSyncEngine.lastEntityStateKey, PhiSyncEngine.tombstoneRoundsStateKey,
            PhiSyncEngine.hasAdoptedStateKey,
        ]
        XCTAssertEqual(Set(PhiSyncEngine.stateKeys), expected)
        XCTAssertEqual(PhiSyncEngine.stateKeys.count, 5, "Exactly five entries without duplicates")
        XCTAssertFalse(PhiSyncEngine.stateKeys.contains(PhiSyncEngine.markerStateKey))
        XCTAssertFalse(PhiSyncEngine.stateKeys.contains(PhiSyncEngine.storeBirthdayStateKey))
        XCTAssertEqual(PhiSyncEngine.legacyMarkerStateKeys,
                       [PhiSyncEngine.storeBirthdayStateKey, PhiSyncEngine.markerStateKey])
        XCTAssertTrue(Set(PhiSyncEngine.stateKeys).isDisjoint(with: PhiSyncEngine.legacyMarkerStateKeys))
    }

    // MARK: - CASE 3.5 (retired engines cannot write markers; account switching clears migration residue)

    /// CASE 3.5A: shutdown while getUpdates is suspended must prevent any later marker writes. After stateKeys
    /// contracts, existing state-key assertions no longer cover the file. A retired engine retains the old
    /// account's store; waking after self-revoke step 4 deletes marker.json must not recreate it and defeat
    /// CASE 3.2.
    func testARetiredEngineNeverWritesTheMarker() async throws {
        let entry = PhiSyncMarkerFile(marker: Data("m0".utf8), storeBirthday: "B")
        let markerStore = MemoryMarkerStore(file: entry)
        let client = FakePhiSyncClient()
        // Provide an actual page to write so the zero-write assertion is meaningful.
        client.scriptedPages = [settingsPage(value: "on", version: 10, marker: "m1")]
        let arrived = Gate()
        let release = Gate()
        client.arrivedInGetUpdates = arrived
        client.getUpdatesGate = release
        let engine = makeEngine(client: client, markerStore: markerStore)

        let parked = Task { await engine.pullOnce() }
        await arrived.wait()                     // This round is suspended in getUpdates
        engine.shutdown()                        // Synchronous, matching stopPhiSync()
        await release.open()
        await parked.value

        XCTAssertTrue(markerStore.saves.isEmpty, "No saves after retirement")
        XCTAssertEqual(markerStore.file, entry, "Unchanged from the entry state")
    }

    /// CASE 3.5B: account-switch erasure includes both legacy keys, and hadCursor recognizes them. Failed
    /// migration retains keys (§2.10); leaving Alice's token behind would migrate it into Bob's marker.json
    /// and permanently skip account history because server markers are account-specific opaque tokens.
    func testAnAccountSwitchAlsoWipesTheMigrationLeftovers() {
        for key in PhiSyncEngine.stateKeys { defaults.set("x", forKey: key) }
        defaults.set(Data("M-alice".utf8), forKey: PhiSyncEngine.markerStateKey)
        defaults.set("B-alice", forKey: PhiSyncEngine.storeBirthdayStateKey)
        defaults.set("auth0|alice", forKey: PhiChromiumCoordinator.phiSyncCursorOwnerKey)

        let dropped = PhiChromiumCoordinator.resetPhiSyncCursorIfAccountChanged(
            accountId: "auth0|bob", defaults: defaults)

        XCTAssertTrue(dropped)
        for key in PhiSyncEngine.stateKeys {
            XCTAssertNil(defaults.object(forKey: key), "\(key) survived the account switch")
        }
        XCTAssertNil(defaults.object(forKey: PhiSyncEngine.markerStateKey), "Legacy keys are erased too")
        XCTAssertNil(defaults.object(forKey: PhiSyncEngine.storeBirthdayStateKey), "Legacy keys are erased too")
        XCTAssertEqual(defaults.string(forKey: PhiChromiumCoordinator.phiSyncCursorOwnerKey),
                       "auth0|bob")

        // hadCursor includes legacy keys even when migration residue is the only cursor state.
        defaults.set(Data("M-bob".utf8), forKey: PhiSyncEngine.markerStateKey)
        XCTAssertTrue(PhiChromiumCoordinator.resetPhiSyncCursorIfAccountChanged(
            accountId: "auth0|carol", defaults: defaults))
        XCTAssertNil(defaults.object(forKey: PhiSyncEngine.markerStateKey))
    }
    // MARK: - Task 2b: fixtures and helpers

    /// Use the client's birthday-1 in the marker file. Per-page birthday persistence becomes an updated ==
    /// markerState no-op, so MemoryMarkerStore.saves and failSaveOnCallNumber count only marker writes.
    private func markerStore(marker: String?) -> MemoryMarkerStore {
        MemoryMarkerStore(file: PhiSyncMarkerFile(marker: marker.map { Data($0.utf8) },
                                                  storeBirthday: "birthday-1"))
    }

    /// hasDrainedFullReplay true means this device has fully replayed the type, satisfying publication guard
    /// ①.
    private func drainedSpaceStore() -> MemorySpaceStore {
        let store = MemorySpaceStore()
        store.table.hasDrainedFullReplay = true
        return store
    }

    private func bookmarkTag(_ uuid: String) -> String { PhiSyncEntity.bookmarkClientTag(uuid) }

    private func bookmarkHash(_ uuid: String) -> String {
        PhiSyncEntity.clientTagHash(for: bookmarkTag(uuid))
    }

    private func pinTag(_ lineage: String, owner: String = "pu-1") -> String {
        PhiSyncEntity.pinClientTag(lineage, ownerKey: owner)
    }

    private func bookmarkEntity(_ uuid: String, version: Int64, entityId: String? = nil,
                                spaceUuid: String = "su-1", title: String = "T") -> PhiRemoteEntity {
        remoteEntity(envelope(bookmarkPayload(uuid: uuid, spaceUuid: spaceUuid, title: title)),
                     tag: bookmarkTag(uuid), version: version,
                     entityId: entityId ?? "srv-\(uuid)", key: key)
    }

    private func pinEntity(_ lineage: String, version: Int64, entityId: String? = nil,
                           title: String = "T") -> PhiRemoteEntity {
        remoteEntity(envelope(pinPayload(lineage: lineage, title: title)),
                     tag: pinTag(lineage), version: version,
                     entityId: entityId ?? "srv-\(lineage)", key: key)
    }

    /// A landable Space create, bound to makeSpaceAccess's pu-1 profile_uuid.
    private func spaceCreateEntity(_ uuid: String, version: Int64,
                                   entityId: String? = nil) -> PhiRemoteEntity {
        var payload = spacePayload(uuid: uuid)
        payload.profileUuid = stamped("pu-1", at: 100)
        return remoteEntity(envelope(payload), tag: PhiSyncEntity.spaceClientTag(uuid),
                            version: version, entityId: entityId ?? "srv-\(uuid)", key: key)
    }

    private func boolSettingsEntity(key settingKey: String, _ flag: Bool, at ms: Int64,
                                    version: Int64, entityId: String = "srv-settings")
        -> PhiRemoteEntity {
        var setting = Phi_PhiSettingEntity()
        setting.values[settingKey] = stamped(flag, at: ms)
        var wrapper = Phi_PhiEntity()
        wrapper.setting = setting
        return remoteEntity(wrapper, tag: PhiSyncEntity.clientTag, version: version,
                            entityId: entityId, key: key)
    }

    /// Single-bool registry matching the private PhiSyncEngineTests.registry helper.
    private func boolRegistry(_ settingKey: String) -> [SyncableSetting] {
        [SyncableSetting(
            key: settingKey,
            read: { defaults in
                var value = Phi_PhiSettingValue()
                value.boolValue = defaults.bool(forKey: settingKey)
                return value
            },
            write: { value, defaults in
                if case .boolValue(let flag)? = value.v { defaults.set(flag, forKey: settingKey) }
            })]
    }

    private func settingsCommits(_ client: FakePhiSyncClient) -> [FakePhiSyncClient.CommitCall] {
        client.commits.filter { $0.clientTagHash == PhiSyncEntity.settingsClientTagHash }
    }

    /// Pending local bookmark edit: its title differs from cursor.reconciled, producing an update. Seed
    /// client.stored with matching entityId/version 1 or the fake update throws INVALID_MESSAGE. pagesByMarker
    /// ignores stored; in stored mode, entry marker 1 prevents this row from replaying.
    private func seedPendingLocalBookmarkEdit(access: FakeBookmarkAccess,
                                              store: MemoryOwnedItemStore,
                                              client: FakePhiSyncClient) {
        let baseline = bookmarkPayload(uuid: "bl", title: "Old")
        access.rows.append(.fixture(guid: "gl", syncId: "bl", spaceId: "s-1", title: "Local edit"))
        store.table.cursors["bl"] = ownedCursor(reconciled: baselineBytes(baseline),
                                                server: baselineBytes(baseline),
                                                entityId: "srv-bl", version: 1, ownerUuid: "su-1")
        client.seed(tagHash: bookmarkHash("bl"),
                    ciphertext: (try? PhiEntityCodec.encrypt(envelope(baseline), key: key)) ?? Data(),
                    version: 1, entityId: "srv-bl")
    }

    private func createCount(_ ops: [BookmarkApplyOp]) -> Int {
        ops.filter { if case .create = $0 { return true } else { return false } }.count
    }

    private func pinCreateCount(_ ops: [PinApplyOp]) -> Int {
        ops.filter { if case .create = $0 { return true } else { return false } }.count
    }

    // MARK: - Task 6: URL Rule helpers

    private func ruleTag(_ uuid: String) -> String { PhiSyncEntity.urlRuleClientTag(uuid) }

    /// Landable rule targeting su-1, mapped to makeSpaceAccess's s-1. Another targetSpaceUuid represents an
    /// owner Space not yet created; B2-16 uses this to put the Space and its rule on one page.
    private func urlRuleEntity(_ uuid: String, version: Int64, entityId: String? = nil,
                               targetSpaceUuid: String = "su-1",
                               host: String = "github.com") -> PhiRemoteEntity {
        remoteEntity(envelope(urlRulePayload(uuid: uuid, targetSpaceUuid: targetSpaceUuid,
                                             host: host)),
                     tag: ruleTag(uuid), version: version,
                     entityId: entityId ?? "srv-\(uuid)", key: key)
    }

    private func ruleCreateCount(_ ops: [URLRuleSyncOp]) -> Int {
        ops.filter { if case .create = $0 { return true } else { return false } }.count
    }

    private func ruleCommits(_ client: FakePhiSyncClient) -> [FakePhiSyncClient.CommitCall] {
        client.commits.filter { $0.name == PhiSyncEntity.urlRuleEntityName }
    }

    private func ruleApplyCalls(_ access: FakeURLRuleAccess) -> Int {
        access.calls.filter { if case .apply = $0 { return true } else { return false } }.count
    }

    private func applyCalls(_ access: FakeBookmarkAccess) -> Int {
        access.calls.filter { if case .apply = $0 { return true } else { return false } }.count
    }

    /// Matches PhiSyncEngineOwnedItemsTests.makeEngine with markerStore injection. spaceAccess is optional
    /// because a nonoptional @MainActor fake cannot be constructed in a nonisolated default-argument context.
    private func makeOwnedEngine(client: FakePhiSyncClient,
                                 markerStore: any PhiSyncMarkerStore,
                                 spaceStore: MemorySpaceStore,
                                 spaceAccess: FakePhiSpaceAccess? = nil,
                                 settings: [SyncableSetting] = [],
                                 ownedKinds: [OwnedKindRegistration] = []) -> PhiSyncEngine {
        PhiSyncEngine(domainKeys: StubDomainKeys(key: key), client: client,
                      defaults: defaults, deviceKeyId: "devA", pairingComplete: true, settings: settings,
                      spaceAccess: spaceAccess ?? makeSpaceAccess(), spaceStore: spaceStore,
                      markerStore: markerStore, ownedKinds: ownedKinds,
                      now: { 1_700_000_000_000 })
    }

    /// M3-1 settings-only engine with nil spaceStore and spaceAccess.
    private func makeSettingsOnlyEngine(client: FakePhiSyncClient,
                                        markerStore: any PhiSyncMarkerStore,
                                        settings: [SyncableSetting]) -> PhiSyncEngine {
        PhiSyncEngine(domainKeys: StubDomainKeys(key: key), client: client,
                      defaults: defaults, deviceKeyId: "devA", pairingComplete: true, settings: settings,
                      markerStore: markerStore, now: { 1_700_000_000_000 })
    }

    // MARK: - CASE B2-1 (bookmark cursor save failure prevents marker advancement)

    /// CASE B2-1: failed bookmark cursor persistence keeps the page marker unchanged and yields
    /// cursor_save_failed. Allowing writes replays M0 through update without adding rows. Advancing after
    /// landing but before cursor persistence would skip replay forever and make the next diff resend against
    /// the pre-landing baseline.
    func testABookmarkCursorSaveFailureHoldsTheMarkerAndTheReplayIsIdempotent() async throws {
        let access = FakeBookmarkAccess()
        let ownedStore = MemoryOwnedItemStore()
        ownedStore.failNextSave = true
        let markerStore = markerStore(marker: "0")
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([bookmarkEntity("b1", version: 7, entityId: "e1")], marker: "7")]
        let engine = makeOwnedEngine(client: client, markerStore: markerStore,
                                     spaceStore: drainedSpaceStore(),
                                     ownedKinds: [.bookmarks(access: access, store: ownedStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertEqual(markerStore.file.marker, Data("0".utf8), "M0 is unchanged")
        let outcome = await engine.lastRoundOutcomeForTesting
        let advanced = await engine.lastRoundMarkerAdvancedForTesting
        let failures = await engine.lastRoundCursorSaveFailedCountForTesting
        let pages = await engine.lastRoundPagesForTesting
        let counters = await engine.lastOwnedRoundCountersForTesting["bookmarks"]
        XCTAssertEqual(outcome, .cursorSaveFailed)
        XCTAssertFalse(advanced)
        XCTAssertEqual(failures, 1)
        XCTAssertEqual(pages, 1)
        XCTAssertEqual(access.rows.count, 1, "The row exists: landing precedes cursor persistence")
        XCTAssertEqual(counters?.applied, 1)

        ownedStore.failNextSave = false
        let applyCallsBefore = applyCalls(access)
        await engine.pullOnce()

        XCTAssertEqual(client.getUpdatesCalls.last?.marker, Data("0".utf8), "The fake replays the same page from M0")
        if applyCalls(access) > applyCallsBefore {
            XCTAssertEqual(createCount(access.lastAppliedOps), 0, "Replay takes the update branch")
        }
        XCTAssertEqual(access.rows.count, 1)
        XCTAssertEqual(access.rows.filter { $0.syncId == "b1" }.count, 1, "One row per identity")
        XCTAssertEqual(markerStore.file.marker, Data("7".utf8))
        let second = await engine.lastRoundOutcomeForTesting
        XCTAssertEqual(second, .ok)
    }

    /// CASE B2-1b: the failed round publishes no bookmark tags and never reaches the publication-side
    /// loadOwnedTable (hadRecordsSeen.count == 1). Publishing against the pre-landing baseline recreates the
    /// commit storm fixed in c549c4c5 (R-M3-4a-16's three consequences).
    func testAFailedCursorSaveRoundPublishesNothing() async throws {
        let access = FakeBookmarkAccess()
        let ownedStore = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        seedPendingLocalBookmarkEdit(access: access, store: ownedStore, client: client)
        ownedStore.failNextSave = true
        let markerStore = markerStore(marker: "0")
        client.pagesByMarker = [page([bookmarkEntity("b1", version: 7, entityId: "e1")], marker: "7")]
        let engine = makeOwnedEngine(client: client, markerStore: markerStore,
                                     spaceStore: drainedSpaceStore(),
                                     ownedKinds: [.bookmarks(access: access, store: ownedStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let counters = await engine.lastOwnedRoundCountersForTesting["bookmarks"]
        XCTAssertTrue(bookmarkCommits(client).isEmpty, "The failed round publishes nothing")
        XCTAssertEqual(counters?.pushed, 0)
        XCTAssertEqual(counters?.tombstones, 0)
        XCTAssertEqual(ownedStore.saveCalls, 1, "Only the landing write occurred; publication was skipped")
        XCTAssertEqual(ownedStore.hadRecordsSeen.count, 1, "Publication never calls loadOwnedTable")
    }

    // MARK: - CASE B2-1c (publication requires canPublishThisRound ∧ cursorSaveFailures == 0)

    /// CASE B2-1c (a): settings-only engine with nil spaceStore returns .ok, not .gated, and publishes
    /// settings.
    func testASettingsOnlyEngineReportsOkAndPublishes() async throws {
        let settingKey = "phi.test.b21c.local"
        defaults.set(true, forKey: settingKey)              // Pending local edit
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([boolSettingsEntity(key: "phi.test.b21c.remote", false,
                                                          at: 100, version: 10)], marker: "10")]
        client.seed(ciphertext: Data(), version: 10, entityId: "srv-settings")
        let engine = makeSettingsOnlyEngine(client: client, markerStore: markerStore(marker: "0"),
                                            settings: boolRegistry(settingKey))
        await engine.pullOnce()

        let outcome = await engine.lastRoundOutcomeForTesting
        let failures = await engine.lastRoundCursorSaveFailedCountForTesting
        XCTAssertEqual(outcome, .ok, "spaceStore == nil is not gated (RR-B10)")
        XCTAssertEqual(failures, 0)
        XCTAssertEqual(settingsCommits(client).count, 1, "Exactly one settings tag")
    }

    /// CASE B2-1c (b): a closed gate with nonnil spaceStore returns .gated while publishing settings.
    func testAGatedRoundReportsGatedAndStillPublishesSettings() async throws {
        let settingKey = "phi.test.b21c.local"
        defaults.set(true, forKey: settingKey)
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([boolSettingsEntity(key: "phi.test.b21c.remote", false,
                                                          at: 100, version: 10)], marker: "10")]
        client.seed(ciphertext: Data(), version: 10, entityId: "srv-settings")
        let engine = makeOwnedEngine(client: client, markerStore: markerStore(marker: "0"),
                                     spaceStore: MemorySpaceStore(),
                                     settings: boolRegistry(settingKey))
        // Keep the gate closed; do not call setSpaceSyncEnabled(true).
        await engine.pullOnce()

        let outcome = await engine.lastRoundOutcomeForTesting
        XCTAssertEqual(outcome, .gated)
        XCTAssertEqual(settingsCommits(client).count, 1, "Settings publish while the gate is closed")
    }

    /// CASE B2-1c (c): exhausting the 64-page budget returns .pageBudgetExhausted with zero commits because
    /// canPublishThisRound is false (c9ab5806); markers still advance (B2-8b). The follow-up drains the
    /// remainder and publishes the pending edit. gateGetUpdatesFromCall = 65 suspends the engine-scheduled,
    /// non-awaitable follow-up so the first outcome is deterministic; a later pullOnce waits behind it after
    /// release.
    func testAPageBudgetRoundPublishesNothingUntilAFollowUpDrains() async throws {
        let access = FakeBookmarkAccess()
        let ownedStore = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        seedPendingLocalBookmarkEdit(access: access, store: ownedStore, client: client)
        client.seed(tagHash: bookmarkHash("b9"),
                    ciphertext: try PhiEntityCodec.encrypt(envelope(bookmarkPayload(uuid: "b9")), key: key),
                    version: 5, entityId: "srv-b9")
        client.pageBudgetExhaustsAfter = 1_000
        let followUpGate = Gate()
        client.getUpdatesGate = followUpGate
        client.gateGetUpdatesFromCall = 65
        let engine = makeOwnedEngine(client: client, markerStore: markerStore(marker: "1"),
                                     spaceStore: drainedSpaceStore(),
                                     ownedKinds: [.bookmarks(access: access, store: ownedStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let outcome = await engine.lastRoundOutcomeForTesting
        let pages = await engine.lastRoundPagesForTesting
        let advanced = await engine.lastRoundMarkerAdvancedForTesting
        XCTAssertEqual(outcome, .pageBudgetExhausted)
        XCTAssertEqual(pages, 64)
        XCTAssertTrue(advanced, "Marker advancement is independent of publication")
        XCTAssertTrue(client.commits.isEmpty, "An undrained round publishes nothing")

        client.pageBudgetExhaustsAfter = nil
        await followUpGate.open()
        await engine.pullOnce()                     // Wait behind the follow-up until it drains and publishes

        let drainedOutcome = await engine.lastRoundOutcomeForTesting
        XCTAssertEqual(drainedOutcome, .ok)
        XCTAssertGreaterThanOrEqual(bookmarkCommits(client).count, 1, "Publication waits for the drained round")
    }

    /// CASE B2-1c (d): bookmark local-read failure yields .localReadFailed and zero bookmark pushes; pins and
    /// rules still publish (R-exec-3 is per-kind). Task 6 verifies one r1 rule create and zero urlrules
    /// local_read_failed.
    func testALocalReadFailureIsPerKindAndReportedAsLocalReadFailed() async throws {
        let bookmarkAccess = FakeBookmarkAccess()
        bookmarkAccess.readError = LocalStoreWriteError.storeUnavailable
        let bookmarkStore = MemoryOwnedItemStore()
        let pinAccess = FakePinAccess(scope: .profile, account: .profile,
                                      rows: [.fixture(lineageId: "lp", guid: "gp", profileId: "Default")])
        let pinStore = MemoryOwnedItemStore()
        // Target makeSpaceAccess's s-1 (su-1): ownership is eligible for the snapshot.
        let ruleAccess = FakeURLRuleAccess(rows: [.fixture(id: "ir", syncId: "r1", spaceId: "s-1")])
        let ruleStore = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([], marker: "3")]
        let engine = makeOwnedEngine(client: client, markerStore: markerStore(marker: "0"),
                                     spaceStore: drainedSpaceStore(),
                                     ownedKinds: [.bookmarks(access: bookmarkAccess, store: bookmarkStore),
                                                  .pins(access: pinAccess, store: pinStore),
                                                  .urlRules(access: ruleAccess, store: ruleStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let outcome = await engine.lastRoundOutcomeForTesting
        let counters = await engine.lastOwnedRoundCountersForTesting
        XCTAssertEqual(outcome, .localReadFailed)
        XCTAssertEqual(counters["bookmarks"]?.pushed, 0)
        XCTAssertTrue(bookmarkCommits(client).isEmpty)
        XCTAssertEqual(pinCommits(client).count, 1, "Bookmark read failure does not affect pins")
        XCTAssertGreaterThanOrEqual(counters["pins"]?.pushed ?? 0, 1)
        // CASE B2-1c (d) urlrules（Task 6）
        XCTAssertEqual(counters["bookmarks"]?.localReadFailed, 1, "Only the bookmark kind fails")
        XCTAssertEqual(counters["urlrules"]?.localReadFailed, 0)
        XCTAssertEqual(ruleCommits(client).count, 1, "Bookmark read failure does not affect rules")
        XCTAssertGreaterThanOrEqual(counters["urlrules"]?.pushed ?? 0, 1)
    }

    /// CASE B2-1c (e), whole-branch final review I-1 / R-M3-4a-103: a publication-side bookmark cursor write
    /// failure suppresses only bookmarks. Pins and rules still snapshot, diff, commit, persist and run §8.4.5
    /// clearing (b) plus 3b readmission checks; each commits once with durable cursors. The round ends
    /// cursor_save_failed.
    /// A global cursorSaveFailures == 0 gate in publishOwnedKind would suppress pins/urlrules after bookmarks
    /// in registration order, violating §2.5(6)'s per-kind R-exec-3 requirement. canPublishThisRound stays
    /// true because this failure occurs during push, not page application.
    /// An empty bookmark batch returns through landsEmptyBatch with replayedAfterDelete == 0 and performs no
    /// landing write. Empty local work means the only save is publication's guard !work.isEmpty early-return
    /// write, with no bookmark commit. Only URL rules plan/land empty batches.
    func testAPushSideCursorSaveFailureOfOneKindDoesNotSuppressTheLaterKinds() async throws {
        let bookmarkAccess = FakeBookmarkAccess()
        let bookmarkStore = MemoryOwnedItemStore()
        bookmarkStore.failSaveOnCallNumber = 1
        let pinAccess = FakePinAccess(scope: .profile, account: .profile,
                                      rows: [.fixture(lineageId: "lp", guid: "gp", profileId: "Default")])
        let pinStore = MemoryOwnedItemStore()
        // Target makeSpaceAccess's s-1 (su-1): ownership is eligible for the snapshot.
        let ruleAccess = FakeURLRuleAccess(rows: [.fixture(id: "ir", syncId: "r1", spaceId: "s-1")])
        let ruleStore = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([], marker: "3")]
        let engine = makeOwnedEngine(client: client, markerStore: markerStore(marker: "0"),
                                     spaceStore: drainedSpaceStore(),
                                     ownedKinds: [.bookmarks(access: bookmarkAccess, store: bookmarkStore),
                                                  .pins(access: pinAccess, store: pinStore),
                                                  .urlRules(access: ruleAccess, store: ruleStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let outcome = await engine.lastRoundOutcomeForTesting
        let failures = await engine.lastRoundCursorSaveFailedCountForTesting
        let counters = await engine.lastOwnedRoundCountersForTesting
        XCTAssertEqual(outcome, .cursorSaveFailed)
        XCTAssertEqual(failures, 1, "Only the bookmark publication write fails")
        XCTAssertEqual(bookmarkStore.saveCalls, 1, "The empty page has no landing writes; the only write is publication")
        XCTAssertTrue(bookmarkCommits(client).isEmpty)
        XCTAssertEqual(counters["bookmarks"]?.pushed, 0)
        XCTAssertEqual(pinCommits(client).count, 1, "Bookmark write failure does not affect pins")
        XCTAssertGreaterThanOrEqual(counters["pins"]?.pushed ?? 0, 1)
        XCTAssertEqual(pinStore.table.cursors.count, 1, "The pin cursor persisted")
        XCTAssertEqual(ruleCommits(client).count, 1, "Bookmark write failure does not affect rules")
        XCTAssertGreaterThanOrEqual(counters["urlrules"]?.pushed ?? 0, 1)
        XCTAssertNotNil(ruleStore.table.cursors["r1"], "The rule cursor persisted")
    }

    /// CASE B2-1c (f), final review I-1 negative control / R-M3-4a-103: failure to clear marker while arming
    /// bookmark loss replay must still block bookmark publication/file recreation/latch setting, while pins
    /// and rules publish. Taking before prior to loadOwnedTable includes the arming failure in the per-kind
    /// delta and preserves 2b-L1. Page 1 writes marker first; bookmark replay clearing is write 2. Pin/rule
    /// HadRecords flags are false, so their loads do not report loss or write marker.
    func testAFailedLossReplayArmStillSkipsOnlyItsOwnKind() async throws {
        let spaceStore = drainedSpaceStore()
        spaceStore.table.bookmarksHadRecords = true        // An empty bookmark table means its cursor file was lost
        let bookmarkAccess = FakeBookmarkAccess(rows: [.fixture(guid: "gl", syncId: "bl", spaceId: "s-1",
                                                                title: "Local edit")])
        let bookmarkStore = MemoryOwnedItemStore()
        let pinAccess = FakePinAccess(scope: .profile, account: .profile,
                                      rows: [.fixture(lineageId: "lp", guid: "gp", profileId: "Default")])
        let pinStore = MemoryOwnedItemStore()
        let ruleAccess = FakeURLRuleAccess(rows: [.fixture(id: "ir", syncId: "r1", spaceId: "s-1")])
        let ruleStore = MemoryOwnedItemStore()
        let markerStore = markerStore(marker: "0")
        markerStore.failSaveOnCallNumber = 2
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([], marker: "7")]
        let engine = makeOwnedEngine(client: client, markerStore: markerStore, spaceStore: spaceStore,
                                     ownedKinds: [.bookmarks(access: bookmarkAccess, store: bookmarkStore),
                                                  .pins(access: pinAccess, store: pinStore),
                                                  .urlRules(access: ruleAccess, store: ruleStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let outcome = await engine.lastRoundOutcomeForTesting
        let failures = await engine.lastRoundCursorSaveFailedCountForTesting
        XCTAssertEqual(outcome, .cursorSaveFailed)
        XCTAssertEqual(failures, 1)
        XCTAssertTrue(bookmarkCommits(client).isEmpty, "No publication against the lost table")
        XCTAssertEqual(bookmarkStore.saveCalls, 0, "The empty page writes nothing; publication returns before any write")
        XCTAssertTrue(bookmarkStore.table.cursors.isEmpty, "The next load still detects loss")
        XCTAssertFalse(spaceStore.table.bookmarksReplayedForEmptyTable, "The latch remains unset")
        XCTAssertEqual(markerStore.file.marker, Data("7".utf8), "Clearing the marker failed")
        XCTAssertEqual(pinCommits(client).count, 1, "Failed bookmark replay arming does not affect pins")
        XCTAssertEqual(ruleCommits(client).count, 1, "Rules are unaffected too")
        XCTAssertNotNil(ruleStore.table.cursors["r1"])
    }

    /// CASE B2-1d / R-M3-4a-92: local-edit rounds bypass if thenPush. A final-page cursor save failure leaves
    /// drained true but makes pull return false, blocking push and all commits; the disk marker stays on page
    /// 1. Successful replay of page 2 then publishes the edit. Checking failure only inside if thenPush would
    /// miss this guard await pull(... thenPush: false) path.
    func testALocalOwnedChangeRoundIsBlockedByTheCursorSaveFailureOfItsLastPage() async throws {
        let access = FakeBookmarkAccess()
        let ownedStore = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        seedPendingLocalBookmarkEdit(access: access, store: ownedStore, client: client)
        client.pagesByMarker = [
            page([bookmarkEntity("b1", version: 7)], marker: "7", changesRemaining: true),
            page([bookmarkEntity("b2", version: 9)], marker: "9"),
        ]
        // One landing write per page makes the final page write number 2.
        ownedStore.failSaveOnCallNumber = 2
        let markerStore = markerStore(marker: "0")
        let engine = makeOwnedEngine(client: client, markerStore: markerStore,
                                     spaceStore: drainedSpaceStore(),
                                     ownedKinds: [.bookmarks(access: access, store: ownedStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.handleLocalOwnedChange(label: "bookmarks")

        let outcome = await engine.lastRoundOutcomeForTesting
        let failures = await engine.lastRoundCursorSaveFailedCountForTesting
        let counters = await engine.lastOwnedRoundCountersForTesting["bookmarks"]
        XCTAssertEqual(outcome, .cursorSaveFailed)
        XCTAssertEqual(failures, 1)
        XCTAssertTrue(client.commits.isEmpty, "No bookmark/settings/Space commits: the internal pull returned false")
        XCTAssertEqual(counters?.pushed, 0)
        XCTAssertEqual(markerStore.file.marker, Data("7".utf8), "Marker stays on page 1 without passing page 2")

        ownedStore.failSaveOnCallNumber = nil
        await engine.pullOnce()

        let second = await engine.lastRoundOutcomeForTesting
        XCTAssertEqual(second, .ok)
        XCTAssertEqual(markerStore.file.marker, Data("9".utf8))
        XCTAssertEqual(bookmarkCommits(client).count, 1, "The pending local edit publishes only now")
    }

    /// CASE B2-1e / R-M3-4a-92: after .conflict, cursor persistence failure during the retry pull aborts at
    /// guard await pull. Only the original conflicting bookmark commit exists, and reconciled stays unchanged.
    /// The next successful round retries and applies. Write order: initial pull pages 1/2 → saves 1/2;
    /// publishOwnedKind saves 3; retry alone fetches the higher-watermark page 3, whose landing is save 4.
    func testAConflictRetryIsBlockedByTheCursorSaveFailureOfItsPreflightPull() async throws {
        let access = FakeBookmarkAccess()
        let ownedStore = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        seedPendingLocalBookmarkEdit(access: access, store: ownedStore, client: client)
        let baseline = ownedStore.table.cursors["bl"]?.reconciled
        client.pagesByMarker = [
            page([bookmarkEntity("b1", version: 7)], marker: "7", changesRemaining: true),
            page([bookmarkEntity("b2", version: 9)], marker: "9"),
            page([bookmarkEntity("b3", version: 11)], marker: "11"),
        ]
        client.conflictOnceForTagHashes = [bookmarkHash("bl")]
        ownedStore.failSaveOnCallNumber = 4
        let markerStore = markerStore(marker: "0")
        let engine = makeOwnedEngine(client: client, markerStore: markerStore,
                                     spaceStore: drainedSpaceStore(),
                                     ownedKinds: [.bookmarks(access: access, store: ownedStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.handleLocalOwnedChange(label: "bookmarks")

        let outcome = await engine.lastRoundOutcomeForTesting
        XCTAssertEqual(outcome, .cursorSaveFailed)
        XCTAssertEqual(bookmarkCommits(client).count, 1, "No commits after the conflicting attempt")
        XCTAssertEqual(ownedStore.table.cursors["bl"]?.reconciled, baseline,
                       "The pre-retry baseline did not overwrite it")
        XCTAssertEqual(markerStore.file.marker, Data("9".utf8), "Page 3 of the retry pull did not advance marker")

        ownedStore.failSaveOnCallNumber = nil
        await engine.pullOnce()

        let second = await engine.lastRoundOutcomeForTesting
        XCTAssertEqual(second, .ok)
        XCTAssertEqual(bookmarkCommits(client).count, 2, "Normal retry follows replay of the missing page")
        XCTAssertGreaterThan(ownedStore.table.cursors["bl"]?.version ?? 0, 1, "This attempt is applied")
        XCTAssertEqual(markerStore.file.marker, Data("11".utf8))
    }

    // MARK: - CASE B2-2 (pin cursor save failure)

    /// CASE B2-2: pin cursor save failure preserves marker. Replay matches (lineage, ownerKey), preventing
    /// duplicate pins. B2-2b's positive rowAlreadyMapped case with real LocalStore lives in
    /// PinnedTabScopeTests.
    func testAPinCursorSaveFailureHoldsTheMarkerAndTheReplayDoesNotDuplicateTheRow() async throws {
        let pinAccess = FakePinAccess(scope: .profile, account: .profile)
        let pinStore = MemoryOwnedItemStore()
        pinStore.failNextSave = true
        let markerStore = markerStore(marker: "0")
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([pinEntity("lx", version: 7, entityId: "e1")], marker: "7")]
        let engine = makeOwnedEngine(client: client, markerStore: markerStore,
                                     spaceStore: drainedSpaceStore(),
                                     ownedKinds: [.pins(access: pinAccess, store: pinStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let outcome = await engine.lastRoundOutcomeForTesting
        let counters = await engine.lastOwnedRoundCountersForTesting["pins"]
        XCTAssertEqual(outcome, .cursorSaveFailed)
        XCTAssertEqual(counters?.applied, 1)
        XCTAssertEqual(markerStore.file.marker, Data("0".utf8))
        XCTAssertEqual(pinAccess.rows.count, 1)
        let titleAfterFirstLanding = pinAccess.rows.first?.title

        pinStore.failNextSave = false
        await engine.pullOnce()

        let second = await engine.lastRoundOutcomeForTesting
        let secondCounters = await engine.lastOwnedRoundCountersForTesting["pins"]
        XCTAssertEqual(second, .ok)
        XCTAssertEqual(pinAccess.rows.count, 1, "Replay updates without creating another row")
        XCTAssertEqual(pinCreateCount(pinAccess.lastAppliedOps), 0)
        XCTAssertEqual(pinAccess.rows.first?.title, titleAfterFirstLanding)
        XCTAssertEqual(secondCounters?.refused, 0, "No rowAlreadyMapped errors")
        XCTAssertNotNil(pinStore.table.cursors.values.first { $0.entityId == "e1" })
    }

    // MARK: - CASE B2-3 (URL Rule cursor save failure prevents marker advancement)

    /// CASE B2-3 (Task 6): rule cursor save failure yields cursor_save_failed and zero commits while
    /// preserving M0; landing already created the row. Successful replay preserves its syncId/id/four fields,
    /// uses update with zero creates, and advances to M1. Advancing on failure permanently loses the baseline,
    /// permitting a baseVersion == 0 overwrite; recreating on replay duplicates the local row.
    func testAURLRuleCursorSaveFailureHoldsTheMarkerAndTheReplayDoesNotDuplicateTheRow() async throws {
        let access = FakeURLRuleAccess(rows: [])
        let store = MemoryOwnedItemStore()
        store.failNextSave = true
        let markerStore = markerStore(marker: "0")
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([urlRuleEntity("r1", version: 7, entityId: "e1")], marker: "7")]
        let engine = makeOwnedEngine(client: client, markerStore: markerStore,
                                     spaceStore: drainedSpaceStore(),
                                     ownedKinds: [.urlRules(access: access, store: store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let outcome = await engine.lastRoundOutcomeForTesting
        let advanced = await engine.lastRoundMarkerAdvancedForTesting
        let failures = await engine.lastRoundCursorSaveFailedCountForTesting
        let counters = await engine.lastOwnedRoundCountersForTesting["urlrules"]
        XCTAssertEqual(outcome, .cursorSaveFailed)
        XCTAssertFalse(advanced)
        XCTAssertEqual(failures, 1)
        XCTAssertEqual(counters?.applied, 1)
        XCTAssertEqual(counters?.pushed, 0)
        XCTAssertTrue(client.commits.filter { $0.name == PhiSyncEntity.urlRuleEntityName }.isEmpty)
        XCTAssertEqual(markerStore.file.marker, Data("0".utf8))
        XCTAssertEqual(access.rows.count, 1, "Landing precedes cursor persistence; the row already exists")
        let landed = try XCTUnwrap(access.rows.first)
        XCTAssertEqual(landed.syncId, "r1")
        XCTAssertEqual(landed.spaceId, "s-1")

        store.failNextSave = false
        await engine.pullOnce()

        let second = await engine.lastRoundOutcomeForTesting
        XCTAssertEqual(second, .ok)
        XCTAssertEqual(access.rows.count, 1, "Replay updates without creating another row")
        let replayed = try XCTUnwrap(access.rows.first)
        XCTAssertEqual(replayed.id, landed.id)
        XCTAssertEqual(replayed.syncId, "r1")
        XCTAssertEqual(replayed.host, landed.host)
        XCTAssertEqual(replayed.pathPrefix, landed.pathPrefix)
        XCTAssertEqual(replayed.askBeforeRouting, landed.askBeforeRouting)
        XCTAssertEqual(replayed.spaceId, landed.spaceId)
        XCTAssertEqual(ruleCreateCount(access.lastAppliedOps), 0, "Round two takes the update branch")
        XCTAssertEqual(markerStore.file.marker, Data("7".utf8))
        XCTAssertEqual(store.table.cursors["r1"]?.entityId, "e1", "The cursor persists only now")
    }

    // MARK: - CASE B2-4 (Space table save failure)

    /// CASE B2-4: failed Space-table persistence preserves marker. Replay creates no extra row or mapping and
    /// finally persists the cursor. Swallowing the failure permanently skips the cursor and can make the next
    /// diff publish an outbound tombstone for a supposedly missing local Space.
    func testASpaceTableSaveFailureHoldsTheMarkerAndTheReplayDoesNotDuplicateTheSpace() async throws {
        let spaceAccess = makeSpaceAccess()
        let spaceStore = drainedSpaceStore()
        let markerStore = markerStore(marker: "0")
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([spaceCreateEntity("u1", version: 3)], marker: "3")]
        let engine = makeOwnedEngine(client: client, markerStore: markerStore,
                                     spaceStore: spaceStore, spaceAccess: spaceAccess)
        await engine.setSpaceSyncEnabled(true)
        spaceStore.failNextSave = true                 // The gate write has already completed
        await engine.pullOnce()

        let outcome = await engine.lastRoundOutcomeForTesting
        XCTAssertEqual(outcome, .cursorSaveFailed)
        XCTAssertEqual(markerStore.file.marker, Data("0".utf8))
        XCTAssertEqual(spaceAccess.spaces.count, 2, "The SpaceModel row exists, in addition to s-1")
        XCTAssertEqual(spaceAccess.spaceMappings.values.filter { $0 == "u1" }.count, 1)
        XCTAssertNil(spaceStore.table.cursors["u1"], "The write did not persist")

        spaceStore.failNextSave = false
        await engine.pullOnce()

        let second = await engine.lastRoundOutcomeForTesting
        XCTAssertEqual(second, .ok)
        XCTAssertEqual(spaceAccess.spaces.count, 2, "Replay does not create a second row")
        XCTAssertEqual(spaceAccess.spaceMappings.values.filter { $0 == "u1" }.count, 1, "The mapping is not reminted")
        XCTAssertNotNil(spaceStore.table.cursors["u1"]?.reconciled)
        XCTAssertEqual(spaceStore.table.cursors["u1"]?.entityId, "srv-u1")
        XCTAssertEqual(markerStore.file.marker, Data("3".utf8))
    }

    /// CASE B2-4b: failed derived-state persistence during final drain mutateSpaceTable must count once, yield
    /// .cursorSaveFailed and keep hasDrainedFullReplay false. Page markers already advanced before this write,
    /// so check outcome/count rather than marker_advanced.
    func testAFailedDrainFlagWriteAtTheRoundTailIsCountedAsACursorSaveFailure() async throws {
        let spaceStore = MemorySpaceStore()
        spaceStore.table.drainInProgress = true
        let markerStore = markerStore(marker: "0")
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([spaceCreateEntity("u1", version: 3)], marker: "3")]
        let engine = makeOwnedEngine(client: client, markerStore: markerStore, spaceStore: spaceStore)
        await engine.setSpaceSyncEnabled(true)
        // The next write lands the page; the following write saves the final drain flag.
        spaceStore.failSaveOnCallNumber = spaceStore.saveCalls + 2
        await engine.pullOnce()

        let outcome = await engine.lastRoundOutcomeForTesting
        let failures = await engine.lastRoundCursorSaveFailedCountForTesting
        let advanced = await engine.lastRoundMarkerAdvancedForTesting
        XCTAssertEqual(outcome, .cursorSaveFailed)
        XCTAssertEqual(failures, 1)
        XCTAssertFalse(spaceStore.table.hasDrainedFullReplay, "The write did not persist")
        XCTAssertTrue(spaceStore.table.drainInProgress)
        XCTAssertTrue(advanced, "The page marker advanced before the round-end write")
        XCTAssertNotNil(spaceStore.table.cursors["u1"], "The page landing write succeeded")
    }

    /// CASE B2-4c (a): nil spaceStore early return is not a failure; settings-only engines still advance
    /// marker.
    func testASettingsOnlyEngineCountsNoCursorSaveFailures() async throws {
        let markerStore = markerStore(marker: "0")
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([boolSettingsEntity(key: "phi.test.b24c", true, at: 100,
                                                          version: 10)], marker: "10")]
        let engine = makeSettingsOnlyEngine(client: client, markerStore: markerStore,
                                            settings: boolRegistry("phi.test.b24c"))
        await engine.pullOnce()

        let outcome = await engine.lastRoundOutcomeForTesting
        let failures = await engine.lastRoundCursorSaveFailedCountForTesting
        let advanced = await engine.lastRoundMarkerAdvancedForTesting
        XCTAssertEqual(failures, 0)
        XCTAssertEqual(outcome, .ok)
        XCTAssertTrue(advanced)
        XCTAssertEqual(markerStore.file.marker, Data("10".utf8))
    }

    /// CASE B2-4c (b): isStopped early return is not a failure. Shutdown while commit is suspended after
    /// landing makes all later write entry points return true, without .cursorSaveFailed.
    func testARetiredRoundsEarlyReturnsAreNotCursorSaveFailures() async throws {
        let access = FakeBookmarkAccess()
        let ownedStore = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        seedPendingLocalBookmarkEdit(access: access, store: ownedStore, client: client)
        client.pagesByMarker = [page([bookmarkEntity("b1", version: 7)], marker: "7")]
        let arrived = Gate()
        let release = Gate()
        client.gatedCommitTagHash = bookmarkHash("bl")
        client.arrivedInCommit = arrived
        client.commitGate = release
        let engine = makeOwnedEngine(client: client, markerStore: markerStore(marker: "0"),
                                     spaceStore: drainedSpaceStore(),
                                     ownedKinds: [.bookmarks(access: access, store: ownedStore)])
        await engine.setSpaceSyncEnabled(true)

        let parked = Task { await engine.pullOnce() }
        await arrived.wait()                     // Landing completed; this round is suspended in the bookmark commit
        engine.shutdown()
        await release.open()
        await parked.value

        let outcome = await engine.lastRoundOutcomeForTesting
        let failures = await engine.lastRoundCursorSaveFailedCountForTesting
        XCTAssertNotEqual(outcome, .cursorSaveFailed)
        XCTAssertEqual(failures, 0)
    }

    /// CASE B2-4d (engine coverage): mapSpace throwing persistFailed is the fourth failure site; it yields
    /// .cursorSaveFailed, unchanged marker and pendingApply for the UUID. Successful replay persists the
    /// mapping and resolves localSpaceId. Task 3b's mapping-before-create case B2-4d-x (R-M3-4a-87) adds the
    /// single-row guarantee; the earlier create-before-map implementation left unmapped rows that duplicated
    /// on replay.
    func testASpaceMappingPersistFailureIsCountedAndTheEntityIsReplayed() async throws {
        let spaceAccess = makeSpaceAccess()
        spaceAccess.errorOnNextMapping = SpaceSyncMappingError.persistFailed
        let spaceStore = drainedSpaceStore()
        let markerStore = markerStore(marker: "0")
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([spaceCreateEntity("u1", version: 3)], marker: "3")]
        let engine = makeOwnedEngine(client: client, markerStore: markerStore,
                                     spaceStore: spaceStore, spaceAccess: spaceAccess)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let outcome = await engine.lastRoundOutcomeForTesting
        let failures = await engine.lastRoundCursorSaveFailedCountForTesting
        XCTAssertEqual(outcome, .cursorSaveFailed)
        XCTAssertEqual(failures, 1)
        XCTAssertEqual(markerStore.file.marker, Data("0".utf8))
        XCTAssertNotNil(spaceStore.table.cursors["u1"]?.pendingApply, "Existing parking path")
        XCTAssertNil(spaceAccess.localSpaceId(forSyncUuid: "u1"), "Throwing leaves no trace")

        await engine.pullOnce()

        let second = await engine.lastRoundOutcomeForTesting
        XCTAssertEqual(second, .ok)
        XCTAssertNotNil(spaceAccess.localSpaceId(forSyncUuid: "u1"), "The mapping persisted")
        XCTAssertEqual(spaceAccess.spaceMappings.values.filter { $0 == "u1" }.count, 1)
        XCTAssertNil(spaceStore.table.cursors["u1"]?.pendingApply)
        XCTAssertEqual(markerStore.file.marker, Data("3".utf8))
    }

    // MARK: - CASE B2-5 (settings-page and marker ordering)

    /// CASE B2-5: writeSettings → storedLastEntity → hasAdopted → marker. Failing the marker write must find
    /// the first three already applied. UserDefaults.standard.set cannot report a settings-value write
    /// failure, so there is no settings-side save-failure case.
    func testSettingsLandBeforeTheMarkerWrite() async throws {
        let settingKey = "phi.test.b25"
        defaults.set(false, forKey: settingKey)
        defaults.set(NSNumber(value: Int64(100)), forKey: SyncableSettings.timestampKey(for: settingKey))
        let markerStore = markerStore(marker: "0")
        markerStore.failSaveOnCallNumber = 1
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([boolSettingsEntity(key: settingKey, true, at: 300,
                                                          version: 10)], marker: "10")]
        let engine = makeSettingsOnlyEngine(client: client, markerStore: markerStore,
                                            settings: boolRegistry(settingKey))
        await engine.pullOnce()

        XCTAssertTrue(defaults.bool(forKey: settingKey), "V2 landed")
        XCTAssertEqual(defaults.object(forKey: SyncableSettings.timestampKey(for: settingKey)) as? NSNumber,
                       NSNumber(value: Int64(300)))
        XCTAssertNotNil(defaults.data(forKey: PhiSyncEngine.lastEntityStateKey), "storedLastEntity persisted")
        XCTAssertTrue(defaults.bool(forKey: PhiSyncEngine.hasAdoptedStateKey))
        XCTAssertEqual(markerStore.file.marker, Data("0".utf8), "Marker retains its entry value")
        let outcome = await engine.lastRoundOutcomeForTesting
        XCTAssertEqual(outcome, .cursorSaveFailed)
    }

    /// CASE B2-5b: settings replay is idempotent because timestamps use value.updatedAtMs (R-M3-4a-33). The
    /// second merge preserves K bytes and sidecar 300, not now(). A second engine sees the manually
    /// rolled-back file; the first retains its own memory image.
    func testReceivingTheSameSettingsPageTwiceIsIdempotentByTimestamp() async throws {
        let settingKey = "phi.test.b25b"
        defaults.set(false, forKey: settingKey)
        let markerStore = markerStore(marker: "0")
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([boolSettingsEntity(key: settingKey, true, at: 300,
                                                          version: 10)], marker: "10")]
        let first = makeSettingsOnlyEngine(client: client, markerStore: markerStore,
                                           settings: boolRegistry(settingKey))
        await first.pullOnce()
        XCTAssertTrue(defaults.bool(forKey: settingKey))
        XCTAssertTrue(defaults.bool(forKey: PhiSyncEngine.hasAdoptedStateKey))
        let firstBytes = defaults.data(forKey: SyncableSettings.valueKey(for: settingKey))

        markerStore.file.marker = Data("0".utf8)             // Simulate replay by restoring the entry marker on disk
        let second = makeSettingsOnlyEngine(client: client, markerStore: markerStore,
                                            settings: boolRegistry(settingKey))
        await second.pullOnce()

        XCTAssertEqual(client.getUpdatesCalls.last?.marker, Data("0".utf8))
        XCTAssertTrue(defaults.bool(forKey: settingKey))
        XCTAssertEqual(defaults.data(forKey: SyncableSettings.valueKey(for: settingKey)), firstBytes,
                       "Bytes are identical")
        XCTAssertEqual(defaults.object(forKey: SyncableSettings.timestampKey(for: settingKey)) as? NSNumber,
                       NSNumber(value: Int64(300)), "Does not use any now() timestamp")
    }

    // MARK: - CASE B2-6 / 6b / 6c (termination between apply and marker)

    /// CASE B2-6: fail marker persistence after all landing and cursor writes to model termination before
    /// marker save. Restart a second engine on the same stores; replay adds no rows, creates or adoptions.
    func testARestartAfterAFailedMarkerWriteReplaysThePageWithoutDuplicates() async throws {
        let spaceAccess = makeSpaceAccess()
        let spaceStore = drainedSpaceStore()
        let access = FakeBookmarkAccess()
        let ownedStore = MemoryOwnedItemStore()
        let markerStore = markerStore(marker: "0")
        markerStore.failSaveOnCallNumber = 1
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([bookmarkEntity("b1", version: 7, entityId: "e1")], marker: "7")]
        let first = makeOwnedEngine(client: client, markerStore: markerStore,
                                    spaceStore: spaceStore, spaceAccess: spaceAccess,
                                    ownedKinds: [.bookmarks(access: access, store: ownedStore)])
        await first.setSpaceSyncEnabled(true)
        await first.pullOnce()

        XCTAssertEqual(markerStore.file.marker, Data("0".utf8))
        XCTAssertEqual(ownedStore.table.cursors["b1"]?.entityId, "e1", "All cursor writes completed")
        let titleAfterFirstLanding = access.rows.first?.title

        markerStore.failSaveOnCallNumber = nil
        let second = makeOwnedEngine(client: client, markerStore: markerStore,
                                     spaceStore: spaceStore, spaceAccess: spaceAccess,
                                     ownedKinds: [.bookmarks(access: access, store: ownedStore)])
        let applyCallsBefore = applyCalls(access)
        await second.pullOnce()

        let counters = await second.lastOwnedRoundCountersForTesting["bookmarks"]
        XCTAssertEqual(access.rows.count, 1)
        if applyCalls(access) > applyCallsBefore {
            XCTAssertEqual(createCount(access.lastAppliedOps), 0)
        }
        XCTAssertEqual(counters?.adopted, 0)
        XCTAssertEqual(access.rows.first?.title, titleAfterFirstLanding)
        XCTAssertEqual(markerStore.file.marker, Data("7".utf8))
    }

    /// CASE B2-6b: model termination between kinds by registering only bookmarks and failing marker save. A
    /// second engine registers all three kinds against the same stores: bookmarks remain one row; pins and
    /// rules each land one. Task 6 verifies no first-round rule work and identity-based rule landing with
    /// cursor persistence after restart.
    func testARestartBetweenKindsLandsTheMissingKindWithoutDuplicatingTheFirst() async throws {
        let spaceAccess = makeSpaceAccess()
        let spaceStore = drainedSpaceStore()
        let bookmarkAccess = FakeBookmarkAccess()
        let bookmarkStore = MemoryOwnedItemStore()
        let pinAccess = FakePinAccess(scope: .profile, account: .profile)
        let pinStore = MemoryOwnedItemStore()
        let ruleAccess = FakeURLRuleAccess(rows: [])
        let ruleStore = MemoryOwnedItemStore()
        let markerStore = markerStore(marker: "0")
        markerStore.failSaveOnCallNumber = 1
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([bookmarkEntity("b1", version: 7),
                                      pinEntity("lx", version: 8),
                                      urlRuleEntity("r1", version: 9)], marker: "9")]
        let first = makeOwnedEngine(client: client, markerStore: markerStore,
                                    spaceStore: spaceStore, spaceAccess: spaceAccess,
                                    ownedKinds: [.bookmarks(access: bookmarkAccess, store: bookmarkStore)])
        await first.setSpaceSyncEnabled(true)
        await first.pullOnce()

        XCTAssertEqual(bookmarkAccess.rows.count, 1)
        XCTAssertTrue(pinAccess.rows.isEmpty, "The pin kind never ran")
        XCTAssertTrue(ruleAccess.rows.isEmpty, "The rule kind never ran")
        XCTAssertEqual(markerStore.file.marker, Data("0".utf8))

        markerStore.failSaveOnCallNumber = nil
        let second = makeOwnedEngine(client: client, markerStore: markerStore,
                                     spaceStore: spaceStore, spaceAccess: spaceAccess,
                                     ownedKinds: [.bookmarks(access: bookmarkAccess, store: bookmarkStore),
                                                  .pins(access: pinAccess, store: pinStore),
                                                  .urlRules(access: ruleAccess, store: ruleStore)])
        let applyCallsBefore = applyCalls(bookmarkAccess)
        await second.pullOnce()

        XCTAssertEqual(bookmarkAccess.rows.count, 1, "No duplicate bookmarks")
        if applyCalls(bookmarkAccess) > applyCallsBefore {
            XCTAssertEqual(createCount(bookmarkAccess.lastAppliedOps), 0, "Takes the update branch")
        }
        XCTAssertEqual(pinAccess.rows.count, 1, "No pins are lost")
        XCTAssertEqual(markerStore.file.marker, Data("9".utf8))
        // CASE B2-6b urlrules（Task 6）
        let counters = await second.lastOwnedRoundCountersForTesting["urlrules"]
        XCTAssertEqual(ruleAccess.rows.count, 1, "No rules are lost")
        XCTAssertEqual(ruleAccess.rows.first?.syncId, "r1")
        XCTAssertEqual(ruleAccess.rows.first?.spaceId, "s-1")
        XCTAssertEqual(counters?.applied, 1)
        XCTAssertEqual(ruleStore.table.cursors["r1"]?.entityId, "srv-r1", "The cursor persists only now")
    }

    /// CASE B2-6c: terminate after LocalStore transaction commit but before cursor write. The existing syncId
    /// seeds the tag index through localIdentities, so replay rebuilds entityId e1 in the cursor rather than
    /// creating another row.
    func testARestartAfterAFailedCursorWriteRebuildsTheCursorFromTheLocalIdentity() async throws {
        let spaceAccess = makeSpaceAccess()
        let spaceStore = drainedSpaceStore()
        let access = FakeBookmarkAccess()
        let ownedStore = MemoryOwnedItemStore()
        ownedStore.failNextSave = true
        let markerStore = markerStore(marker: "0")
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([bookmarkEntity("b1", version: 7, entityId: "e1")], marker: "7")]
        let first = makeOwnedEngine(client: client, markerStore: markerStore,
                                    spaceStore: spaceStore, spaceAccess: spaceAccess,
                                    ownedKinds: [.bookmarks(access: access, store: ownedStore)])
        await first.setSpaceSyncEnabled(true)
        await first.pullOnce()

        XCTAssertEqual(access.rows.first?.syncId, "b1", "The row exists with syncId")
        XCTAssertTrue(ownedStore.table.cursors.isEmpty, "Its identity is absent from the cursor table")
        XCTAssertEqual(markerStore.file.marker, Data("0".utf8))

        ownedStore.failNextSave = false
        let second = makeOwnedEngine(client: client, markerStore: markerStore,
                                     spaceStore: spaceStore, spaceAccess: spaceAccess,
                                     ownedKinds: [.bookmarks(access: access, store: ownedStore)])
        let applyCallsBefore = applyCalls(access)
        await second.pullOnce()

        XCTAssertEqual(access.rows.count, 1)
        if applyCalls(access) > applyCallsBefore {
            XCTAssertEqual(createCount(access.lastAppliedOps), 0)
        }
        XCTAssertEqual(ownedStore.table.cursors["b1"]?.entityId, "e1", "The cursor is rebuilt")
        XCTAssertEqual(markerStore.file.marker, Data("7".utf8))
    }

    // MARK: - CASE B2-7 / 7b / 7c (multiple kinds on one page)

    /// One page: 1 settings entity, 1 Space, 2 bookmarks, 1 pin and 1 rule. Task 6 adds rules as the fifth
    /// kind, last.
    private func fourKindPage(settingKey: String) -> FakePhiSyncClient.Page {
        page([
            boolSettingsEntity(key: settingKey, true, at: 300, version: 10),
            spaceCreateEntity("u1", version: 11),
            bookmarkEntity("b1", version: 12),
            bookmarkEntity("b2", version: 13),
            pinEntity("lx", version: 14),
            urlRuleEntity("r1", version: 15),
        ], marker: "15")
    }

    private struct FourKindFixture {
        let spaceAccess: FakePhiSpaceAccess
        let spaceStore: MemorySpaceStore
        let bookmarkAccess: FakeBookmarkAccess
        let bookmarkStore: MemoryOwnedItemStore
        let pinAccess: FakePinAccess
        let pinStore: MemoryOwnedItemStore
        let urlRuleAccess: FakeURLRuleAccess
        let urlRuleStore: MemoryOwnedItemStore
        let markerStore: MemoryMarkerStore
        let client: FakePhiSyncClient
        let settingKey: String
    }

    private func makeFourKindFixture() -> FourKindFixture {
        let settingKey = "phi.test.b27"
        let client = FakePhiSyncClient()
        client.pagesByMarker = [fourKindPage(settingKey: settingKey)]
        return FourKindFixture(spaceAccess: makeSpaceAccess(), spaceStore: drainedSpaceStore(),
                               bookmarkAccess: FakeBookmarkAccess(), bookmarkStore: MemoryOwnedItemStore(),
                               pinAccess: FakePinAccess(scope: .profile, account: .profile),
                               pinStore: MemoryOwnedItemStore(),
                               urlRuleAccess: FakeURLRuleAccess(), urlRuleStore: MemoryOwnedItemStore(),
                               markerStore: markerStore(marker: "0"),
                               client: client, settingKey: settingKey)
    }

    /// Registration order [bookmarks, pins, urlrules] matches the coordinator. Rules are last, so B2-7b covers
    /// termination after the final kind lands but before marker persistence (CASE U-28).
    private func makeFourKindEngine(_ f: FourKindFixture) -> PhiSyncEngine {
        makeOwnedEngine(client: f.client, markerStore: f.markerStore, spaceStore: f.spaceStore,
                        spaceAccess: f.spaceAccess, settings: boolRegistry(f.settingKey),
                        ownedKinds: [.bookmarks(access: f.bookmarkAccess, store: f.bookmarkStore),
                                     .pins(access: f.pinAccess, store: f.pinStore),
                                     .urlRules(access: f.urlRuleAccess, store: f.urlRuleStore)])
    }

    private func assertFourKindsLandedExactlyOnce(_ f: FourKindFixture,
                                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(defaults.bool(forKey: f.settingKey), "Settings value", file: file, line: line)
        XCTAssertEqual(defaults.object(forKey: SyncableSettings.timestampKey(for: f.settingKey)) as? NSNumber,
                       NSNumber(value: Int64(300)), "Settings sidecar", file: file, line: line)
        XCTAssertEqual(f.spaceAccess.spaces.count, 2, "Exactly one Space row in addition to s-1", file: file, line: line)
        XCTAssertEqual(f.spaceAccess.spaceMappings.values.filter { $0 == "u1" }.count, 1,
                       file: file, line: line)
        XCTAssertEqual(f.bookmarkAccess.rows.count, 2, "Two bookmark rows", file: file, line: line)
        XCTAssertEqual(Set(f.bookmarkAccess.rows.compactMap(\.syncId)), ["b1", "b2"], file: file, line: line)
        XCTAssertEqual(f.pinAccess.rows.count, 1, "One pin row", file: file, line: line)
        XCTAssertEqual(f.urlRuleAccess.rows.count, 1, "One rule row", file: file, line: line)
        XCTAssertEqual(f.urlRuleAccess.rows.first?.syncId, "r1", file: file, line: line)
    }

    /// CASE B2-7: only pin-store save fails, preserving marker after all five kinds land. Replay adds no
    /// rows/identities and produces no resurrection, refusal or outbound tombstones. Task 6 verifies one rule
    /// r1, applied == 1 and successful rule cursor persistence despite another kind's failure; round two has
    /// zero tombstones/creates.
    func testOneKindsSaveFailureDoesNotUndoTheOtherKindsAndTheReplayAddsNothing() async throws {
        let f = makeFourKindFixture()
        f.pinStore.failNextSave = true
        let engine = makeFourKindEngine(f)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let advanced = await engine.lastRoundMarkerAdvancedForTesting
        let outcome = await engine.lastRoundOutcomeForTesting
        let firstCounters = await engine.lastOwnedRoundCountersForTesting
        XCTAssertFalse(advanced)
        XCTAssertEqual(outcome, .cursorSaveFailed)
        assertFourKindsLandedExactlyOnce(f)
        XCTAssertNotNil(f.spaceStore.table.cursors["u1"], "The Space cursor persisted; that table did not fail")
        XCTAssertEqual(f.bookmarkStore.table.cursors.count, 2)
        XCTAssertTrue(f.pinStore.table.cursors.isEmpty, "Only the pin write failed to persist")
        // CASE B2-7 urlrules（Task 6）
        XCTAssertEqual(firstCounters["urlrules"]?.applied, 1)
        XCTAssertEqual(f.urlRuleStore.table.cursors.count, 1, "The rule cursor table save succeeded")
        XCTAssertEqual(f.urlRuleStore.table.cursors["r1"]?.entityId, "srv-r1")
        let ruleApplyCallsAfterFirstRound = ruleApplyCalls(f.urlRuleAccess)

        f.pinStore.failNextSave = false
        await engine.pullOnce()

        let second = await engine.lastRoundOutcomeForTesting
        let counters = await engine.lastOwnedRoundCountersForTesting
        XCTAssertEqual(second, .ok)
        assertFourKindsLandedExactlyOnce(f)
        XCTAssertEqual(f.bookmarkStore.table.cursors.count, 2, "Identity count is unchanged")
        XCTAssertEqual(f.pinStore.table.cursors.count, 1)
        XCTAssertEqual(f.urlRuleStore.table.cursors.count, 1, "Rule identity count is unchanged")
        for label in ["bookmarks", "pins", "urlrules"] {
            XCTAssertEqual(counters[label]?.resurrected, 0, label)
            XCTAssertEqual(counters[label]?.refused, 0, label)
            XCTAssertEqual(counters[label]?.tombstones, 0, label)
        }
        // Receiving a live entity again produces no create: its cursor persisted in round one, so replay is a
        // no-op or update (rule probe for R-M3-4a-16 consequence (b)).
        if ruleApplyCalls(f.urlRuleAccess) > ruleApplyCallsAfterFirstRound {
            XCTAssertEqual(ruleCreateCount(f.urlRuleAccess.lastAppliedOps), 0)
        }
        XCTAssertTrue(f.client.commitsAreFreeOfOutboundTombstones(), "Replay emits no outbound tombstone")
        XCTAssertEqual(f.markerStore.file.marker, Data("15".utf8))
    }

    /// CASE B2-7b: all five kinds persist before a failed marker write. A second engine replays without
    /// changing row counts, identities or contents. Task 6 preserves rule
    /// syncId/host/pathPrefix/spaceId/sortOrder with zero adopted/resurrected. Placing rules last specifically
    /// covers the final-kind-to-marker crash window (CASE U-28).
    func testARestartAfterAFullyLandedMultiKindPageReplaysItWithoutDuplicates() async throws {
        let f = makeFourKindFixture()
        f.markerStore.failSaveOnCallNumber = 1
        let first = makeFourKindEngine(f)
        await first.setSpaceSyncEnabled(true)
        await first.pullOnce()

        XCTAssertEqual(f.markerStore.file.marker, Data("0".utf8))
        assertFourKindsLandedExactlyOnce(f)
        let bookmarkTitles = f.bookmarkAccess.rows.map(\.title).sorted()
        let pinTitle = f.pinAccess.rows.first?.title
        let spaceName = f.spaceAccess.spaces.first { f.spaceAccess.spaceMappings[$0.spaceId] == "u1" }?.name
        let ruleBeforeAbort = try XCTUnwrap(f.urlRuleAccess.rows.first)

        f.markerStore.failSaveOnCallNumber = nil
        let second = makeFourKindEngine(f)
        await second.pullOnce()

        let outcome = await second.lastRoundOutcomeForTesting
        let counters = await second.lastOwnedRoundCountersForTesting
        XCTAssertEqual(outcome, .ok)
        assertFourKindsLandedExactlyOnce(f)
        XCTAssertEqual(f.bookmarkStore.table.cursors.count, 2)
        XCTAssertEqual(f.pinStore.table.cursors.count, 1)
        XCTAssertEqual(f.urlRuleStore.table.cursors.count, 1)
        XCTAssertEqual(f.bookmarkAccess.rows.map(\.title).sorted(), bookmarkTitles)
        XCTAssertEqual(f.pinAccess.rows.first?.title, pinTitle)
        XCTAssertEqual(f.spaceAccess.spaces.first { f.spaceAccess.spaceMappings[$0.spaceId] == "u1" }?.name,
                       spaceName)
        // CASE B2-7b urlrules（Task 6）
        let ruleAfterReplay = try XCTUnwrap(f.urlRuleAccess.rows.first)
        XCTAssertEqual(ruleAfterReplay.syncId, ruleBeforeAbort.syncId)
        XCTAssertEqual(ruleAfterReplay.host, ruleBeforeAbort.host)
        XCTAssertEqual(ruleAfterReplay.pathPrefix, ruleBeforeAbort.pathPrefix)
        XCTAssertEqual(ruleAfterReplay.spaceId, ruleBeforeAbort.spaceId)
        XCTAssertEqual(ruleAfterReplay.sortOrder, ruleBeforeAbort.sortOrder)
        XCTAssertEqual(counters["urlrules"]?.adopted, 0)
        XCTAssertEqual(counters["urlrules"]?.resurrected, 0)
        XCTAssertEqual(f.markerStore.file.marker, Data("15".utf8))
    }

    /// CASE B2-7c: replaying a remote tombstone emits no outbound tombstone. Round one deletes the row, fails
    /// cursor save and commits nothing; replay takes the missing-row T3 branch and still emits none.
    /// counters.tombstones counts inbound entities, so outbound absence is checked through client.commits and
    /// pushed.
    func testReceivingARemoteTombstoneTwiceNeverProducesAnOutboundTombstone() async throws {
        let access = FakeBookmarkAccess(rows: [.fixture(guid: "g1", syncId: "b1", spaceId: "s-1")])
        let ownedStore = MemoryOwnedItemStore()
        let payload = bookmarkPayload(uuid: "b1")
        ownedStore.table.cursors["b1"] = ownedCursor(reconciled: baselineBytes(payload),
                                                     server: baselineBytes(payload),
                                                     entityId: "srv-b1", version: 1, ownerUuid: "su-1")
        ownedStore.failNextSave = true
        let markerStore = markerStore(marker: "1")
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([remoteTombstone(tag: bookmarkTag("b1"), version: 9,
                                                      entityId: "srv-b1")], marker: "9")]
        let engine = makeOwnedEngine(client: client, markerStore: markerStore,
                                     spaceStore: drainedSpaceStore(),
                                     ownedKinds: [.bookmarks(access: access, store: ownedStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let outcome = await engine.lastRoundOutcomeForTesting
        let counters = await engine.lastOwnedRoundCountersForTesting["bookmarks"]
        XCTAssertTrue(access.rows.isEmpty, "The row is deleted")
        XCTAssertEqual(outcome, .cursorSaveFailed)
        XCTAssertEqual(counters?.pushed, 0)
        XCTAssertTrue(bookmarkCommits(client).isEmpty, "No bookmark tags")
        XCTAssertEqual(markerStore.file.marker, Data("1".utf8))

        ownedStore.failNextSave = false
        await engine.pullOnce()

        let second = await engine.lastRoundOutcomeForTesting
        let secondCounters = await engine.lastOwnedRoundCountersForTesting["bookmarks"]
        XCTAssertEqual(second, .ok)
        XCTAssertTrue(access.rows.isEmpty)
        XCTAssertEqual(secondCounters?.pushed, 0)
        XCTAssertTrue(bookmarkCommits(client).filter(\.deleted).isEmpty, "No outbound tombstones")
        XCTAssertEqual(markerStore.file.marker, Data("9".utf8))
    }

    // MARK: - CASE B2-8(a) / 8(b) / 8b (mid-round errors and page budget)

    /// CASE B2-8(a): an incremental pull error preserves completed pages. Marker stays on page 3, with
    /// .pullFailed and marker_advanced true; the first three pages landed and the next round resumes at 13.
    func testAnIncrementalRoundInterruptedMidWayKeepsTheLandedPages() async throws {
        let access = FakeBookmarkAccess()
        let ownedStore = MemoryOwnedItemStore()
        let spaceStore = drainedSpaceStore()            // drainInProgress == false: guard 1 does not arm
        let markerStore = markerStore(marker: "10")
        let client = FakePhiSyncClient()
        client.pagesByMarker = (11...15).map { version in
            page([bookmarkEntity("b\(version)", version: Int64(version))], marker: "\(version)",
                 changesRemaining: version < 15)
        }
        client.getUpdatesErrorAfterPages = (pages: 3, error: URLError(.timedOut))
        let engine = makeOwnedEngine(client: client, markerStore: markerStore, spaceStore: spaceStore,
                                     ownedKinds: [.bookmarks(access: access, store: ownedStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let outcome = await engine.lastRoundOutcomeForTesting
        let pages = await engine.lastRoundPagesForTesting
        let advanced = await engine.lastRoundMarkerAdvancedForTesting
        XCTAssertEqual(markerStore.file.marker, Data("13".utf8), "The page-3 marker")
        XCTAssertEqual(pages, 3)
        XCTAssertEqual(outcome, .pullFailed)
        XCTAssertTrue(advanced)
        XCTAssertEqual(Set(access.rows.compactMap(\.syncId)), ["b11", "b12", "b13"], "The first three pages landed")
        XCTAssertTrue(client.commits.isEmpty, "The failed round has no commits")

        let callsBefore = client.getUpdatesCalls.count
        await engine.pullOnce()

        XCTAssertEqual(client.getUpdatesCalls[callsBefore].marker, Data("13".utf8), "Resume from 13")
        XCTAssertEqual(Set(access.rows.compactMap(\.syncId)), ["b11", "b12", "b13", "b14", "b15"])
        XCTAssertEqual(markerStore.file.marker, Data("15".utf8))
    }

    /// CASE B2-8(b): interrupted initial drain must replay from scratch. Nil entry marker arms guard 1; the
    /// catch clears marker so round two replays all five pages before hasDrainedFullReplay becomes true.
    /// Removing that clear would certify a replay containing gaps and wrongly permit owned-kind publication.
    func testAnInterruptedFirstDrainReplaysFromScratch() async throws {
        let access = FakeBookmarkAccess()
        let ownedStore = MemoryOwnedItemStore()
        let spaceStore = MemorySpaceStore()
        let markerStore = markerStore(marker: nil)
        let client = FakePhiSyncClient()
        client.pagesByMarker = (11...15).map { version in
            page([bookmarkEntity("b\(version)", version: Int64(version))], marker: "\(version)",
                 changesRemaining: version < 15)
        }
        client.getUpdatesErrorAfterPages = (pages: 3, error: URLError(.timedOut))
        let engine = makeOwnedEngine(client: client, markerStore: markerStore, spaceStore: spaceStore,
                                     ownedKinds: [.bookmarks(access: access, store: ownedStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let outcome = await engine.lastRoundOutcomeForTesting
        XCTAssertNil(markerStore.file.marker, "An interrupted drain clears marker")
        XCTAssertTrue(spaceStore.table.drainInProgress)
        XCTAssertFalse(spaceStore.table.hasDrainedFullReplay)
        XCTAssertEqual(outcome, .pullFailed)

        let callsBefore = client.getUpdatesCalls.count
        await engine.pullOnce()

        XCTAssertNil(client.getUpdatesCalls[callsBefore].marker, "Actually replay from scratch")
        XCTAssertEqual(client.getUpdatesCalls.count - callsBefore, 5)
        XCTAssertTrue(spaceStore.table.hasDrainedFullReplay)
        XCTAssertFalse(spaceStore.table.drainInProgress)
        XCTAssertEqual(markerStore.file.marker, Data("15".utf8))
    }

    /// CASE B2-8b: .pageBudgetExhausted still advances marker through page 64, with marker_advanced true and
    /// zero commits. The follow-up resumes there and publishes only when drained. Advancing only for .ok would
    /// make large accounts repeat the same 64 pages indefinitely.
    func testAPageBudgetRoundStillAdvancesTheMarkerButCommitsNothing() async throws {
        let access = FakeBookmarkAccess()
        let ownedStore = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.seed(tagHash: bookmarkHash("b9"),
                    ciphertext: try PhiEntityCodec.encrypt(envelope(bookmarkPayload(uuid: "b9")), key: key),
                    version: 5, entityId: "srv-b9")
        client.pageBudgetExhaustsAfter = 1_000
        let followUpGate = Gate()
        client.getUpdatesGate = followUpGate
        client.gateGetUpdatesFromCall = 65
        let markerStore = markerStore(marker: "1")
        let engine = makeOwnedEngine(client: client, markerStore: markerStore,
                                     spaceStore: drainedSpaceStore(),
                                     ownedKinds: [.bookmarks(access: access, store: ownedStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let outcome = await engine.lastRoundOutcomeForTesting
        let advanced = await engine.lastRoundMarkerAdvancedForTesting
        let pages = await engine.lastRoundPagesForTesting
        XCTAssertEqual(outcome, .pageBudgetExhausted)
        XCTAssertTrue(advanced)
        XCTAssertEqual(pages, 64)
        XCTAssertEqual(markerStore.file.marker, Data("5".utf8), "The page-64 marker")
        XCTAssertTrue(client.commits.isEmpty)
        XCTAssertEqual(access.rows.count, 1, "The page-1 entity landed")

        // Suspend the follow-up at request 65; after release it resumes from 5 and drains.
        client.pageBudgetExhaustsAfter = nil
        await followUpGate.open()
        await engine.pullOnce()
        let drainedOutcome = await engine.lastRoundOutcomeForTesting
        XCTAssertEqual(drainedOutcome, .ok)
        XCTAssertEqual(client.getUpdatesCalls[64].marker, Data("5".utf8), "The follow-up resumes from it")
    }

    // MARK: - CASE B2-9 (gated rounds advance marker after recording the gate flag)

    /// CASE B2-9: .gated rounds advance marker and set markerMovedWhileGateShut. Settings value and sidecar
    /// land; the three non-settings entities are discarded and cursors stay empty.
    func testAGatedRoundAdvancesTheMarkerRecordsTheMoveAndLandsSettings() async throws {
        let settingKey = "phi.test.b29"
        let spaceStore = MemorySpaceStore()
        let markerStore = markerStore(marker: "0")
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([
            boolSettingsEntity(key: settingKey, true, at: 300, version: 10),
            spaceCreateEntity("u1", version: 11),
            bookmarkEntity("b1", version: 12),
            pinEntity("lx", version: 13),
        ], marker: "13")]
        let engine = makeOwnedEngine(client: client, markerStore: markerStore, spaceStore: spaceStore,
                                     settings: boolRegistry(settingKey))
        await engine.pullOnce()                            // The gate is closed

        let outcome = await engine.lastRoundOutcomeForTesting
        let advanced = await engine.lastRoundMarkerAdvancedForTesting
        XCTAssertEqual(outcome, .gated)
        XCTAssertTrue(advanced)
        XCTAssertTrue(spaceStore.table.markerMovedWhileGateShut)
        XCTAssertTrue(defaults.bool(forKey: settingKey), "Settings landed")
        XCTAssertEqual(defaults.object(forKey: SyncableSettings.timestampKey(for: settingKey)) as? NSNumber,
                       NSNumber(value: Int64(300)))
        XCTAssertTrue(spaceStore.table.cursors.isEmpty, "The three non-settings entities were discarded")
        XCTAssertEqual(markerStore.file.marker, Data("13".utf8))
    }

    /// CASE B2-9 crash variant / R-M3-4a-77: save the flag, then fail marker persistence. The flag is true
    /// with the entry marker intact and .cursorSaveFailed. A second engine safely replays; opening the gate
    /// then triggers the first applySpaceGate disjunct and full-type replay. RR-B12's former
    /// marker-before-flag order could leave an advanced marker with no replay flag and permanently skip gated
    /// pages.
    func testAGatedRoundWritesTheMoveRecordBeforeTheMarker() async throws {
        let settingKey = "phi.test.b29w"
        let spaceStore = MemorySpaceStore()
        spaceStore.table.hasDrainedFullReplay = true       // Only markerMovedWhileGateShut can arm replay
        let markerStore = markerStore(marker: "0")
        markerStore.failSaveOnCallNumber = 1
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([boolSettingsEntity(key: settingKey, true, at: 300, version: 10)],
                                     marker: "10")]
        let first = makeOwnedEngine(client: client, markerStore: markerStore, spaceStore: spaceStore,
                                    settings: boolRegistry(settingKey))
        await first.pullOnce()

        let outcome = await first.lastRoundOutcomeForTesting
        XCTAssertTrue(spaceStore.table.markerMovedWhileGateShut, "The flag persists first")
        XCTAssertEqual(markerStore.file.marker, Data("0".utf8), "Marker retains its entry value")
        XCTAssertEqual(outcome, .cursorSaveFailed)

        markerStore.failSaveOnCallNumber = nil
        let second = makeOwnedEngine(client: client, markerStore: markerStore, spaceStore: spaceStore,
                                     settings: boolRegistry(settingKey))
        await second.pullOnce()
        let secondOutcome = await second.lastRoundOutcomeForTesting
        XCTAssertEqual(secondOutcome, .gated)
        XCTAssertEqual(markerStore.file.marker, Data("10".utf8), "The same page replays and completes normally")

        await second.setSpaceSyncEnabled(true)
        XCTAssertNil(markerStore.file.marker, "Opening the gate satisfies the first disjunct and replays the whole type")
        XCTAssertTrue(spaceStore.table.drainInProgress)
        XCTAssertFalse(spaceStore.table.markerMovedWhileGateShut)
    }

    /// CASE B2-9 inverse: mutateSpaceTable fails saving the flag, so marker and flag remain unchanged with
    /// .cursorSaveFailed. Return immediately without page 2 (saveCalls == 1). Retry saves the flag on call 2.
    /// Since page 1 has changesRemaining true, gateGetUpdatesFromCall = 2 suspends the automatically scheduled
    /// follow-up; releasing it performs the retry.
    func testAFailedMoveRecordWriteHoldsTheMarkerAndEndsTheRound() async throws {
        let settingKey = "phi.test.b29f"
        let spaceStore = MemorySpaceStore()
        spaceStore.failSaveOnCallNumber = 1
        let markerStore = markerStore(marker: "0")
        let client = FakePhiSyncClient()
        client.pagesByMarker = [
            page([boolSettingsEntity(key: settingKey, true, at: 300, version: 7)], marker: "7",
                 changesRemaining: true),
            page([], marker: "9"),
        ]
        let followUpGate = Gate()
        client.getUpdatesGate = followUpGate
        client.gateGetUpdatesFromCall = 2
        let engine = makeOwnedEngine(client: client, markerStore: markerStore, spaceStore: spaceStore,
                                     settings: boolRegistry(settingKey))
        await engine.pullOnce()

        let outcome = await engine.lastRoundOutcomeForTesting
        let advanced = await engine.lastRoundMarkerAdvancedForTesting
        XCTAssertEqual(outcome, .cursorSaveFailed)
        XCTAssertFalse(advanced)
        XCTAssertEqual(markerStore.file.marker, Data("0".utf8), "This page does not advance marker")
        XCTAssertFalse(spaceStore.table.markerMovedWhileGateShut)
        XCTAssertEqual(spaceStore.saveCalls, 1, "Early return prevents a second-page attempt")
        XCTAssertTrue(markerStore.saves.isEmpty, "No marker writes")

        await followUpGate.open()                          // Release the retry follow-up
        await engine.pullOnce()                            // Queue behind it and wait for completion

        XCTAssertEqual(spaceStore.saveCalls, 2, "Called again")
        XCTAssertTrue(spaceStore.table.markerMovedWhileGateShut)
        XCTAssertEqual(markerStore.file.marker, Data("9".utf8))
    }

    // MARK: - CASE B2-10 (engine coverage)

    /// CASE B2-10 (engine): the failed round has exactly one landing save, no publication save, and
    /// bookmarksHadRecords false. Only successful replay sets it. Store coverage is above.
    func testAFailedCursorSaveRoundWritesExactlyOnceAndLeavesHadRecordsFalse() async throws {
        let spaceStore = drainedSpaceStore()
        let access = FakeBookmarkAccess()
        let ownedStore = MemoryOwnedItemStore()
        ownedStore.failNextSave = true
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([bookmarkEntity("b1", version: 7, entityId: "e1")], marker: "7")]
        let engine = makeOwnedEngine(client: client, markerStore: markerStore(marker: "0"),
                                     spaceStore: spaceStore,
                                     ownedKinds: [.bookmarks(access: access, store: ownedStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertFalse(spaceStore.table.bookmarksHadRecords)
        XCTAssertEqual(ownedStore.saveCalls, 1)

        ownedStore.failNextSave = false
        await engine.pullOnce()

        XCTAssertTrue(spaceStore.table.bookmarksHadRecords)
    }

    // MARK: - CASE B2-12 (push-side cursor failure still converges)

    /// CASE B2-12: failed publication writeOwnedTable yields .cursorSaveFailed with failure count ≥ 1, without
    /// rolling back the marker already advanced by pull. The next pull replays the committed entity, matches
    /// identity, updates the row and rebuilds its cursor. Use stored mode so commits feed the next replay.
    /// Entry marker 0 plus remote b0@50 ensures real pull advancement; landing is save 1 and publication save
    /// 2.
    func testAPublishSideCursorWriteFailureStillConverges() async throws {
        let access = FakeBookmarkAccess(rows: [.fixture(guid: "gl", spaceId: "s-1", title: "Mine")])
        let ownedStore = MemoryOwnedItemStore()
        ownedStore.failSaveOnCallNumber = 2
        let markerStore = markerStore(marker: "0")
        let client = FakePhiSyncClient()
        client.seed(tagHash: bookmarkHash("b0"),
                    ciphertext: try PhiEntityCodec.encrypt(envelope(bookmarkPayload(uuid: "b0")), key: key),
                    version: 50, entityId: "srv-b0")
        let engine = makeOwnedEngine(client: client, markerStore: markerStore,
                                     spaceStore: drainedSpaceStore(),
                                     ownedKinds: [.bookmarks(access: access, store: ownedStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let outcome = await engine.lastRoundOutcomeForTesting
        let failures = await engine.lastRoundCursorSaveFailedCountForTesting
        let advanced = await engine.lastRoundMarkerAdvancedForTesting
        XCTAssertEqual(outcome, .cursorSaveFailed)
        XCTAssertGreaterThanOrEqual(failures, 1)
        XCTAssertTrue(advanced, "Marker does not roll back")
        XCTAssertEqual(markerStore.file.marker, Data("50".utf8))
        XCTAssertEqual(bookmarkCommits(client).count, 1, "The local bookmark create was applied")
        let minted = try XCTUnwrap(access.rows.first { $0.guid == "gl" }?.syncId, "Identity was claimed")
        XCTAssertNil(ownedStore.table.cursors[minted], "The publication write did not persist")

        let applyCallsBefore = applyCalls(access)
        await engine.pullOnce()

        let second = await engine.lastRoundOutcomeForTesting
        XCTAssertEqual(second, .ok)
        XCTAssertEqual(access.rows.count, 2, "Row count is unchanged: b0 plus the local row")
        if applyCalls(access) > applyCallsBefore {
            XCTAssertEqual(createCount(access.lastAppliedOps), 0)
        }
        XCTAssertEqual(ownedStore.table.cursors[minted]?.entityId,
                       client.entityId(forTagHash: bookmarkHash(minted)), "The cursor is rebuilt")
    }

    // MARK: - CASE B2-13 (.unusable does not interrupt drain)

    /// CASE B2-13: undecodable settings on page 2 must not stop the five-page drain. Request markers are
    /// nil/1/2/3/4 (R-M3-4a-76). Review A3: the marker is no longer rewound for unusable settings — it is
    /// shared with every other kind — so every page persists its marker normally, disk ends at page 5,
    /// and the refusal is recorded durably instead; the outcome is still .unusableSettings. Settings
    /// publication is suppressed but pushOwnedItems runs. Preseed drainInProgress and hasDrainedFullReplay
    /// true to prevent guard 1 from resetting the publication prerequisite at nil entry.
    func testAnUnusableSettingsEntityDoesNotInterruptTheDrain() async throws {
        let spaceAccess = makeSpaceAccess()
        let spaceStore = MemorySpaceStore()
        spaceStore.table.hasDrainedFullReplay = true
        spaceStore.table.drainInProgress = true
        let access = FakeBookmarkAccess()
        let ownedStore = MemoryOwnedItemStore()
        let ruleAccess = FakeURLRuleAccess(rows: [])
        let ruleStore = MemoryOwnedItemStore()
        let markerStore = markerStore(marker: nil)
        let client = FakePhiSyncClient()
        client.pagesByMarker = [
            page([], marker: "1", changesRemaining: true),
            page([remoteUnreadable(tag: PhiSyncEntity.clientTag, version: 2)], marker: "2",
                 changesRemaining: true),
            page([urlRuleEntity("r3", version: 3)], marker: "3", changesRemaining: true),
            page([spaceCreateEntity("u4", version: 4)], marker: "4", changesRemaining: true),
            page([bookmarkEntity("b5", version: 5)], marker: "5"),
        ]
        let engine = makeOwnedEngine(client: client, markerStore: markerStore, spaceStore: spaceStore,
                                     spaceAccess: spaceAccess,
                                     ownedKinds: [.bookmarks(access: access, store: ownedStore),
                                                  .urlRules(access: ruleAccess, store: ruleStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let outcome = await engine.lastRoundOutcomeForTesting
        let pages = await engine.lastRoundPagesForTesting
        let counters = await engine.lastOwnedRoundCountersForTesting["bookmarks"]
        let spaceTable = await engine.spaceTableForTesting
        XCTAssertNotNil(spaceTable.cursors["u4"]?.reconciled, "Page 4 landed")
        XCTAssertEqual(spaceAccess.spaceMappings.values.filter { $0 == "u4" }.count, 1)
        XCTAssertEqual(counters?.applied, 1, "Page 5 landed")
        XCTAssertEqual(client.getUpdatesCalls.map(\.marker),
                       [nil, Data("1".utf8), Data("2".utf8), Data("3".utf8), Data("4".utf8)])
        XCTAssertEqual(pages, 5)
        XCTAssertEqual(markerStore.saves.first?.marker, Data("1".utf8), "Page 1 persisted normally")
        XCTAssertEqual(markerStore.saves.map(\.marker),
                       ["1", "2", "3", "4", "5"].map { Data($0.utf8) },
                       "Every page persists its marker; unusable settings do not rewind the shared marker")
        XCTAssertEqual(markerStore.file.marker, Data("5".utf8), "The on-disk marker is page 5 at round end")
        XCTAssertEqual(outcome, .unusableSettings)
        XCTAssertTrue(settingsCommits(client).isEmpty, "`maySettingsPublish == false`")
        XCTAssertEqual(ownedStore.hadRecordsSeen.count, 2, "pushOwnedItems ran: publication loaded the table")
        // CASE B2-13 URL rules (Task 6): the rule on page 3 and its cursor must land after page 2's unusable
        // settings. An implementation that aborts immediately never fetches this page.
        let ruleCounters = await engine.lastOwnedRoundCountersForTesting["urlrules"]
        XCTAssertEqual(ruleCounters?.applied, 1, "Page 3 landed")
        XCTAssertEqual(ruleAccess.rows.count, 1)
        XCTAssertEqual(ruleAccess.rows.first?.syncId, "r3")
        XCTAssertEqual(ruleStore.table.cursors["r3"]?.entityId, "srv-r3")
        XCTAssertEqual(ruleStore.hadRecordsSeen.count, 2,
                       "loadOwnedTable runs twice per round, at entry and publication, regardless of page count")
    }

    // MARK: - CASE B2-14 (round-level guard 2 clears marker before setting the latch)

    private func makeGuard2Fixture()
        -> (store: MemorySpaceStore, markerStore: MemoryMarkerStore, client: FakePhiSyncClient) {
        let store = MemorySpaceStore()
        store.table.hadRecords = true
        store.table.hasDrainedFullReplay = true
        let client = FakePhiSyncClient()
        client.pagesByMarker = [
            page([], marker: "11", changesRemaining: true),
            page([spaceCreateEntity("u12", version: 12)], marker: "12", changesRemaining: true),
            page([], marker: "13"),
        ]
        return (store, markerStore(marker: "10"), client)
    }

    /// CASE B2-14 (a): the first and only marker write is nil, before any page advancement. This round starts
    /// from scratch and lands three pages, but ends with nil marker and hasDrainedFullReplay false; the next
    /// request also uses nil. (b) Moving guard 2 inside the page loop breaks the first-write, final-nil and
    /// incomplete-drain assertions.
    func testGuard2IsRoundLevelAndClearsTheMarkerBeforeBurningTheLatch() async throws {
        let f = makeGuard2Fixture()
        let engine = makeOwnedEngine(client: f.client, markerStore: f.markerStore, spaceStore: f.store)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertTrue(f.store.table.didReplayForEmptyTable)
        XCTAssertTrue(f.store.table.drainInProgress)
        XCTAssertFalse(f.store.table.hasDrainedFullReplay)
        XCTAssertEqual(f.markerStore.saves.count, 1, "This round has only one marker write")
        XCTAssertNil(f.markerStore.saves.first?.marker, "The first write clears marker to nil")
        XCTAssertNil(f.client.getUpdatesCalls.first?.marker, "This round pulls from scratch")
        XCTAssertEqual(f.client.getUpdatesCalls.count, 3)
        XCTAssertNotNil(f.store.table.cursors["u12"], "All three pages land normally")
        XCTAssertNil(f.markerStore.file.marker, "Marker remains nil at round end")
        XCTAssertFalse(f.store.table.hasDrainedFullReplay, "Suppression skips final bookkeeping")
        let outcome = await engine.lastRoundOutcomeForTesting
        XCTAssertEqual(outcome, .ok)

        let callsBefore = f.client.getUpdatesCalls.count
        await engine.pullOnce()
        XCTAssertNil(f.client.getUpdatesCalls[callsBefore].marker, "The next round pulls from nil")
        XCTAssertTrue(f.store.table.hasDrainedFullReplay, "This unsuppressed round completes drain normally")
        XCTAssertEqual(f.markerStore.file.marker, Data("13".utf8))
    }

    /// CASE B2-14 (c): a page-2 network error finds disk marker already nil from guard 2 step 1, with latch
    /// set and drain incomplete. The next round replays from scratch. Delaying the clear until round end would
    /// consume the latch without clearing marker; only resetForNewStoreBirthday resets that latch.
    func testGuard2ClearsTheMarkerBeforeTheFirstPageEvenIfALaterPageThrows() async throws {
        let f = makeGuard2Fixture()
        f.client.getUpdatesErrorAfterPages = (pages: 1, error: URLError(.timedOut))
        let engine = makeOwnedEngine(client: f.client, markerStore: f.markerStore, spaceStore: f.store)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let outcome = await engine.lastRoundOutcomeForTesting
        XCTAssertEqual(outcome, .pullFailed)
        XCTAssertNil(f.markerStore.file.marker, "Persisted in step 1")
        XCTAssertTrue(f.store.table.didReplayForEmptyTable)
        XCTAssertFalse(f.store.table.hasDrainedFullReplay)

        let callsBefore = f.client.getUpdatesCalls.count
        await engine.pullOnce()
        XCTAssertNil(f.client.getUpdatesCalls[callsBefore].marker, "Actually replay from scratch")
        XCTAssertTrue(f.store.table.hasDrainedFullReplay)
    }

    /// CASE B2-14 (d): failSaveOnCallNumber = 2 allows guard 2's clear; suppression prevents page-1 writes.
    /// Restart sees didReplayForEmptyTable true, marker nil and hasDrainedFullReplay false. The released
    /// second engine replays from scratch and completes normally.
    func testGuard2LeavesARestartableStateWhenNoLaterMarkerWriteHappens() async throws {
        let f = makeGuard2Fixture()
        f.markerStore.failSaveOnCallNumber = 2
        let first = makeOwnedEngine(client: f.client, markerStore: f.markerStore, spaceStore: f.store)
        await first.setSpaceSyncEnabled(true)
        await first.pullOnce()

        XCTAssertEqual(f.markerStore.saves.count, 1, "Page 1 is suppressed; no further writes")
        XCTAssertTrue(f.store.table.didReplayForEmptyTable)
        XCTAssertNil(f.markerStore.file.marker)
        XCTAssertFalse(f.store.table.hasDrainedFullReplay)

        f.markerStore.failSaveOnCallNumber = nil
        let second = makeOwnedEngine(client: f.client, markerStore: f.markerStore, spaceStore: f.store)
        let callsBefore = f.client.getUpdatesCalls.count
        await second.pullOnce()
        XCTAssertNil(f.client.getUpdatesCalls[callsBefore].marker)
        XCTAssertTrue(f.store.table.hasDrainedFullReplay)
        XCTAssertEqual(f.markerStore.file.marker, Data("13".utf8))
    }

    /// CASE B2-14 (e), R-M3-4a-89: failure at guard 2 step 1 yields .cursorSaveFailed, one failure, zero
    /// pages/commits, unchanged drain flags and disk marker, and an unset latch. Retry re-enters guard 2,
    /// clears marker, sets the latch and replays three pages while suppression keeps hasDrainedFullReplay
    /// false. (g) Combining or reversing the writes breaks both the unset-latch and unchanged-marker
    /// guarantees.
    func testGuard2StepOneFailureBurnsNothingAndRetriggersNextRound() async throws {
        let f = makeGuard2Fixture()
        f.markerStore.failSaveOnCallNumber = 1
        let engine = makeOwnedEngine(client: f.client, markerStore: f.markerStore, spaceStore: f.store)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let outcome = await engine.lastRoundOutcomeForTesting
        let failures = await engine.lastRoundCursorSaveFailedCountForTesting
        let pages = await engine.lastRoundPagesForTesting
        XCTAssertEqual(outcome, .cursorSaveFailed)
        XCTAssertEqual(failures, 1)
        XCTAssertEqual(pages, 0)
        XCTAssertTrue(f.client.getUpdatesCalls.isEmpty, "No requests occurred")
        XCTAssertFalse(f.store.table.didReplayForEmptyTable, "The latch remains unset")
        XCTAssertFalse(f.store.table.drainInProgress, "Identical to the entry state")
        XCTAssertTrue(f.store.table.hasDrainedFullReplay, "Identical to the entry state")
        XCTAssertEqual(f.markerStore.file.marker, Data("10".utf8), "Disk retains the entry value")
        XCTAssertTrue(f.client.commits.isEmpty)

        f.markerStore.failSaveOnCallNumber = nil
        await engine.pullOnce()

        XCTAssertTrue(f.store.table.didReplayForEmptyTable, "Guard 2 triggers again")
        XCTAssertNil(f.markerStore.file.marker)
        XCTAssertNil(f.client.getUpdatesCalls.first?.marker)
        XCTAssertEqual(f.client.getUpdatesCalls.count, 3, "Replay all three pages from scratch")
        XCTAssertFalse(f.store.table.hasDrainedFullReplay, "Suppression keeps it false")
    }

    /// CASE B2-14 (f): step 1 persists nil but step 2 mutateSpaceTable fails. Rollback leaves latch unset,
    /// zero pages/commits and .cursorSaveFailed. Retry re-enters guard 2; clearing is idempotent with no extra
    /// saves/failures, then step 2 succeeds and full replay proceeds.
    func testGuard2StepTwoFailureIsRetriedWithAnIdempotentStepOne() async throws {
        let f = makeGuard2Fixture()
        let engine = makeOwnedEngine(client: f.client, markerStore: f.markerStore, spaceStore: f.store)
        await engine.setSpaceSyncEnabled(true)
        f.store.failNextSave = true                        // The gate write has already completed
        await engine.pullOnce()

        let outcome = await engine.lastRoundOutcomeForTesting
        let pages = await engine.lastRoundPagesForTesting
        XCTAssertEqual(outcome, .cursorSaveFailed)
        XCTAssertEqual(pages, 0)
        XCTAssertNil(f.markerStore.file.marker, "Step 1 succeeded")
        XCTAssertEqual(f.markerStore.saves.count, 1)
        XCTAssertFalse(f.store.table.didReplayForEmptyTable, "Rollback keeps memory consistent with disk")
        XCTAssertTrue(f.client.commits.isEmpty)

        f.store.failNextSave = false
        await engine.pullOnce()

        let second = await engine.lastRoundOutcomeForTesting
        let secondFailures = await engine.lastRoundCursorSaveFailedCountForTesting
        XCTAssertEqual(second, .ok)
        XCTAssertEqual(secondFailures, 0, "Step 1 is idempotent: no cursorSaveFailures increment")
        XCTAssertEqual(f.markerStore.saves.count, 1, "Step 1 is idempotent: saves does not increase")
        XCTAssertTrue(f.store.table.didReplayForEmptyTable, "Step 2 persists this time")
        XCTAssertEqual(f.client.getUpdatesCalls.count, 3, "Normal replay from scratch")
        XCTAssertNil(f.client.getUpdatesCalls.first?.marker)
    }

    // MARK: - CASE B2-15 (settings .absent is a round-level predicate)

    /// CASE B2-15: settings appear only on page 1; pages 2–5 contain Space/bookmark/pin/rule entities.
    /// clearEntityCursor is never called; page 1's entityId and last entity survive, so the next push uses
    /// update with nonzero baseVersion. Evaluating .absent per page would discard the settings cursor on page
    /// 5 and create instead. Task 6 uses a real rule on the final page to exercise this non-settings-page
    /// boundary.
    func testAbsentSettingsIsARoundLevelPredicate() async throws {
        let settingKey = "phi.test.b215"
        let access = FakeBookmarkAccess()
        let ownedStore = MemoryOwnedItemStore()
        let pinAccess = FakePinAccess(scope: .profile, account: .profile)
        let pinStore = MemoryOwnedItemStore()
        let ruleAccess = FakeURLRuleAccess(rows: [])
        let ruleStore = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.pagesByMarker = [
            page([boolSettingsEntity(key: settingKey, true, at: 300, version: 1, entityId: "srv-set")],
                 marker: "1", changesRemaining: true),
            page([spaceCreateEntity("u2", version: 2)], marker: "2", changesRemaining: true),
            page([bookmarkEntity("b3", version: 3)], marker: "3", changesRemaining: true),
            page([pinEntity("l4", version: 4)], marker: "4", changesRemaining: true),
            page([urlRuleEntity("r5", version: 5)], marker: "5"),
        ]
        client.seed(ciphertext: Data(), version: 1, entityId: "srv-set")
        let engine = makeOwnedEngine(client: client, markerStore: markerStore(marker: nil),
                                     spaceStore: MemorySpaceStore(), settings: boolRegistry(settingKey),
                                     ownedKinds: [.bookmarks(access: access, store: ownedStore),
                                                  .pins(access: pinAccess, store: pinStore),
                                                  .urlRules(access: ruleAccess, store: ruleStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertEqual(defaults.string(forKey: PhiSyncEngine.entityIdStateKey), "srv-set",
                       "clearEntityCursor() is never called")
        XCTAssertNotNil(defaults.data(forKey: PhiSyncEngine.lastEntityStateKey))
        // CASE B2-15 URL rules (Task 6): verify the last-page rule actually landed, establishing that the
        // final page contains a non-settings entity.
        let ruleCounters = await engine.lastOwnedRoundCountersForTesting["urlrules"]
        XCTAssertEqual(ruleCounters?.applied, 1, "Page 5 landed")
        XCTAssertEqual(ruleAccess.rows.count, 1)
        XCTAssertEqual(ruleAccess.rows.first?.syncId, "r5")
        XCTAssertEqual(ruleStore.table.cursors["r5"]?.entityId, "srv-r5")

        defaults.set(false, forKey: settingKey)             // Local edit publishes next round
        await engine.pushLocalSettings()

        let last = try XCTUnwrap(settingsCommits(client).last)
        XCTAssertEqual(last.entityId, "srv-set", "Takes the update branch")
        XCTAssertNotEqual(last.baseVersion, 0)
    }

    /// CASE B2-15 positive control: no settings across five pages, drained, startedFromScratch and a prior
    /// storedEntityId cause exactly one clearEntityCursor, making the key nil.
    func testAFullReplayWithoutASettingsEntityClearsTheStaleEntityCursorOnce() async throws {
        defaults.set("stale-id", forKey: PhiSyncEngine.entityIdStateKey)
        let client = FakePhiSyncClient()
        client.pagesByMarker = [
            page([], marker: "1", changesRemaining: true),
            page([spaceCreateEntity("u2", version: 2)], marker: "2", changesRemaining: true),
            page([], marker: "3", changesRemaining: true),
            page([], marker: "4", changesRemaining: true),
            page([], marker: "5"),
        ]
        let engine = makeOwnedEngine(client: client, markerStore: markerStore(marker: nil),
                                     spaceStore: MemorySpaceStore())
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertNil(defaults.string(forKey: PhiSyncEngine.entityIdStateKey), "The entity-id key becomes nil")
        XCTAssertEqual(client.getUpdatesCalls.count, 5)
        XCTAssertNil(defaults.string(forKey: PhiSyncEngine.storeBirthdayStateKey),
                     "An injected marker store prevents all defaults writes")
    }

    // MARK: - CASE B2-16 (owner resolution across pages)

    /// CASE B2-16: page 2 carries a new Space and its bookmark; Space routing runs first, so the bookmark
    /// lands this round with parked 0 and applied 1. Without invalidating ownedMapsThisRound at page end,
    /// classify reuses page 1's map and parks until next round. Task 6 adds the equivalent rule case below.
    func testABookmarkOwnedByASpaceLandedOnTheSamePageResolvesThisRound() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess()
        let ownedStore = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.pagesByMarker = [
            page([], marker: "1", changesRemaining: true),        // Page 1 already built an owner-resolution map
            page([spaceCreateEntity("u2", version: 2),
                  bookmarkEntity("b2", version: 3, spaceUuid: "u2")], marker: "3"),
        ]
        let engine = makeOwnedEngine(client: client, markerStore: markerStore(marker: "0"),
                                     spaceStore: drainedSpaceStore(), spaceAccess: spaceAccess,
                                     ownedKinds: [.bookmarks(access: access, store: ownedStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let counters = await engine.lastOwnedRoundCountersForTesting["bookmarks"]
        XCTAssertEqual(counters?.parked, 0)
        XCTAssertEqual(counters?.applied, 1)
        let landedSpaceId = try XCTUnwrap(spaceAccess.localSpaceId(forSyncUuid: "u2"))
        XCTAssertEqual(access.rows.first?.spaceId, landedSpaceId, "Lands in the newly created Space")
        XCTAssertNil(ownedStore.table.cursors["b2"]?.pendingApply)
    }

    /// CASE B2-16 URL rules (Task 6): a new Space and a rule targeting it share a page. The rule lands in that
    /// new Space this round with parked 0, applied 1 and no pendingApply. Reusing page 1's cached owner map
    /// would fail to resolve u2 and park it. This separately exercises target_space_uuid resolution rather
    /// than the bookmark's space_uuid path.
    func testAURLRuleOwnedByASpaceLandedOnTheSamePageResolvesThisRound() async throws {
        let spaceAccess = makeSpaceAccess()
        let ruleAccess = FakeURLRuleAccess(rows: [])
        let ruleStore = MemoryOwnedItemStore()
        let markerStore = markerStore(marker: "0")
        let client = FakePhiSyncClient()
        client.pagesByMarker = [
            page([], marker: "1", changesRemaining: true),        // Page 1 already built an owner-resolution map
            page([spaceCreateEntity("u2", version: 2),
                  urlRuleEntity("r2", version: 3, targetSpaceUuid: "u2")], marker: "3"),
        ]
        let engine = makeOwnedEngine(client: client, markerStore: markerStore,
                                     spaceStore: drainedSpaceStore(), spaceAccess: spaceAccess,
                                     ownedKinds: [.urlRules(access: ruleAccess, store: ruleStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let counters = await engine.lastOwnedRoundCountersForTesting["urlrules"]
        XCTAssertEqual(counters?.parked, 0)
        XCTAssertEqual(counters?.applied, 1)
        XCTAssertEqual(ruleAccess.rows.count, 1)
        XCTAssertEqual(ruleAccess.rows.first?.syncId, "r2")
        let landedSpaceId = try XCTUnwrap(spaceAccess.localSpaceId(forSyncUuid: "u2"))
        XCTAssertEqual(ruleAccess.rows.first?.spaceId, landedSpaceId, "Lands in the newly created Space")
        XCTAssertNil(ruleStore.table.cursors["r2"]?.pendingApply)
        XCTAssertEqual(markerStore.file.marker, Data("3".utf8))
    }

    // MARK: - CASE B2-18 (engine coverage)

    /// CASE B2-18 (engine): failed gated-round plist persistence yields .cursorSaveFailed, unchanged marker
    /// and saveCalls 1. Replay of the same page must detect the difference again and save on call 2. Only
    /// after markerMovedWhileGateShut persists may marker advance; advancement is the observable proxy for the
    /// memory latch. Variant (a) fails again; variants (b)/(c) live in
    /// PhiSyncEngineSpaceTests/SpaceSyncMappingManagerTests (Task 2a).
    func testAFailedMoveRecordWriteIsRetriedOnTheReplayedPage() async throws {
        let spaceStore = MemorySpaceStore()
        spaceStore.failSaveOnCallNumber = 1
        let markerStore = markerStore(marker: "0")
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([boolSettingsEntity(key: "phi.test.b218", true, at: 300,
                                                          version: 7)], marker: "7")]
        let engine = makeOwnedEngine(client: client, markerStore: markerStore, spaceStore: spaceStore)
        await engine.pullOnce()                            // The gate is closed

        let outcome = await engine.lastRoundOutcomeForTesting
        XCTAssertEqual(outcome, .cursorSaveFailed)
        XCTAssertEqual(markerStore.file.marker, Data("0".utf8))
        XCTAssertEqual(spaceStore.saveCalls, 1)
        XCTAssertFalse(spaceStore.table.markerMovedWhileGateShut)

        await engine.pullOnce()

        let second = await engine.lastRoundOutcomeForTesting
        XCTAssertEqual(second, .gated)
        XCTAssertEqual(spaceStore.saveCalls, 2, "Detects the difference and saves again")
        XCTAssertTrue(spaceStore.table.markerMovedWhileGateShut)
        XCTAssertEqual(markerStore.file.marker, Data("7".utf8), "Marker advances only after successful persistence")
    }

    /// CASE B2-18 variant (a): a second failure still prevents advancement; saveCalls == 2.
    func testTwoFailedMoveRecordWritesNeverAdvanceTheMarker() async throws {
        let spaceStore = MemorySpaceStore()
        spaceStore.failNextSave = true
        let markerStore = markerStore(marker: "0")
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([boolSettingsEntity(key: "phi.test.b218a", true, at: 300,
                                                          version: 7)], marker: "7")]
        let engine = makeOwnedEngine(client: client, markerStore: markerStore, spaceStore: spaceStore)
        await engine.pullOnce()
        await engine.pullOnce()

        let outcome = await engine.lastRoundOutcomeForTesting
        XCTAssertEqual(outcome, .cursorSaveFailed)
        XCTAssertEqual(spaceStore.saveCalls, 2, "One attempt per round, without internal retry")
        XCTAssertEqual(markerStore.file.marker, Data("0".utf8), "Marker still does not advance")
        XCTAssertTrue(markerStore.saves.isEmpty)
        XCTAssertFalse(spaceStore.table.markerMovedWhileGateShut)
    }

    // MARK: - Review A2 (a loss observed at round entry survives a landing that rewrites the file)

    /// Review A2: the bookmark cursor file is lost (`bookmarksHadRecords == true`, empty table at round
    /// entry) and the same pull lands one incoming bookmark, which writes a one-cursor file back before
    /// publication re-loads the table. A non-empty file no longer reports loss, so without the entry
    /// observation publication would find no loss, never arm the replay, and commit every cursor-less
    /// local row — here `gl` — as an `entityId = nil` create over the account tree. The loss observed at
    /// entry must stand: replay armed marker-first, latch set, nothing published this round.
    func testALossObservedAtRoundEntryStillArmsTheReplayAfterLandingRewroteTheFile() async throws {
        let spaceStore = drainedSpaceStore()
        spaceStore.table.bookmarksHadRecords = true
        let access = FakeBookmarkAccess(rows: [.fixture(guid: "gl", syncId: "bl", spaceId: "s-1",
                                                        title: "Local, cursor lost")])
        let ownedStore = MemoryOwnedItemStore()               // Empty at entry: the cursor file was lost
        let markerStore = markerStore(marker: "0")
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([bookmarkEntity("b1", version: 7, entityId: "e1")], marker: "7")]
        let engine = makeOwnedEngine(client: client, markerStore: markerStore, spaceStore: spaceStore,
                                     ownedKinds: [.bookmarks(access: access, store: ownedStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertNotNil(ownedStore.table.cursors["b1"], "landing still persists the page it received")
        XCTAssertTrue(client.commits.isEmpty,
                      "no cursor-less local row may be published as a create while the tree is unread")
        XCTAssertNil(markerStore.file.marker, "publication armed the replay from the loss seen at entry")
        XCTAssertTrue(spaceStore.table.bookmarksReplayedForEmptyTable, "the per-kind latch is consumed")
        XCTAssertTrue(spaceStore.table.drainInProgress)
        XCTAssertFalse(spaceStore.table.hasDrainedFullReplay)
    }

    // MARK: - CASE 2b-L1 (failed loss-replay arming blocks kind publication and file recreation)

    /// CASE 2b-L1, Task 2b fix round 1 / R-M3-4a-103: bookmarksHadRecords true marks the empty cursor file as
    /// lost. With a pending local edit, failure to clear marker in arming step ① must produce zero commits/new
    /// store writes, leave bookmarksReplayedForEmptyTable false and yield cursor_save_failed. Retry redetects
    /// loss, clears marker, sets the latch and arms drain. Task 6 U-18 adds two URL-rule R-103 variants.
    /// loadOwnedTable's failure branches return (table, false), so guard !loaded.lost alone would allow
    /// snapshot/diff/commit against an empty baseline and recreate the cursor file. That would publish the
    /// edit as a create, hide file loss forever and permanently prevent per-kind full replay.
    /// Settings have an empty storedLastEntity so outgoing == last; su-1 is unreadableTagHashes-gated by guard
    /// 3. Thus zero commits specifically tests bookmarks. Page 1's marker is write 1; the failed replay clear
    /// is write 2.
    func testAFailedLossReplayArmDoesNotPublishAgainstTheLostTableNorRecreateItsFile() async throws {
        let spaceStore = drainedSpaceStore()
        spaceStore.table.bookmarksHadRecords = true
        spaceStore.table.unreadableTagHashes[
            PhiSyncEntity.clientTagHash(for: PhiSyncEntity.spaceClientTag("su-1"))] = 1
        defaults.set(try Phi_PhiSettingEntity().serializedData(),
                     forKey: PhiSyncEngine.lastEntityStateKey)
        let access = FakeBookmarkAccess(rows: [.fixture(guid: "gl", syncId: "bl", spaceId: "s-1",
                                                        title: "Local edit")])
        let ownedStore = MemoryOwnedItemStore()               // An empty table means the cursor file was lost
        let markerStore = markerStore(marker: "0")
        markerStore.failSaveOnCallNumber = 2
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([], marker: "7")]
        let engine = makeOwnedEngine(client: client, markerStore: markerStore, spaceStore: spaceStore,
                                     ownedKinds: [.bookmarks(access: access, store: ownedStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let outcome = await engine.lastRoundOutcomeForTesting
        let failures = await engine.lastRoundCursorSaveFailedCountForTesting
        XCTAssertEqual(outcome, .cursorSaveFailed)
        XCTAssertEqual(failures, 1)
        XCTAssertTrue(client.commits.isEmpty, "No commit calls")
        XCTAssertTrue(client.callLog.filter { $0 == "commit" }.isEmpty)
        // An empty bookmark page returns through landsEmptyBatch with replayedAfterDelete 0 and writes
        // nothing. Publication returns before any write too, so save count is zero.
        XCTAssertEqual(ownedStore.saveCalls, 0, "Publication did not recreate the file")
        XCTAssertTrue(ownedStore.table.cursors.isEmpty, "No cursor persisted; the next load still detects loss")
        XCTAssertEqual(ownedStore.hadRecordsSeen, [true, true], "Loss is detected at round entry and publication")
        XCTAssertFalse(spaceStore.table.bookmarksReplayedForEmptyTable, "The latch remains unset")
        XCTAssertFalse(spaceStore.table.drainInProgress, "Drain is not armed")
        XCTAssertTrue(spaceStore.table.hasDrainedFullReplay)
        XCTAssertEqual(markerStore.file.marker, Data("7".utf8), "Page 1 marker persisted, but clearing marker failed")
        XCTAssertEqual(markerStore.saves.count, 2)

        markerStore.failSaveOnCallNumber = nil
        await engine.pullOnce()

        let second = await engine.lastRoundOutcomeForTesting
        XCTAssertEqual(second, .ok)
        XCTAssertTrue(client.commits.isEmpty, "Loss is detected again, so this round still publishes nothing")
        XCTAssertNil(markerStore.file.marker, "Marker is cleared to nil")
        XCTAssertTrue(spaceStore.table.bookmarksReplayedForEmptyTable, "The latch persisted")
        XCTAssertTrue(spaceStore.table.drainInProgress, "Replay is armed")
        XCTAssertFalse(spaceStore.table.hasDrainedFullReplay)
        XCTAssertTrue(ownedStore.table.cursors.isEmpty, "Still no publication against the empty table")
    }

    // MARK: - Task 3b: mapping before inbound Space create (R-M3-4a-87)

    /// Read preminted local IDs (UUID().uuidString) from mapSpace calls, without assuming constants. Call
    /// order preserves mint order, so count measures mint attempts.
    private func mintedSpaceIds(_ access: FakePhiSpaceAccess, syncUuid: String) -> [String] {
        access.calls.compactMap {
            if case .mapSpace(let spaceId, let uuid) = $0, uuid == syncUuid { return spaceId }
            return nil
        }
    }

    /// All create calls, including the failing one: createError records before throwing.
    private func spaceCreateCalls(_ access: FakePhiSpaceAccess) -> [String] {
        access.calls.compactMap { if case .create(let id) = $0 { return id } else { return nil } }
    }

    /// Space entity commits only; settings share the commits list but are outside these cases.
    private func spaceCommits(_ client: FakePhiSyncClient) -> [FakePhiSyncClient.CommitCall] {
        client.commits.filter { $0.name == PhiSyncEntity.spaceEntityName }
    }

    /// CASE B2-17neg is a documented negative control and ledger entry, not duplicate test code. Restoring
    /// create-before-map changes the crash window to an existing row without mapping. On retry
    /// localSpaceId(forSyncUuid:) misses, so A0 recovery cannot run; create adds a second same-named Space.
    /// Later ensureMapped mints another UUID for the orphan row, duplicating the account entity (M3-2b
    /// App-B#2/#3/#17). Review must see B2-17's single-row, single sync-new mapping and dropSpaceMapping
    /// assertions fail under that order; a comments-only fix is insufficient.
    /// CASE B2-17, §2.6 crash-window table row 2: mapping persists, then createError records create and throws
    /// before transaction commit. First round verifies mapSpace precedes create, create receives the preminted
    /// ID, one dangling mapping exists, no rows/baseline exist, and pendingApply persists. land failure is not
    /// persistence failure because mapSpace succeeded (ruling 7), so marker advances.
    /// Round two has no new client page; pendingApply returns the entity to all. A0 resolves the mapping but
    /// isKnownLocalSpace is false, so it drops the mapping, mints again and lands one row with one mapping and
    /// no second UUID. If dropSpaceMapping silently failed, mapSpace(newId2, …) would throw
    /// syncUuidAlreadyClaimed, park and retry next round (ruling 6); the fake cannot fail that Void operation,
    /// so this branch is reasoned rather than tested.
    /// This guards against unhealed dangling mappings, including an erroneous cursor.reconciled == nil
    /// restriction on A0: such mappings prevent Space creation and permanently park dependent rules while
    /// appearing indistinguishable from an absent remote Space.
    func testACrashBetweenTheMappingWriteAndTheRowCreateLeavesADanglingMappingThatHealsIntoOneRow() async throws {
        let spaceAccess = makeSpaceAccess([:])                 // No rows or mappings
        spaceAccess.createError = NSError(domain: "test", code: 1)
        let spaceStore = drainedSpaceStore()
        let markerStore = markerStore(marker: "0")
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([spaceCreateEntity("sync-new", version: 3)], marker: "3")]
        let engine = makeOwnedEngine(client: client, markerStore: markerStore,
                                     spaceStore: spaceStore, spaceAccess: spaceAccess)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let outcome = await engine.lastRoundOutcomeForTesting
        let minted = mintedSpaceIds(spaceAccess, syncUuid: "sync-new")
        XCTAssertEqual(minted.count, 1)
        let newId = try XCTUnwrap(minted.first)
        let mapIndex = try XCTUnwrap(spaceAccess.calls.firstIndex(
            of: .mapSpace(spaceId: newId, syncUuid: "sync-new")))
        let createIndex = try XCTUnwrap(spaceAccess.calls.firstIndex(of: .create(newId)))
        XCTAssertLessThan(mapIndex, createIndex,
                          "mapSpace precedes create, which receives the preminted ID")
        XCTAssertEqual(spaceAccess.allSpaceMappings(), [newId: "sync-new"], "Exactly one dangling mapping")
        XCTAssertTrue(spaceAccess.spaces.isEmpty, "No rows")
        XCTAssertNotNil(spaceStore.table.cursors["sync-new"]?.pendingApply, "Parked")
        XCTAssertNil(spaceStore.table.cursors["sync-new"]?.reconciled, "No baseline write")
        XCTAssertNotEqual(outcome, .cursorSaveFailed,
                          "land errors are not persistence failures; mapSpace persistFailed sets the flag, and mapping succeeded here")
        XCTAssertEqual(markerStore.file.marker, Data("3".utf8), "The page advances marker; replay comes from parking")

        spaceAccess.createError = nil
        await engine.pullOnce()

        XCTAssertEqual(client.getUpdatesCalls.last?.marker, Data("3".utf8), "The fake client has no new pages this round")
        XCTAssertTrue(spaceAccess.calls.contains(.dropSpaceMapping(newId)), "A0 recovery ran")
        XCTAssertEqual(spaceCreateCalls(spaceAccess).count, 2, "The first throwing attempt also recorded a call")
        XCTAssertEqual(spaceAccess.spaces.count, 1, "One final row is the case invariant")
        let rowId = try XCTUnwrap(spaceAccess.spaces.first?.spaceId)
        XCTAssertNotEqual(rowId, newId, "Recovery remints without reusing the dangling ID")
        let mappingsForUuid = spaceAccess.allSpaceMappings().filter { $0.value == "sync-new" }
        XCTAssertEqual(mappingsForUuid.count, 1, "Exactly one mapping has value sync-new")
        XCTAssertEqual(mappingsForUuid.keys.first, rowId)
        XCTAssertEqual(spaceAccess.allSpaceMappings().count, 1, "No second UUID or dangling residue")
        let resolved = try XCTUnwrap(spaceAccess.localSpaceId(forSyncUuid: "sync-new"))
        XCTAssertTrue(spaceAccess.isKnownLocalSpace(resolved))
        XCTAssertNotNil(spaceStore.table.cursors["sync-new"]?.reconciled)
        XCTAssertNil(spaceStore.table.cursors["sync-new"]?.pendingApply)
    }

    /// CASE B2-17a, §2.6 crash-window table row 3: after row creation, writeSpaceTable fails with
    /// cursor_save_failed and unchanged marker. The fake replays the same page next round; the existing
    /// mapping resolves, bypassing the entire mint/create block. Land updates, leaving create/mapSpace counts
    /// at one, one row and a newly durable cursor.
    /// Observe the update branch through themeState(newId), which applyThemeState always calls for nondefault
    /// Spaces. update(spaceId:…) is conditional on name/color/icon/creation-time differences; identical replay
    /// has none. A guard that checks only !isDefault and omits localSpaceId == nil would remint, hit
    /// syncUuidAlreadyClaimed and permanently park an otherwise idempotent update.
    func testACrashBetweenTheRowCreateAndTheCursorWriteReplaysThePageThroughTheUpdateBranch() async throws {
        let spaceAccess = makeSpaceAccess([:])
        let spaceStore = drainedSpaceStore()
        let markerStore = markerStore(marker: "0")
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([spaceCreateEntity("sync-new", version: 3)], marker: "3")]
        let engine = makeOwnedEngine(client: client, markerStore: markerStore,
                                     spaceStore: spaceStore, spaceAccess: spaceAccess)
        await engine.setSpaceSyncEnabled(true)
        spaceStore.failNextSave = true                 // The gate write has already completed
        await engine.pullOnce()

        let outcome = await engine.lastRoundOutcomeForTesting
        let advanced = await engine.lastRoundMarkerAdvancedForTesting
        XCTAssertEqual(outcome, .cursorSaveFailed)
        XCTAssertFalse(advanced)
        XCTAssertEqual(markerStore.file.marker, Data("0".utf8), "Disk retains markerAtEntry")
        XCTAssertEqual(spaceAccess.spaces.count, 1, "The row exists")
        XCTAssertEqual(spaceAccess.allSpaceMappings().count, 1, "The mapping persisted")
        XCTAssertNil(spaceStore.table.cursors["sync-new"], "The cursor write did not persist")
        let newId = try XCTUnwrap(mintedSpaceIds(spaceAccess, syncUuid: "sync-new").first)
        XCTAssertEqual(spaceAccess.spaces.first?.spaceId, newId, "create receives the preminted ID")
        let callsAfterFirstRound = spaceAccess.calls.count

        spaceStore.failNextSave = false
        await engine.pullOnce()

        let second = await engine.lastRoundOutcomeForTesting
        let secondRoundCalls = Array(spaceAccess.calls[callsAfterFirstRound...])
        XCTAssertEqual(second, .ok)
        XCTAssertEqual(client.getUpdatesCalls.last?.marker, Data("0".utf8), "The same marker replays the same page")
        XCTAssertEqual(spaceCreateCalls(spaceAccess).count, 1, "The second attempt creates no new row")
        XCTAssertEqual(mintedSpaceIds(spaceAccess, syncUuid: "sync-new").count, 1, "No second UUID is minted")
        XCTAssertEqual(spaceAccess.allSpaceMappings(), [newId: "sync-new"])
        XCTAssertTrue(secondRoundCalls.contains(.themeState(newId)), "Replay takes the update branch")
        XCTAssertFalse(secondRoundCalls.contains(.dropSpaceMapping(newId)), "The row exists, so recovery does not run")
        XCTAssertEqual(spaceAccess.spaces.count, 1, "One row")
        XCTAssertNotNil(spaceStore.table.cursors["sync-new"]?.reconciled)
        XCTAssertNil(spaceStore.table.cursors["sync-new"]?.pendingApply)
        XCTAssertEqual(markerStore.file.marker, Data("3".utf8))
    }

    /// CASE B2-4d-x cross-checks B2-4d: mapSpaceError = .persistFailed throws before recording a mapping and
    /// remains armed. Round one hits the fourth failure site, yielding cursor_save_failed and unchanged marker
    /// with no mapping, row, mapSpace call or create call. pendingApply itself persists before the failure
    /// flag is set. The round drains; cursorSaveFailed closes publication's canPublishThisRound conjunction.
    /// Round two replays the same marker/page. all = pending.filter { !incoming.contains(uuid) } + incoming
    /// deduplicates sync-new, producing exactly one mapSpace/create and one mapping/row. This catches
    /// create-before-map or a missing catch continue leaving an orphan row, failure treated only as parking
    /// (which advances marker and makes cursor loss permanent), and missing pending/incoming deduplication
    /// producing two creates.
    func testAMappingPersistFailureLeavesNoTraceAndTheReplayedPageLandsExactlyOnce() async throws {
        let spaceAccess = makeSpaceAccess([:])
        spaceAccess.mapSpaceError = SpaceSyncMappingError.persistFailed
        let spaceStore = drainedSpaceStore()
        let markerStore = markerStore(marker: "0")
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([spaceCreateEntity("sync-new", version: 3)], marker: "3")]
        let engine = makeOwnedEngine(client: client, markerStore: markerStore,
                                     spaceStore: spaceStore, spaceAccess: spaceAccess)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let outcome = await engine.lastRoundOutcomeForTesting
        let advanced = await engine.lastRoundMarkerAdvancedForTesting
        let failures = await engine.lastRoundCursorSaveFailedCountForTesting
        XCTAssertEqual(outcome, .cursorSaveFailed, "The fourth failure site")
        XCTAssertEqual(failures, 1)
        XCTAssertFalse(advanced)
        XCTAssertEqual(markerStore.file.marker, Data("0".utf8), "Disk retains markerAtEntry")
        XCTAssertTrue(spaceAccess.allSpaceMappings().isEmpty, "No mappings")
        XCTAssertTrue(spaceAccess.spaces.isEmpty, "No rows")
        XCTAssertTrue(mintedSpaceIds(spaceAccess, syncUuid: "sync-new").isEmpty, "Throws before recording the call")
        XCTAssertTrue(spaceCreateCalls(spaceAccess).isEmpty, "land was never called")
        XCTAssertNotNil(spaceStore.table.cursors["sync-new"]?.pendingApply, "Parking itself already persisted")
        XCTAssertNil(spaceStore.table.cursors["sync-new"]?.reconciled)
        XCTAssertTrue(spaceCommits(client).isEmpty, "cursorSaveFailed closes the publication gate")

        spaceAccess.mapSpaceError = nil
        await engine.pullOnce()

        let second = await engine.lastRoundOutcomeForTesting
        let secondAdvanced = await engine.lastRoundMarkerAdvancedForTesting
        XCTAssertEqual(client.getUpdatesCalls.last?.marker, Data("0".utf8), "The same marker replays the same page")
        XCTAssertEqual(second, .ok)
        XCTAssertTrue(secondAdvanced)
        XCTAssertEqual(markerStore.file.marker, Data("3".utf8))
        XCTAssertEqual(mintedSpaceIds(spaceAccess, syncUuid: "sync-new").count, 1, "Exactly one mapSpace call")
        XCTAssertEqual(spaceCreateCalls(spaceAccess).count, 1, "Exactly one create: parked and inbound entities are deduplicated")
        XCTAssertEqual(spaceAccess.allSpaceMappings().count, 1, "One mapping")
        XCTAssertEqual(spaceAccess.spaces.count, 1, "One row")
        XCTAssertNotNil(spaceStore.table.cursors["sync-new"]?.reconciled)
        XCTAssertNil(spaceStore.table.cursors["sync-new"]?.pendingApply)
    }
}

private extension PhiSyncEngineTests.FakePhiSyncClient {
    /// Replaying a remote tombstone emits no outbound tombstone: no commit entry has deleted set.
    func commitsAreFreeOfOutboundTombstones() -> Bool {
        !commits.contains { $0.deleted }
    }
}

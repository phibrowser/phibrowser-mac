import XCTest
@testable import Phi

/// Task 3: per-kind cursor tables, atomic JSON storage under the account directory,
/// and four per-kind loss/replay flags on PhiSpaceSyncTable. No MainActor fakes
/// are used: FileOwnedItemStateStore and both structs are unisolated, so the test
/// class remains unannotated like PhiSpaceSyncStateTests.
final class PhiOwnedItemStateTests: XCTestCase {

    /// Use a separate temporary directory per case to observe the real filesystem
    /// and assert paths that must not write anything back.
    private var directory: URL!
    private var fileURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("PhiOwnedItemStateTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Match the production path name: <account.userDataStorage>/sync/bookmarks-cursors.json (§3.5).
        fileURL = directory.appendingPathComponent("sync", isDirectory: true)
            .appendingPathComponent("bookmarks-cursors.json")
    }

    override func tearDownWithError() throws {
        // CASE 2a.7 makes sync/ read-only to force persistence failure. Restore permissions
        // before deleting or undeletable temporary directories accumulate.
        if let fileURL {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: fileURL.deletingLastPathComponent().path)
        }
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        fileURL = nil
        try super.tearDownWithError()
    }

    /// 0o500 permits reads/traversal but blocks the temporary file needed by atomic
    /// writes. The non-root test process makes this failure deterministic.
    private func setCursorDirectoryWritable(_ writable: Bool) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: writable ? 0o700 : 0o500],
            ofItemAtPath: fileURL.deletingLastPathComponent().path)
    }

    private func makeStore() -> FileOwnedItemStateStore {
        FileOwnedItemStateStore(fileURL: fileURL)
    }

    private var fileExists: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    // MARK: - CASE 3.1

    /// CASE 3.1: round-trip all fourteen fields. Partial coverage misses omitted Codable
    /// fields, which can make the engine send baseVersion=0 creates that blindly overwrite
    /// account entities. The field-count assertion requires any fifteenth field to join this test.
    func testEveryCursorFieldSurvivesAFileRoundTrip() throws {
        var cursor = PhiOwnedItemCursor()
        cursor.entityId = "srv-1"
        cursor.version = 4
        cursor.reconciled = Data([0x01])
        cursor.server = Data([0x02])
        cursor.ownerUuid = "su-1"
        cursor.pendingApply = Data([0x03])
        cursor.pendingOwnerUuid = "su-2"
        cursor.pendingTombstone = true
        cursor.pendingPartnerLineage = "LY"
        cursor.pendingDelete = true
        cursor.deleteDecidedAtMs = 77
        cursor.deleteRejectRounds = 2
        cursor.rekeyRejectRounds = 3
        cursor.deletedAtMs = 88

        var table = PhiOwnedItemTable()
        table.cursors["bm-1"] = cursor
        let store = makeStore()
        store.save(table)
        let loaded = store.load(hadRecords: true)

        let fieldCount = Mirror(reflecting: cursor).children.count
        let roundTripped = loaded.table
        let reportedLoss = loaded.reportedLoss
        XCTAssertEqual(fieldCount, 14, "Every new cursor field needs a nondefault value in this test")
        XCTAssertEqual(roundTripped, table)
        XCTAssertEqual(roundTripped.cursors["bm-1"], cursor)
        XCTAssertFalse(reportedLoss, "Readable data is not lost")

        // Also verify persisted key names: synthesized CodingKeys follow property renames,
        // so a round trip alone permits a key change within the same formatVersion and
        // default-decoding every existing cursor's field. Decode literal JSON with fixed
        // keys; Data fields use JSONEncoder's default base64.
        let literal = Data("""
        {
          "entityId": "srv-1",
          "version": 4,
          "reconciled": "AQ==",
          "server": "Ag==",
          "ownerUuid": "su-1",
          "pendingApply": "Aw==",
          "pendingOwnerUuid": "su-2",
          "pendingTombstone": true,
          "pendingPartnerLineage": "LY",
          "pendingDelete": true,
          "deleteDecidedAtMs": 77,
          "deleteRejectRounds": 2,
          "rekeyRejectRounds": 3,
          "deletedAtMs": 88
        }
        """.utf8)

        let fromLiteral = try JSONDecoder().decode(PhiOwnedItemCursor.self, from: literal)

        XCTAssertEqual(fromLiteral, cursor, "All fourteen persisted keys must match this literal exactly")
    }

    /// CASE 3.1b: files written by the previous version remain readable (R-exec-13 / F-PK-2).
    /// Synthesized decoding uses decode for nonoptional properties and throws keyNotFound
    /// even if a property declares a default. Existing JSON contains every nonoptional
    /// field but not newly added ones. Adding a required field could invalidate every
    /// pin/bookmark cursor file, return an empty table with loss, trigger full replay,
    /// and discard every reconciled baseline. This literal matches build 822's keys,
    /// without rekeyRejectRounds; it must decode that field as nil, meaning no rejection streak.
    func testACursorFileFromTheBuildBeforeThisFieldStillDecodes() throws {
        let previousBuild = Data("""
        {
          "formatVersion": 1,
          "cursors": {
            "bm-1": {
              "entityId": "srv-1",
              "version": 4,
              "reconciled": "AQ==",
              "server": "Ag==",
              "ownerUuid": "su-1",
              "pendingTombstone": false,
              "pendingDelete": false,
              "deleteDecidedAtMs": 0,
              "deleteRejectRounds": 0
            }
          }
        }
        """.utf8)

        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try previousBuild.write(to: fileURL, options: .atomic)
        let store = makeStore()
        let loaded = store.load(hadRecords: true)

        XCTAssertFalse(loaded.reportedLoss, "① The previous version's file is not a loss")
        XCTAssertEqual(loaded.table.cursors["bm-1"]?.entityId, "srv-1", "② The baseline and identity/version tuple survive")
        XCTAssertNotNil(loaded.table.cursors["bm-1"]?.reconciled)
        XCTAssertNil(loaded.table.cursors["bm-1"]?.rekeyRejectRounds,
                     "③ A missing key decodes as nil, meaning no rejection streak")
    }

    // MARK: - CASE 3.2

    /// CASE 3.2: the table contains no window state. R-M3-3-28 removed firstArrival,
    /// claimEligible, locallyMinted, and creator_device_id mechanisms; restoring any must fail here.
    func testTheTableCarriesNoFirstMergeWindowState() {
        let names = Set(Mirror(reflecting: PhiOwnedItemTable()).children.compactMap(\.label))

        XCTAssertEqual(names, ["formatVersion", "cursors"])
    }

    // MARK: - CASE 3.3

    /// CASE 3.3: a missing file reports loss only with hadRecords. Before any publication,
    /// no file is expected. Writing an empty file after failed reading would disguise
    /// real loss as a normal empty table and permit blind baseVersion=0 overwrites next round.
    func testAMissingFileReportsLossOnlyWhenTheKindHasPublishedBefore() {
        let store = makeStore()

        let quiet = store.load(hadRecords: false)
        let loud = store.load(hadRecords: true)

        let quietTable = quiet.table
        let quietLoss = quiet.reportedLoss
        let loudTable = loud.table
        let loudLoss = loud.reportedLoss
        let exists = fileExists
        XCTAssertTrue(quietTable.cursors.isEmpty)
        XCTAssertFalse(quietLoss)
        XCTAssertTrue(loudTable.cursors.isEmpty)
        XCTAssertTrue(loudLoss)
        XCTAssertFalse(exists, "A failed read must write nothing back")
    }

    // MARK: - CASE 3.4

    /// CASE 3.4: discard and report loss for an old formatVersion.
    func testATableFromAnOlderFormatVersionIsDroppedAndReported() throws {
        var stale = PhiOwnedItemTable()
        stale.formatVersion = PhiOwnedItemTable.currentFormatVersion - 1
        stale.cursors["bm-1"] = ownedCursor(reconciled: Data([0x01]),
                                            entityId: "srv-1", version: 3)
        let staleBytes = try JSONEncoder().encode(stale)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try staleBytes.write(to: fileURL, options: .atomic)
        let store = makeStore()

        let loud = store.load(hadRecords: true)
        let quiet = store.load(hadRecords: false)

        let loudTable = loud.table
        let loudLoss = loud.reportedLoss
        let quietLoss = quiet.reportedLoss
        let onDisk = try Data(contentsOf: fileURL)
        XCTAssertTrue(loudTable.cursors.isEmpty)
        XCTAssertEqual(loudTable.formatVersion, PhiOwnedItemTable.currentFormatVersion)
        XCTAssertTrue(loudLoss)
        XCTAssertFalse(quietLoss, "reportedLoss depends only on hadRecords")
        XCTAssertEqual(onDisk, staleBytes, "Discarding does not rewrite the file")
    }

    /// CASE 3.4, missing formatVersion (§3.6 / §12.1: smaller or absent).
    /// Include a real cursor so only the missing format key causes discard. This also
    /// exposes the field-addition trap: synthesized Decodable throws keyNotFound and
    /// does not use property defaults.
    func testATableWithNoFormatVersionKeyIsDroppedAndReported() throws {
        var table = PhiOwnedItemTable()
        table.cursors["bm-1"] = ownedCursor(reconciled: Data([0x01]),
                                            entityId: "srv-1", version: 3)
        let encoded = try JSONEncoder().encode(table)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "formatVersion")
        let bytes = try JSONSerialization.data(withJSONObject: object)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try bytes.write(to: fileURL, options: .atomic)
        let store = makeStore()

        let loud = store.load(hadRecords: true)
        let quiet = store.load(hadRecords: false)

        let loudTable = loud.table
        let loudLoss = loud.reportedLoss
        let quietLoss = quiet.reportedLoss
        let onDisk = try Data(contentsOf: fileURL)
        XCTAssertTrue(loudTable.cursors.isEmpty)
        XCTAssertTrue(loudLoss)
        XCTAssertFalse(quietLoss)
        XCTAssertEqual(onDisk, bytes, "A missing key must not cause a file rewrite")
    }

    // MARK: - CASE 3.5

    /// CASE 3.5: discard and report loss for undecodable bytes.
    func testUndecodableBytesAreDroppedAndReported() throws {
        let garbage = Data("{ not json".utf8)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try garbage.write(to: fileURL, options: .atomic)
        let store = makeStore()

        let loud = store.load(hadRecords: true)
        let quiet = store.load(hadRecords: false)

        let loudTable = loud.table
        let loudLoss = loud.reportedLoss
        let quietTable = quiet.table
        let quietLoss = quiet.reportedLoss
        let onDisk = try Data(contentsOf: fileURL)
        XCTAssertTrue(loudTable.cursors.isEmpty)
        XCTAssertTrue(loudLoss)
        XCTAssertTrue(quietTable.cursors.isEmpty)
        XCTAssertFalse(quietLoss)
        XCTAssertEqual(onDisk, garbage, "Undecodable data must not be rewritten")
    }

    // MARK: - CASE 3.6

    /// CASE 3.6: an empty table reports loss if this kind has published before.
    func testAnEmptyTableIsALossWhenTheKindHasPublishedBefore() throws {
        let store = makeStore()
        store.save(PhiOwnedItemTable())

        let loud = store.load(hadRecords: true)
        let quiet = store.load(hadRecords: false)

        let loudTable = loud.table
        let loudLoss = loud.reportedLoss
        let quietLoss = quiet.reportedLoss
        XCTAssertTrue(loudTable.cursors.isEmpty)
        XCTAssertTrue(loudLoss)
        XCTAssertFalse(quietLoss)
    }

    /// CASE 3.6 fake parity: MemoryOwnedItemStore must make the same loss decision.
    /// Otherwise Task 6/9 tests with an empty table and bookmarksHadRecords=true pass
    /// as normal rounds while production reports loss and replays the entire type.
    func testTheMemoryStoreReportsTheSameLossAsTheFileStore() {
        let store = MemoryOwnedItemStore()

        let loud = store.load(hadRecords: true)
        let quiet = store.load(hadRecords: false)

        let loudTable = loud.table
        let loudLoss = loud.reportedLoss
        let quietLoss = quiet.reportedLoss
        let seen = store.hadRecordsSeen
        XCTAssertTrue(loudTable.cursors.isEmpty)
        XCTAssertTrue(loudLoss)
        XCTAssertFalse(quietLoss)
        XCTAssertEqual(seen, [true, false])

        // A nonempty table without scripted loss loads normally without reporting loss.
        var table = PhiOwnedItemTable()
        table.cursors["bm-1"] = ownedCursor(reconciled: Data([0x01]), entityId: "srv-1")
        store.save(table)

        let healthy = store.load(hadRecords: true)

        let healthyTable = healthy.table
        let healthyLoss = healthy.reportedLoss
        XCTAssertEqual(healthyTable, table)
        XCTAssertFalse(healthyLoss)
    }

    // MARK: - CASE 3.7

    /// CASE 3.7: loss detection is independent of local rows and syncId. Pins have
    /// no syncId column, so checking for rows with syncId would never detect pin loss;
    /// losing pins-cursors.json would then cause blind baseVersion=0 overwrites of every account pin.
    func testLossReportingFollowsOnlyTheFlagItIsGiven() {
        let store = makeStore()
        store.save(PhiOwnedItemTable())

        let first = store.load(hadRecords: true)
        let second = store.load(hadRecords: false)
        let third = store.load(hadRecords: true)

        let firstLoss = first.reportedLoss
        let secondLoss = second.reportedLoss
        let thirdLoss = third.reportedLoss
        XCTAssertTrue(firstLoss)
        XCTAssertFalse(secondLoss, "Only the input changed; store and bytes are identical")
        XCTAssertTrue(thirdLoss, "Loss reporting has no report-once memory")
    }

    // MARK: - CASE 3.8

    /// CASE 3.8: atomic save always leaves a complete table on disk.
    func testSaveLandsOneCompleteTable() throws {
        var table = PhiOwnedItemTable()
        table.cursors["bm-1"] = ownedCursor(reconciled: Data([0x01]),
                                            entityId: "srv-1", version: 2)
        table.cursors["bm-2"] = ownedCursor(server: Data([0x02]),
                                            entityId: "srv-2", version: 3,
                                            ownerUuid: "su-1")
        let store = makeStore()

        store.save(table)

        let bytes = try Data(contentsOf: fileURL)
        let decoded = try JSONDecoder().decode(PhiOwnedItemTable.self, from: bytes)
        XCTAssertEqual(decoded, table)
    }

    // MARK: - CASE 3.9

    /// CASE 3.9: load returns an empty table after deleteFile; §9.1 self-revoke deletes the file directly.
    func testDeleteFileLeavesTheNextLoadWithAnEmptyTable() {
        var table = PhiOwnedItemTable()
        table.cursors["bm-1"] = ownedCursor(reconciled: Data([0x01]), entityId: "srv-1")
        let store = makeStore()
        store.save(table)

        store.deleteFile()

        let loaded = store.load(hadRecords: true)
        let cursors = loaded.table.cursors
        let exists = fileExists
        XCTAssertTrue(cursors.isEmpty)
        XCTAssertFalse(exists)
    }

    // MARK: - CASE 3.10

    /// CASE 3.10: the 30-day window drops only expired tombstone cursors.
    /// Set now one millisecond after the old tombstone expires: deletedAtMs=1 expires,
    /// while one finalized 999 ms later remains. Live cursors never participate.
    func testOnlyExpiredTombstoneCursorsAreDropped() {
        var table = PhiOwnedItemTable()
        table.cursors["live"] = ownedCursor(reconciled: Data([0x01]),
                                            entityId: "srv-1", version: 2)
        var recent = ownedCursor(entityId: "srv-2", version: 3)
        recent.deletedAtMs = 1_000
        table.cursors["recent-tombstone"] = recent
        var old = ownedCursor(entityId: "srv-3", version: 4)
        old.deletedAtMs = 1
        table.cursors["old-tombstone"] = old

        table.dropExpiredTombstones(nowMs: 1 + PhiSpaceSyncState.retentionMs + 1)

        let keys = Set(table.cursors.keys)
        XCTAssertEqual(keys, ["live", "recent-tombstone"])
    }

    // MARK: - CASE 3.11

    /// CASE 3.11: per-kind flags are independent of the permanent Space latch.
    /// Reusing didReplayForEmptyTable after the Space section consumes it would deny
    /// bookmarks or pins any replay after their first file loss.
    func testThePerKindReplayFlagsAreIndependentOfTheSpaceLatch() {
        var table = PhiSpaceSyncTable()

        table.didReplayForEmptyTable = true

        let spaceLatch = table.didReplayForEmptyTable
        let bookmarksHad = table.bookmarksHadRecords
        let pinsHad = table.pinsHadRecords
        let bookmarksReplayed = table.bookmarksReplayedForEmptyTable
        let pinsReplayed = table.pinsReplayedForEmptyTable
        XCTAssertTrue(spaceLatch)
        XCTAssertFalse(bookmarksHad)
        XCTAssertFalse(pinsHad)
        XCTAssertFalse(bookmarksReplayed)
        XCTAssertFalse(pinsReplayed)
    }

    /// Also verify both OwnedKindFlags registrations independently read and write their own pair.
    func testOwnedKindFlagsAddressOnePairEach() {
        var table = PhiSpaceSyncTable()

        table[keyPath: OwnedKindFlags.bookmarks.hadRecords] = true
        table[keyPath: OwnedKindFlags.pins.replayedForEmptyTable] = true

        let bookmarksHad = table.bookmarksHadRecords
        let pinsHad = table.pinsHadRecords
        let bookmarksReplayed = table.bookmarksReplayedForEmptyTable
        let pinsReplayed = table.pinsReplayedForEmptyTable
        XCTAssertTrue(bookmarksHad)
        XCTAssertFalse(pinsHad)
        XCTAssertFalse(bookmarksReplayed)
        XCTAssertTrue(pinsReplayed)
    }

    // MARK: - CASE 3.12

    /// CASE 3.12: account-scoped marker/replay state shared by all kinds.
    /// Enrollment acknowledgement belongs beside its replay latch, never in a per-kind file.
    func testTheSharedMarkerStateIsAccountScoped() {
        let all = Set(Mirror(reflecting: PhiSpaceSyncTable()).children.compactMap(\.label))

        let marker = all.subtracting(["formatVersion", "cursors"])

        XCTAssertEqual(marker, [
            "drainInProgress",
            "hasDrainedFullReplay",
            "hadRecords",
            "spaceSectionEnabled",
            "markerMovedWhileGateShut",
            "lastEnrollmentReplayToken",
            "didReplayForEmptyTable",
            "lastDrainedBirthday",
            "unreadableTagHashes",
            "bookmarksHadRecords",
            "pinsHadRecords",
            "bookmarksReplayedForEmptyTable",
            "pinsReplayedForEmptyTable",
            "urlRulesHadRecords",
            "urlRulesReplayedForEmptyTable",
        ])
    }

    // MARK: - CASE 2a.7（R-M3-4a-83）

    /// CASE 2a.7: FileOwnedItemStateStore.save returns false in an unwritable directory
    /// and preserves the file. A catch that forgets false keeps cursorSaveFailed false,
    /// invalidating B-2 for all three JSON files. Also preserve §11.4's no-retry contract:
    /// one returned failure, no partial retry queue, and the previous complete table intact.
    func testAFailedCursorSaveReportsItAndLeavesTheFileUntouched() throws {
        let store = makeStore()
        var tableA = PhiOwnedItemTable()
        var cursorA = PhiOwnedItemCursor()
        cursorA.entityId = "srv-a"
        cursorA.version = 4
        cursorA.reconciled = Data([0x01])
        tableA.cursors["b1"] = cursorA
        XCTAssertTrue(store.save(tableA), "A successful write returns true")
        let bytesAfterA = try Data(contentsOf: fileURL).count

        var tableB = PhiOwnedItemTable()
        var cursorB = PhiOwnedItemCursor()
        cursorB.entityId = "srv-b"
        cursorB.version = 9
        cursorB.reconciled = Data([0x02, 0x03])
        tableB.cursors["b2"] = cursorB

        try setCursorDirectoryWritable(false)
        XCTAssertFalse(store.save(tableB), "A failed disk write returns false")

        try setCursorDirectoryWritable(true)
        let reloaded = store.load(hadRecords: true)
        XCTAssertEqual(reloaded.table, tableA, "The previous complete table remains on disk")
        XCTAssertFalse(reloaded.reportedLoss, "Readable data is not lost")
        XCTAssertEqual(try Data(contentsOf: fileURL).count, bytesAfterA,
                       "The failed attempt wrote no bytes")
    }

    // MARK: - CASE M-31: removeCursor file round trip (8b-1)

    /// Replacing a removed cursor with an empty PhiOwnedItemCursor would leave entityId
    /// empty and reconciled nil, repeatedly triggering key completion and §4.2 step 3b
    /// while the local row belongs to another identity: one orphan publication per round.
    /// reportedLoss=false also proves removing one cursor is not loss of the whole table.
    func testRemoveCursorDropsTheWholeEntryAndSurvivesAFileRoundTrip() throws {
        var table = PhiOwnedItemTable()
        var old = PhiOwnedItemCursor()
        old.ownerUuid = "su-1"
        table.cursors["old"] = old
        var fresh = PhiOwnedItemCursor()
        fresh.entityId = "srv-new"
        fresh.version = 7
        fresh.reconciled = Data([0x01, 0x02])
        fresh.server = Data([0x01, 0x02])
        fresh.ownerUuid = "su-1"
        table.cursors["new"] = fresh
        let formatVersion = table.formatVersion

        table.removeCursor(identity: "old")
        XCTAssertNil(table.cursors["old"], "The cursor is absent, not an empty cursor")
        XCTAssertEqual(table.cursors.count, 1)
        XCTAssertTrue(makeStore().save(table))

        let reloaded = makeStore().load(hadRecords: true)
        XCTAssertNil(reloaded.table.cursors["old"])
        XCTAssertEqual(reloaded.table.cursors["new"], fresh, "Every field matches")
        XCTAssertFalse(reloaded.reportedLoss)
        XCTAssertEqual(reloaded.table.formatVersion, formatVersion)

        // Idempotence: removing a missing identity leaves the table unchanged.
        var untouched = reloaded.table
        untouched.removeCursor(identity: "missing")
        XCTAssertEqual(untouched, reloaded.table)
    }
}

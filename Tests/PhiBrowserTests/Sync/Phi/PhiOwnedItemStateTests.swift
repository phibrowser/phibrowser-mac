import XCTest
@testable import Phi

/// Task 3 的用例：per-kind 的游标表、它在账户目录下的原子 JSON 文件存储，以及住在
/// `PhiSpaceSyncTable` 上的四个 per-kind 报损 / 重放标志。
///
/// 这个类一个 `@MainActor` 假件都不用（`FileOwnedItemStateStore` 与两个 struct 都不是
/// 隔离类型），所以整类不标注——形状照同样不标注的 `PhiSpaceSyncStateTests`。
final class PhiOwnedItemStateTests: XCTestCase {

    /// 每条用例一个独立的临时目录：文件存储的契约里有「这一路一个字节都不许写回去」，
    /// 断言它就必须能看到真实的文件系统状态。
    private var directory: URL!
    private var fileURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("PhiOwnedItemStateTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // 名字与生产落点同款（§3.5：`<account.userDataStorage>/sync/bookmarks-cursors.json`）。
        fileURL = directory.appendingPathComponent("sync", isDirectory: true)
            .appendingPathComponent("bookmarks-cursors.json")
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        fileURL = nil
        try super.tearDownWithError()
    }

    private func makeStore() -> FileOwnedItemStateStore {
        FileOwnedItemStateStore(fileURL: fileURL)
    }

    private var fileExists: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    // MARK: - CASE 3.1

    /// CASE 3.1 — 十三个字段全部往返。
    ///
    /// 防的是什么：只钉住一部分字段的往返用例会放过一条被漏掉的 `Codable` 字段，而漏掉
    /// 任何一条都让引擎对一条实体做出错误判断；错误的方向是「发一条 `baseVersion == 0`
    /// 的 create 把账户上那条盲写覆盖」。字段数断言让加第十四个字段的人必须回到这里。
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
        cursor.deletedAtMs = 88

        var table = PhiOwnedItemTable()
        table.cursors["bm-1"] = cursor
        let store = makeStore()
        store.save(table)
        let loaded = store.load(hadRecords: true)

        let fieldCount = Mirror(reflecting: cursor).children.count
        let roundTripped = loaded.table
        let reportedLoss = loaded.reportedLoss
        XCTAssertEqual(fieldCount, 13, "新增一个游标字段必须同时在这条用例里赋非默认值")
        XCTAssertEqual(roundTripped, table)
        XCTAssertEqual(roundTripped.cursors["bm-1"], cursor)
        XCTAssertFalse(reportedLoss, "读得出来就不是丢失")
    }

    // MARK: - CASE 3.2

    /// CASE 3.2 — 表里没有任何窗口状态。
    ///
    /// 防的是什么：R-M3-3-28 撤回了 `firstArrival` / `claimEligible` / `locallyMinted`
    /// 与 `creator_device_id` 那几套机制；把其中任何一个加回来的人在这里红。
    func testTheTableCarriesNoFirstMergeWindowState() {
        let names = Set(Mirror(reflecting: PhiOwnedItemTable()).children.compactMap(\.label))

        XCTAssertEqual(names, ["formatVersion", "cursors"])
    }

    // MARK: - CASE 3.3

    /// CASE 3.3 — 文件不存在时只有 `hadRecords` 才报损。
    ///
    /// 防的是什么：从未发布过任何东西 ⇒ 文件本来就不该存在，这不是丢失。而「读不出来
    /// 顺手写一个空文件回去」会把一次真正的丢失变成一张「正常的空表」，下一轮就以
    /// `baseVersion == 0` 的 create 盲写覆盖账户。
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
        XCTAssertFalse(exists, "读不出来的那一路一个字节都不许写回去")
    }

    // MARK: - CASE 3.4

    /// CASE 3.4 — `formatVersion` 偏低 ⇒ 丢弃并报损。
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
        XCTAssertFalse(quietLoss, "`reportedLoss` 只随 `hadRecords` 变")
        XCTAssertEqual(onDisk, staleBytes, "丢弃那一路不写回文件")
    }

    // MARK: - CASE 3.5

    /// CASE 3.5 — 字节解不开 ⇒ 丢弃并报损。
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
        XCTAssertEqual(onDisk, garbage, "解不开那一路不写回文件")
    }

    // MARK: - CASE 3.6

    /// CASE 3.6 — 表为空但该 kind 发布过 ⇒ 报损。
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

    // MARK: - CASE 3.7

    /// CASE 3.7 — 报损判据与本地行、与 `syncId` 无关。
    ///
    /// 防的是什么：pin 根本没有 `syncId` 这一列，按「名下还有没有带 `syncId` 的行」写的
    /// 判据对 pin 恒不触发，于是丢掉 `pins-cursors.json` 什么都不发生，下一轮就把账户里
    /// 每一条 pin 用 `baseVersion == 0` 的 create 盲写覆盖。
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
        XCTAssertFalse(secondLoss, "同一个 store、同一份字节，只有入参变了")
        XCTAssertTrue(thirdLoss, "判据没有「只报一次」这种记忆")
    }

    // MARK: - CASE 3.8

    /// CASE 3.8 — `save` 是原子的：落盘的永远是一份完整的表。
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

    /// CASE 3.9 — `deleteFile` 之后 `load` 是空表（§9.1 的自撤销直接删文件）。
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

    /// CASE 3.10 — 30 天窗口只丢过期的 tombstone 游标。
    ///
    /// `nowMs` 取「旧 tombstone 的到期时刻再加 1 ms」：`deletedAtMs = 1` 的那条刚好过期，
    /// 999 ms 之后才定案的那条还在窗口里，活游标（没有 `deletedAtMs`）永远不参与。
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

    /// CASE 3.11 — per-kind 标志与 Space 的那个永久闩独立。
    ///
    /// 防的是什么：复用 Space 侧的 `didReplayForEmptyTable`，会在 Space 段先花掉它之后，
    /// 让书签或 pin 的第一次文件丢失**一次重放都得不到**。
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

    /// 同一条用例的另一半：`OwnedKindFlags` 的两条注册项各自读写自己那一对，互不串线。
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

    /// CASE 3.12 — 共享 marker 状态的字段集合。
    ///
    /// 防的是什么：加第十三个字段的人必须先读那段注释——这些字段**四种 kind 共用**，
    /// 一份都不得复制进 per-kind 的文件里。
    func testTheSharedMarkerStateIsExactlyTheseTwelveFields() {
        let all = Set(Mirror(reflecting: PhiSpaceSyncTable()).children.compactMap(\.label))

        let marker = all.subtracting(["formatVersion", "cursors"])

        XCTAssertEqual(marker, [
            "drainInProgress",
            "hasDrainedFullReplay",
            "hadRecords",
            "spaceSectionEnabled",
            "markerMovedWhileGateShut",
            "didReplayForEmptyTable",
            "lastDrainedBirthday",
            "unreadableTagHashes",
            "bookmarksHadRecords",
            "pinsHadRecords",
            "bookmarksReplayedForEmptyTable",
            "pinsReplayedForEmptyTable",
        ])
    }
}

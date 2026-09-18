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
        // CASE 2a.7 把 `sync/` 改成只读来注入落盘失败；**先恢复权限再删**，否则只读目录
        // 删不掉，临时目录会一次次累积下来。
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

    /// `0o500` = 可读可进入、**不可写**：`.atomic` 写要在同目录建临时文件，于是必然失败。
    /// **测试进程不是 root**，所以这个注入是确定的。
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

    /// CASE 3.1 — 十四个字段全部往返。
    ///
    /// 防的是什么：只钉住一部分字段的往返用例会放过一条被漏掉的 `Codable` 字段，而漏掉
    /// 任何一条都让引擎对一条实体做出错误判断；错误的方向是「发一条 `baseVersion == 0`
    /// 的 create 把账户上那条盲写覆盖」。字段数断言让加第十五个字段的人必须回到这里。
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
        XCTAssertEqual(fieldCount, 14, "新增一个游标字段必须同时在这条用例里赋非默认值")
        XCTAssertEqual(roundTripped, table)
        XCTAssertEqual(roundTripped.cursors["bm-1"], cursor)
        XCTAssertFalse(reportedLoss, "读得出来就不是丢失")

        // 同一条用例的第二半：**盘上的键名**。往返断言钉不住改名——合成的 `CodingKeys` 跟着
        // 属性名走，改一个属性名就在同一个 `formatVersion` 下悄悄换掉盘上的键，那个字段的
        // 每条游标都解成默认值。所以这里解一份写死键名的 JSON。`Data` 字段是
        // `JSONEncoder` 默认的 base64。
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

        XCTAssertEqual(fromLiteral, cursor, "十四个盘上键名必须与这份字面量逐字一致")
    }

    /// CASE 3.1b — **上一版落盘的文件仍然读得出来**（R-exec-13 / F-PK-2）。
    ///
    /// 防的是什么：合成的 `init(from:)` 对一条**非可选**属性调的是 `decode(_:forKey:)`，缺键
    /// 就抛 `keyNotFound`——属性上写没写默认值都一样。而 `JSONEncoder` 只省略值为 nil 的可选
    /// 字段，所以线上那些文件里每一个非可选字段都在、后加的那个不在。于是给这个结构体加一条
    /// **非可选**字段 = 每一台已有设备的 `pins-cursors.json` / `bookmarks-cursors.json` 整份
    /// 解不开 = `load` 交出空表并报损 = 整类型重放 + 每一份 `reconciled` 基线当场丢失。
    ///
    /// 这份字面量就是 build 822 真机上那份文件的键集（少了 `rekeyRejectRounds`）。它必须解得
    /// 出来，并且解出 `nil`（= 没有连败）。
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

        XCTAssertFalse(loaded.reportedLoss, "① 上一版的文件不是一次丢失")
        XCTAssertEqual(loaded.table.cursors["bm-1"]?.entityId, "srv-1", "② 基线与三元组都还在")
        XCTAssertNotNil(loaded.table.cursors["bm-1"]?.reconciled)
        XCTAssertNil(loaded.table.cursors["bm-1"]?.rekeyRejectRounds,
                     "③ 缺键解成 nil，与「没有连败」同义")
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

    /// CASE 3.4 的另一半：`formatVersion` **缺失**（§3.6 / §12.1 的「更小**或缺失**」）。
    ///
    /// 表里带着一条真游标，所以这条用例只可能因为「没有 `formatVersion` 这个键」而丢弃——
    /// 而这正是 per-kind 表将来加字段时最可能踩的那个机制（合成的 `Decodable` 对缺席的键
    /// 抛 `keyNotFound`，属性默认值不参与）。
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
        XCTAssertEqual(onDisk, bytes, "缺键那一路也不写回文件")
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

    /// CASE 3.6 的假件对照：`MemoryOwnedItemStore` 在同一处必须给出同一个答案。
    ///
    /// 防的是什么：两边的报损判据一旦分家，一条拿着空表、`bookmarksHadRecords == true` 的
    /// Task 6 / 9 用例会在「正常一轮、什么都没丢」上变绿，而线上代码在同一处报损并重放
    /// 整个 data type——假件把真实行为盖住了，方向还正好是放过它。
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

        // 非空表、没有脚本化的丢失 ⇒ 照常读回原表，一次报损都没有。
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

    // MARK: - CASE 2a.7（R-M3-4a-83）

    /// CASE 2a.7 — `FileOwnedItemStateStore.save` 在不可写目录上回 `false` 且**不动文件**。
    ///
    /// 防的是什么：catch 分支忘了 `return false`、或者写成 `return true` 的实现——它让
    /// Task 2b 的 `cursorSaveFailed` 永远为假，B-2 的整条保证在三个 JSON 文件上归零。
    /// 同时钉住「写失败**不重试**」（§11.4）仍然成立：没有半截的重试队列，只有一个回传，
    /// 上一份完整的表原封不动留在盘上。
    func testAFailedCursorSaveReportsItAndLeavesTheFileUntouched() throws {
        let store = makeStore()
        var tableA = PhiOwnedItemTable()
        var cursorA = PhiOwnedItemCursor()
        cursorA.entityId = "srv-a"
        cursorA.version = 4
        cursorA.reconciled = Data([0x01])
        tableA.cursors["b1"] = cursorA
        XCTAssertTrue(store.save(tableA), "一次成功的写回 true")
        let bytesAfterA = try Data(contentsOf: fileURL).count

        var tableB = PhiOwnedItemTable()
        var cursorB = PhiOwnedItemCursor()
        cursorB.entityId = "srv-b"
        cursorB.version = 9
        cursorB.reconciled = Data([0x02, 0x03])
        tableB.cursors["b2"] = cursorB

        try setCursorDirectoryWritable(false)
        XCTAssertFalse(store.save(tableB), "写盘失败 ⇒ false")

        try setCursorDirectoryWritable(true)
        let reloaded = store.load(hadRecords: true)
        XCTAssertEqual(reloaded.table, tableA, "盘上仍然是上一份完整的表")
        XCTAssertFalse(reloaded.reportedLoss, "读得出来就不是丢失")
        XCTAssertEqual(try Data(contentsOf: fileURL).count, bytesAfterA,
                       "失败那一次一个字节都没写出去")
    }
}

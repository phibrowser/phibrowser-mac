import CryptoKit
import Foundation
import XCTest
@testable import Phi

/// B-2「marker 边界」那一组用例的宿主。
///
/// **本文件在 Task 2a 里只放 B2-4d / B2-10 / B2-18 三条的 *store 半边*。** 每一条的另一半
/// ——轮次里的结局行（`outcome=cursor_save_failed`）、「本页不推 marker」、「跳过 push 段」
/// ——都要等 Task 2b 的逐页边界与 `cursorSaveFailed` 落地，本文件里一条都不断言它们。
/// B2-1 … B2-17 由 Task 2b / 3 / 3b 续写**同一个文件**。
///
/// **Task 3 追加**：`marker.json`（§2.10 / R-M3-4a-18）的 B2-11a…d 与 CASE 3.1 / 3.3 / 3.4 /
/// 3.5。CASE 3.2（自撤销多删一次 `marker.json`）住在 `SelfRevokeTests`——它要一个完整的
/// `SyncKeyController` 脚手架，只有那里有。
///
/// 两条本任务写下、但住在别处的半边（写在有现成脚手架的地方，不在这里复制一份）：
///
/// - **B2-18 变体 (b)**（`MemorySpaceStore` + `failNextSave` 下 `localSpaceIdLookup` 零调用）
///   = `PhiSyncEngineSpaceTests.testAFailedSpaceTableWriteSkipsTheMainActorCacheRefresh`
///   （CASE 2a.9，带正向对照）。
/// - **B2-18 变体 (c)**（真 `AccountSpaceSyncMappingStore` 上的懒铸造抛 `persistFailed`）
///   = `SpaceSyncMappingManagerTests.testLazyMintingOnARealStoreLeavesNoTraceWhenThePlistWriteFails`。
///
/// 假件都是 `@MainActor` 的（`SpaceSyncMappingManager` 也是），所以整类标注。
@MainActor
final class PhiSyncMarkerBoundaryTests: XCTestCase {
    typealias FakePhiSyncClient = PhiSyncEngineTests.FakePhiSyncClient
    typealias StubDomainKeys = PhiSyncEngineTests.StubDomainKeys
    typealias MemorySpaceStore = PhiSyncEngineSpaceTests.MemorySpaceStore
    typealias MemorySpaceMappingStore = SpaceSyncMappingManagerTests.MemorySpaceMappingStore
    /// 让一轮停在 `getUpdates` 里的一次性闸门（CASE 3.5A）。复用 `PhiSyncEngineTests` 的。
    typealias Gate = PhiSyncEngineTests.Gate

    private var defaults: UserDefaults!
    private var suiteName: String!
    private let key = SymmetricKey(size: .bits256)
    private var scratchAccounts: [Account] = []
    /// `FilePhiSyncMarkerStore` 用例各自的临时目录，`tearDown` 里删。
    private var scratchDirectories: [URL] = []

    /// 本地 spaceId 是 `UUID().uuidString`（大写，SpaceManager.swift），syncUuid 一律小写。
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
            // **先恢复权限再删**：只读目录删不掉，残留会一次次累积。
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

    /// 一个空的临时目录（**不预建** `marker.json`：文件不存在正是 B2-11a / B2-11d(i) 的
    /// 起点）。
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

    /// 形状照 `PhiSyncEngineSpaceTests.makeEngine`，多传 `markerStore:`。`settings: []`
    /// 的理由同那里：不让生产注册表在一个一次性的 suite 上提交真实的设置实体。
    private func makeEngine(client: FakePhiSyncClient,
                            markerStore: any PhiSyncMarkerStore,
                            spaceStore: MemorySpaceStore = MemorySpaceStore()) -> PhiSyncEngine {
        PhiSyncEngine(domainKeys: StubDomainKeys(key: key), client: client,
                      defaults: defaults, deviceKeyId: "devA", settings: [],
                      spaceAccess: makeSpaceAccess(), spaceStore: spaceStore,
                      markerStore: markerStore,
                      now: { 1_700_000_000_000 })
    }

    private func makeAccount() -> Account {
        let account = Account(userID: UUID().uuidString)
        scratchAccounts.append(account)
        // `userDefaults` 是 lazy：这一次访问才真正建出 `defaults/` 目录。
        _ = account.userDefaults
        return account
    }

    /// `0o500` = 可读可进入、**不可写**：`.atomic` 写要在同目录建临时文件，于是必然失败。
    /// **测试进程不是 root**，所以这个注入是确定的；内存假件覆盖不到真实的 `persistLocked`
    /// 失败，而 B2-18 要验的恰恰是它。
    private static func setDefaultsDirectoryWritable(_ writable: Bool, for account: Account) throws {
        let directory = account.userDataStorage
            .appendingPathComponent("defaults", isDirectory: true)
        try FileManager.default.setAttributes([.posixPermissions: writable ? 0o700 : 0o500],
                                              ofItemAtPath: directory.path)
    }

    private func setWritable(_ writable: Bool, for account: Account) throws {
        try Self.setDefaultsDirectoryWritable(writable, for: account)
    }

    /// 一台已经配过对的机器：Space 映射齐备，profile 双向映射齐备。形状照
    /// `PhiSyncEngineOwnedItemsTests.makeSpaceAccess`（那一份是 `private`）。
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

    // MARK: - CASE B2-4d（store 半边）

    /// CASE B2-4d — `setSyncUuid` 失败经 `SpaceSyncMappingManager` 抛 `persistFailed`。
    ///
    /// 三个入口（铸造 / 认领 / 懒铸造）各一份 store，三条都必须抛，而且**抛完不留痕迹**：
    /// store 已经把内存回滚回写之前那一份，所以 `syncUuid(forSpaceId:)` 与
    /// `localSpaceId(forSyncUuid:)` 都查不到这条映射。
    ///
    /// 防的是什么：§2.5 第 2 条的整条。吞掉失败会在内存里留下一个**从没落盘**的 uuid，
    /// 本轮 `pushSpaces` 拿它发布，重启后映射消失、下一轮再铸一个新的 ⇒ **同一个本机
    /// Space 在账户上占两条**，而映射一旦写下没有任何 UI 能撤。
    ///
    /// 交给 Task 2b 的那一半：引擎轮次里 `applySpaces` 的 `mapSpace(...)` 进既有 catch、
    /// `outcome=cursor_save_failed`、marker 不推、重投同一页之后「账户上不多出第二条
    /// Space」——旋钮是既有的 `FakePhiSpaceAccess.errorOnNextMapping`。
    func testEveryMappingEntryThrowsPersistFailedAndLeavesNoTrace() throws {
        // (a) 铸造
        let mintStore = MemorySpaceMappingStore()
        mintStore.failNextSet = true
        let mintKeys = SpaceSyncMappingManager(store: mintStore)
        XCTAssertThrowsError(try mintKeys.mintSyncUuid(forSpaceId: localId)) { error in
            XCTAssertEqual(error as? SpaceSyncMappingError, .persistFailed)
        }
        XCTAssertEqual(mintStore.map, [:], "抛出之后不留痕迹")
        XCTAssertNil(mintKeys.syncUuid(forSpaceId: localId))
        XCTAssertEqual(mintStore.setCalls, 1, "只试了一次，没有内部重试")

        // (b) 认领
        let mapStore = MemorySpaceMappingStore()
        mapStore.failNextSet = true
        let mapKeys = SpaceSyncMappingManager(store: mapStore)
        XCTAssertThrowsError(try mapKeys.map(spaceId: localId, toSyncUuid: "sync-x")) { error in
            XCTAssertEqual(error as? SpaceSyncMappingError, .persistFailed)
        }
        XCTAssertEqual(mapStore.map, [:])
        XCTAssertNil(mapKeys.syncUuid(forSpaceId: localId))
        XCTAssertNil(mapKeys.localSpaceId(forSyncUuid: "sync-x"), "反查同样解析不出")
        XCTAssertEqual(mapStore.setCalls, 1)

        // (c) 懒铸造（`ensureMapped` 一行不改，抛错经 `mintSyncUuid` 继承）
        let ensureStore = MemorySpaceMappingStore()
        ensureStore.failNextSet = true
        let ensureKeys = SpaceSyncMappingManager(store: ensureStore)
        XCTAssertThrowsError(try ensureKeys.ensureMapped(spaceId: localId)) { error in
            XCTAssertEqual(error as? SpaceSyncMappingError, .persistFailed)
        }
        XCTAssertEqual(ensureStore.map, [:])
        XCTAssertNil(ensureKeys.syncUuid(forSpaceId: localId))
        XCTAssertEqual(ensureStore.setCalls, 1)

        // 放行之后重来一次，三条全部成功。
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

    // MARK: - CASE B2-10（store 半边）

    /// CASE B2-10 — `…HadRecords` 不被一次**失败**的 save 提前置真。
    ///
    /// 防的是什么：§2.5 第 7 条。`…HadRecords` 的含义是「这台机器曾经为该 kind **写下过**
    /// 一条带 `entityId` 的游标」。一次没落盘的写提前置真，会让下一次真正的文件丢失被
    /// `load(hadRecords:)` 读成「本来就是空的」而拿不到整类型重放——而那次重放是唯一能把
    /// 账户的书签树重新对齐的机制。
    ///
    /// **`saveCalls` 只断言下界**：`writeOwnedTable` 在一轮 pull 里有不止一个调用点
    /// （落地段一次、发布段至少一次），所以一个精确的整数会把这条用例钉在与它无关的引擎
    /// 结构上。「没有内部重试」这一半由 B2-4d 的 `setCalls == 1` 与
    /// `FileOwnedItemStateStore` 的 CASE 2a.7 各自钉住；精确计数是 Task 2b 的事（它要的
    /// 正是本任务给的 `saveCalls`）。
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
                                   defaults: defaults, deviceKeyId: "devA", settings: [],
                                   spaceAccess: spaceAccess, spaceStore: spaceStore,
                                   ownedKinds: [.bookmarks(access: access, store: ownedStore)],
                                   now: { 1_700_000_000_000 })
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertFalse(spaceStore.table.bookmarksHadRecords,
                       "一次没落盘的写不许把 per-kind 的报损判据花掉")
        XCTAssertGreaterThanOrEqual(ownedStore.saveCalls, 1, "写口确实被调用过")
        XCTAssertTrue(ownedStore.table.cursors.isEmpty, "失败那一次一个游标都没进去")
        XCTAssertEqual(access.rows.count, 1, "落地先于游标：本机书签行已经建出来了")

        // 放行之后重投同一页：这一次 save 成功，标志才该置真。
        ownedStore.failNextSave = false
        client.scriptedPages = [page([
            remoteEntity(envelope(bookmarkPayload(uuid: "b1")),
                         tag: PhiSyncEntity.bookmarkClientTag("b1"),
                         version: 8, entityId: "e1", key: key),
        ], marker: "m2")]
        await engine.pullOnce()

        XCTAssertTrue(spaceStore.table.bookmarksHadRecords,
                      "一次成功的写之后标志才置真")
    }

    // MARK: - CASE B2-18（store 半边）

    /// CASE B2-18 — plist 写失败不得被进程内缓存绕过。
    ///
    /// `MemorySpaceStore` **不够**：要真的经过 `AccountUserDefaults`，因为被验的正是
    /// 「内存回滚」这件事。门关着（`spaceSectionEnabled == false` ⇒
    /// `recordsGatedMarkerMoves == true`），于是一页推进 marker 就写一次 Space 表。
    ///
    /// 防的是什么：「写失败但缓存保留新值」的那一版——第二轮 `loadSpaceTable()` 从进程内
    /// `storage` 读到 `true` ⇒ `mutateSpaceTable` 的 `guard table != before` 当场早退 ⇒
    /// **`save` 根本不被调用**。少了回滚，盘上会落成「marker 已推进、标志缺失」，对
    /// `hasDrainedFullReplay` 已为真的设备，下次开门不重放、门关期间越过的页**永久丢失**。
    ///
    /// 交给 Task 2b 的那一半：第 1 轮 `outcome=cursor_save_failed`、marker 不推；第 2 轮
    /// `save` 调用计数 `== 2`、**只有在它成功之后** `storedMarker` 才推进、
    /// `markerMoveRecorded` 才置真。
    func testAFailedPlistWriteIsNotBypassedByTheInProcessCache() async throws {
        let account = makeAccount()
        let store = AccountPhiSpaceSyncStateStore(defaults: account.userDefaults)
        let client = FakePhiSyncClient()
        client.scriptedPages = [settingsPage(value: "on", version: 10, marker: "m1")]
        let engine = PhiSyncEngine(domainKeys: StubDomainKeys(key: key), client: client,
                                   defaults: defaults, deviceKeyId: "devA", settings: [],
                                   spaceAccess: makeSpaceAccess(), spaceStore: store,
                                   now: { 1_700_000_000_000 })

        try setWritable(false, for: account)
        await engine.pullOnce()
        XCTAssertFalse(store.load().markerMovedWhileGateShut,
                       "回滚可见：写失败之后内存不领先磁盘")

        try setWritable(true, for: account)
        client.scriptedPages = [settingsPage(value: "off", version: 11, marker: "m2")]
        await engine.pullOnce()

        XCTAssertTrue(store.load().markerMovedWhileGateShut, "第二轮**再一次真的写**")
        XCTAssertTrue(
            AccountPhiSpaceSyncStateStore(defaults: AccountUserDefaults(account: account))
                .load().markerMovedWhileGateShut,
            "同一个账户上新建的实例读盘，盘上确实是它")
    }

    /// CASE B2-18 变体 (a) — 第二轮权限仍是 `0o500` ⇒ 盘上与内存都仍是 `false`，
    /// 两轮各试一次、零内部重试。
    func testTwoRoundsAgainstAReadOnlyDirectoryBothLeaveTheFlagFalse() async throws {
        let account = makeAccount()
        let store = AccountPhiSpaceSyncStateStore(defaults: account.userDefaults)
        let client = FakePhiSyncClient()
        client.scriptedPages = [settingsPage(value: "on", version: 10, marker: "m1")]
        let engine = PhiSyncEngine(domainKeys: StubDomainKeys(key: key), client: client,
                                   defaults: defaults, deviceKeyId: "devA", settings: [],
                                   spaceAccess: makeSpaceAccess(), spaceStore: store,
                                   now: { 1_700_000_000_000 })

        try setWritable(false, for: account)
        await engine.pullOnce()
        XCTAssertFalse(store.load().markerMovedWhileGateShut)

        client.scriptedPages = [settingsPage(value: "off", version: 11, marker: "m2")]
        await engine.pullOnce()
        XCTAssertFalse(store.load().markerMovedWhileGateShut, "两轮都失败，内存仍是旧表")

        try setWritable(true, for: account)
        XCTAssertFalse(
            AccountPhiSpaceSyncStateStore(defaults: AccountUserDefaults(account: account))
                .load().markerMovedWhileGateShut,
            "盘上同样是 false——两处从来没有分开过")
    }

    // MARK: - CASE B2-11a…d（`marker.json` 的一次性迁移，§2.10 / R-M3-4a-18）

    /// CASE B2-11a — 两个键在、文件不在 ⇒ 迁进文件、清键；第二次什么都不做。
    ///
    /// 防的是什么：不迁移 ⇒ 每台从 M3-1 升上来的机器的 marker 与 birthday 在升级当刻变成
    /// nil，整个 data type 重放一遍；更要命的是**不清键** ⇒ 同一份状态有两个落点，盘上那一份
    /// 与键那一份从此各走各的，而 R-M3-4a-18 要的「导入天然是一致的一组」只有在键真的没了
    /// 之后才成立。
    func testMigrationMovesBothLegacyKeysIntoTheFileExactlyOnce() throws {
        let store = try makeFileMarkerStore()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        defaults.set(Data("M9".utf8), forKey: PhiSyncEngine.markerStateKey)
        defaults.set("B", forKey: PhiSyncEngine.storeBirthdayStateKey)

        let first = PhiSyncMarkerMigration.migrateLegacyMarker(from: defaults, into: store)
        let second = PhiSyncMarkerMigration.migrateLegacyMarker(from: defaults, into: store)

        XCTAssertTrue(first, "第一次真的迁移了")
        XCTAssertFalse(second, "第二次两个键都空 ⇒ 什么都不做")
        let expected = PhiSyncMarkerFile(formatVersion: 1, marker: Data("M9".utf8), storeBirthday: "B")
        XCTAssertEqual(store.load(), expected)
        XCTAssertNil(defaults.data(forKey: PhiSyncEngine.markerStateKey), "键被清掉")
        XCTAssertNil(defaults.string(forKey: PhiSyncEngine.storeBirthdayStateKey), "键被清掉")
        let bytes = try Data(contentsOf: store.fileURL)
        XCTAssertEqual(try JSONDecoder().decode(PhiSyncMarkerFile.self, from: bytes), expected,
                       "盘上的字节直接解得出同一个值")
    }

    /// CASE B2-11b — 文件里已经有东西 ⇒ 键被**忽略**（不是清理）、一次写都没有。
    ///
    /// 防的是什么：「键在就覆盖文件」会用一个陈旧水位盖掉盘上正确的 marker——要么把已经收过
    /// 的页重收一遍，要么（旧键的水位更高时）**永久跳过**中间那些页；导入之后这一步还会把
    /// 刚刚跟着库一起回退的 marker 又推回去，正是 R-M3-4a-18 要消掉的那个组合。
    func testMigrationIgnoresTheLegacyKeysWhenTheFileAlreadyHasContent() {
        let onDisk = PhiSyncMarkerFile(marker: Data("M-file".utf8), storeBirthday: "B-file")
        let store = MemoryMarkerStore(file: onDisk)
        defaults.set(Data("M-old".utf8), forKey: PhiSyncEngine.markerStateKey)
        defaults.set("B-old", forKey: PhiSyncEngine.storeBirthdayStateKey)

        let migrated = PhiSyncMarkerMigration.migrateLegacyMarker(from: defaults, into: store)

        XCTAssertFalse(migrated)
        XCTAssertTrue(store.saves.isEmpty, "一次写都没有")
        XCTAssertEqual(store.file, onDisk, "文件逐字未变")
        XCTAssertEqual(defaults.data(forKey: PhiSyncEngine.markerStateKey), Data("M-old".utf8),
                       "键仍然在：清理由 §12.2 的重置清单与账户切换的擦除面负责")
        XCTAssertEqual(defaults.string(forKey: PhiSyncEngine.storeBirthdayStateKey), "B-old")
    }

    /// CASE B2-11c — 写失败 ⇒ 键保留、返回 false；下次启动重来一次就成。
    ///
    /// 防的是什么：先清键、再写文件的实现在一次写盘失败之后**两边都空**——marker 与 birthday
    /// 一起蒸发。重放本身安全，但 birthday 丢了意味着下一次 `getUpdates` 带空串，这条路径上
    /// 没有任何机制把它标成异常，问题会以「某台机器每次启动都重放整个 data type」存活很久。
    func testAFailedMigrationWriteKeepsTheLegacyKeysForTheNextLaunch() {
        let store = MemoryMarkerStore()
        store.failSave = true
        defaults.set(Data("M9".utf8), forKey: PhiSyncEngine.markerStateKey)
        defaults.set("B", forKey: PhiSyncEngine.storeBirthdayStateKey)

        XCTAssertFalse(PhiSyncMarkerMigration.migrateLegacyMarker(from: defaults, into: store))
        XCTAssertEqual(defaults.data(forKey: PhiSyncEngine.markerStateKey), Data("M9".utf8),
                       "写失败 ⇒ 不清键")
        XCTAssertEqual(defaults.string(forKey: PhiSyncEngine.storeBirthdayStateKey), "B")
        XCTAssertEqual(store.file, PhiSyncMarkerFile(), "内存假件的失败那一路不改 `file`")

        store.failSave = false
        XCTAssertTrue(PhiSyncMarkerMigration.migrateLegacyMarker(from: defaults, into: store),
                      "下一次启动重来，这一次真的迁移了")
        XCTAssertEqual(store.file, PhiSyncMarkerFile(marker: Data("M9".utf8), storeBirthday: "B"))
        XCTAssertNil(defaults.object(forKey: PhiSyncEngine.markerStateKey))
        XCTAssertNil(defaults.object(forKey: PhiSyncEngine.storeBirthdayStateKey))
    }

    /// CASE B2-11d — 文件缺失 / 解不开 ⇒ `load()` 交回空表且**一个字节都不写回** ⇒ marker
    /// 为 nil ⇒ 下一次 pull 从头重放整个 data type（§10 的自愈路径已武装）。
    ///
    /// 防的是什么：「读不出来就写一张空的回去」会把一次真正的丢失变成一张正常的空表，此后
    /// 再也分辨不出；§10 那条自愈要成立，前提就是 `load` 的失败方向是**空表 + 不写回**。
    func testAMissingOrUndecodableFileReadsAsNoMarkerAndIsNotWrittenBack() async throws {
        // (i) 文件不存在。
        try await assertReplayIsArmed(prepare: { _ in })
        // (ii) 文件里是解不开的字节。
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

        XCTAssertEqual(store.load(), PhiSyncMarkerFile(), "读不出来 ⇒ 空表", file: file, line: line)
        if let undecodableBytes {
            XCTAssertEqual(try Data(contentsOf: store.fileURL), undecodableBytes,
                           "一个字节都不写回", file: file, line: line)
        } else {
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path),
                           "一个字节都不写回", file: file, line: line)
        }

        await engine.pullOnce()

        XCTAssertEqual(client.getUpdatesCalls.count, 1, file: file, line: line)
        XCTAssertNil(client.getUpdatesCalls.first?.marker, "从头重放", file: file, line: line)
        XCTAssertEqual(client.getUpdatesCalls.first?.storeBirthday, "", file: file, line: line)
        let after = store.load()
        XCTAssertNotNil(after.marker, "轮末 marker 落进了文件", file: file, line: line)
        XCTAssertEqual(after.storeBirthday, "birthday-1", file: file, line: line)
    }

    // MARK: - CASE 3.1（三个字段往返）

    /// CASE 3.1 — `formatVersion` / `marker` / `storeBirthday` 三个字段往返，`deleteFile()`
    /// 之后文件不存在、`load()` 交回空表。
    ///
    /// 防的是什么：丢掉 `storeBirthday` 这一半会让 birthday 无处落盘，而 §2.4 说明 1 要它
    /// **逐页**落盘：下一次请求带不上最新 birthday ⇒ `NOT_MY_BIRTHDAY` ⇒
    /// `resetForNewStoreBirthday()` ⇒ 再拉 ⇒ 再 `NOT_MY_BIRTHDAY`，一条死循环。
    func testTheFileRoundTripsAllThreeFields() throws {
        let store = try makeFileMarkerStore()
        let a = PhiSyncMarkerFile(marker: Data([0x00, 0x01, 0xFF]), storeBirthday: "srv-birthday-1")
        let b = PhiSyncMarkerFile()

        XCTAssertTrue(store.save(a))
        let loadedA = store.load()
        XCTAssertEqual(loadedA, a)
        XCTAssertEqual(loadedA.formatVersion, 1)

        XCTAssertTrue(store.save(b))
        XCTAssertEqual(store.load(), b, "空表也是一次真正的写：`marker == nil` 落到了盘上")

        store.deleteFile()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        XCTAssertEqual(store.load(), PhiSyncMarkerFile())
    }

    /// CASE 3.1 的另一半：「没有水位」（`nil`）与「零长度水位」（`Data()`）在 store 这一层
    /// 分得开——`marker` 写成 `Data` 而不是 `Data?` 的实现分不开两者，而前者是重放、后者是
    /// 越过。（引擎的 `storedMarker` setter 把零长度归一化成 nil，那是引擎的事，不是 store 的。）
    func testAZeroLengthMarkerIsNotTheSameAsNoMarkerOnDisk() throws {
        let store = try makeFileMarkerStore()
        XCTAssertTrue(store.save(PhiSyncMarkerFile(marker: Data(), storeBirthday: "b")))
        let loaded = store.load()
        XCTAssertNotNil(loaded.marker)
        XCTAssertEqual(loaded.marker, Data())
        XCTAssertTrue(store.save(PhiSyncMarkerFile(marker: nil, storeBirthday: "b")))
        XCTAssertNil(store.load().marker)
    }

    // MARK: - CASE 3.3（`resetForNewStoreBirthday` 清 marker，birthday 逐页落进同一个文件）

    /// CASE 3.3 — NOT_MY_BIRTHDAY ⇒ 第二次请求带空 birthday、无 marker；轮末两者都在文件
    /// 里，而两个旧键**全程**一个字节都不进 `UserDefaults`。
    ///
    /// 防的是什么：① 把 birthday 留在 `UserDefaults` 而只搬 marker——导入回退库之后两者分居
    /// 两地，§2.4 说明 1 的「birthday 变了 ⇒ marker 作废」靠 `resetForNewStoreBirthday()`
    /// 同时清两者成立。② 把「marker 为 nil」实现成「不写文件」——`clearRemoteCursor()` 的
    /// `storedMarker = nil` 必须真的落到盘上，否则重启之后旧 marker 复活，在一个**新的
    /// store** 上按旧水位要增量。
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
        XCTAssertEqual(client.getUpdatesCalls[0].storeBirthday, "stale-birthday", "读的是注入的文件")
        XCTAssertEqual(client.getUpdatesCalls[0].marker, Data("4".utf8))
        XCTAssertEqual(client.getUpdatesCalls[1].storeBirthday, "")
        XCTAssertNil(client.getUpdatesCalls[1].marker)
        XCTAssertEqual(markerStore.file.storeBirthday, "birthday-1")
        XCTAssertNotNil(markerStore.file.marker)
        XCTAssertTrue(markerStore.saves.contains(PhiSyncMarkerFile()),
                      "`marker == nil` 是一次真正的写，不是「不写文件」")
        XCTAssertNil(defaults.object(forKey: PhiSyncEngine.markerStateKey),
                     "注入了 store 就一个字节都不进 defaults")
        XCTAssertNil(defaults.object(forKey: PhiSyncEngine.storeBirthdayStateKey))
    }

    // MARK: - CASE 3.4（`stateKeys` 收缩）

    /// CASE 3.4 — `stateKeys` 恰好五项，两个 marker 键退出；`legacyMarkerStateKeys` 仍在。
    ///
    /// 防的是什么：收缩没做的实现照样能让其余每一条用例变绿（引擎读的是文件，键顺带被清
    /// 而已），而它留下的是 R-M3-4a-18 判死的那个形状：账户目录被导入整体换掉、`UserDefaults`
    /// 里那一份**不回退**。这条是「收缩真的发生了」的唯一探针。
    func testStateKeysShrankAndTheLegacyKeysStillExist() {
        let expected: Set<String> = [
            PhiSyncEngine.entityIdStateKey, PhiSyncEngine.versionStateKey,
            PhiSyncEngine.lastEntityStateKey, PhiSyncEngine.tombstoneRoundsStateKey,
            PhiSyncEngine.hasAdoptedStateKey,
        ]
        XCTAssertEqual(Set(PhiSyncEngine.stateKeys), expected)
        XCTAssertEqual(PhiSyncEngine.stateKeys.count, 5, "恰好五项，没有重复")
        XCTAssertFalse(PhiSyncEngine.stateKeys.contains(PhiSyncEngine.markerStateKey))
        XCTAssertFalse(PhiSyncEngine.stateKeys.contains(PhiSyncEngine.storeBirthdayStateKey))
        XCTAssertEqual(PhiSyncEngine.legacyMarkerStateKeys,
                       [PhiSyncEngine.storeBirthdayStateKey, PhiSyncEngine.markerStateKey])
        XCTAssertTrue(Set(PhiSyncEngine.stateKeys).isDisjoint(with: PhiSyncEngine.legacyMarkerStateKeys))
    }

    // MARK: - CASE 3.5（退休的引擎不写 marker；换账户擦掉迁移残留）

    /// CASE 3.5A — 一轮停在 `getUpdates` 里时 `shutdown()`，醒来之后 marker 一个字节都不写。
    ///
    /// 防的是什么：`stateKeys` 收缩之后「shutdown 之后没有 state key 被写」那两条既有断言不再
    /// 覆盖 marker，而一个已退休的引擎手上握着的是**上一个账户目录**的 store：自撤销第 1 步
    /// 退休引擎、第 4 步删掉 `marker.json`，一个还在 `getUpdates` 里挂着的轮次醒来把 marker
    /// 写回去，就把 CASE 3.2 防的那个灾难原样造出来。
    func testARetiredEngineNeverWritesTheMarker() async throws {
        let entry = PhiSyncMarkerFile(marker: Data("m0".utf8), storeBirthday: "B")
        let markerStore = MemoryMarkerStore(file: entry)
        let client = FakePhiSyncClient()
        // 有一页可收：少了它，「没写」只是因为无事可写。
        client.scriptedPages = [settingsPage(value: "on", version: 10, marker: "m1")]
        let arrived = Gate()
        let release = Gate()
        client.arrivedInGetUpdates = arrived
        client.getUpdatesGate = release
        let engine = makeEngine(client: client, markerStore: markerStore)

        let parked = Task { await engine.pullOnce() }
        await arrived.wait()                     // 这一轮此刻停在 getUpdates 里
        engine.shutdown()                        // 同步，与 `stopPhiSync()` 的调法一致
        await release.open()
        await parked.value

        XCTAssertTrue(markerStore.saves.isEmpty, "退休之后一次 save 都没有")
        XCTAssertEqual(markerStore.file, entry, "与入口那份逐字相等")
    }

    /// CASE 3.5B — 换账户那一次擦除连两个 legacy 键一起擦，`hadCursor` 也认它们。
    ///
    /// 防的是什么：一台迁移写失败的机器（§2.10：写失败就不清键）换账户之后，
    /// `buildPhiSyncEngine` 会把 alice 的 marker 迁进 bob 的 `marker.json`——服务端的 marker
    /// 是按账户发的不透明 token，bob 按它要增量等于**永久漏收**账户历史。
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
        XCTAssertNil(defaults.object(forKey: PhiSyncEngine.markerStateKey), "legacy 键也擦")
        XCTAssertNil(defaults.object(forKey: PhiSyncEngine.storeBirthdayStateKey), "legacy 键也擦")
        XCTAssertEqual(defaults.string(forKey: PhiChromiumCoordinator.phiSyncCursorOwnerKey),
                       "auth0|bob")

        // `hadCursor` 的判据同样认 legacy 键：只剩迁移残留时也算「有游标」。
        defaults.set(Data("M-bob".utf8), forKey: PhiSyncEngine.markerStateKey)
        XCTAssertTrue(PhiChromiumCoordinator.resetPhiSyncCursorIfAccountChanged(
            accountId: "auth0|carol", defaults: defaults))
        XCTAssertNil(defaults.object(forKey: PhiSyncEngine.markerStateKey))
    }
}

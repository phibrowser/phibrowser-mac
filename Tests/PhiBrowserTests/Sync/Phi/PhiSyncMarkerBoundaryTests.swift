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
/// **Task 2b 追加**（逐页边界的引擎半边，`// MARK: - Task 2b` 之后）：B2-1 / 1b / 1c / 1d / 1e /
/// 2 / 4 / 4b / 4c / 4d / 5 / 5b / 6 / 6b / 6c / 7 / 7b / 7c / 8(a) / 8(b) / 8b / 9 / 10 / 12 / 13 /
/// 14 / 15 / 16 / 18。B2-2b（真 `LocalStore` 上 `rowAlreadyMapped` 的正面用例）住在
/// `PinnedTabScopeTests`（脚手架在那里）；B2-3 / B2-17 与每一条「五种 kind」用例里的 urlrules
/// 那一格留给 Task 6 / 3b。崩溃窗口一律用「假件在精确那一点回 `false` + 同一组 store 上新建
/// 第二个引擎」模拟，测试里没有任何 `abort()`，也不碰那两个 debug 键。
///
/// **Task 3b 追加**（`// MARK: - Task 3b` 之后）：Space 入站 create 的映射先行（R-M3-4a-87）——
/// B2-17（主探针：映射已写、行未建 ⇒ A0 死映射自愈收口）、B2-17a（行已建、游标未写 ⇒ 重投走
/// update 支）、B2-4d-x（映射写失败零痕迹 + 本页重投去重）；B2-17neg 是 B2-17 上方的一段注释，
/// 不是第二份测试代码。B2-17 的规则侧连带断言留给 Task 6 在同一条用例上**追加**。
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
    // MARK: - Task 2b：装配与小工具

    /// 与 `client.storeBirthday`（"birthday-1"）一致的 marker 文件：逐页的 birthday 写因此是
    /// `updated == markerState` 的零写，`MemoryMarkerStore.saves` 里只剩 marker 本身的写，
    /// `failSaveOnCallNumber` 数的也只是它们。
    private func markerStore(marker: String?) -> MemoryMarkerStore {
        MemoryMarkerStore(file: PhiSyncMarkerFile(marker: marker.map { Data($0.utf8) },
                                                  storeBirthday: "birthday-1"))
    }

    /// `hasDrainedFullReplay` 预置为真 = 这台机器已经完整拉过一遍这个 data type，发布侧的
    /// guard ① 不挡路。
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

    /// 一条能落地的 Space create：`profile_uuid` 绑到 `makeSpaceAccess` 里那个 `pu-1`。
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

    /// 一元 bool 注册表，形状照 `PhiSyncEngineTests.registry`（那一份是 `private`）。
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

    /// 一条本机待发的书签编辑：行的标题与游标 `reconciled` 不同 ⇒ 差分为它发一条 update。
    /// 服务端那一行同时种进 `client.stored`（版本 1，`entityId` 与游标一致），否则假件的
    /// update 路径找不到行会抛 INVALID_MESSAGE。用 `pagesByMarker` 时 `stored` 不参与
    /// `getUpdates`；用 `stored` 模式时入口 marker 取 "1"，这一行就不会被重投。
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

    // MARK: - Task 6：URL Rule 那一格的小工具

    private func ruleTag(_ uuid: String) -> String { PhiSyncEntity.urlRuleClientTag(uuid) }

    /// 一条能落地的规则实体：目标默认 `su-1`，映到 `makeSpaceAccess` 的 `s-1`。`targetSpaceUuid`
    /// 传别的值 = 归属那条 Space 还没建出来（B2-16 的规则版就靠它把归属与 Space 排在同一页）。
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

    /// 形状照 `PhiSyncEngineOwnedItemsTests.makeEngine`，多传 `markerStore:`；`spaceAccess`
    /// 是可选参数而不是带默认实参的非可选值（那个假件是 `@MainActor` 的，默认实参在非隔离
    /// 上下文里求值）。
    private func makeOwnedEngine(client: FakePhiSyncClient,
                                 markerStore: any PhiSyncMarkerStore,
                                 spaceStore: MemorySpaceStore,
                                 spaceAccess: FakePhiSpaceAccess? = nil,
                                 settings: [SyncableSetting] = [],
                                 ownedKinds: [OwnedKindRegistration] = []) -> PhiSyncEngine {
        PhiSyncEngine(domainKeys: StubDomainKeys(key: key), client: client,
                      defaults: defaults, deviceKeyId: "devA", settings: settings,
                      spaceAccess: spaceAccess ?? makeSpaceAccess(), spaceStore: spaceStore,
                      markerStore: markerStore, ownedKinds: ownedKinds,
                      now: { 1_700_000_000_000 })
    }

    /// M3-1 形态的纯设置引擎：`spaceStore == nil`、`spaceAccess == nil`。
    private func makeSettingsOnlyEngine(client: FakePhiSyncClient,
                                        markerStore: any PhiSyncMarkerStore,
                                        settings: [SyncableSetting]) -> PhiSyncEngine {
        PhiSyncEngine(domainKeys: StubDomainKeys(key: key), client: client,
                      defaults: defaults, deviceKeyId: "devA", settings: settings,
                      markerStore: markerStore, now: { 1_700_000_000_000 })
    }

    // MARK: - CASE B2-1（书签游标 save 失败 ⇒ marker 不推）

    /// CASE B2-1 — 书签游标 save 失败 ⇒ 本页 marker 不推、本轮 `cursor_save_failed`；放行之后
    /// 假件从 M0 重投同一页，落地走 update 支、一行不多。
    ///
    /// 防的是什么：「收到就落 marker」那一版——行落了、游标没落、marker 却越过了那一页，服务端
    /// 永不重投 ⇒ 下一轮 `loadOwnedTable` 读到落地前的基线 ⇒ 差分为这条身份重发一遍。
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

        XCTAssertEqual(markerStore.file.marker, Data("0".utf8), "M0 未动")
        let outcome = await engine.lastRoundOutcomeForTesting
        let advanced = await engine.lastRoundMarkerAdvancedForTesting
        let failures = await engine.lastRoundCursorSaveFailedCountForTesting
        let pages = await engine.lastRoundPagesForTesting
        let counters = await engine.lastOwnedRoundCountersForTesting["bookmarks"]
        XCTAssertEqual(outcome, .cursorSaveFailed)
        XCTAssertFalse(advanced)
        XCTAssertEqual(failures, 1)
        XCTAssertEqual(pages, 1)
        XCTAssertEqual(access.rows.count, 1, "行已经建出来：落地先于游标")
        XCTAssertEqual(counters?.applied, 1)

        ownedStore.failNextSave = false
        let applyCallsBefore = applyCalls(access)
        await engine.pullOnce()

        XCTAssertEqual(client.getUpdatesCalls.last?.marker, Data("0".utf8), "假件从 M0 重投同一页")
        if applyCalls(access) > applyCallsBefore {
            XCTAssertEqual(createCount(access.lastAppliedOps), 0, "重投走 update 支，不是 create")
        }
        XCTAssertEqual(access.rows.count, 1)
        XCTAssertEqual(access.rows.filter { $0.syncId == "b1" }.count, 1, "一条身份一行")
        XCTAssertEqual(markerStore.file.marker, Data("7".utf8))
        let second = await engine.lastRoundOutcomeForTesting
        XCTAssertEqual(second, .ok)
    }

    /// CASE B2-1b — 失败轮零发布：`client.commits` 里书签 tag 零条，发布段那次 `loadOwnedTable`
    /// 根本没发生（`hadRecordsSeen.count == 1`，只有轮首那一次）。
    ///
    /// 防的是什么：放行 push 的那一版会带着**落地前**的基线 commit，正是 `c549c4c5` 刚修掉的
    /// 提交风暴（R-M3-4a-16 的三条后果）。
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
        XCTAssertTrue(bookmarkCommits(client).isEmpty, "失败轮一条都不发")
        XCTAssertEqual(counters?.pushed, 0)
        XCTAssertEqual(counters?.tombstones, 0)
        XCTAssertEqual(ownedStore.saveCalls, 1, "只有落地那一次写，发布段那次没发生")
        XCTAssertEqual(ownedStore.hadRecordsSeen.count, 1, "发布段的 `loadOwnedTable` 零调用")
    }

    // MARK: - CASE B2-1c（发布闸是 `canPublishThisRound ∧ cursorSaveFailures == 0`）

    /// CASE B2-1c (a) — `spaceStore == nil` 的纯设置引擎：`.ok`（**不是** `.gated`），设置照发。
    func testASettingsOnlyEngineReportsOkAndPublishes() async throws {
        let settingKey = "phi.test.b21c.local"
        defaults.set(true, forKey: settingKey)              // 本机待发编辑
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([boolSettingsEntity(key: "phi.test.b21c.remote", false,
                                                          at: 100, version: 10)], marker: "10")]
        client.seed(ciphertext: Data(), version: 10, entityId: "srv-settings")
        let engine = makeSettingsOnlyEngine(client: client, markerStore: markerStore(marker: "0"),
                                            settings: boolRegistry(settingKey))
        await engine.pullOnce()

        let outcome = await engine.lastRoundOutcomeForTesting
        let failures = await engine.lastRoundCursorSaveFailedCountForTesting
        XCTAssertEqual(outcome, .ok, "`spaceStore == nil` 不算 gated（RR-B10）")
        XCTAssertEqual(failures, 0)
        XCTAssertEqual(settingsCommits(client).count, 1, "设置 tag 恰 1 条")
    }

    /// CASE B2-1c (b) — 门关、`spaceStore` 非 nil ⇒ `.gated`，设置照发。
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
        // 门**关着**：不调 `setSpaceSyncEnabled(true)`。
        await engine.pullOnce()

        let outcome = await engine.lastRoundOutcomeForTesting
        XCTAssertEqual(outcome, .gated)
        XCTAssertEqual(settingsCommits(client).count, 1, "门关轮次设置照发")
    }

    /// CASE B2-1c (c) — 页预算用尽 ⇒ `.pageBudgetExhausted`、64 页、**零 commit**
    /// （`canPublishThisRound == false`，`c9ab5806` 的语义；marker 照推，B2-8b）；跟进轮把
    /// 剩下的页排干之后 `.ok` 并把本机那条待发编辑发出去。
    ///
    /// 跟进轮是引擎自己排进队列的、不可 await 的一轮：`gateGetUpdatesFromCall = 65` 让它停在
    /// 自己的第一次请求里，本轮的结局行因此可以确定地读到；放行之后再排一轮普通 `pullOnce()`
    /// 排在它后面，等它跑完。
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
        XCTAssertTrue(advanced, "marker 照推，发布与推进是两件事")
        XCTAssertTrue(client.commits.isEmpty, "没 drain 完的一轮一条都不发")

        client.pageBudgetExhaustsAfter = nil
        await followUpGate.open()
        await engine.pullOnce()                     // 排在跟进轮后面，等它排干并发布

        let drainedOutcome = await engine.lastRoundOutcomeForTesting
        XCTAssertEqual(drainedOutcome, .ok)
        XCTAssertGreaterThanOrEqual(bookmarkCommits(client).count, 1, "排干那一轮才发出去")
    }

    /// CASE B2-1c (d) — 只有书签的本机读失败 ⇒ `.localReadFailed`，书签 `pushed == 0` 而 pin 与
    /// 规则照发（R-exec-3 是 per-kind 的，不是全局）。规则那一格（Task 6）：本机那条未发布的
    /// `r1` 照常发出去一条 create、`urlrules` 自己的 `local_read_failed` 是 0。
    func testALocalReadFailureIsPerKindAndReportedAsLocalReadFailed() async throws {
        let bookmarkAccess = FakeBookmarkAccess()
        bookmarkAccess.readError = LocalStoreWriteError.storeUnavailable
        let bookmarkStore = MemoryOwnedItemStore()
        let pinAccess = FakePinAccess(scope: .profile, account: .profile,
                                      rows: [.fixture(lineageId: "lp", guid: "gp", profileId: "Default")])
        let pinStore = MemoryOwnedItemStore()
        // 目标是 `makeSpaceAccess` 的 `s-1`（映到 `su-1`）⇒ 归属合格、这一条进得了快照。
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
        XCTAssertEqual(pinCommits(client).count, 1, "pin 不受书签那次读失败影响")
        XCTAssertGreaterThanOrEqual(counters["pins"]?.pushed ?? 0, 1)
        // CASE B2-1c (d) urlrules（Task 6）
        XCTAssertEqual(counters["bookmarks"]?.localReadFailed, 1, "失效的只有书签那一条 kind")
        XCTAssertEqual(counters["urlrules"]?.localReadFailed, 0)
        XCTAssertEqual(ruleCommits(client).count, 1, "规则不受书签那次读失败影响")
        XCTAssertGreaterThanOrEqual(counters["urlrules"]?.pushed ?? 0, 1)
    }

    /// CASE B2-1c (e)（whole-branch final review I-1，R-M3-4a-103）— **发布段自己**那次游标表写
    /// 失败也是 per-kind 的：书签的 `writeOwnedTable` 失败 ⇒ 只有书签这一条 kind 缩手，pin 与
    /// 规则的整个发布段（快照 → 差分 → commit → 写表，连同 §8.4.5 清位 (b) 与 3b 重新准入复检）
    /// 照跑，各 1 条 commit、各自的游标真的落了盘；结局仍收口成 `cursor_save_failed`。
    ///
    /// 防的是什么：`publishOwnedKind` 里把 R-M3-4a-103 那道闸写成 `cursorSaveFailures == 0` 的
    /// 那一版。注册次序是 `bookmarks → pins → urlrules`，书签一次推送侧的写失败会把后面两条 kind
    /// 的发布段整段吃掉——§2.5 第 6 条点名禁止把 R-exec-3 的 per-kind 语义扩成全局。轮级的那道闸
    /// 是 `canPublishThisRound`（本用例里它是真：失败发生在 push 段，不在任何一页里）。
    ///
    /// 写序号的推导：空页对书签**一次表写都没有**——`applyOwnedKind` 在 `landsEmptyBatch` 那道
    /// 早退上返回（三者全空 ∧ `landsEmptyBatch == false`，`replayedAfterDelete == 0` ⇒ 连早退里
    /// 那次写也不发生；只有规则那条 kind 的空页要走 `plan` / `land`）。于是书签这一轮的第 1 次、
    /// 也是唯一一次 `save` 就是发布段那一次；书签本机零行 ⇒ `work` 为空 ⇒ 它正是
    /// `guard !work.isEmpty` 的早退写、零 commit。
    func testAPushSideCursorSaveFailureOfOneKindDoesNotSuppressTheLaterKinds() async throws {
        let bookmarkAccess = FakeBookmarkAccess()
        let bookmarkStore = MemoryOwnedItemStore()
        bookmarkStore.failSaveOnCallNumber = 1
        let pinAccess = FakePinAccess(scope: .profile, account: .profile,
                                      rows: [.fixture(lineageId: "lp", guid: "gp", profileId: "Default")])
        let pinStore = MemoryOwnedItemStore()
        // 目标是 `makeSpaceAccess` 的 `s-1`（映到 `su-1`）⇒ 归属合格、这一条进得了快照。
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
        XCTAssertEqual(failures, 1, "失败的恰好是书签发布段那一次写")
        XCTAssertEqual(bookmarkStore.saveCalls, 1, "空页零落地写 ⇒ 唯一那次就是发布段那次")
        XCTAssertTrue(bookmarkCommits(client).isEmpty)
        XCTAssertEqual(counters["bookmarks"]?.pushed, 0)
        XCTAssertEqual(pinCommits(client).count, 1, "pin 不受书签那次写失败影响")
        XCTAssertGreaterThanOrEqual(counters["pins"]?.pushed ?? 0, 1)
        XCTAssertEqual(pinStore.table.cursors.count, 1, "pin 的游标真的落了盘")
        XCTAssertEqual(ruleCommits(client).count, 1, "规则不受书签那次写失败影响")
        XCTAssertGreaterThanOrEqual(counters["urlrules"]?.pushed ?? 0, 1)
        XCTAssertNotNil(ruleStore.table.cursors["r1"], "规则的游标真的落了盘")
    }

    /// CASE B2-1c (f)（final review I-1 的负面对照，R-M3-4a-103）— 同一道闸的**本意**必须保住：
    /// 书签自己那次报损重放武装（第 ① 步清 marker）写失败 ⇒ 书签这一条 kind 本轮不发布、不重建
    /// 它的游标文件、闩不置位；而同一轮里 pin 与规则照发。
    ///
    /// 两条断言分工：书签那几条钉的是 2b-L1 的语义在 delta 形态下没被放宽（`before` 取在
    /// `loadOwnedTable` **之前**，武装那次失败落在 delta 里）；pin / 规则那两条钉的是它没有被
    /// 扩成全局。写序号：页 1 的 marker 写是第 1 次，书签报损重放的第 ① 步是第 2 次（pin 与规则
    /// 的 `…HadRecords` 是假 ⇒ 它们那两次 load 不报损、不写 marker）。
    func testAFailedLossReplayArmStillSkipsOnlyItsOwnKind() async throws {
        let spaceStore = drainedSpaceStore()
        spaceStore.table.bookmarksHadRecords = true        // 书签的空表 = 游标文件丢了
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
        XCTAssertTrue(bookmarkCommits(client).isEmpty, "没有对着丢失的表发布")
        XCTAssertEqual(bookmarkStore.saveCalls, 0, "空页零落地写、发布段又在任何写之前返回")
        XCTAssertTrue(bookmarkStore.table.cursors.isEmpty, "下一轮 load 照样报损")
        XCTAssertFalse(spaceStore.table.bookmarksReplayedForEmptyTable, "闩没置位")
        XCTAssertEqual(markerStore.file.marker, Data("7".utf8), "清 marker 那一步没成")
        XCTAssertEqual(pinCommits(client).count, 1, "书签那次失败的武装不牵连 pin")
        XCTAssertEqual(ruleCommits(client).count, 1, "也不牵连规则")
        XCTAssertNotNil(ruleStore.table.cursors["r1"])
    }

    /// CASE B2-1d — 本地编辑轮绕过 `if thenPush` 那一行（R-M3-4a-92）：最后一页的游标 save 失败
    /// ⇒ `drained == true` 但 `pull` 回 `false` ⇒ `push` 的 guard 拦住 ⇒ 零 commit；盘上 marker
    /// 停在第 1 页那个值。放行之后重投第 2 页，本机那条待发编辑这才发出去。
    ///
    /// 防的是什么：把合取项只串在 `if thenPush, canPublishThisRound` 上的那一版——本地编辑轮走
    /// 的是 `guard await pull(retryOnBirthday: true, thenPush: false) else { return }`，
    /// `thenPush == false`，那一行根本不参与判定。
    func testALocalOwnedChangeRoundIsBlockedByTheCursorSaveFailureOfItsLastPage() async throws {
        let access = FakeBookmarkAccess()
        let ownedStore = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        seedPendingLocalBookmarkEdit(access: access, store: ownedStore, client: client)
        client.pagesByMarker = [
            page([bookmarkEntity("b1", version: 7)], marker: "7", changesRemaining: true),
            page([bookmarkEntity("b2", version: 9)], marker: "9"),
        ]
        // 两页各一次落地写 ⇒ 最后一页那次是第 2 次。
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
        XCTAssertTrue(client.commits.isEmpty, "书签 / 设置 / Space 全零：那次内部 pull 回的是 false")
        XCTAssertEqual(counters?.pushed, 0)
        XCTAssertEqual(markerStore.file.marker, Data("7".utf8), "停在第 1 页，没有越过第 2 页")

        ownedStore.failSaveOnCallNumber = nil
        await engine.pullOnce()

        let second = await engine.lastRoundOutcomeForTesting
        XCTAssertEqual(second, .ok)
        XCTAssertEqual(markerStore.file.marker, Data("9".utf8))
        XCTAssertEqual(bookmarkCommits(client).count, 1, "本机那条待发编辑这才发出去")
    }

    /// CASE B2-1e — 冲突重试的绕过（R-M3-4a-92）：`.conflict` 之后的限定重发前那次 pull 落地
    /// 写失败 ⇒ 重试在 `guard await pull(…) else { return }` 当场中止，本轮书签 commit 恰 1 条
    /// （冲突的那一次），冲突身份的 `reconciled` 一个字节没动；下一轮放行 ⇒ 正常重试并 `.applied`。
    ///
    /// 写序号的推导：pull#1 两页各一次落地写（1、2）→ `publishOwnedKind` 提交后写一次表（3）→
    /// 重试那次 pull 只取第 3 页（第 2 页 `changesRemaining == false`，第 3 页水位更高、要等
    /// 重试才被取到）⇒ 它的落地写是第 4 次。
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
        XCTAssertEqual(bookmarkCommits(client).count, 1, "冲突的那一次之后零条")
        XCTAssertEqual(ownedStore.table.cursors["bl"]?.reconciled, baseline,
                       "没有被「重试前的基线」覆写")
        XCTAssertEqual(markerStore.file.marker, Data("9".utf8), "重试那次 pull 的第 3 页没推 marker")

        ownedStore.failSaveOnCallNumber = nil
        await engine.pullOnce()

        let second = await engine.lastRoundOutcomeForTesting
        XCTAssertEqual(second, .ok)
        XCTAssertEqual(bookmarkCommits(client).count, 2, "重投缺的那一页之后正常重试")
        XCTAssertGreaterThan(ownedStore.table.cursors["bl"]?.version ?? 0, 1, "这一次 `.applied`")
        XCTAssertEqual(markerStore.file.marker, Data("11".utf8))
    }

    // MARK: - CASE B2-2（pin 游标 save 失败）

    /// CASE B2-2 — pin 游标 save 失败 ⇒ marker 不推；重投之后按 `(lineage, ownerKey)` 命中了行，
    /// 一条 pin 不会在本机变两条。B2-2b（真 `LocalStore` 上 `rowAlreadyMapped` 的正面用例）在
    /// `PinnedTabScopeTests`。
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
        XCTAssertEqual(pinAccess.rows.count, 1, "重投没有把 update 走成 create")
        XCTAssertEqual(pinCreateCount(pinAccess.lastAppliedOps), 0)
        XCTAssertEqual(pinAccess.rows.first?.title, titleAfterFirstLanding)
        XCTAssertEqual(secondCounters?.refused, 0, "零 `rowAlreadyMapped` 抛出")
        XCTAssertNotNil(pinStore.table.cursors.values.first { $0.entityId == "e1" })
    }

    // MARK: - CASE B2-3（URL Rule 游标 save 失败 ⇒ marker 不推）

    /// CASE B2-3（Task 6）— 规则游标 save 失败 ⇒ 本页 marker 不推、`cursor_save_failed`、零 commit
    /// （落地先于游标，行已经建出来）；放行之后假件从 M0 重投同一页 ⇒ 行仍是一条、`syncId` /
    /// `id` / 四个字段与第一次落地后逐字相同、第二轮零条 `.create`（走 update 支）、marker 推到 M1。
    ///
    /// 防的是什么：「游标写失败也把 marker 推过去」——服务端不会再发第二次，那条规则的基线永久
    /// 缺席，下一轮发布段以 `baseVersion == 0` 盲写覆盖账户上那一条；以及重投走 create 支：账户
    /// 上一条规则，本机变两行。
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
        XCTAssertEqual(access.rows.count, 1, "落地先于游标，行已经建出来")
        let landed = try XCTUnwrap(access.rows.first)
        XCTAssertEqual(landed.syncId, "r1")
        XCTAssertEqual(landed.spaceId, "s-1")

        store.failNextSave = false
        await engine.pullOnce()

        let second = await engine.lastRoundOutcomeForTesting
        XCTAssertEqual(second, .ok)
        XCTAssertEqual(access.rows.count, 1, "重投没有把 update 走成 create")
        let replayed = try XCTUnwrap(access.rows.first)
        XCTAssertEqual(replayed.id, landed.id)
        XCTAssertEqual(replayed.syncId, "r1")
        XCTAssertEqual(replayed.host, landed.host)
        XCTAssertEqual(replayed.pathPrefix, landed.pathPrefix)
        XCTAssertEqual(replayed.askBeforeRouting, landed.askBeforeRouting)
        XCTAssertEqual(replayed.spaceId, landed.spaceId)
        XCTAssertEqual(ruleCreateCount(access.lastAppliedOps), 0, "第二轮走 update 支")
        XCTAssertEqual(markerStore.file.marker, Data("7".utf8))
        XCTAssertEqual(store.table.cursors["r1"]?.entityId, "e1", "游标这才写下")
    }

    // MARK: - CASE B2-4（Space 表 save 失败）

    /// CASE B2-4 — Space 表 save 失败 ⇒ marker 不动；重投同一页 ⇒ 本机不新增第二条行、映射不重铸、
    /// 游标这才写下。
    ///
    /// 防的是什么：Space 表写失败被吞掉 ⇒ marker 越过 ⇒ 游标永远缺这一条 ⇒ 下一轮差分把它当
    /// 「本机没有」，为它发一条出站 tombstone。
    func testASpaceTableSaveFailureHoldsTheMarkerAndTheReplayDoesNotDuplicateTheSpace() async throws {
        let spaceAccess = makeSpaceAccess()
        let spaceStore = drainedSpaceStore()
        let markerStore = markerStore(marker: "0")
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([spaceCreateEntity("u1", version: 3)], marker: "3")]
        let engine = makeOwnedEngine(client: client, markerStore: markerStore,
                                     spaceStore: spaceStore, spaceAccess: spaceAccess)
        await engine.setSpaceSyncEnabled(true)
        spaceStore.failNextSave = true                 // 门那一次写已经过去了
        await engine.pullOnce()

        let outcome = await engine.lastRoundOutcomeForTesting
        XCTAssertEqual(outcome, .cursorSaveFailed)
        XCTAssertEqual(markerStore.file.marker, Data("0".utf8))
        XCTAssertEqual(spaceAccess.spaces.count, 2, "`SpaceModel` 行已建（s-1 之外多一条）")
        XCTAssertEqual(spaceAccess.spaceMappings.values.filter { $0 == "u1" }.count, 1)
        XCTAssertNil(spaceStore.table.cursors["u1"], "那次写没落盘")

        spaceStore.failNextSave = false
        await engine.pullOnce()

        let second = await engine.lastRoundOutcomeForTesting
        XCTAssertEqual(second, .ok)
        XCTAssertEqual(spaceAccess.spaces.count, 2, "重投不新增第二条行")
        XCTAssertEqual(spaceAccess.spaceMappings.values.filter { $0 == "u1" }.count, 1, "映射不重铸")
        XCTAssertNotNil(spaceStore.table.cursors["u1"]?.reconciled)
        XCTAssertEqual(spaceStore.table.cursors["u1"]?.entityId, "srv-u1")
        XCTAssertEqual(markerStore.file.marker, Data("3".utf8))
    }

    /// CASE B2-4b — 派生状态那次写失败也要被捕获：轮末 drain 收尾的 `mutateSpaceTable` 回 `false`
    /// ⇒ 计数 1、`.cursorSaveFailed`、`hasDrainedFullReplay` 仍为 false。marker 在那次写**之前**
    /// 已经随页推进过，所以断言的是结局与计数，不是 `marker_advanced`。
    func testAFailedDrainFlagWriteAtTheRoundTailIsCountedAsACursorSaveFailure() async throws {
        let spaceStore = MemorySpaceStore()
        spaceStore.table.drainInProgress = true
        let markerStore = markerStore(marker: "0")
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([spaceCreateEntity("u1", version: 3)], marker: "3")]
        let engine = makeOwnedEngine(client: client, markerStore: markerStore, spaceStore: spaceStore)
        await engine.setSpaceSyncEnabled(true)
        // 页内落地写是下一次，轮末 drain 标志那次再下一次。
        spaceStore.failSaveOnCallNumber = spaceStore.saveCalls + 2
        await engine.pullOnce()

        let outcome = await engine.lastRoundOutcomeForTesting
        let failures = await engine.lastRoundCursorSaveFailedCountForTesting
        let advanced = await engine.lastRoundMarkerAdvancedForTesting
        XCTAssertEqual(outcome, .cursorSaveFailed)
        XCTAssertEqual(failures, 1)
        XCTAssertFalse(spaceStore.table.hasDrainedFullReplay, "那次写没落盘")
        XCTAssertTrue(spaceStore.table.drainInProgress)
        XCTAssertTrue(advanced, "页的 marker 在轮末那次写之前已经推进")
        XCTAssertNotNil(spaceStore.table.cursors["u1"], "页内落地那次写成了")
    }

    /// CASE B2-4c (a) — `spaceStore == nil` 的早退不算失败：纯设置引擎照推 marker。
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

    /// CASE B2-4c (b) — `isStopped` 的早退不算失败：一轮停在落地之后的 commit 里时 `shutdown()`，
    /// 醒来之后每一处写口都早退回 `true`，结局不是 `.cursorSaveFailed`。
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
        await arrived.wait()                     // 落地已完成，本轮停在书签那次 commit 里
        engine.shutdown()
        await release.open()
        await parked.value

        let outcome = await engine.lastRoundOutcomeForTesting
        let failures = await engine.lastRoundCursorSaveFailedCountForTesting
        XCTAssertNotEqual(outcome, .cursorSaveFailed)
        XCTAssertEqual(failures, 0)
    }

    /// CASE B2-4d（引擎半边）— Space 身份映射写失败（`mapSpace` 抛 `persistFailed`）是第四个
    /// 置位点：`.cursorSaveFailed`、marker 不推、该 uuid 的游标进 `pendingApply`；放行之后重投 ⇒
    /// 映射写下、`localSpaceId(forSyncUuid:)` 解析得出。
    ///
    /// 「本机 Space 行仍是 1 条」那一半由 Task 3b 的映射先行（R-M3-4a-87，CASE B2-4d-x）保证：
    /// 今天的 create 支先建行、后写映射，所以一次映射写失败在 HEAD 上留下一条无映射的行，
    /// 重投会再建一条——那正是 3b 要消掉的形状，本任务不在旧次序上断言它。
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
        XCTAssertNotNil(spaceStore.table.cursors["u1"]?.pendingApply, "既有停放路径")
        XCTAssertNil(spaceAccess.localSpaceId(forSyncUuid: "u1"), "抛出之后不留痕迹")

        await engine.pullOnce()

        let second = await engine.lastRoundOutcomeForTesting
        XCTAssertEqual(second, .ok)
        XCTAssertNotNil(spaceAccess.localSpaceId(forSyncUuid: "u1"), "映射写下")
        XCTAssertEqual(spaceAccess.spaceMappings.values.filter { $0 == "u1" }.count, 1)
        XCTAssertNil(spaceStore.table.cursors["u1"]?.pendingApply)
        XCTAssertEqual(markerStore.file.marker, Data("3".utf8))
    }

    // MARK: - CASE B2-5（设置页与 marker 的次序）

    /// CASE B2-5 — 写入次序是 `writeSettings` → `storedLastEntity` → `hasAdopted` → **marker**：
    /// marker 那次写失败时前三样都已经落地。
    ///
    /// 补注：设置值本身的写入无法回传失败（`UserDefaults.standard.set` 不报错），所以没有
    /// 「设置侧 save 失败」这条用例。
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

        XCTAssertTrue(defaults.bool(forKey: settingKey), "V2 已落地")
        XCTAssertEqual(defaults.object(forKey: SyncableSettings.timestampKey(for: settingKey)) as? NSNumber,
                       NSNumber(value: Int64(300)))
        XCTAssertNotNil(defaults.data(forKey: PhiSyncEngine.lastEntityStateKey), "`storedLastEntity` 已写")
        XCTAssertTrue(defaults.bool(forKey: PhiSyncEngine.hasAdoptedStateKey))
        XCTAssertEqual(markerStore.file.marker, Data("0".utf8), "marker 仍是入口值")
        let outcome = await engine.lastRoundOutcomeForTesting
        XCTAssertEqual(outcome, .cursorSaveFailed)
    }

    /// CASE B2-5b — 重收设置页幂等的真实依据是「盖的是 `value.updatedAtMs`」（R-M3-4a-33）：
    /// 第二次走 merge 支，`K` 的字节逐字相同，sidecar 仍是 300 而不是任何一次 `now()`。
    /// 「重投」用第二台引擎 + 手工回退的 marker 文件模拟（引擎持有内存镜像，直接改文件对
    /// 第一台不可见）。
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

        markerStore.file.marker = Data("0".utf8)             // 模拟重投：盘上回到入口值
        let second = makeSettingsOnlyEngine(client: client, markerStore: markerStore,
                                            settings: boolRegistry(settingKey))
        await second.pullOnce()

        XCTAssertEqual(client.getUpdatesCalls.last?.marker, Data("0".utf8))
        XCTAssertTrue(defaults.bool(forKey: settingKey))
        XCTAssertEqual(defaults.data(forKey: SyncableSettings.valueKey(for: settingKey)), firstBytes,
                       "字节逐字相同")
        XCTAssertEqual(defaults.object(forKey: SyncableSettings.timestampKey(for: settingKey)) as? NSNumber,
                       NSNumber(value: Int64(300)), "不是任何一次 now()")
    }

    // MARK: - CASE B2-6 / 6b / 6c（apply 与 marker 之间被杀）

    /// CASE B2-6 — 落地段与游标写全部完成、marker 写没成（= 在 marker 写之前进程死亡）；用同一组
    /// store 新建第二个引擎（= 重启）重投 ⇒ 行数不增、零 create、零 adopt。
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
        XCTAssertEqual(ownedStore.table.cursors["b1"]?.entityId, "e1", "游标写全部完成")
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

    /// CASE B2-6b — 跨 kind 之间被杀：第一台只注册书签、marker 写失败（= 书签已落、pin 与规则
    /// 一步没跑、marker 未推）；第二台注册三条 kind 共用同一组 store ⇒ 书签行数仍 1、pin 与规则
    /// 各正常落地一条。规则那一格（Task 6）：第一轮零行（那条 kind 根本没注册），第二轮按身份
    /// 落一行、游标这才写下。
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
        XCTAssertTrue(pinAccess.rows.isEmpty, "pin 那条 kind 一步没跑")
        XCTAssertTrue(ruleAccess.rows.isEmpty, "规则那条 kind 一步没跑")
        XCTAssertEqual(markerStore.file.marker, Data("0".utf8))

        markerStore.failSaveOnCallNumber = nil
        let second = makeOwnedEngine(client: client, markerStore: markerStore,
                                     spaceStore: spaceStore, spaceAccess: spaceAccess,
                                     ownedKinds: [.bookmarks(access: bookmarkAccess, store: bookmarkStore),
                                                  .pins(access: pinAccess, store: pinStore),
                                                  .urlRules(access: ruleAccess, store: ruleStore)])
        let applyCallsBefore = applyCalls(bookmarkAccess)
        await second.pullOnce()

        XCTAssertEqual(bookmarkAccess.rows.count, 1, "书签无重复")
        if applyCalls(bookmarkAccess) > applyCallsBefore {
            XCTAssertEqual(createCount(bookmarkAccess.lastAppliedOps), 0, "走 update 支")
        }
        XCTAssertEqual(pinAccess.rows.count, 1, "pin 无丢失")
        XCTAssertEqual(markerStore.file.marker, Data("9".utf8))
        // CASE B2-6b urlrules（Task 6）
        let counters = await second.lastOwnedRoundCountersForTesting["urlrules"]
        XCTAssertEqual(ruleAccess.rows.count, 1, "规则无丢失")
        XCTAssertEqual(ruleAccess.rows.first?.syncId, "r1")
        XCTAssertEqual(ruleAccess.rows.first?.spaceId, "s-1")
        XCTAssertEqual(counters?.applied, 1)
        XCTAssertEqual(ruleStore.table.cursors["r1"]?.entityId, "srv-r1", "游标这才写下")
    }

    /// CASE B2-6c — LocalStore 事务提交与游标写之间被杀：行已建且带 `syncId`、游标文件仍是旧的。
    /// 重启后 tag 索引的种子含 `localIdentities()` 里那个 `syncId` ⇒ 路由命中 ⇒ 游标被**重建**
    /// （`entityId == "e1"`）而不是新建第二条行。
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

        XCTAssertEqual(access.rows.first?.syncId, "b1", "行存在且带 `syncId`")
        XCTAssertTrue(ownedStore.table.cursors.isEmpty, "游标表里没有它的身份")
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
        XCTAssertEqual(ownedStore.table.cursors["b1"]?.entityId, "e1", "游标被重建")
        XCTAssertEqual(markerStore.file.marker, Data("7".utf8))
    }

    // MARK: - CASE B2-7 / 7b / 7c（多种 kind 同页）

    /// 同一页：设置 1 + Space 1 + 书签 2 + pin 1 + 规则 1（Task 6 补的第五种 kind，排最后）。
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

    /// 注册次序 `[bookmarks, pins, urlrules]`，与协调器的 `ownedKinds` 字面量逐字相同：规则排
    /// 最后，B2-7b 的中止窗口「最后一条 kind 落完但 marker 没写」因此落在它身上（CASE U-28）。
    private func makeFourKindEngine(_ f: FourKindFixture) -> PhiSyncEngine {
        makeOwnedEngine(client: f.client, markerStore: f.markerStore, spaceStore: f.spaceStore,
                        spaceAccess: f.spaceAccess, settings: boolRegistry(f.settingKey),
                        ownedKinds: [.bookmarks(access: f.bookmarkAccess, store: f.bookmarkStore),
                                     .pins(access: f.pinAccess, store: f.pinStore),
                                     .urlRules(access: f.urlRuleAccess, store: f.urlRuleStore)])
    }

    private func assertFourKindsLandedExactlyOnce(_ f: FourKindFixture,
                                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(defaults.bool(forKey: f.settingKey), "设置键值", file: file, line: line)
        XCTAssertEqual(defaults.object(forKey: SyncableSettings.timestampKey(for: f.settingKey)) as? NSNumber,
                       NSNumber(value: Int64(300)), "设置 sidecar", file: file, line: line)
        XCTAssertEqual(f.spaceAccess.spaces.count, 2, "Space 行：s-1 之外恰一条", file: file, line: line)
        XCTAssertEqual(f.spaceAccess.spaceMappings.values.filter { $0 == "u1" }.count, 1,
                       file: file, line: line)
        XCTAssertEqual(f.bookmarkAccess.rows.count, 2, "书签两行", file: file, line: line)
        XCTAssertEqual(Set(f.bookmarkAccess.rows.compactMap(\.syncId)), ["b1", "b2"], file: file, line: line)
        XCTAssertEqual(f.pinAccess.rows.count, 1, "pin 一行", file: file, line: line)
        XCTAssertEqual(f.urlRuleAccess.rows.count, 1, "规则一行", file: file, line: line)
        XCTAssertEqual(f.urlRuleAccess.rows.first?.syncId, "r1", file: file, line: line)
    }

    /// CASE B2-7 — 只有 pin 的 store save 失败 ⇒ marker 不推，但**五种 kind 的落地都已发生**；
    /// 重投整页 ⇒ 五种 kind 各自的行数与身份数不增、零 resurrected / refused / 出站 tombstone。
    /// 规则那一格（Task 6）：行数 1、`syncId == "r1"`、`urlrules applied == 1`、规则的游标表 save
    /// **成功**（一种 kind 失败不牵连别的 kind 的落盘）；第二轮零 `tombstones`、零 `.create`。
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
        XCTAssertNotNil(f.spaceStore.table.cursors["u1"], "Space 游标写成了（那张表没失败）")
        XCTAssertEqual(f.bookmarkStore.table.cursors.count, 2)
        XCTAssertTrue(f.pinStore.table.cursors.isEmpty, "只有 pin 那次写没落盘")
        // CASE B2-7 urlrules（Task 6）
        XCTAssertEqual(firstCounters["urlrules"]?.applied, 1)
        XCTAssertEqual(f.urlRuleStore.table.cursors.count, 1, "规则的游标表 save 成功")
        XCTAssertEqual(f.urlRuleStore.table.cursors["r1"]?.entityId, "srv-r1")
        let ruleApplyCallsAfterFirstRound = ruleApplyCalls(f.urlRuleAccess)

        f.pinStore.failNextSave = false
        await engine.pullOnce()

        let second = await engine.lastRoundOutcomeForTesting
        let counters = await engine.lastOwnedRoundCountersForTesting
        XCTAssertEqual(second, .ok)
        assertFourKindsLandedExactlyOnce(f)
        XCTAssertEqual(f.bookmarkStore.table.cursors.count, 2, "身份数不增")
        XCTAssertEqual(f.pinStore.table.cursors.count, 1)
        XCTAssertEqual(f.urlRuleStore.table.cursors.count, 1, "规则身份数不增")
        for label in ["bookmarks", "pins", "urlrules"] {
            XCTAssertEqual(counters[label]?.resurrected, 0, label)
            XCTAssertEqual(counters[label]?.refused, 0, label)
            XCTAssertEqual(counters[label]?.tombstones, 0, label)
        }
        // 重收一条远端存活实体不产出任何 `.create`：游标在第一轮就写成了，第二轮要么零 op、
        // 要么只走 update 支（R-M3-4a-16 后果 (b) 在规则上的探针）。
        if ruleApplyCalls(f.urlRuleAccess) > ruleApplyCallsAfterFirstRound {
            XCTAssertEqual(ruleCreateCount(f.urlRuleAccess.lastAppliedOps), 0)
        }
        XCTAssertTrue(f.client.commitsAreFreeOfOutboundTombstones(), "重收不产出出站 tombstone")
        XCTAssertEqual(f.markerStore.file.marker, Data("15".utf8))
    }

    /// CASE B2-7b — 同一页多种 kind 落地之后、marker 之前被杀：五个 store 全放行，marker 写失败；
    /// 第二台引擎重投 ⇒ 五种 kind 的行数、身份数不增、内容与中止前逐字相同。规则那一格（Task 6）：
    /// `syncId` / `host` / `pathPrefix` / `spaceId` / `sortOrder` 与中止前逐字相同，`adopted` /
    /// `resurrected` 都是 0。中止点是「最后一条 kind（规则）落完、marker 没写」——注册次序把规则
    /// 排在 pin 之后，这条用例才覆盖得到那个唯一的跨 kind 窗口（CASE U-28）。
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

    /// CASE B2-7c — 重收一条远端 tombstone 不产出出站 tombstone：第一轮行被删、游标写失败、零
    /// commit；第二轮重投 ⇒ 本机已无行（T3 支）、仍然零出站 tombstone。
    ///
    /// `counters.tombstones` 数的是**入站**的远端 tombstone（`applyOwnedKind` 的头三行），所以这里
    /// 钉「零出站」用的是 `client.commits` 与 `pushed`，不是那个计数。
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
        XCTAssertTrue(access.rows.isEmpty, "行被删")
        XCTAssertEqual(outcome, .cursorSaveFailed)
        XCTAssertEqual(counters?.pushed, 0)
        XCTAssertTrue(bookmarkCommits(client).isEmpty, "书签 tag 零条")
        XCTAssertEqual(markerStore.file.marker, Data("1".utf8))

        ownedStore.failNextSave = false
        await engine.pullOnce()

        let second = await engine.lastRoundOutcomeForTesting
        let secondCounters = await engine.lastOwnedRoundCountersForTesting["bookmarks"]
        XCTAssertEqual(second, .ok)
        XCTAssertTrue(access.rows.isEmpty)
        XCTAssertEqual(secondCounters?.pushed, 0)
        XCTAssertTrue(bookmarkCommits(client).filter(\.deleted).isEmpty, "零出站 tombstone")
        XCTAssertEqual(markerStore.file.marker, Data("9".utf8))
    }

    // MARK: - CASE B2-8(a) / 8(b) / 8b（中途抛错与页预算）

    /// CASE B2-8(a) — 增量轮中途抛错，前面的页保住：marker 停在第 3 页那个值（不是入口值、不是
    /// nil），`.pullFailed`、`marker_advanced == true`，前三页的实体都已落地；下一轮从 13 继续。
    func testAnIncrementalRoundInterruptedMidWayKeepsTheLandedPages() async throws {
        let access = FakeBookmarkAccess()
        let ownedStore = MemoryOwnedItemStore()
        let spaceStore = drainedSpaceStore()            // drainInProgress == false：guard 1 不武装
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
        XCTAssertEqual(markerStore.file.marker, Data("13".utf8), "第 3 页那个值")
        XCTAssertEqual(pages, 3)
        XCTAssertEqual(outcome, .pullFailed)
        XCTAssertTrue(advanced)
        XCTAssertEqual(Set(access.rows.compactMap(\.syncId)), ["b11", "b12", "b13"], "前三页都已落地")
        XCTAssertTrue(client.commits.isEmpty, "抛错的一轮零 commit")

        let callsBefore = client.getUpdatesCalls.count
        await engine.pullOnce()

        XCTAssertEqual(client.getUpdatesCalls[callsBefore].marker, Data("13".utf8), "从 13 继续")
        XCTAssertEqual(Set(access.rows.compactMap(\.syncId)), ["b11", "b12", "b13", "b14", "b15"])
        XCTAssertEqual(markerStore.file.marker, Data("15".utf8))
    }

    /// CASE B2-8(b) — drain 轮中途抛错，整条重放：首同步（marker nil）⇒ guard 1 武装 ⇒ 抛错后
    /// catch 里那句丢 marker 保留 ⇒ 第二轮真的从头重放，跑完五页后 `hasDrainedFullReplay == true`。
    ///
    /// 防的是什么：删掉那一句的那一版会让一次被打断的 drain 在下一轮以「已完整重放」收尾
    /// （`hasDrainedFullReplay` 盖在洞上），而那个标志是归属 kind 的发布闸。
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
        XCTAssertNil(markerStore.file.marker, "被打断的 drain 丢 marker")
        XCTAssertTrue(spaceStore.table.drainInProgress)
        XCTAssertFalse(spaceStore.table.hasDrainedFullReplay)
        XCTAssertEqual(outcome, .pullFailed)

        let callsBefore = client.getUpdatesCalls.count
        await engine.pullOnce()

        XCTAssertNil(client.getUpdatesCalls[callsBefore].marker, "真的从头重放")
        XCTAssertEqual(client.getUpdatesCalls.count - callsBefore, 5)
        XCTAssertTrue(spaceStore.table.hasDrainedFullReplay)
        XCTAssertFalse(spaceStore.table.drainInProgress)
        XCTAssertEqual(markerStore.file.marker, Data("15".utf8))
    }

    /// CASE B2-8b — 页预算用尽照推 marker：`.pageBudgetExhausted`、`marker_advanced == true`、
    /// 64 页、盘上 marker 是第 64 页那个值、**零 commit**；跟进轮从它继续，排干那一轮才发布。
    ///
    /// 防的是什么：按「只有 `ok` 才推 marker」实现的版本——真机上那意味着大账户每轮重读同样
    /// 64 页、永远排不干。
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
        XCTAssertEqual(markerStore.file.marker, Data("5".utf8), "第 64 页那个值")
        XCTAssertTrue(client.commits.isEmpty)
        XCTAssertEqual(access.rows.count, 1, "第 1 页的实体已落地")

        // 跟进轮停在它的第 65 次请求里；放行后它从 "5" 继续并排干。
        client.pageBudgetExhaustsAfter = nil
        await followUpGate.open()
        await engine.pullOnce()
        let drainedOutcome = await engine.lastRoundOutcomeForTesting
        XCTAssertEqual(drainedOutcome, .ok)
        XCTAssertEqual(client.getUpdatesCalls[64].marker, Data("5".utf8), "跟进轮从它继续")
    }

    // MARK: - CASE B2-9（门关轮次照推 marker，记账先于 marker）

    /// CASE B2-9 — 门关轮次：`.gated`、marker 照推、`markerMovedWhileGateShut == true`、设置那一条
    /// 已经落地（键值与 sidecar），三条非设置实体被丢弃、`cursors` 仍为空。
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
        await engine.pullOnce()                            // 门关着

        let outcome = await engine.lastRoundOutcomeForTesting
        let advanced = await engine.lastRoundMarkerAdvancedForTesting
        XCTAssertEqual(outcome, .gated)
        XCTAssertTrue(advanced)
        XCTAssertTrue(spaceStore.table.markerMovedWhileGateShut)
        XCTAssertTrue(defaults.bool(forKey: settingKey), "设置已落地")
        XCTAssertEqual(defaults.object(forKey: SyncableSettings.timestampKey(for: settingKey)) as? NSNumber,
                       NSNumber(value: Int64(300)))
        XCTAssertTrue(spaceStore.table.cursors.isEmpty, "三条非设置实体被丢弃")
        XCTAssertEqual(markerStore.file.marker, Data("13".utf8))
    }

    /// CASE B2-9 崩溃窗口变体（R-M3-4a-77）— 标志写成功、marker 写失败（= 在两次写之间死亡）⇒
    /// `markerMovedWhileGateShut == true` **且** 盘上 marker 仍是入口值、`.cursorSaveFailed`；
    /// 第二台引擎重投同一页 ⇒ 正常收尾；随后开门 ⇒ `applySpaceGate` 第一个析取项成立 ⇒ 整类型重放。
    ///
    /// 防的是什么：按 RR-B12 原次序（标志写在 marker 落盘之后）实现的那一版：同一个注入点留下
    /// 「marker 已推进、标志丢失」⇒ 下次开门两个析取项都不成立 ⇒ 门关期间越过的页永久丢失。
    func testAGatedRoundWritesTheMoveRecordBeforeTheMarker() async throws {
        let settingKey = "phi.test.b29w"
        let spaceStore = MemorySpaceStore()
        spaceStore.table.hasDrainedFullReplay = true       // 只有 `markerMovedWhileGateShut` 能武装重放
        let markerStore = markerStore(marker: "0")
        markerStore.failSaveOnCallNumber = 1
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([boolSettingsEntity(key: settingKey, true, at: 300, version: 10)],
                                     marker: "10")]
        let first = makeOwnedEngine(client: client, markerStore: markerStore, spaceStore: spaceStore,
                                    settings: boolRegistry(settingKey))
        await first.pullOnce()

        let outcome = await first.lastRoundOutcomeForTesting
        XCTAssertTrue(spaceStore.table.markerMovedWhileGateShut, "标志先落盘")
        XCTAssertEqual(markerStore.file.marker, Data("0".utf8), "marker 仍是入口值")
        XCTAssertEqual(outcome, .cursorSaveFailed)

        markerStore.failSaveOnCallNumber = nil
        let second = makeOwnedEngine(client: client, markerStore: markerStore, spaceStore: spaceStore,
                                     settings: boolRegistry(settingKey))
        await second.pullOnce()
        let secondOutcome = await second.lastRoundOutcomeForTesting
        XCTAssertEqual(secondOutcome, .gated)
        XCTAssertEqual(markerStore.file.marker, Data("10".utf8), "重投同一页，正常收尾")

        await second.setSpaceSyncEnabled(true)
        XCTAssertNil(markerStore.file.marker, "开门：第一个析取项成立 ⇒ 整类型重放")
        XCTAssertTrue(spaceStore.table.drainInProgress)
        XCTAssertFalse(spaceStore.table.markerMovedWhileGateShut)
    }

    /// CASE B2-9 另一半方向 — 标志那次 `mutateSpaceTable` 回 `false` ⇒ 本页**不推** marker、
    /// `.cursorSaveFailed`、`markerMovedWhileGateShut` 仍为 false，且本轮当场早退（第 2 页不再
    /// 试：`saveCalls == 1`）；放行重跑 ⇒ 再次调用（`saveCalls == 2`）并写下标志。
    ///
    /// 第 1 页 `changesRemaining == true` ⇒ 早退的一轮没 drain 完 ⇒ 引擎自己排一轮跟进轮；
    /// `gateGetUpdatesFromCall = 2` 把它停在第一次请求里，放行之后它就是那次「重跑」。
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
        XCTAssertEqual(markerStore.file.marker, Data("0".utf8), "本页不推 marker")
        XCTAssertFalse(spaceStore.table.markerMovedWhileGateShut)
        XCTAssertEqual(spaceStore.saveCalls, 1, "早退：第 2 页没有再试一次")
        XCTAssertTrue(markerStore.saves.isEmpty, "marker 一次都没写")

        await followUpGate.open()                          // 放行重跑（跟进轮）
        await engine.pullOnce()                            // 排在它后面，等它跑完

        XCTAssertEqual(spaceStore.saveCalls, 2, "再次调用")
        XCTAssertTrue(spaceStore.table.markerMovedWhileGateShut)
        XCTAssertEqual(markerStore.file.marker, Data("9".utf8))
    }

    // MARK: - CASE B2-10（引擎半边）

    /// CASE B2-10（引擎半边）— 失败那一轮 `saveCalls` 恰 1（落地那一次，发布段没跑）、
    /// `bookmarksHadRecords` 仍为 false；放行重投之后才置真。store 半边在上面。
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

    // MARK: - CASE B2-12（push 侧游标写失败仍然收敛）

    /// CASE B2-12 — 发布段那一次 `writeOwnedTable` 失败 ⇒ `.cursorSaveFailed`（push 段自己的游标写
    /// 失败也收口）、计数 ≥ 1、**marker 不回退**（它在 pull 段已经推过）；下一轮 pull 把刚提交的
    /// 实体重新投回 ⇒ 按身份命中本机行 ⇒ update 支 ⇒ 行数不增、游标被重建。
    ///
    /// 用 `stored` 模式：commit 写进 `stored` 的那一行正是下一轮要被重投的。入口 marker "0"，
    /// 另种一条远端书签 `b0@50` 让 pull 段真的推进 marker。写序号：落地是第 1 次 ⇒ 发布段是第 2 次。
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
        XCTAssertTrue(advanced, "marker 不回退")
        XCTAssertEqual(markerStore.file.marker, Data("50".utf8))
        XCTAssertEqual(bookmarkCommits(client).count, 1, "那条本机书签的 create 得了 `.applied`")
        let minted = try XCTUnwrap(access.rows.first { $0.guid == "gl" }?.syncId, "身份已认领")
        XCTAssertNil(ownedStore.table.cursors[minted], "发布段那次写没落盘")

        let applyCallsBefore = applyCalls(access)
        await engine.pullOnce()

        let second = await engine.lastRoundOutcomeForTesting
        XCTAssertEqual(second, .ok)
        XCTAssertEqual(access.rows.count, 2, "行数不增（b0 + 本机那条）")
        if applyCalls(access) > applyCallsBefore {
            XCTAssertEqual(createCount(access.lastAppliedOps), 0)
        }
        XCTAssertEqual(ownedStore.table.cursors[minted]?.entityId,
                       client.entityId(forTagHash: bookmarkHash(minted)), "游标被重建")
    }

    // MARK: - CASE B2-13（`.unusable` 不中断 drain）

    /// CASE B2-13 — 第 2 页带一条解不开的设置实体：五页全部取回并落地、请求 marker 依次是
    /// nil / "1" / "2" / "3" / "4"（内存 marker 照推，R-M3-4a-76）、第 2 页之后再没有非 nil 的
    /// marker 写、轮末盘上 marker 为 nil、`.unusableSettings`；设置不发而 `pushOwnedItems` 被调用。
    ///
    /// `drainInProgress` / `hasDrainedFullReplay` 预置为真：前者让 guard 1 不在 marker nil 的入口
    /// 重新武装（否则后者被置假，归属 kind 的发布段在 guard ① 就返回，`loadOwnedTable` 观察不到）。
    /// 抑制中的一轮不跑轮末 drain 收尾，所以两者本轮不变。
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
        XCTAssertNotNil(spaceTable.cursors["u4"]?.reconciled, "第 4 页落地")
        XCTAssertEqual(spaceAccess.spaceMappings.values.filter { $0 == "u4" }.count, 1)
        XCTAssertEqual(counters?.applied, 1, "第 5 页落地")
        XCTAssertEqual(client.getUpdatesCalls.map(\.marker),
                       [nil, Data("1".utf8), Data("2".utf8), Data("3".utf8), Data("4".utf8)])
        XCTAssertEqual(pages, 5)
        XCTAssertEqual(markerStore.saves.first?.marker, Data("1".utf8), "第 1 页照常落盘")
        XCTAssertTrue(markerStore.saves.dropFirst().allSatisfy { $0.marker == nil },
                      "第 2 页之后再没有非 nil 的 marker 写")
        XCTAssertNil(markerStore.file.marker, "轮末盘上 marker 为 nil")
        XCTAssertEqual(outcome, .unusableSettings)
        XCTAssertTrue(settingsCommits(client).isEmpty, "`maySettingsPublish == false`")
        XCTAssertEqual(ownedStore.hadRecordsSeen.count, 2, "`pushOwnedItems` 被调用：发布段的 load 发生过")
        // CASE B2-13 urlrules（Task 6）——那条解不开的设置实体在第 2 页，规则在第 3 页：
        // 「`.unusable` 就地中断 drain」的实现连第 3 页都取不到，这一条落地与它的游标都不会存在。
        let ruleCounters = await engine.lastOwnedRoundCountersForTesting["urlrules"]
        XCTAssertEqual(ruleCounters?.applied, 1, "第 3 页落地")
        XCTAssertEqual(ruleAccess.rows.count, 1)
        XCTAssertEqual(ruleAccess.rows.first?.syncId, "r3")
        XCTAssertEqual(ruleStore.table.cursors["r3"]?.entityId, "srv-r3")
        XCTAssertEqual(ruleStore.hadRecordsSeen.count, 2,
                       "`loadOwnedTable` 一轮两次（轮首 + 发布段），与页数无关")
    }

    // MARK: - CASE B2-14（guard 2 是轮级的；marker 先清、确认之后才烧闩）

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

    /// CASE B2-14 (a) — 本轮**第一次** marker 写就是那个 nil（闩与 marker 之间没有任何别的 marker
    /// 写，也没有页 1 的推进）、本轮就从头拉、三页照常落地、轮末 marker 仍为 nil、
    /// `hasDrainedFullReplay` 仍为 false；下一轮的第一次请求带 nil。
    /// (b) 把 guard 2 放进页循环的那一版让「第一次写是 nil」「轮末 nil」「未 drain」三条同时红。
    func testGuard2IsRoundLevelAndClearsTheMarkerBeforeBurningTheLatch() async throws {
        let f = makeGuard2Fixture()
        let engine = makeOwnedEngine(client: f.client, markerStore: f.markerStore, spaceStore: f.store)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertTrue(f.store.table.didReplayForEmptyTable)
        XCTAssertTrue(f.store.table.drainInProgress)
        XCTAssertFalse(f.store.table.hasDrainedFullReplay)
        XCTAssertEqual(f.markerStore.saves.count, 1, "本轮唯一一次 marker 写")
        XCTAssertNil(f.markerStore.saves.first?.marker, "第一次写就是那个 nil")
        XCTAssertNil(f.client.getUpdatesCalls.first?.marker, "本轮就从头拉")
        XCTAssertEqual(f.client.getUpdatesCalls.count, 3)
        XCTAssertNotNil(f.store.table.cursors["u12"], "三页照常落地")
        XCTAssertNil(f.markerStore.file.marker, "轮末 marker 仍为 nil")
        XCTAssertFalse(f.store.table.hasDrainedFullReplay, "轮末那块因抑制不跑")
        let outcome = await engine.lastRoundOutcomeForTesting
        XCTAssertEqual(outcome, .ok)

        let callsBefore = f.client.getUpdatesCalls.count
        await engine.pullOnce()
        XCTAssertNil(f.client.getUpdatesCalls[callsBefore].marker, "下一轮从 nil 拉")
        XCTAssertTrue(f.store.table.hasDrainedFullReplay, "这一轮没有抑制，drain 正常收尾")
        XCTAssertEqual(f.markerStore.file.marker, Data("13".utf8))
    }

    /// CASE B2-14 (c) — 第 2 页抛网络错 ⇒ 盘上 marker **已经**是 nil（guard 2 的第 1 步就写下了）、
    /// 闩已烧、未 drain；下一轮真的从头重放。把 `storedMarker = nil` 推到轮末的那一版在这里留下
    /// 「闩已烧、marker 未清」，而闩的全仓唯一复位点是 `resetForNewStoreBirthday()`。
    func testGuard2ClearsTheMarkerBeforeTheFirstPageEvenIfALaterPageThrows() async throws {
        let f = makeGuard2Fixture()
        f.client.getUpdatesErrorAfterPages = (pages: 1, error: URLError(.timedOut))
        let engine = makeOwnedEngine(client: f.client, markerStore: f.markerStore, spaceStore: f.store)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let outcome = await engine.lastRoundOutcomeForTesting
        XCTAssertEqual(outcome, .pullFailed)
        XCTAssertNil(f.markerStore.file.marker, "第 1 步就写下了")
        XCTAssertTrue(f.store.table.didReplayForEmptyTable)
        XCTAssertFalse(f.store.table.hasDrainedFullReplay)

        let callsBefore = f.client.getUpdatesCalls.count
        await engine.pullOnce()
        XCTAssertNil(f.client.getUpdatesCalls[callsBefore].marker, "真的从头重放")
        XCTAssertTrue(f.store.table.hasDrainedFullReplay)
    }

    /// CASE B2-14 (d) — `failSaveOnCallNumber = 2`（放过 guard 2 那一次；页 1 被抑制所以退化为
    /// 「不再有写」）+ 第二台引擎重启 ⇒ 重启看到的是 `didReplayForEmptyTable == true` 且 marker
    /// 为 nil、`hasDrainedFullReplay == false`；放行后重启那一轮从头重放并正常收尾。
    func testGuard2LeavesARestartableStateWhenNoLaterMarkerWriteHappens() async throws {
        let f = makeGuard2Fixture()
        f.markerStore.failSaveOnCallNumber = 2
        let first = makeOwnedEngine(client: f.client, markerStore: f.markerStore, spaceStore: f.store)
        await first.setSpaceSyncEnabled(true)
        await first.pullOnce()

        XCTAssertEqual(f.markerStore.saves.count, 1, "页 1 被抑制：不再有写")
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

    /// CASE B2-14 (e) — 两步确认的主探针（R-M3-4a-89）：guard 2 的**第 1 步**就写不成 ⇒
    /// `.cursorSaveFailed`、计数 1、**零页**、**闩没烧**、drain 标志与入口逐字相同、盘上仍是入口值、
    /// 零 commit。放行再拉 ⇒ guard 2 再次命中（判据没被消耗掉）⇒ marker 清成 nil、闩烧掉、三页
    /// 从头重放、`hasDrainedFullReplay` 按抑制规则仍为 false。
    /// (g) 把两次写写回「同一个闭包」或对调两步的那一版在这里让「闩没烧」与「盘上仍是入口值」同时红。
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
        XCTAssertTrue(f.client.getUpdatesCalls.isEmpty, "一次请求都没发生")
        XCTAssertFalse(f.store.table.didReplayForEmptyTable, "闩没烧")
        XCTAssertFalse(f.store.table.drainInProgress, "与入口逐字相同")
        XCTAssertTrue(f.store.table.hasDrainedFullReplay, "与入口逐字相同")
        XCTAssertEqual(f.markerStore.file.marker, Data("10".utf8), "盘上仍是入口值")
        XCTAssertTrue(f.client.commits.isEmpty)

        f.markerStore.failSaveOnCallNumber = nil
        await engine.pullOnce()

        XCTAssertTrue(f.store.table.didReplayForEmptyTable, "guard 2 再次命中")
        XCTAssertNil(f.markerStore.file.marker)
        XCTAssertNil(f.client.getUpdatesCalls.first?.marker)
        XCTAssertEqual(f.client.getUpdatesCalls.count, 3, "三页从头重放")
        XCTAssertFalse(f.store.table.hasDrainedFullReplay, "按抑制规则仍为 false")
    }

    /// CASE B2-14 (f) — 另一半方向：第 1 步成功（盘上 marker 已是 nil）、第 2 步 `mutateSpaceTable`
    /// 回 `false` ⇒ `.cursorSaveFailed`、零页、闩没烧（回滚之后内存与盘一致）、零 commit。放行再拉
    /// ⇒ guard 2 又命中 ⇒ 第 1 步**幂等**（`saves` 不增、计数不增）⇒ 第 2 步这次写成 ⇒ 正常从头重放。
    func testGuard2StepTwoFailureIsRetriedWithAnIdempotentStepOne() async throws {
        let f = makeGuard2Fixture()
        let engine = makeOwnedEngine(client: f.client, markerStore: f.markerStore, spaceStore: f.store)
        await engine.setSpaceSyncEnabled(true)
        f.store.failNextSave = true                        // 门那一次写已经过去了
        await engine.pullOnce()

        let outcome = await engine.lastRoundOutcomeForTesting
        let pages = await engine.lastRoundPagesForTesting
        XCTAssertEqual(outcome, .cursorSaveFailed)
        XCTAssertEqual(pages, 0)
        XCTAssertNil(f.markerStore.file.marker, "第 1 步成功")
        XCTAssertEqual(f.markerStore.saves.count, 1)
        XCTAssertFalse(f.store.table.didReplayForEmptyTable, "回滚之后内存与盘一致")
        XCTAssertTrue(f.client.commits.isEmpty)

        f.store.failNextSave = false
        await engine.pullOnce()

        let second = await engine.lastRoundOutcomeForTesting
        let secondFailures = await engine.lastRoundCursorSaveFailedCountForTesting
        XCTAssertEqual(second, .ok)
        XCTAssertEqual(secondFailures, 0, "第 1 步幂等：不计 `cursorSaveFailures`")
        XCTAssertEqual(f.markerStore.saves.count, 1, "第 1 步幂等：`saves` 不增")
        XCTAssertTrue(f.store.table.didReplayForEmptyTable, "第 2 步这次写成")
        XCTAssertEqual(f.client.getUpdatesCalls.count, 3, "正常从头重放")
        XCTAssertNil(f.client.getUpdatesCalls.first?.marker)
    }

    // MARK: - CASE B2-15（设置 `.absent` 是轮级谓词）

    /// CASE B2-15 — 设置实体只在第 1 页、第 2 至 5 页只有 Space / 书签 / pin / 规则 ⇒
    /// `clearEntityCursor()` 零调用：entity id 键仍是第 1 页写下的那个、`storedLastEntity` 非 nil；
    /// 下一轮 push 走 update（`entityId != nil`、`baseVersion != 0`）。
    ///
    /// 防的是什么：逐页求值 `.absent` 的那一版会在第 5 页命中 `clearEntityCursor()`，把刚建立的
    /// 设置游标丢掉 ⇒ 下一次 push 退化成 `baseVersion == 0` 的 create。规则那一格（Task 6）把
    /// 最后那一页从空页换成一条规则：最后一页带的是**非设置**实体，正是逐页求值那一版会失手的
    /// 那一页。
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
                       "`clearEntityCursor()` 零调用")
        XCTAssertNotNil(defaults.data(forKey: PhiSyncEngine.lastEntityStateKey))
        // CASE B2-15 urlrules（Task 6）——最后一页那条规则真的被取回并落地了（否则「最后一页
        // 不带设置实体」这个前提本身不成立，整条用例会空跑）。
        let ruleCounters = await engine.lastOwnedRoundCountersForTesting["urlrules"]
        XCTAssertEqual(ruleCounters?.applied, 1, "第 5 页落地")
        XCTAssertEqual(ruleAccess.rows.count, 1)
        XCTAssertEqual(ruleAccess.rows.first?.syncId, "r5")
        XCTAssertEqual(ruleStore.table.cursors["r5"]?.entityId, "srv-r5")

        defaults.set(false, forKey: settingKey)             // 本机编辑 ⇒ 下一轮 push
        await engine.pushLocalSettings()

        let last = try XCTUnwrap(settingsCommits(client).last)
        XCTAssertEqual(last.entityId, "srv-set", "走 update")
        XCTAssertNotEqual(last.baseVersion, 0)
    }

    /// CASE B2-15 正面那一半 — 五页一条设置实体都没有 ∧ drained ∧ `startedFromScratch` ∧
    /// `storedEntityId != nil` ⇒ `clearEntityCursor()` 恰好一次（entity id 键变成 nil）。
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

        XCTAssertNil(defaults.string(forKey: PhiSyncEngine.entityIdStateKey), "entity id 键变成 nil")
        XCTAssertEqual(client.getUpdatesCalls.count, 5)
        XCTAssertNil(defaults.string(forKey: PhiSyncEngine.storeBirthdayStateKey),
                     "注入了 marker store 就一个字节都不进 defaults")
    }

    // MARK: - CASE B2-16（跨页归属解析）

    /// CASE B2-16 — 第 2 页同时带一条新 Space 与一条归属于它的书签（路由次序 Space 在前）⇒
    /// 那条书签**本轮落地**、`parked == 0`、`applied == 1`。规则版是下面那条同名用例
    /// （Task 6）。
    ///
    /// 防的是什么：不在页末失效 `ownedMapsThisRound` 的那一版：`classify` 用的是第 1 页那一刻的
    /// `localSpaceIdBySyncUuid` ⇒ `.unresolved` ⇒ 停放，本轮解不开、要等下一轮。
    func testABookmarkOwnedByASpaceLandedOnTheSamePageResolvesThisRound() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess()
        let ownedStore = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.pagesByMarker = [
            page([], marker: "1", changesRemaining: true),        // 第 1 页就算过一次翻译表
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
        XCTAssertEqual(access.rows.first?.spaceId, landedSpaceId, "落在那条刚建出来的 Space 里")
        XCTAssertNil(ownedStore.table.cursors["b2"]?.pendingApply)
    }

    /// CASE B2-16 的规则版（Task 6）— 同一页同时带一条新 Space 与一条 `target_space_uuid` 指向
    /// 它的规则 ⇒ 那条规则**本轮落地**、`parked == 0`、`applied == 1`、行落在那条刚建出来的
    /// Space 里、游标上不留 `pendingApply`。
    ///
    /// 防的是什么：与书签版同一条——不在页末失效 `ownedMapsThisRound` 的那一版拿的是第 1 页那
    /// 一刻的 `localSpaceIdBySyncUuid`，`"u2"` 解析不出 ⇒ 规则被当成「归属还没建出来」停放，本轮
    /// 解不开。规则那一格额外钉的是「停放的是**规则**而不是书签」：它的归属是 `target_space_uuid`
    /// 而不是 `space_uuid`，两条路径各自解析一次。
    func testAURLRuleOwnedByASpaceLandedOnTheSamePageResolvesThisRound() async throws {
        let spaceAccess = makeSpaceAccess()
        let ruleAccess = FakeURLRuleAccess(rows: [])
        let ruleStore = MemoryOwnedItemStore()
        let markerStore = markerStore(marker: "0")
        let client = FakePhiSyncClient()
        client.pagesByMarker = [
            page([], marker: "1", changesRemaining: true),        // 第 1 页就算过一次翻译表
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
        XCTAssertEqual(ruleAccess.rows.first?.spaceId, landedSpaceId, "落在那条刚建出来的 Space 里")
        XCTAssertNil(ruleStore.table.cursors["r2"]?.pendingApply)
        XCTAssertEqual(markerStore.file.marker, Data("3".utf8))
    }

    // MARK: - CASE B2-18（引擎半边）

    /// CASE B2-18（引擎半边）— 门关轮次里标志那次 plist 写失败 ⇒ `.cursorSaveFailed`、marker 不推、
    /// `saveCalls == 1`；第 2 轮假件从同一个 marker 重投同一页 ⇒ **再次看见差异、再次 save**
    /// （`saveCalls == 2`），这次写下 `markerMovedWhileGateShut == true`，只有在它成功之后 marker
    /// 才推进（推进就是内存闩已置的可观察代理）。变体 (a)：第二次也失败 ⇒ marker 仍不推、
    /// `saveCalls == 2`。变体 (b) / (c) 各在 `PhiSyncEngineSpaceTests` /
    /// `SpaceSyncMappingManagerTests`（Task 2a）。
    func testAFailedMoveRecordWriteIsRetriedOnTheReplayedPage() async throws {
        let spaceStore = MemorySpaceStore()
        spaceStore.failSaveOnCallNumber = 1
        let markerStore = markerStore(marker: "0")
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([boolSettingsEntity(key: "phi.test.b218", true, at: 300,
                                                          version: 7)], marker: "7")]
        let engine = makeOwnedEngine(client: client, markerStore: markerStore, spaceStore: spaceStore)
        await engine.pullOnce()                            // 门关着

        let outcome = await engine.lastRoundOutcomeForTesting
        XCTAssertEqual(outcome, .cursorSaveFailed)
        XCTAssertEqual(markerStore.file.marker, Data("0".utf8))
        XCTAssertEqual(spaceStore.saveCalls, 1)
        XCTAssertFalse(spaceStore.table.markerMovedWhileGateShut)

        await engine.pullOnce()

        let second = await engine.lastRoundOutcomeForTesting
        XCTAssertEqual(second, .gated)
        XCTAssertEqual(spaceStore.saveCalls, 2, "再次看见差异、再次 save")
        XCTAssertTrue(spaceStore.table.markerMovedWhileGateShut)
        XCTAssertEqual(markerStore.file.marker, Data("7".utf8), "只有在它成功之后 marker 才推进")
    }

    /// CASE B2-18 变体 (a) — 第二次也失败 ⇒ marker 仍不推、`saveCalls == 2`。
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
        XCTAssertEqual(spaceStore.saveCalls, 2, "两轮各试一次，零内部重试")
        XCTAssertEqual(markerStore.file.marker, Data("0".utf8), "marker 仍不推")
        XCTAssertTrue(markerStore.saves.isEmpty)
        XCTAssertFalse(spaceStore.table.markerMovedWhileGateShut)
    }

    // MARK: - CASE 2b-L1（报损重放的两步之一失败 ⇒ 那条 kind 本轮不发布、不重建文件）

    /// CASE 2b-L1（Task 2b fix round 1，R-M3-4a-103）— 书签游标文件丢失（`bookmarksHadRecords ==
    /// true`）+ 一条本机待发编辑；报损重放的第 ① 步（清 marker）写不成 ⇒ 那一轮**零 `commit`
    /// 调用**、书签 store 没有新写（不重建文件）、`bookmarksReplayedForEmptyTable == false`、
    /// `cursor_save_failed`；下一轮 store 放行 ⇒ 报损再次检测到、marker 清成 nil、闩写下、drain
    /// 武装。Task 6 的 U-18 两条 R-103 变体会为 urlrules 再钉一次。
    ///
    /// 防的是什么：`loadOwnedTable` 的两个失败支回 `(table, false)`，`publishOwnedKind` 里的
    /// `guard !loaded.lost` 放行——不再拦一道的话，发布段会对着**空的**游标表跑快照 → 差分 →
    /// commit（本机那条待发编辑被当成新建发出去），并在末尾 `writeOwnedTable` 写出一份新文件；
    /// 下一轮的 load 不再报损，per-kind 闩再也不会置位，那条 kind 的整类型重放**永久丢失**——
    /// 对着空表发布 + 重建文件把丢失永远藏起来。
    ///
    /// 设置与 Space 两半各自没有东西可发（`storedLastEntity` 预置成空实体 ⇒ `outgoing == last`
    /// 早退；`su-1` 记进 `unreadableTagHashes` ⇒ guard 3 跳过它），于是「零 `commit` 调用」说的
    /// 就是书签那一半。marker 写序号：页 1 的 marker 写是第 1 次，报损重放的第 ① 步是第 2 次。
    func testAFailedLossReplayArmDoesNotPublishAgainstTheLostTableNorRecreateItsFile() async throws {
        let spaceStore = drainedSpaceStore()
        spaceStore.table.bookmarksHadRecords = true
        spaceStore.table.unreadableTagHashes[
            PhiSyncEntity.clientTagHash(for: PhiSyncEntity.spaceClientTag("su-1"))] = 1
        defaults.set(try Phi_PhiSettingEntity().serializedData(),
                     forKey: PhiSyncEngine.lastEntityStateKey)
        let access = FakeBookmarkAccess(rows: [.fixture(guid: "gl", syncId: "bl", spaceId: "s-1",
                                                        title: "Local edit")])
        let ownedStore = MemoryOwnedItemStore()               // 空表 = 游标文件丢了
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
        XCTAssertTrue(client.commits.isEmpty, "零 commit 调用")
        XCTAssertTrue(client.callLog.filter { $0 == "commit" }.isEmpty)
        // 空页对书签一次表写都没有（`applyOwnedKind` 的 `landsEmptyBatch` 早退，
        // `replayedAfterDelete == 0`），而发布段在任何写之前就返回了 ⇒ 零 `save`。
        XCTAssertEqual(ownedStore.saveCalls, 0, "发布段没有写出新文件")
        XCTAssertTrue(ownedStore.table.cursors.isEmpty, "没有游标被写下 ⇒ 下一轮 load 照样报损")
        XCTAssertEqual(ownedStore.hadRecordsSeen, [true, true], "轮首与发布段各报损一次")
        XCTAssertFalse(spaceStore.table.bookmarksReplayedForEmptyTable, "闩没置位")
        XCTAssertFalse(spaceStore.table.drainInProgress, "drain 没武装")
        XCTAssertTrue(spaceStore.table.hasDrainedFullReplay)
        XCTAssertEqual(markerStore.file.marker, Data("7".utf8), "页 1 的 marker 已落盘，清 marker 那一步没成")
        XCTAssertEqual(markerStore.saves.count, 2)

        markerStore.failSaveOnCallNumber = nil
        await engine.pullOnce()

        let second = await engine.lastRoundOutcomeForTesting
        XCTAssertEqual(second, .ok)
        XCTAssertTrue(client.commits.isEmpty, "报损再次检测到 ⇒ 这一轮仍然一条不发")
        XCTAssertNil(markerStore.file.marker, "marker 清成 nil")
        XCTAssertTrue(spaceStore.table.bookmarksReplayedForEmptyTable, "闩写下")
        XCTAssertTrue(spaceStore.table.drainInProgress, "重放武装")
        XCTAssertFalse(spaceStore.table.hasDrainedFullReplay)
        XCTAssertTrue(ownedStore.table.cursors.isEmpty, "仍然没有对着空表发布")
    }

    // MARK: - Task 3b：Space 入站 create 的映射先行（R-M3-4a-87）

    /// 引擎预铸的本机 id（`UUID().uuidString`）从 `.mapSpace` 那条调用里取——**不预设常量**。
    /// 按出现次序返回，所以「铸了几次」就是 `count`。
    private func mintedSpaceIds(_ access: FakePhiSpaceAccess, syncUuid: String) -> [String] {
        access.calls.compactMap {
            if case .mapSpace(let spaceId, let uuid) = $0, uuid == syncUuid { return spaceId }
            return nil
        }
    }

    /// `.create` 的全部调用（含抛错那次——`createError` 是先记调用再抛）。
    private func spaceCreateCalls(_ access: FakePhiSpaceAccess) -> [String] {
        access.calls.compactMap { if case .create(let id) = $0 { return id } else { return nil } }
    }

    /// Space 实体的 commit 条目；设置实体骑在同一个 `commits` 列表上，不是这些用例关心的东西。
    private func spaceCommits(_ client: FakePhiSyncClient) -> [FakePhiSyncClient.CommitCall] {
        client.commits.filter { $0.name == PhiSyncEntity.spaceEntityName }
    }

    /// CASE B2-17neg（负面：旧次序在主探针下必须红；写成注释与一条 ledger 条目，不写第二份
    /// 测试代码）— 把次序写回「先建行、后写映射」之后，下面 B2-17 的 Setup 表达的窗口就变成
    /// 「**行已建、映射未写**」：`create` 成功、进程死在 `mapSpace` 之前。那一版第 2 轮的实际
    /// 走向：`localSpaceId(forSyncUuid:)` 查不到 ⇒ A0 自愈**不触发**（它的前提是「反查命中而行
    /// 不在」，这里反查根本不命中）⇒ 再走一次 create 支 ⇒ `spaces.count == 2`（两条同名 Space）；
    /// 无映射的旧行日后被发布段的 `ensureMapped` 惰性铸一个**自己的**新 uuid ⇒ 账户上多出第二条
    /// 实体（M3-2b 承接的 App-B#2 / #3 / #17）。B2-17 里会红的是三条：「行数 1」、「value 为
    /// `sync-new` 的映射恰一条」与 `.dropSpaceMapping` 的 `contains`。复审照这三条核对即可。
    /// 防的是什么：一个只改注释、代码次序没动的实现通过评审。
    ///
    /// CASE B2-17（主探针：映射已写、行未建、进程死亡 ⇒ 死映射自愈收口；§2.6 三窗口表第 2 行）
    /// — `createError` 让 `create` **先记 `.create` 调用、再抛**（行写发出去了、事务提交前死掉）。
    /// 第 1 轮：`.mapSpace` 的下标小于 `.create` 的下标、`create` 收到的正是预铸的 id、盘上恰一条
    /// 悬空映射、零行、停放不写基线、结局**不是** `cursor_save_failed`（`land` 抛错不是持久化失败，
    /// 本轮那次 `mapSpace` 成功了，裁定 7）⇒ 本页 marker 照推。第 2 轮：假 client 零新页，实体从
    /// `pendingApply` 回到 `all` ⇒ A0 反查命中而 `isKnownLocalSpace` 为假 ⇒ `dropSpaceMapping`
    /// ⇒ 本块再铸一次、干净落地 ⇒ **一条行、一条映射、零第二个 uuid**。
    ///
    /// 自愈里 `dropSpaceMapping` 写失败那一支（它返回 Void、不抛）不写成用例：随后的
    /// `mapSpace(newId2, …)` 撞上 `syncUuidAlreadyClaimed` ⇒ 抛错 ⇒ 停放 ⇒ 再下一轮重试
    /// （裁定 6）；假件的 `dropSpaceMapping` 不可能失败，这一支是一条论证。
    ///
    /// 防的是什么：「映射先行留下的悬空映射没人收口」。一个把两次写反序、却在自愈上失手的实现
    /// （比如给 A0 那个 `if` 加一条 `cursor.reconciled == nil` 的短路）会留下「映射指向一条不存在
    /// 的行」：那个 uuid 从此解析到一个查不到的 id，Space 永远建不出来、指向它的规则永远停放，
    /// 而 `applied` 不涨、`parked` 涨，与「对端还没建 Space」无法区分。
    func testACrashBetweenTheMappingWriteAndTheRowCreateLeavesADanglingMappingThatHealsIntoOneRow() async throws {
        let spaceAccess = makeSpaceAccess([:])                 // 零行、零映射
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
                          "映射先行：`.mapSpace` 在 `.create` 之前，且 `create` 收到的是预铸的 id")
        XCTAssertEqual(spaceAccess.allSpaceMappings(), [newId: "sync-new"], "恰一条悬空映射")
        XCTAssertTrue(spaceAccess.spaces.isEmpty, "零行")
        XCTAssertNotNil(spaceStore.table.cursors["sync-new"]?.pendingApply, "停放")
        XCTAssertNil(spaceStore.table.cursors["sync-new"]?.reconciled, "不写基线")
        XCTAssertNotEqual(outcome, .cursorSaveFailed,
                          "`land` 抛错不是持久化失败；置位点是 `mapSpace` 的 `persistFailed`，本轮那次成功了")
        XCTAssertEqual(markerStore.file.marker, Data("3".utf8), "本页 marker 照推，重投来自停放")

        spaceAccess.createError = nil
        await engine.pullOnce()

        XCTAssertEqual(client.getUpdatesCalls.last?.marker, Data("3".utf8), "假 client 本轮零新页")
        XCTAssertTrue(spaceAccess.calls.contains(.dropSpaceMapping(newId)), "A0 自愈确实跑过")
        XCTAssertEqual(spaceCreateCalls(spaceAccess).count, 2, "第一次抛错那次也记了调用")
        XCTAssertEqual(spaceAccess.spaces.count, 1, "行数 1——整条用例的落点")
        let rowId = try XCTUnwrap(spaceAccess.spaces.first?.spaceId)
        XCTAssertNotEqual(rowId, newId, "自愈之后重铸，不复用悬空的那个 id")
        let mappingsForUuid = spaceAccess.allSpaceMappings().filter { $0.value == "sync-new" }
        XCTAssertEqual(mappingsForUuid.count, 1, "value 为 sync-new 的映射恰一条")
        XCTAssertEqual(mappingsForUuid.keys.first, rowId)
        XCTAssertEqual(spaceAccess.allSpaceMappings().count, 1, "零第二个 uuid、零悬空残留")
        let resolved = try XCTUnwrap(spaceAccess.localSpaceId(forSyncUuid: "sync-new"))
        XCTAssertTrue(spaceAccess.isKnownLocalSpace(resolved))
        XCTAssertNotNil(spaceStore.table.cursors["sync-new"]?.reconciled)
        XCTAssertNil(spaceStore.table.cursors["sync-new"]?.pendingApply)
    }

    /// CASE B2-17a（变体：行已建、游标未写；§2.6 三窗口表第 3 行）— 本页 `writeSpaceTable` 的
    /// save 失败 ⇒ `cursor_save_failed`、marker 不推；假 client 按传进来的 marker 分页，第 2 轮从
    /// 同一个 marker **再发一次同一页** ⇒ `localSpaceId(forSyncUuid:)` 解析得出 ⇒ 新块整个跳过、
    /// `land` 走 update 支：`.create` 仍 1、`.mapSpace` 仍 1（**不铸第二个 uuid**）、行数 1、游标
    /// 这才写下。
    ///
    /// 「走了 update 支」的观察量是第 2 轮的 `.themeState(newId)`：`land` 的 update 支对非默认
    /// Space **无条件**调 `applyThemeState`，而 `update(spaceId:…)` 只在名字 / 颜色 / 图标 / 创建
    /// 时间有差异时才调——重投的是同一页，行是上一轮照它建的，四个字段零差异，`.update` 不会出现。
    ///
    /// 防的是什么：把「映射先行」实现成「每页都重铸一次 `newId` 再 `mapSpace`」（新块的守卫写成
    /// `if !isDefault` 而漏掉 `localSpaceId == nil`）的版本。重投时 `localSpaceId` 已解析得出，本块
    /// 应当整个跳过；跳不过就会撞上 `syncUuidAlreadyClaimed`，把一条本来幂等的 update 变成永久停放。
    func testACrashBetweenTheRowCreateAndTheCursorWriteReplaysThePageThroughTheUpdateBranch() async throws {
        let spaceAccess = makeSpaceAccess([:])
        let spaceStore = drainedSpaceStore()
        let markerStore = markerStore(marker: "0")
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([spaceCreateEntity("sync-new", version: 3)], marker: "3")]
        let engine = makeOwnedEngine(client: client, markerStore: markerStore,
                                     spaceStore: spaceStore, spaceAccess: spaceAccess)
        await engine.setSpaceSyncEnabled(true)
        spaceStore.failNextSave = true                 // 门那一次写已经过去了
        await engine.pullOnce()

        let outcome = await engine.lastRoundOutcomeForTesting
        let advanced = await engine.lastRoundMarkerAdvancedForTesting
        XCTAssertEqual(outcome, .cursorSaveFailed)
        XCTAssertFalse(advanced)
        XCTAssertEqual(markerStore.file.marker, Data("0".utf8), "盘上仍是 markerAtEntry")
        XCTAssertEqual(spaceAccess.spaces.count, 1, "行已建")
        XCTAssertEqual(spaceAccess.allSpaceMappings().count, 1, "映射已写")
        XCTAssertNil(spaceStore.table.cursors["sync-new"], "游标那次写没落盘")
        let newId = try XCTUnwrap(mintedSpaceIds(spaceAccess, syncUuid: "sync-new").first)
        XCTAssertEqual(spaceAccess.spaces.first?.spaceId, newId, "`create` 收到的是预铸的 id")
        let callsAfterFirstRound = spaceAccess.calls.count

        spaceStore.failNextSave = false
        await engine.pullOnce()

        let second = await engine.lastRoundOutcomeForTesting
        let secondRoundCalls = Array(spaceAccess.calls[callsAfterFirstRound...])
        XCTAssertEqual(second, .ok)
        XCTAssertEqual(client.getUpdatesCalls.last?.marker, Data("0".utf8), "同一个 marker 重投同一页")
        XCTAssertEqual(spaceCreateCalls(spaceAccess).count, 1, "第二次没有再建行")
        XCTAssertEqual(mintedSpaceIds(spaceAccess, syncUuid: "sync-new").count, 1, "不铸第二个 uuid")
        XCTAssertEqual(spaceAccess.allSpaceMappings(), [newId: "sync-new"])
        XCTAssertTrue(secondRoundCalls.contains(.themeState(newId)), "重投走 update 支")
        XCTAssertFalse(secondRoundCalls.contains(.dropSpaceMapping(newId)), "行在，自愈不触发")
        XCTAssertEqual(spaceAccess.spaces.count, 1, "行数 1")
        XCTAssertNotNil(spaceStore.table.cursors["sync-new"]?.reconciled)
        XCTAssertNil(spaceStore.table.cursors["sync-new"]?.pendingApply)
        XCTAssertEqual(markerStore.file.marker, Data("3".utf8))
    }

    /// CASE B2-4d-x（交叉核：映射写失败之后什么都不留，且本页重投；与 B2-4d 同一个输入）—
    /// `mapSpaceError = .persistFailed`（在写 `spaceMappings` 之前抛、不自动清空）。第 1 轮：第四个
    /// 置位点 ⇒ `cursor_save_failed`、marker 不推；**零映射、零行**、`.calls` 里既无 `.mapSpace` 也无
    /// `.create`（`land` 根本没被调到）；停放本身已经落盘——置位发生在本页 `writeSpaceTable` 之后，
    /// 那次 save 成功；发布闸是 `canPublishThisRound ∧ !cursorSaveFailed` 的合取，本轮 drain 完了，
    /// 抑制发布的是 `cursorSaveFailed` 这一项。第 2 轮同一个 marker 重投同一页，停放重试与入站实体
    /// 去重（`all = pending.filter { !incoming.contains(uuid) } + incoming`）⇒ `sync-new` 在 `all`
    /// 里只出现一次 ⇒ `.mapSpace` 恰一次、`.create` 恰一次 ⇒ **一映射一行**。
    ///
    /// 防的是什么，一条用例各钉一半：(a) 旧次序下一次 `mapSpace` 失败留下的是一条**无映射的行**
    /// （catch 跑到时 `land` 已经建过行），把新块写在 `land` 之后、或 catch 里忘了 `continue` 的版本
    /// 都会留下它；(b) 把映射写失败**只**当停放、不置 `cursorSaveFailed` 的版本——marker 越过这一页，
    /// 那条 Space 从此只靠 `pendingApply` 存活，一次游标文件丢失就永久丢掉。同时钉死去重：少了那个
    /// `filter`，重投页让同一个 uuid 在 `all` 里出现两次 ⇒ 两次 create ⇒ 两条行。
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
        XCTAssertEqual(outcome, .cursorSaveFailed, "第四个置位点")
        XCTAssertEqual(failures, 1)
        XCTAssertFalse(advanced)
        XCTAssertEqual(markerStore.file.marker, Data("0".utf8), "盘上仍是 markerAtEntry")
        XCTAssertTrue(spaceAccess.allSpaceMappings().isEmpty, "零映射")
        XCTAssertTrue(spaceAccess.spaces.isEmpty, "零行")
        XCTAssertTrue(mintedSpaceIds(spaceAccess, syncUuid: "sync-new").isEmpty, "抛在记调用之前")
        XCTAssertTrue(spaceCreateCalls(spaceAccess).isEmpty, "`land` 没有被调到")
        XCTAssertNotNil(spaceStore.table.cursors["sync-new"]?.pendingApply, "停放本身已经落盘")
        XCTAssertNil(spaceStore.table.cursors["sync-new"]?.reconciled)
        XCTAssertTrue(spaceCommits(client).isEmpty, "发布闸被 cursorSaveFailed 这一项关掉")

        spaceAccess.mapSpaceError = nil
        await engine.pullOnce()

        let second = await engine.lastRoundOutcomeForTesting
        let secondAdvanced = await engine.lastRoundMarkerAdvancedForTesting
        XCTAssertEqual(client.getUpdatesCalls.last?.marker, Data("0".utf8), "同一个 marker 重投同一页")
        XCTAssertEqual(second, .ok)
        XCTAssertTrue(secondAdvanced)
        XCTAssertEqual(markerStore.file.marker, Data("3".utf8))
        XCTAssertEqual(mintedSpaceIds(spaceAccess, syncUuid: "sync-new").count, 1, "`.mapSpace` 恰一次")
        XCTAssertEqual(spaceCreateCalls(spaceAccess).count, 1, "`.create` 恰一次——停放与入站去重成立")
        XCTAssertEqual(spaceAccess.allSpaceMappings().count, 1, "一映射")
        XCTAssertEqual(spaceAccess.spaces.count, 1, "一行")
        XCTAssertNotNil(spaceStore.table.cursors["sync-new"]?.reconciled)
        XCTAssertNil(spaceStore.table.cursors["sync-new"]?.pendingApply)
    }
}

private extension PhiSyncEngineTests.FakePhiSyncClient {
    /// 「重收不产出出站 tombstone」：commits 里没有任何一条 `deleted` 条目。
    func commitsAreFreeOfOutboundTombstones() -> Bool {
        !commits.contains { $0.deleted }
    }
}

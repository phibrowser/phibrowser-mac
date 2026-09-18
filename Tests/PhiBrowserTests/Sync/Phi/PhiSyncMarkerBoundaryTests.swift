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

    private var defaults: UserDefaults!
    private var suiteName: String!
    private let key = SymmetricKey(size: .bits256)
    private var scratchAccounts: [Account] = []

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
        super.tearDown()
    }

    // MARK: - Helpers

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
}

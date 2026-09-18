import CryptoKit
import Foundation
import XCTest
@testable import Phi

/// 8b-1 的用例（spec §12.1「URL Rule」块里的 M-* 系列，D30 的第一段）：纯谓词级
/// （M-28 / M-29 / M-30，直接调 `URLRuleKind` 上的三个静态函数）与假件级（M-1 / M-2 / M-2b /
/// M-8 / M-8b / M-9 / M-11 / M-13 / M-14 / M-18 / M-20，真引擎 + `FakeURLRuleAccess` + 内存 store，
/// 驱动入口只用 `pullOnce()`）。M-31 在 `PhiOwnedItemStateTests`、M-32 在
/// `LocalStoreURLRuleThrowingTests`（真 `LocalStore`）。
///
/// 类标 `@MainActor` 与 `SyncableOwnedItemsTests.swift:11-12` 同款理由：要构造 `@MainActor` 假件。
///
/// **两条口径贯穿全文：**
/// - 远端戳一律取 `Self.remoteStamp`（比 fixture 行的 `createdDate` 新），于是 §8.2 的无基线合并
///   里远端赢下三个单元、合并结果 == 入站实体、零 `mustRepublish`——`pushed == 0` 的断言只说
///   认领这一件事，不混进「本机赢了字段要重新发布」那条正当的推送。
/// - 同一桶里的几条到达 rank 各不相同且按到达序递增（`V` / `W` / `X`），于是认领之后的
///   `sortOrder` 序与基线 rank 序一致，出站快照沿用基线 rank、不铸新的。
@MainActor
final class URLRuleMergeTests: XCTestCase {
    typealias FakePhiSyncClient = PhiSyncEngineTests.FakePhiSyncClient
    typealias StubDomainKeys = PhiSyncEngineTests.StubDomainKeys
    typealias MemorySpaceStore = PhiSyncEngineSpaceTests.MemorySpaceStore

    private struct Boom: Error {}

    private let resolve = OwnerResolver.fixture()
    private let normalize = URLRuleSignatureQueries.normalize

    private var defaults: UserDefaults!
    private var suiteName: String!
    private let key = SymmetricKey(size: .bits256)
    /// 8b-2 的 CASE M2-d 那几条真 `LocalStore` 用例开出来的临时目录。**只删自己建的那些**。
    private var mergeTempDirectories: [URL] = []

    private static let now: Int64 = 1_700_000_000_000
    /// 见文件头：比 `PhiLocalURLRule.fixture()` 的 `createdDate`（1_000 s ⇒ 1_000_000 ms）新。
    private static let remoteStamp: Int64 = 5_000_000

    override func setUp() {
        super.setUp()
        suiteName = "URLRuleMergeTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        for directory in mergeTempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        mergeTempDirectories.removeAll()
        super.tearDown()
    }

    // MARK: - 脚手架（形状照 `URLRuleKindTests` 的 Task 6 段）

    /// 一台已经配过对的机器：`space-a/b/c → su-1/2/3`，与 `OwnerResolver.fixture()` 同一套本机 id。
    private func makeSpaceAccess() -> FakePhiSpaceAccess {
        let access = FakePhiSpaceAccess()
        let mappings = ["space-a": "su-1", "space-b": "su-2", "space-c": "su-3"]
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

    /// `hasDrainedFullReplay` 预置为真：发布侧的 guard ① 不挡路，设置段与 Space 段静默。
    private func drainedSpaceStore() throws -> MemorySpaceStore {
        let store = MemorySpaceStore()
        store.table.hasDrainedFullReplay = true
        try silenceOtherSections(store)
        return store
    }

    /// 让设置段与 Space 段这一轮都没有东西可发（照 `URLRuleKindTests.silenceOtherSections`），
    /// 于是 `client.commits` 说的就是规则那一半。
    private func silenceOtherSections(_ spaceStore: MemorySpaceStore) throws {
        for uuid in ["su-1", "su-2", "su-3"] {
            spaceStore.table.unreadableTagHashes[
                PhiSyncEntity.clientTagHash(for: PhiSyncEntity.spaceClientTag(uuid))] = 1
        }
        defaults.set(try Phi_PhiSettingEntity().serializedData(),
                     forKey: PhiSyncEngine.lastEntityStateKey)
    }

    private func markerStore(marker: String?) -> MemoryMarkerStore {
        MemoryMarkerStore(file: PhiSyncMarkerFile(marker: marker.map { Data($0.utf8) },
                                                  storeBirthday: "birthday-1"))
    }

    private func makeEngine(client: FakePhiSyncClient,
                            markerStore: any PhiSyncMarkerStore,
                            spaceStore: any PhiSpaceSyncStateStore,
                            ownedKinds: [OwnedKindRegistration]) -> PhiSyncEngine {
        PhiSyncEngine(domainKeys: StubDomainKeys(key: key), client: client,
                      defaults: defaults, deviceKeyId: "devA", settings: [],
                      spaceAccess: makeSpaceAccess(), spaceStore: spaceStore,
                      markerStore: markerStore, ownedKinds: ownedKinds,
                      now: { Self.now })
    }

    private func ruleTag(_ uuid: String) -> String { PhiSyncEntity.urlRuleClientTag(uuid) }

    private func ruleHash(_ uuid: String) -> String {
        PhiSyncEntity.clientTagHash(for: ruleTag(uuid))
    }

    private func ruleEntity(_ payload: Phi_PhiURLRuleEntity, version: Int64) -> PhiRemoteEntity {
        remoteEntity(envelope(payload), tag: ruleTag(payload.ruleUuid), version: version,
                     entityId: "srv-\(payload.ruleUuid)", key: key)
    }

    /// 一条远端实体，三枚戳都是 `remoteStamp`（见文件头）。
    private func remote(uuid: String, target: String = "su-1", host: String = "github.com",
                        pathPrefix: String = "", rank: String = "V") -> Phi_PhiURLRuleEntity {
        urlRulePayload(uuid: uuid, targetSpaceUuid: target, host: host, pathPrefix: pathPrefix,
                       rank: rank, contentStamp: Self.remoteStamp, targetStamp: Self.remoteStamp,
                       rankStamp: Self.remoteStamp)
    }

    private func ruleCommits(_ client: FakePhiSyncClient) -> [FakePhiSyncClient.CommitCall] {
        client.commits.filter { $0.name == PhiSyncEntity.urlRuleEntityName }
    }

    /// 一条**活**的已发布游标：`server == reconciled`、有服务端三元组、归属已知。
    private func publishedRuleCursor(_ payload: Phi_PhiURLRuleEntity,
                                     entityId: String = "srv-1", version: Int64 = 1,
                                     owner: String = "su-1") -> PhiOwnedItemCursor {
        ownedCursor(reconciled: baselineBytes(payload), server: baselineBytes(payload),
                    entityId: entityId, version: version, ownerUuid: owner)
    }

    private func createCount(_ ops: [URLRuleSyncOp]) -> Int {
        ops.filter { if case .create = $0 { return true } else { return false } }.count
    }

    private func rekeyCount(_ ops: [URLRuleSyncOp]) -> Int {
        ops.filter { if case .rekey = $0 { return true } else { return false } }.count
    }

    private func claimNotes(_ access: FakeURLRuleAccess) -> [Int] {
        access.calls.compactMap { if case .notePersistedClaims(let count) = $0 { return count } else { return nil } }
    }

    private func counters(_ engine: PhiSyncEngine) async -> OwnedRoundCounters? {
        await engine.lastOwnedRoundCountersForTesting["urlrules"]
    }

    private func isAtRest(_ row: PhiLocalURLRule, _ cursor: PhiOwnedItemCursor?,
                          tombstones: Set<String> = []) -> Bool {
        URLRuleKind.isAtRest(row: row, cursor: cursor, resolve: resolve, normalize: normalize,
                             tombstonesThisPage: tombstones)
    }

    // MARK: - CASE M-1（首次同步认领）

    /// 防的是什么：「删旧建新」的实现让那一行短暂没有身份或产生第二条行，而 §5.7 的差分对
    /// 「有游标、无本机行」的回答是发一条 tombstone。
    func testM1_firstSyncClaimsTheLocalRowByReKeyingIt() async throws {
        let access = FakeURLRuleAccess(rows: [.fixture(id: "i1", syncId: "local-a", host: "github.com")])
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([ruleEntity(remote(uuid: "remote-b"), version: 7)], marker: "7")]
        let engine = makeEngine(client: client, markerStore: markerStore(marker: "0"),
                                spaceStore: try drainedSpaceStore(),
                                ownedKinds: [.urlRules(access: access, store: store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        // ① 那一行被 re-key，`id` 不变，没有第二条行。
        XCTAssertEqual(access.rows.count, 1)
        XCTAssertEqual(access.rows.first?.id, "i1")
        XCTAssertEqual(access.rows.first?.syncId, "remote-b")
        XCTAssertEqual(rekeyCount(access.lastAppliedOps), 1)
        XCTAssertEqual(createCount(access.lastAppliedOps), 0)
        // ② 旧游标整条不在，新身份有基线与服务端三元组。
        XCTAssertNil(store.table.cursors["local-a"])
        XCTAssertNotNil(store.table.cursors["remote-b"]?.reconciled)
        XCTAssertEqual(store.table.cursors["remote-b"]?.entityId, "srv-remote-b")
        XCTAssertEqual(store.table.cursors["remote-b"]?.version, 7)
        // ③
        let first = await counters(engine)
        XCTAssertEqual(first?.adopted, 1)
        XCTAssertEqual(first?.applied, 1)
        XCTAssertTrue(ruleCommits(client).isEmpty, "远端赢下三个单元 ⇒ 没有什么要重新发布")

        // ④ 再跑一轮：零推送、零 tombstone。
        await engine.pullOnce()
        let second = await counters(engine)
        XCTAssertEqual(second?.pushed, 0)
        XCTAssertEqual(second?.tombstones, 0)
        XCTAssertTrue(ruleCommits(client).isEmpty)
        XCTAssertEqual(access.rows.first?.syncId, "remote-b")
    }

    /// ⑤ 一个事务：落地抛 ⇒ 行的 `syncId` 仍是旧值、旧游标状态一个字节不变（表里本来就没有
    /// 它）、新身份没有基线（停放）。防的是什么：先删旧游标再落地的实现在这里留下一条「行没改、
    /// 游标没了」的中间态，那条身份下一轮以 `baseVersion == 0` 的 create 盲写覆盖账户。
    /// 末尾多跑一轮：停放项重试时走同一条认领通路（定义域是「到达 ∪ 停放」），收敛到 ①。
    func testM1_aFailedLandingLeavesTheRowOnItsOldIdentityAndWritesNoBaseline() async throws {
        let access = FakeURLRuleAccess(rows: [.fixture(id: "i1", syncId: "local-a", host: "github.com")])
        access.failApplyOnce = true
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([ruleEntity(remote(uuid: "remote-b"), version: 7)], marker: "7")]
        let engine = makeEngine(client: client, markerStore: markerStore(marker: "0"),
                                spaceStore: try drainedSpaceStore(),
                                ownedKinds: [.urlRules(access: access, store: store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertEqual(access.rows.count, 1)
        XCTAssertEqual(access.rows.first?.syncId, "local-a")
        XCTAssertNil(store.table.cursors["local-a"], "从没有过，也没被写出来")
        XCTAssertNil(store.table.cursors["remote-b"]?.reconciled, "没有基线")
        XCTAssertNotNil(store.table.cursors["remote-b"]?.pendingApply, "整批停放")
        let first = await counters(engine)
        XCTAssertEqual(first?.parked, 1)
        XCTAssertEqual(first?.applied, 0)

        await engine.pullOnce()
        XCTAssertEqual(access.rows.count, 1)
        XCTAssertEqual(access.rows.first?.id, "i1")
        XCTAssertEqual(access.rows.first?.syncId, "remote-b", "停放重试走同一条认领通路")
        XCTAssertNotNil(store.table.cursors["remote-b"]?.reconciled)
        XCTAssertNil(store.table.cursors["remote-b"]?.pendingApply)
        let second = await counters(engine)
        XCTAssertEqual(second?.adopted, 1)
    }

    // MARK: - CASE M-2（认领拒绝：已有基线）

    /// 防的是什么：只判「游标不存在」的实现会 re-key 一条有基线的行并按第 4 步把带基线的旧游标
    /// 整条删掉 ⇒ 基线销毁、旧身份那条账户实体变成谁都删不掉的孤儿。
    /// ③（第二轮两条都静止 ⇒ `syncId` 较大的那条被软删、`collapsed == 1`）是 **8b-2** 的断言，
    /// 这里只写到 ②，`collapsed` 留占位。
    func testM2_aRowWithABaselineIsNotClaimable() async throws {
        let access = FakeURLRuleAccess(rows: [.fixture(id: "i1", syncId: "local-a", host: "github.com")])
        let store = MemoryOwnedItemStore()
        let published = urlRulePayload(uuid: "local-a")
        store.table.cursors["local-a"] = publishedRuleCursor(published, entityId: "e-a", version: 3)
        let client = FakePhiSyncClient()
        // 账户上真有这条实体：假 client 的更新路径按 `entityId` / `baseVersion` 认它。
        client.seed(tagHash: ruleHash("local-a"), ciphertext: Data(), version: 3, entityId: "e-a")
        client.pagesByMarker = [page([ruleEntity(remote(uuid: "remote-b", rank: "W"), version: 7)],
                                     marker: "7")]
        let engine = makeEngine(client: client, markerStore: markerStore(marker: "0"),
                                spaceStore: try drainedSpaceStore(),
                                ownedKinds: [.urlRules(access: access, store: store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        // ① 第一轮：零认领，入站实体作为第二条行落地。
        let first = await counters(engine)
        XCTAssertEqual(first?.adopted, 0)
        XCTAssertEqual(access.rows.count, 2)
        XCTAssertEqual(access.rows.first { $0.id == "i1" }?.syncId, "local-a")
        XCTAssertEqual(createCount(access.lastAppliedOps), 1)
        XCTAssertEqual(rekeyCount(access.lastAppliedOps), 0)
        // ② 刚落地那条身份的游标要到 `land` 返回之后才写下，静止判据 1 本轮不成立（R-M3-4a-67）。
        XCTAssertEqual(first?.collapsed, 0)
        // ④ 已发布实体的游标完好：基线还在，没有被当成「旧游标」整条删掉。
        XCTAssertEqual(store.table.cursors["local-a"]?.entityId, "e-a")
        XCTAssertNotNil(store.table.cursors["local-a"]?.reconciled)
        XCTAssertNil(store.table.cursors["local-a"]?.deletedAtMs)

        await engine.pullOnce()
        // ③（8b-2）：第二轮两条都静止 ⇒ `syncId` 字典序较大的 `"remote-b"` 被软删、
        // `collapsed == 1`，胜者 `"local-a"` 那条**已发布实体**一个字节不动。
        let second = await counters(engine)
        XCTAssertEqual(second?.collapsed, 1)
        XCTAssertNil(store.table.cursors["local-a"]?.deletedAtMs, "胜者的游标不动")
        XCTAssertNil(access.rows.first { $0.syncId == "local-a" }?.deletedDate)
        XCTAssertNotNil(access.rows.first { $0.syncId == "remote-b" }?.deletedDate, "败者软删")
        XCTAssertEqual(access.rows.first { $0.syncId == "remote-b" }?.mergePartnerSyncId, "local-a")
        XCTAssertEqual(access.rows.filter { $0.deletedDate == nil }.count, 1, "收敛之后一条活行")
    }

    // MARK: - CASE M-2b（birthday 重置留下的游标不可认领）

    /// 防的是什么：只看前两个合取项（`entityId.isEmpty && server == nil`）的实现会让一次 birthday
    /// 重置之后**每一条**规则游标都可认领 ⇒ 任何同签名的入站实体都能 re-key 那一行、再把带基线的
    /// 旧游标删掉。R-exec-13 的补键判据正是这种形状的镜像。
    ///
    /// 第 2 页的请求抛出去，让本轮止于 pull（无 push）：发布段的补键通路本来就会为这种形状的
    /// 游标经 client tag 重新认一次身份并收割三元组，那是它的正当行为，但会遮住「认领 pre-pass
    /// 一个字节都没动它」这条断言。
    func testM2b_aBirthdayResetCursorIsNotClaimable() async throws {
        let access = FakeURLRuleAccess(rows: [.fixture(id: "i1", syncId: "local-a", host: "github.com")])
        let store = MemoryOwnedItemStore()
        let reset = ownedCursor(reconciled: baselineBytes(urlRulePayload(uuid: "local-a")),
                                ownerUuid: "su-1")
        XCTAssertEqual(reset.entityId, "")
        XCTAssertEqual(reset.version, 0)
        XCTAssertNil(reset.server)
        store.table.cursors["local-a"] = reset
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([ruleEntity(remote(uuid: "remote-b", rank: "W"), version: 7)],
                                     marker: "7", changesRemaining: true)]
        client.getUpdatesErrorAfterPages = (pages: 1, error: Boom())
        let engine = makeEngine(client: client, markerStore: markerStore(marker: "0"),
                                spaceStore: try drainedSpaceStore(),
                                ownedKinds: [.urlRules(access: access, store: store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let first = await counters(engine)
        XCTAssertEqual(first?.adopted, 0)
        XCTAssertEqual(store.table.cursors["local-a"], reset, "一个字节都没动")
        XCTAssertEqual(access.rows.first { $0.id == "i1" }?.syncId, "local-a")
        XCTAssertEqual(access.rows.count, 2, "入站实体作为第二条行落地")
        XCTAssertEqual(rekeyCount(access.lastAppliedOps), 0)
    }

    // MARK: - CASE M-8（签名按归一化后的值比）

    /// 防的是什么：按未归一化的字节比签名的实现把两条同一规则判成两条；线上 `path_prefix` 的
    /// `""` 与本机 nil 不互转的实现同样在这里红。
    func testM8_signaturesCompareNormalizedValues() async throws {
        let access = FakeURLRuleAccess(rows: [
            .fixture(id: "i1", syncId: "local-a", host: "GitHub.com.", pathPrefix: nil),
        ])
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([ruleEntity(remote(uuid: "remote-b", host: "github.com",
                                                        pathPrefix: ""), version: 7)],
                                     marker: "7")]
        let engine = makeEngine(client: client, markerStore: markerStore(marker: "0"),
                                spaceStore: try drainedSpaceStore(),
                                ownedKinds: [.urlRules(access: access, store: store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let first = await counters(engine)
        XCTAssertEqual(first?.adopted, 1)
        XCTAssertEqual(access.rows.count, 1)
        XCTAssertEqual(access.rows.first?.syncId, "remote-b")
        XCTAssertEqual(access.rows.first?.host, "github.com", "落地写的是归一化之后的值")
    }

    /// 负面同批：路径相同、**目标不同** ⇒ 冲突不是重复，两条行都留着（交给 §9 的裁决键）。
    func testM8_aDifferentTargetIsAConflictNotADuplicate() async throws {
        let access = FakeURLRuleAccess(rows: [
            .fixture(id: "i1", syncId: "local-a", host: "GitHub.com.", pathPrefix: nil),
        ])
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([ruleEntity(remote(uuid: "remote-b", target: "su-2",
                                                        host: "github.com"), version: 7)],
                                     marker: "7")]
        let engine = makeEngine(client: client, markerStore: markerStore(marker: "0"),
                                spaceStore: try drainedSpaceStore(),
                                ownedKinds: [.urlRules(access: access, store: store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let first = await counters(engine)
        XCTAssertEqual(first?.adopted, 0)
        XCTAssertEqual(access.rows.filter { $0.deletedDate == nil }.count, 2)
        XCTAssertEqual(access.rows.first { $0.id == "i1" }?.syncId, "local-a")
        XCTAssertEqual(access.rows.first { $0.syncId == "remote-b" }?.spaceId, "space-b")
    }

    // MARK: - CASE M-8b（签名的 owner 是账户级的量）

    /// 防的是什么：把 `signatureIndex` 改成按本机 `spaceId` 建键的实现在第一段红（两个键空间，永不
    /// 命中，认领整条静默失效）；把保留常量排除在签名之外的实现在第二段红。
    func testM8b_signatureOwnerIsTheAccountLevelUuid() async throws {
        let access = FakeURLRuleAccess(rows: [.fixture(id: "i1", syncId: "local-a", spaceId: "space-a")])
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([ruleEntity(remote(uuid: "remote-b", target: "su-1"), version: 7)],
                                     marker: "7")]
        let engine = makeEngine(client: client, markerStore: markerStore(marker: "0"),
                                spaceStore: try drainedSpaceStore(),
                                ownedKinds: [.urlRules(access: access, store: store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let first = await counters(engine)
        XCTAssertEqual(first?.adopted, 1)
        XCTAssertEqual(access.rows.count, 1)
        XCTAssertEqual(access.rows.first?.syncId, "remote-b")
    }

    func testM8b_theReservedIncognitoConstantIsASignatureOwnerToo() async throws {
        let access = FakeURLRuleAccess(rows: [
            .fixture(id: "i1", syncId: "local-a", spaceId: SpaceManager.incognitoRuleTargetId),
        ])
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([ruleEntity(remote(uuid: "remote-b",
                                                        target: SyncableSpaces.incognitoSpaceUuid),
                                                 version: 7)],
                                     marker: "7")]
        let engine = makeEngine(client: client, markerStore: markerStore(marker: "0"),
                                spaceStore: try drainedSpaceStore(),
                                ownedKinds: [.urlRules(access: access, store: store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let first = await counters(engine)
        XCTAssertEqual(first?.adopted, 1)
        XCTAssertEqual(access.rows.count, 1)
        XCTAssertEqual(access.rows.first?.syncId, "remote-b")
        XCTAssertEqual(access.rows.first?.spaceId, SpaceManager.incognitoRuleTargetId)
    }

    // MARK: - CASE M-9（停放 / 待删 / 补键 / 停着 tombstone 的成员不静止）

    /// 防的是什么：漏掉判据 5 的实现会把一条停着远端 tombstone 的行选成胜者 ⇒ 它吸收败者、软删
    /// 败者并真的发出败者的 tombstone，而它自己进不了 `snapshot` ⇒ 下一轮它也被硬删 ⇒ 该签名组
    /// 在两台与账户上全部为零。漏掉判据 9 的实现让补键态成员被淘汰。`collapsed` 是 8b-2 的。
    func testM9_parkedPendingDeleteUnkeyedAndPendingTombstoneMembersAreNotAtRest() {
        let a = PhiLocalURLRule.fixture(id: "ia", syncId: "a", sortOrder: 0)
        let b = PhiLocalURLRule.fixture(id: "ib", syncId: "b", sortOrder: 1)
        let cursorA = publishedRuleCursor(urlRulePayload(uuid: "a"), entityId: "srv-a")
        let baseB = publishedRuleCursor(urlRulePayload(uuid: "b", rank: "W"), entityId: "srv-b")
        XCTAssertTrue(isAtRest(a, cursorA))
        XCTAssertTrue(isAtRest(b, baseB), "基准：两条都静止")

        var parked = baseB
        parked.pendingApply = Data([0x01])
        var pendingDelete = baseB
        pendingDelete.pendingDelete = true
        var unkeyed = baseB
        unkeyed.entityId = ""
        var pendingTombstone = baseB
        pendingTombstone.pendingTombstone = true

        for (label, variant) in [("(a) pendingApply", parked), ("(b) pendingDelete", pendingDelete),
                                 ("(c) 补键态", unkeyed), ("(d) pendingTombstone", pendingTombstone)] {
            XCTAssertTrue(isAtRest(a, cursorA), label)
            XCTAssertFalse(isAtRest(b, variant), label)
        }
        // (c) 里 `b` 仍然满足 `PhiSyncEngine` 的 `unkeyed` 候选判据（补键没有被绕过）。
        XCTAssertTrue(unkeyed.entityId.isEmpty && unkeyed.reconciled != nil
                      && unkeyed.deletedAtMs == nil && unkeyed.pendingApply == nil
                      && !unkeyed.pendingDelete && (unkeyed.rekeyRejectRounds ?? 0) < 3)
    }

    // MARK: - CASE M-11（V11 回填 + 两台首次同步）

    /// 防的是什么：把 M1 放进 `ownedItemsPublishAllowed` 闸后面的实现在 ① 上红（首次 drain 里那道闸
    /// 为假）——那正是 §12.2 第 13d 步点名的「`adopted` 是 0 而规则数变成 4」。这一条同时是 D30(a)
    /// 在真实升级路径上的验收。
    func testM11_aFreshDeviceClaimsAllThreeBackfilledRowsDuringItsFirstDrain() async throws {
        let access = FakeURLRuleAccess(rows: [
            .fixture(id: "i1", syncId: "local-1", host: "a.example", sortOrder: 0),
            .fixture(id: "i2", syncId: "local-2", host: "b.example", sortOrder: 1),
            .fixture(id: "i3", syncId: "local-3", host: "c.example", sortOrder: 2),
        ])
        let store = MemoryOwnedItemStore()
        // 首次 drain：`hasDrainedFullReplay == false`，`setSpaceSyncEnabled(true)` 武装 drain。
        let spaceStore = MemorySpaceStore()
        try silenceOtherSections(spaceStore)
        let client = FakePhiSyncClient()
        let arrivals = [remote(uuid: "acc-1", host: "a.example", rank: "V"),
                        remote(uuid: "acc-2", host: "b.example", rank: "W"),
                        remote(uuid: "acc-3", host: "c.example", rank: "X")]
        for (offset, entity) in arrivals.enumerated() {
            client.seed(tagHash: ruleHash(entity.ruleUuid), ciphertext: Data(), version: Int64(offset + 1),
                        entityId: "srv-\(entity.ruleUuid)")
        }
        client.pagesByMarker = [page(arrivals.enumerated().map { ruleEntity($1, version: Int64($0 + 1)) },
                                     marker: "3")]
        let engine = makeEngine(client: client, markerStore: markerStore(marker: "0"),
                                spaceStore: spaceStore,
                                ownedKinds: [.urlRules(access: access, store: store)])
        await engine.setSpaceSyncEnabled(true)
        XCTAssertFalse(spaceStore.table.hasDrainedFullReplay, "认领跑在 drain 排干之前")
        await engine.pullOnce()

        let first = await counters(engine)
        XCTAssertEqual(first?.adopted, 3)
        XCTAssertEqual(access.rows.count, 3)
        XCTAssertEqual(access.rows.first { $0.id == "i1" }?.syncId, "acc-1")
        XCTAssertEqual(access.rows.first { $0.id == "i2" }?.syncId, "acc-2")
        XCTAssertEqual(access.rows.first { $0.id == "i3" }?.syncId, "acc-3")
        for retired in ["local-1", "local-2", "local-3"] {
            XCTAssertNil(store.table.cursors[retired], "旧游标 \(retired) 整条不在")
        }
        for adopted in ["acc-1", "acc-2", "acc-3"] {
            XCTAssertNotNil(store.table.cursors[adopted]?.reconciled)
        }
        XCTAssertEqual(first?.pushed, 0)
        XCTAssertEqual(first?.tombstones, 0)

        await engine.pullOnce()
        let second = await counters(engine)
        XCTAssertEqual(second?.pushed, 0)
        XCTAssertEqual(second?.tombstones, 0)
        XCTAssertTrue(ruleCommits(client).isEmpty)
        XCTAssertEqual(client.stored.count, 3, "账户上恰好 3 条")
        XCTAssertTrue(client.stored.values.allSatisfy { !$0.deleted })
    }

    // MARK: - CASE M-13（1:1 配对）

    /// 防的是什么：不做 1:1 的实现会产出两条 `.claim` 指向同一条行 ⇒ 第二次 re-key 的守卫必然不
    /// 成立 ⇒ 抛 ⇒ 整批回滚、全部留在 `pendingApply`、同一页每轮重放每轮抛，marker 永不推进（B-2）。
    func testM13_twoSameSignatureArrivalsClaimOneRowAndCreateTheOther() async throws {
        let access = FakeURLRuleAccess(rows: [.fixture(id: "i1", syncId: "local-a")])
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        let marker = markerStore(marker: "0")
        client.pagesByMarker = [page([ruleEntity(remote(uuid: "r-2", rank: "W"), version: 6),
                                      ruleEntity(remote(uuid: "r-1", rank: "V"), version: 7)],
                                     marker: "7")]
        let engine = makeEngine(client: client, markerStore: marker,
                                spaceStore: try drainedSpaceStore(),
                                ownedKinds: [.urlRules(access: access, store: store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let first = await counters(engine)
        XCTAssertEqual(first?.adopted, 1)
        XCTAssertEqual(access.rows.first { $0.id == "i1" }?.syncId, "r-1", "字典序第一")
        XCTAssertEqual(access.rows.count, 2)
        XCTAssertNotNil(access.rows.first { $0.syncId == "r-2" }, "另一条作为第二条行落地")
        XCTAssertEqual(rekeyCount(access.lastAppliedOps), 1)
        XCTAssertEqual(createCount(access.lastAppliedOps), 1)
        XCTAssertEqual(first?.refused, 0, "零抛出")
        XCTAssertEqual(first?.parked, 0)
        XCTAssertEqual(first?.applied, 2)
        XCTAssertEqual(marker.file.marker, Data("7".utf8), "marker 正常推进")
    }

    /// 对称变体：一条 arrival + 两条可认领的本机行 ⇒ 按本机 `syncId` 字典序取第一条，另一条不动。
    func testM13_oneArrivalAgainstTwoClaimableRowsClaimsTheFirstBySyncId() async throws {
        let access = FakeURLRuleAccess(rows: [
            .fixture(id: "i2", syncId: "local-b", sortOrder: 0),
            .fixture(id: "i1", syncId: "local-a", sortOrder: 1),
        ])
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([ruleEntity(remote(uuid: "r-1"), version: 7)], marker: "7")]
        let engine = makeEngine(client: client, markerStore: markerStore(marker: "0"),
                                spaceStore: try drainedSpaceStore(),
                                ownedKinds: [.urlRules(access: access, store: store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let first = await counters(engine)
        XCTAssertEqual(first?.adopted, 1)
        XCTAssertEqual(access.rows.count, 2)
        XCTAssertEqual(access.rows.first { $0.id == "i1" }?.syncId, "r-1", "`local-a` < `local-b`")
        let other = access.rows.first { $0.id == "i2" }
        XCTAssertEqual(other?.syncId, "local-b")
        XCTAssertEqual(other?.id, "i2")
        XCTAssertNil(store.table.cursors["local-a"])
        XCTAssertNil(store.table.cursors["local-b"], "没被认领的那条本来就没有游标，也没被建出来")
    }

    // MARK: - CASE M-14（没有签名的行是惰性的）

    /// 防的是什么：把 nil owner 退化成 `""` / 本机 `spaceId` 的实现、以及只判第一道门的实现都在
    /// 这里红——后者让 (c) 那条行「有签名却进不了 `snapshot`」。
    func testM14_rowsWithoutASignatureAreInert() async throws {
        // (a) 两个不同的 agent Space（没有映射 ⇒ `eligibilityOwner` nil）；
        // (b) 过期的 incognito 运行期 id（R-M3-4a-8）。
        let stale = SpaceManager.incognitoRuleTargetId + ".stale-runtime"
        let segments: [(label: String, rows: [PhiLocalURLRule])] = [
            ("(a) agent", [.fixture(id: "i1", syncId: "local-a", spaceId: "agent-space-1"),
                           .fixture(id: "i2", syncId: "local-b", spaceId: "agent-space-2")]),
            ("(b) stale incognito", [.fixture(id: "i1", syncId: "local-a", spaceId: stale),
                                     .fixture(id: "i2", syncId: "local-b", spaceId: "agent-space-2")]),
        ]
        for segment in segments {
            for row in segment.rows {
                XCTAssertNil(URLRuleKind.signature(of: row, resolve: resolve, normalize: normalize),
                             segment.label)
            }
            let access = FakeURLRuleAccess(rows: segment.rows)
            let store = MemoryOwnedItemStore()
            let client = FakePhiSyncClient()
            client.pagesByMarker = [page([ruleEntity(remote(uuid: "remote-b"), version: 7)], marker: "7")]
            let engine = makeEngine(client: client, markerStore: markerStore(marker: "0"),
                                    spaceStore: try drainedSpaceStore(),
                                    ownedKinds: [.urlRules(access: access, store: store)])
            await engine.setSpaceSyncEnabled(true)
            await engine.pullOnce()

            let first = await counters(engine)
            XCTAssertEqual(first?.adopted, 0, segment.label)
            XCTAssertEqual(first?.collapsed, 0, segment.label)
            XCTAssertEqual(access.rows.first { $0.id == "i1" }?.syncId, "local-a", segment.label)
            XCTAssertEqual(access.rows.first { $0.id == "i2" }?.syncId, "local-b", segment.label)
            XCTAssertTrue(access.rows.allSatisfy { $0.deletedDate == nil }, segment.label)
        }
    }

    /// (c) 目标 Space 在本机带着 `hidden`（`localSpaceId != nil` 且 `isEligibleSpace == false`）而
    /// 映射还在：第一道门过、第二道门不过 ⇒ nil；那条行也不进 `snapshot`（`skippedIneligibleOwner` +1）。
    func testM14c_aHiddenTargetFailsTheSecondGateAndStaysOutOfTheSnapshot() async throws {
        let rows: [PhiLocalURLRule] = [.fixture(id: "i1", syncId: "local-a", spaceId: "space-a"),
                                       .fixture(id: "i2", syncId: "local-b", spaceId: "space-b")]
        let hidden = OwnerResolver.fixture(ineligible: ["su-1"])
        XCTAssertNotNil(hidden.localSpaceId("su-1"), "映射还在")
        XCTAssertNil(URLRuleKind.signature(of: rows[0], resolve: hidden, normalize: normalize))
        XCTAssertNotNil(URLRuleKind.signature(of: rows[1], resolve: hidden, normalize: normalize))
        let snapshot = SyncableOwnedItems.snapshot(URLRuleKind.self, locals: rows,
                                                   table: PhiOwnedItemTable(), resolve: hidden,
                                                   scope: nil, now: Self.now)
        XCTAssertEqual(snapshot.skippedIneligibleOwner, 1)
        XCTAssertNil(snapshot.entities["local-a"])
        XCTAssertNotNil(snapshot.entities["local-b"])

        let access = FakeURLRuleAccess(rows: rows)
        let store = MemoryOwnedItemStore()
        let spaceStore = try drainedSpaceStore()
        var cursor = PhiSpaceCursor()
        cursor.entityId = "srv-space-1"
        cursor.version = 4
        cursor.hidden = true
        cursor.deletedAtMs = 1
        spaceStore.table.cursors["su-1"] = cursor
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([ruleEntity(remote(uuid: "remote-b", target: "su-1"), version: 7)],
                                     marker: "7")]
        let engine = makeEngine(client: client, markerStore: markerStore(marker: "0"),
                                spaceStore: spaceStore,
                                ownedKinds: [.urlRules(access: access, store: store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let first = await counters(engine)
        XCTAssertEqual(first?.adopted, 0)
        XCTAssertEqual(first?.collapsed, 0)
        XCTAssertEqual(access.rows.first { $0.id == "i1" }?.syncId, "local-a")
        XCTAssertEqual(access.rows.first { $0.id == "i2" }?.syncId, "local-b")
        XCTAssertTrue(access.rows.allSatisfy { $0.deletedDate == nil })
        XCTAssertEqual(rekeyCount(access.lastAppliedOps), 0)
    }

    // MARK: - CASE M-18（认领在第 1 页，差分在第 2 页）

    /// 防的是什么：轮首冻结投影的实现在 ② 上同时做出两件事（把刚认领上的那条账户实体删掉）。这一条
    /// 同时是「每页重读 + 两个就地更新口」的唯一端到端探针。
    func testM18_aClaimOnPageOneIsVisibleToPageTwoAndToTheEndOfRoundDiff() async throws {
        let access = FakeURLRuleAccess(rows: [.fixture(id: "i1", syncId: "local-a")])
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.pagesByMarker = [
            page([ruleEntity(remote(uuid: "remote-b"), version: 7)], marker: "7", changesRemaining: true),
            page([], marker: "9"),
        ]
        let engine = makeEngine(client: client, markerStore: markerStore(marker: "0"),
                                spaceStore: try drainedSpaceStore(),
                                ownedKinds: [.urlRules(access: access, store: store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let pages = await engine.lastRoundPagesForTesting
        XCTAssertEqual(pages, 2)
        let first = await counters(engine)
        XCTAssertEqual(first?.adopted, 1)
        // ② 轮末的发布段用的是刷新过的行投影：老 `syncId` 不被当成「没有游标的行」再发一条新实体，
        //    新身份不被判成「有基线、本机无对应行」。
        XCTAssertEqual(first?.pushed, 0)
        XCTAssertEqual(first?.tombstones, 0)
        XCTAssertTrue(ruleCommits(client).isEmpty)
        XCTAssertEqual(access.rows.count, 1)
        XCTAssertEqual(access.rows.first?.syncId, "remote-b")
        XCTAssertEqual(claimNotes(access), [1], "就地更新口被调过、恰好一次")
        XCTAssertNil(store.table.cursors["local-a"])
        XCTAssertNotNil(store.table.cursors["remote-b"]?.reconciled)
    }

    /// 变体（跨页重复认领）：两条同签名入站实体分在两页、本机只有一条可认领的行 ⇒ `adopted == 1`、
    /// 第 2 页那条作为第二条行落地、落地零抛出、marker 正常推进。防的是什么：用轮首那一份签名索引
    /// 去建第 2 页索引的实现让同一条行被第二条身份 re-key ⇒ 抛 ⇒ 整批回滚。
    func testM18_aSecondSameSignatureArrivalOnPageTwoDoesNotReKeyTheRowAgain() async throws {
        let access = FakeURLRuleAccess(rows: [.fixture(id: "i1", syncId: "local-a")])
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        let marker = markerStore(marker: "0")
        client.pagesByMarker = [
            page([ruleEntity(remote(uuid: "remote-b", rank: "V"), version: 7)], marker: "7",
                 changesRemaining: true),
            page([ruleEntity(remote(uuid: "remote-c", rank: "W"), version: 9)], marker: "9"),
        ]
        let engine = makeEngine(client: client, markerStore: marker,
                                spaceStore: try drainedSpaceStore(),
                                ownedKinds: [.urlRules(access: access, store: store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let first = await counters(engine)
        XCTAssertEqual(first?.adopted, 1)
        XCTAssertEqual(first?.refused, 0, "落地零抛出")
        XCTAssertEqual(first?.parked, 0)
        XCTAssertEqual(first?.applied, 2)
        XCTAssertEqual(access.rows.count, 2)
        XCTAssertEqual(access.rows.first { $0.id == "i1" }?.syncId, "remote-b")
        XCTAssertNotNil(access.rows.first { $0.syncId == "remote-c" })
        XCTAssertEqual(createCount(access.lastAppliedOps), 1, "第 2 页那条是 create")
        XCTAssertEqual(rekeyCount(access.lastAppliedOps), 0, "第 2 页没有第二次 re-key")
        XCTAssertEqual(marker.file.marker, Data("9".utf8))
        XCTAssertEqual(first?.pushed, 0)
        XCTAssertEqual(first?.tombstones, 0)
    }

    // MARK: - CASE M-20（re-key 那一半：引擎的写绝不置位 `pendingLocalEdit`）

    /// 防的是什么：一次认领若置位，这条身份对下一次远端删除免疫（§8.4.4 的让位谓词读它）；re-key
    /// 顺手清掉那一位的实现会把一次真实的未发布用户编辑在首次同步里静默丢掉。另外两条（用户删除 /
    /// Space 级联）是 Task 9 与 8b-4 的。
    func testM20_reKeyNeverSetsThePendingLocalEditFlag() async throws {
        let access = FakeURLRuleAccess(rows: [
            .fixture(id: "i1", syncId: "local-a", pendingLocalEdit: false),
        ])
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([ruleEntity(remote(uuid: "remote-b"), version: 7)], marker: "7")]
        let engine = makeEngine(client: client, markerStore: markerStore(marker: "0"),
                                spaceStore: try drainedSpaceStore(),
                                ownedKinds: [.urlRules(access: access, store: store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let row = access.rows.first { $0.id == "i1" }
        XCTAssertEqual(row?.syncId, "remote-b")
        XCTAssertEqual(row?.pendingLocalEdit, false, "re-key、字段合并落地、重编号、归一化都不置位")
    }

    func testM20_reKeyNeitherClearsAPendingLocalEditNorTouchesTheMergePartner() async throws {
        let access = FakeURLRuleAccess(rows: [
            .fixture(id: "i1", syncId: "local-a", pendingLocalEdit: true, mergePartnerSyncId: "w"),
        ])
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([ruleEntity(remote(uuid: "remote-b"), version: 7)], marker: "7")]
        let engine = makeEngine(client: client, markerStore: markerStore(marker: "0"),
                                spaceStore: try drainedSpaceStore(),
                                ownedKinds: [.urlRules(access: access, store: store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let first = await counters(engine)
        XCTAssertEqual(first?.adopted, 1)
        let row = access.rows.first { $0.id == "i1" }
        XCTAssertEqual(row?.syncId, "remote-b")
        XCTAssertEqual(row?.pendingLocalEdit, true, "原样保留：清位只在 §8.4.5 的两处（8b-4）")
        XCTAssertEqual(row?.mergePartnerSyncId, "w", "RR10-8：re-key 不动这一列")
    }

    // MARK: - CASE M-28（静止谓词的十项，一项一条负面）

    /// 防的是什么：第 10 项是新加的那一项（R-M3-4a-86）；第 5 项与第 10 项是同族的两半，少任何一项
    /// 都让一个签名组在两台与账户上全部归零。`syncId == nil` 那条钉住「绝不强解包」。
    func testM28_everyOneOfTheTenConjunctsIsIndividuallyFalsifiable() throws {
        let r = PhiLocalURLRule.fixture(id: "ir", syncId: "r", spaceId: "space-a")
        var base = publishedRuleCursor(urlRulePayload(uuid: "r"), entityId: "e", version: 2)
        base.deletedAtMs = nil
        XCTAssertTrue(isAtRest(r, base), "基准：十项全成立")

        func cursor(_ mutate: (inout PhiOwnedItemCursor) -> Void) -> PhiOwnedItemCursor {
            var out = base
            mutate(&out)
            return out
        }
        // 1 ~ 5、9：游标各翻一项。
        XCTAssertFalse(isAtRest(r, cursor { $0.server = nil }), "1 已发布")
        XCTAssertFalse(isAtRest(r, cursor { $0.server = Data([0x01]) }), "2 server == reconciled")
        XCTAssertFalse(isAtRest(r, cursor { $0.pendingApply = Data() }), "3 pendingApply")
        XCTAssertFalse(isAtRest(r, cursor { $0.pendingDelete = true }), "4 pendingDelete")
        XCTAssertFalse(isAtRest(r, cursor { $0.pendingTombstone = true }), "5 pendingTombstone")
        XCTAssertFalse(isAtRest(r, cursor { $0.entityId = "" }), "9 补键态（reconciled 留着）")
        XCTAssertFalse(isAtRest(r, nil), "1 没有游标")
        // 6、7：行各翻一项。
        var pendingEdit = r
        pendingEdit.pendingLocalEdit = true
        XCTAssertFalse(isAtRest(pendingEdit, base), "6 pendingLocalEdit")
        var deleted = r
        deleted.deletedDate = Date()
        XCTAssertFalse(isAtRest(deleted, base), "7 deletedDate")
        // 8：目标改成 agent Space ⇒ `eligibilityOwner == nil`。
        var agent = r
        agent.spaceId = "agent-space"
        XCTAssertFalse(isAtRest(agent, base), "8 没有签名")
        // 10：本页有它的 tombstone。
        XCTAssertFalse(isAtRest(r, base, tombstones: ["r"]), "10 tombstonesThisPage")
        // 前置：`syncId == nil` 的行绝不强解包。
        var unkeyedRow = r
        unkeyedRow.syncId = nil
        XCTAssertFalse(isAtRest(unkeyedRow, base), "syncId == nil")

        // (a) `mergePartners` 对一条 `mergePartnerSyncId == "r"` 的 X：基准下交回，变体 5 / 10 下不交回。
        let x = PhiLocalURLRule.fixture(id: "ix", syncId: "x", host: "other.example",
                                        mergePartnerSyncId: "r")
        let access = FakeURLRuleAccess(rows: [r, x])
        var table = PhiOwnedItemTable()
        table.cursors["r"] = base
        XCTAssertEqual(access.mergePartners(table: table, resolve: resolve, tombstonesThisPage: []),
                       ["x": "r"])
        var tombstoned = PhiOwnedItemTable()
        tombstoned.cursors["r"] = cursor { $0.pendingTombstone = true }
        XCTAssertEqual(access.mergePartners(table: tombstoned, resolve: resolve, tombstonesThisPage: []),
                       [:], "变体 5：W 不静止 ⇒ 不进本表")
        XCTAssertEqual(access.mergePartners(table: table, resolve: resolve, tombstonesThisPage: ["r"]),
                       [:], "变体 10：W 不静止 ⇒ 不进本表")
        // (b) 变体 10 下 `signatureIndex` 里 R 仍然在（第 10 项只影响静止，不影响分组）。
        let signature = try XCTUnwrap(URLRuleKind.signature(of: r, resolve: resolve, normalize: normalize))
        XCTAssertEqual(access.signatureIndex(resolve: resolve)[signature]?.map(\.id), ["ir"])
    }

    // MARK: - CASE M-29（签名的两道门与惰性行的分组排除）

    /// 防的是什么：只判第一道门的实现让 (c) 进索引；把保留常量按普通 uuid 送进 `isEligibleSpace`
    /// 的实现让 (b) 掉出去；组内不排序的实现让 §8.4.2 的「取字典序第一条」在两台上取到不同的行。
    func testM29_bothGatesAndTheGroupOrderOfTheSignatureIndex() throws {
        let hidden = OwnerResolver.fixture(ineligible: ["su-2"])
        let a = PhiLocalURLRule.fixture(id: "i1", syncId: "a", spaceId: "space-a", host: "a.example")
        let b = PhiLocalURLRule.fixture(id: "i2", syncId: "b", spaceId: SpaceManager.incognitoRuleTargetId,
                                        host: "b.example")
        let c = PhiLocalURLRule.fixture(id: "i3", syncId: "c", spaceId: "space-b", host: "c.example")
        let d = PhiLocalURLRule.fixture(id: "i4", syncId: "d", spaceId: "agent-space", host: "d.example")
        let softDeleted = PhiLocalURLRule.fixture(id: "i5", syncId: "e", spaceId: "space-a",
                                                  host: "a.example", deletedDate: Date())
        // 同签名三条：组内按 `(syncId ?? "", id)` 升序 ⇒ 没有 syncId 的排最前，然后 `aa` < `zz`。
        let dupZ = PhiLocalURLRule.fixture(id: "i9", syncId: "zz", spaceId: "space-a", host: "dup.example")
        let dupA = PhiLocalURLRule.fixture(id: "i8", syncId: "aa", spaceId: "space-a", host: "dup.example")
        let dupNil = PhiLocalURLRule.fixture(id: "i7", syncId: nil, spaceId: "space-a", host: "dup.example")

        XCTAssertEqual(URLRuleKind.signature(of: a, resolve: hidden, normalize: normalize)?.owner, "su-1")
        XCTAssertEqual(URLRuleKind.signature(of: b, resolve: hidden, normalize: normalize)?.owner,
                       "incognito-space")
        XCTAssertNil(URLRuleKind.signature(of: c, resolve: hidden, normalize: normalize), "(c) 第二道门")
        XCTAssertNil(URLRuleKind.signature(of: d, resolve: hidden, normalize: normalize), "(d) 第一道门")

        let access = FakeURLRuleAccess(rows: [dupZ, a, b, c, d, softDeleted, dupA, dupNil])
        let index = access.signatureIndex(resolve: hidden)
        let indexed = Set(index.values.flatMap { $0 }.map(\.id))
        XCTAssertEqual(indexed, ["i1", "i2", "i7", "i8", "i9"])
        XCTAssertFalse(indexed.contains("i5"), "软删行一条都不在")
        let dup = try XCTUnwrap(URLRuleKind.signature(of: dupA, resolve: hidden, normalize: normalize))
        XCTAssertEqual(index[dup]?.map(\.id), ["i7", "i8", "i9"])
    }

    // MARK: - CASE M-30（`baselineSignature` 的 fail-closed）

    /// 防的是什么：任何一种退化取值（`""` owner、跳过第二道门、解不出时回一个空签名）都会让 §8.4.4
    /// 的兜底支命中一条不该命中的 W；(e) 钉住「基线签名与当前签名走同一个函数」。
    func testM30_baselineSignatureFailsClosedAndMatchesTheRowSignature() throws {
        let hidden = OwnerResolver.fixture(ineligible: ["su-2"])
        var table = PhiOwnedItemTable()
        table.cursors["b"] = ownedCursor(server: Data([0x01]))
        table.cursors["c"] = ownedCursor(reconciled: Data("not a protobuf envelope".utf8))
        table.cursors["c2"] = ownedCursor(reconciled: baselineBytes(bookmarkPayload(uuid: "bk")))
        table.cursors["d"] = ownedCursor(reconciled: baselineBytes(
            urlRulePayload(uuid: "d", targetSpaceUuid: "su-2", host: "d.example")))
        table.cursors["e"] = ownedCursor(reconciled: baselineBytes(
            urlRulePayload(uuid: "e", targetSpaceUuid: "su-1", host: "E.example.", pathPrefix: "/docs")))

        func baseline(_ identity: String) -> RuleSignature? {
            URLRuleKind.baselineSignature(identity: identity, table: table, resolve: hidden,
                                          normalize: normalize)
        }
        XCTAssertNil(baseline("a"), "(a) 没有这条身份")
        XCTAssertNil(baseline("b"), "(b) 没有 reconciled")
        XCTAssertNil(baseline("c"), "(c) 解不出 Phi_PhiEntity")
        XCTAssertNil(baseline("c2"), "(c) 解得出信封、不是规则")
        XCTAssertNil(baseline("d"), "(d) 目标此刻 hidden")
        let e = try XCTUnwrap(baseline("e"))
        // 把那份 `reconciled` 落成本机行之后算出的签名逐字相等。
        let landed = PhiLocalURLRule.fixture(id: "ie", syncId: "e", spaceId: "space-a",
                                             host: "E.example.", pathPrefix: "/docs")
        XCTAssertEqual(URLRuleKind.signature(of: landed, resolve: hidden, normalize: normalize), e)
        XCTAssertEqual(e, RuleSignature(host: "e.example", pathPrefix: "/docs", owner: "su-1"))
    }

    // =======================================================================================
    // MARK: - 8b-2（M2 收敛）：脚手架
    // =======================================================================================

    /// 毫秒戳 -> `Date`，与 `URLRuleKind` 内部那一份互为逆。有效账户戳读出来的就是它。
    private func stampDate(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

    /// 一条**静止**的已发布行 + 它的游标：十个合取项全部成立。
    ///
    /// `accountStamp` 落在**游标基线**的三枚戳上（有效账户戳的第三层读它），与行上那一列
    /// `rowContentUpdatedDate` 刻意**解耦**——R-M3-4a-94 的整条论证就是「静止只蕴含『有基线且
    /// `server == reconciled`』，**不蕴含**『行戳 == 基线戳』」，所以用例必须造得出两者不同的行。
    @discardableResult
    private func seedSettled(_ syncId: String, id: String,
                             host: String = "github.com", pathPrefix: String? = nil,
                             ask: Bool = false, spaceId: String = "space-a",
                             target: String = "su-1", sortOrder: Int = 0,
                             accountStamp: Int64, rank: String? = nil,
                             rowContentUpdatedDate: Date? = nil,
                             createdDate: Date = Date(timeIntervalSince1970: 1_000),
                             pendingLocalEdit: Bool = false,
                             mergePartnerSyncId: String? = nil,
                             rows: inout [PhiLocalURLRule],
                             table: inout PhiOwnedItemTable) -> PhiLocalURLRule {
        // 见文件头的第二条口径：同一桶里几条行的 rank 必须各不相同、且与 `sortOrder` 同序，
        // 否则出站快照会为它们重新铸 rank，每一条「这一轮零 commit」的断言都会看到一次虚假推送。
        let ladder = ["V", "W", "X", "Y", "Z"]
        let payload = urlRulePayload(uuid: syncId, targetSpaceUuid: target, host: host,
                                     pathPrefix: pathPrefix ?? "", ask: ask,
                                     rank: rank ?? ladder[min(max(sortOrder, 0), ladder.count - 1)],
                                     contentStamp: accountStamp, targetStamp: accountStamp,
                                     rankStamp: accountStamp)
        table.cursors[syncId] = publishedRuleCursor(payload, entityId: "srv-\(syncId)", version: 1)
        let row = PhiLocalURLRule.fixture(id: id, syncId: syncId, spaceId: spaceId, host: host,
                                          pathPrefix: pathPrefix, askBeforeRouting: ask,
                                          sortOrder: sortOrder, createdDate: createdDate,
                                          contentUpdatedDate: rowContentUpdatedDate,
                                          pendingLocalEdit: pendingLocalEdit,
                                          mergePartnerSyncId: mergePartnerSyncId)
        rows.append(row)
        return row
    }

    /// `URLRuleKind.mergePass` 的调用糖。`publishedIdentities` 默认按 R-M3-4a-95 的取值式
    /// 从游标表算（`server != nil`），与 `land` 闭包里那一行逐字相同。
    private func mergePass(rows: [PhiLocalURLRule], table: PhiOwnedItemTable,
                           atRest: Set<String>, convergeAllowed: Bool = true,
                           landedThisPage: Set<String> = [],
                           published: Set<String>? = nil,
                           preLanding: [String: RuleSignature] = [:],
                           landed: [String: URLRuleLandingValues] = [:],
                           rebaselined: [String: Data] = [:]) -> URLRuleMergeResult {
        URLRuleKind.mergePass(
            rows: rows, landedThisPage: landedThisPage,
            publishedIdentities: published
                ?? Set(table.cursors.filter { $0.value.server != nil }.keys),
            preLandingSignatures: preLanding, atRest: atRest, landed: landed,
            rebaselined: rebaselined, table: table, convergeAllowed: convergeAllowed,
            resolve: resolve)
    }

    private func pointerPass(_ liveRows: [PhiLocalURLRule],
                             landedThisPage: Set<String> = [],
                             published: Set<String>,
                             preLanding: [String: RuleSignature] = [:]) -> [String: String] {
        URLRuleKind.mergePointerPass(liveRows: liveRows, landedThisPage: landedThisPage,
                                     publishedIdentities: published,
                                     preLandingSignatures: preLanding, resolve: resolve)
    }

    /// 本页的 M2 补写 op（`FakeURLRuleAccess` 记的那一份）。
    private func mergeOps(_ access: FakeURLRuleAccess) -> [URLRuleSyncOp] { access.lastMergeOps }

    private func refreshCalls(_ access: FakeURLRuleAccess) -> Int {
        access.calls.filter { $0 == .refreshRoutingTable }.count
    }

    private func applyCalls(_ access: FakeURLRuleAccess) -> Int {
        access.calls.filter { if case .apply = $0 { return true } else { return false } }.count
    }

    private func liveRows(_ access: FakeURLRuleAccess) -> [PhiLocalURLRule] {
        access.rows.filter { $0.deletedDate == nil }
    }

    private func row(_ access: FakeURLRuleAccess, _ syncId: String) -> PhiLocalURLRule? {
        access.rows.first { $0.syncId == syncId }
    }

    /// 一台只跑规则的引擎 + 一页（默认空页：`landsEmptyBatch` 的那条路径）。
    private func makeRuleEngine(_ access: FakeURLRuleAccess, _ store: MemoryOwnedItemStore,
                                client: FakePhiSyncClient,
                                drained: Bool = true) throws -> PhiSyncEngine {
        let spaceStore = MemorySpaceStore()
        spaceStore.table.hasDrainedFullReplay = drained
        try silenceOtherSections(spaceStore)
        return makeEngine(client: client, markerStore: markerStore(marker: "0"),
                          spaceStore: spaceStore,
                          ownedKinds: [.urlRules(access: access, store: store)])
    }

    // =======================================================================================
    // MARK: - CASE M-6b（吸收先归约整组，再写一次）（R-M3-4a-82）
    // =======================================================================================

    /// 防的是什么：逐个败者比一份**固定的 W 快照**的实现先写 `true@30`、再因为「20 > 10（快照
    /// 没更新）」写 `true@20` ⇒ 收在 `true@20`，戳**倒退**，两台成员次序不同还会分歧。
    func testM6b_absorptionReducesTheWholeGroupOnceInsteadOfPerLoser() throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        seedSettled("a", id: "i-a", ask: false, accountStamp: 10, rows: &rows, table: &table)
        seedSettled("b", id: "i-b", ask: true, accountStamp: 30, rows: &rows, table: &table)
        seedSettled("c", id: "i-c", ask: true, accountStamp: 20, rows: &rows, table: &table)

        let signature = try XCTUnwrap(URLRuleKind.signature(of: rows[0], resolve: resolve,
                                                            normalize: normalize))
        let stamps = ["a": stampDate(10), "b": stampDate(30), "c": stampDate(20)]
        let converged = URLRuleKind.convergePass(groups: [signature: rows],
                                                 atRest: ["a", "b", "c"],
                                                 accountStamps: stamps)
        // 一次写，取值是**整组**的 `source`（`true@30`），戳**照抄来源**。
        XCTAssertEqual(converged.contentGroupWrites.count, 1)
        XCTAssertEqual(converged.contentGroupWrites.first?.syncId, "a", "胜者是 syncId 最小的那条")
        XCTAssertEqual(converged.contentGroupWrites.first?.ask, true)
        XCTAssertEqual(converged.contentGroupWrites.first?.contentUpdatedDate, stampDate(30))
        XCTAssertEqual(converged.collapsed, 2)
        XCTAssertEqual(converged.softDeletes.map(\.syncId).sorted(), ["b", "c"])
        XCTAssertTrue(converged.softDeletes.allSatisfy { $0.mergePartnerSyncId == "a" })
        XCTAssertEqual(converged.touchedBuckets, ["space-a"])

        // (a) 戳推进：内容组相同、戳不同 ⇒ W 的组戳照样被写成 30。少了它，W 的组戳停在 10、
        //     下一轮同一条败者又赢一次，「戳只进不退」守不住。
        var advanced = rows
        advanced[0].askBeforeRouting = true
        let advancedOut = URLRuleKind.convergePass(groups: [signature: advanced],
                                                   atRest: ["a", "b", "c"],
                                                   accountStamps: stamps)
        XCTAssertEqual(advancedOut.contentGroupWrites.count, 1)
        XCTAssertEqual(advancedOut.contentGroupWrites.first?.contentUpdatedDate, stampDate(30))
        XCTAssertEqual(advancedOut.contentGroupWrites.first?.ask, true)

        // (b) 戳相等定序：`true@30` 与 `false@30` ⇒ 按 `syncId` 字典序取定，**两台逐字相同**，
        //     而且仍然只写一次。把成员次序打乱重跑，结论一个字节不变。
        var tied: [PhiLocalURLRule] = []
        var tiedTable = PhiOwnedItemTable()
        seedSettled("a", id: "i-a", ask: true, accountStamp: 30, rows: &tied, table: &tiedTable)
        seedSettled("b", id: "i-b", ask: false, accountStamp: 30, rows: &tied, table: &tiedTable)
        let tiedStamps = ["a": stampDate(30), "b": stampDate(30)]
        let first = URLRuleKind.convergePass(groups: [signature: tied], atRest: ["a", "b"],
                                             accountStamps: tiedStamps)
        let reversed = URLRuleKind.convergePass(groups: [signature: tied.reversed()],
                                                atRest: ["a", "b"], accountStamps: tiedStamps)
        XCTAssertEqual(first.contentGroupWrites.count, 1)
        XCTAssertEqual(first, reversed, "成员次序不影响终态")
        XCTAssertEqual(first.softDeletes.map(\.syncId), ["b"])
    }

    // =======================================================================================
    // MARK: - CASE M2-a（指针绝不覆盖一条已经指向活行的值 —— 纯值）
    // =======================================================================================

    /// 防的是什么：承重的那条前置一旦放宽，指针这一步就是「两遍分组 × 每一页 × 组内每一个
    /// 非锚点成员」的全库每页重写，而且第二遍会覆盖第 2 步 (b) 写下的终值（RR11-2）。
    func testM2a_thePointerNeverOverwritesAValueThatAlreadyPointsAtALiveRow() throws {
        let a = PhiLocalURLRule.fixture(id: "i-a", syncId: "a")
        let b = PhiLocalURLRule.fixture(id: "i-b", syncId: "b", sortOrder: 1,
                                        mergePartnerSyncId: "c")
        let c = PhiLocalURLRule.fixture(id: "i-c", syncId: "c", sortOrder: 2,
                                        mergePartnerSyncId: "zz")
        let out = pointerPass([a, b, c], published: ["a", "b", "c"])
        XCTAssertNil(out["b"], "已经指向一条活行 ⇒ 不动")
        XCTAssertEqual(out["c"], "a", "悬空 ⇒ 改写成锚点")
        XCTAssertNil(out["a"], "锚点自己那一列恒为 nil（RR13-7）")

        // 悬空判据只看「有没有**活**行」：指向一条已经被别人收敛掉的软删行同样是悬空。
        var cPointsAtDeleted = c
        cPointsAtDeleted.mergePartnerSyncId = "gone"
        let deleted = PhiLocalURLRule.fixture(id: "i-gone", syncId: "gone", sortOrder: 3,
                                              deletedDate: Date(timeIntervalSince1970: 9))
        XCTAssertEqual(deleted.deletedDate != nil, true)
        let dangling = pointerPass([a, b, cPointsAtDeleted], published: ["a", "b", "c", "gone"])
        XCTAssertEqual(dangling["c"], "a")

        // 负面对照（R-M3-4a-95）：`"A0"` 有 `syncId`（M1 认领那一刻就铸了一个）却**从没发布过**。
        // 把「已发布」判成 `row.syncId != nil` 的实现会选它当锚点，而一条未发布的行**永远不
        // 静止** ⇒ §8.4.4 第一步的伙伴查找对整组恒不命中（RR13-5）。
        let a0 = PhiLocalURLRule.fixture(id: "i-a0", syncId: "A0", sortOrder: 4)
        let control = pointerPass([a0, a, b, c], published: ["a", "b", "c"])
        XCTAssertEqual(control["A0"], "a", "锚点仍然是 a，A0 自己也进结果字典")
        XCTAssertEqual(control["c"], "a")
        XCTAssertNil(control["a"])
        XCTAssertNil(control["b"])

        // 锚点子集少于两条 ⇒ 这一组零写。
        XCTAssertTrue(pointerPass([a0, a], published: ["a"]).isEmpty)
    }

    /// **F1 的探针（8b-2 fix round 1）**：锚点子集的**基数**按伪码的时刻求值 —— 也就是收敛
    /// **之前**那一份活集。组里两条已发布静止成员 A / B 加一条从未发布、本页也没落地的活行 C：
    /// 收敛把 B 软删掉，软删之后的活集里「已发布 ∪ 本页落地」只剩 A 一条。
    ///
    /// 防的是什么：把锚点子集也建在软删之后那一份活集上的实现，这一组的子集从 2 掉到 1 ⇒
    /// `guard anchors.count >= 2` 当场 `continue` ⇒ **C 一条指针都拿不到**，而 §8.4.3 的
    /// `writePointer` 在收敛之前求那个 `> 1`、给**每一个**非锚点成员（含从未发布的）写指针，
    /// `mergePartnerSyncId` 生命周期表的 RR10-8 那一行正是按「它被写过」立的。
    func testM2a_theAnchorCardinalityIsEvaluatedBeforeTheSoftDeletes() throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        seedSettled("a", id: "i-a", accountStamp: 100, rows: &rows, table: &table)
        seedSettled("b", id: "i-b", sortOrder: 1, accountStamp: 100, rows: &rows, table: &table)
        // C：有 `syncId`（插入点铸造，R-M3-4a-23），**没有游标** ⇒ 既不在 `publishedIdentities`
        // 里、也不在 `landedThisPage` 里，而且它不静止 ⇒ 不是收敛的成员。
        rows.append(.fixture(id: "i-c", syncId: "c-local", sortOrder: 2, pendingLocalEdit: true))

        let out = mergePass(rows: rows, table: table, atRest: ["a", "b"])
        XCTAssertEqual(out.collapsed, 1, "B 被软删")
        XCTAssertEqual(out.ops, [
            .softDelete(syncId: "b", mergePartnerSyncId: "a"),
            .setMergePartner(syncId: "c-local", mergePartnerSyncId: "a"),
        ], "C 照样拿到指向锚点 A 的那一列")

        // 对照：同一份输入但闸关着（零软删）⇒ C 拿到的那一列**逐字相同**。B 此时还活着、
        // 也还是非锚点成员，所以它多一条指针写；C 那一条两条路径一致，正是「`convergePass`
        // 先跑」那条偏离要证明的东西。
        let gated = mergePass(rows: rows, table: table, atRest: ["a", "b"], convergeAllowed: false)
        XCTAssertEqual(gated.ops, [
            .setMergePartner(syncId: "b", mergePartnerSyncId: "a"),
            .setMergePartner(syncId: "c-local", mergePartnerSyncId: "a"),
        ])
    }

    // =======================================================================================
    // MARK: - CASE M2-c（闸只管第 2 步：通道级断言）
    // =======================================================================================

    /// 防的是什么：把闸读成「整趟不跑」或者把它塞进 `mergePointerPass` 内部，两种写法在纯值
    /// 层面都看不出来。`changedRouting` 若把指针写也算进去，CASE M-7 的「零刷新」会变成每页一次。
    func testM2c_theGateOnlyStopsTheSecondStep() throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        seedSettled("a", id: "i-a", ask: false, accountStamp: 10, rows: &rows, table: &table)
        seedSettled("b", id: "i-b", ask: true, accountStamp: 20, sortOrder: 1,
                    rows: &rows, table: &table)

        let closed = mergePass(rows: rows, table: table, atRest: ["a", "b"], convergeAllowed: false)
        XCTAssertEqual(closed.ops, [.setMergePartner(syncId: "b", mergePartnerSyncId: "a")],
                       "闸关着：只有第 1 步的指针")
        XCTAssertEqual(closed.collapsed, 0)
        XCTAssertFalse(closed.changedRouting, "纯指针写 ⇒ 不刷路由表")

        let open = mergePass(rows: rows, table: table, atRest: ["a", "b"], convergeAllowed: true)
        XCTAssertEqual(open.ops, [
            .setContentGroup(syncId: "a", host: "github.com", pathPrefix: nil, ask: true,
                             contentUpdatedDate: stampDate(20)),
            .softDelete(syncId: "b", mergePartnerSyncId: "a"),
        ], "闸开：内容组 → 软删的相序")
        XCTAssertEqual(open.collapsed, 1)
        XCTAssertTrue(open.changedRouting)
    }

    // =======================================================================================
    // MARK: - CASE M-4（内容组吸收：照抄来源的戳，绝不铸 `now`）
    // =======================================================================================

    /// 防的是什么：铸 `now` 会让一条经机器搬运的规则带着伪造的新鲜度去赢一次真实的用户编辑
    /// （D33 / §8.4.1 第五条）。变体三防的是取值源去读 `createdDate` 之类的**每设备量**。
    func testM4_absorptionCopiesTheSourceStampAndNeverMintsNow() throws {
        /// 变体 α / β 的唯一差别是**行上那一列**，期望逐字相同（R-M3-4a-94：读的是账户戳）。
        func run(rowStamps: Bool) -> URLRuleMergeResult {
            var rows: [PhiLocalURLRule] = []
            var table = PhiOwnedItemTable()
            seedSettled("a", id: "i-a", ask: false, accountStamp: 100,
                        rowContentUpdatedDate: rowStamps ? stampDate(100) : nil,
                        rows: &rows, table: &table)
            seedSettled("b", id: "i-b", ask: true, sortOrder: 1, accountStamp: 300,
                        rowContentUpdatedDate: rowStamps ? stampDate(300) : nil,
                        rows: &rows, table: &table)
            return mergePass(rows: rows, table: table, atRest: ["a", "b"])
        }
        for rowStamps in [true, false] {
            let out = run(rowStamps: rowStamps)
            XCTAssertEqual(out.ops.first,
                           .setContentGroup(syncId: "a", host: "github.com", pathPrefix: nil,
                                            ask: true, contentUpdatedDate: stampDate(300)),
                           "rowStamps=\(rowStamps)：吸收 `true@300`，**不是** now")
            XCTAssertEqual(out.collapsed, 1)
        }

        // 变体一：败者内容组与胜者相同、戳也相同 ⇒ `ask` 与 `contentUpdatedDate` 一个字节不动。
        var same: [PhiLocalURLRule] = []
        var sameTable = PhiOwnedItemTable()
        seedSettled("a", id: "i-a", ask: true, accountStamp: 300, rows: &same, table: &sameTable)
        seedSettled("b", id: "i-b", ask: true, sortOrder: 1, accountStamp: 300,
                    rows: &same, table: &sameTable)
        let identical = mergePass(rows: same, table: sameTable, atRest: ["a", "b"])
        XCTAssertEqual(identical.ops, [.softDelete(syncId: "b", mergePartnerSyncId: "a")],
                       "零多余 commit：没有内容组写")
        XCTAssertEqual(identical.collapsed, 1)

        // 变体二 / 三：败者内容戳更旧而 `ask` 不同 ⇒ **整组不吸收**；把败者的本机 `createdDate`
        // 推到远晚于胜者（每设备量）⇒ 结论逐字相同。
        for loserCreated in [Date(timeIntervalSince1970: 1_000), Date(timeIntervalSince1970: 9_000)] {
            var older: [PhiLocalURLRule] = []
            var olderTable = PhiOwnedItemTable()
            seedSettled("a", id: "i-a", ask: false, accountStamp: 300, rows: &older,
                        table: &olderTable)
            seedSettled("b", id: "i-b", ask: true, sortOrder: 1, accountStamp: 100,
                        createdDate: loserCreated, rows: &older, table: &olderTable)
            let out = mergePass(rows: older, table: olderTable, atRest: ["a", "b"])
            XCTAssertEqual(out.ops, [.softDelete(syncId: "b", mergePartnerSyncId: "a")],
                           "createdDate=\(loserCreated)：整组不吸收")
        }
    }

    // =======================================================================================
    // MARK: - CASE M-3b（未发布行绝不当胜者，也绝不杀已发布实体）
    // =======================================================================================

    /// 防的是什么：静止谓词漏掉判据 1（已发布）的实现会选 `"a-local"` 当胜者并软删那条账户
    /// 实体，直接违反 D30 原文；跨设备变体里那种实现会「A 删账户实体、B 删自己那条」。
    func testM3b_anUnpublishedRowNeverWinsAndNeverKillsAPublishedEntity() throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        seedSettled("m-account", id: "i-acc", accountStamp: 100, rows: &rows, table: &table)
        // 本机新建、从未发布：有 `syncId`（插入点铸造，R-M3-4a-23），**没有游标**。
        rows.append(.fixture(id: "i-local", syncId: "a-local", sortOrder: 1, pendingLocalEdit: true))

        let out = mergePass(rows: rows, table: table, atRest: ["m-account"])
        XCTAssertEqual(out.collapsed, 0)
        XCTAssertTrue(out.ops.isEmpty, "锚点子集只有一条 ⇒ 连指针都不写")

        // 跨设备变体：本机铸值一次小于、一次大于账户身份 ⇒ **两台都零收敛**。
        for localId in ["a-local", "z-local"] {
            var variant: [PhiLocalURLRule] = []
            var variantTable = PhiOwnedItemTable()
            seedSettled("m-account", id: "i-acc", accountStamp: 100, rows: &variant,
                        table: &variantTable)
            variant.append(.fixture(id: "i-local", syncId: localId, sortOrder: 1,
                                    pendingLocalEdit: true))
            XCTAssertEqual(mergePass(rows: variant, table: variantTable,
                                     atRest: ["m-account"]).collapsed, 0, localId)
        }
    }

    // =======================================================================================
    // MARK: - CASE M-10（收敛不复活用户删掉的行）
    // =======================================================================================

    /// 防的是什么：尾钩拿到的是**含软删行**的投影（寻址要它），漏掉那道活行过滤会让一条用户
    /// 刚删掉的行当上胜者、被吸收内容组——用户眼里是「删掉的规则又改了一次内容回来」。
    func testM10_convergenceNeverResurrectsARowTheUserDeleted() throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        seedSettled("a", id: "i-a", ask: false, accountStamp: 10, rows: &rows, table: &table)
        let deletedAt = Date(timeIntervalSince1970: 4_242)
        seedSettled("b", id: "i-b", ask: true, sortOrder: 1, accountStamp: 900,
                    rows: &rows, table: &table)
        rows[1].deletedDate = deletedAt

        let out = mergePass(rows: rows, table: table, atRest: ["a", "b"])
        XCTAssertEqual(out.collapsed, 0, "软删那条不是组成员 ⇒ 组里只剩一条")
        XCTAssertTrue(out.ops.isEmpty, "`a` 一个字节都不写（它那一列本来就是 nil）")
        XCTAssertEqual(rows[1].deletedDate, deletedAt, "M2 一个字节都没碰它")
    }

    // =======================================================================================
    // MARK: - CASE M-27（M2 不选本页将死的胜者）（R-M3-4a-86）
    // =======================================================================================

    /// 防的是什么：把 Z 当胜者的那一版（`atRest` 若在尾钩里重算就必然缺第 10 项）会让 Z 吸收
    /// X 的内容组、软删 X 并发它的 tombstone，而 Z 自己在同一页的删除相被硬删 ⇒ **该签名组在
    /// 两台与账户上全部为零**，日志里只留一个 `collapsed`。
    func testM27_theMergeNeverPicksAWinnerThatDiesOnThisPage() throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        let z = seedSettled("a", id: "i-z", ask: false, accountStamp: 10, rows: &rows, table: &table)
        seedSettled("b", id: "i-x", ask: true, sortOrder: 1, accountStamp: 20,
                    rows: &rows, table: &table)
        // 本页 `arrivals` 里到达 Z 的 tombstone ⇒ 8b-1 的第 10 项把 Z 踢出 `atRestIdentities`。
        XCTAssertFalse(isAtRest(z, table.cursors["a"], tombstones: ["a"]), "第 10 项")

        let out = mergePass(rows: rows, table: table, atRest: ["b"])
        XCTAssertEqual(out.collapsed, 0, "静止成员只剩一条")
        XCTAssertFalse(out.changedRouting)
        // X 行上除第 1 步那次指针写之外零变化：不写内容组、不写 `deletedDate`。
        XCTAssertEqual(out.ops, [.setMergePartner(syncId: "b", mergePartnerSyncId: "a")])

        // 下一页：Z 已经硬删 ⇒ 该签名只剩 X 一条 ⇒ 不再是重复。
        var afterDelete = [rows[1]]
        afterDelete[0].mergePartnerSyncId = "a"
        var afterTable = table
        afterTable.cursors["a"] = nil
        let next = mergePass(rows: afterDelete, table: afterTable, atRest: ["b"])
        XCTAssertEqual(next.collapsed, 0)
        // 清空规则①：组里只剩它一条、它静止、那一列还挂着一个陈旧的伙伴 ⇒ 清空。
        XCTAssertEqual(next.ops, [.setMergePartner(syncId: "b", mergePartnerSyncId: nil)])
    }

    // =======================================================================================
    // MARK: - CASE M-33（同页 M3 → M2：戳取**有效账户戳**的三层）
    // =======================================================================================

    /// 变体 (b)：戳源的「已落地那一半」。一律读游标基线的那一版选 W@30、把账户上最新的那份
    /// 内容丢掉，必须红。
    func testM33b_theEffectiveStampOfAnIdentityLandedThisPageIsItsLandingValue() throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        seedSettled("a", id: "i-w", ask: false, accountStamp: 30,
                    rowContentUpdatedDate: stampDate(30), rows: &rows, table: &table)
        // B 本页被一条 `.update` 落成 `ask == true` / 组戳 40，而 `land` 闭包手上那份**游标表
        // 仍说 20**（记账排在 `land(...)` 之后）。
        seedSettled("b", id: "i-b", ask: true, sortOrder: 1, accountStamp: 20,
                    rowContentUpdatedDate: stampDate(40), rows: &rows, table: &table)
        let landed = ["b": URLRuleLandingValues.fixture(syncId: "b", spaceId: "space-a",
                                                        host: "github.com",
                                                        askBeforeRouting: true, sortOrder: 1,
                                                        contentUpdatedDate: stampDate(40),
                                                        targetUpdatedDate: stampDate(40))]
        let out = mergePass(rows: rows, table: table, atRest: ["a", "b"],
                            landedThisPage: ["b"], landed: landed)
        XCTAssertEqual(out.ops, [
            .setContentGroup(syncId: "a", host: "github.com", pathPrefix: nil, ask: true,
                             contentUpdatedDate: stampDate(40)),
            .softDelete(syncId: "b", mergePartnerSyncId: "a"),
        ], "`source` 取本页落地值 40，不是游标里那份 20")
        XCTAssertEqual(out.collapsed, 1)
    }

    /// 变体 (c)：行戳根本不能读。读行戳的那一版给 A 算出 `.distantPast`（或退到
    /// `?? createdDate` 这个**每设备量**）⇒ 选 B ⇒ 账户上更新的那份被机器覆盖。
    func testM33c_theRowStampIsNeverTheSourceOfTruth() throws {
        // 两种形态：行上那一列是 `nil`（Task 5 裁定 5 的新行形态）与停在一个更旧的 10
        // （`rebaselined` 只刷基线、不写行）。期望逐字相同。
        for rowStamp in [nil, stampDate(10)] as [Date?] {
            var rows: [PhiLocalURLRule] = []
            var table = PhiOwnedItemTable()
            seedSettled("a", id: "i-a", ask: false, accountStamp: 30,
                        rowContentUpdatedDate: rowStamp, rows: &rows, table: &table)
            seedSettled("b", id: "i-b", ask: true, sortOrder: 1, accountStamp: 20,
                        rowContentUpdatedDate: stampDate(20), rows: &rows, table: &table)
            let out = mergePass(rows: rows, table: table, atRest: ["a", "b"])
            XCTAssertEqual(out.ops, [.softDelete(syncId: "b", mergePartnerSyncId: "a")],
                           "rowStamp=\(String(describing: rowStamp))：`source` 是 A ⇒ A 一个字节不写")
            XCTAssertEqual(out.collapsed, 1)
        }
    }

    /// 变体 (d)：戳源的「本页 `rebaselined` 那一层」（R-M3-4a-97）。**这一页一条 op 都没有**，
    /// 所以候选集的转移减法、相序、事务内剔除三条没有一条拦得住它——`rebaselined` 是唯一的堵口。
    func testM33d_theEffectiveStampFallsBackToThisPagesRebaselinedBytes() throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        seedSettled("a", id: "i-a", ask: false, accountStamp: 10, rows: &rows, table: &table)
        seedSettled("b", id: "i-b", ask: true, sortOrder: 1, accountStamp: 20,
                    rows: &rows, table: &table)
        // 本页到达 A 的一条实体：取值与本机**逐字相同**（仍是 `false`）而 `updated_at_ms == 30`
        // ⇒ `plan` 一条 step 都不产出、A 落进 `plan.rebaselined`。
        let rebased = baselineBytes(urlRulePayload(uuid: "a", targetSpaceUuid: "su-1",
                                                   host: "github.com", ask: false,
                                                   contentStamp: 30, targetStamp: 30,
                                                   rankStamp: 30))
        let out = mergePass(rows: rows, table: table, atRest: ["a", "b"],
                            rebaselined: ["a": rebased])
        XCTAssertEqual(out.ops, [.softDelete(syncId: "b", mergePartnerSyncId: "a")],
                       "`source` 是 A（30 > 20）⇒ B 被软删、A 一个字节不写")
        XCTAssertEqual(out.collapsed, 1)

        // 只有「落地值 + 游标基线」两层的那一版：A 停在 10 ⇒ 选 B 当 `source` ⇒ 把 A 覆写成
        // `ask == true` / 戳 20 并软删 A。这一行就是那个必须红的形状。
        let twoLayers = mergePass(rows: rows, table: table, atRest: ["a", "b"])
        XCTAssertEqual(twoLayers.ops.first,
                       .setContentGroup(syncId: "a", host: "github.com", pathPrefix: nil,
                                        ask: true, contentUpdatedDate: stampDate(20)),
                       "对照：没有第二层就会去吸收 B@20")
    }

    // =======================================================================================
    // MARK: - CASE M-25（指针的零延迟输入）（R-M3-4a-74 / 75 / 95）
    // =======================================================================================

    /// (a) 首次落地那一页：Z 与 X **第一次**从账户落地（两者此刻都还没有游标）⇒ 断言那一页就
    /// 写下 X → Z 的指针。只按 `publishedIdentities` 取锚点子集、**忘了并上 `landedThisPage`**
    /// 的实现必须红（该子集此刻为空 ⇒ 一个指针都写不出）。
    func testM25a_thePointerIsWrittenOnTheVeryPageBothSidesFirstLand() throws {
        let z = PhiLocalURLRule.fixture(id: "i-z", syncId: "a")
        let x = PhiLocalURLRule.fixture(id: "i-x", syncId: "b", sortOrder: 1)
        let out = pointerPass([z, x], landedThisPage: ["a", "b"], published: [])
        XCTAssertEqual(out, ["b": "a"])
        XCTAssertTrue(pointerPass([z, x], landedThisPage: [], published: []).isEmpty,
                      "两个并集项都是承重的：只看 `landedThisPage` 那一半也写不出来")
    }

    /// (b)(d) 闸关着（整段首次 drain / 报损重放）⇒ 这一页**照样写指针**，同一页 `collapsed == 0`。
    func testM25bd_theGateNeverStopsThePointer() throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        seedSettled("a", id: "i-z", accountStamp: 10, rows: &rows, table: &table)
        seedSettled("b", id: "i-x", sortOrder: 1, accountStamp: 20, rows: &rows, table: &table)
        let out = mergePass(rows: rows, table: table, atRest: ["a", "b"], convergeAllowed: false,
                            landedThisPage: ["a"])
        XCTAssertEqual(out.ops, [.setMergePartner(syncId: "b", mergePartnerSyncId: "a")])
        XCTAssertEqual(out.collapsed, 0)
        XCTAssertFalse(out.changedRouting)
    }

    /// (c) 同页 `.move`，而 X 本页一条 step 都不落地：第一遍按**此刻**的签名不同组，第二遍按
    /// `preLandingSignatures[Z]` 同组 ⇒ 指针写在 X 的行上、指向 Z。
    ///
    /// 三条必须红的实现：第二遍的定义域收成「表里那些身份」（X 不在表里 ⇒ 那一组只有 Z 一条
    /// ⇒ **静默**空转）；落地之后重读行来算落地前签名；用 `newOwnerUuid` 当落地前目标。
    func testM25c_theSecondPassGroupsByThePreLandingSignature() throws {
        // Z 本页被搬到 `space-b`（su-2），X 还在 `space-a`（su-1）。
        let z = PhiLocalURLRule.fixture(id: "i-z", syncId: "a", spaceId: "space-b")
        let x = PhiLocalURLRule.fixture(id: "i-x", syncId: "b", spaceId: "space-a",
                                        sortOrder: 1, pendingLocalEdit: true)
        let preLanding = ["a": RuleSignature(host: "github.com", pathPrefix: nil, owner: "su-1")]
        XCTAssertTrue(pointerPass([z, x], published: ["a", "b"]).isEmpty,
                      "只按此刻的签名 ⇒ 两组各一条 ⇒ 零写")
        XCTAssertEqual(pointerPass([z, x], published: ["a", "b"], preLanding: preLanding),
                       ["b": "a"])

        // Z 的**落地前**目标此刻解析不出来 ⇒ 这条身份不在 `preLandingSignatures` 里 ⇒ 第二遍
        // 跳过它、**不崩**。
        XCTAssertTrue(pointerPass([z, x], published: ["a", "b"], preLanding: [:]).isEmpty)
    }

    /// (e) 交织 B：X 与 Z 都不进 `preLandingSignatures`，第一遍按此刻的签名不同组，第二遍的键
    /// 退化成同一对签名 ⇒ **那一趟两遍指针都写不出**。
    func testM25e_theInterleavedShapeWritesNoPointerAtAll() throws {
        let z = PhiLocalURLRule.fixture(id: "i-z", syncId: "a", spaceId: "space-b")
        let x = PhiLocalURLRule.fixture(id: "i-x", syncId: "b", spaceId: "space-a", sortOrder: 1)
        XCTAssertTrue(pointerPass([z, x], landedThisPage: ["a"], published: ["a", "b"]).isEmpty)
        XCTAssertNil(z.mergePartnerSyncId)
        XCTAssertNil(x.mergePartnerSyncId)
    }

    // =======================================================================================
    // MARK: - CASE M-3c / M-17（带未发布编辑的成员不静止，但要写指针）
    // =======================================================================================

    /// 防的是什么：把指针的条件绑在「有静止胜者」上 ⇒ §8.4.6 竞态 3 掉进「指针从没被写过」那
    /// 一格、终态两条规则。把静止判据 6 写成 `server == reconciled` 之外的任何投影比较也在这里红。
    func testM3c_aMemberWithAnUnpublishedEditIsNotAtRestButStillGetsThePointer() throws {
        /// `edited` 那一条不静止（`pendingLocalEdit` 或 `server != reconciled`），另一条是锚点。
        func run(editedIsLarger: Bool, viaServerMismatch: Bool) -> (URLRuleMergeResult, String) {
            let editedId = editedIsLarger ? "b" : "a"
            let otherId = editedIsLarger ? "a" : "b"
            var rows: [PhiLocalURLRule] = []
            var table = PhiOwnedItemTable()
            seedSettled(otherId, id: "i-other", accountStamp: 10, rows: &rows, table: &table)
            seedSettled(editedId, id: "i-edited", ask: true, sortOrder: 1, accountStamp: 20,
                        pendingLocalEdit: !viaServerMismatch, rows: &rows, table: &table)
            if viaServerMismatch {
                table.cursors[editedId]?.server = Data([0x07])
            }
            return (mergePass(rows: rows, table: table, atRest: [otherId]), editedId)
        }

        // 被编辑的那条 `syncId` 更大 ⇒ 它行上此刻带着指向组内最小已发布 `syncId` 的那一列。
        let (larger, _) = run(editedIsLarger: true, viaServerMismatch: false)
        XCTAssertEqual(larger.collapsed, 0)
        XCTAssertEqual(larger.ops, [.setMergePartner(syncId: "b", mergePartnerSyncId: "a")])

        // 对称变体：被编辑的那条更小（它自己是锚点）⇒ **另一条**带着指向它的那一列。
        let (smaller, _) = run(editedIsLarger: false, viaServerMismatch: false)
        XCTAssertEqual(smaller.collapsed, 0)
        XCTAssertEqual(smaller.ops, [.setMergePartner(syncId: "b", mergePartnerSyncId: "a")])

        // 对照二：`server != reconciled` ⇒ 判据 2 不成立 ⇒ 同样零收敛且写下指针。
        let (mismatch, _) = run(editedIsLarger: true, viaServerMismatch: true)
        XCTAssertEqual(mismatch.collapsed, 0)
        XCTAssertEqual(mismatch.ops, [.setMergePartner(syncId: "b", mergePartnerSyncId: "a")])
    }

    /// CASE M-17 的 M2 半边：胜者被 retarget ⇒ 败者被软删、**胜者的 rank 与目标一个字节都不动**，
    /// 而且 M2 **绝不**把败者拉回来（它只写 `deletedDate`，从不清空它）。
    func testM17_theLoserIsSoftDeletedAndTheWinnerIsNeverTouchedOrPulledBack() throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        // 两条的有效账户戳相同 ⇒ 内容组零写（「戳推进」那一格由 CASE M-6b (a) 单独钉）。
        seedSettled("a", id: "i-z", sortOrder: 0, accountStamp: 10, rows: &rows, table: &table)
        seedSettled("b", id: "i-x", sortOrder: 1, accountStamp: 10, rows: &rows, table: &table)

        let out = mergePass(rows: rows, table: table, atRest: ["a", "b"])
        XCTAssertEqual(out.collapsed, 1)
        XCTAssertEqual(out.ops, [.softDelete(syncId: "b", mergePartnerSyncId: "a")],
                       "胜者 Z 一条 op 都没有：rank 与目标一个字节不动")

        // M2 软删之后**只写 `deletedDate`，从不清空它**：把软删过的 X 原样喂回去，它不是组成员
        // （活行过滤），`collapsed` 此后恒 0，X 绝不被拉回 S2。
        var afterCollapse = rows
        afterCollapse[1].deletedDate = Date(timeIntervalSince1970: 7)
        afterCollapse[1].mergePartnerSyncId = "a"
        let next = mergePass(rows: afterCollapse, table: table, atRest: ["a", "b"])
        XCTAssertEqual(next.collapsed, 0)
        XCTAssertTrue(next.ops.isEmpty, "胜者那一列本来就是 nil ⇒ 清空规则①也没什么可写")
        XCTAssertEqual(afterCollapse[1].deletedDate, Date(timeIntervalSince1970: 7))
    }

    // =======================================================================================
    // MARK: - CASE M-16（让位对用户做的删除同样成立 —— 本任务只断 M2 的那一半）
    // =======================================================================================

    /// 防的是什么：一个「组里只有它一条也写指针」的实现会给它写上一个指向它自己的
    /// `mergePartnerSyncId`（RR7-13 禁止），(i) 支于是把它的编辑转移到它自己身上、tombstone
    /// 照常硬删 ⇒ 那次编辑永久丢失，而日志上看不出任何异常。
    func testM16_aLoneMemberNeverGetsAPointerAndIsNeverCollapsed() async throws {
        let access = FakeURLRuleAccess(rows: [
            .fixture(id: "i1", syncId: "a", host: "github.com", askBeforeRouting: true,
                     contentUpdatedDate: Date(timeIntervalSince1970: 30), pendingLocalEdit: true),
        ])
        let store = MemoryOwnedItemStore()
        store.table.cursors["a"] = publishedRuleCursor(urlRulePayload(uuid: "a"),
                                                       entityId: "srv-a")
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([], marker: "7")]
        let engine = try makeRuleEngine(access, store, client: client)
        await engine.setSpaceSyncEnabled(true)

        for _ in 0..<3 {
            await engine.pullOnce()
            let counters = await counters(engine)
            XCTAssertEqual(counters?.collapsed, 0)
            XCTAssertNil(row(access, "a")?.mergePartnerSyncId,
                         "`members.count == 1` ⇒ 那一列恒为 nil（让位走 (ii) 支的结构性前提）")
            XCTAssertNil(row(access, "a")?.deletedDate, "M2 一次都没碰它的 `deletedDate`")
        }
        XCTAssertEqual(row(access, "a")?.contentUpdatedDate, Date(timeIntervalSince1970: 30),
                       "三枚戳一个都没被 M2 碰过")
    }

    // =======================================================================================
    // MARK: - CASE M-3（收敛的胜者是确定的 + 指针优先级）—— 引擎级
    // =======================================================================================

    /// 防的是什么：任何依赖每设备量（本机铸的 `syncId`、`createdDate`、`id`、`sortOrder`）的
    /// 胜者选择在两台上分叉。指针那一半防的是 RR11-2。
    func testM3_theWinnerIsDeterministicAndTheLosersPointAtIt() async throws {
        /// 三条同签名活行，按给定的排布重跑一遍。
        func run(order: [(syncId: String, id: String, sortOrder: Int, created: TimeInterval)])
            async throws -> FakeURLRuleAccess {
            var rows: [PhiLocalURLRule] = []
            var table = PhiOwnedItemTable()
            for entry in order {
                seedSettled(entry.syncId, id: entry.id, sortOrder: entry.sortOrder,
                            accountStamp: 100,
                            createdDate: Date(timeIntervalSince1970: entry.created),
                            rows: &rows, table: &table)
            }
            let access = FakeURLRuleAccess(rows: rows)
            let store = MemoryOwnedItemStore()
            store.table = table
            let client = FakePhiSyncClient()
            client.pagesByMarker = [page([], marker: "7")]
            let engine = try makeRuleEngine(access, store, client: client)
            await engine.setSpaceSyncEnabled(true)
            await engine.pullOnce()
            let counters = await counters(engine)
            XCTAssertEqual(counters?.collapsed, 2)
            return access
        }

        // ① 基准排布。
        let base = try await run(order: [("b", "i-b", 0, 1_000), ("a", "i-a", 1, 2_000),
                                          ("c", "i-c", 2, 3_000)])
        XCTAssertNil(row(base, "a")?.deletedDate, "胜者是 `a`")
        XCTAssertNotNil(row(base, "b")?.deletedDate)
        XCTAssertNotNil(row(base, "c")?.deletedDate)
        XCTAssertEqual(row(base, "b")?.mergePartnerSyncId, "a")
        XCTAssertEqual(row(base, "c")?.mergePartnerSyncId, "a")
        XCTAssertNil(row(base, "a")?.mergePartnerSyncId, "胜者自己那一列是空的")

        // ② 把插入次序、`id`、`sortOrder`、`createdDate` 全部打乱重跑 ⇒ 胜者仍是 `a`。
        let shuffled = try await run(order: [("c", "z-1", 2, 9_000), ("b", "z-2", 0, 5_000),
                                             ("a", "z-9", 1, 7_000)])
        XCTAssertNil(row(shuffled, "a")?.deletedDate)
        XCTAssertEqual(row(shuffled, "b")?.mergePartnerSyncId, "a")
        XCTAssertEqual(row(shuffled, "c")?.mergePartnerSyncId, "a")
    }

    /// 对照组：组里另有一条 `syncId` 字典序**更小**、已发布但带 `pendingLocalEdit` 的 `"A0"`
    /// ⇒ 锚点是 `"A0"`，但**败者行上 `mergePartnerSyncId` 仍是 `"a"`（胜者），不是锚点**。
    ///
    /// 防的是什么：第二遍无条件覆盖的实现会把败者的指针改成锚点，而败者一软删就退出
    /// `allURLRules()`、M2 再也不会为它补写第二次 ⇒ 指针永久指向一条不是胜者的行。
    func testM3_theLoserPointerIsTheWinnerNotTheAnchor() async throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        seedSettled("A0", id: "i-a0", accountStamp: 100, pendingLocalEdit: true,
                    rows: &rows, table: &table)
        seedSettled("a", id: "i-a", sortOrder: 1, accountStamp: 100, rows: &rows, table: &table)
        seedSettled("b", id: "i-b", sortOrder: 2, accountStamp: 100, rows: &rows, table: &table)
        seedSettled("c", id: "i-c", sortOrder: 3, accountStamp: 100, rows: &rows, table: &table)

        let access = FakeURLRuleAccess(rows: rows)
        let store = MemoryOwnedItemStore()
        store.table = table
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([], marker: "7")]
        let engine = try makeRuleEngine(access, store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let counters = await counters(engine)
        XCTAssertEqual(counters?.collapsed, 2, "`A0` 不静止 ⇒ 静止成员是 a / b / c")
        XCTAssertEqual(row(access, "b")?.mergePartnerSyncId, "a", "败者指向**胜者**")
        XCTAssertEqual(row(access, "c")?.mergePartnerSyncId, "a")
        XCTAssertNil(row(access, "A0")?.deletedDate, "带未发布编辑的那条一个字节不动")
        XCTAssertNil(row(access, "A0")?.mergePartnerSyncId, "它是锚点 ⇒ 自己那一列恒为 nil")
        XCTAssertEqual(row(access, "a")?.mergePartnerSyncId, "A0",
                       "软删之后的活集里 `a` 不是锚点 ⇒ 它拿到指向锚点的那一列")
    }

    // =======================================================================================
    // MARK: - CASE M-5（幂等与「本机绝不两条同死」）
    // =======================================================================================

    /// 防的是什么：`settled.first` 若也进 `dropFirst()` 的定义域，本机这一台上某个签名组会一条
    /// 不剩；幂等破掉则每一页都重跑一次软删与吸收，publisher 每页发射一次、稳态当场破。
    func testM5_convergenceIsIdempotentAndAlwaysLeavesOneLiveRow() async throws {
        for count in [2, 3, 5] {
            var rows: [PhiLocalURLRule] = []
            var table = PhiOwnedItemTable()
            for offset in 0..<count {
                seedSettled("r\(offset)", id: "i\(offset)", sortOrder: offset, accountStamp: 100,
                            rows: &rows, table: &table)
            }
            let access = FakeURLRuleAccess(rows: rows)
            let store = MemoryOwnedItemStore()
            store.table = table
            let client = FakePhiSyncClient()
            client.pagesByMarker = [page([], marker: "7")]
            let engine = try makeRuleEngine(access, store, client: client)
            await engine.setSpaceSyncEnabled(true)

            await engine.pullOnce()
            let first = await counters(engine)
            XCTAssertEqual(first?.collapsed, count - 1, "count=\(count)")
            XCTAssertEqual(liveRows(access).count, 1, "count=\(count)：收敛之后至少一条活行")
            XCTAssertEqual(liveRows(access).first?.syncId, "r0")
            let refreshesAfterFirst = refreshCalls(access)

            // 第二页：零落地 step、尾钩照跑 ⇒ `collapsed == 0`、`ops` 为空、**零次行写**。
            await engine.pullOnce()
            let second = await counters(engine)
            XCTAssertEqual(second?.collapsed, 0, "count=\(count)")
            XCTAssertTrue(mergeOps(access).isEmpty, "count=\(count)：第二页零 op")
            XCTAssertTrue(access.lastAppliedOps.isEmpty)
            XCTAssertEqual(refreshCalls(access), refreshesAfterFirst,
                           "count=\(count)：稳态零刷新")
            XCTAssertEqual(liveRows(access).count, 1)
        }
    }

    // =======================================================================================
    // MARK: - CASE M-7（收敛不回声 + 指针零写 + 单成员清空）
    // =======================================================================================

    /// 承重的是那条前置（RR12-7）——把「只写此刻为 nil 或指向一条没有活行的身份的活成员」
    /// 放宽、只靠原语零写的实现在这里红：指针的调用面是「两遍分组 × 每一页 × 组内每一个非锚点
    /// 成员」，无条件写就是一次全库每页重写。
    ///
    /// **本条不断言路由刷新的载荷内容**（测试进程里桥是 nil），只断言钩子的触发次数。
    func testM7_anAlreadyPointedGroupWritesNothingAndRefreshesNothing() async throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        seedSettled("a", id: "i-a", accountStamp: 100, rows: &rows, table: &table)
        // 非锚点那条已经指向锚点，而且它带着一次未发布编辑 ⇒ 不静止 ⇒ 这一组已经收敛完了。
        seedSettled("b", id: "i-b", sortOrder: 1, accountStamp: 100, pendingLocalEdit: true,
                    mergePartnerSyncId: "a", rows: &rows, table: &table)

        let access = FakeURLRuleAccess(rows: rows)
        let store = MemoryOwnedItemStore()
        store.table = table
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([], marker: "7")]
        let engine = try makeRuleEngine(access, store, client: client)
        await engine.setSpaceSyncEnabled(true)

        let before = access.rows
        for _ in 0..<3 { await engine.pullOnce() }
        let counters = await counters(engine)
        XCTAssertEqual(counters?.collapsed, 0)
        XCTAssertTrue(mergeOps(access).isEmpty, "零次 `SpaceURLRule` 行写")
        XCTAssertEqual(access.rows, before, "三轮下来一个字节都没动")
        XCTAssertEqual(refreshCalls(access), 0, "落地后刷新钩子零次触发")
        XCTAssertTrue(ruleCommits(client).isEmpty, "`urlRulesPublisher` 这一侧零发射的等价断言")
    }

    /// 清空规则①：胜者此刻**静止**且它的签名组里只剩它自己（`members.count == 1`）⇒ 它的
    /// `mergePartnerSyncId` 被清空。防的是 RR9-4 的措辞陷阱（写成「不在任何签名组里」按字面
    /// 永不成立，陈旧伙伴的窗口只剩第一条）。
    func testM7_aLoneSettledMemberGetsItsStalePartnerCleared() async throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        seedSettled("a", id: "i-a", accountStamp: 100, mergePartnerSyncId: "gone",
                    rows: &rows, table: &table)

        let access = FakeURLRuleAccess(rows: rows)
        let store = MemoryOwnedItemStore()
        store.table = table
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([], marker: "7")]
        let engine = try makeRuleEngine(access, store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertEqual(mergeOps(access), [.setMergePartner(syncId: "a", mergePartnerSyncId: nil)])
        XCTAssertNil(row(access, "a")?.mergePartnerSyncId)
        XCTAssertEqual(refreshCalls(access), 0, "指针写不刷路由表")
        // 幂等：清过之后不再写。
        await engine.pullOnce()
        XCTAssertTrue(mergeOps(access).isEmpty)
    }

    // =======================================================================================
    // MARK: - CASE M-15（drain / 重放期间：第 2 步不跑，第 1 步照跑）
    // =======================================================================================

    /// 断言的是「第 2 步不跑」，**不是「整趟零写」**——把断言写成「一个字节都没写」的实现会把
    /// R-M3-4a-74(3) 判红；反过来，把指针也留在闸后面的实现会让「Z 那次改目标落在 drain /
    /// 报损重放里」的那一格永远写不出指针、终态两条规则。
    func testM15_theGateStopsTheSecondStepButNeverThePointer() async throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        seedSettled("a", id: "i-a", accountStamp: 100, rows: &rows, table: &table)
        seedSettled("b", id: "i-b", sortOrder: 1, accountStamp: 100, rows: &rows, table: &table)

        let access = FakeURLRuleAccess(rows: rows)
        let store = MemoryOwnedItemStore()
        store.table = table
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([], marker: "7")]
        let spaceStore = MemorySpaceStore()
        spaceStore.table.hasDrainedFullReplay = false      // 闸关着
        try silenceOtherSections(spaceStore)
        let engine = makeEngine(client: client, markerStore: markerStore(marker: "0"),
                                spaceStore: spaceStore,
                                ownedKinds: [.urlRules(access: access, store: store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let gated = await counters(engine)
        XCTAssertEqual(gated?.collapsed, 0, "零次软删、零次内容组吸收")
        XCTAssertNil(row(access, "a")?.deletedDate)
        XCTAssertNil(row(access, "b")?.deletedDate)
        XCTAssertEqual(row(access, "b")?.mergePartnerSyncId, "a", "同一页里指针已经指向锚点")
        XCTAssertEqual(refreshCalls(access), 0, "纯指针写 ⇒ 零刷新")

        // 闸打开之后的下一页：`collapsed == 1`。
        spaceStore.table.hasDrainedFullReplay = true
        await engine.pullOnce()
        let opened = await counters(engine)
        XCTAssertEqual(opened?.collapsed, 1)
        XCTAssertNotNil(row(access, "b")?.deletedDate)
        XCTAssertNil(row(access, "a")?.deletedDate)
    }

    // =======================================================================================
    // MARK: - CASE M-35（空页也收敛，走完整引擎入口）（R-M3-4a-99 / R-M3-4a-56）
    // =======================================================================================

    /// 防的是什么：只放宽 `guard !ops.isEmpty`（Task 8 那句）与 `land` 闭包那条早退、却没动
    /// 引擎那道空批次早退 guard 的实现。drain 结束之后的稳态里绝大多数页正是「三者全空」这
    /// 一种，于是「纯本机重复也要收敛」在**首次 drain 之后就再也不执行**。
    func testM35_anEmptyPageStillRunsTheMergeThroughTheFullEngineEntry() async throws {
        /// (i) 这一页只带一条 Space 更新；(ii) 这一页干脆是空页。
        for carriesSpace in [true, false] {
            var rows: [PhiLocalURLRule] = []
            var table = PhiOwnedItemTable()
            seedSettled("a", id: "i-a", accountStamp: 100, rows: &rows, table: &table)
            seedSettled("b", id: "i-b", sortOrder: 1, accountStamp: 100, rows: &rows, table: &table)

            let access = FakeURLRuleAccess(rows: rows)
            let store = MemoryOwnedItemStore()
            store.table = table
            let client = FakePhiSyncClient()
            let entities: [PhiRemoteEntity] = carriesSpace
                ? [remoteEntity(envelope(spacePayload(uuid: "su-9")),
                                tag: PhiSyncEntity.spaceClientTag("su-9"), version: 3, key: key)]
                : []
            client.pagesByMarker = [page(entities, marker: "7")]
            let engine = try makeRuleEngine(access, store, client: client)
            await engine.setSpaceSyncEnabled(true)
            await engine.pullOnce()

            let label = carriesSpace ? "(i) 只带 Space" : "(ii) 空页"
            // `plan` 与 `land` 都被调过：`FakeURLRuleAccess.calls` 里有一条 `.apply`，尽管
            // `ops` 为空。
            XCTAssertEqual(applyCalls(access), 1, label)
            XCTAssertTrue(access.lastAppliedOps.isEmpty, "\(label)：零落地 op")
            let counters = await counters(engine)
            XCTAssertEqual(counters?.collapsed, 1, label)
            XCTAssertNotNil(row(access, "b")?.deletedDate, label)
            XCTAssertEqual(row(access, "b")?.mergePartnerSyncId, "a", label)
            // `mergeChangedRouting == true` ⇒ Task 6 那个落地后钩子刷一次路由表（计划裁定七）。
            XCTAssertEqual(refreshCalls(access), 1, "\(label)：§6.6 第 8 行")

            // 随后两轮稳态。
            for _ in 0..<2 { await engine.pullOnce() }
            let steady = await counters(engine)
            XCTAssertEqual(steady?.collapsed, 0, label)
            XCTAssertEqual(refreshCalls(access), 1, "\(label)：稳态不再刷新")
        }
    }

    /// 负面对照的**结构性**半边：这道 guard 的第四个析取项就是 `landsEmptyBatch`，而三条 kind
    /// 里只有规则取 `true`。取 `false`（或不补那个析取项）⇒ `applyOwnedKind` 在 `plan` 之前就
    /// return ⇒ `collapsed` 永远是 0、A 与 B 永远并存。
    func testM35_onlyTheRuleKindLandsAnEmptyBatch() {
        let ruleStore = MemoryOwnedItemStore()
        let rules = OwnedKindRegistration.urlRules(access: FakeURLRuleAccess(), store: ruleStore)
        let bookmarks = OwnedKindRegistration.bookmarks(access: FakeBookmarkAccess(),
                                                        store: MemoryOwnedItemStore())
        let pins = OwnedKindRegistration.pins(access: FakePinAccess(scope: .profile),
                                              store: MemoryOwnedItemStore())
        XCTAssertTrue(rules.landsEmptyBatch)
        XCTAssertFalse(bookmarks.landsEmptyBatch, "书签的早退逐字保留")
        XCTAssertFalse(pins.landsEmptyBatch, "pin 的早退逐字保留")
    }

    /// 对照（书签与 pin 逐字不变）：同一页里两个 kind **零条 `.apply`**——它们的
    /// `landsEmptyBatch == false`，早退支照旧走。
    func testM35_bookmarksAndPinsStillTakeTheirEarlyReturnOnAnEmptyPage() async throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        seedSettled("a", id: "i-a", accountStamp: 100, rows: &rows, table: &table)
        seedSettled("b", id: "i-b", sortOrder: 1, accountStamp: 100, rows: &rows, table: &table)

        let ruleAccess = FakeURLRuleAccess(rows: rows)
        let ruleStore = MemoryOwnedItemStore()
        ruleStore.table = table
        let bookmarkAccess = FakeBookmarkAccess(rows: [.fixture(guid: "G1", syncId: "bk1",
                                                                spaceId: "space-a")])
        let pinAccess = FakePinAccess(scope: .profile)
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([], marker: "7")]
        let spaceStore = MemorySpaceStore()
        spaceStore.table.hasDrainedFullReplay = true
        try silenceOtherSections(spaceStore)
        let engine = makeEngine(
            client: client, markerStore: markerStore(marker: "0"), spaceStore: spaceStore,
            ownedKinds: [.bookmarks(access: bookmarkAccess, store: MemoryOwnedItemStore()),
                         .pins(access: pinAccess, store: MemoryOwnedItemStore()),
                         .urlRules(access: ruleAccess, store: ruleStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertEqual(applyCalls(ruleAccess), 1, "规则那一条走完了 `land`")
        XCTAssertFalse(bookmarkAccess.calls.contains { if case .apply = $0 { return true } else { return false } },
                       "书签零条 `.apply`")
        XCTAssertFalse(pinAccess.calls.contains { if case .apply = $0 { return true } else { return false } },
                       "pin 零条 `.apply`")
    }

    // =======================================================================================
    // MARK: - CASE M-36（pre-pass 之后的本机编辑：静止集只是上界）（R-M3-4a-100）
    // =======================================================================================

    /// 防的是什么：「pre-pass 在主 actor 上算、落地事务在写队列上跑」这两个时刻之间的窗口。
    /// 只按 pre-pass 那份 `atRest` 实现（事务里不再剔除）⇒ `source` 取 B（20 > 10，W 那次 Save
    /// 没上账户）⇒ **W 被覆写回戳 20**，用户刚按下的那次 Save 在同一页里被机器抹掉。
    func testM36_aLocalSaveBetweenThePrePassAndTheTransactionLeavesTheCandidateSet() async throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        seedSettled("a", id: "i-w", ask: false, accountStamp: 10, rows: &rows, table: &table)
        seedSettled("b", id: "i-b", ask: true, sortOrder: 1, accountStamp: 20,
                    rows: &rows, table: &table)

        let access = FakeURLRuleAccess(rows: rows)
        let store = MemoryOwnedItemStore()
        store.table = table
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([], marker: "7")]
        // pre-pass 与落地事务之间的那一次**真实用户写**（编辑器语义，绝不手写行或游标）。
        access.beforeLandingTransaction = { [weak access] in
            access?.applyEditorSave(syncId: "a", ask: true, at: Date(timeIntervalSince1970: 0.030))
        }
        let engine = try makeRuleEngine(access, store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let counters = await counters(engine)
        XCTAssertEqual(counters?.collapsed, 0, "W 退出候选集 ⇒ 静止成员只剩 B 一条")
        XCTAssertNil(row(access, "b")?.deletedDate, "B 没有被软删")
        let w = try XCTUnwrap(row(access, "a"))
        XCTAssertEqual(w.askBeforeRouting, true, "W 一个字节没被 M2 动过")
        XCTAssertEqual(w.contentUpdatedDate, Date(timeIntervalSince1970: 0.030),
                       "戳仍是那次 Save 的 30，**不是** B 的 20")
        XCTAssertTrue(w.pendingLocalEdit)
        XCTAssertNil(row(access, "b")?.mergePartnerSyncId,
                     "`members.count == 1` 那条清空规则不触发（B 本来就是 nil）")
    }

    // =======================================================================================
    // MARK: - CASE M2-b（`preLandingSignatures` 取的是**落地前**目标，且每页重算）（RR12-5）
    // =======================================================================================

    /// 防的是什么：按「轮首冻结一次投影」实现的版本第 2 页会算出 S2 ⇒ 第二遍按一个**两页之前**
    /// 的签名分组、把指针写到错误的锚点上，而「只写 nil 或悬空」的前置会让那个错值**粘住**、
    /// 下一页不会纠正，而且**静默**。
    ///
    /// 上半：模块级探针。`plan` 在**产出 step 的那一刻**照身份查 `context.localSignatures`，
    /// 查不到的身份**结构性地不在表里**（不强解包、不填空值）。
    func testM2b_thePlanRecordsThePreLandingSignatureWhenItEmitsTheStep() throws {
        var table = PhiOwnedItemTable()
        table.cursors["a"] = publishedRuleCursor(
            urlRulePayload(uuid: "a", host: "old.example", contentStamp: 100), entityId: "srv-a")
        let arrival = OwnedItemArrival(
            entity: urlRulePayload(uuid: "a", host: "new.example", contentStamp: 900),
            entityId: "srv-a", version: 7)
        let signature = RuleSignature(host: "old.example", pathPrefix: nil, owner: "su-1")

        var context = OwnedItemPlanContext()
        context.localSignatures = ["a": signature]
        let recorded = SyncableOwnedItems.plan(URLRuleKind.self, arrivals: [arrival], parked: [:],
                                               table: table, resolve: resolve, context: context)
        XCTAssertTrue(recorded.steps.contains { $0.identity == "a" && $0.kind == .update },
                      "这一页真的产出了一条 `.update`")
        XCTAssertEqual(recorded.preLandingSignatures["a"], signature,
                       "记的是**落地前**那一个（`old.example`），不是载荷里的新值")

        // 算不出签名的身份不进表：**不强解包、不填空值**。
        let missing = SyncableOwnedItems.plan(URLRuleKind.self, arrivals: [arrival], parked: [:],
                                              table: table, resolve: resolve,
                                              context: OwnedItemPlanContext())
        XCTAssertTrue(missing.preLandingSignatures.isEmpty)

        // 书签与 pin 那两条路径永不填 `localSignatures` ⇒ 这一位恒空（行为逐字不变）。
        var bookmarkTable = PhiOwnedItemTable()
        bookmarkTable.cursors["bk"] = ownedCursor(
            reconciled: baselineBytes(bookmarkPayload(uuid: "bk", title: "old")),
            server: baselineBytes(bookmarkPayload(uuid: "bk", title: "old")),
            entityId: "srv-bk", version: 1, ownerUuid: "su-1")
        let bookmarkPlan = SyncableOwnedItems.plan(
            BookmarkKind.self,
            arrivals: [OwnedItemArrival(entity: bookmarkPayload(uuid: "bk", title: "new",
                                                                contentStamp: 900),
                                        entityId: "srv-bk", version: 7)],
            parked: [:], table: bookmarkTable, resolve: resolve, context: OwnedItemPlanContext())
        XCTAssertTrue(bookmarkPlan.preLandingSignatures.isEmpty, "书签恒空")
    }

    /// 下半：引擎级。同一轮两页，Z 连搬两次目标而 X 两页都不落地 ⇒ 第 2 页那次第二遍分组用的
    /// 是 Z 在**第 2 页开始时**（也就是第 1 页落地之后）的目标，指针因此落在 X 的行上、指向 Z。
    func testM2b_thePreLandingSignatureIsRecomputedEveryPage() async throws {
        // Z 起点在 `space-c`（su-3）；第 1 页 `.move` 到 `space-b`（su-2），第 2 页再到
        // `space-a`（su-1）。X 此刻在 `space-b`、两页都不落地（它压着一次未发布的用户编辑）。
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        seedSettled("a", id: "i-z", spaceId: "space-c", target: "su-3", accountStamp: 100,
                    rows: &rows, table: &table)
        seedSettled("b", id: "i-x", spaceId: "space-b", target: "su-2", sortOrder: 1,
                    accountStamp: 100, pendingLocalEdit: true, rows: &rows, table: &table)

        let access = FakeURLRuleAccess(rows: rows)
        let store = MemoryOwnedItemStore()
        store.table = table
        let client = FakePhiSyncClient()
        client.pagesByMarker = [
            page([ruleEntity(urlRulePayload(uuid: "a", targetSpaceUuid: "su-2",
                                            rank: "V", contentStamp: 100, targetStamp: 900,
                                            rankStamp: 900), version: 7)],
                 marker: "7", changesRemaining: true),
            page([ruleEntity(urlRulePayload(uuid: "a", targetSpaceUuid: "su-1",
                                            rank: "V", contentStamp: 100, targetStamp: 1_900,
                                            rankStamp: 1_900), version: 8)],
                 marker: "8"),
        ]
        let engine = try makeRuleEngine(access, store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertEqual(row(access, "a")?.spaceId, "space-a", "两页 `.move` 都落地了")
        XCTAssertEqual(row(access, "b")?.mergePartnerSyncId, "a",
                       "指针写在 X 的行上、指向 Z（第二遍按**落地前**的目标分组）")
        XCTAssertNil(row(access, "a")?.mergePartnerSyncId, "Z 是锚点")
        let counters = await counters(engine)
        XCTAssertEqual(counters?.collapsed, 0, "X 不静止 ⇒ 静止成员不足两条")
    }

    // =======================================================================================
    // MARK: - CASE M-6（两台并发新建，收敛到同一条身份）（R-M3-4a-67）
    // =======================================================================================

    /// 承重的断言：两台机器对同一个签名组选出**同一个幸存者**，而两台的每设备量
    /// （本机行 `id`、`createdDate`、桶内 `sortOrder`、插入次序）刻意造得完全不同。
    ///
    /// 防的是什么：胜者选择一旦依赖任何每设备量，两台就会软删不同的那一条 —— 终态两台各剩
    /// 不同的一条规则，而账户上两条都在。`syncId` 字典序是唯一的账户级定序键。
    func testM6_twoDevicesPickTheSameSurvivorDespiteDifferentLocalQuantities() async throws {
        /// 一台机器：同一对账户身份 `rule-a` / `rule-b`，两条都已发布且静止。
        func makeDevice(_ name: String, layout: [(syncId: String, id: String, sortOrder: Int,
                                                  created: TimeInterval)]) throws
            -> (engine: PhiSyncEngine, access: FakeURLRuleAccess, suite: String) {
            let suite = "URLRuleMergeTests.M6.\(name).\(UUID().uuidString)"
            let deviceDefaults = UserDefaults(suiteName: suite)!
            deviceDefaults.set(try Phi_PhiSettingEntity().serializedData(),
                               forKey: PhiSyncEngine.lastEntityStateKey)
            var rows: [PhiLocalURLRule] = []
            var table = PhiOwnedItemTable()
            for entry in layout {
                seedSettled(entry.syncId, id: entry.id, sortOrder: entry.sortOrder,
                            accountStamp: 100,
                            createdDate: Date(timeIntervalSince1970: entry.created),
                            rows: &rows, table: &table)
            }
            let access = FakeURLRuleAccess(rows: rows)
            let store = MemoryOwnedItemStore()
            store.table = table
            let spaceStore = MemorySpaceStore()
            spaceStore.table.hasDrainedFullReplay = true
            for uuid in ["su-1", "su-2", "su-3"] {
                spaceStore.table.unreadableTagHashes[
                    PhiSyncEntity.clientTagHash(for: PhiSyncEntity.spaceClientTag(uuid))] = 1
            }
            let client = FakePhiSyncClient()
            client.pagesByMarker = [page([], marker: "7")]
            let engine = PhiSyncEngine(domainKeys: StubDomainKeys(key: key), client: client,
                                       defaults: deviceDefaults, deviceKeyId: "dev-\(name)",
                                       settings: [], spaceAccess: makeSpaceAccess(),
                                       spaceStore: spaceStore,
                                       markerStore: markerStore(marker: "0"),
                                       ownedKinds: [.urlRules(access: access, store: store)],
                                       now: { Self.now })
            return (engine, access, suite)
        }

        // A：`rule-a` 是后插的、`id` 更大、桶里排在后面、`createdDate` 更晚。
        let deviceA = try makeDevice("A", layout: [("rule-b", "z-row", 0, 1_000),
                                                   ("rule-a", "a-row", 1, 9_000)])
        // B：三项每设备量全部相反。
        let deviceB = try makeDevice("B", layout: [("rule-a", "z-row", 0, 9_000),
                                                   ("rule-b", "a-row", 1, 1_000)])
        defer {
            UserDefaults.standard.removePersistentDomain(forName: deviceA.suite)
            UserDefaults.standard.removePersistentDomain(forName: deviceB.suite)
        }
        await deviceA.engine.setSpaceSyncEnabled(true)
        await deviceB.engine.setSpaceSyncEnabled(true)
        await deviceA.engine.pullOnce()
        await deviceB.engine.pullOnce()

        let a = await deviceA.engine.lastOwnedRoundCountersForTesting["urlrules"]
        let b = await deviceB.engine.lastOwnedRoundCountersForTesting["urlrules"]
        XCTAssertEqual(a?.collapsed, 1)
        XCTAssertEqual(b?.collapsed, 1)
        // **软删的身份逐字相同**：胜者是 `syncId` 字典序最小的 `rule-a`。
        XCTAssertEqual(liveRows(deviceA.access).compactMap(\.syncId), ["rule-a"])
        XCTAssertEqual(liveRows(deviceB.access).compactMap(\.syncId), ["rule-a"])
        XCTAssertEqual(row(deviceA.access, "rule-b")?.mergePartnerSyncId, "rule-a")
        XCTAssertEqual(row(deviceB.access, "rule-b")?.mergePartnerSyncId, "rule-a")

        // 稳态：再跑两轮零 `collapsed`。
        for _ in 0..<2 {
            await deviceA.engine.pullOnce()
            await deviceB.engine.pullOnce()
        }
        let steadyA = await deviceA.engine.lastOwnedRoundCountersForTesting["urlrules"]
        let steadyB = await deviceB.engine.lastOwnedRoundCountersForTesting["urlrules"]
        XCTAssertEqual(steadyA?.collapsed, 0)
        XCTAssertEqual(steadyB?.collapsed, 0)
    }

    // =======================================================================================
    // MARK: - CASE M2-d（三个原语在同一个事务里组合，冲突即整批回滚）—— 真 `LocalStore`
    // =======================================================================================

    /// 防的是什么：三个原语各自开一次 `performBackgroundWriteAndWaitThrowing`（串行写流）的
    /// 实现会在写块里**自我死锁**（R-exec-2），所以必须是「throwing 兄弟 + 私有 `…Body(…, in:)`」
    /// 两半、尾钩只调 body。把尾钩排在稠密重排**之后**的实现会在败者离开的桶里留下一个空洞
    /// 下标，而 `sortOrder` 是 `Specificity` 的第三项、排在裁决键之前。
    func testM2d_theThreePrimitivesShareOneTransactionAndTheTailRunsBeforeTheDensify() async throws {
        let store = try makeMergeStore()
        try await seedMergeRows(in: store)

        let tail = URLRuleMergeTail { _ in
            URLRuleMergeResult(
                ops: [.setContentGroup(syncId: "W", host: "github.com", pathPrefix: nil,
                                       ask: true, contentUpdatedDate: Date(timeIntervalSince1970: 0.3)),
                      .softDelete(syncId: "L1", mergePartnerSyncId: "W"),
                      .softDelete(syncId: "L2", mergePartnerSyncId: "W"),
                      .setMergePartner(syncId: "M", mergePartnerSyncId: "W")],
                collapsed: 2, touchedBuckets: ["space-a"], changedRouting: true)
        }
        let landing = URLRuleLandingValues.fixture(syncId: "M", spaceId: "space-a",
                                                   host: "other.example", sortOrder: 3)
        let outcome = try await store.applyURLRuleSyncBatchThrowing([.update(landing)],
                                                                    mergeTail: tail)
        XCTAssertEqual(outcome.collapsed, 2)
        XCTAssertTrue(outcome.mergeChangedRouting)
        XCTAssertTrue(outcome.deferredTombstones.isEmpty, "M2 自己从不填它")

        let after = try mergeRows(in: store)
        let winner = try XCTUnwrap(after["W"])
        XCTAssertTrue(winner.askBeforeRouting, "内容组落盘了")
        XCTAssertEqual(winner.contentUpdatedDate, Date(timeIntervalSince1970: 0.3))
        XCTAssertNil(winner.deletedDate)
        for loser in ["L1", "L2"] {
            XCTAssertNotNil(after[loser]?.deletedDate, loser)
            XCTAssertEqual(after[loser]?.mergePartnerSyncId, "W", "\(loser)：两列同一次行写")
            XCTAssertFalse(after[loser]?.pendingLocalEdit ?? true, "\(loser)：置位一个字节不碰")
        }
        XCTAssertEqual(after["M"]?.mergePartnerSyncId, "W")
        // 尾钩的写**排在稠密重排之前**：两条败者离开之后那个桶没有空洞。
        let live = after.values.filter { $0.deletedDate == nil }
            .sorted { $0.sortOrder < $1.sortOrder }
        XCTAssertEqual(live.map(\.sortOrder), Array(0..<live.count))
    }

    /// 冲突支：**整批回滚**。落地那条 `.update` 已经写过、尾钩的内容组与第一条软删也写过，
    /// 随后一条撞车的 op 抛 `rowAlreadyMapped` ⇒ **一条都没落盘**。
    ///
    /// 用 `.rekey` 撞车而不是「让 `.softDelete` 命中一条 `syncId` 与请求不符的行」：三个原语
    /// 一律按 `syncId` 在 `URLRuleTableIndex.bySyncId` 上寻址，那条 `rowAlreadyMapped` 守卫
    /// 在那条寻址路径上**结构性地不可达**（留着是为了寻址方式一旦变化，静默覆盖仍然变成一次
    /// 抛错）。要钉的东西是同一个：一次抛错让**尾钩已经写下的那几列**一起回滚。
    func testM2d_aConflictInsideTheTailRollsTheWholeBatchBack() async throws {
        let store = try makeMergeStore()
        try await seedMergeRows(in: store)
        let before = try mergeRows(in: store)

        let tail = URLRuleMergeTail { rows in
            let loser = rows.first { $0.syncId == "L2" }
            return URLRuleMergeResult(
                ops: [.setContentGroup(syncId: "W", host: "github.com", pathPrefix: nil,
                                       ask: true, contentUpdatedDate: Date(timeIntervalSince1970: 0.3)),
                      .softDelete(syncId: "L1", mergePartnerSyncId: "W"),
                      // 把 L2 那一行 re-key 到 W 已经占着的身份 ⇒ `rowAlreadyMapped`。
                      .rekey(localId: loser?.id ?? "missing", to: "W", values: nil)],
                collapsed: 1, touchedBuckets: ["space-a"], changedRouting: true)
        }
        let landing = URLRuleLandingValues.fixture(syncId: "M", spaceId: "space-a",
                                                   host: "other.example", sortOrder: 3)
        do {
            _ = try await store.applyURLRuleSyncBatchThrowing([.update(landing)], mergeTail: tail)
            XCTFail("expected rowAlreadyMapped")
        } catch {
            XCTAssertEqual(error as? LocalStoreWriteError, .rowAlreadyMapped)
        }

        let after = try mergeRows(in: store)
        XCTAssertEqual(after, before, "W 的内容组、L1 的 `deletedDate`、M 的指针全部没落盘")
    }

    // MARK: - M2-d 的真库脚手架

    private func makeMergeStore() throws -> LocalStore {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        mergeTempDirectories.append(directory)
        return LocalStore(account: Account(userID: "merge-test-user"),
                          storeDirectoryURL: directory,
                          presentsCompatibilityAlerts: false)
    }

    /// 一个桶里四条活行：胜者 W、两条败者 L1 / L2、一条旁观者 M。
    private func seedMergeRows(in store: LocalStore) async throws {
        try await store.performBackgroundWriteAndWaitThrowing { context in
            for (offset, syncId) in ["W", "L1", "L2", "M"].enumerated() {
                context.insert(SpaceURLRule(
                    id: "row-\(syncId)", spaceId: "space-a", host: "github.com",
                    pathPrefix: nil, askBeforeRouting: false, sortOrder: offset,
                    createdDate: Date(timeIntervalSince1970: 1_000), syncId: syncId,
                    contentUpdatedDate: nil, targetUpdatedDate: nil, deletedDate: nil,
                    pendingLocalEdit: false, mergePartnerSyncId: nil))
            }
        }
    }

    private func mergeRows(in store: LocalStore) throws -> [String: PhiLocalURLRule] {
        guard let context = store.getMainContext() else {
            throw LocalStoreWriteError.storeUnavailable
        }
        let models = try store.allURLRuleModelsIncludingDeleted(in: context)
        var out: [String: PhiLocalURLRule] = [:]
        for model in models {
            guard let syncId = model.syncId else { continue }
            out[syncId] = PhiLocalURLRule(
                id: model.id, syncId: model.syncId, spaceId: model.spaceId, host: model.host,
                pathPrefix: model.pathPrefix, askBeforeRouting: model.askBeforeRouting,
                sortOrder: model.sortOrder, createdDate: model.createdDate,
                contentUpdatedDate: model.contentUpdatedDate,
                targetUpdatedDate: model.targetUpdatedDate, deletedDate: model.deletedDate,
                pendingLocalEdit: model.pendingLocalEdit,
                mergePartnerSyncId: model.mergePartnerSyncId)
        }
        return out
    }
}

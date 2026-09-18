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

    /// **fix round 2 的探针**：第二遍的锚点子集**绝不**能建在软删之前那一份活集上。
    ///
    /// 形状：`"p"` 本页按**此刻**的签名 K1（`su-1`）被收敛掉（胜者 `"m"` 的 `syncId` 更小），
    /// 而它的**落地前**签名是 K2（`su-2`，本页一条 `.move` 把它从 `space-b` 搬到了 `space-a`）。
    /// K2 里还有一条活成员 `"z"`，`syncId` 比 `"p"` 大。
    ///
    /// 防的是什么：第二遍若沿用软删之前那一份活集求子集，K2 的子集是 `["p", "z"]`（基数 2 **正是
    /// 靠那条死行才够到的**）、锚点是 `"p"` ⇒ `"z"` 的 `mergePartnerSyncId` 当场指向一条**同一个
    /// 事务里刚被软删的行**。leg (1) 的「锚点 ≤ 胜者 < 每一条败者」只在分组键与 `convergePass`
    /// 的键相同时成立，而第二遍的键不是那一个。
    func testM2a_theSecondPassNeverAnchorsOnARowCollapsedThisPage() throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        seedSettled("m", id: "i-m", accountStamp: 100, rows: &rows, table: &table)
        seedSettled("p", id: "i-p", sortOrder: 1, accountStamp: 100, rows: &rows, table: &table)
        seedSettled("z", id: "i-z", spaceId: "space-b", target: "su-2", accountStamp: 100,
                    rows: &rows, table: &table)
        // `"p"` 这一页刚落地一条 `.move`（su-2 → su-1），所以它的落地前签名是 K2。
        let k2 = RuleSignature(host: "github.com", pathPrefix: nil, owner: "su-2")
        let preLanding = ["p": k2]

        let out = mergePass(rows: rows, table: table, atRest: ["m", "p", "z"],
                            landedThisPage: ["p"], preLanding: preLanding)
        XCTAssertEqual(out.collapsed, 1)
        XCTAssertEqual(out.ops, [.softDelete(syncId: "p", mergePartnerSyncId: "m")],
                       "`z` 一条指针都不该有：K2 的活成员只剩它自己")
        XCTAssertFalse(out.ops.contains(.setMergePartner(syncId: "z", mergePartnerSyncId: "p")),
                       "绝不指向一条同一个事务里刚被软删的行")

        // 对照（也就是 fix 之前那一版会走的那条路）：`"p"` **还活着**的时候，第二遍给 `"z"` 写的
        // 正是指向 `"p"` 的那一列——写本身是对的，错的是在它已经被本页软删之后还照写。
        // （闸关着 ⇒ 零软删；第一遍照样给 K1 的非锚点成员 `"p"` 写一条指向 `"m"` 的。）
        let alive = mergePass(rows: rows, table: table, atRest: ["m", "p", "z"],
                              convergeAllowed: false, landedThisPage: ["p"],
                              preLanding: preLanding)
        XCTAssertEqual(alive.ops, [
            .setMergePartner(syncId: "p", mergePartnerSyncId: "m"),
            .setMergePartner(syncId: "z", mergePartnerSyncId: "p"),
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

    // =======================================================================================
    // MARK: - 8b-3（§8.4.4 让位）：脚手架
    // =======================================================================================

    /// `URLRuleKind.transferSource(of:resolve:)` 的调用糖。算不出来直接炸——用例都是自己
    /// 造的合法实体。
    private func projection(_ payload: Phi_PhiURLRuleEntity) throws -> RuleProjection {
        try XCTUnwrap(URLRuleKind.transferSource(of: payload, resolve: resolve))
    }

    /// `plan.steps` 的可读形式：`"<相>:<身份>"`，转移额外带上目标。断言执行序用它。
    private func stepSummary(_ steps: [OwnedItemApplyStep]) -> [String] {
        steps.map { step in
            switch step.kind {
            case .claim: return "claim:\(step.identity)"
            case .create: return "create:\(step.identity)"
            case .move: return "move:\(step.identity)"
            case .update: return "update:\(step.identity)"
            case .transfer(_, let to): return "transfer:\(step.identity)->\(to)"
            case .delete: return "delete:\(step.identity)"
            }
        }
    }

    /// 假件记到的 op 序（`.apply` 收到的那一份，已经过 `URLRuleApplyBatch` 的四相排序）。
    private func opSummary(_ ops: [URLRuleSyncOp]) -> [String] {
        ops.map { op in
            switch op {
            case .create(let values): return "create:\(values.syncId)"
            case .update(let values): return "update:\(values.syncId)"
            case .move(let values): return "move:\(values.syncId)"
            case .reorder(let syncId, _, _): return "reorder:\(syncId)"
            case .delete(let syncId): return "delete:\(syncId)"
            case .rekey(_, let to, _): return "rekey:\(to)"
            case .softDelete(let syncId, _): return "softDelete:\(syncId)"
            case .setMergePartner(let syncId, _): return "setMergePartner:\(syncId)"
            case .setContentGroup(let syncId, _, _, _, _): return "setContentGroup:\(syncId)"
            case .transfer(let from, let to, _, _): return "transfer:\(from)->\(to)"
            }
        }
    }

    // =======================================================================================
    // MARK: - CASE 8b-3.1（开关关掉 ⇒ 书签与 pin 的 plan 逐字节不变）
    // =======================================================================================

    /// 防的是什么：把让位做成「所有 kind 共享」的实现会让书签的每一次远端删除都变成一次
    /// 复活——书签的数量级与删除频率与规则完全不同（§14.1）。
    func test8b31_theYieldSwitchIsOffForBookmarksAndPins() throws {
        XCTAssertFalse(BookmarkKind.tombstoneYieldsToLocalEdits, "书签走协议默认实现")
        XCTAssertFalse(PinKind.tombstoneYieldsToLocalEdits, "pin 走协议默认实现")
        XCTAssertTrue(URLRuleKind.tombstoneYieldsToLocalEdits, "规则是唯一开着的那一条")
        XCTAssertNil(BookmarkKind.transferSource(of: bookmarkPayload(uuid: "bk"), resolve: resolve),
                     "书签的取值源恒 nil")
        XCTAssertNil(PinKind.transferSource(of: pinPayload(lineage: "LX"), resolve: resolve),
                     "pin 的取值源恒 nil")

        // 一条书签，行上带一次未发布编辑（`server != reconciled`），同轮到达它的 tombstone。
        var table = PhiOwnedItemTable()
        table.cursors["bk"] = ownedCursor(
            reconciled: baselineBytes(bookmarkPayload(uuid: "bk", title: "local")),
            server: baselineBytes(bookmarkPayload(uuid: "bk", title: "remote")),
            entityId: "srv-bk", version: 1, ownerUuid: "su-1")
        // 四个新输入**全填上**：书签这一侧结构性地读不到它们。
        var context = OwnedItemPlanContext()
        context.tombstonedIdentities = ["bk"]
        context.pendingLocalEdits = ["bk"]
        context.unpublished = ["bk"]
        context.mergePartners = ["bk": "other"]
        context.partnerNotAtRest = ["bk"]
        let plan = SyncableOwnedItems.plan(BookmarkKind.self, arrivals: [], parked: [:],
                                           table: table, resolve: resolve, context: context)
        XCTAssertEqual(stepSummary(plan.steps), ["delete:bk"], "`.delete` 照常产出")
        XCTAssertTrue(plan.parkedTombstones.isEmpty)
        XCTAssertTrue(plan.yieldedTombstones.isEmpty)

        // 差分那一侧：`deferredDeletions` 带默认值 ⇒ `deferred` 恒空、记账逐字不变。
        let diff = SyncableOwnedItems.tombstones(BookmarkKind.self, locals: [], table: table,
                                                 resolve: resolve, scope: nil, nowMs: 100)
        XCTAssertTrue(diff.deferred.isEmpty)
        XCTAssertEqual(diff.identities, ["bk"], "既有的三条判据一个字没改")
    }

    // =======================================================================================
    // MARK: - CASE 8b-3.2（`parkedTombstones` 走正常返回路径）
    // =======================================================================================

    /// 防的是什么：只在 §7.3 那条整批早退路径上填这个集合的实现里，正常返回路径靠默认值
    /// `[]` ⇒ 那次停放**静默丢失**：三元组已收割、游标看上去健康、marker 早已推过那一页，
    /// 那条远端删除再也不会被投递第二次。
    func test8b32_aParkedTombstoneRidesTheNormalReturnPathAlongsideALanding() throws {
        var table = PhiOwnedItemTable()
        table.cursors["b"] = publishedRuleCursor(urlRulePayload(uuid: "b"), entityId: "srv-b")
        table.cursors["y"] = publishedRuleCursor(urlRulePayload(uuid: "y", host: "y.example"),
                                                 entityId: "srv-y")
        var context = OwnedItemPlanContext()
        context.tombstonedIdentities = ["b"]
        context.pendingLocalEdits = ["b"]
        context.partnerNotAtRest = ["b"]          // W 在、但不静止
        let arrival = OwnedItemArrival(
            entity: urlRulePayload(uuid: "y", host: "y2.example", contentStamp: 900),
            entityId: "srv-y", version: 7)
        let plan = SyncableOwnedItems.plan(URLRuleKind.self, arrivals: [arrival], parked: [:],
                                           table: table, resolve: resolve, context: context)

        XCTAssertEqual(plan.parkedTombstones, ["b"], "逐身份停放，走的是正常返回路径")
        XCTAssertTrue(plan.yieldedTombstones.isEmpty, "停放不是让位")
        XCTAssertFalse(plan.steps.contains { $0.identity == "b" },
                       "**不产出 `.delete`**：行一个字节不动")
        XCTAssertEqual(stepSummary(plan.steps), ["update:y"], "同页别的身份照常落地")
    }

    // =======================================================================================
    // MARK: - CASE M-12 / M-21 / M-24（落点 (α) 的三结局，模块级）
    // =======================================================================================

    /// (α) 的三结局表，一条用例三支：W 静止 ⇒ `.transfer` + **照常 `.delete`**；W 在但不静止
    /// ⇒ 停放、零 `.delete`；根本没有伙伴 ⇒ (ii)、零 `.delete`。
    ///
    /// 防的是什么：因为「W 暂时不合格」就退回 (ii) 的以两条规则收场（RR8-7）；(α) 之后走软删
    /// 而不是硬删的实现会在下一轮多发一条无谓的 tombstone（M-21）。
    func testM12_theThreeOutcomesOfAnInboundTombstoneMeetingALocalEdit() throws {
        let xPayload = urlRulePayload(uuid: "b", targetSpaceUuid: "su-2", contentStamp: 30,
                                      targetStamp: 30)
        var table = PhiOwnedItemTable()
        table.cursors["a"] = publishedRuleCursor(urlRulePayload(uuid: "a"), entityId: "srv-a")
        table.cursors["b"] = publishedRuleCursor(xPayload, entityId: "srv-b")

        func planFor(_ mutate: (inout OwnedItemPlanContext) -> Void) -> OwnedItemPlan {
            var context = OwnedItemPlanContext()
            context.tombstonedIdentities = ["b"]
            context.pendingLocalEdits = ["b"]
            context.localProjections["b"] = baselineBytes(xPayload)
            mutate(&context)
            return SyncableOwnedItems.plan(URLRuleKind.self, arrivals: [], parked: [:],
                                           table: table, resolve: resolve, context: context)
        }

        // (i) 支：转移**第三相**、硬删**第四相**，同一批、同一个事务。
        let transferred = planFor { $0.mergePartners = ["b": "a"] }
        XCTAssertEqual(stepSummary(transferred.steps), ["transfer:b->a", "delete:b"],
                       "转移在前、硬删在后")
        XCTAssertTrue(transferred.yieldedTombstones.isEmpty)
        XCTAssertTrue(transferred.parkedTombstones.isEmpty)
        let expectedSource = try projection(xPayload)
        if case .transfer(let source, let to) = transferred.steps[0].kind {
            XCTAssertEqual(to, "a")
            XCTAssertEqual(source, expectedSource, "取值源是 X 的本机行投影")
            XCTAssertEqual(source.targetSpaceId, "space-b", "账户级目标反查成了本机 Space id")
        } else {
            XCTFail("第一条 step 必须是 `.transfer`")
        }

        // 停放支：**零 `.delete`**。
        let parked = planFor { $0.partnerNotAtRest = ["b"] }
        XCTAssertEqual(parked.parkedTombstones, ["b"])
        XCTAssertTrue(parked.steps.isEmpty, "行一个字节不动")

        // (ii) 支：根本没有伙伴行。
        let yielded = planFor { _ in }
        XCTAssertEqual(yielded.yieldedTombstones, ["b"])
        XCTAssertTrue(yielded.steps.isEmpty, "`plan` 对它零 `.delete` step")
        XCTAssertTrue(yielded.parkedTombstones.isEmpty, "让位不是停放")

        // 取值算不出（投影缺席）⇒ **按 (ii) 走**，不停放、不硬删（裁定 3 末段 / C-19）。
        var unresolvable = OwnedItemPlanContext()
        unresolvable.tombstonedIdentities = ["b"]
        unresolvable.pendingLocalEdits = ["b"]
        unresolvable.mergePartners = ["b": "a"]
        let noSource = SyncableOwnedItems.plan(URLRuleKind.self, arrivals: [], parked: [:],
                                               table: table, resolve: resolve,
                                               context: unresolvable)
        XCTAssertEqual(noSource.yieldedTombstones, ["b"], "投影缺席 ⇒ (ii)")
        XCTAssertTrue(noSource.steps.isEmpty)

        // M-24（竞态 4）：败者上**没有**任何本机意图 ⇒ 两个析取项都不成立 ⇒ 照常硬删。
        var settled = OwnedItemPlanContext()
        settled.tombstonedIdentities = ["b"]
        settled.mergePartners = ["b": "a"]
        settled.localProjections["b"] = baselineBytes(xPayload)
        let hardDeleted = SyncableOwnedItems.plan(URLRuleKind.self, arrivals: [], parked: [:],
                                                  table: table, resolve: resolve, context: settled)
        XCTAssertEqual(stepSummary(hardDeleted.steps), ["delete:b"], "不走 `.transfer`")
        XCTAssertTrue(hardDeleted.yieldedTombstones.isEmpty)
    }

    /// (α) 的第二个析取项（取值式 `unpublished`）**单独**成立时同样让位——把它写成
    /// 「只读 `pendingLocalEdit`」的实现在一次由落地合并赢下、还没上账户的本机编辑面前
    /// 毫无防护（CASE M-19 (e)）。
    func testM19e_theUnpublishedDisjunctAloneIsEnoughToYield() throws {
        var table = PhiOwnedItemTable()
        table.cursors["b"] = publishedRuleCursor(urlRulePayload(uuid: "b"), entityId: "srv-b")
        var context = OwnedItemPlanContext()
        context.tombstonedIdentities = ["b"]
        context.unpublished = ["b"]               // `pendingLocalEdit` 是假
        let plan = SyncableOwnedItems.plan(URLRuleKind.self, arrivals: [], parked: [:],
                                           table: table, resolve: resolve, context: context)
        XCTAssertEqual(plan.yieldedTombstones, ["b"])
        XCTAssertTrue(plan.steps.isEmpty)
    }

    // =======================================================================================
    // MARK: - CASE M-22（竞态 2：落点 (β)，模块级）
    // =======================================================================================

    /// (β) 的三结局：W 静止 ⇒ `.transfer`、**X 的软删与 `pendingDelete` 全部留着**；
    /// W 在但不静止 ⇒ 停放**那条入站存活实体**（`parked`，**不是** `parkedTombstones`）；
    /// 两者都不成立 ⇒ 回到 A9 原语义。
    ///
    /// 防的是什么：把 (α) 的 `deletedDate == nil` 或那条析取抄进来 ⇒ 永不让路 ⇒ 终态
    /// Z@S2 + X@S1 两条；按本机那条软删行取值 ⇒ 目标单元不赢 ⇒ Z 停在旧目标。
    func testM22_theThreeOutcomesOfTheA9Branch() throws {
        // X 已发布、游标待删（B 跑过 M2、tombstone 拿了 `.conflict`）；入站是 A 那条 retarget。
        let baseline = urlRulePayload(uuid: "b", targetSpaceUuid: "su-2", contentStamp: 100,
                                      targetStamp: 100)
        var table = PhiOwnedItemTable()
        var cursor = publishedRuleCursor(baseline, entityId: "srv-b")
        cursor.pendingDelete = true
        cursor.deleteDecidedAtMs = 200
        table.cursors["b"] = cursor
        let inbound = urlRulePayload(uuid: "b", targetSpaceUuid: "su-1", contentStamp: 100,
                                     targetStamp: 900)
        let arrival = OwnedItemArrival(entity: inbound, entityId: "srv-b", version: 9)

        func planFor(_ mutate: (inout OwnedItemPlanContext) -> Void) -> OwnedItemPlan {
            var context = OwnedItemPlanContext()
            mutate(&context)
            return SyncableOwnedItems.plan(URLRuleKind.self, arrivals: [arrival], parked: [:],
                                           table: table, resolve: resolve, context: context)
        }

        // W 静止 ⇒ 转移。取值源是**入站实体**，不是本机那条软删行。
        let transferred = planFor { $0.mergePartners = ["b": "a"] }
        XCTAssertEqual(stepSummary(transferred.steps), ["transfer:b->a"],
                       "**不产出 `.delete`**：X 保持软删 + `pendingDelete`")
        XCTAssertTrue(transferred.cancelledDeletes.isEmpty, "不撤销那条本机删除")
        XCTAssertTrue(transferred.parked.isEmpty, "那条入站实体不落地、也不停放")
        if case .transfer(let source, _) = transferred.steps[0].kind {
            XCTAssertEqual(source.targetOwnerUuid, "su-1", "取值源是入站 `merged` 的新目标")
            XCTAssertEqual(source.targetUpdatedDate,
                           Date(timeIntervalSince1970: 0.9), "目标戳照抄入站那一枚")
        } else {
            XCTFail("必须是 `.transfer`")
        }

        // W 在但不静止 ⇒ 停放**那条入站存活实体**：`parked` 有它、`parkedTombstones` **没有**。
        let parked = planFor { $0.partnerNotAtRest = ["b"] }
        XCTAssertTrue(parked.steps.isEmpty)
        XCTAssertNotNil(parked.parked["b"], "游标 `pendingApply` + `pendingOwnerUuid`")
        XCTAssertEqual(parked.parked["b"]?.pendingOwnerUuid, "su-1")
        XCTAssertTrue(parked.parkedTombstones.isEmpty, "**绝不置 `pendingTombstone`**")
        XCTAssertTrue(parked.cancelledDeletes.isEmpty)

        // 两者都不成立 ⇒ A9 原语义（位置比删除决定新、父是活的 ⇒ 取消删除）。
        let a9 = planFor { _ in }
        XCTAssertEqual(a9.cancelledDeletes, ["b"], "A9 的三个合取项逐字不动")
        XCTAssertTrue(a9.steps.contains { $0.identity == "b" })
    }

    // =======================================================================================
    // MARK: - CASE M-34 ①（`.transfer` 夹在 `.update` 与 `.delete` 之间）（R-M3-4a-93）
    // =======================================================================================

    /// 防的是什么：把 `.transfer` 留在**第一相**的那一版。执行序变成 `transfer(X→W)`（跟 W
    /// **落地前**的 `@10` 比，30 赢）→ `.update(W)`（这条 step 在 plan 期就按入站载荷算好了，
    /// 落地时原样写 `true@20`）→ `delete(X)` ⇒ **终态 W = `true@20`，那次 `@30` 的编辑凭空
    /// 消失**，而 X 已经硬删、无处可捞。
    func testM34_theTransferPhaseRunsAfterTheUpdateAndBeforeTheDelete() throws {
        let wBaseline = urlRulePayload(uuid: "a", host: "w.example", ask: false, contentStamp: 10)
        let xProjection = urlRulePayload(uuid: "c", host: "w.example", ask: false, contentStamp: 30)
        var table = PhiOwnedItemTable()
        table.cursors["a"] = publishedRuleCursor(wBaseline, entityId: "srv-a")
        table.cursors["c"] = publishedRuleCursor(xProjection, entityId: "srv-c")

        var context = OwnedItemPlanContext()
        context.tombstonedIdentities = ["c"]
        context.pendingLocalEdits = ["c"]
        context.mergePartners = ["c": "a"]
        context.localProjections["c"] = baselineBytes(xProjection)
        let arrival = OwnedItemArrival(
            entity: urlRulePayload(uuid: "a", host: "w.example", ask: true, contentStamp: 20),
            entityId: "srv-a", version: 9)
        let plan = SyncableOwnedItems.plan(URLRuleKind.self, arrivals: [arrival], parked: [:],
                                           table: table, resolve: resolve, context: context)
        XCTAssertEqual(stepSummary(plan.steps), ["update:a", "transfer:c->a", "delete:c"],
                       "四相：`.update` ⇒ `.transfer` ⇒ `.delete`")

        // 批次那一侧的同一条次序（`URLRuleApplyBatch.init` 的三组）。
        let values = URLRuleLandingValues.fixture(syncId: "a", spaceId: "space-a")
        let batch = URLRuleApplyBatch(unordered: [
            .delete(syncId: "c"),
            .transfer(fromSyncId: "c", toSyncId: "a", source: try projection(xProjection),
                      targetEffectiveStamps: URLRuleEffectiveStamps()),
            .update(values),
        ])
        XCTAssertEqual(opSummary(batch.ops), ["update:a", "transfer:c->a", "delete:c"],
                       "传入次序被相序改写，相内仍然稳定")
    }

    // =======================================================================================
    // MARK: - CASE 8b-3.3（`deferredDeletions` 零记账）
    // =======================================================================================

    /// 防的是什么：把守卫写成「差分照常跑、只在切片里过滤」的实现会在同一步清掉
    /// `pendingApply` 并重写 `deleteDecidedAtMs`，于是**下一轮**守卫的第二个合取项恒假、
    /// A9 那条「入站位置比删除决定更新」的比较基准也被一路往后推。
    func test8b33_aDeferredDeletionWritesNothingAtAllIntoTheCursorTable() throws {
        var table = PhiOwnedItemTable()
        var deferred = pendingDeleteCursor(decidedAtMs: 700, entityId: "srv-b", version: 3,
                                           reconciled: baselineBytes(urlRulePayload(uuid: "b")))
        deferred.server = deferred.reconciled
        deferred.ownerUuid = "su-1"
        deferred.pendingApply = baselineBytes(urlRulePayload(uuid: "b", targetSpaceUuid: "su-2"))
        deferred.pendingOwnerUuid = "su-2"
        table.cursors["b"] = deferred
        // 对照：同样「本机没有活行」的另一条身份，**不在**守卫里 ⇒ 照常发 tombstone。
        table.cursors["z"] = ownedCursor(reconciled: baselineBytes(urlRulePayload(uuid: "z")),
                                         server: baselineBytes(urlRulePayload(uuid: "z")),
                                         entityId: "srv-z", version: 4, ownerUuid: "su-1")

        let result = SyncableOwnedItems.tombstones(URLRuleKind.self, locals: [], table: table,
                                                   resolve: resolve, scope: nil, nowMs: 900,
                                                   deferredDeletions: ["b"])
        XCTAssertEqual(result.identities, ["z"], "守卫里的身份不进 `identities`")
        XCTAssertNil(result.cursorUpdates["b"], "**零 `cursorUpdates`**")
        XCTAssertEqual(result.deferred, ["b"], "原样回传")
        XCTAssertNotNil(result.cursorUpdates["z"], "同一趟别的身份照常记账")
        // 引擎那一侧的第三个合取项：一条**上一轮就已经** `pendingDelete == true` 的身份本轮
        // 不产出 cursorUpdate，仍会按既有 filter 进候选——所以那个减法必须读 `deferred`。
        XCTAssertTrue(table.cursors["b"]?.pendingDelete == true
                        && table.cursors["b"]?.deletedAtMs == nil,
                      "既有 filter 的两个合取项对它成立")
    }

    // =======================================================================================
    // MARK: - CASE M-23 对照二 / M-26（`partnerNotAtRest` 的三步查找次序与两个集合的分工）
    // =======================================================================================

    /// 三步查找次序（RR10-7）：① 指针 ⇒ 静止的那一条；② 指针取不到**或指到的行不静止**
    /// ⇒ 退到兜底支；③ 都拿不出 ⇒ 按「有没有伙伴行」分流。
    ///
    /// 防的是什么：只按指针一条路查、指针不静止就停放的实现（M-23 对照二）；把「伙伴不静止」
    /// 与「根本没有伙伴」混成一件事的实现（RR10-3）。
    func testM23b_thePartnerLookupFallsBackWhenThePointerIsNotAtRest() throws {
        var table = PhiOwnedItemTable()
        // X：待重判的那一条，指针指向一条**永远不会静止**的锚点（目标 hidden ⇒ 失去签名）。
        let baseline = urlRulePayload(uuid: "x")
        table.cursors["x"] = publishedRuleCursor(baseline, entityId: "srv-x")
        table.cursors["anchor"] = publishedRuleCursor(urlRulePayload(uuid: "anchor"),
                                                      entityId: "srv-anchor")
        table.cursors["settled"] = publishedRuleCursor(urlRulePayload(uuid: "settled"),
                                                       entityId: "srv-settled")
        let rows = [
            PhiLocalURLRule.fixture(id: "i-x", syncId: "x", pendingLocalEdit: true,
                                    mergePartnerSyncId: "anchor"),
            // 锚点：活行，但目标是一条 agent Space ⇒ 没有签名 ⇒ 静止第 8 项永假。
            PhiLocalURLRule.fixture(id: "i-anchor", syncId: "anchor", spaceId: "agent-space",
                                    sortOrder: 1),
            PhiLocalURLRule.fixture(id: "i-settled", syncId: "settled", sortOrder: 2),
        ]
        let access = FakeURLRuleAccess(rows: rows)
        let partners = access.mergePartners(table: table, resolve: resolve, tombstonesThisPage: [])
        XCTAssertEqual(partners["x"], "settled", "退到兜底支、拿那条**静止**活行")
        XCTAssertFalse(access.partnerNotAtRest(table: table, rows: rows, resolve: resolve,
                                               tombstonesThisPage: []).contains("x"),
                       "拿得出 W ⇒ 这一条不停放")
    }

    /// M-26 的第 10 项：同一页里 W 自己的 tombstone 也到了 ⇒ W 在这一页**不静止** ⇒ X 进
    /// `partnerNotAtRest`（停放），而不是 (ii)。W 的行消失之后才轮到 (ii)。
    func testM26_aPartnerDyingOnThisPageParksInsteadOfYielding() throws {
        var table = PhiOwnedItemTable()
        table.cursors["a"] = publishedRuleCursor(urlRulePayload(uuid: "a"), entityId: "srv-a")
        table.cursors["b"] = publishedRuleCursor(urlRulePayload(uuid: "b"), entityId: "srv-b")
        let rows = [
            PhiLocalURLRule.fixture(id: "i-a", syncId: "a"),
            PhiLocalURLRule.fixture(id: "i-b", syncId: "b", sortOrder: 1, pendingLocalEdit: true,
                                    mergePartnerSyncId: "a"),
        ]
        let access = FakeURLRuleAccess(rows: rows)
        let settled = access.mergePartners(table: table, resolve: resolve, tombstonesThisPage: [])
        XCTAssertEqual(settled["b"], "a", "没有本页 tombstone 时 W 静止")
        XCTAssertTrue(access.mergePartners(table: table, resolve: resolve,
                                           tombstonesThisPage: ["a", "b"]).isEmpty,
                      "第 10 项让 W 在这一页不静止")
        XCTAssertTrue(access.partnerNotAtRest(table: table, rows: rows, resolve: resolve,
                                              tombstonesThisPage: ["a", "b"]).contains("b"),
                      "W 在但不静止 ⇒ 停放，**不是** (ii)")

        // W 的行已经没了 ⇒ 既没有静止的 W、也**没有伙伴行** ⇒ 两个集合都不收它 ⇒ (ii)。
        let orphan = FakeURLRuleAccess(rows: [rows[1]])
        XCTAssertTrue(orphan.mergePartners(table: table, resolve: resolve,
                                           tombstonesThisPage: []).isEmpty)
        XCTAssertTrue(orphan.partnerNotAtRest(table: table, rows: [rows[1]], resolve: resolve,
                                              tombstonesThisPage: []).isEmpty,
                      "悬空指针不算「有伙伴行」——算了就是无界停放")
    }

    /// (β) 的定义域**含软删行**（RR8-1）：照抄 (α) 的 `deletedDate == nil` 会让这两张表对
    /// (β) 恒空 ⇒ 守卫形同虚设、正在重判的那一行被硬删。
    func testM22_theGuardDomainIncludesSoftDeletedRows() throws {
        var table = PhiOwnedItemTable()
        table.cursors["a"] = publishedRuleCursor(urlRulePayload(uuid: "a"), entityId: "srv-a")
        var pending = publishedRuleCursor(urlRulePayload(uuid: "b"), entityId: "srv-b")
        pending.pendingDelete = true
        table.cursors["b"] = pending
        // W 不静止（游标带停放载荷）；X 是**软删**态、指针指向 W。
        table.cursors["a"]?.pendingApply = baselineBytes(urlRulePayload(uuid: "a"))
        let rows = [
            PhiLocalURLRule.fixture(id: "i-a", syncId: "a"),
            PhiLocalURLRule.fixture(id: "i-b", syncId: "b", sortOrder: 1,
                                    deletedDate: Date(timeIntervalSince1970: 5),
                                    mergePartnerSyncId: "a"),
        ]
        let access = FakeURLRuleAccess(rows: rows)
        XCTAssertEqual(access.partnerNotAtRest(table: table, rows: rows, resolve: resolve,
                                               tombstonesThisPage: []),
                       ["b"], "软删的 X 照样进守卫")
        XCTAssertTrue(access.partnerNotAtRest(table: table,
                                              rows: rows.filter { $0.deletedDate == nil },
                                              resolve: resolve, tombstonesThisPage: []).isEmpty,
                      "`rows` 取 `allURLRules()` 的实现必须判红")
    }

    // =======================================================================================
    // MARK: - CASE 8b-3.5 / 8b-3.6 / M-34 (b)(c)（转移的每单元 LWW，值级）
    // =======================================================================================

    /// 裁定 9 的四条，一条用例四段。
    ///
    /// 防的是什么：无条件置位会给 W 留一个永不清掉的标志（8b-3.5）；**按字段**转移会把 X 的
    /// `ask` 连同 X 的组戳打到 W 上（8b-3.6）；**只读 W 行戳**的那一版在 M-34 (c) 上把账户上
    /// 更新的那份取值覆写掉。
    func test8b35_theTransferWritesOnlyTheUnitsItWins() throws {
        let target = PhiLocalURLRule.fixture(id: "i-w", syncId: "a", host: "w.example",
                                             contentUpdatedDate: stampDate(100),
                                             targetUpdatedDate: stampDate(100))

        // 8b-3.5：两个单元都输 ⇒ 零写、不置位、不计 `transferred`。
        let stale = try projection(urlRulePayload(uuid: "b", targetSpaceUuid: "su-2",
                                                  host: "x.example", contentStamp: 10,
                                                  targetStamp: 10))
        let lost = URLRuleKind.transferDecision(target: target, source: stale,
                                                targetEffectiveStamps: URLRuleEffectiveStamps())
        XCTAssertEqual(lost.written, 0)
        XCTAssertTrue(lost.contentSuperseded)

        // 8b-3.6：目标戳更新、内容组戳更旧 ⇒ **只写目标整组**，内容组三个字段一个都不打过去。
        let split = try projection(urlRulePayload(uuid: "b", targetSpaceUuid: "su-2",
                                                  host: "x.example", contentStamp: 10,
                                                  targetStamp: 900))
        let partial = URLRuleKind.transferDecision(target: target, source: split,
                                                   targetEffectiveStamps: URLRuleEffectiveStamps())
        XCTAssertFalse(partial.writesContent, "内容组整组不转移")
        XCTAssertTrue(partial.writesTarget)
        XCTAssertEqual(partial.written, 1)
        XCTAssertTrue(partial.contentSuperseded, "计一次 `superseded_by_delete`")

        // M-34 (c)：W 的**账户**戳是 40、**行**上那一列还停在 10 ⇒ `max` 取 40 ⇒ 30 不赢。
        let laggingRow = PhiLocalURLRule.fixture(id: "i-w", syncId: "a", host: "w.example",
                                                 contentUpdatedDate: stampDate(10))
        let edit = try projection(urlRulePayload(uuid: "c", host: "w.example", ask: true,
                                                 contentStamp: 30, targetStamp: 30))
        let againstAccount = URLRuleKind.transferDecision(
            target: laggingRow, source: edit,
            targetEffectiveStamps: URLRuleEffectiveStamps(content: stampDate(40), target: nil))
        XCTAssertFalse(againstAccount.writesContent,
                       "`max(行戳 10, 账户戳 40)` ⇒ 30 输；只读行戳的实现必须红")
        // 同族：行戳是 `nil`（Task 5 裁定 5 的新行形态），账户戳仍是 40 ⇒ 期望逐字相同。
        let freshRow = PhiLocalURLRule.fixture(id: "i-w", syncId: "a", host: "w.example")
        XCTAssertFalse(URLRuleKind.transferDecision(
            target: freshRow, source: edit,
            targetEffectiveStamps: URLRuleEffectiveStamps(content: stampDate(40),
                                                          target: nil)).writesContent)
        // 反过来：账户戳缺席 ⇒ `max` 退化成行戳（fail-open 到旧口径），30 > 10 ⇒ 赢。
        XCTAssertTrue(URLRuleKind.transferDecision(
            target: laggingRow, source: edit,
            targetEffectiveStamps: URLRuleEffectiveStamps()).writesContent)

        // `targetSpaceId == nil` ⇒ 目标这一组不转移（零写，fail-closed）。
        var unmapped = try projection(urlRulePayload(uuid: "b", contentStamp: 10,
                                                     targetStamp: 900))
        unmapped.targetSpaceId = nil
        XCTAssertFalse(URLRuleKind.transferDecision(
            target: target, source: unmapped,
            targetEffectiveStamps: URLRuleEffectiveStamps()).writesTarget)
    }

    // =======================================================================================
    // MARK: - CASE M-37（pre-pass 之后编辑来源行：事务内的「来源行未变」复查）（R-M3-4a-102）
    // =======================================================================================

    /// 复查的判定半边，值级。
    ///
    /// 防的是什么：不做复查的那一版转移的是 **E1**、随后硬删那条装着 E2 的行 ⇒ E2 在本机与
    /// 账户上都不存在；把它写成「一律停放一轮」的实现让 (i) 支永远走不完。
    func testM37_theInTransactionSourceRecheck() throws {
        let row = PhiLocalURLRule.fixture(id: "i-x", syncId: "b", host: "e1.example",
                                          contentUpdatedDate: stampDate(30),
                                          pendingLocalEdit: true, mergePartnerSyncId: "a")
        let source = try projection(urlRulePayload(uuid: "b", host: "e1.example",
                                                   contentStamp: 30, targetStamp: 30))
        XCTAssertTrue(URLRuleKind.transferSourceUnchanged(row: row, source: source),
                      "来源行没变 ⇒ 逐字回到今天")

        var saved = row
        saved.host = "e2.example"
        saved.contentUpdatedDate = stampDate(40)
        XCTAssertFalse(URLRuleKind.transferSourceUnchanged(row: saved, source: source),
                       "用户在 pre-pass 与事务之间按了一次 Save")

        var retargeted = row
        retargeted.spaceId = "space-c"
        retargeted.targetUpdatedDate = stampDate(40)
        XCTAssertFalse(URLRuleKind.transferSourceUnchanged(row: retargeted, source: source),
                       "只改目标的那次 Save 同样挡住")

        var softDeleted = row
        softDeleted.deletedDate = Date(timeIntervalSince1970: 9)
        XCTAssertFalse(URLRuleKind.transferSourceUnchanged(row: softDeleted, source: source),
                       "`deletedDate != nil` 也算「变了」——软删之后那条 tombstone 该走 (β)")
        XCTAssertFalse(URLRuleKind.transferSourceUnchanged(row: nil, source: source),
                       "行已不在")

        // 亚毫秒抖动**不算**变了：两侧都先过毫秒换算再比（裁定 11）。
        var jittered = row
        jittered.contentUpdatedDate = Date(timeIntervalSince1970: 0.0300001)
        XCTAssertTrue(URLRuleKind.transferSourceUnchanged(row: jittered, source: source),
                      "白停放一轮的实现必须红")
    }

    // =======================================================================================
    // MARK: - `transferTargets` 与 `landedIdentities` 的分工（R-M3-4a-90 / RR12-6）
    // =======================================================================================

    /// 转移目标要退出本页 M2 的候选集；`.transfer` 的身份**不进** `landedIdentities`
    /// （`outcome.landed` 是它的超集，两者不可互换）。
    func testM33_transferTargetsLeaveThisPagesMergeCandidateSet() throws {
        let steps = [
            OwnedItemApplyStep(identity: "c", kind: .transfer(source: try projection(
                urlRulePayload(uuid: "c")), to: "a"), newParentUuid: nil, newRank: nil,
                               payload: nil),
            OwnedItemApplyStep(identity: "y", kind: .update, newParentUuid: nil, newRank: nil,
                               payload: nil),
            OwnedItemApplyStep(identity: "c", kind: .delete, newParentUuid: nil, newRank: nil,
                               payload: nil),
        ]
        XCTAssertEqual(URLRuleKind.transferTargets(in: steps), ["a"])
        XCTAssertEqual(URLRuleKind.landedIdentities(in: steps), ["y"],
                       "`.transfer` 与 `.delete` 都不在里面")
    }

    // =======================================================================================
    // MARK: - CASE M-12 / M-21（引擎级：(α) 的 (i) 支走完整一轮）
    // =======================================================================================

    /// 一页只带 X 的 tombstone；X 手上有一次未发布编辑、指针指向静止的 W。
    ///
    /// 防的是什么：**终态不得是两条规则**。(α) 之后走软删而不是硬删的实现会在下一轮多发一条
    /// 无谓的 tombstone，行还要在盘上躺 30 天（RR8-5）。
    func testM21_anInboundTombstoneTransfersTheEditAndHardDeletesTheLoser() async throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        seedSettled("a", id: "i-a", ask: false, accountStamp: 10, rows: &rows, table: &table)
        seedSettled("b", id: "i-b", ask: true, sortOrder: 1, accountStamp: 30,
                    rowContentUpdatedDate: stampDate(30), pendingLocalEdit: true,
                    mergePartnerSyncId: "a", rows: &rows, table: &table)

        let access = FakeURLRuleAccess(rows: rows)
        let store = MemoryOwnedItemStore()
        store.table = table
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([remoteTombstone(tag: ruleTag("b"), version: 40,
                                                      entityId: "srv-b")], marker: "7")]
        let engine = try makeRuleEngine(access, store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        // ① 执行序：这一页没有到 W 的 `.update`，所以只有转移与硬删两条。
        XCTAssertEqual(opSummary(access.lastAppliedOps), ["transfer:b->a", "delete:b"])
        // ② W 收下了那次编辑；X 在 `allURLRulesIncludingDeleted()` 里也找不到。
        let w = try XCTUnwrap(row(access, "a"))
        XCTAssertEqual(w.askBeforeRouting, true, "内容组整组转移过来")
        XCTAssertEqual(w.contentUpdatedDate, stampDate(30), "戳照抄来源，绝不铸 `now`")
        XCTAssertTrue(w.pendingLocalEdit, "写了单元 ⇒ 置位")
        XCTAssertNil(row(access, "b"), "X 被**硬删**，不是软删")
        let counters = await counters(engine)
        XCTAssertEqual(counters?.transferred, 1)
        XCTAssertEqual(counters?.resurrected, 0)
        XCTAssertEqual(counters?.yieldNoPartner, 0)
        // ③ X 的游标按普通 tombstone 记账。
        let cursor = await engine.ownedTableForTesting("urlrules").cursors["b"]
        XCTAssertNil(cursor?.reconciled)
        XCTAssertNil(cursor?.server)
        XCTAssertNotNil(cursor?.deletedAtMs)
        XCTAssertEqual(cursor?.pendingDelete, false)
        XCTAssertEqual(cursor?.pendingTombstone, false)
    }

    /// 落地抛错 ⇒ **整批回滚**：`.transfer` 与 `.delete` 在同一个事务里，W 的行与 X 的行
    /// 一个字节都不动。
    func testM21_aFailedLandingRollsBackBothTheTransferAndTheDelete() async throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        seedSettled("a", id: "i-a", ask: false, accountStamp: 10, rows: &rows, table: &table)
        seedSettled("b", id: "i-b", ask: true, sortOrder: 1, accountStamp: 30,
                    rowContentUpdatedDate: stampDate(30), pendingLocalEdit: true,
                    mergePartnerSyncId: "a", rows: &rows, table: &table)

        let access = FakeURLRuleAccess(rows: rows)
        access.failApplyOnce = true
        let store = MemoryOwnedItemStore()
        store.table = table
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([remoteTombstone(tag: ruleTag("b"), version: 40,
                                                      entityId: "srv-b")], marker: "7")]
        let engine = try makeRuleEngine(access, store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertEqual(row(access, "a")?.askBeforeRouting, false, "W 的行没被动过")
        XCTAssertFalse(try XCTUnwrap(row(access, "a")).pendingLocalEdit)
        XCTAssertNotNil(row(access, "b"), "X 的行还在")
        let counters = await counters(engine)
        XCTAssertEqual(counters?.transferred, 0)
        let cursor = await engine.ownedTableForTesting("urlrules").cursors["b"]
        XCTAssertEqual(cursor?.pendingTombstone, true, "整批停放，下一轮重判")
        XCTAssertNotNil(cursor?.reconciled, "基线一个字节没写")
    }

    // =======================================================================================
    // MARK: - CASE 8b-3.5（引擎级：零写转移不置位、不计 `transferred`，X 照常硬删）
    // =======================================================================================

    /// 防的是什么：无条件置位会给 W 留一个永不清掉的标志：它从此**永久**退出静止（M2 不再
    /// 收敛它）、并对**每一次**远端删除让位。
    func test8b35_aZeroUnitTransferStillHardDeletesTheLoser() async throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        // W 的两枚账户戳都比 X 新 ⇒ 两个单元都输。
        seedSettled("a", id: "i-a", ask: false, accountStamp: 900, rows: &rows, table: &table)
        seedSettled("b", id: "i-b", ask: true, sortOrder: 1, accountStamp: 30,
                    rowContentUpdatedDate: stampDate(30), pendingLocalEdit: true,
                    mergePartnerSyncId: "a", rows: &rows, table: &table)

        let access = FakeURLRuleAccess(rows: rows)
        let store = MemoryOwnedItemStore()
        store.table = table
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([remoteTombstone(tag: ruleTag("b"), version: 40,
                                                      entityId: "srv-b")], marker: "7")]
        let engine = try makeRuleEngine(access, store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let w = try XCTUnwrap(row(access, "a"))
        XCTAssertEqual(w.askBeforeRouting, false, "W 的行一个字节没变")
        XCTAssertNil(w.contentUpdatedDate)
        XCTAssertFalse(w.pendingLocalEdit, "零写 ⇒ **不置位**")
        XCTAssertNil(row(access, "b"), "那条 `.delete` 不受零写影响")
        let counters = await counters(engine)
        XCTAssertEqual(counters?.transferred, 0)
        XCTAssertEqual(counters?.supersededByDelete, 1, "内容组输掉 ⇒ 计一次（§13.3）")
    }

    // =======================================================================================
    // MARK: - CASE M-37（引擎级：pre-pass 之后的那一次真实用户 Save）（R-M3-4a-102）
    // =======================================================================================

    /// 防的是什么：pre-pass（主 actor）与落地事务（写队列）之间那一次**真实可达**的用户 Save。
    /// 不做复查的那一版转移的是 **E1**、`.delete(X)` 照常硬删那条装着 E2 的行 ⇒ **E2 在本机与
    /// 账户上都不存在**，没有任何日志说它发生过。
    func testM37_anEditToTheSourceRowBetweenThePrePassAndTheTransactionDefersBothOps() async throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        seedSettled("a", id: "i-a", ask: false, accountStamp: 10, rows: &rows, table: &table)
        seedSettled("b", id: "i-b", ask: true, sortOrder: 1, accountStamp: 30,
                    rowContentUpdatedDate: stampDate(30), pendingLocalEdit: true,
                    mergePartnerSyncId: "a", rows: &rows, table: &table)

        let access = FakeURLRuleAccess(rows: rows)
        let store = MemoryOwnedItemStore()
        store.table = table
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([remoteTombstone(tag: ruleTag("b"), version: 40,
                                                      entityId: "srv-b")], marker: "7")]
        // 注入点：**落地事务之前**那一刻，pre-pass 已经冻下 E1。真实用户写（编辑器语义）。
        access.beforeLandingTransaction = { [weak access] in
            access?.applyEditorSave(syncId: "b", host: "e2.example",
                                    at: Date(timeIntervalSince1970: 0.040))
        }
        let engine = try makeRuleEngine(access, store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        // W 的行一个字节没变、X 的行还在，而且**就是 E2**。
        let w = try XCTUnwrap(row(access, "a"))
        XCTAssertEqual(w.askBeforeRouting, false)
        XCTAssertNil(w.contentUpdatedDate)
        XCTAssertFalse(w.pendingLocalEdit)
        let x = try XCTUnwrap(row(access, "b"))
        XCTAssertEqual(x.host, "e2.example")
        XCTAssertEqual(x.contentUpdatedDate, Date(timeIntervalSince1970: 0.040))
        XCTAssertTrue(x.pendingLocalEdit)
        let counters = await counters(engine)
        XCTAssertEqual(counters?.transferred, 0)
        XCTAssertEqual(counters?.resurrected, 0)
        // 游标：`pendingTombstone` 置上、三元组已收割、两份基线与 `deletedAtMs` 一个字节不动。
        let cursor = await engine.ownedTableForTesting("urlrules").cursors["b"]
        XCTAssertEqual(cursor?.pendingTombstone, true)
        XCTAssertEqual(cursor?.version, 40, "三元组照常收割")
        XCTAssertNotNil(cursor?.reconciled)
        XCTAssertNotNil(cursor?.server)
        XCTAssertNil(cursor?.deletedAtMs, "**绝不**进 `deleted`")

        // 下一轮：那条停放的 tombstone 被重新投递，pre-pass 这一次捕获的是 **E2**。
        access.beforeLandingTransaction = nil
        client.pagesByMarker = [page([], marker: "8")]
        await engine.pullOnce()

        let movedOn = try XCTUnwrap(row(access, "a"))
        XCTAssertEqual(movedOn.host, "e2.example", "转移的是 E2")
        XCTAssertEqual(movedOn.contentUpdatedDate, Date(timeIntervalSince1970: 0.040))
        XCTAssertTrue(movedOn.pendingLocalEdit)
        XCTAssertNil(row(access, "b"), "X 随后才被硬删")
        let second = await counters(engine)
        XCTAssertEqual(second?.transferred, 1)
    }

    /// 对照：钩子**什么都不做** ⇒ 事务内比较逐格相等 ⇒ `.transfer` + `.delete(X)` 照常执行。
    /// 钉住「复查只在真的变了时挡」，别把它写成「一律停放一轮」。
    func testM37_anUnchangedSourceRowExecutesBothOpsExactlyAsBefore() async throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        seedSettled("a", id: "i-a", ask: false, accountStamp: 10, rows: &rows, table: &table)
        seedSettled("b", id: "i-b", ask: true, sortOrder: 1, accountStamp: 30,
                    rowContentUpdatedDate: stampDate(30), pendingLocalEdit: true,
                    mergePartnerSyncId: "a", rows: &rows, table: &table)

        let access = FakeURLRuleAccess(rows: rows)
        let store = MemoryOwnedItemStore()
        store.table = table
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([remoteTombstone(tag: ruleTag("b"), version: 40,
                                                      entityId: "srv-b")], marker: "7")]
        access.beforeLandingTransaction = { }
        let engine = try makeRuleEngine(access, store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertEqual(row(access, "a")?.askBeforeRouting, true)
        XCTAssertNil(row(access, "b"))
        let counters = await counters(engine)
        XCTAssertEqual(counters?.transferred, 1)
        let cursor = await engine.ownedTableForTesting("urlrules").cursors["b"]
        XCTAssertEqual(cursor?.pendingTombstone, false)
        XCTAssertNotNil(cursor?.deletedAtMs)
    }

    // =======================================================================================
    // MARK: - CASE M-12 (ii)（引擎级：让位 ⇒ 轮末 3b 重发布）
    // =======================================================================================

    /// 根本没有伙伴行 ⇒ (ii)：行留着、两份基线清 nil、`deletedAtMs` 写下**并保留**，轮末那次
    /// 3b 以那条 tombstone 的版本当 `base_version` 把这条规则重新发回账户。
    ///
    /// 防的是什么：提前清 `deletedAtMs` 的让 3b 永远发不出；kind 自己软删、不产出 `.delete`
    /// step 的实现会多发一条无谓的 tombstone。
    func testM12_theYieldBranchRepublishesTheRuleAtTheEndOfTheRound() async throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        seedSettled("b", id: "i-b", ask: true, accountStamp: 30,
                    rowContentUpdatedDate: stampDate(30), pendingLocalEdit: true,
                    rows: &rows, table: &table)

        let access = FakeURLRuleAccess(rows: rows)
        let store = MemoryOwnedItemStore()
        store.table = table
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([remoteTombstone(tag: ruleTag("b"), version: 40,
                                                      entityId: "srv-b")], marker: "7")]
        // 账户上那一行真的还在（tombstone 那一版），于是轮末那次 3b 走 update 支并被接受。
        client.seed(tagHash: ruleHash("b"), ciphertext: Data(), version: 40, entityId: "srv-b",
                    deleted: true)
        let engine = try makeRuleEngine(access, store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        // 行还在、`syncId` 没变、`deletedDate == nil`；`plan` 对它零 `.delete` step。
        let x = try XCTUnwrap(row(access, "b"))
        XCTAssertNil(x.deletedDate)
        XCTAssertEqual(x.askBeforeRouting, true, "那次未发布编辑原样留着")
        XCTAssertTrue(access.lastAppliedOps.isEmpty, "零落地 op")
        XCTAssertTrue(access.hardDeleteCalls.isEmpty)
        // 轮末 3b：`base_version` 取那条 tombstone 的版本。
        let commits = ruleCommits(client)
        XCTAssertEqual(commits.count, 1, "3b 重发布，一条")
        XCTAssertEqual(commits.first?.baseVersion, 40)
        XCTAssertEqual(commits.first?.deleted, false)
        let counters = await counters(engine)
        XCTAssertEqual(counters?.yieldNoPartner, 1, "成因：指针空 ∧ 兜底未命中")
        XCTAssertEqual(counters?.transferred, 0)
        XCTAssertEqual(counters?.tombstones, 1, "到达的那一条，不是本机发出去的")
        // `.applied` 之后：§4.2 规则 3b 的复活——`deletedAtMs` 被清、两份基线写回。
        XCTAssertEqual(counters?.resurrected, 1)
        let cursor = await engine.ownedTableForTesting("urlrules").cursors["b"]
        XCTAssertNil(cursor?.deletedAtMs, "**只有** `.applied` 才清它（RR5-3）")
        XCTAssertNotNil(cursor?.reconciled)
        XCTAssertEqual(cursor?.reconciled, cursor?.server, "R-exec-7：两份基线都写")
        XCTAssertEqual(cursor?.pendingDelete, false)
        XCTAssertEqual(cursor?.pendingTombstone, false)
        // `pendingLocalEdit` 的清位是 8b-4 的清位 (b)，本任务不碰它。
        XCTAssertTrue(try XCTUnwrap(row(access, "b")).pendingLocalEdit)
    }


    // =======================================================================================
    // MARK: - 8b-3 fix round 1：守卫的引擎接线与 3b 复查的两条「不过」支
    // =======================================================================================

    /// 本轮真的发出去的**规则 tombstone** commit。守卫写歪的唯一可观测后果就是这里多一条。
    private func ruleTombstoneCommits(_ client: FakePhiSyncClient) -> [FakePhiSyncClient.CommitCall] {
        ruleCommits(client).filter(\.deleted)
    }

    /// 一台只跑规则的引擎，但 Space 侧的假件与 store 由用例自己给（3b 复查的成因二要改
    /// Space 游标，成因三要改 `currentSpaces()`，两者 `makeRuleEngine` 都够不到）。
    private func makeYieldEngine(_ access: FakeURLRuleAccess, _ store: MemoryOwnedItemStore,
                                 client: FakePhiSyncClient,
                                 spaceAccess: FakePhiSpaceAccess,
                                 spaceStore: MemorySpaceStore) -> PhiSyncEngine {
        PhiSyncEngine(domainKeys: StubDomainKeys(key: key), client: client,
                      defaults: defaults, deviceKeyId: "devA", settings: [],
                      spaceAccess: spaceAccess, spaceStore: spaceStore,
                      markerStore: markerStore(marker: "0"),
                      ownedKinds: [.urlRules(access: access, store: store)],
                      now: { Self.now })
    }

    /// 一条**走过 (ii)** 的游标：两份基线 nil、`deletedAtMs` 写下**并保留**、三个待办位清掉
    /// （= `applyOwnedKind` 让位记账那一段写下的形状）。3b 复查的定义域就是它。
    private func yieldedCursor(entityId: String = "srv-b", version: Int64 = 40,
                               owner: String = "su-1") -> PhiOwnedItemCursor {
        var cursor = PhiOwnedItemCursor()
        cursor.entityId = entityId
        cursor.version = version
        cursor.reconciled = nil
        cursor.server = nil
        cursor.ownerUuid = owner
        cursor.deletedAtMs = Self.now - 1_000
        return cursor
    }

    /// 一条 (β) 停放态：X 软删 + 指针指向 W、游标待删；W 活着但**不静止**（行上带一次未发布
    /// 编辑）。两条行的取值与各自的基线逐字相同，所以「这一轮零 commit」的断言只说守卫这一件事。
    private func seedBetaPark(rows: inout [PhiLocalURLRule], table: inout PhiOwnedItemTable,
                              decidedAtMs: Int64 = 700) {
        seedSettled("a", id: "i-a", accountStamp: 100, pendingLocalEdit: true,
                    rows: &rows, table: &table)
        let payload = urlRulePayload(uuid: "b", host: "github.com", rank: "W", contentStamp: 100,
                                     targetStamp: 100, rankStamp: 100)
        var cursor = publishedRuleCursor(payload, entityId: "srv-b", version: 1)
        cursor.pendingDelete = true
        cursor.deleteDecidedAtMs = decidedAtMs
        table.cursors["b"] = cursor
        rows.append(.fixture(id: "i-b", syncId: "b", spaceId: "space-a", host: "github.com",
                             sortOrder: 1, deletedDate: Date(timeIntervalSince1970: 5),
                             mergePartnerSyncId: "a"))
    }

    // =======================================================================================
    // MARK: - CASE M-22 引擎级 / CASE 8b-3.3 整轮版（R-M3-4a-84 的守卫接线）
    // =======================================================================================

    /// **这一支必须经完整发布段**（R-M3-4a-84）：`pullOnce()` 跑完 `plan` → `land` → 差分 →
    /// 切片 → 组批。守卫这一次由**引擎**算（`tombstones` 闭包里的
    /// `partnerNotAtRest ∩ pendingApply != nil`），不是用例手喂的集合。
    ///
    /// 防的是什么（spec 点名的那条失败链）：守卫恒空 ⇒ 差分在**同一步**清掉 `pendingApply`
    /// 并把 X 排进 `deleteCandidates` ⇒ 那条 tombstone 必然 `.applied` ⇒ **正在重判的那一行被
    /// 硬删** ⇒ 下一轮差分为它重发一条 `.create` ⇒ 终态两条规则。
    func testM22_theEngineComputedGuardSuppressesTheTombstoneThroughAFullRound() async throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        seedBetaPark(rows: &rows, table: &table)

        let access = FakeURLRuleAccess(rows: rows)
        let store = MemoryOwnedItemStore()
        store.table = table
        let client = FakePhiSyncClient()
        // B 的 tombstone 拿了 `.conflict` ⇒ 这一页带回 X 的**存活**实体。
        client.pagesByMarker = [page([ruleEntity(remote(uuid: "b", rank: "W"), version: 40)],
                                     marker: "7")]
        let engine = try makeRuleEngine(access, store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        // ① (β) 的停放真的发生了：那条实体没落地，游标带上载荷与归属。
        let cursor = await engine.ownedTableForTesting("urlrules").cursors["b"]
        XCTAssertNotNil(cursor?.pendingApply, "入站实体停放下来（**不是**被差分清掉）")
        XCTAssertEqual(cursor?.pendingOwnerUuid, "su-1")
        XCTAssertEqual(cursor?.pendingTombstone, false, "那是 (α) 的位")
        // ② 守卫：差分对它**零记账**，四个字段与轮首逐字相同（CASE 8b-3.3 的整轮版）。
        XCTAssertEqual(cursor?.pendingDelete, true)
        XCTAssertEqual(cursor?.deleteDecidedAtMs, 700, "比较基准没有被一路往后推")
        XCTAssertEqual(cursor?.reconciled, table.cursors["b"]?.reconciled, "基线一个字节没写")
        // ③ `client.commit` 里没有 X 的 tombstone。
        XCTAssertTrue(ruleTombstoneCommits(client).isEmpty, "守卫恒空的实现在这里红")
        let counters = await counters(engine)
        XCTAssertEqual(counters?.tombstones, 0)
        // ④ X 的行一个字节没动。
        let x = try XCTUnwrap(row(access, "b"))
        XCTAssertEqual(x.deletedDate, Date(timeIntervalSince1970: 5), "仍是软删态")
        XCTAssertEqual(x.mergePartnerSyncId, "a")
        XCTAssertEqual(x.spaceId, "space-a")
        XCTAssertTrue(access.hardDeleteCalls.isEmpty)
    }

    /// **对照二（owner 形状停放不进守卫）**：X 的停放是「归属还没映射」那一种
    /// （`pendingOwnerUuid` 指一个未映射 Space，身份**不在** `partnerNotAtRest` 里），而用户
    /// 本机删除还在 ⇒ **那一轮照常发 tombstone**。
    ///
    /// 防的是什么：把守卫写成 `pendingApply == nil` 一条的实现会把 §5.5 第 4 步的 owner 形状
    /// 停放一并圈进来，一条正当的用户删除被**无界**地挡住。
    func testM22_anOwnerShapedParkIsNotCoveredByTheGuard() async throws {
        let payload = urlRulePayload(uuid: "b", host: "github.com", contentStamp: 100)
        var table = PhiOwnedItemTable()
        var cursor = publishedRuleCursor(payload, entityId: "srv-b", version: 1)
        cursor.pendingDelete = true
        cursor.deleteDecidedAtMs = 700
        // owner 形状停放：等的是一个**未映射**的 Space，与伙伴静不静止无关。
        cursor.pendingApply = baselineBytes(urlRulePayload(uuid: "b", targetSpaceUuid: "su-9"))
        cursor.pendingOwnerUuid = "su-9"
        table.cursors["b"] = cursor
        // 组里没有第二条行 ⇒ `partnerNotAtRest` 对它恒空。
        let rows: [PhiLocalURLRule] = [
            .fixture(id: "i-b", syncId: "b", spaceId: "space-a", host: "github.com",
                     deletedDate: Date(timeIntervalSince1970: 5)),
        ]
        let access = FakeURLRuleAccess(rows: rows)
        XCTAssertTrue(access.partnerNotAtRest(table: table, rows: rows, resolve: resolve,
                                              tombstonesThisPage: []).isEmpty,
                      "根本没有伙伴行 ⇒ 不进守卫")

        let store = MemoryOwnedItemStore()
        store.table = table
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([], marker: "7")]
        // 服务端上那一行真的存在，于是这次 tombstone commit 走 update 支并被接受。
        client.seed(tagHash: ruleHash("b"), ciphertext: Data(), version: 1, entityId: "srv-b")
        let engine = try makeRuleEngine(access, store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertEqual(ruleTombstoneCommits(client).count, 1, "正当的用户删除照常发出去")
        XCTAssertEqual(ruleTombstoneCommits(client).first?.baseVersion, 1)
        let counters = await counters(engine)
        XCTAssertEqual(counters?.tombstones, 1)
    }

    /// **对照三（求值点）**：在 (β) 停放态上跑一趟 `.localOwnedChange`（`push(...)` 那四支之一，
    /// 不是 `pullOnce()`）⇒ 那一趟同样零 tombstone、X 的行仍是软删态、`pendingDelete` 仍为真、
    /// `pendingApply` 一个字节没动。守卫住在 `tombstones` 闭包里，所以它对**每一种**走到发布段
    /// 的轮次都成立。
    ///
    /// **同一趟再加一条**：把守卫那一次的 `rows` 换成 `allURLRules()`（过滤软删）⇒ 守卫恒空
    /// ——(β) 的 X 结构性是软删态的，那一版必须红。
    func testM22_theGuardAlsoHoldsOnAPushOnlyRound() async throws {
        var rows: [PhiLocalURLRule] = []
        var table = PhiOwnedItemTable()
        seedBetaPark(rows: &rows, table: &table)
        // 停放态已经在盘上（上一轮 (β) 写下的），这一趟不拉任何页。
        table.cursors["b"]?.pendingApply = baselineBytes(
            urlRulePayload(uuid: "b", host: "github.com", rank: "W", contentStamp: 100))
        table.cursors["b"]?.pendingOwnerUuid = "su-1"
        let parkedPayload = table.cursors["b"]?.pendingApply

        let access = FakeURLRuleAccess(rows: rows)
        // 定义域那一格：含软删行 ⇒ 守卫命中；换成活行 ⇒ 恒空。
        XCTAssertTrue(access.partnerNotAtRest(table: table, rows: rows, resolve: resolve,
                                              tombstonesThisPage: []).contains("b"))
        XCTAssertTrue(access.partnerNotAtRest(table: table,
                                              rows: rows.filter { $0.deletedDate == nil },
                                              resolve: resolve,
                                              tombstonesThisPage: []).isEmpty,
                      "`rows` 取 `allURLRules()` 的那一版必须红")

        let store = MemoryOwnedItemStore()
        store.table = table
        let client = FakePhiSyncClient()
        let engine = try makeRuleEngine(access, store, client: client)
        await engine.setSpaceSyncEnabled(true)
        await engine.handleLocalOwnedChange(label: "urlrules")

        XCTAssertTrue(ruleTombstoneCommits(client).isEmpty, "push-only 的那一趟同样不发")
        let cursor = await engine.ownedTableForTesting("urlrules").cursors["b"]
        XCTAssertEqual(cursor?.pendingApply, parkedPayload, "`pendingApply` 一个字节没动")
        XCTAssertEqual(cursor?.pendingDelete, true)
        XCTAssertEqual(cursor?.deleteDecidedAtMs, 700)
        XCTAssertEqual(row(access, "b")?.deletedDate, Date(timeIntervalSince1970: 5))
    }

    // =======================================================================================
    // MARK: - CASE 8b-3.4（3b 复查：游标上没有可用的服务端三元组 ⇒ 零写）
    // =======================================================================================

    /// 一条走过 (ii) 的身份（`deletedAtMs != nil`、`reconciled == nil`、本机有活行），三元组
    /// **不可用**（`entityId` 为空 / `version == 0`），**同时**它的目标 Space 游标带 `hidden`。
    ///
    /// 防的是什么：把「没有可用三元组」也走撤销支的实现会**硬删一条本机活行**而账户上没有任何
    /// 东西被执行；把 RR13-6 读成「`pendingDelete == false` 就没有可执行的 tombstone」的实现会
    /// 让撤销让位整支变成死代码（(ii) 的记账已经把三个待办位清掉了）。
    func test8b34_aYieldWithNoUsableServerTripleWritesNothing() async throws {
        for (label, entityId, version) in [("entityId 为空", "", Int64(40)),
                                           ("version == 0", "srv-b", Int64(0))] {
            let rows: [PhiLocalURLRule] = [
                .fixture(id: "i-b", syncId: "b", spaceId: "space-a", host: "github.com",
                         contentUpdatedDate: stampDate(30), pendingLocalEdit: true),
            ]
            var table = PhiOwnedItemTable()
            table.cursors["b"] = yieldedCursor(entityId: entityId, version: version)

            let access = FakeURLRuleAccess(rows: rows)
            let store = MemoryOwnedItemStore()
            store.table = table
            let client = FakePhiSyncClient()
            client.pagesByMarker = [page([], marker: "7")]
            let spaceStore = try drainedSpaceStore()
            // 成因二那一格也成立（目标 Space 已 purge）⇒ 成因一必须**先**判，否则这一条会被
            // 撤销支硬删。
            spaceStore.table.cursors["su-1"] = purgedSpaceCursor()
            let engine = makeYieldEngine(access, store, client: client,
                                         spaceAccess: makeSpaceAccess(), spaceStore: spaceStore)
            await engine.setSpaceSyncEnabled(true)
            await engine.pullOnce()

            // **一个字节都不写。**
            let survivor = try XCTUnwrap(row(access, "b"), label)
            XCTAssertNil(survivor.deletedDate, "\(label)：行还在")
            XCTAssertTrue(survivor.pendingLocalEdit, "\(label)：`pendingLocalEdit` 一个字节不动")
            XCTAssertEqual(survivor.contentUpdatedDate, stampDate(30), label)
            let cursor = await engine.ownedTableForTesting("urlrules").cursors["b"]
            XCTAssertEqual(cursor?.deletedAtMs, Self.now - 1_000, "\(label)：`deletedAtMs` 还在")
            XCTAssertNil(cursor?.reconciled, label)
            XCTAssertNil(cursor?.server, label)
            XCTAssertTrue(ruleCommits(client).isEmpty, "\(label)：不发任何 tombstone，也不发 3b")
            XCTAssertFalse(access.lastAppliedOps.contains { if case .delete = $0 { return true }
                                                            else { return false } },
                           "\(label)：撤销支没跑")
            XCTAssertTrue(access.hardDeleteCalls.isEmpty, label)
        }
    }

    // =======================================================================================
    // MARK: - CASE M-12 变体 (2) / (4)（跨轮复查 ⇒ 撤销让位、硬删）
    // =======================================================================================

    /// 第一轮：准入**通过**，3b 发出去却拿 `.conflict`（连同那次限定重发一起）⇒ 让位状态原样
    /// 留着。**下一轮**才让目标 Space 转 `hidden` ⇒ **那一轮仍然复查并撤销让位、硬删**。
    ///
    /// 这一条同时是**变体 (4)**：行上 `pendingLocalEdit == false`（那条身份当初只靠取值式
    /// `unpublished` 让位），而让位记账已经把两份基线清 nil ⇒ 把复查的第三个合取项写成
    /// 「`pendingLocalEdit` ∨ `unpublished`」的实现在这里恒假 ⇒ 这条身份被**永久**排除在复查
    /// 之外、行永远留着 ⇒ 断言「行没了」必须红。
    ///
    /// 防的是什么：把复查绑在**本轮** `yieldedTombstones` 上的实现在第二轮什么都不做。
    func testM12_variant2_theRecheckRevokesTheYieldOnALaterRound() async throws {
        let rows: [PhiLocalURLRule] = [
            .fixture(id: "i-b", syncId: "b", spaceId: "space-a", host: "github.com",
                     contentUpdatedDate: stampDate(30), pendingLocalEdit: false),
        ]
        var table = PhiOwnedItemTable()
        table.cursors["b"] = yieldedCursor()

        let access = FakeURLRuleAccess(rows: rows)
        let store = MemoryOwnedItemStore()
        store.table = table
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([], marker: "7"), page([], marker: "8")]
        // 第一轮那次 3b 与它的限定重发都拿 `.conflict`（`forcedConflicts` 在服务端行寻址之前
        // 判，所以不需要往 `stored` 里塞行）。
        client.forcedConflicts = 2
        let spaceStore = try drainedSpaceStore()
        let engine = makeYieldEngine(access, store, client: client,
                                     spaceAccess: makeSpaceAccess(), spaceStore: spaceStore)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        // 第一轮：准入通过 ⇒ 3b 真的发了（`base_version` 取 tombstone 那一版），但没被接受。
        XCTAssertEqual(ruleCommits(client).count, 2, "一次 3b + 一次限定重发")
        XCTAssertEqual(ruleCommits(client).first?.baseVersion, 40)
        XCTAssertEqual(ruleCommits(client).first?.deleted, false)
        XCTAssertNotNil(row(access, "b"), "让位状态原样留着")
        var cursor = await engine.ownedTableForTesting("urlrules").cursors["b"]
        XCTAssertEqual(cursor?.deletedAtMs, Self.now - 1_000, "`.conflict` 不写任何基线")
        XCTAssertNil(cursor?.reconciled)

        // 第二轮：目标 Space 转 hidden ⇒ 复查照跑（本轮 `yieldedTombstones` 是空集）⇒ 撤销。
        spaceStore.table.cursors["su-1"] = purgedSpaceCursor()
        await engine.pullOnce()

        XCTAssertNil(row(access, "b"), "撤销让位：那一行被**硬删**")
        XCTAssertTrue(access.lastAppliedOps.contains { if case .delete(let syncId) = $0 {
            return syncId == "b" } else { return false } }, "走的是 `registration.land([.delete])`")
        cursor = await engine.ownedTableForTesting("urlrules").cursors["b"]
        XCTAssertEqual(cursor?.deletedAtMs, Self.now, "按 `:3195-3201` 逐字记账")
        XCTAssertEqual(cursor?.pendingDelete, false)
        XCTAssertNil(cursor?.reconciled)
        XCTAssertNil(cursor?.server)
        XCTAssertEqual(ruleCommits(client).count, 2, "撤销那一轮一条都不发（身份已剔出切片）")
    }

    // =======================================================================================
    // MARK: - CASE M-12 变体 (3)（成因区分：解析不出 ≠ hidden ⇒ 零写）
    // =======================================================================================

    /// 目标 Space 只是**暂时不在 `currentSpaces()` 里**（**没有** `hidden`、**没有**
    /// `purgedAtMs`，Space 游标根本不存在）⇒ 不硬删、不发任何 tombstone、行与
    /// `pendingLocalEdit` 与 `deletedAtMs` 一个字节不动、那一轮也不发 3b；映射建立之后正常发
    /// 3b、`resurrected == 1`。
    ///
    /// 防的是什么：一刀切硬删的实现在这里把一条用户还在用的规则连同它那次未发布编辑一起删掉。
    func testM12_variant3_anUnresolvableOwnerWritesNothingAndRepublishesLater() async throws {
        let rows: [PhiLocalURLRule] = [
            .fixture(id: "i-b", syncId: "b", spaceId: "space-a", host: "github.com",
                     contentUpdatedDate: stampDate(30), pendingLocalEdit: true),
        ]
        var table = PhiOwnedItemTable()
        table.cursors["b"] = yieldedCursor()

        let access = FakeURLRuleAccess(rows: rows)
        let store = MemoryOwnedItemStore()
        store.table = table
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([], marker: "7"), page([], marker: "8")]
        // 3b 被接受要求服务端那一行真的在（tombstone 那一版）。
        client.seed(tagHash: ruleHash("b"), ciphertext: Data(), version: 40, entityId: "srv-b",
                    deleted: true)
        let spaceAccess = makeSpaceAccess()
        let restored = spaceAccess.spaces
        // Space 列表还没加载：映射表还在，但它不在 `currentSpaces()` 里 ⇒ 归属不合格 ⇒ 这一行
        // 惰性 ⇒ 进不了快照 ⇒ 准入不过；而 Space 游标**不存在** ⇒ 成因二不成立。
        spaceAccess.spaces = []
        let spaceStore = try drainedSpaceStore()
        let engine = makeYieldEngine(access, store, client: client,
                                     spaceAccess: spaceAccess, spaceStore: spaceStore)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let survivor = try XCTUnwrap(row(access, "b"), "不硬删")
        XCTAssertTrue(survivor.pendingLocalEdit, "`pendingLocalEdit` 一个字节不动")
        XCTAssertEqual(survivor.contentUpdatedDate, stampDate(30))
        var cursor = await engine.ownedTableForTesting("urlrules").cursors["b"]
        XCTAssertEqual(cursor?.deletedAtMs, Self.now - 1_000, "`deletedAtMs` 留着")
        XCTAssertTrue(ruleCommits(client).isEmpty, "那一轮也不发 3b")
        XCTAssertTrue(access.hardDeleteCalls.isEmpty)

        // 映射建立之后：准入通过 ⇒ 正常发 3b ⇒ `.applied` ⇒ 复活。
        spaceAccess.spaces = restored
        await engine.pullOnce()

        XCTAssertEqual(ruleCommits(client).count, 1, "3b 发出去了")
        XCTAssertEqual(ruleCommits(client).first?.baseVersion, 40)
        XCTAssertEqual(ruleCommits(client).first?.deleted, false)
        cursor = await engine.ownedTableForTesting("urlrules").cursors["b"]
        XCTAssertNil(cursor?.deletedAtMs, "§4.2 规则 3b 的复活：`deletedAtMs` 被清")
        XCTAssertNotNil(cursor?.reconciled)
        let counters = await counters(engine)
        XCTAssertEqual(counters?.resurrected, 1)
        XCTAssertNotNil(row(access, "b"), "行一直都在")
    }

}

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
        // ③ 留给 8b-2（M2 收敛）：这里只钉「没有任何一条已发布实体因为认领而被删」。
        XCTAssertNil(store.table.cursors["local-a"]?.deletedAtMs)
        XCTAssertTrue(ruleCommits(client).filter(\.deleted).isEmpty)
        XCTAssertEqual(access.rows.filter { $0.deletedDate == nil }.count, 2)
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
}

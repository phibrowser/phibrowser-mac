import XCTest
@testable import Phi

/// D6 §2.1 的映射层。每一条都是「同一个 Space 在账户里只有一个身份」的安全性质：
/// 铸重了就是账户里多一条永远合不掉的 Space，认领串了就是两台机器的两个 Space 被
/// 焊成一个，而映射一旦写下没有任何 UI 能撤。
@MainActor
final class SpaceSyncMappingManagerTests: XCTestCase {

    /// 与 `ProfileKeyManagerTests.MemoryMappingStore`（ProfileKeyManagerTests.swift:9-16）
    /// 逐行同形的内存假件。
    final class MemorySpaceMappingStore: SpaceSyncMappingStore {
        var map: [String: String] = [:]
        func syncUuid(forSpaceId spaceId: String) -> String? { map[spaceId] }
        func setSyncUuid(_ uuid: String, forSpaceId spaceId: String) { map[spaceId] = uuid }
        func allMappings() -> [String: String] { map }
        func removeMapping(forSpaceId spaceId: String) { map.removeValue(forKey: spaceId) }
        func removeAllMappings() { map = [:] }
    }

    private func makeManager() -> (SpaceSyncMappingManager, MemorySpaceMappingStore) {
        let store = MemorySpaceMappingStore()
        return (SpaceSyncMappingManager(store: store), store)
    }

    /// 本地 spaceId 是 `UUID().uuidString`（大写，SpaceManager.swift:960）。
    private let localId = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"

    // MARK: - 1. 铸造

    func testMintWritesALowercaseUuidThatIsNeverTheLocalSpaceId() throws {
        let (keys, store) = makeManager()
        let minted = try keys.mintSyncUuid(forSpaceId: localId)
        XCTAssertEqual(minted, minted.lowercased(),
                       "syncUuid 一律小写，于是「谁把本地 id 当 syncUuid 用了」在日志与 plist 里肉眼可辨")
        XCTAssertNotEqual(minted, localId, "绝不复用本地 spaceId")
        XCTAssertEqual(store.map, [localId: minted])
        XCTAssertEqual(keys.syncUuid(forSpaceId: localId), minted)
    }

    // MARK: - 2. C-1 同款防线

    func testMintRefusesASecondUuidForAnAlreadyMappedSpaceAndLeavesTheTableAlone() throws {
        let (keys, store) = makeManager()
        let first = try keys.mintSyncUuid(forSpaceId: localId)
        XCTAssertThrowsError(try keys.mintSyncUuid(forSpaceId: localId)) { error in
            XCTAssertEqual(error as? SpaceSyncMappingError, .alreadyMapped)
        }
        XCTAssertEqual(store.map, [localId: first], "一次瞬时失败不能铸出第二个 uuid")
    }

    // MARK: - 3. 认领

    func testMapClaimsAnAccountSpaceAndRefusesADoubleClaim() throws {
        let (keys, store) = makeManager()
        try keys.map(spaceId: localId, toSyncUuid: "acct-1")
        XCTAssertEqual(store.map, [localId: "acct-1"])

        XCTAssertThrowsError(try keys.map(spaceId: "OTHER", toSyncUuid: "acct-1")) { error in
            XCTAssertEqual(error as? SpaceSyncMappingError, .syncUuidAlreadyClaimed)
        }
        XCTAssertThrowsError(try keys.map(spaceId: localId, toSyncUuid: "acct-2")) { error in
            XCTAssertEqual(error as? SpaceSyncMappingError, .alreadyMapped)
        }
        XCTAssertEqual(store.map, [localId: "acct-1"], "两次拒绝都不许改表")
    }

    // MARK: - 4. 反查与 tie-break

    func testReverseLookupResolvesAndTieBreaksLexicographically() {
        let (keys, store) = makeManager()
        // 结构上不该出现（`map` 的 `.syncUuidAlreadyClaimed` 是闸）；假件直接构造非法态。
        store.map = ["ZZZ": "acct-1", "AAA": "acct-1"]
        XCTAssertEqual(keys.localSpaceId(forSyncUuid: "acct-1"), "AAA")
        XCTAssertNil(keys.localSpaceId(forSyncUuid: "acct-nope"))
    }

    // MARK: - 5. 默认 Space 的双向常量（R-D6-2）

    func testTheDefaultSpaceResolvesBothWaysWithoutAMappingRow() {
        let (keys, store) = makeManager()
        XCTAssertEqual(keys.syncUuid(forSpaceId: LocalStore.defaultSpaceId),
                       SyncableSpaces.defaultSpaceUuid)
        XCTAssertEqual(keys.localSpaceId(forSyncUuid: SyncableSpaces.defaultSpaceUuid),
                       LocalStore.defaultSpaceId)
        XCTAssertTrue(store.map.isEmpty, "默认 Space 不存映射行")

        XCTAssertThrowsError(try keys.mintSyncUuid(forSpaceId: LocalStore.defaultSpaceId)) {
            XCTAssertEqual($0 as? SpaceSyncMappingError, .defaultSpaceIsImplicit)
        }
        XCTAssertThrowsError(try keys.map(spaceId: LocalStore.defaultSpaceId, toSyncUuid: "x")) {
            XCTAssertEqual($0 as? SpaceSyncMappingError, .defaultSpaceIsImplicit)
        }
    }

    /// §2.1：两个常量取值相等纯属约定，由这条断言钉住，不是一条编译期依赖
    /// （`defaultSpaceUuid` 不许再写成 `= LocalStore.defaultSpaceId`）。
    func testTheTwoDefaultConstantsAgreeByTestRatherThanByAlias() {
        XCTAssertEqual(SyncableSpaces.defaultSpaceUuid, LocalStore.defaultSpaceId)
        XCTAssertEqual(SyncableSpaces.defaultSpaceUuid, "default-space")
    }

    // MARK: - 6/7. 删除

    func testRemoveMappingDropsOnlyThatEntry() {
        let (keys, store) = makeManager()
        store.map = ["a": "acct-a", "b": "acct-b"]
        keys.removeMapping(forSpaceId: "a")
        XCTAssertEqual(store.map, ["b": "acct-b"])
        keys.removeMapping(forSpaceId: LocalStore.defaultSpaceId)   // no-op
        XCTAssertEqual(store.map, ["b": "acct-b"])
    }

    /// 自撤销把整表写空。默认 Space 的解析必须活下来——这是常量分支存在的全部理由：
    /// 一行 `"default-space" -> "default-space"` 会被一起删掉，重新加入时账户里那条
    /// `default-space` 实体从此再也收不到这台机器的更新。
    func testRemoveAllMappingsKeepsTheDefaultSpaceResolvable() {
        let (keys, store) = makeManager()
        store.map = ["a": "acct-a"]
        keys.removeAllMappings()
        XCTAssertTrue(store.map.isEmpty)
        XCTAssertEqual(keys.syncUuid(forSpaceId: LocalStore.defaultSpaceId),
                       SyncableSpaces.defaultSpaceUuid)
        XCTAssertEqual(keys.localSpaceId(forSyncUuid: SyncableSpaces.defaultSpaceUuid),
                       LocalStore.defaultSpaceId)
    }

    // MARK: - 8. 懒铸造的幂等（R-D6-7）

    func testEnsureMappedIsIdempotent() throws {
        let (keys, store) = makeManager()
        let first = try keys.ensureMapped(spaceId: localId)
        let second = try keys.ensureMapped(spaceId: localId)
        XCTAssertEqual(first, second)
        XCTAssertEqual(store.map.count, 1)
        XCTAssertEqual(try keys.ensureMapped(spaceId: LocalStore.defaultSpaceId),
                       SyncableSpaces.defaultSpaceUuid, "默认 Space 走常量分支，不铸也不写表")
        XCTAssertEqual(store.map.count, 1)
    }

    // MARK: - 生产 store（spec §10.1 末行）

    /// `AccountUserDefaults` 确实只能由一个真的 `Account` 构造
    /// （AccountUserDefaults.swift:15-29），但**那不是障碍**：`Account` 是 internal、
    /// init 是 `init(userID:userInfo:)`（Account.swift:26）、`userDefaults` 是
    /// `private(set) lazy var`（:22），而测试套件里已经有现成的先例
    /// （`AccountPhiSpaceAccessMappingTests.makeAccess` 就写着
    /// `Account(userID: UUID().uuidString)`，PhiSpaceLocalAccessTests.swift:188）。
    /// 唯一的代价是一次真实的磁盘副作用：`AccountUserDefaults.init` 会建出
    /// `FileSystemUtils.phiBrowserDataDirectory()/users/<uuid>/defaults/`，所以每条
    /// 用例用一个**全新的随机 userID**，并在 `tearDown` 里删掉那棵子树。
    ///
    /// 值得为此写这一组的理由：`removeMapping` 的
    /// `guard map.removeValue(forKey:) != nil else { return }` 早退与
    /// `removeAllMappings` 「写一张空字典」而不是 `removeObject` 的选择，都是**静默
    /// 丢数据**形状的分支，纯内存假件一条都覆盖不到。
    private var scratchAccounts: [Account] = []

    private func makeAccountStore() -> AccountSpaceSyncMappingStore {
        let account = Account(userID: UUID().uuidString)
        scratchAccounts.append(account)
        return AccountSpaceSyncMappingStore(defaults: account.userDefaults)
    }

    override func tearDown() {
        for account in scratchAccounts {
            try? FileManager.default.removeItem(at: account.userDataStorage)
        }
        scratchAccounts = []
        super.tearDown()
    }

    /// 键名是「这张表按账户隔离」的全部理由，一次改名会把老机器的映射静默丢掉。
    func testTheAccountStoreUsesTheKeyTheDesignNames() {
        XCTAssertEqual(AccountSpaceSyncMappingStore.defaultsKey, "sync.spaceGlobalUuids")
    }

    func testTheAccountStoreRoundTripsEveryMethodThroughTheAccountPlist() {
        let store = makeAccountStore()
        XCTAssertEqual(store.allMappings(), [:], "一张没写过的表读出来是空的，不是 nil 崩溃")

        store.setSyncUuid("sync-1", forSpaceId: "LOCAL-1")
        store.setSyncUuid("sync-2", forSpaceId: "LOCAL-2")
        XCTAssertEqual(store.syncUuid(forSpaceId: "LOCAL-1"), "sync-1")
        XCTAssertEqual(store.allMappings(), ["LOCAL-1": "sync-1", "LOCAL-2": "sync-2"])

        store.removeMapping(forSpaceId: "LOCAL-1")
        XCTAssertNil(store.syncUuid(forSpaceId: "LOCAL-1"))
        XCTAssertEqual(store.allMappings(), ["LOCAL-2": "sync-2"], "只删这一条，其余一字不动")
        // 早退分支：删一条不存在的行不许把表清掉。
        store.removeMapping(forSpaceId: "LOCAL-404")
        XCTAssertEqual(store.allMappings(), ["LOCAL-2": "sync-2"])

        store.removeAllMappings()
        XCTAssertEqual(store.allMappings(), [:])
    }

    /// 持久化那一半：**第二个** store 建在同一个 `Account` 上，读到的必须是同一张表。
    /// 这是「切账户不需要任何清理」的可执行版本——表跟着 plist 走，不跟着实例走。
    func testASecondStoreOverTheSameAccountReadsTheSameTable() {
        let account = Account(userID: UUID().uuidString)
        scratchAccounts.append(account)
        AccountSpaceSyncMappingStore(defaults: account.userDefaults)
            .setSyncUuid("sync-1", forSpaceId: "LOCAL-1")
        XCTAssertEqual(AccountSpaceSyncMappingStore(defaults: account.userDefaults).allMappings(),
                       ["LOCAL-1": "sync-1"])
    }
}

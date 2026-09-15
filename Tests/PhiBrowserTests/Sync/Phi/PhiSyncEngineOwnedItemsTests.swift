import CryptoKit
import Foundation
import XCTest
@testable import Phi

/// M3-3 §5 的引擎接缝：kind 注册 / 分发 / tag 校验 / 轮次 / 切片 / 门 / 计数。
///
/// **本文件的注册清单里只有书签那一条。** 引擎对归属 kind 是泛型的，pin 由 Task 5b-2 以
/// 同样的形状追加；两条 kind 并存的情形由那一批用例覆盖。
///
/// 驱动一律走既有入口（`setSpaceSyncEnabled(_:)` + `pullOnce()`），断言一律先 `await` 取值
/// 再比——`XCTAssert*` 的参数是 autoclosure，直接把 `await` 表达式塞进去取不到值。假件都是
/// `@MainActor`，所以整个测试类标 `@MainActor`（形状照 `PhiSyncEngineSpaceTests`）。
@MainActor
final class PhiSyncEngineOwnedItemsTests: XCTestCase {
    typealias FakePhiSyncClient = PhiSyncEngineTests.FakePhiSyncClient
    typealias StubDomainKeys = PhiSyncEngineTests.StubDomainKeys
    typealias Gate = PhiSyncEngineTests.Gate
    typealias MemorySpaceStore = PhiSyncEngineSpaceTests.MemorySpaceStore
    typealias Clock = PhiSyncEngineSpaceTests.Clock

    private var defaults: UserDefaults!
    private var suiteName: String!
    private let key = SymmetricKey(size: .bits256)

    override func setUp() {
        super.setUp()
        suiteName = "PhiSyncEngineOwnedItemsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func bookmarkHash(_ uuid: String) -> String {
        PhiSyncEntity.clientTagHash(for: PhiSyncEntity.bookmarkClientTag(uuid))
    }

    private func bookmarkTag(_ uuid: String) -> String {
        PhiSyncEntity.bookmarkClientTag(uuid)
    }

    /// 预览侧的小工具。预览只认 Space 形状的载荷，所以这里只要 Space 的 tag 与密文；
    /// 书签那一条用上面既有的 `bookmarkTag(_:)`。
    private func spaceHash(_ uuid: String) -> String {
        PhiSyncEntity.clientTagHash(for: PhiSyncEntity.spaceClientTag(uuid))
    }

    private func spaceCiphertext(_ uuid: String, name: String = "Work") throws -> Data {
        try PhiEntityCodec.encrypt(envelope(spacePayload(uuid: uuid, name: name)), key: key)
    }

    private func space(_ spaceId: String) -> PhiLocalSpace {
        PhiLocalSpace(spaceId: spaceId, profileId: "Default", name: "S", colorHex: "#3A6FF8",
                      iconName: "emoji:1F4BC", sortOrder: 0,
                      createdDate: Date(timeIntervalSince1970: 1), themeId: nil,
                      opacityLight: nil, opacityDark: nil)
    }

    /// 一台已经配过对的机器：Space 映射齐备，profile 双向映射齐备。
    private func makeSpaceAccess(_ mappings: [String: String] = ["s-1": "su-1"])
        -> FakePhiSpaceAccess {
        let access = FakePhiSpaceAccess()
        access.spaceMappings = mappings
        access.spaces = mappings.keys.sorted().map(space)
        access.uuidByProfileId = ["Default": "pu-1"]
        access.profileIdByUuid = ["pu-1": "Default"]
        access.knownLocalProfileIds = ["Default"]
        return access
    }

    /// `hasDrainedFullReplay` 预置为真 = 这台机器已经完整拉过一遍这个 data type，
    /// 所以发布侧的 guard ① 不挡路。断言它反面的用例（CASE 6.14 / 6.23 / 6.26）不经这里。
    private func makeSpaceStore(drained: Bool = true) -> MemorySpaceStore {
        let store = MemorySpaceStore()
        store.table.hasDrainedFullReplay = drained
        return store
    }

    /// 形状照 `PhiSyncEngineSpaceTests.makeEngine`：**除 `client:` 外每个参数都有默认值**。
    ///
    /// `settings: []` 不是装饰：没有它，引擎会在一个一次性 defaults suite 上按生产的
    /// `SyncableSettings.all` 注册表跑，每一轮都把一条真的设置实体提交进这些用例正在数的
    /// 那个 `client.commits` 里。所有条数断言因此都走 `bookmarkCommits(_:)`。
    /// `access:` 是 `FakePhiSpaceAccess?` 而不是一个带默认实参的非可选值：那个假件是
    /// `@MainActor` 的，而默认实参在**非隔离**的上下文里求值，`= FakePhiSpaceAccess()`
    /// 编不过。调用方的写法不变（`makeEngine(client:ownedKinds:)` 仍然合法）。
    private func makeEngine(client: FakePhiSyncClient,
                            access: FakePhiSpaceAccess? = nil,
                            store: MemorySpaceStore = MemorySpaceStore(),
                            clock: Clock = Clock(),
                            domainKeys: StubDomainKeys? = nil,
                            ownedKinds: [OwnedKindRegistration] = [],
                            previewMaxPages: Int = PhiSyncEngine.defaultPreviewMaxPages)
        -> PhiSyncEngine {
        PhiSyncEngine(domainKeys: domainKeys ?? StubDomainKeys(key: key),
                      client: client, defaults: defaults, deviceKeyId: "devA",
                      settings: [], spaceAccess: access ?? makeSpaceAccess(), spaceStore: store,
                      ownedKinds: ownedKinds, previewMaxPages: previewMaxPages,
                      now: { clock.read() })
    }

    private func bookmarkKind(_ access: FakeBookmarkAccess,
                              _ store: MemoryOwnedItemStore) -> OwnedKindRegistration {
        .bookmarks(access: access, store: store)
    }

    /// 一条 commit 的密文解出来的整条书签实体。顺序与字段断言都靠它。
    private func committedBookmark(_ call: FakePhiSyncClient.CommitCall) -> Phi_PhiBookmarkEntity? {
        guard let ciphertext = call.ciphertext,
              let entity = try? PhiEntityCodec.decrypt(ciphertext, key: key),
              case .bookmark(let payload)? = entity.kind else { return nil }
        return payload
    }

    private func applyCallCount(_ access: FakeBookmarkAccess) -> Int {
        access.calls.filter { if case .apply = $0 { return true } else { return false } }.count
    }

    /// 一条**活**的已发布游标：有基线、有服务端三元组、归属已知。
    private func publishedCursor(_ payload: Phi_PhiBookmarkEntity,
                                 entityId: String = "srv-1",
                                 version: Int64 = 1,
                                 owner: String = "su-1") -> PhiOwnedItemCursor {
        ownedCursor(reconciled: baselineBytes(payload), server: baselineBytes(payload),
                    entityId: entityId, version: version, ownerUuid: owner)
    }

    // MARK: - pin 侧的同款小工具

    /// pin 的 client tag 两段都进：身份是 `(lineage, owner)` 这一对，一条 lineage 在 N 个
    /// owner 下就是 N 条实体。
    private func pinTag(_ lineage: String, owner: String = "pu-1") -> String {
        PhiSyncEntity.pinClientTag(lineage, ownerKey: owner)
    }

    private func pinHash(_ lineage: String, owner: String = "pu-1") -> String {
        PhiSyncEntity.clientTagHash(for: pinTag(lineage, owner: owner))
    }

    private func pinKind(_ access: FakePinAccess,
                         _ store: MemoryOwnedItemStore) -> OwnedKindRegistration {
        .pins(access: access, store: store)
    }

    /// 一条 commit 的密文解出来的整条 pin 实体。
    private func committedPin(_ call: FakePhiSyncClient.CommitCall) -> Phi_PhiPinTabEntity? {
        guard let ciphertext = call.ciphertext,
              let entity = try? PhiEntityCodec.decrypt(ciphertext, key: key),
              case .pinTab(let payload)? = entity.kind else { return nil }
        return payload
    }

    /// pin 那一侧的 `publishedCursor`：归属默认是 profile 作用域的 `pu-1`。
    private func publishedPinCursor(_ payload: Phi_PhiPinTabEntity,
                                    entityId: String = "srv-p1",
                                    version: Int64 = 1,
                                    owner: String = "pu-1") -> PhiOwnedItemCursor {
        ownedCursor(reconciled: baselineBytes(payload), server: baselineBytes(payload),
                    entityId: entityId, version: version, ownerUuid: owner)
    }

    // MARK: - CASE 6.1 – 6.3：分发

    /// CASE 6.1 — 一页四种实体混排，各归各位。
    func testOnePageOfFourKindsRoutesEachEntityToItsOwnSection() async throws {
        let spaceAccess = makeSpaceAccess()
        let spaceStore = makeSpaceStore()
        let access = FakeBookmarkAccess()
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        var remoteSpace = spacePayload(uuid: "su-9")
        remoteSpace.profileUuid = stamped("pu-1", at: 100)
        client.scriptedPages = [page([
            remoteSettingsEntity(key: "theme.dark", value: "on", version: 10, key: key),
            remoteEntity(envelope(remoteSpace), tag: PhiSyncEntity.spaceClientTag("su-9"),
                         version: 11, entityId: "srv-space", key: key),
            remoteEntity(envelope(bookmarkPayload(uuid: "b1")), tag: bookmarkTag("b1"),
                         version: 12, entityId: "srv-b1", key: key),
            remoteUnknownKind(tag: "phi-future:x", version: 13, key: key),
        ])]

        let engine = makeEngine(client: client, access: spaceAccess, store: spaceStore,
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertEqual(Set(table.cursors.keys), ["b1"])
        let counters = await engine.lastOwnedRoundCountersForTesting["bookmarks"]
        XCTAssertEqual(counters?.pulled, 1)
        XCTAssertNotNil(spaceStore.table.cursors["su-9"], "Space 段照常落位")
        XCTAssertNotNil(defaults.data(forKey: PhiSyncEngine.lastEntityStateKey),
                        "settings 段照常落位")
        let unreadable = await engine.spaceTableForTesting.unreadableTagHashes
        XCTAssertTrue(unreadable.isEmpty, "未知 kind 既不进任何表也不报错")
    }

    /// CASE 6.2 — tombstone 的路由先于任何解密尝试。
    ///
    /// 防的是什么：tombstone 没有密文，解密必然抛错；把它归进「解不开」会让每一条远端删除
    /// **永久丢失**——marker 已经推过那一页，服务端再也不会重发。
    func testATombstoneIsRoutedBeforeAnyDecryptAttempt() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "G1", syncId: "b1", spaceId: "s-1"),
        ])
        let store = MemoryOwnedItemStore()
        store.table.cursors["b1"] = publishedCursor(bookmarkPayload(uuid: "b1"))
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([remoteTombstone(tag: bookmarkTag("b1"), version: 2)])]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let counters = await engine.lastOwnedRoundCountersForTesting["bookmarks"]
        XCTAssertEqual(counters?.tombstones, 1)
        XCTAssertEqual(counters?.unreadable, 0)
        let unreadable = await engine.spaceTableForTesting.unreadableTagHashes
        XCTAssertTrue(unreadable.isEmpty)
    }

    /// CASE 6.3 — 同一次 drain 内学到的身份立刻可路由。
    ///
    /// 防的是什么：一棵上千条的树跨十几页拉；索引每页重建一次的实现会把后面整页归进
    /// 「不认识」，而 marker 已经过去了。
    func testAnIdentityLearnedOnPageOneRoutesItsTombstoneOnPageTwo() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess()
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.scriptedPages = [
            page([remoteEntity(envelope(bookmarkPayload(uuid: "b7")), tag: bookmarkTag("b7"),
                               version: 5, entityId: "srv-b7", key: key)],
                 marker: "m1", changesRemaining: true),
            page([remoteTombstone(tag: bookmarkTag("b7"), version: 6)], marker: "m2"),
        ]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let counters = await engine.lastOwnedRoundCountersForTesting["bookmarks"]
        XCTAssertEqual(counters?.tombstones, 1)
    }

    // MARK: - CASE 6.4 – 6.6b：tag 校验

    /// CASE 6.4 — 载荷与 tag 不符 ⇒ 丢弃、游标不动、hash 进隔离区。
    ///
    /// 防的是什么：动了游标的实现会把一条伪造或对端 bug 的载荷当成一次合法更新的基线。
    func testAPayloadThatDoesNotHashBackToItsTagIsQuarantinedAndLeavesTheCursorAlone() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "G1", syncId: "b1", spaceId: "s-1"),
        ])
        let store = MemoryOwnedItemStore()
        store.table.cursors["b1"] = publishedCursor(bookmarkPayload(uuid: "b1"), version: 3)
        let before = store.table.cursors["b1"]
        let client = FakePhiSyncClient()
        // tag 是 b1，载荷里的 `bookmark_uuid` 是 b2。
        client.scriptedPages = [page([
            remoteEntity(envelope(bookmarkPayload(uuid: "b2")), tag: bookmarkTag("b1"),
                         version: 9, entityId: "srv-1", key: key),
        ])]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertEqual(table.cursors["b1"]?.version, 3)
        XCTAssertEqual(table.cursors["b1"], before, "游标一个字段都不许动")
        XCTAssertNil(table.cursors["b2"], "伪造载荷绝不长出游标")
        let unreadable = await engine.spaceTableForTesting.unreadableTagHashes
        XCTAssertEqual(Set(unreadable.keys), [bookmarkHash("b1")])
    }

    /// CASE 6.5 — 载荷的归属与 tag 上一轮记录的归属不同时**照常落地**。
    ///
    /// 防的是什么：把校验写成「连归属一起比」会把每一次跨 Space 移动都判成伪造载荷。
    /// §2.5 校验的是**身份**，不是归属。
    func testACrossSpaceMoveIsNotTreatedAsAForgedPayload() async throws {
        let spaceAccess = makeSpaceAccess(["s-1": "su-1", "s-2": "su-2"])
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "G1", syncId: "b1", spaceId: "s-1"),
        ])
        let store = MemoryOwnedItemStore()
        store.table.cursors["b1"] = publishedCursor(
            bookmarkPayload(uuid: "b1", spaceUuid: "su-1", locationStamp: 100))
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([
            remoteEntity(envelope(bookmarkPayload(uuid: "b1", spaceUuid: "su-2",
                                                  locationStamp: 500)),
                         tag: bookmarkTag("b1"), version: 9, entityId: "srv-1", key: key),
        ])]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let unreadable = await engine.spaceTableForTesting.unreadableTagHashes
        XCTAssertTrue(unreadable.isEmpty, "跨 Space 移动不是伪造载荷")
        XCTAssertEqual(access.rows.first { $0.guid == "G1" }?.spaceId, "s-2")
    }

    /// CASE 6.6 — tombstone 豁免 tag 校验（它没有载荷可反推）。
    func testATombstoneIsExemptFromTheTagVerification() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess()
        let store = MemoryOwnedItemStore()
        store.table.cursors["b1"] = publishedCursor(bookmarkPayload(uuid: "b1"))
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([remoteTombstone(tag: bookmarkTag("b1"), version: 4)])]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let unreadable = await engine.spaceTableForTesting.unreadableTagHashes
        XCTAssertTrue(unreadable.isEmpty)
        let table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertNotNil(table.cursors["b1"]?.deletedAtMs, "本机没有行也照样定案这次删除")
    }

    /// CASE 6.6b — 实体的 `is_folder` 与本机那一行的物理类型不符 ⇒ 拒收。
    ///
    /// 防的是什么：落地会把一条书签行原地变成文件夹，它的 URL 随即失去意义；反方向则让一个
    /// 文件夹变成书签，**它的孩子当场失去父**。`refuses(_:baseline:)` 覆盖不到这一类——它比
    /// 的是游标基线，而这条身份本机根本没有基线。
    func testAnEntityWhoseFolderFlagContradictsThePhysicalRowIsRefused() async throws {
        // 本机那一行坐在一个**没有映射**的 Space 里，所以它不进快照、不会被发布——这条用例
        // 要断言的是「一次拒收不建游标」，不该被同一轮的发布段搅进来。
        let spaceAccess = makeSpaceAccess()
        let row = PhiLocalBookmark.fixture(guid: "G1", syncId: "b1", spaceId: "s-9",
                                           isFolder: false)
        let access = FakeBookmarkAccess(rows: [row])
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([
            remoteEntity(envelope(bookmarkPayload(uuid: "b1", isFolder: true,
                                                  url: "https://bookmark.phi/folder")),
                         tag: bookmarkTag("b1"), version: 9, entityId: "srv-1", key: key),
        ])]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let counters = await engine.lastOwnedRoundCountersForTesting["bookmarks"]
        XCTAssertEqual(counters?.refused, 1)
        XCTAssertEqual(access.rows, [row], "那一行一个字段都没变")
        let table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertNil(table.cursors["b1"], "一次拒收绝不建游标")
    }

    // MARK: - CASE 6.7 – 6.11b：轮次与切片

    /// CASE 6.7 — Space 与它下面三条书签同轮落地。
    ///
    /// 防的是什么：书签排在下一轮的实现会让每一棵新 Space 的树比它的 Space 晚一整轮。
    func testANewSpaceAndTheBookmarksUnderItLandInTheSameRound() async throws {
        let spaceAccess = makeSpaceAccess([:])
        let access = FakeBookmarkAccess()
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        var remoteSpace = spacePayload(uuid: "su-9")
        remoteSpace.profileUuid = stamped("pu-1", at: 100)
        var entities = [remoteEntity(envelope(remoteSpace),
                                     tag: PhiSyncEntity.spaceClientTag("su-9"),
                                     version: 10, entityId: "srv-space", key: key)]
        for index in 0..<3 {
            entities.append(remoteEntity(
                envelope(bookmarkPayload(uuid: "b\(index)", spaceUuid: "su-9",
                                         rank: "V\(index + 1)")),
                tag: bookmarkTag("b\(index)"), version: Int64(11 + index),
                entityId: "srv-b\(index)", key: key))
        }
        client.scriptedPages = [page(entities)]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let counters = await engine.lastOwnedRoundCountersForTesting["bookmarks"]
        XCTAssertEqual(counters?.applied, 3)
        XCTAssertEqual(counters?.parked, 0)
    }

    /// CASE 6.8 — 发布切片每轮 250（= 10 批 × 25）。
    func testThePublishSliceIsCappedAtTwoHundredAndFiftyPerRound() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: (0..<600).map {
            .fixture(guid: "G\($0)", spaceId: "s-1", index: $0)
        })
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let firstRound = bookmarkCommits(client).count
        XCTAssertEqual(firstRound, 250)
        let counters = await engine.lastOwnedRoundCountersForTesting["bookmarks"]
        XCTAssertEqual(counters?.pendingPublish, 350)

        // `commits` 是 `private(set)`，所以「清空再跑一轮」写成「减去上一轮的条数」。
        await engine.pullOnce()
        XCTAssertEqual(bookmarkCommits(client).count - firstRound, 350)
    }

    /// CASE 6.9 — 存活实体的切片是**拓扑序的前缀闭包**。
    ///
    /// 防的是什么：边界把父留到下一轮而先发孩子，那条孩子在对端只能停放，而停放项每轮重试
    /// 直到父在若干轮后到达。
    func testEveryEntityInTheSliceHasItsParentInTheSameSlice() async throws {
        let spaceAccess = makeSpaceAccess()
        var rows: [PhiLocalBookmark] = []
        for index in 0..<300 {
            rows.append(.fixture(guid: "G\(index)",
                                 spaceId: "s-1",
                                 parentGuid: index == 0 ? nil : "G\(index - 1)",
                                 index: 0,
                                 isFolder: true,
                                 url: URL(string: "https://bookmark.phi/folder")!))
        }
        let access = FakeBookmarkAccess(rows: rows)
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let commits = bookmarkCommits(client)
        XCTAssertEqual(commits.count, 250)
        let published = Set(commits.compactMap { committedBookmarkUuid($0, key: key) })
        for call in commits {
            guard let entity = committedBookmark(call) else {
                XCTFail("commit 的密文解不开")
                continue
            }
            let parent = entity.parentUuid.stringValue
            guard !parent.isEmpty else { continue }
            XCTAssertTrue(published.contains(parent),
                          "每一条的父也必须在这一片里")
        }
    }

    /// CASE 6.10 — tombstone 段反拓扑，祖先等后代 `.applied`。
    ///
    /// 防的是什么：`.pending` 不算——一条还没被服务端确认的子 tombstone 不能授权删它的父。
    func testAnAncestorTombstoneWaitsForItsDescendantToBeApplied() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess()
        let store = MemoryOwnedItemStore()
        store.table.cursors["parent"] = publishedCursor(
            bookmarkPayload(uuid: "parent", isFolder: true,
                            url: "https://bookmark.phi/folder"),
            entityId: "srv-parent", version: 4)
        store.table.cursors["child"] = publishedCursor(
            bookmarkPayload(uuid: "child", parentUuid: "parent"),
            entityId: "srv-child", version: 5)
        let client = FakePhiSyncClient()
        client.refuseCommitsForTagHashes = [bookmarkHash("child")]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let tombstones = Set(bookmarkCommits(client).filter(\.deleted).map(\.clientTagHash))
        XCTAssertEqual(tombstones, [bookmarkHash("child")], "父必须等着")
    }

    /// CASE 6.10b — tombstone 切片不把一棵子树拆到两轮。
    ///
    /// 防的是什么：拆开之后，对端在两轮之间看到的是「一个文件夹里的 300 条没了、另外 200 条
    /// 还在」——而它同时还会把那个仍然存在的文件夹当成活的，于是可能往里写新东西。
    func testATombstoneSliceNeverSplitsOneSubtreeAcrossTwoRounds() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess()
        let store = MemoryOwnedItemStore()
        store.table.cursors["folder"] = publishedCursor(
            bookmarkPayload(uuid: "folder", isFolder: true,
                            url: "https://bookmark.phi/folder"),
            entityId: "srv-folder", version: 4)
        var descendants: Set<String> = []
        for index in 0..<500 {
            let identity = "d\(String(format: "%03d", index))"
            descendants.insert(bookmarkHash(identity))
            store.table.cursors[identity] = publishedCursor(
                bookmarkPayload(uuid: identity, parentUuid: "folder"),
                entityId: "srv-\(identity)", version: 5)
        }
        let client = FakePhiSyncClient()

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let sent = Set(bookmarkCommits(client).filter(\.deleted).map(\.clientTagHash))
        XCTAssertEqual(sent, descendants,
                       "整棵子树一次发完，不出现「发了一部分、剩下的留到下一轮」的切法")
        XCTAssertFalse(sent.contains(bookmarkHash("folder")),
                       "文件夹自己要等后代被服务端接受")
    }

    /// CASE 6.10c — 接收侧：文件夹 tombstone 落地时提升集合为空也要成立。
    ///
    /// 防的是什么：R-M3-3-17 的三步里第 2 步在空集合上必须是零操作。写成「先取第一条后代」
    /// 的实现会在这里崩。
    func testAFolderTombstoneWithNoDescendantsLandsWithoutAnyLift() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "F1", syncId: "f1", spaceId: "s-1", isFolder: true,
                     url: URL(string: "https://bookmark.phi/folder")!),
        ])
        let store = MemoryOwnedItemStore()
        store.table.cursors["f1"] = publishedCursor(
            bookmarkPayload(uuid: "f1", isFolder: true, url: "https://bookmark.phi/folder"))
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([remoteTombstone(tag: bookmarkTag("f1"), version: 7)])]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertFalse(access.rows.contains { $0.guid == "F1" })
        let lifts = access.lastAppliedOps.filter {
            if case .move = $0 { return true } else { return false }
        }
        XCTAssertTrue(lifts.isEmpty, "没有后代就没有提升")
    }

    /// CASE 6.10b-2 — 孤儿根下的行不进快照，但也**绝不被 tombstone**（R-exec-4）。
    ///
    /// 防的是什么：用快照当差分的第三条判据，`b9` 会被判成「本机没有这一行」而被 tombstone
    /// ——账户上那一条真实存在的书签就此删掉，而本机那一行还在原地。
    func testARowUnderAnOrphanRootIsNeverPublishedAndNeverTombstoned() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess()
        access.orphanedSyncIds = ["b9"]
        let store = MemoryOwnedItemStore()
        store.table.cursors["b9"] = publishedCursor(bookmarkPayload(uuid: "b9"))
        let client = FakePhiSyncClient()

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertTrue(bookmarkCommits(client).isEmpty,
                      "既不发 tombstone，也不当成一次更新发出去")
        let table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertNil(table.cursors["b9"]?.deletedAtMs)
        XCTAssertFalse(table.cursors["b9"]?.pendingDelete ?? true)
    }

    /// CASE 6.10c-2 — 一个 Space 正在导入，另一个照常落地。
    ///
    /// 防的是什么：不切开的话整批一个事务，`refuseIfImporting` 看到 `s-b` 上锁就拒掉整批，
    /// 于是 `s-a` 那两条也被回滚——它们没有任何理由等一次与自己无关的导入。③ 是判据：只断言
    /// ①② 的用例，对一个「重试时先落 a 再落 b」的实现也绿。
    func testAnImportingSpaceParksOnlyItsOwnEntities() async throws {
        let spaceAccess = makeSpaceAccess(["s-a": "su-a", "s-b": "su-b"])
        let access = FakeBookmarkAccess()
        access.importingSpaceIds = ["s-b"]
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        var entities: [PhiRemoteEntity] = []
        for (offset, identity) in ["a1", "a2"].enumerated() {
            entities.append(remoteEntity(envelope(bookmarkPayload(uuid: identity,
                                                                  spaceUuid: "su-a",
                                                                  rank: "V\(offset + 1)")),
                                         tag: bookmarkTag(identity), version: Int64(10 + offset),
                                         entityId: "srv-\(identity)", key: key))
        }
        for (offset, identity) in ["b1", "b2"].enumerated() {
            entities.append(remoteEntity(envelope(bookmarkPayload(uuid: identity,
                                                                  spaceUuid: "su-b",
                                                                  rank: "V\(offset + 1)")),
                                         tag: bookmarkTag(identity), version: Int64(20 + offset),
                                         entityId: "srv-\(identity)", key: key))
        }
        client.scriptedPages = [page(entities)]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        var table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertEqual(access.rows.filter { $0.spaceId == "s-a" }.count, 2, "① 没上锁的照常落地")
        XCTAssertNotNil(table.cursors["a1"]?.reconciled)
        XCTAssertTrue(access.rows.filter { $0.spaceId == "s-b" }.isEmpty, "② 上锁的没落地")
        XCTAssertNotNil(table.cursors["b1"]?.pendingApply)
        XCTAssertNil(table.cursors["b1"]?.reconciled)
        XCTAssertFalse(table.cursors["b1"]?.pendingTombstone ?? true)
        XCTAssertEqual(applyCallCount(access), 2, "③ 一个 Space 一次 apply，不是一次")
        // A6：停放**新建**出来的游标同样带服务端三元组。共享 marker 已经推过那一页，这一版
        // 实体永不重投——不在停放那一刻收割，下一轮落了地也补不上（`applyOwnedKind`）。
        XCTAssertEqual(table.cursors["b1"]?.entityId, "srv-b1")
        XCTAssertEqual(table.cursors["b1"]?.version, 20)

        access.importingSpaceIds = []
        await engine.pullOnce()
        table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertEqual(access.rows.filter { $0.spaceId == "s-b" }.count, 2, "④ 下一轮落地")
        XCTAssertNotNil(table.cursors["b1"]?.reconciled)
        XCTAssertEqual(table.cursors["b1"]?.entityId, "srv-b1",
                       "⑤ 停放落地之后身份还在：这一轮 `b1` 没有任何实体到达，三元组只能是"
                       + "停放那一轮留下的")
        XCTAssertEqual(table.cursors["b1"]?.version, 20)
    }

    /// CASE 6.10c-3 — 三种落地失败各走各的路，不共用一条笼统分支。
    ///
    /// 防的是什么：全按「停放」处理 ⇒ 算错的批次每轮原样重试，永远不会好；全按「拒收」处理
    /// ⇒ 正在导入的 Space 丢掉这一轮的全部落地。**两种错的正确反应方向相反。**
    func testTheThreeLandingFailuresTakeThreeDifferentPaths() async throws {
        func runRound(_ failure: Error?) async -> (PhiOwnedItemTable, OwnedRoundCounters?) {
            let spaceAccess = makeSpaceAccess()
            let access = FakeBookmarkAccess()
            access.applyErrorOnce = failure
            let store = MemoryOwnedItemStore()
            let client = FakePhiSyncClient()
            client.scriptedPages = [page([
                remoteEntity(envelope(bookmarkPayload(uuid: "b1")), tag: bookmarkTag("b1"),
                             version: 9, entityId: "srv-1", key: key),
            ])]
            let engine = makeEngine(client: client, access: spaceAccess,
                                    store: makeSpaceStore(),
                                    ownedKinds: [bookmarkKind(access, store)])
            await engine.setSpaceSyncEnabled(true)
            await engine.pullOnce()
            let table = await engine.ownedTableForTesting("bookmarks")
            let counters = await engine.lastOwnedRoundCountersForTesting["bookmarks"]
            return (table, counters)
        }

        // ① 导入锁：**停放**，不计 `refused`。
        let importing = await runRound(LocalStoreWriteError.spaceImporting(spaceId: "s-1"))
        XCTAssertNotNil(importing.0.cursors["b1"]?.pendingApply)
        XCTAssertEqual(importing.1?.refused, 0)

        // ② `.folderNotEmpty`：**拒收**，不进 `pendingApply`。
        let notEmpty = await runRound(LocalStoreWriteError.folderNotEmpty)
        XCTAssertNil(notEmpty.0.cursors["b1"]?.pendingApply)
        XCTAssertEqual(notEmpty.1?.refused, 1)

        // ③ `.rowAlreadyMapped`：同 ②。
        let mapped = await runRound(LocalStoreWriteError.rowAlreadyMapped)
        XCTAssertNil(mapped.0.cursors["b1"]?.pendingApply)
        XCTAssertEqual(mapped.1?.refused, 1)
    }

    /// CASE 6.10d — 本地读抛错 ⇒ 整轮跳过，**零 tombstone**（R-exec-3）。
    ///
    /// 防的是什么：把失败的读当成「零行」继续跑差分，是本里程碑里单次故障后果最重的一条
    /// 路径：差分的第三条判据是「本机找不到这条身份」，空数组让每一条已发布身份都命中它，
    /// 于是这一轮给账户上的全部书签各发一条 tombstone，而每台设备都会忠实执行。
    func testAFailedLocalReadSkipsTheWholeKindAndEmitsNoTombstone() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess()
        access.readError = LocalStoreWriteError.storeUnavailable
        let store = MemoryOwnedItemStore()
        for identity in ["b1", "b2", "b3"] {
            store.table.cursors[identity] = publishedCursor(bookmarkPayload(uuid: identity),
                                                            entityId: "srv-\(identity)")
        }
        let before = store.table
        let client = FakePhiSyncClient()

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertTrue(bookmarkCommits(client).isEmpty, "① 零 commit，特别是零 tombstone")
        XCTAssertEqual(store.table, before, "② 游标表与调用前逐字段相同")
        var counters = await engine.lastOwnedRoundCountersForTesting["bookmarks"]
        XCTAssertEqual(counters?.localReadFailed, 1)

        // ④ 读好了就一切照常：这一轮**读得到那三条行**，所以差分认得出它们还在，零 commit。
        // 没有这三条行，一个「恢复之后照样把已发布身份判成缺席」的实现会发三条 tombstone，
        // 而只断言 `localReadFailed == 0` 的用例对它全绿。
        access.readError = nil
        access.rows = [
            .fixture(guid: "Gb1", syncId: "b1", spaceId: "s-1", index: 0),
            .fixture(guid: "Gb2", syncId: "b2", spaceId: "s-1", index: 1),
            .fixture(guid: "Gb3", syncId: "b3", spaceId: "s-1", index: 2),
        ]
        await engine.pullOnce()
        counters = await engine.lastOwnedRoundCountersForTesting["bookmarks"]
        XCTAssertEqual(counters?.localReadFailed, 0)
        XCTAssertTrue(bookmarkCommits(client).filter(\.deleted).isEmpty,
                      "④ 恢复轮绝不为还在本机的身份发 tombstone")
    }

    /// CASE 6.11 — B8 逃生口：后代放弃之后祖先照常出门。
    ///
    /// 防的是什么：没有这条逃生口，一条被服务端永久拒绝的子 tombstone 会把它的整条祖先链
    /// 钉在「待删」状态上，而那些行在本机已经没了。
    func testAnAncestorTombstoneGoesOutOnceItsDescendantHasGivenUp() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess()
        let store = MemoryOwnedItemStore()
        store.table.cursors["parent"] = publishedCursor(
            bookmarkPayload(uuid: "parent", isFolder: true,
                            url: "https://bookmark.phi/folder"),
            entityId: "srv-parent", version: 4)
        var child = publishedCursor(bookmarkPayload(uuid: "child", parentUuid: "parent"),
                                    entityId: "srv-child", version: 5)
        child.deleteRejectRounds = 3
        store.table.cursors["child"] = child
        let client = FakePhiSyncClient()
        client.refuseCommitsForTagHashes = [bookmarkHash("child")]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let tombstones = Set(bookmarkCommits(client).filter(\.deleted).map(\.clientTagHash))
        XCTAssertTrue(tombstones.contains(bookmarkHash("parent")))
    }

    /// CASE 6.11b — 被拒的实体不长出游标（P5）。
    ///
    /// 防的是什么：`plan` 先收割 `entityId` / `version`、再判 `refuses`，所以被拒的实体照样在
    /// `harvest` 里留下记录，而它的身份没有对应游标。照着 harvest 建游标的实现，会让一个持续
    /// 发畸形载荷的对端每一轮把本机的游标表撑大一圈。
    func testRefusedEntitiesNeverGrowCursorsNoMatterHowManyRounds() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess()
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)

        for round in 0..<3 {
            client.scriptedPages = [page([
                // 非法 rank（以 '0' 结尾）。
                remoteEntity(envelope(bookmarkPayload(uuid: "b8", rank: "0")),
                             tag: bookmarkTag("b8"), version: Int64(10 + round),
                             entityId: "srv-b8", key: key),
                // 大写身份：一台设备把自己的本机 guid 发上线的形状。
                remoteEntity(envelope(bookmarkPayload(uuid: "B9")),
                             tag: bookmarkTag("B9"), version: Int64(20 + round),
                             entityId: "srv-b9", key: key),
            ])]
            await engine.pullOnce()
            let counters = await engine.lastOwnedRoundCountersForTesting["bookmarks"]
            XCTAssertEqual(counters?.refused, 2, "第 \(round) 轮")
            let table = await engine.ownedTableForTesting("bookmarks")
            XCTAssertTrue(table.cursors.isEmpty, "第 \(round) 轮之后游标表仍然是空的")
        }
    }

    // MARK: - CASE 6.12 – 6.19：门与基线顺序

    /// CASE 6.12 — 门关着：零发布。
    ///
    /// **与 case spec 的一处偏离**：spec 写的是「入站那条仍被处理（`pulled == 1`）」，而
    /// §5.1 / §5.4 把 `guard spaceLive else { continue }` 定成分发处**覆盖全部三个分支**的
    /// 一道门（`PhiSyncEngine.swift` 那句原样保留），归属 kind 与 Space 段共用它。门关着时
    /// 入站实体在分发处就被丢掉，补偿是开门边沿的整类型重放（CASE 6.13）。两句话不能同时
    /// 成立，这里按**实现规范**那一句断言。
    func testAShutGatePublishesNothing() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "G1", spaceId: "s-1"),
        ])
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([
            remoteEntity(envelope(bookmarkPayload(uuid: "b1")), tag: bookmarkTag("b1"),
                         version: 9, entityId: "srv-1", key: key),
        ])]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(false)
        await engine.pullOnce()

        XCTAssertEqual(bookmarkCommits(client).count, 0)
        let counters = await engine.lastOwnedRoundCountersForTesting["bookmarks"]
        XCTAssertEqual(counters?.pulled ?? 0, 0, "门关着时归属项与 Space 段一样在分发处就让开")
        XCTAssertNil(access.rows.first?.syncId, "门关着绝不铸身份")
    }

    /// CASE 6.13 — 门开边沿的整类型重放覆盖 Space 与每一条**已注册**的 kind。
    ///
    /// 防的是什么：断言两个计数之和大于零，光靠书签一个就能满足，而 Space 根本没被断言
    /// ——重放漏掉任一 kind 都会让那个 kind 停在门关之前的状态。
    func testTheGateOpenEdgeReplaysBothTheSpaceSectionAndEveryRegisteredKind() async throws {
        let spaceAccess = makeSpaceAccess()
        let spaceStore = makeSpaceStore()
        spaceStore.table.markerMovedWhileGateShut = true
        let access = FakeBookmarkAccess()
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        var remoteSpace = spacePayload(uuid: "su-9")
        remoteSpace.profileUuid = stamped("pu-1", at: 100)
        client.scriptedPages = [page([
            remoteEntity(envelope(remoteSpace), tag: PhiSyncEntity.spaceClientTag("su-9"),
                         version: 10, entityId: "srv-space", key: key),
            remoteEntity(envelope(bookmarkPayload(uuid: "b1")), tag: bookmarkTag("b1"),
                         version: 11, entityId: "srv-b1", key: key),
            remoteEntity(envelope(pinPayload(lineage: "lx")),
                         tag: PhiSyncEntity.pinClientTag("lx", ownerKey: "pu-1"),
                         version: 12, entityId: "srv-pin", key: key),
        ])]

        let engine = makeEngine(client: client, access: spaceAccess, store: spaceStore,
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        // 两个断言**分开写**。
        XCTAssertNotNil(spaceStore.table.cursors["su-9"], "Space 段处理了它那一条")
        let counters = await engine.lastOwnedRoundCountersForTesting["bookmarks"]
        XCTAssertGreaterThanOrEqual(counters?.pulled ?? 0, 1, "书签段处理了它那一条")
    }

    /// CASE 6.14 — guard ①：未 drain 完整重放时零 commit **且**零铸造。
    ///
    /// 防的是什么：只断言「零 commit」放得过「铸了 uuid 但没发」的实现，而那些 uuid 会在
    /// 下一轮被当作已发布的身份，从此再没人为它们发 create。
    func testAnInterruptedDrainCommitsNothingAndMintsNothing() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: (0..<3).map {
            .fixture(guid: "G\($0)", spaceId: "s-1", index: $0)
        })
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.getUpdatesErrorAfterPages = (pages: 1, error: PhiSyncProtocolError.http(500))
        client.pageBudgetExhaustsAfter = 4

        let engine = makeEngine(client: client, access: spaceAccess,
                                store: makeSpaceStore(drained: false),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertEqual(bookmarkCommits(client).count, 0)
        XCTAssertTrue(access.rows.allSatisfy { $0.syncId == nil },
                      "一个 uuid 都不许铸进本机行")
    }

    /// CASE 6.15 — apply 抛错 ⇒ 基线一个字节都不写。
    func testAThrownApplyWritesNoBaseline() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess()
        access.failApplyOnce = true
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([
            remoteEntity(envelope(bookmarkPayload(uuid: "b1")), tag: bookmarkTag("b1"),
                         version: 9, entityId: "srv-1", key: key),
        ])]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertNil(table.cursors["b1"]?.reconciled)
    }

    /// CASE 6.16 — 落地后复核：行没变 ⇒ 按停放处理，不写基线。
    ///
    /// 防的是什么：§4.5 要求「落地之后、写基线之前，按计划复核一次」；没有它，任何残留的
    /// 静默拒绝都会被记成一次成功落地。
    func testASilentlyEmptyLandingIsParkedRatherThanBaselined() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess()
        access.applyLandsNothingSilently = true
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([
            remoteEntity(envelope(bookmarkPayload(uuid: "b1")), tag: bookmarkTag("b1"),
                         version: 9, entityId: "srv-1", key: key),
        ])]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertNil(table.cursors["b1"]?.reconciled)
        let counters = await engine.lastOwnedRoundCountersForTesting["bookmarks"]
        XCTAssertEqual(counters?.applied, 0)
    }

    /// CASE 6.17 — 本机赢下一个字段之后必须重新发布，且 `server` 记的是**拉到的那一条**。
    ///
    /// 防的是什么：④ 是这条用例的承重半边。`server` 的语义是「服务端手上那一版是什么」；把
    /// 合并结果写进去，下一轮就会把一个服务端从没见过的字节当成服务端的现状，于是一次真实的
    /// 远端更新被判成「我早就知道了」而丢弃。只断言 commit 条数的用例对这个错误全绿。
    func testALocallyWonFieldIsRepublishedAndServerKeepsThePulledBytes() async throws {
        let spaceAccess = makeSpaceAccess(["s-1": "su-1", "s-2": "su-2"])
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "G1", syncId: "b1", spaceId: "s-1", title: "local",
                     contentUpdatedDate: Date(timeIntervalSince1970: 500)),
        ])
        let baseline = bookmarkPayload(uuid: "b1", spaceUuid: "su-1", title: "old",
                                       locationStamp: 100, contentStamp: 100)
        let inbound = bookmarkPayload(uuid: "b1", spaceUuid: "su-2", title: "old",
                                      locationStamp: 300, contentStamp: 100)
        let store = MemoryOwnedItemStore()
        store.table.cursors["b1"] = publishedCursor(baseline, entityId: "srv-b1", version: 7)
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([
            remoteEntity(envelope(inbound), tag: bookmarkTag("b1"), version: 42,
                         entityId: "srv-b1", key: key),
        ])]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let commits = bookmarkCommits(client)
        XCTAssertEqual(commits.count, 1, "①")
        XCTAssertEqual(commits.first?.baseVersion, 42, "②")
        let sent = commits.first.flatMap(committedBookmark)
        XCTAssertEqual(sent?.title.stringValue, "local", "③ 标题是本机的")
        XCTAssertEqual(sent?.spaceUuid.stringValue, "su-2", "③ 位置是远端的")
        let table = await engine.ownedTableForTesting("bookmarks")
        // ④ 提交被接受之后，服务端手上那一版**就是刚发出去的这一份**，所以两份基线都等于
        // 它（R-exec-7，与 Space 侧逐字同款）。只更新 `reconciled` 的实现会让 `server` 永远
        // 停在发布之前那一版，而它的用途正是「压掉一次多余的发布」。
        let sentBytes = sent.map(baselineBytes)
        XCTAssertNotNil(sentBytes)
        XCTAssertEqual(table.cursors["b1"]?.reconciled, sentBytes)
        XCTAssertEqual(table.cursors["b1"]?.server, sentBytes)
        XCTAssertNotEqual(table.cursors["b1"]?.server, baselineBytes(inbound),
                          "④ 落地写的那一份远端字节已经被这次被接受的提交盖过去了")
    }

    /// CASE 6.18 / 6.21 — `NOT_MY_BIRTHDAY` 的字段级后果。
    ///
    /// 防的是什么：账户没变，本机对「我上次与账户对齐到什么」的记忆仍然成立，变的只是服务端
    /// 那一侧的三元组。清表或删文件会毁掉每一份 `reconciled` 基线，而 §3.5 说那正是触发账户级
    /// 盲写覆盖的状态。
    func testNotMyBirthdayClearsOnlyTheServerSideTripleOfAnOwnedCursor() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess()
        let store = MemoryOwnedItemStore()
        var cursor = publishedCursor(bookmarkPayload(uuid: "b1"), entityId: "srv-b1", version: 9)
        cursor.deleteRejectRounds = 2
        cursor.deletedAtMs = 1_234
        store.table.cursors["b1"] = cursor
        let reconciled = cursor.reconciled
        let client = FakePhiSyncClient()
        client.throwNotMyBirthdayOnce = true

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let landed = store.table.cursors["b1"]
        XCTAssertEqual(landed?.entityId, "")
        XCTAssertEqual(landed?.version, 0)
        XCTAssertNil(landed?.server)
        XCTAssertEqual(landed?.deleteRejectRounds, 0)
        XCTAssertEqual(landed?.reconciled, reconciled, "`reconciled` 原样保留")
        XCTAssertEqual(landed?.ownerUuid, "su-1", "`ownerUuid` 原样保留")
        XCTAssertEqual(landed?.deletedAtMs, 1_234, "`deletedAtMs` 原样保留")
    }

    /// CASE 6.19 — 发布段写回例外 ②：加密失败 ⇒ `break` 而非 `return`，前面切片的 outcome
    /// 仍然保存。
    ///
    /// 防的是什么：丢掉这一条会把失败之前每一个已被接受的 outcome 扔掉，那些实体下一轮带着
    /// 过期基线重新发布。加密发生在**引擎**里，所以失败经 `StubDomainKeys.error` 注入，而不是
    /// 往假 client 上加一个开关——那是找错了接缝。
    func testAnEncryptionFailureKeepsTheOutcomesTheEarlierSlicesAlreadyProduced() async throws {
        let spaceAccess = makeSpaceAccess()
        // 60 条已有身份、还没有游标的行：一批 25，所以第一片是 b00…b24（切片按身份排序）。
        let access = FakeBookmarkAccess(rows: (0..<60).map {
            .fixture(guid: "G\($0)", syncId: String(format: "b%02d", $0), spaceId: "s-1",
                     index: $0)
        })
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        let arrived = Gate()
        let release = Gate()
        client.gatedCommitTagHash = bookmarkHash("b00")
        client.arrivedInCommit = arrived
        client.commitGate = release
        let domainKeys = StubDomainKeys(key: key)

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                domainKeys: domainKeys,
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        let round = Task { await engine.pullOnce() }
        await arrived.wait()
        domainKeys.error = LocalStoreWriteError.storeUnavailable
        await release.open()
        await round.value

        let table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertFalse(table.cursors["b00"]?.entityId.isEmpty ?? true,
                       "第一批那些身份的游标已经收下了 entityId / version")
        XCTAssertGreaterThan(table.cursors["b00"]?.version ?? 0, 0)
    }

    // MARK: - CASE 6.20 – 6.26：恢复路径

    /// CASE 6.20 — 不可读实体：隔离 + 游标不被覆盖 + 恢复后解除。
    ///
    /// 防的是什么：只测前半的用例放得过一个永远不清理的实现——一次短暂的密钥抖动会让这条
    /// 实体此后永久只读。
    ///
    /// **与 case spec 的一处机械调整**：spec 写的是 `client.forceInvalidMessage = true`，
    /// 但那个开关答的是 commit 的 outcome，造不出一条**读不出来的实体**；隔离区只由解密失败
    /// 填充，所以这里改用 `remoteUnreadable(tag:version:)` 注入，Expected 一字不改。
    func testAnUnreadableEntityIsQuarantinedAndReleasedOnceItBecomesReadable() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "G1", syncId: "b1", spaceId: "s-1"),
        ])
        let store = MemoryOwnedItemStore()
        store.table.cursors["b1"] = publishedCursor(bookmarkPayload(uuid: "b1"))
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([remoteUnreadable(tag: bookmarkTag("b1"), version: 5)])]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        var quarantined = await engine.spaceTableForTesting.unreadableTagHashes
        XCTAssertNotNil(quarantined[bookmarkHash("b1")])
        var table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertNotNil(table.cursors["b1"]?.reconciled, "游标不被覆盖")

        client.scriptedPages = [page([
            remoteEntity(envelope(bookmarkPayload(uuid: "b1", rank: "W")),
                         tag: bookmarkTag("b1"), version: 6, entityId: "srv-b1", key: key),
        ])]
        await engine.pullOnce()

        quarantined = await engine.spaceTableForTesting.unreadableTagHashes
        XCTAssertNil(quarantined[bookmarkHash("b1")], "读得出来之后隔离必须自己解除")
        table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertNotNil(table.cursors["b1"]?.reconciled)
    }

    /// CASE 6.22 — `.conflict` 只做限定范围重试。
    ///
    /// 防的是什么：完全忽略且不重试，同一条每轮重发、每轮再冲突，占着 250 条切片的一个名额
    /// **永不释放**。
    func testAConflictRetriesOnlyTheEntitiesThatConflicted() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: (0..<3).map {
            .fixture(guid: "G\($0)", syncId: "b\($0)", spaceId: "s-1", index: $0)
        })
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.conflictOnceForTagHashes = [bookmarkHash("b0"), bookmarkHash("b1")]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let commits = bookmarkCommits(client)
        XCTAssertEqual(commits.count, 5, "三条 + 限定重发的两条")
        XCTAssertEqual(Set(commits.suffix(2).map(\.clientTagHash)),
                       [bookmarkHash("b0"), bookmarkHash("b1")],
                       "重试只覆盖那两条，不是整轮重来")
    }

    /// CASE 6.23 — 报损之后的整类型重放，外加 `MemoryOwnedItemStore` 自己的语义。
    ///
    /// 防的是什么：③ 是最贵的那条——重放时把每条实体当新的建一遍，会让本机每一条书签变成
    /// 两条，而两条都带身份、都不会被差分判成删除。
    func testALostCursorFileReplaysTheWholeTypeWithoutRecreatingAnyRow() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "G1", syncId: "b1", spaceId: "s-1"),
        ])
        let spaceStore = makeSpaceStore()
        spaceStore.table.bookmarksHadRecords = true
        let store = MemoryOwnedItemStore()
        store.table.cursors["b1"] = publishedCursor(bookmarkPayload(uuid: "b1"))
        store.forcedLoss = true
        let client = FakePhiSyncClient()
        client.seed(tagHash: bookmarkHash("b1"),
                    ciphertext: try PhiEntityCodec.encrypt(
                        envelope(bookmarkPayload(uuid: "b1")), key: key),
                    version: 20, entityId: "srv-b1")

        let engine = makeEngine(client: client, access: spaceAccess, store: spaceStore,
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        // ① 触发整类型重放；② 重放期间零 commit。
        XCTAssertFalse(spaceStore.table.hasDrainedFullReplay)
        XCTAssertEqual(bookmarkCommits(client).count, 0)
        // ⑤ 替身自身的语义：它确实看见了引擎喂进来的那个布尔，且报损那次交出的是空表。
        XCTAssertEqual(store.hadRecordsSeen.first, true)
        XCTAssertTrue(store.load(hadRecords: true).table.cursors.isEmpty)
        XCTAssertTrue(store.load(hadRecords: true).reportedLoss)

        store.forcedLoss = false
        await engine.pullOnce()

        // ③ 重放把游标按身份重建，`.create` 一次都没有——那些行本机已经有了。
        let creates = access.lastAppliedOps.filter {
            if case .create = $0 { return true } else { return false }
        }.count
        XCTAssertEqual(creates, 0)
        XCTAssertEqual(access.rows.count, 1, "一条行绝不变成两条")

    }

    /// CASE 6.23 assertion 4 — 反向那一半：`…HadRecords == false` 时同样丢文件 ⇒ **不重放**。
    ///
    /// 断言的是**引擎**：`getUpdatesCalls` 里不许多出一条 `marker == nil` 的记录。断言替身自己
    /// 的 `reportedLoss` 语义（那是 assertion 5 的事）对一个照样重放的引擎恒绿。
    func testALostCursorFileWithNoPriorRecordDoesNotReplay() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess()          // 一条本机行都没有 ⇒ 永远写不出已发布游标
        let spaceStore = makeSpaceStore()
        XCTAssertFalse(spaceStore.table.bookmarksHadRecords, "前提：这台机器没为书签发布过")
        let store = MemoryOwnedItemStore()
        store.forcedLoss = true
        let client = FakePhiSyncClient()
        // 空页，但带一个真的 marker，所以「这一轮从头拉」在 `getUpdatesCalls` 上看得出来。
        client.scriptedPages = [page([], marker: "m1"), page([], marker: "m2")]

        let engine = makeEngine(client: client, access: spaceAccess, store: spaceStore,
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()
        await engine.pullOnce()

        XCTAssertEqual(client.getUpdatesCalls.filter { $0.marker == nil }.count, 1,
                       "没有 `…HadRecords` 就没有丢失，第二轮不许从头拉")
        XCTAssertTrue(spaceStore.table.hasDrainedFullReplay)
    }

    /// CASE 6.24 / 6.25 — per-kind 闸独立于 Space 的永久闩，而且**可以重新武装**。
    ///
    /// 防的是什么：只断言「某个书签标志是 false」的用例，放得过一个共享 Space 闩、却另外
    /// 暴露一个书签标志的实现。可重新武装是 per-kind 闸与 Space 那个永久闩**唯一**的行为
    /// 差别（A2），丢了这条它就只是一句注释。
    func testThePerKindReplayGateIsIndependentOfTheSpaceLatchAndCanRearm() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "G1", syncId: "b1", spaceId: "s-1"),
        ])
        let spaceStore = makeSpaceStore()
        // Space 那个永久闩已经花掉了。
        spaceStore.table.hadRecords = true
        spaceStore.table.didReplayForEmptyTable = true
        spaceStore.table.bookmarksHadRecords = true
        let store = MemoryOwnedItemStore()
        store.table.cursors["b1"] = publishedCursor(bookmarkPayload(uuid: "b1"))
        let client = FakePhiSyncClient()
        client.seed(tagHash: bookmarkHash("b1"),
                    ciphertext: try PhiEntityCodec.encrypt(
                        envelope(bookmarkPayload(uuid: "b1")), key: key),
                    version: 20, entityId: "srv-b1")

        func markerNilCalls() -> Int { client.getUpdatesCalls.filter { $0.marker == nil }.count }

        let engine = makeEngine(client: client, access: spaceAccess, store: spaceStore,
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()               // 建立一个 marker
        let baselineCalls = markerNilCalls()

        // CASE 6.24：书签侧丢文件 ⇒ 书签侧**真的重放了**，Space 的永久闩挡不住它。
        store.forcedLoss = true
        await engine.pullOnce()               // 发布段的 load 报损 ⇒ 丢 marker
        store.forcedLoss = false
        await engine.pullOnce()               // 这一轮从头拉
        XCTAssertGreaterThan(markerNilCalls(), baselineCalls,
                             "`getUpdatesCalls` 里出现一条新的 marker == nil")
        let afterFirstLoss = markerNilCalls()

        // CASE 6.25：表重新拿到已发布游标之后再丢一次，闸重新武装。
        store.forcedLoss = true
        await engine.pullOnce()
        store.forcedLoss = false
        await engine.pullOnce()
        XCTAssertGreaterThan(markerNilCalls(), afterFirstLoss,
                             "per-kind 闸可以重新武装，再多一条 marker == nil")
    }

    // MARK: - 复审轮补上的用例

    /// T6-C3 — 铸出来的身份写不回本机行时，**游标留着**，而且只有落地成功的 Space 前进。
    ///
    /// 防的是什么：撤掉游标是最贵的那条路。服务端**已经接受**了那些实体，所以账户上它们真实
    /// 存在；游标一删，这台机器对它们再无任何记录，而本机那些行的 `syncId` 仍然是 nil——下一轮
    /// 它们重铸一批新身份、再建一批新实体，第一批就此变成没有任何设备持有游标的幽灵，§4.7 的
    /// 差分永远产不出它们的 tombstone，每一个对端都把它们物化成重复书签。写回批次不按 Space
    /// 切开还会让一个正在导入的 Space 把另一个 Space 的写回一起拒掉。
    func testAFailedIdentityWriteBackKeepsTheCursorAndMintsNothingNextRound() async throws {
        let spaceAccess = makeSpaceAccess(["s-a": "su-a", "s-b": "su-b"])
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "GA", spaceId: "s-a", index: 0, title: "A",
                     url: URL(string: "https://a.example")!),
            .fixture(guid: "GB", spaceId: "s-b", index: 0, title: "B",
                     url: URL(string: "https://b.example")!),
        ])
        access.importingSpaceIds = ["s-b"]
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        // 两条都被账户接受了。
        XCTAssertEqual(bookmarkCommits(client).count, 2)
        let table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertEqual(table.cursors.count, 2, "被接受的身份一条游标都不许撤掉")
        // 没上锁的那个 Space：身份真的写回了本机行。
        XCTAssertNotNil(access.rows.first { $0.guid == "GA" }?.syncId)
        // 上锁的那个：写不回去，但游标停放着那份载荷，等下一轮认领。
        XCTAssertNil(access.rows.first { $0.guid == "GB" }?.syncId)
        let parked = table.cursors.values.filter { $0.pendingApply != nil }
        XCTAssertEqual(parked.count, 1)

        // 下一轮：那条行仍然没有 `syncId`，但**不许再铸一个新身份**——账户上已经有它那一条。
        let before = bookmarkCommits(client).count
        await engine.pullOnce()
        let after = await engine.ownedTableForTesting("bookmarks")
        XCTAssertEqual(after.cursors.count, 2, "下一轮不许为同一条本机行铸第二个身份")
        XCTAssertEqual(bookmarkCommits(client).count - before, 0,
                       "也不许把第二个身份发上账户")
    }

    /// T6-N3 的脚手架：一条**停放着、等认领**的游标，加上那条还没被认领的本机行。
    ///
    /// 直接预置游标而不是跑一整轮，是因为这两条用例要断言的是**纯 push 轮**的行为，而跑轮 1
    /// 就得先跑一次 pull。`phi.sync.entityId` 预置成非空让 `pushSettings` 在它自己那道
    /// 「服务端有一份我读不出来的基线」守卫上提前返回：于是这一轮既不发设置提交、也不触发
    /// 它的首次 pull，是一次真正没有落地段的轮次。
    private func parkedClaimFixture(url: URL = URL(string: "https://b.example")!)
        -> (access: FakeBookmarkAccess, store: MemoryOwnedItemStore,
            spaceStore: MemorySpaceStore, spaceAccess: FakePhiSpaceAccess) {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "GB", spaceId: "s-1", title: "B", url: url),
        ])
        let store = MemoryOwnedItemStore()
        // 停放的字节必须与本机行的投影逐字节一致（真实轮次里它们就来自同一行）：行夹具的
        // `createdDate` 默认是 1_000 s，投影成 1_000_000 ms，载荷也要用这个值，否则认领
        // 写回后那一行进快照就会多发一条毫无意义的 update（T6-N6）。
        var cursor = publishedCursor(bookmarkPayload(uuid: "bpark", title: "B",
                                                     url: "https://b.example",
                                                     createdAtMs: 1_000_000),
                                     entityId: "srv-bpark", version: 7)
        cursor.pendingApply = cursor.reconciled
        store.table.cursors["bpark"] = cursor
        defaults.set("srv-settings", forKey: PhiSyncEngine.entityIdStateKey)
        return (access, store, makeSpaceStore(), spaceAccess)
    }

    /// T6-N3 — 一次**纯 push 轮**也要先重试停放项（R-exec-10）。
    ///
    /// 防的是什么：豁免与「本轮不铸新身份」都从本轮的认领配对表算出来，而那张表过去只有落地段
    /// 会写。用户在重试窗口里改一次设置，去抖动的观察者就会跑一次没有落地段的轮次：那一轮
    /// 把还没认领的本机行又铸一个身份发上账户，同时把原来那条身份 tombstone 掉——对端看到的
    /// 是一次删除加一次毫无关系的新建，而任何对端在这期间对原实体做的编辑就此丢失。
    func testAPushOnlyRoundRetriesTheParkedClaimInsteadOfDeletingTheEntity() async throws {
        let fixture = parkedClaimFixture()
        let client = FakePhiSyncClient()
        let engine = makeEngine(client: client, access: fixture.spaceAccess,
                                store: fixture.spaceStore,
                                ownedKinds: [bookmarkKind(fixture.access, fixture.store)])
        await engine.setSpaceSyncEnabled(true)

        await engine.pushLocalSettings()

        XCTAssertTrue(bookmarkCommits(client).isEmpty,
                      "既不为那条身份发 tombstone，也不为那条行铸第二个身份")
        XCTAssertEqual(fixture.access.rows.first { $0.guid == "GB" }?.syncId, "bpark",
                       "导入锁已经不在了，这一轮就该把身份写回本机行")
        let table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertNil(table.cursors["bpark"]?.pendingApply, "写回成功之后解除停放")
        XCTAssertNil(table.cursors["bpark"]?.deletedAtMs)
    }

    /// T6-N3 的另一半：认领**配不上**时，纯 push 轮的结论与 pull 轮逐字相同——tombstone
    /// 那条身份，并为那条本机行铸一个新的。
    func testAPushOnlyRoundStillTombstonesAnUnclaimableParkedIdentity() async throws {
        let fixture = parkedClaimFixture(url: URL(string: "https://b-edited.example")!)
        let client = FakePhiSyncClient()
        // 账户上那条实体真的在，否则假服务端会用 INVALID_MESSAGE 掀掉整批，后面那条铸造
        // 提交就不会被记下来。
        client.seed(tagHash: bookmarkHash("bpark"), ciphertext: Data(), version: 7,
                    entityId: "srv-bpark")
        let engine = makeEngine(client: client, access: fixture.spaceAccess,
                                store: fixture.spaceStore,
                                ownedKinds: [bookmarkKind(fixture.access, fixture.store)])
        await engine.setSpaceSyncEnabled(true)

        await engine.pushLocalSettings()

        let commits = bookmarkCommits(client)
        XCTAssertEqual(commits.filter(\.deleted).map(\.clientTagHash), [bookmarkHash("bpark")],
                       "配不上的那条身份照样被清理掉")
        XCTAssertEqual(commits.filter { !$0.deleted }.count, 1,
                       "那条本机行铸一个新身份，正好一条")
        XCTAssertNotEqual(fixture.access.rows.first { $0.guid == "GB" }?.syncId, "bpark")
    }

    /// T6-N4 — 一条被导入锁挡下的**真正入站实体**，认领之后那份合并结果必须还在。
    ///
    /// 防的是什么：`.claim` 只写身份、不写任何字段。认领成功就解除停放，等于把 `adopt` 算出
    /// 来的那份字段级合并结果扔掉，而那条实体永远不会再来一次——共享 marker 早已推过那一页。
    /// 下一轮的快照于是拿本机那一行的全部字段盖掉账户上那一条，远端的位置就此丢失，正是
    /// §6.2 点名禁止的「整体采纳本机」。
    func testAParkedInboundEntityKeepsItsPayloadUntilTheMergeActuallyLands() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "GX", spaceId: "s-1", title: "local",
                     url: URL(string: "https://x.example")!),
        ])
        let store = MemoryOwnedItemStore()
        // §5.6 T4 的形状：载荷停着，**从没落过地**，所以 `reconciled` 还是 nil。
        var cursor = ownedCursor(entityId: "srv-x1", version: 5, ownerUuid: "su-1")
        cursor.pendingApply = baselineBytes(bookmarkPayload(uuid: "x1", title: "remote",
                                                            url: "https://x.example",
                                                            contentStamp: 9_000))
        store.table.cursors["x1"] = cursor
        defaults.set("srv-settings", forKey: PhiSyncEngine.entityIdStateKey)
        let client = FakePhiSyncClient()

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)

        // 纯 push 轮：导入锁已经不在，认领写得下去。
        await engine.pushLocalSettings()

        XCTAssertEqual(access.rows.first { $0.guid == "GX" }?.syncId, "x1", "身份写回去了")
        var table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertNotNil(table.cursors["x1"]?.pendingApply,
                        "合并结果还没落地，载荷一个字节都不许丢")
        XCTAssertTrue(bookmarkCommits(client).isEmpty,
                      "停放中的游标不进快照，所以这一轮什么都不该被发布到它上面")
        XCTAssertEqual(access.rows.first { $0.guid == "GX" }?.title, "local",
                       "认领不是一次编辑")

        // 下一轮的落地段把那份合并结果真的放下去。
        await engine.pullOnce()

        XCTAssertEqual(access.rows.first { $0.guid == "GX" }?.title, "remote",
                       "远端赢下的字段最终要到达本机行")
        table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertNil(table.cursors["x1"]?.pendingApply, "落地之后才解除停放")
        XCTAssertNotNil(table.cursors["x1"]?.reconciled)
    }

    /// T6-N5 — 轮首重试写下的那个身份，同一轮的落地段必须看得见。
    ///
    /// 防的是什么：`adopt` 的本机侧筛的是 `syncId == nil`，读的是轮首那份快照。中途写下的身份
    /// 不折回去，落地段就会把**第二个**身份配给同一条行，`applyBookmarkSyncBatchThrowing` 用
    /// `rowAlreadyMapped` 拒掉那个 Space 的**整批**——拒收而不是停放，于是那些入站实体既没有
    /// 游标也永远不会重投。假件把 `.claim` 模成一次普通赋值、从不抛 `rowAlreadyMapped`，所以
    /// 这条用例断言的是它的前一步：第二条身份绝不该配到那一行上。
    func testAMidRoundClaimIsVisibleToTheSameRoundsAdoption() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "GB", spaceId: "s-1", title: "B",
                     url: URL(string: "https://b.example")!),
        ])
        let store = MemoryOwnedItemStore()
        // 写回重试的形状：载荷就是 `reconciled` 的一份拷贝。
        let landed = bookmarkPayload(uuid: "e1", title: "B", url: "https://b.example")
        var cursor = publishedCursor(landed, entityId: "srv-e1", version: 4)
        cursor.pendingApply = cursor.reconciled
        store.table.cursors["e1"] = cursor
        let client = FakePhiSyncClient()
        // 同一个父下、URL 完全相同的第二条账户实体——没有那次折回，它会被配到 `GB` 上。
        client.scriptedPages = [page([
            remoteEntity(envelope(bookmarkPayload(uuid: "e2", rank: "W", title: "B",
                                                  url: "https://b.example")),
                         tag: bookmarkTag("e2"), version: 30, entityId: "srv-e2", key: key),
        ])]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertEqual(access.rows.first { $0.guid == "GB" }?.syncId, "e1",
                       "那一行已经认领过了，第二个身份绝不许再配给它")
        XCTAssertEqual(access.rows.count, 2, "第二条实体照常建一条新行")
        XCTAssertEqual(access.rows.first { $0.guid != "GB" }?.syncId, "e2")
    }

    /// T6-N1 的轮 1：两个 Space、其中一个正在导入，于是被锁那一条的身份写不回本机行。
    /// 返回那条**留在游标表里、本机行却没有认领**的身份。
    private func runFailedWriteBackRound()
        async -> (engine: PhiSyncEngine, client: FakePhiSyncClient,
                  access: FakeBookmarkAccess, store: MemoryOwnedItemStore, orphan: String) {
        let spaceAccess = makeSpaceAccess(["s-a": "su-a", "s-b": "su-b"])
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "GA", spaceId: "s-a", index: 0, title: "A",
                     url: URL(string: "https://a.example")!),
            .fixture(guid: "GB", spaceId: "s-b", index: 0, title: "B",
                     url: URL(string: "https://b.example")!),
        ])
        access.importingSpaceIds = ["s-b"]
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let table = await engine.ownedTableForTesting("bookmarks")
        let claimed = access.rows.first { $0.guid == "GA" }?.syncId
        let orphan = table.cursors.keys.first { $0 != claimed } ?? ""
        return (engine, client, access, store, orphan)
    }

    /// T6-N1 — 写不回去的那条游标必须带着归属，否则「下一轮差分把它删掉」这条后路走不通。
    ///
    /// 防的是什么：`SyncableOwnedItems.tombstones` 在 `ownerUuid == nil` 上保守地放弃，而发布段
    /// 那次归属刷新跑在提交循环**之前**、只碰已经存在的游标。所以一条为铸出来的身份新建的游标
    /// 若不在 `.applied` 那一刻就钉上归属，它此后永远 `ownerUuid == nil`——账户上那条实体既没有
    /// 本地行认领它，也**永远发不出它的 tombstone**，每个对端都把它物化成一条谁都删不掉的
    /// 重复书签。用户在重试窗口里改一次那条书签的 URL 就够了：认领从此配不上它。
    func testAnUnclaimedMintedIdentityCarriesItsOwnerAndIsEventuallyTombstoned() async throws {
        let round1 = await runFailedWriteBackRound()
        let engine = round1.engine
        var table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertFalse(round1.orphan.isEmpty)
        XCTAssertEqual(table.cursors[round1.orphan]?.ownerUuid, "su-b",
                       "铸出来的身份在提交被接受的那一刻就要钉上归属")
        XCTAssertNotNil(table.cursors[round1.orphan]?.pendingApply)

        // 用户在重试窗口里改了那条书签的 URL ⇒ §6 的按位配对再也认不出它。
        if let index = round1.access.rows.firstIndex(where: { $0.guid == "GB" }) {
            round1.access.rows[index].url = URL(string: "https://b-edited.example")!
        }
        round1.access.importingSpaceIds = []
        await engine.pullOnce()

        table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertEqual(table.cursors[round1.orphan]?.ownerUuid, "su-b", "归属不许被刷成 nil")
        let tombstoned = Set(bookmarkCommits(round1.client).filter(\.deleted)
            .map(\.clientTagHash))
        XCTAssertTrue(tombstoned.contains(bookmarkHash(round1.orphan)),
                      "认领不上的那条身份要被差分清理掉，不许变成永久孤儿")
    }

    /// T6-N1 的另一半：用户干脆把那条本机行删了。账户上那条实体同样必须能被清理掉。
    func testAnUnclaimedMintedIdentityIsTombstonedWhenItsRowIsDeletedLocally() async throws {
        let round1 = await runFailedWriteBackRound()
        round1.access.rows.removeAll { $0.guid == "GB" }
        round1.access.importingSpaceIds = []
        await round1.engine.pullOnce()

        let tombstoned = Set(bookmarkCommits(round1.client).filter(\.deleted)
            .map(\.clientTagHash))
        XCTAssertTrue(tombstoned.contains(bookmarkHash(round1.orphan)))
    }

    /// T6-I1 / §5.6 T3 — 反查到身份、本机没有行的 tombstone 照样把游标定案。
    ///
    /// 防的是什么：不写 `deletedAtMs`，那条游标永远停在「活着」的状态，§3.6 那个按
    /// `deletedAtMs` 扫描的 30 天丢弃永远收不走它；而同一轮的差分还会为一条账户已经删掉的
    /// 实体再发一条多余的 tombstone。
    func testARemoteTombstoneWithNoLocalRowStillStampsTheCursor() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess()            // 本机没有这一行
        let store = MemoryOwnedItemStore()
        store.table.cursors["b1"] = publishedCursor(bookmarkPayload(uuid: "b1"),
                                                    entityId: "srv-b1", version: 3)
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([remoteTombstone(tag: bookmarkTag("b1"), version: 8)])]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertNotNil(table.cursors["b1"]?.deletedAtMs, "T3 照样定案")
        XCTAssertNil(table.cursors["b1"]?.reconciled)
        XCTAssertTrue(bookmarkCommits(client).filter(\.deleted).isEmpty,
                      "远端已经删掉的实体不该再收到本机的一条 tombstone")
        // CASE 6b.3 的另一半：什么都不删，所以落地段连一次事务都不该开。
        XCTAssertEqual(applyCallCount(access), 0, "本机没有这条行 ⇒ 一次 `apply` 都不发生")
    }

    /// T6-I2 — 一次认领与一次移动共用同一个父时，兄弟们的 index 不许撞上。
    ///
    /// 防的是什么：`.claim` 只写 `syncId`、`.update` 只写字段，两者都不带 index，而批次入口
    /// 写的是**裸 index**——它不会替你把兄弟们往后挪。把它们算成「已经带着最终 index 出门」，
    /// 被认领的那一条会留着旧 index 与某个被重新编号的兄弟撞上，那个文件夹的顺序此后随 fetch
    /// 而变（正是 CASE 2a.22 给 `children(of:)` 加次键要防的形状）。
    func testAClaimAndAMoveUnderTheSameParentNeverCollideOnAnIndex() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "F1", syncId: "f1", spaceId: "s-1", index: 0, isFolder: true,
                     url: URL(string: "https://bookmark.phi/folder")!),
            // 待认领：没有身份，内容与入站的 `x1` 逐字相同。
            .fixture(guid: "GX", spaceId: "s-1", parentGuid: "F1", index: 0,
                     title: "X", url: URL(string: "https://x.example")!),
            // 已有身份，本轮被移动。
            .fixture(guid: "GY", syncId: "y1", spaceId: "s-1", parentGuid: "F1", index: 1,
                     title: "Y", url: URL(string: "https://y.example")!),
        ])
        let store = MemoryOwnedItemStore()
        store.table.cursors["f1"] = publishedCursor(
            bookmarkPayload(uuid: "f1", isFolder: true, url: "https://bookmark.phi/folder"))
        store.table.cursors["y1"] = publishedCursor(
            bookmarkPayload(uuid: "y1", parentUuid: "f1", rank: "W", title: "Y",
                            url: "https://y.example"))
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([
            // 认领 `GX`：同一个父下、URL 完全相同的一条远端实体。
            // `x1` 的 rank 排在 `y1` 后面，所以被认领的那一条**必须移动**：认领只写
            // `syncId`，不带 index，漏掉置换它就留在 index 0 上与 `y1` 撞上。
            remoteEntity(envelope(bookmarkPayload(uuid: "x1", parentUuid: "f1", rank: "Z",
                                                  title: "X", url: "https://x.example")),
                         tag: bookmarkTag("x1"), version: 30, entityId: "srv-x1", key: key),
            // `y1` 换了 rank，于是它是一次真正的移动，并且排到了前面。
            remoteEntity(envelope(bookmarkPayload(uuid: "y1", parentUuid: "f1", rank: "V",
                                                  title: "Y", url: "https://y.example",
                                                  rankStamp: 500)),
                         tag: bookmarkTag("y1"), version: 31, entityId: "srv-y1", key: key),
        ])]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let siblings = access.rows.filter { $0.parentGuid == "F1" }
        XCTAssertEqual(siblings.count, 2)
        XCTAssertEqual(Set(siblings.map(\.index)).count, 2,
                       "同一个父下的两条行不许共用一个 index")
    }

    /// T6-I3 — 一个**每次都读不出来**的游标文件至多换来一次重放。
    ///
    /// 防的是什么：把「闸的复位」挂在一次成功的 save 上，等于拿引擎自己刚在内存里建出来的
    /// 那张表当「文件恢复了」的证据。于是权限错误或永远解析失败的 JSON 会在「报损 → 重放 →
    /// 重建游标 → 清闸 → 再报损」之间无限循环，此后每一轮都是一次整个 data type 的重放。
    func testAPermanentlyUnreadableCursorFileReplaysAtMostOnce() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "G1", syncId: "b1", spaceId: "s-1"),
        ])
        let spaceStore = makeSpaceStore()
        spaceStore.table.bookmarksHadRecords = true
        let store = MemoryOwnedItemStore()
        store.forcedLoss = true                       // 这个文件永远读不出来
        let client = FakePhiSyncClient()
        client.seed(tagHash: bookmarkHash("b1"),
                    ciphertext: try PhiEntityCodec.encrypt(
                        envelope(bookmarkPayload(uuid: "b1")), key: key),
                    version: 20, entityId: "srv-b1")

        let engine = makeEngine(client: client, access: spaceAccess, store: spaceStore,
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        for _ in 0..<4 { await engine.pullOnce() }

        XCTAssertLessThanOrEqual(client.getUpdatesCalls.filter { $0.marker == nil }.count, 2,
                                 "第一轮本来就是 marker == nil，报损只许再换来一次重放")
    }

    /// T6-I5 / §4.2 规则 3b — 一条带 `deletedAtMs`、本机行还活着的游标要复活发布。
    ///
    /// 防的是什么：不复活，那条书签只活在这一台机器上；复活时不清 `deletedAtMs`，每一轮都会
    /// 再复活发布一次，每轮换来一次 `.conflict` 加一次限定重发。
    func testACursorWithADeletedStampRepublishesTheLiveRowAndClearsTheStamp() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "G1", syncId: "lx", spaceId: "s-1", title: "back"),
        ])
        let store = MemoryOwnedItemStore()
        var cursor = publishedCursor(bookmarkPayload(uuid: "lx"), entityId: "e-lx", version: 42)
        cursor.reconciled = nil          // tombstone 收尾清掉了两份基线
        cursor.server = nil
        cursor.deletedAtMs = 1_000
        store.table.cursors["lx"] = cursor
        let client = FakePhiSyncClient()
        // 账户上那一行是 tombstone，`e-lx` / 42 就是复活提交要用的三元组。空脚本页让这一轮
        // 的拉取不去重投它——重投会让它作为一条入站 tombstone 把本机那条活行删掉，而这条
        // 用例要的是**本机行还活着**的那一半。
        client.seed(tagHash: bookmarkHash("lx"), ciphertext: Data(), version: 42,
                    entityId: "e-lx", deleted: true)
        client.scriptedPages = [page([], marker: "m1")]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let live = bookmarkCommits(client).filter { !$0.deleted }
        XCTAssertEqual(live.count, 1)
        XCTAssertEqual(live.first?.entityId, "e-lx", "复活用的是保留下来的那个 entityId")
        XCTAssertEqual(live.first?.baseVersion, 42)
        let table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertNil(table.cursors["lx"]?.deletedAtMs, "落地之后清 `deletedAtMs`")
        let counters = await engine.lastOwnedRoundCountersForTesting["bookmarks"]
        XCTAssertEqual(counters?.resurrected, 1)
    }

    /// CASE 6.26 — 报损只在发布段的 `load()` 被观察到 ⇒ 该轮发布就地中止。
    ///
    /// 防的是什么：断言的是 `hasDrainedFullReplay` 这个**既有**字段——M2 裁定「不要第二个
    /// `publishBlocked` 标志」，这条用例就是那条裁定的探针。
    func testALossSeenOnlyByThePublishLoadAbortsThatRoundsPublishInPlace() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "G1", spaceId: "s-1"),        // 未同步：一条本该被发布的行
        ])
        let spaceStore = makeSpaceStore()
        spaceStore.table.bookmarksHadRecords = true
        let store = MemoryOwnedItemStore()
        store.table.cursors["seed"] = publishedCursor(bookmarkPayload(uuid: "seed"))
        store.loseOnLoadNumber = 2          // apply 段读到旧表，发布段那次才报损
        let client = FakePhiSyncClient()

        let engine = makeEngine(client: client, access: spaceAccess, store: spaceStore,
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertEqual(bookmarkCommits(client).count, 0)
        XCTAssertFalse(spaceStore.table.hasDrainedFullReplay)
    }

    // MARK: - CASE 5b.1 – 5b.6：pin 注册进引擎

    /// CASE 5b.1 — 注册之后引擎真的驱动 pin 段。
    ///
    /// 防的是什么：没有注册的话 pin 段连 `load()` 都没有对象可调，而 Task 9b 的级联会写进
    /// 一张谁也不会保存的表。
    func testRegisteringThePinKindMakesTheEngineDriveThePinSection() async throws {
        let pinAccess = FakePinAccess(scope: .profile, account: .profile, rows: [.fixture()])
        let pinStore = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()

        let engine = makeEngine(client: client, ownedKinds: [pinKind(pinAccess, pinStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let seen = pinStore.hadRecordsSeen
        let counters = await engine.lastOwnedRoundCountersForTesting["pins"]
        XCTAssertFalse(seen.isEmpty, "pin 段至少读过一次它自己的表")
        XCTAssertNotNil(counters, "计数行里出现 PinKind 那一行")
    }

    /// CASE 5b.2 — 两条 kind 同时注册时互不干扰。
    ///
    /// 防的是什么：把注册清单实现成「最后一条覆盖前一条」或让两条 kind 共用一张表，都会在
    /// 这条用例上红，而线上表现是其中一种实体整类消失。
    func testTwoRegisteredKindsKeepTheirOwnTablesCountersAndTagIndices() async throws {
        let spaceAccess = makeSpaceAccess()
        let bookmarkAccess = FakeBookmarkAccess()
        let bookmarkStore = MemoryOwnedItemStore()
        let pinAccess = FakePinAccess(scope: .profile, account: .profile)
        let pinStore = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([
            remoteEntity(envelope(bookmarkPayload(uuid: "b1")), tag: bookmarkTag("b1"),
                         version: 11, entityId: "srv-b1", key: key),
            remoteEntity(envelope(pinPayload(lineage: "lx")), tag: pinTag("lx"),
                         version: 12, entityId: "srv-p1", key: key),
        ])]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(bookmarkAccess, bookmarkStore),
                                             pinKind(pinAccess, pinStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let bookmarkTable = await engine.ownedTableForTesting("bookmarks")
        let pinTable = await engine.ownedTableForTesting("pins")
        let bookmarkCounters = await engine.lastOwnedRoundCountersForTesting["bookmarks"]
        let pinCounters = await engine.lastOwnedRoundCountersForTesting["pins"]
        XCTAssertEqual(Set(bookmarkTable.cursors.keys), ["b1"], "书签表只长书签那一条")
        XCTAssertEqual(Set(pinTable.cursors.keys), ["lx:pu-1"], "pin 表只长 pin 那一条")
        XCTAssertEqual(bookmarkCounters?.pulled, 1)
        XCTAssertEqual(pinCounters?.pulled, 1)
    }

    /// CASE 5b.3（承接 CASE 6.4 / 6.5）— pin 的 tag 校验顺带钉住 owner。
    ///
    /// 防的是什么：owner 是 pin 身份的一半（R-M3-3-15），所以 owner 与 tag 不符**就是身份
    /// 不符**。这样一条实体是伪造载荷或对端 bug，**不是**一次合法的换绑——换绑在线上的形状
    /// 是「旧 tag 一条 tombstone + 新 tag 一条 create」。
    func testAPinPayloadWhoseOwnerDoesNotMatchItsTagIsQuarantined() async throws {
        let spaceAccess = makeSpaceAccess()
        let pinAccess = FakePinAccess(scope: .profile, account: .profile,
                                      rows: [.fixture(lineageId: "LX", guid: "p1")])
        let pinStore = MemoryOwnedItemStore()
        pinStore.table.cursors["lx:pu-1"] = publishedPinCursor(pinPayload(lineage: "lx"),
                                                               version: 3)
        let before = pinStore.table.cursors["lx:pu-1"]
        let client = FakePhiSyncClient()
        // tag 的 ownerKey 是 pu-1，载荷里的 owner 是 su-9。
        client.scriptedPages = [page([
            remoteEntity(envelope(pinPayload(lineage: "lx", ownerKey: "su-9")),
                         tag: pinTag("lx"), version: 9, entityId: "srv-p1", key: key),
        ])]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [pinKind(pinAccess, pinStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let table = await engine.ownedTableForTesting("pins")
        XCTAssertEqual(table.cursors["lx:pu-1"], before, "游标一个字段都不许动")
        XCTAssertNil(table.cursors["lx:su-9"], "伪造载荷绝不长出游标")
        let unreadable = await engine.spaceTableForTesting.unreadableTagHashes
        XCTAssertEqual(Set(unreadable.keys), [pinHash("lx")])
    }

    /// CASE 5b.4（承接 CASE 6.13）— 门开边沿的整类型重放覆盖三种 kind。
    ///
    /// 防的是什么：重放漏掉任一 kind，那个 kind 就停在门关之前的状态，而 marker 已经过去了。
    /// **三个断言分开写**：断言两个计数之和，光靠其中一条就能满足。
    func testTheGateOpenEdgeReplayCoversTheSpaceSectionAndBothOwnedKinds() async throws {
        let spaceAccess = makeSpaceAccess()
        let spaceStore = makeSpaceStore()
        spaceStore.table.markerMovedWhileGateShut = true
        let bookmarkAccess = FakeBookmarkAccess()
        let bookmarkStore = MemoryOwnedItemStore()
        let pinAccess = FakePinAccess(scope: .profile, account: .profile)
        let pinStore = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        var remoteSpace = spacePayload(uuid: "su-9")
        remoteSpace.profileUuid = stamped("pu-1", at: 100)
        client.scriptedPages = [page([
            remoteEntity(envelope(remoteSpace), tag: PhiSyncEntity.spaceClientTag("su-9"),
                         version: 10, entityId: "srv-space", key: key),
            remoteEntity(envelope(bookmarkPayload(uuid: "b1")), tag: bookmarkTag("b1"),
                         version: 11, entityId: "srv-b1", key: key),
            remoteEntity(envelope(pinPayload(lineage: "lx")), tag: pinTag("lx"),
                         version: 12, entityId: "srv-p1", key: key),
        ])]

        let engine = makeEngine(client: client, access: spaceAccess, store: spaceStore,
                                ownedKinds: [bookmarkKind(bookmarkAccess, bookmarkStore),
                                             pinKind(pinAccess, pinStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let bookmarkCounters = await engine.lastOwnedRoundCountersForTesting["bookmarks"]
        let pinCounters = await engine.lastOwnedRoundCountersForTesting["pins"]
        XCTAssertNotNil(spaceStore.table.cursors["su-9"], "Space 段处理了它那一条")
        XCTAssertGreaterThanOrEqual(bookmarkCounters?.pulled ?? 0, 1, "书签段处理了它那一条")
        XCTAssertGreaterThanOrEqual(pinCounters?.pulled ?? 0, 1, "pin 段处理了它那一条")
    }

    /// CASE 5b-2.1（原 CASE 6.6c）— 本机主动解除拆分 ⇒ 发 `""`，不是重发基线里的旧伙伴。
    ///
    /// 防的是什么：无条件沿用基线的实现让②也发 `"ld"`——那条 pin 的拆分关系在账户上**永远
    /// 解不掉**，用户每次解除、每次同步又被拼回去。反过来，无条件发 `""` 的实现让①在伙伴
    /// 到达前就把一个完好的拆分对拆开。两半只有「按 `pendingPartnerLineage` 分流」才同时
    /// 成立。
    ///
    /// **取值之外还断时间戳**：一条沿用基线戳的空串与对端手上那条 `("<伙伴>", t_基线)` 戳
    /// 相同，LWW 按序列化字节破平手，空串是对方的前缀、**输掉**平手——解除在对端从来不生效，
    /// 而只断取值的用例对这个缺陷是绿的。
    ///
    /// **第三种形状（③）是反方向的那一半**：一对两半都链好的拆分 pin，它的游标同样没有
    /// `pendingPartnerLineage`。表副本若把它也清掉，投影与基线每轮都不同、每轮重发一次，
    /// 而对端合并出来的值与它手上那条相等、产不出任何 step，于是它也每轮重发——两台设备
    /// 把每一条拆分 pin 永远发下去，还吃掉每轮 250 条的发布预算。
    func testALocalSplitReleaseSendsAnEmptyPartnerWhileAHalfLandedPairKeepsTheBaseline() async throws {
        let spaceAccess = makeSpaceAccess()
        // ①②两条本机行的 `splitPartnerLineageId` 都是 nil；①的标题与基线不同，于是它这一轮
        // 确实出门，投影出来的 `split_partner_uuid` 才观察得到。③那一对互相链着。
        //
        // **四条行都显式传 `createdDate`**：`PhiLocalPin.fixture` 的默认值是 1_000 **秒**，
        // 而 `pinPayload` 的 `createdAtMs` 默认值是 1_000 **毫秒**，差一千倍。`created_at_ms`
        // 是个裸值、不参与盖戳，所以两边不对齐时投影与基线**永远**不同——③那一对会照样出门，
        // 而它们本该一个字节都不发。真实的一轮里基线就是由同一条行投影出来的，所以这是 fixture
        // 的坑不是产品的（书签侧在 `0bba0ae5` 踩过同一个）。
        let created = Date(timeIntervalSince1970: 1)
        let pinAccess = FakePinAccess(scope: .profile, account: .profile, rows: [
            .fixture(lineageId: "LA", guid: "pa", index: 0, title: "A", createdDate: created),
            .fixture(lineageId: "LC", guid: "pc", index: 1, title: "T", createdDate: created),
            .fixture(lineageId: "LE", guid: "pe", index: 2, title: "T",
                     splitPartnerLineageId: "lf", createdDate: created),
            .fixture(lineageId: "LF", guid: "pf", index: 3, title: "T",
                     splitPartnerLineageId: "le", createdDate: created),
        ])
        let pinStore = MemoryOwnedItemStore()
        // ① 确实在等伙伴。四条基线的字段戳都是 100。
        var waiting = publishedPinCursor(pinPayload(lineage: "la", rank: "V",
                                                    splitPartner: "lb"))
        waiting.pendingPartnerLineage = "lb"
        pinStore.table.cursors["la:pu-1"] = waiting
        // ② 伙伴早就到过，是用户刚刚主动解除的。
        pinStore.table.cursors["lc:pu-1"] = publishedPinCursor(
            pinPayload(lineage: "lc", rank: "W", splitPartner: "ld"), entityId: "srv-p2")
        // ③ 两半都链好了：基线带着伙伴，游标没有 `pendingPartnerLineage`，本机两行互相指着。
        pinStore.table.cursors["le:pu-1"] = publishedPinCursor(
            pinPayload(lineage: "le", rank: "X", splitPartner: "lf"), entityId: "srv-p3")
        pinStore.table.cursors["lf:pu-1"] = publishedPinCursor(
            pinPayload(lineage: "lf", rank: "Y", splitPartner: "le"), entityId: "srv-p4")
        let client = FakePhiSyncClient()
        let clock = Clock()

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                clock: clock, ownedKinds: [pinKind(pinAccess, pinStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let commits = pinCommits(client)
        let waitingHalf = commits.first { $0.clientTagHash == pinHash("la") }
            .flatMap(committedPin)
        let releasedHalf = commits.first { $0.clientTagHash == pinHash("lc") }
            .flatMap(committedPin)
        let baselineStamp: Int64 = 100
        XCTAssertEqual(waitingHalf?.splitPartnerUuid.stringValue, "lb",
                       "伙伴还没落地 ⇒ 沿用基线，绝不发空串")
        XCTAssertEqual(waitingHalf?.splitPartnerUuid.updatedAtMs, baselineStamp,
                       "沿用基线的值就该沿用基线的戳，不是一次新的编辑")
        XCTAssertEqual(releasedHalf?.splitPartnerUuid.stringValue, "",
                       "本机主动解除 ⇒ 发空串，不是重发基线里的旧伙伴")
        XCTAssertEqual(releasedHalf?.splitPartnerUuid.updatedAtMs, clock.nowMs,
                       "解除盖的是本轮的 now，否则它在对端的 LWW 平手里输给那条旧链接")
        XCTAssertGreaterThan(releasedHalf?.splitPartnerUuid.updatedAtMs ?? 0, baselineStamp)
        XCTAssertNil(commits.first { $0.clientTagHash == pinHash("le") },
                     "两半都链好的拆分对没有任何变化，表副本不许把它改写成一次编辑")
        XCTAssertNil(commits.first { $0.clientTagHash == pinHash("lf") })
        XCTAssertEqual(commits.count, 2, "本轮只有①②该出门")
    }

    /// CASE 5b.6（R-exec-5）— 远端 pin 落地时带上内容戳。
    ///
    /// 防的是什么：留 nil 的话，下一轮的本机比较戳回落到 `createdDate` = 落地时刻，于是这条
    /// 刚从对端拿来的 pin 在下一次冲突里凭一个假的「我更新」赢掉对端的真实编辑。
    func testARemotePinLandsWithTheEntitysOwnContentTimestamp() async throws {
        let spaceAccess = makeSpaceAccess()
        let pinAccess = FakePinAccess(scope: .profile, account: .profile)
        let pinStore = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        // 内容戳 5 s，远早于 `Clock` 那个 2023 年的「现在」。
        client.scriptedPages = [page([
            remoteEntity(envelope(pinPayload(lineage: "lx", contentStamp: 5_000)),
                         tag: pinTag("lx"), version: 9, entityId: "srv-p1", key: key),
        ])]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [pinKind(pinAccess, pinStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let landed = pinAccess.rows.first { PinKind.lineageKey($0.lineageId) == "lx" }
        let stamp = landed?.contentUpdatedDate
        XCTAssertEqual(stamp, Date(timeIntervalSince1970: 5),
                       "落地的是实体的内容戳，不是 nil、也不是落地时刻")
    }

    // MARK: - CASE 6b.1 – 6b.13：tombstone 的落地（§5.6 T1–T4 / R-M3-3-17 / L1 / L2）

    /// 行 fixture 的 `createdDate` 默认是 1_000 **秒**，而 `bookmarkPayload` 的 `createdAtMs`
    /// 默认是 1_000 **毫秒**，差一千倍。`created_at_ms` 是个裸值、不参与盖戳，所以两边不对齐
    /// 时投影与基线**永远**不同，任何「这一轮零 commit」的断言都会因为一个与被测代码无关的
    /// 理由变红。本段每一条基线载荷都显式传这个值。
    private static let rowCreatedAtMs: Int64 = 1_000_000

    /// 一条与 `PhiLocalBookmark.fixture` 逐字段对齐的基线载荷。
    private func alignedPayload(uuid: String,
                                spaceUuid: String = "su-1",
                                parentUuid: String = "",
                                rank: String = "V",
                                isFolder: Bool = false,
                                title: String = "T",
                                url: String = "https://e.example") -> Phi_PhiBookmarkEntity {
        bookmarkPayload(uuid: uuid, spaceUuid: spaceUuid, parentUuid: parentUuid, rank: rank,
                        isFolder: isFolder, title: title, url: url,
                        createdAtMs: Self.rowCreatedAtMs)
    }

    private func moveIndex(_ ops: [BookmarkApplyOp]) -> Int? {
        ops.firstIndex { if case .move = $0 { return true } else { return false } }
    }

    private func deleteGuids(_ ops: [BookmarkApplyOp]) -> [String] {
        ops.compactMap { if case .delete(let guid) = $0 { return guid } else { return nil } }
    }

    /// CASE 6b.1（T1）— 三张索引都反查不到这个 hash ⇒ 整条忽略、**不建游标**、记一条 info。
    ///
    /// 防的是什么：为一个不认识的 hash 建游标，等于给本机凭空添一条「我删过这个」的记忆。
    /// 那条记忆此后会挡掉这条身份的每一次到达（§4.2 第 3 条与 L2 的版本判据都读它），而本机
    /// 从来就没有过这一行。§11.4 的失败模式表把这一行单列出来。
    func testATombstoneNoIndexRecognisesBuildsNoCursorAtAll() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "G1", syncId: "b1", spaceId: "s-1"),
        ])
        let store = MemoryOwnedItemStore()
        store.table.cursors["b1"] = publishedCursor(alignedPayload(uuid: "b1"))
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([
            remoteTombstone(tag: bookmarkTag("never-published"), version: 9),
        ])]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let table = await engine.ownedTableForTesting("bookmarks")
        let spaceTable = await engine.spaceTableForTesting
        XCTAssertEqual(Set(table.cursors.keys), ["b1"],
                       "认不出的 hash 不许在归属游标表里长出第二条")
        XCTAssertTrue(spaceTable.cursors.isEmpty, "Space 那张表也不许为它建一条")
        let counters = await engine.lastOwnedRoundCountersForTesting["bookmarks"]
        XCTAssertEqual(counters?.tombstones, 0, "没有落地的 tombstone 不计数")
    }

    /// CASE 6b.2（T2）— 反查到身份、本机有行 ⇒ 真删该行，游标写 `deletedAtMs`。
    ///
    /// 时刻取的是**测试自己那个 `Clock`** 的当前值：引擎是 actor，没有也不该有
    /// `nowForTesting`。
    func testARemoteTombstoneDeletesTheRowAndStampsItWithThisRoundsClock() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "G1", syncId: "b1", spaceId: "s-1"),
        ])
        let store = MemoryOwnedItemStore()
        store.table.cursors["b1"] = publishedCursor(alignedPayload(uuid: "b1"),
                                                    entityId: "srv-b1", version: 3)
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([remoteTombstone(tag: bookmarkTag("b1"), version: 8)])]
        let clock = Clock()

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                clock: clock, ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let table = await engine.ownedTableForTesting("bookmarks")
        let stamp = table.cursors["b1"]?.deletedAtMs
        let clockNow = clock.nowMs
        XCTAssertTrue(access.rows.isEmpty, "远端删除真的把那一行删掉了")
        XCTAssertEqual(stamp, clockNow, "定案的时刻是本轮那个时钟读到的值")
        XCTAssertNil(table.cursors["b1"]?.reconciled, "两份基线一起清")
        XCTAssertNil(table.cursors["b1"]?.server)
        XCTAssertFalse(table.cursors["b1"]?.pendingTombstone ?? true)
    }

    /// CASE 6b.4（T4）— 该行所在 Space 正在被导入 ⇒ **停放**这次删除。
    ///
    /// 防的是什么：导入会成批写入同一个 Space，此刻删掉一条行，导入器可能正拿着它的父做插入
    /// 位置计算。
    func testAnImportLockParksARemoteTombstoneInsteadOfDeletingMidImport() async throws {
        let spaceAccess = makeSpaceAccess(["space-a": "su-1"])
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "G1", syncId: "b1", spaceId: "space-a"),
        ])
        access.importingSpaceIds = ["space-a"]
        let store = MemoryOwnedItemStore()
        store.table.cursors["b1"] = publishedCursor(alignedPayload(uuid: "b1"),
                                                    entityId: "srv-b1", version: 3)
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([remoteTombstone(tag: bookmarkTag("b1"), version: 8)])]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertEqual(access.rows.map(\.guid), ["G1"], "导入中途一行都不删")
        XCTAssertTrue(table.cursors["b1"]?.pendingTombstone ?? false, "停放成工作集的一员")
        XCTAssertNil(table.cursors["b1"]?.deletedAtMs, "没删成就不算删了")
    }

    /// CASE 6b.5 — 停放的 tombstone 在导入结束后的第一轮兑现。
    ///
    /// 防的是什么：不兑现的话 T4 的停放就变成静默丢弃——共享 marker 早已推过那一页，那条
    /// tombstone 此后再也不会被服务端重发。
    func testAParkedTombstoneIsHonouredOnTheFirstRoundAfterTheImport() async throws {
        let spaceAccess = makeSpaceAccess(["space-a": "su-1"])
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "G1", syncId: "b1", spaceId: "space-a"),
        ])
        access.importingSpaceIds = ["space-a"]
        let store = MemoryOwnedItemStore()
        store.table.cursors["b1"] = publishedCursor(alignedPayload(uuid: "b1"),
                                                    entityId: "srv-b1", version: 3)
        let client = FakePhiSyncClient()
        client.scriptedPages = [
            page([remoteTombstone(tag: bookmarkTag("b1"), version: 8)], marker: "m1"),
            page([], marker: "m2"),
        ]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        // 第二轮的脚本页是空的：这次删除只能从表里那个 `pendingTombstone` 工作集来。
        access.importingSpaceIds = []
        await engine.pullOnce()

        let table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertTrue(access.rows.isEmpty, "导入结束后的第一轮真的删掉了它")
        XCTAssertNotNil(table.cursors["b1"]?.deletedAtMs)
        XCTAssertFalse(table.cursors["b1"]?.pendingTombstone ?? true, "兑现之后清掉停放位")
    }

    /// CASE 6b.6（R-M3-3-17）— 远端文件夹 tombstone：先提升后代，再删文件夹。
    ///
    /// 防的是什么：**绝不依赖 SwiftData 的 `.cascade`**——它会把孩子一起销毁，而差分随后把
    /// 这场销毁当成本机删除发回去，账户上那些孩子在每一台设备上都消失。
    func testARemoteFolderTombstoneLiftsItsDescendantsBeforeDeletingTheFolder() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "F1", syncId: "folder", spaceId: "s-1", index: 0, isFolder: true,
                     url: URL(string: "https://bookmark.phi/folder")!),
            .fixture(guid: "C1", syncId: "child", spaceId: "s-1", parentGuid: "F1", index: 0),
        ])
        let store = MemoryOwnedItemStore()
        store.table.cursors["folder"] = publishedCursor(
            alignedPayload(uuid: "folder", isFolder: true, url: "https://bookmark.phi/folder"),
            entityId: "srv-folder", version: 3)
        store.table.cursors["child"] = publishedCursor(
            alignedPayload(uuid: "child", parentUuid: "folder"),
            entityId: "srv-child", version: 4)
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([remoteTombstone(tag: bookmarkTag("folder"), version: 9)])]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let table = await engine.ownedTableForTesting("bookmarks")
        let ops = access.lastAppliedOps
        XCTAssertEqual(access.rows.map(\.guid), ["C1"], "① 文件夹没了，孩子还在")
        XCTAssertNil(access.rows.first?.parentGuid, "② 孩子被提到 Space 根")
        XCTAssertNil(table.cursors["child"]?.deletedAtMs, "③ 孩子不是被删的那一条")
        let lift = moveIndex(ops)
        let removal = ops.firstIndex { if case .delete = $0 { return true } else { return false } }
        XCTAssertNotNil(lift, "④ 提升必须真的进了这一批 ops")
        XCTAssertNotNil(removal)
        if let lift, let removal { XCTAssertLessThan(lift, removal, "④ 先提升、后删") }
        XCTAssertEqual(applyCallCount(access), 1, "⑤ 三步在同一个事务里")
    }

    /// CASE 6b.6b — 提升集合是「那个文件夹下的**全部本机后代**」，不是「有游标的那些」。
    ///
    /// 防的是什么：按游标表算提升集合的实现只会看见带身份的那一条，另一条随 `.cascade`
    /// **一起被销毁**——那是一条用户刚建、还没来得及同步的书签，本机从此没有它、账户上也
    /// 从来没有过，**没有任何一侧能把它找回来**。
    ///
    /// 本轮的发布一律被服务端拒掉（`forceInvalidMessage`），于是 §6.4 的「提交被接受之后才
    /// 把铸出来的身份写回本机行」不会发生：这条用例要断言的是**提升**不铸身份，而不是发布
    /// 不铸身份（后者是 CASE 6.14）。
    func testTheLiftSetIsEveryLocalDescendantIncludingRowsWithNoIdentityYet() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "F1", syncId: "folder", spaceId: "s-1", index: 0, isFolder: true,
                     url: URL(string: "https://bookmark.phi/folder")!),
            .fixture(guid: "C1", syncId: "child", spaceId: "s-1", parentGuid: "F1", index: 0),
            // 纯本机：用户刚建的一条，从没上过账户。
            .fixture(guid: "C2", spaceId: "s-1", parentGuid: "F1", index: 1,
                     title: "fresh", url: URL(string: "https://fresh.example")!),
        ])
        let store = MemoryOwnedItemStore()
        store.table.cursors["folder"] = publishedCursor(
            alignedPayload(uuid: "folder", isFolder: true, url: "https://bookmark.phi/folder"),
            entityId: "srv-folder", version: 3)
        store.table.cursors["child"] = publishedCursor(
            alignedPayload(uuid: "child", parentUuid: "folder"),
            entityId: "srv-child", version: 4)
        let client = FakePhiSyncClient()
        client.forceInvalidMessage = true
        client.scriptedPages = [page([remoteTombstone(tag: bookmarkTag("folder"), version: 9)])]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let survivors = access.rows.sorted { $0.guid < $1.guid }
        XCTAssertEqual(survivors.map(\.guid), ["C1", "C2"], "两条后代都活下来，文件夹最后删")
        XCTAssertTrue(survivors.allSatisfy { $0.parentGuid == nil }, "两条都被提到 Space 根")
        XCTAssertNil(survivors.first { $0.guid == "C2" }?.syncId, "提升不铸身份")
    }

    /// CASE 6b.7 — 带自己 tombstone 的后代不被提升。
    ///
    /// 防的是什么：把它也提升一次再删，中间那次 `move` 会被本地写路径看成一次真实的位置变化。
    func testADescendantCarryingItsOwnTombstoneIsDeletedRatherThanLifted() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "F1", syncId: "folder", spaceId: "s-1", index: 0, isFolder: true,
                     url: URL(string: "https://bookmark.phi/folder")!),
            .fixture(guid: "C1", syncId: "child", spaceId: "s-1", parentGuid: "F1", index: 0),
        ])
        let store = MemoryOwnedItemStore()
        store.table.cursors["folder"] = publishedCursor(
            alignedPayload(uuid: "folder", isFolder: true, url: "https://bookmark.phi/folder"),
            entityId: "srv-folder", version: 3)
        store.table.cursors["child"] = publishedCursor(
            alignedPayload(uuid: "child", parentUuid: "folder"),
            entityId: "srv-child", version: 4)
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([
            remoteTombstone(tag: bookmarkTag("folder"), version: 9, entityId: "srv-folder"),
            remoteTombstone(tag: bookmarkTag("child"), version: 10, entityId: "srv-child"),
        ])]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let ops = access.lastAppliedOps
        XCTAssertNil(moveIndex(ops), "该消失的后代不提升")
        XCTAssertEqual(deleteGuids(ops), ["C1", "F1"], "delete 相内子先于父")
        XCTAssertTrue(access.rows.isEmpty)
    }

    /// CASE 6b.8 — 远端删掉的行在差分跑之前就写上 `deletedAtMs`。
    ///
    /// 防的是什么：差分的三条判据（有 `reconciled`、没有 `deletedAtMs`、本机找不到这条身份）
    /// 在删行之后同时成立；不提前定稿，一次**远端**删除会被改写成一次**本机**删除再发回去。
    /// 而只断「没有 tombstone commit」还不够：同一轮的发布段读的是轮首那份行快照，被删的那
    /// 一行仍然在里面，于是 §4.2 第 3b 条会拿「有 `deletedAtMs` + 有活行」把它**复活**发回
    /// 账户——两条路都通向「一次远端删除自己撤销了自己」，所以断的是**整轮零 commit**。
    func testARowDeletedByARemoteTombstoneCommitsNothingInTheSameRound() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "G1", syncId: "b1", spaceId: "s-1"),
        ])
        let store = MemoryOwnedItemStore()
        store.table.cursors["b1"] = publishedCursor(alignedPayload(uuid: "b1"),
                                                    entityId: "srv-b1", version: 3)
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([remoteTombstone(tag: bookmarkTag("b1"), version: 8)])]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertEqual(bookmarkCommits(client).count, 0,
                       "远端删除既不被改写成本机删除发回去，也不被同一轮的发布段复活")
        XCTAssertNotNil(table.cursors["b1"]?.deletedAtMs)
    }

    /// CASE 6b.9（R-M3-3-7）— 每一条离开「活着」的路径都写 `deletedAtMs`。
    ///
    /// 防的是什么：漏掉任何一条，那条游标会停在「有 `reconciled`、无 `deletedAtMs`、本机无
    /// 行」上——也就是差分每一轮都重新为它发一条 tombstone，而 §3.6 的 30 天丢弃永远收不走它。
    func testEveryPathOutOfBeingAliveStampsDeletedAtMs() async throws {
        // ① 本机 tombstone 被服务端接受。
        let acceptedAccess = FakeBookmarkAccess()          // 本机已经没有这一行
        let acceptedStore = MemoryOwnedItemStore()
        acceptedStore.table.cursors["b1"] = publishedCursor(alignedPayload(uuid: "b1"),
                                                            entityId: "srv-b1", version: 3)
        let acceptedClient = FakePhiSyncClient()
        let accepted = makeEngine(client: acceptedClient, access: makeSpaceAccess(),
                                  store: makeSpaceStore(),
                                  ownedKinds: [bookmarkKind(acceptedAccess, acceptedStore)])
        await accepted.setSpaceSyncEnabled(true)
        await accepted.pullOnce()
        let acceptedTable = await accepted.ownedTableForTesting("bookmarks")
        XCTAssertEqual(bookmarkCommits(acceptedClient).filter(\.deleted).count, 1,
                       "① 差分确实发了一条本机 tombstone")
        XCTAssertNotNil(acceptedTable.cursors["b1"]?.deletedAtMs, "① `.applied` 那一支要定案")

        // ② 入站 tombstone 落地。
        let inboundAccess = FakeBookmarkAccess(rows: [
            .fixture(guid: "G1", syncId: "b1", spaceId: "s-1"),
        ])
        let inboundStore = MemoryOwnedItemStore()
        inboundStore.table.cursors["b1"] = publishedCursor(alignedPayload(uuid: "b1"),
                                                           entityId: "srv-b1", version: 3)
        let inboundClient = FakePhiSyncClient()
        inboundClient.scriptedPages = [page([remoteTombstone(tag: bookmarkTag("b1"), version: 8)])]
        let inbound = makeEngine(client: inboundClient, access: makeSpaceAccess(),
                                 store: makeSpaceStore(),
                                 ownedKinds: [bookmarkKind(inboundAccess, inboundStore)])
        await inbound.setSpaceSyncEnabled(true)
        await inbound.pullOnce()
        let inboundTable = await inbound.ownedTableForTesting("bookmarks")
        XCTAssertNotNil(inboundTable.cursors["b1"]?.deletedAtMs, "② 入站落地那一支要定案")

        // ③ `pendingDelete` 连续三轮被 `INVALID_MESSAGE` 拒绝之后的放弃支。
        let refusedAccess = FakeBookmarkAccess()
        let refusedStore = MemoryOwnedItemStore()
        refusedStore.table.cursors["b1"] = publishedCursor(alignedPayload(uuid: "b1"),
                                                           entityId: "srv-b1", version: 3)
        let refusedClient = FakePhiSyncClient()
        refusedClient.refuseCommitsForTagHashes = [bookmarkHash("b1")]
        let refused = makeEngine(client: refusedClient, access: makeSpaceAccess(),
                                 store: makeSpaceStore(),
                                 ownedKinds: [bookmarkKind(refusedAccess, refusedStore)])
        await refused.setSpaceSyncEnabled(true)
        for _ in 0..<3 { await refused.pullOnce() }
        let refusedTable = await refused.ownedTableForTesting("bookmarks")
        XCTAssertFalse(refusedTable.cursors["b1"]?.pendingDelete ?? true, "③ 三轮之后就地收尾")
        XCTAssertNotNil(refusedTable.cursors["b1"]?.deletedAtMs, "③ 放弃支同样定案")
    }

    /// CASE 6b.10（L1 的引擎接线）— 引擎真的把 A9 的三个合取项喂进了 `OwnedItemPlanContext`。
    ///
    /// 防的是什么：引擎不把 `deletedSubtree` 与 `liveLocalParents` 填进去，那三个合取项永远
    /// 判不成立，A9 形同不存在——纯函数层的用例全绿，线上却一次也不触发。
    func testAnInboundMoveOutOfADeletedSubtreeCancelsTheLocalDelete() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "FS", syncId: "b-survivor", spaceId: "s-1", index: 0, isFolder: true,
                     url: URL(string: "https://bookmark.phi/folder")!),
            .fixture(guid: "GC", syncId: "b-child", spaceId: "s-1", index: 1),
        ])
        let store = MemoryOwnedItemStore()
        store.table.cursors["b-survivor"] = publishedCursor(
            alignedPayload(uuid: "b-survivor", isFolder: true,
                           url: "https://bookmark.phi/folder"),
            entityId: "srv-survivor", version: 2)
        // 差分上一轮已经为它作出删除决定，时刻是 1_000。
        store.table.cursors["b-child"] = pendingDeleteCursor(
            decidedAtMs: 1_000, entityId: "srv-child", version: 4,
            reconciled: baselineBytes(alignedPayload(uuid: "b-child")))
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([
            // location 戳 2000 **严格晚于** 删除决定（1_000），父是一条活的本机文件夹。
            remoteEntity(envelope(bookmarkPayload(uuid: "b-child", parentUuid: "b-survivor",
                                                  rank: "W", locationStamp: 2_000,
                                                  rankStamp: 2_000,
                                                  createdAtMs: Self.rowCreatedAtMs)),
                         tag: bookmarkTag("b-child"), version: 30, entityId: "srv-child",
                         key: key),
        ])]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertFalse(table.cursors["b-child"]?.pendingDelete ?? true, "A9 取消了这次删除")
        XCTAssertEqual(access.rows.first { $0.guid == "GC" }?.parentGuid, "FS",
                       "那条行被移到活着的那个父下面")
    }

    /// CASE 6b.11（L2）— 复活按**版本**判，两种 kind 各一次。
    ///
    /// 防的是什么：按时间戳判的实现会被一条重放的旧实体复活掉——服务端在 marker 回退后会重发
    /// 旧版本，而那条实体的字段戳当然比本机刚写的 tombstone 早，于是一条用户明确删掉的行自己
    /// 回来了。A4 说这条适用于 pin，并**防御性地**适用于书签，所以两种 kind 都要测。
    func testResurrectionIsDecidedByVersionForBothKinds() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess()
        let store = MemoryOwnedItemStore()
        var bookmarkCursor = ownedCursor(entityId: "srv-b1", version: 42, ownerUuid: "su-1")
        bookmarkCursor.deletedAtMs = 900
        store.table.cursors["b1"] = bookmarkCursor
        let pinAccess = FakePinAccess(scope: .profile, account: .profile)
        let pinStore = MemoryOwnedItemStore()
        var pinCursor = ownedCursor(entityId: "srv-p1", version: 42, ownerUuid: "pu-1")
        pinCursor.deletedAtMs = 900
        pinStore.table.cursors["lx:pu-1"] = pinCursor
        let client = FakePhiSyncClient()
        client.scriptedPages = [
            // 轮 1：两条都是**旧**版本的重放。
            page([
                remoteEntity(envelope(alignedPayload(uuid: "b1")), tag: bookmarkTag("b1"),
                             version: 41, entityId: "srv-b1", key: key),
                remoteEntity(envelope(pinPayload(lineage: "lx")), tag: pinTag("lx"),
                             version: 41, entityId: "srv-p1", key: key),
            ], marker: "m1"),
            // 轮 2：两条都比那条 tombstone **更新**。
            page([
                remoteEntity(envelope(alignedPayload(uuid: "b1")), tag: bookmarkTag("b1"),
                             version: 43, entityId: "srv-b1", key: key),
                remoteEntity(envelope(pinPayload(lineage: "lx")), tag: pinTag("lx"),
                             version: 43, entityId: "srv-p1", key: key),
            ], marker: "m2"),
        ]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store),
                                             pinKind(pinAccess, pinStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        var bookmarkTable = await engine.ownedTableForTesting("bookmarks")
        var pinTable = await engine.ownedTableForTesting("pins")
        XCTAssertEqual(bookmarkTable.cursors["b1"]?.deletedAtMs, 900,
                       "旧版本重放 ⇒ 丢弃，`deletedAtMs` 原样留着")
        XCTAssertEqual(pinTable.cursors["lx:pu-1"]?.deletedAtMs, 900)
        XCTAssertTrue(access.rows.isEmpty, "一条重放的旧实体不许建行")
        XCTAssertTrue(pinAccess.rows.isEmpty)

        await engine.pullOnce()

        bookmarkTable = await engine.ownedTableForTesting("bookmarks")
        pinTable = await engine.ownedTableForTesting("pins")
        let counters = await engine.lastOwnedRoundCountersForTesting
        XCTAssertNil(bookmarkTable.cursors["b1"]?.deletedAtMs, "更新的版本 ⇒ 合法复活")
        XCTAssertNil(pinTable.cursors["lx:pu-1"]?.deletedAtMs)
        XCTAssertEqual(counters["bookmarks"]?.resurrected, 1)
        XCTAssertEqual(counters["pins"]?.resurrected, 1)
    }

    /// CASE 6b.12（spec item 16 的后半）— 伙伴到达后由**落地**在同一个事务里链两个方向。
    ///
    /// 防的是什么：拆分对是**双向**的；只写到达的那一侧，另一侧要等下一轮本地变化才被发现，
    /// 中间那段时间两台机器对同一对 pin 的显示不一致。这条在引擎层而不是 `plan` 里：它要为
    /// 一条本轮没到达的身份补一步，还要改一条游标，两样都在 `plan` 的输出形状之外。
    ///
    /// ③「`reconcilePinnedSplitPartners` 零调用」在这里是**结构性**的：那个函数是
    /// `BrowserState` 上的活动窗口启发式，同步落地的唯一接缝 `PhiPinnedTabLocalAccess` 上
    /// 根本没有它——②「这一批里只有 `.update`」就是它在假件这一侧的可观测形态。
    func testAnArrivingHalfLinksBothDirectionsOfTheSplitPairInOneBatch() async throws {
        let spaceAccess = makeSpaceAccess()
        let created = Date(timeIntervalSince1970: 1)
        let pinAccess = FakePinAccess(scope: .profile, account: .profile, rows: [
            .fixture(lineageId: "LA", guid: "pa", index: 0, createdDate: created),
            .fixture(lineageId: "LB", guid: "pb", index: 1, createdDate: created),
        ])
        let pinStore = MemoryOwnedItemStore()
        // `la` 上一轮就落了地，那时 `lb` 还不在本机，于是它记下了自己在等谁。
        var waiting = publishedPinCursor(pinPayload(lineage: "la", rank: "V"),
                                         entityId: "srv-pa")
        waiting.pendingPartnerLineage = "lb"
        pinStore.table.cursors["la:pu-1"] = waiting
        pinStore.table.cursors["lb:pu-1"] = publishedPinCursor(
            pinPayload(lineage: "lb", rank: "W"), entityId: "srv-pb")
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([
            remoteEntity(envelope(pinPayload(lineage: "lb", rank: "W", splitPartner: "la",
                                             contentStamp: 500)),
                         tag: pinTag("lb"), version: 9, entityId: "srv-pb", key: key),
        ])]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [pinKind(pinAccess, pinStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let ops = pinAccess.lastAppliedOps
        var linkOf: [String: String?] = [:]
        for op in ops {
            guard case .update(let guid, let fields) = op,
                  let partner = fields.splitPartnerLineageId else { continue }
            linkOf[guid] = partner
        }
        XCTAssertEqual(ops.count, 2, "② 这一批里只有两条 `.update`，没有别的 op")
        XCTAssertTrue(ops.allSatisfy { if case .update = $0 { return true } else { return false } },
                      "② 一条 `.move` / `.relineage` 都不许混进来")
        XCTAssertEqual(linkOf["pa"], "lb", "① `la` 指向 `lb`")
        XCTAssertEqual(linkOf["pb"], "la", "① `lb` 指向 `la`")
        let table = await engine.ownedTableForTesting("pins")
        XCTAssertNil(table.cursors["la:pu-1"]?.pendingPartnerLineage,
                     "④ 伙伴到齐了，那一位跟着清")
        // 这台机器只是**接收**了这条链接：同一轮的发布段绝不许把它读成一次本机解除。
        // （§7.4 的表副本判据是「本机那一行还挂不挂着这条链接」，而那一行是落地在本轮中途
        // 写的，轮首那份投影不会自己变新。）
        let released = pinCommits(client).compactMap(committedPin)
            .filter { $0.splitPartnerUuid.stringValue.isEmpty }
        XCTAssertTrue(released.isEmpty, "不许在同一轮里把刚接收下来的链接当成解除发回账户")
    }

    /// CASE 6b.13 — 同一轮里第二条身份配到一条已被认领的行。
    ///
    /// 防的是什么：第二条也认领同一行的话，那行的 `syncId` 被改写成第二条的身份，**第一条
    /// 身份在账户上从此没有持有者**，下一轮差分为它发一条 tombstone，把账户上一条真实的书签
    /// 删掉。
    ///
    /// 四条断言都由 `SyncableOwnedItems.adopt` 的**按位一对一**配对撑着：两条同键的入站实体
    /// 对一条本机行只配得上第一条，第二条落进 `leftOver` 并走 create。配对那一侧一旦回归、
    /// 两条身份都配到 `GX` 上，① 会是第一个红的——那一行最后带的是 `x2` 而不是 `x1`，②
    /// 的行数也只剩一条。
    ///
    /// **这里不指望假件的 `rowAlreadyMapped` 抛出。** `FakeBookmarkAccess.apply` 是先拿
    /// **施加任何 op 之前**的 `rows` 把整批扫一遍再落地的，所以同一批里的两条 `.claim` 打在
    /// 同一条**尚未认领**的行上时两条都看见 `syncId == nil`，一条都不抛——第二条只是在落地
    /// 时覆盖掉第一条。那条模拟覆盖的是另一种形状：目标行**在这一批之前**就已经带着另一个
    /// 身份（上一批、或轮首那份快照里就带着）。
    func testASecondIdentityPairingToAClaimedRowTakesTheCreatePath() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            // 一条本机未同步行，两条入站实体按 §6.1 的匹配键（URL）都配得上它。
            .fixture(guid: "GX", spaceId: "s-1", index: 0, title: "X",
                     url: URL(string: "https://x.example")!),
        ])
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([
            remoteEntity(envelope(alignedPayload(uuid: "x1", rank: "V", title: "X",
                                                 url: "https://x.example")),
                         tag: bookmarkTag("x1"), version: 30, entityId: "srv-x1", key: key),
            remoteEntity(envelope(alignedPayload(uuid: "x2", rank: "W", title: "X",
                                                 url: "https://x.example")),
                         tag: bookmarkTag("x2"), version: 31, entityId: "srv-x2", key: key),
        ])]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let table = await engine.ownedTableForTesting("bookmarks")
        let counters = await engine.lastOwnedRoundCountersForTesting["bookmarks"]
        let claimed = access.rows.first { $0.guid == "GX" }?.syncId
        XCTAssertEqual(claimed, "x1", "① 第一条正常认领，那行写上它的身份")
        XCTAssertEqual(access.rows.count, 2, "② 第二条走 create 路径，本机多出一条新行")
        XCTAssertEqual(access.rows.first { $0.guid != "GX" }?.syncId, "x2")
        XCTAssertNotNil(table.cursors["x1"]?.reconciled,
                        "③ 那个 Space 的整批落地没有被 `rowAlreadyMapped` 拒掉")
        XCTAssertNotNil(table.cursors["x2"]?.reconciled)
        XCTAssertEqual(counters?.adopted, 1, "④ 只认领了一条")
    }

    // MARK: - CASE 11.1 – 11.5：预览的页预算与截止时间

    // 预览与正式拉取共用 `maxPullPages = 64` 时，一页 500 条、上限 32 000 条实体要横跨
    // 全部 kind，并且 tombstone 也算在里面（M5 之前永不回收）。两种新 kind 之后，一个
    // 普通账户的书签与 pin 就能把这 64 页吃完，于是配对向导会在数清账户里有几个 Space
    // 之前先被截断。所以预览有它自己的页预算与自己的截止时间。

    /// CASE 11.1 — 默认页预算就是 400。
    ///
    /// 防的是什么：每个 `makeEngine` 都显式传 `previewMaxPages` 的用例永远测不到**默认
    /// 值**——把默认写成 64 的实现照样全绿，而线上走的正是那个默认值。所以这一条**不经
    /// `makeEngine`**：直接构造一台不传这个参数的引擎，让它自己跑到预算耗尽。
    func testTheDefaultPreviewPageBudgetIsFourHundredPages() async throws {
        XCTAssertEqual(PhiSyncEngine.defaultPreviewMaxPages, 400)

        let client = FakePhiSyncClient()
        client.keepReportingChangesRemaining = true        // 永远还有下一页
        client.seed(tagHash: spaceHash("su-1"),
                    ciphertext: try spaceCiphertext("su-1"), version: 3)
        let clock = Clock()                                // advancePerRead = 0 ⇒ 期限不参与
        let engine = PhiSyncEngine(domainKeys: StubDomainKeys(key: key), client: client,
                                   defaults: defaults, deviceKeyId: "devA", settings: [],
                                   spaceAccess: makeSpaceAccess(), spaceStore: makeSpaceStore(),
                                   ownedKinds: [], now: { clock.read() })

        let result = await engine.previewAccountSpaces()
        guard case .failure(let error) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(error, .truncated)
        // 那台不传参数的引擎真的走到了 400 页才停：默认实参与 `defaultPreviewMaxPages` 同源。
        XCTAssertEqual(client.getUpdatesCalls.count, 400)
        let stats = await engine.lastPreviewStatsForTesting
        XCTAssertEqual(stats.pages, 400)
    }

    /// CASE 11.2 — 第 65 页仍然继续。
    ///
    /// 防的是什么：按 64 页停的实现必须让这条红。
    func testThePreviewKeepsPagingPastTheSixtyFourthPage() async throws {
        let client = FakePhiSyncClient()
        // 前 65 页都报 `changesRemaining == true`，第 66 页才收尾。这里用的是倒计时
        // `pageBudgetExhaustsAfter` 而不是 `keepReportingChangesRemaining`：后者永不收尾，
        // 结果只能是 `.truncated`，而这一条要断言的恰恰是 `.success`。
        client.pageBudgetExhaustsAfter = 65
        client.seed(tagHash: spaceHash("su-1"),
                    ciphertext: try spaceCiphertext("su-1"), version: 3)
        let engine = makeEngine(client: client)

        let result = await engine.previewAccountSpaces()
        guard case .success(let summaries) = result else { return XCTFail("expected success") }
        XCTAssertGreaterThan(client.getUpdatesCalls.count, 64, "64 页不是预览的预算")
        XCTAssertEqual(summaries.map(\.syncUuid), ["su-1"])
    }

    /// CASE 11.3 — 超出页预算返回 `.truncated`，两个计数经一条独立的只读接缝暴露。
    ///
    /// 防的是什么：没有这两个数字，一次线上截断在日志里与一次网络失败无法区分。但它们
    /// **不能挂在 `.truncated` 上**：给那个 case 加载荷会同时改坏 `PhiSyncEngineSpaceTests`
    /// 与 `PairingWizardViewModelTests` 里既有的断言，以及 `PairingWizardViewModel` 的两处
    /// `case .truncated:`。做成只读接缝，既有代码一行不动。
    func testAnExhaustedPreviewPageBudgetExposesItsPageAndEntityCounts() async throws {
        let client = FakePhiSyncClient.alwaysMorePages(key: key)
        client.seed(tagHash: spaceHash("su-1"),
                    ciphertext: try spaceCiphertext("su-1"), version: 3)
        let engine = makeEngine(client: client, previewMaxPages: 3)

        let result = await engine.previewAccountSpaces()
        guard case .failure(let error) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(error, .truncated)
        XCTAssertEqual(client.getUpdatesCalls.count, 3)
        let stats = await engine.lastPreviewStatsForTesting
        XCTAssertEqual(stats.pages, 3)
        XCTAssertGreaterThan(stats.entities, 0, "数过的实体条数，不是摘要条数")
    }

    /// CASE 11.4 — 截止时间是 120 s，超期报 `.timedOut` 而不是 `.truncated`。
    ///
    /// 期限判在轮体里、判在页边界上：`serialized(_:)` 把轮体放进一个非结构化 `Task {}`，
    /// 向导那一侧取消不掉它，所以没有这条守卫，一次抖动的网络会一直占着 round 队列。
    func testThePreviewDeadlineIsTwoMinutesAndReportsTimedOut() async throws {
        XCTAssertEqual(PhiSyncEngine.previewDeadlineMs, 120_000)

        let clock = Clock()
        clock.advancePerRead = 30_000                      // 每读一次推进 30 s
        let client = FakePhiSyncClient()
        client.pageBudgetExhaustsAfter = 1_000             // 永远 changesRemaining == true
        client.seed(tagHash: spaceHash("su-1"),
                    ciphertext: try spaceCiphertext("su-1"), version: 3)
        let engine = makeEngine(client: client, clock: clock)

        let result = await engine.previewAccountSpaces()
        guard case .failure(let error) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(error, .timedOut, "`.truncated` 是页预算用尽，期限是另一回事")
        // 120 s / 30 s ⇒ 三页之后就超了；断言留一页余量，免得多一次 `now()` 读取就红。
        XCTAssertGreaterThan(client.getUpdatesCalls.count, 0)
        XCTAssertLessThanOrEqual(client.getUpdatesCalls.count, 4,
                                 "期限必须远在 400 页预算之前把分页停下来")
    }

    /// CASE 11.5 — 预览仍然跳过 tombstone 与非 Space kind，一条都不物化。
    ///
    /// 这是**既有行为**（解密前 `guard !entity.deleted`；构造摘要前 `guard case .space`），
    /// 这里只是把它钉住：预览是只读的，Task 6 那条按 kind 泛型分发的路径**绝不能**从预览
    /// 走到——否则一次配对预览就会往本机写书签。
    func testThePreviewSkipsTombstonesAndNonSpaceKindsAndMaterialisesNothing() async throws {
        let bookmarkAccess = FakeBookmarkAccess(rows: [])
        let bookmarkStore = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([
            remoteTombstone(tag: PhiSyncEntity.spaceClientTag("su-dead"), version: 2,
                            entityId: "srv-dead"),
            remoteEntity(envelope(bookmarkPayload(uuid: "b1")), tag: bookmarkTag("b1"),
                         version: 3, entityId: "srv-b1", key: key),
            remoteEntity(envelope(spacePayload(uuid: "su-live", name: "Work")),
                         tag: PhiSyncEntity.spaceClientTag("su-live"),
                         version: 4, entityId: "srv-live", key: key),
        ])]
        let engine = makeEngine(client: client, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(bookmarkAccess, bookmarkStore)])

        let result = await engine.previewAccountSpaces()
        guard case .success(let summaries) = result else { return XCTFail("expected success") }
        XCTAssertEqual(summaries.map(\.syncUuid), ["su-live"], "tombstone 与书签都不在列表里")
        XCTAssertEqual(summaries.first?.name, "Work")
        // 一条都不物化：本机不被读、不被写，归属游标表连载入都没有，零 commit。
        XCTAssertTrue(bookmarkAccess.calls.isEmpty, "预览不碰本机书签")
        XCTAssertTrue(bookmarkStore.hadRecordsSeen.isEmpty, "预览不载入归属游标表")
        XCTAssertTrue(bookmarkStore.table.cursors.isEmpty)
        XCTAssertTrue(client.commits.isEmpty, "预览零 commit")
        let stats = await engine.lastPreviewStatsForTesting
        XCTAssertEqual(stats.pages, 1)
        XCTAssertEqual(stats.entities, 3, "数的是页里的实体总数，过滤在它之后")
    }

    // MARK: - CASE 7.1 – 7.7：认领 + 提交期铸造 + 发布段预处理（Group A）

    /// 一条本机未同步行，URL 与 `alignedPayload(uuid:)` 默认产出的那条实体相同。
    ///
    /// §6.1 的书签匹配键是 **URL**（文件夹才按标题），所以这一对天然配得上；标题与内容戳
    /// 由调用方按每条用例要的胜负方向给。`createdDate` 用 fixture 的默认值（1_000 **秒**），
    /// 与 `Self.rowCreatedAtMs`（1_000_000 **毫秒**）对齐，于是任何「这一轮零 commit」的
    /// 断言不会因为 `created_at_ms` 这个裸值而变红。
    private func adoptableRow(guid: String = "G1", spaceId: String = "s-1",
                              title: String = "T",
                              contentUpdatedDate: Date? = nil) -> PhiLocalBookmark {
        .fixture(guid: guid, spaceId: spaceId, title: title,
                 contentUpdatedDate: contentUpdatedDate)
    }

    /// 一页只装一条书签实体的脚本页。
    ///
    /// marker 取一个**数值**（假件按 `Int64(text)` 解 watermark）：默认那个 `"m1"` 解出 0，
    /// 于是第二轮会把第一轮提交进 `stored` 的那些行整批重投一遍，而本段好几条用例的第二轮
    /// 断言的正是「一条都不该再发」。
    private func oneEntityPage(_ entity: Phi_PhiBookmarkEntity, uuid: String,
                               version: Int64 = 30,
                               entityId: String = "srv-b1")
        -> FakePhiSyncClient.Page {
        page([remoteEntity(envelope(entity), tag: bookmarkTag(uuid), version: version,
                           entityId: entityId, key: key)],
             marker: "500")
    }

    /// CASE 7.1 — 认领与落地共一个事务，一起回滚。
    ///
    /// 防的是什么：「改了 `syncId` 却没落地」的中间态会让下一轮的匹配看不见那些行（它们已经
    /// 不是 `syncId == nil`），于是远端实体被建成重复行，而本机那几行永远不会再被认领。
    ///
    /// **断言 ② 是「一个字节的基线都没写」，不是「游标表为空」**：落地失败的那一批按 §4.9
    /// 第 3 条**停放**，而停放本来就要建一条带 `pendingApply` 的游标（Task 6 落地的形状）。
    /// 真正不许发生的是写下一份 `reconciled` / `server`——那等于记住一次从没发生过的落地。
    func testAFailedLandingRollsBackTheClaimAndWritesNoBaseline() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [adoptableRow()])
        access.failApplyOnce = true
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.scriptedPages = [oneEntityPage(alignedPayload(uuid: "b1"), uuid: "b1")]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let table = await engine.ownedTableForTesting("bookmarks")
        let syncId = access.rows.first { $0.guid == "G1" }?.syncId
        let baselines = table.cursors.values.filter { $0.reconciled != nil || $0.server != nil }
        XCTAssertNil(syncId, "① 落地回滚了，`syncId` 不许停在中间态")
        XCTAssertTrue(baselines.isEmpty, "② 基线一个字节都不写")
        XCTAssertTrue(bookmarkCommits(client).isEmpty,
                      "③ 配对上的那一行本轮不铸新身份，所以也没什么可发")
    }

    /// CASE 7.2 — 成功那一路：认领而不是复制。
    func testASuccessfulLandingAdoptsTheLocalRowInsteadOfCopyingIt() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [adoptableRow()])
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.scriptedPages = [oneEntityPage(alignedPayload(uuid: "b1"), uuid: "b1")]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let counters = await engine.lastOwnedRoundCountersForTesting["bookmarks"]
        XCTAssertEqual(access.rows.count, 1, "① 一条行绝不因为一次认领变成两条")
        XCTAssertEqual(access.rows.first { $0.guid == "G1" }?.syncId, "b1",
                       "② 那一行接过账户上那个身份")
        XCTAssertEqual(counters?.adopted, 1, "③")
    }

    /// CASE 7.2b — 认领时本机赢了一个字段 ⇒ 恰好一条 commit，带的是合并后的标题。
    ///
    /// 防的是什么：两个独立的错法都在这条上红。其一，落地时用了入站的**原始**实体 ⇒ ① 变成
    /// `"remote-old"`，用户刚打的字被一次认领吃掉。其二，`mustRepublish` 没人消费 ⇒ ③ 是零条：
    /// 那条游标的基线已经是合并后的字节，快照差分此后永远判「没变化」，账户上那条旧标题
    /// **再也没有机会**被纠正。本条只盯本机赢的那个方向，远端赢的那一半由 CASE 7.2c 盯。
    func testALocalFieldWonAtAdoptionIsRepublishedOnceWithTheMergedTitle() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            adoptableRow(title: "local-new",
                         contentUpdatedDate: Date(timeIntervalSince1970: 3_000)),
        ])
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.scriptedPages = [oneEntityPage(
            bookmarkPayload(uuid: "b1", title: "remote-old", contentStamp: 2_000_000,
                            createdAtMs: Self.rowCreatedAtMs), uuid: "b1")]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let counters = await engine.lastOwnedRoundCountersForTesting["bookmarks"]
        let row = access.rows.first { $0.guid == "G1" }
        XCTAssertEqual(access.rows.count, 1, "①")
        XCTAssertEqual(row?.syncId, "b1", "①")
        XCTAssertEqual(row?.title, "local-new", "① 落地的是合并结果，不是入站那条原始实体")
        XCTAssertEqual(counters?.adopted, 1, "②")

        // ③ 判据是「这一轮或下一轮**恰好**一条」，所以第二轮之后数的是累计值。
        await engine.pullOnce()

        let commits = bookmarkCommits(client)
        XCTAssertEqual(commits.count, 1, "③ 本机赢下的字段回了账户，而且只回一次")
        XCTAssertEqual(commits.first.flatMap(committedBookmark)?.title.stringValue, "local-new",
                       "③ 发出去的是合并后的标题")
    }

    /// CASE 7.2c — 认领时远端赢了一个字段 ⇒ 本机那一行被改写。
    ///
    /// 防的是什么：`fieldWrites` 没人消费 ⇒ ① 停在 `"local-old"`，而那条游标的 `reconciled`
    /// 记的是 `"remote-new"`。下一轮快照拿本机那个旧标题投影，与基线不同 ⇒ 判成「本机改了
    /// 标题」，把 `"local-old"` 发回账户，**把对端刚做的改名覆盖掉**——一次认领于是变成一次
    /// 静默的数据回滚。
    func testARemoteFieldWonAtAdoptionRewritesTheLocalRow() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            adoptableRow(title: "local-old",
                         contentUpdatedDate: Date(timeIntervalSince1970: 500)),
        ])
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.scriptedPages = [oneEntityPage(
            bookmarkPayload(uuid: "b1", title: "remote-new", contentStamp: 2_000_000,
                            createdAtMs: Self.rowCreatedAtMs), uuid: "b1")]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let row = access.rows.first { $0.guid == "G1" }
        XCTAssertEqual(access.rows.count, 1, "①")
        XCTAssertEqual(row?.syncId, "b1", "①")
        XCTAssertEqual(row?.title, "remote-new", "① 远端赢下的字段真的写进了本机行")

        await engine.pullOnce()

        XCTAssertEqual(bookmarkCommits(client).count, 0,
                       "② 账户已经是对的，两轮加起来一条都不该发")
    }

    /// CASE 7.3 — 铸造在提交那一刻：提交没被接受 ⇒ 身份不进本机行。
    ///
    /// 防的是什么：提前写进 SwiftData 的实现会在一次提交失败之后留下一批「有身份、线上不
    /// 存在」的行，而差分此后把它们当作已发布，永远不再产出 create。
    func testAMintedIdentityReachesTheLocalRowOnlyAfterTheCommitIsAccepted() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [.fixture(guid: "G1", spaceId: "s-1")])
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        // 超过 §5.3 那次限定范围重试所需的条数，于是本轮这条实体一个字节都没被账户接受。
        client.forcedConflicts = 10

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertNil(access.rows.first { $0.guid == "G1" }?.syncId,
                     "① 提交没被接受 ⇒ 身份不许落进本机行")

        client.forcedConflicts = 0
        await engine.pullOnce()

        XCTAssertNotNil(access.rows.first { $0.guid == "G1" }?.syncId,
                        "② 被接受的那一刻才写回")
        XCTAssertEqual(access.rows.count, 1, "两轮下来那条行还是一条")
    }

    /// CASE 7.4 — 尽力推迟是轮内局部量，不落盘（§5.3 / §6.4）。
    ///
    /// 防的是什么：把推迟判据写进游标表会被 CASE 3.2 打红（那张表里不许有任何窗口状态）；
    /// 而不推迟会在一次首次合并里同时发出本机副本与账户副本，制造 §6.5 记录的那类重复。
    func testAnUnsyncedRowWaitsOutTheRoundInWhichItsSpaceReceivedEntities() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            // URL 与入站那条不同 ⇒ §6.1 配不上它，本轮会为它铸一个新身份。
            .fixture(guid: "G2", spaceId: "s-1", index: 1, title: "other",
                     url: URL(string: "https://other.example")!),
        ])
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.scriptedPages = [oneEntityPage(alignedPayload(uuid: "b1"), uuid: "b1")]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertEqual(bookmarkCommits(client).count, 0,
                       "① 这个 Space 本轮到过货 ⇒ 它下面的未同步行不进本轮切片")
        let table = await engine.ownedTableForTesting("bookmarks")
        let fields = Mirror(reflecting: table).children.compactMap(\.label)
        XCTAssertEqual(fields, ["formatVersion", "cursors"],
                       "② 推迟不许在游标表上留下任何窗口状态")

        // 第一个**没有**该 Space 实体到达的轮次：那条行照常发出。
        await engine.pullOnce()

        let commits = bookmarkCommits(client)
        XCTAssertEqual(commits.count, 1, "③ 下一轮照常发出，推迟不是丢弃")
        XCTAssertEqual(commits.first.flatMap(committedBookmark)?.url.stringValue,
                       "https://other.example", "③ 发出去的正是那条被推迟的行")
    }

    /// CASE 7.5 — 预处理刷新表里**每一条**游标的 `ownerUuid`，不只是本轮切片里的。
    ///
    /// 防的是什么：只刷新切片内的实现，会让一条长期没变动的行的 `ownerUuid` 永远停在它第一次
    /// 发布时的 Space 上；那个 Space 一旦被清理，§9.3 的级联就会去删一条活行的游标，而那条行
    /// 此后被差分判成从未发布过、用 `baseVersion == 0` 的 create 盲写覆盖账户上那一条。
    func testTheOwnerPrePassRefreshesEveryCursorNotOnlyThisRoundsSlice() async throws {
        let spaceAccess = makeSpaceAccess(["s-1": "su-1", "s-2": "su-2"])
        let access = FakeBookmarkAccess(rows: [
            // 早就发布过、这一轮一个字节都没变 ⇒ **不进切片**；它现在坐在 `s-2`。
            .fixture(guid: "GOLD", syncId: "b-old", spaceId: "s-2", title: "T"),
            // 本轮会被铸身份、进切片的那一条。
            .fixture(guid: "GNEW", spaceId: "s-1", index: 1, title: "N",
                     url: URL(string: "https://new.example")!),
        ])
        let store = MemoryOwnedItemStore()
        var stale = publishedCursor(alignedPayload(uuid: "b-old", spaceUuid: "su-2"),
                                    entityId: "srv-old", version: 9)
        stale.ownerUuid = "su-stale"
        store.table.cursors["b-old"] = stale
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([], marker: "500")]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let table = await engine.ownedTableForTesting("bookmarks")
        let published = bookmarkCommits(client).compactMap { committedBookmarkUuid($0, key: key) }
        XCTAssertEqual(table.cursors["b-old"]?.ownerUuid, "su-2",
                       "① 归属按本地行现在坐的那个 Space 刷新")
        XCTAssertFalse(published.contains("b-old"),
                       "② 它本轮根本没进切片——刷新覆盖的是表里每一条，不是切片里那些")
        XCTAssertEqual(published.count, 1, "② 进切片的只有那条新行")
    }

    /// CASE 7.6 — 落地一条远端赢的标题变更 ⇒ 该轮零 commit，下一轮静默。
    ///
    /// 防的是什么：不刷新轮内那份本机投影时 ① 是一条——内容是**落地前**的旧标题、戳是 `now`。
    /// 那个 `now` 比对端刚才那次真实编辑更晚，于是在一次并发编辑里**旧值盖掉新值**，一个纯粹
    /// 的读写时序问题变成一次数据回滚。② 是判据的另一半：只断言第一轮的实现可能把刷新做成
    /// 「延迟到下一轮」，那样第二轮才发那条多余的 commit。
    func testLandingARemotelyWonTitleCommitsNothingInEitherRound() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "G1", syncId: "b1", spaceId: "s-1", title: "old",
                     contentUpdatedDate: Date(timeIntervalSince1970: 500)),
        ])
        let store = MemoryOwnedItemStore()
        store.table.cursors["b1"] = publishedCursor(alignedPayload(uuid: "b1", title: "old"),
                                                    entityId: "srv-b1", version: 7)
        let client = FakePhiSyncClient()
        client.scriptedPages = [oneEntityPage(
            bookmarkPayload(uuid: "b1", title: "new", contentStamp: 2_000_000,
                            createdAtMs: Self.rowCreatedAtMs),
            uuid: "b1", version: 42, entityId: "srv-b1")]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertEqual(access.rows.first { $0.guid == "G1" }?.title, "new",
                       "前提：远端赢下的标题真的落进了本机行")
        XCTAssertEqual(bookmarkCommits(client).count, 0, "① 落地那一轮零 commit")

        await engine.pullOnce()

        XCTAssertEqual(bookmarkCommits(client).count, 0,
                       "② 下一轮也零条——真的收敛了，不是把问题推到下一轮")
    }

    /// CASE 7.7 — 落地一条远端赢的移动 ⇒ 该轮零 commit（**位置也要刷新**）。
    ///
    /// 防的是什么：刷新只覆盖内容字段、漏掉位置的实现，会在每一次入站移动之后把**旧位置**
    /// 配上一个新鲜的 `now` 发回去，把对端刚做的移动原地撤销。断言 ② 是 CASE 6.17 的 ③
    /// （`testALocallyWonFieldIsRepublishedAndServerKeepsThePulledBytes`）那一半：本机赢下内容
    /// 时那条 commit 照发，但它带的位置必须是**落地后**的 `su-2`。这里把它单独立一遍，是因为
    /// 那条用例还同时断言别的东西，只看它的话分不清「位置对了」与「别的原因让它绿了」。
    func testLandingARemotelyWonMoveCommitsNothingAndRepublishesAtTheNewSpace() async throws {
        // 第一半：纯位置变化 ⇒ 零 commit。
        let spaceAccess = makeSpaceAccess(["s-1": "su-1", "s-2": "su-2"])
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "G1", syncId: "b1", spaceId: "s-1", title: "T",
                     contentUpdatedDate: Date(timeIntervalSince1970: 500)),
        ])
        let store = MemoryOwnedItemStore()
        store.table.cursors["b1"] = publishedCursor(alignedPayload(uuid: "b1"),
                                                    entityId: "srv-b1", version: 7)
        let client = FakePhiSyncClient()
        client.scriptedPages = [oneEntityPage(
            bookmarkPayload(uuid: "b1", spaceUuid: "su-2", locationStamp: 300,
                            createdAtMs: Self.rowCreatedAtMs),
            uuid: "b1", version: 42, entityId: "srv-b1")]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertEqual(access.rows.first { $0.guid == "G1" }?.spaceId, "s-2",
                       "前提：远端赢下的移动真的落了地")
        XCTAssertEqual(bookmarkCommits(client).count, 0,
                       "① 位置也刷新了 ⇒ 投影与刚写好的基线逐字节相同，没什么可发")

        // 第二半（CASE 6.17 的 ③）：同一次移动，但本机赢下了内容 ⇒ 那条 commit 照发，
        // 而它带的位置是**落地后**的那一个。
        let wonAccess = FakeBookmarkAccess(rows: [
            .fixture(guid: "G1", syncId: "b1", spaceId: "s-1", title: "local",
                     contentUpdatedDate: Date(timeIntervalSince1970: 500)),
        ])
        let wonStore = MemoryOwnedItemStore()
        wonStore.table.cursors["b1"] = publishedCursor(alignedPayload(uuid: "b1", title: "old"),
                                                       entityId: "srv-b1", version: 7)
        let wonClient = FakePhiSyncClient()
        wonClient.scriptedPages = [oneEntityPage(
            bookmarkPayload(uuid: "b1", spaceUuid: "su-2", title: "old", locationStamp: 300,
                            createdAtMs: Self.rowCreatedAtMs),
            uuid: "b1", version: 42, entityId: "srv-b1")]

        let wonEngine = makeEngine(client: wonClient, access: makeSpaceAccess(["s-1": "su-1",
                                                                              "s-2": "su-2"]),
                                   store: makeSpaceStore(),
                                   ownedKinds: [bookmarkKind(wonAccess, wonStore)])
        await wonEngine.setSpaceSyncEnabled(true)
        await wonEngine.pullOnce()

        let wonCommits = bookmarkCommits(wonClient)
        let sent = wonCommits.first.flatMap(committedBookmark)
        XCTAssertEqual(wonCommits.count, 1, "② 本机赢下的标题要回账户")
        XCTAssertEqual(sent?.title.stringValue, "local", "② 带的是本机那个标题")
        XCTAssertEqual(sent?.spaceUuid.stringValue, "su-2", "② 带的是落地后的那个 Space")
    }

    // MARK: - CASE 9a.1 – 9a.3：生命周期（书签半边）

    /// Task 9a 专用的 `SyncKeyController`：只接自撤销那一步真正要碰的两样东西——归属项的
    /// 游标 store 数组，与清 `syncId` 的那个窄闭包。其余构造参数走默认值，或本文件与
    /// `Sync/Keys` 那批用例共享的假件（形状照 `SelfRevokeTests.makeController`）。
    ///
    /// **`engineDefaults` 显式传本用例那个一次性 suite**，不用默认实参：自撤销的引擎状态
    /// 那一步会把 `PhiSyncEngine.stateKeys` 从传进去的域里删掉，而默认实参是
    /// `UserDefaults.standard`——那是这台机器上真正在用的同步游标。
    private func makeController(ownedStores: [any PhiOwnedItemStateStore],
                                bookmarkAccess: FakeBookmarkAccess,
                                ledger: SelfRevokeLedger = SelfRevokeLedger()) async throws
        -> SyncKeyController {
        let api = AccountKeyManagerTests.FakeAPI()
        let manager = AccountKeyManager(
            api: api, deviceKeyProvider: AccountKeyManagerTests.FakeDeviceKeyProvider())
        _ = try await manager.bootstrap()
        let profileKeys = ProfileKeyManager(
            api: api, keyManager: manager,
            mappingStore: ProfileKeyManagerTests.MemoryMappingStore())
        let approvals = DeviceApprovalService(
            api: api, keyManager: manager,
            deviceKeyProvider: AccountKeyManagerTests.FakeDeviceKeyProvider())
        return SyncKeyController(
            manager: manager, approvals: approvals, profileKeys: profileKeys,
            localProfilesProvider: { [] }, notifyChromium: {},
            engineDefaults: defaults,
            ownedItemStores: ownedStores,
            // 记在闭包**进入时**，不是返回之后：这一步会抛，而 CASE 9a.1 要断言的正是
            // 「它开始的时候文件已经删掉了」。
            clearAllSyncIds: {
                ledger.note("clearSyncIds")
                try await bookmarkAccess.clearAllSyncIds()
            })
    }

    /// 自撤销那几步的**发生次序**。`@unchecked Sendable` 是因为 `clearAllSyncIds` 是一个
    /// `@Sendable` 闭包；这些用例整体跑在 main actor 上，账本没有并发写入方。
    final class SelfRevokeLedger: @unchecked Sendable {
        private(set) var steps: [String] = []
        func note(_ step: String) { steps.append(step) }
    }

    /// CASE 9a.1 的顺序探针用的游标 store：每一次副作用都记进共享账本。
    ///
    /// 单独写一个而不是给 `MemoryOwnedItemStore` 加成员：那个假件被本文件几十条用例共享，
    /// 而这里要的是一份只有这一条用例关心的副作用流水。
    private final class RecordingOwnedItemStore: PhiOwnedItemStateStore {
        let ledger: SelfRevokeLedger
        var table = PhiOwnedItemTable()
        private(set) var deleted = false

        init(ledger: SelfRevokeLedger) { self.ledger = ledger }

        func load(hadRecords: Bool) -> (table: PhiOwnedItemTable, reportedLoss: Bool) {
            ledger.note("load")
            return (table, hadRecords && table.cursors.isEmpty)
        }

        func save(_ table: PhiOwnedItemTable) {
            self.table = table
            ledger.note("save")
        }

        func deleteFile() {
            deleted = true
            table = PhiOwnedItemTable()
            ledger.note("deleteFile")
        }
    }

    /// CASE 9a.1（spec engine 12）— 自撤销**先删两个游标文件，再清 `syncId`**。
    ///
    /// 防的是什么：断言的是**顺序本身**。两种中途失败的后果不对称——停在「文件没了、
    /// `syncId` 还在」这一侧是**可恢复**的（重新加入时的整类型重放按身份把每条实体重新落回
    /// 它原来那一行，游标自己长回来）；反过来「`syncId` 清了、文件还在」是**灾难**：游标说
    /// 「我发布过这些身份」，本机却没有任何行带这些身份，§4.7 的差分把整张表判成本机删除，
    /// 重新加入后删掉账户上的整棵树。
    ///
    /// **终态断不出这件事**（T9a-1）：清 `syncId` 失败是被有意吞掉的，所以把两步反过来写，
    /// 「文件已删 + `syncId` 还在 + 清那一步跑过」三条**照样全部成立**。判据必须是两个副作用
    /// 的**先后**，所以这里记一份流水账，由 `RecordingOwnedItemStore` 与注入的闭包共同写。
    ///
    /// 清 `syncId` 失败**只记 warn、不中断、也不回滚删文件**，precedent 是同一个方法里设备
    /// 密钥轮换失败那一段。
    func testSelfRevokeDeletesTheCursorFilesBeforeItClearsTheSyncIds() async throws {
        let ledger = SelfRevokeLedger()
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "G1", syncId: "b1", spaceId: "space-a"),
        ])
        // 第二步抛：可恢复的那一侧，同时证明失败不回滚前一步。
        access.failClearSyncIds = true
        let store = RecordingOwnedItemStore(ledger: ledger)
        store.table.cursors["b1"] = ownedCursor(entityId: "srv-b1", version: 1,
                                                ownerUuid: "su-1")
        ProfilePairingGate.staticPendingOverride = true
        defer { ProfilePairingGate.staticPendingOverride = nil }

        let controller = try await makeController(ownedStores: [store], bookmarkAccess: access,
                                                  ledger: ledger)
        try await controller.removeThisDeviceFromSync()

        XCTAssertEqual(ledger.steps, ["deleteFile", "clearSyncIds"],
                       "① 次序本身：文件先删，`syncId` 后清。反过来写这一条就红")
        XCTAssertTrue(store.deleted, "② 清 `syncId` 抛了也不回滚那次删文件")
        XCTAssertEqual(access.rows.first?.syncId, "b1",
                       "③ 它抛了，`syncId` 原样留在行上——可恢复的那一侧")
        XCTAssertTrue(access.calls.contains(.clearAllSyncIds), "④ 清 `syncId` 那一步确实跑过")
        XCTAssertFalse(ledger.steps.contains("save"),
                       "⑤ 自撤销**删文件**，绝不保存一张空表：空表会让下一次 `load` 再也报不出损")
    }

    /// CASE 9a.2（spec engine 11）— 保留期级联**幂等**，且对活行 **fail-safe**（E11 + A12）。
    ///
    /// 两条判据都成立才删一条游标：(a) `ownerUuid` 指向的那个 Space 的游标带 `purgedAtMs`；
    /// (b) 没有任何活的本地行认领这条身份。命中 (a) 但违反 (b) ⇒ **不删**，就地把
    /// `ownerUuid` 按本地行改写并计一次 `rehomed_cursors`。
    ///
    /// 防的是什么：删掉一条**活行**的游标，那条行此后被差分判成从未发布过，于是下一轮用
    /// `baseVersion == 0` 的 create 盲写覆盖账户上那一条——而服务端的
    /// `ON CONFLICT (client_tag_hash) DO UPDATE` 没有版本检查。
    func testTheRetentionCascadeRehomesLiveCursorsAndDropsOnlyTheOrphans() async throws {
        let spaceAccess = makeSpaceAccess(["space-a": "su-1", "space-b": "su-2"])
        let spaceStore = makeSpaceStore()
        // `su-1` 的 30 天清理已经跑过：phase 1 盖上的 `purgedAtMs` 还在，而
        // `purgeExpired` 自己的守卫是 `purgedAtMs == nil`，所以这个 uuid 再也不会被返回
        // 第二次——级联因此不能挂在「本次返回的 uuid」上。
        spaceStore.table.cursors["su-1"] = purgedSpaceCursor()
        // `b1` 还有一条活的本地行，它现在坐在 `space-b` 里；`b2` 一条行都没有。
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "G1", syncId: "b1", spaceId: "space-b"),
        ])
        let store = MemoryOwnedItemStore()
        store.table.cursors["b1"] = ownedCursor(entityId: "srv-b1", version: 1,
                                                ownerUuid: "su-1")
        store.table.cursors["b2"] = ownedCursor(entityId: "srv-b2", version: 1,
                                                ownerUuid: "su-1")

        let engine = makeEngine(client: FakePhiSyncClient(), access: spaceAccess,
                                store: spaceStore, ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.runRetentionSweep()

        let first = await engine.ownedTableForTesting("bookmarks")
        let firstCounters = await engine.lastOwnedRoundCountersForTesting["bookmarks"]
        XCTAssertEqual(first.cursors["b1"]?.ownerUuid, "su-2",
                       "① 活行那条不删，就地按本地行改写归属")
        XCTAssertNotNil(first.cursors["b1"], "① 那条游标本身还在")
        XCTAssertNil(first.cursors["b2"], "② 没有活行认领的那条被删掉")
        XCTAssertEqual(firstCounters?.rehomedCursors, 1, "③ 改写计一次 `rehomed_cursors`")
        XCTAssertEqual(store.table.cursors["b1"]?.ownerUuid, "su-2", "④ 落了盘")
        XCTAssertNil(store.table.cursors["b2"])

        await engine.runRetentionSweep()

        let second = await engine.ownedTableForTesting("bookmarks")
        let secondCounters = await engine.lastOwnedRoundCountersForTesting["bookmarks"]
        XCTAssertEqual(second.cursors["b1"]?.ownerUuid, "su-2", "⑤ 第二趟结果不变")
        XCTAssertNil(second.cursors["b2"])
        XCTAssertEqual(secondCounters?.rehomedCursors, 0,
                       "⑥ 幂等：游标已经指向一个没被清理的 Space，判据 (a) 不再命中")
    }

    /// CASE 9a.3（spec engine 13）— 退休之后，在飞的那一轮**零写回**。
    ///
    /// 防的是什么：一次 `shutdown()` 之后在飞的那一轮会把它手上那份旧表写回，于是刚被自
    /// 撤销清干净的设备又长出一份游标表——而那份表说「我发布过这些身份」，本机却已经没有
    /// 任何行带这些身份了。
    ///
    /// `Gate` 只有 `open()` 与 `wait()` 两个方法，都要 `await`；`shutdown()` 是
    /// `nonisolated` 且同步生效，所以它在返回时就已经挡住了后面每一个写入口。
    func testARoundInFlightWhenTheDeviceRetiresWritesNothingBack() async throws {
        let spaceAccess = makeSpaceAccess(["space-a": "su-1"])
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "G1", syncId: "b1", spaceId: "space-a"),
        ])
        let store = MemoryOwnedItemStore()
        store.table.cursors["b1"] = ownedCursor(entityId: "srv-b1", version: 1,
                                                ownerUuid: "su-1")
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([
            remoteEntity(envelope(bookmarkPayload(uuid: "b9")), tag: bookmarkTag("b9"),
                         version: 12, entityId: "srv-b9", key: key),
        ])]
        let arrived = Gate()
        let release = Gate()
        client.arrivedInGetUpdates = arrived
        client.getUpdatesGate = release

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        let round = Task { await engine.pullOnce() }
        await arrived.wait()

        // 自撤销那两步，就在这一轮停在 `getUpdates` 里的时候发生。
        engine.shutdown()
        store.deleteFile()
        await release.open()
        await round.value

        let applied = access.calls.contains { if case .apply = $0 { return true } else { return false } }
        XCTAssertTrue(store.deleted, "① 文件没有被在飞那一轮写回来")
        XCTAssertTrue(store.table.cursors.isEmpty, "② 游标表仍然是空的")
        XCTAssertEqual(bookmarkCommits(client).count, 0, "③ 退休之后一条 commit 都没发")
        XCTAssertFalse(applied, "④ 退休之后没有任何落地")
    }

    /// CASE 9a.4（§3.6）— 清理轮丢弃删除定案满 30 天的 tombstone 游标，**两条 kind 都过**。
    ///
    /// 防的是什么：`PhiOwnedItemTable.dropExpiredTombstones` 从 Task 0 起就写好了，但在这一
    /// 条之前**没有任何调用方**——于是每一条被删过的书签 / pin 都在那张表里留一条永久游标，
    /// 而一次大规模整理正是这张表最不该永久增长的时刻。§3.6 的窗口复用
    /// `PhiSpaceSyncState.retentionMs`，与 M1 §2 的恢复窗口是同一个 30 天。
    ///
    /// 边界取在窗口两侧各一毫秒：判据是 `now - deletedAtMs <= retentionMs` 时保留，所以
    /// 「正好满 30 天」那一条是**留着**的，`window + 1` 才丢。
    func testTheSweepDropsOwnedTombstoneCursorsPastTheRetentionWindow() async throws {
        let clock = Clock()
        let nowMs = clock.nowMs
        let window = PhiSpaceSyncState.retentionMs
        let spaceAccess = makeSpaceAccess(["space-a": "su-1"])
        let created = Date(timeIntervalSince1970: 1)

        let bookmarkAccess = FakeBookmarkAccess(rows: [
            .fixture(guid: "G1", syncId: "live", spaceId: "space-a"),
        ])
        let bookmarks = MemoryOwnedItemStore()
        bookmarks.table.cursors["live"] = ownedCursor(entityId: "srv-live", version: 1,
                                                       ownerUuid: "su-1")
        var staleBookmark = ownedCursor(entityId: "srv-old", version: 1, ownerUuid: "su-1")
        staleBookmark.deletedAtMs = nowMs - window - 1
        bookmarks.table.cursors["old"] = staleBookmark
        var freshBookmark = ownedCursor(entityId: "srv-young", version: 1, ownerUuid: "su-1")
        freshBookmark.deletedAtMs = nowMs - window + 1
        bookmarks.table.cursors["young"] = freshBookmark

        let pinAccess = FakePinAccess(scope: .profile, account: .profile, rows: [
            .fixture(lineageId: "LP", guid: "pp", index: 0, createdDate: created),
        ])
        let pins = MemoryOwnedItemStore()
        pins.table.cursors["lp:pu-1"] = ownedCursor(entityId: "srv-lp", version: 1,
                                                     ownerUuid: "pu-1")
        var stalePin = ownedCursor(entityId: "srv-pold", version: 1, ownerUuid: "pu-1")
        stalePin.deletedAtMs = nowMs - window - 1
        pins.table.cursors["pold:pu-1"] = stalePin

        let engine = makeEngine(client: FakePhiSyncClient(), access: spaceAccess,
                                store: makeSpaceStore(), clock: clock,
                                ownedKinds: [bookmarkKind(bookmarkAccess, bookmarks),
                                             pinKind(pinAccess, pins)])
        await engine.setSpaceSyncEnabled(true)
        await engine.runRetentionSweep()

        let bookmarkTable = await engine.ownedTableForTesting("bookmarks")
        let pinTable = await engine.ownedTableForTesting("pins")
        XCTAssertNil(bookmarkTable.cursors["old"], "① 过了窗口的 tombstone 游标整条丢弃")
        XCTAssertNotNil(bookmarkTable.cursors["young"], "② 还在窗口里的留着")
        XCTAssertNotNil(bookmarkTable.cursors["live"],
                        "③ 活游标没有 `deletedAtMs`，一个字节都不动")
        XCTAssertNil(pinTable.cursors["pold:pu-1"], "④ 这一趟走注册清单，两条 kind 都过")
        XCTAssertNotNil(pinTable.cursors["lp:pu-1"])
        XCTAssertNil(bookmarks.table.cursors["old"], "⑤ 落了盘")
        XCTAssertNil(pins.table.cursors["pold:pu-1"])
    }

    // MARK: - CASE 9b.1 – 9b.3：生命周期（pin 半边）

    /// CASE 9b.1 — 复活按 **update** 发，沿用 tombstone 那条实体与版本。
    ///
    /// 作用域来回切一次，身份会原样回来（R-M3-3-23）：`migratePinnedTabs` 对 lineage 是确定
    /// 性的，Profile → Space → Profile 之后 `(LX, pu-1)` 重新出现。中间那一程里它被差分判成
    /// 「本机没有这一行」而发过 tombstone，于是游标带着 `deletedAtMs`——但 `entityId` 与
    /// `version` 按 R-M3-3-7 一并保留。
    ///
    /// 防的是什么：用 `baseVersion == 0` 发 create 会被服务端按版本不匹配拒掉，这条 pin 此后
    /// 每一轮都重试同一个必然失败的提交。
    func testAResurrectedPinPublishesAsAnUpdateOverTheTombstonedVersion() async throws {
        let spaceAccess = makeSpaceAccess()
        // `createdDate` 与 `pinPayload` 的 `createdAtMs`（1_000 **毫秒**）对齐：fixture 的
        // 默认值是 1_000 **秒**，差一千倍，对不齐时投影与基线永远不同。
        let created = Date(timeIntervalSince1970: 1)
        let pinAccess = FakePinAccess(scope: .profile, account: .profile, rows: [
            .fixture(lineageId: "LX", guid: "px", index: 0, createdDate: created),
        ])
        let pinStore = MemoryOwnedItemStore()
        // 一条**已定案删除**的游标：服务端接受过那条 tombstone，所以两份基线都清了、
        // `deletedAtMs` 写下了，而 `entityId` / `version` 原样留着（R-M3-3-7）。
        var tombstoned = PhiOwnedItemCursor()
        tombstoned.entityId = "e-lx"
        tombstoned.version = 42
        tombstoned.deletedAtMs = 900
        tombstoned.ownerUuid = "pu-1"
        pinStore.table.cursors["lx:pu-1"] = tombstoned
        let client = FakePhiSyncClient()

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [pinKind(pinAccess, pinStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let commits = pinCommits(client)
        let counters = await engine.lastOwnedRoundCountersForTesting["pins"]
        let table = await engine.ownedTableForTesting("pins")
        XCTAssertEqual(commits.count, 1, "本轮只有这一条该出门")
        XCTAssertEqual(commits.first?.entityId, "e-lx", "① 沿用 tombstone 那条实体")
        XCTAssertEqual(commits.first?.baseVersion, 42, "② 沿用它的版本，不是 0")
        XCTAssertEqual(commits.first?.deleted, false, "③ 是一条存活的 update，不是 tombstone")
        XCTAssertEqual(counters?.resurrected, 1)
        XCTAssertNil(table.cursors["lx:pu-1"]?.deletedAtMs,
                     "④ 复活被服务端接受之后才清 `deletedAtMs`，否则 §4.2 第 3b 条每轮再复活一次")
    }

    /// CASE 9b.2 — pin 的 purge 级联，判据 (b) 的粒度是**完整身份**而不是裸 lineage
    /// （T9a-2），fail-safe 那一半照旧。
    ///
    /// pin 的**身份本身**带着 owner（`PinKind.identity(of local:)` =
    /// `<lineageKey>:<eligibilityOwner>`），而引擎里每一个 `cursor.ownerUuid` 的写入方都取
    /// `snapshot.ownerUuids[identity]` = 同一个 `eligibilityOwner`——所以一条 pin 游标的
    /// `ownerUuid` 与它自己的键的后半段**永远相等**，rehome 那一支对 pin 结构上到不了。换
    /// owner 按 §7.2 走「旧身份 tombstone + 新身份 create」，不是原地改写归属。
    ///
    /// 三条游标覆盖三条不同的路：
    ///
    /// - `lx:su-1` —— 那条 lineage 还在，但它现在坐在**另一个 owner**（`space-b`）下。按裸
    ///   lineage 判会让它被永久保护住：删不掉（看起来有活行认领）、也改不了（它的身份配不上
    ///   任何本机行），于是永远带着一个指向已清理 Space 的 `ownerUuid`。按完整身份判 ⇒ 删。
    /// - `lz:su-1` —— 行还留在那个被清理的 Space 里（数据级联抛过错，映射与行都留着）。这是
    ///   A12 的 fail-safe：有活行认领这条身份 ⇒ 不删。
    /// - `ly:su-1` —— 本机一条行都没有 ⇒ 两条判据都成立 ⇒ 删。
    ///
    /// 防的是什么：删掉一条**活行**的游标，那条行下一轮被差分判成从未发布过，于是以
    /// `baseVersion == 0` 的 create 盲写覆盖账户上那一条；反过来永远留着一条 owner 已被清理
    /// 的游标，§9.3 的这一趟就白跑了。
    func testThePinRetentionCascadeMatchesOnTheFullIdentityNotTheBareLineage() async throws {
        let spaceAccess = makeSpaceAccess(["space-a": "su-1", "space-b": "su-2"])
        let spaceStore = makeSpaceStore()
        // `su-1` 的 30 天清理已经跑过：phase 1 盖上的 `purgedAtMs` 还在。
        spaceStore.table.cursors["su-1"] = purgedSpaceCursor()
        let created = Date(timeIntervalSince1970: 1)
        // Space 作用域：行的 owner 就是它所在 Space 的 syncUuid。
        let pinAccess = FakePinAccess(scope: .space, account: .space, rows: [
            .fixture(lineageId: "LX", guid: "px", spaceId: "space-b", index: 0,
                     createdDate: created),
            .fixture(lineageId: "LZ", guid: "pz", spaceId: "space-a", index: 1,
                     createdDate: created),
        ])
        let pinStore = MemoryOwnedItemStore()
        for identity in ["lx:su-1", "ly:su-1", "lz:su-1"] {
            pinStore.table.cursors[identity] = ownedCursor(entityId: "srv-" + identity,
                                                           version: 1, ownerUuid: "su-1")
        }

        let engine = makeEngine(client: FakePhiSyncClient(), access: spaceAccess,
                                store: spaceStore, ownedKinds: [pinKind(pinAccess, pinStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.runRetentionSweep()

        let table = await engine.ownedTableForTesting("pins")
        let counters = await engine.lastOwnedRoundCountersForTesting["pins"]
        XCTAssertNil(table.cursors["lx:su-1"],
                     "① 同 lineage、**另一个 owner** 下的行不构成对这条身份的认领 ⇒ 删")
        XCTAssertNil(table.cursors["ly:su-1"], "② 一条行都没有 ⇒ 删")
        XCTAssertNotNil(table.cursors["lz:su-1"],
                        "③ 行还留在那个被清理的 Space 里 ⇒ A12 的 fail-safe，不许删")
        XCTAssertEqual(table.cursors["lz:su-1"]?.ownerUuid, "su-1",
                       "④ 归属没变，也就没有 rehome 可做")
        XCTAssertEqual(counters?.rehomedCursors, 0,
                       "⑤ pin 的身份带着 owner，rehome 那一支对它结构上到不了")
        XCTAssertNil(pinStore.table.cursors["lx:su-1"], "⑥ 落了盘")
        XCTAssertNotNil(pinStore.table.cursors["lz:su-1"])
    }

    /// R-exec-11 ① — Space 作用域下，作用域之外的 profile 备份行**只保护它自己那条身份**。
    ///
    /// 现场（Mac B 2026-09-14）：作用域迁移把 profile 形状的行原地留下当备份，用户随后在
    /// `default-space` 里取消固定了那条 pin。旧口径的定义域是**裸 lineage**，备份行让整条
    /// lineage 看起来「本机还有行」，于是 `(LX, default-space)` 既不会被重新拉回来（游标已
    /// 定案），也永远发不出 tombstone——账户上那条实体就此与本机永久分叉。
    ///
    /// 按完整身份判之后：备份行贡献 `lx:pu-1`，那一条照旧不发 tombstone（R-exec-4 的本意
    /// 成立）；`lx:su-1` 一条行都没有 ⇒ 发 tombstone。
    func testAnOutOfScopeBackupRowProtectsOnlyItsOwnPinIdentity() async throws {
        let spaceAccess = makeSpaceAccess(["space-a": "su-1"])
        let created = Date(timeIntervalSince1970: 1)
        // 当前作用域（Space）里一条行都没有：用户刚把 `space-a` 那一条取消固定了。
        let pinAccess = FakePinAccess(scope: .space, account: .space, rows: [])
        // 迁移原地留下的 profile 形状备份行：`allPins()` 看不见，`allPinRows()` 看得见。
        pinAccess.outOfScopeRows = [
            .fixture(lineageId: "LX", guid: "p-backup", spaceId: nil, index: 0,
                     createdDate: created),
        ]
        let pinStore = MemoryOwnedItemStore()
        pinStore.table.cursors["lx:su-1"] = publishedPinCursor(
            pinPayload(lineage: "lx", ownerKey: "su-1"), entityId: "e-space", owner: "su-1")
        pinStore.table.cursors["lx:pu-1"] = publishedPinCursor(
            pinPayload(lineage: "lx", ownerKey: "pu-1"), entityId: "e-backup", owner: "pu-1")
        let client = FakePhiSyncClient()

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [pinKind(pinAccess, pinStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let tombstones = pinCommits(client).filter(\.deleted)
        let table = await engine.ownedTableForTesting("pins")
        let counters = await engine.lastOwnedRoundCountersForTesting["pins"]
        XCTAssertEqual(tombstones.map(\.entityId), ["e-space"],
                       "① 本机没有行的那条身份发 tombstone")
        XCTAssertEqual(counters?.tombstones, 1)
        XCTAssertNil(table.cursors["lx:pu-1"]?.deleteDecidedAtMs,
                     "② 备份行自己那条身份照旧不被判成删除（R-exec-4）")
    }

    /// R-exec-11 ② — 同一条 lineage 坐在两个 Space 下，删掉其中一个 ⇒ **只有那一条**发
    /// tombstone。
    ///
    /// 防的是什么：换 owner 按 §7.2 是「旧身份 tombstone + 新身份 create」，所以「同 lineage
    /// 在别处还有行」从来都不是「这条身份还活着」的证据。按裸 lineage 判的话，两台设备中的
    /// 任何一台删掉一个 Space 副本，账户上那条实体都永远死不掉，而每台新设备加入都会把它
    /// 拉回来。
    ///
    /// **这一条是防「改过头」的回归护栏，不是那个缺陷的探针**：旧代码在这里也是绿的——
    /// `lx` 当时在 `inScope` 里，于是补壳那一支被跳过，`lx:su-2` 照样发了 tombstone。它钉的
    /// 是新定义域**没有**把兄弟 owner 的游标一起保护起来，而那正是把备份行整批放进定义域
    /// 这件事引入的风险。真正的探针是上面那条 `…BackupRowProtectsOnlyItsOwnPinIdentity`。
    func testDeletingOneSpaceCopyTombstonesOnlyThatPinIdentity() async throws {
        let spaceAccess = makeSpaceAccess(["space-a": "su-1", "space-b": "su-2"])
        let created = Date(timeIntervalSince1970: 1)
        // `space-a` 的副本还在，`space-b` 的那一条刚被取消固定。
        let pinAccess = FakePinAccess(scope: .space, account: .space, rows: [
            .fixture(lineageId: "LX", guid: "px", spaceId: "space-a", index: 0,
                     createdDate: created),
        ])
        let pinStore = MemoryOwnedItemStore()
        pinStore.table.cursors["lx:su-1"] = publishedPinCursor(
            pinPayload(lineage: "lx", ownerKey: "su-1"), entityId: "e-a", owner: "su-1")
        pinStore.table.cursors["lx:su-2"] = publishedPinCursor(
            pinPayload(lineage: "lx", ownerKey: "su-2"), entityId: "e-b", owner: "su-2")
        let client = FakePhiSyncClient()

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [pinKind(pinAccess, pinStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let tombstones = pinCommits(client).filter(\.deleted)
        let table = await engine.ownedTableForTesting("pins")
        let counters = await engine.lastOwnedRoundCountersForTesting["pins"]
        XCTAssertEqual(tombstones.map(\.entityId), ["e-b"],
                       "① 只有行真的没了的那条身份发 tombstone")
        XCTAssertEqual(counters?.tombstones, 1)
        XCTAssertNil(table.cursors["lx:su-1"]?.deleteDecidedAtMs,
                     "② 还有行的那条身份一个字都不动")
    }

    /// R-exec-11 ③ — 远端删掉 `(LX, space-a)`，而 `(LX, space-b)` 还在 ⇒ **只删那一行，而且
    /// 不停放**。
    ///
    /// 这是 §4.5 落地后复核那一半的探针，与上面两条（差分那一半）配成一对。
    ///
    /// 防的是什么：复核一度只按**裸 lineage** 问「本机还有没有这条」，于是同一条 lineage 在
    /// 别的 Space 下还有行时它答「在」。删除那一支把「在」读成「没删成」，于是这条 tombstone
    /// 每一轮都被保守地停放、永远兑现不了——账户上那条实体死不掉，本机那一行却早就删了。
    /// Mac B 2026-09-14 收到 A 那次 Test Space 取消固定之后停放了整整一分钟，就是这条。
    func testARemotePinTombstoneLandsWhileTheSameLineageSurvivesInAnotherSpace() async throws {
        let spaceAccess = makeSpaceAccess(["space-a": "su-1", "space-b": "su-2"])
        let created = Date(timeIntervalSince1970: 1)
        // 同一条 lineage 的两个 Space 副本，各自是一条账户实体（R-M3-3-15）。
        let pinAccess = FakePinAccess(scope: .space, account: .space, rows: [
            .fixture(lineageId: "LX", guid: "pa", spaceId: "space-a", index: 0,
                     createdDate: created),
            .fixture(lineageId: "LX", guid: "pb", spaceId: "space-b", index: 0,
                     createdDate: created),
        ])
        let pinStore = MemoryOwnedItemStore()
        // 两条身份都已发布过：一条 tombstone 没有载荷，身份要靠 §5.1 的 tag 索引反查，而 pin
        // 这一侧索引的种子只有游标键。
        pinStore.table.cursors["lx:su-1"] = publishedPinCursor(
            pinPayload(lineage: "lx", ownerKey: "su-1"), entityId: "e-a", owner: "su-1")
        pinStore.table.cursors["lx:su-2"] = publishedPinCursor(
            pinPayload(lineage: "lx", ownerKey: "su-2"), entityId: "e-b", owner: "su-2")
        let client = FakePhiSyncClient()
        client.scriptedPages = [
            page([remoteTombstone(tag: pinTag("lx", owner: "su-1"), version: 8,
                                  entityId: "e-a")]),
        ]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [pinKind(pinAccess, pinStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let table = await engine.ownedTableForTesting("pins")
        let counters = await engine.lastOwnedRoundCountersForTesting["pins"]
        XCTAssertEqual(pinAccess.lastAppliedOps, [.delete(guid: "pa")],
                       "① 这一批只有那一条删除——同 lineage 跨 owner 不是变体，不重铸")
        XCTAssertEqual(pinAccess.rows.map(\.guid), ["pb"], "② 另一个 Space 的副本原样留着")
        XCTAssertEqual(counters?.applied, 1, "③ 落地了，不是停放")
        XCTAssertEqual(counters?.parked, 0)
        XCTAssertFalse(table.cursors["lx:su-1"]?.pendingTombstone ?? false,
                       "④ 没有被停成工作集的一员")
        XCTAssertNotNil(table.cursors["lx:su-1"]?.deletedAtMs, "⑤ 删除定案")
        XCTAssertNil(table.cursors["lx:su-2"]?.deleteDecidedAtMs,
                     "⑥ 还有行的那条身份一个字都不动")
    }

    /// R-exec-11 ④ — 判据 (b) 的 fail-safe：**归属反查不出来**的备份行退回按 lineage 保护
    /// 它名下的全部游标。
    ///
    /// 与上面 CASE 9b.2 是一对，不是矛盾：那一条说的是「归属**算得出来**、而且是另一个
    /// owner」⇒ 不构成认领；这一条说的是「归属**算不出来**」⇒ 证不了这条行不是那条游标的
    /// 那一行，于是保守地留着。
    ///
    /// 防的是什么：一次 Space 映射抖动（映射表还没落地、或者那个 Space 这一轮解析不出来）
    /// 会让备份行名下的游标被这一趟扫掉，而那条行还在用户的机器上。删错的代价是它下一轮被
    /// 判成从未发布过，以 `baseVersion == 0` 的 create 盲写覆盖账户上那一条；留错的代价只是
    /// 一条游标多活一个保留期。
    func testAnUnresolvableOwnerOnABackupRowKeepsItsLineagesCursors() async throws {
        // `space-gone` **不在**映射表里：那条备份行这一轮算不出归属。
        let spaceAccess = makeSpaceAccess(["space-a": "su-1"])
        let spaceStore = makeSpaceStore()
        // `su-1` 的 30 天清理已经跑过，于是它名下的 pin 游标进入这一趟的候选集。
        spaceStore.table.cursors["su-1"] = purgedSpaceCursor()
        let created = Date(timeIntervalSince1970: 1)
        let pinAccess = FakePinAccess(scope: .space, account: .space, rows: [])
        pinAccess.outOfScopeRows = [
            .fixture(lineageId: "LX", guid: "p-backup", spaceId: "space-gone", index: 0,
                     createdDate: created),
        ]
        let pinStore = MemoryOwnedItemStore()
        pinStore.table.cursors["lx:su-1"] = ownedCursor(entityId: "srv-lx", version: 1,
                                                        ownerUuid: "su-1")

        let engine = makeEngine(client: FakePhiSyncClient(), access: spaceAccess,
                                store: spaceStore, ownedKinds: [pinKind(pinAccess, pinStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.runRetentionSweep()

        let table = await engine.ownedTableForTesting("pins")
        let counters = await engine.lastOwnedRoundCountersForTesting["pins"]
        XCTAssertNotNil(table.cursors["lx:su-1"],
                        "① 归属算不出来的那条行保护住它整条 lineage 的游标")
        XCTAssertEqual(table.cursors["lx:su-1"]?.ownerUuid, "su-1",
                       "② 只认领、不改写归属——来源 1 才是唯一的 `ownerUuid` 写入方")
        XCTAssertEqual(counters?.rehomedCursors, 0)
        // ③是**兜底，不是载荷**：这一趟 `dropped == 0 && rehomed == 0` 时根本不写表，而这条
        // 游标本来就是直接种在内存 store 上的，所以它不可能变红。留着它是为了在「保护住了
        // 但落盘时被顺手清掉」这种将来的改动下有人喊。载荷是①。
        XCTAssertNotNil(pinStore.table.cursors["lx:su-1"], "③ 落了盘")
    }

    /// CASE 9b.3（T6b-1）— 同 rank 的两条 pin 按 **`pin_uuid`**（归一后的 lineage）破平手，
    /// **不按本机 guid**。
    ///
    /// 防的是什么：用本机 guid 破平手是**设备相关**的——`guid` 是每台设备各铸的，所以两台
    /// 机器对同一对 pin 排出相反的顺序，各自把自己那份 rank 发回账户，于是它们**互相覆盖、
    /// 永不收敛**：每一轮各发一条 commit，用户看到两台机器上的 pin 顺序不停对调。spec §2.4
    /// 指定 `pin_uuid` 正是因为它是唯一两端都认得的键。
    ///
    /// 两台设备跑在同一个 `defaults` suite 上：假 client 的 `scriptedPages` 是每个 client
    /// 自己的、按次序弹出，与 marker 无关，所以第一台留下的 marker 影响不到第二台。
    func testEqualRanksBreakTheTieOnPinUuidNotTheDeviceLocalGuid() async throws {
        /// 一台设备落地一轮，交回「lineage -> 落地之后那一行的 index」。
        func land(guidForLA: String, guidForLB: String) async -> [String: Int] {
            let created = Date(timeIntervalSince1970: 1)
            let access = FakePinAccess(scope: .profile, account: .profile, rows: [
                .fixture(lineageId: "LA", guid: guidForLA, index: 0, createdDate: created),
                .fixture(lineageId: "LB", guid: guidForLB, index: 1, createdDate: created),
            ])
            let store = MemoryOwnedItemStore()
            // 基线 rank 各不相同，入站的那一份把两条都改成**同一个** rank ⇒ `plan` 为两条
            // 都产出 `.move`，于是这个 owner 进 `touchedOwners`、整组走一次稠密置换。
            store.table.cursors["la:pu-1"] = publishedPinCursor(
                pinPayload(lineage: "la", rank: "V"), entityId: "srv-la")
            store.table.cursors["lb:pu-1"] = publishedPinCursor(
                pinPayload(lineage: "lb", rank: "W"), entityId: "srv-lb")
            let client = FakePhiSyncClient()
            client.scriptedPages = [page([
                remoteEntity(envelope(pinPayload(lineage: "la", rank: "K", rankStamp: 500)),
                             tag: pinTag("la"), version: 10, entityId: "srv-la", key: key),
                remoteEntity(envelope(pinPayload(lineage: "lb", rank: "K", rankStamp: 500)),
                             tag: pinTag("lb"), version: 11, entityId: "srv-lb", key: key),
            ])]

            let engine = makeEngine(client: client, access: makeSpaceAccess(),
                                    store: makeSpaceStore(),
                                    ownedKinds: [pinKind(access, store)])
            await engine.setSpaceSyncEnabled(true)
            await engine.pullOnce()

            var out: [String: Int] = [:]
            for row in access.rows { out[row.lineageId] = row.index }
            return out
        }

        // 第一台：本机 guid 顺序与 lineage 顺序**一致**。
        let deviceA = await land(guidForLA: "p-1", guidForLB: "p-2")
        // 第二台：同一对 pin，本机 guid 顺序**相反**。
        let deviceB = await land(guidForLA: "p-9", guidForLB: "p-0")

        XCTAssertEqual(deviceA["LA"], 0, "① 按 `pin_uuid` 排：la < lb")
        XCTAssertEqual(deviceA["LB"], 1)
        XCTAssertEqual(deviceB["LA"], 0, "② guid 顺序相反，算出来的次序必须一模一样")
        XCTAssertEqual(deviceB["LB"], 1)
        XCTAssertEqual(deviceA, deviceB, "③ 两台设备对同一对 pin 收敛到同一个次序")
    }

    // MARK: - CASE 9b.4：轮中作用域迁移（R-exec-12 / D-A）

    /// 一台正要跟随迁移的机器：Space 作用域、账户也是 Space，两条 Space 形状的行。
    /// 入站的是**对端已经翻到 Profile 之后**发布的那两条实体（owner 是 profile uuid）。
    private func migratingPinAccess() -> FakePinAccess {
        // `createdDate` 与 `pinPayload` 的 `createdAtMs`（1_000 **毫秒**）对齐，理由同上。
        let created = Date(timeIntervalSince1970: 1)
        return FakePinAccess(scope: .space, account: .space, rows: [
            .fixture(lineageId: "LX", guid: "px-space", spaceId: "space-a",
                     profileId: "Default", index: 0, createdDate: created),
            .fixture(lineageId: "LY", guid: "py-space", spaceId: "space-a",
                     profileId: "Default", index: 1, createdDate: created),
        ])
    }

    /// Task 8 的跟随迁移落地之后那台机器的样子：同两条 lineage，Profile 形状，新的物理
    /// guid（`migratePinnedTabs` 重建整批行），两个作用域都成了 `.profile`。
    @MainActor
    private func applyFollowerMigration(_ access: FakePinAccess) {
        let created = Date(timeIntervalSince1970: 1)
        access.scope = .profile
        access.account = .profile
        access.rows = [
            .fixture(lineageId: "LX", guid: "px-profile", spaceId: nil,
                     profileId: "Default", index: 0, createdDate: created),
            .fixture(lineageId: "LY", guid: "py-profile", spaceId: nil,
                     profileId: "Default", index: 1, createdDate: created),
        ]
        // 迁移重建了整批物理行，本轮那份快照与它已经没有关系了（生产实现只清不重读）。
        access.beginRound()
    }

    /// 对端翻到 Profile 之后发布的那两条实体，owner 是 profile uuid。
    private func profileScopedPinPage() -> FakePhiSyncClient.Page {
        page([
            remoteEntity(envelope(pinPayload(lineage: "lx", ownerKey: "pu-1")),
                         tag: pinTag("lx", owner: "pu-1"), version: 10, entityId: "srv-lx",
                         key: key),
            remoteEntity(envelope(pinPayload(lineage: "ly", ownerKey: "pu-1")),
                         tag: pinTag("ly", owner: "pu-1"), version: 11, entityId: "srv-ly",
                         key: key),
        ])
    }

    /// CASE 9b.4（R-exec-12 / D-A）— 作用域在**轮首取样之后、落地之前**动了 ⇒ 这一轮按
    /// §7.3 处理：入站全部停放、一条都不落、一条都不发。
    ///
    /// 现场（Mac B 2026-09-14，build 821）：`beginOwnedRound()` 在 `pull` 翻第一页**之前**
    /// 冻结 `state.locals` 与两个作用域，而作用域变更正是**跟着那一页到达的**——远端设置落地
    /// 把镜像键改成 `profile`，Task 8 的跟随迁移在一个 detached `Task` 里 15 ms 后重建了全部
    /// 物理行。落地段执行时库已是 Profile 形状，而 `state.locals` 还是 Space 形状，于是入站
    /// 实体的 `(lineage, profileUuid)` 配不上任何一条本机身份，`landPins` 走 create 那一支，
    /// 在迁移刚建好的行**旁边**又建了一遍。§7.3 原本的守卫挡不住：两个作用域都是在它们还
    /// 一致的时候取样的。
    ///
    /// 防的是什么：那四条重复行是**不可逆**的——下一轮 A11 给它们各铸一条新 lineage，账户上
    /// 从此多出四条用户从来没有过的 pin，而本仓库里没有任何东西会把两条 lineage 再并回去。
    func testAScopeMigrationLandingMidRoundParksTheInboundInsteadOfDuplicatingRows() async throws {
        let pinAccess = migratingPinAccess()
        // 轮首取样**之后**就地跑一次跟随迁移：`beginRound` 是第 1 次 `accountScope()` 读。
        pinAccess.midRoundMigration = (onAccountScopeRead: 1, run: applyFollowerMigration)
        let pinStore = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.scriptedPages = [profileScopedPinPage()]

        let engine = makeEngine(client: client, access: makeSpaceAccess(["space-a": "su-1"]),
                                store: makeSpaceStore(),
                                ownedKinds: [pinKind(pinAccess, pinStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let counters = await engine.lastOwnedRoundCountersForTesting["pins"]
        let table = await engine.ownedTableForTesting("pins")
        XCTAssertEqual(counters?.applied, 0, "① 一条都没落")
        XCTAssertEqual(counters?.parked, 2, "② 两条入站全部停放")
        XCTAssertEqual(counters?.scopeMismatch, true,
                       "③ §11.2 的 `scope_mismatch`：这一轮的 pin 段是被作用域挡下的")
        XCTAssertEqual(pinAccess.rows.count, 2,
                       "④ 载荷：库里仍然只有迁移产出的那两条行，没有在它们旁边再建一遍")
        XCTAssertEqual(Set(pinAccess.rows.map(\.guid)), ["px-profile", "py-profile"],
                       "⑤ 留下的是迁移建的那两条，不是落地新建的")
        XCTAssertFalse(pinAccess.calls.contains { if case .apply = $0 { return true }
                                                  else { return false } },
                       "⑥ 落地段整段没跑——A11 的重铸同样按 guid 定位，而那批行已经被换掉了")
        XCTAssertEqual(counters?.relineaged, 0)
        XCTAssertEqual(counters?.pushed, 0, "⑦ 发布半边整段跳过")
        XCTAssertTrue(pinCommits(client).isEmpty)
        XCTAssertNotNil(table.cursors["lx:pu-1"]?.pendingApply,
                        "⑧ 停放不丢东西：marker 已经推过那一页，载荷记在游标上")
        XCTAssertNotNil(table.cursors["ly:pu-1"]?.pendingApply)
        // A6：**停放同样收割服务端三元组。** 这两条身份的游标是这一轮由停放**新建**出来的，
        // 而共享 marker 已经推过那一页 —— 不在这里收割，这一版实体永不重投，游标再也补不上
        // 身份（Mac B 2026-09-14，build 822）。
        XCTAssertEqual(table.cursors["lx:pu-1"]?.entityId, "srv-lx",
                       "⑨ 停放建出来的游标带着到达那一条的 entity id")
        XCTAssertEqual(table.cursors["lx:pu-1"]?.version, 10)
        XCTAssertEqual(table.cursors["ly:pu-1"]?.entityId, "srv-ly")
        XCTAssertEqual(table.cursors["ly:pu-1"]?.version, 11)
    }

    /// CASE 9b.4b（R-exec-12）— 上一条的下一轮：停放的两条以 **update** 落地，不是 create，
    /// 而且没有任何重铸。
    ///
    /// 这是 D-A 的收敛证明。下一轮的 `beginRound` 读到的是一致的「新行 + 新作用域」，于是
    /// `(lineage, profileUuid)` 配得上本机行，落地走的是「先按身份找本机行，找不到才 create」
    /// 的前半支。本机行数自始至终是 2。
    func testTheParkedInboundLandsAsUpdatesOnTheNextRoundWithNoRelineage() async throws {
        let pinAccess = migratingPinAccess()
        pinAccess.midRoundMigration = (onAccountScopeRead: 1, run: applyFollowerMigration)
        let pinStore = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        // 第二页是空的：停放项自己会被重试，不需要对端再发一次。
        client.scriptedPages = [profileScopedPinPage(), page([])]

        let engine = makeEngine(client: client, access: makeSpaceAccess(["space-a": "su-1"]),
                                store: makeSpaceStore(),
                                ownedKinds: [pinKind(pinAccess, pinStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()
        await engine.pullOnce()

        let counters = await engine.lastOwnedRoundCountersForTesting["pins"]
        let table = await engine.ownedTableForTesting("pins")
        XCTAssertEqual(counters?.applied, 2, "① 第二轮把停放的两条落下去")
        XCTAssertEqual(counters?.relineaged, 0,
                       "② 没有任何重铸——本机从头到尾每条身份只有一行")
        XCTAssertEqual(counters?.scopeMismatch, false, "③ 作用域这一轮稳住了")
        XCTAssertEqual(pinAccess.rows.count, 2, "④ 载荷：本机行数始终是 2")
        XCTAssertEqual(Set(pinAccess.rows.map(\.guid)), ["px-profile", "py-profile"],
                       "⑤ 落的是那两条既有行，不是两条新建的")
        XCTAssertFalse(pinAccess.lastAppliedOps.contains { if case .create = $0 { return true }
                                                           else { return false } },
                       "⑥ 落地走的是 update 那一支，不是 create")
        XCTAssertTrue(pinAccess.lastAppliedOps.contains { if case .update = $0 { return true }
                                                          else { return false } })
        XCTAssertNil(table.cursors["lx:pu-1"]?.pendingApply, "⑦ 停放解开了")
        XCTAssertNil(table.cursors["ly:pu-1"]?.pendingApply)
        // **落地之后的游标必须与「直接落地的那一条」逐字一样。** 这一轮没有任何实体到达
        // （第二页是空的），所以 `plan.harvest` 里一条记录都没有：三元组只能是停放那一轮
        // 留下的。少了它，这两条身份此后既发不出 tombstone 也只能以 `baseVersion == 0`
        // 盲写发布。
        XCTAssertEqual(table.cursors["lx:pu-1"]?.entityId, "srv-lx",
                       "⑧ 停放落地之后 entity id 还在")
        XCTAssertEqual(table.cursors["lx:pu-1"]?.version, 10, "⑨ 版本就是到达那一条的版本")
        XCTAssertEqual(table.cursors["ly:pu-1"]?.entityId, "srv-ly")
        XCTAssertEqual(table.cursors["ly:pu-1"]?.version, 11)
        XCTAssertNotNil(table.cursors["lx:pu-1"]?.reconciled, "⑩ 基线照常写下")
    }

    /// CASE 9b.4e（R-exec-1 / A6）— 停放落地之后**本机取消固定**：发出**一条** tombstone，
    /// 带着那条实体真正的 entity id 与基版本。
    ///
    /// 这是 9b.4b 的下一步，也是这条缺陷在现场的样子（Mac B 2026-09-14，build 822，步骤
    /// 6c）：作用域迁移让每条 pin 换了身份，新身份的游标全部由**停放**新建，而停放那一支
    /// 不收割服务端三元组。七条游标于是以 `entityId == "" / version == 0` 落盘并**一直**
    /// 保持这个样子——共享 marker 早已推过那一页，那一版实体永不重投。用户随后在 Test2 里
    /// 取消固定一条 pin，`§4.7` 的差分照常判出删除，而 §9.1 的第二道闸看见 `entityId == ""`
    /// 就把它就地收尾：**一条 tombstone 都没发出去**，对端那一条 pin 从此没有任何设备能删掉。
    ///
    /// 防的是什么：断言在游标上（9b.4b）挡不住这一条——游标坏掉的后果要等到**下一次本机
    /// 删除**才现形，而那正是用户能看见的那一刻。
    func testAnUnpinAfterAParkedLandingTombstonesTheEntityItLandedFrom() async throws {
        let pinAccess = migratingPinAccess()
        pinAccess.midRoundMigration = (onAccountScopeRead: 1, run: applyFollowerMigration)
        let pinStore = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        // 三轮：① 作用域挡下 ⇒ 全部停放；② 停放落地；③ 本机取消固定 ⇒ 差分发 tombstone。
        client.scriptedPages = [profileScopedPinPage(), page([]), page([])]
        // 账户上那两行确实在，id 与版本与脚本页里那两条实体对齐——第 ③ 轮那条 tombstone 走
        // 的是假件的 update 支（带 id + 基版本），它要认得出这一行才答得出 `.applied`。
        client.seed(tagHash: pinHash("lx", owner: "pu-1"), ciphertext: Data(), version: 10,
                    entityId: "srv-lx")
        client.seed(tagHash: pinHash("ly", owner: "pu-1"), ciphertext: Data(), version: 11,
                    entityId: "srv-ly")

        let engine = makeEngine(client: client, access: makeSpaceAccess(["space-a": "su-1"]),
                                store: makeSpaceStore(),
                                ownedKinds: [pinKind(pinAccess, pinStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()
        await engine.pullOnce()

        // 用户在 UI 上取消固定 LX：本机那一行没了，LY 原样留着。
        pinAccess.rows.removeAll { $0.lineageId == "LX" }
        await engine.pullOnce()

        let tombstones = pinCommits(client).filter(\.deleted)
        let table = await engine.ownedTableForTesting("pins")
        let counters = await engine.lastOwnedRoundCountersForTesting["pins"]
        XCTAssertEqual(tombstones.count, 1, "① 恰好一条 tombstone")
        XCTAssertEqual(tombstones.first?.entityId, "srv-lx",
                       "② 带的是那条实体的 entity id，不是空串")
        XCTAssertEqual(tombstones.first?.baseVersion, 10,
                       "③ 基版本是停放那一轮收割到的版本")
        XCTAssertEqual(tombstones.first?.clientTagHash, pinHash("lx", owner: "pu-1"))
        XCTAssertEqual(counters?.tombstones, 1)
        XCTAssertNotNil(table.cursors["lx:pu-1"]?.deletedAtMs,
                        "④ 服务端接受之后删除定案")
        XCTAssertNil(table.cursors["ly:pu-1"]?.deletedAtMs, "⑤ 还有行的那条一个字都不动")
    }

    /// CASE 9b.4f（R-exec-1）— **已经坏掉的表**的补键自愈：一条「有基线、没有 entityId」
    /// 的游标被无条件排进发布切片，经 client tag 的唯一索引认回账户上那一行。
    ///
    /// 为什么需要它：9b.4e 修的是「不再写出这种游标」，而 build 822 已经在真机上写下了七条。
    /// 那些机器**自己修不好**——那一版实体永不重投，快照字节又恰好等于基线（那条行就是从
    /// 账户上落下来的），于是既收不到新的 id，也没有任何东西会让它重发。
    ///
    /// 断言③是这条自愈的要害：服务端的 `ON CONFLICT (client_tag_hash) DO UPDATE` 按 tag
    /// 认行，所以这次 create **打在账户上那一行上**，回来的是它原本的 id，不是一条新实体。
    func testABaselinedCursorWithNoEntityIdRepublishesToReKeyItself() async throws {
        let created = Date(timeIntervalSince1970: 1)
        let pinAccess = FakePinAccess(scope: .space, account: .space, rows: [
            .fixture(lineageId: "LX", guid: "px", spaceId: "space-a", index: 0,
                     createdDate: created),
        ])
        let pinStore = MemoryOwnedItemStore()
        // build 822 写出来的那种游标：基线有、归属有，服务端三元组是空的。
        pinStore.table.cursors["lx:su-1"] = publishedPinCursor(
            pinPayload(lineage: "lx", ownerKey: "su-1"), entityId: "", version: 0, owner: "su-1")
        let client = FakePhiSyncClient()
        // 账户上那一行确实在，id 是 `srv-lx`。**空页**：它这一轮不会被投递（marker 早已
        // 推过那一页），所以游标补不到三元组的唯一通路就是发布那一侧。
        client.seed(tagHash: pinHash("lx", owner: "su-1"), ciphertext: Data(), version: 10,
                    entityId: "srv-lx")
        client.scriptedPages = [page([])]

        let engine = makeEngine(client: client, access: makeSpaceAccess(["space-a": "su-1"]),
                                store: makeSpaceStore(),
                                ownedKinds: [pinKind(pinAccess, pinStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let commits = pinCommits(client)
        let table = await engine.ownedTableForTesting("pins")
        XCTAssertEqual(commits.count, 1,
                       "① 快照字节等于基线，可它照样发了一条——补键是发布的唯一通路")
        XCTAssertNil(commits.first?.entityId, "② 以 create 出门：本机手上没有 id 可带")
        XCTAssertEqual(commits.first?.deleted, false)
        XCTAssertEqual(table.cursors["lx:su-1"]?.entityId, "srv-lx",
                       "③ 认回的是账户上那一行原本的 id，不是一条新实体")
        XCTAssertGreaterThan(table.cursors["lx:su-1"]?.version ?? 0, 0, "④ 版本也补上了")
        XCTAssertNotNil(table.cursors["lx:su-1"]?.reconciled)
        XCTAssertNil(table.cursors["lx:su-1"]?.rekeyRejectRounds, "⑤ 补成了 ⇒ 连败计数清零")
    }

    /// CASE 9b.4g（R-exec-13 / F-PK-2）— 补键**连续三轮被拒**之后不再重新武装：恰好三次
    /// 提交，之后一条都不发。
    ///
    /// 防的是什么：补键是发布段里唯一一条「快照字节与基线相等也照发」的通路。服务端始终判
    /// 非法时（那条 tag 在账户上真的不存在、或者服务端侧另有原因），没有放弃的实现会把它变成
    /// 一条每 60 s 一次、永远不会好的提交——M3-2 §5.1 给 tombstone 定的三次放弃规则针对的是
    /// 同一件事。
    ///
    /// 放弃的**动作**与 tombstone 那一条相反，断言④⑤钉的就是这点：本机那一行还在，所以
    /// `reconciled` 与 `deletedAtMs` 一个字都不许动——放弃只关掉这条自愈通路。
    func testAGivenUpReKeyStopsCommittingAfterThreeRejections() async throws {
        let created = Date(timeIntervalSince1970: 1)
        let pinAccess = FakePinAccess(scope: .space, account: .space, rows: [
            .fixture(lineageId: "LX", guid: "px", spaceId: "space-a", index: 0,
                     createdDate: created),
        ])
        let pinStore = MemoryOwnedItemStore()
        pinStore.table.cursors["lx:su-1"] = publishedPinCursor(
            pinPayload(lineage: "lx", ownerKey: "su-1"), entityId: "", version: 0, owner: "su-1")
        let client = FakePhiSyncClient()
        // 这条 tag 的每一次提交都答 INVALID_MESSAGE，账户侧一个字节都不动。
        client.refuseCommitsForTagHashes = [pinHash("lx", owner: "su-1")]
        // 五轮，每轮一页空的：`stored` 是空的，不能让任何一轮回退到它去读。
        client.scriptedPages = Array(repeating: page([]), count: 5)

        let engine = makeEngine(client: client, access: makeSpaceAccess(["space-a": "su-1"]),
                                store: makeSpaceStore(),
                                ownedKinds: [pinKind(pinAccess, pinStore)])
        await engine.setSpaceSyncEnabled(true)
        for _ in 0..<5 { await engine.pullOnce() }

        let table = await engine.ownedTableForTesting("pins")
        XCTAssertEqual(pinCommits(client).count, 3,
                       "① 三轮之后不再重新武装——第四、第五轮一条都不发")
        XCTAssertEqual(table.cursors["lx:su-1"]?.rekeyRejectRounds, 3, "② 放弃记在游标上")
        XCTAssertEqual(table.cursors["lx:su-1"]?.entityId, "", "③ 仍然没有 id，补键确实没成")
        XCTAssertNotNil(table.cursors["lx:su-1"]?.reconciled,
                        "④ 放弃**不动基线**：本机那一行还在，它不是一次删除")
        XCTAssertNil(table.cursors["lx:su-1"]?.deletedAtMs,
                     "⑤ 也不写 `deletedAtMs`——与 tombstone 那一条的放弃方向相反")
        XCTAssertEqual(pinAccess.rows.count, 1, "⑥ 载荷：本机那一行自始至终没被碰过")
    }

    /// CASE 9b.4h（R-exec-13 / F-PK-4）— 对端的一次更新把身份收割回来 ⇒ 连败计数清零，
    /// **后来那一次损坏重新拿到完整的三次机会**。
    ///
    /// 防的是什么：连败计数记的是「补键这条通路连着失败了几轮」。一条被入站 harvest 收割回
    /// 身份的游标此刻根本不需要补键——它已经有 id 了；旧账留着，这条身份**下一次**丢掉 id
    /// （一次 `.invalidMessage`、或者 NOT_MY_BIRTHDAY 之后的 reset）时三次机会里已经用掉了
    /// 两次，于是它一轮就放弃，而那一轮的失败与很久以前那两次毫无关系。差别正好在提交条数
    /// 上：不清零 ⇒ 第二段只试一次（总共四条）。
    ///
    /// 脚本分四段，每段的意图写在下面的注释里；第二段那条入站实体**与基线逐字相同**，于是
    /// `plan` 一条 step 都不产、落地什么都不改——这一段要隔离的就是 harvest 本身。
    func testAHarvestedEntityIdClearsTheRekeyStrikes() async throws {
        let created = Date(timeIntervalSince1970: 1)
        let original = PhiLocalPin.fixture(lineageId: "LX", guid: "px", spaceId: "space-a",
                                           index: 0, createdDate: created)
        let pinAccess = FakePinAccess(scope: .space, account: .space, rows: [original])
        let pinStore = MemoryOwnedItemStore()
        pinStore.table.cursors["lx:su-1"] = publishedPinCursor(
            pinPayload(lineage: "lx", ownerKey: "su-1"), entityId: "", version: 0, owner: "su-1")
        let client = FakePhiSyncClient()
        client.refuseCommitsForTagHashes = [pinHash("lx", owner: "su-1")]
        let arrival = page([
            remoteEntity(envelope(pinPayload(lineage: "lx", ownerKey: "su-1")),
                         tag: pinTag("lx", owner: "su-1"), version: 10, entityId: "srv-lx",
                         key: key),
        ])
        // 八轮：2 段一 + 1 段二 + 1 段三 + 3 段四 + 1 收尾。
        client.scriptedPages = [page([]), page([]), arrival] + Array(repeating: page([]), count: 5)

        let engine = makeEngine(client: client, access: makeSpaceAccess(["space-a": "su-1"]),
                                store: makeSpaceStore(),
                                ownedKinds: [pinKind(pinAccess, pinStore)])
        await engine.setSpaceSyncEnabled(true)

        // 段一：补键连着被拒两轮 ⇒ 两条提交、两次连败。
        await engine.pullOnce()
        await engine.pullOnce()
        var table = await engine.ownedTableForTesting("pins")
        XCTAssertEqual(pinCommits(client).count, 2, "① 两轮各试一次")
        XCTAssertEqual(table.cursors["lx:su-1"]?.rekeyRejectRounds, 2, "② 两次连败")

        // 段二：对端的一次更新到达 ⇒ harvest 把身份收割回来。
        await engine.pullOnce()
        table = await engine.ownedTableForTesting("pins")
        XCTAssertEqual(table.cursors["lx:su-1"]?.entityId, "srv-lx", "③ 身份回来了")
        XCTAssertNil(table.cursors["lx:su-1"]?.rekeyRejectRounds, "④ 连败计数跟着清零")
        XCTAssertEqual(pinCommits(client).count, 2,
                       "⑤ 这一轮不发：有 id 了不必补键，内容也与基线相同")

        // 段三：**后来那一次损坏**。用户改了标题 ⇒ 一次普通的内容发布，被服务端判非法 ⇒
        // 身份又没了（`applyOwnedCommitOutcome` 的 `.invalidMessage` 活体支）。这一条不是
        // 补键，所以它自己不该记一次连败。
        pinAccess.rows[0].title = "改过的标题"
        await engine.pullOnce()
        table = await engine.ownedTableForTesting("pins")
        XCTAssertEqual(pinCommits(client).count, 3, "⑥ 内容发布出门一次")
        XCTAssertEqual(table.cursors["lx:su-1"]?.entityId, "", "⑦ 被判非法 ⇒ 身份又没了")
        XCTAssertNil(table.cursors["lx:su-1"]?.rekeyRejectRounds,
                     "⑧ 普通内容发布被拒**不**记补键的账")
        // 标题改回去：此后快照字节与基线相等，于是补键成了唯一还会发东西的通路——段四数的
        // 才是补键自己的次数。
        pinAccess.rows[0] = original

        // 段四：完整的三次机会，然后放弃。
        for _ in 0..<4 { await engine.pullOnce() }
        table = await engine.ownedTableForTesting("pins")
        XCTAssertEqual(pinCommits(client).count, 6,
                       "⑨ 3 + 3：损坏之后又试满三次（不清零的话这里只会多一条，总共四条）")
        XCTAssertEqual(table.cursors["lx:su-1"]?.rekeyRejectRounds, 3, "⑩ 三次之后才放弃")
        XCTAssertNotNil(table.cursors["lx:su-1"]?.reconciled, "⑪ 放弃仍然不动基线")
        XCTAssertEqual(pinAccess.rows.count, 1)
    }

    /// CASE 9b.4c（R-exec-12 / §11.2）— **纯 push 轮**：没有任何入站，于是 `plan` 与落地都
    /// 不跑，`pinSnapshot` 那一处复查是这一轮唯一能看见作用域移动的地方。
    ///
    /// 为什么这条单列：现场那一分钟的 25 轮全是这一种（协调器的 `UserDefaults` 2 s 去抖发的
    /// push 轮，`PhiChromiumCoordinator.swift:601-610`）。只在 `plan` 那一路复查的实现在这条
    /// 用例上必红——它会把一批**迁移前**的行连同新鲜的 `now` 发回账户，而 §11.2 的
    /// `scope_mismatch` 仍然印 false，一个计数器都不变色。
    func testAPushOnlyRoundSkipsThePublishWhenTheScopeMovesUnderIt() async throws {
        let pinAccess = migratingPinAccess()
        // 1 = `beginRound`，2 = `pinSnapshot`（`plan` 与落地这一轮都不跑）。挂在 1 上 ⇒ 轮首
        // 两个值取样一致，迁移紧随其后。
        pinAccess.midRoundMigration = (onAccountScopeRead: 1, run: applyFollowerMigration)
        let pinStore = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        // 空页：一条入站都没有 ⇒ `applyOwnedKind` 在 `plan` 之前就返回。
        client.scriptedPages = [page([])]

        let engine = makeEngine(client: client, access: makeSpaceAccess(["space-a": "su-1"]),
                                store: makeSpaceStore(),
                                ownedKinds: [pinKind(pinAccess, pinStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let counters = await engine.lastOwnedRoundCountersForTesting["pins"]
        XCTAssertEqual(counters?.scopeMismatch, true,
                       "① 发布段复查时作用域已经动了 ⇒ 整段跳过**并记账**")
        XCTAssertEqual(counters?.pushed, 0)
        XCTAssertTrue(pinCommits(client).isEmpty,
                      "② 载荷：两条迁移前的行一条都没有被发回账户——不挡的话它们本来会发")
    }

    /// CASE 9b.4d — 上一条的对照：作用域**没动**的同一个纯 push 轮照常发布两条。
    ///
    /// 防的是什么：9b.4c 断言的是「一条都没发」。若这条 kind 在这个 fixture 下本来就发不出
    /// 东西（门没开、映射缺一半、行被过滤掉），那条断言恒真、什么都守不住。
    func testThePushOnlyControlRoundStillPublishesWhenTheScopeHoldsStill() async throws {
        let pinAccess = migratingPinAccess()        // 钩子不挂：作用域自始至终是 `.space`
        let pinStore = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([])]

        let engine = makeEngine(client: client, access: makeSpaceAccess(["space-a": "su-1"]),
                                store: makeSpaceStore(),
                                ownedKinds: [pinKind(pinAccess, pinStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let counters = await engine.lastOwnedRoundCountersForTesting["pins"]
        XCTAssertEqual(counters?.scopeMismatch, false)
        XCTAssertEqual(pinCommits(client).count, 2,
                       "作用域稳住时这一轮本来就该发两条——9b.4c 挡掉的正是这两条")
    }
}

// MARK: - 外部评审回归：未发布的本机编辑

extension PhiSyncEngineOwnedItemsTests {

    /// spec §12.1 引擎第 8 条的另一半：本机那处**还没推送**的改名，遇上对端改了同一条实体
    /// 的**另一个**字段（第 8 条里对端做的是移动，于是根本不产出 `.update`，这条缺陷看不见）。
    ///
    /// 防的是什么：合并若拿 `reconciled` 当本机那一侧，那次改名在参与比较的两条实体里没有
    /// 任何代表，合并结果带回基线里的**旧标题**，而 `.update` 的补丁四个内容字段一起写
    /// ——用户刚改的名字被静默改写，没有 commit、没有计数。
    func testAnUnpublishedLocalRenameSurvivesARemoteEditOfAnotherField() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "G1", syncId: "b1", spaceId: "s-1", title: "本机新标题",
                     contentUpdatedDate: Date(timeIntervalSince1970: 500)),
        ])
        let store = MemoryOwnedItemStore()
        // 账户与基线上都还是旧标题：那次改名本机还没发出去。
        store.table.cursors["b1"] = publishedCursor(alignedPayload(uuid: "b1", title: "旧标题"),
                                                    entityId: "srv-b1", version: 7)
        let client = FakePhiSyncClient()
        // 对端改的是 URL，标题一个字没动（内容字段共用一个戳，所以标题也被重盖了一次）。
        client.scriptedPages = [oneEntityPage(
            bookmarkPayload(uuid: "b1", title: "旧标题", url: "https://peer.example",
                            contentStamp: 2_000_000, createdAtMs: Self.rowCreatedAtMs),
            uuid: "b1", version: 42, entityId: "srv-b1")]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let row = access.rows.first { $0.guid == "G1" }
        XCTAssertEqual(row?.title, "本机新标题", "① 本机那次还没发布的改名不被改写")
        XCTAssertEqual(row?.url.absoluteString, "https://peer.example",
                       "② 对端那次真实编辑照常落地")
        let commits = bookmarkCommits(client)
        let sent = commits.first.flatMap(committedBookmark)
        XCTAssertEqual(commits.count, 1, "③ 本机赢下的字段要回账户（`mustRepublish`）")
        XCTAssertEqual(sent?.title.stringValue, "本机新标题", "③ 带的是本机那个标题")
        XCTAssertEqual(sent?.url.stringValue, "https://peer.example", "③ 也带着对端那个 URL")
        XCTAssertEqual(commits.first?.baseVersion, 42, "④ 发布打在刚拉到的那一版上")
    }

    /// pin 那一侧的同一条（评审说两种 kind 都能复现）。
    func testAnUnpublishedLocalPinRenameSurvivesARemoteUrlEdit() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakePinAccess(scope: .profile, account: .profile, rows: [
            .fixture(lineageId: "LX", guid: "P1", spaceId: nil, profileId: "Default",
                     title: "本机新标题", createdDate: Date(timeIntervalSince1970: 1_000),
                     contentUpdatedDate: Date(timeIntervalSince1970: 500)),
        ])
        let store = MemoryOwnedItemStore()
        store.table.cursors["lx:pu-1"] = publishedPinCursor(
            pinPayload(lineage: "lx", title: "旧标题", createdAtMs: 1_000_000),
            entityId: "srv-p1", version: 7)
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([
            remoteEntity(envelope(pinPayload(lineage: "lx", title: "旧标题",
                                             url: "https://peer.example",
                                             contentStamp: 2_000_000, createdAtMs: 1_000_000)),
                         tag: pinTag("lx"), version: 42, entityId: "srv-p1", key: key),
        ])]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [pinKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let row = access.rows.first { $0.guid == "P1" }
        XCTAssertEqual(row?.title, "本机新标题", "① 未发布的本机改名不被改写")
        XCTAssertEqual(row?.url.absoluteString, "https://peer.example", "② 对端的编辑照常落地")
        let sent = pinCommits(client).first.flatMap(committedPin)
        XCTAssertEqual(pinCommits(client).count, 1, "③ 本机赢下的字段要回账户")
        XCTAssertEqual(sent?.title.stringValue, "本机新标题")
    }
}

// MARK: - 外部评审回归：中途失败的多页拉取

extension PhiSyncEngineOwnedItemsTests {

    /// 一次多页拉取在第 2 页抛错：第 1 页的实体**已经被 marker 永久消费掉了**。
    ///
    /// 防的是什么：共享 marker 一页一页落盘，而路由解出来的那一批活在这一轮的局部变量里。
    /// 抛错把它们带走之后，服务端只会从推进过的 marker 之后发货——页 1 上那条 create 与那条
    /// tombstone **再也不会被投递**：那条书签在本机永远不出现，那次远端删除在本机永远不发生，
    /// 而每一个计数器都是健康值。
    func testAPullInterruptedAfterTheMarkerMovedKeepsWhatTheEarlierPagesDelivered() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "GD", syncId: "b-doomed", spaceId: "s-1", index: 0),
        ])
        let store = MemoryOwnedItemStore()
        store.table.cursors["b-doomed"] = publishedCursor(alignedPayload(uuid: "b-doomed"),
                                                          entityId: "srv-doomed", version: 3)
        let client = FakePhiSyncClient()
        client.scriptedPages = [
            page([
                remoteEntity(envelope(alignedPayload(uuid: "b-new", title: "对端建的")),
                             tag: bookmarkTag("b-new"), version: 30, entityId: "srv-new",
                             key: key),
                remoteTombstone(tag: bookmarkTag("b-doomed"), version: 31,
                                entityId: "srv-doomed"),
            ], marker: "31", changesRemaining: true),
        ]
        client.getUpdatesErrorAfterPages = (pages: 1, error: PhiSyncProtocolError.http(500))

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertEqual(client.getUpdatesCalls.count, 2, "前提：页 1 到货、页 2 抛错")
        XCTAssertNotNil(defaults.data(forKey: PhiSyncEngine.markerStateKey),
                        "前提：页 1 的 marker 推进是持久的——这正是问题所在")
        var table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertNotNil(table.cursors["b-new"]?.pendingApply, "① 存活实体停放，不是丢掉")
        XCTAssertEqual(table.cursors["b-new"]?.entityId, "srv-new", "① 三元组照收（A6）")
        XCTAssertEqual(table.cursors["b-new"]?.pendingOwnerUuid, "su-1")
        XCTAssertEqual(table.cursors["b-doomed"]?.pendingTombstone, true,
                       "② 远端 tombstone 同样要留下来")
        XCTAssertEqual(table.cursors["b-doomed"]?.version, 31, "② tombstone 的版本也收割了")

        // 下一轮服务端一条都不再发（marker 早已推过那一页），全靠游标上留下的那两笔。
        await engine.pullOnce()

        XCTAssertNotNil(access.rows.first { $0.syncId == "b-new" }, "③ 那条 create 最终落了地")
        XCTAssertNil(access.rows.first { $0.guid == "GD" }, "③ 那次远端删除最终也发生了")
        table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertNil(table.cursors["b-new"]?.pendingApply, "落地之后才解除停放")
        XCTAssertEqual(table.cursors["b-doomed"]?.pendingTombstone, false)
        XCTAssertNotNil(table.cursors["b-doomed"]?.deletedAtMs)
    }
}

// MARK: - 外部评审回归：作用域不一致轮里的 tombstone

extension PhiSyncEngineOwnedItemsTests {

    /// spec §12.1 第 15 条的后半句（「tombstone 进 `pendingTombstone`」）的引擎接线。
    ///
    /// 防的是什么：`plan` 在作用域不一致时一条 step 都不产出，于是落地段看不见这条身份，
    /// 而 `pendingTombstone` 的两个写入点（`outcome.parked` 与本轮的落地）都要求它先出现在
    /// step 里。那条远端删除因此被静默丢掉：三元组已经收割、游标看上去健康、marker 早已推过
    /// 那一页——本机那条 pin 永远不死，账户上它早就没了。
    func testAScopeMismatchRoundKeepsAnInboundPinTombstoneUntilTheScopesAgree() async throws {
        let spaceAccess = makeSpaceAccess(["space-a": "su-1"])
        // 本机是 Space 作用域、账户说 Profile ⇒ §7.3 的不一致轮。
        let pinAccess = FakePinAccess(scope: .space, account: .profile, rows: [
            .fixture(lineageId: "LX", guid: "P1", spaceId: "space-a", profileId: "Default",
                     createdDate: Date(timeIntervalSince1970: 1_000)),
        ])
        let pinStore = MemoryOwnedItemStore()
        pinStore.table.cursors["lx:su-1"] = publishedPinCursor(
            pinPayload(lineage: "lx", ownerKey: "su-1", createdAtMs: 1_000_000),
            entityId: "srv-lx", version: 5, owner: "su-1")
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([
            remoteTombstone(tag: pinTag("lx", owner: "su-1"), version: 12, entityId: "srv-lx"),
        ])]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [pinKind(pinAccess, pinStore)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        var table = await engine.ownedTableForTesting("pins")
        XCTAssertNotNil(pinAccess.rows.first { $0.guid == "P1" },
                        "前提：不一致轮一条都不落地")
        XCTAssertEqual(table.cursors["lx:su-1"]?.pendingTombstone, true,
                       "① 那条远端删除留在游标上，等作用域收敛")
        XCTAssertEqual(table.cursors["lx:su-1"]?.version, 12, "② 三元组照收（A6）")

        // 作用域收敛之后的第一轮：那次删除照常发生，靠的全是游标上留下的那一位。
        pinAccess.account = .space
        await engine.pullOnce()

        XCTAssertNil(pinAccess.rows.first { $0.guid == "P1" },
                     "③ 收敛后的第一轮把那次远端删除放下去")
        table = await engine.ownedTableForTesting("pins")
        XCTAssertEqual(table.cursors["lx:su-1"]?.pendingTombstone, false)
        XCTAssertNotNil(table.cursors["lx:su-1"]?.deletedAtMs)
    }
}

// MARK: - 外部评审回归：取值相同、戳更新的入站实体

extension PhiSyncEngineOwnedItemsTests {

    private func baselineTitle(_ bytes: Data?) -> Phi_PhiSettingValue? {
        guard let bytes, let envelope = try? Phi_PhiEntity(serializedBytes: bytes),
              let entity = BookmarkKind.entity(from: envelope) else { return nil }
        return entity.title
    }

    /// 对端把标题改成 B 又改回 A：落地什么都不用做，**基线仍然要吃下那个更新的戳**，
    /// 否则下一条更旧的实体会凭一个过期的比较基准赢下账户上更新的那个值。
    func testASameValueUpdateStillMovesTheBaselineForwardSoALaterOlderEditLoses() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "G1", syncId: "b1", spaceId: "s-1", title: "A"),
        ])
        let store = MemoryOwnedItemStore()
        store.table.cursors["b1"] = publishedCursor(alignedPayload(uuid: "b1", title: "A"),
                                                    entityId: "srv-b1", version: 7)
        let client = FakePhiSyncClient()
        client.scriptedPages = [
            // ① A@300：与本机取值相同、戳更新。
            oneEntityPage(bookmarkPayload(uuid: "b1", title: "A", contentStamp: 300,
                                          createdAtMs: Self.rowCreatedAtMs),
                          uuid: "b1", version: 42, entityId: "srv-b1"),
            // ② 随后一条更旧的 B@200（重放 / 第三台设备 / marker 回退都产得出）。
            oneEntityPage(bookmarkPayload(uuid: "b1", title: "B", contentStamp: 200,
                                          createdAtMs: Self.rowCreatedAtMs),
                          uuid: "b1", version: 43, entityId: "srv-b1"),
        ]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        var table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertEqual(baselineTitle(table.cursors["b1"]?.reconciled)?.updatedAtMs, 300,
                       "① 基线吃下那个更新的戳")
        XCTAssertEqual(applyCallCount(access), 0, "① 落地那一侧什么都不用做，不产空补丁")

        await engine.pullOnce()

        XCTAssertEqual(access.rows.first { $0.guid == "G1" }?.title, "A",
                       "② 更旧的 B@200 输给账户上那条 A@300，本机那一行一个字不动")
        table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertEqual(baselineTitle(table.cursors["b1"]?.reconciled)?.stringValue, "A")
    }
}

// MARK: - 评审回归 F-CX-2 / F-CX-3

extension PhiSyncEngineOwnedItemsTests {

    /// F-CX-2 — 轮首那次本机读抛了，而共享 marker 已经推过这一页。
    ///
    /// 防的是什么：就地返回等于把这一页上的 create 与远端删除**永久**丢掉——服务端只从推进
    /// 过的 marker 之后发货，那条书签在本机永远不出现、那次删除永远不发生，而每一个计数器
    /// 都是健康值。R-exec-3 关的是这条 kind 的出站半边，不是「可以把已经收下的字节扔掉」。
    func testAFailedLocalReadStillKeepsWhatTheMarkerAlreadyConsumed() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "GD", syncId: "b-doomed", spaceId: "s-1", index: 0),
        ])
        access.readError = LocalStoreWriteError.storeUnavailable
        let store = MemoryOwnedItemStore()
        store.table.cursors["b-doomed"] = publishedCursor(alignedPayload(uuid: "b-doomed"),
                                                          entityId: "srv-doomed", version: 3)
        let client = FakePhiSyncClient()
        client.scriptedPages = [page([
            remoteEntity(envelope(alignedPayload(uuid: "b-new", title: "对端建的")),
                         tag: bookmarkTag("b-new"), version: 30, entityId: "srv-new", key: key),
            remoteTombstone(tag: bookmarkTag("b-doomed"), version: 31, entityId: "srv-doomed"),
        ], marker: "500")]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        var table = await engine.ownedTableForTesting("bookmarks")
        let counters = await engine.lastOwnedRoundCountersForTesting["bookmarks"]
        XCTAssertEqual(counters?.localReadFailed, 1, "前提：这一轮的本机读真的抛了")
        XCTAssertEqual(applyCallCount(access), 0, "前提：落地段整段没跑")
        XCTAssertNotNil(table.cursors["b-new"]?.pendingApply, "① 存活实体停放，不是丢掉")
        XCTAssertEqual(table.cursors["b-new"]?.entityId, "srv-new", "① 三元组照收（A6）")
        XCTAssertEqual(table.cursors["b-doomed"]?.pendingTombstone, true,
                       "② 远端 tombstone 同样留下来")
        XCTAssertEqual(table.cursors["b-doomed"]?.version, 31)

        // 读恢复之后的第一轮（服务端一条都不再发）把它们放下去。
        access.readError = nil
        await engine.pullOnce()

        XCTAssertNotNil(access.rows.first { $0.syncId == "b-new" }, "③ 那条 create 最终落了地")
        XCTAssertNil(access.rows.first { $0.guid == "GD" }, "③ 那次远端删除最终也发生了")
        table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertNil(table.cursors["b-new"]?.pendingApply)
        XCTAssertEqual(table.cursors["b-doomed"]?.pendingTombstone, false)
    }

    /// F-CX-3 ① — 本机赢下字段的那条实体**排不进这一轮 250 条的切片**，下一轮照样发出去。
    ///
    /// 防的是什么：把「要重发」记在轮内那个集合里，这条需求随轮次一起消失，而落地之后本机
    /// 那一行与 `reconciled` 逐字相等——字节差分永远不会再为它说话，账户永远停在旧值上。
    /// 游标上 `server != reconciled` 持久地记着同一件事。
    func testALocallyWonMergeThatMissesThePublishSliceGoesOutOnALaterRound() async throws {
        let alphabet = Array("123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        func fillerRank(_ index: Int) -> String {
            "V" + String(alphabet[index / alphabet.count]) + String(alphabet[index % alphabet.count])
        }
        let spaceAccess = makeSpaceAccess()
        // ① 本机赢的那一条：`zz-won` 在身份序里排在每一条 filler 之后，而切片按（深度，身份）
        // 排序，所以它必然落在 250 条之外。
        var rows: [PhiLocalBookmark] = [
            .fixture(guid: "G-won", syncId: "zz-won", spaceId: "s-1", index: 0,
                     title: "本机新标题",
                     contentUpdatedDate: Date(timeIntervalSince1970: 500)),
        ]
        let store = MemoryOwnedItemStore()
        store.table.cursors["zz-won"] = publishedCursor(
            alignedPayload(uuid: "zz-won", rank: "B", title: "旧标题"),
            entityId: "srv-won", version: 7)
        // ② 260 条本机改过名、都在等发布的行，把这一轮的切片填满。
        for index in 0..<260 {
            let identity = String(format: "f-%03d", index)
            rows.append(.fixture(guid: "G-" + identity, syncId: identity, spaceId: "s-1",
                                 index: index + 1, title: "new",
                                 contentUpdatedDate: Date(timeIntervalSince1970: 500)))
            store.table.cursors[identity] = publishedCursor(
                alignedPayload(uuid: identity, rank: fillerRank(index), title: "old"),
                entityId: "srv-" + identity, version: 2)
        }
        let access = FakeBookmarkAccess(rows: rows)
        let client = FakePhiSyncClient()
        // 对端改的是 URL；本机那次改名还没发布 ⇒ 合并结果里本机赢下标题。
        client.scriptedPages = [oneEntityPage(
            bookmarkPayload(uuid: "zz-won", rank: "B", title: "旧标题",
                            url: "https://peer.example", contentStamp: 2_000_000,
                            createdAtMs: Self.rowCreatedAtMs),
            uuid: "zz-won", version: 42, entityId: "srv-won")]

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let firstRound = bookmarkCommits(client)
        XCTAssertEqual(firstRound.count, 250, "前提：这一轮的切片满了")
        XCTAssertFalse(firstRound.contains { $0.clientTagHash == bookmarkHash("zz-won") },
                       "前提：本机赢的那一条没排上")
        let table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertNotEqual(table.cursors["zz-won"]?.server, table.cursors["zz-won"]?.reconciled,
                          "① 分歧持久地记在游标上：账户手上那一份不是本机落地的那一份")

        await engine.pullOnce()

        let later = Array(bookmarkCommits(client).dropFirst(firstRound.count))
        let sent = later.first { $0.clientTagHash == bookmarkHash("zz-won") }
            .flatMap(committedBookmark)
        XCTAssertNotNil(sent, "② 下一轮把它发出去——轮内那个集合早就清空了")
        XCTAssertEqual(sent?.title.stringValue, "本机新标题", "② 带的是本机那个标题")
    }

    /// F-CX-3 ② — 落地与发布之间断了一次（这里用一次抛错的 commit 表达；退休、sign-out、
    /// 进程退出是同一个形状）⇒ 那条重发需求必须活到下一轮。
    func testALocallyWonMergeSurvivesAFailedCommitAndPublishesNextRound() async throws {
        let spaceAccess = makeSpaceAccess()
        let access = FakeBookmarkAccess(rows: [
            .fixture(guid: "G1", syncId: "b1", spaceId: "s-1", title: "本机新标题",
                     contentUpdatedDate: Date(timeIntervalSince1970: 500)),
        ])
        let store = MemoryOwnedItemStore()
        store.table.cursors["b1"] = publishedCursor(alignedPayload(uuid: "b1", title: "旧标题"),
                                                    entityId: "srv-b1", version: 7)
        let client = FakePhiSyncClient()
        client.scriptedPages = [oneEntityPage(
            bookmarkPayload(uuid: "b1", title: "旧标题", url: "https://peer.example",
                            contentStamp: 2_000_000, createdAtMs: Self.rowCreatedAtMs),
            uuid: "b1", version: 42, entityId: "srv-b1")]
        client.commitErrorOnce = URLError(.timedOut)

        let engine = makeEngine(client: client, access: spaceAccess, store: makeSpaceStore(),
                                ownedKinds: [bookmarkKind(access, store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertEqual(bookmarkCommits(client).count, 1, "前提：那一轮试过发，而它抛了")
        let table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertNotEqual(table.cursors["b1"]?.server, table.cursors["b1"]?.reconciled,
                          "① 需求留在游标上")

        await engine.pullOnce()

        let later = Array(bookmarkCommits(client).dropFirst(1))
        XCTAssertEqual(later.count, 1, "② 下一轮重发，正好一条")
        XCTAssertEqual(later.first.flatMap(committedBookmark)?.title.stringValue, "本机新标题")
        let settled = await engine.ownedTableForTesting("bookmarks")
        XCTAssertEqual(settled.cursors["b1"]?.server, settled.cursors["b1"]?.reconciled,
                       "③ 被接受之后两份基线合一，需求就此消失（不然它每轮都重发）")
    }
}

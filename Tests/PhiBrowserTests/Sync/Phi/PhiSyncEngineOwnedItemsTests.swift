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
                            previewMaxPages: Int = 400) -> PhiSyncEngine {
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

        access.importingSpaceIds = []
        await engine.pullOnce()
        table = await engine.ownedTableForTesting("bookmarks")
        XCTAssertEqual(access.rows.filter { $0.spaceId == "s-b" }.count, 2, "④ 下一轮落地")
        XCTAssertNotNil(table.cursors["b1"]?.reconciled)
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
        var cursor = publishedCursor(bookmarkPayload(uuid: "bpark", title: "B",
                                                     url: "https://b.example"),
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
}

import Foundation
import XCTest
@testable import Phi

/// `SyncableOwnedItems` 与 `BookmarkKind` 的模块级用例：**没有 SwiftData、没有引擎、
/// 没有持久化**，全部输入都是值类型，全部输出都是返回值。
///
/// 类标 `@MainActor` 是因为 Task 0 那两个假件（`FakeBookmarkAccess` / `FakePinAccess`）
/// 是 `@MainActor` 的，本里程碑后面的用例会在同一个文件族里构造它们；模块本身不需要
/// 任何 actor。
@MainActor
final class SyncableOwnedItemsTests: XCTestCase {

    private let resolve = OwnerResolver.fixture()

    // MARK: - 小工具

    private func arrival(_ payload: Phi_PhiBookmarkEntity,
                         entityId: String = "srv-1",
                         version: Int64 = 1) -> OwnedItemArrival<Phi_PhiBookmarkEntity> {
        OwnedItemArrival(entity: payload, entityId: entityId, version: version)
    }

    private func planned(_ arrivals: [OwnedItemArrival<Phi_PhiBookmarkEntity>],
                         parked: [String: ParkedOwnedItem] = [:],
                         table: PhiOwnedItemTable = PhiOwnedItemTable(),
                         resolve: OwnerResolver? = nil,
                         context: OwnedItemPlanContext = OwnedItemPlanContext()) -> OwnedItemPlan {
        SyncableOwnedItems.plan(BookmarkKind.self, arrivals: arrivals, parked: parked,
                                table: table, resolve: resolve ?? self.resolve, context: context)
    }

    /// 一条活游标，带基线与归属——`plan` 的删除排序与 `tombstones` 的三条判据都读它。
    private func landedCursor(_ payload: Phi_PhiBookmarkEntity,
                              entityId: String = "srv-1",
                              version: Int64 = 1,
                              ownerUuid: String? = "su-1") -> PhiOwnedItemCursor {
        ownedCursor(reconciled: baselineBytes(payload), entityId: entityId,
                    version: version, ownerUuid: ownerUuid)
    }

    private func deleteIdentities(_ plan: OwnedItemPlan) -> [String] {
        plan.steps.filter { $0.kind == .delete }.map(\.identity)
    }

    /// 本机行的内容取值与 `bookmarkPayload` 的默认值逐字段对齐，于是「没有任何变化」
    /// 的那些用例产出的字节真的等于基线。`createdDate` 是 1 秒 = 1000 ms，正是
    /// `bookmarkPayload` 的 `createdAtMs` 默认值。
    private func row(identity: String,
                     guid: String? = nil,
                     spaceId: String = "space-a",
                     parentGuid: String? = nil,
                     index: Int = 0,
                     isFolder: Bool = false,
                     title: String = "T",
                     contentUpdatedDate: Date? = nil) -> PhiLocalBookmark {
        PhiLocalBookmark.fixture(guid: guid ?? ("g-" + identity), syncId: identity,
                                 spaceId: spaceId, parentGuid: parentGuid, index: index,
                                 isFolder: isFolder, title: title,
                                 createdDate: Date(timeIntervalSince1970: 1),
                                 contentUpdatedDate: contentUpdatedDate)
    }

    private func bytes(_ entity: Phi_PhiBookmarkEntity?) -> Data? {
        guard let entity else { return nil }
        return try? entity.serializedData()
    }

    // MARK: - CASE 4a.1

    /// CASE 4a.1 — 归属解析不到 ⇒ 停放。
    ///
    /// 防的是什么：停放是「等 Space 落地」，不是丢弃也不是猜一个 Space；停放项在本机
    /// 不该留任何痕迹，否则下一轮差分把那个痕迹当成本机意图发回去。
    func testAnArrivalWhoseOwnerDoesNotResolveIsParkedRatherThanLandedOrDropped() {
        let plan = planned([arrival(bookmarkPayload(uuid: "b1", spaceUuid: "su-unknown"))])

        let steps = plan.steps
        let parkedKeys = Set(plan.parked.keys)
        XCTAssertTrue(steps.isEmpty)
        XCTAssertEqual(parkedKeys, ["b1"])
    }

    // MARK: - CASE 4a.2 / 4a.3

    /// CASE 4a.2 — 一页里乱序到达的三层树一轮落完。
    func testAThreeLevelTreeArrivingOutOfOrderLandsInOneRound() {
        let plan = planned([
            arrival(bookmarkPayload(uuid: "c", parentUuid: "b")),
            arrival(bookmarkPayload(uuid: "a", isFolder: true)),
            arrival(bookmarkPayload(uuid: "b", parentUuid: "a", isFolder: true)),
        ])

        let identities = plan.steps.map(\.identity)
        let parkedKeys = Array(plan.parked.keys)
        XCTAssertEqual(identities, ["a", "b", "c"])
        XCTAssertTrue(parkedKeys.isEmpty)
    }

    /// CASE 4a.3 — 五层树打乱顺序仍一轮落完。
    ///
    /// 防的是什么：按到达顺序处理的实现会把每一层推到下一轮，一棵五层树要五轮。
    func testAFiveLevelTreeStillLandsInOneRoundWhateverTheArrivalOrder() {
        let chain = ["n1", "n2", "n3", "n4", "n5"]
        var arrivals: [OwnedItemArrival<Phi_PhiBookmarkEntity>] = []
        for (depth, uuid) in chain.enumerated() {
            arrivals.append(arrival(bookmarkPayload(uuid: uuid,
                                                    parentUuid: depth == 0 ? "" : chain[depth - 1],
                                                    isFolder: depth < chain.count - 1)))
        }
        // 打乱成一个与链序毫无关系的到达顺序。
        let shuffled = [arrivals[3], arrivals[0], arrivals[4], arrivals[2], arrivals[1]]

        let plan = planned(shuffled)

        let identities = plan.steps.map(\.identity)
        let parkedKeys = Array(plan.parked.keys)
        XCTAssertEqual(identities, chain)
        XCTAssertTrue(parkedKeys.isEmpty)
    }

    // MARK: - CASE 4a.4

    /// CASE 4a.4 — 环 ⇒ 两条都 refuse，不 trap。
    ///
    /// 防的是什么：这是对端字节不是本机 bug；停放会让它永远等一个等不到的父。
    func testACycleRefusesBothEntitiesInsteadOfParkingOrTrapping() {
        let plan = planned([
            arrival(bookmarkPayload(uuid: "a", parentUuid: "b", isFolder: true)),
            arrival(bookmarkPayload(uuid: "b", parentUuid: "a", isFolder: true)),
        ])

        let steps = plan.steps
        let refused = plan.refused
        let parkedKeys = Array(plan.parked.keys)
        XCTAssertTrue(steps.isEmpty)
        XCTAssertEqual(refused, 2)
        XCTAssertTrue(parkedKeys.isEmpty)
    }

    // MARK: - CASE 4a.5 / 4a.6 / 4a.7

    private func parentChildTable() -> PhiOwnedItemTable {
        var table = PhiOwnedItemTable()
        table.cursors["parent"] = landedCursor(bookmarkPayload(uuid: "parent", isFolder: true),
                                               entityId: "srv-p")
        table.cursors["child"] = landedCursor(bookmarkPayload(uuid: "child", parentUuid: "parent"),
                                              entityId: "srv-c")
        return table
    }

    /// CASE 4a.5 — 父被证实死亡时子才提升。
    ///
    /// 防的是什么：提升是一次字段变化，会推回账户，两边靠它收敛。
    func testAChildIsLiftedToTheRootOnlyWhenItsParentIsProvenDead() {
        var context = OwnedItemPlanContext()
        context.tombstonedIdentities = ["parent"]

        let plan = planned([arrival(bookmarkPayload(uuid: "child", parentUuid: "parent"))],
                           table: parentChildTable(), context: context)

        let lifted = plan.lifted
        let childStep = plan.steps.first { $0.identity == "child" }
        XCTAssertEqual(lifted, 1)
        XCTAssertEqual(childStep?.newParentUuid, "")
    }

    /// CASE 4a.6 — 子自己也带 tombstone ⇒ 两条都删，不提升。
    func testAChildThatCarriesItsOwnTombstoneIsDeletedRatherThanLifted() {
        var context = OwnedItemPlanContext()
        context.tombstonedIdentities = ["parent", "child"]

        let plan = planned([arrival(bookmarkPayload(uuid: "child", parentUuid: "parent"))],
                           table: parentChildTable(), context: context)

        let lifted = plan.lifted
        let deletes = deleteIdentities(plan)
        XCTAssertEqual(lifted, 0)
        XCTAssertEqual(deletes, ["child", "parent"])
    }

    /// CASE 4a.7 — 父只是「缺席」时子停放（负面三连）。
    ///
    /// 防的是什么：这三种都不是「父被证实死亡」；当成死亡会把一棵完好的子树整体提到
    /// Space 根，而那个位置会被发回账户、在每一台设备上生效。
    func testAMerelyAbsentParentParksTheChildInsteadOfLiftingIt() {
        let childArrival = arrival(bookmarkPayload(uuid: "child", parentUuid: "parent"))

        // ① 父的实体解密失败，被记进了 `unreadableTagHashes`：本机认得这条身份（游标在），
        //    但它从来没落过地，所以既没有本地行也没有基线。
        var unreadableTable = PhiOwnedItemTable()
        unreadableTable.cursors["parent"] = PhiOwnedItemCursor()
        unreadableTable.cursors["child"] = landedCursor(
            bookmarkPayload(uuid: "child", parentUuid: "parent"), entityId: "srv-c")

        // ② 父本轮被 §4.6 拒收（非法 rank）。
        let refusedParent = arrival(bookmarkPayload(uuid: "parent", rank: "V0", isFolder: true))

        // ③ 父根本没到。
        let cases: [(name: String, arrivals: [OwnedItemArrival<Phi_PhiBookmarkEntity>],
                     table: PhiOwnedItemTable)] = [
            ("父不可读", [childArrival], unreadableTable),
            ("父被拒收", [childArrival, refusedParent], parentChildTable()),
            ("父没到", [childArrival], PhiOwnedItemTable()),
        ]

        for scenario in cases {
            let plan = planned(scenario.arrivals, table: scenario.table)

            let lifted = plan.lifted
            let parkedKeys = Array(plan.parked.keys)
            let steps = plan.steps
            XCTAssertEqual(lifted, 0, scenario.name)
            XCTAssertEqual(parkedKeys, ["child"], scenario.name)
            XCTAssertTrue(steps.isEmpty, scenario.name)
        }
    }

    // MARK: - CASE 4a.8

    /// CASE 4a.8 — 非法 rank ⇒ refuse，且 `rankBetween` 零调用。
    ///
    /// 防的是什么：`rankBetween` 在发布构建里用 `precondition` 直接 trap，而对端字节是
    /// 不可信输入——唯一的解码边界就是 `isLegalRank`。书签让这件事更严重：rank 只在同一个
    /// 父下可比，一次非法 rank 能污染的是一整个文件夹。
    func testAnIllegalRankIsRefusedAndNeverReachesRankBetween() {
        // spec §4.6 列了三种非法形状，只测一种的实现可能只挡住了字符集那一条。
        for rank in ["", "V0", "V-1"] {
            RankProbe.reset()

            let plan = planned([arrival(bookmarkPayload(uuid: "b1", rank: rank))])

            let refused = plan.refused
            let steps = plan.steps
            let rankBetweenCalls = RankProbe.rankBetweenCalls
            XCTAssertEqual(refused, 1, rank)
            XCTAssertTrue(steps.isEmpty, rank)
            XCTAssertEqual(rankBetweenCalls, 0, rank)
        }
    }

    // MARK: - CASE 4a.9 / 4a.10 / 4a.20

    /// CASE 4a.9 — 根级项两个 location 成员共用一个戳（7a）。
    ///
    /// 内容戳（2000 ms）与 `now`（5000 ms）刻意取成不同的值：A13 那句「其余字段盖 `now`」
    /// 已被 R-M3-3-28 的 First-publish stamps 与 spec §4.2 第 5 条取代，而书签的「其余字段」
    /// 集合是**空**的——它全部 LWW 字段就是两个 location 成员、`rank` 与四个内容字段。
    /// 于是这条与 CASE 4a.20 是同一条规则的两个独立探针。
    func testARootLevelRowStampsBothLocationMembersTogetherWithNoBaseline() {
        let local = row(identity: "b1", contentUpdatedDate: Date(timeIntervalSince1970: 2))

        let result = SyncableOwnedItems.snapshot(BookmarkKind.self, locals: [local],
                                                 table: PhiOwnedItemTable(), resolve: resolve,
                                                 scope: nil, now: 5_000)

        let entity = result.entities["b1"]
        let spaceStamp = entity?.spaceUuid.updatedAtMs
        let parentStamp = entity?.parentUuid.updatedAtMs
        XCTAssertEqual(spaceStamp, 0)
        XCTAssertEqual(parentStamp, 0)
        XCTAssertEqual(spaceStamp, parentStamp)
        XCTAssertEqual(entity?.rank.updatedAtMs, 0)
        XCTAssertEqual(entity?.title.updatedAtMs, 2_000, "内容字段盖行自己的内容戳")
        XCTAssertNotEqual(entity?.title.updatedAtMs, 5_000, "绝不盖 now")
    }

    /// CASE 4a.10 — 纯排序只重盖 `rank`（7b 前半）。
    func testAPureReorderRestampsOnlyTheRank() {
        // 基线次序是 b2("k") 之后 b1("V")，本机把 b2 拖到了前面，于是只有 b2 要一个新 rank。
        var table = PhiOwnedItemTable()
        table.cursors["b1"] = landedCursor(bookmarkPayload(uuid: "b1", rank: "V"))
        table.cursors["b2"] = landedCursor(bookmarkPayload(uuid: "b2", rank: "k"))
        let locals = [row(identity: "b2", index: 0), row(identity: "b1", index: 1)]

        let result = SyncableOwnedItems.snapshot(BookmarkKind.self, locals: locals, table: table,
                                                 resolve: resolve, scope: nil, now: 5_000)

        let moved = result.entities["b2"]
        XCTAssertEqual(moved?.spaceUuid.updatedAtMs, 100)
        XCTAssertEqual(moved?.rank.updatedAtMs, 5_000)
    }

    /// CASE 4a.20 — 无基线的新行怎么盖戳（10）。
    func testANoBaselineRowStampsContentWithItsOwnContentTimestamp() {
        let local = PhiLocalBookmark.fixture(guid: "g1", syncId: "b1", spaceId: "space-a",
                                             createdDate: Date(timeIntervalSince1970: 1),
                                             contentUpdatedDate: Date(timeIntervalSince1970: 2))

        let result = SyncableOwnedItems.snapshot(BookmarkKind.self, locals: [local],
                                                 table: PhiOwnedItemTable(), resolve: resolve,
                                                 scope: nil, now: 5_000)

        let entity = result.entities["b1"]
        XCTAssertEqual(entity?.spaceUuid.updatedAtMs, 0)
        XCTAssertEqual(entity?.parentUuid.updatedAtMs, 0)
        XCTAssertEqual(entity?.rank.updatedAtMs, 0)
        XCTAssertEqual(entity?.title.updatedAtMs, 2_000)
        XCTAssertEqual(entity?.url.updatedAtMs, 2_000)
        XCTAssertEqual(entity?.createdAtMs, 1_000)
    }

    // MARK: - CASE 4a.11 – 4a.14（合并）

    /// CASE 4a.11 — 相干规则两个方向同结果（7c）。
    ///
    /// 防的是什么：写成「当赢家是对面那一侧时才取对面的 rank」只修一半：本机赢下 location
    /// 而对端 rank 戳更新时，plain LWW 会把一个在**输掉的** location 里铸出来的 rank 装到
    /// 赢家的 location 上，两台机器从同一对实体算出不同结果。
    func testTheRankFollowsTheLocationWinnerInBothDirections() {
        let x = bookmarkPayload(uuid: "b1", spaceUuid: "su-1", rank: "M",
                                locationStamp: 200, rankStamp: 100)
        let y = bookmarkPayload(uuid: "b1", spaceUuid: "su-2", rank: "V",
                                locationStamp: 100, rankStamp: 300)

        let forward = BookmarkKind.merge(local: x, remote: y)
        let backward = BookmarkKind.merge(local: y, remote: x)

        XCTAssertEqual(forward, backward)
        XCTAssertEqual(forward.spaceUuid.stringValue, "su-1")
        XCTAssertEqual(forward.rank.stringValue, "M")
    }

    /// CASE 4a.12 — 三方汇合与顺序无关（7d 的一半）。
    func testAThreeWayMergeIsIndependentOfTheOrderItIsApplied() {
        let a = bookmarkPayload(uuid: "b1", spaceUuid: "su-1", rank: "M", title: "A",
                                locationStamp: 300, rankStamp: 100, contentStamp: 100)
        let b = bookmarkPayload(uuid: "b1", spaceUuid: "su-2", rank: "V", title: "B",
                                locationStamp: 200, rankStamp: 500, contentStamp: 300)
        let c = bookmarkPayload(uuid: "b1", spaceUuid: "su-3", rank: "k", title: "C",
                                locationStamp: 100, rankStamp: 700, contentStamp: 200)

        let left = BookmarkKind.merge(local: BookmarkKind.merge(local: a, remote: b), remote: c)
        let right = BookmarkKind.merge(local: BookmarkKind.merge(local: c, remote: b), remote: a)

        XCTAssertEqual(left, right)
    }

    /// CASE 4a.13 — 载体恒由深度决定，不取 `max`（N1 的探针）。
    ///
    /// 防的是什么：取 `max(space, parent)` 的实现会算出 900 并赢下这次合并；两台机器对
    /// 同一对实体挑不同的载体，位置永不收敛。
    func testTheLocationTimestampComesFromTheCarrierNeverFromTheLargerMember() {
        var descendant = bookmarkPayload(uuid: "b1", parentUuid: "p1", locationStamp: 100)
        descendant.spaceUuid = stamped("su-1", at: 900)
        let rival = bookmarkPayload(uuid: "b1", parentUuid: "p2", locationStamp: 500)

        let carrierStamp = BookmarkKind.locationStamp(of: descendant)
        let merged = BookmarkKind.merge(local: descendant, remote: rival)

        XCTAssertEqual(carrierStamp, 100)
        XCTAssertEqual(merged.parentUuid.stringValue, "p2")
    }

    /// CASE 4a.14 — 平手按字节字典序（7e）。
    func testATiedLocationIsBrokenDeterministicallyAndSymmetrically() {
        let a = bookmarkPayload(uuid: "b1", spaceUuid: "su-1", locationStamp: 100)
        let b = bookmarkPayload(uuid: "b1", spaceUuid: "su-2", locationStamp: 100)

        let forward = BookmarkKind.merge(local: a, remote: b)
        let backward = BookmarkKind.merge(local: b, remote: a)

        XCTAssertEqual(forward, backward)
        XCTAssertEqual(forward.spaceUuid.stringValue, "su-2")
    }

    // MARK: - CASE 4a.15 / 4a.16

    /// CASE 4a.15 — 子孙的 `space_uuid` 不参与变化检测（7b 后半 · 一）。
    ///
    /// 防的是什么：子孙的 Space 由它的父推导，让它参与会在每次跨 Space 移动时把整棵子树
    /// 都标成脏的。
    func testADescendantsSpaceUuidDoesNotParticipateInChangeDetection() {
        let baseline = bookmarkPayload(uuid: "c1", spaceUuid: "su-1", parentUuid: "p1")
        var table = PhiOwnedItemTable()
        table.cursors["p1"] = landedCursor(bookmarkPayload(uuid: "p1", isFolder: true))
        table.cursors["c1"] = landedCursor(baseline)
        // 本机把整棵子树重打到了 space-b，只有那个文件夹是一次真实的位置变化。
        let locals = [row(identity: "p1", spaceId: "space-b", isFolder: true),
                      row(identity: "c1", spaceId: "space-b", parentGuid: "g-p1")]

        let result = SyncableOwnedItems.snapshot(BookmarkKind.self, locals: locals, table: table,
                                                 resolve: resolve, scope: nil, now: 5_000)

        let produced = bytes(result.entities["c1"])
        let expected = bytes(baseline)
        XCTAssertNotNil(produced)
        XCTAssertEqual(produced, expected)
    }

    /// CASE 4a.16 — 跨 Space 移动一个含 40 后代的文件夹 ⇒ 恰好一条 commit（7b 后半 · 二）。
    ///
    /// 防的是什么：41 条 commit 与 1 条的差别，在一次大规模整理里就是几千条无谓的写。
    func testMovingAFolderWithFortyDescendantsAcrossSpacesChangesExactlyOneEntity() {
        let descendantCount = 40
        var table = PhiOwnedItemTable()
        var baselines: [String: Phi_PhiBookmarkEntity] = [:]
        var locals: [PhiLocalBookmark] = []

        let folderBaseline = bookmarkPayload(uuid: "fd", spaceUuid: "su-1", rank: "V",
                                             isFolder: true)
        baselines["fd"] = folderBaseline
        table.cursors["fd"] = landedCursor(folderBaseline)
        locals.append(row(identity: "fd", spaceId: "space-b", isFolder: true))

        for index in 0..<descendantCount {
            let identity = "c\(index)"
            // 单字符 rank，按字母表严格递增，于是本机次序与基线次序一致、没有一条要重排。
            let rank = String(SyncableSpaces.rankAlphabet[index + 1])
            let baseline = bookmarkPayload(uuid: identity, spaceUuid: "su-1",
                                           parentUuid: "fd", rank: rank)
            baselines[identity] = baseline
            table.cursors[identity] = landedCursor(baseline)
            locals.append(row(identity: identity, spaceId: "space-b",
                              parentGuid: "g-fd", index: index))
        }

        let result = SyncableOwnedItems.snapshot(BookmarkKind.self, locals: locals, table: table,
                                                 resolve: resolve, scope: nil, now: 5_000)

        let changed = baselines.keys.filter { bytes(result.entities[$0]) != bytes(baselines[$0]) }
        let produced = result.entities.count
        XCTAssertEqual(produced, descendantCount + 1)
        XCTAssertEqual(changed, ["fd"])
    }

    // MARK: - CASE 4a.17 / 4a.17b / 4a.18 / 4a.18b

    /// CASE 4a.17 — 差分 tombstone 的三条判据 + 两条排除（8）。
    ///
    /// 防的是什么：§4.7 点名了④的后果——把归属不合格而被 §4.2 跳过的行算成「本机没有
    /// 这一行」，会在一次映射抖动里删掉账户上一整个 Space 的书签。
    func testTheLocalDeleteDiffHasThreeCriteriaAndTwoOwnerExclusions() {
        var table = PhiOwnedItemTable()
        table.cursors["i1"] = landedCursor(bookmarkPayload(uuid: "i1"))
        table.cursors["i2"] = ownedCursor(entityId: "srv-2", version: 1, ownerUuid: "su-1")
        var decided = landedCursor(bookmarkPayload(uuid: "i3"))
        decided.deletedAtMs = 4_000
        table.cursors["i3"] = decided
        table.cursors["i4"] = landedCursor(bookmarkPayload(uuid: "i4"), ownerUuid: "su-unknown")
        table.cursors["i5"] = landedCursor(bookmarkPayload(uuid: "i5"), ownerUuid: "su-2")

        let result = SyncableOwnedItems.tombstones(BookmarkKind.self, locals: [], table: table,
                                                   resolve: OwnerResolver.fixture(ineligible: ["su-2"]),
                                                   scope: nil, nowMs: 5_000)

        let identities = result.identities
        XCTAssertEqual(identities, ["i1"])
    }

    /// CASE 4a.17b — 两条排除各自计进 `excluded_unmapped_owner`（V21）。
    ///
    /// 防的是什么：spec §11.2 对这个计数的定义覆盖两种排除，只喂其中一个成员进日志的
    /// 实现会让一整类排除在线上不可见。
    func testBothOwnerExclusionsAreCountedSeparatelyButBelongToOneLogField() {
        // b3 是 C1 的探针：一条**子孙**行，它的绑定引用是父（一个书签 uuid），拿那个去问
        // `isEligibleSpace` 永远为真。排除判据必须读它**坐在哪个 Space 里**，否则一个账户
        // 已软删的 Space 底下每一条非根行都会继续发布，30 天后被 purge 级联静默删掉。
        let locals = [row(identity: "b1", spaceId: "space-x"),
                      row(identity: "b2", spaceId: "space-b", isFolder: true),
                      row(identity: "b3", spaceId: "space-b", parentGuid: "g-b2")]

        let result = SyncableOwnedItems.snapshot(
            BookmarkKind.self, locals: locals, table: PhiOwnedItemTable(),
            resolve: OwnerResolver.fixture(ineligible: ["su-2"]), scope: nil, now: 5_000)

        let unmapped = result.skippedUnmappedOwner
        let ineligible = result.skippedIneligibleOwner
        let produced = result.entities.count
        XCTAssertEqual(unmapped, 1)
        XCTAssertEqual(ineligible, 2, "根级项与子孙都要被排除")
        XCTAssertEqual(produced, 0)
    }

    /// CASE 4a.18 — 停放的两种情形方向相反（8a）。
    ///
    /// 防的是什么：这是 C1 那条回归——它是唯一能删掉对端数据的错法。断言落在
    /// `cursorUpdates` 上而不是「跑完之后去看那张表」：纯函数拿的是 `table` 的值拷贝，
    /// 改不到调用方那一份。
    func testAParkedEntityOnlyTombstonesWhenThisDeviceHadAlreadyLandedIt() {
        var table = PhiOwnedItemTable()
        // p1：只有 `pendingApply`，从未落地——一条仅仅是本机还没能放下去的入站实体。
        var neverLanded = PhiOwnedItemCursor()
        neverLanded.entityId = "srv-p1"
        neverLanded.version = 7
        neverLanded.pendingApply = baselineBytes(bookmarkPayload(uuid: "p1"))
        neverLanded.ownerUuid = "su-1"
        table.cursors["p1"] = neverLanded
        // p2：落地过，之后才被停放，本机行已经被用户删掉。
        var landedThenParked = landedCursor(bookmarkPayload(uuid: "p2"),
                                            entityId: "srv-p2", version: 9)
        landedThenParked.pendingApply = baselineBytes(bookmarkPayload(uuid: "p2", title: "新"))
        table.cursors["p2"] = landedThenParked

        let result = SyncableOwnedItems.tombstones(BookmarkKind.self, locals: [], table: table,
                                                   resolve: resolve, scope: nil, nowMs: 5_000)

        let identities = result.identities
        let updated = result.cursorUpdates["p2"]
        let neverLandedUpdate = result.cursorUpdates["p1"]
        XCTAssertEqual(identities, ["p2"])
        XCTAssertNil(updated?.pendingApply)
        XCTAssertEqual(updated?.pendingDelete, true)
        XCTAssertEqual(updated?.deleteDecidedAtMs, 5_000)
        XCTAssertEqual(updated?.entityId, "srv-p2")
        XCTAssertEqual(updated?.version, 9)
        XCTAssertNil(neverLandedUpdate)
    }

    /// CASE 4a.18b — 停放项带着它在等的归属 uuid（V19 / §4.4 第 4 步）。
    ///
    /// 防的是什么：`pendingOwnerUuid` 是游标上一个真实存在的字段，没有这条通道它永远是
    /// nil，于是每一条停放项每一轮都要把整棵树重解一遍才知道能不能重试。
    func testAParkedItemRecordsTheOwnerReferenceItIsWaitingFor() {
        let plan = planned([
            arrival(bookmarkPayload(uuid: "b1", spaceUuid: "su-unknown")),
            arrival(bookmarkPayload(uuid: "b2", parentUuid: "missing-parent")),
        ])

        let waitingForSpace = plan.parked["b1"]?.pendingOwnerUuid
        let waitingForParent = plan.parked["b2"]?.pendingOwnerUuid
        XCTAssertEqual(waitingForSpace, "su-unknown")
        XCTAssertEqual(waitingForParent, "missing-parent")
    }

    // MARK: - CASE 4a.19

    /// CASE 4a.19 — 回声抑制：apply 之后立刻 snapshot ⇒ 零盖戳（9）。
    ///
    /// 防的是什么：**必须逐字段断言戳没动**，不能只比 `signature(of:)`——那个函数定义就是
    /// 「把 `updatedAtMs` 清零后的字节」，一个 apply 之后给每个字段都盖上 `now` 的实现在
    /// 签名相等这条断言下照样绿，而它会让两台机器无限互相回声。
    func testSnapshottingRightAfterAnApplyRestampsNoField() {
        let baseline = bookmarkPayload(uuid: "b1")
        var table = PhiOwnedItemTable()
        table.cursors["b1"] = landedCursor(baseline)

        let result = SyncableOwnedItems.snapshot(BookmarkKind.self, locals: [row(identity: "b1")],
                                                 table: table, resolve: resolve,
                                                 scope: nil, now: 5_000)

        let entity = result.entities["b1"]
        let stamps = [entity?.spaceUuid.updatedAtMs, entity?.parentUuid.updatedAtMs,
                      entity?.rank.updatedAtMs, entity?.title.updatedAtMs,
                      entity?.url.updatedAtMs, entity?.secondaryURL.updatedAtMs,
                      entity?.secondaryTitle.updatedAtMs]
        let produced = bytes(entity)
        let expected = bytes(baseline)
        XCTAssertEqual(stamps, Array(repeating: Int64(100), count: 7))
        XCTAssertEqual(produced, expected)
    }

    // MARK: - CASE 4a.21 / 4a.22

    /// CASE 4a.21 — `created_at_ms` 取 min，`source` 取非零、都非零取较小（11）。
    func testCreatedAtAndSourceMergeDeterministicallyInBothDirections() {
        let a = bookmarkPayload(uuid: "b1", source: 0, createdAtMs: 5_000)
        let b = bookmarkPayload(uuid: "b1", source: 2, createdAtMs: 1_000)
        let c = bookmarkPayload(uuid: "b1", source: 3, createdAtMs: 2_000)
        let d = bookmarkPayload(uuid: "b1", source: 1, createdAtMs: 2_000)

        let oneWay = BookmarkKind.merge(local: a, remote: b)
        let otherWay = BookmarkKind.merge(local: b, remote: a)
        let bothNonZero = BookmarkKind.merge(local: c, remote: d)
        let bothNonZeroReversed = BookmarkKind.merge(local: d, remote: c)

        XCTAssertEqual(oneWay.createdAtMs, 1_000)
        XCTAssertEqual(oneWay.source, 2)
        XCTAssertEqual(otherWay.createdAtMs, 1_000)
        XCTAssertEqual(otherWay.source, 2)
        XCTAssertEqual(bothNonZero.source, 1)
        XCTAssertEqual(bothNonZeroReversed.source, 1)
    }

    /// CASE 4a.22 — 未知字段在 merge 后原样保留（12）。
    ///
    /// 防的是什么：`merge` 必须从 `remote` 起手；从 `local` 起手的实现每一轮都会把新版本
    /// 客户端写的字段抹掉。
    func testUnknownFieldsSurviveAMerge() throws {
        var raw = try bookmarkPayload(uuid: "b1").serializedData()
        // field 12（`reserved 12 to 15` 里的第一个），wire type 0：tag = 12 << 3 = 0x60。
        raw.append(contentsOf: [0x60, 0x2A])
        let remote = try Phi_PhiBookmarkEntity(serializedBytes: raw)

        let merged = BookmarkKind.merge(local: bookmarkPayload(uuid: "b1"), remote: remote)

        let arrived = remote.unknownFields.data.isEmpty
        let survived = merged.unknownFields.data.isEmpty
        XCTAssertFalse(arrived)
        XCTAssertFalse(survived)
    }
}

// MARK: - 认领（§6 的规则 (i)）

extension SyncableOwnedItemsTests {

    /// 文件夹的本机占位 URL（`LocalStore+Bookmark.swift`）。所有文件夹共享它，所以文件夹
    /// **绝不**参与任何按 URL 的比较。
    private static let folderPlaceholder = URL(string: "https://bookmark.phi/folder")!

    private func folderRow(identity: String?, guid: String, title: String,
                           spaceId: String = "space-a", parentGuid: String? = nil,
                           index: Int = 0) -> PhiLocalBookmark {
        PhiLocalBookmark.fixture(guid: guid, syncId: identity, spaceId: spaceId,
                                 parentGuid: parentGuid, index: index, isFolder: true,
                                 title: title, url: Self.folderPlaceholder,
                                 createdDate: Date(timeIntervalSince1970: 1))
    }

    private func markRow(identity: String?, guid: String, url: String,
                         title: String = "T", spaceId: String = "space-a",
                         parentGuid: String? = nil, index: Int = 0,
                         contentUpdatedDate: Date? = nil) -> PhiLocalBookmark {
        PhiLocalBookmark.fixture(guid: guid, syncId: identity, spaceId: spaceId,
                                 parentGuid: parentGuid, index: index, title: title,
                                 url: URL(string: url)!,
                                 createdDate: Date(timeIntervalSince1970: 1),
                                 contentUpdatedDate: contentUpdatedDate)
    }

    /// CASE 4a.23（spec 13）— 基本认领：本机行被认领而不是被复制。
    func testAnIncomingEntityAdoptsAMatchingUnsyncedLocalRow() {
        let local = markRow(identity: nil, guid: "g1", url: "https://e.example")

        let result = SyncableOwnedItems.adopt(arrivals: [bookmarkPayload(uuid: "b1")],
                                              locals: [local], resolve: resolve)

        let pairedGuid = result.pairs["b1"]
        let adopted = result.adopted
        XCTAssertEqual(pairedGuid, "g1")
        XCTAssertEqual(adopted, 1)
    }

    /// CASE 4a.24（spec 13a / 13a′）— 字段级合并与重新发布。
    ///
    /// 防的是什么：本机赢了却不发布，对端永远停在旧值上，而两边都认为自己收敛了。
    func testAdoptionMergesFieldByFieldAndRepublishesWhenALocalFieldWins() {
        // 本机在加入期间改过标题，戳晚于远端；位置字段本机没有基线，一律取远端。
        let local = markRow(identity: nil, guid: "g1", url: "https://e.example",
                            title: "本机标题", contentUpdatedDate: Date(timeIntervalSince1970: 900))
        let remote = bookmarkPayload(uuid: "b1", spaceUuid: "su-1", rank: "k", title: "远端标题",
                                     locationStamp: 100, rankStamp: 100, contentStamp: 100)

        let adoption = SyncableOwnedItems.adopt(arrivals: [remote], locals: [local],
                                                resolve: resolve)

        // 断言落在**模块的产出**上：合并规则若只活在测试体里，一个整体采纳远端的引擎
        // 照样绿，而那正是 §6.2 点名禁止的实现。
        let merged = mergedEntity(adoption, "b1")
        let pairedGuid = adoption.pairs["b1"]
        let title = merged?.title.stringValue
        let rank = merged?.rank.stringValue
        let locationStamp = merged.map(BookmarkKind.locationStamp(of:))
        let republishes = adoption.mustRepublish.contains("b1")
        XCTAssertEqual(pairedGuid, "g1")
        XCTAssertEqual(title, "本机标题")
        XCTAssertEqual(rank, "k")
        XCTAssertEqual(locationStamp, 100)
        XCTAssertTrue(republishes)
    }

    /// `adopt` 产出的合并结果解回实体。
    private func mergedEntity(_ result: OwnedItemAdoptionResult,
                              _ identity: String) -> Phi_PhiBookmarkEntity? {
        guard let bytes = result.merges[identity],
              let envelope = try? Phi_PhiEntity(serializedBytes: bytes) else { return nil }
        return BookmarkKind.entity(from: envelope)
    }

    /// CASE 4a.24b（spec 13a′）— `updatedDate` 被推前而 `contentUpdatedDate` 不动（V29）。
    ///
    /// 防的是什么：这正是 §6.2 拒绝用 `updatedDate` 当同步戳的理由——`updateLastSeen` /
    /// `updateTabFavicon` / `normalizeIndexes` 都会把它推前，而「推前」正是让一个没人编辑
    /// 过的本机旧值赢下对端真实编辑的那个方向。`PhiLocalBookmark` 里根本没有那一列，所以
    /// 这条在结构上已经防住了；写成用例是为了让哪天有人把它加回来时立刻红。
    func testTheLocalStampIsContentUpdatedDateSoATouchedRowStillLosesToARealEdit() {
        // 一次**打开**（`updateLastSeen`）会把 `updatedDate` 推到现在，而 `contentUpdatedDate`
        // 一动不动。本机参与比较的戳仍是那个早得多的 `createdDate`，于是远端的内容值赢。
        let touched = PhiLocalBookmark.fixture(guid: "g1", spaceId: "space-a", title: "本机旧值",
                                               createdDate: Date(timeIntervalSince1970: 0.05))
        let remote = bookmarkPayload(uuid: "b1", title: "远端改名", contentStamp: 100,
                                     createdAtMs: 50)

        let adoption = SyncableOwnedItems.adopt(arrivals: [remote], locals: [touched],
                                                resolve: resolve)

        let fields = Mirror(reflecting: touched).children.compactMap(\.label)
        let merged = mergedEntity(adoption, "b1")
        let title = merged?.title.stringValue
        let republishes = adoption.mustRepublish.contains("b1")
        XCTAssertFalse(fields.contains("updatedDate"), "加回这一列就让这条用例立刻红")
        XCTAssertEqual(title, "远端改名")
        XCTAssertFalse(republishes, "本机一个字段都没赢 ⇒ 零 commit")
    }

    /// CASE 4a.25（spec 13b）— 跨轮认领。
    ///
    /// 防的是什么：规则 (i) 是**无状态、连续**的（R-M3-3-28）——写成「只在该 Space 首次
    /// 合并时跑一次」的实现，会让第二轮到达的实体在本机建出重复行。
    func testRuleOneKeepsAdoptingOnLaterRoundsAndUsesAdoptedParentsAsAnchors() {
        let folder = folderRow(identity: nil, guid: "g-folder", title: "F")
        let firstRound = SyncableOwnedItems.adopt(
            arrivals: [bookmarkPayload(uuid: "f1", isFolder: true, title: "F",
                                       url: Self.folderPlaceholder.absoluteString)],
            locals: [folder], resolve: resolve)

        // 第一轮认领的结果写回本机行，第二轮那一行已经带身份。
        let adoptedFolder = folderRow(identity: "f1", guid: "g-folder", title: "F")
        let child = markRow(identity: nil, guid: "g-child", url: "https://child.example",
                            parentGuid: "g-folder")
        let secondRound = SyncableOwnedItems.adopt(
            arrivals: [bookmarkPayload(uuid: "c1", parentUuid: "f1",
                                       url: "https://child.example")],
            locals: [adoptedFolder, child], resolve: resolve)

        let firstPair = firstRound.pairs["f1"]
        let secondPair = secondRound.pairs["c1"]
        let secondAdopted = secondRound.adopted
        let refusedToRepair = secondRound.pairs["f1"]
        XCTAssertEqual(firstPair, "g-folder")
        XCTAssertEqual(secondPair, "g-child")
        XCTAssertEqual(secondAdopted, 1)
        XCTAssertNil(refusedToRepair)
    }

    /// CASE 4a.26（spec 13c）— 先按完整键分组，再组内按位配对。
    ///
    /// 防的是什么：按 (Space, 路径) 分组再按位配的实现会把 URL 不同的两条配到一起。
    func testPairingGroupsByTheFullKeyFirstAndOnlyThenPairsPositionally() {
        let locals = [
            markRow(identity: nil, guid: "gX1", url: "https://x.example", index: 0),
            markRow(identity: nil, guid: "gY1", url: "https://y.example", index: 1),
            markRow(identity: nil, guid: "gX2", url: "https://x.example", index: 2),
            markRow(identity: nil, guid: "gY2", url: "https://y.example", index: 3),
        ]
        let arrivals = [
            bookmarkPayload(uuid: "rX2", rank: "B", url: "https://x.example"),
            bookmarkPayload(uuid: "rX1", rank: "A", url: "https://x.example"),
            bookmarkPayload(uuid: "rY1", rank: "C", url: "https://y.example"),
        ]

        let result = SyncableOwnedItems.adopt(arrivals: arrivals, locals: locals, resolve: resolve)

        let firstX = result.pairs["rX1"]
        let secondX = result.pairs["rX2"]
        let firstY = result.pairs["rY1"]
        let adopted = result.adopted
        XCTAssertEqual(firstX, "gX1")
        XCTAssertEqual(secondX, "gX2")
        XCTAssertEqual(firstY, "gY1")
        XCTAssertEqual(adopted, 3)
    }

    /// CASE 4a.27（spec 13d）— 已有身份的行永不被重新指派。
    ///
    /// 防的是什么：重新指派会让 `b1` 在账户上失去持有者，于是下一轮差分为它发一条
    /// tombstone——一次「看起来重复」的判断删掉了账户上一条真实的书签。
    func testARowThatAlreadyHasAnIdentityIsNeverReassigned() {
        let local = markRow(identity: "b1", guid: "g1", url: "https://e.example")
        var table = PhiOwnedItemTable()
        table.cursors["b1"] = landedCursor(bookmarkPayload(uuid: "b1"))

        let adoption = SyncableOwnedItems.adopt(arrivals: [bookmarkPayload(uuid: "b2")],
                                                locals: [local], resolve: resolve)
        let diff = SyncableOwnedItems.tombstones(BookmarkKind.self, locals: [local], table: table,
                                                 resolve: resolve, scope: nil, nowMs: 5_000)

        let adopted = adoption.adopted
        let pairedGuid = adoption.pairs["b2"]
        let tombstoned = diff.identities
        XCTAssertEqual(adopted, 0)
        XCTAssertNil(pairedGuid)
        XCTAssertTrue(tombstoned.isEmpty)
    }

    /// CASE 4a.28（spec 13e）— 稳态下的重复保持重复，零删除。
    ///
    /// 防的是什么：spec 把这条叫「撤回自动合并之后的核心保证」——**任何「看起来重复就删
    /// 一条」的实现必须让它红**。
    func testDeliberateDuplicatesStayDuplicatesAndProduceNoTombstone() {
        let folder = folderRow(identity: "fd", guid: "g-fd", title: "夹")
        let first = markRow(identity: "d1", guid: "g-d1", url: "https://dup.example",
                            parentGuid: "g-fd", index: 0)
        let second = markRow(identity: "d2", guid: "g-d2", url: "https://dup.example",
                             parentGuid: "g-fd", index: 1)
        let locals = [folder, first, second]
        var table = PhiOwnedItemTable()
        table.cursors["fd"] = landedCursor(bookmarkPayload(uuid: "fd", isFolder: true))
        table.cursors["d1"] = landedCursor(bookmarkPayload(uuid: "d1", parentUuid: "fd"))
        table.cursors["d2"] = landedCursor(bookmarkPayload(uuid: "d2", parentUuid: "fd"))

        let adoption = SyncableOwnedItems.adopt(
            arrivals: [bookmarkPayload(uuid: "d1", parentUuid: "fd", url: "https://dup.example"),
                       bookmarkPayload(uuid: "d2", parentUuid: "fd", url: "https://dup.example")],
            locals: locals, resolve: resolve)
        let diff = SyncableOwnedItems.tombstones(BookmarkKind.self, locals: locals, table: table,
                                                 resolve: resolve, scope: nil, nowMs: 5_000)

        let adopted = adoption.adopted
        let tombstoned = diff.identities
        let updates = diff.cursorUpdates
        XCTAssertEqual(adopted, 0)
        XCTAssertTrue(tombstoned.isEmpty)
        XCTAssertTrue(updates.isEmpty)
    }

    /// CASE 4a.29（spec 13f）— 撤回的三套机制一个字段都没回来。
    func testNeitherTheTableNorTheCursorCarriesAnyWithdrawnWindowState() {
        let withdrawn = ["firstArrival", "firstArrivalAtMs", "claimEligible", "lastArrivalMs",
                         "locallyMinted", "creatorDeviceId", "dedupedAwayAtMs"]

        let tableFields = Mirror(reflecting: PhiOwnedItemTable()).children.compactMap(\.label)
        let cursorFields = Mirror(reflecting: PhiOwnedItemCursor()).children.compactMap(\.label)

        for name in withdrawn {
            XCTAssertFalse(tableFields.contains(name), name)
            XCTAssertFalse(cursorFields.contains(name), name)
        }
    }

    /// CASE 4a.30（spec 13e 的计数半边）— `unmatchedFolders` 的定义。
    ///
    /// 防的是什么：§12.2 验收步骤 5 要断言 `adopted=3`，这两个计数是承重的，不能只在日志里
    /// 凑数。
    func testUnmatchedFoldersCountsIncomingFolderEntitiesThatFoundNoLocalRow() {
        let anchor = folderRow(identity: "pf", guid: "g-pf", title: "父")
        let mine = folderRow(identity: nil, guid: "g-mine", title: "本机夹", parentGuid: "g-pf")

        let result = SyncableOwnedItems.adopt(
            arrivals: [bookmarkPayload(uuid: "rf", parentUuid: "pf", isFolder: true,
                                       title: "远端夹",
                                       url: Self.folderPlaceholder.absoluteString)],
            locals: [anchor, mine], resolve: resolve)

        let unmatched = result.unmatchedFolders
        let adopted = result.adopted
        XCTAssertEqual(unmatched, 1)
        XCTAssertEqual(adopted, 0)
    }

    /// CASE 4a.31 — 文件夹绝不按 URL 配对。
    ///
    /// 防的是什么：所有文件夹共享那一个占位 URL；按 URL 配会把同级所有文件夹塌成一个，
    /// 而塌掉的文件夹会孤立它的孩子。
    func testFoldersPairByTitleAndNeverByTheirSharedPlaceholderURL() {
        let locals = [folderRow(identity: nil, guid: "g-a", title: "A", index: 0),
                      folderRow(identity: nil, guid: "g-b", title: "B", index: 1)]
        let arrivals = [
            bookmarkPayload(uuid: "rb", rank: "k", isFolder: true, title: "B",
                            url: Self.folderPlaceholder.absoluteString),
            bookmarkPayload(uuid: "ra", rank: "V", isFolder: true, title: "A",
                            url: Self.folderPlaceholder.absoluteString),
        ]

        let result = SyncableOwnedItems.adopt(arrivals: arrivals, locals: locals, resolve: resolve)

        let pairedA = result.pairs["ra"]
        let pairedB = result.pairs["rb"]
        let adopted = result.adopted
        let unmatched = result.unmatchedFolders
        XCTAssertEqual(pairedA, "g-a")
        XCTAssertEqual(pairedB, "g-b")
        XCTAssertEqual(adopted, 2)
        XCTAssertEqual(unmatched, 0)
    }
}

// MARK: - 修复轮回归（review C1 / C2 / I1 / I2 / I3 / M1 / M5）

extension SyncableOwnedItemsTests {

    /// C2 — 既搬了家又被改了名的实体必须同时产出 `.move` 与 `.update`。
    ///
    /// 防的是什么：落地的 move 操作不带字段补丁，内容只走 update。只产出 move 的实现会让
    /// 那次改名永远到不了本机行，而下一轮的快照拿本机的旧标题盖回账户——对端的编辑被销毁，
    /// 没有任何计数动一下，两台机器还都认为自己收敛了。
    func testAnEntityThatBothMovedAndChangedContentEmitsBothSteps() {
        var table = PhiOwnedItemTable()
        table.cursors["b1"] = landedCursor(bookmarkPayload(uuid: "b1", parentUuid: "p1",
                                                           title: "A"))
        var context = OwnedItemPlanContext()
        context.liveLocalParents = ["p1", "p2"]

        let plan = planned([arrival(bookmarkPayload(uuid: "b1", parentUuid: "p2", title: "B",
                                                    locationStamp: 300, contentStamp: 300))],
                           table: table, context: context)

        let kinds = plan.steps.filter { $0.identity == "b1" }.map(\.kind)
        XCTAssertEqual(kinds, [.move, .update])
    }

    /// C2 的另一半 — 对端一次**纯重盖戳**不产出任何步骤。
    ///
    /// 防的是什么：拿整条实体比（时间戳也算）会为每一次重盖戳产出一条空的字段补丁。
    func testAPeersPureRestampProducesNoStepAtAll() {
        var table = PhiOwnedItemTable()
        table.cursors["b1"] = landedCursor(bookmarkPayload(uuid: "b1"))

        let plan = planned([arrival(bookmarkPayload(uuid: "b1", locationStamp: 400,
                                                    rankStamp: 400, contentStamp: 400))],
                           table: table)

        let steps = plan.steps.filter { $0.identity == "b1" }
        XCTAssertTrue(steps.isEmpty)
    }

    /// I3 — `is_folder` 与本机已有的那一条不符 ⇒ 拒收，不是合并。
    ///
    /// 防的是什么：把这个分歧合并掉（取并 / 取一侧）会把一条被 §4.6 判为非法的载荷变成
    /// 一次合法的更新，而一条行不会在书签与文件夹之间变形。
    func testAnIsFolderDisagreementWithTheBaselineIsRefusedRatherThanMerged() {
        var table = PhiOwnedItemTable()
        table.cursors["b1"] = landedCursor(bookmarkPayload(uuid: "b1", isFolder: true))

        let plan = planned([arrival(bookmarkPayload(uuid: "b1", isFolder: false))], table: table)

        let refusal = BookmarkKind.refuses(bookmarkPayload(uuid: "b1", isFolder: false),
                                           baseline: bookmarkPayload(uuid: "b1", isFolder: true))
        let refused = plan.refused
        let steps = plan.steps
        XCTAssertEqual(refusal, .isFolderMismatch)
        XCTAssertEqual(refused, 1)
        XCTAssertTrue(steps.isEmpty)
    }

    /// I1 — 父不是本轮的同步合格行 ⇒ 该行本轮跳过（§4.2 第 2 条）。
    ///
    /// 防的是什么：父的实体正停放着（本机还没落地账户上那个更新的版本）时照发孩子，账户上
    /// 会留下一条指着一个本机根本还没同步的父的实体。这条排除**不计任何计数**——它不是
    /// 「归属没映射」。
    func testARowWhoseParentIsNotSyncEligibleThisRoundIsSkippedWithoutACounter() {
        var parked = PhiOwnedItemCursor()
        parked.pendingApply = baselineBytes(bookmarkPayload(uuid: "p1", isFolder: true))
        var table = PhiOwnedItemTable()
        table.cursors["p1"] = parked
        let locals = [row(identity: "p1", isFolder: true),
                      row(identity: "c1", parentGuid: "g-p1")]

        let result = SyncableOwnedItems.snapshot(BookmarkKind.self, locals: locals, table: table,
                                                 resolve: resolve, scope: nil, now: 5_000)

        let identities = Set(result.entities.keys)
        let unmapped = result.skippedUnmappedOwner
        let ineligible = result.skippedIneligibleOwner
        XCTAssertTrue(identities.isEmpty)
        XCTAssertEqual(unmapped, 0)
        XCTAssertEqual(ineligible, 0)
    }

    /// I2 — 探针确实数得到东西。
    ///
    /// 防的是什么：CASE 4a.8 断言的是 `rankBetweenCalls == 0`。若模块的 rank 生成绕过了
    /// 转发器，那条断言恒真、什么都守不住。这条用例是它的活性证明：一次真的重排必须让
    /// 计数变成非零。
    func testTheRankProbeObservesTheModulesOwnRankGeneration() {
        var table = PhiOwnedItemTable()
        table.cursors["b1"] = landedCursor(bookmarkPayload(uuid: "b1", rank: "V"))
        table.cursors["b2"] = landedCursor(bookmarkPayload(uuid: "b2", rank: "k"))
        let locals = [row(identity: "b2", index: 0), row(identity: "b1", index: 1)]
        RankProbe.reset()

        _ = SyncableOwnedItems.snapshot(BookmarkKind.self, locals: locals, table: table,
                                        resolve: resolve, scope: nil, now: 5_000)

        let calls = RankProbe.rankBetweenCalls
        XCTAssertGreaterThan(calls, 0)
    }

    /// M1 — 已经待删的游标绝不被重写删除决定的时刻。
    ///
    /// 防的是什么：`deleteDecidedAtMs` 是 A9 那条「入站位置比删除决定更新」的比较基准。
    /// 每一轮把它往前推，一次并发移动就永远取消不了删除。
    func testARedecidedDeleteNeverPushesTheDecisionTimestampForward() {
        var cursor = pendingDeleteCursor(decidedAtMs: 1_000,
                                         reconciled: baselineBytes(bookmarkPayload(uuid: "b1")))
        cursor.ownerUuid = "su-1"
        cursor.pendingApply = baselineBytes(bookmarkPayload(uuid: "b1", title: "新"))
        var table = PhiOwnedItemTable()
        table.cursors["b1"] = cursor

        let result = SyncableOwnedItems.tombstones(BookmarkKind.self, locals: [], table: table,
                                                   resolve: resolve, scope: nil, nowMs: 5_000)

        let identities = result.identities
        let updated = result.cursorUpdates["b1"]
        XCTAssertEqual(identities, ["b1"])
        XCTAssertNil(updated?.pendingApply)
        XCTAssertEqual(updated?.deleteDecidedAtMs, 1_000)
    }

    /// M4 — 游标的 `ownerUuid` 还没被刷新过 ⇒ 不发 tombstone。
    ///
    /// 防的是什么：引擎每轮要为表里的每一条游标刷新这个字段；nil 说明那条前置条件没成立，
    /// 而本模块检查不了。方向只能是保守的。
    func testACursorWithNoRefreshedOwnerNeverTombstones() {
        var table = PhiOwnedItemTable()
        table.cursors["b1"] = landedCursor(bookmarkPayload(uuid: "b1"), ownerUuid: nil)

        let result = SyncableOwnedItems.tombstones(BookmarkKind.self, locals: [], table: table,
                                                   resolve: resolve, scope: nil, nowMs: 5_000)

        let identities = result.identities
        XCTAssertTrue(identities.isEmpty)
    }

    /// M5 — uuid 为空的到达计一次 `refused`。
    func testAnArrivalWithAnEmptyUuidCountsAsRefused() {
        let plan = planned([arrival(bookmarkPayload(uuid: ""))])

        let refused = plan.refused
        let steps = plan.steps
        XCTAssertEqual(refused, 1)
        XCTAssertTrue(steps.isEmpty)
    }
}

// MARK: - 修复轮 2 回归（review F1 / F2）

extension SyncableOwnedItemsTests {

    /// `plan` 的某一条 step 里那份载荷解回实体。
    private func stepEntity(_ plan: OwnedItemPlan, _ identity: String,
                            _ kind: StepKind) -> Phi_PhiBookmarkEntity? {
        guard let payload = plan.steps.first(where: { $0.identity == identity && $0.kind == kind })?
                .payload,
              let envelope = try? Phi_PhiEntity(serializedBytes: payload) else { return nil }
        return BookmarkKind.entity(from: envelope)
    }

    /// 把一次认领的产出接进 `plan` 的入参，与引擎将来要做的接法逐字一致。
    private func adoptionContext(_ result: OwnedItemAdoptionResult) -> OwnedItemPlanContext {
        var context = OwnedItemPlanContext()
        context.pairs = result.pairs
        context.adoptedMerges = result.merges
        context.adoptedFieldWrites = result.fieldWrites
        return context
    }

    /// F1 (a) — 认领的身份落地的是**合并结果**，不是远端那一份。
    ///
    /// 防的是什么：一个忽略 `context.adoptedMerges`、直接落远端的实现——正是 §6.2 点名禁止
    /// 的「整体采纳远端」——会让 `.claim` 那条 step 的载荷带着「远端标题」，于是下面那条
    /// `XCTAssertEqual(claimedTitle, "本机标题")` 立刻红。它同时钉住 `.claim` + `.update`
    /// 这一对：落地的 claim 操作只写 `syncId`，内容只走 update，只产出一条就把那次合并丢了。
    func testAClaimedIdentityLandsTheMergedEntityRatherThanTheRemoteWholesale() {
        // 本机的标题更新（`contentUpdatedDate` 更晚），而 `secondary_title` 这一侧远端更新：
        // 于是合并结果两边各赢一个字段，既要重新发布，又确实要写字段。
        let local = markRow(identity: nil, guid: "g1", url: "https://e.example",
                            title: "本机标题", contentUpdatedDate: Date(timeIntervalSince1970: 900))
        var remote = bookmarkPayload(uuid: "b1", spaceUuid: "su-1", rank: "k", title: "远端标题",
                                     locationStamp: 100, rankStamp: 100, contentStamp: 100)
        remote.secondaryTitle = stamped("远端副标题", at: 1_000_000)

        let adoption = SyncableOwnedItems.adopt(arrivals: [remote], locals: [local],
                                                resolve: resolve)
        let plan = planned([arrival(remote)], context: adoptionContext(adoption))

        let kinds = plan.steps.filter { $0.identity == "b1" }.map(\.kind)
        let claimed = stepEntity(plan, "b1", .claim)
        let patched = stepEntity(plan, "b1", .update)
        let claimedTitle = claimed?.title.stringValue
        let claimedSecondary = claimed?.secondaryTitle.stringValue
        let claimedRank = claimed?.rank.stringValue
        let claimedLocation = claimed.map(BookmarkKind.locationStamp(of:))
        let republishes = adoption.mustRepublish.contains("b1")
        XCTAssertEqual(kinds, [.claim, .update])
        XCTAssertEqual(claimedTitle, "本机标题", "本机赢下的内容字段")
        XCTAssertEqual(claimedSecondary, "远端副标题", "远端赢下的内容字段")
        XCTAssertEqual(claimedRank, "k", "位置取远端")
        XCTAssertEqual(claimedLocation, 100, "位置取远端")
        XCTAssertEqual(patched, claimed, "两条 step 带的是同一份合并结果")
        XCTAssertTrue(republishes)
    }

    /// F1 (b) — 本机行与远端逐字相同 ⇒ 只有 `.claim`，零重新发布。
    ///
    /// 防的是什么：无条件产出 `.update` 会为每一条认领的行发一条空补丁，而首次同步里
    /// 认领的行可能有上千条。
    func testAClaimedRowIdenticalToTheRemoteNeedsNoFieldWriteAndNoRepublish() {
        let local = PhiLocalBookmark.fixture(guid: "g1", spaceId: "space-a", title: "T",
                                             createdDate: Date(timeIntervalSince1970: 0.05))
        let remote = bookmarkPayload(uuid: "b1", createdAtMs: 50)

        let adoption = SyncableOwnedItems.adopt(arrivals: [remote], locals: [local],
                                                resolve: resolve)
        let plan = planned([arrival(remote)], context: adoptionContext(adoption))

        let kinds = plan.steps.filter { $0.identity == "b1" }.map(\.kind)
        let republishes = adoption.mustRepublish.contains("b1")
        let writes = adoption.fieldWrites.contains("b1")
        XCTAssertEqual(kinds, [.claim])
        XCTAssertFalse(republishes)
        XCTAssertFalse(writes)
    }

    /// F2 — 合并算不出来 ⇒ 那一对不成立，绝不退回「整体采纳远端」。
    ///
    /// 防的是什么：投影失败时静默按远端落地，会在一次归属解析抖动里吃掉用户在加入期间做的
    /// 编辑。构造一个正向与反向不一致的解析器（`localSpaceId` 认得 `su-1`，`syncUuid` 却
    /// 认不得 `space-a`），投影因此拿不到 Space 的 syncUuid。
    func testAPairWhoseMergeCannotBeComputedIsDroppedRatherThanTakenWholesale() {
        let brokenResolve = OwnerResolver(syncUuid: { _ in nil },
                                          localSpaceId: { $0 == "su-1" ? "space-a" : nil },
                                          isEligibleSpace: { _ in true },
                                          globalUuid: { _ in nil },
                                          localProfileId: { _ in nil })
        let local = markRow(identity: nil, guid: "g1", url: "https://e.example")

        let result = SyncableOwnedItems.adopt(arrivals: [bookmarkPayload(uuid: "b1")],
                                              locals: [local], resolve: brokenResolve)

        let adopted = result.adopted
        let pairedGuid = result.pairs["b1"]
        let merged = result.merges["b1"]
        let dropped = result.unmergeablePairs
        XCTAssertEqual(adopted, 0)
        XCTAssertNil(pairedGuid)
        XCTAssertNil(merged)
        XCTAssertEqual(dropped, 1)
    }
}

// MARK: - PinKind（Task 4b）

/// `PinKind` 的模块级用例：与上面那一族同样**没有 SwiftData、没有引擎、没有持久化**。
///
/// 单独一个类而不是 `SyncableOwnedItemsTests` 的 extension：pin 的 `arrival` / `planned`
/// / 行构造与书签同名不同型，同一个类里两套重载会让每一处调用都要写类型标注。
///
/// 类标 `@MainActor` 是因为 CASE 4b.2 要用 Task 0 那个 `@MainActor` 的 `FakePinAccess`
/// 去钉 `allPins()` 的契约。
@MainActor
final class PinKindTests: XCTestCase {

    private let resolve = OwnerResolver.fixture()

    /// 把字面量 `"app"` 映射到**它自己**的解析器——引擎侧（Task 5b / Task 6）构造
    /// `OwnerResolver` 时要做的正是这一件事。
    ///
    /// 为什么必须在解析器里做、而不是在 `tombstones` 里特判这个字符串：`tombstones`
    /// 判「这条游标的归属还在不在」走的是 `localSpaceId` 与 `localProfileId`，两个都解析
    /// 不出来就按**归属未映射**跳过（§4.2 第 1 条）。一条 App 作用域 pin 的 `ownerUuid`
    /// 是字面量 `"app"`，于是那条游标永远不产出 tombstone——用户删掉的 App 作用域 pin
    /// 在账户上不死，每台新设备加入都把它拉回来（CASE 4b.4b）。特判那个字符串则会给
    /// 「归属未映射」这条规则在 pin 侧开一个例外，而那条规则正是 §4.7 用来防「一次映射
    /// 抖动删掉整个 Space 的书签」的。
    private let resolveWithApp = OwnerResolver.fixture(
        profileUuids: ["Default": "pu-1", "app": "app"])

    // MARK: - 小工具

    /// 本机行的内容取值与 `pinPayload` 的默认值逐字段对齐（`createdDate` 1 秒 = 1000 ms
    /// 正是 `pinPayload` 的 `createdAtMs` 默认值），于是「没有任何变化」的用例产出的字节
    /// 真的等于基线。
    private func pinRow(lineageId: String = "LX",
                        guid: String = "p1",
                        spaceId: String? = nil,
                        profileId: String? = "Default",
                        index: Int = 0,
                        title: String = "T",
                        url: URL = URL(string: "https://e.example")!,
                        splitPartnerLineageId: String? = nil,
                        contentUpdatedDate: Date? = nil,
                        isDormant: Bool = false) -> PhiLocalPin {
        PhiLocalPin.fixture(lineageId: lineageId, guid: guid, spaceId: spaceId,
                            profileId: profileId, index: index, title: title, url: url,
                            splitPartnerLineageId: splitPartnerLineageId,
                            createdDate: Date(timeIntervalSince1970: 1),
                            contentUpdatedDate: contentUpdatedDate, isDormant: isDormant)
    }

    private func snapshot(_ locals: [PhiLocalPin],
                          table: PhiOwnedItemTable = PhiOwnedItemTable(),
                          resolve: OwnerResolver? = nil,
                          scope: PinnedTabScope? = .space,
                          now: Int64 = 5_000) -> OwnedItemSnapshotResult<Phi_PhiPinTabEntity> {
        SyncableOwnedItems.snapshot(PinKind.self, locals: locals, table: table,
                                    resolve: resolve ?? self.resolve, scope: scope, now: now)
    }

    private func tombstones(_ locals: [PhiLocalPin],
                            table: PhiOwnedItemTable,
                            resolve: OwnerResolver? = nil,
                            scope: PinnedTabScope? = .space,
                            nowMs: Int64 = 5_000) -> OwnedItemTombstoneResult {
        SyncableOwnedItems.tombstones(PinKind.self, locals: locals, table: table,
                                      resolve: resolve ?? self.resolve, scope: scope,
                                      nowMs: nowMs)
    }

    /// 一条**活**游标，带基线与归属。
    private func landedCursor(_ payload: Phi_PhiPinTabEntity,
                              entityId: String = "srv-1",
                              version: Int64 = 1,
                              ownerUuid: String? = "su-1") -> PhiOwnedItemCursor {
        ownedCursor(reconciled: baselineBytes(payload), entityId: entityId,
                    version: version, ownerUuid: ownerUuid)
    }

    // MARK: - CASE 4b.1

    /// CASE 4b.1（spec 7c）— pin 没有 location：一条 lineage 在两个 owner 下就是两条实体，
    /// 而 `rank` 走**普通 LWW**。
    ///
    /// 防的是什么：owner 是身份的一半（R-M3-3-15），把它当成一个可合并的字段、或者把一条
    /// lineage 当成一条实体，会让两个 Space 里的同一条 pin 在字典里互相覆盖——账户上只剩
    /// 一条，另一个 Space 里那一条既到不了别的机器、也无法被别的机器删除。`rank` 若套用
    /// 书签那条「相干」规则，它要去问一个 pin 根本没有的 location，结果由一个恒相等的值
    /// 决定。
    func testOneLineageInThreeOwnersIsThreeEntitiesAndItsRankIsPlainLastWriterWins() {
        // §12.1 item 7c：同一条 lineage 在**三个** Space 的行 ⇒ 三条实体，**没有任何一条
        // 被字典覆盖掉**。两个的版本测不出「按 lineage 当键」这一族错法里最常见的那一个
        // ——写成 `entities[lineage]` 的实现在两条时还剩一条，看上去像「少了一条」，三条时
        // 才明显是「只剩最后写进去的那一条」。
        let rows = [pinRow(guid: "p1", spaceId: "space-a"),
                    pinRow(guid: "p2", spaceId: "space-b"),
                    pinRow(guid: "p3", spaceId: "space-c")]
        let threeSpaces = OwnerResolver.fixture(
            spaceUuids: ["space-a": "su-1", "space-b": "su-2", "space-c": "su-3"])

        let result = snapshot(rows, resolve: threeSpaces, scope: .space)

        let keys = Set(result.entities.keys)
        let count = result.entities.count
        XCTAssertEqual(keys, ["lx:su-1", "lx:su-2", "lx:su-3"])
        XCTAssertEqual(count, 3)

        // 同一身份的两条实体：戳大的 rank 赢，两个方向结果相同，没有 location 参与。
        let older = pinPayload(lineage: "lx", ownerKey: "su-1", rank: "a", rankStamp: 100)
        let newer = pinPayload(lineage: "lx", ownerKey: "su-1", rank: "b", rankStamp: 200)
        let forward = PinKind.merge(local: older, remote: newer).rank.stringValue
        let backward = PinKind.merge(local: newer, remote: older).rank.stringValue
        XCTAssertEqual(forward, "b")
        XCTAssertEqual(backward, "b")
    }

    // MARK: - CASE 4b.2 / 4b.3 / 4b.3b

    /// CASE 4b.2（spec 8b 第一句）— 只剩休眠行的 lineage：不进快照，但**产出** tombstone。
    ///
    /// 防的是什么：v3 的 spec 在这里写反了（V12）。`allPins()` 的契约是「当前作用域内、
    /// **非休眠**的全部行」，所以一条只剩休眠副本的 lineage 在差分眼里就是「本机没有这
    /// 一行」，三条判据全中。写成「不产出」的实现会让一条用户已经收起来的 pin 永远赖在
    /// 账户上，每台新设备加入都把它拉回来。
    ///
    /// 两个断言面各钉一半：假 access 的 `allPins()` 真的把休眠行滤掉（契约），而把那条
    /// 休眠行**直接**喂给模块时 `PinKind` 自己也不发布它（`PhiLocalPin.isDormant` 的自述
    /// 「休眠行不进快照，也不参与差分」在 kind 这一层也成立）。
    func testALineageLeftWithOnlyADormantRowLeavesTheSnapshotButStillTombstones() {
        let dormant = pinRow(guid: "p1", spaceId: "space-a", isDormant: true)
        var table = PhiOwnedItemTable()
        table.cursors["lx:su-1"] = landedCursor(pinPayload(lineage: "lx", ownerKey: "su-1"))
        let access = FakePinAccess(scope: .space, account: .space, rows: [dormant])

        let visible = access.allPins()
        let published = snapshot([dormant], table: table).entities
        let result = tombstones([dormant], table: table)

        let visibleCount = visible.count
        let publishedCount = published.count
        let identities = result.identities
        XCTAssertEqual(visibleCount, 0, "allPins() 的契约：非休眠的全部行")
        XCTAssertEqual(publishedCount, 0)
        XCTAssertEqual(identities, ["lx:su-1"])
    }

    /// CASE 4b.3（spec 8b 第三句）— 同 owner 下多条同 lineage 活动行，**全部**消失才产出。
    ///
    /// 防的是什么：按「找到一条就算在」写对；按「数量变了就算删」写错——后者会在用户关掉
    /// 其中一个副本时，把整条 lineage 从账户上删掉。
    func testALineageWithSeveralActiveRowsOnlyTombstonesWhenTheLastOneIsGone() {
        let rows = [pinRow(guid: "p1", spaceId: "space-a", index: 0),
                    pinRow(guid: "p2", spaceId: "space-a", index: 1)]
        var table = PhiOwnedItemTable()
        table.cursors["lx:su-1"] = landedCursor(pinPayload(lineage: "lx", ownerKey: "su-1"))

        let withBoth = tombstones(rows, table: table).identities
        let withOne = tombstones([rows[0]], table: table).identities
        let withNone = tombstones([], table: table).identities

        XCTAssertEqual(withBoth, [])
        XCTAssertEqual(withOne, [])
        XCTAssertEqual(withNone, ["lx:su-1"])
    }

    /// CASE 4b.3b（spec 8b 第二句 / V27）— 活动行与休眠备份并存：只投影活动行，不产出
    /// tombstone。
    ///
    /// 防的是什么：把休眠副本也算进快照会让同一条身份有两个候选投影，两次运行挑中不同的
    /// 那一条就产生一次假的字段变化；而把「存在休眠副本」当成「还在」的实现会与 CASE 4b.2
    /// 直接冲突。
    func testAnActiveRowBesideADormantBackupProjectsOnlyTheActiveOne() {
        let active = pinRow(guid: "p1", spaceId: "space-a", index: 0, title: "活")
        let dormant = pinRow(guid: "p2", spaceId: "space-a", index: 1, title: "休眠",
                             isDormant: true)
        var table = PhiOwnedItemTable()
        table.cursors["lx:su-1"] = landedCursor(pinPayload(lineage: "lx", ownerKey: "su-1"))

        let published = snapshot([active, dormant], table: table).entities
        let identities = tombstones([active, dormant], table: table).identities

        let keys = Set(published.keys)
        let title = published["lx:su-1"]?.title.stringValue
        XCTAssertEqual(keys, ["lx:su-1"])
        XCTAssertEqual(title, "活")
        XCTAssertEqual(identities, [])
    }

    // MARK: - CASE 4b.4 / 4b.4b / 4b.5

    /// CASE 4b.4（spec 14）— owner 按 §7.2 的表推导：Space / Profile / App 各一条。
    ///
    /// 防的是什么：§7.2 把 App 作用域定义为「两者都为 nil」，而 `pinnedTab(_:belongsTo:)`
    /// 保证一条行恰好属于一个 owner，所以判据是**先看 `spaceId` 再看 `profileId`**，不是
    /// 「哪个非 nil 用哪个」——一条 Space 作用域的行两个字段都非 nil。
    func testTheOwnerIsDerivedFromTheRowShapeForEachOfTheThreeScopes() {
        let spaceScoped = pinRow(guid: "p1", spaceId: "space-a", profileId: nil)
        let profileScoped = pinRow(guid: "p2", spaceId: nil, profileId: "Default")
        let appScoped = pinRow(guid: "p3", spaceId: nil, profileId: nil)

        let space = PinKind.eligibilityOwner(of: spaceScoped, resolve: resolve, scope: .space)
        let profile = PinKind.eligibilityOwner(of: profileScoped, resolve: resolve, scope: .profile)
        let app = PinKind.eligibilityOwner(of: appScoped, resolve: resolve, scope: .app)
        XCTAssertEqual(space, "su-1")
        XCTAssertEqual(profile, "pu-1")
        XCTAssertEqual(app, "app")

        // 一条 Space 作用域的真实行两个字段都非 nil（`PhiLocalPin.spaceId` 的自述）：
        // 判据仍然先看 `spaceId`。
        let bothSet = pinRow(guid: "p4", spaceId: "space-b", profileId: "Default")
        let derived = PinKind.eligibilityOwner(of: bothSet, resolve: resolve, scope: .space)
        XCTAssertEqual(derived, "su-2")
    }

    /// CASE 4b.4b — App 作用域的游标照常产出 tombstone。
    ///
    /// 防的是什么：`"app"` 两个解析器都不认，按「归属未映射」跳过的话这条游标永远不产出
    /// tombstone——用户删掉的 App 作用域 pin 在账户上不死，每台新设备都把它拉回来。这条
    /// 用例只有在 resolver 把 `"app"` 映射到自己之后才绿，所以它同时是 Task 5b / Task 6
    /// 那一行注释的探测器。
    func testAnAppScopedCursorStillTombstonesOnceTheResolverMapsTheLiteralToItself() {
        var table = PhiOwnedItemTable()
        table.cursors["lx:app"] = landedCursor(pinPayload(lineage: "lx", ownerKey: "app"),
                                               ownerUuid: "app")

        let mapped = tombstones([], table: table, resolve: resolveWithApp, scope: .app).identities
        let unmapped = tombstones([], table: table, resolve: resolve, scope: .app).identities

        XCTAssertEqual(mapped, ["lx:app"])
        XCTAssertEqual(unmapped, [], "解析器不认 \"app\" 时它被当作归属未映射——这正是要修的")
    }

    /// CASE 4b.5 — 映射缺失 ⇒ 排除，**不退化成 `"app"`**。
    ///
    /// 防的是什么：退化成 `"app"` 会把一条 Space 作用域的 pin 发成账户全局的，对端按 App
    /// 作用域落地之后它在**每一个** Space 里都出现。
    func testARowWhoseSpaceHasNoMappingIsExcludedRatherThanFallingBackToTheAppScope() {
        let orphan = pinRow(guid: "p1", spaceId: "space-z")

        let owner = PinKind.eligibilityOwner(of: orphan, resolve: resolve, scope: .space)
        let result = snapshot([orphan], scope: .space)

        let produced = result.entities.count
        let unmapped = result.skippedUnmappedOwner
        XCTAssertNil(owner)
        XCTAssertEqual(produced, 0)
        XCTAssertEqual(unmapped, 1)
    }

    // MARK: - CASE 4b.6

    /// CASE 4b.6 — `lineageKey` 归一并贯穿身份与 client tag。
    ///
    /// 防的是什么：`PhiSyncEntity.pinClientTag(_:ownerKey:)` 自己**不做**任何大小写归一
    /// （有意如此，它是一个纯拼接函数），归一的责任全部落在 `lineageKey(_:)` 上。三处
    /// 共用它——tag 的构造、§5.1 的索引种子、落地时的匹配——任何一处漏掉，算出的 hash 与
    /// 线上那条永不相等，§2.5 的接收端校验会把**每一条** pin 实体都判成伪造载荷。
    func testTheLineageKeyNormalizesOnceAndRunsThroughBothTheIdentityAndTheTag() {
        let key = PinKind.lineageKey("LX-Abc")
        let row = pinRow(lineageId: "LX-Abc", guid: "p1", profileId: "Default")

        let identity = PinKind.identity(of: row, resolve: resolve, scope: .profile)
        XCTAssertEqual(key, "lx-abc")
        XCTAssertEqual(identity, "lx-abc:pu-1")

        // 身份的后半段与 client tag 的后半段逐字一致。
        let tag = identity.map { PinKind.tagPrefix + $0 }
        let built = PhiSyncEntity.pinClientTag(key, ownerKey: "pu-1")
        XCTAssertEqual(tag, built)
    }

    // MARK: - CASE 4b.7

    /// CASE 4b.7（spec 14 后半）— 换 owner = 旧 tag 的 tombstone + 新 tag 的 create。
    ///
    /// 防的是什么：把它当成一次字段更新会在线上留下一条谁都不再持有、也永远不会被差分
    /// 判成删除的孤儿实体。`PinApplyOp` 里因此**不存在** `rebind`。
    func testMovingAPinToAnotherOwnerTombstonesTheOldTagAndCreatesTheNewOne() {
        var table = PhiOwnedItemTable()
        table.cursors["lx:su-1"] = landedCursor(pinPayload(lineage: "lx", ownerKey: "su-1"))
        let moved = pinRow(guid: "p1", spaceId: "space-b")

        let published = snapshot([moved], table: table).entities
        let identities = tombstones([moved], table: table).identities

        let keys = Array(published.keys)
        XCTAssertEqual(keys, ["lx:su-2"])
        XCTAssertEqual(identities, ["lx:su-1"])
    }

    // MARK: - CASE 4b.8

    /// CASE 4b.8（spec 14b / A11）— 同 owner 下的同 lineage 变体重铸，落在 `PinApplyBatch` 里。
    ///
    /// 防的是什么：做成发布段 pre-pass 的旁路写，会在「重铸已提交、实体未发布」的中间态
    /// 崩掉，而重铸不可逆（旧 lineage 已经不在任何行上）。按「一条实体、多个物理副本」写
    /// 则会留下一整类**永远同步不了**的行：第二个副本没有自己的身份，既到不了别的机器，
    /// 也无法被别的机器删除。
    func testVariantsUnderOneOwnerAreRelineagedKeepingTheLowestIndexRow() {
        let rows = [pinRow(guid: "p1", spaceId: "space-a", index: 0),
                    pinRow(guid: "p2", spaceId: "space-a", index: 1)]

        let batch = PinKind.normalizeVariants(locals: rows)

        let ops = batch.ops
        XCTAssertEqual(ops.count, 1)
        guard case .relineage(let guid, let newLineageId)? = ops.first else {
            return XCTFail("期待恰好一条 relineage")
        }
        XCTAssertEqual(guid, "p2", "index 最小的那一条保留原 lineage")
        XCTAssertNotEqual(newLineageId, "LX")
        XCTAssertNotEqual(PinKind.lineageKey(newLineageId), "lx")
        XCTAssertFalse(newLineageId.isEmpty)
        // 铸出来的值本身要能当一条线上 lineage 用：已归一、且不会被 §4.6 判成非法。
        XCTAssertEqual(PinKind.lineageKey(newLineageId), newLineageId)
    }

    /// CASE 4b.8（4b-4）— 重铸出来的 lineage **跨设备确定**。
    ///
    /// 防的是什么：A11 的场景就是「两台机器跑同一次确定性迁移、面对同一对变体」。用
    /// `UUID()` 各铸一个的话，两边各自发布一条对方没有的实体、又各自落地对方那一条，而
    /// §6.7 排除了 pin 的认领——**没有任何东西会去重**，用户每个变体多出一个固定标签页，
    /// 两台机器都是。随机实现在这条上必红。
    func testTheRemintedLineageIsDeterministicAcrossDevices() {
        // 同一批行在「另一台机器」上的样子：物理 guid 按设备重铸，lineage 与 index 由那次
        // 确定性迁移决定，所以两边一致。
        let deviceA = [pinRow(guid: "p1", spaceId: "space-a", index: 0),
                       pinRow(guid: "p2", spaceId: "space-a", index: 1),
                       pinRow(guid: "p3", spaceId: "space-a", index: 2)]
        let deviceB = [pinRow(guid: "q1", spaceId: "space-a", index: 0),
                       pinRow(guid: "q2", spaceId: "space-a", index: 1),
                       pinRow(guid: "q3", spaceId: "space-a", index: 2)]

        let first = mintedLineages(PinKind.normalizeVariants(locals: deviceA))
        let again = mintedLineages(PinKind.normalizeVariants(locals: deviceA))
        let other = mintedLineages(PinKind.normalizeVariants(locals: deviceB))

        XCTAssertEqual(first.count, 2, "三条变体重铸两条，index 最小的那一条不动")
        XCTAssertEqual(first, again, "同一批输入跑两次产出同一批 lineage")
        XCTAssertEqual(first, other, "另一台设备的同一次迁移结果铸出同一批 lineage")
        XCTAssertNotEqual(first[0], first[1], "ordinal 不同 ⇒ lineage 不同")

        // index 最小的那一条一个 op 都没有。
        let targets = relineageGuids(PinKind.normalizeVariants(locals: deviceA))
        XCTAssertEqual(targets, ["p2", "p3"])
    }

    private func mintedLineages(_ batch: PinApplyBatch) -> [String] {
        batch.ops.compactMap {
            guard case .relineage(_, let newLineageId) = $0 else { return nil }
            return newLineageId
        }
    }

    private func relineageGuids(_ batch: PinApplyBatch) -> [String] {
        batch.ops.compactMap {
            guard case .relineage(let guid, _) = $0 else { return nil }
            return guid
        }
    }

    /// CASE 4b.8（后半）— 一个 owner 一组：不同 owner 下的同 lineage 行**不是**变体。
    ///
    /// 防的是什么：按 lineage 单独分组会把「一条 lineage 在 N 个 Space 里」这个**正常**
    /// 形状（`migratePinnedTabs` Profile → Space 的扇出）判成 N-1 条要重铸的变体，于是
    /// 一次作用域迁移之后两台机器各自重铸、各自造出一批只有自己有的 pin。
    func testTheSameLineageInTwoOwnersIsNotAVariantAndIsNeverRelineaged() {
        let rows = [pinRow(guid: "p1", spaceId: "space-a"),
                    pinRow(guid: "p2", spaceId: "space-b")]

        let ops = PinKind.normalizeVariants(locals: rows).ops

        XCTAssertTrue(ops.isEmpty)
    }

    // MARK: - CASE 4b.9

    /// CASE 4b.9（spec 14c / R-M3-3-23）— 作用域往返之后的复活沿用**旧游标**。
    ///
    /// 防的是什么：用 `entityId == ""` / `baseVersion == 0` 发 create 会被服务端按
    /// `baseVersion` 不匹配拒掉，这条 pin 此后每一轮都重试同一个必然失败的提交。
    ///
    /// 断言落在「快照产出的身份就是那条游标的键」上：发布段的切片构造（Task 6 Step 5）读
    /// 的正是 `table.cursors[身份]` 的 `entityId` 与 `version`，所以身份一旦漂掉（lineage
    /// 没归一、owner 推导换了一种写法），它找到的就是「没有游标」，于是发 create。
    /// **不断言「游标没被快照改动」**（V34）：`snapshot` 收的是 `table` 的值拷贝，那条断言
    /// 对任何实现都恒真。
    func testAResurrectedPinKeepsTheIdentityThatAlreadyCarriesTheServerTriple() {
        var table = PhiOwnedItemTable()
        var tombstoned = landedCursor(pinPayload(lineage: "lx", ownerKey: "pu-1"),
                                      entityId: "e-lx", version: 42, ownerUuid: "pu-1")
        tombstoned.deletedAtMs = 900
        table.cursors["lx:pu-1"] = tombstoned
        let revived = pinRow(guid: "p1", profileId: "Default")

        let result = snapshot([revived], table: table, scope: .profile)

        let keys = Set(result.entities.keys)
        let cursor = table.cursors[keys.first ?? ""]
        let entityId = cursor?.entityId
        let version = cursor?.version
        XCTAssertEqual(keys, ["lx:pu-1"], "复活的实体落在那条 tombstone 游标的键上")
        XCTAssertEqual(entityId, "e-lx")
        XCTAssertEqual(version, 42)
    }
}

// MARK: - PinKind 的入站半边（CASE 4b.10 – 4b.15）

extension PinKindTests {

    private func arrival(_ payload: Phi_PhiPinTabEntity,
                         entityId: String = "srv-1",
                         version: Int64 = 1) -> OwnedItemArrival<Phi_PhiPinTabEntity> {
        OwnedItemArrival(entity: payload, entityId: entityId, version: version)
    }

    private func planned(_ arrivals: [OwnedItemArrival<Phi_PhiPinTabEntity>],
                         parked: [String: ParkedOwnedItem] = [:],
                         table: PhiOwnedItemTable = PhiOwnedItemTable(),
                         resolve: OwnerResolver? = nil,
                         context: OwnedItemPlanContext = OwnedItemPlanContext()) -> OwnedItemPlan {
        SyncableOwnedItems.plan(PinKind.self, arrivals: arrivals, parked: parked, table: table,
                                resolve: resolve ?? OwnerResolver.fixture(), context: context)
    }

    private func pendingDeleteTable(_ identity: String,
                                   decidedAtMs: Int64 = 1_000) -> PhiOwnedItemTable {
        var table = PhiOwnedItemTable()
        table.cursors[identity] = pendingDeleteCursor(decidedAtMs: decidedAtMs)
        return table
    }

    // MARK: - CASE 4b.10

    /// CASE 4b.10（spec 15 / R-M3-3-12）— 作用域不一致：零发布 + 入站**全部停放**，收敛
    /// 之后的第一轮原样落地。
    ///
    /// 防的是什么（其一）：丢弃的话，共享 marker 已经逐页推过去了，服务端只按
    /// `version > marker` 下发——那些实体**再也不会重发**，直到某个对端碰巧再编辑一次。
    /// 而这一轮恰恰是最可能带着 pin 实体的那一轮：作用域是随设置通道落地的，对端正是在
    /// 那一刻重新发布了它按新作用域派生出的 pin。
    ///
    /// 防的是什么（其二，V7）：`OwnedItemPlanContext` 不带 `localScope` / `accountScope`
    /// 这两个成员时，这条 Expected **没有任何输入能产出**——`plan` 看不到作用域，就不可能
    /// 因为作用域而把整批入站停放。
    func testAScopeMismatchParksEveryArrivalAndTheNextAgreeingRoundLandsThem() {
        var mismatched = OwnedItemPlanContext()
        mismatched.localScope = .space
        mismatched.accountScope = .profile

        let parkedRound = planned([arrival(pinPayload(lineage: "lx", ownerKey: "pu-1"))],
                                  context: mismatched)

        let mismatchedSteps = parkedRound.steps
        let parkedKeys = Set(parkedRound.parked.keys)
        let waitingFor = parkedRound.parked["lx:pu-1"]?.pendingOwnerUuid
        XCTAssertTrue(mismatched.scopeMismatch)
        XCTAssertTrue(mismatchedSteps.isEmpty)
        XCTAssertEqual(parkedKeys, ["lx:pu-1"], "入站的那条进 parked，不是被丢弃")
        XCTAssertEqual(waitingFor, "pu-1")

        // 作用域收敛之后的第一轮：把上一轮的 `parked` 原样传回去。
        var agreed = OwnedItemPlanContext()
        agreed.localScope = .profile
        agreed.accountScope = .profile

        let landedRound = planned([], parked: parkedRound.parked, context: agreed)

        let landedIdentities = landedRound.steps.map(\.identity)
        let landedKinds = landedRound.steps.map(\.kind)
        let stillParked = Array(landedRound.parked.keys)
        XCTAssertFalse(agreed.scopeMismatch)
        XCTAssertEqual(landedIdentities, ["lx:pu-1"])
        XCTAssertEqual(landedKinds, [.create])
        XCTAssertTrue(stillParked.isEmpty)
    }

    // MARK: - CASE 4b.11 / 4b.11c

    /// CASE 4b.11（spec 16 / §7.4）— 拆分对只到一条时，快照发**基线里**的 partner，不发
    /// 空串。
    ///
    /// 防的是什么：本机行的 `splitPartnerGuid` 是 nil（伙伴还没落地），而基线里的
    /// `split_partner_uuid` 是伙伴的 lineage。判出「这个字段变了」并把 `""` 盖上 `now`
    /// 发出去，等于宣布「这条 pin 不再有拆分伙伴」——会在对端把一个完好的拆分对拆开，而
    /// 这台机器只是接收了它。
    func testAHalfLandedSplitPairReEmitsTheBaselinePartnerRatherThanClearingIt() {
        let baseline = pinPayload(lineage: "lx", ownerKey: "pu-1", splitPartner: "lb")
        var table = PhiOwnedItemTable()
        table.cursors["lx:pu-1"] = ownedCursor(reconciled: baselineBytes(baseline),
                                               entityId: "srv-1", version: 1,
                                               ownerUuid: "pu-1")
        let halfLanded = pinRow(guid: "p1", profileId: "Default", splitPartnerLineageId: nil)

        let result = snapshot([halfLanded], table: table, scope: .profile)

        let entity = result.entities["lx:pu-1"]
        let partner = entity?.splitPartnerUuid.stringValue
        let partnerStamp = entity?.splitPartnerUuid.updatedAtMs
        XCTAssertEqual(partner, "lb")
        XCTAssertEqual(partnerStamp, 100, "照抄基线那一份，连戳一起——它不是一次本机变化")
    }

    /// CASE 4b.11c（spec item 16 / V28）— 伙伴到达时产出的是一条**普通的字段更新**。
    ///
    /// 防的是什么：既有的 `reconcilePinnedSplitPartners()` 是给**本机**拆分操作用的启发式
    /// 修复（它遍历活动窗口里的 `SplitGroup`，而一对由同步落地的拆分 pin 根本没有活动
    /// group）。让同步落地去调它，等于把一个「猜哪两条该配对」的算法插进一条已经有确定
    /// 答案（`split_partner_uuid` 字段）的路径。
    ///
    /// **本任务能观察到的是这条**：`plan` 为一次 partner 变化产出的是 `.update` 而不是
    /// 别的相，于是落地段（Task 6b）拿到的是 `PinApplyOp.update` 这一条确定的写。假件的
    /// `lastAppliedOps` 断言要等引擎接线之后才有被测对象（CASE 6b.12）。
    func testAPartnerLinkArrivingIsAPlainFieldUpdate() {
        let baseline = pinPayload(lineage: "lx", ownerKey: "pu-1", splitPartner: "")
        var table = PhiOwnedItemTable()
        table.cursors["lx:pu-1"] = ownedCursor(reconciled: baselineBytes(baseline),
                                               entityId: "srv-1", version: 1,
                                               ownerUuid: "pu-1")
        let linked = pinPayload(lineage: "lx", ownerKey: "pu-1", splitPartner: "lb",
                                contentStamp: 2_000)

        let plan = planned([arrival(linked)], table: table)

        let kinds = plan.steps.map(\.kind)
        let identities = plan.steps.map(\.identity)
        XCTAssertEqual(kinds, [.update], "partner 变化算进内容签名，且只算进内容签名")
        XCTAssertEqual(identities, ["lx:pu-1"])
    }

    // MARK: - CASE 4b.12 / 4b.13

    /// CASE 4b.12（spec 17a）— `pendingDelete` 遇一次普通更新 ⇒ 丢弃，本机的删除赢。
    func testAnOrdinaryUpdateArrivingOnAPendingDeleteIsDiscarded() {
        let table = pendingDeleteTable("lx:pu-1", decidedAtMs: 1_000)
        // 只改了标题：内容戳 2000，而**位置戳**（pin 是 `rank` 的戳）还停在 100。
        let edited = pinPayload(lineage: "lx", ownerKey: "pu-1", title: "新标题",
                                rankStamp: 100, contentStamp: 2_000)

        let plan = planned([arrival(edited)], table: table)

        let steps = plan.steps
        let superseded = plan.supersededByDelete
        let cancelled = plan.cancelledDeletes
        XCTAssertTrue(steps.isEmpty)
        XCTAssertEqual(superseded, 1)
        XCTAssertTrue(cancelled.isEmpty)
    }

    /// CASE 4b.13（spec 17b / A6）— 被丢弃的那一条**仍然**要收割 `entityId` / `version`。
    ///
    /// 防的是什么：接下来那条 tombstone 会用一个过期的 `baseVersion` 提交并被永久拒绝，
    /// 在真机上表现为一个每 60 s 重来一次、删除永远落不了地的循环。这条用例只有在 `plan`
    /// 收 `OwnedItemArrival`（带协议层三元组）而不是裸载荷时才可能成立——载荷里根本没有
    /// 这两个字段。
    func testTheDiscardedArrivalStillHarvestsItsServerTriple() {
        let table = pendingDeleteTable("lx:pu-1", decidedAtMs: 1_000)
        let edited = pinPayload(lineage: "lx", ownerKey: "pu-1", title: "新标题",
                                rankStamp: 100, contentStamp: 2_000)

        let plan = planned([arrival(edited, entityId: "e-server", version: 77)], table: table)

        let harvested = plan.harvest["lx:pu-1"]
        let entityId = harvested?.entityId
        let version = harvested?.version
        let superseded = plan.supersededByDelete
        XCTAssertEqual(entityId, "e-server")
        XCTAssertEqual(version, 77)
        XCTAssertEqual(superseded, 1)
    }

    // MARK: - CASE 4b.14 / 4b.15

    /// CASE 4b.14（spec 17c / A9）— 入站实体的**位置**比删除决定更新 ⇒ 取消删除。
    ///
    /// 触发者是**远端实体**，不是本机的又一次编辑：按「本机行在决定之后又被改过」实现的
    /// 版本会在本地无关改动上取消删除，同时把真正的 A9 情形丢掉（§5.6 警告的正是这种
    /// 错配）。
    ///
    /// 这条同时是 `PinKind.locationStamp(of:)` 的探测器：它返回 0 的实现会让第一个合取项
    /// **恒假**，于是 pin 侧的取消删除永远不触发，这条用例必红。
    func testARemotePositionNewerThanTheDeleteDecisionCancelsTheDelete() {
        let table = pendingDeleteTable("lx:pu-1", decidedAtMs: 1_000)
        let moved = pinPayload(lineage: "lx", ownerKey: "pu-1", rank: "b", rankStamp: 2_000)

        let plan = planned([arrival(moved)], table: table)

        let identities = plan.steps.map(\.identity)
        let cancelled = plan.cancelledDeletes
        let superseded = plan.supersededByDelete
        XCTAssertEqual(identities, ["lx:pu-1"])
        XCTAssertTrue(cancelled.contains("lx:pu-1"))
        XCTAssertEqual(superseded, 0)
    }

    /// CASE 4b.15（spec 17d）— 同样一次更新的两个否定支：该项进了被删子树、或它的归属
    /// 解析不出来 ⇒ **仍然**丢弃，绝不取消删除。
    func testAMoveIntoTheDeletedSubtreeOrAnUnresolvableOwnerStillLosesToTheDelete() {
        // ① 这条身份本身就在本轮被删的那一片里。
        let doomedTable = pendingDeleteTable("lx:pu-1", decidedAtMs: 1_000)
        var doomedContext = OwnedItemPlanContext()
        doomedContext.deletedSubtree = ["lx:pu-1"]
        let moved = pinPayload(lineage: "lx", ownerKey: "pu-1", rank: "b", rankStamp: 2_000)

        let doomed = planned([arrival(moved)], table: doomedTable, context: doomedContext)

        let doomedSteps = doomed.steps
        let doomedCancelled = doomed.cancelledDeletes
        let doomedSuperseded = doomed.supersededByDelete
        XCTAssertTrue(doomedSteps.isEmpty)
        XCTAssertTrue(doomedCancelled.isEmpty)
        XCTAssertEqual(doomedSuperseded, 1)

        // ② 归属解析不出来：这条实体连落地资格都没有，先被停放（**不是**取消删除，也
        //    不是丢弃——归属落地之后它还要重来一次）。
        let orphanTable = pendingDeleteTable("lx:pu-nowhere", decidedAtMs: 1_000)
        let orphan = pinPayload(lineage: "lx", ownerKey: "pu-nowhere", rank: "b",
                                rankStamp: 2_000)

        let unresolved = planned([arrival(orphan)], table: orphanTable)

        let orphanSteps = unresolved.steps
        let orphanCancelled = unresolved.cancelledDeletes
        let orphanParked = Set(unresolved.parked.keys)
        XCTAssertTrue(orphanSteps.isEmpty)
        XCTAssertTrue(orphanCancelled.isEmpty)
        XCTAssertEqual(orphanParked, ["lx:pu-nowhere"])
    }

    // MARK: - 拒收（§4.6 的 pin 半边）

    /// §4.6 的 pin 拒收表，每一行都测；owner 与作用域不符**不在**表里（§7.3 停放，由
    /// CASE 4b.10 覆盖）。
    ///
    /// 防的是什么：非法 `rank` 是 `rankBetween` 的解码边界（发布构建里 `precondition` 直接
    /// trap）；未归一的大写 lineage 若被接受，同一条 pin 在账户上会有两个身份；带 `:` 的
    /// lineage 让 `lineage + ":" + ownerKey` 这个拼接不再可逆（`("a:b", "c")` 与
    /// `("a", "b:c")` 算出同一个身份），于是一条伪造载荷可以顶着另一条实体的身份去收割
    /// `entityId` / `version`；解析不出 `URL` 的那一条落地段既 create 不了也 update 不了
    /// （`PhiLocalPin.url` 是非可选的 `URL`），不在这里拒收就只剩「静默丢弃」或「永久停放」
    /// 两条坏路（4b-1）。
    func testThePinRefusalTableIsTheStructuralCriteria() {
        // 两个独立的探针，因为 `URL(string:)` 比它看上去宽松得多：这个工具链上
        // `"not a url"`（带空格）、`"https://e.example/\u{0}"`、裸控制字符都**能**解析出
        // 一个 URL。真正被拒的是「权威部分本身非法」这一类：未闭合的 IPv6 字面量，以及
        // 空串。两条都断言，于是任何一条被将来的解析器放宽时这条用例仍然有牙。
        let unparseable = "http://[::1"
        XCTAssertNil(URL(string: unparseable), "fixture 前提：未闭合的 IPv6 字面量解析不出 URL")
        XCTAssertNil(URL(string: ""), "fixture 前提：空串解析不出 URL")

        let empty = PinKind.refuses(pinPayload(lineage: ""), baseline: nil)
        let uppercase = PinKind.refuses(pinPayload(lineage: "LX"), baseline: nil)
        let colon = PinKind.refuses(pinPayload(lineage: "lx:pu-1"), baseline: nil)
        let illegalRank = PinKind.refuses(pinPayload(lineage: "lx", rank: "V0"), baseline: nil)
        let emptyRank = PinKind.refuses(pinPayload(lineage: "lx", rank: ""), baseline: nil)
        let badURL = PinKind.refuses(pinPayload(lineage: "lx", url: unparseable), baseline: nil)
        let emptyURL = PinKind.refuses(pinPayload(lineage: "lx", url: ""), baseline: nil)
        let legal = PinKind.refuses(pinPayload(lineage: "lx", rank: "V"), baseline: nil)
        XCTAssertEqual(empty, .invalidUuid)
        XCTAssertEqual(uppercase, .invalidUuid)
        XCTAssertEqual(colon, .invalidUuid)
        XCTAssertEqual(illegalRank, .illegalRank)
        XCTAssertEqual(emptyRank, .illegalRank)
        XCTAssertEqual(badURL, .invalidURL)
        XCTAssertEqual(emptyURL, .invalidURL)
        XCTAssertNil(legal)
    }

    /// 4b-6（§4.2 第 5 条 / A13）— 无基线那一行的三类戳：`rank` 盖 0、内容字段
    /// （`title` / `url`）盖行自己的内容戳、**其余每个字段盖 `now`**。
    ///
    /// 防的是什么：把 `rank` 记成 `now` 会让一条被当作 create 重新发布的 pin 改写掉账户里
    /// 的次序；把 `title` / `url` 记成 `now` 会让一条几年前建的、从没人动过的 pin 赢下对端
    /// 上周做的改名。而 `split_partner_uuid` 记成内容戳则反过来：拆分链接不是「编辑内容」
    /// 的产物，`contentUpdatedDate` 不为它而动，拿一个可能几年前的戳去发一条刚建立的链接，
    /// 会让对端一条更早但戳更新的空值赢下它。
    func testANoBaselineRowStampsRankZeroContentFromTheRowAndEverythingElseNow() {
        let row = pinRow(guid: "p1", spaceId: "space-a", splitPartnerLineageId: "LB",
                         contentUpdatedDate: Date(timeIntervalSince1970: 2))

        let result = snapshot([row], scope: .space, now: 5_000)

        let entity = result.entities["lx:su-1"]
        let rankStamp = entity?.rank.updatedAtMs
        let titleStamp = entity?.title.updatedAtMs
        let urlStamp = entity?.url.updatedAtMs
        let partnerStamp = entity?.splitPartnerUuid.updatedAtMs
        let partner = entity?.splitPartnerUuid.stringValue
        XCTAssertEqual(rankStamp, 0)
        XCTAssertEqual(titleStamp, 2_000)
        XCTAssertEqual(urlStamp, 2_000)
        XCTAssertEqual(partnerStamp, 5_000)
        XCTAssertEqual(partner, "lb", "伙伴 lineage 出门前也要过 lineageKey")
    }
}

// MARK: - Task 5a：落地 index 投影（§4.10）

/// `BookmarkKind.rankToIndex(siblings:ranks:)` 的三条用例。模块级、纯函数：没有
/// `LocalStore`、没有引擎、没有假件——投影本身是落地路径上唯一一处「线上次序 → 本机
/// 稠密 index」的翻译，它错了整个文件夹的顺序就错了，所以它单独有用例。
@MainActor
final class BookmarkRankToIndexProjectionTests: XCTestCase {

    /// 只写这条用例在乎的四个字段；其余走 fixture 的默认值。
    private func sibling(guid: String,
                         syncId: String?,
                         index: Int) -> PhiLocalBookmark {
        PhiLocalBookmark.fixture(guid: guid, syncId: syncId, index: index)
    }

    // MARK: - CASE 5a.1

    /// CASE 5a.1 — rank → 稠密 index 的投影按 **rank 序**编号，不是按旧 `index` 序。
    ///
    /// 防的是什么：沿用旧 `index` 排序的实现在「本机顺序恰好等于 rank 顺序」的数据上
    /// 也是绿的，只有在两者不一致时才露馅。这里刻意让旧 `index`（7 / 2 / 5）与 rank
    /// 序（M < V < b）给出**三个都不同**的名次，于是任何一种按旧 index 编号的写法都
    /// 得不到期望值。
    func testTheProjectionNumbersSiblingsByRankOrderNotByTheirOldIndex() {
        let siblings = [
            sibling(guid: "g1", syncId: "b1", index: 7),
            sibling(guid: "g2", syncId: "b2", index: 2),
            sibling(guid: "g3", syncId: "b3", index: 5),
        ]

        let projected = BookmarkKind.rankToIndex(siblings: siblings,
                                                 ranks: ["b1": "V", "b2": "M", "b3": "b"])

        XCTAssertEqual(projected, ["g2": 0, "g1": 1, "g3": 2])
    }

    // MARK: - CASE 5a.2

    /// CASE 5a.2 — rank 平手时按**身份 uuid** 定序。
    ///
    /// 防的是什么：不定序会让两台机器把同一批行写成不同的 index 顺序，各自再发回一轮
    /// 无谓的 rank 更新，两边永远互相盖。
    ///
    /// 两条行的**本机 guid 次序与身份次序刻意相反**（`b-aaa` 住在 `g-zzz` 上）：按 guid
    /// 平手的写法会把 `b-bbb` 排前，于是这条用例对「平手判据用错了字段」是有牙的，而
    /// 不是两种写法都绿。
    func testSiblingsWithTheSameRankAreOrderedByIdentityUuid() {
        let siblings = [
            sibling(guid: "g-aaa", syncId: "b-bbb", index: 0),
            sibling(guid: "g-zzz", syncId: "b-aaa", index: 1),
        ]

        let projected = BookmarkKind.rankToIndex(siblings: siblings,
                                                 ranks: ["b-aaa": "M", "b-bbb": "M"])

        XCTAssertEqual(projected["g-zzz"], 0, "b-aaa 排前")
        XCTAssertEqual(projected["g-aaa"], 1)
    }

    // MARK: - CASE 5a.3

    /// CASE 5a.3 — 投影喂的是**未过滤**的兄弟列表：本轮不参与同步的那条也拿到一个
    /// index，三个 index 互不相同。
    ///
    /// 防的是什么：只重排参与本轮的那几条，被排除的兄弟留着的旧 `index` 会与新写的
    /// 撞上，同一个文件夹里出现两条 index 相同的行，此后顺序随 fetch 而变；下一轮的
    /// 出站 pass 于是给其中一条算出新 rank 发出去，对端应用后顺序又翻回来——每轮两条
    /// commit，永远（§4.10）。
    func testTheProjectionCoversEverySiblingIncludingTheOnesNotInThisRound() {
        let siblings = [
            sibling(guid: "g1", syncId: "b1", index: 0),
            // 还没发布过的本机行：本轮没有 rank，但它占着这个父下的一个槽位。
            sibling(guid: "g2", syncId: nil, index: 1),
            sibling(guid: "g3", syncId: "b3", index: 2),
        ]

        let projected = BookmarkKind.rankToIndex(siblings: siblings,
                                                 ranks: ["b1": "V", "b3": "b"])

        let indexes = Set(projected.values)
        XCTAssertEqual(projected.count, 3, "未过滤：三条兄弟都要拿到 index")
        XCTAssertEqual(indexes.count, 3, "三个 index 互不相同")
        XCTAssertEqual(projected["g2"], 0, "没有 rank 的行排在最前，与 assignRanks 的补集规则同向")
    }
}

// MARK: - Task 5a fix round：读失败与差分定义域

/// `PhiBookmarkLocalAccess` 两条读契约的用例（R-exec-3 / R-exec-4）。走假件，因为要断言的
/// 是**协议的形状**——读失败能不能被调用方看见、差分的定义域是不是比快照宽——而不是
/// SwiftData 的行为。
@MainActor
final class BookmarkLocalAccessReadContractTests: XCTestCase {

    private struct StoreDown: Error {}

    // MARK: - R-exec-3

    /// 读失败必须抛，**绝不**变成一个空数组。
    ///
    /// 防的是什么：一次读不出来与「这个账户一条书签都没有」在值上是同一个 `[]`。§4.7 的
    /// 差分对空集合的回答是给每一条游标发 tombstone，所以把失败读成空集合会删掉账户上整棵
    /// 树，而且每台设备同步之后都跟着删。进程刚起来那一轮最危险：本机还没有任何快照可回落，
    /// 游标表却已经从磁盘上读满了。
    func testAFailingStoreMakesTheSnapshotThrowRatherThanReportNoBookmarks() async {
        let access = FakeBookmarkAccess(rows: [
            PhiLocalBookmark.fixture(guid: "g1", syncId: "b1"),
            PhiLocalBookmark.fixture(guid: "g2", syncId: "b2"),
        ])
        access.readError = StoreDown()

        var thrown: Error?
        var returned: [PhiLocalBookmark]?
        do {
            returned = try access.allBookmarks()
        } catch {
            thrown = error
        }

        XCTAssertNil(returned, "读失败不许交出任何一份行列表，空数组也不行")
        XCTAssertTrue(thrown is StoreDown, "原样上抛，调用方才分得清这是读失败")
    }

    /// 差分定义域那一个读口同样要抛：它才是 §4.7 判「本机还有没有这一行」的那一份数据。
    func testAFailingStoreMakesTheIdentityReadThrowToo() async {
        let access = FakeBookmarkAccess(rows: [PhiLocalBookmark.fixture(guid: "g1", syncId: "b1")])
        access.readError = StoreDown()

        var thrown: Error?
        var returned: Set<String>?
        do {
            returned = try access.allSyncIds()
        } catch {
            thrown = error
        }

        XCTAssertNil(returned)
        XCTAssertTrue(thrown is StoreDown)
    }

    // MARK: - R-exec-4

    /// 孤儿根下面那条行**不在快照里**（它不发布），但**在身份集合里**（它没有被删）。
    ///
    /// 防的是什么：快照回答的是「同步层认领哪些行」，差分要问的是「这条身份在本机还有没有
    /// 行」。拿快照当差分的定义域，一条曾经发布过、后来它那个根不再是 Space 的 canonical
    /// root 的行（并发初始化正好造出这种状态）会连同整棵子树被判成删除，账户上那一片就没
    /// 了——而本机其实一行都没少。
    func testAnOrphanRootRowIsOutOfTheSnapshotButStillCountsAsPresentForTheDiff() throws {
        let access = FakeBookmarkAccess(rows: [
            PhiLocalBookmark.fixture(guid: "g1", syncId: "b1"),
        ])
        // 本机有这一行，但它挂在一个已经不是 canonical root 的根下面。
        access.orphanedSyncIds = ["b-orphan"]

        let snapshotIdentities = Set(try access.allBookmarks().compactMap(\.syncId))
        let diffDomain = try access.allSyncIds()

        XCTAssertEqual(snapshotIdentities, ["b1"], "孤儿根那棵不进快照，它不发布")
        XCTAssertEqual(diffDomain, ["b1", "b-orphan"], "但它绝不能被差分判成「本机没有了」")
        XCTAssertTrue(diffDomain.isSuperset(of: snapshotIdentities),
                      "差分定义域只会比快照宽，不会窄")
    }
}

// MARK: - Task 5a fix round 2：快照的生命周期

/// 三个读缓存的读者什么时候有意义（G1 / G4）。契约是：本轮**最后一次成功的**
/// `allBookmarks()` 或 `apply(_:)` 之后。
@MainActor
final class BookmarkSnapshotLifetimeTests: XCTestCase {

    private func access() -> FakeBookmarkAccess {
        FakeBookmarkAccess(rows: [
            PhiLocalBookmark.fixture(guid: "g-folder", syncId: "b-folder",
                                     index: 0, isFolder: true),
            PhiLocalBookmark.fixture(guid: "g1", syncId: "b1", parentGuid: "g-folder", index: 0),
        ])
    }

    /// 本轮还没读过 ⇒ 三个读者交出「不在」，`allSyncIds()` 抛。
    ///
    /// 防的是什么：这三个值全都是**错的**，只是非抛出的签名里没有别的东西可交。生产实现在
    /// DEBUG 下会在这里 `assertionFailure`，假件跟着模同一条契约，免得 Task 6 的引擎用例在
    /// 假件上跑过一种真机上根本不成立的用法。
    func testTheCacheBackedReadersReportAbsentBeforeAnySuccessfulSnapshot() {
        let access = access()

        let siblings = access.siblings(ofParent: "g-folder", inSpaceId: LocalStore.defaultSpaceId)
        let known = access.isKnownLocalBookmark("g1")
        let isFolder = access.localIsFolder(guid: "g-folder")
        var identitiesThrew = false
        do { _ = try access.allSyncIds() } catch { identitiesThrew = true }

        XCTAssertTrue(siblings.isEmpty)
        XCTAssertFalse(known)
        XCTAssertNil(isFolder)
        XCTAssertTrue(identitiesThrew, "空集合会让差分把整棵树判成删除，所以这里只能抛")
    }

    /// 一次成功的 `allBookmarks()` 之后三个读者才答得上话。
    func testASuccessfulSnapshotMakesTheReadersAnswer() throws {
        let access = access()

        _ = try access.allBookmarks()

        let siblings = access.siblings(ofParent: "g-folder", inSpaceId: LocalStore.defaultSpaceId)
        let known = access.isKnownLocalBookmark("g1")
        let isFolder = access.localIsFolder(guid: "g-folder")
        XCTAssertEqual(siblings.map(\.guid), ["g1"])
        XCTAssertTrue(known)
        XCTAssertEqual(isFolder, true)
    }

    /// 一次成功的 `apply(_:)` 之后，三个读者仍然答得上话，而且答的是**落地之后**的形状。
    ///
    /// 防的是什么：§4.5 要求「落地之后、写基线之前，按计划复核一次」，而复核用的正是这三个
    /// 读者。落地后把快照清空了事的话，它们对每一个 guid 都答「不在」——复核永远不通过、
    /// 基线永远不写、同一批每轮重放；而 `isKnownLocalBookmark` 全答 false 更会让引擎把每条
    /// 身份判成死映射，把整棵树当成新行重建一遍，用户看见的是一棵重复的树。
    func testTheReadersStillAnswerRightAfterASuccessfulApply() async throws {
        let access = access()
        _ = try access.allBookmarks()

        try await access.apply(BookmarkApplyBatch(unordered: [
            .create(PhiLocalBookmark.fixture(guid: "g2", syncId: "b2",
                                             parentGuid: "g-folder", index: 1)),
        ]))

        let siblings = access.siblings(ofParent: "g-folder", inSpaceId: LocalStore.defaultSpaceId)
        let known = access.isKnownLocalBookmark("g2")
        let identities = try access.allSyncIds()
        XCTAssertEqual(siblings.map(\.guid), ["g1", "g2"], "复核读到的是落地之后的形状")
        XCTAssertTrue(known, "落地的那条行必须认得出来，否则它会被当成死映射重建")
        XCTAssertTrue(identities.contains("b2"))
    }

    /// 新一轮开始、还没读之前，读者回到「不在」。
    func testBeginningANewRoundInvalidatesTheReaders() throws {
        let access = access()
        _ = try access.allBookmarks()

        access.beginRound()

        let known = access.isKnownLocalBookmark("g1")
        XCTAssertFalse(known)
    }
}

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

import Foundation
import XCTest
@testable import Phi

/// `URLRuleKind` 的模块级用例（spec §12.1「URL Rule」块里归 Task 7 的那些）：**没有
/// SwiftData、没有引擎、没有持久化**，全部输入都是值类型，全部输出都是返回值。
///
/// 类标 `@MainActor` 与 `SyncableOwnedItemsTests.swift:11-12` 同款理由：同一文件族里要构造
/// `@MainActor` 假件；模块本身不需要任何 actor。
@MainActor
final class URLRuleKindTests: XCTestCase {

    private let resolve = OwnerResolver.fixture()

    // MARK: - 小工具

    private func arrival(_ payload: Phi_PhiURLRuleEntity,
                         entityId: String = "srv-1",
                         version: Int64 = 1) -> OwnedItemArrival<Phi_PhiURLRuleEntity> {
        OwnedItemArrival(entity: payload, entityId: entityId, version: version)
    }

    private func planned(_ arrivals: [OwnedItemArrival<Phi_PhiURLRuleEntity>],
                         parked: [String: ParkedOwnedItem] = [:],
                         table: PhiOwnedItemTable = PhiOwnedItemTable(),
                         resolve: OwnerResolver? = nil,
                         context: OwnedItemPlanContext = OwnedItemPlanContext()) -> OwnedItemPlan {
        SyncableOwnedItems.plan(URLRuleKind.self, arrivals: arrivals, parked: parked,
                                table: table, resolve: resolve ?? self.resolve, context: context)
    }

    private func decoded(_ step: OwnedItemApplyStep?) -> Phi_PhiURLRuleEntity? {
        guard let payload = step?.payload,
              let envelope = try? Phi_PhiEntity(serializedBytes: payload) else { return nil }
        return URLRuleKind.entity(from: envelope)
    }

    private func normalized(_ arrivals: [OwnedItemArrival<Phi_PhiURLRuleEntity>])
        -> (arrivals: [OwnedItemArrival<Phi_PhiURLRuleEntity>], normalized: Set<String>) {
        URLRuleKind.normalizeArrivals(arrivals, normalize: LocalStore.normalizedRule(host:pathPrefix:))
    }

    // MARK: - CASE U-1（停放，不改写）

    func testUnresolvableTargetParksTheEntityWithoutRewritingIt() {
        let payload = urlRulePayload(uuid: "r1", targetSpaceUuid: "S-unknown")
        let plan = planned([arrival(payload, entityId: "srv-1", version: 3)])

        XCTAssertTrue(plan.steps.isEmpty)
        XCTAssertEqual(Array(plan.parked.keys), ["r1"])
        XCTAssertEqual(plan.parked["r1"]?.pendingOwnerUuid, "S-unknown")
        XCTAssertEqual(plan.harvest["r1"]?.entityId, "srv-1")
        XCTAssertEqual(plan.harvest["r1"]?.version, 3)
        XCTAssertEqual(plan.refused, 0)
        // 停放的载荷逐字节就是入站那一条：从未被写成任何别的目标（D16）。
        XCTAssertEqual(plan.parked["r1"]?.payload, baselineBytes(payload))
    }

    /// 计划裁定：空目标返回 `[""]` 而不是 `[]`，于是 `classify("")` 判 `.unresolved` 并停放；
    /// 返回 `[]` 会让一条 `target_space_uuid` 为空的实体带着空目标写进本机行。
    func testEmptyTargetIsParkedNotLanded() {
        let payload = urlRulePayload(uuid: "r1e", targetSpaceUuid: "")
        XCTAssertEqual(URLRuleKind.ownerUuids(of: payload), [""])
        let plan = planned([arrival(payload)])
        XCTAssertTrue(plan.steps.isEmpty)
        XCTAssertEqual(plan.parked["r1e"]?.pendingOwnerUuid, "")
        XCTAssertEqual(plan.refused, 0)
    }

    // MARK: - CASE U-2（保留常量不停放）

    func testReservedIncognitoTargetLandsInsteadOfParking() {
        let payload = urlRulePayload(uuid: "r2", targetSpaceUuid: SyncableSpaces.incognitoSpaceUuid)
        let plan = planned([arrival(payload)], resolve: OwnedOwnerMaps().resolver)

        XCTAssertTrue(plan.parked.isEmpty)
        XCTAssertEqual(plan.steps.count, 1)
        XCTAssertEqual(plan.steps.first?.kind, .create)
        XCTAssertEqual(plan.steps.first?.identity, "r2")
        XCTAssertEqual(URLRuleKind.ownerUuids(of: payload), ["incognito-space"])
        XCTAssertNotEqual(URLRuleKind.ownerUuids(of: payload), [])
        XCTAssertEqual(URLRuleKind.targetOwnerUuid(of: payload), "incognito-space")
    }

    // MARK: - CASE U-3（内容组是一个单元）

    func testContentGroupMergesAsOneUnit() {
        var x = urlRulePayload(uuid: "r3", host: "a.com", pathPrefix: "/x", ask: false,
                               contentStamp: 100, targetStamp: 100, rankStamp: 100)
        // X 的 `ask` 单独带一枚更新的戳：逐字段 LWW 会取 X 的 `ask == false` 配 Y 的
        // `path == "/y"`，合出一条谁都没写过的规则；整组判定只读载体 `host`（100 < 200）。
        x.ask.updatedAtMs = 900
        let y = urlRulePayload(uuid: "r3", host: "a.com", pathPrefix: "/y", ask: true,
                               contentStamp: 200, targetStamp: 100, rankStamp: 100)

        let xy = URLRuleKind.merge(local: x, remote: y)
        let yx = URLRuleKind.merge(local: y, remote: x)
        XCTAssertEqual(xy, yx)
        XCTAssertEqual(xy.host.stringValue, "a.com")
        XCTAssertEqual(xy.pathPrefix.stringValue, "/y")
        XCTAssertTrue(xy.ask.boolValue)
        XCTAssertEqual(xy.host.updatedAtMs, 200)
        XCTAssertEqual(xy.pathPrefix.updatedAtMs, 200)
        XCTAssertEqual(xy.ask.updatedAtMs, 200)
        XCTAssertEqual(xy.targetSpaceUuid, x.targetSpaceUuid)
        XCTAssertEqual(xy.rank, x.rank)
    }

    // MARK: - CASE U-4（内容组戳的载体恒取 `host`）

    func testContentStampCarrierIsHostAndIndependentOfTheTargetStamp() {
        var uneven = urlRulePayload(uuid: "r4", host: "uneven.com", pathPrefix: "/u", ask: true,
                                    contentStamp: 100)
        uneven.pathPrefix.updatedAtMs = 900
        uneven.ask.updatedAtMs = 500
        let flat = urlRulePayload(uuid: "r4", host: "flat.com", pathPrefix: "/f", ask: false,
                                  contentStamp: 300)

        let a = URLRuleKind.merge(local: uneven, remote: flat)
        let b = URLRuleKind.merge(local: flat, remote: uneven)
        XCTAssertEqual(a, b)
        // 按 `host` 的 100 判 ⇒ 对手（300）赢下整组；取 `max` 的实现会算出 900 并赢下这次合并。
        XCTAssertEqual(a.host.stringValue, "flat.com")
        XCTAssertEqual(a.pathPrefix.stringValue, "/f")
        XCTAssertFalse(a.ask.boolValue)
        XCTAssertEqual(a.host.updatedAtMs, 300)
        XCTAssertEqual(a.pathPrefix.updatedAtMs, 300)
        XCTAssertEqual(a.ask.updatedAtMs, 300)

        // 变体：目标戳比三者都大，内容组的判定与它完全无关（R-M3-4a-40 的通道隔离）。
        var variant = uneven
        variant.targetSpaceUuid.updatedAtMs = 9_000
        let c = URLRuleKind.merge(local: variant, remote: flat)
        let d = URLRuleKind.merge(local: flat, remote: variant)
        XCTAssertEqual(c, d)
        XCTAssertEqual(c.host, a.host)
        XCTAssertEqual(c.pathPrefix, a.pathPrefix)
        XCTAssertEqual(c.ask, a.ask)
        XCTAssertEqual(URLRuleKind.contentSignature(of: c), URLRuleKind.contentSignature(of: a))
        XCTAssertEqual(c.targetSpaceUuid.updatedAtMs, 9_000, "目标通道照自己的戳走")
    }

    // MARK: - CASE U-5（相干规则跟着目标走）

    func testRankFollowsTheWinningTargetEvenWhenTheOtherRankStampIsNewer() {
        let a = urlRulePayload(uuid: "r5", targetSpaceUuid: "su-2", rank: "M",
                               targetStamp: 200, rankStamp: 200)
        let b = urlRulePayload(uuid: "r5", targetSpaceUuid: "su-1", rank: "V",
                               targetStamp: 100, rankStamp: 300)

        let ab = URLRuleKind.merge(local: a, remote: b)
        let ba = URLRuleKind.merge(local: b, remote: a)
        XCTAssertEqual(ab, ba)
        XCTAssertEqual(ab.targetSpaceUuid.stringValue, "su-2")
        XCTAssertEqual(ab.targetSpaceUuid.updatedAtMs, 200)
        XCTAssertEqual(ab.rank.stringValue, "M", "跟着赢下目标的那一条，哪怕对面 rank 戳更新")
        XCTAssertEqual(ab.rank.updatedAtMs, 200)

        // 三方汇合：(A,B) 与 (B,A) 两种顺序再并 C。
        let c = urlRulePayload(uuid: "r5", targetSpaceUuid: "su-1", rank: "Q",
                               targetStamp: 150, rankStamp: 400)
        let abc = URLRuleKind.merge(local: ab, remote: c)
        let bac = URLRuleKind.merge(local: ba, remote: c)
        XCTAssertEqual(abc, bac)
        XCTAssertEqual(abc.targetSpaceUuid.stringValue, "su-2")
        XCTAssertEqual(abc.rank.stringValue, "M")
    }

    // MARK: - CASE U-5b（内容与目标各自存活）

    func testAContentEditAndATargetEditBothSurviveTheMerge() {
        // A 只改 host（内容组 100，目标与 rank 停在 50）。
        let a = urlRulePayload(uuid: "r5b", targetSpaceUuid: "su-1", host: "new.com", rank: "V",
                               contentStamp: 100, targetStamp: 50, rankStamp: 50)
        // B 只改目标（目标 200、rank 200，内容组停在 50 且是旧值）。
        let b = urlRulePayload(uuid: "r5b", targetSpaceUuid: "su-2", host: "old.com", rank: "M",
                               contentStamp: 50, targetStamp: 200, rankStamp: 200)

        let ab = URLRuleKind.merge(local: a, remote: b)
        let ba = URLRuleKind.merge(local: b, remote: a)
        XCTAssertEqual(ab, ba)
        XCTAssertEqual(ab.host.stringValue, "new.com", "A 的 host 在")
        XCTAssertEqual(ab.host.updatedAtMs, 100)
        XCTAssertEqual(ab.targetSpaceUuid.stringValue, "su-2", "B 的目标在")
        XCTAssertEqual(ab.targetSpaceUuid.updatedAtMs, 200)
        XCTAssertEqual(ab.rank.stringValue, "M", "目标不一致 ⇒ rank 跟目标走")
    }

    // MARK: - CASE U-6（归一化是不动点，kind 这一侧的半边）

    func testNormalizeArrivalsIsAFixedPointOfTheSharedNormalizer() {
        let hosts = ["GitHub.COM", "github.com.", "github.com..", "github.com .", "github.com ..",
                     "github.com . .", "a. .", "a. . .", " github.com. ", " *.Figma.com "]
        let paths = ["/foo/", "/", "/foo%2F", "/%2F", "%2F", "/a%252F", "/r%C3%A9sum%C3%A9",
                     "/100%complete"]
        var arrivals: [OwnedItemArrival<Phi_PhiURLRuleEntity>] = []
        for (offset, host) in hosts.enumerated() {
            arrivals.append(arrival(urlRulePayload(uuid: "h\(offset)", host: host)))
        }
        for (offset, path) in paths.enumerated() {
            arrivals.append(arrival(urlRulePayload(uuid: "p\(offset)", pathPrefix: path)))
        }

        let first = normalized(arrivals)
        var expectedNormalized: Set<String> = []
        for (offset, item) in first.arrivals.enumerated() {
            let raw = arrivals[offset].entity
            let wirePath = raw.pathPrefix.stringValue
            // 第一遍产出的每条实体与直接调 `LocalStore.normalizedRule` 的结果逐字相同。
            let direct = LocalStore.normalizedRule(host: raw.host.stringValue,
                                                   pathPrefix: wirePath.isEmpty ? nil : wirePath)
            XCTAssertEqual(item.entity.host.stringValue, direct.host, raw.host.stringValue)
            XCTAssertEqual(item.entity.pathPrefix.stringValue, direct.pathPrefix ?? "", wirePath)
            // 三枚戳一个都不碰。
            XCTAssertEqual(item.entity.host.updatedAtMs, raw.host.updatedAtMs)
            XCTAssertEqual(item.entity.pathPrefix.updatedAtMs, raw.pathPrefix.updatedAtMs)
            XCTAssertEqual(item.entity.ask.updatedAtMs, raw.ask.updatedAtMs)
            XCTAssertEqual(item.entity.targetSpaceUuid.updatedAtMs, raw.targetSpaceUuid.updatedAtMs)
            XCTAssertEqual(item.entity.rank.updatedAtMs, raw.rank.updatedAtMs)
            if direct.host != raw.host.stringValue || (direct.pathPrefix ?? "") != wirePath {
                expectedNormalized.insert(raw.ruleUuid)
            }
        }
        XCTAssertEqual(first.normalized, expectedNormalized)
        XCTAssertTrue(first.normalized.contains("h0"), "\"GitHub.COM\" 变了")
        XCTAssertFalse(first.normalized.contains("p1"), "\"/\" 已经是不动点")

        // 第二遍喂第一遍的输出：空集、逐字节不变。
        let second = normalized(first.arrivals)
        XCTAssertTrue(second.normalized.isEmpty)
        XCTAssertEqual(second.arrivals.map(\.entity), first.arrivals.map(\.entity))
        XCTAssertEqual(second.arrivals.map { baselineBytes($0.entity) },
                       first.arrivals.map { baselineBytes($0.entity) })

        // 三条具体值，经 arrival 这一侧读出来。
        let byUuid = Dictionary(uniqueKeysWithValues: first.arrivals.map { ($0.entity.ruleUuid, $0.entity) })
        XCTAssertEqual(byUuid["p3"]?.pathPrefix.stringValue, "/", "f(\"/%2F\") == \"/\"，不是 nil、不是 \"//\"")
        XCTAssertEqual(byUuid["p2"]?.pathPrefix.stringValue, "/foo", "f(\"/foo%2F\") == \"/foo\"")
        XCTAssertEqual(byUuid["p5"]?.pathPrefix.stringValue, "/a%252F", "f(\"/a%252F\") 已是不动点")
        XCTAssertEqual(byUuid["h9"]?.host.stringValue, "*.figma.com")
        XCTAssertEqual(byUuid["h6"]?.host.stringValue, "a")

        // 线上 `""` ⇔ 本机 nil 的互转在两个方向都成立：
        // 空白路径归一成 nil ⇒ 线上写回 `""`、计一次；线上 `""` 交给归一函数的是 nil ⇒ 原样、不计。
        let blank = normalized([arrival(urlRulePayload(uuid: "blank", pathPrefix: "   "))])
        XCTAssertEqual(blank.arrivals[0].entity.pathPrefix.stringValue, "")
        XCTAssertEqual(blank.normalized, ["blank"])
        let empty = normalized([arrival(urlRulePayload(uuid: "empty", pathPrefix: ""))])
        XCTAssertEqual(empty.arrivals[0].entity.pathPrefix.stringValue, "")
        XCTAssertTrue(empty.normalized.isEmpty)
        // `"/"` 与 `""` 是两个不同的值：根路径不会被塌成「匹配任意路径」。
        let root = normalized([arrival(urlRulePayload(uuid: "root", pathPrefix: "/"))])
        XCTAssertEqual(root.arrivals[0].entity.pathPrefix.stringValue, "/")
        XCTAssertTrue(root.normalized.isEmpty)
    }

    // MARK: - CASE U-7（未归一的入站被归一而不是被拒）

    func testUnnormalizedInboundIsNormalizedNotRefusedAndKeepsItsStamps() {
        let raw = urlRulePayload(uuid: "r7", host: "GitHub.com", pathPrefix: "/foo/",
                                 contentStamp: 500, targetStamp: 700, rankStamp: 900)
        let old = urlRulePayload(uuid: "r7", host: "github.com", pathPrefix: "/bar",
                                 contentStamp: 100, targetStamp: 100, rankStamp: 100)
        var table = PhiOwnedItemTable()
        table.cursors["r7"] = ownedCursor(reconciled: baselineBytes(old), entityId: "srv-1",
                                          version: 1, ownerUuid: "su-1")

        let first = normalized([arrival(raw, version: 2)])
        XCTAssertEqual(first.normalized, ["r7"])
        let entity = first.arrivals[0].entity
        XCTAssertEqual(entity.host.stringValue, "github.com")
        XCTAssertEqual(entity.pathPrefix.stringValue, "/foo")
        XCTAssertEqual(entity.host.updatedAtMs, 500, "不是 now")
        XCTAssertEqual(entity.pathPrefix.updatedAtMs, 500)
        XCTAssertEqual(entity.ask.updatedAtMs, 500)
        XCTAssertEqual(entity.targetSpaceUuid.updatedAtMs, 700)
        XCTAssertEqual(entity.rank.updatedAtMs, 900)

        let plan = planned(first.arrivals, table: table)
        XCTAssertEqual(plan.refused, 0)
        XCTAssertEqual(plan.steps.map(\.kind), [.update])
        let landed = decoded(plan.steps.first)
        XCTAssertEqual(landed?.host.stringValue, "github.com")
        XCTAssertEqual(landed?.pathPrefix.stringValue, "/foo")
        XCTAssertEqual(landed?.host.updatedAtMs, 500)
        XCTAssertEqual(landed?.targetSpaceUuid.updatedAtMs, 700)
        XCTAssertEqual(landed?.rank.updatedAtMs, 900)
        // 调用方把 `normalized` 并进 `mustRepublish`（模块自己的判据对纯归一恒假）。
        XCTAssertTrue(plan.mustRepublish.union(first.normalized).contains("r7"))

        // 第二轮：基线已经是归一后的字节 ⇒ `normalized` 为空、零 step、连基线都不用动。
        table.cursors["r7"]?.reconciled = plan.steps.first?.payload
        let second = normalized(first.arrivals)
        XCTAssertTrue(second.normalized.isEmpty)
        let again = planned(second.arrivals, table: table)
        XCTAssertTrue(again.steps.isEmpty)
        XCTAssertTrue(again.rebaselined.isEmpty)
        XCTAssertEqual(again.refused, 0)
    }

    // MARK: - CASE U-8（结构性拒收三条 + IPv6 不被误拒）

    func testStructuralHostRefusalsAcceptBracketedIPv6Literals() {
        let cases: [(host: String, expected: OwnedItemRefusal?)] = [
            ("", .emptyHost),
            ("*.", .degenerateHost),
            ("a/b", .malformedHost),
            ("a:b", .malformedHost),
            ("[::1]:8080", .malformedHost),
            ("[::1]", nil),
            ("[2001:db8::1]", nil),
        ]
        for item in cases {
            XCTAssertEqual(URLRuleKind.refuses(urlRulePayload(uuid: "r8", host: item.host), baseline: nil),
                           item.expected, "host \(item.host)")
        }
        XCTAssertEqual(URLRuleKind.refuses(urlRulePayload(uuid: "r8", host: "*"), baseline: nil),
                       .degenerateHost)

        let arrivals = cases.enumerated().map { offset, item in
            arrival(urlRulePayload(uuid: "r8-\(offset)", host: item.host), entityId: "srv-\(offset)")
        }
        let plan = planned(arrivals)
        XCTAssertEqual(plan.refused, 5)
        XCTAssertTrue(plan.parked.isEmpty)
        XCTAssertEqual(plan.steps.count, 2)
        XCTAssertEqual(Set(plan.steps.map(\.identity)), ["r8-5", "r8-6"])
        XCTAssertTrue(plan.steps.allSatisfy { $0.kind == .create })
    }

    // MARK: - CASE U-9（非法 rank 不到达 `precondition`）

    func testIllegalRanksAreRefusedBeforeReachingRankBetween() {
        RankProbe.reset()
        for rank in ["", "V0", "a-b"] {
            let plan = planned([arrival(urlRulePayload(uuid: "r9", rank: rank))])
            XCTAssertEqual(plan.refused, 1, "rank \(rank)")
            XCTAssertTrue(plan.steps.isEmpty, "rank \(rank)")
            XCTAssertEqual(URLRuleKind.refuses(urlRulePayload(uuid: "r9", rank: rank), baseline: nil),
                           .illegalRank, "rank \(rank)")
        }
        XCTAssertEqual(RankProbe.rankBetweenCalls, 0)
    }

    // MARK: - CASE U-19（无基线首发的戳，三项）

    func testFirstPublicationStampsComeFromTheRowNotFromNow() throws {
        let local = PhiLocalURLRule.fixture(syncId: "r19",
                                            createdDate: Date(timeIntervalSince1970: 1_000),
                                            contentUpdatedDate: nil, targetUpdatedDate: nil)
        let projected = try XCTUnwrap(URLRuleKind.project(local, resolve: resolve, scope: nil,
                                                          parentIdentity: nil))
        XCTAssertEqual(projected.ruleUuid, "r19")
        XCTAssertEqual(projected.targetSpaceUuid.stringValue, "su-1")
        XCTAssertEqual(projected.rank.stringValue, "", "投影不填 rank")

        let stamped = URLRuleKind.stamp(projected, baseline: nil, local: local, rank: "V",
                                        now: 5_000_000)
        XCTAssertEqual(stamped.rank.stringValue, "V")
        XCTAssertEqual(stamped.host.updatedAtMs, 1_000_000, "= createdDate 的毫秒值")
        XCTAssertEqual(stamped.pathPrefix.updatedAtMs, 1_000_000)
        XCTAssertEqual(stamped.ask.updatedAtMs, 1_000_000)
        XCTAssertEqual(stamped.targetSpaceUuid.updatedAtMs, 1_000_000)
        XCTAssertEqual(stamped.rank.updatedAtMs, 0)
        XCTAssertEqual(URLRuleKind.locationStamp(of: stamped), 1_000_000)

        // 变体：用户改过一次目标而从没改过内容 ⇒ 两枚戳不同值。
        let variant = PhiLocalURLRule.fixture(syncId: "r19",
                                              createdDate: Date(timeIntervalSince1970: 1_000),
                                              contentUpdatedDate: nil,
                                              targetUpdatedDate: Date(timeIntervalSince1970: 3_000))
        let stampedVariant = URLRuleKind.stamp(
            try XCTUnwrap(URLRuleKind.project(variant, resolve: resolve, scope: nil, parentIdentity: nil)),
            baseline: nil, local: variant, rank: "V", now: 5_000_000)
        XCTAssertEqual(stampedVariant.host.updatedAtMs, 1_000_000)
        XCTAssertEqual(stampedVariant.targetSpaceUuid.updatedAtMs, 3_000_000)
        XCTAssertEqual(stampedVariant.rank.updatedAtMs, 0)
    }

    // MARK: - CASE U-23（A9：只有改目标能取消本机删除）

    func testOnlyATargetChangeCancelsALocalDeletion() {
        let baseline = urlRulePayload(uuid: "r23", targetSpaceUuid: "su-1", host: "old.com",
                                      contentStamp: 50, targetStamp: 50, rankStamp: 50)
        var table = PhiOwnedItemTable()
        table.cursors["r23"] = pendingDeleteCursor(decidedAtMs: 100, reconciled: baselineBytes(baseline))

        // (a) 只改了 host：内容组戳 200 比删除决定新，但目标戳没动 ⇒ 本机的删除赢。
        let contentOnly = urlRulePayload(uuid: "r23", targetSpaceUuid: "su-1", host: "new.com",
                                         contentStamp: 200, targetStamp: 50, rankStamp: 50)
        let a = planned([arrival(contentOnly)], table: table)
        XCTAssertEqual(a.supersededByDelete, 1)
        XCTAssertTrue(a.cancelledDeletes.isEmpty)
        XCTAssertTrue(a.steps.isEmpty)

        // (b) 改了目标：目标戳 200 > 100 ⇒ 取消删除，产出 `.move`。
        let retargeted = urlRulePayload(uuid: "r23", targetSpaceUuid: "su-2", host: "old.com",
                                        contentStamp: 50, targetStamp: 200, rankStamp: 200)
        let b = planned([arrival(retargeted)], table: table)
        XCTAssertEqual(b.cancelledDeletes, ["r23"])
        XCTAssertEqual(b.supersededByDelete, 0)
        XCTAssertEqual(b.steps.map(\.kind), [.move])
        XCTAssertEqual(b.steps.first?.newOwnerUuid, "su-2")
        XCTAssertNil(b.steps.first?.newParentUuid)
    }

    // MARK: - CASE U-25（`created_at_ms` / `source` 的基线折叠）

    func testCreatedAtAndSourceFoldAgainstTheBaselineSoTheProjectionMatchesBytes() throws {
        let baseline = urlRulePayload(uuid: "r25", targetSpaceUuid: "su-1", host: "github.com",
                                      pathPrefix: "", ask: false, rank: "V",
                                      contentStamp: 100, targetStamp: 100, rankStamp: 100,
                                      source: 1, createdAtMs: 1_000)
        let local = PhiLocalURLRule.fixture(syncId: "r25", spaceId: "space-a", host: "github.com",
                                            createdDate: Date(timeIntervalSince1970: 2))
        let projected = try XCTUnwrap(URLRuleKind.project(local, resolve: resolve, scope: nil,
                                                          parentIdentity: nil))
        XCTAssertEqual(projected.createdAtMs, 2_000, "投影自己发的是本机那一列")
        XCTAssertEqual(projected.source, 0, "本机无 source 列 ⇒ 恒发 0")

        let baselineBytes = try baseline.serializedData()
        for round in 1...2 {
            let stamped = URLRuleKind.stamp(projected, baseline: baseline, local: local,
                                            rank: URLRuleKind.rank(of: baseline),
                                            now: 9_000 + Int64(round))
            XCTAssertEqual(stamped.createdAtMs, 1_000, "round \(round)")
            XCTAssertEqual(stamped.source, 1, "round \(round)")
            XCTAssertEqual(try stamped.serializedData(), baselineBytes,
                           "round \(round)：与基线逐字节相同 ⇒ 判「没变化」、零 commit")
        }

        // 毫秒换算是四舍五入，不是截断。
        let rounded = URLRuleKind.project(PhiLocalURLRule.fixture(createdDate: Date(timeIntervalSince1970: 1.0015)),
                                          resolve: resolve, scope: nil, parentIdentity: nil)
        XCTAssertEqual(rounded?.createdAtMs, 1_002)
    }

    // MARK: - §8.2 / D33：有基线的改动带行戳，不带 `now`

    /// 控制者裁定（spec §8.2 / D33 压过计划与 `BookmarkKind` 的先例，只对这一 kind）：一次本机
    /// 编辑可能在几轮之后才被发布，快照时刻的 `now` 会让一次更早的本机编辑赢下对端更晚的那次
    /// 真实编辑；只有 rank（本机派生、没有行戳）允许带 `now`。
    func testEditsAgainstABaselineCarryTheRowStampsNotNow() throws {
        let baseline = urlRulePayload(uuid: "rs", targetSpaceUuid: "su-1", host: "old.com",
                                      contentStamp: 100, targetStamp: 100, rankStamp: 100)
        let now: Int64 = 5_000_000

        // 只改 host，行的内容戳是 2_000 s。
        let edited = PhiLocalURLRule.fixture(syncId: "rs", spaceId: "space-a", host: "new.com",
                                             contentUpdatedDate: Date(timeIntervalSince1970: 2_000))
        let stampedEdit = URLRuleKind.stamp(
            try XCTUnwrap(URLRuleKind.project(edited, resolve: resolve, scope: nil, parentIdentity: nil)),
            baseline: baseline, local: edited, rank: "V", now: now)
        XCTAssertEqual(stampedEdit.host.updatedAtMs, 2_000_000, "行戳，不是 now")
        XCTAssertEqual(stampedEdit.pathPrefix.updatedAtMs, 2_000_000)
        XCTAssertEqual(stampedEdit.ask.updatedAtMs, 2_000_000)
        XCTAssertEqual(stampedEdit.targetSpaceUuid.updatedAtMs, 100, "目标没动 ⇒ 沿用基线")
        XCTAssertEqual(stampedEdit.rank.updatedAtMs, 100, "rank 没动 ⇒ 沿用基线")

        // 只改目标，行的目标戳是 3_000 s。
        let retargeted = PhiLocalURLRule.fixture(syncId: "rs", spaceId: "space-b", host: "old.com",
                                                 targetUpdatedDate: Date(timeIntervalSince1970: 3_000))
        let stampedRetarget = URLRuleKind.stamp(
            try XCTUnwrap(URLRuleKind.project(retargeted, resolve: resolve, scope: nil, parentIdentity: nil)),
            baseline: baseline, local: retargeted, rank: "V", now: now)
        XCTAssertEqual(stampedRetarget.targetSpaceUuid.stringValue, "su-2")
        XCTAssertEqual(stampedRetarget.targetSpaceUuid.updatedAtMs, 3_000_000, "行戳，不是 now")
        XCTAssertEqual(stampedRetarget.rank.updatedAtMs, now, "桶变了 ⇒ rank 戳是唯一允许带 now 的")
        XCTAssertEqual(stampedRetarget.host.updatedAtMs, baseline.host.updatedAtMs)
        XCTAssertEqual(stampedRetarget.pathPrefix.updatedAtMs, baseline.host.updatedAtMs)
        XCTAssertEqual(stampedRetarget.ask.updatedAtMs, baseline.host.updatedAtMs)

        // 行戳缺席时退回 createdDate（与无基线分支同源），仍然不是 now。
        let fallback = PhiLocalURLRule.fixture(syncId: "rs", spaceId: "space-a", host: "new.com",
                                               createdDate: Date(timeIntervalSince1970: 1_000))
        let stampedFallback = URLRuleKind.stamp(
            try XCTUnwrap(URLRuleKind.project(fallback, resolve: resolve, scope: nil, parentIdentity: nil)),
            baseline: baseline, local: fallback, rank: "V", now: now)
        XCTAssertEqual(stampedFallback.host.updatedAtMs, 1_000_000)
        XCTAssertEqual(stampedFallback.targetSpaceUuid.updatedAtMs, 100)
    }

    // MARK: - R-M3-4a-26：`.move` 带 `newOwnerUuid`

    func testMoveStepCarriesTheMergedTargetAsNewOwner() {
        let baseline = urlRulePayload(uuid: "rm", targetSpaceUuid: "su-1", rank: "V")
        var table = PhiOwnedItemTable()
        table.cursors["rm"] = ownedCursor(reconciled: baselineBytes(baseline), ownerUuid: "su-1")

        let retarget = urlRulePayload(uuid: "rm", targetSpaceUuid: "su-2", rank: "M",
                                      targetStamp: 200, rankStamp: 200)
        let moved = planned([arrival(retarget)], table: table)
        XCTAssertEqual(moved.steps.map(\.kind), [.move])
        XCTAssertEqual(moved.steps.first?.newOwnerUuid, "su-2")
        XCTAssertEqual(moved.steps.first?.newRank, "M")
        XCTAssertNil(moved.steps.first?.newParentUuid, "规则没有父")

        // 一次纯重排也产出 `.move`，且照样带着当前目标——降级成 reorder 是落地批次的事（Task 8）。
        let reorder = urlRulePayload(uuid: "rm", targetSpaceUuid: "su-1", rank: "X", rankStamp: 200)
        let reordered = planned([arrival(reorder)], table: table)
        XCTAssertEqual(reordered.steps.map(\.kind), [.move])
        XCTAssertEqual(reordered.steps.first?.newOwnerUuid, "su-1")
        XCTAssertEqual(reordered.steps.first?.newRank, "X")
    }

    /// 书签的 `.move` 逐字不变：`targetOwnerUuid(of:)` 的默认实现让它照旧带 `nil`，而既有的
    /// 五参数构造写法（不带 `newOwnerUuid`）仍然成立。
    func testBookmarkMoveStepsStillCarryNoOwner() {
        let baseline = bookmarkPayload(uuid: "b1", rank: "V")
        var table = PhiOwnedItemTable()
        table.cursors["b1"] = ownedCursor(reconciled: baselineBytes(baseline), ownerUuid: "su-1")
        let reorder = bookmarkPayload(uuid: "b1", rank: "X", rankStamp: 200)
        let plan = SyncableOwnedItems.plan(
            BookmarkKind.self,
            arrivals: [OwnedItemArrival(entity: reorder, entityId: "srv-1", version: 1)],
            parked: [:], table: table, resolve: resolve, context: OwnedItemPlanContext())
        XCTAssertEqual(plan.steps.map(\.kind), [.move])
        XCTAssertNil(plan.steps.first?.newOwnerUuid)
        XCTAssertNil(BookmarkKind.targetOwnerUuid(of: reorder))
        XCTAssertEqual(plan.steps.first,
                       OwnedItemApplyStep(identity: "b1", kind: .move, newParentUuid: nil,
                                          newRank: "X", payload: plan.steps.first?.payload))
    }

    // MARK: - §8.3 `rankToSortOrder`

    func testRankToSortOrderExcludesSoftDeletedRowsAndOrdersByRankThenIdentity() {
        let rows = [
            PhiLocalURLRule.fixture(id: "i-new", syncId: nil, sortOrder: 9),
            PhiLocalURLRule.fixture(id: "i-b", syncId: "r-b", sortOrder: 0),
            PhiLocalURLRule.fixture(id: "i-a", syncId: "r-a", sortOrder: 1),
            PhiLocalURLRule.fixture(id: "i-c", syncId: "r-c", sortOrder: 2),
            PhiLocalURLRule.fixture(id: "i-dead", syncId: "r-dead", sortOrder: 3,
                                    deletedDate: Date(timeIntervalSince1970: 5)),
        ]
        // `r-dead` 的 rank 最小：不排除它，它会占住下标 0，整桶错位一格。
        let ranks = ["r-a": "M", "r-b": "M", "r-c": "V", "r-dead": "A"]
        let out = URLRuleKind.rankToSortOrder(siblings: rows, ranks: ranks)
        // 没有 rank 的行排最前；平手按 `syncId ?? id` 升序；软删行不在。
        XCTAssertEqual(out, ["i-new": 0, "i-a": 1, "i-b": 2, "i-c": 3])
        XCTAssertNil(out["i-dead"])
    }

    // MARK: - CASE U-R1（resolver 的保留常量自映射）

    func testResolverSelfMapsTheReservedIncognitoConstant() {
        let resolver = OwnedOwnerMaps().resolver
        let reserved = SyncableSpaces.incognitoSpaceUuid
        XCTAssertEqual(reserved, "incognito-space")
        XCTAssertEqual(resolver.localProfileId(reserved), reserved)
        XCTAssertEqual(resolver.globalUuid(reserved), reserved)
        XCTAssertNil(resolver.localSpaceId(reserved), "localSpaceId 保持不映射")
        XCTAssertTrue(resolver.isEligibleSpace(reserved))
        // `"app"` 的四个既有取值一字不变。
        XCTAssertEqual(resolver.localProfileId("app"), "app")
        XCTAssertEqual(resolver.globalUuid("app"), "app")
        XCTAssertNil(resolver.localSpaceId("app"))
        XCTAssertTrue(resolver.isEligibleSpace("app"))

        // 差分的 `mapped` 判据认这个常量：用户删掉一条 incognito 规则，tombstone 发得出去。
        var table = PhiOwnedItemTable()
        table.cursors["rr1"] = ownedCursor(
            reconciled: baselineBytes(urlRulePayload(uuid: "rr1", targetSpaceUuid: reserved)),
            entityId: "srv-1", version: 1, ownerUuid: reserved)
        let result = SyncableOwnedItems.tombstones(URLRuleKind.self, locals: [], table: table,
                                                   resolve: resolver, scope: nil, nowMs: 1)
        XCTAssertEqual(result.identities, ["rr1"])
        XCTAssertEqual(result.cursorUpdates["rr1"]?.pendingDelete, true)
        XCTAssertEqual(result.cursorUpdates["rr1"]?.deleteDecidedAtMs, 1)
    }

    // MARK: - §5.3 `eligibilityOwner` 的三条判据

    func testEligibilityOwnerFollowsTheThreeCriteriaInOrder() {
        let incognito = PhiLocalURLRule.fixture(spaceId: SpaceManager.incognitoRuleTargetId)
        XCTAssertEqual(URLRuleKind.eligibilityOwner(of: incognito, resolve: resolve, scope: nil),
                       SyncableSpaces.incognitoSpaceUuid)
        let stale = PhiLocalURLRule.fixture(spaceId: SpaceManager.incognitoSpaceIdPrefix + ".ABC-123")
        XCTAssertNil(URLRuleKind.eligibilityOwner(of: stale, resolve: resolve, scope: nil),
                     "过期的 incognito 运行期 id 不合格")
        let unmapped = PhiLocalURLRule.fixture(spaceId: "space-agent")
        XCTAssertNil(URLRuleKind.eligibilityOwner(of: unmapped, resolve: resolve, scope: nil))
        XCTAssertNil(URLRuleKind.project(unmapped, resolve: resolve, scope: nil, parentIdentity: nil))
        // hidden / purged 不在这里判：有映射就返回 owner，让模块自己去问 `isEligibleSpace`。
        let hidden = OwnerResolver.fixture(ineligible: ["su-1"])
        XCTAssertEqual(URLRuleKind.eligibilityOwner(of: PhiLocalURLRule.fixture(), resolve: hidden, scope: nil),
                       "su-1")
    }
}

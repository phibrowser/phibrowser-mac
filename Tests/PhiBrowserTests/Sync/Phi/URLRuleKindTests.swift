import Combine
import CryptoKit
import Foundation
import SwiftData
import XCTest
@testable import Phi

/// `URLRuleKind` 的模块级用例（spec §12.1「URL Rule」块里归 Task 7 的那些）：**没有
/// SwiftData、没有引擎、没有持久化**，全部输入都是值类型，全部输出都是返回值。
///
/// 类标 `@MainActor` 与 `SyncableOwnedItemsTests.swift:11-12` 同款理由：同一文件族里要构造
/// `@MainActor` 假件；模块本身不需要任何 actor。
///
/// 文件末尾的 **Task 6 段**是规则那条注册项的引擎级用例（U-11 / U-16 / U-17 / U-18 (a)–(f) /
/// U-24 / U-27 ~ U-31）：真引擎 + `FakeURLRuleAccess` + 内存 store，驱动入口只用 `pullOnce()`
/// 与 `handleLocalOwnedChange(label:)`。
@MainActor
final class URLRuleKindTests: XCTestCase {
    typealias FakePhiSyncClient = PhiSyncEngineTests.FakePhiSyncClient
    typealias StubDomainKeys = PhiSyncEngineTests.StubDomainKeys
    typealias MemorySpaceStore = PhiSyncEngineSpaceTests.MemorySpaceStore
    typealias Clock = PhiSyncEngineSpaceTests.Clock

    private let resolve = OwnerResolver.fixture()

    private var defaults: UserDefaults!
    private var suiteName: String!
    private let key = SymmetricKey(size: .bits256)
    /// 第二台引擎（CASE U-11）的 defaults suite，`tearDown` 里一起清。
    private var extraSuites: [String] = []
    /// CASE U-29 那个真 `LocalStore` 的临时目录。
    private var tempDirectories: [URL] = []

    override func setUp() {
        super.setUp()
        suiteName = "URLRuleKindTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        for suite in extraSuites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        extraSuites = []
        for directory in tempDirectories { try? FileManager.default.removeItem(at: directory) }
        tempDirectories = []
        super.tearDown()
    }

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

    // MARK: - Task 8 —— `URLRuleApplyBatch` 的合并与降级（纯值）、`FakeURLRuleAccess`（假件）

    // CASE U-10b（纯值半边）—— 目标没变的 `.move` 降成 `.reorder`，不是 rehome。
    //
    // 防的是什么：把 `.move` 一律当 rehome 的实现会白重排两个桶，其中「另一个桶」这一轮根本
    // 没被碰过——一次无意义的写经 §6.5 的 publisher 变成一次多余的推送轮。
    func testMoveWithUnchangedTargetIsDemotedToReorder() {
        let values = URLRuleLandingValues.fixture(syncId: "R1", spaceId: "S1", sortOrder: 2)
        let batch = URLRuleApplyBatch(unordered: [.move(values)], currentSpaceIds: ["R1": "S1"])
        XCTAssertEqual(batch.ops, [.reorder(syncId: "R1", spaceId: "S1", sortOrder: 2)])
    }

    // 目标真的变了 ⇒ 留 `.move`；本页快照里没有这条身份（现值未知）也按 rehome 处理。
    func testMoveWithChangedOrUnknownTargetStaysAMove() {
        let values = URLRuleLandingValues.fixture(syncId: "R1", spaceId: "S2", sortOrder: 0)
        XCTAssertEqual(URLRuleApplyBatch(unordered: [.move(values)], currentSpaceIds: ["R1": "S1"]).ops,
                       [.move(values)])
        XCTAssertEqual(URLRuleApplyBatch(unordered: [.move(values)], currentSpaceIds: [:]).ops,
                       [.move(values)])
    }

    // CASE U-10e ①（纯值半边）—— 同一身份的 `.move` + `.update` 合成**一条** `.move`，内容一个
    // 字节不丢；目标没变时留 `.update`（内容要写），不降成 `.reorder`。
    //
    // 防的是什么：分两次写时 `.update` 会在 `.move` 之后再写一次归属，行落进一个从没被重排过的
    // 桶（R-M3-4a-42(b) / RR-B9）；反向的错法是合并时丢掉 `.update` 的内容组。
    func testMoveAndUpdateForOneIdentityCollapseIntoOneOpKeepingContent() throws {
        let values = URLRuleLandingValues.fixture(syncId: "R1", spaceId: "S2", host: "new.example",
                                                  sortOrder: 0)
        let batch = URLRuleApplyBatch(unordered: [.move(values), .update(values)],
                                      currentSpaceIds: ["R1": "S1"])
        XCTAssertEqual(batch.ops.count, 1)
        guard case .move(let merged) = try XCTUnwrap(batch.ops.first) else {
            return XCTFail("expected .move, got \(batch.ops)")
        }
        XCTAssertEqual(merged.host, "new.example")
        XCTAssertEqual(merged.spaceId, "S2")

        let same = URLRuleLandingValues.fixture(syncId: "R1", spaceId: "S1", host: "new.example",
                                                sortOrder: 1)
        let unchanged = URLRuleApplyBatch(unordered: [.move(same), .update(same)],
                                          currentSpaceIds: ["R1": "S1"])
        XCTAssertEqual(unchanged.ops, [.update(same)])
    }

    // 相序：升级写在前、`.delete` 在后；相内保持传入次序（稳定）。
    func testBatchOrdersDeletesLastAndKeepsArrivalOrderWithinAPhase() {
        let a = URLRuleLandingValues.fixture(syncId: "A", spaceId: "S1", sortOrder: 0)
        let b = URLRuleLandingValues.fixture(syncId: "B", spaceId: "S1", sortOrder: 1)
        let batch = URLRuleApplyBatch(unordered: [.delete(syncId: "Z"), .update(a), .create(b),
                                                  .delete(syncId: "Y")])
        XCTAssertEqual(batch.ops, [.update(a), .create(b), .delete(syncId: "Z"), .delete(syncId: "Y")])
    }

    // CASE U-10e ③ —— 假件上同一批只有一次 `.apply`、`R1` 只出现一次，两桶都稠密。
    func testFakeAccessLandsAMergedBatchOnceAndKeepsBothBucketsDense() async throws {
        let access = FakeURLRuleAccess(rows: [
            .fixture(id: "i1", syncId: "R1", spaceId: "S1", sortOrder: 0),
            .fixture(id: "i2", syncId: "Ra", spaceId: "S1", sortOrder: 1),
            .fixture(id: "i3", syncId: "Rb", spaceId: "S1", sortOrder: 2),
            .fixture(id: "i4", syncId: "Rc", spaceId: "S2", sortOrder: 0),
            .fixture(id: "i5", syncId: "Rd", spaceId: "S2", sortOrder: 1),
        ])
        let values = URLRuleLandingValues.fixture(syncId: "R1", spaceId: "S2", host: "new.example",
                                                  sortOrder: 0)
        let batch = URLRuleApplyBatch(unordered: [.move(values), .update(values)],
                                      currentSpaceIds: ["R1": "S1"])
        try await access.apply(batch)

        XCTAssertEqual(access.calls, [.apply(opCount: 1)])
        XCTAssertEqual(access.lastAppliedOps.filter { $0.syncId == "R1" }.count, 1)
        let moved = try XCTUnwrap(access.rows.first { $0.syncId == "R1" })
        XCTAssertEqual(moved.id, "i1", "rehome keeps the physical row")
        XCTAssertEqual(moved.spaceId, "S2")
        XCTAssertEqual(moved.host, "new.example")
        XCTAssertEqual(access.rows.count, 5)
        XCTAssertEqual(access.siblings(inSpaceId: "S1").map(\.sortOrder), [0, 1])
        XCTAssertEqual(access.siblings(inSpaceId: "S2").map(\.sortOrder), [0, 1, 2])
    }

    // CASE U-8r —— 两个读口读失败一律抛，抛的是注入的那个错，`readError` 不自动清零。
    //
    // 防的是什么：差分对空集合的回答是给每一条游标发一条 tombstone——一次失败的 fetch 抹掉全
    // 账户的规则（R-exec-3）；一次性的失败旋钮会让第二次读悄悄成功，用例就断言不到「整段跳过」。
    func testFakeAccessReadErrorIsThrownByBothReadsAndDoesNotClear() {
        let access = FakeURLRuleAccess(rows: [
            .fixture(id: "i1", syncId: "R1", sortOrder: 0),
            .fixture(id: "i2", syncId: "R2", sortOrder: 1),
            .fixture(id: "i3", syncId: "R3", sortOrder: 2),
        ])
        access.readError = LocalStoreWriteError.storeUnavailable
        for _ in 0..<2 {
            XCTAssertThrowsError(try access.allURLRules()) {
                XCTAssertEqual($0 as? LocalStoreWriteError, .storeUnavailable)
            }
            XCTAssertThrowsError(try access.allURLRulesIncludingDeleted()) {
                XCTAssertEqual($0 as? LocalStoreWriteError, .storeUnavailable)
            }
        }
        XCTAssertNotNil(access.readError, "readError must not clear itself")
        XCTAssertFalse(access.snapshotIsLoaded)
        XCTAssertEqual(access.calls, [.allURLRules, .allURLRulesIncludingDeleted,
                                      .allURLRules, .allURLRulesIncludingDeleted])
    }

    // 假件的两个读口：`allURLRules()` 过滤软删行，`allURLRulesIncludingDeleted()` 不过滤；
    // `siblings` / `isKnownLocalURLRule` 只认活行、判据是 `syncId`；`liveOwners` 只填 `claimed`。
    func testFakeAccessReadsSeparateLiveRowsFromSoftDeletedOnes() throws {
        let access = FakeURLRuleAccess(rows: [
            .fixture(id: "i1", syncId: "R1", spaceId: "S1", sortOrder: 1),
            .fixture(id: "i0", syncId: "R0", spaceId: "S1", sortOrder: 0),
            .fixture(id: "i9", syncId: "R9", spaceId: "S1", sortOrder: 2,
                     deletedDate: Date(timeIntervalSince1970: 2_000)),
        ])
        XCTAssertFalse(access.isKnownLocalURLRule("R1"), "no snapshot yet")
        XCTAssertEqual(try access.allURLRules().map(\.id), ["i0", "i1"])
        XCTAssertEqual(try access.allURLRulesIncludingDeleted().map(\.id), ["i0", "i1", "i9"])
        XCTAssertEqual(access.siblings(inSpaceId: "S1").map(\.id), ["i0", "i1"])
        XCTAssertTrue(access.isKnownLocalURLRule("R1"))
        XCTAssertFalse(access.isKnownLocalURLRule("R9"), "soft-deleted rows are not known")
        XCTAssertFalse(access.isKnownLocalURLRule("i1"), "the predicate is on syncId, not id")
        let owners = try access.liveOwners(["R0", "R9", "R-none"])
        XCTAssertEqual(owners.claimed, ["R0"])
        XCTAssertTrue(owners.owners.isEmpty, "owners is Task 6's closure to fill")
    }

    // 假件镜像生产 body 的「进了桶」规则：一次 `.update` 救回软删行、落在已占用的下标上 ⇒ 目标桶
    // 重排成全置换（R-M3-4a-3 / RR-B9），身份与 `id` 不变，不多出第二条行。
    func testFakeAccessReviveViaUpdateDensifiesTheBucket() async throws {
        let access = FakeURLRuleAccess(rows: [
            .fixture(id: "i0", syncId: "R0", spaceId: "S1", sortOrder: 0),
            .fixture(id: "i1", syncId: "R1", spaceId: "S1", sortOrder: 1),
            .fixture(id: "i2", syncId: "R2", spaceId: "S1", sortOrder: 2),
            .fixture(id: "i9", syncId: "R9", spaceId: "S1", sortOrder: 9,
                     deletedDate: Date(timeIntervalSince1970: 2_000), mergePartnerSyncId: "R0"),
        ])
        let values = URLRuleLandingValues.fixture(syncId: "R9", spaceId: "S1", host: "revived.example",
                                                  sortOrder: 1)
        try await access.apply(URLRuleApplyBatch(unordered: [.update(values)], currentSpaceIds: ["R9": "S1"]))

        XCTAssertEqual(access.rows.count, 4)
        let revived = try XCTUnwrap(access.rows.first { $0.syncId == "R9" })
        XCTAssertEqual(revived.id, "i9")
        XCTAssertNil(revived.deletedDate)
        XCTAssertNil(revived.mergePartnerSyncId)
        XCTAssertEqual(access.siblings(inSpaceId: "S1").map(\.id), ["i0", "i1", "i9", "i2"])
        XCTAssertEqual(access.siblings(inSpaceId: "S1").map(\.sortOrder), [0, 1, 2, 3])
    }

    // MARK: - Task 6：规则那条注册项的引擎级用例——脚手架

    private static let now: Int64 = 1_700_000_000_000

    /// 一台已经配过对的机器：`space-a/b/c → su-1/2/3`（与 `OwnerResolver.fixture()` 同一套本机
    /// id），profile 双向映射齐备。形状照 `PhiSyncEngineOwnedItemsTests.makeSpaceAccess`。
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

    /// `hasDrainedFullReplay` 预置为真 = 这台机器已经完整拉过一遍这个 data type，发布侧的
    /// guard ① 不挡路。
    private func drainedSpaceStore() -> MemorySpaceStore {
        let store = MemorySpaceStore()
        store.table.hasDrainedFullReplay = true
        return store
    }

    /// 与 `client.storeBirthday`（"birthday-1"）一致的 marker 文件，birthday 那一半永远是零写。
    private func markerStore(marker: String?) -> MemoryMarkerStore {
        MemoryMarkerStore(file: PhiSyncMarkerFile(marker: marker.map { Data($0.utf8) },
                                                  storeBirthday: "birthday-1"))
    }

    /// 第二台引擎自己的 defaults suite（CASE U-11）。
    private func makeExtraDefaults() -> UserDefaults {
        let name = "URLRuleKindTests.extra.\(UUID().uuidString)"
        extraSuites.append(name)
        return UserDefaults(suiteName: name)!
    }

    /// 形状照 `PhiSyncMarkerBoundaryTests.makeOwnedEngine`：`settings: []`，时钟冻结；Task 9 的
    /// 保留期用例传一个可推进的 `clock`（`PhiSyncEngineSpaceTests.Clock`），不传就是冻结的 `Self.now`。
    private func makeEngine(client: FakePhiSyncClient,
                            markerStore: any PhiSyncMarkerStore,
                            spaceStore: any PhiSpaceSyncStateStore,
                            spaceAccess: FakePhiSpaceAccess? = nil,
                            defaults: UserDefaults? = nil,
                            clock: Clock? = nil,
                            ownedKinds: [OwnedKindRegistration]) -> PhiSyncEngine {
        let now: () -> Int64 = clock.map { clock in { clock.read() } } ?? { Self.now }
        return PhiSyncEngine(domainKeys: StubDomainKeys(key: key), client: client,
                             defaults: defaults ?? self.defaults, deviceKeyId: "devA", settings: [],
                             spaceAccess: spaceAccess ?? makeSpaceAccess(), spaceStore: spaceStore,
                             markerStore: markerStore, ownedKinds: ownedKinds,
                             now: now)
    }

    /// 让设置段与 Space 段这一轮都没有东西可发（形状照 `PhiSyncMarkerBoundaryTests` 的 2b-L1）：
    /// 设置半边靠预置空 `storedLastEntity` 早退，Space 半边靠 guard 3 的 `unreadableTagHashes`
    /// 跳过三个已映射 Space，于是 `client.commits` 说的就是规则那一半。
    private func silenceOtherSections(_ spaceStore: MemorySpaceStore, defaults: UserDefaults) throws {
        for uuid in ["su-1", "su-2", "su-3"] {
            spaceStore.table.unreadableTagHashes[
                PhiSyncEntity.clientTagHash(for: PhiSyncEntity.spaceClientTag(uuid))] = 1
        }
        defaults.set(try Phi_PhiSettingEntity().serializedData(),
                     forKey: PhiSyncEngine.lastEntityStateKey)
    }

    private func ruleTag(_ uuid: String) -> String { PhiSyncEntity.urlRuleClientTag(uuid) }

    private func ruleHash(_ uuid: String) -> String {
        PhiSyncEntity.clientTagHash(for: ruleTag(uuid))
    }

    private func ruleEntity(_ payload: Phi_PhiURLRuleEntity, version: Int64,
                            entityId: String? = nil) -> PhiRemoteEntity {
        remoteEntity(envelope(payload), tag: ruleTag(payload.ruleUuid), version: version,
                     entityId: entityId ?? "srv-\(payload.ruleUuid)", key: key)
    }

    /// 规则 tag 的 commit 条目。设置实体与 Space 实体骑在同一个 `commits` 列表上。
    private func ruleCommits(_ client: FakePhiSyncClient) -> [FakePhiSyncClient.CommitCall] {
        client.commits.filter { $0.name == PhiSyncEntity.urlRuleEntityName }
    }

    /// 一条 commit 的密文解出来的整条规则实体。
    private func committedRule(_ call: FakePhiSyncClient.CommitCall) -> Phi_PhiURLRuleEntity? {
        guard let ciphertext = call.ciphertext,
              let entity = try? PhiEntityCodec.decrypt(ciphertext, key: key),
              case .urlRule(let payload)? = entity.kind else { return nil }
        return payload
    }

    private func createCount(_ ops: [URLRuleSyncOp]) -> Int {
        ops.filter { if case .create = $0 { return true } else { return false } }.count
    }

    private func applyCalls(_ access: FakeURLRuleAccess) -> Int {
        access.calls.filter { if case .apply = $0 { return true } else { return false } }.count
    }

    private func refreshCalls(_ access: FakeURLRuleAccess) -> Int {
        access.calls.filter { $0 == .refreshRoutingTable }.count
    }

    /// 跑过给定的防抖窗口再多留一点，让主队列上的投递有机会落地（照
    /// `LocalStoreURLRuleThrowingTests.waitPastDebounceWindow`）。同步 helper：`run(until:)` 不能
    /// 直接在 async 上下文里调。
    private func waitPastDebounceWindow(_ window: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(window + 0.6))
    }

    /// 一条**活**的已发布游标：有基线、有服务端三元组、归属已知。
    private func publishedRuleCursor(_ payload: Phi_PhiURLRuleEntity,
                                     entityId: String = "srv-1",
                                     version: Int64 = 1,
                                     owner: String = "su-1") -> PhiOwnedItemCursor {
        ownedCursor(reconciled: baselineBytes(payload), server: baselineBytes(payload),
                    entityId: entityId, version: version, ownerUuid: owner)
    }

    // MARK: - CASE U-17（读失败绝不当成零行）

    /// 防的是什么：`beginRound` 把 `try access.allURLRulesIncludingDeleted()` 吞成 `[]` 的实现。
    /// 差分对空 `locals` 的回答是给账户上每一条已发布身份各发一条 tombstone ⇒ 一次 SwiftData
    /// 抖动抹掉全账户的规则，而且每台设备跟着抹。
    func testALocalReadFailureNeverReadsAsZeroRows() async throws {
        let access = FakeURLRuleAccess(rows: [.fixture(id: "i1", syncId: "r1")])
        access.readError = LocalStoreWriteError.storeUnavailable       // 每次都抛、不自动清零
        let store = MemoryOwnedItemStore()
        store.table.cursors["r1"] = publishedRuleCursor(urlRulePayload(uuid: "r1"))
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([], marker: "1")]
        let engine = makeEngine(client: client, markerStore: markerStore(marker: "0"),
                                spaceStore: drainedSpaceStore(),
                                ownedKinds: [.urlRules(access: access, store: store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let outcome = await engine.lastRoundOutcomeForTesting
        let counters = await engine.lastOwnedRoundCountersForTesting["urlrules"]
        XCTAssertEqual(outcome, .localReadFailed)
        XCTAssertEqual(counters?.localReadFailed, 1)
        XCTAssertEqual(counters?.tombstones, 0)
        XCTAssertEqual(counters?.pushed, 0)
        XCTAssertTrue(ruleCommits(client).isEmpty)
        XCTAssertEqual(store.saveCalls, 0, "游标表一个字节没写")
        XCTAssertEqual(applyCalls(access), 0)
        XCTAssertEqual(store.table.cursors["r1"]?.entityId, "srv-1")
    }

    // MARK: - CASE U-18（游标文件丢失 ⇒ 整类型重放）

    private struct LossFixture {
        let access: FakeURLRuleAccess
        let store: MemoryOwnedItemStore
        let spaceStore: MemorySpaceStore
        let markerStore: MemoryMarkerStore
        let client: FakePhiSyncClient
    }

    /// 四段共用：本机两条行；`MemoryOwnedItemStore` 空表（= 文件没了，`hadRecords` 为真时报损）；
    /// `storedMarker = "5"`。重放页的水位是 3 ≤ 5：从 "5" 起拉不到它，只有重放（从 nil 起）
    /// 才拉得到——这就是 (a) 的「重放页里带 `r1` 一条存活实体」。
    ///
    /// 设置段与 Space 段静默（`silenceOtherSections`）：`makeSpaceAccess` 映了三个没有游标的
    /// Space，不静默的话 `pushSpaces` 在 `pushOwnedItems` **之前**就把它们三条 create 发出去并写一次
    /// Space 表，(e) 的「零 commit」与 (e)/(f) 数 Space 表写次数的旋钮都会被它打偏。静默之后
    /// `pushSpaces` 仍然写**一次**表（`work` 为空那一支的 `writeSpaceTable(table)` 写回），
    /// (e)/(f) 的序号按它算。
    private func makeLossFixture(hadRecords: Bool, withSyncIds: Bool = true,
                                 replayPage: Bool = true) throws -> LossFixture {
        let rows: [PhiLocalURLRule] = withSyncIds
            ? [.fixture(id: "i1", syncId: "r1", sortOrder: 0), .fixture(id: "i2", syncId: "r2", sortOrder: 1)]
            : [.fixture(id: "i1", sortOrder: 0), .fixture(id: "i2", sortOrder: 1)]
        let spaceStore = drainedSpaceStore()
        spaceStore.table.urlRulesHadRecords = hadRecords
        try silenceOtherSections(spaceStore, defaults: defaults)
        let client = FakePhiSyncClient()
        if replayPage {
            client.pagesByMarker = [page([ruleEntity(urlRulePayload(uuid: "r1"), version: 3)], marker: "3")]
        }
        return LossFixture(access: FakeURLRuleAccess(rows: rows), store: MemoryOwnedItemStore(),
                           spaceStore: spaceStore, markerStore: markerStore(marker: "5"),
                           client: client)
    }

    private func makeLossEngine(_ f: LossFixture) -> PhiSyncEngine {
        makeEngine(client: f.client, markerStore: f.markerStore, spaceStore: f.spaceStore,
                   ownedKinds: [.urlRules(access: f.access, store: f.store)])
    }

    /// 报损武装那一轮之后的四条：marker 清成 nil、drain 武装、`hasDrainedFullReplay` 置假、
    /// per-kind 闩置位；重放期间零 commit。
    private func assertLossReplayArmed(_ f: LossFixture, file: StaticString = #filePath,
                                       line: UInt = #line) {
        XCTAssertNil(f.markerStore.file.marker, "storedMarker == nil", file: file, line: line)
        XCTAssertTrue(f.spaceStore.table.drainInProgress, file: file, line: line)
        XCTAssertFalse(f.spaceStore.table.hasDrainedFullReplay, file: file, line: line)
        XCTAssertTrue(f.spaceStore.table.urlRulesReplayedForEmptyTable, file: file, line: line)
        XCTAssertTrue(ruleCommits(f.client).isEmpty, "重放期间零 commit", file: file, line: line)
    }

    /// 重放那一轮之后的三条：`r1` 按身份匹配到本机行 ⇒ 游标被重建、行数仍是 2、零条 `.create`。
    private func assertReplayRebuiltTheCursorByIdentity(_ f: LossFixture, file: StaticString = #filePath,
                                                        line: UInt = #line) {
        XCTAssertNotNil(f.client.getUpdatesCalls.last, file: file, line: line)
        XCTAssertNil(f.client.getUpdatesCalls.last?.marker ?? nil, "从头重放", file: file, line: line)
        XCTAssertEqual(f.access.rows.count, 2, "行数仍是 2", file: file, line: line)
        XCTAssertEqual(createCount(f.access.lastAppliedOps), 0, "零条 .create", file: file, line: line)
        XCTAssertEqual(f.store.table.cursors["r1"]?.entityId, "srv-r1", "游标被重建", file: file, line: line)
        XCTAssertNotNil(f.store.table.cursors["r1"]?.reconciled, file: file, line: line)
        XCTAssertFalse(ruleCommits(f.client).contains { $0.clientTagHash == ruleHash("r1") },
                       "r1 与账户对齐，不再发布", file: file, line: line)
    }

    /// (a) — `urlRulesHadRecords == true`、闩未置位、文件报损 ⇒ 发布段那一次 load 武装重放；
    /// 下一轮从 nil 重放，`r1` 按身份匹配到本机行。
    ///
    /// 防的是什么：复用 Space 那个永久闩的实现（书签先花掉之后规则一次重放都得不到）；把判据
    /// 写成「本机还有带 `syncId` 的规则行」的实现（对规则恒真 ⇒ (c)/(d) 会重放）；报损之后照常
    /// push 的实现（`hasDrainedFullReplay == false` 那道 guard ① 是重放期间零 commit 的唯一依据）。
    func testALostCursorFileArmsOneReplayAndTheReplayRebuildsTheCursorByIdentity() async throws {
        let f = try makeLossFixture(hadRecords: true)
        let engine = makeLossEngine(f)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let outcome = await engine.lastRoundOutcomeForTesting
        XCTAssertEqual(outcome, .ok)
        assertLossReplayArmed(f)
        XCTAssertEqual(f.store.hadRecordsSeen, [true, true], "轮首与发布段各报损一次")

        await engine.pullOnce()

        assertReplayRebuiltTheCursorByIdentity(f)
        XCTAssertFalse(f.spaceStore.table.urlRulesReplayedForEmptyTable,
                       "一次成功的 load 交回带已发布游标的表 ⇒ 闩复位（A2）")
    }

    /// (b) — 同 (a)，但书签那道一次性闸已经花掉：两道闸互不相干。
    func testALostCursorFileStillReplaysWhenTheBookmarkLatchIsAlreadySpent() async throws {
        let f = try makeLossFixture(hadRecords: true)
        f.spaceStore.table.bookmarksReplayedForEmptyTable = true
        let engine = makeLossEngine(f)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        assertLossReplayArmed(f)
        XCTAssertTrue(f.spaceStore.table.bookmarksReplayedForEmptyTable, "书签那道不受影响")

        await engine.pullOnce()

        assertReplayRebuiltTheCursorByIdentity(f)
    }

    /// (c) — `urlRulesHadRecords == false`、store 同样报损 ⇒ 不是丢失：marker 不动、零重放。
    func testAnEmptyTableIsNotALossWhenThisDeviceNeverPublishedRules() async throws {
        let f = try makeLossFixture(hadRecords: false, withSyncIds: false)
        let engine = makeLossEngine(f)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertEqual(f.markerStore.file.marker, Data("5".utf8))
        XCTAssertFalse(f.spaceStore.table.drainInProgress)
        XCTAssertTrue(f.spaceStore.table.hasDrainedFullReplay)
        XCTAssertFalse(f.spaceStore.table.urlRulesReplayedForEmptyTable)
        XCTAssertEqual(f.client.getUpdatesCalls.count, 1)
        XCTAssertEqual(f.client.getUpdatesCalls.first?.marker, Data("5".utf8), "零重放")
        XCTAssertTrue(f.markerStore.saves.isEmpty)
    }

    /// (d) — 同 (c)，但本机两条行都带 `syncId`（R-M3-4a-23 让每条活行都有）：判据不是「本机还有
    /// 带 `syncId` 的规则行」，那条判据对规则恒真。
    func testRowsWithSyncIdsDoNotTurnAnEmptyTableIntoALoss() async throws {
        let f = try makeLossFixture(hadRecords: false, withSyncIds: true)
        let engine = makeLossEngine(f)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertEqual(f.markerStore.file.marker, Data("5".utf8))
        XCTAssertFalse(f.spaceStore.table.drainInProgress)
        XCTAssertFalse(f.spaceStore.table.urlRulesReplayedForEmptyTable)
        XCTAssertEqual(f.client.getUpdatesCalls.map(\.marker), [Data("5".utf8)], "零重放")
    }

    /// (e)（R-M3-4a-103 / Task 2b 计划裁定 3b）— marker 清不掉：报损重放的第 ① 步写失败 ⇒
    /// `.cursorSaveFailed`、`cursor_save_failed=1`、盘上 marker 一个字节没动、闩没置位、两个 drain
    /// 标志与轮首逐字相同、零 commit、marker store 恰好多出那一次失败的调用；放行之后下一轮报损
    /// 检查**再次触发**（marker nil、闩置位、drain 武装），再下一轮从头重放、`r1` 按身份匹配。
    ///
    /// 负面对照（不写成代码）：「先置闩、后清 marker」的次序会在第一轮盘上留下「旧 marker "5" +
    /// 闩已置位 + drain 已武装」；第二轮从 "5" 增量拉、一页空页让轮末 drain 收尾把
    /// `hasDrainedFullReplay` 置真，而那次重放从来没有发生；此后 `loadOwnedTable` 的
    /// `guard !…replayedForEmptyTable` 每轮直接早退、报损检查再也不触发 ⇒ 下面「第二轮闩才置位」
    /// 与「第三轮真的重放了」两条必须红。同时钉住失败支回 `(table, false)` 而不是 `(table, true)`。
    func testAFailedMarkerClearLeavesTheLossUnarmedAndRetriggersNextRound() async throws {
        let f = try makeLossFixture(hadRecords: true)
        f.markerStore.failSaveOnCallNumber = 1          // 第一次 marker 写 = 报损重放的第 ① 步
        let engine = makeLossEngine(f)
        await engine.setSpaceSyncEnabled(true)
        let spaceSavesBefore = f.spaceStore.saveCalls
        await engine.pullOnce()

        let outcome = await engine.lastRoundOutcomeForTesting
        let failures = await engine.lastRoundCursorSaveFailedCountForTesting
        XCTAssertEqual(outcome, .cursorSaveFailed)
        XCTAssertEqual(failures, 1)
        XCTAssertEqual(f.markerStore.file.marker, Data("5".utf8), "一个字节没动")
        XCTAssertFalse(f.spaceStore.table.urlRulesReplayedForEmptyTable, "闩没置位")
        XCTAssertFalse(f.spaceStore.table.drainInProgress, "与轮首相同")
        XCTAssertTrue(f.spaceStore.table.hasDrainedFullReplay, "与轮首相同")
        XCTAssertTrue(f.client.commits.filter { $0.clientTagHash != PhiSyncEntity.settingsClientTagHash }.isEmpty,
                      "五种 kind 一条都不发")
        XCTAssertEqual(f.markerStore.saves.count, 1, "恰好多出那一次失败的调用；落地段那次 load 什么都没写")
        // Space 表恰好两次写：页 1 那次无条件的表写（#1）+ `pushSpaces` 在 `pushOwnedItems` 之前那次
        // 写回（#2，Space 段已静默、`work` 为空）。没有第三次 = 步骤 ② 没跑。
        XCTAssertEqual(f.spaceStore.saveCalls - spaceSavesBefore, 2)
        XCTAssertTrue(f.store.table.cursors.isEmpty, "没有对着丢失的表发布、也没有重建它的文件")

        f.markerStore.failSaveOnCallNumber = nil
        await engine.pullOnce()

        let second = await engine.lastRoundOutcomeForTesting
        XCTAssertEqual(second, .ok, "报损检查再次触发、两步都写成")
        assertLossReplayArmed(f)

        await engine.pullOnce()

        assertReplayRebuiltTheCursorByIdentity(f)
    }

    /// (f)（R-M3-4a-103）— marker 清掉了、闩写不下去：第 ① 步成功（盘上 marker nil）、第 ② 步
    /// `mutateSpaceTable` 回 `false` ⇒ `.cursorSaveFailed`、闩仍为 false（R-M3-4a-83 的回滚让内存
    /// 与盘一致）、两个 drain 标志与轮首相同、零 commit。
    ///
    /// 第二轮（放行）：盘上 marker 已经是 nil，于是 guard 1（R-M3-4a-89）在**轮首**就武装 drain 并
    /// 从头重放——重放页里的 `r1` 按身份匹配、游标在发布段那次 load **之前**已经重建，报损检查
    /// 因此不再命中、闩不需要再置位：那次可重来的落盘失败没有变成永久失效，整类型重放确实发生了。
    /// 「第 ① 步幂等零写、第 ② 步这次写成」那一格由下一条（重放页为空的账户）钉。
    func testAFailedLatchWriteAfterAClearedMarkerStillEndsInAFullReplay() async throws {
        let f = try makeLossFixture(hadRecords: true)
        let engine = makeLossEngine(f)
        await engine.setSpaceSyncEnabled(true)
        // Space 表写的序号：页 1 那次无条件的表写是第 1 次，`pushSpaces`（静默，`work` 为空）的写回是
        // 第 2 次，报损重放的第 ② 步是第 3 次。
        f.spaceStore.failSaveOnCallNumber = f.spaceStore.saveCalls + 3
        await engine.pullOnce()

        let outcome = await engine.lastRoundOutcomeForTesting
        let failures = await engine.lastRoundCursorSaveFailedCountForTesting
        XCTAssertEqual(outcome, .cursorSaveFailed)
        XCTAssertEqual(failures, 1)
        XCTAssertNil(f.markerStore.file.marker, "第 ① 步成功")
        XCTAssertFalse(f.spaceStore.table.urlRulesReplayedForEmptyTable, "第 ② 步没写成 ⇒ 闩仍为 false")
        XCTAssertFalse(f.spaceStore.table.drainInProgress, "与轮首相同")
        XCTAssertTrue(f.spaceStore.table.hasDrainedFullReplay, "与轮首相同")
        XCTAssertTrue(ruleCommits(f.client).isEmpty)
        XCTAssertTrue(f.store.table.cursors.isEmpty)

        f.spaceStore.failSaveOnCallNumber = nil
        await engine.pullOnce()

        let second = await engine.lastRoundOutcomeForTesting
        let secondFailures = await engine.lastRoundCursorSaveFailedCountForTesting
        XCTAssertEqual(second, .ok)
        XCTAssertEqual(secondFailures, 0)
        assertReplayRebuiltTheCursorByIdentity(f)
        XCTAssertTrue(f.spaceStore.table.hasDrainedFullReplay, "重放排干")
        XCTAssertFalse(f.store.load(hadRecords: true).reportedLoss, "游标文件已重建，不再报损")
    }

    /// (f) 的另一半 — 账户上没有规则（重放页为空）时第二轮报损检查**幂等地再触发一次**：第 ① 步
    /// `persistMarkerState` 的 `updated == markerState` 短路成零写（`markerStore.saves` 不增、
    /// `cursor_save_failed` 为 0），第 ② 步这次写成 ⇒ 闩置位、drain 武装。
    func testAFailedLatchWriteIsRetriedWithAnIdempotentMarkerClear() async throws {
        let f = try makeLossFixture(hadRecords: true, replayPage: false)
        let engine = makeLossEngine(f)
        await engine.setSpaceSyncEnabled(true)
        // 同上一条：页写 #1、`pushSpaces` 写回 #2、第 ② 步 #3。
        f.spaceStore.failSaveOnCallNumber = f.spaceStore.saveCalls + 3
        await engine.pullOnce()

        let outcome = await engine.lastRoundOutcomeForTesting
        XCTAssertEqual(outcome, .cursorSaveFailed)
        XCTAssertNil(f.markerStore.file.marker)
        XCTAssertFalse(f.spaceStore.table.urlRulesReplayedForEmptyTable)
        let markerSavesAfterFirstRound = f.markerStore.saves.count

        f.spaceStore.failSaveOnCallNumber = nil
        await engine.pullOnce()

        let second = await engine.lastRoundOutcomeForTesting
        let secondFailures = await engine.lastRoundCursorSaveFailedCountForTesting
        XCTAssertEqual(second, .ok)
        XCTAssertEqual(secondFailures, 0)
        XCTAssertEqual(f.markerStore.saves.count, markerSavesAfterFirstRound, "第 ① 步短路成零写")
        assertLossReplayArmed(f)
    }

    // MARK: - CASE U-24（落地显式刷新 Chromium 表）——引擎半边

    /// 一页只改 host 的实体落地 ⇒ `.refreshRoutingTable` 恰好一条、排在 `.apply(opCount: 1)` 之后；
    /// 刷新那一刻假件的 `rows` 已经带着新 host。
    ///
    /// 防的是什么：靠 `urlRulesPublisher` 自己发射的实现（`removeDuplicates` 比的是 SwiftData
    /// 就地刷新的同一批实例，一次只改 host 的落地被它吞掉 ⇒ 零次刷新）。
    func testALandingRefreshesTheRoutingTableOnceAfterApply() async throws {
        let access = FakeURLRuleAccess(rows: [.fixture(id: "i1", syncId: "r1", host: "old.example")])
        let store = MemoryOwnedItemStore()
        store.table.cursors["r1"] = publishedRuleCursor(urlRulePayload(uuid: "r1", host: "old.example"))
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([ruleEntity(urlRulePayload(uuid: "r1", host: "new.example",
                                                                contentStamp: 900), version: 7)],
                                     marker: "7")]
        let engine = makeEngine(client: client, markerStore: markerStore(marker: "0"),
                                spaceStore: drainedSpaceStore(),
                                ownedKinds: [.urlRules(access: access, store: store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let counters = await engine.lastOwnedRoundCountersForTesting["urlrules"]
        XCTAssertEqual(counters?.applied, 1)
        XCTAssertEqual(refreshCalls(access), 1, "恰好一条")
        let applyIndex = try XCTUnwrap(access.calls.firstIndex(of: .apply(opCount: 1)))
        let refreshIndex = try XCTUnwrap(access.calls.firstIndex(of: .refreshRoutingTable))
        XCTAssertLessThan(applyIndex, refreshIndex, "排在那条 .apply 之后")
        XCTAssertEqual(access.rows.first?.host, "new.example", "刷新那一刻 rows 已经是新值")
        XCTAssertEqual(access.rows.count, 1)
        XCTAssertEqual(createCount(access.lastAppliedOps), 0)
    }

    /// ③ 同一页带两条实体 ⇒ 仍然恰好一次刷新（一页一次，不是一行一次）。
    func testATwoEntityPageRefreshesTheRoutingTableOnce() async throws {
        let access = FakeURLRuleAccess(rows: [
            .fixture(id: "i1", syncId: "r1", host: "old1.example", sortOrder: 0),
            .fixture(id: "i2", syncId: "r2", host: "old2.example", sortOrder: 1),
        ])
        let store = MemoryOwnedItemStore()
        store.table.cursors["r1"] = publishedRuleCursor(urlRulePayload(uuid: "r1", host: "old1.example"),
                                                        entityId: "srv-r1")
        store.table.cursors["r2"] = publishedRuleCursor(urlRulePayload(uuid: "r2", host: "old2.example",
                                                                       rank: "W"),
                                                        entityId: "srv-r2")
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([
            ruleEntity(urlRulePayload(uuid: "r1", host: "new1.example", contentStamp: 900), version: 7),
            ruleEntity(urlRulePayload(uuid: "r2", host: "new2.example", rank: "W", contentStamp: 900),
                       version: 8),
        ], marker: "8")]
        let engine = makeEngine(client: client, markerStore: markerStore(marker: "0"),
                                spaceStore: drainedSpaceStore(),
                                ownedKinds: [.urlRules(access: access, store: store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertEqual(applyCalls(access), 1, "一页一批")
        XCTAssertEqual(refreshCalls(access), 1, "一页一次刷新")
        XCTAssertEqual(Set(access.rows.map(\.host)), ["new1.example", "new2.example"])
    }

    /// ④ 落地整批抛错 ⇒ 零次刷新（推出去一份与库不一致的表是错的）。
    func testAFailedLandingDoesNotRefreshTheRoutingTable() async throws {
        let access = FakeURLRuleAccess(rows: [.fixture(id: "i1", syncId: "r1", host: "old.example")])
        access.failApplyOnce = true
        let store = MemoryOwnedItemStore()
        store.table.cursors["r1"] = publishedRuleCursor(urlRulePayload(uuid: "r1", host: "old.example"))
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([ruleEntity(urlRulePayload(uuid: "r1", host: "new.example",
                                                                contentStamp: 900), version: 7)],
                                     marker: "7")]
        let engine = makeEngine(client: client, markerStore: markerStore(marker: "0"),
                                spaceStore: drainedSpaceStore(),
                                ownedKinds: [.urlRules(access: access, store: store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let counters = await engine.lastOwnedRoundCountersForTesting["urlrules"]
        XCTAssertEqual(applyCalls(access), 1)
        XCTAssertEqual(refreshCalls(access), 0, "落地失败也刷新 = 推出去一份与库不一致的表")
        XCTAssertEqual(counters?.applied, 0)
        XCTAssertEqual(counters?.parked, 1, "整批停放，下一轮重试")
        XCTAssertEqual(access.rows.first?.host, "old.example")
    }

    // MARK: - CASE U-16（回声半边：一次落地不产生第二轮提交）

    /// 一页落地（内容 + rank 都变了 ⇒ `space-a` 桶整桶重排），紧接着模拟 `urlRuleChangesPublisher`
    /// 那次必然的发射 ⇒ 第二轮零 commit、零 `.apply`、`pushed == 0`、`.refreshRoutingTable` 仍是
    /// 落地那一条。
    ///
    /// 防的是什么：落地没有在同一轮写好基线（`reconciled`）的实现——回声轮会比出差异、发一条
    /// commit、对端落地、再发一次，两台设备互相自激。也钉住「引擎自己绝不在落地里调
    /// `handleLocalOwnedChange`」：回声抑制靠的是「基线已经写好 ⇒ 零 commit」（§6.5）。
    func testALandingDoesNotEchoBackAsASecondRoundCommit() async throws {
        let access = FakeURLRuleAccess(rows: [
            .fixture(id: "i1", syncId: "r1", host: "old.example", sortOrder: 0),
            .fixture(id: "i2", syncId: "r2", host: "other.example", sortOrder: 1),
        ])
        let store = MemoryOwnedItemStore()
        store.table.cursors["r1"] = publishedRuleCursor(urlRulePayload(uuid: "r1", host: "old.example",
                                                                       rank: "V"),
                                                        entityId: "srv-r1")
        store.table.cursors["r2"] = publishedRuleCursor(urlRulePayload(uuid: "r2", host: "other.example",
                                                                       rank: "W"),
                                                        entityId: "srv-r2")
        let spaceStore = drainedSpaceStore()
        try silenceOtherSections(spaceStore, defaults: defaults)
        let client = FakePhiSyncClient()
        // 改 host 且 rank 从 "V" 跳到 "X"（排到 r2 之后）⇒ 一条 .update + 一条 .move ⇒ 整桶重排。
        client.pagesByMarker = [page([ruleEntity(urlRulePayload(uuid: "r1", host: "new.example",
                                                                rank: "X", contentStamp: 900,
                                                                rankStamp: 900), version: 7)],
                                     marker: "7")]
        let engine = makeEngine(client: client, markerStore: markerStore(marker: "0"),
                                spaceStore: spaceStore,
                                ownedKinds: [.urlRules(access: access, store: store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertEqual(access.rows.first { $0.syncId == "r1" }?.host, "new.example")
        XCTAssertEqual(access.siblings(inSpaceId: "space-a").map(\.syncId), ["r2", "r1"], "整桶重排")
        XCTAssertEqual(applyCalls(access), 1)
        XCTAssertEqual(refreshCalls(access), 1)
        XCTAssertTrue(client.commits.isEmpty, "落地那一轮零 commit")

        await engine.handleLocalOwnedChange(label: "urlrules")

        let counters = await engine.lastOwnedRoundCountersForTesting["urlrules"]
        XCTAssertEqual(counters?.pushed, 0)
        XCTAssertEqual(counters?.tombstones, 0)
        XCTAssertEqual(counters?.pendingPublish, 0)
        XCTAssertTrue(client.commits.isEmpty, "回声轮零 commit")
        XCTAssertEqual(applyCalls(access), 1, "回声轮零 .apply")
        XCTAssertEqual(refreshCalls(access), 1, "刷新总数仍然是落地那一条")
    }

    // MARK: - CASE U-27（`urlrules` 计数行的字段与门）

    /// 三条行文本按 `logOwnedRounds` 的拼串规则核对：`urlrules` 行不含认领那三项与作用域那两项，
    /// 行尾依次是六个规则专属字段；`bookmarks` 行不含 `normalized=`，它的 `adopted=` 仍紧跟
    /// `tombstones=`；`pins` 行两组都不含。
    ///
    /// 防的是什么：把判据写成 `!reportsAdoption && !reportsScope` 的实现（加第六种 kind 时静默失效）；
    /// 把六项塞进 `if registration.reportsAdoption` 那一段的实现（书签行多出五个恒零字段）。
    func testTheRuleCounterLineCarriesExactlyTheSixRuleFieldsAtItsTail() {
        let rules = OwnedKindRegistration.urlRules(access: FakeURLRuleAccess(),
                                                   store: MemoryOwnedItemStore())
        let bookmarks = OwnedKindRegistration.bookmarks(access: FakeBookmarkAccess(),
                                                        store: MemoryOwnedItemStore())
        let pins = OwnedKindRegistration.pins(access: FakePinAccess(scope: .profile, account: .profile),
                                              store: MemoryOwnedItemStore())
        XCTAssertTrue(rules.reportsRuleCounters)
        XCTAssertFalse(bookmarks.reportsRuleCounters)
        XCTAssertFalse(pins.reportsRuleCounters)
        XCTAssertTrue(rules.landsEmptyBatch)
        XCTAssertFalse(bookmarks.landsEmptyBatch)
        XCTAssertFalse(pins.landsEmptyBatch)

        var counters = OwnedRoundCounters()
        counters.tombstones = 3
        counters.adopted = 2
        counters.normalized = 1
        counters.ownerMoved = 1
        let ruleLine = PhiSyncEngine.ownedRoundLogLine(rules, counters: counters)
        XCTAssertTrue(ruleLine.hasPrefix("[phi-sync] urlrules pulled="))
        XCTAssertFalse(ruleLine.contains("unmatched_folders="))
        XCTAssertFalse(ruleLine.contains("unmergeable_pairs="))
        XCTAssertFalse(ruleLine.contains("relineaged="))
        XCTAssertFalse(ruleLine.contains("scope_mismatch="))
        XCTAssertTrue(ruleLine.hasSuffix(" normalized=1 owner_moved=1 adopted=2 collapsed=0"
                                         + " transferred=0 yield_no_partner=0"), ruleLine)

        let bookmarkLine = PhiSyncEngine.ownedRoundLogLine(bookmarks, counters: counters)
        XCTAssertFalse(bookmarkLine.contains("normalized="))
        XCTAssertFalse(bookmarkLine.contains("owner_moved="))
        XCTAssertTrue(bookmarkLine.contains("tombstones=3 adopted=2 unmatched_folders=0"), bookmarkLine)
        XCTAssertTrue(bookmarkLine.hasSuffix("local_read_failed=0"), bookmarkLine)

        let pinLine = PhiSyncEngine.ownedRoundLogLine(pins, counters: counters)
        XCTAssertFalse(pinLine.contains("normalized="))
        XCTAssertFalse(pinLine.contains("adopted="))
        XCTAssertTrue(pinLine.contains("relineaged=0"))
        XCTAssertTrue(pinLine.hasSuffix("local_read_failed=0 scope_mismatch=false"), pinLine)
    }

    /// 引擎半边：一轮把规则侧的 `normalized` 与 `ownerMoved` 填出非零值（三条注册项都挂上）。
    /// `r1` 改目标 `su-1 → su-2`（一条真的 `.move`），`r9` 以未归一的 host 到达。
    func testARoundFillsNormalizedAndOwnerMovedOnTheRuleCounters() async throws {
        let access = FakeURLRuleAccess(rows: [.fixture(id: "i1", syncId: "r1", spaceId: "space-a")])
        let store = MemoryOwnedItemStore()
        store.table.cursors["r1"] = publishedRuleCursor(urlRulePayload(uuid: "r1"), entityId: "srv-r1")
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([
            ruleEntity(urlRulePayload(uuid: "r1", targetSpaceUuid: "su-2", targetStamp: 500), version: 7),
            ruleEntity(urlRulePayload(uuid: "r9", host: "Example.COM"), version: 8),
        ], marker: "8")]
        let engine = makeEngine(client: client, markerStore: markerStore(marker: "0"),
                                spaceStore: drainedSpaceStore(),
                                ownedKinds: [.bookmarks(access: FakeBookmarkAccess(),
                                                        store: MemoryOwnedItemStore()),
                                             .pins(access: FakePinAccess(scope: .profile, account: .profile),
                                                   store: MemoryOwnedItemStore()),
                                             .urlRules(access: access, store: store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let counters = await engine.lastOwnedRoundCountersForTesting
        XCTAssertEqual(counters["urlrules"]?.normalized, 1)
        XCTAssertEqual(counters["urlrules"]?.ownerMoved, 1)
        XCTAssertEqual(counters["urlrules"]?.applied, 2)
        XCTAssertEqual(counters["bookmarks"]?.normalized, 0)
        XCTAssertEqual(counters["pins"]?.ownerMoved, 0)
        XCTAssertEqual(access.rows.first { $0.syncId == "r1" }?.spaceId, "space-b", "rehome 落了")
        XCTAssertEqual(access.rows.first { $0.syncId == "r9" }?.host, "example.com", "归一后落地")
    }

    // MARK: - CASE U-28（注册次序即处理次序：规则排最后）

    /// 一页同时带书签、pin、规则各一条 ⇒ 落地写的次序是 `["bookmarks", "pins", "urlrules"]`
    /// （`RecordingSpaceStore` 在文件末尾）。
    /// `ownedKinds` 数组字面量与协调器的逐字相同；`beginOwnedRound` 与页循环那两个
    /// `for registration in ownedKinds` 都零 kind 分支（§6.2 第五种 kind 不需要任何新分支）。
    ///
    /// 防的是什么：把规则插在书签与 pin 之间的实现——B2-7b 的中止点因此不再落在「最后一条 kind」
    /// 上，那条用例会绿着漏掉唯一的跨 kind 半落地窗口。
    func testRegistrationOrderIsProcessingOrderWithRulesLast() async throws {
        let spaceStore = RecordingSpaceStore()
        spaceStore.table.hasDrainedFullReplay = true
        let bookmarkAccess = FakeBookmarkAccess()
        let pinAccess = FakePinAccess(scope: .profile, account: .profile)
        let ruleAccess = FakeURLRuleAccess()
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([
            remoteEntity(envelope(bookmarkPayload(uuid: "b1", spaceUuid: "su-1")),
                         tag: PhiSyncEntity.bookmarkClientTag("b1"), version: 7, entityId: "srv-b1", key: key),
            remoteEntity(envelope(pinPayload(lineage: "lx")),
                         tag: PhiSyncEntity.pinClientTag("lx", ownerKey: "pu-1"), version: 8,
                         entityId: "srv-lx", key: key),
            ruleEntity(urlRulePayload(uuid: "r1"), version: 9),
        ], marker: "9")]
        let bookmarkKind = OwnedKindRegistration.bookmarks(access: bookmarkAccess, store: MemoryOwnedItemStore())
        let pinKind = OwnedKindRegistration.pins(access: pinAccess, store: MemoryOwnedItemStore())
        let urlRuleKind = OwnedKindRegistration.urlRules(access: ruleAccess, store: MemoryOwnedItemStore())
        let ownedKinds = [bookmarkKind, pinKind, urlRuleKind]
        let engine = makeEngine(client: client, markerStore: markerStore(marker: "0"),
                                spaceStore: spaceStore, ownedKinds: ownedKinds)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertEqual(ownedKinds.map(\.label), ["bookmarks", "pins", "urlrules"])
        XCTAssertEqual(spaceStore.firstFlagOrder, ["bookmarks", "pins", "urlrules"])
        XCTAssertEqual(bookmarkAccess.rows.count, 1)
        XCTAssertEqual(pinAccess.rows.count, 1)
        XCTAssertEqual(ruleAccess.rows.count, 1)
    }

    // MARK: - CASE U-29（本地写 ⇒ 一轮 `.localOwnedChange`，防抖在 store 侧）

    /// 真 `LocalStore` + `urlRuleChangesPublisher(debounceWindow:)`，订阅照搬协调器那条的形状：
    /// **裸 `sink`、不加第二级防抖**，label 从注册项带过来。20 ms 内连写三条 ⇒ 恰好一次、实参
    /// `"urlrules"`；拆掉订阅并清掉 label 之后再写一条 ⇒ 零调用。
    ///
    /// 防的是什么：在协调器 sink 上再加一级 `.debounce`（两级串起来是 4 秒延迟）；订阅接
    /// `urlRulesPublisher()` 而不是 store 级兄弟（发 model 对象、按 `l.id` 去重，SwiftData 就地
    /// 刷新会吞掉真实字段编辑，§6.5 第 1 条）；teardown 漏掉第三条订阅。
    func testALocalWriteBurstYieldsOneLocalOwnedChangeAndTeardownStopsIt() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("URLRuleKindTests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        let store = LocalStore(account: Account(userID: "test-user"),
                               storeDirectoryURL: directory,
                               presentsCompatibilityAlerts: false)
        let window: TimeInterval = 0.02
        var received: [String] = []
        var label: String? = OwnedKindRegistration.urlRules(access: FakeURLRuleAccess(),
                                                            store: MemoryOwnedItemStore()).label
        var cancellable: AnyCancellable? = store.urlRuleChangesPublisher(debounceWindow: window)
            .sink { _ in
                // 协调器里这一行是 `await self?.phiSyncEngine?.handleLocalOwnedChange(label: label)`。
                if let label { received.append(label) }
            }

        for index in 0..<3 {
            try await store.applyURLRuleEditsThrowing(
                upserts: [LocalStore.URLRuleDraft(id: "u29-\(index)", host: "u29-\(index).example",
                                                  spaceId: "space-a")],
                deletedIds: [])
        }
        waitPastDebounceWindow(window)
        XCTAssertEqual(received, ["urlrules"], "三条写塌成一轮，实参是注册项的 label")

        // `stopPhiSync()`：cancel + 置 nil + label 置 nil。
        cancellable?.cancel()
        cancellable = nil
        label = nil
        try await store.applyURLRuleEditsThrowing(
            upserts: [LocalStore.URLRuleDraft(id: "u29-late", host: "late.example", spaceId: "space-a")],
            deletedIds: [])
        waitPastDebounceWindow(window)
        XCTAssertEqual(received, ["urlrules"], "teardown 之后零调用")
        XCTAssertNil(cancellable)
    }

    // MARK: - CASE U-30（`NOT_MY_BIRTHDAY` 清 `urlRulesReplayedForEmptyTable`）

    /// 换 store ⇒ 闩清掉、`urlRulesHadRecords` 仍为 true、游标的服务端三元组与 `rekeyRejectRounds`
    /// 归零而 `reconciled` 原样保留、marker 清成 nil。游标带 `deletedAtMs`（照 CASE 6.18 / 6.21 的
    /// 书签形状）：那样发布段既不会为它补键、差分也不会给它发 tombstone，断言读到的就是 reset 本身。
    ///
    /// 防的是什么：漏掉那一行的实现——换过 store 的机器此后第一次丢 `urlrules-cursors.json` 时拿不到
    /// 重放。反向：把 `urlRulesHadRecords` 也清掉、或把 `reconciled` 清掉的实现（后者当场触发账户级
    /// 盲写覆盖）。
    func testANewStoreBirthdayClearsTheRuleReplayLatchButKeepsHadRecordsAndTheBaseline() async throws {
        let access = FakeURLRuleAccess()
        let store = MemoryOwnedItemStore()
        var cursor = publishedRuleCursor(urlRulePayload(uuid: "r1"), entityId: "srv-1", version: 3)
        cursor.rekeyRejectRounds = 2
        cursor.deletedAtMs = 1_234
        store.table.cursors["r1"] = cursor
        let reconciled = cursor.reconciled
        let spaceStore = drainedSpaceStore()
        spaceStore.table.urlRulesHadRecords = true
        spaceStore.table.urlRulesReplayedForEmptyTable = true
        let client = FakePhiSyncClient()
        client.throwNotMyBirthdayOnce = true
        let markerStore = markerStore(marker: "9")
        let engine = makeEngine(client: client, markerStore: markerStore, spaceStore: spaceStore,
                                ownedKinds: [.urlRules(access: access, store: store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertFalse(spaceStore.table.urlRulesReplayedForEmptyTable)
        XCTAssertTrue(spaceStore.table.urlRulesHadRecords, "描述的是「这台机器曾经发布过」，换 store 不改变它")
        let landed = try XCTUnwrap(store.table.cursors["r1"])
        XCTAssertEqual(landed.entityId, "")
        XCTAssertEqual(landed.version, 0)
        XCTAssertNil(landed.server)
        XCTAssertNil(landed.rekeyRejectRounds)
        XCTAssertEqual(landed.reconciled, reconciled, "`reconciled` 原样保留")
        XCTAssertNil(markerStore.file.marker)
    }

    // MARK: - CASE U-31（门关 ⇒ 规则整段不跑）

    /// `spaceSectionEnabled == false`：本机两条规则（一条有未发布编辑）、一页带一条规则实体 ⇒
    /// `.gated`、规则的四个计数全 0、`access.calls` 整个为空（连 `allURLRulesIncludingDeleted()` 都
    /// 没读过）、`store.saveCalls == 0`。`logOwnedRounds` 的 `spaceSectionEnabled` 守卫让它不印任何
    /// kind 行（那一处没有测试面）。
    ///
    /// 防的是什么：把规则接在门外面的实现。规则是账户级数据，门关着还发布 = 一台没配对完的机器把
    /// 自己整套规则铸上 `syncId` 推到账户上（§6.4 第三条前置）。
    func testAShutGateSkipsTheWholeRuleSection() async throws {
        let access = FakeURLRuleAccess(rows: [
            .fixture(id: "i1", syncId: "r1", sortOrder: 0),
            .fixture(id: "i2", syncId: "r2", sortOrder: 1, pendingLocalEdit: true),
        ])
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        client.pagesByMarker = [page([ruleEntity(urlRulePayload(uuid: "r3"), version: 7)], marker: "7")]
        let engine = makeEngine(client: client, markerStore: markerStore(marker: "0"),
                                spaceStore: MemorySpaceStore(),
                                ownedKinds: [.urlRules(access: access, store: store)])
        // 门**关着**：不调 `setSpaceSyncEnabled(true)`。
        await engine.pullOnce()

        let outcome = await engine.lastRoundOutcomeForTesting
        let counters = await engine.lastOwnedRoundCountersForTesting["urlrules"]
        XCTAssertEqual(outcome, .gated)
        XCTAssertEqual(counters?.pulled ?? 0, 0)
        XCTAssertEqual(counters?.applied ?? 0, 0)
        XCTAssertEqual(counters?.pushed ?? 0, 0)
        XCTAssertEqual(counters?.tombstones ?? 0, 0)
        XCTAssertTrue(access.calls.isEmpty, "连 allURLRulesIncludingDeleted() 都没读过")
        XCTAssertEqual(store.saveCalls, 0)
        XCTAssertTrue(ruleCommits(client).isEmpty)
        XCTAssertEqual(access.rows.count, 2)
    }

    // MARK: - CASE U-11（并发改目标收敛到一条）

    /// 两台引擎 A / B 共用一个假 client（同一条已发布规则 X 的基线在两边游标里都有）。A 把 X 改到
    /// S2（`targetUpdatedDate` = 100 ms），B 把 X 改到 S3（200 ms）。A 先发布（`.applied`，v+1）；
    /// B 的第一次 commit 被脚本判 `.conflict(serverVersion: v+1)` ⇒ 限定重发**只带 X**、
    /// `base_version == v+1`、载荷目标是 S3（200 > 100）；A 随后 pull 到 X@S3 并落地 ⇒ 两台各一条
    /// 行、目标都是 S3；账户上 `phi-urlrule` 仍是一条实体；再跑两轮两台 `pushed == 0`。
    ///
    /// 防的是什么：把 `.conflict` 之后的重发写成「整表重发」或「按本机值盖过远端值」的实现：前者让
    /// `commit` 带上无关身份，后者让戳更旧的目标（S2）赢、或让两台各自留下一条 ⇒ 账户上两条实体。
    /// D33「以后更新的为准」在规则目标单元上的引擎级探针。
    func testConcurrentTargetEditsConvergeToTheNewerTargetThroughAScopedConflictRetry() async throws {
        let baseline = urlRulePayload(uuid: "x1", targetSpaceUuid: "su-1",
                                      contentStamp: 50, targetStamp: 50, rankStamp: 50)
        let client = FakePhiSyncClient()
        client.seed(tagHash: ruleHash("x1"),
                    ciphertext: try PhiEntityCodec.encrypt(envelope(baseline), key: key),
                    version: 10, entityId: "srv-x1")

        // A：X 在 space-b（su-2），目标戳 100 ms。
        let accessA = FakeURLRuleAccess(rows: [
            .fixture(id: "ia", syncId: "x1", spaceId: "space-b",
                     targetUpdatedDate: Date(timeIntervalSince1970: 0.1)),
        ])
        let storeA = MemoryOwnedItemStore()
        storeA.table.cursors["x1"] = publishedRuleCursor(baseline, entityId: "srv-x1", version: 10)
        let spaceStoreA = drainedSpaceStore()
        try silenceOtherSections(spaceStoreA, defaults: defaults)
        let engineA = makeEngine(client: client, markerStore: markerStore(marker: "10"),
                                 spaceStore: spaceStoreA,
                                 ownedKinds: [.urlRules(access: accessA, store: storeA)])
        // B：X 在 space-c（su-3），目标戳 200 ms；自己的 defaults suite 与 store。
        let defaultsB = makeExtraDefaults()
        let accessB = FakeURLRuleAccess(rows: [
            .fixture(id: "ib", syncId: "x1", spaceId: "space-c",
                     targetUpdatedDate: Date(timeIntervalSince1970: 0.2)),
        ])
        let storeB = MemoryOwnedItemStore()
        storeB.table.cursors["x1"] = publishedRuleCursor(baseline, entityId: "srv-x1", version: 10)
        let spaceStoreB = drainedSpaceStore()
        try silenceOtherSections(spaceStoreB, defaults: defaultsB)
        let engineB = makeEngine(client: client, markerStore: markerStore(marker: "10"),
                                 spaceStore: spaceStoreB, defaults: defaultsB,
                                 ownedKinds: [.urlRules(access: accessB, store: storeB)])
        await engineA.setSpaceSyncEnabled(true)
        await engineB.setSpaceSyncEnabled(true)

        // A 先发布：一条 update，base_version = v，账户上 X 变成 S2@v+1。
        await engineA.handleLocalOwnedChange(label: "urlrules")
        let commitsAfterA = ruleCommits(client)
        XCTAssertEqual(commitsAfterA.count, 1)
        XCTAssertEqual(commitsAfterA.first?.baseVersion, 10)
        XCTAssertEqual(committedRule(commitsAfterA[0])?.targetSpaceUuid.stringValue, "su-2")
        let serverAfterA = try XCTUnwrap(client.stored[ruleHash("x1")]?.version)
        XCTAssertGreaterThan(serverAfterA, 10)

        // B：拉到 A 的 X@S2 ⇒ 目标 LWW 让 S3（200）赢、本机赢了字段 ⇒ 必须重新发布；第一次 commit
        // 被判 `.conflict` ⇒ 一次 pull + 限定到 X 的重发。
        client.conflictOnceForTagHashes = [ruleHash("x1")]
        await engineB.handleLocalOwnedChange(label: "urlrules")
        let commitsB = Array(ruleCommits(client).dropFirst())
        XCTAssertEqual(commitsB.count, 2, "一次冲突 + 一次限定重发")
        XCTAssertEqual(commitsB.map(\.clientTagHash), [ruleHash("x1"), ruleHash("x1")], "限定重发只带 X")
        XCTAssertEqual(commitsB.last?.baseVersion, serverAfterA, "base_version == v+1")
        let republished = try XCTUnwrap(commitsB.last.flatMap(committedRule))
        XCTAssertEqual(republished.targetSpaceUuid.stringValue, "su-3", "200 > 100 ⇒ S3 赢")
        XCTAssertEqual(republished.targetSpaceUuid.updatedAtMs, 200)
        let fromA = try XCTUnwrap(committedRule(commitsAfterA[0]))
        XCTAssertEqual(URLRuleKind.contentSignature(of: republished), URLRuleKind.contentSignature(of: fromA),
                       "内容组与 A 的相同")
        let countersB = await engineB.lastOwnedRoundCountersForTesting["urlrules"]
        XCTAssertEqual(countersB?.pendingPublish, 0)
        XCTAssertEqual(accessB.rows.count, 1)
        XCTAssertEqual(accessB.rows.first?.spaceId, "space-c")

        // A 随后 pull 到 X@S3 并落地：一条 `.move`，行搬到 space-c。
        await engineA.pullOnce()
        let countersA = await engineA.lastOwnedRoundCountersForTesting["urlrules"]
        XCTAssertEqual(countersA?.ownerMoved, 1)
        XCTAssertEqual(accessA.rows.count, 1)
        XCTAssertEqual(accessA.rows.first?.spaceId, "space-c")
        XCTAssertEqual(accessA.rows.first?.id, "ia", "rehome 保留物理行")
        XCTAssertEqual(ruleCommits(client).count, 3, "A 落地之后零新 commit")
        XCTAssertTrue(ruleCommits(client).allSatisfy { $0.clientTagHash == ruleHash("x1") },
                      "账户上仍是一条实体")

        // 再跑两轮：两台都零 push、零 tombstone，commit 总数不变。
        for _ in 0..<2 {
            await engineA.pullOnce()
            await engineB.pullOnce()
            let a = await engineA.lastOwnedRoundCountersForTesting["urlrules"]
            let b = await engineB.lastOwnedRoundCountersForTesting["urlrules"]
            XCTAssertEqual(a?.pushed, 0)
            XCTAssertEqual(a?.tombstones, 0)
            XCTAssertEqual(b?.pushed, 0)
            XCTAssertEqual(b?.tombstones, 0)
        }
        XCTAssertEqual(ruleCommits(client).count, 3)
        XCTAssertEqual(accessA.rows.first?.spaceId, "space-c")
        XCTAssertEqual(accessB.rows.first?.spaceId, "space-c")
    }

    // MARK: - Task 9：生命周期——脚手架

    private static let dayMs: Int64 = 24 * 60 * 60 * 1000

    private func spaceHash(_ uuid: String) -> String {
        PhiSyncEntity.clientTagHash(for: PhiSyncEntity.spaceClientTag(uuid))
    }

    /// 一条**远端软删**的 Space 游标——一条 Space tombstone 落地之后留下的形状：`hidden` 与
    /// `deletedAtMs` 同在（Space 侧的不变量），映射**保留**（R-D6-10）。
    private func hiddenSpaceCursor(deletedAtMs: Int64) -> PhiSpaceCursor {
        var cursor = PhiSpaceCursor()
        cursor.entityId = "srv-space-1"
        cursor.version = 4
        cursor.hidden = true
        cursor.deletedAtMs = deletedAtMs
        return cursor
    }

    /// 账户上真有这条实体：假 client 的更新路径要 `stored[hash].entityId == entry.entityId` 且
    /// `version == baseVersion`，否则一条 tombstone 会被判 `invalidMessage`。id 与
    /// `publishedRuleCursor(_:entityId: "srv-<uuid>")` 对齐。
    private func seedPublished(_ client: FakePhiSyncClient, uuid: String, version: Int64 = 1) {
        client.seed(tagHash: ruleHash(uuid), ciphertext: Data(), version: version,
                    entityId: "srv-\(uuid)")
    }

    private func ruleTombstones(_ client: FakePhiSyncClient) -> [FakePhiSyncClient.CommitCall] {
        ruleCommits(client).filter(\.deleted)
    }

    private struct LifecycleFixture {
        let access: FakeURLRuleAccess
        let store: MemoryOwnedItemStore
        let spaceStore: MemorySpaceStore
        let spaceAccess: FakePhiSpaceAccess
        let client: FakePhiSyncClient
        let markerStore: MemoryMarkerStore
    }

    private static let deletedSpaceRules: [(uuid: String, host: String, rank: String)] = [
        ("r1", "a.example", "V"), ("r2", "b.example", "W"), ("r3", "c.example", "X"),
    ]

    /// Space S（`space-a` → `su-1`）的三条已发布规则。`rowsDeleted` = 用户在本机删了 S：
    /// `SpaceModel` 行没了（`isEligibleSpace("su-1")` 假）、映射还在（`localSpaceId("su-1")` 非
    /// nil）、三条规则行软删（Task 5 的 `deleteSpaceCascade(origin: .userIntent)` 留下的形状，
    /// 本任务只消费）。`published == false` = 三条游标从没上过账户（`reconciled == nil`）。
    private func makeDeletedSpaceFixture(rowsDeleted: Bool = true,
                                         published: Bool = true) throws -> LifecycleFixture {
        let deletedDate: Date? = rowsDeleted ? Date(timeIntervalSince1970: 2_000) : nil
        let rows = Self.deletedSpaceRules.enumerated().map { index, rule in
            PhiLocalURLRule.fixture(id: "i\(index + 1)", syncId: rule.uuid, host: rule.host,
                                    sortOrder: index, deletedDate: deletedDate)
        }
        let access = FakeURLRuleAccess(rows: rows)
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        for rule in Self.deletedSpaceRules {
            if published {
                store.table.cursors[rule.uuid] = publishedRuleCursor(
                    urlRulePayload(uuid: rule.uuid, host: rule.host, rank: rule.rank),
                    entityId: "srv-\(rule.uuid)")
                seedPublished(client, uuid: rule.uuid)
            } else {
                store.table.cursors[rule.uuid] = ownedCursor(ownerUuid: "su-1")
            }
        }
        let spaceStore = drainedSpaceStore()
        try silenceOtherSections(spaceStore, defaults: defaults)
        let spaceAccess = makeSpaceAccess()
        // 用户删了 S：行没了、映射还在。
        spaceAccess.spaces.removeAll { $0.spaceId == "space-a" }
        return LifecycleFixture(access: access, store: store, spaceStore: spaceStore,
                                spaceAccess: spaceAccess, client: client,
                                markerStore: markerStore(marker: "9"))
    }

    private func makeLifecycleEngine(_ f: LifecycleFixture, clock: Clock? = nil) -> PhiSyncEngine {
        makeEngine(client: f.client, markerStore: f.markerStore, spaceStore: f.spaceStore,
                   spaceAccess: f.spaceAccess, clock: clock,
                   ownedKinds: [.urlRules(access: f.access, store: f.store)])
    }

    // MARK: - CASE U-12（Space 软删 / purge 期间不发 tombstone）

    /// 两条活行的目标 Space `su-1` 的游标 hidden（或 purged）、映射仍在 ⇒ 一轮之后零 tombstone、
    /// 两条游标 `pendingDelete == false`、`deleteDecidedAtMs` 未写。
    ///
    /// 防的是什么：跟随端替删除方发 tombstone。**这条的正确实现不靠归属门**：`locals` 不做归属
    /// 过滤、`identity(of local:)` 恒交 `syncId`，于是这两行进 `liveIdentities`、判据 3 就把它们
    /// 挡住了。把「hidden ⇒ 从 `locals` 里过滤掉」写进闭包的实现会让判据 3 失效，此时只剩合格门
    /// 在救——而 purge 那一格已经把映射删掉，两道门的方向不同，迟早漏一格。
    private func assertNoFollowerTombstone(spaceCursor: PhiSpaceCursor, _ label: String) async throws {
        let access = FakeURLRuleAccess(rows: [
            .fixture(id: "i1", syncId: "r1", sortOrder: 0),
            .fixture(id: "i2", syncId: "r2", host: "other.example", sortOrder: 1),
        ])
        let store = MemoryOwnedItemStore()
        store.table.cursors["r1"] = publishedRuleCursor(urlRulePayload(uuid: "r1"), entityId: "srv-r1")
        store.table.cursors["r2"] = publishedRuleCursor(urlRulePayload(uuid: "r2", host: "other.example",
                                                                       rank: "W"),
                                                        entityId: "srv-r2")
        let spaceStore = drainedSpaceStore()
        try silenceOtherSections(spaceStore, defaults: defaults)
        spaceStore.table.cursors["su-1"] = spaceCursor
        let client = FakePhiSyncClient()
        seedPublished(client, uuid: "r1")
        seedPublished(client, uuid: "r2")
        // 映射仍在：`makeSpaceAccess()` 默认就带 `space-a → su-1`。
        let engine = makeEngine(client: client, markerStore: markerStore(marker: "9"),
                                spaceStore: spaceStore,
                                ownedKinds: [.urlRules(access: access, store: store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let counters = await engine.lastOwnedRoundCountersForTesting["urlrules"]
        XCTAssertEqual(counters?.tombstones, 0, "\(label)：跟随端零 tombstone")
        XCTAssertTrue(ruleTombstones(client).isEmpty, "\(label)：commit 里零条规则 tombstone")
        for identity in ["r1", "r2"] {
            XCTAssertEqual(store.table.cursors[identity]?.pendingDelete, false, label)
            XCTAssertEqual(store.table.cursors[identity]?.deleteDecidedAtMs, 0, "\(label)：删除决定没写")
        }
        XCTAssertEqual(access.rows.count, 2, "\(label)：两条行都还在")
        XCTAssertTrue(access.hardDeleteCalls.isEmpty, label)
    }

    func testAHiddenTargetSpaceNeverYieldsAFollowerTombstone() async throws {
        try await assertNoFollowerTombstone(spaceCursor: hiddenSpaceCursor(deletedAtMs: Self.now),
                                            "hidden")
    }

    func testAPurgedTargetSpaceNeverYieldsAFollowerTombstone() async throws {
        try await assertNoFollowerTombstone(spaceCursor: purgedSpaceCursor(), "purged")
    }

    // MARK: - CASE U-13（本地删 Space ⇒ 软删规则 ⇒ 起源 (b) 发 tombstone）——引擎半边

    /// 用户在本机删了 S：`isEligibleSpace("su-1")` 假、`localSpaceId("su-1")` 非 nil、三行软删 ⇒
    /// 一轮之后恰好三条规则 tombstone（`clientTagHash` 对得上）、`tombstones == 3`、`pushed == 0`、
    /// 删除决定只写一次、`.applied` 之后三条软删行被出路 1 硬删。
    ///
    /// 防的是什么（MOD-2 / R-M3-4a-78）：**(a') 只有起源 (a)**（不实现 `explicitDeletions`）⇒ 合格门
    /// 逐条 `continue` ⇒ `tombstones == 0`，账户上那三条实体成为**任何设备都删不掉**的孤儿（主探针）；
    /// **(a'') 把软删改回 `context.delete`** ⇒ 行没了、`deletedDate` 无从谈起、两个起源都看不见它 ⇒
    /// 同样 0。
    func testALocallyDeletedSpaceSendsOneTombstonePerSoftDeletedRuleAndHardDeletesTheRows() async throws {
        let f = try makeDeletedSpaceFixture()
        let engine = makeLifecycleEngine(f)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let tombstones = ruleTombstones(f.client)
        XCTAssertEqual(tombstones.count, 3, "① 恰好三条规则 tombstone")
        XCTAssertEqual(Set(tombstones.map(\.clientTagHash)), Set(["r1", "r2", "r3"].map(ruleHash)),
                       "① clientTagHash 对得上那三个 syncId")
        XCTAssertEqual(ruleCommits(f.client).count, 3, "① tombstone 之外零条规则 commit")
        let counters = await engine.lastOwnedRoundCountersForTesting["urlrules"]
        XCTAssertEqual(counters?.tombstones, 3, "②")
        XCTAssertEqual(counters?.pushed, 0, "④ 软删行不进 snapshot")
        for identity in ["r1", "r2", "r3"] {
            let cursor = try XCTUnwrap(f.store.table.cursors[identity])
            XCTAssertEqual(cursor.deleteDecidedAtMs, Self.now, "③ 删除决定的时刻写了")
            XCTAssertFalse(cursor.pendingDelete, "③ .applied 之后收尾")
            XCTAssertNotNil(cursor.deletedAtMs)
            XCTAssertNil(cursor.reconciled)
        }
        XCTAssertTrue(f.access.rows.isEmpty, "⑤ 出路 1：.applied 之后三条软删行没了")
        XCTAssertEqual(f.access.hardDeleteCalls, ["r1", "r2", "r3"], "⑤ 恰好那三个 syncId")

        // 第二轮重跑：删除决定的时刻**只写一次**，不再发第二批。
        await engine.pullOnce()
        XCTAssertEqual(ruleTombstones(f.client).count, 3)
        for identity in ["r1", "r2", "r3"] {
            XCTAssertEqual(f.store.table.cursors[identity]?.deleteDecidedAtMs, Self.now, "③ 第二轮值不变")
        }
        XCTAssertEqual(f.access.hardDeleteCalls.count, 3, "第二轮不再硬删")
    }

    /// U-13 的跟随端变体：同一个 Space 没了（行不在 `currentSpaces()`、映射还在），但本机**零删除
    /// 动作**——三行 `deletedDate == nil` ⇒ `tombstones == 0`：起源 (b) 的入口就是 `deletedDate != nil`，
    /// 跟随端保护逐字不变。
    func testAFollowerWithLiveRowsSendsNoTombstoneForAnIneligibleSpace() async throws {
        let f = try makeDeletedSpaceFixture(rowsDeleted: false)
        let engine = makeLifecycleEngine(f)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let counters = await engine.lastOwnedRoundCountersForTesting["urlrules"]
        XCTAssertEqual(counters?.tombstones, 0)
        XCTAssertTrue(ruleTombstones(f.client).isEmpty)
        XCTAssertEqual(f.access.rows.count, 3, "三行都在")
        XCTAssertTrue(f.access.rows.allSatisfy { $0.deletedDate == nil })
        XCTAssertTrue(f.access.hardDeleteCalls.isEmpty)
        for identity in ["r1", "r2", "r3"] {
            XCTAssertEqual(f.store.table.cursors[identity]?.pendingDelete, false)
        }
    }

    /// U-13 的 `reconciled == nil` 变体：三行软删，但游标从没上过账户 ⇒ `tombstones == 0`——起源 (b)
    /// 要求账户上真有这条实体，判据 1 不跳；软删行也不被出路 1 碰（没有 `.applied`）。
    func testASoftDeletedRuleThatNeverReachedTheAccountSendsNoTombstone() async throws {
        let f = try makeDeletedSpaceFixture(published: false)
        let engine = makeLifecycleEngine(f)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let counters = await engine.lastOwnedRoundCountersForTesting["urlrules"]
        XCTAssertEqual(counters?.tombstones, 0)
        XCTAssertTrue(ruleCommits(f.client).isEmpty, "零条规则 commit")
        XCTAssertEqual(f.access.rows.count, 3, "软删行原样躺着，交给出路 2")
        XCTAssertTrue(f.access.hardDeleteCalls.isEmpty)
    }

    /// RR-B6 的重启探针：差分产出与 tombstone `.applied` 之间换一个引擎（同一个 `FakeURLRuleAccess`
    /// 与 store）⇒ 三条软删行**仍在**、删除意图不丢，新引擎那一轮照常发出三条并硬删。第一轮的
    /// commit 抛一个普通错误（既不是 conflict 也不是 NOT_MY_BIRTHDAY）模拟「发出去之前进程没了」。
    ///
    /// 防的是什么：把删除意图只写进游标表的那一版——意图在行上（`deletedDate`），游标表只是它的
    /// 投影，重启之后由行重新算出来。
    func testTheDeletionIntentSurvivesARestartBetweenTheDiffAndTheApplied() async throws {
        struct Boom: Error {}
        let f = try makeDeletedSpaceFixture()
        f.client.commitErrorOnce = Boom()
        let first = makeLifecycleEngine(f)
        await first.setSpaceSyncEnabled(true)
        await first.pullOnce()

        XCTAssertEqual(f.access.rows.count, 3, "第一轮没有 .applied ⇒ 三条软删行仍在")
        XCTAssertTrue(f.access.rows.allSatisfy { $0.deletedDate != nil })
        XCTAssertTrue(f.access.hardDeleteCalls.isEmpty, "没有 .applied 就没有出路 1")
        for identity in ["r1", "r2", "r3"] {
            XCTAssertEqual(f.store.table.cursors[identity]?.pendingDelete, true, "删除决定已经落盘")
            XCTAssertEqual(f.store.table.cursors[identity]?.deleteDecidedAtMs, Self.now)
            XCTAssertNil(f.store.table.cursors[identity]?.deletedAtMs)
        }
        first.shutdown()

        let second = makeLifecycleEngine(f)
        await second.setSpaceSyncEnabled(true)
        await second.pullOnce()

        let counters = await second.lastOwnedRoundCountersForTesting["urlrules"]
        XCTAssertEqual(counters?.tombstones, 3, "新引擎那一轮把三条发出去")
        XCTAssertTrue(f.access.rows.isEmpty, "出路 1 在 .applied 之后硬删")
        XCTAssertEqual(f.access.hardDeleteCalls, ["r1", "r2", "r3"])
        for identity in ["r1", "r2", "r3"] {
            XCTAssertEqual(f.store.table.cursors[identity]?.deleteDecidedAtMs, Self.now, "只写一次")
            XCTAssertNotNil(f.store.table.cursors[identity]?.deletedAtMs)
        }
    }

    // MARK: - CASE U-13b（跟随端不替删除方发 tombstone，且不删行）

    /// 跟随端：三条规则行活着、游标有 `reconciled`；一页里 S 的 Space tombstone 与三条规则的更新一起
    /// 到达。Space 段先落（`su-1` hidden）⇒ 规则段的三条更新目标不合格 ⇒ 停放。
    private func makeFollowerFixture() throws -> LifecycleFixture {
        let f = try makeDeletedSpaceFixture(rowsDeleted: false)
        // 跟随端的 Space 行还在（远端软删只 hide，不删行）。
        f.spaceAccess.spaces = makeSpaceAccess().spaces
        // `su-1` 已经落过地：tombstone 按 hash 认到这条游标。**不静默它**（`silenceOtherSections` 只
        // 挡 commit，但这里要它的 Space 段照常落地并保持形状干净）。
        var spaceCursor = PhiSpaceCursor()
        spaceCursor.entityId = "srv-space-1"
        spaceCursor.version = 4
        spaceCursor.reconciled = try spacePayload(uuid: "su-1").serializedData()
        spaceCursor.server = spaceCursor.reconciled
        f.spaceStore.table.cursors["su-1"] = spaceCursor
        f.spaceStore.table.unreadableTagHashes.removeValue(forKey: spaceHash("su-1"))
        var firstPage: [PhiRemoteEntity] = [
            remoteTombstone(tag: PhiSyncEntity.spaceClientTag("su-1"), version: 10,
                            entityId: "srv-space-1"),
        ]
        for (index, rule) in Self.deletedSpaceRules.enumerated() {
            firstPage.append(ruleEntity(urlRulePayload(uuid: rule.uuid, host: "new-\(rule.host)",
                                                       rank: rule.rank, contentStamp: 900),
                                        version: Int64(11 + index)))
        }
        f.client.pagesByMarker = [page(firstPage, marker: "13")]
        return f
    }

    /// 第一轮：三行都在、`deletedDate` 仍是 nil、`tombstones == 0`、三条规则游标 `pendingApply` 非 nil。
    /// 第二轮（三条规则各自的 tombstone）：三行**被硬删**（入站 tombstone 是硬删，R-M3-4a-41）、
    /// `applied == 3`。
    ///
    /// 防的是什么：「Space tombstone 隐含规则删除」这条推论。实现成级联软删的版本会让跟随端替删除方
    /// 再发一遍 tombstone（本机行软删 ⇒ 起源 (b) 成立）。
    func testAFollowerParksTheRulesOfASoftDeletedSpaceAndOnlyDeletesOnTheirOwnTombstones() async throws {
        let f = try makeFollowerFixture()
        var secondPage: [PhiRemoteEntity] = []
        for (index, rule) in Self.deletedSpaceRules.enumerated() {
            secondPage.append(remoteTombstone(tag: ruleTag(rule.uuid), version: Int64(20 + index),
                                              entityId: "srv-\(rule.uuid)"))
        }
        f.client.pagesByMarker.append(page(secondPage, marker: "22"))
        let engine = makeLifecycleEngine(f)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertEqual(f.spaceStore.table.cursors["su-1"]?.hidden, true, "Space tombstone 落地")
        XCTAssertEqual(f.access.rows.count, 3, "第一轮：三行都在")
        XCTAssertTrue(f.access.rows.allSatisfy { $0.deletedDate == nil }, "第一轮：不软删")
        let first = await engine.lastOwnedRoundCountersForTesting["urlrules"]
        XCTAssertEqual(first?.tombstones, 0, "第一轮：跟随端零 tombstone")
        XCTAssertTrue(ruleTombstones(f.client).isEmpty)
        for identity in ["r1", "r2", "r3"] {
            XCTAssertNotNil(f.store.table.cursors[identity]?.pendingApply, "第一轮：目标不合格 ⇒ 停放")
        }
        XCTAssertTrue(f.access.hardDeleteCalls.isEmpty)

        await engine.pullOnce()

        XCTAssertTrue(f.access.rows.isEmpty, "第二轮：三行被入站 tombstone 硬删")
        let second = await engine.lastOwnedRoundCountersForTesting["urlrules"]
        XCTAssertEqual(second?.applied, 3)
        XCTAssertEqual(second?.tombstones, 0, "仍然没有本机发出的 tombstone")
        XCTAssertTrue(ruleTombstones(f.client).isEmpty)
        for identity in ["r1", "r2", "r3"] {
            XCTAssertNotNil(f.store.table.cursors[identity]?.deletedAtMs)
        }
    }

    /// U-13b 的撤销变体：第一轮之后不送规则 tombstone，改让 `su-1` 的 Space 游标从 hidden 回到活着 ⇒
    /// 第二轮那三条停放的规则**重新解析得出目标并落地**（内容更新写进行）、行仍在、`tombstones == 0`。
    ///
    /// 防的是什么：级联软删的版本连「30 天内的撤销把停放的那些救回来」这条路径也一起没了。
    func testUnhidingTheSpaceLandsTheParkedRulesInsteadOfDeletingThem() async throws {
        let f = try makeFollowerFixture()
        let engine = makeLifecycleEngine(f)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()
        XCTAssertEqual(f.access.rows.count, 3)
        XCTAssertNotNil(f.store.table.cursors["r1"]?.pendingApply)

        // 撤销：S 回到活着（一条复活的 Space 实体落地之后留下的形状）。
        f.spaceStore.table.cursors["su-1"]?.hidden = false
        f.spaceStore.table.cursors["su-1"]?.deletedAtMs = nil
        await engine.pullOnce()

        XCTAssertEqual(f.access.rows.count, 3, "行仍在")
        XCTAssertTrue(f.access.rows.allSatisfy { $0.deletedDate == nil })
        XCTAssertEqual(Set(f.access.rows.map(\.host)),
                       Set(Self.deletedSpaceRules.map { "new-\($0.host)" }),
                       "停放的三条内容更新落地了")
        let counters = await engine.lastOwnedRoundCountersForTesting["urlrules"]
        XCTAssertEqual(counters?.tombstones, 0)
        XCTAssertEqual(counters?.applied, 3)
        XCTAssertTrue(ruleTombstones(f.client).isEmpty)
        for identity in ["r1", "r2", "r3"] {
            XCTAssertNil(f.store.table.cursors[identity]?.pendingApply, "停放解除")
        }
        XCTAssertTrue(f.access.hardDeleteCalls.isEmpty)
    }

    // MARK: - CASE U-13c（purge 不是删除意图）——引擎半边

    /// §5.7 的可达场景：X 已在本机落地于 S_old（`su-1`）；账户把 X 改到 S_new（`su-new`），本机
    /// S_new 未映射 ⇒ X 停放；S_old 的 Space 游标 hidden 且过了 30 天窗口。Task 5 的 purge 级联已经把
    /// X 的本机行**硬删**（store 半边，本任务只消费：行不存在、`deletedDate` 无从谈起）。
    ///
    /// ① `runRetentionSweep()`：S_old 被 purge、映射被删；X 的游标**仍在**且 `pendingApply` /
    /// `reconciled` / `(entityId, version)` 都在、`ownerUuid` 不刷（R-M3-4a-27 的豁免）。
    /// ② 一整轮发布段：零 tombstone。
    /// ③ 给 S_new 建映射：X 按 R-M3-4a-42(a)「行不存在 ⇒ 按载荷建行」落地于 S_new、账户上 X 仍存活。
    ///
    /// 防的是什么：**把 purge 写成软删** ⇒ X 行带上 `deletedDate` ⇒ 起源 (b) 成立、绕过两道归属门 ⇒
    /// `tombstones == 1` ⇒ 账户上 X@S_new 被删掉；**不做停放豁免** ⇒ `removeValue` 连载荷带三元组丢掉
    /// 整条游标，共享 marker 早已推过那一页 ⇒ 那次改目标永不重投，③ 永远不会发生；**豁免时顺手刷
    /// `ownerUuid`** ⇒ 差分读到一条本机从没成立过的归属。对照：同一个 Space 换成用户在本机删除 ⇒
    /// CASE U-13 的三条 tombstone 照常发出。
    func testARetentionPurgeKeepsTheParkedTargetChangeAndSendsNoTombstone() async throws {
        let clock = Clock()
        let payloadOld = urlRulePayload(uuid: "r-x", targetSpaceUuid: "su-1")
        let payloadNew = urlRulePayload(uuid: "r-x", targetSpaceUuid: "su-new", targetStamp: 900)
        let access = FakeURLRuleAccess(rows: [])
        let store = MemoryOwnedItemStore()
        var cursor = publishedRuleCursor(payloadOld, entityId: "srv-r-x", version: 3)
        cursor.pendingApply = baselineBytes(payloadNew)
        cursor.pendingOwnerUuid = "su-new"
        store.table.cursors["r-x"] = cursor
        let spaceStore = drainedSpaceStore()
        try silenceOtherSections(spaceStore, defaults: defaults)
        spaceStore.table.cursors["su-1"] =
            hiddenSpaceCursor(deletedAtMs: clock.nowMs - PhiSpaceSyncState.retentionMs - 1)
        let spaceAccess = makeSpaceAccess()
        let client = FakePhiSyncClient()
        seedPublished(client, uuid: "r-x", version: 3)
        let engine = makeEngine(client: client, markerStore: markerStore(marker: "9"),
                                spaceStore: spaceStore, spaceAccess: spaceAccess, clock: clock,
                                ownedKinds: [.urlRules(access: access, store: store)])
        await engine.setSpaceSyncEnabled(true)

        // ①
        await engine.runRetentionSweep()
        XCTAssertTrue(spaceAccess.calls.contains(.purge("space-a")), "① S_old 被 purge")
        XCTAssertNil(spaceAccess.spaceMappings["space-a"], "① su-old 的映射被 dropSpaceMapping 删掉")
        XCTAssertNotNil(spaceStore.table.cursors["su-1"]?.purgedAtMs)
        XCTAssertTrue(access.rows.isEmpty, "① X 的本机行不存在（硬删）")
        let kept = try XCTUnwrap(store.table.cursors["r-x"], "① 豁免：游标仍在")
        XCTAssertEqual(kept.pendingApply, baselineBytes(payloadNew), "① 载荷仍在")
        XCTAssertEqual(kept.reconciled, baselineBytes(payloadOld))
        XCTAssertEqual(kept.entityId, "srv-r-x")
        XCTAssertEqual(kept.version, 3)
        XCTAssertEqual(kept.ownerUuid, "su-1", "① 豁免不刷 ownerUuid")
        let sweep = await engine.lastOwnedRoundCountersForTesting["urlrules"]
        XCTAssertEqual(sweep?.rehomedCursors ?? 0, 0)

        // ②
        await engine.pullOnce()
        let published = await engine.lastOwnedRoundCountersForTesting["urlrules"]
        XCTAssertEqual(published?.tombstones, 0, "② purge 不是删除意图")
        XCTAssertTrue(ruleTombstones(client).isEmpty, "② 零条规则 tombstone")
        XCTAssertNotNil(store.table.cursors["r-x"]?.pendingApply, "② 仍停放")
        XCTAssertEqual(store.table.cursors["r-x"]?.pendingDelete, false)

        // ③
        try spaceAccess.mapSpace("space-d", toSyncUuid: "su-new")
        spaceAccess.spaces.append(PhiLocalSpace(spaceId: "space-d", profileId: "Default", name: "S",
                                                colorHex: "#3A6FF8", iconName: "emoji:1F4BC",
                                                sortOrder: 3, createdDate: Date(timeIntervalSince1970: 1),
                                                themeId: nil, opacityLight: nil, opacityDark: nil))
        await engine.pullOnce()
        let landed = await engine.lastOwnedRoundCountersForTesting["urlrules"]
        XCTAssertEqual(landed?.applied, 1, "③ 停放的改目标落地")
        XCTAssertEqual(access.rows.count, 1, "③ 行不存在 ⇒ 按载荷建行")
        XCTAssertEqual(access.rows.first?.syncId, "r-x")
        XCTAssertEqual(access.rows.first?.spaceId, "space-d", "③ 落在 S_new")
        XCTAssertNil(store.table.cursors["r-x"]?.pendingApply)
        XCTAssertEqual(landed?.tombstones, 0)
        XCTAssertTrue(ruleTombstones(client).isEmpty)
        XCTAssertEqual(client.stored[ruleHash("r-x")]?.deleted, false, "③ 账户上 X 仍是一条存活实体")
    }

    // MARK: - CASE U-20（保留期级联的两条 fail-safe）

    /// `su-1` 已 purge。(a) 已发布规则 `r-a` 的目标是一个过期的 incognito 运行期 id
    /// （`eligibilityOwner` 交 nil，R-M3-4a-8），活行还在、游标 `ownerUuid == "su-1"`；`liveOwners` 把
    /// 它放进 `claimed`、`owners` 留空。(b) 游标 `r-b` 带 `pendingApply`（停放中的改目标）、
    /// `ownerUuid == "su-1"`、本机没有对应行。两次清理之后：(a) 游标不丢、`ownerUuid` 仍是 `su-1`、
    /// `rehomedCursors == 0`、下一轮 `tombstones == 0`；(b) 游标保留，载荷与三元组都在。
    ///
    /// 防的是什么：无条件 `removeValue`。(a) 缺 `liveOwners` 的身份粒度 fail-safe ⇒ 一整类
    /// `eligibilityOwner == nil` 的**活行**的游标被删光 ⇒ 那些行此后被差分判成从未发布过，用
    /// `baseVersion == 0` 的 create 盲写覆盖账户上那条。(b) 缺停放豁免 ⇒ U-13c 那条永不重投的链。
    func testTheRetentionCascadeKeepsUnresolvableLiveRowsAndParkedCursors() async throws {
        let staleIncognitoTarget = SpaceManager.incognitoRuleTargetId + ".stale-runtime"
        XCTAssertFalse(SpaceManager.isRoutableRuleTarget(staleIncognitoTarget))
        let access = FakeURLRuleAccess(rows: [
            .fixture(id: "i1", syncId: "r-a", spaceId: staleIncognitoTarget, sortOrder: 0),
        ])
        let store = MemoryOwnedItemStore()
        store.table.cursors["r-a"] = publishedRuleCursor(urlRulePayload(uuid: "r-a"), entityId: "srv-r-a")
        var parked = publishedRuleCursor(urlRulePayload(uuid: "r-b"), entityId: "srv-r-b")
        parked.pendingApply = baselineBytes(urlRulePayload(uuid: "r-b", targetSpaceUuid: "su-unmapped",
                                                           targetStamp: 900))
        parked.pendingOwnerUuid = "su-unmapped"
        store.table.cursors["r-b"] = parked
        let spaceStore = drainedSpaceStore()
        try silenceOtherSections(spaceStore, defaults: defaults)
        spaceStore.table.cursors["su-1"] = purgedSpaceCursor()
        let client = FakePhiSyncClient()
        seedPublished(client, uuid: "r-a")
        seedPublished(client, uuid: "r-b")
        let engine = makeEngine(client: client, markerStore: markerStore(marker: "9"),
                                spaceStore: spaceStore,
                                ownedKinds: [.urlRules(access: access, store: store)])
        await engine.setSpaceSyncEnabled(true)

        for pass in 1...2 {
            await engine.runRetentionSweep()
            let table = await engine.ownedTableForTesting("urlrules")
            let counters = await engine.lastOwnedRoundCountersForTesting["urlrules"]
            let live = try XCTUnwrap(table.cursors["r-a"], "(a) 第 \(pass) 趟：活行的游标不被丢弃")
            XCTAssertEqual(live.ownerUuid, "su-1", "(a) 解析不出就不改写")
            XCTAssertEqual(live.entityId, "srv-r-a")
            XCTAssertEqual(counters?.rehomedCursors ?? 0, 0, "(a) 零 rehome")
            let held = try XCTUnwrap(table.cursors["r-b"], "(b) 第 \(pass) 趟：停放的游标保留")
            XCTAssertNotNil(held.pendingApply, "(b) 载荷在")
            XCTAssertEqual(held.entityId, "srv-r-b")
            XCTAssertEqual(held.version, 1, "(b) 已收割的三元组在")
            XCTAssertEqual(held.ownerUuid, "su-1", "(b) 不刷 ownerUuid")
            XCTAssertEqual(store.table.cursors.count, 2, "落盘的表同样两条")
        }

        await engine.pullOnce()
        let counters = await engine.lastOwnedRoundCountersForTesting["urlrules"]
        XCTAssertEqual(counters?.tombstones, 0, "(a) 活行进 liveIdentities；(b) 归属不合格 ⇒ 都不发")
        XCTAssertTrue(ruleTombstones(client).isEmpty)
        XCTAssertEqual(access.rows.count, 1)
    }

    // MARK: - CASE U-22（编辑器删一行 ⇒ 一条 tombstone ⇒ 行硬删）——tombstone 半边

    /// 同一个桶里三条已发布规则，目标合格；`r2` 已被编辑器软删（Task 11 的写路径，本任务只消费状态）
    /// 并带着一个非 nil 的 `mergePartnerSyncId` ⇒ 一轮之后 `tombstones == 1`（身份 `r2`）、另外两条零
    /// commit、`.applied` 之后 `r2` 的行没了（出路 1）、游标 `deletedAtMs` 非 nil、`mergePartnerSyncId`
    /// 随行一起消失。
    ///
    /// 防的是什么：出路 1 缺席 ⇒ 那条软删行在盘上躺 30 天，而它已经不在任何读口里。**这一格同时是
    /// 起源 (a) 的正面证据**：`r2` 的归属合格，两道门都过，它不需要 `explicitDeletions` 就发得出去；
    /// 把 (b) 写成「顶掉 (a)」的实现在这里不会红，所以 U-13 与本条必须成对存在。
    func testAnEditorDeletionSendsOneTombstoneAndHardDeletesTheRowWithItsMergePartner() async throws {
        let access = FakeURLRuleAccess(rows: [
            .fixture(id: "i1", syncId: "r1", host: "a.example", sortOrder: 0),
            .fixture(id: "i2", syncId: "r2", host: "b.example", sortOrder: 1,
                     deletedDate: Date(timeIntervalSince1970: 2_000), mergePartnerSyncId: "r-partner"),
            .fixture(id: "i3", syncId: "r3", host: "c.example", sortOrder: 1),
        ])
        let store = MemoryOwnedItemStore()
        let client = FakePhiSyncClient()
        for rule in Self.deletedSpaceRules {
            store.table.cursors[rule.uuid] = publishedRuleCursor(
                urlRulePayload(uuid: rule.uuid, host: rule.host, rank: rule.rank),
                entityId: "srv-\(rule.uuid)")
            seedPublished(client, uuid: rule.uuid)
        }
        let spaceStore = drainedSpaceStore()
        try silenceOtherSections(spaceStore, defaults: defaults)
        let engine = makeEngine(client: client, markerStore: markerStore(marker: "9"),
                                spaceStore: spaceStore,
                                ownedKinds: [.urlRules(access: access, store: store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let counters = await engine.lastOwnedRoundCountersForTesting["urlrules"]
        XCTAssertEqual(counters?.tombstones, 1, "①")
        XCTAssertEqual(ruleTombstones(client).map(\.clientTagHash), [ruleHash("r2")], "① 身份是 r2")
        XCTAssertEqual(counters?.pushed, 0, "② 另外两条投影与 reconciled 逐字相等")
        XCTAssertEqual(ruleCommits(client).count, 1, "② 另外两条零 commit")
        XCTAssertNil(access.rows.first { $0.syncId == "r2" }, "③ 出路 1：r2 的行没了")
        XCTAssertEqual(access.hardDeleteCalls, ["r2"], "③")
        XCTAssertEqual(access.rows.map(\.syncId), ["r1", "r3"], "另外两条行原样")
        let cursor = try XCTUnwrap(store.table.cursors["r2"])
        XCTAssertNotNil(cursor.deletedAtMs, "④")
        XCTAssertFalse(cursor.pendingDelete, "④")
        XCTAssertNil(cursor.reconciled, "④")
        XCTAssertFalse(access.rows.contains { $0.mergePartnerSyncId != nil },
                       "⑤ mergePartnerSyncId 随行一起消失")
    }

    // MARK: - CASE 9.1（软删行的第二条出路：30 天清扫）

    /// `r-orphan` 的 tombstone 已连续三轮被拒走过放弃分支（`reconciled == nil`、`deletedAtMs` 已写，
    /// 行的 `deletedDate = T`）；`r-fresh` 是一条新鲜软删行。时钟推到 `T + 29 天`跑一次清理 ⇒
    /// `r-orphan` 仍在（`purgeCalls` 一次、条数 0）；推到 `T + 31 天`再跑 ⇒ `r-orphan` 没了、
    /// `r-fresh` 仍在；第三次再跑 ⇒ 条数 0（幂等）。
    ///
    /// 防的是什么：把判据写成游标上的 `deletedAtMs` 的实现。放弃分支之后 `dropExpiredOwnedTombstones`
    /// 会把那条游标一并丢掉（本用例第二趟正是这样），于是「按游标清行」的实现在游标消失的那一刻就
    /// **永远**找不到这一行了——它在盘上永久驻留，对每一个读口都不可见。
    func testTheThirtyDaySweepPurgesSoftDeletedRowsByTheirOwnDeletedDate() async throws {
        let clock = Clock()
        let t = clock.nowMs
        let fresh = t + 31 * Self.dayMs
        let access = FakeURLRuleAccess(rows: [
            .fixture(id: "i0", syncId: "r-live", host: "live.example", sortOrder: 0),
            .fixture(id: "i1", syncId: "r-orphan", host: "orphan.example", sortOrder: 1,
                     deletedDate: Date(timeIntervalSince1970: Double(t) / 1000)),
            .fixture(id: "i2", syncId: "r-fresh", host: "fresh.example", sortOrder: 2,
                     deletedDate: Date(timeIntervalSince1970: Double(fresh) / 1000)),
        ])
        let store = MemoryOwnedItemStore()
        store.table.cursors["r-live"] = publishedRuleCursor(urlRulePayload(uuid: "r-live", host: "live.example"),
                                                            entityId: "srv-r-live")
        // 放弃分支留下的形状（`PhiSyncEngine.applyOwnedCommitOutcome` 的 `.invalidMessage` 三轮之后）。
        var orphan = ownedCursor(entityId: "srv-r-orphan", version: 1, ownerUuid: "su-1")
        orphan.deleteRejectRounds = 3
        orphan.deletedAtMs = t
        store.table.cursors["r-orphan"] = orphan
        let spaceStore = drainedSpaceStore()
        try silenceOtherSections(spaceStore, defaults: defaults)
        let client = FakePhiSyncClient()
        seedPublished(client, uuid: "r-live")
        let engine = makeEngine(client: client, markerStore: markerStore(marker: "9"),
                                spaceStore: spaceStore, clock: clock,
                                ownedKinds: [.urlRules(access: access, store: store)])
        await engine.setSpaceSyncEnabled(true)

        clock.nowMs = t + 29 * Self.dayMs
        await engine.runRetentionSweep()
        XCTAssertEqual(access.purgeCalls.count, 1, "第一次：清扫跑了一趟")
        XCTAssertEqual(Set(access.rows.compactMap(\.syncId)), ["r-live", "r-orphan", "r-fresh"],
                       "第一次：29 天，r-orphan 仍在")
        XCTAssertNotNil(store.table.cursors["r-orphan"], "29 天：游标也还没到期")

        clock.nowMs = t + 31 * Self.dayMs
        await engine.runRetentionSweep()
        XCTAssertEqual(access.purgeCalls.count, 2)
        XCTAssertNil(store.table.cursors["r-orphan"], "31 天：游标被 dropExpiredOwnedTombstones 丢掉")
        XCTAssertEqual(Set(access.rows.compactMap(\.syncId)), ["r-live", "r-fresh"],
                       "第二次：r-orphan 没了、r-fresh 仍在——判据是行上的 deletedDate，游标没了也找得到")
        let counters = await engine.lastOwnedRoundCountersForTesting["urlrules"]
        XCTAssertEqual(counters?.tombstones ?? 0, 0, "这一趟不动游标的删除记账")
        XCTAssertEqual(counters?.rehomedCursors ?? 0, 0)

        await engine.runRetentionSweep()
        XCTAssertEqual(access.purgeCalls.count, 3, "第三次：仍然跑、条数 0（幂等）")
        XCTAssertEqual(Set(access.rows.compactMap(\.syncId)), ["r-live", "r-fresh"])
        XCTAssertTrue(access.hardDeleteCalls.isEmpty, "出路 2 不经出路 1")
    }
}

/// CASE U-28 的探针：记录每一次 `save` 收到的表上三个 `…HadRecords` 标志**第一次**为真的次序。
/// `writeOwnedTable` 在每条 kind 的落地写之后置位它自己那一位，所以这个次序就是三条 kind 的
/// 处理次序。顶层类型（不进 `@MainActor` 的测试类）：协议 `PhiSpaceSyncStateStore` 不隔离，
/// 引擎从它自己的 actor 上调它。
private final class RecordingSpaceStore: PhiSpaceSyncStateStore {
    var table = PhiSpaceSyncTable()
    private(set) var firstFlagOrder: [String] = []

    func load() -> PhiSpaceSyncTable { table }

    @discardableResult
    func save(_ table: PhiSpaceSyncTable) -> Bool {
        let flags = [("bookmarks", table.bookmarksHadRecords), ("pins", table.pinsHadRecords),
                     ("urlrules", table.urlRulesHadRecords)]
        for (label, flag) in flags where flag && !firstFlagOrder.contains(label) {
            firstFlagOrder.append(label)
        }
        self.table = table
        return true
    }
}

// MARK: - Task 11 段：显式编辑集与单一写面（U-14 / U-15 / U-15b / U-15c / U-22 / U-24c）

/// 真 `LocalStore`（临时目录）+ 编辑器的纯函数 `URLRulesEditor.computeEditSet` + agent 侧的两个纯函数
/// + `SpaceManager.makeForTesting(boundTo:)`（只绑 `boundAccount`，不碰 `shared`）。
/// 「差分产出恰好一条 tombstone」那一半是 Task 9 的（U-22 的 tombstone 用例在上面）；这里只断言行。
extension URLRuleKindTests {
    private typealias Row = URLRulesEditor.Row

    private struct RuleSnap: Equatable {
        var id: String
        var spaceId: String
        var host: String
        var pathPrefix: String?
        var askBeforeRouting: Bool
        var sortOrder: Int
        var syncId: String?
        var contentUpdatedDate: Date?
        var targetUpdatedDate: Date?
        var deletedDate: Date?
        var pendingLocalEdit: Bool

        init(_ rule: SpaceURLRule) {
            id = rule.id
            spaceId = rule.spaceId
            host = rule.host
            pathPrefix = rule.pathPrefix
            askBeforeRouting = rule.askBeforeRouting
            sortOrder = rule.sortOrder
            syncId = rule.syncId
            contentUpdatedDate = rule.contentUpdatedDate
            targetUpdatedDate = rule.targetUpdatedDate
            deletedDate = rule.deletedDate
            pendingLocalEdit = rule.pendingLocalEdit
        }
    }

    private struct Seed {
        var id: String
        var syncId: String
        var spaceId: String = "space-a"
        var host: String
        var ask: Bool = false
        var sortOrder: Int
    }

    private static let t11SpaceA = "space-a"
    private static let t11SpaceB = "space-b"
    /// 大写 UUID 串：`Row.init(from:)` 往返 `UUID(uuidString:).uuidString` 之后一个字不变，
    /// 于是 U-14 主变体能正面断言「`id` 不变」；小写 / 非 UUID 形的 id 走 legacy 变体（`syncId` 兜住）。
    private static let i0 = "0A0A0A0A-0000-4000-8000-000000000000"
    private static let i1 = "1B1B1B1B-0000-4000-8000-000000000001"
    private static let i2 = "2C2C2C2C-0000-4000-8000-000000000002"

    private static var threeSeeds: [Seed] {
        [
            Seed(id: i0, syncId: "r0", host: "zero.example", sortOrder: 0),
            Seed(id: i1, syncId: "r1", host: "one.example", sortOrder: 1),
            Seed(id: i2, syncId: "r2", host: "two.example", sortOrder: 2),
        ]
    }

    private func makeRuleStore(for account: Account? = nil) throws -> LocalStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("URLRuleKindTests.t11.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        return LocalStore(account: account ?? Account(userID: "test-user"),
                          storeDirectoryURL: directory,
                          presentsCompatibilityAlerts: false)
    }

    private func seed(_ seeds: [Seed], in store: LocalStore) async throws {
        try await store.performBackgroundWriteAndWaitThrowing { context in
            for seed in seeds {
                context.insert(SpaceURLRule(id: seed.id,
                                            spaceId: seed.spaceId,
                                            host: seed.host,
                                            askBeforeRouting: seed.ask,
                                            sortOrder: seed.sortOrder,
                                            syncId: seed.syncId))
            }
        }
    }

    private func drainMainQueue() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    /// 整张表（**含软删行**）的值快照，按 `id`。
    private func snapshot(_ store: LocalStore) throws -> [String: RuleSnap] {
        drainMainQueue()
        let context = try XCTUnwrap(store.getMainContext())
        let rows = try context.fetch(FetchDescriptor<SpaceURLRule>())
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.id, RuleSnap($0)) })
    }

    /// 默认读口（软删行已过滤），与编辑器 `load()` / agent `storedRules()` 读的是同一条路。
    private func liveRules(_ store: LocalStore) -> [SpaceURLRule] {
        drainMainQueue()
        return store.getAllURLRules()
    }

    private func editorRows(_ store: LocalStore) -> [Row] {
        liveRules(store).map(Row.init(from:))
    }

    private func editSet(rows: [Row], loaded: [Row], removed: [Row] = [],
                         store: LocalStore) -> URLRulesEditor.EditSet {
        URLRulesEditor.computeEditSet(rows: rows, loaded: loaded, removed: removed,
                                      stored: liveRules(store))
    }

    private func apply(_ edits: URLRulesEditor.EditSet, to store: LocalStore) async throws {
        try await store.applyURLRuleEditsThrowing(upserts: edits.upserts, deletedIds: edits.deletedIds)
    }

    private func assertIdentityUntouched(_ before: [String: RuleSnap], _ after: [String: RuleSnap],
                                         ids: [String], file: StaticString = #filePath, line: UInt = #line) {
        for id in ids {
            XCTAssertEqual(after[id]?.id, id, "id of \(id) drifted", file: file, line: line)
            XCTAssertEqual(after[id]?.syncId, before[id]?.syncId, "syncId of \(id) drifted", file: file, line: line)
        }
    }

    // MARK: CASE U-14（四处 draft 构造点都带身份与 `id`）

    /// 四条不相关的编辑各走一处构造点：(1) 编辑器改第 2 条的 value；(2) agent add 往 S1 加一条；
    /// (3) agent update 改第 2 条的 ask；(4) 单一写面软删第 3 条。每条之后第 2 条 `id == I1`、
    /// `syncId == r1`；(1) / (3) 盖 `contentUpdatedDate`、`targetUpdatedDate` 不动；(2) / (4) 两枚戳都不动；
    /// 同桶其余规则的 `id` / `syncId` 都不变；总行数只在 (2) 增一。
    ///
    /// 防的是什么：漏传 `id` 的 draft miss 索引、退化成 delete-then-insert（`URLRuleDraft.init` 的 `id`
    /// 默认实参是重铸）；漏传 `syncId` 在 legacy 行上把一条规则变成两条。
    func testEveryDraftConstructionSiteCarriesTheRowIdentity() async throws {
        let store = try makeRuleStore()
        try await seed(Self.threeSeeds, in: store)
        let s0 = try snapshot(store)
        XCTAssertNil(s0[Self.i1]?.contentUpdatedDate)

        // (1) 编辑器：只改第 2 条的 value。
        let loaded = editorRows(store)
        var rows = loaded
        let index1 = try XCTUnwrap(rows.firstIndex { $0.storeId == Self.i1 })
        rows[index1].value = "one-changed.example"
        let e1 = editSet(rows: rows, loaded: loaded, store: store)
        XCTAssertEqual(e1.upserts.map(\.id), [Self.i1], "(1) 只有第 2 条进 upserts")
        XCTAssertEqual(e1.upserts.first?.syncId, "r1")
        XCTAssertTrue(e1.deletedIds.isEmpty)
        try await apply(e1, to: store)
        let s1 = try snapshot(store)
        XCTAssertEqual(s1.count, 3)
        assertIdentityUntouched(s0, s1, ids: [Self.i0, Self.i1, Self.i2])
        XCTAssertEqual(s1[Self.i1]?.host, "*.one-changed.example")
        XCTAssertNotNil(s1[Self.i1]?.contentUpdatedDate, "(1) 内容改了 ⇒ 盖内容戳")
        XCTAssertNil(s1[Self.i1]?.targetUpdatedDate, "(1) 目标戳不动")

        // (2) agent add：往 S1 加一条新规则。
        let e2 = AgentSpaceRouter.urlRuleAddEdits(all: liveRules(store), spaceId: Self.t11SpaceA,
                                                  host: "added.example", pathPrefix: nil, ask: false)
        XCTAssertEqual(e2.upserts.count, 4, "(2) 目标桶整桶 + 一条新行")
        XCTAssertEqual(Set(e2.upserts.prefix(3).map(\.id)), [Self.i0, Self.i1, Self.i2], "(2) 既有行都带 id")
        XCTAssertEqual(e2.upserts.prefix(3).compactMap(\.syncId).count, 3, "(2) 既有行都带 syncId")
        XCTAssertNil(e2.upserts.last?.syncId, "(2) 新行不带 syncId（插入点铸）")
        XCTAssertEqual(e2.upserts.last?.sortOrder, 3)
        try await apply(e2, to: store)
        let s2 = try snapshot(store)
        XCTAssertEqual(s2.count, 4, "(2) 行数增一")
        assertIdentityUntouched(s1, s2, ids: [Self.i0, Self.i1, Self.i2])
        XCTAssertEqual(s2[Self.i1]?.contentUpdatedDate, s1[Self.i1]?.contentUpdatedDate, "(2) 第 2 条内容戳不动")
        XCTAssertNil(s2[Self.i1]?.targetUpdatedDate)
        let added = try XCTUnwrap(s2.values.first { $0.host == "added.example" })
        XCTAssertNotNil(added.syncId)
        XCTAssertEqual(added.sortOrder, 3)

        // (3) agent update：改第 2 条的 ask。
        let existing = try XCTUnwrap(liveRules(store).first { $0.id == Self.i1 })
        let e3 = AgentSpaceRouter.urlRuleUpdateEdits(all: liveRules(store), existing: existing,
                                                     host: existing.host, pathPrefix: existing.pathPrefix,
                                                     ask: true, spaceId: existing.spaceId)
        XCTAssertEqual(e3.upserts.count, 4, "(3) 同桶整桶")
        XCTAssertEqual(e3.upserts.first { $0.id == Self.i1 }?.syncId, "r1")
        XCTAssertEqual(e3.upserts.first { $0.id == Self.i1 }?.sortOrder, 1, "(3) 位置保留")
        try await apply(e3, to: store)
        let s3 = try snapshot(store)
        XCTAssertEqual(s3.count, 4)
        assertIdentityUntouched(s2, s3, ids: [Self.i0, Self.i1, Self.i2, added.id])
        XCTAssertEqual(s3[Self.i1]?.askBeforeRouting, true)
        XCTAssertNotEqual(s3[Self.i1]?.contentUpdatedDate, s2[Self.i1]?.contentUpdatedDate, "(3) ask 改了 ⇒ 盖内容戳")
        XCTAssertNil(s3[Self.i1]?.targetUpdatedDate)

        // (4) 单一写面：软删第 3 条。
        let e4 = URLRulesEditor.EditSet(upserts: [], deletedIds: [Self.i2])
        try await apply(e4, to: store)
        let s4 = try snapshot(store)
        XCTAssertEqual(s4.count, 4, "(4) 软删不减行")
        XCTAssertNotNil(s4[Self.i2]?.deletedDate)
        assertIdentityUntouched(s3, s4, ids: [Self.i0, Self.i1, Self.i2, added.id])
        XCTAssertEqual(s4[Self.i1]?.contentUpdatedDate, s3[Self.i1]?.contentUpdatedDate, "(4) 两枚戳都不动")
        XCTAssertNil(s4[Self.i1]?.targetUpdatedDate)
        XCTAssertEqual(liveRules(store).map(\.sortOrder), [0, 1, 2], "(4) 桶内稠密")
    }

    /// legacy 变体：`id = "legacy-7"` / `syncId = r2` 的行走编辑器路径改一次 host ⇒ 那条行的 `id` 变了
    /// （一个 UUID 串）、`syncId == r2`、总行数不增（裁定 3 的 store 兜底：按 `syncId` 认成同一条行）。
    func testALegacyIdRowIsRecastNotDuplicatedByTheEditor() async throws {
        let store = try makeRuleStore()
        try await seed([
            Seed(id: Self.i0, syncId: "r0", host: "zero.example", sortOrder: 0),
            Seed(id: "legacy-7", syncId: "r2", host: "legacy.example", sortOrder: 1),
        ], in: store)

        let loaded = editorRows(store)
        var rows = loaded
        let index = try XCTUnwrap(rows.firstIndex { $0.storeId == "legacy-7" })
        XCTAssertNotEqual(rows[index].id.uuidString, "legacy-7", "Row.init(from:) 重铸了非 UUID 形的 id")
        XCTAssertEqual(rows[index].syncId, "r2")
        rows[index].value = "legacy-changed.example"
        let edits = editSet(rows: rows, loaded: loaded, store: store)
        XCTAssertEqual(edits.upserts.count, 1)
        XCTAssertEqual(edits.upserts.first?.id, rows[index].id.uuidString, "upsert 传重铸后的 id")
        XCTAssertEqual(edits.upserts.first?.syncId, "r2", "…与 syncId 兜住身份")
        try await apply(edits, to: store)

        let after = try snapshot(store)
        XCTAssertEqual(after.count, 2, "总行数不增")
        XCTAssertNil(after["legacy-7"], "旧 id 没了")
        let recast = try XCTUnwrap(after.values.first { $0.syncId == "r2" })
        XCTAssertNotNil(UUID(uuidString: recast.id), "新 id 是一个 UUID 串")
        XCTAssertEqual(recast.host, "*.legacy-changed.example")
        XCTAssertEqual(after[Self.i0]?.syncId, "r0")
    }

    // MARK: CASE U-15（编辑器不改写失效目标；触发条件是「改了一行」）

    /// 第 1 / 2 条的目标都不在活 Space 里（一条 ask、一条不 ask），只改第 3 条 ⇒ `upserts` 恰好第 3 条、
    /// `deletedIds` 空；落库后第 1 / 2 条的目标原样、两条都在、两枚戳一个字节不动。
    ///
    /// 防的是什么：从前 `save()` 把 ask 行的失效目标改写成 `ruleTargetSpaces.first`、把非 ask 的失效行
    /// 整条丢掉——前者让两台机器为同一身份发布不同目标、后者是一次账户级删除。
    func testTheEditorNeitherRewritesNorDropsRulesWithUnresolvableTargets() async throws {
        let store = try makeRuleStore()
        try await seed([
            Seed(id: Self.i0, syncId: "r0", spaceId: "dead-space-a", host: "a.example", ask: true, sortOrder: 0),
            Seed(id: Self.i1, syncId: "r1", spaceId: "dead-space-b", host: "b.example", ask: false, sortOrder: 0),
            Seed(id: Self.i2, syncId: "r2", spaceId: Self.t11SpaceA, host: "c.example", sortOrder: 0),
        ], in: store)
        let before = try snapshot(store)

        let loaded = editorRows(store)
        var rows = loaded
        let index = try XCTUnwrap(rows.firstIndex { $0.storeId == Self.i2 })
        rows[index].value = "c-changed.example"
        let edits = editSet(rows: rows, loaded: loaded, store: store)
        XCTAssertEqual(edits.upserts.map(\.id), [Self.i2])
        XCTAssertEqual(edits.upserts.first?.spaceId, Self.t11SpaceA)
        XCTAssertTrue(edits.deletedIds.isEmpty)
        try await apply(edits, to: store)

        let after = try snapshot(store)
        XCTAssertEqual(after.count, 3)
        XCTAssertEqual(after[Self.i0]?.spaceId, "dead-space-a")
        XCTAssertEqual(after[Self.i1]?.spaceId, "dead-space-b")
        XCTAssertEqual(after[Self.i0], before[Self.i0], "第 1 条一个字节不动")
        XCTAssertEqual(after[Self.i1], before[Self.i1], "第 2 条一个字节不动")
        XCTAssertEqual(after[Self.i2]?.host, "*.c-changed.example")
    }

    // MARK: CASE U-15b（编辑器不碰它没见过的行）

    /// sheet 打开时两条；期间远端落了第 3 条（`syncId = r3`）；改第 1 条之后保存 ⇒ `deletedIds` 空、
    /// `upserts` 只有第 1 条；第 3 条仍在、`syncId` 仍是 r3、`deletedDate == nil`。
    ///
    /// 防的是什么：整表写回那一版（`replaceAllURLRules` 的「不在字典里 = 清空」）让第 3 条在本机消失，
    /// 差分把它当用户删除、每台设备都删。「下一轮差分 tombstones == 0」由 Task 9 的定义域钉。
    func testTheEditorLeavesRowsItNeverSawAlone() async throws {
        let store = try makeRuleStore()
        try await seed(Array(Self.threeSeeds.prefix(2)), in: store)
        let loaded = editorRows(store)
        XCTAssertEqual(loaded.count, 2)

        // sheet 打开期间远端落地的新行。
        try await seed([Seed(id: Self.i2, syncId: "r3", host: "remote.example", sortOrder: 2)], in: store)

        var rows = loaded
        let index = try XCTUnwrap(rows.firstIndex { $0.storeId == Self.i0 })
        rows[index].value = "zero-changed.example"
        let edits = editSet(rows: rows, loaded: loaded, store: store)
        XCTAssertTrue(edits.deletedIds.isEmpty)
        XCTAssertEqual(edits.upserts.map(\.id), [Self.i0])
        try await apply(edits, to: store)

        let after = try snapshot(store)
        XCTAssertEqual(after.count, 3)
        XCTAssertEqual(after[Self.i2]?.syncId, "r3")
        XCTAssertNil(after[Self.i2]?.deletedDate)
        XCTAssertEqual(after[Self.i2]?.host, "remote.example")
        XCTAssertEqual(after[Self.i0]?.host, "*.zero-changed.example")
    }

    // MARK: CASE U-15c（清空即删除）

    /// 把第 1 条的 value 清空、再 append 一条 `Row(defaultSpaceId:)` 的空行 ⇒ `deletedIds == [I1]`，
    /// `upserts` 里既没有新空行也没有第 1 条；落库后仍是三条，I1 `deletedDate != nil` 且
    /// `pendingLocalEdit == false`，I2 / I3 一个字节不动。变体：`.domainSuffix` + `"*."`（encode 出空 host）。
    ///
    /// 防的是什么：从前两道静默 `continue` 在「整表写回」下等于删除；换成「只碰点名的行」之后它们会变成
    /// 「库里那一行原封不动、继续路由」。另一半防的是把新空行插进去。
    func testClearingARuleDeletesItAndBlankNewRowsAreIgnored() async throws {
        let store = try makeRuleStore()
        try await seed(Self.threeSeeds, in: store)
        let before = try snapshot(store)

        let loaded = editorRows(store)
        var rows = loaded
        let index = try XCTUnwrap(rows.firstIndex { $0.storeId == Self.i0 })
        rows[index].value = ""
        rows.append(Row(defaultSpaceId: Self.t11SpaceA))
        let edits = editSet(rows: rows, loaded: loaded, store: store)
        XCTAssertEqual(edits.deletedIds, [Self.i0])
        XCTAssertTrue(edits.upserts.isEmpty, "新空行与被清空的行都不进 upserts")
        try await apply(edits, to: store)

        let after = try snapshot(store)
        XCTAssertEqual(after.count, 3, "库里仍是三条（软删 + 没插新空行）")
        XCTAssertNotNil(after[Self.i0]?.deletedDate)
        XCTAssertEqual(after[Self.i0]?.pendingLocalEdit, false, "删除不是编辑（R-M3-4a-69）")
        XCTAssertEqual(after[Self.i1]?.host, before[Self.i1]?.host)
        XCTAssertEqual(after[Self.i1]?.syncId, before[Self.i1]?.syncId)
        XCTAssertEqual(after[Self.i1]?.contentUpdatedDate, before[Self.i1]?.contentUpdatedDate)
        XCTAssertEqual(after[Self.i1]?.pendingLocalEdit, false)
        XCTAssertEqual(after[Self.i2]?.host, before[Self.i2]?.host)
        XCTAssertEqual(after[Self.i2]?.pendingLocalEdit, false)
        XCTAssertEqual(liveRules(store).map(\.sortOrder), [0, 1], "桶内稠密")

        // 变体：encode 出空 host 的形状同样算清空。
        let loaded2 = editorRows(store)
        var rows2 = loaded2
        let index2 = try XCTUnwrap(rows2.firstIndex { $0.storeId == Self.i1 })
        rows2[index2].matchType = .domainSuffix
        rows2[index2].value = "*."
        let edits2 = editSet(rows: rows2, loaded: loaded2, store: store)
        XCTAssertEqual(edits2.deletedIds, [Self.i1])
        XCTAssertTrue(edits2.upserts.isEmpty)
    }

    // MARK: CASE U-22（编辑器删一行 ⇒ 软删行）

    /// 同桶三条，`removed` 里放第 2 条、`rows` 只剩第 1 / 3 条 ⇒ `deletedIds == [I2]`、`upserts` 空；
    /// 经 `applyRuleEdits` 落库后 I2 的行还在且 `deletedDate != nil`、`pendingLocalEdit == false`；
    /// 桶内存活行的 `sortOrder` 是稠密的 0…1；第 1 / 3 条两枚戳与 `pendingLocalEdit` 一个字节不动。
    ///
    /// 防的是什么：`context.delete` 让删除意图与行一起消失（R-M3-4a-41）；顺手给软删行置
    /// `pendingLocalEdit` 会让一条已决定要删的规则对入站 tombstone 让位。
    func testDeletingARowInTheEditorSoftDeletesExactlyThatRow() async throws {
        let account = Account(userID: "t11-u22")
        let store = try makeRuleStore(for: account)
        account.localStorage = store
        try await seed(Self.threeSeeds, in: store)
        let before = try snapshot(store)
        let manager = SpaceManager.makeForTesting(boundTo: account)

        let loaded = editorRows(store)
        var rows = loaded
        let index = try XCTUnwrap(rows.firstIndex { $0.storeId == Self.i1 })
        let removed = [rows.remove(at: index)]
        XCTAssertEqual(removed.first?.syncId, "r1")
        let edits = editSet(rows: rows, loaded: loaded, removed: removed, store: store)
        XCTAssertEqual(edits.deletedIds, [Self.i1])
        XCTAssertTrue(edits.upserts.isEmpty, "第 1 / 3 条内容与相对序都没动")
        try await manager.applyRuleEdits(upserts: edits.upserts, deletedIds: edits.deletedIds)

        let after = try snapshot(store)
        XCTAssertEqual(after.count, 3, "I2 的行还在")
        XCTAssertNotNil(after[Self.i1]?.deletedDate)
        XCTAssertEqual(after[Self.i1]?.pendingLocalEdit, false)
        for id in [Self.i0, Self.i2] {
            XCTAssertEqual(after[id]?.contentUpdatedDate, before[id]?.contentUpdatedDate)
            XCTAssertEqual(after[id]?.targetUpdatedDate, before[id]?.targetUpdatedDate)
            XCTAssertEqual(after[id]?.pendingLocalEdit, false)
        }
        XCTAssertEqual(liveRules(store).map(\.sortOrder), [0, 1], "存活行稠密 0…1")
        XCTAssertEqual(manager.urlRuleReloadCountForTesting, 1, "写面刷新了一次")
    }

    // MARK: CASE U-24c（每一个写面都刷新）

    /// (a) 绑在临时目录 store 上的 `SpaceManager`：连调三次 `applyRuleEdits`（改 host / 加 / 删）⇒
    /// `urlRuleReloadCountForTesting` 0 → 3、每次恰好加一，且每次刷新读到的都是已提交的行；
    /// `boundAccount == nil` ⇒ 抛 `.storeUnavailable`、计数不动。
    ///
    /// 防的是什么：绕过 `applyRuleEdits` 直接调 store 的那一版让库变了、`cachedURLRules` 因
    /// `removeDuplicates` 不变、Chromium 的表不变；`guard … else { return }` 那一版把「没写」与「写成功」
    /// 做成同一个观感（R-M3-3-14）。
    func testEveryWriteFaceRefreshesTheRoutingTableOnceAfterTheCommit() async throws {
        let account = Account(userID: "t11-u24c")
        let store = try makeRuleStore(for: account)
        account.localStorage = store
        try await seed(Self.threeSeeds, in: store)
        let manager = SpaceManager.makeForTesting(boundTo: account)
        XCTAssertEqual(manager.urlRuleReloadCountForTesting, 0)

        // 改一条 host。
        try await manager.applyRuleEdits(
            upserts: [LocalStore.URLRuleDraft(id: Self.i0, host: "zero-changed.example",
                                              spaceId: Self.t11SpaceA, syncId: "r0")],
            deletedIds: [])
        XCTAssertEqual(manager.urlRuleReloadCountForTesting, 1)
        XCTAssertEqual(manager.allRules.first { $0.id == Self.i0 }?.host, "zero-changed.example",
                       "刷新读到的是已提交的行")

        // 加一条。
        try await manager.applyRuleEdits(
            upserts: [LocalStore.URLRuleDraft(host: "added.example", spaceId: Self.t11SpaceA, sortOrder: 3)],
            deletedIds: [])
        XCTAssertEqual(manager.urlRuleReloadCountForTesting, 2)
        XCTAssertEqual(manager.allRules.count, 4)

        // 删一条。
        try await manager.applyRuleEdits(upserts: [], deletedIds: [Self.i2])
        XCTAssertEqual(manager.urlRuleReloadCountForTesting, 3)
        XCTAssertEqual(manager.allRules.count, 3)
        XCTAssertFalse(manager.allRules.contains { $0.id == Self.i2 })

        // 没绑账号 ⇒ 抛，不是静默返回。
        let unbound = SpaceManager.makeForTesting(boundTo: nil)
        do {
            try await unbound.applyRuleEdits(upserts: [], deletedIds: [Self.i0])
            XCTFail("expected .storeUnavailable")
        } catch let error as LocalStoreWriteError {
            XCTAssertEqual(error, .storeUnavailable)
        }
        XCTAssertEqual(unbound.urlRuleReloadCountForTesting, 0)
    }

    /// (b) 三个写面的纯编辑集：add ⇒ 一条新 draft、`deletedIds` 空；update ⇒ 一条带 `id` / `syncId` 的
    /// draft、`deletedIds` 空；delete ⇒ `upserts` 空、`deletedIds` 恰好那一个 id。
    /// 「三个 handler 各自恰好经过 `applyRuleEdits` 一次」由编译 + grep 兜住（CASE 11.1）。
    func testTheThreeAgentWriteFacesProduceRowAddressedEditSets() {
        let existing = SpaceURLRule(id: Self.i1, spaceId: Self.t11SpaceA, host: "one.example",
                                    sortOrder: 0, syncId: "r1")

        let add = AgentSpaceRouter.urlRuleAddEdits(all: [], spaceId: Self.t11SpaceA,
                                                   host: "new.example", pathPrefix: "/p/", ask: true)
        XCTAssertEqual(add.upserts.count, 1)
        XCTAssertNil(add.upserts.first?.syncId)
        XCTAssertEqual(add.upserts.first?.spaceId, Self.t11SpaceA)
        XCTAssertEqual(add.upserts.first?.sortOrder, 0)
        XCTAssertEqual(add.upserts.first?.content?.host, "new.example")
        XCTAssertEqual(add.upserts.first?.content?.pathPrefix, "/p")
        XCTAssertEqual(add.upserts.first?.content?.askBeforeRouting, true)
        XCTAssertTrue(add.deletedIds.isEmpty)

        let update = AgentSpaceRouter.urlRuleUpdateEdits(all: [existing], existing: existing,
                                                         host: "one.example", pathPrefix: nil,
                                                         ask: true, spaceId: Self.t11SpaceA)
        XCTAssertEqual(update.upserts.count, 1)
        XCTAssertEqual(update.upserts.first?.id, Self.i1)
        XCTAssertEqual(update.upserts.first?.syncId, "r1")
        XCTAssertEqual(update.upserts.first?.content?.askBeforeRouting, true)
        XCTAssertTrue(update.deletedIds.isEmpty)

        // 改目标：源桶少一条、目标桶多一条，两个桶各自成序。
        let sibling = SpaceURLRule(id: Self.i0, spaceId: Self.t11SpaceA, host: "zero.example",
                                   sortOrder: 1, syncId: "r0")
        let moved = AgentSpaceRouter.urlRuleUpdateEdits(all: [existing, sibling], existing: existing,
                                                        host: "one.example", pathPrefix: nil,
                                                        ask: false, spaceId: Self.t11SpaceB)
        XCTAssertEqual(moved.upserts.map(\.id), [Self.i0, Self.i1])
        XCTAssertEqual(moved.upserts.map(\.spaceId), [Self.t11SpaceA, Self.t11SpaceB])
        XCTAssertEqual(moved.upserts.map(\.sortOrder), [0, 0])

        let delete = URLRulesEditor.EditSet(upserts: [], deletedIds: [Self.i1])
        XCTAssertTrue(delete.upserts.isEmpty)
        XCTAssertEqual(delete.deletedIds, [Self.i1])
    }

    // MARK: 裁定 4（拖动排序：整桶只带 `sortOrder`）与恢复支（R-M3-4a-101 / 104）

    /// 桶内把第 3 条拖到最前 ⇒ 三条都进 `upserts`，全部 `content == nil` / `spaceId == nil`、
    /// `sortOrder` 是新下标；落库后桶序 [I2, I0, I1]、两枚戳一动不动。
    func testReorderingABucketSendsSortOrderOnlyDrafts() async throws {
        let store = try makeRuleStore()
        try await seed(Self.threeSeeds, in: store)
        let before = try snapshot(store)

        let loaded = editorRows(store)
        var rows = loaded
        let last = rows.removeLast()
        rows.insert(last, at: 0)
        let edits = editSet(rows: rows, loaded: loaded, store: store)
        XCTAssertEqual(edits.upserts.map(\.id), [Self.i2, Self.i0, Self.i1])
        XCTAssertEqual(edits.upserts.map(\.sortOrder), [0, 1, 2])
        XCTAssertTrue(edits.upserts.allSatisfy { $0.content == nil && $0.spaceId == nil }, "只带 sortOrder")
        XCTAssertTrue(edits.deletedIds.isEmpty)
        try await apply(edits, to: store)

        let after = try snapshot(store)
        XCTAssertEqual(liveRules(store).map(\.id), [Self.i2, Self.i0, Self.i1])
        for id in [Self.i0, Self.i1, Self.i2] {
            XCTAssertEqual(after[id]?.contentUpdatedDate, before[id]?.contentUpdatedDate)
            XCTAssertEqual(after[id]?.targetUpdatedDate, before[id]?.targetUpdatedDate)
        }
    }

    /// CASE 11.2（fix round 1）：拖动重排 + 一条**没动过的**兄弟行在 sheet 打开期间被远端硬删 ⇒ 消失的
    /// 那条不进 `upserts`（它没有现值可重排；带 `content: nil` 的 draft 会让 store 的插入支抛
    /// `noCandidateSurvived` 并整批回滚），其余行的 `sortOrder` draft 照发、写入提交、桶稠密。
    func testAReorderStillCommitsWhenASiblingVanishedBehindTheSheet() async throws {
        let store = try makeRuleStore()
        try await seed(Self.threeSeeds, in: store)
        let loaded = editorRows(store)

        // 远端硬删了第 2 条（用户在 sheet 里没碰它）。
        try await store.performBackgroundWriteAndWaitThrowing { context in
            let id = Self.i1
            for row in try context.fetch(FetchDescriptor<SpaceURLRule>(predicate: #Predicate { $0.id == id })) {
                context.delete(row)
            }
        }
        XCTAssertEqual(liveRules(store).count, 2)

        // 用户把第 3 条拖到最前：rows = [I2, I0, I1]。
        var rows = loaded
        let last = rows.removeLast()
        rows.insert(last, at: 0)
        let edits = editSet(rows: rows, loaded: loaded, store: store)
        XCTAssertEqual(edits.upserts.map(\.id), [Self.i2, Self.i0], "消失的 I1 不进 upserts")
        XCTAssertTrue(edits.upserts.allSatisfy { $0.content == nil && $0.spaceId == nil })
        XCTAssertTrue(edits.deletedIds.isEmpty)
        try await apply(edits, to: store)

        let after = try snapshot(store)
        XCTAssertEqual(after.count, 2, "写入提交了；I1 没有被复活")
        XCTAssertNil(after[Self.i1])
        XCTAssertEqual(liveRules(store).map(\.id), [Self.i2, Self.i0])
        XCTAssertEqual(liveRules(store).map(\.sortOrder), [0, 1], "桶稠密")
    }

    /// sheet 打开期间那一行被远端硬删；用户改了它 ⇒ draft 带原 `id`、`syncId = nil`（恢复支），落库后
    /// 它以一条新身份回来、行数不变。
    func testADirtyRowDeletedRemotelyComesBackWithoutItsOldSyncId() async throws {
        let store = try makeRuleStore()
        try await seed(Self.threeSeeds, in: store)
        let loaded = editorRows(store)

        try await store.performBackgroundWriteAndWaitThrowing { context in
            let id = Self.i1
            for row in try context.fetch(FetchDescriptor<SpaceURLRule>(predicate: #Predicate { $0.id == id })) {
                context.delete(row)
            }
        }
        XCTAssertEqual(liveRules(store).count, 2)

        var rows = loaded
        let index = try XCTUnwrap(rows.firstIndex { $0.storeId == Self.i1 })
        rows[index].value = "one-revived.example"
        let edits = editSet(rows: rows, loaded: loaded, store: store)
        XCTAssertEqual(edits.upserts.map(\.id), [Self.i1], "原 id")
        XCTAssertNil(edits.upserts.first?.syncId, "恢复支不带旧 syncId")
        try await apply(edits, to: store)

        let after = try snapshot(store)
        XCTAssertEqual(after.count, 3)
        XCTAssertEqual(after[Self.i1]?.host, "*.one-revived.example")
        XCTAssertNotNil(after[Self.i1]?.syncId)
        XCTAssertNotEqual(after[Self.i1]?.syncId, "r1")
    }
}

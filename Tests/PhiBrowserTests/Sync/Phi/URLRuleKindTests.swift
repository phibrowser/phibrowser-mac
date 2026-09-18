import Combine
import CryptoKit
import Foundation
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

    /// 形状照 `PhiSyncMarkerBoundaryTests.makeOwnedEngine`：`settings: []`，时钟冻结。
    private func makeEngine(client: FakePhiSyncClient,
                            markerStore: any PhiSyncMarkerStore,
                            spaceStore: any PhiSpaceSyncStateStore,
                            spaceAccess: FakePhiSpaceAccess? = nil,
                            defaults: UserDefaults? = nil,
                            ownedKinds: [OwnedKindRegistration]) -> PhiSyncEngine {
        PhiSyncEngine(domainKeys: StubDomainKeys(key: key), client: client,
                      defaults: defaults ?? self.defaults, deviceKeyId: "devA", settings: [],
                      spaceAccess: spaceAccess ?? makeSpaceAccess(), spaceStore: spaceStore,
                      markerStore: markerStore, ownedKinds: ownedKinds,
                      now: { Self.now })
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
    private func makeLossFixture(hadRecords: Bool, withSyncIds: Bool = true,
                                 replayPage: Bool = true) -> LossFixture {
        let rows: [PhiLocalURLRule] = withSyncIds
            ? [.fixture(id: "i1", syncId: "r1", sortOrder: 0), .fixture(id: "i2", syncId: "r2", sortOrder: 1)]
            : [.fixture(id: "i1", sortOrder: 0), .fixture(id: "i2", sortOrder: 1)]
        let spaceStore = drainedSpaceStore()
        spaceStore.table.urlRulesHadRecords = hadRecords
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
        let f = makeLossFixture(hadRecords: true)
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
        let f = makeLossFixture(hadRecords: true)
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
        let f = makeLossFixture(hadRecords: false, withSyncIds: false)
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
        let f = makeLossFixture(hadRecords: false, withSyncIds: true)
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
        let f = makeLossFixture(hadRecords: true)
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
        // 页 1 那一次表写之外没有第二次 Space 表写：步骤 ② 没跑。
        XCTAssertLessThanOrEqual(f.spaceStore.saveCalls - spaceSavesBefore, 1)
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
        let f = makeLossFixture(hadRecords: true)
        let engine = makeLossEngine(f)
        await engine.setSpaceSyncEnabled(true)
        // 页 1 那次表写是第 1 次，报损重放的第 ② 步是第 2 次。
        f.spaceStore.failSaveOnCallNumber = f.spaceStore.saveCalls + 2
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
        let f = makeLossFixture(hadRecords: true, replayPage: false)
        let engine = makeLossEngine(f)
        await engine.setSpaceSyncEnabled(true)
        f.spaceStore.failSaveOnCallNumber = f.spaceStore.saveCalls + 2
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
        RunLoop.main.run(until: Date().addingTimeInterval(window + 0.6))
        XCTAssertEqual(received, ["urlrules"], "三条写塌成一轮，实参是注册项的 label")

        // `stopPhiSync()`：cancel + 置 nil + label 置 nil。
        cancellable?.cancel()
        cancellable = nil
        label = nil
        try await store.applyURLRuleEditsThrowing(
            upserts: [LocalStore.URLRuleDraft(id: "u29-late", host: "late.example", spaceId: "space-a")],
            deletedIds: [])
        RunLoop.main.run(until: Date().addingTimeInterval(window + 0.6))
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

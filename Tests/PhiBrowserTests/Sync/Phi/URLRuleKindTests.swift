import Combine
import CryptoKit
import Foundation
import SwiftData
import XCTest
@testable import Phi

/// URLRuleKind module tests from spec §12.1's URL Rule block (Task 7). Inputs and outputs are values, without
/// SwiftData, engine or persistence. @MainActor accommodates actor-isolated fakes in this file family, as in
/// SyncableOwnedItemsTests.swift:11–12; the module itself needs no actor.
/// The Task 6 section adds engine coverage for U-11 / U-16 / U-17 / U-18(a)–(f) / U-24 / U-27…U-31, using the
/// real engine, FakeURLRuleAccess and memory stores, driven only by pullOnce() and
/// handleLocalOwnedChange(label:).
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
    /// Defaults suites for the second engine in CASE U-11, also cleared in tearDown.
    private var extraSuites: [String] = []
    /// Temporary directories for CASE U-29's real LocalStore.
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

    // MARK: - Helpers

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

    // MARK: - CASE U-1 (park without rewriting)

    func testUnresolvableTargetParksTheEntityWithoutRewritingIt() {
        let payload = urlRulePayload(uuid: "r1", targetSpaceUuid: "S-unknown")
        let plan = planned([arrival(payload, entityId: "srv-1", version: 3)])

        XCTAssertTrue(plan.steps.isEmpty)
        XCTAssertEqual(Array(plan.parked.keys), ["r1"])
        XCTAssertEqual(plan.parked["r1"]?.pendingOwnerUuid, "S-unknown")
        XCTAssertEqual(plan.harvest["r1"]?.entityId, "srv-1")
        XCTAssertEqual(plan.harvest["r1"]?.version, 3)
        XCTAssertEqual(plan.refused, 0)
        // Parked payload bytes equal the inbound payload; no alternative target was ever written (D16).
        XCTAssertEqual(plan.parked["r1"]?.payload, baselineBytes(payload))
    }

    /// Planning decision: an empty target returns [""], so classify("") is unresolved and parks. Returning []
    /// would land an entity with an empty target_space_uuid into a local row.
    func testEmptyTargetIsParkedNotLanded() {
        let payload = urlRulePayload(uuid: "r1e", targetSpaceUuid: "")
        XCTAssertEqual(URLRuleKind.ownerUuids(of: payload), [""])
        let plan = planned([arrival(payload)])
        XCTAssertTrue(plan.steps.isEmpty)
        XCTAssertEqual(plan.parked["r1e"]?.pendingOwnerUuid, "")
        XCTAssertEqual(plan.refused, 0)
    }

    // MARK: - CASE U-2 (reserved constants do not park)

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

    // MARK: - CASE U-3 (content merges as one unit)

    func testContentGroupMergesAsOneUnit() {
        var x = urlRulePayload(uuid: "r3", host: "a.com", pathPrefix: "/x", ask: false,
                               contentStamp: 100, targetStamp: 100, rankStamp: 100)
        // X has a newer ask stamp. Per-field LWW would combine X's false ask with Y's /y path into a rule
        // nobody wrote. Group comparison uses only the host carrier (100 < 200).
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

    // MARK: - CASE U-4 (host always carries the content stamp)

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
        // host stamp 100 loses the entire group to 300. Using max would incorrectly select 900 and win.
        XCTAssertEqual(a.host.stringValue, "flat.com")
        XCTAssertEqual(a.pathPrefix.stringValue, "/f")
        XCTAssertFalse(a.ask.boolValue)
        XCTAssertEqual(a.host.updatedAtMs, 300)
        XCTAssertEqual(a.pathPrefix.updatedAtMs, 300)
        XCTAssertEqual(a.ask.updatedAtMs, 300)

        // Variant: a target stamp newer than all three content fields cannot affect content selection
        // (R-M3-4a-40 channel isolation).
        var variant = uneven
        variant.targetSpaceUuid.updatedAtMs = 9_000
        let c = URLRuleKind.merge(local: variant, remote: flat)
        let d = URLRuleKind.merge(local: flat, remote: variant)
        XCTAssertEqual(c, d)
        XCTAssertEqual(c.host, a.host)
        XCTAssertEqual(c.pathPrefix, a.pathPrefix)
        XCTAssertEqual(c.ask, a.ask)
        XCTAssertEqual(URLRuleKind.contentSignature(of: c), URLRuleKind.contentSignature(of: a))
        XCTAssertEqual(c.targetSpaceUuid.updatedAtMs, 9_000, "The target channel uses its own stamp")
    }

    // MARK: - CASE U-5 (rank follows the winning target)

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
        XCTAssertEqual(ab.rank.stringValue, "M", "Rank follows the winning target even when the other rank stamp is newer")
        XCTAssertEqual(ab.rank.updatedAtMs, 200)

        // Three-way convergence: merge C after both (A,B) and (B,A).
        let c = urlRulePayload(uuid: "r5", targetSpaceUuid: "su-1", rank: "Q",
                               targetStamp: 150, rankStamp: 400)
        let abc = URLRuleKind.merge(local: ab, remote: c)
        let bac = URLRuleKind.merge(local: ba, remote: c)
        XCTAssertEqual(abc, bac)
        XCTAssertEqual(abc.targetSpaceUuid.stringValue, "su-2")
        XCTAssertEqual(abc.rank.stringValue, "M")
    }

    // MARK: - CASE U-5b (content and target edits both survive)

    func testAContentEditAndATargetEditBothSurviveTheMerge() {
        // A edits only host: content stamp 100, target and rank remain at 50.
        let a = urlRulePayload(uuid: "r5b", targetSpaceUuid: "su-1", host: "new.com", rank: "V",
                               contentStamp: 100, targetStamp: 50, rankStamp: 50)
        // B edits only target: target/rank stamps 200; old content remains at 50.
        let b = urlRulePayload(uuid: "r5b", targetSpaceUuid: "su-2", host: "old.com", rank: "M",
                               contentStamp: 50, targetStamp: 200, rankStamp: 200)

        let ab = URLRuleKind.merge(local: a, remote: b)
        let ba = URLRuleKind.merge(local: b, remote: a)
        XCTAssertEqual(ab, ba)
        XCTAssertEqual(ab.host.stringValue, "new.com", "A's host survives")
        XCTAssertEqual(ab.host.updatedAtMs, 100)
        XCTAssertEqual(ab.targetSpaceUuid.stringValue, "su-2", "B's target survives")
        XCTAssertEqual(ab.targetSpaceUuid.updatedAtMs, 200)
        XCTAssertEqual(ab.rank.stringValue, "M", "Different targets make rank follow the winning target")
    }

    // MARK: - CASE U-6 (normalization fixed point, kind coverage)

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
            // Each first-pass entity exactly matches a direct LocalStore.normalizedRule call.
            let direct = LocalStore.normalizedRule(host: raw.host.stringValue,
                                                   pathPrefix: wirePath.isEmpty ? nil : wirePath)
            XCTAssertEqual(item.entity.host.stringValue, direct.host, raw.host.stringValue)
            XCTAssertEqual(item.entity.pathPrefix.stringValue, direct.pathPrefix ?? "", wirePath)
            // Leave all three stamps unchanged.
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
        XCTAssertTrue(first.normalized.contains("h0"), "\"GitHub.COM\" changed")
        XCTAssertFalse(first.normalized.contains("p1"), "\"/\" is already a fixed point")

        // Feed first-pass output back in: no normalized identities and identical bytes.
        let second = normalized(first.arrivals)
        XCTAssertTrue(second.normalized.isEmpty)
        XCTAssertEqual(second.arrivals.map(\.entity), first.arrivals.map(\.entity))
        XCTAssertEqual(second.arrivals.map { baselineBytes($0.entity) },
                       first.arrivals.map { baselineBytes($0.entity) })

        // Three concrete values read through arrivals.
        let byUuid = Dictionary(uniqueKeysWithValues: first.arrivals.map { ($0.entity.ruleUuid, $0.entity) })
        XCTAssertEqual(byUuid["p3"]?.pathPrefix.stringValue, "/", "f(\"/%2F\") == \"/\", not nil or \"//\"")
        XCTAssertEqual(byUuid["p2"]?.pathPrefix.stringValue, "/foo", "f(\"/foo%2F\") == \"/foo\"")
        XCTAssertEqual(byUuid["p5"]?.pathPrefix.stringValue, "/a%252F", "f(\"/a%252F\") is already a fixed point")
        XCTAssertEqual(byUuid["h9"]?.host.stringValue, "*.figma.com")
        XCTAssertEqual(byUuid["h6"]?.host.stringValue, "a")

        // Wire empty string and local nil round-trip both ways. Whitespace normalizes to nil and writes an
        // empty wire value, counting once. An existing empty wire value passes nil to normalization and
        // remains unchanged without counting.
        let blank = normalized([arrival(urlRulePayload(uuid: "blank", pathPrefix: "   "))])
        XCTAssertEqual(blank.arrivals[0].entity.pathPrefix.stringValue, "")
        XCTAssertEqual(blank.normalized, ["blank"])
        let empty = normalized([arrival(urlRulePayload(uuid: "empty", pathPrefix: ""))])
        XCTAssertEqual(empty.arrivals[0].entity.pathPrefix.stringValue, "")
        XCTAssertTrue(empty.normalized.isEmpty)
        // Slash and empty string differ: root-path matching must not collapse into any-path matching.
        let root = normalized([arrival(urlRulePayload(uuid: "root", pathPrefix: "/"))])
        XCTAssertEqual(root.arrivals[0].entity.pathPrefix.stringValue, "/")
        XCTAssertTrue(root.normalized.isEmpty)
    }

    // MARK: - CASE U-7 (normalize malformed arrivals instead of refusing them)

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
        XCTAssertEqual(entity.host.updatedAtMs, 500, "Not now")
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
        // The caller unions normalized into mustRepublish; the module's predicate stays false for
        // normalization alone.
        XCTAssertTrue(plan.mustRepublish.union(first.normalized).contains("r7"))

        // Second round: normalized baseline bytes mean an empty normalized set, no steps and no baseline
        // changes.
        table.cursors["r7"]?.reconciled = plan.steps.first?.payload
        let second = normalized(first.arrivals)
        XCTAssertTrue(second.normalized.isEmpty)
        let again = planned(second.arrivals, table: table)
        XCTAssertTrue(again.steps.isEmpty)
        XCTAssertTrue(again.rebaselined.isEmpty)
        XCTAssertEqual(again.refused, 0)
    }

    // MARK: - CASE U-8 (three structural refusals; valid IPv6 accepted)

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

    // MARK: - CASE U-9 (invalid rank never reaches precondition)

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

    // MARK: - CASE U-19 (three stamps for first publication without baseline)

    func testFirstPublicationStampsComeFromTheRowNotFromNow() throws {
        let local = PhiLocalURLRule.fixture(syncId: "r19",
                                            createdDate: Date(timeIntervalSince1970: 1_000),
                                            contentUpdatedDate: nil, targetUpdatedDate: nil)
        let projected = try XCTUnwrap(URLRuleKind.project(local, resolve: resolve, scope: nil,
                                                          parentIdentity: nil))
        XCTAssertEqual(projected.ruleUuid, "r19")
        XCTAssertEqual(projected.targetSpaceUuid.stringValue, "su-1")
        XCTAssertEqual(projected.rank.stringValue, "", "Projection leaves rank empty")

        let stamped = URLRuleKind.stamp(projected, baseline: nil, local: local, rank: "V",
                                        now: 5_000_000)
        XCTAssertEqual(stamped.rank.stringValue, "V")
        XCTAssertEqual(stamped.host.updatedAtMs, 1_000_000, "Equals createdDate in milliseconds")
        XCTAssertEqual(stamped.pathPrefix.updatedAtMs, 1_000_000)
        XCTAssertEqual(stamped.ask.updatedAtMs, 1_000_000)
        XCTAssertEqual(stamped.targetSpaceUuid.updatedAtMs, 1_000_000)
        XCTAssertEqual(stamped.rank.updatedAtMs, 0)
        XCTAssertEqual(URLRuleKind.locationStamp(of: stamped), 1_000_000)

        // Variant: the user edited target but never content, so the two stamps differ.
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

    // MARK: - CASE U-23 (A9: only target changes cancel local deletion)

    func testOnlyATargetChangeCancelsALocalDeletion() {
        let baseline = urlRulePayload(uuid: "r23", targetSpaceUuid: "su-1", host: "old.com",
                                      contentStamp: 50, targetStamp: 50, rankStamp: 50)
        var table = PhiOwnedItemTable()
        table.cursors["r23"] = pendingDeleteCursor(decidedAtMs: 100, reconciled: baselineBytes(baseline))

        // (a) Host-only edit: content stamp 200 is newer than the deletion decision, but target is unchanged;
        // local deletion wins.
        let contentOnly = urlRulePayload(uuid: "r23", targetSpaceUuid: "su-1", host: "new.com",
                                         contentStamp: 200, targetStamp: 50, rankStamp: 50)
        let a = planned([arrival(contentOnly)], table: table)
        XCTAssertEqual(a.supersededByDelete, 1)
        XCTAssertTrue(a.cancelledDeletes.isEmpty)
        XCTAssertTrue(a.steps.isEmpty)

        // (b) Target edit: stamp 200 > 100 cancels deletion and produces move.
        let retargeted = urlRulePayload(uuid: "r23", targetSpaceUuid: "su-2", host: "old.com",
                                        contentStamp: 50, targetStamp: 200, rankStamp: 200)
        let b = planned([arrival(retargeted)], table: table)
        XCTAssertEqual(b.cancelledDeletes, ["r23"])
        XCTAssertEqual(b.supersededByDelete, 0)
        XCTAssertEqual(b.steps.map(\.kind), [.move])
        XCTAssertEqual(b.steps.first?.newOwnerUuid, "su-2")
        XCTAssertNil(b.steps.first?.newParentUuid)
    }

    // MARK: - CASE U-25 (baseline folding of created_at_ms / source)

    func testCreatedAtAndSourceFoldAgainstTheBaselineSoTheProjectionMatchesBytes() throws {
        let baseline = urlRulePayload(uuid: "r25", targetSpaceUuid: "su-1", host: "github.com",
                                      pathPrefix: "", ask: false, rank: "V",
                                      contentStamp: 100, targetStamp: 100, rankStamp: 100,
                                      source: 1, createdAtMs: 1_000)
        let local = PhiLocalURLRule.fixture(syncId: "r25", spaceId: "space-a", host: "github.com",
                                            createdDate: Date(timeIntervalSince1970: 2))
        let projected = try XCTUnwrap(URLRuleKind.project(local, resolve: resolve, scope: nil,
                                                          parentIdentity: nil))
        XCTAssertEqual(projected.createdAtMs, 2_000, "Projection emits the local column")
        XCTAssertEqual(projected.source, 0, "No local source column; always emit 0")

        let baselineBytes = try baseline.serializedData()
        for round in 1...2 {
            let stamped = URLRuleKind.stamp(projected, baseline: baseline, local: local,
                                            rank: URLRuleKind.rank(of: baseline),
                                            now: 9_000 + Int64(round))
            XCTAssertEqual(stamped.createdAtMs, 1_000, "round \(round)")
            XCTAssertEqual(stamped.source, 1, "round \(round)")
            XCTAssertEqual(try stamped.serializedData(), baselineBytes,
                           "round \(round): baseline bytes match, so no change and no commit")
        }

        // Milliseconds are rounded, not truncated.
        let rounded = URLRuleKind.project(PhiLocalURLRule.fixture(createdDate: Date(timeIntervalSince1970: 1.0015)),
                                          resolve: resolve, scope: nil, parentIdentity: nil)
        XCTAssertEqual(rounded?.createdAtMs, 1_002)
    }

    // MARK: - §8.2 / D33: edits with a baseline use row stamps, not now

    /// Controller ruling: spec §8.2 / D33 overrides the plan and BookmarkKind precedent for this kind.
    /// Publishing may happen rounds after an edit; snapshot now would let an earlier local edit defeat a
    /// genuinely later remote edit. Only derived rank, which has no row stamp, may use now.
    func testEditsAgainstABaselineCarryTheRowStampsNotNow() throws {
        let baseline = urlRulePayload(uuid: "rs", targetSpaceUuid: "su-1", host: "old.com",
                                      contentStamp: 100, targetStamp: 100, rankStamp: 100)
        let now: Int64 = 5_000_000

        // Host-only edit; row content stamp is 2_000 seconds.
        let edited = PhiLocalURLRule.fixture(syncId: "rs", spaceId: "space-a", host: "new.com",
                                             contentUpdatedDate: Date(timeIntervalSince1970: 2_000))
        let stampedEdit = URLRuleKind.stamp(
            try XCTUnwrap(URLRuleKind.project(edited, resolve: resolve, scope: nil, parentIdentity: nil)),
            baseline: baseline, local: edited, rank: "V", now: now)
        XCTAssertEqual(stampedEdit.host.updatedAtMs, 2_000_000, "Use the row stamp, not now")
        XCTAssertEqual(stampedEdit.pathPrefix.updatedAtMs, 2_000_000)
        XCTAssertEqual(stampedEdit.ask.updatedAtMs, 2_000_000)
        XCTAssertEqual(stampedEdit.targetSpaceUuid.updatedAtMs, 100, "Unchanged target keeps the baseline")
        XCTAssertEqual(stampedEdit.rank.updatedAtMs, 100, "Unchanged rank keeps the baseline")

        // Target-only edit; row target stamp is 3_000 seconds.
        let retargeted = PhiLocalURLRule.fixture(syncId: "rs", spaceId: "space-b", host: "old.com",
                                                 targetUpdatedDate: Date(timeIntervalSince1970: 3_000))
        let stampedRetarget = URLRuleKind.stamp(
            try XCTUnwrap(URLRuleKind.project(retargeted, resolve: resolve, scope: nil, parentIdentity: nil)),
            baseline: baseline, local: retargeted, rank: "V", now: now)
        XCTAssertEqual(stampedRetarget.targetSpaceUuid.stringValue, "su-2")
        XCTAssertEqual(stampedRetarget.targetSpaceUuid.updatedAtMs, 3_000_000, "Use the row stamp, not now")
        XCTAssertEqual(stampedRetarget.rank.updatedAtMs, now, "The bucket changed; only rank may use now")
        XCTAssertEqual(stampedRetarget.host.updatedAtMs, baseline.host.updatedAtMs)
        XCTAssertEqual(stampedRetarget.pathPrefix.updatedAtMs, baseline.host.updatedAtMs)
        XCTAssertEqual(stampedRetarget.ask.updatedAtMs, baseline.host.updatedAtMs)

        // Missing row stamps fall back to createdDate, as in the no-baseline branch, never now.
        let fallback = PhiLocalURLRule.fixture(syncId: "rs", spaceId: "space-a", host: "new.com",
                                               createdDate: Date(timeIntervalSince1970: 1_000))
        let stampedFallback = URLRuleKind.stamp(
            try XCTUnwrap(URLRuleKind.project(fallback, resolve: resolve, scope: nil, parentIdentity: nil)),
            baseline: baseline, local: fallback, rank: "V", now: now)
        XCTAssertEqual(stampedFallback.host.updatedAtMs, 1_000_000)
        XCTAssertEqual(stampedFallback.targetSpaceUuid.updatedAtMs, 100)
    }

    // MARK: - R-M3-4a-26: move carries newOwnerUuid

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
        XCTAssertNil(moved.steps.first?.newParentUuid, "Rules have no parent")

        // Pure reordering also produces move with the current target. The landing batch downgrades it to
        // reorder (Task 8).
        let reorder = urlRulePayload(uuid: "rm", targetSpaceUuid: "su-1", rank: "X", rankStamp: 200)
        let reordered = planned([arrival(reorder)], table: table)
        XCTAssertEqual(reordered.steps.map(\.kind), [.move])
        XCTAssertEqual(reordered.steps.first?.newOwnerUuid, "su-1")
        XCTAssertEqual(reordered.steps.first?.newRank, "X")
    }

    /// Bookmark move remains unchanged: default targetOwnerUuid(of:) returns nil, and the existing
    /// five-argument initializer without newOwnerUuid still works.
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
        // r-dead has the smallest rank; failing to exclude it reserves index 0 and shifts the entire bucket.
        let ranks = ["r-a": "M", "r-b": "M", "r-c": "V", "r-dead": "A"]
        let out = URLRuleKind.rankToSortOrder(siblings: rows, ranks: ranks)
        // Unranked rows come first; ties use ascending syncId ?? id; soft-deleted rows are excluded.
        XCTAssertEqual(out, ["i-new": 0, "i-a": 1, "i-b": 2, "i-c": 3])
        XCTAssertNil(out["i-dead"])
    }

    // MARK: - CASE U-R1 (resolver self-mapping for reserved constants)

    func testResolverSelfMapsTheReservedIncognitoConstant() {
        let resolver = OwnedOwnerMaps().resolver
        let reserved = SyncableSpaces.incognitoSpaceUuid
        XCTAssertEqual(reserved, "incognito-space")
        XCTAssertEqual(resolver.localProfileId(reserved), reserved)
        XCTAssertEqual(resolver.globalUuid(reserved), reserved)
        XCTAssertNil(resolver.localSpaceId(reserved), "localSpaceId remains unmapped")
        XCTAssertTrue(resolver.isEligibleSpace(reserved))
        // The four existing app resolutions are unchanged.
        XCTAssertEqual(resolver.localProfileId("app"), "app")
        XCTAssertEqual(resolver.globalUuid("app"), "app")
        XCTAssertNil(resolver.localSpaceId("app"))
        XCTAssertTrue(resolver.isEligibleSpace("app"))

        // Diff's mapped predicate recognizes the constant, allowing a user-deleted incognito rule to emit its
        // tombstone.
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

    // MARK: - §5.3 eligibilityOwner's three predicates

    func testEligibilityOwnerFollowsTheThreeCriteriaInOrder() {
        let incognito = PhiLocalURLRule.fixture(spaceId: SpaceManager.incognitoRuleTargetId)
        XCTAssertEqual(URLRuleKind.eligibilityOwner(of: incognito, resolve: resolve, scope: nil),
                       SyncableSpaces.incognitoSpaceUuid)
        let stale = PhiLocalURLRule.fixture(spaceId: SpaceManager.incognitoSpaceIdPrefix + ".ABC-123")
        XCTAssertNil(URLRuleKind.eligibilityOwner(of: stale, resolve: resolve, scope: nil),
                     "Expired incognito runtime IDs are ineligible")
        let unmapped = PhiLocalURLRule.fixture(spaceId: "space-agent")
        XCTAssertNil(URLRuleKind.eligibilityOwner(of: unmapped, resolve: resolve, scope: nil))
        XCTAssertNil(URLRuleKind.project(unmapped, resolve: resolve, scope: nil, parentIdentity: nil))
        // Hidden/purged checks belong elsewhere. Return mapped owners and let the module ask isEligibleSpace.
        let hidden = OwnerResolver.fixture(ineligible: ["su-1"])
        XCTAssertEqual(URLRuleKind.eligibilityOwner(of: PhiLocalURLRule.fixture(), resolve: hidden, scope: nil),
                       "su-1")
    }

    // MARK: - Task 8: URLRuleApplyBatch merge/downgrade value tests and FakeURLRuleAccess

    // CASE U-10b, value coverage: a move with unchanged target becomes reorder. Treating every move as rehome
    // needlessly reorders an untouched second bucket and triggers an extra push round through §6.5's
    // publisher.
    func testMoveWithUnchangedTargetIsDemotedToReorder() {
        let values = URLRuleLandingValues.fixture(syncId: "R1", spaceId: "S1", sortOrder: 2)
        let batch = URLRuleApplyBatch(unordered: [.move(values)], currentSpaceIds: ["R1": "S1"])
        XCTAssertEqual(batch.ops, [.reorder(syncId: "R1", spaceId: "S1", sortOrder: 2)])
    }

    // A changed target keeps move. Missing identity in this page's snapshot means unknown current ownership
    // and also uses rehome.
    func testMoveWithChangedOrUnknownTargetStaysAMove() {
        let values = URLRuleLandingValues.fixture(syncId: "R1", spaceId: "S2", sortOrder: 0)
        XCTAssertEqual(URLRuleApplyBatch(unordered: [.move(values)], currentSpaceIds: ["R1": "S1"]).ops,
                       [.move(values)])
        XCTAssertEqual(URLRuleApplyBatch(unordered: [.move(values)], currentSpaceIds: [:]).ops,
                       [.move(values)])
    }

    // CASE U-10e ①, value coverage: merge move + update for one identity into one move without losing content.
    // If target is unchanged, retain update to write content rather than reducing to reorder. Separate writes
    // can rewrite ownership after move into an unreordered bucket (R-M3-4a-42(b) / RR-B9); merging must also
    // retain update's content group.
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

    // Upserts precede deletes; preserve stable input order within each phase.
    func testBatchOrdersDeletesLastAndKeepsArrivalOrderWithinAPhase() {
        let a = URLRuleLandingValues.fixture(syncId: "A", spaceId: "S1", sortOrder: 0)
        let b = URLRuleLandingValues.fixture(syncId: "B", spaceId: "S1", sortOrder: 1)
        let batch = URLRuleApplyBatch(unordered: [.delete(syncId: "Z"), .update(a), .create(b),
                                                  .delete(syncId: "Y")])
        XCTAssertEqual(batch.ops, [.update(a), .create(b), .delete(syncId: "Z"), .delete(syncId: "Y")])
    }

    // CASE U-10e ③: one fake apply call per batch, R1 occurs once, and both buckets are dense.
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

    // CASE U-8r: both read entry points propagate the injected error; readError remains armed. Empty locals
    // would tombstone every cursor and erase account rules after one failed fetch (R-exec-3). A one-shot error
    // could let the second read succeed and hide failure to skip the whole section.
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

    // The fake's allURLRules filters soft-deleted rows; allURLRulesIncludingDeleted retains them. siblings and
    // isKnownLocalURLRule recognize only live syncId rows; liveOwners fills claimed only.
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

    // The fake mirrors production bucket entry: update revives a soft-deleted row at an occupied index and
    // reorders the target as a complete permutation (R-M3-4a-3 / RR-B9), preserving id/identity without
    // another row.
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

    // MARK: - Task 6: engine fixtures for the rule registration

    private static let now: Int64 = 1_700_000_000_000

    /// Paired device: space-a/b/c map to su-1/2/3, matching OwnerResolver.fixture(), with complete
    /// bidirectional profile mapping. Matches PhiSyncEngineOwnedItemsTests.makeSpaceAccess.
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

    /// hasDrainedFullReplay true means the device fully replayed this type and satisfies publication guard ①.
    private func drainedSpaceStore() -> MemorySpaceStore {
        let store = MemorySpaceStore()
        store.table.hasDrainedFullReplay = true
        return store
    }

    /// Match the client's birthday-1 so birthday persistence is always a no-op.
    private func markerStore(marker: String?) -> MemoryMarkerStore {
        MemoryMarkerStore(file: PhiSyncMarkerFile(marker: marker.map { Data($0.utf8) },
                                                  storeBirthday: "birthday-1"))
    }

    /// Separate defaults suite for CASE U-11's second engine.
    private func makeExtraDefaults() -> UserDefaults {
        let name = "URLRuleKindTests.extra.\(UUID().uuidString)"
        extraSuites.append(name)
        return UserDefaults(suiteName: name)!
    }

    /// Matches PhiSyncMarkerBoundaryTests.makeOwnedEngine with empty settings and frozen time. Task 9
    /// retention cases may supply an advancing PhiSyncEngineSpaceTests.Clock; otherwise use Self.now.
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

    /// Silence settings and Spaces as in PhiSyncMarkerBoundaryTests 2b-L1. Empty storedLastEntity skips
    /// settings; unreadableTagHashes makes guard 3 skip the three mapped Spaces. client.commits then measures
    /// only rules.
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

    /// Rule-tag commits only; settings and Spaces share the same commits list.
    private func ruleCommits(_ client: FakePhiSyncClient) -> [FakePhiSyncClient.CommitCall] {
        client.commits.filter { $0.name == PhiSyncEntity.urlRuleEntityName }
    }

    /// Decrypt the complete rule payload from a commit.
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

    /// Wait past debounce plus delivery slack for the main queue, matching
    /// LocalStoreURLRuleThrowingTests.waitPastDebounceWindow. This helper is synchronous because run(until:)
    /// cannot be called directly in an async context.
    private func waitPastDebounceWindow(_ window: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(window + 0.6))
    }

    /// A live published cursor with baseline, server metadata and known ownership.
    private func publishedRuleCursor(_ payload: Phi_PhiURLRuleEntity,
                                     entityId: String = "srv-1",
                                     version: Int64 = 1,
                                     owner: String = "su-1") -> PhiOwnedItemCursor {
        ownedCursor(reconciled: baselineBytes(payload), server: baselineBytes(payload),
                    entityId: entityId, version: version, ownerUuid: owner)
    }

    // MARK: - CASE U-17 (read failure must not become an empty row set)

    /// Guard against beginRound swallowing allURLRulesIncludingDeleted errors as []. Diff would tombstone
    /// every published account identity, propagating one SwiftData read failure into deletion on every device.
    func testALocalReadFailureNeverReadsAsZeroRows() async throws {
        let access = FakeURLRuleAccess(rows: [.fixture(id: "i1", syncId: "r1")])
        access.readError = LocalStoreWriteError.storeUnavailable       // Throws every time without auto-resetting
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
        XCTAssertEqual(store.saveCalls, 0, "No cursor-table bytes were written")
        XCTAssertEqual(applyCalls(access), 0)
        XCTAssertEqual(store.table.cursors["r1"]?.entityId, "srv-1")
    }

    // MARK: - CASE U-18 (lost cursor file triggers full-type replay)

    private struct LossFixture {
        let access: FakeURLRuleAccess
        let store: MemoryOwnedItemStore
        let spaceStore: MemorySpaceStore
        let markerStore: MemoryMarkerStore
        let client: FakePhiSyncClient
    }

    /// Shared fixture: two local rows, an empty MemoryOwnedItemStore (loss when hadRecords is true), and
    /// marker 5. Replay page watermark 3 is unavailable incrementally from 5 and reachable only from nil; it
    /// carries live r1 for (a).
    /// Silence other sections: otherwise the three mapped, cursorless Spaces commit before pushOwnedItems and
    /// skew (e)'s zero-commit assertion and (e)/(f) write counters. Even when silent, pushSpaces writes the
    /// table once on its empty-work branch; write ordinals include this.
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

    /// After arming loss replay: marker nil, drain armed, hasDrainedFullReplay false, per-kind latch set, and
    /// zero commits during replay.
    private func assertLossReplayArmed(_ f: LossFixture, file: StaticString = #filePath,
                                       line: UInt = #line) {
        XCTAssertNil(f.markerStore.file.marker, "storedMarker == nil", file: file, line: line)
        XCTAssertTrue(f.spaceStore.table.drainInProgress, file: file, line: line)
        XCTAssertFalse(f.spaceStore.table.hasDrainedFullReplay, file: file, line: line)
        XCTAssertTrue(f.spaceStore.table.urlRulesReplayedForEmptyTable, file: file, line: line)
        XCTAssertTrue(ruleCommits(f.client).isEmpty, "No commits during replay", file: file, line: line)
    }

    /// After replay: r1 matches the local identity and rebuilds its cursor; two rows remain with zero creates.
    private func assertReplayRebuiltTheCursorByIdentity(_ f: LossFixture, file: StaticString = #filePath,
                                                        line: UInt = #line) {
        XCTAssertNotNil(f.client.getUpdatesCalls.last, file: file, line: line)
        XCTAssertNil(f.client.getUpdatesCalls.last?.marker ?? nil, "Replay from scratch", file: file, line: line)
        XCTAssertEqual(f.access.rows.count, 2, "The row count remains 2", file: file, line: line)
        XCTAssertEqual(createCount(f.access.lastAppliedOps), 0, "No create operations", file: file, line: line)
        XCTAssertEqual(f.store.table.cursors["r1"]?.entityId, "srv-r1", "The cursor is rebuilt", file: file, line: line)
        XCTAssertNotNil(f.store.table.cursors["r1"]?.reconciled, file: file, line: line)
        XCTAssertFalse(ruleCommits(f.client).contains { $0.clientTagHash == ruleHash("r1") },
                       "r1 matches the account and needs no publication", file: file, line: line)
    }

    /// (a) urlRulesHadRecords true plus unset latch and reported loss arms replay during publication load.
    /// Next round starts from nil and matches r1. This catches sharing Space's permanent latch, relying on
    /// local syncId rows (always true for rules), and publishing during replay; guard ① on
    /// hasDrainedFullReplay is the zero-commit guarantee.
    func testALostCursorFileArmsOneReplayAndTheReplayRebuildsTheCursorByIdentity() async throws {
        let f = try makeLossFixture(hadRecords: true)
        let engine = makeLossEngine(f)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let outcome = await engine.lastRoundOutcomeForTesting
        XCTAssertEqual(outcome, .ok)
        assertLossReplayArmed(f)
        XCTAssertEqual(f.store.hadRecordsSeen, [true, true], "Loss is detected at round entry and publication")

        await engine.pullOnce()

        assertReplayRebuiltTheCursorByIdentity(f)
        XCTAssertFalse(f.spaceStore.table.urlRulesReplayedForEmptyTable,
                       "A successful load with a published cursor resets the latch (A2)")
    }

    /// (b) As (a), with the bookmark one-shot latch already consumed; the two latches are independent.
    func testALostCursorFileStillReplaysWhenTheBookmarkLatchIsAlreadySpent() async throws {
        let f = try makeLossFixture(hadRecords: true)
        f.spaceStore.table.bookmarksReplayedForEmptyTable = true
        let engine = makeLossEngine(f)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        assertLossReplayArmed(f)
        XCTAssertTrue(f.spaceStore.table.bookmarksReplayedForEmptyTable, "The bookmark latch is unaffected")

        await engine.pullOnce()

        assertReplayRebuiltTheCursorByIdentity(f)
    }

    /// (c) urlRulesHadRecords false means reported empty-store loss does not qualify: marker unchanged and no
    /// replay.
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
        XCTAssertEqual(f.client.getUpdatesCalls.first?.marker, Data("5".utf8), "No replay")
        XCTAssertTrue(f.markerStore.saves.isEmpty)
    }

    /// (d) As (c), with both local rows carrying syncId (R-M3-4a-23). Local syncId presence cannot be the
    /// predicate because every live rule has one.
    func testRowsWithSyncIdsDoNotTurnAnEmptyTableIntoALoss() async throws {
        let f = try makeLossFixture(hadRecords: false, withSyncIds: true)
        let engine = makeLossEngine(f)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        XCTAssertEqual(f.markerStore.file.marker, Data("5".utf8))
        XCTAssertFalse(f.spaceStore.table.drainInProgress)
        XCTAssertFalse(f.spaceStore.table.urlRulesReplayedForEmptyTable)
        XCTAssertEqual(f.client.getUpdatesCalls.map(\.marker), [Data("5".utf8)], "No replay")
    }

    /// (e), R-M3-4a-103 / Task 2b ruling 3b: failure to clear marker at step ① yields .cursorSaveFailed, one
    /// failure, unchanged disk marker/latch/drain flags and zero commits, with exactly one extra marker save
    /// attempt. Retry redetects loss and arms replay; the third round actually replays and matches r1.
    /// Documented negative control: setting latch before clearing marker would leave old marker 5 with armed
    /// drain. Next round's empty incremental page would falsely complete replay, and the consumed latch would
    /// block loss detection forever. The second-round latch and third-round replay assertions must fail under
    /// that order. Failure must return (table, false), not (table, true).
    func testAFailedMarkerClearLeavesTheLossUnarmedAndRetriggersNextRound() async throws {
        let f = try makeLossFixture(hadRecords: true)
        f.markerStore.failSaveOnCallNumber = 1          // The first marker write is loss-replay step ①
        let engine = makeLossEngine(f)
        await engine.setSpaceSyncEnabled(true)
        let spaceSavesBefore = f.spaceStore.saveCalls
        await engine.pullOnce()

        let outcome = await engine.lastRoundOutcomeForTesting
        let failures = await engine.lastRoundCursorSaveFailedCountForTesting
        XCTAssertEqual(outcome, .cursorSaveFailed)
        XCTAssertEqual(failures, 1)
        XCTAssertEqual(f.markerStore.file.marker, Data("5".utf8), "Unchanged byte for byte")
        XCTAssertFalse(f.spaceStore.table.urlRulesReplayedForEmptyTable, "The latch remains unset")
        XCTAssertFalse(f.spaceStore.table.drainInProgress, "Unchanged from round entry")
        XCTAssertTrue(f.spaceStore.table.hasDrainedFullReplay, "Unchanged from round entry")
        XCTAssertTrue(f.client.commits.filter { $0.clientTagHash != PhiSyncEntity.settingsClientTagHash }.isEmpty,
                      "None of the five kinds publishes")
        XCTAssertEqual(f.markerStore.saves.count, 1, "Exactly one failed save attempt; the landing-side load wrote nothing")
        // Exactly two Space writes: page 1's unconditional write (#1), then silent pushSpaces' empty-work
        // write (#2) before pushOwnedItems. No third write means step ② did not run.
        XCTAssertEqual(f.spaceStore.saveCalls - spaceSavesBefore, 2)
        XCTAssertTrue(f.store.table.cursors.isEmpty, "No publication against the lost table or recreation of its file")

        f.markerStore.failSaveOnCallNumber = nil
        await engine.pullOnce()

        let second = await engine.lastRoundOutcomeForTesting
        XCTAssertEqual(second, .ok, "Loss detection triggers again and both persistence steps succeed")
        assertLossReplayArmed(f)

        await engine.pullOnce()

        assertReplayRebuiltTheCursorByIdentity(f)
    }

    /// (f), R-M3-4a-103: clearing marker succeeds but step ② mutateSpaceTable fails. Disk marker is nil;
    /// R-M3-4a-83 rollback leaves latch false and both drain flags unchanged, with .cursorSaveFailed and zero
    /// commits.
    /// Next round, nil marker makes guard 1 arm drain at entry (R-M3-4a-89). Replay matches r1 and rebuilds
    /// the cursor before publication loads it, so loss no longer triggers and no latch is needed. The next
    /// empty-account case covers the alternative where step ① is an idempotent no-op and step ② retries
    /// successfully.
    func testAFailedLatchWriteAfterAClearedMarkerStillEndsInAFullReplay() async throws {
        let f = try makeLossFixture(hadRecords: true)
        let engine = makeLossEngine(f)
        await engine.setSpaceSyncEnabled(true)
        // Space write order: page 1 unconditional write (#1), silent pushSpaces empty-work write (#2),
        // loss-replay step ② (#3).
        f.spaceStore.failSaveOnCallNumber = f.spaceStore.saveCalls + 3
        await engine.pullOnce()

        let outcome = await engine.lastRoundOutcomeForTesting
        let failures = await engine.lastRoundCursorSaveFailedCountForTesting
        XCTAssertEqual(outcome, .cursorSaveFailed)
        XCTAssertEqual(failures, 1)
        XCTAssertNil(f.markerStore.file.marker, "Step ① succeeded")
        XCTAssertFalse(f.spaceStore.table.urlRulesReplayedForEmptyTable, "Step ② failed, leaving the latch false")
        XCTAssertFalse(f.spaceStore.table.drainInProgress, "Unchanged from round entry")
        XCTAssertTrue(f.spaceStore.table.hasDrainedFullReplay, "Unchanged from round entry")
        XCTAssertTrue(ruleCommits(f.client).isEmpty)
        XCTAssertTrue(f.store.table.cursors.isEmpty)

        f.spaceStore.failSaveOnCallNumber = nil
        await engine.pullOnce()

        let second = await engine.lastRoundOutcomeForTesting
        let secondFailures = await engine.lastRoundCursorSaveFailedCountForTesting
        XCTAssertEqual(second, .ok)
        XCTAssertEqual(secondFailures, 0)
        assertReplayRebuiltTheCursorByIdentity(f)
        XCTAssertTrue(f.spaceStore.table.hasDrainedFullReplay, "Replay drained")
        XCTAssertFalse(f.store.load(hadRecords: true).reportedLoss, "The cursor file is rebuilt and no longer reports loss")
    }

    /// Other half of (f): with an empty rule replay page, next round redetects loss idempotently. Step ①'s
    /// updated == markerState returns without another save or failure; step ② succeeds, setting the latch and
    /// arming drain.
    func testAFailedLatchWriteIsRetriedWithAnIdempotentMarkerClear() async throws {
        let f = try makeLossFixture(hadRecords: true, replayPage: false)
        let engine = makeLossEngine(f)
        await engine.setSpaceSyncEnabled(true)
        // Same ordinals: page write #1, pushSpaces write #2, step ② #3.
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
        XCTAssertEqual(f.markerStore.saves.count, markerSavesAfterFirstRound, "Step ① returns without writing")
        assertLossReplayArmed(f)
    }

    // MARK: - CASE U-24 (explicit Chromium routing refresh after landing, engine coverage)

    /// Landing a host-only edit produces exactly one refreshRoutingTable after apply(opCount: 1), and the
    /// fake's rows already contain the new host at refresh. Relying on urlRulesPublisher fails because
    /// removeDuplicates compares the same in-place SwiftData instances and can swallow the edit.
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
        XCTAssertEqual(refreshCalls(access), 1, "Exactly one call")
        let applyIndex = try XCTUnwrap(access.calls.firstIndex(of: .apply(opCount: 1)))
        let refreshIndex = try XCTUnwrap(access.calls.firstIndex(of: .refreshRoutingTable))
        XCTAssertLessThan(applyIndex, refreshIndex, "Follows the apply call")
        XCTAssertEqual(access.rows.first?.host, "new.example", "Rows contain the new value at refresh time")
        XCTAssertEqual(access.rows.count, 1)
        XCTAssertEqual(createCount(access.lastAppliedOps), 0)
    }

    /// ③ Two entities on a page still refresh once: per page, not per row.
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

        XCTAssertEqual(applyCalls(access), 1, "One batch per page")
        XCTAssertEqual(refreshCalls(access), 1, "One refresh per page")
        XCTAssertEqual(Set(access.rows.map(\.host)), ["new1.example", "new2.example"])
    }

    /// ④ A failed landing batch never refreshes, avoiding a routing table inconsistent with storage.
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
        XCTAssertEqual(refreshCalls(access), 0, "Refreshing after failed landing would expose a table inconsistent with storage")
        XCTAssertEqual(counters?.applied, 0)
        XCTAssertEqual(counters?.parked, 1, "Park the whole batch for next-round retry")
        XCTAssertEqual(access.rows.first?.host, "old.example")
    }

    // MARK: - CASE U-16 (landing echoes do not produce another commit)

    /// Land content and rank changes, reordering the space-a bucket, then simulate urlRuleChangesPublisher's
    /// expected emission. The echo round has zero commits, zero row writes, pushed 0 and no new routing
    /// refresh. Persisting reconciled in the landing round prevents two devices repeatedly republishing each
    /// other's changes. The engine must not call handleLocalOwnedChange from landing; §6.5 echo suppression
    /// relies on the durable baseline.
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
        // Change host and rank V → X, after r2: update + move require full-bucket reordering.
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
        XCTAssertEqual(access.siblings(inSpaceId: "space-a").map(\.syncId), ["r2", "r1"], "Reorder the entire bucket")
        XCTAssertEqual(applyCalls(access), 1)
        XCTAssertEqual(refreshCalls(access), 1)
        XCTAssertTrue(client.commits.isEmpty, "No commits in the landing round")

        await engine.handleLocalOwnedChange(label: "urlrules")

        let counters = await engine.lastOwnedRoundCountersForTesting["urlrules"]
        XCTAssertEqual(counters?.pushed, 0)
        XCTAssertEqual(counters?.tombstones, 0)
        XCTAssertEqual(counters?.pendingPublish, 0)
        XCTAssertTrue(client.commits.isEmpty, "No commits in the echo round")
        // 8b-2 / R-M3-4a-56: the echo round's pre-push pull has no rule steps but still runs a matching
        // transaction for M2's tail hook, increasing apply count from 1 to 2. The empty batch writes no rows;
        // zero commits and one total refresh verify that (CASE M-7 / M-35).
        XCTAssertEqual(applyCalls(access), 2, "The echo page has no landing operations but its empty transaction still runs M2")
        XCTAssertEqual(access.lastAppliedOps.count, 0, "The echo batch has no landing operations")
        XCTAssertEqual(refreshCalls(access), 1, "Only the original landing refresh remains; M2 wrote nothing and did not refresh")
    }

    // MARK: - CASE U-27 (urlrules counter fields and gating)

    /// Check logOwnedRounds formatting: urlrules omits the three adoption and two scope fields, ending with
    /// six rule-specific fields. bookmarks lacks normalized and keeps adopted immediately after tombstones;
    /// pins has neither group. This catches inferred !reportsAdoption && !reportsScope gating that fails with
    /// a sixth kind, or placing rule fields under reportsAdoption and polluting bookmark logs.
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

    /// Engine coverage registers all three kinds and produces nonzero normalized/ownerMoved: r1 moves su-1 →
    /// su-2, and r9 arrives with an unnormalized host.
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
        XCTAssertEqual(access.rows.first { $0.syncId == "r1" }?.spaceId, "space-b", "Rehome landed")
        XCTAssertEqual(access.rows.first { $0.syncId == "r9" }?.host, "example.com", "Landed after normalization")
    }

    // MARK: - CASE U-28 (registration order determines processing; rules last)

    /// A page with one bookmark, pin and rule must persist in bookmarks/pins/urlrules order, observed by
    /// RecordingSpaceStore below. ownedKinds matches the coordinator literal; beginOwnedRound and page-loop
    /// iteration have no per-kind branching (§6.2). Inserting rules before pins would make B2-7b miss the
    /// final-kind crash window while still passing.
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

    // MARK: - CASE U-29 (local writes schedule one localOwnedChange; store owns debounce)

    /// Use real LocalStore and urlRuleChangesPublisher(debounceWindow:) with the coordinator's plain sink and
    /// registration label. Three writes within 20 ms yield one urlrules call; after cancellation and clearing
    /// the label, another write yields none. A second coordinator debounce adds a four-second delay;
    /// subscribing to model-based urlRulesPublisher can swallow in-place field edits (§6.5(1)); teardown must
    /// cancel the third subscription too.
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
                // The coordinator invokes await self?.phiSyncEngine?.handleLocalOwnedChange(label: label)
                // here.
                if let label { received.append(label) }
            }

        for index in 0..<3 {
            try await store.applyURLRuleEditsThrowing(
                upserts: [LocalStore.URLRuleDraft(id: "u29-\(index)", host: "u29-\(index).example",
                                                  spaceId: "space-a")],
                deletedIds: [])
        }
        waitPastDebounceWindow(window)
        XCTAssertEqual(received, ["urlrules"], "Three writes coalesce into one round with the registration label")

        // stopPhiSync cancels the subscription, sets it to nil and clears the label.
        cancellable?.cancel()
        cancellable = nil
        label = nil
        try await store.applyURLRuleEditsThrowing(
            upserts: [LocalStore.URLRuleDraft(id: "u29-late", host: "late.example", spaceId: "space-a")],
            deletedIds: [])
        waitPastDebounceWindow(window)
        XCTAssertEqual(received, ["urlrules"], "No calls after teardown")
        XCTAssertNil(cancellable)
    }

    // MARK: - CASE U-30 (NOT_MY_BIRTHDAY clears urlRulesReplayedForEmptyTable)

    /// Changing stores clears the replay latch, server metadata, rekeyRejectRounds and marker while retaining
    /// urlRulesHadRecords and reconciled. deletedAtMs matches bookmark CASE 6.18/6.21, preventing publication
    /// from refreshing keys or emitting tombstones so assertions isolate reset. An uncleared latch blocks
    /// future lost-file replay; clearing HadRecords loses detection, and clearing reconciled permits blind
    /// account overwrites.
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
        XCTAssertTrue(spaceStore.table.urlRulesHadRecords, "Records prior publication by this device; changing stores does not alter it")
        let landed = try XCTUnwrap(store.table.cursors["r1"])
        XCTAssertEqual(landed.entityId, "")
        XCTAssertEqual(landed.version, 0)
        XCTAssertNil(landed.server)
        XCTAssertNil(landed.rekeyRejectRounds)
        XCTAssertEqual(landed.reconciled, reconciled, "reconciled remains unchanged")
        XCTAssertNil(markerStore.file.marker)
    }

    // MARK: - CASE U-31 (closed gate skips the entire rule section)

    /// With spaceSectionEnabled false, two local rules (one edited) and an inbound rule yield .gated, four
    /// zero counters, no access calls including reads, and zero store saves. logOwnedRounds also gates all
    /// kind logs, though it has no test surface. Account rules must not publish from an incompletely paired
    /// device (§6.4 prerequisite 3).
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
        // Keep the gate closed; do not call setSpaceSyncEnabled(true).
        await engine.pullOnce()

        let outcome = await engine.lastRoundOutcomeForTesting
        let counters = await engine.lastOwnedRoundCountersForTesting["urlrules"]
        XCTAssertEqual(outcome, .gated)
        XCTAssertEqual(counters?.pulled ?? 0, 0)
        XCTAssertEqual(counters?.applied ?? 0, 0)
        XCTAssertEqual(counters?.pushed ?? 0, 0)
        XCTAssertEqual(counters?.tombstones ?? 0, 0)
        XCTAssertTrue(access.calls.isEmpty, "Even allURLRulesIncludingDeleted() was not called")
        XCTAssertEqual(store.saveCalls, 0)
        XCTAssertTrue(ruleCommits(client).isEmpty)
        XCTAssertEqual(access.rows.count, 2)
    }

    // MARK: - CASE U-11 (concurrent target edits converge to one rule)

    /// Two engines share a fake client and X's published baseline. A targets S2 at 100 ms; B targets S3 at 200
    /// ms. A updates to v+1; B's scripted conflict triggers retry limited to X with base_version v+1 and
    /// winning target S3. A then pulls S3. Each device retains one row and the account one phi-urlrule entity;
    /// two more rounds push nothing.
    /// This engine probe for D33 catches whole-table conflict retries, unrelated identities in commits,
    /// overwriting with stale local targets, and duplicate entities instead of target-unit LWW convergence.
    func testConcurrentTargetEditsConvergeToTheNewerTargetThroughAScopedConflictRetry() async throws {
        let baseline = urlRulePayload(uuid: "x1", targetSpaceUuid: "su-1",
                                      contentStamp: 50, targetStamp: 50, rankStamp: 50)
        let client = FakePhiSyncClient()
        client.seed(tagHash: ruleHash("x1"),
                    ciphertext: try PhiEntityCodec.encrypt(envelope(baseline), key: key),
                    version: 10, entityId: "srv-x1")

        // A: X is in space-b (su-2), target stamp 100 ms.
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
        // B: X is in space-c (su-3), target stamp 200 ms, with its own defaults and store.
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

        // A publishes first: one update at base_version v, producing X at S2/v+1.
        await engineA.handleLocalOwnedChange(label: "urlrules")
        let commitsAfterA = ruleCommits(client)
        XCTAssertEqual(commitsAfterA.count, 1)
        XCTAssertEqual(commitsAfterA.first?.baseVersion, 10)
        XCTAssertEqual(committedRule(commitsAfterA[0])?.targetSpaceUuid.stringValue, "su-2")
        let serverAfterA = try XCTUnwrap(client.stored[ruleHash("x1")]?.version)
        XCTAssertGreaterThan(serverAfterA, 10)

        // B pulls A's S2 target; LWW keeps local S3 (200), requiring republication. The first commit
        // conflicts, followed by one pull and an X-only retry.
        client.conflictOnceForTagHashes = [ruleHash("x1")]
        await engineB.handleLocalOwnedChange(label: "urlrules")
        let commitsB = Array(ruleCommits(client).dropFirst())
        XCTAssertEqual(commitsB.count, 2, "One conflict and one scoped retry")
        XCTAssertEqual(commitsB.map(\.clientTagHash), [ruleHash("x1"), ruleHash("x1")], "Scoped retry contains only X")
        XCTAssertEqual(commitsB.last?.baseVersion, serverAfterA, "base_version == v+1")
        let republished = try XCTUnwrap(commitsB.last.flatMap(committedRule))
        XCTAssertEqual(republished.targetSpaceUuid.stringValue, "su-3", "200 > 100, so S3 wins")
        XCTAssertEqual(republished.targetSpaceUuid.updatedAtMs, 200)
        let fromA = try XCTUnwrap(committedRule(commitsAfterA[0]))
        XCTAssertEqual(URLRuleKind.contentSignature(of: republished), URLRuleKind.contentSignature(of: fromA),
                       "Content group matches A")
        let countersB = await engineB.lastOwnedRoundCountersForTesting["urlrules"]
        XCTAssertEqual(countersB?.pendingPublish, 0)
        XCTAssertEqual(accessB.rows.count, 1)
        XCTAssertEqual(accessB.rows.first?.spaceId, "space-c")

        // A then pulls X at S3 and applies one move to space-c.
        await engineA.pullOnce()
        let countersA = await engineA.lastOwnedRoundCountersForTesting["urlrules"]
        XCTAssertEqual(countersA?.ownerMoved, 1)
        XCTAssertEqual(accessA.rows.count, 1)
        XCTAssertEqual(accessA.rows.first?.spaceId, "space-c")
        XCTAssertEqual(accessA.rows.first?.id, "ia", "Rehome preserves the physical row")
        XCTAssertEqual(ruleCommits(client).count, 3, "No new commits after A lands")
        XCTAssertTrue(ruleCommits(client).allSatisfy { $0.clientTagHash == ruleHash("x1") },
                      "The account still has one entity")

        // Two more rounds: neither device pushes or tombstones; total commits stay unchanged.
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

    // MARK: - Task 9: lifecycle fixtures

    private static let dayMs: Int64 = 24 * 60 * 60 * 1000

    private func spaceHash(_ uuid: String) -> String {
        PhiSyncEntity.clientTagHash(for: PhiSyncEntity.spaceClientTag(uuid))
    }

    /// Remote-soft-deleted Space cursor: hidden and deletedAtMs coexist, preserving the Space invariant, and
    /// the mapping remains (R-D6-10).
    private func hiddenSpaceCursor(deletedAtMs: Int64) -> PhiSpaceCursor {
        var cursor = PhiSpaceCursor()
        cursor.entityId = "srv-space-1"
        cursor.version = 4
        cursor.hidden = true
        cursor.deletedAtMs = deletedAtMs
        return cursor
    }

    /// Seed the real fake-client entity: updates require matching stored hash/entityId and baseVersion or
    /// tombstones fail invalidMessage. Match publishedRuleCursor's srv-<uuid> ID.
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

    /// Three published rules in Space S (space-a → su-1). rowsDeleted models local user deletion: no
    /// SpaceModel row, ineligible su-1, retained mapping and three soft-deleted rules, as left by Task 5
    /// deleteSpaceCascade(origin: .userIntent). published false gives never-published cursors with reconciled
    /// nil.
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
        // The user deleted S: no row, but its mapping remains.
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

    // MARK: - CASE U-12 (no tombstones during Space soft deletion or purge)

    /// Two live rules target hidden/purged su-1. A round produces no tombstones or
    /// pendingDelete/deleteDecidedAtMs. Followers must not delete on the originator's behalf. Correctness
    /// comes from unfiltered locals and identity always returning syncId: liveIdentities blocks predicate 3.
    /// Filtering hidden owners would defeat that protection and rely on a differently directed eligibility
    /// gate; purge may already have removed the mapping.
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
        // makeSpaceAccess retains its default space-a → su-1 mapping.
        let engine = makeEngine(client: client, markerStore: markerStore(marker: "9"),
                                spaceStore: spaceStore,
                                ownedKinds: [.urlRules(access: access, store: store)])
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let counters = await engine.lastOwnedRoundCountersForTesting["urlrules"]
        XCTAssertEqual(counters?.tombstones, 0, "\(label): no follower tombstones")
        XCTAssertTrue(ruleTombstones(client).isEmpty, "\(label): commits contain no rule tombstones")
        for identity in ["r1", "r2"] {
            XCTAssertEqual(store.table.cursors[identity]?.pendingDelete, false, label)
            XCTAssertEqual(store.table.cursors[identity]?.deleteDecidedAtMs, 0, "\(label): no deletion decision was written")
        }
        XCTAssertEqual(access.rows.count, 2, "\(label): both rows remain")
        XCTAssertTrue(access.hardDeleteCalls.isEmpty, label)
    }

    func testAHiddenTargetSpaceNeverYieldsAFollowerTombstone() async throws {
        try await assertNoFollowerTombstone(spaceCursor: hiddenSpaceCursor(deletedAtMs: Self.now),
                                            "hidden")
    }

    func testAPurgedTargetSpaceNeverYieldsAFollowerTombstone() async throws {
        try await assertNoFollowerTombstone(spaceCursor: purgedSpaceCursor(), "purged")
    }

    // MARK: - CASE U-13 (local Space deletion soft-deletes rules; origin (b) publishes tombstones)

    /// Local user deletion leaves su-1 ineligible but mapped and three soft-deleted rules. One round emits
    /// exactly three matching tombstones, pushed 0 and one-time deletion decisions; applied acknowledgements
    /// hard-delete all three rows through exit 1.
    /// MOD-2 / R-M3-4a-78 negative controls: implementing only origin (a), without explicitDeletions, skips
    /// all three at eligibility and creates undeletable account orphans; replacing soft deletion with
    /// context.delete removes deletedDate evidence, making both origins miss them.
    func testALocallyDeletedSpaceSendsOneTombstonePerSoftDeletedRuleAndHardDeletesTheRows() async throws {
        let f = try makeDeletedSpaceFixture()
        let engine = makeLifecycleEngine(f)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let tombstones = ruleTombstones(f.client)
        XCTAssertEqual(tombstones.count, 3, "① Exactly three rule tombstones")
        XCTAssertEqual(Set(tombstones.map(\.clientTagHash)), Set(["r1", "r2", "r3"].map(ruleHash)),
                       "① clientTagHash matches those three syncIds")
        XCTAssertEqual(ruleCommits(f.client).count, 3, "① No rule commits besides tombstones")
        let counters = await engine.lastOwnedRoundCountersForTesting["urlrules"]
        XCTAssertEqual(counters?.tombstones, 3, "②")
        XCTAssertEqual(counters?.pushed, 0, "④ Soft-deleted rows are excluded from the snapshot")
        for identity in ["r1", "r2", "r3"] {
            let cursor = try XCTUnwrap(f.store.table.cursors[identity])
            XCTAssertEqual(cursor.deleteDecidedAtMs, Self.now, "③ The deletion decision timestamp persisted")
            XCTAssertFalse(cursor.pendingDelete, "③ Finalize after applied")
            XCTAssertNotNil(cursor.deletedAtMs)
            XCTAssertNil(cursor.reconciled)
        }
        XCTAssertTrue(f.access.rows.isEmpty, "⑤ Exit 1 removes all three soft-deleted rows after applied")
        XCTAssertEqual(f.access.hardDeleteCalls, ["r1", "r2", "r3"], "⑤ Exactly those three syncIds")

        // A second round preserves the original deletion decision timestamp and sends no second batch.
        await engine.pullOnce()
        XCTAssertEqual(ruleTombstones(f.client).count, 3)
        for identity in ["r1", "r2", "r3"] {
            XCTAssertEqual(f.store.table.cursors[identity]?.deleteDecidedAtMs, Self.now, "③ The value is unchanged in round two")
        }
        XCTAssertEqual(f.access.hardDeleteCalls.count, 3, "No further hard deletion in round two")
    }

    /// U-13 follower variant: the same missing Space row and retained mapping, but no local delete. Three
    /// deletedDate-nil rows produce no tombstones; origin (b) requires deletedDate != nil.
    func testAFollowerWithLiveRowsSendsNoTombstoneForAnIneligibleSpace() async throws {
        let f = try makeDeletedSpaceFixture(rowsDeleted: false)
        let engine = makeLifecycleEngine(f)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let counters = await engine.lastOwnedRoundCountersForTesting["urlrules"]
        XCTAssertEqual(counters?.tombstones, 0)
        XCTAssertTrue(ruleTombstones(f.client).isEmpty)
        XCTAssertEqual(f.access.rows.count, 3, "All three rows remain")
        XCTAssertTrue(f.access.rows.allSatisfy { $0.deletedDate == nil })
        XCTAssertTrue(f.access.hardDeleteCalls.isEmpty)
        for identity in ["r1", "r2", "r3"] {
            XCTAssertEqual(f.store.table.cursors[identity]?.pendingDelete, false)
        }
    }

    /// U-13 reconciled-nil variant: never-published soft-deleted rows emit no tombstones because origin (b)
    /// requires a real account entity (predicate 1). Without applied acknowledgement, exit 1 leaves the rows
    /// alone.
    func testASoftDeletedRuleThatNeverReachedTheAccountSendsNoTombstone() async throws {
        let f = try makeDeletedSpaceFixture(published: false)
        let engine = makeLifecycleEngine(f)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()

        let counters = await engine.lastOwnedRoundCountersForTesting["urlrules"]
        XCTAssertEqual(counters?.tombstones, 0)
        XCTAssertTrue(ruleCommits(f.client).isEmpty, "No rule commits")
        XCTAssertEqual(f.access.rows.count, 3, "Soft-deleted rows remain unchanged for exit 2")
        XCTAssertTrue(f.access.hardDeleteCalls.isEmpty)
    }

    /// RR-B6 restart probe: a normal commit error, neither conflict nor NOT_MY_BIRTHDAY, models termination
    /// after diff but before tombstone application. A new engine sharing access/store sees all three
    /// soft-deleted rows, republishes tombstones and hard-deletes them. Deletion intent is durable on
    /// row.deletedDate; the cursor is only its projection and cannot be the sole record.
    func testTheDeletionIntentSurvivesARestartBetweenTheDiffAndTheApplied() async throws {
        struct Boom: Error {}
        let f = try makeDeletedSpaceFixture()
        f.client.commitErrorOnce = Boom()
        let first = makeLifecycleEngine(f)
        await first.setSpaceSyncEnabled(true)
        await first.pullOnce()

        XCTAssertEqual(f.access.rows.count, 3, "No first-round applied acknowledgement; all three soft-deleted rows remain")
        XCTAssertTrue(f.access.rows.allSatisfy { $0.deletedDate != nil })
        XCTAssertTrue(f.access.hardDeleteCalls.isEmpty, "Exit 1 requires applied acknowledgement")
        for identity in ["r1", "r2", "r3"] {
            XCTAssertEqual(f.store.table.cursors[identity]?.pendingDelete, true, "The deletion decision persisted")
            XCTAssertEqual(f.store.table.cursors[identity]?.deleteDecidedAtMs, Self.now)
            XCTAssertNil(f.store.table.cursors[identity]?.deletedAtMs)
        }
        first.shutdown()

        let second = makeLifecycleEngine(f)
        await second.setSpaceSyncEnabled(true)
        await second.pullOnce()

        let counters = await second.lastOwnedRoundCountersForTesting["urlrules"]
        XCTAssertEqual(counters?.tombstones, 3, "The new engine publishes all three")
        XCTAssertTrue(f.access.rows.isEmpty, "Exit 1 hard-deletes after applied")
        XCTAssertEqual(f.access.hardDeleteCalls, ["r1", "r2", "r3"])
        for identity in ["r1", "r2", "r3"] {
            XCTAssertEqual(f.store.table.cursors[identity]?.deleteDecidedAtMs, Self.now, "Written only once")
            XCTAssertNotNil(f.store.table.cursors[identity]?.deletedAtMs)
        }
    }

    // MARK: - CASE U-13b (followers neither tombstone nor delete on the originator's behalf)

    /// Follower has three live rule rows and reconciled cursors. A page carries S's tombstone plus three rule
    /// updates. Space lands first and hides su-1; all rule targets become ineligible and park.
    private func makeFollowerFixture() throws -> LifecycleFixture {
        let f = try makeDeletedSpaceFixture(rowsDeleted: false)
        // The follower retains the Space row: remote soft deletion hides it without deleting it.
        f.spaceAccess.spaces = makeSpaceAccess().spaces
        // su-1 already landed, so its tombstone routes by hash to the cursor. Do not silence this section: it
        // must land normally, while silenceOtherSections only blocks commits.
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

    /// First round retains three live rows, zero tombstones and pendingApply for each. Their own inbound rule
    /// tombstones in round two hard-delete all three with applied 3 (R-M3-4a-41). A Space tombstone does not
    /// imply rule deletion; cascading soft delete would activate origin (b) and make the follower emit
    /// duplicate tombstones.
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

        XCTAssertEqual(f.spaceStore.table.cursors["su-1"]?.hidden, true, "The Space tombstone landed")
        XCTAssertEqual(f.access.rows.count, 3, "Round one: all three rows remain")
        XCTAssertTrue(f.access.rows.allSatisfy { $0.deletedDate == nil }, "Round one: no soft deletion")
        let first = await engine.lastOwnedRoundCountersForTesting["urlrules"]
        XCTAssertEqual(first?.tombstones, 0, "Round one: no follower tombstones")
        XCTAssertTrue(ruleTombstones(f.client).isEmpty)
        for identity in ["r1", "r2", "r3"] {
            XCTAssertNotNil(f.store.table.cursors[identity]?.pendingApply, "Round one: ineligible targets park")
        }
        XCTAssertTrue(f.access.hardDeleteCalls.isEmpty)

        await engine.pullOnce()

        XCTAssertTrue(f.access.rows.isEmpty, "Round two: inbound tombstones hard-delete all three rows")
        let second = await engine.lastOwnedRoundCountersForTesting["urlrules"]
        XCTAssertEqual(second?.applied, 3)
        XCTAssertEqual(second?.tombstones, 0, "Still no locally emitted tombstones")
        XCTAssertTrue(ruleTombstones(f.client).isEmpty)
        for identity in ["r1", "r2", "r3"] {
            XCTAssertNotNil(f.store.table.cursors[identity]?.deletedAtMs)
        }
    }

    /// U-13b undo variant: restore the hidden Space cursor to live instead of delivering rule tombstones. The
    /// next round resolves and lands all three parked content updates, preserving rows and emitting no
    /// tombstones. Cascaded deletion would also break recovery within the 30-day undo window.
    func testUnhidingTheSpaceLandsTheParkedRulesInsteadOfDeletingThem() async throws {
        let f = try makeFollowerFixture()
        let engine = makeLifecycleEngine(f)
        await engine.setSpaceSyncEnabled(true)
        await engine.pullOnce()
        XCTAssertEqual(f.access.rows.count, 3)
        XCTAssertNotNil(f.store.table.cursors["r1"]?.pendingApply)

        // Undo: S is live again, as after landing a resurrected Space entity.
        f.spaceStore.table.cursors["su-1"]?.hidden = false
        f.spaceStore.table.cursors["su-1"]?.deletedAtMs = nil
        await engine.pullOnce()

        XCTAssertEqual(f.access.rows.count, 3, "The row remains")
        XCTAssertTrue(f.access.rows.allSatisfy { $0.deletedDate == nil })
        XCTAssertEqual(Set(f.access.rows.map(\.host)),
                       Set(Self.deletedSpaceRules.map { "new-\($0.host)" }),
                       "All three parked content updates landed")
        let counters = await engine.lastOwnedRoundCountersForTesting["urlrules"]
        XCTAssertEqual(counters?.tombstones, 0)
        XCTAssertEqual(counters?.applied, 3)
        XCTAssertTrue(ruleTombstones(f.client).isEmpty)
        for identity in ["r1", "r2", "r3"] {
            XCTAssertNil(f.store.table.cursors[identity]?.pendingApply, "Parking is cleared")
        }
        XCTAssertTrue(f.access.hardDeleteCalls.isEmpty)
    }

    // MARK: - CASE U-13c (purge is not deletion intent, engine coverage)

    /// Reachable §5.7 case: X landed in S_old (su-1), then remotely moved to unmapped S_new (su-new) and
    /// parked. S_old is hidden beyond 30 days; Task 5 purge already hard-deleted X's local row.
    /// ① runRetentionSweep purges S_old and its mapping, preserving X's pendingApply, reconciled,
    /// entityId/version and old ownerUuid under R-M3-4a-27. ② Publication emits no tombstone. ③ Mapping S_new
    /// lets R-M3-4a-42(a) recreate the missing row from payload at S_new while X remains live remotely.
    /// Soft-deleting during purge would create local deletion intent and wrongly tombstone X at S_new. Missing
    /// the parked exemption would discard an unreplayable payload behind the shared marker. Rewriting
    /// ownerUuid during exemption invents ownership never established locally. U-13 contrasts actual user
    /// deletion, which still emits three tombstones.
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
        XCTAssertTrue(spaceAccess.calls.contains(.purge("space-a")), "① S_old was purged")
        XCTAssertNil(spaceAccess.spaceMappings["space-a"], "① dropSpaceMapping removed the su-old mapping")
        XCTAssertNotNil(spaceStore.table.cursors["su-1"]?.purgedAtMs)
        XCTAssertTrue(access.rows.isEmpty, "① X has no local row after hard deletion")
        let kept = try XCTUnwrap(store.table.cursors["r-x"], "① Exemption preserves the cursor")
        XCTAssertEqual(kept.pendingApply, baselineBytes(payloadNew), "① The payload remains")
        XCTAssertEqual(kept.reconciled, baselineBytes(payloadOld))
        XCTAssertEqual(kept.entityId, "srv-r-x")
        XCTAssertEqual(kept.version, 3)
        XCTAssertEqual(kept.ownerUuid, "su-1", "① Exemption does not rewrite ownerUuid")
        let sweep = await engine.lastOwnedRoundCountersForTesting["urlrules"]
        XCTAssertEqual(sweep?.rehomedCursors ?? 0, 0)

        // ②
        await engine.pullOnce()
        let published = await engine.lastOwnedRoundCountersForTesting["urlrules"]
        XCTAssertEqual(published?.tombstones, 0, "② Purge is not deletion intent")
        XCTAssertTrue(ruleTombstones(client).isEmpty, "② No rule tombstones")
        XCTAssertNotNil(store.table.cursors["r-x"]?.pendingApply, "② Still parked")
        XCTAssertEqual(store.table.cursors["r-x"]?.pendingDelete, false)

        // ③
        try spaceAccess.mapSpace("space-d", toSyncUuid: "su-new")
        spaceAccess.spaces.append(PhiLocalSpace(spaceId: "space-d", profileId: "Default", name: "S",
                                                colorHex: "#3A6FF8", iconName: "emoji:1F4BC",
                                                sortOrder: 3, createdDate: Date(timeIntervalSince1970: 1),
                                                themeId: nil, opacityLight: nil, opacityDark: nil))
        await engine.pullOnce()
        let landed = await engine.lastOwnedRoundCountersForTesting["urlrules"]
        XCTAssertEqual(landed?.applied, 1, "③ The parked target change landed")
        XCTAssertEqual(access.rows.count, 1, "③ The missing row is created from payload")
        XCTAssertEqual(access.rows.first?.syncId, "r-x")
        XCTAssertEqual(access.rows.first?.spaceId, "space-d", "③ Landed in S_new")
        XCTAssertNil(store.table.cursors["r-x"]?.pendingApply)
        XCTAssertEqual(landed?.tombstones, 0)
        XCTAssertTrue(ruleTombstones(client).isEmpty)
        XCTAssertEqual(client.stored[ruleHash("r-x")]?.deleted, false, "③ X remains live in the account")
    }

    // MARK: - CASE U-20 (two retention-cascade fail-safes)

    /// su-1 is purged. (a) Published live r-a targets an expired incognito runtime ID, so eligibilityOwner is
    /// nil (R-M3-4a-8), while cursor ownerUuid remains su-1; liveOwners records claimed without an owner. (b)
    /// Rowless r-b has a parked target change and ownerUuid su-1. After two sweeps, preserve (a)'s
    /// cursor/ownerUuid with rehomedCursors 0 and no next-round tombstone, and (b)'s payload/server metadata.
    /// Unconditional removal without the live-identity fail-safe would discard cursors for live rows with
    /// unresolved owners, causing blind baseVersion 0 creates. Missing the parked exemption loses U-13c's
    /// unreplayable move.
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
            let live = try XCTUnwrap(table.cursors["r-a"], "(a) Pass \(pass): preserve the live row's cursor")
            XCTAssertEqual(live.ownerUuid, "su-1", "(a) Do not rewrite unresolved ownership")
            XCTAssertEqual(live.entityId, "srv-r-a")
            XCTAssertEqual(counters?.rehomedCursors ?? 0, 0, "(a) No rehome")
            let held = try XCTUnwrap(table.cursors["r-b"], "(b) Pass \(pass): preserve the parked cursor")
            XCTAssertNotNil(held.pendingApply, "(b) The payload remains")
            XCTAssertEqual(held.entityId, "srv-r-b")
            XCTAssertEqual(held.version, 1, "(b) Harvested server metadata remains")
            XCTAssertEqual(held.ownerUuid, "su-1", "(b) Do not rewrite ownerUuid")
            XCTAssertEqual(store.table.cursors.count, 2, "The persisted table also has two entries")
        }

        await engine.pullOnce()
        let counters = await engine.lastOwnedRoundCountersForTesting["urlrules"]
        XCTAssertEqual(counters?.tombstones, 0, "(a) Live row is in liveIdentities; (b) owner is ineligible; neither publishes")
        XCTAssertTrue(ruleTombstones(client).isEmpty)
        XCTAssertEqual(access.rows.count, 1)
    }

    // MARK: - CASE U-22 (editor deletion emits one tombstone and hard-deletes the row)

    /// Three published rules share an eligible bucket. Task 11 has soft-deleted r2 with a mergePartnerSyncId.
    /// One round tombstones only r2; applied acknowledgement removes its row and merge partner metadata via
    /// exit 1, leaving deletedAtMs in the cursor. Without exit 1 the invisible row lingers 30 days. This also
    /// positively covers origin (a), since eligibility permits deletion without explicitDeletions; pair it
    /// with U-13 to ensure (b) supplements rather than replaces (a).
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
        XCTAssertEqual(ruleTombstones(client).map(\.clientTagHash), [ruleHash("r2")], "① Identity is r2")
        XCTAssertEqual(counters?.pushed, 0, "② The other two projections exactly match reconciled")
        XCTAssertEqual(ruleCommits(client).count, 1, "② No commits for the other two")
        XCTAssertNil(access.rows.first { $0.syncId == "r2" }, "③ Exit 1 removes r2's row")
        XCTAssertEqual(access.hardDeleteCalls, ["r2"], "③")
        XCTAssertEqual(access.rows.map(\.syncId), ["r1", "r3"], "The other two rows are unchanged")
        let cursor = try XCTUnwrap(store.table.cursors["r2"])
        XCTAssertNotNil(cursor.deletedAtMs, "④")
        XCTAssertFalse(cursor.pendingDelete, "④")
        XCTAssertNil(cursor.reconciled, "④")
        XCTAssertFalse(access.rows.contains { $0.mergePartnerSyncId != nil },
                       "⑤ mergePartnerSyncId disappears with the row")
    }

    // MARK: - CASE 9.1 (soft-deleted rows' second exit: 30-day sweep)

    /// r-orphan exhausted three tombstone rejections, leaving reconciled nil, cursor deletedAtMs and row
    /// deletedDate T. r-fresh was recently soft-deleted. At T+29 days purge is called but deletes none; at
    /// T+31 it removes only r-orphan; a third sweep is idempotent. Row cleanup must use deletedDate, not
    /// cursor deletedAtMs: dropExpiredOwnedTombstones can remove the cursor first, otherwise leaving an
    /// invisible row forever.
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
        // State after three invalidMessage rounds in PhiSyncEngine.applyOwnedCommitOutcome's abandonment
        // branch.
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
        XCTAssertEqual(access.purgeCalls.count, 1, "First call: one sweep ran")
        XCTAssertEqual(Set(access.rows.compactMap(\.syncId)), ["r-live", "r-orphan", "r-fresh"],
                       "First call: r-orphan remains at day 29")
        XCTAssertNotNil(store.table.cursors["r-orphan"], "Day 29: the cursor has not expired either")

        clock.nowMs = t + 31 * Self.dayMs
        await engine.runRetentionSweep()
        XCTAssertEqual(access.purgeCalls.count, 2)
        XCTAssertNil(store.table.cursors["r-orphan"], "Day 31: dropExpiredOwnedTombstones removes the cursor")
        XCTAssertEqual(Set(access.rows.compactMap(\.syncId)), ["r-live", "r-fresh"],
                       "Second call: row.deletedDate removes r-orphan while preserving r-fresh, even after cursor removal")
        let counters = await engine.lastOwnedRoundCountersForTesting["urlrules"]
        XCTAssertEqual(counters?.tombstones ?? 0, 0, "This sweep does not change cursor deletion bookkeeping")
        XCTAssertEqual(counters?.rehomedCursors ?? 0, 0)

        await engine.runRetentionSweep()
        XCTAssertEqual(access.purgeCalls.count, 3, "Third call: sweep still runs and removes zero rows idempotently")
        XCTAssertEqual(Set(access.rows.compactMap(\.syncId)), ["r-live", "r-fresh"])
        XCTAssertTrue(access.hardDeleteCalls.isEmpty, "Exit 2 does not use exit 1")
    }
}

/// CASE U-28 probe: record the order in which save first observes each of the three HadRecords flags true.
/// writeOwnedTable sets each flag after that kind lands, exposing processing order. This top-level type stays
/// outside the @MainActor test class because PhiSpaceSyncStateStore is nonisolated and invoked from the engine
/// actor.
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

// MARK: - Task 11: explicit edit sets and one write entry point (U-14 / U-15 / U-15b / U-15c / U-22 / U-24c)

/// Real temporary LocalStore, URLRulesEditor.computeEditSet, two agent-side pure functions and
/// SpaceManager.makeForTesting(boundTo:) without shared access. This section asserts rows; Task 9's U-22 above
/// covers exactly one diff tombstone.
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
        var mergePartnerSyncId: String?
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
            mergePartnerSyncId = rule.mergePartnerSyncId
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
    /// Uppercase UUID strings survive Row.init(from:)'s UUID(uuidString:).uuidString round trip unchanged,
    /// letting U-14 assert stable id. Lowercase/non-UUID legacy IDs use syncId fallback coverage.
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

    /// Value snapshot of the complete table, including soft-deleted rows, keyed by id.
    private func snapshot(_ store: LocalStore) throws -> [String: RuleSnap] {
        drainMainQueue()
        let context = try XCTUnwrap(store.getMainContext())
        let rows = try context.fetch(FetchDescriptor<SpaceURLRule>())
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.id, RuleSnap($0)) })
    }

    /// Default live-row read path, shared by editor load() and agent storedRules().
    private func liveRules(_ store: LocalStore) -> [SpaceRoutingRule] {
        drainMainQueue()
        return store.getAllURLRules()
    }

    private func editorRows(_ store: LocalStore) -> [Row] {
        liveRules(store).map(Row.init(from:))
    }

    /// M5 / 8b-4: dirty is the fifth parameter. Empty means no controls were touched, so every case expecting
    /// an upsert must explicitly identify the edited controls (R-M3-4a-72).
    private func editSet(rows: [Row], loaded: [Row], removed: [Row] = [],
                         dirty: [UUID: URLRulesEditor.RowDirty] = [:],
                         store: LocalStore) -> URLRulesEditor.EditSet {
        URLRulesEditor.computeEditSet(rows: rows, loaded: loaded, removed: removed,
                                      stored: liveRules(store), dirty: dirty)
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

    // MARK: CASE U-14 (all four draft construction sites retain identity and id)

    /// Exercise four draft sites independently: editor changes row 2's value, agent adds to S1, agent changes
    /// row 2's ask, and the shared writer soft-deletes row 3. Each preserves row 2 id I1/syncId r1 and sibling
    /// identities. Editor/agent updates advance only contentUpdatedDate; add/delete leave both stamps
    /// unchanged. Only add increases row count. Missing id can turn update into delete/insert via default
    /// minting; missing syncId can duplicate legacy rows.
    func testEveryDraftConstructionSiteCarriesTheRowIdentity() async throws {
        let store = try makeRuleStore()
        try await seed(Self.threeSeeds, in: store)
        let s0 = try snapshot(store)
        XCTAssertNil(s0[Self.i1]?.contentUpdatedDate)

        // (1) Editor changes only row 2's value.
        let loaded = editorRows(store)
        var rows = loaded
        let index1 = try XCTUnwrap(rows.firstIndex { $0.storeId == Self.i1 })
        rows[index1].value = "one-changed.example"
        let e1 = editSet(rows: rows, loaded: loaded, dirty: [rows[index1].id: .value], store: store)
        XCTAssertEqual(e1.upserts.map(\.id), [Self.i1], "(1) Only row 2 enters upserts")
        XCTAssertEqual(e1.upserts.first?.syncId, "r1")
        XCTAssertTrue(e1.deletedIds.isEmpty)
        try await apply(e1, to: store)
        let s1 = try snapshot(store)
        XCTAssertEqual(s1.count, 3)
        assertIdentityUntouched(s0, s1, ids: [Self.i0, Self.i1, Self.i2])
        XCTAssertEqual(s1[Self.i1]?.host, "one-changed.example")
        XCTAssertNotNil(s1[Self.i1]?.contentUpdatedDate, "(1) Content edits advance the content stamp")
        XCTAssertNil(s1[Self.i1]?.targetUpdatedDate, "(1) Target stamp is unchanged")

        // (2) Agent adds a new rule to S1.
        let e2 = AgentSpaceRouter.urlRuleAddEdits(all: liveRules(store), spaceId: Self.t11SpaceA,
                                                  host: "added.example", pathPrefix: nil, ask: false)
        XCTAssertEqual(e2.upserts.count, 4, "(2) The full target bucket plus one new row")
        XCTAssertEqual(Set(e2.upserts.prefix(3).map(\.id)), [Self.i0, Self.i1, Self.i2], "(2) Existing rows all retain id")
        XCTAssertEqual(e2.upserts.prefix(3).compactMap(\.syncId).count, 3, "(2) Existing rows all retain syncId")
        XCTAssertNil(e2.upserts.last?.syncId, "(2) The new row has no syncId; insertion mints it")
        XCTAssertEqual(e2.upserts.last?.sortOrder, 3)
        try await apply(e2, to: store)
        let s2 = try snapshot(store)
        XCTAssertEqual(s2.count, 4, "(2) Row count increases by one")
        assertIdentityUntouched(s1, s2, ids: [Self.i0, Self.i1, Self.i2])
        XCTAssertEqual(s2[Self.i1]?.contentUpdatedDate, s1[Self.i1]?.contentUpdatedDate, "(2) Row 2's content stamp is unchanged")
        XCTAssertNil(s2[Self.i1]?.targetUpdatedDate)
        let added = try XCTUnwrap(s2.values.first { $0.host == "added.example" })
        XCTAssertNotNil(added.syncId)
        XCTAssertEqual(added.sortOrder, 3)

        // (3) Agent updates row 2's ask.
        let existing = try XCTUnwrap(liveRules(store).first { $0.id == Self.i1 })
        let e3 = AgentSpaceRouter.urlRuleUpdateEdits(all: liveRules(store), existing: existing,
                                                     host: existing.host, pathPrefix: existing.pathPrefix,
                                                     ask: true, spaceId: existing.spaceId)
        XCTAssertEqual(e3.upserts.count, 4, "(3) The entire same bucket")
        XCTAssertEqual(e3.upserts.first { $0.id == Self.i1 }?.syncId, "r1")
        XCTAssertEqual(e3.upserts.first { $0.id == Self.i1 }?.sortOrder, 1, "(3) Position is preserved")
        try await apply(e3, to: store)
        let s3 = try snapshot(store)
        XCTAssertEqual(s3.count, 4)
        assertIdentityUntouched(s2, s3, ids: [Self.i0, Self.i1, Self.i2, added.id])
        XCTAssertEqual(s3[Self.i1]?.askBeforeRouting, true)
        XCTAssertNotEqual(s3[Self.i1]?.contentUpdatedDate, s2[Self.i1]?.contentUpdatedDate, "(3) Editing ask advances the content stamp")
        XCTAssertNil(s3[Self.i1]?.targetUpdatedDate)

        // (4) Shared write entry point soft-deletes row 3.
        let e4 = URLRulesEditor.EditSet(upserts: [], deletedIds: [Self.i2])
        try await apply(e4, to: store)
        let s4 = try snapshot(store)
        XCTAssertEqual(s4.count, 4, "(4) Soft deletion does not reduce row count")
        XCTAssertNotNil(s4[Self.i2]?.deletedDate)
        assertIdentityUntouched(s3, s4, ids: [Self.i0, Self.i1, Self.i2, added.id])
        XCTAssertEqual(s4[Self.i1]?.contentUpdatedDate, s3[Self.i1]?.contentUpdatedDate, "(4) Both stamps are unchanged")
        XCTAssertNil(s4[Self.i1]?.targetUpdatedDate)
        XCTAssertEqual(liveRules(store).map(\.sortOrder), [0, 1, 2], "(4) The bucket is dense")
    }

    /// Legacy variant: editing host for id legacy-7 / syncId r2 replaces id with a UUID but preserves syncId
    /// and row count. Ruling 3's store fallback recognizes the same row by syncId.
    func testALegacyIdRowIsRecastNotDuplicatedByTheEditor() async throws {
        let store = try makeRuleStore()
        try await seed([
            Seed(id: Self.i0, syncId: "r0", host: "zero.example", sortOrder: 0),
            Seed(id: "legacy-7", syncId: "r2", host: "legacy.example", sortOrder: 1),
        ], in: store)

        let loaded = editorRows(store)
        var rows = loaded
        let index = try XCTUnwrap(rows.firstIndex { $0.storeId == "legacy-7" })
        XCTAssertNotEqual(rows[index].id.uuidString, "legacy-7", "Row.init(from:) reminted the non-UUID id")
        XCTAssertEqual(rows[index].syncId, "r2")
        rows[index].value = "legacy-changed.example"
        let edits = editSet(rows: rows, loaded: loaded, dirty: [rows[index].id: .value], store: store)
        XCTAssertEqual(edits.upserts.count, 1)
        XCTAssertEqual(edits.upserts.first?.id, rows[index].id.uuidString, "Upsert passes the reminted id")
        XCTAssertEqual(edits.upserts.first?.syncId, "r2", "And syncId preserves identity")
        try await apply(edits, to: store)

        let after = try snapshot(store)
        XCTAssertEqual(after.count, 2, "Total row count is unchanged")
        XCTAssertNil(after["legacy-7"], "The old id is gone")
        let recast = try XCTUnwrap(after.values.first { $0.syncId == "r2" })
        XCTAssertNotNil(UUID(uuidString: recast.id), "The new id is a UUID string")
        XCTAssertEqual(recast.host, "legacy-changed.example")
        XCTAssertEqual(after[Self.i0]?.syncId, "r0")
    }

    // MARK: CASE U-15 (editing one row must not rewrite invalid targets elsewhere)

    /// Rows 1/2 target absent Spaces, one ask and one not. Edit only row 3: upserts contains only row 3,
    /// deletedIds is empty, and both invalid-target rows and stamps remain unchanged. Former save rewrote ask
    /// targets to ruleTargetSpaces.first and discarded non-ask rows, causing divergent targets or account-wide
    /// deletion.
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
        let edits = editSet(rows: rows, loaded: loaded, dirty: [rows[index].id: .value], store: store)
        XCTAssertEqual(edits.upserts.map(\.id), [Self.i2])
        XCTAssertEqual(edits.upserts.first?.spaceId, Self.t11SpaceA)
        XCTAssertTrue(edits.deletedIds.isEmpty)
        try await apply(edits, to: store)

        let after = try snapshot(store)
        XCTAssertEqual(after.count, 3)
        XCTAssertEqual(after[Self.i0]?.spaceId, "dead-space-a")
        XCTAssertEqual(after[Self.i1]?.spaceId, "dead-space-b")
        XCTAssertEqual(after[Self.i0], before[Self.i0], "Row 1 is unchanged byte for byte")
        XCTAssertEqual(after[Self.i1], before[Self.i1], "Row 2 is unchanged byte for byte")
        XCTAssertEqual(after[Self.i2]?.host, "c-changed.example")
    }

    // MARK: CASE U-15b (editor does not modify unseen rows)

    /// Open with two rows; remote r3 arrives while the sheet is open. Saving an edit to row 1 produces only
    /// that upsert and no deletions; r3 remains live. Whole-table replaceAllURLRules treated absence from the
    /// editor dictionary as deletion and propagated it to every device. Task 9 covers zero next-round
    /// tombstones.
    func testTheEditorLeavesRowsItNeverSawAlone() async throws {
        let store = try makeRuleStore()
        try await seed(Array(Self.threeSeeds.prefix(2)), in: store)
        let loaded = editorRows(store)
        XCTAssertEqual(loaded.count, 2)

        // A new row landed remotely while the sheet was open.
        try await seed([Seed(id: Self.i2, syncId: "r3", host: "remote.example", sortOrder: 2)], in: store)

        var rows = loaded
        let index = try XCTUnwrap(rows.firstIndex { $0.storeId == Self.i0 })
        rows[index].value = "zero-changed.example"
        let edits = editSet(rows: rows, loaded: loaded, dirty: [rows[index].id: .value], store: store)
        XCTAssertTrue(edits.deletedIds.isEmpty)
        XCTAssertEqual(edits.upserts.map(\.id), [Self.i0])
        try await apply(edits, to: store)

        let after = try snapshot(store)
        XCTAssertEqual(after.count, 3)
        XCTAssertEqual(after[Self.i2]?.syncId, "r3")
        XCTAssertNil(after[Self.i2]?.deletedDate)
        XCTAssertEqual(after[Self.i2]?.host, "remote.example")
        XCTAssertEqual(after[Self.i0]?.host, "zero-changed.example")
    }

    // MARK: CASE U-15c (clearing means deletion)

    /// Clear row 1's value and append an empty Row(defaultSpaceId:). deletedIds is [I1], and neither empty row
    /// is upserted. Storage retains three rows with I1 soft-deleted and pendingLocalEdit false; I2/I3 remain
    /// unchanged. domainSuffix plus *. encodes the same empty-host case. Old silent continue behavior under
    /// whole-table replacement meant deletion; explicit edits must preserve that intent without inserting
    /// empty new rows.
    func testClearingARuleDeletesItAndBlankNewRowsAreIgnored() async throws {
        let store = try makeRuleStore()
        try await seed(Self.threeSeeds, in: store)
        let before = try snapshot(store)

        let loaded = editorRows(store)
        var rows = loaded
        let index = try XCTUnwrap(rows.firstIndex { $0.storeId == Self.i0 })
        rows[index].value = ""
        rows.append(Row(defaultSpaceId: Self.t11SpaceA))
        // Deletion ignores dirty flags (R-M3-4a-69), so dirty is deliberately empty.
        let edits = editSet(rows: rows, loaded: loaded, store: store)
        XCTAssertEqual(edits.deletedIds, [Self.i0])
        XCTAssertTrue(edits.upserts.isEmpty, "Neither the new empty row nor the cleared row enters upserts")
        try await apply(edits, to: store)

        let after = try snapshot(store)
        XCTAssertEqual(after.count, 3, "Three stored rows remain: soft deletion and no empty-row insertion")
        XCTAssertNotNil(after[Self.i0]?.deletedDate)
        XCTAssertEqual(after[Self.i0]?.pendingLocalEdit, false, "Deletion is not an edit (R-M3-4a-69)")
        XCTAssertEqual(after[Self.i1]?.host, before[Self.i1]?.host)
        XCTAssertEqual(after[Self.i1]?.syncId, before[Self.i1]?.syncId)
        XCTAssertEqual(after[Self.i1]?.contentUpdatedDate, before[Self.i1]?.contentUpdatedDate)
        XCTAssertEqual(after[Self.i1]?.pendingLocalEdit, false)
        XCTAssertEqual(after[Self.i2]?.host, before[Self.i2]?.host)
        XCTAssertEqual(after[Self.i2]?.pendingLocalEdit, false)
        XCTAssertEqual(liveRules(store).map(\.sortOrder), [0, 1], "The bucket is dense")

        // An encoded empty host is also a cleared rule.
        let loaded2 = editorRows(store)
        var rows2 = loaded2
        let index2 = try XCTUnwrap(rows2.firstIndex { $0.storeId == Self.i1 })
        rows2[index2].matchType = .domainSuffix
        rows2[index2].value = "*."
        let edits2 = editSet(rows: rows2, loaded: loaded2, store: store)
        XCTAssertEqual(edits2.deletedIds, [Self.i1])
        XCTAssertTrue(edits2.upserts.isEmpty)
    }

    // MARK: CASE U-22 (editor removal soft-deletes the row)

    /// Remove row 2 from three siblings: deletedIds [I2], no upserts. applyRuleEdits retains I2 with
    /// deletedDate and pendingLocalEdit false; live orders become dense 0…1. Other rows retain stamps and
    /// pendingLocalEdit. context.delete would erase intent (R-M3-4a-41); setting pendingLocalEdit on the
    /// deleted row would wrongly yield to an inbound tombstone.
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
        XCTAssertTrue(edits.upserts.isEmpty, "Rows 1/3 retain content and relative order")
        try await manager.applyRuleEdits(upserts: edits.upserts, deletedIds: edits.deletedIds)

        let after = try snapshot(store)
        XCTAssertEqual(after.count, 3, "I2's row remains")
        XCTAssertNotNil(after[Self.i1]?.deletedDate)
        XCTAssertEqual(after[Self.i1]?.pendingLocalEdit, false)
        for id in [Self.i0, Self.i2] {
            XCTAssertEqual(after[id]?.contentUpdatedDate, before[id]?.contentUpdatedDate)
            XCTAssertEqual(after[id]?.targetUpdatedDate, before[id]?.targetUpdatedDate)
            XCTAssertEqual(after[id]?.pendingLocalEdit, false)
        }
        XCTAssertEqual(liveRules(store).map(\.sortOrder), [0, 1], "Live rows have dense order 0…1")
        XCTAssertEqual(manager.urlRuleReloadCountForTesting, 1, "The write entry point refreshed once")
    }

    // MARK: CASE U-24c (every write entry point refreshes routing)

    /// (a) Bound SpaceManager edits host, adds and deletes through applyRuleEdits: reload count advances 0 →
    /// 3, once per committed write, observing committed rows. Nil boundAccount throws storeUnavailable without
    /// incrementing. Direct store writes can leave cachedURLRules/Chromium stale due to removeDuplicates;
    /// silent guard returns would make no write appear successful (R-M3-3-14).
    func testEveryWriteFaceRefreshesTheRoutingTableOnceAfterTheCommit() async throws {
        let account = Account(userID: "t11-u24c")
        let store = try makeRuleStore(for: account)
        account.localStorage = store
        try await seed(Self.threeSeeds, in: store)
        let manager = SpaceManager.makeForTesting(boundTo: account)
        XCTAssertEqual(manager.urlRuleReloadCountForTesting, 0)

        // Edit one host.
        try await manager.applyRuleEdits(
            upserts: [LocalStore.URLRuleDraft(id: Self.i0, host: "zero-changed.example",
                                              spaceId: Self.t11SpaceA, syncId: "r0")],
            deletedIds: [])
        XCTAssertEqual(manager.urlRuleReloadCountForTesting, 1)
        XCTAssertEqual(manager.allRules.first { $0.id == Self.i0 }?.host, "zero-changed.example",
                       "Refresh reads committed rows")

        // Add one rule.
        try await manager.applyRuleEdits(
            upserts: [LocalStore.URLRuleDraft(host: "added.example", spaceId: Self.t11SpaceA, sortOrder: 3)],
            deletedIds: [])
        XCTAssertEqual(manager.urlRuleReloadCountForTesting, 2)
        XCTAssertEqual(manager.allRules.count, 4)

        // Delete one rule.
        try await manager.applyRuleEdits(upserts: [], deletedIds: [Self.i2])
        XCTAssertEqual(manager.urlRuleReloadCountForTesting, 3)
        XCTAssertEqual(manager.allRules.count, 3)
        XCTAssertFalse(manager.allRules.contains { $0.id == Self.i2 })

        // No bound account must throw instead of returning silently.
        let unbound = SpaceManager.makeForTesting(boundTo: nil)
        do {
            try await unbound.applyRuleEdits(upserts: [], deletedIds: [Self.i0])
            XCTFail("expected .storeUnavailable")
        } catch let error as LocalStoreWriteError {
            XCTAssertEqual(error, .storeUnavailable)
        }
        XCTAssertEqual(unbound.urlRuleReloadCountForTesting, 0)
    }

    /// (b) Pure edit sets: add has one new draft/no deletions; update has one identified draft/no deletions;
    /// delete has no upserts and exactly the requested id. Compile and source inspection verify each handler
    /// calls applyRuleEdits once (CASE 11.1).
    func testTheThreeAgentWriteFacesProduceRowAddressedEditSets() {
        let existing = SpaceRoutingRule(id: Self.i1, spaceId: Self.t11SpaceA, host: "one.example",
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

        // Target change removes one source sibling and adds one destination sibling; both buckets remain
        // ordered.
        let sibling = SpaceRoutingRule(id: Self.i0, spaceId: Self.t11SpaceA, host: "zero.example",
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

    // MARK: Ruling 12 (drag dirties only the dragged row) and recovery (R-M3-4a-101 / 104)

    /// Drag row 3 first: only its sortOrder is upserted, with nil content/spaceId. The resulting [I2,I0,I1]
    /// bucket is dense, both stamps stay unchanged and only the dragged row becomes pending.
    /// applyURLRuleEditsBody step 8 renumbers siblings without marking them. Task 11's earlier full-bucket
    /// drafts dirtied every row, disabling stillness and yielding the whole bucket to remote deletion (8b-4 /
    /// M5 / U-21).
    func testReorderingABucketSendsASortOrderOnlyDraftForTheDraggedRowOnly() async throws {
        let store = try makeRuleStore()
        try await seed(Self.threeSeeds, in: store)
        let before = try snapshot(store)

        let loaded = editorRows(store)
        var rows = loaded
        let last = rows.removeLast()
        rows.insert(last, at: 0)
        let edits = editSet(rows: rows, loaded: loaded, dirty: [last.id: .order], store: store)
        XCTAssertEqual(edits.upserts.map(\.id), [Self.i2], "Only the dragged row")
        XCTAssertEqual(edits.upserts.map(\.sortOrder), [0])
        XCTAssertTrue(edits.upserts.allSatisfy { $0.content == nil && $0.spaceId == nil }, "Contains only sortOrder")
        XCTAssertTrue(edits.deletedIds.isEmpty)
        try await apply(edits, to: store)

        let after = try snapshot(store)
        XCTAssertEqual(liveRules(store).map(\.id), [Self.i2, Self.i0, Self.i1])
        XCTAssertEqual(liveRules(store).map(\.sortOrder), [0, 1, 2], "The bucket is dense")
        for id in [Self.i0, Self.i1, Self.i2] {
            XCTAssertEqual(after[id]?.contentUpdatedDate, before[id]?.contentUpdatedDate)
            XCTAssertEqual(after[id]?.targetUpdatedDate, before[id]?.targetUpdatedDate)
        }
        XCTAssertEqual(after[Self.i2]?.pendingLocalEdit, true, "The dragged row is marked pending")
        XCTAssertEqual(after[Self.i0]?.pendingLocalEdit, false, "Renumbering does not mark pending")
        XCTAssertEqual(after[Self.i1]?.pendingLocalEdit, false)
    }

    /// CASE 11.2, fix round 1 after M5: while reordering, a remote hard delete removes an untouched sibling.
    /// That row has no dirty flags and enters neither edit set, so it is not revived; the dragged row still
    /// writes its sortOrder and the bucket stays dense.
    func testAReorderStillCommitsWhenASiblingVanishedBehindTheSheet() async throws {
        let store = try makeRuleStore()
        try await seed(Self.threeSeeds, in: store)
        let loaded = editorRows(store)

        // Remote hard deletion removes row 2, untouched in the sheet.
        try await store.performBackgroundWriteAndWaitThrowing { context in
            let id = Self.i1
            for row in try context.fetch(FetchDescriptor<SpaceURLRule>(predicate: #Predicate { $0.id == id })) {
                context.delete(row)
            }
        }
        XCTAssertEqual(liveRules(store).count, 2)

        // The user drags row 3 first: rows = [I2,I0,I1].
        var rows = loaded
        let last = rows.removeLast()
        rows.insert(last, at: 0)
        let edits = editSet(rows: rows, loaded: loaded, dirty: [last.id: .order], store: store)
        XCTAssertEqual(edits.upserts.map(\.id), [Self.i2], "Missing I1 has no dirty flags and enters neither set")
        XCTAssertTrue(edits.upserts.allSatisfy { $0.content == nil && $0.spaceId == nil })
        XCTAssertTrue(edits.deletedIds.isEmpty)
        try await apply(edits, to: store)

        let after = try snapshot(store)
        XCTAssertEqual(after.count, 2, "The write committed without reviving I1")
        XCTAssertNil(after[Self.i1])
        XCTAssertEqual(liveRules(store).map(\.id), [Self.i2, Self.i0])
        XCTAssertEqual(liveRules(store).map(\.sortOrder), [0, 1], "The bucket is dense")
    }

    /// A dirty row hard-deleted while the sheet is open recovers with its original id and nil syncId. It
    /// returns with a new identity and unchanged row count.
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
        let edits = editSet(rows: rows, loaded: loaded, dirty: [rows[index].id: .value], store: store)
        XCTAssertEqual(edits.upserts.map(\.id), [Self.i1], "Original id")
        XCTAssertNil(edits.upserts.first?.syncId, "Recovery does not carry the old syncId")
        // M5 recovery includes all three units; a partial-unit draft would throw noCandidateSurvived during
        // insertion.
        XCTAssertNotNil(edits.upserts.first?.content)
        XCTAssertNotNil(edits.upserts.first?.spaceId)
        XCTAssertNotNil(edits.upserts.first?.sortOrder)
        try await apply(edits, to: store)

        let after = try snapshot(store)
        XCTAssertEqual(after.count, 3)
        XCTAssertEqual(after[Self.i1]?.host, "one-revived.example")
        XCTAssertNotNil(after[Self.i1]?.syncId)
        XCTAssertNotEqual(after[Self.i1]?.syncId, "r1")
    }

    // MARK: - 8b-4 (M5 editor coverage: U-15d / U-15f / U-15g / U-21)

    private static let t11SpaceC = "space-c"
    private static let i3 = "3D3D3D3D-0000-4000-8000-000000000003"
    private static let i4 = "4E4E4E4E-0000-4000-8000-000000000004"

    private static var fiveSeeds: [Seed] {
        [
            Seed(id: i0, syncId: "r0", host: "zero.example", sortOrder: 0),
            Seed(id: i1, syncId: "r1", host: "one.example", sortOrder: 1),
            Seed(id: i2, syncId: "r2", host: "two.example", sortOrder: 2),
            Seed(id: i3, syncId: "r3", host: "three.example", sortOrder: 3),
            Seed(id: i4, syncId: "r4", host: "four.example", sortOrder: 4),
        ]
    }

    /// Remote landing uses production LocalStore.applyURLRuleSyncBatchThrowing, the same body the engine
    /// invokes. Never manually mutate rows or deletedDate.
    private func landRemote(_ ops: [URLRuleSyncOp], in store: LocalStore) async throws {
        _ = try await store.applyURLRuleSyncBatchThrowing(ops)
    }

    /// Driver for spec §5.8(3), 8b-4 fix round 1: refreshFromStore privately mutates view @State, while its
    /// pure predicate lives in refreshRows(rows:loaded:removed:stored:dirty:), like computeEditSet. Drive that
    /// function using liveRules(store), the same read path as manager.allRules.
    private func refresh(rows: [Row], loaded: [Row], removed: [Row] = [],
                         dirty: [UUID: URLRulesEditor.RowDirty] = [:],
                         store: LocalStore) -> URLRulesEditor.RefreshResult {
        URLRulesEditor.refreshRows(rows: rows, loaded: loaded, removed: removed,
                                   stored: liveRules(store), dirty: dirty)
    }

    private func landingValues(syncId: String, spaceId: String,
                               host: String, sortOrder: Int, stamp: Double) -> URLRuleLandingValues {
        URLRuleLandingValues(syncId: syncId, spaceId: spaceId, host: host, pathPrefix: nil,
                             askBeforeRouting: false, sortOrder: sortOrder,
                             createdDate: Date(timeIntervalSince1970: 1_000),
                             contentUpdatedDate: Date(timeIntervalSince1970: stamp),
                             targetUpdatedDate: Date(timeIntervalSince1970: stamp))
    }

    // MARK: CASE U-15d (Save writes only changed rows and units; R-M3-4a-72 / RR6-6 / RR7-10)

    /// Five published rules; each subcase opens a fresh sheet. ① Editing only row 3's target yields one
    /// target-only upsert. ② Saving untouched yields empty sets and no applyRuleEdits. ③ Remote target S3 plus
    /// local text edit preserves remote target/stamp and stamps only content at Save. ④ Remote refresh of
    /// untouched row 4 creates no upsert or pending flag. ⑤ Local a.example versus concurrent remote b.example
    /// keeps the dirty local text and upserts it.
    /// This catches whole-table/fingerprint migration that marks every row pending, whole-row comparison that
    /// stamps untouched target fields, dirty baselines frozen at load(), and refresh that protects only the
    /// currently focused field. That last error silently replaces a.example and loses the local edit at Save
    /// (ruling 10).
    func testSaveWritesOnlyTheRowsAndTheUnitsTheUserTouched() async throws {
        // ① Edit only row 3's target selector.
        do {
            let store = try makeRuleStore()
            try await seed(Self.fiveSeeds, in: store)
            let before = try snapshot(store)
            let loaded = editorRows(store)
            var rows = loaded
            let index = try XCTUnwrap(rows.firstIndex { $0.storeId == Self.i2 })
            rows[index].askBeforeRouting = false
            rows[index].targetSpaceId = Self.t11SpaceB
            let edits = editSet(rows: rows, loaded: loaded,
                                dirty: [rows[index].id: [.ask, .target]], store: store)
            XCTAssertEqual(edits.upserts.map(\.id), [Self.i2], "① Exactly one upsert")
            XCTAssertTrue(edits.deletedIds.isEmpty)
            XCTAssertNil(edits.upserts.first?.content, "① Content matches storage, so omit that unit")
            XCTAssertEqual(edits.upserts.first?.spaceId, Self.t11SpaceB)
            try await apply(edits, to: store)

            let after = try snapshot(store)
            XCTAssertEqual(after[Self.i2]?.spaceId, Self.t11SpaceB)
            XCTAssertNotNil(after[Self.i2]?.targetUpdatedDate)
            XCTAssertEqual(after[Self.i2]?.contentUpdatedDate, before[Self.i2]?.contentUpdatedDate,
                           "① Content stamp is unchanged byte for byte")
            XCTAssertEqual(after[Self.i2]?.pendingLocalEdit, true)
            for id in [Self.i0, Self.i1, Self.i3, Self.i4] {
                XCTAssertEqual(after[id]?.contentUpdatedDate, before[id]?.contentUpdatedDate, id)
                XCTAssertEqual(after[id]?.targetUpdatedDate, before[id]?.targetUpdatedDate, id)
                XCTAssertEqual(after[id]?.pendingLocalEdit, false, id)
            }
        }

        // ② Save without changes.
        do {
            let store = try makeRuleStore()
            try await seed(Self.fiveSeeds, in: store)
            let loaded = editorRows(store)
            let edits = editSet(rows: loaded, loaded: loaded, store: store)
            XCTAssertTrue(edits.isEmpty, "② No dirty flags means empty sets and no applyRuleEdits call")
        }

        // ③ Remote target changes while the sheet is open, followed by a real per-field refresh; the user
        // edits only text.
        do {
            let store = try makeRuleStore()
            try await seed(Self.fiveSeeds, in: store)
            let loaded = editorRows(store)                 // Open the sheet
            try await landRemote([.move(landingValues(syncId: "r2", spaceId: Self.t11SpaceC,
                                                      host: "two.example", sortOrder: 0,
                                                      stamp: 2_000))], in: store)
            let landed = try snapshot(store)
            XCTAssertEqual(landed[Self.i2]?.spaceId, Self.t11SpaceC)

            // §5.8(3): untouched target selector refreshes to the newly landed store value.
            let refreshed = refresh(rows: loaded, loaded: loaded, store: store)
            XCTAssertTrue(refreshed.changed, "③ Refresh actually changed the displayed value")
            var rows = refreshed.rows
            let index = try XCTUnwrap(rows.firstIndex { $0.storeId == Self.i2 })
            XCTAssertEqual(rows[index].targetSpaceId, Self.t11SpaceC,
                           "③ Refresh updates the clean target selector (positive control)")
            XCTAssertEqual(refreshed.changedIds, [rows[index].id],
                           "③ Reload only the cell whose value actually changed")
            rows[index].value = "two-typed.example"
            let edits = editSet(rows: rows, loaded: refreshed.loaded,
                                dirty: [rows[index].id: .value], store: store)
            XCTAssertEqual(edits.upserts.map(\.id), [Self.i2])
            XCTAssertNotNil(edits.upserts.first?.content)
            XCTAssertNil(edits.upserts.first?.spaceId, "③ Omitted target unit preserves both stored columns")
            try await apply(edits, to: store)

            let after = try snapshot(store)
            XCTAssertEqual(after[Self.i2]?.spaceId, Self.t11SpaceC, "③ The target just landed in storage")
            XCTAssertEqual(after[Self.i2]?.targetUpdatedDate, landed[Self.i2]?.targetUpdatedDate,
                           "③ targetUpdatedDate is unchanged byte for byte")
            XCTAssertNotEqual(after[Self.i2]?.contentUpdatedDate, landed[Self.i2]?.contentUpdatedDate,
                              "③ contentUpdatedDate uses this Save's now")
            XCTAssertEqual(after[Self.i2]?.host, "two-typed.example")
            XCTAssertEqual(after[Self.i2]?.pendingLocalEdit, true)
        }

        // ④ Remote row-4 refresh updates its untouched fields without upsert or pending state. The clean-unit
        // baseline follows storage (§5.8(4)).
        do {
            let store = try makeRuleStore()
            try await seed(Self.fiveSeeds, in: store)
            let loaded = editorRows(store)
            try await landRemote([.update(landingValues(syncId: "r3", spaceId: Self.t11SpaceA,
                                                        host: "three-remote.example",
                                                        sortOrder: 3, stamp: 2_000))], in: store)
            let landed = try snapshot(store)

            let refreshed = refresh(rows: loaded, loaded: loaded, store: store)
            XCTAssertTrue(refreshed.changed)
            var rows = refreshed.rows
            let fourth = try XCTUnwrap(rows.first { $0.storeId == Self.i3 })
            XCTAssertEqual(fourth.value, "three-remote.example",
                           "④ Refresh updates the clean text field (positive control)")
            XCTAssertEqual(fourth.matchType, .domain)
            XCTAssertEqual(refreshed.changedIds, [fourth.id],
                           "④ The other four rows are unchanged and need no cell reload")
            let index = try XCTUnwrap(rows.firstIndex { $0.storeId == Self.i0 })
            rows[index].value = "zero-typed.example"
            let edits = editSet(rows: rows, loaded: refreshed.loaded,
                                dirty: [rows[index].id: .value], store: store)
            XCTAssertEqual(edits.upserts.map(\.id), [Self.i0], "④ Row 4 does not enter upserts")
            try await apply(edits, to: store)

            let after = try snapshot(store)
            XCTAssertEqual(after[Self.i3]?.host, "three-remote.example")
            XCTAssertEqual(after[Self.i3]?.pendingLocalEdit, false, "④ Remains false")
            XCTAssertEqual(after[Self.i3]?.contentUpdatedDate, landed[Self.i3]?.contentUpdatedDate)
        }

        // ⑤ Refresh must preserve the dirty local field against concurrent remote content (ruling 10).
        do {
            let store = try makeRuleStore()
            try await seed(Self.fiveSeeds, in: store)
            let loaded = editorRows(store)
            var rows = loaded
            let index = try XCTUnwrap(rows.firstIndex { $0.storeId == Self.i4 })
            rows[index].value = "a.example"                // The value dirty flag remains after focus moves away
            let dirty: [UUID: URLRulesEditor.RowDirty] = [rows[index].id: .value]
            try await landRemote([.update(landingValues(syncId: "r4", spaceId: Self.t11SpaceA,
                                                        host: "b.example",
                                                        sortOrder: 4, stamp: 2_000))], in: store)
            let landedFive = try snapshot(store)
            XCTAssertEqual(landedFive[Self.i4]?.host, "b.example")

            // Run an actual per-field refresh.
            let refreshed = refresh(rows: rows, loaded: loaded, dirty: dirty, store: store)
            rows = refreshed.rows
            let fifth = try XCTUnwrap(rows.first { $0.storeId == Self.i4 })
            XCTAssertEqual(fifth.value, "a.example",
                           "⑤ Preserve the dirty field; replacing it with b.example must fail")
            // Refresh cannot clear dirty flags by type: dirty is read-only input to refreshRows and absent
            // from RefreshResult. These assertions verify the observable consequence.
            XCTAssertEqual(dirty[fifth.id], .value)
            XCTAssertTrue(refreshed.droppedIds.isEmpty, "⑤ No rows leave the sheet")
            XCTAssertTrue(refreshed.changedIds.isEmpty,
                          "⑤ The only changed row is dirty, so no refresh or cell reload")
            // Only clean-unit baselines follow storage; this row's dirty content baseline remains unchanged.
            let baseline = try XCTUnwrap(refreshed.loaded.first { $0.storeId == Self.i4 })
            XCTAssertEqual(baseline.value, "four.example", "⑤ The dirty-unit baseline is not refreshed")

            let edits = editSet(rows: rows, loaded: refreshed.loaded, dirty: dirty, store: store)
            XCTAssertEqual(edits.upserts.map(\.id), [Self.i4])
            XCTAssertEqual(edits.upserts.first?.content?.host, "a.example")
            try await apply(edits, to: store)

            let after = try snapshot(store)
            XCTAssertEqual(after[Self.i4]?.host, "a.example", "⑤ The user's edit was not silently lost")
            XCTAssertEqual(after[Self.i4]?.pendingLocalEdit, true)
        }

        // ⑥ Row-level refresh rules: append new rows, drop missing clean rows, retain missing dirty rows.
        do {
            let store = try makeRuleStore()
            try await seed(Self.fiveSeeds, in: store)
            let loaded = editorRows(store)
            var rows = loaded
            let dirtyIndex = try XCTUnwrap(rows.firstIndex { $0.storeId == Self.i1 })
            rows[dirtyIndex].value = "one-typed.example"
            let dirty: [UUID: URLRulesEditor.RowDirty] = [rows[dirtyIndex].id: .value]

            // Remote deletes rows 2 (dirty) and 3 (clean), and creates one row.
            try await landRemote([
                .delete(syncId: "r1"),
                .delete(syncId: "r2"),
                .create(landingValues(syncId: "r9", spaceId: Self.t11SpaceA,
                                      host: "nine.example", sortOrder: 9, stamp: 2_000)),
            ], in: store)

            let refreshed = refresh(rows: rows, loaded: loaded, dirty: dirty, store: store)
            XCTAssertTrue(refreshed.changed)
            let ids = refreshed.rows.compactMap(\.storeId)
            XCTAssertTrue(ids.contains(Self.i1), "Missing dirty rows remain in the sheet for recovery")
            XCTAssertFalse(ids.contains(Self.i2), "Missing clean rows leave on refresh without local revival")
            XCTAssertEqual(refreshed.droppedIds.count, 1)
            let appended = try XCTUnwrap(refreshed.rows.first { $0.value == "nine.example" },
                                         "New stored rows are appended to the sheet")
            XCTAssertNil(dirty[appended.id], "Newly appended rows are not dirty")
            XCTAssertEqual(refreshed.rows.count, 5, "5 - 1 missing clean row + 1 new row")
            XCTAssertTrue(refreshed.changedIds.isEmpty,
                          "Removal and append change the id sequence via structural handling, not changedIds")
        }
    }

    // MARK: CASE U-21 (local drag dirties one row's rank unit)

    /// Five published siblings start with pendingLocalEdit false. Drag row 4 to position 2: exactly one
    /// sortOrder-only upsert, only that row pending, all content/target stamps unchanged, and dense 0…n-1
    /// ordering. Dirtying the bucket would disable stillness for all five and yield to remote deletion; adding
    /// content/target to the draft would advance an untouched stamp.
    func testALocalDragDirtiesOnlyTheRankUnitOfTheDraggedRow() async throws {
        let store = try makeRuleStore()
        try await seed(Self.fiveSeeds, in: store)
        let before = try snapshot(store)
        let loaded = editorRows(store)

        var rows = loaded
        let moved = rows.remove(at: 3)
        rows.insert(moved, at: 1)
        let edits = editSet(rows: rows, loaded: loaded, dirty: [moved.id: .order], store: store)
        XCTAssertEqual(edits.upserts.map(\.id), [Self.i3], "Only the dragged row")
        XCTAssertEqual(edits.upserts.first?.sortOrder, 1)
        XCTAssertNil(edits.upserts.first?.content, "No content unit")
        XCTAssertNil(edits.upserts.first?.spaceId, "No target unit")
        XCTAssertTrue(edits.deletedIds.isEmpty)
        try await apply(edits, to: store)

        let after = try snapshot(store)
        XCTAssertEqual(liveRules(store).map(\.id), [Self.i0, Self.i3, Self.i1, Self.i2, Self.i4])
        XCTAssertEqual(liveRules(store).map(\.sortOrder), [0, 1, 2, 3, 4], "The bucket is dense 0…n-1")
        XCTAssertEqual(after[Self.i3]?.pendingLocalEdit, true)
        for id in [Self.i0, Self.i1, Self.i2, Self.i4] {
            XCTAssertEqual(after[id]?.pendingLocalEdit, false, "\(id)：Renumbering does not mark pending")
        }
        for id in [Self.i0, Self.i1, Self.i2, Self.i3, Self.i4] {
            XCTAssertEqual(after[id]?.contentUpdatedDate, before[id]?.contentUpdatedDate, id)
            XCTAssertEqual(after[id]?.targetUpdatedDate, before[id]?.targetUpdatedDate, id)
        }
    }

    // MARK: CASE U-15f (recover a dirty row deleted remotely; R-M3-4a-101 / §5.8(3))

    /// Edit row 2's text, then land its inbound tombstone through the production batch while the sheet remains
    /// open, actually hard-deleting it. Save succeeds with one full three-unit upsert, original row id and nil
    /// syncId. Insertion mints a new identity different from R2 and sets pendingLocalEdit. A regular partial
    /// M5 draft would fail the whole batch; reusing old syncId would silently undo another device's deletion.
    func testADirtyRowKilledByAnInboundTombstoneComesBackUnderAFreshIdentity() async throws {
        let store = try makeRuleStore()
        try await seed(Self.threeSeeds, in: store)
        let loaded = editorRows(store)

        var rows = loaded
        let index = try XCTUnwrap(rows.firstIndex { $0.storeId == Self.i1 })
        rows[index].value = "one-typed.example"
        // Also edit row 1 so the negative control checks that the other upsert rolls back too.
        let other = try XCTUnwrap(rows.firstIndex { $0.storeId == Self.i0 })
        rows[other].value = "zero-typed.example"
        let dirty: [UUID: URLRulesEditor.RowDirty] = [rows[index].id: .value,
                                                      rows[other].id: .value]

        // While the sheet stays open, land row 2's remote tombstone and hard-delete it.
        try await landRemote([.delete(syncId: "r1")], in: store)
        let afterTombstone = try snapshot(store)
        XCTAssertEqual(afterTombstone.count, 2, "The row is actually gone")

        let edits = editSet(rows: rows, loaded: loaded, dirty: dirty, store: store)
        let revived = try XCTUnwrap(edits.upserts.first { $0.id == Self.i1 })
        XCTAssertEqual(edits.upserts.count, 2, "Row 2 recovery plus row 1's partial-unit draft")
        XCTAssertNotNil(revived.content, "Contains all three units")
        XCTAssertNotNil(revived.spaceId)
        XCTAssertNotNil(revived.sortOrder)
        XCTAssertEqual(revived.content?.host, "one-typed.example", "The row's current value in the sheet")
        XCTAssertNil(revived.syncId, "Never reuse the old syncId; that would make the editor revive a deleted identity")
        XCTAssertTrue(edits.deletedIds.isEmpty)

        try await apply(edits, to: store)              // Save succeeds without throwing

        let after = try snapshot(store)
        XCTAssertEqual(after.count, 3, "Storage gains one live row")
        let row = try XCTUnwrap(after[Self.i1])
        XCTAssertNil(row.deletedDate)
        XCTAssertNotNil(row.syncId)
        XCTAssertNotEqual(row.syncId, "r1", "Insertion minted a new identity")
        XCTAssertEqual(row.pendingLocalEdit, true)
        XCTAssertEqual(after[Self.i0]?.host, "zero-typed.example", "The other upsert persists too")
        XCTAssertEqual(after[Self.i2]?.pendingLocalEdit, false, "Row 3 is unchanged byte for byte")
    }

    /// Negative control: a normal M5 content-only draft cannot match id/syncId and enters insertion without
    /// required content and spaceId. applyURLRuleEditsBody throws noCandidateSurvived and rolls back the whole
    /// batch, including the unrelated valid upsert. This defective path must fail.
    func testAUnitOnlyDraftForAVanishedRowFailsTheWholeSave() async throws {
        let store = try makeRuleStore()
        try await seed(Self.threeSeeds, in: store)
        try await landRemote([.delete(syncId: "r1")], in: store)
        let before = try snapshot(store)

        let broken = LocalStore.URLRuleDraft(
            id: Self.i1, syncId: nil,
            content: LocalStore.URLRuleDraft.ContentUnit(host: "one-typed.example"),
            spaceId: nil, sortOrder: nil, createdDate: nil, contentUpdatedDate: nil)
        let healthy = LocalStore.URLRuleDraft(
            id: Self.i0, syncId: "r0",
            content: LocalStore.URLRuleDraft.ContentUnit(host: "zero-typed.example"),
            spaceId: nil, sortOrder: nil, createdDate: nil, contentUpdatedDate: nil)
        do {
            try await store.applyURLRuleEditsThrowing(upserts: [healthy, broken], deletedIds: [])
            XCTFail("expected noCandidateSurvived")
        } catch {
            XCTAssertEqual(error as? LocalStoreWriteError, .noCandidateSurvived)
        }
        let rolledBack = try snapshot(store)
        XCTAssertEqual(rolledBack, before, "The whole batch rolls back, including the other upsert")
    }

    /// Control: if row 2 is untouched, no dirty flags means it enters neither set and is not recreated.
    /// Recovery applies only to dirty rows; recreating every missing stored row would undo every remote
    /// deletion.
    func testACleanRowDeletedRemotelyIsNeverRevived() async throws {
        let store = try makeRuleStore()
        try await seed(Self.threeSeeds, in: store)
        let loaded = editorRows(store)
        try await landRemote([.delete(syncId: "r1")], in: store)

        let edits = editSet(rows: loaded, loaded: loaded, store: store)
        XCTAssertTrue(edits.isEmpty, "No dirty flags means neither edit set contains the row")
        let after = try snapshot(store)
        XCTAssertEqual(after.count, 2, "Storage gains no rows")
    }

    // MARK: CASE U-15g (recovery encounters a soft-deleted row; R-M3-4a-104 / Task 5 ruling 8)

    /// Use U-15f's same draft, but M2 soft-deletes the row while the sheet is open. allURLRules excludes it
    /// (R-M3-4a-51), so the editor cannot and need not distinguish soft from hard deletion. Save inserts a new
    /// live row with new id/syncId while preserving the soft-deleted row byte for byte. Its later applied
    /// tombstone deletes only that old row.
    /// The editor's live-only stored domain differs from the transaction's byId including soft-deleted rows
    /// (R-M3-4a-56). Updating that hidden row in place would report successful Save, then discard the user's
    /// edit when its tombstone hard-deletes it.
    func testTheRecoveryDraftHittingASoftDeletedRowMintsAFreshRowInstead() async throws {
        let store = try makeRuleStore()
        try await seed(Self.threeSeeds, in: store)
        let loaded = editorRows(store)

        var rows = loaded
        let index = try XCTUnwrap(rows.firstIndex { $0.storeId == Self.i1 })
        rows[index].value = "one-typed.example"
        let dirty: [UUID: URLRulesEditor.RowDirty] = [rows[index].id: .value]

        // With the sheet open, M2 soft-deletes row 2 through the production batch; do not assign deletedDate
        // manually.
        try await landRemote([.softDelete(syncId: "r1", mergePartnerSyncId: "r0")], in: store)
        let afterSoftDelete = try snapshot(store)
        XCTAssertEqual(afterSoftDelete.count, 3, "The row remains in storage")
        XCTAssertNotNil(afterSoftDelete[Self.i1]?.deletedDate)
        XCTAssertFalse(liveRules(store).contains { $0.id == Self.i1 }, "The default read path excludes it")

        let edits = editSet(rows: rows, loaded: loaded, dirty: dirty, store: store)
        let revived = try XCTUnwrap(edits.upserts.first)
        XCTAssertEqual(edits.upserts.count, 1)
        XCTAssertEqual(revived.id, Self.i1, "The same draft as U-15f retains the original id")
        XCTAssertNil(revived.syncId, "And syncId is nil")
        XCTAssertNotNil(revived.content)
        XCTAssertNotNil(revived.spaceId)
        XCTAssertNotNil(revived.sortOrder)

        try await apply(edits, to: store)              // Save succeeds without throwing

        let after = try snapshot(store)
        XCTAssertEqual(after.count, 4, "Storage gains one new live row")
        // The soft-deleted row is unchanged byte for byte.
        XCTAssertEqual(after[Self.i1], afterSoftDelete[Self.i1], "The soft-deleted row is unchanged byte for byte")
        // The new row has newly minted id and syncId.
        let fresh = try XCTUnwrap(after.values.first { $0.host == "one-typed.example" })
        XCTAssertNotEqual(fresh.id, Self.i1, "Newly minted id")
        XCTAssertNotNil(fresh.syncId)
        XCTAssertNotEqual(fresh.syncId, "r1", "Newly minted lowercase UUID")
        XCTAssertNil(fresh.deletedDate)
        XCTAssertNil(fresh.mergePartnerSyncId)
        XCTAssertEqual(fresh.pendingLocalEdit, true)
        // After load(), the sheet row retains its position and receives the new storeId.
        XCTAssertEqual(editorRows(store).compactMap(\.storeId), liveRules(store).map(\.id))
        // Rows 1 and 3 remain unchanged byte for byte.
        XCTAssertEqual(after[Self.i0]?.pendingLocalEdit, false)
        XCTAssertEqual(after[Self.i2]?.pendingLocalEdit, false)

        // Finally, the old row's tombstone is applied and hard-deletes only that row.
        try await store.hardDeleteURLRuleThrowing(syncId: "r1")
        let afterHardDelete = try snapshot(store)
        XCTAssertNil(afterHardDelete[Self.i1], "Hard-delete only the old soft-deleted row")
        XCTAssertEqual(afterHardDelete[fresh.id]?.syncId, fresh.syncId, "The new row is unchanged byte for byte")
        XCTAssertEqual(afterHardDelete[fresh.id]?.pendingLocalEdit, true)
    }

    /// Live-row control: without M2 soft deletion, ordinary M5 content-only upsert updates in place,
    /// preserving I2/r1 and setting pendingLocalEdit. Creation is specific to the soft-deleted match; nil
    /// syncId alone must not force insertion.
    func testADirtyRowStillInTheStoreTakesTheOrdinaryPerUnitBranch() async throws {
        let store = try makeRuleStore()
        try await seed(Self.threeSeeds, in: store)
        let loaded = editorRows(store)

        var rows = loaded
        let index = try XCTUnwrap(rows.firstIndex { $0.storeId == Self.i1 })
        rows[index].value = "one-typed.example"
        let edits = editSet(rows: rows, loaded: loaded,
                            dirty: [rows[index].id: .value], store: store)
        XCTAssertEqual(edits.upserts.map(\.id), [Self.i1])
        XCTAssertEqual(edits.upserts.first?.syncId, "r1", "Matching a live row preserves identity")
        XCTAssertNil(edits.upserts.first?.spaceId, "Contains only the content unit")
        XCTAssertNil(edits.upserts.first?.sortOrder)
        try await apply(edits, to: store)

        let after = try snapshot(store)
        XCTAssertEqual(after.count, 3, "Row count is unchanged")
        XCTAssertEqual(after[Self.i1]?.syncId, "r1")
        XCTAssertEqual(after[Self.i1]?.host, "one-typed.example")
        XCTAssertEqual(after[Self.i1]?.pendingLocalEdit, true)
    }


    /// 8b-4 fix round 2: a row removed in the open sheet remains in storage until Save. Refresh's append logic
    /// must include removed in the represented set or it will append the removed row as new, visually undoing
    /// deletion while removedRows still schedules it for soft deletion. Remove row 2, land a remote new row,
    /// refresh: row 2 stays absent, new row appears, and Save still deletes I2.
    func testARowDeletedInTheSheetIsNotReAppendedByARefresh() async throws {
        let store = try makeRuleStore()
        try await seed(Self.threeSeeds, in: store)
        let loaded = editorRows(store)

        // User removes row 2: the value-level coordinator equivalent moves it from rows into removed.
        var rows = loaded
        let index = try XCTUnwrap(rows.firstIndex { $0.storeId == Self.i1 })
        let removed = [rows.remove(at: index)]
        XCTAssertEqual(removed.first?.storeId, Self.i1)

        // Another device lands a new rule while the sheet is open.
        try await landRemote([.create(landingValues(syncId: "r9", spaceId: Self.t11SpaceA,
                                                    host: "nine.example", sortOrder: 9,
                                                    stamp: 2_000))], in: store)

        let refreshed = refresh(rows: rows, loaded: loaded, removed: removed, store: store)
        let storeIds = refreshed.rows.compactMap(\.storeId)
        XCTAssertFalse(storeIds.contains(Self.i1),
                       "Do not reappend the removed row, which remains stored but absent from the sheet")
        XCTAssertTrue(refreshed.rows.contains { $0.value == "nine.example" },
                      "Actually new rows are still appended")
        XCTAssertEqual(refreshed.rows.count, 3, "3 - 1 removed + 1 new")
        XCTAssertTrue(refreshed.droppedIds.isEmpty)
        XCTAssertTrue(refreshed.changedIds.isEmpty, "The two remaining rows retain identical values")

        // Save still includes that row in deletedIds.
        let edits = editSet(rows: refreshed.rows, loaded: refreshed.loaded, removed: removed,
                            store: store)
        XCTAssertEqual(edits.deletedIds, [Self.i1], "Refresh preserves deletion intent")
        XCTAssertTrue(edits.upserts.isEmpty, "Remaining and newly appended rows have no dirty flags")
        try await apply(edits, to: store)

        let after = try snapshot(store)
        XCTAssertNotNil(after[Self.i1]?.deletedDate, "The row is soft-deleted")
        XCTAssertEqual(after[Self.i1]?.pendingLocalEdit, false, "Deletion is not an edit")
        XCTAssertEqual(liveRules(store).count, 3, "I0 / I3 / the newly landed row")
    }

    /// Control: passing empty removed reproduces the former domain and re-appends the deleted row as newly
    /// discovered. seen must include rows ∪ removed.
    func testTheRefreshWouldReAppendADeletedRowIfRemovedWereNotInTheDomain() async throws {
        let store = try makeRuleStore()
        try await seed(Self.threeSeeds, in: store)
        let loaded = editorRows(store)
        var rows = loaded
        let index = try XCTUnwrap(rows.firstIndex { $0.storeId == Self.i1 })
        rows.remove(at: index)

        let refreshed = refresh(rows: rows, loaded: loaded, removed: [], store: store)
        XCTAssertTrue(refreshed.rows.compactMap(\.storeId).contains(Self.i1),
                      "Omitting removed from the domain reappends the row, reproducing the previous defect")
    }

}

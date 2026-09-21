import Foundation
import XCTest
@testable import Phi

/// Module tests for SyncableOwnedItems and BookmarkKind: no SwiftData, engine,
/// or persistence; all inputs and outputs are values. MainActor is required only
/// for the shared Task 0 FakeBookmarkAccess/FakePinAccess used by this test family;
/// the module itself needs no actor.
@MainActor
final class SyncableOwnedItemsTests: XCTestCase {

    private let resolve = OwnerResolver.fixture()

    // MARK: - Helpers

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

    /// Live cursor with baseline and owner, read by plan's delete ordering and the three tombstone criteria.
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

    /// Match every local content field to bookmarkPayload defaults so unchanged
    /// cases produce bytes equal to the baseline. createdDate is one second,
    /// matching the payload's default createdAtMs=1000.
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

    /// CASE 4a.1: unresolved owner parks the entity. Wait for its Space without
    /// discarding, guessing, or leaving local traces that the next diff could publish as intent.
    func testAnArrivalWhoseOwnerDoesNotResolveIsParkedRatherThanLandedOrDropped() {
        let plan = planned([arrival(bookmarkPayload(uuid: "b1", spaceUuid: "su-unknown"))])

        let steps = plan.steps
        let parkedKeys = Set(plan.parked.keys)
        XCTAssertTrue(steps.isEmpty)
        XCTAssertEqual(parkedKeys, ["b1"])
    }

    // MARK: - CASE 4a.2 / 4a.3

    /// CASE 4a.2: apply a three-level tree arriving out of order in one round.
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

    /// CASE 4a.3: apply a shuffled five-level tree in one round. Arrival-order
    /// processing would defer each level and require five rounds.
    func testAFiveLevelTreeStillLandsInOneRoundWhateverTheArrivalOrder() {
        let chain = ["n1", "n2", "n3", "n4", "n5"]
        var arrivals: [OwnedItemArrival<Phi_PhiBookmarkEntity>] = []
        for (depth, uuid) in chain.enumerated() {
            arrivals.append(arrival(bookmarkPayload(uuid: uuid,
                                                    parentUuid: depth == 0 ? "" : chain[depth - 1],
                                                    isFolder: depth < chain.count - 1)))
        }
        // Shuffle arrivals independently of chain order.
        let shuffled = [arrivals[3], arrivals[0], arrivals[4], arrivals[2], arrivals[1]]

        let plan = planned(shuffled)

        let identities = plan.steps.map(\.identity)
        let parkedKeys = Array(plan.parked.keys)
        XCTAssertEqual(identities, chain)
        XCTAssertTrue(parkedKeys.isEmpty)
    }

    // MARK: - CASE 4a.4

    /// CASE 4a.4: refuse both cycle members without trapping. Remote bytes are
    /// untrusted, not a local bug; parking waits forever for an impossible parent.
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

    /// CASE 4a.5: promote children only when the parent is confirmed dead.
    /// Promotion changes fields and republishes them so devices converge.
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

    /// CASE 4a.6: a child also carrying a tombstone is deleted with its parent, without promotion.
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

    /// CASE 4a.7: merely absent parents park children, in all three negative cases.
    /// None proves parent death; promotion would move an intact subtree to the
    /// Space root and publish that incorrect location to every device.
    func testAMerelyAbsentParentParksTheChildInsteadOfLiftingIt() {
        let childArrival = arrival(bookmarkPayload(uuid: "child", parentUuid: "parent"))

        // ① Parent decryption failed and its tag is unreadable. A cursor identifies it,
        // but it never applied, so it has neither local row nor baseline.
        var unreadableTable = PhiOwnedItemTable()
        unreadableTable.cursors["parent"] = PhiOwnedItemCursor()
        unreadableTable.cursors["child"] = landedCursor(
            bookmarkPayload(uuid: "child", parentUuid: "parent"), entityId: "srv-c")

        // ② §4.6 refuses this round's parent for an invalid rank.
        let refusedParent = arrival(bookmarkPayload(uuid: "parent", rank: "V0", isFolder: true))

        // ③ The parent has not arrived.
        let cases: [(name: String, arrivals: [OwnedItemArrival<Phi_PhiBookmarkEntity>],
                     table: PhiOwnedItemTable)] = [
            ("Unreadable parent", [childArrival], unreadableTable),
            ("Refused parent", [childArrival, refusedParent], parentChildTable()),
            ("Absent parent", [childArrival], PhiOwnedItemTable()),
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

    /// CASE 4a.8: refuse invalid rank without calling rankBetween. Its precondition
    /// traps even in release builds, so isLegalRank is the sole decoding boundary
    /// for untrusted ranks. Bookmark ranks compare only within one parent; an invalid
    /// one can corrupt an entire folder's ordering.
    func testAnIllegalRankIsRefusedAndNeverReachesRankBetween() {
        // Cover all three invalid forms from §4.6; one case might test only the character-set guard.
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

    /// CASE 4a.9: root items' two location members share a stamp (7a).
    /// Deliberately distinguish content stamp 2000 from now=5000. R-M3-3-28 first-publish
    /// stamps and §4.2 rule 5 supersede A13's restamp-other-fields rule. Bookmarks
    /// have no other LWW fields: only two location members, rank, and four content
    /// fields. This and CASE 4a.20 independently test the same rule.
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
        XCTAssertEqual(entity?.title.updatedAtMs, 2_000, "Content fields use the row's own content stamp")
        XCTAssertNotEqual(entity?.title.updatedAtMs, 5_000, "Never stamp now")
    }

    /// CASE 4a.10: pure reorder restamps only rank (7b, first half).
    func testAPureReorderRestampsOnlyTheRank() {
        // Baseline rank order puts b2(k) after b1(V); dragging b2 ahead requires a new rank only for b2.
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

    /// CASE 4a.20: first-publish timestamps for a row without a baseline (10).
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

    // MARK: - CASE 4a.11–4a.14: Merge

    /// CASE 4a.11: coherence gives the same result in both directions (7c).
    /// Taking remote rank only when remote location wins fixes only one direction.
    /// When local location wins but remote rank is newer, plain LWW would attach a
    /// rank minted in the losing location to the winner, producing different results on the two devices.
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

    /// CASE 4a.12: three-way merge is order-independent (7d, first half).
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

    /// CASE 4a.13: depth selects the carrier, never max (N1 probe).
    /// max(space, parent) would choose 900 and win this merge; devices choosing
    /// different carriers for the same entities would never converge in location.
    func testTheLocationTimestampComesFromTheCarrierNeverFromTheLargerMember() {
        var descendant = bookmarkPayload(uuid: "b1", parentUuid: "p1", locationStamp: 100)
        descendant.spaceUuid = stamped("su-1", at: 900)
        let rival = bookmarkPayload(uuid: "b1", parentUuid: "p2", locationStamp: 500)

        let carrierStamp = BookmarkKind.locationStamp(of: descendant)
        let merged = BookmarkKind.merge(local: descendant, remote: rival)

        XCTAssertEqual(carrierStamp, 100)
        XCTAssertEqual(merged.parentUuid.stringValue, "p2")
    }

    /// CASE 4a.14: ties use lexicographic byte order (7e).
    func testATiedLocationIsBrokenDeterministicallyAndSymmetrically() {
        let a = bookmarkPayload(uuid: "b1", spaceUuid: "su-1", locationStamp: 100)
        let b = bookmarkPayload(uuid: "b1", spaceUuid: "su-2", locationStamp: 100)

        let forward = BookmarkKind.merge(local: a, remote: b)
        let backward = BookmarkKind.merge(local: b, remote: a)

        XCTAssertEqual(forward, backward)
        XCTAssertEqual(forward.spaceUuid.stringValue, "su-2")
    }

    // MARK: - CASE 4a.15 / 4a.16

    /// CASE 4a.15: descendant space_uuid does not participate in change detection
    /// (7b, second half, part 1). Its Space derives from its parent; including it
    /// would dirty every descendant on each cross-Space move.
    func testADescendantsSpaceUuidDoesNotParticipateInChangeDetection() {
        let baseline = bookmarkPayload(uuid: "c1", spaceUuid: "su-1", parentUuid: "p1")
        var table = PhiOwnedItemTable()
        table.cursors["p1"] = landedCursor(bookmarkPayload(uuid: "p1", isFolder: true))
        table.cursors["c1"] = landedCursor(baseline)
        // Retag the entire subtree to space-b; only the folder has a real location change.
        let locals = [row(identity: "p1", spaceId: "space-b", isFolder: true),
                      row(identity: "c1", spaceId: "space-b", parentGuid: "g-p1")]

        let result = SyncableOwnedItems.snapshot(BookmarkKind.self, locals: locals, table: table,
                                                 resolve: resolve, scope: nil, now: 5_000)

        let produced = bytes(result.entities["c1"])
        let expected = bytes(baseline)
        XCTAssertNotNil(produced)
        XCTAssertEqual(produced, expected)
    }

    /// CASE 4a.16: moving a folder with 40 descendants across Spaces produces one
    /// commit (7b, second half, part 2). Sending 41 instead scales to thousands
    /// of unnecessary writes during large reorganizations.
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
            // Strictly increasing single-character ranks match local and baseline order, requiring no reordering.
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

    /// CASE 4a.17: three tombstone criteria plus two exclusions (8).
    /// §4.7 warns that treating §4.2's ineligible-owner exclusions as missing local
    /// rows can delete every bookmark in an account Space during a mapping fluctuation.
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

    /// CASE 4a.17b: both exclusions count toward excluded_unmapped_owner (V21).
    /// §11.2 includes both; logging only one makes an entire exclusion class invisible.
    func testBothOwnerExclusionsAreCountedSeparatelyButBelongToOneLogField() {
        // b3 probes C1: a descendant's binding is its parent bookmark UUID, which
        // always passes isEligibleSpace. Check the actual containing Space or every
        // nonroot row under a soft-deleted Space keeps publishing until retention purge destroys it.
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
        XCTAssertEqual(ineligible, 2, "Exclude both root and descendant rows")
        XCTAssertEqual(produced, 0)
    }

    /// CASE 4a.18: the two parked cases require opposite outcomes (8a).
    /// This C1 regression can delete remote data. Assert cursorUpdates, because
    /// the pure function receives a value copy and cannot mutate the caller's table.
    func testAParkedEntityOnlyTombstonesWhenThisDeviceHadAlreadyLandedIt() {
        var table = PhiOwnedItemTable()
        // p1 has only pendingApply and has never landed locally.
        var neverLanded = PhiOwnedItemCursor()
        neverLanded.entityId = "srv-p1"
        neverLanded.version = 7
        neverLanded.pendingApply = baselineBytes(bookmarkPayload(uuid: "p1"))
        neverLanded.ownerUuid = "su-1"
        table.cursors["p1"] = neverLanded
        // p2 applied before parking, and the user has since deleted its local row.
        var landedThenParked = landedCursor(bookmarkPayload(uuid: "p2"),
                                            entityId: "srv-p2", version: 9)
        landedThenParked.pendingApply = baselineBytes(bookmarkPayload(uuid: "p2", title: "\u{65b0}"))
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

    /// CASE 4a.18b: parked items carry the owner UUID they await (V19 / §4.4 step 4).
    /// Without this path pendingOwnerUuid stays nil, forcing every parked item to
    /// redecode its whole tree each round just to decide whether it can retry.
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

    /// CASE 4a.19: snapshot immediately after apply restamps nothing (9).
    /// Assert timestamps field by field; signature clears updatedAtMs by definition,
    /// so signature equality would miss restamping every field with now and infinite device echoes.
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

    /// CASE 4a.21: created_at_ms takes the minimum; source takes the nonzero value, or the smaller of two nonzero values (11).
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

    /// CASE 4a.22: preserve unknown fields through merge (12). Merge must start
    /// from remote; starting from local erases newer-client fields every round.
    func testUnknownFieldsSurviveAMerge() throws {
        var raw = try bookmarkPayload(uuid: "b1").serializedData()
        // Field 12, first of reserved 12–15, with wire type 0: tag = 12 << 3 = 0x60.
        raw.append(contentsOf: [0x60, 0x2A])
        let remote = try Phi_PhiBookmarkEntity(serializedBytes: raw)

        let merged = BookmarkKind.merge(local: bookmarkPayload(uuid: "b1"), remote: remote)

        let arrived = remote.unknownFields.data.isEmpty
        let survived = merged.unknownFields.data.isEmpty
        XCTAssertFalse(arrived)
        XCTAssertFalse(survived)
    }
}

// MARK: - Adoption (§6 rule i)

extension SyncableOwnedItemsTests {

    /// Local folder placeholder URL from LocalStore+Bookmark.swift. All folders
    /// share it, so folders must never participate in URL-based comparisons.
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
                         contentUpdatedDate: Date? = nil,
                         locationUpdatedDate: Date? = nil) -> PhiLocalBookmark {
        PhiLocalBookmark.fixture(guid: guid, syncId: identity, spaceId: spaceId,
                                 parentGuid: parentGuid, index: index, title: title,
                                 url: URL(string: url)!,
                                 createdDate: Date(timeIntervalSince1970: 1),
                                 contentUpdatedDate: contentUpdatedDate,
                                 locationUpdatedDate: locationUpdatedDate)
    }

    /// CASE 4a.23 (spec 13): basic adoption claims a local row rather than copying it.
    func testAnIncomingEntityAdoptsAMatchingUnsyncedLocalRow() {
        let local = markRow(identity: nil, guid: "g1", url: "https://e.example")

        let result = SyncableOwnedItems.adopt(arrivals: [bookmarkPayload(uuid: "b1")],
                                              locals: [local], resolve: resolve)

        let pairedGuid = result.pairs["b1"]
        let adopted = result.adopted
        XCTAssertEqual(pairedGuid, "g1")
        XCTAssertEqual(adopted, 1)
    }

    /// CASE 4a.24 (spec 13a / 13a′): field merge and republication. If local wins
    /// without publishing, the remote remains stale while both devices consider themselves converged.
    func testAdoptionMergesFieldByFieldAndRepublishesWhenALocalFieldWins() {
        // The local title changed during join with a newer stamp. Without a local
        // location baseline, take remote location fields.
        let local = markRow(identity: nil, guid: "g1", url: "https://e.example",
                            title: "\u{672c}\u{673a}\u{6807}\u{9898}", contentUpdatedDate: Date(timeIntervalSince1970: 900))
        let remote = bookmarkPayload(uuid: "b1", spaceUuid: "su-1", rank: "k", title: "\u{8fdc}\u{7aef}\u{6807}\u{9898}",
                                     locationStamp: 100, rankStamp: 100, contentStamp: 100)

        let adoption = SyncableOwnedItems.adopt(arrivals: [remote], locals: [local],
                                                resolve: resolve)

        // Assert module output. Merge logic written only in the test would let an
        // engine blindly adopting remote values pass, despite §6.2 explicitly forbidding it.
        let merged = mergedEntity(adoption, "b1")
        let pairedGuid = adoption.pairs["b1"]
        let title = merged?.title.stringValue
        let rank = merged?.rank.stringValue
        let locationStamp = merged.map(BookmarkKind.locationStamp(of:))
        let republishes = adoption.mustRepublish.contains("b1")
        XCTAssertEqual(pairedGuid, "g1")
        XCTAssertEqual(title, "\u{672c}\u{673a}\u{6807}\u{9898}")
        XCTAssertEqual(rank, "k")
        XCTAssertEqual(locationStamp, 100)
        XCTAssertTrue(republishes)
    }

    /// The claiming projection stays at location stamp 0 even for a row the user moved locally
    /// (schema V13). The location projected here is the ARRIVAL's -- `recordMerge` takes
    /// `parentIdentity` from the remote entity -- so letting `locationUpdatedDate` stamp it would
    /// hand an unchanged location a stamp above the account's and republish every adopted row.
    func testAdoptionKeepsLocationAtStampZeroEvenForALocallyMovedRow() {
        let moved = markRow(identity: nil, guid: "g1", url: "https://e.example",
                            locationUpdatedDate: Date(timeIntervalSince1970: 9_000_000))
        // Every remote stamp is above the local row's derived content stamp, so the ONLY thing that
        // could make this pair republish is the location group.
        let remote = bookmarkPayload(uuid: "b1", spaceUuid: "su-1", locationStamp: 100,
                                     rankStamp: 2_000, contentStamp: 2_000)

        let adoption = SyncableOwnedItems.adopt(arrivals: [remote], locals: [moved],
                                                resolve: resolve)

        let merged = mergedEntity(adoption, "b1")
        XCTAssertEqual(merged.map(BookmarkKind.locationStamp(of:)), 100)
        XCTAssertFalse(adoption.mustRepublish.contains("b1"),
                       "an adopted row whose location did not change must not republish")
    }

    /// Decode the merged entity produced by adopt.
    private func mergedEntity(_ result: OwnedItemAdoptionResult,
                              _ identity: String) -> Phi_PhiBookmarkEntity? {
        guard let bytes = result.merges[identity],
              let envelope = try? Phi_PhiEntity(serializedBytes: bytes) else { return nil }
        return BookmarkKind.entity(from: envelope)
    }

    /// CASE 4a.24b (spec 13a′): updatedDate advances without contentUpdatedDate (V29).
    /// §6.2 rejects updatedDate as a sync stamp because lastSeen/favicon/index
    /// maintenance advances it, letting untouched local values beat real remote edits.
    /// PhiLocalBookmark structurally omits that column; this regression fails if it returns.
    func testTheLocalStampIsContentUpdatedDateSoATouchedRowStillLosesToARealEdit() {
        // Opening updates lastSeen/updatedDate but not contentUpdatedDate. The local
        // comparison stamp remains the much older createdDate, so remote content wins.
        let touched = PhiLocalBookmark.fixture(guid: "g1", spaceId: "space-a", title: "\u{672c}\u{673a}\u{65e7}\u{503c}",
                                               createdDate: Date(timeIntervalSince1970: 0.05))
        let remote = bookmarkPayload(uuid: "b1", title: "\u{8fdc}\u{7aef}\u{6539}\u{540d}", contentStamp: 100,
                                     createdAtMs: 50)

        let adoption = SyncableOwnedItems.adopt(arrivals: [remote], locals: [touched],
                                                resolve: resolve)

        let fields = Mirror(reflecting: touched).children.compactMap(\.label)
        let merged = mergedEntity(adoption, "b1")
        let title = merged?.title.stringValue
        let republishes = adoption.mustRepublish.contains("b1")
        XCTAssertFalse(fields.contains("updatedDate"), "Restoring this column must fail the test")
        XCTAssertEqual(title, "\u{8fdc}\u{7aef}\u{6539}\u{540d}")
        XCTAssertFalse(republishes, "No local field won, so no commit is needed")
    }

    /// CASE 4a.25 (spec 13b): adoption across rounds. Rule i is stateless and
    /// continuous (R-M3-3-28); running only on a Space's first merge creates duplicate
    /// local rows for entities arriving in later rounds.
    func testRuleOneKeepsAdoptingOnLaterRoundsAndUsesAdoptedParentsAsAnchors() {
        let folder = folderRow(identity: nil, guid: "g-folder", title: "F")
        let firstRound = SyncableOwnedItems.adopt(
            arrivals: [bookmarkPayload(uuid: "f1", isFolder: true, title: "F",
                                       url: Self.folderPlaceholder.absoluteString)],
            locals: [folder], resolve: resolve)

        // Write the first round's claimed identity to the local row before round 2.
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

    /// CASE 4a.26 (spec 13c): group by the full key, then pair by position.
    /// Grouping only by Space/path would pair rows with different URLs.
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

    /// CASE 4a.27 (spec 13d): never reassign an identified row. Reassignment
    /// orphaning b1 would make the next diff tombstone a real account bookmark
    /// merely because it looked duplicated.
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

    /// CASE 4a.28 (spec 13e): stable duplicates remain duplicates, without deletion.
    /// This is the core guarantee after removing automatic merging; deleting any
    /// lookalike row must fail here.
    func testDeliberateDuplicatesStayDuplicatesAndProduceNoTombstone() {
        let folder = folderRow(identity: "fd", guid: "g-fd", title: "\u{5939}")
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

    /// CASE 4a.29 (spec 13f): none of the three withdrawn mechanisms regains any fields.
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

    /// CASE 4a.30 (spec 13e counting): unmatchedFolders definition. §12.2 acceptance
    /// step 5 asserts adopted=3; both counts carry test meaning rather than merely filling logs.
    func testUnmatchedFoldersCountsIncomingFolderEntitiesThatFoundNoLocalRow() {
        let anchor = folderRow(identity: "pf", guid: "g-pf", title: "\u{7236}")
        let mine = folderRow(identity: nil, guid: "g-mine", title: "\u{672c}\u{673a}\u{5939}", parentGuid: "g-pf")

        let result = SyncableOwnedItems.adopt(
            arrivals: [bookmarkPayload(uuid: "rf", parentUuid: "pf", isFolder: true,
                                       title: "\u{8fdc}\u{7aef}\u{5939}",
                                       url: Self.folderPlaceholder.absoluteString)],
            locals: [anchor, mine], resolve: resolve)

        let unmatched = result.unmatchedFolders
        let adopted = result.adopted
        XCTAssertEqual(unmatched, 1)
        XCTAssertEqual(adopted, 0)
    }

    /// CASE 4a.31: never pair folders by URL. Their shared placeholder would
    /// collapse every sibling folder into one and orphan the removed folders' children.
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

// MARK: - Fix-round regressions (review C1 / C2 / I1 / I2 / I3 / M1 / M5)

extension SyncableOwnedItemsTests {

    /// C2: an entity both moved and renamed produces move and update. Move carries
    /// no field patch; content uses update. Emitting only move loses the rename,
    /// then the next snapshot overwrites the account with the old local title,
    /// silently destroying the remote edit while both devices report convergence.
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

    /// C2, other half: remote timestamp-only changes produce no steps. Comparing
    /// whole entities including timestamps would generate empty patches for every restamp.
    func testAPeersPureRestampProducesNoStepAtAll() {
        var table = PhiOwnedItemTable()
        table.cursors["b1"] = landedCursor(bookmarkPayload(uuid: "b1"))

        let plan = planned([arrival(bookmarkPayload(uuid: "b1", locationStamp: 400,
                                                    rankStamp: 400, contentStamp: 400))],
                           table: table)

        let steps = plan.steps.filter { $0.identity == "b1" }
        XCTAssertTrue(steps.isEmpty)
    }

    /// I3: refuse is_folder mismatch with an existing row instead of merging.
    /// Resolving the mismatch by union or choosing a side would legitimize a §4.6
    /// invalid payload; rows cannot transform between bookmarks and folders.
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

    /// I1: skip a row whose parent is not sync-eligible this round (§4.2 rule 2).
    /// Publishing children of a parked parent references a parent version not yet
    /// applied locally. This exclusion increments no counter; it is not an unmapped owner.
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

    /// I2: prove the rank probe is live. CASE 4a.8's zero rankBetweenCalls would
    /// always pass if rank generation bypassed the forwarding counter. A real
    /// reorder must make it nonzero.
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

    /// M1: never rewrite deleteDecidedAtMs on an already-pending cursor. A9 compares
    /// inbound location freshness against it; advancing it each round would prevent
    /// any concurrent move from cancelling deletion.
    func testARedecidedDeleteNeverPushesTheDecisionTimestampForward() {
        var cursor = pendingDeleteCursor(decidedAtMs: 1_000,
                                         reconciled: baselineBytes(bookmarkPayload(uuid: "b1")))
        cursor.ownerUuid = "su-1"
        cursor.pendingApply = baselineBytes(bookmarkPayload(uuid: "b1", title: "\u{65b0}"))
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

    /// R-exec-9: a claim not yet persisted differs from an unmatchable claim.
    /// Rule i can match a row this round while an import lock rejects syncId writeback.
    /// Without an exemption, the missing identity satisfies the deletion criterion
    /// and tombstones an entity both sides agree exists; next round remints it,
    /// showing the remote an unrelated delete/create pair.
    /// Conversely, a parked cursor that no longer matches because the user edited
    /// during retry must remain deletable. Exempting all pendingApply cursors would
    /// leave permanent account entities no device can remove.
    func testAParkedCursorIsExemptOnlyWhileItsClaimIsStillPending() {
        var table = PhiOwnedItemTable()
        for identity in ["claimed", "unclaimable"] {
            var cursor = landedCursor(bookmarkPayload(uuid: identity))
            cursor.pendingApply = baselineBytes(bookmarkPayload(uuid: identity))
            table.cursors[identity] = cursor
        }

        let result = SyncableOwnedItems.tombstones(BookmarkKind.self, locals: [], table: table,
                                                   resolve: resolve, scope: nil, nowMs: 5_000,
                                                   pendingClaims: ["claimed"])

        let identities = result.identities
        let exempt = result.cursorUpdates["claimed"]
        XCTAssertEqual(identities, ["unclaimable"])
        XCTAssertNil(exempt, "Do not change any field of the exempt cursor")
    }

    /// M4: a cursor whose ownerUuid has not been refreshed sends no tombstone.
    /// The engine must refresh every cursor each round; nil means that prerequisite
    /// failed, which this module cannot verify, so remain conservative.
    func testACursorWithNoRefreshedOwnerNeverTombstones() {
        var table = PhiOwnedItemTable()
        table.cursors["b1"] = landedCursor(bookmarkPayload(uuid: "b1"), ownerUuid: nil)

        let result = SyncableOwnedItems.tombstones(BookmarkKind.self, locals: [], table: table,
                                                   resolve: resolve, scope: nil, nowMs: 5_000)

        let identities = result.identities
        XCTAssertTrue(identities.isEmpty)
    }

    /// M5: an arrival with empty UUID increments refused once.
    func testAnArrivalWithAnEmptyUuidCountsAsRefused() {
        let plan = planned([arrival(bookmarkPayload(uuid: ""))])

        let refused = plan.refused
        let steps = plan.steps
        XCTAssertEqual(refused, 1)
        XCTAssertTrue(steps.isEmpty)
    }
}

// MARK: - Fix-round 2 regressions (review F1 / F2)

extension SyncableOwnedItemsTests {

    /// Decode the entity carried by a plan step.
    private func stepEntity(_ plan: OwnedItemPlan, _ identity: String,
                            _ kind: StepKind) -> Phi_PhiBookmarkEntity? {
        guard let payload = plan.steps.first(where: { $0.identity == identity && $0.kind == kind })?
                .payload,
              let envelope = try? Phi_PhiEntity(serializedBytes: payload) else { return nil }
        return BookmarkKind.entity(from: envelope)
    }

    /// Feed adoption output into plan exactly as the engine will.
    private func adoptionContext(_ result: OwnedItemAdoptionResult) -> OwnedItemPlanContext {
        var context = OwnedItemPlanContext()
        context.pairs = result.pairs
        context.adoptedMerges = result.merges
        context.adoptedFieldWrites = result.fieldWrites
        return context
    }

    /// F1(a): apply the merged result for an adopted identity, not the remote original.
    /// Ignoring context.adoptedMerges implements §6.2's forbidden wholesale adoption
    /// and loses the winning local title. Assert both claim and update: claim writes
    /// only syncId, while update carries content; omitting either loses the merge.
    func testAClaimedIdentityLandsTheMergedEntityRatherThanTheRemoteWholesale() {
        // Local title is newer, while remote secondary_title is newer. Each side
        // wins a field, requiring both republication and a local content write.
        let local = markRow(identity: nil, guid: "g1", url: "https://e.example",
                            title: "\u{672c}\u{673a}\u{6807}\u{9898}", contentUpdatedDate: Date(timeIntervalSince1970: 900))
        var remote = bookmarkPayload(uuid: "b1", spaceUuid: "su-1", rank: "k", title: "\u{8fdc}\u{7aef}\u{6807}\u{9898}",
                                     locationStamp: 100, rankStamp: 100, contentStamp: 100)
        remote.secondaryTitle = stamped("\u{8fdc}\u{7aef}\u{526f}\u{6807}\u{9898}", at: 1_000_000)

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
        XCTAssertEqual(claimedTitle, "\u{672c}\u{673a}\u{6807}\u{9898}", "The locally winning content field")
        XCTAssertEqual(claimedSecondary, "\u{8fdc}\u{7aef}\u{526f}\u{6807}\u{9898}", "The remotely winning content field")
        XCTAssertEqual(claimedRank, "k", "Take the remote location")
        XCTAssertEqual(claimedLocation, 100, "Take the remote location")
        XCTAssertEqual(patched, claimed, "Both steps carry the same merged result")
        XCTAssertTrue(republishes)
    }

    /// F1(b): byte-identical local and remote rows need only claim, without
    /// republication. Unconditional update emits empty patches for potentially
    /// thousands of first-sync adoptions.
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

    /// F2: failed merge invalidates the pair, never falling back to wholesale
    /// remote adoption and losing join-time user edits. Build inconsistent forward
    /// and reverse owner lookup: localSpaceId resolves su-1, but syncUuid cannot
    /// resolve space-a, preventing projection from obtaining the Space UUID.
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

/// PinKind module tests, likewise without SwiftData, engine, or persistence.
/// Use a separate class because pin arrival/planned/row helpers share bookmark
/// names with different types, otherwise requiring annotations at every call.
/// MainActor is needed for CASE 4b.2's FakePinAccess contract check.
@MainActor
final class PinKindTests: XCTestCase {

    private let resolve = OwnerResolver.fixture()

    /// Resolver maps literal app to itself, as engine construction must in Tasks
    /// 5b/6. tombstones checks ownership through localSpaceId/localProfileId; if
    /// neither resolves app, §4.2 rule 1 skips it forever, preventing deletion of
    /// App pins and resurrecting them on new devices (CASE 4b.4b). A special case
    /// in tombstones would instead weaken the shared unmapped-owner rule protecting
    /// whole Space bookmark collections during mapping fluctuations (§4.7).
    private let resolveWithApp = OwnerResolver.fixture(
        profileUuids: ["Default": "pu-1", "app": "app"])

    // MARK: - Helpers

    /// Match local content to pinPayload defaults so unchanged cases equal baseline
    /// bytes. createdDate of one second matches default createdAtMs=1000.
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

    /// Live cursor with baseline and owner.
    private func landedCursor(_ payload: Phi_PhiPinTabEntity,
                              entityId: String = "srv-1",
                              version: Int64 = 1,
                              ownerUuid: String? = "su-1") -> PhiOwnedItemCursor {
        ownedCursor(reconciled: baselineBytes(payload), entityId: entityId,
                    version: version, ownerUuid: ownerUuid)
    }

    // MARK: - CASE 4b.1

    /// CASE 4b.1 (spec 7c): pins have no location; one lineage under two owners
    /// means two entities, and rank uses ordinary LWW. Owner is half the identity
    /// (R-M3-3-15). Treating it as mergeable or keying only by lineage collapses
    /// Space pins in the dictionary, leaving one unsyncable and undeletable remotely.
    /// Bookmark rank coherence would query a nonexistent location and depend on a constant equality.
    func testOneLineageInThreeOwnersIsThreeEntitiesAndItsRankIsPlainLastWriterWins() {
        // §12.1 item 7c: one lineage in three Spaces produces three entities without
        // dictionary overwrites. Three makes the common entities[lineage] bug clearly
        // retain only the last item, rather than merely appearing to lose one of two.
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

        // For one identity, newer rank wins symmetrically, without any location field.
        let older = pinPayload(lineage: "lx", ownerKey: "su-1", rank: "a", rankStamp: 100)
        let newer = pinPayload(lineage: "lx", ownerKey: "su-1", rank: "b", rankStamp: 200)
        let forward = PinKind.merge(local: older, remote: newer).rank.stringValue
        let backward = PinKind.merge(local: newer, remote: older).rank.stringValue
        XCTAssertEqual(forward, "b")
        XCTAssertEqual(backward, "b")
    }

    // MARK: - CASE 4b.2 / 4b.3 / 4b.3b

    /// CASE 4b.2 (spec 8b first sentence): dormant-only lineages are excluded from
    /// snapshot but produce tombstones; spec v3 incorrectly said otherwise (V12).
    /// allPins includes only active-scope nondormant rows, so all three deletion
    /// criteria hold. Suppressing deletion would keep user-hidden pins in the account
    /// and restore them on every new device. Assert both the fake access filter
    /// and PinKind's exclusion when handed a dormant row directly.
    func testALineageLeftWithOnlyADormantRowLeavesTheSnapshotButStillTombstones() throws {
        let dormant = pinRow(guid: "p1", spaceId: "space-a", isDormant: true)
        var table = PhiOwnedItemTable()
        table.cursors["lx:su-1"] = landedCursor(pinPayload(lineage: "lx", ownerKey: "su-1"))
        let access = FakePinAccess(scope: .space, account: .space, rows: [dormant])

        let visible = try access.allPins()
        let published = snapshot([dormant], table: table).entities
        let result = tombstones([dormant], table: table)

        let visibleCount = visible.count
        let publishedCount = published.count
        let identities = result.identities
        XCTAssertEqual(visibleCount, 0, "allPins includes all nondormant rows only")
        XCTAssertEqual(publishedCount, 0)
        XCTAssertEqual(identities, ["lx:su-1"])
    }

    /// CASE 4b.3 (spec 8b third sentence): same-lineage active copies under one
    /// owner produce a tombstone only when all disappear. Presence, not a changed
    /// count, is the criterion; closing one copy must not delete the account lineage.
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

    /// CASE 4b.3b (spec 8b second sentence / V27): with active and dormant copies,
    /// project only active rows and send no tombstone. Including dormant candidates
    /// can choose different projections and invent changes; counting dormant copies
    /// as presence contradicts CASE 4b.2.
    func testAnActiveRowBesideADormantBackupProjectsOnlyTheActiveOne() {
        let active = pinRow(guid: "p1", spaceId: "space-a", index: 0, title: "\u{6d3b}")
        let dormant = pinRow(guid: "p2", spaceId: "space-a", index: 1, title: "\u{4f11}\u{7720}",
                             isDormant: true)
        var table = PhiOwnedItemTable()
        table.cursors["lx:su-1"] = landedCursor(pinPayload(lineage: "lx", ownerKey: "su-1"))

        let published = snapshot([active, dormant], table: table).entities
        let identities = tombstones([active, dormant], table: table).identities

        let keys = Set(published.keys)
        let title = published["lx:su-1"]?.title.stringValue
        XCTAssertEqual(keys, ["lx:su-1"])
        XCTAssertEqual(title, "\u{6d3b}")
        XCTAssertEqual(identities, [])
    }

    // MARK: - CASE 4b.4 / 4b.4b / 4b.5

    /// CASE 4b.4 (spec 14): infer Space/Profile/App owners using §7.2. App has
    /// both ids nil; each pin belongs to exactly one owner. Check spaceId before
    /// profileId, because Space-scoped rows can have both populated.
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

        // A real Space-scoped row has both ids; spaceId still takes precedence.
        let bothSet = pinRow(guid: "p4", spaceId: "space-b", profileId: "Default")
        let derived = PinKind.eligibilityOwner(of: bothSet, resolve: resolve, scope: .space)
        XCTAssertEqual(derived, "su-2")
    }

    /// CASE 4b.4b: App cursors produce tombstones normally. If neither resolver
    /// recognizes app, unmapped-owner exclusion prevents deletion forever and new
    /// devices resurrect the pin. This passes only when the resolver maps app to
    /// itself, also checking the Tasks 5b/6 integration contract.
    func testAnAppScopedCursorStillTombstonesOnceTheResolverMapsTheLiteralToItself() {
        var table = PhiOwnedItemTable()
        table.cursors["lx:app"] = landedCursor(pinPayload(lineage: "lx", ownerKey: "app"),
                                               ownerUuid: "app")

        let mapped = tombstones([], table: table, resolve: resolveWithApp, scope: .app).identities
        let unmapped = tombstones([], table: table, resolve: resolve, scope: .app).identities

        XCTAssertEqual(mapped, ["lx:app"])
        XCTAssertEqual(unmapped, [], "Without app resolution, the cursor is incorrectly treated as unmapped")
    }

    /// CASE 4b.5: missing mapping excludes the pin without falling back to app.
    /// Fallback publishes a Space pin account-wide, making it appear in every Space remotely.
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

    /// CASE 4b.6: lineageKey normalization covers identity and client tag.
    /// pinClientTag is deliberately pure concatenation. Tag construction, §5.1
    /// index seeding, and application matching must all use lineageKey; omitting
    /// one makes hashes differ and §2.5 reject every pin as a forged payload.
    func testTheLineageKeyNormalizesOnceAndRunsThroughBothTheIdentityAndTheTag() {
        let key = PinKind.lineageKey("LX-Abc")
        let row = pinRow(lineageId: "LX-Abc", guid: "p1", profileId: "Default")

        let identity = PinKind.identity(of: row, resolve: resolve, scope: .profile)
        XCTAssertEqual(key, "lx-abc")
        XCTAssertEqual(identity, "lx-abc:pu-1")

        // The identity suffix matches the client-tag suffix exactly.
        let tag = identity.map { PinKind.tagPrefix + $0 }
        let built = PhiSyncEntity.pinClientTag(key, ownerKey: "pu-1")
        XCTAssertEqual(tag, built)
    }

    // MARK: - CASE 4b.7

    /// CASE 4b.7 (spec 14, second half): owner change is old-tag tombstone plus
    /// new-tag create. A field update leaves an unowned entity that diffing cannot
    /// delete; consequently PinApplyOp has no rebind operation.
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

    /// CASE 4b.8 (spec 14b / A11): relineage same-owner variants inside PinApplyBatch.
    /// An out-of-band publication pre-pass could crash after irreversible relineaging
    /// before publishing. Treating variants as physical copies of one entity instead
    /// leaves additional copies without identities, unable to sync or be deleted remotely.
    func testVariantsUnderOneOwnerAreRelineagedKeepingTheLowestIndexRow() {
        // Use distinct sync-field signatures (R-exec-12 / D-A2). Equal signatures
        // are physical copies collapsed by A11; real variants get new identities.
        // Give the second row a different title to exercise relineaging.
        let rows = [pinRow(guid: "p1", spaceId: "space-a", index: 0, title: "T"),
                    pinRow(guid: "p2", spaceId: "space-a", index: 1, title: "Variant")]

        let batch = PinKind.normalizeVariants(locals: rows)

        let ops = batch.ops
        XCTAssertEqual(ops.count, 1)
        guard case .relineage(let guid, let newLineageId)? = ops.first else {
            return XCTFail("Expected exactly one relineage")
        }
        XCTAssertEqual(guid, "p2", "The lowest-index row keeps the original lineage")
        XCTAssertNotEqual(newLineageId, "LX")
        XCTAssertNotEqual(PinKind.lineageKey(newLineageId), "lx")
        XCTAssertFalse(newLineageId.isEmpty)
        // The minted lineage must be normalized and valid under §4.6.
        XCTAssertEqual(PinKind.lineageKey(newLineageId), newLineageId)
    }

    /// CASE 4b.8 (4b-4): relineaging is deterministic across devices. A11 has two
    /// machines running the same migration on the same variants. Random UUIDs
    /// make each publish and then import the other's variant. §6.7 excludes pin
    /// adoption, so no deduplication removes the extra pins. Random minting must fail here.
    func testTheRemintedLineageIsDeterministicAcrossDevices() {
        // The same migrated rows on another device have different physical guids but
        // identical deterministic lineage/index values. Use three distinct signatures:
        // A11 collapses identical copies, covered separately below.
        let deviceA = [pinRow(guid: "p1", spaceId: "space-a", index: 0, title: "T"),
                       pinRow(guid: "p2", spaceId: "space-a", index: 1, title: "U"),
                       pinRow(guid: "p3", spaceId: "space-a", index: 2, title: "W")]
        let deviceB = [pinRow(guid: "q1", spaceId: "space-a", index: 0, title: "T"),
                       pinRow(guid: "q2", spaceId: "space-a", index: 1, title: "U"),
                       pinRow(guid: "q3", spaceId: "space-a", index: 2, title: "W")]

        let first = mintedLineages(PinKind.normalizeVariants(locals: deviceA))
        let again = mintedLineages(PinKind.normalizeVariants(locals: deviceA))
        let other = mintedLineages(PinKind.normalizeVariants(locals: deviceB))

        XCTAssertEqual(first.count, 2, "Relineage two of three variants, preserving the lowest-index row")
        XCTAssertEqual(first, again, "Identical inputs produce identical lineages on repeated runs")
        XCTAssertEqual(first, other, "The same migration on another device produces identical lineages")
        XCTAssertNotEqual(first[0], first[1], "Different ordinals produce different lineages")

        // The lowest-index row receives no operations.
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

    /// CASE 4b.8, second half: group by owner; the same lineage under different
    /// owners is not a variant. Grouping by lineage alone misclassifies normal
    /// Profile-to-Space fanout as N-1 variants to remint, creating device-specific extra pins.
    func testTheSameLineageInTwoOwnersIsNotAVariantAndIsNeverRelineaged() {
        let rows = [pinRow(guid: "p1", spaceId: "space-a"),
                    pinRow(guid: "p2", spaceId: "space-b")]

        let ops = PinKind.normalizeVariants(locals: rows).ops

        XCTAssertTrue(ops.isEmpty)
    }

    // MARK: - CASE 4b.8b: Collapse exact duplicates (R-exec-12 / D-A2)

    private func deletedGuids(_ batch: PinApplyBatch) -> [String] {
        batch.ops.compactMap {
            guard case .delete(let guid) = $0 else { return nil }
            return guid
        }
    }

    /// CASE 4b.8b (R-exec-12 / D-A2): same owner, lineage, and signature means
    /// two physical copies of one pin. Collapse them without relineaging.
    /// Mac B, 2026-09-14, build 821: mid-round migration created duplicate rows
    /// beside newly migrated ones. The old criterion ignored content and minted
    /// four new identities. Relineaging is irreversible: nothing merges distinct
    /// lineages afterward, so a transient collision became four permanent account
    /// duplicates requiring manual unpinning. mergeCandidates would merge the same
    /// rows (§7.1); both paths must agree on pin identity.
    func testTwoIdenticalRowsUnderOneIdentityAreCollapsedNotRelineaged() {
        // Identical fields except physical guid/index: two copies of the same pin.
        let rows = [pinRow(guid: "p-keep", spaceId: "space-a", index: 0),
                    pinRow(guid: "p-dup", spaceId: "space-a", index: 1)]

        let batch = PinKind.normalizeVariants(locals: rows)

        XCTAssertEqual(deletedGuids(batch), ["p-dup"],
                       "① Delete the highest-index copy and retain the lowest-index row")
        XCTAssertTrue(relineageGuids(batch).isEmpty,
                      "② Never relineage a collision into a permanent account duplicate")
        XCTAssertEqual(batch.ops.count, 1)
    }

    /// CASE 4b.8b, split partners: signatures include partner lineage; different
    /// partners mean real variants. Comparing only title/URL can collapse equal-content
    /// split halves and destroy half a view. Share the PinnedTabVariantSignature definition.
    func testRowsDifferingOnlyInTheirSplitPartnerAreVariantsNotDuplicates() {
        let rows = [pinRow(guid: "p1", spaceId: "space-a", index: 0,
                           splitPartnerLineageId: "lm"),
                    pinRow(guid: "p2", spaceId: "space-a", index: 1,
                           splitPartnerLineageId: "ln")]

        let batch = PinKind.normalizeVariants(locals: rows)

        XCTAssertTrue(deletedGuids(batch).isEmpty)
        XCTAssertEqual(relineageGuids(batch), ["p2"])
    }

    /// CASE 4b.8b, mixed group: two equal copies and one variant yield one delete
    /// and one relineage, with ordinal based on survivors. Assigning ordinal before
    /// collapse gives 2 instead of 1, making race-dependent duplicate presence
    /// produce different cross-device identities and permanent extra pins.
    func testAMixedGroupCollapsesTheDuplicateAndRelineagesOnlyTheDivergentMember() {
        let rows = [pinRow(guid: "p-keep", spaceId: "space-a", index: 0, title: "T"),
                    pinRow(guid: "p-dup", spaceId: "space-a", index: 1, title: "T"),
                    pinRow(guid: "p-variant", spaceId: "space-a", index: 2, title: "Variant")]

        let batch = PinKind.normalizeVariants(locals: rows)

        XCTAssertEqual(deletedGuids(batch), ["p-dup"])
        XCTAssertEqual(relineageGuids(batch), ["p-variant"])
        // Survivors are p-keep/p-variant, so use ordinal 1, exactly as if the group
        // had contained only the two real variants.
        let twoVariantsOnly = [pinRow(guid: "p-keep", spaceId: "space-a", index: 0, title: "T"),
                               pinRow(guid: "p-variant", spaceId: "space-a", index: 1,
                                      title: "Variant")]
        XCTAssertEqual(mintedLineages(batch),
                       mintedLineages(PinKind.normalizeVariants(locals: twoVariantsOnly)),
                       "Survivor-based ordinals produce identical lineages with or without the duplicate")
    }

    /// CASE 4b.8b, determinism: devices retain and delete corresponding copies.
    /// Choosing by device-local guid can keep opposite physical rows, leading to
    /// both copies being deleted. Use cross-device-stable fields: migration produces
    /// index deterministically, while each device mints its own guid.
    func testTheCollapseSurvivorIsTheSameRowOnTwoDevices() {
        // Both devices share deterministic indexes but mint different guids. Reverse
        // B's guid order so guid-based survivor selection must diverge.
        let deviceA = [pinRow(guid: "a-first", spaceId: "space-a", index: 0),
                       pinRow(guid: "a-second", spaceId: "space-a", index: 1)]
        let deviceB = [pinRow(guid: "z-first", spaceId: "space-a", index: 0),
                       pinRow(guid: "b-second", spaceId: "space-a", index: 1)]

        let onA = PinKind.normalizeVariants(locals: deviceA)
        let onB = PinKind.normalizeVariants(locals: deviceB)

        XCTAssertEqual(deletedGuids(onA), ["a-second"], "① Delete the higher-index copy")
        XCTAssertEqual(deletedGuids(onB), ["b-second"],
                       "② The other device deletes the same position despite reversed guid order")
        XCTAssertEqual(onA.ops.count, onB.ops.count)
    }

    /// CASE 4b.8b, dormant rows: backups participate in neither collapse nor
    /// relineaging. Their content matches active rows after migration; collapsing
    /// them silently destroys backups during a scope round trip.
    func testADormantBackupRowIsNeverCollapsedIntoItsActiveTwin() {
        let rows = [pinRow(guid: "p-active", spaceId: "space-a", index: 0),
                    pinRow(guid: "p-dormant", spaceId: "space-a", index: 1, isDormant: true)]

        let batch = PinKind.normalizeVariants(locals: rows)

        XCTAssertTrue(batch.ops.isEmpty)
    }

    // MARK: - CASE 4b.8c: Deduplicate snapshot identities (R-exec-12 / D-B)

    /// CASE 4b.8c (R-exec-12 / D-B): two rows with one identity yield one entity,
    /// retaining baseline rank and identical bytes across repeated runs.
    /// Mac B, 2026-09-14 19:18:37–19:19:34: eight rows for four identities entered
    /// row-based rank groups, duplicating UUIDs in assignRanks order. A duplicate
    /// cannot join the strictly increasing retained set, so each round minted a
    /// rankBetween value; UUID-keyed assigned then overwrote the retained rank.
    /// All four identities differed from baseline every round: 25 rounds at
    /// 2.34-second intervals, keys growing one character per round (922–934 bytes).
    /// Counters looked healthy (pushed=4/refused=0/parked=0). Deduplication structurally
    /// prevents this endless commit loop with no cost for normally unique identities.
    func testTwoLocalRowsSharingOneIdentityProduceExactlyOneStableEntity() {
        var table = PhiOwnedItemTable()
        table.cursors["lx:su-1"] = landedCursor(pinPayload(lineage: "lx", ownerKey: "su-1",
                                                           rank: "V"))
        // Two same-lineage, same-owner rows both resolve to lx:su-1.
        let doubled = [pinRow(guid: "p-first", spaceId: "space-a", index: 0),
                       pinRow(guid: "p-second", spaceId: "space-a", index: 1)]

        RankProbe.reset()
        let first = snapshot(doubled, table: table)
        let rankCalls = RankProbe.rankBetweenCalls
        let again = snapshot(doubled, table: table)

        XCTAssertEqual(Array(first.entities.keys), ["lx:su-1"], "① One entity per identity")
        XCTAssertEqual(first.entities["lx:su-1"]?.rank.stringValue, "V",
                       "② Reuse the baseline rank without minting")
        XCTAssertEqual(rankCalls, 0,
                       "③ A single baseline rank is already ordered; never call rankBetween")
        let firstBytes = first.entities["lx:su-1"].flatMap { try? $0.serializedData() }
        let againBytes = again.entities["lx:su-1"].flatMap { try? $0.serializedData() }
        XCTAssertNotNil(firstBytes)
        XCTAssertEqual(firstBytes, againBytes,
                       "④ Repeated snapshots produce identical bytes, the publication convergence criterion")
    }

    /// CASE 4b.8c, survivor: snapshot keeps the first locals row, matching A11.
    /// Different survivors would publish a row that A11 deletes in the same round.
    /// allPins sorts by ownerKey/index/guid, so first means lowest index and matches A11.
    func testTheDeduplicatedSnapshotKeepsTheSameRowThatVariantCollapseKeeps() {
        // Different contents make the selected survivor visible in the published entity.
        let rows = [pinRow(guid: "p-first", spaceId: "space-a", index: 0, title: "First"),
                    pinRow(guid: "p-second", spaceId: "space-a", index: 1, title: "Second")]

        let published = snapshot(rows).entities["lx:su-1"]

        XCTAssertEqual(published?.title.stringValue, "First",
                       "① Retain the lowest-index row")
        // With distinct signatures, A11 also relineages the second row.
        XCTAssertEqual(relineageGuids(PinKind.normalizeVariants(locals: rows)), ["p-second"],
                       "② Both paths agree on the survivor")
    }

    // MARK: - CASE 4b.9

    /// CASE 4b.9 (spec 14c / R-M3-3-23): revival after a scope round trip reuses
    /// the old cursor. Creating with empty entityId/baseVersion=0 would be rejected
    /// every round for version mismatch. Assert snapshot identity equals the cursor
    /// key used by Task 6 step 5 to obtain entityId/version. Normalization or owner
    /// drift would miss it and send create. Do not assert that snapshot leaves the
    /// table unchanged (V34): it receives a value copy, so that assertion always passes.
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
        XCTAssertEqual(keys, ["lx:pu-1"], "The revived entity uses the tombstone cursor's key")
        XCTAssertEqual(entityId, "e-lx")
        XCTAssertEqual(version, 42)
    }
}

// MARK: - PinKind inbound handling (CASE 4b.10–4b.15)

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

    /// CASE 4b.10 (spec 15 / R-M3-3-12): scope mismatch suppresses publication
    /// and parks all inbound entities, applying them once scopes converge. Dropping
    /// them loses them permanently after the shared marker advances; the server
    /// resends only on later edits. Scope-setting rounds are especially likely
    /// to contain newly republished pins for the new scope.
    /// V7: OwnedItemPlanContext must carry localScope/accountScope; otherwise plan
    /// has no input from which it could implement the expected parking behavior.
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
        XCTAssertEqual(parkedKeys, ["lx:pu-1"], "Park the inbound entity instead of discarding it")
        XCTAssertEqual(waitingFor, "pu-1")

        // First converged round: pass the previous parked payload back unchanged.
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

    /// CASE 4b.11 (spec 16 / §7.4): if only one split half arrives, snapshot
    /// emits its baseline partner rather than empty string. Local splitPartnerGuid
    /// is nil until arrival, but restamping an empty partner with now would tell
    /// the remote device to break its intact pair merely because this device received it.
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
        XCTAssertEqual(partnerStamp, 100, "Copy the baseline partner and stamp; this is not a local change")
    }

    /// CASE 4b.11c (spec 16 / V28): partner arrival produces an ordinary field
    /// update. reconcilePinnedSplitPartners heuristically scans active SplitGroups
    /// for local operations; newly synced pairs have none, and their explicit
    /// split_partner_uuid already determines the answer. Assert plan produces
    /// update, giving Task 6b a deterministic PinApplyOp.update. lastAppliedOps
    /// requires engine wiring and is covered by CASE 6b.12.
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
        XCTAssertEqual(kinds, [.update], "Partner changes affect only the content signature")
        XCTAssertEqual(identities, ["lx:pu-1"])
    }

    // MARK: - CASE 4b.12 / 4b.13

    /// CASE 4b.12 (spec 17a): pendingDelete discards an ordinary update; local deletion wins.
    func testAnOrdinaryUpdateArrivingOnAPendingDeleteIsDiscarded() {
        let table = pendingDeleteTable("lx:pu-1", decidedAtMs: 1_000)
        // Only title changed: content stamp 2000, but location stamp (pin rank) remains 100.
        let edited = pinPayload(lineage: "lx", ownerKey: "pu-1", title: "\u{65b0}\u{6807}\u{9898}",
                                rankStamp: 100, contentStamp: 2_000)

        let plan = planned([arrival(edited)], table: table)

        let steps = plan.steps
        let superseded = plan.supersededByDelete
        let cancelled = plan.cancelledDeletes
        XCTAssertTrue(steps.isEmpty)
        XCTAssertEqual(superseded, 1)
        XCTAssertTrue(cancelled.isEmpty)
    }

    /// CASE 4b.13 (spec 17b / A6): harvest entityId/version even from discarded
    /// arrivals. Otherwise the tombstone retries a stale baseVersion forever,
    /// visibly looping every 60 seconds. plan must receive OwnedItemArrival with
    /// the protocol tuple; bare payloads contain neither field.
    func testTheDiscardedArrivalStillHarvestsItsServerTriple() {
        let table = pendingDeleteTable("lx:pu-1", decidedAtMs: 1_000)
        let edited = pinPayload(lineage: "lx", ownerKey: "pu-1", title: "\u{65b0}\u{6807}\u{9898}",
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

    /// CASE 4b.14 (spec 17c / A9): inbound location newer than the deletion decision
    /// cancels deletion. The trigger is the remote entity, not a later local edit;
    /// using local edits would cancel on unrelated changes and miss the real A9
    /// case warned about by §5.6. Also probes PinKind.locationStamp: returning zero
    /// makes the first conjunction always false and must fail this test.
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

    /// CASE 4b.15 (spec 17d): the negative cases, deleted-subtree membership or
    /// unresolved owner, must never cancel deletion; their precise handling is checked below.
    func testAMoveIntoTheDeletedSubtreeOrAnUnresolvableOwnerStillLosesToTheDelete() {
        // ① This identity belongs to the subtree deleted this round.
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

        // ② Unresolved ownership prevents application, so park first. Do not cancel
        // deletion or discard: retry once the owner has applied.
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

    // MARK: - Refusal (§4.6 pin cases)

    /// Test every §4.6 pin refusal row. Owner/scope mismatch is parking under
    /// §7.3, covered by CASE 4b.10. Invalid ranks must be rejected before rankBetween's
    /// release precondition can trap. Accepting uppercase lineage creates duplicate
    /// identities; colon-containing lineage makes lineage:owner concatenation ambiguous
    /// and lets a forged payload harvest another entity's id/version. Invalid URLs
    /// cannot create or update a nonoptional PhiLocalPin.url, so rejecting here
    /// avoids silent discard or permanent parking (4b-1).
    func testThePinRefusalTableIsTheStructuralCriteria() {
        // Use two independent invalid URLs: this toolchain accepts spaces, NULs,
        // and bare controls more liberally than expected. Invalid authority, such as
        // unclosed IPv6, and empty string are rejected. Checking both retains coverage
        // if future parsers become more permissive for one.
        let unparseable = "http://[::1"
        XCTAssertNil(URL(string: unparseable), "Fixture precondition: an unclosed IPv6 literal cannot form a URL")
        XCTAssertNil(URL(string: ""), "Fixture precondition: an empty string cannot form a URL")

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

    /// 4b-6 (§4.2 rule 5 / A13): without a baseline, stamp rank at zero, title/URL
    /// with the row's content stamp, and every other field with now. Stamping rank
    /// with now could overwrite account ordering on republished creates; doing
    /// the same to content makes an untouched old pin beat a recent remote rename.
    /// Conversely, split links do not advance contentUpdatedDate, so giving a newly
    /// created link that old stamp lets a newer remote empty value incorrectly win.
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
        XCTAssertEqual(partner, "lb", "Normalize partner lineage through lineageKey before publication")
    }
}

// MARK: - Task 5a: Application index projection (§4.10)

/// Three pure BookmarkKind.rankToIndex tests without LocalStore, engine, or
/// fakes. This is the application path's sole wire-order-to-dense-local-index
/// translation; an error reorders the whole folder, warranting direct coverage.
@MainActor
final class BookmarkRankToIndexProjectionTests: XCTestCase {

    /// Specify only the four relevant fields; use fixture defaults for the rest.
    private func sibling(guid: String,
                         syncId: String?,
                         index: Int) -> PhiLocalBookmark {
        PhiLocalBookmark.fixture(guid: guid, syncId: syncId, index: index)
    }

    // MARK: - CASE 5a.1

    /// CASE 5a.1: rank order determines dense indexes, not old index order.
    /// Choose old indexes 7/2/5 and ranks M/V/b so all three positions differ;
    /// otherwise retaining old order could pass accidentally.
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

    /// CASE 5a.2: break rank ties by identity UUID. Nondeterministic ties make
    /// devices write different indexes and endlessly exchange rank updates.
    /// Reverse local guid and identity order (b-aaa on g-zzz) so guid-based
    /// tie-breaking fails rather than coincidentally matching.
    func testSiblingsWithTheSameRankAreOrderedByIdentityUuid() {
        let siblings = [
            sibling(guid: "g-aaa", syncId: "b-bbb", index: 0),
            sibling(guid: "g-zzz", syncId: "b-aaa", index: 1),
        ]

        let projected = BookmarkKind.rankToIndex(siblings: siblings,
                                                 ranks: ["b-aaa": "M", "b-bbb": "M"])

        XCTAssertEqual(projected["g-zzz"], 0, "b-aaa sorts first")
        XCTAssertEqual(projected["g-aaa"], 1)
    }

    // MARK: - CASE 5a.3

    /// CASE 5a.3: project unfiltered siblings, including nonsyncing rows, into
    /// distinct indexes. Filtering leaves stale indexes colliding with rewritten
    /// ones, makes fetch order unstable, and creates endless rank-update oscillation
    /// with two commits per round (§4.10).
    func testTheProjectionCoversEverySiblingIncludingTheOnesNotInThisRound() {
        let siblings = [
            sibling(guid: "g1", syncId: "b1", index: 0),
            // An unpublished local row has no rank this round but still occupies a sibling slot.
            sibling(guid: "g2", syncId: nil, index: 1),
            sibling(guid: "g3", syncId: "b3", index: 2),
        ]

        let projected = BookmarkKind.rankToIndex(siblings: siblings,
                                                 ranks: ["b1": "V", "b3": "b"])

        let indexes = Set(projected.values)
        XCTAssertEqual(projected.count, 3, "All three unfiltered siblings receive indexes")
        XCTAssertEqual(indexes.count, 3, "All three indexes are distinct")
        XCTAssertEqual(projected["g2"], 0, "Unranked rows come first, matching assignRanks complement ordering")
    }
}

// MARK: - Task 5a fix round: Read failures and diff domain

/// PhiBookmarkLocalAccess read contracts (R-exec-3 / R-exec-4). Use fakes to
/// verify protocol behavior, not SwiftData: callers must observe read failures,
/// and the diff domain must be wider than the snapshot.
@MainActor
final class BookmarkLocalAccessReadContractTests: XCTestCase {

    private struct StoreDown: Error {}

    // MARK: - R-exec-3

    /// Read failures must throw, never return an empty array. Empty means no
    /// local bookmarks to §4.7, which tombstones every cursor and deletes the
    /// whole account tree on all devices. Startup is particularly dangerous:
    /// no local snapshot exists yet, while cursors have already loaded from disk.
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

        XCTAssertNil(returned, "A failed read returns no row list, including an empty array")
        XCTAssertTrue(thrown is StoreDown, "Propagate the original error so callers can recognize read failure")
    }

    /// The diff-domain read must also throw; it supplies §4.7's evidence of local row existence.
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

    /// An orphan-root row is absent from snapshot but present in the identity
    /// set. Snapshot decides what sync claims; diff asks whether a local row
    /// still exists. Concurrent initialization can make a former root noncanonical;
    /// using snapshot as the diff domain would tombstone its intact published
    /// subtree while no local row was actually deleted.
    func testAnOrphanRootRowIsOutOfTheSnapshotButStillCountsAsPresentForTheDiff() throws {
        let access = FakeBookmarkAccess(rows: [
            PhiLocalBookmark.fixture(guid: "g1", syncId: "b1"),
        ])
        // This local row is under a root that is no longer canonical.
        access.orphanedSyncIds = ["b-orphan"]

        let snapshotIdentities = Set(try access.allBookmarks().compactMap(\.syncId))
        let diffDomain = try access.allSyncIds()

        XCTAssertEqual(snapshotIdentities, ["b1"], "The orphan subtree is not published in the snapshot")
        XCTAssertEqual(diffDomain, ["b1", "b-orphan"], "The diff must not classify it as locally absent")
        XCTAssertTrue(diffDomain.isSuperset(of: snapshotIdentities),
                      "The diff domain contains the snapshot domain")
    }
}

// MARK: - Task 5a fix round 2: Snapshot lifecycle

/// The three cache readers are valid after this round's last successful
/// allBookmarks or apply (G1 / G4).
@MainActor
final class BookmarkSnapshotLifetimeTests: XCTestCase {

    private func access() -> FakeBookmarkAccess {
        FakeBookmarkAccess(rows: [
            PhiLocalBookmark.fixture(guid: "g-folder", syncId: "b-folder",
                                     index: 0, isFolder: true),
            PhiLocalBookmark.fixture(guid: "g1", syncId: "b1", parentGuid: "g-folder", index: 0),
        ])
    }

    /// Before reading this round, all three readers report absent and allSyncIds
    /// throws. Absent values are not truthful observations, just the nonthrowing
    /// APIs' fallback. Production DEBUG asserts here; matching the contract in
    /// fakes prevents Task 6 from relying on usage invalid on real devices.
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
        XCTAssertTrue(identitiesThrew, "Throw instead of returning an empty set that deletes the entire tree")
    }

    /// The three readers become valid after a successful allBookmarks call.
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

    /// After successful apply, all three readers remain valid and reflect the
    /// applied state. §4.5 uses them to verify application before recording baselines.
    /// Clearing the snapshot would make every guid absent, block baselines, and
    /// replay the batch forever; false isKnownLocalBookmark also triggers dead-mapping
    /// repair that recreates the entire tree as duplicates.
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
        XCTAssertEqual(siblings.map(\.guid), ["g1", "g2"], "Verification sees the post-apply rows")
        XCTAssertTrue(known, "Recognize the applied row so dead-mapping repair cannot recreate it")
        XCTAssertTrue(identities.contains("b2"))
    }

    /// A new round invalidates the readers until another successful read.
    func testBeginningANewRoundInvalidatesTheReaders() throws {
        let access = access()
        _ = try access.allBookmarks()

        access.beginRound()

        let known = access.isKnownLocalBookmark("g1")
        XCTAssertFalse(known)
    }
}

// MARK: - External review: Local side of inbound merge (§4.3 / §6.2)

extension SyncableOwnedItemsTests {

    /// Current local outbound projection for context.localProjections, built exactly
    /// like engine bookmarkLocalProjections: project, then stamp against the baseline.
    private func projectionBytes(of row: PhiLocalBookmark,
                                 baseline: Phi_PhiBookmarkEntity,
                                 parentIdentity: String? = nil,
                                 now: Int64) throws -> Data {
        let projected = try XCTUnwrap(BookmarkKind.project(row, resolve: resolve, scope: nil,
                                                          parentIdentity: parentIdentity))
        let stamped = BookmarkKind.stamp(projected, baseline: baseline, local: row,
                                         rank: BookmarkKind.rank(of: baseline), now: now)
        return try BookmarkKind.envelope(stamped).serializedData()
    }

    /// An unpublished local edit meets a remote edit to another field. Using
    /// reconciled as the local merge side omits the pending edit, since its old
    /// value/stamp remain in baseline. The merged bookmarkPatch rewrites all four
    /// content fields and silently erases that edit without commits or counters,
    /// while both devices consider themselves converged.
    func testAnUnpublishedLocalEditSurvivesARemoteEditOfAnotherField() throws {
        let baseline = bookmarkPayload(uuid: "b1", title: "T", url: "https://old.example")
        // Local URL changed without publication; title is unchanged.
        let edited = PhiLocalBookmark.fixture(guid: "g-b1", syncId: "b1", spaceId: "space-a",
                                              title: "T",
                                              url: URL(string: "https://new.example")!,
                                              createdDate: Date(timeIntervalSince1970: 1),
                                              contentUpdatedDate: Date(timeIntervalSince1970: 400))
        var table = PhiOwnedItemTable()
        table.cursors["b1"] = landedCursor(baseline)
        // Remote changed only the title.
        let inbound = bookmarkPayload(uuid: "b1", title: "\u{5bf9}\u{7aef}\u{6807}\u{9898}",
                                      url: "https://old.example", contentStamp: 200)
        var context = OwnedItemPlanContext()
        context.localProjections = ["b1": try projectionBytes(of: edited, baseline: baseline,
                                                              now: 500)]

        let plan = planned([arrival(inbound)], table: table, context: context)

        let landed = stepEntity(plan, "b1", .update)
        XCTAssertEqual(landed?.title.stringValue, "\u{5bf9}\u{7aef}\u{6807}\u{9898}", "① The remote side wins its edited field")
        XCTAssertEqual(landed?.url.stringValue, "https://new.example",
                       "② Preserve the unpublished local edit exactly")
        XCTAssertTrue(plan.mustRepublish.contains("b1"),
                      "③ Republish locally winning fields so the account receives the new URL")
    }

    /// Conversely, unchanged local rows let remote win entirely with no republication.
    /// Treating projection presence itself as a local win adds a commit for every
    /// inbound update, causing endless device echoes.
    func testAnInboundUpdateOnACleanRowRepublishesNothing() throws {
        let baseline = bookmarkPayload(uuid: "b1", title: "T")
        let clean = PhiLocalBookmark.fixture(guid: "g-b1", syncId: "b1", spaceId: "space-a",
                                             title: "T",
                                             createdDate: Date(timeIntervalSince1970: 1))
        var table = PhiOwnedItemTable()
        table.cursors["b1"] = landedCursor(baseline)
        let inbound = bookmarkPayload(uuid: "b1", title: "\u{5bf9}\u{7aef}\u{6807}\u{9898}", contentStamp: 200)
        var context = OwnedItemPlanContext()
        context.localProjections = ["b1": try projectionBytes(of: clean, baseline: baseline,
                                                              now: 500)]

        let plan = planned([arrival(inbound)], table: table, context: context)

        let landed = stepEntity(plan, "b1", .update)
        XCTAssertEqual(landed?.title.stringValue, "\u{5bf9}\u{7aef}\u{6807}\u{9898}")
        XCTAssertTrue(plan.mustRepublish.isEmpty, "Remote wins every field, so nothing needs republication")
    }
}

// MARK: - External review: Tombstones during scope mismatch (§7.3 / §12.1 item 15)

extension PinKindTests {

    /// Scope mismatch parks live entities in parked and tombstones in parkedTombstones.
    /// Parking only live payloads permanently loses remote deletions: tombstones
    /// carry only tag hashes (§2.5), and an advanced marker prevents redelivery.
    /// The local pin then survives forever despite account deletion, harvested
    /// versions, and healthy-looking counters.
    func testAScopeMismatchParksInboundTombstonesInsteadOfDroppingThem() {
        var mismatched = OwnedItemPlanContext()
        mismatched.localScope = .space
        mismatched.accountScope = .profile
        mismatched.tombstonedIdentities = ["lx:pu-1"]

        let plan = planned([arrival(pinPayload(lineage: "ly", ownerKey: "pu-1"))],
                           context: mismatched)

        XCTAssertTrue(plan.steps.isEmpty, "① Scope mismatch produces no steps")
        XCTAssertEqual(Set(plan.parked.keys), ["ly:pu-1"], "② Live entities enter parked")
        XCTAssertEqual(plan.parkedTombstones, ["lx:pu-1"],
                       "③ Retain the remote deletion because it will not be delivered again")
    }

    /// With matching scopes, parkedTombstones stays empty; tombstones use the normal third phase.
    func testAnAgreeingScopeRoundEmitsDeleteStepsRatherThanParkingTombstones() {
        var agreed = OwnedItemPlanContext()
        agreed.localScope = .profile
        agreed.accountScope = .profile
        agreed.tombstonedIdentities = ["lx:pu-1"]

        let plan = planned([], context: agreed)

        XCTAssertEqual(plan.steps.map(\.kind), [.delete])
        XCTAssertTrue(plan.parkedTombstones.isEmpty)
    }
}

// MARK: - External review: Equal values with newer inbound stamps (§4.3 LWW value/stamp pairs)

extension SyncableOwnedItemsTests {

    private func bookmarkEntity(_ bytes: Data?) -> Phi_PhiBookmarkEntity? {
        guard let bytes, let envelope = try? Phi_PhiEntity(serializedBytes: bytes) else {
            return nil
        }
        return BookmarkKind.entity(from: envelope)
    }

    /// Remote changes title A to B and back to A: equal value with newer stamp
    /// produces no step but advances baseline. Otherwise delayed B@200 from replay,
    /// a third device, or marker rollback beats stale A@100 and overwrites newer
    /// account A, silently diverging devices without any diagnostic change.
    func testASameValueUpdateWithANewerStampStillMovesTheBaselineForward() {
        let baseline = bookmarkPayload(uuid: "b1", title: "A")
        var table = PhiOwnedItemTable()
        table.cursors["b1"] = landedCursor(baseline)

        let plan = planned([arrival(bookmarkPayload(uuid: "b1", title: "A", contentStamp: 300))],
                           table: table)

        XCTAssertTrue(plan.steps.isEmpty, "① Unchanged values produce no empty patch")
        let refreshed = bookmarkEntity(plan.rebaselined["b1"])
        XCTAssertEqual(refreshed?.title.stringValue, "A")
        XCTAssertEqual(refreshed?.title.updatedAtMs, 300, "② The baseline retains the newer stamp")

        // ③ After baseline advancement, older B@200 cannot win.
        var refreshedTable = PhiOwnedItemTable()
        refreshedTable.cursors["b1"] = ownedCursor(reconciled: plan.rebaselined["b1"],
                                                   entityId: "srv-1", version: 1,
                                                   ownerUuid: "su-1")

        let late = planned([arrival(bookmarkPayload(uuid: "b1", title: "B", contentStamp: 200))],
                           table: refreshedTable)

        XCTAssertTrue(late.steps.isEmpty, "③ B@200 loses to account A@300")
    }

    /// Conversely, byte-identical inbound entity and baseline require no baseline rewrite.
    func testAnIdenticalInboundEntityRewritesNothingAtAll() {
        let baseline = bookmarkPayload(uuid: "b1", title: "A")
        var table = PhiOwnedItemTable()
        table.cursors["b1"] = landedCursor(baseline)

        let plan = planned([arrival(baseline)], table: table)

        XCTAssertTrue(plan.steps.isEmpty)
        XCTAssertTrue(plan.rebaselined.isEmpty, "Identical bytes require no writes")
    }
}

// MARK: - R-exec-16: Fields not writable locally (created_at_ms / source)

/// When devices disagree on creation time, outbound projection must merge
/// with its baseline first. created_at_ms merges by minimum but cannot be
/// written by BookmarkFieldPatch; creation-time-only merges generate no local
/// ops while advancing both baselines. Reasserting the local column then makes
/// one device's projection differ from reconciled and the other's server differ
/// from reconciled, endlessly republishing a 176-byte bookmark (Mac A/B commit
/// storm, 2026-09-14).
extension SyncableOwnedItemsTests {

    /// The incident's two timestamps: A's value and B's value eleven minutes later.
    private static var earlierCreatedAtMs: Int64 { 1_789_370_308_853 }
    private static var laterCreatedAtMs: Int64 { 1_789_370_985_148 }

    private func date(fromMilliseconds ms: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
    }

    /// Current outbound projection: project and stamp against the device's own
    /// baseline, matching PhiSyncEngine.bookmarkLocalProjections.
    private func projection(of row: PhiLocalBookmark,
                            baseline: Phi_PhiBookmarkEntity) throws -> Phi_PhiBookmarkEntity {
        let projected = try XCTUnwrap(BookmarkKind.project(row, resolve: resolve, scope: nil,
                                                           parentIdentity: nil))
        return BookmarkKind.stamp(projected, baseline: baseline, local: row,
                                  rank: BookmarkKind.rank(of: baseline), now: 9_000)
    }

    /// CASE 16.1: both projections take the minimum and are byte-identical.
    func testTwoDevicesProjectTheSameEarliestCreationStamp() throws {
        let earlier = Self.earlierCreatedAtMs
        let later = Self.laterCreatedAtMs
        // Two local rows for one bookmark differ only in creation time.
        let rowA = PhiLocalBookmark.fixture(guid: "GA", syncId: "b1", spaceId: "space-a",
                                            createdDate: date(fromMilliseconds: earlier))
        let rowB = PhiLocalBookmark.fixture(guid: "GB", syncId: "b1", spaceId: "space-a",
                                            createdDate: date(fromMilliseconds: later))
        // Each machine just applied the other's entity; its merged baseline carries
        // the peer's creation timestamp.
        let baselineA = bookmarkPayload(uuid: "b1", createdAtMs: later)
        let baselineB = bookmarkPayload(uuid: "b1", createdAtMs: earlier)

        let projectedA = try projection(of: rowA, baseline: baselineA)
        let projectedB = try projection(of: rowB, baseline: baselineB)

        XCTAssertEqual(projectedA.createdAtMs, earlier, "① The earlier device keeps publishing its own timestamp")
        XCTAssertEqual(projectedB.createdAtMs, earlier, "② The later device uses the baseline timestamp instead of reasserting its own")
        XCTAssertEqual(try projectedA.serializedData(), try projectedB.serializedData(),
                       "③ Both devices produce identical bytes for the bookmark")
    }

    /// CASE 16.2: projection is a merge fixed point against the account entity.
    /// This is the no-republication condition: application stores merged reconciled
    /// bytes, and the next identical projection has no byte difference to publish.
    func testAProjectionIsAFixedPointOfTheMerge() throws {
        let earlier = Self.earlierCreatedAtMs
        let later = Self.laterCreatedAtMs
        let rowB = PhiLocalBookmark.fixture(guid: "GB", syncId: "b1", spaceId: "space-a",
                                            createdDate: date(fromMilliseconds: later))
        // The account entity comes from the peer with the earlier timestamp.
        let account = bookmarkPayload(uuid: "b1", createdAtMs: earlier)

        let projected = try projection(of: rowB, baseline: account)
        let merged = BookmarkKind.merge(local: projected, remote: account)

        XCTAssertEqual(merged, projected, "Merge leaves projection unchanged, so no republication is needed")
        XCTAssertEqual(merged.createdAtMs, earlier)
    }

    /// CASE 16.3: source is write-once; copy it from baseline without overriding it from the local column.
    func testABaselineSourceIsNeverOverwrittenByTheLocalColumn() throws {
        let row = PhiLocalBookmark.fixture(guid: "GA", syncId: "b1", spaceId: "space-a",
                                           source: 7,
                                           createdDate: date(fromMilliseconds: 1_000))
        let account = bookmarkPayload(uuid: "b1", source: 3, createdAtMs: 1_000)

        let projected = try projection(of: row, baseline: account)
        let merged = BookmarkKind.merge(local: projected, remote: account)

        XCTAssertEqual(projected.source, 3, "① The account value wins")
        XCTAssertEqual(merged, projected, "② Merge is also a fixed point")
    }

    /// CASE 16.4: the same pin contract; PinFieldPatch cannot write these two fields either.
    func testAPinProjectionConvergesOnTheEarliestCreationStampToo() throws {
        let earlier = Self.earlierCreatedAtMs
        let later = Self.laterCreatedAtMs
        let row = PhiLocalPin.fixture(lineageId: "LX", guid: "px", profileId: "Default",
                                      source: 7,
                                      createdDate: date(fromMilliseconds: later))
        let account = pinPayload(lineage: "lx", source: 3, createdAtMs: earlier)

        let projected = try XCTUnwrap(PinKind.project(row, resolve: resolve, scope: nil,
                                                      parentIdentity: nil))
        let stamped = PinKind.stamp(projected, baseline: account, local: row,
                                    rank: PinKind.rank(of: account), now: 9_000)
        let merged = PinKind.merge(local: stamped, remote: account)

        XCTAssertEqual(stamped.createdAtMs, earlier)
        XCTAssertEqual(stamped.source, 3)
        XCTAssertEqual(merged, stamped, "Like bookmarks, the projection is a merge fixed point")
    }
}

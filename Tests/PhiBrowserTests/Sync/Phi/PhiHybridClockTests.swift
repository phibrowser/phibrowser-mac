import XCTest
@testable import Phi

/// The hybrid logical clock (C2 / design R2.1, amended by AM-1) and the stamping rules the
/// three owned kinds now share.
///
/// The clock's algebraic properties are also asserted, randomized, by the hostless convergence
/// harness (`Tests/SyncConvergence`, which symlinks the same production file). These cases pin
/// the specific scenarios R2.5(c) names, in the shape the rest of this suite uses.
final class PhiHybridClockTests: XCTestCase {

    private let wall: Int64 = 1_700_000_000_000

    // MARK: - The formula

    /// `stamp() = max(wall, maxSeen + 1)`. With the wall clock frozen the stamps still increase
    /// strictly: plain millisecond LWW hands out the same stamp twice inside one millisecond and
    /// lets the byte tie-break decide, which is not an order at all.
    func testStampsIncreaseStrictlyUnderAFrozenWallClock() {
        var clock = PhiHybridClock()

        let stamps = (0..<5).map { _ in clock.stamp(wallMs: wall) }

        XCTAssertEqual(stamps, [wall, wall + 1, wall + 2, wall + 3, wall + 4])
        XCTAssertEqual(clock.maxSeen, wall + 4)
    }

    /// The wall clock jumps backwards an hour (DST, an NTP correction). Logical time does not
    /// follow it, so no stamp is ever re-issued.
    func testStampsKeepIncreasingWhenTheWallClockJumpsBackwards() {
        var clock = PhiHybridClock()
        let before = clock.stamp(wallMs: wall)

        let after = clock.stamp(wallMs: wall - 3_600_000)

        XCTAssertEqual(after, before + 1)
    }

    /// Stamp 0 means "derived, must never beat a real action" (R2.3). It is never produced and
    /// never observed, which `max` gives for free -- this pins the property, not the code.
    func testStampZeroIsNeitherObservedNorProduced() {
        var clock = PhiHybridClock()
        let issued = clock.stamp(wallMs: wall)

        clock.observe(0)
        clock.observe(-1)

        XCTAssertEqual(clock.maxSeen, issued)
        XCTAssertNotEqual(clock.stamp(wallMs: 0), 0)
    }

    /// A peer a year in the future raises logical time, and the next local stamp exceeds it. The
    /// inbound stamp itself is never rewritten and `maxSeen` is never clamped (R2.4): a clamp
    /// would change the merge input, and two devices with different wall clocks would clamp
    /// differently and pick different LWW winners.
    func testAFuturePeerStampIsAdoptedWithoutAClampAndExceededByTheNextLocalStamp() {
        var clock = PhiHybridClock()
        _ = clock.stamp(wallMs: wall)
        let inflated = wall + 365 * 24 * 3_600_000

        clock.observe(inflated)

        XCTAssertEqual(clock.maxSeen, inflated)
        XCTAssertEqual(clock.stamp(wallMs: wall), inflated + 1)
    }

    /// `Int64.max` is a legal stamp on the wire, so `+ 1` must saturate rather than trap: a peer
    /// could otherwise halt the browser by publishing one.
    func testTheClockSaturatesAtInt64MaxInsteadOfTrapping() {
        var clock = PhiHybridClock(maxSeen: Int64.max)

        XCTAssertEqual(clock.stamp(wallMs: wall), Int64.max)
        XCTAssertEqual(clock.editStamp(editWallMs: wall), Int64.max)
        XCTAssertEqual(PhiHybridClock.editStamp(editWallMs: wall, overwrittenStampMs: Int64.max),
                       Int64.max)
    }

    /// AM-1: a changed merge unit's stamp is its EDIT time, raised one above the stamp of the
    /// value it overwrote. Without the bump a device whose clock runs behind would replace a
    /// value it merged from a peer with a SMALLER stamp and lose its own, causally later, edit.
    func testAnEditStampAlwaysBeatsTheValueItOverwrote() {
        XCTAssertEqual(PhiHybridClock.editStamp(editWallMs: 5_000, overwrittenStampMs: 100),
                       5_000, "a healthy clock keeps the real edit time")
        XCTAssertEqual(PhiHybridClock.editStamp(editWallMs: 100, overwrittenStampMs: 5_000),
                       5_001, "a slow clock is raised just above what it overwrites")
        XCTAssertEqual(PhiHybridClock(maxSeen: 9_000).editStamp(editWallMs: 100), 9_001,
                       "with no baseline the floor is the account's logical time")
    }

    // MARK: - Stamp-0 invariants (R2.3)

    /// Derived positions still carry 0 on all three kinds: AM-1 raises CONTENT stamps only, and
    /// a local order this device merely computed must never outrank a real drag.
    func testDerivedLocationAndRankStampsAreStillZeroWithoutABaseline() throws {
        let resolve = OwnerResolver.fixture()

        let bookmarkRow = PhiLocalBookmark.fixture(guid: "g1", syncId: "b1", spaceId: "space-a",
                                                   createdDate: Date(timeIntervalSince1970: 2))
        let bookmark = BookmarkKind.stamp(
            try XCTUnwrap(BookmarkKind.project(bookmarkRow, resolve: resolve, scope: nil,
                                               parentIdentity: nil)),
            baseline: nil, local: bookmarkRow, rank: "V", now: 9_000, hlcMax: 8_000)
        XCTAssertEqual(bookmark.spaceUuid.updatedAtMs, 0)
        XCTAssertEqual(bookmark.parentUuid.updatedAtMs, 0)
        XCTAssertEqual(bookmark.rank.updatedAtMs, 0)
        XCTAssertEqual(bookmark.title.updatedAtMs, 8_001,
                       "content takes AM-1's no-baseline floor, location and rank do not")

        let pinRow = PhiLocalPin.fixture(lineageId: "LX", guid: "p1", spaceId: "space-a",
                                         createdDate: Date(timeIntervalSince1970: 2))
        let pin = PinKind.stamp(
            try XCTUnwrap(PinKind.project(pinRow, resolve: resolve, scope: .space,
                                          parentIdentity: nil)),
            baseline: nil, local: pinRow, rank: "V", now: 9_000, hlcMax: 8_000)
        XCTAssertEqual(pin.rank.updatedAtMs, 0)

        let ruleRow = PhiLocalURLRule.fixture(syncId: "r1",
                                              createdDate: Date(timeIntervalSince1970: 2))
        let rule = URLRuleKind.stamp(
            try XCTUnwrap(URLRuleKind.project(ruleRow, resolve: resolve, scope: nil,
                                              parentIdentity: nil)),
            baseline: nil, local: ruleRow, rank: "V", now: 9_000, hlcMax: 8_000)
        XCTAssertEqual(rule.rank.updatedAtMs, 0)
    }

    // MARK: - R2.5(c) scenarios 7 and 8 (offline edits)

    /// Scenario 7. A bookmark renamed offline publishes its RENAME time, not the reconnect time.
    /// `now` is an hour later here and must not appear anywhere in the content group.
    func testAnOfflineRenamePublishesTheEditTimeNotTheReconnectTime() throws {
        let baseline = bookmarkPayload(uuid: "b1", title: "old", contentStamp: 1_000)
        let renamed = PhiLocalBookmark.fixture(guid: "g-b1", syncId: "b1", spaceId: "space-a",
                                               title: "new",
                                               createdDate: Date(timeIntervalSince1970: 1),
                                               contentUpdatedDate: Date(timeIntervalSince1970: 2_000))

        let stamped = BookmarkKind.stamp(
            try XCTUnwrap(BookmarkKind.project(renamed, resolve: OwnerResolver.fixture(),
                                               scope: nil, parentIdentity: nil)),
            baseline: baseline, local: renamed, rank: BookmarkKind.rank(of: baseline),
            now: 5_000_000, hlcMax: 1_000)

        XCTAssertEqual(stamped.title.updatedAtMs, 2_000_000, "the rename time, not `now`")
        XCTAssertNotEqual(stamped.title.updatedAtMs, 5_000_000)
        XCTAssertEqual(stamped.url.updatedAtMs, 1_000, "an unchanged field keeps its stamp")
    }

    /// Scenario 8, the headline regression for C2. A renames offline at T1, B renames online at
    /// T2 > T1, A reconnects at T3 > T2. B must win. Before C2, A's projection was stamped T3 at
    /// publish time and beat B every time.
    func testAnOnlineRenameBeatsAnEarlierOfflineRenamePublishedLater() throws {
        let t1: Int64 = 2_000_000
        let t2: Int64 = 3_000_000
        let t3: Int64 = 5_000_000

        let baseline = bookmarkPayload(uuid: "b1", title: "old", contentStamp: 1_000)
        let offlineRow = PhiLocalBookmark.fixture(guid: "g-b1", syncId: "b1", spaceId: "space-a",
                                                  title: "A",
                                                  createdDate: Date(timeIntervalSince1970: 1),
                                                  contentUpdatedDate: Date(timeIntervalSince1970: TimeInterval(t1) / 1_000))
        // A publishes at T3, an hour after its own edit.
        let published = BookmarkKind.stamp(
            try XCTUnwrap(BookmarkKind.project(offlineRow, resolve: OwnerResolver.fixture(),
                                               scope: nil, parentIdentity: nil)),
            baseline: baseline, local: offlineRow, rank: BookmarkKind.rank(of: baseline),
            now: t3, hlcMax: 1_000)
        let fromB = bookmarkPayload(uuid: "b1", title: "B", contentStamp: t2)

        let merged = BookmarkKind.merge(local: published, remote: fromB)

        XCTAssertEqual(published.title.updatedAtMs, t1)
        XCTAssertEqual(merged.title.stringValue, "B",
                       "the genuinely later edit wins; publish time no longer decides")
    }

    // MARK: - Bookmark location (schema V13)

    /// The location analogue of scenario 7. A bookmark moved offline publishes the MOVE time; `now`
    /// is the reconnect an hour later and must not reach the location group.
    func testAnOfflineMovePublishesTheMoveTimeNotTheReconnectTime() throws {
        let baseline = bookmarkPayload(uuid: "b1", locationStamp: 1_000)
        let moved = PhiLocalBookmark.fixture(guid: "g-b1", syncId: "b1", spaceId: "space-b",
                                             createdDate: Date(timeIntervalSince1970: 1),
                                             locationUpdatedDate: Date(timeIntervalSince1970: 2_000))

        let stamped = BookmarkKind.stamp(
            try XCTUnwrap(BookmarkKind.project(moved, resolve: OwnerResolver.fixture(),
                                               scope: nil, parentIdentity: nil)),
            baseline: baseline, local: moved, rank: BookmarkKind.rank(of: baseline),
            now: 5_000_000, hlcMax: 1_000)

        XCTAssertEqual(BookmarkKind.locationStamp(of: stamped), 2_000_000, "the move time, not `now`")
        XCTAssertNotEqual(BookmarkKind.locationStamp(of: stamped), 5_000_000)
    }

    /// AM-1 on the location unit. A device whose clock runs an hour behind moves a bookmark it had
    /// already merged from a peer: the bare edit column would be SMALLER than the stamp it
    /// overwrites, and the causally later move would lose.
    func testASlowClockMoveIsRaisedAboveTheBaselineLocationStamp() throws {
        let baseline = bookmarkPayload(uuid: "b1", locationStamp: 9_000_000)
        let moved = PhiLocalBookmark.fixture(guid: "g-b1", syncId: "b1", spaceId: "space-b",
                                             createdDate: Date(timeIntervalSince1970: 1),
                                             locationUpdatedDate: Date(timeIntervalSince1970: 5_000))

        let stamped = BookmarkKind.stamp(
            try XCTUnwrap(BookmarkKind.project(moved, resolve: OwnerResolver.fixture(),
                                               scope: nil, parentIdentity: nil)),
            baseline: baseline, local: moved, rank: BookmarkKind.rank(of: baseline),
            now: 9_500_000, hlcMax: 9_000_000)

        XCTAssertEqual(BookmarkKind.locationStamp(of: stamped), 9_000_001)
    }

    /// A row with no recorded move — pre-V13, or one whose location only ever arrived from a peer —
    /// keeps the behaviour that shipped before the column existed: the round clock with a baseline,
    /// 0 without one, so a derived position still cannot outrank a real action (R2.3).
    func testALocationWithNoRecordedMoveKeepsTheRoundClockAndTheStampZeroFloor() throws {
        let resolve = OwnerResolver.fixture()
        let unmoved = PhiLocalBookmark.fixture(guid: "g-b1", syncId: "b1", spaceId: "space-b",
                                               createdDate: Date(timeIntervalSince1970: 1))

        let againstBaseline = BookmarkKind.stamp(
            try XCTUnwrap(BookmarkKind.project(unmoved, resolve: resolve, scope: nil,
                                               parentIdentity: nil)),
            baseline: bookmarkPayload(uuid: "b1", locationStamp: 1_000), local: unmoved,
            rank: "V", now: 5_000_000, hlcMax: 1_000)
        XCTAssertEqual(BookmarkKind.locationStamp(of: againstBaseline), 5_000_000)

        let created = BookmarkKind.stamp(
            try XCTUnwrap(BookmarkKind.project(unmoved, resolve: resolve, scope: nil,
                                               parentIdentity: nil)),
            baseline: nil, local: unmoved, rank: "V", now: 5_000_000, hlcMax: 8_000)
        XCTAssertEqual(created.spaceUuid.updatedAtMs, 0)
        XCTAssertEqual(created.parentUuid.updatedAtMs, 0)
    }

    /// R4.6's prerequisite: a republish after a tombstone yield has no baseline, so a deliberate
    /// move would be stamped 0 and any peer could overwrite it. With a recorded move the
    /// no-baseline path takes AM-1's floor instead.
    func testARecordedMoveSurvivesTheNoBaselinePath() throws {
        let lifted = PhiLocalBookmark.fixture(guid: "g-b1", syncId: "b1", spaceId: "space-b",
                                              createdDate: Date(timeIntervalSince1970: 1),
                                              locationUpdatedDate: Date(timeIntervalSince1970: 2))

        let stamped = BookmarkKind.stamp(
            try XCTUnwrap(BookmarkKind.project(lifted, resolve: OwnerResolver.fixture(),
                                               scope: nil, parentIdentity: nil)),
            baseline: nil, local: lifted, rank: "V", now: 5_000_000, hlcMax: 8_000)

        XCTAssertEqual(BookmarkKind.locationStamp(of: stamped), 8_001)
        XCTAssertEqual(stamped.rank.updatedAtMs, 0, "rank stays derived")
    }

    /// §4.3's carrier rule is unchanged by the column: one stamp is written to BOTH members, and
    /// `locationStamp(of:)` reads space_uuid for a root and parent_uuid for a descendant.
    func testTheLocationStampIsWrittenToBothMembersForRootsAndDescendants() throws {
        let resolve = OwnerResolver.fixture()
        let moveDate = Date(timeIntervalSince1970: 2_000)

        let root = PhiLocalBookmark.fixture(guid: "g-b1", syncId: "b1", spaceId: "space-b",
                                            createdDate: Date(timeIntervalSince1970: 1),
                                            locationUpdatedDate: moveDate)
        let stampedRoot = BookmarkKind.stamp(
            try XCTUnwrap(BookmarkKind.project(root, resolve: resolve, scope: nil,
                                               parentIdentity: nil)),
            baseline: bookmarkPayload(uuid: "b1", locationStamp: 1_000), local: root,
            rank: "V", now: 5_000_000, hlcMax: 1_000)
        XCTAssertEqual(stampedRoot.spaceUuid.updatedAtMs, 2_000_000)
        XCTAssertEqual(stampedRoot.parentUuid.updatedAtMs, stampedRoot.spaceUuid.updatedAtMs)
        XCTAssertEqual(BookmarkKind.locationStamp(of: stampedRoot),
                       stampedRoot.spaceUuid.updatedAtMs, "a root carries on space_uuid")

        let child = PhiLocalBookmark.fixture(guid: "g-b2", syncId: "b2", spaceId: "space-a",
                                             parentGuid: "g-b1",
                                             createdDate: Date(timeIntervalSince1970: 1),
                                             locationUpdatedDate: moveDate)
        let stampedChild = BookmarkKind.stamp(
            try XCTUnwrap(BookmarkKind.project(child, resolve: resolve, scope: nil,
                                               parentIdentity: "b1")),
            baseline: bookmarkPayload(uuid: "b2", parentUuid: "b9", locationStamp: 1_000),
            local: child, rank: "V", now: 5_000_000, hlcMax: 1_000)
        XCTAssertEqual(stampedChild.parentUuid.updatedAtMs, 2_000_000)
        XCTAssertEqual(stampedChild.spaceUuid.updatedAtMs, stampedChild.parentUuid.updatedAtMs)
        XCTAssertEqual(BookmarkKind.locationStamp(of: stampedChild),
                       stampedChild.parentUuid.updatedAtMs, "a descendant carries on parent_uuid")
    }

    // MARK: - A9 boundary on a skewed account (R2.5(c) scenario 10)

    /// `deleteDecidedAtMs` is written from `hlcNow()`, so it is comparable with the LWW location
    /// stamps A9 tests it against. On an account whose logical time has run a year ahead of wall
    /// clock, an inbound entity OLDER than the decision must still lose to the pending delete --
    /// if the decision were wall clock, every arrival would look newer and cancel every delete.
    func testAnInboundEntityOlderThanAnHlcDeleteDecisionDoesNotCancelIt() {
        let skewedLogicalTime: Int64 = 1_700_000_000_000 + 365 * 24 * 3_600_000
        let baseline = bookmarkPayload(uuid: "b1", locationStamp: skewedLogicalTime - 10_000)
        var table = PhiOwnedItemTable()
        table.cursors["b1"] = pendingDeleteCursor(decidedAtMs: skewedLogicalTime,
                                                  reconciled: baselineBytes(baseline))

        let stale = bookmarkPayload(uuid: "b1", spaceUuid: "su-2",
                                    locationStamp: skewedLogicalTime - 1)
        let staleplan = SyncableOwnedItems.plan(
            BookmarkKind.self, arrivals: [OwnedItemArrival(entity: stale, entityId: "srv-1",
                                                           version: 2)],
            parked: [:], table: table, resolve: OwnerResolver.fixture(),
            context: OwnedItemPlanContext())

        XCTAssertEqual(staleplan.supersededByDelete, 1)
        XCTAssertTrue(staleplan.cancelledDeletes.isEmpty)
        XCTAssertTrue(staleplan.steps.isEmpty)

        // The other half of the boundary: a move stamped above the decision still cancels it, so
        // the case above is not passing because A9 stopped working altogether.
        let fresh = bookmarkPayload(uuid: "b1", spaceUuid: "su-2",
                                    locationStamp: skewedLogicalTime + 1)
        let freshPlan = SyncableOwnedItems.plan(
            BookmarkKind.self, arrivals: [OwnedItemArrival(entity: fresh, entityId: "srv-1",
                                                           version: 2)],
            parked: [:], table: table, resolve: OwnerResolver.fixture(),
            context: OwnedItemPlanContext())

        XCTAssertEqual(freshPlan.cancelledDeletes, ["b1"])
        XCTAssertEqual(freshPlan.supersededByDelete, 0)
    }

    /// The same boundary for C4-a's content half. `contentStamp` is compared against the same
    /// hybrid-logical decision, so a stale CONTENT edit must lose on a skewed account exactly as
    /// a stale move does -- otherwise the extension would cancel every local delete on any
    /// account whose logical time has run ahead of wall clock.
    func testAnInboundContentEditOlderThanAnHlcDeleteDecisionDoesNotCancelIt() {
        let skewedLogicalTime: Int64 = 1_700_000_000_000 + 365 * 24 * 3_600_000
        let baseline = bookmarkPayload(uuid: "b1", locationStamp: skewedLogicalTime - 10_000,
                                       contentStamp: skewedLogicalTime - 10_000)
        var table = PhiOwnedItemTable()
        table.cursors["b1"] = pendingDeleteCursor(decidedAtMs: skewedLogicalTime,
                                                  reconciled: baselineBytes(baseline))

        func plan(contentStamp: Int64) -> OwnedItemPlan {
            let arrival = bookmarkPayload(uuid: "b1", title: "renamed",
                                          locationStamp: skewedLogicalTime - 10_000,
                                          contentStamp: contentStamp)
            return SyncableOwnedItems.plan(
                BookmarkKind.self,
                arrivals: [OwnedItemArrival(entity: arrival, entityId: "srv-1", version: 2)],
                parked: [:], table: table, resolve: OwnerResolver.fixture(),
                context: OwnedItemPlanContext())
        }

        let stale = plan(contentStamp: skewedLogicalTime - 1)
        XCTAssertEqual(stale.supersededByDelete, 1)
        XCTAssertTrue(stale.cancelledDeletes.isEmpty)

        let fresh = plan(contentStamp: skewedLogicalTime + 1)
        XCTAssertEqual(fresh.cancelledDeletes, ["b1"])
        XCTAssertEqual(fresh.supersededByDelete, 0)
    }


    // MARK: - AM-2: source-side clock correction

    private let threshold = PhiHybridClock.wallClockCorrectionThresholdMs

    /// The threshold is a real threshold: nothing at or below it is corrected. Ordinary skew is
    /// harmless -- LWW never promised true-time ordering of concurrent writes at that resolution
    /// -- and a correction re-measured every round would only jitter this device's stamps.
    func testAnOffsetWithinTheThresholdIsNotCorrected() {
        let local: Int64 = 1_700_000_000_000

        XCTAssertEqual(PhiHybridClock.wallClockCorrection(serverMs: local, localMs: local), 0)
        XCTAssertEqual(PhiHybridClock.wallClockCorrection(serverMs: local + threshold,
                                                          localMs: local), 0,
                       "exactly at the threshold is still trusted")
        XCTAssertEqual(PhiHybridClock.wallClockCorrection(serverMs: local - threshold,
                                                          localMs: local), 0)
    }

    /// Past the threshold the whole measured offset is applied, in both directions. The stored
    /// value is the CORRECTION, not the raw measurement, so no reader has to re-apply the rule.
    func testAnOffsetBeyondTheThresholdIsCorrectedInBothDirections() {
        let local: Int64 = 1_700_000_000_000
        let hour: Int64 = 3_600_000

        XCTAssertEqual(PhiHybridClock.wallClockCorrection(serverMs: local + hour, localMs: local),
                       hour, "a device running an hour SLOW is pushed forward")
        XCTAssertEqual(PhiHybridClock.wallClockCorrection(serverMs: local - hour, localMs: local),
                       -hour, "a device running an hour FAST is pulled back")
        XCTAssertEqual(PhiHybridClock.wallClockCorrection(serverMs: local + threshold + 1,
                                                          localMs: local), threshold + 1,
                       "one millisecond past the threshold is corrected by the full offset")
    }

    /// A nonsense header must not trap. `abs(Int64.min)` does, and so does a bare subtraction of
    /// two extremes, so both are computed with the overflow-reporting forms.
    func testAnAbsurdServerClockSaturatesInsteadOfTrapping() {
        XCTAssertEqual(PhiHybridClock.wallClockCorrection(serverMs: .max, localMs: .min), .max)
        XCTAssertEqual(PhiHybridClock.wallClockCorrection(serverMs: .min, localMs: .max), .min)
        XCTAssertEqual(PhiHybridClock.corrected(wallMs: .max, offsetMs: 1), .max)
        XCTAssertEqual(PhiHybridClock.corrected(wallMs: .min, offsetMs: -1), .min)
        XCTAssertEqual(PhiHybridClock.corrected(wallMs: 5, offsetMs: 0), 5)
    }

    /// The correction reaches a STAMP, which is the point of all of it: a device an hour fast
    /// stamps at the account's time, not its own, so `maxSeen` never runs an hour ahead. R2.4 is
    /// untouched -- nothing here rewrites an inbound stamp or clamps `maxSeen`.
    func testACorrectedClockStampsAtTheAccountsTimeRatherThanItsOwn() {
        let trueNow: Int64 = 1_700_000_000_000
        let hour: Int64 = 3_600_000
        let broken = trueNow + hour
        let correction = PhiHybridClock.wallClockCorrection(serverMs: trueNow, localMs: broken)

        var uncorrected = PhiHybridClock()
        var corrected = PhiHybridClock()

        XCTAssertEqual(uncorrected.stamp(wallMs: broken), broken)
        XCTAssertEqual(corrected.stamp(wallMs: PhiHybridClock.corrected(wallMs: broken,
                                                                       offsetMs: correction)),
                       trueNow)
        XCTAssertEqual(corrected.maxSeen, trueNow)
    }

    /// AM-1 and AM-2 compose in the order the kinds apply them: the edit column is corrected
    /// FIRST, then raised above the stamp it overwrites. Correcting afterwards would let a
    /// broken clock's raw edit time reach the wire whenever it happened to exceed the baseline.
    func testAnEditTimeIsCorrectedBeforeAM1RaisesIt() {
        let trueNow: Int64 = 1_700_000_000_000
        let hour: Int64 = 3_600_000
        let editOnABrokenClock = trueNow + hour

        let stamp = PhiHybridClock.editStamp(
            editWallMs: PhiHybridClock.corrected(wallMs: editOnABrokenClock, offsetMs: -hour),
            overwrittenStampMs: trueNow - 10_000)

        XCTAssertEqual(stamp, trueNow, "the edit keeps its own (corrected) time")
        XCTAssertGreaterThan(stamp, trueNow - 10_000, "and still beats the value it overwrote")
    }

    /// The whole chain, on the kind that owns the most edit columns: a row edited on a clock an
    /// hour fast publishes the account's time. `contentUpdatedDate` was written by `LocalStore`
    /// from that same broken `Date()`, so correcting only `hlcNow()` would leave the content
    /// group an hour ahead -- which is why `wallOffsetMs` reaches `stamp` and not just the clock.
    func testAnEditOnABrokenClockPublishesACorrectedStamp() throws {
        let hour: Int64 = 3_600_000
        let trueEdit: Int64 = 1_700_000_000_000
        let baseline = bookmarkPayload(uuid: "b1", title: "old", contentStamp: 1_000)
        // The row's column, as the broken clock wrote it: an hour ahead of the real edit.
        let renamed = PhiLocalBookmark.fixture(
            guid: "g-b1", syncId: "b1", spaceId: "space-a", title: "new",
            createdDate: Date(timeIntervalSince1970: 1),
            contentUpdatedDate: Date(timeIntervalSince1970: TimeInterval(trueEdit + hour) / 1_000))

        func stamp(offset: Int64) throws -> Phi_PhiBookmarkEntity {
            BookmarkKind.stamp(
                try XCTUnwrap(BookmarkKind.project(renamed, resolve: OwnerResolver.fixture(),
                                                   scope: nil, parentIdentity: nil)),
                baseline: baseline, local: renamed, rank: BookmarkKind.rank(of: baseline),
                now: trueEdit, hlcMax: 1_000, wallOffsetMs: offset)
        }

        XCTAssertEqual(try stamp(offset: 0).title.updatedAtMs, trueEdit + hour,
                       "uncorrected, the broken clock reaches the wire")
        XCTAssertEqual(try stamp(offset: -hour).title.updatedAtMs, trueEdit,
                       "corrected, the account sees the real edit time")
        XCTAssertEqual(try stamp(offset: -hour).url.updatedAtMs, 1_000,
                       "an unchanged field still keeps its baseline stamp")
    }
}

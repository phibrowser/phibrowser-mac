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
}

import XCTest
@testable import Phi

final class SyncableSpacesTests: XCTestCase {

    // MARK: - rankBetween

    func testRankBetweenBothNilIsTheAlphabetMidpoint() {
        XCTAssertEqual(SyncableSpaces.rankBetween(nil, nil), "V")
    }

    func testRankBetweenIsStrictlyBetweenAndNeverEndsInZero() {
        // `(nil, "0")` and `(nil, "")` are deliberately NOT in this list: no
        // string over `0-9A-Za-z` -- not even the empty string -- is
        // lexicographically less than "0" or than "", so "strictly between"
        // has no solution for either. The invariant "a rank never ends in the
        // lowest digit" is exactly what makes "0" an impossible upper bound,
        // and an empty rank is exactly as impossible for the same reason
        // (nothing sorts below ""), so both are illegal upper bounds and the
        // precondition below traps on either rather than silently returning a
        // rank above the (missing) bound.
        let cases: [(String?, String?)] = [
            (nil, "V"), ("V", nil), ("V", "W"), ("a", "b"),
            ("V", "V1"), ("0001", "0002"), (nil, "01"), ("zzzz", nil),
        ]
        for (a, b) in cases {
            let mid = SyncableSpaces.rankBetween(a, b)
            XCTAssertFalse(mid.isEmpty, "\(String(describing: a))..\(String(describing: b))")
            XCTAssertFalse(mid.hasSuffix("0"), "\(mid) ends in the lowest digit")
            if let a { XCTAssertTrue(a < mid, "\(a) < \(mid)") }
            if let b { XCTAssertTrue(mid < b, "\(mid) < \(b)") }
        }
    }

    /// The contract at the bottom edge of the alphabet: a rank that ends in the
    /// lowest digit is not a legal upper bound, and one that does not is handled
    /// by refining a digit rather than by returning something above the bound.
    func testRankBetweenBelowTheLowestLegalBoundStaysBelowIt() {
        let mid = SyncableSpaces.rankBetween(nil, "01")
        XCTAssertTrue(mid < "01", "\(mid) must stay under the upper bound")
        XCTAssertFalse(mid.hasSuffix("0"))
    }

    func testRankBetweenIsRepeatableUnderInsertion() {
        var low = "V"
        let high = "W"
        for _ in 0..<40 {
            let mid = SyncableSpaces.rankBetween(low, high)
            XCTAssertTrue(low < mid && mid < high)
            low = mid
        }
    }

    // MARK: - LIS over (rank, uuid)

    func testKeptSetIsEverythingWhenLocalOrderMatchesTheTotalOrder() {
        let keys: [(rank: String?, uuid: String)] =
            [("A", "u1"), ("B", "u2"), ("C", "u3"), ("D", "u4")]
        XCTAssertEqual(SyncableSpaces.longestIncreasingKeptSet(keys), Set(0..<4))
    }

    /// A tie on rank is NOT disorder: the total order is (rank, uuid), so a
    /// converged tie whose local order already matches must be kept whole.
    func testTiedRanksInUuidOrderAreAllKept() {
        let keys: [(rank: String?, uuid: String)] =
            [("A", "u1"), ("M", "u2"), ("M", "u9"), ("Z", "u3")]
        XCTAssertEqual(SyncableSpaces.longestIncreasingKeptSet(keys), Set(0..<4))
    }

    func testASingleMovedElementIsTheOnlyOneOutsideTheKeptSet() {
        // D moved from the end to position 1.
        let keys: [(rank: String?, uuid: String)] =
            [("A", "u1"), ("D", "u4"), ("B", "u2"), ("C", "u3")]
        let kept = SyncableSpaces.longestIncreasingKeptSet(keys)
        XCTAssertEqual(kept.count, 3)
        XCTAssertFalse(kept.contains(1))
    }

    func testElementsWithNoRankNeverJoinTheKeptSet() {
        let keys: [(rank: String?, uuid: String)] =
            [("A", "u1"), (nil, "new"), ("B", "u2")]
        XCTAssertEqual(SyncableSpaces.longestIncreasingKeptSet(keys), Set([0, 2]))
    }

    // MARK: - assignRanks

    func testAssignRanksRewritesOnlyTheMovedElement() {
        let assigned = SyncableSpaces.assignRanks(order: [
            (uuid: "u1", rank: "A"), (uuid: "u4", rank: "D"),
            (uuid: "u2", rank: "B"), (uuid: "u3", rank: "C"),
        ])
        XCTAssertEqual(Set(assigned.keys), ["u4"])
        XCTAssertTrue("A" < assigned["u4"]! && assigned["u4"]! < "B")
    }

    func testAssignRanksGivesConsecutiveNewSpacesStrictlyIncreasingRanks() {
        let assigned = SyncableSpaces.assignRanks(order: [
            (uuid: "u1", rank: "A"),
            (uuid: "n1", rank: nil), (uuid: "n2", rank: nil),
            (uuid: "u2", rank: "B"),
        ])
        XCTAssertEqual(Set(assigned.keys), ["n1", "n2"])
        XCTAssertTrue("A" < assigned["n1"]! && assigned["n1"]! < assigned["n2"]!)
        XCTAssertTrue(assigned["n2"]! < "B")
    }

    /// The tie-interval rule (§7): inserting between two equal ranks evicts the
    /// right endpoint into the complement, so exactly ONE extra entity is
    /// rewritten and the three end up strictly increasing.
    func testInsertingIntoATieRewritesTheRightEndpointToo() {
        let assigned = SyncableSpaces.assignRanks(order: [
            (uuid: "left", rank: "M"),
            (uuid: "inserted", rank: nil),
            (uuid: "right", rank: "M"),
            (uuid: "tail", rank: "Z"),
        ])
        XCTAssertEqual(Set(assigned.keys), ["inserted", "right"])
        XCTAssertTrue("M" < assigned["inserted"]!)
        XCTAssertTrue(assigned["inserted"]! < assigned["right"]!)
        XCTAssertTrue(assigned["right"]! < "Z")
    }

    func testAssignRanksIsANoOpForAConvergedTie() {
        let assigned = SyncableSpaces.assignRanks(order: [
            (uuid: "a", rank: "M"), (uuid: "b", rank: "M"), (uuid: "c", rank: "Z"),
        ])
        XCTAssertTrue(assigned.isEmpty)
    }

    // MARK: - shared LWW helpers (promoted out of SyncableSettings)

    func testLwwWinnerIsSymmetricAndBreaksTiesOnBytes() {
        var older = Phi_PhiSettingValue()
        older.updatedAtMs = 10
        older.stringValue = "old"
        var newer = Phi_PhiSettingValue()
        newer.updatedAtMs = 11
        newer.stringValue = "new"
        XCTAssertEqual(SyncableSettings.lwwWinner(older, newer), newer)
        XCTAssertEqual(SyncableSettings.lwwWinner(newer, older), newer)

        var tieA = Phi_PhiSettingValue()
        tieA.updatedAtMs = 7
        tieA.stringValue = "aaa"
        var tieB = Phi_PhiSettingValue()
        tieB.updatedAtMs = 7
        tieB.stringValue = "bbb"
        XCTAssertEqual(SyncableSettings.lwwWinner(tieA, tieB),
                       SyncableSettings.lwwWinner(tieB, tieA))
    }

    func testSignatureIgnoresTheTimestamp() {
        var a = Phi_PhiSettingValue()
        a.updatedAtMs = 1
        a.stringValue = "x"
        var b = a
        b.updatedAtMs = 999
        XCTAssertEqual(SyncableSettings.signature(of: a), SyncableSettings.signature(of: b))
        var c = a
        c.stringValue = "y"
        XCTAssertNotEqual(SyncableSettings.signature(of: a), SyncableSettings.signature(of: c))
    }
}

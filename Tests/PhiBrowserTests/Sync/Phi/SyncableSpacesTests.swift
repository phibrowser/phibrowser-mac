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

    // MARK: - snapshot / merge helpers

    private func local(_ id: String, name: String = "Work", order: Int = 0,
                       profile: String = "Default", theme: String? = nil,
                       light: Double? = nil, dark: Double? = nil,
                       created: TimeInterval = 1_000) -> PhiLocalSpace {
        PhiLocalSpace(spaceId: id, profileId: profile, name: name, colorHex: "#3A6FF8",
                      iconName: "emoji:1F4BC", sortOrder: order,
                      createdDate: Date(timeIntervalSince1970: created),
                      themeId: theme, opacityLight: light, opacityDark: dark)
    }

    private func uuidMap(_ pairs: [String: String]) -> (String) -> String? {
        { pairs[$0] }
    }

    func testSnapshotStampsEveryFieldNowForANewSpaceExceptRank() {
        let out = SyncableSpaces.snapshot(
            spaces: [local("u1")], table: PhiSpaceSyncTable(),
            globalUuid: uuidMap(["Default": "uuid-a"]), syncUuid: { $0 }, now: 9_000)
        let entity = try! XCTUnwrap(out["u1"])
        XCTAssertEqual(entity.name.updatedAtMs, 9_000)
        XCTAssertEqual(entity.iconName.updatedAtMs, 9_000)
        XCTAssertEqual(entity.colorHex.updatedAtMs, 9_000)
        XCTAssertEqual(entity.profileUuid.stringValue, "uuid-a")
        // Derived order must never beat a real drag on ANY device (§7).
        XCTAssertEqual(entity.rank.updatedAtMs, 0)
        XCTAssertFalse(entity.rank.stringValue.isEmpty)
        XCTAssertEqual(entity.createdAtMs, 1_000_000)
        XCTAssertEqual(entity.themeID.stringValue, "")
        XCTAssertEqual(entity.overlayOpacityLight.intValue, -1)
    }

    func testSnapshotReusesBaselineTimestampsForUnchangedFields() throws {
        var first = SyncableSpaces.snapshot(
            spaces: [local("u1")], table: PhiSpaceSyncTable(),
            globalUuid: uuidMap(["Default": "uuid-a"]), syncUuid: { $0 }, now: 9_000)["u1"]!
        var table = PhiSpaceSyncTable()
        var cursor = PhiSpaceCursor()
        cursor.reconciled = try first.serializedData()
        table.cursors["u1"] = cursor

        let second = SyncableSpaces.snapshot(
            spaces: [local("u1")], table: table,
            globalUuid: uuidMap(["Default": "uuid-a"]), syncUuid: { $0 }, now: 50_000)["u1"]!
        XCTAssertEqual(second, first)   // zero stamps: this is the echo suppression
        first.name.updatedAtMs = 9_000  // silence the unused-mutation warning
    }

    func testSnapshotStampsOnlyTheChangedField() throws {
        let base = SyncableSpaces.snapshot(
            spaces: [local("u1", name: "Work")], table: PhiSpaceSyncTable(),
            globalUuid: uuidMap(["Default": "uuid-a"]), syncUuid: { $0 }, now: 9_000)["u1"]!
        var table = PhiSpaceSyncTable()
        var cursor = PhiSpaceCursor()
        cursor.reconciled = try base.serializedData()
        table.cursors["u1"] = cursor

        let renamed = SyncableSpaces.snapshot(
            spaces: [local("u1", name: "Work2")], table: table,
            globalUuid: uuidMap(["Default": "uuid-a"]), syncUuid: { $0 }, now: 50_000)["u1"]!
        XCTAssertEqual(renamed.name.updatedAtMs, 50_000)
        XCTAssertEqual(renamed.iconName.updatedAtMs, base.iconName.updatedAtMs)
        XCTAssertEqual(renamed.rank.updatedAtMs, base.rank.updatedAtMs)
    }

    // MARK: - Edit-time stamping (C2-a / design option S2)

    /// The cursor's `pendingProjection` is this device's own outbound bytes, so a field whose
    /// value still matches it keeps the stamp it was given. That is what carries an offline
    /// rename's own time all the way to the publish pass, which may run hours later.
    func testAPendingProjectionKeepsAnOfflineEditsOwnTime() throws {
        let base = SyncableSpaces.snapshot(
            spaces: [local("u1", name: "Work")], table: PhiSpaceSyncTable(),
            globalUuid: uuidMap(["Default": "uuid-a"]), syncUuid: { $0 }, now: 9_000)["u1"]!
        var table = PhiSpaceSyncTable()
        var cursor = PhiSpaceCursor()
        cursor.reconciled = try base.serializedData()
        table.cursors["u1"] = cursor

        // The stamping pass, run while the machine is offline.
        let stamped = SyncableSpaces.snapshot(
            spaces: [local("u1", name: "Travel")], table: table,
            globalUuid: uuidMap(["Default": "uuid-a"]), syncUuid: { $0 }, now: 20_000)["u1"]!
        XCTAssertEqual(stamped.name.updatedAtMs, 20_000)

        // The publish pass, an hour after the reconnect.
        table.cursors["u1"]?.pendingProjection = try stamped.serializedData()
        let published = SyncableSpaces.snapshot(
            spaces: [local("u1", name: "Travel")], table: table,
            globalUuid: uuidMap(["Default": "uuid-a"]), syncUuid: { $0 }, now: 3_600_000)["u1"]!
        XCTAssertEqual(published.name.updatedAtMs, 20_000,
                       "the rename must carry its own time, not the reconnect's")
        XCTAssertEqual(published, stamped)
    }

    /// Two offline edits of DIFFERENT fields, which is why the pending projection has to be the
    /// effective baseline: stamping the second pass against `reconciled` alone would find the
    /// first field changed as well and restamp it at the second edit's time.
    func testTwoSuccessiveOfflineEditsKeepTheirOwnPerFieldTimes() throws {
        let base = SyncableSpaces.snapshot(
            spaces: [local("u1", name: "Work")], table: PhiSpaceSyncTable(),
            globalUuid: uuidMap(["Default": "uuid-a"]), syncUuid: { $0 }, now: 9_000)["u1"]!
        var table = PhiSpaceSyncTable()
        var cursor = PhiSpaceCursor()
        cursor.reconciled = try base.serializedData()
        table.cursors["u1"] = cursor

        let renamed = SyncableSpaces.snapshot(
            spaces: [local("u1", name: "Travel")], table: table,
            globalUuid: uuidMap(["Default": "uuid-a"]), syncUuid: { $0 }, now: 20_000)["u1"]!
        table.cursors["u1"]?.pendingProjection = try renamed.serializedData()

        // The theme is one of the two fields that are not on `SpaceModel` at all, which is what
        // ruled out a per-row edit-date column for Spaces.
        let rethemed = SyncableSpaces.snapshot(
            spaces: [local("u1", name: "Travel", theme: "coral")], table: table,
            globalUuid: uuidMap(["Default": "uuid-a"]), syncUuid: { $0 }, now: 30_000)["u1"]!
        XCTAssertEqual(rethemed.name.updatedAtMs, 20_000)
        XCTAssertEqual(rethemed.themeID.updatedAtMs, 30_000)
        XCTAssertEqual(rethemed.iconName.updatedAtMs, base.iconName.updatedAtMs)
    }

    /// AM-1. A device whose wall clock runs behind the account still has to stamp above the
    /// value it overwrites, or a genuinely later edit would lose to the value it was made on
    /// top of -- the exact failure the hybrid clock exists to remove.
    func testASlowClockEditStillExceedsTheStampItOverwrites() throws {
        var baseline = Phi_PhiSpaceEntity()
        baseline.spaceUuid = "u1"
        var name = Phi_PhiSettingValue()
        name.stringValue = "Work"
        name.updatedAtMs = 5_000_000        // a peer on a healthy clock wrote this
        baseline.name = name

        var table = PhiSpaceSyncTable()
        var cursor = PhiSpaceCursor()
        cursor.reconciled = try baseline.serializedData()
        table.cursors["u1"] = cursor

        // This device's wall clock says 1_000.
        let stamped = SyncableSpaces.snapshot(
            spaces: [local("u1", name: "Travel")], table: table,
            globalUuid: uuidMap(["Default": "uuid-a"]), syncUuid: { $0 }, now: 1_000)["u1"]!
        XCTAssertEqual(stamped.name.updatedAtMs, 5_000_001)
    }

    /// A field edited and then put back before it was ever published must publish nothing: the
    /// baseline branch is tested FIRST, so the value takes the account's own stamp again and the
    /// whole projection collapses back onto `reconciled`, which is the commit batch's own
    /// "nothing to publish" test.
    func testAFieldRevertedBeforePublishingLeavesNothingToPublish() throws {
        let base = SyncableSpaces.snapshot(
            spaces: [local("u1", name: "Work")], table: PhiSpaceSyncTable(),
            globalUuid: uuidMap(["Default": "uuid-a"]), syncUuid: { $0 }, now: 9_000)["u1"]!
        var table = PhiSpaceSyncTable()
        var cursor = PhiSpaceCursor()
        cursor.reconciled = try base.serializedData()
        table.cursors["u1"] = cursor

        let renamed = SyncableSpaces.snapshot(
            spaces: [local("u1", name: "Travel")], table: table,
            globalUuid: uuidMap(["Default": "uuid-a"]), syncUuid: { $0 }, now: 20_000)["u1"]!
        table.cursors["u1"]?.pendingProjection = try renamed.serializedData()

        let reverted = SyncableSpaces.snapshot(
            spaces: [local("u1", name: "Work")], table: table,
            globalUuid: uuidMap(["Default": "uuid-a"]), syncUuid: { $0 }, now: 30_000)["u1"]!
        XCTAssertEqual(reverted.name.updatedAtMs, base.name.updatedAtMs)
        XCTAssertEqual(reverted, base, "a revert must leave the baseline bytes exactly")
    }

    /// A cursor that has never published has no per-field history to preserve, so a stray
    /// `pendingProjection` on it changes nothing: first publication stays wholesale (A1).
    func testAPendingProjectionWithoutABaselineIsIgnored() throws {
        var stale = Phi_PhiSpaceEntity()
        stale.spaceUuid = "u1"
        var name = Phi_PhiSettingValue()
        name.stringValue = "Work"
        name.updatedAtMs = 7
        stale.name = name

        var table = PhiSpaceSyncTable()
        var cursor = PhiSpaceCursor()
        cursor.pendingProjection = try stale.serializedData()   // reconciled deliberately nil
        table.cursors["u1"] = cursor

        let out = SyncableSpaces.snapshot(
            spaces: [local("u1", name: "Work")], table: table,
            globalUuid: uuidMap(["Default": "uuid-a"]), syncUuid: { $0 }, now: 9_000)["u1"]!
        XCTAssertEqual(out.name.updatedAtMs, 9_000)
        XCTAssertEqual(out.rank.updatedAtMs, 0, "no baseline still means a derived rank")
    }

    /// §7 through the stamping pass: one drag rewrites one entity, and running the pass again
    /// for an unrelated local change must not re-issue that Space's rank stamp -- nor invent one
    /// for the Spaces that did not move.
    func testADragRestampsOnlyTheMovedSpaceAndKeepsThatStampOnTheNextPass() throws {
        let order = ["u1", "u2", "u3"]
        let seeded = SyncableSpaces.snapshot(
            spaces: order.enumerated().map { local($0.element, order: $0.offset) },
            table: PhiSpaceSyncTable(),
            globalUuid: uuidMap(["Default": "uuid-a"]), syncUuid: { $0 }, now: 1_000)
        var table = PhiSpaceSyncTable()
        for uuid in order {
            var cursor = PhiSpaceCursor()
            cursor.reconciled = try seeded[uuid]!.serializedData()
            table.cursors[uuid] = cursor
        }

        // The user drags u3 into the middle. Only u3 leaves the kept set.
        let dragged = ["u1", "u3", "u2"].enumerated().map { local($0.element, order: $0.offset) }
        let first = SyncableSpaces.snapshot(
            spaces: dragged, table: table,
            globalUuid: uuidMap(["Default": "uuid-a"]), syncUuid: { $0 }, now: 20_000)
        XCTAssertEqual(first["u3"]!.rank.updatedAtMs, 20_000)
        XCTAssertEqual(first["u1"]!.rank.updatedAtMs, seeded["u1"]!.rank.updatedAtMs)
        XCTAssertEqual(first["u2"]!.rank.updatedAtMs, seeded["u2"]!.rank.updatedAtMs)

        // An unrelated local change runs the pass again; the drag is already recorded.
        for uuid in order { table.cursors[uuid]?.pendingProjection = try first[uuid]!.serializedData() }
        let second = SyncableSpaces.snapshot(
            spaces: dragged, table: table,
            globalUuid: uuidMap(["Default": "uuid-a"]), syncUuid: { $0 }, now: 40_000)
        XCTAssertEqual(second["u3"]!.rank.stringValue, first["u3"]!.rank.stringValue)
        XCTAssertEqual(second["u3"]!.rank.updatedAtMs, 20_000,
                       "a Space that has not moved since must not be restamped")
        XCTAssertEqual(second["u1"]!.rank.updatedAtMs, seeded["u1"]!.rank.updatedAtMs)
        XCTAssertEqual(second["u2"]!.rank.updatedAtMs, seeded["u2"]!.rank.updatedAtMs)
    }

    /// D1 is a property of the identity, not of the stamping path: the default Space publishes
    /// neither field however it was stamped.
    func testTheDefaultIdentityStillSuppressesProfileAndThemeWithAPendingProjection() throws {
        func def(_ name: String) -> PhiLocalSpace {
            PhiLocalSpace(spaceId: LocalStore.defaultSpaceId, profileId: "Default", name: name,
                          colorHex: "#3A6FF8", iconName: "phi:x", sortOrder: 0,
                          createdDate: Date(timeIntervalSince1970: 1),
                          themeId: "coral", opacityLight: nil, opacityDark: nil)
        }
        let base = SyncableSpaces.snapshot(
            spaces: [def("Default")], table: PhiSpaceSyncTable(), globalUuid: { _ in "uuid-a" },
            syncUuid: { _ in SyncableSpaces.defaultSpaceUuid },
            now: 100)[SyncableSpaces.defaultSpaceUuid]!
        var table = PhiSpaceSyncTable()
        var cursor = PhiSpaceCursor()
        cursor.reconciled = try base.serializedData()
        table.cursors[SyncableSpaces.defaultSpaceUuid] = cursor

        let stamped = SyncableSpaces.snapshot(
            spaces: [def("Renamed")], table: table, globalUuid: { _ in "uuid-a" },
            syncUuid: { _ in SyncableSpaces.defaultSpaceUuid },
            now: 20_000)[SyncableSpaces.defaultSpaceUuid]!
        table.cursors[SyncableSpaces.defaultSpaceUuid]?.pendingProjection =
            try stamped.serializedData()
        let published = SyncableSpaces.snapshot(
            spaces: [def("Renamed")], table: table, globalUuid: { _ in "uuid-a" },
            syncUuid: { _ in SyncableSpaces.defaultSpaceUuid },
            now: 90_000)[SyncableSpaces.defaultSpaceUuid]!
        XCTAssertFalse(published.hasProfileUuid)
        XCTAssertFalse(published.hasThemeID)
        XCTAssertEqual(published.name.updatedAtMs, 20_000)
    }

    /// `rank` is an OPTIONAL message field, so a baseline that never carried one
    /// decodes to `""` -- and `""` is not merely a bad rank, it is an ILLEGAL
    /// upper bound: `rankBetween`'s precondition traps on it (`SyncableSpaces
    /// .swift:43-46`, commit `5545d006`), because nothing over this alphabet
    /// sorts below the empty string. `snapshot` must therefore degrade such a
    /// baseline to "no rank" at the decode boundary, so the Space joins
    /// `assignRanks`'s complement and is handed a real, non-empty rank.
    /// With two Spaces the un-normalized form is reachable: the rankless one
    /// wins the patience tail, becomes the kept set, and is then offered to
    /// `rankBetween` as the right endpoint.
    func testSnapshotTreatsARanklessBaselineAsUnrankedRatherThanEmpty() throws {
        var ranked = Phi_PhiSpaceEntity()
        ranked.spaceUuid = "u1"
        var rank = Phi_PhiSettingValue()
        rank.updatedAtMs = 1_000
        rank.stringValue = "M"
        ranked.rank = rank
        var rankless = Phi_PhiSpaceEntity()
        rankless.spaceUuid = "u2"

        var table = PhiSpaceSyncTable()
        var withRank = PhiSpaceCursor()
        withRank.reconciled = try ranked.serializedData()
        var withoutRank = PhiSpaceCursor()
        withoutRank.reconciled = try rankless.serializedData()
        table.cursors = ["u1": withRank, "u2": withoutRank]

        let out = SyncableSpaces.snapshot(
            spaces: [local("u1"), local("u2")], table: table,
            globalUuid: uuidMap(["Default": "uuid-a"]), syncUuid: { $0 }, now: 9_000)
        let first = try XCTUnwrap(out["u1"])
        let second = try XCTUnwrap(out["u2"])
        XCTAssertEqual(first.rank.stringValue, "M", "a real rank is kept, not rewritten")
        XCTAssertFalse(second.rank.stringValue.isEmpty, "an empty rank is illegal on the wire")
        XCTAssertLessThan(first.rank.stringValue, second.rank.stringValue,
                          "the local order must survive into the rank channel")
        XCTAssertEqual(second.rank.updatedAtMs, 9_000,
                       "publishing a rank the account has never seen IS a local write")
    }

    /// The empty baseline above is only ONE of the shapes a peer can put in the
    /// `rank` field -- the protocol validates none of them, and our own
    /// `rankBetween` merely happens never to EMIT an illegal one. Its
    /// precondition rejects an empty upper bound and one ending in the
    /// alphabet's lowest digit as "the same impossibility", so `"M0"` traps the
    /// process just as `""` does; a character outside `rankAlphabet` traps
    /// nothing but silently breaks the lexicographic == numeric equivalence the
    /// channel rests on (`rankBetween` reads an unknown character as the lowest
    /// digit). All of them must degrade to "no rank" at the same decode
    /// boundary. Local order is [u1 (no rank at all), u2 (the illegal one)], so
    /// u2 wins the patience tail and, un-normalized, is offered to
    /// `rankBetween` as the right endpoint.
    func testSnapshotTreatsAnIllegalBaselineRankAsUnranked() throws {
        for illegal in ["M0", "0", "M~", "M/"] {
            var unranked = Phi_PhiSpaceEntity()
            unranked.spaceUuid = "u1"
            var poisoned = Phi_PhiSpaceEntity()
            poisoned.spaceUuid = "u2"
            var value = Phi_PhiSettingValue()
            value.updatedAtMs = 1_000
            value.stringValue = illegal
            poisoned.rank = value

            var table = PhiSpaceSyncTable()
            var withoutRank = PhiSpaceCursor()
            withoutRank.reconciled = try unranked.serializedData()
            var withIllegalRank = PhiSpaceCursor()
            withIllegalRank.reconciled = try poisoned.serializedData()
            table.cursors = ["u1": withoutRank, "u2": withIllegalRank]

            let out = SyncableSpaces.snapshot(
                spaces: [local("u1"), local("u2")], table: table,
                globalUuid: uuidMap(["Default": "uuid-a"]), syncUuid: { $0 }, now: 9_000)
            let low = try XCTUnwrap(out["u1"]).rank
            let high = try XCTUnwrap(out["u2"]).rank
            for published in [low.stringValue, high.stringValue] {
                XCTAssertFalse(published.isEmpty, "\(illegal): an empty rank is illegal on the wire")
                XCTAssertFalse(published.hasSuffix("0"), "\(illegal): \(published) ends in the lowest digit")
                XCTAssertTrue(published.allSatisfy(SyncableSpaces.rankAlphabet.contains),
                              "\(illegal): \(published) leaves the rank alphabet")
            }
            XCTAssertNotEqual(high.stringValue, illegal,
                              "\(illegal): an illegal rank must be replaced, not republished")
            XCTAssertLessThan(low.stringValue, high.stringValue,
                              "\(illegal): the local order must survive into the rank channel")
            XCTAssertEqual(high.updatedAtMs, 9_000,
                           "\(illegal): replacing an illegal rank IS a local write")
        }
    }

    func testSnapshotOmitsProfileAndThemeForTheDefaultSpace() {
        let entity = SyncableSpaces.snapshot(
            spaces: [local(LocalStore.defaultSpaceId, theme: "midnight")],
            table: PhiSpaceSyncTable(),
            globalUuid: uuidMap(["Default": "uuid-a"]), syncUuid: { $0 }, now: 9_000)[LocalStore.defaultSpaceId]!
        XCTAssertFalse(entity.hasProfileUuid)
        XCTAssertFalse(entity.hasThemeID)
    }

    func testSnapshotSkipsASpaceWhoseProfileHasNoMapping() {
        let out = SyncableSpaces.snapshot(
            spaces: [local("u1", profile: "Profile 9")], table: PhiSpaceSyncTable(),
            globalUuid: uuidMap([:]), syncUuid: { $0 }, now: 9_000)
        XCTAssertTrue(out.isEmpty, "never put a Chromium basename on the wire")
    }

    func testSnapshotSkipsHiddenRefusedAndSoftDeletedCursors() {
        var table = PhiSpaceSyncTable()
        var hidden = PhiSpaceCursor(); hidden.hidden = true
        var refused = PhiSpaceCursor(); refused.refusedAtMs = 1
        var deleted = PhiSpaceCursor(); deleted.entityId = "srv"; deleted.deletedAtMs = 1
        table.cursors = ["h": hidden, "r": refused, "d": deleted]
        let out = SyncableSpaces.snapshot(
            spaces: [local("h"), local("r"), local("d"), local("ok")], table: table,
            globalUuid: uuidMap(["Default": "uuid-a"]), syncUuid: { $0 }, now: 9_000)
        XCTAssertEqual(Set(out.keys), ["ok"])
    }

    /// A uuid holding an UNAPPLIED incoming entity must not be published over.
    /// The four park sites (§6.2 fallback B, a landing failure, a mapping write
    /// failure, a rebind that did not take effect) all leave `reconciled == nil`
    /// on a first landing, so without this exclusion the Space is snapshotted
    /// with NO baseline — every field stamped `now` — and committed at the
    /// parked cursor's harvested id/version, replacing the account's Space with
    /// this Mac's values. Pre-D6 the cursor was keyed by the publisher's local
    /// spaceId, so a parked uuid could never reach a snapshot that iterates
    /// local rows; the mapping layer is what opened it.
    func testSnapshotSkipsAUuidWhoseIncomingEntityIsStillParked() {
        var table = PhiSpaceSyncTable()
        var parked = PhiSpaceCursor()
        parked.entityId = "srv-1"
        parked.version = 7
        parked.pendingApply = Data([0x01])      // reconciled / server deliberately nil
        table.cursors = ["p": parked]
        let out = SyncableSpaces.snapshot(
            spaces: [local("p"), local("ok")], table: table,
            globalUuid: uuidMap(["Default": "uuid-a"]), syncUuid: { $0 }, now: 9_000)
        XCTAssertEqual(Set(out.keys), ["ok"])
    }

    /// §3.5 fallback A: a held binding is echoed back with the BASELINE's own
    /// timestamp, so this device neither wins the field nor commits for it.
    func testSnapshotEchoesAHeldBindingWithoutStampingNow() throws {
        var baseline = Phi_PhiSpaceEntity()
        baseline.spaceUuid = "u1"
        var binding = Phi_PhiSettingValue()
        binding.updatedAtMs = 4_242
        binding.stringValue = "uuid-\u{8fdc}\u{7aef}"
        baseline.profileUuid = binding

        var table = PhiSpaceSyncTable()
        var cursor = PhiSpaceCursor()
        cursor.entityId = "srv"
        cursor.reconciled = try baseline.serializedData()
        cursor.heldProfileUuid = "uuid-\u{8fdc}\u{7aef}"
        cursor.heldForLocalProfileId = "Default"
        table.cursors["u1"] = cursor

        let entity = SyncableSpaces.snapshot(
            spaces: [local("u1")], table: table,
            globalUuid: uuidMap(["Default": "uuid-a"]), syncUuid: { $0 }, now: 900_000)["u1"]!
        XCTAssertEqual(entity.profileUuid.stringValue, "uuid-\u{8fdc}\u{7aef}")
        XCTAssertEqual(entity.profileUuid.updatedAtMs, 4_242)
    }

    /// §3.5's second clause: when the user later rebinds the Space, clear the hold
    /// and stamp now as for ordinary fields. A hold surviving its original binding
    /// would permanently prevent this device from publishing a new binding.
    func testALocalRebindOverridesAStaleHeldBinding() throws {
        var baseline = Phi_PhiSpaceEntity()
        baseline.spaceUuid = "u1"
        var binding = Phi_PhiSettingValue()
        binding.updatedAtMs = 4_242
        binding.stringValue = "uuid-\u{8fdc}\u{7aef}"
        baseline.profileUuid = binding

        var table = PhiSpaceSyncTable()
        var cursor = PhiSpaceCursor()
        cursor.entityId = "srv"
        cursor.reconciled = try baseline.serializedData()
        cursor.heldProfileUuid = "uuid-\u{8fdc}\u{7aef}"
        cursor.heldForLocalProfileId = "Default"
        table.cursors["u1"] = cursor

        // The user has since dragged the Space onto Profile 3.
        let entity = SyncableSpaces.snapshot(
            spaces: [local("u1", profile: "Profile 3")], table: table,
            globalUuid: uuidMap(["Default": "uuid-a", "Profile 3": "uuid-c"]),
            syncUuid: { $0 },
            now: 900_000)["u1"]!
        XCTAssertEqual(entity.profileUuid.stringValue, "uuid-c")
        XCTAssertEqual(entity.profileUuid.updatedAtMs, 900_000,
                       "a local rebind is an ordinary field write and must be published")
    }

    func testSnapshotQuantizesOpacityToMilliUnitsWithNoEcho() throws {
        let first = SyncableSpaces.snapshot(
            spaces: [local("u1", light: 0.82, dark: 0.5)], table: PhiSpaceSyncTable(),
            globalUuid: uuidMap(["Default": "uuid-a"]), syncUuid: { $0 }, now: 9_000)["u1"]!
        XCTAssertEqual(first.overlayOpacityLight.intValue, 820)
        XCTAssertEqual(first.overlayOpacityDark.intValue, 500)

        var table = PhiSpaceSyncTable()
        var cursor = PhiSpaceCursor()
        cursor.reconciled = try first.serializedData()
        table.cursors["u1"] = cursor
        let second = SyncableSpaces.snapshot(
            spaces: [local("u1", light: 0.82, dark: 0.5)], table: table,
            globalUuid: uuidMap(["Default": "uuid-a"]), syncUuid: { $0 }, now: 90_000)["u1"]!
        XCTAssertEqual(second, first)
    }

    // MARK: - D6: Outbound translation (§3.2)

    /// Use distinct local id and syncUuid strings, then assert the local id never
    /// appears anywhere in the result: the outbound channel's identity boundary.
    func testSnapshotPutsSyncUuidsOnTheWireAndNeverTheLocalSpaceId() throws {
        let local = PhiLocalSpace(spaceId: "LOCAL-1", profileId: "Default", name: "Work",
                                  colorHex: "#3A6FF8", iconName: "phi:x", sortOrder: 0,
                                  createdDate: Date(timeIntervalSince1970: 1),
                                  themeId: nil, opacityLight: nil, opacityDark: nil)
        let out = SyncableSpaces.snapshot(spaces: [local], table: PhiSpaceSyncTable(),
                                          globalUuid: { _ in "uuid-a" },
                                          syncUuid: { $0 == "LOCAL-1" ? "sync-1" : nil },
                                          now: 100)
        XCTAssertEqual(Set(out.keys), ["sync-1"])
        let entity = try XCTUnwrap(out["sync-1"])
        XCTAssertEqual(entity.spaceUuid, "sync-1")
        let bytes = try entity.serializedData()
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("LOCAL-1"),
                       "Local spaceId never goes on the wire")
    }

    /// Skipping unmapped Spaces and skipping unmapped Profiles are instances of the same rule.
    func testSnapshotSkipsASpaceWithNoMappingEntirely() {
        let mapped = PhiLocalSpace(spaceId: "LOCAL-1", profileId: "Default", name: "Work",
                                   colorHex: "#3A6FF8", iconName: "phi:x", sortOrder: 0,
                                   createdDate: Date(timeIntervalSince1970: 1),
                                   themeId: nil, opacityLight: nil, opacityDark: nil)
        var unmapped = mapped
        unmapped.spaceId = "LOCAL-2"
        let out = SyncableSpaces.snapshot(spaces: [mapped, unmapped], table: PhiSpaceSyncTable(),
                                          globalUuid: { _ in "uuid-a" },
                                          syncUuid: { $0 == "LOCAL-1" ? "sync-1" : nil },
                                          now: 100)
        XCTAssertEqual(Set(out.keys), ["sync-1"])
    }

    /// Cursors, baselines, and ranks all use syncUuid: a hidden cursor is excluded
    /// and baseline timestamps are retained without restamping now.
    func testSnapshotReadsCursorsAndBaselinesBySyncUuid() throws {
        let local = PhiLocalSpace(spaceId: "LOCAL-1", profileId: "Default", name: "Work",
                                  colorHex: "#3A6FF8", iconName: "phi:x", sortOrder: 0,
                                  createdDate: Date(timeIntervalSince1970: 1),
                                  themeId: nil, opacityLight: nil, opacityDark: nil)
        var baseline = Phi_PhiSpaceEntity()
        baseline.spaceUuid = "sync-1"
        var name = Phi_PhiSettingValue(); name.updatedAtMs = 42; name.stringValue = "Work"
        baseline.name = name
        var cursor = PhiSpaceCursor()
        cursor.entityId = "srv-1"
        cursor.reconciled = try baseline.serializedData()
        var table = PhiSpaceSyncTable()
        table.cursors["sync-1"] = cursor

        let out = SyncableSpaces.snapshot(spaces: [local], table: table,
                                          globalUuid: { _ in "uuid-a" },
                                          syncUuid: { _ in "sync-1" }, now: 900)
        XCTAssertEqual(out["sync-1"]?.name.updatedAtMs, 42, "The baseline matches by syncUuid and is not restamped with now")

        var hidden = cursor
        hidden.hidden = true
        hidden.deletedAtMs = 5
        table.cursors["sync-1"] = hidden
        XCTAssertTrue(SyncableSpaces.snapshot(spaces: [local], table: table,
                                              globalUuid: { _ in "uuid-a" },
                                              syncUuid: { _ in "sync-1" }, now: 900).isEmpty)
    }

    /// Default Space uses default-space for both local id and syncUuid; isDefault still holds.
    func testTheDefaultSpaceStillSuppressesProfileAndTheme() throws {
        let def = PhiLocalSpace(spaceId: LocalStore.defaultSpaceId, profileId: "Default",
                                name: "Default", colorHex: "#3A6FF8", iconName: "phi:x",
                                sortOrder: 0, createdDate: Date(timeIntervalSince1970: 1),
                                themeId: "coral", opacityLight: nil, opacityDark: nil)
        let out = SyncableSpaces.snapshot(spaces: [def], table: PhiSpaceSyncTable(),
                                          globalUuid: { _ in "uuid-a" },
                                          syncUuid: { _ in SyncableSpaces.defaultSpaceUuid },
                                          now: 100)
        let entity = try XCTUnwrap(out[SyncableSpaces.defaultSpaceUuid])
        XCTAssertFalse(entity.hasProfileUuid)
        XCTAssertFalse(entity.hasThemeID)
    }

    // MARK: - merge

    func testMergeIsSymmetricFieldByFieldAndTakesMinCreatedAt() throws {
        var a = Phi_PhiSpaceEntity()
        a.spaceUuid = "u1"
        a.name = lww("A-name", 20)
        a.profileUuid = lww("p-a", 5)
        a.createdAtMs = 5_000
        var b = Phi_PhiSpaceEntity()
        b.spaceUuid = "u1"
        b.name = lww("B-name", 10)
        b.profileUuid = lww("p-b", 30)
        b.createdAtMs = 1_000

        let ab = SyncableSpaces.merge(local: a, remote: b)
        let ba = SyncableSpaces.merge(local: b, remote: a)
        XCTAssertEqual(ab, ba)
        XCTAssertEqual(ab.name.stringValue, "A-name")     // concurrent rename survives
        XCTAssertEqual(ab.profileUuid.stringValue, "p-b")  // concurrent rebind survives
        XCTAssertEqual(ab.createdAtMs, 1_000)
        XCTAssertEqual(ab.spaceUuid, "u1")
    }

    /// §6.2 merges against server to preserve reserved fields 11–14 written by newer
    /// clients. Unknown bytes survive only because merge starts from remote. Building
    /// a fresh entity strips them; since cursor.server retains them, toSend != server
    /// then triggers another stripping commit every round.
    func testMergeKeepsAnUnknownReservedFieldWrittenByANewerClient() throws {
        var newer = Phi_PhiSpaceEntity()
        newer.spaceUuid = "u1"
        newer.name = lww("Remote", 10)
        newer.createdAtMs = 1_000
        // Field 11 (reserved for M3-3 / M3-4), varint 42: what a newer client
        // puts on the wire and this build cannot name.
        let bytes = try newer.serializedData() + Data([0x58, 0x2A])
        let remote = try Phi_PhiSpaceEntity(serializedBytes: bytes)
        XCTAssertFalse(remote.unknownFields.data.isEmpty, "fixture must carry an unknown field")

        var local = Phi_PhiSpaceEntity()
        local.spaceUuid = "u1"
        local.name = lww("Local", 20)
        local.createdAtMs = 1_000

        let merged = SyncableSpaces.merge(local: local, remote: remote)
        XCTAssertEqual(merged.name.stringValue, "Local", "the LWW winner is unchanged")
        XCTAssertEqual(merged.unknownFields, remote.unknownFields)
        // The bytes `spaceCommitEntries` actually sends, decoded again.
        let reencoded = try Phi_PhiSpaceEntity(serializedBytes: try merged.serializedData())
        XCTAssertEqual(reencoded.unknownFields, remote.unknownFields)
    }

    /// The ping-pong half of the same bug: with the peer's field preserved, a
    /// round whose local snapshot says nothing new compares equal to `server`
    /// and publishes nothing.
    func testMergingASnapshotAgainstAServerCopyWithUnknownFieldsPublishesNothing() throws {
        var base = Phi_PhiSpaceEntity()
        base.spaceUuid = "u1"
        base.name = lww("Work", 10)
        base.createdAtMs = 1_000
        let server = try Phi_PhiSpaceEntity(serializedBytes: try base.serializedData() + Data([0x58, 0x2A]))
        XCTAssertEqual(SyncableSpaces.merge(local: base, remote: server), server)
    }

    private func lww(_ s: String, _ ts: Int64) -> Phi_PhiSettingValue {
        var v = Phi_PhiSettingValue(); v.updatedAtMs = ts; v.stringValue = s; return v
    }

    // MARK: - refuses no longer applies incognito checks to wire UUIDs (§3.4)

    /// After D6, wire UUIDs are random, so the incognito UUID check is unreachable
    /// and misleading. Local incognito Spaces are excluded by currentSpaces/pairableSpaces
    /// before mapping and never receive syncUuid. Both agent signatures remain rejected
    /// by name/icon/color criteria independent of UUID.
    func testRefusesNoLongerLooksAtTheUuidButStillRefusesBothAgentShapes() {
        var incognitoShaped = Phi_PhiSpaceEntity()
        incognitoShaped.spaceUuid = "space.incognito.7"
        XCTAssertFalse(SyncableSpaces.refuses(incognitoShaped),
                       "D6: refuses no longer checks space_uuid")

        var ephemeral = Phi_PhiSpaceEntity()
        ephemeral.spaceUuid = "u-agent"
        ephemeral.name = lww("R3", 1)
        ephemeral.iconName = lww("emoji:1F916", 1)
        ephemeral.colorHex = lww("#8E8E93", 1)
        XCTAssertTrue(SyncableSpaces.refuses(ephemeral))

        var persistent = ephemeral
        persistent.name = lww("task-42", 1)
        persistent.colorHex = lww("#5856D6", 1)
        XCTAssertTrue(SyncableSpaces.refuses(persistent))

        var ordinary = Phi_PhiSpaceEntity()
        ordinary.spaceUuid = "u1"
        ordinary.name = lww("Work", 1)
        ordinary.iconName = lww("emoji:1F4BC", 1)
        ordinary.colorHex = lww("#3A6FF8", 1)
        XCTAssertFalse(SyncableSpaces.refuses(ordinary))
    }

    // MARK: - landing order (§6.2 A2)

    @MainActor
    func testLandingAppliesThemeThenRebindThenRowFields() async throws {
        let access = FakePhiSpaceAccess()
        access.spaces = [local("u1", name: "Old", profile: "Default")]
        var merged = Phi_PhiSpaceEntity()
        merged.spaceUuid = "u1"
        merged.name = lww("New", 10)
        merged.colorHex = lww("#111111", 10)
        merged.iconName = lww("phi:x", 10)
        merged.themeID = lww("midnight", 10)
        var opacity = Phi_PhiSettingValue(); opacity.intValue = 700
        merged.overlayOpacityLight = opacity
        var dark = Phi_PhiSettingValue(); dark.intValue = -1
        merged.overlayOpacityDark = dark
        merged.createdAtMs = 500

        try await SyncableSpaces.land(merged, existing: access.spaces[0],
                                      localSpaceId: access.spaces[0].spaceId,
                                      profileId: "Profile 2", access: access)
        XCTAssertEqual(access.calls, [.themeState("u1"),
                                      .rebind(spaceId: "u1", toProfileId: "Profile 2"),
                                      .update("u1")])
        XCTAssertEqual(access.currentSpaces()[0].name, "New")
    }

    @MainActor
    func testLandingCreatesWhenThereIsNoLocalRow() async throws {
        let access = FakePhiSpaceAccess()
        var merged = Phi_PhiSpaceEntity()
        merged.spaceUuid = "u2"
        merged.name = lww("Reading", 10)
        merged.colorHex = lww("#222222", 10)
        merged.iconName = lww("phi:y", 10)
        merged.createdAtMs = 700
        // D6: nil localSpaceId creates a newly minted local row id, distinct from
        // merged.spaceUuid. Assert the returned id rather than u2.
        let landed = try await SyncableSpaces.land(merged, existing: nil, localSpaceId: nil,
                                                   profileId: "Default", access: access)
        XCTAssertEqual(access.calls.first, .create(landed))
        XCTAssertEqual(access.currentSpaces().first?.createdDate,
                       Date(timeIntervalSince1970: 0.7))
    }

    // MARK: - D6: Application (§3.4)

    /// A remote-only Space: R-D6-7's primary creation path.
    @MainActor
    func testLandingANewSpaceMintsAFreshLocalIdAndNeverUsesTheWireUuid() async throws {
        let access = FakePhiSpaceAccess()
        var entity = Phi_PhiSpaceEntity()
        entity.spaceUuid = "sync-new"
        var v = Phi_PhiSettingValue(); v.stringValue = "Reading"; v.updatedAtMs = 1
        entity.name = v
        var theme = Phi_PhiSettingValue(); theme.stringValue = "coral"; theme.updatedAtMs = 1
        entity.themeID = theme

        let landed = try await SyncableSpaces.land(entity, existing: nil, localSpaceId: nil,
                                                   profileId: "Default", access: access)
        XCTAssertNotEqual(landed, "sync-new", "Never use a wire UUID as a local row id")
        XCTAssertNotNil(UUID(uuidString: landed), "Mint a valid local UUID")
        XCTAssertEqual(access.calls, [.create(landed), .themeState(landed)],
                       "Create's applyThemeState also receives the minted local id, not localSpaceId!")
        XCTAssertEqual(access.spaces.first?.spaceId, landed)
    }

    /// A non-Void result prevents bare return; the caller catches failures and restores pendingApply.
    @MainActor
    func testLandingWithNoProfileThrowsAndWritesNothing() async {
        let access = FakePhiSpaceAccess()
        var entity = Phi_PhiSpaceEntity()
        entity.spaceUuid = "sync-new"
        do {
            _ = try await SyncableSpaces.land(entity, existing: nil, localSpaceId: nil,
                                              profileId: nil, access: access)
            XCTFail("expected unresolvedProfile")
        } catch {
            XCTAssertEqual(error as? SyncableSpacesError, .unresolvedProfile)
        }
        XCTAssertTrue(access.calls.isEmpty)
    }

    /// Update: all three write APIs receive local id, never merged.spaceUuid.
    @MainActor
    func testLandingAnExistingSpaceOnlyEverWritesTheLocalId() async throws {
        let access = FakePhiSpaceAccess()
        let existing = PhiLocalSpace(spaceId: "LOCAL-1", profileId: "Default", name: "Old",
                                     colorHex: "#000000", iconName: "phi:x", sortOrder: 0,
                                     createdDate: Date(timeIntervalSince1970: 1),
                                     themeId: nil, opacityLight: nil, opacityDark: nil)
        access.spaces = [existing]
        var entity = Phi_PhiSpaceEntity()
        entity.spaceUuid = "sync-1"
        var name = Phi_PhiSettingValue(); name.stringValue = "New"; name.updatedAtMs = 9
        entity.name = name
        var profile = Phi_PhiSettingValue(); profile.stringValue = "uuid-b"; profile.updatedAtMs = 9
        entity.profileUuid = profile

        let landed = try await SyncableSpaces.land(entity, existing: existing,
                                                   localSpaceId: "LOCAL-1",
                                                   profileId: "Profile 1", access: access)
        XCTAssertEqual(landed, "LOCAL-1")
        XCTAssertEqual(access.calls, [.themeState("LOCAL-1"),
                                      .rebind(spaceId: "LOCAL-1", toProfileId: "Profile 1"),
                                      .update("LOCAL-1")])
    }

    // MARK: - order projection (§7)

    func testPlannedOrderKeepsLocalOnlySpacesInTheirOwnSlots() {
        let order = SyncableSpaces.plannedOrder(
            localOrder: [local("hidden", order: 0), local("s2", order: 1),
                         local("s1", order: 2), local("agent", order: 3)],
            syncedRanks: ["s1": (rank: "A", uuid: "sync-1"),
                          "s2": (rank: "B", uuid: "sync-2")])
        XCTAssertEqual(order, ["hidden", "s1", "s2", "agent"])
    }

    /// `localOrder` is the UNFILTERED order (`allSpacesForOrdering()`), never
    /// `currentSpaces()`. `LocalStore.reorderSpaces` writes `index` as
    /// `sortOrder` for exactly the ids it is handed and leaves every other row's
    /// value alone (LocalStore+Space.swift:322-353), so an agent Space that never
    /// reaches the caller keeps a stale `sortOrder` and interleaves arbitrarily
    /// with the freshly renumbered 0..n-1. Here it must come back in its own slot.
    func testPlannedOrderReturnsEveryLocalSpaceIncludingTheExcludedOnes() {
        let order = SyncableSpaces.plannedOrder(
            localOrder: [local("s2", order: 0), local("agent", order: 1),
                         local("s1", order: 2), local("unmapped", order: 3)],
            syncedRanks: ["s1": (rank: "A", uuid: "sync-1"),
                          "s2": (rank: "B", uuid: "sync-2")])
        XCTAssertEqual(order, ["s1", "agent", "s2", "unmapped"])
        XCTAssertEqual(order.count, 4, "every local Space must be renumbered in one write")
    }

    // MARK: - plannedOrder key namespace (§3.4 silent-failure regression)

    /// syncedRanks uses local spaceId keys. Partial translation silently makes
    /// every lookup nil and turns the entire account reorder into a no-op.
    func testPlannedOrderIsASilentNoOpWhenHandedSyncUuidKeys() {
        let locals = ["LOCAL-1", "LOCAL-2", "LOCAL-3"].enumerated().map { index, id in
            PhiLocalSpace(spaceId: id, profileId: "Default", name: id, colorHex: "#000000",
                          iconName: "phi:x", sortOrder: index,
                          createdDate: Date(timeIntervalSince1970: 1),
                          themeId: nil, opacityLight: nil, opacityDark: nil)
        }
        let byLocalId = ["LOCAL-1": (rank: "V", uuid: "sync-1"),
                         "LOCAL-2": (rank: "F", uuid: "sync-2"),
                         "LOCAL-3": (rank: "k", uuid: "sync-3")]
        XCTAssertEqual(SyncableSpaces.plannedOrder(localOrder: locals, syncedRanks: byLocalId),
                       ["LOCAL-2", "LOCAL-1", "LOCAL-3"])
        let bySyncUuid = ["sync-1": (rank: "V", uuid: "sync-1"),
                          "sync-2": (rank: "F", uuid: "sync-2"),
                          "sync-3": (rank: "k", uuid: "sync-3")]
        XCTAssertEqual(SyncableSpaces.plannedOrder(localOrder: locals, syncedRanks: bySyncUuid),
                       ["LOCAL-1", "LOCAL-2", "LOCAL-3"],
                       "Partial translation silently does nothing; keep translation in the engine")
    }

    /// Two devices that inserted at the same slot hold the SAME fractional rank for two
    /// different Spaces. The tie must break on the account sync uuid, the way
    /// `longestIncreasingKeptSet` and the wire contract do: local ids differ per device, so a
    /// local-id tie-break leaves the two strips in different orders for good.
    func testPlannedOrderBreaksTiedRanksOnTheSyncUuidSoBothDevicesAgree() {
        // Device A calls them A-1/A-2 and lists them in one order; device B calls the same two
        // account Spaces B-9/B-8 and lists them in the other.
        let deviceA = [local("A-1", order: 0), local("A-2", order: 1)]
        let deviceB = [local("B-9", order: 0), local("B-8", order: 1)]
        let ranksA = ["A-1": (rank: "V", uuid: "sync-beta"),
                      "A-2": (rank: "V", uuid: "sync-alpha")]
        let ranksB = ["B-9": (rank: "V", uuid: "sync-alpha"),
                      "B-8": (rank: "V", uuid: "sync-beta")]

        let orderA = SyncableSpaces.plannedOrder(localOrder: deviceA, syncedRanks: ranksA)
        let orderB = SyncableSpaces.plannedOrder(localOrder: deviceB, syncedRanks: ranksB)

        XCTAssertEqual(orderA.map { ranksA[$0]?.uuid }, ["sync-alpha", "sync-beta"])
        XCTAssertEqual(orderB.map { ranksB[$0]?.uuid }, ["sync-alpha", "sync-beta"],
                       "tied ranks must resolve to the same account order on every device")
    }

    // MARK: - One thousandths-unit encoder (§5.7)

    func testOpacityMilliUnitsIsTheOneEncodingBothSidesUse() {
        XCTAssertEqual(SyncableSpaces.opacityMilliUnits(nil), -1)
        XCTAssertEqual(SyncableSpaces.opacityMilliUnits(0.85), 850)
        XCTAssertEqual(SyncableSpaces.opacityMilliUnits(0.4489), 449)
        XCTAssertEqual(SyncableSpaces.opacityMilliUnits(0.8555), 856)
    }
}

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
            globalUuid: uuidMap(["Default": "uuid-a"]), now: 9_000)
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
            globalUuid: uuidMap(["Default": "uuid-a"]), now: 9_000)["u1"]!
        var table = PhiSpaceSyncTable()
        var cursor = PhiSpaceCursor()
        cursor.reconciled = try first.serializedData()
        table.cursors["u1"] = cursor

        let second = SyncableSpaces.snapshot(
            spaces: [local("u1")], table: table,
            globalUuid: uuidMap(["Default": "uuid-a"]), now: 50_000)["u1"]!
        XCTAssertEqual(second, first)   // zero stamps: this is the echo suppression
        first.name.updatedAtMs = 9_000  // silence the unused-mutation warning
    }

    func testSnapshotStampsOnlyTheChangedField() throws {
        let base = SyncableSpaces.snapshot(
            spaces: [local("u1", name: "Work")], table: PhiSpaceSyncTable(),
            globalUuid: uuidMap(["Default": "uuid-a"]), now: 9_000)["u1"]!
        var table = PhiSpaceSyncTable()
        var cursor = PhiSpaceCursor()
        cursor.reconciled = try base.serializedData()
        table.cursors["u1"] = cursor

        let renamed = SyncableSpaces.snapshot(
            spaces: [local("u1", name: "Work2")], table: table,
            globalUuid: uuidMap(["Default": "uuid-a"]), now: 50_000)["u1"]!
        XCTAssertEqual(renamed.name.updatedAtMs, 50_000)
        XCTAssertEqual(renamed.iconName.updatedAtMs, base.iconName.updatedAtMs)
        XCTAssertEqual(renamed.rank.updatedAtMs, base.rank.updatedAtMs)
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
            globalUuid: uuidMap(["Default": "uuid-a"]), now: 9_000)
        let first = try XCTUnwrap(out["u1"])
        let second = try XCTUnwrap(out["u2"])
        XCTAssertEqual(first.rank.stringValue, "M", "a real rank is kept, not rewritten")
        XCTAssertFalse(second.rank.stringValue.isEmpty, "an empty rank is illegal on the wire")
        XCTAssertLessThan(first.rank.stringValue, second.rank.stringValue,
                          "the local order must survive into the rank channel")
        XCTAssertEqual(second.rank.updatedAtMs, 9_000,
                       "publishing a rank the account has never seen IS a local write")
    }

    func testSnapshotOmitsProfileAndThemeForTheDefaultSpace() {
        let entity = SyncableSpaces.snapshot(
            spaces: [local(LocalStore.defaultSpaceId, theme: "midnight")],
            table: PhiSpaceSyncTable(),
            globalUuid: uuidMap(["Default": "uuid-a"]), now: 9_000)[LocalStore.defaultSpaceId]!
        XCTAssertFalse(entity.hasProfileUuid)
        XCTAssertFalse(entity.hasThemeID)
    }

    func testSnapshotSkipsASpaceWhoseProfileHasNoMapping() {
        let out = SyncableSpaces.snapshot(
            spaces: [local("u1", profile: "Profile 9")], table: PhiSpaceSyncTable(),
            globalUuid: uuidMap([:]), now: 9_000)
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
            globalUuid: uuidMap(["Default": "uuid-a"]), now: 9_000)
        XCTAssertEqual(Set(out.keys), ["ok"])
    }

    /// §3.5 fallback A: a held binding is echoed back with the BASELINE's own
    /// timestamp, so this device neither wins the field nor commits for it.
    func testSnapshotEchoesAHeldBindingWithoutStampingNow() throws {
        var baseline = Phi_PhiSpaceEntity()
        baseline.spaceUuid = "u1"
        var binding = Phi_PhiSettingValue()
        binding.updatedAtMs = 4_242
        binding.stringValue = "uuid-远端"
        baseline.profileUuid = binding

        var table = PhiSpaceSyncTable()
        var cursor = PhiSpaceCursor()
        cursor.entityId = "srv"
        cursor.reconciled = try baseline.serializedData()
        cursor.heldProfileUuid = "uuid-远端"
        cursor.heldForLocalProfileId = "Default"
        table.cursors["u1"] = cursor

        let entity = SyncableSpaces.snapshot(
            spaces: [local("u1")], table: table,
            globalUuid: uuidMap(["Default": "uuid-a"]), now: 900_000)["u1"]!
        XCTAssertEqual(entity.profileUuid.stringValue, "uuid-远端")
        XCTAssertEqual(entity.profileUuid.updatedAtMs, 4_242)
    }

    /// §3.5's second clause: "本机之后主动换绑该 Space 时清掉它并按普通字段盖
    /// `now`". A hold that outlived the binding it was taken against would make
    /// this device unable to publish a binding for that Space ever again.
    func testALocalRebindOverridesAStaleHeldBinding() throws {
        var baseline = Phi_PhiSpaceEntity()
        baseline.spaceUuid = "u1"
        var binding = Phi_PhiSettingValue()
        binding.updatedAtMs = 4_242
        binding.stringValue = "uuid-远端"
        baseline.profileUuid = binding

        var table = PhiSpaceSyncTable()
        var cursor = PhiSpaceCursor()
        cursor.entityId = "srv"
        cursor.reconciled = try baseline.serializedData()
        cursor.heldProfileUuid = "uuid-远端"
        cursor.heldForLocalProfileId = "Default"
        table.cursors["u1"] = cursor

        // The user has since dragged the Space onto Profile 3.
        let entity = SyncableSpaces.snapshot(
            spaces: [local("u1", profile: "Profile 3")], table: table,
            globalUuid: uuidMap(["Default": "uuid-a", "Profile 3": "uuid-c"]),
            now: 900_000)["u1"]!
        XCTAssertEqual(entity.profileUuid.stringValue, "uuid-c")
        XCTAssertEqual(entity.profileUuid.updatedAtMs, 900_000,
                       "a local rebind is an ordinary field write and must be published")
    }

    func testSnapshotQuantizesOpacityToMilliUnitsWithNoEcho() throws {
        let first = SyncableSpaces.snapshot(
            spaces: [local("u1", light: 0.82, dark: 0.5)], table: PhiSpaceSyncTable(),
            globalUuid: uuidMap(["Default": "uuid-a"]), now: 9_000)["u1"]!
        XCTAssertEqual(first.overlayOpacityLight.intValue, 820)
        XCTAssertEqual(first.overlayOpacityDark.intValue, 500)

        var table = PhiSpaceSyncTable()
        var cursor = PhiSpaceCursor()
        cursor.reconciled = try first.serializedData()
        table.cursors["u1"] = cursor
        let second = SyncableSpaces.snapshot(
            spaces: [local("u1", light: 0.82, dark: 0.5)], table: table,
            globalUuid: uuidMap(["Default": "uuid-a"]), now: 90_000)["u1"]!
        XCTAssertEqual(second, first)
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

    private func lww(_ s: String, _ ts: Int64) -> Phi_PhiSettingValue {
        var v = Phi_PhiSettingValue(); v.updatedAtMs = ts; v.stringValue = s; return v
    }

    // MARK: - refusal (§6.5)

    func testApplyRefusesIncognitoAndBothAgentSignatures() {
        var incognito = Phi_PhiSpaceEntity()
        incognito.spaceUuid = "space.incognito.7"
        XCTAssertTrue(SyncableSpaces.refuses(incognito))

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
        try await SyncableSpaces.land(merged, existing: nil, profileId: "Default", access: access)
        XCTAssertEqual(access.calls.first, .create("u2"))
        XCTAssertEqual(access.currentSpaces().first?.createdDate,
                       Date(timeIntervalSince1970: 0.7))
    }

    // MARK: - order projection (§7)

    func testPlannedOrderKeepsLocalOnlySpacesInTheirOwnSlots() {
        let order = SyncableSpaces.plannedOrder(
            localOrder: [local("hidden", order: 0), local("s2", order: 1),
                         local("s1", order: 2), local("agent", order: 3)],
            syncedRanks: ["s1": "A", "s2": "B"])
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
            syncedRanks: ["s1": "A", "s2": "B"])
        XCTAssertEqual(order, ["s1", "agent", "s2", "unmapped"])
        XCTAssertEqual(order.count, 4, "every local Space must be renumbered in one write")
    }
}

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
            globalUuid: uuidMap(["Default": "uuid-a"]), syncUuid: { $0 }, now: 900_000)["u1"]!
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

    // MARK: - D6：出站翻译（§3.2）

    /// 本地 id 与 syncUuid 取成两个**不同**字符串，然后断言结果里任何地方都不出现
    /// 本地 id。这是整条出站通道的总闸。
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
                       "本地 spaceId 绝不上线")
    }

    /// 「无映射就跳过」与「profile 没有映射就 continue」是同一条规则的两个实例。
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

    /// 游标、基线与 rank 通道整条在 syncUuid 空间里：一张按 syncUuid 键的表里
    /// `hidden` 的那一条不出现在结果里，基线的时间戳被沿用（没有被重新盖 `now`）。
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
        XCTAssertEqual(out["sync-1"]?.name.updatedAtMs, 42, "基线按 syncUuid 命中，没有被重新盖 now")

        var hidden = cursor
        hidden.hidden = true
        hidden.deletedAtMs = 5
        table.cursors["sync-1"] = hidden
        XCTAssertTrue(SyncableSpaces.snapshot(spaces: [local], table: table,
                                              globalUuid: { _ in "uuid-a" },
                                              syncUuid: { _ in "sync-1" }, now: 900).isEmpty)
    }

    /// 默认 Space：本地 id 与 syncUuid 都是 `"default-space"`，`isDefault` 判据仍成立。
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

    /// §6.2's stated reason for merging against `server` at all: "与 server 合并
    /// 而不是裸发 snapshot，是为了保住更新版客户端写在预留字段 11-14 上的内容".
    /// That only holds if the unknown bytes ride through the merge, which they do
    /// only because it starts from `remote`. Building a fresh entity instead
    /// stripped them on every round trip -- and, because `cursor.server` keeps
    /// them while the merged entity would not, `toSend != server` would fire a
    /// commit that strips them again every single round.
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

    // MARK: - `refuses` 不再对线上 uuid 做 incognito 判据（§3.4）

    /// D6 之后线上 uuid 是随机 syncUuid，这条判据永远不会为真，留着是误导（读者会
    /// 以为 incognito 有线上防线）。本机的 incognito Space 在源头（`currentSpaces()` /
    /// `pairableSpaces()` 的排除表）就拿不到映射行，从不产生 syncUuid。
    /// **两条 agent 特征仍被拒**——那条判据看的是名称/图标/颜色的形状，与 uuid 无关。
    func testRefusesNoLongerLooksAtTheUuidButStillRefusesBothAgentShapes() {
        var incognitoShaped = Phi_PhiSpaceEntity()
        incognitoShaped.spaceUuid = "space.incognito.7"
        XCTAssertFalse(SyncableSpaces.refuses(incognitoShaped),
                       "D6：`refuses` 不再看 `space_uuid`")

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
        // D6：`localSpaceId: nil` 走 create 分支，本地行 id 是新铸的，**不是**
        // `merged.spaceUuid`，所以断言的是返回值而不是 `"u2"`。
        let landed = try await SyncableSpaces.land(merged, existing: nil, localSpaceId: nil,
                                                   profileId: "Default", access: access)
        XCTAssertEqual(access.calls.first, .create(landed))
        XCTAssertEqual(access.currentSpaces().first?.createdDate,
                       Date(timeIntervalSince1970: 0.7))
    }

    // MARK: - D6：落地（§3.4）

    /// 账户里有、本机没有的 Space —— R-D6-7 的主新增路径。
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
        XCTAssertNotEqual(landed, "sync-new", "线上 uuid 绝不当本地行 id 用")
        XCTAssertNotNil(UUID(uuidString: landed), "新铸的是一个本地 UUID")
        XCTAssertEqual(access.calls, [.create(landed), .themeState(landed)],
                       "create 分支内部的 applyThemeState 收到的也是新铸的本地 id，不是 localSpaceId!")
        XCTAssertEqual(access.spaces.first?.spaceId, landed)
    }

    /// 非 Void 返回让裸 `return` 编译不过；调用方的 catch 会把实体停回 `pendingApply`。
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

    /// update 分支：三处写方法收到的都是**本地** id，一次都没收到 `merged.spaceUuid`。
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

    // MARK: - `plannedOrder` 的键空间（§3.4 的静默失效回归）

    /// `syncedRanks` 按**本地** spaceId 键。半翻译在这里没有任何错误信号：每次查表
    /// 都是 nil，账户级重排整体变成 no-op。
    func testPlannedOrderIsASilentNoOpWhenHandedSyncUuidKeys() {
        let locals = ["LOCAL-1", "LOCAL-2", "LOCAL-3"].enumerated().map { index, id in
            PhiLocalSpace(spaceId: id, profileId: "Default", name: id, colorHex: "#000000",
                          iconName: "phi:x", sortOrder: index,
                          createdDate: Date(timeIntervalSince1970: 1),
                          themeId: nil, opacityLight: nil, opacityDark: nil)
        }
        let byLocalId = ["LOCAL-1": "V", "LOCAL-2": "F", "LOCAL-3": "k"]
        XCTAssertEqual(SyncableSpaces.plannedOrder(localOrder: locals, syncedRanks: byLocalId),
                       ["LOCAL-2", "LOCAL-1", "LOCAL-3"])
        let bySyncUuid = ["sync-1": "V", "sync-2": "F", "sync-3": "k"]
        XCTAssertEqual(SyncableSpaces.plannedOrder(localOrder: locals, syncedRanks: bySyncUuid),
                       ["LOCAL-1", "LOCAL-2", "LOCAL-3"],
                       "半翻译 = 静默 no-op：翻译点必须留在引擎里")
    }

    // MARK: - 千分单位编码只有一份（§5.7）

    func testOpacityMilliUnitsIsTheOneEncodingBothSidesUse() {
        XCTAssertEqual(SyncableSpaces.opacityMilliUnits(nil), -1)
        XCTAssertEqual(SyncableSpaces.opacityMilliUnits(0.85), 850)
        XCTAssertEqual(SyncableSpaces.opacityMilliUnits(0.4489), 449)
        XCTAssertEqual(SyncableSpaces.opacityMilliUnits(0.8555), 856)
    }
}

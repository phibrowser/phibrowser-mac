import XCTest
@testable import Phi

/// The pairing sheet's decision core. Every case here is an app-modal-gate
/// safety property: a wrong decision set does not merely misrender, it mints an
/// account profile no device claims, which pins `needsPairing` true and leaves
/// `ProfilePairingGate` holding a window the user cannot close.
final class ProfilePairingModelTests: XCTestCase {
    private let home = RemoteProfile(uuid: "R1", name: "Home")
    private let work = RemoteProfile(uuid: "R2", name: "Work")
    private let unreadable = RemoteProfile(uuid: "R3", name: nil)
    /// The account's default profile, and an ordinary profile a new client
    /// registered; `home` / `work` above are legacy (unflagged).
    private let accountDefault = RemoteProfile(uuid: "RD", name: "Your Phi", isDefault: true)
    private let flaggedHome = RemoteProfile(uuid: "RH", name: "Home", isDefault: false)

    private func ordinary(_ id: String, _ name: String) -> PairingLocal {
        PairingLocal(profileId: id, displayName: name, isDefault: false)
    }

    private func localDefault(_ name: String) -> PairingLocal {
        PairingLocal(profileId: "Default", displayName: name, isDefault: true)
    }

    private func makeModel(locals: [PairingLocal],
                           remotes: [RemoteProfile],
                           selections: [String: ProfilePairingModel.Choice]? = nil,
                           remoteChoices: [String: ProfilePairingModel.RemoteChoice] = [:]) -> ProfilePairingModel {
        ProfilePairingModel(
            locals: locals, remotes: remotes,
            selections: selections ?? ProfilePairingModel.initialSelections(locals: locals, remotes: remotes),
            remoteChoices: remoteChoices)
    }

    private func assertOneDecisionPerLocal(_ decisions: [PairingDecision],
                                           file: StaticString = #filePath, line: UInt = #line) {
        let named = decisions.compactMap(ProfilePairingModel.localProfileId(of:))
        XCTAssertEqual(Set(named).count, named.count,
                       "two decisions for one local profile orphan an account profile: \(decisions)",
                       file: file, line: line)
    }

    // MARK: - Assign to X on a remote row

    /// The headline new option, in its simplest shape. The local's own picker is
    /// still `registerNew` (no name match), so the naive build emits BOTH a
    /// `.registerNew` and the row's `.adopt`; `submitPairing` applies them in
    /// order and the registered uuid is abandoned by the adopt that follows.
    func testAssigningARemoteToALocalEmitsOnlyTheAdopt() {
        let local = ordinary("Profile 1", "Spare")
        let model = makeModel(locals: [local], remotes: [home],
                              remoteChoices: ["R1": .adopt(localProfileId: "Profile 1")])

        XCTAssertEqual(model.decisions(), [.adopt(localProfileId: "Profile 1", remoteUuid: "R1")])
        assertOneDecisionPerLocal(model.decisions())
        XCTAssertEqual(model.claimedRemoteUuids, ["R1"], "the assigned row counts as decided")
    }

    /// Mixed sheet: one local matched by name, one local assigned from a remote
    /// row, one remote created locally.
    func testMixedSheetNamesEachLocalAtMostOnce() {
        let matched = ordinary("Profile 2", "Home")
        let spare = ordinary("Profile 1", "Spare")
        let model = makeModel(locals: [matched, spare], remotes: [home, work],
                              remoteChoices: ["R2": .adopt(localProfileId: "Profile 1")])

        let decisions = model.decisions()
        assertOneDecisionPerLocal(decisions)
        XCTAssertTrue(decisions.contains(.adopt(localProfileId: "Profile 2", remoteUuid: "R1")))
        XCTAssertTrue(decisions.contains(.adopt(localProfileId: "Profile 1", remoteUuid: "R2")))
        XCTAssertEqual(decisions.count, 2, "no leftover registerNew for the assigned local")
    }

    // MARK: - Cross-row exclusion

    /// One local, two unclaimed remotes: once a row has taken the local, the
    /// other row must not offer it. Both `adoptRemoteProfile` calls would
    /// otherwise land on the same profileId and the second would overwrite the
    /// first mapping, leaving that remote unclaimed forever.
    func testALocalIsOfferedByAtMostOneRemoteRow() {
        let local = ordinary("A", "A")
        let model = makeModel(locals: [local], remotes: [home, work],
                              remoteChoices: ["R1": .adopt(localProfileId: "A")])

        XCTAssertEqual(model.assignableLocals(for: home).map(\.profileId), ["A"],
                       "the row that made the choice still shows it")
        XCTAssertTrue(model.assignableLocals(for: work).isEmpty,
                      "the other row must not offer a local that is already spoken for")
    }

    func testTwoRowsClaimingTheSameLocalProduceNoDuplicateDecision() {
        let local = ordinary("A", "A")
        let model = makeModel(locals: [local], remotes: [home, work],
                              remoteChoices: ["R1": .adopt(localProfileId: "A"),
                                              "R2": .adopt(localProfileId: "A")])

        assertOneDecisionPerLocal(model.decisions())
        XCTAssertTrue(model.claimedRemoteUuids.isEmpty,
                      "an unreachable state must read as UNDECIDED, so the button stays disabled")
    }

    // MARK: - Stale choices

    /// The user assigns R1 to A, then moves A's own picker to R2. A is no longer
    /// assignable, so R1's stored choice must read back as undecided rather than
    /// surviving invisibly behind a Picker that renders blank.
    func testAChoiceWhoseLocalMovedAwayReadsAsUndecided() {
        let local = ordinary("A", "A")
        let model = makeModel(locals: [local], remotes: [home, work],
                              selections: ["A": .remote("R2")],
                              remoteChoices: ["R1": .adopt(localProfileId: "A")])

        XCTAssertNil(model.choice(for: home))
        XCTAssertEqual(model.decisions(), [.adopt(localProfileId: "A", remoteUuid: "R2")])
        XCTAssertEqual(model.claimedRemoteUuids, ["R2"], "R1 is undecided again")
    }

    /// A remote a local row has claimed is not an unclaimed-remote row at all,
    /// so a leftover choice for it must not turn into a second decision.
    func testAChoiceForARemoteALocalClaimedIsIgnored() {
        let local = ordinary("A", "A")
        let model = makeModel(locals: [local], remotes: [home],
                              selections: ["A": .remote("R1")],
                              remoteChoices: ["R1": .createLocal])

        XCTAssertNil(model.choice(for: home))
        XCTAssertEqual(model.decisions(), [.adopt(localProfileId: "A", remoteUuid: "R1")])
    }

    // MARK: - Undecryptable remotes

    /// `remote.name == nil` means the envelope did not open under this ARK.
    /// Every path into `adoptRemoteProfile` for it throws, so no picker — local
    /// row included — may offer it and no decision may name it.
    func testAnUndecryptableRemoteIsOfferedByNoPicker() {
        let local = ordinary("A", "A")
        let model = makeModel(locals: [local], remotes: [unreadable],
                              remoteChoices: ["R3": .createLocal])

        XCTAssertTrue(model.remoteOptions(for: local).isEmpty,
                      "the local picker must not offer an envelope that will not open")
        XCTAssertNil(model.choice(for: unreadable))
        XCTAssertEqual(model.decisions(), [.registerNew(localProfileId: "A", displayName: "A")])
        XCTAssertTrue(model.unclaimedRemotes.contains(where: { $0.uuid == "R3" }),
                      "it still shows, as a read-only row")
    }

    func testADecryptableRemoteIsStillOfferedToLocalRows() {
        let local = ordinary("A", "A")
        let model = makeModel(locals: [local], remotes: [home, unreadable])

        XCTAssertEqual(model.remoteOptions(for: local).map(\.uuid), ["R1"])
    }

    // MARK: - The gate's own shape

    /// With no locals, every row is an unclaimed account Profile. Assignment disappears,
    /// but Create on this Mac remains submittable.
    func testRemotesOnlySheetIsDecidableAndSubmittable() {
        let model = makeModel(locals: [], remotes: [home],
                              remoteChoices: ["R1": .createLocal])

        XCTAssertTrue(model.assignableLocals(for: home).isEmpty)
        XCTAssertEqual(model.createLocalUuids, ["R1"])
        XCTAssertEqual(model.decisions(), [.createLocal(remoteUuid: "R1", displayName: "Home")])
    }

    func testUndecidedRemoteRowYieldsNoDecisionAndNoClaim() {
        let model = makeModel(locals: [], remotes: [home])

        XCTAssertNil(model.choice(for: home))
        XCTAssertTrue(model.decisions().isEmpty)
        XCTAssertTrue(model.claimedRemoteUuids.isEmpty)
        XCTAssertTrue(model.createLocalUuids.isEmpty)
    }

    // MARK: - Default pairs only with default

    /// The local Default takes the account default even when the names differ,
    /// and a same-named non-default local does not get it.
    func testTheLocalDefaultPreselectsTheAccountDefault() {
        let mine = localDefault("Personal")
        let spare = ordinary("Profile 1", "Your Phi")
        let model = makeModel(locals: [spare, mine], remotes: [flaggedHome, accountDefault])

        XCTAssertEqual(model.selection(for: mine), .remote("RD"))
        XCTAssertEqual(model.selection(for: spare), .registerNew,
                       "a name match is no reason to hand the account default to another profile")
        XCTAssertEqual(model.decisions(), [.registerNew(localProfileId: "Profile 1", displayName: "Your Phi"),
                                           .adopt(localProfileId: "Default", remoteUuid: "RD")])
    }

    /// A profile another device registered as non-default is never offered to
    /// the local Default -- not by name preselection, not in its picker, not as
    /// "Assign to" on the remote row -- and a stored choice of it reads back as
    /// `.registerNew`.
    func testTheLocalDefaultCannotTakeAKnownNonDefault() {
        let mine = localDefault("Home")
        let model = makeModel(locals: [mine], remotes: [flaggedHome])

        XCTAssertEqual(model.selection(for: mine), .registerNew, "no name preselection across the rule")
        XCTAssertTrue(model.remoteOptions(for: mine).isEmpty)
        XCTAssertTrue(model.assignableLocals(for: flaggedHome).isEmpty)
        XCTAssertTrue(model.offersCreateLocal(for: flaggedHome))

        let forced = makeModel(locals: [mine], remotes: [flaggedHome],
                               selections: ["Default": .remote("RH")],
                               remoteChoices: ["RH": .adopt(localProfileId: "Default")])
        XCTAssertEqual(forced.selection(for: mine), .registerNew)
        XCTAssertNil(forced.choice(for: flaggedHome))
        XCTAssertEqual(forced.decisions(), [.registerNew(localProfileId: "Default", displayName: "Home")])
    }

    /// The account default the local Default takes is never offered to another
    /// local, and never created as a new local profile: the local Default
    /// always exists.
    func testANonDefaultLocalCannotTakeTheAuthoritativeDefault() {
        let mine = localDefault("Personal")
        let spare = ordinary("Profile 1", "Your Phi")
        let model = makeModel(locals: [mine, spare], remotes: [accountDefault])

        XCTAssertEqual(model.authoritativeDefaultUuid, "RD")
        XCTAssertEqual(model.selection(for: spare), .registerNew)
        XCTAssertTrue(model.remoteOptions(for: spare).isEmpty)
        XCTAssertFalse(model.offersCreateLocal(for: accountDefault))

        let forced = makeModel(locals: [mine, spare], remotes: [accountDefault],
                               selections: ["Default": .remote("RD"), "Profile 1": .remote("RD")])
        XCTAssertEqual(forced.selection(for: spare), .registerNew, "a stored choice of it reads back as registerNew")
        XCTAssertEqual(forced.decisions(), [.adopt(localProfileId: "Default", remoteUuid: "RD"),
                                            .registerNew(localProfileId: "Profile 1", displayName: "Your Phi")])
    }

    /// Two devices that paired concurrently each registered a default. The one
    /// the local Default takes is authoritative; the other is an ordinary
    /// profile in the same sheet -- name-matched, offered, assignable and
    /// creatable -- so nothing is left that no row can claim.
    func testAnExtraAccountDefaultIsAnOrdinaryProfile() {
        let second = RemoteProfile(uuid: "RD2", name: "Laptop", isDefault: true)
        let mine = localDefault("Personal")
        let laptop = ordinary("Profile 1", "Laptop")
        let model = makeModel(locals: [laptop, mine], remotes: [accountDefault, second])

        XCTAssertEqual(model.selection(for: mine), .remote("RD"))
        XCTAssertEqual(model.authoritativeDefaultUuid, "RD")
        XCTAssertEqual(model.selection(for: laptop), .remote("RD2"), "the extra default name-matches like any profile")
        XCTAssertEqual(model.unclaimedRemotes, [])

        let unmatched = makeModel(locals: [mine, ordinary("Profile 2", "Spare")], remotes: [accountDefault, second])
        XCTAssertEqual(unmatched.remoteOptions(for: ordinary("Profile 2", "Spare")).map(\.uuid), ["RD2"])
        XCTAssertEqual(unmatched.assignableLocals(for: second).map(\.profileId), ["Profile 2"])
        XCTAssertTrue(unmatched.offersCreateLocal(for: second))
        let created = makeModel(locals: [mine], remotes: [accountDefault, second],
                                remoteChoices: ["RD2": .createLocal])
        XCTAssertEqual(created.decisions(), [.adopt(localProfileId: "Default", remoteUuid: "RD"),
                                             .createLocal(remoteUuid: "RD2", displayName: "Laptop")])

        // Moving the local Default to the other default swaps the roles.
        let swapped = makeModel(locals: [mine], remotes: [accountDefault, second],
                                selections: ["Default": .remote("RD2")])
        XCTAssertEqual(swapped.authoritativeDefaultUuid, "RD2")
        XCTAssertTrue(swapped.offersCreateLocal(for: accountDefault))
        XCTAssertFalse(swapped.offersCreateLocal(for: second))
    }

    /// With the local Default absent (already mapped) or on a legacy profile,
    /// no account default here is authoritative: each is an ordinary profile.
    func testWithoutAnAuthoritativeDefaultEveryAccountDefaultIsOrdinary() {
        let spare = ordinary("Profile 1", "Your Phi")
        let model = makeModel(locals: [spare], remotes: [accountDefault])
        XCTAssertNil(model.authoritativeDefaultUuid)
        XCTAssertEqual(model.selection(for: spare), .remote("RD"))

        let legacy = makeModel(locals: [localDefault("Home"), ordinary("Profile 2", "Spare")],
                               remotes: [home, accountDefault],
                               selections: ["Default": .remote("R1"), "Profile 2": .registerNew])
        XCTAssertNil(legacy.authoritativeDefaultUuid)
        XCTAssertTrue(legacy.offersCreateLocal(for: accountDefault))
        XCTAssertEqual(legacy.assignableLocals(for: accountDefault).map(\.profileId), ["Profile 2"])
    }

    /// The account default's own row may be assigned to the local Default and
    /// to nothing else.
    func testTheAccountDefaultRowAssignsOnlyToTheLocalDefault() {
        let mine = localDefault("Personal")
        let spare = ordinary("Profile 1", "Spare")
        let model = makeModel(locals: [mine, spare], remotes: [accountDefault],
                              selections: ["Default": .registerNew, "Profile 1": .registerNew],
                              remoteChoices: ["RD": .adopt(localProfileId: "Default")])

        XCTAssertEqual(model.assignableLocals(for: accountDefault).map(\.profileId), ["Default"])
        XCTAssertEqual(model.decisions(), [.registerNew(localProfileId: "Profile 1", displayName: "Spare"),
                                           .adopt(localProfileId: "Default", remoteUuid: "RD")])
    }

    /// A legacy (unflagged) profile is unknown, so both sides may take it; with
    /// no account default the local Default falls back to the name match.
    func testALegacyRemoteIsAllowedOnBothSides() {
        let mine = localDefault("Home")
        let spare = ordinary("Profile 1", "Work")
        let model = makeModel(locals: [mine, spare], remotes: [home, work])

        XCTAssertEqual(model.selection(for: mine), .remote("R1"))
        XCTAssertEqual(model.selection(for: spare), .remote("R2"))
        XCTAssertEqual(Set(model.remoteOptions(for: mine).map(\.uuid)), ["R1"])
        let unselected = makeModel(locals: [mine, spare], remotes: [home],
                                   selections: ["Default": .registerNew, "Profile 1": .registerNew])
        XCTAssertEqual(unselected.assignableLocals(for: home).map(\.profileId), ["Default", "Profile 1"])
    }
}

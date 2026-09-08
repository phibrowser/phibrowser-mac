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

    // MARK: - "指派给 X" on a remote row

    /// The headline new option, in its simplest shape. The local's own picker is
    /// still `registerNew` (no name match), so the naive build emits BOTH a
    /// `.registerNew` and the row's `.adopt`; `submitPairing` applies them in
    /// order and the registered uuid is abandoned by the adopt that follows.
    func testAssigningARemoteToALocalEmitsOnlyTheAdopt() {
        let local = PairingLocal(profileId: "Default", displayName: "Default")
        let model = makeModel(locals: [local], remotes: [home],
                              remoteChoices: ["R1": .adopt(localProfileId: "Default")])

        XCTAssertEqual(model.decisions(), [.adopt(localProfileId: "Default", remoteUuid: "R1")])
        assertOneDecisionPerLocal(model.decisions())
        XCTAssertEqual(model.claimedRemoteUuids, ["R1"], "the assigned row counts as decided")
    }

    /// Mixed sheet: one local matched by name, one local assigned from a remote
    /// row, one remote created locally.
    func testMixedSheetNamesEachLocalAtMostOnce() {
        let matched = PairingLocal(profileId: "Default", displayName: "Home")
        let spare = PairingLocal(profileId: "Profile 1", displayName: "Spare")
        let model = makeModel(locals: [matched, spare], remotes: [home, work],
                              remoteChoices: ["R2": .adopt(localProfileId: "Profile 1")])

        let decisions = model.decisions()
        assertOneDecisionPerLocal(decisions)
        XCTAssertTrue(decisions.contains(.adopt(localProfileId: "Default", remoteUuid: "R1")))
        XCTAssertTrue(decisions.contains(.adopt(localProfileId: "Profile 1", remoteUuid: "R2")))
        XCTAssertEqual(decisions.count, 2, "no leftover registerNew for the assigned local")
    }

    // MARK: - Cross-row exclusion

    /// One local, two unclaimed remotes: once a row has taken the local, the
    /// other row must not offer it. Both `adoptRemoteProfile` calls would
    /// otherwise land on the same profileId and the second would overwrite the
    /// first mapping, leaving that remote unclaimed forever.
    func testALocalIsOfferedByAtMostOneRemoteRow() {
        let local = PairingLocal(profileId: "A", displayName: "A")
        let model = makeModel(locals: [local], remotes: [home, work],
                              remoteChoices: ["R1": .adopt(localProfileId: "A")])

        XCTAssertEqual(model.assignableLocals(for: home).map(\.profileId), ["A"],
                       "the row that made the choice still shows it")
        XCTAssertTrue(model.assignableLocals(for: work).isEmpty,
                      "the other row must not offer a local that is already spoken for")
    }

    func testTwoRowsClaimingTheSameLocalProduceNoDuplicateDecision() {
        let local = PairingLocal(profileId: "A", displayName: "A")
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
        let local = PairingLocal(profileId: "A", displayName: "A")
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
        let local = PairingLocal(profileId: "A", displayName: "A")
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
        let local = PairingLocal(profileId: "A", displayName: "A")
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
        let local = PairingLocal(profileId: "A", displayName: "A")
        let model = makeModel(locals: [local], remotes: [home, unreadable])

        XCTAssertEqual(model.remoteOptions(for: local).map(\.uuid), ["R1"])
    }

    // MARK: - The gate's own shape

    /// `locals == []`: every row is an unclaimed account profile, the assign
    /// option disappears, and "在这台 Mac 上创建" is still submittable.
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
}

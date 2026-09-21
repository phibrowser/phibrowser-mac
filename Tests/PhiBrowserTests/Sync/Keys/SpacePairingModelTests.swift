import XCTest
@testable import Phi

/// Step 2 decisions and D7 overwrite differences. Like ProfilePairingModelTests,
/// these test safety properties rather than rendering: duplicate claims permanently
/// fuse two local Spaces in the account; false differences promise an overwrite that will not happen.
final class SpacePairingModelTests: XCTestCase {

    private func local(_ id: String, name: String = "Work", profile: String = "Default",
                       icon: String = "phi:a", color: String = "#3AA4D5",
                       themeId: String? = nil,
                       light: Double? = nil, dark: Double? = nil) -> PhiLocalSpace {
        PhiLocalSpace(spaceId: id, profileId: profile, name: name, colorHex: color,
                      iconName: icon, sortOrder: 0,
                      createdDate: Date(timeIntervalSince1970: 1),
                      themeId: themeId, opacityLight: light, opacityDark: dark)
    }

    private func account(_ uuid: String, name: String = "Work", icon: String = "phi:a",
                         color: String = "#3AA4D5", profileUuid: String = "uuid-a",
                         themeId: String = "", light: Int64 = -1,
                         dark: Int64 = -1) -> PhiAccountSpaceSummary {
        PhiAccountSpaceSummary(syncUuid: uuid, name: name, iconName: icon, colorHex: color,
                               profileUuid: profileUuid, isDefault: false, themeId: themeId,
                               overlayOpacityLightMilli: light, overlayOpacityDarkMilli: dark)
    }

    private func model(locals: [PhiLocalSpace], accounts: [PhiAccountSpaceSummary],
                       selections: [String: SpacePairingModel.Assignment] = [:])
        -> SpacePairingModel {
        SpacePairingModel(
            input: .init(locals: locals, accountSpaces: accounts,
                         localProfileNames: ["Default": "Personal"],
                         accountProfileNames: ["uuid-a": "Home"]),
            selections: selections)
    }

    // MARK: - 1. At most one row claims each account Space

    func testAnAccountSpaceLeavesTheOtherRowsListsButStaysInItsOwn() {
        let a = local("A"), b = local("B", name: "Reading")
        let m = model(locals: [a, b], accounts: [account("acct-1"), account("acct-2", name: "R")],
                      selections: ["A": .existing(syncUuid: "acct-1")])
        XCTAssertEqual(m.assignableAccountSpaces(for: b).map(\.syncUuid), ["acct-2"])
        XCTAssertEqual(m.assignableAccountSpaces(for: a).map(\.syncUuid), ["acct-1", "acct-2"],
                       "Keep the row's own selection available or Picker renders a blank missing tag")
    }

    // MARK: - 2. Stale selections read as undecided

    func testAStaleSelectionReadsBackAsUndecided() {
        let a = local("A")
        let m = model(locals: [a], accounts: [],   // The account list changed and acct-1 disappeared
                      selections: ["A": .existing(syncUuid: "acct-1")])
        XCTAssertNil(m.assignment(for: a))
        XCTAssertFalse(m.allRowsDecided)
        XCTAssertTrue(m.decisions().isEmpty, "A row displayed as blank produces no decision")
    }

    // MARK: - 3. Add all as new is a shortcut, not a reset

    func testAddAllAsNewOnlyFillsTheUndecidedRows() {
        let a = local("A"), b = local("B", name: "Reading"), c = local("C", name: "Notes")
        let m = model(locals: [a, b, c], accounts: [account("acct-1")],
                      selections: ["A": .existing(syncUuid: "acct-1")])
        let after = m.addAllAsNew()
        XCTAssertEqual(after["A"], .existing(syncUuid: "acct-1"), "Already-decided rows remain unchanged")
        XCTAssertEqual(after["B"], .addAsNew)
        XCTAssertEqual(after["C"], .addAsNew)
    }

    // MARK: - 4/5. Default Space and decisions()

    func testTheDefaultSpaceIsNeitherARowNorADecision() {
        let def = local(LocalStore.defaultSpaceId, name: "Default")
        let a = local("A")
        let m = model(locals: [def, a], accounts: [account("acct-1")],
                      selections: ["A": .addAsNew,
                                   LocalStore.defaultSpaceId: .existing(syncUuid: "acct-1")])
        XCTAssertEqual(m.rows.map(\.spaceId), ["A"])
        XCTAssertEqual(m.defaultRow?.spaceId, LocalStore.defaultSpaceId)
        XCTAssertTrue(m.allRowsDecided, "The default Space is excluded")
        XCTAssertEqual(m.decisions().map(\.localSpaceId), ["A"])
    }

    func testDecisionsNeverPointTwoRowsAtOneAccountSpace() {
        let a = local("A"), b = local("B", name: "Reading")
        let m = model(locals: [a, b], accounts: [account("acct-1")],
                      selections: ["A": .existing(syncUuid: "acct-1"),
                                   "B": .existing(syncUuid: "acct-1")])
        let claimed = m.decisions().compactMap { decision -> String? in
            if case .existing(let uuid) = decision.assignment { return uuid }
            return nil
        }
        XCTAssertEqual(Set(claimed).count, claimed.count,
                       "The second row's unavailable selection reads as undecided")
    }

    // MARK: - 6. Empty account

    func testAnEmptyAccountIsDecidableInOneClick() {
        let a = local("A"), b = local("B", name: "Reading")
        let m = model(locals: [a, b], accounts: [])
        XCTAssertTrue(m.assignableAccountSpaces(for: a).isEmpty)
        XCTAssertFalse(m.allRowsDecided)
        let after = m.addAllAsNew()
        XCTAssertTrue(model(locals: [a, b], accounts: [], selections: after).allRowsDecided)
    }

    // MARK: - 7. Left-column membership (executable §5.4 comment)

    /// Include a local Space with an unmapped Profile: pairableSpaces includes it,
    /// currentSpaces does not. Using currentSpaces for the left column makes this test fail.
    func testARowSurvivesEvenWhenItsProfileHasNoMappingYet() {
        let unmapped = local("A", name: "Work", profile: "Profile 7")
        let m = model(locals: [unmapped], accounts: [])
        XCTAssertEqual(m.rows.map(\.spaceId), ["A"])
        XCTAssertNil(m.profileName(for: unmapped), "An unresolved Profile name does not exclude the row")
    }

    // MARK: - D7：SpaceOverwriteDiff（§5.7）

    private func diffs(_ selections: [String: SpacePairingModel.Assignment],
                       locals: [PhiLocalSpace],
                       accounts: [PhiAccountSpaceSummary],
                       themes: [String: String] = ["pure": "Pure", "coral": "Coral"])
        -> [SpaceOverwriteDiff] {
        let m = model(locals: locals, accounts: accounts, selections: selections)
        return SpaceOverwriteDiff.diffs(decisions: m.decisions(), locals: locals,
                                        accountSpaces: accounts,
                                        themeDisplayName: { themes[$0] })
    }

    // 8
    func testSixEqualFieldsProduceNoDiff() {
        let out = diffs(["A": .existing(syncUuid: "acct-1")],
                        locals: [local("A", themeId: nil, light: nil, dark: nil)],
                        accounts: [account("acct-1", themeId: "", light: -1, dark: -1)])
        XCTAssertTrue(out.isEmpty)
    }

    // 9
    func testOneDifferingFieldListsOnlyThatField() throws {
        let out = diffs(["A": .existing(syncUuid: "acct-1")],
                        locals: [local("A", name: "Job")],
                        accounts: [account("acct-1", name: "Work")])
        let diff = try XCTUnwrap(out.first)
        XCTAssertEqual(diff.spaceName, "Job", "The section title is the local Space name")
        XCTAssertEqual(diff.changes.count, 1)
        XCTAssertEqual(diff.changes[0].field, .name)
        XCTAssertEqual(diff.changes[0].local, .text("Job"))
        XCTAssertEqual(diff.changes[0].account, .text("Work"))
    }

    // 10
    func testThemeDefaultsAreNormalizedAndNamedThroughTheResolver() throws {
        let pinned = diffs(["A": .existing(syncUuid: "acct-1")],
                           locals: [local("A", themeId: nil)],
                           accounts: [account("acct-1", themeId: "pure")])
        XCTAssertEqual(pinned.first?.changes.first?.local, .defaultValue)
        XCTAssertEqual(pinned.first?.changes.first?.account, .text("Pure"))

        let unknown = diffs(["A": .existing(syncUuid: "acct-1")],
                            locals: [local("A", themeId: nil)],
                            accounts: [account("acct-1", themeId: "moss")])
        XCTAssertEqual(unknown.first?.changes.first?.account, .text("moss"),
                       "Use the id when no display name resolves")

        // Empty string and default both mean no pin; the UI must never display
        // Theme: No custom value → No custom value.
        let sentinel = diffs(["A": .existing(syncUuid: "acct-1")],
                             locals: [local("A", themeId: nil)],
                             accounts: [account("acct-1", themeId: "default")])
        XCTAssertTrue(sentinel.isEmpty)
    }

    // 11
    func testOpacityIsComparedInMilliUnitsAndNegativesAreAllCleared() throws {
        // A floating-point round trip must not create a false difference.
        XCTAssertTrue(diffs(["A": .existing(syncUuid: "acct-1")],
                            locals: [local("A", light: 0.85)],
                            accounts: [account("acct-1", light: 850)]).isEmpty)

        let cleared = diffs(["A": .existing(syncUuid: "acct-1")],
                            locals: [local("A", light: 0.85)],
                            accounts: [account("acct-1", light: -1)])
        XCTAssertEqual(cleared.first?.changes.first?.local, .percent(milliUnits: 850))
        XCTAssertEqual(cleared.first?.changes.first?.account, .defaultValue)

        let gained = diffs(["A": .existing(syncUuid: "acct-1")],
                           locals: [local("A", dark: nil)],
                           accounts: [account("acct-1", dark: 700)])
        XCTAssertEqual(gained.first?.changes.first?.field, .opacityDark)
        XCTAssertEqual(gained.first?.changes.first?.local, .defaultValue)
        XCTAssertEqual(gained.first?.changes.first?.account, .percent(milliUnits: 700))

        // Continuous-slider values that Int(milli / 10) would incorrectly display as 45% → 45%.
        let slider = diffs(["A": .existing(syncUuid: "acct-1")],
                           locals: [local("A", light: 0.4489)],
                           accounts: [account("acct-1", light: 451)])
        XCTAssertEqual(slider.first?.changes.first?.local, .percent(milliUnits: 449))
        XCTAssertEqual(slider.first?.changes.first?.account, .percent(milliUnits: 451))

        // Any negative value is a sentinel, not only -1: application-side opacity checks < 0.
        XCTAssertTrue(diffs(["A": .existing(syncUuid: "acct-1")],
                            locals: [local("A", light: nil)],
                            accounts: [account("acct-1", light: -5)]).isEmpty)
    }

    // 12: D7's order exception, not §7.
    func testRankAndSortOrderAreNotPartOfTheOverwriteDiffPerD7() {
        var localRow = local("A")
        localRow.sortOrder = 9
        XCTAssertTrue(diffs(["A": .existing(syncUuid: "acct-1")],
                            locals: [localRow], accounts: [account("acct-1")]).isEmpty)
    }

    // 13
    func testOnlyExistingDecisionsProduceDiffs() {
        let out = diffs(["A": .addAsNew],
                        locals: [local("A", name: "Totally different", color: "#000000")],
                        accounts: [account("acct-1")])
        XCTAssertTrue(out.isEmpty, "addAsNew overwrites nothing")
    }

    // 14
    func testFieldOrderIsDeclarationOrderAndSectionOrderFollowsTheDecisions() throws {
        let locals = [local("A", name: "n", icon: "phi:z", color: "#AAAAAA",
                            themeId: "coral", light: 0.5, dark: 0.5),
                      local("B", name: "m")]
        let accounts = [account("acct-2", name: "N", icon: "phi:y", color: "#BBBBBB",
                                themeId: "pure", light: 600, dark: 600),
                        account("acct-1", name: "M")]
        let out = diffs(["A": .existing(syncUuid: "acct-2"), "B": .existing(syncUuid: "acct-1")],
                        locals: locals, accounts: accounts)
        XCTAssertEqual(out.map(\.localSpaceId), ["A", "B"], "Section order matches decisions() order")
        XCTAssertEqual(out[0].changes.map(\.field),
                       [.name, .icon, .color, .theme, .opacityLight, .opacityDark])
    }

    // 15: Intentional: Swift String equality is case-sensitive, and land uses that operator.
    func testColorHexCaseIsARealDifferenceBecauseLandUsesTheSameOperator() {
        let out = diffs(["A": .existing(syncUuid: "acct-1")],
                        locals: [local("A", color: "#AABBCC")],
                        accounts: [account("acct-1", color: "#aabbcc")])
        XCTAssertEqual(out.first?.changes.map(\.field), [.color])
    }

    // 16
    func testUnresolvableRowsAreSkippedRatherThanTrapping() {
        let out = SpaceOverwriteDiff.diffs(
            decisions: [(localSpaceId: "A", assignment: .existing(syncUuid: "ghost")),
                        (localSpaceId: "GONE", assignment: .existing(syncUuid: "acct-1")),
                        (localSpaceId: "B", assignment: .existing(syncUuid: "acct-1"))],
            locals: [local("A"), local("B", name: "Renamed")],
            accountSpaces: [account("acct-1")],
            themeDisplayName: { _ in nil })
        XCTAssertEqual(out.map(\.localSpaceId), ["B"],
                       "Skip unresolved rows without trapping or affecting other rows")
    }
}

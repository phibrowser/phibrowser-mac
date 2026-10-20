import XCTest
@testable import Phi

/// The pairing wizard's page plan (docs/sync.md, "Pairing page plan"): which pages show, when the wizard
/// completes on its own, and the decisions a hidden Profiles page stands for.
final class PairingFlowPlanTests: XCTestCase {
    private func facts(brandNew: Bool = false, complete: Bool = true, replaceable: Bool = false,
                       profiles: Bool = false, profileRows: Bool = true,
                       spaces: Bool = false) -> PairingFlowFacts {
        PairingFlowFacts(isBrandNewAccount: brandNew, previewComplete: complete,
                         localHasReplaceableData: replaceable, profilesNeedDecision: profiles,
                         profilesHaveRows: profileRows, spacesNeedDecision: spaces)
    }

    private func space(_ id: String, profile: String = "Default") -> PhiLocalSpace {
        PhiLocalSpace(spaceId: id, profileId: profile, name: id, colorHex: "#3AA4D5",
                      iconName: "phi:a", sortOrder: 0, createdDate: Date(timeIntervalSince1970: 1),
                      themeId: nil, opacityLight: nil, opacityDark: nil)
    }

    private func accountSpace(_ uuid: String) -> PhiAccountSpaceSummary {
        PhiAccountSpaceSummary(syncUuid: uuid, name: uuid, iconName: "phi:a", colorHex: "#3AA4D5",
                               profileUuid: "uuid-work", isDefault: false, themeId: "",
                               overlayOpacityLightMilli: -1, overlayOpacityDarkMilli: -1)
    }

    private let localDefault = PairingLocal(profileId: "Default", displayName: "Personal", isDefault: true)
    private let localExtra = PairingLocal(profileId: "Profile 2", displayName: "Reading", isDefault: false)
    private let accountDefault = RemoteProfile(uuid: "uuid-default", name: "Your Phi", isDefault: true)
    private let accountWork = RemoteProfile(uuid: "uuid-work", name: "Work", isDefault: false)
    private let accountLegacy = RemoteProfile(uuid: "uuid-legacy", name: "Old", isDefault: nil)
    private let unreadable = RemoteProfile(uuid: "uuid-unreadable", name: nil)

    // MARK: - make(_:) over the design cases

    func testThePlanTable() {
        struct Row {
            let name: String
            let facts: PairingFlowFacts
            let enabled: Bool
            let method: Bool, profiles: Bool, spaces: Bool
        }
        let rows: [Row] = [
            Row(name: "brand-new account", facts: facts(brandNew: true, replaceable: true, profiles: true, spaces: true),
                enabled: true, method: false, profiles: false, spaces: false),
            Row(name: "default-only Mac, account with data", facts: facts(),
                enabled: true, method: false, profiles: false, spaces: false),
            Row(name: "default Profile with extra Spaces", facts: facts(replaceable: true, spaces: true),
                enabled: false, method: false, profiles: false, spaces: true),
            Row(name: "default Profile with extra Spaces, method step enabled",
                facts: facts(replaceable: true, spaces: true),
                enabled: true, method: true, profiles: false, spaces: true),
            Row(name: "extra local Profile", facts: facts(replaceable: true, profiles: true),
                enabled: false, method: false, profiles: true, spaces: false),
            Row(name: "extra local Profile, method step enabled", facts: facts(replaceable: true, profiles: true),
                enabled: true, method: true, profiles: true, spaces: false),
            Row(name: "incomplete preview with Profile rows", facts: facts(complete: false),
                enabled: false, method: false, profiles: true, spaces: false),
            Row(name: "incomplete preview without Profile rows", facts: facts(complete: false, profileRows: false),
                enabled: false, method: false, profiles: false, spaces: true),
        ]
        for row in rows {
            let plan = PairingFlowPlan.make(row.facts, methodStepEnabled: row.enabled)
            XCTAssertEqual(plan.showsMethod, row.method, row.name)
            XCTAssertEqual(plan.showsProfiles, row.profiles, row.name)
            XCTAssertEqual(plan.showsSpaces, row.spaces, row.name)
            XCTAssertEqual(plan.autoCompletes, !row.method && !row.profiles && !row.spaces, row.name)
        }
    }

    func testTheMethodStepIsEnabled() {
        XCTAssertTrue(PairingFlowPlan.methodStepEnabled)
        XCTAssertTrue(PairingFlowPlan.make(facts(replaceable: true, profiles: true)).showsMethod,
                      "The default planner shows the method step when this Mac has replaceable data")
        XCTAssertFalse(PairingFlowPlan.make(facts()).showsMethod, "Nothing to replace: no method step")
        XCTAssertFalse(PairingFlowPlan.make(facts(brandNew: true, replaceable: true)).showsMethod,
                       "A brand-new account has nothing to choose between")
    }

    /// The method step alone does not complete on its own: it still asks merge or replace.
    func testAMethodOnlyPlanAsksBeforeFinishing() {
        let plan = PairingFlowPlan.make(facts(replaceable: true))
        XCTAssertEqual(plan, PairingFlowPlan(showsMethod: true, showsProfiles: false, showsSpaces: false))
        XCTAssertFalse(plan.autoCompletes)
        XCTAssertEqual(plan.steps(for: .merge), [.method])
        XCTAssertEqual(plan.steps(for: .useAccount), [.method, .confirm])
    }

    /// The method step's primary button: Finish only when merging leads to no further page.
    func testFinishOrContinueAtTheMethodStep() {
        let methodOnly = PairingFlowPlan(showsMethod: true, showsProfiles: false, showsSpaces: false)
        XCTAssertTrue(methodOnly.finishesAtMethodStep(for: .merge))
        XCTAssertFalse(methodOnly.finishesAtMethodStep(for: .useAccount), "The confirmation always follows")
        for plan in [PairingFlowPlan(showsMethod: true, showsProfiles: true, showsSpaces: false),
                     PairingFlowPlan(showsMethod: true, showsProfiles: false, showsSpaces: true)] {
            XCTAssertFalse(plan.finishesAtMethodStep(for: .merge))
            XCTAssertFalse(plan.finishesAtMethodStep(for: .useAccount))
        }
    }

    func testAnIncompletePreviewNeverAutoCompletes() {
        for profileRows in [true, false] {
            let plan = PairingFlowPlan.make(facts(complete: false, profileRows: profileRows),
                                            methodStepEnabled: true)
            XCTAssertFalse(plan.autoCompletes, "profileRows=\(profileRows)")
        }
    }

    // MARK: - steps(for:)

    func testStepsForBothMethods() {
        let all = PairingFlowPlan(showsMethod: true, showsProfiles: true, showsSpaces: true)
        XCTAssertEqual(all.steps(for: .merge), [.method, .profiles, .spaces])
        XCTAssertEqual(all.steps(for: .useAccount), [.method, .confirm])

        let spacesOnly = PairingFlowPlan(showsMethod: false, showsProfiles: false, showsSpaces: true)
        XCTAssertEqual(spacesOnly.steps(for: .merge), [.spaces])

        let methodOnly = PairingFlowPlan(showsMethod: true, showsProfiles: false, showsSpaces: false)
        XCTAssertEqual(methodOnly.steps(for: .merge), [.method])
        XCTAssertFalse(methodOnly.autoCompletes)

        let none = PairingFlowPlan(showsMethod: false, showsProfiles: false, showsSpaces: false)
        XCTAssertEqual(none.steps(for: .merge), [])
        XCTAssertTrue(none.autoCompletes)
    }

    func testRevealingProfilesKeepsTheOtherPages() {
        let plan = PairingFlowPlan(showsMethod: false, showsProfiles: false, showsSpaces: true)
        XCTAssertEqual(plan.revealingProfiles(),
                       PairingFlowPlan(showsMethod: false, showsProfiles: true, showsSpaces: true))
    }

    // MARK: - Predicates

    func testProfilesNeedDecision() {
        XCTAssertTrue(PairingFlowPlan.profilesNeedDecision(locals: [localDefault, localExtra], remotes: []),
                      "A non-default local Profile is always the user's call")
        XCTAssertTrue(PairingFlowPlan.profilesNeedDecision(locals: [localDefault], remotes: [accountLegacy]),
                      "The Default with no account default gets a picker over legacy Profiles")
        XCTAssertFalse(PairingFlowPlan.profilesNeedDecision(locals: [localDefault],
                                                            remotes: [accountDefault, accountWork]),
                       "The Default is fixed to the account default; the rest is created here")
        XCTAssertFalse(PairingFlowPlan.profilesNeedDecision(locals: [localDefault], remotes: []),
                       "The Default registers as the account default")
        XCTAssertTrue(PairingFlowPlan.profilesNeedDecision(locals: [localDefault], remotes: [accountWork]),
                      "No account default to fix the Default to: the user decides")
        XCTAssertFalse(PairingFlowPlan.profilesNeedDecision(locals: [], remotes: [accountWork]),
                       "Every local is already mapped; the account Profile is created here")
    }

    func testUnreadableRemotes() {
        XCTAssertTrue(PairingFlowPlan.profilesNeedDecision(locals: [localDefault], remotes: [unreadable]),
                      "An unreadable Profile may be the account default: never register the Default unseen")
        XCTAssertTrue(PairingFlowPlan.profilesNeedDecision(locals: [localDefault],
                                                           remotes: [unreadable, accountWork]))
        XCTAssertFalse(PairingFlowPlan.profilesNeedDecision(locals: [], remotes: [unreadable]),
                       "Every local mapped and nothing readable: nothing to ask")
        let skip = PairingFlowPlan.make(facts(profiles: false, profileRows: false, spaces: true))
        XCTAssertEqual(skip.steps(for: .merge), [.spaces], "No unmapped local, all unreadable: straight to Spaces")
        XCTAssertFalse(PairingFlowPlan.profilesHaveRows(locals: [], remotes: [unreadable]))
        XCTAssertTrue(PairingFlowPlan.profilesHaveRows(locals: [], remotes: [accountWork]))
        XCTAssertTrue(PairingFlowPlan.profilesHaveRows(locals: [localDefault], remotes: []))
    }

    func testAutoRemoteChoicesCreateEveryUnclaimedReadableProfileButTheAuthoritativeDefault() {
        let locals = [localDefault]
        let remotes = [accountDefault, accountWork, unreadable]
        let choices = PairingFlowPlan.autoRemoteChoices(
            locals: locals, remotes: remotes,
            selections: ProfilePairingModel.initialSelections(locals: locals, remotes: remotes))
        XCTAssertEqual(choices, ["uuid-work": .createLocal])

        // The choices decide every row, so the Profiles page has nothing left to ask.
        let model = ProfilePairingModel(locals: locals, remotes: remotes,
                                        selections: ProfilePairingModel.initialSelections(locals: locals,
                                                                                          remotes: remotes),
                                        remoteChoices: choices)
        XCTAssertEqual(model.claimedRemoteUuids, ["uuid-default"])
        XCTAssertEqual(model.createLocalUuids, ["uuid-work"])
    }

    func testAutoRemoteChoicesWithEveryLocalMapped() {
        let choices = PairingFlowPlan.autoRemoteChoices(locals: [], remotes: [accountDefault, accountWork],
                                                        selections: [:])
        XCTAssertEqual(choices, ["uuid-default": .createLocal, "uuid-work": .createLocal],
                       "No local Default here, so no account default is authoritative")
    }

    func testSpacesNeedDecision() {
        func input(_ locals: [PhiLocalSpace]) -> SpacePairingModel.Input {
            SpacePairingModel.Input(locals: locals, accountSpaces: [accountSpace("acct-1")],
                                    localProfileNames: [:], accountProfileNames: [:])
        }
        XCTAssertFalse(PairingFlowPlan.spacesNeedDecision(input([space(LocalStore.defaultSpaceId)])),
                       "The default Space is never a row")
        XCTAssertTrue(PairingFlowPlan.spacesNeedDecision(input([space(LocalStore.defaultSpaceId),
                                                                space("LOCAL-1")])))
    }

    func testLocalHasReplaceableData() {
        let defaultOnly = [space(LocalStore.defaultSpaceId)]
        XCTAssertFalse(PairingFlowPlan.localHasReplaceableData(
            localProfileIds: [LocalStore.defaultProfileId], localSpaces: defaultOnly, ownedItemsPresent: false),
            "A fresh install's seeded data is not replaceable data")
        XCTAssertTrue(PairingFlowPlan.localHasReplaceableData(
            localProfileIds: [LocalStore.defaultProfileId], localSpaces: defaultOnly, ownedItemsPresent: nil),
            "An unknown inventory cannot prove this Mac is empty")
        XCTAssertTrue(PairingFlowPlan.localHasReplaceableData(
            localProfileIds: [LocalStore.defaultProfileId], localSpaces: defaultOnly, ownedItemsPresent: true))
        XCTAssertTrue(PairingFlowPlan.localHasReplaceableData(
            localProfileIds: [LocalStore.defaultProfileId, "Profile 2"], localSpaces: defaultOnly,
            ownedItemsPresent: false))
        XCTAssertTrue(PairingFlowPlan.localHasReplaceableData(
            localProfileIds: [LocalStore.defaultProfileId], localSpaces: defaultOnly + [space("LOCAL-1")],
            ownedItemsPresent: false))
    }

    func testOwnedItemsFromTheInventory() {
        XCTAssertNil(PairingFlowPlan.ownedItemsPresent(nil), "An unreadable inventory is unknown")
        XCTAssertEqual(PairingFlowPlan.ownedItemsPresent(LocalPhiInventory()), false)
        XCTAssertEqual(PairingFlowPlan.ownedItemsPresent(LocalPhiInventory(nonDefaultSpaceIds: ["LOCAL-1"],
                                                                           profileIdsToDelete: ["P"])),
                       false, "Spaces and Profiles are judged separately")
        for inventory in [LocalPhiInventory(bookmarks: 1), LocalPhiInventory(bookmarkFolders: 1),
                          LocalPhiInventory(pinnedTabs: 1), LocalPhiInventory(urlRules: 1)] {
            XCTAssertEqual(PairingFlowPlan.ownedItemsPresent(inventory), true, "\(inventory)")
        }
        let defaultOnly = [space(LocalStore.defaultSpaceId)]
        XCTAssertTrue(PairingFlowPlan.localHasReplaceableData(
            localProfileIds: [LocalStore.defaultProfileId], localSpaces: defaultOnly,
            ownedItemsPresent: PairingFlowPlan.ownedItemsPresent(nil)),
            "An inventory read failure shows the method step")
    }

    // MARK: - Replacing this Mac's data

    func testExtraLocalsAreTheUnmatchedNonDefaultProfiles() {
        let sameName = PairingLocal(profileId: "Profile 3", displayName: "Work", isDefault: false)
        XCTAssertEqual(PairingFlowPlan.extraLocals(locals: [localDefault, localExtra, sameName],
                                                   remotes: [accountDefault, accountWork]),
                       [localExtra], "The Default and a same-name Profile adopt without asking")
        XCTAssertEqual(PairingFlowPlan.extraLocals(locals: [localDefault], remotes: [accountDefault]), [])
    }

    func testReplacingAdoptsASameNameProfileAndDeletesOnlyTheExtras() {
        let sameName = PairingLocal(profileId: "Profile 3", displayName: "Work", isDefault: false)
        let locals = [localDefault, localExtra, sameName]
        let remotes = [accountDefault, accountWork]
        let deleting = Set(PairingFlowPlan.extraLocals(locals: locals, remotes: remotes).map(\.profileId))
        XCTAssertEqual(deleting, ["Profile 2"], "The same-name Profile is not deleted")
        XCTAssertEqual(PairingFlowPlan.replaceDecisions(locals: locals, remotes: remotes, deleting: deleting), [
            .adopt(localProfileId: "Default", remoteUuid: "uuid-default"),
            .adopt(localProfileId: "Profile 3", remoteUuid: "uuid-work"),
        ], "The same-name Profile adopts its account Profile, so nothing is created for it")
    }

    func testReplaceDecisionsGiveDeletedExtrasNoDecisionAndRegisterOnlyUndeletedOnes() {
        let locals = [localDefault, localExtra]
        let remotes = [accountDefault, accountWork, unreadable]
        let extras = Set(PairingFlowPlan.extraLocals(locals: locals, remotes: remotes).map(\.profileId))
        XCTAssertEqual(extras, ["Profile 2"])
        XCTAssertEqual(PairingFlowPlan.replaceDecisions(locals: locals, remotes: remotes, deleting: extras), [
            .adopt(localProfileId: "Default", remoteUuid: "uuid-default"),
            .createLocal(remoteUuid: "uuid-work", displayName: "Work"),
        ], "Every extra is deleted without a decision; the unclaimed readable Profile is created; the unreadable one waits")
        XCTAssertEqual(PairingFlowPlan.replaceDecisions(locals: locals, remotes: remotes, deleting: []), [
            .adopt(localProfileId: "Default", remoteUuid: "uuid-default"),
            .registerNew(localProfileId: "Profile 2", displayName: "Reading"),
            .createLocal(remoteUuid: "uuid-work", displayName: "Work"),
        ], "An extra outside the marker's set (created after a replace started) registers")
        XCTAssertEqual(PairingFlowPlan.replaceDecisions(locals: [], remotes: [unreadable], deleting: []), [],
                       "A replay after the decisions applied has nothing left to do")
    }

    func testDefaultNeedsChoice() {
        XCTAssertFalse(PairingFlowPlan.defaultNeedsChoice(locals: [localDefault], remotes: [accountDefault]))
        XCTAssertFalse(PairingFlowPlan.defaultNeedsChoice(locals: [localDefault], remotes: []))
        XCTAssertFalse(PairingFlowPlan.defaultNeedsChoice(locals: [localExtra], remotes: [unreadable]),
                       "A mapped Default needs nothing")
        XCTAssertTrue(PairingFlowPlan.defaultNeedsChoice(locals: [localDefault], remotes: [unreadable]))
        XCTAssertTrue(PairingFlowPlan.defaultNeedsChoice(locals: [localDefault], remotes: [accountLegacy]))
    }

    func testIsBrandNewAccount() {
        XCTAssertTrue(PairingFlowPlan.isBrandNewAccount(createdByThisFlow: true, previewComplete: true,
                                                        remotes: [], accountSpaces: []))
        XCTAssertFalse(PairingFlowPlan.isBrandNewAccount(createdByThisFlow: false, previewComplete: true,
                                                         remotes: [], accountSpaces: []),
                       "Joining an existing account is never brand new")
        XCTAssertFalse(PairingFlowPlan.isBrandNewAccount(createdByThisFlow: true, previewComplete: false,
                                                         remotes: [], accountSpaces: []),
                       "An incomplete preview does not prove the account is empty")
        XCTAssertFalse(PairingFlowPlan.isBrandNewAccount(createdByThisFlow: true, previewComplete: true,
                                                         remotes: [accountWork], accountSpaces: []))
        XCTAssertFalse(PairingFlowPlan.isBrandNewAccount(createdByThisFlow: true, previewComplete: true,
                                                         remotes: [], accountSpaces: [accountSpace("acct-1")]))
    }
}

// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// The parts of a run that can be pinned without a running browser: the pure
/// fold from a plan plus what the run produced into the report, the scoped
/// construct that holds a Space under the import target lock, and the mark a
/// finished run leaves so a second one from the same source warns first.
final class BrowserMigrationRunTests: XCTestCase {

    private let operationID = UUID(uuidString: "00000000-0000-0000-0000-0000000000CC")!

    // MARK: - Fixture builders

    /// A one-link tree. The fold reads only whether the plan carries a tree at
    /// all — what is in it is the store's business — so one link is enough.
    private func tree() -> ArcDataParserTool.Bookmark {
        let root = ArcDataParserTool.Bookmark(
            guid: "root", title: "Space", url: nil, isFolder: true)
        root.children = [ArcDataParserTool.Bookmark(
            guid: "leaf", title: "Example", url: "https://example.com", isFolder: false)]
        return root
    }

    private func space(
        _ id: String, _ name: String, profileKey: String, bookmarks: Bool = true
    ) -> BrowserMigrationSourceSpace {
        BrowserMigrationSourceSpace(
            id: id, name: name, colorHex: "#112233", profileKey: profileKey,
            bookmarkRoot: bookmarks ? tree() : nil)
    }

    /// Two profiles, the first with two Spaces, so the report's order and its
    /// "first created Space" both have something to get wrong.
    private func plan() -> BrowserMigrationPlan {
        let source = BrowserMigrationSource(
            profiles: [
                BrowserMigrationSourceProfile(key: "Default", displayName: "Personal"),
                BrowserMigrationSourceProfile(key: "Profile 1", displayName: "Work"),
            ],
            defaultProfileKey: "Default",
            spaces: [
                space("s-home", "Home", profileKey: "Default"),
                space("s-side", "Side Projects", profileKey: "Default"),
                space("s-work", "Work", profileKey: "Profile 1"),
            ])
        return BrowserMigrationPlanner.plan(
            source: source,
            existingProfileDisplayNames: [],
            pinnedTabScope: .profile,
            selection: .all(in: source),
            operationID: operationID)
    }

    /// A source whose bookmarks arrive Chromium-side carries no Mac-side tree,
    /// so its Spaces have no Bookmarks step of their own.
    private func planWithoutTrees() -> BrowserMigrationPlan {
        let source = BrowserMigrationSource(
            profiles: [BrowserMigrationSourceProfile(key: "Default", displayName: "Personal")],
            defaultProfileKey: "Default",
            spaces: [space("s-home", "Home", profileKey: "Default", bookmarks: false)])
        return BrowserMigrationPlanner.plan(
            source: source,
            existingProfileDisplayNames: [],
            pinnedTabScope: .profile,
            selection: .all(in: source),
            operationID: operationID)
    }

    /// One profile with two Spaces and two pinned entries, so both the fan-out
    /// and a dropped entry have something to get wrong.
    private func planWithPinnedEntries(scope: PinnedTabScope) -> BrowserMigrationPlan {
        let source = BrowserMigrationSource(
            profiles: [BrowserMigrationSourceProfile(key: "Default", displayName: "Personal")],
            defaultProfileKey: "Default",
            spaces: [
                space("s-home", "Home", profileKey: "Default"),
                space("s-side", "Side Projects", profileKey: "Default"),
            ],
            pinnedGroups: [BrowserMigrationSourcePinnedGroup(
                profileKey: "Default",
                entries: [
                    BrowserMigrationPinnedEntry(title: "Mail", url: "https://mail.example"),
                    BrowserMigrationPinnedEntry(title: "Docs", url: "https://docs.example"),
                ])])
        return BrowserMigrationPlanner.plan(
            source: source,
            existingProfileDisplayNames: [],
            pinnedTabScope: scope,
            selection: .all(in: source),
            operationID: operationID)
    }

    /// Both Spaces of the pinned-entry plan landed.
    private func pinnedEntryOutcomes() -> BrowserMigrationOutcomes {
        outcomes(
            profiles: ["Default": "Profile 2"],
            spaces: ["s-home": "id-home", "s-side": "id-side"])
    }

    private func outcomes(
        profiles: [String: String] = [:],
        spaces: [String: String] = [:]
    ) -> BrowserMigrationOutcomes {
        BrowserMigrationOutcomes(profileIDs: profiles, spaceIDs: spaces)
    }

    /// Everything the plan asked for landed.
    private func fullOutcomes() -> BrowserMigrationOutcomes {
        outcomes(
            profiles: ["Default": "Profile 2", "Profile 1": "Profile 3"],
            spaces: ["s-home": "id-home", "s-side": "id-side", "s-work": "id-work"])
    }

    // MARK: - Structure

    func testTheReportListsProfilesAndTheirSpacesInPlanOrder() {
        let report = BrowserMigrationReport.folded(plan: plan(), outcomes: fullOutcomes())

        XCTAssertEqual(report.profiles.map(\.displayName), ["Personal", "Work"])
        XCTAssertEqual(report.profiles[0].spaces.map(\.name), ["Home", "Side Projects"])
        XCTAssertEqual(report.profiles[1].spaces.map(\.name), ["Work"])
    }

    func testEverythingThatLandedIsReportedCreated() {
        let report = BrowserMigrationReport.folded(plan: plan(), outcomes: fullOutcomes())

        XCTAssertTrue(report.profiles.allSatisfy(\.created))
        XCTAssertTrue(report.profiles.flatMap(\.spaces).allSatisfy(\.created))
    }

    // MARK: - Failures

    func testAFailedUnitIsReportedNotCreatedAndTheRestStillLand() {
        let report = BrowserMigrationReport.folded(
            plan: plan(),
            outcomes: outcomes(
                profiles: ["Default": "Profile 2", "Profile 1": "Profile 3"],
                spaces: ["s-home": "id-home", "s-work": "id-work"]))

        XCTAssertEqual(report.profiles[0].spaces.map(\.created), [true, false])
        XCTAssertTrue(report.profiles[1].spaces[0].created)
    }

    func testAProfileThatFailedReportsItsSpacesNotCreatedToo() {
        let report = BrowserMigrationReport.folded(
            plan: plan(),
            outcomes: outcomes(
                profiles: ["Profile 1": "Profile 3"], spaces: ["s-work": "id-work"]))

        XCTAssertFalse(report.profiles[0].created)
        XCTAssertEqual(report.profiles[0].spaces.map(\.created), [false, false])
        XCTAssertTrue(report.profiles[1].created)
    }

    // MARK: - Bookmarks

    func testASpaceReportsTheBookmarksThatPersisted() {
        var outcomes = fullOutcomes()
        outcomes.spaceBookmarkCounts = ["s-home": 4, "s-side": 0, "s-work": 2]

        let report = BrowserMigrationReport.folded(plan: plan(), outcomes: outcomes)

        XCTAssertEqual(report.profiles[0].spaces.map(\.bookmarks), [.written(4), .written(0)])
        XCTAssertEqual(report.profiles[1].spaces[0].bookmarks, .written(2))
    }

    /// The outcome comes from the write, not from the import completion signal
    /// that reports success unconditionally — so a Space that landed but whose
    /// tree did not is reported as what it is.
    func testASpaceWhoseBookmarksDidNotPersistSaysSo() {
        var outcomes = fullOutcomes()
        outcomes.spaceBookmarkCounts = ["s-home": 3, "s-work": 1]

        let report = BrowserMigrationReport.folded(plan: plan(), outcomes: outcomes)

        XCTAssertEqual(report.profiles[0].spaces.map(\.bookmarks), [.written(3), .failed])
        XCTAssertTrue(report.profiles[0].spaces.allSatisfy(\.created))
        // The Space that lost its Bookmarks leaves the rest of the run alone.
        XCTAssertEqual(report.profiles[1].spaces[0].bookmarks, .written(1))
    }

    func testASpaceThatWasNeverCreatedAttemptsNoBookmarks() {
        let report = BrowserMigrationReport.folded(
            plan: plan(), outcomes: outcomes(profiles: ["Default": "Profile 2"]))

        XCTAssertEqual(
            report.profiles[0].spaces.map(\.bookmarks), [.notAttempted, .notAttempted])
    }

    /// Distinct from a failed write: nothing was to be written in the first
    /// place, so the report must not imply anything was lost.
    func testASpaceWithNoSourceTreeAttemptsNoBookmarks() {
        let report = BrowserMigrationReport.folded(
            plan: planWithoutTrees(),
            outcomes: outcomes(
                profiles: ["Default": "Profile 2"], spaces: ["s-home": "id-home"]))

        XCTAssertTrue(report.profiles[0].spaces[0].created)
        XCTAssertEqual(report.profiles[0].spaces[0].bookmarks, .notAttempted)
    }

    // MARK: - History, cookies and extensions

    /// A request, not a result: the count is what installation was triggered
    /// for, and the row claims nothing about the cookies beyond having asked
    /// for them.
    func testAProfileReportsWhatItsDataImportWasAskedFor() {
        var outcomes = fullOutcomes()
        outcomes.profileExtensionCounts = ["Default": 7, "Profile 1": 0]

        let report = BrowserMigrationReport.folded(plan: plan(), outcomes: outcomes)

        XCTAssertEqual(report.profiles[0].browserData, .requested(extensions: 7))
        XCTAssertEqual(report.profiles[1].browserData, .requested(extensions: 0))
    }

    func testAProfileWhoseDataImportFailedSaysSoAndTheNextOneStillLands() {
        var outcomes = fullOutcomes()
        outcomes.profileExtensionCounts = ["Profile 1": 2]

        let report = BrowserMigrationReport.folded(plan: plan(), outcomes: outcomes)

        XCTAssertEqual(report.profiles[0].browserData, .failed)
        XCTAssertTrue(report.profiles[0].created)
        XCTAssertEqual(report.profiles[1].browserData, .requested(extensions: 2))
    }

    /// Distinct from a failed import: there was no Profile to import into, so
    /// the report must not imply anything was lost.
    func testAProfileThatWasNeverCreatedAttemptsNoDataImport() {
        let report = BrowserMigrationReport.folded(
            plan: plan(), outcomes: outcomes(profiles: ["Profile 1": "Profile 3"]))

        XCTAssertEqual(report.profiles[0].browserData, .notAttempted)
        XCTAssertEqual(report.profiles[1].browserData, .failed)
    }

    // MARK: - Pinned tabs

    func testAProfileReportsThePinnedTabsThatLanded() {
        let plan = planWithPinnedEntries(scope: .profile)
        var landed = pinnedEntryOutcomes()
        landed.pinnedTabGuids = Set(plan.profiles[0].pinnedTabs.map(\.guid))

        let report = BrowserMigrationReport.folded(plan: plan, outcomes: landed)

        XCTAssertEqual(report.profiles[0].pinnedTabsWritten, 2)
        XCTAssertEqual(report.profiles[0].pinnedTabsPlanned, 2)
    }

    /// One entry written once per Space is still one entry: the report states
    /// what the user sees in any one Space, not how many rows the run wrote.
    func testFanOutCopiesCountAsTheOneEntryTheyCameFrom() {
        let plan = planWithPinnedEntries(scope: .space)
        var landed = pinnedEntryOutcomes()
        landed.pinnedTabGuids = Set(plan.profiles[0].pinnedTabs.map(\.guid))

        XCTAssertEqual(plan.profiles[0].pinnedTabs.count, 4)
        let report = BrowserMigrationReport.folded(plan: plan, outcomes: landed)

        XCTAssertEqual(report.profiles[0].pinnedTabsWritten, 2)
        XCTAssertEqual(report.profiles[0].pinnedTabsPlanned, 2)
    }

    /// An entry the store refused — one whose URL it could not parse — is
    /// reported as missing rather than counted as though it had landed.
    func testAnEntryTheStoreRefusedIsReportedAsAShortfall() {
        let plan = planWithPinnedEntries(scope: .profile)
        var landed = pinnedEntryOutcomes()
        landed.pinnedTabGuids = [plan.profiles[0].pinnedTabs[0].guid]

        let report = BrowserMigrationReport.folded(plan: plan, outcomes: landed)

        XCTAssertEqual(report.profiles[0].pinnedTabsWritten, 1)
        XCTAssertEqual(report.profiles[0].pinnedTabsPlanned, 2)
        // The rest of the run is untouched by it.
        XCTAssertTrue(report.profiles[0].spaces.allSatisfy(\.created))
    }

    /// Distinct from a shortfall: the source had nothing to pin, so the report
    /// must not imply anything was lost.
    func testAProfileWhoseSourceHadNoPinnedEntriesReportsNone() {
        let report = BrowserMigrationReport.folded(plan: plan(), outcomes: fullOutcomes())

        XCTAssertTrue(report.profiles.allSatisfy { $0.pinnedTabsPlanned == 0 })
        XCTAssertTrue(report.profiles.allSatisfy { $0.pinnedTabsWritten == 0 })
    }

    // MARK: - The Space the report jumps to

    func testTheReportJumpsToTheFirstSpaceInPlanOrder() {
        let report = BrowserMigrationReport.folded(plan: plan(), outcomes: fullOutcomes())

        XCTAssertEqual(report.firstCreatedSpace?.spaceID, "id-home")
        XCTAssertEqual(report.firstCreatedSpace?.name, "Home")
    }

    func testTheFirstCreatedSpaceSkipsOneThatFailed() {
        let report = BrowserMigrationReport.folded(
            plan: plan(),
            outcomes: outcomes(
                profiles: ["Default": "Profile 2", "Profile 1": "Profile 3"],
                spaces: ["s-side": "id-side", "s-work": "id-work"]))

        XCTAssertEqual(report.firstCreatedSpace?.spaceID, "id-side")
    }

    func testARunThatCreatedNoSpaceHasNoneToJumpTo() {
        let report = BrowserMigrationReport.folded(
            plan: plan(), outcomes: outcomes(profiles: ["Default": "Profile 2"]))

        XCTAssertNil(report.firstCreatedSpace)
    }

    // MARK: - Holding a Space under the import target lock

    func testAHeldSpaceIsLockedForTheDurationAndReleasedAfter() async {
        let spaceID = "held-space"

        await ImportTargetLock.shared.holding(spaceID) {
            XCTAssertTrue(ImportTargetLock.shared.isImporting(into: spaceID))
        }

        XCTAssertFalse(ImportTargetLock.shared.isImporting(into: spaceID))
    }

    func testAThrownErrorStillReleasesTheSpace() async {
        struct Failure: Error {}
        let spaceID = "thrown-space"

        do {
            try await ImportTargetLock.shared.holding(spaceID) { throw Failure() }
            XCTFail("expected the error to propagate")
        } catch is Failure {
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertFalse(ImportTargetLock.shared.isImporting(into: spaceID))
    }

    func testAnEarlyReturnStillReleasesTheSpace() async {
        let spaceID = "early-return-space"
        var ranToTheEnd = false

        await ImportTargetLock.shared.holding(spaceID) {
            // Always taken; written as a guard so the body really does leave
            // through an early return rather than falling off its end.
            guard ProcessInfo.processInfo.processIdentifier == 0 else { return }
            ranToTheEnd = true
        }

        XCTAssertFalse(ranToTheEnd)
        XCTAssertFalse(ImportTargetLock.shared.isImporting(into: spaceID))
    }

    // MARK: - The already-migrated mark

    /// One account's preferences on a file of their own, so what one case
    /// records cannot reach another — which is also what a second account
    /// looks like to the first one's mark.
    private func makeStoreURL() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("account_defaults.plist")
    }

    private func makeDefaults(at url: URL, userID: String = "migration-mark")
        -> AccountUserDefaults {
        AccountUserDefaults(account: Account(userID: userID), storeURL: url)
    }

    func testAnAccountThatHasNotMigratedCarriesNoMark() throws {
        XCTAssertEqual(makeDefaults(at: try makeStoreURL()).migratedBrowserSources(), [])
    }

    func testACompletedMigrationMarksItsSource() throws {
        let defaults = makeDefaults(at: try makeStoreURL())

        defaults.addMigratedBrowserSource(BrowserMigrationSourceKind.arc.rawValue)

        XCTAssertEqual(defaults.migratedBrowserSources(), ["arc"])
    }

    func testAnotherSourceIsUnaffectedByOnesMark() throws {
        let defaults = makeDefaults(at: try makeStoreURL())

        defaults.addMigratedBrowserSource(BrowserMigrationSourceKind.arc.rawValue)

        XCTAssertFalse(defaults.migratedBrowserSources().contains("some-other-source"))
    }

    func testMigratingFromTheSameSourceAgainLeavesOneMark() throws {
        let defaults = makeDefaults(at: try makeStoreURL())

        defaults.addMigratedBrowserSource(BrowserMigrationSourceKind.arc.rawValue)
        defaults.addMigratedBrowserSource(BrowserMigrationSourceKind.arc.rawValue)

        XCTAssertEqual(defaults.migratedBrowserSources(), ["arc"])
    }

    func testTheMarkOutlivesTheAppThatWroteIt() throws {
        let url = try makeStoreURL()
        makeDefaults(at: url).addMigratedBrowserSource(BrowserMigrationSourceKind.arc.rawValue)

        XCTAssertEqual(makeDefaults(at: url).migratedBrowserSources(), ["arc"])
    }

    /// A mark lives in the preferences of the account that made it, which are
    /// a file of that account's own — so the account signed into next reads
    /// none of it.
    func testAnotherAccountDoesNotSeeThisOnesMark() throws {
        makeDefaults(at: try makeStoreURL(), userID: "first")
            .addMigratedBrowserSource(BrowserMigrationSourceKind.arc.rawValue)

        let other = makeDefaults(at: try makeStoreURL(), userID: "second")

        XCTAssertEqual(other.migratedBrowserSources(), [])
    }

    // MARK: - Warning before a second run

    @MainActor
    func testAMarkedSourceWarnsWhileTheFirstMigrationsSpacesAreStillThere() {
        XCTAssertTrue(BrowserMigrationWizardModel.warnsBeforeRerun(
            hasMigrated: true, spaceCount: 4))
    }

    /// The account has been taken back down to its one default Space, so
    /// whatever the first Migration created is gone and there is nothing left
    /// for a second one to duplicate.
    @MainActor
    func testAMarkedSourceStaysQuietWhenOnlyOneSpaceIsLeft() {
        XCTAssertFalse(BrowserMigrationWizardModel.warnsBeforeRerun(
            hasMigrated: true, spaceCount: 1))
    }

    @MainActor
    func testAnUnmarkedSourceNeverWarnsHoweverManySpacesThereAre() {
        XCTAssertFalse(BrowserMigrationWizardModel.warnsBeforeRerun(
            hasMigrated: false, spaceCount: 4))
    }

    /// That the wizard consults the mark at all. Asserted from the unmarked
    /// side because it is the half that does not depend on the machine: the
    /// test host runs against whatever Spaces the developer's account holds,
    /// so the marked side belongs to `warnsBeforeRerun` above, where the count
    /// is a parameter. Nothing starts either way — the model has no plan.
    @MainActor
    func testStartConsultsTheMark() {
        BrowserMigrationRunner.migratedSourcesOverrideForTesting = []
        defer { BrowserMigrationRunner.migratedSourcesOverrideForTesting = nil }
        let model = BrowserMigrationWizardModel()
        model.pickedSource = .arc

        model.start()

        XCTAssertFalse(model.isConfirmingRerun)
    }
}

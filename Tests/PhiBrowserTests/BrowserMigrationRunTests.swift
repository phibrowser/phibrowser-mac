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

    /// A root the user left empty, and one holding nothing but a folder. The
    /// store counts bookmarks rather than nodes, so neither had anything to
    /// lose — which is what tells an empty Space from a dropped write.
    private func emptyTree() -> ArcDataParserTool.Bookmark {
        ArcDataParserTool.Bookmark(guid: "root", title: "Space", url: nil, isFolder: true)
    }

    private func folderOnlyTree() -> ArcDataParserTool.Bookmark {
        let root = emptyTree()
        root.children = [ArcDataParserTool.Bookmark(
            guid: "folder", title: "Reading", url: nil, isFolder: true)]
        return root
    }

    /// A bookmark one level down, so the source count is a walk of the tree
    /// rather than a look at its top level.
    private func nestedTree() -> ArcDataParserTool.Bookmark {
        let root = folderOnlyTree()
        root.children[0].children = [ArcDataParserTool.Bookmark(
            guid: "leaf", title: "Example", url: "https://example.com", isFolder: false)]
        return root
    }

    private func space(
        _ id: String, _ name: String, profileKey: String, bookmarks: Bool = true
    ) -> BrowserMigrationSourceSpace {
        space(id, name, profileKey: profileKey, root: bookmarks ? tree() : nil)
    }

    private func space(
        _ id: String, _ name: String, profileKey: String,
        root: ArcDataParserTool.Bookmark?, icon: BrowserMigrationSourceIcon? = nil
    ) -> BrowserMigrationSourceSpace {
        BrowserMigrationSourceSpace(
            id: id, name: name, colorHex: "#112233", icon: icon, profileKey: profileKey,
            bookmarkRoot: root)
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

    /// Two profiles whose Spaces alternate in the source's order — the shape
    /// the run has to keep rather than regroup by Profile — with the first
    /// Space belonging to the second Profile.
    private func interleavedPlan() -> BrowserMigrationPlan {
        let source = BrowserMigrationSource(
            profiles: [
                BrowserMigrationSourceProfile(key: "Default", displayName: "Personal"),
                BrowserMigrationSourceProfile(key: "Profile 1", displayName: "Work"),
            ],
            defaultProfileKey: "Default",
            spaces: [
                space("s-research", "Research", profileKey: "Profile 1"),
                space("s-home", "Home", profileKey: "Default"),
                space("s-side", "Side Projects", profileKey: "Default"),
            ])
        return BrowserMigrationPlanner.plan(
            source: source,
            existingProfileDisplayNames: [],
            pinnedTabScope: .profile,
            selection: .all(in: source),
            operationID: operationID)
    }

    /// One Space with an Arc icon that lands on a Phi icon — a name whose
    /// table row is a Phi icon needs no emoji catalog — so the fold has an
    /// icon other than the default to carry.
    private func planWithIcon() -> BrowserMigrationPlan {
        let source = BrowserMigrationSource(
            profiles: [BrowserMigrationSourceProfile(key: "Default", displayName: "Personal")],
            defaultProfileKey: "Default",
            spaces: [space("s-home", "Home", profileKey: "Default", root: tree(),
                           icon: .arcNamed("notifications"))])
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

    /// Arc's request — history, cookies and extensions — which every
    /// Arc-shaped fixture here takes.
    private static let arcRequest: Set<ImportDataType> = [.history, .cookies, .extensions]

    /// The fold, over Arc's request unless a case says otherwise. The real
    /// fold has no such default: what a run's source was asked for is the
    /// caller's to state.
    private func folded(
        plan: BrowserMigrationPlan,
        outcomes: BrowserMigrationOutcomes,
        requestedDataTypes: Set<ImportDataType> = arcRequest
    ) -> BrowserMigrationReport {
        BrowserMigrationReport
            .folded(plan: plan, outcomes: outcomes, requestedDataTypes: requestedDataTypes)
    }

    // MARK: - Structure

    func testTheReportListsProfilesAndTheirSpacesInPlanOrder() {
        let report = folded(plan: plan(), outcomes: fullOutcomes())

        XCTAssertEqual(report.profiles.map(\.displayName), ["Personal", "Work"])
        XCTAssertEqual(report.profiles[0].spaces.map(\.name), ["Home", "Side Projects"])
        XCTAssertEqual(report.profiles[1].spaces.map(\.name), ["Work"])
    }

    func testEverythingThatLandedIsReportedCreated() {
        let report = folded(plan: plan(), outcomes: fullOutcomes())

        XCTAssertTrue(report.profiles.allSatisfy(\.created))
        XCTAssertTrue(report.profiles.flatMap(\.spaces).allSatisfy(\.created))
    }

    // MARK: - Space icon

    /// The plan's icon, carried through the fold the way the theme is, so the
    /// report row can be checked against the preview row — and against the
    /// strip — for the icon as well as the swatch.
    func testASpaceRowCarriesThePlansIcon() {
        let plan = planWithIcon()

        let report = folded(
            plan: plan,
            outcomes: outcomes(profiles: ["Default": "Profile 2"], spaces: ["s-home": "id-home"]))

        XCTAssertEqual(report.profiles[0].spaces[0].iconName, plan.profiles[0].spaces[0].iconName)
        XCTAssertEqual(report.profiles[0].spaces[0].iconName, "phi:phi-icon-bell")
    }

    // MARK: - Failures

    func testAFailedUnitIsReportedNotCreatedAndTheRestStillLand() {
        let report = folded(
            plan: plan(),
            outcomes: outcomes(
                profiles: ["Default": "Profile 2", "Profile 1": "Profile 3"],
                spaces: ["s-home": "id-home", "s-work": "id-work"]))

        XCTAssertEqual(report.profiles[0].spaces.map(\.created), [true, false])
        XCTAssertTrue(report.profiles[1].spaces[0].created)
    }

    func testAProfileThatFailedReportsItsSpacesNotCreatedToo() {
        let report = folded(
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
        outcomes.spaceBookmarkCounts = ["s-home": 4, "s-side": 3, "s-work": 2]

        let report = folded(plan: plan(), outcomes: outcomes)

        XCTAssertEqual(report.profiles[0].spaces.map(\.bookmarks), [.written(4), .written(3)])
        XCTAssertEqual(report.profiles[1].spaces[0].bookmarks, .written(2))
    }

    // MARK: - The two ways a Space ends up with no bookmarks

    /// One profile and one Space, whose source tree is whatever the case is
    /// about. Everything asked for lands except the bookmark count, which each
    /// case supplies.
    private func planWithTree(_ root: ArcDataParserTool.Bookmark?) -> BrowserMigrationPlan {
        let source = BrowserMigrationSource(
            profiles: [BrowserMigrationSourceProfile(key: "Default", displayName: "Personal")],
            defaultProfileKey: "Default",
            spaces: [space("s-home", "Home", profileKey: "Default", root: root)])
        return BrowserMigrationPlanner.plan(
            source: source,
            existingProfileDisplayNames: [],
            pinnedTabScope: .profile,
            selection: .all(in: source),
            operationID: operationID)
    }

    private func oneSpaceOutcomes(bookmarks: Int) -> BrowserMigrationOutcomes {
        var landed = outcomes(
            profiles: ["Default": "Profile 2"], spaces: ["s-home": "id-home"])
        landed.spaceBookmarkCounts = ["s-home": bookmarks]
        landed.profileExtensionCounts = ["Default": 0]
        return landed
    }

    /// The source Space genuinely had none, so nothing was lost and the report
    /// promotes nothing.
    func testASpaceWhoseSourceHadNoBookmarksSaysSoAndIsNotPromoted() {
        let report = folded(
            plan: planWithTree(emptyTree()), outcomes: oneSpaceOutcomes(bookmarks: 0))

        XCTAssertEqual(report.profiles[0].spaces[0].bookmarks, .noneInSource)
        XCTAssertEqual(report.problems, [])
    }

    /// A folder is not a bookmark — the count the store returns leaves folders
    /// out — so a Space holding nothing else had none to lose either.
    func testASourceTreeOfFoldersAloneCountsAsHavingHadNoBookmarks() {
        let report = folded(
            plan: planWithTree(folderOnlyTree()), outcomes: oneSpaceOutcomes(bookmarks: 0))

        XCTAssertEqual(report.profiles[0].spaces[0].bookmarks, .noneInSource)
    }

    /// The other zero: the source carried bookmarks and none of them landed.
    /// This is the visible symptom of the inherited staged-root defect, and it
    /// is promoted where the empty Space above is not.
    func testASpaceWhoseBookmarksAllVanishedIsWordedApartAndPromoted() {
        let report = folded(
            plan: planWithTree(nestedTree()), outcomes: oneSpaceOutcomes(bookmarks: 0))

        XCTAssertEqual(report.profiles[0].spaces[0].bookmarks, .noneSaved)
        XCTAssertEqual(
            report.problems, [.bookmarksNoneSaved(profile: "Personal", space: "Home")])
    }

    /// The outcome comes from the write, not from the import completion signal
    /// that reports success unconditionally — so a Space that landed but whose
    /// tree did not is reported as what it is.
    func testASpaceWhoseBookmarksDidNotPersistSaysSo() {
        var outcomes = fullOutcomes()
        outcomes.spaceBookmarkCounts = ["s-home": 3, "s-work": 1]

        let report = folded(plan: plan(), outcomes: outcomes)

        XCTAssertEqual(report.profiles[0].spaces.map(\.bookmarks), [.written(3), .failed])
        XCTAssertTrue(report.profiles[0].spaces.allSatisfy(\.created))
        // The Space that lost its Bookmarks leaves the rest of the run alone.
        XCTAssertEqual(report.profiles[1].spaces[0].bookmarks, .written(1))
    }

    func testASpaceThatWasNeverCreatedAttemptsNoBookmarks() {
        let report = folded(
            plan: plan(), outcomes: outcomes(profiles: ["Default": "Profile 2"]))

        XCTAssertEqual(
            report.profiles[0].spaces.map(\.bookmarks), [.notAttempted, .notAttempted])
    }

    /// Distinct from a failed write: nothing was to be written in the first
    /// place, so the report must not imply anything was lost.
    func testASpaceWithNoSourceTreeAttemptsNoBookmarks() {
        let report = folded(
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

        let report = folded(plan: plan(), outcomes: outcomes)

        XCTAssertEqual(report.profiles[0].browserData, .requested(extensions: 7))
        XCTAssertEqual(report.profiles[1].browserData, .requested(extensions: 0))
    }

    func testAProfileWhoseDataImportFailedSaysSoAndTheNextOneStillLands() {
        var outcomes = fullOutcomes()
        outcomes.profileExtensionCounts = ["Profile 1": 2]

        let report = folded(plan: plan(), outcomes: outcomes)

        XCTAssertEqual(report.profiles[0].browserData, .failed)
        XCTAssertTrue(report.profiles[0].created)
        XCTAssertEqual(report.profiles[1].browserData, .requested(extensions: 2))
    }

    /// Distinct from a failed import: there was no Profile to import into, so
    /// the report must not imply anything was lost.
    func testAProfileThatWasNeverCreatedAttemptsNoDataImport() {
        let report = folded(
            plan: plan(), outcomes: outcomes(profiles: ["Profile 1": "Profile 3"]))

        XCTAssertEqual(report.profiles[0].browserData, .notAttempted)
        XCTAssertEqual(report.profiles[1].browserData, .failed)
    }

    // MARK: - What a Zen-shaped row answers for

    /// Two Profiles derived from one Firefox profile — the shape Zen's
    /// container mapping produces.
    private func zenShapedPlan() -> BrowserMigrationPlan {
        let source = BrowserMigrationSource(
            profiles: [
                BrowserMigrationSourceProfile(
                    key: "fx#0", displayName: "Zen", sourceDirectory: "fx"),
                BrowserMigrationSourceProfile(
                    key: "fx#1", displayName: "Personal", sourceDirectory: "fx"),
            ],
            defaultProfileKey: "fx#0",
            spaces: [
                space("s-home", "Home", profileKey: "fx#0"),
                space("s-work", "Work", profileKey: "fx#1"),
            ])
        return BrowserMigrationPlanner.plan(
            source: source,
            existingProfileDisplayNames: [],
            pinnedTabScope: .profile,
            selection: .all(in: source),
            operationID: operationID)
    }

    /// Zen's request today: history alone.
    private static let zenRequest: Set<ImportDataType> = [.history]

    /// Every Space and its tree landed; whether the history imports did is
    /// the case's to say.
    private func zenOutcomes(importsFinished: Bool = true) -> BrowserMigrationOutcomes {
        var landed = outcomes(
            profiles: ["fx#0": "Profile 2", "fx#1": "Profile 3"],
            spaces: ["s-home": "id-home", "s-work": "id-work"])
        landed.spaceBookmarkCounts = ["s-home": 1, "s-work": 1]
        if importsFinished {
            landed.profileExtensionCounts = ["fx#0": 0, "fx#1": 0]
        }
        return landed
    }

    /// History landed on both rows, and the report carries the request the
    /// rows answer for — history alone — so nothing else is on them.
    func testAZenProfileRowAnswersForHistoryAlone() {
        let report = folded(
            plan: zenShapedPlan(), outcomes: zenOutcomes(), requestedDataTypes: Self.zenRequest)

        XCTAssertEqual(
            report.profiles.map(\.browserData),
            [.requested(extensions: 0), .requested(extensions: 0)])
        XCTAssertEqual(report.requestedDataTypes, [.history])
        XCTAssertEqual(report.problems, [])
    }

    /// A failed history import is the same promoted failure it is for Arc,
    /// against the same request.
    func testAZenProfileWhoseHistoryImportFailedIsPromotedForHistoryAlone() {
        let report = folded(
            plan: zenShapedPlan(), outcomes: zenOutcomes(importsFinished: false),
            requestedDataTypes: Self.zenRequest)

        XCTAssertEqual(report.profiles.map(\.browserData), [.failed, .failed])
        XCTAssertEqual(report.requestedDataTypes, Self.zenRequest)
        XCTAssertEqual(report.problems, [
            .browserDataFailed(profile: "Zen"),
            .browserDataFailed(profile: "Personal"),
        ])
    }

    /// An Arc row answers for all three, as it did.
    func testAnArcRowAnswersForHistoryCookiesAndExtensions() {
        let report = folded(plan: plan(), outcomes: fullOutcomes())

        XCTAssertEqual(report.requestedDataTypes, [.history, .cookies, .extensions])
    }

    // MARK: - What the source-level note counts

    /// Two profiles the plan skipped for having no Spaces, one of them with
    /// pinned entries — a Zen container no Space is set to keeps its
    /// Essentials — and one with none: the report counts what went nowhere.
    func testTheReportCountsThePinnedEntriesLeftBehindWithTheirProfiles() {
        let source = BrowserMigrationSource(
            profiles: [
                BrowserMigrationSourceProfile(key: "Default", displayName: "Personal"),
                BrowserMigrationSourceProfile(key: "Profile 1", displayName: "Work"),
                BrowserMigrationSourceProfile(key: "Profile 2", displayName: "Shopping"),
            ],
            defaultProfileKey: "Default",
            spaces: [space("s-home", "Home", profileKey: "Default")],
            pinnedGroups: [BrowserMigrationSourcePinnedGroup(
                profileKey: "Profile 1",
                entries: [
                    BrowserMigrationPinnedEntry(title: "Mail", url: "https://mail.example"),
                    BrowserMigrationPinnedEntry(title: "Docs", url: "https://docs.example"),
                ])])
        let plan = BrowserMigrationPlanner.plan(
            source: source,
            existingProfileDisplayNames: [],
            pinnedTabScope: .profile,
            selection: .all(in: source),
            operationID: operationID)

        let report = folded(
            plan: plan,
            outcomes: outcomes(profiles: ["Default": "Profile 2"], spaces: ["s-home": "id-home"]))

        XCTAssertEqual(plan.skippedProfiles.map(\.droppedPinnedEntries), [2, 0])
        XCTAssertEqual(report.droppedPinnedEntries, 2)
    }

    func testARunThatLeftNoPinnedEntryBehindCountsNone() {
        let report = folded(plan: plan(), outcomes: fullOutcomes())

        XCTAssertEqual(report.droppedPinnedEntries, 0)
    }

    // MARK: - Pinned tabs

    func testAProfileReportsThePinnedTabsThatLanded() {
        let plan = planWithPinnedEntries(scope: .profile)
        var landed = pinnedEntryOutcomes()
        landed.pinnedTabGuids = Set(plan.profiles[0].pinnedTabs.map(\.guid))

        let report = folded(plan: plan, outcomes: landed)

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
        let report = folded(plan: plan, outcomes: landed)

        XCTAssertEqual(report.profiles[0].pinnedTabsWritten, 2)
        XCTAssertEqual(report.profiles[0].pinnedTabsPlanned, 2)
    }

    /// An entry the store refused — one whose URL it could not parse — is
    /// reported as missing rather than counted as though it had landed.
    func testAnEntryTheStoreRefusedIsReportedAsAShortfall() {
        let plan = planWithPinnedEntries(scope: .profile)
        var landed = pinnedEntryOutcomes()
        landed.pinnedTabGuids = [plan.profiles[0].pinnedTabs[0].guid]

        let report = folded(plan: plan, outcomes: landed)

        XCTAssertEqual(report.profiles[0].pinnedTabsWritten, 1)
        XCTAssertEqual(report.profiles[0].pinnedTabsPlanned, 2)
        // The rest of the run is untouched by it.
        XCTAssertTrue(report.profiles[0].spaces.allSatisfy(\.created))
    }

    /// Distinct from a shortfall: the source had nothing to pin, so the report
    /// must not imply anything was lost.
    func testAProfileWhoseSourceHadNoPinnedEntriesReportsNone() {
        let report = folded(plan: plan(), outcomes: fullOutcomes())

        XCTAssertTrue(report.profiles.allSatisfy { $0.pinnedTabsPlanned == 0 })
        XCTAssertTrue(report.profiles.allSatisfy { $0.pinnedTabsWritten == 0 })
    }

    // MARK: - The Space the report jumps to

    func testTheReportJumpsToTheFirstCreatedSpace() {
        let report = folded(plan: plan(), outcomes: fullOutcomes())

        XCTAssertEqual(report.firstCreatedSpace?.spaceID, "id-home")
        XCTAssertEqual(report.firstCreatedSpace?.name, "Home")
    }

    /// The source's first ticked Space that landed — the first the run
    /// creates — even when it belongs to the Profile the plan lists second.
    func testTheReportJumpsToTheSourcesFirstSpaceAcrossProfiles() {
        let report = folded(
            plan: interleavedPlan(),
            outcomes: outcomes(
                profiles: ["Default": "Profile 2", "Profile 1": "Profile 3"],
                spaces: ["s-research": "id-research", "s-home": "id-home", "s-side": "id-side"]))

        XCTAssertEqual(report.firstCreatedSpace?.spaceID, "id-research")
        XCTAssertEqual(report.firstCreatedSpace?.name, "Research")
    }

    func testTheFirstCreatedSpaceSkipsOneThatFailed() {
        let report = folded(
            plan: plan(),
            outcomes: outcomes(
                profiles: ["Default": "Profile 2", "Profile 1": "Profile 3"],
                spaces: ["s-side": "id-side", "s-work": "id-work"]))

        XCTAssertEqual(report.firstCreatedSpace?.spaceID, "id-side")
    }

    func testARunThatCreatedNoSpaceHasNoneToJumpTo() {
        let report = folded(
            plan: plan(), outcomes: outcomes(profiles: ["Default": "Profile 2"]))

        XCTAssertNil(report.firstCreatedSpace)
    }

    // MARK: - What the report promotes

    /// Two profiles between them producing every promoted kind at once: the
    /// second was never created, and the first kept a Space that lost its
    /// bookmarks, one that never had any, one whose write failed, one that was
    /// never created, and a pinned set only half of which landed.
    private func planWithEveryFailure() -> BrowserMigrationPlan {
        let source = BrowserMigrationSource(
            profiles: [
                BrowserMigrationSourceProfile(key: "Default", displayName: "Personal"),
                BrowserMigrationSourceProfile(key: "Profile 1", displayName: "Work"),
            ],
            defaultProfileKey: "Default",
            spaces: [
                space("s-good", "Good", profileKey: "Default", root: tree()),
                space("s-lost", "Lost", profileKey: "Default", root: tree()),
                space("s-empty", "Empty", profileKey: "Default", root: emptyTree()),
                space("s-broken", "Broken", profileKey: "Default", root: tree()),
                space("s-dead", "Dead", profileKey: "Default", root: tree()),
                space("s-work", "Work Space", profileKey: "Profile 1", root: tree()),
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
            pinnedTabScope: .profile,
            selection: .all(in: source),
            operationID: operationID)
    }

    func testEveryPromotedKindAppearsAndNothingElseDoes() {
        let plan = planWithEveryFailure()
        var landed = outcomes(
            profiles: ["Default": "Profile 2"],
            spaces: [
                "s-good": "id-good", "s-lost": "id-lost",
                "s-empty": "id-empty", "s-broken": "id-broken",
            ])
        // "s-broken" leaves no count at all, which is how a failed write is
        // recorded; "s-lost" wrote nothing out of a tree that carried one.
        landed.spaceBookmarkCounts = ["s-good": 5, "s-lost": 0, "s-empty": 0]
        landed.profileExtensionCounts = ["Default": 3]
        landed.pinnedTabGuids = [plan.profiles[0].pinnedTabs[0].guid]

        let report = folded(plan: plan, outcomes: landed)

        XCTAssertEqual(report.problems, [
            .pinnedTabsIncomplete(profile: "Personal", written: 1, planned: 2),
            .bookmarksNoneSaved(profile: "Personal", space: "Lost"),
            .bookmarksFailed(profile: "Personal", space: "Broken"),
            .spaceNotCreated(profile: "Personal", space: "Dead"),
            .profileNotCreated(profile: "Work"),
            .spaceNotCreated(profile: "Work", space: "Work Space"),
        ])
    }

    func testARunWhereEverythingLandedPromotesNothing() {
        var landed = fullOutcomes()
        landed.spaceBookmarkCounts = ["s-home": 4, "s-side": 3, "s-work": 2]
        landed.profileExtensionCounts = ["Default": 7, "Profile 1": 0]

        let report = folded(plan: plan(), outcomes: landed)

        XCTAssertEqual(report.problems, [])
    }

    /// The one failure the reader can otherwise finish without seeing. Both
    /// Profiles and every Space were created, so the summary counts them and
    /// says nothing is wrong; with the detail rows collapsed by default, an
    /// unpromoted import failure would leave the run looking clean while none
    /// of the Profile's history, cookies or extensions came across. `requested`
    /// is the hedge that stays unpromoted; `failed` is a confirmed failure.
    func testAFailedDataImportIsPromotedEvenWhenItIsTheOnlyFailure() {
        var landed = fullOutcomes()
        landed.spaceBookmarkCounts = ["s-home": 4, "s-side": 3, "s-work": 2]
        landed.profileExtensionCounts = ["Default": 7]

        let report = folded(plan: plan(), outcomes: landed)

        XCTAssertEqual(report.profiles[1].browserData, .failed)
        XCTAssertEqual(report.problems, [.browserDataFailed(profile: "Work")])
        // The tick and the promotion now answer together: every way a Profile
        // row loses its tick is a problem the count reaches.
        XCTAssertFalse(report.profiles[1].landedCleanly)
        XCTAssertTrue(report.profiles[0].landedCleanly)
    }

    /// Two independent failures of one existing Profile, both reported: a
    /// refused import says nothing about whether the pinned entries landed.
    func testAFailedDataImportAndAPinnedShortfallAreBothPromoted() {
        let plan = planWithPinnedEntries(scope: .profile)
        var landed = pinnedEntryOutcomes()
        landed.spaceBookmarkCounts = ["s-home": 1, "s-side": 1]
        // No extension count for this Profile, which is how the fold hears
        // that its import failed. Spelled out because the absence is the
        // fixture: every sibling test sets a count here to say it succeeded,
        // and one that quietly gained one would gut this case rather than
        // fail it.
        landed.profileExtensionCounts = [:]
        landed.pinnedTabGuids = [plan.profiles[0].pinnedTabs[0].guid]

        let report = folded(plan: plan, outcomes: landed)

        XCTAssertEqual(report.profiles[0].browserData, .failed)
        XCTAssertEqual(report.problems, [
            .browserDataFailed(profile: "Personal"),
            .pinnedTabsIncomplete(profile: "Personal", written: 1, planned: 2),
        ])
    }

    /// Both counts, because "some of them" is the whole point of the row: a
    /// bare "3 couldn't be added" says nothing about how much was asked for.
    func testAPartlyLandedPinnedSetIsPromotedWithBothCounts() {
        let plan = planWithPinnedEntries(scope: .profile)
        var landed = pinnedEntryOutcomes()
        landed.spaceBookmarkCounts = ["s-home": 1, "s-side": 1]
        landed.profileExtensionCounts = ["Default": 0]
        landed.pinnedTabGuids = [plan.profiles[0].pinnedTabs[0].guid]

        let report = folded(plan: plan, outcomes: landed)

        XCTAssertEqual(
            report.problems,
            [.pinnedTabsIncomplete(profile: "Personal", written: 1, planned: 2)])
    }

    /// A Profile that was never created is one problem, not two: nothing was
    /// written to it because there was nothing to write to, which its own row
    /// already says.
    func testAProfileThatWasNeverCreatedDoesNotAlsoPromoteItsPinnedShortfall() {
        let report = folded(
            plan: planWithPinnedEntries(scope: .profile), outcomes: outcomes())

        XCTAssertEqual(report.problems, [
            .profileNotCreated(profile: "Personal"),
            .spaceNotCreated(profile: "Personal", space: "Home"),
            .spaceNotCreated(profile: "Personal", space: "Side Projects"),
        ])
    }

    // MARK: - What the summary counts

    func testTheSummaryCountsOnlyWhatWasCreated() {
        let report = folded(
            plan: plan(),
            outcomes: outcomes(
                profiles: ["Default": "Profile 2"],
                spaces: ["s-home": "id-home", "s-side": "id-side"]))

        XCTAssertEqual(report.createdProfileCount, 1)
        XCTAssertEqual(report.createdSpaceCount, 2)
    }

    func testARunThatCreatedNothingCountsNothing() {
        let report = folded(plan: plan(), outcomes: outcomes())

        XCTAssertEqual(report.createdProfileCount, 0)
        XCTAssertEqual(report.createdSpaceCount, 0)
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

    // MARK: - The unit list the progress publishes

    /// The window draws its checklist off this list rather than rebuilding it
    /// from the plan, so the order and the kinds are the run's own: every
    /// Profile first, so a Space always has its Profile by the time its unit
    /// runs, then the Spaces in the source's own order across Profiles.
    @MainActor
    func testTheProgressPublishesEveryProfileThenEverySpaceInSourceOrder() {
        let progress = BrowserMigrationRunner.progress(at: 0, of: interleavedPlan())

        XCTAssertEqual(
            progress.units.map(\.name),
            ["Personal", "Work", "Research", "Home", "Side Projects"])
        XCTAssertEqual(progress.units.map(\.isSpace), [false, false, true, true, true])
        XCTAssertEqual(progress.currentUnit.name, "Personal")
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

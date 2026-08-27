// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// The planner is the whole of the Migration design that can be tested without
/// a running browser: every mapping decision lands here, so these cases are the
/// specification of what a run creates.
final class BrowserMigrationPlannerTests: XCTestCase {

    private let operationID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!

    // MARK: - Fixture builders

    private func profile(
        _ key: String,
        _ displayName: String,
        pinsUnavailable: BrowserMigrationPinsUnavailableReason? = nil
    ) -> BrowserMigrationSourceProfile {
        BrowserMigrationSourceProfile(
            key: key, displayName: displayName, pinsUnavailable: pinsUnavailable)
    }

    private func pinnedGroup(
        _ profileKey: String?, _ entries: [(String, String)]
    ) -> BrowserMigrationSourcePinnedGroup {
        BrowserMigrationSourcePinnedGroup(
            profileKey: profileKey,
            entries: entries.map { BrowserMigrationPinnedEntry(title: $0.0, url: $0.1) })
    }

    private func space(
        _ id: String,
        _ name: String,
        profileKey: String?,
        colorHex: String = "#112233",
        bookmarks: [String] = []
    ) -> BrowserMigrationSourceSpace {
        let root = ArcDataParserTool.Bookmark(
            guid: id, title: name, url: nil, isFolder: true)
        root.children = bookmarks.map {
            ArcDataParserTool.Bookmark(
                guid: "\(id)-\($0)", title: $0, url: "https://\($0)", isFolder: false)
        }
        return BrowserMigrationSourceSpace(
            id: id, name: name, colorHex: colorHex, profileKey: profileKey, bookmarkRoot: root)
    }

    private func source(
        profiles: [BrowserMigrationSourceProfile],
        spaces: [BrowserMigrationSourceSpace],
        pinnedGroups: [BrowserMigrationSourcePinnedGroup] = []
    ) -> BrowserMigrationSource {
        BrowserMigrationSource(
            profiles: profiles,
            defaultProfileKey: "Default",
            spaces: spaces,
            pinnedGroups: pinnedGroups)
    }

    private func plan(
        _ source: BrowserMigrationSource,
        existing: [String] = [],
        scope: PinnedTabScope = .profile,
        selection: BrowserMigrationSelection? = nil
    ) -> BrowserMigrationPlan {
        BrowserMigrationPlanner.plan(
            source: source,
            existingProfileDisplayNames: existing,
            pinnedTabScope: scope,
            selection: selection ?? .all(in: source),
            operationID: operationID
        )
    }

    /// Two profiles, their Spaces interleaved in the source order, and an
    /// order that is not alphabetical.
    private func twoProfileSource() -> BrowserMigrationSource {
        source(
            profiles: [profile("Default", "Work"), profile("Profile 1", "Personal")],
            spaces: [
                space("s-zebra", "Zebra", profileKey: "Default", colorHex: "#ff2d2d"),
                space("s-home", "Home", profileKey: "Profile 1"),
                space("s-apple", "Apple", profileKey: "Default", colorHex: "#3cd63c"),
            ]
        )
    }

    // MARK: - Profiles and Spaces

    func testSpacesKeepSourceOrderWithTheirColourAndTheDefaultIcon() {
        let result = plan(twoProfileSource())

        XCTAssertEqual(result.profiles.map(\.sourceProfileKey), ["Default", "Profile 1"])
        XCTAssertEqual(result.profiles.map(\.displayName), ["Work", "Personal"])
        XCTAssertEqual(result.profiles[0].spaces.map(\.name), ["Zebra", "Apple"])
        XCTAssertEqual(result.profiles[0].spaces.map(\.themeID), ["coral", "mint"])
        XCTAssertEqual(
            result.profiles[0].spaces.map(\.colorHex),
            ["coral", "mint"].map(BrowserMigrationSpaceTheme.overlayHex(ofThemeID:)))
        XCTAssertEqual(result.profiles[1].spaces.map(\.sourceSpaceID), ["s-home"])
        XCTAssertEqual(
            Set(result.profiles.flatMap(\.spaces).map(\.iconName)),
            [BrowserMigrationPlanner.spaceIconName])
        XCTAssertTrue(result.profiles.flatMap(\.spaces).allSatisfy { !$0.boundToDefaultProfile })
        XCTAssertTrue(result.skippedProfiles.isEmpty)
    }

    func testEmptyDisplayNameFallsBackToTheDirectoryBasename() {
        let result = plan(source(
            profiles: [profile("Profile 3", "   ")],
            spaces: [space("s1", "One", profileKey: "Profile 3")]
        ))

        XCTAssertEqual(result.profiles.map(\.displayName), ["Profile 3"])
    }

    func testCollidingDisplayNameGetsANumericSuffix() {
        let result = plan(
            source(
                profiles: [profile("Default", "Work"), profile("Profile 1", "Work")],
                spaces: [
                    space("s1", "One", profileKey: "Default"),
                    space("s2", "Two", profileKey: "Profile 1"),
                ]
            ),
            // Profile creation compares display names case-insensitively, so
            // the planner has to as well or it plans a name that is rejected.
            existing: ["work", "Personal"]
        )

        XCTAssertEqual(result.profiles.map(\.displayName), ["Work 2", "Work 3"])
    }

    func testProfileWithNoSpacesIsSkippedWithItsReason() {
        let result = plan(source(
            profiles: [profile("Default", "Work"), profile("Profile 1", "Abandoned")],
            spaces: [space("s1", "One", profileKey: "Default")]
        ))

        XCTAssertEqual(result.profiles.map(\.sourceProfileKey), ["Default"])
        XCTAssertEqual(result.skippedProfiles, [
            BrowserMigrationSkippedProfile(
                sourceProfileKey: "Profile 1", displayName: "Abandoned", reason: .noSpaces),
        ])
    }

    func testSpaceWithAnEmptyBookmarkTreeStillPlansThatSpace() {
        let full = space("s1", "Full", profileKey: "Default", bookmarks: ["a", "b"])
        let empty = space("s2", "Empty", profileKey: "Default")
        let result = plan(source(profiles: [profile("Default", "Work")], spaces: [full, empty]))

        XCTAssertEqual(result.profiles[0].spaces.map(\.name), ["Full", "Empty"])
        XCTAssertEqual(result.profiles[0].spaces[0].bookmarkRoot?.children.count, 2)
        XCTAssertEqual(result.profiles[0].spaces[1].bookmarkRoot?.children.count, 0)
    }

    /// A source whose profile cache is unreadable must cost display names, not
    /// Spaces — including the default profile the unreadable records fall back
    /// to, which nothing would otherwise put in the plan.
    func testProfileTheSourceCacheNeverListedStillGetsItsSpaces() {
        let result = plan(source(
            profiles: [],
            spaces: [
                space("s1", "One", profileKey: "Profile 7"),
                space("s2", "Two", profileKey: nil),
            ]
        ))

        XCTAssertEqual(result.profiles.map(\.sourceProfileKey), ["Profile 7", "Default"])
        XCTAssertEqual(result.profiles.map(\.displayName), ["Profile 7", "Default"])
        XCTAssertEqual(result.profiles[0].spaces.map(\.boundToDefaultProfile), [false])
        XCTAssertEqual(result.profiles[1].spaces.map(\.boundToDefaultProfile), [true])
    }

    // MARK: - Tick rules

    func testUntickingTheLastSpaceOfAProfileUnticksTheProfile() {
        let model = twoProfileSource()
        let selection = BrowserMigrationSelection.all(in: model)
            .setting(spaceID: "s-home", ticked: false, in: model)

        XCTAssertFalse(selection.isTicked(profileKey: "Profile 1", in: model))
        XCTAssertEqual(
            plan(model, selection: selection).profiles.map(\.sourceProfileKey), ["Default"])
    }

    func testUntickingOneSpaceRemovesOnlyThatSpace() {
        let model = twoProfileSource()
        let selection = BrowserMigrationSelection.all(in: model)
            .setting(spaceID: "s-zebra", ticked: false, in: model)
        let result = plan(model, selection: selection)

        XCTAssertEqual(result.profiles.map(\.sourceProfileKey), ["Default", "Profile 1"])
        XCTAssertEqual(result.profiles[0].spaces.map(\.sourceSpaceID), ["s-apple"])
        XCTAssertEqual(result.profiles[1].spaces.map(\.sourceSpaceID), ["s-home"])
    }

    func testUntickingAProfileUnticksAllOfItsSpacesAndTickingItBringsThemBack() {
        let model = twoProfileSource()
        let unticked = BrowserMigrationSelection.all(in: model)
            .setting(profileKey: "Default", ticked: false, in: model)

        XCTAssertEqual(plan(model, selection: unticked).profiles.map(\.sourceProfileKey),
                       ["Profile 1"])

        let reticked = unticked.setting(profileKey: "Default", ticked: true, in: model)
        XCTAssertEqual(plan(model, selection: reticked).profiles[0].spaces.map(\.sourceSpaceID),
                       ["s-zebra", "s-apple"])
    }

    // MARK: - Unresolvable profile

    private func orphanSource() -> BrowserMigrationSource {
        source(
            profiles: [profile("Default", "Work"), profile("Profile 1", "Personal")],
            spaces: [
                space("s-own", "Own", profileKey: "Default"),
                space("s-orphan", "Orphan", profileKey: nil),
                space("s-other", "Other", profileKey: "Profile 1"),
            ]
        )
    }

    func testSpaceWithAnUnresolvableProfileBindsToTheDefaultProfileAndIsFlagged() {
        let result = plan(orphanSource())

        XCTAssertEqual(result.profiles[0].spaces.map(\.sourceSpaceID), ["s-own", "s-orphan"])
        XCTAssertEqual(result.profiles[0].spaces.map(\.boundToDefaultProfile), [false, true])
        XCTAssertEqual(result.profiles[1].spaces.map(\.sourceSpaceID), ["s-other"])
    }

    func testUnresolvableProfileSpaceFollowsTheDefaultProfileAndCannotBeTickedAlone() {
        let model = orphanSource()

        let profileUnticked = BrowserMigrationSelection.all(in: model)
            .setting(profileKey: "Default", ticked: false, in: model)
        XCTAssertFalse(profileUnticked.isTicked(spaceID: "s-orphan"))
        XCTAssertEqual(
            plan(model, selection: profileUnticked).profiles.map(\.sourceProfileKey),
            ["Profile 1"])

        // It has no tick of its own in either direction.
        XCTAssertEqual(
            profileUnticked.setting(spaceID: "s-orphan", ticked: true, in: model),
            profileUnticked)
        let allTicked = BrowserMigrationSelection.all(in: model)
        XCTAssertEqual(
            allTicked.setting(spaceID: "s-orphan", ticked: false, in: model), allTicked)
    }

    /// Unticking the Profile takes the orphan with it, and re-ticking any one
    /// of the Profile's own Spaces has to bring it back: it has no control of
    /// its own, so leaving it off would strand it out of the plan for good.
    func testTickingASiblingSpaceBringsTheDefaultBoundSpaceBack() {
        let model = orphanSource()
        let selection = BrowserMigrationSelection.all(in: model)
            .setting(profileKey: "Default", ticked: false, in: model)
            .setting(spaceID: "s-own", ticked: true, in: model)

        XCTAssertTrue(selection.isTicked(spaceID: "s-orphan"))
        XCTAssertEqual(
            plan(model, selection: selection).profiles[0].spaces.map(\.sourceSpaceID),
            ["s-own", "s-orphan"])
    }

    // MARK: - Pinned tabs

    private func favouriteSource(
        pinsUnavailable: BrowserMigrationPinsUnavailableReason? = nil
    ) -> BrowserMigrationSource {
        source(
            profiles: [
                profile("Default", "Work", pinsUnavailable: pinsUnavailable),
                profile("Profile 1", "Personal"),
            ],
            spaces: [
                space("s1", "One", profileKey: "Default"),
                space("s2", "Two", profileKey: "Default"),
                space("s3", "Three", profileKey: "Profile 1"),
            ],
            pinnedGroups: [
                pinnedGroup("Default", [
                    ("Mail", "https://mail.example"), ("Docs", "https://docs.example"),
                ]),
                pinnedGroup("Profile 1", [("News", "https://news.example")]),
            ]
        )
    }

    func testFavoritesFanOutToOneOwnerAtProfileScope() {
        let pins = plan(favouriteSource(), scope: .profile).profiles[0].pinnedTabs

        XCTAssertEqual(pins.map(\.title), ["Mail", "Docs"])
        XCTAssertEqual(pins.map(\.ownerProfileKey), ["Default", "Default"])
        XCTAssertEqual(pins.map(\.ownerSpaceID), ["s1", "s1"])
        XCTAssertEqual(Set(pins.map(\.lineageID)).count, 2)
    }

    func testFavoritesFanOutToOneOwnerPerSpaceAtSpaceScope() {
        let pins = plan(favouriteSource(), scope: .space).profiles[0].pinnedTabs

        XCTAssertEqual(pins.map(\.title), ["Mail", "Mail", "Docs", "Docs"])
        XCTAssertEqual(pins.map(\.ownerSpaceID), ["s1", "s2", "s1", "s2"])
        // Every copy of one Favorite shares one lineage, so a later widening of
        // the scope collapses them back into a single entry.
        XCTAssertEqual(pins[0].lineageID, pins[1].lineageID)
        XCTAssertEqual(pins[2].lineageID, pins[3].lineageID)
        XCTAssertNotEqual(pins[0].lineageID, pins[2].lineageID)
        XCTAssertEqual(Set(pins.map(\.guid)).count, 4)
    }

    func testFavoritesFanOutToOneOwnerAtAppScope() {
        let result = plan(favouriteSource(), scope: .app)

        XCTAssertEqual(result.pinnedTabScope, .app)
        XCTAssertEqual(result.profiles[0].pinnedTabs.map(\.title), ["Mail", "Docs"])
        XCTAssertEqual(result.profiles[0].pinnedTabs.map(\.ownerSpaceID), ["s1", "s1"])
        XCTAssertEqual(result.profiles[1].pinnedTabs.map(\.title), ["News"])
    }

    func testLineageIdentifiersAreUniqueAcrossProfiles() {
        let result = plan(favouriteSource(), scope: .space)
        let lineages = result.profiles.flatMap(\.pinnedTabs).map(\.lineageID)

        XCTAssertEqual(Set(lineages).count, 3)
    }

    func testPinnedEntriesWithAnUnresolvableProfileGoToTheDefaultProfile() {
        let result = plan(source(
            profiles: [profile("Default", "Work")],
            spaces: [space("s1", "One", profileKey: "Default")],
            pinnedGroups: [
                pinnedGroup("Default", [("Mail", "https://mail.example")]),
                pinnedGroup(nil, [("Orphan", "https://orphan.example")]),
            ]
        ))

        XCTAssertEqual(result.profiles[0].pinnedTabs.map(\.title), ["Mail", "Orphan"])
    }

    func testPinsUnavailablePlansNoPinnedEntriesAndCarriesTheMarker() {
        let result = plan(favouriteSource(pinsUnavailable: .noSourceWindow), scope: .space)

        XCTAssertEqual(result.profiles[0].pinsUnavailable, .noSourceWindow)
        XCTAssertTrue(result.profiles[0].pinnedTabs.isEmpty)
        // Only the profile that reported it is affected.
        XCTAssertNil(result.profiles[1].pinsUnavailable)
        XCTAssertEqual(result.profiles[1].pinnedTabs.map(\.title), ["News"])
    }

    // MARK: - Late-completion guard

    func testGenerationAcceptsOnlyTheStepRunningNow() {
        var generation = BrowserMigrationGeneration()
        let first = generation.advance()
        XCTAssertTrue(generation.accepts(first))

        let second = generation.advance()
        XCTAssertFalse(generation.accepts(first))
        XCTAssertTrue(generation.accepts(second))
        XCTAssertNotEqual(first, second)
    }

    // MARK: - Arc source adaptation

    func testArcMigrationSourceTranslatesProfilesSpacesAndFavorites() {
        let model = BrowserDataImporter.ArcMigrationSource(
            profiles: [
                .init(directory: "Default", name: "Work", email: nil),
                .init(directory: "Profile 1", name: "Personal", email: nil),
            ],
            sidebar: ArcSidebar(
                spaces: [
                    arcSpace("s1", "One", profile: .default),
                    arcSpace("s2", "Two", profile: .custom(directoryBasename: "Profile 1")),
                    arcSpace("s3", "Three", profile: .unknown),
                ],
                favorites: [
                    ArcFavorites(
                        profile: .default,
                        entries: [ArcFavorite(title: "Mail", url: "https://mail.example")]),
                    ArcFavorites(profile: .unknown, entries: []),
                ])
        ).migrationSource

        XCTAssertEqual(model.profiles.map(\.key), ["Default", "Profile 1"])
        XCTAssertEqual(model.defaultProfileKey, "Default")
        // A malformed profile record arrives as nil, which is what makes the
        // planner bind it to the default profile and flag it.
        XCTAssertEqual(model.spaces.map(\.profileKey), ["Default", "Profile 1", nil])
        XCTAssertEqual(model.spaces.map(\.colorHex), ["#123456", "#123456", "#123456"])
        XCTAssertEqual(model.pinnedGroups.map(\.profileKey), ["Default", nil])
        XCTAssertEqual(model.pinnedGroups[0].entries,
                       [BrowserMigrationPinnedEntry(title: "Mail", url: "https://mail.example")])
        XCTAssertTrue(model.pinnedGroups[1].entries.isEmpty)
    }

    private func arcSpace(
        _ id: String, _ title: String, profile: ArcSourceProfile
    ) -> ArcSpace {
        ArcSpace(
            id: id,
            title: title,
            profile: profile,
            colorHex: "#123456",
            root: ArcDataParserTool.Bookmark(guid: id, title: title, url: nil, isFolder: true))
    }

    // MARK: - Space theme

    /// Phi's Space colour vocabulary is eight built-in themes, so a source
    /// colour is snapped to the nearest hue rather than stored as-is. These
    /// pin which hue lands where.
    func testASourceColourSnapsToTheBuiltInThemeNearestInHue() {
        let expected: [(String, String)] = [
            ("#ff2d2d", "coral"),
            ("#ffcc33", "amber"),
            ("#3cd63c", "mint"),
            ("#33d6dd", "aqua"),
            ("#2f9dff", "mist"),
            ("#6f4dff", "iris"),
            ("#d94dff", "petal"),
        ]
        for (sourceHex, themeID) in expected {
            XCTAssertEqual(
                BrowserMigrationSpaceTheme.resolved(forSourceColorHex: sourceHex).themeID,
                themeID,
                "\(sourceHex) should snap to \(themeID)")
        }
    }

    /// An Arc Space with no theme is not a Space painted Phi's default blue:
    /// the absence has to survive to the planner, or the stand-in colour gets
    /// snapped to whatever hue it happens to have.
    func testASpaceWithNoThemeTakesTheDefaultThemeRatherThanASnappedStandIn() {
        let resolved = BrowserMigrationSpaceTheme.resolved(forSourceColorHex: nil)

        XCTAssertEqual(resolved.themeID, BrowserMigrationSpaceTheme.defaultThemeID)
        XCTAssertNotEqual(
            resolved.themeID,
            BrowserMigrationSpaceTheme.resolved(
                forSourceColorHex: LocalStore.defaultSpaceColorHex).themeID)
    }

    func testAColourTooCloseToNeutralTakesTheDefaultTheme() {
        for sourceHex in ["#808080", "#f2f2f0", "#0a0a0a", "#000000"] {
            XCTAssertEqual(
                BrowserMigrationSpaceTheme.resolved(forSourceColorHex: sourceHex).themeID,
                BrowserMigrationSpaceTheme.defaultThemeID,
                "\(sourceHex) names no hue and should take the default theme")
        }
    }

    /// The plan states what will exist: the colour of the theme it pins, never
    /// the source's own colour, which Phi has no way to show.
    func testAPlannedSpaceCarriesTheThemesColourNotTheSources() {
        let resolved = BrowserMigrationSpaceTheme.resolved(forSourceColorHex: "#ff2d2d")

        XCTAssertEqual(resolved.colorHex,
            BrowserMigrationSpaceTheme.overlayHex(ofThemeID: "coral"))
        XCTAssertNotEqual(resolved.colorHex, "#ff2d2d")
    }
}

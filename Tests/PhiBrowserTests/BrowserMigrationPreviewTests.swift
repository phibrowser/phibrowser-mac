// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// The wizard's preview is the plan: these cases pin what it shows for rows the
/// plan carries and for the ones it deliberately leaves out — an unticked
/// Profile, a skipped one — because those must stay on screen to be ticked back.
final class BrowserMigrationPreviewTests: XCTestCase {

    private let operationID = UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!

    // MARK: - Fixture builders

    private func space(
        _ id: String,
        _ name: String,
        profileKey: String?,
        colorHex: String = "#112233"
    ) -> BrowserMigrationSourceSpace {
        BrowserMigrationSourceSpace(
            id: id, name: name, colorHex: colorHex, profileKey: profileKey)
    }

    private func source(
        profiles: [(String, String)],
        spaces: [BrowserMigrationSourceSpace]
    ) -> BrowserMigrationSource {
        BrowserMigrationSource(
            profiles: profiles.map {
                BrowserMigrationSourceProfile(key: $0.0, displayName: $0.1)
            },
            defaultProfileKey: "Default",
            spaces: spaces)
    }

    private func rows(
        _ source: BrowserMigrationSource,
        existing: [String] = [],
        selection: BrowserMigrationSelection? = nil
    ) -> [BrowserMigrationPreviewProfileRow] {
        let plan = BrowserMigrationPlanner.plan(
            source: source,
            existingProfileDisplayNames: existing,
            pinnedTabScope: .profile,
            selection: selection ?? .all(in: source),
            operationID: operationID)
        return BrowserMigrationPreview.rows(source: source, plan: plan)
    }

    /// Two profiles whose Spaces interleave in the source order, so a preview
    /// that regrouped or re-sorted them would show.
    private func twoProfileSource() -> BrowserMigrationSource {
        source(
            profiles: [("Default", "Personal"), ("Profile 1", "Work")],
            spaces: [
                space("s-work", "Work", profileKey: "Profile 1"),
                space("s-home", "Home", profileKey: "Default", colorHex: "#ff2d2d"),
                space("s-side", "Side Projects", profileKey: "Profile 1"),
            ])
    }

    // MARK: - Structure

    func testProfilesAndSpacesComeOutInSourceOrder() {
        let rows = rows(twoProfileSource())

        XCTAssertEqual(rows.map(\.sourceProfileKey), ["Default", "Profile 1"])
        XCTAssertEqual(rows[0].spaces.map(\.sourceSpaceID), ["s-home"])
        XCTAssertEqual(rows[1].spaces.map(\.sourceSpaceID), ["s-work", "s-side"])
    }

    func testASpaceCarriesItsNameAndTickState() {
        let row = rows(twoProfileSource())[0].spaces[0]

        XCTAssertEqual(row.name, "Home")
        XCTAssertTrue(row.isTicked)
        XCTAssertFalse(row.boundToDefaultProfile)
    }

    /// The theme the run will pin, not the source's own colour: the row's
    /// swatch is drawn from it, and it is the only colour the preview can
    /// promise, because the run pins a theme rather than a hex.
    func testASpaceCarriesTheThemeThePlanResolved() {
        let source = twoProfileSource()
        let plan = BrowserMigrationPlanner.plan(
            source: source,
            existingProfileDisplayNames: [],
            pinnedTabScope: .profile,
            selection: .all(in: source),
            operationID: operationID)

        let row = BrowserMigrationPreview.rows(source: source, plan: plan)[0].spaces[0]

        XCTAssertEqual(row.themeID, plan.profiles[0].spaces[0].themeID)
        XCTAssertEqual(row.themeID, "coral")
    }

    /// An unticked Space is not in the plan, so its theme comes from the
    /// planner's own fallback — unticking must not appear to restyle it.
    func testUntickingASpaceDoesNotChangeItsTheme() {
        let source = twoProfileSource()
        let ticked = rows(source)[0].spaces[0]
        let unticked = rows(
            source,
            selection: BrowserMigrationSelection.all(in: source)
                .setting(spaceID: "s-home", ticked: false, in: source)
        )[0].spaces[0]

        XCTAssertTrue(ticked.isTicked)
        XCTAssertFalse(unticked.isTicked)
        XCTAssertEqual(unticked.themeID, ticked.themeID)
    }

    // MARK: - Names

    func testACollidingProfileNamePreviewsSuffixed() {
        let rows = rows(twoProfileSource(), existing: ["Work"])

        XCTAssertEqual(rows.map(\.displayName), ["Personal", "Work 2"])
    }

    func testAnEmptyProfileNamePreviewsAsItsDirectoryBasename() {
        let source = source(
            profiles: [("Profile 3", "  ")],
            spaces: [space("s-1", "Space", profileKey: "Profile 3")])

        XCTAssertEqual(rows(source).map(\.displayName), ["Profile 3"])
    }

    // MARK: - Ticks

    func testUntickingAProfileKeepsItsRowsAndItsName() {
        let source = twoProfileSource()
        let selection = BrowserMigrationSelection.all(in: source)
            .setting(profileKey: "Profile 1", ticked: false, in: source)

        let rows = rows(source, existing: ["Work"], selection: selection)

        // The Profile creates nothing, so it is not in the plan — but its row
        // and its Spaces stay on screen, unticked, or it could never come back.
        XCTAssertEqual(rows.map(\.sourceProfileKey), ["Default", "Profile 1"])
        XCTAssertEqual(rows[1].tick, .off)
        XCTAssertEqual(rows[1].spaces.map(\.isTicked), [false, false])
        // Not in the plan means no collision to resolve, so no suffix.
        XCTAssertEqual(rows[1].displayName, "Work")
    }

    func testUntickingOneSpaceLeavesItsSiblingsTicked() {
        let source = twoProfileSource()
        let selection = BrowserMigrationSelection.all(in: source)
            .setting(spaceID: "s-work", ticked: false, in: source)

        let rows = rows(source, selection: selection)

        // Some of its Spaces, not all: the box says so rather than reading as
        // a Profile that comes across whole.
        XCTAssertEqual(rows[1].tick, .mixed)
        XCTAssertEqual(rows[1].spaces.map(\.isTicked), [false, true])
    }

    func testAProfileWithEveryOneOfItsSpacesTickedIsFullyTicked() {
        let rows = rows(twoProfileSource())

        XCTAssertEqual(rows.map(\.tick), [.on, .on])
    }

    // MARK: - The rows a plan leaves out

    func testAProfileWithNoSpacesPreviewsAsSkipped() {
        let source = source(
            profiles: [("Default", "Personal"), ("Profile 1", "Empty")],
            spaces: [space("s-home", "Home", profileKey: "Default")])

        let rows = rows(source)

        XCTAssertEqual(rows[1].sourceProfileKey, "Profile 1")
        XCTAssertEqual(rows[1].displayName, "Empty")
        XCTAssertEqual(rows[1].skipReason, .noSpaces)
        XCTAssertEqual(rows[1].tick, .off)
        XCTAssertTrue(rows[1].spaces.isEmpty)
    }

    func testASpaceWithAnUnresolvableProfileSaysItUsesTheDefaultOne() {
        let source = source(
            profiles: [("Default", "Personal")],
            spaces: [
                space("s-home", "Home", profileKey: "Default"),
                space("s-orphan", "Orphan", profileKey: nil),
            ])

        let rows = rows(source)

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].sourceProfileKey, "Default")
        let orphan = rows[0].spaces[1]
        XCTAssertEqual(orphan.sourceSpaceID, "s-orphan")
        XCTAssertTrue(orphan.boundToDefaultProfile)
        XCTAssertTrue(orphan.isTicked)
    }

    func testUntickingTheDefaultProfileUnticksTheSpaceBoundToIt() {
        let source = source(
            profiles: [("Default", "Personal")],
            spaces: [
                space("s-home", "Home", profileKey: "Default"),
                space("s-orphan", "Orphan", profileKey: nil),
            ])
        let selection = BrowserMigrationSelection.all(in: source)
            .setting(profileKey: "Default", ticked: false, in: source)

        let rows = rows(source, selection: selection)

        XCTAssertEqual(rows[0].tick, .off)
        XCTAssertEqual(rows[0].spaces.map(\.isTicked), [false, false])
    }

    // MARK: - Nothing to migrate

    /// A source Phi read fine that still offers nothing. It is not the same
    /// state as a source that could not be read — that one produces no rows and
    /// never reaches the preview — and the wizard says a different thing about
    /// each.
    func testASourceWhoseProfilesAllCreateNothingHasNothingToMigrate() {
        let source = source(
            profiles: [("Default", "Personal"), ("Profile 1", "Work")],
            spaces: [])

        let rows = rows(source)

        XCTAssertEqual(rows.map(\.displayName), ["Personal", "Work"])
        XCTAssertTrue(BrowserMigrationPreview.hasNothingToMigrate(rows: rows))
    }

    /// Unticking everything empties the plan too, but there is still something
    /// to tick back — so it must not read as a source with nothing in it.
    func testUntickingEverythingIsNotTheSameAsHavingNothingToMigrate() {
        let source = twoProfileSource()
        let selection = BrowserMigrationSelection.all(in: source)
            .setting(profileKey: "Default", ticked: false, in: source)
            .setting(profileKey: "Profile 1", ticked: false, in: source)

        let rows = rows(source, selection: selection)

        XCTAssertEqual(rows.map(\.tick), [.off, .off])
        XCTAssertFalse(BrowserMigrationPreview.hasNothingToMigrate(rows: rows))
    }

    // MARK: - Sources

    /// Asserted over every source rather than the installed ones, which depend
    /// on what this machine happens to have.
    func testSourcesAreOfferedAlphabetically() {
        let names = BrowserMigrationSourceKind.allInDisplayOrder.map(\.displayName)

        XCTAssertEqual(names, names.sorted())
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertEqual(names.count, BrowserMigrationSourceKind.allCases.count)
    }

    /// Migration has no per-data-type toggles, so a source is always asked for
    /// everything it supports — except Arc's bookmarks, which Phi parses out of
    /// the sidebar itself and writes per Space.
    func testArcIsAskedForEveryDataTypeItSupportsButItsBookmarks() {
        let requested = Set(BrowserMigrationSourceKind.arc.migrationDataTypes)
        let supported = Set(ImportDataType.availableTypes(for: .arc).map(\.rawValue))

        XCTAssertEqual(
            requested, Set([ImportDataType.history, .cookies, .extensions].map(\.rawValue)))
        XCTAssertEqual(requested, supported.subtracting([ImportDataType.bookmarks.rawValue]))
    }
}

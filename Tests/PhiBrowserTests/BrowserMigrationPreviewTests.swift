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

    func testASpaceCarriesItsNameAndTheColourItWillGet() {
        let row = rows(twoProfileSource())[0].spaces[0]

        XCTAssertEqual(row.name, "Home")
        // The colour of the theme the run will pin, not the source's own —
        // the preview must not promise a colour Phi cannot produce.
        XCTAssertEqual(row.colorHex, BrowserMigrationSpaceTheme.overlayHex(ofThemeID: "coral"))
        XCTAssertTrue(row.isTicked)
        XCTAssertFalse(row.boundToDefaultProfile)
    }

    /// A row the user has unticked is not in the plan, so its colour comes
    /// from the fallback — which has to be the same colour, or unticking a
    /// Space would appear to change it.
    func testUntickingASpaceDoesNotChangeItsColour() {
        let source = twoProfileSource()
        let ticked = rows(source)[0].spaces[0]
        let unticked = rows(
            source,
            selection: BrowserMigrationSelection.all(in: source)
                .setting(spaceID: "s-home", ticked: false, in: source)
        )[0].spaces[0]

        XCTAssertTrue(ticked.isTicked)
        XCTAssertFalse(unticked.isTicked)
        XCTAssertEqual(unticked.colorHex, ticked.colorHex)
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
        XCTAssertEqual(rows[1].isTicked, false)
        XCTAssertEqual(rows[1].spaces.map(\.isTicked), [false, false])
        // Not in the plan means no collision to resolve, so no suffix.
        XCTAssertEqual(rows[1].displayName, "Work")
    }

    func testUntickingOneSpaceLeavesItsSiblingsTicked() {
        let source = twoProfileSource()
        let selection = BrowserMigrationSelection.all(in: source)
            .setting(spaceID: "s-work", ticked: false, in: source)

        let rows = rows(source, selection: selection)

        XCTAssertTrue(rows[1].isTicked)
        XCTAssertEqual(rows[1].spaces.map(\.isTicked), [false, true])
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
        XCTAssertFalse(rows[1].isTicked)
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

        XCTAssertFalse(rows[0].isTicked)
        XCTAssertEqual(rows[0].spaces.map(\.isTicked), [false, false])
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
}

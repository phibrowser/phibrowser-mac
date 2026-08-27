// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// The two parts of a run that can be pinned without a running browser: the
/// pure fold from a plan plus what the run produced into the report, and the
/// scoped construct that holds a Space under the import target lock.
final class BrowserMigrationRunTests: XCTestCase {

    private let operationID = UUID(uuidString: "00000000-0000-0000-0000-0000000000CC")!

    // MARK: - Fixture builders

    private func space(_ id: String, _ name: String, profileKey: String) -> BrowserMigrationSourceSpace {
        BrowserMigrationSourceSpace(
            id: id, name: name, colorHex: "#112233", profileKey: profileKey)
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
}

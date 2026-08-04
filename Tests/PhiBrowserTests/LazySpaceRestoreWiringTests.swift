// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// The lazy-restore wiring hangs three decisions off pure rules, pinned here
/// the way the classifier and the snapshot writer already are:
///
///   * whether a reopen arms the eager filter at all (`armedEagerWindowIds`)
///     — the switch, the framework probe, and the "parking nothing buys
///     nothing" floor;
///   * which parked window an activation of a Space materializes
///     (`parkedGhostWindowId(in:forSpaceId:)`) — including the deterministic
///     pick on a corrupt duplicate;
///   * where the coordinator's fallback mint may land
///     (`steeredFallbackMintSpaceId`) — the one resolution that CREATES a
///     window, which must not land on a Space whose window is parked.
///
/// What they cannot reach — that `activate`, `deleteSpace`, `changeProfile`
/// and the coordinator feed these rules their real state — rests on the
/// call-site comments, the same line `SlotsSnapshotPersistGateTests` draws.
final class LazySpaceRestoreWiringTests: XCTestCase {
    // MARK: - Arming (what the reopen sends over the bridge)

    private static func classification(
        eager: Set<Int>, ghosts: [Int: String]
    ) -> SpaceManager.RestoreWindowClassification {
        SpaceManager.RestoreWindowClassification(
            eagerWindowIds: eager, ghostSpaceIdsByWindowId: ghosts)
    }

    func testArmingRequiresTheSwitch() {
        XCTAssertNil(SpaceManager.armedEagerWindowIds(
            featureEnabled: false,
            bridgeSupportsLazyRestore: true,
            classification: Self.classification(eager: [1], ghosts: [2: "space-b"])
        ))
    }

    func testArmingRequiresTheSelectorFamily() {
        // An older framework cannot materialize or drop what this reopen
        // would park — so nothing may park.
        XCTAssertNil(SpaceManager.armedEagerWindowIds(
            featureEnabled: true,
            bridgeSupportsLazyRestore: false,
            classification: Self.classification(eager: [1], ghosts: [2: "space-b"])
        ))
    }

    func testArmingThatParksNothingStaysUnarmed() {
        // The eager set is a whitelist to the replay: a saved window outside
        // it parks. With nothing to park, arming buys nothing over the full
        // replay and only widens what a snapshot gap could fall through.
        XCTAssertNil(SpaceManager.armedEagerWindowIds(
            featureEnabled: true,
            bridgeSupportsLazyRestore: true,
            classification: Self.classification(eager: [1, 2], ghosts: [:])
        ))
    }

    func testArmedEagerSetIsSortedAscending() {
        XCTAssertEqual(
            SpaceManager.armedEagerWindowIds(
                featureEnabled: true,
                bridgeSupportsLazyRestore: true,
                classification: Self.classification(
                    eager: [55, 7, 102], ghosts: [9: "space-b"])
            ),
            [7, 55, 102].map { NSNumber(value: $0) }
        )
    }

    // MARK: - Which parked window an activation materializes

    func testNoParkedWindowMeansNoMaterialization() {
        XCTAssertNil(SpaceManager.parkedGhostWindowId(
            in: [:], forSpaceId: "space-a"))
        XCTAssertNil(SpaceManager.parkedGhostWindowId(
            in: [55: "space-b"], forSpaceId: "space-a"))
    }

    func testTheSpacesParkedWindowIsFound() {
        XCTAssertEqual(
            SpaceManager.parkedGhostWindowId(
                in: [55: "space-b", 7: "space-a"], forSpaceId: "space-b"),
            55
        )
    }

    func testCorruptDuplicateParkPicksTheLowestIdDeterministically() {
        // A Space maps 1:1 to a window, so two parked ids naming one Space is
        // damage — but the pick must still be the same every time, not
        // whatever a hash walk yields first. Lowest id is the project's one
        // deterministic ordering over snapshot windows.
        XCTAssertEqual(
            SpaceManager.parkedGhostWindowId(
                in: [102: "space-b", 55: "space-b", 7: "space-a"],
                forSpaceId: "space-b"),
            55
        )
    }

    // MARK: - Where the fallback mint may land

    private static let candidates: [(spaceId: String, profileId: String, isSwitchTarget: Bool)] = [
        (spaceId: "agent", profileId: "p1", isSwitchTarget: false),
        (spaceId: "ghosted", profileId: "p1", isSwitchTarget: true),
        (spaceId: "other-profile", profileId: "p2", isSwitchTarget: true),
        (spaceId: "clear", profileId: "p1", isSwitchTarget: true),
    ]

    func testMintOnANonGhostSpaceStandsUnchanged() {
        XCTAssertEqual(
            SpaceManager.steeredFallbackMintSpaceId(
                resolved: "clear",
                ghostSpaceIds: ["ghosted"],
                candidates: Self.candidates,
                profileId: "p1"),
            "clear"
        )
    }

    func testMintOnAGhostSpaceSteersToTheProfilesFirstClearSwitchTarget() {
        // "agent" is skipped (not a switch target), "other-profile" is
        // skipped (wrong profile) — strip order lands on "clear".
        XCTAssertEqual(
            SpaceManager.steeredFallbackMintSpaceId(
                resolved: "ghosted",
                ghostSpaceIds: ["ghosted"],
                candidates: Self.candidates,
                profileId: "p1"),
            "clear"
        )
    }

    func testMintWithAnEmptyProfileMaySteerAnywhereClear() {
        // A window with no profile constraint takes the first clear switch
        // target in strip order, whatever profile it belongs to.
        XCTAssertEqual(
            SpaceManager.steeredFallbackMintSpaceId(
                resolved: "ghosted",
                ghostSpaceIds: ["ghosted", "clear"],
                candidates: Self.candidates,
                profileId: ""),
            "other-profile"
        )
    }

    func testMintWithNoClearAlternativeKeepsTheGhostSpace() {
        // Every Space of the profile is parked (or unusable): the doubled
        // record is the lesser evil next to presenting the window as another
        // profile's Space, so the resolution stands and the caller logs it.
        XCTAssertEqual(
            SpaceManager.steeredFallbackMintSpaceId(
                resolved: "ghosted",
                ghostSpaceIds: ["ghosted", "clear"],
                candidates: Self.candidates,
                profileId: "p1"),
            "ghosted"
        )
    }
}

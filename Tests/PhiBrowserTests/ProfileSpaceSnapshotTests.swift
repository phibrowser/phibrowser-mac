// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

@MainActor
final class ProfileSpaceSnapshotTests: XCTestCase {
    func testDefaultProfileCountsEvenWithNoOpenWindowAndTheAgentFallbackIsExcluded() {
        let initial = PhiBrowserProfile(profileId: "Default", displayName: "Default",
                                        isLoaded: false, isInUse: false)
        let agent = PhiBrowserProfile(profileId: "agent-test", displayName: PhiPreferences.AgentSpaces.agentFallbackProfileName,
                                      isLoaded: true, isInUse: true)
        XCTAssertEqual(ProfileManager.userAssignableProfiles(in: [initial]), [initial])
        XCTAssertEqual(ProfileManager.userAssignableProfiles(in: [initial, agent]), [initial])
    }

    func testDefaultAndOrdinarySpacesCountAcrossProfiles() {
        let initial = space(LocalStore.defaultSpaceId)
        XCTAssertEqual(SpaceManager.userSpaceCountForAnalytics(in: [initial], hidden: []), 1)
        let work = space("work", profile: "Profile 1")
        XCTAssertEqual(SpaceManager.userSpaceCountForAnalytics(in: [initial, work], hidden: []), 2)
    }

    func testInternalAndHiddenSpacesDoNotIncreaseTheCount() {
        let temporary = space("agent", name: AgentSpaceManager.agentSpaceName(1),
                              color: AgentSpaceManager.spaceColorHex, icon: AgentSpaceManager.spaceIconName)
        let persistent = space("persistent", name: "task-id", color: AgentSpaceManager.persistentSpaceColorHex,
                               icon: AgentSpaceManager.spaceIconName)
        let spaces = [space(LocalStore.defaultSpaceId), space("hidden"), space("space.incognito.2"),
                      temporary, persistent]
        XCTAssertEqual(SpaceManager.userSpaceCountForAnalytics(in: spaces, hidden: ["hidden"]), 1)
    }

    private func space(_ id: String, profile: String = "Default", name: String = "Personal",
                       color: String = "#3A6FF8", icon: String = "emoji:1F680") -> Space {
        Space(spaceId: id, profileId: profile, name: name, colorHex: color, iconName: icon, sortOrder: 0)
    }
}

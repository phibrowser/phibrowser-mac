// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// Pins `SpaceManager.isProfileWithoutSpace`: which Chromium-initiated
/// windows the coordinator discards instead of presenting them as a Space of
/// another profile.
final class SpaceManagerProfileWithoutSpaceTests: XCTestCase {
    private typealias Known = (profileId: String, isUserSpace: Bool)

    func testProfileNoSpaceIsBoundToIsWithoutSpace() {
        let known: [Known] = [("Profile 1", true), ("Profile 2", true)]
        XCTAssertTrue(SpaceManager.isProfileWithoutSpace(profileId: "Default", knownSpaces: known))
    }

    func testProfileWithAUserSpaceKeepsItsWindow() {
        let known: [Known] = [("Default", true), ("Profile 1", true)]
        XCTAssertFalse(SpaceManager.isProfileWithoutSpace(profileId: "Default", knownSpaces: known))
    }

    func testProfileUsedOnlyByAnAgentSpaceKeepsItsWindow() {
        let known: [Known] = [("Profile 1", true), ("Default", false)]
        XCTAssertFalse(SpaceManager.isProfileWithoutSpace(profileId: "Default", knownSpaces: known))
    }

    func testNothingIsDiscardedBeforeAnyUserSpaceIsKnown() {
        XCTAssertFalse(SpaceManager.isProfileWithoutSpace(profileId: "Default", knownSpaces: []))
        let onlyEphemeral: [Known] = [("Profile 1", false)]
        XCTAssertFalse(SpaceManager.isProfileWithoutSpace(profileId: "Default", knownSpaces: onlyEphemeral))
    }

    func testWindowReportingNoProfileIsNeverDiscarded() {
        let known: [Known] = [("Profile 1", true)]
        XCTAssertFalse(SpaceManager.isProfileWithoutSpace(profileId: "", knownSpaces: known))
    }
}

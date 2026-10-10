// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class SidebarMediaPreferencesTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "SidebarMediaPreferencesTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testFreshInstallEnablesPlayerAndUsesDynamicMode() {
        XCTAssertTrue(PhiPreferences.GeneralSettings.sidebarMediaPlayerEnabled.loadValue(from: defaults))
        XCTAssertEqual(PhiPreferences.GeneralSettings.loadSidebarMediaPresentationMode(from: defaults), .dynamic)
        defaults.set("unknown-mode", forKey: PhiPreferences.GeneralSettings.sidebarMediaPresentationModeKey)
        XCTAssertEqual(PhiPreferences.GeneralSettings.loadSidebarMediaPresentationMode(from: defaults), .dynamic)
    }

    func testEveryModePersistsIndependentlyOfEnableSwitch() throws {
        for mode in SidebarMediaPresentationMode.allCases {
            PhiPreferences.GeneralSettings.saveSidebarMediaPresentationMode(mode, to: defaults)
            defaults.set(false, forKey: PhiPreferences.GeneralSettings.sidebarMediaPlayerEnabled.rawValue)
            let reopened = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            XCTAssertFalse(PhiPreferences.GeneralSettings.sidebarMediaPlayerEnabled.loadValue(from: reopened))
            XCTAssertEqual(PhiPreferences.GeneralSettings.loadSidebarMediaPresentationMode(from: reopened), mode)
            reopened.set(true, forKey: PhiPreferences.GeneralSettings.sidebarMediaPlayerEnabled.rawValue)
            XCTAssertEqual(PhiPreferences.GeneralSettings.loadSidebarMediaPresentationMode(from: defaults), mode,
                           "Re-enabling the player must preserve each independent display choice")
        }
    }
}

// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class AutoPictureInPictureModeTests: XCTestCase {
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!

    override func setUp() {
        super.setUp()
        defaultsSuiteName = "AutoPictureInPictureModeTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defaultsSuiteName = nil
        defaults = nil
        super.tearDown()
    }

    func testFreshInstallDefaultsToNormal() {
        XCTAssertEqual(PhiPreferences.GeneralSettings.loadAutoPictureInPictureMode(from: defaults), .normal)
    }

    func testUnknownStoredValueFallsBackToNormal() {
        defaults.set("sideways", forKey: PhiPreferences.GeneralSettings.autoPictureInPictureModeKey)
        XCTAssertEqual(PhiPreferences.GeneralSettings.loadAutoPictureInPictureMode(from: defaults), .normal)
    }

    func testSaveRoundTripsEveryMode() {
        for mode in AutoPictureInPictureMode.allCases {
            PhiPreferences.GeneralSettings.saveAutoPictureInPictureMode(mode, to: defaults)
            XCTAssertEqual(PhiPreferences.GeneralSettings.loadAutoPictureInPictureMode(from: defaults), mode)
        }
    }

    func testPictureInPictureOnFullscreenDesktopsDefaultsToOn() {
        XCTAssertTrue(PhiPreferences.GeneralSettings.loadPictureInPictureOnFullscreenDesktops(from: defaults))
    }

    func testPictureInPictureOnFullscreenDesktopsSaveRoundTrips() {
        for enabled in [false, true] {
            PhiPreferences.GeneralSettings.savePictureInPictureOnFullscreenDesktops(enabled, to: defaults)
            XCTAssertEqual(PhiPreferences.GeneralSettings.loadPictureInPictureOnFullscreenDesktops(from: defaults), enabled)
        }
    }
}

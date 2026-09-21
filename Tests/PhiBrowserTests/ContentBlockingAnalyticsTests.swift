// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class ContentBlockingAnalyticsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ContentBlockingAnalyticsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func state(ads: Bool = false, cookies: Bool = false,
                       trackers: Bool = false) -> ContentBlockingState {
        ContentBlockingState(blockAds: ads, blockCookieBanners: cookies, blockTrackers: trackers,
                             lists: [], siteExceptions: [], status: .disabled, statusDetail: "")
    }

    private func snapshot() -> [String: Bool] {
        ContentBlockingAnalytics.snapshotProperties(defaults: defaults) as? [String: Bool] ?? [:]
    }

    func testSnapshotIsAllOffWithoutAMirror() {
        XCTAssertEqual(snapshot(), [
            "block_ads_enabled": false,
            "block_cookie_banners_enabled": false,
            "block_trackers_enabled": false,
        ])
    }

    func testSnapshotIsOnWhenAnyProfileHasTheSwitchOn() {
        ContentBlockingAnalytics.mirror(state(ads: true), profileId: "Default", defaults: defaults)
        ContentBlockingAnalytics.mirror(state(trackers: true), profileId: "Profile 1", defaults: defaults)
        XCTAssertEqual(snapshot(), [
            "block_ads_enabled": true,
            "block_cookie_banners_enabled": false,
            "block_trackers_enabled": true,
        ])

        // Turning it off in the only profile that had it on turns the field off.
        ContentBlockingAnalytics.mirror(state(), profileId: "Default", defaults: defaults)
        XCTAssertEqual(snapshot()["block_ads_enabled"], false)
        XCTAssertEqual(snapshot()["block_trackers_enabled"], true)
    }

    func testMirrorPrunesDeletedProfiles() {
        ContentBlockingAnalytics.mirror(state(ads: true), profileId: "Profile 1", defaults: defaults)
        ContentBlockingAnalytics.mirror(state(), profileId: "Default",
                                        knownProfileIds: ["Default"], defaults: defaults)
        XCTAssertEqual(snapshot()["block_ads_enabled"], false)
    }
}

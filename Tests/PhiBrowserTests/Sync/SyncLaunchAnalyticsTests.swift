// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// The launch snapshot's sync fields and their caches (docs/sync.md, "Launch snapshot caches").
final class SyncLaunchAnalyticsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "SyncLaunchAnalyticsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func properties() -> [String: Any] {
        SyncLaunchAnalytics.snapshotProperties(defaults: defaults)
    }

    private func device(_ id: String, status: String = "active", revoked: Bool = false) throws -> AccountDeviceDTO {
        var json: [String: Any] = ["device_key_id": id, "name": "n", "platform": "macos", "status": status,
                                   "created_at": "2026-10-01T00:00:00Z"]
        if revoked { json["revoked_at"] = "2026-10-02T00:00:00Z" }
        return try JSONDecoder().decode(AccountDeviceDTO.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testSyncEnabledIsAlwaysPresentAndUnknownCountsAreOmitted() {
        XCTAssertEqual(properties() as? [String: Bool], ["sync_enabled": false], "Never mirrored: off, no counts")

        SyncLaunchAnalytics.recordPaired(true, defaults: defaults)
        XCTAssertEqual(properties() as? [String: Bool], ["sync_enabled": true], "Paired, nothing listed yet")

        SyncLaunchAnalytics.recordAccountProfiles(["a", "b"], defaults: defaults)
        SyncLaunchAnalytics.recordDefaultFlag(uuid: "a", isDefault: true, defaults: defaults)
        var snapshot = properties()
        XCTAssertEqual(snapshot["sync_account_profile_count"] as? Int, 2)
        XCTAssertNil(snapshot["sync_default_flagged_profile_count"], "b's flag is unknown, so the count is too")
        XCTAssertNil(snapshot["sync_paired_device_count"])

        SyncLaunchAnalytics.recordDefaultFlag(uuid: "b", isDefault: false, defaults: defaults)
        SyncLaunchAnalytics.recordActiveDeviceCount(3, defaults: defaults)
        snapshot = properties()
        XCTAssertEqual(snapshot["sync_default_flagged_profile_count"] as? Int, 1)
        XCTAssertEqual(snapshot["sync_paired_device_count"] as? Int, 3)
        XCTAssertEqual(snapshot["sync_enabled"] as? Bool, true)

        SyncLaunchAnalytics.recordPaired(false, defaults: defaults)
        XCTAssertEqual(properties() as? [String: Bool], ["sync_enabled": false], "Counts are omitted while off")
    }

    func testTheDefaultFlagCountIgnoresProfilesNoLongerListed() {
        SyncLaunchAnalytics.recordPaired(true, defaults: defaults)
        SyncLaunchAnalytics.recordAccountProfiles(["a", "b", "c"], defaults: defaults)
        for uuid in ["a", "b", "c"] {
            SyncLaunchAnalytics.recordDefaultFlag(uuid: uuid, isDefault: uuid != "c", defaults: defaults)
        }
        XCTAssertEqual(properties()["sync_default_flagged_profile_count"] as? Int, 2, "Two defaults")

        SyncLaunchAnalytics.recordAccountProfiles(["a", "c"], defaults: defaults)
        XCTAssertEqual(properties()["sync_account_profile_count"] as? Int, 2)
        XCTAssertEqual(properties()["sync_default_flagged_profile_count"] as? Int, 1, "b left the account")

        // A flag read for a uuid the last listing did not name does not count until it is listed.
        SyncLaunchAnalytics.recordDefaultFlag(uuid: "d", isDefault: true, defaults: defaults)
        XCTAssertEqual(properties()["sync_default_flagged_profile_count"] as? Int, 1)
    }

    func testTheLazyFillReadsAtMostThreeUnreadProfilesPerPass() {
        let listing: Set<String> = ["e", "a", "d", "b", "c", "f"]
        SyncLaunchAnalytics.recordDefaultFlag(uuid: "b", isDefault: false, defaults: defaults)
        let first = SyncLaunchAnalytics.uuidsNeedingDefaultFlag(listing: listing, excluded: ["a"], defaults: defaults)
        XCTAssertEqual(first, ["c", "d", "e"], "Uuid order, at most three, read and unreadable ones skipped")
        for uuid in first { SyncLaunchAnalytics.recordDefaultFlag(uuid: uuid, isDefault: false, defaults: defaults) }
        XCTAssertEqual(SyncLaunchAnalytics.uuidsNeedingDefaultFlag(listing: listing, excluded: ["a"], defaults: defaults),
                       ["f"])
        XCTAssertEqual(SyncLaunchAnalytics.defaultFlagFillPerPass, 3)
    }

    func testTheDeviceCountCacheFollowsTheLatestListing() throws {
        let rows = [try device("d1"), try device("d2"), try device("d3", status: "revoked", revoked: true),
                    try device("d4", revoked: true)]
        XCTAssertEqual(SyncLaunchAnalytics.activeDeviceCount(rows), 2, "Active and unrevoked only")
        SyncLaunchAnalytics.recordPaired(true, defaults: defaults)
        SyncLaunchAnalytics.recordActiveDeviceCount(SyncLaunchAnalytics.activeDeviceCount(rows), defaults: defaults)
        XCTAssertEqual(properties()["sync_paired_device_count"] as? Int, 2)
        SyncLaunchAnalytics.recordActiveDeviceCount(1, defaults: defaults)
        XCTAssertEqual(properties()["sync_paired_device_count"] as? Int, 1)
    }

    func testResetForgetsEverything() {
        SyncLaunchAnalytics.recordPaired(true, defaults: defaults)
        SyncLaunchAnalytics.recordAccountProfiles(["a"], defaults: defaults)
        SyncLaunchAnalytics.recordDefaultFlag(uuid: "a", isDefault: true, defaults: defaults)
        SyncLaunchAnalytics.recordActiveDeviceCount(2, defaults: defaults)
        SyncLaunchAnalytics.reset(defaults: defaults)
        XCTAssertEqual(properties() as? [String: Bool], ["sync_enabled": false])
        SyncLaunchAnalytics.recordPaired(true, defaults: defaults)
        XCTAssertEqual(properties() as? [String: Bool], ["sync_enabled": true], "No stale counts after re-pairing")
    }
}

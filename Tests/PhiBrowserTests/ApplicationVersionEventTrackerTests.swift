// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// Pins the manual `Application Installed` / `Application Updated` capture to
/// the PostHog SDK's semantics: its UserDefaults keys, its build-keyed
/// decision, and its property names and value types.
final class ApplicationVersionEventTrackerTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suite = "ApplicationVersionEventTrackerTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private func tracker(version: String? = "2.11.0", build: String? = "830") -> ApplicationVersionEventTracker {
        ApplicationVersionEventTracker(defaults: defaults, currentVersion: version, currentBuild: build)
    }

    func testUsesTheSDKsKeysAndEventNames() {
        XCTAssertEqual(ApplicationVersionEventTracker.versionKey, "PHGVersionKey")
        XCTAssertEqual(ApplicationVersionEventTracker.buildKey, "PHGBuildKeyV2")
        XCTAssertEqual(ApplicationVersionEventTracker.installedEvent, "Application Installed")
        XCTAssertEqual(ApplicationVersionEventTracker.updatedEvent, "Application Updated")
    }

    func testNoStoredBuildIsAnInstall() throws {
        let launch = try XCTUnwrap(tracker().consumeLaunch())
        XCTAssertEqual(launch.event, "Application Installed")
        XCTAssertEqual(launch.properties["version"] as? String, "2.11.0")
        XCTAssertEqual(launch.properties["build"] as? Int, 830)
        XCTAssertNil(launch.properties["previous_version"])
        XCTAssertNil(launch.properties["previous_build"])
        // Persisted under the SDK's keys, as strings, like the SDK does.
        XCTAssertEqual(defaults.string(forKey: "PHGVersionKey"), "2.11.0")
        XCTAssertEqual(defaults.string(forKey: "PHGBuildKeyV2"), "830")
    }

    func testSameVersionAndBuildSendsNothing() {
        defaults.set("2.11.0", forKey: "PHGVersionKey")
        defaults.set("830", forKey: "PHGBuildKeyV2")
        XCTAssertNil(tracker().consumeLaunch())
    }

    func testDifferentVersionIsAnUpdateWithThePreviousValues() throws {
        defaults.set("2.9.0", forKey: "PHGVersionKey")
        defaults.set("807", forKey: "PHGBuildKeyV2")
        let launch = try XCTUnwrap(tracker().consumeLaunch())
        XCTAssertEqual(launch.event, "Application Updated")
        XCTAssertEqual(launch.properties["version"] as? String, "2.11.0")
        XCTAssertEqual(launch.properties["build"] as? Int, 830)
        XCTAssertEqual(launch.properties["previous_version"] as? String, "2.9.0")
        XCTAssertEqual(launch.properties["previous_build"] as? Int, 807)
        XCTAssertEqual(defaults.string(forKey: "PHGVersionKey"), "2.11.0")
        XCTAssertEqual(defaults.string(forKey: "PHGBuildKeyV2"), "830")
    }

    /// The build alone decides, as in the SDK: a canary rebuild of the same
    /// marketing version is still an update.
    func testSameVersionDifferentBuildIsAnUpdate() throws {
        defaults.set("2.11.0", forKey: "PHGVersionKey")
        defaults.set("829", forKey: "PHGBuildKeyV2")
        let launch = try XCTUnwrap(tracker().consumeLaunch())
        XCTAssertEqual(launch.event, "Application Updated")
        XCTAssertEqual(launch.properties["previous_version"] as? String, "2.11.0")
        XCTAssertEqual(launch.properties["previous_build"] as? Int, 829)
    }

    /// 2.10 → 2.11: the SDK's lifecycle integration wrote the keys on 2.10
    /// (819, before e748d9f4 turned it off); this build must read them back
    /// and report an update, not a fresh install.
    func testUpgradeFromABuildWhereTheSDKWroteTheKeysIsAnUpdate() throws {
        defaults.set("2.10.0", forKey: "PHGVersionKey")
        defaults.set("819", forKey: "PHGBuildKeyV2")
        let launch = try XCTUnwrap(tracker().consumeLaunch())
        XCTAssertEqual(launch.event, "Application Updated")
        XCTAssertEqual(launch.properties["previous_version"] as? String, "2.10.0")
        XCTAssertEqual(launch.properties["previous_build"] as? Int, 819)
        XCTAssertEqual(launch.properties["version"] as? String, "2.11.0")
        XCTAssertEqual(launch.properties["build"] as? Int, 830)
        // The next launch of the same build is quiet.
        XCTAssertNil(tracker().consumeLaunch())
    }

    func testNonNumericBuildsStayStrings() throws {
        defaults.set("2.10.0", forKey: "PHGVersionKey")
        defaults.set("819b", forKey: "PHGBuildKeyV2")
        let launch = try XCTUnwrap(tracker(build: "830rc1").consumeLaunch())
        XCTAssertEqual(launch.properties["previous_build"] as? String, "819b")
        XCTAssertEqual(launch.properties["build"] as? String, "830rc1")
    }
}

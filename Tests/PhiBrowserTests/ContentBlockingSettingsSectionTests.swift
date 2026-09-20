// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

private final class RecordingBridge: ContentBlockingBridging {
    var categoryCalls: [(String, PhiContentBlockingCategory, Bool)] = []

    func getContentBlockingSettings(_ profileId: String,
                                    completion: @escaping ((any PhiContentBlockingSettings)?, String?) -> Void) {
        completion(FakeSettings(blockAds: true, blockCookieBanners: true, blockTrackers: true,
                                lists: [], siteExceptions: []), nil)
    }

    func setContentBlockingCategory(_ profileId: String,
                                    category: PhiContentBlockingCategory,
                                    enabled: Bool,
                                    completion: @escaping (Bool, String?) -> Void) {
        categoryCalls.append((profileId, category, enabled))
        completion(true, nil)
    }

    func setContentBlockingList(_ profileId: String, listId: String, enabled: Bool,
                                completion: @escaping (Bool, String?) -> Void) {
        completion(true, nil)
    }

    func setContentBlockingSiteException(_ profileId: String, domain: String, enabled: Bool,
                                         completion: @escaping (Bool, String?) -> Void) {
        completion(true, nil)
    }

    func contentBlockingSiteExceptionDomain(forURL url: String) -> String {
        URL(string: url)?.host ?? ""
    }
}

@MainActor
final class ContentBlockingSettingsSectionTests: XCTestCase {
    func testSelectingAProfileBindsTheTogglesToItsFacade() {
        let bridge = RecordingBridge()
        let model = ContentBlockingSectionModel(makeSettings: {
            ContentBlockingSettings(profileId: $0, bridge: bridge, notificationCenter: NotificationCenter())
        })
        model.select("Work")
        let drained = expectation(description: "refresh delivered")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
        XCTAssertEqual(model.settings?.profileId, "Work")
        XCTAssertEqual(model.settings?.state?.blockTrackers, true)

        model.settings?.setCategory(.trackers, enabled: false)
        XCTAssertEqual(model.settings?.state?.blockTrackers, false)
        XCTAssertEqual(bridge.categoryCalls.count, 1)
        XCTAssertEqual(bridge.categoryCalls.first?.0, "Work")
        XCTAssertEqual(bridge.categoryCalls.first?.1, .trackers)
        XCTAssertEqual(bridge.categoryCalls.first?.2, false)
    }

    func testReselectingTheSameProfileKeepsTheFacade() {
        let model = ContentBlockingSectionModel(makeSettings: { ContentBlockingSettings(profileId: $0, bridge: nil) })
        model.select("A")
        let first = model.settings
        model.select("A")
        XCTAssertTrue(model.settings === first)
        model.select("B")
        XCTAssertEqual(model.settings?.profileId, "B")
        XCTAssertFalse(model.settings === first)
    }
}

final class ContentBlockingDiagnosticsLinesTests: XCTestCase {
    private func state(_ status: ContentBlockingState.Status, blocked: Int = 0, detail: String = "") -> ContentBlockingState {
        ContentBlockingState(blockAds: true, blockCookieBanners: true, blockTrackers: true,
                             lists: [], siteExceptions: [], status: status, statusDetail: detail,
                             sessionBlockedCount: blocked, lastBuildLog: "")
    }

    func testNothingWhileStateIsUnknownOrBuilding() {
        XCTAssertEqual(ContentBlockingSettingsSection.diagnosticsLines(for: nil), [])
        XCTAssertEqual(ContentBlockingSettingsSection.diagnosticsLines(for: state(.building)), [])
    }

    func testActiveShowsNothingAndHidesTheSessionCount() {
        XCTAssertEqual(ContentBlockingSettingsSection.diagnosticsLines(for: state(.active, blocked: 42)), [])
    }

    func testDegradedShowsStatusAndDetail() {
        let lines = ContentBlockingSettingsSection.diagnosticsLines(for: state(.degraded, blocked: 3, detail: "cache unreadable"))
        XCTAssertEqual(lines.count, 2)
        XCTAssertFalse(lines[0].contains("3"))
        XCTAssertEqual(lines[1], "cache unreadable")
        XCTAssertEqual(ContentBlockingSettingsSection.diagnosticsLines(for: state(.degraded)).count, 1)
    }

    func testDisabledShowsNothing() {
        XCTAssertEqual(ContentBlockingSettingsSection.diagnosticsLines(for: state(.disabled, blocked: 9)), [])
    }
}

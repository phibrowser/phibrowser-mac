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

final class PrivacySettingsViewTests: XCTestCase {
    private func profile(_ id: String) -> PhiBrowserProfile {
        PhiBrowserProfile(profileId: id, displayName: id, isLoaded: true, isInUse: false)
    }

    func testInitialSelectionPrefersTheActiveProfile() {
        let profiles = [profile(LocalStore.defaultProfileId), profile("Work")]
        XCTAssertEqual(PrivacySettingsModel.initialProfileId(profiles: profiles, activeProfileId: "Work"), "Work")
    }

    func testIncognitoOrUnknownActiveProfileFallsBackToDefault() {
        let profiles = [profile("Work"), profile(LocalStore.defaultProfileId)]
        XCTAssertEqual(PrivacySettingsModel.initialProfileId(profiles: profiles,
                                                             activeProfileId: SpaceManager.incognitoProfileId),
                       LocalStore.defaultProfileId)
        XCTAssertEqual(PrivacySettingsModel.initialProfileId(profiles: profiles, activeProfileId: "Gone"),
                       LocalStore.defaultProfileId)
        XCTAssertEqual(PrivacySettingsModel.initialProfileId(profiles: [profile("Only")], activeProfileId: nil),
                       "Only")
        XCTAssertNil(PrivacySettingsModel.initialProfileId(profiles: [], activeProfileId: nil))
    }

    func testReconcileKeepsAValidSelection() {
        let model = PrivacySettingsModel(makeSettings: { ContentBlockingSettings(profileId: $0, bridge: nil) })
        model.reconcile(profiles: [profile("A"), profile("B")], activeProfileId: "B")
        XCTAssertEqual(model.selectedProfileId, "B")
        model.reconcile(profiles: [profile("A"), profile("B")], activeProfileId: "A")
        XCTAssertEqual(model.selectedProfileId, "B", "an existing valid selection is kept")
        model.reconcile(profiles: [profile("A")], activeProfileId: nil)
        XCTAssertEqual(model.selectedProfileId, "A", "a deleted profile's selection moves on")
    }

    func testTogglesBindToTheSelectedProfileFacade() {
        let bridge = RecordingBridge()
        let model = PrivacySettingsModel(makeSettings: {
            ContentBlockingSettings(profileId: $0, bridge: bridge, notificationCenter: NotificationCenter())
        })
        model.reconcile(profiles: [profile("Work")], activeProfileId: "Work")
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
}

final class PrivacySettingsDiagnosticsTests: XCTestCase {
    private func state(_ status: ContentBlockingState.Status, blocked: Int = 0, detail: String = "") -> ContentBlockingState {
        ContentBlockingState(blockAds: true, blockCookieBanners: true, blockTrackers: true,
                             lists: [], siteExceptions: [], status: status, statusDetail: detail,
                             sessionBlockedCount: blocked, lastBuildLog: "")
    }

    func testNothingWhileStateIsUnknownOrBuilding() {
        XCTAssertEqual(PrivacySettingsView.diagnosticsLines(for: nil), [])
        XCTAssertEqual(PrivacySettingsView.diagnosticsLines(for: state(.building)), [])
    }

    func testActiveShowsNothingAndHidesTheSessionCount() {
        XCTAssertEqual(PrivacySettingsView.diagnosticsLines(for: state(.active, blocked: 42)), [])
    }

    func testDegradedShowsStatusAndDetail() {
        let lines = PrivacySettingsView.diagnosticsLines(for: state(.degraded, blocked: 3, detail: "cache unreadable"))
        XCTAssertEqual(lines.count, 2)
        XCTAssertFalse(lines[0].contains("3"))
        XCTAssertEqual(lines[1], "cache unreadable")
        XCTAssertEqual(PrivacySettingsView.diagnosticsLines(for: state(.degraded)).count, 1)
    }

    func testDisabledShowsOnlyTheOffLine() {
        let lines = PrivacySettingsView.diagnosticsLines(for: state(.disabled, blocked: 9))
        XCTAssertEqual(lines.count, 1)
        XCTAssertFalse(lines[0].contains("9"))
    }
}

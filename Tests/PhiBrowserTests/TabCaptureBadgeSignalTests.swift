// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

@MainActor
final class TabCaptureBadgeSignalTests: XCTestCase {
    func test_micOrCameraOnly_drivesCapturingMediaNotScreenShare() {
        let tab = Tab(guid: 1, url: "https://meet.example/", isActive: true, index: 0)
        tab.setCaptureStateForTesting(audio: true, video: true)

        XCTAssertTrue(tab.isCapturingMedia)
        XCTAssertFalse(tab.isPresentingScreenShare)
        XCTAssertFalse(tab.isBeingSharedRemotely)
    }

    func test_presentingTab_sharingScreenWithoutMirror() {
        let tab = Tab(guid: 1, url: "https://meet.example/", isActive: true, index: 0)
        tab.setCaptureStateForTesting(sharingScreen: true, beingMirrored: false)

        XCTAssertFalse(tab.isCapturingMedia)
        XCTAssertTrue(tab.isPresentingScreenShare)
        XCTAssertFalse(tab.isBeingSharedRemotely)
    }

    func test_mirroredTarget_showsBeingSharedNotPresenting() {
        let tab = Tab(guid: 2, url: "https://youtube.example/", isActive: true, index: 1)
        tab.setCaptureStateForTesting(sharingScreen: true, beingMirrored: true)

        XCTAssertFalse(tab.isCapturingMedia)
        XCTAssertFalse(tab.isPresentingScreenShare)
        XCTAssertTrue(tab.isBeingSharedRemotely)
    }

    func test_mirroredTarget_doesNotCountAsCapturingMediaForMicDot() {
        let tab = Tab(guid: 2, url: "https://youtube.example/", isActive: true, index: 1)
        tab.setCaptureStateForTesting(sharingScreen: true, beingMirrored: true)

        XCTAssertFalse(tab.isCapturingMedia)
        XCTAssertTrue(tab.showsCaptureIndicator)
    }
}

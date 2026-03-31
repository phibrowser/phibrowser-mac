// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class LivingDownloadItemTests: XCTestCase {
    func testWarningItemDoesNotAutoDismissAfterHoverEnds() {
        let item = DownloadItem(
            id: "warning-download",
            fileName: "dangerous.pkg",
            url: "https://example.com/dangerous.pkg",
            state: .complete,
            percentComplete: 100,
            totalBytes: 1024,
            receivedBytes: 1024
        )
        item.isDangerous = true
        item.dangerType = DownloadDangerType.dangerousFile.rawValue
        item.isInsecure = false
        item.insecureDownloadStatus = InsecureDownloadStatus.safe.rawValue

        let livingItem = LivingDownloadItem(downloadItem: item, dismissDuration: 0.05)

        livingItem.setHovered(true)
        livingItem.setHovered(false)

        RunLoop.main.run(until: Date().addingTimeInterval(0.15))

        XCTAssertFalse(livingItem.shouldDismiss)
    }

    func testNormalItemDismissTimerIsNotResetByUnchangedSafetyFields() {
        let item = DownloadItem(
            id: "normal-download",
            fileName: "safe.zip",
            url: "https://example.com/safe.zip",
            state: .complete,
            percentComplete: 100,
            totalBytes: 1024,
            receivedBytes: 1024
        )
        item.isDangerous = false
        item.dangerType = DownloadDangerType.notDangerous.rawValue
        item.isInsecure = false
        item.insecureDownloadStatus = InsecureDownloadStatus.safe.rawValue

        let livingItem = LivingDownloadItem(downloadItem: item, dismissDuration: 0.1)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            // Same value write should not reset dismiss timer.
            item.isDangerous = false
        }

        RunLoop.main.run(until: Date().addingTimeInterval(0.14))

        XCTAssertTrue(livingItem.shouldDismiss)
    }
}

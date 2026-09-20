// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class ContentBlockingCustomFiltersSheetTests: XCTestCase {
    private func list(_ id: String, _ category: String) -> ContentBlockingList {
        ContentBlockingList(id: id, category: category, title: id, description: "",
                            homepage: nil, license: "", checked: true)
    }

    private func state(_ lists: [ContentBlockingList]) -> ContentBlockingState {
        ContentBlockingState(blockAds: true, blockCookieBanners: true, blockTrackers: true,
                             lists: lists, siteExceptions: [], status: .active, statusDetail: "")
    }

    func testDoneDownloadsOnlyCheckedMissingCustomLists() {
        var missingCustom = list("custom-1", "custom")
        missingCustom.isCustom = true
        missingCustom.available = false
        var uncheckedCustom = list("custom-2", "custom")
        uncheckedCustom.isCustom = true
        uncheckedCustom.available = false
        uncheckedCustom.checked = false
        var missingCatalog = list("easylist", "ads")
        missingCatalog.available = false
        var busy = list("custom-3", "custom")
        busy.isCustom = true
        busy.available = false
        busy.isDownloading = true
        let state = state([missingCustom, uncheckedCustom, missingCatalog, busy])
        XCTAssertEqual(ContentBlockingCustomFiltersSheet.missingIds(in: state), ["custom-1"])
        XCTAssertTrue(ContentBlockingCustomFiltersSheet.anyDownloading(in: state))
    }

    func testRowControlFollowsTheListState() {
        var bundled = list("phi-specific", "phi")
        bundled.fetchedAt = nil
        XCTAssertEqual(ContentBlockingListRow.control(for: bundled), .none)

        var downloaded = list("easylist", "ads")
        downloaded.fetchedAt = Date()
        XCTAssertEqual(ContentBlockingListRow.control(for: downloaded), .none,
                       "downloaded files are shared by every profile and are not deleted from here")

        var missing = list("easylist", "ads")
        missing.available = false
        XCTAssertEqual(ContentBlockingListRow.control(for: missing), .download,
                       "a missing list is idle until the user downloads it")

        var fetching = missing
        fetching.isDownloading = true
        XCTAssertEqual(ContentBlockingListRow.control(for: fetching), .downloading)

        var failed = missing
        failed.lastError = "HTTP 404"
        XCTAssertEqual(ContentBlockingListRow.control(for: failed), .download)

        var pasted = list("custom-1", "custom")
        pasted.isCustom = true
        XCTAssertEqual(ContentBlockingListRow.control(for: pasted), .removeCustom)

        var remote = pasted
        remote.sourceURL = URL(string: "https://a.example/l.txt")
        remote.available = false
        XCTAssertEqual(ContentBlockingListRow.control(for: remote), .removeCustom)
        remote.isDownloading = true
        XCTAssertEqual(ContentBlockingListRow.control(for: remote), .downloading)
    }

    func testAvailabilityLineAndDownloadingBytes() {
        var remote = list("custom-1", "custom")
        remote.isCustom = true
        remote.available = false
        XCTAssertEqual(ContentBlockingListRow.availabilityLine(for: remote), "Not downloaded yet")
        remote.isDownloading = true
        XCTAssertEqual(ContentBlockingListRow.availabilityLine(for: remote), "Downloading…")
        remote.downloadedBytes = 512_000
        XCTAssertTrue(ContentBlockingListRow.availabilityLine(for: remote)!.hasPrefix("Downloading… "))
        XCTAssertFalse(ContentBlockingListRow.availabilityLine(for: remote)!.contains(" of "))
        remote.totalBytes = 2_048_000
        XCTAssertTrue(ContentBlockingListRow.availabilityLine(for: remote)!.contains(" of "))
        var failed = remote
        failed.isDownloading = false
        failed.lastError = "HTTP 404"
        XCTAssertEqual(ContentBlockingListRow.availabilityLine(for: failed), "Not downloaded: HTTP 404")
        XCTAssertNil(ContentBlockingListRow.availabilityLine(for: list("easylist", "ads")))
    }

    func testInfoPopoverUpdateLine() {
        let now = Date()
        var fetched = list("easylist", "ads")
        fetched.fetchedAt = now.addingTimeInterval(-3 * 3600)
        XCTAssertTrue(ContentBlockingListInfoPopover.updateLine(for: fetched, now: now).hasPrefix("Updated "))
        XCTAssertEqual(ContentBlockingListInfoPopover.updateLine(for: list("phi-specific", "phi"), now: now), "Built into Phi")
        var pending = list("x", "ads")
        pending.available = false
        XCTAssertEqual(ContentBlockingListInfoPopover.updateLine(for: pending, now: now), "Not downloaded yet")
    }
}

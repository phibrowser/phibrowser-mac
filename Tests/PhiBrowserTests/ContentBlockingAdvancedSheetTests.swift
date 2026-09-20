// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class ContentBlockingAdvancedSheetTests: XCTestCase {
    private func list(_ id: String, _ category: String) -> ContentBlockingList {
        ContentBlockingList(id: id, category: category, title: id, description: "",
                            homepage: nil, license: "", checked: true)
    }

    func testListsGroupedBySectionInCatalogOrder() {
        // Catalog order interleaves categories; the sheet keeps each
        // section's members in that order and orders sections fixedly.
        let lists = [
            list("easylist", "ads"),
            list("easyprivacy", "trackers"),
            list("ublock-ads", "ads"),
            list("easylist-cookie", "cookies"),
            list("adguard-japanese", "regional"),
            list("phi-specific", "phi"),
            list("ublock-privacy", "trackers"),
            list("bulgarian", "regional"),
        ]
        let groups = ContentBlockingAdvancedSheet.groups(from: lists)
        XCTAssertEqual(groups.map(\.section), [.ads, .trackers, .cookies, .regional, .custom])
        XCTAssertTrue(groups[4].lists.isEmpty, "the Custom section always shows so a filter can be added")
        XCTAssertEqual(groups[0].lists.map(\.id), ["easylist", "ublock-ads"])
        XCTAssertEqual(groups[1].lists.map(\.id), ["easyprivacy", "ublock-privacy"])
        XCTAssertEqual(groups[2].lists.map(\.id), ["easylist-cookie"])
        XCTAssertEqual(groups[3].lists.map(\.id), ["adguard-japanese", "bulgarian"])
    }

    func testPhiSectionIsHidden() {
        // The first-party list is active but not user-selectable.
        let groups = ContentBlockingAdvancedSheet.groups(from: [list("phi-specific", "phi"), list("x", "ads")])
        XCTAssertEqual(groups.map(\.section), [.ads])
    }

    func testEmptySectionsAreOmittedAndUnknownCategoriesIgnored() {
        let groups = ContentBlockingAdvancedSheet.groups(from: [list("x", "ads"), list("y", "mystery")])
        XCTAssertEqual(groups.map(\.section), [.ads, .custom])
    }

    func testCustomListsGroupTogetherAndReadTheirDownloadState() {
        var remote = list("custom-1", "custom")
        remote.isCustom = true
        remote.available = false
        var failed = list("custom-2", "custom")
        failed.isCustom = true
        failed.available = false
        failed.lastError = "HTTP 404"
        let groups = ContentBlockingAdvancedSheet.groups(from: [list("easylist", "ads"), remote, failed])
        XCTAssertEqual(groups.map(\.section), [.ads, .custom])
        XCTAssertEqual(groups[1].lists.map(\.id), ["custom-1", "custom-2"])
        XCTAssertEqual(ContentBlockingListRow.availabilityLine(for: remote), "Downloading…")
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

    func testSectionsFollowThePaneToggles() {
        var state = ContentBlockingState(blockAds: false, blockCookieBanners: true, blockTrackers: false,
                                         lists: [], siteExceptions: [], status: .active, statusDetail: "")
        XCTAssertFalse(ContentBlockingSection.ads.isEnabled(in: state))
        XCTAssertFalse(ContentBlockingSection.regional.isEnabled(in: state))
        XCTAssertFalse(ContentBlockingSection.trackers.isEnabled(in: state))
        XCTAssertTrue(ContentBlockingSection.cookies.isEnabled(in: state))
        XCTAssertTrue(ContentBlockingSection.phi.isEnabled(in: state), "Phi follows any toggle")
        state.blockCookieBanners = false
        XCTAssertFalse(ContentBlockingSection.phi.isEnabled(in: state))
    }
}

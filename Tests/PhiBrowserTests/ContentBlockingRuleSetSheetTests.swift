// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class ContentBlockingRuleSetSheetTests: XCTestCase {
    private func list(_ id: String, _ category: String, checked: Bool = true, available: Bool = true,
                      error: String = "", custom: Bool = false, downloading: Bool = false) -> ContentBlockingList {
        var list = ContentBlockingList(id: id, category: category, title: id, description: "",
                                       homepage: nil, license: "", checked: checked)
        list.available = available
        list.lastError = error
        list.isCustom = custom
        list.isDownloading = downloading
        return list
    }

    private func state(_ lists: [ContentBlockingList], status: ContentBlockingState.Status = .active) -> ContentBlockingState {
        ContentBlockingState(blockAds: true, blockCookieBanners: true, blockTrackers: true,
                             lists: lists, siteExceptions: [], status: status, statusDetail: "")
    }

    func testAdsCoverRegionalListsAndCustomListsCountForEveryToggle() {
        let lists = [list("easylist", "ads"), list("adguard-chinese", "regional"),
                     list("easyprivacy", "trackers"), list("cookie", "cookies"), list("custom-1", "custom", custom: true)]
        XCTAssertEqual(ContentBlockingRuleSets.lists(for: .ads, in: state(lists)).map(\.id), ["easylist", "adguard-chinese"])
        XCTAssertEqual(ContentBlockingRuleSets.lists(for: .trackers, in: state(lists)).map(\.id), ["easyprivacy"])
        XCTAssertEqual(ContentBlockingRuleSets.lists(for: .cookieBanners, in: state(lists)).map(\.id), ["cookie"])

        // Only a custom list on disk: no download is needed for any toggle.
        let onlyCustom = state([list("easylist", "ads", available: false), list("custom-1", "custom", custom: true)])
        XCTAssertFalse(ContentBlockingRuleSets.needsDownload(for: .ads, in: onlyCustom))
        XCTAssertFalse(ContentBlockingRuleSets.needsDownload(for: .trackers, in: onlyCustom))
    }

    func testNeedsDownloadUntilACheckedListIsOnDisk() {
        XCTAssertTrue(ContentBlockingRuleSets.needsDownload(for: .ads, in: state([list("easylist", "ads", available: false)])))
        XCTAssertTrue(ContentBlockingRuleSets.needsDownload(for: .ads, in: state([list("easylist", "ads", checked: false)])),
                      "an unchecked downloaded list does not count")
        XCTAssertFalse(ContentBlockingRuleSets.needsDownload(for: .ads, in: state([list("easylist", "ads")])))
        XCTAssertTrue(ContentBlockingRuleSets.needsDownload(for: .trackers, in: state([])))
    }

    func testSummaryNamesTheCheckedListsAndTheirState() {
        XCTAssertEqual(ContentBlockingRuleSets.summary(for: .ads, in: state([list("easylist", "ads", checked: false)])), "No rule sets selected")
        XCTAssertEqual(ContentBlockingRuleSets.summary(for: .ads, in: state([list("easylist", "ads")])), "easylist")
        XCTAssertEqual(ContentBlockingRuleSets.summary(for: .ads, in: state([list("easylist", "ads"), list("ublock-ads", "ads")])), "2 rule sets")
        XCTAssertEqual(ContentBlockingRuleSets.summary(for: .ads, in: state([list("a", "ads"), list("b", "ads"), list("c", "regional")])), "3 rule sets")
        // Custom lists apply to every toggle and are counted on each line.
        let withCustom = state([list("easylist", "ads"), list("custom-1", "custom", custom: true)])
        XCTAssertEqual(ContentBlockingRuleSets.summary(for: .ads, in: withCustom), "easylist + 1 custom list")
        XCTAssertEqual(ContentBlockingRuleSets.summary(for: .trackers, in: withCustom), "1 custom list")
        let twoCustom = state([list("custom-1", "custom", custom: true), list("custom-2", "custom", custom: true)])
        XCTAssertEqual(ContentBlockingRuleSets.summary(for: .ads, in: twoCustom), "2 custom lists")
        XCTAssertEqual(ContentBlockingRuleSets.actionLabel(for: .trackers, in: withCustom), "Change…")
        XCTAssertEqual(ContentBlockingRuleSets.summary(for: .ads, in: state([list("easylist", "ads", available: false)])), "easylist · 1 not downloaded")
        XCTAssertEqual(ContentBlockingRuleSets.summary(for: .ads, in: state([list("easylist", "ads", available: false, downloading: true)])), "easylist · Downloading…")
        XCTAssertEqual(ContentBlockingRuleSets.summary(for: .ads, in: state([list("easylist", "ads"), list("ublock-ads", "ads", available: false, error: "HTTP 404")])), "2 rule sets · 1 not downloaded")
    }

    func testDoneDownloadsOnlyCheckedMissingLists() {
        let lists = [list("easylist", "ads", available: false), list("adguard-chinese", "regional", checked: false, available: false),
                     list("cookie", "cookies", available: false), list("custom-1", "custom", available: false, custom: true),
                     list("busy", "ads", available: false, downloading: true)]
        XCTAssertEqual(ContentBlockingRuleSetSheet.missingIds(for: .ads, in: state(lists)), ["easylist", "custom-1"])
        XCTAssertTrue(ContentBlockingRuleSetSheet.anyDownloading(for: .ads, in: state(lists)))
        XCTAssertEqual(ContentBlockingRuleSetSheet.missingIds(for: .cookieBanners, in: state(lists)), ["cookie", "custom-1"], "custom lists show in every sheet")
        XCTAssertFalse(ContentBlockingRuleSetSheet.anyDownloading(for: .cookieBanners, in: state(lists)))
        XCTAssertEqual(ContentBlockingRuleSetSheet.missingIds(for: .ads, in: state([list("easylist", "ads")])), [])
    }

    func testUpdateDownloadedCoversFetchableListsOnDisk() {
        var pasted = list("custom-1", "custom", custom: true)
        pasted.sourceURL = nil
        var remote = list("custom-2", "custom", custom: true)
        remote.sourceURL = URL(string: "https://a.example/l.txt")
        let lists = [list("easylist", "ads"), list("adguard-chinese", "regional", checked: false),
                     list("easyprivacy", "trackers"), list("missing", "ads", available: false), pasted, remote]
        XCTAssertEqual(ContentBlockingRuleSetSheet.downloadedIds(for: .ads, in: state(lists)), ["easylist", "adguard-chinese", "custom-2"])
    }

    func testTogglesWithoutAUsableRuleSetTurnOff() {
        XCTAssertEqual(ContentBlockingRuleSets.togglesToTurnOff(in: state([])), [.ads, .cookieBanners, .trackers])
        XCTAssertEqual(ContentBlockingRuleSets.togglesToTurnOff(in: state([list("easylist", "ads"), list("cookie", "cookies")])), [.trackers])
        XCTAssertEqual(ContentBlockingRuleSets.togglesToTurnOff(in: state([list("custom-1", "custom", custom: true)])), [])
        var off = state([list("easylist", "ads")])
        off.blockAds = false
        off.blockCookieBanners = false
        off.blockTrackers = false
        XCTAssertEqual(ContentBlockingRuleSets.togglesToTurnOff(in: off), [], "off toggles are left alone")
    }

    func testNoListsStatusShowsUnderTheToggles() {
        let lines = ContentBlockingSettingsSection.diagnosticsLines(for: state([], status: .noLists))
        XCTAssertEqual(lines, ["Nothing is blocked until a rule set is downloaded."])
        XCTAssertEqual(ContentBlockingSettingsSection.diagnosticsLines(for: state([], status: .active)), [])
    }
}

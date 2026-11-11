// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// The tab-group operations `BrowserState` hands Chromium when it groups a
/// tab opened from a link. Existing group code still calls the bridge
/// directly.
protocol TabGroupBridging {
    /// Creates a tab group from `tabIds` in the window `windowId`, named
    /// `title` (nil keeps Chromium's default). Returns the group's token, or
    /// nil when Chromium refused the batch.
    func createGroup(tabIds: [Int], title: String?, windowId: Int) -> String?
    /// Adds `tabIds` to the group `token` in the window `windowId`.
    func addTabs(_ tabIds: [Int], toGroup token: String, windowId: Int)
}

/// Forwards to the live Chromium bridge.
struct LiveTabGroupBridge: TabGroupBridging {
    func createGroup(tabIds: [Int], title: String?, windowId: Int) -> String? {
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else { return nil }
        let token = bridge.createGroupFromTabs(withWindowId: Int64(windowId),
                                               tabIds: tabIds.map { NSNumber(value: Int64($0)) },
                                               title: title,
                                               color: nil)
        return token.isEmpty ? nil : token
    }

    func addTabs(_ tabIds: [Int], toGroup token: String, windowId: Int) {
        ChromiumLauncher.sharedInstance().bridge?.addTabsToGroup(withWindowId: Int64(windowId),
                                                                 tabIds: tabIds.map { NSNumber(value: Int64($0)) },
                                                                 tokenHex: token)
    }
}

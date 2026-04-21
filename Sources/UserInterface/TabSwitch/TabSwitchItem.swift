// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

struct TabSwitchItem {
    let tabID: Int
    let title: String
    let snapshotImage: NSImage?
    /// From `Tab.liveFaviconData` only, matching `TabViewModel.liveFaviconImage`.
    let liveFaviconImage: NSImage?
    /// Page URL for `FaviconDataProvider` when `liveFaviconImage` is nil; same role as `faviconLoadURL ?? url` in `UnifiedTabFaviconView`.
    let faviconPageURL: String?
    let isCurrentTab: Bool
}

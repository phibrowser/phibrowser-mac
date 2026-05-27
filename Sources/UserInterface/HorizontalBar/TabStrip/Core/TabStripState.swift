// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

struct TabRenderData: Equatable {
    var id: String
    var title: String
    var url: String
    var isActive: Bool
    var isPinned: Bool
    /// Position within a Chromium split pair, if any. Drives merged-bar shape.
    /// Invariant: when `pinnedSplitPartner` is non-nil this is forced to nil
    /// — the merged pinned cell stands alone visually and must not double up
    /// with the paired-bar styling. Construct via `splitRender(...)` to
    /// honor the invariant rather than setting both fields directly.
    var splitPairPosition: SplitPairPosition?
    /// True when the split this tab belongs to contains the focusing tab.
    /// Both pair members render with the active-group fill in that case.
    /// Same invariant as above: false when `pinnedSplitPartner` is non-nil.
    var isSplitGroupActive: Bool
    /// Set on the `.first` pane of a pinned split so a single pinned cell can
    /// render both panes' favicons side-by-side. The horizontal strip uses
    /// this to satisfy the "two icons in one cell" presentation; nil for
    /// normal tabs and non-first panes.
    weak var pinnedSplitPartner: Tab?

    // `sourceTab` is intentionally excluded from `Equatable`.
    weak var sourceTab: Tab?
    static func == (lhs: TabRenderData, rhs: TabRenderData) -> Bool {
        return lhs.id == rhs.id &&
            lhs.title == rhs.title &&
            lhs.url == rhs.url &&
            lhs.isActive == rhs.isActive &&
            lhs.isPinned == rhs.isPinned &&
            lhs.splitPairPosition == rhs.splitPairPosition &&
            lhs.isSplitGroupActive == rhs.isSplitGroupActive &&
            lhs.pinnedSplitPartner?.uniqueId == rhs.pinnedSplitPartner?.uniqueId
    }
}

/// Builder for the three mutually-related split-render fields on
/// `TabRenderData`. Centralizes the rule "a pinned-merged cell hides the
/// paired-bar styling" so individual call sites don't open-code the
/// `partner != nil ? nil : ...` ternaries.
struct TabSplitRender {
    let position: SplitPairPosition?
    let isGroupActive: Bool
    weak var pinnedMergedPartner: Tab?

    static func standalone(position: SplitPairPosition?, isGroupActive: Bool) -> TabSplitRender {
        TabSplitRender(position: position,
                       isGroupActive: isGroupActive,
                       pinnedMergedPartner: nil)
    }

    static func pinnedMerged(partner: Tab) -> TabSplitRender {
        TabSplitRender(position: nil,
                       isGroupActive: false,
                       pinnedMergedPartner: partner)
    }
}

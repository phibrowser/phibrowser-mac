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
    var isMultiSelected: Bool = false
    /// Position within a Chromium split, if any. Drives the merged-bar shape
    /// a split renders with when its panes stay separate cells.
    /// Invariant: when `mergedSplitPanes` is non-empty this is forced to nil
    /// — the merged cell stands alone visually and must not double up with
    /// the bar styling. Construct via `TabSplitRender` to honor the
    /// invariant rather than setting both fields directly.
    var splitPanePosition: SplitPanePosition?
    /// True when the split this tab belongs to contains the focusing tab.
    /// Every pane renders with the active-group fill in that case.
    /// Same invariant as above: false when `mergedSplitPanes` is non-empty.
    var isSplitGroupActive: Bool
    /// The other panes of the split this cell hosts, in on-screen order
    /// (one to `SplitGroup.maxPaneCount - 1`). Set on the first pane of a
    /// merged split so a single cell renders every pane's favicon; empty
    /// for standalone tabs and for the collapsed non-host panes.
    var mergedSplitPanes: [Tab] = []

    // `sourceTab` is intentionally excluded from `Equatable`.
    weak var sourceTab: Tab?
    static func == (lhs: TabRenderData, rhs: TabRenderData) -> Bool {
        return lhs.id == rhs.id &&
            lhs.title == rhs.title &&
            lhs.url == rhs.url &&
            lhs.isActive == rhs.isActive &&
            lhs.isPinned == rhs.isPinned &&
            lhs.isMultiSelected == rhs.isMultiSelected &&
            lhs.splitPanePosition == rhs.splitPanePosition &&
            lhs.isSplitGroupActive == rhs.isSplitGroupActive &&
            lhs.mergedSplitPanes.map(\.uniqueId) == rhs.mergedSplitPanes.map(\.uniqueId)
    }
}

/// Builder for the three mutually-related split-render fields on
/// `TabRenderData`. Centralizes the rule "a merged cell hides the bar
/// styling" so individual call sites don't open-code the
/// `panes.isEmpty ? position : nil` ternaries.
struct TabSplitRender {
    let position: SplitPanePosition?
    let isGroupActive: Bool
    /// The other panes rendered inside this cell; empty unless merged.
    let mergedPanes: [Tab]

    static func standalone(position: SplitPanePosition?, isGroupActive: Bool) -> TabSplitRender {
        TabSplitRender(position: position,
                       isGroupActive: isGroupActive,
                       mergedPanes: [])
    }

    static func merged(panes: [Tab]) -> TabSplitRender {
        TabSplitRender(position: nil,
                       isGroupActive: false,
                       mergedPanes: panes)
    }
}

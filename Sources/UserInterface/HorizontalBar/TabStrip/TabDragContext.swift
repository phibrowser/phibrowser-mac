// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

enum TabContainerType {
    case pinned
    case normal
}

/// Stores the source and current target state for an active tab drag.
final class TabDragContext {
    // MARK: - Source State

    /// Dragged tab.
    let draggingTab: Tab
    /// Original container type.
    let sourceContainerType: TabContainerType
    /// Original index.
    let sourceIndex: Int
    /// Mouse location at drag start in tab-strip coordinates.
    let initialMouseLocation: CGPoint
    /// Source tab frame in container coordinates.
    let initialTabFrame: CGRect
    /// Width of the dragged tab, used when sizing the gap.
    let draggedTabWidth: CGFloat
    /// Index of the dragged tab's split partner in the same zone, if any.
    /// Set so the partner lifts alongside the dragged tab and the layout
    /// engine excludes both indices.
    let siblingSourceIndex: Int?

    // MARK: - Target State

    /// Current destination container type.
    var targetContainerType: TabContainerType
    /// Current destination index.
    var targetIndex: Int
    /// When `targetIndex` falls at a tab-group's leading edge (= the
    /// group's first member's index in `normalTabs`), this flag
    /// records whether the cursor sits on the chip's left half. The
    /// layout engine uses it to decide whether the drag-gap opens
    /// *before* the chip (chip slides right to make room) or *after*
    /// the chip (chip stays, first member slides right).
    var gapBeforeRunStartChip: Bool = false

    /// Token of the chip that `gapBeforeRunStartChip` is "about" —
    /// i.e. the leadingChip from the previous frame's gapBeforeChip
    /// computation. Used by foreign-chip prev-state branching to
    /// detect a chip change: when the new leadingChip differs from
    /// the stored token, the stale TRUE flag from a previous chip
    /// would otherwise carry into the new chip's TRUE branch and
    /// evaluate against the new chip's natural midX with proxy
    /// edges far past it, wrongly returning FALSE and preventing
    /// the new chip from letting way (multi-collapsed-chip bug).
    /// On chip change we reset to the FALSE branch (fresh prev-
    /// state for this chip).
    var gapBeforeRunStartChipToken: String?

    /// Token of the group whose leading edge the drop would attach
    /// the dragged tab to (= chip whose `firstMemberIndex` equals
    /// `targetIndex`, when the dragged tab isn't already in that
    /// group). Non-nil means a leading-edge auto-join is pending; nil
    /// means the drop wouldn't change the dragged tab's group
    /// membership at this position. Used by `hasPositionChanged` so
    /// drops that don't move the tab physically but DO change its
    /// group membership (e.g. dragging the tab immediately to the
    /// left of a chip onto the chip's region) still take the commit
    /// path instead of being silently cancelled.
    var targetGroupForLeadingJoin: String?

    /// Token of the dragged tab's *own* group when the cursor sits
    /// on that group's chip's left half or further left
    /// (`cursor.x < chip.midX`). Symmetric to
    /// `targetGroupForLeadingJoin`: this represents the "leave the
    /// group via leading edge" intent that the geometric auto-leave
    /// check (`toIndex < lowerBound`) cannot detect when the group
    /// is at the strip's leading edge — there `lowerBound` is 0 and
    /// no toIndex can be less. Threshold mirrors
    /// `gapBeforeRunStartChip` so visual and commit agree: the same
    /// cursor position that opens the gap before the chip also
    /// detaches from the group. Drop-handler reads this to fire
    /// `removeTabsFromGroup`. Also feeds `hasPositionChanged` so
    /// drag-out drops that would otherwise be no-ops (e.g. dragging
    /// the FIRST member to the left of its own chip, where
    /// `targetIndex == sourceIndex + 1`) still take the commit path.
    var targetGroupForLeadingLeave: String?

    /// Token of the dragged tab's *own* group when the cursor sits
    /// past the right edge of the group's last visible member
    /// (`cursor.x >= lastMember.frame.maxX`). Symmetric counterpart
    /// to `targetGroupForLeadingLeave`: represents "leave the group
    /// via trailing edge" intent that the geometric auto-leave check
    /// (`toIndex > upperBound + 1`) cannot detect when the cursor is
    /// in the slot immediately after the group's last member but
    /// hasn't yet crossed the next tab's midX (or when no such next
    /// tab exists). Drop-handler reads this to fire
    /// `removeTabsFromGroup`. Also feeds `hasPositionChanged` so
    /// drag-out drops with no positional change still take the
    /// commit path.
    var targetGroupForTrailingLeave: String?

    /// Token of a foreign group whose last visible member z is
    /// covered ≥50% by the dragged tab's frame AND whose drop slot
    /// (toIndex == upperBound + 1) is the current target. Mirrors
    /// `targetGroupForLeadingJoin` for the trailing edge: drop here
    /// auto-joins the dragged tab to that group as its new last
    /// member. Visual feedback comes from `groupGeometries`
    /// extending the run's `rightX` past z to include the drop slot
    /// while this token is set.
    var targetGroupForTrailingJoin: String?

    /// Current mouse location in tab-strip coordinates.
    var currentMouseLocation: CGPoint

    // MARK: - Derived State

    /// Whether the drag crosses between pinned and normal zones.
    var isCrossZoneDrag: Bool {
        sourceContainerType != targetContainerType
    }

    var currentTabFrame: CGRect {
        var frame = initialTabFrame
        let deltaX = currentMouseLocation.x - initialMouseLocation.x
        frame.origin.x += deltaX
        return frame
    }

    /// Whether the drag would result in a real move OR a group
    /// membership change. Drops at the same physical slot as the
    /// source (`targetIndex == sourceIndex` or `sourceIndex + 1`)
    /// would normally be no-ops, but a leading-edge drop next to a
    /// chip can flip the dragged tab's group membership via the
    /// auto-join path — those need the commit path even though the
    /// position is unchanged.
    var hasPositionChanged: Bool {
        if isCrossZoneDrag {
            return true
        }
        if targetIndex != sourceIndex && targetIndex != sourceIndex + 1 {
            return true
        }
        return targetGroupForLeadingJoin != nil
            || targetGroupForLeadingLeave != nil
            || targetGroupForTrailingLeave != nil
            || targetGroupForTrailingJoin != nil
    }

    // MARK: - Init

    init(
        draggingTab: Tab,
        sourceContainerType: TabContainerType,
        sourceIndex: Int,
        initialMouseLocation: CGPoint,
        initialTabFrame: CGRect,
        siblingSourceIndex: Int? = nil
    ) {
        self.draggingTab = draggingTab
        self.sourceContainerType = sourceContainerType
        self.sourceIndex = sourceIndex
        self.initialMouseLocation = initialMouseLocation
        self.initialTabFrame = initialTabFrame
        self.draggedTabWidth = initialTabFrame.width
        self.siblingSourceIndex = siblingSourceIndex

        // Start with the source position as the initial target.
        self.targetContainerType = sourceContainerType
        self.targetIndex = sourceIndex
        self.currentMouseLocation = initialMouseLocation
    }
}

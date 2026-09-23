// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

/// Pending end-of-drag action for a whole-group drag. Computed each
/// frame by `TabGroupDragController.continueDragging` based on
/// cursor position; consumed by `endDragging` to dispatch the
/// correct commit path. Mirrors the same-window vs cross-window vs
/// tear-off split in single-tab drag (`TabStrip.PendingDropAction`).
enum PendingGroupDropAction {
    /// Cursor stayed inside the source tab strip. Commits via
    /// `BrowserState.moveNormalTabSlice` (existing path).
    case local
    /// Cursor entered another browser window's tab strip at a valid
    /// drop slot. Commits via `BrowserState.moveGroupSliceToWindow`.
    case external(ExternalGroupDropTarget)
    /// Cursor is over another browser window's tab strip BUT the
    /// resolved zone refuses the group (e.g., pinned region — groups
    /// can't be pinned). On release: cancel the drag, slice stays
    /// in the source window. Distinct from `.tearOff` so an
    /// accidental wander through the pinned zone doesn't spawn a
    /// new window.
    case rejected
    /// Cursor left all browser windows entirely. Commits via
    /// `BrowserState.moveGroupSliceToNewWindow` (creates a new
    /// browser window with the group).
    case tearOff
}

/// Resolved cross-window drop target for a whole-group drag. Built by
/// the source `TabStrip` from the target window's group-aware
/// `groupDropTarget(forScreenPoint:)`. `zone` is always `.normal`
/// (groups cannot land in the pinned region; pinned hits return nil
/// upstream); `index` is in target's `normalTabs` coordinate space.
struct ExternalGroupDropTarget {
    let windowController: SpaceSessionController
    let zone: TabContainerType
    let index: Int
}

/// Drag state for a whole tab-group drag. Parallel to `TabDragContext`
/// but slice-shaped — sources and target are slice boundaries, not a
/// single tab. Group membership is invariant during the drag; the
/// `targetGroupFor*` / `gapBeforeRunStartChip` fields of single-tab
/// drag have no meaning here and are intentionally absent.
final class TabGroupDragContext {
    // MARK: - Source

    /// Token of the group being dragged.
    let draggingChipToken: String
    /// Member guids in source order.
    let memberTabIds: [Int]
    /// Members' range in `normalTabOrder` at drag start: `[s, s+N)`.
    let sourceRange: Range<Int>
    /// Mouse position when drag started, in tab-strip coordinates.
    let initialMouseLocation: CGPoint
    /// Chip frame at drag start, in normalContainer coordinates with
    /// scroll offset added back (same space as `normalTabFrames`).
    let initialChipFrame: CGRect
    /// Slice's drawn width at drag start.
    /// - Collapsed: `chipW`.
    /// - Expanded: `chipW + Σ memberW + interior spacings`
    ///   (computed as `lastMemberFrame.maxX − chipFrame.minX`).
    let initialSliceWidth: CGFloat
    /// Whether the group was collapsed at drag start.
    let isCollapsedAtDragStart: Bool

    // MARK: - Target

    /// Valid insertion index in `normalTabOrder`. Initialized to
    /// `sourceRange.lowerBound` (no-op slot); updated by the
    /// controller's snap-target computation in later tasks.
    var targetIndex: Int
    /// Current mouse location in tab-strip coordinates.
    var currentMouseLocation: CGPoint
    /// Pending end-of-drag action; refreshed each frame by
    /// `TabGroupDragController.continueDragging`. Defaults to
    /// `.local` so a synchronous abort before the first
    /// `continueDragging` tick still routes through the same-window
    /// commit path (no-op when `hasPositionChanged == false`).
    var pendingDropAction: PendingGroupDropAction = .local

    /// Cached chip snapshot for the floating drag preview shown when
    /// the cursor leaves the source strip. Populated lazily at drag
    /// start by `TabStrip.applyChipPlacements`'s `onDragStart` callback
    /// (the chip view is the source for the image). Chip-only (no
    /// member tabs); per 2026-05-12 plan §Design Decision 1.
    var cachedChipDragImage: NSImage?

    /// Snap candidates computed once at drag-start from the natural
    /// pre-drag layout, with after-source positions pre-shifted left
    /// by `initialSliceWidth` so that each candidate's `x` reflects
    /// where the slice's left edge would land if dropped at that
    /// `index`. Caching ensures stability across the natural ↔
    /// excluded layout transition that fires during drag — the
    /// frames in `dragControllerRequestMetrics()` jump by sliceWidth
    /// across that boundary, which would otherwise oscillate the
    /// chosen snap target.
    let snapCandidates: [(index: Int, x: CGFloat)]
    /// Leftmost x-coordinate of the normal zone — also captured at
    /// drag-start. Used for pinned-region soft-clamping.
    let firstNormalSlotX: CGFloat
    /// `P_post − P_pre`: how far the chip's natural slot moved when
    /// temp-collapse triggered a relayout before snapshot. Subtracted
    /// from `deltaX` in `applyGroupDragTransforms` so the chip's
    /// visual position stays under the cursor where the user grabbed
    /// it. Zero when no relayout shift occurred.
    let chipPositionShift: CGFloat

    // MARK: - Derived

    /// X-coordinate of the proxy slice's left edge in normalContainer
    /// coordinates before any pinned-zone clamping.
    ///
    /// **Chip-leading drag semantic.** The proxy origin tracks the
    /// chip's left edge (`initialChipFrame.minX`) plus the mouse
    /// delta — NOT the slice's right edge or center. The slice's
    /// width is folded into snap candidate positions instead (via
    /// the `-sliceWidth` shift applied to after-source candidates
    /// in `TabGroupDragStartSnapshot.snapCandidates`), so the snap
    /// distance comparison cancels slice width out and the let-way
    /// crossover depends only on the neighbor's width:
    ///
    ///     deltaX_crossover ≈ (spacing + neighbor.width) / 2
    ///
    /// **Visual consequence:** wider slices visually overlap their
    /// neighbors more deeply before snap fires (because the slice's
    /// right edge sticks out `sliceWidth` past the chip, while only
    /// the chip's left needs to reach the neighbor's midpoint).
    /// Narrower slices feel tighter. This is symmetric for left/
    /// right neighbors and consistent with single-tab drag.
    ///
    /// **To change to slice-right-edge leading** (e.g. "trigger let-
    /// way when the slice's trailing edge covers half the neighbor"):
    /// add `+ initialSliceWidth` here AND remove the `-sliceWidth`
    /// shift from `snapCandidates`. Note that this makes left-side
    /// neighbors asymmetric (left neighbors still engage via chip's
    /// left edge but right neighbors engage via slice's right edge),
    /// so a fully symmetric rewrite needs to pick the closer slice
    /// edge per candidate direction.
    var currentSliceOriginX: CGFloat {
        let deltaX = currentMouseLocation.x - initialMouseLocation.x
        return initialChipFrame.minX + deltaX
    }

    /// True when committing the drag would actually move the slice.
    /// Slice semantics: any `t ∈ [s, s+N]` is a no-op — `t == s`
    /// keeps the slice in place, `t == s+N` inserts just past the
    /// slice's own right edge (same physical slot), and `t ∈ (s, s+N)`
    /// is degenerate (inserting into yourself).
    var hasPositionChanged: Bool {
        !(targetIndex >= sourceRange.lowerBound
          && targetIndex <= sourceRange.upperBound)
    }

    init(
        draggingChipToken: String,
        memberTabIds: [Int],
        sourceRange: Range<Int>,
        initialMouseLocation: CGPoint,
        initialChipFrame: CGRect,
        initialSliceWidth: CGFloat,
        isCollapsedAtDragStart: Bool,
        snapCandidates: [(index: Int, x: CGFloat)],
        firstNormalSlotX: CGFloat,
        chipPositionShift: CGFloat
    ) {
        self.draggingChipToken = draggingChipToken
        self.memberTabIds = memberTabIds
        self.sourceRange = sourceRange
        self.initialMouseLocation = initialMouseLocation
        self.initialChipFrame = initialChipFrame
        self.initialSliceWidth = initialSliceWidth
        self.isCollapsedAtDragStart = isCollapsedAtDragStart
        self.snapCandidates = snapCandidates
        self.firstNormalSlotX = firstNormalSlotX
        self.chipPositionShift = chipPositionShift
        self.targetIndex = sourceRange.lowerBound
        self.currentMouseLocation = initialMouseLocation
    }
}

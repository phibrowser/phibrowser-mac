// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

/// Snapshot returned by the strip when a group drag starts. The strip
/// owns the live geometry; the controller stays geometry-agnostic.
struct TabGroupDragStartSnapshot {
    let memberTabIds: [Int]
    let sourceRange: Range<Int>
    let chipFrame: CGRect
    let sliceWidth: CGFloat
    let isCollapsed: Bool
    /// Snap candidates pre-computed at drag-start to keep them stable
    /// across the natural ↔ excluded layout transition during drag.
    let snapCandidates: [(index: Int, x: CGFloat)]
    /// Leftmost normal-zone x for pinned soft-clamping.
    let firstNormalSlotX: CGFloat
    /// See `TabGroupDragContext.chipPositionShift`.
    let chipPositionShift: CGFloat
}

/// Delegate for whole-group drag. Parallel to `TabStripDragDelegate`,
/// slice-shaped.
protocol TabGroupDragDelegate: AnyObject {
    /// Build the start snapshot from the live layout. Return `nil` to
    /// veto the drag (e.g. token unknown, no live chip frame).
    func groupDragControllerSnapshot(token: String) -> TabGroupDragStartSnapshot?

    /// Requests a relayout reflecting the controller's current context.
    func groupDragControllerDidUpdate()

    /// Commits the slice move when dragging ends with a real position change.
    func groupDragControllerCommitMove(memberTabIds: [Int], to: Int)

    /// Commits a cross-window slice move when dragging ends over
    /// another browser window. Members are detached from THIS strip
    /// and re-attached to the target via Chromium's atomic group
    /// detach + insert (see `BrowserState.moveGroupSliceToWindow`).
    /// `atIndex` is in the target strip's `normalTabs` coordinate space.
    func groupDragControllerCommitMoveCrossWindow(
        memberTabIds: [Int],
        targetWindowController: SpaceSessionController,
        atIndex: Int
    )

    /// Tears off the slice into a brand-new Browser window. Chromium
    /// owns the new-window creation atomically; Mac only records the
    /// pending placement (`dropScreenLocation`) so the new window
    /// frames around the drop point when it appears via
    /// `.mainBrowserWindowCreated`.
    func groupDragControllerCommitTearOff(
        memberTabIds: [Int],
        dropScreenLocation: CGPoint
    )

    /// Cancels the drag and restores the original layout.
    func groupDragControllerDidCancel()

    /// Snapshot of the current `normalTabOrder`. Used by the controller
    /// for liveness checks (so a member-tab close mid-drag can abort
    /// cleanly rather than commit a stale slice).
    func groupDragControllerCurrentNormalTabOrder() -> [Int]

    /// Last-known screen-coordinate location of the dragging cursor.
    /// The controller takes mouse positions in tab-strip-local space,
    /// but cross-window hit-tests need screen coordinates. The strip
    /// owns the window↔screen conversion via `NSWindow.convertPoint`.
    /// Returns `nil` if no screen point has been observed yet (very
    /// first `continueDragging` tick before the first window/screen
    /// reading lands) — treat as "cursor still in source strip".
    func groupDragControllerCurrentScreenPoint() -> CGPoint?

    /// Resolve a screen point to a cross-window drop target on another
    /// browser window's tab strip. Returns `nil` when (a) `screenPoint`
    /// is over the source window, (b) `screenPoint` is over a window
    /// that rejects cross-window drags, or (c) the resolved zone is
    /// `.pinned` (groups cannot land in the pinned region).
    func groupDragControllerResolveExternalDropTarget(screenPoint: CGPoint) -> ExternalGroupDropTarget?

    /// Whether `screenPoint` is inside the source tab strip's drag
    /// boundary. Used to distinguish `.local` from `.tearOff` once the
    /// cross-window resolver has returned `nil`.
    func groupDragControllerIsInsideDragBoundary(screenPoint: CGPoint) -> Bool

    /// Whether `screenPoint` is over ANY non-source browser window's
    /// tab strip drag boundary (regardless of whether the position
    /// there is a valid drop slot for the group). Used to distinguish
    /// `.rejected` (over another window but no valid slot, e.g., the
    /// pinned region) from `.tearOff` (outside all browser windows).
    func groupDragControllerIsOverAnotherBrowserStrip(screenPoint: CGPoint) -> Bool
}

final class TabGroupDragController {
    weak var delegate: TabGroupDragDelegate?

    /// Active drag context, or `nil` when idle.
    private(set) var context: TabGroupDragContext?

    /// Whether a group drag is currently active.
    var isDragging: Bool { context != nil }

    /// Minimum horizontal mouse delta before a chip mouseDown is
    /// promoted from click-pending to active drag. Matches the chip
    /// view's internal threshold; declared here so callers can reason
    /// about the value.
    static let dragActivationThreshold: CGFloat = 4

    // MARK: - Lifecycle

    /// Capture source geometry and switch the strip into group-slice
    /// layout mode (layout-mode switching is wired in a later task).
    /// - Returns: `true` if the drag started.
    @discardableResult
    func startDragging(token: String, mouseLocation: CGPoint) -> Bool {
        guard context == nil else { return false }
        guard let snap = delegate?.groupDragControllerSnapshot(token: token) else {
            AppLogWarn("[TabGroupDrag] startDragging snapshot failed token=\(token)")
            return false
        }
        let ctx = TabGroupDragContext(
            draggingChipToken: token,
            memberTabIds: snap.memberTabIds,
            sourceRange: snap.sourceRange,
            initialMouseLocation: mouseLocation,
            initialChipFrame: snap.chipFrame,
            initialSliceWidth: snap.sliceWidth,
            isCollapsedAtDragStart: snap.isCollapsed,
            snapCandidates: snap.snapCandidates,
            firstNormalSlotX: snap.firstNormalSlotX,
            chipPositionShift: snap.chipPositionShift
        )
        context = ctx
        AppLogDebug(
            "[TabGroupDrag] startDragging token=\(token) " +
            "range=\(snap.sourceRange) members=\(snap.memberTabIds) " +
            "collapsed=\(snap.isCollapsed) sliceW=\(snap.sliceWidth)"
        )
        delegate?.groupDragControllerDidUpdate()
        return true
    }

    func continueDragging(mouseLocation: CGPoint) {
        guard let ctx = context, let delegate else { return }
        // Liveness check: if any member has been closed mid-drag (the
        // tab no longer appears in normalTabOrder), abort cleanly
        // rather than commit a stale slice on mouseUp.
        if !areMembersStillLive(ctx: ctx, delegate: delegate) {
            cancelDragging()
            return
        }
        let prevTargetIndex = ctx.targetIndex
        ctx.currentMouseLocation = mouseLocation

        // Resolve drop action by cursor position. Four-way branch:
        //   1. cursor over another window's strip at a valid slot   → .external
        //   2. cursor over another window's strip but invalid slot  → .rejected
        //      (e.g., pinned region — groups can't be pinned)
        //   3. cursor outside source strip AND outside all other
        //      windows' strips                                      → .tearOff
        //   4. cursor inside source strip                           → .local
        // When screen point is unknown (very first tick) treat as .local.
        let prevAction = ctx.pendingDropAction
        let nextAction: PendingGroupDropAction
        if let screenPoint = delegate.groupDragControllerCurrentScreenPoint() {
            if let target = delegate.groupDragControllerResolveExternalDropTarget(screenPoint: screenPoint) {
                nextAction = .external(target)
            } else if delegate.groupDragControllerIsOverAnotherBrowserStrip(screenPoint: screenPoint) {
                // Over another window's strip but target refused the
                // specific zone (e.g., pinned). Treat as silent
                // rejection — distinct from tear-off.
                nextAction = .rejected
            } else if !delegate.groupDragControllerIsInsideDragBoundary(screenPoint: screenPoint) {
                nextAction = .tearOff
            } else {
                nextAction = .local
            }
        } else {
            nextAction = .local
        }
        ctx.pendingDropAction = nextAction

        if !pendingDropActionsEqual(prevAction, nextAction) {
            AppLogDebug(
                "[TabGroupDrag] continueDragging action=" +
                "\(describe(prevAction))→\(describe(nextAction))"
            )
        }

        // Snap target only matters for .local; for .external / .tearOff
        // the destination index is computed elsewhere (target strip's
        // groupDropTarget for .external, irrelevant for .tearOff).
        // Skipping snap also avoids spurious "targetIndex=X→Y" logs
        // when the cursor is in another window.
        if case .local = nextAction, !ctx.snapCandidates.isEmpty {
            // Pinned soft-clamp: proxy can visually overshoot the
            // pinned/normal boundary but the snap target stays within
            // the normal zone.
            let proxyOriginX = max(ctx.firstNormalSlotX, ctx.currentSliceOriginX)

            var bestIdx = ctx.snapCandidates[0].index
            var bestDist = abs(ctx.snapCandidates[0].x - proxyOriginX)
            for cand in ctx.snapCandidates.dropFirst() {
                let d = abs(cand.x - proxyOriginX)
                if d < bestDist {
                    bestDist = d
                    bestIdx = cand.index
                }
            }
            ctx.targetIndex = bestIdx
        }

        if ctx.targetIndex != prevTargetIndex {
            AppLogDebug(
                "[TabGroupDrag] continueDragging targetIndex=" +
                "\(prevTargetIndex)→\(ctx.targetIndex)"
            )
        }

        delegate.groupDragControllerDidUpdate()
    }

    /// Equality for `PendingGroupDropAction` —  the enum has an
    /// associated-value case, so synthesized `Equatable` would require
    /// `ExternalGroupDropTarget: Equatable`. Manual compare avoids
    /// pulling Equatable through the target struct's window-controller
    /// reference.
    private func pendingDropActionsEqual(
        _ a: PendingGroupDropAction,
        _ b: PendingGroupDropAction
    ) -> Bool {
        switch (a, b) {
        case (.local, .local), (.tearOff, .tearOff), (.rejected, .rejected):
            return true
        case let (.external(la), .external(lb)):
            return la.windowController === lb.windowController
                && la.zone == lb.zone
                && la.index == lb.index
        default:
            return false
        }
    }

    private func describe(_ action: PendingGroupDropAction) -> String {
        switch action {
        case .local: return "local"
        case .external(let t):
            let win = t.windowController.browserState.windowId
            return "external(window=\(win), zone=\(t.zone), index=\(t.index))"
        case .rejected: return "rejected"
        case .tearOff: return "tearOff"
        }
    }

    /// - Returns: `true` if the drop committed a slice move.
    @discardableResult
    func endDragging(mouseLocation: CGPoint) -> Bool {
        guard let ctx = context else { return false }
        // Liveness check at drop time too — covers the case where a
        // member is closed between the last continueDragging and the
        // mouseUp.
        if let delegate, !areMembersStillLive(ctx: ctx, delegate: delegate) {
            cancelDragging()
            return false
        }
        ctx.currentMouseLocation = mouseLocation

        // Dispatch by drop action. Tear-off path still no-op pending
        // Task 5; .external commits via the cross-window delegate
        // hook which fires Chromium's atomic detach + insert.
        switch ctx.pendingDropAction {
        case .external(let target):
            AppLogDebug(
                "[TabGroupDrag] endDragging commit external " +
                "members=\(ctx.memberTabIds) " +
                "targetWindow=\(target.windowController.browserState.windowId) " +
                "zone=\(target.zone) atIndex=\(target.index)"
            )
            delegate?.groupDragControllerCommitMoveCrossWindow(
                memberTabIds: ctx.memberTabIds,
                targetWindowController: target.windowController,
                atIndex: target.index
            )
            context = nil
            delegate?.groupDragControllerDidUpdate()
            return true

        case .rejected:
            AppLogDebug(
                "[TabGroupDrag] endDragging rejected — target zone refused " +
                "members=\(ctx.memberTabIds); cancelling, slice stays in source"
            )
            context = nil
            delegate?.groupDragControllerDidCancel()
            return false

        case .tearOff:
            // Resolve drop screen point from the delegate. Required
            // for the new-window frame placement (see
            // `BrowserState.moveGroupSliceToNewWindow`). Fallback to
            // cancel if the delegate has no recorded screen point —
            // shouldn't happen in practice (continueDragging already
            // requires a screen point for the action to flip to
            // `.tearOff`) but bail safely rather than firing the
            // bridge without a placement.
            guard let dropScreen = delegate?.groupDragControllerCurrentScreenPoint() else {
                AppLogWarn(
                    "[TabGroupDrag] endDragging tear-off but no screen " +
                    "point; cancelling instead of committing"
                )
                context = nil
                delegate?.groupDragControllerDidCancel()
                return false
            }
            AppLogDebug(
                "[TabGroupDrag] endDragging commit tear-off " +
                "members=\(ctx.memberTabIds) dropScreen=\(dropScreen)"
            )
            delegate?.groupDragControllerCommitTearOff(
                memberTabIds: ctx.memberTabIds,
                dropScreenLocation: dropScreen
            )
            context = nil
            delegate?.groupDragControllerDidUpdate()
            return true

        case .local:
            break  // fall through to existing same-window commit
        }

        let committed: Bool
        if ctx.hasPositionChanged {
            AppLogDebug(
                "[TabGroupDrag] endDragging commit " +
                "members=\(ctx.memberTabIds) to=\(ctx.targetIndex)"
            )
            delegate?.groupDragControllerCommitMove(
                memberTabIds: ctx.memberTabIds,
                to: ctx.targetIndex
            )
            committed = true
        } else {
            AppLogDebug("[TabGroupDrag] endDragging no-op (t in source range)")
            committed = false
        }
        context = nil
        delegate?.groupDragControllerDidUpdate()
        return committed
    }

    func cancelDragging() {
        guard context != nil else { return }
        AppLogDebug("[TabGroupDrag] cancelDragging")
        context = nil
        delegate?.groupDragControllerDidCancel()
    }

    /// Returns `true` if every member in the active context is still
    /// present in the live `normalTabOrder`. Returns `false` when at
    /// least one member has been removed (e.g. tab close mid-drag).
    private func areMembersStillLive(ctx: TabGroupDragContext, delegate: TabGroupDragDelegate) -> Bool {
        let live = Set(delegate.groupDragControllerCurrentNormalTabOrder())
        for member in ctx.memberTabIds where !live.contains(member) {
            AppLogWarn(
                "[TabGroupDrag] member \(member) disappeared mid-drag " +
                "(members=\(ctx.memberTabIds)); aborting"
            )
            return false
        }
        return true
    }
}

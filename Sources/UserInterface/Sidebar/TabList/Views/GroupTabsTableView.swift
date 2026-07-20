// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

/// `NSTableView` subclass embedded inside `TabGroupCellView` to render the
/// member tabs of a Chromium tab group. Lives WITHOUT an enclosing
/// `NSScrollView` so the outer outline view stays the sole scroller.
/// Handles mouse gestures itself so grouped-tab drags can be started
/// from the outer outline view instead of AppKit's embedded-table drag
/// pipeline.
final class GroupTabsTableView: NSTableView {
    private static let dragThreshold: CGFloat = 5

    weak var phiTableDelegate: GroupTabsTableViewDelegate?
    private var pendingDragRow: Int?
    private var pendingDragStartPoint: NSPoint?
    /// When the user presses inside the SwiftUI close or mute control areas, `NSHostingView` may
    /// receive the mouse sequence but the SwiftUI `Button` actions do not run reliably in this
    /// embedded inner-table path. We detect control hits in `mouseDown`, store the target here,
    /// and on `mouseUp` (same row and matching target) dispatch `didRequest` instead of row
    /// activation. Non-nil also suppresses manual row drag so a press on those controls does not
    /// start a tab drag.
    private var pendingInteractionTarget: GroupTabsTableInteractionTarget?
    private var pendingMouseDownEvent: NSEvent?
    private var manualDragInProgress = false

    /// Pin the inner cell to the row's full rect so it always tracks
    /// `bounds.width`, regardless of `NSTableColumn.width`. The default
    /// implementation derives the cell rect from `column.width`, which
    /// can lag behind the table's actual bounds (autoresizing mask is
    /// proportional, and existing rows are not re-framed when we mutate
    /// `column.width` manually). This mirrors the pattern used in
    /// `SideBarOutlineView.frameOfCell` for tab-group rows.
    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        let rowRect = rect(ofRow: row)
        return NSRect(x: 0,
                      y: rowRect.minY,
                      width: rowRect.width - 4,
                      height: rowRect.height)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        pendingDragRow = row
        pendingDragStartPoint = point
        pendingInteractionTarget = interactionTarget(at: point, row: row)
        pendingMouseDownEvent = event
        manualDragInProgress = false
        AppLogDebug(
            "[TAB_GROUPS][INNER_DRAG] inner.mouseDown row=\(row) " +
            "windowPoint=\(event.locationInWindow)"
        )
    }

    override func mouseDragged(with event: NSEvent) {
        AppLogDebug(
            "[TAB_GROUPS][INNER_DRAG] inner.mouseDragged pendingRow=\(pendingDragRow ?? -1) " +
            "manual=\(manualDragInProgress)"
        )
        guard !manualDragInProgress,
              let row = pendingDragRow,
              let startPoint = pendingDragStartPoint,
              row >= 0,
              row < numberOfRows,
              let mouseDownEvent = pendingMouseDownEvent else {
            return
        }

        guard pendingInteractionTarget == nil else {
            return
        }

        let currentPoint = convert(event.locationInWindow, from: nil)
        let dx = abs(currentPoint.x - startPoint.x)
        let dy = abs(currentPoint.y - startPoint.y)
        guard dx > Self.dragThreshold || dy > Self.dragThreshold else {
            return
        }

        manualDragInProgress = true
        AppLogDebug("[TAB_GROUPS][INNER_DRAG] inner.beginManualDrag row=\(row)")
        phiTableDelegate?.tableView(self,
                                    beginDraggingRow: row,
                                    with: mouseDownEvent)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }

        let clickLocation = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: clickLocation)
        guard clickedRow >= 0 else { return }

        resetPendingDragState()
        phiTableDelegate?.tableView(self,
                                    didMiddleClickRow: clickedRow,
                                    at: clickLocation)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let operation = super.draggingUpdated(sender)
        // The inner table is not scroll-backed, so keep the outer outline view
        // responsible for edge cue visibility and autoscroll.
        enclosingSidebarOutlineView()?.updateDragAutoscrollCueVisibility()
        enclosingSidebarOutlineView()?.autoscrollNearEdgeIfNeeded(
            draggingLocationInWindow: sender.draggingLocation)
        return operation
    }

    override func wantsPeriodicDraggingUpdates() -> Bool {
        true
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let operation = super.draggingEntered(sender)
        enclosingSidebarOutlineView()?.updateDragAutoscrollCueVisibility()
        return operation
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        enclosingSidebarOutlineView()?.hideDragAutoscrollCue()
        super.draggingExited(sender)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        enclosingSidebarOutlineView()?.hideDragAutoscrollCue()
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        enclosingSidebarOutlineView()?.hideDragAutoscrollCue()
        super.concludeDragOperation(sender)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let upRow = row(at: point)
        let modifierFlags = pendingMouseDownEvent?.modifierFlags ?? event.modifierFlags
        if !manualDragInProgress,
           let clickedRow = pendingDragRow,
           clickedRow >= 0,
           clickedRow == upRow {
            let upTarget = interactionTarget(at: point, row: upRow)
            if let pendingInteractionTarget,
               pendingInteractionTarget == upTarget {
                phiTableDelegate?.tableView(self,
                                            didRequest: pendingInteractionTarget,
                                            row: clickedRow)
            } else if pendingInteractionTarget == nil {
                phiTableDelegate?.tableView(
                    self,
                    didClickRow: clickedRow,
                    modifierFlags: modifierFlags
                )
            }
        }
        resetPendingDragState()
        AppLogDebug("[TAB_GROUPS][INNER_DRAG] inner.mouseUp")
    }

    private func resetPendingDragState() {
        pendingDragRow = nil
        pendingDragStartPoint = nil
        pendingInteractionTarget = nil
        pendingMouseDownEvent = nil
        manualDragInProgress = false
    }

    private func interactionTarget(at point: NSPoint, row: Int) -> GroupTabsTableInteractionTarget? {
        guard row >= 0,
              let cellView = view(atColumn: 0,
                                  row: row,
                                  makeIfNecessary: false) as? SidebarTabCellView,
              let tab = cellView.item as? Tab else {
            return nil
        }

        let cellPoint = cellView.convert(point, from: self)
        let closeRect = NSRect(x: cellView.bounds.maxX - 32,
                               y: cellView.bounds.midY - 12,
                               width: 24,
                               height: 24)
        if closeRect.contains(cellPoint) {
            return .close
        }

        guard tab.isCurrentlyAudible || tab.isAudioMuted else {
            return nil
        }

        let mediaLeading = WebContentConstant.edgesSpacing + 6 + 16 + 8
        let muteRect = NSRect(x: mediaLeading,
                              y: cellView.bounds.midY - 12,
                              width: 24,
                              height: 24)
        if muteRect.contains(cellPoint) {
            return .mute
        }

        return nil
    }

    private func enclosingSidebarOutlineView() -> SideBarOutlineView? {
        var view = superview
        while let current = view {
            if let outlineView = current as? SideBarOutlineView {
                return outlineView
            }
            view = current.superview
        }
        return nil
    }
}

enum GroupTabsTableInteractionTarget: String {
    case close
    case mute
}

protocol GroupTabsTableViewDelegate: AnyObject {
    func tableView(_ tableView: GroupTabsTableView,
                   beginDraggingRow row: Int,
                   with event: NSEvent)
    func tableView(_ tableView: GroupTabsTableView,
                   didClickRow row: Int,
                   modifierFlags: NSEvent.ModifierFlags)
    func tableView(_ tableView: GroupTabsTableView,
                   didMiddleClickRow row: Int,
                   at location: NSPoint)
    func tableView(_ tableView: GroupTabsTableView,
                   didRequest target: GroupTabsTableInteractionTarget,
                   row: Int)
}

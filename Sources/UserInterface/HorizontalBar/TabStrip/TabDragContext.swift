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

    // MARK: - Target State

    /// Current destination container type.
    var targetContainerType: TabContainerType
    /// Current destination index.
    var targetIndex: Int
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

    /// Whether the drag would result in a real move.
    var hasPositionChanged: Bool {
        if isCrossZoneDrag {
            return true
        }
        // Adjacent insertion points inside the same zone are no-ops.
        return targetIndex != sourceIndex && targetIndex != sourceIndex + 1
    }

    // MARK: - Init

    init(
        draggingTab: Tab,
        sourceContainerType: TabContainerType,
        sourceIndex: Int,
        initialMouseLocation: CGPoint,
        initialTabFrame: CGRect
    ) {
        self.draggingTab = draggingTab
        self.sourceContainerType = sourceContainerType
        self.sourceIndex = sourceIndex
        self.initialMouseLocation = initialMouseLocation
        self.initialTabFrame = initialTabFrame
        self.draggedTabWidth = initialTabFrame.width

        // Start with the source position as the initial target.
        self.targetContainerType = sourceContainerType
        self.targetIndex = sourceIndex
        self.currentMouseLocation = initialMouseLocation
    }
}

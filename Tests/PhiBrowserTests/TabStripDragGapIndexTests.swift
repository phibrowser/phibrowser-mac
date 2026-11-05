// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

/// Tail-branch semantics of the drag gap-index resolvers: a drop past
/// every visible item must append after every RECORD, not after the last
/// visible one. Trailing zero-width records (a merged split pair's second
/// pane) sit between the two, and the old `lastVisible.index + 1` landed
/// between the pair's records — invisible on screen (both surfaces merge
/// the pair by partner guid) but persisted into the pinned record order.
@MainActor
final class TabStripDragGapIndexTests: XCTestCase {
    /// Repro shape: pinned records [A, host, secondary] with the pair at
    /// the zone end. A is dragged past the merged cell's right edge.
    func test_cursorGapIndexPastTrailingMergedPairAppendsAfterPair() {
        let controller = TabStripDragController()
        let frames = [
            CGRect(x: 0, y: 0, width: 28, height: 28),   // A (dragged, excluded)
            CGRect(x: 30, y: 0, width: 58, height: 28),  // merged pair host (wide)
            CGRect.zero,                                 // collapsed second pane
        ]

        let index = controller.calculateGapIndex(
            localX: 200,
            tabFrames: frames,
            excludedIndices: [0]
        )

        XCTAssertEqual(index, 3,
            "A drop past the trailing merged pair must append after the pair, not between its records.")
    }

    /// Normal-zone variant: edge-based resolver with the pair at the strip
    /// end and the dragged tab's proxy far to the right.
    func test_edgeBasedGapIndexPastTrailingMergedPairAppendsAfterPair() {
        let controller = TabStripDragController()
        let frames = [
            CGRect(x: 0, y: 0, width: 100, height: 32),    // dragged tab's slot
            CGRect(x: 102, y: 0, width: 100, height: 32),  // merged pair host
            CGRect.zero,                                   // collapsed second pane
        ]

        let index = controller.calculateGapIndexEdgeBased(
            xFrame: CGRect(x: 400, y: 0, width: 100, height: 32),
            tabFrames: frames,
            chipFrames: [],
            excludedIndices: [0],
            previousIndex: 0
        )

        XCTAssertEqual(index, 3,
            "An edge-based drop past the trailing merged pair must append after the pair, not between its records.")
    }

    func test_multiDragStartExcludesEveryRepresentedSourceIndex() {
        let controller = TabStripDragController()
        let delegate = RecordingTabStripDragDelegate()
        controller.delegate = delegate

        let tab = Tab(guid: 2,
                      url: "https://e2.example",
                      isActive: false,
                      index: 1)
        controller.startDragging(
            tab: tab,
            sourceIndex: 1,
            sourceZone: .normal,
            mouseLocation: .zero,
            tabFrame: CGRect(x: 110, y: 0, width: 100, height: 32),
            sourceExcludedIndices: [1, 3, 4],
            draggingTabIds: [2, 4, 5],
            draggingVisualSlotCount: 3
        )

        XCTAssertEqual(delegate.normalExcludedIndices, [1, 3, 4])
        XCTAssertEqual(delegate.normalGapIndex, 1)
        XCTAssertEqual(
            delegate.normalGapWidth ?? -1,
            TabStripDragController.dragGapWidth(perSlotWidth: 100, visualSlotCount: 3),
            accuracy: 0.001
        )
    }

    func test_singleDragStartUsesDefaultOneSlotGap() {
        let controller = TabStripDragController()
        let delegate = RecordingTabStripDragDelegate()
        controller.delegate = delegate

        let tab = Tab(guid: 2,
                      url: "https://e2.example",
                      isActive: false,
                      index: 1)
        controller.startDragging(
            tab: tab,
            sourceIndex: 1,
            sourceZone: .normal,
            mouseLocation: .zero,
            tabFrame: CGRect(x: 110, y: 0, width: 100, height: 32)
        )

        XCTAssertEqual(delegate.normalExcludedIndices, [1])
        XCTAssertEqual(delegate.normalGapIndex, 1)
        XCTAssertEqual(
            delegate.normalGapWidth ?? -1,
            TabStripDragController.dragGapWidth(perSlotWidth: 100, visualSlotCount: 1),
            accuracy: 0.001
        )
    }
}

private final class RecordingTabStripDragDelegate: TabStripDragDelegate {
    var normalExcludedIndices: Set<Int> = []
    var normalGapIndex: Int?
    var normalGapWidth: CGFloat?

    func dragControllerDidUpdateLayout(
        pinnedExcludedIndices: Set<Int>,
        pinnedGapIndex: Int?,
        normalExcludedIndices: Set<Int>,
        normalGapIndex: Int?,
        normalGapWidth: CGFloat?
    ) {
        self.normalExcludedIndices = normalExcludedIndices
        self.normalGapIndex = normalGapIndex
        self.normalGapWidth = normalGapWidth
    }

    func dragControllerRequestMetrics() -> TabStripMetricsSnapshot {
        TabStripMetricsSnapshot(
            pinnedContainerFrame: .zero,
            normalContainerFrame: CGRect(x: 0, y: 0, width: 600, height: 32),
            pinnedTabWidth: TabStripMetrics.PinnedTab.width,
            normalTabFrames: [
                CGRect(x: 0, y: 0, width: 100, height: 32),
                CGRect(x: 110, y: 0, width: 100, height: 32),
                CGRect(x: 220, y: 0, width: 100, height: 32),
                CGRect(x: 330, y: 0, width: 100, height: 32),
                CGRect(x: 440, y: 0, width: 100, height: 32),
                CGRect(x: 550, y: 0, width: 100, height: 32),
            ],
            pinnedTabFrames: [],
            normalScrollOffset: 0,
            chipFrames: [],
            draggedTabFrameInNormal: nil,
            normalSplitRuns: []
        )
    }

    func dragControllerDidEndDrag(tab: Tab, toZone: TabContainerType, toIndex: Int) {}

    func dragControllerDidCancelDrag() {}

    func dragControllerConvertPointToLocal(_ windowPoint: CGPoint) -> CGPoint {
        windowPoint
    }
}

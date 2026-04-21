// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

// MARK: - Realtime Reordering Notes
// This collection view reports the hovered item continuously during drag so the
// controller can update its local snapshot and let diffable data source animate
// the reorder in real time.
// The source item is hidden after the drag image is captured to avoid showing
// both the system drag preview and the original cell at the same time.
// `acceptDrop` still performs the final persistence step, including the
// existing off-by-one workaround in `movePinnedTab` for forward moves.

import AppKit

protocol ReorderingCollectionViewDelegate: AnyObject {
    func collectionView(_ collectionView: NSCollectionView, draggingInfo: NSDraggingInfo, movedTo indexPath: IndexPath)
    func collectionView(_ collectionView: NSCollectionView, draggingExited info: NSDraggingInfo?)
}

class ReorderingCollectionView: NSCollectionView {
    weak var reorderDelegate: ReorderingCollectionViewDelegate?
    private var lastDragTargetIndexPath: IndexPath?

    override func draggingUpdated(_ session: NSDraggingInfo) -> NSDragOperation {
        let point = self.convert(session.draggingLocation, from: nil)

        let targetIndexPath = indexPathForItem(at: point) ?? inferredTargetIndexPath(at: point)

        if let targetIndexPath, targetIndexPath != lastDragTargetIndexPath {
            lastDragTargetIndexPath = targetIndexPath
            reorderDelegate?.collectionView(self, draggingInfo: session, movedTo: targetIndexPath)
        }

        return super.draggingUpdated(session)
    }

    /// When the cursor is over empty space past the last item in a grid row,
    /// infer the intended drop target from layout geometry.
    private func inferredTargetIndexPath(at point: NSPoint) -> IndexPath? {
        for section in stride(from: numberOfSections - 1, through: 0, by: -1) {
            let count = numberOfItems(inSection: section)
            guard count > 0 else { continue }

            let lastIndexPath = IndexPath(item: count - 1, section: section)
            guard let lastAttrs = collectionViewLayout?.layoutAttributesForItem(at: lastIndexPath) else { continue }

            let isPastLastRow = point.y > lastAttrs.frame.maxY
            let isAfterLastItemInRow = point.y >= lastAttrs.frame.minY && point.x > lastAttrs.frame.maxX

            if isPastLastRow || isAfterLastItemInRow {
                return IndexPath(item: count, section: section)
            }
        }
        return nil
    }

    override func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        // Source-side tracking for pinned tabs: drive drag-image updates using cursor position.
        unsafeBrowserState?.tabDraggingSession.attachNativeSession(session)
        unsafeBrowserState?.tabDraggingSession.update(
            screenLocation: CGPoint(x: screenPoint.x, y: screenPoint.y)
        )
        super.draggingSession(session, movedTo: screenPoint)
    }
    
    override func draggingEnded(_ session: NSDraggingInfo) {
        self.lastDragTargetIndexPath = nil
        super.draggingEnded(session)
    }
    
    override func draggingExited(_ session: NSDraggingInfo?) {
        super.draggingExited(session)
        self.lastDragTargetIndexPath = nil
        reorderDelegate?.collectionView(self, draggingExited: session)
    }
}

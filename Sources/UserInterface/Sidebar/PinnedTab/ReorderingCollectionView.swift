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
    func collectionView(_ collectionView: NSCollectionView, extensionReorderOperationFor draggingInfo: NSDraggingInfo) -> NSDragOperation
    func collectionView(_ collectionView: NSCollectionView, acceptExtensionReorderDrop draggingInfo: NSDraggingInfo) -> Bool
}

class ReorderingCollectionView: NSCollectionView {
    weak var reorderDelegate: ReorderingCollectionViewDelegate?
    var capturesContextMenuClicks = false
    /// A scoped management surface can own drops, including empty-grid destinations.
    var managedDragOperation: ((NSDraggingInfo) -> NSDragOperation)?
    var managedDrop: ((NSDraggingInfo) -> Bool)?
    var managedDragExited: (() -> Void)?
    private var lastDragTargetIndexPath: IndexPath?

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Avoid collection-item lookups while AppKit is already resolving a
        // contextual event; walking the resolved hierarchy cannot re-enter hit testing.
        let hitView = super.hitTest(point)
        guard capturesContextMenuClicks,
              ContextMenuEvent.isMouseDown(NSApp.currentEvent),
              let hitView else {
            return hitView
        }

        var candidate: NSView? = hitView
        while let view = candidate, view !== self {
            if view.menu != nil, !view.isHidden, view.alphaValue > 0 {
                return view
            }
            candidate = view.superview
        }
        return hitView
    }

    // Pinned-extension reorders bypass NSCollectionView's dropping machinery
    // entirely: its internal drop-target inference reports "no destination"
    // over the shelf's empty strips (right of a sparse last row, the row
    // gaps), returning .none and firing draggingExited while the pointer is
    // still inside the view — the drop delegate is never consulted there.
    // The shelf's geometry belongs to the controller, so route this drag
    // type straight to it, the same shape as the sidebar address bar's
    // ExtensionReorderStackView. Every other type keeps the stock path.
    private func isExtensionReorder(_ info: NSDraggingInfo) -> Bool {
        info.draggingPasteboard.string(forType: .phiPinnedExtensionReorder) != nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if let managedDragOperation { return managedDragOperation(sender) }
        guard !isExtensionReorder(sender) else {
            return reorderDelegate?.collectionView(self, extensionReorderOperationFor: sender) ?? []
        }
        return super.draggingEntered(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let managedDragOperation { return !managedDragOperation(sender).isEmpty }
        guard !isExtensionReorder(sender) else { return true }
        return super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let managedDrop { return managedDrop(sender) }
        guard !isExtensionReorder(sender) else {
            return reorderDelegate?.collectionView(self, acceptExtensionReorderDrop: sender) ?? false
        }
        return super.performDragOperation(sender)
    }

    override func draggingUpdated(_ session: NSDraggingInfo) -> NSDragOperation {
        if let managedDragOperation { return managedDragOperation(session) }
        guard !isExtensionReorder(session) else {
            return reorderDelegate?.collectionView(self, extensionReorderOperationFor: session) ?? []
        }
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
        // Source-side tracking for pinned tabs: drive drag-image updates using
        // cursor position. Pinned-extension reorders are surface-local and
        // never engage the tab dragging session.
        if managedDragOperation == nil, session.draggingPasteboard.string(forType: .phiPinnedExtensionReorder) == nil {
            unsafeBrowserState?.tabDraggingSession.attachNativeSession(session)
            unsafeBrowserState?.tabDraggingSession.update(
                screenLocation: CGPoint(x: screenPoint.x, y: screenPoint.y)
            )
        }
        super.draggingSession(session, movedTo: screenPoint)
    }
    
    override func draggingEnded(_ session: NSDraggingInfo) {
        managedDragExited?()
        self.lastDragTargetIndexPath = nil
        super.draggingEnded(session)
    }
    
    override func draggingExited(_ session: NSDraggingInfo?) {
        super.draggingExited(session)
        managedDragExited?()
        self.lastDragTargetIndexPath = nil
        reorderDelegate?.collectionView(self, draggingExited: session)
    }
}

// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

class DiffableOutlineView: NSOutlineView {
    private struct ReloadRequest {
        let snapshot: DiffableOutlineSnapshot<AnyHashable>
        let animated: Bool
        let updateDataSource: () -> Void
        let prepareReloadData: (() -> Void)?
        let completion: (() -> Void)?
    }

    private var currentSnapshot: DiffableOutlineSnapshot<AnyHashable>?
    private var isApplyingSnapshot = false
    private var pendingReloadRequest: ReloadRequest?

    func reloadWith(
        _ snapshot: DiffableOutlineSnapshot<AnyHashable>,
        animated: Bool = true,
        updateDataSource: @escaping () -> Void,
        prepareReloadData: (() -> Void)? = nil,
        completion: (() -> Void)? = nil
    ) {
        let request = ReloadRequest(
            snapshot: snapshot,
            animated: animated,
            updateDataSource: updateDataSource,
            prepareReloadData: prepareReloadData,
            completion: completion
        )

        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.applyOrQueue(request)
            }
            return
        }

        applyOrQueue(request)
    }

    private func applyOrQueue(_ request: ReloadRequest) {
        guard !isApplyingSnapshot else {
            pendingReloadRequest = request
            return
        }

        apply(request)
        applyPendingReloads()
    }

    private func applyPendingReloads() {
        while !isApplyingSnapshot, let request = pendingReloadRequest {
            pendingReloadRequest = nil
            apply(request)
        }
    }

    private func apply(_ request: ReloadRequest) {
        if let validationError = request.snapshot.validationError {
            reportInvalidSnapshot(validationError)
            request.completion?()
            return
        }

        guard let oldSnapshot = currentSnapshot else {
            request.updateDataSource()
            request.prepareReloadData?()
            reloadData()
            currentSnapshot = request.snapshot
            request.completion?()
            return
        }

        let plan = DiffableOutlineDiffPlanner.plan(from: oldSnapshot, to: request.snapshot)
        guard plan.isSafe else {
            request.updateDataSource()
            request.prepareReloadData?()
            reloadData()
            currentSnapshot = request.snapshot
            request.completion?()
            return
        }

        isApplyingSnapshot = true
        request.updateDataSource()
        apply(plan.operations, oldSnapshot: oldSnapshot, newSnapshot: request.snapshot, animated: request.animated)
        currentSnapshot = request.snapshot
        isApplyingSnapshot = false

        DispatchQueue.main.async {
            request.completion?()
        }
    }

    func resetDiffableSnapshot(_ snapshot: DiffableOutlineSnapshot<AnyHashable>? = nil) {
        currentSnapshot = snapshot
    }

    func reportInvalidSnapshot(_ error: DiffableOutlineSnapshotValidationError<AnyHashable>) {
        AppLogWarn("[DiffableOutlineView] invalid snapshot: \(error)")
#if DEBUG
        assertionFailure("Invalid DiffableOutlineSnapshot: \(error)")
#endif
    }

    func applyRemove(
        at indexes: IndexSet,
        inParent parent: Any?,
        animation: NSOutlineView.AnimationOptions
    ) {
        removeItems(at: indexes, inParent: parent, withAnimation: animation)
    }

    func applyInsert(
        at indexes: IndexSet,
        inParent parent: Any?,
        animation: NSOutlineView.AnimationOptions
    ) {
        insertItems(at: indexes, inParent: parent, withAnimation: animation)
    }

    func applyMove(
        from fromIndex: Int,
        inParent oldParent: Any?,
        to toIndex: Int,
        inParent newParent: Any?
    ) {
        moveItem(at: fromIndex, inParent: oldParent, to: toIndex, inParent: newParent)
    }

    func applyReload(rowIndexes: IndexSet) {
        guard !rowIndexes.isEmpty, numberOfColumns > 0 else { return }
        reloadData(forRowIndexes: rowIndexes, columnIndexes: IndexSet(integersIn: 0..<numberOfColumns))
    }

    private func apply(
        _ operations: [DiffableOutlineOperation<AnyHashable>],
        oldSnapshot: DiffableOutlineSnapshot<AnyHashable>,
        newSnapshot: DiffableOutlineSnapshot<AnyHashable>,
        animated: Bool
    ) {
        guard !operations.isEmpty else { return }

        let animation: NSOutlineView.AnimationOptions = animated ? [.effectFade, .effectGap] : []
        beginUpdates()
        for operation in operations {
            apply(
                operation,
                oldSnapshot: oldSnapshot,
                newSnapshot: newSnapshot,
                animation: animation
            )
        }
        endUpdates()
    }

    private func apply(
        _ operation: DiffableOutlineOperation<AnyHashable>,
        oldSnapshot: DiffableOutlineSnapshot<AnyHashable>,
        newSnapshot: DiffableOutlineSnapshot<AnyHashable>,
        animation: NSOutlineView.AnimationOptions
    ) {
        switch operation {
        case .remove(_, let parentID, let index):
            applyRemove(
                at: IndexSet(integer: index),
                inParent: oldSnapshot.item(forOptionalID: parentID),
                animation: animation
            )
        case .move(_, let parentID, let from, let to):
            let parent = oldSnapshot.item(forOptionalID: parentID)
            applyMove(from: from, inParent: parent, to: to, inParent: parent)
        case .insert(_, let parentID, let index):
            applyInsert(
                at: IndexSet(integer: index),
                inParent: newSnapshot.item(forOptionalID: parentID),
                animation: animation
            )
        case .replace(_, let parentID, let index):
            applyRemove(
                at: IndexSet(integer: index),
                inParent: oldSnapshot.item(forOptionalID: parentID),
                animation: animation
            )
            applyInsert(
                at: IndexSet(integer: index),
                inParent: newSnapshot.item(forOptionalID: parentID),
                animation: animation
            )
        case .reload(let id):
            guard let item = newSnapshot.item(for: id) else { return }
            let row = row(forItem: item)
            guard row >= 0 else { return }
            applyReload(rowIndexes: IndexSet(integer: row))
        }
    }
}

private extension DiffableOutlineSnapshot where ItemID == AnyHashable {
    func item(forOptionalID id: ItemID?) -> AnyObject? {
        guard let id else { return nil }
        return item(for: id)
    }
}

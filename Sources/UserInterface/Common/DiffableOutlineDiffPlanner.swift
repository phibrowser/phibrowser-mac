// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

enum DiffableOutlineOperation<ItemID: Hashable>: Equatable {
    case remove(id: ItemID, parentID: ItemID?, index: Int)
    case move(id: ItemID, parentID: ItemID?, from: Int, to: Int)
    case insert(id: ItemID, parentID: ItemID?, index: Int)
    case replace(id: ItemID, parentID: ItemID?, index: Int)
    case reload(id: ItemID)
}

struct DiffableOutlinePlan<ItemID: Hashable> {
    let operations: [DiffableOutlineOperation<ItemID>]
    let isSafe: Bool

    static var unsafe: DiffableOutlinePlan<ItemID> {
        DiffableOutlinePlan(operations: [], isSafe: false)
    }
}

enum DiffableOutlineDiffPlanner {
    static func plan<ItemID: Hashable>(
        from old: DiffableOutlineSnapshot<ItemID>,
        to new: DiffableOutlineSnapshot<ItemID>
    ) -> DiffableOutlinePlan<ItemID> {
        guard old.validationError == nil, new.validationError == nil else {
            return .unsafe
        }

        let oldIDs = Set(old.nodes.keys)
        let newIDs = Set(new.nodes.keys)
        let removedIDs = oldIDs.subtracting(newIDs)
        let insertedIDs = newIDs.subtracting(oldIDs)

        let highestRemoved = Set(removedIDs.filter { !old.hasAncestor(of: $0, in: removedIDs) })
        let highestInserted = Set(insertedIDs.filter { !new.hasAncestor(of: $0, in: insertedIDs) })
        let structuralChanges = structuralOperations(
            old: old,
            new: new,
            highestRemoved: highestRemoved,
            highestInserted: highestInserted
        )

        return DiffableOutlinePlan(operations: structuralChanges, isSafe: true)
    }

    private static func structuralOperations<ItemID: Hashable>(
        old: DiffableOutlineSnapshot<ItemID>,
        new: DiffableOutlineSnapshot<ItemID>,
        highestRemoved: Set<ItemID>,
        highestInserted: Set<ItemID>
    ) -> [DiffableOutlineOperation<ItemID>] {
        var removes: [DiffableOutlineOperation<ItemID>] = []
        var inserts: [DiffableOutlineOperation<ItemID>] = []

        for parentID in parentIDsForSiblingDiff(old: old, new: new) {
            let oldChildren = old.childIDs(of: parentID)
            let newChildren = new.childIDs(of: parentID)
            guard oldChildren != newChildren else { continue }

            let difference = newChildren.difference(from: oldChildren)
            for change in difference {
                switch change {
                case .remove(let offset, let id, _):
                    guard highestRemoved.contains(id) else { continue }
                    removes.append(.remove(id: id, parentID: parentID, index: offset))
                case .insert(let offset, let id, _):
                    guard highestInserted.contains(id) else { continue }
                    inserts.append(.insert(id: id, parentID: parentID, index: offset))
                }
            }
        }

        return sortedRemoves(removes, in: old) + sortedInserts(inserts, in: new)
    }

    private static func parentIDsForSiblingDiff<ItemID: Hashable>(
        old: DiffableOutlineSnapshot<ItemID>,
        new: DiffableOutlineSnapshot<ItemID>
    ) -> [ItemID?] {
        let parentIDs = Set([nil] + old.nodes.keys.map(Optional.some) + new.nodes.keys.map(Optional.some))
        return parentIDs.sorted { lhs, rhs in
            String(describing: lhs) < String(describing: rhs)
        }
    }

    private static func sortedRemoves<ItemID: Hashable>(
        _ operations: [DiffableOutlineOperation<ItemID>],
        in snapshot: DiffableOutlineSnapshot<ItemID>
    ) -> [DiffableOutlineOperation<ItemID>] {
        operations.sorted { lhs, rhs in
            let left = removeSortKey(lhs, in: snapshot)
            let right = removeSortKey(rhs, in: snapshot)
            if left.depth != right.depth { return left.depth > right.depth }
            if left.parent != right.parent { return left.parent < right.parent }
            return left.index > right.index
        }
    }

    private static func sortedInserts<ItemID: Hashable>(
        _ operations: [DiffableOutlineOperation<ItemID>],
        in snapshot: DiffableOutlineSnapshot<ItemID>
    ) -> [DiffableOutlineOperation<ItemID>] {
        operations.sorted { lhs, rhs in
            let left = insertSortKey(lhs, in: snapshot)
            let right = insertSortKey(rhs, in: snapshot)
            if left.depth != right.depth { return left.depth < right.depth }
            if left.parent != right.parent { return left.parent < right.parent }
            return left.index < right.index
        }
    }

    private static func removeSortKey<ItemID: Hashable>(
        _ operation: DiffableOutlineOperation<ItemID>,
        in snapshot: DiffableOutlineSnapshot<ItemID>
    ) -> (depth: Int, parent: String, index: Int) {
        guard case .remove(let id, let parentID, let index) = operation else {
            return (0, "", 0)
        }
        return (snapshot.depth(of: id), String(describing: parentID), index)
    }

    private static func insertSortKey<ItemID: Hashable>(
        _ operation: DiffableOutlineOperation<ItemID>,
        in snapshot: DiffableOutlineSnapshot<ItemID>
    ) -> (depth: Int, parent: String, index: Int) {
        guard case .insert(let id, let parentID, let index) = operation else {
            return (0, "", 0)
        }
        return (snapshot.depth(of: id), String(describing: parentID), index)
    }
}

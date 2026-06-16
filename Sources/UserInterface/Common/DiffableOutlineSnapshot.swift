// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

struct DiffableOutlineSnapshot<ItemID: Hashable> {
    struct Node {
        let id: ItemID
        let item: AnyObject
        let parentID: ItemID?
        let childIDs: [ItemID]
    }

    let rootIDs: [ItemID]
    let nodes: [ItemID: Node]
    let reloadIDs: Set<ItemID>

    init(rootIDs: [ItemID], nodes: [ItemID: Node], reloadIDs: Set<ItemID> = []) {
        self.rootIDs = rootIDs
        self.nodes = nodes
        self.reloadIDs = reloadIDs
    }

    var validationError: DiffableOutlineSnapshotValidationError<ItemID>? {
        validate()
    }

    func item(for id: ItemID) -> AnyObject? {
        nodes[id]?.item
    }

    func parentID(of id: ItemID) -> ItemID? {
        nodes[id]?.parentID
    }

    func childIDs(of parentID: ItemID?) -> [ItemID] {
        guard let parentID else { return rootIDs }
        return nodes[parentID]?.childIDs ?? []
    }

    func index(of id: ItemID) -> Int? {
        childIDs(of: parentID(of: id)).firstIndex(of: id)
    }

    func contains(_ id: ItemID) -> Bool {
        nodes[id] != nil
    }

    func depth(of id: ItemID) -> Int {
        var depth = 0
        var current = parentID(of: id)
        while let parent = current {
            depth += 1
            current = parentID(of: parent)
        }
        return depth
    }

    func descendants(of id: ItemID) -> [ItemID] {
        var result: [ItemID] = []

        func walk(_ current: ItemID) {
            for child in childIDs(of: current) {
                result.append(child)
                walk(child)
            }
        }

        walk(id)
        return result
    }

    func hasAncestor(of id: ItemID, in ids: Set<ItemID>) -> Bool {
        var current = parentID(of: id)
        while let parent = current {
            if ids.contains(parent) { return true }
            current = parentID(of: parent)
        }
        return false
    }

    private func validate() -> DiffableOutlineSnapshotValidationError<ItemID>? {
        var referencedIDs = Set<ItemID>()

        for rootID in rootIDs {
            guard nodes[rootID] != nil else { return .missingRoot(rootID) }
            if !referencedIDs.insert(rootID).inserted { return .duplicateChildID(rootID) }
            if nodes[rootID]?.parentID != nil { return .rootHasParent(rootID) }
        }

        for id in orderedNodeIDs {
            guard let node = nodes[id] else { continue }
            guard node.id == id else { return .nodeKeyMismatch(key: id, nodeID: node.id) }

            if let parentID = node.parentID, nodes[parentID] == nil {
                return .missingParent(id: id, parentID: parentID)
            }

            for childID in node.childIDs {
                guard let child = nodes[childID] else {
                    return .missingChild(id: id, childID: childID)
                }

                if child.parentID != id {
                    return .parentMismatch(
                        id: childID,
                        expectedParentID: id,
                        actualParentID: child.parentID
                    )
                }

                if !referencedIDs.insert(childID).inserted {
                    return .duplicateChildID(childID)
                }
            }
        }

        for id in orderedNodeIDs where !referencedIDs.contains(id) {
            if detectsCycle(startingAt: id) { return .cycleDetected(id) }
            if nodes[id]?.parentID == nil { return .unreachableNode(id) }
        }

        for id in orderedNodeIDs where detectsCycle(startingAt: id) {
            return .cycleDetected(id)
        }

        if let missingReloadID = reloadIDs.sortedForStableDiagnostics().first(where: { nodes[$0] == nil }) {
            return .missingReloadID(missingReloadID)
        }

        return nil
    }

    private var orderedNodeIDs: [ItemID] {
        nodes.keys.sortedForStableDiagnostics()
    }

    private func detectsCycle(startingAt id: ItemID) -> Bool {
        var seen = Set<ItemID>()
        var current: ItemID? = id
        while let next = current {
            if !seen.insert(next).inserted { return true }
            current = parentID(of: next)
        }
        return false
    }
}

enum DiffableOutlineSnapshotValidationError<ItemID: Hashable>: Error, Equatable {
    case missingRoot(ItemID)
    case rootHasParent(ItemID)
    case missingParent(id: ItemID, parentID: ItemID)
    case missingChild(id: ItemID, childID: ItemID)
    case parentMismatch(id: ItemID, expectedParentID: ItemID, actualParentID: ItemID?)
    case duplicateChildID(ItemID)
    case nodeKeyMismatch(key: ItemID, nodeID: ItemID)
    case unreachableNode(ItemID)
    case cycleDetected(ItemID)
    case missingReloadID(ItemID)
}

private extension Sequence where Element: Hashable {
    func sortedForStableDiagnostics() -> [Element] {
        sorted { String(describing: $0) < String(describing: $1) }
    }
}

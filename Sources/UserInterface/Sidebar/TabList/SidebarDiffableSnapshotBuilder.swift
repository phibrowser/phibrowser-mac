// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

struct SidebarDiffableSnapshotBuilder {
    struct VirtualInsertion {
        let item: SidebarItem
        let parentID: AnyHashable?
        let index: Int
    }

    let rootItems: [SidebarItem]
    var virtualInsertion: VirtualInsertion?
    var hiddenItemID: AnyHashable?

    init(
        rootItems: [SidebarItem],
        virtualInsertion: VirtualInsertion? = nil,
        hiddenItemID: AnyHashable? = nil
    ) {
        self.rootItems = rootItems
        self.virtualInsertion = virtualInsertion
        self.hiddenItemID = hiddenItemID
    }

    func makeSnapshot() -> DiffableOutlineSnapshot<AnyHashable> {
        var nodes: [AnyHashable: DiffableOutlineSnapshot<AnyHashable>.Node] = [:]
        var visited = Set<AnyHashable>()

        func append(_ item: SidebarItem, parentID: AnyHashable?) {
            guard visited.insert(item.id).inserted else { return }
            let children = children(of: item)
            nodes[item.id] = .init(
                id: item.id,
                item: item as AnyObject,
                parentID: parentID,
                childIDs: children.map(\.id)
            )
            for child in children {
                append(child, parentID: item.id)
            }
        }

        let roots = children(of: nil)
        for root in roots {
            append(root, parentID: nil)
        }

        return DiffableOutlineSnapshot(rootIDs: roots.map(\.id), nodes: nodes)
    }

    private func children(of parent: SidebarItem?) -> [SidebarItem] {
        let baseChildren: [SidebarItem]
        if let parent {
            guard parent.isExpandable else { return [] }
            baseChildren = parent.childrenItems
        } else {
            baseChildren = rootItems
        }

        var children = baseChildren
        if let hiddenItemID {
            children.removeAll { $0.id == hiddenItemID }
        }

        guard let virtualInsertion,
              virtualInsertion.parentID == parent?.id else {
            return children
        }

        let index = min(max(0, virtualInsertion.index), children.count)
        children.insert(virtualInsertion.item, at: index)
        return children
    }
}

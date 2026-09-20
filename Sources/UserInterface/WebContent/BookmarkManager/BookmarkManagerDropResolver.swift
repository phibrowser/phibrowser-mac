// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// A structural destination reported by the bookmark manager outline.
///
/// The controller translates AppKit's proposed item and child index into one
/// of these values. Keeping that translation outside the resolver makes the
/// validation independent of `NSDraggingInfo` and `NSOutlineView`.
enum BookmarkManagerDropTarget: Equatable {
    /// Dropping on a folder appends after its current children.
    case onFolder(guid: String)
    /// Dropping between children of a visible folder uses a pre-removal index.
    case betweenSiblings(parentGuid: String, index: Int)
    /// Dropping between top-level bookmarks persists with a nil parent GUID.
    case atRoot(index: Int)
}

/// The normalized batch mutation consumed by `BrowserState.moveSelectedBookmarks`.
struct BookmarkManagerDropPlan: Equatable {
    /// Unique GUIDs in the visual order captured when the drag began.
    let orderedBookmarkGuids: [String]
    /// Nil represents the current scope's hidden bookmark root.
    let destinationParentGuid: String?
    /// Pre-removal sibling index. The persistence layer owns final normalization.
    let destinationIndex: Int
}

enum BookmarkManagerDropRejection: Equatable {
    case searchActive
    case emptySelection
    case invalidRoot
    case missingBookmark(guid: String)
    case invalidTarget
    case invalidIndex
    case selfDrop
    case selectedTarget
    case folderDescendant
    case noOp
}

enum BookmarkManagerDropResolution: Equatable {
    case move(BookmarkManagerDropPlan)
    case rejected(BookmarkManagerDropRejection)
}

/// Resolves and validates bookmark-only structural drops against the source tree.
///
/// The result deliberately retains selected descendants in the ordered GUID
/// batch. `LocalStore.moveSelectedBookmarks` is authoritative for the existing
/// folder-plus-descendant behavior and commits the whole batch once.
enum BookmarkManagerDropResolver {
    static func resolve(
        orderedBookmarkGuids: [String],
        target: BookmarkManagerDropTarget,
        rootFolder: Bookmark,
        isSearchActive: Bool,
        destinationRootFolder: Bookmark? = nil
    ) -> BookmarkManagerDropResolution {
        guard !isSearchActive else {
            return .rejected(.searchActive)
        }

        let orderedGuids = deduplicated(orderedBookmarkGuids)
        guard !orderedGuids.isEmpty else {
            return .rejected(.emptySelection)
        }
        guard let tree = TreeIndex(rootFolder: rootFolder) else {
            return .rejected(.invalidRoot)
        }

        for guid in orderedGuids {
            guard guid != tree.rootGuid,
                  tree.nodesByGuid[guid] != nil else {
                return .rejected(.missingBookmark(guid: guid))
            }
        }

        guard let destinationTree = TreeIndex(rootFolder: destinationRootFolder ?? rootFolder) else {
            return .rejected(.invalidRoot)
        }
        let destination: Destination
        switch target {
        case .onFolder(let guid):
            guard guid != destinationTree.rootGuid,
                  let folder = destinationTree.nodesByGuid[guid],
                  folder.isFolder,
                  let children = destinationTree.childrenByParentGuid[guid] else {
                return .rejected(.invalidTarget)
            }
            destination = Destination(
                treeParentGuid: guid,
                persistedParentGuid: guid,
                index: children.count
            )

        case .betweenSiblings(let parentGuid, let index):
            guard parentGuid != destinationTree.rootGuid,
                  let parent = destinationTree.nodesByGuid[parentGuid],
                  parent.isFolder,
                  let children = destinationTree.childrenByParentGuid[parentGuid] else {
                return .rejected(.invalidTarget)
            }
            guard (0...children.count).contains(index) else {
                return .rejected(.invalidIndex)
            }
            destination = Destination(
                treeParentGuid: parentGuid,
                persistedParentGuid: parentGuid,
                index: index
            )

        case .atRoot(let index):
            let children = destinationTree.childrenByParentGuid[destinationTree.rootGuid] ?? []
            guard (0...children.count).contains(index) else {
                return .rejected(.invalidIndex)
            }
            destination = Destination(
                treeParentGuid: destinationTree.rootGuid,
                persistedParentGuid: nil,
                index: index
            )
        }

        let selectedGuids = Set(orderedGuids)
        if selectedGuids.contains(destination.treeParentGuid) {
            if orderedGuids.count == 1,
               orderedGuids[0] == destination.treeParentGuid {
                return .rejected(.selfDrop)
            }
            return .rejected(.selectedTarget)
        }

        for guid in orderedGuids {
            guard tree.nodesByGuid[guid]?.isFolder == true else { continue }
            if tree.isDescendant(destination.treeParentGuid, of: guid) {
                return .rejected(.folderDescendant)
            }
        }

        let selectedRootGuids = tree.selectedRootGuids(
            from: orderedGuids,
            selectedGuids: selectedGuids
        )
        if tree.rootGuid == destinationTree.rootGuid, tree.isNoOp(
            selectedRootGuids: selectedRootGuids,
            destinationParentGuid: destination.treeParentGuid,
            destinationIndex: destination.index
        ) {
            return .rejected(.noOp)
        }

        return .move(
            BookmarkManagerDropPlan(
                orderedBookmarkGuids: orderedGuids,
                destinationParentGuid: destination.persistedParentGuid,
                destinationIndex: destination.index
            )
        )
    }

    private struct Destination {
        let treeParentGuid: String
        let persistedParentGuid: String?
        let index: Int
    }

    private struct TreeIndex {
        let rootGuid: String
        let nodesByGuid: [String: Bookmark]
        let parentGuidByGuid: [String: String]
        let childrenByParentGuid: [String: [String]]

        init?(rootFolder: Bookmark) {
            guard rootFolder.isFolder else { return nil }

            var nodesByGuid: [String: Bookmark] = [:]
            var parentGuidByGuid: [String: String] = [:]
            var childrenByParentGuid: [String: [String]] = [:]
            var foundDuplicateGuid = false

            func visit(_ bookmark: Bookmark, parentGuid: String?) {
                guard nodesByGuid[bookmark.guid] == nil else {
                    foundDuplicateGuid = true
                    return
                }

                nodesByGuid[bookmark.guid] = bookmark
                if let parentGuid {
                    parentGuidByGuid[bookmark.guid] = parentGuid
                }
                childrenByParentGuid[bookmark.guid] = bookmark.children.map(\.guid)

                for child in bookmark.children {
                    visit(child, parentGuid: bookmark.guid)
                }
            }

            visit(rootFolder, parentGuid: nil)
            guard !foundDuplicateGuid else { return nil }

            self.rootGuid = rootFolder.guid
            self.nodesByGuid = nodesByGuid
            self.parentGuidByGuid = parentGuidByGuid
            self.childrenByParentGuid = childrenByParentGuid
        }

        func isDescendant(_ candidateGuid: String, of ancestorGuid: String) -> Bool {
            var currentGuid = parentGuidByGuid[candidateGuid]
            while let guid = currentGuid {
                if guid == ancestorGuid {
                    return true
                }
                currentGuid = parentGuidByGuid[guid]
            }
            return false
        }

        func selectedRootGuids(
            from orderedGuids: [String],
            selectedGuids: Set<String>
        ) -> [String] {
            orderedGuids.filter { guid in
                var currentGuid = parentGuidByGuid[guid]
                while let parentGuid = currentGuid {
                    if selectedGuids.contains(parentGuid) {
                        return false
                    }
                    currentGuid = parentGuidByGuid[parentGuid]
                }
                return true
            }
        }

        /// Mirrors the persistence layer's pre-removal index adjustment without
        /// mutating the tree. A placement is a no-op only when every selected
        /// root already has the destination parent and the resulting sibling
        /// order would remain identical.
        func isNoOp(
            selectedRootGuids: [String],
            destinationParentGuid: String,
            destinationIndex: Int
        ) -> Bool {
            guard !selectedRootGuids.isEmpty,
                  selectedRootGuids.allSatisfy({
                      parentGuidByGuid[$0] == destinationParentGuid
                  }) else {
                return false
            }

            let currentChildren = childrenByParentGuid[destinationParentGuid] ?? []
            let selectedRootSet = Set(selectedRootGuids)
            let boundedIndex = min(destinationIndex, currentChildren.count)
            let movingRootsBeforeDestination = currentChildren
                .prefix(boundedIndex)
                .filter { selectedRootSet.contains($0) }
                .count
            let adjustedIndex = destinationIndex - movingRootsBeforeDestination

            var resultingChildren = currentChildren.filter {
                !selectedRootSet.contains($0)
            }
            let insertionIndex = min(max(0, adjustedIndex), resultingChildren.count)
            resultingChildren.insert(contentsOf: selectedRootGuids, at: insertionIndex)
            return resultingChildren == currentChildren
        }
    }

    private static func deduplicated(_ guids: [String]) -> [String] {
        var seen = Set<String>()
        return guids.filter { seen.insert($0).inserted }
    }
}

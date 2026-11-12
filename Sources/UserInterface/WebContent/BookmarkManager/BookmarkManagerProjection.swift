// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// A pure outline projection of one explicitly scoped bookmark tree.
///
/// Item identity includes the source scope so a future scope switch cannot
/// accidentally preserve selection or animation state for an unrelated item
/// that happens to use the same bookmark GUID.
struct BookmarkManagerProjection {
    struct ItemID: Hashable {
        let scope: BookmarkManagementScope
        let guid: String
    }

    enum Mode: Equatable {
        case tree
        case search(query: String)
    }

    /// Values that can change without changing an item's structural identity.
    /// Comparing these captured values lets the outline reload visible cells
    /// while continuing to store the existing `Bookmark` object in its nodes.
    struct DisplaySignature: Equatable {
        let title: String
        let url: String?
        let secondaryTitle: String?
        let secondaryURL: String?
        let extraPanes: [SplitBookmarkExtraPane]
        let faviconURL: String?
        let cachedFaviconData: Data?
        let liveFaviconData: Data?
        let isFolder: Bool
        let childCount: Int

        init(bookmark: Bookmark) {
            title = bookmark.title
            url = bookmark.url
            secondaryTitle = bookmark.secondaryTitle
            secondaryURL = bookmark.secondaryUrl
            extraPanes = bookmark.splitExtraPanes
            faviconURL = bookmark.faviconUrl
            cachedFaviconData = bookmark.cachedFaviconData
            liveFaviconData = bookmark.liveFaviconData
            isFolder = bookmark.isFolder
            childCount = bookmark.children.count
        }
    }

    let scope: BookmarkManagementScope
    let mode: Mode
    let rootIDs: [ItemID]
    let bookmarksByID: [ItemID: Bookmark]
    let displaySignatures: [ItemID: DisplaySignature]
    let snapshot: DiffableOutlineSnapshot<AnyHashable>

    /// Creates either the source hierarchy or a flat search result projection.
    ///
    /// - Parameters:
    ///   - previous: The last committed projection. Visible items whose display
    ///     signature changed are included in the new snapshot's `reloadIDs`.
    static func make(
        scope: BookmarkManagementScope,
        rootBookmarks: [Bookmark],
        searchText: String = "",
        previous: BookmarkManagerProjection? = nil
    ) -> BookmarkManagerProjection {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let mode: Mode = query.isEmpty ? .tree : .search(query: query)

        var rootIDs: [ItemID] = []
        var bookmarksByID: [ItemID: Bookmark] = [:]
        var signatures: [ItemID: DisplaySignature] = [:]
        var nodes: [AnyHashable: DiffableOutlineSnapshot<AnyHashable>.Node] = [:]

        func register(_ bookmark: Bookmark, parentID: ItemID?, childIDs: [ItemID]) {
            let id = ItemID(scope: scope, guid: bookmark.guid)
            bookmarksByID[id] = bookmark
            signatures[id] = DisplaySignature(bookmark: bookmark)
            nodes[AnyHashable(id)] = .init(
                id: AnyHashable(id),
                item: bookmark,
                parentID: parentID.map(AnyHashable.init),
                childIDs: childIDs.map(AnyHashable.init)
            )
        }

        switch mode {
        case .tree:
            func appendTree(_ bookmark: Bookmark, parentID: ItemID?) {
                let id = ItemID(scope: scope, guid: bookmark.guid)
                let childIDs = bookmark.children.map {
                    ItemID(scope: scope, guid: $0.guid)
                }
                register(bookmark, parentID: parentID, childIDs: childIDs)
                for child in bookmark.children {
                    appendTree(child, parentID: id)
                }
            }

            rootIDs = rootBookmarks.map { ItemID(scope: scope, guid: $0.guid) }
            for bookmark in rootBookmarks {
                appendTree(bookmark, parentID: nil)
            }

        case .search(let query):
            func appendSearchMatches(_ bookmark: Bookmark) {
                if matches(bookmark, query: query) {
                    let id = ItemID(scope: scope, guid: bookmark.guid)
                    rootIDs.append(id)
                    register(bookmark, parentID: nil, childIDs: [])
                }
                for child in bookmark.children {
                    appendSearchMatches(child)
                }
            }

            for bookmark in rootBookmarks {
                appendSearchMatches(bookmark)
            }
        }

        let reloadIDs = Set(signatures.compactMap { id, signature -> AnyHashable? in
            guard previous?.displaySignatures[id] != nil,
                  previous?.displaySignatures[id] != signature else {
                return nil
            }
            return AnyHashable(id)
        })
        let snapshot = DiffableOutlineSnapshot<AnyHashable>(
            rootIDs: rootIDs.map(AnyHashable.init),
            nodes: nodes,
            reloadIDs: reloadIDs
        )

        return BookmarkManagerProjection(
            scope: scope,
            mode: mode,
            rootIDs: rootIDs,
            bookmarksByID: bookmarksByID,
            displaySignatures: signatures,
            snapshot: snapshot
        )
    }

    func bookmark(for id: ItemID) -> Bookmark? {
        bookmarksByID[id]
    }

    func itemID(for bookmark: Bookmark) -> ItemID {
        ItemID(scope: scope, guid: bookmark.guid)
    }

    private static func matches(_ bookmark: Bookmark, query: String) -> Bool {
        let searchableValues: [String?] = [
            bookmark.title,
            bookmark.url,
            bookmark.secondaryTitle,
            bookmark.secondaryUrl,
        ] + bookmark.splitExtraPanes.flatMap { [$0.title, Optional($0.url)] }
        return searchableValues.compactMap { $0 }.contains { value in
            value.range(
                of: query,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: nil,
                locale: .current
            ) != nil
        }
    }
}

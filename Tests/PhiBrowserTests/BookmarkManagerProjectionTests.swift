// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class BookmarkManagerProjectionTests: XCTestCase {
    private let scope = BookmarkManagementScope(
        accountId: "account-1",
        profileId: "profile-1",
        spaceId: "space-1"
    )

    func testTreeProjectionPreservesSourceHierarchyOrderAndBookmarkInstances() {
        let firstLeaf = Bookmark(guid: "leaf-1", title: "First", url: "https://first.example")
        let secondLeaf = Bookmark(guid: "leaf-2", title: "Second", url: "https://second.example")
        let folder = Bookmark(guid: "folder", title: "Folder", isFolder: true)
        folder.addChild(firstLeaf)
        folder.addChild(secondLeaf)
        let rootLeaf = Bookmark(guid: "root-leaf", title: "Root", url: "https://root.example")

        let projection = BookmarkManagerProjection.make(
            scope: scope,
            rootBookmarks: [folder, rootLeaf]
        )
        let folderID = projection.itemID(for: folder)
        let firstLeafID = projection.itemID(for: firstLeaf)
        let secondLeafID = projection.itemID(for: secondLeaf)
        let rootLeafID = projection.itemID(for: rootLeaf)

        XCTAssertEqual(projection.mode, .tree)
        XCTAssertEqual(projection.rootIDs, [folderID, rootLeafID])
        XCTAssertEqual(
            projection.snapshot.childIDs(of: AnyHashable(folderID)),
            [AnyHashable(firstLeafID), AnyHashable(secondLeafID)]
        )
        XCTAssertEqual(projection.snapshot.parentID(of: AnyHashable(firstLeafID)), AnyHashable(folderID))
        XCTAssertTrue(projection.snapshot.item(for: AnyHashable(folderID)) === folder)
        XCTAssertTrue(projection.snapshot.item(for: AnyHashable(firstLeafID)) === firstLeaf)
        XCTAssertTrue(projection.bookmark(for: secondLeafID) === secondLeaf)
        XCTAssertNil(projection.snapshot.validationError)
    }

    func testWhitespaceOnlySearchUsesTreeProjection() {
        let folder = Bookmark(guid: "folder", title: "Folder", isFolder: true)
        folder.addChild(Bookmark(guid: "leaf", title: "Leaf", url: "https://leaf.example"))

        let projection = BookmarkManagerProjection.make(
            scope: scope,
            rootBookmarks: [folder],
            searchText: "  \n\t "
        )

        XCTAssertEqual(projection.mode, .tree)
        XCTAssertEqual(projection.snapshot.childIDs(of: AnyHashable(projection.itemID(for: folder))).count, 1)
    }

    func testSearchIsLocalizedCaseAndDiacriticInsensitiveAndReturnsFlatDepthFirstRows() {
        let titleMatch = Bookmark(guid: "title", title: "Résumé Notes", url: "https://notes.example")
        let secondaryMatch = Bookmark(
            guid: "split",
            title: "Mail",
            url: "https://mail.example",
            secondaryUrl: "https://calendar.example/RÉSUMÉ",
            secondaryTitle: "Calendar"
        )
        let nestedFolder = Bookmark(guid: "nested", title: "Nested", isFolder: true)
        nestedFolder.addChild(secondaryMatch)
        let parent = Bookmark(guid: "parent", title: "Parent", isFolder: true)
        parent.addChild(titleMatch)
        parent.addChild(nestedFolder)
        let rootMatch = Bookmark(guid: "root", title: "A resume checklist", url: "https://root.example")

        let projection = BookmarkManagerProjection.make(
            scope: scope,
            rootBookmarks: [parent, rootMatch],
            searchText: "  resume  "
        )

        XCTAssertEqual(projection.mode, .search(query: "resume"))
        XCTAssertEqual(
            projection.rootIDs.map(\.guid),
            [titleMatch.guid, secondaryMatch.guid, rootMatch.guid]
        )
        for id in projection.rootIDs {
            XCTAssertNil(projection.snapshot.parentID(of: AnyHashable(id)))
            XCTAssertTrue(projection.snapshot.childIDs(of: AnyHashable(id)).isEmpty)
        }
        XCTAssertNil(projection.snapshot.validationError)
    }

    func testSearchMatchesFolderAndSecondaryTitleWithoutMakingFolderExpandable() {
        let child = Bookmark(guid: "child", title: "Child", url: "https://child.example")
        let folder = Bookmark(guid: "folder", title: "Design Archive", isFolder: true)
        folder.addChild(child)
        let split = Bookmark(
            guid: "split",
            title: "Mail",
            url: "https://mail.example",
            secondaryUrl: "https://tasks.example",
            secondaryTitle: "Design Board"
        )

        let projection = BookmarkManagerProjection.make(
            scope: scope,
            rootBookmarks: [folder, split],
            searchText: "design"
        )
        let folderID = projection.itemID(for: folder)

        XCTAssertEqual(projection.rootIDs.map(\.guid), [folder.guid, split.guid])
        XCTAssertTrue(projection.snapshot.childIDs(of: AnyHashable(folderID)).isEmpty)
        XCTAssertEqual(projection.displaySignatures[folderID]?.childCount, 1)
    }

    func testExtraPanesParticipateInSearchAndReloads() {
        let bookmark = Bookmark(title: "First", url: "https://first.example",
                                secondaryUrl: "https://second.example",
                                splitExtraPanes: [
                                    SplitBookmarkExtraPane(url: "https://third.example", title: "Third"),
                                    SplitBookmarkExtraPane(url: "https://fourth.example", title: "Fourth"),
                                ])
        for query in ["Third", "fourth.example"] {
            let result = BookmarkManagerProjection.make(scope: scope, rootBookmarks: [bookmark], searchText: query)
            XCTAssertEqual(result.rootIDs.map(\.guid), [bookmark.guid])
        }
        let previous = BookmarkManagerProjection.make(scope: scope, rootBookmarks: [bookmark])
        bookmark.splitExtraPanes.removeLast()
        let current = BookmarkManagerProjection.make(scope: scope, rootBookmarks: [bookmark], previous: previous)
        XCTAssertTrue(current.snapshot.reloadIDs.contains(AnyHashable(current.itemID(for: bookmark))))
    }

    func testItemIdentityIncludesScopeAndBookmarkGUID() {
        let bookmark = Bookmark(guid: "shared-guid", title: "Shared", url: "https://shared.example")
        let first = BookmarkManagerProjection.make(scope: scope, rootBookmarks: [bookmark])
        let otherScope = BookmarkManagementScope(
            accountId: scope.accountId,
            profileId: scope.profileId,
            spaceId: "space-2"
        )
        let second = BookmarkManagerProjection.make(scope: otherScope, rootBookmarks: [bookmark])

        XCTAssertNotEqual(first.rootIDs, second.rootIDs)
        XCTAssertEqual(first.rootIDs.first?.guid, second.rootIDs.first?.guid)
    }

    func testChangedDisplaySignaturesReloadExistingItemsWithoutReplacingThem() {
        let leaf = Bookmark(guid: "leaf", title: "Before", url: "https://before.example")
        let unchanged = Bookmark(guid: "unchanged", title: "Stable", url: "https://stable.example")
        let folder = Bookmark(guid: "folder", title: "Folder", isFolder: true)
        folder.addChild(leaf)
        folder.addChild(unchanged)
        let previous = BookmarkManagerProjection.make(scope: scope, rootBookmarks: [folder])

        leaf.title = "After"
        leaf.url = "https://after.example"
        leaf.updateCachedFaviconData(Data([1, 2, 3]), persist: false)
        let added = Bookmark(guid: "added", title: "Added", url: "https://added.example")
        folder.addChild(added)
        let current = BookmarkManagerProjection.make(
            scope: scope,
            rootBookmarks: [folder],
            previous: previous
        )
        let leafID = current.itemID(for: leaf)
        let folderID = current.itemID(for: folder)
        let unchangedID = current.itemID(for: unchanged)

        XCTAssertEqual(
            current.snapshot.reloadIDs,
            Set([AnyHashable(leafID), AnyHashable(folderID)])
        )
        XCTAssertFalse(current.snapshot.reloadIDs.contains(AnyHashable(unchangedID)))
        XCTAssertTrue(current.snapshot.item(for: AnyHashable(leafID)) === leaf)
        XCTAssertTrue(current.snapshot.item(for: AnyHashable(folderID)) === folder)
        XCTAssertNil(current.snapshot.validationError)
    }
}

// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class BookmarkManagerDropResolverTests: XCTestCase {
    func testOrderedBatchIsDeduplicatedWithoutChangingVisualOrder() {
        let tree = makeTree()

        let resolution = resolve(
            ["leaf-c", "leaf-a", "leaf-c"],
            target: .onFolder(guid: "folder-b"),
            tree: tree
        )

        XCTAssertEqual(
            resolution,
            .move(
                BookmarkManagerDropPlan(
                    orderedBookmarkGuids: ["leaf-c", "leaf-a"],
                    destinationParentGuid: "folder-b",
                    destinationIndex: 1
                )
            )
        )
    }

    func testDropOnFolderAppendsAfterExistingChildren() {
        let tree = makeTree()

        let resolution = resolve(
            ["leaf-a"],
            target: .onFolder(guid: "folder-a"),
            tree: tree
        )

        XCTAssertEqual(
            resolution,
            .move(
                BookmarkManagerDropPlan(
                    orderedBookmarkGuids: ["leaf-a"],
                    destinationParentGuid: "folder-a",
                    destinationIndex: 2
                )
            )
        )
    }

    func testDropBetweenSiblingsKeepsPreRemovalParentAndIndex() {
        let tree = makeTree()

        let resolution = resolve(
            ["leaf-a"],
            target: .betweenSiblings(parentGuid: "folder-a", index: 1),
            tree: tree
        )

        XCTAssertEqual(
            resolution,
            .move(
                BookmarkManagerDropPlan(
                    orderedBookmarkGuids: ["leaf-a"],
                    destinationParentGuid: "folder-a",
                    destinationIndex: 1
                )
            )
        )
    }

    func testRootInsertionUsesNilPersistedParent() {
        let tree = makeTree()

        let resolution = resolve(
            ["nested-a"],
            target: .atRoot(index: 1),
            tree: tree
        )

        XCTAssertEqual(
            resolution,
            .move(
                BookmarkManagerDropPlan(
                    orderedBookmarkGuids: ["nested-a"],
                    destinationParentGuid: nil,
                    destinationIndex: 1
                )
            )
        )
    }

    func testSingleFolderDroppedOnItselfIsRejected() {
        let tree = makeTree()

        let resolution = resolve(
            ["folder-a"],
            target: .onFolder(guid: "folder-a"),
            tree: tree
        )

        XCTAssertEqual(resolution, .rejected(.selfDrop))
    }

    func testFolderDroppedIntoDescendantIsRejected() {
        let tree = makeTree()

        let resolution = resolve(
            ["folder-a"],
            target: .onFolder(guid: "nested-folder"),
            tree: tree
        )

        XCTAssertEqual(resolution, .rejected(.folderDescendant))
    }

    func testBatchDroppedOnSelectedFolderIsRejected() {
        let tree = makeTree()

        let resolution = resolve(
            ["leaf-a", "folder-b"],
            target: .onFolder(guid: "folder-b"),
            tree: tree
        )

        XCTAssertEqual(resolution, .rejected(.selectedTarget))
    }

    func testSameParentBatchAtCurrentPlacementIsRejectedAsNoOp() {
        let tree = makeTree()

        let resolution = resolve(
            ["nested-a", "nested-folder"],
            target: .onFolder(guid: "folder-a"),
            tree: tree
        )

        XCTAssertEqual(resolution, .rejected(.noOp))
    }

    func testSameParentReorderWithDifferentResultProducesMove() {
        let tree = makeTree()

        let resolution = resolve(
            ["nested-folder"],
            target: .betweenSiblings(parentGuid: "folder-a", index: 0),
            tree: tree
        )

        XCTAssertEqual(
            resolution,
            .move(
                BookmarkManagerDropPlan(
                    orderedBookmarkGuids: ["nested-folder"],
                    destinationParentGuid: "folder-a",
                    destinationIndex: 0
                )
            )
        )
    }

    func testSelectedAncestorAndDescendantRemainInCommitBatch() {
        let tree = makeTree()

        let resolution = resolve(
            ["folder-a", "nested-a"],
            target: .onFolder(guid: "folder-b"),
            tree: tree
        )

        XCTAssertEqual(
            resolution,
            .move(
                BookmarkManagerDropPlan(
                    orderedBookmarkGuids: ["folder-a", "nested-a"],
                    destinationParentGuid: "folder-b",
                    destinationIndex: 1
                )
            )
        )
    }

    func testStructuralDropIsRejectedWhileSearchIsActive() {
        let tree = makeTree()

        let resolution = resolve(
            ["leaf-a"],
            target: .atRoot(index: 0),
            tree: tree,
            isSearchActive: true
        )

        XCTAssertEqual(resolution, .rejected(.searchActive))
    }

    func testNonFolderAndOutOfBoundsTargetsAreRejected() {
        let tree = makeTree()

        XCTAssertEqual(
            resolve(
                ["leaf-a"],
                target: .onFolder(guid: "leaf-b"),
                tree: tree
            ),
            .rejected(.invalidTarget)
        )
        XCTAssertEqual(
            resolve(
                ["leaf-a"],
                target: .atRoot(index: 10),
                tree: tree
            ),
            .rejected(.invalidIndex)
        )
    }

    func testCrossSpaceDropResolvesAgainstDestinationTree() {
        let source = makeTree()
        let destination = folder(guid: "destination-root")
        let target = folder(guid: "destination-folder")
        target.addChild(bookmark(guid: "existing"))
        destination.addChild(target)
        let result = BookmarkManagerDropResolver.resolve(
            orderedBookmarkGuids: ["folder-a", "nested-a"],
            target: .onFolder(guid: target.guid), rootFolder: source,
            isSearchActive: false, destinationRootFolder: destination)
        XCTAssertEqual(result, .move(BookmarkManagerDropPlan(
            orderedBookmarkGuids: ["folder-a", "nested-a"],
            destinationParentGuid: target.guid, destinationIndex: 1)))
        XCTAssertEqual(source.children.map(\.guid), ["leaf-a", "folder-a", "leaf-b", "folder-b"])
    }

    func testCrossSpaceDropRejectsMissingSourceAndForeignTarget() {
        let source = makeTree()
        let destination = folder(guid: "destination-root")
        XCTAssertEqual(BookmarkManagerDropResolver.resolve(
            orderedBookmarkGuids: ["missing"], target: .atRoot(index: 0),
            rootFolder: source, isSearchActive: false, destinationRootFolder: destination),
            .rejected(.missingBookmark(guid: "missing")))
        XCTAssertEqual(BookmarkManagerDropResolver.resolve(
            orderedBookmarkGuids: ["leaf-a"], target: .onFolder(guid: "folder-a"),
            rootFolder: source, isSearchActive: false, destinationRootFolder: destination),
            .rejected(.invalidTarget))
    }

    private func resolve(
        _ orderedGuids: [String],
        target: BookmarkManagerDropTarget,
        tree: Bookmark,
        isSearchActive: Bool = false
    ) -> BookmarkManagerDropResolution {
        BookmarkManagerDropResolver.resolve(
            orderedBookmarkGuids: orderedGuids,
            target: target,
            rootFolder: tree,
            isSearchActive: isSearchActive
        )
    }

    /// Tree order:
    /// root
    /// - leaf-a
    /// - folder-a
    ///   - nested-a
    ///   - nested-folder
    ///     - deep-a
    /// - leaf-b
    /// - folder-b
    ///   - leaf-c
    private func makeTree() -> Bookmark {
        let root = folder(guid: "root")
        let leafA = bookmark(guid: "leaf-a")
        let folderA = folder(guid: "folder-a")
        let nestedA = bookmark(guid: "nested-a")
        let nestedFolder = folder(guid: "nested-folder")
        let deepA = bookmark(guid: "deep-a")
        let leafB = bookmark(guid: "leaf-b")
        let folderB = folder(guid: "folder-b")
        let leafC = bookmark(guid: "leaf-c")

        nestedFolder.addChild(deepA)
        folderA.addChild(nestedA)
        folderA.addChild(nestedFolder)
        folderB.addChild(leafC)
        root.addChild(leafA)
        root.addChild(folderA)
        root.addChild(leafB)
        root.addChild(folderB)
        return root
    }

    private func folder(guid: String) -> Bookmark {
        Bookmark(guid: guid, title: guid, isFolder: true)
    }

    private func bookmark(guid: String) -> Bookmark {
        Bookmark(guid: guid, title: guid, url: "https://\(guid).example")
    }
}

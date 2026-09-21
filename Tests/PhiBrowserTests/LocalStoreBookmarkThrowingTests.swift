// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Combine
import SwiftData
import XCTest
@testable import Phi

// Throwing bookmark write APIs (§4.9). performBackgroundWriteAndWaitThrowing throws only
// when its body or save() throws. A silent return looks like a successful write, letting the
// engine record a reconciled/server baseline for work that never happened. The row then
// escapes both deletion diffing (it still exists) and snapshot retry (the baseline says synced).
@MainActor
final class LocalStoreBookmarkThrowingTests: XCTestCase {
    private var tempDirectories: [URL] = []

    override func tearDownWithError() throws {
        // Some cases run real scope migrations, whose success path writes UserDefaults.standard.
        // In hosted tests, that is Phi's own preferences domain.
        clearPinnedTabScopeMirrorDefaults()
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    // MARK: - moveBookmarkThrowing

    // CASE 2a.1
    func testMoveBookmarkThrowingThrowsWhenRowIsMissing() async throws {
        let store = try await makeStoreWithSpaces()
        let folder = try await store.createDirectoryThrowing(title: "Folder",
                                                             profileId: Self.profileId,
                                                             parentId: nil)

        await assertThrows(.rowNotFound) {
            try await store.moveBookmarkThrowing(guid: "no-such-guid",
                                                 toParentGuid: folder,
                                                 inSpaceId: LocalStore.defaultSpaceId,
                                                 index: 0)
        }
    }

    // CASE 2a.2
    func testMoveBookmarkThrowingThrowsWhenTargetIsTheRoot() async throws {
        let store = try await makeStoreWithSpaces()
        let folder = try await store.createDirectoryThrowing(title: "Folder",
                                                             profileId: Self.profileId,
                                                             parentId: nil)
        let rootGuid = try await rootGuid(in: store, spaceId: LocalStore.defaultSpaceId)

        await assertThrows(.rowIsRoot) {
            try await store.moveBookmarkThrowing(guid: rootGuid,
                                                 toParentGuid: folder,
                                                 inSpaceId: LocalStore.defaultSpaceId,
                                                 index: 0)
        }
    }

    // CASE 2a.3
    func testMoveBookmarkThrowingThrowsWhenTargetParentDoesNotResolve() async throws {
        let store = try await makeStoreWithSpaces()
        let bookmark = try await store.createBookmarkThrowing(url: Self.exampleURL,
                                                              title: "A",
                                                              profileId: Self.profileId,
                                                              parentId: nil)

        await assertThrows(.rowNotFound) {
            try await store.moveBookmarkThrowing(guid: bookmark,
                                                 toParentGuid: "no-such-folder",
                                                 inSpaceId: LocalStore.defaultSpaceId,
                                                 index: 0)
        }
    }

    // CASE 2a.20: retag a subtree and reparent it to any folder in one call. Neither existing
    // primitive supports this: moveBookmark takes the Space from the row, while moveBookmarks
    // always targets the Space root. R-D6-14 ③ requires a field change, not delete plus create.
    func testMoveBookmarkThrowingRetagsSubtreeAndReparentsIntoAnyFolder() async throws {
        let store = try await makeStoreWithSpaces()
        let source = try await store.createDirectoryThrowing(title: "Source",
                                                             profileId: Self.profileId,
                                                             parentId: nil,
                                                             spaceId: LocalStore.defaultSpaceId)
        let child = try await store.createBookmarkThrowing(url: Self.exampleURL,
                                                           title: "Child",
                                                           profileId: Self.profileId,
                                                           parentId: source,
                                                           spaceId: LocalStore.defaultSpaceId)
        let target = try await store.createDirectoryThrowing(title: "Target",
                                                             profileId: Self.profileId,
                                                             parentId: nil,
                                                             spaceId: Self.otherSpaceId)

        try await store.moveBookmarkThrowing(guid: source,
                                             toParentGuid: target,
                                             inSpaceId: Self.otherSpaceId,
                                             index: 0)
        drainMainQueue()

        let movedFolder = try XCTUnwrap(try row(source, in: store))
        let movedChild = try XCTUnwrap(try row(child, in: store))
        XCTAssertEqual(movedFolder.spaceId, Self.otherSpaceId)
        XCTAssertEqual(movedChild.spaceId, Self.otherSpaceId)
        XCTAssertEqual(movedChild.guid, child)
        XCTAssertEqual(movedFolder.parent?.guid, target)
    }

    // MARK: - moveBookmarksThrowing

    // CASE 2a.4: an empty list is a caller bug, not a successful no-op.
    func testMoveBookmarksThrowingThrowsOnAnEmptyGuidList() async throws {
        let store = try await makeStoreWithSpaces()

        await assertThrows(.noCandidateSurvived) {
            try await store.moveBookmarksThrowing(guids: [],
                                                  toSpaceId: Self.otherSpaceId,
                                                  profileId: Self.profileId)
        }
    }

    // CASE 2a.5
    func testMoveBookmarksThrowingThrowsWhenTargetSpaceIsNotWritable() async throws {
        let store = try await makeStoreWithSpaces()
        let bookmark = try await store.createBookmarkThrowing(url: Self.exampleURL,
                                                              title: "A",
                                                              profileId: Self.profileId,
                                                              parentId: nil)

        await assertThrows(.targetNotWritable) {
            try await store.moveBookmarksThrowing(guids: [bookmark],
                                                  toSpaceId: "no-such-space",
                                                  profileId: Self.profileId)
        }
    }

    // CASE 2a.6: reachable only through existingBookmarkRoot; createIfNeeded: true would
    // silently recreate an empty root and report success.
    func testMoveBookmarksThrowingThrowsWhenTargetRootIsMissing() async throws {
        let store = try await makeStoreWithSpaces()
        let bookmark = try await store.createBookmarkThrowing(url: Self.exampleURL,
                                                              title: "A",
                                                              profileId: Self.profileId,
                                                              parentId: nil)
        try await store.detachBookmarkRootRelationshipForTesting(spaceId: Self.otherSpaceId)

        await assertThrows(.rowNotFound) {
            try await store.moveBookmarksThrowing(guids: [bookmark],
                                                  toSpaceId: Self.otherSpaceId,
                                                  profileId: Self.profileId)
        }
    }

    // CASE 2a.7: the two formerly silent continue paths could skip the entire batch,
    // report success, and make sync record a baseline without any writes.
    func testMoveBookmarksThrowingThrowsWhenEveryCandidateIsSkipped() async throws {
        let store = try await makeStoreWithSpaces()
        let bookmark = try await store.createBookmarkThrowing(url: Self.exampleURL,
                                                              title: "A",
                                                              profileId: Self.profileId,
                                                              parentId: nil,
                                                              spaceId: Self.otherSpaceId)

        await assertThrows(.noCandidateSurvived) {
            try await store.moveBookmarksThrowing(guids: [bookmark],
                                                  toSpaceId: Self.otherSpaceId,
                                                  profileId: Self.profileId)
        }
    }

    // MARK: - updateBookmarkThrowing

    // CASE 2a.8
    func testUpdateBookmarkThrowingThrowsWhenRowIsMissing() async throws {
        let store = try await makeStoreWithSpaces()

        await assertThrows(.rowNotFound) {
            try await store.updateBookmarkThrowing("no-such-guid",
                                                   profileId: Self.profileId,
                                                   title: "B",
                                                   url: nil)
        }
    }

    // CASE 2a.9: previously the title changed before the URL guard returned.
    // Validate before mutating when extracting the body.
    func testUpdateBookmarkThrowingRollsBackTheTitleWhenThePrimaryURLIsInvalid() async throws {
        let store = try await makeStoreWithSpaces()
        let bookmark = try await store.createBookmarkThrowing(url: Self.exampleURL,
                                                              title: "A",
                                                              profileId: Self.profileId,
                                                              parentId: nil)

        await assertThrows(.invalidURL) {
            try await store.updateBookmarkThrowing(bookmark,
                                                   profileId: Self.profileId,
                                                   title: "B",
                                                   url: .some("::not a url::"))
        }
        drainMainQueue()

        let stored = try XCTUnwrap(try row(bookmark, in: store))
        XCTAssertEqual(stored.title, "A")
    }

    // CASE 2a.10
    func testUpdateBookmarkThrowingThrowsWhenTheSecondaryURLIsInvalid() async throws {
        let store = try await makeStoreWithSpaces()
        let bookmark = try await store.createBookmarkThrowing(url: Self.exampleURL,
                                                              title: "A",
                                                              profileId: Self.profileId,
                                                              parentId: nil)

        await assertThrows(.invalidURL) {
            try await store.updateBookmarkThrowing(bookmark,
                                                   profileId: Self.profileId,
                                                   title: nil,
                                                   url: nil,
                                                   secondaryUrl: .some(.some("::not a url::")))
        }
    }

    // CASE 2a.16b: §4.9 rule 1 requires allowsEmptyTitle in both create and update.
    func testUpdateBookmarkThrowingHonoursAllowsEmptyTitleOnBothSides() async throws {
        let store = try await makeStoreWithSpaces()
        let allowed = try await store.createBookmarkThrowing(url: Self.exampleURL,
                                                             title: "A",
                                                             profileId: Self.profileId,
                                                             parentId: nil)
        try await store.updateBookmarkThrowing(allowed,
                                               profileId: Self.profileId,
                                               title: .some(""),
                                               url: nil,
                                               allowsEmptyTitle: true)
        drainMainQueue()
        XCTAssertEqual(try XCTUnwrap(try row(allowed, in: store)).title, "")

        let replaced = try await store.createBookmarkThrowing(url: Self.exampleURL,
                                                              title: "A",
                                                              profileId: Self.profileId,
                                                              parentId: nil)
        try await store.updateBookmarkThrowing(replaced,
                                               profileId: Self.profileId,
                                               title: .some(""),
                                               url: nil,
                                               allowsEmptyTitle: false)
        drainMainQueue()
        XCTAssertEqual(try XCTUnwrap(try row(replaced, in: store)).title,
                       Self.exampleURL.absoluteString)
    }

    // MARK: - deleteBookmarkThrowing

    // CASE 2a.11: this guard was previously silent.
    func testDeleteBookmarkThrowingThrowsWhenRowIsMissing() async throws {
        let store = try await makeStoreWithSpaces()

        await assertThrows(.rowNotFound) {
            try await store.deleteBookmarkThrowing("no-such-guid", profileId: Self.profileId)
        }
    }

    // CASE 2a.12
    func testDeleteBookmarkThrowingThrowsWhenTargetIsTheRoot() async throws {
        let store = try await makeStoreWithSpaces()
        let rootGuid = try await rootGuid(in: store, spaceId: LocalStore.defaultSpaceId)

        await assertThrows(.rowIsRoot) {
            try await store.deleteBookmarkThrowing(rootGuid, profileId: Self.profileId)
        }
    }

    // MARK: - createBookmarkThrowing

    // CASE 2a.13: resolveParent silently falls back to the Space root for a missing or nonfolder
    // parent. Useful for UI input, this puts synced bookmarks in an unrequested location; the
    // next diff treats that location as local intent and overwrites the remote parent_uuid.
    func testCreateBookmarkThrowingThrowsWhenTheParentIsNotAFolder() async throws {
        let store = try await makeStoreWithSpaces()
        let leaf = try await store.createBookmarkThrowing(url: Self.exampleURL,
                                                          title: "Leaf",
                                                          profileId: Self.profileId,
                                                          parentId: nil)

        await assertThrows(.rowNotFound) {
            _ = try await store.createBookmarkThrowing(url: Self.exampleURL,
                                                       title: "Child",
                                                       profileId: Self.profileId,
                                                       parentId: leaf)
        }
    }

    // CASE 2a.15: all creation paths use insertBookmarkNode, which replaces empty titles with the URL.
    func testCreateBookmarkThrowingKeepsAnEmptyTitleWhenAllowed() async throws {
        let store = try await makeStoreWithSpaces()
        let bookmark = try await store.createBookmarkThrowing(url: Self.exampleURL,
                                                              title: "",
                                                              profileId: Self.profileId,
                                                              parentId: nil,
                                                              allowsEmptyTitle: true)
        drainMainQueue()

        XCTAssertEqual(try XCTUnwrap(try row(bookmark, in: store)).title, "")
    }

    // CASE 2a.16: UI behavior remains unchanged.
    func testCreateBookmarkThrowingReplacesAnEmptyTitleWhenNotAllowed() async throws {
        let store = try await makeStoreWithSpaces()
        let bookmark = try await store.createBookmarkThrowing(url: Self.exampleURL,
                                                              title: "",
                                                              profileId: Self.profileId,
                                                              parentId: nil,
                                                              allowsEmptyTitle: false)
        drainMainQueue()

        XCTAssertEqual(try XCTUnwrap(try row(bookmark, in: store)).title,
                       Self.exampleURL.absoluteString)
    }

    // CASE 2a.17: createBookmark uses URLProcessor.processUserInput, which can turn non-URLs
    // into searches. The throwing API accepts URL and bypasses that user-input processing.
    func testCreateBookmarkThrowingDoesNotRunUserInputProcessing() async throws {
        let store = try await makeStoreWithSpaces()
        let escaped = try XCTUnwrap(URL(string: "https://example.com/a%20b?q=c%20d"))
        let bookmark = try await store.createBookmarkThrowing(url: escaped,
                                                              title: "Escaped",
                                                              profileId: Self.profileId,
                                                              parentId: nil)
        drainMainQueue()

        XCTAssertEqual(try XCTUnwrap(try row(bookmark, in: store)).url.absoluteString,
                       escaped.absoluteString)
    }

    // MARK: - contentUpdatedDate

    // CASE 2a.18: updateLastSeen/updateTabFavicon advance updatedDate, letting an untouched
    // old local value win against a recent remote edit (§6.2).
    func testContentEditsStampContentUpdatedDateAndReadsDoNot() async throws {
        let store = try await makeStoreWithSpaces()
        let bookmark = try await store.createBookmarkThrowing(url: Self.exampleURL,
                                                              title: "A",
                                                              profileId: Self.profileId,
                                                              parentId: nil)
        drainMainQueue()
        XCTAssertNil(try XCTUnwrap(try row(bookmark, in: store)).contentUpdatedDate)

        try await store.updateBookmarkThrowing(bookmark,
                                               profileId: Self.profileId,
                                               title: "B",
                                               url: nil)
        drainMainQueue()
        let afterEdit = try XCTUnwrap(try XCTUnwrap(try row(bookmark, in: store)).contentUpdatedDate)

        store.updateLastSeen(bookmark)
        drainMainQueue()
        XCTAssertEqual(try XCTUnwrap(try row(bookmark, in: store)).contentUpdatedDate, afterEdit)

        store.updateTabFavicon(bookmark, favicon: Data([1, 2, 3]))
        drainMainQueue()
        XCTAssertEqual(try XCTUnwrap(try row(bookmark, in: store)).contentUpdatedDate, afterEdit)
    }

    // CASE 2a.19: saving an unchanged title must not make the row win against a remote edit.
    func testWritingTheSameTitleIsNotAnEdit() async throws {
        let store = try await makeStoreWithSpaces()
        let bookmark = try await store.createBookmarkThrowing(url: Self.exampleURL,
                                                              title: "A",
                                                              profileId: Self.profileId,
                                                              parentId: nil)

        try await store.updateBookmarkThrowing(bookmark,
                                               profileId: Self.profileId,
                                               title: "A",
                                               url: nil)
        drainMainQueue()

        XCTAssertNil(try XCTUnwrap(try row(bookmark, in: store)).contentUpdatedDate)
    }

    // MARK: - Fire-and-forget APIs

    // CASE 2a.14: making the UI path throw during body extraction would turn user-side races into crashes.
    func testFireAndForgetUpdateStillSwallowsAMissingRow() async throws {
        let store = try await makeStoreWithSpaces()

        store.updateBookmark("no-such-guid",
                             profileId: Self.profileId,
                             title: "B",
                             url: nil)
        drainMainQueue()

        XCTAssertNil(try row("no-such-guid", in: store))
    }

    // MARK: - Batch insertion and secondary sort keys

    // CASE 2a.21: insert(node:to:at:in:) fetches the parent's children and normalizes all sibling
    // indexes for each row. Adding 250 rows to one folder therefore causes 250 fetches and
    // 250 complete reorderings in a single transaction that cannot yield during the round.
    func testBulkInsertNormalizesEachTouchedParentExactlyOnce() async throws {
        let store = try await makeStoreWithSpaces()
        let folder = try await store.createDirectoryThrowing(title: "Bulk",
                                                             profileId: Self.profileId,
                                                             parentId: nil)
        let rows = (0..<20).map { position in
            LocalStore.BulkBookmarkInsert(guid: "bulk-\(position)",
                                          title: "Bulk \(position)",
                                          url: Self.exampleURL,
                                          index: position,
                                          isFolder: false,
                                          parentGuid: folder,
                                          spaceId: LocalStore.defaultSpaceId,
                                          profileId: Self.profileId,
                                          createdDate: Date())
        }

        let normalizations = try await store.insertBookmarksBulkThrowingCountingNormalizations(rows)
        drainMainQueue()

        XCTAssertEqual(normalizations, 1)
        XCTAssertEqual(store.fetchBookmarks(parentId: folder, profileId: Self.profileId).count, 20)
    }

    // CASE 2a.22: excluded siblings (parked, pending deletion, or unidentified) retain stale
    // indexes that can collide with new writes. Sorting children only by index makes ties
    // fetch-dependent and causes two unnecessary commits every round.
    func testChildrenOrderingHasAStableSecondaryKey() async throws {
        let store = try await makeStoreWithSpaces()
        let folder = try await store.createDirectoryThrowing(title: "Folder",
                                                             profileId: Self.profileId,
                                                             parentId: nil)
        try await store.insertBookmarkWithIndexForTesting(guid: "BBBB", parentGuid: folder, index: 1)
        try await store.insertBookmarkWithIndexForTesting(guid: "AAAA", parentGuid: folder, index: 1)
        drainMainQueue()

        let ordered = store.fetchBookmarks(parentId: folder, profileId: Self.profileId)
        XCTAssertEqual(ordered.map(\.guid), ["AAAA", "BBBB"])
    }

    // MARK: - existingBookmarkRoot

    // CASE 2a.23: bookmarkRoot sets space?.bookmarkRoot = primary and deletes duplicates
    // before its createIfNeeded guard. Using it in every round's read path can delete main-context rows.
    func testExistingBookmarkRootNeitherHealsNorWrites() async throws {
        let store = try await makeStoreWithSpaces()
        _ = try await store.createBookmarkThrowing(url: Self.exampleURL,
                                                   title: "A",
                                                   profileId: Self.profileId,
                                                   parentId: nil,
                                                   spaceId: Self.otherSpaceId)
        try await store.detachBookmarkRootRelationshipForTesting(spaceId: Self.otherSpaceId)

        let observed = try await store.performBackgroundWriteAndWaitThrowing { context -> ObservedRead in
            let before = try store.allBookmarkModels(in: context).count
            let root = try store.existingBookmarkRoot(profileId: Self.profileId,
                                                      spaceId: Self.otherSpaceId,
                                                      in: context)
            let after = try store.allBookmarkModels(in: context).count
            return ObservedRead(hasChanges: context.hasChanges,
                                rootWasFound: root != nil,
                                countBefore: before,
                                countAfter: after)
        }

        XCTAssertFalse(observed.hasChanges)
        XCTAssertFalse(observed.rootWasFound)
        XCTAssertEqual(observed.countBefore, observed.countAfter)
    }

    // MARK: - applyBookmarkSyncBatchThrowing（Task 5a fix round）

    // F2: a folder containing children absent from the delete batch must roll back the entire batch.
    //
    // deleteBookmarkBody calls context.delete(node), and TabDataModel.children cascades deletion
    // through the subtree. R-M3-3-17 requires deleting or promoting every surviving descendant
    // to the Space root first. Local-only rows (syncId == nil) are absent from cursors, so a
    // cursor-derived promotion list misses them and silently destroys user bookmarks.
    func testDeletingAFolderThatStillHasUnnamedChildrenRollsTheWholeBatchBack() async throws {
        let store = try await makeStoreWithSpaces()
        let folder = try await store.createDirectoryThrowing(title: "Folder",
                                                             profileId: Self.profileId,
                                                             parentId: nil)
        // This local-only row has no syncId and cannot appear in a cursor-derived promotion list.
        let localOnly = try await store.createBookmarkThrowing(url: Self.exampleURL,
                                                               title: "Local only",
                                                               profileId: Self.profileId,
                                                               parentId: folder)
        let sibling = try await store.createBookmarkThrowing(url: Self.exampleURL,
                                                             title: "Sibling",
                                                             profileId: Self.profileId,
                                                             parentId: nil,
                                                             syncId: "b-sibling")

        await assertThrows(.folderNotEmpty) {
            try await store.applyBookmarkSyncBatchThrowing([
                .update(guid: sibling, fields: BookmarkFieldPatch(title: "Renamed")),
                .delete(guid: folder),
            ])
        }

        // Full rollback preserves the local-only row and undoes the update preceding the delete.
        let survivor = try row(localOnly, in: store)
        let folderRow = try row(folder, in: store)
        let siblingTitle = try row(sibling, in: store)?.title
        XCTAssertNotNil(survivor, "Cascade deletion preserves this unpublished row")
        XCTAssertNotNil(folderRow)
        XCTAssertEqual(siblingTitle, "Sibling", "No partial success: the update in the same batch also rolls back")
    }

    // Review A4: a Space row that exists but never materialized its bookmark root (a pre-Spaces
    // row never opened in a window, the default Space on a fresh device) must not park the
    // account's whole bookmark batch forever. Landing a parentless row materializes the root the
    // way Space creation does, inside the same transaction.
    func testLandingAParentlessBookmarkMaterializesAMissingSpaceRoot() async throws {
        let store = try await makeStoreWithSpaces()
        try await store.performBackgroundWriteAndWaitThrowing { context in
            guard let root = try store.existingBookmarkRoot(profileId: Self.profileId,
                                                            spaceId: Self.otherSpaceId,
                                                            in: context) else { return }
            let spaceId = Self.otherSpaceId
            let spaces = try context.fetch(FetchDescriptor<SpaceModel>(
                predicate: #Predicate<SpaceModel> { $0.spaceId == spaceId }))
            for space in spaces { space.bookmarkRoot = nil }
            context.delete(root)
        }

        try await store.applyBookmarkSyncBatchThrowing([
            .create(.fixture(guid: "g-landed", syncId: "b-landed", spaceId: Self.otherSpaceId,
                             profileId: Self.profileId, title: "Landed")),
        ])

        let landed = try row("g-landed", in: store)
        XCTAssertNotNil(landed, "the row lands instead of parking on rowNotFound")
        let root = try await rootGuid(in: store, spaceId: Self.otherSpaceId)
        XCTAssertEqual(landed?.parent?.guid, root, "the landed row hangs off the freshly materialized root")
    }

    // F2, positive control: empty folders remain deletable.
    func testDeletingAnEmptyFolderStillSucceeds() async throws {
        let store = try await makeStoreWithSpaces()
        let folder = try await store.createDirectoryThrowing(title: "Folder",
                                                             profileId: Self.profileId,
                                                             parentId: nil)

        try await store.applyBookmarkSyncBatchThrowing([.delete(guid: folder)])

        let deleted = try row(folder, in: store)
        XCTAssertNil(deleted)
    }

    // G3: deleting children before their parent in one batch must succeed.
    // The folderNotEmpty guard runs after descendants are deleted in this batch; it relies on
    // fetches including pending changes but excluding rows just marked by context.delete.
    // This milestone only compiled tests, while §4.4 suggested the opposite fetch behavior.
    // If that assumption is wrong, every remote nonempty-folder deletion fails forever.
    // This case makes the assumption explicit and verifiable.
    func testDeletingAChildAndThenItsParentFolderInOneBatchSucceeds() async throws {
        let store = try await makeStoreWithSpaces()
        let folder = try await store.createDirectoryThrowing(title: "Folder",
                                                             profileId: Self.profileId,
                                                             parentId: nil)
        let child = try await store.createBookmarkThrowing(url: Self.exampleURL,
                                                           title: "Child",
                                                           profileId: Self.profileId,
                                                           parentId: folder)

        // The delete phase orders children before parents, exactly as the engine does.
        try await store.applyBookmarkSyncBatchThrowing([
            .delete(guid: child),
            .delete(guid: folder),
        ])

        let childRow = try row(child, in: store)
        let folderRow = try row(folder, in: store)
        XCTAssertNil(childRow)
        XCTAssertNil(folderRow, "The guard must allow a valid whole-subtree deletion")
    }

    // F3: a row with another identity cannot be reclaimed.
    // Overwriting its identity removes the old local association; §4.7 would publish a tombstone
    // for the apparently missing row, deleting the remote entity. Identity is claimed once (§6.1 / 13d).
    func testClaimingARowThatAlreadyCarriesADifferentIdentityRollsTheBatchBack() async throws {
        let store = try await makeStoreWithSpaces()
        let guid = try await store.createBookmarkThrowing(url: Self.exampleURL,
                                                          title: "A",
                                                          profileId: Self.profileId,
                                                          parentId: nil,
                                                          syncId: "b-first")

        await assertThrows(.rowAlreadyMapped) {
            try await store.applyBookmarkSyncBatchThrowing([
                .claim(guid: guid, syncId: "b-second"),
            ])
        }

        let identity = try row(guid, in: store)?.syncId
        XCTAssertEqual(identity, "b-first", "The original identity remains unchanged")
    }

    // F3: claiming an unidentified row succeeds; reclaiming the same uuid is idempotent.
    func testClaimingIsIdempotentForTheSameIdentityAndWritesAnUnclaimedRow() async throws {
        let store = try await makeStoreWithSpaces()
        let guid = try await store.createBookmarkThrowing(url: Self.exampleURL,
                                                          title: "A",
                                                          profileId: Self.profileId,
                                                          parentId: nil)

        try await store.applyBookmarkSyncBatchThrowing([.claim(guid: guid, syncId: "b1")])
        try await store.applyBookmarkSyncBatchThrowing([.claim(guid: guid, syncId: "b1")])

        let identity = try row(guid, in: store)?.syncId
        XCTAssertEqual(identity, "b1")
    }

    // F7: a Space being imported throws a dedicated case, not targetNotWritable.
    // targetNotWritable means a deleted Space or changed Profile, a structural failure. Import
    // is transient and should park for retry. Conflating them makes §11.2's parked count
    // unable to distinguish retryable parking from permanent failure.
    func testABatchTargetingAnImportingSpaceThrowsTheDedicatedCase() async throws {
        let store = try await makeStoreWithSpaces()
        let guid = try await store.createBookmarkThrowing(url: Self.exampleURL,
                                                          title: "A",
                                                          profileId: Self.profileId,
                                                          parentId: nil)
        ImportTargetLock.shared.begin(into: LocalStore.defaultSpaceId)
        defer { ImportTargetLock.shared.end(into: LocalStore.defaultSpaceId) }

        await assertThrows(.spaceImporting(spaceId: LocalStore.defaultSpaceId)) {
            try await store.applyBookmarkSyncBatchThrowing([
                .update(guid: guid, fields: BookmarkFieldPatch(title: "Renamed")),
            ])
        }

        let title = try row(guid, in: store)?.title
        XCTAssertEqual(title, "A", "No bytes are written while locked")
    }

    // MARK: - Fetching the diff domain (R-exec-4)

    // F4: a row under an orphan root is outside the snapshot domain but inside the diff domain.
    // allBookmarkModels plus canonicalRootGuids recursion correctly excludes orphan subtrees
    // from publication. But §4.7 locals asks whether an identity still has a local row. Using
    // the snapshot for that answer tombstones an entire account subtree that still exists locally.
    func testIdentitiesUnderAnOrphanRootStayInTheDiffDomainAfterTheRootIsDetached() async throws {
        let store = try await makeStoreWithSpaces()
        let folder = try await store.createDirectoryThrowing(title: "Folder",
                                                             profileId: Self.profileId,
                                                             parentId: nil,
                                                             spaceId: Self.otherSpaceId,
                                                             syncId: "b-folder")
        _ = try await store.createBookmarkThrowing(url: Self.exampleURL,
                                                   title: "Child",
                                                   profileId: Self.profileId,
                                                   parentId: folder,
                                                   spaceId: Self.otherSpaceId,
                                                   syncId: "b-child")
        let rootGuid = try await rootGuid(in: store, spaceId: Self.otherSpaceId)
        try await store.detachBookmarkRootRelationshipForTesting(spaceId: Self.otherSpaceId)

        // AccountPhiBookmarkAccess.rebuildCache reads identities from the unfiltered
        // allBookmarkModels(in:) result, then traverses roots over the same result for the snapshot.
        // These assertions check those two inputs.
        let observed = try await store.performBackgroundWriteAndWaitThrowing { context -> ObservedDomain in
            let models = try store.allBookmarkModels(in: context)
            return ObservedDomain(canonicalRoots: try store.canonicalRootGuids(in: context),
                                  identities: Set(models.compactMap(\.syncId)))
        }

        XCTAssertFalse(observed.canonicalRoots.contains(rootGuid),
                       "A broken root relationship makes the subtree unreachable by recursion")
        XCTAssertTrue(observed.identities.isSuperset(of: ["b-folder", "b-child"]),
                      "Both identities still have local rows and must not be classified as deleted")
    }

    // MARK: - Store change publisher (§5.7)

    // CASE 6c.1: a burst of writes emits once, with no initial emission on subscription.
    // Subscribe directly: LocalStore.changeSignalDebounce belongs to the publisher. Adding a
    // test debounce would verify a custom pipeline. This is the only case using the production
    // window because it measures that window and must track changes to the constant.
    //
    // Wait a complete quiet period before checking zero emissions: even an incorrect initial
    // emission must pass through debounce. Checking after a 0.05-second main-queue drain
    // always sees zero and misses the bug. Verify quiet first, then issue the 30 writes.
    func testBookmarkChangesPublisherCollapsesABurstOfWritesIntoOneSignal() async throws {
        let store = try await makeStoreWithSpaces()

        var received = 0
        let cancellable = store.bookmarkChangesPublisher().sink { _ in received += 1 }
        defer { cancellable.cancel() }

        // Wait a full debounce window without writes to expose an initial seed emission.
        waitPastDebounceWindow()
        let afterQuietPeriod = received
        XCTAssertEqual(afterQuietPeriod, 0, "Subscription does not emit the current value")

        for index in 0..<30 {
            let url = try XCTUnwrap(URL(string: "https://example.com/burst-\(index)"))
            _ = try await store.createBookmarkThrowing(url: url,
                                                       title: "B\(index)",
                                                       profileId: Self.profileId,
                                                       parentId: nil)
        }
        waitPastDebounceWindow()

        let observed = received
        XCTAssertEqual(observed, 1, "Thirty writes collapse into one debounced emission")
    }

    // CASE 6c.2: favicon and lastSeen writes emit nothing.
    // Neither field belongs to PhiLocalBookmark's value snapshot. Including them would make
    // Task 10's favicon backfill trigger dozens of redundant commits per round. Both writes
    // emit NSManagedObjectContextDidSave, pass the type filter, and start the debounce timer;
    // the identical projection after the quiet period suppresses them. Adding updatedDate
    // to BookmarkChangeSnapshot makes this test fail.
    func testBookmarkChangesPublisherIgnoresFaviconAndLastSeenWrites() async throws {
        let store = try await makeStoreWithSpaces()
        let guid = try await store.createBookmarkThrowing(url: Self.exampleURL,
                                                          title: "A",
                                                          profileId: Self.profileId,
                                                          parentId: nil)

        var received = 0
        let cancellable = store.bookmarkChangesPublisher(debounceWindow: Self.shortDebounceWindow)
            .sink { _ in received += 1 }
        defer { cancellable.cancel() }

        store.updateTabFavicon(guid, favicon: Data([0x01, 0x02, 0x03]))
        store.updateLastSeen(guid, seenAt: Date(timeIntervalSince1970: 1_700_000_000))
        // Drain both writes through the write queue before waiting; with a short window,
        // otherwise the assertion could pass simply because the writes have not happened.
        await flushWrites(store)
        waitPastDebounceWindow(Self.shortDebounceWindow)

        let observed = received
        XCTAssertEqual(observed, 0, "Favicon and lastSeen are absent from the snapshot and must emit nothing")
    }

    // Scope itself belongs to the snapshot (T6c-6 / ledger 4).
    // A pure scope flip changes no TabDataModel bytes but changes which rows sync claims.
    // If scope is omitted, the filter accepts the BrowserDataSettingsModel save but deduplication
    // suppresses it as unchanged, and the engine never learns about the scope change.
    // Create no pins: otherwise migratePinnedTabs also changes rows and hides the missing scope field.
    func testPinnedTabChangesPublisherEmitsWhenOnlyTheScopeChanges() async throws {
        let store = try await makeStoreWithSpaces()

        var received = 0
        let cancellable = store.pinnedTabChangesPublisher(debounceWindow: Self.shortDebounceWindow)
            .sink { _ in received += 1 }
        defer { cancellable.cancel() }

        waitPastDebounceWindow(Self.shortDebounceWindow)
        let afterQuietPeriod = received
        XCTAssertEqual(afterQuietPeriod, 0, "Subscription does not emit the current value")

        try await store.changePinnedTabScope(to: .space,
                                             preferredProfileId: Self.profileId,
                                             preferredSpaceId: LocalStore.defaultSpaceId)
        waitPastDebounceWindow(Self.shortDebounceWindow)

        let observed = received
        XCTAssertEqual(observed, 1, "With no pins, only scope changes; it must be in the snapshot")
    }

    // Pin equivalent of 6c.2. updateLastSeen writes both pinnedTab and bookmark rows,
    // and Task 10 backfills favicons for both kinds.
    func testPinnedTabChangesPublisherIgnoresFaviconAndLastSeenWrites() async throws {
        let store = try await makeStoreWithSpaces()
        let guid = "pin-favicon"
        try await store.createPinnedTabThrowing(guid: guid,
                                                url: Self.exampleURL,
                                                title: "A",
                                                profileId: Self.profileId)

        var received = 0
        let cancellable = store.pinnedTabChangesPublisher(debounceWindow: Self.shortDebounceWindow)
            .sink { _ in received += 1 }
        defer { cancellable.cancel() }

        store.updateTabFavicon(guid, favicon: Data([0x04, 0x05, 0x06]))
        store.updateLastSeen(guid, seenAt: Date(timeIntervalSince1970: 1_700_000_000))
        await flushWrites(store)
        waitPastDebounceWindow(Self.shortDebounceWindow)

        let observed = received
        XCTAssertEqual(observed, 0, "Favicon and lastSeen are absent from the snapshot and must emit nothing")
    }

    // MARK: - Fixtures

    private struct ObservedDomain: Sendable {
        let canonicalRoots: Set<String>
        let identities: Set<String>
    }

    private struct ObservedRead: Sendable {
        let hasChanges: Bool
        let rootWasFound: Bool
        let countBefore: Int
        let countAfter: Int
    }

    private static let profileId = LocalStore.defaultProfileId
    private static let otherSpaceId = "space-b"
    private static let exampleURL = URL(string: "https://example.com/a")!

    private func makeStore() throws -> LocalStore {
        let directory = try makeTemporaryStoreDirectory()
        return LocalStore(account: Account(userID: "test-user"),
                          storeDirectoryURL: directory,
                          presentsCompatibilityAlerts: false)
    }

    private func makeStoreWithSpaces() async throws -> LocalStore {
        let store = try makeStore()
        try await store.createSpaceForTesting(spaceId: LocalStore.defaultSpaceId,
                                              profileId: Self.profileId)
        try await store.createSpaceForTesting(spaceId: Self.otherSpaceId,
                                              profileId: Self.profileId)
        return store
    }

    private func makeTemporaryStoreDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        return directory
    }

    private func rootGuid(in store: LocalStore, spaceId: String) async throws -> String {
        let guid = try await store.performBackgroundWriteAndWaitThrowing { context -> String? in
            try store.existingBookmarkRoot(profileId: Self.profileId,
                                           spaceId: spaceId,
                                           in: context)?.guid
        }
        return try XCTUnwrap(guid)
    }

    private func row(_ guid: String, in store: LocalStore) throws -> TabDataModel? {
        let context = try XCTUnwrap(store.getMainContext())
        let descriptor = FetchDescriptor<TabDataModel>(
            predicate: #Predicate<TabDataModel> { $0.guid == guid }
        )
        return try context.fetch(descriptor).first
    }

    // Assertions use autoclosures; read values before asserting.
    private func assertThrows(_ expected: LocalStoreWriteError,
                              file: StaticString = #filePath,
                              line: UInt = #line,
                              _ block: () async throws -> Void) async {
        do {
            try await block()
            XCTFail("Expected \(expected) to be thrown.", file: file, line: line)
        } catch let error as LocalStoreWriteError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    private func drainMainQueue() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    /// Short window for properties independent of duration: deduplication, filtering, and scope
    /// inclusion. Only CASE 6c.1 uses LocalStore.changeSignalDebounce because it measures
    /// the production window itself; other assertions need not wait two seconds each.
    private static let shortDebounceWindow: TimeInterval = 0.2

    /// Wait the debounce window plus a small allowance for main-queue delivery.
    private func waitPastDebounceWindow(
        _ window: TimeInterval = LocalStore.changeSignalDebounce
    ) {
        RunLoop.main.run(until: Date().addingTimeInterval(window + 0.6))
    }

    /// Drain fire-and-forget updateTabFavicon/updateLastSeen writes through the FIFO write queue.
    /// Zero-emission assertions must do this first; otherwise a short window may pass before
    /// any write happens, verifying nothing.
    private func flushWrites(_ store: LocalStore) async {
        await store.performBackgroundWriteAndWait { _ in }
    }
}

// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

@MainActor
final class BrowserStateMultiSelectionTests: XCTestCase {
    private var tempDirectories: [URL] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipIf(!TabMultiSelection.isEnabled, "Tab multi-selection is disabled.")
    }

    override func tearDownWithError() throws {
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    private func makeState() throws -> BrowserState {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        let store = LocalStore(account: Account(userID: UUID().uuidString),
                               storeDirectoryURL: directory)
        return BrowserState(windowId: 7, localStore: store, profileId: "Default")
    }

    private func seed(_ state: BrowserState, guids: [Int]) {
        state.tabs = guids.enumerated().map { index, guid in
            Tab(guid: guid,
                url: "https://e\(guid).example",
                isActive: false,
                index: index)
        }
        state.updateNormalTabs()
    }

    private func waitUntil(timeout: TimeInterval = 1,
                           condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTFail("Condition was not met before timeout.")
        return false
    }

    private func makeSpace(id: String = "space-target",
                           profileId: String = "Default") -> SpaceModel {
        SpaceModel(spaceId: id,
                   profileId: profileId,
                   name: "Target",
                   colorHex: "#000000",
                   iconName: "circle",
                   sortOrder: 1)
    }

    func testToggleNormalTabEntersAndExits() throws {
        let state = try makeState()
        seed(state, guids: [1, 2, 3])
        state.focuseTab(state.tabs[0])

        state.toggleMultiSelection(for: state.tabs[1])
        XCTAssertTrue(state.multiSelection.isActive)
        XCTAssertEqual(state.multiSelection.guids, [2])

        state.toggleMultiSelection(for: state.tabs[1])
        XCTAssertFalse(state.multiSelection.isActive)
    }

    func testToggleActiveTabIsNoop() throws {
        let state = try makeState()
        seed(state, guids: [1, 2])
        state.focuseTab(state.tabs[0])

        state.toggleMultiSelection(for: state.tabs[1])
        state.toggleMultiSelection(for: state.tabs[0])
        XCTAssertEqual(state.multiSelection.guids, [2])
    }

    func testReplaceMultiSelectionKeepsActiveNormalTabImplicit() throws {
        let state = try makeState()
        seed(state, guids: [1, 2, 3])
        state.focuseTab(state.tabs[0])

        XCTAssertTrue(state.replaceMultiSelection(tabIds: [1, 2, 3], bookmarkGuids: []))

        XCTAssertEqual(state.multiSelection.guids, [2, 3])
        XCTAssertEqual(state.orderedMultiSelectedTabs.map(\.guid), [1, 2, 3])
    }

    func testReplaceMultiSelectionIsDisabledDuringGroupOverview() throws {
        let state = try makeState()
        seed(state, guids: [1, 2, 3])
        state.handleTabGroupCreated(token: "A",
                                    title: "Group A",
                                    color: .blue,
                                    isCollapsed: false,
                                    initialTabIds: [2, 3])
        state.showGroupOverview(token: "A")

        XCTAssertFalse(state.replaceMultiSelection(tabIds: [2, 3], bookmarkGuids: []))

        XCTAssertFalse(state.multiSelection.isActive)
    }

    func testClearMultiSelection() throws {
        let state = try makeState()
        seed(state, guids: [1, 2, 3])
        state.focuseTab(state.tabs[0])

        state.toggleMultiSelection(for: state.tabs[1])
        state.toggleMultiSelection(for: state.tabs[2])
        XCTAssertTrue(state.multiSelection.isActive)

        state.clearMultiSelection()
        XCTAssertFalse(state.multiSelection.isActive)
    }

    func testOrderedSelectionFollowsTabOrderNotClickOrder() throws {
        let state = try makeState()
        seed(state, guids: [10, 20, 30, 40])
        state.focuseTab(state.tabs[0])

        state.toggleMultiSelection(for: state.tabs[2]) // 30
        state.toggleMultiSelection(for: state.tabs[1]) // 20
        XCTAssertEqual(state.orderedMultiSelectedTabs.map(\.guid), [10, 20, 30])
    }

    func testDragSelectionExpandsSplitPartner() throws {
        let state = try makeState()
        seed(state, guids: [1, 2, 3, 4])
        state.splits = [
            SplitGroup(id: "split-2-3",
                       primaryTabId: 2,
                       secondaryTabId: 3,
                       layout: .vertical,
                       ratio: 0.5)
        ]
        state.focuseTab(state.tabs[0])

        state.toggleMultiSelection(for: state.tabs[1])

        XCTAssertEqual(state.multiSelectionDragTabIds(startingFrom: state.tabs[1]), [1, 2, 3])
        XCTAssertEqual(state.multiSelectionDragTabIds(startingFrom: state.tabs[2]), [1, 2, 3])
    }

    func testCopyLinksExpandsFocusedSplitPartner() throws {
        for focusedIndex in [1, 2] {
            let state = try makeState()
            seed(state, guids: [1, 2, 3, 4])
            state.splits = [
                SplitGroup(id: "split-2-3",
                           primaryTabId: 2,
                           secondaryTabId: 3,
                           layout: .vertical,
                           ratio: 0.5)
            ]

            state.focuseTab(state.tabs[focusedIndex])
            state.toggleMultiSelection(for: state.tabs[3])
            NSPasteboard.general.clearContents()

            state.copyLinksOfMultiSelectedTabs()

            XCTAssertEqual(NSPasteboard.general.string(forType: .string),
                           "https://e2.example\nhttps://e3.example\nhttps://e4.example")
            XCTAssertFalse(state.multiSelection.isActive)
        }
    }

    func testCopySelectedTabURLCopiesFocusedTab() throws {
        let state = try makeState()
        state.tabs = [
            Tab(guid: 1, url: "chrome://settings", isActive: false, index: 0)
        ]
        state.updateNormalTabs()
        state.focuseTab(state.tabs[0])
        NSPasteboard.general.clearContents()

        XCTAssertEqual(state.selectedTabCountForURLCopy, 1)
        XCTAssertTrue(state.copySelectedTabURLs())

        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "phi://settings")
        XCTAssertFalse(state.multiSelection.isActive)
    }

    func testCopySelectedTabURLsCopiesMultiSelection() throws {
        let state = try makeState()
        seed(state, guids: [1, 2, 3])
        state.focuseTab(state.tabs[0])
        state.toggleMultiSelection(for: state.tabs[1])
        NSPasteboard.general.clearContents()

        XCTAssertEqual(state.selectedTabCountForURLCopy, 2)
        XCTAssertTrue(state.copySelectedTabURLs())

        XCTAssertEqual(NSPasteboard.general.string(forType: .string),
                       "https://e1.example\nhttps://e2.example")
        XCTAssertFalse(state.multiSelection.isActive)
    }

    func testBookmarkMultiSelectionExpandsFocusedSplitPartner() throws {
        let state = try makeState()
        seed(state, guids: [1, 2, 3])
        state.splits = [
            SplitGroup(id: "split-1-2",
                       primaryTabId: 1,
                       secondaryTabId: 2,
                       layout: .vertical,
                       ratio: 0.5)
        ]
        state.focuseTab(state.tabs[0])
        state.toggleMultiSelection(for: state.tabs[2])

        state.bookmarkMultiSelectedTabs(into: nil)

        XCTAssertTrue(waitUntil {
            state.localStore.fetchBookmarks(parentId: nil as String?,
                                            profileId: state.profileId).count == 2
        })
        let bookmarks = state.localStore.fetchBookmarks(parentId: nil as String?,
                                                        profileId: state.profileId)
        let splitBookmark = try XCTUnwrap(bookmarks.first {
            $0.url.absoluteString == "https://e1.example/"
        })
        let soloBookmark = try XCTUnwrap(bookmarks.first {
            $0.url.absoluteString == "https://e3.example/"
        })
        XCTAssertEqual(splitBookmark.secondaryUrl?.absoluteString, "https://e2.example/")
        XCTAssertNil(soloBookmark.secondaryUrl)
        XCTAssertFalse(state.multiSelection.isActive)
        XCTAssertEqual(state.splits.map(\.id), ["split-1-2"])
    }

    func testBookmarkMultiSelectionPreservesSelectedSplitAsSingleBookmark() throws {
        let state = try makeState()
        seed(state, guids: [1, 2, 3])
        state.splits = [
            SplitGroup(id: "split-1-2",
                       primaryTabId: 1,
                       secondaryTabId: 2,
                       layout: .vertical,
                       ratio: 0.5)
        ]
        state.focuseTab(state.tabs[2])
        state.toggleMultiSelectionForSplitPair(leftTab: state.tabs[0],
                                               rightTab: state.tabs[1])

        state.bookmarkMultiSelectedTabs(into: nil)

        XCTAssertTrue(waitUntil {
            state.localStore.fetchBookmarks(parentId: nil as String?,
                                            profileId: state.profileId).count == 2
        })
        let bookmarks = state.localStore.fetchBookmarks(parentId: nil as String?,
                                                        profileId: state.profileId)
        XCTAssertEqual(Set(bookmarks.map { $0.url.absoluteString }),
                       ["https://e1.example/", "https://e3.example/"])
        let splitBookmark = try XCTUnwrap(bookmarks.first {
            $0.url.absoluteString == "https://e1.example/"
        })
        XCTAssertEqual(splitBookmark.secondaryUrl?.absoluteString, "https://e2.example/")
        XCTAssertFalse(state.multiSelection.isActive)
        XCTAssertEqual(state.splits.map(\.id), ["split-1-2"])
    }

    func testBookmarkMultiSelectionIntoNewFolderPreservesSplitBookmark() throws {
        let state = try makeState()
        seed(state, guids: [1, 2, 3])
        state.splits = [
            SplitGroup(id: "split-1-2",
                       primaryTabId: 1,
                       secondaryTabId: 2,
                       layout: .vertical,
                       ratio: 0.5)
        ]
        state.focuseTab(state.tabs[0])
        state.toggleMultiSelection(for: state.tabs[2])
        let capturedTabs = state.orderedMultiSelectedTabs

        state.bookmarkTabs(capturedTabs, intoNewFolderNamed: "Saved Tabs")

        XCTAssertTrue(waitUntil {
            state.localStore.fetchBookmarks(parentId: nil as String?,
                                            profileId: state.profileId).count == 1
        })
        let folder = try XCTUnwrap(state.localStore.fetchBookmarks(parentId: nil as String?,
                                                                   profileId: state.profileId).first)
        XCTAssertTrue(waitUntil {
            state.localStore.fetchBookmarks(parentId: folder.guid,
                                            profileId: state.profileId).count == 2
        })
        let children = state.localStore.fetchBookmarks(parentId: folder.guid,
                                                       profileId: state.profileId)
        let splitBookmark = try XCTUnwrap(children.first {
            $0.url.absoluteString == "https://e1.example/"
        })
        let soloBookmark = try XCTUnwrap(children.first {
            $0.url.absoluteString == "https://e3.example/"
        })
        XCTAssertEqual(splitBookmark.secondaryUrl?.absoluteString, "https://e2.example/")
        XCTAssertNil(soloBookmark.secondaryUrl)
        XCTAssertFalse(state.multiSelection.isActive)
    }

    func testDragCountBadgeCollapsesSplitPairToOneVisibleUnit() throws {
        let state = try makeState()
        seed(state, guids: [1, 2, 3, 4])
        state.splits = [
            SplitGroup(id: "split-2-3",
                       primaryTabId: 2,
                       secondaryTabId: 3,
                       layout: .vertical,
                       ratio: 0.5)
        ]

        XCTAssertEqual(
            TabDragCountBadge.visibleUnitCount(tabIds: [1, 2, 3, 4], browserState: state),
            3
        )
        XCTAssertEqual(
            TabDragCountBadge.visibleRepresentativeTabIds(tabIds: [3, 2, 4], browserState: state),
            [3, 4]
        )
    }

    func testToggleInactiveSplitPairSelectsBothPanes() throws {
        let state = try makeState()
        seed(state, guids: [1, 2, 3, 4])
        state.splits = [
            SplitGroup(id: "split-2-3",
                       primaryTabId: 2,
                       secondaryTabId: 3,
                       layout: .vertical,
                       ratio: 0.5)
        ]
        state.focuseTab(state.tabs[0])

        state.toggleMultiSelectionForSplitPair(leftTab: state.tabs[1], rightTab: state.tabs[2])

        XCTAssertEqual(state.multiSelection.guids, [2, 3])
        XCTAssertEqual(state.multiSelectionDragTabIds(startingFrom: state.tabs[1]), [1, 2, 3])

        state.toggleMultiSelectionForSplitPair(leftTab: state.tabs[1], rightTab: state.tabs[2])

        XCTAssertFalse(state.multiSelection.isActive)
    }

    func testToggleActiveSplitPairSelectsPartnerPane() throws {
        let state = try makeState()
        seed(state, guids: [1, 2, 3, 4])
        state.splits = [
            SplitGroup(id: "split-2-3",
                       primaryTabId: 2,
                       secondaryTabId: 3,
                       layout: .vertical,
                       ratio: 0.5)
        ]
        state.focuseTab(state.tabs[1])

        state.toggleMultiSelectionForSplitPair(leftTab: state.tabs[1], rightTab: state.tabs[2])

        XCTAssertEqual(state.multiSelection.guids, [3])
        XCTAssertEqual(state.orderedMultiSelectedTabs.map(\.guid), [2, 3])
        XCTAssertEqual(state.multiSelectionDragTabIds(startingFrom: state.tabs[1]), [2, 3])

        state.toggleMultiSelectionForSplitPair(leftTab: state.tabs[1], rightTab: state.tabs[2])

        XCTAssertFalse(state.multiSelection.isActive)
    }

    func testMoveNormalTabsLocallyMovesIdsAsOrderedBlock() throws {
        let state = try makeState()
        seed(state, guids: [1, 2, 3, 4, 5])

        state.moveNormalTabsLocally(tabIds: [4, 2], to: 5, syncChromiumOrder: false)

        XCTAssertEqual(state.normalTabs.map(\.guid), [1, 3, 5, 2, 4])
    }

    func testMoveNormalTabsLocallyMovesNonContiguousSelectionToFront() throws {
        let state = try makeState()
        seed(state, guids: [1, 2, 3, 4, 5])

        state.moveNormalTabsLocally(tabIds: [2, 4, 5], to: 0, syncChromiumOrder: false)

        XCTAssertEqual(state.normalTabs.map(\.guid), [2, 4, 5, 1, 3])
    }

    func testRelativeOrderSyncMovesBatchBeforeExternalAnchorFromBackToFront() throws {
        let state = try makeState()
        seed(state, guids: [1, 2, 3, 4, 5])

        state.moveNormalTabsLocally(tabIds: [2, 4, 5], to: 0, syncChromiumOrder: false)

        XCTAssertEqual(
            state.normalTabRelativeOrderSyncMoves(tabIds: [2, 4, 5]),
            [
                BrowserState.NormalTabRelativeOrderMove(tabId: 5, anchor: .before(1)),
                BrowserState.NormalTabRelativeOrderMove(tabId: 4, anchor: .before(5)),
                BrowserState.NormalTabRelativeOrderMove(tabId: 2, anchor: .before(4)),
            ]
        )
    }

    func testRelativeOrderSyncOperationsMoveSplitAsUnit() throws {
        let state = try makeState()
        seed(state, guids: [1, 2, 3, 4, 5])
        state.splits = [
            SplitGroup(id: "split-2-3",
                       primaryTabId: 2,
                       secondaryTabId: 3,
                       layout: .vertical,
                       ratio: 0.5)
        ]

        state.moveNormalTabsLocally(tabIds: [2, 3, 5], to: 0, syncChromiumOrder: false)

        XCTAssertEqual(state.normalTabs.map(\.guid), [2, 3, 5, 1, 4])
        XCTAssertEqual(
            state.normalTabRelativeOrderSyncOperations(tabIds: [2, 3, 5]),
            [
                .tab(BrowserState.NormalTabRelativeOrderMove(tabId: 5, anchor: .before(1))),
                .split(splitId: "split-2-3", tabIds: [2, 3], toIndex: 0),
            ]
        )
    }

    func testMoveNormalTabsToBookmarksPreservesSplitAsSingleBookmark() throws {
        let state = try makeState()
        seed(state, guids: [1, 2, 3, 4])
        state.splits = [
            SplitGroup(id: "split-2-3",
                       primaryTabId: 2,
                       secondaryTabId: 3,
                       layout: .vertical,
                       ratio: 0.5)
        ]

        let moved = state.moveNormalTabs(tabIds: [1, 2, 3, 4],
                                         toBookmark: nil,
                                         index: 0)

        XCTAssertTrue(moved)
        XCTAssertEqual(Set(state.splitBookmarkBindings.values), ["split-2-3"])
        XCTAssertTrue(waitUntil {
            state.localStore.fetchBookmarks(parentId: nil as String?,
                                            profileId: state.profileId).count == 3
        })

        let bookmarks = state.localStore
            .fetchBookmarks(parentId: nil as String?, profileId: state.profileId)
            .sorted { $0.index < $1.index }
        guard bookmarks.count == 3 else { return }
        XCTAssertEqual(bookmarks.map { $0.url.absoluteString },
                       ["https://e1.example/", "https://e2.example/", "https://e4.example/"])
        XCTAssertEqual(bookmarks[1].secondaryUrl?.absoluteString,
                       "https://e3.example/")
    }

    func testMoveNormalTabsToPinnedPreservesSplitAsPinnedPair() throws {
        let state = try makeState()
        seed(state, guids: [1, 2, 3, 4])
        state.splits = [
            SplitGroup(id: "split-2-3",
                       primaryTabId: 2,
                       secondaryTabId: 3,
                       layout: .vertical,
                       ratio: 0.5)
        ]

        let moved = state.moveNormalTabs(tabIds: [2, 3, 4],
                                         toPinnedTabs: 0)

        XCTAssertTrue(moved)
        XCTAssertTrue(state.splits.first?.isPinned == true)
        guard let leftPinnedGuid = state.tabs.first(where: { $0.guid == 2 })?.guidInLocalDB,
              let rightPinnedGuid = state.tabs.first(where: { $0.guid == 3 })?.guidInLocalDB,
              let soloPinnedGuid = state.tabs.first(where: { $0.guid == 4 })?.guidInLocalDB else {
            return XCTFail("Moved tabs did not receive pinned guids")
        }

        XCTAssertTrue(waitUntil {
            let pinned = state.localStore.getAllPinnedTabs(for: state.profileId)
            guard pinned.count == 3 else { return false }
            let first = pinned[0]
            let second = pinned[1]
            return first.guid == leftPinnedGuid
                && second.guid == rightPinnedGuid
                && first.splitPartnerGuid == rightPinnedGuid
                && second.splitPartnerGuid == leftPinnedGuid
        })

        let pinned = state.localStore.getAllPinnedTabs(for: state.profileId)
        guard pinned.count == 3 else { return }
        XCTAssertEqual(pinned.map(\.guid), [leftPinnedGuid, rightPinnedGuid, soloPinnedGuid])
    }

    func testPinnedTabToggleClearsSelection() throws {
        let state = try makeState()
        seed(state, guids: [1, 2])
        state.focuseTab(state.tabs[0])

        state.toggleMultiSelection(for: state.tabs[1])
        let pinned = Tab(guid: 99, url: "https://pinned.example", isActive: false, index: 0)
        pinned.isPinned = true
        state.toggleMultiSelection(for: pinned)
        XCTAssertFalse(state.multiSelection.isActive)
    }

    func testBookmarkGuidCanMixWithNormalTabSelection() throws {
        let state = try makeState()
        seed(state, guids: [1, 2])
        state.focuseTab(state.tabs[0])
        let bookmarkGuid = "bookmark-1"
        state.localStore.createBookmark(url: "https://bookmark.example",
                                        title: "Bookmark",
                                        profileId: state.profileId,
                                        parentId: nil,
                                        guid: bookmarkGuid,
                                        spaceId: state.spaceId)
        guard waitUntil(condition: {
            state.bookmarkManager.bookmark(withGuid: bookmarkGuid) != nil
        }) else { return }

        state.toggleMultiSelection(for: state.tabs[1])
        state.toggleBookmarkMultiSelection(bookmarkGuid: bookmarkGuid)

        XCTAssertEqual(state.multiSelection.guids, [2])
        XCTAssertEqual(state.multiSelection.bookmarkGuids, [bookmarkGuid])
        XCTAssertTrue(state.multiSelection.hasTabSelection)
        XCTAssertTrue(state.multiSelection.hasBookmarkSelection)
        XCTAssertFalse(state.multiSelectionContext.containsBookmarkFolder)
        XCTAssertTrue(state.multiSelectionContext.showsCloseItems)
    }

    func testBookmarkSelectionIncludesImplicitActiveNormalTabForContextAndDrag() throws {
        let state = try makeState()
        seed(state, guids: [1, 2])
        state.focuseTab(state.tabs[0])
        let bookmarkGuid = "bookmark-implicit-active"
        state.localStore.createBookmark(url: "https://bookmark.example",
                                        title: "Bookmark",
                                        profileId: state.profileId,
                                        parentId: nil,
                                        guid: bookmarkGuid,
                                        spaceId: state.spaceId)
        guard waitUntil(condition: {
            state.bookmarkManager.bookmark(withGuid: bookmarkGuid) != nil
        }) else { return }
        let bookmark = try XCTUnwrap(state.bookmarkManager.bookmark(withGuid: bookmarkGuid))

        state.toggleBookmarkMultiSelection(bookmarkGuid: bookmarkGuid)

        XCTAssertEqual(state.multiSelection.guids, [])
        XCTAssertEqual(state.multiSelection.bookmarkGuids, [bookmarkGuid])
        XCTAssertEqual(state.orderedMultiSelectedTabs.map(\.guid), [1])
        XCTAssertTrue(state.multiSelectionContext.showsCloseItems)
        XCTAssertEqual(state.multiSelectionDragTabIdsForBookmarkDrag(), [1])
        XCTAssertEqual(state.multiSelectionDragBookmarkGuids(startingFrom: bookmark), [bookmarkGuid])
    }

    func testBookmarkFolderSelectionDisablesTabOnlyActions() throws {
        let state = try makeState()
        seed(state, guids: [1, 2])
        state.focuseTab(state.tabs[0])
        let folderGuid = "folder-1"
        state.localStore.createDirectory(title: "Folder",
                                         profileId: state.profileId,
                                         parentId: nil,
                                         guid: folderGuid)
        guard waitUntil(condition: {
            state.bookmarkManager.bookmark(withGuid: folderGuid) != nil
        }) else { return }

        state.toggleMultiSelection(for: state.tabs[1])
        state.toggleBookmarkMultiSelection(bookmarkGuid: folderGuid)

        XCTAssertEqual(state.multiSelection.guids, [2])
        XCTAssertEqual(state.multiSelection.bookmarkGuids, [folderGuid])
        XCTAssertTrue(state.multiSelectionContext.containsBookmarkFolder)
        XCTAssertFalse(state.multiSelectionContext.canOpenAsSplit)
        XCTAssertFalse(state.multiSelectionContext.showsCloseItems)
    }

    func testReplaceMultiSelectionKeepsFolderAndChildButActionsUseRoots() throws {
        let state = try makeState()
        let folderGuid = "folder-root"
        let childGuid = "folder-child"
        state.localStore.createDirectory(title: "Folder",
                                         profileId: state.profileId,
                                         parentId: nil,
                                         guid: folderGuid)
        state.localStore.createBookmark(url: "https://child.example",
                                        title: "Child",
                                        profileId: state.profileId,
                                        parentId: folderGuid,
                                        guid: childGuid,
                                        spaceId: state.spaceId)
        guard waitUntil(condition: {
            state.bookmarkManager.bookmark(withGuid: folderGuid) != nil &&
                state.bookmarkManager.bookmark(withGuid: childGuid) != nil
        }) else { return }

        XCTAssertTrue(state.replaceMultiSelection(tabIds: [], bookmarkGuids: [folderGuid, childGuid]))

        XCTAssertEqual(state.multiSelection.bookmarkGuids, [folderGuid, childGuid])
        XCTAssertEqual(state.orderedMultiSelectedBookmarkRoots.map(\.guid), [folderGuid])
        let context = try XCTUnwrap(state.multiSelectionBookmarkDeletionContext)
        XCTAssertEqual(context.folderCount, 1)
        XCTAssertEqual(context.bookmarkCount, 0)
    }

    func testFolderMultiSelectionMenuHidesTabOnlyActions() throws {
        let state = try makeState()
        seed(state, guids: [1, 2])
        state.focuseTab(state.tabs[0])
        state.handleTabGroupCreated(token: "A",
                                    title: "Group A",
                                    color: .blue,
                                    isCollapsed: false,
                                    initialTabIds: [2])
        let folderGuid = "folder-1"
        state.localStore.createDirectory(title: "Folder",
                                         profileId: state.profileId,
                                         parentId: nil,
                                         guid: folderGuid)
        guard waitUntil(condition: {
            state.bookmarkManager.bookmark(withGuid: folderGuid) != nil
        }) else { return }
        state.toggleMultiSelection(for: state.tabs[1])
        state.toggleBookmarkMultiSelection(bookmarkGuid: folderGuid)
        let menu = NSMenu()

        XCTAssertTrue(TabMultiSelectionMenu.populateIfNeeded(menu, browserState: state))

        XCTAssertFalse(menu.items.contains { $0.title == "Open as Split" })
        XCTAssertFalse(menu.items.contains { $0.title == "Add Tabs to New Group" })
        XCTAssertFalse(menu.items.contains { $0.title == "Move Tabs to Group" })
        XCTAssertFalse(menu.items.contains { $0.title == "Close Tabs" })
        XCTAssertFalse(menu.items.contains { $0.title == "Close Other Tabs" })
        XCTAssertFalse(menu.items.last?.isSeparatorItem == true)
    }

    func testBookmarkDeleteMenuTitleCountsOnlyBookmarkRoots() throws {
        let state = try makeState()
        seed(state, guids: [1, 2])
        state.focuseTab(state.tabs[0])
        let firstFolderGuid = "folder-a"
        let secondFolderGuid = "folder-b"
        let childBookmarkGuid = "folder-a-child"
        let firstBookmarkGuid = "bookmark-a"
        let secondBookmarkGuid = "bookmark-b"
        state.localStore.createDirectory(title: "Folder A",
                                         profileId: state.profileId,
                                         parentId: nil,
                                         guid: firstFolderGuid)
        state.localStore.createDirectory(title: "Folder B",
                                         profileId: state.profileId,
                                         parentId: nil,
                                         guid: secondFolderGuid)
        state.localStore.createBookmark(url: "https://child.example",
                                        title: "Child",
                                        profileId: state.profileId,
                                        parentId: firstFolderGuid,
                                        guid: childBookmarkGuid,
                                        spaceId: state.spaceId)
        state.localStore.createBookmark(url: "https://first.example",
                                        title: "First",
                                        profileId: state.profileId,
                                        parentId: nil,
                                        guid: firstBookmarkGuid,
                                        spaceId: state.spaceId)
        state.localStore.createBookmark(url: "https://second.example",
                                        title: "Second",
                                        profileId: state.profileId,
                                        parentId: nil,
                                        guid: secondBookmarkGuid,
                                        spaceId: state.spaceId)
        guard waitUntil(condition: {
            [
                firstFolderGuid,
                secondFolderGuid,
                childBookmarkGuid,
                firstBookmarkGuid,
                secondBookmarkGuid
            ].allSatisfy { state.bookmarkManager.bookmark(withGuid: $0) != nil }
        }) else { return }

        state.toggleBookmarkMultiSelection(bookmarkGuid: firstFolderGuid)
        state.toggleBookmarkMultiSelection(bookmarkGuid: secondFolderGuid)
        XCTAssertEqual(deleteMenuItem(in: state)?.title, "Delete 2 Folders")

        state.clearMultiSelection()
        state.toggleBookmarkMultiSelection(bookmarkGuid: firstBookmarkGuid)
        state.toggleBookmarkMultiSelection(bookmarkGuid: secondBookmarkGuid)
        XCTAssertEqual(deleteMenuItem(in: state)?.title, "Delete 2 Bookmarks")

        state.clearMultiSelection()
        state.toggleMultiSelection(for: state.tabs[1])
        state.toggleBookmarkMultiSelection(bookmarkGuid: firstFolderGuid)
        state.toggleBookmarkMultiSelection(bookmarkGuid: childBookmarkGuid)
        state.toggleBookmarkMultiSelection(bookmarkGuid: firstBookmarkGuid)

        let context = try XCTUnwrap(state.multiSelectionBookmarkDeletionContext)
        XCTAssertEqual(context.folderCount, 1)
        XCTAssertEqual(context.bookmarkCount, 1)

        let deleteItem = try XCTUnwrap(deleteMenuItem(in: state))
        XCTAssertEqual(deleteItem.title, "Delete 2 Items")
        XCTAssertEqual(deleteItem.keyEquivalent, "d")
        XCTAssertEqual(deleteItem.keyEquivalentModifierMask, [.command])
    }

    func testDeletingMultiSelectedBookmarksDoesNotCloseNormalTabs() throws {
        let state = try makeState()
        let bookmarkGuid = "opened-bookmark"
        state.localStore.createBookmark(url: "https://bookmark.example",
                                        title: "Bookmark",
                                        profileId: state.profileId,
                                        parentId: nil,
                                        guid: bookmarkGuid,
                                        spaceId: state.spaceId)
        guard waitUntil(condition: {
            state.bookmarkManager.bookmark(withGuid: bookmarkGuid) != nil
        }) else { return }

        let activeWrapper = TestWebContentWrapper(urlString: "https://active.example")
        let selectedWrapper = TestWebContentWrapper(urlString: "https://selected.example")
        let bookmarkWrapper = TestWebContentWrapper(urlString: "https://bookmark.example")
        let activeTab = Tab(guid: 1,
                            url: "https://active.example",
                            isActive: false,
                            index: 0,
                            webContentView: activeWrapper)
        let selectedTab = Tab(guid: 2,
                              url: "https://selected.example",
                              isActive: false,
                              index: 1,
                              webContentView: selectedWrapper)
        let bookmarkTab = Tab(guid: 3,
                              url: "https://bookmark.example",
                              isActive: false,
                              index: 2,
                              title: "Bookmark",
                              webContentView: bookmarkWrapper,
                              customGuid: bookmarkGuid)
        state.tabs = [activeTab, selectedTab, bookmarkTab]
        state.handleBookmarkTabOpened(bookmarkTab)
        state.updateNormalTabs()
        state.focuseTab(activeTab)
        state.toggleMultiSelection(for: selectedTab)
        state.toggleBookmarkMultiSelection(bookmarkGuid: bookmarkGuid)

        XCTAssertTrue(state.deleteMultiSelectedBookmarks())

        XCTAssertEqual(activeWrapper.closeCallCount, 0)
        XCTAssertEqual(selectedWrapper.closeCallCount, 0)
        XCTAssertEqual(bookmarkWrapper.closeCallCount, 1)
        XCTAssertEqual(activeWrapper.updatedCustomValues, [])
        XCTAssertEqual(selectedWrapper.updatedCustomValues, [])
        XCTAssertEqual(bookmarkWrapper.updatedCustomValues, [""])
        XCTAssertNil(bookmarkTab.guidInLocalDB)
        XCTAssertFalse(state.multiSelection.isActive)
        XCTAssertTrue(waitUntil {
            state.bookmarkManager.bookmark(withGuid: bookmarkGuid) == nil
        })
    }

    func testFolderMultiSelectionMenuFiltersInvalidBookmarkFolderTargets() throws {
        let state = try makeState()
        seed(state, guids: [1, 2])
        let folderAGuid = "folder-a"
        let childGuid = "folder-a-1"
        let siblingGuid = "folder-b"
        state.localStore.createDirectory(title: "Folder A",
                                         profileId: state.profileId,
                                         parentId: nil,
                                         guid: folderAGuid)
        state.localStore.createDirectory(title: "Folder A-1",
                                         profileId: state.profileId,
                                         parentId: folderAGuid,
                                         guid: childGuid)
        state.localStore.createDirectory(title: "Folder B",
                                         profileId: state.profileId,
                                         parentId: nil,
                                         guid: siblingGuid)
        guard waitUntil(condition: {
            state.bookmarkManager.bookmark(withGuid: folderAGuid) != nil &&
                state.bookmarkManager.bookmark(withGuid: childGuid) != nil &&
                state.bookmarkManager.bookmark(withGuid: siblingGuid) != nil
        }) else { return }
        state.toggleMultiSelection(for: state.tabs[1])
        state.toggleBookmarkMultiSelection(bookmarkGuid: folderAGuid)
        let menu = NSMenu()

        XCTAssertTrue(TabMultiSelectionMenu.populateIfNeeded(menu, browserState: state))

        let addToFolderItem = try XCTUnwrap(menu.items.first { $0.title == "Add to Folder" })
        let submenu = try XCTUnwrap(addToFolderItem.submenu)
        let titles = submenu.items
            .filter { !$0.isSeparatorItem }
            .map(\.title)
        XCTAssertFalse(titles.contains("Folder A"))
        XCTAssertFalse(titles.contains("Folder A-1"))
        XCTAssertTrue(titles.contains("Folder B"))
        XCTAssertTrue(titles.contains("New Folder"))
    }

    func testAddToFolderMovesSelectedBookmarkRootsAndBookmarksSelectedTabs() throws {
        let state = try makeState()
        seed(state, guids: [1, 2])
        let sourceFolderGuid = "source-folder"
        let targetFolderGuid = "target-folder"
        state.localStore.createDirectory(title: "Source Folder",
                                         profileId: state.profileId,
                                         parentId: nil,
                                         guid: sourceFolderGuid)
        state.localStore.createDirectory(title: "Target Folder",
                                         profileId: state.profileId,
                                         parentId: nil,
                                         guid: targetFolderGuid)
        guard waitUntil(condition: {
            state.bookmarkManager.bookmark(withGuid: sourceFolderGuid) != nil &&
                state.bookmarkManager.bookmark(withGuid: targetFolderGuid) != nil
        }) else { return }
        let targetFolder = try XCTUnwrap(state.bookmarkManager.bookmark(withGuid: targetFolderGuid))
        state.toggleMultiSelection(for: state.tabs[0])
        state.toggleBookmarkMultiSelection(bookmarkGuid: sourceFolderGuid)

        XCTAssertTrue(state.bookmarkMultiSelectedTabs(into: targetFolder))

        XCTAssertTrue(waitUntil {
            let children = state.localStore.fetchBookmarks(parentId: targetFolderGuid,
                                                           profileId: state.profileId)
            return children.contains(where: { $0.guid == sourceFolderGuid && $0.dataType == .bookmarkFolder }) &&
                children.contains(where: { $0.url.absoluteString == "https://e1.example" })
        })
        XCTAssertFalse(state.multiSelection.isActive)
    }

    func testAddToFolderRejectsSelectedFolderDescendantTarget() throws {
        let state = try makeState()
        seed(state, guids: [1, 2])
        let folderAGuid = "folder-a"
        let childGuid = "folder-a-1"
        state.localStore.createDirectory(title: "Folder A",
                                         profileId: state.profileId,
                                         parentId: nil,
                                         guid: folderAGuid)
        state.localStore.createDirectory(title: "Folder A-1",
                                         profileId: state.profileId,
                                         parentId: folderAGuid,
                                         guid: childGuid)
        guard waitUntil(condition: {
            state.bookmarkManager.bookmark(withGuid: folderAGuid) != nil &&
                state.bookmarkManager.bookmark(withGuid: childGuid) != nil
        }) else { return }
        let childFolder = try XCTUnwrap(state.bookmarkManager.bookmark(withGuid: childGuid))
        state.toggleMultiSelection(for: state.tabs[0])
        state.toggleBookmarkMultiSelection(bookmarkGuid: folderAGuid)

        XCTAssertFalse(state.canBookmarkMultiSelection(into: childFolder))
        XCTAssertFalse(state.bookmarkMultiSelectedTabs(into: childFolder))
        XCTAssertTrue(state.multiSelection.isActive)
    }

    func testMoveBookmarkFolderToSpaceRetagsSubtree() throws {
        let state = try makeState()
        let targetSpaceId = "space-target"
        let context = try XCTUnwrap(state.localStore.getMainContext())
        context.insert(SpaceModel(spaceId: targetSpaceId,
                                  profileId: state.profileId,
                                  name: "Target",
                                  colorHex: "#000000",
                                  iconName: "circle",
                                  sortOrder: 1))
        try context.save()

        let folderGuid = "folder-root"
        let childGuid = "folder-child"
        state.localStore.createDirectory(title: "Folder",
                                         profileId: state.profileId,
                                         parentId: nil,
                                         guid: folderGuid,
                                         spaceId: state.spaceId)
        XCTAssertTrue(waitUntil {
            state.localStore.fetchBookmarks(parentId: nil,
                                            profileId: state.profileId,
                                            spaceId: state.spaceId).contains { $0.guid == folderGuid }
        })
        state.localStore.createBookmark(url: "https://child.example",
                                        title: "Child",
                                        profileId: state.profileId,
                                        parentId: folderGuid,
                                        guid: childGuid,
                                        spaceId: state.spaceId)
        XCTAssertTrue(waitUntil {
            state.localStore.fetchBookmarks(parentId: folderGuid,
                                            profileId: state.profileId,
                                            spaceId: state.spaceId).contains { $0.guid == childGuid }
        })

        state.localStore.moveBookmarks([folderGuid, childGuid],
                                       sourceProfileId: state.profileId,
                                       toSpaceId: targetSpaceId,
                                       targetProfileId: state.profileId)

        XCTAssertTrue(waitUntil {
            let targetRoots = state.localStore.fetchBookmarks(parentId: nil,
                                                              profileId: state.profileId,
                                                              spaceId: targetSpaceId)
            let targetChildren = state.localStore.fetchBookmarks(parentId: folderGuid,
                                                                 profileId: state.profileId,
                                                                 spaceId: targetSpaceId)
            return targetRoots.map(\.guid) == [folderGuid] &&
                targetChildren.contains { $0.guid == childGuid && $0.spaceId == targetSpaceId }
        })
        XCTAssertTrue(state.localStore.fetchBookmarks(parentId: nil,
                                                      profileId: state.profileId,
                                                      spaceId: state.spaceId).isEmpty)
    }

    func testCanMoveMultiSelectionAllowsLiveSplitTabWithSourceSlot() throws {
        let state = try makeState()
        seed(state, guids: [1, 2])
        state.splits = [
            SplitGroup(id: "split-1-2",
                       primaryTabId: 1,
                       secondaryTabId: 2,
                       layout: .vertical,
                       ratio: 0.5)
        ]
        state.focuseTab(state.tabs[0])
        state.toggleMultiSelection(for: state.tabs[1])

        XCTAssertTrue(state.canMoveMultiSelection(to: makeSpace(),
                                                  sourceHasSpaceSlot: true))
        XCTAssertFalse(state.canMoveMultiSelection(to: makeSpace(),
                                                   sourceHasSpaceSlot: false))
    }

    func testCanMoveMultiSelectionRejectsPinnedLiveSplitTab() throws {
        let state = try makeState()
        seed(state, guids: [1, 2])
        state.splits = [
            SplitGroup(id: "split-1-2",
                       primaryTabId: 1,
                       secondaryTabId: 2,
                       layout: .vertical,
                       ratio: 0.5,
                       isPinned: true)
        ]
        state.focuseTab(state.tabs[0])
        state.toggleMultiSelection(for: state.tabs[1])

        XCTAssertFalse(state.canMoveMultiSelection(to: makeSpace(),
                                                   sourceHasSpaceSlot: true))
    }

    func testCanMoveMultiSelectionRejectsCrossProfileSplitWithMissingURL() throws {
        let state = try makeState()
        seed(state, guids: [1, 2])
        state.tabs[1].url = nil
        state.splits = [
            SplitGroup(id: "split-1-2",
                       primaryTabId: 1,
                       secondaryTabId: 2,
                       layout: .vertical,
                       ratio: 0.5)
        ]
        state.focuseTab(state.tabs[0])
        state.toggleMultiSelection(for: state.tabs[1])

        XCTAssertFalse(state.canMoveMultiSelection(to: makeSpace(profileId: "Profile-B"),
                                                   sourceHasSpaceSlot: true))
    }

    func testSpaceMoveUnitsExpandLiveSplitAsTwoNormalTabs() throws {
        let state = try makeState()
        seed(state, guids: [1, 2, 3, 4])
        state.splits = [
            SplitGroup(id: "split-2-3",
                       primaryTabId: 2,
                       secondaryTabId: 3,
                       layout: .vertical,
                       ratio: 0.5)
        ]
        let units = SpaceManager.shared.tabMoveUnits(from: [state.tabs[1], state.tabs[3]],
                                                     sourceState: state)

        XCTAssertEqual(units.map(\.normalTabCount), [2, 1])
        guard case .split(let left, let right) = units.first else {
            return XCTFail("Expected the selected split pane to move as a split unit.")
        }
        XCTAssertEqual(left.guid, 2)
        XCTAssertEqual(right.guid, 3)
    }

    func testTwoUnopenedBookmarkTabsCanOpenAsSplit() throws {
        let state = try makeState()
        let firstGuid = "bookmark-left"
        let secondGuid = "bookmark-right"
        state.localStore.createBookmark(url: "https://left.example",
                                        title: "Left",
                                        profileId: state.profileId,
                                        parentId: nil,
                                        guid: firstGuid,
                                        spaceId: state.spaceId)
        state.localStore.createBookmark(url: "https://right.example",
                                        title: "Right",
                                        profileId: state.profileId,
                                        parentId: nil,
                                        guid: secondGuid,
                                        spaceId: state.spaceId)
        guard waitUntil(condition: {
            state.bookmarkManager.bookmark(withGuid: firstGuid) != nil &&
            state.bookmarkManager.bookmark(withGuid: secondGuid) != nil
        }) else { return }

        state.toggleBookmarkMultiSelection(bookmarkGuid: firstGuid)
        state.toggleBookmarkMultiSelection(bookmarkGuid: secondGuid)
        let menu = NSMenu()

        XCTAssertTrue(state.multiSelectionContext.canOpenAsSplit)
        XCTAssertTrue(TabMultiSelectionMenu.populateIfNeeded(menu, browserState: state))
        XCTAssertTrue(menu.items.contains { $0.title == "Open as Split" })

        state.openMultiSelectedTabsAsSplit()

        let pending = try XCTUnwrap(state.pendingPrimarySplitTargetByGuid.values.first)
        XCTAssertEqual(pending.secondaryURL, "https://right.example")
        XCTAssertNil(pending.boundBookmarkGuid)
        XCTAssertFalse(state.multiSelection.isActive)
    }

    func testOpenAsSplitDetachesTwoOpenedBookmarkTabs() throws {
        let state = try makeState()
        let firstGuid = "opened-bookmark-left"
        let secondGuid = "opened-bookmark-right"
        state.localStore.createBookmark(url: "https://left.example",
                                        title: "Left",
                                        profileId: state.profileId,
                                        parentId: nil,
                                        guid: firstGuid,
                                        spaceId: state.spaceId)
        state.localStore.createBookmark(url: "https://right.example",
                                        title: "Right",
                                        profileId: state.profileId,
                                        parentId: nil,
                                        guid: secondGuid,
                                        spaceId: state.spaceId)
        guard waitUntil(condition: {
            state.bookmarkManager.bookmark(withGuid: firstGuid) != nil &&
            state.bookmarkManager.bookmark(withGuid: secondGuid) != nil
        }) else { return }
        let firstBookmark = try XCTUnwrap(state.bookmarkManager.bookmark(withGuid: firstGuid))
        let secondBookmark = try XCTUnwrap(state.bookmarkManager.bookmark(withGuid: secondGuid))
        let firstWrapper = TestWebContentWrapper(urlString: "https://left.example")
        let secondWrapper = TestWebContentWrapper(urlString: "https://right.example")
        let firstTab = Tab(guid: 1,
                           url: "https://left.example",
                           isActive: false,
                           index: 0,
                           title: "Left",
                           webContentView: firstWrapper,
                           customGuid: firstGuid)
        let secondTab = Tab(guid: 2,
                            url: "https://right.example",
                            isActive: false,
                            index: 1,
                            title: "Right",
                            webContentView: secondWrapper,
                            customGuid: secondGuid)
        state.tabs = [firstTab, secondTab]
        state.handleBookmarkTabOpened(firstTab)
        state.handleBookmarkTabOpened(secondTab)
        state.updateNormalTabs()

        state.toggleBookmarkMultiSelection(bookmarkGuid: firstGuid)
        state.toggleBookmarkMultiSelection(bookmarkGuid: secondGuid)

        XCTAssertTrue(state.multiSelectionContext.canOpenAsSplit)
        state.openMultiSelectedTabsAsSplit()

        XCTAssertNil(firstTab.guidInLocalDB)
        XCTAssertNil(secondTab.guidInLocalDB)
        XCTAssertEqual(firstWrapper.updatedCustomValues, [""])
        XCTAssertEqual(secondWrapper.updatedCustomValues, [""])
        XCTAssertFalse(firstBookmark.isOpened)
        XCTAssertFalse(secondBookmark.isOpened)
        XCTAssertEqual(state.normalTabs.map(\.guid), [1, 2])
    }

    func testOpenAsSplitReusesOpenedBookmarkTabAndCreatesMissingBookmarkPane() throws {
        let state = try makeState()
        let openedGuid = "opened-bookmark"
        let unopenedGuid = "unopened-bookmark"
        state.localStore.createBookmark(url: "https://opened.example",
                                        title: "Opened",
                                        profileId: state.profileId,
                                        parentId: nil,
                                        guid: openedGuid,
                                        spaceId: state.spaceId)
        state.localStore.createBookmark(url: "https://unopened.example",
                                        title: "Unopened",
                                        profileId: state.profileId,
                                        parentId: nil,
                                        guid: unopenedGuid,
                                        spaceId: state.spaceId)
        guard waitUntil(condition: {
            state.bookmarkManager.bookmark(withGuid: openedGuid) != nil &&
            state.bookmarkManager.bookmark(withGuid: unopenedGuid) != nil
        }) else { return }
        let openedBookmark = try XCTUnwrap(state.bookmarkManager.bookmark(withGuid: openedGuid))
        let wrapper = TestWebContentWrapper(urlString: "https://opened.example")
        let openedTab = Tab(guid: 7,
                            url: "https://opened.example",
                            isActive: false,
                            index: 0,
                            title: "Opened",
                            webContentView: wrapper,
                            customGuid: openedGuid)
        state.tabs = [openedTab]
        state.handleBookmarkTabOpened(openedTab)
        state.updateNormalTabs()
        state.focuseTab(openedTab)

        state.toggleBookmarkMultiSelection(bookmarkGuid: unopenedGuid)
        let menu = NSMenu()

        XCTAssertEqual(state.multiSelection.bookmarkGuids, [unopenedGuid])
        XCTAssertEqual(state.multiSelectionContext.bookmarkGuids, [openedGuid, unopenedGuid])
        XCTAssertTrue(state.multiSelectionContext.canOpenAsSplit)
        XCTAssertTrue(TabMultiSelectionMenu.populateIfNeeded(menu, browserState: state))
        XCTAssertTrue(menu.items.contains { $0.title == "Open as Split" })
        state.openMultiSelectedTabsAsSplit()

        let pending = try XCTUnwrap(state.pendingSplitPartnerByCustomGuid.values.first)
        XCTAssertNil(openedTab.guidInLocalDB)
        XCTAssertEqual(wrapper.updatedCustomValues, [""])
        XCTAssertFalse(openedBookmark.isOpened)
        XCTAssertEqual(pending.partnerTabId, openedTab.guid)
        guard case .right = pending.newTabSlot else {
            return XCTFail("Unopened bookmark should be created as the right split pane.")
        }
        XCTAssertNil(pending.boundBookmarkGuid)
        XCTAssertFalse(state.multiSelection.isActive)
    }

    func testActiveBookmarkTabCanCrossSelectNormalTab() throws {
        let state = try makeState()
        let bookmarkGuid = "bookmark-1"
        state.localStore.createBookmark(url: "https://bookmark.example",
                                        title: "Bookmark",
                                        profileId: state.profileId,
                                        parentId: nil,
                                        guid: bookmarkGuid,
                                        spaceId: state.spaceId)
        guard waitUntil(condition: {
            state.bookmarkManager.bookmark(withGuid: bookmarkGuid) != nil
        }) else { return }
        guard let bookmark = state.bookmarkManager.bookmark(withGuid: bookmarkGuid) else {
            return XCTFail("Bookmark was not indexed.")
        }

        let normalTab = Tab(guid: 1,
                            url: "https://normal.example",
                            isActive: false,
                            index: 0)
        let bookmarkWrapper = TestWebContentWrapper(urlString: "https://bookmark.example")
        let bookmarkTab = Tab(guid: 2,
                              url: "https://bookmark.example",
                              isActive: false,
                              index: 1,
                              title: "Bookmark",
                              webContentView: bookmarkWrapper,
                              customGuid: bookmarkGuid)
        state.tabs = [normalTab, bookmarkTab]
        bookmark.isOpened = true
        bookmark.chromiumTabGuid = bookmarkTab.guid
        state.updateNormalTabs()

        state.focuseTab(bookmarkTab)
        state.toggleMultiSelection(for: normalTab)

        XCTAssertEqual(state.focusingTab?.guid, bookmarkTab.guid)
        XCTAssertTrue(state.multiSelection.isActive)
        XCTAssertEqual(state.multiSelection.guids, [normalTab.guid])
        XCTAssertEqual(state.multiSelection.bookmarkGuids, [bookmark.guid])
        XCTAssertEqual(state.orderedMultiSelectedTabs.map(\.guid), [normalTab.guid])
        XCTAssertEqual(bookmarkWrapper.setAsActiveTabCallCount, 0)
    }

    func testActiveSplitBookmarkCanCrossSelectNormalTabOrSplitPair() throws {
        let state = try makeState()
        let bookmarkGuid = "split-bookmark-1"
        state.localStore.createBookmark(url: "https://e1.example",
                                        title: "Split Bookmark",
                                        profileId: state.profileId,
                                        parentId: nil,
                                        guid: bookmarkGuid,
                                        spaceId: state.spaceId,
                                        secondaryUrl: "https://e2.example")
        guard waitUntil(condition: {
            state.bookmarkManager.bookmark(withGuid: bookmarkGuid) != nil
        }) else { return }
        guard let bookmark = state.bookmarkManager.bookmark(withGuid: bookmarkGuid) else {
            return XCTFail("Bookmark was not indexed.")
        }
        seed(state, guids: [1, 2, 3, 4, 5])
        let primaryWrapper = TestWebContentWrapper(urlString: "https://e1.example")
        state.tabs[0].setWebContentsWrapper(wrapper: primaryWrapper)
        state.splits = [
            SplitGroup(id: "split-bookmark",
                       primaryTabId: 1,
                       secondaryTabId: 2,
                       layout: .vertical,
                       ratio: 0.5),
            SplitGroup(id: "split-normal",
                       primaryTabId: 4,
                       secondaryTabId: 5,
                       layout: .vertical,
                       ratio: 0.5)
        ]
        state.splitBookmarkBindings[bookmarkGuid] = "split-bookmark"
        state.updateNormalTabs()

        state.focuseTab(state.tabs[0])
        state.toggleMultiSelection(for: state.tabs[2])

        XCTAssertEqual(state.focusingTab?.guid, 1)
        XCTAssertEqual(state.multiSelection.guids, [3])
        XCTAssertEqual(state.multiSelection.bookmarkGuids, [bookmark.guid])

        state.openBookmark(bookmark)

        XCTAssertEqual(state.focusingTab?.guid, 1)
        XCTAssertTrue(state.tabs[0].isActive)
        XCTAssertFalse(state.tabs[2].isActive)
        XCTAssertEqual(primaryWrapper.setAsActiveTabCallCount, 1)
        XCTAssertFalse(state.multiSelection.isActive)

        state.focuseTab(state.tabs[0])
        let handled = state.toggleMultiSelectionForSplitPair(leftTab: state.tabs[3],
                                                             rightTab: state.tabs[4])

        XCTAssertTrue(handled)
        XCTAssertEqual(state.multiSelection.guids, [4, 5])
        XCTAssertEqual(state.multiSelection.bookmarkGuids, [bookmark.guid])
    }

    func testActiveBookmarkTabCanCrossSelectNormalSplitPair() throws {
        let state = try makeState()
        let bookmarkGuid = "bookmark-2"
        state.localStore.createBookmark(url: "https://bookmark.example",
                                        title: "Bookmark",
                                        profileId: state.profileId,
                                        parentId: nil,
                                        guid: bookmarkGuid,
                                        spaceId: state.spaceId)
        guard waitUntil(condition: {
            state.bookmarkManager.bookmark(withGuid: bookmarkGuid) != nil
        }) else { return }
        state.tabs = [
            Tab(guid: 1,
                url: "https://bookmark.example",
                isActive: false,
                index: 0,
                title: "Bookmark",
                customGuid: bookmarkGuid),
            Tab(guid: 2, url: "https://e2.example", isActive: false, index: 1),
            Tab(guid: 3, url: "https://e3.example", isActive: false, index: 2)
        ]
        state.splits = [
            SplitGroup(id: "split-normal",
                       primaryTabId: 2,
                       secondaryTabId: 3,
                       layout: .vertical,
                       ratio: 0.5)
        ]
        state.updateNormalTabs()
        state.focuseTab(state.tabs[0])

        let handled = state.toggleMultiSelectionForSplitPair(leftTab: state.tabs[1],
                                                             rightTab: state.tabs[2])

        XCTAssertTrue(handled)
        XCTAssertEqual(state.multiSelection.guids, [2, 3])
        XCTAssertEqual(state.multiSelection.bookmarkGuids, [bookmarkGuid])
    }

    func testAddToGroupDedupsTabsAlreadyInThatGroup() throws {
        let state = try makeState()
        state.tabs = [
            Tab(guid: 1, url: "https://1", isActive: false, index: 0),
            Tab(guid: 2, url: "https://2", isActive: false, index: 0),
            Tab(guid: 3, url: "https://3", isActive: false, index: 0),
        ]
        state.tabs[1].groupToken = "A"
        state.updateNormalTabs()
        state.focuseTab(state.tabs[0])
        state.toggleMultiSelection(for: state.tabs[1])
        state.toggleMultiSelection(for: state.tabs[2])
        let targets = state.multiSelectionTargets(forAddingToGroup: "A")
        XCTAssertEqual(targets.map(\.guid), [1, 3])
    }

    func testMultiSelectionSplitPairRequiresExactlyTwoPlainTabs() throws {
        let state = try makeState()
        seed(state, guids: [1, 2, 3])
        state.focuseTab(state.tabs[0])
        state.toggleMultiSelection(for: state.tabs[1])

        XCTAssertEqual(state.multiSelectionSplitPair?.left.guid, 1)
        XCTAssertEqual(state.multiSelectionSplitPair?.right.guid, 2)

        state.toggleMultiSelection(for: state.tabs[2])

        XCTAssertNil(state.multiSelectionSplitPair)
    }

    func testMultiSelectionSplitPairRejectsExistingSplitPane() throws {
        let state = try makeState()
        seed(state, guids: [1, 2, 3])
        state.splits = [
            SplitGroup(id: "split-1-2",
                       primaryTabId: 1,
                       secondaryTabId: 2,
                       layout: .vertical,
                       ratio: 0.5)
        ]
        state.focuseTab(state.tabs[0])
        state.toggleMultiSelection(for: state.tabs[1])

        XCTAssertNil(state.multiSelectionSplitPair)
    }

    func testSplitPairSidebarContextMenuUsesMultiSelectionMenuWhenSelectionActive() throws {
        let state = try makeState()
        seed(state, guids: [1, 2, 3])
        state.splits = [
            SplitGroup(id: "split-2-3",
                       primaryTabId: 2,
                       secondaryTabId: 3,
                       layout: .vertical,
                       ratio: 0.5)
        ]
        state.focuseTab(state.tabs[0])
        state.toggleMultiSelectionForSplitPair(leftTab: state.tabs[1], rightTab: state.tabs[2])

        let item = SplitPairSidebarItem(groupId: "split-2-3",
                                        leftTab: state.tabs[1],
                                        rightTab: state.tabs[2],
                                        browserState: state)
        let menu = NSMenu()

        item.makeContextMenu(on: menu)

        XCTAssertEqual(menu.items.first?.title, "Duplicate Tabs")
        XCTAssertFalse(menu.items.contains { $0.title == "Duplicate Split" })
    }

    func testDuplicateMultiSelectionPreservesSplitPair() throws {
        let state = try makeState()
        seed(state, guids: [1, 2, 3, 4])
        state.splits = [
            SplitGroup(id: "split-2-3",
                       primaryTabId: 2,
                       secondaryTabId: 3,
                       layout: .vertical,
                       ratio: 0.5)
        ]
        state.focuseTab(state.tabs[0])
        state.toggleMultiSelectionForSplitPair(leftTab: state.tabs[1], rightTab: state.tabs[2])
        state.toggleMultiSelection(for: state.tabs[3])

        state.duplicateMultiSelectedTabs()

        XCTAssertFalse(state.multiSelection.isActive)
        XCTAssertEqual(state.pendingPrimarySplitTargetByGuid.count, 1)
        XCTAssertEqual(state.pendingPrimarySplitTargetByGuid.values.first?.secondaryURL,
                       "https://e3.example")
    }

    func testClosingSelectedTabPrunesSelection() throws {
        let state = try makeState()
        seed(state, guids: [1, 2, 3])
        state.focuseTab(state.tabs[0])
        state.toggleMultiSelection(for: state.tabs[1])
        state.toggleMultiSelection(for: state.tabs[2])
        XCTAssertEqual(state.multiSelection.guids, [2, 3])

        state.tabs.removeAll { $0.guid == 2 }
        state.updateNormalTabs()

        XCTAssertEqual(state.multiSelection.guids, [3])
    }

    private func deleteMenuItem(in state: BrowserState) -> NSMenuItem? {
        let menu = NSMenu()
        guard TabMultiSelectionMenu.populateIfNeeded(menu, browserState: state) else {
            return nil
        }
        guard let item = menu.items.last, !item.isSeparatorItem else {
            return nil
        }
        guard item.action == #selector(TabMultiSelectionMenuController.deleteSelectedBookmarks) else {
            return nil
        }
        return item
    }
}

private final class TestWebContentWrapper: NSObject, WebContentWrapper {
    @objc dynamic weak var nativeView: NSView?
    @objc dynamic var isLoading = false
    @objc dynamic var loadingState = PhiTabLoadingState(rawValue: 0)!
    @objc dynamic var isFocused = false
    @objc dynamic var loadProgress: CGFloat = 1
    @objc dynamic var favIconURL: String?
    @objc dynamic var favIconData: Data?
    @objc dynamic var favIconRevision = 0
    @objc dynamic var canGoBack = false
    @objc dynamic var canGoForward = false
    @objc dynamic var title: String?
    @objc dynamic var urlString: String?
    @objc dynamic var securityInfo: [String: Any]?
    @objc dynamic var isCurrentlyAudible = false
    @objc dynamic var isAudioMuted = false
    @objc dynamic var isCapturingAudio = false
    @objc dynamic var isCapturingVideo = false
    @objc dynamic var isCapturingWindow = false
    @objc dynamic var isCapturingDisplay = false
    @objc dynamic var isCapturingTab = false
    @objc dynamic var isBeingMirrored = false
    @objc dynamic var isSharingScreen = false
    @objc dynamic var isInContentFullscreen = false

    private(set) var setAsActiveTabCallCount = 0
    private(set) var updatedCustomValues: [String] = []
    private(set) var closeCallCount = 0

    init(urlString: String?) {
        self.urlString = urlString
        super.init()
    }

    func close() { closeCallCount += 1 }
    func reload() {}
    func reloadBypassingCache() {}
    func goBack() {}
    func goForward() {}
    func stopLoading() {}
    func navigate(toURL urlString: String) { self.urlString = urlString }
    func setAsActiveTab() { setAsActiveTabCallCount += 1 }
    func moveSelf(to newIndex: Int, selectAfterMove: Bool) {}
    func moveSelf(toNewWindow activateNewWindow: Bool) {}
    func moveSelf(toWindow targetWindowId: Int64, at insertIndex: Int) {}
    func moveSelf(toWindow targetWindowId: Int64,
                  andAddToGroupTokenHex targetGroupTokenHex: String,
                  beforeTabId anchorTabId: Int64) {}
    func moveSelf(toWindow targetWindowId: Int64,
                  andAddToGroupTokenHex targetGroupTokenHex: String,
                  afterTabId anchorTabId: Int64) {}
    func moveSplit(toNewWindow activateNewWindow: Bool) {}
    func moveSplit(toWindow targetWindowId: Int64, at insertIndex: Int) {}
    func updateTabCustomValue(_ customValue: String) { updatedCustomValues.append(customValue) }
    func focus() {}
    func restoreFocus() {}
    func updateSecurityState(_ securityState: [AnyHashable: Any]) {}
    func setAudioMuted(_ muted: Bool) {}
    func muteAudio() {}
    func unmuteAudio() {}
}

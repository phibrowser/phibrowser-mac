// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

@MainActor
final class BookmarkManagerScopeTests: XCTestCase {
    private var tempDirectories: [URL] = []
    private var stores: [LocalStore] = []

    override func tearDown() async throws {
        for store in stores {
            await store.performBackgroundWriteAndWait { _ in }
        }
        stores.removeAll()
        await Task.yield()
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    func testManagerCapturesBrowserStateScope() throws {
        let state = try makeState(
            accountId: "scope-account",
            profileId: "Profile 1",
            spaceId: "scope-space"
        )

        XCTAssertEqual(
            state.bookmarkManager.scope,
            BookmarkManagementScope(
                accountId: "scope-account",
                profileId: "Profile 1",
                spaceId: "scope-space"
            )
        )
    }

    func testAddFolderAcceptsCallerSuppliedGuid() throws {
        let state = try makeState()
        let folderGuid = "manager-created-folder"

        state.bookmarkManager.addFolder(title: "Managed Folder", guid: folderGuid)

        XCTAssertTrue(waitUntil {
            state.bookmarkManager.bookmark(withGuid: folderGuid)?.title == "Managed Folder"
        })
    }

    func testAddFolderInsertsAtRequestedChildIndex() throws {
        let state = try makeState()
        let parentGuid = "parent-folder"
        let existingGuid = "existing-child"
        let insertedGuid = "inserted-child"

        state.bookmarkManager.addFolder(title: "Parent", guid: parentGuid)
        XCTAssertTrue(waitUntil {
            state.bookmarkManager.bookmark(withGuid: parentGuid) != nil
        })

        var parent = try XCTUnwrap(state.bookmarkManager.bookmark(withGuid: parentGuid))
        state.bookmarkManager.addFolder(
            title: "Existing",
            to: parent,
            guid: existingGuid
        )
        XCTAssertTrue(waitUntil {
            state.bookmarkManager.bookmark(withGuid: existingGuid) != nil
        })

        parent = try XCTUnwrap(state.bookmarkManager.bookmark(withGuid: parentGuid))
        state.bookmarkManager.addFolder(
            title: "Inserted",
            to: parent,
            guid: insertedGuid,
            targetIndex: 0
        )

        XCTAssertTrue(waitUntil {
            state.bookmarkManager.bookmark(withGuid: parentGuid)?.children.map(\.guid)
                == [insertedGuid, existingGuid]
        })
    }

    func testNewBookmarkManagerTabUsesNativeTitle() throws {
        let state = try makeState()
        let tab = Tab(
            guid: 42,
            url: "chrome://bookmarks",
            isActive: false,
            index: 0,
            title: "chrome://bookmarks"
        )

        state.handleNewTabFromChromium(tab)

        XCTAssertEqual(tab.title, BookmarkManagerRoute.tabTitle)

        state.updateTabTitle(tabId: tab.guid, newTitle: "chrome://bookmarks")
        XCTAssertEqual(tab.title, BookmarkManagerRoute.tabTitle)

        tab.url = "https://example.com"
        state.updateTabTitle(tabId: tab.guid, newTitle: "Example")
        XCTAssertEqual(tab.title, "Example")
    }

    func testSidebarReordersLastBookmarkInsideFolderWithoutChangingDropRules() throws {
        let state = try makeState()
        let manager = state.bookmarkManager
        manager.addFolder(title: "Drag Test", guid: "drag-folder")
        XCTAssertTrue(waitUntil { manager.bookmark(withGuid: "drag-folder") != nil })
        let folder = try XCTUnwrap(manager.bookmark(withGuid: "drag-folder"))
        for title in ["A", "B", "C"] {
            manager.addBookmark(title: title, url: "https://\(title.lowercased()).example", to: folder)
        }
        XCTAssertTrue(waitUntil { folder.children.map(\.title) == ["A", "B", "C"] })
        let section = BookmarkSectionController(browserState: state)
        let last = try XCTUnwrap(folder.children.last)

        // Validation has no insertion index: a last child can still move upward.
        XCTAssertTrue(section.canAcceptDrop(of: last, to: folder))
        XCTAssertTrue(section.handleDrop(of: last, to: folder, at: 1))
        XCTAssertTrue(waitUntil { folder.children.map(\.title) == ["A", "C", "B"] })

        // AppKit's pre-removal index must still be adjusted for downward moves.
        XCTAssertTrue(section.canAcceptDrop(of: last, to: folder))
        XCTAssertTrue(section.handleDrop(of: last, to: folder, at: 3))
        XCTAssertTrue(waitUntil { folder.children.map(\.title) == ["A", "B", "C"] })
        XCTAssertTrue(section.canAcceptDrop(of: last, to: folder))
        XCTAssertFalse(section.handleDrop(of: last, to: folder, at: 3))
    }

    func testSidebarStillRejectsFolderSelfAndDescendantDrops() throws {
        let state = try makeState()
        let section = BookmarkSectionController(browserState: state)
        let parent = Bookmark(folderTitle: "Parent")
        let child = Bookmark(folderTitle: "Child")
        parent.addChild(child)

        XCTAssertFalse(section.canAcceptDrop(of: parent, to: parent))
        XCTAssertFalse(section.handleDrop(of: parent, to: parent, at: nil))
        XCTAssertFalse(section.canAcceptDrop(of: parent, to: child))
        XCTAssertFalse(section.handleDrop(of: parent, to: child, at: nil))
        XCTAssertTrue(section.canAcceptDrop(of: child, to: nil))
    }

    func testExplicitBatchSpaceMoveDetachesLiveBookmarkBindings() throws {
        let state = try makeState()
        let targetModel = SpaceModel(
            spaceId: "batch-target",
            profileId: state.profileId,
            name: "Target",
            colorHex: "#000000",
            iconName: "circle",
            sortOrder: 1
        )
        let context = try XCTUnwrap(state.localStore.getMainContext())
        context.insert(targetModel)
        try context.save()
        let targetSpace = try XCTUnwrap(state.localStore.getAllSpaces().first {
            $0.spaceId == targetModel.spaceId
        })

        let normalGuid = "live-normal-bookmark"
        let splitGuid = "live-split-bookmark"
        state.localStore.createBookmark(
            url: "https://normal.example",
            title: "Normal",
            profileId: state.profileId,
            parentId: nil,
            guid: normalGuid,
            spaceId: state.spaceId
        )
        state.localStore.createBookmark(
            url: "https://left.example",
            title: "Split",
            profileId: state.profileId,
            parentId: nil,
            guid: splitGuid,
            spaceId: state.spaceId,
            secondaryUrl: "https://right.example"
        )
        guard waitUntil(condition: {
            state.bookmarkManager.bookmark(withGuid: normalGuid) != nil &&
                state.bookmarkManager.bookmark(withGuid: splitGuid) != nil
        }) else { return }

        let normalTab = Tab(
            guid: 1,
            url: "https://normal.example",
            isActive: false,
            index: 0
        )
        normalTab.guidInLocalDB = normalGuid
        state.tabs = [
            normalTab,
            Tab(guid: 2, url: "https://left.example", isActive: false, index: 1),
            Tab(guid: 3, url: "https://right.example", isActive: false, index: 2),
        ]
        state.splits = [
            SplitGroup(
                id: "live-split",
                primaryTabId: 2,
                secondaryTabId: 3,
                layout: .vertical,
                ratio: 0.5
            )
        ]
        state.splitBookmarkBindings[splitGuid] = "live-split"

        XCTAssertFalse(state.multiSelection.isActive)
        XCTAssertTrue(
            state.moveBookmarks(
                bookmarkGuids: [normalGuid, splitGuid],
                to: targetSpace
            )
        )
        XCTAssertNil(normalTab.guidInLocalDB)
        XCTAssertNil(state.splitBookmarkBindings[splitGuid])
        XCTAssertTrue(waitUntil {
            Set(
                state.localStore.fetchBookmarks(
                    parentId: nil,
                    profileId: targetSpace.profileId,
                    spaceId: targetSpace.spaceId
                ).map(\.guid)
            ) == [normalGuid, splitGuid]
        })
    }

    func testExplicitBatchSpaceClonePreservesLiveBindingsAndSplitMetadata() throws {
        let state = try makeState()
        let targetModel = SpaceModel(
            spaceId: "batch-clone-target",
            profileId: state.profileId,
            name: "Target",
            colorHex: "#000000",
            iconName: "circle",
            sortOrder: 1
        )
        let context = try XCTUnwrap(state.localStore.getMainContext())
        context.insert(targetModel)
        try context.save()
        let targetSpace = try XCTUnwrap(state.localStore.getAllSpaces().first {
            $0.spaceId == targetModel.spaceId
        })

        let normalGuid = "clone-live-normal-bookmark"
        let splitGuid = "clone-live-split-bookmark"
        let splitFavicon = Data([0x01, 0x02, 0x03])
        state.localStore.createBookmark(
            url: "https://normal.example",
            title: "Normal",
            profileId: state.profileId,
            parentId: nil,
            guid: normalGuid,
            spaceId: state.spaceId
        )
        state.localStore.createBookmark(
            url: "https://left.example",
            title: "Split",
            profileId: state.profileId,
            parentId: nil,
            guid: splitGuid,
            spaceId: state.spaceId,
            secondaryUrl: "https://right.example",
            secondaryTitle: "Right",
            favicon: splitFavicon
        )
        guard waitUntil(condition: {
            state.bookmarkManager.bookmark(withGuid: normalGuid) != nil &&
                state.bookmarkManager.bookmark(withGuid: splitGuid) != nil
        }) else { return }

        let normalTab = Tab(
            guid: 1,
            url: "https://normal.example",
            isActive: false,
            index: 0
        )
        normalTab.guidInLocalDB = normalGuid
        state.tabs = [
            normalTab,
            Tab(guid: 2, url: "https://left.example", isActive: false, index: 1),
            Tab(guid: 3, url: "https://right.example", isActive: false, index: 2),
        ]
        state.splits = [
            SplitGroup(
                id: "clone-live-split",
                primaryTabId: 2,
                secondaryTabId: 3,
                layout: .vertical,
                ratio: 0.5
            )
        ]
        state.splitBookmarkBindings[splitGuid] = "clone-live-split"

        XCTAssertFalse(state.multiSelection.isActive)
        XCTAssertTrue(
            state.canCloneBookmarks(
                bookmarkGuids: [normalGuid, splitGuid],
                to: targetSpace
            )
        )
        XCTAssertTrue(
            state.cloneBookmarks(
                bookmarkGuids: [normalGuid, splitGuid],
                to: targetSpace
            )
        )
        XCTAssertEqual(normalTab.guidInLocalDB, normalGuid)
        XCTAssertEqual(state.splitBookmarkBindings[splitGuid], "clone-live-split")
        XCTAssertFalse(state.multiSelection.isActive)

        XCTAssertTrue(waitUntil {
            state.localStore.fetchBookmarks(
                parentId: nil,
                profileId: targetSpace.profileId,
                spaceId: targetSpace.spaceId
            ).count == 2
        })
        let sourceBookmarks = state.localStore.fetchBookmarks(
            parentId: nil,
            profileId: state.profileId,
            spaceId: state.spaceId
        )
        let clonedBookmarks = state.localStore.fetchBookmarks(
            parentId: nil,
            profileId: targetSpace.profileId,
            spaceId: targetSpace.spaceId
        )
        let clonedNormal = try XCTUnwrap(clonedBookmarks.first { $0.title == "Normal" })
        let clonedSplit = try XCTUnwrap(clonedBookmarks.first { $0.title == "Split" })

        XCTAssertEqual(Set(sourceBookmarks.map(\.guid)), [normalGuid, splitGuid])
        XCTAssertNotEqual(clonedNormal.guid, normalGuid)
        XCTAssertNotEqual(clonedSplit.guid, splitGuid)
        XCTAssertEqual(clonedSplit.url.absoluteString, "https://left.example")
        XCTAssertEqual(clonedSplit.secondaryUrl?.absoluteString, "https://right.example")
        XCTAssertEqual(clonedSplit.secondaryTitle, "Right")
        XCTAssertEqual(clonedSplit.favicon, splitFavicon)
    }

    func testExplicitBatchSpaceTransferEligibilityRejectsInvalidTargets() throws {
        let state = try makeState()
        let bookmarkGuid = "batch-transfer-eligibility"
        state.localStore.createBookmark(
            url: "https://bookmark.example",
            title: "Bookmark",
            profileId: state.profileId,
            parentId: nil,
            guid: bookmarkGuid,
            spaceId: state.spaceId
        )
        guard waitUntil(condition: {
            state.bookmarkManager.bookmark(withGuid: bookmarkGuid) != nil
        }) else { return }

        let validTarget = Space(
            spaceId: "batch-valid-target",
            profileId: state.profileId,
            name: "Target",
            colorHex: "#000000",
            iconName: "circle",
            sortOrder: 1
        )
        let sameSpace = Space(
            spaceId: state.spaceId,
            profileId: state.profileId,
            name: "Current",
            colorHex: "#000000",
            iconName: "circle",
            sortOrder: 0
        )
        let incognitoTarget = Space(
            spaceId: "\(SpaceManager.incognitoSpaceIdPrefix).test",
            profileId: SpaceManager.incognitoProfileId,
            name: "Incognito",
            colorHex: "#000000",
            iconName: "circle",
            sortOrder: 2
        )

        XCTAssertTrue(state.canMoveBookmarks(bookmarkGuids: [bookmarkGuid], to: validTarget))
        XCTAssertTrue(state.canCloneBookmarks(bookmarkGuids: [bookmarkGuid], to: validTarget))
        XCTAssertFalse(state.canMoveBookmarks(bookmarkGuids: [], to: validTarget))
        XCTAssertFalse(state.canCloneBookmarks(bookmarkGuids: [], to: validTarget))
        XCTAssertFalse(state.canMoveBookmarks(bookmarkGuids: [bookmarkGuid], to: sameSpace))
        XCTAssertFalse(state.canCloneBookmarks(bookmarkGuids: [bookmarkGuid], to: sameSpace))
        XCTAssertFalse(state.canMoveBookmarks(bookmarkGuids: [bookmarkGuid], to: incognitoTarget))
        XCTAssertFalse(state.canCloneBookmarks(bookmarkGuids: [bookmarkGuid], to: incognitoTarget))
    }

    func testExplicitBookmarkCopyUsesSelectedRootsAndPreservesMultiSelection() throws {
        let state = try makeState()
        let folderGuid = "copy-folder"
        let splitGuid = "copy-split-child"
        let normalGuid = "copy-normal-root"
        state.localStore.createDirectory(
            title: "Folder",
            profileId: state.profileId,
            parentId: nil,
            guid: folderGuid,
            spaceId: state.spaceId
        )
        guard waitUntil(condition: {
            state.bookmarkManager.bookmark(withGuid: folderGuid) != nil
        }) else { return }
        state.localStore.createBookmark(
            url: "https://left.example",
            title: "Split",
            profileId: state.profileId,
            parentId: folderGuid,
            guid: splitGuid,
            spaceId: state.spaceId,
            secondaryUrl: "https://right.example"
        )
        state.localStore.createBookmark(
            url: "https://normal.example",
            title: "Normal",
            profileId: state.profileId,
            parentId: nil,
            guid: normalGuid,
            spaceId: state.spaceId
        )
        guard waitUntil(condition: {
            state.bookmarkManager.bookmark(withGuid: splitGuid) != nil &&
                state.bookmarkManager.bookmark(withGuid: normalGuid) != nil
        }) else { return }

        XCTAssertTrue(
            state.replaceMultiSelection(
                tabIds: [],
                bookmarkGuids: [normalGuid, splitGuid]
            )
        )
        let originalMultiSelectionBookmarkGuids = state.multiSelection.bookmarkGuids

        NSPasteboard.general.clearContents()
        XCTAssertTrue(
            state.copyBookmarkLinks(
                bookmarkGuids: [folderGuid, splitGuid, normalGuid]
            )
        )
        XCTAssertEqual(
            NSPasteboard.general.string(forType: .string),
            "https://normal.example"
        )
        XCTAssertEqual(
            state.multiSelection.bookmarkGuids,
            originalMultiSelectionBookmarkGuids
        )

        NSPasteboard.general.clearContents()
        XCTAssertTrue(state.copyBookmarkLinks(bookmarkGuids: [splitGuid]))
        XCTAssertEqual(
            NSPasteboard.general.string(forType: .string),
            "https://left.example\nhttps://right.example"
        )

        NSPasteboard.general.clearContents()
        XCTAssertFalse(state.copyBookmarkLinks(bookmarkGuids: [folderGuid]))
        XCTAssertNil(NSPasteboard.general.string(forType: .string))
        XCTAssertEqual(
            state.multiSelection.bookmarkGuids,
            originalMultiSelectionBookmarkGuids
        )
    }

    func testExplicitBookmarkGroupEligibilityAcceptsClosedAndSplitRoots() throws {
        let state = try makeState()
        let folderGuid = "group-folder"
        let liveGuid = "group-live-normal"
        let closedGuid = "group-closed-normal"
        let splitGuid = "group-split"
        state.localStore.createDirectory(
            title: "Folder",
            profileId: state.profileId,
            parentId: nil,
            guid: folderGuid,
            spaceId: state.spaceId
        )
        state.localStore.createBookmark(
            url: "https://live.example",
            title: "Live",
            profileId: state.profileId,
            parentId: nil,
            guid: liveGuid,
            spaceId: state.spaceId
        )
        state.localStore.createBookmark(
            url: "https://closed.example",
            title: "Closed",
            profileId: state.profileId,
            parentId: nil,
            guid: closedGuid,
            spaceId: state.spaceId
        )
        state.localStore.createBookmark(
            url: "https://left.example",
            title: "Split",
            profileId: state.profileId,
            parentId: nil,
            guid: splitGuid,
            spaceId: state.spaceId,
            secondaryUrl: "https://right.example"
        )
        guard waitUntil(condition: {
            state.bookmarkManager.bookmark(withGuid: folderGuid) != nil &&
                state.bookmarkManager.bookmark(withGuid: liveGuid) != nil &&
                state.bookmarkManager.bookmark(withGuid: closedGuid) != nil &&
                state.bookmarkManager.bookmark(withGuid: splitGuid) != nil
        }) else { return }

        let liveTab = Tab(
            guid: 1,
            url: "https://live.example",
            isActive: false,
            index: 0
        )
        liveTab.guidInLocalDB = liveGuid
        state.tabs = [liveTab]
        state.updateNormalTabs()
        XCTAssertTrue(
            state.replaceMultiSelection(
                tabIds: [],
                bookmarkGuids: [closedGuid, splitGuid]
            )
        )
        let originalMultiSelectionBookmarkGuids = state.multiSelection.bookmarkGuids

        XCTAssertTrue(state.canCreateGroupFromBookmarks(bookmarkGuids: [liveGuid]))
        XCTAssertTrue(
            state.canCreateGroupFromBookmarks(
                bookmarkGuids: [liveGuid, closedGuid, splitGuid]
            )
        )
        XCTAssertFalse(state.canCreateGroupFromBookmarks(bookmarkGuids: []))
        XCTAssertFalse(state.canCreateGroupFromBookmarks(bookmarkGuids: [folderGuid]))
        XCTAssertTrue(state.canCreateGroupFromBookmarks(bookmarkGuids: [closedGuid]))
        XCTAssertTrue(state.canCreateGroupFromBookmarks(bookmarkGuids: [splitGuid]))
        XCTAssertEqual(
            state.bookmarkGroupSeedReuseCandidateGuid(
                bookmarkGuids: [closedGuid, splitGuid]
            ),
            splitGuid
        )
        XCTAssertEqual(
            state.bookmarkGroupSeedReuseCandidateGuid(bookmarkGuids: [closedGuid]),
            closedGuid
        )
        XCTAssertNil(
            state.bookmarkGroupSeedReuseCandidateGuid(bookmarkGuids: [liveGuid])
        )
        XCTAssertFalse(
            state.canCreateGroupFromBookmarks(
                bookmarkGuids: [folderGuid, liveGuid]
            )
        )
        XCTAssertEqual(liveTab.guidInLocalDB, liveGuid)
        XCTAssertEqual(
            state.multiSelection.bookmarkGuids,
            originalMultiSelectionBookmarkGuids
        )

        state.tabs.append(
            Tab(guid: 2, url: "https://partner.example", isActive: false, index: 1)
        )
        state.splits = [
            SplitGroup(
                id: "group-live-split",
                primaryTabId: 1,
                secondaryTabId: 2,
                layout: .vertical,
                ratio: 0.5
            )
        ]
        XCTAssertTrue(state.canCreateGroupFromBookmarks(bookmarkGuids: [liveGuid]))
        XCTAssertEqual(liveTab.guidInLocalDB, liveGuid)
    }

    func testStaleBookmarkGroupSeedArrivalIsDiscarded() throws {
        let state = try makeState()
        let staleCustomGuid = "\(BrowserState.bookmarkGroupSeedGuidPrefix)stale"
        let tab = Tab(
            guid: 41,
            url: "chrome://newtab/",
            isActive: false,
            index: 0,
            customGuid: staleCustomGuid,
            windowId: state.windowId
        )

        XCTAssertTrue(BrowserState.isBookmarkGroupSeedGuid(staleCustomGuid))
        state.handleNewTabFromChromium(tab)

        XCTAssertNil(tab.guidInLocalDB)
        XCTAssertTrue(state.tabs.isEmpty)
        XCTAssertTrue(state.normalTabs.isEmpty)
        XCTAssertFalse(state.multiSelection.isActive)
    }

    func testAddingExplicitBookmarkAlreadyInTargetGroupIsANoOp() throws {
        let state = try makeState()
        let bookmarkGuid = "bookmark-already-in-target-group"
        state.localStore.createBookmark(
            url: "https://bookmark.example",
            title: "Bookmark",
            profileId: state.profileId,
            parentId: nil,
            guid: bookmarkGuid,
            spaceId: state.spaceId
        )
        guard waitUntil(condition: {
            state.bookmarkManager.bookmark(withGuid: bookmarkGuid) != nil
        }) else { return }

        let liveTab = Tab(
            guid: 1,
            url: "https://bookmark.example",
            isActive: false,
            index: 0
        )
        liveTab.guidInLocalDB = bookmarkGuid
        state.tabs = [liveTab]
        state.updateNormalTabs()
        state.groups["target-group"] = WebContentGroupInfo(
            token: "target-group",
            title: "Target",
            color: .blue,
            isCollapsed: false
        )
        XCTAssertTrue(
            state.replaceMultiSelection(
                tabIds: [],
                bookmarkGuids: [bookmarkGuid]
            )
        )
        let originalMultiSelection = state.multiSelection

        XCTAssertTrue(
            state.canAddBookmarks(
                bookmarkGuids: [bookmarkGuid],
                toGroup: "target-group"
            )
        )
        XCTAssertFalse(
            state.canAddBookmarks(
                bookmarkGuids: [bookmarkGuid],
                toGroup: "missing-group"
            )
        )
        liveTab.groupToken = "target-group"
        XCTAssertFalse(
            state.canAddBookmarks(
                bookmarkGuids: [bookmarkGuid],
                toGroup: "target-group"
            )
        )

        XCTAssertFalse(
            state.addBookmarks(
                bookmarkGuids: [bookmarkGuid],
                toGroup: "target-group"
            )
        )
        XCTAssertEqual(liveTab.guidInLocalDB, bookmarkGuid)
        XCTAssertEqual(liveTab.groupToken, "target-group")
        XCTAssertEqual(state.normalTabs.map(\.guid), [liveTab.guid])
        XCTAssertNotNil(state.bookmarkManager.bookmark(withGuid: bookmarkGuid))
        XCTAssertEqual(state.multiSelection, originalMultiSelection)
    }

    private func makeState(
        accountId: String = UUID().uuidString,
        profileId: String = LocalStore.defaultProfileId,
        spaceId: String = LocalStore.defaultSpaceId
    ) throws -> BrowserState {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        let store = LocalStore(
            account: Account(userID: accountId),
            storeDirectoryURL: directory
        )
        stores.append(store)
        return BrowserState(
            windowId: 17,
            localStore: store,
            profileId: profileId,
            spaceId: spaceId
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTFail("Condition was not met before timeout.")
        return false
    }
}

@MainActor
final class BookmarkManagerAnalyticsSessionTests: XCTestCase {
    private struct Event {
        let name: String
        let properties: [String: Any]
    }

    func testSessionCapturesOpenedOnlyOnceAndSkipsUnusedExit() {
        var events: [Event] = []
        let session = BookmarkManagerAnalyticsSession { name, properties in
            events.append(Event(name: name, properties: properties))
        }

        session.start()
        session.start()
        session.finish()

        XCTAssertEqual(events.map(\.name), ["bookmark_manager_opened"])
    }

    func testSessionCapturesOneEditedEventWithoutEditDetails() {
        var events: [Event] = []
        let session = BookmarkManagerAnalyticsSession { name, properties in
            events.append(Event(name: name, properties: properties))
        }

        session.start()
        session.markEdited()
        session.markEdited()
        session.finish()
        session.finish()

        XCTAssertEqual(events.map(\.name), [
            "bookmark_manager_opened",
            "bookmark_manager_edited",
        ])
        XCTAssertTrue(events.last?.properties.isEmpty == true)
    }
}

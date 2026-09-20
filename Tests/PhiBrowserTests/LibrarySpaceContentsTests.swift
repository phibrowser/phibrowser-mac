// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import SwiftData
import SwiftUI
import XCTest
@testable import Phi

@MainActor
final class LibrarySpaceContentsTests: XCTestCase {
    private var store: LocalStore!
    private var directory: URL!
    private var subscriptions = Set<AnyCancellable>()

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = LocalStore(account: Account(userID: UUID().uuidString), storeDirectoryURL: directory,
                           presentsCompatibilityAlerts: false)
    }

    override func tearDown() async throws {
        subscriptions.removeAll()
        try await store.closeForAccountDirectoryRemoval()
        store = nil
        try FileManager.default.removeItem(at: directory)
    }

    func testBookmarksPreserveHierarchyOrderAndSplitContentWithoutRoot() throws {
        let context = try XCTUnwrap(store.getMainContext())
        let root = node("root", type: .bookmarkFolder)
        let folder = node("folder", type: .bookmarkFolder, index: 1)
        let first = node("first", type: .bookmark, index: 0)
        let nested = node("nested", type: .bookmark)
        [root, folder, first, nested].forEach { context.insert($0) }
        folder.parent = root
        first.parent = root
        nested.parent = folder
        nested.secondaryUrl = URL(string: "https://secondary.example")
        nested.secondaryTitle = "Second pane"
        try context.save()

        let manager = BookmarkManager(store: store, scope: BookmarkManagementScope(accountId: store.account.userID, profileId: "profile", spaceId: "space"))
        let items = manager.mappedModels(from: [nested, folder, root, first])
        XCTAssertEqual(items.map(\.guid), ["first", "folder"])
        XCTAssertEqual(items[1].children.map(\.guid), ["nested"])
        XCTAssertEqual(items[1].children[0].secondaryTitle, "Second pane")
        XCTAssertEqual(items[1].children[0].secondaryUrl.flatMap(URL.init(string:))?.host, "secondary.example")
        XCTAssertTrue(items[1].isFolder)
    }

    func testPinnedSplitAppearsOnceAndDanglingPartnerRemainsVisible() {
        let primary = node("primary", type: .pinnedTab, index: 0)
        let partner = node("partner", type: .pinnedTab, index: 1)
        let dangling = node("dangling", type: .pinnedTab, index: 2)
        primary.splitPartnerGuid = partner.guid
        partner.splitPartnerGuid = primary.guid
        dangling.splitPartnerGuid = "missing"
        let items = LibrarySpaceContents.pinnedItems([dangling, partner, primary])
        XCTAssertEqual(items.map(\.id), ["primary", "dangling"])
        XCTAssertEqual(items[0].secondaryID, "partner")
        XCTAssertNil(items[1].secondaryID)
    }

    func testProfileScopedPinsRefreshAcrossCardsAndClearOnStoreClose() async throws {
        let context = try XCTUnwrap(store.getMainContext())
        let profile = ProfileModel(profileId: "profile")
        let pin = node("pin", type: .pinnedTab)
        context.insert(profile)
        context.insert(pin)
        pin.profile = profile
        pin.profileId = profile.profileId
        try context.save()
        let first = LibrarySpaceContents(store: store, space: space("a", profileID: "profile"))
        let second = LibrarySpaceContents(store: store, space: space("b", profileID: "profile"))
        let unrelated = LibrarySpaceContents(store: store, space: space("c", profileID: "other"))
        XCTAssertEqual(first.pins.map(\.id), ["pin"])
        XCTAssertEqual(second.pins.map(\.id), ["pin"])
        XCTAssertTrue(unrelated.pins.isEmpty)
        let changed = expectation(description: "Both cards receive the persisted title")
        changed.expectedFulfillmentCount = 2
        for contents in [first, second] {
            contents.$pins.filter { $0.first?.title == "Renamed" }.prefix(1)
                .sink { _ in changed.fulfill() }.store(in: &subscriptions)
        }
        store.updateTabTitle("pin", title: "Renamed")
        await fulfillment(of: [changed], timeout: 5)
        let snapshot = first.pins
        try await store.closeForAccountDirectoryRemoval()
        XCTAssertTrue(first.pins.isEmpty)
        XCTAssertTrue(second.pins.isEmpty)
        XCTAssertEqual(snapshot.first?.title, "Renamed")
    }

    func testScopedManagerReusesBookmarkObjectsAndClearsOnClose() async throws {
        try seedSpaces()
        let manager = BookmarkManager(store: store, scope: scope("a", "p"))
        manager.addFolder(title: "Folder", guid: "folder")
        await settleStore()
        let folder = try XCTUnwrap(manager.bookmark(withGuid: "folder"))
        folder.isExpanded = true
        manager.addBookmark(title: "Saved", url: "https://saved.example", to: folder)
        await settleStore()
        XCTAssertTrue(manager.bookmark(withGuid: "folder") === folder)
        XCTAssertTrue(folder.isExpanded)
        XCTAssertEqual(folder.children.first?.title, "Saved")
        let child = try XCTUnwrap(folder.children.first)
        manager.updateBookmark(guid: child.guid, title: "Changed")
        await settleStore()
        XCTAssertTrue(manager.bookmark(withGuid: child.guid) === child)
        XCTAssertEqual(child.title, "Changed")
        XCTAssertTrue(store.fetchBookmarks(parentId: nil, profileId: "q", spaceId: "b").isEmpty)
        manager.removeBookmark(child)
        await settleStore()
        XCTAssertNil(manager.bookmark(withGuid: child.guid))
        try await store.closeForAccountDirectoryRemoval()
        XCTAssertNil(manager.localStore)
        XCTAssertTrue(manager.rootFolder.children.isEmpty)
    }

    func testCrossSpaceFolderDropPreservesTreeAndTargetIndex() async throws {
        try seedSpaces()
        let source = BookmarkManager(store: store, scope: scope("a", "p"))
        let target = BookmarkManager(store: store, scope: scope("b", "q"))
        source.addFolder(title: "Source", guid: "source-folder")
        target.addFolder(title: "Target", guid: "target-folder")
        await settleStore()
        let sourceFolder = try XCTUnwrap(source.bookmark(withGuid: "source-folder"))
        let targetFolder = try XCTUnwrap(target.bookmark(withGuid: "target-folder"))
        source.addSplitBookmark(title: "Pair", primaryURL: "https://one.example", secondaryURL: "https://two.example",
            secondaryTitle: "Two", layout: .horizontal, to: sourceFolder)
        target.addBookmark(title: "Existing", url: "https://existing.example", to: targetFolder)
        await settleStore()
        let leafID = try XCTUnwrap(sourceFolder.children.first?.guid)
        store.moveBookmarks([sourceFolder.guid], sourceProfileId: "p", toSpaceId: "b", targetProfileId: "q",
                            sourceSpaceId: "a", targetParentId: targetFolder.guid, destinationIndex: 0)
        await settleStore()
        XCTAssertNil(source.bookmark(withGuid: sourceFolder.guid))
        let moved = try XCTUnwrap(target.bookmark(withGuid: sourceFolder.guid))
        XCTAssertEqual(targetFolder.children.first?.guid, moved.guid)
        XCTAssertEqual(moved.children.map(\.guid), [leafID])
        XCTAssertEqual(moved.children.first?.profileId, "q")
        XCTAssertEqual(moved.children.first?.secondaryUrl, "https://two.example")
        XCTAssertEqual(moved.children.first?.layout, .horizontal)
        XCTAssertEqual(store.getTab(by: leafID)?.spaceId, "b")
    }

    func testScopedTransferRejectsCyclesAndStaleSourceScope() async throws {
        try seedSpaces()
        let manager = BookmarkManager(store: store, scope: scope("a", "p"))
        manager.addFolder(title: "Parent", guid: "parent")
        await settleStore()
        let parent = try XCTUnwrap(manager.bookmark(withGuid: "parent"))
        manager.addFolder(title: "Child", to: parent, guid: "child")
        await settleStore()
        store.moveBookmarks(["parent"], sourceProfileId: "p", toSpaceId: "a", targetProfileId: "p",
                            sourceSpaceId: "a", targetParentId: "child", destinationIndex: 0)
        await settleStore()
        XCTAssertEqual(manager.rootFolder.children.map(\.guid), ["parent"])
        XCTAssertEqual(parent.children.map(\.guid), ["child"])
        store.moveBookmarks(["parent"], sourceProfileId: "p", toSpaceId: "b", targetProfileId: "q", sourceSpaceId: "wrong")
        await settleStore()
        XCTAssertNotNil(manager.bookmark(withGuid: "parent"))
        XCTAssertEqual(store.getTab(by: "parent")?.spaceId, "a")
    }

    func testLibraryMoveDetachesBookmarksInEveryMatchingWindow() async throws {
        try await checkLiveBookmarkRemoval(moving: true)
    }

    func testLibraryDeletionClearsBookmarksInEveryMatchingWindow() async throws {
        try await checkLiveBookmarkRemoval(moving: false)
    }

    private func checkLiveBookmarkRemoval(moving: Bool) async throws {
        let layout = UserDefaults.standard.object(forKey: PhiPreferences.GeneralSettings.layoutModeKey)
        PhiPreferences.GeneralSettings.saveLayoutMode(.performance)
        defer { UserDefaults.standard.set(layout, forKey: PhiPreferences.GeneralSettings.layoutModeKey) }
        try seedSpaces()
        let contents = LibrarySpaceContents(store: store, space: space("a", profileID: "p"))
        contents.bookmarkManager.addFolder(title: "Folder", guid: "folder")
        await settleStore()
        let folder = try XCTUnwrap(contents.bookmarkManager.bookmark(withGuid: "folder"))
        contents.bookmarkManager.addSplitBookmark(title: "Pair", primaryURL: "https://one.example",
            secondaryURL: "https://two.example", secondaryTitle: "Two", layout: .horizontal, to: folder)
        contents.bookmarkManager.addBookmark(title: "Single", url: "https://single.example", to: folder)
        await settleStore()
        let pairID = try XCTUnwrap(folder.children.first { $0.secondaryUrl != nil }?.guid)
        let singleID = try XCTUnwrap(folder.children.first { $0.secondaryUrl == nil }?.guid)
        let matching = [101, 102].map {
            BrowserState(windowId: -$0, localStore: store, profileId: "p", spaceId: "a")
        }
        let otherSpace = BrowserState(windowId: -103, localStore: store, profileId: "q", spaceId: "b")
        let otherProfile = BrowserState(windowId: -104, localStore: store, profileId: "q", spaceId: "a")
        let otherDirectory = directory.appendingPathComponent("other-store")
        let otherStore = LocalStore(account: Account(userID: store.account.userID), storeDirectoryURL: otherDirectory,
                                    presentsCompatibilityAlerts: false)
        let otherAccountState = BrowserState(windowId: -105, localStore: otherStore, profileId: "p", spaceId: "a")
        let unrelated = [otherSpace, otherProfile, otherAccountState]
        await settleStore()
        for state in matching + unrelated {
            state.tabs = [
                Tab(guid: 1, url: "https://one.example", isActive: false, index: 0, title: "One"),
                Tab(guid: 2, url: "https://two.example", isActive: false, index: 1, title: "Two"),
                Tab(guid: 3, url: "https://single.example", isActive: false, index: 2,
                    title: "Single", customGuid: singleID)
            ]
            state.splits = [SplitGroup(id: "pair", primaryTabId: 1, secondaryTabId: 2,
                                      layout: .horizontal, ratio: 0.5)]
            state.splitBookmarkBindings[pairID] = "pair"
            state.syncAllBookmarksOpenedState()
        }
        for state in matching { XCTAssertTrue(state.normalTabs.isEmpty) }

        LibrarySpaceManagementController.prepareLiveBookmarksForRemoval([folder], scope: contents.scope,
            storeIdentifier: contents.storeIdentifier, states: matching + unrelated, moving: moving)

        for state in matching {
            XCTAssertNil(state.splitBookmarkBindings[pairID])
            XCTAssertNil(state.tabs.first { $0.guid == 3 }?.guidInLocalDB)
            if moving {
                XCTAssertEqual(state.normalTabs.map(\.guid), [1, 2, 3])
                XCTAssertEqual(state.splits.count, 1)
            }
        }
        for state in unrelated {
            XCTAssertEqual(state.splitBookmarkBindings[pairID], "pair")
            XCTAssertEqual(state.tabs.first { $0.guid == 3 }?.guidInLocalDB, singleID)
        }
        if moving {
            store.moveBookmarks([folder.guid], sourceProfileId: "p", toSpaceId: "b", targetProfileId: "q", sourceSpaceId: "a")
        } else {
            contents.bookmarkManager.removeBookmark(folder)
        }
        await settleStore()
        for state in matching {
            XCTAssertNil(state.bookmarkManager.bookmark(withGuid: pairID))
            XCTAssertNil(state.splitBookmarkBindings[pairID])
        }
        XCTAssertEqual(store.getTab(by: pairID)?.spaceId, moving ? "b" : nil)
        try await otherStore.closeForAccountDirectoryRemoval()
    }

    func testCardRecreatesContentsAfterProfileChangeWithStableScrollIdentity() async throws {
        try seedSpaces()
        let space = space("a", profileID: "p")
        let contents = LibrarySpaceContents(store: store, space: space)
        contents.bookmarkManager.addFolder(title: "Preserved", guid: "preserved")
        store.createPinnedTab(guid: "old-pin", url: "https://old.example", title: "Old", profileId: "p", spaceId: "a")
        store.createPinnedTab(guid: "new-pin", url: "https://new.example", title: "New", profileId: "q", spaceId: "b")
        store.createPinnedTab(guid: "new-pin-2", url: "https://second.example", title: "Second", profileId: "q", spaceId: "b")
        await settleStore()
        let state = BrowserState(windowId: -201, localStore: store, profileId: "p", spaceId: "a")
        let library = LibrarySpacesView(browserState: state)
        let host = NSHostingView(rootView: library.card(space, store: store).id(space.spaceId))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        await settleStore()
        let original = try XCTUnwrap(managementController(in: host))
        XCTAssertEqual(original.collectionView(NSCollectionView(), numberOfItemsInSection: 1), 1)

        // Renaming preserves the controller and its selection/expansion state.
        store.updateSpace(spaceId: "a", name: "Renamed")
        await settleStore()
        space.update(from: try XCTUnwrap(store.getAllSpaces().first { $0.spaceId == "a" }))
        host.rootView = library.card(space, store: store).id(space.spaceId)
        host.layoutSubtreeIfNeeded()
        await settleStore()
        XCTAssertTrue(managementController(in: host) === original)

        store.changeSpaceProfile(spaceId: "a", toProfileId: "q")
        await settleStore()
        space.update(from: try XCTUnwrap(store.getAllSpaces().first { $0.spaceId == "a" }))
        host.rootView = library.card(space, store: store).id(space.spaceId)
        host.layoutSubtreeIfNeeded()
        await settleStore()
        let replacement = try XCTUnwrap(managementController(in: host))
        XCTAssertFalse(replacement === original)
        XCTAssertEqual(replacement.outlineView(NSOutlineView(), numberOfChildrenOfItem: nil), 1)
        let folder = try XCTUnwrap(replacement.outlineView(NSOutlineView(), child: 0, ofItem: nil) as? Bookmark)
        XCTAssertEqual(folder.guid, "preserved")
        XCTAssertEqual(folder.profileId, "q")
        XCTAssertEqual(replacement.collectionView(NSCollectionView(), numberOfItemsInSection: 1), 2)
    }

    private func managementController(in view: NSView) -> LibrarySpaceManagementController? {
        if let controller = view.nextResponder as? LibrarySpaceManagementController { return controller }
        return view.subviews.lazy.compactMap { self.managementController(in: $0) }.first
    }

    private func scope(_ space: String, _ profile: String) -> BookmarkManagementScope {
        BookmarkManagementScope(accountId: store.account.userID, profileId: profile, spaceId: space)
    }

    private func seedSpaces() throws {
        let context = try XCTUnwrap(store.getMainContext())
        for (index, pair) in [("a", "p"), ("b", "q")].enumerated() {
            context.insert(ProfileModel(profileId: pair.1))
            context.insert(SpaceModel(spaceId: pair.0, profileId: pair.1, name: pair.0,
                                      colorHex: "#000000", iconName: "star", sortOrder: index))
        }
        try context.save()
    }

    private func settleStore() async {
        await Task.yield()
        await store.performBackgroundWriteAndWait { _ in }
        // Store notifications and the manager's initial MainActor subscription are asynchronous.
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    private func node(_ id: String, type: TabDataType, index: Int = 0) -> TabDataModel {
        let node = TabDataModel(title: id, guid: id, index: index,
                                url: URL(string: "https://\(id).example")!, favicon: nil,
                                createdDate: Date(), updatedDate: Date())
        node.dataType = type
        return node
    }

    private func space(_ id: String, profileID: String) -> Space {
        Space(spaceId: id, profileId: profileID, name: id, colorHex: "#123456",
              iconName: "circle", sortOrder: 0, storeIdentifier: store.identifier)
    }
}

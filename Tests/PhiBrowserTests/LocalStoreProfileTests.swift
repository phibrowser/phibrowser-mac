// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
import CoreData
import SwiftData
import Cocoa
@testable import Phi

@MainActor
final class LocalStoreProfileTests: XCTestCase {
    private var tempDirectories: [URL] = []

    override func tearDownWithError() throws {
        let fileManager = FileManager.default
        for directory in tempDirectories {
            try? fileManager.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    func testMigratingLegacyStoreAssignsRowsToDefaultProfile() throws {
        guard #available(macOS 14, *) else {
            throw XCTSkip("Legacy SwiftData stores require macOS 14 to seed and convert.")
        }
        let directory = try makeTemporaryStoreDirectory()
        try seedLegacyStore(at: directory)

        let store = LocalStore(
            account: Account(userID: "legacy-account"),
            storeDirectoryURL: directory
        )
        let context = try XCTUnwrap(store.getMainContext())

        let profiles: [ProfileModel] = try context.fetch(ProfileModel.request())
        XCTAssertEqual(profiles.map { $0.profileId }, ["Default"])

        let tabs: [TabDataModel] = try context.fetch(TabDataModel.request())
        XCTAssertEqual(tabs.count, 1)
        XCTAssertEqual(tabs.first?.profile?.profileId, "Default")
        XCTAssertEqual(tabs.first?.pinLineageId, "legacy-guid")
        XCTAssertEqual(store.pinnedTabScope(), .profile)
    }

    func testGetAllPinnedTabsFiltersByProfileId() throws {
        let store = try makeStore()
        let context = try XCTUnwrap(store.getMainContext())

        let defaultProfile = ProfileModel(insertInto: context, profileId: "Default")
        let workProfile = ProfileModel(insertInto: context, profileId: "Work")
        context.insert(defaultProfile)
        context.insert(workProfile)

        let defaultPinned = makeTab(in: context, guid: "default-pinned", title: "Default", url: "https://default.example")
        defaultPinned.dataType = TabDataType.pinnedTab
        defaultPinned.profile = defaultProfile
        context.insert(defaultPinned)

        let workPinned = makeTab(in: context, guid: "work-pinned", title: "Work", url: "https://work.example")
        workPinned.dataType = TabDataType.pinnedTab
        workPinned.profile = workProfile
        context.insert(workPinned)

        try context.save()

        XCTAssertEqual(store.getAllPinnedTabs(for: "Default").map { $0.guid }, ["default-pinned"])
        XCTAssertEqual(store.getAllPinnedTabs(for: "Work").map { $0.guid }, ["work-pinned"])
    }

    func testUpsertProfileDisplayNamesCreatesAndUpdatesProfileRows() throws {
        let store = try makeStore()
        let context = try XCTUnwrap(store.getMainContext())

        let defaultProfile = ProfileModel(insertInto: context, profileId: "Default", displayName: "Old Default")
        context.insert(defaultProfile)
        try context.save()

        store.upsertProfileDisplayNames([
            "Default": "Personal",
            "Profile 1": " Work "
        ])

        let profiles = try context.fetch(ProfileModel.request())
        XCTAssertEqual(profiles.first(where: { $0.profileId == "Default" })?.displayName, "Personal")
        XCTAssertEqual(profiles.first(where: { $0.profileId == "Profile 1" })?.displayName, "Work")
    }

    func testFetchBookmarksAndDeleteProtectionRespectProfileRoot() throws {
        let store = try makeStore()
        let context = try XCTUnwrap(store.getMainContext())

        let defaultProfile = ProfileModel(insertInto: context, profileId: "Default")
        let workProfile = ProfileModel(insertInto: context, profileId: "Work")
        context.insert(defaultProfile)
        context.insert(workProfile)

        let defaultRoot = makeFolder(in: context, guid: "root-default", title: "Bookmarks")
        defaultRoot.profile = defaultProfile
        defaultProfile.bookmarkRoot = defaultRoot
        context.insert(defaultRoot)

        let workRoot = makeFolder(in: context, guid: "root-work", title: "Bookmarks")
        workRoot.profile = workProfile
        workProfile.bookmarkRoot = workRoot
        context.insert(workRoot)

        let defaultBookmark = makeTab(in: context, guid: "bookmark-default", title: "Default Bookmark", url: "https://default.example")
        defaultBookmark.dataType = TabDataType.bookmark
        defaultBookmark.parent = defaultRoot
        defaultBookmark.profile = defaultProfile
        context.insert(defaultBookmark)

        let workBookmark = makeTab(in: context, guid: "bookmark-work", title: "Work Bookmark", url: "https://work.example")
        workBookmark.dataType = TabDataType.bookmark
        workBookmark.parent = workRoot
        workBookmark.profile = workProfile
        context.insert(workBookmark)

        try context.save()

        XCTAssertEqual(store.fetchBookmarks(parentId: nil as String?, profileId: "Default").map { $0.guid }, ["bookmark-default"])
        XCTAssertEqual(store.fetchBookmarks(parentId: nil as String?, profileId: "Work").map { $0.guid }, ["bookmark-work"])

        store.deleteBookmark("root-default", profileId: "Default")
        try waitForBackgroundWrite()

        let refreshedDefaultRoot: [TabDataModel] = try context.fetch(
            TabDataModel.request(NSPredicate(format: "guid == %@", "root-default"))
        )
        XCTAssertEqual(refreshedDefaultRoot.count, 1)
    }

    func testFetchBookmarkTabsReturnsFlatSpaceScopedRowsOrderedByLastSeen() throws {
        let store = try makeStore()
        let context = try XCTUnwrap(store.getMainContext())

        let defaultProfile = ProfileModel(profileId: "Default")
        let workProfile = ProfileModel(profileId: "Work")
        context.insert(defaultProfile)
        context.insert(workProfile)

        let selectedSpace = SpaceModel(
            spaceId: "space-a",
            profileId: "Default",
            name: "Selected",
            colorHex: "#112233",
            iconName: "rectangle.stack",
            sortOrder: 0
        )
        let otherSpace = SpaceModel(
            spaceId: "space-b",
            profileId: "Work",
            name: "Other",
            colorHex: "#445566",
            iconName: "rectangle.stack",
            sortOrder: 1
        )
        context.insert(selectedSpace)
        context.insert(otherSpace)

        let folder = makeFolder(guid: "folder", title: "Folder")
        folder.profile = defaultProfile
        folder.profileId = defaultProfile.profileId
        folder.spaceId = selectedSpace.spaceId
        folder.lastSeen = Date(timeIntervalSince1970: 400)
        context.insert(folder)

        let recent = makeTab(guid: "recent", title: "Recent", url: "https://recent.example")
        recent.dataType = .bookmark
        recent.profile = defaultProfile
        recent.profileId = defaultProfile.profileId
        recent.spaceId = selectedSpace.spaceId
        recent.parent = folder
        recent.lastSeen = Date(timeIntervalSince1970: 300)
        context.insert(recent)

        let older = makeTab(guid: "older", title: "Older", url: "https://older.example")
        older.dataType = .bookmark
        older.profile = defaultProfile
        older.profileId = defaultProfile.profileId
        older.spaceId = selectedSpace.spaceId
        older.lastSeen = Date(timeIntervalSince1970: 100)
        context.insert(older)

        let neverOpened = makeTab(guid: "never", title: "Never", url: "https://never.example")
        neverOpened.dataType = .bookmark
        neverOpened.profile = defaultProfile
        neverOpened.profileId = defaultProfile.profileId
        neverOpened.spaceId = selectedSpace.spaceId
        context.insert(neverOpened)

        let otherSpaceBookmark = makeTab(
            guid: "other-space",
            title: "Other Space",
            url: "https://other.example"
        )
        otherSpaceBookmark.dataType = .bookmark
        otherSpaceBookmark.profile = workProfile
        otherSpaceBookmark.profileId = workProfile.profileId
        otherSpaceBookmark.spaceId = otherSpace.spaceId
        otherSpaceBookmark.lastSeen = Date(timeIntervalSince1970: 500)
        context.insert(otherSpaceBookmark)

        let normalTab = makeTab(guid: "normal", title: "Normal", url: "https://normal.example")
        normalTab.dataType = .tab
        normalTab.profile = defaultProfile
        normalTab.profileId = defaultProfile.profileId
        normalTab.spaceId = selectedSpace.spaceId
        normalTab.lastSeen = Date(timeIntervalSince1970: 600)
        context.insert(normalTab)

        try context.save()

        XCTAssertEqual(
            store.fetchBookmarkTabs(in: [selectedSpace]).map(\.guid),
            ["recent", "older", "never"]
        )
    }

    func testBrowserStateStoresProfileId() throws {
        let store = try makeStore()

        let state = BrowserState(windowId: 7, localStore: store, profileId: "Work")

        XCTAssertEqual(state.profileId, "Work")
    }

    func testBrowserStateRefreshesPersistedPinnedTabURLWhenLocalStoreChanges() throws {
        let store = try makeStore()
        let context = try XCTUnwrap(store.getMainContext())
        let profile = ProfileModel(insertInto: context, profileId: "Default")
        context.insert(profile)

        let pinnedModel = makeTab(in: context, guid: "pinned-guid", title: "Pinned", url: "https://163.com")
        pinnedModel.dataType = TabDataType.pinnedTab
        pinnedModel.profile = profile
        context.insert(pinnedModel)
        try context.save()

        let state = BrowserState(windowId: 7, localStore: store, profileId: "Default")
        let pinnedTab = try XCTUnwrap(state.pinnedTabs.first)
        pinnedTab.isOpenned = true
        pinnedTab.url = "https://github.com/features/copilot"

        store.updateTabURL("pinned-guid", url: try XCTUnwrap(URL(string: "https://qq.com")))
        try waitUntil {
            pinnedTab.pinnedUrl == "https://qq.com"
        }

        XCTAssertTrue(
            state.pinnedTabs.first === pinnedTab,
            "BrowserState should keep the existing pinned tab runtime object so open state and wrapper bindings are preserved."
        )
        XCTAssertEqual(
            pinnedTab.pinnedUrl,
            "https://qq.com",
            "Persisted pinned-tab URL changes should refresh the in-memory pinnedUrl used when the tab is closed and reopened."
        )
        XCTAssertEqual(
            pinnedTab.url,
            "https://github.com/features/copilot",
            "Refreshing persisted pinned-tab metadata must not overwrite the currently opened page URL."
        )
    }

    func testBrowserStatePinnedTabEditingURLPrefersPersistedURLOverRuntimeNavigationURL() throws {
        let store = try makeStore()
        let context = try XCTUnwrap(store.getMainContext())
        let profile = ProfileModel(insertInto: context, profileId: "Default")
        context.insert(profile)
        let pinnedModel = makeTab(in: context, guid: "github-pinned", title: "GitHub", url: "https://github.com")
        pinnedModel.dataType = TabDataType.pinnedTab
        pinnedModel.profile = profile
        context.insert(pinnedModel)
        try context.save()

        let state = BrowserState(windowId: 7, localStore: store, profileId: "Default")
        let pinnedTab = Tab(
            guid: 42,
            url: "https://github.com/features/copilot",
            isActive: true,
            index: 0,
            title: "GitHub Copilot",
            customGuid: "github-pinned"
        )
        pinnedTab.isPinned = true
        pinnedTab.pinnedUrl = "https://stale.example"
        state.pinnedTabs = [pinnedTab]

        let editingURL = state.pinnedTabEditingURL(
            for: "github-pinned",
            fallbackURL: "https://github.com/features/copilot"
        )

        XCTAssertEqual(
            editingURL,
            "https://github.com",
            "Editing a pinned tab should show the persisted URL instead of the currently navigated page URL."
        )
    }

    func testUpdateLastSeenOnlyPersistsForPinnedTabsAndBookmarks() throws {
        let store = try makeStore()
        let context = try XCTUnwrap(store.getMainContext())
        let profile = ProfileModel(insertInto: context, profileId: "Default")
        context.insert(profile)

        let root = makeFolder(in: context, guid: "root", title: "Bookmarks")
        root.profile = profile
        root.profileId = "Default"
        profile.bookmarkRoot = root
        context.insert(root)

        let pinned = makeTab(in: context, guid: "pinned", title: "Pinned", url: "https://pinned.example")
        pinned.dataType = TabDataType.pinnedTab
        pinned.profile = profile
        pinned.profileId = "Default"
        context.insert(pinned)

        let bookmark = makeTab(in: context, guid: "bookmark", title: "Bookmark", url: "https://bookmark.example")
        bookmark.dataType = TabDataType.bookmark
        bookmark.profile = profile
        bookmark.profileId = "Default"
        bookmark.parent = root
        context.insert(bookmark)

        let folder = makeFolder(in: context, guid: "folder", title: "Folder")
        folder.profile = profile
        folder.profileId = "Default"
        folder.parent = root
        context.insert(folder)

        let normal = makeTab(in: context, guid: "normal", title: "Normal", url: "https://normal.example")
        normal.dataType = TabDataType.tab
        normal.profile = profile
        normal.profileId = "Default"
        context.insert(normal)
        try context.save()

        let seenAt = Date(timeIntervalSince1970: 1_800_123_456)
        store.updateLastSeen("pinned", seenAt: seenAt)
        store.updateLastSeen("bookmark", seenAt: seenAt)
        store.updateLastSeen("folder", seenAt: seenAt)
        store.updateLastSeen("normal", seenAt: seenAt)

        try waitUntil {
            store.getTab(by: "pinned")?.lastSeen != nil &&
            store.getTab(by: "bookmark")?.lastSeen != nil
        }

        XCTAssertEqual(try XCTUnwrap(store.getTab(by: "pinned")?.lastSeen).timeIntervalSince1970,
                       seenAt.timeIntervalSince1970,
                       accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(store.getTab(by: "bookmark")?.lastSeen).timeIntervalSince1970,
                       seenAt.timeIntervalSince1970,
                       accuracy: 0.001)
        XCTAssertNil(store.getTab(by: "folder")?.lastSeen)
        XCTAssertNil(store.getTab(by: "normal")?.lastSeen)
    }

    func testBrowserDataImporterStoresTargetContext() {
        let importer = BrowserDataImporter(
            targetProfileId: "Work",
            targetSpaceId: "space-work",
            targetWindowId: 42
        )

        XCTAssertEqual(importer.targetProfileId, "Work")
        XCTAssertEqual(importer.targetSpaceId, "space-work")
        XCTAssertEqual(importer.targetWindowId, 42)

        // Omitting targetSpaceId must default to the default Space so existing
        // call sites (e.g. onboarding) keep their pre-Spaces behavior.
        let defaultImporter = BrowserDataImporter(targetProfileId: "Work")
        XCTAssertEqual(defaultImporter.targetSpaceId, LocalStore.defaultSpaceId)
    }

    /// Bookmarks imported into a non-default Space must land under that Space's
    /// bookmark root, and must not leak into the default Space. Exercises the
    /// `spaceId` thread-through added for T1. The Chromium path shares the same
    /// `bookmarkRoot(spaceId:)` change but its `BookmarkWrapper` input is a
    /// framework type that cannot be constructed in a unit test, so the Arc
    /// path stands in for the shared behavior.
    func testSaveArcBookmarksToLocalStoreLandsInTargetSpace() async throws {
        let store = try makeStore()
        let context = try XCTUnwrap(store.getMainContext())
        let targetSpaceId = "space-secondary"

        // The target Space must exist: the persist path drops imports whose
        // Space was deleted/re-profiled mid-flight (see importTargetSpaceIsWritable).
        context.insert(SpaceModel(
            spaceId: targetSpaceId,
            profileId: LocalStore.defaultProfileId,
            name: "Secondary",
            colorHex: "#000000",
            iconName: "circle",
            sortOrder: 1
        ))
        try context.save()

        let leaf = ArcDataParserTool.Bookmark(
            guid: "arc-1",
            title: "Example",
            url: "https://example.com",
            isFolder: false
        )
        let root = ArcDataParserTool.Bookmark(guid: "s1", title: "Work", url: nil, isFolder: true)
        root.children = [leaf]

        await store.saveArcBookmarksToLocalStore(
            root,
            profileId: LocalStore.defaultProfileId,
            spaceId: targetSpaceId
        )

        // Imported bookmarks land in the target Space...
        let targetRootChildren = store.fetchBookmarks(
            parentId: nil,
            profileId: LocalStore.defaultProfileId,
            spaceId: targetSpaceId
        )
        XCTAssertEqual(targetRootChildren.count, 1, "Exactly one import folder should be created in the target Space.")
        let importFolder = try XCTUnwrap(targetRootChildren.first)
        XCTAssertEqual(importFolder.spaceId, targetSpaceId)
        XCTAssertEqual(importFolder.title, "Work")

        let importedBookmarks = store.fetchBookmarks(
            parentId: importFolder.guid,
            profileId: LocalStore.defaultProfileId,
            spaceId: targetSpaceId
        )
        XCTAssertEqual(importedBookmarks.map { $0.title }, ["Example"])
        XCTAssertEqual(importedBookmarks.first?.spaceId, targetSpaceId)

        // ...and not into the default Space.
        let defaultRootChildren = store.fetchBookmarks(
            parentId: nil,
            profileId: LocalStore.defaultProfileId,
            spaceId: LocalStore.defaultSpaceId
        )
        XCTAssertTrue(defaultRootChildren.isEmpty, "Importing into a non-default Space must not touch the default Space.")
    }

    /// Backstop for the delete/re-profile race: when the target Space has no
    /// live SpaceModel (deleted or re-profiled mid-import), the persist path
    /// drops the import instead of writing an orphan root the UI never shows.
    func testSaveArcBookmarksAbortsWhenTargetSpaceMissing() async throws {
        let store = try makeStore()
        let targetSpaceId = "space-gone"   // intentionally no SpaceModel inserted

        let leaf = ArcDataParserTool.Bookmark(
            guid: "arc-1",
            title: "Example",
            url: "https://example.com",
            isFolder: false
        )
        let root = ArcDataParserTool.Bookmark(guid: "s1", title: "Work", url: nil, isFolder: true)
        root.children = [leaf]
        await store.saveArcBookmarksToLocalStore(
            root,
            profileId: LocalStore.defaultProfileId,
            spaceId: targetSpaceId
        )

        XCTAssertTrue(
            store.fetchBookmarks(parentId: nil, profileId: LocalStore.defaultProfileId, spaceId: targetSpaceId).isEmpty,
            "Nothing should be written into a Space that no longer exists."
        )
        XCTAssertTrue(
            store.fetchBookmarks(parentId: nil, profileId: LocalStore.defaultProfileId, spaceId: LocalStore.defaultSpaceId).isEmpty,
            "A dropped import must not spill into the default Space either."
        )
    }

    func testSaveArcBookmarksLandsInSpaceNamedFolder() async throws {
        let store = try makeStore()
        let context = try XCTUnwrap(store.getMainContext())
        let space = SpaceModel(spaceId: "space-a", profileId: LocalStore.defaultProfileId,
                               name: "A", colorHex: "#000000", iconName: "star", sortOrder: 0)
        context.insert(space)
        try context.save()

        let leaf = ArcDataParserTool.Bookmark(guid: "t1", title: "Linear",
                                              url: "https://linear.app", isFolder: false)
        let root = ArcDataParserTool.Bookmark(guid: "s1", title: "Work",
                                              url: nil, isFolder: true)
        root.children = [leaf]

        await store.saveArcBookmarksToLocalStore(root,
            profileId: LocalStore.defaultProfileId, spaceId: "space-a")

        let top = store.fetchBookmarks(parentId: nil,
            profileId: LocalStore.defaultProfileId, spaceId: "space-a")
        let folder = try XCTUnwrap(top.first { $0.title == "Work" })
        XCTAssertEqual(folder.source, 3)
        let children = store.fetchBookmarks(parentId: folder.guid,
            profileId: LocalStore.defaultProfileId, spaceId: "space-a")
        XCTAssertEqual(children.map { $0.title }, ["Linear"])
    }

    func testSaveArcBookmarksSkipsEmptySpace() async throws {
        let store = try makeStore()
        let context = try XCTUnwrap(store.getMainContext())
        let space = SpaceModel(spaceId: "space-a", profileId: LocalStore.defaultProfileId,
                               name: "A", colorHex: "#000000", iconName: "star", sortOrder: 0)
        context.insert(space)
        try context.save()

        let emptyRoot = ArcDataParserTool.Bookmark(guid: "s1", title: "Empty",
                                                   url: nil, isFolder: true)
        await store.saveArcBookmarksToLocalStore(emptyRoot,
            profileId: LocalStore.defaultProfileId, spaceId: "space-a")

        let top = store.fetchBookmarks(parentId: nil,
            profileId: LocalStore.defaultProfileId, spaceId: "space-a")
        XCTAssertNil(top.first { $0.title == "Empty" })
    }

    func testImportTargetLockTracksImportingSpaces() {
        let lock = ImportTargetLock.shared
        let spaceId = "space-lock-\(UUID().uuidString)"

        XCTAssertFalse(lock.isImporting(into: spaceId))
        lock.begin(into: spaceId)
        XCTAssertTrue(lock.isImporting(into: spaceId))
        lock.end(into: spaceId)
        XCTAssertFalse(lock.isImporting(into: spaceId))
    }

    func testFormatImportTargetLabel() {
        XCTAssertEqual(
            ImportFromOtherBrowserViewController.formatImportTargetLabel(spaceName: "Work", profileName: "Personal"),
            "Work (Personal)"
        )
        XCTAssertEqual(
            ImportFromOtherBrowserViewController.formatImportTargetLabel(spaceName: "Work", profileName: nil),
            "Work"
        )
        XCTAssertEqual(
            ImportFromOtherBrowserViewController.formatImportTargetLabel(spaceName: "Work", profileName: ""),
            "Work"
        )
    }

    /// The single import window is retargeted (not duplicated) when re-invoked
    /// from another Space. `updateTarget` is the seam that swaps the destination
    /// window/profile/Space — including across profiles — that `rebindTarget`
    /// drives once an import is no longer in flight.
    func testBrowserDataImporterUpdateTargetRetargetsDestination() {
        let importer = BrowserDataImporter(
            targetProfileId: "Default",
            targetSpaceId: "space-A",
            targetWindowId: 1
        )
        XCTAssertFalse(importer.isImporting)

        importer.updateTarget(profileId: "Work", spaceId: "space-B", windowId: 2)

        XCTAssertEqual(importer.targetProfileId, "Work")
        XCTAssertEqual(importer.targetSpaceId, "space-B")
        XCTAssertEqual(importer.targetWindowId, 2)
    }

    func testArcBookmarkRootGatedByArcOption() {
        let root = ArcDataParserTool.Bookmark(guid: "s", title: "Work", url: nil, isFolder: true)
        let space = ArcSpace(id: "s", title: "Work", profile: .default, root: root)

        // Arc NOT among the selected browsers -> no Arc bookmarks even with a cached space.
        XCTAssertNil(BrowserDataImporter.arcBookmarkRoot(options: [.chrome], arcSpace: space, wantsBookmarks: true))
        // Arc selected + bookmarks wanted -> the chosen space's root.
        XCTAssertTrue(BrowserDataImporter.arcBookmarkRoot(options: [.arc], arcSpace: space, wantsBookmarks: true) === root)
        // Arc selected but no space chosen -> nil.
        XCTAssertNil(BrowserDataImporter.arcBookmarkRoot(options: [.arc], arcSpace: nil, wantsBookmarks: true))
        // Arc selected but bookmarks deselected -> nil.
        XCTAssertNil(BrowserDataImporter.arcBookmarkRoot(options: [.arc], arcSpace: space, wantsBookmarks: false))
    }

    func testProjectDataTypesDropsEmptyBrowsersAndNilsWhenAllEmpty() {
        // Nothing selected anywhere → nil.
        XCTAssertNil(ImportFromOtherBrowserViewController.projectDataTypes([:]))
        XCTAssertNil(ImportFromOtherBrowserViewController.projectDataTypes([.chrome: [], .safari: []]))

        // Non-empty browsers project to sorted rawValue arrays; empty ones dropped.
        let result = ImportFromOtherBrowserViewController.projectDataTypes([
            .chrome: [.bookmarks, .history],
            .safari: [],
            .arc: [.cookies],
        ])
        XCTAssertEqual(result?[.chrome], ["favorites", "history"])  // bookmarks rawValue is "favorites", sorted
        XCTAssertEqual(result?[.arc], ["cookies"])
        XCTAssertNil(result?[.safari])  // empty set omitted
    }

    private func makeStore() throws -> LocalStore {
        let directory = try makeTemporaryStoreDirectory()
        return LocalStore(account: Account(userID: UUID().uuidString), storeDirectoryURL: directory)
    }

    private func makeTemporaryStoreDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        return directory
    }

    @available(macOS 14, *)
    private func seedLegacyStore(at directory: URL) throws {
        let configuration = ModelConfiguration(url: directory.appendingPathComponent("LocalStore.sqlite"))
        let container = try ModelContainer(for: TabDataModelSchemaV2.TabDataModel.self, configurations: configuration)
        let context = container.mainContext

        let row = TabDataModelSchemaV2.TabDataModel(
            title: "Legacy Pinned",
            guid: "legacy-guid",
            index: 0,
            url: URL(string: "https://legacy.example")!,
            favicon: nil,
            createdDate: Date(),
            updatedDate: Date()
        )
        row.type = TabDataType.pinnedTab.rawValue
        row.profileId = "legacy-account"
        context.insert(row)
        try context.save()
    }

    private func makeFolder(in context: NSManagedObjectContext, guid: String, title: String) -> TabDataModel {
        let folder = TabDataModel(
            insertInto: context,
            title: title,
            guid: guid,
            index: 0,
            url: URL(string: "https://bookmark.phi/folder")!,
            favicon: nil as Data?,
            createdDate: Date(),
            updatedDate: Date()
        )
        folder.dataType = TabDataType.bookmarkFolder
        return folder
    }

    private func makeTab(in context: NSManagedObjectContext, guid: String, title: String, url: String) -> TabDataModel {
        TabDataModel(
            insertInto: context,
            title: title,
            guid: guid,
            index: 0,
            url: URL(string: url)!,
            favicon: nil,
            createdDate: Date(),
            updatedDate: Date()
        )
    }

    private func waitForBackgroundWrite() throws {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    private func waitUntil(timeout: TimeInterval = 1, condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTFail("Condition was not met before timeout.")
    }

    // MARK: - ArcSpace parser helpers

    private func makeArcSidebar(profileJSON: String, title: String? = "Work") -> Data {
        let titleField = title.map { "\"title\": \"\($0)\"," } ?? ""
        return Data("""
        {
          "sidebarSyncState": { "items": [] },
          "sidebar": { "containers": [ {
            "spaces": [ { "id": "S1", \(titleField) "profile": \(profileJSON), "containerIDs": ["pinned", "C1"] } ],
            "items": [
              { "id": "C1", "childrenIds": ["T1"],
                "data": { "itemContainer": { "containerType": { "spaceItems": { "_0": "S1" } } } } },
              { "id": "T1", "childrenIds": [], "title": "Linear",
                "data": { "tab": { "savedURL": "https://linear.app", "savedTitle": "Linear" } } }
            ]
          } ] }
        }
        """.utf8)
    }

    private func makeArcSidebarEmptySpace() -> Data {
        return Data("""
        {
          "sidebarSyncState": { "items": [] },
          "sidebar": { "containers": [ {
            "spaces": [ { "id": "S1", "profile": {"default": true}, "containerIDs": [] } ],
            "items": []
          } ] }
        }
        """.utf8)
    }

    func testParseCustomProfileSpace() throws {
        let json = makeArcSidebar(
            profileJSON: #"{"custom":{"_0":{"machineID":"M","directoryBasename":"Profile 1"}}}"#)
        let spaces = try ArcDataParserTool.parse(data: json)
        XCTAssertEqual(spaces.count, 1)
        let s = try XCTUnwrap(spaces.first)
        XCTAssertEqual(s.id, "S1")
        XCTAssertEqual(s.title, "Work")
        XCTAssertEqual(s.profile, .custom(directoryBasename: "Profile 1"))
        XCTAssertEqual(s.profile.directoryName, "Profile 1")
        XCTAssertEqual(s.root.children.count, 1)
        XCTAssertEqual(s.root.children.first?.title, "Linear")
    }

    func testParseDefaultProfileSpace() throws {
        let spaces = try ArcDataParserTool.parse(data: makeArcSidebar(profileJSON: #"{"default": true}"#))
        XCTAssertEqual(spaces.first?.profile, .default)
        XCTAssertEqual(spaces.first?.profile.directoryName, "Default")
    }

    func testParseMalformedProfileBecomesUnknownWithoutAborting() throws {
        let spaces = try ArcDataParserTool.parse(data: makeArcSidebar(profileJSON: #"{"weird":1}"#))
        XCTAssertEqual(spaces.count, 1)               // parse did not abort
        XCTAssertEqual(spaces.first?.profile, .unknown)
        XCTAssertNil(spaces.first?.profile.directoryName)
    }

    func testParseUntitledEmptySpaceIsSurfaced() throws {
        let spaces = try ArcDataParserTool.parse(data: makeArcSidebarEmptySpace())
        XCTAssertEqual(spaces.count, 1)
        XCTAssertEqual(spaces.first?.title, NSLocalizedString("oobe.importBrowserData.arc.untitledSpaceName", value: "Untitled Space", comment: "Arc import - Fallback name for an Arc Space with no title"))
        XCTAssertEqual(spaces.first?.root.children.count, 0)
    }

    func testArcSourceProfileDecoding() throws {
        let dec = JSONDecoder()

        XCTAssertEqual(
            try dec.decode(ArcSourceProfile.self, from: Data(#"{"default": true}"#.utf8)),
            .default)
        XCTAssertEqual(ArcSourceProfile.default.directoryName, "Default")

        let custom = try dec.decode(
            ArcSourceProfile.self,
            from: Data(#"{"custom":{"_0":{"machineID":"M","directoryBasename":"Profile 1"}}}"#.utf8))
        XCTAssertEqual(custom, .custom(directoryBasename: "Profile 1"))
        XCTAssertEqual(custom.directoryName, "Profile 1")

        XCTAssertNil(ArcSourceProfile.unknown.directoryName)
        XCTAssertThrowsError(try dec.decode(ArcSourceProfile.self, from: Data(#"{"weird":1}"#.utf8)))
    }

    func testArcSourceProfileRejectsInvalidCustomBasename() throws {
        func profile(_ basename: String) throws -> ArcSourceProfile {
            let dict: [String: Any] = ["custom": ["_0": ["directoryBasename": basename]]]
            let data = try JSONSerialization.data(withJSONObject: dict)
            return try JSONDecoder().decode(ArcSourceProfile.self, from: data)
        }
        // Empty / whitespace / path separators / traversal must NOT become a usable
        // dir (which Chromium would map to Default → wrong-profile data import).
        XCTAssertEqual(try profile(""), .unknown)
        XCTAssertEqual(try profile("   "), .unknown)
        XCTAssertEqual(try profile("a/b"), .unknown)
        XCTAssertEqual(try profile(".."), .unknown)
        XCTAssertEqual(try profile("../evil"), .unknown)
        XCTAssertEqual(try profile("."), .unknown)
        XCTAssertEqual(try profile("a\\b"), .unknown)   // backslash separator
        XCTAssertNil(try profile("").directoryName)
        // A valid basename still works and is trimmed.
        XCTAssertEqual(try profile(" Profile 1 "), .custom(directoryBasename: "Profile 1"))
        XCTAssertEqual(try profile("Profile 1").directoryName, "Profile 1")
    }

    func testLoadChromiumProfilesFromInjectedLocalState() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Local State")
        try Data("""
        {"profile":{"profiles_order":["Default","Profile 1"],
          "info_cache":{"Default":{"name":"Your Arc","user_name":""},
                        "Profile 1":{"name":"aa","user_name":""}}}}
        """.utf8).write(to: url)

        let importer = BrowserDataImporter()
        let profiles = importer.loadChromiumProfiles(localStateURL: url)
        XCTAssertEqual(profiles.map { $0.directory }, ["Default", "Profile 1"])
        XCTAssertEqual(profiles.map { $0.name }, ["Your Arc", "aa"])
    }
}

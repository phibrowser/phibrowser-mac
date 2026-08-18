// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
import SwiftData
import Cocoa
@testable import Phi

/// Shared-scope pinned-tab edits are applied by one Space through
/// `updateTabURL`/`updateTabTitle`, and other BrowserState instances hear
/// about them through `pinnedTabsPublisher`. These tests pin down the
/// cross-Space half of the edit and the live-tab rebind after scope migration.
@MainActor
final class BrowserStatePinnedTabEditCrossSpaceTests: XCTestCase {
    private var tempDirectories: [URL] = []
    private var stores: [LocalStore] = []

    override func tearDown() async throws {
        for store in stores {
            await store.performBackgroundWriteAndWait { _ in }
        }
        await settleAsyncWork()
        for store in stores {
            await store.performBackgroundWriteAndWait { _ in }
        }
        stores.removeAll()
        await settleAsyncWork()
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    func testPinnedTabURLEditNavigatesOpenCopyInOtherSpace() throws {
        let store = try makeStore()
        try seedPinnedTab(in: store, guid: "pinned-guid", url: "https://old.example")

        let editingSpace = BrowserState(windowId: 1, localStore: store,
                                        profileId: "Default", spaceId: "space-a")
        let otherSpace = BrowserState(windowId: 2, localStore: store,
                                      profileId: "Default", spaceId: "space-b")
        _ = editingSpace

        // Space B has its own live copy of the pinned tab open.
        let otherPinned = try XCTUnwrap(otherSpace.pinnedTabs.first)
        let wrapper = PinnedEditWebContentWrapperSpy(urlString: "https://old.example")
        let liveTab = Tab(guid: 99, url: "https://old.example", isActive: false,
                          index: 0, webContentView: wrapper, customGuid: "pinned-guid")
        otherSpace.tabs = [liveTab]
        otherPinned.isOpenned = true
        otherPinned.guid = liveTab.guid
        otherPinned.setWebContentsWrapper(wrapper: wrapper)

        // The edit's persistence step, as performed by the editing Space.
        store.updateTabURL("pinned-guid", url: try XCTUnwrap(URL(string: "https://new.example")))

        try waitUntil(otherSpace, describing: "open copy navigates to the edited URL") {
            wrapper.navigatedURLs.contains("https://new.example")
        }
        XCTAssertEqual(otherPinned.pinnedUrl, "https://new.example")
        XCTAssertEqual(otherPinned.url, "https://new.example")
    }

    func testPinnedTabURLEditRefreshesClosedCopyInOtherSpace() throws {
        let store = try makeStore()
        try seedPinnedTab(in: store, guid: "pinned-guid", url: "https://old.example")

        let otherSpace = BrowserState(windowId: 2, localStore: store,
                                      profileId: "Default", spaceId: "space-b")
        let otherPinned = try XCTUnwrap(otherSpace.pinnedTabs.first)
        XCTAssertFalse(otherPinned.isOpenned)

        store.updateTabURL("pinned-guid", url: try XCTUnwrap(URL(string: "https://new.example")))

        try waitUntil(otherSpace, describing: "closed copy picks up the edited URL") {
            otherPinned.pinnedUrl == "https://new.example" &&
            otherPinned.url == "https://new.example"
        }
    }

    func testPinnedTabTitleEditReachesOtherSpace() throws {
        let store = try makeStore()
        try seedPinnedTab(in: store, guid: "pinned-guid", url: "https://old.example")

        let otherSpace = BrowserState(windowId: 2, localStore: store,
                                      profileId: "Default", spaceId: "space-b")
        let otherPinned = try XCTUnwrap(otherSpace.pinnedTabs.first)

        store.updateTabTitle("pinned-guid", title: "Renamed")

        try waitUntil(otherSpace, describing: "title edit reaches the other Space") {
            otherPinned.storedTitle == "Renamed" && otherPinned.title == "Renamed"
        }
    }

    func testProfileScopedPinnedFaviconSyncDoesNotFeedBackAcrossSpaces() async throws {
        try await assertSharedPinnedFaviconSyncDoesNotFeedBack(
            scope: .profile,
            secondProfileId: "Default"
        )
    }

    func testAppScopedPinnedFaviconSyncDoesNotFeedBackAcrossProfiles() async throws {
        try await assertSharedPinnedFaviconSyncDoesNotFeedBack(
            scope: .app,
            secondProfileId: "Work"
        )
    }

    func testAppScopedProfileFaviconFallbackStaysViewOnlyAndMatchingLiveFaviconPersists() async throws {
        let store = try makeStore()
        let sharedFavicon = Data([0x10])
        let defaultProfileFavicon = Data([0x20])
        let workProfileFavicon = Data([0x30])
        try seedPinnedTab(
            in: store,
            guid: "pinned-guid",
            url: "https://github.com/example/actions",
            favicon: sharedFavicon
        )
        try await store.changePinnedTabScope(
            to: .app,
            preferredProfileId: "Default",
            preferredSpaceId: "space-a"
        )

        let defaultState = BrowserState(
            windowId: 1,
            localStore: store,
            profileId: "Default",
            spaceId: "space-a"
        )
        let workState = BrowserState(
            windowId: 2,
            localStore: store,
            profileId: "Work",
            spaceId: "space-b"
        )
        let defaultPinned = try XCTUnwrap(defaultState.pinnedTabs.first)
        let workPinned = try XCTUnwrap(workState.pinnedTabs.first)
        let sharedGuid = try XCTUnwrap(defaultPinned.guidInLocalDB)
        XCTAssertEqual(workPinned.guidInLocalDB, sharedGuid)
        XCTAssertFalse(defaultPinned.allowsProfileScopedFaviconPersistence)
        XCTAssertFalse(workPinned.allowsProfileScopedFaviconPersistence)

        defaultPinned.updateProfileScopedFaviconData(
            defaultProfileFavicon,
            sourceURLString: defaultPinned.pinnedUrl
        )
        workPinned.updateProfileScopedFaviconData(
            workProfileFavicon,
            sourceURLString: workPinned.pinnedUrl
        )
        await store.performBackgroundWriteAndWait { _ in }

        XCTAssertEqual(defaultPinned.cachedFaviconData, sharedFavicon)
        XCTAssertEqual(workPinned.cachedFaviconData, sharedFavicon)
        XCTAssertEqual(store.getTab(by: sharedGuid)?.favicon, sharedFavicon)

        bindOpenPinnedTab(
            defaultPinned,
            to: defaultState,
            chromiumGuid: 101,
            favicon: defaultProfileFavicon
        )
        await store.performBackgroundWriteAndWait { _ in }

        XCTAssertEqual(store.getTab(by: sharedGuid)?.favicon, defaultProfileFavicon)
    }

    func testProfileScopedProfileFaviconFallbackPersistsSnapshot() async throws {
        try await assertProfileScopedFaviconFallbackPersists(scope: .profile)
    }

    func testSpaceScopedProfileFaviconFallbackPersistsSnapshot() async throws {
        try await assertProfileScopedFaviconFallbackPersists(scope: .space)
    }

    func testPassiveFaviconSyncUpdatesCacheWithoutPersisting() {
        let tab = Tab(
            guid: 1,
            url: "https://github.com/example/actions",
            isActive: false,
            index: 0,
            faviconData: Data([0x10])
        )
        var writeBacks: [Data] = []
        tab.setFaviconSnapshotUpdater { data, _ in writeBacks.append(data) }

        tab.hydrateCachedFaviconData(Data([0x20]))

        XCTAssertEqual(tab.cachedFaviconData, Data([0x20]))
        XCTAssertTrue(writeBacks.isEmpty)
    }

    func testRebindingSameWrapperDoesNotResampleItsFavicon() {
        let wrapperFavicon = Data([0x10])
        let syncedFavicon = Data([0x20])
        let changedFavicon = Data([0x30])
        let wrapper = PinnedEditWebContentWrapperSpy(
            urlString: "https://github.com/example/actions"
        )
        wrapper.favIconData = wrapperFavicon
        let tab = Tab(
            guid: 1,
            url: wrapper.urlString,
            isActive: false,
            index: 0,
            webContentView: wrapper
        )
        var writeBacks: [Data] = []
        tab.setFaviconSnapshotUpdater { data, _ in writeBacks.append(data) }
        tab.hydrateCachedFaviconData(syncedFavicon)

        tab.setWebContentsWrapper(wrapper: wrapper)

        XCTAssertEqual(tab.cachedFaviconData, syncedFavicon)
        XCTAssertEqual(tab.liveFaviconData, wrapperFavicon)
        XCTAssertTrue(writeBacks.isEmpty)

        wrapper.favIconData = changedFavicon

        XCTAssertEqual(tab.cachedFaviconData, changedFavicon)
        XCTAssertEqual(tab.liveFaviconData, changedFavicon)
        XCTAssertEqual(writeBacks, [changedFavicon])
    }

    func testStoredTitleRemainsAuthoritativeWithoutRebindingWrapper() {
        let wrapper = PinnedEditWebContentWrapperSpy(urlString: "https://example.com")
        wrapper.title = "Page Title"
        let tab = Tab(
            guid: 1,
            url: wrapper.urlString,
            isActive: false,
            index: 0,
            webContentView: wrapper
        )

        tab.applyStoredTitle("Custom Title")
        wrapper.title = "Updated Page Title"

        XCTAssertEqual(tab.title, "Custom Title")
    }

    func testNavigatedPinnedFaviconDoesNotReplaceCanonicalSnapshot() {
        let canonicalURL = "https://www.163.com/news/article.html"
        let readerURL = "chrome-extension://\(ReaderExtensionBridge.extensionId)/reader.html#tab=1"
        let persistedFavicon = Data([0x10])
        let readerFavicon = Data([0x20])
        let navigatedFavicon = Data([0x30])
        let tab = Tab(
            guid: 1,
            url: readerURL,
            isActive: false,
            index: 0,
            faviconData: persistedFavicon
        )
        tab.guidInLocalDB = "pinned-guid"
        tab.pinnedUrl = canonicalURL

        var writeBacks: [(Data, String)] = []
        tab.setFaviconSnapshotUpdater { data, sourceURLString in
            writeBacks.append((data, sourceURLString))
        }

        tab.updateProfileScopedFaviconData(
            readerFavicon,
            sourceURLString: readerURL
        )
        tab.updateCachedFaviconData(
            navigatedFavicon,
            sourceURLString: "https://example.com/other-page"
        )

        XCTAssertEqual(tab.cachedFaviconData, persistedFavicon)
        XCTAssertTrue(writeBacks.isEmpty)
    }

    func testPinnedFaviconCanonicalSourceUpdatesSnapshot() {
        let canonicalURL = "https://example.com/article"
        let persistedFavicon = Data([0x10])
        let updatedFavicon = Data([0x20])
        let tab = Tab(
            guid: 1,
            url: canonicalURL,
            isActive: false,
            index: 0,
            faviconData: persistedFavicon
        )
        tab.guidInLocalDB = "pinned-guid"
        tab.pinnedUrl = canonicalURL

        var writeBacks: [(Data, String)] = []
        tab.setFaviconSnapshotUpdater { data, sourceURLString in
            writeBacks.append((data, sourceURLString))
        }

        tab.updateProfileScopedFaviconData(
            updatedFavicon,
            sourceURLString: "https://EXAMPLE.com/article#reader-position"
        )

        XCTAssertEqual(tab.cachedFaviconData, updatedFavicon)
        XCTAssertEqual(writeBacks.count, 1)
        XCTAssertEqual(writeBacks.first?.0, updatedFavicon)
        XCTAssertEqual(writeBacks.first?.1, "https://EXAMPLE.com/article#reader-position")
    }

    func testPinnedFaviconDatabaseWriteRejectsNonCanonicalSourceURL() async throws {
        let store = try makeStore()
        let canonicalURL = "https://www.163.com/news/article.html"
        let persistedFavicon = Data([0x10])
        let readerFavicon = Data([0x20])
        let updatedFavicon = Data([0x30])
        try seedPinnedTab(
            in: store,
            guid: "pinned-guid",
            url: canonicalURL,
            favicon: persistedFavicon
        )

        store.updatePinnedTabFavicon(
            "pinned-guid",
            favicon: readerFavicon,
            sourceURLString: "chrome-extension://\(ReaderExtensionBridge.extensionId)/reader.html#tab=1"
        )
        await store.performBackgroundWriteAndWait { _ in }

        XCTAssertEqual(store.getTab(by: "pinned-guid")?.favicon, persistedFavicon)

        store.updatePinnedTabFavicon(
            "pinned-guid",
            favicon: updatedFavicon,
            sourceURLString: "\(canonicalURL)#section"
        )
        await store.performBackgroundWriteAndWait { _ in }

        XCTAssertEqual(store.getTab(by: "pinned-guid")?.favicon, updatedFavicon)
    }

    func testPinnedTabOriginNavigationReturnsOpenTabToOriginalURL() throws {
        let store = try makeStore()
        try seedPinnedTab(in: store, guid: "pinned-guid", url: "https://www.google.com/")

        let state = BrowserState(windowId: 1, localStore: store,
                                 profileId: "Default", spaceId: "space-a")
        let pinnedTab = try XCTUnwrap(state.pinnedTabs.first)
        let wrapper = PinnedEditWebContentWrapperSpy(
            urlString: "https://www.google.com/search?q=1"
        )
        pinnedTab.isOpenned = true
        pinnedTab.setWebContentsWrapper(wrapper: wrapper)

        state.navigatePinnedTabToOriginalURL(pinnedTab)

        XCTAssertEqual(wrapper.navigatedURLs, ["https://www.google.com/"])
    }

    func testPinnedTabOriginNavigationDoesNothingAtOriginalURL() throws {
        let store = try makeStore()
        try seedPinnedTab(in: store, guid: "pinned-guid", url: "https://www.google.com/")

        let state = BrowserState(windowId: 1, localStore: store,
                                 profileId: "Default", spaceId: "space-a")
        let pinnedTab = try XCTUnwrap(state.pinnedTabs.first)
        let wrapper = PinnedEditWebContentWrapperSpy(urlString: "https://www.google.com/")
        pinnedTab.isOpenned = true
        pinnedTab.setWebContentsWrapper(wrapper: wrapper)

        state.navigatePinnedTabToOriginalURL(pinnedTab)

        XCTAssertTrue(wrapper.navigatedURLs.isEmpty)
        XCTAssertTrue(wrapper.customValues.isEmpty)
    }

    func testPinnedTabOriginNavigationDoesNothingForEquivalentWWWURL() throws {
        let store = try makeStore()
        try seedPinnedTab(in: store, guid: "pinned-guid", url: "https://www.google.com/")

        let state = BrowserState(windowId: 1, localStore: store,
                                 profileId: "Default", spaceId: "space-a")
        let pinnedTab = try XCTUnwrap(state.pinnedTabs.first)
        let wrapper = PinnedEditWebContentWrapperSpy(urlString: "https://google.com")
        pinnedTab.isOpenned = true
        pinnedTab.setWebContentsWrapper(wrapper: wrapper)

        state.navigatePinnedTabToOriginalURL(pinnedTab)

        XCTAssertTrue(wrapper.navigatedURLs.isEmpty)
        XCTAssertTrue(wrapper.customValues.isEmpty)
    }

    func testPinnedTabSeparationOpensCurrentURLInBackgroundBeforeReturningToOrigin() throws {
        let store = try makeStore()
        try seedPinnedTab(in: store, guid: "pinned-guid", url: "https://www.google.com/")

        let state = PinnedOriginRecordingBrowserState(
            windowId: 1,
            localStore: store,
            profileId: "Default",
            spaceId: "space-a"
        )
        let pinnedTab = try XCTUnwrap(state.pinnedTabs.first)
        let wrapper = PinnedEditWebContentWrapperSpy(
            urlString: "https://www.google.com/search?q=1"
        )
        pinnedTab.isOpenned = true
        pinnedTab.setWebContentsWrapper(wrapper: wrapper)

        state.separatePinnedTabFromCurrentURL(pinnedTab)

        XCTAssertEqual(
            state.createTabRequests,
            [
                .init(
                    url: "https://www.google.com/search?q=1",
                    customGuid: nil,
                    focusAfterCreate: false
                )
            ]
        )
        XCTAssertEqual(wrapper.navigatedURLs, ["https://www.google.com/"])
    }

    func testScopeMigrationRebindsOpenPinnedTabWithoutReplacingRuntimeObject() async throws {
        let store = try makeStore()
        let originalFavicon = Data([0x10])
        let updatedFavicon = Data([0x20])
        try seedPinnedTab(
            in: store,
            guid: "pinned-guid",
            url: "https://old.example",
            favicon: originalFavicon
        )
        let context = try XCTUnwrap(store.getMainContext())
        context.insert(SpaceModel(
            spaceId: "space-a",
            profileId: "Default",
            name: "A",
            colorHex: "#000000",
            iconName: "star",
            sortOrder: 0
        ))
        try context.save()

        let state = BrowserState(
            windowId: 1,
            localStore: store,
            profileId: "Default",
            spaceId: "space-a"
        )
        let pinnedTab = try XCTUnwrap(state.pinnedTabs.first)
        let wrapper = PinnedEditWebContentWrapperSpy(urlString: "https://old.example")
        wrapper.favIconData = originalFavicon
        let liveTab = Tab(
            guid: 99,
            url: "https://old.example",
            isActive: true,
            index: 0,
            webContentView: wrapper,
            customGuid: "pinned-guid",
            faviconData: originalFavicon
        )
        state.tabs = [liveTab]
        pinnedTab.isOpenned = true
        pinnedTab.guid = liveTab.guid
        pinnedTab.setWebContentsWrapper(wrapper: wrapper)

        try await store.changePinnedTabScope(
            to: .space,
            preferredProfileId: "Default",
            preferredSpaceId: "space-a"
        )

        try waitUntil(state, describing: "scope migration rebinds the live pinned tab") {
            state.pinnedTabs.first === pinnedTab &&
            pinnedTab.guidInLocalDB != "pinned-guid" &&
            liveTab.guidInLocalDB == pinnedTab.guidInLocalDB
        }
        let newGuid = try XCTUnwrap(pinnedTab.guidInLocalDB)
        XCTAssertTrue(state.pinnedTabs.first === pinnedTab)
        XCTAssertEqual(liveTab.guidInLocalDB, newGuid)
        XCTAssertEqual(wrapper.customValues.last, newGuid)
        XCTAssertTrue(wrapper.navigatedURLs.isEmpty)

        wrapper.favIconData = updatedFavicon
        await store.performBackgroundWriteAndWait { _ in }

        XCTAssertEqual(store.getTab(by: newGuid)?.favicon, updatedFavicon)
        XCTAssertEqual(store.getTab(by: "pinned-guid")?.favicon, originalFavicon)
    }

    func testEditOpenedBeforeScopeMigrationWritesReboundActiveGuid() async throws {
        let store = try makeStore()
        try seedPinnedTab(in: store, guid: "pinned-guid", url: "https://old.example")
        let context = try XCTUnwrap(store.getMainContext())
        context.insert(SpaceModel(
            spaceId: "space-a",
            profileId: "Default",
            name: "A",
            colorHex: "#000000",
            iconName: "star",
            sortOrder: 0
        ))
        try context.save()

        let state = BrowserState(
            windowId: 1,
            localStore: store,
            profileId: "Default",
            spaceId: "space-a"
        )
        // This is the object an already-open edit sheet retains.
        let editTarget = try XCTUnwrap(state.pinnedTabs.first)

        try await store.changePinnedTabScope(to: .space)
        try waitUntil(state, describing: "scope migration rebinds the edit target") {
            editTarget.guidInLocalDB != "pinned-guid"
        }
        let reboundGuid = try XCTUnwrap(editTarget.guidInLocalDB)

        Tab.applyPinnedTabEdit(
            targetTab: editTarget,
            url: "https://new.example",
            title: "Renamed",
            in: state
        )
        await store.performBackgroundWriteAndWait { _ in }
        await settleAsyncWork()

        let active = try XCTUnwrap(store.getTab(by: reboundGuid))
        XCTAssertEqual(active.url.absoluteString, "https://new.example")
        XCTAssertEqual(active.title, "Renamed")

        let inactiveBackup = try XCTUnwrap(store.getTab(by: "pinned-guid"))
        XCTAssertEqual(inactiveBackup.url.absoluteString, "https://old.example")
        XCTAssertEqual(inactiveBackup.title, "Pinned")
    }

    private func makeStore() throws -> LocalStore {
        let directory = try makeStoreDirectory()
        let store = LocalStore(
            account: Account(userID: UUID().uuidString),
            storeDirectoryURL: directory,
            presentsCompatibilityAlerts: false
        )
        stores.append(store)
        return store
    }

    private func makeStoreDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        return directory
    }

    private func seedPinnedTab(
        in store: LocalStore,
        guid: String,
        url: String,
        favicon: Data? = nil
    ) throws {
        let context = try XCTUnwrap(store.getMainContext())
        let profile = ProfileModel(profileId: "Default")
        context.insert(profile)

        let pinnedModel = TabDataModel(
            title: "Pinned",
            guid: guid,
            index: 0,
            url: URL(string: url)!,
            favicon: favicon,
            createdDate: Date(),
            updatedDate: Date()
        )
        pinnedModel.dataType = TabDataType.pinnedTab
        pinnedModel.profile = profile
        context.insert(pinnedModel)
        try context.save()
    }

    private func assertProfileScopedFaviconFallbackPersists(
        scope: PinnedTabScope
    ) async throws {
        let store = try makeStore()
        let persistedFavicon = Data([0x10])
        let fallbackFavicon = Data([0x20])
        try seedPinnedTab(
            in: store,
            guid: "pinned-guid",
            url: "https://github.com/example/actions",
            favicon: persistedFavicon
        )

        if scope == .space {
            let context = try XCTUnwrap(store.getMainContext())
            context.insert(SpaceModel(
                spaceId: "space-a",
                profileId: "Default",
                name: "A",
                colorHex: "#000000",
                iconName: "star",
                sortOrder: 0
            ))
            try context.save()
            try await store.changePinnedTabScope(
                to: .space,
                preferredProfileId: "Default",
                preferredSpaceId: "space-a"
            )
        }

        let state = BrowserState(
            windowId: 1,
            localStore: store,
            profileId: "Default",
            spaceId: "space-a"
        )
        let pinnedTab = try XCTUnwrap(state.pinnedTabs.first)
        let guid = try XCTUnwrap(pinnedTab.guidInLocalDB)
        XCTAssertTrue(pinnedTab.allowsProfileScopedFaviconPersistence)

        pinnedTab.updateProfileScopedFaviconData(
            fallbackFavicon,
            sourceURLString: pinnedTab.pinnedUrl
        )
        await store.performBackgroundWriteAndWait { _ in }

        XCTAssertEqual(pinnedTab.cachedFaviconData, fallbackFavicon)
        XCTAssertEqual(store.getTab(by: guid)?.favicon, fallbackFavicon)
    }

    private func assertSharedPinnedFaviconSyncDoesNotFeedBack(
        scope: PinnedTabScope,
        secondProfileId: String
    ) async throws {
        let store = try makeStore()
        let persistedFavicon = Data([0x10])
        let firstLiveFavicon = Data([0x20])
        let secondLiveFavicon = Data([0x30])
        try seedPinnedTab(
            in: store,
            guid: "pinned-guid",
            url: "https://github.com/example/actions",
            favicon: persistedFavicon
        )
        if scope != .profile {
            try await store.changePinnedTabScope(
                to: scope,
                preferredProfileId: "Default",
                preferredSpaceId: "space-a"
            )
            await settleAsyncWork()
        }

        let firstState = BrowserState(
            windowId: 1,
            localStore: store,
            profileId: "Default",
            spaceId: "space-a"
        )
        let secondState = BrowserState(
            windowId: 2,
            localStore: store,
            profileId: secondProfileId,
            spaceId: "space-b"
        )
        let firstPinned = try XCTUnwrap(firstState.pinnedTabs.first)
        let secondPinned = try XCTUnwrap(secondState.pinnedTabs.first)
        let sharedGuid = try XCTUnwrap(firstPinned.guidInLocalDB)
        XCTAssertEqual(secondPinned.guidInLocalDB, sharedGuid)

        var firstWriteBacks: [Data] = []
        var secondWriteBacks: [Data] = []
        firstPinned.setFaviconSnapshotUpdater { data, _ in firstWriteBacks.append(data) }
        secondPinned.setFaviconSnapshotUpdater { data, _ in secondWriteBacks.append(data) }

        bindOpenPinnedTab(
            firstPinned,
            to: firstState,
            chromiumGuid: 101,
            favicon: firstLiveFavicon
        )
        bindOpenPinnedTab(
            secondPinned,
            to: secondState,
            chromiumGuid: 202,
            favicon: secondLiveFavicon
        )
        firstWriteBacks.removeAll()
        secondWriteBacks.removeAll()

        store.updateTabFavicon(sharedGuid, favicon: firstLiveFavicon)
        await store.performBackgroundWriteAndWait { _ in }

        try waitUntil(secondState, describing: "shared favicon update is applied without write-back") {
            secondPinned.cachedFaviconData == firstLiveFavicon || !secondWriteBacks.isEmpty
        }
        XCTAssertTrue(firstWriteBacks.isEmpty)
        XCTAssertTrue(secondWriteBacks.isEmpty)
        XCTAssertEqual(secondPinned.cachedFaviconData, firstLiveFavicon)
        XCTAssertEqual(secondPinned.liveFaviconData, secondLiveFavicon)
        XCTAssertEqual(store.getTab(by: sharedGuid)?.favicon, firstLiveFavicon)
    }

    private func bindOpenPinnedTab(
        _ pinnedTab: Tab,
        to state: BrowserState,
        chromiumGuid: Int,
        favicon: Data
    ) {
        let wrapper = PinnedEditWebContentWrapperSpy(urlString: pinnedTab.pinnedUrl)
        wrapper.favIconData = favicon
        let liveTab = Tab(
            guid: chromiumGuid,
            url: pinnedTab.pinnedUrl,
            isActive: false,
            index: 0,
            webContentView: wrapper,
            customGuid: pinnedTab.guidInLocalDB,
            profileId: state.profileId,
            faviconData: favicon
        )
        liveTab.isPinned = true
        state.tabs = [liveTab]
        pinnedTab.isOpenned = true
        pinnedTab.guid = liveTab.guid
        pinnedTab.setWebContentsWrapper(wrapper: wrapper)
    }

    private func settleAsyncWork() async {
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    private func waitUntil(_ state: BrowserState,
                           describing expectation: String,
                           timeout: TimeInterval = 2,
                           condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTFail("Timed out waiting for: \(expectation). pinnedTabs=\(state.pinnedTabs.map { "\($0.guidInLocalDB ?? "?") url=\($0.url ?? "nil") pinnedUrl=\($0.pinnedUrl ?? "nil") open=\($0.isOpenned)" })")
    }
}

private final class PinnedOriginRecordingBrowserState: BrowserState {
    struct CreateTabRequest: Equatable {
        let url: String?
        let customGuid: String?
        let focusAfterCreate: Bool
    }

    private(set) var createTabRequests: [CreateTabRequest] = []

    override func createTab(
        _ url: String?,
        customGuid: String?,
        focusAfterCreate: Bool
    ) {
        createTabRequests.append(
            .init(
                url: url,
                customGuid: customGuid,
                focusAfterCreate: focusAfterCreate
            )
        )
    }
}

private final class PinnedEditWebContentWrapperSpy: NSObject, WebContentWrapper {
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
    @objc dynamic var isDistillable = false
    @objc dynamic var devToolsTargetId: String? = nil

    func requestAccessibilityTreeSnapshot(
        withMinimumPages minimumPages: Int,
        timeoutMs: Int,
        completion: @escaping ([String: Any]?) -> Void
    ) {
        completion(nil)
    }

    private(set) var navigatedURLs: [String] = []
    private(set) var customValues: [String] = []

    init(urlString: String?) {
        self.urlString = urlString
        super.init()
    }

    func close() {}
    func reload() {}
    func reloadBypassingCache() {}
    func goBack() {}
    func goForward() {}
    func stopLoading() {}
    func navigate(toURL urlString: String) {
        navigatedURLs.append(urlString)
        self.urlString = urlString
    }
    func setAsActiveTab() {}
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
    func updateTabCustomValue(_ customValue: String) { customValues.append(customValue) }
    func focus() {}
    func restoreFocus() {}
    func updateSecurityState(_ securityState: [AnyHashable: Any]) {}
    func setAudioMuted(_ muted: Bool) {}
    func muteAudio() {}
    func unmuteAudio() {}
}

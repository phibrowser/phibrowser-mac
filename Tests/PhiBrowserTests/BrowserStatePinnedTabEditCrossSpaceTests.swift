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

    override func tearDownWithError() throws {
        // 这个类驱动真的作用域迁移，而迁移的成功路径写 `UserDefaults.standard`——在 hosted
        // 测试里那就是 Phi 自己的偏好域。
        clearPinnedTabScopeMirrorDefaults()
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
        let pinnedTab = try XCTUnwrap(state.pinnedTabs.first)
        let wrapper = PinnedEditWebContentWrapperSpy(urlString: "https://old.example")
        let liveTab = Tab(
            guid: 99,
            url: "https://old.example",
            isActive: true,
            index: 0,
            webContentView: wrapper,
            customGuid: "pinned-guid"
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
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let active = try XCTUnwrap(store.getTab(by: reboundGuid))
        XCTAssertEqual(active.url.absoluteString, "https://new.example")
        XCTAssertEqual(active.title, "Renamed")

        let inactiveBackup = try XCTUnwrap(store.getTab(by: "pinned-guid"))
        XCTAssertEqual(inactiveBackup.url.absoluteString, "https://old.example")
        XCTAssertEqual(inactiveBackup.title, "Pinned")
    }

    private func makeStore() throws -> LocalStore {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        return LocalStore(account: Account(userID: UUID().uuidString), storeDirectoryURL: directory)
    }

    private func seedPinnedTab(in store: LocalStore, guid: String, url: String) throws {
        let context = try XCTUnwrap(store.getMainContext())
        let profile = ProfileModel(profileId: "Default")
        context.insert(profile)

        let pinnedModel = TabDataModel(
            title: "Pinned",
            guid: guid,
            index: 0,
            url: URL(string: url)!,
            favicon: nil,
            createdDate: Date(),
            updatedDate: Date()
        )
        pinnedModel.dataType = TabDataType.pinnedTab
        context.insert(pinnedModel)
        pinnedModel.profile = profile
        try context.save()
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

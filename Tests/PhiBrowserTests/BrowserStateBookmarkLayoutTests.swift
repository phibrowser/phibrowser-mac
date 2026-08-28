// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SwiftData
import XCTest
@testable import Phi

@MainActor
final class BrowserStateBookmarkLayoutTests: XCTestCase {
    private var tempDirectories: [URL] = []
    private var originalLayoutRawValue: String?

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalLayoutRawValue = UserDefaults.standard.string(forKey: PhiPreferences.GeneralSettings.layoutModeKey)
        PhiPreferences.GeneralSettings.saveLayoutMode(.performance)
    }

    override func tearDownWithError() throws {
        if let originalLayoutRawValue {
            UserDefaults.standard.set(originalLayoutRawValue,
                                      forKey: PhiPreferences.GeneralSettings.layoutModeKey)
        } else {
            UserDefaults.standard.removeObject(forKey: PhiPreferences.GeneralSettings.layoutModeKey)
        }
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification,
                                        object: UserDefaults.standard)

        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testSwitchingToComfortableDetachesOpenBookmarkTab() throws {
        let state = try makeState()
        let bookmarkGuid = "bookmark-comfortable"
        let bookmark = try createBookmark(in: state,
                                          guid: bookmarkGuid,
                                          url: "https://bookmark.example")
        let wrapper = BookmarkLayoutTestWebContentWrapper(urlString: "https://bookmark.example")
        let bookmarkTab = Tab(guid: 101,
                              url: "https://bookmark.example",
                              isActive: true,
                              index: 0,
                              title: "Bookmark",
                              webContentView: wrapper,
                              customGuid: bookmarkGuid)
        state.tabs = [bookmarkTab]
        bookmark.isOpened = true
        bookmark.isActive = true
        bookmark.chromiumTabGuid = bookmarkTab.guid
        bookmark.setWebContentWrapper(wrapper)
        state.updateNormalTabs()

        XCTAssertEqual(bookmarkTab.guidInLocalDB, bookmarkGuid)
        XCTAssertTrue(state.normalTabs.isEmpty)

        switchLayout(to: .comfortable)
        XCTAssertTrue(waitUntil {
            state.layoutMode == .comfortable && bookmarkTab.guidInLocalDB == nil
        })

        XCTAssertEqual(wrapper.customValues.last, "")
        XCTAssertFalse(bookmark.isOpened)
        XCTAssertFalse(bookmark.isActive)
        XCTAssertEqual(bookmark.chromiumTabGuid, -1)
        XCTAssertEqual(state.normalTabs.map(\.guid), [101])
    }

    func testSwitchingToComfortableDetachesSplitBookmarkBindingWithoutRemovingSplit() throws {
        let state = try makeState()
        let bookmarkGuid = "split-bookmark-comfortable"
        let bookmark = try createBookmark(in: state,
                                          guid: bookmarkGuid,
                                          url: "https://primary.example",
                                          secondaryUrl: "https://secondary.example")
        let primary = Tab(guid: 201,
                          url: "https://primary.example",
                          isActive: true,
                          index: 0,
                          title: "Primary")
        let secondary = Tab(guid: 202,
                            url: "https://secondary.example",
                            isActive: false,
                            index: 1,
                            title: "Secondary")
        let split = SplitGroup(id: "split-comfortable",
                               primaryTabId: primary.guid,
                               secondaryTabId: secondary.guid,
                               layout: .vertical,
                               ratio: 0.5)
        state.tabs = [primary, secondary]
        state.splits = [split]
        state.splitBookmarkBindings[bookmarkGuid] = split.id
        state.syncSplitBookmarkOpenedState(bookmarkGuid: bookmarkGuid)
        state.updateNormalTabs()

        XCTAssertTrue(bookmark.isOpened)
        XCTAssertTrue(state.normalTabs.isEmpty)

        switchLayout(to: .comfortable)
        XCTAssertTrue(waitUntil {
            state.layoutMode == .comfortable && state.splitBookmarkBindings[bookmarkGuid] == nil
        })

        XCTAssertEqual(state.splits, [split])
        XCTAssertFalse(bookmark.isOpened)
        XCTAssertEqual(bookmark.chromiumTabGuid, -1)
        XCTAssertEqual(state.normalTabs.map(\.guid), [201, 202])
    }

    func testOpeningSplitBookmarkInComfortableDoesNotBindPendingSplitToBookmark() throws {
        let state = try makeState()
        let bookmarkGuid = "split-bookmark-open-comfortable"
        let bookmark = try createBookmark(in: state,
                                          guid: bookmarkGuid,
                                          url: "https://primary.example",
                                          secondaryUrl: "https://secondary.example")
        state.layoutMode = .comfortable

        state.openBookmark(bookmark)

        XCTAssertEqual(state.pendingPrimarySplitTargetByGuid.count, 1)
        XCTAssertNil(state.pendingPrimarySplitTargetByGuid.values.first?.boundBookmarkGuid)
    }

    func testOpeningSplitBookmarkRestoresPersistedLayout() throws {
        let state = try makeState()
        let bookmark = try createBookmark(in: state,
                                          guid: "stacked-bookmark",
                                          url: "https://primary.example",
                                          secondaryUrl: "https://secondary.example",
                                          layout: .horizontal)

        XCTAssertEqual(bookmark.layout, .horizontal)

        state.openBookmark(bookmark)

        XCTAssertEqual(state.pendingPrimarySplitTargetByGuid.values.first?.layout, .horizontal)
    }

    func testLegacySplitBookmarkDefaultsToSideBySideLayout() throws {
        let state = try makeState()
        let bookmark = try createBookmark(in: state,
                                          guid: "legacy-split-bookmark",
                                          url: "https://primary.example",
                                          secondaryUrl: "https://secondary.example")

        XCTAssertEqual(bookmark.layout, .vertical)
    }

    func testChangingSplitBookmarkLayoutUpdatesRuntimeAndStore() throws {
        let state = try makeState()
        let bookmark = try createBookmark(in: state,
                                          guid: "convert-split-bookmark",
                                          url: "https://primary.example",
                                          secondaryUrl: "https://secondary.example")

        state.updateBookmarkSplitLayout(bookmarkGuid: bookmark.guid, layout: .horizontal)

        XCTAssertEqual(bookmark.layout, .horizontal)
        XCTAssertTrue(waitUntil {
            guard let context = state.localStore.getMainContext() else { return false }
            return (try? context.fetch(FetchDescriptor<TabDataModel>()).first(where: {
                $0.guid == bookmark.guid
            })?.layout) == SplitLayout.horizontal.rawValue
        })
    }

    func testSwitchingToComfortableClearsPrimaryPendingSplitBookmarkBinding() throws {
        let state = try makeState()
        let bookmarkGuid = "split-bookmark-primary-pending"
        let bookmark = try createBookmark(in: state,
                                          guid: bookmarkGuid,
                                          url: "https://primary.example",
                                          secondaryUrl: "https://secondary.example")

        state.openBookmark(bookmark)

        let pendingGuid = try XCTUnwrap(
            state.pendingPrimarySplitTargetByGuid.first {
                $0.value.boundBookmarkGuid == bookmarkGuid
            }?.key
        )

        switchLayout(to: .comfortable)
        XCTAssertTrue(waitUntil {
            state.pendingPrimarySplitTargetByGuid[pendingGuid]?.boundBookmarkGuid == nil
        })

        let primaryTab = Tab(guid: 301,
                             url: "https://primary.example",
                             isActive: true,
                             index: 0,
                             title: "Primary",
                             customGuid: pendingGuid)
        state.consumePendingPrimarySplit(for: primaryTab)

        XCTAssertTrue(state.pendingSplitPartnerByCustomGuid.values.allSatisfy {
            $0.boundBookmarkGuid == nil
        })
    }

    func testSwitchingToComfortableClearsPartnerPendingSplitBookmarkBinding() throws {
        let state = try makeState()
        let bookmarkGuid = "split-bookmark-partner-pending"
        let bookmark = try createBookmark(in: state,
                                          guid: bookmarkGuid,
                                          url: "https://primary.example",
                                          secondaryUrl: "https://secondary.example")
        state.openBookmark(bookmark)
        let pendingGuid = try XCTUnwrap(
            state.pendingPrimarySplitTargetByGuid.first {
                $0.value.boundBookmarkGuid == bookmarkGuid
            }?.key
        )
        let primaryTab = Tab(guid: 401,
                             url: "https://primary.example",
                             isActive: true,
                             index: 0,
                             title: "Primary",
                             customGuid: pendingGuid)
        state.consumePendingPrimarySplit(for: primaryTab)
        let partnerPendingGuid = try XCTUnwrap(
            state.pendingSplitPartnerByCustomGuid.first {
                $0.value.boundBookmarkGuid == bookmarkGuid
            }?.key
        )

        switchLayout(to: .comfortable)
        XCTAssertTrue(waitUntil {
            state.pendingSplitPartnerByCustomGuid[partnerPendingGuid]?.boundBookmarkGuid == nil
        })
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

    private func createBookmark(in state: BrowserState,
                                guid: String,
                                url: String,
                                secondaryUrl: String? = nil,
                                layout: SplitLayout? = nil) throws -> Bookmark {
        state.localStore.createBookmark(url: url,
                                        title: "Bookmark",
                                        profileId: state.profileId,
                                        parentId: nil,
                                        guid: guid,
                                        spaceId: state.spaceId,
                                        secondaryUrl: secondaryUrl,
                                        layout: layout?.rawValue)
        XCTAssertTrue(waitUntil {
            state.bookmarkManager.bookmark(withGuid: guid) != nil
        })
        return try XCTUnwrap(state.bookmarkManager.bookmark(withGuid: guid))
    }

    private func switchLayout(to mode: LayoutMode) {
        PhiPreferences.GeneralSettings.saveLayoutMode(mode)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification,
                                        object: UserDefaults.standard)
    }

    private func waitUntil(timeout: TimeInterval = 1,
                           condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return false
    }
}

private final class BookmarkLayoutTestWebContentWrapper: NSObject, WebContentWrapper {
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
    @objc dynamic var isDiscarded = false
    @objc dynamic var isUnloaded = false
    @objc dynamic var isDistillable = false
    @objc dynamic var devToolsTargetId: String? = nil

    func requestAccessibilityTreeSnapshot(
        withMinimumPages minimumPages: Int,
        timeoutMs: Int,
        completion: @escaping ([String: Any]?) -> Void
    ) {
        completion(nil)
    }

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
    func navigate(toURL urlString: String) { self.urlString = urlString }
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
    func updateIsPeekSurface(_ isPeekSurface: Bool) {}
    func setAudioMuted(_ muted: Bool) {}
    func muteAudio() {}
    func unmuteAudio() {}
}

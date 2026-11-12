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

    func testBookmarkEditSubmenuIsLimitedToOrdinarySidebarBookmarks() {
        let bookmark = Bookmark(title: "Bookmark", url: "https://example.com")
        let menu = NSMenu()
        bookmark.makeContextMenu(on: menu, source: .sidebar)
        let submenu = menu.items.compactMap(\.submenu).first {
            $0.items.contains { $0.action == NSSelectorFromString("replaceSavedBookmarkURL") }
        }
        XCTAssertEqual(submenu?.items.count, 2)
        XCTAssertEqual(submenu?.items.first?.action, NSSelectorFromString("edit"))
        XCTAssertEqual(submenu?.items.last?.isEnabled, false)
        submenu?.update()
        XCTAssertEqual(submenu?.items.last?.isEnabled, false)

        bookmark.makeContextMenu(on: menu, source: .bookmarkBar)
        XCTAssertTrue(menu.items.contains { $0.action == NSSelectorFromString("edit") })
        XCTAssertFalse(menu.items.contains { $0.submenu?.items.contains { $0.action == NSSelectorFromString("replaceSavedBookmarkURL") } == true })

        bookmark.secondaryUrl = "https://split.example"
        bookmark.makeContextMenu(on: menu, source: .sidebar)
        XCTAssertTrue(menu.items.contains { $0.action == NSSelectorFromString("edit") })
        XCTAssertFalse(menu.items.contains { $0.submenu?.items.contains { $0.action == NSSelectorFromString("replaceSavedBookmarkURL") } == true })
    }

    func testReplaceSavedBookmarkURLPreservesLivePageAndTitle() throws {
        let state = try makeState()
        let bookmark = try createBookmark(in: state, guid: "replace-bookmark", url: "https://old.example")
        XCTAssertNil(state.replacementURLForBookmark(guid: bookmark.guid))
        let wrapper = BookmarkLayoutTestWebContentWrapper(urlString: "https://old.example")
        let tab = Tab(guid: 101, url: wrapper.urlString, isActive: false, index: 0,
                      webContentView: wrapper, customGuid: bookmark.guid)
        state.tabs = [tab]
        bookmark.isOpened = true
        bookmark.chromiumTabGuid = tab.guid
        bookmark.setWebContentWrapper(wrapper)
        XCTAssertNil(state.replacementURLForBookmark(guid: bookmark.guid))
        wrapper.urlString = "https://new.example/path"
        XCTAssertNotNil(state.replacementURLForBookmark(guid: bookmark.guid))
        state.replaceSavedURLForBookmark(guid: bookmark.guid)
        XCTAssertTrue(waitUntil { bookmark.url == "https://new.example/path" })
        XCTAssertEqual(bookmark.title, "Bookmark")
        XCTAssertTrue(wrapper.navigatedURLs.isEmpty)
        XCTAssertTrue(wrapper.customValues.isEmpty)
        XCTAssertNil(state.replacementURLForBookmark(guid: bookmark.guid))
        wrapper.urlString = "https://another.example"
        bookmark.secondaryUrl = "https://split.example"
        XCTAssertNil(state.replacementURLForBookmark(guid: bookmark.guid))
        bookmark.secondaryUrl = nil
        state.tabs = []
        XCTAssertNil(state.replacementURLForBookmark(guid: bookmark.guid))
    }

    func testTabTracksWebContentUnloadedState() {
        let wrapper = BookmarkLayoutTestWebContentWrapper(urlString: "https://example.com")
        wrapper.isUnloaded = true
        let tab = Tab(
            guid: 100,
            url: wrapper.urlString,
            isActive: false,
            index: 0,
            webContentView: wrapper
        )

        XCTAssertTrue(tab.isUnloaded)

        wrapper.isUnloaded = false

        XCTAssertTrue(waitUntil { !tab.isUnloaded })
    }

    func testSidebarSplitPairKeepsFaviconsOpaqueAcrossReclaimedStatesAndPreferenceChanges() {
        let defaults = UserDefaults.standard
        let key = PhiPreferences.GeneralSettings.showUnloadedTabIndicators.rawValue
        let originalValue = defaults.object(forKey: key)
        defaults.removeObject(forKey: key)
        defer {
            defaults.set(originalValue, forKey: key)
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        }

        let leftWrapper = BookmarkLayoutTestWebContentWrapper(urlString: "https://left.example")
        leftWrapper.isUnloaded = true
        let rightWrapper = BookmarkLayoutTestWebContentWrapper(urlString: "https://right.example")
        let leftTab = Tab(
            guid: 1,
            url: leftWrapper.urlString,
            isActive: false,
            index: 0,
            webContentView: leftWrapper
        )
        let rightTab = Tab(
            guid: 2,
            url: rightWrapper.urlString,
            isActive: false,
            index: 1,
            webContentView: rightWrapper
        )
        let cell = SidebarSplitCellView()
        cell.configure(with: SplitSidebarItem(
            groupId: "split-1-2",
            panes: [leftTab, rightTab],
            browserState: nil
        ))

        XCTAssertEqual(cell.faviconOpacity(paneIndex: 0), 1)
        XCTAssertEqual(cell.faviconOpacity(paneIndex: 1), 1)

        defaults.set(false, forKey: key)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        XCTAssertTrue(waitUntil {
            cell.faviconOpacity(paneIndex: 0) == 1 && cell.faviconOpacity(paneIndex: 1) == 1
        })

        leftWrapper.isUnloaded = false
        rightWrapper.isDiscarded = true
        XCTAssertTrue(waitUntil { !leftTab.isUnloaded && rightTab.isDiscarded })
        XCTAssertEqual(cell.faviconOpacity(paneIndex: 0), 1)
        XCTAssertEqual(cell.faviconOpacity(paneIndex: 1), 1)

        defaults.set(true, forKey: key)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        XCTAssertTrue(waitUntil {
            cell.faviconOpacity(paneIndex: 0) == 1 &&
                cell.faviconOpacity(paneIndex: 1) == 1
        })

        cell.prepareForReuse()
        XCTAssertEqual(cell.faviconOpacity(paneIndex: 0), 1)
        XCTAssertEqual(cell.faviconOpacity(paneIndex: 1), 1)
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
                               tabIds: [primary.guid, secondary.guid],
                               layout: .vertical,
                               fractions: [0.5, 0.5])
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

    /// The primary pane of a split bookmark, arrived from Chromium while its
    /// split is still opening.
    private func arrivePrimaryPane(of bookmark: Bookmark, in state: BrowserState, tabId: Int) throws {
        state.openBookmark(bookmark)
        let pendingGuid = try XCTUnwrap(
            state.pendingPrimarySplitTargetByGuid.first {
                $0.value.boundBookmarkGuid == bookmark.guid
            }?.key
        )
        state.handleNewTabFromChromium(Tab(guid: tabId,
                                           url: "https://primary.example",
                                           isActive: true,
                                           index: 0,
                                           title: "Primary",
                                           customGuid: pendingGuid))
    }

    /// Chromium reports a split a moment after its panes arrive. The panes
    /// of a split its bookmark opened stay out of the tab list meanwhile,
    /// instead of each flashing a row that vanishes behind the bookmark.
    func testPanesOfASplitOpeningFromItsBookmarkStayOutOfTheTabList() throws {
        let state = try makeState()
        let bookmarkGuid = "split-bookmark-opening"
        let bookmark = try createBookmark(in: state,
                                          guid: bookmarkGuid,
                                          url: "https://primary.example",
                                          secondaryUrl: "https://secondary.example")

        try arrivePrimaryPane(of: bookmark, in: state, tabId: 501)

        XCTAssertEqual(state.splitPaneIdsOpeningBehindBookmark, [501])
        XCTAssertTrue(state.normalTabs.isEmpty)

        // The partner is tracked the same way on arrival; then the split lands.
        state.tabs.append(Tab(guid: 502, url: "https://secondary.example",
                              isActive: false, index: 1, title: "Secondary"))
        state.splitPaneIdsOpeningBehindBookmark.insert(502)
        state.splitBookmarkBindings[bookmarkGuid] = "split"
        state.handleSplitCreated(splitId: "split", tabIds: [501, 502],
                                 layout: .vertical, fractions: [0.5, 0.5])

        XCTAssertTrue(state.splitPaneIdsOpeningBehindBookmark.isEmpty)
        XCTAssertTrue(state.normalTabs.isEmpty, "The bound split keeps its panes behind the bookmark")
    }

    func testPaneOfABookmarkSplitThatNeverFormsIsListed() throws {
        let state = try makeState()
        let bookmark = try createBookmark(in: state,
                                          guid: "split-bookmark-abandoned",
                                          url: "https://primary.example",
                                          secondaryUrl: "https://secondary.example")
        try arrivePrimaryPane(of: bookmark, in: state, tabId: 601)
        XCTAssertTrue(state.normalTabs.isEmpty)

        state.listPanesNoLongerOpeningBehindBookmark([601])

        XCTAssertTrue(state.splitPaneIdsOpeningBehindBookmark.isEmpty)
        XCTAssertEqual(state.normalTabs.map(\.guid), [601])
    }

    /// A four-pane bookmark C, A, F, D bound to the live split of tabs 1...4.
    private func makeBoundFourPaneBookmark(in state: BrowserState, guid: String) throws -> Bookmark {
        state.localStore.createBookmark(url: "https://c.example/",
                                        title: "C",
                                        profileId: state.profileId,
                                        parentId: nil,
                                        guid: guid,
                                        spaceId: state.spaceId,
                                        secondaryUrl: "https://a.example/",
                                        secondaryTitle: "A",
                                        splitExtraPanes: [
                                            SplitBookmarkExtraPane(url: "https://f.example/", title: "F"),
                                            SplitBookmarkExtraPane(url: "https://d.example/", title: "D"),
                                        ])
        XCTAssertTrue(waitUntil { state.bookmarkManager.bookmark(withGuid: guid) != nil })
        let bookmark = try XCTUnwrap(state.bookmarkManager.bookmark(withGuid: guid))
        state.tabs = (1...5).map { Tab(guid: $0, url: "https://e\($0).example/", isActive: false, index: $0, title: "E\($0)") }
        state.handleSplitCreated(splitId: "split", tabIds: [1, 2, 3, 4], layout: .vertical,
                                 fractions: [0.25, 0.25, 0.25, 0.25])
        state.splitBookmarkBindings[guid] = "split"
        return bookmark
    }

    func testReorderingABoundSplitResequencesTheBookmarkPanes() throws {
        let state = try makeState()
        let bookmark = try makeBoundFourPaneBookmark(in: state, guid: "reorder-bookmark")

        state.handleSplitContentsChanged(splitId: "split", tabIds: [3, 1, 2, 4])

        XCTAssertEqual(bookmark.splitPanes.map(\.url),
                       ["https://f.example/", "https://c.example/", "https://a.example/", "https://d.example/"])
        XCTAssertEqual(bookmark.splitPanes.map(\.title), ["F", "C", "A", "D"])
        XCTAssertEqual(state.splitBookmarkBindings[bookmark.guid], "split")
        XCTAssertTrue(waitUntil {
            state.localStore.getTab(by: bookmark.guid)?.url.absoluteString == "https://f.example/"
        })
        let row = try XCTUnwrap(state.localStore.getTab(by: bookmark.guid))
        XCTAssertEqual(row.secondaryUrl?.absoluteString, "https://c.example/")
        XCTAssertEqual(row.decodedSplitExtraPanes,
                       [SplitBookmarkExtraPane(url: "https://a.example/", title: "A"),
                        SplitBookmarkExtraPane(url: "https://d.example/", title: "D")])
    }

    /// Panes also leave one by one while the split, the window or the app
    /// closes; that must not strip the bookmark.
    func testPaneLeavingKeepsTheBoundBookmark() throws {
        let state = try makeState()
        let bookmark = try makeBoundFourPaneBookmark(in: state, guid: "teardown-bookmark")

        state.handleSplitContentsChanged(splitId: "split", tabIds: [2, 3, 4])
        state.handleSplitContentsChanged(splitId: "split", tabIds: [3, 4])

        XCTAssertEqual(bookmark.splitPanes.map(\.url),
                       ["https://c.example/", "https://a.example/", "https://f.example/", "https://d.example/"])
    }

    func testReplacedPaneIsSavedIntoTheBoundBookmark() throws {
        let state = try makeState()
        let bookmark = try makeBoundFourPaneBookmark(in: state, guid: "replace-bookmark-pane")

        state.handleSplitContentsChanged(splitId: "split", tabIds: [1, 5, 3, 4])

        XCTAssertEqual(bookmark.splitPanes.map(\.url),
                       ["https://c.example/", "https://e5.example/", "https://f.example/", "https://d.example/"])
        XCTAssertEqual(bookmark.splitPanes.map(\.title), ["C", "E5", "F", "D"])
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

final class BookmarkLayoutTestWebContentWrapper: NSObject, WebContentWrapper {
    let mediaControls: PhiMediaControls = InactiveMediaControlsStub()
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
    @objc dynamic var isMediaSessionMuted = false
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
    @objc dynamic var pageColor: NSColor?
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
    private(set) var navigatedURLs: [String] = []
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
    func updateIsPeekSurface(_ isPeekSurface: Bool) {}
    func updateIsPeekPresented(_ presented: Bool) {}
    func toggleAudioMuted() {}
    func setAudioMuted(_ muted: Bool) {}
    func muteAudio() {}
    func unmuteAudio() {}
}

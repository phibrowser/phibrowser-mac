// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

@MainActor
final class BookmarkFaviconOriginNavigationTests: XCTestCase {
    private var tempDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testNavigatesOpenBookmarkBackToStoredURLInPlace() throws {
        let state = try makeState()
        let bookmark = try createBookmark(
            in: state,
            guid: "bookmark-origin",
            url: "https://bookmark.example/original"
        )
        let wrapper = BookmarkOriginTestWebContentWrapper(
            urlString: "https://other.example/current"
        )
        let tab = Tab(
            guid: 101,
            url: "https://other.example/current",
            isActive: true,
            index: 0,
            webContentView: wrapper,
            customGuid: bookmark.guid
        )
        state.tabs = [tab]
        state.handleBookmarkTabOpened(tab)

        state.navigateBookmarkTabToOriginalURL(tab, bookmark: bookmark)

        XCTAssertTrue(waitUntil {
            wrapper.navigatedURLs == ["https://bookmark.example/original"]
        })
        XCTAssertEqual(wrapper.customValues.first, "")
        XCTAssertTrue(waitUntil {
            wrapper.customValues.last == bookmark.guid
        })
    }

    func testDoesNotNavigateWhenBookmarkAlreadyShowsStoredURL() throws {
        let state = try makeState()
        let bookmark = try createBookmark(
            in: state,
            guid: "bookmark-at-origin",
            url: "https://bookmark.example/original"
        )
        let wrapper = BookmarkOriginTestWebContentWrapper(
            urlString: "https://bookmark.example/original"
        )
        let tab = Tab(
            guid: 102,
            url: "https://bookmark.example/original",
            isActive: true,
            index: 0,
            webContentView: wrapper,
            customGuid: bookmark.guid
        )
        state.tabs = [tab]
        state.handleBookmarkTabOpened(tab)

        state.navigateBookmarkTabToOriginalURL(tab, bookmark: bookmark)
        state.separateBookmarkTabFromCurrentURL(tab, bookmark: bookmark)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertTrue(wrapper.navigatedURLs.isEmpty)
        XCTAssertTrue(wrapper.customValues.isEmpty)
        XCTAssertTrue(state.createTabRequests.isEmpty)
    }

    func testDoesNotNavigateForEquivalentWWWBookmarkURL() throws {
        let state = try makeState()
        let bookmark = try createBookmark(
            in: state,
            guid: "bookmark-equivalent-origin",
            url: "https://www.bookmark.example/"
        )
        let wrapper = BookmarkOriginTestWebContentWrapper(
            urlString: "https://bookmark.example"
        )
        let tab = Tab(
            guid: 104,
            url: "https://bookmark.example",
            isActive: true,
            index: 0,
            webContentView: wrapper,
            customGuid: bookmark.guid
        )
        state.tabs = [tab]
        state.handleBookmarkTabOpened(tab)

        state.navigateBookmarkTabToOriginalURL(tab, bookmark: bookmark)
        state.separateBookmarkTabFromCurrentURL(tab, bookmark: bookmark)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertTrue(wrapper.navigatedURLs.isEmpty)
        XCTAssertTrue(wrapper.customValues.isEmpty)
        XCTAssertTrue(state.createTabRequests.isEmpty)
    }

    func testSeparatesCurrentURLInBackgroundBeforeReturningBookmarkToStoredURL() throws {
        let state = try makeState()
        let bookmark = try createBookmark(
            in: state,
            guid: "bookmark-separate",
            url: "https://bookmark.example/original"
        )
        var events: [String] = []
        state.onCreateTab = { url in
            events.append("create:\(url ?? "")")
        }
        let wrapper = BookmarkOriginTestWebContentWrapper(
            urlString: "https://other.example/current",
            onNavigate: { url in
                events.append("navigate:\(url)")
            }
        )
        let tab = Tab(
            guid: 103,
            url: "https://other.example/current",
            isActive: true,
            index: 0,
            webContentView: wrapper,
            customGuid: bookmark.guid
        )
        state.tabs = [tab]
        state.handleBookmarkTabOpened(tab)
        state.focuseTab(tab)

        state.separateBookmarkTabFromCurrentURL(tab, bookmark: bookmark)

        XCTAssertEqual(
            state.createTabRequests,
            [
                .init(
                    url: "https://other.example/current",
                    customGuid: nil,
                    focusAfterCreate: false
                )
            ]
        )
        XCTAssertEqual(state.focusingTab?.guid, tab.guid)
        XCTAssertTrue(waitUntil {
            wrapper.navigatedURLs == ["https://bookmark.example/original"]
        })
        XCTAssertEqual(state.focusingTab?.guid, tab.guid)
        XCTAssertEqual(
            events,
            [
                "create:https://other.example/current",
                "navigate:https://bookmark.example/original"
            ]
        )
        XCTAssertEqual(wrapper.customValues.first, "")
        XCTAssertTrue(waitUntil {
            wrapper.customValues.last == bookmark.guid
        })
    }

    func testNavigatesSelectedSplitBookmarkPaneToItsStoredURL() throws {
        let state = try makeState()
        let bookmark = try createBookmark(
            in: state,
            guid: "split-bookmark-origin",
            url: "https://primary.example/original",
            secondaryURL: "https://secondary.example/original"
        )
        let primary = Tab(
            guid: 201,
            url: "https://primary.example/current",
            isActive: true,
            index: 0,
            webContentView: BookmarkOriginTestWebContentWrapper(
                urlString: "https://primary.example/current"
            )
        )
        let secondaryWrapper = BookmarkOriginTestWebContentWrapper(
            urlString: "https://other.example/current"
        )
        let secondary = Tab(
            guid: 202,
            url: "https://other.example/current",
            isActive: false,
            index: 1,
            webContentView: secondaryWrapper
        )
        let split = SplitGroup(
            id: "bookmark-split",
            primaryTabId: primary.guid,
            secondaryTabId: secondary.guid,
            layout: .vertical,
            ratio: 0.5
        )
        state.tabs = [primary, secondary]
        state.splits = [split]
        state.splitBookmarkBindings[bookmark.guid] = split.id
        state.syncSplitBookmarkOpenedState(bookmarkGuid: bookmark.guid)

        state.navigateBookmarkTabToOriginalURL(secondary, bookmark: bookmark)

        XCTAssertTrue(waitUntil {
            secondaryWrapper.navigatedURLs == ["https://secondary.example/original"]
        })
        XCTAssertEqual(secondaryWrapper.customValues.first, "")
        XCTAssertTrue(waitUntil {
            secondaryWrapper.customValues.count == 2
        })
        XCTAssertEqual(secondaryWrapper.customValues.last, "")
    }

    private func makeState() throws -> BookmarkOriginRecordingBrowserState {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        let store = LocalStore(
            account: Account(userID: UUID().uuidString),
            storeDirectoryURL: directory
        )
        return BookmarkOriginRecordingBrowserState(
            windowId: 7,
            localStore: store,
            profileId: "Default"
        )
    }

    private func createBookmark(
        in state: BrowserState,
        guid: String,
        url: String,
        secondaryURL: String? = nil
    ) throws -> Bookmark {
        state.localStore.createBookmark(
            url: url,
            title: "Bookmark",
            profileId: state.profileId,
            parentId: nil,
            guid: guid,
            spaceId: state.spaceId,
            secondaryUrl: secondaryURL
        )
        XCTAssertTrue(waitUntil {
            state.bookmarkManager.bookmark(withGuid: guid) != nil
        })
        return try XCTUnwrap(state.bookmarkManager.bookmark(withGuid: guid))
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
        return false
    }
}

private final class BookmarkOriginRecordingBrowserState: BrowserState {
    struct CreateTabRequest: Equatable {
        let url: String?
        let customGuid: String?
        let focusAfterCreate: Bool
    }

    private(set) var createTabRequests: [CreateTabRequest] = []
    var onCreateTab: ((String?) -> Void)?

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
        onCreateTab?(url)
    }
}

private final class BookmarkOriginTestWebContentWrapper: NSObject, WebContentWrapper {
    @objc dynamic weak var nativeView: NSView?
    @objc dynamic var isLoading = false
    @objc dynamic var isDiscarded = false
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

    private(set) var navigatedURLs: [String] = []
    private(set) var customValues: [String] = []
    private let onNavigate: ((String) -> Void)?

    init(urlString: String?, onNavigate: ((String) -> Void)? = nil) {
        self.urlString = urlString
        self.onNavigate = onNavigate
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
        onNavigate?(urlString)
    }
    func setAsActiveTab() {}
    func moveSelf(to newIndex: Int, selectAfterMove: Bool) {}
    func moveSelf(toNewWindow activateNewWindow: Bool) {}
    func moveSelf(toWindow targetWindowId: Int64, at insertIndex: Int) {}
    func moveSelf(
        toWindow targetWindowId: Int64,
        andAddToGroupTokenHex targetGroupTokenHex: String,
        beforeTabId anchorTabId: Int64
    ) {}
    func moveSelf(
        toWindow targetWindowId: Int64,
        andAddToGroupTokenHex targetGroupTokenHex: String,
        afterTabId anchorTabId: Int64
    ) {}
    func moveSplit(toNewWindow activateNewWindow: Bool) {}
    func moveSplit(toWindow targetWindowId: Int64, at insertIndex: Int) {}
    func updateTabCustomValue(_ customValue: String) {
        customValues.append(customValue)
    }
    func focus() {}
    func restoreFocus() {}
    func updateSecurityState(_ securityState: [AnyHashable: Any]) {}
    func updateIsPeekSurface(_ isPeekSurface: Bool) {}
    func setAudioMuted(_ muted: Bool) {}
    func muteAudio() {}
    func unmuteAudio() {}
}

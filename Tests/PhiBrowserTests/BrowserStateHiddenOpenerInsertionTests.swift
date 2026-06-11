// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

@MainActor
final class BrowserStateHiddenOpenerInsertionTests: XCTestCase {
    private var tempDirectories: [URL] = []

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

    private func seedNormalTabs(_ state: BrowserState) {
        state.tabs = [
            Tab(guid: 1, url: "https://a.example", isActive: false, index: 0),
            Tab(guid: 2, url: "https://b.example", isActive: false, index: 1),
            Tab(guid: 3, url: "https://c.example", isActive: false, index: 2),
        ]
        state.updateNormalTabs()
    }

    func testNewTabsFromHiddenPinnedOpenerStayAtStartOfNormalTabs() throws {
        let state = try makeState()
        seedNormalTabs(state)

        let pinnedRecord = Tab(guid: 9, url: "https://p.example", isActive: true, index: 3, customGuid: "pinned-p")
        pinnedRecord.isOpenned = true
        state.pinnedTabs = [pinnedRecord]

        let pinnedLiveTab = Tab(guid: 9, url: "https://p.example", isActive: true, index: 3, customGuid: "pinned-p")
        pinnedLiveTab.isPinned = true
        state.tabs.append(pinnedLiveTab)

        state.handleNewTabFromChromium(
            Tab(guid: 10, url: "https://d.example", isActive: true, index: 4),
            context: NativeTabCreationContext(
                isActiveAtCreation: true,
                creationKind: .linkForeground,
                openerTabId: 9,
                insertAfterTabId: 3,
                sourceTabId: 9
            )
        )
        state.handleNewTabFromChromium(
            Tab(guid: 11, url: "https://e.example", isActive: true, index: 5),
            context: NativeTabCreationContext(
                isActiveAtCreation: true,
                creationKind: .linkForeground,
                openerTabId: 9,
                insertAfterTabId: 3,
                sourceTabId: 9
            )
        )

        XCTAssertEqual(state.normalTabs.map(\.guid), [10, 11, 1, 2, 3])
    }

    func testNewTabFromHiddenBookmarkOpenerUsesPinnedStyleStartInsertion() throws {
        let state = try makeState()
        seedNormalTabs(state)

        let bookmark = Bookmark(guid: "bookmark-p",
                                title: "Bookmark P",
                                url: "https://p.example")
        bookmark.isOpened = true
        state.bookmarkManager.rootFolder.addChild(bookmark)

        let bookmarkLiveTab = Tab(guid: 9, url: "https://p.example", isActive: true, index: 3, customGuid: bookmark.guid)
        state.tabs.append(bookmarkLiveTab)

        state.handleNewTabFromChromium(
            Tab(guid: 10, url: "https://d.example", isActive: true, index: 4),
            context: NativeTabCreationContext(
                isActiveAtCreation: true,
                creationKind: .linkForeground,
                openerTabId: 9,
                insertAfterTabId: 3,
                sourceTabId: 9
            )
        )

        XCTAssertEqual(state.normalTabs.map(\.guid), [10, 1, 2, 3])
    }
}

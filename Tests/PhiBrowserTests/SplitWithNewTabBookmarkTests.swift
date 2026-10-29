// Copyright 2026 Phinomenon Inc.
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

@MainActor
final class SplitWithNewTabBookmarkTests: XCTestCase {
    private var directory: URL?
    private var store: LocalStore?
    private var savedPreferences: [String: Any] = [:]
    private let preferenceKeys = [
        PhiPreferences.GeneralSettings.layoutModeKey,
        PhiPreferences.GeneralSettings.openNewTabPageOnCmdT.rawValue,
    ]

    override func setUpWithError() throws {
        for key in preferenceKeys {
            savedPreferences[key] = UserDefaults.standard.object(forKey: key)
        }
        PhiPreferences.GeneralSettings.saveLayoutMode(.performance)
    }

    override func tearDown() async throws {
        for key in preferenceKeys {
            if let value = savedPreferences[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        savedPreferences.removeAll()
        try await store?.closeForAccountDirectoryRemoval()
        store = nil
        if let directory { try FileManager.default.removeItem(at: directory) }
        directory = nil
        try await super.tearDown()
    }

    private func makeFixture() throws -> (BrowserState, Tab, Bookmark) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        let store = LocalStore(account: Account(userID: UUID().uuidString), storeDirectoryURL: directory)
        self.store = store
        // No Chromium Browser exists for this ID; bridge requests cannot affect real tabs.
        let state = BrowserState(windowId: -982631, localStore: store, profileId: "Default")
        let bookmark = Bookmark(guid: "split-source-bookmark", title: "Source", url: "https://source.example")
        bookmark.isOpened = true
        state.bookmarkManager.rootFolder.addChild(bookmark)
        let source = Tab(guid: 100, url: bookmark.url, isActive: true, index: 0, customGuid: bookmark.guid)
        state.tabs = [source]
        state.focuseTab(source)
        state.updateNormalTabs()
        XCTAssertTrue(state.normalTabs.isEmpty, "The fixture must start with a hidden bookmark-bound tab")
        return (state, source, bookmark)
    }

    private func assertSourceJoinsVisiblePair(_ state: BrowserState, _ source: Tab, _ bookmark: Bookmark,
                                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(source.guidInLocalDB, file: file, line: line)
        XCTAssertFalse(bookmark.isOpened, file: file, line: line)
        XCTAssertTrue(state.bookmarkManager.getAllBookmarks().contains { $0 === bookmark },
                      "The saved bookmark must remain after its live tab is unbound", file: file, line: line)
        // Simulate the arriving pane and split notification independently of Chromium.
        let partner = Tab(guid: 101, url: "https://partner.example", isActive: false, index: 1)
        state.tabs.append(partner)
        state.updateNormalTabs()
        state.handleSplitCreated(splitId: "bookmark-source-split", primaryTabId: source.guid,
                                 secondaryTabId: partner.guid, layout: .vertical, ratio: 0.5)
        XCTAssertEqual(state.normalTabs.map(\.guid), [source.guid, partner.guid], file: file, line: line)
        XCTAssertNotNil(state.splitPairPosition(forTabId: source.guid), file: file, line: line)
        XCTAssertNotNil(state.splitPairPosition(forTabId: partner.guid), file: file, line: line)
    }

    func testNewTabPageUnbindsBookmarkSourceBeforeOpeningPane() throws {
        let (state, source, bookmark) = try makeFixture()
        UserDefaults.standard.set(true, forKey: PhiPreferences.GeneralSettings.openNewTabPageOnCmdT.rawValue)

        XCTAssertTrue(state.splitFocusedTabWithNewTab())

        assertSourceJoinsVisiblePair(state, source, bookmark)
    }

    func testSubmittingPreviewUnbindsBookmarkSource() throws {
        let (state, source, bookmark) = try makeFixture()
        UserDefaults.standard.set(false, forKey: PhiPreferences.GeneralSettings.openNewTabPageOnCmdT.rawValue)
        state.pendingSplitPreview = PendingSplitPreview(partnerTabId: source.guid)

        XCTAssertTrue(state.commitSplitPreview(url: "https://partner.example"))

        assertSourceJoinsVisiblePair(state, source, bookmark)
        XCTAssertNil(state.pendingSplitPreview)
    }

    func testCancellingPreviewPreservesBookmarkBinding() throws {
        let (state, source, bookmark) = try makeFixture()
        state.pendingSplitPreview = PendingSplitPreview(partnerTabId: source.guid)

        state.endSplitPreview()

        XCTAssertNil(state.pendingSplitPreview)
        XCTAssertEqual(source.guidInLocalDB, bookmark.guid)
        XCTAssertTrue(bookmark.isOpened)
        XCTAssertTrue(state.normalTabs.isEmpty)
    }
}

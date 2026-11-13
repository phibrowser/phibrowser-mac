// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// A split bound to a split-view bookmark is bound to it again when a
/// session restore brings the split back under the same id.
@MainActor
final class BrowserStateSplitBookmarkRestoreTests: XCTestCase {
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

    // MARK: - Saving

    func testBindingIsSavedWithTheAccountAndRemovedWhenItEndsUnderALiveSplit() throws {
        let state = try makeBoundSplit()
        XCTAssertEqual(savedBindings(of: state), ["split-1": "bookmark"])

        state.splitBookmarkBindings.removeValue(forKey: "bookmark")
        XCTAssertEqual(savedBindings(of: state), [:])
    }

    /// Quit and a closing window take the split apart before the session is
    /// saved; the binding must still be there for the next launch.
    func testBindingStaysSavedWhenItsSplitGoesAway() throws {
        let state = try makeBoundSplit()

        state.handleSplitRemoved(splitId: "split-1")

        XCTAssertEqual(state.splitBookmarkBindings, [:])
        XCTAssertEqual(savedBindings(of: state), ["split-1": "bookmark"])
    }

    // MARK: - Restoring

    func testRestoredSplitIsBoundToItsBookmarkAgain() throws {
        let (state, bookmark) = try makeStateWithSplitBookmark(guid: "restored-bookmark")
        savePreviousRunBindings(["split-1": bookmark.guid], for: state)

        restoreWindow(into: state, splitId: "split-1")

        XCTAssertEqual(state.splitBookmarkBindings, [bookmark.guid: "split-1"])
        XCTAssertEqual(state.normalTabs.map(\.guid), [50], "The panes stay behind the bookmark")
        XCTAssertTrue(bookmark.isOpened)
        XCTAssertEqual(savedBindings(of: state), ["split-1": bookmark.guid],
                       "The binding is saved again for the next launch")
    }

    func testRestoredSplitIsBoundBeforeTheBookmarkStoreDelivers() throws {
        let guid = "late-bookmark"
        let store = try makeStore()
        try saveSplitBookmark(guid: guid, in: store)
        // No run-loop turn between the window and its restore, as at a
        // launch: the store has not delivered yet.
        let state = BrowserState(windowId: 7, localStore: store, profileId: "Default")
        savePreviousRunBindings(["split-1": guid], for: state)

        restoreWindow(into: state, splitId: "split-1")
        XCTAssertFalse(state.bookmarkManager.didApplyFirstStoreDelivery)
        XCTAssertEqual(state.normalTabs.map(\.guid), [50], "The panes never show as rows")

        XCTAssertTrue(waitUntil { state.bookmarkManager.bookmark(withGuid: guid)?.isOpened == true })
        XCTAssertEqual(state.splitBookmarkBindings, [guid: "split-1"])
        XCTAssertEqual(state.normalTabs.map(\.guid), [50])
    }

    func testRestoredSplitWhoseBookmarkIsGoneStaysANormalSplit() throws {
        let state = try makeState()
        XCTAssertTrue(waitUntil { state.bookmarkManager.didApplyFirstStoreDelivery })
        savePreviousRunBindings(["split-1": "deleted-bookmark"], for: state)

        restoreWindow(into: state, splitId: "split-1")

        XCTAssertEqual(state.splitBookmarkBindings, [:])
        XCTAssertEqual(state.normalTabs.map(\.guid), [50, 51, 52])
        XCTAssertEqual(savedBindings(of: state), [:])
    }

    func testRestoredSplitIsUnboundOnceTheStoreDeliversWithoutItsBookmark() throws {
        let state = try makeState()
        savePreviousRunBindings(["split-1": "deleted-bookmark"], for: state)

        restoreWindow(into: state, splitId: "split-1")
        XCTAssertFalse(state.bookmarkManager.didApplyFirstStoreDelivery)

        XCTAssertTrue(waitUntil { state.bookmarkManager.didApplyFirstStoreDelivery })
        XCTAssertEqual(state.splitBookmarkBindings, [:])
        XCTAssertEqual(state.normalTabs.map(\.guid), [50, 51, 52])
        XCTAssertEqual(savedBindings(of: state), [:])
    }

    func testSplitRestoredInTheComfortableLayoutStaysANormalSplit() throws {
        PhiPreferences.GeneralSettings.saveLayoutMode(.comfortable)
        let (state, bookmark) = try makeStateWithSplitBookmark(guid: "comfortable-bookmark")
        XCTAssertTrue(waitUntil { state.layoutMode == .comfortable })
        savePreviousRunBindings(["split-1": bookmark.guid], for: state)

        restoreWindow(into: state, splitId: "split-1")

        XCTAssertEqual(state.splitBookmarkBindings, [:])
        XCTAssertEqual(state.normalTabs.map(\.guid), [50, 51, 52])
        XCTAssertFalse(bookmark.isOpened)
    }

    func testBindingWhoseSplitDoesNotComeBackIsNotKept() throws {
        let (state, bookmark) = try makeStateWithSplitBookmark(guid: "unrestored-bookmark")
        savePreviousRunBindings(["split-gone": bookmark.guid], for: state)

        restoreWindow(into: state, splitId: nil)

        XCTAssertEqual(state.splitBookmarkBindings, [:])
        XCTAssertFalse(bookmark.isOpened)
        XCTAssertEqual(savedBindings(of: state), [:])
    }

    func testSplitCreatedOutsideARestoreIsNotBound() throws {
        let (state, bookmark) = try makeStateWithSplitBookmark(guid: "reopened-bookmark")
        savePreviousRunBindings(["split-1": bookmark.guid], for: state)

        state.handleInsertedTabsSnapshot(windowSnapshot(splitId: "split-1"))

        XCTAssertEqual(state.splitBookmarkBindings, [:])
        XCTAssertEqual(state.normalTabs.map(\.guid), [50, 51, 52])
    }

    // MARK: - Helpers

    private func makeStore() throws -> LocalStore {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        return LocalStore(account: Account(userID: UUID().uuidString),
                          storeDirectoryURL: directory)
    }

    private func makeState() throws -> BrowserState {
        BrowserState(windowId: 7, localStore: try makeStore(), profileId: "Default")
    }

    /// Saves a split-view bookmark and waits for the row. A window made
    /// afterwards gets the bookmark in the store's first delivery, as at a
    /// launch; one that subscribes while the row is still being written can
    /// be handed a first delivery without it.
    private func saveSplitBookmark(guid: String, in store: LocalStore) throws {
        let spaceId = SpaceManager.shared.currentDefaultSpaceId
        store.createDefaultRootDir(profileId: "Default", spaceId: spaceId)
        store.createBookmark(url: "https://primary.example",
                             title: "Bookmark",
                             profileId: "Default",
                             parentId: nil,
                             guid: guid,
                             spaceId: spaceId,
                             secondaryUrl: "https://secondary.example")
        XCTAssertTrue(waitUntil { store.getTab(by: guid) != nil })
    }

    /// A window whose store has already delivered the split-view bookmark.
    private func makeStateWithSplitBookmark(guid: String) throws -> (BrowserState, Bookmark) {
        let store = try makeStore()
        try saveSplitBookmark(guid: guid, in: store)
        let state = BrowserState(windowId: 7, localStore: store, profileId: "Default")
        XCTAssertTrue(waitUntil { state.bookmarkManager.bookmark(withGuid: guid) != nil })
        return (state, try XCTUnwrap(state.bookmarkManager.bookmark(withGuid: guid)))
    }

    /// Tabs 51 and 52 as the split "split-1", bound to "bookmark".
    private func makeBoundSplit() throws -> BrowserState {
        let state = try makeState()
        state.tabs = [51, 52].map { Tab(guid: $0, url: "https://e\($0).example", isActive: false, index: $0) }
        state.handleSplitCreated(splitId: "split-1", tabIds: [51, 52],
                                 layout: .vertical, fractions: [0.5, 0.5])
        state.splitBookmarkBindings["bookmark"] = "split-1"
        return state
    }

    /// What a previous run left in the account's defaults.
    private func savePreviousRunBindings(_ bindings: [String: String], for state: BrowserState) {
        state.localStore.account.userDefaults.set(bindings,
                                                  forKey: BrowserState.savedSplitBookmarkBindingsKey)
    }

    private func savedBindings(of state: BrowserState) -> [String: String] {
        state.localStore.account.userDefaults
            .object(forKey: BrowserState.savedSplitBookmarkBindingsKey) as? [String: String] ?? [:]
    }

    private func restoreWindow(into state: BrowserState, splitId: String?) {
        state.handleRestoredWindowSnapshot(windowSnapshot(splitId: splitId))
    }

    /// Tabs 50, 51 and 52, the last two as the split `splitId` when given.
    private func windowSnapshot(splitId: String?) -> BrowserState.RestoredWindowSnapshot {
        var previousGuid: Int?
        let items = [50, 51, 52].map { guid -> (tab: Tab, context: NativeTabCreationContext) in
            let tab = Tab(guid: guid, url: "https://e\(guid).example", isActive: false, index: 0)
            let context = NativeTabCreationContext(isActiveAtCreation: false,
                                                   creationKind: .restore,
                                                   insertAfterTabId: previousGuid)
            previousGuid = guid
            return (tab, context)
        }
        return BrowserState.RestoredWindowSnapshot(
            tabs: items,
            activeTabId: 50,
            splitActions: splitId.map {
                [.created(splitId: $0, tabIds: [51, 52], layout: .vertical, fractions: [0.5, 0.5])]
            } ?? [])
    }

    /// The host app is still launching while these tests run, and one of its
    /// main-thread tasks can outlast a whole short timeout inside a single
    /// run-loop pass: the condition is read again after the deadline.
    private func waitUntil(timeout: TimeInterval = 5, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }
}

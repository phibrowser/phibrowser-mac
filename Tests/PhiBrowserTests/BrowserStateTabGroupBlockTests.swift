// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

@MainActor
final class BrowserStateTabGroupBlockTests: XCTestCase {

    // MARK: - Helpers

    private var tempDirectories: [URL] = []

    override func tearDownWithError() throws {
        let fileManager = FileManager.default
        for directory in tempDirectories {
            try? fileManager.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    private func makeTemporaryStoreDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        return directory
    }

    private func makeBrowserState(profileId: String = "Default") throws -> BrowserState {
        let directory = try makeTemporaryStoreDirectory()
        let store = LocalStore(account: Account(userID: UUID().uuidString),
                               storeDirectoryURL: directory)
        return BrowserState(windowId: 7, localStore: store, profileId: profileId)
    }

    /// Seeds `state` with the given tabs in order and groups any tab whose
    /// token is non-nil. Returns the seeded tabs in the same order so tests
    /// can grab references by index.
    @discardableResult
    private func seed(state: BrowserState,
                      tabs: [(guid: Int, url: String, token: String?)]) -> [Tab] {
        let constructed: [Tab] = tabs.map { spec in
            let tab = Tab(guid: spec.guid, url: spec.url, isActive: false, index: 0)
            return tab
        }
        state.tabs = constructed
        state.updateNormalTabs()

        // Group tabs by token, then prime each group via the same handler
        // Chromium drives so groupToken / groups stay in sync.
        let tokens = Set(tabs.compactMap { $0.token })
        for token in tokens {
            let initialIds = tabs.filter { $0.token == token }.map { $0.guid }
            state.handleTabGroupCreated(token: token,
                                        title: "",
                                        color: .blue,
                                        isCollapsed: false,
                                        initialTabIds: initialIds)
        }
        return constructed
    }

    private func waitForBackgroundWrite() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }

    // MARK: - moveNormalTabSlice

    func testMoveNormalTabSlice_movesContiguousMembersToTail_preservingMemberOrder() throws {
        let state = try makeBrowserState()
        seed(state: state, tabs: [
            (guid: 100, url: "https://n1.example", token: nil),
            (guid: 200, url: "https://a1.example", token: "A"),
            (guid: 201, url: "https://a2.example", token: "A"),
            (guid: 101, url: "https://n2.example", token: nil),
            (guid: 102, url: "https://n3.example", token: nil),
        ])

        state.moveNormalTabSlice(memberIds: [200, 201], to: 5)

        XCTAssertEqual(state.normalTabs.map { $0.guid },
                       [100, 101, 102, 200, 201])
    }

    func testMoveNormalTabSlice_movesContiguousMembersToStart_preservingMemberOrder() throws {
        let state = try makeBrowserState()
        seed(state: state, tabs: [
            (guid: 100, url: "https://n1.example", token: nil),
            (guid: 101, url: "https://n2.example", token: nil),
            (guid: 200, url: "https://a1.example", token: "A"),
            (guid: 201, url: "https://a2.example", token: "A"),
            (guid: 102, url: "https://n3.example", token: nil),
        ])

        state.moveNormalTabSlice(memberIds: [200, 201], to: 0)

        XCTAssertEqual(state.normalTabs.map { $0.guid },
                       [200, 201, 100, 101, 102])
    }

    func testMoveNormalTabSlice_dropInsideSourceRange_isNoOp() throws {
        let state = try makeBrowserState()
        seed(state: state, tabs: [
            (guid: 100, url: "https://n1.example", token: nil),
            (guid: 200, url: "https://a1.example", token: "A"),
            (guid: 201, url: "https://a2.example", token: "A"),
            (guid: 101, url: "https://n2.example", token: nil),
        ])

        let before = state.normalTabs.map { $0.guid }
        state.moveNormalTabSlice(memberIds: [200, 201], to: 2)

        XCTAssertEqual(state.normalTabs.map { $0.guid }, before)
    }

    // MARK: - moveGroupBlock

    /// `[N1, A1, A2, N2, N3]` with group A at indices 1..2.
    /// `moveGroupBlock("A", to: 5)` moves the block to the strip's tail.
    /// The toIndex is interpreted in PRE-move coords (NSOutlineView
    /// convention), and is adjusted by `-blockSize` when the block moves
    /// forward, mirroring `moveNormalTabLocally`'s `-1` adjustment.
    func testMoveGroupBlock_movesGroupAsContiguousBlock_preservingMemberOrder() throws {
        let state = try makeBrowserState()
        seed(state: state, tabs: [
            (guid: 100, url: "https://n1.example", token: nil),
            (guid: 200, url: "https://a1.example", token: "A"),
            (guid: 201, url: "https://a2.example", token: "A"),
            (guid: 101, url: "https://n2.example", token: nil),
            (guid: 102, url: "https://n3.example", token: nil),
        ])

        state.moveGroupBlock(token: "A", to: 5)

        XCTAssertEqual(state.normalTabs.map { $0.guid },
                       [100, 101, 102, 200, 201])
    }

    func testMoveGroupBlock_toStart_preservesMemberOrder() throws {
        let state = try makeBrowserState()
        seed(state: state, tabs: [
            (guid: 100, url: "https://n1.example", token: nil),
            (guid: 101, url: "https://n2.example", token: nil),
            (guid: 200, url: "https://a1.example", token: "A"),
            (guid: 201, url: "https://a2.example", token: "A"),
            (guid: 102, url: "https://n3.example", token: nil),
        ])

        state.moveGroupBlock(token: "A", to: 0)

        XCTAssertEqual(state.normalTabs.map { $0.guid },
                       [200, 201, 100, 101, 102])
    }

    func testMoveGroupBlock_blockAlreadyAtTarget_isNoOp() throws {
        let state = try makeBrowserState()
        seed(state: state, tabs: [
            (guid: 200, url: "https://a1.example", token: "A"),
            (guid: 201, url: "https://a2.example", token: "A"),
            (guid: 100, url: "https://n1.example", token: nil),
        ])

        let before = state.normalTabs.map { $0.guid }
        state.moveGroupBlock(token: "A", to: 0)
        XCTAssertEqual(state.normalTabs.map { $0.guid }, before)
    }

    func testMoveGroupBlock_unknownToken_isNoOp() throws {
        let state = try makeBrowserState()
        seed(state: state, tabs: [
            (guid: 100, url: "https://n1.example", token: nil),
            (guid: 200, url: "https://a1.example", token: "A"),
            (guid: 101, url: "https://n2.example", token: nil),
        ])

        let before = state.normalTabs.map { $0.guid }
        state.moveGroupBlock(token: "DOES_NOT_EXIST", to: 0)
        XCTAssertEqual(state.normalTabs.map { $0.guid }, before)
    }

    // MARK: - optimistic group membership

    func testApplyOptimisticGroupMembership_batchSplitJoinAtGroupFrontPreservesInsertion() throws {
        let state = try makeBrowserState()
        seed(state: state, tabs: [
            (guid: 100, url: "https://left.example", token: nil),
            (guid: 101, url: "https://right.example", token: nil),
            (guid: 200, url: "https://a1.example", token: "A"),
            (guid: 201, url: "https://a2.example", token: "A"),
        ])
        state.splits = [
            SplitGroup(id: "split-100-101",
                       tabIds: [100, 101],
                       layout: .vertical,
                       fractions: [0.5, 0.5])
        ]

        state.moveNormalTabLocally(from: 0, to: 2)
        state.applyOptimisticGroupMembership(updates: [
            (tabId: 100, newToken: "A"),
            (tabId: 101, newToken: "A"),
        ])

        XCTAssertEqual(state.normalTabs.map(\.guid), [100, 101, 200, 201])
        XCTAssertEqual(state.normalTabs.map(\.groupToken), ["A", "A", "A", "A"])
    }

    func testApplyOptimisticGroupMembership_crossGroupJoinPreservesInsertionPoint() throws {
        let state = try makeBrowserState()
        seed(state: state, tabs: [
            (guid: 200, url: "https://a1.example", token: "A"),
            (guid: 201, url: "https://a2.example", token: "A"),
            (guid: 300, url: "https://b1.example", token: "B"),
            (guid: 301, url: "https://b2.example", token: "B"),
        ])

        state.moveNormalTabLocally(from: 0, to: 2, syncChromiumOrder: false)
        state.applyOptimisticGroupMembership(updates: [
            (tabId: 200, newToken: "B"),
        ])

        XCTAssertEqual(state.normalTabs.map(\.guid), [201, 200, 300, 301])
        XCTAssertEqual(state.normalTabs.map(\.groupToken), ["A", "B", "B", "B"])
    }

    // MARK: - group-relative order sync

    func testGroupRelativeOrderSync_beforeOptimisticMembershipReturnsNil() throws {
        let state = try makeBrowserState()
        let tabs = seed(state: state, tabs: [
            (guid: 100, url: "https://joining.example", token: nil),
            (guid: 200, url: "https://g1.example", token: "A"),
        ])

        XCTAssertNil(
            state.normalTabRelativeOrderSyncMove(
                tabId: tabs[0].guid,
                withinGroupToken: "A"
            )
        )
    }

    func testGroupRelativeOrderSync_noVisibleGroupMemberDoesNotUseExternalAnchor() throws {
        let defaults = UserDefaults.standard
        let layoutKey = PhiPreferences.GeneralSettings.layoutModeKey
        let originalLayout = defaults.string(forKey: layoutKey)
        PhiPreferences.GeneralSettings.saveLayoutMode(.performance)
        defer {
            if let originalLayout {
                defaults.set(originalLayout, forKey: layoutKey)
            } else {
                defaults.removeObject(forKey: layoutKey)
            }
        }

        let state = try makeBrowserState()
        let hiddenBookmark = Bookmark(
            guid: "hidden-group-member",
            title: "Hidden Group Member",
            url: "https://hidden-member.example"
        )
        hiddenBookmark.isOpened = true
        state.bookmarkManager.rootFolder.addChild(hiddenBookmark)

        let hiddenMember = Tab(guid: 200,
                               url: "https://hidden-member.example",
                               isActive: false,
                               index: 0,
                               customGuid: hiddenBookmark.guid)
        let joining = Tab(guid: 100,
                          url: "https://joining.example",
                          isActive: false,
                          index: 1)
        let external = Tab(guid: 101,
                           url: "https://external.example",
                           isActive: false,
                           index: 2)

        state.tabs = [hiddenMember, joining, external]
        state.updateNormalTabs()
        state.handleTabGroupCreated(token: "A",
                                    title: "",
                                    color: .blue,
                                    isCollapsed: false,
                                    initialTabIds: [hiddenMember.guid])
        state.applyOptimisticGroupMembership(tabId: joining.guid,
                                             newToken: "A")

        XCTAssertEqual(state.normalTabs.map(\.guid), [joining.guid, external.guid])
        XCTAssertEqual(joining.groupToken, "A")
        XCTAssertNil(
            state.normalTabRelativeOrderSyncMove(
                tabId: joining.guid,
                withinGroupToken: "A"
            )
        )
    }

    func testGroupRelativeOrderSync_frontJoinAnchorsBeforeFirstMember() throws {
        let state = try makeBrowserState()
        let tabs = seed(state: state, tabs: [
            (guid: 100, url: "https://joining.example", token: nil),
            (guid: 200, url: "https://g1.example", token: "A"),
            (guid: 201, url: "https://g2.example", token: "A"),
            (guid: 101, url: "https://external.example", token: nil),
        ])

        state.applyOptimisticGroupMembership(tabId: tabs[0].guid,
                                             newToken: "A")

        XCTAssertEqual(
            state.normalTabRelativeOrderSyncMove(
                tabId: tabs[0].guid,
                withinGroupToken: "A"
            ),
            BrowserState.NormalTabRelativeOrderMove(
                tabId: tabs[0].guid,
                anchor: .before(tabs[1].guid)
            )
        )
    }

    func testGroupRelativeOrderSync_middleJoinAnchorsBeforeRightMember() throws {
        let state = try makeBrowserState()
        let tabs = seed(state: state, tabs: [
            (guid: 200, url: "https://g1.example", token: "A"),
            (guid: 100, url: "https://joining.example", token: nil),
            (guid: 201, url: "https://g2.example", token: "A"),
            (guid: 101, url: "https://external.example", token: nil),
        ])

        state.applyOptimisticGroupMembership(tabId: tabs[1].guid,
                                             newToken: "A")

        XCTAssertEqual(
            state.normalTabRelativeOrderSyncMove(
                tabId: tabs[1].guid,
                withinGroupToken: "A"
            ),
            BrowserState.NormalTabRelativeOrderMove(
                tabId: tabs[1].guid,
                anchor: .before(tabs[2].guid)
            )
        )
    }

    func testGroupRelativeOrderSync_tailJoinAnchorsToMemberAcrossHiddenBookmarkTab() throws {
        let defaults = UserDefaults.standard
        let layoutKey = PhiPreferences.GeneralSettings.layoutModeKey
        let originalLayout = defaults.string(forKey: layoutKey)
        PhiPreferences.GeneralSettings.saveLayoutMode(.performance)
        defer {
            if let originalLayout {
                defaults.set(originalLayout, forKey: layoutKey)
            } else {
                defaults.removeObject(forKey: layoutKey)
            }
        }

        let state = try makeBrowserState()
        let hiddenBookmark = Bookmark(
            guid: "hidden-bookmark",
            title: "Hidden Bookmark",
            url: "https://hidden.example"
        )
        hiddenBookmark.isOpened = true
        state.bookmarkManager.rootFolder.addChild(hiddenBookmark)

        let g1 = Tab(guid: 200,
                     url: "https://g1.example",
                     isActive: false,
                     index: 0)
        let g2 = Tab(guid: 201,
                     url: "https://g2.example",
                     isActive: false,
                     index: 1)
        let hidden = Tab(guid: 900,
                         url: "https://hidden.example",
                         isActive: false,
                         index: 2,
                         customGuid: hiddenBookmark.guid)
        let joining = Tab(guid: 100,
                          url: "https://joining.example",
                          isActive: false,
                          index: 3)
        let external = Tab(guid: 101,
                           url: "https://external.example",
                           isActive: false,
                           index: 4)

        state.tabs = [g1, g2, hidden, joining, external]
        state.updateNormalTabs()
        state.handleTabGroupCreated(token: "A",
                                    title: "",
                                    color: .blue,
                                    isCollapsed: false,
                                    initialTabIds: [g1.guid, g2.guid])
        state.applyOptimisticGroupMembership(tabId: joining.guid,
                                             newToken: "A")

        XCTAssertEqual(state.tabs.sorted { $0.index < $1.index }.map(\.guid),
                       [200, 201, 900, 100, 101])
        XCTAssertEqual(state.normalTabs.map(\.guid),
                       [200, 201, 100, 101])
        XCTAssertEqual(
            state.normalTabRelativeOrderSyncMove(
                tabId: joining.guid,
                withinGroupToken: "A"
            ),
            BrowserState.NormalTabRelativeOrderMove(
                tabId: joining.guid,
                anchor: .after(g2.guid)
            )
        )
    }

    // MARK: - convertGroupToBookmarks

    func testConvertGroupToBookmarks_createsFolderAndRewiresOpenTabsToChildBookmarks() throws {
        let state = try makeBrowserState()
        let tabs = seed(state: state, tabs: [
            (guid: 100, url: "https://n1.example", token: nil),
            (guid: 200, url: "https://a1.example", token: "A"),
            (guid: 201, url: "https://a2.example", token: "A"),
            (guid: 101, url: "https://n2.example", token: nil),
        ])
        let a1 = tabs[1]
        let a2 = tabs[2]
        state.localStore.createBookmark(url: "https://existing.example",
                                        title: "Existing",
                                        profileId: state.profileId,
                                        parentId: nil)
        waitForBackgroundWrite()

        state.convertGroupToBookmarks(token: "A", parentFolder: nil, at: 0)

        XCTAssertNil(a1.groupToken)
        XCTAssertNil(a2.groupToken)
        XCTAssertNil(state.groups["A"])
        XCTAssertTrue(state.tabs.contains { $0.guid == 200 })
        XCTAssertTrue(state.tabs.contains { $0.guid == 201 })
        guard let a1BookmarkGuid = a1.guidInLocalDB,
              let a2BookmarkGuid = a2.guidInLocalDB else {
            XCTFail("Expected open tabs to be associated with new bookmark records")
            return
        }

        waitForBackgroundWrite()
        let rootItems = state.localStore.fetchBookmarks(parentId: nil as String?,
                                                        profileId: state.profileId)
        XCTAssertEqual(rootItems.first?.title, "Blue · 2 tabs")
        XCTAssertEqual(rootItems.last?.title, "Existing")

        guard let folder = rootItems.first else {
            XCTFail("Expected converted group folder at root index 0")
            return
        }
        let children = state.localStore.fetchBookmarks(parentId: folder.guid,
                                                       profileId: state.profileId)
        XCTAssertEqual(children.map(\.guid), [a1BookmarkGuid, a2BookmarkGuid])
        XCTAssertEqual(children.map { $0.url.absoluteString },
                       ["https://a1.example/", "https://a2.example/"])
    }

    /// A split in the group is saved as one split-view bookmark bound to the
    /// live split, so its panes stay together instead of becoming separate
    /// bookmarks.
    func testConvertGroupToBookmarks_savesASplitAsOneSplitBookmark() throws {
        let state = try makeBrowserState()
        let tabs = seed(state: state, tabs: [
            (guid: 200, url: "https://a1.example", token: "A"),
            (guid: 201, url: "https://left.example", token: "A"),
            (guid: 202, url: "https://right.example", token: "A"),
        ])
        state.handleSplitCreated(splitId: "split", tabIds: [201, 202],
                                 layout: .horizontal, fractions: [0.5, 0.5])

        state.convertGroupToBookmarks(token: "A", parentFolder: nil, at: 0)

        XCTAssertNil(tabs[1].groupToken)
        XCTAssertNil(tabs[2].groupToken)
        XCTAssertNil(tabs[1].guidInLocalDB)
        XCTAssertNil(tabs[2].guidInLocalDB)
        XCTAssertNotNil(state.splitGroup(forId: "split"))
        let boundGuid = try XCTUnwrap(state.splitBookmarkBindings.first { $0.value == "split" }?.key)

        waitForBackgroundWrite()
        let folder = try XCTUnwrap(state.localStore.fetchBookmarks(parentId: nil as String?,
                                                                    profileId: state.profileId).first)
        let children = state.localStore.fetchBookmarks(parentId: folder.guid, profileId: state.profileId)
            .sorted { $0.index < $1.index }
        XCTAssertEqual(children.count, 2)
        XCTAssertEqual(children.map(\.url.absoluteString), ["https://a1.example/", "https://left.example/"])
        XCTAssertEqual(children[1].guid, boundGuid)
        XCTAssertEqual(children[1].secondaryUrl?.absoluteString, "https://right.example/")
        XCTAssertEqual(children[1].layout, SplitLayout.horizontal.rawValue)
    }

    /// Members hit `moveNormalTab(toBookmark:index:)` in normalTabs order
    /// with monotonically increasing `index`, so the persisted bookmarks
    /// keep the pre-dissolution member order.
    func testConvertGroupToBookmarks_preservesMemberOrderInBookmarks() throws {
        let state = try makeBrowserState()
        seed(state: state, tabs: [
            (guid: 200, url: "https://a1.example", token: "A"),
            (guid: 201, url: "https://a2.example", token: "A"),
            (guid: 202, url: "https://a3.example", token: "A"),
        ])

        state.convertGroupToBookmarks(token: "A", parentFolder: nil, at: 0)

        waitForBackgroundWrite()
        let stored = state.localStore.fetchBookmarks(parentId: nil as String?,
                                                     profileId: state.profileId)
        // Sort by the persisted sibling index since fetchBookmarks isn't
        // contractually ordered.
        let ordered = stored.sorted { $0.index < $1.index }
        let urls = ordered.map { $0.url.absoluteString }
        let aOnly = urls.filter { $0.contains("example") }
        XCTAssertEqual(aOnly.count, 3, "expected 3 bookmarks; got \(urls)")
        let firstA1 = aOnly.firstIndex { $0.contains("a1.example") }
        let firstA2 = aOnly.firstIndex { $0.contains("a2.example") }
        let firstA3 = aOnly.firstIndex { $0.contains("a3.example") }
        XCTAssertNotNil(firstA1)
        XCTAssertNotNil(firstA2)
        XCTAssertNotNil(firstA3)
        if let i1 = firstA1, let i2 = firstA2, let i3 = firstA3 {
            XCTAssertLessThan(i1, i2, "a1 should precede a2")
            XCTAssertLessThan(i2, i3, "a2 should precede a3")
        }
    }
}

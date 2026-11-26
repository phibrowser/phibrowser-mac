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
        state.handleSplitCreated(splitId: "bookmark-source-split", tabIds: [source.guid, partner.guid],
                                 layout: .vertical, fractions: [0.5, 0.5])
        XCTAssertEqual(state.normalTabs.map(\.guid), [source.guid, partner.guid], file: file, line: line)
        XCTAssertEqual(state.splitPanePosition(forTabId: source.guid), .first, file: file, line: line)
        XCTAssertEqual(state.splitPanePosition(forTabId: partner.guid), .last, file: file, line: line)
    }

    func testRemoveSplitCommandRequiresAnUnpinnedLiveSplitAndKeepsTabs() throws {
        let (state, source, _) = try makeFixture()
        XCTAssertFalse(state.canPerformOmniboxCommand(.removeSplitView))
        let partner = Tab(guid: 101, url: "https://partner.example", isActive: false, index: 1)
        state.tabs.append(partner)
        state.splits = [SplitGroup(id: "command-split", tabIds: [source.guid, partner.guid],
                                   layout: .vertical, fractions: [0.5, 0.5])]
        XCTAssertTrue(state.canPerformOmniboxCommand(.removeSplitView))
        state.focusingTab = partner
        XCTAssertTrue(state.canPerformOmniboxCommand(.removeSplitView))
        state.splits[0].isPinned = true
        XCTAssertFalse(state.canPerformOmniboxCommand(.removeSplitView))
        state.splits[0].isPinned = false

        state.handleSplitRemoved(splitId: "command-split")

        XCTAssertEqual(state.tabs.map(\.guid), [source.guid, partner.guid])
        XCTAssertEqual(state.focusingTab?.guid, partner.guid)
        XCTAssertFalse(state.canPerformOmniboxCommand(.removeSplitView))
    }

    func testAddSplitCommandsFollowFocusedSplitLayoutAndPaneLimit() throws {
        let (state, source, _) = try makeFixture()
        let sideBySide: [OmniboxCommand] = [.newSplitView, .addLeftSplit]
        let stacked: [OmniboxCommand] = [.addVerticalSplitView, .addTopSplit]
        XCTAssertTrue((sideBySide + stacked).allSatisfy { state.canPerformOmniboxCommand($0) })

        state.splits = [SplitGroup(id: "command-split", tabIds: [source.guid, 101],
                                   layout: .vertical, fractions: [0.5, 0.5])]
        XCTAssertTrue(sideBySide.allSatisfy { state.canPerformOmniboxCommand($0) })
        XCTAssertFalse(stacked.contains { state.canPerformOmniboxCommand($0) })

        state.splits[0].layout = .horizontal
        XCTAssertFalse(sideBySide.contains { state.canPerformOmniboxCommand($0) })
        XCTAssertTrue(stacked.allSatisfy { state.canPerformOmniboxCommand($0) })

        state.splits = [SplitGroup(id: "command-split", tabIds: [source.guid, 101, 102, 103],
                                   layout: .horizontal, fractions: [0.25, 0.25, 0.25, 0.25])]
        XCTAssertFalse((sideBySide + stacked).contains { state.canPerformOmniboxCommand($0) })
    }

    func testSplitSnapshotOffersRemoveCommandWithoutNativeEntities() throws {
        let (state, source, _) = try makeFixture()
        state.splits = [SplitGroup(id: "command-split", tabIds: [source.guid, 101],
                                   layout: .vertical, fractions: [0.5, 0.5])]
        let snapshot = OmniboxNativeSearchSnapshot(
            mutationEpoch: "1", pinScope: "test",
            bookmarks: .init(status: .complete, entities: [
                .init(kind: .bookmark, entityID: "other", title: "Other", url: "https://other.example")
            ]), pins: .init(status: .complete, entities: []))
        let result = try state.decorateOmniboxSnapshot(
            snapshot, ticket: OmniboxQueryTicket(deadlineUptimeNanoseconds: UInt64.max))
        XCTAssertTrue(result.commands?.entities.contains { $0.commandID == "removeSplitView" } == true)
        XCTAssertEqual(result.bookmarks.status, .unavailable)
        XCTAssertTrue(result.bookmarks.entities.isEmpty)
        XCTAssertEqual(result.pins.status, .unavailable)
        XCTAssertNil(result.learning)
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

    func testDirectionalPreviewSubmissionPreservesLayoutAndSlot() throws {
        let (state, source, _) = try makeFixture()
        let configurations: [(SplitLayout, SplitSlot)] = [
            (.vertical, .right), (.vertical, .left),
            (.horizontal, .right), (.horizontal, .left),
        ]
        for (layout, slot) in configurations {
            state.pendingSplitPartnerByCustomGuid.removeAll()
            state.pendingSplitPreview = PendingSplitPreview(
                partnerTabId: source.guid, newTabSlot: slot, layout: layout)

            XCTAssertTrue(state.commitSplitPreview(url: "https://partner.example"))

            let pending = try XCTUnwrap(state.pendingSplitPartnerByCustomGuid.values.first)
            guard case let .newPair(partnerTabId, newTabSlot, pendingLayout) = pending.target else {
                return XCTFail("Expected a new pair")
            }
            XCTAssertEqual(partnerTabId, source.guid)
            XCTAssertEqual(newTabSlot, slot)
            XCTAssertEqual(pendingLayout, layout)
            XCTAssertEqual(state.pendingSplitPreview?.isCommitted, true)
            state.endSplitPreview()
            XCTAssertNotNil(state.pendingSplitPreview, "Committed previews stay until the split arrives")
        }
    }

    func testDirectionalNewTabPagePreservesLayoutAndSlot() throws {
        let (state, source, _) = try makeFixture()
        UserDefaults.standard.set(true, forKey: PhiPreferences.GeneralSettings.openNewTabPageOnCmdT.rawValue)
        let configurations: [(SplitLayout, SplitSlot)] = [
            (.vertical, .left), (.horizontal, .right), (.horizontal, .left),
        ]
        for (layout, slot) in configurations {
            state.pendingSplitPartnerByCustomGuid.removeAll()
            XCTAssertTrue(state.splitFocusedTabWithNewTab(newTabSlot: slot, layout: layout))
            let pending = try XCTUnwrap(state.pendingSplitPartnerByCustomGuid.values.first)
            guard case let .newPair(partnerTabId, newTabSlot, pendingLayout) = pending.target else {
                return XCTFail("Expected a new pair")
            }
            XCTAssertEqual(partnerTabId, source.guid)
            XCTAssertEqual(newTabSlot, slot)
            XCTAssertEqual(pendingLayout, layout)
            XCTAssertNil(state.pendingSplitPreview)
        }
    }

    func testFocusedPaneGetsNewPaneBeforeOrAfterItBySlot() throws {
        let (state, source, _) = try makeFixture()
        UserDefaults.standard.set(true, forKey: PhiPreferences.GeneralSettings.openNewTabPageOnCmdT.rawValue)
        state.splits = [SplitGroup(id: "slot-split", tabIds: [99, source.guid, 101],
                                   layout: .vertical, fractions: [0.4, 0.3, 0.3])]
        for (newTabSlot, expectedSlot) in [(SplitSlot.left, 1), (SplitSlot.right, 2)] {
            state.pendingSplitPartnerByCustomGuid.removeAll()
            XCTAssertTrue(state.splitFocusedTabWithNewTab(newTabSlot: newTabSlot))
            let pending = try XCTUnwrap(state.pendingSplitPartnerByCustomGuid.values.first)
            guard case let .existingSplit(splitId, slot) = pending.target else {
                return XCTFail("Expected the new pane to join the split")
            }
            XCTAssertEqual(splitId, "slot-split")
            XCTAssertEqual(slot, expectedSlot)
        }
    }

    func testSubmittingJoinPreviewAddsPaneToSplitAndEndsOnArrival() throws {
        let (state, source, _) = try makeFixture()
        state.splits = [SplitGroup(id: "join-split", tabIds: [99, source.guid, 101],
                                   layout: .vertical, fractions: [0.4, 0.3, 0.3])]
        let join = SplitJoin(splitId: "join-split", slot: 1)
        state.pendingSplitPreview = PendingSplitPreview(partnerTabId: source.guid, joining: join)

        XCTAssertTrue(state.commitSplitPreview(url: "https://joining.example"))

        let pending = try XCTUnwrap(state.pendingSplitPartnerByCustomGuid.values.first)
        guard case let .existingSplit(splitId, slot) = pending.target else {
            return XCTFail("Expected the new pane to join the split")
        }
        XCTAssertEqual(splitId, join.splitId)
        XCTAssertEqual(slot, join.slot)
        XCTAssertEqual(state.pendingSplitPreview?.isCommitted, true)

        state.handleSplitContentsChanged(splitId: "join-split", tabIds: [99, 102, source.guid, 101])
        XCTAssertNil(state.pendingSplitPreview)
    }

    func testJoinPreviewEndsWhenTargetSplitChangesBeforeSubmission() throws {
        let (state, source, _) = try makeFixture()
        let join = SplitJoin(splitId: "join-split", slot: 1)
        state.splits = [SplitGroup(id: "join-split", tabIds: [99, source.guid, 101],
                                   layout: .vertical, fractions: [0.4, 0.3, 0.3])]
        state.pendingSplitPreview = PendingSplitPreview(partnerTabId: source.guid, joining: join)

        state.handleSplitContentsChanged(splitId: "join-split", tabIds: [source.guid, 101])
        XCTAssertNil(state.pendingSplitPreview)

        state.pendingSplitPreview = PendingSplitPreview(partnerTabId: source.guid, joining: join)
        state.handleSplitRemoved(splitId: "join-split")
        XCTAssertNil(state.pendingSplitPreview)

        state.splits = [SplitGroup(id: "join-split", tabIds: [99, source.guid, 101],
                                   layout: .vertical, fractions: [0.4, 0.3, 0.3])]
        let committed = PendingSplitPreview(partnerTabId: source.guid, joining: join, isCommitted: true)
        state.pendingSplitPreview = committed
        state.handleSplitContentsChanged(splitId: "join-split", tabIds: [source.guid, 101])
        XCTAssertEqual(state.pendingSplitPreview, committed)
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

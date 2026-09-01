// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

@MainActor
final class SplitChatBindingTests: XCTestCase {
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

    private func seed(_ state: BrowserState, guids: [Int]) {
        state.tabs = guids.map { Tab(guid: $0, url: "https://e\($0).example", isActive: false, index: 0) }
        state.updateNormalTabs()
    }

    private func makeChatTab(guid: Int) -> Tab {
        Tab(guid: guid, url: "chrome-extension://x/index.html", isActive: false, index: 0)
    }

    private func splitGroup(_ p: Int, _ s: Int) -> SplitGroup {
        SplitGroup(id: "split-\(p)-\(s)", primaryTabId: p, secondaryTabId: s,
                   layout: .vertical, ratio: 0.5)
    }

    func testResolverOutsideSplitReturnsOwnIdentifier() throws {
        let state = try makeState()
        seed(state, guids: [1, 2])
        XCTAssertEqual(state.chatIdentifier(for: state.tabs[0]),
                       state.getTabIdentifier(for: state.tabs[0]))
    }

    func testResolverWhenOnlyOnePaneHasChatReturnsThatPane() throws {
        let state = try makeState()
        seed(state, guids: [1, 2])
        state.splits = [splitGroup(1, 2)]
        let id1 = state.getTabIdentifier(for: state.tabs[0])
        state.aiChatTabs[id1] = makeChatTab(guid: 100)

        XCTAssertEqual(state.chatIdentifier(for: state.tabs[0]), id1)
        XCTAssertEqual(state.chatIdentifier(for: state.tabs[1]), id1)
    }

    func testResolverWhenNoPaneHasChatReturnsForegroundPane() throws {
        let state = try makeState()
        seed(state, guids: [1, 2])
        state.splits = [splitGroup(1, 2)]
        state.focuseTab(state.tabs[1])

        let id2 = state.getTabIdentifier(for: state.tabs[1])
        XCTAssertEqual(state.chatIdentifier(for: state.tabs[0]), id2)
        XCTAssertEqual(state.chatIdentifier(for: state.tabs[1]), id2)
    }

    func testReconcileBothHaveChatKeepsForegroundClosesOther() throws {
        let state = try makeState()
        seed(state, guids: [1, 2])
        let id1 = state.getTabIdentifier(for: state.tabs[0])
        let id2 = state.getTabIdentifier(for: state.tabs[1])
        state.aiChatTabs[id1] = makeChatTab(guid: 100)
        state.aiChatTabs[id2] = makeChatTab(guid: 200)
        let group = splitGroup(1, 2)
        state.splits = [group]
        state.focuseTab(state.tabs[1]) // secondary is foreground

        state.reconcileSplitChatBinding(group)

        XCTAssertNil(state.aiChatTabs[id1])              // loser closed
        XCTAssertNotNil(state.aiChatTabs[id2])           // foreground kept
        XCTAssertEqual(state.chatIdentifier(for: state.tabs[0]), id2)
    }

    func testReconcileSinglePaneChatIsNoop() throws {
        let state = try makeState()
        seed(state, guids: [1, 2])
        let id1 = state.getTabIdentifier(for: state.tabs[0])
        state.aiChatTabs[id1] = makeChatTab(guid: 100)
        let group = splitGroup(1, 2)
        state.splits = [group]

        state.reconcileSplitChatBinding(group)

        XCTAssertNotNil(state.aiChatTabs[id1])
    }

    func testMigrateHelperMovesChatKey() throws {
        let state = try makeState()
        seed(state, guids: [1, 2])
        let id1 = state.getTabIdentifier(for: state.tabs[0])
        let id2 = state.getTabIdentifier(for: state.tabs[1])
        let chat = makeChatTab(guid: 100)
        state.aiChatTabs[id1] = chat

        state.migrateAIChatTab(fromIdentifier: id1, toIdentifier: id2)

        XCTAssertNil(state.aiChatTabs[id1])
        XCTAssertTrue(state.aiChatTabs[id2] === chat)
    }

    func testAIOutputRejectsAWindowMismatchBeforeAdvancingSequence() throws {
        let state = try makeState()
        seed(state, guids: [1])
        let store = SidecarAIOutputStateStore()

        XCTAssertFalse(store.apply(SidecarAIOutputPayload(
            tabId: 1,
            windowId: 8,
            active: true,
            phase: .streaming,
            seq: 1
        ), in: state))
        XCTAssertFalse(state.tabs[0].isPairedChatGenerating)

        XCTAssertTrue(store.apply(SidecarAIOutputPayload(
            tabId: 1,
            windowId: 7,
            active: true,
            phase: .streaming,
            seq: 1
        ), in: state))
        XCTAssertTrue(state.tabs[0].isPairedChatGenerating)
    }

    func testDissolvingSplitRestoresEachPanesOwnAIOutputState() throws {
        let state = try makeState()
        seed(state, guids: [1, 2])
        let group = splitGroup(1, 2)
        state.splits = [group]
        let store = SidecarAIOutputStateStore()

        XCTAssertTrue(store.apply(SidecarAIOutputPayload(
            tabId: 1,
            windowId: 7,
            active: true,
            phase: .streaming,
            seq: 1
        ), in: state))
        XCTAssertTrue(state.tabs[0].isPairedChatGenerating)
        XCTAssertTrue(state.tabs[1].isPairedChatGenerating)

        store.splitDidDissolve(group, in: state)

        XCTAssertTrue(state.tabs[0].isPairedChatGenerating)
        XCTAssertFalse(state.tabs[1].isPairedChatGenerating)
        XCTAssertFalse(state.tabs[1].hasPairedChat)
    }

    func testClosingContentTabClearsLiveAndPinnedAIOutputProjections() throws {
        let state = try makeState()
        seed(state, guids: [1])
        let pinnedRepresentation = Tab(
            guid: 1,
            url: "https://e1.example",
            isActive: false,
            index: 0
        )
        state.pinnedTabs = [pinnedRepresentation]
        let store = SidecarAIOutputStateStore()
        XCTAssertTrue(store.apply(SidecarAIOutputPayload(
            tabId: 1,
            windowId: 7,
            active: true,
            phase: .streaming,
            seq: 1
        ), in: state))

        store.contentTabDidClose(1, in: state)

        XCTAssertFalse(state.tabs[0].isPairedChatGenerating)
        XCTAssertFalse(pinnedRepresentation.isPairedChatGenerating)
        XCTAssertTrue(store.apply(SidecarAIOutputPayload(
            tabId: 1,
            windowId: 7,
            active: true,
            phase: .submitted,
            seq: 1
        ), in: state))
    }

    func testClosingSplitChatOwnerMigratesAIOutputStateToSurvivor() throws {
        let state = try makeState()
        seed(state, guids: [1, 2])
        state.splits = [splitGroup(1, 2)]
        let store = SidecarAIOutputStateStore()
        XCTAssertTrue(store.apply(SidecarAIOutputPayload(
            tabId: 1,
            windowId: 7,
            active: true,
            phase: .streaming,
            seq: 1
        ), in: state))

        store.contentTabDidClose(1, in: state, migratingConversationTo: 2)
        XCTAssertFalse(state.tabs[0].isPairedChatGenerating)
        XCTAssertTrue(state.tabs[1].isPairedChatGenerating)

        XCTAssertTrue(store.apply(SidecarAIOutputPayload(
            tabId: 2,
            windowId: 7,
            active: false,
            phase: .idle,
            seq: 2
        ), in: state))
        XCTAssertTrue(state.tabs[1].hasPairedChat)
        XCTAssertFalse(state.tabs[1].isPairedChatGenerating)
    }

    func testSidebarOpenTriggerIsConsumedOnce() throws {
        let state = try makeState()

        XCTAssertEqual(state.consumeAIChatSidebarOpenTrigger(), .restore)

        state.prepareAIChatSidebarOpen(trigger: .shortcut)

        XCTAssertEqual(state.consumeAIChatSidebarOpenTrigger(), .shortcut)
        XCTAssertEqual(state.consumeAIChatSidebarOpenTrigger(), .restore)
    }

    func testSidebarMetricsSessionOnlyTracksVisibilityEdges() {
        var session = AIChatSidebarMetricsSession()

        XCTAssertEqual(session.update(isExpanded: true, uptime: 10), .opened)
        XCTAssertNil(session.update(isExpanded: true, uptime: 20))
        XCTAssertEqual(
            session.update(isExpanded: false, uptime: 35),
            .closed(durationSeconds: 25)
        )
        XCTAssertNil(session.update(isExpanded: false, uptime: 40))
    }

    func testSidebarMetricsSessionsTrackTabsIndependently() {
        var tabASession = AIChatSidebarMetricsSession()
        var tabBSession = AIChatSidebarMetricsSession()

        XCTAssertEqual(tabASession.update(isExpanded: true, uptime: 10), .opened)
        XCTAssertEqual(tabBSession.update(isExpanded: true, uptime: 20), .opened)
        XCTAssertEqual(
            tabBSession.update(isExpanded: false, uptime: 35),
            .closed(durationSeconds: 15)
        )
        XCTAssertEqual(
            tabASession.update(isExpanded: false, uptime: 50),
            .closed(durationSeconds: 40)
        )
    }
}

// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// Records what `BrowserState` hands the Chromium bridge for the AI Chat panel.
private final class FakeAIChatPanelBridge: AIChatPanelBridging {
    var pushes: [(record: String?, tabId: Int)] = []
    var panelRequests: [(url: String, customGuid: String, windowId: Int)] = []

    func setAIChatPanelRecord(_ record: String?, forTabId tabId: Int) {
        pushes.append((record, tabId))
    }

    func createAIChatPanelTab(url: String, customGuid: String, windowId: Int) {
        panelRequests.append((url, customGuid, windowId))
    }

    /// Decoded pushes for `tabId`; a clear reads as nil.
    func records(forTabId tabId: Int) -> [AIChatPanelRecord?] {
        pushes.filter { $0.tabId == tabId }.map { $0.record.flatMap(AIChatPanelRecord.init(encoded:)) }
    }
}

/// Undo close brings a tab back with the AI Chat panel it had (chromium ADR
/// 0017). Out: the window's `BrowserState` pushes each page tab's panel record
/// to Chromium as it changes. In: a restored tab that arrives with a record
/// gets its panel back on the same conversation, expanded or collapsed as it
/// was.
@MainActor
final class BrowserStateAIChatPanelRecordTests: XCTestCase {
    private let conversationX = "3f2a8c1e-5b7d-4e9a-8c6f-1d2e3f4a5b6c"
    private let conversationY = "9b8a7c6d-5e4f-4a3b-9c2d-1e0f9a8b7c6d"
    private var tempDirectories: [URL] = []
    private var originalPhiAIEnabled: Any?

    override func setUpWithError() throws {
        // Expanding a panel is gated on the AI switch; pin it on and give the
        // user's value back afterwards.
        let key = PhiPreferences.AISettings.phiAIEnabled.rawValue
        originalPhiAIEnabled = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
    }

    override func tearDownWithError() throws {
        let key = PhiPreferences.AISettings.phiAIEnabled.rawValue
        if let originalPhiAIEnabled {
            UserDefaults.standard.set(originalPhiAIEnabled, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        originalPhiAIEnabled = nil
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    private func makeState(bridge: FakeAIChatPanelBridge) throws -> BrowserState {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        let store = LocalStore(account: Account(userID: UUID().uuidString),
                               storeDirectoryURL: directory)
        return BrowserState(windowId: 7, localStore: store, profileId: "Default",
                            aiChatPanelBridge: bridge)
    }

    private func seed(_ state: BrowserState, guids: [Int]) -> [Tab] {
        let tabs = guids.map { Tab(guid: $0, url: "https://e\($0).example", isActive: false, index: 0) }
        state.tabs = tabs
        state.updateNormalTabs()
        return tabs
    }

    /// Gives `tab` a panel tab showing `url`, as `handleNewTabFromChromium`
    /// files one.
    @discardableResult
    private func addPanel(to tab: Tab, in state: BrowserState, url: String) -> Tab {
        let chat = Tab(guid: tab.guid * 100, url: url, isActive: false, index: 0)
        state.aiChatTabs[state.getTabIdentifier(for: tab)] = chat
        return chat
    }

    private func conversationURL(_ id: String, tabId: Int) -> String {
        "chrome://conversation/\(id)?is_sidebar=1&tabId=\(tabId)"
    }

    private func newChatURL(tabId: Int) -> String {
        "chrome://conversation/index.html?is_sidebar=1&tabId=\(tabId)"
    }

    private func record(expanded: Bool, _ conversationId: String?) -> AIChatPanelRecord? {
        AIChatPanelRecord(isExpanded: expanded, conversationId: conversationId)
    }

    /// Every live `BrowserState` reacts to this preference on the main queue
    /// (`updateAISettings`), and turning it off there tears Sentinel down. A
    /// test that turns it off must turn it back on, or let tearDown restore
    /// it, without yielding to the main queue in between.
    private func setAIEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: PhiPreferences.AISettings.phiAIEnabled.rawValue)
    }

    // MARK: - Out: pushing the record

    func testExpandingPushesAnExpandedRecordWithoutAConversation() throws {
        let bridge = FakeAIChatPanelBridge()
        let state = try makeState(bridge: bridge)
        let tab = seed(state, guids: [1])[0]

        tab.aiChatCollapsed = false

        XCTAssertEqual(bridge.records(forTabId: 1), [record(expanded: true, nil)])
    }

    func testAConversationInThePanelURLIsPushed() throws {
        let bridge = FakeAIChatPanelBridge()
        let state = try makeState(bridge: bridge)
        let tab = seed(state, guids: [1])[0]
        tab.aiChatCollapsed = false
        let chat = addPanel(to: tab, in: state, url: newChatURL(tabId: 1))

        chat.url = conversationURL(conversationX, tabId: 1)

        XCTAssertEqual(bridge.records(forTabId: 1),
                       [record(expanded: true, nil), record(expanded: true, conversationX)])
    }

    func testSwitchingConversationPushesTheNewOne() throws {
        let bridge = FakeAIChatPanelBridge()
        let state = try makeState(bridge: bridge)
        let tab = seed(state, guids: [1])[0]
        tab.aiChatCollapsed = false
        let chat = addPanel(to: tab, in: state, url: conversationURL(conversationX, tabId: 1))

        chat.url = conversationURL(conversationY, tabId: 1)

        XCTAssertEqual(bridge.records(forTabId: 1).last, record(expanded: true, conversationY))
    }

    /// The page's own URL form, in case Chromium hands it over unrewritten.
    func testAConversationInTheExtensionURLFormIsPushed() throws {
        let bridge = FakeAIChatPanelBridge()
        let state = try makeState(bridge: bridge)
        let tab = seed(state, guids: [1])[0]
        tab.aiChatCollapsed = false

        addPanel(to: tab, in: state,
                 url: "chrome-extension://fenmfiepnpdlhplemgijlimpbebebljo/index.html?is_sidebar=1&tabId=1&conv_id=\(conversationX)")

        XCTAssertEqual(bridge.records(forTabId: 1).last, record(expanded: true, conversationX))
    }

    func testCollapsingPushesACollapsedRecordWithItsConversation() throws {
        let bridge = FakeAIChatPanelBridge()
        let state = try makeState(bridge: bridge)
        let tab = seed(state, guids: [1])[0]
        tab.aiChatCollapsed = false
        addPanel(to: tab, in: state, url: conversationURL(conversationX, tabId: 1))

        tab.aiChatCollapsed = true

        XCTAssertEqual(bridge.records(forTabId: 1).last, record(expanded: false, conversationX))
    }

    func testCollapsingWithoutAConversationClearsTheRecord() throws {
        let bridge = FakeAIChatPanelBridge()
        let state = try makeState(bridge: bridge)
        let tab = seed(state, guids: [1])[0]
        tab.aiChatCollapsed = false
        addPanel(to: tab, in: state, url: newChatURL(tabId: 1))

        tab.aiChatCollapsed = true

        XCTAssertEqual(bridge.records(forTabId: 1), [record(expanded: true, nil), nil])
        XCTAssertNil(bridge.pushes.last?.record)
    }

    func testATabThatNeverOpenedItsPanelPushesNothing() throws {
        let bridge = FakeAIChatPanelBridge()
        let state = try makeState(bridge: bridge)
        let tabs = seed(state, guids: [1, 2])

        tabs[1].aiChatCollapsed = true
        tabs[0].aiChatCollapsed = false

        XCTAssertEqual(bridge.pushes.map(\.tabId), [1])
    }

    func testAnUnchangedRecordIsNotPushedAgain() throws {
        let bridge = FakeAIChatPanelBridge()
        let state = try makeState(bridge: bridge)
        let tab = seed(state, guids: [1])[0]
        tab.aiChatCollapsed = false
        let chat = addPanel(to: tab, in: state, url: conversationURL(conversationX, tabId: 1))

        tab.aiChatCollapsed = false
        chat.url = conversationURL(conversationX, tabId: 1)

        XCTAssertEqual(bridge.records(forTabId: 1),
                       [record(expanded: true, nil), record(expanded: true, conversationX)])
    }

    func testClosingThePageTabPushesNoClear() throws {
        let bridge = FakeAIChatPanelBridge()
        let state = try makeState(bridge: bridge)
        let tab = seed(state, guids: [1])[0]
        tab.aiChatCollapsed = false
        addPanel(to: tab, in: state, url: conversationURL(conversationX, tabId: 1))
        XCTAssertEqual(bridge.records(forTabId: 1).last, record(expanded: true, conversationX))
        let pushesBeforeClose = bridge.pushes.count

        state.closeTab(1)

        XCTAssertNil(state.aiChatTabs[state.getTabIdentifier(for: tab)])
        XCTAssertEqual(bridge.pushes.count, pushesBeforeClose)
    }

    // MARK: - Split: two panes share one panel

    private func splitPanes(_ state: BrowserState, _ primary: Int, _ secondary: Int) {
        state.splits = [SplitGroup(id: "split-\(primary)-\(secondary)", primaryTabId: primary,
                                   secondaryTabId: secondary, layout: .vertical, ratio: 0.5)]
    }

    /// Chromium files the panel tab `createAIChatTab` asked for under `identifier`.
    private func filePanel(for identifier: String, in state: BrowserState, url: String) {
        let chat = Tab(guid: 900, url: url, isActive: false, index: 0)
        chat.guidInLocalDB = BrowserState.aiChatId(for: identifier)
        state.handleNewTabFromChromium(chat)
    }

    /// Tab 1 holds the split's panel, expanded on conversation X.
    private func makeSplitWithPanelOnTab1(bridge: FakeAIChatPanelBridge) throws -> BrowserState {
        let state = try makeState(bridge: bridge)
        state.aiChatTabCreationGateOverrideForTesting = true
        let tabs = seed(state, guids: [1, 2])
        splitPanes(state, 1, 2)
        // Expanding mirrors to tab 2 before the panel exists.
        expand(tabs[0], in: state)
        filePanel(for: state.getTabIdentifier(for: tabs[0]), in: state,
                  url: conversationURL(conversationX, tabId: 1))
        return state
    }

    func testInASplitOnlyThePaneHoldingThePanelKeepsARecord() throws {
        let bridge = FakeAIChatPanelBridge()
        _ = try makeSplitWithPanelOnTab1(bridge: bridge)

        XCTAssertEqual(bridge.records(forTabId: 1).last, record(expanded: true, conversationX))
        XCTAssertNil(try XCTUnwrap(bridge.pushes.last(where: { $0.tabId == 2 })).record)
    }

    func testClosingThePaneHoldingThePanelHandsTheRecordToTheOtherPane() throws {
        let bridge = FakeAIChatPanelBridge()
        let state = try makeSplitWithPanelOnTab1(bridge: bridge)

        state.closeTab(1)

        XCTAssertNotNil(state.aiChatTabs[state.getTabIdentifier(for: state.tabs[0])])
        XCTAssertNil(try XCTUnwrap(bridge.pushes.last(where: { $0.tabId == 1 })).record)
        XCTAssertEqual(bridge.records(forTabId: 2).last, record(expanded: true, conversationX))
    }

    func testTheHandOffIsPushedWhenChromiumAnnouncesTheRemoval() throws {
        let bridge = FakeAIChatPanelBridge()
        let state = try makeSplitWithPanelOnTab1(bridge: bridge)

        // Chromium writes tab 1's closed entry once this returns, before the
        // client's `closeTab` runs.
        state.splitPaneWillBeRemoved(1)

        XCTAssertNil(try XCTUnwrap(bridge.pushes.last(where: { $0.tabId == 1 })).record)
        XCTAssertEqual(bridge.records(forTabId: 2).last, record(expanded: true, conversationX))
        let pushesBeforeClose = bridge.pushes.count
        state.closeTab(1)
        XCTAssertEqual(bridge.pushes.count, pushesBeforeClose)
    }

    func testACollapsedPanelIsHandedOverCollapsed() throws {
        let bridge = FakeAIChatPanelBridge()
        let state = try makeSplitWithPanelOnTab1(bridge: bridge)
        // Collapsing mirrors to tab 2.
        state.setAIChatCollapsed(for: state.tabs[0], collapsed: true)
        XCTAssertEqual(bridge.records(forTabId: 1).last, record(expanded: false, conversationX))

        state.splitPaneWillBeRemoved(1)

        XCTAssertNil(try XCTUnwrap(bridge.pushes.last(where: { $0.tabId == 1 })).record)
        XCTAssertEqual(bridge.records(forTabId: 2).last, record(expanded: false, conversationX))
    }

    // When both panes close, the record each holds when Chromium announces its
    // removal is the one its closed entry gets, so it stays with the pane that
    // closes last.

    func testWhenTheHolderClosesFirstTheOtherPaneEndsWithTheRecord() throws {
        let bridge = FakeAIChatPanelBridge()
        let state = try makeSplitWithPanelOnTab1(bridge: bridge)

        state.splitPaneWillBeRemoved(1)
        state.closeTab(1)
        state.splitPaneWillBeRemoved(2)
        state.closeTab(2)

        XCTAssertNil(try XCTUnwrap(bridge.pushes.last(where: { $0.tabId == 1 })).record)
        XCTAssertEqual(bridge.records(forTabId: 2).last, record(expanded: true, conversationX))
    }

    /// Close Other Tabs closes both panes in one go: Chromium announces both
    /// removals before the client handles either close.
    func testWhenBothAreRemovedTogetherHolderFirstTheOtherPaneEndsWithTheRecord() throws {
        let bridge = FakeAIChatPanelBridge()
        let state = try makeSplitWithPanelOnTab1(bridge: bridge)

        state.splitPaneWillBeRemoved(1)
        state.splitPaneWillBeRemoved(2)
        state.closeTab(1)
        state.closeTab(2)

        XCTAssertNil(try XCTUnwrap(bridge.pushes.last(where: { $0.tabId == 1 })).record)
        XCTAssertEqual(bridge.records(forTabId: 2).last, record(expanded: true, conversationX))
    }

    func testWhenTheOtherPaneIsRemovedFirstTheHolderKeepsTheRecord() throws {
        let bridge = FakeAIChatPanelBridge()
        let state = try makeSplitWithPanelOnTab1(bridge: bridge)

        state.splitPaneWillBeRemoved(2)
        state.splitPaneWillBeRemoved(1)
        state.closeTab(2)
        state.closeTab(1)

        XCTAssertNil(try XCTUnwrap(bridge.pushes.last(where: { $0.tabId == 2 })).record)
        XCTAssertEqual(bridge.records(forTabId: 1).last, record(expanded: true, conversationX))
    }

    // A split formed from two tabs keeps at most one of their panels.

    /// Chromium reports the split formed, unlike `splitPanes`:
    /// `handleSplitCreated` reconciles the panels and syncs collapse.
    private func formSplit(_ state: BrowserState, _ primary: Int, _ secondary: Int) {
        state.handleSplitCreated(splitId: "split-\(primary)-\(secondary)", primaryTabId: primary,
                                 secondaryTabId: secondary, layout: .vertical, ratio: 0.5)
    }

    func testFormingASplitClearsTheRecordOfThePaneWhosePanelIsClosed() throws {
        let bridge = FakeAIChatPanelBridge()
        let state = try makeState(bridge: bridge)
        let tabs = seed(state, guids: [1, 2])
        for (tab, conversation) in zip(tabs, [conversationX, conversationY]) {
            tab.aiChatCollapsed = false
            addPanel(to: tab, in: state, url: conversationURL(conversation, tabId: tab.guid))
        }
        state.focuseTab(tabs[1])
        let pushesBefore = bridge.pushes.count

        formSplit(state, 1, 2)

        // The foreground pane keeps its panel; tab 1's is closed.
        XCTAssertNil(state.aiChatTabs[state.getTabIdentifier(for: tabs[0])])
        let pushes = bridge.pushes.dropFirst(pushesBefore)
        XCTAssertEqual(pushes.map(\.tabId), [1])
        XCTAssertNil(try XCTUnwrap(pushes.first).record)
        XCTAssertEqual(bridge.records(forTabId: 2).last, record(expanded: true, conversationY))
    }

    func testFormingASplitWhereOnlyOnePaneHasAPanelPushesNothing() throws {
        let bridge = FakeAIChatPanelBridge()
        let state = try makeState(bridge: bridge)
        let tabs = seed(state, guids: [1, 2])
        tabs[0].aiChatCollapsed = false
        addPanel(to: tabs[0], in: state, url: conversationURL(conversationX, tabId: 1))
        state.focuseTab(tabs[1])
        let pushesBefore = bridge.pushes.count

        // Tab 2 expands to match tab 1, and resolves to tab 1's panel.
        formSplit(state, 1, 2)

        XCTAssertEqual(bridge.pushes.count, pushesBefore)
    }

    func testFormingASplitWhereNeitherPaneHasAPanelPushesNothing() throws {
        let bridge = FakeAIChatPanelBridge()
        let state = try makeState(bridge: bridge)
        let tabs = seed(state, guids: [1, 2])
        // Both expanded, before either panel exists.
        tabs.forEach { $0.aiChatCollapsed = false }
        state.focuseTab(tabs[1])
        let pushesBefore = bridge.pushes.count

        formSplit(state, 1, 2)

        XCTAssertEqual(bridge.pushes.count, pushesBefore)
    }

    // MARK: - In: a restored tab arrives with its record

    private func arrive(_ state: BrowserState, guid: Int, record: AIChatPanelRecord?,
                        isActiveAtCreation: Bool) -> Tab {
        let tab = Tab(guid: guid, url: "https://e\(guid).example", isActive: false, index: 0)
        tab.restoredAIChatPanel = record
        state.handleNewTabFromChromium(
            tab,
            context: NativeTabCreationContext(isActiveAtCreation: isActiveAtCreation,
                                              creationKind: .restore))
        return tab
    }

    /// The user expands the panel, and the chat pane asks for its panel tab.
    private func expand(_ tab: Tab, in state: BrowserState) {
        state.setAIChatCollapsed(for: tab, collapsed: false)
        state.createAIChatTab(for: state.chatIdentifier(for: tab), chromeTabId: tab.guid)
    }

    func testTheCurrentTabArrivingExpandedAsksForItsPanelOnTheSameConversation() throws {
        let bridge = FakeAIChatPanelBridge()
        let state = try makeState(bridge: bridge)
        state.aiChatTabCreationGateOverrideForTesting = true
        _ = seed(state, guids: [1])

        let tab = arrive(state, guid: 5, record: record(expanded: true, conversationX),
                         isActiveAtCreation: true)

        XCTAssertFalse(tab.aiChatCollapsed)
        XCTAssertEqual(bridge.panelRequests.count, 1)
        let request = try XCTUnwrap(bridge.panelRequests.first)
        XCTAssertEqual(request.customGuid, BrowserState.aiChatId(for: "5"))
        XCTAssertEqual(request.windowId, 7)
        let query = URLComponents(string: request.url)?.queryItems ?? []
        XCTAssertEqual(query.first(where: { $0.name == "is_sidebar" })?.value, "1")
        XCTAssertEqual(query.first(where: { $0.name == "tabId" })?.value, "5")
        XCTAssertEqual(query.first(where: { $0.name == "conv_id" })?.value, conversationX)
    }

    func testTakingOverAnExpandedRecordPushesItBack() throws {
        let bridge = FakeAIChatPanelBridge()
        let state = try makeState(bridge: bridge)
        state.aiChatTabCreationGateOverrideForTesting = true
        _ = seed(state, guids: [1])

        _ = arrive(state, guid: 5, record: record(expanded: true, conversationX),
                   isActiveAtCreation: true)

        // Chromium stops handing the record back once the client pushes it.
        XCTAssertEqual(bridge.records(forTabId: 5), [record(expanded: true, conversationX)])
    }

    func testABackgroundTabArrivingExpandedGetsItsPanelOnTheSameConversationWhenShown() throws {
        let bridge = FakeAIChatPanelBridge()
        let state = try makeState(bridge: bridge)
        state.aiChatTabCreationGateOverrideForTesting = true
        _ = seed(state, guids: [1])

        let tab = arrive(state, guid: 5, record: record(expanded: true, conversationX),
                         isActiveAtCreation: false)
        XCTAssertFalse(tab.aiChatCollapsed)
        XCTAssertTrue(bridge.panelRequests.isEmpty)

        // The chat pane asks for the panel the first time the tab is shown.
        state.createAIChatTab(for: state.chatIdentifier(for: tab), chromeTabId: tab.guid)

        let request = try XCTUnwrap(bridge.panelRequests.first)
        let query = URLComponents(string: request.url)?.queryItems ?? []
        XCTAssertEqual(query.first(where: { $0.name == "conv_id" })?.value, conversationX)
    }

    func testARecordInAnotherVersionOrNamingNoValidConversationReadsAsNone() {
        XCTAssertNotNil(AIChatPanelRecord(encoded: #"{"conversationId":"\#(conversationX)","expanded":true,"v":1}"#))
        XCTAssertNil(AIChatPanelRecord(encoded: #"{"conversationId":"\#(conversationX)","expanded":true,"v":2}"#))
        XCTAssertNil(AIChatPanelRecord(encoded: #"{"conversationId":"x&tabId=1","expanded":true,"v":1}"#))
    }

    func testACollapsedRecordArrivingStaysCollapsedAndIsPushedBack() throws {
        let bridge = FakeAIChatPanelBridge()
        let state = try makeState(bridge: bridge)
        state.aiChatTabCreationGateOverrideForTesting = true
        _ = seed(state, guids: [1])

        let tab = arrive(state, guid: 5, record: record(expanded: false, conversationX),
                         isActiveAtCreation: true)

        XCTAssertTrue(tab.aiChatCollapsed)
        XCTAssertTrue(bridge.panelRequests.isEmpty)
        // Chromium stops handing the record back once the client pushes it.
        XCTAssertEqual(bridge.records(forTabId: 5), [record(expanded: false, conversationX)])
    }

    func testExpandingACollapsedArrivalAsksForItsPanelOnTheSameConversation() throws {
        let bridge = FakeAIChatPanelBridge()
        let state = try makeState(bridge: bridge)
        state.aiChatTabCreationGateOverrideForTesting = true
        _ = seed(state, guids: [1])
        let tab = arrive(state, guid: 5, record: record(expanded: false, conversationX),
                         isActiveAtCreation: true)

        expand(tab, in: state)

        let request = try XCTUnwrap(bridge.panelRequests.first)
        let query = URLComponents(string: request.url)?.queryItems ?? []
        XCTAssertEqual(query.first(where: { $0.name == "conv_id" })?.value, conversationX)
        XCTAssertEqual(bridge.records(forTabId: 5).last, record(expanded: true, conversationX))
    }

    func testARecomputeBeforeThePanelExistsKeepsTheConversation() throws {
        let bridge = FakeAIChatPanelBridge()
        let state = try makeState(bridge: bridge)
        state.aiChatTabCreationGateOverrideForTesting = true
        _ = seed(state, guids: [1])
        let tab = arrive(state, guid: 5, record: record(expanded: false, conversationX),
                         isActiveAtCreation: true)

        // Setting the unchanged state still publishes, so the record is recomputed.
        state.setAIChatCollapsed(for: tab, collapsed: true)

        XCTAssertEqual(bridge.records(forTabId: 5), [record(expanded: false, conversationX)])
    }

    func testOnceThePanelExistsSwitchingAndCollapsingArePushedFromItsURL() throws {
        let bridge = FakeAIChatPanelBridge()
        let state = try makeState(bridge: bridge)
        state.aiChatTabCreationGateOverrideForTesting = true
        _ = seed(state, guids: [1])
        let tab = arrive(state, guid: 5, record: record(expanded: false, conversationX),
                         isActiveAtCreation: true)
        expand(tab, in: state)
        let chat = addPanel(to: tab, in: state, url: conversationURL(conversationX, tabId: 5))

        chat.url = conversationURL(conversationY, tabId: 5)
        state.setAIChatCollapsed(for: tab, collapsed: true)

        XCTAssertEqual(bridge.records(forTabId: 5),
                       [record(expanded: false, conversationX), record(expanded: true, conversationX),
                        record(expanded: true, conversationY), record(expanded: false, conversationY)])
    }

    func testClosingBeforeThePanelExistsLeavesChromiumTheCollapsedRecord() throws {
        let bridge = FakeAIChatPanelBridge()
        let state = try makeState(bridge: bridge)
        state.aiChatTabCreationGateOverrideForTesting = true
        _ = seed(state, guids: [1])
        _ = arrive(state, guid: 5, record: record(expanded: false, conversationX),
                   isActiveAtCreation: true)

        state.closeTab(5)

        // Chromium writes the record it last got into the closed entry.
        XCTAssertEqual(bridge.records(forTabId: 5), [record(expanded: false, conversationX)])
    }

    func testPinningBeforeExpandingKeepsTheConversation() throws {
        let bridge = FakeAIChatPanelBridge()
        let state = try makeState(bridge: bridge)
        state.aiChatTabCreationGateOverrideForTesting = true
        _ = seed(state, guids: [1])
        let tab = arrive(state, guid: 5, record: record(expanded: false, conversationX),
                         isActiveAtCreation: true)
        state.moveNormalTabToPinned(tab, after: nil)

        expand(tab, in: state)

        let request = try XCTUnwrap(bridge.panelRequests.first)
        let query = URLComponents(string: request.url)?.queryItems ?? []
        XCTAssertEqual(query.first(where: { $0.name == "conv_id" })?.value, conversationX)
        XCTAssertEqual(bridge.records(forTabId: 5).last, record(expanded: true, conversationX))
    }

    func testAPanelCreatedAgainLaterDoesNotReopenTheRestoredConversation() throws {
        let bridge = FakeAIChatPanelBridge()
        let state = try makeState(bridge: bridge)
        state.aiChatTabCreationGateOverrideForTesting = true
        _ = seed(state, guids: [1])
        let tab = arrive(state, guid: 5, record: record(expanded: false, conversationX),
                         isActiveAtCreation: true)
        expand(tab, in: state)
        let identifier = state.getTabIdentifier(for: tab)
        let chat = Tab(guid: 500, url: conversationURL(conversationX, tabId: 5), isActive: false, index: 0)
        chat.guidInLocalDB = BrowserState.aiChatId(for: identifier)
        state.handleNewTabFromChromium(chat)
        // The panel tab goes away while the page tab stays.
        state.closeAIChatTab(for: identifier)

        expand(tab, in: state)

        let request = try XCTUnwrap(bridge.panelRequests.dropFirst().first)
        let query = URLComponents(string: request.url)?.queryItems ?? []
        XCTAssertNil(query.first(where: { $0.name == "conv_id" }))
    }

    // MARK: - Dropped: AI switch off, guest mode, unreadable records

    func testWithTheAISwitchOffAnArrivingRecordIsDropped() throws {
        for expanded in [true, false] {
            let bridge = FakeAIChatPanelBridge()
            let state = try makeState(bridge: bridge)
            state.aiChatTabCreationGateOverrideForTesting = true
            _ = seed(state, guids: [1])
            setAIEnabled(false)

            let tab = arrive(state, guid: 5, record: record(expanded: expanded, conversationX),
                             isActiveAtCreation: true)

            XCTAssertTrue(tab.aiChatCollapsed, "expanded=\(expanded)")
            XCTAssertTrue(bridge.panelRequests.isEmpty, "expanded=\(expanded)")
            XCTAssertEqual(bridge.pushes.map(\.tabId), [5], "expanded=\(expanded)")
            XCTAssertEqual(bridge.pushes.map(\.record), [nil], "expanded=\(expanded)")
            // With AI back on, closing the tab again leaves Chromium no record
            // for the closed entry.
            setAIEnabled(true)
            state.closeTab(5)
            XCTAssertEqual(bridge.pushes.count, 1, "expanded=\(expanded)")
        }
    }

    func testARecordDroppedWithTheAISwitchOffKeepsNoConversationForLater() throws {
        let bridge = FakeAIChatPanelBridge()
        let state = try makeState(bridge: bridge)
        state.aiChatTabCreationGateOverrideForTesting = true
        _ = seed(state, guids: [1])
        setAIEnabled(false)
        let tab = arrive(state, guid: 5, record: record(expanded: false, conversationX),
                         isActiveAtCreation: true)
        setAIEnabled(true)

        expand(tab, in: state)

        let request = try XCTUnwrap(bridge.panelRequests.first)
        let query = URLComponents(string: request.url)?.queryItems ?? []
        XCTAssertNil(query.first(where: { $0.name == "conv_id" }))
        XCTAssertEqual(bridge.records(forTabId: 5).last, record(expanded: true, nil))
    }

    func testInGuestModeAnArrivingRecordIsDropped() throws {
        for expanded in [true, false] {
            let bridge = FakeAIChatPanelBridge()
            let state = try makeState(bridge: bridge)
            state.aiChatTabCreationGateOverrideForTesting = true
            state.guestModeOverrideForTesting = true
            _ = seed(state, guids: [1])

            let tab = arrive(state, guid: 5, record: record(expanded: expanded, conversationX),
                             isActiveAtCreation: true)

            XCTAssertTrue(tab.aiChatCollapsed, "expanded=\(expanded)")
            XCTAssertTrue(bridge.panelRequests.isEmpty, "expanded=\(expanded)")
            XCTAssertEqual(bridge.pushes.map(\.tabId), [5], "expanded=\(expanded)")
            XCTAssertEqual(bridge.pushes.map(\.record), [nil], "expanded=\(expanded)")
            // Signed in later, the panel opens on a new conversation.
            state.guestModeOverrideForTesting = false
            expand(tab, in: state)
            let request = try XCTUnwrap(bridge.panelRequests.first, "expanded=\(expanded)")
            let query = URLComponents(string: request.url)?.queryItems ?? []
            XCTAssertNil(query.first(where: { $0.name == "conv_id" }), "expanded=\(expanded)")
        }
    }

    func testAMalformedRecordReadsAsNone() {
        XCTAssertNil(AIChatPanelRecord(encoded: ""))
        XCTAssertNil(AIChatPanelRecord(encoded: "not json"))
        XCTAssertNil(AIChatPanelRecord(encoded: #"{"expanded":true}"#))
        XCTAssertNil(AIChatPanelRecord(encoded: #"{"conversationId":"\#(conversationX)","v":1}"#))
        XCTAssertNil(AIChatPanelRecord(encoded: #"{"expanded":"yes","v":1}"#))
    }

    func testTurningTheAISwitchOffClearsEveryTabsRecord() throws {
        let bridge = FakeAIChatPanelBridge()
        let state = try makeState(bridge: bridge)
        state.aiChatTabCreationGateOverrideForTesting = true
        let tabs = seed(state, guids: [1, 2])
        tabs[0].aiChatCollapsed = false
        addPanel(to: tabs[0], in: state, url: conversationURL(conversationX, tabId: 1))
        let restored = arrive(state, guid: 5, record: record(expanded: false, conversationY),
                              isActiveAtCreation: false)

        setAIEnabled(false)
        state.closeAllAIContent()

        XCTAssertNil(try XCTUnwrap(bridge.pushes.last(where: { $0.tabId == 1 })).record)
        XCTAssertNil(try XCTUnwrap(bridge.pushes.last(where: { $0.tabId == 5 })).record)
        // A tab moved in from another window can hold a record this window
        // never pushed.
        XCTAssertNil(try XCTUnwrap(bridge.pushes.last(where: { $0.tabId == 2 })).record)
        // The conversation the restored tab was waiting on is gone as well.
        setAIEnabled(true)
        expand(restored, in: state)
        let request = try XCTUnwrap(bridge.panelRequests.first)
        let query = URLComponents(string: request.url)?.queryItems ?? []
        XCTAssertNil(query.first(where: { $0.name == "conv_id" }))
    }

    // MARK: - Peek: the opener's pairing marker

    /// Stamps `tab` as `presentPeek` stamps a normal opener: a one-shot marker
    /// for the Peek's restore binding, which the Peek's end strips again.
    private func stampPeekOpenerMarker(on tab: Tab) {
        tab.guidInLocalDB = BrowserState.peekOpenerGuidPrefix + UUID().uuidString
    }

    func testCollapsingAndExpandingDuringAPeekKeepTheConversation() throws {
        let bridge = FakeAIChatPanelBridge()
        let state = try makeState(bridge: bridge)
        let tab = seed(state, guids: [1])[0]
        tab.aiChatCollapsed = false
        addPanel(to: tab, in: state, url: conversationURL(conversationX, tabId: 1))
        stampPeekOpenerMarker(on: tab)

        tab.aiChatCollapsed = true
        tab.aiChatCollapsed = false

        XCTAssertEqual(bridge.records(forTabId: 1),
                       [record(expanded: true, nil), record(expanded: true, conversationX),
                        record(expanded: false, conversationX), record(expanded: true, conversationX)])
    }

    func testAPanelCreatedDuringAPeekStaysWithItsTab() throws {
        let bridge = FakeAIChatPanelBridge()
        let state = try makeState(bridge: bridge)
        state.aiChatTabCreationGateOverrideForTesting = true
        let tab = seed(state, guids: [1])[0]
        stampPeekOpenerMarker(on: tab)

        expand(tab, in: state)

        let request = try XCTUnwrap(bridge.panelRequests.first)
        XCTAssertEqual(request.customGuid, BrowserState.aiChatId(for: "1"))
        // Chromium files the panel tab under the identifier it was asked for.
        let chat = Tab(guid: 100, url: newChatURL(tabId: 1), isActive: false, index: 0)
        chat.guidInLocalDB = request.customGuid
        state.handleNewTabFromChromium(chat)
        // The Peek ends.
        tab.guidInLocalDB = nil
        XCTAssertTrue(state.aiChatTabs[state.chatIdentifier(for: tab)] === chat)

        state.closeTab(1)

        XCTAssertTrue(state.aiChatTabs.isEmpty)
    }
}

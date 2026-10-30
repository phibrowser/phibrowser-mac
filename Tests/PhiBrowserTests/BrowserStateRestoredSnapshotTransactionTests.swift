// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Combine
import XCTest
@testable import Phi

/// T3B: `handleRestoredWindowSnapshot` applies a restored window as one
/// transaction. These tests pin its final state to the per-tab path
/// (`handleNewTabFromChromium` + split handlers + active change) run over
/// the same fixture, plus the transaction-specific guarantees: exactly one
/// `normalTabs` publish, duplicate-id fail-closed, the synchronous UI
/// signal, and that the transaction can never stay latched.
@MainActor
final class BrowserStateRestoredSnapshotTransactionTests: XCTestCase {

    // MARK: - Helpers

    private var tempDirectories: [URL] = []
    private var cancellables = Set<AnyCancellable>()

    override func tearDownWithError() throws {
        cancellables.removeAll()
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

    private func makeBrowserState(windowId: Int = 7) throws -> BrowserState {
        let directory = try makeTemporaryStoreDirectory()
        let store = LocalStore(account: Account(userID: UUID().uuidString),
                               storeDirectoryURL: directory)
        return BrowserState(windowId: windowId, localStore: store, profileId: "Default")
    }

    private struct RestoreTabSpec {
        let guid: Int
        var url: String = "https://example.test"
        var customGuid: String? = nil
        var groupToken: String? = nil
    }

    /// Builds snapshot items the way the coordinator does: tabs in final
    /// strip order, each context anchored on the preceding payload tab
    /// (T3A's rewritten anchor chain), creation kind `.restore`.
    private func makeItems(_ specs: [RestoreTabSpec]) -> [(tab: Tab, context: NativeTabCreationContext)] {
        var previousGuid: Int?
        return specs.map { spec in
            let tab = Tab(guid: spec.guid,
                          url: spec.url,
                          isActive: false,
                          index: 0,
                          customGuid: spec.customGuid)
            if let token = spec.groupToken {
                tab.groupToken = token
            }
            let context = NativeTabCreationContext(
                isActiveAtCreation: false,
                creationKind: .restore,
                insertAfterTabId: previousGuid
            )
            previousGuid = spec.guid
            return (tab, context)
        }
    }

    /// The pre-T3B reference: replay the same payload through the existing
    /// per-tab arrival path, then splits, then the final active tab — the
    /// exact order the T3A thin adapter used.
    private func applyPerTabReference(state: BrowserState,
                                      items: [(tab: Tab, context: NativeTabCreationContext)],
                                      splitActions: [SplitEvent.SplitAction] = [],
                                      activeTabId: Int? = nil) {
        for item in items {
            state.handleNewTabFromChromium(item.tab, context: item.context)
        }
        for action in splitActions {
            switch action {
            case let .created(splitId, primaryTabId, secondaryTabId, layout, ratio):
                state.handleSplitCreated(splitId: splitId,
                                         primaryTabId: primaryTabId,
                                         secondaryTabId: secondaryTabId,
                                         layout: layout,
                                         ratio: ratio)
            case let .visualsChanged(splitId, layout, ratio):
                state.handleSplitVisualsChanged(splitId: splitId, layout: layout, ratio: ratio)
            case let .contentsChanged(splitId, primaryTabId, secondaryTabId):
                state.handleSplitContentsChanged(splitId: splitId,
                                                 primaryTabId: primaryTabId,
                                                 secondaryTabId: secondaryTabId)
            case .removed(let splitId):
                state.handleSplitRemoved(splitId: splitId)
            case let .openLinkAsSplitPartner(partnerTabId, url):
                state.handleOpenLinkAsSplitPartner(partnerTabId: partnerTabId, url: url)
            }
        }
        if let activeTabId {
            state.handleChromiumActiveTabChanged(activeTabId)
        }
    }

    private func assertFinalStatesMatch(_ transactional: BrowserState,
                                        _ reference: BrowserState,
                                        file: StaticString = #filePath,
                                        line: UInt = #line) {
        XCTAssertEqual(transactional.tabs.map(\.guid), reference.tabs.map(\.guid),
                       "tabs order", file: file, line: line)
        XCTAssertEqual(transactional.normalTabs.map(\.guid), reference.normalTabs.map(\.guid),
                       "normalTabs order", file: file, line: line)
        XCTAssertEqual(transactional.tabs.map { $0.groupToken }, reference.tabs.map { $0.groupToken },
                       "group tokens", file: file, line: line)
        XCTAssertEqual(transactional.focusingTab?.guid, reference.focusingTab?.guid,
                       "focusing tab", file: file, line: line)
        XCTAssertEqual(transactional.splits.map(\.id), reference.splits.map(\.id),
                       "split groups", file: file, line: line)
    }

    // MARK: - Semantic equivalence with the per-tab path

    func testPlainBatchMatchesPerTabPathFinalState() throws {
        let specs = [
            RestoreTabSpec(guid: 10, url: "https://a.example"),
            RestoreTabSpec(guid: 11, url: "https://b.example"),
            RestoreTabSpec(guid: 12, url: "https://c.example"),
            RestoreTabSpec(guid: 13, url: "https://d.example"),
        ]
        let reference = try makeBrowserState()
        applyPerTabReference(state: reference, items: makeItems(specs), activeTabId: 12)

        let transactional = try makeBrowserState()
        transactional.handleRestoredWindowSnapshot(
            BrowserState.RestoredWindowSnapshot(tabs: makeItems(specs),
                                               activeTabId: 12,
                                               splitActions: []))

        assertFinalStatesMatch(transactional, reference)
        XCTAssertEqual(transactional.normalTabs.map(\.guid), [10, 11, 12, 13])
        XCTAssertEqual(transactional.focusingTab?.guid, 12)
    }

    func testPinnedReattachMatchesPerTabPath() throws {
        let specs = [
            RestoreTabSpec(guid: 20, url: "https://a.example"),
            RestoreTabSpec(guid: 21, url: "https://pinned.example", customGuid: "pinned-a"),
            RestoreTabSpec(guid: 22, url: "https://b.example"),
        ]
        func seedPinnedRecord(_ state: BrowserState) {
            let record = Tab(guid: 900,
                             url: "https://pinned.example",
                             isActive: false,
                             index: 0,
                             customGuid: "pinned-a")
            state.pinnedTabs = [record]
        }

        let reference = try makeBrowserState()
        seedPinnedRecord(reference)
        applyPerTabReference(state: reference, items: makeItems(specs), activeTabId: 20)

        let transactional = try makeBrowserState()
        seedPinnedRecord(transactional)
        transactional.handleRestoredWindowSnapshot(
            BrowserState.RestoredWindowSnapshot(tabs: makeItems(specs),
                                               activeTabId: 20,
                                               splitActions: []))

        assertFinalStatesMatch(transactional, reference)
        // The pinned-bound tab reattaches to its record and stays out of the
        // sidebar's normal list.
        XCTAssertEqual(transactional.pinnedTabs.first?.isOpenned, true)
        XCTAssertEqual(transactional.pinnedTabs.first?.guid, 21)
        // The pinned-bound tab is filtered out of the projection as soon as it
        // reattaches, which leaves the next payload's anchor (21) unresolvable.
        // That must not move 22 ahead of 20: hiding a tab changes what the
        // sidebar shows, never the relative order of what stays visible.
        XCTAssertEqual(transactional.normalTabs.map(\.guid), [20, 22])
    }

    func testMidStripPinnedBindingKeepsFollowingTabsInStripOrder() throws {
        let specs = [
            RestoreTabSpec(guid: 100, url: "https://a.example"),
            RestoreTabSpec(guid: 101, url: "https://b.example"),
            RestoreTabSpec(guid: 102, url: "https://pinned.example", customGuid: "pinned-mid"),
            RestoreTabSpec(guid: 103, url: "https://c.example"),
            RestoreTabSpec(guid: 104, url: "https://d.example"),
        ]
        func seedPinnedRecord(_ state: BrowserState) {
            let record = Tab(guid: 901,
                             url: "https://pinned.example",
                             isActive: false,
                             index: 0,
                             customGuid: "pinned-mid")
            state.pinnedTabs = [record]
        }

        let reference = try makeBrowserState()
        seedPinnedRecord(reference)
        applyPerTabReference(state: reference, items: makeItems(specs), activeTabId: 100)

        let transactional = try makeBrowserState()
        seedPinnedRecord(transactional)
        transactional.handleRestoredWindowSnapshot(
            BrowserState.RestoredWindowSnapshot(tabs: makeItems(specs),
                                               activeTabId: 100,
                                               splitActions: []))

        assertFinalStatesMatch(transactional, reference)
        XCTAssertEqual(transactional.pinnedTabs.first?.isOpenned, true)
        // Everything after the hidden tab keeps its strip order. Before the
        // fix, 103 lost its anchor and was prepended, dragging 104 with it and
        // producing [103, 104, 100, 101].
        XCTAssertEqual(transactional.normalTabs.map(\.guid), [100, 101, 103, 104])
    }

    func testGroupedBatchMatchesPerTabPath_groupsPreCreated() throws {
        let specs = [
            RestoreTabSpec(guid: 30),
            RestoreTabSpec(guid: 31, groupToken: "deadbeef"),
            RestoreTabSpec(guid: 32, groupToken: "deadbeef"),
            RestoreTabSpec(guid: 33),
        ]
        func seedGroup(_ state: BrowserState) {
            state.handleTabGroupCreated(token: "deadbeef",
                                        title: "G",
                                        color: .blue,
                                        isCollapsed: false,
                                        initialTabIds: [31, 32])
        }

        let reference = try makeBrowserState()
        seedGroup(reference)
        applyPerTabReference(state: reference, items: makeItems(specs), activeTabId: 30)

        let transactional = try makeBrowserState()
        seedGroup(transactional)
        transactional.handleRestoredWindowSnapshot(
            BrowserState.RestoredWindowSnapshot(tabs: makeItems(specs),
                                               activeTabId: 30,
                                               splitActions: []))

        assertFinalStatesMatch(transactional, reference)
        XCTAssertEqual(transactional.normalTabs.map(\.guid), [30, 31, 32, 33])
    }

    func testGroupedBatchKeepsTokens_whenGroupEventTrailing() throws {
        // T3B's synchronous apply runs before the EventBus-queued group
        // events drain, so `groups` is still empty mid-transaction. Payload
        // tokens must survive; the group dict catches up afterwards.
        let specs = [
            RestoreTabSpec(guid: 40, groupToken: "cafebabe"),
            RestoreTabSpec(guid: 41, groupToken: "cafebabe"),
            RestoreTabSpec(guid: 42),
        ]
        let state = try makeBrowserState()
        state.handleRestoredWindowSnapshot(
            BrowserState.RestoredWindowSnapshot(tabs: makeItems(specs),
                                               activeTabId: 40,
                                               splitActions: []))

        XCTAssertEqual(state.normalTabs.map(\.guid), [40, 41, 42])
        XCTAssertEqual(state.tabs.compactMap { $0.groupToken }, ["cafebabe", "cafebabe"])

        state.handleTabGroupCreated(token: "cafebabe",
                                    title: "G",
                                    color: .blue,
                                    isCollapsed: false,
                                    initialTabIds: [40, 41])
        XCTAssertNotNil(state.groups["cafebabe"])
        XCTAssertEqual(state.normalTabs.map(\.guid), [40, 41, 42])
    }

    func testSplitReplayMatchesPerTabPath() throws {
        let specs = [
            RestoreTabSpec(guid: 50),
            RestoreTabSpec(guid: 51),
            RestoreTabSpec(guid: 52),
        ]
        let splitActions: [SplitEvent.SplitAction] = [
            .created(splitId: "split-1",
                     primaryTabId: 51,
                     secondaryTabId: 52,
                     layout: .vertical,
                     ratio: 0.5),
        ]

        let reference = try makeBrowserState()
        applyPerTabReference(state: reference,
                             items: makeItems(specs),
                             splitActions: splitActions,
                             activeTabId: 51)

        let transactional = try makeBrowserState()
        transactional.handleRestoredWindowSnapshot(
            BrowserState.RestoredWindowSnapshot(tabs: makeItems(specs),
                                               activeTabId: 51,
                                               splitActions: splitActions))

        assertFinalStatesMatch(transactional, reference)
        XCTAssertEqual(transactional.splits.count, 1)
        XCTAssertEqual(transactional.splits.first?.primaryTabId, 51)
        XCTAssertEqual(transactional.splits.first?.secondaryTabId, 52)
        // Split members stay adjacent in the normal order.
        XCTAssertEqual(transactional.normalTabs.map(\.guid), [50, 51, 52])
    }

    func testRestoredSplitPullsSecondaryNextToItsPrimary() throws {
        // Chromium's strip keeps the split's two members apart; the Mac side
        // deliberately pulls the secondary up next to its primary
        // (`enforceSplitAdjacency`), so the restored visible order diverges
        // from strip order on purpose.
        let specs = [
            RestoreTabSpec(guid: 110),
            RestoreTabSpec(guid: 111),
            RestoreTabSpec(guid: 112),
            RestoreTabSpec(guid: 113),
        ]
        let splitActions: [SplitEvent.SplitAction] = [
            .created(splitId: "split-apart",
                     primaryTabId: 110,
                     secondaryTabId: 112,
                     layout: .vertical,
                     ratio: 0.5),
        ]

        let state = try makeBrowserState()
        state.handleRestoredWindowSnapshot(
            BrowserState.RestoredWindowSnapshot(tabs: makeItems(specs),
                                               activeTabId: 110,
                                               splitActions: splitActions))

        XCTAssertEqual(state.normalTabs.map(\.guid), [110, 112, 111, 113])
    }

    func testBufferedCrashAppliesDuringTransaction() throws {
        let specs = [RestoreTabSpec(guid: 60)]
        // Buffer a crash for a tab that does not exist yet on any window —
        // showCrashPage falls into the pending-crash buffer. Fence the
        // process-global buffer so a failure here cannot leak the entry
        // into sibling tests.
        defer { _ = PhiChromiumCoordinator.shared.drainPendingCrash(tabId: 60) }
        PhiChromiumCoordinator.shared.showCrashPage(60, windowId: 424242, data: [:])

        let state = try makeBrowserState()
        state.handleRestoredWindowSnapshot(
            BrowserState.RestoredWindowSnapshot(tabs: makeItems(specs),
                                               activeTabId: nil,
                                               splitActions: []))

        XCTAssertNotNil(state.tabs.first?.crashState)
        // Buffer entry was consumed.
        XCTAssertNil(PhiChromiumCoordinator.shared.drainPendingCrash(tabId: 60))
    }

    // MARK: - Transaction guarantees

    func testDuplicateGuidPayloadDroppedBatchSurvives() throws {
        let state = try makeBrowserState()
        // Pre-existing tab with guid 71 — the snapshot's duplicate must be
        // dropped without disturbing the rest of the batch.
        state.tabs = [Tab(guid: 71, url: "https://existing.example", isActive: false, index: 0)]
        state.updateNormalTabs()

        var items = makeItems([
            RestoreTabSpec(guid: 70),
            RestoreTabSpec(guid: 71),
            RestoreTabSpec(guid: 72),
        ])
        // In-batch duplicate of 70 as well.
        items.append(contentsOf: makeItems([RestoreTabSpec(guid: 70)]))

        state.handleRestoredWindowSnapshot(
            BrowserState.RestoredWindowSnapshot(tabs: items,
                                               activeTabId: 72,
                                               splitActions: []))

        XCTAssertEqual(state.tabs.map(\.guid), [71, 70, 72])
        XCTAssertEqual(state.focusingTab?.guid, 72)
        // Transaction is not latched: a later ordinary arrival still lands.
        state.handleNewTabFromChromium(
            Tab(guid: 73, url: "https://later.example", isActive: false, index: 0),
            context: NativeTabCreationContext(creationKind: .typedNewTab))
        XCTAssertTrue(state.normalTabs.map(\.guid).contains(73))
    }

    func testExactlyOneNormalTabsPublishPerRestoredWindow() throws {
        let state = try makeBrowserState()
        var publishCount = 0
        state.$normalTabs
            .dropFirst()
            .sink { _ in publishCount += 1 }
            .store(in: &cancellables)

        let items = makeItems([
            RestoreTabSpec(guid: 80),
            RestoreTabSpec(guid: 81),
            RestoreTabSpec(guid: 82),
            RestoreTabSpec(guid: 83),
            RestoreTabSpec(guid: 84),
        ])
        state.handleRestoredWindowSnapshot(
            BrowserState.RestoredWindowSnapshot(tabs: items,
                                               activeTabId: 82,
                                               splitActions: []))

        XCTAssertEqual(publishCount, 1, "restored window must publish normalTabs exactly once")
        XCTAssertEqual(state.normalTabs.map(\.guid), [80, 81, 82, 83, 84])
    }

    func testTransactionSignalFiresAfterSinglePublishInSameTurn() throws {
        let state = try makeBrowserState()
        var normalTabsAtSignal: [Int]?
        var publishesAtSignal = 0
        var publishCount = 0
        state.$normalTabs
            .dropFirst()
            .sink { _ in publishCount += 1 }
            .store(in: &cancellables)
        state.restoredWindowTransactionSignal
            .sink { [weak state] in
                normalTabsAtSignal = state?.normalTabs.map(\.guid)
                publishesAtSignal = publishCount
            }
            .store(in: &cancellables)

        state.handleRestoredWindowSnapshot(
            BrowserState.RestoredWindowSnapshot(tabs: makeItems([
                RestoreTabSpec(guid: 90),
                RestoreTabSpec(guid: 91),
            ]),
                                               activeTabId: 90,
                                               splitActions: []))

        // The signal is synchronous and observes the fully-published state.
        XCTAssertEqual(normalTabsAtSignal, [90, 91])
        XCTAssertEqual(publishesAtSignal, 1)
    }

    func testTransactionUnlatchesAndNormalUpdatesFlow() throws {
        let state = try makeBrowserState()
        state.handleRestoredWindowSnapshot(
            BrowserState.RestoredWindowSnapshot(tabs: makeItems([RestoreTabSpec(guid: 95)]),
                                               activeTabId: nil,
                                               splitActions: []))

        var publishCount = 0
        state.$normalTabs
            .dropFirst()
            .sink { _ in publishCount += 1 }
            .store(in: &cancellables)

        // Ordinary interactive arrival publishes again — a latched
        // transaction (stuck pending set) would swallow this.
        state.handleNewTabFromChromium(
            Tab(guid: 96, url: "https://after.example", isActive: false, index: 0),
            context: NativeTabCreationContext(creationKind: .typedNewTab))

        XCTAssertGreaterThanOrEqual(publishCount, 1)
        XCTAssertEqual(state.normalTabs.map(\.guid), [95, 96])
    }
    func testRemovedBatchPublishesSurvivorsOnceAndIgnoresRepeatedIDs() throws {
        let state = try makeBrowserState()
        state.handleRestoredWindowSnapshot(.init(
            tabs: makeItems((1...6).map { RestoreTabSpec(guid: $0) }),
            activeTabId: nil, splitActions: []))
        var tabPublications = [[Int]]()
        var normalPublications = [[Int]]()
        state.$tabs.dropFirst().sink { tabPublications.append($0.map(\.guid)) }
            .store(in: &cancellables)
        state.$normalTabs.dropFirst().sink { normalPublications.append($0.map(\.guid)) }
            .store(in: &cancellables)

        state.applyTabsRemoved([2, 3, 2, 5, 999])
        state.reorderTabs([1: 0, 4: 1, 6: 2])

        XCTAssertEqual(tabPublications, [[1, 4, 6]])
        XCTAssertEqual(normalPublications, [[1, 4, 6]])
        state.closeTab(4)
        XCTAssertEqual(state.tabs.map(\.guid), [1, 6], "The removal transaction must end synchronously")
    }

    func testRemovedBatchSelectionDoesNotTargetAnotherRemovedTab() throws {
        let state = try makeBrowserState()
        state.handleRestoredWindowSnapshot(.init(
            tabs: makeItems((1...4).map { RestoreTabSpec(guid: $0) }),
            activeTabId: 2, splitActions: []))
        state.applyTabsRemoved([2, 3], indices: [1: 0, 4: 1], activeTabId: 4)
        XCTAssertEqual(state.focusingTab?.guid, 4)
    }

    func testPartialGroupRemovalPublishesOnceWithoutMembershipEvents() throws {
        let state = try makeBrowserState()
        state.handleRestoredWindowSnapshot(.init(
            tabs: makeItems((1...22).map { RestoreTabSpec(guid: $0) }),
            activeTabId: 22, splitActions: []))
        state.handleTabGroupCreated(token: "A", title: "Group", color: .blue,
                                    isCollapsed: false, initialTabIds: Array(1...21))
        state.showGroupOverview(token: "A")
        let group = try XCTUnwrap(state.groups["A"])
        var publications = [[Int]]()
        var groupNotifications = 0
        state.$normalTabs.dropFirst().sink { publications.append($0.map(\.guid)) }
            .store(in: &cancellables)
        group.objectWillChange.sink { groupNotifications += 1 }.store(in: &cancellables)

        // Chromium omits tabLeftGroup for members already detached from its model.
        state.applyTabsRemoved(Array(1...20), indices: [21: 0, 22: 1])

        XCTAssertEqual(publications, [[21, 22]])
        XCTAssertEqual(groupNotifications, 0)
        XCTAssertTrue(state.groups["A"] === group)
        XCTAssertEqual(state.normalTabs.filter { $0.groupToken == "A" }.map(\.guid), [21])
        XCTAssertEqual(state.activeGroupOverviewToken, "A")
    }

    func testWholeGroupRemovalClearsOverviewWithoutMembershipEvents() throws {
        let state = try makeBrowserState()
        state.handleRestoredWindowSnapshot(.init(
            tabs: makeItems((1...21).map { RestoreTabSpec(guid: $0) }),
            activeTabId: 21, splitActions: []))
        state.handleTabGroupCreated(token: "A", title: "Group", color: .blue,
                                    isCollapsed: false, initialTabIds: Array(1...20))
        state.showGroupOverview(token: "A")
        var publications = [[Int]]()
        state.$normalTabs.dropFirst().sink { publications.append($0.map(\.guid)) }
            .store(in: &cancellables)

        // The group-closed event precedes the final removal snapshot.
        state.handleTabGroupClosed(token: "A")
        state.applyTabsRemoved(Array(1...20), indices: [21: 0])

        XCTAssertEqual(publications, [[21]])
        XCTAssertNil(state.groups["A"])
        XCTAssertNil(state.activeGroupOverviewToken)
        XCTAssertTrue(state.tabs.allSatisfy { $0.groupToken == nil })
    }

    func testUngroupingMiddleTabKeepsTabAndRemainingGroupContiguous() throws {
        let state = try makeBrowserState()
        state.handleRestoredWindowSnapshot(.init(
            tabs: makeItems((1...4).map { RestoreTabSpec(guid: $0) }),
            activeTabId: 4, splitActions: []))
        state.handleTabGroupCreated(token: "A", title: "Group", color: .blue,
                                    isCollapsed: false, initialTabIds: [1, 2, 3])
        var notifications = 0
        let group = try XCTUnwrap(state.groups["A"])
        group.objectWillChange.sink { notifications += 1 }.store(in: &cancellables)

        state.handleTabLeftGroup(tabId: 2, token: "A")

        XCTAssertEqual(state.normalTabs.map(\.guid), [1, 3, 2, 4])
        XCTAssertNil(state.tabs.first { $0.guid == 2 }?.groupToken)
        XCTAssertEqual(state.normalTabs.filter { $0.groupToken == "A" }.map(\.guid), [1, 3])
        XCTAssertEqual(notifications, 1)
    }

    func testInsertedBatchKeepsExistingTabsAndPublishesFinalOrderOnce() throws {
        let state = try makeBrowserState()
        state.handleRestoredWindowSnapshot(.init(
            tabs: makeItems([RestoreTabSpec(guid: 1), RestoreTabSpec(guid: 2)]),
            activeTabId: nil, splitActions: []))
        var tabPublications = [[Int]]()
        var normalPublications = [[Int]]()
        state.$tabs.dropFirst().sink { tabPublications.append($0.map(\.guid)) }
            .store(in: &cancellables)
        state.$normalTabs.dropFirst().sink { normalPublications.append($0.map(\.guid)) }
            .store(in: &cancellables)
        let items = [
            (Tab(guid: 3, url: "https://first.test", isActive: false, index: 1),
             NativeTabCreationContext(isActiveAtCreation: false, insertAfterTabId: 1)),
            (Tab(guid: 4, url: "https://second.test", isActive: false, index: 3),
             NativeTabCreationContext(isActiveAtCreation: true, insertAfterTabId: 2)),
        ]
        var payload = BrowserState.RestoredWindowSnapshot(tabs: items, activeTabId: 4, splitActions: [])
        payload.indices = [1: 0, 3: 1, 2: 2, 4: 3]
        state.handleInsertedTabsSnapshot(payload)

        XCTAssertEqual(tabPublications, [[1, 3, 2, 4]])
        XCTAssertEqual(normalPublications, [[1, 3, 2, 4]])
        XCTAssertEqual(state.focusingTab?.guid, 4)
    }

    func testRemovalSnapshotCrossesObjectiveCBridgeWithFinalState() throws {
        let payload = NSMutableDictionary(dictionary: [
            "removals": NSMutableArray(array: [["id": 2]]),
            "indices": NSDictionary(dictionary: [NSNumber(value: 1): NSNumber(value: 0)]),
            "activeTabId": NSNumber(value: 1),
        ])
        let action = PhiChromiumCoordinator.decodeTabRemovalSnapshot(payload as! [String: Any])
        guard case let .tabsRemoved(ids, indices, activeTabId) = action else {
            return XCTFail("Expected a removal event")
        }
        XCTAssertEqual(ids, [2])
        XCTAssertEqual(indices, [1: 0])
        XCTAssertEqual(activeTabId, 1)

        // Exercise the ObjC-to-Swift thunk used by the native framework.
        let receiver = PhiChromiumCoordinator.shared
        let selector = NSSelectorFromString("tabsRemovedSnapshot:windowId:")
        typealias Callback = @convention(c) (AnyObject, Selector, AnyObject, Int64) -> Void
        let callback = unsafeBitCast(try XCTUnwrap(receiver.method(for: selector)), to: Callback.self)
        callback(receiver, selector, payload, -1)
        XCTAssertFalse(receiver.responds(to: NSSelectorFromString("tabsRemoved:windowId:")))
    }

}

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
        // [22, 20], not [20, 22]: the pinned-bound tab is filtered out of the
        // projection as soon as it reattaches, so the next payload's anchor
        // (21) misses and the `.restore` fallback inserts at the head. This
        // is the per-tab path's long-standing behavior for a mid-strip
        // pinned binding — the transaction must reproduce it, not fix it.
        XCTAssertEqual(transactional.normalTabs.map(\.guid), [22, 20])
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
}

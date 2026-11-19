import XCTest
import ObjectiveC.runtime
@testable import Phi

/// This deliberately implements only the exercised bridge boundary. Runtime
/// conformance avoids implementing unrelated engine operations in the fixture.
private final class NewTabPlacementBridgeStub: NSObject {
    var supportsPlacement = true
    var requests: [(tab: Int, anchor: Int)] = []
    var onPlacement: ((Int, Int) -> Void)?
    var forwardingBridge: PhiChromiumBridgeProtocol?

    override func responds(to selector: Selector!) -> Bool {
        if selector == NSSelectorFromString("placeNewTabWithWindowId:tabId:beforeTabId:") {
            return supportsPlacement
        }
        return super.responds(to: selector) || forwardingBridge?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? { forwardingBridge }

    @objc(placeNewTabWithWindowId:tabId:beforeTabId:)
    func placeNewTab(windowId: Int64, tabId: Int64, anchorTabId: Int64) {
        requests.append((Int(tabId), Int(anchorTabId)))
        onPlacement?(Int(tabId), Int(anchorTabId))
    }
}

@MainActor
final class BrowserStateNewTabPlacementTests: XCTestCase {
    private var directories: [URL] = []
    private var stores: [LocalStore] = []
    private var originalBridge: PhiChromiumBridgeProtocol?
    private var previousLayout: Any?
    private var previousNewTabsAtTop: Any?

    override func setUp() async throws {
        originalBridge = ChromiumLauncher.sharedInstance().bridge
        previousLayout = UserDefaults.standard.object(forKey: PhiPreferences.GeneralSettings.layoutModeKey)
        PhiPreferences.GeneralSettings.saveLayoutMode(.performance)
        previousNewTabsAtTop = UserDefaults.standard.object(forKey: PhiPreferences.GeneralSettings.newTabsAtTop.rawValue)
        UserDefaults.standard.set(true, forKey: PhiPreferences.GeneralSettings.newTabsAtTop.rawValue)
    }

    override func tearDown() async throws {
        await drain()
        ChromiumLauncher.sharedInstance().bridge = originalBridge
        for store in stores { try await store.closeForAccountDirectoryRemoval() }
        stores.removeAll()
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories.removeAll()
        UserDefaults.standard.set(previousLayout, forKey: PhiPreferences.GeneralSettings.layoutModeKey)
        UserDefaults.standard.set(previousNewTabsAtTop, forKey: PhiPreferences.GeneralSettings.newTabsAtTop.rawValue)
    }

    private func makeState() throws -> BrowserState {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let store = LocalStore(account: Account(userID: UUID().uuidString), storeDirectoryURL: directory)
        stores.append(store)
        let state = BrowserState(windowId: -982642, localStore: store, profileId: "Default")
        state.tabs = (1...4).map { Tab(guid: $0, url: "https://example.test/\($0)", isActive: false, index: $0 - 1) }
        state.updateNormalTabs()
        return state
    }

    private func installBridge() throws -> NewTabPlacementBridgeStub {
        let bridge = NewTabPlacementBridgeStub()
        bridge.forwardingBridge = originalBridge
        let bridgeProtocol = try XCTUnwrap(objc_getProtocol("PhiChromiumBridgeProtocol"))
        class_addProtocol(NewTabPlacementBridgeStub.self, bridgeProtocol)
        ChromiumLauncher.sharedInstance().bridge = try XCTUnwrap(bridge as? PhiChromiumBridgeProtocol)
        return bridge
    }

    private func arrival(_ state: BrowserState, id: Int = 10, customGuid: String? = nil, group: String? = nil) {
        let tab = Tab(guid: id, url: "chrome://newtab", isActive: false, index: state.tabs.count, customGuid: customGuid)
        tab.groupToken = group
        state.handleNewTabFromChromium(tab, context: NativeTabCreationContext(creationKind: .typedNewTab, insertAfterTabId: 4))
    }

    private func drain() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    func testEventBusDefersCallbacksAndCompletionInFIFOOrder() async {
        var order: [Int] = []
        EventBus.shared.enqueue {
            order.append(1)
            EventBus.shared.enqueue { order.append(3) }
        }
        EventBus.shared.enqueue { order.append(2) }
        XCTAssertTrue(order.isEmpty, "Callbacks must leave Chromium's mutation stack")
        await drain()
        XCTAssertEqual(order, [1, 2, 3])
    }

    func testBottomPreferenceAppendsWithoutMovingChromiumOrChangingSplitOrder() throws {
        UserDefaults.standard.set(false, forKey: PhiPreferences.GeneralSettings.newTabsAtTop.rawValue)
        let state = try makeState()
        state.splits = [SplitGroup(id: "s", tabIds: [1, 2, 3, 4], layout: .vertical,
                                  fractions: SplitGroup.equalFractions(paneCount: 4))]
        let bridge = try installBridge()
        arrival(state)
        XCTAssertEqual(state.normalTabs.map(\.guid), [1, 2, 3, 4, 10])
        XCTAssertEqual(state.splits.first?.tabIds, [1, 2, 3, 4])
        XCTAssertTrue(bridge.requests.isEmpty)
    }

    func testDestinationComfortableLayoutOverridesTopPreference() throws {
        let destination = try makeState()
        destination.layoutMode = .comfortable
        let bridge = try installBridge()
        arrival(destination)
        XCTAssertEqual(destination.normalTabs.map(\.guid), [1, 2, 3, 4, 10])
        XCTAssertTrue(bridge.requests.isEmpty)
    }

    func testUnsetPreferencePreservesBottomDefault() throws {
        UserDefaults.standard.removeObject(forKey: PhiPreferences.GeneralSettings.newTabsAtTop.rawValue)
        XCTAssertFalse(PhiPreferences.GeneralSettings.newTabsAtTop.defaultValue)
        XCTAssertFalse(try makeState().opensNewTabsAtTop)
    }

    func testPlacementPolicyReadsCurrentDestinationLayoutAndPreference() throws {
        let destination = try makeState()
        for layout in LayoutMode.allCases {
            destination.layoutMode = layout
            UserDefaults.standard.set(true, forKey: PhiPreferences.GeneralSettings.newTabsAtTop.rawValue)
            XCTAssertEqual(destination.opensNewTabsAtTop, !layout.isTraditional)
            UserDefaults.standard.set(false, forKey: PhiPreferences.GeneralSettings.newTabsAtTop.rawValue)
            XCTAssertFalse(destination.opensNewTabsAtTop)
        }
    }

    func testTypedArrivalConsumesAddressBarClaimBeforeNextRealLink() async throws {
        let keys = [PhiPreferences.GeneralSettings.peekViewEnabled.rawValue,
                    PhiPreferences.GeneralSettings.autoPeekViewEnabled.rawValue]
        let previous = keys.map { UserDefaults.standard.object(forKey: $0) }
        keys.forEach { UserDefaults.standard.set(true, forKey: $0) }
        defer { for (key, value) in zip(keys, previous) { UserDefaults.standard.set(value, forKey: key) } }
        let state = try makeState()
        _ = try installBridge()
        let opener = Tab(guid: 9, url: "https://bound.example", isActive: true,
                         index: 4, customGuid: "pinned-opener")
        opener.isPinned = true
        state.tabs.append(opener)
        state.pinnedTabs = [opener]
        state.noteAddressBarWillOpenNewTab(openerTabId: 9)
        state.handleNewTabFromChromium(
            Tab(guid: 10, url: "https://typed.example", isActive: false, index: 5),
            context: NativeTabCreationContext(creationKind: .typedNavigation, openerTabId: 9))
        state.handleNewTabFromChromium(
            Tab(guid: 11, url: "https://link.example", isActive: false, index: 6),
            context: NativeTabCreationContext(creationKind: .linkForeground, openerTabId: 9))
        XCTAssertTrue(state.tabs.contains { $0.guid == 10 })
        XCTAssertFalse(state.tabs.contains { $0.guid == 11 }, "The next real link must remain eligible for Peek")
        await drain()
    }

    func testRapidCreationsSurviveQueuedOldIndicesAndBothCompletions() async throws {
        let state = try makeState()
        let bridge = try installBridge()
        bridge.onPlacement = { id, _ in
            let indices = id == 10
                ? [10: 0, 1: 1, 2: 2, 3: 3, 4: 4, 11: 5]
                : [11: 0, 10: 1, 1: 2, 2: 3, 3: 4, 4: 5]
            DispatchQueue.main.async { state.reorderTabs(indices) }
        }
        DispatchQueue.main.async { self.arrival(state, id: 10) }
        DispatchQueue.main.async { state.reorderTabs([1: 0, 2: 1, 3: 2, 4: 3, 10: 4]) }
        DispatchQueue.main.async { self.arrival(state, id: 11) }
        DispatchQueue.main.async { state.reorderTabs([1: 0, 2: 1, 3: 2, 4: 3, 10: 4, 11: 5]) }
        await drain()
        XCTAssertEqual(bridge.requests.map(\.tab), [10, 11])
        XCTAssertEqual(bridge.requests.map(\.anchor), [1, 10])
        XCTAssertEqual(state.normalTabs.map(\.guid), [11, 10, 1, 2, 3, 4])
        state.reorderTabs([1: 0, 2: 1, 3: 2, 4: 3, 10: 4, 11: 5])
        XCTAssertEqual(state.normalTabs.map(\.guid), [1, 2, 3, 4, 10, 11], "Completion must release protection")
    }

    func testCloseBetweenEchoAndCompletionCannotResurrectTab() async throws {
        let state = try makeState()
        let bridge = try installBridge()
        bridge.onPlacement = { _, _ in
            DispatchQueue.main.async { state.reorderTabs([10: 0, 1: 1, 2: 2, 3: 3, 4: 4]) }
            DispatchQueue.main.async { state.closeTab(10) }
        }
        arrival(state)
        await drain()
        XCTAssertEqual(state.normalTabs.map(\.guid), [1, 2, 3, 4])
        XCTAssertFalse(state.tabs.contains { $0.guid == 10 })
    }

    func testTransferBetweenEchoAndCompletionLeavesDestinationOrderAlone() async throws {
        let source = try makeState()
        let destination = try makeState()
        let bridge = try installBridge()
        bridge.onPlacement = { _, _ in
            EventBus.shared.enqueue { source.reorderTabs([10: 0, 1: 1, 2: 2, 3: 3, 4: 4]) }
            EventBus.shared.enqueue {
                source.applyTabsRemoved([10], indices: [1: 0, 2: 1, 3: 2, 4: 3], activeTabId: nil)
                destination.handleNewTabFromChromium(
                    Tab(guid: 10, url: "https://example.test", isActive: false, index: 4),
                    context: NativeTabCreationContext(creationKind: .moveFromOtherWindow, insertAfterTabId: 4))
            }
        }
        arrival(source)
        await drain()
        XCTAssertEqual(source.normalTabs.map(\.guid), [1, 2, 3, 4])
        XCTAssertEqual(destination.normalTabs.map(\.guid), [1, 2, 3, 4, 10])
        XCTAssertEqual(bridge.requests.count, 1)
    }

    func testNewTabAfterBookmarkSplitPromotionUsesUpdatedThreeAndFourPaneBoundary() throws {
        for count in [3, 4] {
            ChromiumLauncher.sharedInstance().bridge = originalBridge
            let state = try makeState()
            let ids = Array(1...count)
            state.splits = [SplitGroup(id: "s", tabIds: ids, layout: .vertical,
                                      fractions: SplitGroup.equalFractions(paneCount: count))]
            state.splitBookmarkBindings["bookmark"] = "s"
            state.updateNormalTabs()
            XCTAssertTrue(state.makeSplitNormalOpened("s"))
            let reversed = Array(ids.reversed())
            state.handleSplitContentsChanged(splitId: "s", tabIds: reversed)
            let physical = reversed + (count == 3 ? [4] : [])
            state.reorderTabs(Dictionary(uniqueKeysWithValues: physical.enumerated().map { ($0.element, $0.offset) }))
            let bridge = try installBridge()
            arrival(state)
            XCTAssertEqual(bridge.requests.map(\.anchor), [count])
            XCTAssertEqual(state.normalTabs.map(\.guid), [10] + physical)
            XCTAssertEqual(state.splits.first?.tabIds, reversed)
        }
    }

    func testNewTabAfterPinnedSplitPromotionKeepsEveryPaneTogether() throws {
        for count in [3, 4] {
            ChromiumLauncher.sharedInstance().bridge = originalBridge
            let state = try makeState()
            let ids = Array(1...count)
            let dbIDs = ids.map { "pin-\($0)" }
            state.pinnedTabs = ids.enumerated().map { offset, id in
                let record = Tab(guid: id, url: "https://example.test/\(id)", isActive: false,
                                 index: offset, customGuid: dbIDs[offset])
                record.isOpenned = true
                record.splitPaneGuids = dbIDs
                return record
            }
            for (offset, id) in ids.enumerated() {
                let live = try XCTUnwrap(state.tabs.first { $0.guid == id })
                live.guidInLocalDB = dbIDs[offset]
                live.isPinned = true
            }
            state.splits = [SplitGroup(id: "s", tabIds: ids, layout: .vertical,
                                      fractions: SplitGroup.equalFractions(paneCount: count), isPinned: true)]
            state.updateNormalTabs()
            XCTAssertTrue(state.makeSplitNormalOpened("s"))
            XCTAssertEqual(state.splits.first?.isPinned, false)
            let reversed = Array(ids.reversed())
            state.handleSplitContentsChanged(splitId: "s", tabIds: reversed)
            let physical = reversed + (count == 3 ? [4] : [])
            state.reorderTabs(Dictionary(uniqueKeysWithValues: physical.enumerated().map { ($0.element, $0.offset) }))
            let bridge = try installBridge()
            arrival(state)
            XCTAssertEqual(bridge.requests.map(\.anchor), [count])
            XCTAssertEqual(state.normalTabs.map(\.guid), [10] + physical)
            XCTAssertEqual(state.splits.first?.tabIds, reversed)
        }
    }

    func testUnknownCreationDoesNotOverrideAnExplicitPhysicalAnchor() throws {
        let state = try makeState()
        let bridge = try installBridge()
        state.handleNewTabFromChromium(
            Tab(guid: 10, url: "about:blank", isActive: false, index: 2),
            context: NativeTabCreationContext(creationKind: .unknown, insertAfterTabId: 2))
        XCTAssertTrue(bridge.requests.isEmpty)
        XCTAssertEqual(state.normalTabs.map(\.guid), [1, 2, 10, 3, 4])
    }

    func testOldFrameworkDoesNotPublishUnsupportedPlacement() throws {
        let state = try makeState()
        let bridge = try installBridge()
        bridge.supportsPlacement = false
        arrival(state)
        XCTAssertTrue(bridge.requests.isEmpty)
        XCTAssertEqual(state.normalTabs.map(\.guid), [1, 2, 3, 4, 10])
    }

    func testStructuredAndExplicitCreationsNeverUseOrdinaryPlacement() throws {
        let state = try makeState()
        let bridge = try installBridge()
        arrival(state, id: 10, customGuid: "split-seed")
        arrival(state, id: 11, group: "group")
        state.scheduleNormalTabInsertion(tabGuid: 12, at: 2)
        arrival(state, id: 12)
        XCTAssertTrue(bridge.requests.isEmpty)
        XCTAssertEqual(state.normalTabs.firstIndex { $0.guid == 12 }, 2)
    }

    func testMalformedTypedSnapshotNeverCallsBackIntoChromium() throws {
        let state = try makeState()
        let bridge = try installBridge()
        let tab = Tab(guid: 10, url: "chrome://newtab", isActive: false, index: 4)
        state.handleRestoredWindowSnapshot(.init(
            tabs: [(tab, NativeTabCreationContext(creationKind: .typedNewTab, insertAfterTabId: 4))],
            activeTabId: nil, splitActions: [], indices: [1: 0, 2: 1, 3: 2, 4: 3, 10: 4]))
        XCTAssertTrue(bridge.requests.isEmpty)
        XCTAssertEqual(state.normalTabs.map(\.guid), [1, 2, 3, 4, 10])
    }

    func testNewTabBeforeReversedFourPaneSplitUsesWholeSplitAnchor() throws {
        let state = try makeState()
        state.splits = [SplitGroup(id: "s", tabIds: [1, 2, 3, 4], layout: .vertical, fractions: [0.25, 0.25, 0.25, 0.25])]
        state.handleSplitContentsChanged(splitId: "s", tabIds: [4, 3, 2, 1])
        state.reorderTabs([4: 0, 3: 1, 2: 2, 1: 3])
        let bridge = try installBridge()
        arrival(state)
        XCTAssertEqual(bridge.requests.map(\.anchor), [4])
        XCTAssertEqual(state.normalTabs.map(\.guid), [10, 4, 3, 2, 1])
        XCTAssertEqual(state.splits.first?.tabIds, [4, 3, 2, 1])
    }
}

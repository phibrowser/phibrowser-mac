// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

@MainActor
final class TabSwitchManagerTests: XCTestCase {
    private var tempDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    private func makeState(recordInitialVisits: Bool = true) throws -> BrowserState {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        let store = LocalStore(account: Account(userID: UUID().uuidString),
                               storeDirectoryURL: directory)
        let state = BrowserState(windowId: 7, localStore: store, profileId: "Default")
        state.tabs = [makeTab(1), makeTab(2)]
        state.updateNormalTabs()
        if recordInitialVisits {
            state.focuseTab(state.tabs[1])
            state.focuseTab(state.tabs[0])
        }
        return state
    }

    private func makeTab(_ id: Int) -> Tab {
        Tab(guid: id, url: "https://example.com/\(id)", isActive: false, index: id - 1)
    }

    private func openBackgroundTab(_ id: Int, in state: BrowserState) {
        state.handleNewTabFromChromium(
            makeTab(id),
            context: NativeTabCreationContext(creationKind: .linkBackground, openerTabId: 1)
        )
    }

    func testBackgroundLinkBecomesNextCandidateWithoutTakingFocus() throws {
        let state = try makeState()

        openBackgroundTab(3, in: state)

        XCTAssertEqual(state.tabSwitchManager.recentTabIDs, [1, 3, 2])
        XCTAssertEqual(state.tabSwitchManager.visitedTabIDs, [1, 2])
        XCTAssertEqual(state.focusingTab?.guid, 1)
        XCTAssertFalse(try XCTUnwrap(state.tabs.first { $0.guid == 3 }).isActive)
    }

    func testNewestBackgroundLinksTakePriorityAndPreserveHistoryLimit() throws {
        let state = try makeState()

        for id in 3...8 {
            openBackgroundTab(id, in: state)
        }

        XCTAssertEqual(state.tabSwitchManager.recentTabIDs, [1, 8, 7, 6, 5])
        XCTAssertEqual(state.tabSwitchManager.recentTabIDs.count, TabSwitchMetrics.maxRecentTabs)
        XCTAssertEqual(state.tabSwitchManager.visitedTabIDs, [1, 2],
                       "Background arrivals are not visits, even when they displace visited switcher entries")
        XCTAssertEqual(state.focusingTab?.guid, 1)
    }

    func testBackgroundAdmissionDeduplicatesHistoryOutsideSwitcherLimit() throws {
        let state = try makeState()
        for id in 3...8 {
            openBackgroundTab(id, in: state)
            state.focuseTab(try XCTUnwrap(state.tabs.first { $0.guid == id }))
        }
        state.focuseTab(state.tabs[0])
        let manager = state.tabSwitchManager
        let history = manager.visitedTabIDs

        manager.recordBackgroundTab(try XCTUnwrap(state.tabs.first { $0.guid == 3 }))

        XCTAssertEqual(manager.visitedTabIDs, history)
        XCTAssertEqual(manager.recentTabIDs, [1, 8, 7, 6, 5])
    }

    func testBackgroundArrivalsPreserveCompleteMediaVisitOrder() throws {
        let state = try makeState()
        for id in 3...8 {
            openBackgroundTab(id, in: state)
            state.focuseTab(try XCTUnwrap(state.tabs.first { $0.guid == id }))
        }
        let manager = state.tabSwitchManager
        XCTAssertEqual(manager.visitedTabIDs, [8, 7, 6, 5, 4, 3, 1, 2])

        for id in 9...14 {
            openBackgroundTab(id, in: state)
        }

        XCTAssertEqual(manager.recentTabIDs, [8, 14, 13, 12, 11])
        XCTAssertEqual(manager.visitedTabIDs, [8, 7, 6, 5, 4, 3, 1, 2])
    }

    func testBackgroundArrivalWithoutFocusDoesNotInventVisits() throws {
        let state = try makeState(recordInitialVisits: false)

        openBackgroundTab(3, in: state)
        state.tabSwitchManager.recordBackgroundTab(try XCTUnwrap(state.tabs.first { $0.guid == 3 }))

        XCTAssertEqual(state.tabSwitchManager.recentTabIDs, [3])
        XCTAssertTrue(state.tabSwitchManager.visitedTabIDs.isEmpty)
        XCTAssertNil(state.focusingTab)
    }

    func testStaleTabsArePrunedFromBothHistories() throws {
        let state = try makeState()
        openBackgroundTab(3, in: state)
        state.tabs.removeAll { $0.guid == 2 || $0.guid == 3 }

        openBackgroundTab(4, in: state)

        XCTAssertEqual(state.tabSwitchManager.recentTabIDs, [1, 4])
        XCTAssertEqual(state.tabSwitchManager.visitedTabIDs, [1])
    }

    func testVisitingBackgroundTabResumesMRUOrdering() throws {
        let state = try makeState()
        openBackgroundTab(3, in: state)
        openBackgroundTab(4, in: state)

        state.focuseTab(try XCTUnwrap(state.tabs.first { $0.guid == 3 }))

        XCTAssertEqual(state.tabSwitchManager.recentTabIDs, [3, 1, 4, 2])
        XCTAssertEqual(state.tabSwitchManager.visitedTabIDs, [3, 1, 2])
        state.tabSwitchManager.removeTab(tabID: 4)
        XCTAssertEqual(state.tabSwitchManager.recentTabIDs, [3, 1, 2])
        XCTAssertEqual(state.tabSwitchManager.visitedTabIDs, [3, 1, 2])
        state.tabSwitchManager.removeTab(tabID: 3)
        XCTAssertEqual(state.tabSwitchManager.recentTabIDs, [1, 2])
        XCTAssertEqual(state.tabSwitchManager.visitedTabIDs, [1, 2])
    }

    func testOtherCreationKindsDoNotEnterHistoryBeforeActivation() throws {
        let state = try makeState()
        let kinds: [NativeTabCreationKind] = [
            .linkForeground, .typedNewTab, .typedNavigation, .explicitInsert,
            .moveFromOtherWindow, .restore, .bridgeCreate, .unknown,
        ]
        for (index, kind) in kinds.enumerated() {
            state.handleNewTabFromChromium(
                makeTab(index + 3),
                context: NativeTabCreationContext(creationKind: kind)
            )
        }
        state.handleNewTabFromChromium(makeTab(20))
        state.handleNewTabFromChromium(
            makeTab(21),
            context: NativeTabCreationContext(isActiveAtCreation: true, creationKind: .linkBackground)
        )

        XCTAssertEqual(state.tabSwitchManager.recentTabIDs, [1, 2])
    }

    func testBackgroundAdmissionIgnoresForeignTabsAndExistingHistory() throws {
        let state = try makeState()
        openBackgroundTab(3, in: state)
        openBackgroundTab(4, in: state)
        let manager = state.tabSwitchManager

        manager.recordBackgroundTab(makeTab(99))
        manager.recordBackgroundTab(state.tabs[0])
        manager.recordBackgroundTab(try XCTUnwrap(state.tabs.first { $0.guid == 3 }))

        XCTAssertEqual(manager.recentTabIDs, [1, 4, 3, 2])
    }

    func testBackgroundAIChatNeverEntersHistory() throws {
        let state = try makeState()
        let tab = makeTab(3)
        tab.guidInLocalDB = BrowserState.aiChatId(for: "test")

        state.handleNewTabFromChromium(
            tab,
            context: NativeTabCreationContext(creationKind: .linkBackground, openerTabId: 1)
        )

        XCTAssertEqual(state.tabSwitchManager.recentTabIDs, [1, 2])
        XCTAssertFalse(state.tabs.contains { $0.guid == 3 })
    }
}

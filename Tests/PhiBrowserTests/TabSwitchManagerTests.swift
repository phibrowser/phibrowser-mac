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

    private func makeState() throws -> BrowserState {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        let store = LocalStore(account: Account(userID: UUID().uuidString),
                               storeDirectoryURL: directory)
        let state = BrowserState(windowId: 7, localStore: store, profileId: "Default")
        state.tabs = [makeTab(1), makeTab(2)]
        state.updateNormalTabs()
        state.focuseTab(state.tabs[1])
        state.focuseTab(state.tabs[0])
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
        XCTAssertEqual(state.focusingTab?.guid, 1)
    }

    func testVisitingBackgroundTabResumesMRUOrdering() throws {
        let state = try makeState()
        openBackgroundTab(3, in: state)
        openBackgroundTab(4, in: state)

        state.focuseTab(try XCTUnwrap(state.tabs.first { $0.guid == 3 }))

        XCTAssertEqual(state.tabSwitchManager.recentTabIDs, [3, 1, 4, 2])
        state.tabSwitchManager.removeTab(tabID: 4)
        XCTAssertEqual(state.tabSwitchManager.recentTabIDs, [3, 1, 2])
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

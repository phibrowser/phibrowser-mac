// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

/// Each Space can fix how many pinned tabs share a sidebar row and how far
/// apart they sit. A Space never set keeps the grid as it was.
@MainActor
final class PinnedTabGridStyleTests: XCTestCase {
    /// The pinned grid's width in the default sidebar.
    private let sidebarWidth: CGFloat = 204

    // MARK: - Layout

    func testAnAutomaticGridKeepsThreePinsPerRowAtTheUsualSidebarWidth() {
        let grid = PinnedTabLayout.tabGrid(itemCount: 6, contentWidth: sidebarWidth, style: .automatic)
        XCTAssertEqual(grid.columns, 3)
        XCTAssertEqual(grid.itemWidth, (sidebarWidth - 16 - 2 * 8) / 3, accuracy: 0.001)
    }

    func testAnAutomaticGridStillStretchesAFewPinsAcrossTheRow() {
        let grid = PinnedTabLayout.tabGrid(itemCount: 2, contentWidth: sidebarWidth, style: .automatic)
        XCTAssertEqual(grid.columns, 2)
        XCTAssertEqual(grid.itemWidth, (sidebarWidth - 16 - 8) / 2, accuracy: 0.001)
    }

    func testAFixedCountPutsThatManyPinsInARowBelowTheAutomaticMinimumWidth() {
        let style = PinnedTabGridStyle(columns: 5)
        let grid = PinnedTabLayout.tabGrid(itemCount: 12, contentWidth: sidebarWidth, style: style)
        XCTAssertEqual(grid.columns, 5)
        XCTAssertEqual(grid.itemWidth, (sidebarWidth - 16 - 4 * 8) / 5, accuracy: 0.001)
        XCTAssertLessThan(grid.itemWidth, 53)
    }

    func testAFixedCountKeepsTheTileWidthWhenThereAreFewerPinsThanColumns() {
        let style = PinnedTabGridStyle(columns: 5)
        let few = PinnedTabLayout.tabGrid(itemCount: 2, contentWidth: sidebarWidth, style: style)
        let many = PinnedTabLayout.tabGrid(itemCount: 12, contentWidth: sidebarWidth, style: style)
        XCTAssertEqual(few.columns, 5)
        XCTAssertEqual(few.itemWidth, many.itemWidth, accuracy: 0.001)
    }

    func testCompactSpacingNarrowsTheGapAndWidensTheTiles() {
        let standard = PinnedTabLayout.tabGrid(itemCount: 12, contentWidth: sidebarWidth, style: PinnedTabGridStyle(columns: 5))
        let compact = PinnedTabLayout.tabGrid(
            itemCount: 12, contentWidth: sidebarWidth, style: PinnedTabGridStyle(columns: 5, spacing: .compact))
        XCTAssertEqual(PinnedTabGridStyle.Spacing.compact.points, 4)
        XCTAssertEqual(compact.itemWidth - standard.itemWidth, 4 * 4 / 5, accuracy: 0.001)
    }

    // MARK: - Storage

    func testASpaceWithoutAStyleUsesTheAutomaticGrid() async throws {
        let (manager, cleanUp) = makeManager()
        XCTAssertEqual(manager.pinnedTabGridStyle(forSpaceId: "never-set"), .automatic)
        try await cleanUp()
    }

    func testEachSpaceKeepsItsOwnStyleAndTellsItsSidebars() async throws {
        let (manager, cleanUp) = makeManager()
        let compactFive = PinnedTabGridStyle(columns: 5, spacing: .compact)
        let changed = expectation(forNotification: .pinnedTabGridStyleDidChange, object: manager) { notification in
            notification.userInfo?["spaceIds"] as? [String] == ["first"]
        }

        manager.setPinnedTabGridStyle(compactFive, forSpaceId: "first")

        await fulfillment(of: [changed], timeout: 1)
        XCTAssertEqual(manager.pinnedTabGridStyle(forSpaceId: "first"), compactFive)
        XCTAssertEqual(manager.pinnedTabGridStyle(forSpaceId: "second"), .automatic)
        try await cleanUp()
    }

    func testGoingBackToAutomaticDropsTheSpacesEntry() async throws {
        let (manager, account, cleanUp) = makeManagerAndAccount()
        manager.setPinnedTabGridStyle(PinnedTabGridStyle(columns: 4), forSpaceId: "first")
        manager.setPinnedTabGridStyle(.automatic, forSpaceId: "first")
        XCTAssertNil(account.userDefaults.spacePinnedTabGridStyles()["first"])
        try await cleanUp()
    }

    func testDeletingASpaceForgetsItsStyle() async throws {
        let (manager, account, cleanUp) = makeManagerAndAccount()
        manager.setPinnedTabGridStyle(PinnedTabGridStyle(columns: 6), forSpaceId: "gone")
        manager.clearThemeRecords(forSpaceId: "gone")
        XCTAssertNil(account.userDefaults.spacePinnedTabGridStyles()["gone"])
        try await cleanUp()
    }

    func testApplyingToAllSpacesCopiesTheStyleOnceAndLeavesEachSpaceItsOwn() async throws {
        let (manager, cleanUp) = makeManager()
        for id in ["first", "second", "third"] {
            _ = manager.createSpace(name: id, colorHex: "#3A6FF8", iconName: "star", profileId: "Default",
                                    makeDefaultActive: false, spaceId: id)
        }
        let ids = manager.spaces.map(\.spaceId)
        XCTAssertTrue(Set(["first", "second", "third"]).isSubset(of: Set(ids)))
        let compactFour = PinnedTabGridStyle(columns: 4, spacing: .compact)
        manager.setPinnedTabGridStyle(compactFour, forSpaceId: "first")

        manager.applyPinnedTabGridStyleToAllSpaces(from: "first", parts: [.columns, .spacing])
        XCTAssertEqual(manager.pinnedTabGridStyle(forSpaceId: "second"), compactFour)
        XCTAssertEqual(manager.pinnedTabGridStyle(forSpaceId: "third"), compactFour)

        manager.setPinnedTabGridStyle(.automatic, forSpaceId: "first")
        XCTAssertEqual(manager.pinnedTabGridStyle(forSpaceId: "second"), compactFour)
        try await cleanUp()
    }

    func testApplyingOnlyOneSettingLeavesEachSpacesOtherSettingAlone() async throws {
        let (manager, cleanUp) = makeManager()
        for id in ["first", "second"] {
            _ = manager.createSpace(name: id, colorHex: "#3A6FF8", iconName: "star", profileId: "Default",
                                    makeDefaultActive: false, spaceId: id)
        }
        manager.setPinnedTabGridStyle(PinnedTabGridStyle(columns: 5, spacing: .compact), forSpaceId: "first")
        manager.setPinnedTabGridStyle(PinnedTabGridStyle(columns: 3), forSpaceId: "second")

        manager.applyPinnedTabGridStyleToAllSpaces(from: "first", parts: .spacing)
        XCTAssertEqual(manager.pinnedTabGridStyle(forSpaceId: "second"), PinnedTabGridStyle(columns: 3, spacing: .compact))

        manager.setPinnedTabGridStyle(PinnedTabGridStyle(columns: 5), forSpaceId: "first")
        manager.applyPinnedTabGridStyleToAllSpaces(from: "first", parts: .columns)
        XCTAssertEqual(manager.pinnedTabGridStyle(forSpaceId: "second"), PinnedTabGridStyle(columns: 5, spacing: .compact))
        try await cleanUp()
    }

    // MARK: - Helpers

    private func makeManager() -> (SpaceManager, () async throws -> Void) {
        let (manager, _, cleanUp) = makeManagerAndAccount()
        return (manager, cleanUp)
    }

    private func makeManagerAndAccount() -> (SpaceManager, Account, () async throws -> Void) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let account = Account(userID: "pinned-grid-test-" + UUID().uuidString)
        let store = LocalStore(account: account, storeDirectoryURL: directory, presentsCompatibilityAlerts: false)
        account.localStorage = store
        let manager = SpaceManager.makeForTesting(boundTo: account)
        return (manager, account, {
            try await store.closeForAccountDirectoryRemoval()
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: account.userDataStorage)
        })
    }
}

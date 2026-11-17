// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// A Peek open over a pane of a split comes back over that pane when the
/// window is restored, as a Peek over a single tab does. The pane and its
/// Peek name each other through the markers saved with the session.
@MainActor
final class BrowserStatePeekSplitRestoreTests: XCTestCase {
    private let peekKey = PhiPreferences.GeneralSettings.peekViewEnabled.rawValue
    private var originalPeek: Any?
    private var originalLayoutRawValue: String?
    private var tempDirectories: [URL] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalPeek = UserDefaults.standard.object(forKey: peekKey)
        UserDefaults.standard.set(true, forKey: peekKey)
        originalLayoutRawValue = UserDefaults.standard.string(forKey: PhiPreferences.GeneralSettings.layoutModeKey)
        PhiPreferences.GeneralSettings.saveLayoutMode(.performance)
    }

    override func tearDownWithError() throws {
        if let originalPeek {
            UserDefaults.standard.set(originalPeek, forKey: peekKey)
        } else {
            UserDefaults.standard.removeObject(forKey: peekKey)
        }
        if let originalLayoutRawValue {
            UserDefaults.standard.set(originalLayoutRawValue,
                                      forKey: PhiPreferences.GeneralSettings.layoutModeKey)
        } else {
            UserDefaults.standard.removeObject(forKey: PhiPreferences.GeneralSettings.layoutModeKey)
        }
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification,
                                        object: UserDefaults.standard)
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
        try super.tearDownWithError()
    }

    // MARK: - Restoring

    /// A pane of a normal split, or of a split behind a split-view
    /// bookmark: the pane has no record, so it carries an opener marker.
    func testPeekOverAnUnboundSplitPaneIsRestoredOverThatPane() throws {
        let state = try makeState()
        let marker = BrowserState.peekOpenerGuidPrefix + "pair"

        restoreWindow(into: state, paneBinding: marker)

        XCTAssertTrue(waitUntil { state.peekState.peek(forOpener: 51)?.guid == 60 })
        XCTAssertEqual(state.tabs.map(\.guid), [50, 51, 52], "The Peek is not a tab of the window")
        XCTAssertEqual(state.tabs.first { $0.guid == 51 }?.guidInLocalDB, marker)
        XCTAssertEqual(state.peekState.peek(forOpener: 51)?.guidInLocalDB,
                       BrowserState.peekTabGuidPrefix + marker,
                       "Both keep their markers for the next restore")
    }

    /// A pane of a pinned split is bound to its pinned record.
    func testPeekOverASplitPaneBoundToARecordIsRestoredOverThatPane() throws {
        let state = try makeState()

        restoreWindow(into: state, paneBinding: "pin")

        XCTAssertTrue(waitUntil { state.peekState.peek(forOpener: 51)?.guid == 60 })
        XCTAssertEqual(state.tabs.map(\.guid), [50, 51, 52])
        XCTAssertEqual(state.peekState.peek(forOpener: 51)?.guidInLocalDB,
                       BrowserState.peekTabGuidPrefix + "pin")
    }

    // MARK: - Marking

    func testPeekOpenedOverAnUnboundSplitPaneMarksThePaneAndNamesIt() throws {
        let state = try makeStateWithSplit()
        let peek = Tab(guid: 60, url: "https://peek.example", isActive: false, index: 0)

        state.stampPeekRestoreBinding(on: peek, openerTabId: 51)

        let marker = try XCTUnwrap(state.tabs.first { $0.guid == 51 }?.guidInLocalDB)
        XCTAssertTrue(BrowserState.isPeekOpenerGuid(marker))
        XCTAssertEqual(peek.guidInLocalDB, BrowserState.peekTabGuidPrefix + marker)
        XCTAssertNil(state.tabs.first { $0.guid == 52 }?.guidInLocalDB, "The other pane is left alone")
    }

    /// Unpinning a split clears each pane's binding; a pane under a Peek
    /// then needs a marker for the Peek to name.
    func testClearingTheBindingOfASplitPaneUnderAPeekLeavesItAnOpenerMarker() throws {
        let state = try makeStateWithSplit()
        let pane = try XCTUnwrap(state.tabs.first { $0.guid == 51 })
        pane.guidInLocalDB = "pin"
        let peek = Tab(guid: 60, url: "https://peek.example", isActive: false, index: 0,
                       customGuid: BrowserState.peekTabGuidPrefix + "pin")
        state.peekState.present(peek, openerTabId: 51)

        state.setBinding(nil, for: pane)

        let marker = try XCTUnwrap(pane.guidInLocalDB)
        XCTAssertTrue(BrowserState.isPeekOpenerGuid(marker))
        XCTAssertEqual(peek.guidInLocalDB, BrowserState.peekTabGuidPrefix + marker)
    }

    // MARK: - Helpers

    private func makeState() throws -> BrowserState {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        let store = LocalStore(account: Account(userID: UUID().uuidString),
                               storeDirectoryURL: directory)
        return BrowserState(windowId: 7, localStore: store, profileId: "Default")
    }

    /// Tabs 50, 51 and 52, the last two as the split "split-1".
    private func makeStateWithSplit() throws -> BrowserState {
        let state = try makeState()
        state.tabs = [50, 51, 52].map { Tab(guid: $0, url: "https://e\($0).example", isActive: false, index: $0) }
        state.handleSplitCreated(splitId: "split-1", tabIds: [51, 52],
                                 layout: .vertical, fractions: [0.5, 0.5])
        return state
    }

    /// Restores tabs 50, 51 and 52, the last two as the split "split-1",
    /// and tab 60: the Peek that was open over pane 51, whose saved binding
    /// is `paneBinding`.
    private func restoreWindow(into state: BrowserState, paneBinding: String) {
        let customGuids: [Int: String] = [51: paneBinding,
                                          60: BrowserState.peekTabGuidPrefix + paneBinding]
        var previousGuid: Int?
        let items = [50, 51, 52, 60].map { guid -> (tab: Tab, context: NativeTabCreationContext) in
            let tab = Tab(guid: guid, url: "https://e\(guid).example", isActive: false, index: 0,
                          customGuid: customGuids[guid])
            let context = NativeTabCreationContext(isActiveAtCreation: false,
                                                   creationKind: .restore,
                                                   insertAfterTabId: previousGuid)
            previousGuid = guid
            return (tab, context)
        }
        state.handleRestoredWindowSnapshot(BrowserState.RestoredWindowSnapshot(
            tabs: items,
            activeTabId: 51,
            splitActions: [.created(splitId: "split-1", tabIds: [51, 52],
                                    layout: .vertical, fractions: [0.5, 0.5])]))
    }

    /// The host app is still launching while these tests run, and one of its
    /// main-thread tasks can outlast a whole short timeout inside a single
    /// run-loop pass: the condition is read again after the deadline.
    private func waitUntil(timeout: TimeInterval = 5, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }
}

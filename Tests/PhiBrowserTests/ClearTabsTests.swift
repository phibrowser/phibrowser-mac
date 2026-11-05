// Copyright 2026 Phinomenon Inc.
// Use of this source code is governed by an Apache license in the LICENSE file.

import AppKit
import Combine
import Lottie
import XCTest
@testable import Phi

private final class ClearTabsRecordingState: BrowserState {
    var closeRequests: [[Int]] = []
    var cancelledIDs = Set<Int>()
    var nextID = 1000

    override func closeTabs(_ tabs: [Tab]) {
        MainActor.assumeIsolated {
            closeRequests.append(tabs.map(\.guid))
            let removed = Set(tabs.map(\.guid)).subtracting(cancelledIDs)
            recordClearedTabs(removed)
            self.tabs.removeAll { removed.contains($0.guid) }
            splits.removeAll { !removed.isDisjoint(with: $0.tabIds) }
            updateNormalTabs()
        }
    }

    override func restoreTabs(order: [[AnyHashable: Any]],
                              groups: [[AnyHashable: Any]],
                              splits: [[AnyHashable: Any]]) -> [String: Int] {
        MainActor.assumeIsolated {
            var restored: [String: Int] = [:]
            var previous: Int?
            for (offset, entry) in order.enumerated() {
                if let id = entry["tabId"] as? Int {
                    previous = id
                    continue
                }
                guard let key = entry["key"] as? String else { continue }
                nextID += 1
                let tab = Tab(guid: nextID, url: entry["url"] as? String, isActive: false, index: 0,
                              title: entry["title"] as? String ?? "")
                let next = order[(offset + 1)...].lazy.compactMap { $0["tabId"] as? Int }.first
                let index = previous.flatMap { id in tabs.firstIndex { $0.guid == id }.map { $0 + 1 } }
                    ?? next.flatMap { id in tabs.firstIndex { $0.guid == id } }
                    ?? tabs.count
                tabs.insert(tab, at: index)
                restored[key] = tab.guid
                previous = tab.guid
            }
            updateNormalTabs()
            reorderTabs(Dictionary(uniqueKeysWithValues: tabs.enumerated().map { ($1.guid, $0) }))
            return restored
        }
    }
}

@MainActor
final class ClearTabsTests: XCTestCase {
    private var directory: URL!
    private var accountDirectory: URL!
    private var store: LocalStore!
    private var state: ClearTabsRecordingState!
    private var controller: SpaceSessionController!
    private var window: NSWindow!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let account = Account(userID: "clear-tabs-test-\(UUID().uuidString)")
        accountDirectory = account.userDataStorage
        store = LocalStore(account: account, storeDirectoryURL: directory, presentsCompatibilityAlerts: false)
        account.localStorage = store
        state = ClearTabsRecordingState(windowId: 987654390, localStore: store,
                                        profileId: LocalStore.defaultProfileId, spaceId: UUID().uuidString)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        controller = SpaceSessionController(window: window, windowId: state.windowId,
            profileId: state.profileId, spaceId: state.spaceId, account: account, browserState: state, dormant: true)
    }

    override func tearDown() async throws {
        state.clearTabsUndoManager.removeAllActions()
        controller.discardDormant()
        window.close()
        controller = nil
        state = nil
        window = nil
        let drained = expectation(description: "Cleanup fixture UI updates drained")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
        try await store.closeForAccountDirectoryRemoval()
        store = nil
        for url in [directory, accountDirectory].compactMap({ $0 })
        where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func seed(_ count: Int) {
        state.tabs = (1...count).map { Tab(guid: $0, url: "https://example.test/\($0)", isActive: $0 == 1,
                                         index: $0 - 1, title: "Tab \($0)") }
        state.updateNormalTabs()
        state.focusingTab = state.tabs[0]
    }

    private func waitForRestore() async throws {
        for _ in 0..<100 where state.isRestoringClearedTabs {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(state.isRestoringClearedTabs)
    }

    func testClearKeepsBothForegroundSplitPanesAndPinnedTabs() {
        seed(5)
        state.splits = [SplitGroup(id: "foreground", tabIds: [1, 2],
                                  layout: .vertical, fractions: [0.4, 0.6], isPinned: false)]
        state.tabs[4].isPinned = true
        state.updateNormalTabs()
        XCTAssertTrue(state.canClearAllTabs)
        XCTAssertEqual(state.clearAllTabsCandidates.map(\.guid), [3, 4])
        state.clearAllTabs()
        XCTAssertEqual(state.closeRequests, [[3, 4]])
        XCTAssertEqual(state.tabs.map(\.guid), [1, 2, 5])
        XCTAssertTrue(state.clearTabsUndoManager.canUndo)
    }

    func testOneTabAndOnlyForegroundSplitAreNoOps() {
        seed(1)
        XCTAssertFalse(state.canClearAllTabs)
        state.clearAllTabs()
        XCTAssertTrue(state.closeRequests.isEmpty)
        seed(2)
        state.splits = [SplitGroup(id: "foreground", tabIds: [1, 2],
                                  layout: .horizontal, fractions: [0.5, 0.5], isPinned: false)]
        XCTAssertFalse(state.canClearAllTabs)
        state.clearAllTabs()
        XCTAssertTrue(state.closeRequests.isEmpty)
        XCTAssertFalse(state.clearTabsUndoManager.canUndo)
    }

    func testSplitOfThreeOrFourPanesCountsAsOneUnit() {
        seed(3)
        state.splits = [SplitGroup(id: "three", tabIds: [1, 2, 3], layout: .vertical,
                                   fractions: [0.5, 0.25, 0.25], isPinned: false)]
        XCTAssertFalse(state.canClearAllTabs)

        seed(5)
        state.splits = [SplitGroup(id: "four", tabIds: [1, 2, 3, 4], layout: .vertical,
                                   fractions: [0.25, 0.25, 0.25, 0.25], isPinned: false)]
        XCTAssertTrue(state.canClearAllTabs)
    }

    func testSplitWithPartnerOutsideNormalTabsDoesNotMergeUnits() {
        seed(2)
        state.splits = [SplitGroup(id: "detached", tabIds: [1, 99],
                                  layout: .horizontal, fractions: [0.5, 0.5], isPinned: false)]
        XCTAssertTrue(state.canClearAllTabs)
    }

    func testRedoCleansCurrentBackgroundTabsAndUndoRestoresItsNewSnapshot() async throws {
        seed(4)
        state.focusingTab = state.tabs[2]
        let originalURLs = state.normalTabs.map(\.url)
        state.clearAllTabs()
        XCTAssertEqual(state.closeRequests, [[1, 2, 4]])
        state.clearTabsUndoManager.undo()
        try await waitForRestore()
        XCTAssertEqual(state.normalTabs.map(\.url), originalURLs)
        XCTAssertEqual(state.focusingTab?.guid, 3)
        XCTAssertTrue(state.clearTabsUndoManager.canRedo)
        let restored = state.normalTabs.filter { $0.guid != 3 }.map(\.guid)
        state.tabs.append(Tab(guid: 2000, url: "https://later.test", isActive: false, index: 4))
        state.updateNormalTabs()
        let redoURLs = state.normalTabs.map(\.url)
        state.clearTabsUndoManager.redo()
        XCTAssertEqual(state.closeRequests.last, restored + [2000])
        XCTAssertEqual(state.tabs.map(\.guid), [3])
        state.clearTabsUndoManager.undo()
        try await waitForRestore()
        XCTAssertEqual(state.normalTabs.map(\.url), redoURLs)
    }

    func testCancelledCloseIsNotRestoredAndRedoRetriesItAsCurrentBackground() async throws {
        seed(3)
        state.cancelledIDs = [2]
        state.clearAllTabs()
        state.clearTabsUndoManager.undo()
        try await waitForRestore()
        XCTAssertEqual(state.tabs.filter { $0.url == "https://example.test/2" }.count, 1)
        XCTAssertEqual(state.tabs.count, 3)
        state.cancelledIDs = []
        state.clearTabsUndoManager.redo()
        XCTAssertEqual(state.closeRequests.last?.count, 2)
        XCTAssertEqual(state.tabs.map(\.guid), [1])
    }

    func testRedoKeepsNewForegroundSplitAfterOriginalKeptTabWasClosed() async throws {
        seed(4)
        state.clearAllTabs()
        state.clearTabsUndoManager.undo()
        try await waitForRestore()
        let restored = state.normalTabs.filter { $0.guid != 1 }
        state.focusingTab = restored[0]
        state.splits = [SplitGroup(id: "new-foreground", tabIds: [restored[0].guid, restored[1].guid],
                                  layout: .vertical, fractions: [0.4, 0.6], isPinned: false)]
        state.closeTabs(state.tabs.filter { $0.guid == 1 })
        state.clearTabsUndoManager.redo()
        XCTAssertEqual(state.closeRequests.last, [restored[2].guid])
        XCTAssertEqual(Set(state.tabs.map(\.guid)), Set(restored.prefix(2).map(\.guid)))
        XCTAssertEqual(state.focusingTab?.guid, restored[0].guid)
        XCTAssertEqual(state.splits.count, 1)
        state.clearTabsUndoManager.undo()
        try await waitForRestore()
        XCTAssertEqual(state.normalTabs.map(\.url), restored.map(\.url))
        XCTAssertEqual(state.focusingTab?.guid, restored[0].guid)
    }

    func testRedoDoesNothingWithoutForegroundOrWithOnlyForegroundSplit() async throws {
        seed(3)
        state.clearAllTabs()
        state.clearTabsUndoManager.undo()
        try await waitForRestore()
        state.focusingTab = nil
        state.tabs.forEach { $0.isActive = false }
        state.clearTabsUndoManager.redo()
        XCTAssertEqual(state.closeRequests.count, 1)
        XCTAssertEqual(state.tabs.count, 3)

        state.focusingTab = state.tabs[0]
        state.clearAllTabs()
        state.clearTabsUndoManager.undo()
        try await waitForRestore()
        let pair = Array(state.normalTabs.prefix(2))
        state.focusingTab = pair[0]
        state.splits = [SplitGroup(id: "only-foreground", tabIds: [pair[0].guid, pair[1].guid],
                                  layout: .horizontal, fractions: [0.5, 0.5], isPinned: false)]
        state.closeTabs(state.tabs.filter { !pair.contains($0) })
        let count = state.closeRequests.count
        state.clearTabsUndoManager.redo()
        XCTAssertEqual(state.closeRequests.count, count)
        XCTAssertEqual(state.tabs.count, 2)
        XCTAssertFalse(state.isRestoringClearedTabs)
    }

    func testFullyCancelledCloseDoesNotRegisterUndo() {
        seed(3)
        state.cancelledIDs = [2, 3]
        state.clearAllTabs()
        XCTAssertFalse(state.clearTabsUndoManager.canUndo)
        XCTAssertEqual(state.tabs.count, 3)
    }

    func testSnapshotPreservesGroupAndSplitPresentation() {
        seed(4)
        state.tabs[1].groupToken = "group"
        state.tabs[2].groupToken = "group"
        state.groups["group"] = WebContentGroupInfo(token: "group", title: "Research", color: .blue, isCollapsed: true)
        state.splits = [SplitGroup(id: "background", tabIds: [2, 3],
                                  layout: .horizontal, fractions: [0.35, 0.65], isPinned: false)]
        let batch = ClearedTabsBatch(tabs: state.clearAllTabsCandidates, state: state)
        XCTAssertEqual(batch.groups.first?.title, "Research")
        XCTAssertEqual(batch.groups.first?.color, "blue")
        XCTAssertEqual(batch.groups.first?.collapsed, true)
        XCTAssertEqual(batch.pages.map(\.group), ["group", "group", nil])
        XCTAssertEqual(batch.splits, state.splits)
    }

    func testFileMenuRebuildUsesDefaultAndCustomizedShortcut() throws {
        let previous = Shortcuts.configuration
        defer { Shortcuts.configuration = previous }
        Shortcuts.configuration = ShortcutConfiguration()
        let menu = NSMenu(title: "File")
        let close = NSMenuItem(title: "Close Tab", action: nil, keyEquivalent: "w")
        close.tag = CommandWrapper.IDC_CLOSE_TAB.rawValue
        menu.addItem(close)
        AppController.installOrUpdateFileMenuItems(in: menu, target: nil)
        var item = try XCTUnwrap(menu.item(withTag: CommandWrapper.PHI_CLEAR_ALL_TABS.rawValue))
        XCTAssertEqual(Shortcuts.key(for: .PHI_CLEAR_ALL_TABS),
                       ShortcutsKey(characters: "k", modifiers: [.command, .shift]))
        XCTAssertEqual(item.keyEquivalent, "K")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command])
        XCTAssertEqual(menu.index(of: item), menu.index(of: close) + 1)
        XCTAssertTrue(Shortcuts.Group.file.commands.contains(.PHI_CLEAR_ALL_TABS))
        let custom = ShortcutsKey(characters: "j", modifiers: [.control, .option])
        Shortcuts.configuration = ShortcutConfiguration(overrides: [CommandWrapper.PHI_CLEAR_ALL_TABS.rawValue: .custom(custom)])
        AppController.installOrUpdateFileMenuItems(in: menu, target: nil)
        item = try XCTUnwrap(menu.item(withTag: CommandWrapper.PHI_CLEAR_ALL_TABS.rawValue))
        XCTAssertEqual(item.keyEquivalent, "j")
        XCTAssertEqual(item.keyEquivalentModifierMask, custom.modifiers)
        XCTAssertEqual(menu.items.filter { $0.tag == CommandWrapper.PHI_CLEAR_ALL_TABS.rawValue }.count, 1)
    }

    func testDefaultAndCustomShortcutsDispatchAndReleaseOldBinding() throws {
        let previous = Shortcuts.configuration
        defer {
            Shortcuts.configuration = previous
            CommandDispatcher.reloadPhiShortcutMap()
        }
        func event(_ characters: String, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 40))
        }
        Shortcuts.configuration = ShortcutConfiguration()
        CommandDispatcher.reloadPhiShortcutMap()
        seed(3)
        let original = try event("K", [.command, .shift])
        XCTAssertEqual(CommandDispatcher.interceptedPhiCommand(for: original), .PHI_CLEAR_ALL_TABS)
        XCTAssertNotEqual(CommandDispatcher.interceptedPhiCommand(for: try event("k", [.command])), .PHI_CLEAR_ALL_TABS)
        XCTAssertTrue(CommandDispatcher.handleKeyEquivalent(original, window: window))
        XCTAssertEqual(state.closeRequests, [[2, 3]])
        let custom = ShortcutsKey(characters: "j", modifiers: [.control, .option])
        Shortcuts.configuration = ShortcutConfiguration(overrides: [CommandWrapper.PHI_CLEAR_ALL_TABS.rawValue: .custom(custom)])
        CommandDispatcher.reloadPhiShortcutMap()
        XCTAssertNotEqual(CommandDispatcher.interceptedPhiCommand(for: original), .PHI_CLEAR_ALL_TABS)
        seed(3)
        XCTAssertTrue(CommandDispatcher.handleKeyEquivalent(try event("j", [.control, .option]), window: window))
        XCTAssertEqual(state.closeRequests.count, 2)
    }

    func testClearTabsAnimationLoadsFromApplicationBundle() {
        XCTAssertNotNil(LottieAnimation.named("clear-tabs", bundle: .main, subdirectory: "LottieFiles"))
    }

    func testClearClickWaitsForPlaybackAndIgnoresRepeatedClicks() async throws {
        let cell = SeparatorCellView(frame: NSRect(x: 0, y: 0, width: 260, height: 28))
        let closed = expectation(description: "Close after animation finishes")
        var calls = 0
        var startedAt = Date()
        cell.clearTabsAction = {
            calls += 1
            XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(startedAt), 0.4)
            closed.fulfill()
        }
        window.contentView?.addSubview(cell)
        window.orderFront(nil)
        cell.layoutSubtreeIfNeeded()
        // Let the hosting view mount before sending the manual playback trigger.
        try await Task.sleep(for: .milliseconds(100))
        let button = try XCTUnwrap(cell.subviews.compactMap { $0 as? SidebarCleanupButton }.first { $0.kind == .clear })
        startedAt = Date()
        button.sendAction(button.action, to: button.target)
        button.sendAction(button.action, to: button.target)
        XCTAssertEqual(calls, 0)
        await fulfillment(of: [closed], timeout: 3)
        XCTAssertEqual(calls, 1)

        let cancelled = expectation(description: "Reused cell must not close tabs")
        cancelled.isInverted = true
        cell.clearTabsAction = { cancelled.fulfill() }
        button.sendAction(button.action, to: button.target)
        try await Task.sleep(for: .milliseconds(100))
        cell.prepareForReuse()
        cell.clearTabsAction = { cancelled.fulfill() }
        await fulfillment(of: [cancelled], timeout: 0.7)
    }

    func testSeparatorHoverColorsMatchInBothAppearancesAndResetWhenHidden() throws {
        let broom = SidebarCleanupButton(kind: .organize)
        let clear = SidebarCleanupButton(kind: .clear)
        let enter = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, trackingNumber: 0, userData: nil))
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            for button in [broom, clear] {
                button.isHidden = false
                button.appearance = appearance
                button.mouseEntered(with: enter)
            }
            let background = try XCTUnwrap(broom.layer?.backgroundColor)
            XCTAssertEqual(background, clear.layer?.backgroundColor)
            XCTAssertEqual(background.alpha, 0.04, accuracy: 0.001)
            appearance.performAsCurrentDrawingAppearance {
                XCTAssertEqual(background, NSColor(resource: .sidebarTabHovered).cgColor)
            }
            for button in [broom, clear] {
                button.isHidden = true
                XCTAssertEqual(button.layer?.backgroundColor?.alpha, 0)
                XCTAssertTrue(button.layer?.animationKeys()?.isEmpty ?? true)
            }
        }
    }

    func testSeparatorButtonsSitAfterLineAndResetOnReuse() throws {
        let cell = SeparatorCellView(frame: NSRect(x: 0, y: 0, width: 260, height: 28))
        cell.cleanupAction = {}
        cell.clearTabsAction = {}
        cell.layoutSubtreeIfNeeded()
        let broom = try XCTUnwrap(cell.subviews.first { ($0 as? SidebarCleanupButton)?.kind == .organize })
        let clear = try XCTUnwrap(cell.subviews.first { ($0 as? SidebarCleanupButton)?.kind == .clear })
        let line = try XCTUnwrap(cell.subviews.first { type(of: $0) == NSView.self })
        XCTAssertLessThan(line.frame.maxX, broom.frame.minX)
        XCTAssertLessThan(broom.frame.maxX, clear.frame.minX)
        XCTAssertEqual(clear.frame.midY, line.frame.midY, accuracy: 0.5)
        XCTAssertFalse(broom.isHidden)
        XCTAssertFalse(clear.isHidden)
        XCTAssertTrue(cell.hitTest(NSPoint(x: broom.frame.midX, y: broom.frame.midY)) === broom)
        let clearHit = cell.hitTest(NSPoint(x: clear.frame.midX, y: clear.frame.midY))
        XCTAssertTrue(clearHit === clear || clearHit?.isDescendant(of: clear) == true)
        cell.prepareForReuse()
        XCTAssertTrue(broom.isHidden)
        XCTAssertTrue(clear.isHidden)
    }
}

private final class ClearTabsLiveState: BrowserState {
    override func createTab(_ url: String?, customGuid: String? = nil, focusAfterCreate: Bool = true) {
        ChromiumLauncher.sharedInstance().bridge?.createNewTab(withUrl: url ?? "about:blank",
            windowId: Int64(windowId), customGuid: customGuid, focusAfterCreate: focusAfterCreate)
    }
}

private final class ClearTabsBridgeDelegate: NSObject {
    let original: NSObject
    init(original: NSObject) { self.original = original }
    @objc func canShowChromiumWindow() -> Bool { true }
    override func responds(to selector: Selector!) -> Bool {
        if NSStringFromSelector(selector).hasPrefix("mainBrowserWindowCreated:") { return false }
        return super.responds(to: selector) || original.responds(to: selector)
    }
    override func forwardingTarget(for selector: Selector!) -> Any? { original }
}

extension ClearTabsTests {
    func testChromiumUndoRestoresGroupSplitAndOrderAcrossTwoCycles() async throws {
        try await checkChromiumRestoration(foregroundIndex: 0)
    }

    func testChromiumUndoRejoinsSurvivingForegroundGroup() async throws {
        try await checkChromiumRestoration(foregroundIndex: 3)
    }

    private func checkChromiumRestoration(foregroundIndex: Int) async throws {
        let collapsed = foregroundIndex == 0
        let dataDirectory = try XCTUnwrap(FileSystemUtils.launchUserDataDirectory)
        let temporaryRoot = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        XCTAssertTrue(URL(fileURLWithPath: dataDirectory).resolvingSymlinksInPath().path.hasPrefix(temporaryRoot + "/"))
        guard URL(fileURLWithPath: dataDirectory).resolvingSymlinksInPath().path.hasPrefix(temporaryRoot + "/") else { return }
        let bridge = try XCTUnwrap(ChromiumLauncher.sharedInstance().bridge)
        let bridgeObject = try XCTUnwrap(bridge as? NSObject)
        let previousDelegate = try XCTUnwrap(bridge.delegate as? NSObject)
        let delegate = ClearTabsBridgeDelegate(original: previousDelegate)
        func setDelegate(_ object: NSObject) throws {
            let selector = NSSelectorFromString("setDelegate:")
            let implementation = try XCTUnwrap(bridgeObject.method(for: selector))
            typealias Invoke = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
            unsafeBitCast(implementation, to: Invoke.self)(bridgeObject, selector, object)
        }
        try setDelegate(delegate)
        defer { try? setDelegate(previousDelegate) }
        // An off-the-record fixture has no saved-group deletion dialog and
        // never writes its pages into the test profile's session restore.
        let browser = try XCTUnwrap(bridge.createBrowser(withWindowType: .incognito, profileId: nil, hidden: true))
        let browserWindow = try XCTUnwrap(browser["window"] as? NSWindow)
        let browserID = try XCTUnwrap(browser["windowId"] as? NSNumber).intValue
        let live = ClearTabsLiveState(windowId: browserID, localStore: store,
                                     profileId: LocalStore.defaultProfileId, spaceId: UUID().uuidString, isIncognito: true)
        let session = SpaceSessionController(window: browserWindow, windowId: browserID, browserType: .incognito,
            profileId: live.profileId, spaceId: live.spaceId, account: store.account, browserState: live, dormant: true)
        defer {
            live.clearTabsUndoManager.removeAllActions()
            session.discardDormant()
            bridge.executeCommand(Int32(CommandWrapper.IDC_CLOSE_WINDOW.rawValue), windowId: Int64(browserID))
        }
        func waitFor(_ condition: @escaping () -> Bool) async throws {
            for _ in 0..<200 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTAssertTrue(condition(), "Chromium did not settle: tabs=\(live.normalTabs.map(\.guid)), focus=\(String(describing: live.focusingTab?.guid)), canUndo=\(live.clearTabsUndoManager.canUndo), restoring=\(live.isRestoringClearedTabs), groups=\(live.groups.count), splits=\(live.splits.count)")
            if !condition() { throw XCTestError(.timeoutWhileWaiting) }
        }
        for index in 0..<5 {
            live.createTab("data:text/html,<title>Cleanup\(index)</title>", focusAfterCreate: index == 0)
        }
        try await waitFor { live.normalTabs.count == 5 }
        let original = live.normalTabs
        let group = bridge.createGroupFromTabs(withWindowId: Int64(browserID),
            tabIds: original[1...3].map { NSNumber(value: $0.guid) }, title: "Research", color: "blue")
        XCTAssertFalse(group.isEmpty)
        try await waitFor { live.groups[group] != nil && live.normalTabs.filter { $0.groupToken == group }.count == 3 }
        let splitID = try XCTUnwrap(live.createSplit(leftTabId: original[1].guid, rightTabId: original[2].guid, layout: .horizontal))
        live.updateSplitRatio(splitID, ratio: 0.35)
        try await waitFor { live.splits.count == 1 }
        original[foregroundIndex].webContentWrapper?.setAsActiveTab()
        live.focuseTab(original[foregroundIndex])
        bridge.updateTabGroupCollapsed(withWindowId: Int64(browserID), tokenHex: group, isCollapsed: collapsed)
        try await waitFor { live.groups[group]?.isCollapsed == collapsed }
        let urls = live.normalTabs.map(\.url)
        XCTAssertTrue(live.canClearAllTabs)
        XCTAssertEqual(live.clearAllTabsCandidates.count, 4)
        live.clearAllTabs()
        try await waitFor { live.normalTabs.count == 1 && live.clearTabsUndoManager.canUndo }
        for _ in 0..<2 {
            let cleared = live.normalTabs.map(\.guid)
            var published: [[Int]] = []
            let recording = live.$normalTabs.sink { published.append($0.map(\.guid)) }
            live.clearTabsUndoManager.undo()
            try await waitFor { !live.isRestoringClearedTabs && live.normalTabs.count == 5 && live.splits.count == 1 }
            try await waitFor { live.groups.values.contains { $0.title == "Research" && $0.isCollapsed == collapsed } }
            recording.cancel()
            let restoredOrder = live.normalTabs.map(\.guid)
            XCTAssertTrue(published.allSatisfy { $0 == cleared || $0 == restoredOrder }, "Intermediate orders: \(published)")
            let restoredTabs = live.normalTabs.filter { $0.guid != original[foregroundIndex].guid }
            try await waitFor { restoredTabs.allSatisfy(\.isUnloaded) }
            XCTAssertEqual(live.normalTabs.map(\.url), urls)
            let restoredGroup = try XCTUnwrap(live.groups.values.first { $0.title == "Research" })
            XCTAssertEqual(restoredGroup.color, .blue)
            XCTAssertEqual(restoredGroup.isCollapsed, collapsed)
            XCTAssertEqual(live.normalTabs.filter { $0.groupToken == restoredGroup.token }.count, 3)
            let split = try XCTUnwrap(live.splits.first)
            XCTAssertEqual(split.layout, .horizontal)
            XCTAssertEqual(try XCTUnwrap(split.pairRatio), 0.35, accuracy: 0.01)
            XCTAssertEqual(live.focusingTab?.guid, original[foregroundIndex].guid)
            live.clearTabsUndoManager.redo()
            try await waitFor { live.normalTabs.count == 1 }
        }
    }
}

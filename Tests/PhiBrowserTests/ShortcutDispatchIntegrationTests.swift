// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

@MainActor
final class ShortcutDispatchIntegrationTests: XCTestCase {
    private var previousConfiguration: ShortcutConfiguration!
    private var directory: URL!
    private var accountDirectory: URL!
    private var store: LocalStore!
    private var previousDefaults: [String: Any] = [:]
    private let defaultKeys = ["FolioFeatureFlag", "spacesFeatureEnabled", "NSWindow Frame KioskBrowserWindow"]
    private let inspectKey = ShortcutsKey(characters: "c", modifiers: [.command, .option])
    private let copyKey = ShortcutsKey(characters: "c", modifiers: [.command, .shift])

    override func setUp() async throws {
        previousConfiguration = Shortcuts.configuration
        for key in defaultKeys { previousDefaults[key] = UserDefaults.standard.object(forKey: key) }
        UserDefaults.standard.set(true, forKey: "FolioFeatureFlag")
        configure([:])
        ChromiumLauncher.sharedInstance().bridge?.requestRebuildMainMenu()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let account = Account(userID: "shortcut-dispatch-test-\(UUID().uuidString)")
        accountDirectory = account.userDataStorage
        store = LocalStore(account: account, storeDirectoryURL: directory, presentsCompatibilityAlerts: false)
        account.localStorage = store
    }

    override func tearDown() async throws {
        Shortcuts.configuration = previousConfiguration
        CommandDispatcher.reloadPhiShortcutMap()
        ChromiumLauncher.sharedInstance().bridge?.requestRebuildMainMenu()
        for key in defaultKeys { UserDefaults.standard.set(previousDefaults[key], forKey: key) }
        let drained = expectation(description: "Dispatch fixture UI updates drained")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
        try await store.closeForAccountDirectoryRemoval()
        store = nil
        for url in [directory, accountDirectory].compactMap({ $0 })
        where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func testUnavailableNativeActionsConsumeTheirKeyBeforeHiddenInspect() throws {
        XCTAssertTrue(Shortcuts.additionalBindings().contains {
            $0.commandID == CommandWrapper.IDC_DEV_TOOLS_INSPECT.rawValue
                && $0.source == .hidden && $0.key.menuKeyEquivalent == inspectKey.menuKeyEquivalent
        }, "The paired Framework must still expose the conflicting Inspect alias")
        try withController { controller, window in
            XCTAssertNil(controller.browserState.focusingTab)
            for command in [CommandWrapper.PHI_COPY_URL, .PHI_SHARE_PAGE, .PHI_TOGGLE_READER,
                            .PHI_SAVE_FOR_LATER, .PHI_FARRINGDON_TOGGLE,
                            .PHI_CAPTURE_FULL_PAGE, .PHI_CAPTURE_AREA] {
                assignInspectKey(to: command)
                XCTAssertEqual(CommandDispatcher.interceptedPhiCommand(for: try event(inspectKey, in: window)), command)
                let item = NSMenuItem(title: "Unavailable action", action: nil, keyEquivalent: "")
                item.tag = command.rawValue
                XCTAssertFalse(CommandDispatcher.dispatchCommand(item, window: window), "No action result for \(command)")
                XCTAssertTrue(CommandDispatcher.handleKeyEquivalent(try event(inspectKey, in: window), window: window),
                              "The matched \(command) must stop fallback even without an action result")
            }
        }
    }

    func testBookmarkBarCommandUsesPhiVisibilityAndDoesNotFallBackInKiosk() throws {
        let defaults = UserDefaults.standard
        let layoutKey = PhiPreferences.GeneralSettings.layoutModeKey
        let visibilityKey = PhiPreferences.GeneralSettings.alwaysShowBookmarkBar.rawValue
        let layout = defaults.object(forKey: layoutKey)
        let visibility = defaults.object(forKey: visibilityKey)
        defer {
            defaults.set(layout, forKey: layoutKey)
            defaults.set(visibility, forKey: visibilityKey)
        }
        PhiPreferences.GeneralSettings.saveLayoutMode(.comfortable)
        defaults.set(false, forKey: visibilityKey)
        let command = Int32(CommandWrapper.IDC_SHOW_BOOKMARK_BAR.rawValue)
        try withController { _, window in
            XCTAssertTrue(CommandDispatcher.dispatchCommand(command, window: window))
            XCTAssertTrue(PhiPreferences.GeneralSettings.alwaysShowBookmarkBar.loadValue())
            XCTAssertTrue(CommandDispatcher.dispatchCommand(command, window: window))
            XCTAssertFalse(PhiPreferences.GeneralSettings.alwaysShowBookmarkBar.loadValue())
        }
        try withController(kiosk: true) { _, window in
            XCTAssertTrue(CommandDispatcher.dispatchCommand(command, window: window))
            XCTAssertFalse(PhiPreferences.GeneralSettings.alwaysShowBookmarkBar.loadValue())
        }
    }

    func testDisabledAndReboundCommandsDoNotConsumeTheirOldKey() throws {
        try withController { _, window in
            configure([.PHI_COPY_URL: .disabled])
            XCTAssertFalse(CommandDispatcher.handleKeyEquivalent(try event(copyKey, in: window), window: window))
            let replacement = ShortcutsKey(characters: "k", modifiers: .control)
            configure([.PHI_COPY_URL: .custom(replacement)])
            XCTAssertFalse(CommandDispatcher.handleKeyEquivalent(try event(copyKey, in: window), window: window))
            XCTAssertTrue(CommandDispatcher.handleKeyEquivalent(try event(replacement, in: window), window: window))
            XCTAssertFalse(CommandDispatcher.handleKeyEquivalent(
                try event(.init(characters: "k", modifiers: [.control, .option]), in: window), window: window))
        }
    }

    func testScreenshotDefaultsMatchShiftedDigitsAndReleaseOldKeys() throws {
        try withController { _, window in
            for (command, character, digit, code) in [
                (CommandWrapper.PHI_CAPTURE_FULL_PAGE, "!", "1", UInt16(18)),
                (.PHI_CAPTURE_AREA, "@", "2", UInt16(19))
            ] {
                let original = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                    modifierFlags: [.command, .shift], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: character,
                    charactersIgnoringModifiers: character, isARepeat: false, keyCode: code))
                let unshifted = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                    modifierFlags: .command, timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: digit,
                    charactersIgnoringModifiers: digit, isARepeat: false, keyCode: code))
                configure([:])
                XCTAssertEqual(CommandDispatcher.interceptedPhiCommand(for: original), command)
                XCTAssertNil(CommandDispatcher.interceptedPhiCommand(for: unshifted))
                XCTAssertTrue(CommandDispatcher.handleKeyEquivalent(original, window: window))
                configure([command: .disabled])
                XCTAssertFalse(CommandDispatcher.handleKeyEquivalent(original, window: window))
                configure([command: .custom(inspectKey)])
                XCTAssertFalse(CommandDispatcher.handleKeyEquivalent(original, window: window))
                XCTAssertTrue(CommandDispatcher.handleKeyEquivalent(try event(inspectKey, in: window), window: window))
            }
        }
    }

    func testPageCommandsDoNotClaimSettingsOrOtherNonBrowserWindows() throws {
        let window = makeWindow()
        defer { window.close() }
        XCTAssertNil(SpaceSessionControllersManager.shared.findControllerWith(window: window))
        for command in [CommandWrapper.PHI_COPY_URL, .PHI_SHARE_PAGE, .PHI_TOGGLE_READER, .PHI_SAVE_FOR_LATER,
                        .PHI_CAPTURE_FULL_PAGE, .PHI_CAPTURE_AREA] {
            assignInspectKey(to: command)
            XCTAssertFalse(CommandDispatcher.handleKeyEquivalent(try event(inspectKey, in: window), window: window))
        }
    }

    func testKioskSharedPageActionsOwnUnavailableBindingsWithoutClaimingBrowserOnlyActions() throws {
        try withController(kiosk: true) { _, window in
            for command in [CommandWrapper.PHI_COPY_URL, .PHI_SHARE_PAGE, .PHI_TOGGLE_READER, .PHI_SAVE_FOR_LATER,
                            .PHI_CAPTURE_FULL_PAGE, .PHI_CAPTURE_AREA] {
                assignInspectKey(to: command)
                XCTAssertTrue(command.shortcutScope.contains(.kiosk))
                XCTAssertTrue(CommandDispatcher.handleKeyEquivalent(try event(inspectKey, in: window), window: window))
            }
            for command in [CommandWrapper.PHI_FARRINGDON_TOGGLE, .PHI_TAB_SWITCHER_FORWARD,
                            .PHI_SELECT_NEXT_SPACE, .PHI_SELECT_SPACE_1] {
                assignInspectKey(to: command)
                XCTAssertFalse(command.shortcutScope.contains(.kiosk))
                XCTAssertFalse(CommandDispatcher.handleKeyEquivalent(try event(inspectKey, in: window), window: window))
            }
        }
    }

    func testCopyURLStillExecutesInOrdinaryAndKioskWindows() throws {
        let pasteboard = NSPasteboard.general
        let previousItems = (pasteboard.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        var ownedChangeCount: Int?
        defer {
            if pasteboard.changeCount == ownedChangeCount {
                pasteboard.clearContents()
                if !previousItems.isEmpty { pasteboard.writeObjects(previousItems) }
            }
        }
        for kiosk in [false, true] {
            try withController(kiosk: kiosk) { controller, window in
                let url = "https://example.test/shortcut-copy-\(kiosk)"
                let tab = Tab(guid: 1001, url: url, isActive: true, index: 0)
                controller.browserState.tabs = [tab]
                controller.browserState.focusingTab = tab
                XCTAssertTrue(controller.browserState.hasCopyableSelectedTabURLs)
                configure([:])
                XCTAssertTrue(CommandDispatcher.handleKeyEquivalent(try event(copyKey, in: window), window: window))
                ownedChangeCount = pasteboard.changeCount
                XCTAssertEqual(pasteboard.string(forType: .string), url)
            }
        }
    }

    func testUnavailableFeaturesAndMissingIndexedSpaceRemainUnhandled() throws {
        try withController { _, window in
            UserDefaults.standard.set(false, forKey: "FolioFeatureFlag")
            assignInspectKey(to: .PHI_SAVE_FOR_LATER)
            XCTAssertFalse(CommandDispatcher.handleKeyEquivalent(try event(inspectKey, in: window), window: window))
            UserDefaults.standard.set(false, forKey: "spacesFeatureEnabled")
            for command in [CommandWrapper.PHI_NEW_INCOGNITO_SPACE, .PHI_SELECT_NEXT_SPACE, .PHI_SELECT_PREVIOUS_SPACE] {
                assignInspectKey(to: command)
                XCTAssertFalse(CommandDispatcher.handleKeyEquivalent(try event(inspectKey, in: window), window: window))
            }
            UserDefaults.standard.set(true, forKey: "spacesFeatureEnabled")
            assignInspectKey(to: .PHI_SELECT_SPACE_1)
            XCTAssertFalse(CommandDispatcher.handleKeyEquivalent(try event(inspectKey, in: window), window: window))
        }
    }

    /// Close Tab on the focused pane of a split in the tab list is left to
    /// Chromium, which closes that pane alone. In a split that a bookmark or
    /// a pinned record saves it is handled here: the whole split closes.
    func testCloseTabIsHandledHereOnlyForASplitSavedInTheSidebar() throws {
        for savedInSidebar in [false, true] {
            try withController { controller, window in
                let state = controller.browserState
                state.tabs = (1...4).map {
                    Tab(guid: $0, url: "https://e\($0).example", isActive: $0 == 2, index: $0 - 1)
                }
                state.splits = [SplitGroup(id: "split", tabIds: [1, 2, 3], layout: .vertical,
                                           fractions: SplitGroup.equalFractions(paneCount: 3))]
                if savedInSidebar { state.splitBookmarkBindings["bookmark"] = "split" }
                state.updateNormalTabs()
                state.focusingTab = state.tabs[1]

                let item = NSMenuItem(title: "Close Tab", action: nil, keyEquivalent: "")
                item.tag = CommandWrapper.IDC_CLOSE_TAB.rawValue
                XCTAssertEqual(CommandDispatcher.dispatchCommand(item, window: window), savedInSidebar)
            }
        }
    }

    private func assignInspectKey(to command: CommandWrapper) {
        var overrides: [CommandWrapper: ShortcutOverride] = [.PHI_COPY_URL: .disabled]
        overrides[command] = .custom(inspectKey)
        configure(overrides)
    }

    private func configure(_ overrides: [CommandWrapper: ShortcutOverride]) {
        Shortcuts.configuration = ShortcutConfiguration(
            overrides: Dictionary(uniqueKeysWithValues: overrides.map { ($0.key.rawValue, $0.value) }))
        CommandDispatcher.reloadPhiShortcutMap()
    }

    private func withController(kiosk: Bool = false,
                                _ body: (SpaceSessionController, NSWindow) throws -> Void) throws {
        let window = makeWindow()
        let controller: SpaceSessionController
        if kiosk {
            controller = KioskBrowserWindowController(window: window, windowId: 987654322,
                browserType: .kiosk, profileId: LocalStore.defaultProfileId, account: store.account)
        } else {
            let state = BrowserState(windowId: 987654322, localStore: store,
                                     profileId: LocalStore.defaultProfileId, spaceId: UUID().uuidString)
            controller = SpaceSessionController(window: window, windowId: state.windowId,
                profileId: state.profileId, spaceId: state.spaceId, account: store.account,
                browserState: state, dormant: true)
        }
        defer {
            OverlayToastCenter.shared.clearWindow(windowId: controller.windowId)
            if !kiosk { controller.discardDormant() }
            window.close()
            withExtendedLifetime(controller) {}
        }
        XCTAssertTrue(SpaceSessionControllersManager.shared.findControllerWith(window: window) === controller)
        try body(controller, window)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private func event(_ key: ShortcutsKey, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: key.modifiers,
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: key.characters, charactersIgnoringModifiers: key.characters, isARepeat: false, keyCode: 8))
    }
}

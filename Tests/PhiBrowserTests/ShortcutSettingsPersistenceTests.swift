// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import XCTest
@testable import Phi

private final class ReleasedShortcutActionTarget: NSObject {
    var invocationCount = 0
    @objc func invoke(_ sender: Any?) { invocationCount += 1 }
    @objc(copyToFindPboard:) func useSelection(_ sender: Any?) { invocationCount += 1 }
    @objc(centerSelectionInVisibleArea:) func jumpToSelection(_ sender: Any?) { invocationCount += 1 }
    @objc(copyFullPageScreenshotFromMenu:) func captureFullPage(_ sender: Any?) { invocationCount += 1 }
    @objc(capturePageAreaFromMenu:) func captureArea(_ sender: Any?) { invocationCount += 1 }
}

final class ShortcutSettingsPersistenceTests: XCTestCase {
    private var previousConfiguration: ShortcutConfiguration?
    private var contents = Data("[]".utf8)
    private var backups: [Data] = []
    private var rejectsWrites = false
    private var writeCount = 0
    private let customKey = ShortcutsKey(characters: "j", modifiers: [.command, .control])

    override func setUpWithError() throws {
        previousConfiguration = Shortcuts.configuration
        let url = try XCTUnwrap(previousConfiguration?.fileURL)
        contents = Data("[]".utf8)
        backups = []
        rejectsWrites = false
        writeCount = 0
        Shortcuts.configuration = ShortcutConfiguration(
            fileURL: url,
            files: .init(
                read: { [unowned self] _ in self.contents },
                write: { [unowned self] data, _ in
                    if self.rejectsWrites { throw CocoaError(.fileWriteNoPermission) }
                    self.contents = data
                    self.writeCount += 1
                },
                backup: { [unowned self] _, _ in self.backups.append(self.contents) }
            )
        )
        CommandDispatcher.reloadPhiShortcutMap()
    }

    override func tearDownWithError() throws {
        Shortcuts.configuration = try XCTUnwrap(previousConfiguration)
        CommandDispatcher.reloadPhiShortcutMap()
        ChromiumLauncher.sharedInstance().bridge?.requestRebuildMainMenu()
        previousConfiguration = nil
    }

    private func item(_ command: CommandWrapper, in model: ShortcutsViewModel) throws -> ShortcutItem {
        try XCTUnwrap(model.sections.flatMap(\.items).first { $0.command == command })
    }

    func testScreenshotCommandsSurviveRebindReloadDisableAndRestore() throws {
        let bridge = try XCTUnwrap(ChromiumLauncher.sharedInstance().bridge)
        let model = ShortcutsViewModel()
        let commands: [(CommandWrapper, String, String, UInt16)] = [
            (.PHI_CAPTURE_FULL_PAGE, "copyFullPageScreenshotFromMenu:", "!", 18),
            (.PHI_CAPTURE_AREA, "capturePageAreaFromMenu:", "@", 19)
        ]

        func assertMenu(_ command: CommandWrapper, action: String, key: ShortcutsKey?, code: UInt16) throws {
            bridge.requestRebuildMainMenu()
            model.rebuildSections()
            let menu = try XCTUnwrap(NSApp.mainMenu)
            let file = try XCTUnwrap(ChromiumMainMenuRole.file.item(in: menu)?.submenu)
            let entries = file.items.filter { $0.action == NSSelectorFromString(action) }
            XCTAssertEqual(entries.count, 1)
            let entry = try XCTUnwrap(entries.first)
            XCTAssertEqual(entry.tag, command.rawValue)
            XCTAssertEqual(entry.keyEquivalent, key?.menuKeyEquivalent.characters ?? "")
            XCTAssertEqual(entry.keyEquivalentModifierMask, key?.menuKeyEquivalent.modifiers ?? [])
            NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: file)
            defer { NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: file) }
            if key == Shortcuts.DefaultShortcuts[command] {
                XCTAssertEqual(entry.keyEquivalent, command == .PHI_CAPTURE_FULL_PAGE ? "1" : "2")
                XCTAssertEqual(entry.keyEquivalentModifierMask, [.command, .shift])
            } else {
                XCTAssertEqual(entry.keyEquivalent, key?.menuKeyEquivalent.characters ?? "")
                XCTAssertEqual(entry.keyEquivalentModifierMask, key?.menuKeyEquivalent.modifiers ?? [])
            }
            let bindings = Shortcuts.menuBindings(in: file).filter { $0.commandID == command.rawValue }
            XCTAssertEqual(bindings.map(\.key.menuKeyEquivalent), key.map { [$0.menuKeyEquivalent] } ?? [])
            XCTAssertEqual(try item(command, in: model).shortcutKey, key)
            XCTAssertTrue(Shortcuts.Group.file.commands.contains(command))
            XCTAssertFalse(model.inventory.bindings.contains { $0.owner == .nativeAction(action) })
            if let key {
                let target = ReleasedShortcutActionTarget()
                let originalTarget = entry.target
                let autoenables = file.autoenablesItems
                defer {
                    entry.target = originalTarget
                    file.autoenablesItems = autoenables
                }
                file.autoenablesItems = false
                entry.target = target
                entry.isEnabled = true
                let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                    modifierFlags: key.modifiers, timestamp: 0, windowNumber: 0, context: nil,
                    characters: key.characters, charactersIgnoringModifiers: key.characters,
                    isARepeat: false, keyCode: code))
                XCTAssertEqual(CommandDispatcher.interceptedPhiCommand(for: event), command)
                let menuEvent: NSEvent
                if key == Shortcuts.DefaultShortcuts[command] {
                    // Let the system translate a physical digit key. Supplying "!"
                    // as both character fields does not model AppKit's digit matching.
                    let keyboardEvent = try XCTUnwrap(CGEvent(
                        keyboardEventSource: nil, virtualKey: code, keyDown: true))
                    keyboardEvent.flags = [.maskCommand, .maskShift]
                    menuEvent = try XCTUnwrap(NSEvent(cgEvent: keyboardEvent))
                } else {
                    menuEvent = event
                }
                XCTAssertEqual(CommandDispatcher.interceptedPhiCommand(for: menuEvent), command)
                XCTAssertTrue(file.performKeyEquivalent(with: menuEvent))
                XCTAssertEqual(target.invocationCount, 1)
            }
        }

        for (command, action, character, code) in commands {
            let original = ShortcutsKey(characters: character, modifiers: [.command, .shift])
            XCTAssertEqual(Shortcuts.DefaultShortcuts[command], original)
            try assertMenu(command, action: action, key: original, code: code)
            XCTAssertEqual(try item(command, in: model).shortcutKeycapTokens,
                           ShortcutsKey(characters: code == 18 ? "1" : "2",
                                        modifiers: [.command, .shift]).keycapTokens)
            model.setCustomShortcut(for: command, key: customKey)
            try assertMenu(command, action: action, key: customKey, code: 38)
            try Shortcuts.reloadOverrides().get()
            try assertMenu(command, action: action, key: customKey, code: 38)
            model.disableShortcut(for: command)
            try assertMenu(command, action: action, key: nil, code: code)
            try Shortcuts.reloadOverrides().get()
            try assertMenu(command, action: action, key: nil, code: code)
            model.restoreDefaultShortcut(for: command)
            try assertMenu(command, action: action, key: original, code: code)
        }
    }

    func testNewKioskWindowRejectsF12WithoutSavingAndAcceptsNextShortcut() throws {
        let command = CommandWrapper.PHI_NEW_KIOSK_WINDOW
        let model = ShortcutsViewModel()
        model.setCustomShortcut(for: command, key: customKey)
        let saved = contents
        let writes = writeCount
        func keyDown(_ characters: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        }
        model.startRecording(for: command)
        let f12 = try keyDown("\u{F70F}", 111, .function)
        for event in [f12, try keyDown("\u{F70F}", 111, [.command, .function])] {
            model.handleCaptureEvent(event)
            XCTAssertEqual(model.editingCommand, command)
            XCTAssertNotNil(model.recordingMessage)
            XCTAssertEqual(Shortcuts.key(for: command), customKey)
            XCTAssertEqual(contents, saved)
            XCTAssertEqual(writeCount, writes)
        }
        model.handleCaptureEvent(try keyDown("y", 16, [.control, .option]))
        XCTAssertNil(model.capture)
        XCTAssertNil(model.recordingMessage)
        XCTAssertEqual(Shortcuts.key(for: command), ShortcutsKey(characters: "y", modifiers: [.control, .option]))
        XCTAssertEqual(writeCount, writes + 1)

        model.startRecording(for: .IDC_RELOAD)
        model.handleCaptureEvent(f12)
        XCTAssertNil(model.capture)
        XCTAssertEqual(Shortcuts.key(for: .IDC_RELOAD), ShortcutsKey(characters: "\u{F70F}", modifiers: []))
        let toggle = try XCTUnwrap(model.conflicts(for: .IDC_RELOAD).first { $0.id == .command(40237) })
        XCTAssertNil(toggle.command)
    }

    func testLegacyNewKioskWindowF12UsesDefaultAfterReload() throws {
        let command = CommandWrapper.PHI_NEW_KIOSK_WINDOW
        let defaultKey = try XCTUnwrap(Shortcuts.DefaultShortcuts[command])
        let url = try XCTUnwrap(Shortcuts.configuration.fileURL)
        let f12 = ShortcutsKey(characters: "\u{F70F}", modifiers: [])
        try Shortcuts.configuration.set(.custom(f12), for: command.rawValue, at: url)
        try Shortcuts.reloadOverrides().get()
        XCTAssertFalse(Shortcuts.isOverridden(command))
        XCTAssertEqual(Shortcuts.key(for: command), defaultKey)
        XCTAssertEqual(try item(command, in: ShortcutsViewModel()).shortcutKey, defaultKey)
    }

    func testRecordedShiftedDigitsUseSharedDisplayWithoutChangingSavedKeys() throws {
        let model = ShortcutsViewModel()
        let commands: [CommandWrapper] = [.IDC_RELOAD, .PHI_COPY_URL, .IDS_EDIT_USE_SELECTION_MAC]
        let digits: [(String, String, UInt16)] = [
            ("1", "!", 18), ("2", "@", 19), ("3", "#", 20), ("4", "$", 21),
            ("5", "%", 23), ("6", "^", 22), ("7", "&", 26), ("8", "*", 28),
            ("9", "(", 25), ("0", ")", 29)
        ]
        for (index, (digit, symbol, code)) in digits.enumerated() {
            let command = commands[index % commands.count]
            let modifiers: NSEvent.ModifierFlags = [.command, .control, .shift]
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
                characters: symbol, charactersIgnoringModifiers: symbol, isARepeat: false, keyCode: code))
            model.startRecording(for: command)
            model.handleCaptureEvent(event)
            let original = ShortcutsKey(characters: symbol, modifiers: modifiers)
            XCTAssertEqual(Shortcuts.key(for: command), original)
            XCTAssertEqual(try item(command, in: model).shortcutKeycapTokens, ["⌃", "⇧", "⌘", digit])
            XCTAssertTrue(try XCTUnwrap(ShortcutsKey.eventKeys(for: event)).matches(original))
            let bridgeKey = try XCTUnwrap(PhiChromiumCoordinator.shared.keyEquivalentOverride(
                forCommand: Int32(command.rawValue)))
            XCTAssertEqual(bridgeKey["keyEquivalent"] as? String, symbol)
            XCTAssertEqual(bridgeKey["modifierFlags"] as? UInt, modifiers.subtracting(.shift).rawValue)
            try Shortcuts.reloadOverrides().get()
            XCTAssertEqual(Shortcuts.key(for: command), original)
            model.searchText = "cmd control shift \(digit)"
            XCTAssertTrue(model.filteredSections.flatMap(\.items).contains { $0.command == command })
            model.searchText = ""
            model.restoreDefaultShortcut(for: command)
        }
    }

    func testMultiplyRecordingKeepsDistinctDisplaysAndExistingMenuMatches() throws {
        try XCTUnwrap(AppController.shared).startObservingServiceShortcuts()
        let cases: [(UInt16, NSEvent.ModifierFlags, [String], String, NSEvent.ModifierFlags)] = [
            (67, [.command, .numericPad], ["⌘", "*"], "*", .command),
            (67, [.command, .shift, .numericPad], ["⇧", "⌘", "*"], "*", [.command, .shift]),
            (28, [.command, .shift], ["⇧", "⌘", "8"], "8", [.command, .shift])
        ]
        let menuEvents = try cases.map { code, flags, _, _, _ in
            let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true))
            event.flags = CGEventFlags(rawValue: UInt64(flags.rawValue))
            return try XCTUnwrap(NSEvent(cgEvent: event))
        }
        for command in [CommandWrapper.IDC_RELOAD, .PHI_COPY_URL] {
            let model = ShortcutsViewModel()
            for (index, (code, flags, tokens, displayCharacter, displayModifiers)) in cases.enumerated() {
                let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                    modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                    characters: "*", charactersIgnoringModifiers: "*", isARepeat: false, keyCode: code))
                model.startRecording(for: command)
                model.handleCaptureEvent(event)
                let key = try XCTUnwrap(Shortcuts.key(for: command))
                XCTAssertEqual(key.characters, "*")
                XCTAssertEqual(key.modifiers, flags.subtracting(.numericPad))
                XCTAssertEqual(try item(command, in: model).shortcutKeycapTokens, tokens)
                try Shortcuts.reloadOverrides().get()
                XCTAssertEqual(Shortcuts.key(for: command), key)
                XCTAssertEqual(try item(command, in: model).shortcutKeycapTokens, tokens)
                let bridge = try XCTUnwrap(PhiChromiumCoordinator.shared.keyEquivalentOverride(
                    forCommand: Int32(command.rawValue)))
                XCTAssertEqual(bridge["keyEquivalent"] as? String, "*")
                XCTAssertEqual(bridge["modifierFlags"] as? UInt, key.menuKeyEquivalent.modifiers.rawValue)

                let menu = NSMenu()
                menu.autoenablesItems = false
                let target = ReleasedShortcutActionTarget()
                let entry = NSMenuItem(title: "Multiply", action: #selector(ReleasedShortcutActionTarget.invoke(_:)),
                                       keyEquivalent: "")
                entry.tag = command.rawValue
                entry.target = target
                Shortcuts.updateShortcut(for: entry)
                menu.addItem(entry)
                let bindings = Shortcuts.menuBindings(in: menu)
                let before = menuEvents.map { menu.performKeyEquivalent(with: $0) }
                XCTAssertTrue(before[index])
                // The number-row chord and unshifted keypad chord retain the
                // existing equivalence; this change only distinguishes display.
                if index != 1 {
                    XCTAssertTrue(before[0])
                    XCTAssertTrue(before[2])
                }
                NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
                XCTAssertEqual(entry.keyEquivalent, displayCharacter)
                XCTAssertEqual(entry.keyEquivalentModifierMask, displayModifiers)
                XCTAssertEqual(Shortcuts.menuBindings(in: menu), bindings)
                let countBefore = target.invocationCount
                XCTAssertEqual(menuEvents.map { menu.performKeyEquivalent(with: $0) }, before)
                XCTAssertEqual(target.invocationCount - countBefore, before.filter { $0 }.count)
                NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
                XCTAssertEqual(menu.items.count, 1)
                XCTAssertEqual(entry.keyEquivalent, key.menuKeyEquivalent.characters)
                XCTAssertEqual(entry.keyEquivalentModifierMask, key.menuKeyEquivalent.modifiers)
                XCTAssertEqual(menuEvents.map { menu.performKeyEquivalent(with: $0) }, before)
            }
            model.restoreDefaultShortcut(for: command)
        }
    }

    func testBookmarkManagerBindingSurvivesNativeMenuRepopulation() throws {
        let target = ReleasedShortcutActionTarget()
        let menu = NSMenu()
        let command = CommandWrapper.IDC_SHOW_BOOKMARK_MANAGER
        let action = #selector(ReleasedShortcutActionTarget.invoke(_:))
        for state in [ShortcutOverride.custom(customKey), .disabled, nil] {
            try Shortcuts.setOverride(state, for: command).get()
            // Repopulating the native menu replaces the items Chromium built.
            for _ in 0..<2 {
                BookmarkMenuContentBuilder.populate(menu: menu, bookmarks: [],
                    canBookmarkCurrentTab: false, canBookmarkAllTabs: false, canExportBookmarks: false,
                    target: target, bookmarkThisTabAction: action, bookmarkAllTabsAction: action,
                    bookmarkManagerAction: action, exportBookmarksAction: action, openBookmarkAction: action)
                let manager = try XCTUnwrap(menu.items.first { $0.tag == command.rawValue })
                let expected = Shortcuts.key(for: command)?.menuKeyEquivalent
                XCTAssertEqual(manager.keyEquivalent, expected?.characters ?? "")
                XCTAssertEqual(manager.keyEquivalentModifierMask, expected?.modifiers ?? [])
                XCTAssertTrue(manager.target === target)
                XCTAssertEqual(manager.action, action)
                let keys = Shortcuts.menuBindings(in: menu).filter { $0.commandID == command.rawValue }.map(\.key.menuKeyEquivalent)
                XCTAssertEqual(keys, expected.map { [$0] } ?? [])
            }
        }
    }

    func testQuitStaysFixedAcrossLegacyOverridesReloadAndRestore() throws {
        let command = CommandWrapper.IDC_EXIT
        let defaultKey = try XCTUnwrap(Shortcuts.DefaultShortcuts[command])
        let bridge = try XCTUnwrap(ChromiumLauncher.sharedInstance().bridge)

        func assertFixedQuit() throws {
            bridge.requestRebuildMainMenu()
            let menu = try XCTUnwrap(NSApp.mainMenu)
            let appMenu = try XCTUnwrap(menu.items.first?.submenu)
            let quit = try XCTUnwrap(appMenu.items.first { $0.tag == command.rawValue })
            XCTAssertEqual(quit.action, NSSelectorFromString("terminate:"))
            XCTAssertTrue(quit.target === NSApp)
            XCTAssertEqual(quit.keyEquivalent, "q")
            XCTAssertEqual(quit.keyEquivalentModifierMask, .command)
            XCTAssertEqual(Shortcuts.key(for: command), defaultKey)
            XCTAssertNil(Shortcuts.overrideState(for: command.rawValue))
            XCTAssertFalse(Shortcuts.isOverridden(command))
            let override = try XCTUnwrap(PhiChromiumCoordinator.shared.keyEquivalentOverride(
                forCommand: Int32(command.rawValue)))
            XCTAssertEqual(override["keyEquivalent"] as? String, "q")
            XCTAssertEqual(override["modifierFlags"] as? UInt, NSEvent.ModifierFlags.command.rawValue)
            let model = ShortcutsViewModel()
            XCTAssertFalse(model.sections.flatMap(\.items).contains { $0.command == command })
            XCTAssertEqual(Set(model.inventory.bindings(for: command.rawValue).map(\.key)), [defaultKey])
        }

        try assertFixedQuit()
        let model = ShortcutsViewModel()
        model.setCustomShortcut(for: command, key: customKey)
        model.disableShortcut(for: command)
        XCTAssertEqual(writeCount, 0)
        XCTAssertTrue(Shortcuts.configuration.overrides.isEmpty)
        try assertFixedQuit()

        for legacy in [ShortcutOverride.custom(customKey), .disabled, .excluding([defaultKey])] {
            // Simulate configurations saved before Quit became fixed.
            let url = try XCTUnwrap(Shortcuts.configuration.fileURL)
            try Shortcuts.configuration.set(legacy, for: command.rawValue, at: url)
            try Shortcuts.reloadOverrides().get()
            XCTAssertEqual(Shortcuts.configuration.overrides[command.rawValue], legacy)
            try assertFixedQuit()
        }
        try Shortcuts.restoreOverrides().get()
        try assertFixedQuit()
    }

    func testSelectionCommandsKeepNativeActionsAcrossRebindReloadDisableAndRestore() throws {
        let bridge = try XCTUnwrap(ChromiumLauncher.sharedInstance().bridge)
        let commands: [(CommandWrapper, String)] = [
            (.IDS_EDIT_USE_SELECTION_MAC, "copyToFindPboard:"),
            (.IDS_EDIT_JUMP_TO_SELECTION_MAC, "centerSelectionInVisibleArea:")
        ]
        let model = ShortcutsViewModel()
        let key = ShortcutsKey(characters: "e", modifiers: [.command, .control, .shift])

        func assertMenu(_ command: CommandWrapper, action: String, key: ShortcutsKey?) throws {
            bridge.requestRebuildMainMenu()
            model.rebuildSections()
            let menu = try XCTUnwrap(NSApp.mainMenu)
            let edit = try XCTUnwrap(ChromiumMainMenuRole.edit.item(in: menu)?.submenu)
            func matches(in menu: NSMenu) -> [NSMenuItem] {
                menu.items.flatMap { item -> [NSMenuItem] in
                    if let submenu = item.submenu { return matches(in: submenu) }
                    return item.action == NSSelectorFromString(action) ? [item] : []
                }
            }
            let items = matches(in: edit)
            XCTAssertEqual(items.count, 1)
            let entry = try XCTUnwrap(items.first)
            XCTAssertEqual(entry.tag, command.rawValue)
            XCTAssertNil(entry.target)
            XCTAssertEqual(entry.keyEquivalent, key?.menuKeyEquivalent.characters ?? "")
            XCTAssertEqual(entry.keyEquivalentModifierMask, key?.menuKeyEquivalent.modifiers ?? [])
            XCTAssertEqual(try item(command, in: model).shortcutKey, key)
            XCTAssertFalse(model.inventory.bindings.contains { $0.owner == .nativeAction(action) })
            let actual = Shortcuts.menuBindings(in: menu).filter { $0.commandID == command.rawValue }
            XCTAssertEqual(actual.map { $0.key.menuKeyEquivalent }, key.map { [$0.menuKeyEquivalent] } ?? [])
            if let key {
                let target = ReleasedShortcutActionTarget()
                let originalTarget = entry.target
                defer { entry.target = originalTarget }
                entry.target = target
                let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                    modifierFlags: key.modifiers, timestamp: 0, windowNumber: 0, context: nil,
                    characters: key.menuKeyEquivalent.characters,
                    charactersIgnoringModifiers: key.menuKeyEquivalent.characters,
                    isARepeat: false, keyCode: command == .IDS_EDIT_JUMP_TO_SELECTION_MAC && key.modifiers == .command ? 38 : 14))
                XCTAssertTrue(menu.performKeyEquivalent(with: event))
                XCTAssertEqual(target.invocationCount, 1)
            }
        }

        for (command, action) in commands {
            let original = try XCTUnwrap(Shortcuts.DefaultShortcuts[command])
            try assertMenu(command, action: action, key: original)
            model.setCustomShortcut(for: command, key: key)
            try assertMenu(command, action: action, key: key)
            try Shortcuts.reloadOverrides().get()
            try assertMenu(command, action: action, key: key)
            model.disableShortcut(for: command)
            try assertMenu(command, action: action, key: nil)
            try Shortcuts.reloadOverrides().get()
            try assertMenu(command, action: action, key: nil)
            model.restoreDefaultShortcut(for: command)
            try assertMenu(command, action: action, key: original)
        }

        let useSelection = CommandWrapper.IDS_EDIT_USE_SELECTION_MAC
        let jump = CommandWrapper.IDS_EDIT_JUMP_TO_SELECTION_MAC
        model.setCustomShortcut(for: jump, key: try XCTUnwrap(Shortcuts.DefaultShortcuts[useSelection]))
        model.rebuildSections()
        XCTAssertTrue(model.conflicts(for: jump).contains { $0.command == useSelection })
        XCTAssertTrue(model.conflicts(for: useSelection).contains { $0.command == jump })
        XCTAssertNil(Shortcuts.overrideState(for: useSelection.rawValue))
    }

    func testBookmarkBarCommandKeepsNativeActionAcrossShortcutChanges() throws {
        let bridge = try XCTUnwrap(ChromiumLauncher.sharedInstance().bridge)
        let layoutKey = PhiPreferences.GeneralSettings.layoutModeKey
        let previousLayout = UserDefaults.standard.object(forKey: layoutKey)
        defer { UserDefaults.standard.set(previousLayout, forKey: layoutKey) }
        PhiPreferences.GeneralSettings.saveLayoutMode(.comfortable)
        let command = CommandWrapper.IDC_SHOW_BOOKMARK_BAR
        let model = ShortcutsViewModel()
        XCTAssertNotNil(try item(command, in: model))

        func assertMenu(_ key: ShortcutsKey?) throws {
            bridge.requestRebuildMainMenu()
            let menu = try XCTUnwrap(NSApp.mainMenu)
            let view = try XCTUnwrap(ChromiumMainMenuRole.view.item(in: menu)?.submenu)
            let items = view.items.filter { $0.tag == command.rawValue }
            XCTAssertEqual(items.count, 1)
            let bookmark = try XCTUnwrap(items.first)
            XCTAssertEqual(bookmark.action, NSSelectorFromString("toggleBookmarkBar:"))
            XCTAssertEqual(bookmark.keyEquivalent, key?.menuKeyEquivalent.characters ?? "")
            XCTAssertEqual(bookmark.keyEquivalentModifierMask, key?.menuKeyEquivalent.modifiers ?? [])
            XCTAssertEqual(Shortcuts.key(for: command), key)
        }

        try assertMenu(Shortcuts.DefaultShortcuts[command])
        model.setCustomShortcut(for: command, key: customKey)
        try assertMenu(customKey)
        try Shortcuts.reloadOverrides().get()
        try assertMenu(customKey)
        model.disableShortcut(for: command)
        try assertMenu(nil)
        model.restoreDefaultShortcut(for: command)
        try assertMenu(Shortcuts.DefaultShortcuts[command])
    }

    func testSystemConflictIsInformationalAndIncludedInConflictFilter() throws {
        let defaultKey = try XCTUnwrap(Shortcuts.key(for: .IDC_NEW_WINDOW))
        let system = ShortcutBinding(owner: .system, key: defaultKey, scope: .all, source: .system)
        let model = ShortcutsViewModel(additionalBindings: { [system] })
        let shortcut = try item(.IDC_NEW_WINDOW, in: model)
        XCTAssertTrue(shortcut.hasSystemConflict)
        XCTAssertTrue(shortcut.hasConflict)
        XCTAssertTrue(shortcut.conflictingCommandNames.isEmpty)
        let conflict = try XCTUnwrap(model.conflicts(for: .IDC_NEW_WINDOW).first)
        XCTAssertTrue(conflict.isSystem)
        XCTAssertNil(conflict.command)
        XCTAssertEqual(conflict.name, ShortcutConflictItem.systemMessage)
        XCTAssertFalse(model.reservedShortcuts.contains { $0.id == .system })
        model.filter = .conflicting
        XCTAssertTrue(model.filteredSections.flatMap(\.items).contains { $0.command == .IDC_NEW_WINDOW })
        XCTAssertTrue(Shortcuts.configuration.overrides.isEmpty)
        XCTAssertEqual(writeCount, 0)
    }

    func testSystemAndApplicationConflictsCoexistAndSavingPreservesOtherBindings() throws {
        let system = ShortcutBinding(owner: .system, key: customKey, scope: .all, source: .system)
        let model = ShortcutsViewModel(additionalBindings: {
            [system, ShortcutBinding(commandID: CommandWrapper.IDC_RELOAD.rawValue,
                                     key: self.customKey, scope: .browser, source: .hidden)]
        })
        model.setCustomShortcut(for: .IDC_DUPLICATE_TAB, key: customKey)
        let shortcut = try item(.IDC_DUPLICATE_TAB, in: model)
        XCTAssertTrue(shortcut.hasSystemConflict)
        XCTAssertEqual(shortcut.conflictingCommandNames.count, 1)
        let conflicts = model.conflicts(for: .IDC_DUPLICATE_TAB)
        XCTAssertEqual(conflicts.filter(\.isSystem).count, 1)
        XCTAssertEqual(conflicts.first { !$0.isSystem }?.command, .IDC_RELOAD)
        XCTAssertEqual(Shortcuts.configuration.overrides, [CommandWrapper.IDC_DUPLICATE_TAB.rawValue: .custom(customKey)])
        XCTAssertTrue(model.inventory.bindings.contains(system))
        try Shortcuts.reloadOverrides().get()
        model.rebuildSections()
        XCTAssertTrue(try item(.IDC_DUPLICATE_TAB, in: model).hasSystemConflict)
        model.disableShortcut(for: .IDC_DUPLICATE_TAB)
        XCTAssertFalse(try item(.IDC_DUPLICATE_TAB, in: model).hasConflict)
    }

    func testSystemConflictsRefreshAfterApplicationActivation() throws {
        let defaultKey = try XCTUnwrap(Shortcuts.key(for: .IDC_NEW_WINDOW))
        var active = true
        let model = ShortcutsViewModel(additionalBindings: {
            active ? [ShortcutBinding(owner: .system, key: defaultKey, scope: .all, source: .system)] : []
        })
        XCTAssertTrue(try item(.IDC_NEW_WINDOW, in: model).hasSystemConflict)
        model.filter = .conflicting
        active = false
        let refreshed = expectation(description: "System reservations refreshed after activation")
        var observer: AnyCancellable?
        observer = model.$sections.dropFirst().filter { sections in
            sections.flatMap(\.items).contains { $0.command == .IDC_NEW_WINDOW && !$0.hasSystemConflict }
        }.prefix(1).sink { _ in refreshed.fulfill() }
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        wait(for: [refreshed], timeout: 2)
        observer?.cancel()
        XCTAssertFalse(try item(.IDC_NEW_WINDOW, in: model).hasConflict)
        XCTAssertFalse(model.filteredSections.flatMap(\.items).contains { $0.command == .IDC_NEW_WINDOW })
        XCTAssertEqual(writeCount, 0)
    }

    func testConflictDetailsDeduplicateOwnersAndOnlyLinkVisibleCommands() throws {
        let hiddenCommand = CommandWrapper.IDC_SHOW_READING_MODE_KEYBOARD
        let model = ShortcutsViewModel(additionalBindings: {
            [self.customNativeBinding(),
             ShortcutBinding(commandID: hiddenCommand.rawValue, key: self.customKey,
                             scope: .browser, source: .hidden, title: "Reading Mode"),
             ShortcutBinding(commandID: CommandWrapper.IDC_RELOAD.rawValue, key: self.customKey,
                             scope: .browser, source: .menu),
             ShortcutBinding(commandID: CommandWrapper.IDC_RELOAD.rawValue, key: self.customKey,
                             scope: .browser, source: .hidden)]
        })
        model.setCustomShortcut(for: .IDC_DUPLICATE_TAB, key: customKey)
        let conflicts = model.conflicts(for: .IDC_DUPLICATE_TAB)
        XCTAssertEqual(conflicts.count, 3)
        XCTAssertEqual(conflicts.filter { $0.command == .IDC_RELOAD }.count, 1)
        XCTAssertEqual(conflicts.first { $0.id == .nativeAction("copy:") }?.name, "Copy")
        XCTAssertNil(try XCTUnwrap(conflicts.first { $0.id == .nativeAction("copy:") }).command)
        XCTAssertNil(try XCTUnwrap(conflicts.first { $0.id == .command(hiddenCommand.rawValue) }).command)
        XCTAssertEqual(conflicts.first { $0.command == .IDC_RELOAD }?.keys, [customKey.displayString])
    }

    func testBrowserCommandTitlesStayConsistentAcrossRowsConflictsAndSearch() throws {
        let commands: [CommandWrapper] = [.IDC_CLEAR_BROWSING_DATA, .IDC_SHOW_BOOKMARK_BAR,
                                          .IDC_SHOW_BOOKMARK_MANAGER]
        for source in [ShortcutBinding.Source.menu, .hidden] {
            let bindings = (commands + [.IDC_DUPLICATE_TAB]).map { command in
                ShortcutBinding(commandID: command.rawValue, key: customKey,
                                scope: .browser, source: source, title: "Unlocalized inventory title")
            }
            let model = ShortcutsViewModel(additionalBindings: { bindings }, availableCommands: { commands })
            let conflicts = model.conflicts(for: .IDC_DUPLICATE_TAB)
            for command in commands {
                let row = try item(command, in: model)
                let conflict = try XCTUnwrap(conflicts.first { $0.command == command })
                XCTAssertEqual(conflict.name, row.name, "\(command), \(source)")
                XCTAssertNotEqual(row.name, "Unlocalized inventory title")
                XCTAssertTrue(row.searchKeywords.contains(row.name.lowercased()))

                // English aliases remain searchable after the title is translated.
                for query in [command.displayName, row.name] {
                    model.searchText = query
                    XCTAssertTrue(model.filteredSections.flatMap(\.items).contains { $0.command == command })
                }
            }
        }
        XCTAssertEqual(writeCount, 0)
    }

    func testSystemAndUnknownCommandConflictsKeepTheirMenuTitles() throws {
        let systemCommand = CommandWrapper.IDC_CONTENT_CONTEXT_COPY
        let unknownID = 123456
        let bindings = [
            ShortcutBinding(commandID: systemCommand.rawValue, key: customKey,
                            scope: .browser, source: .menu, title: "System menu title"),
            ShortcutBinding(commandID: unknownID, key: customKey,
                            scope: .browser, source: .menu, title: "External menu title"),
            ShortcutBinding(commandID: CommandWrapper.IDC_DUPLICATE_TAB.rawValue, key: customKey,
                            scope: .browser, source: .hidden)
        ]
        let model = ShortcutsViewModel(additionalBindings: { bindings }, availableCommands: { [] })
        let conflicts = model.conflicts(for: .IDC_DUPLICATE_TAB)
        XCTAssertEqual(conflicts.first { $0.id == .command(systemCommand.rawValue) }?.name, "System menu title")
        XCTAssertEqual(conflicts.first { $0.id == .command(unknownID) }?.name, "External menu title")
        XCTAssertEqual(writeCount, 0)
    }

    func testConflictNavigationClearsAllFiltersWithoutRecording() throws {
        let model = ShortcutsViewModel(additionalBindings: { [] })
        model.filter = .customized
        model.searchText = "Duplicate Tab"
        model.editingCommand = .IDC_DUPLICATE_TAB
        model.selectConflict(.IDC_RELOAD)
        XCTAssertEqual(model.searchText, "")
        XCTAssertEqual(model.filter, .all)
        XCTAssertNil(model.capture)
        XCTAssertEqual(model.selectedItem?.command, .IDC_RELOAD)
        XCTAssertTrue(model.filteredSections.flatMap(\.items).contains { $0.command == .IDC_RELOAD })
    }

    func testCustomizedFilterIncludesDisabledShortcutsAndUpdatesAfterRestore() throws {
        let model = ShortcutsViewModel(additionalBindings: { [] })
        model.setCustomShortcut(for: .IDC_NEW_WINDOW, key: customKey)
        model.disableShortcut(for: .PHI_COPY_URL)
        model.filter = .customized
        XCTAssertEqual(Set(model.filteredSections.flatMap(\.items).map(\.command)),
                       [.IDC_NEW_WINDOW, .PHI_COPY_URL])
        XCTAssertTrue(model.filteredReservedShortcuts.isEmpty)
        model.selectedCommand = .IDC_NEW_WINDOW
        model.restoreDefaultShortcut(for: .IDC_NEW_WINDOW)
        XCTAssertEqual(model.filteredSections.flatMap(\.items).map(\.command), [.PHI_COPY_URL])
        XCTAssertEqual(model.selectedCommand, .PHI_COPY_URL)
        model.restoreDefaultShortcut(for: .PHI_COPY_URL)
        XCTAssertTrue(model.filteredSections.isEmpty)
        XCTAssertNil(model.selectedCommand)
    }

    func testSectionFilterReplacesConflictFilterAndCombinesWithSearch() throws {
        let model = ShortcutsViewModel(additionalBindings: { [] })
        let newTabKey = try XCTUnwrap(Shortcuts.key(for: .IDC_NEW_TAB))
        model.setCustomShortcut(for: .IDC_NEW_WINDOW, key: newTabKey)
        model.filter = .conflicting
        let conflicting = model.filteredSections.flatMap(\.items)
        XCTAssertTrue(conflicting.contains { $0.command == .IDC_NEW_WINDOW })
        XCTAssertTrue(conflicting.contains { $0.command == .IDC_NEW_TAB })
        XCTAssertFalse(conflicting.contains { $0.command == .IDC_RELOAD })

        let section = try XCTUnwrap(model.sections.first { $0.items.contains { $0.command == .IDC_RELOAD } })
        model.startRecording(for: .IDC_NEW_WINDOW)
        model.filter = .section(section.category)
        XCTAssertNil(model.capture)
        XCTAssertEqual(model.filteredSections.map(\.category), [section.category])
        XCTAssertEqual(model.filteredSections.flatMap(\.items).map(\.command), section.items.map(\.command))
        XCTAssertTrue(model.filteredReservedShortcuts.isEmpty)
        model.searchText = try item(.IDC_RELOAD, in: model).name
        XCTAssertEqual(Set(model.filteredSections.flatMap(\.items).map(\.command)),
                       [.IDC_RELOAD, .IDC_RELOAD_BYPASSING_CACHE])
        model.searchText = "no-shortcut-matches-this-query"
        XCTAssertTrue(model.filteredSections.isEmpty)
        XCTAssertNil(model.selectedCommand)
        model.searchText = ""
        model.filter = .all
        XCTAssertEqual(model.filteredSections.map(\.category), model.sections.map(\.category))
    }

    func testRowSelectionDoesNotCaptureWindowCloseShortcut() throws {
        let model = ShortcutsViewModel(additionalBindings: { [] })
        model.selectedCommand = .IDC_NEW_WINDOW
        let original = Shortcuts.key(for: .IDC_NEW_WINDOW)
        let close = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13
        ))
        model.handleCaptureEvent(close)
        XCTAssertNil(model.capture)
        XCTAssertEqual(Shortcuts.key(for: .IDC_NEW_WINDOW), original)
        XCTAssertEqual(writeCount, 0)
        model.startRecording(for: .IDC_NEW_WINDOW)
        model.selectedCommand = .IDC_NEW_TAB
        XCTAssertNil(model.capture)
    }

    func testShortcutControlStartsRecordingAndTransfersToAnotherCommand() {
        let model = ShortcutsViewModel(additionalBindings: { [] })
        XCTAssertNil(model.capture)
        model.startRecording(for: .IDC_NEW_WINDOW)
        XCTAssertEqual(model.selectedCommand, .IDC_NEW_WINDOW)
        XCTAssertEqual(model.capture, .command(.IDC_NEW_WINDOW))
        let previousSession = model.captureSessionID
        model.startRecording(for: .IDC_NEW_TAB)
        XCTAssertEqual(model.selectedCommand, .IDC_NEW_TAB)
        XCTAssertEqual(model.capture, .command(.IDC_NEW_TAB))
        model.cancelCapture(sessionID: previousSession)
        XCTAssertEqual(model.capture, .command(.IDC_NEW_TAB))
        XCTAssertEqual(writeCount, 0)
    }

    func testModifierPreviewDoesNotSaveOrRestartCaptureAndClearsOnSelection() {
        let model = ShortcutsViewModel(additionalBindings: { [] })
        model.startRecording(for: .IDC_NEW_WINDOW)
        let session = model.captureSessionID
        model.handleCaptureModifiers([.command, .shift, .capsLock])
        XCTAssertEqual(model.recordingModifiers, [.command, .shift])
        XCTAssertEqual(model.captureSessionID, session)
        XCTAssertEqual(writeCount, 0)
        model.handleCaptureModifiers(.command)
        XCTAssertEqual(model.recordingModifiers, .command)
        model.startRecording(for: .IDC_NEW_TAB)
        XCTAssertEqual(model.recordingModifiers, [])
        model.handleCaptureModifiers(.option)
        model.cancelCapture(sessionID: model.captureSessionID)
        XCTAssertEqual(model.recordingModifiers, [])
        XCTAssertEqual(writeCount, 0)
    }

    func testModifierPreviewIgnoresInactiveCapture() {
        let model = ShortcutsViewModel(additionalBindings: { [] })
        model.handleCaptureModifiers(.command)
        XCTAssertEqual(model.recordingModifiers, [])
        XCTAssertEqual(writeCount, 0)
    }

    func testDetailKeycapsPreserveDisplayNotationAndDisabledState() throws {
        let model = ShortcutsViewModel(additionalBindings: { [] })
        XCTAssertEqual(try item(.IDC_NEW_WINDOW, in: model).shortcutKeycapTokens, ["⌘", "N"])
        XCTAssertEqual(try item(.IDC_SELECT_PREVIOUS_TAB, in: model).shortcutKeycapTokens, ["⇧", "⌘", "["])
        XCTAssertEqual(try item(.IDC_SELECT_NEXT_TAB, in: model).shortcutKeycapTokens, ["⇧", "⌘", "]"])
        model.setCustomShortcut(for: .IDC_NEW_WINDOW, key: customKey)
        XCTAssertEqual(try item(.IDC_NEW_WINDOW, in: model).shortcutKeycapTokens, ["⌃", "⌘", "J"])
        model.disableShortcut(for: .IDC_NEW_WINDOW)
        XCTAssertEqual(try item(.IDC_NEW_WINDOW, in: model).shortcutKeycapTokens, [])
    }

    func testRestartingRecordingCreatesFreshCaptureAndIgnoresOldCancellation() {
        let model = ShortcutsViewModel(additionalBindings: { [] })
        model.startRecording(for: .IDC_NEW_WINDOW)
        let previousSession = model.captureSessionID
        model.startRecording(for: .IDC_NEW_WINDOW)
        XCTAssertNotEqual(model.captureSessionID, previousSession)
        model.cancelCapture(sessionID: previousSession)
        XCTAssertEqual(model.capture, .command(.IDC_NEW_WINDOW))
        model.cancelCapture(sessionID: model.captureSessionID)
        XCTAssertNil(model.capture)
        XCTAssertEqual(writeCount, 0)
    }

    func testShortcutControlDoesNotRecordWhenConfigurationCannotBeRead() {
        contents = Data("damaged configuration".utf8)
        _ = Shortcuts.reloadOverrides()
        let model = ShortcutsViewModel(additionalBindings: { [] })
        model.startRecording(for: .IDC_NEW_WINDOW)
        XCTAssertEqual(model.selectedCommand, .IDC_NEW_WINDOW)
        XCTAssertNil(model.capture)
        XCTAssertEqual(writeCount, 0)
    }

    func testFilteringSelectsVisibleCommandAndClearsDetailForNoResults() throws {
        let model = ShortcutsViewModel(additionalBindings: { [] })
        model.searchText = "Duplicate Tab"
        XCTAssertEqual(model.selectedItem?.command, .IDC_DUPLICATE_TAB)
        XCTAssertNil(model.capture)
        model.editingCommand = .IDC_DUPLICATE_TAB
        model.searchText = "no-shortcut-matches-this-query"
        XCTAssertNil(model.selectedItem)
        XCTAssertNil(model.capture)
        model.searchText = ""
        XCTAssertNotNil(model.selectedItem)
    }

    func testOverrideStateIsIndependentOfConflictsIncludingAfterRestore() throws {
        let model = ShortcutsViewModel(additionalBindings: { [] })
        let reload = try XCTUnwrap(Shortcuts.DefaultShortcuts[.IDC_RELOAD])
        model.setCustomShortcut(for: .IDC_DUPLICATE_TAB, key: reload)
        XCTAssertTrue(try item(.IDC_DUPLICATE_TAB, in: model).isOverridden)
        XCTAssertTrue(try item(.IDC_DUPLICATE_TAB, in: model).hasConflict)
        XCTAssertFalse(try item(.IDC_RELOAD, in: model).isOverridden)
        XCTAssertTrue(try item(.IDC_RELOAD, in: model).hasConflict)
        model.disableShortcut(for: .IDC_RELOAD)
        XCTAssertTrue(try item(.IDC_RELOAD, in: model).isOverridden)
        XCTAssertFalse(try item(.IDC_RELOAD, in: model).hasConflict)
        model.restoreDefaultShortcut(for: .IDC_RELOAD)
        XCTAssertFalse(try item(.IDC_RELOAD, in: model).isOverridden)
        XCTAssertTrue(try item(.IDC_RELOAD, in: model).hasConflict)
    }

    func testShiftedKeypadSurvivesSettingsReloadBridgeAndMenuInventory() throws {
        let source = "com.apple.keylayout.US"
        let shiftedEvent = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.control, .shift, .numericPad], timestamp: 0, windowNumber: 0,
            context: nil, characters: "1", charactersIgnoringModifiers: "1", isARepeat: false, keyCode: 83))
        let key = try XCTUnwrap(ShortcutsKey.recordingKey(for: shiftedEvent, inputSourceIdentifier: source))
        for command in [CommandWrapper.IDC_SELECT_TAB_0, .PHI_COPY_URL] {
            let model = ShortcutsViewModel(additionalBindings: { [] })
            model.setCustomShortcut(for: command, key: key)
            XCTAssertNil(model.persistenceFailure)
            try Shortcuts.configuration.reload(from: XCTUnwrap(Shortcuts.configuration.fileURL))
            CommandDispatcher.reloadPhiShortcutMap()
            XCTAssertEqual(Shortcuts.key(for: command), key)
            let bridge = try XCTUnwrap(PhiChromiumCoordinator.shared.keyEquivalentOverride(forCommand: Int32(command.rawValue)))
            XCTAssertEqual(bridge["keyEquivalent"] as? String, "1")
            XCTAssertEqual(bridge["modifierFlags"] as? UInt, NSEvent.ModifierFlags([.control, .shift]).rawValue)

            let menu = NSMenu()
            let menuItem = NSMenuItem(title: "Keypad binding", action: NSSelectorFromString("commandDispatch:"), keyEquivalent: "")
            menuItem.tag = command.rawValue
            menu.addItem(menuItem)
            Shortcuts.updateShortcut(for: menuItem)
            XCTAssertEqual(menuItem.keyEquivalentModifierMask, [.control, .shift])
            let bindings = Shortcuts.menuBindings(in: menu)
            XCTAssertEqual(bindings.count, 1)
            XCTAssertEqual(bindings.first?.key.menuKeyEquivalent, key.menuKeyEquivalent)
            let inventory = ShortcutInventory(bindings: bindings)
            XCTAssertTrue(inventory.occupants(of: .init(characters: "1", modifiers: .control)).isEmpty)
            XCTAssertEqual(inventory.occupants(of: key).map(\.commandID), [command.rawValue])
            XCTAssertEqual(try XCTUnwrap(ShortcutsKey.eventKeys(for: shiftedEvent, inputSourceIdentifier: source))
                .matches(Shortcuts.key(for: command)), true)
            try Shortcuts.setOverride(nil, for: command).get()
        }
    }

    func testSaveFailureKeepsUIAndBridgeAtPreviousBindingThenRetrySucceeds() throws {
        let model = ShortcutsViewModel()
        let command = CommandWrapper.PHI_COPY_URL
        let previousKey = Shortcuts.key(for: command)
        rejectsWrites = true
        model.setCustomShortcut(for: command, key: customKey)

        XCTAssertEqual(model.persistenceFailure, .save)
        XCTAssertEqual(try item(command, in: model).shortcutKey, previousKey)
        XCTAssertNil(Shortcuts.overrideState(for: command.rawValue))
        XCTAssertNil(PhiChromiumCoordinator.shared.keyEquivalentOverride(forCommand: Int32(command.rawValue)))
        XCTAssertEqual(writeCount, 0)
        XCTAssertEqual(contents, Data("[]".utf8))

        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: customKey.modifiers,
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "j", charactersIgnoringModifiers: "j", isARepeat: false, keyCode: 38
        ))
        XCTAssertNil(CommandDispatcher.interceptedPhiCommand(
            for: event, inputSourceIdentifier: "com.apple.keylayout.US"
        ))

        rejectsWrites = false
        model.setCustomShortcut(for: command, key: customKey)
        XCTAssertNil(model.persistenceFailure)
        XCTAssertEqual(try item(command, in: model).shortcutKey, customKey)
        XCTAssertEqual(Shortcuts.overrideState(for: command.rawValue), .custom(customKey))
        XCTAssertEqual(writeCount, 1)
        let bridge = try XCTUnwrap(PhiChromiumCoordinator.shared.keyEquivalentOverride(forCommand: Int32(command.rawValue)))
        XCTAssertEqual(bridge["keyEquivalent"] as? String, "j")
        XCTAssertEqual(bridge["modifierFlags"] as? UInt, customKey.menuKeyEquivalent.modifiers.rawValue)
        XCTAssertEqual(CommandDispatcher.interceptedPhiCommand(
            for: event, inputSourceIdentifier: "com.apple.keylayout.US"
        ), command)
    }

    func testDisableAndRestoreExposeDistinctBridgeStates() throws {
        let model = ShortcutsViewModel()
        let command = CommandWrapper.IDC_RELOAD
        model.disableShortcut(for: command)
        XCTAssertNil(try item(command, in: model).shortcutKey)
        let bridge = try XCTUnwrap(PhiChromiumCoordinator.shared.keyEquivalentOverride(forCommand: Int32(command.rawValue)))
        XCTAssertEqual(bridge["keyEquivalent"] as? String, "")
        XCTAssertEqual(Shortcuts.overrideState(for: command.rawValue), .disabled)

        model.restoreDefaultShortcut(for: command)
        XCTAssertNil(PhiChromiumCoordinator.shared.keyEquivalentOverride(forCommand: Int32(command.rawValue)))
        XCTAssertEqual(try item(command, in: model).shortcutKey, Shortcuts.DefaultShortcuts[command])
        XCTAssertEqual(contents, Data("[]".utf8))
    }

    func testCorruptConfigurationBlocksChangesUntilRecoveryPreservesOriginal() throws {
        let damaged = Data("damaged configuration".utf8)
        contents = damaged
        _ = Shortcuts.reloadOverrides()
        let model = ShortcutsViewModel()
        XCTAssertEqual(model.persistenceFailure, .load)
        XCTAssertFalse(model.canEdit)
        model.setCustomShortcut(for: .PHI_COPY_URL, key: customKey)
        XCTAssertEqual(writeCount, 0)
        XCTAssertEqual(contents, damaged)

        model.restoreAllShortcuts()
        XCTAssertEqual(backups, [damaged])
        XCTAssertEqual(contents, Data("[]".utf8))
        XCTAssertNil(model.persistenceFailure)
        XCTAssertTrue(model.canEdit)
    }

    func testRetryLoadingRepairedConfigurationReenablesEditing() throws {
        contents = Data("broken".utf8)
        _ = Shortcuts.reloadOverrides()
        let model = ShortcutsViewModel()
        contents = Data("[]".utf8)
        model.retryLoadingShortcuts()
        XCTAssertNil(model.persistenceFailure)
        XCTAssertTrue(model.canEdit)
        XCTAssertEqual(writeCount, 0)
    }

    func testRestoreAllRefreshesNonBrowserCloseAliasWithoutInventingConflict() throws {
        for hasCustomization in [false, true] {
            let menu = NSMenu()
            let tab = NSMenuItem(title: "Close Tab", action: NSSelectorFromString("commandDispatch:"),
                                 keyEquivalent: "w")
            tab.tag = CommandWrapper.IDC_CLOSE_TAB.rawValue
            let window = NSMenuItem(title: "Close Window", action: NSSelectorFromString("performClose:"),
                                    keyEquivalent: "W")
            window.tag = CommandWrapper.IDC_CLOSE_WINDOW.rawValue
            menu.addItem(tab)
            menu.addItem(window)
            let model = ShortcutsViewModel(additionalBindings: { Shortcuts.menuBindings(in: menu) },
                                           availableCommands: { [] })
            if hasCustomization {
                model.setCustomShortcut(for: .PHI_COPY_URL, key: customKey)
            }
            XCTAssertNil(model.persistenceFailure)
            XCTAssertFalse(model.conflicts(for: .IDC_CLOSE_TAB).contains {
                $0.id == .command(CommandWrapper.IDC_CLOSE_WINDOW.rawValue)
            })

            // Moving to Settings changes the native menu role without refreshing
            // the cached inventory. Restore All must handle that role on rescan,
            // including a reset when the configuration is already at defaults.
            tab.title = "Close Window"
            tab.action = NSSelectorFromString("performClose:")
            tab.tag = CommandWrapper.IDC_CLOSE_WINDOW.rawValue
            window.isHidden = true
            window.action = nil
            window.tag = 0

            model.restoreAllShortcuts()

            XCTAssertNil(model.persistenceFailure)
            XCTAssertTrue(Shortcuts.configuration.overrides.isEmpty)
            XCTAssertEqual(contents, Data("[]".utf8))
            for (command, other) in [(CommandWrapper.IDC_CLOSE_TAB, CommandWrapper.IDC_CLOSE_WINDOW),
                                     (.IDC_CLOSE_WINDOW, .IDC_CLOSE_TAB)] {
                XCTAssertFalse(model.conflicts(for: command).contains { $0.id == .command(other.rawValue) },
                               "Restore All must not introduce a close conflict: customized=\(hasCustomization)")
                XCTAssertEqual(try item(command, in: model).shortcutKey, Shortcuts.DefaultShortcuts[command])
            }
            let alias = try XCTUnwrap(model.inventory.bindings.first { $0.source == .menu })
            XCTAssertEqual(alias.scope, .nonBrowser)
        }
    }

    func testFailedResetKeepsExistingBindingAndReportsFailure() throws {
        let model = ShortcutsViewModel()
        model.setCustomShortcut(for: .PHI_COPY_URL, key: customKey)
        let saved = contents
        rejectsWrites = true
        model.restoreAllShortcuts()
        XCTAssertEqual(model.persistenceFailure, .save)
        XCTAssertEqual(try item(.PHI_COPY_URL, in: model).shortcutKey, customKey)
        XCTAssertEqual(contents, saved)
    }

    func testDisablingRuntimeBindingWithoutSwiftDefaultPersistsExplicitDisable() throws {
        let command = CommandWrapper.IDC_DUPLICATE_TAB
        XCTAssertNil(Shortcuts.DefaultShortcuts[command])
        let model = ShortcutsViewModel(additionalBindings: {
            [ShortcutBinding(commandID: command.rawValue, key: self.customKey,
                             scope: .browser, source: .hidden)]
        }, availableCommands: { [] })
        model.disableShortcut(for: command)
        _ = Shortcuts.reloadOverrides()
        XCTAssertEqual(Shortcuts.overrideState(for: command.rawValue), .disabled)
        XCTAssertTrue(try item(command, in: model).isOverridden)
    }

    func testDeletingUnassignedCommandDoesNotCreateOverride() throws {
        let command = CommandWrapper.IDC_SAVE_PAGE
        let model = ShortcutsViewModel(additionalBindings: { [] }, availableCommands: { [command] })
        XCTAssertNil(Shortcuts.key(for: command))
        XCTAssertTrue(model.inventory.bindings(for: command.rawValue).isEmpty)
        model.selectedCommand = command
        model.editingCommand = command
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\u{7F}", charactersIgnoringModifiers: "\u{7F}", isARepeat: false, keyCode: 51))

        model.handleCaptureEvent(event)

        XCTAssertNil(model.capture)
        XCTAssertEqual(writeCount, 0)
        XCTAssertNil(Shortcuts.overrideState(for: command.rawValue))
        XCTAssertFalse(try item(command, in: model).isOverridden)
        XCTAssertEqual(contents, Data("[]".utf8))
    }

    func testDeletingNewAssignmentRestoresUnassignedBaseline() throws {
        let command = CommandWrapper.IDC_SAVE_PAGE
        let model = ShortcutsViewModel(additionalBindings: { [] }, availableCommands: { [command] })
        model.setCustomShortcut(for: command, key: customKey)
        XCTAssertTrue(try item(command, in: model).isOverridden)
        model.editingCommand = command
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\u{7F}", charactersIgnoringModifiers: "\u{7F}", isARepeat: false, keyCode: 51))

        model.handleCaptureEvent(event)

        XCTAssertNil(model.capture)
        XCTAssertNil(Shortcuts.overrideState(for: command.rawValue))
        XCTAssertNil(try item(command, in: model).shortcutKey)
        XCTAssertFalse(try item(command, in: model).isOverridden)
        XCTAssertEqual(contents, Data("[]".utf8))
        try Shortcuts.reloadOverrides().get()
        XCTAssertNil(Shortcuts.overrideState(for: command.rawValue))
    }

    func testDeletingCustomRuntimeBindingStillDisablesOriginalDefault() throws {
        let command = CommandWrapper.IDC_DUPLICATE_TAB
        let model = ShortcutsViewModel(additionalBindings: {
            guard Shortcuts.overrideState(for: command.rawValue) == nil else { return [] }
            return [ShortcutBinding(commandID: command.rawValue, key: self.customKey,
                                    scope: .browser, source: .hidden)]
        }, availableCommands: { [command] })
        model.setCustomShortcut(for: command, key: ShortcutsKey(characters: "k", modifiers: [.command, .control]))
        model.disableShortcut(for: command)
        XCTAssertEqual(Shortcuts.overrideState(for: command.rawValue), .disabled)
        XCTAssertTrue(try item(command, in: model).isOverridden)
    }

    func testRecordingDefaultRemovesCustomOverride() throws {
        let model = ShortcutsViewModel()
        let command = CommandWrapper.PHI_COPY_URL
        model.setCustomShortcut(for: command, key: customKey)
        model.setCustomShortcut(for: command, key: try XCTUnwrap(Shortcuts.DefaultShortcuts[command]))
        XCTAssertNil(Shortcuts.overrideState(for: command.rawValue))
        XCTAssertFalse(try item(command, in: model).isOverridden)
        XCTAssertEqual(contents, Data("[]".utf8))
    }

    func testRecordingNewWindowOnNewTabKeyKeepsBothBindingsAndReportsConflict() throws {
        let model = ShortcutsViewModel()
        let newTabKey = try XCTUnwrap(Shortcuts.DefaultShortcuts[.IDC_NEW_TAB])
        model.selectedCommand = .IDC_NEW_WINDOW
        model.editingCommand = .IDC_NEW_WINDOW
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil,
            characters: "t", charactersIgnoringModifiers: "t", isARepeat: false, keyCode: 17))
        model.handleCaptureEvent(event)
        XCTAssertNil(model.capture)
        XCTAssertEqual(writeCount, 1)
        XCTAssertEqual(Shortcuts.key(for: .IDC_NEW_WINDOW), newTabKey)
        XCTAssertEqual(Shortcuts.key(for: .IDC_NEW_TAB), newTabKey)
        XCTAssertEqual(Shortcuts.configuration.overrides, [CommandWrapper.IDC_NEW_WINDOW.rawValue: .custom(newTabKey)])
        XCTAssertEqual(model.selectedItem?.command, .IDC_NEW_WINDOW)
        XCTAssertTrue(model.conflicts(for: .IDC_NEW_WINDOW).contains { $0.command == .IDC_NEW_TAB })
        XCTAssertTrue(model.conflicts(for: .IDC_NEW_TAB).contains { $0.command == .IDC_NEW_WINDOW })
        try Shortcuts.reloadOverrides().get()
        model.rebuildSections()
        XCTAssertEqual(Set(model.inventory.occupants(of: newTabKey).map(\.owner)),
                       [.command(CommandWrapper.IDC_NEW_WINDOW.rawValue), .command(CommandWrapper.IDC_NEW_TAB.rawValue)])
        model.restoreDefaultShortcut(for: .IDC_NEW_WINDOW)
        XCTAssertEqual(Shortcuts.key(for: .IDC_NEW_TAB), newTabKey)
        XCTAssertFalse(try item(.IDC_NEW_WINDOW, in: model).hasConflict)
    }


    func testFailedConflictingRecordingRetainsEveryBindingAndCanBeRetried() throws {
        let model = ShortcutsViewModel(additionalBindings: { [] })
        let reload = try XCTUnwrap(Shortcuts.DefaultShortcuts[.IDC_RELOAD])
        rejectsWrites = true
        model.setCustomShortcut(for: .IDC_DUPLICATE_TAB, key: reload)
        XCTAssertEqual(model.persistenceFailure, .save)
        XCTAssertTrue(Shortcuts.configuration.overrides.isEmpty)
        XCTAssertEqual(contents, Data("[]".utf8))
        rejectsWrites = false
        model.setCustomShortcut(for: .IDC_DUPLICATE_TAB, key: reload)
        XCTAssertEqual(writeCount, 1)
        XCTAssertEqual(Shortcuts.key(for: .IDC_RELOAD), reload)
        XCTAssertEqual(Shortcuts.key(for: .IDC_DUPLICATE_TAB), reload)
    }

    func testCancelingRecordingDoesNotWrite() throws {
        let model = ShortcutsViewModel(additionalBindings: { [] })
        model.editingCommand = .IDC_DUPLICATE_TAB
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53))
        model.handleCaptureEvent(event)
        XCTAssertNil(model.capture)
        XCTAssertEqual(writeCount, 0)
        XCTAssertTrue(Shortcuts.configuration.overrides.isEmpty)
    }

    func testRecordingSettingsOnUndoReportsLiveSystemConflict() throws {
        let bridge = try XCTUnwrap(ChromiumLauncher.sharedInstance().bridge)
        bridge.requestRebuildMainMenu()
        let model = ShortcutsViewModel()
        model.editingCommand = .IDC_OPTIONS
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil,
            characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6))

        model.handleCaptureEvent(event)

        let undo = CommandWrapper.IDC_CONTENT_CONTEXT_UNDO
        XCTAssertEqual(Shortcuts.key(for: .IDC_OPTIONS), Shortcuts.key(for: undo))
        XCTAssertNil(Shortcuts.overrideState(for: undo.rawValue))
        XCTAssertTrue(try item(.IDC_OPTIONS, in: model).hasConflict)
        let conflict = try XCTUnwrap(model.conflicts(for: .IDC_OPTIONS).first {
            $0.id == .command(undo.rawValue)
        })
        XCTAssertNil(conflict.command)
        XCTAssertFalse(conflict.name.isEmpty)
        XCTAssertEqual(conflict.keys, ["⌘Z"])

        try Shortcuts.reloadOverrides().get()
        let reopened = ShortcutsViewModel()
        XCTAssertTrue(reopened.conflicts(for: .IDC_OPTIONS).contains {
            $0.id == .command(undo.rawValue)
        })
        reopened.restoreDefaultShortcut(for: .IDC_OPTIONS)
        XCTAssertFalse(try item(.IDC_OPTIONS, in: reopened).hasConflict)
        XCTAssertTrue(Shortcuts.menuBindings().contains {
            $0.commandID == undo.rawValue && $0.key == Shortcuts.DefaultShortcuts[undo]
        })
    }

    func testLiveSystemShortcutsRemainHiddenButReportConflictingAssignments() throws {
        let bridge = try XCTUnwrap(ChromiumLauncher.sharedInstance().bridge)
        bridge.requestRebuildMainMenu()
        let model = ShortcutsViewModel()
        let bindings: [(ShortcutsKey, ShortcutBinding.Owner)] = [
            (.init(characters: "a", modifiers: .command), .command(CommandWrapper.IDC_CONTENT_CONTEXT_SELECTALL.rawValue)),
            (.init(characters: "z", modifiers: [.command, .shift]), .command(CommandWrapper.IDC_CONTENT_CONTEXT_REDO.rawValue)),
            (.init(characters: "c", modifiers: .command), .command(CommandWrapper.IDC_CONTENT_CONTEXT_COPY.rawValue)),
            (.init(characters: " ", modifiers: [.command, .control]), .nativeAction("orderFrontCharacterPalette:"))
        ]
        for (key, owner) in bindings {
            model.setCustomShortcut(for: .IDC_OPTIONS, key: key)
            XCTAssertEqual(Shortcuts.configuration.overrides, [CommandWrapper.IDC_OPTIONS.rawValue: .custom(key)])
            XCTAssertTrue(try item(.IDC_OPTIONS, in: model).hasConflict, key.displayString)
            let conflict = try XCTUnwrap(model.conflicts(for: .IDC_OPTIONS).first { $0.id == owner }, key.displayString)
            XCTAssertNil(conflict.command)
            XCTAssertFalse(model.sections.flatMap(\.items).contains { owner == .command($0.command.rawValue) })
            XCTAssertFalse(model.reservedShortcuts.contains { $0.id == owner })
            XCTAssertTrue(model.inventory.occupants(of: key).contains { $0.owner == owner })
        }
    }

    func testNativeActionConflictIsSavedAndReportedWithoutChangingNativeBinding() throws {
        let model = ShortcutsViewModel(additionalBindings: { [self.customNativeBinding()] })
        model.setCustomShortcut(for: .IDC_DUPLICATE_TAB, key: customKey)
        XCTAssertEqual(writeCount, 1)
        XCTAssertEqual(Shortcuts.key(for: .IDC_DUPLICATE_TAB), customKey)
        let conflict = try XCTUnwrap(model.conflicts(for: .IDC_DUPLICATE_TAB).first { $0.id == .nativeAction("copy:") })
        XCTAssertEqual(conflict.name, "Copy")
        XCTAssertNil(conflict.command)
        XCTAssertFalse(model.reservedShortcuts.contains { $0.id == .nativeAction("copy:") })
        XCTAssertTrue(model.inventory.occupants(of: customKey).contains(customNativeBinding()))
    }

    private func customNativeBinding() -> ShortcutBinding {
        ShortcutBinding(owner: .nativeAction("copy:"), key: customKey,
                        scope: .all, source: .menu, title: "Copy")
    }


    func testConflictingForwardAliasPreservesAllKeysAcrossReloadAndRestore() throws {
        let bridge = try XCTUnwrap(ChromiumLauncher.sharedInstance().bridge)
        let arrow = ShortcutsKey(characters: "\u{F703}", modifiers: .command)
        let bracket = ShortcutsKey(characters: "]", modifiers: .command)
        for (taken, retained) in [(arrow, bracket), (bracket, arrow)] {
            bridge.requestRebuildMainMenu()
            let model = ShortcutsViewModel()
            model.setCustomShortcut(for: .IDC_DUPLICATE_TAB, key: taken)
            XCTAssertNil(Shortcuts.overrideState(for: CommandWrapper.IDC_FORWARD.rawValue))
            XCTAssertEqual(try item(.IDC_FORWARD, in: model).shortcutKey, Shortcuts.DefaultShortcuts[.IDC_FORWARD])
            for _ in 0..<2 {
                // Inspect actual menu and Framework exports, not only UI filtering.
                let bindings = Shortcuts.additionalBindings().filter { $0.commandID == CommandWrapper.IDC_FORWARD.rawValue }
                XCTAssertTrue(bindings.contains { $0.key.menuKeyEquivalent == retained.menuKeyEquivalent })
                XCTAssertTrue(bindings.contains { $0.key.menuKeyEquivalent == taken.menuKeyEquivalent })
                XCTAssertEqual(Set(model.inventory.occupants(of: taken).map(\.owner)),
                               [.command(CommandWrapper.IDC_DUPLICATE_TAB.rawValue), .command(CommandWrapper.IDC_FORWARD.rawValue)])
                _ = Shortcuts.reloadOverrides()
                bridge.requestRebuildMainMenu()
                model.rebuildSections()
            }
            model.disableShortcut(for: .IDC_FORWARD)
            XCTAssertTrue(Shortcuts.additionalBindings().filter { $0.commandID == CommandWrapper.IDC_FORWARD.rawValue }.isEmpty)
            model.restoreDefaultShortcut(for: .IDC_DUPLICATE_TAB)
            model.restoreDefaultShortcut(for: .IDC_FORWARD)
            let restored = Shortcuts.additionalBindings().filter { $0.commandID == CommandWrapper.IDC_FORWARD.rawValue }
            XCTAssertTrue(restored.contains { $0.key.menuKeyEquivalent == arrow.menuKeyEquivalent })
            XCTAssertTrue(restored.contains { $0.key.menuKeyEquivalent == bracket.menuKeyEquivalent })
        }
    }

    func testConflictingHiddenTabAliasPreservesPrimaryAndAliasBindings() throws {
        let bridge = try XCTUnwrap(ChromiumLauncher.sharedInstance().bridge)
        bridge.requestRebuildMainMenu()
        let model = ShortcutsViewModel()
        let pageDown = ShortcutsKey(characters: "\u{F72D}", modifiers: .control)
        let original = try XCTUnwrap(try item(.IDC_SELECT_NEXT_TAB, in: model).shortcutKey)
        model.setCustomShortcut(for: .IDC_DUPLICATE_TAB, key: pageDown)
        let remaining = Shortcuts.additionalBindings().filter { $0.commandID == CommandWrapper.IDC_SELECT_NEXT_TAB.rawValue }
        XCTAssertTrue(remaining.contains { $0.key.menuKeyEquivalent == pageDown.menuKeyEquivalent })
        XCTAssertTrue(remaining.contains { $0.key.menuKeyEquivalent == original.menuKeyEquivalent })
        XCTAssertEqual(try item(.IDC_SELECT_NEXT_TAB, in: model).shortcutKey, original)
    }

    func testSuccessiveConflictingRecordingsPreserveAllOtherCommandAliases() throws {
        let command = CommandWrapper.IDC_FORWARD
        let first = ShortcutsKey(characters: "\u{F703}", modifiers: .command)
        let second = ShortcutsKey(characters: "f", modifiers: [.control, .option])
        let primary = try XCTUnwrap(Shortcuts.DefaultShortcuts[command])
        let model = ShortcutsViewModel(additionalBindings: {
            [first, second].filter { Shortcuts.overrideState(for: command.rawValue)?.excludes($0) != true }
                .map { ShortcutBinding(commandID: command.rawValue, key: $0, scope: .browser, source: .hidden) }
        })
        model.setCustomShortcut(for: .IDC_DUPLICATE_TAB, key: first)
        model.setCustomShortcut(for: .IDC_WINDOW_MUTE_SITE, key: second)
        XCTAssertNil(Shortcuts.overrideState(for: command.rawValue))
        XCTAssertEqual(try item(command, in: model).shortcutKey, primary)
        XCTAssertEqual(Set(model.inventory.occupants(of: first).map(\.owner)), [.command(CommandWrapper.IDC_DUPLICATE_TAB.rawValue), .command(command.rawValue)])
        XCTAssertEqual(Set(model.inventory.occupants(of: second).map(\.owner)), [.command(CommandWrapper.IDC_WINDOW_MUTE_SITE.rawValue), .command(command.rawValue)])
    }


    func testTextSearchMatchesModifierNamesSymbolsAndKeyCombinationsWithoutWriting() {
        let key = ShortcutsKey(characters: "s", modifiers: [.command, .control])
        let model = ShortcutsViewModel(additionalBindings: {
            [ShortcutBinding(commandID: CommandWrapper.IDC_DUPLICATE_TAB.rawValue,
                             key: key, scope: .browser, source: .hidden)]
        })
        for query in ["command", "CMD", "control", "CTRL", "S", "⌘", "⌃",
                      "cmd ctrl s", "COMMAND+CONTROL+S", "⌘⌃S", "⌃ ⌘ s",
                      "  cMd + CtRl + s  ", "command CMD control CTRL S"] {
            model.searchText = query
            XCTAssertTrue(model.filteredSections.flatMap(\.items).contains {
                $0.command == .IDC_DUPLICATE_TAB
            }, query)
            XCTAssertNil(model.capture)
        }
        for query in ["cmd ctrl x", "cmd option s", "shift ctrl s", "cmd ctrl a"] {
            model.searchText = query
            XCTAssertFalse(model.filteredSections.flatMap(\.items).contains {
                $0.command == .IDC_DUPLICATE_TAB
            }, query)
        }
        XCTAssertEqual(writeCount, 0)
    }

    func testTextSearchMatchesOtherModifiersAndReadOnlyBindings() {
        let command = CommandWrapper.IDC_SHOW_READING_MODE_KEYBOARD
        let key = ShortcutsKey(characters: "s", modifiers: [.option, .shift, .function])
        let model = ShortcutsViewModel(additionalBindings: {
            [ShortcutBinding(commandID: command.rawValue, key: key,
                             scope: .browser, source: .hidden, title: "Reading Mode")]
        })
        for query in ["option", "OPT", "alt", "⌥", "shift", "⇧", "fn", "function", "🌐",
                      "alt shift fn s", "🌐⌥⇧S", "Reading Mode"] {
            model.searchText = query
            XCTAssertTrue(model.filteredReservedShortcuts.contains {
                $0.id == .command(command.rawValue)
            }, query)
        }
        model.searchText = "cmd s"
        XCTAssertTrue(model.filteredReservedShortcuts.isEmpty)
        XCTAssertEqual(writeCount, 0)
    }

    func testTextSearchDoesNotCombineSeparateAliases() {
        let command = CommandWrapper.IDC_DUPLICATE_TAB
        let model = ShortcutsViewModel(additionalBindings: {
            [ShortcutsKey(characters: "s", modifiers: .command),
             ShortcutsKey(characters: "j", modifiers: .control)].map {
                ShortcutBinding(commandID: command.rawValue, key: $0, scope: .browser, source: .hidden)
            }
        })
        model.searchText = "cmd ctrl s"
        XCTAssertFalse(model.filteredSections.flatMap(\.items).contains { $0.command == command })
        model.searchText = "control j"
        XCTAssertTrue(model.filteredSections.flatMap(\.items).contains { $0.command == command })
    }

    func testTextSearchTracksRebindDisableAndRestore() {
        let model = ShortcutsViewModel(additionalBindings: { [] })
        model.setCustomShortcut(for: .IDC_NEW_WINDOW,
                                key: ShortcutsKey(characters: "s", modifiers: [.command, .control]))
        model.searchText = "cmd ctrl s"
        XCTAssertTrue(model.filteredSections.flatMap(\.items).contains { $0.command == .IDC_NEW_WINDOW })
        model.disableShortcut(for: .IDC_NEW_WINDOW)
        XCTAssertFalse(model.filteredSections.flatMap(\.items).contains { $0.command == .IDC_NEW_WINDOW })
        model.searchText = "New Window"
        XCTAssertTrue(model.filteredSections.flatMap(\.items).contains { $0.command == .IDC_NEW_WINDOW })
        model.restoreDefaultShortcut(for: .IDC_NEW_WINDOW)
        model.searchText = "cmd n"
        XCTAssertTrue(model.filteredSections.flatMap(\.items).contains { $0.command == .IDC_NEW_WINDOW })
    }

    func testTextSearchPreservesDisplayedKeysAndLiteralPlus() {
        let model = ShortcutsViewModel(additionalBindings: { [] })
        model.searchText = "cmd shift ["
        XCTAssertTrue(model.filteredSections.flatMap(\.items).contains { $0.command == .IDC_SELECT_PREVIOUS_TAB })
        model.setCustomShortcut(for: .IDC_DUPLICATE_TAB,
                                key: ShortcutsKey(characters: "+", modifiers: [.command, .shift]))
        for query in ["+", "cmd shift +", "command+shift++", "⌘⇧+"] {
            model.searchText = query
            XCTAssertTrue(model.filteredSections.flatMap(\.items).contains { $0.command == .IDC_DUPLICATE_TAB }, query)
        }
        model.searchText = "   \n "
        XCTAssertEqual(model.filteredSections.flatMap(\.items).count, model.sections.flatMap(\.items).count)
    }

    func testIncrementalModifierSearchKeepsMatchingWhileTyping() {
        let model = ShortcutsViewModel(additionalBindings: { [] })
        model.setCustomShortcut(for: .IDC_NEW_WINDOW,
                                key: ShortcutsKey(characters: "s", modifiers: [.command, .control]))
        for query in ["co", "com", "comm", "comma", "comman", "command", "cm", "cmd",
                      "cmd+", "cmd + ", "cmd+co", "cmd+con", "cmd+cont", "cmd+contr",
                      "cmd+contro", "cmd+control", "cmd+control+", "cmd+control+s", "CMD + CTR + S"] {
            model.searchText = query
            XCTAssertTrue(model.filteredSections.flatMap(\.items).contains { $0.command == .IDC_NEW_WINDOW }, query)
        }
        model.setCustomShortcut(for: .IDC_DUPLICATE_TAB,
                                key: ShortcutsKey(characters: "z", modifiers: [.option, .shift, .function]))
        for query in ["op", "opti", "al", "sh", "shif", "fu", "funct", "op sh fu z"] {
            model.searchText = query
            XCTAssertTrue(model.filteredSections.flatMap(\.items).contains { $0.command == .IDC_DUPLICATE_TAB }, query)
        }
        for query in ["cmd s", "op a", "op s", "op f"] {
            model.searchText = query
            XCTAssertFalse(model.filteredSections.flatMap(\.items).contains { $0.command == .IDC_DUPLICATE_TAB }, query)
        }
    }

    func testIncompleteSeparatorDoesNotRequireLiteralPlus() {
        let model = ShortcutsViewModel(additionalBindings: { [] })
        model.setCustomShortcut(for: .IDC_NEW_WINDOW,
                                key: ShortcutsKey(characters: "n", modifiers: [.command, .shift]))
        model.setCustomShortcut(for: .IDC_DUPLICATE_TAB,
                                key: ShortcutsKey(characters: "+", modifiers: [.command, .shift]))
        for query in ["cmd+", "cmd + ", "cmd+shift+", "cmd shift +"] {
            model.searchText = query
            let commands = Set(model.filteredSections.flatMap(\.items).map(\.command))
            XCTAssertTrue(commands.contains(.IDC_NEW_WINDOW), query)
            XCTAssertTrue(commands.contains(.IDC_DUPLICATE_TAB), query)
        }
        for query in ["+", "cmd++", "cmd+shift++", "⌘⇧+"] {
            model.searchText = query
            let commands = Set(model.filteredSections.flatMap(\.items).map(\.command))
            XCTAssertFalse(commands.contains(.IDC_NEW_WINDOW), query)
            XCTAssertTrue(commands.contains(.IDC_DUPLICATE_TAB), query)
        }
    }

    func testSearchSnapshotRefreshesEditableAndReadOnlyAliases() {
        var key = ShortcutsKey(characters: "j", modifiers: .command)
        let command = CommandWrapper.IDC_DUPLICATE_TAB
        let reservedCommand = CommandWrapper.IDC_SHOW_READING_MODE_KEYBOARD
        let model = ShortcutsViewModel(additionalBindings: {
            [command, reservedCommand].map {
                ShortcutBinding(commandID: $0.rawValue, key: key, scope: .browser, source: .hidden)
            }
        })
        model.searchText = "cmd j"
        XCTAssertTrue(model.filteredSections.flatMap(\.items).contains { $0.command == command })
        XCTAssertTrue(model.filteredReservedShortcuts.contains { $0.id == .command(reservedCommand.rawValue) })
        key = ShortcutsKey(characters: "x", modifiers: .control)
        model.rebuildSections()
        XCTAssertFalse(model.filteredSections.flatMap(\.items).contains { $0.command == command })
        XCTAssertTrue(model.filteredReservedShortcuts.isEmpty)
        model.searchText = "ctrl x"
        XCTAssertTrue(model.filteredSections.flatMap(\.items).contains { $0.command == command })
        XCTAssertTrue(model.filteredReservedShortcuts.contains { $0.id == .command(reservedCommand.rawValue) })
        let commands = model.filteredSections.flatMap(\.items).map(\.command)
        model.selectedCommand = command
        model.startRecording(for: command)
        XCTAssertEqual(model.filteredSections.flatMap(\.items).map(\.command), commands)
        model.filter = .reserved
        XCTAssertTrue(model.filteredSections.isEmpty)
        XCTAssertNil(model.selectedCommand)
        XCTAssertTrue(model.filteredReservedShortcuts.contains { $0.id == .command(reservedCommand.rawValue) })
        model.filter = .all
        XCTAssertEqual(model.filteredSections.flatMap(\.items).map(\.command), commands)
        XCTAssertNotNil(model.selectedItem)
    }

    func testPairedFrameworkExportsAliasesAndHonorsRebindDisableRestore() throws {
        let bridge = try XCTUnwrap(ChromiumLauncher.sharedInstance().bridge)
        XCTAssertTrue(bridge.responds(to: NSSelectorFromString("shortcutBindings")))
        let command = CommandWrapper.IDC_SELECT_NEXT_TAB
        let pageDown = ShortcutsKey(characters: "\u{F72D}", modifiers: .control)
        bridge.requestRebuildMainMenu()
        func aliases() -> [ShortcutBinding] {
            Shortcuts.additionalBindings().filter { $0.commandID == command.rawValue && $0.source == .hidden }
        }
        XCTAssertTrue(aliases().contains { $0.key.menuKeyEquivalent == pageDown.menuKeyEquivalent })
        let model = ShortcutsViewModel()
        model.setCustomShortcut(for: command, key: customKey)
        XCTAssertFalse(aliases().isEmpty)
        XCTAssertTrue(aliases().allSatisfy { $0.key.menuKeyEquivalent == customKey.menuKeyEquivalent })
        model.disableShortcut(for: command)
        XCTAssertTrue(aliases().isEmpty)
        model.restoreDefaultShortcut(for: command)
        XCTAssertTrue(aliases().contains { $0.key.menuKeyEquivalent == pageDown.menuKeyEquivalent })
    }

    func testSplitTabStaysMenuOnlyAcrossKioskChangesAndRestoreAll() throws {
        let bridge = try XCTUnwrap(ChromiumLauncher.sharedInstance().bridge)
        let model = ShortcutsViewModel()
        func findSplit(in menu: NSMenu) -> NSMenuItem? {
            for entry in menu.items {
                if entry.tag == CommandWrapper.IDC_NEW_SPLIT_TAB.rawValue,
                   entry.action != nil { return entry }
                if let submenu = entry.submenu, let found = findSplit(in: submenu) { return found }
            }
            return nil
        }
        func assertMenuOnly() throws {
            bridge.requestRebuildMainMenu()
            model.rebuildSections()
            let entry = try XCTUnwrap(findSplit(in: XCTUnwrap(NSApp.mainMenu)))
            XCTAssertEqual(entry.action, NSSelectorFromString("commandDispatch:"))
            XCTAssertTrue(entry.keyEquivalent.isEmpty)
            XCTAssertNil(Shortcuts.key(for: .IDC_NEW_SPLIT_TAB))
            XCTAssertTrue(model.inventory.bindings(for: CommandWrapper.IDC_NEW_SPLIT_TAB.rawValue).isEmpty)
            XCTAssertFalse(model.conflicts(for: .PHI_NEW_KIOSK_WINDOW).contains {
                $0.id == .command(CommandWrapper.IDC_NEW_SPLIT_TAB.rawValue)
            })
            let override = try XCTUnwrap(PhiChromiumCoordinator.shared.keyEquivalentOverride(
                forCommand: Int32(CommandWrapper.IDC_NEW_SPLIT_TAB.rawValue)))
            XCTAssertEqual(override["keyEquivalent"] as? String, "")
        }
        try assertMenuOnly()
        // Legacy saved bindings must not bypass the menu-only product policy.
        contents = try JSONSerialization.data(withJSONObject: [
            ["commandId": CommandWrapper.IDC_NEW_SPLIT_TAB.rawValue,
             "key": ["characters": customKey.characters, "modifiersRaw": customKey.modifiersRaw]] as [String: Any]
        ])
        try Shortcuts.reloadOverrides().get()
        try assertMenuOnly()
        model.setCustomShortcut(for: .PHI_NEW_KIOSK_WINDOW, key: customKey)
        try assertMenuOnly()
        model.disableShortcut(for: .PHI_NEW_KIOSK_WINDOW)
        try assertMenuOnly()
        model.restoreAllShortcuts()
        XCTAssertNil(model.persistenceFailure)
        XCTAssertEqual(Shortcuts.key(for: .PHI_NEW_KIOSK_WINDOW), Shortcuts.DefaultShortcuts[.PHI_NEW_KIOSK_WINDOW])
        try assertMenuOnly()
    }

    private var productOwnedCommands: [CommandWrapper] {
        [.PHI_NEW_KIOSK_WINDOW, .PHI_COPY_URL, .PHI_SELECT_NEXT_SPACE,
         .PHI_SELECT_PREVIOUS_SPACE, .PHI_TOGGLE_READER, .PHI_TOGGLE_SIDEBAR]
    }

    func testProductDefaultsHaveOneOwnerAndKeepOtherChromiumAliases() throws {
        try XCTUnwrap(ChromiumLauncher.sharedInstance().bridge).requestRebuildMainMenu()
        let model = ShortcutsViewModel()
        for command in productOwnedCommands {
            let key = try XCTUnwrap(Shortcuts.DefaultShortcuts[command])
            XCTAssertEqual(Set(model.inventory.occupants(of: key).map(\.owner)),
                           [.command(command.rawValue)], "Product default: \(command)")
            XCTAssertFalse(try item(command, in: model).hasConflict)
        }
        for (command, key) in [
            (CommandWrapper.IDC_DEV_TOOLS_INSPECT, ShortcutsKey(characters: "c", modifiers: [.command, .option])),
            (.IDC_SELECT_NEXT_TAB, ShortcutsKey(characters: "\u{F72D}", modifiers: .control)),
            (.IDC_SELECT_PREVIOUS_TAB, ShortcutsKey(characters: "\u{F72C}", modifiers: .control)),
            (.IDC_SELECT_NEXT_TAB, try XCTUnwrap(Shortcuts.DefaultShortcuts[.IDC_SELECT_NEXT_TAB])),
            (.IDC_SELECT_PREVIOUS_TAB, try XCTUnwrap(Shortcuts.DefaultShortcuts[.IDC_SELECT_PREVIOUS_TAB]))
        ] {
            XCTAssertTrue(model.inventory.bindings(for: command.rawValue).contains {
                $0.key.menuKeyEquivalent == key.menuKeyEquivalent
            }, "Unrelated alias must remain: \(command)")
        }
        XCTAssertFalse(model.reservedShortcuts.contains { $0.id == .command(CommandWrapper.IDC_NEW_SPLIT_TAB.rawValue) })
        XCTAssertFalse(model.reservedShortcuts.contains { $0.id == .command(CommandWrapper.IDC_SHOW_READING_MODE_KEYBOARD.rawValue) })

        func find(_ command: CommandWrapper, in menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if item.tag == command.rawValue, item.action != nil { return item }
                if let submenu = item.submenu, let found = find(command, in: submenu) { return found }
            }
            return nil
        }
        let menu = try XCTUnwrap(NSApp.mainMenu)
        let split = try XCTUnwrap(find(.IDC_NEW_SPLIT_TAB, in: menu))
        XCTAssertEqual(split.keyEquivalent, "", "Remove the default binding, not the menu command")
        XCTAssertEqual(split.action, NSSelectorFromString("commandDispatch:"))
    }

    func testProductDefaultsDoNotReviveAfterRebindDisableOrRestore() throws {
        try XCTUnwrap(ChromiumLauncher.sharedInstance().bridge).requestRebuildMainMenu()
        let model = ShortcutsViewModel()
        for command in productOwnedCommands {
            let key = try XCTUnwrap(Shortcuts.DefaultShortcuts[command])
            model.setCustomShortcut(for: command, key: customKey)
            XCTAssertTrue(model.inventory.occupants(of: key).isEmpty, "Rebound: \(command)")
            model.disableShortcut(for: command)
            XCTAssertTrue(model.inventory.occupants(of: key).isEmpty, "Disabled: \(command)")
            model.restoreDefaultShortcut(for: command)
            XCTAssertEqual(Set(model.inventory.occupants(of: key).map(\.owner)),
                           [.command(command.rawValue)], "Restored: \(command)")
        }
        XCTAssertTrue(Shortcuts.configuration.overrides.isEmpty,
                      "Product defaults must not be persisted as user disables")
    }

    func testExplicitUserConflictWithProductKeyPreservesBothBindings() throws {
        try XCTUnwrap(ChromiumLauncher.sharedInstance().bridge).requestRebuildMainMenu()
        let model = ShortcutsViewModel()
        let copyKey = try XCTUnwrap(Shortcuts.DefaultShortcuts[.PHI_COPY_URL])
        model.setCustomShortcut(for: .IDC_DEV_TOOLS_INSPECT, key: copyKey)
        XCTAssertEqual(Shortcuts.key(for: .PHI_COPY_URL), copyKey)
        XCTAssertEqual(Set(model.inventory.occupants(of: copyKey).map(\.owner)),
                       [.command(CommandWrapper.IDC_DEV_TOOLS_INSPECT.rawValue), .command(CommandWrapper.PHI_COPY_URL.rawValue)])
        XCTAssertTrue(model.inventory.bindings(for: CommandWrapper.IDC_DEV_TOOLS_INSPECT.rawValue).contains {
            $0.source == .hidden && $0.key.menuKeyEquivalent == copyKey.menuKeyEquivalent
        }, "Explicit user overrides must still reach the Framework")
        model.restoreAllShortcuts()
        XCTAssertEqual(Set(model.inventory.occupants(of: copyKey).map(\.owner)),
                       [.command(CommandWrapper.PHI_COPY_URL.rawValue)])
    }

    func testPhiSwitcherChangesNeverReviveChromiumCycleKeys() throws {
        let bridge = try XCTUnwrap(ChromiumLauncher.sharedInstance().bridge)
        bridge.requestRebuildMainMenu()
        let model = ShortcutsViewModel()
        let oldKey = ShortcutsKey(characters: "\t", modifiers: .control)
        for disabled in [false, true] {
            if disabled { model.disableShortcut(for: .PHI_TAB_SWITCHER_FORWARD) }
            else { model.setCustomShortcut(for: .PHI_TAB_SWITCHER_FORWARD, key: customKey) }
            XCTAssertTrue(model.inventory.occupants(of: oldKey).isEmpty)
            for command in [CommandWrapper.IDC_CYCLE_TO_NEXT_TAB, .IDC_CYCLE_TO_PREV_TAB] {
                let state = try XCTUnwrap(PhiChromiumCoordinator.shared.keyEquivalentOverride(forCommand: Int32(command.rawValue)))
                XCTAssertEqual(state["keyEquivalent"] as? String, "")
                XCTAssertFalse(Shortcuts.menuBindings().contains { $0.commandID == command.rawValue })
            }
        }
        model.restoreDefaultShortcut(for: .PHI_TAB_SWITCHER_FORWARD)
        XCTAssertEqual(Set(model.inventory.occupants(of: oldKey).map(\.owner)), [.command(CommandWrapper.PHI_TAB_SWITCHER_FORWARD.rawValue)])
    }

    func testLiveHiddenOwnersHaveNamesAndConflictingBindingsArePreserved() throws {
        let bridge = try XCTUnwrap(ChromiumLauncher.sharedInstance().bridge)
        XCTAssertTrue(bridge.responds(to: NSSelectorFromString("shortcutBindings")))
        bridge.requestRebuildMainMenu()
        let model = ShortcutsViewModel()
        let hidden = model.inventory.bindings.filter { $0.source == .hidden }
        XCTAssertFalse(hidden.isEmpty)
        for binding in hidden {
            // Chromium owns IDC_DEV_TOOLS_TOGGLE; Phi lists it as a read-only F12 binding.
            if binding.commandID == 40237 {
                XCTAssertEqual(binding.key, ShortcutsKey(characters: "\u{F70F}", modifiers: []))
                let reserved = try XCTUnwrap(model.reservedShortcuts.first { $0.id == binding.owner })
                XCTAssertFalse(reserved.name.isEmpty)
                XCTAssertTrue(reserved.keys.contains(binding.key))
                continue
            }
            let command = try XCTUnwrap(binding.commandID.flatMap(CommandWrapper.init(rawValue:)))
            let name = model.sections.flatMap(\.items).first { $0.command == command }?.name
                ?? model.reservedShortcuts.first { $0.id == binding.owner }?.name
            XCTAssertFalse(try XCTUnwrap(name).isEmpty)
            XCTAssertNotEqual(name, "Reserved browser shortcut")
        }
        let reserved = try XCTUnwrap(hidden.first { $0.commandID == CommandWrapper.IDC_MOVE_TAB_NEXT.rawValue })
        let row = try item(.IDC_MOVE_TAB_NEXT, in: model)
        XCTAssertEqual(row.name, "Move Tab Right")
        XCTAssertEqual(row.shortcutKey, reserved.key)
        model.setCustomShortcut(for: .IDC_DUPLICATE_TAB, key: reserved.key)
        XCTAssertEqual(writeCount, 1)
        XCTAssertNil(Shortcuts.overrideState(for: CommandWrapper.IDC_MOVE_TAB_NEXT.rawValue))
        XCTAssertEqual(try item(.IDC_MOVE_TAB_NEXT, in: model).shortcutKey, reserved.key)
        XCTAssertTrue(model.conflicts(for: .IDC_DUPLICATE_TAB).contains { $0.command == .IDC_MOVE_TAB_NEXT })
    }

    func testBrowserCommandsCanBeCustomizedDisabledAndRestoredInLiveTables() throws {
        let bridge = try XCTUnwrap(ChromiumLauncher.sharedInstance().bridge)
        bridge.requestRebuildMainMenu()
        let model = ShortcutsViewModel()
        for command in [CommandWrapper.IDC_RELOAD_BYPASSING_CACHE, .IDC_MOVE_TAB_PREVIOUS,
                        .IDC_ADD_NEW_TAB_TO_GROUP] {
            let original = try XCTUnwrap(try item(command, in: model).shortcutKey)
            model.setCustomShortcut(for: command, key: customKey)
            XCTAssertEqual(try item(command, in: model).shortcutKey, customKey)
            let customized = model.inventory.bindings(for: command.rawValue)
                .filter { $0.source != .configured }
            XCTAssertFalse(customized.isEmpty)
            XCTAssertTrue(customized.allSatisfy { $0.key.menuKeyEquivalent == customKey.menuKeyEquivalent })
            XCTAssertFalse(customized.contains { $0.key.menuKeyEquivalent == original.menuKeyEquivalent })

            model.disableShortcut(for: command)
            XCTAssertNil(try item(command, in: model).shortcutKey)
            XCTAssertTrue(model.inventory.bindings(for: command.rawValue).isEmpty)

            model.restoreDefaultShortcut(for: command)
            XCTAssertEqual(try item(command, in: model).shortcutKey?.menuKeyEquivalent, original.menuKeyEquivalent)
            XCTAssertTrue(model.inventory.bindings(for: command.rawValue).contains {
                $0.source != .configured && $0.key.menuKeyEquivalent == original.menuKeyEquivalent
            })
        }
    }

    private var productDisabledKeys: [(CommandWrapper, ShortcutsKey, UInt16)] {
        [(.IDC_FOCUS_NEXT_PANE, .init(characters: "\u{F701}", modifiers: [.command, .option]), 125),
         (.IDC_FOCUS_PREVIOUS_PANE, .init(characters: "\u{F700}", modifiers: [.command, .option]), 126),
         (.IDC_FOCUS_INACTIVE_POPUP_FOR_ACCESSIBILITY, .init(characters: "a", modifiers: [.command, .option, .shift]), 0),
         (.IDC_SHOW_AVATAR_MENU, .init(characters: "m", modifiers: [.command, .shift]), 46),
         (.IDC_TOGGLE_FULLSCREEN_TOOLBAR, .init(characters: "f", modifiers: [.command, .shift]), 3),
         (.IDC_HELP_PAGE_VIA_MENU, .init(characters: "?", modifiers: [.command, .shift]), 44)]
    }

    func testProductDisabledCommandsStayUnboundAfterReloadRestoreAndMenuRebuild() throws {
        let bridge = try XCTUnwrap(ChromiumLauncher.sharedInstance().bridge)
        func assertReleased() throws {
            bridge.requestRebuildMainMenu()
            let actual = Shortcuts.additionalBindings()
            let hidden = bridge.shortcutBindings()
            let model = ShortcutsViewModel()
            for (command, _, _) in productDisabledKeys {
                XCTAssertFalse(actual.contains { $0.commandID == command.rawValue })
                XCTAssertFalse(hidden.contains { ($0["commandId"] as? Int) == command.rawValue })
                XCTAssertNil(Shortcuts.key(for: command))
                XCTAssertFalse(model.sections.flatMap(\.items).contains { $0.command == command })
                let override = try XCTUnwrap(PhiChromiumCoordinator.shared.keyEquivalentOverride(forCommand: Int32(command.rawValue)))
                XCTAssertEqual(override["keyEquivalent"] as? String, "")
            }
        }
        try assertReleased()
        // Simulate an existing configuration loaded on startup. The records
        // remain stored, but product policy wins over every saved custom key.
        contents = try JSONSerialization.data(withJSONObject: productDisabledKeys.map { command, _, _ in
            ["commandId": command.rawValue,
             "key": ["characters": customKey.characters, "modifiersRaw": customKey.modifiersRaw]] as [String: Any]
        })
        let saved = contents
        try Shortcuts.reloadOverrides().get()
        XCTAssertEqual(Shortcuts.configuration.overrides.count, productDisabledKeys.count)
        XCTAssertEqual(contents, saved)
        try assertReleased()
        try Shortcuts.restoreOverrides().get()
        try assertReleased()
    }

    func testReleasedCombinationsCanBeAssignedToAndInvokeAnotherMenuCommand() throws {
        let bridge = try XCTUnwrap(ChromiumLauncher.sharedInstance().bridge)
        bridge.requestRebuildMainMenu()
        let model = ShortcutsViewModel()
        func findReload(in menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if item.tag == CommandWrapper.IDC_RELOAD.rawValue, item.action != nil { return item }
                if let submenu = item.submenu, let found = findReload(in: submenu) { return found }
            }
            return nil
        }
        for (_, key, keyCode) in productDisabledKeys {
            model.setCustomShortcut(for: .IDC_RELOAD, key: key)
            XCTAssertEqual(Shortcuts.key(for: .IDC_RELOAD), key)
            // Product policy releases application owners, not macOS reservations.
            XCTAssertEqual(Set(model.inventory.occupants(of: key).map(\.owner).filter { $0 != .system }),
                           [.command(CommandWrapper.IDC_RELOAD.rawValue)])
            let menu = try XCTUnwrap(NSApp.mainMenu)
            let item = try XCTUnwrap(findReload(in: menu))
            let target = ReleasedShortcutActionTarget()
            let originalTarget = item.target
            let originalAction = item.action
            let originalEnabled = item.isEnabled
            defer {
                item.target = originalTarget
                item.action = originalAction
                item.isEnabled = originalEnabled
            }
            // Exercise AppKit key matching without reloading a user's page.
            item.target = target
            item.action = #selector(ReleasedShortcutActionTarget.invoke(_:))
            item.isEnabled = true
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: key.modifiers, timestamp: 0, windowNumber: 0, context: nil,
                characters: key.menuKeyEquivalent.characters,
                charactersIgnoringModifiers: key.menuKeyEquivalent.characters,
                isARepeat: false, keyCode: keyCode))
            XCTAssertTrue(menu.performKeyEquivalent(with: event))
            XCTAssertEqual(target.invocationCount, 1)
        }
    }

    func testOpenSettingsRefreshesAfterExternalReloadAndCancelsStaleRecording() throws {
        let model = ShortcutsViewModel()
        let command = CommandWrapper.PHI_COPY_URL
        // Drain the initial spaces subscription so it cannot mask a missing
        // shortcuts notification subscription by rebuilding at the same time.
        let ready = expectation(description: "Initial settings subscriptions settle")
        DispatchQueue.main.async { ready.fulfill() }
        wait(for: [ready], timeout: 2)
        let refreshed = expectation(description: "Open settings observes a reloaded binding")
        let subscription = model.$sections.dropFirst()
            .filter { sections in
                sections.flatMap(\.items).first(where: { $0.command == command })?.shortcutKey == nil
            }
            .prefix(1)
            .sink { _ in refreshed.fulfill() }
        model.editingCommand = command
        contents = Data("[{\"commandId\":\(command.rawValue),\"key\":null}]".utf8)
        _ = Shortcuts.reloadOverrides()
        wait(for: [refreshed], timeout: 2)
        withExtendedLifetime(subscription) {}
        XCTAssertNil(model.editingCommand)
        XCTAssertNil(try item(command, in: model).shortcutKey)
    }
}

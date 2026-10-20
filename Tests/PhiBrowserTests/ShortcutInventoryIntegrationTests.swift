// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

final class ShortcutInventoryIntegrationTests: XCTestCase {
    func testMenuEncodedShiftIsVisibleWithoutChangingBindingIdentity() {
        let menuKey = ShortcutsKey(characters: "C", modifiers: .command)
        XCTAssertEqual(menuKey.displayString, "⇧⌘C")
        XCTAssertEqual(menuKey.keycapTokens, ["⇧", "⌘", "C"])
        XCTAssertEqual(menuKey.modifiers, .command)
        XCTAssertEqual(ShortcutsKey(characters: "c", modifiers: .command).displayString, "⌘C")
        XCTAssertEqual(ShortcutsKey(characters: "C", modifiers: [.command, .shift]).keycapTokens,
                       ["⇧", "⌘", "C"])
    }

    func testHiddenNavigationAndSystemKeyLabelsRemainReadable() {
        for (characters, label) in [("\u{F72C}", "⇞"), ("\u{F72D}", "⇟"),
                                    ("\u{F729}", "↖"), ("\u{F72B}", "↘"),
                                    ("\u{F728}", "⌦"), ("\u{F70F}", "F12"), (" ", "␣")] {
            XCTAssertEqual(ShortcutsKey(characters: characters, modifiers: .control).displayString, "⌃" + label)
        }
        XCTAssertEqual(ShortcutsKey(characters: "e", modifiers: .function).keycapTokens, ["fn", "E"])
    }

    private var previousConfiguration: ShortcutConfiguration?

    override func setUp() {
        previousConfiguration = Shortcuts.configuration
        install([:])
    }

    override func tearDownWithError() throws {
        Shortcuts.configuration = try XCTUnwrap(previousConfiguration)
        previousConfiguration = nil
    }

    private func install(_ overrides: [CommandWrapper: ShortcutOverride]) {
        Shortcuts.configuration = ShortcutConfiguration(
            overrides: Dictionary(uniqueKeysWithValues: overrides.map { ($0.key.rawValue, $0.value) }),
            fileURL: previousConfiguration?.fileURL,
            files: .init(
                read: { _ in throw CocoaError(.fileReadNoPermission) },
                write: { _, _ in throw CocoaError(.fileWriteNoPermission) },
                backup: { _, _ in throw CocoaError(.fileWriteNoPermission) }
            )
        )
    }

    private func item(_ command: CommandWrapper, in model: ShortcutsViewModel) throws -> ShortcutItem {
        try XCTUnwrap(model.sections.flatMap(\.items).first { $0.command == command })
    }

    func testAdditionalBindingFilterPreservesOwnersAndExcludesDisabledCommands() {
        let key = ShortcutsKey(characters: "d", modifiers: [.control, .option])
        let disabled = ShortcutBinding(commandID: CommandWrapper.IDC_FOCUS_NEXT_PANE.rawValue,
                                       key: key, scope: .all, source: .hidden)
        let enabled = ShortcutBinding(commandID: CommandWrapper.IDC_DUPLICATE_TAB.rawValue,
                                      key: key, scope: .browser, source: .webContents)
        let unknown = ShortcutBinding(commandID: 999999, key: key, scope: .all, source: .menu)
        let native = ShortcutBinding(owner: .nativeAction("copy:"), key: key,
                                     scope: .all, source: .menu, title: "Copy")
        let system = ShortcutBinding(owner: .system, key: key,
                                     scope: .all, source: .system, title: "System")
        let baseline = Shortcuts.bindingInventory(additionalBindings: []).bindings
        let expected = Set(baseline + [enabled, unknown, native, system])
        let additional = [disabled, enabled, native, system, unknown, disabled, native]

        for bindings in [additional, Array(additional.reversed())] {
            let inventory = Shortcuts.bindingInventory(additionalBindings: bindings)
            XCTAssertEqual(Set(inventory.bindings), expected)
            XCTAssertEqual(inventory.bindings.count, expected.count)
            XCTAssertFalse(inventory.bindings.contains(disabled))
        }
    }

    func testRebuiltInventoryPreservesNonCommandOwnersAndFiltersUnavailableSpaces() {
        let key = ShortcutsKey(characters: "d", modifiers: [.control, .option])
        let enabled = ShortcutBinding(commandID: CommandWrapper.IDC_DUPLICATE_TAB.rawValue,
                                      key: key, scope: .browser, source: .hidden)
        let unknown = ShortcutBinding(commandID: 999999, key: key, scope: .all, source: .menu)
        let native = ShortcutBinding(owner: .nativeAction("copy:"), key: key,
                                     scope: .all, source: .menu, title: "Copy")
        let system = ShortcutBinding(owner: .system, key: key,
                                     scope: .all, source: .system, title: "System")
        let spaceBindings = CommandWrapper.spaceSelectionCommands.map {
            ShortcutBinding(commandID: $0.rawValue, key: key, scope: .browser, source: .hidden)
        }
        var records = [enabled, unknown, native, system, native] + spaceBindings
        let model = ShortcutsViewModel(additionalBindings: { records }, availableCommands: { [] })
        for binding in [enabled, unknown, native, system] {
            XCTAssertTrue(model.inventory.bindings.contains(binding))
        }
        for (index, binding) in spaceBindings.enumerated() {
            XCTAssertEqual(model.inventory.bindings.contains(binding), index < SpaceManager.shared.spaces.count)
        }
        let expected = model.inventory.bindings
        XCTAssertEqual(expected.count, Set(expected).count)
        records = Array(records.reversed()) + records
        model.rebuildSections()
        XCTAssertEqual(model.inventory.bindings, expected)
    }

    func testConflictTargetsOnlyLinkVisibleCommandsAndPreserveReservedOwners() throws {
        let key = ShortcutsKey(characters: "d", modifiers: [.control, .option])
        install([.IDC_DUPLICATE_TAB: .custom(key), .IDC_WINDOW_MUTE_SITE: .custom(key)])
        let reserved: [ShortcutBinding.Owner] = [.command(CommandWrapper.IDC_EXIT.rawValue),
            .command(999999), .nativeAction("copy:"), .system]
        let records = reserved.map {
            ShortcutBinding(owner: $0, key: key, scope: .all, source: .menu, title: "Reserved")
        }
        let model = ShortcutsViewModel(additionalBindings: { records + records }, availableCommands: { [] })
        let conflicts = model.conflicts(for: .IDC_DUPLICATE_TAB)
        let visible = try XCTUnwrap(conflicts.first { $0.id == .command(CommandWrapper.IDC_WINDOW_MUTE_SITE.rawValue) })
        XCTAssertEqual(visible.command, .IDC_WINDOW_MUTE_SITE)
        for owner in reserved {
            let conflict = try XCTUnwrap(conflicts.first { $0.id == owner })
            XCTAssertNil(conflict.command)
            XCTAssertEqual(conflict.keys, [key.displayString])
            XCTAssertEqual(conflicts.filter { $0.id == owner }.count, 1)
        }
    }

    func testTwoCustomOnlyCommandsReportEachOther() throws {
        let key = ShortcutsKey(characters: "d", modifiers: [.control, .option])
        install([.IDC_DUPLICATE_TAB: .custom(key), .IDC_WINDOW_MUTE_SITE: .custom(key)])
        let model = ShortcutsViewModel(additionalBindings: { [] }, availableCommands: { [] })
        let duplicate = try item(.IDC_DUPLICATE_TAB, in: model)
        let mute = try item(.IDC_WINDOW_MUTE_SITE, in: model)
        XCTAssertTrue(duplicate.conflictingCommandNames.contains(mute.name))
        XCTAssertTrue(mute.conflictingCommandNames.contains(duplicate.name))
    }

    func testDefaultAndCustomOnlyConflictIsSymmetric() throws {
        install([.IDC_DUPLICATE_TAB: .custom(try XCTUnwrap(Shortcuts.DefaultShortcuts[.IDC_RELOAD]))])
        let model = ShortcutsViewModel(additionalBindings: { [] }, availableCommands: { [] })
        let duplicate = try item(.IDC_DUPLICATE_TAB, in: model)
        let reload = try item(.IDC_RELOAD, in: model)
        XCTAssertTrue(duplicate.conflictingCommandNames.contains(reload.name))
        XCTAssertTrue(reload.conflictingCommandNames.contains(duplicate.name))
    }

    func testHiddenAliasConflictsInBothDirectionsDespiteDifferentPrimaryKey() throws {
        let pageDown = ShortcutsKey(characters: "\u{F72D}", modifiers: .control)
        install([.IDC_OPTIONS: .custom(pageDown)])
        let model = ShortcutsViewModel(additionalBindings: {
            [ShortcutBinding(commandID: CommandWrapper.IDC_SELECT_NEXT_TAB.rawValue,
                             key: pageDown, scope: .browser, source: .hidden)]
        })
        let settings = try item(.IDC_OPTIONS, in: model)
        let next = try item(.IDC_SELECT_NEXT_TAB, in: model)
        XCTAssertTrue(settings.conflictingCommandNames.contains(next.name))
        XCTAssertTrue(next.conflictingCommandNames.contains(settings.name))
        XCTAssertNotEqual(next.shortcutKey, pageDown)
        XCTAssertEqual(Set(model.inventory.occupants(of: pageDown).map(\.commandID)),
                       [CommandWrapper.IDC_OPTIONS.rawValue, CommandWrapper.IDC_SELECT_NEXT_TAB.rawValue])
    }

    func testDisabledCustomOnlyOwnerIsRemovedFromConflicts() throws {
        let key = ShortcutsKey(characters: "d", modifiers: [.control, .option])
        install([.IDC_DUPLICATE_TAB: .custom(key), .IDC_WINDOW_MUTE_SITE: .disabled])
        let model = ShortcutsViewModel(additionalBindings: { [] }, availableCommands: { [] })
        XCTAssertFalse(try item(.IDC_DUPLICATE_TAB, in: model).hasConflict)
        XCTAssertTrue(model.inventory.bindings(for: CommandWrapper.IDC_WINDOW_MUTE_SITE.rawValue).isEmpty)
    }

    func testOpenFileIsEditableAndFixedQuitStillExplainsConflicts() throws {
        install([.IDC_DUPLICATE_TAB: .custom(try XCTUnwrap(Shortcuts.DefaultShortcuts[.IDC_EXIT]))])
        let model = ShortcutsViewModel(additionalBindings: { [] }, availableCommands: { [] })
        XCTAssertEqual(try item(.IDC_OPEN_FILE, in: model).shortcutKey,
                       ShortcutsKey(characters: "o", modifiers: .command))
        XCTAssertFalse(model.sections.flatMap(\.items).contains { $0.command == .IDC_EXIT })
        XCTAssertFalse(model.reservedShortcuts.contains { $0.id == .command(CommandWrapper.IDC_EXIT.rawValue) })
        let quit = try XCTUnwrap(model.conflicts(for: .IDC_DUPLICATE_TAB).first {
            $0.id == .command(CommandWrapper.IDC_EXIT.rawValue)
        })
        XCTAssertNil(quit.command)
        XCTAssertEqual(quit.keys, ["⌘Q"])
        XCTAssertFalse(quit.name.isEmpty)
    }

    func testSystemServicesAreHiddenButStillReportConflictingAssignments() throws {
        let bindings: [ShortcutBinding] = [
            .init(commandID: CommandWrapper.IDC_CONTENT_CONTEXT_SELECTALL.rawValue,
                  key: .init(characters: "a", modifiers: .command), scope: .all, source: .menu, title: "Select All"),
            .init(commandID: CommandWrapper.IDC_CONTENT_CONTEXT_UNDO.rawValue,
                  key: .init(characters: "z", modifiers: .command), scope: .all, source: .menu, title: "Undo"),
            .init(commandID: CommandWrapper.IDS_EDIT_CHECK_DOCUMENT_MAC.rawValue,
                  key: .init(characters: ";", modifiers: .command), scope: .all, source: .menu, title: "Check Document Now"),
            .init(owner: .nativeAction("orderFrontCharacterPalette:"),
                  key: .init(characters: " ", modifiers: [.command, .control]),
                  scope: .all, source: .menu, title: "Emoji & Symbols")
        ]
        let model = ShortcutsViewModel(additionalBindings: { bindings })
        for binding in bindings {
            XCTAssertFalse(model.reservedShortcuts.contains { $0.id == binding.owner })
            XCTAssertFalse(model.sections.flatMap(\.items).contains { $0.command.rawValue == binding.commandID })
            XCTAssertTrue(model.inventory.occupants(of: binding.key).contains(binding))
            install([.IDC_DUPLICATE_TAB: .custom(binding.key)])
            model.rebuildSections()
            let conflict = try XCTUnwrap(model.conflicts(for: .IDC_DUPLICATE_TAB).first { $0.id == binding.owner })
            XCTAssertNil(conflict.command)
            XCTAssertEqual(conflict.name, try XCTUnwrap(binding.title))
        }
        for command in [CommandWrapper.IDC_FIND, .IDC_FIND_NEXT, .IDC_FIND_PREVIOUS, .IDC_FOCUS_SEARCH] {
            XCTAssertNotNil(try item(command, in: model).shortcutKey)
        }
    }

    func testBrowserRowsUseRuntimeDefaultsAndKeepDisabledDiscoveredCommandsEditable() throws {
        let move = ShortcutsKey(characters: "\u{F72C}", modifiers: [.control, .shift])
        let focus = ShortcutsKey(characters: "c", modifiers: [.command, .control])
        let model = ShortcutsViewModel(additionalBindings: {
            [.init(commandID: CommandWrapper.IDC_MOVE_TAB_PREVIOUS.rawValue, key: move, scope: .browser, source: .hidden),
             .init(commandID: CommandWrapper.IDC_ADD_NEW_TAB_TO_GROUP.rawValue, key: focus, scope: .browser, source: .hidden)]
        })
        XCTAssertEqual(try item(.IDC_MOVE_TAB_PREVIOUS, in: model).shortcutKey, move)
        XCTAssertEqual(try item(.IDC_ADD_NEW_TAB_TO_GROUP, in: model).shortcutKey, focus)
        XCTAssertEqual(try item(.IDC_RELOAD_BYPASSING_CACHE, in: model).shortcutKey,
                       ShortcutsKey(characters: "r", modifiers: [.command, .shift]))
        install([.IDC_DUPLICATE_TAB: .custom(focus)])
        model.rebuildSections()
        XCTAssertTrue(model.conflicts(for: .IDC_DUPLICATE_TAB).contains { $0.command == .IDC_ADD_NEW_TAB_TO_GROUP })

        install([.IDC_ADD_NEW_TAB_TO_GROUP: .disabled])
        let disabled = ShortcutsViewModel(additionalBindings: { [] }, availableCommands: { [] })
        XCTAssertNil(try item(.IDC_ADD_NEW_TAB_TO_GROUP, in: disabled).shortcutKey)
        XCTAssertTrue(disabled.inventory.bindings(for: CommandWrapper.IDC_ADD_NEW_TAB_TO_GROUP.rawValue).isEmpty)
    }

    func testProductPolicyOverridesSavedKeysAndStaleRuntimeBindings() throws {
        let releasedKey = ShortcutsKey(characters: "m", modifiers: [.command, .shift])
        let commands: [CommandWrapper] = [.IDC_FOCUS_NEXT_PANE, .IDC_FOCUS_PREVIOUS_PANE,
            .IDC_FOCUS_INACTIVE_POPUP_FOR_ACCESSIBILITY, .IDC_SHOW_AVATAR_MENU,
            .IDC_TOGGLE_FULLSCREEN_TOOLBAR, .IDC_HELP_PAGE_VIA_MENU]
        install(Dictionary(uniqueKeysWithValues: commands.map { ($0, .custom(releasedKey)) }))
        let saved = Shortcuts.configuration.overrides
        let stale = commands.flatMap { command in
            [ShortcutBinding.Source.menu, .hidden, .webContents].map {
                ShortcutBinding(commandID: command.rawValue, key: releasedKey, scope: .all, source: $0)
            }
        }
        let model = ShortcutsViewModel(additionalBindings: { stale })
        for command in commands {
            XCTAssertNil(Shortcuts.key(for: command))
            XCTAssertEqual(Shortcuts.chromiumOverrideState(for: command.rawValue), .disabled)
            let menuItem = NSMenuItem(title: "Unsupported command", action: nil, keyEquivalent: "m")
            menuItem.tag = command.rawValue
            menuItem.keyEquivalentModifierMask = [.command, .shift]
            Shortcuts.updateShortcut(for: menuItem)
            XCTAssertTrue(menuItem.keyEquivalent.isEmpty)
            XCTAssertEqual(menuItem.keyEquivalentModifierMask.rawValue, 0)
            XCTAssertFalse(Shortcuts.configurableCommands.contains(command))
            XCTAssertFalse(model.sections.flatMap(\.items).contains { $0.command == command })
            XCTAssertFalse(model.reservedShortcuts.contains { $0.id == .command(command.rawValue) })
            XCTAssertTrue(model.inventory.bindings(for: command.rawValue).isEmpty)
        }
        XCTAssertTrue(model.inventory.occupants(of: releasedKey).isEmpty)
        XCTAssertEqual(Shortcuts.configuration.overrides, saved)

        install([.IDC_RELOAD: .custom(releasedKey)])
        model.rebuildSections()
        XCTAssertEqual(Shortcuts.key(for: .IDC_RELOAD), releasedKey)
        XCTAssertEqual(Set(model.inventory.occupants(of: releasedKey).map(\.owner)),
                       [.command(CommandWrapper.IDC_RELOAD.rawValue)])
    }

    func testDiscoveredCommandsJoinTheirFunctionalSectionsWithoutDuplicates() throws {
        let expected: [(Shortcuts.Group, [CommandWrapper])] = [
            (.file, [.IDC_SAVE_PAGE, .IDC_BASIC_PRINT]),
            (.view, [.IDC_FULLSCREEN]),
            (.history, [.IDC_CLEAR_BROWSING_DATA]),
            (.bookmarks, [.IDC_BOOKMARK_THIS_TAB, .IDC_BOOKMARK_ALL_TABS, .IDC_SHOW_BOOKMARK_MANAGER]),
            (.window, [.IDC_TASK_MANAGER]),
            (.tab, [.IDC_NEW_SPLIT_TAB, .IDC_WINDOW_PIN_TAB, .IDC_WINDOW_CLOSE_OTHER_TABS,
                    .IDC_WINDOW_CLOSE_TABS_TO_RIGHT, .IDC_MOVE_TAB_TO_NEW_WINDOW,
                    .IDC_CREATE_NEW_TAB_GROUP, .IDC_ADD_NEW_TAB_TO_GROUP, .IDC_WINDOW_GROUP_TAB,
                    .IDC_FOCUS_PREV_TAB_GROUP, .IDC_FOCUS_NEXT_TAB_GROUP, .IDC_CLOSE_TAB_GROUP])
        ]
        let key = ShortcutsKey(characters: "g", modifiers: [.control, .option])
        let commands = expected.flatMap { $0.1 }
        let model = ShortcutsViewModel(additionalBindings: {
            (commands + [.IDC_DEBUG_PRINT_VIEW_TREE]).map {
                ShortcutBinding(commandID: $0.rawValue, key: key, scope: .browser, source: .hidden)
            }
        }, availableCommands: { [] })
        for (group, expectedCommands) in expected {
            let section = try XCTUnwrap(model.sections.first { $0.category == group.title })
            XCTAssertEqual(section.items.filter { commands.contains($0.command) }.map(\.command), expectedCommands)
            for command in expectedCommands {
                let row = try item(command, in: model)
                XCTAssertEqual(row.shortcutKey, Shortcuts.DefaultShortcuts[command] ?? key)
                XCTAssertTrue(row.aliases.contains(key))
            }
        }
        let allCommands = model.sections.flatMap(\.items).map(\.command)
        XCTAssertEqual(allCommands.count, Set(allCommands).count)
        let other = try XCTUnwrap(model.sections.first { $0.items.contains { $0.command == .IDC_DEBUG_PRINT_VIEW_TREE } })
        XCTAssertEqual(other.items.map(\.command), [.IDC_DEBUG_PRINT_VIEW_TREE])
        XCTAssertTrue(Shortcuts.configuration.overrides.isEmpty)
    }

    func testVisibleUnassignedMenuCommandsCanBeConfiguredWithoutInventingBindings() throws {
        let menu = NSMenu()
        for command in [CommandWrapper.IDC_SAVE_PAGE, .IDC_IMPORT_SETTINGS, .IDC_NEW_TAB_TO_RIGHT, .IDC_NEW_SPLIT_TAB] {
            let item = NSMenuItem(title: "Unassigned", action: NSSelectorFromString("commandDispatch:"), keyEquivalent: "")
            item.tag = command.rawValue
            menu.addItem(item)
        }
        let hidden = NSMenuItem(title: "Hidden", action: NSSelectorFromString("commandDispatch:"), keyEquivalent: "")
        hidden.tag = CommandWrapper.IDC_WINDOW_PIN_TAB.rawValue
        hidden.isHidden = true
        menu.addItem(hidden)
        let model = ShortcutsViewModel(additionalBindings: { [] }, availableCommands: {
            Shortcuts.availableMenuCommands(in: menu)
        })
        for command in [CommandWrapper.IDC_SAVE_PAGE, .IDC_NEW_SPLIT_TAB] {
            let row = try item(command, in: model)
            XCTAssertNil(row.shortcutKey)
            XCTAssertTrue(model.inventory.bindings(for: command.rawValue).isEmpty)
            model.startRecording(for: command)
            XCTAssertEqual(model.editingCommand, command)
        }
        for command in [CommandWrapper.IDC_WINDOW_PIN_TAB, .IDC_IMPORT_SETTINGS, .IDC_NEW_TAB_TO_RIGHT] {
            XCTAssertFalse(model.sections.flatMap(\.items).contains { $0.command == command })
        }
        XCTAssertTrue(Shortcuts.configuration.overrides.isEmpty)
    }

    func testSavePageMenuRebuildPreservesCustomAndDisabledBindings() {
        let menu = NSMenu()
        let item = NSMenuItem(title: "Save Page", action: NSSelectorFromString("commandDispatch:"), keyEquivalent: "s")
        item.tag = CommandWrapper.IDC_SAVE_PAGE.rawValue
        menu.addItem(item)
        let key = ShortcutsKey(characters: "s", modifiers: [.command, .option])
        install([.IDC_SAVE_PAGE: .custom(key)])
        AppController.installOrUpdateFileMenuItems(in: menu, target: nil)
        XCTAssertEqual(item.keyEquivalent, key.menuKeyEquivalent.characters)
        XCTAssertEqual(item.keyEquivalentModifierMask, key.menuKeyEquivalent.modifiers)
        install([.IDC_SAVE_PAGE: .disabled])
        AppController.installOrUpdateFileMenuItems(in: menu, target: nil)
        XCTAssertTrue(item.keyEquivalent.isEmpty)
        install([:])
        AppController.installOrUpdateFileMenuItems(in: menu, target: nil)
        XCTAssertTrue(item.keyEquivalent.isEmpty)
    }

    func testCategoriesDoNotExposeUndiscoveredCommandsAndBookmarkBarMovesFromView() throws {
        let model = ShortcutsViewModel(additionalBindings: { [] }, availableCommands: { [] })
        let commands = Set(model.sections.flatMap(\.items).map(\.command))
        XCTAssertTrue(commands.isDisjoint(with: Shortcuts.Group.allCases.flatMap(\.discoveredCommands)))
        let bookmarks = try XCTUnwrap(model.sections.first { $0.category == Shortcuts.Group.bookmarks.title })
        XCTAssertEqual(bookmarks.items.map(\.command), [.IDC_SHOW_BOOKMARK_BAR])
        let view = try XCTUnwrap(model.sections.first { $0.category == Shortcuts.Group.view.title })
        XCTAssertFalse(view.items.contains { $0.command == .IDC_SHOW_BOOKMARK_BAR })
        model.filter = .section(Shortcuts.Group.bookmarks.title)
        XCTAssertEqual(model.filteredSections.flatMap(\.items).map(\.command), [.IDC_SHOW_BOOKMARK_BAR])
    }

    func testCategorizedSavedCommandsKeepDisabledStateAndConflictNavigation() throws {
        let key = try XCTUnwrap(Shortcuts.DefaultShortcuts[.IDC_NEW_TAB])
        install([.IDC_CREATE_NEW_TAB_GROUP: .disabled, .IDC_BOOKMARK_THIS_TAB: .custom(key)])
        let saved = Shortcuts.configuration.overrides
        let model = ShortcutsViewModel(additionalBindings: { [] }, availableCommands: { [] })
        let tab = try XCTUnwrap(model.sections.first { $0.category == Shortcuts.Group.tab.title })
        XCTAssertTrue(tab.items.contains { $0.command == .IDC_CREATE_NEW_TAB_GROUP })
        XCTAssertNil(try item(.IDC_CREATE_NEW_TAB_GROUP, in: model).shortcutKey)
        XCTAssertTrue(try item(.IDC_CREATE_NEW_TAB_GROUP, in: model).isOverridden)
        let bookmarks = try XCTUnwrap(model.sections.first { $0.category == Shortcuts.Group.bookmarks.title })
        XCTAssertTrue(bookmarks.items.contains { $0.command == .IDC_BOOKMARK_THIS_TAB })
        XCTAssertEqual(try item(.IDC_BOOKMARK_THIS_TAB, in: model).shortcutKey, key)
        XCTAssertTrue(model.conflicts(for: .IDC_NEW_TAB).contains { $0.command == .IDC_BOOKMARK_THIS_TAB })

        model.filter = .section(Shortcuts.Group.tab.title)
        model.selectConflict(.IDC_BOOKMARK_THIS_TAB)
        XCTAssertEqual(model.filter, .all)
        XCTAssertEqual(model.selectedItem?.command, .IDC_BOOKMARK_THIS_TAB)
        XCTAssertTrue(model.filteredSections.flatMap(\.items).contains { $0.command == .IDC_BOOKMARK_THIS_TAB })
        XCTAssertEqual(Shortcuts.configuration.overrides, saved)

        install([:])
        model.rebuildSections()
        XCTAssertFalse(model.sections.flatMap(\.items).contains { $0.command == .IDC_CREATE_NEW_TAB_GROUP })
        XCTAssertFalse(model.sections.flatMap(\.items).contains { $0.command == .IDC_BOOKMARK_THIS_TAB })
    }

    func testUnavailableServicesDoNotConflictButOtherServiceStatesStillDo() throws {
        install([.IDC_TAB_SEARCH: .custom(.init(characters: "m", modifiers: [.command, .shift]))])
        let menu = NSMenu()
        let services = NSMenu(title: "Services")
        services.autoenablesItems = false
        let parent = NSMenuItem()
        parent.submenu = services
        menu.addItem(parent)
        // Services may be grouped into nested submenus.
        let group = NSMenuItem()
        let nested = NSMenu(title: "Text")
        nested.autoenablesItems = false
        group.submenu = nested
        services.addItem(group)
        let service = NSMenuItem(title: "Open man Page in Terminal",
                                 action: NSSelectorFromString("_processRequest:"), keyEquivalent: "M")
        service.keyEquivalentModifierMask = .command
        service.allowsKeyEquivalentWhenHidden = true
        nested.addItem(service)
        let model = ShortcutsViewModel(additionalBindings: {
            Shortcuts.menuBindings(in: menu, servicesMenu: services)
        })

        for hidden in [false, true] {
            for enabled in [false, true] {
                service.isHidden = hidden
                service.isEnabled = enabled
                model.rebuildSections()
                let conflicts = model.conflicts(for: .IDC_TAB_SEARCH)
                if hidden && !enabled {
                    XCTAssertTrue(conflicts.isEmpty)
                    XCTAssertFalse(try item(.IDC_TAB_SEARCH, in: model).hasConflict)
                } else {
                    XCTAssertEqual(conflicts.map(\.name), [service.title])
                    XCTAssertEqual(conflicts.first?.keys, ["⇧⌘M"])
                }
            }
        }

        // The same selector outside the Services tree must not be filtered.
        service.isHidden = true
        service.isEnabled = false
        XCTAssertEqual(Shortcuts.menuBindings(in: menu, servicesMenu: nil).count, 1)
    }

    func testReplacedServicesSnapshotDoesNotReserveKeysOrHideChromiumConflicts() throws {
        let registeredServices = NSMenu(title: "Registered Services")
        let services = NSMenu(title: "Localized Services")
        services.autoenablesItems = false
        let service = NSMenuItem(title: "Search man Page Index in Terminal",
                                 action: NSSelectorFromString("_processRequest:"), keyEquivalent: "A")
        service.keyEquivalentModifierMask = .command
        service.isHidden = false
        service.isEnabled = true
        services.addItem(service)
        services.addItem(NSMenuItem(title: "Localized Settings",
                                    action: NSSelectorFromString("_configureServicesMenu:"), keyEquivalent: ""))
        let mainMenu = NSMenu()
        let parent = NSMenuItem()
        parent.submenu = services
        mainMenu.addItem(parent)
        var currentServices = services
        let model = ShortcutsViewModel(additionalBindings: {
            Shortcuts.menuBindings(in: mainMenu, servicesMenu: currentServices)
        })
        XCTAssertTrue(service.keyEquivalent.isEmpty)
        XCTAssertTrue((service.copy() as? NSMenuItem)?.keyEquivalent.isEmpty == true)
        XCTAssertTrue(model.conflicts(for: .IDC_TAB_SEARCH).isEmpty)

        // Reproduce the live mismatch after a menu rebuild: the visible tree
        // retains enabled service entries, but AppKit owns a different menu.
        currentServices = registeredServices
        model.rebuildSections()
        XCTAssertTrue(model.conflicts(for: .IDC_TAB_SEARCH).isEmpty)
        XCTAssertFalse(try item(.IDC_TAB_SEARCH, in: model).hasConflict)

        // A hidden Chromium menu command outside Services still reserves its key.
        let browserItem = NSMenuItem(title: "Find", action: NSSelectorFromString("commandDispatch:"),
                                     keyEquivalent: "A")
        browserItem.tag = CommandWrapper.IDC_FIND.rawValue
        browserItem.keyEquivalentModifierMask = .command
        browserItem.isHidden = true
        browserItem.isEnabled = false
        mainMenu.addItem(browserItem)
        model.rebuildSections()
        XCTAssertEqual(model.conflicts(for: .IDC_TAB_SEARCH).map(\.command), [.IDC_FIND])
        XCTAssertTrue(model.conflicts(for: .IDC_FIND).contains { $0.command == .IDC_TAB_SEARCH })
    }

    func testMenuSnapshotIncludesHiddenKeysUsedByChromiumMatching() throws {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let parent = NSMenuItem()
        parent.submenu = NSMenu()
        parent.submenu?.autoenablesItems = false
        menu.addItem(parent)
        let item = NSMenuItem(title: "Find", action: NSSelectorFromString("performFindPanelAction:"), keyEquivalent: "f")
        item.tag = CommandWrapper.IDC_FIND.rawValue
        item.keyEquivalentModifierMask = .command
        parent.submenu?.addItem(item)
        XCTAssertEqual(Shortcuts.menuBindings(in: menu).map(\.commandID), [item.tag])
        item.isHidden = true
        XCTAssertEqual(Shortcuts.menuBindings(in: menu).count, 1)
        item.allowsKeyEquivalentWhenHidden = true
        XCTAssertEqual(Shortcuts.menuBindings(in: menu).count, 1)
        item.isEnabled = false
        XCTAssertEqual(Shortcuts.menuBindings(in: menu).count, 1)
        install([.IDC_OPTIONS: .custom(.init(characters: "f", modifiers: .command))])
        let model = ShortcutsViewModel(additionalBindings: { Shortcuts.menuBindings(in: menu) })
        XCTAssertTrue(try self.item(.IDC_OPTIONS, in: model).hasConflict)
        XCTAssertTrue(try self.item(.IDC_FIND, in: model).hasConflict)
        item.keyEquivalent = ""
        XCTAssertTrue(Shortcuts.menuBindings(in: menu).isEmpty)
    }
}

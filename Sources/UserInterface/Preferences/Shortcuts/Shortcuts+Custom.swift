// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import AppKit
import ObjectiveC

/// Menu fields are also read by Chromium's matcher. Project them only while
/// AppKit tracks a visible menu, then restore the exact matching representation.
final class ShortcutMenuPresentation {
    private static var associationKey: UInt8 = 0
    private static var aliasAssociationKey: UInt8 = 0
    private struct Projection {
        let original: ShortcutsKey.MenuKeyEquivalent
        let display: ShortcutsKey.MenuKeyEquivalent
        let alias: NSMenuItem
    }
    private var projections: [NSMenuItem: Projection] = [:]
    private var isUpdating = false

    private static func state(for menu: NSMenu) -> ShortcutMenuPresentation? {
        objc_getAssociatedObject(menu, &associationKey) as? ShortcutMenuPresentation
    }

    private static func declaredKey(_ item: NSMenuItem) -> ShortcutsKey.MenuKeyEquivalent {
        // AppKit copies custom views through NSCoding; programmatic hosting
        // views cannot be decoded. Only detach ordinary items to recover keys.
        let declared = item.keyEquivalent.isEmpty && item.view == nil
            ? (item.copy() as? NSMenuItem ?? item) : item
        return .init(characters: declared.keyEquivalent, modifiers: declared.keyEquivalentModifierMask)
    }

    private static func displayedKey(_ key: ShortcutsKey.MenuKeyEquivalent,
                                     for item: NSMenuItem) -> ShortcutsKey.MenuKeyEquivalent {
        // A menu equivalent has already folded Shift into its character. Only
        // the original binding can distinguish keypad "*" from number-row "8".
        guard let command = CommandWrapper(rawValue: item.tag),
              let original = Shortcuts.key(for: command),
              original.menuKeyEquivalent == key else { return key }
        // AppKit reports Ctrl-Shift-= as "+", and "+" alone hides the Shift.
        if command == .PHI_SPLIT_WITH_NEW_TAB, original == Shortcuts.DefaultShortcuts[command] {
            return ShortcutsKey(characters: "=", modifiers: original.modifiers,
                                preservesShift: true).menuKeyEquivalent
        }
        let display = original.displayKey
        return display == original ? key : display.menuKeyEquivalent
    }

    static func isMatchingAlias(_ item: NSMenuItem) -> Bool {
        objc_getAssociatedObject(item, &aliasAssociationKey) != nil
    }

    static func originalKey(for item: NSMenuItem) -> ShortcutsKey.MenuKeyEquivalent? {
        guard let menu = item.menu, let state = state(for: menu),
              let projection = state.projections[item],
              state.isUpdating || declaredKey(item) == projection.display else { return nil }
        return projection.original
    }

    static func handle(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu else { return }
        switch notification.name {
        case NSMenu.didBeginTrackingNotification:
            begin(in: menu)
        case NSMenu.didEndTrackingNotification:
            end(in: menu)
        default:
            update(in: menu)
        }
    }

    private static func begin(in menu: NSMenu) {
        if state(for: menu) == nil {
            objc_setAssociatedObject(menu, &associationKey, ShortcutMenuPresentation(),
                                     .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        update(in: menu)
        for item in menu.items {
            if let submenu = item.submenu { begin(in: submenu) }
        }
    }

    private static func update(in menu: NSMenu) {
        guard let state = state(for: menu), !state.isUpdating else { return }
        state.isUpdating = true
        defer { state.isUpdating = false }
        for (item, projection) in state.projections where item.menu !== menu {
            state.projections.removeValue(forKey: item)
            if declaredKey(item) == projection.display {
                item.keyEquivalent = projection.original.characters
                item.keyEquivalentModifierMask = projection.original.modifiers
            }
            if projection.alias.menu === menu { menu.removeItem(projection.alias) }
        }
        for item in menu.items where item.submenu == nil && item.view == nil && !isMatchingAlias(item) {
            let declared = declaredKey(item)
            let previous = state.projections[item]
            let original = previous.flatMap {
                declared == $0.display ? $0.original : nil
            } ?? declared
            let display = item.isHidden ? original : displayedKey(original, for: item)
            if display != original {
                guard let alias = previous?.alias ?? (item.copy() as? NSMenuItem) else { continue }
                alias.keyEquivalent = original.characters
                alias.keyEquivalentModifierMask = original.modifiers
                alias.action = item.action
                alias.target = item.target
                alias.isEnabled = item.isEnabled
                alias.isHidden = true
                alias.allowsKeyEquivalentWhenHidden = true
                objc_setAssociatedObject(alias, &aliasAssociationKey, true,
                                         .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                state.projections[item] = Projection(original: original, display: display, alias: alias)
                // The displayed digit does not accept every event the symbol
                // accepted, including keypad Multiply. Retain that exact route.
                // TODO:// Preserve conflict priority during menu tracking. An earlier
                // Cmd-Shift-8 item loses to a later Cmd-keypad-* item when its alias
                // is appended here; closing the menu restores the original winner.
                // Keep aliases beside their owners and test the invoked command identity.
                // Evaluate strict Shift-aware matching separately across Phi, Chromium,
                // conflict detection, and legacy bindings; existing equivalence is retained.
                if alias.menu == nil { menu.addItem(alias) }
            } else {
                state.projections.removeValue(forKey: item)
                if let alias = previous?.alias, alias.menu === menu { menu.removeItem(alias) }
            }
            if display != declared {
                item.keyEquivalent = display.characters
                item.keyEquivalentModifierMask = display.modifiers
            }
        }
    }

    private static func end(in menu: NSMenu) {
        if let state = state(for: menu) {
            // Keep inventory reads canonical between the two property writes.
            state.isUpdating = true
            for (item, projection) in state.projections {
                if declaredKey(item) == projection.display {
                    item.keyEquivalent = projection.original.characters
                    item.keyEquivalentModifierMask = projection.original.modifiers
                }
                if projection.alias.menu === menu { menu.removeItem(projection.alias) }
            }
            objc_setAssociatedObject(menu, &associationKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        for item in menu.items {
            if let submenu = item.submenu { end(in: submenu) }
        }
    }
}

extension Notification.Name {
    static let shortcutsDidChange = Notification.Name("PhiShortcutsDidChangeNotification")
}

extension Shortcuts {
    /// These commands always use product defaults, including with legacy overrides.
    static let fixedShortcutCommands: Set<CommandWrapper> = [.IDC_EXIT]

    /// Product policy: add commands here to release all their keyboard bindings.
    /// This takes precedence over defaults and saved overrides. It does not
    /// disable the key combinations themselves or non-keyboard command entry points.
    static let disabledShortcutCommands: Set<CommandWrapper> = [
        // These actions remain available from menus without keyboard bindings.
        .IDC_IMPORT_SETTINGS,
        .IDC_NEW_TAB_TO_RIGHT,
        .IDC_NEW_SPLIT_TAB,
        // Chromium UI commands that are not supported by Phi's native shell.
        .IDC_FOCUS_NEXT_PANE,
        .IDC_FOCUS_PREVIOUS_PANE,
        .IDC_FOCUS_INACTIVE_POPUP_FOR_ACCESSIBILITY,
        .IDC_SHOW_AVATAR_MENU,
        .IDC_TOGGLE_FULLSCREEN_TOOLBAR,
        .IDC_HELP_PAGE_VIA_MENU,
        // Phi owns tab switching; Chromium must not revive its Ctrl-Tab aliases.
        .IDC_CYCLE_TO_NEXT_TAB,
        .IDC_CYCLE_TO_PREV_TAB,
    ]

    static func isShortcutDisabled(for commandID: Int) -> Bool {
        CommandWrapper(rawValue: commandID).map(disabledShortcutCommands.contains) ?? false
    }

    /// Shortcut groups shown in the settings view.
    /// Actual visibility is filtered by `ShortcutsViewModel.hiddenGroups`.
    enum Group: String, CaseIterable {
        case app = "App"
        case file = "File"
        case edit = "Edit"
        case view = "View"
        case history = "History"
        case bookmarks = "Bookmarks"
        case window = "Window"
        case tab = "Tab"
        case spaces = "Spaces"
        case kiosk = "Kiosk"
        case help = "Help"
        
        var title: String {
            switch self {
            case .app:
                return NSLocalizedString("settings.shortcuts.group.app", value: "App", comment: "Shortcuts settings - Section title for application commands")
            case .file:
                return NSLocalizedString("settings.shortcuts.group.file", value: "File", comment: "Shortcuts settings - Section title for file commands")
            case .edit:
                return NSLocalizedString("settings.shortcuts.group.edit", value: "Edit", comment: "Shortcuts settings - Section title for editing commands")
            case .view:
                return NSLocalizedString("settings.shortcuts.group.view", value: "View", comment: "Shortcuts settings - Section title for view commands")
            case .history:
                return NSLocalizedString("settings.shortcuts.group.history", value: "History", comment: "Shortcuts settings - Section title for browsing history commands")
            case .bookmarks:
                return NSLocalizedString("settings.shortcuts.group.bookmarks", value: "Bookmarks", comment: "Shortcuts settings - Section title for bookmark commands")
            case .window:
                return NSLocalizedString("settings.shortcuts.group.window", value: "Window", comment: "Shortcuts settings - Section title for window commands")
            case .tab:
                return NSLocalizedString("settings.shortcuts.group.tab", value: "Tab", comment: "Shortcuts settings - Section title for tab commands")
            case .spaces:
                return NSLocalizedString("settings.shortcuts.group.spaces", value: "Spaces", comment: "Shortcuts settings - Section title for Space commands")
            case .kiosk:
                return NSLocalizedString("settings.shortcuts.group.kiosk", value: "Kiosk & Peek", comment: "Shortcuts settings - Section title for Kiosk and Peek commands")
            case .help:
                return NSLocalizedString("settings.shortcuts.group.help", value: "Help", comment: "Shortcuts settings - Section title for help commands")
            }
        }
        
        var subtitle: String? {
            guard self == .kiosk else { return nil }
            return NSLocalizedString("settings.shortcuts.group.kiosk.subtitle", value: "Only work in Peek or Kiosk windows.", comment: "Shortcuts settings - Subtitle explaining that this group's shortcuts apply to Peek or Kiosk windows")
        }

        var commands: [CommandWrapper] {
            switch self {
            case .app:
                return [.IDC_OPTIONS]
            case .file:
                var commands: [CommandWrapper] = [.IDC_NEW_TAB,
                        .IDC_NEW_WINDOW,
                        .IDC_NEW_INCOGNITO_WINDOW,
                        .PHI_NEW_KIOSK_WINDOW,
                        .PHI_NEW_INCOGNITO_SPACE,
                        .IDC_RESTORE_TAB,
                        .IDC_OPEN_FILE,
                        .IDC_FOCUS_LOCATION,
                        .IDC_CLOSE_WINDOW,
                        .IDC_CLOSE_TAB,
                        .PHI_CAPTURE_FULL_PAGE,
                        .PHI_CAPTURE_AREA,
                        .PHI_SHARE_PAGE,
                        .PHI_SAVE_FOR_LATER,
                        .IDC_PRINT]
                if !SaveForLaterService.featureEnabled {
                    commands.removeAll { $0 == .PHI_SAVE_FOR_LATER }
                }
                return commands
            case .edit:
                return [.PHI_COPY_URL,
                        .IDC_FIND,
                        .IDC_FIND_NEXT,
                        .IDC_FIND_PREVIOUS,
                        .IDS_EDIT_USE_SELECTION_MAC,
                        .IDS_EDIT_JUMP_TO_SELECTION_MAC,
                        .IDC_FOCUS_SEARCH]
            case .view:
                return [.IDC_STOP,
                        .IDC_RELOAD,
                        .IDC_RELOAD_BYPASSING_CACHE,
                        .IDC_ZOOM_NORMAL,
                        .IDC_ZOOM_PLUS,
                        .IDC_ZOOM_MINUS,
                        .IDC_VIEW_SOURCE,
                        .IDC_DEV_TOOLS,
                        .IDC_DEV_TOOLS_INSPECT,
                        .IDC_DEV_TOOLS_CONSOLE,
                        .PHI_TOGGLE_SIDEBAR,
                        .PHI_TOGGLE_CHATBAR,
                        .PHI_TOGGLE_READER,
                        .PHI_NEW_CONVERSATION]
            case .history:
                return [.IDC_HOME,
                        .IDC_BACK,
                        .IDC_FORWARD,
                        .IDC_SHOW_HISTORY]
            case .bookmarks:
                return [.IDC_SHOW_BOOKMARK_BAR]
            case .window:
                return [.IDC_MANAGE_EXTENSIONS,
                        .IDC_SHOW_DOWNLOADS]
            case .tab:
                return [.PHI_TAB_SWITCHER_FORWARD,
                        .PHI_TAB_SWITCHER_BACKWARD,
                        .IDC_NEW_TAB_TO_RIGHT,
                        .PHI_SPLIT_WITH_NEW_TAB,
                        .IDC_SELECT_NEXT_TAB,
                        .IDC_SELECT_PREVIOUS_TAB,
                        .IDC_MOVE_TAB_PREVIOUS,
                        .IDC_MOVE_TAB_NEXT,
                        .IDC_SELECT_TAB_0,
                        .IDC_SELECT_TAB_1,
                        .IDC_SELECT_TAB_2,
                        .IDC_SELECT_TAB_3,
                        .IDC_SELECT_TAB_4,
                        .IDC_SELECT_TAB_5,
                        .IDC_SELECT_TAB_6,
                        .IDC_SELECT_TAB_7,
                        .IDC_SELECT_LAST_TAB,
                        .IDC_DUPLICATE_TAB,
                        .IDC_WINDOW_MUTE_SITE,
                        .PHI_FARRINGDON_TOGGLE,
                        .IDC_TAB_SEARCH]
            case .spaces:
                return [.PHI_SELECT_NEXT_SPACE,
                        .PHI_SELECT_PREVIOUS_SPACE] + CommandWrapper.spaceSelectionCommands
            case .kiosk:
                return [.PHI_KIOSK_OPEN_IN_SPACE, .PHI_KIOSK_CHOOSE_SPACE]
//            case .help:
//                return [.IDC_FEEDBACK,
//                        .IDC_HELP_PAGE_VIA_MENU]
            default: return []
            }
        }

        /// Presentation order for additional commands, shown only when discovered
        /// in available menus, live bindings, or saved overrides. These do not register defaults.
        var discoveredCommands: [CommandWrapper] {
            switch self {
            case .app:
                return [.IDC_IMPORT_SETTINGS]
            case .file:
                return [.IDC_SAVE_PAGE, .IDC_BASIC_PRINT]
            case .view:
                return [.IDC_FULLSCREEN]
            case .history:
                return [.IDC_CLEAR_BROWSING_DATA]
            case .bookmarks:
                return [.IDC_BOOKMARK_THIS_TAB, .IDC_BOOKMARK_ALL_TABS, .IDC_SHOW_BOOKMARK_MANAGER]
            case .window:
                return [.IDC_TASK_MANAGER]
            case .tab:
                return [.IDC_NEW_SPLIT_TAB,
                        .IDC_WINDOW_PIN_TAB,
                        .IDC_WINDOW_CLOSE_OTHER_TABS,
                        .IDC_WINDOW_CLOSE_TABS_TO_RIGHT,
                        .IDC_MOVE_TAB_TO_NEW_WINDOW,
                        .IDC_CREATE_NEW_TAB_GROUP,
                        .IDC_ADD_NEW_TAB_TO_GROUP,
                        .IDC_WINDOW_GROUP_TAB,
                        .IDC_FOCUS_PREV_TAB_GROUP,
                        .IDC_FOCUS_NEXT_TAB_GROUP,
                        .IDC_CLOSE_TAB_GROUP]
            default:
                return []
            }
        }
    }
    
    static var configuration: ShortcutConfiguration = {
        var configuration = ShortcutConfiguration()
        do {
            try configuration.reload(from: customShortcutsFileURL)
        } catch {
            AppLogError("[Shortcuts] Failed to load configuration: \(error)")
        }
        return configuration
    }()
    
    static func key(for command: CommandWrapper) -> ShortcutsKey? {
        guard !disabledShortcutCommands.contains(command) else { return nil }
        if let override = overrideState(for: command.rawValue) {
            if !override.inheritsDefaults { return override.key }
            return DefaultShortcuts[command].flatMap { override.excludes($0) ? nil : $0 }
        }
        return DefaultShortcuts[command]
    }
    
    static func overrideState(for commandId: Int) -> ShortcutOverride? {
        if let command = CommandWrapper(rawValue: commandId), fixedShortcutCommands.contains(command) {
            return nil
        }
        return configuration.overrides[commandId]
    }

    static func chromiumOverrideState(for commandID: Int) -> ShortcutOverride? {
        if let command = CommandWrapper(rawValue: commandID), fixedShortcutCommands.contains(command) {
            return DefaultShortcuts[command].map(ShortcutOverride.custom)
        }
        if isShortcutDisabled(for: commandID) {
            return .disabled
        }
        return overrideState(for: commandID)
    }
    
    /// A missing override restores the default; `.disabled` explicitly clears it.
    @discardableResult
    static func setOverride(
        _ state: ShortcutOverride?, for command: CommandWrapper,
        updating conflicts: [Int: ShortcutOverride] = [:]
    ) -> Result<Void, Error> {
        guard !fixedShortcutCommands.contains(command) else { return .success(()) }
        var override = state
        if case .custom(let key) = state, key == DefaultShortcuts[command] {
            override = nil
        }
        return changeConfiguration {
            try $0.set(override, for: command.rawValue, updating: conflicts, at: customShortcutsFileURL)
        }
    }
    
    @discardableResult
    static func reloadOverrides() -> Result<Void, Error> {
        changeConfiguration {
            try $0.reload(from: customShortcutsFileURL)
        }
    }
    
    @discardableResult
    static func restoreOverrides() -> Result<Void, Error> {
        changeConfiguration {
            try $0.restoreDefaults(at: customShortcutsFileURL)
        }
    }

    private static func changeConfiguration(
        _ change: (inout ShortcutConfiguration) throws -> Void
    ) -> Result<Void, Error> {
        let previous = configuration.overrides
        let result: Result<Void, Error>
        do {
            try change(&configuration)
            result = .success(())
        } catch {
            AppLogError("[Shortcuts] Configuration change failed: \(error)")
            result = .failure(error)
        }
        if configuration.overrides != previous {
            CommandDispatcher.reloadPhiShortcutMap()
            ChromiumLauncher.sharedInstance().bridge?.requestRebuildMainMenu()
        }
        NotificationCenter.default.post(name: .shortcutsDidChange, object: nil)
        return result
    }
    
    static func isOverridden(_ command: CommandWrapper) -> Bool {
        overrideState(for: command.rawValue) != nil
    }

    static var configurableCommands: [CommandWrapper] {
        Array(Set(Group.allCases.flatMap(\.commands)))
            .filter { !disabledShortcutCommands.contains($0) }
            .sorted { $0.rawValue < $1.rawValue }
    }

    static func bindingInventory(additionalBindings: [ShortcutBinding]) -> ShortcutInventory {
        let commands = Set(configurableCommands)
            .union(fixedShortcutCommands)
            .union(configuration.overrides.keys.compactMap(CommandWrapper.init(rawValue:)))
        let configured = commands.compactMap { command -> ShortcutBinding? in
            guard let key = key(for: command) else { return nil }
            return ShortcutBinding(commandID: command.rawValue, key: key,
                                   scope: command.shortcutScope, source: .configured)
        }
        // Retain native/system owners, but never reserve keys for a product-
        // disabled command, including stale menu or Framework snapshots.
        // Avoid nested filter/map closures here: Swift 6.3's optimized
        // compilation can fail SIL ownership verification for the owner enum.
        var activeAdditional: [ShortcutBinding] = []
        for binding in additionalBindings {
            if let commandID = binding.commandID, isShortcutDisabled(for: commandID) {
                continue
            }
            activeAdditional.append(binding)
        }
        return ShortcutInventory(bindings: configured + activeAdditional)
    }

    /// Available menu actions can be configured before their first binding.
    /// Hidden menu branches are excluded because Phi replaces or suppresses them.
    static func availableMenuCommands(in menu: NSMenu? = NSApp.mainMenu) -> [CommandWrapper] {
        guard let menu else { return [] }
        return menu.items.filter { !$0.isHidden }.flatMap { item -> [CommandWrapper] in
            if let submenu = item.submenu { return availableMenuCommands(in: submenu) }
            guard item.action != nil, let command = CommandWrapper(rawValue: item.tag) else { return [] }
            return [command]
        }
    }

    static func menuBindings(
        in menu: NSMenu? = NSApp.mainMenu,
        servicesMenu: NSMenu? = NSApp.servicesMenu
    ) -> [ShortcutBinding] {
        func visit(_ menu: NSMenu, inServices: Bool = false) -> [ShortcutBinding] {
            let inServices = inServices || menu === servicesMenu
            return menu.items.flatMap { item -> [ShortcutBinding] in
                if ShortcutMenuPresentation.isMatchingAlias(item) { return [] }
                // Chromium's menu matcher examines hidden entries too.
                if let submenu = item.submenu { return visit(submenu, inServices: inServices) }
                // AppKit retains unavailable Services in the menu tree. Their
                // detached copies can expose keys despite being hidden and disabled.
                if inServices && item.isHidden && !item.isEnabled { return [] }
                // AppKit can report an empty key for a live menu item when
                // another item claims the same equivalent (for example, Undo
                // after assigning Cmd-Z to Settings). A detached copy retains
                // the declared binding, including explicit empty overrides.
                // Keep it in the inventory so suppression cannot hide conflicts.
                let keyItem = item.keyEquivalent.isEmpty && item.view == nil
                    ? (item.copy() as? NSMenuItem ?? item) : item
                guard !keyItem.keyEquivalent.isEmpty,
                      let action = item.action else { return [] }
                let command = CommandWrapper(rawValue: item.tag)
                let owner: ShortcutBinding.Owner
                if command != nil || (action == NSSelectorFromString("commandDispatch:") && item.tag > 0) {
                    owner = .command(item.tag)
                } else {
                    owner = .nativeAction(NSStringFromSelector(action))
                }
                let equivalent = ShortcutMenuPresentation.originalKey(for: item)
                    ?? ShortcutsKey.MenuKeyEquivalent(characters: keyItem.keyEquivalent,
                                                      modifiers: keyItem.keyEquivalentModifierMask)
                // Older Frameworks switch the default Cmd-W row to Close Window
                // without stable identifiers (AppKit falls back to the action
                // name). Its non-browser role is still recognizable. Explicit
                // close-key assignments keep their scope and real conflicts.
                let isLegacyDefaultCloseAlias = (item.identifier == nil
                    || item.identifier?.rawValue == "performClose:")
                    && action == NSSelectorFromString("performClose:")
                    && Self.key(for: .IDC_CLOSE_TAB) == DefaultShortcuts[.IDC_CLOSE_TAB]
                    && Self.key(for: .IDC_CLOSE_WINDOW) == DefaultShortcuts[.IDC_CLOSE_WINDOW]
                    && equivalent == DefaultShortcuts[.IDC_CLOSE_TAB]?.menuKeyEquivalent
                let scope: ShortcutBinding.Scope
                if command == .IDC_CLOSE_WINDOW,
                   item.identifier?.rawValue == "phi.closeTab" || isLegacyDefaultCloseAlias {
                    // Chromium temporarily makes the stable Close Tab row the
                    // non-browser window's default Close Window action. Keep
                    // its actual owner, but do not invent a browser conflict.
                    scope = .nonBrowser
                } else {
                    scope = command?.shortcutScope ?? .all
                }
                let key = ShortcutsKey(menuKeyEquivalent: equivalent.characters,
                                       modifiers: equivalent.modifiers)
                return [ShortcutBinding(
                    owner: owner,
                    key: key,
                    scope: scope, source: .menu,
                    title: item.title
                )]
            }
        }
        return menu.map { visit($0) } ?? []
    }

    static func additionalBindings() -> [ShortcutBinding] {
        let menu = menuBindings()
        let browser = chromiumBindings()
        let additional = menu + browser
        let effective = bindingInventory(additionalBindings: additional)
        return additional + SystemShortcutBindings.current(conflictingWith: effective.bindings)
    }

    private static func chromiumBindings() -> [ShortcutBinding] {
        guard let bridge = ChromiumLauncher.sharedInstance().bridge,
              bridge.responds(to: NSSelectorFromString("shortcutBindings")) else { return [] }
        return bridge.shortcutBindings().compactMap { record in
            guard let commandID = record["commandId"] as? Int,
                  let characters = record["keyEquivalent"] as? String, !characters.isEmpty,
                  let modifiers = record["modifierFlags"] as? UInt,
                  let source = record["source"] as? String,
                  source == "hidden" || source == "webContents" else { return nil }
            return ShortcutBinding(commandID: commandID,
                                   key: ShortcutsKey(menuKeyEquivalent: characters,
                                                     modifiers: .init(rawValue: modifiers)),
                                   scope: CommandWrapper(rawValue: commandID)?.shortcutScope ?? .browser,
                                   source: source == "hidden" ? .hidden : .webContents)
        }
    }
    
    // MARK: - Persistence
    private static var customShortcutsFileURL: URL {
        if let account = AccountController.shared.account {
            let path = account.userDataStorage.path
            let url = URL(fileURLWithPath: path)
            return url.appendingPathComponent("CustomShortcuts.json")
        } else {
            let path = FileSystemUtils.phiBrowserDataDirectory()
            let url = URL(fileURLWithPath: path)
            return url.appendingPathComponent("CustomShortcuts.json")
        }
    }
    
}
extension ShortcutsKey {
    private var displayModifiers: NSEvent.ModifierFlags {
        // Menu equivalents encode Shift in uppercase letters instead of flags.
        characters != characters.lowercased() ? modifiers.union(.shift) : modifiers
    }

    var displayString: String {
        keycapTokens.joined()
    }

    var keycapTokens: [String] {
        let key = displayKey
        let modifiers = key.displayModifiers
        var tokens: [String] = []
        if modifiers.contains(.function) { tokens.append("fn") }
        if modifiers.contains(.control) { tokens.append("⌃") }
        if modifiers.contains(.option) { tokens.append("⌥") }
        if modifiers.contains(.shift) { tokens.append("⇧") }
        if modifiers.contains(.command) { tokens.append("⌘") }
        tokens.append(key.characterSymbol)
        return tokens
    }

    private var characterSymbol: String {
        if let scalar = characters.unicodeScalars.first, characters.unicodeScalars.count == 1,
           (0xF704...0xF726).contains(scalar.value) {
            return "F\(scalar.value - 0xF704 + 1)"
        }
        switch characters {
        case String(format: "%c", NSBackspaceCharacter):
            return "⌫"
        case "\t":
            return "⇥"
        case "\r":
            return "↩︎"
        case "\u{3}":
            return "⌤"
        case "\u{1B}":
            return "⎋"
        case "\u{F700}":
            return "↑"
        case "\u{F701}":
            return "↓"
        case "\u{F702}":
            return "←"
        case "\u{F703}":
            return "→"
        case "\u{7F}", "\u{F728}":
            return "⌦"
        case "\u{F729}":
            return "↖"
        case "\u{F72B}":
            return "↘"
        case "\u{F72C}":
            return "⇞"
        case "\u{F72D}":
            return "⇟"
        case " ":
            return "␣"
        default:
            return characters.uppercased()
        }
    }
}

extension CommandWrapper {
    /// Standard macOS menu services reserve keys without appearing in settings.
    var isSystemShortcut: Bool {
        switch self {
        case .IDC_EXIT, .IDC_HIDE_APP, .IDC_MINIMIZE_WINDOW,
             .IDC_CONTENT_CONTEXT_UNDO, .IDC_CONTENT_CONTEXT_REDO,
             .IDC_CONTENT_CONTEXT_CUT, .IDC_CONTENT_CONTEXT_COPY,
             .IDC_CONTENT_CONTEXT_PASTE, .IDC_CONTENT_CONTEXT_PASTE_AND_MATCH_STYLE,
             .IDC_CONTENT_CONTEXT_SELECTALL,
             .IDS_HIDE_OTHERS_MAC, .IDS_CLOSE_ALL_WINDOWS_MAC,
             .IDS_PASTE_MATCH_STYLE_MAC, .IDS_EDIT_SHOW_SPELLING_GRAMMAR_MAC,
             .IDS_EDIT_CHECK_DOCUMENT_MAC:
            return true
        default:
            return false
        }
    }

    var shortcutScope: ShortcutBinding.Scope {
        if Shortcuts.Group.kiosk.commands.contains(self) { return .kiosk }
        if self == .IDC_CLOSE_TAB { return [.browser, .kiosk] }
        return isUnavailableInKiosk ? .browser : .all
    }

    /// Commands without an action in a Kiosk window. Shared by dispatch and
    /// shortcut conflict detection so inactive commands do not reserve keys.
    var isUnavailableInKiosk: Bool {
        if spaceSelectionIndex != nil { return true }
        switch self {
        case .IDC_OPEN_FILE, .IDC_SHOW_BOOKMARK_BAR, .PHI_TOGGLE_SIDEBAR,
             .PHI_FARRINGDON_TOGGLE, .PHI_SPLIT_WITH_NEW_TAB,
             .IDC_TAB_SEARCH, .IDC_DUPLICATE_TAB, .IDC_WINDOW_PIN_TAB,
             .IDC_DEV_TOOLS, .IDC_DEV_TOOLS_INSPECT, .IDC_DEV_TOOLS_CONSOLE,
             .PHI_TOGGLE_CHATBAR, .PHI_NEW_CONVERSATION,
             .IDC_SELECT_PREVIOUS_TAB, .IDC_SELECT_NEXT_TAB,
             .IDC_CYCLE_TO_NEXT_TAB, .IDC_CYCLE_TO_PREV_TAB,
             .IDC_SELECT_LAST_TAB, .PHI_TAB_SWITCHER_FORWARD,
             .PHI_TAB_SWITCHER_BACKWARD, .PHI_SELECT_NEXT_SPACE,
             .PHI_SELECT_PREVIOUS_SPACE,
             .IDC_SELECT_TAB_0, .IDC_SELECT_TAB_1, .IDC_SELECT_TAB_2,
             .IDC_SELECT_TAB_3, .IDC_SELECT_TAB_4, .IDC_SELECT_TAB_5,
             .IDC_SELECT_TAB_6, .IDC_SELECT_TAB_7:
            return true
        default:
            return false
        }
    }

    struct Presentation {
        let title: String
        let keywords: [String]
    }
    
    private static let presentationOverrides: [CommandWrapper: Presentation] = [
        .IDC_OPTIONS: .init(title: "Settings", keywords: ["preferences", "options", "config"]),
        .IDC_HIDE_APP: .init(title: "Hide Phi", keywords: ["hide", "application"]),
        .IDC_EXIT: .init(title: "Quit Phi", keywords: ["quit", "exit"]),
        .IDC_CLEAR_BROWSING_DATA: .init(title: "Clear Browsing Data", keywords: ["clear data", "privacy"]),
        .IDC_NEW_TAB: .init(title: "New Tab", keywords: ["tab", "open tab"]),
        .IDC_NEW_WINDOW: .init(title: "New Window", keywords: ["window"]),
        .IDC_NEW_INCOGNITO_WINDOW: .init(title: "New Incognito Window", keywords: ["incognito", "private"]),
        .IDC_RESTORE_TAB: .init(title: "Reopen Closed Tab", keywords: ["restore", "closed tab"]),
        .IDC_OPEN_FILE: .init(title: "Open File…", keywords: ["file", "open"]),
        .IDC_FOCUS_LOCATION: .init(title: "Focus Address Bar", keywords: ["omnibox", "address", "url"]),
        .IDC_CLOSE_WINDOW: .init(title: "Close Window", keywords: ["close window"]),
        .IDC_CLOSE_TAB: .init(title: "Close Tab", keywords: ["close tab"]),
        .IDC_SAVE_PAGE: .init(title: "Save Page", keywords: ["save", "download"]),
        .IDC_PRINT: .init(title: "Print…", keywords: ["print"]),
        .IDC_SHOW_BOOKMARK_BAR: .init(title: "Toggle Bookmark Bar", keywords: ["bookmark bar"]),
        .IDC_RELOAD: .init(title: "Reload Page", keywords: ["refresh", "reload"]),
        .IDC_FULLSCREEN: .init(title: "Full Screen", keywords: ["fullscreen"]),
        .IDC_VIEW_SOURCE: .init(title: "View Page Source", keywords: ["source"]),
        .IDC_DEV_TOOLS: .init(title: "Open DevTools", keywords: ["inspect", "developer"]),
        .IDC_HOME: .init(title: "Home", keywords: ["home", "start"]),
        .IDC_BACK: .init(title: "Back", keywords: ["history back"]),
        .IDC_FORWARD: .init(title: "Forward", keywords: ["history forward"]),
        .IDC_SHOW_HISTORY: .init(title: "Show History", keywords: ["history"]),
        .IDC_SHOW_BOOKMARK_MANAGER: .init(title: "Bookmark Manager", keywords: ["bookmarks"]),
        .IDC_BOOKMARK_THIS_TAB: .init(title: "Bookmark Tab", keywords: ["bookmark"]),
        .IDC_BOOKMARK_ALL_TABS: .init(title: "Bookmark All Tabs", keywords: ["bookmark all"]),
        .IDC_SHOW_DOWNLOADS: .init(title: "Downloads", keywords: ["downloads"]),
        .IDC_TAB_SEARCH: .init(title: "Tab Search", keywords: ["search tabs"]),
        .IDC_FEEDBACK: .init(title: "Send Feedback", keywords: ["feedback", "support"]),
        .IDC_HELP_PAGE_VIA_MENU: .init(title: "Phi Help", keywords: ["help", "docs"]),
        .IDC_MANAGE_EXTENSIONS: .init(title: "Extensions", keywords: ["extensions"]),
        .IDC_WINDOW_PIN_TAB: .init(title: "Pin Tab", keywords: ["pintab"]),
        .IDC_WINDOW_GROUP_TAB: .init(title: "Group Tab", keywords: ["grouptab"]),
        .IDC_WINDOW_CLOSE_OTHER_TABS: .init(title: "Close Other Tabs", keywords: ["closeothertabs"]),
        .IDC_WINDOW_MUTE_SITE: .init(title: "Mute Site", keywords: ["mutesite"]),
        .IDC_WINDOW_CLOSE_TABS_TO_RIGHT: .init(title: "Close Tabs to the Right", keywords: ["closetabstotheright"]),
        .IDC_MOVE_TAB_TO_NEW_WINDOW: .init(title: "Move Tab to New Window", keywords: ["movetabtonewwindow"]),
        .PHI_TOGGLE_SIDEBAR: .init(title: "Toggle Sidebar", keywords: ["togglesidebar"]),
        .PHI_TOGGLE_CHATBAR: .init(title: "Toggle Chatbar", keywords: ["togglechatbar","ai"]),
        .PHI_TAB_SWITCHER_FORWARD: .init(title: "Show Tab Switcher", keywords: ["tab switcher", "forward"]),
        .PHI_TAB_SWITCHER_BACKWARD: .init(title: "Show Tab Switcher(Reverse)", keywords: ["tab switcher", "backward"]),
        .PHI_NEW_CONVERSATION: .init(title: "New Conversation", keywords: ["new conversation", "new chat", "ai", "chat"]),
        .PHI_FARRINGDON_TOGGLE: .init(title: "Organize Tabs with AI", keywords: ["organize tabs", "tidy tabs", "group tabs", "clean", "farringdon", "ai"]),
        .PHI_COPY_URL: .init(title: "Copy URL", keywords: ["copy url", "copy link", "url"]),
        .PHI_TOGGLE_READER: .init(title: "Toggle Reader View", keywords: ["reader", "reader view", "reading", "article", "distraction free"]),
        .PHI_NEW_KIOSK_WINDOW: .init(title: "New Kiosk Window", keywords: ["new kiosk window", "kiosk", "window"]),
        .PHI_NEW_INCOGNITO_SPACE: .init(title: "New Incognito Space", keywords: ["new incognito space", "incognito", "private", "space"]),
        .PHI_SHARE_PAGE: .init(title: "Share Page", keywords: ["share", "share page", "share link", "airdrop", "send"]),
        .PHI_CAPTURE_FULL_PAGE: .init(title: "Capture Full Page", keywords: ["screenshot", "capture", "full page", "image"]),
        .PHI_CAPTURE_AREA: .init(title: "Capture Area", keywords: ["screenshot", "capture", "area", "region", "image"]),
        .PHI_KIOSK_OPEN_IN_SPACE: .init(title: "Open Kiosk or Peek in current Space", keywords: ["kiosk", "peek", "open as tab", "open in space", "current space", "move"]),
        .PHI_KIOSK_CHOOSE_SPACE: .init(title: "Show Kiosk \"Open in\" Menu", keywords: ["kiosk", "choose space", "open in", "menu"]),
        .PHI_SAVE_FOR_LATER: .init(title: "Save to Folio", keywords: ["save", "save to folio", "folio", "read later", "markdown", "archive"]),
        .PHI_SPLIT_WITH_NEW_TAB: .init(title: "Split with New Tab", keywords: ["split", "split view", "new tab", "pane"]),
        .PHI_SELECT_NEXT_SPACE: .init(title: "Next Space", keywords: ["space", "next space", "forward"]),
        .PHI_SELECT_PREVIOUS_SPACE: .init(title: "Previous Space", keywords: ["space", "previous space", "backward"]),
        .PHI_SELECT_SPACE_0: .init(title: "Go to Space 1", keywords: ["space", "space1"]),
        .PHI_SELECT_SPACE_1: .init(title: "Go to Space 2", keywords: ["space", "space2"]),
        .PHI_SELECT_SPACE_2: .init(title: "Go to Space 3", keywords: ["space", "space3"]),
        .PHI_SELECT_SPACE_3: .init(title: "Go to Space 4", keywords: ["space", "space4"]),
        .PHI_SELECT_SPACE_4: .init(title: "Go to Space 5", keywords: ["space", "space5"]),
        .PHI_SELECT_SPACE_5: .init(title: "Go to Space 6", keywords: ["space", "space6"]),
        .PHI_SELECT_SPACE_6: .init(title: "Go to Space 7", keywords: ["space", "space7"]),
        .PHI_SELECT_SPACE_7: .init(title: "Go to Space 8", keywords: ["space", "space8"]),
        .PHI_SELECT_SPACE_8: .init(title: "Go to Space 9", keywords: ["space", "space9"]),
        
        .IDS_HIDE_OTHERS_MAC: .init(title: "Hide Others", keywords: []),
        .IDS_CLOSE_ALL_WINDOWS_MAC: .init(title: "Close All", keywords: []),
        .IDS_PASTE_MATCH_STYLE_MAC: .init(title: "Paste and Match Style", keywords: []),
        .IDS_EDIT_USE_SELECTION_MAC: .init(title: "Use Selection for Find", keywords: []),
        .IDC_FOCUS_SEARCH: .init(title: "Search the Web...", keywords: ["search the web"]),
        .IDS_EDIT_JUMP_TO_SELECTION_MAC: .init(title: "Jump to Selection", keywords: []),
        .IDS_EDIT_SHOW_SPELLING_GRAMMAR_MAC: .init(title: "Show Spelling and Grammar", keywords: []),
        .IDS_EDIT_CHECK_DOCUMENT_MAC: .init(title: "Check Document Now", keywords: []),
        
        
        .IDC_SELECT_TAB_0: .init(title: "Select Tab 1", keywords: ["select", "tab1", "first tab"]),
        .IDC_SELECT_TAB_1: .init(title: "Select Tab 2", keywords: ["select", "tab2"]),
        .IDC_SELECT_TAB_2: .init(title: "Select Tab 3", keywords: ["select", "tab3"]),
        .IDC_SELECT_TAB_3: .init(title: "Select Tab 4", keywords: ["select", "tab4"]),
        .IDC_SELECT_TAB_4: .init(title: "Select Tab 5", keywords: ["select", "tab5"]),
        .IDC_SELECT_TAB_5: .init(title: "Select Tab 6", keywords: ["select", "tab6"]),
        .IDC_SELECT_TAB_6: .init(title: "Select Tab 7", keywords: ["select", "tab7"]),
        .IDC_SELECT_TAB_7: .init(title: "Select Tab 8", keywords: ["select", "tab8"]),
        
        .IDC_CONTENT_CONTEXT_UNDO: .init(title: "Undo", keywords: ["undo"]),
        .IDC_CONTENT_CONTEXT_REDO: .init(title: "Redo", keywords: ["redo"]),
        .IDC_CONTENT_CONTEXT_CUT: .init(title: "Cut", keywords: ["cut"]),
        .IDC_CONTENT_CONTEXT_COPY: .init(title: "Copy", keywords: ["copy"]),
        .IDC_CONTENT_CONTEXT_PASTE: .init(title: "Paste", keywords: ["paste"]),
        .IDC_CONTENT_CONTEXT_PASTE_AND_MATCH_STYLE: .init(title: "Paste and Match Style", keywords: ["paste", "match style"]),
        .IDC_CONTENT_CONTEXT_SELECTALL: .init(title: "Select All", keywords: ["select all"]),
    ]
    
    var displayName: String {
        if let override = CommandWrapper.presentationOverrides[self]?.title {
            return override
        }
        return CommandWrapper.buildTitle(from: caseName)
    }
    
    var searchKeywords: [String] {
        var keywords = CommandWrapper.presentationOverrides[self]?.keywords ?? []
        keywords.append(displayName.lowercased())
        keywords.append(contentsOf: caseKeywords)
        return Array(Set(keywords.map { $0.lowercased() }))
    }
    
    private var caseName: String {
        String(describing: self)
    }
    
    private var caseKeywords: [String] {
        caseName
            .replacingOccurrences(of: "IDC_", with: "")
            .split(separator: "_")
            .map { String($0).lowercased() }
    }
    
    private static func buildTitle(from raw: String) -> String {
        raw.replacingOccurrences(of: "IDC_", with: "")
            .split(separator: "_")
            .map { word in
                let lower = word.lowercased()
                if lower == "idc" { return "" }
                return lower.capitalized
            }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    static let spaceSelectionCommands: [CommandWrapper] = [
        .PHI_SELECT_SPACE_0,
        .PHI_SELECT_SPACE_1,
        .PHI_SELECT_SPACE_2,
        .PHI_SELECT_SPACE_3,
        .PHI_SELECT_SPACE_4,
        .PHI_SELECT_SPACE_5,
        .PHI_SELECT_SPACE_6,
        .PHI_SELECT_SPACE_7,
        .PHI_SELECT_SPACE_8,
    ]

    static func spaceSelectionCommand(at index: Int) -> CommandWrapper? {
        guard spaceSelectionCommands.indices.contains(index) else { return nil }
        return spaceSelectionCommands[index]
    }

    var spaceSelectionIndex: Int? {
        CommandWrapper.spaceSelectionCommands.firstIndex(of: self)
    }
}

extension Shortcuts {
    static func updateShortcut(for item: NSMenuItem) {
        let effectiveKey: ShortcutsKey?
        if isShortcutDisabled(for: item.tag) {
            effectiveKey = nil
        } else if let override = overrideState(for: item.tag), !override.inheritsDefaults {
            effectiveKey = override.key
        } else {
            guard let command = CommandWrapper(rawValue: item.tag),
                  let defaultKey = DefaultShortcuts[command] else {
                // Preserve menu items that do not participate in shortcut settings.
                return
            }
            effectiveKey = overrideState(for: item.tag)?.excludes(defaultKey) == true ? nil : defaultKey
        }

        if let key = effectiveKey {
            let menuKey = key.menuKeyEquivalent
            item.keyEquivalent = menuKey.characters
            item.keyEquivalentModifierMask = menuKey.modifiers
        } else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = .init(rawValue: 0)
        }
    }
}

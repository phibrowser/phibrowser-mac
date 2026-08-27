// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import Combine
class ShortcutsViewModel: ObservableObject {
    @Published var sections: [(category: String, items: [ShortcutItem])] = []
    @Published var editingCommand: CommandWrapper?
    @Published var hiddenGroups: Set<Shortcuts.Group> = [.help, .bookmarks]
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        SpaceManager.shared.$spaces
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuildSections()
            }
            .store(in: &cancellables)
        rebuildSections()
    }
    
    func rebuildSections() {
        var newSections: [(category: String, items: [ShortcutItem])] = []
        
        Shortcuts.Group.allCases
            .filter { !hiddenGroups.contains($0) }
            .forEach { group in
                let items = group.commands.compactMap { command -> ShortcutItem? in
                    guard shouldShow(command) else { return nil }
                    let key = Shortcuts.key(for: command)
                    let conflictingCommands = findConflictingCommands(for: command, currentKey: key)
                    
                    return ShortcutItem(
                        id: command,
                        command: command,
                        name: displayName(for: command),
                        shortcutKey: key,
                        shortcutDisplay: shortcutDisplay(for: command, key: key),
                        isOverridden: Shortcuts.isOverridden(command),
                        conflictingCommandNames: conflictingCommands.map { displayName(for: $0) },
                        searchKeywords: searchKeywords(for: command)
                    )
                }
                
                if !items.isEmpty {
                    newSections.append((category: group.title, items: items))
                }
            }
        
        sections = newSections
    }

    private func shortcutDisplay(
        for command: CommandWrapper,
        key: ShortcutsKey?
    ) -> String {
        guard let key else {
            return NSLocalizedString(
                "settings.shortcuts.unassignedPlaceholder",
                value: "Add New",
                comment: "Shortcuts settings - Placeholder text when no shortcut is assigned"
            )
        }

        // AppKit reports the shifted characters for these default events, so
        // execution stores "{" and "}". Keep the settings label in the
        // familiar physical-key notation without changing global key identity.
        guard key == Shortcuts.DefaultShortcuts[command] else {
            return key.displayString
        }
        switch command {
        case .IDC_SELECT_PREVIOUS_TAB:
            return ShortcutsKey(
                characters: "[",
                modifiers: key.modifiers
            ).displayString
        case .IDC_SELECT_NEXT_TAB:
            return ShortcutsKey(
                characters: "]",
                modifiers: key.modifiers
            ).displayString
        default:
            return key.displayString
        }
    }
    
    private func findConflictingCommands(for command: CommandWrapper, currentKey: ShortcutsKey?) -> [CommandWrapper] {
        guard let currentKey = currentKey else { return [] }
        
        var conflicts: [CommandWrapper] = []
        
        Shortcuts.DefaultShortcuts.keys.forEach { otherCommand in
            guard otherCommand != command else { return }
            guard shouldShow(otherCommand) else { return }
            if let otherKey = Shortcuts.key(for: otherCommand),
               otherKey.menuKeyEquivalent == currentKey.menuKeyEquivalent {
                conflicts.append(otherCommand)
            }
        }
        return conflicts
    }

    private func shouldShow(_ command: CommandWrapper) -> Bool {
        guard let index = command.spaceSelectionIndex else {
            return true
        }
        return index < SpaceManager.shared.spaces.count
    }

    private func displayName(for command: CommandWrapper) -> String {
        if let index = command.spaceSelectionIndex {
            let spaces = SpaceManager.shared.spaces
            if spaces.indices.contains(index) {
                return String(
                    format: NSLocalizedString("settings.shortcuts.activateSpaceCommandTitle", value: "Go to Space \"%@\"", comment: "Shortcuts settings - Command title to activate the Space at this position"),
                    spaces[index].name
                )
            }
        }
        return command.localizedShortcutTitle
    }

    private func searchKeywords(for command: CommandWrapper) -> [String] {
        var keywords = command.searchKeywords
        keywords.append(displayName(for: command))
        if let index = command.spaceSelectionIndex {
            let spaces = SpaceManager.shared.spaces
            if spaces.indices.contains(index) {
                keywords.append(spaces[index].name)
                keywords.append("space \(index + 1)")
            }
        }
        return Array(Set(keywords.map { $0.lowercased() }))
    }
    
    func setCustomShortcut(for command: CommandWrapper, key: ShortcutsKey) {
        Shortcuts.override(key, for: command)
        rebuildSections()
    }
    
    /// Disables the shortcut by storing an explicit empty override.
    func disableShortcut(for command: CommandWrapper) {
        Shortcuts.override(nil, for: command, remove: false)
        rebuildSections()
    }
    
    /// Restores the default shortcut for the command.
    func restoreDefaultShortcut(for command: CommandWrapper) {
        Shortcuts.override(nil, for: command, remove: true)
        rebuildSections()
    }
    
    func restoreAllShortcuts() {
        Shortcuts.restoreOverrides()
        rebuildSections()
    }
}

private extension CommandWrapper {
    var localizedShortcutTitle: String {
        switch self {
        case .IDC_OPTIONS:
            return NSLocalizedString("settings.shortcuts.command.openSettings", value: "Settings", comment: "Shortcuts settings - Command title for opening Phi settings")
        case .IDC_NEW_TAB:
            return NSLocalizedString("settings.shortcuts.command.newTab", value: "New Tab", comment: "Shortcuts settings - Command title for opening a new tab")
        case .IDC_NEW_WINDOW:
            return NSLocalizedString("settings.shortcuts.command.newWindow", value: "New Window", comment: "Shortcuts settings - Command title for opening a new window")
        case .IDC_NEW_INCOGNITO_WINDOW:
            return NSLocalizedString("settings.shortcuts.command.newIncognitoWindow", value: "New Incognito Window", comment: "Shortcuts settings - Command title for opening a new Incognito window")
        case .PHI_NEW_KIOSK_WINDOW:
            return NSLocalizedString("settings.shortcuts.command.newKioskWindow", value: "New Kiosk Window", comment: "Shortcuts settings - Command title for opening a new Kiosk window")
        case .IDC_RESTORE_TAB:
            return NSLocalizedString("settings.shortcuts.command.reopenClosedTab", value: "Reopen Closed Tab", comment: "Shortcuts settings - Command title for reopening the most recently closed tab")
        case .IDC_FOCUS_LOCATION:
            return NSLocalizedString("settings.shortcuts.command.focusAddressBar", value: "Focus Address Bar", comment: "Shortcuts settings - Command title for moving keyboard focus to the address bar")
        case .IDC_CLOSE_WINDOW:
            return NSLocalizedString("settings.shortcuts.command.closeWindow", value: "Close Window", comment: "Shortcuts settings - Command title for closing the current window")
        case .IDC_CLOSE_TAB:
            return NSLocalizedString("settings.shortcuts.command.closeTab", value: "Close Tab", comment: "Shortcuts settings - Command title for closing the current tab")
        case .IDC_PRINT:
            return NSLocalizedString("settings.shortcuts.command.printPage", value: "Print…", comment: "Shortcuts settings - Command title for printing the current page")
        case .PHI_COPY_URL:
            return NSLocalizedString("settings.shortcuts.command.copyURL", value: "Copy URL", comment: "Shortcuts settings - Command title for copying the current URL")
        case .PHI_TOGGLE_READER:
            return NSLocalizedString("settings.shortcuts.command.toggleReaderView", value: "Toggle Reader View", comment: "Shortcuts settings - Command title for switching the current page between Reader View and the normal page")
        case .IDC_FIND:
            return NSLocalizedString("settings.shortcuts.command.findOnPage", value: "Find", comment: "Shortcuts settings - Command title for finding text on the current page")
        case .IDC_FIND_NEXT:
            return NSLocalizedString("settings.shortcuts.command.findNextMatch", value: "Find Next", comment: "Shortcuts settings - Command title for selecting the next match on the current page")
        case .IDC_FIND_PREVIOUS:
            return NSLocalizedString("settings.shortcuts.command.findPreviousMatch", value: "Find Previous", comment: "Shortcuts settings - Command title for selecting the previous match on the current page")
        case .IDC_FOCUS_SEARCH:
            return NSLocalizedString("settings.shortcuts.command.searchTheWeb", value: "Search the Web...", comment: "Shortcuts settings - Command title for starting a web search")
        case .IDC_STOP:
            return NSLocalizedString("settings.shortcuts.command.stopLoading", value: "Stop", comment: "Shortcuts settings - Command title for stopping the current page from loading")
        case .IDC_RELOAD:
            return NSLocalizedString("settings.shortcuts.command.reloadPage", value: "Reload Page", comment: "Shortcuts settings - Command title for reloading the current page")
        case .IDC_ZOOM_NORMAL:
            return NSLocalizedString("settings.shortcuts.command.resetZoom", value: "Zoom Normal", comment: "Shortcuts settings - Command title for restoring the default page zoom level")
        case .IDC_ZOOM_PLUS:
            return NSLocalizedString("settings.shortcuts.command.zoomIn", value: "Zoom Plus", comment: "Shortcuts settings - Command title for increasing the page zoom level")
        case .IDC_ZOOM_MINUS:
            return NSLocalizedString("settings.shortcuts.command.zoomOut", value: "Zoom Minus", comment: "Shortcuts settings - Command title for decreasing the page zoom level")
        case .IDC_VIEW_SOURCE:
            return NSLocalizedString("settings.shortcuts.command.viewPageSource", value: "View Page Source", comment: "Shortcuts settings - Command title for viewing the current page source")
        case .IDC_DEV_TOOLS:
            return NSLocalizedString("settings.shortcuts.command.openDeveloperTools", value: "Open DevTools", comment: "Shortcuts settings - Command title for opening developer tools")
        case .IDC_DEV_TOOLS_INSPECT:
            return NSLocalizedString("settings.shortcuts.command.inspectWithDeveloperTools", value: "Dev Tools Inspect", comment: "Shortcuts settings - Command title for inspecting the page with developer tools")
        case .IDC_DEV_TOOLS_CONSOLE:
            return NSLocalizedString("settings.shortcuts.command.openDeveloperConsole", value: "Dev Tools Console", comment: "Shortcuts settings - Command title for opening the developer tools console")
        case .PHI_TOGGLE_SIDEBAR:
            return NSLocalizedString("settings.shortcuts.command.toggleSidebar", value: "Toggle Sidebar", comment: "Shortcuts settings - Command title for showing or hiding the sidebar")
        case .PHI_TOGGLE_CHATBAR:
            return NSLocalizedString("settings.shortcuts.command.toggleChatbar", value: "Toggle Chatbar", comment: "Shortcuts settings - Command title for showing or hiding the Chatbar")
        case .PHI_NEW_CONVERSATION:
            return NSLocalizedString("settings.shortcuts.command.newConversation", value: "New Conversation", comment: "Shortcuts settings - Command title for starting a new conversation")
        case .IDC_HOME:
            return NSLocalizedString("settings.shortcuts.command.goHome", value: "Home", comment: "Shortcuts settings - Command title for opening the home page")
        case .IDC_BACK:
            return NSLocalizedString("settings.shortcuts.command.goBack", value: "Back", comment: "Shortcuts settings - Command title for navigating back")
        case .IDC_FORWARD:
            return NSLocalizedString("settings.shortcuts.command.goForward", value: "Forward", comment: "Shortcuts settings - Command title for navigating forward")
        case .IDC_SHOW_HISTORY:
            return NSLocalizedString("settings.shortcuts.command.showHistory", value: "Show History", comment: "Shortcuts settings - Command title for showing browsing history")
        case .IDC_MANAGE_EXTENSIONS:
            return NSLocalizedString("settings.shortcuts.command.manageExtensions", value: "Extensions", comment: "Shortcuts settings - Command title for managing browser extensions")
        case .IDC_SHOW_DOWNLOADS:
            return NSLocalizedString("settings.shortcuts.command.showDownloads", value: "Downloads", comment: "Shortcuts settings - Command title for showing downloads")
        case .PHI_TAB_SWITCHER_FORWARD:
            return NSLocalizedString("settings.shortcuts.command.showTabSwitcher", value: "Show Tab Switcher", comment: "Shortcuts settings - Command title for showing the tab switcher in forward order")
        case .PHI_TAB_SWITCHER_BACKWARD:
            return NSLocalizedString("settings.shortcuts.command.showTabSwitcherReverse", value: "Show Tab Switcher(Reverse)", comment: "Shortcuts settings - Command title for showing the tab switcher in reverse order")
        case .IDC_NEW_TAB_TO_RIGHT:
            return NSLocalizedString("settings.shortcuts.command.newTabToRight", value: "New Tab To Right", comment: "Shortcuts settings - Command title for opening a new tab to the right of the current tab")
        case .IDC_SELECT_NEXT_TAB:
            return NSLocalizedString("settings.shortcuts.command.selectNextTab", value: "Select Next Tab", comment: "Shortcuts settings - Command title for selecting the next tab")
        case .IDC_SELECT_PREVIOUS_TAB:
            return NSLocalizedString("settings.shortcuts.command.selectPreviousTab", value: "Select Previous Tab", comment: "Shortcuts settings - Command title for selecting the previous tab")
        case .IDC_SELECT_TAB_0:
            return Self.localizedTabSelectionTitle(number: 1)
        case .IDC_SELECT_TAB_1:
            return Self.localizedTabSelectionTitle(number: 2)
        case .IDC_SELECT_TAB_2:
            return Self.localizedTabSelectionTitle(number: 3)
        case .IDC_SELECT_TAB_3:
            return Self.localizedTabSelectionTitle(number: 4)
        case .IDC_SELECT_TAB_4:
            return Self.localizedTabSelectionTitle(number: 5)
        case .IDC_SELECT_TAB_5:
            return Self.localizedTabSelectionTitle(number: 6)
        case .IDC_SELECT_TAB_6:
            return Self.localizedTabSelectionTitle(number: 7)
        case .IDC_SELECT_TAB_7:
            return Self.localizedTabSelectionTitle(number: 8)
        case .IDC_SELECT_LAST_TAB:
            return NSLocalizedString("settings.shortcuts.command.selectLastTab", value: "Select Last Tab", comment: "Shortcuts settings - Command title for selecting the last tab")
        case .IDC_DUPLICATE_TAB:
            return NSLocalizedString("settings.shortcuts.command.duplicateTab", value: "Duplicate Tab", comment: "Shortcuts settings - Command title for duplicating the current tab")
        case .IDC_WINDOW_MUTE_SITE:
            return NSLocalizedString("settings.shortcuts.command.muteSite", value: "Mute Site", comment: "Shortcuts settings - Command title for muting audio from the current site")
        case .PHI_FARRINGDON_TOGGLE:
            return NSLocalizedString("settings.shortcuts.command.organizeTabsWithAI", value: "Organize Tabs with AI", comment: "Shortcuts settings - Command title for organizing tabs with AI")
        case .IDC_TAB_SEARCH:
            return NSLocalizedString("settings.shortcuts.command.searchTabs", value: "Tab Search", comment: "Shortcuts settings - Command title for searching open tabs")
        case .PHI_SELECT_NEXT_SPACE:
            return NSLocalizedString("settings.shortcuts.command.selectNextSpace", value: "Next Space", comment: "Shortcuts settings - Command title for selecting the next Space")
        case .PHI_SELECT_PREVIOUS_SPACE:
            return NSLocalizedString("settings.shortcuts.command.selectPreviousSpace", value: "Previous Space", comment: "Shortcuts settings - Command title for selecting the previous Space")
        default:
            return displayName
        }
    }

    private static func localizedTabSelectionTitle(number: Int) -> String {
        String(
            format: NSLocalizedString("settings.shortcuts.command.selectNumberedTab", value: "Select Tab %d", comment: "Shortcuts settings - Command title for selecting a numbered tab; %d is the tab position"),
            number
        )
    }
}

struct ShortcutItem: Identifiable {
    let id: CommandWrapper
    let command: CommandWrapper
    let name: String
    let shortcutKey: ShortcutsKey?
    let shortcutDisplay: String
    let isOverridden: Bool
    let conflictingCommandNames: [String]
    let searchKeywords: [String]
    
    var hasConflict: Bool {
        !conflictingCommandNames.isEmpty
    }
}

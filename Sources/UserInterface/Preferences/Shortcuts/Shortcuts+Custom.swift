// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import AppKit

extension ShortcutsKey: Codable {
    enum CodingKeys: String, CodingKey {
        case characters
        case modifiersRaw
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(characters, forKey: .characters)
        try container.encode(modifiersRaw, forKey: .modifiersRaw)
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let characters = try container.decode(String.self, forKey: .characters)
        let modifiersRaw = try container.decode(UInt.self, forKey: .modifiersRaw)
        self.init(characters: characters, modifiers: NSEvent.ModifierFlags(rawValue: modifiersRaw))
    }
}

extension Shortcuts {
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
        case help = "Help"
        
        var title: String { rawValue }
        
        var commands: [CommandWrapper] {
            switch self {
            case .app:
                return [.IDC_OPTIONS]
            case .file:
                return [.IDC_NEW_TAB,
                        .IDC_NEW_WINDOW,
                        .IDC_NEW_INCOGNITO_WINDOW,
                        .IDC_RESTORE_TAB,
                        .IDC_FOCUS_LOCATION,
                        .IDC_CLOSE_WINDOW,
                        .IDC_CLOSE_TAB,
                        .IDC_PRINT]
            case .edit:
                return [.IDC_FIND,
                        .IDC_FIND_NEXT,
                        .IDC_FIND_PREVIOUS,
                        .IDC_FOCUS_SEARCH]
            case .view:
                return [.IDC_STOP,
                        .IDC_RELOAD,
                        .IDC_ZOOM_NORMAL,
                        .IDC_ZOOM_PLUS,
                        .IDC_ZOOM_MINUS,
                        .IDC_VIEW_SOURCE,
                        .IDC_DEV_TOOLS,
                        .IDC_DEV_TOOLS_INSPECT,
                        .IDC_DEV_TOOLS_CONSOLE,
                        .PHI_TOGGLE_SIDEBAR,
                        .PHI_TOGGLE_CHATBAR]
            case .history:
                return [.IDC_HOME,
                        .IDC_BACK,
                        .IDC_FORWARD,
                        .IDC_SHOW_HISTORY]
//            case .bookmarks:
//                return [.IDC_SHOW_BOOKMARK_MANAGER,
//                        .IDC_BOOKMARK_THIS_TAB,
//                        .IDC_BOOKMARK_ALL_TABS]
            case .window:
                return [.IDC_MANAGE_EXTENSIONS,
                        .IDC_SHOW_DOWNLOADS]
            case .tab:
                return [.IDC_NEW_TAB_TO_RIGHT,
                        .IDC_SELECT_NEXT_TAB,
                        .IDC_SELECT_PREVIOUS_TAB,
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
//                        .IDC_WINDOW_PIN_TAB,
//                        .IDC_WINDOW_GROUP_TAB,
//                        .IDC_WINDOW_CLOSE_OTHER_TABS,
//                        .IDC_WINDOW_CLOSE_TABS_TO_RIGHT,
//                        .IDC_MOVE_TAB_TO_NEW_WINDOW,
                        .IDC_TAB_SEARCH]
//            case .help:
//                return [.IDC_FEEDBACK,
//                        .IDC_HELP_PAGE_VIA_MENU]
            default: return []
            }
        }
    }
    
    // `nil` means the user explicitly removed the shortcut.
    // Missing entries fall back to the default shortcut.
    static var overridedShortcuts: [CommandWrapper: ShortcutsKey?] = load()
    
    static func key(for command: CommandWrapper) -> ShortcutsKey? {
        // Check overrides first, including explicit `nil`.
        if let override = overridedShortcuts[command] {
            return override
        }
        // Fall back to the default shortcut.
        return DefaultShortcuts[command]
    }
    
    // Return semantics:
    // `.none` means no override.
    // `.some(.none)` means the shortcut was explicitly disabled.
    // `.some(.some(key))` means a custom shortcut was saved.
    static func overrideState(for commandId: Int) -> ShortcutsKey?? {
        guard let wrapper = CommandWrapper(rawValue: commandId) else {
            return .none
        }
        
        // Absence from the dictionary means "use the default".
        if !overridedShortcuts.keys.contains(wrapper) {
            return .none
        }
        
        // The dictionary stores `ShortcutsKey?`, so this returns `ShortcutsKey??`.
        return overridedShortcuts[wrapper]
    }
    
    // ObjC bridge that exposes only the currently effective override value.
    static func key(for commandId: Int) -> ShortcutsKey? {
        guard let wrapper = CommandWrapper(rawValue: commandId) else {
            return nil
        }
        if let override = overridedShortcuts[wrapper] {
            return override
        }
        return nil
    }
    
    /// Overrides a shortcut or removes the override when `remove` is true.
    static func override(_ key: ShortcutsKey?, for command: CommandWrapper, remove: Bool = false) {
        if remove {
            // Restore the default shortcut.
            overridedShortcuts.removeValue(forKey: command)
        } else if key != DefaultShortcuts[command] {
            // Store explicit `nil` by wrapping it in `Optional(...)`; assigning bare
            // `nil` would remove the dictionary entry entirely.
            overridedShortcuts[command] = Optional(key)
        } else if key == DefaultShortcuts[command] {
            // Matching the default means the override can be removed.
            overridedShortcuts.removeValue(forKey: command)
        }
        
        save()
        notifyChromiumShortcutsChanged()
    }
    
    static func reloadOverrides() {
        overridedShortcuts = load()
        notifyChromiumShortcutsChanged()
    }
    
    static func restoreOverrides() {
        overridedShortcuts.removeAll()
        save()
        notifyChromiumShortcutsChanged()
    }
    
    private static func notifyChromiumShortcutsChanged() {
        ChromiumLauncher.sharedInstance().bridge?.requestRebuildMainMenu()
    }
    
    static func isOverridden(_ command: CommandWrapper) -> Bool {
        // Presence in the dictionary means "overridden", even when the value is `nil`.
        overridedShortcuts.keys.contains(command)
    }
    
    // MARK: - Persistence
    private struct PersistedShortcut: Codable {
        let commandId: Int
        let key: ShortcutsKey?
    }
    
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
    
    static func save() {
        // Persist the optional shortcut value as-is.
        let items = overridedShortcuts.map { PersistedShortcut(commandId: $0.key.rawValue, key: $0.value) }
        do {
            let data = try JSONEncoder().encode(items)
            let url = customShortcutsFileURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
            try data.write(to: url)
        } catch {
            print("Failed to save shortcuts: \(error)")
        }
    }
    
    private static func load() -> [CommandWrapper: ShortcutsKey?] {
        let url = customShortcutsFileURL
        guard let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([PersistedShortcut].self, from: data) else {
            return [:]
        }
        
        var result: [CommandWrapper: ShortcutsKey?] = [:]
        for item in items {
            if let command = CommandWrapper(rawValue: item.commandId) {
                // `item.key` is already a `ShortcutsKey?`.
                result[command] = item.key
            }
        }
        return result
    }
}
extension ShortcutsKey {
    var modifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiersRaw)
    }
    
    var displayString: String {
        var prefix = ""
        if modifiers.contains(.command) { prefix += "⌘" }
        if modifiers.contains(.option) { prefix += "⌥" }
        if modifiers.contains(.shift) { prefix += "⇧" }
        if modifiers.contains(.control) { prefix += "⌃" }
        
        let characterSymbol: String
        switch characters {
        case String(format: "%c", NSBackspaceCharacter):
            characterSymbol = "⌫"
        case "\t":
            characterSymbol = "⇥"
        case "\r":
            characterSymbol = "↩︎"
        case "\u{1B}":
            characterSymbol = "⎋"
        default:
            if characters.count == 1 {
                characterSymbol = characters.uppercased()
            } else {
                characterSymbol = characters.uppercased()
            }
        }
        
        return prefix + characterSymbol
    }
}

extension CommandWrapper {
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
}

extension Shortcuts {
    static func updateShortcut(for item: NSMenuItem) {
        let tag = item.tag
        let state = overrideState(for: tag)
        guard let state else {
            return
        }
        if let key = state {
            item.keyEquivalent = key.characters
            item.keyEquivalentModifierMask = key.modifiers
        } else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = .init(rawValue: 0)
        }
    }
}

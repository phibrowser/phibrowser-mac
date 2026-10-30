// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import Combine
import AppKit
class ShortcutsViewModel: ObservableObject {
    enum Filter: Hashable {
        case all, customized, conflicting
        case section(String)
        case reserved

        var title: String {
            switch self {
            case .all:
                return NSLocalizedString("settings.shortcuts.filter.all", value: "All Shortcuts", comment: "Shortcuts settings - Filter showing every shortcut")
            case .customized:
                return NSLocalizedString("settings.shortcuts.filter.customized", value: "Customized Shortcuts", comment: "Shortcuts settings - Filter showing shortcuts changed or disabled by the user")
            case .conflicting:
                return NSLocalizedString("settings.shortcuts.filter.conflicting", value: "Conflicting Shortcuts", comment: "Shortcuts settings - Filter showing shortcuts that conflict with another binding")
            case .section(let title):
                return title
            case .reserved:
                return NSLocalizedString("settings.shortcuts.reservedSection", value: "Other active shortcuts (read-only)", comment: "Shortcuts settings - Active native and browser bindings that this settings page cannot reassign")
            }
        }
    }

    enum Capture: Equatable {
        case command(CommandWrapper)
    }

    enum PersistenceFailure {
        case load, save

        var message: String {
            switch self {
            case .load:
                return NSLocalizedString("settings.shortcuts.persistence.loadFailed", value: "Saved shortcuts could not be read. Retry, or choose Reset All to Defaults to keep a recovery copy and use the defaults.", comment: "Shortcuts settings - Configuration could not be loaded; edits are blocked until retry or explicit recovery")
            case .save:
                return NSLocalizedString("settings.shortcuts.persistence.saveFailed", value: "The change could not be saved. Your previous shortcuts are still active. Try the change again.", comment: "Shortcuts settings - A failed save leaves the previous shortcuts active")
            }
        }
    }

    @Published var sections: [(category: String, subtitle: String?, items: [ShortcutItem])] = []
    @Published private(set) var captureSessionID = UUID()
    @Published private(set) var recordingModifiers: NSEvent.ModifierFlags = []
    @Published var capture: Capture? {
        didSet {
            captureSessionID = UUID()
            recordingModifiers = []
        }
    }
    @Published var selectedCommand: CommandWrapper? {
        didSet {
            if selectedCommand != oldValue {
                capture = nil
                recordingMessage = nil
            }
        }
    }
    @Published var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            updateFilteredResults()
        }
    }
    @Published var filter: Filter = .all {
        didSet {
            guard filter != oldValue else { return }
            capture = nil
            updateFilteredResults()
        }
    }
    @Published var recordingMessage: String?
    @Published private(set) var reservedShortcuts: [ReservedShortcutItem] = []
    @Published var hiddenGroups: Set<Shortcuts.Group> = [.help]
    @Published private(set) var persistenceFailure: PersistenceFailure?
    private var cancellables = Set<AnyCancellable>()
    private let additionalBindings: () -> [ShortcutBinding]
    private let availableCommands: () -> [CommandWrapper]
    private var commandsCustomizedFromUnassigned = Set<CommandWrapper>()
    private(set) var inventory = ShortcutInventory(bindings: [])
    private var searchEntries: [ShortcutBinding.Owner: ShortcutSearchEntry] = [:]
    @Published private(set) var filteredSections: [(category: String, subtitle: String?, items: [ShortcutItem])] = []
    @Published private(set) var filteredReservedShortcuts: [ReservedShortcutItem] = []

    var canEdit: Bool { persistenceFailure != .load }

    var selectedItem: ShortcutItem? {
        sections.flatMap(\.items).first { $0.command == selectedCommand }
    }

    /// Selection and the view share one result snapshot per search or inventory change.
    private func updateFilteredResults() {
        let query = ShortcutSearchQuery(searchText)
        filteredSections = sections.compactMap { section in
            let items = section.items.filter { item in
                guard matchesFilter(item, category: section.category),
                      let entry = searchEntries[.command(item.command.rawValue)] else { return false }
                return query.matches(entry)
            }
            return items.isEmpty ? nil : (section.category, section.subtitle, items)
        }
        filteredReservedShortcuts = reservedShortcuts.filter { item in
            guard matchesFilter(item), let entry = searchEntries[item.id] else { return false }
            return query.matches(entry)
        }
        reconcileSelection()
    }

    private func rebuildSearchEntries() {
        searchEntries.removeAll(keepingCapacity: true)
        for item in sections.flatMap(\.items) {
            let keys = item.shortcutKey.map {
                [$0, shortcutDisplayKey(for: item.command, key: $0)]
            } ?? []
            searchEntries[.command(item.command.rawValue)] = ShortcutSearchEntry(
                keywords: [item.name] + item.searchKeywords, keys: keys + item.aliases
            )
        }
        for item in reservedShortcuts {
            var keywords = [item.name]
            if let command = item.id.commandID.flatMap(CommandWrapper.init(rawValue:)) {
                keywords += searchKeywords(for: command)
            }
            searchEntries[item.id] = ShortcutSearchEntry(keywords: keywords, keys: item.keys)
        }
    }

    private func matchesFilter(_ item: ShortcutItem, category: String) -> Bool {
        switch filter {
        case .all: return true
        case .customized: return item.isOverridden
        case .conflicting: return item.hasConflict
        case .section(let selected): return category == selected
        case .reserved: return false
        }
    }

    private func matchesFilter(_ item: ReservedShortcutItem) -> Bool {
        switch filter {
        case .all, .reserved: return true
        case .customized, .section: return false
        case .conflicting:
            guard let command = item.id.commandID.flatMap(CommandWrapper.init(rawValue:)) else { return false }
            return !findConflictingCommands(for: command).isEmpty
        }
    }

    private func reconcileSelection() {
        let commands = filteredSections.flatMap(\.items).map(\.command)
        if !commands.contains(where: { $0 == selectedCommand }) {
            selectedCommand = commands.first
        }
    }

    /// Only a shortcut control starts capture; row selection remains navigation.
    func startRecording(for command: CommandWrapper) {
        guard sections.flatMap(\.items).contains(where: { $0.command == command }) else { return }
        selectedCommand = command
        recordingMessage = nil
        capture = canEdit ? .command(command) : nil
    }

    func cancelCapture(sessionID: UUID) {
        // A previous responder can resign after the next recording has started.
        guard captureSessionID == sessionID else { return }
        capture = nil
    }

    func selectConflict(_ command: CommandWrapper) {
        guard sections.flatMap(\.items).contains(where: { $0.command == command }) else { return }
        searchText = ""
        filter = .all
        capture = nil
        selectedCommand = command
    }

    func conflicts(for command: CommandWrapper) -> [ShortcutConflictItem] {
        let visibleCommands = Set(sections.flatMap(\.items).map(\.command))
        let bindings = inventory.bindings(for: command.rawValue).flatMap { binding in
            inventory.conflicts(for: command.rawValue, key: binding.key, in: binding.scope)
        }
        let owners = Dictionary(grouping: bindings, by: \.owner)
        return owners.keys.sorted { $0.precedes($1) }.map { owner in
            let target: CommandWrapper?
            if let id = owner.commandID, let command = CommandWrapper(rawValue: id), visibleCommands.contains(command) {
                target = command
            } else {
                target = nil
            }
            return ShortcutConflictItem(
                id: owner, name: displayName(for: owner), command: target,
                keys: Array(Set(owners[owner, default: []].map { $0.key.displayString })).sorted()
            )
        }
    }

    var editingCommand: CommandWrapper? {
        get {
            if case .command(let command) = capture { return command }
            return nil
        }
        set { capture = newValue.map(Capture.command) }
    }
    
    init(additionalBindings: @escaping () -> [ShortcutBinding] = Shortcuts.additionalBindings,
         availableCommands: @escaping () -> [CommandWrapper] = { Shortcuts.availableMenuCommands() }) {
        self.additionalBindings = additionalBindings
        self.availableCommands = availableCommands
        SpaceManager.shared.$spaces
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuildSections()
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .shortcutsDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.capture = nil
                self.refreshLoadFailure()
                self.rebuildSections()
            }
            .store(in: &cancellables)
        refreshLoadFailure()
        rebuildSections()
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuildSections() }
            .store(in: &cancellables)
        // A companion app connecting or quitting can take a command away
        // (Save to Folio, see SaveForLaterService.featureEnabled) or give it back.
        NotificationCenter.default.publisher(for: .agentCompanionsDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuildSections() }
            .store(in: &cancellables)
        DistributedNotificationCenter.default()
            .publisher(for: KioskGlobalShortcutRegistrar.inputSourceDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuildSections() }
            .store(in: &cancellables)
    }
    
    func rebuildSections() {
        let snapshot = Shortcuts.bindingInventory(additionalBindings: additionalBindings())
        // Keep owner inspection out of nested optional closures: Swift 6.3
        // can fail SIL ownership verification when optimizing that chain.
        var visible: [ShortcutBinding] = []
        for binding in snapshot.bindings {
            if let id = binding.commandID, let command = CommandWrapper(rawValue: id), !shouldShow(command) {
                continue
            }
            visible.append(binding)
        }
        inventory = ShortcutInventory(bindings: visible)
        var newSections: [(category: String, subtitle: String?, items: [ShortcutItem])] = []
        
        // Discover available actions even before they have a binding. Keep saved
        // commands available after disabling them removes their runtime binding.
        let grouped = Set(Shortcuts.configurableCommands)
        let discovered = Set(inventory.bindings.compactMap(\.commandID)
            + availableCommands().map(\.rawValue)
            + Array(Shortcuts.configuration.overrides.keys))
            .compactMap(CommandWrapper.init(rawValue:))
            .filter { !grouped.contains($0) && !$0.isSystemShortcut && shouldShow($0)
                && $0 != .IDC_SHOW_READING_MODE_KEYBOARD }
            .sorted { $0.rawValue < $1.rawValue }
        let discoveredSet = Set(discovered)
        let categorized = Set(Shortcuts.Group.allCases.flatMap(\.discoveredCommands))
        Shortcuts.Group.allCases
            .filter { !hiddenGroups.contains($0) }
            .forEach { group in
                let commands = group.commands.filter(shouldShow)
                    + group.discoveredCommands.filter { discoveredSet.contains($0) }
                if !commands.isEmpty {
                    newSections.append((category: group.title, subtitle: group.subtitle, items: commands.map(makeItem)))
                }
            }

        let uncategorized = discovered.filter { !categorized.contains($0) }
        if !uncategorized.isEmpty {
            newSections.append((category: NSLocalizedString(
                "settings.shortcuts.group.other", value: "Other",
                comment: "Shortcuts settings - Additional customizable browser commands"),
                subtitle: nil, items: uncategorized.map(makeItem)))
        }
        sections = newSections
        let editable = Set(sections.flatMap(\.items).map { ShortcutBinding.Owner.command($0.command.rawValue) })
        let unlisted = Dictionary(grouping: inventory.bindings.filter {
            guard !editable.contains($0.owner), case .command(let id) = $0.owner else { return false }
            return CommandWrapper(rawValue: id)?.isSystemShortcut != true
        }, by: \.owner)
        reservedShortcuts = unlisted.keys.sorted { $0.precedes($1) }.map { owner in
            ReservedShortcutItem(id: owner, name: displayName(for: owner),
                                 keys: Array(Set(unlisted[owner, default: []].map(\.key)))
                                    .sorted { $0.displayString < $1.displayString })
        }
        rebuildSearchEntries()
        updateFilteredResults()
    }

    private func makeItem(_ command: CommandWrapper) -> ShortcutItem {
        let bindings = inventory.bindings(for: command.rawValue)
        let conflicts = findConflictingCommands(for: command)
        // Chromium owns defaults for commands absent from Phi's default table.
        // An explicit disable must never fall back to a stale runtime snapshot.
        let override = Shortcuts.overrideState(for: command.rawValue)
        let inheritsDefaults = override == nil || override?.inheritsDefaults == true
        let key = Shortcuts.key(for: command) ?? (inheritsDefaults ? bindings.first?.key : nil)
        return ShortcutItem(
            id: command, command: command, name: displayName(for: command),
            shortcutKey: key, shortcutDisplay: shortcutDisplay(for: command, key: key),
            shortcutKeycapTokens: key.map { shortcutDisplayKey(for: command, key: $0).keycapTokens } ?? [],
            isOverridden: Shortcuts.isOverridden(command),
            conflictingCommandNames: conflicts
                .filter { $0 != .system }.map { displayName(for: $0) },
            searchKeywords: searchKeywords(for: command),
            aliases: Array(Set(bindings.map(\.key))).sorted { $0.displayString < $1.displayString },
            hasSystemConflict: conflicts.contains(.system)
        )
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

        return shortcutDisplayKey(for: command, key: key).displayString
    }

    private func shortcutDisplayKey(for command: CommandWrapper, key: ShortcutsKey) -> ShortcutsKey {
        // AppKit reports the shifted characters for these default events, so
        // execution stores "{" and "}". Keep the settings label in the
        // familiar physical-key notation without changing global key identity.
        guard key == Shortcuts.DefaultShortcuts[command] else {
            return key
        }
        switch command {
        case .IDC_SELECT_PREVIOUS_TAB:
            return ShortcutsKey(
                characters: "[",
                modifiers: key.modifiers
            )
        case .IDC_SELECT_NEXT_TAB:
            return ShortcutsKey(
                characters: "]",
                modifiers: key.modifiers
            )
        case .PHI_SPLIT_WITH_NEW_TAB:
            return ShortcutsKey(
                characters: "=",
                modifiers: key.modifiers
            )
        default:
            return key
        }
    }
    
    private func findConflictingCommands(for command: CommandWrapper) -> [ShortcutBinding.Owner] {
        let owners = Set(inventory.bindings(for: command.rawValue).flatMap { binding in
            inventory.conflicts(for: command.rawValue, key: binding.key,
                                in: binding.scope).map(\.owner)
        })
        return owners.sorted { $0.precedes($1) }
    }

    private func shouldShow(_ command: CommandWrapper) -> Bool {
        guard !Shortcuts.disabledShortcutCommands.contains(command) else { return false }
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

    private func displayName(for owner: ShortcutBinding.Owner) -> String {
        if owner == .system { return ShortcutConflictItem.systemMessage }
        let command = owner.commandID.flatMap(CommandWrapper.init(rawValue:))
        if let command, !command.isSystemShortcut {
            return displayName(for: command)
        }
        if let title = inventory.bindings.first(where: { $0.owner == owner && $0.title?.isEmpty == false })?.title {
            return title
        }
        if let command { return displayName(for: command) }
        return NSLocalizedString("settings.shortcuts.reservedOwner", value: "Reserved browser shortcut", comment: "Shortcuts settings - An active browser binding that cannot be customized in this version")
    }

    func handleCaptureModifiers(_ modifiers: NSEvent.ModifierFlags) {
        guard case .command = capture else { return }
        let preview = modifiers.intersection([.command, .control, .option, .shift, .function])
        if recordingModifiers != preview { recordingModifiers = preview }
    }

    func handleCaptureEvent(_ event: NSEvent) {
        guard event.type == .keyDown, let capture else { return }
        let action = ShortcutsKey.recordingAction(for: event)
        guard case .command(let command) = capture else { return }
        switch action {
        case .cancel:
            self.capture = nil
        case .disable:
            disableShortcut(for: command)
        case .key(let key):
            setCustomShortcut(for: command, key: key)
        case .unsupported:
            recordingMessage = event.keyCode == 53
                ? NSLocalizedString("settings.shortcuts.recording.escapeModifiers", value: "Escape shortcuts require Command or Control.", comment: "Shortcuts settings - macOS menu matching does not support Escape with only Shift or Option")
                : NSLocalizedString("settings.shortcuts.recording.unsupported", value: "Use a modifier key. Letters and symbols require Command, Control, or Option.", comment: "Shortcuts settings - Recording rejected an unmodified key or a Shift-only printable key to preserve normal typing")
        }
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
    
    /// Save only this command. Conflicts remain visible for the user to resolve.
    func setCustomShortcut(for command: CommandWrapper, key: ShortcutsKey) {
        // Runtime bindings already include overrides. Remember the unassigned
        // baseline before replacing it, rather than treating the custom key as a default.
        if !Shortcuts.isOverridden(command) {
            if Shortcuts.DefaultShortcuts[command] == nil,
               inventory.bindings(for: command.rawValue).isEmpty {
                commandsCustomizedFromUnassigned.insert(command)
            } else {
                commandsCustomizedFromUnassigned.remove(command)
            }
        }
        recordingMessage = nil
        apply(Shortcuts.setOverride(.custom(key), for: command))
    }
    
    /// Removes a new assignment, or explicitly disables inherited bindings.
    func disableShortcut(for command: CommandWrapper) {
        // Deleting an unassigned command does not create a customization.
        if !Shortcuts.isOverridden(command),
           Shortcuts.key(for: command) == nil,
           inventory.bindings(for: command.rawValue).isEmpty {
            recordingMessage = nil
            capture = nil
            return
        }
        let override: ShortcutOverride? = commandsCustomizedFromUnassigned.contains(command) ? nil : .disabled
        apply(Shortcuts.setOverride(override, for: command))
    }
    
    /// Restores the default shortcut for the command.
    func restoreDefaultShortcut(for command: CommandWrapper) {
        apply(Shortcuts.setOverride(nil, for: command))
    }
    
    func restoreAllShortcuts() {
        apply(Shortcuts.restoreOverrides())
    }

    func retryLoadingShortcuts() {
        apply(Shortcuts.reloadOverrides())
    }

    func dismissSaveFailure() {
        if persistenceFailure == .save { persistenceFailure = nil }
    }

    private func refreshLoadFailure() {
        if Shortcuts.configuration.loadError != nil {
            persistenceFailure = .load
        } else if persistenceFailure == .load {
            persistenceFailure = nil
        }
    }

    private func apply(_ result: Result<Void, Error>) {
        switch result {
        case .success:
            persistenceFailure = nil
        case .failure:
            persistenceFailure = Shortcuts.configuration.loadError == nil ? .save : .load
        }
        editingCommand = nil
        rebuildSections()
    }
}

private extension CommandWrapper {
    var localizedShortcutTitle: String {
        // Keep this exhaustive so new commands cannot silently display English metadata.
        switch self {
        case .IDC_OPTIONS:
            return NSLocalizedString("settings.shortcuts.command.openSettings", value: "Settings", comment: "Shortcuts settings - Command title for opening Phi settings")
        case .IDC_HIDE_APP:
            return NSLocalizedString("settings.shortcuts.command.hideApp", value: "Hide Phi", comment: "Shortcuts settings - Command title for hiding Phi and its windows")
        case .IDC_EXIT:
            return NSLocalizedString("settings.shortcuts.command.quitApp", value: "Quit Phi", comment: "Shortcuts settings - Command title for quitting Phi")
        case .IDC_CLEAR_BROWSING_DATA:
            return NSLocalizedString("settings.shortcuts.command.clearBrowsingData", value: "Clear Browsing Data", comment: "Shortcuts settings - Command title for choosing browsing data to clear")
        case .IDC_IMPORT_SETTINGS:
            return NSLocalizedString("settings.shortcuts.command.importSettings", value: "Import Settings", comment: "Shortcuts settings - Command title for importing bookmarks and settings from another browser")
        case .IDC_NEW_SPLIT_TAB:
            return NSLocalizedString("settings.shortcuts.command.newSplitTab", value: "New Split Tab", comment: "Shortcuts settings - Command title for opening a tab in Split View")
        case .IDC_SAVE_PAGE:
            return NSLocalizedString("settings.shortcuts.command.savePage", value: "Save Page", comment: "Shortcuts settings - Command title for saving the current page to a file")
        case .IDC_BASIC_PRINT:
            return NSLocalizedString("settings.shortcuts.command.basicPrint", value: "Basic Print", comment: "Shortcuts settings - Command title for printing with the system dialog")
        case .IDC_CONTENT_CONTEXT_UNDO:
            return NSLocalizedString("settings.shortcuts.command.undo", value: "Undo", comment: "Shortcuts settings - Command title for undoing the last edit")
        case .IDC_CONTENT_CONTEXT_REDO:
            return NSLocalizedString("settings.shortcuts.command.redo", value: "Redo", comment: "Shortcuts settings - Command title for redoing the last undone edit")
        case .IDC_CONTENT_CONTEXT_CUT:
            return NSLocalizedString("settings.shortcuts.command.cut", value: "Cut", comment: "Shortcuts settings - Command title for cutting the selection to the clipboard")
        case .IDC_CONTENT_CONTEXT_COPY:
            return NSLocalizedString("settings.shortcuts.command.copy", value: "Copy", comment: "Shortcuts settings - Command title for copying the selection to the clipboard")
        case .IDC_CONTENT_CONTEXT_PASTE:
            return NSLocalizedString("settings.shortcuts.command.paste", value: "Paste", comment: "Shortcuts settings - Command title for pasting the clipboard contents")
        case .IDC_CONTENT_CONTEXT_PASTE_AND_MATCH_STYLE, .IDS_PASTE_MATCH_STYLE_MAC:
            return NSLocalizedString("settings.shortcuts.command.pasteMatchStyle", value: "Paste and Match Style", comment: "Shortcuts settings - Command title for pasting text with the surrounding formatting")
        case .IDC_CONTENT_CONTEXT_SELECTALL:
            return NSLocalizedString("settings.shortcuts.command.selectAll", value: "Select All", comment: "Shortcuts settings - Command title for selecting all content in the focused area")
        case .IDC_SHOW_BOOKMARK_BAR:
            return NSLocalizedString("settings.shortcuts.command.toggleBookmarkBar", value: "Toggle Bookmark Bar", comment: "Shortcuts settings - Command title for showing or hiding the bookmarks bar")
        case .IDC_TOGGLE_FULLSCREEN_TOOLBAR:
            return NSLocalizedString("settings.shortcuts.command.toggleFullscreenToolbar", value: "Toggle Fullscreen Toolbar", comment: "Shortcuts settings - Command title for showing or hiding the toolbar in full screen")
        case .IDC_FULLSCREEN:
            return NSLocalizedString("settings.shortcuts.command.fullscreen", value: "Full Screen", comment: "Shortcuts settings - Command title for entering or leaving full screen")
        case .IDC_SHOW_BOOKMARK_MANAGER:
            return NSLocalizedString("settings.shortcuts.command.bookmarkManager", value: "Bookmark Manager", comment: "Shortcuts settings - Command title for opening the bookmark manager")
        case .IDC_BOOKMARK_THIS_TAB:
            return NSLocalizedString("settings.shortcuts.command.bookmarkTab", value: "Bookmark Tab", comment: "Shortcuts settings - Command title for bookmarking the current page")
        case .IDC_BOOKMARK_ALL_TABS:
            return NSLocalizedString("settings.shortcuts.command.bookmarkAllTabs", value: "Bookmark All Tabs", comment: "Shortcuts settings - Command title for bookmarking all open tabs")
        case .IDC_MINIMIZE_WINDOW:
            return NSLocalizedString("settings.shortcuts.command.minimizeWindow", value: "Minimize Window", comment: "Shortcuts settings - Command title for minimizing the current window")
        case .IDC_TASK_MANAGER:
            return NSLocalizedString("settings.shortcuts.command.taskManager", value: "Task Manager", comment: "Shortcuts settings - Command title for viewing browser tasks and their resource usage")
        case .IDC_WINDOW_PIN_TAB:
            return NSLocalizedString("settings.shortcuts.command.pinTab", value: "Pin Tab", comment: "Shortcuts settings - Command title for pinning or unpinning the current tab")
        case .IDC_WINDOW_GROUP_TAB:
            return NSLocalizedString("settings.shortcuts.command.groupTab", value: "Group Tab", comment: "Shortcuts settings - Command title for changing the current tab's group")
        case .IDC_WINDOW_CLOSE_OTHER_TABS:
            return NSLocalizedString("settings.shortcuts.command.closeOtherTabs", value: "Close Other Tabs", comment: "Shortcuts settings - Command title for closing other tabs in the current window")
        case .IDC_WINDOW_CLOSE_TABS_TO_RIGHT:
            return NSLocalizedString("settings.shortcuts.command.closeTabsToRight", value: "Close Tabs to the Right", comment: "Shortcuts settings - Command title for closing tabs to the right of the current tab")
        case .IDC_MOVE_TAB_TO_NEW_WINDOW:
            return NSLocalizedString("settings.shortcuts.command.moveTabToNewWindow", value: "Move Tab to New Window", comment: "Shortcuts settings - Command title for moving the current tab to a new window")
        case .IDC_FEEDBACK:
            return NSLocalizedString("settings.shortcuts.command.sendFeedback", value: "Send Feedback", comment: "Shortcuts settings - Command title for opening the feedback page")
        case .IDC_HELP_PAGE_VIA_MENU:
            return NSLocalizedString("settings.shortcuts.command.openHelp", value: "Phi Help", comment: "Shortcuts settings - Command title for opening browser help")
        case .IDS_HIDE_OTHERS_MAC:
            return NSLocalizedString("settings.shortcuts.command.hideOthers", value: "Hide Others", comment: "Shortcuts settings - Command title for hiding other applications")
        case .IDS_CLOSE_ALL_WINDOWS_MAC:
            return NSLocalizedString("settings.shortcuts.command.closeAllWindows", value: "Close All", comment: "Shortcuts settings - Command title for closing all browser windows")
        case .IDS_EDIT_SHOW_SPELLING_GRAMMAR_MAC:
            return NSLocalizedString("settings.shortcuts.command.showSpellingAndGrammar", value: "Show Spelling and Grammar", comment: "Shortcuts settings - Command title for opening spelling and grammar tools")
        case .IDS_EDIT_CHECK_DOCUMENT_MAC:
            return NSLocalizedString("settings.shortcuts.command.checkDocument", value: "Check Document Now", comment: "Shortcuts settings - Command title for checking spelling in the current document")
        case .IDC_MOVE_TAB_NEXT:
            return NSLocalizedString("settings.shortcuts.command.moveTabRight", value: "Move Tab Right", comment: "Shortcuts settings - Title of a browser shortcut")
        case .IDC_MOVE_TAB_PREVIOUS:
            return NSLocalizedString("settings.shortcuts.command.moveTabLeft", value: "Move Tab Left", comment: "Shortcuts settings - Title of a browser shortcut")
        case .IDC_SHOW_AVATAR_MENU:
            return NSLocalizedString("settings.shortcuts.command.showProfiles", value: "Show Profiles Menu", comment: "Shortcuts settings - Title of a browser shortcut")
        case .IDC_FOCUS_NEXT_PANE:
            return NSLocalizedString("settings.shortcuts.command.focusNextPane", value: "Focus Next Pane", comment: "Shortcuts settings - Title of a browser shortcut")
        case .IDC_FOCUS_PREVIOUS_PANE:
            return NSLocalizedString("settings.shortcuts.command.focusPreviousPane", value: "Focus Previous Pane", comment: "Shortcuts settings - Title of a browser shortcut")
        case .IDC_FOCUS_INACTIVE_POPUP_FOR_ACCESSIBILITY:
            return NSLocalizedString("settings.shortcuts.command.focusPopup", value: "Focus Open Popup", comment: "Shortcuts settings - Title of a browser shortcut")
        case .IDC_SHOW_READING_MODE_KEYBOARD:
            return NSLocalizedString("settings.shortcuts.command.showReadingMode", value: "Show Reading Mode", comment: "Shortcuts settings - Title of a browser shortcut")
        case .IDC_ADD_NEW_TAB_TO_GROUP:
            return NSLocalizedString("settings.shortcuts.command.addTabToGroup", value: "Add New Tab to Group", comment: "Shortcuts settings - Title of a browser shortcut")
        case .IDC_CREATE_NEW_TAB_GROUP:
            return NSLocalizedString("settings.shortcuts.command.createTabGroup", value: "Create New Tab Group", comment: "Shortcuts settings - Title of a browser shortcut")
        case .IDC_CLOSE_TAB_GROUP:
            return NSLocalizedString("settings.shortcuts.command.closeTabGroup", value: "Close Tab Group", comment: "Shortcuts settings - Title of a browser shortcut")
        case .IDC_FOCUS_NEXT_TAB_GROUP:
            return NSLocalizedString("settings.shortcuts.command.focusNextTabGroup", value: "Focus Next Tab Group", comment: "Shortcuts settings - Title of a browser shortcut")
        case .IDC_FOCUS_PREV_TAB_GROUP:
            return NSLocalizedString("settings.shortcuts.command.focusPreviousTabGroup", value: "Focus Previous Tab Group", comment: "Shortcuts settings - Title of a browser shortcut")
        case .IDC_DEBUG_TOGGLE_TABLET_MODE:
            return NSLocalizedString("settings.shortcuts.command.toggleTabletMode", value: "Toggle Tablet Mode", comment: "Shortcuts settings - Title of a browser shortcut")
        case .IDC_DEBUG_PRINT_VIEW_TREE:
            return NSLocalizedString("settings.shortcuts.command.printViewTree", value: "Print View Tree", comment: "Shortcuts settings - Title of a browser shortcut")
        case .IDC_DEBUG_PRINT_VIEW_TREE_DETAILS:
            return NSLocalizedString("settings.shortcuts.command.printViewTreeDetails", value: "Print View Tree Details", comment: "Shortcuts settings - Title of a browser shortcut")
        case .IDC_OPEN_FILE:
            return NSLocalizedString("settings.shortcuts.command.openFile", value: "Open File…", comment: "Shortcuts settings - Command title for opening a local file")
        case .IDC_NEW_TAB:
            return NSLocalizedString("settings.shortcuts.command.newTab", value: "New Tab", comment: "Shortcuts settings - Command title for opening a new tab")
        case .IDC_NEW_WINDOW:
            return NSLocalizedString("settings.shortcuts.command.newWindow", value: "New Window", comment: "Shortcuts settings - Command title for opening a new window")
        case .IDC_NEW_INCOGNITO_WINDOW:
            return NSLocalizedString("settings.shortcuts.command.newIncognitoWindow", value: "New Incognito Window", comment: "Shortcuts settings - Command title for opening a new Incognito window")
        case .PHI_NEW_INCOGNITO_SPACE:
            return NSLocalizedString("app.fileMenu.createNewIncognitoSpace", value: "New Incognito Space", comment: "File menu and Shortcuts settings - Command title for creating a new Incognito Space")
        case .PHI_NEW_KIOSK_WINDOW:
            return NSLocalizedString("settings.shortcuts.command.newKioskWindow", value: "New Kiosk Window", comment: "Shortcuts settings - Command title for opening a new Kiosk window")
        case .PHI_KIOSK_OPEN_IN_SPACE:
            return NSLocalizedString("settings.shortcuts.command.kioskOpenInSpace", value: "Open Kiosk or Peek in current Space", comment: "Shortcuts settings - Open the Kiosk page in the toolbar's target Space or expand Peek into a regular tab in the current Space")
        case .PHI_KIOSK_CHOOSE_SPACE:
            return NSLocalizedString("settings.shortcuts.command.kioskChooseSpace", value: "Show Kiosk \"Open in\" Menu", comment: "Shortcuts settings - Show the Open in menu for selecting a destination Space in a Kiosk window")
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
        case .PHI_SHARE_PAGE:
            return NSLocalizedString("settings.shortcuts.command.sharePage", value: "Share Page", comment: "Shortcuts settings - Command title for sharing the current page via the macOS share picker")
        case .PHI_CAPTURE_FULL_PAGE:
            return NSLocalizedString("app.fileMenu.copyFullPageScreenshot", value: "Capture Full Page", comment: "File menu - Capture the entire current webpage and copy it as an image")
        case .PHI_CAPTURE_AREA:
            return NSLocalizedString("app.fileMenu.capturePageArea", value: "Capture Area…", comment: "File menu - Select a visible webpage area to capture and edit")
        case .PHI_COPY_URL:
            return NSLocalizedString("settings.shortcuts.command.copyURL", value: "Copy URL", comment: "Shortcuts settings - Command title for copying the current URL")
        case .PHI_TOGGLE_READER:
            return NSLocalizedString("settings.shortcuts.command.toggleReaderView", value: "Toggle Reader View", comment: "Shortcuts settings - Command title for switching the current page between Reader View and the normal page")
        case .PHI_SAVE_FOR_LATER:
            return NSLocalizedString("settings.shortcuts.command.saveToFolio", value: "Save to Folio", comment: "Shortcuts settings - Command title for saving the current page for later as markdown plus a webpage copy")
        case .PHI_SPLIT_WITH_NEW_TAB:
            return NSLocalizedString("settings.shortcuts.command.splitWithNewTab", value: "Split with New Tab", comment: "Shortcuts settings - Command title for opening a new tab in Split View next to the current tab")
        case .IDC_FIND:
            return NSLocalizedString("settings.shortcuts.command.findOnPage", value: "Find", comment: "Shortcuts settings - Command title for finding text on the current page")
        case .IDC_FIND_NEXT:
            return NSLocalizedString("settings.shortcuts.command.findNextMatch", value: "Find Next", comment: "Shortcuts settings - Command title for selecting the next match on the current page")
        case .IDC_FIND_PREVIOUS:
            return NSLocalizedString("settings.shortcuts.command.findPreviousMatch", value: "Find Previous", comment: "Shortcuts settings - Command title for selecting the previous match on the current page")
        case .IDC_FOCUS_SEARCH:
            return NSLocalizedString("settings.shortcuts.command.searchTheWeb", value: "Search the Web...", comment: "Shortcuts settings - Command title for starting a web search")
        case .IDS_EDIT_USE_SELECTION_MAC:
            return NSLocalizedString("settings.shortcuts.command.useSelectionForFind", value: "Use Selection for Find", comment: "Shortcuts settings - Use selected text as the search text")
        case .IDS_EDIT_JUMP_TO_SELECTION_MAC:
            return NSLocalizedString("settings.shortcuts.command.jumpToSelection", value: "Jump to Selection", comment: "Shortcuts settings - Scroll to the selected text")
        case .IDC_STOP:
            return NSLocalizedString("settings.shortcuts.command.stopLoading", value: "Stop", comment: "Shortcuts settings - Command title for stopping the current page from loading")
        case .IDC_RELOAD:
            return NSLocalizedString("settings.shortcuts.command.reloadPage", value: "Reload Page", comment: "Shortcuts settings - Command title for reloading the current page")
        case .IDC_RELOAD_BYPASSING_CACHE:
            return NSLocalizedString("settings.shortcuts.command.forceReload", value: "Force Reload Page", comment: "Shortcuts settings - Reload the page without using cached content")
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
        case .IDC_SELECT_NEXT_TAB, .IDC_CYCLE_TO_NEXT_TAB:
            return NSLocalizedString("settings.shortcuts.command.selectNextTab", value: "Select Next Tab", comment: "Shortcuts settings - Command title for selecting the next tab")
        case .IDC_SELECT_PREVIOUS_TAB, .IDC_CYCLE_TO_PREV_TAB:
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
        case .PHI_SELECT_SPACE_0, .PHI_SELECT_SPACE_1, .PHI_SELECT_SPACE_2,
             .PHI_SELECT_SPACE_3, .PHI_SELECT_SPACE_4, .PHI_SELECT_SPACE_5,
             .PHI_SELECT_SPACE_6, .PHI_SELECT_SPACE_7, .PHI_SELECT_SPACE_8:
            return String(
                format: NSLocalizedString("settings.shortcuts.command.selectNumberedSpace", value: "Go to Space %d", comment: "Shortcuts settings - Command title when a Space name is unavailable; %d is the one-based Space position"),
                rawValue - Self.PHI_SELECT_SPACE_0.rawValue + 1
            )
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
    let shortcutKeycapTokens: [String]
    let isOverridden: Bool
    let conflictingCommandNames: [String]
    let searchKeywords: [String]
    var aliases: [ShortcutsKey] = []
    var hasSystemConflict = false
    
    var hasConflict: Bool {
        hasSystemConflict || !conflictingCommandNames.isEmpty
    }
}

struct ReservedShortcutItem: Identifiable {
    let id: ShortcutBinding.Owner
    let name: String
    let keys: [ShortcutsKey]
}

/// A conflict destination exists only for commands shown in the editable list.
struct ShortcutConflictItem: Identifiable {
    let id: ShortcutBinding.Owner
    let name: String
    let command: CommandWrapper?
    let keys: [String]

    var isSystem: Bool { id == .system }

    static var systemMessage: String {
        NSLocalizedString("settings.shortcuts.conflict.systemMessage", value: "This shortcut conflicts with a macOS system shortcut and may not work in Phi.", comment: "Shortcuts settings - Fixed warning for a shortcut reserved by macOS; informational only, with no navigation action")
    }
}

/// Normalize and deduplicate bindings only when the shortcut inventory changes.
private struct ShortcutSearchEntry {
    struct Key {
        let modifiers: Set<String>
        let characters: Set<String>
    }

    let keywords: [String]
    let keys: [Key]

    init(keywords: [String], keys: [ShortcutsKey]) {
        self.keywords = Array(Set(keywords))
        self.keys = Set(keys).map { key in
            let keycaps = key.keycapTokens.map { $0.lowercased() }
            return Key(modifiers: Set(keycaps.dropLast()),
                       characters: [key.characters.lowercased(), keycaps.last ?? ""])
        }
    }
}

/// Match every key term against one binding so aliases cannot form a nonexistent chord.
private struct ShortcutSearchQuery {
    private static let modifierAliases = [
        "command": "⌘", "cmd": "⌘", "⌘": "⌘",
        "control": "⌃", "ctrl": "⌃", "ctl": "⌃", "⌃": "⌃",
        "option": "⌥", "opt": "⌥", "alt": "⌥", "⌥": "⌥",
        "shift": "⇧", "⇧": "⇧",
        "function": "fn", "fn": "fn", "🌐": "fn",
    ]
    private static let modifierSymbols = ["⌘", "⌃", "⌥", "⇧", "🌐"]

    private enum Token {
        case modifier(Set<String>)
        case text(String)
    }

    private let text: String
    private let tokens: [Token]

    init(_ searchText: String) {
        text = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var separated = text.lowercased()
        for symbol in Self.modifierSymbols {
            separated = separated.replacingOccurrences(of: symbol, with: " \(symbol) ")
        }
        var terms = separated.split { $0.isWhitespace || $0 == "+" }.map(String.init)
        // A trailing separator is incomplete input (cmd+). Keep literal plus for
        // standalone +, doubled ++, or compact symbol notation such as ⌘⇧+.
        let followsSymbol = text.dropLast().last.map { Self.modifierSymbols.contains(String($0)) } ?? false
        if text == "+" || text.hasSuffix("++") || (text.hasSuffix("+") && followsSymbol) {
            terms.append("+")
        }
        tokens = terms.map { term in
            if let modifier = Self.modifierAliases[term] { return .modifier([modifier]) }
            // Keep single letters as keys; longer prefixes allow typing comm or ctr.
            if term.count > 1 {
                let modifiers = Set(Self.modifierAliases.filter { $0.key.hasPrefix(term) }.values)
                if !modifiers.isEmpty { return .modifier(modifiers) }
            }
            return .text(term)
        }
    }

    func matches(_ entry: ShortcutSearchEntry) -> Bool {
        if text.isEmpty || entry.keywords.contains(where: { $0.localizedStandardContains(text) }) {
            return true
        }
        guard !tokens.isEmpty else { return false }
        return entry.keys.contains { key in
            tokens.allSatisfy { token in
                switch token {
                case .modifier(let candidates):
                    return !key.modifiers.isDisjoint(with: candidates)
                case .text(let value):
                    if key.characters.contains(value) { return true }
                    // Single letters must match the key, not a modifier name or command title.
                    return value.count > 1 && entry.keywords.contains { $0.localizedStandardContains(value) }
                }
            }
        }
    }
}

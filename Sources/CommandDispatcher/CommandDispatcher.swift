// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import AppKit
struct CommandDispatcher {
    private static let shortcutModifierFlags: NSEvent.ModifierFlags = [
        .command,
        .option,
        .shift,
        .control,
    ]

    // Shortcut -> Chromium command mapping for events handled on the native side.
    private static let shortcutCommandMap: [ShortcutsKey: CommandWrapper] = [
        ShortcutsKey(characters: "t", modifiers: [.command]): .IDC_NEW_TAB,
        ShortcutsKey(characters: "0", modifiers: [.command]): .IDC_SELECT_TAB_0,
        ShortcutsKey(characters: "1", modifiers: [.command]): .IDC_SELECT_TAB_1,
        ShortcutsKey(characters: "2", modifiers: [.command]): .IDC_SELECT_TAB_2,
        ShortcutsKey(characters: "3", modifiers: [.command]): .IDC_SELECT_TAB_3,
        ShortcutsKey(characters: "4", modifiers: [.command]): .IDC_SELECT_TAB_4,
        ShortcutsKey(characters: "5", modifiers: [.command]): .IDC_SELECT_TAB_5,
        ShortcutsKey(characters: "6", modifiers: [.command]): .IDC_SELECT_TAB_6,
        ShortcutsKey(characters: "7", modifiers: [.command]): .IDC_SELECT_TAB_7,
    ]

    /// PHI-only commands intercepted in `handleKeyEquivalent` before Chromium sees them.
    private static let phiInterceptedCommands: [CommandWrapper] = [
        .PHI_TAB_SWITCHER_FORWARD,
        .PHI_TAB_SWITCHER_BACKWARD,
        .PHI_SELECT_NEXT_SPACE,
        .PHI_SELECT_PREVIOUS_SPACE,
        .PHI_FARRINGDON_TOGGLE,
        .PHI_COPY_URL,
    ] + CommandWrapper.spaceSelectionCommands

    /// Commands swallowed while the focused tab shows the native NTP — it has no
    /// WebContents to inspect or view source of.
    private static let nativeNtpBlockedCommands: Set<CommandWrapper> = [
        .IDC_DEV_TOOLS,
        .IDC_DEV_TOOLS_INSPECT,
        .IDC_DEV_TOOLS_CONSOLE,
        .IDC_VIEW_SOURCE,
    ]

    /// Commands that stay available while a window is agent-controlled — only
    /// Space navigation, so the user can always leave the agent Space. Every
    /// other browser command (menu or shortcut) is blocked until they take
    /// control. See `isWindowAgentLocked`.
    private static let agentLockAllowedCommands: Set<CommandWrapper> =
        Set(CommandWrapper.spaceSelectionCommands
            + [.PHI_SELECT_NEXT_SPACE, .PHI_SELECT_PREVIOUS_SPACE])

    /// Reverse lookup: user-configured shortcut key → PHI command.
    /// Rebuilt when shortcuts change via `reloadPhiShortcutMap()`.
    private static var phiShortcutMap: [ShortcutsKey: CommandWrapper] = buildPhiShortcutMap()

    static func reloadPhiShortcutMap() {
        phiShortcutMap = buildPhiShortcutMap()
    }

    private static func buildPhiShortcutMap() -> [ShortcutsKey: CommandWrapper] {
        var map: [ShortcutsKey: CommandWrapper] = [:]
        for cmd in phiInterceptedCommands {
            if let key = Shortcuts.key(for: cmd) {
                map[key] = cmd
            }
        }
        return map
    }
    
    @MainActor
    static func dispatchCommand(_ sender: Any, window: NSWindow) -> Bool {
        guard let command = CommandWrapper(rawValue: (sender as AnyObject).tag) else {
            return false
        }
        return dispatchCommand(command, to: window)
    }
    
    /// True while `window` shows an agent Space the agent currently controls.
    /// Its workspace is off-limits to the user until they take control.
    @MainActor
    static func isWindowAgentLocked(_ window: NSWindow) -> Bool {
        guard let state = MainBrowserWindowControllersManager.shared
                .findControllerWith(window: window)?.browserState else { return false }
        return AgentSpaceManager.shared.isAgentOwned(state.spaceId)
    }

    @MainActor
    private static func dispatchCommand(_ command: CommandWrapper, to window: NSWindow) -> Bool {
        guard let windowController = MainBrowserWindowControllersManager.shared.findControllerWith(window: window) else {
            return false
        }
        // Agent lock: while the agent controls this window, block every command
        // except Space navigation. The menu items are greyed and the shortcuts
        // swallowed in `handleKeyEquivalent`; this is the execution backstop for
        // anything that still reaches dispatch. Returning true = swallowed.
        if !agentLockAllowedCommands.contains(command), isWindowAgentLocked(window) {
            return true
        }
        // DevTools can't attach to the native NTP (no WebContents) — swallow the command.
        if nativeNtpBlockedCommands.contains(command),
           let tab = windowController.browserState.focusingTab,
           tab.isShowingNativeNTP {
            AppLogDebug("[DevToolsBlock] swallowed \(command) on native NTP")
            return true
        }

        switch command {
        case .IDC_HOME:
            guard !AgentAnimationManager.shared.isActive(for: windowController.browserState.focusingTab?.guid ?? 0) else {
                // disable home command when the current tab is excuting agent job
                return true
            }
            return false
        case .IDC_BACK:
            windowController.goBack(nil)
            return true
        case .IDC_FORWARD:
            windowController.goForward(nil)
            return true
        case .IDC_NEW_TAB:
            windowController.newBrowserTab(nil)
            return true
        case .IDC_NEW_TAB_TO_RIGHT:
            // Placeholder mode has no active tab, so "to the right" has no
            // meaning — fall back to a plain new tab. Outside placeholder,
            // let Chromium handle it normally (it operates on active_index()).
            if windowController.browserState.isInPlaceholderMode {
                windowController.newBrowserTab(nil)
                return true
            }
            return false
        case .IDC_CLOSE_TAB:
            // ⌘W closing the last tab in a Space tears the whole window
            // slot down — same as ⇧⌘W / the red ✕ — rather than switching
            // to a sibling Space. It therefore deliberately does NOT tag
            // the slot as a tab-driven close (only the tab-row ✕ button,
            // `Tab.close()`, still does): an untagged close reaches
            // `unregisterWindow` as window-driven and cascades every
            // remaining Space in the slot shut.
            return windowController.handleCloseTab()
        case .IDC_FOCUS_LOCATION:
            windowController.openLocationBar(nil)
            return true
        case .IDC_TAB_SEARCH:
            windowController.toggleSearchTabs()
            return true
        case .IDC_WINDOW_PIN_TAB:
            return true
        case .IDC_SELECT_PREVIOUS_TAB:
            windowController.browserState.swicthTab(.back)
            return true
        case .IDC_SELECT_NEXT_TAB:
            windowController.browserState.swicthTab(.forward)
            return true
        case .PHI_TAB_SWITCHER_FORWARD:
            windowController.browserState.tabSwitchManager.handleStep(.forward)
            return true
        case .PHI_TAB_SWITCHER_BACKWARD:
            windowController.browserState.tabSwitchManager.handleStep(.backward)
            return true
        case .PHI_SELECT_NEXT_SPACE:
            return activateSpace(by: 1, from: windowController)
        case .PHI_SELECT_PREVIOUS_SPACE:
            return activateSpace(by: -1, from: windowController)
        case .PHI_FARRINGDON_TOGGLE:
            guard FarringdonOrganizer.canOrganizeTabs(in: windowController.browserState) else {
                return false
            }
            FarringdonOrganizer.organizeFocusedWindow()
            return true
        case .PHI_COPY_URL:
            let state = windowController.browserState
            let copiedURLCount = state.selectedTabCountForURLCopy
            guard state.copySelectedTabURLs() else { return false }
            OverlayToastCenter.shared.showURLCopyConfirmation(copiedURLCount: copiedURLCount, in: state)
            return true
        case let c where c.spaceSelectionIndex != nil:
            guard let index = c.spaceSelectionIndex else { return false }
            return activateSpace(at: index, from: windowController)
        case .IDC_SELECT_LAST_TAB:
            windowController.browserState.swicthTab(.last)
            return true
        case .IDC_FOCUS_SEARCH:
            windowController.newBrowserTab(nil)
            return true
        case .IDC_FEEDBACK:
            windowController.showFeedbackWindow()
            return true
        case .IDC_IMPORT_SETTINGS:
            windowController.showImportDataWindow()
            return true
        case .IDC_BOOKMARK_THIS_TAB:
            windowController.toggleBookmark(nil)
            return true
        case let c where c.rawValue >= CommandWrapper.IDC_SELECT_TAB_0.rawValue && c.rawValue <= CommandWrapper.IDC_SELECT_TAB_7.rawValue:
            MainBrowserWindowControllersManager.shared.findControllerWith(window: window)?.selectTabWithIndex(c.rawValue - CommandWrapper.IDC_SELECT_TAB_0.rawValue)
            return true
        default: break
        }
        return false
    }

    @MainActor
    private static func activateSpace(by step: Int, from windowController: MainBrowserWindowController) -> Bool {
        guard spacesShortcutsEnabled else { return false }
        let spaces = SpaceManager.shared.spaces
        guard spaces.count > 1, let slot = windowController.slot else {
            return true
        }
        guard let currentId = slot.activeSpaceId,
              let currentIdx = spaces.firstIndex(where: { $0.spaceId == currentId }) else {
            slot.activate(spaceId: spaces[0].spaceId, userInitiated: true)
            return true
        }
        let nextIdx = (currentIdx + step + spaces.count) % spaces.count
        slot.activate(spaceId: spaces[nextIdx].spaceId, userInitiated: true)
        return true
    }

    @MainActor
    private static func activateSpace(at index: Int, from windowController: MainBrowserWindowController) -> Bool {
        guard spacesShortcutsEnabled else { return false }
        let spaces = SpaceManager.shared.spaces
        guard spaces.indices.contains(index),
              let slot = windowController.slot else {
            return false
        }
        slot.activate(spaceId: spaces[index].spaceId, userInitiated: true)
        return true
    }

    private static var spacesShortcutsEnabled: Bool {
        PhiPreferences.GeneralSettings.spacesFeatureEnabled.loadValue()
        && LoginController.shared.isLoggedin()
    }
    
    @MainActor
    static func handleKeyEquivalent(_ event: NSEvent, window: NSWindow) -> Bool {
        let modifiers = event.modifierFlags.intersection(shortcutModifierFlags)

        // Tab key may report different characters depending on Shift state.
        let isTabKey = event.keyCode == 48
        let characters: String
        if isTabKey {
            characters = "\t"
        } else {
            guard let chars = event.charactersIgnoringModifiers else { return false }
            characters = normalizedShortcutCharacters(chars)
        }

        let key = ShortcutsKey(characters: characters, modifiers: modifiers)

        // PHI-only commands: intercepted before Chromium sees the event.
        if let phiCommand = phiShortcutMap[key] {
            return dispatchCommand(phiCommand, to: window)
        }

        // Agent lock: swallow every other browser shortcut while the agent
        // controls this window, so Chromium never runs it. Space-navigation is
        // handled above and stays live, so the user can still leave the agent
        // Space with the keyboard.
        if isWindowAgentLocked(window) {
            return true
        }

        return false
    }

    private static func normalizedShortcutCharacters(_ characters: String) -> String {
        if characters == String(format: "%c", NSDeleteCharacter) {
            return String(format: "%c", NSBackspaceCharacter)
        }
        if characters.count > 1 {
            return String(characters.prefix(1)).lowercased()
        }
        return characters.lowercased()
    }
    
    @MainActor
    static func dispatchCommand(_ commandId: Int32, window: NSWindow) -> Bool {
        guard let command = CommandWrapper(rawValue: Int(commandId)) else {
            return false
        }
        AppLogDebug("will dispatch command: \(command)")
        return dispatchCommand(command, to: window)
    }
}

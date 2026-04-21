// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
struct CommandDispatcher {
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
    ]

    /// Commands swallowed while the focused tab shows the native NTP — it has no
    /// WebContents to inspect or view source of.
    private static let nativeNtpBlockedCommands: Set<CommandWrapper> = [
        .IDC_DEV_TOOLS,
        .IDC_DEV_TOOLS_INSPECT,
        .IDC_DEV_TOOLS_CONSOLE,
        .IDC_VIEW_SOURCE,
    ]

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
    
    @MainActor
    private static func dispatchCommand(_ command: CommandWrapper, to window: NSWindow) -> Bool {
        guard let windowController = MainBrowserWindowControllersManager.shared.findControllerWith(window: window) else {
            return false
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
        case .IDC_CLOSE_TAB:
            return windowController.handleCloseTab()
        case .IDC_FOCUS_LOCATION:
            windowController.openLocationBar(nil)
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
    static func handleKeyEquivalent(_ event: NSEvent, window: NSWindow) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Tab key may report different characters depending on Shift state.
        let isTabKey = event.keyCode == 48
        let characters: String
        if isTabKey {
            characters = "\t"
        } else {
            guard let chars = event.characters else { return false }
            characters = chars
        }

        let key = ShortcutsKey(characters: characters, modifiers: modifiers)

        // PHI-only commands: intercepted before Chromium sees the event.
        if let phiCommand = phiShortcutMap[key] {
            return dispatchCommand(phiCommand, to: window)
        }
        
        return false
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

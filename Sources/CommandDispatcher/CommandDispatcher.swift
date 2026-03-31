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
    
    static func dispatchCommand(_ sender: Any, window: NSWindow) -> Bool {
        guard let command = CommandWrapper(rawValue: (sender as AnyObject).tag) else {
            return false
        }
        return dispatchCommand(command, to: window)
    }
    
    private static func dispatchCommand(_ command: CommandWrapper, to window: NSWindow) -> Bool {
        guard let windowController = MainBrowserWindowControllersManager.shared.findControllerWith(window: window) else {
            return false
        }
        switch command {
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
    
    static func handleKeyEquivalent(_ event: NSEvent, window: NSWindow) -> Bool {
        // Most shortcuts are intercepted by Chromium and routed through `dispatchCommand(_:window:)`.
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard let characters = event.characters else {
            return false
        }
        if let command = shortcutCommandMap[.init(characters: characters, modifiers: modifiers)] {
            return dispatchCommand(command, to: window)
        } else {
            return false
        }
    }
    
    static func dispatchCommand(_ commandId: Int32, window: NSWindow) -> Bool {
        guard let command = CommandWrapper(rawValue: Int(commandId)) else {
            return false
        }
        AppLogDebug("will dispatch command: \(command)")
        return dispatchCommand(command, to: window)
    }
}

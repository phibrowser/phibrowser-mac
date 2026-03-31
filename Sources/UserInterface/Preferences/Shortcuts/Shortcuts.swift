// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import AppKit

struct Shortcuts {
    let command: CommandWrapper
    let key: ShortcutsKey
}

// chrome/app/chrome_command_ids.h
enum CommandWrapper: Int, Equatable {
    // App
    case IDC_OPTIONS                 = 40015
    case IDC_HIDE_APP                = 44003
    case IDC_EXIT                    = 34031
    case IDC_CLEAR_BROWSING_DATA     = 40013
    case IDC_IMPORT_SETTINGS         = 40014

    // File
    case IDC_NEW_TAB                 = 34014
    case IDC_NEW_WINDOW              = 34000
    case IDC_NEW_INCOGNITO_WINDOW    = 34001
    case IDC_RESTORE_TAB             = 34028
    case IDC_OPEN_FILE               = 40000
    case IDC_FOCUS_LOCATION          = 39001
    case IDC_CLOSE_WINDOW            = 34012
    case IDC_CLOSE_TAB               = 34015
    case IDC_SAVE_PAGE               = 35004
    case IDC_PRINT                   = 35003
    case IDC_BASIC_PRINT             = 35007

    // Edit
    case IDC_CONTENT_CONTEXT_UNDO                = 50154
    case IDC_CONTENT_CONTEXT_REDO                = 50155
    case IDC_CONTENT_CONTEXT_CUT                 = 50151
    case IDC_CONTENT_CONTEXT_COPY                = 50150
    case IDC_CONTENT_CONTEXT_PASTE               = 50152
    case IDC_CONTENT_CONTEXT_PASTE_AND_MATCH_STYLE = 50157
    case IDC_CONTENT_CONTEXT_SELECTALL           = 50156
    case IDC_FIND                                = 37000
    case IDC_FIND_NEXT                           = 37001
    case IDC_FIND_PREVIOUS                       = 37002
    case IDC_FOCUS_SEARCH                        = 39002

    // View
    case IDC_SHOW_BOOKMARK_BAR       = 40009
    case IDC_TOGGLE_FULLSCREEN_TOOLBAR = 40250
    case IDC_STOP                    = 33006
    case IDC_RELOAD                  = 33002
    case IDC_RELOAD_BYPASSING_CACHE  = 33007
    case IDC_FULLSCREEN              = 34030
    case IDC_ZOOM_NORMAL             = 38002
    case IDC_ZOOM_PLUS               = 38001
    case IDC_ZOOM_MINUS              = 38003
    case IDC_VIEW_SOURCE             = 35002
    case IDC_DEV_TOOLS               = 40004
    case IDC_DEV_TOOLS_INSPECT       = 40023
    case IDC_DEV_TOOLS_CONSOLE       = 40005

    // History
    case IDC_HOME                    = 33003
    case IDC_BACK                    = 33000
    case IDC_FORWARD                 = 33001
    case IDC_SHOW_HISTORY            = 40010

    // Bookmarks
    case IDC_SHOW_BOOKMARK_MANAGER   = 40011
    case IDC_BOOKMARK_THIS_TAB       = 35000
    case IDC_BOOKMARK_ALL_TABS       = 35001

    // Window
    case IDC_MINIMIZE_WINDOW         = 34046
    case IDC_SHOW_DOWNLOADS          = 40012
    case IDC_MANAGE_EXTENSIONS       = 40022
    case IDC_TASK_MANAGER            = 40006
    case IDC_ALL_WINDOWS_FRONT       = 34048

    // Tab
    case IDC_NEW_TAB_TO_RIGHT        = 35024
    case IDC_SELECT_NEXT_TAB         = 34016
    case IDC_SELECT_PREVIOUS_TAB     = 34017
    case IDC_SELECT_TAB_0            = 34018
    case IDC_SELECT_TAB_1            = 34019
    case IDC_SELECT_TAB_2            = 34020
    case IDC_SELECT_TAB_3            = 34021
    case IDC_SELECT_TAB_4            = 34022
    case IDC_SELECT_TAB_5            = 34023
    case IDC_SELECT_TAB_6            = 34024
    case IDC_SELECT_TAB_7            = 34025
    case IDC_SELECT_LAST_TAB         = 34026
    case IDC_DUPLICATE_TAB           = 34027
    case IDC_WINDOW_MUTE_SITE        = 35012
    case IDC_WINDOW_PIN_TAB          = 35013
    case IDC_WINDOW_GROUP_TAB        = 35014
    case IDC_WINDOW_CLOSE_OTHER_TABS = 35023
    case IDC_WINDOW_CLOSE_TABS_TO_RIGHT = 35022
    case IDC_MOVE_TAB_TO_NEW_WINDOW  = 34054
    case IDC_TAB_SEARCH              = 52500

    // Help
    case IDC_FEEDBACK                = 40008
    case IDC_HELP_PAGE_VIA_MENU      = 40020
    
    
    // Phi
    case PHI_TOGGLE_SIDEBAR          = 90000
    case PHI_TOGGLE_CHATBAR          = 90001
    
    // System Preserved
    case IDS_HIDE_OTHERS_MAC         = 110
    case IDS_CLOSE_ALL_WINDOWS_MAC   = 100  // alternate
    case IDS_PASTE_MATCH_STYLE_MAC   = 133  // alternate
    case IDS_EDIT_USE_SELECTION_MAC  = 141
    case IDS_EDIT_JUMP_TO_SELECTION_MAC = 142
    case IDS_EDIT_SHOW_SPELLING_GRAMMAR_MAC = 144
    case IDS_EDIT_CHECK_DOCUMENT_MAC = 145
}

struct ShortcutsKey: Hashable {
    let characters: String
    let modifiersRaw: UInt

    init(characters: String, modifiers: NSEvent.ModifierFlags) {
        self.characters = characters
        self.modifiersRaw = modifiers.rawValue
    }
}

extension Shortcuts {
    static let DefaultShortcuts: [CommandWrapper: ShortcutsKey] = [
        // App
        .IDC_OPTIONS: .init(characters: ",", modifiers: .command),

        // File
        .IDC_NEW_TAB: .init(characters: "t", modifiers: .command),
        .IDC_NEW_WINDOW: .init(characters: "n", modifiers: .command),
        .IDC_NEW_INCOGNITO_WINDOW: .init(characters: "n", modifiers: [.command, .shift]),
        .IDC_RESTORE_TAB: .init(characters: "t", modifiers: [.command, .shift]),
        .IDC_OPEN_FILE: .init(characters: "o", modifiers: .command),
        .IDC_FOCUS_LOCATION: .init(characters: "l", modifiers: .command),
        .IDC_CLOSE_WINDOW: .init(characters: "w", modifiers: [.command, .shift]),
        .IDC_CLOSE_TAB: .init(characters: "w", modifiers: .command),
//        .IDC_SAVE_PAGE: .init(characters: "s", modifiers: .command),
        .IDC_PRINT: .init(characters: "p", modifiers: .command),
        .IDC_BASIC_PRINT: .init(characters: "p", modifiers: [.command, .option]),

        // Edit
        .IDC_CONTENT_CONTEXT_UNDO: .init(characters: "z", modifiers: .command),
        .IDC_CONTENT_CONTEXT_REDO: .init(characters: "z", modifiers: [.command, .shift]),
        .IDC_CONTENT_CONTEXT_CUT: .init(characters: "x", modifiers: .command),
        .IDC_CONTENT_CONTEXT_COPY: .init(characters: "c", modifiers: .command),
        .IDC_CONTENT_CONTEXT_PASTE: .init(characters: "v", modifiers: .command),
        .IDC_CONTENT_CONTEXT_PASTE_AND_MATCH_STYLE: .init(characters: "v", modifiers: [.command, .shift, .option]),
        .IDC_CONTENT_CONTEXT_SELECTALL: .init(characters: "a", modifiers: .command),
        .IDC_FIND: .init(characters: "f", modifiers: .command),
        .IDC_FIND_NEXT: .init(characters: "g", modifiers: .command),
        .IDC_FIND_PREVIOUS: .init(characters: "g", modifiers: [.command, .shift]),
        .IDC_FOCUS_SEARCH: .init(characters: "f", modifiers: [.command, .option]),

        // View
        .IDC_SHOW_BOOKMARK_BAR: .init(characters: "b", modifiers: [.command, .shift]),
        .IDC_TOGGLE_FULLSCREEN_TOOLBAR: .init(characters: "f", modifiers: [.command, .shift]),
        .IDC_STOP: .init(characters: ".", modifiers: .command),
        .IDC_RELOAD: .init(characters: "r", modifiers: .command),
        .IDC_RELOAD_BYPASSING_CACHE: .init(characters: "r", modifiers: [.command, .shift]),
        .IDC_FULLSCREEN: .init(characters: "f", modifiers: [.command, .control]),
        .IDC_ZOOM_NORMAL: .init(characters: "0", modifiers: .command),
        .IDC_ZOOM_PLUS: .init(characters: "+", modifiers: .command),
        .IDC_ZOOM_MINUS: .init(characters: "-", modifiers: .command),
        .IDC_VIEW_SOURCE: .init(characters: "u", modifiers: [.command, .option]),
        .IDC_DEV_TOOLS: .init(characters: "i", modifiers: [.command, .option]),
        .IDC_DEV_TOOLS_INSPECT: .init(characters: "c", modifiers: [.command, .option]),
        .IDC_DEV_TOOLS_CONSOLE: .init(characters: "j", modifiers: [.command, .option]),

        // History
        .IDC_HOME: .init(characters: "h", modifiers: [.command, .shift]),
        .IDC_BACK: .init(characters: "[", modifiers: .command),
        .IDC_FORWARD: .init(characters: "]", modifiers: .command),
        .IDC_SHOW_HISTORY: .init(characters: "y", modifiers: .command),

        // Bookmarks
        .IDC_SHOW_BOOKMARK_MANAGER: .init(characters: "b", modifiers: [.command, .option]),
        .IDC_BOOKMARK_THIS_TAB: .init(characters: "d", modifiers: .command),
        .IDC_BOOKMARK_ALL_TABS: .init(characters: "d", modifiers: [.command, .shift]),

        // Window
        .IDC_MINIMIZE_WINDOW: .init(characters: "m", modifiers: .command),
        .IDC_SHOW_DOWNLOADS: .init(characters: "j", modifiers: [.command, .shift]),

        // Tab
        .IDC_SELECT_NEXT_TAB: .init(characters: "\t", modifiers: .control),
        .IDC_SELECT_PREVIOUS_TAB: .init(characters: "\t", modifiers: [.control, .shift]),
        .IDC_SELECT_TAB_0: .init(characters: "1", modifiers: .command),
        .IDC_SELECT_TAB_1: .init(characters: "2", modifiers: .command),
        .IDC_SELECT_TAB_2: .init(characters: "3", modifiers: .command),
        .IDC_SELECT_TAB_3: .init(characters: "4", modifiers: .command),
        .IDC_SELECT_TAB_4: .init(characters: "5", modifiers: .command),
        .IDC_SELECT_TAB_5: .init(characters: "6", modifiers: .command),
        .IDC_SELECT_TAB_6: .init(characters: "7", modifiers: .command),
        .IDC_SELECT_TAB_7: .init(characters: "8", modifiers: .command),
        .IDC_SELECT_LAST_TAB: .init(characters: "9", modifiers: .command),
        .IDC_TAB_SEARCH: .init(characters: "a", modifiers: [.command, .shift]),

        // Help
        .IDC_FEEDBACK: .init(characters: "i", modifiers: [.command, .option, .shift]),
        .IDC_HELP_PAGE_VIA_MENU: .init(characters: "?", modifiers: .command),
        
        
        // PHI
        .PHI_TOGGLE_SIDEBAR: .init(characters: "s", modifiers: [.command]),
        .PHI_TOGGLE_CHATBAR: .init(characters: "s", modifiers: [.command, .shift]),
        
        // System Preserved Shortcuts
        .IDS_HIDE_OTHERS_MAC: .init(characters: "h", modifiers: [.command, .option]),
        .IDS_CLOSE_ALL_WINDOWS_MAC: .init(characters: "w", modifiers: [.command, .option, .shift]), // alternate
        .IDS_PASTE_MATCH_STYLE_MAC: .init(characters: "v", modifiers: [.command, .option]),         // alternate
        .IDS_EDIT_USE_SELECTION_MAC: .init(characters: "e", modifiers: [.command]),
        .IDS_EDIT_JUMP_TO_SELECTION_MAC: .init(characters: "j", modifiers: [.command]),
        .IDS_EDIT_SHOW_SPELLING_GRAMMAR_MAC: .init(characters: ":", modifiers: [.command]),
        .IDS_EDIT_CHECK_DOCUMENT_MAC: .init(characters: ";", modifiers: [.command]),
        .IDC_HIDE_APP: .init(characters: "h", modifiers: [.command]),
    ]
}

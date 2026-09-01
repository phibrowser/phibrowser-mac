// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import AppKit
import Carbon.HIToolbox

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
    case IDC_NEW_SPLIT_TAB           = 34057
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
    case PHI_TAB_SWITCHER_FORWARD    = 90002
    case PHI_TAB_SWITCHER_BACKWARD   = 90003
    case PHI_NEW_CONVERSATION        = 90004
    case PHI_SELECT_NEXT_SPACE       = 90005
    case PHI_SELECT_PREVIOUS_SPACE   = 90006
    case PHI_SELECT_SPACE_0          = 90010
    case PHI_SELECT_SPACE_1          = 90011
    case PHI_SELECT_SPACE_2          = 90012
    case PHI_SELECT_SPACE_3          = 90013
    case PHI_SELECT_SPACE_4          = 90014
    case PHI_SELECT_SPACE_5          = 90015
    case PHI_SELECT_SPACE_6          = 90016
    case PHI_SELECT_SPACE_7          = 90017
    case PHI_SELECT_SPACE_8          = 90018
    case PHI_FARRINGDON_TOGGLE       = 90019
    case PHI_COPY_URL                = 90020
    case PHI_TOGGLE_READER           = 90021
    case PHI_NEW_KIOSK_WINDOW        = 90022
    case PHI_NEW_INCOGNITO_SPACE     = 90023

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
    struct EventKeys {
        let canonical: ShortcutsKey
        let legacy: ShortcutsKey?

        var matchingKeys: [ShortcutsKey] {
            if let legacy {
                return [canonical, legacy]
            }
            return [canonical]
        }
    }

    struct MenuKeyEquivalent: Equatable {
        let characters: String
        let modifiers: NSEvent.ModifierFlags
    }

    static let supportedModifierFlags: NSEvent.ModifierFlags = [
        .command,
        .option,
        .shift,
        .control,
    ]

    /// Chromium's Command-QWERTY layouts resolve shortcuts from the physical
    /// ANSI key instead of the active layout's semantic character.
    private static let qwertyLetterByANSIKeyCode: [UInt16: String] = [
        UInt16(kVK_ANSI_A): "a", UInt16(kVK_ANSI_B): "b",
        UInt16(kVK_ANSI_C): "c", UInt16(kVK_ANSI_D): "d",
        UInt16(kVK_ANSI_E): "e", UInt16(kVK_ANSI_F): "f",
        UInt16(kVK_ANSI_G): "g", UInt16(kVK_ANSI_H): "h",
        UInt16(kVK_ANSI_I): "i", UInt16(kVK_ANSI_J): "j",
        UInt16(kVK_ANSI_K): "k", UInt16(kVK_ANSI_L): "l",
        UInt16(kVK_ANSI_M): "m", UInt16(kVK_ANSI_N): "n",
        UInt16(kVK_ANSI_O): "o", UInt16(kVK_ANSI_P): "p",
        UInt16(kVK_ANSI_Q): "q", UInt16(kVK_ANSI_R): "r",
        UInt16(kVK_ANSI_S): "s", UInt16(kVK_ANSI_T): "t",
        UInt16(kVK_ANSI_U): "u", UInt16(kVK_ANSI_V): "v",
        UInt16(kVK_ANSI_W): "w", UInt16(kVK_ANSI_X): "x",
        UInt16(kVK_ANSI_Y): "y", UInt16(kVK_ANSI_Z): "z",
    ]

    /// Chromium derives these US-ANSI unshifted/shifted characters from the
    /// Carbon key code; keeping both forms is required for keys such as ] / }.
    private static let qwertyNonLetterByANSIKeyCode:
        [UInt16: (unshifted: String, shifted: String)] = [
            UInt16(kVK_ANSI_0): ("0", ")"),
            UInt16(kVK_ANSI_1): ("1", "!"),
            UInt16(kVK_ANSI_2): ("2", "@"),
            UInt16(kVK_ANSI_3): ("3", "#"),
            UInt16(kVK_ANSI_4): ("4", "$"),
            UInt16(kVK_ANSI_5): ("5", "%"),
            UInt16(kVK_ANSI_6): ("6", "^"),
            UInt16(kVK_ANSI_7): ("7", "&"),
            UInt16(kVK_ANSI_8): ("8", "*"),
            UInt16(kVK_ANSI_9): ("9", "("),
            UInt16(kVK_ANSI_Grave): ("`", "~"),
            UInt16(kVK_ANSI_Minus): ("-", "_"),
            UInt16(kVK_ANSI_Equal): ("=", "+"),
            UInt16(kVK_ANSI_LeftBracket): ("[", "{"),
            UInt16(kVK_ANSI_RightBracket): ("]", "}"),
            UInt16(kVK_ANSI_Backslash): ("\\", "|"),
            UInt16(kVK_ANSI_Semicolon): (";", ":"),
            UInt16(kVK_ANSI_Quote): ("'", "\""),
            UInt16(kVK_ANSI_Comma): (",", "<"),
            UInt16(kVK_ANSI_Period): (".", ">"),
            UInt16(kVK_ANSI_Slash): ("/", "?"),
        ]

    /// Chromium switches these layouts to physical ANSI/QWERTY printable keys
    /// while Command is held.
    private static let commandQWERTYInputSourceIdentifiers: Set<String> = [
        "com.apple.keylayout.DVORAK-QWERTYCMD",
        "com.apple.keylayout.Dhivehi-QWERTY",
        "com.apple.keylayout.Inuktitut-QWERTY",
        "com.apple.keylayout.Cherokee-QWERTY",
    ]

    let characters: String
    let modifiersRaw: UInt

    init(characters: String, modifiers: NSEvent.ModifierFlags) {
        self.characters = characters
        self.modifiersRaw = modifiers.rawValue
    }

    /// AppKit encodes Shift in printable key equivalents instead of the modifier mask.
    var menuKeyEquivalent: MenuKeyEquivalent {
        var menuModifiers = modifiers
        guard menuModifiers.contains(.shift), isPrintableMenuCharacter else {
            return MenuKeyEquivalent(characters: characters, modifiers: menuModifiers)
        }

        menuModifiers.remove(.shift)
        return MenuKeyEquivalent(
            characters: characters.uppercased(),
            modifiers: menuModifiers
        )
    }

    /// Resolves the ordered identities that shortcut recording and native
    /// dispatch share.
    static func eventKeys(
        for event: NSEvent,
        inputSourceIdentifier: String? = currentInputSourceIdentifier
    ) -> EventKeys? {
        let modifiers = event.modifierFlags.intersection(supportedModifierFlags)
        let semanticKey = semanticEventKey(for: event, modifiers: modifiers)
        let latinKey = latinEventKey(
            for: event,
            modifiers: modifiers,
            inputSourceIdentifier: inputSourceIdentifier
        )

        guard let canonical = latinKey ?? semanticKey else { return nil }
        // Prefer the layout-independent Latin key for new recordings and command
        // lookup, while retaining the semantic key for existing non-Latin overrides.
        let legacy = semanticKey.flatMap { $0 == canonical ? nil : $0 }
        return EventKeys(canonical: canonical, legacy: legacy)
    }

    /// Returns the canonical key to persist for a captured event.
    static func recordingKey(
        for event: NSEvent,
        inputSourceIdentifier: String? = currentInputSourceIdentifier
    ) -> ShortcutsKey? {
        guard let key = eventKeys(
            for: event,
            inputSourceIdentifier: inputSourceIdentifier
        )?.canonical,
              key.modifiersRaw != 0 else {
            return nil
        }
        return key
    }

    static func resolvedInputSourceIdentifier(
        textInputContextIdentifier: String?,
        systemInputSourceIdentifier: () -> String?
    ) -> String? {
        if let textInputContextIdentifier {
            return textInputContextIdentifier
        }
        return systemInputSourceIdentifier()
    }

    private static var currentInputSourceIdentifier: String? {
        // The focused text context is the most precise source, but it can be nil
        // when focus is outside an editable responder. TIS supplies Chromium's
        // process-wide fallback for that case.
        resolvedInputSourceIdentifier(
            textInputContextIdentifier:
                NSTextInputContext.current?.selectedKeyboardInputSource,
            systemInputSourceIdentifier: { currentSystemInputSourceIdentifier }
        )
    }

    private static var currentSystemInputSourceIdentifier: String? {
        let inputSource = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let property = TISGetInputSourceProperty(
            inputSource,
            kTISPropertyInputSourceID
        ) else {
            return nil
        }
        return Unmanaged<CFString>
            .fromOpaque(property)
            .takeUnretainedValue() as String
    }

    private static func semanticEventKey(
        for event: NSEvent,
        modifiers: NSEvent.ModifierFlags
    ) -> ShortcutsKey? {
        // `charactersIgnoringModifiers` still reflects the active input source,
        // so a non-Latin layout returns its local-script character here.
        // Tab may also report different characters depending on Shift state.
        if event.keyCode == UInt16(kVK_Tab) {
            return ShortcutsKey(characters: "\t", modifiers: modifiers)
        }
        guard let characters = event.charactersIgnoringModifiers,
              !characters.isEmpty else {
            return nil
        }
        return ShortcutsKey(
            characters: normalizedCharacters(characters),
            modifiers: modifiers
        )
    }

    private static func latinEventKey(
        for event: NSEvent,
        modifiers: NSEvent.ModifierFlags,
        inputSourceIdentifier: String?
    ) -> ShortcutsKey? {
        let charactersIgnoringModifiers = event.charactersIgnoringModifiers ?? ""
        let usesNonASCIICharacters = charactersIgnoringModifiers.utf16.first
            .map { $0 > 0x7F } == true
        // Some Apple Hebrew layouts report ASCII punctuation for letter keys,
        // so script inspection alone cannot identify them.
        let usesHebrewLayout = inputSourceIdentifier?
            .hasPrefix("com.apple.keylayout.Hebrew") == true
        let usesCommandQWERTYLayout = inputSourceIdentifier
            .map(commandQWERTYInputSourceIdentifiers.contains) == true

        // Some non-Latin layouts expose the menu-equivalent Latin character
        // through `characters` while `charactersIgnoringModifiers` stays local.
        // Do not use `characters` for ordinary ASCII-to-ASCII differences: those
        // can represent intentional semantic layouts such as Dvorak.
        if let characters = event.characters,
           characters.utf16.count == 1,
           let character = characters.utf16.first,
           character >= 0x20,
           character <= 0x7E {
            // Mirror Chromium's observed AppKit exceptions for Hebrew Cmd-Q and
            // Arabic PC/AZERTY Shift-Cmd-V. Both event strings are ASCII, so the
            // input-source ID must distinguish them from intentional ASCII maps.
            let usesHebrewCommandEquivalent = modifiers.contains(.command)
                && usesHebrewLayout
                && charactersIgnoringModifiers == "/"
                && characters == "q"
            let usesArabicCommandEquivalent = modifiers.contains(.command)
                && (inputSourceIdentifier?.hasPrefix("com.apple.keylayout.ArabicPC") == true
                    || inputSourceIdentifier?.hasPrefix("com.apple.keylayout.Arabic-AZERTY") == true)
                && charactersIgnoringModifiers == "{"
                && characters == "V"
            let usesASCIIEquivalent = charactersIgnoringModifiers.isEmpty
                || usesNonASCIICharacters
                || usesHebrewCommandEquivalent
                || usesArabicCommandEquivalent
            if usesASCIIEquivalent {
                return ShortcutsKey(
                    characters: normalizedCharacters(characters),
                    modifiers: modifiers
                )
            }
        }

        // Match Chromium's main-keyboard Command-QWERTY projection while
        // Command is held. This is deliberately source-qualified; applying
        // physical QWERTY to a normal Dvorak or non-Latin layout would change
        // semantic shortcuts.
        // TODO: Chromium applies this projection for every modifier combination.
        // Non-Command custom IDC shortcuts can therefore mismatch on these rare
        // layouts; mirror Chromium if Phi needs to support that configuration.
        guard modifiers.contains(.command),
              usesCommandQWERTYLayout,
              let qwertyCharacter = commandQWERTYCharacter(
                keyCode: event.keyCode,
                shifted: modifiers.contains(.shift)
              ) else {
            return nil
        }
        return ShortcutsKey(
            characters: normalizedCharacters(qwertyCharacter),
            modifiers: modifiers
        )
    }

    private static func commandQWERTYCharacter(
        keyCode: UInt16,
        shifted: Bool
    ) -> String? {
        if let letter = qwertyLetterByANSIKeyCode[keyCode] {
            return shifted ? letter.uppercased() : letter
        }
        guard let characters = qwertyNonLetterByANSIKeyCode[keyCode] else {
            return nil
        }
        return shifted ? characters.shifted : characters.unshifted
    }

    private static func normalizedCharacters(_ characters: String) -> String {
        if characters == String(format: "%c", NSDeleteCharacter) {
            return String(format: "%c", NSBackspaceCharacter)
        }
        if characters.count > 1 {
            return String(characters.prefix(1)).lowercased()
        }
        return characters.lowercased()
    }

    /// Resolves the Carbon virtual key used by system-wide hot-key
    /// registration. Printable shortcuts use the same ANSI identities as the
    /// Chromium shortcut bridge; AppKit function-key characters are mapped to
    /// their corresponding hardware keys.
    var carbonVirtualKeyCode: UInt32? {
        let normalized = characters.lowercased()
        if let keyCode = Self.qwertyLetterByANSIKeyCode.first(where: {
            $0.value == normalized
        })?.key {
            return UInt32(keyCode)
        }
        if let keyCode = Self.qwertyNonLetterByANSIKeyCode.first(where: {
            $0.value.unshifted == characters || $0.value.shifted == characters
        })?.key {
            return UInt32(keyCode)
        }

        switch characters {
        case " ": return UInt32(kVK_Space)
        case "\t": return UInt32(kVK_Tab)
        case "\r": return UInt32(kVK_Return)
        case String(format: "%c", NSBackspaceCharacter):
            return UInt32(kVK_Delete)
        case "\u{F700}": return UInt32(kVK_UpArrow)
        case "\u{F701}": return UInt32(kVK_DownArrow)
        case "\u{F702}": return UInt32(kVK_LeftArrow)
        case "\u{F703}": return UInt32(kVK_RightArrow)
        case "\u{F704}": return UInt32(kVK_F1)
        case "\u{F705}": return UInt32(kVK_F2)
        case "\u{F706}": return UInt32(kVK_F3)
        case "\u{F707}": return UInt32(kVK_F4)
        case "\u{F708}": return UInt32(kVK_F5)
        case "\u{F709}": return UInt32(kVK_F6)
        case "\u{F70A}": return UInt32(kVK_F7)
        case "\u{F70B}": return UInt32(kVK_F8)
        case "\u{F70C}": return UInt32(kVK_F9)
        case "\u{F70D}": return UInt32(kVK_F10)
        case "\u{F70E}": return UInt32(kVK_F11)
        case "\u{F70F}": return UInt32(kVK_F12)
        case "\u{F710}": return UInt32(kVK_F13)
        case "\u{F711}": return UInt32(kVK_F14)
        case "\u{F712}": return UInt32(kVK_F15)
        case "\u{F713}": return UInt32(kVK_F16)
        case "\u{F714}": return UInt32(kVK_F17)
        case "\u{F715}": return UInt32(kVK_F18)
        case "\u{F716}": return UInt32(kVK_F19)
        case "\u{F717}": return UInt32(kVK_F20)
        case "\u{F728}": return UInt32(kVK_ForwardDelete)
        case "\u{F729}": return UInt32(kVK_Home)
        case "\u{F72B}": return UInt32(kVK_End)
        case "\u{F72C}": return UInt32(kVK_PageUp)
        case "\u{F72D}": return UInt32(kVK_PageDown)
        case "\u{F746}": return UInt32(kVK_Help)
        default: return nil
        }
    }

    private var isPrintableMenuCharacter: Bool {
        guard characters.unicodeScalars.count == 1,
              let scalar = characters.unicodeScalars.first else {
            return false
        }
        return !CharacterSet.controlCharacters.contains(scalar)
            && !(0xF700...0xF8FF).contains(scalar.value)
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
        // AppKit events carry Shift in printable characters. Keep Shift in the
        // stored identity for display, but store the actual shifted character so
        // `menuKeyEquivalent` can remove the modifier without guessing a layout.
        .IDC_SELECT_NEXT_TAB: .init(characters: "}", modifiers: [.command, .shift]),
        .IDC_SELECT_PREVIOUS_TAB: .init(characters: "{", modifiers: [.command, .shift]),
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
        .PHI_TAB_SWITCHER_FORWARD: .init(characters: "\t", modifiers: .control),
        .PHI_TAB_SWITCHER_BACKWARD: .init(characters: "\t", modifiers: [.control, .shift]),
        .PHI_NEW_CONVERSATION: .init(characters: "o", modifiers: [.command, .shift]),
        .PHI_SELECT_NEXT_SPACE: .init(characters: "\u{F703}", modifiers: [.command, .option]),
        .PHI_SELECT_PREVIOUS_SPACE: .init(characters: "\u{F702}", modifiers: [.command, .option]),
        .PHI_SELECT_SPACE_0: .init(characters: "1", modifiers: .control),
        .PHI_SELECT_SPACE_1: .init(characters: "2", modifiers: .control),
        .PHI_SELECT_SPACE_2: .init(characters: "3", modifiers: .control),
        .PHI_SELECT_SPACE_3: .init(characters: "4", modifiers: .control),
        .PHI_SELECT_SPACE_4: .init(characters: "5", modifiers: .control),
        .PHI_SELECT_SPACE_5: .init(characters: "6", modifiers: .control),
        .PHI_SELECT_SPACE_6: .init(characters: "7", modifiers: .control),
        .PHI_SELECT_SPACE_7: .init(characters: "8", modifiers: .control),
        .PHI_SELECT_SPACE_8: .init(characters: "9", modifiers: .control),
        .PHI_FARRINGDON_TOGGLE: .init(characters: "g", modifiers: [.control, .shift]),
        .PHI_COPY_URL: .init(characters: "c", modifiers: [.command, .shift]),
        // Safari's Reader shortcut is Cmd-Shift-R, which Chromium already
        // binds to hard reload. Cmd-Opt-R keeps Reader View next to the
        // reload family without displacing it.
        .PHI_TOGGLE_READER: .init(characters: "r", modifiers: [.command, .option]),
        .PHI_NEW_KIOSK_WINDOW: .init(characters: "n", modifiers: [.command, .option]),
        .PHI_NEW_INCOGNITO_SPACE: .init(characters: "n", modifiers: [.control, .shift]),

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

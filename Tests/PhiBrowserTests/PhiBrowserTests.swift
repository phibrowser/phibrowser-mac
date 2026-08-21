// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
import AppKit
import Carbon.HIToolbox
import SwiftUI
@testable import Phi

final class PhiBrowserTests: XCTestCase {
    private enum InputSource {
        static let us = "com.apple.keylayout.US"
        static let russian = "com.apple.keylayout.Russian"
        static let dvorak = "com.apple.keylayout.Dvorak"
        static let dvorakCommandQWERTY = "com.apple.keylayout.DVORAK-QWERTYCMD"
        static let hebrewQWERTY = "com.apple.keylayout.Hebrew-QWERTY"
        static let arabicAZERTY = "com.apple.keylayout.Arabic-AZERTY"
    }

    private func makeShortcutKeyEvent(
        characters: String,
        charactersIgnoringModifiers: String,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16 = UInt16(kVK_ANSI_C)
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: charactersIgnoringModifiers,
                isARepeat: false,
                keyCode: keyCode
            )
        )
    }

    func testCopyURLShortcutIsCustomizableFromEditShortcuts() {
        XCTAssertEqual(
            Shortcuts.DefaultShortcuts[.PHI_COPY_URL],
            ShortcutsKey(characters: "c", modifiers: [.command, .shift])
        )
        XCTAssertTrue(Shortcuts.Group.edit.commands.contains(.PHI_COPY_URL))
        XCTAssertEqual(CommandWrapper.PHI_COPY_URL.displayName, "Copy URL")
    }

    func testInputSourceIdentifierSelectionPrefersTextContextAndUsesSystemFallback() {
        var systemLookupCount = 0
        XCTAssertEqual(
            ShortcutsKey.resolvedInputSourceIdentifier(
                textInputContextIdentifier: InputSource.russian,
                systemInputSourceIdentifier: {
                    systemLookupCount += 1
                    return InputSource.hebrewQWERTY
                }
            ),
            InputSource.russian
        )
        XCTAssertEqual(systemLookupCount, 0)
        XCTAssertEqual(
            ShortcutsKey.resolvedInputSourceIdentifier(
                textInputContextIdentifier: nil,
                systemInputSourceIdentifier: {
                    systemLookupCount += 1
                    return InputSource.hebrewQWERTY
                }
            ),
            InputSource.hebrewQWERTY
        )
        XCTAssertEqual(systemLookupCount, 1)
    }

    func testPhiShortcutMatchingFallsBackToASCIICommandCharacterForCyrillicInputSource() throws {
        let event = try makeShortcutKeyEvent(
            characters: "C",
            charactersIgnoringModifiers: "\u{0421}",
            modifiers: [.command, .shift]
        )
        let copyURLKey = try XCTUnwrap(Shortcuts.DefaultShortcuts[.PHI_COPY_URL])

        let command = CommandDispatcher.matchedPhiCommand(
            for: event,
            shortcutMap: [copyURLKey: .PHI_COPY_URL],
            inputSourceIdentifier: InputSource.russian
        )

        XCTAssertEqual(command, .PHI_COPY_URL)
    }

    func testCyrillicCommandCaptureMatchesLatinDefaultShortcut() throws {
        let event = try makeShortcutKeyEvent(
            characters: "C",
            charactersIgnoringModifiers: "\u{0421}",
            modifiers: [.command, .shift]
        )
        let recordedKey = try XCTUnwrap(
            ShortcutsKey.recordingKey(
                for: event,
                inputSourceIdentifier: InputSource.russian
            )
        )
        let copyURLKey = try XCTUnwrap(Shortcuts.DefaultShortcuts[.PHI_COPY_URL])

        XCTAssertEqual(recordedKey, copyURLKey)
        XCTAssertEqual(recordedKey.characters, "c")
        XCTAssertEqual(recordedKey.displayString, "⌘⇧C")
    }

    func testCyrillicCommandCaptureUsesLatinShiftedMenuEquivalent() throws {
        let event = try makeShortcutKeyEvent(
            characters: "P",
            charactersIgnoringModifiers: "\u{0417}",
            modifiers: [.command, .shift],
            keyCode: UInt16(kVK_ANSI_P)
        )

        let recordedKey = try XCTUnwrap(
            ShortcutsKey.recordingKey(
                for: event,
                inputSourceIdentifier: InputSource.russian
            )
        )
        let menuKey = recordedKey.menuKeyEquivalent

        XCTAssertEqual(recordedKey.characters, "p")
        XCTAssertEqual(recordedKey.modifiers, [.command, .shift])
        XCTAssertEqual(recordedKey.displayString, "⌘⇧P")
        XCTAssertEqual(menuKey.characters, "P")
        XCTAssertEqual(menuKey.modifiers, [.command])
    }

    func testShiftedPrintableShortcutProjectsToSameMenuIdentity() {
        let recordedKey = ShortcutsKey(
            characters: "+",
            modifiers: [.command, .shift]
        )
        let existingKey = ShortcutsKey(characters: "+", modifiers: [.command])

        XCTAssertEqual(recordedKey.menuKeyEquivalent, existingKey.menuKeyEquivalent)
    }

    func testShortcutViewModelReportsMenuEquivalentConflict() throws {
        let previousOverrides = Shortcuts.overridedShortcuts
        defer { Shortcuts.overridedShortcuts = previousOverrides }
        Shortcuts.overridedShortcuts = [
            .IDC_BACK: ShortcutsKey(
                characters: "+",
                modifiers: [.command, .shift]
            ),
            .IDC_FORWARD: ShortcutsKey(
                characters: "+",
                modifiers: [.command]
            ),
        ]

        let viewModel = ShortcutsViewModel()
        let items = viewModel.sections.flatMap(\.items)
        let backItem = try XCTUnwrap(
            items.first { $0.command == .IDC_BACK }
        )
        let forwardItem = try XCTUnwrap(
            items.first { $0.command == .IDC_FORWARD }
        )

        XCTAssertTrue(backItem.hasConflict)
        XCTAssertTrue(forwardItem.hasConflict)
    }

    func testShiftedBracketDefaultsUseDistinctAppKitMenuIdentities() throws {
        let backKey = try XCTUnwrap(Shortcuts.DefaultShortcuts[.IDC_BACK])
        let forwardKey = try XCTUnwrap(Shortcuts.DefaultShortcuts[.IDC_FORWARD])
        let previousTabKey = try XCTUnwrap(
            Shortcuts.DefaultShortcuts[.IDC_SELECT_PREVIOUS_TAB]
        )
        let nextTabKey = try XCTUnwrap(
            Shortcuts.DefaultShortcuts[.IDC_SELECT_NEXT_TAB]
        )

        XCTAssertEqual(previousTabKey.characters, "{")
        XCTAssertEqual(previousTabKey.modifiers, [.command, .shift])
        XCTAssertEqual(previousTabKey.menuKeyEquivalent.characters, "{")
        XCTAssertEqual(previousTabKey.menuKeyEquivalent.modifiers, [.command])
        XCTAssertNotEqual(previousTabKey.menuKeyEquivalent, backKey.menuKeyEquivalent)

        XCTAssertEqual(nextTabKey.characters, "}")
        XCTAssertEqual(nextTabKey.modifiers, [.command, .shift])
        XCTAssertEqual(nextTabKey.menuKeyEquivalent.characters, "}")
        XCTAssertEqual(nextTabKey.menuKeyEquivalent.modifiers, [.command])
        XCTAssertNotEqual(nextTabKey.menuKeyEquivalent, forwardKey.menuKeyEquivalent)
    }

    func testShiftedBracketCaptureMatchesDefaultNextTabShortcut() throws {
        let event = try makeShortcutKeyEvent(
            characters: "]",
            charactersIgnoringModifiers: "}",
            modifiers: [.command, .shift],
            keyCode: UInt16(kVK_ANSI_RightBracket)
        )

        let recordedKey = try XCTUnwrap(
            ShortcutsKey.recordingKey(
                for: event,
                inputSourceIdentifier: InputSource.us
            )
        )

        XCTAssertEqual(
            recordedKey,
            Shortcuts.DefaultShortcuts[.IDC_SELECT_NEXT_TAB]
        )
    }

    func testShortcutViewModelPresentsBracketDefaultsWithoutFalseConflicts() throws {
        let previousOverrides = Shortcuts.overridedShortcuts
        defer { Shortcuts.overridedShortcuts = previousOverrides }
        Shortcuts.overridedShortcuts = [:]

        let viewModel = ShortcutsViewModel()
        let items = viewModel.sections.flatMap(\.items)
        let previousTabItem = try XCTUnwrap(
            items.first { $0.command == .IDC_SELECT_PREVIOUS_TAB }
        )
        let nextTabItem = try XCTUnwrap(
            items.first { $0.command == .IDC_SELECT_NEXT_TAB }
        )

        XCTAssertEqual(previousTabItem.shortcutDisplay, "⌘⇧[")
        XCTAssertFalse(previousTabItem.hasConflict)
        XCTAssertEqual(nextTabItem.shortcutDisplay, "⌘⇧]")
        XCTAssertFalse(nextTabItem.hasConflict)
    }

    func testNativeMenuWriterProjectsDefaultShiftedPrintableShortcut() {
        let command = CommandWrapper.PHI_TOGGLE_CHATBAR
        let previousOverrides = Shortcuts.overridedShortcuts
        defer { Shortcuts.overridedShortcuts = previousOverrides }
        Shortcuts.overridedShortcuts.removeValue(forKey: command)

        let item = NSMenuItem(
            title: "Toggle Chatbar",
            action: nil,
            keyEquivalent: "s"
        )
        item.tag = command.rawValue
        item.keyEquivalentModifierMask = [.command, .shift]

        Shortcuts.updateShortcut(for: item)

        XCTAssertEqual(item.keyEquivalent, "S")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command])
    }

    func testPhiShortcutMatchingUsesShiftedPrintableExecutionIdentity() throws {
        let event = try makeShortcutKeyEvent(
            characters: "+",
            charactersIgnoringModifiers: "+",
            modifiers: [.command, .shift],
            keyCode: UInt16(kVK_ANSI_Equal)
        )
        let existingKey = ShortcutsKey(characters: "+", modifiers: [.command])

        XCTAssertEqual(
            CommandDispatcher.matchedPhiCommand(
                for: event,
                shortcutMap: [existingKey: .PHI_COPY_URL],
                inputSourceIdentifier: InputSource.us
            ),
            .PHI_COPY_URL
        )
    }

    func testLatinAndCyrillicEventsResolveToSameCanonicalShortcut() throws {
        let latinEvent = try makeShortcutKeyEvent(
            characters: "C",
            charactersIgnoringModifiers: "C",
            modifiers: [.command, .shift]
        )
        let cyrillicEvent = try makeShortcutKeyEvent(
            characters: "C",
            charactersIgnoringModifiers: "\u{0421}",
            modifiers: [.command, .shift]
        )
        let latinKeys = try XCTUnwrap(
            ShortcutsKey.eventKeys(
                for: latinEvent,
                inputSourceIdentifier: InputSource.us
            )
        )
        let cyrillicKeys = try XCTUnwrap(
            ShortcutsKey.eventKeys(
                for: cyrillicEvent,
                inputSourceIdentifier: InputSource.russian
            )
        )
        let shortcutMap = [latinKeys.canonical: CommandWrapper.PHI_COPY_URL]

        XCTAssertEqual(cyrillicKeys.canonical, latinKeys.canonical)
        XCTAssertNil(latinKeys.legacy)
        XCTAssertEqual(
            cyrillicKeys.legacy,
            ShortcutsKey(characters: "\u{0441}", modifiers: [.command, .shift])
        )
        XCTAssertEqual(
            CommandDispatcher.matchedPhiCommand(
                for: latinEvent,
                shortcutMap: shortcutMap,
                inputSourceIdentifier: InputSource.us
            ),
            .PHI_COPY_URL
        )
        XCTAssertEqual(
            CommandDispatcher.matchedPhiCommand(
                for: cyrillicEvent,
                shortcutMap: shortcutMap,
                inputSourceIdentifier: InputSource.russian
            ),
            .PHI_COPY_URL
        )
    }

    func testPhiShortcutMatchingPrefersCanonicalLatinBinding() throws {
        let event = try makeShortcutKeyEvent(
            characters: "C",
            charactersIgnoringModifiers: "\u{0421}",
            modifiers: [.command, .shift]
        )
        let cyrillicKey = ShortcutsKey(
            characters: "\u{0441}",
            modifiers: [.command, .shift]
        )
        let copyURLKey = try XCTUnwrap(Shortcuts.DefaultShortcuts[.PHI_COPY_URL])

        let command = CommandDispatcher.matchedPhiCommand(
            for: event,
            shortcutMap: [
                cyrillicKey: .PHI_NEW_CONVERSATION,
                copyURLKey: .PHI_COPY_URL,
            ],
            inputSourceIdentifier: InputSource.russian
        )

        XCTAssertEqual(command, .PHI_COPY_URL)
    }

    func testPhiShortcutMatchingUsesLegacyNonLatinBindingWhenCanonicalIsUnassigned() throws {
        let event = try makeShortcutKeyEvent(
            characters: "C",
            charactersIgnoringModifiers: "\u{0421}",
            modifiers: [.command, .shift]
        )
        let cyrillicKey = ShortcutsKey(
            characters: "\u{0441}",
            modifiers: [.command, .shift]
        )

        let command = CommandDispatcher.matchedPhiCommand(
            for: event,
            shortcutMap: [cyrillicKey: .PHI_NEW_CONVERSATION],
            inputSourceIdentifier: InputSource.russian
        )

        XCTAssertEqual(command, .PHI_NEW_CONVERSATION)
    }

    func testPhiShortcutMatchingDoesNotFallbackWhenIgnoringModifiersIsASCII() throws {
        let event = try makeShortcutKeyEvent(
            characters: "Z",
            charactersIgnoringModifiers: ";",
            modifiers: [.command, .shift],
            keyCode: UInt16(kVK_ANSI_Z)
        )
        let physicalKey = ShortcutsKey(
            characters: "z",
            modifiers: [.command, .shift]
        )

        let command = CommandDispatcher.matchedPhiCommand(
            for: event,
            shortcutMap: [physicalKey: .PHI_COPY_URL],
            inputSourceIdentifier: InputSource.dvorak
        )

        XCTAssertNil(command)
    }

    func testShortcutCaptureKeepsSemanticASCIICharacterForAlternateLayout() throws {
        let event = try makeShortcutKeyEvent(
            characters: "Z",
            charactersIgnoringModifiers: ";",
            modifiers: [.command, .shift],
            keyCode: UInt16(kVK_ANSI_Z)
        )

        let recordedKey = try XCTUnwrap(
            ShortcutsKey.recordingKey(
                for: event,
                inputSourceIdentifier: InputSource.dvorak
            )
        )

        XCTAssertEqual(
            recordedKey,
            ShortcutsKey(characters: ";", modifiers: [.command, .shift])
        )
        XCTAssertEqual(
            CommandDispatcher.matchedPhiCommand(
                for: event,
                shortcutMap: [recordedKey: .PHI_COPY_URL],
                inputSourceIdentifier: InputSource.dvorak
            ),
            .PHI_COPY_URL
        )
    }

    func testCommandQWERTYLayoutUsesPhysicalLatinKeyWithCommand() throws {
        let event = try makeShortcutKeyEvent(
            characters: "Z",
            charactersIgnoringModifiers: ";",
            modifiers: [.command, .shift],
            keyCode: UInt16(kVK_ANSI_Z)
        )
        let physicalKey = ShortcutsKey(
            characters: "z",
            modifiers: [.command, .shift]
        )

        let recordedKey = try XCTUnwrap(
            ShortcutsKey.recordingKey(
                for: event,
                inputSourceIdentifier: InputSource.dvorakCommandQWERTY
            )
        )

        XCTAssertEqual(recordedKey, physicalKey)
        XCTAssertEqual(
            CommandDispatcher.matchedPhiCommand(
                for: event,
                shortcutMap: [physicalKey: .PHI_COPY_URL],
                inputSourceIdentifier: InputSource.dvorakCommandQWERTY
            ),
            .PHI_COPY_URL
        )
    }

    func testCommandQWERTYLayoutUsesPhysicalPunctuationWithCommand() throws {
        let unshiftedEvent = try makeShortcutKeyEvent(
            characters: "+",
            charactersIgnoringModifiers: "+",
            modifiers: [.command],
            keyCode: UInt16(kVK_ANSI_RightBracket)
        )
        let shiftedEvent = try makeShortcutKeyEvent(
            characters: "}",
            charactersIgnoringModifiers: "+",
            modifiers: [.command, .shift],
            keyCode: UInt16(kVK_ANSI_RightBracket)
        )
        let unshiftedKey = ShortcutsKey(
            characters: "]",
            modifiers: [.command]
        )
        let shiftedKey = ShortcutsKey(
            characters: "}",
            modifiers: [.command, .shift]
        )

        XCTAssertEqual(
            ShortcutsKey.recordingKey(
                for: unshiftedEvent,
                inputSourceIdentifier: InputSource.dvorakCommandQWERTY
            ),
            unshiftedKey
        )
        XCTAssertEqual(
            ShortcutsKey.recordingKey(
                for: shiftedEvent,
                inputSourceIdentifier: InputSource.dvorakCommandQWERTY
            ),
            shiftedKey
        )
        XCTAssertEqual(shiftedKey.menuKeyEquivalent.characters, "}")
        XCTAssertEqual(shiftedKey.menuKeyEquivalent.modifiers, [.command])
        XCTAssertEqual(
            CommandDispatcher.matchedPhiCommand(
                for: shiftedEvent,
                shortcutMap: [shiftedKey: .PHI_COPY_URL],
                inputSourceIdentifier: InputSource.dvorakCommandQWERTY
            ),
            .PHI_COPY_URL
        )
    }

    func testShortcutCaptureUsesASCIIEquivalentWithoutCommandWhenProvided() throws {
        let event = try makeShortcutKeyEvent(
            characters: "C",
            charactersIgnoringModifiers: "\u{0421}",
            modifiers: [.shift]
        )
        let shiftOnlyKey = ShortcutsKey(characters: "c", modifiers: [.shift])
        let recordedKey = try XCTUnwrap(
            ShortcutsKey.recordingKey(
                for: event,
                inputSourceIdentifier: InputSource.russian
            )
        )

        let command = CommandDispatcher.matchedPhiCommand(
            for: event,
            shortcutMap: [shiftOnlyKey: .PHI_COPY_URL],
            inputSourceIdentifier: InputSource.russian
        )

        XCTAssertEqual(recordedKey, shiftOnlyKey)
        XCTAssertEqual(recordedKey.displayString, "⇧C")
        XCTAssertEqual(command, .PHI_COPY_URL)
    }

    func testNonASCIICaptureKeepsSemanticKeyWithoutASCIIEquivalent() throws {
        let event = try makeShortcutKeyEvent(
            characters: "\u{041F}",
            charactersIgnoringModifiers: "\u{041F}",
            modifiers: [.control, .shift],
            keyCode: UInt16(kVK_ANSI_G)
        )
        let recordedKey = try XCTUnwrap(
            ShortcutsKey.recordingKey(
                for: event,
                inputSourceIdentifier: InputSource.russian
            )
        )
        let semanticKey = ShortcutsKey(
            characters: "\u{043F}",
            modifiers: [.control, .shift]
        )

        XCTAssertEqual(recordedKey, semanticKey)
        XCTAssertEqual(recordedKey.displayString, "⇧⌃П")
        XCTAssertEqual(
            CommandDispatcher.matchedPhiCommand(
                for: event,
                shortcutMap: [semanticKey: .PHI_FARRINGDON_TOGGLE],
                inputSourceIdentifier: InputSource.russian
            ),
            .PHI_FARRINGDON_TOGGLE
        )
    }

    func testPhiShortcutMatchingFallsBackWhenIgnoringModifiersIsEmpty() throws {
        let event = try makeShortcutKeyEvent(
            characters: "C",
            charactersIgnoringModifiers: "",
            modifiers: [.command, .shift]
        )
        let copyURLKey = try XCTUnwrap(Shortcuts.DefaultShortcuts[.PHI_COPY_URL])

        let command = CommandDispatcher.matchedPhiCommand(
            for: event,
            shortcutMap: [copyURLKey: .PHI_COPY_URL],
            inputSourceIdentifier: InputSource.russian
        )

        XCTAssertEqual(command, .PHI_COPY_URL)
    }

    func testHebrewCommandCaptureUsesInputSourceSpecificLatinEquivalent() throws {
        let event = try makeShortcutKeyEvent(
            characters: "q",
            charactersIgnoringModifiers: "/",
            modifiers: [.command],
            keyCode: UInt16(kVK_ANSI_Q)
        )

        let hebrewKey = try XCTUnwrap(
            ShortcutsKey.recordingKey(
                for: event,
                inputSourceIdentifier: InputSource.hebrewQWERTY
            )
        )
        let nonHebrewKey = try XCTUnwrap(
            ShortcutsKey.recordingKey(
                for: event,
                inputSourceIdentifier: InputSource.us
            )
        )

        XCTAssertEqual(hebrewKey, ShortcutsKey(characters: "q", modifiers: [.command]))
        XCTAssertEqual(nonHebrewKey, ShortcutsKey(characters: "/", modifiers: [.command]))
        XCTAssertEqual(
            CommandDispatcher.matchedPhiCommand(
                for: event,
                shortcutMap: [hebrewKey: .PHI_COPY_URL],
                inputSourceIdentifier: InputSource.hebrewQWERTY
            ),
            .PHI_COPY_URL
        )
    }

    func testArabicCommandCaptureUsesInputSourceSpecificLatinEquivalent() throws {
        let event = try makeShortcutKeyEvent(
            characters: "V",
            charactersIgnoringModifiers: "{",
            modifiers: [.command, .shift],
            keyCode: UInt16(kVK_ANSI_V)
        )

        let arabicKey = try XCTUnwrap(
            ShortcutsKey.recordingKey(
                for: event,
                inputSourceIdentifier: InputSource.arabicAZERTY
            )
        )
        let nonArabicKey = try XCTUnwrap(
            ShortcutsKey.recordingKey(
                for: event,
                inputSourceIdentifier: InputSource.us
            )
        )

        XCTAssertEqual(
            arabicKey,
            ShortcutsKey(characters: "v", modifiers: [.command, .shift])
        )
        XCTAssertEqual(
            nonArabicKey,
            ShortcutsKey(characters: "{", modifiers: [.command, .shift])
        )
        XCTAssertEqual(
            CommandDispatcher.matchedPhiCommand(
                for: event,
                shortcutMap: [arabicKey: .PHI_COPY_URL],
                inputSourceIdentifier: InputSource.arabicAZERTY
            ),
            .PHI_COPY_URL
        )
    }

    func testCopyURLShortcutKeycapsMatchMacModifierOrder() {
        let shortcut = ShortcutsKey(characters: "c", modifiers: [.command, .shift])

        XCTAssertEqual(shortcut.keycapTokens, ["⇧", "⌘", "C"])
    }

    func testShortcutKeycapsUseReadableSpecialKeySymbols() {
        let shortcut = ShortcutsKey(
            characters: "\u{F702}",
            modifiers: [.control, .option]
        )

        XCTAssertEqual(shortcut.keycapTokens, ["⌃", "⌥", "←"])
        XCTAssertEqual(shortcut.displayString, "⌥⌃←")
    }

    func testShortcutCaptureNormalizesShiftTabToTabCharacter() throws {
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.control, .shift],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: String(format: "%c", NSBackTabCharacter),
                charactersIgnoringModifiers: String(format: "%c", NSBackTabCharacter),
                isARepeat: false,
                keyCode: UInt16(kVK_Tab)
            )
        )

        let shortcut = try XCTUnwrap(
            ShortcutsKey.recordingKey(
                for: event,
                inputSourceIdentifier: InputSource.us
            )
        )

        XCTAssertEqual(shortcut.characters, "\t")
        XCTAssertEqual(shortcut.modifiers, [.control, .shift])
        XCTAssertEqual(shortcut.displayString, "⇧⌃⇥")
        XCTAssertEqual(shortcut.menuKeyEquivalent.characters, "\t")
        XCTAssertEqual(shortcut.menuKeyEquivalent.modifiers, [.control, .shift])
    }

    func testThemeSnapshotRoundTripPreservesRGBAndStandardizesAlpha() {
        let theme = Theme(id: "theme-snapshot-round-trip", name: "Snapshot")
        theme.setColor(
            light: NSColor(calibratedRed: 0.10, green: 0.20, blue: 0.30, alpha: 0.45),
            dark: NSColor(calibratedRed: 0.70, green: 0.60, blue: 0.50, alpha: 0.85),
            for: .windowOverlayBackground
        )
        theme.setColor(
            light: NSColor(calibratedRed: 0.15, green: 0.25, blue: 0.35, alpha: 0.31),
            dark: NSColor(calibratedRed: 0.65, green: 0.55, blue: 0.45, alpha: 0.79),
            for: .windowBackground
        )
        theme.setColor(
            light: NSColor(calibratedRed: 0.20, green: 0.40, blue: 0.60, alpha: 1.0),
            dark: NSColor(calibratedRed: 0.60, green: 0.40, blue: 0.20, alpha: 1.0),
            for: .themeColor
        )
        theme.setColor(
            light: NSColor(calibratedRed: 0.30, green: 0.50, blue: 0.70, alpha: 1.0),
            dark: NSColor(calibratedRed: 0.70, green: 0.50, blue: 0.30, alpha: 1.0),
            for: .extensionActonColor
        )

        let snapshot = theme.makeSnapshot()
        let restoredTheme = snapshot.makeTheme()

        XCTAssertEqual(snapshot.version, ThemeSnapshot.currentVersion)

        assertColor(
            restoredTheme.color(for: .windowOverlayBackground, appearance: .light),
            equals: theme
                .color(for: .windowOverlayBackground, appearance: .light)
                .withAlphaComponent(0.8)
        )
        assertColor(
            restoredTheme.color(for: .windowOverlayBackground, appearance: .dark),
            equals: theme
                .color(for: .windowOverlayBackground, appearance: .dark)
                .withAlphaComponent(0.8)
        )
        assertColor(
            restoredTheme.color(for: .windowBackground, appearance: .light),
            equals: theme
                .color(for: .windowBackground, appearance: .light)
                .withAlphaComponent(1)
        )
        assertColor(
            restoredTheme.color(for: .windowBackground, appearance: .dark),
            equals: theme
                .color(for: .windowBackground, appearance: .dark)
                .withAlphaComponent(1)
        )
        assertColor(
            restoredTheme.color(for: .themeColor, appearance: .dark),
            equals: theme.color(for: .themeColor, appearance: .dark)
        )
        assertColor(
            restoredTheme.color(for: .extensionActonColor, appearance: .light),
            equals: theme.color(for: .extensionActonColor, appearance: .light)
        )
        XCTAssertEqual(
            restoredTheme.windowOverlayOpacity(for: .light),
            0.8,
            accuracy: 0.001,
            "ThemeSnapshot V2 must ignore customized light overlay alpha."
        )
        XCTAssertEqual(
            restoredTheme.windowOverlayOpacity(for: .dark),
            0.8,
            accuracy: 0.001,
            "ThemeSnapshot V2 must ignore customized dark overlay alpha."
        )
        XCTAssertEqual(snapshot.colors.windowOverlayBackground.light.alpha, 0.8, accuracy: 0.001)
        XCTAssertEqual(snapshot.colors.windowOverlayBackground.dark.alpha, 0.8, accuracy: 0.001)
        XCTAssertEqual(snapshot.colors.windowBackground.light.alpha, 1, accuracy: 0.001)
        XCTAssertEqual(snapshot.colors.windowBackground.dark.alpha, 1, accuracy: 0.001)
    }

    func testThemeWindowRolesAlwaysExposeStandardAlpha() {
        let theme = Theme(id: "fixed-alpha-contract", name: "Fixed Alpha")
        theme.setColor(
            light: NSColor(hex: 0x112233, alpha: 0.12),
            dark: NSColor(hex: 0x445566, alpha: 0.93),
            for: .windowOverlayBackground
        )
        theme.setColor(
            light: NSColor(hex: 0x778899, alpha: 0.24),
            dark: NSColor(hex: 0xAABBCC, alpha: 0.68),
            for: .windowBackground
        )

        XCTAssertEqual(theme.windowOverlayOpacity(for: .light), 0.8, accuracy: 0.0001)
        XCTAssertEqual(theme.windowOverlayOpacity(for: .dark), 0.8, accuracy: 0.0001)
        XCTAssertEqual(
            theme.color(for: .windowBackground, appearance: .light).alphaComponent,
            1,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            theme.color(for: .windowBackground, appearance: .dark).alphaComponent,
            1,
            accuracy: 0.0001
        )
    }

    func testVersion1ColoredThemeSnapshotMigratesFromLatestCanonicalTheme() throws {
        let legacyTheme = Theme(id: Theme.mint.id, name: "Legacy Mint")
        legacyTheme.setColor(
            light: NSColor(calibratedRed: 0.91, green: 0.12, blue: 0.37, alpha: 0.23),
            dark: NSColor(calibratedRed: 0.17, green: 0.83, blue: 0.41, alpha: 0.67),
            for: .windowOverlayBackground
        )
        legacyTheme.setColor(
            light: .magenta,
            dark: .orange,
            for: .windowBackground
        )
        legacyTheme.setColor(light: .red, dark: .blue, for: .themeColor)
        legacyTheme.setColor(light: .yellow, dark: .purple, for: .extensionActonColor)
        let legacySnapshot = ThemeSnapshot(
            version: ThemeSnapshot.version1,
            id: legacyTheme.id,
            name: legacyTheme.name,
            colors: rawEditableColors(from: legacyTheme)
        )

        let migratedSnapshot = try XCTUnwrap(
            legacySnapshot.migratedToCurrentVersion(matching: Theme.mint)
        )
        let restoredTheme = migratedSnapshot.makeTheme(matching: Theme.mint)

        XCTAssertEqual(migratedSnapshot.version, ThemeSnapshot.currentVersion)
        XCTAssertEqual(migratedSnapshot.id, Theme.mint.id)
        XCTAssertEqual(migratedSnapshot.name, Theme.mint.name)
        assertHSB(
            restoredTheme.color(for: .windowOverlayBackground, appearance: .light),
            saturation: 0.40,
            alpha: 0.8
        )
        assertHSB(
            restoredTheme.color(for: .windowOverlayBackground, appearance: .dark),
            saturation: 0.40,
            alpha: 0.8
        )
        assertHSB(
            restoredTheme.color(for: .windowBackground, appearance: .dark),
            saturation: 0.40,
            alpha: 1
        )
        assertColor(
            restoredTheme.color(for: .themeColor, appearance: .light),
            equals: Theme.mint.color(for: .themeColor, appearance: .light)
        )
        assertColor(
            restoredTheme.color(for: .extensionActonColor, appearance: .dark),
            equals: Theme.mint.color(for: .extensionActonColor, appearance: .dark)
        )
    }

    func testVersion1PureThemeSnapshotMigratesToAppearanceSpecificMidpoints() throws {
        let legacyTheme = Theme(id: Theme.pure.id, name: "Legacy Pure")
        legacyTheme.setColor(light: .red, dark: .green, for: .windowOverlayBackground)
        legacyTheme.setColor(light: .blue, dark: .yellow, for: .windowBackground)
        legacyTheme.setColor(light: .orange, dark: .purple, for: .themeColor)
        legacyTheme.setColor(light: .cyan, dark: .magenta, for: .extensionActonColor)
        let legacySnapshot = ThemeSnapshot(
            version: ThemeSnapshot.version1,
            id: legacyTheme.id,
            name: legacyTheme.name,
            colors: rawEditableColors(from: legacyTheme)
        )

        let migratedSnapshot = try XCTUnwrap(
            legacySnapshot.migratedToCurrentVersion(matching: Theme.pure)
        )
        let restoredTheme = migratedSnapshot.makeTheme(matching: Theme.pure)

        XCTAssertEqual(migratedSnapshot.version, ThemeSnapshot.currentVersion)
        assertHSB(
            restoredTheme.color(for: .windowOverlayBackground, appearance: .light),
            brightness: 0.89,
            alpha: 0.8
        )
        assertHSB(
            restoredTheme.color(for: .windowOverlayBackground, appearance: .dark),
            brightness: 0.20,
            alpha: 0.8
        )
        assertHSB(
            restoredTheme.color(for: .windowBackground, appearance: .dark),
            brightness: 0.25,
            alpha: 1
        )
        XCTAssertEqual(
            Theme.pure
                .color(for: .windowOverlayBackground, appearance: .light)
                .hsbBrightnessComponent,
            1,
            accuracy: 0.0001,
            "Migration must not mutate the canonical built-in instance."
        )
    }

    func testVersion1DefaultSnapshotAliasMigratesToPure() throws {
        let legacySnapshot = ThemeSnapshot(
            version: ThemeSnapshot.version1,
            id: "default",
            name: "Default",
            colors: rawEditableColors(from: Theme.pure)
        )

        let migratedSnapshot = try XCTUnwrap(
            legacySnapshot.migratedToCurrentVersion(matching: Theme.pure)
        )

        XCTAssertEqual(migratedSnapshot.id, Theme.pure.id)
        XCTAssertEqual(migratedSnapshot.version, ThemeSnapshot.currentVersion)
    }

    func testVersion1CustomThemeSnapshotKeepsRGBAndStandardizesAlpha() throws {
        let customTheme = Theme(id: "custom-theme", name: "Custom")
        customTheme.setColor(
            light: NSColor(calibratedRed: 0.11, green: 0.22, blue: 0.33, alpha: 0.44),
            dark: NSColor(calibratedRed: 0.55, green: 0.66, blue: 0.77, alpha: 0.88),
            for: .windowOverlayBackground
        )
        customTheme.setColor(light: .red, dark: .green, for: .windowBackground)
        customTheme.setColor(light: .blue, dark: .yellow, for: .themeColor)
        customTheme.setColor(light: .orange, dark: .purple, for: .extensionActonColor)
        let legacySnapshot = ThemeSnapshot(
            version: ThemeSnapshot.version1,
            id: customTheme.id,
            name: customTheme.name,
            colors: rawEditableColors(from: customTheme)
        )

        let migratedSnapshot = try XCTUnwrap(
            legacySnapshot.migratedToCurrentVersion(matching: nil)
        )
        let restoredTheme = migratedSnapshot.makeTheme()

        XCTAssertEqual(migratedSnapshot.version, ThemeSnapshot.currentVersion)
        XCTAssertEqual(migratedSnapshot.id, customTheme.id)
        XCTAssertEqual(migratedSnapshot.name, customTheme.name)
        assertColor(
            restoredTheme.color(for: .windowOverlayBackground, appearance: .light),
            equals: customTheme
                .color(for: .windowOverlayBackground, appearance: .light)
                .withAlphaComponent(0.8)
        )
        assertColor(
            restoredTheme.color(for: .windowOverlayBackground, appearance: .dark),
            equals: customTheme
                .color(for: .windowOverlayBackground, appearance: .dark)
                .withAlphaComponent(0.8)
        )
        assertColor(
            restoredTheme.color(for: .themeColor, appearance: .light),
            equals: customTheme.color(for: .themeColor, appearance: .light)
        )
    }

    func testVersion2SnapshotRestoreKeepsCanonicalNonEditableRoles() throws {
        let canonicalTheme = Theme(id: "future-built-in", name: "Future")
        canonicalTheme.setColor(light: .brown, dark: .gray, for: .textPrimary)
        let editableTheme = Theme(id: canonicalTheme.id, name: canonicalTheme.name)
        editableTheme.setColor(light: .red, dark: .green, for: .windowOverlayBackground)
        let snapshot = editableTheme.makeSnapshot()

        let migratedSnapshot = try XCTUnwrap(
            snapshot.migratedToCurrentVersion(matching: canonicalTheme)
        )
        let restoredTheme = migratedSnapshot.makeTheme(matching: canonicalTheme)

        XCTAssertEqual(migratedSnapshot, snapshot)
        assertColor(
            restoredTheme.color(for: .textPrimary, appearance: .light),
            equals: .brown
        )
        assertColor(
            restoredTheme.color(for: .textPrimary, appearance: .dark),
            equals: .gray
        )
    }

    func testVersion2SnapshotIgnoresPersistedAlpha() throws {
        let savedTheme = Theme(id: "v2-saved-alpha", name: "Saved Alpha")
        savedTheme.setColor(
            light: NSColor(hex: 0x2468AC),
            dark: NSColor(hex: 0x13579B),
            for: .windowOverlayBackground
        )
        savedTheme.setColor(
            light: NSColor(hex: 0xF0E0D0),
            dark: NSColor(hex: 0x302010),
            for: .windowBackground
        )
        let savedSnapshot = ThemeSnapshot(
            version: ThemeSnapshot.currentVersion,
            id: savedTheme.id,
            name: savedTheme.name,
            colors: rawEditableColors(from: savedTheme)
        )

        let normalizedSnapshot = try XCTUnwrap(
            savedSnapshot.migratedToCurrentVersion(matching: nil)
        )
        let restoredTheme = normalizedSnapshot.makeTheme()

        XCTAssertEqual(normalizedSnapshot.colors.windowOverlayBackground.light.alpha, 0.8)
        XCTAssertEqual(normalizedSnapshot.colors.windowOverlayBackground.dark.alpha, 0.8)
        XCTAssertEqual(normalizedSnapshot.colors.windowBackground.light.alpha, 1)
        XCTAssertEqual(normalizedSnapshot.colors.windowBackground.dark.alpha, 1)
        assertColor(
            restoredTheme.color(for: .windowOverlayBackground, appearance: .light),
            equals: NSColor(hex: 0x2468AC, alpha: 0.8)
        )
        assertColor(
            restoredTheme.color(for: .windowBackground, appearance: .dark),
            equals: NSColor(hex: 0x302010, alpha: 1)
        )
    }

    func testUnsupportedThemeSnapshotVersionIsNotApplied() {
        let futureSnapshot = ThemeSnapshot(
            version: ThemeSnapshot.currentVersion + 1,
            id: Theme.mint.id,
            name: Theme.mint.name,
            colors: Theme.mint.makeSnapshot().colors
        )

        XCTAssertNil(
            futureSnapshot.migratedToCurrentVersion(matching: Theme.mint)
        )
    }

    func testThemeColorAdjustmentForcesStandardAlpha() {
        let base = Theme(id: "alpha-normalization", name: "Alpha")
        base.setColor(
            light: NSColor(calibratedRed: 0.2, green: 0.5, blue: 0.8, alpha: 0.37),
            dark: NSColor(calibratedRed: 0.8, green: 0.5, blue: 0.2, alpha: 0.63),
            for: .windowOverlayBackground
        )
        base.setColor(
            light: NSColor(calibratedWhite: 0.9, alpha: 0.71),
            dark: NSColor(calibratedWhite: 0.1, alpha: 0.79),
            for: .windowBackground
        )

        let adjusted = ThemeColorAdjustment.applyingSaturation(
            light: 0.4,
            dark: 0.4,
            darkWindowBackground: 0.4,
            to: base
        )

        XCTAssertEqual(
            adjusted.color(for: .windowOverlayBackground, appearance: .light).alphaComponent,
            0.8,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            adjusted.color(for: .windowOverlayBackground, appearance: .dark).alphaComponent,
            0.8,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            adjusted.color(for: .windowBackground, appearance: .dark).alphaComponent,
            1,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            adjusted.color(for: .windowBackground, appearance: .light).alphaComponent,
            1,
            accuracy: 0.0001
        )
    }

    func testNormalizedThemeSliderTrackColorKeepsRgbAndForcesFullOpacity() {
        let sourceColor = NSColor(calibratedRed: 0.21, green: 0.42, blue: 0.63, alpha: 0.37)

        let normalizedColor = normalizedThemeSliderTrackColor(from: sourceColor)

        assertColor(
            normalizedColor,
            equals: NSColor(calibratedRed: 0.21, green: 0.42, blue: 0.63, alpha: 1.0)
        )
    }

    func testPureThemeBrightnessScaleGetsDarkerFromLeftToRight() {
        XCTAssertEqual(PureThemeBrightnessScale.brightness(forSlider: -1, appearance: .light), 0.94, accuracy: 0.0001)
        XCTAssertEqual(PureThemeBrightnessScale.brightness(forSlider: 0, appearance: .light), 0.94, accuracy: 0.0001)
        XCTAssertEqual(PureThemeBrightnessScale.brightness(forSlider: 50, appearance: .light), 0.89, accuracy: 0.0001)
        XCTAssertEqual(PureThemeBrightnessScale.brightness(forSlider: 100, appearance: .light), 0.84, accuracy: 0.0001)
        XCTAssertEqual(PureThemeBrightnessScale.brightness(forSlider: 101, appearance: .light), 0.84, accuracy: 0.0001)
        XCTAssertEqual(PureThemeBrightnessScale.sliderValue(forBrightness: 0.89, appearance: .light), 50, accuracy: 0.0001)

        XCTAssertEqual(PureThemeBrightnessScale.brightness(forSlider: 0, appearance: .dark), 0.40, accuracy: 0.0001)
        XCTAssertEqual(PureThemeBrightnessScale.brightness(forSlider: 50, appearance: .dark), 0.20, accuracy: 0.0001)
        XCTAssertEqual(PureThemeBrightnessScale.brightness(forSlider: 100, appearance: .dark), 0, accuracy: 0.0001)
        XCTAssertEqual(PureThemeBrightnessScale.sliderValue(forBrightness: 0.20, appearance: .dark), 50, accuracy: 0.0001)

        XCTAssertEqual(PureThemeBrightnessScale.darkWindowBackgroundBrightness(forSlider: 0), 0.30, accuracy: 0.0001)
        XCTAssertEqual(PureThemeBrightnessScale.darkWindowBackgroundBrightness(forSlider: 50), 0.25, accuracy: 0.0001)
        XCTAssertEqual(PureThemeBrightnessScale.darkWindowBackgroundBrightness(forSlider: 100), 0.20, accuracy: 0.0001)
    }

    func testPureTabSubSelectionUsesContrastOverlayAcrossBrightnessRange() {
        for sliderValue in [0.0, 50.0, 100.0] {
            let theme = ThemeColorAdjustment.applyingPureBrightness(
                sliderValue: sliderValue,
                to: .pure
            )

            assertColor(
                ThemedColor.tabSubSelectionBackground.resolve(
                    theme: theme,
                    appearance: .light
                ),
                equals: NSColor.black.withAlphaComponent(0.08)
            )
        }
    }

    func testColoredThemeTabSubSelectionKeepsExistingColors() {
        assertColor(
            ThemedColor.tabSubSelectionBackground.resolve(
                theme: .mint,
                appearance: .light
            ),
            equals: NSColor(white: 0.9, alpha: 1)
        )
        assertColor(
            ThemedColor.tabSubSelectionBackground.resolve(
                theme: .mint,
                appearance: .dark
            ),
            equals: NSColor.white.withAlphaComponent(0.18)
        )
    }

    func testDefaultColoredThemeSaturationIsFortyPercent() {
        XCTAssertEqual(ThemeColorAdjustment.defaultSaturation, 0.40, accuracy: 0.0001)
        XCTAssertEqual(
            OverlaySaturationScale.sliderValue(
                forSaturation: Double(ThemeColorAdjustment.defaultSaturation)
            ),
            37.5,
            accuracy: 0.0001
        )
    }

    func testHSBBrightnessReplacementPreservesSaturationAndSetsAlpha() {
        let sourceColor = NSColor(
            colorSpace: .extendedSRGB,
            hue: 0,
            saturation: 0,
            brightness: 1,
            alpha: 0.4
        )

        let adjustedColor = sourceColor.withHSBBrightness(0.76, alpha: 0.8)

        XCTAssertEqual(adjustedColor.hsbSaturationComponent, 0, accuracy: 0.0001)
        XCTAssertEqual(adjustedColor.hsbBrightnessComponent, 0.76, accuracy: 0.0001)
        XCTAssertEqual(adjustedColor.alphaComponent, 0.8, accuracy: 0.0001)
    }

    @MainActor
    func testBrowserThemeContextPublishesThemeChangesForSameThemeIdentifier() {
        let initialTheme = Theme(id: "browser-context-same-id", name: "Context")
        initialTheme.setColor(
            light: NSColor(hex: 0x445566, alpha: 0.40),
            dark: NSColor(hex: 0x112233, alpha: 0.80),
            for: .windowOverlayBackground
        )

        let context = BrowserThemeContext(
            configuration: BrowserThemeConfiguration(
                currentTheme: initialTheme,
                userAppearanceChoice: .light,
                mirrorsSharedTheme: false,
                mirrorsSharedAppearance: false
            )
        )

        var observedLightOverlayColors: [NSColor] = []
        let subscription = context.subscribe { theme, appearance in
            observedLightOverlayColors.append(
                theme.color(for: .windowOverlayBackground, appearance: appearance)
            )
        }

        let updatedTheme = initialTheme.duplicating()
        updatedTheme.setColor(
            light: NSColor(hex: 0xAA8844, alpha: 0.72),
            dark: NSColor(hex: 0x335577, alpha: 0.36),
            for: .windowOverlayBackground
        )
        context.setTheme(updatedTheme)
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))

        _ = subscription

        XCTAssertEqual(observedLightOverlayColors.count, 2)
        guard observedLightOverlayColors.count == 2 else { return }
        assertColor(
            observedLightOverlayColors[0],
            equals: NSColor(hex: 0x445566, alpha: 0.8)
        )
        assertColor(
            observedLightOverlayColors[1],
            equals: NSColor(hex: 0xAA8844, alpha: 0.8)
        )
    }

    func testBookmarkMainMenuItemRoutingKeepsChromiumBookmarksItemUntouched() {
        let action = BookmarkMainMenuItemRouting.action(
            tag: ChromiumMainMenuRole.bookmarks.rawValue
        )

        XCTAssertEqual(
            action,
            .hideSystemItem,
            "The Chromium-owned Bookmarks menu item must stay discoverable by IDC_BOOKMARKS_MENU so AppController should only hide it instead of repurposing it as the native custom Bookmarks menu."
        )
    }

    func testBookmarkMainMenuItemRoutingRecognizesCustomBookmarksItem() {
        let action = BookmarkMainMenuItemRouting.action(
            tag: AppController.bookmarksMenuItemTag
        )

        XCTAssertEqual(
            action,
            .configureCustomItem,
            "The native Phi Bookmarks item should be the only menu item that gets reconfigured and rebuilt."
        )
    }

    func testChromiumMainMenuRoleUsesTagsInsteadOfLocalizedTitles() {
        let mainMenu = NSMenu(title: "")
        let appItem = NSMenuItem(title: "Localized App Menu", action: nil, keyEquivalent: "")
        appItem.tag = ChromiumMainMenuRole.app.rawValue
        let viewItem = NSMenuItem(title: "Localized View Menu", action: nil, keyEquivalent: "")
        viewItem.tag = ChromiumMainMenuRole.view.rawValue
        let historyItem = NSMenuItem(title: "Localized History Menu", action: nil, keyEquivalent: "")
        historyItem.tag = ChromiumMainMenuRole.history.rawValue
        mainMenu.addItem(appItem)
        mainMenu.addItem(viewItem)
        mainMenu.addItem(historyItem)

        XCTAssertEqual(
            ChromiumMainMenuRole.resolve(viewItem, helpMenu: nil),
            .view
        )
        XCTAssertTrue(ChromiumMainMenuRole.app.item(in: mainMenu) === appItem)
        XCTAssertEqual(ChromiumMainMenuRole.history.index(in: mainMenu), 2)
    }

    func testChromiumMainMenuRoleRecognizesAppKitHelpMenuByIdentity() {
        let helpMenu = NSMenu(title: "Localized Help Menu")
        let helpItem = NSMenuItem(title: "Localized Help Menu", action: nil, keyEquivalent: "")
        helpItem.submenu = helpMenu

        XCTAssertEqual(
            ChromiumMainMenuRole.resolve(helpItem, helpMenu: helpMenu),
            .help
        )
    }

    func testBookmarkMenuContentBuilderAddsBookmarkThisTabAndRecursiveBookmarks() {
        let previousOverrides = Shortcuts.overridedShortcuts
        defer { Shortcuts.overridedShortcuts = previousOverrides }
        Shortcuts.overridedShortcuts[.IDC_SHOW_BOOKMARK_MANAGER] = .some(nil)

        let rootBookmark = Bookmark(title: "Phi", url: "https://phibrowser.com")
        let folder = Bookmark(folderTitle: "Favorites")
        let childBookmark = Bookmark(title: "Docs", url: "https://docs.phibrowser.com")
        folder.addChild(childBookmark)
        let target = BookmarkMenuTestTarget()

        let menu = BookmarkMenuContentBuilder.makeMenu(
            bookmarks: [rootBookmark, folder],
            canBookmarkCurrentTab: true,
            canBookmarkAllTabs: true,
            canExportBookmarks: true,
            target: target,
            bookmarkThisTabAction: #selector(BookmarkMenuTestTarget.menuAction(_:)),
            bookmarkAllTabsAction: #selector(BookmarkMenuTestTarget.menuAction(_:)),
            bookmarkManagerAction: #selector(BookmarkMenuTestTarget.menuAction(_:)),
            exportBookmarksAction: #selector(BookmarkMenuTestTarget.menuAction(_:)),
            openBookmarkAction: #selector(BookmarkMenuTestTarget.menuAction(_:))
        )

        XCTAssertEqual(
            menu.items.first?.title,
            NSLocalizedString("app.bookmarksMenu.addOrEditCurrentTab", value: "Bookmark This Tab...", comment: "Bookmarks menu - Menu item to add or edit a bookmark for the currently focused tab")
        )
        XCTAssertEqual(menu.items.first?.tag, CommandWrapper.IDC_BOOKMARK_THIS_TAB.rawValue)
        XCTAssertEqual(
            menu.items.dropFirst().first?.title,
            NSLocalizedString("app.bookmarksMenu.addAllOpenTabs", value: "Bookmark All Tabs...", comment: "Bookmarks menu - Menu item to add bookmarks for all currently open tabs in the active window")
        )
        XCTAssertEqual(menu.items.dropFirst().first?.tag, CommandWrapper.IDC_BOOKMARK_ALL_TABS.rawValue)
        XCTAssertTrue(
            menu.items.first?.isEnabled == true,
            "The Bookmarks menu should enable the Bookmark This Tab item when the active window has a focusable tab URL."
        )
        XCTAssertTrue(menu.items.dropFirst(2).first?.isSeparatorItem == true)
        XCTAssertEqual(
            menu.items.dropFirst(3).first?.title,
            NSLocalizedString("app.bookmarksMenu.openManager", value: "Manage Bookmarks", comment: "Bookmarks menu - Menu item that opens the bookmark management page")
        )
        let managerItem = menu.items.dropFirst(3).first
        XCTAssertEqual(managerItem?.tag, CommandWrapper.IDC_SHOW_BOOKMARK_MANAGER.rawValue)
        XCTAssertEqual(managerItem?.action, #selector(BookmarkMenuTestTarget.menuAction(_:)))
        XCTAssertEqual(managerItem?.keyEquivalent, "b")
        XCTAssertEqual(managerItem?.keyEquivalentModifierMask, [.command, .option])
        XCTAssertEqual(
            menu.items.dropFirst(4).first?.title,
            NSLocalizedString("app.bookmarksMenu.exportCurrentSpace", value: "Export Bookmarks...", comment: "Bookmarks menu - Menu item to export the current Space's bookmarks to an HTML file")
        )
        XCTAssertTrue(menu.items.dropFirst(5).first?.isSeparatorItem == true)
        XCTAssertEqual(menu.items.dropFirst(6).map(\.title), ["Phi", "Favorites"])
        XCTAssertEqual(menu.items.last?.submenu?.items.map(\.title), ["Docs"])
    }

    func testBookmarkMenuContentBuilderDisablesBookmarkThisTabWithoutFocusedTab() {
        let target = BookmarkMenuTestTarget()

        let menu = BookmarkMenuContentBuilder.makeMenu(
            bookmarks: [],
            canBookmarkCurrentTab: false,
            canBookmarkAllTabs: false,
            canExportBookmarks: false,
            target: target,
            bookmarkThisTabAction: #selector(BookmarkMenuTestTarget.menuAction(_:)),
            bookmarkAllTabsAction: #selector(BookmarkMenuTestTarget.menuAction(_:)),
            bookmarkManagerAction: #selector(BookmarkMenuTestTarget.menuAction(_:)),
            exportBookmarksAction: #selector(BookmarkMenuTestTarget.menuAction(_:)),
            openBookmarkAction: #selector(BookmarkMenuTestTarget.menuAction(_:))
        )

        XCTAssertFalse(
            menu.items.first?.isEnabled == true,
            "The Bookmarks menu should disable the Bookmark This Tab item when there is no focused tab with a bookmarkable URL."
        )
        XCTAssertFalse(
            menu.items.dropFirst().first?.isEnabled == true,
            "The Bookmarks menu should disable the Bookmark All Tabs item when the active window does not have more than one bookmarkable open tab."
        )
        XCTAssertFalse(
            menu.items.dropFirst(4).first?.isEnabled == true,
            "The Bookmarks menu should disable the Export Bookmarks item when the current Space has no bookmarks to export."
        )
        XCTAssertEqual(menu.items.count, 5)
    }

    func testBookmarkMenuContentBuilderShowsDisabledEmptyItemForEmptyFolders() {
        let emptyFolder = Bookmark(folderTitle: "Empty Folder")
        let target = BookmarkMenuTestTarget()

        let menu = BookmarkMenuContentBuilder.makeMenu(
            bookmarks: [emptyFolder],
            canBookmarkCurrentTab: true,
            canBookmarkAllTabs: true,
            canExportBookmarks: true,
            target: target,
            bookmarkThisTabAction: #selector(BookmarkMenuTestTarget.menuAction(_:)),
            bookmarkAllTabsAction: #selector(BookmarkMenuTestTarget.menuAction(_:)),
            bookmarkManagerAction: #selector(BookmarkMenuTestTarget.menuAction(_:)),
            exportBookmarksAction: #selector(BookmarkMenuTestTarget.menuAction(_:)),
            openBookmarkAction: #selector(BookmarkMenuTestTarget.menuAction(_:))
        )

        let folderItem = menu.items[6]
        let emptyItem = try? XCTUnwrap(folderItem.submenu?.items.first)

        XCTAssertEqual(folderItem.title, "Empty Folder")
        XCTAssertEqual(
            emptyItem?.title,
            NSLocalizedString("app.bookmarksMenu.emptyFolderPlaceholder", value: "Empty", comment: "Bookmarks menu - Disabled placeholder item shown when a bookmark folder has no child bookmarks")
        )
        XCTAssertFalse(
            emptyItem?.isEnabled == true,
            "Empty bookmark folders should show a disabled placeholder item so the submenu still renders a stable empty state."
        )
    }

    func testBookmarkMenuContentBuilderDisablesBookmarkAllTabsWithoutEnoughTabs() {
        let target = BookmarkMenuTestTarget()

        let menu = BookmarkMenuContentBuilder.makeMenu(
            bookmarks: [],
            canBookmarkCurrentTab: true,
            canBookmarkAllTabs: false,
            canExportBookmarks: true,
            target: target,
            bookmarkThisTabAction: #selector(BookmarkMenuTestTarget.menuAction(_:)),
            bookmarkAllTabsAction: #selector(BookmarkMenuTestTarget.menuAction(_:)),
            bookmarkManagerAction: #selector(BookmarkMenuTestTarget.menuAction(_:)),
            exportBookmarksAction: #selector(BookmarkMenuTestTarget.menuAction(_:)),
            openBookmarkAction: #selector(BookmarkMenuTestTarget.menuAction(_:))
        )

        XCTAssertEqual(menu.items[1].tag, CommandWrapper.IDC_BOOKMARK_ALL_TABS.rawValue)
        XCTAssertFalse(
            menu.items[1].isEnabled,
            "Bookmark All Tabs should be disabled unless the active window has more than one bookmarkable open tab."
        )
    }

    @MainActor
    func testAuthManagerStartRenewTimerDoesNotReplaceExistingValidTimer() async throws {
        let authManager = AuthManager()

        authManager.startRenewTimer()
        let firstTimer = try await waitForRenewTimer(in: authManager)

        authManager.startRenewTimer()
        let secondTimer = try await waitForRenewTimer(in: authManager)

        authManager.stopRenewTimer()

        XCTAssertTrue(
            firstTimer === secondTimer,
            "Starting the renew timer while an existing valid timer is already running should keep the original timer instance instead of invalidating and replacing it."
        )
    }

    func testAuthSessionGenerationOnlyCommitsToCapturedSession() {
        let sessions = AuthSessionGeneration()
        let session = sessions.capture()
        var canonicalCredential = "old-session"

        let currentCommit = sessions.performIfCurrent(session) {
            canonicalCredential = "renewed-session"
            return true
        }

        XCTAssertEqual(currentCommit, true)
        XCTAssertEqual(canonicalCredential, "renewed-session")

        sessions.advance {
            canonicalCredential = "new-session"
        }
        let staleCommit = sessions.performIfCurrent(session) {
            canonicalCredential = "late-renewal"
            return true
        }

        XCTAssertFalse(sessions.isCurrent(session))
        XCTAssertNil(staleCommit)
        XCTAssertEqual(canonicalCredential, "new-session")
    }

    func testAuthenticatedSessionPublicationStagesUntilSignedInCommit() {
        XCTAssertTrue(
            AuthenticatedSessionPublicationPolicy.stagesCredentials(
                for: .guest
            )
        )
        XCTAssertTrue(
            AuthenticatedSessionPublicationPolicy.stagesCredentials(
                for: .loginRequired
            )
        )
        XCTAssertFalse(
            AuthenticatedSessionPublicationPolicy.stagesCredentials(
                for: .signedIn
            )
        )
        XCTAssertFalse(
            AuthenticatedSessionPublicationPolicy.canPublishSharedSession(
                browserAccessState: .guest
            )
        )
        XCTAssertTrue(
            AuthenticatedSessionPublicationPolicy.canPublishSharedSession(
                browserAccessState: .signedIn
            )
        )
    }

    func testStagedOnboardingCredentialRequiresMatchingActiveOnboardingAccount() {
        let futureExpiry = Date().addingTimeInterval(300)

        XCTAssertTrue(
            StagedOnboardingCredentialPolicy.canUseToken(
                browserAccessState: .guest,
                onboardingPhaseRawValue:
                    LoginController.Phase.setName.rawValue,
                loginPhaseRawValue: LoginController.Phase.login.rawValue,
                donePhaseRawValue: LoginController.Phase.done.rawValue,
                credentialUserID: "auth0|target",
                onboardingAccountUserID: "auth0|target",
                expectedUserID: "auth0|target",
                expiresAt: futureExpiry
            )
        )
        XCTAssertFalse(
            StagedOnboardingCredentialPolicy.canUseToken(
                browserAccessState: .guest,
                onboardingPhaseRawValue:
                    LoginController.Phase.setName.rawValue,
                loginPhaseRawValue: LoginController.Phase.login.rawValue,
                donePhaseRawValue: LoginController.Phase.done.rawValue,
                credentialUserID: "auth0|other",
                onboardingAccountUserID: "auth0|target",
                expectedUserID: "auth0|target",
                expiresAt: futureExpiry
            )
        )
        XCTAssertFalse(
            StagedOnboardingCredentialPolicy.canUseToken(
                browserAccessState: .signedIn,
                onboardingPhaseRawValue:
                    LoginController.Phase.setName.rawValue,
                loginPhaseRawValue: LoginController.Phase.login.rawValue,
                donePhaseRawValue: LoginController.Phase.done.rawValue,
                credentialUserID: "auth0|target",
                onboardingAccountUserID: "auth0|target",
                expectedUserID: "auth0|target",
                expiresAt: futureExpiry
            )
        )
        XCTAssertFalse(
            StagedOnboardingCredentialPolicy.canUseToken(
                browserAccessState: .loginRequired,
                onboardingPhaseRawValue:
                    LoginController.Phase.done.rawValue,
                loginPhaseRawValue: LoginController.Phase.login.rawValue,
                donePhaseRawValue: LoginController.Phase.done.rawValue,
                credentialUserID: "auth0|target",
                onboardingAccountUserID: "auth0|target",
                expectedUserID: "auth0|target",
                expiresAt: futureExpiry
            )
        )
    }

    func testSentinelSessionRunsOnlyForCommittedAuthenticatedAccess() {
        XCTAssertFalse(
            AuthenticatedSentinelSessionPolicy.shouldRun(
                browserAccessState: .guest,
                isAuthenticated: false,
                aiEnabled: true
            )
        )
        XCTAssertFalse(
            AuthenticatedSentinelSessionPolicy.shouldRun(
                browserAccessState: .loginRequired,
                isAuthenticated: false,
                aiEnabled: true
            )
        )
        XCTAssertFalse(
            AuthenticatedSentinelSessionPolicy.shouldRun(
                browserAccessState: .signedIn,
                isAuthenticated: true,
                aiEnabled: false
            )
        )
        XCTAssertTrue(
            AuthenticatedSentinelSessionPolicy.shouldRun(
                browserAccessState: .signedIn,
                isAuthenticated: true,
                aiEnabled: true
            )
        )
        XCTAssertFalse(
            AuthenticatedSentinelSessionPolicy.shouldTerminate(
                browserAccessState: .guest,
                isAuthenticated: false,
                aiEnabled: true
            )
        )
        XCTAssertTrue(
            AuthenticatedSentinelSessionPolicy.shouldTerminate(
                browserAccessState: .guest,
                isAuthenticated: false,
                aiEnabled: false
            )
        )
        XCTAssertFalse(
            AuthenticatedSentinelSessionPolicy.shouldTerminate(
                browserAccessState: .loginRequired,
                isAuthenticated: false,
                aiEnabled: true
            )
        )
        XCTAssertTrue(
            AuthenticatedSentinelSessionPolicy.shouldTerminate(
                browserAccessState: .signedIn,
                isAuthenticated: true,
                aiEnabled: false
            )
        )
        XCTAssertTrue(
            AuthenticatedSentinelSessionPolicy.shouldRegisterAtLogin(
                browserAccessState: .signedIn,
                isAuthenticated: true,
                aiEnabled: true,
                launchOnLogin: true
            )
        )
        XCTAssertFalse(
            AuthenticatedSentinelSessionPolicy.shouldRegisterAtLogin(
                browserAccessState: .signedIn,
                isAuthenticated: true,
                aiEnabled: true,
                launchOnLogin: false
            )
        )
    }

    func testDeferredGuestCleanupResumesOnlyMatchingStagedIdentity() {
        XCTAssertTrue(
            DeferredGuestMigrationRecoveryPolicy.shouldSuspendGuestAccess(
                hasRecoverableCredentials: true,
                storedCredentialUserID: "auth0|target",
                journalTargetUserID: "auth0|target"
            )
        )
        XCTAssertFalse(
            DeferredGuestMigrationRecoveryPolicy.shouldSuspendGuestAccess(
                hasRecoverableCredentials: true,
                storedCredentialUserID: "auth0|other",
                journalTargetUserID: "auth0|target"
            )
        )
        XCTAssertFalse(
            DeferredGuestMigrationRecoveryPolicy.shouldSuspendGuestAccess(
                hasRecoverableCredentials: false,
                storedCredentialUserID: "auth0|target",
                journalTargetUserID: "auth0|target"
            )
        )
    }

    func testReauthenticationIdentityAcceptsOnlyJournalTargetDuringRecovery() {
        XCTAssertTrue(
            AuthenticatedAccountIdentityPolicy.accepts(
                candidateUserID: "auth0|target",
                publishedUserID: nil,
                pendingUserID: nil,
                recoveryTargetUserID: "auth0|target",
                isGuestMigrationRecoveryInProgress: true
            )
        )
        XCTAssertFalse(
            AuthenticatedAccountIdentityPolicy.accepts(
                candidateUserID: "auth0|other",
                publishedUserID: nil,
                pendingUserID: nil,
                recoveryTargetUserID: "auth0|target",
                isGuestMigrationRecoveryInProgress: true
            )
        )
        XCTAssertFalse(
            AuthenticatedAccountIdentityPolicy.accepts(
                candidateUserID: "auth0|target",
                publishedUserID: nil,
                pendingUserID: "auth0|other",
                recoveryTargetUserID: "auth0|target",
                isGuestMigrationRecoveryInProgress: true
            )
        )
    }

    func testReauthenticationIdentityUsesPublishedOrPendingAccountNormally() {
        XCTAssertTrue(
            AuthenticatedAccountIdentityPolicy.accepts(
                candidateUserID: "auth0|published",
                publishedUserID: "auth0|published",
                pendingUserID: nil,
                recoveryTargetUserID: nil,
                isGuestMigrationRecoveryInProgress: false
            )
        )
        XCTAssertTrue(
            AuthenticatedAccountIdentityPolicy.accepts(
                candidateUserID: "auth0|pending",
                publishedUserID: nil,
                pendingUserID: "auth0|pending",
                recoveryTargetUserID: nil,
                isGuestMigrationRecoveryInProgress: false
            )
        )
        XCTAssertFalse(
            AuthenticatedAccountIdentityPolicy.accepts(
                candidateUserID: "auth0|pending",
                publishedUserID: "auth0|published",
                pendingUserID: "auth0|pending",
                recoveryTargetUserID: nil,
                isGuestMigrationRecoveryInProgress: false
            )
        )
    }

    func testAuthSessionGenerationSerializesRestoreAndRenewalCommits() {
        let state = AuthCredentialCommitTestState()
        let session = state.sessions.capture()
        let restoreEntered = DispatchSemaphore(value: 0)
        let allowRestoreToFinish = DispatchSemaphore(value: 0)
        let renewalEntered = DispatchSemaphore(value: 0)
        let restoreFinished = expectation(description: "Restore finished")
        let renewalFinished = expectation(description: "Renewal finished")

        DispatchQueue.global(qos: .userInitiated).async {
            _ = state.sessions.performIfCurrent(session) {
                restoreEntered.signal()
                allowRestoreToFinish.wait()
                state.currentCredential = state.canonicalCredential
            }
            restoreFinished.fulfill()
        }

        XCTAssertEqual(restoreEntered.wait(timeout: .now() + 1), .success)

        DispatchQueue.global(qos: .userInitiated).async {
            _ = state.sessions.performIfCurrent(session) {
                renewalEntered.signal()
                state.canonicalCredential = "renewed"
                state.currentCredential = "renewed"
            }
            renewalFinished.fulfill()
        }

        XCTAssertEqual(
            renewalEntered.wait(timeout: .now() + 0.1),
            .timedOut,
            "Renewal must not interleave between a persisted credential read and restore commit."
        )

        allowRestoreToFinish.signal()
        wait(for: [restoreFinished, renewalFinished], timeout: 1)

        XCTAssertEqual(state.canonicalCredential, "renewed")
        XCTAssertEqual(state.currentCredential, "renewed")
    }

    func testInMemoryCredentialsStorageKeepsSnapshotWritesIsolated() {
        let key = "credentials"
        let canonicalData = Data("canonical".utf8)
        let renewedData = Data("renewed".utf8)
        let canonicalStorage = InMemoryCredentialsStorage(
            entry: canonicalData,
            forKey: key
        )
        let snapshotStorage = InMemoryCredentialsStorage(
            entry: canonicalStorage.getEntry(forKey: key),
            forKey: key
        )

        XCTAssertTrue(snapshotStorage.setEntry(renewedData, forKey: key))
        XCTAssertEqual(snapshotStorage.getEntry(forKey: key), renewedData)
        XCTAssertEqual(canonicalStorage.getEntry(forKey: key), canonicalData)

        XCTAssertTrue(snapshotStorage.deleteEntry(forKey: key))
        XCTAssertNil(snapshotStorage.getEntry(forKey: key))
        XCTAssertEqual(canonicalStorage.getEntry(forKey: key), canonicalData)
    }

    @MainActor
    func testExtensionPopupAnchorUsesPrimaryScreenHeightForChromiumFlip() {
        let point = NSPoint(x: 240, y: 320)
        let primaryFrame = NSRect(x: 0, y: 0, width: 1920, height: 900)

        let chromiumPoint = ExtensionPopupAnchor.chromiumScreenPoint(
            from: point,
            primaryScreenFrame: primaryFrame
        )

        XCTAssertEqual(chromiumPoint.x, 240)
        XCTAssertEqual(
            chromiumPoint.y,
            580,
            "Extension popup anchors must flip against the primary display height so Swift matches Chromium's global screen coordinates."
        )
    }

    @MainActor
    func testExtensionPopupAnchorPreservesLegitimateNegativeChromiumY() {
        let point = NSPoint(x: 120, y: 960)
        let primaryFrame = NSRect(x: 0, y: 0, width: 1920, height: 900)

        let chromiumPoint = ExtensionPopupAnchor.chromiumScreenPoint(
            from: point,
            primaryScreenFrame: primaryFrame
        )

        XCTAssertEqual(
            chromiumPoint.y,
            -60,
            "Points above the primary display should remain negative after the AppKit-to-Chromium flip."
        )
    }

    @MainActor
    func testExtensionPopupAnchorRectFlipUsesPrimaryScreenHeight() {
        let appKitRect = NSRect(x: 240, y: 320, width: 100, height: 24)
        let primaryFrame = NSRect(x: 0, y: 0, width: 1920, height: 900)

        let chromiumRect = ExtensionPopupAnchor.chromiumScreenRect(
            from: appKitRect,
            primaryScreenFrame: primaryFrame
        )

        XCTAssertEqual(chromiumRect.origin.x, 240)
        XCTAssertEqual(
            chromiumRect.origin.y,
            556,
            "Anchor rects must flip as y = primary height - maxY so the rect's top edge lands in Chromium's top-left-origin screen space."
        )
        XCTAssertEqual(chromiumRect.size, appKitRect.size)
    }

    @MainActor
    func testExtensionPopupAnchorLegacyPointMatchesPointBasedConversion() {
        let appKitRect = NSRect(x: 240, y: 320, width: 100, height: 24)
        let primaryFrame = NSRect(x: 0, y: 0, width: 1920, height: 900)

        let pointFromRect = ExtensionPopupAnchor.legacyAnchorPoint(
            for: ExtensionPopupAnchor.chromiumScreenRect(
                from: appKitRect,
                primaryScreenFrame: primaryFrame
            )
        )
        let pointFromBottomLeft = ExtensionPopupAnchor.chromiumScreenPoint(
            from: NSPoint(x: appKitRect.minX, y: appKitRect.minY),
            primaryScreenFrame: primaryFrame
        )

        XCTAssertEqual(
            pointFromRect,
            pointFromBottomLeft,
            "The old-framework fallback must reproduce the icon's visual bottom-left corner exactly as the point-based path did."
        )
    }

    func testAuthFailureTraceBufferKeepsMostRecentEntries() {
        let baseDate = Date(timeIntervalSince1970: 1_713_600_000)
        var tick: TimeInterval = 0
        let buffer = AuthFailureTraceBuffer(
            capacity: 2,
            dateProvider: {
                defer { tick += 1 }
                return baseDate.addingTimeInterval(tick)
            }
        )

        buffer.record("launch-recovery", details: ["result": "skipped"])
        buffer.record("credentials", details: ["result": "loaded"])
        buffer.record("renew", details: ["result": "failed"])

        let rendered = buffer.renderedTrace()

        XCTAssertFalse(
            rendered.contains("launch-recovery"),
            "The oldest auth trace entry should be discarded once the buffer reaches capacity."
        )
        XCTAssertTrue(rendered.contains("credentials"))
        XCTAssertTrue(rendered.contains("renew"))
    }

    func testAuthFailureTraceBufferRendersCallSiteAndSortedDetails() {
        let buffer = AuthFailureTraceBuffer(
            capacity: 4,
            dateProvider: { Date(timeIntervalSince1970: 1_713_600_100) }
        )

        buffer.record(
            "transition-logout",
            details: [
                "operation": "renew credentials",
                "reason": "invalid_refresh_token"
            ],
            fileID: "Phi/AuthManager.swift",
            function: "logCredentialsFailure(_:operation:)",
            line: 321
        )

        let rendered = buffer.renderedTrace()

        XCTAssertTrue(rendered.contains("transition-logout"))
        XCTAssertTrue(rendered.contains("operation=renew credentials"))
        XCTAssertTrue(rendered.contains("reason=invalid_refresh_token"))
        XCTAssertTrue(rendered.contains("Phi/AuthManager.swift:321"))
        XCTAssertTrue(rendered.contains("logCredentialsFailure(_:operation:)"))
    }

    func testAuthFailureTraceBufferEmitsCallStackWhenProvided() {
        let buffer = AuthFailureTraceBuffer(
            capacity: 2,
            dateProvider: { Date(timeIntervalSince1970: 1_713_600_200) }
        )

        buffer.record(
            "transition-to-logged-out",
            details: ["reason": "invalid_refresh_token"],
            callStackSymbols: ["0  Phi  AuthManager.renew", "1  Phi  AuthManager.run"]
        )

        let rendered = buffer.renderedTrace()
        XCTAssertTrue(
            rendered.contains("stack:"),
            "Trace lines for forced-logout transitions must include the captured call stack so refresh-token reuse incidents can be correlated to the triggering caller."
        )
        XCTAssertTrue(rendered.contains("Phi  AuthManager.renew"))
    }

    func testLoginWindowGateKeepsOnboardingVisibleUntilAccountPhaseIsDone() {
        XCTAssertTrue(
            LoginWindowGate.shouldShowLoginWindow(
                hasRecoverableSession: true,
                accountPhase: .setName
            ),
            "A recoverable session should not bypass account-scoped onboarding before the phase reaches done."
        )
        XCTAssertFalse(
            LoginWindowGate.shouldShowLoginWindow(
                hasRecoverableSession: true,
                accountPhase: .done
            ),
            "A completed account-scoped onboarding phase should allow cold-open URLs to continue into Chromium."
        )
        XCTAssertTrue(
            LoginWindowGate.shouldShowLoginWindow(
                hasRecoverableSession: false,
                accountPhase: .done
            ),
            "Without a recoverable auth session, Phi should still present login."
        )
    }

    func testOnboardingPhaseRawValuesSkipLegacyImportDataWithoutChangingDone() {
        XCTAssertEqual(LoginController.Phase.login.rawValue, 0)
        XCTAssertEqual(LoginController.Phase.setName.rawValue, 1)
        XCTAssertEqual(LoginController.Phase.setTheme.rawValue, 2)
        XCTAssertEqual(LoginController.Phase.layoutSelection.rawValue, 3)
        XCTAssertEqual(LoginController.Phase.passwordManager.rawValue, 4)
        XCTAssertEqual(LoginController.Phase.nextStep.rawValue, 5)
        XCTAssertEqual(LoginController.Phase.done.rawValue, 6)
    }

    func testNextStepConsentRequiresLegalAgreementToBegin() {
        var state = NextStepConsentState(locale: Locale(identifier: "en_US"))

        XCTAssertFalse(state.hasAcceptedLegalTerms)
        XCTAssertTrue(state.sharesUsageMetrics)
        XCTAssertFalse(state.canBegin)

        state.hasAcceptedLegalTerms = true
        XCTAssertTrue(state.canBegin)

        state.sharesUsageMetrics = false
        XCTAssertTrue(state.canBegin)
    }

    func testNextStepMetricsConsentDefaultsByLocaleRegion() {
        XCTAssertFalse(
            NextStepConsentState(locale: Locale(identifier: "fr_FR")).sharesUsageMetrics
        )
        XCTAssertFalse(
            NextStepConsentState(locale: Locale(identifier: "en_GB")).sharesUsageMetrics
        )
        XCTAssertFalse(
            NextStepConsentState(locale: Locale(identifier: "de_CH")).sharesUsageMetrics
        )
        XCTAssertFalse(
            NextStepConsentState(locale: Locale(identifier: "el_CY")).sharesUsageMetrics
        )
        XCTAssertFalse(
            NextStepConsentState(locale: Locale(identifier: "en")).sharesUsageMetrics
        )
        XCTAssertTrue(
            NextStepConsentState(locale: Locale(identifier: "en_US")).sharesUsageMetrics
        )
        XCTAssertTrue(
            NextStepConsentState(locale: Locale(identifier: "zh_CN")).sharesUsageMetrics
        )
    }

    @MainActor
    func testNextStepGuideContentIntrinsicHeightGrowsForWrappedLocalizedCopy() {
        let shortTitles = [
            "Onboard your AI assistant",
            "Import data from another browser",
            "Have your AI assistant help you understand the fine print",
            "Enjoy using Phi Browser 🎉"
        ]
        let longTitle = Array(
            repeating: "A deliberately long localized onboarding instruction",
            count: 10
        ).joined(separator: " ")
        let longTitles = [longTitle, shortTitles[1], longTitle, shortTitles[3]]
        let shortController = NSHostingController(
            rootView: NextStepGuideContentView(stepTitles: shortTitles)
                .frame(width: NextStepGuideLayout.innerContentWidth)
        )
        let longController = NSHostingController(
            rootView: NextStepGuideContentView(stepTitles: longTitles)
                .frame(width: NextStepGuideLayout.innerContentWidth)
        )
        let fittingSize = CGSize(
            width: NextStepGuideLayout.innerContentWidth,
            height: .greatestFiniteMagnitude
        )

        let shortSize = shortController.sizeThatFits(in: fittingSize)
        let longSize = longController.sizeThatFits(in: fittingSize)

        XCTAssertGreaterThan(longSize.height, shortSize.height)
    }

    func testNextStepGuideOverflowIndicatorOnlyShowsWhileContentRemainsBelow() {
        XCTAssertFalse(
            NextStepGuideOverflow.shouldShowIndicator(
                contentBottom: 450,
                viewportHeight: 0
            )
        )
        XCTAssertFalse(
            NextStepGuideOverflow.shouldShowIndicator(
                contentBottom: 350,
                viewportHeight: 400
            )
        )
        XCTAssertFalse(
            NextStepGuideOverflow.shouldShowIndicator(
                contentBottom: 400,
                viewportHeight: 400
            )
        )
        XCTAssertFalse(
            NextStepGuideOverflow.shouldShowIndicator(
                contentBottom: 401,
                viewportHeight: 400
            )
        )
        XCTAssertTrue(
            NextStepGuideOverflow.shouldShowIndicator(
                contentBottom: 450,
                viewportHeight: 400
            )
        )
    }

    func testNextStepFinishButtonWidthExpandsForLongLocalizedTitles() {
        let standardWidth = NextStepFinishButtonLayout.width(for: "Let's Begin")
        let doubledWidth = NextStepFinishButtonLayout.width(
            for: "Let's Begin Let's Begin"
        )
        let maximumWidth = NextStepFinishButtonLayout.width(
            for: String(repeating: "A very long localized finish title ", count: 20)
        )

        XCTAssertEqual(standardWidth, NextStepFinishButtonLayout.minimumWidth)
        XCTAssertGreaterThan(doubledWidth, standardWidth)
        XCTAssertEqual(maximumWidth, NextStepFinishButtonLayout.maximumWidth)
    }

    @MainActor
    func testNextStepTitleAvoidsFixedBaselineClipping() {
        let controller = NextStepViewController()

        controller.loadView()
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(controller.titleLabel.bounds.height, 64, accuracy: 0.001)
        XCTAssertEqual(controller.titleLabel.maximumNumberOfLines, 1)
        XCTAssertEqual(controller.titleLabel.cell?.usesSingleLineMode, false)
    }

    @MainActor
    func testNextStepPlainConsentCopyCannotBeSelected() throws {
        let row = OnboardingCheckboxRow(
            title: "Help make Phi better by sharing usage metrics and crash reports",
            isChecked: true
        )
        let titleLabel = try XCTUnwrap(
            row.subviews.compactMap { $0 as? NSTextField }.first
        )

        XCTAssertFalse(titleLabel.isSelectable)
        XCTAssertFalse(titleLabel.isEditable)
        XCTAssertEqual(titleLabel.maximumNumberOfLines, 0)
        XCTAssertEqual(titleLabel.lineBreakMode, .byWordWrapping)
    }

    @MainActor
    func testNextStepLinkGradientUsesSpecifiedEndpointColors() throws {
        let title = NSMutableAttributedString(string: "Privacy")
        let range = NSRange(location: 0, length: title.length)

        NextStepLinkGradient.apply(to: title, range: range)

        let startColor = try XCTUnwrap(
            title.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        ).usingColorSpace(.sRGB)
        let endColor = try XCTUnwrap(
            title.attribute(.foregroundColor, at: title.length - 1, effectiveRange: nil) as? NSColor
        ).usingColorSpace(.sRGB)
        let resolvedStartColor = try XCTUnwrap(startColor)
        let resolvedEndColor = try XCTUnwrap(endColor)

        XCTAssertEqual(resolvedStartColor.redComponent, 148.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(resolvedStartColor.greenComponent, 82.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(resolvedStartColor.blueComponent, 249.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(resolvedEndColor.redComponent, 232.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(resolvedEndColor.greenComponent, 192.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(resolvedEndColor.blueComponent, 255.0 / 255.0, accuracy: 0.001)
    }

    @MainActor
    func testNextStepLinkTextViewDoesNotOverrideGradientForegroundColors() throws {
        let title = NSMutableAttributedString(
            string: "Privacy",
            attributes: [.font: NSFont.systemFont(ofSize: 15)]
        )
        let range = NSRange(location: 0, length: title.length)
        title.addAttribute(
            .link,
            value: try XCTUnwrap(URL(string: "https://phibrowser.com/privacy/")),
            range: range
        )
        NextStepLinkGradient.apply(to: title, range: range)

        let textView = NextStepLinkTextView(
            attributedString: title,
            preferredLayoutWidth: 200
        )

        XCTAssertTrue(textView.isSelectable)
        XCTAssertNil(textView.linkTextAttributes?[.foregroundColor])
        let textStorage = try XCTUnwrap(textView.textStorage)
        XCTAssertNotNil(textStorage.attribute(.foregroundColor, at: 0, effectiveRange: nil))
        XCTAssertNotNil(
            textStorage.attribute(
                .foregroundColor,
                at: textStorage.length - 1,
                effectiveRange: nil
            )
        )
    }

    @MainActor
    func testNextStepLinkTextViewIntrinsicHeightGrowsWhenTextWraps() {
        let title = NSAttributedString(
            string: Array(
                repeating: "A deliberately long localized legal agreement",
                count: 4
            ).joined(separator: " "),
            attributes: [.font: NSFont.systemFont(ofSize: 15)]
        )
        let narrowTextView = NextStepLinkTextView(
            attributedString: title,
            preferredLayoutWidth: 120
        )
        let wideTextView = NextStepLinkTextView(
            attributedString: title,
            preferredLayoutWidth: 396
        )

        XCTAssertGreaterThan(
            narrowTextView.intrinsicContentSize.height,
            wideTextView.intrinsicContentSize.height
        )
    }

    @MainActor
    func testGuestPrivacyLegalAgreementUsesRequestedLinkTitlesAndURLs() throws {
        let agreement = GuestPrivacyLegalAgreement.makeAttributedTitle(
            format: "I agree to the %1$@ and %2$@",
            privacyTitle: "Privacy Policy",
            termsTitle: "Terms of Service"
        )
        let privacyRange = try XCTUnwrap(
            agreement.string.range(of: "Privacy Policy")
        )
        let termsRange = try XCTUnwrap(
            agreement.string.range(of: "Terms of Service")
        )
        let privacyLocation = NSRange(
            privacyRange,
            in: agreement.string
        ).location
        let termsLocation = NSRange(
            termsRange,
            in: agreement.string
        ).location

        XCTAssertEqual(
            agreement.string,
            "I agree to the Privacy Policy and Terms of Service"
        )
        XCTAssertEqual(
            agreement.attribute(
                .link,
                at: privacyLocation,
                effectiveRange: nil
            ) as? URL,
            URL(string: "http://phibrowser.com/privacy/")
        )
        XCTAssertEqual(
            agreement.attribute(
                .link,
                at: termsLocation,
                effectiveRange: nil
            ) as? URL,
            URL(string: "http://phibrowser.com/terms/")
        )
    }

    @MainActor
    func testGuestPrivacyGuideUsesPlainLargerNoticeText() {
        let titles = [
            "No AI features until you sign in",
            "No Browser Memory either",
            "Sign in whenever you're ready"
        ]
        let fittingSize = CGSize(
            width: NextStepGuideLayout.contentWidth,
            height: .greatestFiniteMagnitude
        )
        let guestGuide = NSHostingController(
            rootView: GuestPrivacyGuideView(noticeTitles: titles)
                .frame(width: NextStepGuideLayout.contentWidth, height: 260)
        )

        XCTAssertGreaterThan(guestGuide.sizeThatFits(in: fittingSize).height, 0)
    }

    @MainActor
    func testGuestPrivacyPageRequiresLegalConsentBeforeBeginning() throws {
        let controller = GuestPrivacyConfirmationViewController()

        controller.loadView()

        XCTAssertEqual(
            controller.titleLabel.stringValue,
            NSLocalizedString(
                "oobe.guestPrivacy.title",
                value: "Before we begin.",
                comment: "Guest privacy confirmation - Page title shown before entering Guest Mode"
            )
        )
        XCTAssertEqual(
            controller.nextButton.title,
            NSLocalizedString(
                "oobe.guestPrivacy.beginButton",
                value: "Let's Begin",
                comment: "Guest privacy confirmation - Button that confirms the choices and enters Guest Mode"
            )
        )
        XCTAssertFalse(controller.nextButton.isEnabled)

        func checkboxRows(in view: NSView) -> [OnboardingCheckboxRow] {
            view.subviews.flatMap { subview in
                let current = (subview as? OnboardingCheckboxRow).map { [$0] }
                    ?? []
                return current + checkboxRows(in: subview)
            }
        }

        let rows = checkboxRows(in: controller.view)
        XCTAssertEqual(rows.count, 2)
        let expectedStates = [false, NextStepConsentState().sharesUsageMetrics]
        for (row, expectedState) in zip(rows, expectedStates) {
            let checkbox = try XCTUnwrap(
                row.subviews.compactMap { $0 as? NSButton }.first
            )
            XCTAssertEqual(
                checkbox.accessibilityValue() as? Int,
                expectedState
                    ? NSControl.StateValue.on.rawValue
                    : NSControl.StateValue.off.rawValue
            )
        }
    }

    @MainActor
    func testOnboardingRoutesGuestIntentToPrivacyConfirmation() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 800),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let windowController = OnboardingWindowController(window: window)
        let loginViewController = windowController.loginViewController
        loginViewController.isGuestModeActiveProvider = { false }
        window.contentViewController = loginViewController

        loginViewController.continueAsGuestAction()

        XCTAssertTrue(
            window.contentViewController
                is GuestPrivacyConfirmationViewController
        )
    }

    func testSkipOnboardingLaunchPolicyChoosesGuestModeAtTheOnboardingGate() {
        XCTAssertTrue(
            SkipOnboardingLaunchPolicy.shouldEnterGuestMode(
                hasLaunchArgument: true,
                canUseBrowser: false,
                isAccountDeletionInProgress: false,
                presentsGuestMigrationRecovery: false
            ),
            "A request to present onboarding should be answered with Guest entry when the skip argument is passed."
        )
        XCTAssertFalse(
            SkipOnboardingLaunchPolicy.shouldEnterGuestMode(
                hasLaunchArgument: false,
                canUseBrowser: false,
                isAccountDeletionInProgress: false,
                presentsGuestMigrationRecovery: false
            ),
            "Without the launch argument the onboarding window must be presented."
        )
        XCTAssertFalse(
            SkipOnboardingLaunchPolicy.shouldEnterGuestMode(
                hasLaunchArgument: true,
                canUseBrowser: true,
                isAccountDeletionInProgress: false,
                presentsGuestMigrationRecovery: false
            ),
            "A presentation requested from an already usable browser is a deliberate sign-in and must show."
        )
        XCTAssertFalse(
            SkipOnboardingLaunchPolicy.shouldEnterGuestMode(
                hasLaunchArgument: true,
                canUseBrowser: false,
                isAccountDeletionInProgress: true,
                presentsGuestMigrationRecovery: false
            ),
            "An account-deletion launch stays gated regardless of the skip argument."
        )
        XCTAssertFalse(
            SkipOnboardingLaunchPolicy.shouldEnterGuestMode(
                hasLaunchArgument: true,
                canUseBrowser: false,
                isAccountDeletionInProgress: false,
                presentsGuestMigrationRecovery: true
            ),
            "Guest-migration recovery keeps its journal-bound login presentation."
        )
    }

    func testOmniBoxSearchCoordinatorSuppressesOnlyTheNextAutomaticSearchAfterPrefill() {
        let coordinator = OmniBoxSearchCoordinator()

        coordinator.prepareForPrefilledOpen(text: "https://phibrowser.com", minInputLength: 1)

        XCTAssertFalse(
            coordinator.shouldPerformAutomaticSearch(for: "https://phibrowser.com", minInputLength: 1),
            "Prefilling the current tab URL should not immediately trigger a duplicate automatic search."
        )
        XCTAssertTrue(
            coordinator.shouldPerformAutomaticSearch(for: "https://phibrowser.com/path", minInputLength: 1),
            "Only the next automatic search should be suppressed so later edits still update suggestions."
        )
    }

    func testOmniBoxSearchCoordinatorAcceptsResponsesMatchingTheLatestQuery() {
        let coordinator = OmniBoxSearchCoordinator()

        _ = coordinator.beginRequest(query: "phi", source: .inputChange)
        _ = coordinator.beginRequest(query: "phibrowser", source: .openPrefill)

        XCTAssertFalse(
            coordinator.shouldAcceptResponse(forQuery: "phi"),
            "Stale suggestion responses should be ignored once a newer query has been issued."
        )
        XCTAssertTrue(
            coordinator.shouldAcceptResponse(forQuery: "phibrowser"),
            "Responses matching the latest query should be applied to the UI."
        )
    }

    func testOmniBoxSearchCoordinatorAcceptsStreamedResponsesForTheSameQuery() {
        let coordinator = OmniBoxSearchCoordinator()

        _ = coordinator.beginRequest(query: "phi", source: .inputChange)

        XCTAssertTrue(coordinator.shouldAcceptResponse(forQuery: "phi"))
        // Chromium streams multiple updates per request as providers respond, every
        // subsequent emission for the same query must still be applied.
        XCTAssertTrue(coordinator.shouldAcceptResponse(forQuery: "phi"))
    }

    func testOmniBoxSearchCoordinatorDoesNotArmSuppressionForEmptyPrefill() {
        let coordinator = OmniBoxSearchCoordinator()

        coordinator.prepareForPrefilledOpen(text: "", minInputLength: 1)

        XCTAssertTrue(
            coordinator.shouldPerformAutomaticSearch(for: "g", minInputLength: 1),
            "An empty prefill should not consume the user's first real search edit."
        )
    }

    func testOmniBoxTraceSessionFormatsReadableElapsedLogMessages() {
        var ticks: [UInt64] = [1_000_000_000, 1_125_000_000]
        let session = OmniBoxTraceSession(
            trigger: "address-bar",
            timeProvider: { ticks.removeFirst() }
        )

        let message = session.message(for: "request-start", details: "queryLength=12")

        XCTAssertTrue(message.contains("[OmniboxTrace]"))
        XCTAssertTrue(message.contains("trigger=address-bar"))
        XCTAssertTrue(message.contains("stage=request-start"))
        XCTAssertTrue(message.contains("elapsed=125.0ms"))
        XCTAssertTrue(message.contains("queryLength=12"))
    }

    func testHoverableButtonNSViewInvokesSecondaryActionOnRightMouseDown() throws {
        let button = HoverableButtonNSView(
            config: HoverableButtonConfig(title: "Test", displayMode: .titleOnly),
            action: {}
        )
        var didInvokeSecondaryAction = false
        button.secondaryAction = {
            didInvokeSecondaryAction = true
        }

        let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
        button.rightMouseDown(with: try XCTUnwrap(event))
        XCTAssertTrue(
            didInvokeSecondaryAction,
            "Pinned extension buttons should route right clicks through their secondary action."
        )
    }

    func testHoverableViewInvokesSecondaryClickActionOnRightMouseDown() throws {
        let view = HoverableView()
        var didInvokeSecondaryClick = false
        view.secondaryClickAction = {
            didInvokeSecondaryClick = true
        }

        let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
        view.rightMouseDown(with: try XCTUnwrap(event))
        XCTAssertTrue(
            didInvokeSecondaryClick,
            "Sidebar pinned extension items should route right clicks through their secondary click action."
        )
    }

    func testSecondaryClickPassthroughNSViewInvokesSecondaryActionOnRightMouseDown() throws {
        let view = SecondaryClickPassthroughNSView()
        var didInvokeSecondaryAction = false
        view.onSecondaryClick = {
            didInvokeSecondaryAction = true
        }

        let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
        view.rightMouseDown(with: try XCTUnwrap(event))
        XCTAssertTrue(
            didInvokeSecondaryAction,
            "Popover extension items should route right clicks through the shared secondary click passthrough."
        )
    }

    func testSecondaryClickContainerNSViewInvokesSecondaryActionOnRightMouseDown() throws {
        let view = SecondaryClickContainerNSView()
        var didInvokeSecondaryAction = false
        view.onSecondaryClick = {
            didInvokeSecondaryAction = true
        }

        let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
        view.rightMouseDown(with: try XCTUnwrap(event))
        XCTAssertTrue(
            didInvokeSecondaryAction,
            "Popover grid items should handle right clicks through their dedicated AppKit container."
        )
    }

    @MainActor
    private func waitForRenewTimer(
        in authManager: AuthManager,
        timeout: TimeInterval = 1
    ) async throws -> Timer {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if let timer = renewTimer(in: authManager), timer.isValid {
                return timer
            }
            await Task.yield()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }

        XCTFail("Expected renew timer to become available before timeout.")
        throw NSError(domain: "PhiBrowserTests", code: 1)
    }

    private func renewTimer(in authManager: AuthManager) -> Timer? {
        Mirror(reflecting: authManager).descendant("renewTimer") as? Timer
    }

    /// Builds a pre-V2 payload without applying the current fixed-alpha rule.
    private func rawEditableColors(from theme: Theme) -> ThemeEditableColors {
        let overlay = theme.colorPair(for: .windowOverlayBackground)
        let windowBackground = theme.colorPair(for: .windowBackground)
        return ThemeEditableColors(
            windowOverlayBackground: StoredColorPair(
                light: StoredRGBAColor(overlay.light.withAlphaComponent(0.23)),
                dark: StoredRGBAColor(overlay.dark.withAlphaComponent(0.67))
            ),
            windowBackground: StoredColorPair(
                light: StoredRGBAColor(windowBackground.light.withAlphaComponent(0.31)),
                dark: StoredRGBAColor(windowBackground.dark.withAlphaComponent(0.79))
            ),
            themeColor: StoredColorPair(theme.colorPair(for: .themeColor)),
            extensionActonColor: StoredColorPair(
                theme.colorPair(for: .extensionActonColor)
            )
        )
    }

    private func assertHSB(
        _ color: NSColor,
        saturation: CGFloat? = nil,
        brightness: CGFloat? = nil,
        alpha: CGFloat? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let resolvedColor = color.usingColorSpace(.extendedSRGB) ?? color
        var actualSaturation: CGFloat = 0
        var actualBrightness: CGFloat = 0
        var actualAlpha: CGFloat = 0
        resolvedColor.getHue(
            nil,
            saturation: &actualSaturation,
            brightness: &actualBrightness,
            alpha: &actualAlpha
        )

        if let saturation {
            XCTAssertEqual(actualSaturation, saturation, accuracy: 0.001, file: file, line: line)
        }
        if let brightness {
            XCTAssertEqual(actualBrightness, brightness, accuracy: 0.001, file: file, line: line)
        }
        if let alpha {
            XCTAssertEqual(actualAlpha, alpha, accuracy: 0.001, file: file, line: line)
        }
    }

    private func assertColor(
        _ actual: NSColor,
        equals expected: NSColor,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actualColor = actual.usingColorSpace(.extendedSRGB) ?? actual
        let expectedColor = expected.usingColorSpace(.extendedSRGB) ?? expected

        XCTAssertEqual(actualColor.redComponent, expectedColor.redComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actualColor.greenComponent, expectedColor.greenComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actualColor.blueComponent, expectedColor.blueComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actualColor.alphaComponent, expectedColor.alphaComponent, accuracy: 0.001, file: file, line: line)
    }
}

private final class AuthCredentialCommitTestState: @unchecked Sendable {
    let sessions = AuthSessionGeneration()
    var canonicalCredential = "persisted"
    var currentCredential: String?
}

private final class BookmarkMenuTestTarget: NSObject {
    @objc func menuAction(_ sender: Any?) {}
}

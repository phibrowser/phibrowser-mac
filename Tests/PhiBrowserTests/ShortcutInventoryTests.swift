// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
import AppKit
import Carbon.HIToolbox
#if !SHORTCUTS_HOSTLESS_TESTS
@testable import Phi
#endif

final class ShortcutInventoryTests: XCTestCase {
    private let key = ShortcutsKey(characters: "d", modifiers: [.control, .option])

    private func binding(
        _ id: Int, key: ShortcutsKey? = nil,
        scope: ShortcutBinding.Scope = .all,
        source: ShortcutBinding.Source = .configured
    ) -> ShortcutBinding {
        ShortcutBinding(commandID: id, key: key ?? self.key, scope: scope, source: source)
    }

    func testCustomOnlyCommandsConflictSymmetrically() {
        let first = CommandWrapper.IDC_DUPLICATE_TAB.rawValue
        let second = CommandWrapper.IDC_WINDOW_MUTE_SITE.rawValue
        let inventory = ShortcutInventory(bindings: [binding(first), binding(second)])
        XCTAssertEqual(inventory.conflicts(for: first, key: key, in: .all).map(\.commandID), [second])
        XCTAssertEqual(inventory.conflicts(for: second, key: key, in: .all).map(\.commandID), [first])
    }

    func testKeySearchIncludesEveryAliasAndUnknownCommandOwner() {
        let pageDown = ShortcutsKey(characters: "\u{F72D}", modifiers: .control)
        let nextTab = CommandWrapper.IDC_SELECT_NEXT_TAB.rawValue
        let inventory = ShortcutInventory(bindings: [
            binding(nextTab, key: ShortcutsKey(characters: "}", modifiers: .command)),
            binding(nextTab, key: pageDown, source: .hidden),
            binding(999999, key: pageDown, source: .menu),
        ])
        XCTAssertEqual(inventory.occupants(of: pageDown).map(\.commandID), [nextTab, 999999])
        XCTAssertEqual(inventory.bindings(for: nextTab).count, 2)
    }

    func testSameCommandAliasesNeverConflictWithThemselves() {
        let inventory = ShortcutInventory(bindings: [
            binding(1), binding(1, source: .menu), binding(1, source: .hidden),
        ])
        XCTAssertTrue(inventory.conflicts(for: 1, key: key, in: .all).isEmpty)
    }

    func testDisjointWindowScopesCanCoexistInBothDirections() {
        let inventory = ShortcutInventory(bindings: [
            binding(1, scope: .browser), binding(2, scope: .kiosk), binding(3, scope: .nonBrowser),
        ])
        XCTAssertTrue(inventory.conflicts(for: 1, key: key, in: .browser).isEmpty)
        XCTAssertTrue(inventory.conflicts(for: 2, key: key, in: .kiosk).isEmpty)
        XCTAssertTrue(inventory.conflicts(for: 3, key: key, in: .nonBrowser).isEmpty)
        XCTAssertEqual(inventory.occupants(of: key, in: .kiosk).map(\.commandID), [2])
        XCTAssertEqual(inventory.occupants(of: key, in: .nonBrowser).map(\.commandID), [3])
    }

    func testSharedBindingConflictsWithEachApplicableScope() {
        let inventory = ShortcutInventory(bindings: [
            binding(1, scope: .browser), binding(2, scope: .kiosk), binding(3), binding(4, scope: .nonBrowser),
        ])
        XCTAssertEqual(inventory.conflicts(for: 1, key: key, in: .browser).map(\.commandID), [3])
        XCTAssertEqual(inventory.conflicts(for: 2, key: key, in: .kiosk).map(\.commandID), [3])
        XCTAssertEqual(inventory.conflicts(for: 4, key: key, in: .nonBrowser).map(\.commandID), [3])
        XCTAssertEqual(inventory.conflicts(for: 3, key: key, in: .all).map(\.commandID), [1, 2, 4])
    }

    func testMenuEquivalentIdentityFindsLegacyShiftedPunctuation() {
        let legacy = ShortcutsKey(characters: "+", modifiers: .command)
        let recorded = ShortcutsKey(characters: "+", modifiers: [.command, .shift])
        let inventory = ShortcutInventory(bindings: [binding(1, key: legacy), binding(2, key: recorded)])
        XCTAssertEqual(inventory.conflicts(for: 2, key: recorded, in: .all).map(\.commandID), [1])
        XCTAssertEqual(inventory.occupants(of: legacy).count, 2)
    }

    func testShiftedKeypadDoesNotConflictWithUnshiftedDigitOrPunctuation() throws {
        for (code, character) in [(kVK_ANSI_Keypad1, "1"), (kVK_ANSI_KeypadPlus, "+")] {
            let unshifted = ShortcutsKey(characters: character, modifiers: .control)
            let shiftedEvent = try event(UInt16(code), character, [.control, .shift, .numericPad])
            let shifted = try XCTUnwrap(ShortcutsKey.recordingKey(for: shiftedEvent))
            let inventory = ShortcutInventory(bindings: [binding(1, key: unshifted), binding(2, key: shifted)])
            XCTAssertEqual(shifted.menuKeyEquivalent.modifiers, [.control, .shift])
            XCTAssertTrue(inventory.conflicts(for: 1, key: unshifted, in: .all).isEmpty)
            XCTAssertTrue(inventory.conflicts(for: 2, key: shifted, in: .all).isEmpty)
            let keys = try XCTUnwrap(ShortcutsKey.eventKeys(for: shiftedEvent))
            XCTAssertTrue(keys.matches(shifted))
            XCTAssertFalse(keys.matches(unshifted))
            XCTAssertFalse(try XCTUnwrap(ShortcutsKey.eventKeys(
                for: event(UInt16(code), character, [.control, .numericPad]))).matches(shifted))
            XCTAssertFalse(ShortcutOverride.excluding([shifted]).excludes(unshifted))
            let menuKey = ShortcutsKey(menuKeyEquivalent: character, modifiers: [.control, .shift])
            XCTAssertTrue(ShortcutOverride.excluding([shifted]).excludes(menuKey))
        }
    }

    func testDigitPresentationPreservesKeypadShiftAndOtherPunctuation() {
        for character in ["!", "@", "#", "$", "%", "^", "&", "*", "(", ")"] {
            let key = ShortcutsKey(characters: character, modifiers: .command)
            XCTAssertEqual(key.displayKey, key)
            XCTAssertEqual(key.keycapTokens, ["⌘", character])
        }
        let keypad = ShortcutsKey(characters: "*", modifiers: [.control, .shift], preservesShift: true)
        XCTAssertEqual(keypad.keycapTokens, ["⌃", "⇧", "*"])
        XCTAssertEqual(keypad.displayKey, keypad)
        for character in ["+", "{", "?", "1"] {
            let key = ShortcutsKey(characters: character, modifiers: [.command, .shift])
            XCTAssertEqual(key.displayKey, key)
        }
        let symbol = ShortcutsKey(characters: "!", modifiers: [.command, .shift])
        let digit = ShortcutsKey(characters: "1", modifiers: .command)
        let inventory = ShortcutInventory(bindings: [binding(1, key: symbol), binding(2, key: digit)])
        XCTAssertTrue(inventory.conflicts(for: 1, key: symbol, in: .all).isEmpty)
        XCTAssertEqual(inventory.occupants(of: symbol).map(\.commandID), [1])
    }

    func testInputOrderAndDuplicateMetadataDoNotChangeResults() {
        let records = [binding(2, source: .menu), binding(1), binding(2, source: .hidden)]
        let inventory = ShortcutInventory(bindings: records)
        XCTAssertEqual(inventory.bindings, ShortcutInventory(bindings: Array(records.reversed()) + records).bindings)
        XCTAssertEqual(inventory.bindings.count, 3)
    }

    func testDifferentChordsDoNotConflict() {
        let inventory = ShortcutInventory(bindings: [binding(1)])
        let other = ShortcutsKey(characters: "d", modifiers: [.command, .option])
        XCTAssertTrue(inventory.occupants(of: other).isEmpty)
    }

    func testNativeActionKeepsItsIdentityAndReadableTitle() {
        let native = ShortcutBinding(owner: .nativeAction("copy:"), key: key,
                                     scope: .all, source: .menu, title: "Copy")
        let inventory = ShortcutInventory(bindings: [native, binding(1)])
        let conflicts = inventory.conflicts(for: 1, key: key, in: .all)
        XCTAssertEqual(conflicts.map(\.owner), [.nativeAction("copy:")])
        XCTAssertNil(conflicts.first?.commandID)
        XCTAssertEqual(conflicts.first?.title, "Copy")
    }

    private func event(_ code: UInt16, _ characters: String, _ modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                      timestamp: 0, windowNumber: 0, context: nil,
                                      characters: characters, charactersIgnoringModifiers: characters,
                                      isARepeat: false, keyCode: code))
    }

    func testOnlyPlainEscapeAndBackspaceControlRecording() throws {
        XCTAssertEqual(ShortcutsKey.recordingAction(for: try event(53, "\u{1B}", [])), .cancel)
        XCTAssertEqual(ShortcutsKey.recordingAction(for: try event(51, "\u{7F}", [])), .disable)
        for (code, characters, modifiers) in [
            (UInt16(53), "\u{1B}", NSEvent.ModifierFlags.control),
            (UInt16(51), "\u{7F}", NSEvent.ModifierFlags.command),
        ] {
            guard case .key(let key) = ShortcutsKey.recordingAction(
                for: try event(code, characters, modifiers), inputSourceIdentifier: "com.apple.keylayout.US"
            ) else { return XCTFail("Modified control key was treated as a recording control") }
            XCTAssertEqual(key.modifiers, modifiers)
        }
        XCTAssertEqual(ShortcutsKey.recordingAction(for: try event(53, "\u{1B}", .shift)), .unsupported)
    }

    func testShiftOnlyPrintableKeysAreRejectedWithoutRejectingNavigationAndFunctionKeys() throws {
        XCTAssertNil(ShortcutsKey.recordingKey(for: try event(0, "A", .shift), inputSourceIdentifier: "com.apple.keylayout.US"))
        XCTAssertNotNil(ShortcutsKey.recordingKey(for: try event(0, "A", [.control, .shift]), inputSourceIdentifier: "com.apple.keylayout.US"))
        XCTAssertNotNil(ShortcutsKey.recordingKey(for: try event(48, "\u{19}", .shift), inputSourceIdentifier: "com.apple.keylayout.US"))
        XCTAssertNotNil(ShortcutsKey.recordingKey(for: try event(122, "\u{F704}", .shift), inputSourceIdentifier: "com.apple.keylayout.US"))
    }

    func testBareFunctionKeysCanBeRecordedWithoutCapturingTypingOrNavigation() throws {
        for (code, character) in [(UInt16(122), "\u{F704}"), (111, "\u{F70F}"), (90, "\u{F717}")] {
            let expected = ShortcutsKey(characters: character, modifiers: [])
            for flags: NSEvent.ModifierFlags in [[], .function] {
                XCTAssertEqual(ShortcutsKey.recordingAction(for: try event(code, character, flags)), .key(expected))
            }
            XCTAssertTrue(KioskGlobalShortcutRegistrar.configurations(for: expected, isEnabled: true, layout: nil).isEmpty)
        }
        for (code, character) in [(UInt16(0), "a"), (48, "\t"), (126, "\u{F700}")] {
            XCTAssertEqual(ShortcutsKey.recordingAction(for: try event(code, character, [])), .unsupported)
        }
    }

    func testForwardDeleteDoesNotDisableTheBinding() throws {
        XCTAssertEqual(ShortcutsKey.recordingAction(for: try event(117, "\u{F728}", [])), .unsupported)
        guard case .key = ShortcutsKey.recordingAction(for: try event(117, "\u{F728}", .command)) else {
            return XCTFail("Modified Forward Delete should be recorded")
        }
    }
}

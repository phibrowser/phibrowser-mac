// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Phi

final class SystemShortcutBindingsTests: XCTestCase {
    private let key = ShortcutsKey(characters: "1", modifiers: .control)
    private let layout = KioskGlobalShortcutRegistrar.KeyboardLayout(inputSourceIdentifier: "com.apple.keylayout.US") { code, flags in
        switch Int(code) {
        case kVK_ANSI_1: return flags.contains(.shift) ? "!" : "1"
        case kVK_ANSI_2: return flags.contains(.shift) ? "@" : "2"
        case kVK_ANSI_Keypad1: return "1"
        case kVK_ANSI_Equal: return flags.contains(.shift) ? "+" : "="
        case kVK_ANSI_J: return flags.contains(.shift) ? "J" : "j"
        default: return nil
        }
    }

    private func record(_ code: Int = kVK_ANSI_1, modifiers: Int = controlKey, enabled: Bool = true) -> [String: Any] {
        [kHISymbolicHotKeyCode as String: code,
         kHISymbolicHotKeyModifiers as String: modifiers,
         kHISymbolicHotKeyEnabled as String: enabled]
    }

    private func binding(_ key: ShortcutsKey, source: ShortcutBinding.Source = .configured) -> ShortcutBinding {
        .init(commandID: CommandWrapper.PHI_SELECT_SPACE_0.rawValue, key: key, scope: .browser, source: source)
    }

    func testEnabledReservationHasDistinctSystemOwnerAndAllWindowScopes() throws {
        let bindings = SystemShortcutBindings.conflicts(with: [binding(key)], records: [record()], layout: layout)
        let system = try XCTUnwrap(bindings.first)
        XCTAssertEqual(bindings.count, 1)
        XCTAssertEqual(system.owner, .system)
        XCTAssertEqual(system.source, .system)
        XCTAssertEqual(system.scope, .all)
        XCTAssertNil(system.commandID)
        XCTAssertEqual(system.key, key)
        let inventory = ShortcutInventory(bindings: bindings + [binding(key)])
        XCTAssertEqual(inventory.conflicts(for: CommandWrapper.PHI_SELECT_SPACE_0.rawValue,
                                           key: key, in: .browser).map(\.owner), [.system])
    }

    func testFunctionKeyReservationsPreserveModifiersAndAcceptCarbonFnFlag() {
        let bare = ShortcutsKey(characters: "\u{F70F}", modifiers: [])
        let shifted = ShortcutsKey(characters: "\u{F70F}", modifiers: .shift)
        for fn in [0, Int(kEventKeyModifierFnMask)] {
            for (modifiers, expected) in [(0, bare), (shiftKey, shifted)] {
                let conflicts = SystemShortcutBindings.conflicts(
                    with: [binding(bare), binding(shifted)],
                    records: [record(kVK_F12, modifiers: modifiers | fn)], layout: nil)
                XCTAssertEqual(conflicts.map(\.key), [expected])
            }
        }
    }

    func testShiftedKeypadDoesNotInheritTheControlOneSystemWarning() {
        let shifted = ShortcutsKey(characters: "1", modifiers: [.control, .shift], preservesShift: true)
        let ordinaryReservations = [record(), record(kVK_ANSI_Keypad1)]
        XCTAssertTrue(SystemShortcutBindings.conflicts(with: [binding(shifted)],
            records: ordinaryReservations, layout: layout).isEmpty)
        XCTAssertEqual(SystemShortcutBindings.conflicts(with: [binding(shifted)],
            records: [record(kVK_ANSI_Keypad1, modifiers: controlKey | shiftKey)], layout: layout).map(\.key), [shifted])
    }

    func testDisabledMalformedAndDifferentChordsDoNotReserveKeys() {
        let records = [record(enabled: false), record(kVK_ANSI_2), record(modifiers: cmdKey),
                       record(-1), record(65535),
                       [kHISymbolicHotKeyEnabled as String: true],
                       [kHISymbolicHotKeyCode as String: kVK_ANSI_1]]
        XCTAssertTrue(SystemShortcutBindings.conflicts(with: [binding(key)], records: records, layout: layout).isEmpty)
    }

    func testDuplicateSystemRecordsAndCommandAliasesProduceOneWarningBinding() {
        let bindings = [binding(key), binding(key, source: .hidden)]
        XCTAssertEqual(SystemShortcutBindings.conflicts(with: bindings, records: [record(), record()], layout: layout).count, 1)
    }

    func testHiddenAliasIsCheckedEvenWhenPrimaryKeyIsFree() {
        let other = ShortcutsKey(characters: "2", modifiers: .control)
        let result = SystemShortcutBindings.conflicts(with: [binding(other), binding(key, source: .hidden)],
                                                     records: [record()], layout: layout)
        XCTAssertEqual(result.map(\.key), [key])
    }

    func testPhysicalKeyIsResolvedUsingCurrentLayout() {
        let swapped = KioskGlobalShortcutRegistrar.KeyboardLayout(inputSourceIdentifier: "test.swapped") { code, _ in
            code == UInt16(kVK_ANSI_J) ? "1" : nil
        }
        XCTAssertTrue(SystemShortcutBindings.conflicts(with: [binding(key)], records: [record()], layout: swapped).isEmpty)
        XCTAssertEqual(SystemShortcutBindings.conflicts(with: [binding(key)], records: [record(kVK_ANSI_J)], layout: swapped).count, 1)
    }

    func testLegacyShiftedPunctuationUsesPhysicalShiftAndSpecialKeysNeedNoLayout() {
        let plus = ShortcutsKey(characters: "+", modifiers: .command)
        XCTAssertEqual(SystemShortcutBindings.conflicts(with: [binding(plus)],
            records: [record(kVK_ANSI_Equal, modifiers: cmdKey | shiftKey)], layout: layout).map(\.key), [plus])
        let arrow = ShortcutsKey(characters: "\u{F703}", modifiers: .control)
        XCTAssertEqual(SystemShortcutBindings.conflicts(with: [binding(arrow)],
            records: [record(kVK_RightArrow)], layout: nil).map(\.key), [arrow])
        XCTAssertTrue(SystemShortcutBindings.conflicts(with: [binding(key)], records: [record()], layout: nil).isEmpty)
    }
}

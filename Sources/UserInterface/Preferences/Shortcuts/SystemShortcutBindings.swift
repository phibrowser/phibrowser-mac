// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Carbon.HIToolbox

/// Read-only system reservations. Symbolic hotkeys expose physical chords but
/// no action names, so all matches share an informational system owner.
enum SystemShortcutBindings {
    static func current(conflictingWith bindings: [ShortcutBinding]) -> [ShortcutBinding] {
        assert(Thread.isMainThread)
        var hotKeys: Unmanaged<CFArray>?
        let status = CopySymbolicHotKeys(&hotKeys)
        let records = hotKeys?.takeRetainedValue() as? [[String: Any]]
        guard status == noErr, let records else {
            AppLogError("[SystemShortcutBindings] Failed to read system shortcuts (OSStatus \(status))")
            return []
        }
        return conflicts(with: bindings, records: records,
                         layout: KioskGlobalShortcutRegistrar.KeyboardLayout.current())
    }

    static func conflicts(
        with bindings: [ShortcutBinding],
        records: [[String: Any]],
        layout: KioskGlobalShortcutRegistrar.KeyboardLayout?
    ) -> [ShortcutBinding] {
        let enabled = Set(records.compactMap { record -> KioskGlobalShortcutRegistrar.Configuration? in
            guard record[kHISymbolicHotKeyEnabled as String] as? Bool == true,
                  let code = record[kHISymbolicHotKeyCode as String] as? Int,
                  let rawModifiers = record[kHISymbolicHotKeyModifiers as String] as? Int,
                  let modifiers = UInt32(exactly: rawModifiers),
                  (0...127).contains(code) else { return nil }
            return .init(keyCode: UInt32(code), modifiers: modifiers)
        })
        guard !enabled.isEmpty else { return [] }
        return Set(bindings.filter { $0.owner != .system }.map(\.key)).compactMap { key in
            // Reuse the existing pure Carbon chord resolver, including layout,
            // shifted punctuation and physical aliases. Never register a hotkey.
            let chords: [KioskGlobalShortcutRegistrar.Configuration]
            if key.isStandardFunctionKey, let code = key.carbonSpecialKeyCode,
               !key.modifiers.contains(.function) {
                // Carbon may mark the function key itself with Fn, even for bare F12.
                let modifiers = KioskGlobalShortcutRegistrar.carbonModifiers(key.modifiers)
                chords = [.init(keyCode: code, modifiers: modifiers),
                          .init(keyCode: code, modifiers: modifiers | UInt32(kEventKeyModifierFnMask))]
            } else {
                chords = KioskGlobalShortcutRegistrar.configurations(for: key, isEnabled: true, layout: layout)
            }
            guard chords.contains(where: enabled.contains) else { return nil }
            return ShortcutBinding(owner: .system, key: key, scope: .all, source: .system)
        }
    }
}

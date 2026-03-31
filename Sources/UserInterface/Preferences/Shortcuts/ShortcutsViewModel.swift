// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import Combine
class ShortcutsViewModel: ObservableObject {
    @Published var sections: [(category: String, items: [ShortcutItem])] = []
    @Published var editingCommand: CommandWrapper?
    @Published var hiddenGroups: Set<Shortcuts.Group> = [.help, .bookmarks]
    
    init() {
        rebuildSections()
    }
    
    func rebuildSections() {
        var newSections: [(category: String, items: [ShortcutItem])] = []
        
        Shortcuts.Group.allCases
            .filter { !hiddenGroups.contains($0) }
            .forEach { group in
                let items = group.commands.map { command in
                    let key = Shortcuts.key(for: command)
                    let conflictingCommands = findConflictingCommands(for: command, currentKey: key)
                    
                    return ShortcutItem(
                        id: command,
                        command: command,
                        name: command.displayName,
                        shortcutKey: key,
                        shortcutDisplay: key?.displayString ?? NSLocalizedString("Add New", comment: "Shortcuts settings - Placeholder text when no shortcut is assigned"),
                        isOverridden: Shortcuts.isOverridden(command),
                        conflictingCommands: conflictingCommands
                    )
                }
                
                if !items.isEmpty {
                    newSections.append((category: group.title, items: items))
                }
            }
        
        sections = newSections
    }
    
    private func findConflictingCommands(for command: CommandWrapper, currentKey: ShortcutsKey?) -> [CommandWrapper] {
        guard let currentKey = currentKey else { return [] }
        
        var conflicts: [CommandWrapper] = []
        
        Shortcuts.DefaultShortcuts.keys.forEach { otherCommand in
            guard otherCommand != command else { return }
            if let otherKey = Shortcuts.key(for: otherCommand),
               otherKey == currentKey {
                conflicts.append(otherCommand)
            }
        }
        return conflicts
    }
    
    func setCustomShortcut(for command: CommandWrapper, keyChord: KeyChord) {
        let key = ShortcutsKey(characters: keyChord.characters, modifiers: keyChord.modifiers)
        
        Shortcuts.override(key, for: command)
        rebuildSections()
    }
    
    /// Disables the shortcut by storing an explicit empty override.
    func disableShortcut(for command: CommandWrapper) {
        Shortcuts.override(nil, for: command, remove: false)
        rebuildSections()
    }
    
    /// Restores the default shortcut for the command.
    func restoreDefaultShortcut(for command: CommandWrapper) {
        Shortcuts.override(nil, for: command, remove: true)
        rebuildSections()
    }
    
    func restoreAllShortcuts() {
        Shortcuts.restoreOverrides()
        rebuildSections()
    }
    
    private func normalizeCharacters(_ characters: String) -> String {
        if characters == String(format: "%c", NSDeleteCharacter) {
            return String(format: "%c", NSBackspaceCharacter)
        }
        if characters.count > 1 {
            return String(characters.prefix(1))
        }
        return characters.lowercased()
    }
}

struct ShortcutItem: Identifiable {
    let id: CommandWrapper
    let command: CommandWrapper
    let name: String
    let shortcutKey: ShortcutsKey?
    let shortcutDisplay: String
    let isOverridden: Bool
    let conflictingCommands: [CommandWrapper]
    
    var hasConflict: Bool {
        !conflictingCommands.isEmpty
    }
}

struct KeyChord {
    let characters: String
    let modifiers: NSEvent.ModifierFlags
    
    init?(fromEvent event: NSEvent) {
        guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty else {
            return nil
        }
        
        let relevantModifierFlags: NSEvent.ModifierFlags = [.command, .option, .shift, .control]
        let modifiers = event.modifierFlags.intersection(relevantModifierFlags)
        if modifiers.isEmpty {
            return nil
        }
        
        // Normalize characters
        var normalizedChars = chars
        if chars == String(format: "%c", NSDeleteCharacter) {
            normalizedChars = String(format: "%c", NSBackspaceCharacter)
        } else if chars.count > 1 {
            normalizedChars = String(chars.prefix(1))
        }
        normalizedChars = normalizedChars.lowercased()
        
        self.characters = normalizedChars
        self.modifiers = modifiers
    }
}

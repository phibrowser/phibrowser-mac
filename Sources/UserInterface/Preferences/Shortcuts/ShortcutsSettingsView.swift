// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI
import AppKit
import Combine
struct ShortcutsSettingsView: View {
    @StateObject private var viewModel = ShortcutsViewModel()
    @State private var searchText: String = ""
    @FocusState private var isSearchFieldFocused: Bool
    
    private var filteredSections: [(category: String, items: [ShortcutItem])] {
        guard !searchText.isEmpty else {
            return viewModel.sections
        }
        
        let query = searchText.lowercased()
        return viewModel.sections.compactMap { section in
            let filteredItems = section.items.filter { item in
                item.name.lowercased().contains(query) ||
                item.shortcutDisplay.lowercased().contains(query) ||
                item.command.searchKeywords.contains(where: { $0.contains(query) })
            }
            
            return filteredItems.isEmpty ? nil : (category: section.category, items: filteredItems)
        }
    }
    
    var body: some View {
        let sections = filteredSections
        
        return VStack(spacing: 0) {
            VStack {
                HStack {
                    Text(NSLocalizedString("Shortcuts", comment: "Shortcuts settings - Section title for keyboard shortcuts"))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.secondary)
                    
                    Spacer()
                    
                    Button {
                        viewModel.restoreAllShortcuts()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11, weight: .medium))
                            Text(NSLocalizedString("Restore all shortcuts", comment: "Shortcuts settings - Button to reset all shortcuts to default"))
                                .font(.system(size: 13))
                        }
                    }
                    .buttonStyle(.bordered)
                }
                
                // Container with search bar and list
                VStack(spacing: 0) {
                    // Search bar
                    HStack(spacing: 8) {
                        HStack {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(.secondary)
                                .frame(width: 16, height: 16)
                                .padding(.leading, 12)
                                .padding(.top, 12)
                                .padding(.bottom, 12)
                            
                            TextField(NSLocalizedString("Find shortcut keys", comment: "Shortcuts settings - Search field placeholder to find shortcuts"), text: $searchText)
                                .textFieldStyle(.plain)
                                .padding(.vertical, 6)
                                .focused($isSearchFieldFocused)
                        }
                    }
                    // separator between searchbar and list
                    Rectangle()
                        .fill(Color(.separatorColor))
                        .frame(height: 1)
                        .padding(.leading, 0)
                        .padding(.trailing, 0)
                    
                    // Shortcuts list with empty state
                    ZStack {
                        List {
                            ForEach(sections, id: \.category) { section in
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(section.category)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(.secondary)
                                        .frame(height: 35)
                                        .padding(.vertical, 8)
                                    
                                    Rectangle()
                                        .fill(Color(.separatorColor))
                                        .frame(height: 1)
                                    
                                    ForEach(section.items) { item in
                                        ShortcutRowView(
                                            item: item,
                                            isEditing: viewModel.editingCommand == item.command,
                                            handler: { action in
                                                handleAction(for: item, action: action)
                                            }
                                        )
                                        .overlay(alignment: .bottom) {
                                            Rectangle()
                                                .fill(Color(.separatorColor))
                                                .frame(height: 1)
                                        }
                                        .overlay {
                                            if viewModel.editingCommand == item.command {
                                                KeyCaptureView { event in
                                                    handleKeyCapture(event, for: item.command)
                                                }
                                                .allowsHitTesting(false)
                                            }
                                        }
                                    }
                                }
                                // macOS list rows add 4pt padding by default, so use 4pt
                                // here to land on the designed 12pt visual spacing.
                                .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 4, trailing: 4))
                                .listRowSeparator(.hidden)
                            }
                        }
                        .listStyle(.plain)
                        .listSectionSeparator(.hidden)
                        .scrollContentBackground(.hidden)
                        .opacity(sections.isEmpty ? 0 : 1)
                        
                        if sections.isEmpty {
                            Text(NSLocalizedString("No Results", comment: "Shortcuts settings - Empty state text when no shortcuts match search"))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .themedBackground(ThemedColor(light: .white,
                                              dark: NSColor(hex: 0xFFFFFF, alpha: 0.02)))
                .cornerRadius(8)
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(.commonBorder), lineWidth: 1)
                }
            }
            .padding(.vertical, 36)
            .padding(.horizontal, 36)
        }
        .background(
            CommandShortcutCaptureView { event in
                handleGlobalShortcut(event)
            }
            .allowsHitTesting(false)
        )
    }
    
    private func handleAction(for item: ShortcutItem, action: ShortcutRowView.Action) {
        switch action {
        case .restoreTapped:
            viewModel.restoreDefaultShortcut(for: item.command)
            cancelEditing()
        case .editTapped:
            if viewModel.editingCommand == item.command {
                cancelEditing()
            } else {
                viewModel.editingCommand = item.command
            }
        }
    }
    
    private func handleKeyCapture(_ event: NSEvent, for command: CommandWrapper) {
        // ESC cancels recording
        if event.keyCode == 53 {
            cancelEditing()
            return
        }
        
        // Backspace (51) removes/disables the shortcut
        if event.keyCode == 51 {
            viewModel.disableShortcut(for: command)
            cancelEditing()
            return
        }
        
        if let keyChord = KeyChord(fromEvent: event) {
            viewModel.setCustomShortcut(for: command, keyChord: keyChord)
            cancelEditing()
        }
    }
    
    private func cancelEditing() {
        viewModel.editingCommand = nil
        if isSearchFieldFocused {
            isSearchFieldFocused = false
        }
    }
    
    private func handleGlobalShortcut(_ event: NSEvent) {
        guard viewModel.editingCommand == nil else { return }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if  modifiers.contains(.command),
            event.charactersIgnoringModifiers?.lowercased() == "f" {
            isSearchFieldFocused = true
        } else if event.keyCode == 53 {
            // esc
            isSearchFieldFocused = false
        }
    }
}

// MARK: - Row View
struct ShortcutRowView: View {
    enum Action {
        case restoreTapped
        case editTapped
    }
    
    let item: ShortcutItem
    let isEditing: Bool
    let handler: (Action) -> Void
    
    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(.primary)
                    .frame(height: 16)
                
                if item.hasConflict {
                    Text(String(format: NSLocalizedString("Conflicts with: %@", comment: "Shortcuts settings - Warning text showing conflicting shortcuts"), item.conflictingCommands.map { $0.displayName }.joined(separator: ", ")))
                        .font(.system(size: 11))
                        .foregroundColor(.yellow)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .padding(.vertical, 10)
            
            Spacer()
            
            if item.isOverridden {
                Button(NSLocalizedString("Restore", comment: "Shortcuts settings - Button to restore single shortcut to default")) {
                    handler(.restoreTapped)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            
            Button(action: { handler(.editTapped) }) {
                Text(isEditing ? NSLocalizedString("Press shortcut…", comment: "Shortcuts settings - Prompt text when recording new shortcut") : item.shortcutDisplay)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(isEditing ? .primary : .secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 3)
                    .frame(minWidth: 80)
                    .background(
                        ZStack {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(isEditing ?
                                      Color.accentColor.opacity(0.1) :
                                        Color(NSColor.controlBackgroundColor)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(
                                            isEditing ?
                                            Color.accentColor :
                                                Color(NSColor.separatorColor),
                                            lineWidth: isEditing ? 1.5 : 0.5
                                        )
                                )
                        }
                    )
            }
            .buttonStyle(.plain)
            .scaleEffect(isEditing ? 1.02 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: isEditing)
        }
        .frame(minHeight: 42)
    }
}

// MARK: - Key Capture View

struct KeyCaptureView: NSViewRepresentable {
    let onKeyEvent: (NSEvent) -> Void
    
    func makeNSView(context: Context) -> KeyCaptureNSView {
        let view = KeyCaptureNSView()
        view.onKeyEvent = onKeyEvent
        return view
    }
    
    func updateNSView(_ nsView: KeyCaptureNSView, context: Context) {
        nsView.onKeyEvent = onKeyEvent
    }
}

class KeyCaptureNSView: NSView {
    var onKeyEvent: ((NSEvent) -> Void)?
    private var eventMonitor: Any?
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        
        if window != nil {
            startMonitoring()
        } else {
            stopMonitoring()
        }
    }
    
    private func startMonitoring() {
        stopMonitoring()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.onKeyEvent?(event)
            return nil // Consume the event
        }
    }
    
    private func stopMonitoring() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
    
    deinit {
        stopMonitoring()
    }
}

// MARK: - Command Shortcut Capture View

struct CommandShortcutCaptureView: NSViewRepresentable {
    let onKeyEvent: (NSEvent) -> Void
    
    func makeNSView(context: Context) -> CommandShortcutCaptureNSView {
        let view = CommandShortcutCaptureNSView()
        view.onKeyEvent = onKeyEvent
        return view
    }
    
    func updateNSView(_ nsView: CommandShortcutCaptureNSView, context: Context) {
        nsView.onKeyEvent = onKeyEvent
    }
}

final class CommandShortcutCaptureNSView: NSView {
    var onKeyEvent: ((NSEvent) -> Void)?
    private var eventMonitor: Any?
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            startMonitoring()
        } else {
            stopMonitoring()
        }
    }
    
    private func startMonitoring() {
        stopMonitoring()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.onKeyEvent?(event)
            return event
        }
    }
    
    private func stopMonitoring() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
    
    deinit {
        stopMonitoring()
    }
}

extension View {
    func debugBorder(_ color: Color = .red) -> some View {
        self.overlay(
            Rectangle()
                .stroke(color, lineWidth: 1)
        )
    }
}

#Preview {
    ShortcutsSettingsView()
}

// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI

struct LibrarySpaceCard: View {
    @ObservedObject var space: Space
    let manager: SpaceManager
    let onDragBegin: () -> Void
    let onDragMove: (CGFloat) -> Void
    let onDragEnd: (Bool) -> Void
    @StateObject private var contents: LibrarySpaceContents
    @Environment(\.phiTheme) private var theme
    @Environment(\.phiAppearance) private var appearance
    @State private var showsIconPicker = false
    @State private var showsThemeEditor = false
    @State private var isEditingName = false
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    init(space: Space, store: LocalStore, manager: SpaceManager,
         onDragBegin: @escaping () -> Void, onDragMove: @escaping (CGFloat) -> Void, onDragEnd: @escaping (Bool) -> Void) {
        self.space = space
        self.manager = manager
        self.onDragBegin = onDragBegin
        self.onDragMove = onDragMove
        self.onDragEnd = onDragEnd
        _contents = StateObject(wrappedValue: LibrarySpaceContents(store: store, space: space))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
                .padding(.horizontal, 20)
            LibrarySpaceManagementView(contents: contents)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottomLeading) {
                    LibrarySpaceDragHandle(spaceID: space.spaceId, tint: ThemedColor.textSecondary.resolve(theme: theme, appearance: appearance),
                                           onBegin: onDragBegin, onMove: onDragMove, onEnd: onDragEnd)
                        .frame(width: 24, height: 24)
                        .padding(.leading, 12)
                }
                .padding(.horizontal, 8)
        }
        .padding(.vertical, 20)
        .themedForeground(.textPrimary)
        .onChange(of: nameFocused) { _, focused in
            if !focused && isEditingName { commitName() }
        }
        .onChange(of: space.content) { _, content in
            AppLogInfo("[LibrarySpaces] card.updated space=\(space.spaceId) nameLength=\(content.name.count) icon=\(content.iconName) profile=\(content.profileId)")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                AppLogInfo("[LibrarySpaces] icon.open space=\(space.spaceId)")
                showsIconPicker = true
            } label: {
                SpaceIconView(storedValue: space.iconName, size: 23, symbolWeight: .medium,
                              tint: color(.textPrimary))
                    .frame(width: 32, height: 32)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(NSLocalizedString("library.spaces.editIcon", value: "Change Space icon", comment: "Library Space card - icon picker button"))
            .popover(isPresented: $showsIconPicker) {
                IconPicker(selected: IconPickerSelection.fromStorageValue(space.iconName), showsGroups: true) { selection in
                    AppLogInfo("[LibrarySpaces] icon.commit space=\(space.spaceId) accepted=\(manager.acceptsStoreAction(from: space.storeIdentifier)) value=\(selection.storageValue)")
                    manager.changeIcon(spaceId: space.spaceId, iconName: selection.storageValue,
                                       expectedStoreIdentifier: space.storeIdentifier)
                    showsIconPicker = false
                }
                .padding(12)
                .environment(\.phiTheme, theme)
            }
            if isEditingName {
                TextField(NSLocalizedString("library.spaces.name", value: "Space name", comment: "Library Space card - inline name editor"), text: $name)
                    .textFieldStyle(.plain)
                    .focused($nameFocused)
                    .onSubmit(commitName)
                    .onExitCommand {
                        AppLogInfo("[LibrarySpaces] name.cancel space=\(space.spaceId)")
                        isEditingName = false
                        nameFocused = false
                    }
            } else {
                Button {
                    AppLogInfo("[LibrarySpaces] name.begin space=\(space.spaceId)")
                    name = space.name
                    isEditingName = true
                    nameFocused = true
                } label: {
                    Text(space.name)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(space.name)
            }
            Button {
                showsThemeEditor = true
            } label: {
                Image(systemName: "paintpalette")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 28, height: 28)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(NSLocalizedString("library.spaces.editTheme", value: "Edit Theme", comment: "Library Space card - theme editor button"))
            .accessibilityLabel(NSLocalizedString("library.spaces.editTheme", value: "Edit Theme", comment: "Library Space card - theme editor button"))
            .popover(isPresented: $showsThemeEditor, arrowEdge: .bottom) {
                SpaceThemeEditorView(spaceId: space.spaceId) {
                    showsThemeEditor = false
                }
                .environment(\.phiTheme, theme)
                .environment(\.phiAppearance, appearance)
            }
        }
        .font(.system(size: 17, weight: .semibold))
        .frame(height: 34)
    }

    private func commitName() {
        guard isEditingName else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        isEditingName = false
        nameFocused = false
        if !trimmed.isEmpty && trimmed != space.name {
            AppLogInfo("[LibrarySpaces] name.commit space=\(space.spaceId) accepted=\(manager.acceptsStoreAction(from: space.storeIdentifier)) length=\(trimmed.count)")
            manager.renameSpace(spaceId: space.spaceId, to: trimmed,
                                expectedStoreIdentifier: space.storeIdentifier)
        } else {
            AppLogInfo("[LibrarySpaces] name.unchanged space=\(space.spaceId) empty=\(trimmed.isEmpty)")
        }
    }

    private func color(_ value: ThemedColor) -> Color {
        value.swiftUIColor(theme: theme, appearance: appearance)
    }
}

/// Uses the sidebar's material and resolved overlay color, including saturation.
struct LibrarySpaceBackdrop: NSViewRepresentable {
    let theme: Theme
    let appearance: Appearance
    func makeNSView(context: Context) -> ColoredVisualEffectView {
        let view = ColoredVisualEffectView()
        view.material = .fullScreenUI
        view.blendingMode = .withinWindow
        return view
    }
    func updateNSView(_ view: ColoredVisualEffectView, context: Context) {
        view.backgroundColor = ThemedColor.windowOverlayBackground.resolve(theme: theme, appearance: appearance)
    }
}

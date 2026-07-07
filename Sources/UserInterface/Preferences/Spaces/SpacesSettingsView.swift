// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Settings pane content for managing Spaces, laid out master-detail (mirroring
/// the Profiles pane): the Space list on the left — drag-to-reorder, with a
/// +/−/✎ toolbar — and the selected Space's settings on the right (icon, theme,
/// profile). Mutations route through `SpaceManager`; `ProfileManager` is
/// observed for the profile picker. The NSAlert/confirmation idioms mirror the
/// Spaces menu in AppController+Menu so both entry points stay identical.
struct SpacesSettingsView: View {
    @ObservedObject private var spaceManager = SpaceManager.shared
    @ObservedObject private var profileManager = ProfileManager.shared

    @State private var selectedSpaceId: String?
    /// Pinned theme id for the selected Space (nil = Follow Global), loaded on
    /// selection and updated optimistically (setTheme writes to a separate store
    /// that doesn't republish `spaces`, so unlike icon/profile this needs local
    /// state).
    @State private var spacePinnedThemeId: String?

    /// Drag-reorder state, mirroring SpacesStripView's picker: `orderedIds` is
    /// the live snapshot rearranged as a drag hovers across rows; the persisted
    /// renumbering is written once, on drop, via `SpaceManager.reorder`.
    @State private var draggingSpaceId: String?
    @State private var orderedIds: [String] = []

    /// Local mirror of the Incognito Space preference driving the toggle;
    /// loaded on appear and only flipped after the disable confirmation (if
    /// any) is accepted, so a cancelled prompt leaves the switch in place.
    @State private var incognitoSpaceOn: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 16) {
                incognitoSpaceCard
                spaceListPanel
                    .frame(maxHeight: .infinity)
            }
            .frame(width: 300)
            detailPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(20)
        .onAppear {
            profileManager.refresh()
            incognitoSpaceOn = PhiPreferences.GeneralSettings.incognitoSpaceEnabled.loadValue()
            orderedIds = listedSpaces.map(\.spaceId)
            if selectedSpaceId == nil { selectInitialSpace() }
        }
        // Re-sync the local order when Spaces change elsewhere (never mid-drag),
        // and keep the selection valid as Spaces are created/deleted — the
        // Incognito Space's row included, so flipping its toggle off moves the
        // selection back to a Space that is still listed.
        .onChange(of: listedSpaces.map(\.spaceId)) { ids in
            if draggingSpaceId == nil { orderedIds = ids }
            if let sel = selectedSpaceId, ids.contains(sel) { return }
            selectInitialSpace()
        }
    }

    /// Every Space the list manages, in the manager's published order: the
    /// user Spaces plus, while the toggle is on, the built-in Incognito
    /// Space. All rows drag-reorder alike — the Incognito Space's position
    /// persists as an AccountUserDefaults index (see `SpaceManager.reorder`)
    /// since it has no SpaceModel row.
    private var listedSpaces: [SpaceModel] {
        spaceManager.spaces
    }

    // MARK: - Incognito Space toggle

    private var incognitoSpaceCard: some View {
        SettingsDetailCard {
            SettingsDetailRow(NSLocalizedString("Incognito Space",
                                                comment: "Spaces settings - Incognito Space toggle label")) {
                Toggle("", isOn: Binding(
                    get: { incognitoSpaceOn },
                    set: { setIncognitoSpace(enabled: $0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
        }
        .help(NSLocalizedString(
            "Adds a built-in Space that browses in a private session. URL rules can route sites into it; everything it browsed is cleared when its windows close or Phi quits.",
            comment: "Spaces settings - Incognito Space toggle tooltip"))
    }

    /// Applies the toggle. Turning it OFF while Incognito Space windows are
    /// open closes live tabs and clears the private session, so that path
    /// asks first; the alert idiom mirrors `deleteSelected`.
    private func setIncognitoSpace(enabled: Bool) {
        if !enabled, spaceManager.hasIncognitoSpaceWindows {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString(
                "Turn off Incognito Space?",
                comment: "Title of the confirmation shown when disabling the Incognito Space with open tabs")
            alert.informativeText = NSLocalizedString(
                "Its open tabs will close and its browsing data will be cleared.",
                comment: "Body of the confirmation shown when disabling the Incognito Space with open tabs")
            alert.alertStyle = .warning
            alert.addButton(withTitle: NSLocalizedString("Turn Off", comment: "Confirm disabling the Incognito Space"))
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button"))
            guard alert.runModal() == .alertFirstButtonReturn else {
                // Rejected: leave the preference untouched; the binding's
                // getter re-reads `incognitoSpaceOn`, which never flipped.
                return
            }
        }
        incognitoSpaceOn = enabled
        spaceManager.setIncognitoSpaceEnabled(enabled)
    }

    // MARK: - Left: Space list

    private var spaceListPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text(NSLocalizedString("Your Spaces", comment: "Spaces settings - list header"))
                    .font(.system(size: 12))
                    .themedForeground(.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            SettingsRowDivider()

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(orderedSpaces, id: \.spaceId) { space in
                        spaceListRow(space)
                    }
                }
                .padding(6)
            }

            SettingsRowDivider()

            HStack(spacing: 0) {
                toolbarButton(systemName: "plus",
                              help: NSLocalizedString("New Space", comment: "Spaces settings - new Space tooltip"),
                              action: newSpace)
                toolbarDivider
                toolbarButton(systemName: "minus",
                              help: NSLocalizedString("Delete selected Space", comment: "Spaces settings - delete Space tooltip"),
                              disabled: !canDeleteSelected,
                              action: deleteSelected)
                toolbarDivider
                toolbarButton(systemName: "pencil",
                              help: NSLocalizedString("Rename selected Space", comment: "Spaces settings - rename Space tooltip"),
                              disabled: !canRenameSelected,
                              action: renameSelected)
                Spacer()
            }
            .frame(height: 34)
        }
        .settingsCardChrome()
        // Fallback drop target spanning the whole list panel. Per-row delegates
        // own reordering and take precedence within their bounds; this catches
        // any drop that lands off every row — the dragged row's own hidden slot,
        // the list padding, or the empty area below the last row (e.g. dropping
        // the last Space back at the end). Without it, `draggingSpaceId` would
        // never reset there and the hidden source row would stay invisible.
        .onDrop(of: [.text], delegate: SpaceListResetDropDelegate(
            draggingSpaceId: $draggingSpaceId,
            orderedIds: $orderedIds,
            commit: { spaceManager.reorder(spaceIds: $0) }
        ))
    }

    /// Rows in drag order: the local `orderedIds` snapshot (rearranged live as a
    /// drag hovers across rows), with any Space the snapshot doesn't know yet
    /// appended in the manager's order. Mirrors SpacesStripView.orderedSpaces.
    private var orderedSpaces: [SpaceModel] {
        // Drop agent Spaces — ephemeral background workspaces (CDP / phi-agent)
        // the user can't meaningfully rename, recolor, re-profile, or delete.
        // The incognito Space is intentionally kept (see `listedSpaces`).
        let visible = listedSpaces.filter { !$0.isAgentSpace }
        guard !orderedIds.isEmpty else { return visible }
        let byId = Dictionary(uniqueKeysWithValues: visible.map { ($0.spaceId, $0) })
        var result = orderedIds.compactMap { byId[$0] }
        let known = Set(orderedIds)
        result.append(contentsOf: visible.filter { !known.contains($0.spaceId) })
        return result
    }

    private func spaceListRow(_ space: SpaceModel) -> some View {
        let isSelected = space.spaceId == selectedSpaceId
        let isDefault = space.spaceId == LocalStore.defaultSpaceId
        let isIncognito = space.spaceId == SpaceManager.incognitoSpaceId
        return HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12, weight: .medium))
                .themedForeground(.textSecondary)
            Button {
                select(space.spaceId)
            } label: {
                HStack(spacing: 8) {
                    spaceSwatch(space, size: 20)
                    Text(space.name)
                        .font(.system(size: 13))
                        .themedForeground(.textPrimary)
                        .lineLimit(1)
                    if isDefault {
                        SettingsDefaultBadge()
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // The Incognito Space's OTR profile is synthetic — never one of
            // ProfileManager's — so it gets no profile picker.
            if !isIncognito {
                Picker("", selection: profileBinding(space.spaceId)) {
                    ForEach(profileManager.profiles, id: \.profileId) { profile in
                        Text(profile.displayName).tag(profile.profileId)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .disabled(isDefault)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        // Use an explicit drag preview (not the implicit view snapshot): the
        // snapshot inherited this row's .opacity regardless of modifier order,
        // so dimming the source to remove the duplicate also blanked the drag
        // image and the item vanished. The explicit preview always renders at
        // full opacity, independent of the in-list row below.
        .onDrag {
            // Grabbing a row also selects it, so the detail panel follows the
            // Space being moved and the row reads as selected once it settles
            // back into the list.
            select(space.spaceId)
            draggingSpaceId = space.spaceId
            return NSItemProvider(object: space.spaceId as NSString)
        } preview: {
            spaceDragPreview(space)
        }
        // Hide the row left behind while it's the one being dragged; its slot
        // stays as the drop gap and the floating preview is what's dragged. This
        // removes the second faint card (the "two shadows").
        .opacity(draggingSpaceId == space.spaceId ? 0 : 1)
        .onDrop(of: [.text], delegate: SpaceRowDropDelegate(
            targetSpaceId: space.spaceId,
            draggingSpaceId: $draggingSpaceId,
            orderedIds: $orderedIds,
            commit: { spaceManager.reorder(spaceIds: $0) }
        ))
    }

    /// Gray, small-caps-style section label sitting above a settings card, as in
    /// the Spaces settings layout (Icon / Theme sections).
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .regular))
            .themedForeground(.textSecondary)
            .padding(.leading, 2)
    }

    private func spaceSwatch(_ space: SpaceModel, size: CGFloat) -> some View {
        SpaceIconView(
            storedValue: space.iconName,
            size: size * 0.8,
            symbolWeight: .semibold,
            tint: Color.primary
        )
        .frame(width: size, height: size)
    }

    /// The floating image shown under the cursor while a Space row is dragged.
    /// Mirrors the list row — drag handle, icon, name, Default badge, and the
    /// profile selector — at the same width, so the lifted preview looks like
    /// the item it came from rather than a smaller content-hugging chip. A
    /// dedicated, full-opacity view because the implicit snapshot inherited the
    /// dimmed in-list row and blanked the dragged item.
    private func spaceDragPreview(_ space: SpaceModel) -> some View {
        let isDefault = space.spaceId == LocalStore.defaultSpaceId
        let isIncognito = space.spaceId == SpaceManager.incognitoSpaceId
        let profileName = profileManager.profile(for: space.profileId)?.displayName ?? ""
        return HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12, weight: .medium))
                .themedForeground(.textSecondary)
            spaceSwatch(space, size: 20)
            Text(space.name)
                .font(.system(size: 13))
                .themedForeground(.textPrimary)
                .lineLimit(1)
            if isDefault {
                SettingsDefaultBadge()
            }
            Spacer(minLength: 4)
            // Static stand-in for the row's profile picker (a drag image is
            // never interactive); matches its label and trailing chevron.
            // The Incognito Space's row carries no picker to stand in for.
            if !isIncognito {
                HStack(spacing: 4) {
                    Text(profileName)
                        .font(.system(size: 13))
                        .themedForeground(.textPrimary)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .medium))
                        .themedForeground(.textSecondary)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        // The list panel is 300 wide and the row stack is inset by 6 on each
        // side, so the row — and therefore this preview — is 288 wide.
        .frame(width: 288, alignment: .leading)
        // The lifted Space is selected the moment it's grabbed, so the preview
        // carries the same accent highlight a selected row shows, layered over
        // an opaque base so the floating drag image still reads as a card.
        .background(Color.accentColor.opacity(0.15))
        .themedBackground(.settingItemBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func toolbarButton(systemName: String,
                               help: String,
                               disabled: Bool = false,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(disabled ? Color.secondary.opacity(0.4) : Color.primary.opacity(0.7))
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
    }

    private var toolbarDivider: some View {
        Rectangle()
            .fill(Color(.separatorColor))
            .frame(width: 1, height: 20)
    }

    // MARK: - Right: per-Space settings

    @ViewBuilder
    private var detailPanel: some View {
        if let space = selectedSpace {
            let isDefault = space.spaceId == LocalStore.defaultSpaceId
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 10) {
                        spaceSwatch(space, size: 30)
                        Text(space.name)
                            .font(.system(size: 15, weight: .semibold))
                            .themedForeground(.textPrimary)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.leading, 2)

                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader(NSLocalizedString("Icon", comment: "Spaces settings - icon section header"))
                        SettingsDetailCard {
                            IconPicker(
                                selected: IconPickerSelection.fromStorageValue(space.iconName),
                                showsGroups: true,
                                onSelect: { selection in
                                    spaceManager.changeIcon(spaceId: space.spaceId, iconName: selection.storageValue)
                                }
                            )
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader(NSLocalizedString("Theme", comment: "Spaces settings - theme section header"))
                        SettingsDetailCard {
                            SettingsDetailRow(NSLocalizedString("Color", comment: "Spaces settings - theme color row label")) {
                                themeControl(space.spaceId)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader(NSLocalizedString("Routing", comment: "Spaces settings - routing section header"))
                        SettingsDetailCard {
                            urlRulesRow
                        }
                    }

                    if isDefault {
                        Text(NSLocalizedString("The default Space can't be moved to another profile or deleted.",
                                               comment: "Spaces settings - default Space limits note"))
                            .font(.system(size: 11))
                            .themedForeground(.textSecondary)
                            .padding(.leading, 2)
                    }

                    if space.spaceId == SpaceManager.incognitoSpaceId {
                        Text(NSLocalizedString("The Incognito Space browses in a private session. Its name and profile are fixed; the toggle above the list turns it off.",
                                               comment: "Spaces settings - Incognito Space limits note"))
                            .font(.system(size: 11))
                            .themedForeground(.textSecondary)
                            .padding(.leading, 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text(NSLocalizedString("Select a Space to view its settings.",
                                   comment: "Spaces settings - empty detail placeholder"))
                .font(.system(size: 13))
                .themedForeground(.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Opens the universal URL Rules editor (the same window the Spaces menu's
    /// "URL Rules…" item opens). The editor lists every Space's rules, so it's a
    /// jump-off point rather than a per-Space control.
    private var urlRulesRow: some View {
        Button {
            AppController.shared?.openURLRulesEditor(nil)
        } label: {
            HStack(spacing: 8) {
                Text(NSLocalizedString("URL Rules\u{2026}",
                                       comment: "Spaces settings - button that opens the URL rules editor"))
                    .font(.system(size: 13))
                    .themedForeground(.textPrimary)
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 11, weight: .semibold))
                    .themedForeground(.textSecondary)
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(NSLocalizedString("Open the URL rules editor",
                                comment: "Spaces settings - tooltip for the URL rules button"))
    }

    // MARK: - Selection

    private var selectedSpace: SpaceModel? {
        guard let id = selectedSpaceId else { return nil }
        return spaceManager.spaces.first(where: { $0.spaceId == id })
    }

    private var canDeleteSelected: Bool {
        guard let space = selectedSpace else { return false }
        return space.spaceId != LocalStore.defaultSpaceId
            && space.spaceId != SpaceManager.incognitoSpaceId
    }

    /// False for the built-in Incognito Space, whose name is fixed (a rename
    /// would be a silent store no-op on its sentinel id), as in the strip's
    /// picker rows.
    private var canRenameSelected: Bool {
        guard let space = selectedSpace else { return false }
        return space.spaceId != SpaceManager.incognitoSpaceId
    }

    private func selectInitialSpace() {
        let preferred = listedSpaces.first(where: { $0.spaceId == LocalStore.defaultSpaceId })
            ?? listedSpaces.first
        if let space = preferred {
            select(space.spaceId)
        } else {
            selectedSpaceId = nil
        }
    }

    private func select(_ spaceId: String) {
        selectedSpaceId = spaceId
        spacePinnedThemeId = spaceManager.themeId(forSpaceId: spaceId)
    }

    // MARK: - Detail bindings


    /// Theme dropdown matching the sidebar's right-click "Edit Theme" submenu:
    /// a "Follow Global" entry, a divider, then every theme with its color
    /// swatch; the current one is checkmarked. A `nil` selection = Follow Global.
    private func themeControl(_ spaceId: String) -> some View {
        Menu {
            Picker("", selection: themeBinding(spaceId)) {
                Label {
                    Text(NSLocalizedString("Follow Global", comment: "Spaces settings - theme entry that clears the per-Space override"))
                } icon: {
                    Image(nsImage: .themeColorSwatch(for: ThemeManager.shared.currentTheme))
                        .renderingMode(.original)
                }
                .tag(String?.none)

                Divider()

                ForEach(ThemeManager.shared.orderedThemes, id: \.id) { theme in
                    Label {
                        Text(theme.name)
                    } icon: {
                        Image(nsImage: .themeColorSwatch(for: theme))
                            .renderingMode(.original)
                    }
                    .tag(String?(theme.id))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 6) {
                Image(nsImage: .themeColorSwatch(for: displayedTheme))
                    .renderingMode(.original)
                Text(displayedThemeName)
                    .font(.system(size: 13))
                    .themedForeground(.textPrimary)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .themedForeground(.textSecondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func themeBinding(_ spaceId: String) -> Binding<String?> {
        Binding(
            get: { spacePinnedThemeId },
            set: { newThemeId in
                spacePinnedThemeId = newThemeId
                spaceManager.setTheme(forSpaceId: spaceId, themeId: newThemeId)
            }
        )
    }

    /// The theme whose swatch/name the closed dropdown shows: the pinned theme,
    /// or the current global theme when following global.
    private var displayedTheme: Theme {
        if let id = spacePinnedThemeId {
            return ThemeManager.shared.registeredThemes[id]
                ?? Theme.builtInThemes.first(where: { $0.id == id })
                ?? ThemeManager.shared.currentTheme
        }
        return ThemeManager.shared.currentTheme
    }

    private var displayedThemeName: String {
        spacePinnedThemeId == nil
            ? NSLocalizedString("Follow Global", comment: "Spaces settings - theme follows global label")
            : displayedTheme.name
    }

    private func profileBinding(_ spaceId: String) -> Binding<String> {
        Binding(
            get: { spaceManager.spaces.first(where: { $0.spaceId == spaceId })?.profileId ?? "" },
            set: { newProfileId in
                guard let profile = profileManager.profile(for: newProfileId) else { return }
                changeSpaceProfile(spaceId: spaceId, to: profile)
            }
        )
    }

    // MARK: - Actions
    //
    // The NSAlert flows mirror the Spaces menu handlers in AppController+Menu so
    // both entry points stay identical (and share the same localized strings).

    private func newSpace() {
        // The Incognito Space's synthetic profileId is not one of
        // ProfileManager's, so it can't seed the creation form.
        let activeProfileId = selectedSpace
            .flatMap { $0.spaceId == SpaceManager.incognitoSpaceId ? nil : $0.profileId }
            ?? spaceManager.spaces.first(where: { $0.spaceId == LocalStore.defaultSpaceId })?.profileId
            ?? LocalStore.defaultProfileId
        // Always present the floating popup here. `requestCreation` would route
        // to the active browser window's sidebar overlay in vertical layouts —
        // which lives in a different window than Settings, so the form would
        // appear buried behind the Settings window instead of in front of it.
        CreateSpacePanel.present(manager: spaceManager, initialProfileId: activeProfileId)
    }

    private func deleteSelected() {
        guard let space = selectedSpace else { return }
        deleteSpace(space)
    }

    private func renameSelected() {
        guard let space = selectedSpace else { return }
        renameSpace(space)
    }

    private func renameSpace(_ space: SpaceModel) {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Rename Space", comment: "Title of the rename-Space dialog")
        alert.informativeText = NSLocalizedString("Enter a new name for this Space.", comment: "Body of the rename-Space dialog")
        alert.addButton(withTitle: NSLocalizedString("Rename", comment: "Rename button"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button"))
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        textField.stringValue = space.name
        textField.placeholderString = space.name
        alert.accessoryView = textField
        DispatchQueue.main.async {
            textField.window?.makeFirstResponder(textField)
            textField.selectText(nil)
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let trimmed = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != space.name else { return }
        spaceManager.renameSpace(spaceId: space.spaceId, to: trimmed)
    }

    private func changeSpaceProfile(spaceId: String, to profile: PhiBrowserProfile) {
        guard let space = spaceManager.spaces.first(where: { $0.spaceId == spaceId }),
              spaceId != LocalStore.defaultSpaceId,
              space.profileId != profile.profileId else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            format: NSLocalizedString("Change Profile to \u{201C}%@\u{201D}?", comment: "Title of the change-Space-profile confirmation"),
            profile.displayName
        )
        alert.informativeText = NSLocalizedString(
            "This Space's window will be reopened with the new profile and its open tabs will be reloaded there. Site logins won't carry over. Bookmarks stay with the Space; pinned tabs will be the new profile's.",
            comment: "Body of the change-Space-profile confirmation"
        )
        alert.addButton(withTitle: NSLocalizedString("Change Profile", comment: "Confirm button of the change-Space-profile confirmation"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        spaceManager.changeProfile(spaceId: spaceId, toProfileId: profile.profileId)
    }

    private func deleteSpace(_ space: SpaceModel) {
        guard space.spaceId != LocalStore.defaultSpaceId else { return }
        let alert = NSAlert()
        alert.messageText = String(
            format: NSLocalizedString("Delete \u{201C}%@\u{201D}?", comment: "Title of the delete-Space confirmation"),
            space.name
        )
        alert.informativeText = NSLocalizedString(
            "Bookmarks belonging to this Space will also be removed. This action cannot be undone.",
            comment: "Body of the delete-Space confirmation"
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("Delete", comment: "Destructive button"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        spaceManager.deleteSpace(spaceId: space.spaceId)
    }
}

// The whole-list fallback drop target (`SpaceListResetDropDelegate`) is shared
// with the sidebar strip and picker; it lives next to `SpaceRowDropDelegate` in
// SpacesStripView.swift.

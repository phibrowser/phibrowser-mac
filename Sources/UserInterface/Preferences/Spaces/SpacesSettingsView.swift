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
    @State private var pinnedTabScope: PinnedTabScope = .profile
    @State private var isChangingPinnedTabScope = false
    /// Resolved theme id and opacity slider position for the selected Space,
    /// loaded on selection and updated optimistically (setTheme /
    /// setOverlayOpacity write to stores that don't republish `spaces`, so
    /// unlike icon/profile these need local state).
    @State private var spaceThemeId: String = Theme.default.id
    @State private var spaceOpacitySliderValue: Double = 0

    @Environment(\.phiAppearance) private var appearance

    /// Drag-reorder state, mirroring SpacesStripView's picker: `orderedIds` is
    /// the live snapshot rearranged as a drag hovers across rows; the persisted
    /// renumbering is written once, on drop, via `SpaceManager.reorder`.
    @State private var draggingSpaceId: String?
    @State private var orderedIds: [String] = []

    /// §8.3's rows: the Spaces D2's 「以账户为准」 left on this Mac alone.
    /// Re-read from the local store on every change signal rather than derived
    /// from `spaceManager.spaces`, which §6.6 filters exactly these rows out of.
    @State private var unsyncedSpaces: [SpaceModel] = []

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    spaceListPanel
                        .frame(width: 300, alignment: .top)
                        .frame(maxHeight: .infinity)
                    detailPanel
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .frame(height: 431)
                SettingsDetailCard {
                    pinnedTabScopeRow
                }
                // The URL Rules editor lists every Space's rules, so it sits below
                // the master-detail split as a pane-wide jump-off rather than a
                // per-Space control.
                SettingsDetailCard {
                    urlRulesRow
                }
                // §8.3: only shown when D2 actually left something behind.
                if !unsyncedSpaces.isEmpty {
                    SettingsDetailCard {
                        unsyncedSpacesSection
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(20)
        }
        .onAppear {
            profileManager.refresh()
            pinnedTabScope = AccountController.shared.account?.localStorage.pinnedTabScope() ?? .profile
            orderedIds = listedSpaces.map(\.spaceId)
            if selectedSpaceId == nil { selectInitialSpace() }
            reloadUnsyncedSpaces()
        }
        // Re-sync the local order when Spaces change elsewhere (never mid-drag),
        // and keep the selection valid as Spaces are created/deleted.
        .onChange(of: listedSpaces.map(\.spaceId)) { ids in
            if draggingSpaceId == nil { orderedIds = ids }
            if let sel = selectedSpaceId, ids.contains(sel) { return }
            selectInitialSpace()
        }
        // Resync theme controls when the selected Space is edited from
        // another surface (General pane, sidebar picker, Spaces menu), the
        // global theme registry changes, or the appearance flips (the
        // opacity slider edits the current appearance's value).
        .onReceive(NotificationCenter.default.publisher(for: .spaceThemeDidChange)) { _ in
            syncThemeControls()
        }
        .onReceive(NotificationCenter.default.publisher(for: .themeDidChange)) { _ in
            syncThemeControls()
        }
        .onReceive(NotificationCenter.default.publisher(for: .appearanceDidChange)) { _ in
            syncThemeControls()
        }
        // §8.3's two refresh triggers. The notification is posted after every
        // Space-table write (join / hide / soft delete / purge); the second is a
        // pure CHANGE SIGNAL -- `spaceManager.spaces` can never be the row source
        // here, because §6.6 filters every hidden Space out of it.
        .onReceive(NotificationCenter.default.publisher(for: .phiSpaceHiddenSetDidChange)) { _ in
            reloadUnsyncedSpaces()
        }
        // The zero-parameter closure on purpose: the value is a signal, not data,
        // and the one-parameter spelling used above is deprecated on macOS 14.
        .onChange(of: spaceManager.spaces.map(\.spaceId)) {
            reloadUnsyncedSpaces()
        }
    }

    /// Every Space the list manages, in the manager's published order.
    /// Incognito Spaces are excluded: they are runtime-only (created from
    /// File ▸ New Incognito Space, gone once closed), so settings has
    /// nothing to manage for them.
    private var listedSpaces: [SpaceModel] {
        spaceManager.spaces.filter { !SpaceManager.isIncognitoSpaceId($0.spaceId) }
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
        return HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12, weight: .medium))
                .themedForeground(isSelected ? ThemedColor(.white) : .textSecondary)
            Button {
                select(space.spaceId)
            } label: {
                HStack(spacing: 8) {
                    spaceSwatch(space, size: 20, isSelected: isSelected)
                    Text(space.name)
                        .font(.system(size: 13))
                        .themedForeground(isSelected ? ThemedColor(.white) : .textPrimary)
                        .lineLimit(1)
                    if isDefault {
                        SettingsDefaultBadge(onAccent: isSelected)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Picker("", selection: profileBinding(space.spaceId)) {
                ForEach(profileManager.userAssignableProfiles, id: \.profileId) { profile in
                    Text(profile.displayName).tag(profile.profileId)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .disabled(isDefault)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        // Solid system accent for the focused Space, matching the sidebar
        // Space switcher's active row (SpacePickerRow).
        .background(isSelected ? Color.accentColor : Color.clear)
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

    private func spaceSwatch(_ space: SpaceModel, size: CGFloat, isSelected: Bool = false) -> some View {
        SpaceIconView(
            storedValue: space.iconName,
            size: size * 0.8,
            symbolWeight: .semibold,
            tint: isSelected ? Color.white : Color.primary
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
        let profileName = profileManager.profile(for: space.profileId)?.displayName ?? ""
        return HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.85))
            spaceSwatch(space, size: 20, isSelected: true)
            Text(space.name)
                .font(.system(size: 13))
                .foregroundStyle(Color.white)
                .lineLimit(1)
            if isDefault {
                SettingsDefaultBadge(onAccent: true)
            }
            Spacer(minLength: 4)
            // Static stand-in for the row's profile picker (a drag image is
            // never interactive); matches its label and trailing chevron.
            HStack(spacing: 4) {
                Text(profileName)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.85))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        // The list panel is 300 wide and the row stack is inset by 6 on each
        // side, so the row — and therefore this preview — is 288 wide.
        .frame(width: 288, alignment: .leading)
        // The lifted Space is selected the moment it's grabbed, so the preview
        // carries the same solid accent highlight a selected row shows.
        .background(Color.accentColor)
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
            // No outer ScrollView: the Icon card absorbs all spare height (the
            // grid scrolls internally), so the Opacity card's bottom edge lines
            // up with the Space list's bottom edge.
            VStack(alignment: .leading, spacing: 16) {
                SettingsDetailCard {
                    // Report the card's real content width so the picker
                    // reflows its grid edge-to-edge (the width-less path
                    // renders a fixed 262pt column centered in the card,
                    // leaving blank margins on both sides).
                    GeometryReader { geo in
                        IconPicker(
                            selected: IconPickerSelection.fromStorageValue(space.iconName),
                            showsGroups: true,
                            width: geo.size.width,
                            fillsAvailableHeight: true,
                            onSelect: { selection in
                                spaceManager.changeIcon(spaceId: space.spaceId, iconName: selection.storageValue)
                            }
                        )
                    }
                    .padding(.vertical, 8)
                }
                .frame(maxHeight: .infinity)

                SettingsDetailCard {
                    colorRow(space.spaceId)
                    SettingsRowDivider()
                    SettingsDetailRow(NSLocalizedString("Opacity", comment: "Spaces settings - theme opacity row label for the per-Space window overlay transparency")) {
                        ThemeOpacitySliderView(
                            value: opacityBinding(space.spaceId),
                            trackColor: opacitySliderTrackColor(space.spaceId),
                            borderColor: ThemedColor.border.resolve(theme: displayedTheme, appearance: appearance),
                            width: Self.opacitySliderWidth
                        )
                        .frame(width: Self.opacitySliderWidth, height: 20)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
                Image(systemName: "chevron.right")
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

    private var pinnedTabScopeRow: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(NSLocalizedString(
                    "Pinned tab scope",
                    comment: "Spaces settings - pinned-tab scope row label"
                ))
                .font(.system(size: 13))
                .themedForeground(.textPrimary)

                Text(pinnedTabScopeDescription)
                    .font(.system(size: 11))
                    .themedForeground(.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Picker(
                "",
                selection: Binding(
                    get: { pinnedTabScope },
                    set: { requestPinnedTabScopeChange(to: $0) }
                )
            ) {
                ForEach(PinnedTabScope.allCases) { scope in
                    Text(pinnedTabScopeName(scope)).tag(scope)
                }
            }
            .labelsHidden()
            .frame(width: 120)
            .disabled(isChangingPinnedTabScope)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var pinnedTabScopeDescription: String {
        switch pinnedTabScope {
        case .space:
            return NSLocalizedString(
                "Each Space has its own pinned tabs.",
                comment: "Spaces settings - description of Space pinned-tab scope"
            )
        case .profile:
            return NSLocalizedString(
                "Spaces using the same profile share pinned tabs.",
                comment: "Spaces settings - description of Profile pinned-tab scope"
            )
        case .app:
            return NSLocalizedString(
                "Pinned tabs are shared across all profiles and Spaces.",
                comment: "Spaces settings - description of App pinned-tab scope"
            )
        }
    }

    private func pinnedTabScopeName(_ scope: PinnedTabScope) -> String {
        switch scope {
        case .space:
            return NSLocalizedString("Space", comment: "Spaces settings - Space pinned-tab scope option")
        case .profile:
            return NSLocalizedString("Profile", comment: "Spaces settings - Profile pinned-tab scope option")
        case .app:
            return NSLocalizedString("App", comment: "Spaces settings - App pinned-tab scope option")
        }
    }

    private func requestPinnedTabScopeChange(to newScope: PinnedTabScope) {
        guard newScope != pinnedTabScope,
              !isChangingPinnedTabScope else { return }

        let previousScope = pinnedTabScope
        let isCopy = newScope.hierarchyLevel < previousScope.hierarchyLevel
        pinnedTabScope = newScope

        guard let store = AccountController.shared.account?.localStorage else {
            pinnedTabScope = previousScope
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = NSLocalizedString(
            "Change Pinned Tab Scope?",
            comment: "Spaces settings - title of pinned-tab scope migration confirmation"
        )
        alert.informativeText = isCopy
            ? NSLocalizedString(
                "Your current pinned tabs will be copied into each existing destination. The copies can then be changed independently.",
                comment: "Spaces settings - confirmation body for narrowing pinned-tab scope"
            )
            : NSLocalizedString(
                "Pinned tabs from the existing destinations will be merged. Unchanged copies will be combined, while different versions will be kept.",
                comment: "Spaces settings - confirmation body for broadening pinned-tab scope"
            )
        alert.addButton(withTitle: NSLocalizedString("Change Scope", comment: "Spaces settings - confirm pinned-tab scope change"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button"))
        guard alert.runModal() == .alertFirstButtonReturn else {
            pinnedTabScope = previousScope
            return
        }

        let preferredSpaceId = spaceManager.activeSpaceId ?? selectedSpaceId
        let preferredProfileId = preferredSpaceId.flatMap { spaceId in
            spaceManager.spaces.first(where: { $0.spaceId == spaceId })?.profileId
        }
        isChangingPinnedTabScope = true
        Task { @MainActor in
            do {
                try await store.changePinnedTabScope(
                    to: newScope,
                    preferredProfileId: preferredProfileId,
                    preferredSpaceId: preferredSpaceId
                )
                pinnedTabScope = newScope
            } catch {
                pinnedTabScope = previousScope
                let errorAlert = NSAlert()
                errorAlert.alertStyle = .critical
                errorAlert.messageText = NSLocalizedString(
                    "Pinned Tab Scope Wasn’t Changed",
                    comment: "Spaces settings - pinned-tab scope migration error title"
                )
                errorAlert.informativeText = error.localizedDescription
                errorAlert.addButton(withTitle: NSLocalizedString("OK", comment: "Dismiss button"))
                errorAlert.runModal()
            }
            isChangingPinnedTabScope = false
        }
    }

    // MARK: - Selection

    private var selectedSpace: SpaceModel? {
        guard let id = selectedSpaceId else { return nil }
        return listedSpaces.first(where: { $0.spaceId == id })
    }

    private var canDeleteSelected: Bool {
        guard let space = selectedSpace else { return false }
        return space.spaceId != LocalStore.defaultSpaceId
    }

    private var canRenameSelected: Bool {
        selectedSpace != nil
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
        syncThemeControls()
    }

    /// Loads the selected Space's resolved theme id and effective overlay
    /// opacity (for the current appearance) into the local control state.
    private func syncThemeControls() {
        guard let spaceId = selectedSpaceId else { return }
        spaceThemeId = spaceManager.resolvedThemeId(forSpaceId: spaceId)
        let alpha = spaceManager.effectiveOverlayOpacity(
            forSpaceId: spaceId,
            appearance: ThemeManager.shared.currentAppearance
        )
        spaceOpacitySliderValue = OverlayOpacityScale.sliderValue(forOpacityPercent: alpha * 100)
    }

    // MARK: - Detail bindings

    private static let opacitySliderWidth: CGFloat = 220

    /// Inline theme swatch row mirroring the General pane's Color row: one
    /// dot per built-in theme, the Space's resolved theme ringed with its
    /// name captioned underneath. Compact sizing so all eight dots fit the
    /// narrower detail card.
    private func colorRow(_ spaceId: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(NSLocalizedString("Color", comment: "Spaces settings - theme color row label"))
                .font(.system(size: 13))
                .themedForeground(.textPrimary)
                // The swatch row eats most of the card width; never let the
                // label wrap into a vertical letter stack.
                .lineLimit(1)
                .fixedSize()

            Spacer(minLength: 8)

            HStack(alignment: .top, spacing: 3) {
                ForEach(ThemeManager.shared.orderedThemes, id: \.id) { theme in
                    ThemeSwatchView(
                        fillColor: theme == .pure
                            ? .white
                            : Color(theme.color(for: .themeColor, appearance: appearance)),
                        ringColor: Color(theme.color(for: .themeColor, appearance: appearance)),
                        selected: spaceThemeId == theme.id,
                        title: theme.name,
                        showsContrastBorder: theme == .pure,
                        action: { selectTheme(theme.id, for: spaceId) }
                    )
                    .frame(width: 26)
                }
            }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func selectTheme(_ themeId: String, for spaceId: String) {
        guard spaceThemeId != themeId else { return }
        spaceThemeId = themeId
        // For the default Space this also switches the global theme
        // (SpaceManager keeps that invariant).
        spaceManager.setTheme(forSpaceId: spaceId, themeId: themeId)
        // The new theme's own alpha may differ; re-derive the slider (a
        // custom per-Space opacity survives the switch).
        syncThemeControls()
    }

    private func opacityBinding(_ spaceId: String) -> Binding<Double> {
        Binding(
            get: { spaceOpacitySliderValue },
            set: { newValue in
                spaceOpacitySliderValue = newValue
                let percent = OverlayOpacityScale.opacityPercent(forSlider: newValue)
                spaceManager.setOverlayOpacity(
                    CGFloat(percent / 100),
                    forSpaceId: spaceId,
                    appearance: ThemeManager.shared.currentAppearance
                )
            }
        )
    }

    /// The gradient hue behind the opacity slider: the Space's resolved
    /// overlay color (alpha is stripped by the track renderer).
    private func opacitySliderTrackColor(_ spaceId: String) -> NSColor {
        spaceManager.resolvedTheme(forSpaceId: spaceId)
            .color(for: .windowOverlayBackground, appearance: appearance)
    }

    /// The selected Space's theme instance, for chrome derived from it
    /// (the opacity slider's border color).
    private var displayedTheme: Theme {
        ThemeManager.shared.registeredThemes[spaceThemeId]
            ?? Theme.builtInThemes.first(where: { $0.id == spaceThemeId })
            ?? ThemeManager.shared.currentTheme
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
        let activeProfileId = selectedSpace?.profileId
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
        alert.informativeText = changeProfileConfirmationBody
        alert.addButton(withTitle: NSLocalizedString("Change Profile", comment: "Confirm button of the change-Space-profile confirmation"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        spaceManager.changeProfile(spaceId: spaceId, toProfileId: profile.profileId)
    }

    // MARK: - §8.3: Spaces that are not in the account

    /// The Spaces D2 kept off the account: hidden from the strip, complete on
    /// disk. Rows are `account.localStorage.getAllSpaces()` ∩
    /// `PhiSpaceSyncState.shared.unsyncedSpaceIds` -- never `spaceManager.spaces`
    /// (§6.6 filters these very rows out) and never `hiddenSpaceIds`, which also
    /// holds remotely soft-deleted Spaces: for those the header's "only on this
    /// Mac" is false, "join account sync" is a dud (the engine refuses a cursor
    /// that carries `deletedAtMs` or an `entityId`), and the 30-day sweep would
    /// cascade the Space away days after the user "added it back".
    private var unsyncedSpacesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(
                    format: NSLocalizedString("未同步到账户 (%d)",
                                              comment: "Spaces settings - not-synced-to-account section header"),
                    unsyncedSpaces.count
                ))
                .font(.system(size: 13))
                .themedForeground(.textPrimary)

                Text(NSLocalizedString(
                    "这些 Space 只存在于这台 Mac，不会出现在你的其他设备上。",
                    comment: "Spaces settings - not-synced-to-account section explanation"))
                    .font(.system(size: 11))
                    .themedForeground(.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(unsyncedSpaces, id: \.spaceId) { space in
                SettingsRowDivider()
                unsyncedSpaceRow(space)
            }
        }
    }

    private func unsyncedSpaceRow(_ space: SpaceModel) -> some View {
        HStack(spacing: 8) {
            Text(space.name)
                .font(.system(size: 13))
                .themedForeground(.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 12)

            Button(NSLocalizedString("加入账户同步",
                                     comment: "Spaces settings - join account sync button")) {
                PhiSpaceSyncState.shared.joinAccountSync(spaceId: space.spaceId)
            }
            .buttonStyle(.bordered)

            Button(NSLocalizedString("删除\u{2026}",
                                     comment: "Spaces settings - delete unsynced Space button")) {
                deleteSpace(space)
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// `getAllSpaces()` is the unfiltered local truth; the intersection with
    /// `unsyncedSpaceIds` is what keeps remote soft deletes out of this list.
    private func reloadUnsyncedSpaces() {
        let unsynced = PhiSpaceSyncState.shared.unsyncedSpaceIds
        guard !unsynced.isEmpty,
              let storage = AccountController.shared.account?.localStorage else {
            unsyncedSpaces = []
            return
        }
        unsyncedSpaces = storage.getAllSpaces().filter { unsynced.contains($0.spaceId) }
    }

    private func deleteSpace(_ space: SpaceModel) {
        guard space.spaceId != LocalStore.defaultSpaceId else { return }
        let alert = NSAlert()
        alert.messageText = String(
            format: NSLocalizedString("Delete \u{201C}%@\u{201D}?", comment: "Title of the delete-Space confirmation"),
            space.name
        )
        alert.informativeText = deleteSpaceConfirmationBody
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("Delete", comment: "Destructive button"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        spaceManager.deleteSpace(spaceId: space.spaceId)
    }

    private var changeProfileConfirmationBody: String {
        switch pinnedTabScope {
        case .space:
            return NSLocalizedString(
                "This Space's window will be reopened with the new profile and its open tabs will be reloaded there. Site logins won't carry over. Bookmarks and pinned tabs stay with the Space.",
                comment: "Body of the change-Space-profile confirmation with Space-scoped pinned tabs"
            )
        case .profile:
            return NSLocalizedString(
                "This Space's window will be reopened with the new profile and its open tabs will be reloaded there. Site logins won't carry over. Bookmarks stay with the Space; pinned tabs will be the new profile's.",
                comment: "Body of the change-Space-profile confirmation with Profile-scoped pinned tabs"
            )
        case .app:
            return NSLocalizedString(
                "This Space's window will be reopened with the new profile and its open tabs will be reloaded there. Site logins won't carry over. Bookmarks stay with the Space; pinned tabs remain shared across the app.",
                comment: "Body of the change-Space-profile confirmation with App-scoped pinned tabs"
            )
        }
    }

    private var deleteSpaceConfirmationBody: String {
        if pinnedTabScope == .space {
            return NSLocalizedString(
                "Bookmarks and pinned tabs belonging to this Space will also be removed. This action cannot be undone.",
                comment: "Body of the delete-Space confirmation with Space-scoped pinned tabs"
            )
        }
        return NSLocalizedString(
            "Bookmarks belonging to this Space will also be removed. This action cannot be undone.",
            comment: "Body of the delete-Space confirmation"
        )
    }
}

// The whole-list fallback drop target (`SpaceListResetDropDelegate`) is shared
// with the sidebar strip and picker; it lives next to `SpaceRowDropDelegate` in
// SpacesStripView.swift.
